from datetime import datetime, timedelta, timezone

import pytest

from nodebeat.inventario import (
    conferir_faixa, conferir_ip, conferir_porta, desatualizado, ip_em_uso,
    ips_vistos, montar, porta_em, sobreposicoes,
)

AGORA = datetime(2026, 11, 16, 12, 0, tzinfo=timezone.utc)


def raw(**kw):
    base = {k: [] for k in ("address", "dhcp_network", "pool", "ipsec_policy", "nat", "service")}
    base.update(kw)
    return base


def rede(r, tunel=False):
    return {"rede": r, "origem": "address", "interface": None, "tunel": tunel}


def test_montar_normaliza_e_marca_tunel():
    inv = montar(raw(
        address=[{"address": "192.168.10.1/24", "interface": "bridge"}],
        ipsec_policy=[{"src-address": "192.168.10.0/24", "dst-address": "10.1.0.0/16"}],
    ))
    assert inv["redes"] == [{"rede": "192.168.10.0/24", "origem": "address", "interface": "bridge", "tunel": True}]
    assert inv["ipsec"] == [{"src": "192.168.10.0/24", "dst": "10.1.0.0/16"}]


def test_montar_ignora_dinamico_32_e_desativado():
    inv = montar(raw(address=[
        {"address": "192.168.10.1/24", "interface": "a", "dynamic": True},
        {"address": "192.168.11.1/32", "interface": "b"},
        {"address": "192.168.12.1/24", "interface": "c", "disabled": True},
    ]))
    assert inv["redes"] == []


def test_montar_linhas_v6_sem_campos():
    inv = montar(raw(
        address=[{"address": "192.168.10.1/24", "interface": "bridge"}],
        ipsec_policy=[{"src-address": "192.168.10.0/24", "dst-address": "10.1.0.0/16"}],
        nat=[{"action": "dst-nat", "dst-port": "8081", "to-addresses": "192.168.10.20"}],
    ))
    n = inv["nat"][0]
    assert n["aberto"] is True and n["comentario"] == "" and n["to_ports"] is None


def test_ipsec_src_0_0_0_0_ignorado():
    inv = montar(raw(
        address=[{"address": "192.168.10.1/24", "interface": "bridge"}],
        ipsec_policy=[{"src-address": "0.0.0.0/0", "dst-address": "10.1.0.0/16"}],
    ))
    assert inv["redes"][0]["rede"] == "192.168.10.0/24"
    assert inv["redes"][0]["tunel"] is False


def test_nat_aberto_e_restrito():
    inv = montar(raw(nat=[
        {"action": "dst-nat", "dst-port": "80", "src-address-list": "sede"},
        {"action": "masquerade"},
    ]))
    assert len(inv["nat"]) == 1
    assert inv["nat"][0]["aberto"] is False


def test_servico_aberto():
    s = {"name": "winbox", "port": 8291, "address": "", "disabled": False}
    assert montar(raw(service=[s]))["servicos"][0]["aberto"] is True
    assert montar(raw(service=[{**s, "address": "10.1.0.0/16"}]))["servicos"][0]["aberto"] is False


def test_ips_vistos_merge_e_filtra():
    r = ips_vistos(
        [{"address": "192.168.10.20", "mac-address": "AA:BB:CC:00:00:01", "host-name": "dvr", "dynamic": False}],
        [{"address": "192.168.10.20", "mac-address": "AA:BB:CC:00:00:01"},
         {"address": "203.0.113.5", "mac-address": "AA:BB:CC:00:00:02"}],
        ["192.168.10.0/24"],
    )
    assert r == [{"ip": "192.168.10.20", "mac": "AA:BB:CC:00:00:01", "host_name": "dvr", "fixo": True}]


def test_sobreposicao_so_tunel():
    mks = [
        {"nome": "A", "redes": [rede("10.30.0.0/24", True)]},
        {"nome": "B", "redes": [rede("10.30.0.0/24", True)]},
        {"nome": "C", "redes": [rede("192.168.1.0/24")]},
        {"nome": "D", "redes": [rede("192.168.1.0/24")]},
    ]
    assert sobreposicoes(mks, []) == [{"a": "A", "rede_a": "10.30.0.0/24", "b": "B", "rede_b": "10.30.0.0/24"}]
    s = sobreposicoes(mks[:1], ["10.30.0.0/16"])
    assert s == [{"a": "A", "rede_a": "10.30.0.0/24", "b": "Sede", "rede_b": "10.30.0.0/16"}]


def mk(nome, redes, lido=AGORA):
    return {"nome": nome, "redes": redes, "lido_em": lido}


def test_conferir_faixa_livre_em_uso_aviso():
    mks = [mk("Cond Sol", [rede("10.30.0.0/24", True), rede("192.168.1.0/24")])]
    r = conferir_faixa("10.30.0.128/25", mks, ["10.0.0.0/16"], AGORA)
    assert r["resultado"] == "em_uso" and r["colisoes"] == [{"nome": "Cond Sol", "rede": "10.30.0.0/24"}]
    r = conferir_faixa("192.168.1.0/24", mks, ["10.0.0.0/16"], AGORA)
    assert r["resultado"] == "livre" and any("Cond Sol" in a for a in r["avisos"])
    r = conferir_faixa("10.99.0.0/24", mks, ["10.0.0.0/16"], AGORA)
    assert r["resultado"] == "livre" and r["avisos"] == []


def test_conferir_faixa_colide_com_sede():
    r = conferir_faixa("10.0.5.0/24", [], ["10.0.0.0/16"], AGORA)
    assert r["resultado"] == "em_uso" and r["colisoes"] == [{"nome": "Sede", "rede": "10.0.0.0/16"}]


def test_conferir_faixa_normaliza():
    assert conferir_faixa("10.20.5.1/24", [], ["10.0.0.0/16"], AGORA)["faixa"] == "10.20.5.0/24"
    assert conferir_faixa("10.20.5.7", [], ["10.0.0.0/16"], AGORA)["faixa"] == "10.20.5.7/32"
    with pytest.raises(ValueError):
        conferir_faixa("abc", [], [], AGORA)


def test_conferir_faixa_faltam():
    mks = [mk("A", [], None), mk("B", [], AGORA - timedelta(hours=3)), mk("C", [])]
    r = conferir_faixa("10.99.0.0/24", mks, ["10.0.0.0/16"], AGORA)
    assert r["faltam"] == ["A", "B"] and r["resultado"] == "livre"


def test_conferir_faixa_sede_vazia_avisa():
    r = conferir_faixa("10.99.0.0/24", [], [], AGORA)
    assert "Redes da sede não cadastradas" in r["avisos"]


def test_desatualizado():
    assert desatualizado(None, AGORA)
    assert desatualizado(AGORA - timedelta(hours=3), AGORA)
    assert not desatualizado(AGORA - timedelta(hours=1), AGORA)


def test_porta_em():
    assert porta_em("80,443", 443)
    assert porta_em("8000-8010,9000", 8005)
    assert porta_em(None, 1)
    assert not porta_em("8000-8010", 8011)


def test_conferir_porta():
    inv = montar(raw(
        nat=[
            {"action": "dst-nat", "protocol": "tcp", "dst-port": "8081", "to-addresses": "192.168.10.20"},
            {"action": "dst-nat", "protocol": "tcp", "dst-port": "8090", "disabled": True},
            {"action": "dst-nat", "dst-port": "5000"},
        ],
        service=[{"name": "winbox", "port": 8291, "address": ""}],
    ))
    assert conferir_porta(8081, "tcp", inv)["resultado"] == "em_uso"
    r = conferir_porta(8291, "tcp", inv)
    assert r["resultado"] == "em_uso" and any("winbox" in u for u in r["usos"])
    r = conferir_porta(8090, "tcp", inv)
    assert r["resultado"] == "livre" and r["avisos"]
    assert conferir_porta(8081, "udp", inv)["resultado"] == "livre"
    assert conferir_porta(5000, "udp", inv)["resultado"] == "em_uso"
    assert conferir_porta(5000, "tcp", inv)["resultado"] == "em_uso"


def test_ip_em_uso():
    assert ip_em_uso({"fixo": True, "ultimo_visto": AGORA - timedelta(days=99)}, AGORA)
    assert not ip_em_uso({"fixo": False, "ultimo_visto": AGORA - timedelta(days=16)}, AGORA)


def test_conferir_ip():
    inv = {"redes": [rede("192.168.10.0/24")], "pools": [{"nome": "dhcp", "ranges": "192.168.10.100-192.168.10.200"}]}

    def v(ip, dias, fixo=False):
        return [{"ip": ip, "mac": "m", "host_name": None, "fixo": fixo, "ultimo_visto": AGORA - timedelta(days=dias)}]

    assert conferir_ip("10.0.0.1", inv, [], AGORA)["resultado"] == "fora_da_faixa"
    assert conferir_ip("192.168.10.20", inv, v("192.168.10.20", 3), AGORA)["resultado"] == "em_uso"
    r = conferir_ip("192.168.10.20", inv, v("192.168.10.20", 20), AGORA)
    assert r["resultado"] == "livre" and "visto em 27/10" in r["avisos"][0]
    assert conferir_ip("192.168.10.20", inv, v("192.168.10.20", 20, True), AGORA)["resultado"] == "em_uso"
    r = conferir_ip("192.168.10.150", inv, [], AGORA)
    assert r["resultado"] == "livre" and r["avisos"]
    with pytest.raises(ValueError):
        conferir_ip("x", inv, [], AGORA)
