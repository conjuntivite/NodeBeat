import fakeredis
import pytest
from mongomock_motor import AsyncMongoMockClient

from nodebeat import history, store


@pytest.fixture
def db():
    return AsyncMongoMockClient()["nodebeat"]


@pytest.fixture
def r():
    return fakeredis.FakeAsyncRedis(decode_responses=True)


async def test_upsert_descoberto_e_idempotente_e_preserva_nome(db):
    id1 = await store.upsert_descoberto(db, "switch", "mk1", "192.0.2.10", "Switch X")
    id2 = await store.upsert_descoberto(db, "switch", "mk1", "192.0.2.10", "Switch X")
    assert id1 == id2
    assert await store.atualizar_equipamento(db, id1, {"nome": "Garagem"})
    id3 = await store.upsert_descoberto(db, "switch", "mk1", "192.0.2.10", "Outro nome")
    assert id3 == id1
    eq = await store.get_equipamento(db, id1)
    assert eq["nome"] == "Garagem" and eq["origem"] == "descoberto" and eq["local"] == "mk1"
    assert eq["criado_em"] is not None and eq["id"] == id1
    assert len(await store.listar_equipamentos(db)) == 1


async def test_listar_por_tipo(db):
    await store.inserir_equipamento(db, {"tipo": "switch", "nome": "S", "ip": "10.0.0.1",
                                         "local": "sede", "origem": "manual"})
    await store.inserir_equipamento(db, {"tipo": "camera", "nome": "C", "ip": "10.0.0.2",
                                         "local": "sede", "origem": "manual"})
    assert [e["nome"] for e in await store.listar_equipamentos(db, "switch")] == ["S"]
    assert len(await store.listar_equipamentos(db)) == 2
    assert await store.listar_equipamentos(db, "roteador") == []


async def test_get_apagar_e_id_invalido(db):
    id = await store.inserir_equipamento(db, {"tipo": "switch", "nome": "S", "ip": "10.0.0.1",
                                              "local": "sede", "origem": "manual"})
    assert (await store.get_equipamento(db, id))["nome"] == "S"
    assert await store.apagar_equipamento(db, id) is True
    assert await store.get_equipamento(db, id) is None
    assert await store.get_equipamento(db, "x") is None
    assert await store.apagar_equipamento(db, "x") is False
    assert await store.atualizar_equipamento(db, "x", {"nome": "y"}) is False


async def test_estado_eq_salva_carrega_apaga(r):
    await history.save_eq_state(r, "e1", {"status": "no_ar", "portas": {}})
    await history.save_eq_state(r, "e2", {"status": "offline"})
    await history.save_state(r, "mk1", {"status": "no_ar"})  # não entra em state:eq
    assert await history.load_eq_states(r) == {"e1": {"status": "no_ar", "portas": {}},
                                               "e2": {"status": "offline"}}
    await r.zadd("hist:eq:e1", {"x": 1})
    await history.delete_eq(r, "e1")
    assert await history.load_eq_states(r) == {"e2": {"status": "offline"}}
    assert await r.exists("hist:eq:e1", "state:eq:e1") == 0
