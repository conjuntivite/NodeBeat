from nodebeat.mapa import norm_mac, fabricante, vigiado, porta_do_aparelho, e_equipamento


def test_norm_mac_formatos():
    assert norm_mac("aa-bb-cc-00-11-22") == "AA:BB:CC:00:11:22"
    assert norm_mac("aabb.cc00.1122") == "AA:BB:CC:00:11:22"
    assert norm_mac("aabbcc001122") == "AA:BB:CC:00:11:22"
    assert norm_mac("zz") is None and norm_mac(None) is None


def test_fabricante():
    assert fabricante("44:19:B6:00:00:01") == "Hikvision"
    assert fabricante("4C:5E:0C:00:00:01") == "MikroTik"
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
