"""Baixa as bandeiras dos paises (PNG 40px de largura) para assets/bandeiras/.

Fonte: https://flagcdn.com (bandeiras nacionais, dominio publico).
Codigos: backend/nodebeat/dados/paises.csv. Uso: python tool/baixar_bandeiras.py
"""
import csv
import pathlib
import urllib.request

raiz = pathlib.Path(__file__).resolve().parents[2]
destino = raiz / "frontend" / "assets" / "bandeiras"
destino.mkdir(parents=True, exist_ok=True)

with open(raiz / "backend/nodebeat/dados/paises.csv", encoding="utf-8") as f:
    codigos = [r["cc"].lower() for r in csv.DictReader(f)]

faltam = []
for cc in codigos:
    req = urllib.request.Request(
        f"https://flagcdn.com/w40/{cc}.png", headers={"User-Agent": "nodebeat-bandeiras"}
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            (destino / f"{cc}.png").write_bytes(r.read())
    except Exception as e:
        faltam.append(cc)
        print(f"AVISO: {cc} nao baixou ({e})")

print(f"{len(codigos) - len(faltam)} baixadas, {len(faltam)} faltando: {faltam}")
