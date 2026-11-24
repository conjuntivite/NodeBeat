"""Descoberta e leitura SNMP de switches gerenciáveis (BRIDGE-MIB, Q-BRIDGE-MIB, IF-MIB, LLDP).

A community é segredo: nunca vai para log nem para mensagem de erro.
"""
from __future__ import annotations

from . import mapa, snmp

SYS_DESCR = "1.3.6.1.2.1.1.1.0"
BASE_MAC = "1.3.6.1.2.1.17.1.1.0"
FDB = "1.3.6.1.2.1.17.4.3.1.2"
QFDB = "1.3.6.1.2.1.17.7.1.2.2.1.2"
BASE_IFINDEX = "1.3.6.1.2.1.17.1.4.1.2"
IFNAME = "1.3.6.1.2.1.31.1.1.1.1"
IFOPER = "1.3.6.1.2.1.2.2.1.8"
IFHIGHSPEED = "1.3.6.1.2.1.31.1.1.1.15"
IFTYPE = "1.3.6.1.2.1.2.2.1.3"
# ethernetCsmacd, fastEther, fastEtherFX, gigabitEthernet; fora: LAG (161), CPU/other (1), lo, vlan…
IFTYPES_FISICOS = {6, 62, 69, 117}
LLDP_NOME = "1.0.8802.1.1.2.1.4.1.1.9"
LLDP_CHASSIS = "1.0.8802.1.1.2.1.4.1.1.5"

UPLINK_MIN_VIGIADOS = 3
FABRICANTES_SWITCH = {"Intelbras", "Haiz", "Hikvision", "TP-Link", "MikroTik", "Ubiquiti", "Dahua"}


def candidato(ap: dict) -> bool:
    manual = ap.get("e_switch_manual")
    if manual is not None:
        return bool(manual)
    return bool(ap.get("e_switch")) or ap.get("fabricante") in FABRICANTES_SWITCH


def _sufixo(oid: str, prefixo: str) -> list[int]:
    return [int(x) for x in oid[len(prefixo) + 1:].split(".")]


def _texto(v) -> str:
    return v.decode(errors="replace") if isinstance(v, bytes) else str(v or "")


def _mac_oct(octetos: list[int]) -> str | None:
    if len(octetos) != 6 or any(not 0 <= o <= 255 for o in octetos):
        return None
    return bytes(octetos).hex(":").upper()


def parse_fdb(fdb: list, base_ifindex: list, ifnames: list, qbridge: list = []) -> dict[str, str]:
    """MAC -> nome da porta. Usa a tabela dot1q se a dot1d vier vazia."""
    porta_if = {_sufixo(o, BASE_IFINDEX)[0]: v for o, v in base_ifindex}
    nome = {_sufixo(o, IFNAME)[0]: _texto(v) for o, v in ifnames}
    out: dict[str, str] = {}
    linhas = [(_sufixo(o, FDB)[-6:], v) for o, v in fdb] if fdb else \
             [(_sufixo(o, QFDB)[-6:], v) for o, v in qbridge]  # ...<vlan>.<6 octetos>
    for octetos, porta in linhas:
        # sem a tabela da bridge (alguns UniFi): a porta da bridge é o próprio ifIndex
        mac, nm = _mac_oct(octetos), nome.get(porta_if.get(porta) if porta_if else porta)
        if mac and nm:  # porta 0 ou fora da tabela: ignora
            out.setdefault(mac, nm)  # mesmo MAC em várias VLANs: a primeira vence
    return out


def _vizinhos(nomes: list, chassis: list) -> dict[str, str]:
    mac_de = {tuple(_sufixo(o, LLDP_CHASSIS)): v.hex(":").upper()
              for o, v in chassis if isinstance(v, bytes) and len(v) == 6}
    out = {}
    for o, v in nomes:
        nm, mac = _texto(v).strip(), mac_de.get(tuple(_sufixo(o, LLDP_NOME)))
        if nm and mac:
            out[mac] = nm
    return out


async def descobrir(ip: str, communities: list[str], *, get=snmp.get) -> tuple[str, str] | None:
    """(community, sysDescr) da primeira que responde; None se nenhuma."""
    for c in communities:
        try:
            v = await get(ip, c, SYS_DESCR)
        except snmp.SnmpErro:
            continue
        if v is not None:
            return c, _texto(v)
    return None


def _portas(base_ifindex: list, ifnames: list, oper: list, vel: list | None = None,
            tipos: list | None = None) -> dict[str, dict]:
    """Portas físicas: nome -> {"up"} (e "velocidade" em Mbps se vel vier).

    Com ifType, vale ele (a bridge lista LAG e alguns UniFi nem publicam a bridge); sem, a bridge."""
    nome = {_sufixo(o, IFNAME)[0]: _texto(v) for o, v in ifnames}
    up = {_sufixo(o, IFOPER)[0]: v == 1 for o, v in oper}
    mbps = {_sufixo(o, IFHIGHSPEED)[0]: v for o, v in vel or []}
    tipo = {_sufixo(o, IFTYPE)[0]: v for o, v in tipos or []}
    indices = sorted(i for i, t in tipo.items() if t in IFTYPES_FISICOS) if tipo else [v for _, v in base_ifindex]
    portas = {}
    for i in indices:
        if i in nome:
            portas[nome[i]] = {"up": up.get(i, False)}
            if vel is not None:
                portas[nome[i]]["velocidade"] = mbps.get(i) or None
    return portas


async def ler_portas(ip: str, community: str, *, walk=snmp.walk) -> dict[str, dict]:
    """Leitura leve: {porta: {"up", "velocidade"}}. SnmpErro propaga."""
    return _portas(await walk(ip, community, BASE_IFINDEX), await walk(ip, community, IFNAME),
                   await walk(ip, community, IFOPER), await walk(ip, community, IFHIGHSPEED),
                   await walk(ip, community, IFTYPE))


def uplinks(switch_ip: str, ips: list[dict]) -> dict[str, dict]:
    """Portas que levam a outro switch: com filho gerenciável ou com >= UPLINK_MIN_VIGIADOS vigiados."""
    por_porta: dict[str, dict] = {}
    for ap in ips:
        if ap.get("switch_ip") != switch_ip or not ap.get("switch_porta"):
            continue
        p = por_porta.setdefault(ap["switch_porta"], {"filho": None, "vigiados": 0})
        if ap.get("gerenciavel") and p["filho"] is None:
            p["filho"] = ap.get("ip")
        p["vigiados"] += mapa.vigiado(ap)
    return {k: v for k, v in por_porta.items() if v["filho"] or v["vigiados"] >= UPLINK_MIN_VIGIADOS}


async def ler_switch(ip: str, community: str, *, walk=snmp.walk, get=snmp.get) -> dict:
    descr = _texto(await get(ip, community, SYS_DESCR))  # SnmpErro aqui propaga
    base = await get(ip, community, BASE_MAC)
    base_ifindex = await walk(ip, community, BASE_IFINDEX)
    ifnames = await walk(ip, community, IFNAME)
    oper = await walk(ip, community, IFOPER)
    fdb = await walk(ip, community, FDB)
    qbridge = [] if fdb else await walk(ip, community, QFDB)
    try:
        vizinhos = _vizinhos(await walk(ip, community, LLDP_NOME), await walk(ip, community, LLDP_CHASSIS))
    except snmp.SnmpErro:
        vizinhos = {}
    portas = _portas(base_ifindex, ifnames, oper, tipos=await walk(ip, community, IFTYPE))
    return {
        "descr": descr,
        "base_mac": base.hex(":").upper() if isinstance(base, bytes) and len(base) == 6 else None,
        "portas": portas, "fdb": parse_fdb(fdb, base_ifindex, ifnames, qbridge), "vizinhos": vizinhos}
