import fakeredis
import pytest
from cryptography.fernet import Fernet
from httpx import ASGITransport, AsyncClient
from mongomock_motor import AsyncMongoMockClient

from nodebeat import auth, history, routeros, store
from nodebeat.api import create_app
from nodebeat.config import Settings

KEY = Fernet.generate_key().decode()
SET = Settings("m", "r", KEY, "https://hook.example", None, "ref.example")
SENHA = "senha-bem-longa-123"
MK = {"nome": "MK Norte", "ip_tunel": "10.8.0.2", "ip_publico": "8.8.4.4", "usuario": "admin", "senha": "segredo-mk"}
PEER = "/ip/ipsec/peer"
MSG_SEM_RW = ("Para alterar esta MK pelo NodeBeat, aplique o script 'permitir alterações' da página "
              "Preparar MK e preencha a senha no cadastro.")


@pytest.fixture
def db():
    return AsyncMongoMockClient()["nodebeat"]


@pytest.fixture
def r():
    return fakeredis.FakeAsyncRedis(decode_responses=True)


@pytest.fixture
async def client(db, r):
    await store.insert_user(db, "ana", auth.hash_password(SENHA))
    app = create_app(db, r, SET)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="https://test") as c:
        await c.post("/api/auth/login", json={"usuario": "ana", "senha": SENHA})
        yield c


class FakeApi:
    def __init__(self):
        self.chamadas = []
        self.address = "9.9.9.9"

    def __call__(self, cmd, **kw):
        self.chamadas.append((cmd, kw))
        if cmd == PEER + "/set":
            self.address = kw["address"]
        if cmd == PEER + "/print":
            return iter([{".id": "*1", "name": "peer-ipsec", "address": self.address, "disabled": "false"}])
        return iter([])


@pytest.fixture
def sessao(monkeypatch):
    visto = {"logins": [], "api": FakeApi()}

    def fake(host, user, password, pin, usar, porta=8729, timeout=10.0):
        visto["logins"].append((host, user, password, porta))
        return usar(visto["api"])
    monkeypatch.setattr(routeros, "sessao", fake)
    return visto


async def criar(c, **kw):
    resp = await c.post("/api/mks", json={**MK, **kw})
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


async def test_put_sem_senha_rw_409(client, sessao):
    id = await criar(client)
    resp = await client.put(f"/api/mks/{id}/ipsec/peers/*1", json={"endereco": "8.8.8.8"})
    assert resp.status_code == 409 and resp.json() == {"detail": MSG_SEM_RW}
    assert sessao["logins"] == []


async def test_put_ip_privado_422(client, sessao):
    id = await criar(client, senha_rw="rw-segredo-1")
    for ruim in ("192.168.1.1", "vpn.exemplo.com", "8.8.8.8/32"):
        resp = await client.put(f"/api/mks/{id}/ipsec/peers/*1", json={"endereco": ruim})
        assert resp.status_code == 422, ruim


async def test_put_ok_usa_publico_rw_e_historico(client, r, sessao):
    id = await criar(client, senha_rw="rw-segredo-1")
    resp = await client.put(f"/api/mks/{id}/ipsec/peers/*1", json={"endereco": "8.8.8.8"})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["via"] == "publico" and body["confirmado"] is True and body["novo"] == "8.8.8.8"
    assert sessao["logins"] == [("8.8.4.4", "nodebeat-rw", "rw-segredo-1", 8729)]
    [h] = await history.history(r, id)
    assert h["evento"] == "alteracao"
    assert h["detalhe"] == "Peer IPsec peer-ipsec: 9.9.9.9 → 8.8.8.8, por ana pelo IP público"


async def test_put_peer_inexistente_404(client, sessao):
    id = await criar(client, senha_rw="rw-segredo-1")
    resp = await client.put(f"/api/mks/{id}/ipsec/peers/*9", json={"endereco": "8.8.8.8"})
    assert resp.status_code == 404


async def test_put_igual_422(client, sessao):
    id = await criar(client, senha_rw="rw-segredo-1")
    resp = await client.put(f"/api/mks/{id}/ipsec/peers/*1", json={"endereco": "9.9.9.9"})
    assert resp.status_code == 422


async def test_put_mk_sem_ipsec_409(client, sessao):
    id = await criar(client, senha_rw="rw-segredo-1", sem_ipsec=True, ip_tunel="")
    resp = await client.put(f"/api/mks/{id}/ipsec/peers/*1", json={"endereco": "8.8.8.8"})
    assert resp.status_code == 409 and resp.json()["detail"] == "MK sem IPsec"


async def test_put_falha_vira_502_e_historico(client, r, monkeypatch):
    id = await criar(client, senha_rw="rw-segredo-1")

    def fake(*a, **kw):
        raise routeros.RouterOsError("Usuário nodebeat-rw sem permissão de escrita")
    monkeypatch.setattr(routeros, "sessao", fake)
    resp = await client.put(f"/api/mks/{id}/ipsec/peers/*1", json={"endereco": "8.8.8.8"})
    assert resp.status_code == 502 and "sem permissão" in resp.json()["detalhe"]
    [h] = await history.history(r, id)
    assert h["evento"] == "alteracao" and h["detalhe"].startswith("Falhou: ")


async def test_get_peers_usa_monitor(client, sessao):
    id = await criar(client, senha_rw="rw-segredo-1")
    resp = await client.get(f"/api/mks/{id}/ipsec/peers")
    assert resp.status_code == 200
    assert resp.json()["via"] == "tunel" and resp.json()["peers"][0]["endereco"] == "9.9.9.9"
    assert sessao["logins"] == [("10.8.0.2", "admin", "segredo-mk", 8729)]
