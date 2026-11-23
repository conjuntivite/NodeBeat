import json
from datetime import UTC, datetime, timedelta

import fakeredis
import pytest
from cryptography.fernet import Fernet
from mongomock_motor import AsyncMongoMockClient

from nodebeat import config, crypto, history, store
from nodebeat.config import Settings
from nodebeat.routeros import CertMismatch, RouterOsError, Snapshot
from nodebeat.rules import AlertEngine
from nodebeat.webhook import QUEUE
from nodebeat.worker import atualizar_mk, inventario_devido, load_engine, run_cycle, run_inventario

T0 = datetime(2026, 1, 1, 12, 0, tzinfo=UTC)
KEY = Fernet.generate_key().decode()
SET = Settings("m", "r", KEY, "https://hook.example", None, "ref.example")


@pytest.fixture
def db():
    return AsyncMongoMockClient()["nodebeat"]


@pytest.fixture
def r():
    return fakeredis.FakeAsyncRedis(decode_responses=True)


def doc(nome="mk1", ip="10.0.0.1", **kw):
    return {"nome": nome, "ip_tunel": ip, "ip_publico": None, "usuario": "u",
            "senha_cifrada": crypto.encrypt("segredo", KEY), "cert_sha256": None,
            "interfaces_vigiadas": [], **kw}


async def sim_ok(_):
    return True


async def sim_no(_):
    return False


def fetch_fail(*a):
    raise RouterOsError("sem resposta")


def fetch_ok(*a):
    return Snapshot("7.1", 10.0, 20.0, "1d", {}), "abc123"


async def ciclos(db, r, eng, secs, **kw):
    for s in secs:
        await run_cycle(db, r, eng, SET, T0 + timedelta(seconds=s),
                        ping=sim_no, reference_ok=sim_ok, **kw)


async def test_cycle_enqueues_after_confirm(db, r):
    await store.insert_mk(db, doc())
    await ciclos(db, r, AlertEngine(), range(0, 121, 30), fetch=fetch_fail)
    fila = [json.loads(x) for x in await r.lrange(QUEUE, 0, -1)]
    assert [p["tipo"] for p in fila] == ["offline"] and fila[0]["evento"] == "queda"


async def test_first_contact_pins_cert(db, r):
    id = await store.insert_mk(db, doc())
    await ciclos(db, r, AlertEngine(), [0], fetch=fetch_ok)
    assert (await store.get_mk(db, id))["cert_sha256"] == "abc123"
    st = (await history.load_states(r))[id]
    assert st["status"] == "no_ar" and st["cpu"] == 10.0 and st["desde"] == T0.isoformat()


async def test_frozen_skips_mks(db, r):
    await store.insert_mk(db, doc())
    chamadas = []
    await run_cycle(db, r, AlertEngine(), SET, T0, ping=sim_no, reference_ok=sim_no,
                    fetch=lambda *a: chamadas.append(a))
    assert chamadas == [] and await history.load_states(r) == {}


async def test_one_mk_exception_does_not_stop_others(db, r):
    await store.insert_mk(db, doc("ruim", "10.0.0.1"))
    bom = await store.insert_mk(db, doc("bom", "10.0.0.2"))

    async def ping(ip):
        if ip == "10.0.0.1":
            raise RuntimeError("boom")
        return False

    await run_cycle(db, r, AlertEngine(), SET, T0, ping=ping, reference_ok=sim_ok,
                    fetch=fetch_fail)
    assert (await history.load_states(r))[bom]["status"] == "offline"


async def test_engine_persisted_across_restart(db, r):
    id = await store.insert_mk(db, doc())
    await ciclos(db, r, AlertEngine(), range(0, 121, 30), fetch=fetch_fail)
    eng = AlertEngine.load(json.loads(await r.get("engine")))
    await ciclos(db, r, eng, [150, 180, 240], fetch=fetch_ok)
    # webhook (ticket no sistema de chamados) só na queda; o retorno fica no histórico do painel
    fila = [json.loads(x) for x in await r.lrange(QUEUE, 0, -1)]
    assert [p["evento"] for p in fila] == ["queda"]
    assert "retorno" in [h["evento"] for h in await history.history(r, id, now=(T0 + timedelta(seconds=300)).timestamp())]


async def test_removed_mk_is_forgotten(db, r):
    id = await store.insert_mk(db, doc())
    eng = AlertEngine()
    await ciclos(db, r, eng, [0], fetch=fetch_fail)
    await store.delete_mk(db, id)
    await ciclos(db, r, eng, [30], fetch=fetch_fail)
    assert await history.load_states(r) == {} and eng.dump()["trackers"] == {}


async def test_invalid_id_is_none(db):
    assert await store.get_mk(db, "x") is None and not await store.delete_mk(db, "x")


def test_load_settings_missing_var(monkeypatch):
    for k in ("MONGO_URL", "REDIS_URL", "SECRET_KEY", "WEBHOOK_URL", "REFERENCE_HOST"):
        monkeypatch.setenv(f"NODEBEAT_{k}", "x")
    monkeypatch.delenv("NODEBEAT_SECRET_KEY")
    with pytest.raises(RuntimeError, match="NODEBEAT_SECRET_KEY"):
        config.load_settings()
    monkeypatch.setenv("NODEBEAT_SECRET_KEY", "x")
    assert config.load_settings().interval_s == 30


async def test_reference_blip_retried_in_same_cycle(db, r):
    await store.insert_mk(db, doc())
    chamadas = []

    async def ref(_):  # só a 1ª tentativa do ciclo 60 falha
        chamadas.append(1)
        return len(chamadas) != 3

    eng = AlertEngine()
    for s in range(0, 121, 30):
        await run_cycle(db, r, eng, SET, T0 + timedelta(seconds=s), ping=sim_no,
                        reference_ok=ref, fetch=fetch_fail)
    fila = [json.loads(x) for x in await r.lrange(QUEUE, 0, -1)]
    assert [(p["evento"], p["tipo"]) for p in fila] == [("queda", "offline")]


async def test_cycle_marks_worker_alive(db, r):
    await run_cycle(db, r, AlertEngine(), SET, T0, ping=sim_no, reference_ok=sim_no)
    assert 0 < await r.ttl("worker:vivo") <= 90


def test_load_engine_tolerates_corrupt_json(caplog):
    assert load_engine(None).dump()["trackers"] == {}
    assert load_engine('{"frozen": tru').dump()["trackers"] == {}
    assert load_engine('{"x": 1}').dump()["trackers"] == {}
    assert "tru" not in caplog.text
    e = AlertEngine()
    e.observe_reference(False, T0)
    assert load_engine(json.dumps(e.dump())).frozen


async def test_cert_mismatch_keeps_pin(db, r):
    id = await store.insert_mk(db, doc(cert_sha256="ab" * 32))

    def fetch_mismatch(*a):
        raise CertMismatch()

    await run_cycle(db, r, AlertEngine(), SET, T0, ping=sim_ok, reference_ok=sim_ok,
                    fetch=fetch_mismatch)
    assert (await store.get_mk(db, id))["cert_sha256"] == "ab" * 32
    assert (await history.load_states(r))[id]["status"] == "erro_acesso"


async def test_desde_kept_across_down_types(db, r):
    id = await store.insert_mk(db, doc())
    eng = AlertEngine()
    await ciclos(db, r, eng, [0], fetch=fetch_fail)
    st0 = (await history.load_states(r))[id]
    await run_cycle(db, r, eng, SET, T0 + timedelta(seconds=30),
                    ping=sim_ok, reference_ok=sim_ok, fetch=fetch_fail)
    st1 = (await history.load_states(r))[id]
    assert st0["status"] != st1["status"] and st1["status"] != "no_ar"
    assert st1["desde"] == T0.isoformat()


RAW = {"address": [], "dhcp_network": [], "pool": [], "ipsec_policy": [], "nat": [], "service": [],
       "lease": [], "arp": []}


def raw_com(ips):
    return {**RAW, "address": [{"address": "192.0.2.1/24", "network": "192.0.2.0", "interface": "ether2"}],
            "arp": [{"address": ip, "mac-address": "AA:BB:CC:00:00:01", "interface": "ether2"} for ip in ips]}


def fetch_inv(ips):
    return lambda *a, **k: raw_com(ips)


async def mk_com_id(db, **kw):
    d = doc(**kw)
    d["id"] = await store.insert_mk(db, dict(d))
    return d


async def test_inventario_grava_e_mantem_em_falha(db):
    mk = await mk_com_id(db)
    assert await atualizar_mk(db, SET, mk, T0, fetch=fetch_inv(["192.0.2.5"])) is None
    inv = await store.get_inventario(db, mk["id"])
    assert inv["redes"][0]["rede"] == "192.0.2.0/24" and inv["erro"] is None
    assert inv["lido_em"].tzinfo is not None
    assert [i["ip"] for i in await store.listar_ips(db, mk["id"])] == ["192.0.2.5"]

    def falha(*a, **k):
        raise RouterOsError("API sem resposta (timeout)")
    assert await atualizar_mk(db, SET, mk, T0 + timedelta(hours=1), fetch=falha) == "API sem resposta (timeout)"
    inv2 = await store.get_inventario(db, mk["id"])
    assert inv2["erro"] == "API sem resposta (timeout)"
    assert inv2["redes"] == inv["redes"] and inv2["lido_em"] == inv["lido_em"]
    assert "_id" not in inv2


async def test_ip_nao_some_e_primeiro_visto_fixo(db):
    mk = await mk_com_id(db)
    await atualizar_mk(db, SET, mk, T0, fetch=fetch_inv(["192.0.2.5"]))
    await atualizar_mk(db, SET, mk, T0 + timedelta(hours=1), fetch=fetch_inv([]))
    (ip,) = await store.listar_ips(db, mk["id"])
    assert ip["primeiro_visto"] == T0 and ip["ultimo_visto"] == T0 and ip["primeiro_visto"].tzinfo is not None
    await atualizar_mk(db, SET, mk, T0 + timedelta(hours=2), fetch=fetch_inv(["192.0.2.5"]))
    (ip,) = await store.listar_ips(db, mk["id"])
    assert ip["primeiro_visto"] == T0 and ip["ultimo_visto"] == T0 + timedelta(hours=2)
    assert await store.esquecer_ip(db, mk["id"], "192.0.2.5") and not await store.esquecer_ip(db, mk["id"], "192.0.2.5")


async def test_inventario_uma_mk_falha_outras_gravam(db):
    a = await mk_com_id(db, nome="a", ip="10.0.0.1")
    b = await mk_com_id(db, nome="b", ip="10.0.0.2")

    def fetch(host, *x):
        if host == "10.0.0.1":
            raise ValueError("senha=segredo")
        return raw_com([])
    await run_inventario(db, SET, T0, fetch=fetch)
    assert (await store.get_inventario(db, a["id"]))["erro"] == "Resposta inesperada da API"
    assert (await store.get_inventario(db, b["id"]))["erro"] is None
    assert len(await store.listar_inventarios(db)) == 2
    await store.apagar_inventario(db, a["id"])
    assert await store.get_inventario(db, a["id"]) is None


async def test_senha_invalida_no_inventario(db):
    mk = await mk_com_id(db, senha_cifrada="lixo")
    assert await atualizar_mk(db, SET, mk, T0, fetch=fetch_inv([])) == "Senha cifrada inválida"


def test_inventario_devido():
    assert inventario_devido(None, 0, 3600, False)
    assert not inventario_devido(0, 100, 3600, False)
    assert inventario_devido(0, 100, 3600, True)
    assert inventario_devido(0, 3600, 3600, False)


async def test_listar_ips_ordem_numerica(db):
    await store.registrar_ips(db, "m1", [{"ip": ip, "mac": None, "host_name": None, "fixo": False}
                                          for ip in ("192.168.10.10", "192.168.10.9")], T0)
    assert [i["ip"] for i in await store.listar_ips(db, "m1")] == ["192.168.10.9", "192.168.10.10"]


def test_sede_redes(monkeypatch):
    for k in ("MONGO_URL", "REDIS_URL", "SECRET_KEY", "WEBHOOK_URL", "REFERENCE_HOST"):
        monkeypatch.setenv(f"NODEBEAT_{k}", "x")
    monkeypatch.delenv("NODEBEAT_SEDE_REDES", raising=False)
    assert config.load_settings().sede_redes == [] and config.load_settings().inventario_s == 3600
    monkeypatch.setenv("NODEBEAT_SEDE_REDES", "10.1.0.1/16, 10.2.0.0/24")
    assert config.load_settings().sede_redes == ["10.1.0.0/16", "10.2.0.0/24"]
    monkeypatch.setenv("NODEBEAT_SEDE_REDES", "xyz")
    with pytest.raises(RuntimeError, match="NODEBEAT_SEDE_REDES inválida"):
        config.load_settings()


async def test_run_inventario_nao_levanta_se_list_mks_falha(db, monkeypatch):
    async def boom(_):
        raise RuntimeError("mongo fora")
    monkeypatch.setattr(store, "list_mks", boom)
    assert await run_inventario(db, SET, T0) is False


async def test_reinicio_solicitado_nao_alerta_e_expira(db, r):
    id = await store.insert_mk(db, doc())
    await r.set(f"reinicio:{id}", "ana", ex=300)
    eng = AlertEngine()
    await ciclos(db, r, eng, [0], fetch=fetch_ok)  # ainda desligando: responde, janela continua
    await ciclos(db, r, eng, range(30, 241, 30), fetch=fetch_fail)
    assert await r.lrange(QUEUE, 0, -1) == []
    assert (await history.load_states(r))[id]["status"] == "reiniciando"
    await r.delete(f"reinicio:{id}")  # janela expirou e não voltou: alerta normal
    await ciclos(db, r, eng, range(270, 391, 30), fetch=fetch_fail)
    assert [json.loads(x)["tipo"] for x in await r.lrange(QUEUE, 0, -1)] == ["offline"]


def test_load_engine_usa_janela_de_retorno_atual():
    from nodebeat.worker import RECOVER_S
    assert load_engine(None).recover_s == RECOVER_S
    assert load_engine(json.dumps(AlertEngine().dump())).recover_s == RECOVER_S  # estado antigo (60 s)


def test_oscilacao_dentro_da_janela_gera_uma_queda_so():
    from nodebeat.rules import MkRef, MkState, Observation
    from nodebeat.worker import RECOVER_S
    e, m = AlertEngine(recover_s=RECOVER_S), MkRef("1", "Alfa")
    off, ok = Observation(MkState.OFFLINE, "x"), Observation(MkState.NO_AR)
    # cai 3 min, volta 2 min, cai 3 min, volta 2 min, cai de novo... (flapping)
    seq = [off] * 7 + [ok] * 4 + [off] * 6 + [ok] * 4 + [off] * 6
    evs = [ev for i, o in enumerate(seq) for ev in e.observe_mk(m, o, T0 + timedelta(seconds=30 * i))]
    assert [ev.evento for ev in evs] == ["queda"]
