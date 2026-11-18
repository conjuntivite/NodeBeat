from datetime import UTC, datetime

import json

import fakeredis
import pytest
from cryptography.fernet import Fernet
from httpx import ASGITransport, AsyncClient
from mongomock_motor import AsyncMongoMockClient

from nodebeat import auth, crypto, history, routeros, store
from nodebeat.api import create_app
from nodebeat.config import Settings

KEY = Fernet.generate_key().decode()
SET = Settings("m", "r", KEY, "https://hook.example", None, "ref.example")
SENHA = "senha-bem-longa-123"
MK = {"nome": "MK Norte", "ip_tunel": "10.8.0.2", "ip_publico": "8.8.4.4", "usuario": "admin", "senha": "segredo-mk"}


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


async def criar(c, **kw):
    resp = await c.post("/api/mks", json={**MK, **kw})
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


def sem_senha(o):
    if isinstance(o, dict):
        return all("senha" not in k and sem_senha(v) for k, v in o.items())
    if isinstance(o, list):
        return all(sem_senha(v) for v in o)
    return True


async def test_create_and_get_never_returns_password(client, db):
    id = await criar(client)
    body = (await client.get(f"/api/mks/{id}")).json()
    assert body["nome"] == "MK Norte" and body["interfaces_vigiadas"] == [] and body["cert_sha256"] is None
    assert sem_senha(body) and sem_senha((await client.get("/api/status")).json())
    cifrada = (await store.get_mk(db, id))["senha_cifrada"]
    assert cifrada != MK["senha"] and crypto.decrypt(cifrada, KEY) == MK["senha"]
    assert "senha" not in json.dumps(body)


@pytest.mark.parametrize("campo,valor", [
    ("ip_tunel", "8.8.8.8"), ("ip_tunel", "127.0.0.1"), ("ip_tunel", "169.254.1.1"), ("ip_tunel", "0.0.0.0"), ("usuario", "  "), ("ip_publico", "192.168.0.1"), ("ip_publico", "abc"), ("nome", "  "),
    ("usuario", ""), ("senha", ""),
])
async def test_create_mk_rejects_bad_input(client, campo, valor):
    assert (await client.post("/api/mks", json={**MK, campo: valor})).status_code == 422


async def test_422_detail_per_field_without_echo(client):
    resp = await client.post("/api/mks", json={**MK, "ip_tunel": "8.8.8.8", "senha": "segredo-vazado"})
    assert resp.status_code == 422
    assert resp.json()["detail"] == [{"loc": ["body", "ip_tunel"], "msg": "Use o IP privado do túnel"}]
    assert "segredo-vazado" not in resp.text and "8.8.8.8" not in resp.text and "input" not in resp.text


async def test_422_empty_password_on_create_names_the_field(client):
    resp = await client.post("/api/mks", json={**MK, "senha": ""})
    assert resp.json()["detail"] == [{"loc": ["body", "senha"], "msg": "Campo obrigatório"}]


async def test_put_empty_password_keeps_old(client, db):
    id = await criar(client)
    antes = (await store.get_mk(db, id))["senha_cifrada"]
    resp = await client.put(f"/api/mks/{id}", json={**MK, "nome": "MK Sul", "senha": ""})
    assert resp.status_code == 204
    mk = await store.get_mk(db, id)
    assert mk["senha_cifrada"] == antes and mk["nome"] == "MK Sul"
    await client.put(f"/api/mks/{id}", json={**MK, "senha": "nova"})
    assert crypto.decrypt((await store.get_mk(db, id))["senha_cifrada"], KEY) == "nova"


async def test_put_new_tunnel_ip_clears_pin(client, db):
    id = await criar(client)
    await store.set_cert(db, id, "ab" * 32)
    await client.put(f"/api/mks/{id}", json={**MK, "senha": ""})
    assert (await store.get_mk(db, id))["cert_sha256"] == "ab" * 32
    await client.put(f"/api/mks/{id}", json={**MK, "ip_tunel": "10.8.0.9"})
    assert (await store.get_mk(db, id))["cert_sha256"] is None


async def test_status_summary_and_order(client, r):
    a = await criar(client, nome="Alfa", ip_tunel="10.8.1.1")
    b = await criar(client, nome="bravo", ip_tunel="10.8.1.2")
    c = await criar(client, nome="Charlie", ip_tunel="10.8.1.3")
    d = await criar(client, nome="Delta", ip_tunel="10.8.1.4")
    await client.put(f"/api/mks/{b}/interfaces-vigiadas", json={"interfaces": ["ether1", "ether2", "ether1"]})
    ok = {"detalhe": "", "desde": "2026-01-01T00:00:00+00:00", "uptime": "1d", "versao": "7.1"}
    await history.save_state(r, a, {**ok, "status": "no_ar", "cpu": 10, "mem": 20, "ifaces": {}})
    await history.save_state(r, b, {**ok, "status": "no_ar", "cpu": 80.5, "mem": 20,
                                    "ifaces": {"ether1": True, "ether2": False}})
    await history.save_state(r, c, {**ok, "status": "offline", "cpu": None, "mem": None, "ifaces": {}})
    await r.rpush("queue:webhook", "{}")
    body = (await client.get("/api/status")).json()
    assert body["resumo"] == {"no_ar": 1, "com_alerta": 1, "fora": 1}
    assert body["fila_pendente"] == 1 and body["sede_ok"] is True
    assert [m["nome"] for m in body["mks"]] == ["Charlie", "bravo", "Alfa", "Delta"]
    bravo = body["mks"][1]
    assert bravo["alertas"] == ["CPU alta (80,5%)", "Interface ether2 caída"]
    assert (bravo["ifaces_ok"], bravo["ifaces_total"]) == (1, 2)
    assert body["mks"][3]["status"] == "aguardando" and d == body["mks"][3]["id"]


async def test_status_sede_not_ok_when_engine_frozen(client, r):
    await r.set("engine", json.dumps({"frozen": True, "trackers": {}}))
    assert (await client.get("/api/status")).json()["sede_ok"] is False


async def test_delete_removes_history(client, r):
    id = await criar(client)
    await r.zadd(f"hist:{id}", {json.dumps({"x": 1}): 9_999_999_999})
    await history.save_state(r, id, {"status": "offline"})
    assert (await client.delete(f"/api/mks/{id}")).status_code == 204
    assert await r.keys(f"*{id}") == []
    assert (await client.get(f"/api/mks/{id}")).status_code == 404


async def test_historico_returns_events(client, r):
    id = await criar(client)
    await r.zadd(f"hist:{id}", {json.dumps({"tipo": "offline"}): 9_999_999_999})
    assert (await client.get(f"/api/mks/{id}/historico")).json() == [{"tipo": "offline"}]


async def test_interfaces_ok_and_error_returns_502(client, monkeypatch):
    id = await criar(client)
    visto = {}

    def ok(host, user, pw, pin):
        visto["args"] = (host, user, pw, pin)
        return [("ether1", True)]

    monkeypatch.setattr(routeros, "list_interfaces", ok)
    resp = await client.get(f"/api/mks/{id}/interfaces")
    assert resp.json() == [{"nome": "ether1", "running": True}]
    assert visto["args"] == ("10.8.0.2", "admin", "segredo-mk", None)

    def falha(*a):
        raise routeros.RouterOsError("certificado mudou")

    monkeypatch.setattr(routeros, "list_interfaces", falha)
    resp = await client.get(f"/api/mks/{id}/interfaces")
    assert resp.status_code == 502 and resp.json() == {"detalhe": "certificado mudou"}

    def estranho(*a):
        raise RuntimeError("segredo-mk")

    monkeypatch.setattr(routeros, "list_interfaces", estranho)
    resp = await client.get(f"/api/mks/{id}/interfaces")
    assert resp.status_code == 502 and "segredo-mk" not in resp.text
    assert resp.json() == {"detalhe": "Resposta inesperada da API"}


async def test_accept_certificate_clears_pin(client, db):
    id = await criar(client)
    await store.set_cert(db, id, "ab" * 32)
    assert (await client.post(f"/api/mks/{id}/aceitar-certificado")).status_code == 204
    assert (await store.get_mk(db, id))["cert_sha256"] is None


async def test_duplicate_name_409(client):
    id = await criar(client, nome="Alfa")
    resp = await client.post("/api/mks", json={**MK, "nome": " alfa "})
    assert resp.status_code == 409 and resp.json() == {"detail": "Já existe uma MK com esse nome"}
    outro = await criar(client, nome="Beta", ip_tunel="10.8.0.3")
    assert (await client.put(f"/api/mks/{outro}", json={**MK, "nome": "ALFA"})).status_code == 409
    assert (await client.put(f"/api/mks/{id}", json={**MK, "nome": "ALFA"})).status_code == 204


async def test_unknown_id_404(client):
    for id in ("nao-e-oid", "0" * 24):
        for m, p, kw in [("get", "", {}), ("put", "", {"json": MK}), ("delete", "", {}),
                         ("get", "/interfaces", {}), ("put", "/interfaces-vigiadas", {"json": {"interfaces": ["a"]}}),
                         ("post", "/aceitar-certificado", {}), ("get", "/historico", {})]:
            assert (await client.request(m, f"/api/mks/{id}{p}", **kw)).status_code == 404, (m, p)


async def test_routes_require_auth(anon):
    id = "0" * 24
    for m, p in [("get", "/api/status"), ("get", f"/api/mks/{id}"), ("post", "/api/mks"), ("put", f"/api/mks/{id}"),
                 ("delete", f"/api/mks/{id}"), ("get", f"/api/mks/{id}/interfaces"),
                 ("put", f"/api/mks/{id}/interfaces-vigiadas"), ("post", f"/api/mks/{id}/aceitar-certificado"),
                 ("get", f"/api/mks/{id}/historico")]:
        assert (await anon.request(m, p, json={})).status_code == 401, (m, p)


async def test_status_dados_ok_follows_worker_heartbeat(client, r):
    assert (await client.get("/api/status")).json()["dados_ok"] is False
    await r.set("worker:vivo", "1", ex=90)
    assert (await client.get("/api/status")).json()["dados_ok"] is True


async def test_delete_via_api_makes_worker_forget_trackers(client, db, r):
    from datetime import UTC, datetime, timedelta

    from nodebeat.rules import AlertEngine
    from nodebeat.worker import run_cycle

    async def nao(_):
        return False

    async def sim(_):
        return True

    def falha(*a):
        raise routeros.RouterOsError("sem resposta")

    id = await criar(client)
    eng, t0 = AlertEngine(), datetime(2026, 1, 1, tzinfo=UTC)
    await run_cycle(db, r, eng, SET, t0, fetch=falha, ping=nao, reference_ok=sim)
    assert eng.dump()["trackers"]
    assert (await client.delete(f"/api/mks/{id}")).status_code == 204
    await run_cycle(db, r, eng, SET, t0 + timedelta(seconds=30), fetch=falha, ping=nao, reference_ok=sim)
    assert eng.dump()["trackers"] == {}


async def test_422_public_ip_range_message(client):
    resp = await client.post("/api/mks", json={**MK, "ip_publico": "192.168.0.1"})
    assert resp.json()["detail"] == [{"loc": ["body", "ip_publico"], "msg": "Use o IP público fixo"}]


def _reboot_fake(monkeypatch, *respostas):
    """Cada chamada a routeros.reboot consome uma resposta: None (ok) ou uma exceção."""
    hosts, fila = [], list(respostas)

    def reboot(host, *a):
        hosts.append(host)
        r = fila.pop(0)
        if r is not None:
            raise r
    monkeypatch.setattr(routeros, "reboot", reboot)
    return hosts


async def test_reiniciar_pelo_tunel(client, r, monkeypatch):
    id = await criar(client)
    visto = {}
    monkeypatch.setattr(routeros, "reboot", lambda *a: visto.setdefault("args", a))
    resp = await client.post(f"/api/mks/{id}/reiniciar")
    assert resp.status_code == 200 and resp.json() == {"via": "tunel"}
    assert visto["args"] == ("10.8.0.2", "admin", "segredo-mk", None)
    assert 0 < await r.ttl(f"reinicio:{id}") <= 300
    [h] = await history.history(r, id)
    assert h["evento"] == "reinicio" and h["detalhe"] == "Solicitado por ana"


async def test_reiniciar_cai_no_publico(client, r, monkeypatch):
    id = await criar(client)
    hosts = _reboot_fake(monkeypatch, routeros.SemConexao("API sem resposta (timeout)"), None)
    resp = await client.post(f"/api/mks/{id}/reiniciar")
    assert resp.status_code == 200 and resp.json() == {"via": "publico"}
    assert hosts == ["10.8.0.2", "8.8.4.4"]
    assert await r.exists(f"reinicio:{id}")
    [h] = await history.history(r, id)
    assert h["detalhe"] == "Solicitado por ana pelo IP público"


async def test_reiniciar_login_recusado_nao_tenta_publico(client, r, monkeypatch):
    id = await criar(client)
    hosts = _reboot_fake(monkeypatch, routeros.RouterOsError("Login recusado (usuário ou senha)"))
    resp = await client.post(f"/api/mks/{id}/reiniciar")
    assert resp.status_code == 502 and resp.json() == {"detalhe": "Login recusado (usuário ou senha)"}
    assert hosts == ["10.8.0.2"]
    assert not await r.exists(f"reinicio:{id}")


async def test_reiniciar_dois_caminhos_falham(client, r, monkeypatch):
    id = await criar(client)
    _reboot_fake(monkeypatch, routeros.SemConexao("API sem resposta (timeout)"),
                 routeros.SemConexao("Conexão com a API recusada"))
    resp = await client.post(f"/api/mks/{id}/reiniciar")
    assert resp.status_code == 502
    assert resp.json() == {"detalhe": "Túnel: API sem resposta (timeout). IP público: Conexão com a API recusada"}
    assert not await r.exists(f"reinicio:{id}")


async def test_reiniciar_sem_ip_publico_so_tunel(client, db, monkeypatch):
    id = await criar(client)
    await store.update_mk(db, id, {"ip_publico": ""})
    hosts = _reboot_fake(monkeypatch, routeros.SemConexao("API sem resposta (timeout)"))
    resp = await client.post(f"/api/mks/{id}/reiniciar")
    assert resp.status_code == 502 and resp.json() == {"detalhe": "API sem resposta (timeout)"}
    assert hosts == ["10.8.0.2"]


async def test_reiniciar_publico_excecao_inesperada(client, monkeypatch):
    id = await criar(client)
    _reboot_fake(monkeypatch, routeros.SemConexao("API sem resposta (timeout)"), ValueError("segredo"))
    resp = await client.post(f"/api/mks/{id}/reiniciar")
    assert resp.status_code == 502 and resp.json() == {"detalhe": "Resposta inesperada da API"}
    assert "segredo" not in resp.text


async def test_reiniciar_falha_devolve_502_sem_janela(client, r, monkeypatch):
    id = await criar(client)
    _reboot_fake(monkeypatch, routeros.RouterOsError("Usuário da MK sem permissão de reinício"))
    resp = await client.post(f"/api/mks/{id}/reiniciar")
    assert resp.status_code == 502 and resp.json() == {"detalhe": "Usuário da MK sem permissão de reinício"}
    assert not await r.exists(f"reinicio:{id}")


async def test_preparar_mk_devolve_ips(db, r):
    from dataclasses import replace
    app = create_app(db, r, replace(SET, ip_origem="10.9.9.9", ips_publicos_sede=["203.0.113.5", "198.51.100.7"]))
    await store.insert_user(db, "ana", auth.hash_password(SENHA))
    async with AsyncClient(transport=ASGITransport(app=app), base_url="https://test") as c:
        await c.post("/api/auth/login", json={"usuario": "ana", "senha": SENHA})
        assert (await c.get("/api/preparar-mk")).json() == {"ip_origem": "10.9.9.9", "ips_publicos_sede": ["203.0.113.5", "198.51.100.7"]}


async def test_preparar_mk_sem_env_devolve_null(client):
    assert (await client.get("/api/preparar-mk")).json() == {"ip_origem": None, "ips_publicos_sede": []}


async def test_preparar_mk_exige_login(anon):
    assert (await anon.get("/api/preparar-mk")).status_code == 401


async def test_ip_tunel_fora_da_faixa_privada_so_nas_redes_extra(db, r):
    from dataclasses import replace
    app = create_app(db, r, replace(SET, redes_tunel_extra=["172.32.0.0/22"]))
    await store.insert_user(db, "ana", auth.hash_password(SENHA))
    async with AsyncClient(transport=ASGITransport(app=app), base_url="https://test") as c:
        await c.post("/api/auth/login", json={"usuario": "ana", "senha": SENHA})
        resp = await c.post("/api/mks", json={**MK, "ip_tunel": "172.32.0.1"})
        assert resp.status_code == 201
        id = resp.json()["id"]
        assert (await c.put(f"/api/mks/{id}", json={**MK, "ip_tunel": "172.32.3.254"})).status_code == 204
        for ruim in ("172.32.4.1", "8.8.8.8"):
            for resp in (await c.post("/api/mks", json={**MK, "nome": "Outra", "ip_tunel": ruim}),
                         await c.put(f"/api/mks/{id}", json={**MK, "ip_tunel": ruim})):
                assert resp.status_code == 422
                assert resp.json()["detail"] == [{"loc": ["body", "ip_tunel"], "msg": "Use o IP privado do túnel"}]


async def test_ip_tunel_repetido_recusado(client):
    a = await criar(client)
    b = await criar(client, nome="MK Sul", ip_tunel="10.8.0.3")
    esperado = [{"loc": ["body", "ip_tunel"], "msg": "Já existe uma MK com esse IP do túnel"}]
    resp = await client.post("/api/mks", json={**MK, "nome": "Outra"})
    assert resp.status_code == 422 and resp.json()["detail"] == esperado
    resp = await client.put(f"/api/mks/{b}", json={**MK, "nome": "MK Sul"})
    assert resp.status_code == 422 and resp.json()["detail"] == esperado
    assert (await client.put(f"/api/mks/{a}", json=MK)).status_code == 204


async def test_apagar_mk_apaga_eventos(client, db):
    id = await criar(client)
    await store.inserir_eventos(db, [{"mk_id": id, "recebido_em": datetime(2026, 1, 1, tzinfo=UTC),
                                      "severidade": "info", "topicos": [], "tipo": "x", "campos": {}, "mensagem": "m"}])
    assert (await client.delete(f"/api/mks/{id}")).status_code == 204
    assert await store.listar_eventos(db, id) == []
