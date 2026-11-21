from datetime import UTC, datetime, timedelta

import fakeredis
import pytest
from httpx import ASGITransport, AsyncClient
from mongomock_motor import AsyncMongoMockClient

from nodebeat import auth, store
from nodebeat.api import create_app
from nodebeat.config import Settings
from tests.test_api_mks import KEY, SENHA, criar

SET = Settings("m", "r", KEY, "https://hook.example", None, "ref.example",
               sede_redes=["10.1.0.0/16"], ips_publicos_sede=["198.51.100.7"])


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


def falha(mk_id, ip):
    return {"mk_id": mk_id, "recebido_em": datetime.now(UTC) - timedelta(minutes=10), "severidade": "crit",
            "topicos": ["system", "error", "critical"], "tipo": "login_falha", "campos": {},
            "mensagem": f"login failure for user root from {ip} via ssh"}


async def test_exige_login(anon):
    assert (await anon.get("/api/eventos/painel")).status_code == 401


async def test_periodo_invalido_422(client):
    assert (await client.get("/api/eventos/painel", params={"periodo": "1h"})).status_code == 422


async def test_mk_inexistente_404(client):
    assert (await client.get("/api/eventos/painel", params={"mk": "aaaaaaaaaaaaaaaaaaaaaaaa"})).status_code == 404


async def test_painel_vazio_200_com_estrutura(client):
    id = await criar(client)
    body = (await client.get("/api/eventos/painel")).json()
    assert body["resumo"] == {"acesso": 0, "autenticacao": 0, "vpn": 0, "erros": 0}
    assert [m["mk_id"] for m in body["por_mk"]] == [id]
    assert body["periodo"] == "24h"


async def test_classifica_com_sede_do_settings(client, db):
    id = await criar(client)
    await store.inserir_eventos(db, [falha(id, "203.0.113.9"), falha(id, "198.51.100.7")])
    body = (await client.get("/api/eventos/painel")).json()
    assert body["resumo"]["acesso"] == 1 and body["resumo"]["autenticacao"] == 1


async def test_filtro_mk(client, db):
    a = await criar(client)
    b = await criar(client, nome="Outra", ip_tunel="10.9.0.2")
    await store.inserir_eventos(db, [falha(a, "203.0.113.9"), falha(b, "203.0.113.9")])
    body = (await client.get("/api/eventos/painel", params={"mk": b})).json()
    assert [m["mk_id"] for m in body["por_mk"]] == [b]
    assert body["resumo"]["acesso"] == 1


async def test_cache_repete_a_resposta_dentro_do_ttl(client, db):
    id = await criar(client)
    antes = (await client.get("/api/eventos/painel")).json()
    await store.inserir_eventos(db, [falha(id, "203.0.113.9")])
    assert (await client.get("/api/eventos/painel")).json() == antes


async def test_cache_expira_e_chave_inclui_periodo_e_mk(client, db, monkeypatch):
    id = await criar(client)
    await client.get("/api/eventos/painel")
    await store.inserir_eventos(db, [falha(id, "203.0.113.9")])
    assert (await client.get("/api/eventos/painel", params={"periodo": "7d"})).json()["resumo"]["acesso"] == 1
    assert (await client.get("/api/eventos/painel", params={"mk": id})).json()["resumo"]["acesso"] == 1
    monkeypatch.setattr("nodebeat.api.PAINEL_TTL", 0)
    assert (await client.get("/api/eventos/painel")).json()["resumo"]["acesso"] == 1
