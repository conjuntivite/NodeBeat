from datetime import UTC, datetime, timedelta

from nodebeat.portas import atualizar, estado_porta, fisica_mk

T = datetime(2026, 1, 1, 12, tzinfo=UTC)


def test_fisica_mk():
    assert all(fisica_mk(n) for n in ["ether1", "sfp-sfpplus1", "combo1", "SFP1", "qsfp28-1-1"])
    assert not any(fisica_mk(n) for n in ["bridge", "vlan10", "pppoe-out1", "wg0", "lo", "ipsec-x", "ovpn-in"])


def test_atualizar_marca_caiu_so_na_queda():
    a = atualizar(None, {"ether1": True, "ether2": False}, T)
    assert a["ether1"]["caiu_em"] is None and a["ether2"]["caiu_em"] is None  # nunca teve link: não "caiu"
    b = atualizar(a, {"ether1": False, "ether2": False}, T + timedelta(minutes=1))
    assert b["ether1"]["caiu_em"] == (T + timedelta(minutes=1)).isoformat()
    assert b["ether1"]["desde"] == (T + timedelta(minutes=1)).isoformat()
    c = atualizar(b, {"ether1": False}, T + timedelta(minutes=2))
    assert c["ether1"]["caiu_em"] == b["ether1"]["caiu_em"] and "ether2" not in c
    assert atualizar(c, {"ether1": True}, T + timedelta(minutes=3))["ether1"]["caiu_em"] is None


def test_atualizar_preserva_velocidade_e_inicia_em_none():
    a = atualizar(None, {"ether1": True}, T)
    assert a["ether1"]["velocidade"] is None
    a["ether1"]["velocidade"] = "1G"
    b = atualizar(a, {"ether1": False}, T + timedelta(minutes=1))
    assert b["ether1"]["velocidade"] == "1G"


def test_estado_porta_caiu_vira_down_depois_de_24h():
    p = {"up": False, "caiu_em": T.isoformat()}
    assert estado_porta(p, T + timedelta(hours=23)) == "caiu"
    assert estado_porta(p, T + timedelta(hours=24, seconds=1)) == "down"
    assert estado_porta({"up": True, "caiu_em": None}, T) == "up"
    assert estado_porta({"up": False, "caiu_em": None}, T) == "down"
