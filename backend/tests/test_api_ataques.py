from datetime import UTC, datetime

from nodebeat import api
from tests.test_api_mks import criar
from tests.test_api_painel import anon, client, db, r, falha  # noqa: F401


async def _ins(db, mk, ips):
    docs = [falha(mk, ip) for ip in ips]
    await db.eventos.insert_many(docs)


async def _mk(client):
    return await criar(client)


async def test_exige_login(anon):
    assert (await anon.get("/api/eventos/ataques")).status_code == 401


async def test_cursor_invalido(client):
    assert (await client.get("/api/eventos/ataques", params={"desde": "xyz"})).status_code == 400


async def test_primeira_chamada_so_cursor(client, db):
    assert (await client.get("/api/eventos/ataques")).json() == {"cursor": "", "ataques": [], "descartados": 0}
    mk = await _mk(client)
    await _ins(db, mk, ["203.0.113.5", "203.0.113.6"])
    ultimo = await db.eventos.find_one(sort=[("_id", -1)])
    j = (await client.get("/api/eventos/ataques")).json()
    assert j["ataques"] == [] and j["cursor"] == str(ultimo["_id"])


async def test_feed_traz_so_novos(client, db):
    mk = await _mk(client)
    await _ins(db, mk, ["203.0.113.1"])
    c = (await client.get("/api/eventos/ataques")).json()["cursor"]
    await _ins(db, mk, ["203.0.113.5", "203.0.113.6"])
    j = (await client.get("/api/eventos/ataques", params={"desde": c})).json()
    assert sorted(a["ip"] for a in j["ataques"]) == ["203.0.113.5", "203.0.113.6"]
    assert j["cursor"] != c and all(a["mk_nome"] for a in j["ataques"])
    assert (await client.get("/api/eventos/ataques", params={"desde": j["cursor"]})).json()["ataques"] == []


async def test_feed_cursor_em_rajada(client, db, monkeypatch):
    monkeypatch.setattr(api, "LIMITE_LEITURA", 3)
    mk = await _mk(client)
    c = (await client.get("/api/eventos/ataques")).json()["cursor"]
    ips = [f"203.0.113.{i}" for i in range(7)]
    await _ins(db, mk, ips)
    vistos = []
    for _ in range(3):
        j = (await client.get("/api/eventos/ataques", params={"desde": c})).json()
        vistos += [a["ip"] for a in j["ataques"]]
        c = j["cursor"]
    assert sorted(vistos) == ips
