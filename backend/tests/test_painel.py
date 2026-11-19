from datetime import UTC, datetime, timedelta

import pytest

from nodebeat.painel import Ctx, categoria, falha_login, montar

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


# ---- Task 2: agregação ----
AGORA = datetime(2026, 3, 5, 15, 0, tzinfo=UTC)
MKS = [{"id": "a", "nome": "Alfa"}, {"id": "b", "nome": "Beta"}]


def EV(mk, tipo, msg, atras_h=1.0, sev="info", campos=None):
    return {"mk_id": mk, "recebido_em": AGORA - timedelta(hours=atras_h), "severidade": sev, "topicos": [],
            "tipo": tipo, "campos": campos or {}, "mensagem": msg}


def falha(mk, ip="203.0.113.9", via="ssh", atras_h=1.0):
    return EV(mk, "login_falha", f"login failure for user root from {ip} via {via}", atras_h, "crit")


def M(eventos, periodo="24h", mk_id=None):
    return montar(eventos, MKS, CTX, AGORA, periodo, mk_id)


def test_resumo_conta_por_categoria():
    evs = [falha("a"), falha("a"),
           EV("a", "login_falha", "login failure for user x from 192.168.1.9 via winbox", sev="crit"),
           EV("a", "ipsec", "failed to pre-process ph2 packet."),
           EV("a", "ipsec", "ISAKMP-SA established x"),
           EV("b", "interface", "ether3 link down"),
           EV("b", "login", "user admin logged in from 192.168.1.5 via winbox",
              campos={"usuario": "admin", "ip": "192.168.1.5", "via": "winbox"})]
    assert M(evs)["resumo"] == {"acesso": 2, "autenticacao": 1, "vpn": 1, "erros": 1}


def test_periodo_recorta():
    antigo = falha("a", atras_h=25)
    assert M([antigo])["resumo"]["acesso"] == 0
    assert M([antigo], "7d")["resumo"]["acesso"] == 1


def test_top_ips_e_por_via():
    evs = [falha("a"), falha("a"), falha("b"), falha("a", ip="203.0.113.10", via="telnet")]
    b = M(evs)["blocos"]["acesso"]
    assert b["top_ips"][0] == {"ip": "203.0.113.9", "n": 3}
    assert b["por_via"] == {"ssh": 3, "telnet": 1}
    assert b["total"] == 4
    assert {x["nome"]: x["n"] for x in b["por_mk"]} == {"Alfa": 3, "Beta": 1}


def test_serie_hora_tem_todas_as_horas():
    r = M([falha("a", atras_h=0.5), falha("a", atras_h=5)])
    assert len(r["serie_hora"]) == 24
    assert sum(p["acesso"] for p in r["serie_hora"]) == r["resumo"]["acesso"] == 2


def test_logins_externos_lista_o_login_ok_de_fora():
    ev = EV("a", "login", "user admin logged in from 203.0.113.9 via ssh",
            campos={"usuario": "admin", "ip": "203.0.113.9", "via": "ssh"})
    li = M([ev])["blocos"]["acesso"]["logins_externos"]
    assert [(x["nome"], x["usuario"], x["ip"], x["via"]) for x in li] == [("Alfa", "admin", "203.0.113.9", "ssh")]


def test_interfaces_link_fisico_por_interface():
    msg = "{} excessive or late collision, link duplex mismatch?"
    evs = [EV("a", "outro", msg.format("ether3"), sev="warning")] * 2 + [EV("a", "outro", msg.format("ether4"), sev="warning")]
    ifs = M(evs)["blocos"]["erros"]["interfaces"]
    assert {(x["interface"], x["n"]) for x in ifs} == {("ether3", 2), ("ether4", 1)}


def test_vpn_ultimos_so_falhas():
    r = M([EV("a", "ipsec", "ISAKMP-SA established x"), EV("a", "ipsec", "failed to pre-process ph2 packet.")])
    assert [x["mensagem"] for x in r["blocos"]["vpn"]["ultimos"]] == ["failed to pre-process ph2 packet."]


def test_banco_vazio_devolve_estrutura_completa():
    r = M([])
    assert r["resumo"] == {"acesso": 0, "autenticacao": 0, "vpn": 0, "erros": 0}
    assert [m["nome"] for m in r["por_mk"]] == ["Alfa", "Beta"]
    assert r["atencao"] == [] and r["incidentes"] == [] and r["config"] == []
    assert set(r["blocos"]) == {"acesso", "autenticacao", "vpn", "erros"}
    assert r["blocos"]["acesso"]["top_ips"] == []


def test_filtro_mk():
    r = M([falha("a"), falha("b")], mk_id="b")
    assert [m["mk_id"] for m in r["por_mk"]] == ["b"]
    assert r["resumo"]["acesso"] == 1


def test_periodo_invalido_levanta_valueerror():
    with pytest.raises(ValueError):
        M([], "1h")
