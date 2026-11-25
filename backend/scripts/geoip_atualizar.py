"""Gera nodebeat/dados/geoip-pais.csv.gz e paises.csv. Roda à mão, ~1x por mês.

Fontes:
- Faixas: DB-IP "IP to Country Lite" (CC-BY 4.0, https://db-ip.com) — so IPv4.
- Centroides: albertyw/avenews average-latitude-longitude-countries.csv (derivado do Google DSPL countries.csv).
- Nomes pt-BR: Unicode CLDR (cldr-json, localenames pt).
Uso: python scripts/geoip_atualizar.py [AAAA-MM]
"""
import csv
import gzip
import io
import ipaddress
import json
import sys
import urllib.request
from datetime import date
from pathlib import Path

DADOS = Path(__file__).resolve().parent.parent / "nodebeat" / "dados"
DBIP = "https://download.db-ip.com/free/dbip-country-lite-{}.csv.gz"
CENTROIDES = "https://raw.githubusercontent.com/albertyw/avenews/master/old/data/average-latitude-longitude-countries.csv"
CLDR = "https://raw.githubusercontent.com/unicode-org/cldr-json/main/cldr-json/cldr-localenames-full/main/pt/territories.json"


# Faltam na tabela de centroides (valores aproximados).
EXTRAS = {"AX": (60.2, 20.0), "BL": (17.9, -62.8), "BQ": (12.2, -68.3), "CW": (12.2, -69.0),
          "GG": (49.5, -2.6), "IM": (54.2, -4.5), "JE": (49.2, -2.1), "MF": (18.1, -63.1),
          "PN": (-25.1, -130.1), "SS": (7.0, 30.0), "SX": (18.0, -63.1), "TL": (-8.8, 125.7),
          "XK": (42.6, 20.9)}


def baixar(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "geoip-atualizar/1.0"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def faixas(mes: str) -> bytes:
    try:
        return baixar(DBIP.format(mes))
    except Exception:  # mês ainda não publicado: tenta o anterior
        a, m = map(int, mes.split("-"))
        return baixar(DBIP.format(f"{a - (m == 1)}-{(m - 2) % 12 + 1:02d}"))


def main() -> None:
    mes = sys.argv[1] if len(sys.argv) > 1 else date.today().strftime("%Y-%m")
    linhas = []
    texto = gzip.decompress(faixas(mes)).decode()
    for ini, fim, cc in csv.reader(io.StringIO(texto)):
        if ":" in ini or cc == "ZZ":  # sso IPv4; ZZ = sem pais
            continue
        linhas.append((int(ipaddress.ip_address(ini)), int(ipaddress.ip_address(fim)), cc))
    linhas.sort()
    DADOS.mkdir(parents=True, exist_ok=True)
    with gzip.open(DADOS / "geoip-pais.csv.gz", "wt", newline="", compresslevel=9) as f:
        csv.writer(f).writerows(linhas)

    nomes = json.loads(baixar(CLDR))["main"]["pt"]["localeDisplayNames"]["territories"]
    cent = {r[0]: (r[2], r[3]) for r in csv.reader(io.StringIO(baixar(CENTROIDES).decode()))
            if len(r[0]) == 2 and r[0].isalpha()}
    ccs = sorted({l[2] for l in linhas})
    cent.update({c: (str(a), str(b)) for c, (a, b) in EXTRAS.items() if c not in cent})
    print("sem centroide (lat/lon 0):", [c for c in ccs if c not in cent])
    with open(DADOS / "paises.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["cc", "nome", "lat", "lon"])
        for c in ccs:
            lat, lon = cent.get(c, ("0", "0"))
            w.writerow([c, nomes.get(c, c), lat, lon])
    print(len(linhas), "faixas,", len(ccs), "países")


if __name__ == "__main__":
    main()
