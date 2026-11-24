import json
import re
from datetime import UTC, datetime, timedelta

from nodebeat import store
from tests.test_api_equipamentos import _novo
from tests.test_api_inventario import anon, client, db, r  # noqa: F401  (fixtures)
from tests.test_api_mks import criar

PORTA = {"poe_w": 4.5, "poe_classe": 2, "rx_mbps": 1.0, "tx_mbps": 2.0, "erros": 0, "descartes": 0, "stp": "forwarding",
         "quedas_link": 0, "uplink": False, "aparelhos": 1, "clientes": []}


async def _unifi(r, id, portas):
    await r.set(f"unifi:eq:{id}", json.dumps({"lido_em": "2026-11-24T10:00:00+00:00", "sistema": {"modelo": "USW"},
                                              "portas": portas, "api_key": "nao-vazar"}))


async def _ev(db, id, tipo, minutos, porta=None):
    await db.eventos.insert_one({"mk_id": f"eq:{id}", "origem": "unifi", "unifi_id": f"{tipo}{minutos}",
                                 "recebido_em": datetime.now(UTC) - timedelta(minutes=minutos), "tipo": tipo,
                                 "severidade": "info", "campos": {"porta": porta}, "mensagem": f"m{minutos}"})


async def test_unifi_null_sem_chave(client):
    id = await _novo(client)
    assert (await client.get(f"/api/equipamentos/{id}")).json()["unifi"] is None


async def test_mapeia_porta_snmp_e_sobra(client, r):
    id = await _novo(client)
    await r.set(f"state:eq:{id}", json.dumps({"status": "no_ar", "portas": {"0/12": {"up": True}}}))
    await _unifi(r, id, {"12": PORTA, "99": PORTA})
    u = (await client.get(f"/api/equipamentos/{id}")).json()["unifi"]
    assert set(u["portas"]) == {"0/12", "Porta 99"} and u["sistema"] == {"modelo": "USW"}
    assert "api_key" not in json.dumps(u) and "X-API-Key" not in json.dumps(u)


async def test_eventos_switches(client, db):
    id = await _novo(client)
    await _ev(db, id, "cliente_conectou", 5, "12")
    await _ev(db, id, "inalcancavel", 1)
    await _ev(db, id, "poe_religado", 10)
    await _ev(db, id, "cliente_conectou", 60 * 30)  # fora de 24h
    await _ev(db, "removido", "mudanca_admin", 2)
    body = (await client.get("/api/eventos/switches?periodo=24h")).json()
    assert body["contagens"] == {"clientes": 1, "alertas": 1, "poe": 1, "mudancas": 1}
    assert [e["mensagem"] for e in body["eventos"]] == ["m1", "m2", "m5", "m10"]
    e = body["eventos"][2]
    assert (e["switch_id"], e["switch_nome"], e["porta"], e["grupo"]) == (id, "SW1", "12", "clientes")
    assert body["eventos"][1]["switch_nome"] == "Switch removido"
    assert "api_key" not in json.dumps(body)
    assert len((await client.get("/api/eventos/switches?periodo=30d")).json()["eventos"]) == 5
    assert re.match(r"\d{4}-", e["quando"])


async def test_periodo_invalido(client):
    assert (await client.get("/api/eventos/switches?periodo=2h")).status_code == 422


async def test_painel_nao_conta_eventos_unifi(client, db):
    mk = await criar(client)
    id = await _novo(client)
    falha = {"recebido_em": datetime.now(UTC) - timedelta(minutes=10), "severidade": "crit", "tipo": "login_falha",
             "topicos": ["system", "error", "critical"], "campos": {},
             "mensagem": "login failure for user root from 203.0.113.9 via ssh"}
    await store.inserir_eventos(db, [falha | {"mk_id": mk}, falha | {"mk_id": f"eq:{id}", "origem": "unifi"}])
    body = (await client.get("/api/eventos/painel")).json()
    assert body["resumo"]["acesso"] == 1
    # o painel também ignora MKs desconhecidas; a exclusão em si é do store
    evs = await store.listar_eventos_periodo(db, datetime.now(UTC) - timedelta(days=1))
    assert [e["mk_id"] for e in evs] == [mk]


async def test_eventos_switches_contagem_total_e_lista_limitada(client, db):
    id = await _novo(client)
    docs = [{"mk_id": f"eq:{id}", "origem": "unifi", "unifi_id": f"u{i}", "recebido_em": datetime.now(UTC) - timedelta(minutes=i),
             "tipo": "cliente_conectou", "severidade": "info", "campos": {}, "mensagem": f"m{i}"} for i in range(130)]
    docs.append({**docs[0], "mk_id": "outra-mk", "unifi_id": "x"})  # fora do prefixo eq:
    await db.eventos.insert_many(docs)
    body = (await client.get("/api/eventos/switches?periodo=24h")).json()
    assert body["contagens"]["clientes"] == 130 and len(body["eventos"]) == 100
