import json

import fakeredis.aioredis
import httpx
import pytest

from nodebeat.webhook import deliver_once, enqueue, pending_count, run_sender

URL = "http://hook.test/x"


@pytest.fixture
def r():
    return fakeredis.aioredis.FakeRedis(decode_responses=True)


def client(handler):
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


class Stop(Exception):
    pass


def fake_sleep(delays, n):
    async def sleep(d):
        delays.append(d)
        if len(delays) >= n:
            raise Stop
    return sleep


async def test_enqueue_preserves_order(r):
    for i in range(3):
        await enqueue(r, {"i": i})
    assert await pending_count(r) == 3
    assert [json.loads(x)["i"] for x in await r.lrange("queue:webhook", 0, -1)] == [0, 1, 2]


async def test_deliver_sends_bearer_token(r):
    seen = []

    def h(req):
        seen.append((req.headers.get("authorization"), json.loads(req.content)))
        return httpx.Response(204)

    await enqueue(r, {"a": "ç"})
    assert await deliver_once(r, client(h), URL, "abc") is True
    assert seen == [("Bearer abc", {"a": "ç"})]
    assert await pending_count(r) == 0


async def test_no_auth_header_without_token(r):
    seen = []

    def h(req):
        seen.append(req.headers.get("authorization"))
        return httpx.Response(200)

    await enqueue(r, {})
    await deliver_once(r, client(h), URL, None)
    assert seen == [None]


async def test_failed_post_keeps_event_at_head(r):
    codes = iter([500, 200])
    await enqueue(r, {"a": 1})
    c = client(lambda req: httpx.Response(next(codes)))
    assert await deliver_once(r, c, URL, None) is False
    assert await pending_count(r) == 1
    assert await deliver_once(r, c, URL, None) is True
    assert await pending_count(r) == 0


async def test_4xx_and_network_error_keep_head(r):
    await enqueue(r, {"a": 1})
    assert await deliver_once(r, client(lambda q: httpx.Response(400)), URL, None) is False

    def boom(req):
        raise httpx.ConnectError("down")

    assert await deliver_once(r, client(boom), URL, None) is False
    assert await pending_count(r) == 1


async def test_empty_queue_does_not_post(r):
    def h(req):
        raise AssertionError("no POST expected")

    assert await deliver_once(r, client(h), URL, None) is True


async def test_backoff_caps_at_300(r):
    await enqueue(r, {"a": 1})
    delays = []
    with pytest.raises(Stop):
        await run_sender(r, client(lambda q: httpx.Response(500)), URL, None,
                         sleep=fake_sleep(delays, 8))
    assert delays == [5, 10, 20, 40, 80, 160, 300, 300]


async def test_backoff_resets_after_success(r):
    await enqueue(r, {"a": 1})
    codes = iter([500, 500, 200, 500])
    delays = []

    async def sleep(d):
        delays.append(d)
        if len(delays) == 3:  # após o sucesso, fila vazia -> poll; reenfileira e falha
            await enqueue(r, {"b": 2})
        if len(delays) >= 4:
            raise Stop

    with pytest.raises(Stop):
        await run_sender(r, client(lambda q: httpx.Response(next(codes))), URL, None, sleep=sleep)
    assert delays == [5, 10, 5, 5]


async def test_sender_drains_without_sleeping(r):
    for i in range(3):
        await enqueue(r, {"i": i})
    got = []

    def h(req):
        got.append(json.loads(req.content)["i"])
        return httpx.Response(200)

    delays = []
    with pytest.raises(Stop):
        await run_sender(r, client(h), URL, None, sleep=fake_sleep(delays, 1))
    assert got == [0, 1, 2]
    assert delays == [5]
