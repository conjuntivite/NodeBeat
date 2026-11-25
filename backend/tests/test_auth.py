import asyncio

import fakeredis
import pytest
from fastapi import Depends
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
    # usuário legado: sem o campo admin (conta como admin)
    await db.users.insert_one({"usuario": "ana", "senha_hash": auth.hash_password(SENHA)})
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
    assert (await client.get("/api/auth/me")).status_code == 200


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


async def test_parallel_wrong_logins_are_limited(client):
    rs = await asyncio.gather(*(entrar(client, senha="errada") for _ in range(10)))
    assert sum(x.status_code != 429 for x in rs) <= 5


async def test_unknown_user_failures_count(client):
    for _ in range(5):
        await entrar(client, usuario="fulano", senha="x")
    assert (await entrar(client, usuario="fulano", senha="x")).status_code == 429


async def test_success_clears_counter(client):
    for _ in range(4):
        await entrar(client, senha="errada")
    assert (await entrar(client)).status_code == 204
    for _ in range(5):
        assert (await entrar(client, senha="errada")).status_code == 401


async def test_logout_deletes_cookie_with_path(client):
    await entrar(client)
    ck = (await client.post("/api/auth/logout")).headers["set-cookie"].lower()
    assert ck.startswith("nodebeat_sess=") and "path=/api" in ck and "max-age=0" in ck


async def test_422_does_not_echo_password(client):
    resp = await client.post("/api/auth/login", json={"senha": "segredo-vazado"})
    assert resp.status_code == 422 and "segredo-vazado" not in resp.text


def test_verify_password_corrupted_hash():
    assert auth.verify_password("lixo", "x") is False


async def test_me_traz_admin_e_tema(client):
    await entrar(client)
    j = (await client.get("/api/auth/me")).json()
    assert j == {"usuario": "ana", "admin": True, "tema": None}


async def test_usuario_removido_perde_sessao(client, db):
    await entrar(client)
    await store.apagar_user(db, "ana")
    assert (await client.get("/api/auth/me")).status_code == 401


async def test_login_indexa_sessao(client, r):
    await entrar(client)
    toks = await r.smembers("sess_u:ana")
    assert len(toks) == 1
    assert await r.exists(f"sess:{next(iter(toks))}")


async def test_encerrar_sessoes_mantem_uma(client, r):
    await entrar(client)
    t1 = next(iter(await r.smembers("sess_u:ana")))
    await entrar(client)
    assert len(await r.keys("sess:*")) == 2
    await auth.encerrar_sessoes(r, "ana", manter=t1)
    assert await r.keys("sess:*") == [f"sess:{t1}"]
    assert await r.smembers("sess_u:ana") == {t1}


async def test_admin_user_403(db, r):
    await store.insert_user(db, "bia", auth.hash_password(SENHA), admin=False)
    app = create_app(db, r, SET)
    app.get("/api/t")(lambda u=Depends(auth.admin_user): u["usuario"])
    async with AsyncClient(transport=ASGITransport(app=app), base_url="https://test") as c:
        await entrar(c, "bia")
        resp = await c.get("/api/t")
    assert resp.status_code == 403
    assert resp.json() == {"detail": "Acesso restrito ao admin"}


def test_cli_admin(db):
    senha = lambda _: SENHA
    assert cli.main(["create-user", "Zé", "--admin"], getpass=senha, db=db) == 0
    assert cli.main(["create-user", "Bia"], getpass=senha, db=db) == 0
    assert asyncio.run(store.get_user(db, "zé"))["admin"] is True
    assert asyncio.run(store.get_user(db, "bia"))["admin"] is False
