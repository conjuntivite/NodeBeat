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

from . import crypto, history, inventario, mapa, probes
from . import portas as portas_mod
from . import routeros, snmp, store, switches, webhook
from .classify import classify
from .config import Settings, load_settings
from .rules import AlertEngine, EqObs, EqRef, MkRef, MkState

log = logging.getLogger(__name__)

PEDIDO_INVENTARIO = "inventario:pedido"
REINICIO = "reinicio:"  # + id da MK; TTL = janela sem alerta após reinício pelo painel
JANELA_REINICIO = 300
CARENCIA_RETORNO_S = 300  # MK/switch pai que acabou de voltar: o de baixo ainda está subindo (energia)
TIMEOUT_EQ_S = 20  # um switch lento não segura a rodada dos outros
RECOVER_S = 600  # MK oscilando (cai/volta) dentro dessa janela é UM incidente = um ticket só
# pool próprio: o inventário (até 10 s por MK offline) não pode ocupar as threads do ciclo de 30 s
_POOL_INVENTARIO = ThreadPoolExecutor(max_workers=10, thread_name_prefix="inventario")


async def _emit(r, evs) -> None:
    for ev in evs:
        await history.record(r, ev)
        # o webhook abre ticket no sistema de chamados; o retorno fica só no histórico.
        # Erro de acesso (MK responde ping, API não) não abre ticket: só painel/histórico.
        if ev.evento == "queda" and ev.tipo != MkState.ERRO_ACESSO.value:
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
    if ok:
        portas = portas_mod.atualizar(
            (ant or {}).get("portas"), {n: v for n, v in snap.ifaces.items() if portas_mod.fisica_mk(n)}, now)
    else:
        portas = (ant or {}).get("portas", {})  # sem leitura não se sabe o link
    # entre tipos de queda (offline/vpn_caiu/erro_acesso) o relógio continua: conta desde que saiu do ar
    mesmo = ant and (ant["status"] == status or (ant["status"] != "no_ar" and not ok))
    desde = ant["desde"] if mesmo else now.isoformat()
    await history.save_state(r, mk["id"], {
        "status": status, "detalhe": obs.detalhe, "desde": desde,
        "cpu": obs.cpu if ok else None, "mem": obs.mem if ok else None,
        "uptime": snap.uptime if ok else None, "ifaces": obs.ifaces if ok else {},
        "portas_link": dict(snap.ifaces) if ok else {}, "portas": portas,
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


async def run_switches(db, r, settings: Settings, now: datetime, *, engine: AlertEngine | None = None,
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
        await sincronizar_descobertos(db, r, engine)
    except Exception as e:
        log.warning("switches falharam: %s", type(e).__name__)


async def sincronizar_descobertos(db, r, engine: AlertEngine | None) -> None:
    """Switch gerenciável vira equipamento descoberto; o que deixou de ser some (estado e trackers)."""
    vivos = set()
    manuais = {(e["local"], e["ip"]) for e in await store.listar_equipamentos(db) if e.get("origem") == "manual"}
    async for s in db.switches.find({"gerenciavel": True}):
        if (s["mk_id"], s["ip"]) in manuais:  # o operador já cadastrou: não duplica
            continue
        nome = (s.get("descr") or "")[:40] or s["ip"]
        vivos.add(await store.upsert_descoberto(db, "switch", s["mk_id"], s["ip"], nome))
    for eq in await store.listar_equipamentos(db):
        if eq.get("origem") == "descoberto" and eq["id"] not in vivos:
            await store.apagar_equipamento(db, eq["id"])
            await history.delete_eq(r, eq["id"])
            if engine is not None:
                engine.forget_eq(eq["id"])


SEM_SNMP_EQ = "Responde ping, mas não o SNMP"
SEM_PING_EQ = "Sem resposta ao ping"


def _voltou_ha_pouco(estado: dict, now: datetime) -> bool:
    try:
        desde = datetime.fromisoformat(estado["desde"])
    except (KeyError, TypeError, ValueError):
        return False
    return estado.get("status") == "no_ar" and (now - desde).total_seconds() < CARENCIA_RETORNO_S


async def _equipamento(r, engine, settings, now, eq, ctx, ping, ler_portas) -> None:
    # a community é segredo: nunca no log, no erro ou em texto puro no banco
    antes, mks, mk_estados, ips, sws, por_ip = ctx
    ant = antes.get(eq["id"]) or {}
    ip, local = eq["ip"], eq["local"]
    portas = ant.get("portas", {})
    ups = ant.get("uplinks", {})
    caidos: dict[str, str] = {}
    observar = True
    if await ping(ip):
        falhas = 0
        cifrada = (eq.get("community_cifrada") if eq.get("origem") == "manual"
                   else sws.get(local, {}).get(ip, {}).get("community_cifrada"))
        lidas = None
        try:
            lidas = await ler_portas(ip, crypto.decrypt(cifrada or "", settings.secret_key))
        except (ValueError, snmp.SnmpErro):
            pass
        except Exception as e:
            log.warning("equipamento %s: portas: %s", eq["id"], type(e).__name__)
        if lidas is None:
            status, detalhe = "erro_acesso", SEM_SNMP_EQ
        else:
            status, detalhe = "no_ar", ""
            portas = portas_mod.atualizar(portas, {n: p["up"] for n, p in lidas.items()}, now)
            for n, p in portas.items():
                p["velocidade"] = lidas[n].get("velocidade")
            ups = switches.uplinks(ip, ips.get(local, [])) if eq.get("origem") == "descoberto" else {}
            caidos = {p: f"porta {p} sem link ({u['vigiados']} aparelhos)" for p, u in ups.items()
                      if u["filho"] is None and p in portas and not portas[p]["up"]}
    else:
        falhas = ant.get("falhas", 0) + 1
        if falhas >= 2:
            status, detalhe = "offline", SEM_PING_EQ
        else:  # 1ª falha: mantém o anterior, sem passar pelo motor (como mapa.proximo_estado)
            status, detalhe = ant.get("status", "desconhecido"), ant.get("detalhe", "")
            observar = False
    if observar:
        if local == "sede":
            local_ref, acima_fora = MkRef("sede", "Sede"), False
        else:
            local_ref = MkRef(local, mks.get(local, {}).get("nome", local))
            pai_ip = next((a.get("switch_ip") for a in ips.get(local, []) if a["ip"] == ip), None)
            pai = antes.get(por_ip.get((local, pai_ip)), {})
            mk_est = mk_estados.get(local, {})
            acima_fora = (mk_est.get("status") != "no_ar" or _voltou_ha_pouco(mk_est, now)
                          or pai.get("status") == "offline"  # pai em erro_acesso ainda responde: não silencia
                          or _voltou_ha_pouco(pai, now))
        await _emit(r, engine.observe_equipamento(EqRef(eq["id"], eq["nome"], eq["tipo"]), local_ref,
                                                  EqObs(status, detalhe, caidos), now, acima_fora=acima_fora))
    mesmo = ant and (ant.get("status") == status or (ant.get("status") != "no_ar" and status != "no_ar"))
    await history.save_eq_state(r, eq["id"], {
        "status": status, "detalhe": detalhe, "desde": ant["desde"] if mesmo else now.isoformat(),
        "falhas": falhas, "portas": portas, "uplinks": ups, "atualizado_em": now.isoformat()})


async def run_equipamentos(db, r, engine: AlertEngine, settings: Settings, now: datetime, *,
                           ping=probes.ping, ler_portas=switches.ler_portas) -> None:
    """Pinga e lê as portas de cada switch cadastrado; alerta pelo motor; nunca levanta."""
    try:
        todos = await store.listar_equipamentos(db)
        ids = {e["id"] for e in todos}  # limpeza por todos os tipos; só o switch é monitorado
        eqs = [e for e in todos if e["tipo"] == "switch"]
        for id in engine.eq_ids() - ids:
            engine.forget_eq(id)
        antes = await history.load_eq_states(r)
        for id in antes.keys() - ids:
            await history.delete_eq(r, id)
        locais = {e["local"] for e in eqs} - {"sede"}
        ctx = (antes, {m["id"]: m for m in await store.list_mks(db)}, await history.load_states(r),
               {m: await store.listar_ips(db, m) for m in locais},
               {m: {s["ip"]: s for s in await store.listar_switches(db, m)} for m in locais},
               {(e["local"], e["ip"]): e["id"] for e in eqs})
        sem = asyncio.Semaphore(10)

        async def um(eq):
            async with sem:
                try:
                    async with asyncio.timeout(TIMEOUT_EQ_S):  # estourou: fica para a próxima rodada
                        await _equipamento(r, engine, settings, now, eq, ctx, ping, ler_portas)
                except Exception as e:
                    log.warning("equipamento %s: %s", eq.get("id"), type(e).__name__)

        await asyncio.gather(*(um(e) for e in eqs))
    except Exception as e:
        log.warning("equipamentos falharam: %s", type(e).__name__)


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
        eq_task, ultimo_eq = None, None

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
            try:  # tarefa própria como o mapa; os métodos do motor são síncronos (sem corrida), o run_cycle persiste
                if (not engine.frozen and (eq_task is None or eq_task.done())
                        and (ultimo_eq is None or loop.time() - ultimo_eq >= s.mapa_s)):
                    eq_task = asyncio.create_task(run_equipamentos(db, r, engine, s, datetime.now(UTC)))
                    ultimo_eq = loop.time()
            except Exception as e:
                log.warning("agendamento dos equipamentos falhou: %s", type(e).__name__)
            try:  # idem os switches (SNMP)
                if (not engine.frozen and (sw_task is None or sw_task.done())
                        and (ultimo_sw is None or loop.time() - ultimo_sw >= s.switch_s)):
                    sw_task = asyncio.create_task(run_switches(db, r, s, datetime.now(UTC), engine=engine))
                    ultimo_sw = loop.time()
            except Exception as e:
                log.warning("agendamento dos switches falhou: %s", type(e).__name__)
            await asyncio.sleep(max(0, s.interval_s - (loop.time() - t0)))


if __name__ == "__main__":
    asyncio.run(main())
