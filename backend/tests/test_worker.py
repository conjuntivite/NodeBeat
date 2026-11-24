import json
from datetime import UTC, datetime, timedelta

import fakeredis
import pytest
from cryptography.fernet import Fernet
from mongomock_motor import AsyncMongoMockClient

from nodebeat import config, crypto, history, snmp, store
from nodebeat.config import Settings
from nodebeat.routeros import CertMismatch, RouterOsError, Snapshot
from nodebeat.rules import AlertEngine
from nodebeat.webhook import QUEUE
from nodebeat.worker import (atualizar_mk, inventario_devido, load_engine, run_cycle, run_inventario, run_mapa,
                             run_switches)

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


async def test_registrar_ips_nao_apaga_porta(db):
    ip = {"ip": "10.0.0.5", "mac": None, "host_name": None, "fixo": False}
    fato = {"porta": "ether2", "bridge": "bridge1", "fabricante": "Outro", "identidade": None,
            "plataforma": None, "e_switch": False}
    await store.registrar_ips(db, "m1", [ip], T0, {"10.0.0.5": fato})
    await store.registrar_ips(db, "m1", [ip], T0 + timedelta(hours=1), {"10.0.0.5": {**fato, "porta": None}})
    (d,) = await store.listar_ips(db, "m1")
    assert d["porta"] == "ether2" and d["ultimo_visto"] == T0 + timedelta(hours=1)


async def test_atualizar_mk_grava_porta(db):
    mk = await mk_com_id(db)
    raw = raw_com(["192.0.2.5"])
    raw["bridge_host"] = [{"mac-address": "AA:BB:CC:00:00:01", "on-interface": "ether3", "bridge": "bridge1"}]
    raw["arp"][0]["interface"] = "bridge1"
    assert await atualizar_mk(db, SET, mk, T0, fetch=lambda *a, **k: raw) is None
    (ip,) = await store.listar_ips(db, mk["id"])
    assert ip["porta"] == "ether3" and ip["bridge"] == "bridge1"


async def test_atualizar_mk_fatos_malformados_nao_quebram_inventario(db):
    mk = await mk_com_id(db)
    raw = raw_com(["192.0.2.5"])
    raw["neighbor"] = ["lixo"]
    assert await atualizar_mk(db, SET, mk, T0, fetch=lambda *a, **k: raw) is None
    assert (await store.get_inventario(db, mk["id"]))["erro"] is None
    (ip,) = await store.listar_ips(db, mk["id"])
    assert ip["ip"] == "192.0.2.5" and "porta" not in ip and "fabricante" not in ip


async def test_registrar_ips_sem_fatos(db):
    await store.registrar_ips(db, "m1", [{"ip": "10.0.0.1", "fixo": False}], T0)
    (d,) = await store.listar_ips(db, "m1")
    assert "porta" not in d


async def _mk_mapa(db, r, status="no_ar"):
    mk = await store.insert_mk(db, doc())
    await history.save_state(r, mk, {"status": status})
    await store.salvar_inventario(db, mk, {"redes": [
        {"rede": "192.0.2.0/24", "tunel": True}, {"rede": "198.51.100.0/24", "tunel": False}]}, T0)
    base = {"mac": None, "host_name": None, "fixo": False}
    await store.registrar_ips(db, mk, [
        {**base, "ip": "192.0.2.5"}, {**base, "ip": "192.0.2.6"}, {**base, "ip": "192.0.2.7"},
        {**base, "ip": "192.0.2.8"}, {**base, "ip": "198.51.100.5"}], T0, {
        "192.0.2.5": {"fabricante": "Hikvision"}, "192.0.2.6": {"fabricante": "MAC privado"},
        "192.0.2.7": {"fabricante": "Hikvision"}, "198.51.100.5": {"fabricante": "Hikvision"}})
    # 192.0.2.8 sem fabricante mas fixo
    await db.inventario_ips.update_one({"ip": "192.0.2.8"}, {"$set": {"fixo": True}})
    # 192.0.2.7 velho demais
    await db.inventario_ips.update_one({"ip": "192.0.2.7"}, {"$set": {"ultimo_visto": T0 - timedelta(days=20)}})
    return mk


async def test_run_mapa_pinga_so_vigiados_em_tunel(db, r):
    mk = await _mk_mapa(db, r)
    chamados = []

    async def ping(ip):
        chamados.append(ip)
        return True

    await run_mapa(db, r, SET, T0, ping=ping)
    assert sorted(chamados) == ["192.0.2.5", "192.0.2.8"]
    est = await history.load_aparelhos(r, mk)
    assert est["192.0.2.5"]["online"] is True


async def test_run_mapa_mk_fora_do_ar_nao_pinga_e_preserva_estado(db, r):
    mk = await _mk_mapa(db, r, status="offline")
    await history.save_aparelhos(r, mk, {"192.0.2.5": {"online": True, "falhas": 0, "desde": "x"}})
    chamados = []

    async def ping(ip):
        chamados.append(ip)
        return False

    await run_mapa(db, r, SET, T0, ping=ping)
    assert chamados == []
    assert (await history.load_aparelhos(r, mk))["192.0.2.5"]["online"] is True


async def test_run_mapa_descarta_estado_de_quem_nao_e_mais_alvo(db, r):
    mk = await _mk_mapa(db, r)
    velho = {"online": False, "falhas": 5, "desde": "x"}
    await history.save_aparelhos(r, mk, {"192.0.2.5": velho, "192.0.2.6": velho, "192.0.2.99": velho})

    async def ping(ip):
        return False

    await run_mapa(db, r, SET, T0, ping=ping)
    est = await history.load_aparelhos(r, mk)
    assert set(est) == {"192.0.2.5", "192.0.2.8"}  # só os alvos desta rodada
    # deixa de ser vigiado e volta: começa do zero
    await db.inventario_ips.update_many({"mk_id": mk}, {"$set": {"vigiar_manual": False}})
    await run_mapa(db, r, SET, T0, ping=ping)
    assert await history.load_aparelhos(r, mk) == {}
    await db.inventario_ips.update_many({"mk_id": mk}, {"$unset": {"vigiar_manual": ""}})
    await run_mapa(db, r, SET, T0, ping=ping)
    assert (await history.load_aparelhos(r, mk))["192.0.2.5"]["falhas"] == 1


async def test_check_guarda_portas_link(db, r):
    mk = await store.insert_mk(db, doc(interfaces_vigiadas=["ether1"]))
    eng = AlertEngine(recover_s=600)

    def fetch(*a):
        return Snapshot("7.1", 10.0, 20.0, "1d", {"ether1": True, "ether2": False}), "abc"

    await ciclos(db, r, eng, [0], fetch=fetch)
    est = (await history.load_states(r))[mk]
    assert est["portas_link"] == {"ether1": True, "ether2": False}
    await ciclos(db, r, eng, [30], fetch=fetch_fail)
    assert (await history.load_states(r))[mk]["portas_link"] == {}


async def test_run_mapa_falha_numa_mk_nao_impede_outra(db, r):
    mk1 = await _mk_mapa(db, r)
    mk2 = await store.insert_mk(db, doc(nome="mk2", ip="10.0.0.2"))
    await history.save_state(r, mk2, {"status": "no_ar"})
    await store.salvar_inventario(db, mk2, {"redes": [{"rede": "203.0.113.0/24", "tunel": True}]}, T0)
    await store.registrar_ips(db, mk2, [{"ip": "203.0.113.5", "mac": None, "host_name": None, "fixo": True}], T0)
    orig = store.get_inventario

    async def get_inv(db_, mk_id):
        if mk_id == mk1:
            raise RuntimeError("boom")
        return await orig(db_, mk_id)

    store.get_inventario = get_inv
    try:
        async def ping(ip):
            return True
        await run_mapa(db, r, SET, T0, ping=ping)
    finally:
        store.get_inventario = orig
    assert (await history.load_aparelhos(r, mk2))["203.0.113.5"]["online"] is True


async def test_run_mapa_duas_rodadas_com_falha_viram_offline(db, r):
    mk = await _mk_mapa(db, r)
    await history.save_aparelhos(r, mk, {"192.0.2.5": {"online": True, "falhas": 0, "desde": T0.isoformat()}})

    async def ping(ip):
        return False

    await run_mapa(db, r, SET, T0, ping=ping)
    e = (await history.load_aparelhos(r, mk))["192.0.2.5"]
    assert e["online"] is True and e["falhas"] == 1
    await run_mapa(db, r, SET, T0 + timedelta(seconds=60), ping=ping)
    assert (await history.load_aparelhos(r, mk))["192.0.2.5"]["online"] is False


# --- switches (SNMP) ---

SEGREDO = "comunidade-secreta"
SW_SET = Settings("m", "r", KEY, "https://hook.example", None, "ref.example", snmp_communities=["x", SEGREDO])
LIDO = {"descr": "Switch X", "base_mac": "AA:BB:CC:00:00:99", "portas": {"Port1": {"up": True}},
        "fdb": {"AA:BB:CC:00:00:01": "Port1"}, "vizinhos": {}}


async def _mk_sw(db, r, status="no_ar", nome="mk1"):
    mk = await store.insert_mk(db, doc(nome=nome))
    await history.save_state(r, mk, {"status": status})
    await store.salvar_inventario(db, mk, {"redes": [
        {"rede": "192.0.2.0/24", "tunel": True}, {"rede": "198.51.100.0/24", "tunel": False}]}, T0)
    base = {"mac": "18:E8:29:00:00:01", "host_name": None, "fixo": False}
    await store.registrar_ips(db, mk, [
        {**base, "ip": "192.0.2.10"}, {**base, "ip": "192.0.2.11"}, {**base, "ip": "192.0.2.12"},
        {**base, "ip": "198.51.100.10"}], T0, {
        "192.0.2.10": {"fabricante": "Ubiquiti"}, "192.0.2.11": {"fabricante": "Outro"},
        "192.0.2.12": {"fabricante": "Ubiquiti"}, "198.51.100.10": {"fabricante": "Ubiquiti"}})
    await db.inventario_ips.update_one({"mk_id": mk, "ip": "192.0.2.12"},
                                       {"$set": {"ultimo_visto": T0 - timedelta(days=20)}})
    return mk


def fakes(achou=(SEGREDO, "Switch X"), ler_falha=False):
    chamadas = {"descobrir": [], "ler": []}

    async def descobrir(ip, communities):
        chamadas["descobrir"].append((ip, list(communities)))
        return achou

    async def ler(ip, community):
        chamadas["ler"].append((ip, community))
        if ler_falha if isinstance(ler_falha, bool) else ler_falha(community):
            raise snmp.SnmpErro("timeout")
        return LIDO

    return chamadas, descobrir, ler


async def test_switch_descoberto_vira_gerenciavel_com_community_cifrada(db, r):
    mk = await _mk_sw(db, r)
    ch, descobrir, ler = fakes()
    await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
    assert ch["descobrir"] == [("192.0.2.10", ["x", SEGREDO])]  # só o candidato em túnel, visto há pouco
    (sw,) = await store.listar_switches(db, mk)
    assert sw["ip"] == "192.0.2.10" and sw["gerenciavel"] is True and sw["fdb"] == LIDO["fdb"]
    assert sw["community_cifrada"] != SEGREDO and crypto.decrypt(sw["community_cifrada"], KEY) == SEGREDO
    assert SEGREDO not in json.dumps({k: v for k, v in sw.items() if k != "community_cifrada"}, default=str)
    assert sw["lido_em"] == T0 and sw["erro"] is None and sw["mac"] == "18:E8:29:00:00:01"
    ap = next(a for a in await store.listar_ips(db, mk) if a["ip"] == "192.0.2.10")
    assert ap["gerenciavel"] is True


async def test_switch_sem_resposta_nao_gerenciavel(db, r):
    mk = await _mk_sw(db, r)
    ch, descobrir, ler = fakes(achou=None)
    await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
    (sw,) = await store.listar_switches(db, mk)
    assert sw["gerenciavel"] is False and not sw.get("community_cifrada") and ch["ler"] == []
    assert sw["erro"] and SEGREDO not in sw["erro"]
    ap = next(a for a in await store.listar_ips(db, mk) if a["ip"] == "192.0.2.10")
    assert ap["gerenciavel"] is False


async def test_switch_mk_fora_do_ar_nao_le_e_mantem_doc(db, r):
    mk = await _mk_sw(db, r, status="offline")
    await store.salvar_switch(db, mk, "192.0.2.10", {"gerenciavel": True, "fdb": {"a": "b"}})
    ch, descobrir, ler = fakes()
    await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
    assert ch == {"descobrir": [], "ler": []}
    (sw,) = await store.listar_switches(db, mk)
    assert sw["fdb"] == {"a": "b"} and sw["gerenciavel"] is True


async def test_switch_segunda_rodada_usa_community_guardada(db, r):
    await _mk_sw(db, r)
    ch, descobrir, ler = fakes()
    await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
    ch2, descobrir2, ler2 = fakes()
    await run_switches(db, r, SW_SET, T0 + timedelta(minutes=10), descobrir=descobrir2, ler=ler2)
    assert ch2["descobrir"] == [] and ch2["ler"] == [("192.0.2.10", SEGREDO)]


async def test_switch_community_guardada_parou_volta_a_descobrir(db, r):
    mk = await _mk_sw(db, r)
    await store.salvar_switch(db, mk, "192.0.2.10", {
        "gerenciavel": True, "community_cifrada": crypto.encrypt("velha", KEY)})
    ch, descobrir, ler = fakes(ler_falha=lambda c: c == "velha")
    await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
    assert len(ch["descobrir"]) == 1 and ch["ler"] == [("192.0.2.10", "velha"), ("192.0.2.10", SEGREDO)]
    (sw,) = await store.listar_switches(db, mk)
    assert crypto.decrypt(sw["community_cifrada"], KEY) == SEGREDO and sw["erro"] is None


async def test_switch_community_cifrada_invalida_redescobre(db, r):
    mk = await _mk_sw(db, r)
    await store.salvar_switch(db, mk, "192.0.2.10", {"gerenciavel": True, "community_cifrada": "lixo"})
    ch, descobrir, ler = fakes()
    await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
    assert len(ch["descobrir"]) == 1 and ch["ler"] == [("192.0.2.10", SEGREDO)]


async def test_switch_ja_descoberto_sem_resposta_mantem_dados(db, r):
    mk = await _mk_sw(db, r)
    ch, descobrir, ler = fakes()
    await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
    ch, descobrir, ler = fakes(achou=None, ler_falha=True)  # timeout: nem a descoberta responde
    await run_switches(db, r, SW_SET, T0 + timedelta(minutes=10), descobrir=descobrir, ler=ler)
    (sw,) = await store.listar_switches(db, mk)
    assert sw["gerenciavel"] is True and sw["fdb"] == LIDO["fdb"] and sw["portas"] == LIDO["portas"]
    assert sw["erro"] == "Sem resposta SNMP" and SEGREDO not in sw["erro"]
    assert crypto.decrypt(sw["community_cifrada"], KEY) == SEGREDO
    ap = next(a for a in await store.listar_ips(db, mk) if a["ip"] == "192.0.2.10")
    assert ap["gerenciavel"] is True


async def test_switch_falha_depois_de_sucesso_mantem_lido_em(db, r):
    mk = await _mk_sw(db, r)
    _, descobrir, ler = fakes()
    await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
    depois = T0 + timedelta(minutes=10)
    for achou in (None, (SEGREDO, "Switch X")):  # nem descobre / descobre mas a leitura falha
        _, descobrir, ler = fakes(achou=achou, ler_falha=True)
        await run_switches(db, r, SW_SET, depois, descobrir=descobrir, ler=ler)
        (sw,) = await store.listar_switches(db, mk)
        assert sw["lido_em"] == T0 and sw["tentado_em"] == depois  # "dados de" = da última leitura boa
        assert sw["fdb"] == LIDO["fdb"] and sw["portas"] == LIDO["portas"] and sw["erro"] == "Sem resposta SNMP"


async def test_switch_que_nunca_leu_nao_tem_lido_em(db, r):
    mk = await _mk_sw(db, r)
    for achou in (None, (SEGREDO, "Switch X")):
        await db.switches.delete_many({})
        _, descobrir, ler = fakes(achou=achou, ler_falha=True)
        await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
        (sw,) = await store.listar_switches(db, mk)
        assert "lido_em" not in sw and sw["tentado_em"] == T0


async def test_camera_com_snmp_sem_bridge_nao_e_gerenciavel(db, r):
    mk = await _mk_sw(db, r)

    async def ler(ip, community):  # responde sysDescr, mas BRIDGE-MIB vazia
        return {"descr": "IP Camera", "base_mac": None, "portas": {}, "fdb": {}, "vizinhos": {}}

    _, descobrir, _ = fakes(achou=(SEGREDO, "IP Camera"))
    await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
    (sw,) = await store.listar_switches(db, mk)
    assert sw["gerenciavel"] is False and sw["erro"] == "Sem tabela de bridge"
    ap = next(a for a in await store.listar_ips(db, mk) if a["ip"] == "192.0.2.10")
    assert ap["gerenciavel"] is False
    # switch de verdade: base_mac ou portas bastam
    for parcial in ({"base_mac": "AA:BB:CC:00:00:99", "portas": {}}, {"base_mac": None}):
        async def ler_sw(ip, community, parcial=parcial):
            return {**LIDO, **parcial}
        await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler_sw)
        (sw,) = await store.listar_switches(db, mk)
        assert sw["gerenciavel"] is True and sw["erro"] is None


async def test_desmarcar_e_switch_desfaz_gerenciavel(db, r):
    mk = await _mk_sw(db, r)
    _, descobrir, ler = fakes()
    await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
    assert (await store.listar_switches(db, mk))[0]["gerenciavel"] is True
    await store.editar_aparelho(db, mk, "192.0.2.10", {"e_switch_manual": False})
    ch, descobrir, ler = fakes()
    await run_switches(db, r, SW_SET, T0 + timedelta(minutes=10), descobrir=descobrir, ler=ler)
    assert ch == {"descobrir": [], "ler": []}
    (sw,) = await store.listar_switches(db, mk)
    assert sw["gerenciavel"] is False
    ap = next(a for a in await store.listar_ips(db, mk) if a["ip"] == "192.0.2.10")
    assert ap["gerenciavel"] is False


async def test_switch_descoberto_mas_leitura_falha(db, r):
    mk = await _mk_sw(db, r)
    ch, descobrir, ler = fakes(ler_falha=True)
    await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
    (sw,) = await store.listar_switches(db, mk)
    assert sw["gerenciavel"] is True and sw["descr"] == "Switch X" and sw["erro"] == "Sem resposta SNMP"
    assert crypto.decrypt(sw["community_cifrada"], KEY) == SEGREDO


async def test_switch_falha_numa_mk_nao_impede_outra(db, r, caplog):
    mk1 = await _mk_sw(db, r)
    mk2 = await _mk_sw(db, r, nome="mk2")
    _, descobrir, ler = fakes()

    async def descobrir_boom(ip, communities):
        raise RuntimeError(SEGREDO)

    orig = store.listar_ips

    async def listar(db_, mk_id):
        if mk_id == mk1:
            raise RuntimeError("boom")
        return await orig(db_, mk_id)

    store.listar_ips = listar
    try:
        await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
    finally:
        store.listar_ips = orig
    assert await store.listar_switches(db, mk1) == []
    assert len(await store.listar_switches(db, mk2)) == 1
    await run_switches(db, r, SW_SET, T0, descobrir=descobrir_boom, ler=ler)  # nunca levanta
    assert SEGREDO not in caplog.text


async def test_apagar_inventario_apaga_switches(db):
    await store.salvar_switch(db, "m1", "192.0.2.10", {"gerenciavel": True})
    await store.salvar_switch(db, "m2", "192.0.2.10", {"gerenciavel": True})
    await store.apagar_inventario(db, "m1")
    assert await store.listar_switches(db, "m1") == []
    assert len(await store.listar_switches(db, "m2")) == 1


def test_settings_switches(monkeypatch):
    for k in ("MONGO_URL", "REDIS_URL", "SECRET_KEY", "WEBHOOK_URL", "REFERENCE_HOST"):
        monkeypatch.setenv(f"NODEBEAT_{k}", "x")
    monkeypatch.delenv("NODEBEAT_SNMP_COMMUNITIES", raising=False)
    monkeypatch.delenv("NODEBEAT_SWITCH_S", raising=False)
    s = config.load_settings()
    assert s.snmp_communities == ["public"] and s.switch_s == 600
    monkeypatch.setenv("NODEBEAT_SNMP_COMMUNITIES", " a , ,b ")
    monkeypatch.setenv("NODEBEAT_SWITCH_S", "120")
    s = config.load_settings()
    assert s.snmp_communities == ["a", "b"] and s.switch_s == 120
    monkeypatch.setenv("NODEBEAT_SNMP_COMMUNITIES", " , ")
    assert config.load_settings().snmp_communities == ["public"]
    for v in ("0", "abc"):
        monkeypatch.setenv("NODEBEAT_SWITCH_S", v)
        with pytest.raises(RuntimeError, match="NODEBEAT_SWITCH_S inválida"):
            config.load_settings()


# --- ligações aparelho -> (switch, porta) ---

async def test_registrar_ligacoes_grava_nao_limpa_nem_insere(db):
    await store.registrar_ips(db, "m1", [{"ip": "192.0.2.5", "mac": "AA:BB:CC:00:00:01"}], T0)
    await store.registrar_ligacoes(db, "m1", {"192.0.2.5": {"switch_ip": "192.0.2.10", "porta": "0/3"},
                                              "192.0.2.6": {"switch_ip": "192.0.2.10", "porta": "0/4"}})
    (ap,) = await store.listar_ips(db, "m1")  # 192.0.2.6 não existe: não cria
    assert ap["switch_ip"] == "192.0.2.10" and ap["switch_porta"] == "0/3"
    await store.registrar_ligacoes(db, "m1", {})
    (ap,) = await store.listar_ips(db, "m1")
    assert ap["switch_ip"] == "192.0.2.10" and ap["switch_porta"] == "0/3"


async def test_limpar_ligacoes_so_os_ips_da_mk(db):
    lig = {"192.0.2.5": {"switch_ip": "192.0.2.10", "porta": "0/3"},
           "192.0.2.6": {"switch_ip": "192.0.2.10", "porta": "0/4"}}
    for mk in ("m1", "m2"):
        await store.registrar_ips(db, mk, [{"ip": "192.0.2.5", "mac": "AA:BB:CC:00:00:01"},
                                           {"ip": "192.0.2.6", "mac": "AA:BB:CC:00:00:02"}], T0)
        await store.registrar_ligacoes(db, mk, lig)
    await store.limpar_ligacoes(db, "m1", {"192.0.2.5", "192.0.2.77"})  # 192.0.2.77 sem doc: nada
    await store.limpar_ligacoes(db, "m1", set())
    m1 = {a["ip"]: a for a in await store.listar_ips(db, "m1")}
    assert set(m1) == {"192.0.2.5", "192.0.2.6"}
    assert "switch_ip" not in m1["192.0.2.5"] and "switch_porta" not in m1["192.0.2.5"]
    assert m1["192.0.2.6"]["switch_ip"] == "192.0.2.10" and m1["192.0.2.6"]["switch_porta"] == "0/4"
    for a in await store.listar_ips(db, "m2"):  # outra MK, mesmo IP: intacta
        assert a["switch_ip"] == "192.0.2.10"


async def test_run_switches_limpa_ligacao_errada_da_raiz(db, r):
    # MK -> S1 (192.0.2.2, raiz) -> S2 (192.0.2.3); S1 tem o menor IP, então na leitura do
    # mapa o corte por maior IP derrubaria a ligação certa de S2 se a errada de S1 ficasse
    mk = await store.insert_mk(db, doc())
    await history.save_state(r, mk, {"status": "no_ar"})
    await store.salvar_inventario(db, mk, {"redes": [{"rede": "192.0.2.0/24", "tunel": True}]}, T0)
    m1, m2 = "18:E8:29:00:00:02", "18:E8:29:00:00:03"
    await store.registrar_ips(db, mk, [{"ip": "192.0.2.2", "mac": m1, "host_name": None, "fixo": False},
                                       {"ip": "192.0.2.3", "mac": m2, "host_name": None, "fixo": False}],
                              T0, {"192.0.2.2": {"fabricante": "Ubiquiti"}, "192.0.2.3": {"fabricante": "Ubiquiti"}})
    acima = {f"AA:BB:CC:00:01:{i:02X}": "0/1" for i in range(10)}  # o uplink de S2 aprende a rede acima
    fdb = {"192.0.2.2": {}, "192.0.2.3": {m1: "0/1", **acima}}

    async def ler(ip, community):
        return {**LIDO, "base_mac": None, "fdb": fdb[ip]}

    _, descobrir, _ = fakes()

    async def ligacoes():
        return {a["ip"]: (a.get("switch_ip"), a.get("switch_porta")) for a in await store.listar_ips(db, mk)}

    # 1ª: só S2 vê S1 (S1 ainda não aprendeu S2): sem ciclo, grava a ligação errada S1 -> (S2, 0/1)
    await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
    assert await ligacoes() == {"192.0.2.2": ("192.0.2.3", "0/1"), "192.0.2.3": (None, None)}
    # 2ª: os dois se veem: o corte deixa S1 raiz e a ligação errada some do doc
    fdb["192.0.2.2"] = {m2: "0/48"}
    await run_switches(db, r, SW_SET, T0 + timedelta(minutes=10), descobrir=descobrir, ler=ler)
    assert await ligacoes() == {"192.0.2.2": (None, None), "192.0.2.3": ("192.0.2.2", "0/48")}
    s1 = next(a for a in await store.listar_ips(db, mk) if a["ip"] == "192.0.2.2")
    assert "switch_ip" not in s1 and "switch_porta" not in s1
    # 3ª: ninguém conhece ninguém (tabelas esqueceram): não é corte, a ligação de S2 fica
    fdb.update({"192.0.2.2": {"AA:BB:CC:00:02:01": "0/5"}, "192.0.2.3": acima})
    await run_switches(db, r, SW_SET, T0 + timedelta(minutes=20), descobrir=descobrir, ler=ler)
    assert await ligacoes() == {"192.0.2.2": (None, None), "192.0.2.3": ("192.0.2.2", "0/48")}


async def _com_aparelho_no_fdb(db, mk):
    await store.registrar_ips(db, mk, [{"ip": "192.0.2.20", "mac": "aa:bb:cc:00:00:01", "host_name": None,
                                        "fixo": False}], T0, {"192.0.2.20": {"fabricante": "Outro"}})


async def test_run_switches_grava_ligacao_e_mantem_quando_some(db, r):
    mk = await _mk_sw(db, r)
    await _com_aparelho_no_fdb(db, mk)
    _, descobrir, ler = fakes()
    await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
    ap = next(a for a in await store.listar_ips(db, mk) if a["ip"] == "192.0.2.20")
    assert ap["switch_ip"] == "192.0.2.10" and ap["switch_porta"] == "Port1"

    async def ler_sem(ip, community):  # a tabela MAC esqueceu o aparelho
        return {**LIDO, "fdb": {"AA:BB:CC:00:00:77": "Port2"}}

    await run_switches(db, r, SW_SET, T0 + timedelta(minutes=10), descobrir=descobrir, ler=ler_sem)
    ap = next(a for a in await store.listar_ips(db, mk) if a["ip"] == "192.0.2.20")
    assert ap["switch_ip"] == "192.0.2.10" and ap["switch_porta"] == "Port1"


async def test_ligacoes_falha_numa_mk_nao_impede_outra(db, r, monkeypatch, caplog):
    from nodebeat import mapa
    mk1 = await _mk_sw(db, r)
    mk2 = await _mk_sw(db, r, nome="mk2")
    for mk in (mk1, mk2):
        await _com_aparelho_no_fdb(db, mk)
    orig = mapa.ligacoes_e_raizes
    chamadas = []

    def lig(sws, aps):
        chamadas.append(sws[0]["mk_id"])
        if sws[0]["mk_id"] == mk1:
            raise RuntimeError(SEGREDO)
        return orig(sws, aps)

    monkeypatch.setattr(mapa, "ligacoes_e_raizes", lig)
    _, descobrir, ler = fakes()
    await run_switches(db, r, SW_SET, T0, descobrir=descobrir, ler=ler)
    assert sorted(chamadas) == sorted([mk1, mk2])
    aps = {a["ip"]: a for a in await store.listar_ips(db, mk2)}
    assert aps["192.0.2.20"]["switch_ip"] == "192.0.2.10"
    assert "switch_ip" not in {a["ip"]: a for a in await store.listar_ips(db, mk1)}["192.0.2.20"]
    assert SEGREDO not in caplog.text


async def test_sem_ipsec_pinga_so_um_ip_e_nunca_vpn_caiu(db, r):
    id = await store.insert_mk(db, doc(ip="8.8.4.4", ip_publico="8.8.4.4", sem_ipsec=True))
    vistos = []

    async def ping(ip):
        vistos.append(ip)
        return ip == "8.8.4.4"

    await run_cycle(db, r, AlertEngine(), SET, T0, fetch=fetch_fail, ping=ping, reference_ok=sim_ok)
    assert vistos == ["8.8.4.4"]  # com IPsec seriam dois pings (túnel e público)
    assert (await history.load_states(r))[id]["status"] == "erro_acesso"


async def test_erro_acesso_nao_vai_para_o_webhook(db, r):
    id = await store.insert_mk(db, doc())
    eng = AlertEngine()
    for t in range(0, 121, 30):
        await run_cycle(db, r, eng, SET, T0 + timedelta(seconds=t), fetch=fetch_fail, ping=sim_ok, reference_ok=sim_ok)
    assert (await history.load_states(r))[id]["status"] == "erro_acesso"
    assert await r.llen(QUEUE) == 0


async def test_estado_da_mk_guarda_portas_fisicas_e_caiu(db, r):
    mk = await store.insert_mk(db, doc())
    eng = AlertEngine(recover_s=600)

    def fetch(ether2):
        return lambda *a: (Snapshot("7.1", 10.0, 20.0, "1d",
                                    {"ether1": True, "ether2": ether2, "bridge": True}), "abc")

    await ciclos(db, r, eng, [0], fetch=fetch(True))
    assert set((await history.load_states(r))[mk]["portas"]) == {"ether1", "ether2"}
    await ciclos(db, r, eng, [30], fetch=fetch(False))
    p2 = (await history.load_states(r))[mk]["portas"]
    assert p2["ether2"]["caiu_em"] == (T0 + timedelta(seconds=30)).isoformat()
    await ciclos(db, r, eng, [60], fetch=fetch_fail)
    assert (await history.load_states(r))[mk]["portas"] == p2
