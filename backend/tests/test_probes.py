import asyncio

import httpx

from nodebeat import probes


def fake_exec(code, calls):
    async def exec_(*args, **kw):
        calls.append((args, kw))

        class P:
            async def wait(self):
                return code

        return P()

    return exec_


async def test_ping_true_on_exit_0(monkeypatch):
    calls = []
    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec(0, calls))
    assert await probes.ping("10.0.0.1") is True
    args, kw = calls[0]
    assert args == ("ping", "-n", "-c", "2", "-W", "1", "10.0.0.1")
    assert kw == {"stdout": asyncio.subprocess.DEVNULL, "stderr": asyncio.subprocess.DEVNULL}


async def test_ping_false_on_exit_1(monkeypatch):
    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec(1, []))
    assert await probes.ping("10.0.0.1") is False


async def test_ping_rejects_non_ip_without_spawning(monkeypatch):
    calls = []
    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec(0, calls))
    assert await probes.ping("-c") is False
    assert calls == []


async def test_ping_false_when_binary_missing(monkeypatch):
    async def boom(*a, **k):
        raise FileNotFoundError

    monkeypatch.setattr(asyncio, "create_subprocess_exec", boom)
    assert await probes.ping("10.0.0.1") is False


async def test_reference_ok_any_status():
    t = httpx.MockTransport(lambda r: httpx.Response(503))
    assert await probes.reference_ok("ref.example", transport=t) is True


async def test_reference_fail_on_connect_error():
    def h(r):
        raise httpx.ConnectError("x")

    assert await probes.reference_ok("ref.example", transport=httpx.MockTransport(h)) is False
