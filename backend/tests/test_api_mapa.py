import json
from datetime import UTC, datetime

from nodebeat import routeros, store
from tests.test_api_inventario import anon, client, db, doc, r  # noqa: F401  (fixtures)
from tests.test_api_mks import criar

IP = "192.168.1.7"
OUTRO = "aaaaaaaaaaaaaaaaaaaaaaaa"


async def _ap(db, id, ip=IP, **extra):
    await store.registrar_ips(db, id, [{"ip": ip, "mac": "44:19:B6:00:00:01", "host_name": "cam", "fixo": False}],
                              datetime.now(UTC), {ip: {"porta": "ether2", "fabricante": "Hikvision", **extra}})


async def test_exige_login(anon):
    assert (await anon.get(f"/api/mks/{OUTRO}/mapa")).status_code == 401
    assert (await anon.put(f"/api/mks/{OUTRO}/mapa/aparelhos/{IP}", json={})).status_code == 401
    assert (await anon.put(f"/api/mks/{OUTRO}/mapa/rotulo-porta", json={"porta": "e", "rotulo": "x"})).status_code == 401


async def test_mk_inexistente_404(client):
    assert (await client.get(f"/api/mks/{OUTRO}/mapa")).status_code == 404
    assert (await client.put(f"/api/mks/{OUTRO}/mapa/aparelhos/{IP}", json={})).status_code == 404
    assert (await client.put(f"/api/mks/{OUTRO}/mapa/rotulo-porta", json={"porta": "e"})).status_code == 404


async def test_mapa_vazio_sem_inventario(client):
    id = await criar(client)
    body = (await client.get(f"/api/mks/{id}/mapa")).json()
    assert body == {"lido_em": None, "desatualizado": True, "mk_no_ar": False, "portas": []}


async def test_mapa_aparelho_offline(client, db, r):
    id = await criar(client)
    await store.salvar_inventario(db, id, doc("192.168.1.0/24", True), datetime.now(UTC))
    await _ap(db, id)
    await r.set(f"state:mk:{id}", json.dumps({"status": "no_ar", "portas_link": {"ether2": True}}))
    await r.set(f"state:ap:{id}", json.dumps({IP: {"online": False, "falhas": 2, "desde": "2026-01-01T00:00:00+00:00"}}))
    body = (await client.get(f"/api/mks/{id}/mapa")).json()
    assert body["mk_no_ar"] is True and body["desatualizado"] is False
    porta = body["portas"][0]
    assert porta["nome"] == "ether2" and porta["link"] == "up"
    assert porta["aparelhos"][0]["estado"] == "offline" and porta["problema"] is True
    vazio = (await client.get(f"/api/mks/{id}/mapa", params={"q": "zzz"})).json()
    assert vazio["portas"] == []
    assert (await client.get(f"/api/mks/{id}/mapa", params={"q": "x" * 101})).status_code == 422


async def test_put_aparelho_muda_nome_e_vigiado(client, db):
    id = await criar(client)
    await _ap(db, id, fabricante="Outro")
    url = f"/api/mks/{id}/mapa/aparelhos/{IP}"
    assert (await client.put(url, json={"apelido": "Portaria", "vigiar": True, "e_switch": True})).status_code == 204
    ap = (await client.get(f"/api/mks/{id}/mapa")).json()["portas"][0]["aparelhos"][0]
    assert ap["nome"] == "Portaria" and ap["vigiado"] is True and ap["e_switch"] is True
    # ausente não mexe; null limpa
    assert (await client.put(url, json={"vigiar": None})).status_code == 204
    ap = (await client.get(f"/api/mks/{id}/mapa")).json()["portas"][0]["aparelhos"][0]
    assert ap["nome"] == "Portaria" and ap["e_switch"] is True
    assert (await store.listar_ips(db, id))[0].get("vigiar_manual") is None
    assert (await client.put(url, json={"apelido": ""})).status_code == 204
    assert (await client.get(f"/api/mks/{id}/mapa")).json()["portas"][0]["aparelhos"][0]["apelido"] in (None, "")


async def test_put_aparelho_desconhecido_e_validacao(client, db):
    id = await criar(client)
    assert (await client.put(f"/api/mks/{id}/mapa/aparelhos/{IP}", json={"apelido": "x"})).status_code == 404
    await _ap(db, id)
    assert (await client.put(f"/api/mks/{id}/mapa/aparelhos/{IP}", json={"apelido": "x" * 61})).status_code == 422


async def test_rotulo_porta_e_validacao(client, db):
    id = await criar(client)
    await _ap(db, id)
    url = f"/api/mks/{id}/mapa/rotulo-porta"
    assert (await client.put(url, json={"porta": "ether2", "rotulo": "Bloco A"})).status_code == 204
    assert (await client.get(f"/api/mks/{id}/mapa")).json()["portas"][0]["rotulo"] == "Bloco A"
    assert (await client.put(url, json={"porta": "ether2", "rotulo": "x" * 41})).status_code == 422
    assert (await client.put(url, json={"porta": "ether2", "rotulo": None})).status_code == 204
    assert (await client.get(f"/api/mks/{id}/mapa")).json()["portas"][0]["rotulo"] == ""


async def test_rotulo_sobrevive_a_atualizar_inventario(client, db, monkeypatch):
    id = await criar(client)
    await _ap(db, id)
    await client.put(f"/api/mks/{id}/mapa/rotulo-porta", json={"porta": "ether2", "rotulo": "Bloco A"})
    monkeypatch.setattr(routeros, "fetch_inventario", lambda *a, **k: {
        "address": [{"address": "192.168.5.1/24", "interface": "bridge"}]})
    assert (await client.post(f"/api/mks/{id}/inventario/atualizar")).status_code == 200
    assert await store.rotulos_portas(db, id) == {"ether2": "Bloco A"}
    assert (await client.get(f"/api/mks/{id}/mapa")).json()["portas"][0]["rotulo"] == "Bloco A"


async def test_apagar_mk_apaga_rotulos(client, db):
    id = await criar(client)
    await client.put(f"/api/mks/{id}/mapa/rotulo-porta", json={"porta": "ether2", "rotulo": "A"})
    assert (await client.delete(f"/api/mks/{id}")).status_code == 204
    assert await store.rotulos_portas(db, id) == {}


async def test_mapa_switch_aninhado_e_dica(client, db):
    id = await criar(client)
    await _ap(db, id, "192.168.1.2", e_switch_manual=True)
    await _ap(db, id, "192.168.1.3", switch_ip="192.168.1.2", switch_porta="3")
    body = (await client.get(f"/api/mks/{id}/mapa")).json()
    sw = body["portas"][0]["aparelhos"][0]
    assert sw["gerenciavel"] is False and "SNMP" in sw["dica"]  # sem docs de switch: dica
    await store.salvar_switch(db, id, "192.168.1.2", {"gerenciavel": True, "portas": {"3": {"up": True}}})
    sw = next(a for a in (await client.get(f"/api/mks/{id}/mapa")).json()["portas"][0]["aparelhos"])
    assert sw["gerenciavel"] is True and "dica" not in sw
    assert sw["portas"][0]["nome"] == "3" and sw["portas"][0]["aparelhos"][0]["ip"] == "192.168.1.3"


async def test_esquecer_ip_apaga_switch(db):
    await _ap(db, "m1", "192.168.1.2")
    await store.salvar_switch(db, "m1", "192.168.1.2", {"gerenciavel": True})
    assert await store.esquecer_ip(db, "m1", "192.168.1.2")
    assert await store.listar_switches(db, "m1") == []
    await store.salvar_switch(db, "m1", "192.168.1.9", {"gerenciavel": True})
    assert not await store.esquecer_ip(db, "m1", "192.168.1.9")
