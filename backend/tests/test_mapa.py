from nodebeat.mapa import norm_mac, fabricante, vigiado, porta_do_aparelho, e_equipamento


def test_norm_mac_formatos():
    assert norm_mac("aa-bb-cc-00-11-22") == "AA:BB:CC:00:11:22"
    assert norm_mac("aabb.cc00.1122") == "AA:BB:CC:00:11:22"
    assert norm_mac("aabbcc001122") == "AA:BB:CC:00:11:22"
    assert norm_mac("zz") is None and norm_mac(None) is None


def test_fabricante():
    assert fabricante("44:19:B6:00:00:01") == "Hikvision"
    assert fabricante("4C:5E:0C:00:00:01") == "MikroTik"
    assert fabricante("D8:B3:70:00:00:01") == "Ubiquiti"
    assert fabricante("02:00:00:00:00:01") == "MAC privado"
    assert fabricante("00:00:5E:00:00:01") == "Outro"
    assert fabricante(None) == ""


def test_e_equipamento():
    assert e_equipamento("Hikvision") and e_equipamento("Control iD") and e_equipamento("Haiz")
    for f in ("Outro", "MAC privado", "", "MikroTik", "Ubiquiti", "TP-Link"):
        assert not e_equipamento(f)


def test_vigiado():
    assert vigiado({"fabricante": "Hikvision", "fixo": False, "vigiar_manual": None})
    assert vigiado({"fabricante": "Outro", "fixo": True, "vigiar_manual": None})
    assert not vigiado({"fabricante": "MAC privado", "fixo": False, "vigiar_manual": None})
    assert not vigiado({"fabricante": "Hikvision", "fixo": True, "vigiar_manual": False})
    assert vigiado({"fabricante": "Outro", "fixo": False, "vigiar_manual": True})


def test_vigiado_switch_gerenciavel():
    assert vigiado({"fabricante": "Ubiquiti", "fixo": False, "gerenciavel": True})
    assert not vigiado({"fabricante": "Ubiquiti", "fixo": False, "gerenciavel": True, "vigiar_manual": False})
    assert not vigiado({"fabricante": "Ubiquiti", "fixo": False, "gerenciavel": False})


def test_porta_do_aparelho():
    host = {"AA:BB:CC:00:00:01": "ether2"}
    br = {"bridge1"}
    assert porta_do_aparelho("aa:bb:cc:00:00:01", "bridge1", host, br) == ("ether2", "bridge1")
    assert porta_do_aparelho("AA:BB:CC:00:00:02", "ether5", host, br) == ("ether5", None)
    assert porta_do_aparelho("AA:BB:CC:00:00:02", "bridge1", host, br) == (None, "bridge1")
    assert porta_do_aparelho(None, None, host, br) == (None, None)


def _raw(host=None):
    return {
        "arp": [{"address": "10.0.0.5", "mac-address": "44:19:b6:00:00:01", "interface": "bridge1"}],
        "bridge_host": host or [],
        "bridge_port": [{"bridge": "bridge1", "interface": "ether2"}],
        "neighbor": [{"mac-address": "44:19:B6:00:00:01", "identity": "DS-K1T", "platform": "x",
                      "system-caps": "bridge"}],
    }


IPS = [{"ip": "10.0.0.5", "mac": "44:19:B6:00:00:01", "host_name": None, "fixo": False}]


def test_fatos_por_ip():
    from nodebeat.mapa import fatos_por_ip
    host = [{"mac-address": "44:19:B6:00:00:01", "on-interface": "ether2", "bridge": "bridge1", "local": False}]
    assert fatos_por_ip(_raw(host), IPS) == {"10.0.0.5": {
        "porta": "ether2", "bridge": "bridge1", "fabricante": "Hikvision",
        "identidade": "DS-K1T", "plataforma": "x", "e_switch": True}}


def test_fatos_por_ip_sem_host_e_local_ignorado():
    from nodebeat.mapa import fatos_por_ip
    f = fatos_por_ip(_raw(), IPS)["10.0.0.5"]
    assert f["porta"] is None and f["bridge"] == "bridge1"
    local = [{"mac-address": "44:19:B6:00:00:01", "on-interface": "ether9", "bridge": "bridge1", "local": "true"}]
    assert fatos_por_ip(_raw(local), IPS)["10.0.0.5"]["porta"] is None


def test_fatos_por_ip_sem_vizinho():
    from nodebeat.mapa import fatos_por_ip
    raw = _raw()
    raw["neighbor"] = [{"mac-address": "44:19:B6:00:00:01"}]
    f = fatos_por_ip(raw, IPS)["10.0.0.5"]
    assert f["identidade"] is None and f["e_switch"] is False


def test_fatos_por_ip_sem_mac_nao_pega_vizinho_sem_mac():
    from nodebeat.mapa import fatos_por_ip
    raw = _raw()
    raw["neighbor"] = [{"identity": "X", "platform": "p", "system-caps": "bridge"}]
    f = fatos_por_ip(raw, [{"ip": "10.0.0.9", "mac": None}])["10.0.0.9"]
    assert f["identidade"] is None and f["e_switch"] is False


def test_fatos_por_ip_raw_sem_chaves_novas():
    from nodebeat.mapa import fatos_por_ip
    f = fatos_por_ip({"arp": []}, IPS)["10.0.0.5"]
    assert f["porta"] is None and f["identidade"] is None


from datetime import UTC, datetime

from nodebeat.mapa import estado_de, proximo_estado

T0 = datetime(2026, 1, 1, 12, 0, tzinfo=UTC)


def test_proximo_estado_offline_so_apos_duas_falhas():
    e1 = proximo_estado({"online": True, "falhas": 0, "desde": T0.isoformat()}, False, T0)
    assert e1["online"] is True and e1["falhas"] == 1
    e2 = proximo_estado(e1, False, T0)
    assert e2["online"] is False and e2["desde"] == T0.isoformat()
    assert proximo_estado(e2, True, T0)["online"] is True


def test_proximo_estado_primeira_falha_sem_anterior():
    assert proximo_estado(None, False, T0)["online"] is None
    assert proximo_estado(None, True, T0)["online"] is True


def test_estado_de():
    assert estado_de(True, True, False, {"online": False}) == "desconhecido"
    assert estado_de(True, False, True, {"online": False}) == "nao_vigiado"
    assert estado_de(True, True, True, {"online": False}) == "offline"
    assert estado_de(True, True, True, {"online": True}) == "no_ar"
    assert estado_de(True, True, True, {"online": None}) == "desconhecido"
    assert estado_de(True, True, True, None) == "desconhecido"
    assert estado_de(False, True, True, None) == "nao_vigiado"


# ---- montar_arvore ----
from datetime import datetime, timedelta
from nodebeat.mapa import montar_arvore

HIK = "44:19:B6:00:00:0"


def _ap(ip, porta="ether2", mac_fim="1", **kw):
    return {"ip": ip, "mac": HIK + mac_fim, "fabricante": "Hikvision", "porta": porta, **kw}


def _on(ok=True, falhas=0):
    return {"online": ok, "falhas": falhas, "desde": "2026-11-23T10:00:00"}


def _arv(aps, estados=None, **kw):
    kw.setdefault("link", {})
    kw.setdefault("rotulos", {})
    kw.setdefault("mk_no_ar", True)
    kw.setdefault("redes_tunel", ["10.0.0.0/24"])
    return montar_arvore(aps, estados=estados or {}, **kw)


def _porta(arv, nome):
    return next(p for p in arv if p["nome"] == nome)


def test_arvore_um_offline_com_dois_no_ar():
    aps = [_ap("10.0.0.1"), _ap("10.0.0.2"), _ap("10.0.0.3")]
    est = {"10.0.0.1": _on(), "10.0.0.2": _on(), "10.0.0.3": _on(False, 2)}
    p = _porta(_arv(aps, est), "ether2")
    assert p["problema"] is True and p["causa"] is None
    assert p["no_ar"] == 2 and p["vigiados"] == 3
    assert p["link"] == "desconhecido"


def test_arvore_todos_sem_resposta_precisa_de_dois():
    aps = [_ap("10.0.0.1"), _ap("10.0.0.2")]
    off = _on(False, 2)
    p = _porta(_arv(aps, {"10.0.0.1": off, "10.0.0.2": off}), "ether2")
    assert p["causa"] == "todos sem resposta"
    p = _porta(_arv(aps[:1], {"10.0.0.1": off}), "ether2")
    assert p["causa"] is None and p["problema"] is True


def test_arvore_link_caido():
    aps = [_ap("10.0.0.1", "ether3")]
    p = _porta(_arv(aps, {"10.0.0.1": _on()}, link={"ether3": False}), "ether3")
    assert p["causa"] == "link caído" and p["problema"] is True and p["link"] == "down"
    assert _porta(_arv(aps, link={"ether3": True}), "ether3")["link"] == "up"


def test_arvore_mk_fora_do_ar_sem_problema():
    aps = [_ap("10.0.0.1", "ether3")]
    arv = _arv(aps, {"10.0.0.1": _on(False, 2)}, mk_no_ar=False, link={"ether3": False})
    assert arv[0]["aparelhos"][0]["estado"] == "desconhecido"
    assert arv[0]["problema"] is False and arv[0]["causa"] is None


def test_arvore_fora_da_rede_de_tunel():
    arv = _arv([_ap("192.168.9.9")], {"192.168.9.9": _on()})
    assert arv[0]["aparelhos"][0]["estado"] == "nao_vigiado"


def test_arvore_sem_porta_usa_bridge():
    arv = _arv([_ap("10.0.0.1", None, bridge="bridge1"), _ap("10.0.0.2", None)])
    nomes = {p["nome"] for p in arv}
    assert nomes == {"bridge1 (porta desconhecida)", "Sem porta"}
    g = _porta(arv, "bridge1 (porta desconhecida)")
    assert g["rotulo"] == "" and g["aparelhos"][0]["porta_desconhecida"] is True


def test_arvore_busca():
    aps = [_ap("10.0.0.45", "ether2", "1"),
           {"ip": "10.0.0.46", "mac": "00:00:5E:00:00:02", "fabricante": "Outro", "porta": "ether5",
            "identidade": "Roteador"}]
    assert [p["nome"] for p in _arv(aps, busca="HIKvision")] == ["ether2"]
    assert [p["nome"] for p in _arv(aps, busca="10.0.0.45")] == ["ether2"]
    assert [p["nome"] for p in _arv(aps, busca="roteador")] == ["ether5"]


def test_arvore_so_problema():
    aps = [_ap("10.0.0.1"), _ap("10.0.0.2"),            # ether2: 1 offline de 2
           _ap("10.0.0.3", "ether3"), _ap("10.0.0.4", "ether3"),  # ether3: todos offline (causa)
           _ap("10.0.0.5", "ether4")]                  # ether4: ok
    off = _on(False, 2)
    est = {"10.0.0.1": _on(), "10.0.0.2": off, "10.0.0.3": off, "10.0.0.4": off, "10.0.0.5": _on()}
    arv = _arv(aps, est, so_problema=True)
    assert [p["nome"] for p in arv] == ["ether2", "ether3"]
    assert [a["ip"] for a in arv[0]["aparelhos"]] == ["10.0.0.2"]
    assert len(arv[1]["aparelhos"]) == 2


def test_arvore_offline_continua_na_ultima_porta_e_ordem():
    aps = [_ap("10.0.0.10"), _ap("10.0.0.9", e_switch=True), _ap("10.0.0.2")]
    arv = _arv(aps, {"10.0.0.2": _on(False, 2)})
    assert arv[0]["aparelhos"][0]["estado"] == "desconhecido"
    assert [a["ip"] for a in arv[0]["aparelhos"]] == ["10.0.0.9", "10.0.0.2", "10.0.0.10"]
    assert arv[0]["aparelhos"][1]["estado"] == "offline"


def test_arvore_ordem_portas_e_campos():
    aps = [_ap("10.0.0.1", "ether9"), _ap("10.0.0.2", "Ether1"), _ap("10.0.0.3", "ether5", apelido="Cam",
           identidade="id", e_switch_manual=True)]
    est = {"10.0.0.1": _on(False, 2)}
    arv = _arv(aps, est, rotulos={"Ether1": "Portaria"})
    assert [p["nome"] for p in arv] == ["ether9", "Ether1", "ether5"]
    a = _porta(arv, "ether5")["aparelhos"][0]
    assert a["nome"] == "Cam" and a["e_switch"] is True and a["desde"] is None
    assert _porta(arv, "Ether1")["rotulo"] == "Portaria"


def test_arvore_ultimo_visto_antigo_nao_vigiado():
    agora = datetime(2026, 11, 23)
    aps = [_ap("10.0.0.1", ultimo_visto=agora - timedelta(days=16)),
           _ap("10.0.0.2", ultimo_visto=agora - timedelta(days=1))]
    est = {"10.0.0.1": _on(), "10.0.0.2": _on()}
    a = {x["ip"]: x["estado"] for x in _arv(aps, est, agora=agora)[0]["aparelhos"]}
    assert a == {"10.0.0.1": "nao_vigiado", "10.0.0.2": "no_ar"}


# --- ligações aparelho -> (switch, porta) ---

import copy

from nodebeat.mapa import ligacoes


def _sw(ip, fdb, mac=None, base_mac=None, gerenciavel=True):
    return {"ip": ip, "mac": mac, "base_mac": base_mac, "gerenciavel": gerenciavel, "fdb": fdb, "portas": {}}


def _mac(n):
    return f"AA:BB:CC:00:00:{n:02X}"


def test_ligacoes_aparelho_na_porta_do_switch():
    s1 = _sw("10.0.0.2", {_mac(1): "0/3", _mac(9): "0/1"})
    aps = [{"ip": "10.0.0.5", "mac": _mac(1)}, {"ip": "10.0.0.2", "mac": _mac(2)}]
    assert ligacoes([s1], aps) == {"10.0.0.5": {"switch_ip": "10.0.0.2", "porta": "0/3"}}


def test_ligacoes_cascata_vai_para_a_folha():
    cam = _mac(1)
    s1 = _sw("10.0.0.2", {cam: "0/48", **{_mac(i): "0/48" for i in range(10, 15)}, _mac(20): "0/48"},
             mac=_mac(30))
    s2 = _sw("10.0.0.3", {cam: "0/5"}, mac=_mac(21), base_mac=_mac(20))
    aps = [{"ip": "10.0.0.5", "mac": cam}, {"ip": "10.0.0.2", "mac": _mac(30)},
           {"ip": "10.0.0.3", "mac": _mac(21)}]
    assert ligacoes([s1, s2], aps) == {
        "10.0.0.5": {"switch_ip": "10.0.0.3", "porta": "0/5"},
        "10.0.0.3": {"switch_ip": "10.0.0.2", "porta": "0/48"}}  # pelo base_mac


def test_ligacoes_mac_em_duas_portas_do_mesmo_switch():
    s1 = _sw("10.0.0.2", {"aa:bb:cc:00:00:01": "0/1", _mac(2): "0/1", "AA-BB-CC-00-00-01": "0/7"})
    assert ligacoes([s1], [{"ip": "10.0.0.5", "mac": _mac(1)}])["10.0.0.5"]["porta"] == "0/7"
    # empate: menor (switch_ip, porta)
    s1 = _sw("10.0.0.2", {"aa:bb:cc:00:00:01": "0/9", "AA-BB-CC-00-00-01": "0/3"})
    s0 = _sw("10.0.0.10", {_mac(1): "0/1"})
    assert ligacoes([s0, s1], [{"ip": "10.0.0.5", "mac": _mac(1)}]) == {
        "10.0.0.5": {"switch_ip": "10.0.0.10", "porta": "0/1"}}  # "10.0.0.10" < "10.0.0.2"


def test_ligacoes_ciclo_corta_o_maior_ip():
    s1 = _sw("10.0.0.2", {_mac(3): "0/1"}, mac=_mac(2))
    s2 = _sw("10.0.0.3", {_mac(2): "0/1"}, mac=_mac(3))
    aps = [{"ip": "10.0.0.2", "mac": _mac(2)}, {"ip": "10.0.0.3", "mac": _mac(3)}]
    assert ligacoes([s1, s2], aps) == {"10.0.0.2": {"switch_ip": "10.0.0.3", "porta": "0/1"}}
    # ciclo de 3: corta só o maior IP
    s3 = _sw("10.0.0.4", {_mac(2): "0/1"}, mac=_mac(4))
    s1 = _sw("10.0.0.2", {_mac(3): "0/1"}, mac=_mac(2))
    s2 = _sw("10.0.0.3", {_mac(4): "0/1"}, mac=_mac(3))
    aps.append({"ip": "10.0.0.4", "mac": _mac(4)})
    assert set(ligacoes([s1, s2, s3], aps)) == {"10.0.0.2", "10.0.0.3"}


def test_ligacoes_sem_mac_ou_desconhecido_fica_de_fora():
    s1 = _sw("10.0.0.2", {_mac(1): "0/1"})
    aps = [{"ip": "10.0.0.5", "mac": None}, {"ip": "10.0.0.6", "mac": "zz"}, {"ip": "10.0.0.7"},
           {"ip": "10.0.0.8", "mac": _mac(8)}]
    assert ligacoes([s1], aps) == {}


def test_ligacoes_mac_em_qualquer_formato():
    s1 = _sw("10.0.0.2", {"aa-bb-cc-00-00-01": "0/1", "AABB.CC00.0002": "0/2"})
    aps = [{"ip": "10.0.0.5", "mac": "AA:BB:CC:00:00:01"}, {"ip": "10.0.0.6", "mac": "aa:bb:cc:00:00:02"}]
    assert set(ligacoes([s1], aps)) == {"10.0.0.5", "10.0.0.6"}


def test_ligacoes_switch_nunca_no_proprio():
    s1 = _sw("10.0.0.2", {_mac(2): "CPU", _mac(9): "0/1"}, mac=_mac(2), base_mac=_mac(9))
    assert ligacoes([s1], [{"ip": "10.0.0.2", "mac": _mac(2)}]) == {}


def test_ligacoes_sem_switch_gerenciavel_e_nao_muta():
    aps = [{"ip": "10.0.0.5", "mac": _mac(1)}]
    assert ligacoes([], aps) == {}
    assert ligacoes([_sw("10.0.0.2", {_mac(1): "0/1"}, gerenciavel=False), _sw("10.0.0.3", {})], aps) == {}
    sws = [_sw("10.0.0.2", {"aa-bb-cc-00-00-01": "0/1"})]
    antes = copy.deepcopy((sws, aps))
    ligacoes(sws, aps)
    assert (sws, aps) == antes


# --- árvore com switches gerenciáveis aninhados ---

DICA = "gerenciável detectado: ative o SNMP nele"


def _swdoc(ip, portas=(), erro=None, lido_em="2026-11-23T10:00:00", gerenciavel=True, up=True):
    return {"ip": ip, "gerenciavel": gerenciavel, "portas": {n: {"up": up} for n in portas},
            "fdb": {}, "erro": erro, "lido_em": lido_em}


def _liga(ap, sw, porta):
    return {**ap, "switch_ip": sw, "switch_porta": porta}


S1, S2 = "10.0.0.2", "10.0.0.3"


def _cenario():
    """MK ether2 -> S1 -> 0/3 (facial), 0/7 (camera)."""
    aps = [_ap(S1, "ether2", "2"), _liga(_ap("10.0.0.10", "ether2", "3"), S1, "0/3"),
           _liga(_ap("10.0.0.11", "ether2", "4"), S1, "0/7")]
    return aps, [_swdoc(S1, ["0/3", "0/7"])]


def _aparelho(portas, ip):
    for p in portas:
        for a in p["aparelhos"]:
            if a["ip"] == ip:
                return a
            if (r := _aparelho(a.get("portas", []), ip)) is not None:
                return r
    return None


def test_arvore_switch_aninha_aparelhos_nas_portas():
    aps, sws = _cenario()
    arv = _arv(aps, switches=sws)
    assert [p["nome"] for p in arv] == ["ether2"]
    s1 = arv[0]["aparelhos"]
    assert [a["ip"] for a in s1] == [S1]
    s1 = s1[0]
    assert s1["gerenciavel"] is True and s1["snmp_erro"] is False and s1["switch_lido_em"] == "2026-11-23T10:00:00"
    assert "dica" not in s1
    assert [(p["nome"], [a["ip"] for a in p["aparelhos"]]) for p in s1["portas"]] == [
        ("0/3", ["10.0.0.10"]), ("0/7", ["10.0.0.11"])]
    p = s1["portas"][0]
    assert set(p) == {"nome", "rotulo", "link", "vigiados", "no_ar", "problema", "causa", "aparelhos"}
    assert p["rotulo"] == "" and p["link"] == "up"


def test_arvore_switch_em_cascata():
    aps = [_ap(S1, "ether2", "2"), _liga(_ap(S2, "ether2", "3"), S1, "0/48"),
           _liga(_ap("10.0.0.20", "ether2", "4"), S2, "0/5")]
    arv = _arv(aps, switches=[_swdoc(S1, ["0/48"]), _swdoc(S2, ["0/5"])])
    s1 = arv[0]["aparelhos"][0]
    s2 = s1["portas"][0]["aparelhos"][0]
    assert s1["ip"] == S1 and s2["ip"] == S2 and s2["gerenciavel"] is True
    assert s2["portas"][0]["nome"] == "0/5" and s2["portas"][0]["aparelhos"][0]["ip"] == "10.0.0.20"


def test_arvore_ligacao_invalida_fica_na_porta_da_mk():
    aps = [_ap(S1, "ether2", "2"), _ap(S2, "ether2", "3"),
           _liga(_ap("10.0.0.10", "ether4", "4"), S1, "0/3"),            # S1 não gerenciável
           _liga(_ap("10.0.0.11", "ether4", "5"), S2, "0/3"),            # S2 sem doc
           _liga(_ap("10.0.0.12", "ether4", "6"), "10.0.0.99", "0/3"),   # switch fora da lista
           _liga(_ap("10.0.0.13", "ether4", "7"), S1, None)]             # sem porta
    sws = [_swdoc(S1, ["0/3"], gerenciavel=False), _swdoc("10.0.0.99", ["0/3"])]
    arv = _arv(aps, switches=sws)
    assert sorted(a["ip"] for a in _porta(arv, "ether4")["aparelhos"]) == [
        "10.0.0.10", "10.0.0.11", "10.0.0.12", "10.0.0.13"]
    assert all("portas" not in a for a in _porta(arv, "ether2")["aparelhos"])


def test_arvore_ciclo_corta_o_maior_ip():
    aps = [_liga(_ap(S1, "ether2", "2"), S2, "0/1"), _liga(_ap(S2, "ether3", "3"), S1, "0/2")]
    arv = _arv(aps, switches=[_swdoc(S1, ["0/2"]), _swdoc(S2, ["0/1"])])
    # S2 (maior IP) perde a ligação: fica em ether3 e S1 vai para baixo dele
    assert [p["nome"] for p in arv] == ["ether3"]
    s2 = arv[0]["aparelhos"][0]
    assert s2["ip"] == S2 and s2["portas"][0]["nome"] == "0/1" and s2["portas"][0]["aparelhos"][0]["ip"] == S1
    # ligação a si mesmo
    arv = _arv([_liga(_ap(S1, "ether2", "2"), S1, "0/1")], switches=[_swdoc(S1, ["0/1"])])
    assert arv[0]["nome"] == "ether2" and arv[0]["aparelhos"][0]["portas"] == []


def test_arvore_switch_offline_filhos_desconhecidos_sem_causa():
    aps = [_ap(S1, "ether2", "2"), _liga(_ap(S2, "ether2", "3"), S1, "0/1"),
           _liga(_ap("10.0.0.20", "ether2", "4"), S2, "0/5"),
           _liga(_ap("10.0.0.21", "ether2", "5"), S2, "0/5"),
           _liga({"ip": "10.0.0.22", "mac": "00:00:5E:00:00:09", "fabricante": "Outro", "porta": "ether2"},
                 S1, "0/2")]
    off = _on(False, 2)
    est = {S1: off, S2: _on(), "10.0.0.20": off, "10.0.0.21": off}
    sws = [_swdoc(S1, ["0/1", "0/2"], up=False), _swdoc(S2, ["0/5"], up=False)]
    arv = _arv(aps, est, switches=sws)
    p = arv[0]
    assert p["problema"] is True and p["causa"] is None
    assert p["vigiados"] == 1 and p["no_ar"] == 0
    s1 = p["aparelhos"][0]
    assert s1["estado"] == "offline"
    for ip in (S2, "10.0.0.20", "10.0.0.21"):
        assert _aparelho(arv, ip)["estado"] == "desconhecido"
    assert _aparelho(arv, "10.0.0.22")["estado"] == "nao_vigiado"
    s2 = _aparelho(arv, S2)
    for q in s1["portas"] + s2["portas"]:
        assert q["causa"] is None and q["problema"] is False


def test_arvore_porta_do_switch_caida():
    aps, sws = _cenario()
    sws[0]["portas"]["0/7"]["up"] = False
    arv = _arv(aps, {"10.0.0.11": _on()}, switches=sws)
    q = _porta(arv[0]["aparelhos"][0]["portas"], "0/7")
    assert q["causa"] == "link caído" and q["link"] == "down" and q["problema"] is True
    assert arv[0]["problema"] is True and arv[0]["causa"] is None
    # porta com problema vem primeiro
    assert [x["nome"] for x in arv[0]["aparelhos"][0]["portas"]] == ["0/7", "0/3"]
    # porta desconhecida pelo switch
    sws[0]["portas"] = {}
    q = _porta(_arv(aps, switches=sws)[0]["aparelhos"][0]["portas"], "0/7")
    assert q["link"] == "desconhecido" and q["causa"] is None


def test_arvore_sem_switches_igual_ao_anterior():
    aps = [_ap("10.0.0.1"), _ap("10.0.0.2"), _ap("10.0.0.3", "ether3"), _ap("10.0.0.4", "ether3"),
           _ap("10.0.0.9", e_switch=True), _liga(_ap("10.0.0.5", "ether4"), "10.0.0.9", "0/1")]
    off = _on(False, 2)
    est = {"10.0.0.1": _on(), "10.0.0.2": off, "10.0.0.3": off, "10.0.0.4": off}
    for kw in ({}, {"so_problema": True}, {"busca": "10.0.0.4"}):
        base = _arv(aps, est, **kw)
        assert _arv(aps, est, switches=None, **kw) == base
        assert _arv(aps, est, switches=[], **kw) == base
    assert "dica" not in _aparelho(_arv(aps, est), "10.0.0.9")


def test_arvore_switch_candidato_sem_snmp_tem_dica():
    aps, sws = _cenario()
    aps += [_ap("10.0.0.30", "ether5", "8", e_switch=True), _ap("10.0.0.31", "ether5", "9", e_switch_manual=True)]
    arv = _arv(aps, switches=sws)
    for ip in ("10.0.0.30", "10.0.0.31"):
        a = _aparelho(arv, ip)
        assert a["gerenciavel"] is False and a["dica"] == DICA and "portas" not in a
    a = _aparelho(arv, "10.0.0.10")
    assert "dica" not in a and "gerenciavel" not in a


def test_arvore_busca_e_so_problema_no_aninhado():
    aps, sws = _cenario()
    aps.append(_ap("10.0.0.40", "ether5", "8"))
    arv = _arv(aps, switches=sws, busca="10.0.0.11")
    assert [p["nome"] for p in arv] == ["ether2"]
    s1 = arv[0]["aparelhos"]
    assert [a["ip"] for a in s1] == [S1]
    assert [(p["nome"], [a["ip"] for a in p["aparelhos"]]) for p in s1[0]["portas"]] == [("0/7", ["10.0.0.11"])]
    est = {S1: _on(), "10.0.0.10": _on(), "10.0.0.11": _on(False, 2), "10.0.0.40": _on()}
    arv = _arv(aps, est, switches=sws, so_problema=True)
    assert [p["nome"] for p in arv] == ["ether2"]
    s1 = arv[0]["aparelhos"]
    assert [a["ip"] for a in s1] == [S1]
    assert [(p["nome"], [a["ip"] for a in p["aparelhos"]]) for p in s1[0]["portas"]] == [("0/7", ["10.0.0.11"])]


def test_arvore_switch_lista_so_portas_com_aparelhos():
    aps, _ = _cenario()
    arv = _arv(aps, switches=[_swdoc(S1, [f"0/{i}" for i in range(1, 49)], erro="timeout", lido_em=None)])
    s1 = arv[0]["aparelhos"][0]
    assert [p["nome"] for p in s1["portas"]] == ["0/3", "0/7"]
    assert s1["snmp_erro"] is True and s1["switch_lido_em"] is None


def test_arvore_aparelho_offline_fica_na_ligacao_gravada():
    aps, sws = _cenario()
    sws[0]["fdb"] = {}  # nenhum MAC aprendido agora: vale a ligação gravada
    est = {S1: _on(), "10.0.0.10": _on(False, 2)}
    arv = _arv(aps, est, switches=sws)
    portas_s1 = arv[0]["aparelhos"][0]["portas"]
    assert _aparelho(portas_s1, "10.0.0.10")["estado"] == "offline"
    assert _porta(portas_s1, "0/3")["problema"] is True


def test_arvore_contadores_da_subarvore_e_todos_sem_resposta():
    aps, sws = _cenario()
    off = _on(False, 2)
    est = {S1: _on(), "10.0.0.10": off, "10.0.0.11": _on()}
    p = _arv(aps, est, switches=sws)[0]
    assert p["vigiados"] == 3 and p["no_ar"] == 2 and p["problema"] is True and p["causa"] is None
    q = _porta(p["aparelhos"][0]["portas"], "0/3")
    assert q["vigiados"] == 1 and q["no_ar"] == 0 and q["causa"] is None
    # S1 no ar e um offline dentro dele: não são "todos" -> sem causa
    aps2 = [aps[0], aps[1]]
    p = _arv(aps2, {S1: _on(), "10.0.0.10": off}, switches=sws)[0]
    assert p["causa"] is None
    # S1 offline deixa os filhos desconhecidos; com outro offline direto na porta -> 2 vigiados offline
    p = _arv([aps[0], _ap("10.0.0.50", "ether2", "9")], {S1: off, "10.0.0.50": off}, switches=sws)[0]
    assert p["causa"] == "todos sem resposta"


def test_arvore_switches_nao_muta_entradas():
    aps, sws = _cenario()
    est = {S1: _on(False, 2), "10.0.0.10": _on()}
    antes = copy.deepcopy((aps, sws, est))
    _arv(aps, est, switches=sws, so_problema=True, busca="10")
    assert (aps, sws, est) == antes
