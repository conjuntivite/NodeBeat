"""Login do painel: argon2, sessões em Redis (sess:<token>) e limite de tentativas."""
from __future__ import annotations

import asyncio
import secrets

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from fastapi import Depends, HTTPException, Request

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
    except (VerificationError, InvalidHashError):
        return False


async def login(db, r, usuario: str, senha: str) -> str:
    usuario = usuario.strip().lower()
    chave = f"login_fail:{usuario}"
    # conta a tentativa ANTES de verificar (atômico; INCR+EXPIRE na mesma transação)
    async with r.pipeline(transaction=True) as pipe:
        n = (await pipe.incr(chave).expire(chave, BLOQUEIO_TTL, nx=True).execute())[0]
    if n > MAX_FALHAS:
        raise TooManyAttempts
    u = await store.get_user(db, usuario)
    if not await asyncio.to_thread(verify_password, u["senha_hash"] if u else _DUMMY, senha) or not u:
        raise LoginFailed
    await r.delete(chave)
    token = secrets.token_urlsafe(32)
    async with r.pipeline(transaction=True) as pipe:
        pipe.set(f"sess:{token}", usuario, ex=SESSAO_TTL)
        pipe.sadd(f"sess_u:{usuario}", token)
        pipe.expire(f"sess_u:{usuario}", SESSAO_TTL)
        await pipe.execute()
    return token


async def encerrar_sessoes(r, usuario: str, manter: str | None = None) -> None:
    """Apaga as sessões do usuário, menos `manter`."""
    chave = f"sess_u:{usuario}"
    for t in await r.smembers(chave):
        if t != manter:
            await r.delete(f"sess:{t}")
            await r.srem(chave, t)


async def current_user(request: Request) -> dict:
    token = request.cookies.get(COOKIE)
    usuario = await request.app.state.r.get(f"sess:{token}") if token else None
    u = await store.get_user(request.app.state.db, usuario) if usuario else None
    if not u:
        raise HTTPException(401, "Não autenticado")
    return {"usuario": usuario, "admin": u.get("admin", True), "tema": u.get("tema"), "token": token}


async def admin_user(user: dict = Depends(current_user)) -> dict:
    if not user["admin"]:
        raise HTTPException(403, "Acesso restrito ao admin")
    return user
