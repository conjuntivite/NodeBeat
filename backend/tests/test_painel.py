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


def test_evento_depois_de_agora_nao_derruba_o_painel():
    # chegou entre `agora` e a leitura, já na hora seguinte da série
    r = M([falha("a", atras_h=-1.5), falha("a", atras_h=0.5)])
    assert r["resumo"]["acesso"] == 1


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
    assert [(a["nome"], a["motivo"]) for a in r["atencao"]] == [("Alfa", "Nunca mandou eventos"),
                                                                ("Beta", "Nunca mandou eventos")]
    assert r["incidentes"] == [] and r["config"] == []
    assert set(r["blocos"]) == {"acesso", "autenticacao", "vpn", "erros"}
    assert r["blocos"]["acesso"]["top_ips"] == []


def test_filtro_mk():
    r = M([falha("a"), falha("b")], mk_id="b")
    assert [m["mk_id"] for m in r["por_mk"]] == ["b"]
    assert r["resumo"]["acesso"] == 1


def test_painel_ignora_eventos_de_equipamento():
    base = [falha("a"), EV("b", "interface", "ether3 link down")]
    com_eq = base + [falha("eq:x"), EV("eq:x", "interface", "ether3 link down"),
                     EV("eq:x", "reboot", "system rebooted")]
    assert M(com_eq) == M(base)
    assert all(m["mk_id"] in ("a", "b") for m in M(com_eq)["por_mk"])


def test_periodo_invalido_levanta_valueerror():
    with pytest.raises(ValueError):
        M([], "1h")


# ---- Task 3: semáforo, incidentes, mudanças, habitual ----
def sem(r, mk="a"):
    m = next(x for x in r["por_mk"] if x["mk_id"] == mk)
    return m["semaforo"], " | ".join(m["motivos"])


def vida(mk):
    """Evento neutro recente: tira a MK do 'silêncio' sem contar como problema."""
    return EV(mk, "outro", "x", 0.5)


def down(mk, atras_h, iface="ether3"):
    return EV(mk, "interface", f"{iface} link down", atras_h)


def test_login_de_fora_deixa_vermelho():
    ev = EV("a", "login", "user admin logged in from 203.0.113.9 via ssh",
            campos={"usuario": "admin", "ip": "203.0.113.9", "via": "ssh"})
    cor, motivo = sem(M([ev, vida("b")]))
    assert cor == "vermelho" and "Login de fora" in motivo


def test_dois_reboots_em_24h_vermelho():
    r2 = M([EV("a", "reboot", "router rebooted", 2), EV("a", "reboot", "router rebooted", 5)])
    assert sem(r2)[0] == "vermelho"
    assert sem(M([EV("a", "reboot", "router rebooted", 2), vida("a")]))[0] == "verde"


def test_oscilacao_de_interface():
    cor, motivo = sem(M([down("a", 1.0), down("a", 1.2), down("a", 1.6)]))
    assert cor == "vermelho" and "ether3" in motivo
    assert sem(M([down("a", 1.0), down("a", 1.2), vida("a")]))[0] == "verde"
    assert sem(M([down("a", 1.0), down("a", 2.5), down("a", 4.0)]))[0] == "verde"


def test_falhas_de_vpn_em_1h_vermelho():
    evs = [EV("a", "ipsec", "failed to pre-process ph2 packet.", h) for h in (1.0, 1.2, 1.5)]
    cor, motivo = sem(M(evs))
    assert cor == "vermelho" and "VPN" in motivo


def test_queda_em_massa_pppoe():
    evs = [EV("a", "pppoe", "pppoe-out1: terminating...", 1 + i / 100, "err") for i in range(10)]
    cor, motivo = sem(M(evs))
    assert cor == "vermelho" and "PPPoE" in motivo
    auth = [EV("a", "pppoe", "<198.51.100.7>: user teste authentication failed", 1 + i / 100, "err") for i in range(30)]
    assert sem(M(auth + [vida("a")]))[0] == "verde"


def test_silencio_amarelo():
    assert sem(M([EV("a", "outro", "x", 25)]))[1] == "Sem eventos há mais de 24 h"
    assert sem(M([EV("a", "outro", "x", 25)]))[0] == "amarelo"
    assert sem(M([]))[1] == "Nunca mandou eventos"
    assert sem(M([EV("a", "outro", "x", 23)]))[0] == "verde"


def _erros(n, atras_ini_h, mk="a"):
    return [EV(mk, "erro", "ssl: no common ciphers", atras_ini_h + i * 0.001, "err") for i in range(n)]


def test_acima_do_habitual():
    base = _erros(35, 48)  # 35 erros nos 7 dias anteriores: media 5/dia
    cor, motivo = sem(M(base + _erros(20, 3)))
    assert cor == "amarelo" and "Acima do habitual" in motivo
    assert sem(M(base + _erros(19, 3)))[0] == "verde"


def test_enxurrada_de_acesso_externo_nao_marca_habitual():
    assert sem(M([falha("a", atras_h=1 + i / 1000) for i in range(200)] + [vida("a")]))[0] == "verde"


def test_incidente_correlacionado():
    mks3 = MKS + [{"id": "c", "nome": "Gama"}]
    evs = [down("a", 2.0), down("b", 2.05), down("c", 2.1)]
    r = montar(evs, mks3, CTX, AGORA, "24h")
    assert len(r["incidentes"]) == 1
    assert r["incidentes"][0]["sintoma"] == "interface_down"
    assert sorted(r["incidentes"][0]["mks"]) == ["Alfa", "Beta", "Gama"]
    assert M([down("a", 2.0), down("b", 2.05)])["incidentes"] == []
    assert montar([down("a", 2.0), down("a", 2.01), down("a", 2.02)], mks3, CTX, AGORA, "24h")["incidentes"] == []


def test_config_fora_do_horario():
    def cfg(h):
        e = EV("a", "config", "log rule added by admin", campos={"objeto": "log rule", "acao": "added", "usuario": "admin"})
        e["recebido_em"] = h
        return e
    r = M([cfg(datetime(2026, 3, 5, 1, 0, tzinfo=UTC)), cfg(datetime(2026, 3, 5, 12, 0, tzinfo=UTC))])
    assert [(c["fora_horario"], c["usuario"], c["objeto"], c["acao"]) for c in r["config"]] == [
        (False, "admin", "log rule", "added"), (True, "admin", "log rule", "added")]  # mais recentes primeiro


def test_usuario_novo():
    def cfg(user, atras_h):
        return EV("a", "config", f"x added by {user}", atras_h,
                  campos={"objeto": "x", "acao": "added", "usuario": user})
    r = M([cfg("admin", 120), cfg("fulano", 2)])
    assert sem(r) == ("amarelo", "Usuário novo: fulano")
    assert [c["usuario_novo"] for c in r["config"]] == [True]
    r2 = M([cfg("admin", 120), cfg("admin", 2)])
    assert [c["usuario_novo"] for c in r2["config"]] == [False]
    r3 = M([cfg("fulano", 2)])  # sem historico anterior: nao marca
    assert r3["config"][0]["usuario_novo"] is False


def test_atencao_ordena_vermelho_primeiro():
    evs = [EV("a", "outro", "x", 25), EV("b", "reboot", "router rebooted", 2), EV("b", "reboot", "router rebooted", 3)]
    at = M(evs)["atencao"]
    assert [(a["nome"], a["semaforo"]) for a in at] == [("Beta", "vermelho"), ("Alfa", "amarelo")]


def test_filtro_mk_mantem_incidente_da_mk():
    mks3 = MKS + [{"id": "c", "nome": "Gama"}]
    evs = [down("a", 2.0), down("b", 2.05), down("c", 2.1)]
    assert len(montar(evs, mks3, CTX, AGORA, "24h", "a")["incidentes"]) == 1
    assert montar(evs + [vida("a")], MKS + [{"id": "d", "nome": "Delta"}], CTX, AGORA, "24h", "d")["incidentes"] == []


# ---- Refino: resumo_estado (estado e variação por categoria) ----
def est(r, cat):
    return r["resumo_estado"][cat]


def historia(n_base=14, mais_antigo_h=192):
    """n_base falhas na janela dos 7 dias anteriores ao período de 24 h + um evento mais antigo que a janela."""
    base = [falha("a", atras_h=30 + 10 * i) for i in range(n_base)]
    return base + [falha("a", atras_h=mais_antigo_h)]


def test_resumo_estado_tem_as_quatro_categorias_mesmo_vazio():
    r = M([])
    assert set(r["resumo_estado"]) == {"acesso", "autenticacao", "vpn", "erros"}
    assert est(r, "acesso") == {"estado": "esperado", "delta_pct": None}
    for cat in ("autenticacao", "vpn", "erros"):
        assert est(r, cat) == {"estado": "normal", "delta_pct": None}


def test_acesso_e_esperado_e_login_de_fora_aceito_e_critico():
    assert est(M([falha("a")]), "acesso")["estado"] == "esperado"
    login = EV("a", "login", "user admin logged in from 203.0.113.9 via ssh",
               campos={"usuario": "admin", "ip": "203.0.113.9", "via": "ssh"})
    assert est(M([login]), "acesso")["estado"] == "critico"


def test_delta_pct_contra_media_diaria_dos_7_dias_anteriores():
    # base: 14 em 7 dias = 2/dia; período: 4 em 1 dia -> +100%
    evs = historia() + [falha("a", atras_h=h) for h in (1, 2, 3, 4)]
    assert est(M(evs), "acesso")["delta_pct"] == 100


@pytest.mark.parametrize("evs,periodo", [
    (historia() + [falha("a", atras_h=1)], "30d"),               # 30 d: não há histórico anterior
    ([falha("a", atras_h=30), falha("a", atras_h=1)], "24h"),    # menos de 1 dia de base
    ([falha("a", atras_h=192), falha("a", atras_h=1)], "24h"),   # histórico existe, base contou zero
])
def test_delta_nulo_sem_base(evs, periodo):
    assert est(M(evs, periodo), "acesso")["delta_pct"] is None


def _auth(i):
    return EV("a", "login_falha", "login failure for user x from 192.168.1.9 via winbox", 1 + i * 0.05, "crit")


def _reboot(i):
    return EV("a", "reboot", "router rebooted", 1 + i * 0.05)


@pytest.mark.parametrize("cat,fab", [("autenticacao", _auth), ("erros", _reboot)])
def test_atencao_quando_acima_do_habitual_e_normal_sem_base(cat, fab):
    periodo = [fab(i) for i in range(25)]
    assert est(M(historia(7) + periodo), cat)["estado"] == "atencao"   # 25/dia > 3 x 1/dia
    assert est(M(periodo), cat)["estado"] == "normal"                  # sem base não alarma
    assert est(M(historia(7) + [fab(0)]), cat)["estado"] == "normal"   # abaixo de HABITUAL_MIN


def test_vpn_atencao_so_com_rajada_de_falhas():
    def f(h):
        return EV("a", "ipsec", "failed to pre-process ph2 packet.", h)
    assert est(M([f(1.0), f(1.2)]), "vpn")["estado"] == "normal"
    assert est(M([f(1.4), f(1.0), f(1.2)]), "vpn")["estado"] == "atencao"  # fora de ordem também conta


# ---- Revisão final: base por MK e rajada de VPN por MK ----
def test_delta_nao_inventa_variacao_com_mk_recente():
    # "a" é antiga (sem eventos na janela); "b" começou há ~1,5 dia e manda 20/dia de forma constante.
    b = [falha("b", atras_h=1 + 1.2 * i) for i in range(50)]
    evs = [falha("a", atras_h=200)] + b
    for mk_id in (None, "b"):
        d = M(evs, mk_id=mk_id)["resumo_estado"]["acesso"]["delta_pct"]
        assert d is not None and abs(d) < 15, (mk_id, d)


def test_vpn_rajada_e_por_mk_nao_somada_entre_mks():
    mks3 = MKS + [{"id": "c", "nome": "Gama"}]

    def f(mk, h):
        return EV(mk, "ipsec", "failed to pre-process ph2 packet.", h)
    espalhadas = [f("a", 1.0), f("b", 1.1), f("c", 1.2)]
    assert montar(espalhadas, mks3, CTX, AGORA, "24h")["resumo_estado"]["vpn"]["estado"] == "normal"
    na_mesma = [f("a", 1.0), f("a", 1.1), f("a", 1.2)]
    assert montar(na_mesma, mks3, CTX, AGORA, "24h")["resumo_estado"]["vpn"]["estado"] == "atencao"
