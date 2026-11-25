import fakeredis
import pytest
from httpx import ASGITransport, AsyncClient
from mongomock_motor import AsyncMongoMockClient

from nodebeat import auth, store
from nodebeat.api import create_app
from nodebeat.config import Settings

SET = Settings("m", "r", "k", "https://hook.example", None, "ref.example")
SENHA = "senha-bem-longa-123"
NOVA = "outra-senha-longa-456"


@pytest.fixture
def db():
    return AsyncMongoMockClient()["nodebeat"]


@pytest.fixture
def r():
    return fakeredis.FakeAsyncRedis(decode_responses=True)


@pytest.fixture
def app(db, r):
    return create_app(db, r, SET)


def novo(app):
    return AsyncClient(transport=ASGITransport(app=app), base_url="https://test")


@pytest.fixture
async def client(db, app):
    # usuário legado: sem o campo admin (conta como admin)
    await db.users.insert_one({"usuario": "ana", "senha_hash": auth.hash_password(SENHA)})
    async with novo(app) as c:
        yield c


def entrar(c, usuario="ana", senha=SENHA):
    return c.post("/api/auth/login", json={"usuario": usuario, "senha": senha})


async def comum(app, db, nome="cadu"):
    await store.insert_user(db, nome, auth.hash_password(SENHA))
    c = novo(app)
    assert (await entrar(c, nome)).status_code == 204
    return c


async def test_tema_salvo_volta_no_me(client):
    await entrar(client)
    assert (await client.put("/api/auth/tema", json={"tema": "escuro"})).status_code == 204
    assert (await client.get("/api/auth/me")).json()["tema"] == "escuro"


async def test_tema_invalido_422(client):
    await entrar(client)
    assert (await client.put("/api/auth/tema", json={"tema": "azul"})).status_code == 422


async def test_troca_senha_atual_errada_400(client):
    await entrar(client)
    resp = await client.put("/api/auth/senha", json={"atual": "errada", "nova": NOVA})
    assert resp.status_code == 400
    assert resp.json() == {"detail": "Senha atual incorreta"}


async def test_troca_senha_curta_422(client):
    await entrar(client)
    resp = await client.put("/api/auth/senha", json={"atual": SENHA, "nova": "curta"})
    assert resp.status_code == 422
    assert resp.json()["detail"][0]["msg"] == "Mínimo de 12 caracteres"


async def test_troca_senha_derruba_outras_sessoes(client, app):
    await entrar(client)
    async with novo(app) as c2:
        await entrar(c2)
        assert (await client.put("/api/auth/senha", json={"atual": SENHA, "nova": NOVA})).status_code == 204
        assert (await c2.get("/api/auth/me")).status_code == 401
        assert (await client.get("/api/auth/me")).status_code == 200
        assert (await entrar(c2, senha=NOVA)).status_code == 204


async def test_comum_recebe_403_em_todas_rotas_usuarios(client, app, db):
    c = await comum(app, db)
    assert (await c.get("/api/usuarios")).status_code == 403
    assert (await c.post("/api/usuarios", json={"usuario": "x", "senha": SENHA})).status_code == 403
    assert (await c.put("/api/usuarios/ana", json={"admin": False})).status_code == 403
    assert (await c.delete("/api/usuarios/ana")).status_code == 403


async def test_admin_cria_lista_sem_hash(client):
    await entrar(client)
    resp = await client.post("/api/usuarios", json={"usuario": "  Bia ", "senha": SENHA})
    assert resp.status_code == 201 and resp.json() == {"usuario": "bia"}
    lista = (await client.get("/api/usuarios")).json()
    assert "senha_hash" not in str(lista)
    assert {k: lista[1][k] for k in ("usuario", "admin")} == {"usuario": "bia", "admin": False}


async def test_criar_repetido_409(client):
    await entrar(client)
    body = {"usuario": "bia", "senha": SENHA}
    await client.post("/api/usuarios", json=body)
    resp = await client.post("/api/usuarios", json={**body, "usuario": "BIA"})
    assert resp.status_code == 409 and resp.json() == {"detail": "Usuário já existe"}


async def test_redefinir_senha_derruba_sessoes_do_outro(client, app, db):
    c2 = await comum(app, db, "bia")
    await entrar(client)
    assert (await client.put("/api/usuarios/bia", json={"senha": NOVA})).status_code == 204
    assert (await c2.get("/api/auth/me")).status_code == 401
    assert (await entrar(c2, "bia", NOVA)).status_code == 204


async def test_nao_remove_a_si_mesmo_409(client):
    await entrar(client)
    for resp in (await client.delete("/api/usuarios/ana"),
                 await client.put("/api/usuarios/ana", json={"admin": False})):
        assert resp.status_code == 409
        assert resp.json() == {"detail": "Você não pode remover nem rebaixar a si mesmo"}


async def test_ultimo_admin_nao_rebaixa_409(client, db, monkeypatch):
    await entrar(client)
    await store.insert_user(db, "bia", auth.hash_password(SENHA), admin=True)

    async def um(_db):
        return 1

    monkeypatch.setattr(store, "contar_admins", um)  # corrida: o outro admin sumiu
    resp = await client.put("/api/usuarios/bia", json={"admin": False})
    assert resp.status_code == 409 and resp.json() == {"detail": "Precisa haver ao menos um admin"}
    assert (await client.delete("/api/usuarios/bia")).status_code == 409


async def test_contar_admins_conta_legado_sem_campo(client, db):
    await store.insert_user(db, "bia", auth.hash_password(SENHA))
    assert await store.contar_admins(db) == 1  # só a ana (sem campo admin)


async def test_remover_inexistente_404(client):
    await entrar(client)
    assert (await client.delete("/api/usuarios/fulano")).status_code == 404
    assert (await client.put("/api/usuarios/fulano", json={"admin": True})).status_code == 404


async def test_rota_normaliza_nome(client, db):
    await entrar(client)
    await store.insert_user(db, "bia", auth.hash_password(SENHA))
    assert (await client.delete("/api/usuarios/BIA")).status_code == 204
    assert await store.get_user(db, "bia") is None


async def test_logout_limpa_indice_de_sessoes(client, r):
    await entrar(client)
    await client.post("/api/auth/logout")
    assert await r.smembers("sess_u:ana") == set()


async def test_sessao_antiga_fora_do_indice_da_401(client, r):
    await r.set("sess:legado", "ana")
    client.cookies.set(auth.COOKIE, "legado")
    assert (await client.get("/api/auth/me")).status_code == 401


async def test_criado_em_sai_com_fuso(client):
    await entrar(client)
    await client.post("/api/usuarios", json={"usuario": "bia", "senha": SENHA})
    criado = (await client.get("/api/usuarios")).json()[1]["criado_em"]
    assert criado.endswith("Z") or criado.endswith("+00:00")


async def test_senha_curta_ao_criar_ou_editar_diz_minimo(client):
    await entrar(client)
    r1 = await client.post("/api/usuarios", json={"usuario": "bia", "senha": "curta"})
    r2 = await client.put("/api/usuarios/ana", json={"senha": "curta"})
    for resp in (r1, r2):
        assert resp.status_code == 422
        assert resp.json()["detail"][0]["msg"] == "Mínimo de 12 caracteres"


async def test_admin_trocando_propria_senha_mantem_sessao(client):
    await entrar(client)
    assert (await client.put("/api/usuarios/ana", json={"senha": NOVA})).status_code == 204
    assert (await client.get("/api/auth/me")).status_code == 200


async def test_troca_senha_com_usuario_removido_da_401(client, db):
    await entrar(client)
    real = store.get_user
    chamadas = 0

    async def some(db_, u):
        nonlocal chamadas
        chamadas += 1
        return await real(db_, u) if chamadas == 1 else None  # 1ª: current_user; 2ª: o handler

    import nodebeat.store as s
    s.get_user = some
    try:
        resp = await client.put("/api/auth/senha", json={"atual": SENHA, "nova": NOVA})
    finally:
        s.get_user = real
    assert resp.status_code == 401
