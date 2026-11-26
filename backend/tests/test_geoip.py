import gzip

from nodebeat import geoip


def _fixture(tmp_path):
    f = tmp_path / "f.csv.gz"
    with gzip.open(f, "wt") as g:
        g.write("16777216,16777471,AU\n")  # 1.0.0.0-1.0.0.255
    p = tmp_path / "p.csv"
    p.write_text("cc,nome,lat,lon\nAU,Austrália,-27,133\n", encoding="utf-8")
    geoip.carregar(f, p)


def test_pais_por_faixa(tmp_path):
    _fixture(tmp_path)
    assert geoip.pais("1.0.0.0").cc == "AU"
    assert geoip.pais("1.0.0.255").cc == "AU"
    assert geoip.pais("1.0.1.0") is None


def test_pais_desconhecido(tmp_path):
    _fixture(tmp_path)
    assert geoip.pais("2001:db8::1") is None
    assert geoip.pais("lixo") is None
    assert geoip.pais("10.0.0.1") is None


def test_pais_tem_centroide(tmp_path):
    _fixture(tmp_path)
    p = geoip.pais("1.0.0.1")
    assert (p.nome, p.lat, p.lon) == ("Austrália", -27.0, 133.0)


def test_dados_reais_carregam():
    geoip._dados = None  # descarta fixture de outros testes
    assert geoip.pais("8.8.8.8").cc == "US"
