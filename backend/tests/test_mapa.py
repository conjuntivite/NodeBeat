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
