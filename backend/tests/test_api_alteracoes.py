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

    def __call__(self, cmd, **kw):  # gerador como o librouteros: so age quando consumido
        self.chamadas.append((cmd, kw))
        if cmd == PEER + "/set":
            self.address = kw["address"] + "/32"  # a MK guarda com /32
        if cmd == PEER + "/print":
            yield {".id": "*1", "name": "peer-ipsec", "address": self.address, "disabled": False}


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
    for ruim in ("192.168.88.1", "vpn.exemplo.com", "8.8.8.8/32"):
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


async def test_put_historico_avisa_nao_confirmado_e_policy(client, r, monkeypatch):
    id = await criar(client, senha_rw="rw-segredo-1")
    monkeypatch.setattr(routeros, "sessao", lambda *a, **kw: {"nome": "p1", "antigo": "9.9.9.9", "novo": "8.8.8.8",
                                                               "confirmado": False, "policies": [], "policies_erro": ["*5", "*6"]})
    assert (await client.put(f"/api/mks/{id}/ipsec/peers/*1", json={"endereco": "8.8.8.8"})).status_code == 200
    [h] = await history.history(r, id)
    assert h["detalhe"] == ("Peer IPsec p1: 9.9.9.9 → 8.8.8.8, por ana pelo IP público"
                            " (não confirmado) (policy *5, *6 não atualizada)")


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


async def test_put_falha_antes_de_escrever_502_sem_historico(client, r, monkeypatch):
    id = await criar(client, senha_rw="rw-segredo-1")

    def fake(*a, **kw):
        raise routeros.RouterOsError("Usuário nodebeat-rw sem permissão de escrita")
    monkeypatch.setattr(routeros, "sessao", fake)
    resp = await client.put(f"/api/mks/{id}/ipsec/peers/*1", json={"endereco": "8.8.8.8"})
    assert resp.status_code == 502 and "sem permissão" in resp.json()["detalhe"]
    assert await history.history(r, id) == []  # falhou antes de escrever


async def test_put_efetivamente_envia_set(client, sessao):
    id = await criar(client, senha_rw="rw-segredo-1")
    await client.put(f"/api/mks/{id}/ipsec/peers/*1", json={"endereco": "8.8.8.8"})
    assert (PEER + "/set", {".id": "*1", "address": "8.8.8.8"}) in sessao["api"].chamadas


async def test_falha_depois_de_escrever_registra(client, r, monkeypatch):
    id = await criar(client, senha_rw="rw-segredo-1")

    class Api(FakeApi):
        def __call__(self, cmd, **kw):
            if cmd == PEER + "/set":
                raise routeros.RouterOsError("Erro da API: x")
            yield from super().__call__(cmd, **kw)

    monkeypatch.setattr(routeros, "sessao", lambda host, user, password, pin, usar, porta=8729, timeout=10.0: usar(Api()))
    assert (await client.put(f"/api/mks/{id}/ipsec/peers/*1", json={"endereco": "8.8.8.8"})).status_code == 502
    [h] = await history.history(r, id)
    assert h["evento"] == "alteracao" and h["detalhe"].startswith("Falhou: ")


async def test_get_peers_usa_monitor(client, sessao):
    id = await criar(client, senha_rw="rw-segredo-1")
    resp = await client.get(f"/api/mks/{id}/ipsec/peers")
    assert resp.status_code == 200
    assert resp.json()["via"] == "tunel" and resp.json()["peers"][0]["endereco"] == "9.9.9.9"
    assert sessao["logins"] == [("10.8.0.2", "admin", "segredo-mk", 8729)]


# ---- portas liberadas ----
NAT = "/ip/firewall/nat"
PED = {"protocolo": "tcp", "porta_externa": 8080, "ip_interno": "192.168.88.50", "porta_interna": 80,
       "descricao": "DVR bloco B"}


class NatApi:
    def __init__(self):
        self.chamadas, self.regras = [], []

    def __call__(self, cmd, **kw):
        self.chamadas.append((cmd, kw))
        if cmd == NAT + "/print":
            yield from self.regras
        elif cmd == NAT + "/add":
            self.regras.append({".id": "*7", "disabled": False, "action": "dst-nat", "protocol": kw["protocol"],
                                "comment": kw["comment"], "dst-port": kw["dst-port"]})
            yield {"ret": "*7"}
        elif cmd == NAT + "/remove":
            self.regras = [x for x in self.regras if x[".id"] != kw[".id"]]
        elif cmd == "/ip/address/print":
            yield {"address": "8.8.4.4/30", "interface": "ether1"}
        elif cmd == "/interface/print":
            yield {"name": "ether1"}


@pytest.fixture
def nat_sessao(monkeypatch):
    api = NatApi()
    monkeypatch.setattr(routeros, "sessao", lambda host, user, password, pin, usar, porta=8729, timeout=10.0: usar(api))
    return api


async def test_post_sem_senha_rw_409(client, nat_sessao):
    id = await criar(client)
    resp = await client.post(f"/api/mks/{id}/portas-liberadas", json=PED)
    assert resp.status_code == 409 and resp.json() == {"detail": MSG_SEM_RW}


async def test_post_descricao_com_aspas_422(client, nat_sessao):
    id = await criar(client, senha_rw="rw-segredo-1")
    resp = await client.post(f"/api/mks/{id}/portas-liberadas", json=PED | {"descricao": 'a"b'})
    assert resp.status_code == 422


async def test_post_ip_fora_das_redes_422(client, db, nat_sessao):
    from datetime import UTC, datetime
    id = await criar(client, senha_rw="rw-segredo-1")
    await store.salvar_inventario(db, id, {"redes": [{"rede": "192.168.88.0/25", "origem": "address"}]},
                                  datetime.now(UTC))
    resp = await client.post(f"/api/mks/{id}/portas-liberadas", json=PED | {"ip_interno": "192.168.88.200"})
    assert resp.status_code == 422 and resp.json()["detail"] == "IP fora das redes da MK"


async def test_post_ip_da_propria_mk_422(client, db, nat_sessao):
    from datetime import UTC, datetime
    id = await criar(client, senha_rw="rw-segredo-1")
    await store.salvar_inventario(db, id, {"redes": [{"rede": "192.168.88.0/24", "origem": "address", "ip": "192.168.88.1"}]},
                                  datetime.now(UTC))
    resp = await client.post(f"/api/mks/{id}/portas-liberadas", json=PED | {"ip_interno": "192.168.88.1"})
    assert resp.status_code == 422 and resp.json()["detail"] == "IP é da própria MK"
    assert nat_sessao.chamadas == []


async def test_422_por_campo_tem_mensagem(client, nat_sessao):
    id = await criar(client, senha_rw="rw-segredo-1")
    resp = await client.post(f"/api/mks/{id}/portas-liberadas",
                             json=PED | {"descricao": "ação", "ip_interno": "8.8.8.8", "porta_externa": 0})
    msgs = {e["loc"][-1]: e["msg"] for e in resp.json()["detail"]}
    assert resp.status_code == 422 and "Valor inválido" not in msgs.values(), msgs
    assert set(msgs) == {"descricao", "ip_interno", "porta_externa"}
    resp = await client.put(f"/api/mks/{id}/ipsec/peers/*1", json={"endereco": "192.168.88.1"})
    assert resp.json()["detail"][0]["msg"] == "Use um IPv4 público"


async def test_post_ok_201_e_historico_delete_ok_e_inexistente(client, r, nat_sessao):
    id = await criar(client, senha_rw="rw-segredo-1")
    resp = await client.post(f"/api/mks/{id}/portas-liberadas", json=PED)
    assert resp.status_code == 201, resp.text
    b = resp.json()
    assert b["wan"] == "ether1" and b["regras"] == ["*7"] and b["via"] == "tunel"
    assert "Inventário desatualizado: confira o IP" in b["avisos"]
    assert "Se não abrir, confira o filtro forward da MK" in b["avisos"]
    assert (await client.get(f"/api/mks/{id}/portas-liberadas")).json()["liberacoes"][0]["descricao"] == "DVR bloco B"
    assert (await client.delete(f"/api/mks/{id}/portas-liberadas", params={"descricao": "DVR bloco B"})).status_code == 204
    assert (await client.delete(f"/api/mks/{id}/portas-liberadas", params={"descricao": "DVR bloco B"})).status_code == 404
    hist = [h["detalhe"] for h in await history.history(r, id)]
    assert "Porta tcp 8080 → 192.168.88.50:80 liberada (DVR bloco B), por ana pelo túnel" in hist
    assert "Porta liberada (DVR bloco B) removida, por ana" in hist


async def test_post_conflito_422(client, nat_sessao):
    id = await criar(client, senha_rw="rw-segredo-1")
    assert (await client.post(f"/api/mks/{id}/portas-liberadas", json=PED)).status_code == 201
    resp = await client.post(f"/api/mks/{id}/portas-liberadas", json=PED | {"descricao": "Outra"})
    assert resp.status_code == 422 and "em uso" in resp.json()["detail"]


class CaiApi(NatApi):
    def __init__(self, onde):
        super().__init__()
        self.onde, self.adds = onde, 0

    def __call__(self, cmd, **kw):
        if cmd == NAT + "/add":
            self.adds += 1
            if self.onde == "add" and self.adds == 2:
                raise OSError("caiu")
        if cmd == NAT + "/remove" and self.onde == "remove":
            raise OSError("caiu")
        yield from super().__call__(cmd, **kw)


@pytest.mark.parametrize("onde", ["add", "remove"])
async def test_queda_apos_escrever_502_com_historico_sem_outro_caminho(client, r, monkeypatch, onde):
    id = await criar(client, senha_rw="rw-segredo-1")
    api, logins = CaiApi(onde), []
    api.regras = [{".id": "*1", "comment": "nodebeat:DVR bloco B", "protocol": "tcp"}] if onde == "remove" else []

    def fake(host, user, password, pin, usar, porta=8729, timeout=10.0):
        logins.append(host)
        try:
            return usar(api)
        except OSError:  # como _com_api: queda vira SemConexao
            raise routeros.SemConexao("sem conexão")
    monkeypatch.setattr(routeros, "sessao", fake)
    if onde == "add":
        resp = await client.post(f"/api/mks/{id}/portas-liberadas", json=PED | {"protocolo": "ambos"})
    else:
        resp = await client.delete(f"/api/mks/{id}/portas-liberadas", params={"descricao": "DVR bloco B"})
    assert resp.status_code == 502 and "Conexão caiu" in resp.json()["detalhe"]
    assert len(logins) == 1
    assert any(h["detalhe"].startswith("Falhou:") for h in await history.history(r, id))
