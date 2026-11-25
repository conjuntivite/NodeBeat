"""App FastAPI do painel."""
from __future__ import annotations

import asyncio
import ipaddress
import json
import re
import time
from datetime import UTC, datetime, timedelta
from typing import Literal

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Query, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator
from pymongo.errors import DuplicateKeyError

from nodebeat import auth, cli, crypto, eventos, history, inventario, mapa, painel, routeros, store, switch_painel, unifi, webhook, worker
from nodebeat.rules import LIMITE, Event, MkRef, _pct

PAINEL_TTL = 60  # s: o painel relê 30 dias de eventos; o cache poupa isso a cada troca de filtro
_COOKIE = {"path": "/api", "httponly": True, "secure": True, "samesite": "strict"}


class LoginIn(BaseModel):
    usuario: str
    senha: str


class TemaIn(BaseModel):
    tema: Literal["claro", "escuro"]


class SenhaIn(BaseModel):
    atual: str
    nova: str = Field(min_length=cli.MIN_SENHA)


class UsuarioIn(BaseModel):
    usuario: str = Field(min_length=1)
    senha: str = Field(min_length=cli.MIN_SENHA)
    admin: bool = False

    @field_validator("usuario")
    @classmethod
    def _norm(cls, v: str) -> str:
        v = v.strip().lower()
        if not v:
            raise ValueError("vazio")
        return v


class UsuarioPatch(BaseModel):
    senha: str | None = Field(default=None, min_length=cli.MIN_SENHA)
    admin: bool | None = None


class MkIn(BaseModel):
    nome: str = Field(min_length=1, max_length=80)
    ip_tunel: str = ""  # vazio quando sem_ipsec
    ip_publico: str
    sem_ipsec: bool = False  # MK sem VPN: o NodeBeat acessa pelo IP público (guardado também como ip_tunel)
    usuario: str = Field(min_length=1)
    senha: str = ""

    @field_validator("nome", "usuario")
    @classmethod
    def _nome(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("nome vazio")
        return v

    @field_validator("ip_tunel", "ip_publico")
    @classmethod
    def _ip(cls, v: str, info) -> str:
        if not v and info.field_name == "ip_tunel":
            return v  # o handler exige quando não é sem_ipsec
        ip = ipaddress.IPv4Address(v)  # ValueError -> 422
        if info.field_name == "ip_tunel":  # faixa privada (ou redes extra) é checada no handler, que tem o settings
            ok = not (ip.is_loopback or ip.is_link_local or ip.is_unspecified or ip.is_multicast)
        else:
            ok = ip.is_global
        if not ok:
            raise ValueError("faixa de IP inválida")
        return v


class AparelhoIn(BaseModel):
    apelido: str | None = Field(None, max_length=60)
    vigiar: bool | None = None
    e_switch: bool | None = None


TIPOS_EQ = {"switch"}


class EquipamentoIn(BaseModel):
    tipo: str
    nome: str = Field(min_length=1, max_length=80)
    ip: str
    local: str
    community: str | None = None


class EquipamentoPut(BaseModel):
    nome: str | None = Field(default=None, max_length=80)
    ip: str | None = None
    community: str | None = None


class RotuloPortaIn(BaseModel):
    porta: str = Field(min_length=1, max_length=100)
    rotulo: str | None = Field(None, max_length=40)


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
        if (st.get(campo) or 0) > LIMITE:
            out.append(f"{rotulo} ({_pct(st[campo])}%)")
    ifaces = st.get("ifaces") or {}
    out += [f"Interface {n} caída" for n in mk.get("interfaces_vigiadas") or [] if ifaces.get(n) is False]
    return out


_MSG_422 = {"nome": "Campo obrigatório", "usuario": "Campo obrigatório", "senha": "Campo obrigatório",
            "nova": "Mínimo de 12 caracteres",
            "ip_tunel": "Use o IP privado do túnel",
            "ip_tunel_repetido": "Já existe uma MK com esse IP do túnel", "ip_publico": "Use o IP público fixo"}


def create_app(db, r, settings) -> FastAPI:
    app = FastAPI()
    app.state.db, app.state.r, app.state.settings = db, r, settings

    @app.exception_handler(RequestValidationError)
    async def _invalida(request: Request, exc: RequestValidationError) -> JSONResponse:
        # Só loc + texto fixo: nunca "input"/"ctx" (eco do corpo vazaria a senha).
        detail = [{"loc": list(e["loc"]),
                   "msg": _MSG_422["nova"] if e["type"] == "string_too_short" and e["loc"][-1] == "senha"
                   else _MSG_422.get(str(e["loc"][-1]), "Valor inválido")} for e in exc.errors()]
        return JSONResponse({"detail": detail}, status_code=422)

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
            usuario = await r.get(f"sess:{token}")
            await r.delete(f"sess:{token}")
            if usuario:
                await r.srem(f"sess_u:{usuario}", token)
        resp = Response(status_code=204)
        resp.delete_cookie(auth.COOKIE, **_COOKIE)
        return resp

    @app.get("/api/auth/me")
    async def me(user: dict = Depends(auth.current_user)) -> dict:
        return {k: user[k] for k in ("usuario", "admin", "tema")}

    @app.put("/api/auth/tema", status_code=204)
    async def tema(body: TemaIn, user: dict = Depends(auth.current_user)) -> Response:
        await store.atualizar_user(db, user["usuario"], {"tema": body.tema})
        return Response(status_code=204)

    @app.put("/api/auth/senha", status_code=204)
    async def trocar_senha(body: SenhaIn, user: dict = Depends(auth.current_user)) -> Response:
        u = await store.get_user(db, user["usuario"])
        if not u:
            raise HTTPException(401, "Não autenticado")
        if not await asyncio.to_thread(auth.verify_password, u["senha_hash"], body.atual):
            raise HTTPException(400, "Senha atual incorreta")
        h = await asyncio.to_thread(auth.hash_password, body.nova)
        await store.atualizar_user(db, user["usuario"], {"senha_hash": h})
        await auth.encerrar_sessoes(r, user["usuario"], manter=user["token"])
        return Response(status_code=204)

    @app.get("/api/usuarios")
    async def listar_usuarios(_: dict = Depends(auth.admin_user)) -> list[dict]:
        return await store.listar_users(db)

    @app.post("/api/usuarios", status_code=201)
    async def criar_usuario(body: UsuarioIn, _: dict = Depends(auth.admin_user)) -> dict:
        h = await asyncio.to_thread(auth.hash_password, body.senha)
        try:
            await store.insert_user(db, body.usuario, h, admin=body.admin)
        except DuplicateKeyError:
            raise HTTPException(409, "Usuário já existe")
        return {"usuario": body.usuario}

    async def _alvo_com_travas(u: str, eu: str, perde_admin: bool) -> dict:
        alvo = await store.get_user(db, u)
        if not alvo:
            raise HTTPException(404, "Usuário não encontrado")
        if perde_admin and u == eu:
            raise HTTPException(409, "Você não pode remover nem rebaixar a si mesmo")
        if perde_admin and alvo.get("admin", True) and await store.contar_admins(db) <= 1:
            raise HTTPException(409, "Precisa haver ao menos um admin")
        return alvo

    @app.put("/api/usuarios/{u}", status_code=204)
    async def editar_usuario(u: str, body: UsuarioPatch, me: dict = Depends(auth.admin_user)) -> Response:
        u = u.strip().lower()
        await _alvo_com_travas(u, me["usuario"], body.admin is False)
        campos = {}
        if body.admin is not None:
            campos["admin"] = body.admin
        if body.senha is not None:
            campos["senha_hash"] = await asyncio.to_thread(auth.hash_password, body.senha)
        if campos:
            await store.atualizar_user(db, u, campos)
        if body.senha is not None:
            await auth.encerrar_sessoes(r, u, manter=me["token"] if u == me["usuario"] else None)
        return Response(status_code=204)

    @app.delete("/api/usuarios/{u}", status_code=204)
    async def apagar_usuario(u: str, me: dict = Depends(auth.admin_user)) -> Response:
        u = u.strip().lower()
        await _alvo_com_travas(u, me["usuario"], True)
        await store.apagar_user(db, u)
        await auth.encerrar_sessoes(r, u)
        return Response(status_code=204)

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

    async def _tunel_livre(ip: str, ignorar: str | None = None) -> None:
        if any(m["ip_tunel"] == ip and m["id"] != ignorar for m in await store.list_mks(db)):
            raise HTTPException(422, [{"loc": ["body", "ip_tunel"], "msg": _MSG_422["ip_tunel_repetido"]}])

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
            resumo["no_ar"] += s == "no_ar" and not alertas
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
                "sede_ok": not (eng and json.loads(eng).get("frozen")),
                "dados_ok": bool(await r.exists("worker:vivo")), "mks": [x[0] for x in linhas]}

    extras = [ipaddress.ip_network(n) for n in settings.redes_tunel_extra]

    def _tunel_ok(body: MkIn) -> dict:
        """Campos a gravar; sem IPsec o IP de acesso (ip_tunel) é o público."""
        campos = body.model_dump(exclude={"senha"})
        if body.sem_ipsec:
            return campos | {"ip_tunel": body.ip_publico}
        if not body.ip_tunel:
            raise HTTPException(422, [{"loc": ["body", "ip_tunel"], "msg": "Campo obrigatório"}])
        ip = ipaddress.IPv4Address(body.ip_tunel)
        if not (ip.is_private or any(ip in n for n in extras)):
            raise HTTPException(422, [{"loc": ["body", "ip_tunel"], "msg": _MSG_422["ip_tunel"]}])
        return campos

    @mks.post("/mks", status_code=201)
    async def criar(body: MkIn) -> dict:
        campos = _tunel_ok(body)
        if not body.senha:
            raise HTTPException(422, [{"loc": ["body", "senha"], "msg": "Campo obrigatório"}])
        await _nome_livre(body.nome)
        await _tunel_livre(campos["ip_tunel"])
        doc = campos | {
            "senha_cifrada": crypto.encrypt(body.senha, settings.secret_key),
            "cert_sha256": None, "interfaces_vigiadas": []}
        return {"id": await store.insert_mk(db, doc)}

    @mks.get("/mks/{id}")
    async def obter(id: str) -> dict:
        mk = await _achar(id)
        mk = {k: v for k, v in mk.items() if k in ("id", "nome", "ip_tunel", "ip_publico", "usuario", "sem_ipsec",
                                                   "interfaces_vigiadas", "cert_sha256")}
        mk["estado"] = (await history.load_states(r)).get(id)
        return mk

    @mks.put("/mks/{id}", status_code=204)
    async def alterar(id: str, body: MkIn) -> Response:
        campos = _tunel_ok(body)
        antigo = await _achar(id)
        await _nome_livre(body.nome, id)
        await _tunel_livre(campos["ip_tunel"], id)
        if body.senha:
            campos["senha_cifrada"] = crypto.encrypt(body.senha, settings.secret_key)
        if campos["ip_tunel"] != antigo["ip_tunel"]:
            campos["cert_sha256"] = None  # outro aparelho: o pin antigo não vale
        await store.update_mk(db, id, campos)
        return Response(status_code=204)

    @mks.delete("/mks/{id}", status_code=204)
    async def apagar(id: str) -> Response:
        await _achar(id)
        await store.delete_mk(db, id)
        await store.apagar_inventario(db, id)
        await store.apagar_eventos(db, id)
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

    @mks.post("/mks/{id}/reiniciar")
    async def reiniciar(id: str, user: dict = Depends(auth.current_user)):
        mk = await _achar(id)

        async def _reboot(host: str, **kw) -> None:
            senha = crypto.decrypt(mk["senha_cifrada"], settings.secret_key)
            await asyncio.to_thread(routeros.reboot, host, mk["usuario"], senha, mk.get("cert_sha256"), **kw)

        via = "tunel"
        try:
            try:
                await _reboot(mk["ip_tunel"])
            except routeros.SemConexao as e:  # túnel caído: tenta pela internet (só falha de rede, não login/TLS)
                if not mk.get("ip_publico"):
                    raise
                via = "publico"
                try:
                    try:
                        await _reboot(mk["ip_publico"])
                    except routeros.SemConexao:  # operadora bloqueando a 8729: tenta a porta alternativa
                        await _reboot(mk["ip_publico"], porta=routeros.PORTA_API_ALT)
                except routeros.RouterOsError as e2:
                    raise routeros.RouterOsError(f"Túnel: {e.detalhe}. IP público: {e2.detalhe}") from None
        except routeros.RouterOsError as e:
            return JSONResponse({"detalhe": e.detalhe}, status_code=502)
        except Exception:  # nunca ecoar str(e): pode conter segredo
            return JSONResponse({"detalhe": "Resposta inesperada da API"}, status_code=502)
        await r.set(worker.REINICIO + id, user["usuario"], ex=worker.JANELA_REINICIO)
        detalhe = f"Solicitado por {user['usuario']}" + (" pelo IP público" if via == "publico" else "")
        await history.record(r, Event("reinicio", "reinicio", MkRef(id, mk["nome"]), detalhe,
                                      datetime.now(UTC), None, None))
        return {"via": via}

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

    _VAZIO = {"lido_em": None, "erro": None, "redes": [], "pools": [], "nat": [], "servicos": []}

    async def _inv(id: str) -> dict:
        """Inventário da MK (campos da API) ou vazio; sempre com 'desatualizado'."""
        inv = await store.get_inventario(db, id) or {}
        out = {k: inv.get(k, v) for k, v in _VAZIO.items()}
        out["desatualizado"] = inventario.desatualizado(out["lido_em"], datetime.now(UTC))
        return out

    @mks.get("/faixas")
    async def faixas() -> dict:
        invs = {i["mk_id"]: i for i in await store.listar_inventarios(db)}
        agora = datetime.now(UTC)
        linhas = []
        for mk in sorted(await store.list_mks(db), key=lambda m: m["nome"].casefold()):
            i = invs.get(mk["id"]) or {}
            lido = i.get("lido_em")
            linhas.append({"id": mk["id"], "nome": mk["nome"], "lido_em": lido, "erro": i.get("erro"),
                           "desatualizado": inventario.desatualizado(lido, agora), "redes": i.get("redes", [])})
        return {"mks": linhas, "sede": settings.sede_redes,
                "sobreposicoes": inventario.sobreposicoes(linhas, settings.sede_redes)}

    @mks.get("/faixas/conferir")
    async def conferir_faixa(cidr: str) -> dict:
        invs = {i["mk_id"]: i for i in await store.listar_inventarios(db)}
        lista = [{"nome": m["nome"], "redes": (invs.get(m["id"]) or {}).get("redes", []),
                  "lido_em": (invs.get(m["id"]) or {}).get("lido_em")} for m in await store.list_mks(db)]
        try:
            return inventario.conferir_faixa(cidr, lista, settings.sede_redes, datetime.now(UTC))
        except ValueError:
            raise HTTPException(422, "Faixa inválida")

    @mks.get("/preparar-mk")
    async def preparar_mk() -> dict:
        return {"ip_origem": settings.ip_origem, "ips_publicos_sede": settings.ips_publicos_sede}

    @mks.post("/faixas/atualizar", status_code=202)
    async def pedir_atualizacao() -> Response:
        await r.set(worker.PEDIDO_INVENTARIO, "1")
        return Response(status_code=202)

    @mks.get("/mks/{id}/inventario")
    async def inventario_mk(id: str) -> dict:
        await _achar(id)
        return await _inv(id)

    @mks.post("/mks/{id}/inventario/atualizar")
    async def atualizar_inventario(id: str):
        mk = await _achar(id)
        erro = await worker.atualizar_mk(db, settings, mk, datetime.now(UTC), fetch=routeros.fetch_inventario)
        if erro:
            return JSONResponse({"detalhe": erro}, status_code=502)
        return await _inv(id)

    @mks.get("/mks/{id}/eventos")
    async def eventos_mk(id: str, tipo: list[str] | None = Query(None), desde: datetime | None = None,
                         ate: datetime | None = None, q: str | None = Query(None, max_length=100),
                         limite: int = Query(200, ge=1, le=1000)) -> dict:
        await _achar(id)
        if tipo and any(t not in eventos.TIPOS for t in tipo):
            raise HTTPException(422, [{"loc": ["query", "tipo"], "msg": "Valor inválido"}])
        lista = await store.listar_eventos(db, id, tipos=tipo, desde=desde, ate=ate, q=q, limite=limite)
        ultimo = await store.ultimo_evento(db, id)
        return {"eventos": [{k: v for k, v in e.items() if k != "mk_id"} for e in lista],
                "syslog_ativo": ultimo is not None and ultimo > datetime.now(UTC) - timedelta(hours=24)}

    _painel_cache: dict = {}  # (periodo, mk) -> (instante, resposta); no máx. 3 períodos x (1 + 19 MKs)

    @mks.get("/eventos/painel")
    async def painel_eventos(periodo: str = Query("24h", pattern="^(24h|7d|30d)$"), mk: str | None = None) -> dict:
        if mk:
            await _achar(mk)
        chave, t = (periodo, mk), time.monotonic()
        if (c := _painel_cache.get(chave)) and t - c[0] < PAINEL_TTL:
            return c[1]
        agora = datetime.now(UTC)
        # ponytail: lê os 30 dias em memória (~30 mil eventos/dia); pipeline do Mongo se o cache não bastar
        evs = await store.listar_eventos_periodo(db, agora - timedelta(days=30))
        ctx = painel.Ctx(settings.sede_redes, settings.ips_publicos_sede)
        res = painel.montar(evs, await store.list_mks(db), ctx, agora, periodo, mk)
        _painel_cache[chave] = (t, res)
        return res

    async def _capacidade(sws: list[dict], agora: datetime) -> list[dict]:
        retratos = await store.listar_retratos(db, [e["id"] for e in sws], agora - timedelta(days=30))
        out = []
        for e in sws:
            bruto = await r.get(f"unifi:eq:{e['id']}")
            rets = [x for x in retratos if x["eq_id"] == e["id"]]
            if not bruto and not rets:
                continue
            atual = None
            if bruto:
                est = json.loads(bruto)
                sis, portas = est.get("sistema") or {}, est.get("portas") or {}
                poe = sorted(({"porta": k, "w": p["poe_w"]} for k, p in portas.items() if (p.get("poe_w") or 0) > 0),
                             key=lambda x: -x["w"])
                atual = {**{c: sis.get(c) for c in ("poe_usado_w", "poe_max_w", "clientes", "temperatura")},
                         "portas_total": len(portas), "portas_em_uso": sum(bool(p.get("up")) for p in portas.values()),
                         "poe_por_porta": poe}
            out.append({"switch_id": e["id"], "switch_nome": e["nome"], "atual": atual,
                        "historico": switch_painel.reduzir(rets), "projecoes": switch_painel.projecoes(rets, agora)})
        return out

    @mks.get("/eventos/switches")
    async def eventos_switches(periodo: str = Query("24h", pattern="^(1h|24h|7d|30d)$")) -> dict:
        horas = {"1h": 1, "24h": 24, "7d": 168, "30d": 720}[periodo]
        desde = datetime.now(UTC) - timedelta(hours=horas)
        evs = await store.listar_eventos_unifi(db, desde)
        nomes = {e["id"]: e["nome"] for e in await store.listar_equipamentos(db)}
        contagens = dict.fromkeys(("clientes", "alertas", "poe", "mudancas"), 0)
        for tipo, n in (await store.contar_eventos_unifi(db, desde)).items():
            contagens[unifi.GRUPOS.get(tipo, "alertas")] += n
        agora = datetime.now(UTC)
        ant = await store.listar_eventos_unifi_periodo(db, desde - timedelta(hours=horas), desde)
        atual = await store.listar_eventos_unifi_periodo(db, desde, agora + timedelta(seconds=1))
        sws = await store.listar_equipamentos(db, tipo="switch")
        nomes_eq = {f"eq:{e['id']}": e["nome"] for e in sws}
        ptop = [p | {"switch_id": p["switch_id"][3:]} for p in switch_painel.portas_top(atual, nomes_eq, horas)]
        return {"contagens": contagens, "totais": switch_painel.totais(atual, ant, horas, ptop),
                "serie": switch_painel.serie(atual, desde, periodo), "portas_top": ptop,
                "clientes_top": switch_painel.clientes_top(atual, nomes_eq),
                "capacidade": await _capacidade(sws, agora), "eventos": [
            {"quando": e["recebido_em"].isoformat(), "switch_id": e["mk_id"][3:],
             "switch_nome": nomes.get(e["mk_id"][3:], "Switch removido"), "porta": (e.get("campos") or {}).get("porta"),
             "tipo": e["tipo"], "grupo": unifi.GRUPOS.get(e["tipo"], "alertas"), "mensagem": e["mensagem"],
             "severidade": e["severidade"]} for e in evs]}

    @mks.get("/mks/{id}/portas/conferir")
    async def conferir_porta(id: str, porta: int = Query(ge=1, le=65535),
                             protocolo: str = Query("tcp", pattern="^(tcp|udp)$")) -> dict:
        await _achar(id)
        inv = await _inv(id)
        return inventario.conferir_porta(porta, protocolo, inv) | {"desatualizado": inv["desatualizado"]}

    @mks.get("/mks/{id}/ips")
    async def ips(id: str) -> list[dict]:
        await _achar(id)
        agora = datetime.now(UTC)
        return [v | {"em_uso": inventario.ip_em_uso(v, agora)} for v in await store.listar_ips(db, id)]

    @mks.get("/mks/{id}/ips/conferir")
    async def conferir_ip(id: str, ip: str) -> dict:
        await _achar(id)
        inv = await _inv(id)
        try:
            res = inventario.conferir_ip(ip, inv, await store.listar_ips(db, id), datetime.now(UTC))
        except ValueError:
            raise HTTPException(422, "IP inválido")
        return res | {"desatualizado": inv["desatualizado"]}

    @mks.delete("/mks/{id}/ips/{ip}", status_code=204)
    async def esquecer_ip(id: str, ip: str) -> Response:
        await _achar(id)
        if not await store.esquecer_ip(db, id, ip):
            raise HTTPException(404, "IP não encontrado")
        return Response(status_code=204)

    @mks.get("/mks/{id}/mapa")
    async def mapa_mk(id: str, q: str | None = Query(None, max_length=100), so_problema: bool = False) -> dict:
        await _achar(id)
        inv = await store.get_inventario(db, id) or {}
        lido = inv.get("lido_em")
        row = (await history.load_states(r)).get(id) or {}
        no_ar = row.get("status") == "no_ar"
        portas = mapa.montar_arvore(
            await store.listar_ips(db, id), link=row.get("portas_link") or {},
            rotulos=await store.rotulos_portas(db, id), estados=await history.load_aparelhos(r, id),
            mk_no_ar=no_ar, redes_tunel=[x["rede"] for x in inv.get("redes", []) if x.get("tunel")],
            busca=q, so_problema=so_problema, agora=datetime.now(UTC),
            switches=await store.listar_switches(db, id))
        return {"lido_em": lido, "desatualizado": inventario.desatualizado(lido, datetime.now(UTC)),
                "mk_no_ar": no_ar, "portas": portas}

    @mks.put("/mks/{id}/mapa/aparelhos/{ip}", status_code=204)
    async def editar_aparelho(id: str, ip: str, body: AparelhoIn) -> Response:
        await _achar(id)
        campos = {"apelido": body.apelido or None, "vigiar_manual": body.vigiar, "e_switch_manual": body.e_switch}
        dados = {"apelido": "apelido", "vigiar_manual": "vigiar", "e_switch_manual": "e_switch"}
        campos = {k: v for k, v in campos.items() if dados[k] in body.model_fields_set}
        if not await store.editar_aparelho(db, id, ip, campos):
            raise HTTPException(404, "Aparelho não encontrado")
        return Response(status_code=204)

    @mks.put("/mks/{id}/mapa/rotulo-porta", status_code=204)
    async def rotulo_porta(id: str, body: RotuloPortaIn) -> Response:
        await _achar(id)
        await store.set_rotulo_porta(db, id, body.porta, body.rotulo or None)
        return Response(status_code=204)

    async def _eq(id: str) -> dict:
        eq = await store.get_equipamento(db, id)
        if not eq:
            raise HTTPException(404, "Equipamento não encontrado")
        return eq

    async def _linha(eq: dict, estado: dict | None, nomes: dict[str, str]) -> dict:
        portas = (estado or {}).get("portas") or {}
        return {"id": eq["id"], "tipo": eq["tipo"], "nome": eq["nome"], "ip": eq["ip"], "local": eq["local"],
                "local_nome": "Sede" if eq["local"] == "sede" else nomes.get(eq["local"], eq["local"]),
                "origem": eq["origem"], "estado": estado, "portas_total": len(portas),
                "portas_up": sum(p.get("up") is True for p in portas.values())}

    async def _nomes_mks() -> dict[str, str]:
        return {m["id"]: m["nome"] for m in await store.list_mks(db)}

    def _ip_ok(ip: str) -> str:
        try:
            return str(ipaddress.IPv4Address(ip))
        except ValueError:
            raise HTTPException(422, [{"loc": ["body", "ip"], "msg": "IP inválido"}]) from None

    async def _eq_livre(local: str, ip: str, ignorar: str | None = None) -> None:
        if any(e["local"] == local and e["ip"] == ip and e["id"] != ignorar
               for e in await store.listar_equipamentos(db)):
            raise HTTPException(409, "Já existe um equipamento com esse IP nesse local")

    @mks.get("/equipamentos")
    async def listar_eqs(tipo: str | None = None) -> list[dict]:
        estados, nomes = await history.load_eq_states(r), await _nomes_mks()
        linhas = [await _linha(e, estados.get(e["id"]), nomes) for e in await store.listar_equipamentos(db, tipo)]
        linhas.sort(key=lambda x: (x["local"] != "sede", x["local_nome"].casefold(), x["nome"].casefold()))
        return linhas

    @mks.post("/equipamentos", status_code=201)
    async def criar_eq(body: EquipamentoIn) -> dict:
        if body.tipo not in TIPOS_EQ:
            raise HTTPException(422, [{"loc": ["body", "tipo"], "msg": "Tipo desconhecido"}])
        ip = _ip_ok(body.ip)
        if body.local != "sede" and not await store.get_mk(db, body.local):
            raise HTTPException(422, [{"loc": ["body", "local"], "msg": "Local não existe"}])
        await _eq_livre(body.local, ip)
        community = body.community or settings.snmp_communities[0]
        return {"id": await store.inserir_equipamento(db, {
            "tipo": body.tipo, "nome": body.nome, "ip": ip, "local": body.local, "origem": "manual",
            "community_cifrada": crypto.encrypt(community, settings.secret_key)})}

    async def _unifi_eq(id: str, estado: dict | None) -> dict | None:
        bruto = await r.get(f"unifi:eq:{id}")
        if not bruto:
            return None
        dados = json.loads(bruto)
        # nome SNMP (ex. "0/12") casa pelo número no fim; sem par: "Porta <idx>"
        snmp = {m.group(1): n for n in (estado or {}).get("portas") or {} if (m := re.search(r"(\d+)$", n))}
        return {"lido_em": dados.get("lido_em"), "sistema": dados.get("sistema"),
                "portas": {snmp.get(idx, f"Porta {idx}"): p for idx, p in (dados.get("portas") or {}).items()}}

    @mks.get("/equipamentos/{id}")
    async def obter_eq(id: str) -> dict:
        eq = await _eq(id)
        estado = (await history.load_eq_states(r)).get(id)
        return await _linha(eq, estado, await _nomes_mks()) | {"uplinks": (estado or {}).get("uplinks") or {},
                                                               "unifi": await _unifi_eq(id, estado)}

    @mks.put("/equipamentos/{id}", status_code=204)
    async def editar_eq(id: str, body: EquipamentoPut) -> Response:
        eq = await _eq(id)
        dados = body.model_dump(exclude_unset=True)
        if eq["origem"] != "manual" and set(dados) - {"nome"}:
            raise HTTPException(422, [{"loc": ["body", k], "msg": "Switch descoberto só aceita o nome"}
                                      for k in dados if k != "nome"])
        campos: dict = {}
        if dados.get("nome"):
            campos["nome"] = dados["nome"]
        if dados.get("ip"):
            campos["ip"] = _ip_ok(dados["ip"])
            await _eq_livre(eq["local"], campos["ip"], id)
        if dados.get("community"):
            campos["community_cifrada"] = crypto.encrypt(dados["community"], settings.secret_key)
        if campos:
            await store.atualizar_equipamento(db, id, campos)
        return Response(status_code=204)

    @mks.delete("/equipamentos/{id}", status_code=204)
    async def apagar_eq(id: str) -> Response:
        eq = await _eq(id)
        if eq["origem"] != "manual":
            raise HTTPException(409, "Switch descoberto some sozinho quando deixa de responder SNMP")
        await store.apagar_equipamento(db, id)
        await history.delete_eq(r, id)
        return Response(status_code=204)

    @mks.get("/equipamentos/{id}/eventos")
    async def eventos_eq(id: str) -> list[dict]:
        await _eq(id)
        return await store.listar_eventos(db, f"eq:{id}", limite=200)

    @mks.get("/equipamentos/{id}/historico")
    async def historico_eq(id: str) -> list[dict]:
        await _eq(id)
        return await history.history(r, f"eq:{id}")

    app.include_router(mks)
    return app


def app_from_env() -> FastAPI:
    """Fábrica para `uvicorn --factory nodebeat.api:app_from_env`."""
    import redis.asyncio
    from motor.motor_asyncio import AsyncIOMotorClient

    from nodebeat.config import load_settings

    s = load_settings()
    db = AsyncIOMotorClient(s.mongo_url).get_default_database("nodebeat")
    return create_app(db, redis.asyncio.Redis.from_url(s.redis_url, decode_responses=True), s)
