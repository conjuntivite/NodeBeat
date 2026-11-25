import dataclasses
import json
from datetime import timedelta

from nodebeat import store, unifi
from nodebeat.worker import run_unifi

from tests.test_worker import SET, T0, db, r  # noqa: F401  (fixtures)

CFG = dataclasses.replace(SET, unifi_url="https://unifi.example", unifi_api_key="chave-falsa")
MAC = "02:00:00:00:00:01"
EP = "/proxy/network/v2/api/site/default/system-log/"
DEV = "/proxy/network/api/s/default/stat/device"
STA = "/proxy/network/api/s/default/stat/sta"


def ev(id, ts, mac=MAC, event="CLIENT_CONNECTED_WIRED", nome="SwFalso"):
    return {"id": id, "timestamp": ts, "event": event, "severity": "LOW",
            "parameters": {"DEVICE": {"id": mac.upper(), "name": nome}, "PORT": {"name": "3"},
                           "CLIENT": {"name": "Cam"}, "IP": {"name": "198.51.100.5"}}}


def falso(devs=None, sta=None, all_=None, alerta=None, chamadas=None):
    async def ler(client, url, chave, caminho, corpo=None):
        if chamadas is not None:
            chamadas.append((caminho, corpo))
        if caminho == DEV:
            return devs if devs is not None else [
                {"type": "usw", "ip": "192.0.2.10", "mac": MAC, "name": "SwFalso", "model": "USW",
                 "port_table": [{"port_idx": 3, "up": True}]},
                {"type": "usw", "ip": "192.0.2.99", "mac": "02:00:00:00:00:09", "name": "Outro", "port_table": []}]
        if caminho == STA:
            return sta if sta is not None else [{"is_wired": True, "sw_mac": MAC.upper(), "sw_port": 3,
                                                 "mac": "02:00:00:00:00:aa", "hostname": "cam", "ip": "198.51.100.5"}]
        if caminho == EP + "all":
            return all_ or []
        if caminho == EP + "device-alert":
            return alerta or []
        raise AssertionError(caminho)
    return ler


async def com_switch(db):
    return await store.inserir_equipamento(db, {"tipo": "switch", "nome": "Core", "ip": "192.0.2.10",
                                                "local": "sede", "origem": "manual"})


async def test_sem_config_nao_chama(db, r):
    ch = []
    await run_unifi(db, r, SET, T0, ler=falso(chamadas=ch))
    assert ch == []


async def test_estado_com_clientes_na_porta(db, r):
    eq = await com_switch(db)
    await run_unifi(db, r, CFG, T0, ler=falso())
    est = json.loads(await r.get(f"unifi:eq:{eq}"))
    assert est["lido_em"] == T0.isoformat()
    assert est["portas"]["3"]["clientes"][0]["ip"] == "198.51.100.5"
    assert [k async for k in r.scan_iter("unifi:eq:*")] == [f"unifi:eq:{eq}"]  # "Outro" ignorado


async def test_eventos_sem_duplicar_e_ap_fora(db, r):
    eq = await com_switch(db)
    await store.garantir_indice_unifi(db)
    ler = falso(all_=[ev("a", 1000), ev("ap", 2000, mac="02:00:00:00:00:77", nome="ApFalso")], alerta=[ev("b", 3000)])
    await run_unifi(db, r, CFG, T0, ler=ler)
    await run_unifi(db, r, CFG, T0, ler=ler)
    docs = [d async for d in db.eventos.find({"origem": "unifi"})]
    assert sorted(d["unifi_id"] for d in docs) == ["a", "b"]
    assert {d["mk_id"] for d in docs} == {f"eq:{eq}"}


async def test_erro_mantem_estado_e_cursor(db, r, caplog):
    eq = await com_switch(db)
    await run_unifi(db, r, CFG, T0, ler=falso())
    antes = await r.get(f"unifi:eq:{eq}")
    await r.set("unifi:log:ultimo_ms", 777)

    async def quebra(*a, **k):
        raise unifi.UnifiErro("x")
    with caplog.at_level("DEBUG"):
        await run_unifi(db, r, CFG, T0 + timedelta(minutes=1), ler=quebra)
    assert await r.get(f"unifi:eq:{eq}") == antes
    assert await r.get("unifi:log:ultimo_ms") == "777"
    assert "unifi falhou" in caplog.text and "chave-falsa" not in caplog.text


async def test_estado_expira(db, r):
    eq = await com_switch(db)
    await run_unifi(db, r, CFG, T0, ler=falso())
    assert 0 < await r.ttl(f"unifi:eq:{eq}") <= 600


async def test_switch_malformado_nao_impede_o_outro(db, r):
    eq = await com_switch(db)
    outro = await store.inserir_equipamento(db, {"tipo": "switch", "nome": "B", "ip": "192.0.2.11", "local": "sede", "origem": "manual"})
    devs = [{"type": "usw", "ip": "192.0.2.11", "mac": 5, "name": "Ruim", "port_table": []},
            {"type": "usw", "ip": "192.0.2.10", "mac": MAC, "name": "SwFalso", "port_table": [{"port_idx": 3}]}]
    await run_unifi(db, r, CFG, T0, ler=falso(devs=devs))
    assert await r.get(f"unifi:eq:{eq}") and await r.get(f"unifi:eq:{outro}") is None


async def test_evento_malformado_nao_trava_nem_segura_o_cursor(db, r):
    await com_switch(db)
    await store.garantir_indice_unifi(db)
    ruim = ev("ruim", 9_000_000_000_000_000_000)  # estoura datetime
    ruim2 = ev("ruim2", "nan")
    ler = falso(all_=[ruim, ruim2, ev("ok", 4000)])
    await run_unifi(db, r, CFG, T0, ler=ler)
    assert [d["unifi_id"] async for d in db.eventos.find({"origem": "unifi"})] == ["ok"]
    assert await r.get("unifi:log:ultimo_ms") == "4000"


async def test_cursor_do_log(db, r):
    await com_switch(db)
    ch = []
    await run_unifi(db, r, CFG, T0, ler=falso(all_=[ev("a", 5_000_000)], chamadas=ch))
    corpos = [c for p, c in ch if p.startswith(EP)]
    assert corpos[0]["timestampFrom"] == int(T0.timestamp() * 1000) - 24 * 3600 * 1000
    assert corpos[0]["pageSize"] == 500 and corpos[0]["pageNumber"] == 0
    assert await r.get("unifi:log:ultimo_ms") == "5000000"
    ch.clear()
    await run_unifi(db, r, CFG, T0, ler=falso(chamadas=ch))
    assert [c for p, c in ch if p.startswith(EP)][0]["timestampFrom"] == 5_000_000 - 60_000


async def test_run_unifi_grava_retrato_uma_vez_por_5min(db, r):
    eq = await com_switch(db)
    await run_unifi(db, r, CFG, T0, ler=falso())
    await run_unifi(db, r, CFG, T0 + timedelta(minutes=1), ler=falso())
    docs = [d async for d in db.unifi_hist.find()]
    assert len(docs) == 1 and docs[0]["eq_id"] == eq and docs[0]["portas_total"] == 1
    assert 0 < await r.ttl(f"unifi:hist:{eq}") <= 300


async def test_listar_retratos_sem_portas(db):
    for i in (2, 1, 0):
        await store.inserir_retrato(db, {"eq_id": "a", "em": T0 + timedelta(minutes=i), "clientes": i, "portas": {"1": {}}})
    await store.inserir_retrato(db, {"eq_id": "b", "em": T0, "portas": {}})
    out = await store.listar_retratos(db, ["a"], T0 + timedelta(seconds=30))
    assert [d["clientes"] for d in out] == [1, 2]
    assert all("portas" not in d and "_id" not in d and d["em"].tzinfo for d in out)


async def test_falha_no_retrato_nao_quebra_run_unifi(db, r, monkeypatch):
    eq = await com_switch(db)
    await store.garantir_indice_unifi(db)

    async def quebra(*a, **k):
        raise RuntimeError("mongo fora")
    monkeypatch.setattr(store, "inserir_retrato", quebra)
    await run_unifi(db, r, CFG, T0, ler=falso(all_=[ev("a", 1000)]))
    assert json.loads(await r.get(f"unifi:eq:{eq}"))["portas"]["3"]["up"] is True
    assert [d["unifi_id"] async for d in db.eventos.find({"origem": "unifi"})] == ["a"]
