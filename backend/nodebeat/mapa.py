"""Lógica pura do mapa de rede (MAC, fabricante, vigiado, porta) — sem I/O."""
from __future__ import annotations

import re
from collections import Counter
from datetime import datetime, timedelta
from ipaddress import ip_address, ip_network

from . import inventario

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
    "D8:B3:70": "Ubiquiti",
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
    # switch que respondeu SNMP (worker.run_switches) também é vigiado
    return e_equipamento(ap.get("fabricante", "")) or bool(ap.get("fixo")) or bool(ap.get("gerenciavel"))


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


def proximo_estado(ant: dict | None, respondeu: bool, agora: datetime) -> dict:
    """Estado do aparelho após um ping: offline só depois de 2 falhas seguidas."""
    falhas = 0 if respondeu else (ant or {}).get("falhas", 0) + 1
    if respondeu:
        online = True
    elif falhas >= 2:
        online = False
    else:
        online = (ant or {}).get("online")  # 1ª falha: mantém o anterior (None se não havia)
    desde = ant["desde"] if ant and ant.get("online") == online and ant.get("desde") else agora.isoformat()
    return {"online": online, "falhas": falhas, "desde": desde}


def estado_de(vig: bool, em_tunel: bool, mk_no_ar: bool, est: dict | None) -> str:
    if not vig or not em_tunel:
        return "nao_vigiado"
    if not mk_no_ar or not est or est.get("online") is None:
        return "desconhecido"
    return "no_ar" if est["online"] else "offline"


def _em_tunel(ip: str, redes: list[str]) -> bool:
    try:
        a = ip_address(ip)
        return any(a in ip_network(r, strict=False) for r in redes)
    except ValueError:
        return False


def _aparelho_saida(ap: dict, estados: dict, mk_no_ar: bool, redes: list[str], agora: datetime | None) -> dict:
    est = estados.get(ap["ip"])
    vig = vigiado(ap)
    visto = ap.get("ultimo_visto")
    antigo = agora is not None and visto is not None and agora - visto > timedelta(days=inventario.DIAS_EM_USO)
    estado = "nao_vigiado" if antigo else estado_de(vig, _em_tunel(ap["ip"], redes), mk_no_ar, est)
    manual = ap.get("e_switch_manual")
    return {
        "ip": ap["ip"], "mac": ap.get("mac"), "fabricante": ap.get("fabricante", ""),
        "nome": ap.get("apelido") or ap.get("identidade") or ap.get("host_name") or "",
        "apelido": ap.get("apelido"), "vigiado": vig,
        "e_switch": bool(manual if manual is not None else ap.get("e_switch")),
        "estado": estado, "desde": est.get("desde") if est else None, "ultimo_visto": visto,
        "porta_desconhecida": not ap.get("porta")}


def _nome_porta(ap: dict) -> str:
    if ap.get("porta"):
        return ap["porta"]
    return f"{ap['bridge']} (porta desconhecida)" if ap.get("bridge") else "Sem porta"


def _causa(nome: str, aps: list[dict], link: dict[str, bool], mk_no_ar: bool) -> str | None:
    # MK (ou switch acima) fora do ar: dados de link/ping são velhos, então não há causa.
    if not mk_no_ar:
        return None
    if link.get(nome) is False:
        return "link caído"
    estados = [a["estado"] for a in aps if a["estado"] in ("no_ar", "offline")]
    if len(estados) >= 2 and all(e == "offline" for e in estados):
        return "todos sem resposta"
    return None


def _casa(a: dict, busca: str) -> bool:
    return any(busca in str(a[c] or "").lower() for c in ("ip", "mac", "nome", "fabricante"))


# ponytail: _todos, _podar e preencher são recursivos; cadeia de ~1000 switches estouraria a
# recursão do Python (topologia real não chega perto). Trocar por pilha explícita se chegar.
def _todos(aps: list[dict]):
    """Os aparelhos e tudo o que está abaixo dos switches gerenciáveis entre eles."""
    for a in aps:
        yield a
        for p in a.get("portas", []):
            yield from _todos(p["aparelhos"])


def _porta_saida(nome: str, aps: list[dict], *, link, rotulos, mk_no_ar) -> dict:
    todos = list(_todos(aps))
    causa = _causa(nome, todos, link, mk_no_ar)
    aps = sorted(aps, key=lambda a: (not (a["e_switch"] or a.get("gerenciavel")), ip_address(a["ip"])))
    return {
        "nome": nome,
        "rotulo": rotulos.get(nome, "") if not all(a["porta_desconhecida"] for a in aps) else "",
        "link": "desconhecido" if nome not in link else ("up" if link[nome] else "down"),
        "vigiados": sum(a["estado"] in ("no_ar", "offline") for a in todos),
        "no_ar": sum(a["estado"] == "no_ar" for a in todos),
        "problema": causa is not None or any(a["estado"] == "offline" for a in aps)
        or any(p["problema"] for a in aps for p in a.get("portas", [])),
        "causa": causa, "aparelhos": aps}


def _ordenar(portas: list[dict]) -> list[dict]:
    return sorted(portas, key=lambda p: (not p["problema"], p["nome"].lower()))


def _podar(portas: list[dict], fica, causa_mantem: bool = False) -> list[dict]:
    """Mantém o aparelho que `fica` e o switch com algo mantido abaixo; porta vazia sai.
    `causa_mantem`: porta com causa fica com todos os aparelhos."""
    for p in portas:
        if causa_mantem and p["causa"]:
            continue
        aps = []
        for a in p["aparelhos"]:
            if "portas" in a:
                a["portas"] = _podar(a["portas"], fica, causa_mantem)
            if fica(a) or a.get("portas"):
                aps.append(a)
        p["aparelhos"] = aps
    return [p for p in portas if p["aparelhos"]]


def _cortar_ciclos(pai: dict[str, str], peso: dict[str, int] | None = None) -> set[str]:
    """IPs que perdem a ligação para não haver ciclo: em cada ciclo, o de maior `peso` (MACs
    aprendidos na porta da ligação: o uplink aprende muitos); empate ou sem peso, maior IP (texto)."""
    pai, cortados, peso = dict(pai), set(), peso or {}
    for inicio in sorted(pai):  # cada nó tem um pai só: andar para cima acha os ciclos
        caminho, n = [], inicio
        while n in pai and n not in caminho:
            caminho.append(n)
            n = pai[n]
        if n in caminho:
            c = max(caminho[caminho.index(n):], key=lambda x: (peso.get(x, 0), x))
            del pai[c]
            cortados.add(c)
    return cortados


DICA_SNMP = "gerenciável detectado: ative o SNMP nele"


def _arvore_switches(saidas: list[tuple[dict, dict]], switches: list[dict], mk_no_ar: bool):
    """Encaixa cada aparelho no switch gerenciável gravado nele (switch_ip/switch_porta) e monta as
    portas dos switches; devolve os (aparelho, saída) que ficam direto nas portas da MK.

    Ligação só vale para switch gerenciável que também é aparelho da lista; ciclo perde a ligação
    do switch de maior IP. Abaixo de switch offline tudo fica desconhecido e sem causa."""
    ger = {s["ip"]: s for s in switches if s.get("gerenciavel")}
    ips = {ap["ip"] for ap, _ in saidas}
    pai = {ap["ip"]: (ap["switch_ip"], str(ap["switch_porta"])) for ap, _ in saidas
           if ap.get("switch_ip") in ger and ap["switch_ip"] in ips and ap.get("switch_porta") not in (None, "")}
    for ip in _cortar_ciclos({k: v[0] for k, v in pai.items()}):
        del pai[ip]
    offline = {ap["ip"] for ap, a in saidas if a["estado"] == "offline"}

    def mudo(ip):  # algum switch acima está offline
        while ip in pai:
            ip = pai[ip][0]
            if ip in offline:
                return True
        return False

    filhos: dict[str, dict[str, list[dict]]] = {}
    sw_saida, raiz = {}, []
    for ap, a in saidas:
        if a["estado"] in ("no_ar", "offline") and mudo(ap["ip"]):
            a["estado"] = "desconhecido"
        if ap["ip"] in ger:
            s = ger[ap["ip"]]
            a.update(gerenciavel=True, snmp_erro=bool(s.get("erro")), switch_lido_em=s.get("lido_em"))
            sw_saida[ap["ip"]] = a
        elif a["e_switch"]:
            a.update(gerenciavel=False, dica=DICA_SNMP)
        if ap["ip"] in pai:
            sw, porta = pai[ap["ip"]]
            filhos.setdefault(sw, {}).setdefault(porta, []).append(a)
        else:
            raiz.append((ap, a))

    def preencher(ip):  # das folhas para cima: contadores da porta precisam das portas dos filhos
        link = {n: v["up"] for n, v in (ger[ip].get("portas") or {}).items() if isinstance(v.get("up"), bool)}
        ativo = mk_no_ar and ip not in offline and not mudo(ip)
        portas = []
        for nome, aps in filhos.get(ip, {}).items():
            for a in aps:
                if a["ip"] in sw_saida:
                    preencher(a["ip"])
            portas.append(_porta_saida(nome, aps, link=link, rotulos={}, mk_no_ar=ativo))
        sw_saida[ip]["portas"] = _ordenar(portas)

    for ip in sw_saida:
        if ip not in pai:
            preencher(ip)
    return raiz


def montar_arvore(aparelhos: list[dict], *, link: dict[str, bool], rotulos: dict[str, str],
                  estados: dict[str, dict], mk_no_ar: bool, redes_tunel: list[str],
                  busca: str | None = None, so_problema: bool = False,
                  agora: datetime | None = None, switches: list[dict] | None = None) -> list[dict]:
    """Árvore porta -> aparelhos de uma MK; com `switches`, porta -> switch -> porta -> aparelhos.
    Contadores e causa valem para a sub-árvore inteira da porta; `busca` e `so_problema` só
    filtram o que é listado (mantendo o caminho até o que fica)."""
    saidas = [(ap, _aparelho_saida(ap, estados, mk_no_ar, redes_tunel, agora)) for ap in aparelhos]
    if switches is not None:  # [] ainda marca candidatos com a dica
        saidas = _arvore_switches(saidas, switches, mk_no_ar)
    grupos: dict[str, list[dict]] = {}
    for ap, a in saidas:
        grupos.setdefault(_nome_porta(ap), []).append(a)
    portas = [_porta_saida(n, aps, link=link, rotulos=rotulos, mk_no_ar=mk_no_ar)
              for n, aps in grupos.items()]
    if so_problema:
        portas = _podar(portas, lambda a: a["estado"] == "offline", causa_mantem=True)
    if busca:
        b = busca.strip().lower()
        portas = _podar(portas, lambda a: _casa(a, b))
    return _ordenar(portas)


def ligacoes(switches: list[dict], aparelhos: list[dict]) -> dict[str, dict]:
    """{ip: {"switch_ip", "porta"}} de cada aparelho que algum switch gerenciável conhece.

    Vale a (switch, porta) com menos MACs aprendidos (a mais perto da folha: uplink aprende
    muitos); empate -> menor (switch_ip, porta). Switch é ligado pelo MAC dele e pelo base_mac,
    nunca a si mesmo. Ciclo entre switches (cada um vê o outro): perde a ligação a ponta cuja
    porta aprendeu mais MACs (o uplink), que tenta o próximo candidato; empate -> maior IP."""
    vistos: dict[str, list[tuple[int, str, str]]] = {}  # MAC -> [(contagem, switch_ip, porta)]
    for s in switches:
        if not (s.get("gerenciavel") and s.get("fdb")):
            continue
        cont = Counter(str(p) for p in s["fdb"].values())
        for m, p in s["fdb"].items():
            if n := norm_mac(m):
                vistos.setdefault(n, []).append((cont[str(p)], s["ip"], str(p)))
    base = {}
    for s in switches:
        if n := norm_mac(s.get("base_mac")):
            base.setdefault(s["ip"], set()).add(n)
    cands: dict[str, list[tuple[int, str, str]]] = {}  # IP -> candidatos, melhor primeiro
    for ap in aparelhos:
        macs = {m for m in [norm_mac(ap.get("mac"))] if m} | base.get(ap["ip"], set())
        if c := sorted({c for m in macs for c in vistos.get(m, []) if c[1] != ap["ip"]}):
            cands[ap["ip"]] = c
    # cada volta tira ao menos um candidato de alguém: termina em sum(len(cands)) voltas
    while cortados := _cortar_ciclos({ip: c[0][1] for ip, c in cands.items()},
                                     {ip: c[0][0] for ip, c in cands.items()}):
        for ip in cortados:
            cands[ip].pop(0)
            if not cands[ip]:
                del cands[ip]
    return {ip: {"switch_ip": c[0][1], "porta": c[0][2]} for ip, c in cands.items()}
