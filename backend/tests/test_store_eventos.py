from datetime import UTC, datetime, timedelta

import pytest
from mongomock_motor import AsyncMongoMockClient

from nodebeat import store


@pytest.fixture
def db():
    return AsyncMongoMockClient()["nodebeat"]


def ev(mk, t, tipo="login", msg="x"):
    return {"mk_id": mk, "recebido_em": t, "severidade": "info", "topicos": [], "tipo": tipo,
            "campos": {}, "mensagem": msg}


T0 = datetime(2026, 1, 1, tzinfo=UTC)
T1, T2 = T0 + timedelta(hours=1), T0 + timedelta(hours=2)


async def test_indices_criados(db):
    await store.garantir_indices_eventos(db, 30)
    info = await db.eventos.index_information()
    assert info["ttl_recebido_em"]["expireAfterSeconds"] == 30 * 86400


async def test_ttl_muda_com_dias(db):
    await store.garantir_indices_eventos(db, 30)
    await store.garantir_indices_eventos(db, 7)
    assert (await db.eventos.index_information())["ttl_recebido_em"]["expireAfterSeconds"] == 7 * 86400


async def test_listar_filtra_e_ordena(db):
    await store.inserir_eventos(db, [ev("mk1", T0), ev("mk1", T1, "config"), ev("mk1", T2), ev("mk2", T1)])
    async def horas(**kw):
        return [e["recebido_em"] for e in await store.listar_eventos(db, "mk1", **kw)]
    assert await horas() == [T2, T1, T0]
    assert await horas(tipos=["login"]) == [T2, T0]
    assert await horas(ate=T2) == [T1, T0]
    assert await horas(desde=T1) == [T2, T1]
    assert await horas(limite=1) == [T2]
    assert (await store.listar_eventos(db, "mk1"))[0]["recebido_em"].tzinfo is UTC
    assert "_id" not in (await store.listar_eventos(db, "mk1"))[0]


async def test_q_sem_diferenciar_maiuscula(db):
    await store.inserir_eventos(db, [ev("mk1", T0, msg="user admin logged in"), ev("mk1", T1, msg="outro")])
    achados = await store.listar_eventos(db, "mk1", q="ADMIN")
    assert [e["mensagem"] for e in achados] == ["user admin logged in"]


async def test_inserir_lista_vazia_e_ultimo_evento(db):
    await store.inserir_eventos(db, [])
    assert await store.ultimo_evento(db, "mk1") is None
    await store.inserir_eventos(db, [ev("mk1", T0), ev("mk1", T2)])
    assert await store.ultimo_evento(db, "mk1") == T2


async def test_apagar_eventos(db):
    await store.inserir_eventos(db, [ev("mk1", T0), ev("mk2", T0)])
    await store.apagar_eventos(db, "mk1")
    assert await store.listar_eventos(db, "mk1") == []
    assert len(await store.listar_eventos(db, "mk2")) == 1


async def test_listar_eventos_periodo(db):
    await store.inserir_eventos(db, [ev("a", T2), ev("b", T1), ev("a", T0 - timedelta(hours=1))])
    todos = await store.listar_eventos_periodo(db, T0)
    assert [(e["mk_id"], e["recebido_em"]) for e in todos] == [("b", T1), ("a", T2)]
    assert todos[0]["recebido_em"].tzinfo is not None
    so_a = await store.listar_eventos_periodo(db, T0, mk_id="a")
    assert [e["mk_id"] for e in so_a] == ["a"]


async def test_listar_eventos_periodo_sem_filtro_ignora_equipamentos(db):
    await store.inserir_eventos(db, [ev("a", T1), ev("eq:x", T1), ev("eq:x", T2)])
    assert [e["mk_id"] for e in await store.listar_eventos_periodo(db, T0)] == ["a"]
    assert len(await store.listar_eventos_periodo(db, T0, mk_id="eq:x")) == 2
