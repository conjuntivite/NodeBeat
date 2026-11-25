from datetime import datetime, timedelta, timezone

from nodebeat import switch_painel as sp

T0 = datetime(2026, 11, 1, tzinfo=timezone.utc)


def ev(tipo, quando, porta=None, cliente=None, mk="eq:1", ip=None, mac=None):
    campos = {k: v for k, v in (("porta", porta), ("cliente", cliente), ("ip", ip), ("mac", mac)) if v}
    return {"tipo": tipo, "recebido_em": quando, "mk_id": mk, "campos": campos}


def ret(dias, **kw):
    base = {"eq_id": 1, "em": T0 + timedelta(days=dias), "poe_usado_w": None, "poe_max_w": None,
            "clientes": None, "temperatura": None, "cpu": None, "mem": None,
            "portas_total": None, "portas_em_uso": None, "rx_mbps": None, "tx_mbps": None}
    return {**base, **kw}


def test_totais_variacao_e_projecao():
    atual = [ev("cliente_desconectou", T0)] * 4 + [ev("inalcancavel", T0)] * 6
    t = sp.totais(atual, [ev("outro", T0)] * 5, 24, [{"instavel": True}, {"instavel": False}])
    assert t == {"eventos": 10, "eventos_anterior": 5, "quedas_cliente": 4,
                 "quedas_cliente_anterior": 0, "portas_instaveis": 1, "projecao_30d": 300}


def test_totais_1h_sem_projecao():
    assert sp.totais([ev("outro", T0)], [], 1, [])["projecao_30d"] is None


def test_serie_baldes_24h():
    s = sp.serie([ev("cliente_conectou", T0 + timedelta(hours=5, minutes=30))], T0, "24h")
    assert len(s) == 24
    assert s[5] == {"hora": (T0 + timedelta(hours=5)).isoformat(), "clientes": 1, "alertas": 0,
                    "poe": 0, "mudancas": 0}
    assert sum(b["clientes"] for b in s) == 1


def test_serie_30d_por_dia():
    s = sp.serie([ev("mudanca_admin", T0 + timedelta(days=2, hours=3))], T0, "30d")
    assert len(s) == 30 and s[2]["mudancas"] == 1


def test_portas_top_ordem_e_instavel():
    evs = [ev("cliente_conectou", T0, porta="1")] * 3 + [ev("cliente_desconectou", T0, porta="2")] * 2
    evs += [ev("cliente_conectou", T0)]
    r = sp.portas_top(evs, {"eq:1": "SW"}, 24)
    assert [(p["porta"], p["eventos"], p["instavel"]) for p in r] == [("1", 3, True), ("2", 2, False)]
    assert r[0]["projecao_mes"] == 90 and r[1]["projecao_mes"] == 60
    assert r[0]["switch_id"] == "eq:1" and r[0]["switch_nome"] == "SW"


def test_clientes_top():
    evs = [ev("cliente_desconectou", T0, cliente="a")] * 3 + [ev("cliente_desconectou", T0, cliente="b")]
    evs.append(ev("cliente_conectou", T0, cliente="b"))
    assert sp.clientes_top(evs, {"eq:1": "SW"}) == [
        {"cliente": "a", "switch_nome": "SW", "quedas": 3, "ip": None, "mac": None, "porta": None},
        {"cliente": "b", "switch_nome": "SW", "quedas": 1, "ip": None, "mac": None, "porta": None}]


def test_clientes_top_ultimo_ip_mac_porta_nao_nulos():
    m = "02:00:00:00:00:01"
    evs = [ev("cliente_desconectou", T0 + timedelta(hours=2), cliente="a", porta="5"),  # mais novo, sem ip/mac
           ev("cliente_desconectou", T0, cliente="a", porta="3", ip="192.0.2.1", mac=m),
           ev("cliente_desconectou", T0 + timedelta(hours=1), cliente="a", porta="4", ip="192.0.2.9")]
    r = sp.clientes_top(evs, {"eq:1": "SW"})
    assert r == [{"cliente": "a", "switch_nome": "SW", "quedas": 3, "ip": "192.0.2.9", "mac": m, "porta": "5"}]


def test_clientes_top_completa_pelo_estado_do_redis():
    m = "02:00:00:00:00:02"
    estados = {"eq:1": {"7": {"clientes": [{"nome": "pc-a", "ip": "192.0.2.7", "mac": m},
                                           {"nome": None, "ip": "192.0.2.8", "mac": "02:00:00:00:00:03"}]}}}
    evs = [ev("cliente_desconectou", T0, cliente="pc-a"), ev("cliente_desconectou", T0, cliente=m.upper(), mk="eq:1"),
           ev("cliente_desconectou", T0, cliente="02:00:00:00:00:03"), ev("cliente_desconectou", T0, cliente="zz")]
    r = {x["cliente"]: x for x in sp.clientes_top(evs, {"eq:1": "SW"}, estados=estados)}
    assert (r["pc-a"]["ip"], r["pc-a"]["mac"], r["pc-a"]["porta"]) == ("192.0.2.7", m, "7")
    assert (r[m.upper()]["ip"], r[m.upper()]["mac"]) == ("192.0.2.7", m)
    assert r["02:00:00:00:00:03"]["ip"] == "192.0.2.8"
    assert (r["zz"]["ip"], r["zz"]["mac"], r["zz"]["porta"]) == (None, None, None)


def test_projecoes_poe_subindo():
    r = [ret(d, poe_usado_w=100 + d, poe_max_w=195) for d in range(11)]
    p = sp.projecoes(r, T0 + timedelta(days=10))
    assert p["dias_historico"] == 10
    assert abs(p["poe"]["tendencia_w_dia"] - 1) < 0.01
    assert abs(p["poe"]["dias_ate_80"] - 46) < 0.5


def test_projecoes_estavel_ou_caindo_da_none():
    r = [ret(d, poe_usado_w=100 - d, poe_max_w=195, temperatura=40.0) for d in range(11)]
    p = sp.projecoes(r, T0)
    assert p["poe"]["dias_ate_80"] is None and p["poe"]["tendencia_w_dia"] < 0
    assert p["temperatura"]["tendencia_c_semana"] == 0


def test_projecoes_menos_de_7_dias_tudo_none():
    r = [ret(d, poe_usado_w=100 + d, poe_max_w=195) for d in range(5)]
    p = sp.projecoes(r, T0)
    assert p == {"dias_historico": 4, "poe": None, "temperatura": None, "portas": None}


def test_projecoes_sem_poe_max():
    r = [ret(d, poe_usado_w=100 + d, temperatura=40 + d) for d in range(11)]
    p = sp.projecoes(r, T0)
    assert p["poe"] is None and abs(p["temperatura"]["tendencia_c_semana"] - 7) < 0.01


def test_projecoes_portas_ate_cheio():
    r = [ret(d, portas_total=24, portas_em_uso=10 + d) for d in range(11)]
    assert abs(sp.projecoes(r, T0)["portas"]["dias_ate_cheio"] - 4) < 0.01


def test_reduzir_200():
    r = [ret(i / 10, poe_usado_w=None if i % 2 else 10, clientes=5) for i in range(1000)]
    out = sp.reduzir(r)
    assert len(out) <= 200
    assert all(o["poe_usado_w"] == 10 and o["clientes"] == 5 and o["temperatura"] is None for o in out)


def test_serie_alinha_ao_balde():
    desde = T0 + timedelta(hours=-24, minutes=17)  # agora = T0 + 17 min
    s = sp.serie([ev("cliente_conectou", T0 + timedelta(minutes=10))], desde, "24h")
    assert len(s) == 24
    assert s[0]["hora"] == (T0 - timedelta(hours=23)).isoformat() and s[-1]["hora"] == T0.isoformat()
    assert s[-1]["clientes"] == 1


def test_projecoes_6_6_dias_floor_e_sem_projecao():
    r = [ret(0, poe_usado_w=100, poe_max_w=195), ret(6.6, poe_usado_w=110, poe_max_w=195)]
    assert sp.projecoes(r, T0) == {"dias_historico": 6, "poe": None, "temperatura": None, "portas": None}


def test_projecoes_inteiras():
    r = [ret(d, poe_usado_w=100 + d, poe_max_w=195, portas_total=24, portas_em_uso=10 + d) for d in range(11)]
    p = sp.projecoes(r, T0)
    assert p["poe"]["dias_ate_80"] == 46 and isinstance(p["poe"]["dias_ate_80"], int)
    assert p["portas"]["dias_ate_cheio"] == 4 and isinstance(p["portas"]["dias_ate_cheio"], int)


def test_projecao_30d_e_mes_inteiros():
    t = sp.totais([ev("outro", T0)] * 7, [], 7 * 24, [])
    assert t["projecao_30d"] == 30 and isinstance(t["projecao_30d"], int)
    r = sp.portas_top([ev("cliente_conectou", T0, porta="1")] * 3, {}, 7 * 24)
    assert r[0]["projecao_mes"] == 13 and isinstance(r[0]["projecao_mes"], int)


def test_portas_instaveis_conta_todas_as_portas():
    evs = [ev("cliente_conectou", T0, porta=str(i)) for i in range(1, 13) for _ in range(3)]
    t = sp.totais(evs, [], 24, sp.portas_top(evs, {}, 24, n=None))
    assert t["portas_instaveis"] == 12
    assert len(sp.portas_top(evs, {}, 24)) == 10


def test_switch_removido():
    evs = [ev("cliente_desconectou", T0, porta="1", cliente="a", mk="eq:9")]
    assert sp.portas_top(evs, {}, 24)[0]["switch_nome"] == "Switch removido"
    assert sp.clientes_top(evs, {})[0]["switch_nome"] == "Switch removido"
