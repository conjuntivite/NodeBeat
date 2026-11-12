import fakeredis
import pytest
from httpx import ASGITransport, AsyncClient
from mongomock_motor import AsyncMongoMockClient

from nodebeat import auth, cli, store
from nodebeat.api import create_app
from nodebeat.config import Settings

SET = Settings("m", "r", "k", "https://hook.example", None, "ref.example")
SENHA = "senha-bem-longa-123"


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
        yield c


def entrar(c, usuario="ana", senha=SENHA):
    return c.post("/api/auth/login", json={"usuario": usuario, "senha": senha})


async def test_login_sets_secure_cookie(client):
    resp = await entrar(client)
    assert resp.status_code == 204
    ck = resp.headers["set-cookie"].lower()
    assert ck.startswith("nodebeat_sess=")
    for attr in ("httponly", "secure", "samesite=strict", "path=/api", "max-age=28800"):
        assert attr in ck
    assert (await client.get("/api/auth/me")).json() == {"usuario": "ana"}


async def test_wrong_password_401(client):
    a = await entrar(client, senha="errada")
    b = await entrar(client, usuario="fulano", senha="errada")
    assert a.status_code == b.status_code == 401
    assert a.json() == b.json() == {"detail": "Usuário ou senha inválidos"}


async def test_login_rate_limited_after_5_failures(client):
    for _ in range(5):
        assert (await entrar(client, senha="errada")).status_code == 401
    resp = await entrar(client)
    assert resp.status_code == 429
    assert resp.json() == {"detail": "Muitas tentativas; aguarde 15 minutos"}


async def test_me_requires_session(client):
    assert (await client.get("/api/auth/me")).status_code == 401


async def test_logout_invalidates_session(client, r):
    await entrar(client)
    assert len(await r.keys("sess:*")) == 1
    assert (await client.post("/api/auth/logout")).status_code == 204
    assert await r.keys("sess:*") == []
    client.cookies.clear()
    assert (await client.get("/api/auth/me")).status_code == 401


async def test_password_stored_as_argon2(db):
    await store.insert_user(db, "bia", auth.hash_password(SENHA))
    assert (await store.get_user(db, "bia"))["senha_hash"].startswith("$argon2")


def test_cli_rejects_short_password():
    assert cli.main(["create-user", "ana"], getpass=lambda _: "curta") == 1
