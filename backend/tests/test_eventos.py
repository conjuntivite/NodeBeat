import pytest
from datetime import UTC, datetime
from nodebeat.eventos import TIPOS, classificar, evento, parse, ruido

def test_parse_topicos_e_mensagem():
    p = parse(b"system,info,account user admin logged in from 192.0.2.5 via winbox")
    assert p == {"severidade": "info", "topicos": ["system", "info", "account"],
                 "mensagem": "user admin logged in from 192.0.2.5 via winbox"}

def test_severidade_pelos_topicos():
    assert parse(b"system,error,critical login failure for user admin from 192.0.2.5 via winbox")["severidade"] == "crit"
    assert parse(b"ipsec,error x")["severidade"] == "err"
    assert parse(b"system,warning x")["severidade"] == "warning"
    assert parse(b"ipsec,debug,packet x")["severidade"] == "debug"

def test_linha_sem_topicos():
    assert parse(b"Ola Mundo: algo") == {"severidade": "info", "topicos": [], "mensagem": "Ola Mundo: algo"}

def test_config_v7_extrai_campos():
    tipo, campos = classificar(["system", "info"], "log rule added by tcp-msg(winbox):admin@203.0.113.10/terminal (*9 = /system logging add)", "info")
    assert tipo == "config" and campos == {"objeto": "log rule", "acao": "added", "usuario": "admin", "via": "winbox", "ip": "203.0.113.10"}

def test_ruido():
    mon = evento(b"system,info,account user monitor logged in from 192.0.2.53 via api", "mk1", datetime.now(UTC))
    assert ruido(mon, "192.0.2.53") and not ruido(mon, "192.0.2.99")
    assert ruido(evento(b"pppoe,ppp,debug,packet x", "mk1", datetime.now(UTC)), None)
    assert not ruido(evento(b"system,info,account user admin logged in from 192.0.2.53 via winbox", "mk1", datetime.now(UTC)), "192.0.2.53")

@pytest.mark.parametrize("msg,tipo,campos", [
    ("user admin logged in from 192.0.2.5 via winbox", "login", {"usuario": "admin", "ip": "192.0.2.5", "via": "winbox"}),
    ("login failure for user admin from 192.0.2.5 via ssh", "login_falha", {"usuario": "admin", "ip": "192.0.2.5", "via": "ssh"}),
    ("user admin logged out from 192.0.2.5 via winbox", "logout", {"usuario": "admin", "ip": "192.0.2.5", "via": "winbox"}),
    ("log rule added by admin", "config", {"objeto": "log rule", "acao": "added", "usuario": "admin"}),
    ("ether1 link down", "interface", {"interface": "ether1", "estado": "down"}),
    ("ether1 link up (speed 1G, full duplex)", "interface", {"interface": "ether1", "estado": "up"}),
    ("dhcp1 assigned 192.168.88.10 to 02:00:00:00:00:01", "dhcp", {"servidor": "dhcp1", "ip": "192.168.88.10", "mac": "02:00:00:00:00:01"}),
    ("router rebooted", "reboot", {}),
])
def test_classificar(msg, tipo, campos):
    assert classificar(["system", "info"], msg, "info") == (tipo, campos)

def test_ipsec_e_pppoe_por_topico():
    assert classificar(["ipsec", "error"], "phase1 negotiation failed due to time up 198.51.100.7[500]", "err")[0] == "ipsec"
    assert classificar(["pppoe", "ppp", "info"], "pppoe-out1: connected", "info") == ("pppoe", {"interface": "pppoe-out1", "estado": "connected"})

def test_erro_e_outro():
    assert classificar(["system", "critical"], "algo estranho", "crit")[0] == "erro"
    assert classificar(["system", "info"], "qualquer coisa", "info") == ("outro", {})

def test_lixo_nao_quebra():
    for dado in [b"", b",,,", b"<13>Nov 18 10:00:01 MK - Teste x", bytes(range(256)), b"x" * 5000]:
        e = evento(dado, "mk1", datetime.now(UTC))
        assert e["tipo"] in TIPOS and len(e["mensagem"]) <= 2048

def test_amostras_reais_classificam():  # Task 0: cada linha tem o tipo esperado no fim, após " ## "
    for linha in open("tests/amostras_syslog.txt", encoding="utf-8").read().splitlines():
        cru, esperado = linha.rsplit(" ## ", 1)
        assert evento(cru.encode(), "mk1", datetime.now(UTC))["tipo"] == esperado, cru
