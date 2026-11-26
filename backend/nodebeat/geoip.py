"""Geolocalização offline por país (DB-IP Lite, só IPv4)."""
from __future__ import annotations

import csv
import gzip
import ipaddress
from bisect import bisect_right
from dataclasses import dataclass
from pathlib import Path

_DADOS = Path(__file__).parent / "dados"


@dataclass(frozen=True)
class Pais:
    cc: str
    nome: str
    lat: float
    lon: float


# (inícios, fins, ccs, países por cc); None até carregar
_dados: tuple[list[int], list[int], list[str], dict[str, Pais]] | None = None


def carregar(faixas_csv_gz: Path, paises_csv: Path) -> None:
    global _dados
    inicios, fins, ccs = [], [], []
    with gzip.open(faixas_csv_gz, "rt", newline="") as f:
        for ini, fim, cc in csv.reader(f):
            inicios.append(int(ini))
            fins.append(int(fim))
            ccs.append(cc)
    with open(paises_csv, newline="", encoding="utf-8") as f:
        paises = {r["cc"]: Pais(r["cc"], r["nome"], float(r["lat"]), float(r["lon"]))
                  for r in csv.DictReader(f)}
    _dados = (inicios, fins, ccs, paises)


def precarregar() -> None:
    """Carrega a base padrão se ainda não carregou (~3 s); a API chama no startup, fora do event loop."""
    if _dados is None:
        carregar(_DADOS / "geoip-pais.csv.gz", _DADOS / "paises.csv")


def pais(ip: str) -> Pais | None:
    try:
        a = ipaddress.IPv4Address(ip)
    except ValueError:
        return None
    precarregar()
    inicios, fins, ccs, paises = _dados
    n = int(a)
    i = bisect_right(inicios, n) - 1
    if i < 0 or n > fins[i]:
        return None
    return paises.get(ccs[i])
