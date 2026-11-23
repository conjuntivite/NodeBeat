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
