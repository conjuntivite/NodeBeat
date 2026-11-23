"""Ciclo do worker: referência -> sondas por MK -> motor de alertas -> Redis."""
from __future__ import annotations

import asyncio
import ipaddress
import json
import logging
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

import httpx
import redis.asyncio
from motor.motor_asyncio import AsyncIOMotorClient

from . import crypto, history, inventario, mapa, probes, routeros, snmp, store, switches, webhook
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
        if not tunel and mk.get("ip_publico") and not mk.get("sem_ipsec"):  # sem IPsec o "túnel" já é o público
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
        "portas_link": dict(snap.ifaces) if ok else {},
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
            try:
                fatos = mapa.fatos_por_ip(raw, vistos)
            except Exception as e:  # o mapa não pode impedir o inventário
                log.warning("mk %s: fatos do mapa falharam: %s", mk["id"], type(e).__name__)
                fatos = {}
        except routeros.RouterOsError as e:
            erro = e.detalhe
        except Exception as e:
            log.warning("mk %s: inventário falhou: %s", mk["id"], type(e).__name__)
            erro = "Resposta inesperada da API"
        else:
            await store.salvar_inventario(db, mk["id"], doc, now)
            await store.registrar_ips(db, mk["id"], vistos, now, fatos)
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


async def _em_uso_no_tunel(db, mk_id: str, agora: datetime, filtro) -> list[dict]:
    """IPs da MK que passam no filtro, vistos há <= DIAS_EM_USO e numa rede de túnel."""
    inv = await store.get_inventario(db, mk_id) or {}
    tuneis = [ipaddress.ip_network(x["rede"]) for x in inv.get("redes", []) if x.get("tunel")]
    return [a for a in await store.listar_ips(db, mk_id)
            if filtro(a) and agora - a["ultimo_visto"] <= timedelta(days=inventario.DIAS_EM_USO)
            and any(ipaddress.ip_address(a["ip"]) in n for n in tuneis)]


async def _mapa_mk(db, r, mk_id: str, agora: datetime, sem, ping) -> None:
    alvos = [a["ip"] for a in await _em_uso_no_tunel(db, mk_id, agora, mapa.vigiado)]

    async def um(ip):
        async with sem:
            return ip, await ping(ip)

    resp = await asyncio.gather(*(um(ip) for ip in alvos))
    ant = await history.load_aparelhos(r, mk_id)
    # só os alvos: quem deixou de ser vigiado sai e, se voltar, começa do zero
    await history.save_aparelhos(r, mk_id, {ip: mapa.proximo_estado(ant.get(ip), ok, agora) for ip, ok in resp})


async def run_mapa(db, r, settings: Settings, now: datetime, *, ping=probes.ping) -> None:
    """Pinga os aparelhos vigiados das MKs no ar e guarda o estado; nunca levanta."""
    try:
        estados = await history.load_states(r)
        sem = asyncio.Semaphore(40)  # compartilhado: limite total de pings, não por MK

        async def um(mk):
            try:
                await _mapa_mk(db, r, mk["id"], now, sem, ping)
            except Exception as e:
                log.warning("mk %s: mapa: %s", mk.get("id"), type(e).__name__)

        await asyncio.gather(*(um(mk) for mk in await store.list_mks(db)
                               if estados.get(mk["id"], {}).get("status") == "no_ar"))  # fora: mantém estado
    except Exception as e:
        log.warning("mapa falhou: %s", type(e).__name__)


SEM_RESPOSTA_SNMP = "Sem resposta SNMP"
SEM_BRIDGE = "Sem tabela de bridge"  # responde SNMP (ex.: câmera) mas não é switch


async def _switch(db, settings, mk_id: str, ap: dict, ant: dict, agora: datetime, descobrir, ler) -> None:
    # a community é segredo: nunca no log, no erro ou em texto puro no banco
    ip = ap["ip"]
    community = None
    if ant.get("community_cifrada"):
        try:
            community = crypto.decrypt(ant["community_cifrada"], settings.secret_key)
        except ValueError:
            pass  # cifrada inválida (ex.: chave trocada): descobre de novo
    ja_descoberto = community is not None
    base = {"mac": ap.get("mac"), "tentado_em": agora}  # lido_em só quando a leitura dá certo
    dados = None
    if community is not None:
        try:
            dados = await ler(ip, community)
        except snmp.SnmpErro:
            pass  # a community pode ter mudado: tenta descobrir
    if dados is None:
        achou = await descobrir(ip, settings.snmp_communities)
        if achou is None:
            if ja_descoberto:  # timeout passageiro: mantém a árvore e o vigiado
                await store.salvar_switch(db, mk_id, ip, {**base, "erro": SEM_RESPOSTA_SNMP})
            else:
                await store.salvar_switch(db, mk_id, ip, {**base, "gerenciavel": False, "erro": SEM_RESPOSTA_SNMP})
                await store.marcar_gerenciavel(db, mk_id, ip, False)
            return
        community, descr = achou
        base |= {"community_cifrada": crypto.encrypt(community, settings.secret_key),
                 "gerenciavel": True, "descr": descr}
        try:
            dados = await ler(ip, community)
        except snmp.SnmpErro:
            await store.salvar_switch(db, mk_id, ip, {**base, "erro": SEM_RESPOSTA_SNMP})
            await store.marcar_gerenciavel(db, mk_id, ip, True)
            return
    ger = bool(dados.get("base_mac") or dados.get("portas"))  # sem BRIDGE-MIB não é switch
    await store.salvar_switch(db, mk_id, ip, {**base, **dados, "gerenciavel": ger,
                                              "erro": None if ger else SEM_BRIDGE, "lido_em": agora})
    await store.marcar_gerenciavel(db, mk_id, ip, ger)


async def _switches_mk(db, settings, mk_id: str, agora: datetime, sem, descobrir, ler) -> None:
    antes = {s["ip"]: s for s in await store.listar_switches(db, mk_id)}
    # "É um switch" desmarcado: deixa de ser candidato, então desfaz o gerenciável aqui
    for ap in await store.listar_ips(db, mk_id):
        if ap.get("e_switch_manual") is False and (antes.get(ap["ip"], {}).get("gerenciavel") or ap.get("gerenciavel")):
            await store.salvar_switch(db, mk_id, ap["ip"], {"gerenciavel": False})
            await store.marcar_gerenciavel(db, mk_id, ap["ip"], False)

    async def um(ap):
        async with sem:
            try:
                await _switch(db, settings, mk_id, ap, antes.get(ap["ip"], {}), agora, descobrir, ler)
            except Exception as e:
                log.warning("mk %s: switch: %s", mk_id, type(e).__name__)

    await asyncio.gather(*(um(a) for a in await _em_uso_no_tunel(db, mk_id, agora, switches.candidato)))
    # switch com erro ainda tem o fdb anterior: velho, mas serve para a ligação
    sws = await store.listar_switches(db, mk_id)
    if any(s.get("gerenciavel") and s.get("fdb") for s in sws):
        ligs, raizes = mapa.ligacoes_e_raizes(sws, await store.listar_ips(db, mk_id))
        await store.limpar_ligacoes(db, mk_id, raizes)  # raiz cortada: a ligação gravada antes está errada
        await store.registrar_ligacoes(db, mk_id, ligs)


async def run_switches(db, r, settings: Settings, now: datetime, *,
                       descobrir=switches.descobrir, ler=switches.ler_switch) -> None:
    """Descobre/lê por SNMP os switches candidatos das MKs no ar; nunca levanta."""
    try:
        estados = await history.load_states(r)
        sem = asyncio.Semaphore(10)  # compartilhado: limite total de switches lidos ao mesmo tempo

        async def um(mk):
            try:
                await _switches_mk(db, settings, mk["id"], now, sem, descobrir, ler)
            except Exception as e:
                log.warning("mk %s: switches: %s", mk.get("id"), type(e).__name__)

        await asyncio.gather(*(um(mk) for mk in await store.list_mks(db)
                               if estados.get(mk["id"], {}).get("status") == "no_ar"))  # fora: mantém o doc
    except Exception as e:
        log.warning("switches falharam: %s", type(e).__name__)


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
        mapa_task, ultimo_mapa = None, None
        sw_task, ultimo_sw = None, None

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
            try:  # idem o mapa: tarefa própria, nunca derruba o laço
                if (not engine.frozen and (mapa_task is None or mapa_task.done())
                        and (ultimo_mapa is None or loop.time() - ultimo_mapa >= s.mapa_s)):
                    mapa_task = asyncio.create_task(run_mapa(db, r, s, datetime.now(UTC)))
                    ultimo_mapa = loop.time()
            except Exception as e:
                log.warning("agendamento do mapa falhou: %s", type(e).__name__)
            try:  # idem os switches (SNMP)
                if (not engine.frozen and (sw_task is None or sw_task.done())
                        and (ultimo_sw is None or loop.time() - ultimo_sw >= s.switch_s)):
                    sw_task = asyncio.create_task(run_switches(db, r, s, datetime.now(UTC)))
                    ultimo_sw = loop.time()
            except Exception as e:
                log.warning("agendamento dos switches falhou: %s", type(e).__name__)
            await asyncio.sleep(max(0, s.interval_s - (loop.time() - t0)))


if __name__ == "__main__":
    asyncio.run(main())
