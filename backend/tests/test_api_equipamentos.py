import json

from nodebeat import crypto, store
from tests.test_api_inventario import anon, client, db, doc, r  # noqa: F401  (fixtures)
from tests.test_api_mks import criar

OUTRO = "aaaaaaaaaaaaaaaaaaaaaaaa"
NOVO = {"tipo": "switch", "nome": "SW1", "ip": "10.0.0.5", "local": "sede"}


async def _novo(client, **extra):
    resp = await client.post("/api/equipamentos", json=NOVO | extra)
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


async def test_exige_login(anon):
    assert (await anon.get("/api/equipamentos")).status_code == 401
    assert (await anon.post("/api/equipamentos", json=NOVO)).status_code == 401
    assert (await anon.get(f"/api/equipamentos/{OUTRO}")).status_code == 401
    assert (await anon.delete(f"/api/equipamentos/{OUTRO}")).status_code == 401


async def test_criar_manual_com_community_padrao_cifrada(client, db):
    id = await _novo(client)
    d = await store.get_equipamento(db, id)
    assert d["origem"] == "manual" and d["local"] == "sede"
    assert crypto.decrypt(d["community_cifrada"], client._transport.app.state.settings.secret_key) == "public"


async def test_get_nunca_devolve_community(client):
    id = await _novo(client, community="segredo123")
    for url in ("/api/equipamentos", f"/api/equipamentos/{id}"):
        txt = json.dumps((await client.get(url)).json())
        assert "community" not in txt and "segredo123" not in txt
    body = (await client.get(f"/api/equipamentos/{id}")).json()
    assert body["local_nome"] == "Sede" and body["uplinks"] == {} and body["estado"] is None


async def test_409_local_ip_repetido(client):
    await _novo(client)
    assert (await client.post("/api/equipamentos", json=NOVO | {"nome": "outro"})).status_code == 409


async def test_422(client):
    for extra in ({"tipo": "router"}, {"ip": "nao-ip"}, {"local": OUTRO}):
        assert (await client.post("/api/equipamentos", json=NOVO | extra)).status_code == 422


async def test_local_mk(client):
    mk = await criar(client)
    id = await _novo(client, local=mk)
    assert (await client.get(f"/api/equipamentos/{id}")).json()["local_nome"] != "Sede"


async def test_lista_com_estado_e_portas(client, r):
    id = await _novo(client)
    await r.set(f"state:eq:{id}", json.dumps({"status": "no_ar", "portas": {"1": {"up": True}, "2": {"up": False}}}))
    (linha,) = (await client.get("/api/equipamentos?tipo=switch")).json()
    assert linha["estado"]["status"] == "no_ar" and (linha["portas_total"], linha["portas_up"]) == (2, 1)


async def test_put_manual_e_409(client):
    a = await _novo(client)
    b = await _novo(client, ip="10.0.0.6")
    assert (await client.put(f"/api/equipamentos/{b}", json={"ip": "10.0.0.5"})).status_code == 409
    assert (await client.put(f"/api/equipamentos/{a}", json={"nome": "X", "ip": "10.0.0.5"})).status_code == 204
    assert (await client.get(f"/api/equipamentos/{a}")).json()["nome"] == "X"


async def test_descoberto_so_nome_e_nao_apaga(client, db, r):
    mk = await criar(client)
    id = await store.upsert_descoberto(db, "switch", mk, "10.9.9.9", "auto")
    assert (await client.put(f"/api/equipamentos/{id}", json={"ip": "10.9.9.8"})).status_code == 422
    assert (await client.put(f"/api/equipamentos/{id}", json={"nome": "Novo"})).status_code == 204
    resp = await client.delete(f"/api/equipamentos/{id}")
    assert resp.status_code == 409 and "some sozinho" in resp.text


async def test_apagar_manual_limpa_historico(client, r):
    id = await _novo(client)
    await r.set(f"state:eq:{id}", "{}")
    assert (await client.delete(f"/api/equipamentos/{id}")).status_code == 204
    assert await r.get(f"state:eq:{id}") is None
    assert (await client.get(f"/api/equipamentos/{id}")).status_code == 404


async def test_eventos_e_historico(client):
    id = await _novo(client)
    assert (await client.get(f"/api/equipamentos/{id}/eventos")).json() == []
    assert (await client.get(f"/api/equipamentos/{id}/historico")).json() == []
    assert (await client.get(f"/api/equipamentos/{OUTRO}/eventos")).status_code == 404
