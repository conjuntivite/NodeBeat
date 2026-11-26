import asyncio
from datetime import UTC, datetime, timedelta

from nodebeat import api, painel, tv
from tests.test_api_mks import criar
from tests.test_api_painel import anon, client, db, r, falha  # noqa: F401


def login_ok(mk_id, ip):
    return {"mk_id": mk_id, "recebido_em": datetime.now(UTC) - timedelta(minutes=5), "severidade": "info",
            "topicos": ["system", "info", "account"], "tipo": "login",
            "campos": {"usuario": "admin", "ip": ip, "via": "ssh"},
            "mensagem": f"user admin logged in from {ip} via ssh"}


async def test_tv_ataques_so_campos_publicos(anon, client, db):
    mk = await criar(client)
    await db.eventos.insert_one(falha(mk, "203.0.113.1"))  # cursor vazio é recusado: precisa de um evento antes
    c = (await anon.get("/api/tv/ataques")).json()["cursor"]
    await db.eventos.insert_many([falha(mk, "203.0.113.5"), login_ok(mk, "203.0.113.9")])
    j = (await anon.get("/api/tv/ataques", params={"desde": c})).json()
    assert len(j["ataques"]) == 2
    for a in j["ataques"]:
        assert set(a) == set(tv.CAMPOS_ATAQUE)
        assert "usuario" not in a


async def test_tv_ataques_cursor_vazio_recusado(anon):
    assert (await anon.get("/api/tv/ataques", params={"desde": ""})).status_code == 400
    assert (await anon.get("/api/tv/ataques", params={"desde": "xyz"})).status_code == 400
    j = (await anon.get("/api/tv/ataques")).json()
    assert j["ataques"] == [] and "cursor" in j


async def test_tv_tops_campos_publicos(anon, client, db):
    mk = await criar(client)
    await db.eventos.insert_many([falha(mk, "203.0.113.5"), login_ok(mk, "203.0.113.9")])
    assert (await client.get("/api/eventos/painel")).status_code == 200
    j = (await anon.get("/api/tv/tops")).json()
    assert set(j) == {"total", "top_ips", "top_paises", "por_via", "logins_externos"}
    assert j["logins_externos"]
    for lg in j["logins_externos"]:
        assert set(lg) == set(tv.CAMPOS_LOGIN)
    assert all(set(i) == {"ip", "n", "pais", "pais_nome"} for i in j["top_ips"])


async def test_tv_tops_nao_espera_calculo(anon, monkeypatch):
    chamadas = []
    orig = painel.montar

    def espia(*a, **k):
        chamadas.append(1)
        return orig(*a, **k)

    monkeypatch.setattr(api.painel, "montar", espia)
    rs = await asyncio.gather(*[anon.get("/api/tv/tops") for _ in range(20)])
    assert all(x.status_code == 200 and x.json()["total"] == 0 for x in rs)
    for _ in range(100):  # espera a tarefa em segundo plano terminar
        if chamadas:
            await asyncio.sleep(0.05)
            break
        await asyncio.sleep(0.05)
    assert len(chamadas) == 1


async def test_tv_sem_sessao(anon, client):
    assert (await anon.get("/api/tv/ataques")).status_code == 200
    anonimo = (await anon.get("/api/tv/tops"))
    assert anonimo.status_code == 200
    assert (await client.get("/api/tv/tops")).json() == anonimo.json()


def test_tops_publicos_none():
    assert tv.tops_publicos(None) == {"total": 0, "top_ips": [], "top_paises": [], "por_via": {}, "logins_externos": []}
