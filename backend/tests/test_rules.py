import json
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from nodebeat.rules import AlertEngine, EqObs, EqRef, MkRef, MkState, Observation

t0 = datetime(2026, 11, 11, 14, 0, tzinfo=ZoneInfo("America/Sao_Paulo"))
mk = MkRef("1", "Cond. Alfa")


def at(s):
    return t0 + timedelta(seconds=s)


OFF = Observation(MkState.OFFLINE, "sem resposta")
OK = Observation(MkState.NO_AR)


def run(e, obs, secs):
    return [ev for s in secs for ev in e.observe_mk(mk, obs, at(s))]


def test_short_outage_no_event():
    e = AlertEngine()
    for s in (0, 30, 60, 90):
        assert e.observe_mk(mk, OFF, at(s)) == []
    assert e.observe_mk(mk, OK, at(120)) == []


def fired():
    e = AlertEngine()
    evs = run(e, OFF, (0, 30, 60, 90))
    assert evs == []
    return e, e.observe_mk(mk, OFF, at(120))


def test_outage_fires_after_120s():
    e, evs = fired()
    assert len(evs) == 1
    assert (evs[0].evento, evs[0].tipo, evs[0].inicio) == ("queda", "offline", at(0))
    assert e.observe_mk(mk, OFF, at(150)) == []


def test_return_needs_60s_stable():
    e, _ = fired()
    assert e.observe_mk(mk, OK, at(150)) == []
    assert e.observe_mk(mk, OK, at(180)) == []
    (ev,) = e.observe_mk(mk, OK, at(210))
    assert ev.evento == "retorno"
    assert (ev.inicio, ev.fim, ev.duracao_s) == (at(0), at(150), 150)


def test_flap_during_recovery_no_events():
    e, _ = fired()
    assert e.observe_mk(mk, OK, at(150)) == []
    assert e.observe_mk(mk, OFF, at(180)) == []
    assert e.observe_mk(mk, OK, at(210)) == []
    assert e.observe_mk(mk, OK, at(240)) == []
    (ev,) = e.observe_mk(mk, OK, at(270))
    assert ev.evento == "retorno" and ev.fim == at(210)


def test_type_change_while_alerting():
    e = AlertEngine()
    vpn = Observation(MkState.VPN_CAIU, "vpn")
    run(e, vpn, (0, 30, 60, 90))
    (q,) = e.observe_mk(mk, vpn, at(120))
    assert q.tipo == "vpn_caiu"
    a, b = e.observe_mk(mk, OFF, at(150))
    assert (a.evento, a.tipo) == ("encerrado", "vpn_caiu")
    assert (a.inicio, a.fim, a.duracao_s) == (at(0), at(150), 150)
    assert (b.evento, b.tipo, b.inicio) == ("queda", "offline", at(0))


def test_cpu_threshold_strict():
    e = AlertEngine()
    assert run(e, Observation(MkState.NO_AR, cpu=80.0), range(0, 181, 30)) == []
    e = AlertEngine()
    evs = run(e, Observation(MkState.NO_AR, cpu=80.1), range(0, 121, 30))
    assert [(x.evento, x.tipo) for x in evs] == [("queda", "cpu_alta")]
    e = AlertEngine()
    assert run(e, Observation(MkState.NO_AR, cpu=None), range(0, 181, 30)) == []


def test_parallel_alerts_closed_silently_on_mk_down():
    e = AlertEngine()
    hot = Observation(MkState.NO_AR, cpu=90.0)
    run(e, hot, (0, 30, 60, 90, 120))
    assert run(e, OFF, (150, 180, 210, 240)) == []
    evs = e.observe_mk(mk, OFF, at(270))
    assert [(x.evento, x.tipo) for x in evs] == [("queda", "offline"), ("encerrado", "cpu_alta")]
    more = run(e, OK, range(300, 600, 30))
    assert not [x for x in more if x.tipo == "cpu_alta"]


def test_one_probe_flap_keeps_parallel_alert_open():
    e = AlertEngine()
    hot = Observation(MkState.NO_AR, cpu=90.0)
    run(e, hot, (0, 30, 60, 90, 120))
    assert e.observe_mk(mk, OFF, at(150)) == []
    assert run(e, hot, (180, 210, 240)) == []


def test_interface_down_alert():
    e = AlertEngine()
    obs = Observation(MkState.NO_AR, ifaces={"ether1": False})
    evs = run(e, obs, range(0, 121, 30))
    assert len(evs) == 1
    assert evs[0].tipo == "interface_caida" and "ether1" in evs[0].detalhe


def test_reference_failure_freezes_mks():
    e = AlertEngine()
    evs = []
    for s in range(0, 301, 30):
        evs += e.observe_reference(False, at(s))
        evs += e.observe_mk(mk, OFF, at(s))
    assert [(x.evento, x.tipo, x.mk) for x in evs] == [("queda", "falha_sede", None)]
    assert evs[0].inicio == at(0)


def test_reference_recovery_restarts_pending():
    e = AlertEngine()
    evs = []
    for s in (0, 30, 60, 90):
        evs += e.observe_mk(mk, OFF, at(s))
    evs += e.observe_reference(False, at(90))
    assert e.frozen
    evs += e.observe_reference(True, at(100))
    assert not e.frozen
    for s in range(100, 211, 30):
        evs += e.observe_mk(mk, OFF, at(s))
    assert evs == []
    evs = e.observe_mk(mk, OFF, at(220))
    assert [(x.evento, x.tipo, x.inicio) for x in evs] == [("queda", "offline", at(100))]


def test_dump_load_preserves_open_alert():
    e, _ = fired()
    e2 = AlertEngine.load(json.loads(json.dumps(e.dump())))
    assert e2.observe_mk(mk, OK, at(150)) == []
    (ev,) = e2.observe_mk(mk, OK, at(210))
    assert ev.evento == "retorno" and ev.fim == at(150)


def test_dump_load_preserves_frozen_and_trackers():
    e = AlertEngine()
    e.observe_reference(False, at(0))
    e2 = AlertEngine.load(json.loads(json.dumps(e.dump())))
    assert e2.frozen
    (ev,) = e2.observe_reference(False, at(120))
    assert ev.tipo == "falha_sede"


def test_forget_mk_and_dropped_interface():
    e, _ = fired()
    e.forget_mk("1")
    assert e.observe_mk(mk, OK, at(150)) == []
    assert e.observe_mk(mk, OK, at(210)) == []
    e = AlertEngine()
    run(e, Observation(MkState.NO_AR, ifaces={"ether1": False}), (0, 30))
    assert run(e, OK, (60, 90, 120, 150)) == []
    down = Observation(MkState.NO_AR, ifaces={"ether1": False})
    assert run(e, down, (200, 230, 260, 290)) == []
    (ev,) = e.observe_mk(mk, down, at(320))
    assert (ev.tipo, ev.inicio) == ("interface_caida", at(200))


def test_reference_recovery_restarts_parallel_pending():
    e = AlertEngine()
    hot = Observation(MkState.NO_AR, cpu=90.0)
    evs = run(e, hot, (0, 30, 60, 90))
    evs += e.observe_reference(False, at(90))
    evs += e.observe_reference(True, at(100))
    evs += run(e, hot, (100, 120, 150, 180, 210))
    assert evs == []
    (ev,) = e.observe_mk(mk, hot, at(220))
    assert (ev.tipo, ev.inicio) == ("cpu_alta", at(100))


def test_payload_shape():
    e, evs = fired()
    p = evs[0].to_payload()
    assert set(p) == {"evento", "tipo", "mk", "detalhe", "inicio", "fim", "duracao_s", "equipamento"}
    assert p["mk"] == {"id": "1", "nome": "Cond. Alfa"}
    assert p["inicio"] == "2026-11-11T14:00:00-03:00"
    assert p["fim"] is None and p["duracao_s"] is None
    assert p["equipamento"] is None


def test_missing_interface_detalhe():
    e = AlertEngine()
    obs = Observation(MkState.NO_AR, ifaces={"ether9": False, "ether1": False},
                      missing_ifaces=frozenset({"ether9"}))
    evs = [ev for s in (0, 30, 60, 90, 120) for ev in e.observe_mk(mk, obs, at(s))]
    assert {ev.detalhe for ev in evs} == {"Interface ether9 não encontrada na MK",
                                          "Interface ether1 caída"}


def test_rename_mk_updates_name_on_return():
    e, _ = fired()
    novo = MkRef("1", "Cond. Beta")
    for s in (150, 180):
        assert e.observe_mk(novo, OK, at(s)) == []
    (ev,) = e.observe_mk(novo, OK, at(210))
    assert ev.evento == "retorno" and ev.mk == novo


def test_open_alert_survives_reference_failure():
    e, _ = fired()
    evs = []
    for s in (150, 180, 210, 240, 270):
        evs += e.observe_reference(False, at(s))
        evs += e.observe_mk(mk, OK, at(s))
    evs += e.observe_reference(True, at(300))
    assert [(x.evento, x.tipo) for x in evs] == [("queda", "falha_sede")]
    evs = run(e, OK, (300, 330, 360))
    assert [(x.evento, x.tipo, x.fim) for x in evs] == [("retorno", "offline", at(300))]


def test_type_change_while_recovering():
    e = AlertEngine()
    vpn = Observation(MkState.VPN_CAIU, "vpn")
    run(e, vpn, (0, 30, 60, 90, 120))
    assert e.observe_mk(mk, OK, at(150)) == []
    a, b = e.observe_mk(mk, OFF, at(180))
    assert (a.evento, a.tipo, a.fim) == ("encerrado", "vpn_caiu", at(180))
    assert (b.evento, b.tipo, b.inicio) == ("queda", "offline", at(0))


T0 = t0
EQ = EqRef("e1", "USW Sede", "switch")
SEDE = MkRef("sede", "Sede")


def test_switch_offline_confirma_e_payload_tem_equipamento():
    e = AlertEngine()
    assert e.observe_equipamento(EQ, SEDE, EqObs("offline"), T0, acima_fora=False) == []
    [ev] = e.observe_equipamento(EQ, SEDE, EqObs("offline"), T0 + timedelta(seconds=120), acima_fora=False)
    p = ev.to_payload()
    assert p["evento"] == "queda" and p["tipo"] == "offline"
    assert p["mk"] == {"id": "sede", "nome": "Sede"}
    assert p["equipamento"] == {"id": "e1", "nome": "USW Sede", "tipo": "switch"}
    assert p["detalhe"].startswith("USW Sede")


def test_acima_fora_nao_alerta_e_zera_pendente():
    e = AlertEngine()
    e.observe_equipamento(EQ, SEDE, EqObs("offline"), T0, acima_fora=False)
    assert e.observe_equipamento(EQ, SEDE, EqObs("offline"), T0 + timedelta(seconds=200), acima_fora=True) == []
    assert e.observe_equipamento(EQ, SEDE, EqObs("offline"), T0 + timedelta(seconds=210), acima_fora=False) == []  # recomeça


def test_uplink_caido_so_com_equipamento_no_ar():
    e = AlertEngine()
    o = EqObs("no_ar", uplinks_caidos={"0/12": "porta 0/12 sem link (4 aparelhos)"})
    e.observe_equipamento(EQ, SEDE, o, T0, acima_fora=False)
    [ev] = e.observe_equipamento(EQ, SEDE, o, T0 + timedelta(seconds=120), acima_fora=False)
    assert ev.tipo == "uplink_caido"


def test_mk_ids_ignora_equipamentos():
    e = AlertEngine(); e.observe_equipamento(EQ, SEDE, EqObs("offline"), T0, acima_fora=False)
    assert e.mk_ids() == set() and e.eq_ids() == {"e1"}
    e.forget_mk("e1")
    assert e.eq_ids() == {"e1"}


def test_load_de_engine_antigo_sem_eq():
    d = AlertEngine().dump()
    d["trackers"] = {"m1|mk": {"phase": "pending", "tipo": "offline", "detalhe": "", "primeiro": T0.isoformat(),
                               "voltou": None, "mk": {"id": "m1", "nome": "x"}}}
    assert AlertEngine.load(d).mk_ids() == {"m1"}


def test_dump_load_preserva_eq():
    e = AlertEngine(); e.observe_equipamento(EQ, SEDE, EqObs("offline"), T0, acima_fora=False)
    assert AlertEngine.load(e.dump())._t["eq:e1|eq"].eq == EQ


UP = EqObs("no_ar", uplinks_caidos={"0/12": "porta 0/12 sem link"})
NO_AR = EqObs("no_ar")


def _eq(e, o, s):
    return e.observe_equipamento(EQ, SEDE, o, T0 + timedelta(seconds=s), acima_fora=False)


def test_uplink_confirmado_que_volta_gera_retorno_apos_recover():
    e = AlertEngine()
    _eq(e, UP, 0)
    assert [x.evento for x in _eq(e, UP, 120)] == ["queda"]
    assert _eq(e, NO_AR, 130) == []
    assert _eq(e, NO_AR, 150) == []
    [ev] = _eq(e, NO_AR, 190)
    assert ev.evento == "retorno" and ev.tipo == "uplink_caido" and ev.equipamento == EQ


def test_uplink_oscilando_dentro_do_recover_nao_reabre_queda():
    e = AlertEngine()
    _eq(e, UP, 0)
    _eq(e, UP, 120)
    assert _eq(e, NO_AR, 130) == []
    assert _eq(e, UP, 150) == []
    assert _eq(e, UP, 300) == []


def test_detalhe_vazio_e_so_o_nome():
    e = AlertEngine()
    _eq(e, EqObs("offline"), 0)
    [ev] = _eq(e, EqObs("offline"), 120)
    assert ev.detalhe == "USW Sede"


def test_offline_que_vira_erro_acesso_continua_offline():
    """Oscilação ping/SNMP durante a queda não pode virar um ticket por volta (I1)."""
    e = AlertEngine(recover_s=600)
    seq = ["offline"] * 4 + ["erro_acesso"] * 3 + ["offline"] * 3 + ["erro_acesso"] * 3 + ["offline"] * 3
    evs = []
    for i, st in enumerate(seq):
        evs += e.observe_equipamento(EQ, SEDE, EqObs(st), T0 + timedelta(seconds=60 * i), acima_fora=False)
    assert [(ev.evento, ev.tipo) for ev in evs] == [("queda", "offline")]
