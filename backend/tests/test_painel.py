from datetime import UTC, datetime

from nodebeat.painel import Ctx, categoria, falha_login

CTX = Ctx(["10.1.0.0/16"], ["198.51.100.7"])
T = datetime(2026, 3, 5, 12, 0, tzinfo=UTC)


def E(tipo, msg, sev="info", campos=None, topicos=()):
    return {"mk_id": "a", "recebido_em": T, "severidade": sev, "topicos": list(topicos), "tipo": tipo,
            "campos": campos or {}, "mensagem": msg}


def test_falha_de_ip_publico_e_acesso():
    ev = E("login_falha", "login failure for user root from 203.0.113.9 via ssh", "crit")
    assert categoria(ev, CTX) == ("acesso", "falha_externa")


def test_falha_usuario_vazio_tipo_erro_e_acesso():
    ev = E("erro", "login failure for user  from 203.0.113.9 via telnet", "crit")
    assert categoria(ev, CTX) == ("acesso", "falha_externa")
    assert falha_login(ev) == ("", "203.0.113.9", "telnet")


def test_falha_de_ip_privado_ou_da_sede_e_autenticacao():
    for ip in ("192.168.40.5", "10.1.2.3", "198.51.100.7"):
        ev = E("login_falha", f"login failure for user admin from {ip} via winbox", "crit")
        assert categoria(ev, CTX) == ("autenticacao", "falha_interna"), ip


def test_login_de_fora_e_acesso_login_externo_ok():
    de_fora = E("login", "user admin logged in from 203.0.113.9 via ssh",
                campos={"usuario": "admin", "ip": "203.0.113.9", "via": "ssh"})
    assert categoria(de_fora, CTX) == ("acesso", "login_externo_ok")
    monitor = E("login", "user monitor logged in from 203.0.113.9 via api",
                campos={"usuario": "monitor", "ip": "203.0.113.9", "via": "api"})
    assert categoria(monitor, CTX) == ("autenticacao", "login_ok")
    interno = E("login", "user admin logged in from 192.168.1.5 via winbox",
                campos={"usuario": "admin", "ip": "192.168.1.5", "via": "winbox"})
    assert categoria(interno, CTX) == ("autenticacao", "login_ok")
    assert categoria(E("logout", "user admin logged out from 192.168.1.5 via winbox"), CTX) is None


def test_pppoe_authentication_failed_e_autenticacao():
    ev = E("pppoe", "<198.51.100.7>: user teste authentication failed", "err")
    assert categoria(ev, CTX) == ("autenticacao", "pppoe_auth")
    assert categoria(E("pppoe", "pppoe-out1: terminating...", "err"), CTX) == ("erros", "pppoe")
    assert categoria(E("pppoe", "pppoe-out1: connected", "info"), CTX) is None


def test_ipsec():
    assert categoria(E("ipsec", "203.0.113.9 failed to pre-process ph2 packet."), CTX) == ("vpn", "falha")
    assert categoria(E("ipsec", "qualquer coisa", "err"), CTX) == ("vpn", "falha")
    ok = "ISAKMP-SA established 203.0.113.9[500]-203.0.113.10[500] spi:ef66"
    assert categoria(E("ipsec", ok), CTX) == ("vpn", "ok")
    assert categoria(E("ipsec", "initiate new phase 1 (Aggressive): 203.0.113.9[500]"), CTX) == ("vpn", "ok")


def test_erros_fisicos_e_gerais():
    colisao = E("outro", "ether3 excessive or late collision, link duplex mismatch?", "warning")
    assert categoria(colisao, CTX) == ("erros", "link_fisico")
    assert categoria(E("interface", "ether4 link down"), CTX) == ("erros", "interface_down")
    assert categoria(E("interface", "ether4 link up (speed 1G, full duplex)"), CTX) is None
    assert categoria(E("reboot", "router rebooted"), CTX) == ("erros", "reboot")
    assert categoria(E("erro", "ssl: no common ciphers", "err"), CTX) == ("erros", "erro")
    sem_ip = E("erro", "login failure for user x from lixo via ssh", "err")
    assert categoria(sem_ip, CTX) == ("erros", "erro")
    for ev in (E("outro", "algo"), E("config", "log rule added by admin"), E("dhcp", "x assigned")):
        assert categoria(ev, CTX) is None
