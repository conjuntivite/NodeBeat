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


async def test_resposta_traz_resumo_estado_das_quatro_categorias(client, db):
    id = await criar(client)
    await store.inserir_eventos(db, [falha(id, "203.0.113.9")])
    body = (await client.get("/api/eventos/painel")).json()
    assert set(body["resumo_estado"]) == {"acesso", "autenticacao", "vpn", "erros"}
    assert body["resumo_estado"]["acesso"] == {"estado": "esperado", "delta_pct": None}


def _historia_30d(agora):
    """Eventos espalhados em 30 dias, com as armadilhas de quem olha para trás: MK que só falou há 20 dias
    (silêncio), MK que começou há 15 dias (dias de base), usuário visto há 20 dias e de novo hoje (usuário novo)."""
    def ev(mk, tipo, msg, h, sev="info", campos=None):
        return {"mk_id": mk, "recebido_em": agora - timedelta(hours=h), "severidade": sev, "topicos": [],
                "tipo": tipo, "campos": campos or {}, "mensagem": msg}
    evs = []
    for h in range(1, 720, 7):
        evs.append(ev("a", "login_falha", f"login failure for user root from 203.0.113.{h % 50} via ssh", h + 0.3, "crit"))
        evs.append(ev("a", "interface", "ether3 link down", h + 0.5))
        if h % 3 == 0:
            evs.append(ev("a", "ipsec", "phase1 negotiation failed", h + 0.1, "err"))
        if h < 360:
            evs.append(ev("c", "erro", "algo falhou", h + 0.2, "err"))
    for h in (480, 490, 500):
        evs.append(ev("b", "pppoe", "x terminating... authentication failed", h))
    for h in (2, 240, 480):  # reboots correlacionados (incidente) em a, b, c
        for i, mk in enumerate("abc"):
            evs.append(ev(mk, "reboot", "router rebooted", h + i * 0.01, "crit"))
    for u, h in (("joao", 480), ("joao", 2), ("admin", 600), ("maria", 3), ("antigo", 690)):
        evs.append(ev("a", "config", f"item changed by {u}", h, campos={"usuario": u, "objeto": "ip", "acao": "changed"}))
    evs.append(ev("a", "login", "user admin logged in from 203.0.113.9 via ssh", 5,
                  campos={"usuario": "admin", "ip": "203.0.113.9", "via": "ssh"}))
    evs.append(ev("c", "login", "user ze logged in from 10.1.0.5 via winbox", 400,
                  campos={"usuario": "ze", "ip": "10.1.0.5", "via": "winbox"}))
    evs.append(ev("c", "login", "user ze logged in from 10.1.0.5 via winbox", 1,
                  campos={"usuario": "ze", "ip": "10.1.0.5", "via": "winbox"}))
    return evs


@pytest.mark.parametrize("periodo", ["24h", "7d", "30d"])
async def test_janela_reduzida_da_o_mesmo_painel_que_30_dias(db, periodo):
    from nodebeat import painel
    agora = datetime.now(UTC)
    await store.inserir_eventos(db, _historia_30d(agora))
    mks = [{"id": m, "nome": m.upper()} for m in "abc"]
    ctx = painel.Ctx(SET.sede_redes, SET.ips_publicos_sede, lambda ip: None)
    cheio = painel.montar(await store.listar_eventos_periodo(db, agora - timedelta(days=30)), mks, ctx, agora, periodo)
    reduzido = painel.montar(await painel_ler(db, agora, periodo), mks, ctx, agora, periodo)
    assert reduzido == cheio
    assert any(m["motivos"] for m in cheio["por_mk"])  # o cenário exercita as regras


async def painel_ler(db, agora, periodo):
    from nodebeat import api
    return await api.ler_eventos_painel(db, agora, periodo)


async def test_janela_reduzida_le_menos_que_30_dias(db):
    from nodebeat import api
    agora = datetime.now(UTC)
    await store.inserir_eventos(db, _historia_30d(agora))
    assert len(await api.ler_eventos_painel(db, agora, "24h")) < len(
        await store.listar_eventos_periodo(db, agora - timedelta(days=30))) / 2


async def test_chamadas_simultaneas_fazem_uma_leitura(client, db, monkeypatch):
    import asyncio
    await criar(client)
    original, leituras = store.listar_eventos_periodo, []

    async def contando(*a, **kw):
        leituras.append(1)
        await asyncio.sleep(0.05)
        return await original(*a, **kw)
    monkeypatch.setattr(store, "listar_eventos_periodo", contando)
    r1, r2 = await asyncio.gather(client.get("/api/eventos/painel"), client.get("/api/eventos/painel"))
    assert r1.status_code == r2.status_code == 200 and r1.json() == r2.json()
    assert len(leituras) == 1


def test_ttl_do_cache_maior_que_o_intervalo_da_tv():
    from nodebeat import api
    assert api.PAINEL_TTL > 60


def test_startup_precarrega_geoip(monkeypatch):
    import threading

    from fastapi.testclient import TestClient
    feito = threading.Event()
    monkeypatch.setattr("nodebeat.geoip.precarregar", feito.set)
    with TestClient(create_app(AsyncMongoMockClient()["nodebeat"], fakeredis.FakeAsyncRedis(), SET)):
        assert feito.wait(2)
