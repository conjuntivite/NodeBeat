from datetime import UTC, datetime, timedelta

import fakeredis
import pytest
from httpx import ASGITransport, AsyncClient
from mongomock_motor import AsyncMongoMockClient

from nodebeat import auth, store
from nodebeat.api import create_app
from nodebeat.config import Settings
from tests.test_api_mks import KEY, SENHA, criar

SET = Settings("m", "r", KEY, "https://hook.example", None, "ref.example", sede_redes=["10.1.0.0/16"])


@pytest.fixture
def db():
    return AsyncMongoMockClient()["nodebeat"]


@pytest.fixture
def r():
    return fakeredis.FakeAsyncRedis(decode_responses=True)


@pytest.fixture
async def anon(db, r):
    await store.insert_user(db, "ana", auth.hash_password(SENHA))
    app = create_app(db, r, SET)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="https://test") as c:
        yield c


@pytest.fixture
async def client(anon):
    await anon.post("/api/auth/login", json={"usuario": "ana", "senha": SENHA})
    return anon


def ev(mk_id, quando, tipo="login", msg="msg"):
    return {"mk_id": mk_id, "recebido_em": quando, "severidade": "info", "topicos": ["system"],
            "tipo": tipo, "campos": {}, "mensagem": msg}


async def test_exige_sessao(anon):
    assert (await anon.get("/api/mks/aaaaaaaaaaaaaaaaaaaaaaaa/eventos")).status_code == 401


async def test_mk_inexistente_404(client):
    assert (await client.get("/api/mks/aaaaaaaaaaaaaaaaaaaaaaaa/eventos")).status_code == 404


async def test_lista_e_filtros(client, db):
    id = await criar(client)
    t = datetime(2026, 1, 1, 12, tzinfo=UTC)
    await store.inserir_eventos(db, [ev(id, t, "login", "a"), ev(id, t + timedelta(hours=1), "config", "b"),
                                     ev(id, t + timedelta(hours=2), "ipsec", "c")])
    url = f"/api/mks/{id}/eventos"
    body = (await client.get(url)).json()
    assert [e["mensagem"] for e in body["eventos"]] == ["c", "b", "a"]
    assert "mk_id" not in body["eventos"][0] and body["eventos"][0]["recebido_em"].startswith("2026-01-01T14:00:00")
    body = (await client.get(url, params=[("tipo", "login"), ("tipo", "config")])).json()
    assert [e["mensagem"] for e in body["eventos"]] == ["b", "a"]
    assert len((await client.get(url, params={"limite": 1})).json()["eventos"]) == 1
    body = (await client.get(url, params={"ate": (t + timedelta(hours=1)).isoformat()})).json()
    assert [e["mensagem"] for e in body["eventos"]] == ["a"]


async def test_tipo_invalido_422(client):
    id = await criar(client)
    resp = await client.get(f"/api/mks/{id}/eventos", params={"tipo": "xyz"})
    assert resp.status_code == 422


async def test_q_com_regex_escapado(client, db):
    id = await criar(client)
    await store.inserir_eventos(db, [ev(id, datetime.now(UTC), msg="abc")])
    resp = await client.get(f"/api/mks/{id}/eventos", params={"q": ".*("})
    assert resp.status_code == 200 and resp.json()["eventos"] == []


async def test_syslog_ativo(client, db):
    id = await criar(client)
    url = f"/api/mks/{id}/eventos"
    assert (await client.get(url)).json()["syslog_ativo"] is False
    await store.inserir_eventos(db, [ev(id, datetime.now(UTC) - timedelta(hours=25))])
    assert (await client.get(url)).json()["syslog_ativo"] is False
    await store.inserir_eventos(db, [ev(id, datetime.now(UTC) - timedelta(hours=2))])
    assert (await client.get(url)).json()["syslog_ativo"] is True
