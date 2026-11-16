from datetime import UTC, datetime

import fakeredis
import pytest
from httpx import ASGITransport, AsyncClient
from mongomock_motor import AsyncMongoMockClient

from nodebeat import auth, routeros, store
from nodebeat.api import create_app
from nodebeat.config import Settings
from tests.test_api_mks import KEY, MK, SENHA, criar

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


def doc(rede="10.30.0.0/24", tunel=True):
    return {"redes": [{"rede": rede, "origem": "address", "interface": "ether1", "tunel": tunel}],
            "ipsec": [], "pools": [{"nome": "p", "ranges": "192.168.1.10-192.168.1.20"}],
            "nat": [{"protocolo": "tcp", "dst_port": "8080", "to_addresses": "192.168.1.5", "to_ports": None,
                     "comentario": "", "ativo": True, "aberto": True}],
            "servicos": [{"nome": "ssh", "porta": 22, "ativo": True, "aberto": False}]}


async def test_exige_login(anon):
    assert (await anon.get("/api/faixas")).status_code == 401


async def test_faixas_lista_e_sobreposicao(client, db):
    a = await criar(client)
    b = await criar(client, nome="MK Sul", ip_tunel="10.8.0.3")
    await criar(client, nome="MK Vazia", ip_tunel="10.8.0.4")
    agora = datetime.now(UTC)
    await store.salvar_inventario(db, a, doc(), agora)
    await store.salvar_inventario(db, b, doc(), agora)
    body = (await client.get("/api/faixas")).json()
    assert [m["nome"] for m in body["mks"]] == ["MK Norte", "MK Sul", "MK Vazia"]
    assert len(body["sobreposicoes"]) == 1 and body["sede"] == ["10.1.0.0/16"]
    vazia = body["mks"][2]
    assert vazia["redes"] == [] and vazia["lido_em"] is None and vazia["desatualizado"] is True
    assert body["mks"][0]["desatualizado"] is False and isinstance(body["mks"][0]["lido_em"], str)


async def test_conferir_faixa_invalida_422(client):
    resp = await client.get("/api/faixas/conferir", params={"cidr": "lixo"})
    assert resp.status_code == 422 and resp.json() == {"detail": "Faixa inválida"}


async def test_conferir_faixa_usa_sede(client):
    body = (await client.get("/api/faixas/conferir", params={"cidr": "10.1.5.0/24"})).json()
    assert body["resultado"] == "em_uso"


async def test_pedido_atualizar_grava_redis(client, r):
    assert (await client.post("/api/faixas/atualizar")).status_code == 202
    assert await r.get("inventario:pedido") == "1"


async def test_inventario_vazio_e_cheio(client, db):
    id = await criar(client)
    vazio = (await client.get(f"/api/mks/{id}/inventario")).json()
    assert vazio == {"lido_em": None, "erro": None, "desatualizado": True,
                     "redes": [], "pools": [], "nat": [], "servicos": []}
    await store.salvar_inventario(db, id, doc(), datetime.now(UTC))
    body = (await client.get(f"/api/mks/{id}/inventario")).json()
    assert body["desatualizado"] is False and len(body["nat"]) == 1 and "ipsec" not in body


async def test_atualizar_mk_502_sem_vazar_senha(client, monkeypatch):
    id = await criar(client)

    def falha(*a, **k):
        raise routeros.RouterOsError("Login recusado (usuário ou senha)")
    monkeypatch.setattr(routeros, "fetch_inventario", falha)
    resp = await client.post(f"/api/mks/{id}/inventario/atualizar")
    assert resp.status_code == 502 and resp.json() == {"detalhe": "Login recusado (usuário ou senha)"}
    assert MK["senha"] not in resp.text


async def test_atualizar_mk_sucesso(client, monkeypatch):
    id = await criar(client)
    monkeypatch.setattr(routeros, "fetch_inventario", lambda *a, **k: {
        "address": [{"address": "192.168.5.1/24", "interface": "bridge"}]})
    resp = await client.post(f"/api/mks/{id}/inventario/atualizar")
    assert resp.status_code == 200 and resp.json()["redes"][0]["rede"] == "192.168.5.0/24"


async def test_conferir_porta_e_validacao(client, db):
    id = await criar(client)
    await store.salvar_inventario(db, id, doc(), datetime.now(UTC))
    url = f"/api/mks/{id}/portas/conferir"
    assert (await client.get(url, params={"porta": 0})).status_code == 422
    assert (await client.get(url, params={"porta": 80, "protocolo": "icmp"})).status_code == 422
    body = (await client.get(url, params={"porta": 8080})).json()
    assert body["resultado"] == "em_uso" and body["desatualizado"] is False


async def test_conferir_porta_sem_inventario(client):
    id = await criar(client)
    body = (await client.get(f"/api/mks/{id}/portas/conferir", params={"porta": 80})).json()
    assert body["resultado"] == "livre" and body["desatualizado"] is True


async def test_ips_em_uso_e_esquecer(client, db):
    id = await criar(client)
    await store.registrar_ips(db, id, [{"ip": "192.168.1.7", "mac": "AA", "host_name": "x", "fixo": False}],
                              datetime.now(UTC))
    lista = (await client.get(f"/api/mks/{id}/ips")).json()
    assert lista[0]["ip"] == "192.168.1.7" and lista[0]["em_uso"] is True
    assert isinstance(lista[0]["ultimo_visto"], str)
    assert (await client.delete(f"/api/mks/{id}/ips/192.168.1.7")).status_code == 204
    assert (await client.delete(f"/api/mks/{id}/ips/192.168.1.7")).status_code == 404


async def test_conferir_ip(client, db):
    id = await criar(client)
    await store.salvar_inventario(db, id, doc("192.168.1.0/24", False), datetime.now(UTC))
    await store.registrar_ips(db, id, [{"ip": "192.168.1.7", "fixo": False}], datetime.now(UTC))
    body = (await client.get(f"/api/mks/{id}/ips/conferir", params={"ip": "192.168.1.7"})).json()
    assert body["resultado"] == "em_uso" and body["desatualizado"] is False
    assert isinstance(body["visto"]["ultimo_visto"], str)
    resp = await client.get(f"/api/mks/{id}/ips/conferir", params={"ip": "x"})
    assert resp.status_code == 422 and resp.json() == {"detail": "IP inválido"}


async def test_apagar_mk_apaga_inventario(client, db):
    id = await criar(client)
    await store.salvar_inventario(db, id, doc(), datetime.now(UTC))
    await store.registrar_ips(db, id, [{"ip": "192.168.1.7", "fixo": False}], datetime.now(UTC))
    assert (await client.delete(f"/api/mks/{id}")).status_code == 204
    assert await store.get_inventario(db, id) is None and await store.listar_ips(db, id) == []


async def test_mk_inexistente_404(client):
    assert (await client.get("/api/mks/aaaaaaaaaaaaaaaaaaaaaaaa/inventario")).status_code == 404
