"""Cálculos puros do painel dos switches: totais, série, tops e projeções."""
from collections import Counter
from datetime import datetime, timedelta
from statistics import linear_regression, mean

from .unifi import GRUPOS

LIMITE_INSTAVEL = 30
MIN_EVENTOS_INSTAVEL = 3
MIN_DIAS_PROJECAO = 7
MAX_DIAS_PROJECAO = 365
# periodo -> (tamanho do balde, nº de baldes)
BALDES = {"1h": (timedelta(minutes=5), 12), "24h": (timedelta(hours=1), 24),
          "7d": (timedelta(hours=6), 28), "30d": (timedelta(days=1), 30)}
_QUEDAS = "cliente_desconectou"


def _proj_mes(n: int, horas: int) -> float | None:
    return None if horas <= 1 else n / horas * 720


def _int(v):
    return None if v is None else round(v)


def totais(atual, anterior, horas, portas_top) -> dict:
    q = lambda evs: sum(e["tipo"] == _QUEDAS for e in evs)
    return {"eventos": len(atual), "eventos_anterior": len(anterior),
            "quedas_cliente": q(atual), "quedas_cliente_anterior": q(anterior),
            "portas_instaveis": sum(bool(p.get("instavel")) for p in portas_top),
            "projecao_30d": _int(_proj_mes(len(atual), horas))}


def serie(evs, inicio: datetime, periodo: str) -> list[dict]:
    tam, n = BALDES[periodo]
    # alinha à fronteira UTC do balde (sobe, p/ cobrir até agora; o balde parcial mais antigo cai)
    passo = int(tam.total_seconds())
    inicio = datetime.fromtimestamp(-(-int(inicio.timestamp()) // passo) * passo, tz=inicio.tzinfo)
    baldes = [{"hora": (inicio + i * tam).isoformat(), "clientes": 0, "alertas": 0, "poe": 0, "mudancas": 0}
              for i in range(n)]
    for e in evs:
        i = (e["recebido_em"] - inicio) // tam
        if 0 <= i < n:
            baldes[i][GRUPOS.get(e["tipo"], "alertas")] += 1
    return baldes


def portas_top(evs, nomes, horas, n: int | None = 10) -> list[dict]:
    """n=None devolve todas as portas (para contar as instáveis)."""
    c = Counter((e["mk_id"], e["campos"]["porta"]) for e in evs
                if e["tipo"] in ("cliente_conectou", "cliente_desconectou") and e["campos"].get("porta"))
    out = []
    for (mk, porta), qtd in c.most_common(n):
        proj = _proj_mes(qtd, horas)
        out.append({"switch_id": mk, "switch_nome": nomes.get(mk, "Switch removido"), "porta": porta, "eventos": qtd,
                    "projecao_mes": _int(proj),
                    "instavel": qtd >= MIN_EVENTOS_INSTAVEL and proj is not None and proj >= LIMITE_INSTAVEL})
    return out


def clientes_top(evs, nomes, n=10) -> list[dict]:
    c = Counter((e["campos"]["cliente"], e["mk_id"]) for e in evs
                if e["tipo"] == _QUEDAS and e["campos"].get("cliente"))
    return [{"cliente": cli, "switch_nome": nomes.get(mk, "Switch removido"), "quedas": q}
            for (cli, mk), q in c.most_common(n)]


def _reta(retratos, campo, t0):
    """(inclinação por dia, estimativa atual da reta) ou None com < 2 pontos."""
    pts = [((r["em"] - t0).total_seconds() / 86400, r[campo]) for r in retratos if r.get(campo) is not None]
    if len(pts) < 2 or len({x for x, _ in pts}) < 2:
        return None
    a, b = linear_regression([x for x, _ in pts], [y for _, y in pts])
    return a, a * pts[-1][0] + b


def _dias_ate(inclinacao, atual, alvo):
    # ponto de partida: estimativa atual da reta (não o último valor, que é ruidoso)
    if inclinacao <= 0:
        return None
    d = max(0.0, (alvo - atual) / inclinacao)
    return round(d) if d <= MAX_DIAS_PROJECAO else None  # dias inteiros, arredondado


def projecoes(retratos, agora: datetime) -> dict:
    vazio = {"poe": None, "temperatura": None, "portas": None}
    if len(retratos) < 2:
        return {"dias_historico": 0, **vazio}
    t0 = retratos[0]["em"]
    dias = (retratos[-1]["em"] - t0).total_seconds() / 86400
    if dias < MIN_DIAS_PROJECAO:
        return {"dias_historico": int(dias), **vazio}
    out = {"dias_historico": int(dias), **vazio}
    maxw = next((r["poe_max_w"] for r in reversed(retratos) if r.get("poe_max_w")), None)
    if (r := _reta(retratos, "poe_usado_w", t0)) and maxw:
        out["poe"] = {"dias_ate_80": _dias_ate(*r, 0.8 * maxw), "tendencia_w_dia": r[0]}
    if r := _reta(retratos, "temperatura", t0):
        out["temperatura"] = {"tendencia_c_semana": r[0] * 7}
    total = next((x["portas_total"] for x in reversed(retratos) if x.get("portas_total")), None)
    if (r := _reta(retratos, "portas_em_uso", t0)) and total:
        out["portas"] = {"dias_ate_cheio": _dias_ate(*r, total)}
    return out


def reduzir(retratos, max_pontos=200) -> list[dict]:
    passo = -(-len(retratos) // max_pontos) or 1
    out = []
    for i in range(0, len(retratos), passo):
        grupo = retratos[i:i + passo]
        ponto = {"em": grupo[0]["em"]}
        for c in ("poe_usado_w", "clientes", "temperatura"):
            v = [r[c] for r in grupo if r.get(c) is not None]
            ponto[c] = mean(v) if v else None
        out.append(ponto)
    return out
