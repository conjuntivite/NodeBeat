"""Ciclo do worker: referência -> sondas por MK -> motor de alertas -> Redis."""
from __future__ import annotations

import asyncio
import json
import logging
from datetime import UTC, datetime

import httpx
import redis.asyncio
from motor.motor_asyncio import AsyncIOMotorClient

from . import crypto, history, probes, routeros, store, webhook
from .classify import classify
from .config import Settings, load_settings
from .rules import AlertEngine, MkRef, MkState

log = logging.getLogger(__name__)


async def _emit(r, evs) -> None:
    for ev in evs:
        await history.record(r, ev)
        if ev.evento in ("queda", "retorno"):
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
    ref = MkRef(mk["id"], mk["nome"])
    await _emit(r, engine.observe_mk(ref, obs, now))
    ok = obs.state == MkState.NO_AR
    ant = antes.get(mk["id"])
    # entre tipos de queda (offline/vpn_caiu/erro_acesso) o relógio continua: conta desde que saiu do ar
    mesmo = ant and (ant["status"] == obs.state.value or (ant["status"] != "no_ar" and not ok))
    desde = ant["desde"] if mesmo else now.isoformat()
    await history.save_state(r, mk["id"], {
        "status": obs.state.value, "detalhe": obs.detalhe, "desde": desde,
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


def load_engine(saved: str | None) -> AlertEngine:
    if saved:
        try:
            return AlertEngine.load(json.loads(saved))
        except (ValueError, KeyError, TypeError, AttributeError) as e:
            log.warning("estado do motor ilegível, começando vazio: %s", type(e).__name__)
    return AlertEngine()


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
        while True:
            if sender.done():
                raise RuntimeError("envio do webhook parou") from sender.exception()
            t0 = loop.time()
            try:
                await run_cycle(db, r, engine, s, datetime.now(UTC))
            except Exception as e:
                log.warning("ciclo falhou: %s", type(e).__name__)
            await asyncio.sleep(max(0, s.interval_s - (loop.time() - t0)))


if __name__ == "__main__":
    asyncio.run(main())
