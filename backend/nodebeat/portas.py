"""Histórico de link por porta (MK e switch). Funções puras, só stdlib."""

from datetime import datetime

# Porta que caiu há menos que isto ainda aparece como "caiu" (não "down").
CAIU_JANELA_S = 86400

_PREFIXOS_FISICOS = ("ether", "sfp", "combo", "qsfp")


def fisica_mk(nome: str) -> bool:
    """True se a interface é física (ether, sfp, combo, qsfp), sem diferenciar maiúsculas."""
    return nome.lower().startswith(_PREFIXOS_FISICOS)


def atualizar(ant: dict[str, dict] | None, up: dict[str, bool], agora: datetime) -> dict[str, dict]:
    """Gera o novo estado por porta a partir do estado anterior e do link atual.

    Campos extras da entrada anterior (ex.: "velocidade") são preservados.
    Porta ausente em `up` sai do resultado.
    """
    ant = ant or {}
    novo = {}
    for nome, is_up in up.items():
        prev = ant.get(nome)
        entrada = dict(prev) if prev else {"velocidade": None}
        if prev is None or prev["up"] != is_up:
            entrada["desde"] = agora.isoformat()
        if is_up:
            entrada["caiu_em"] = None
        elif prev is not None and prev["up"]:
            entrada["caiu_em"] = agora.isoformat()
        else:
            entrada["caiu_em"] = prev.get("caiu_em") if prev else None
        entrada["up"] = is_up
        novo[nome] = entrada
    return novo


def estado_porta(p: dict, agora: datetime) -> str:
    """'up', 'caiu' (caiu há menos de CAIU_JANELA_S) ou 'down'."""
    if p["up"]:
        return "up"
    if p.get("caiu_em"):
        decorrido = (agora - datetime.fromisoformat(p["caiu_em"])).total_seconds()
        if decorrido < CAIU_JANELA_S:
            return "caiu"
    return "down"
