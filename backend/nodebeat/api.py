"""App FastAPI do painel."""
from __future__ import annotations

from fastapi import Depends, FastAPI, HTTPException, Request, Response
from pydantic import BaseModel

from nodebeat import auth

_COOKIE = {"path": "/api", "httponly": True, "secure": True, "samesite": "strict"}


class LoginIn(BaseModel):
    usuario: str
    senha: str


def create_app(db, r, settings) -> FastAPI:
    app = FastAPI()
    app.state.db, app.state.r, app.state.settings = db, r, settings

    @app.post("/api/auth/login", status_code=204)
    async def login(body: LoginIn) -> Response:
        try:
            token = await auth.login(db, r, body.usuario, body.senha)
        except auth.TooManyAttempts:
            raise HTTPException(429, "Muitas tentativas; aguarde 15 minutos")
        except auth.LoginFailed:
            raise HTTPException(401, "Usuário ou senha inválidos")
        resp = Response(status_code=204)
        resp.set_cookie(auth.COOKIE, token, max_age=auth.SESSAO_TTL, **_COOKIE)
        return resp

    @app.post("/api/auth/logout", status_code=204)
    async def logout(request: Request) -> Response:
        token = request.cookies.get(auth.COOKIE)
        if token:
            await r.delete(f"sess:{token}")
        resp = Response(status_code=204)
        resp.delete_cookie(auth.COOKIE, **_COOKIE)
        return resp

    @app.get("/api/auth/me")
    async def me(user: dict = Depends(auth.current_user)) -> dict:
        return user

    return app
