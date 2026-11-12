"""Login do painel: argon2, sessões em Redis (sess:<token>) e limite de tentativas."""
from __future__ import annotations

import secrets

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from fastapi import HTTPException, Request

from nodebeat import store

SESSAO_TTL = 8 * 3600
BLOQUEIO_TTL = 900
MAX_FALHAS = 5
COOKIE = "nodebeat_sess"

_ph = PasswordHasher()
_DUMMY = _ph.hash("nodebeat-dummy")  # verifica contra isto quando o usuário não existe (tempo igual)


class LoginFailed(Exception):
    pass


class TooManyAttempts(Exception):
    pass


def hash_password(p: str) -> str:
    return _ph.hash(p)


def verify_password(h: str, p: str) -> bool:
    try:
        return _ph.verify(h, p)
    except VerifyMismatchError:
        return False


async def login(db, r, usuario: str, senha: str) -> str:
    usuario = usuario.strip().lower()
    chave = f"login_fail:{usuario}"
    if int(await r.get(chave) or 0) >= MAX_FALHAS:
        raise TooManyAttempts
    u = await store.get_user(db, usuario)
    if not verify_password(u["senha_hash"] if u else _DUMMY, senha) or not u:
        if await r.incr(chave) == 1:
            await r.expire(chave, BLOQUEIO_TTL)
        raise LoginFailed
    await r.delete(chave)
    token = secrets.token_urlsafe(32)
    await r.set(f"sess:{token}", usuario, ex=SESSAO_TTL)
    return token


async def current_user(request: Request) -> dict:
    token = request.cookies.get(COOKIE)
    usuario = await request.app.state.r.get(f"sess:{token}") if token else None
    if not usuario:
        raise HTTPException(401, "Não autenticado")
    return {"usuario": usuario}
