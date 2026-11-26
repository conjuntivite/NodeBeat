from datetime import UTC, datetime, timedelta

from nodebeat import ataques
from nodebeat.geoip import Pais
from nodebeat.painel import Ctx

CTX = Ctx(["10.1.0.0/16"], ["198.51.100.7"])
NOMES = {"a": "MK A", "b": "MK B"}
T0 = datetime(2026, 11, 25, 12, tzinfo=UTC)
CHAVES = {"ip", "pais", "pais_nome", "lat", "lon", "mk_nome", "via", "n", "sucesso", "quando", "usuario"}


def pais_de(ip):
    return Pais("BR", "Brasil", -10.0, -50.0) if ip.startswith("203.") else None


def falha(ip, mk="a", via="ssh", t=0):
    return {"mk_id": mk, "tipo": "login_falha", "campos": {}, "severidade": "crit",
            "recebido_em": T0 + timedelta(seconds=t), "mensagem": f"login failure for user root from {ip} via {via}"}


def login(ip, usuario, mk="a"):
    return {"mk_id": mk, "tipo": "login", "campos": {"ip": ip, "usuario": usuario}, "severidade": "info",
            "recebido_em": T0, "mensagem": f"user {usuario} logged in from {ip} via ssh"}


def ag(evs, **kw):
    return ataques.agrupar(evs, NOMES, CTX, pais_de, **kw)


def test_agrupa_por_ip_mk_via():
    g, d = ag([falha("203.0.113.5", t=i) for i in range(3)] + [falha("203.0.113.5", via="ftp", t=9)])
    assert sorted(x["n"] for x in g) == [1, 3] and d == 0
    x = next(x for x in g if x["n"] == 3)
    assert x["pais"] == "BR" and x["mk_nome"] == "MK A" and x["via"] == "ssh" and x["sucesso"] is False
    assert x["quando"] == (T0 + timedelta(seconds=2)).isoformat()


def test_ignora_interno_e_sede():
    assert ag([falha("10.1.2.3"), falha("198.51.100.7")]) == ([], 0)


def test_login_aceito():
    g, _ = ag([login("203.0.113.5", "admin"), login("203.0.113.6", "monitor")])
    assert len(g) == 1 and g[0]["sucesso"] is True and g[0]["usuario"] == "admin"


def test_ignora_mk_desconhecida():
    assert ag([falha("203.0.113.5", mk="zzz")]) == ([], 0)


def test_pais_desconhecido():
    g, _ = ag([falha("192.0.2.9")])
    assert g[0]["pais"] is None and g[0]["lat"] is None and g[0]["pais_nome"] is None


def test_teto_de_grupos():
    g, d = ag([falha(f"203.0.113.{i}", t=i) for i in range(250)], max_grupos=200)
    assert len(g) == 200 and d == 50
    assert min(x["quando"] for x in g) == (T0 + timedelta(seconds=50)).isoformat()


def test_sem_ip_publico():
    g, _ = ag([falha("203.0.113.5"), login("203.0.113.6", "admin")])
    assert all(set(x) == CHAVES or set(x) == CHAVES - {"usuario"} for x in g)


def test_logins_aceitos_de_usuarios_diferentes_no_mesmo_ip_nao_se_fundem():
    g, _ = ag([login("203.0.113.5", "admin"), login("203.0.113.5", "joao"), login("203.0.113.5", "admin")])
    assert sorted((x["usuario"], x["n"]) for x in g) == [("admin", 2), ("joao", 1)]
