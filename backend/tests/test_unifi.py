import httpx
import pytest

from nodebeat.unifi import UnifiErro, clientes_com_fio, ler, parse_switch

CHAVE = "chave-secreta-fake"
URL = "https://192.0.2.10"


def _dev():
    return {"ip": "192.0.2.20", "mac": "02:00:00:aa:bb:01", "name": "sw-teste", "model": "USW-FAKE",
            "version": "7.0.1", "upgradable": True, "uptime": 1234, "system-stats": {"cpu": "16.0", "mem": "40.5"},
            "general_temperature": 51, "total_max_power": 95, "num_sta": 7,
            "uplink": {"port_idx": 2, "uplink_mac": "02:00:00:aa:bb:02", "uplink_remote_port": 5},
            "port_table": [
                {"port_idx": 1, "poe_power": "2.50", "poe_class": "Class 3", "rx_bytes-r": 1250000.0,
                 "tx_bytes-r": 125000, "rx_errors": 2, "tx_errors": 1, "rx_dropped": 4, "tx_dropped": 3,
                 "stp_state": "forwarding", "link_down_count": 3, "mac_table": [{}, {}]},
                {"port_idx": 2, "is_uplink": True}]}


def test_parse_switch_poe():
    s = parse_switch(_dev())
    p = s["portas"]["1"]
    assert p["poe_w"] == 2.5 and p["poe_classe"] == "Class 3"
    assert p["rx_mbps"] == 10.0 and p["tx_mbps"] == 1.0
    assert p["erros"] == 3 and p["descartes"] == 7
    assert p["stp"] == "forwarding" and p["quedas_link"] == 3 and p["aparelhos"] == 2
    assert s["portas"]["2"]["uplink"] is True and p["uplink"] is False
    assert (s["ip"], s["mac"], s["nome"], s["modelo"]) == ("192.0.2.20", "02:00:00:aa:bb:01", "sw-teste", "USW-FAKE")
    sis = s["sistema"]
    assert sis["cpu"] == 16.0 and sis["mem"] == 40.5 and sis["temperatura"] == 51.0
    assert sis["firmware"] == "7.0.1" and sis["atualizacao"] is True and sis["uptime_s"] == 1234
    assert sis["poe_usado_w"] == 2.5 and sis["poe_max_w"] == 95.0 and sis["clientes"] == 7
    assert sis["uplink"] == {"porta": 2, "remoto": "02:00:00:aa:bb:02", "remoto_porta": 5}


def test_parse_switch_campos_ausentes():
    s = parse_switch({"ip": "192.0.2.20", "mac": "02:00:00:aa:bb:01", "name": "x", "port_table": [{"port_idx": 1}]})
    assert s["portas"]["1"]["poe_w"] is None and s["portas"]["1"]["erros"] == 0
    assert s["sistema"]["temperatura"] is None and s["sistema"]["uplink"] is None


def test_clientes_com_fio():
    sta = [
        {"is_wired": True, "sw_mac": "02:00:00:AA:BB:01", "sw_port": 1, "hostname": "zeta", "last_ip": "192.0.2.31",
         "mac": "02:00:00:00:00:01", "oui": "Fab", "wired-rate_mbps": 1000},
        {"is_wired": True, "sw_mac": "02:00:00:aa:bb:01", "sw_port": 1, "name": "alfa", "ip": "192.0.2.30",
         "mac": "02:00:00:00:00:02"},
        {"is_wired": True, "sw_mac": "02:00:00:aa:bb:01", "sw_port": 2, "hostname": "02:00:00:00:00:03",
         "mac": "02:00:00:00:00:03"},
        {"is_wired": True, "sw_mac": "02:00:00:aa:bb:01", "mac": "02:00:00:00:00:04"},
        {"is_wired": False, "sw_mac": "02:00:00:aa:bb:01", "sw_port": 3, "mac": "02:00:00:00:00:05"}]
    r = clientes_com_fio(sta)
    assert list(r) == ["02:00:00:aa:bb:01"] and sorted(r["02:00:00:aa:bb:01"]) == [1, 2]
    p1 = r["02:00:00:aa:bb:01"][1]
    assert [c["nome"] for c in p1] == ["alfa", "zeta"]
    assert p1[1] == {"nome": "zeta", "ip": "192.0.2.31", "mac": "02:00:00:00:00:01", "fabricante": "Fab", "mbps": 1000}
    assert r["02:00:00:aa:bb:01"][2][0]["nome"] is None


async def test_ler_envia_chave_e_nao_vaza():
    vistos = []

    def h(req: httpx.Request):
        vistos.append((req.method, req.headers.get("X-API-Key"), req.content))
        if req.url.path.endswith("/ruim"):
            return httpx.Response(401)
        return httpx.Response(200, json={"data": [1, 2]} if req.method == "GET" else {"x": 1})

    async with httpx.AsyncClient(transport=httpx.MockTransport(h)) as c:
        assert await ler(c, URL, CHAVE, "/ok") == [1, 2]
        assert await ler(c, URL, CHAVE, "/ok", {"a": 1}) == {"x": 1}
        with pytest.raises(UnifiErro) as e:
            await ler(c, URL, CHAVE, "/ruim")
    assert [v[:2] for v in vistos[:2]] == [("GET", CHAVE), ("POST", CHAVE)] and vistos[1][2]
    assert CHAVE not in str(e.value) and "192.0.2.10" not in str(e.value) and CHAVE not in repr(e.value)


def test_settings_unifi_opcional(monkeypatch):
    from nodebeat.config import load_settings
    for k, v in {"NODEBEAT_MONGO_URL": "m", "NODEBEAT_REDIS_URL": "r", "NODEBEAT_SECRET_KEY": "k",
                 "NODEBEAT_WEBHOOK_URL": "https://hook.example", "NODEBEAT_REFERENCE_HOST": "ref.example"}.items():
        monkeypatch.setenv(k, v)
    monkeypatch.delenv("NODEBEAT_UNIFI_URL", raising=False)
    monkeypatch.setenv("NODEBEAT_UNIFI_API_KEY", "")
    s = load_settings()
    assert s.unifi_url is None and s.unifi_api_key is None
    monkeypatch.setenv("NODEBEAT_UNIFI_URL", URL)
    assert load_settings().unifi_url == URL
