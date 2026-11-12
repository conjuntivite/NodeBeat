from datetime import datetime, timedelta

import fakeredis.aioredis
import pytest

from nodebeat.history import delete_mk, history, load_states, record, save_state
from nodebeat.rules import SP, Event, MkRef

T0 = datetime(2026, 11, 1, 12, 0, tzinfo=SP)
MK = MkRef("1", "Alfa")


@pytest.fixture
def r():
    return fakeredis.aioredis.FakeRedis(decode_responses=True)


def ev(inicio, fim=None, mk=MK, evento="queda"):
    return Event(evento, "offline", mk, "x", inicio, fim, None)


async def test_record_and_read_history(r):
    a, b = ev(T0), ev(T0 + timedelta(hours=1), T0 + timedelta(hours=2), evento="retorno")
    await record(r, a)
    await record(r, b)
    got = await history(r, "1", now=(T0 + timedelta(hours=3)).timestamp())
    assert got == [b.to_payload(), a.to_payload()]


async def test_history_prunes_older_than_90_days(r):
    old = ev(T0)
    new = ev(T0 + timedelta(days=100))
    await record(r, old)
    await record(r, new)
    assert await r.zcard("hist:1") == 1
    got = await history(r, "1", now=(T0 + timedelta(days=100)).timestamp())
    assert got == [new.to_payload()]
    assert 0 < await r.ttl("hist:1") <= 90 * 86400


async def test_history_filters_by_days_window(r):
    await record(r, ev(T0))
    now = (T0 + timedelta(days=10)).timestamp()
    assert await history(r, "1", days=5, now=now) == []
    assert len(await history(r, "1", days=30, now=now)) == 1


async def test_score_uses_fim_when_present(r):
    fim = T0 + timedelta(hours=2)
    await record(r, ev(T0, fim, evento="encerrado"))
    [(_, score)] = await r.zrange("hist:1", 0, -1, withscores=True)
    assert score == fim.timestamp()


async def test_sede_key(r):
    e = ev(T0, mk=None)
    await record(r, e)
    assert await history(r, "sede", now=T0.timestamp()) == [e.to_payload()]


async def test_state_roundtrip_and_delete(r):
    await save_state(r, "1", {"nome": "Alfa", "state": "no_ar"})
    await save_state(r, "2", {"nome": "Beta"})
    assert await load_states(r) == {"1": {"nome": "Alfa", "state": "no_ar"}, "2": {"nome": "Beta"}}
    await record(r, ev(T0))
    await delete_mk(r, "1")
    assert await load_states(r) == {"2": {"nome": "Beta"}}
    assert await r.exists("hist:1") == 0
