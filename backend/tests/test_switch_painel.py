from datetime import datetime, timedelta, timezone

from nodebeat import switch_painel as sp

T0 = datetime(2026, 11, 1, tzinfo=timezone.utc)


def ev(tipo, quando, porta=None, cliente=None, mk="eq:1"):
    campos = {k: v for k, v in (("porta", porta), ("cliente", cliente)) if v}
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
        {"cliente": "a", "switch_nome": "SW", "quedas": 3}, {"cliente": "b", "switch_nome": "SW", "quedas": 1}]


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
