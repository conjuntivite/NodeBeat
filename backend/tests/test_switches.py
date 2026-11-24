import asyncio
import json
from pathlib import Path

from nodebeat import switches
from nodebeat.snmp import SnmpErro

_A = json.loads((Path(__file__).parent / "amostras_snmp.txt").read_text())


def _v(v):
    return bytes.fromhex(v) if isinstance(v, str) else v  # OCTET STRING vem em hex; int fica int


def _walk_amostra(ip, community, oid, **kw):
    async def f():
        return [(o, _v(v)) for n in _A["walk"].values() for o, v in n
                if o.startswith(oid + ".")]
    return f()


def _get_amostra(ip, community, oid, **kw):
    async def f():
        return {"1.3.6.1.2.1.1.1.0": _v(_A["get"]["sysDescr"]),
                "1.3.6.1.2.1.17.1.1.0": _v(_A["get"]["baseBridgeAddress"])}.get(oid)
    return f()


def rodar(c):
    return asyncio.run(c)


def test_parse_fdb_dot1d():
    fdb = [("1.3.6.1.2.1.17.4.3.1.2.68.25.182.0.0.1", 5),
           ("1.3.6.1.2.1.17.4.3.1.2.68.25.182.0.0.2", 0),
           ("1.3.6.1.2.1.17.4.3.1.2.68.25.182.0.0.3", 99)]
    base = [("1.3.6.1.2.1.17.1.4.1.2.5", 10)]
    nomes = [("1.3.6.1.2.1.31.1.1.1.1.10", b"Gi1")]
    assert switches.parse_fdb(fdb, base, nomes) == {"44:19:B6:00:00:01": "Gi1"}


def test_parse_fdb_qbridge_fallback_primeira_vlan_vence():
    q = [("1.3.6.1.2.1.17.7.1.2.2.1.2.1.68.25.182.0.0.1", 5),
         ("1.3.6.1.2.1.17.7.1.2.2.1.2.2.68.25.182.0.0.1", 6)]
    base = [("1.3.6.1.2.1.17.1.4.1.2.5", 10), ("1.3.6.1.2.1.17.1.4.1.2.6", 11)]
    nomes = [("1.3.6.1.2.1.31.1.1.1.1.10", b"Gi1"), ("1.3.6.1.2.1.31.1.1.1.1.11", b"Gi2")]
    assert switches.parse_fdb([], base, nomes, q) == {"44:19:B6:00:00:01": "Gi1"}


def test_candidato():
    assert switches.candidato({"fabricante": "Intelbras"})
    assert switches.candidato({"e_switch": True})
    assert switches.candidato({"e_switch_manual": True, "fabricante": "Outro"})
    assert not switches.candidato({"fabricante": "Outro"})
    assert not switches.candidato({"fabricante": "Intelbras", "e_switch_manual": False})
    assert not switches.candidato({"e_switch": True, "e_switch_manual": False})


def test_descobrir_pula_community_sem_resposta():
    async def get(ip, community, oid, **kw):
        if community == "segredo1":
            raise SnmpErro("sem resposta")
        return b"descr"
    assert rodar(switches.descobrir("10.0.0.1", ["segredo1", "segredo2"], get=get)) == ("segredo2", "descr")


def test_descobrir_nenhuma():
    async def get(ip, community, oid, **kw):
        raise SnmpErro("x")
    assert rodar(switches.descobrir("10.0.0.1", ["a"], get=get)) is None


def test_ler_switch_amostra_real_sanitizada():
    r = rodar(switches.ler_switch("10.0.0.1", "c", walk=_walk_amostra, get=_get_amostra))
    assert r["descr"].startswith("USW-Pro-48")
    assert r["base_mac"] == "D8:B3:70:00:00:01"
    assert len(r["portas"]) == 78 and r["portas"]["0/1"] == {"up": True}
    assert len(r["fdb"]) == 126  # 127 linhas; 1 na porta 65, sem ifIndex (ignorada)
    assert set(r["fdb"].values()) <= set(r["portas"])
    assert r["fdb"]["44:19:B6:00:00:01"]
    assert r["vizinhos"] == {"00:22:44:66:00:01": "AP-TESTE-1", "00:22:44:66:00:02": "AP-TESTE-2"}


def test_ler_switch_lldp_com_erro_nao_derruba():
    def walk(ip, community, oid, **kw):
        if oid.startswith("1.0.8802"):
            raise SnmpErro("x")
        return _walk_amostra(ip, community, oid)
    r = rodar(switches.ler_switch("10.0.0.1", "c", walk=walk, get=_get_amostra))
    assert r["vizinhos"] == {} and r["fdb"]


def test_ler_switch_fdb_vazia_e_primeiro_get_propaga():
    async def vazio(ip, community, oid, **kw):
        return []
    assert rodar(switches.ler_switch("10.0.0.1", "c", walk=vazio, get=_get_amostra))["fdb"] == {}

    async def falha(ip, community, oid, **kw):
        raise SnmpErro("x")
    try:
        rodar(switches.ler_switch("10.0.0.1", "c", walk=vazio, get=falha))
        assert False
    except SnmpErro:
        pass


def test_ler_portas_com_velocidade():
    d = {switches.BASE_IFINDEX: [(switches.BASE_IFINDEX + ".1", 1), (switches.BASE_IFINDEX + ".2", 2)],
         switches.IFNAME: [(switches.IFNAME + ".1", b"0/1"), (switches.IFNAME + ".2", b"0/2"),
                           (switches.IFNAME + ".9", b"CPU")],
         switches.IFOPER: [(switches.IFOPER + ".1", 1), (switches.IFOPER + ".2", 2)],
         switches.IFHIGHSPEED: [(switches.IFHIGHSPEED + ".1", 1000), (switches.IFHIGHSPEED + ".2", 0)]}

    async def walk(ip, community, oid):
        return d[oid]
    assert rodar(switches.ler_portas("10.0.0.1", "c", walk=walk)) == {
        "0/1": {"up": True, "velocidade": 1000}, "0/2": {"up": False, "velocidade": None}}


def test_ler_portas_propaga_snmperro():
    async def walk(ip, community, oid):
        raise SnmpErro("x")
    try:
        rodar(switches.ler_portas("10.0.0.1", "c", walk=walk))
        assert False
    except SnmpErro:
        pass


def test_uplinks_filho_e_switch_burro():
    ips = [{"ip": "10.0.0.20", "switch_ip": "10.0.0.2", "switch_porta": "0/5", "gerenciavel": True},
           *[{"ip": f"10.0.0.{i}", "switch_ip": "10.0.0.2", "switch_porta": "0/12", "fabricante": "Hikvision"} for i in (31, 32, 33)],
           *[{"ip": f"10.0.0.{i}", "switch_ip": "10.0.0.2", "switch_porta": "0/13", "fabricante": "Hikvision"} for i in (41, 42)],
           {"ip": "10.0.0.50", "switch_ip": "10.0.0.9", "switch_porta": "0/1", "fabricante": "Hikvision"}]
    assert switches.uplinks("10.0.0.2", ips) == {"0/5": {"filho": "10.0.0.20", "vigiados": 1},
                                                 "0/12": {"filho": None, "vigiados": 3}}
