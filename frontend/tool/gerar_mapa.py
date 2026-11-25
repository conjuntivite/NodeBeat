"""Gera assets/ataques/terra.json a partir do Natural Earth 110m land (domínio público).

Origem: https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_land.geojson
Uso: python -I tool/gerar_mapa.py ne_110m_land.geojson assets/ataques/terra.json
Saída: lista de polígonos [[lon, lat], ...] (só o anel externo), coordenadas com 1 casa decimal.
"""
import json
import sys


def simplificar(anel):
    pts = []
    for lon, lat in anel:
        p = [round(lon, 1), round(lat, 1)]
        if not pts or pts[-1] != p:
            pts.append(p)
    return pts if len(pts) >= 4 else None


def main(origem, destino):
    with open(origem, encoding="utf-8") as f:
        geo = json.load(f)
    poligonos = []
    for feat in geo["features"]:
        g = feat["geometry"]
        partes = [g["coordinates"]] if g["type"] == "Polygon" else g["coordinates"]
        for p in partes:
            anel = simplificar(p[0])
            if anel:
                poligonos.append(anel)
    with open(destino, "w", encoding="utf-8") as f:
        json.dump(poligonos, f, separators=(",", ":"))
    print(f"{len(poligonos)} polígonos")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
