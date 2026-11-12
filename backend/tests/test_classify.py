from nodebeat.classify import classify
from nodebeat.routeros import Snapshot
from nodebeat.rules import MkState

SNAP = Snapshot("7.15", 12.0, 40.0, "1d", {"ether1": True, "ether2": False, "ether3": True})


def test_snapshot_is_no_ar():
    o = classify(SNAP, None, False, False, ["ether2", "ether1"])
    assert o.state == MkState.NO_AR
    assert (o.cpu, o.mem) == (12.0, 40.0)
    assert list(o.ifaces.items()) == [("ether2", False), ("ether1", True)]
    assert o.missing_ifaces == frozenset()


def test_missing_watched_interface_is_down():
    o = classify(SNAP, None, None, None, ["ether9"])
    assert o.ifaces == {"ether9": False}
    assert o.missing_ifaces == frozenset({"ether9"})
    assert "interface não encontrada: ether9" in o.detalhe


def test_api_fail_tunnel_ok_is_erro_acesso():
    o = classify(None, "login falhou", True, True, [])
    assert (o.state, o.detalhe) == (MkState.ERRO_ACESSO, "login falhou")
    assert classify(None, None, True, None, []).detalhe == "API sem resposta"


def test_vpn_caiu():
    o = classify(None, "x", False, True, [])
    assert (o.state, o.detalhe) == (MkState.VPN_CAIU, "Túnel sem resposta; IP público responde")


def test_offline():
    o = classify(None, "x", False, False, [])
    assert (o.state, o.detalhe) == (MkState.OFFLINE, "Túnel e IP público sem resposta")
