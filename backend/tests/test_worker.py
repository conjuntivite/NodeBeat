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
from nodebeat.worker import load_engine, run_cycle

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
    await store.insert_mk(db, doc())
    await ciclos(db, r, AlertEngine(), range(0, 121, 30), fetch=fetch_fail)
    eng = AlertEngine.load(json.loads(await r.get("engine")))
    await ciclos(db, r, eng, [150, 180, 240], fetch=fetch_ok)
    fila = [json.loads(x) for x in await r.lrange(QUEUE, 0, -1)]
    assert [p["evento"] for p in fila] == ["queda", "retorno"]


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
