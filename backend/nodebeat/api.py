"""App FastAPI do painel."""
from __future__ import annotations

import asyncio
import ipaddress
import json

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator

from nodebeat import auth, crypto, history, routeros, store, webhook

_COOKIE = {"path": "/api", "httponly": True, "secure": True, "samesite": "strict"}


class LoginIn(BaseModel):
    usuario: str
    senha: str


class MkIn(BaseModel):
    nome: str = Field(min_length=1, max_length=80)
    ip_tunel: str
    ip_publico: str
    usuario: str = Field(min_length=1)
    senha: str = ""

    @field_validator("nome")
    @classmethod
    def _nome(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("nome vazio")
        return v

    @field_validator("ip_tunel", "ip_publico")
    @classmethod
    def _ip(cls, v: str, info) -> str:
        ip = ipaddress.IPv4Address(v)  # ValueError -> 422
        if not (ip.is_private if info.field_name == "ip_tunel" else ip.is_global):
            raise ValueError("faixa de IP inválida")
        return v


class VigiadasIn(BaseModel):
    interfaces: list[str]

    @field_validator("interfaces")
    @classmethod
    def _ifaces(cls, v: list[str]) -> list[str]:
        if not all(v):
            raise ValueError("nome vazio")
        return list(dict.fromkeys(v))


FORA = {"offline", "vpn_caiu", "erro_acesso"}


def _alertas(mk: dict, st: dict) -> list[str]:
    out = []
    for campo, rotulo in (("cpu", "CPU alta"), ("mem", "Memória alta")):
        if (st.get(campo) or 0) > 80:
            out.append(f"{rotulo} ({round(st[campo])}%)")
    ifaces = st.get("ifaces") or {}
    out += [f"Interface {n} caída" for n in mk.get("interfaces_vigiadas") or [] if ifaces.get(n) is False]
    return out


def create_app(db, r, settings) -> FastAPI:
    app = FastAPI()
    app.state.db, app.state.r, app.state.settings = db, r, settings

    @app.exception_handler(RequestValidationError)
    async def _invalida(request: Request, exc: RequestValidationError) -> JSONResponse:
        return JSONResponse({"detail": "Requisição inválida"}, status_code=422)  # sem eco do corpo (senha)

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

    mks = APIRouter(prefix="/api", dependencies=[Depends(auth.current_user)])

    async def _achar(id: str) -> dict:
        mk = await store.get_mk(db, id)
        if not mk:
            raise HTTPException(404, "MK não encontrada")
        return mk

    async def _nome_livre(nome: str, ignorar: str | None = None) -> None:
        # ponytail: varre a coleção (dezenas de MKs); índice único com collation se crescer
        if any(m["nome"].casefold() == nome.casefold() and m["id"] != ignorar for m in await store.list_mks(db)):
            raise HTTPException(409, "Já existe uma MK com esse nome")

    @mks.get("/status")
    async def status() -> dict:
        estados = await history.load_states(r)
        resumo = {"no_ar": 0, "com_alerta": 0, "fora": 0}
        linhas = []
        for mk in await store.list_mks(db):
            st = estados.get(mk["id"])
            s = st["status"] if st else "aguardando"
            vig = mk.get("interfaces_vigiadas") or []
            alertas = _alertas(mk, st) if s == "no_ar" else []
            resumo["fora"] += s in FORA
            resumo["no_ar"] += s == "no_ar"
            resumo["com_alerta"] += bool(alertas)
            ifaces = (st or {}).get("ifaces") or {}
            linhas.append(({"id": mk["id"], "nome": mk["nome"], "status": s, "desde": (st or {}).get("desde"),
                            "cpu": (st or {}).get("cpu"), "mem": (st or {}).get("mem"),
                            "uptime": (st or {}).get("uptime"), "ifaces_ok": sum(ifaces.get(n) is True for n in vig),
                            "ifaces_total": len(vig), "alertas": alertas, "versao": (st or {}).get("versao")},
                           s in FORA))
        linhas.sort(key=lambda x: (not x[1], not x[0]["alertas"], x[0]["nome"].casefold()))
        eng = await r.get("engine")
        return {"resumo": resumo, "fila_pendente": await webhook.pending_count(r),
                "sede_ok": not (eng and json.loads(eng).get("frozen")), "mks": [x[0] for x in linhas]}

    @mks.post("/mks", status_code=201)
    async def criar(body: MkIn) -> dict:
        if not body.senha:
            raise HTTPException(422, "Requisição inválida")
        await _nome_livre(body.nome)
        doc = body.model_dump(exclude={"senha"}) | {
            "senha_cifrada": crypto.encrypt(body.senha, settings.secret_key),
            "cert_sha256": None, "interfaces_vigiadas": []}
        return {"id": await store.insert_mk(db, doc)}

    @mks.get("/mks/{id}")
    async def obter(id: str) -> dict:
        mk = await _achar(id)
        mk = {k: v for k, v in mk.items() if k in ("id", "nome", "ip_tunel", "ip_publico", "usuario",
                                                   "interfaces_vigiadas", "cert_sha256")}
        mk["estado"] = (await history.load_states(r)).get(id)
        return mk

    @mks.put("/mks/{id}", status_code=204)
    async def alterar(id: str, body: MkIn) -> Response:
        antigo = await _achar(id)
        await _nome_livre(body.nome, id)
        campos = body.model_dump(exclude={"senha"})
        if body.senha:
            campos["senha_cifrada"] = crypto.encrypt(body.senha, settings.secret_key)
        if body.ip_tunel != antigo["ip_tunel"]:
            campos["cert_sha256"] = None  # outro aparelho: o pin antigo não vale
        await store.update_mk(db, id, campos)
        return Response(status_code=204)

    @mks.delete("/mks/{id}", status_code=204)
    async def apagar(id: str) -> Response:
        await _achar(id)
        await store.delete_mk(db, id)
        await history.delete_mk(r, id)
        return Response(status_code=204)

    @mks.get("/mks/{id}/interfaces")
    async def interfaces(id: str):
        mk = await _achar(id)
        try:
            senha = crypto.decrypt(mk["senha_cifrada"], settings.secret_key)
            rows = await asyncio.to_thread(routeros.list_interfaces, mk["ip_tunel"], mk["usuario"], senha,
                                           mk.get("cert_sha256"))
        except routeros.RouterOsError as e:
            return JSONResponse({"detalhe": e.detalhe}, status_code=502)
        except Exception:  # nunca ecoar str(e): pode conter segredo
            return JSONResponse({"detalhe": "Resposta inesperada da API"}, status_code=502)
        return [{"nome": n, "running": run} for n, run in rows]

    @mks.put("/mks/{id}/interfaces-vigiadas", status_code=204)
    async def vigiar(id: str, body: VigiadasIn) -> Response:
        await _achar(id)
        await store.update_mk(db, id, {"interfaces_vigiadas": body.interfaces})
        return Response(status_code=204)

    @mks.post("/mks/{id}/aceitar-certificado", status_code=204)
    async def aceitar(id: str) -> Response:
        await _achar(id)
        await store.set_cert(db, id, None)
        return Response(status_code=204)

    @mks.get("/mks/{id}/historico")
    async def historico(id: str) -> list[dict]:
        await _achar(id)
        return await history.history(r, id)

    app.include_router(mks)
    return app
