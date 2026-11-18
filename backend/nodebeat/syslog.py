"""Receptor de syslog UDP das MKs (via IPsec): IP de origem -> MK, filtra ruído, grava em lotes no Mongo."""
from __future__ import annotations

import asyncio
import logging
import time
from collections import Counter
from collections.abc import Callable
from datetime import UTC, datetime

import redis.asyncio
from motor.motor_asyncio import AsyncIOMotorClient

from . import store
from .config import load_settings
from .eventos import evento, ruido

log = logging.getLogger(__name__)

MAX_DESCONHECIDOS = 50  # IPs distintos contados por minuto; o resto vai para "outros"
PORTA = 5514  # o compose publica 514 -> 5514 (container não-root, sem cap)


async def mapa_ips(db) -> dict[str, str | None]:
    """ip_tunel -> mk_id; None quando o IP é de mais de uma MK."""
    mapa: dict[str, str | None] = {}
    for mk in await store.list_mks(db):
        ip = mk["ip_tunel"]
        mapa[ip] = None if ip in mapa else mk["id"]
    return mapa


class Receptor(asyncio.DatagramProtocol):
    def __init__(self, mapa: dict[str, str | None], fila: asyncio.Queue, pedir_recarga: Callable[[], None],
                 ip_origem: str | None = None, limite_por_s: int = 50,
                 relogio: Callable[[], float] = time.monotonic) -> None:
        self.mapa = mapa
        self.fila = fila
        self.pedir_recarga = pedir_recarga
        self.ip_origem = ip_origem
        self.limite_por_s = limite_por_s
        self.relogio = relogio
        self.descartes: Counter = Counter()
        self._janela: dict[str, tuple[int, int]] = {}

    def datagram_received(self, data: bytes, addr) -> None:
        if not data:
            return
        ip = addr[0]
        if ip not in self.mapa:
            # ponytail: varre as chaves (<= 51); contador à parte se a varredura pesar. Teto contra origem forjada.
            chave = ("desconhecido", ip)
            if chave not in self.descartes and sum(1 for k in self.descartes if k[0] == "desconhecido") >= MAX_DESCONHECIDOS:
                chave = ("desconhecido", "outros")
            self.descartes[chave] += 1
            self.pedir_recarga()
            return
        mk_id = self.mapa[ip]
        if mk_id is None:
            self.descartes["ambiguo", ip] += 1
            return
        ev = evento(data, mk_id, datetime.now(UTC))
        if ruido(ev, self.ip_origem):
            return
        # ponytail: janela fixa; token bucket se rajada legítima se perder
        seg = int(self.relogio())
        s, n = self._janela.get(mk_id, (seg, 0))
        if s != seg:
            n = 0
        if n >= self.limite_por_s:
            self.descartes["limite", mk_id] += 1
            return
        self._janela[mk_id] = (seg, n + 1)
        try:
            self.fila.put_nowait(ev)
        except asyncio.QueueFull:
            self.descartes["fila_cheia", ""] += 1


async def gravar(db, fila: asyncio.Queue, intervalo_s: float = 1.0, lote: int = 500) -> None:
    loop = asyncio.get_running_loop()
    while True:
        docs = [await fila.get()]
        fim = loop.time() + intervalo_s
        while len(docs) < lote and (resto := fim - loop.time()) > 0:
            try:
                docs.append(await asyncio.wait_for(fila.get(), resto))
            except TimeoutError:
                break
        try:
            await store.inserir_eventos(db, docs)
        except Exception as e:  # ponytail: lote perdido se o Mongo cair; o UDP já é com perda
            log.warning("gravação de eventos falhou: %s", type(e).__name__)


async def main() -> None:
    logging.basicConfig(level=logging.INFO)
    s = load_settings()
    r = redis.asyncio.Redis.from_url(s.redis_url, decode_responses=True)
    db = AsyncIOMotorClient(s.mongo_url).get_default_database("nodebeat")
    await store.garantir_indices_eventos(db, s.syslog_dias)
    fila: asyncio.Queue = asyncio.Queue(maxsize=10_000)
    recarga = asyncio.Event()
    rec = Receptor(await mapa_ips(db), fila, recarga.set, s.ip_origem)
    loop = asyncio.get_running_loop()
    await loop.create_datagram_endpoint(lambda: rec, local_addr=("0.0.0.0", PORTA))

    async def recarregar() -> None:
        ultima = loop.time()
        while True:
            try:
                await asyncio.wait_for(recarga.wait(), 60)
            except TimeoutError:
                pass
            espera = 10 - (loop.time() - ultima)  # intervalo mínimo entre recargas
            if espera > 0:
                await asyncio.sleep(espera)
            recarga.clear()
            ultima = loop.time()
            try:
                rec.mapa = await mapa_ips(db)
            except Exception as e:
                log.warning("recarga do mapa falhou: %s", type(e).__name__)

    async def vivo() -> None:
        while True:
            try:
                await r.set("syslog:vivo", datetime.now(UTC).isoformat(), ex=90)
            except Exception as e:
                log.warning("syslog:vivo falhou: %s", type(e).__name__)
            await asyncio.sleep(30)

    async def log_descartes() -> None:
        while True:
            await asyncio.sleep(60)
            if rec.descartes:
                log.info("descartes no último minuto: %s", dict(rec.descartes))
                rec.descartes.clear()

    tarefas = [asyncio.create_task(c) for c in (gravar(db, fila), recarregar(), vivo(), log_descartes())]
    await asyncio.gather(*tarefas)  # qualquer tarefa que morra derruba o processo (restart do compose)


if __name__ == "__main__":
    asyncio.run(main())
