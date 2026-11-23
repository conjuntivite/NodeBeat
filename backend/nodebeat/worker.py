"""Ciclo do worker: referência -> sondas por MK -> motor de alertas -> Redis."""
from __future__ import annotations

import asyncio
import json
import logging
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime

import httpx
import redis.asyncio
from motor.motor_asyncio import AsyncIOMotorClient

from . import crypto, history, inventario, probes, routeros, store, webhook
from .classify import classify
from .config import Settings, load_settings
from .rules import AlertEngine, MkRef, MkState

log = logging.getLogger(__name__)

PEDIDO_INVENTARIO = "inventario:pedido"
REINICIO = "reinicio:"  # + id da MK; TTL = janela sem alerta após reinício pelo painel
JANELA_REINICIO = 300
RECOVER_S = 600  # MK oscilando (cai/volta) dentro dessa janela é UM incidente = um ticket só
# pool próprio: o inventário (até 10 s por MK offline) não pode ocupar as threads do ciclo de 30 s
_POOL_INVENTARIO = ThreadPoolExecutor(max_workers=10, thread_name_prefix="inventario")


async def _emit(r, evs) -> None:
    for ev in evs:
        await history.record(r, ev)
        if ev.evento == "queda":  # o webhook abre ticket no sistema de chamados; o retorno fica só no histórico
            await webhook.enqueue(r, ev.to_payload())


async def _check(db, r, engine, settings, now, mk, antes, fetch, ping) -> None:
    # nunca logar args/str da exceção: podem conter a senha
    snap, api_error, sha = None, None, ""
    try:
        senha = crypto.decrypt(mk["senha_cifrada"], settings.secret_key)
    except ValueError:
        api_error = "Senha cifrada inválida"
    else:
        try:
            snap, sha = await asyncio.to_thread(
                fetch, mk["ip_tunel"], mk["usuario"], senha, mk.get("cert_sha256"))
        except routeros.RouterOsError as e:
            api_error = e.detalhe
        except Exception as e:
            log.warning("mk %s: fetch falhou: %s", mk["id"], type(e).__name__)
            api_error = "Resposta inesperada da API"
    tunel = publico = None
    if snap is None:
        tunel = await ping(mk["ip_tunel"])
        if not tunel and mk.get("ip_publico"):
            publico = await ping(mk["ip_publico"])
    elif sha and not mk.get("cert_sha256"):
        await store.set_cert(db, mk["id"], sha)
    obs = classify(snap, api_error, tunel, publico, mk.get("interfaces_vigiadas") or [])
    ok = obs.state == MkState.NO_AR
    status = obs.state.value
    # reinício pedido pelo painel: fora do motor (sem alerta nem ticket) até a janela expirar.
    # Não apaga a janela quando responde: logo após o pedido a MK ainda responde enquanto desliga.
    if not ok and await r.exists(REINICIO + mk["id"]):
        status = "reiniciando"
    if status != "reiniciando":
        await _emit(r, engine.observe_mk(MkRef(mk["id"], mk["nome"]), obs, now))
    ant = antes.get(mk["id"])
    # entre tipos de queda (offline/vpn_caiu/erro_acesso) o relógio continua: conta desde que saiu do ar
    mesmo = ant and (ant["status"] == status or (ant["status"] != "no_ar" and not ok))
    desde = ant["desde"] if mesmo else now.isoformat()
    await history.save_state(r, mk["id"], {
        "status": status, "detalhe": obs.detalhe, "desde": desde,
        "cpu": obs.cpu if ok else None, "mem": obs.mem if ok else None,
        "uptime": snap.uptime if ok else None, "ifaces": obs.ifaces if ok else {},
        "versao": snap.version if ok else None, "atualizado_em": now.isoformat()})


async def run_cycle(db, r, engine: AlertEngine, settings: Settings, now: datetime, *,
                    fetch=routeros.fetch, ping=probes.ping,
                    reference_ok=probes.reference_ok) -> None:
    # 2 tentativas: um blip isolado da referência não congela (nem zera os pendentes)
    ok = await reference_ok(settings.reference_host) or await reference_ok(settings.reference_host)
    await _emit(r, engine.observe_reference(ok, now))
    if not engine.frozen:
        mks = await store.list_mks(db)
        antes = await history.load_states(r)
        ids = {m["id"] for m in mks}
        for id in engine.mk_ids() - ids:  # a API pode já ter apagado a linha de estado
            engine.forget_mk(id)
        for id in antes.keys() - ids:
            await history.delete_mk(r, id)
        sem = asyncio.Semaphore(10)

        async def um(mk):
            async with sem:
                try:
                    await _check(db, r, engine, settings, now, mk, antes, fetch, ping)
                except Exception as e:
                    log.warning("mk %s: %s", mk.get("id"), type(e).__name__)

        await asyncio.gather(*(um(m) for m in mks))
    await r.set("engine", json.dumps(engine.dump()))
    await r.set("worker:vivo", now.isoformat(), ex=90)  # /api/status: dados_ok


async def atualizar_mk(db, settings, mk: dict, now: datetime, fetch=routeros.fetch_inventario) -> str | None:
    """Lê o inventário da MK e grava. None se ok; senão o detalhe do erro (já gravado)."""
    # nunca logar args/str da exceção: podem conter a senha
    try:
        senha = crypto.decrypt(mk["senha_cifrada"], settings.secret_key)
    except ValueError:
        erro = "Senha cifrada inválida"
    else:
        try:
            raw = await asyncio.get_running_loop().run_in_executor(
                _POOL_INVENTARIO, fetch, mk["ip_tunel"], mk["usuario"], senha, mk.get("cert_sha256"))
            doc = inventario.montar(raw)
            vistos = inventario.ips_vistos(
                raw.get("lease", []), raw.get("arp", []), [r["rede"] for r in doc["redes"]])
        except routeros.RouterOsError as e:
            erro = e.detalhe
        except Exception as e:
            log.warning("mk %s: inventário falhou: %s", mk["id"], type(e).__name__)
            erro = "Resposta inesperada da API"
        else:
            await store.salvar_inventario(db, mk["id"], doc, now)
            await store.registrar_ips(db, mk["id"], vistos, now)
            return None
    await store.inventario_erro(db, mk["id"], erro)
    return erro


async def run_inventario(db, settings, now: datetime, *, fetch=routeros.fetch_inventario) -> bool:
    """False se falhou por inteiro (ex.: Mongo fora); nunca levanta."""
    try:
        await _inventariar(db, settings, now, fetch)
    except Exception as e:
        log.warning("inventário falhou: %s", type(e).__name__)
        return False
    return True


async def _inventariar(db, settings, now, fetch) -> None:
    sem = asyncio.Semaphore(10)

    async def um(mk):
        async with sem:
            try:
                await atualizar_mk(db, settings, mk, now, fetch)
            except Exception as e:
                log.warning("mk %s: inventário: %s", mk.get("id"), type(e).__name__)

    await asyncio.gather(*(um(m) for m in await store.list_mks(db)))


def inventario_devido(ultimo: float | None, agora: float, intervalo: int, pedido: bool) -> bool:
    return pedido or ultimo is None or agora - ultimo >= intervalo


def load_engine(saved: str | None) -> AlertEngine:
    engine = AlertEngine(recover_s=RECOVER_S)
    if saved:
        try:
            engine = AlertEngine.load(json.loads(saved))
        except (ValueError, KeyError, TypeError, AttributeError) as e:
            log.warning("estado do motor ilegível, começando vazio: %s", type(e).__name__)
    engine.recover_s = RECOVER_S  # o estado salvo no Redis não pode manter o valor antigo
    return engine


async def main() -> None:
    logging.basicConfig(level=logging.INFO)
    logging.getLogger("httpx").setLevel(logging.WARNING)  # INFO loga a URL (webhook pode ter segredo)
    s = load_settings()
    r = redis.asyncio.Redis.from_url(s.redis_url, decode_responses=True)
    db = AsyncIOMotorClient(s.mongo_url).get_default_database("nodebeat")
    engine = load_engine(await r.get("engine"))
    async with httpx.AsyncClient(timeout=10) as client:
        # referência guardada: o loop só tem weakref das tasks; se o envio morrer, o processo cai
        sender = asyncio.create_task(webhook.run_sender(r, client, s.webhook_url, s.webhook_token))
        loop = asyncio.get_running_loop()
        inv_task, ultimo_inv = None, None

        async def _inv(s):
            nonlocal ultimo_inv
            if not await run_inventario(db, s, datetime.now(UTC)):
                ultimo_inv = loop.time() - s.inventario_s + 300  # falha total: tenta de novo em 5 min

        while True:
            if sender.done():
                raise RuntimeError("envio do webhook parou") from sender.exception()
            t0 = loop.time()
            try:
                await run_cycle(db, r, engine, s, datetime.now(UTC))
            except Exception as e:
                log.warning("ciclo falhou: %s", type(e).__name__)
            try:  # o inventário nunca derruba o monitoramento
                pedido = bool(await r.getdel(PEDIDO_INVENTARIO))
                livre = not engine.frozen and (inv_task is None or inv_task.done())
                if livre and inventario_devido(ultimo_inv, loop.time(), s.inventario_s, pedido):
                    inv_task = asyncio.create_task(_inv(s))
                    ultimo_inv = loop.time()
                elif pedido:  # não perder o pedido enquanto roda ou congelado
                    await r.set(PEDIDO_INVENTARIO, "1")
            except Exception as e:
                log.warning("agendamento do inventário falhou: %s", type(e).__name__)
            await asyncio.sleep(max(0, s.interval_s - (loop.time() - t0)))


if __name__ == "__main__":
    asyncio.run(main())
