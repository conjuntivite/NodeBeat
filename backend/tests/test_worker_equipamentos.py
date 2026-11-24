import json
import logging
from datetime import timedelta

from nodebeat import crypto, history, snmp, store
from nodebeat.rules import AlertEngine
from nodebeat.webhook import QUEUE
from nodebeat.worker import run_equipamentos, sincronizar_descobertos

from tests.test_worker import KEY, SET, T0, db, doc, r  # noqa: F401  (fixtures)

SW = "10.0.0.2"


async def ping_no(_):
    return False


async def ping_ok(_):
    return True


async def fila(r):
    return [json.loads(x) for x in await r.lrange(QUEUE, 0, -1)]


async def ciclos(db, r, eng, secs, **kw):
    for s in secs:
        await run_equipamentos(db, r, eng, SET, T0 + timedelta(seconds=s), **kw)


async def manual_sede(db):
    return await store.inserir_equipamento(db, {
        "tipo": "switch", "nome": "Core", "ip": "192.168.0.2", "local": "sede", "origem": "manual",
        "community_cifrada": crypto.encrypt("public", KEY)})


async def descoberto(db, r, status_mk="no_ar"):
    mk_id = await store.insert_mk(db, doc())
    await history.save_state(r, mk_id, {"status": status_mk})
    await store.salvar_switch(db, mk_id, SW, {"gerenciavel": True, "descr": "Switch X",
                                              "community_cifrada": crypto.encrypt("public", KEY)})
    eq_id = await store.upsert_descoberto(db, "switch", mk_id, SW, "Switch X")
    return mk_id, eq_id


async def test_manual_offline_abre_ticket_depois_de_2_falhas_e_confirmacao(db, r):
    eq_id = await manual_sede(db)
    await ciclos(db, r, AlertEngine(), [0, 60, 120, 180], ping=ping_no)
    q = await fila(r)
    assert len(q) == 1
    assert q[0]["equipamento"]["tipo"] == "switch" and q[0]["mk"]["id"] == "sede"
    st = (await history.load_eq_states(r))[eq_id]
    assert st["status"] == "offline" and st["falhas"] == 4


async def test_erro_acesso_sem_ticket(db, r):
    eq_id = await manual_sede(db)

    async def ler(ip, community):
        raise snmp.SnmpErro("x")

    await ciclos(db, r, AlertEngine(), range(0, 301, 60), ping=ping_ok, ler_portas=ler)
    st = (await history.load_eq_states(r))[eq_id]
    assert st["status"] == "erro_acesso" and st["detalhe"] == "Responde ping, mas não o SNMP"
    assert await fila(r) == []


async def test_cascata_mk_fora_nao_abre_ticket(db, r):
    _, eq_id = await descoberto(db, r, status_mk="offline")
    await ciclos(db, r, AlertEngine(), range(0, 241, 60), ping=ping_no)
    assert await fila(r) == []
    assert (await history.load_eq_states(r))[eq_id]["status"] == "offline"


async def test_uplink_switch_burro_abre_ticket_e_filho_gerenciavel_nao(db, r):
    mk_id, eq_id = await descoberto(db, r)
    aps = [{"ip": SW}, {"ip": "10.0.0.20", "gerenciavel": True, "switch_ip": SW, "switch_porta": "0/5"},
           *({"ip": f"10.0.0.{30 + i}", "fixo": True, "switch_ip": SW, "switch_porta": "0/12"} for i in range(3))]
    await db.inventario_ips.insert_many([{"mk_id": mk_id, **a} for a in aps])
    vistos = []

    async def ler(ip, community):
        vistos.append(community)
        return {"0/1": {"up": True, "velocidade": 1000}, "0/5": {"up": False, "velocidade": 0},
                "0/12": {"up": False, "velocidade": 0}}

    await ciclos(db, r, AlertEngine(), [0, 60, 120], ping=ping_ok, ler_portas=ler)
    q = await fila(r)
    assert [(p["tipo"], p["detalhe"]) for p in q] == [("uplink_caido", "Switch X: porta 0/12 sem link (3 aparelhos)")]
    assert vistos[0] == "public"
    st = (await history.load_eq_states(r))[eq_id]
    assert st["status"] == "no_ar" and st["portas"]["0/1"]["velocidade"] == 1000
    assert set(st["uplinks"]) == {"0/5", "0/12"}


async def test_descoberto_que_deixa_de_ser_gerenciavel_some(db, r):
    mk_id, eq_id = await descoberto(db, r)
    eng = AlertEngine()
    await ciclos(db, r, eng, [0, 60], ping=ping_no)
    assert eq_id in eng.eq_ids() and eq_id in await history.load_eq_states(r)
    await store.salvar_switch(db, mk_id, SW, {"gerenciavel": False})
    await sincronizar_descobertos(db, r, eng)
    assert await store.get_equipamento(db, eq_id) is None
    assert eq_id not in await history.load_eq_states(r) and eq_id not in eng.eq_ids()


async def test_sincronizar_cria_descoberto_com_nome_do_descr(db, r):
    mk_id = await store.insert_mk(db, doc())
    await store.salvar_switch(db, mk_id, SW, {"gerenciavel": True, "descr": "D" * 50})
    await store.salvar_switch(db, mk_id, "10.0.0.3", {"gerenciavel": True})
    await sincronizar_descobertos(db, r, AlertEngine())
    nomes = sorted(e["nome"] for e in await store.listar_equipamentos(db, "switch"))
    assert nomes == ["10.0.0.3", "D" * 40]


async def test_community_nunca_no_log(db, r, caplog):
    await manual_sede(db)

    async def ler(ip, community):
        raise Exception(community)

    with caplog.at_level(logging.DEBUG):
        await ciclos(db, r, AlertEngine(), [0], ping=ping_ok, ler_portas=ler)
    assert "public" not in caplog.text
