"""Lógica pura do inventário de rede das MKs (sem I/O)."""
from __future__ import annotations

from datetime import datetime, timedelta
from ipaddress import ip_address, ip_network

LIMITE_LEITURA = timedelta(hours=2)
DIAS_EM_USO = 15


def _faixa(p: str, q: str):
    return ip_address(p.strip()), ip_address(q.strip())


def _no_pool(ip, ranges: str) -> bool:
    for parte in (ranges or "").split(","):
        if not parte.strip():
            continue
        a, _, b = parte.partition("-")
        ini, fim = _faixa(a, b or a)
        if ini <= ip <= fim:
            return True
    return False


def montar(raw: dict) -> dict:
    ipsec, srcs = [], []
    for p in raw.get("ipsec_policy", []):
        src = p.get("src-address")
        if p.get("template") or p.get("disabled") or not src:
            continue
        s = ip_network(src, strict=False)
        if s.prefixlen == 0:
            continue
        srcs.append(s)
        ipsec.append({"src": str(s), "dst": str(ip_network(p.get("dst-address", "0.0.0.0/0"), strict=False))})

    redes = []

    def add(rede, origem, interface):
        redes.append({"rede": str(rede), "origem": origem, "interface": interface,
                      "tunel": any(rede.subnet_of(s) for s in srcs)})

    for a in raw.get("address", []):
        if a.get("disabled") or a.get("dynamic"):
            continue
        rede = ip_network(a["address"], strict=False)
        if rede.prefixlen < 32:
            add(rede, "address", a.get("interface"))
    for d in raw.get("dhcp_network", []):
        add(ip_network(d["address"], strict=False), "dhcp", None)

    nat = []
    for n in raw.get("nat", []):
        if n.get("action") != "dst-nat":
            continue
        ativo = not n.get("disabled")
        nat.append({
            "protocolo": n.get("protocol"), "dst_port": n.get("dst-port"),
            "to_addresses": n.get("to-addresses"), "to_ports": n.get("to-ports"),
            "comentario": n.get("comment") or "", "ativo": ativo,
            "aberto": ativo and not n.get("src-address") and not n.get("src-address-list"),
        })

    servicos = []
    for s in raw.get("service", []):
        ativo = not s.get("disabled")
        servicos.append({"nome": s["name"], "porta": s["port"], "ativo": ativo,
                         "aberto": ativo and not s.get("address")})

    return {
        "redes": redes, "ipsec": ipsec,
        "pools": [{"nome": p.get("name", ""), "ranges": p.get("ranges", "")} for p in raw.get("pool", [])],
        "nat": nat, "servicos": servicos,
    }


def ips_vistos(lease: list[dict], arp: list[dict], redes: list[str]) -> list[dict]:
    nets = [ip_network(r) for r in redes]
    vistos: dict[str, dict] = {}
    for fixo, linhas in ((False, arp), (True, lease)):  # lease sobrescreve arp
        for l in linhas:
            ip = l.get("address")
            if not ip or not any(ip_address(ip) in n for n in nets):
                continue
            ant = vistos.get(ip, {})
            vistos[ip] = {
                "ip": ip, "mac": l.get("mac-address") or ant.get("mac"),
                "host_name": l.get("host-name") or ant.get("host_name"),
                "fixo": (not l.get("dynamic")) if fixo else ant.get("fixo", False),
            }
    return list(vistos.values())


def desatualizado(lido_em: datetime | None, agora: datetime) -> bool:
    return lido_em is None or agora - lido_em > LIMITE_LEITURA


def sobreposicoes(mks: list[dict], sede: list[str]) -> list[dict]:
    tuneis = [(m["nome"], r["rede"]) for m in mks for r in m["redes"] if r["tunel"]]
    out = []
    for i, (a, ra) in enumerate(tuneis):
        na = ip_network(ra)
        for b, rb in tuneis[i + 1:] + [("Sede", s) for s in sede]:
            if a != b and na.overlaps(ip_network(rb)):
                out.append({"a": a, "rede_a": ra, "b": b, "rede_b": rb})
    return out


def conferir_faixa(cidr: str, mks: list[dict], sede: list[str], agora: datetime) -> dict:
    faixa = ip_network(cidr.strip(), strict=False)  # ValueError se inválido
    colisoes, avisos = [], []
    for m in mks:
        for r in m["redes"]:
            if not faixa.overlaps(ip_network(r["rede"])):
                continue
            if r["tunel"]:
                colisoes.append({"nome": m["nome"], "rede": r["rede"]})
            else:
                avisos.append(f"{m['nome']} usa {r['rede']} em rede local (não passa pelo túnel)")
    for s in sede:
        if faixa.overlaps(ip_network(s)):
            colisoes.append({"nome": "Sede", "rede": s})
    if not sede:
        avisos.append("Redes da sede não cadastradas")
    return {
        "faixa": str(faixa), "resultado": "em_uso" if colisoes else "livre",
        "colisoes": colisoes, "avisos": avisos,
        "faltam": [m["nome"] for m in mks if desatualizado(m.get("lido_em"), agora)],
    }


def porta_em(spec: str | None, porta: int) -> bool:
    if not spec:
        return True
    for parte in spec.split(","):
        a, _, b = parte.strip().partition("-")
        if int(a) <= porta <= int(b or a):
            return True
    return False


def conferir_porta(porta: int, protocolo: str, inv: dict) -> dict:
    usos, avisos = [], []
    for n in inv["nat"]:
        if n["protocolo"] not in (None, protocolo) or not porta_em(n["dst_port"], porta):
            continue
        desc = f"NAT {n['dst_port'] or 'qualquer porta'} -> {n['to_addresses'] or '?'}"
        if n["comentario"]:
            desc += f" ({n['comentario']})"
        if n["ativo"]:
            usos.append(desc)
        else:
            avisos.append(f"Regra desativada: {desc}")
    if protocolo == "tcp":
        for s in inv["servicos"]:
            if s["porta"] == porta:
                (usos if s["ativo"] else avisos).append(
                    f"Serviço {s['nome']}" if s["ativo"] else f"Serviço {s['nome']} desativado")
    return {"porta": porta, "protocolo": protocolo,
            "resultado": "em_uso" if usos else "livre", "usos": usos, "avisos": avisos}


def ip_em_uso(visto: dict, agora: datetime) -> bool:
    return bool(visto["fixo"]) or agora - visto["ultimo_visto"] <= timedelta(days=DIAS_EM_USO)


def conferir_ip(ip: str, inv: dict, vistos: list[dict], agora: datetime) -> dict:
    addr = ip_address(ip.strip())  # ValueError se inválido
    base = {"ip": str(addr), "visto": None, "avisos": []}
    if not any(addr in ip_network(r["rede"]) for r in inv["redes"]):
        return {**base, "resultado": "fora_da_faixa"}
    achados = [v for v in vistos if v["ip"] == str(addr)]
    visto = max(achados, key=lambda v: v["ultimo_visto"], default=None)
    base["visto"] = visto
    if visto and ip_em_uso(visto, agora):
        return {**base, "resultado": "em_uso"}
    if visto:
        base["avisos"].append(f"visto em {visto['ultimo_visto']:%d/%m}")
    if any(_no_pool(addr, p["ranges"]) for p in inv["pools"]):
        base["avisos"].append("IP dentro de um pool DHCP")
    return {**base, "resultado": "livre"}
