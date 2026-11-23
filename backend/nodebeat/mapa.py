"""Lógica pura do mapa de rede (MAC, fabricante, vigiado, porta) — sem I/O."""
from __future__ import annotations

import re

# OUIs (MA-L) conferidos no registro IEEE (https://standards-oui.ieee.org/oui/oui.csv,
# consultado em 2026-11-23). Lista parcial: alguns por fabricante.
# Haiz: sem OUI próprio identificável no registro; fica de fora até haver MAC real.
OUIS = {
    "44:19:B6": "Hikvision",
    "00:BC:99": "Hikvision",
    "04:03:12": "Hikvision",
    "04:EE:CD": "Hikvision",
    "08:3B:C1": "Hikvision",
    "08:54:11": "Hikvision",
    "08:ED:ED": "Dahua",
    "14:A7:8B": "Dahua",
    "20:2C:05": "Dahua",
    "24:52:6A": "Dahua",
    "30:DD:AA": "Dahua",
    "38:AF:29": "Dahua",
    "00:1A:3F": "Intelbras",
    "18:0D:2C": "Intelbras",
    "24:FD:0D": "Intelbras",
    "30:E1:F1": "Intelbras",
    "44:3B:32": "Intelbras",
    "48:51:CF": "Intelbras",
    "FC:52:CE": "Control iD",
    "00:15:6D": "Ubiquiti",
    "00:27:22": "Ubiquiti",
    "04:18:D6": "Ubiquiti",
    "0C:EA:14": "Ubiquiti",
    "18:E8:29": "Ubiquiti",
    "1C:0B:8B": "Ubiquiti",
    "4C:5E:0C": "MikroTik",
    "00:0C:42": "MikroTik",
    "04:F4:1C": "MikroTik",
    "08:55:31": "MikroTik",
    "18:FD:74": "MikroTik",
    "2C:C8:1B": "MikroTik",
    "00:0A:EB": "TP-Link",
    "00:14:78": "TP-Link",
    "00:19:E0": "TP-Link",
    "00:1D:0F": "TP-Link",
    "00:21:27": "TP-Link",
    "00:23:CD": "TP-Link",
}
EQUIPAMENTOS = {"Hikvision", "Dahua", "Intelbras", "Control iD", "Haiz"}


def norm_mac(mac: str | None) -> str | None:
    hexa = re.sub(r"[-:.]", "", mac or "").upper()
    if not re.fullmatch(r"[0-9A-F]{12}", hexa):
        return None
    return ":".join(hexa[i:i + 2] for i in range(0, 12, 2))


def fabricante(mac: str | None) -> str:
    m = norm_mac(mac)
    if not m:
        return ""
    if int(m[:2], 16) & 0x02:
        return "MAC privado"
    return OUIS.get(m[:8], "Outro")


def e_equipamento(fab: str) -> bool:
    return fab in EQUIPAMENTOS


def vigiado(ap: dict) -> bool:
    manual = ap.get("vigiar_manual")
    if manual is not None:
        return bool(manual)
    return e_equipamento(ap.get("fabricante", "")) or bool(ap.get("fixo"))


def porta_do_aparelho(mac, arp_iface, host: dict[str, str], bridges: set[str]):
    """(porta, bridge): porta vem da tabela de hosts da bridge, ou da interface do ARP."""
    m = norm_mac(mac)
    if arp_iface in bridges:
        return (host.get(m) if m else None), arp_iface
    return arp_iface, None


def _txt(v):
    """librouteros converte "yes"/"true" em bool e números em int; volta para texto."""
    return None if v is None or v is False else str(v)


def _verdadeiro(v) -> bool:
    return v is True or str(v).lower() in ("true", "yes")


def fatos_por_ip(raw: dict, ips: list[dict]) -> dict[str, dict]:
    """Fatos de cada IP visto: porta, bridge, fabricante e dados do vizinho (LLDP/MNDP)."""
    host: dict[str, str] = {}
    bridges: set[str] = set()
    for h in raw.get("bridge_host") or []:
        if h.get("bridge"):
            bridges.add(h["bridge"])
        m = norm_mac(_txt(h.get("mac-address")))
        if m and not _verdadeiro(h.get("local")) and h.get("on-interface"):
            host[m] = h["on-interface"]
    for p in raw.get("bridge_port") or []:
        if p.get("bridge"):
            bridges.add(p["bridge"])
    iface = {a.get("address"): a.get("interface") for a in raw.get("arp") or []}
    viz = {m: n for n in raw.get("neighbor") or [] if (m := norm_mac(_txt(n.get("mac-address"))))}
    out = {}
    for i in ips:
        porta, bridge = porta_do_aparelho(i.get("mac"), iface.get(i["ip"]), host, bridges)
        m = norm_mac(i.get("mac"))
        n = (viz.get(m) if m else None) or {}
        out[i["ip"]] = {
            "porta": porta, "bridge": bridge, "fabricante": fabricante(i.get("mac")),
            "identidade": _txt(n.get("identity")), "plataforma": _txt(n.get("platform")),
            "e_switch": "bridge" in str(n.get("system-caps") or "").lower()}
    return out
