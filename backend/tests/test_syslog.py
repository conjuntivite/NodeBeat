import asyncio
import socket
from collections import Counter
from unittest.mock import Mock

import pytest
from mongomock_motor import AsyncMongoMockClient

from nodebeat import store, syslog

MSG = b"system,info,account user admin logged in from 10.0.0.1 via winbox"


@pytest.fixture
def db():
    return AsyncMongoMockClient()["nodebeat"]


async def montar(mapa, **kw):
    fila = kw.pop("fila", asyncio.Queue())
    pedir = Mock()
    rec = syslog.Receptor(mapa, fila, pedir, **kw)
    transp, _ = await asyncio.get_running_loop().create_datagram_endpoint(
        lambda: rec, local_addr=("127.0.0.1", 0))
    return rec, fila, pedir, transp


async def enviar(transp, *dados):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for d in dados:
        s.sendto(d, transp.get_extra_info("sockname"))
    s.close()
    await asyncio.sleep(0.05)


async def test_ip_cadastrado_vai_para_fila():
    rec, fila, _, t = await montar({"127.0.0.1": "mk1"})
    await enviar(t, MSG)
    ev = fila.get_nowait()
    assert ev["mk_id"] == "mk1" and ev["tipo"] == "login"
    t.close()


async def test_ip_desconhecido_descartado_e_pede_recarga():
    rec, fila, pedir, t = await montar({})
    await enviar(t, MSG)
    assert fila.empty() and rec.descartes[("desconhecido", "127.0.0.1")] == 1
    pedir.assert_called()
    t.close()


async def test_ip_ambiguo_descartado():
    rec, fila, _, t = await montar({"127.0.0.1": None})
    await enviar(t, MSG)
    assert fila.empty() and rec.descartes[("ambiguo", "127.0.0.1")] == 1
    t.close()


async def test_limite_por_mk():
    agora = [100.0]
    rec, fila, _, t = await montar({"127.0.0.1": "mk1"}, limite_por_s=3, relogio=lambda: agora[0])
    await enviar(t, *[MSG] * 5)
    assert fila.qsize() == 3 and rec.descartes[("limite", "mk1")] == 2
    agora[0] += 1
    await enviar(t, MSG)
    assert fila.qsize() == 4
    t.close()


async def test_ruido_nao_entra():
    rec, fila, _, t = await montar({"127.0.0.1": "mk1"}, ip_origem="127.0.0.1")
    await enviar(t, b"system,info,account user monitor logged in from 127.0.0.1 via api",
                 b"ipsec,debug,packet x")
    assert fila.empty() and not rec.descartes
    t.close()


async def test_fila_cheia():
    rec, fila, _, t = await montar({"127.0.0.1": "mk1"}, fila=asyncio.Queue(maxsize=1))
    await enviar(t, MSG, MSG)
    assert rec.descartes[("fila_cheia", "")] == 1
    t.close()


def test_datagrama_vazio_ignorado():
    fila = asyncio.Queue()
    rec = syslog.Receptor({"127.0.0.1": "mk1"}, fila, Mock())
    rec.datagram_received(b"", ("127.0.0.1", 1))
    assert fila.empty() and rec.descartes == Counter()


async def test_mapa_ips_ambiguo(db):
    await db.mks.insert_many([{"nome": "a", "ip_tunel": "10.0.0.1"}, {"nome": "b", "ip_tunel": "10.0.0.1"}])
    id3 = await store.insert_mk(db, {"nome": "c", "ip_tunel": "10.0.0.2"})
    assert await syslog.mapa_ips(db) == {"10.0.0.1": None, "10.0.0.2": id3}


async def test_mapa_reflete_alteracao(db):
    id1 = await store.insert_mk(db, {"nome": "a", "ip_tunel": "10.0.0.1"})
    await store.update_mk(db, id1, {"ip_tunel": "10.0.0.9"})
    assert await syslog.mapa_ips(db) == {"10.0.0.9": id1}


def doc(i):
    return {"mk_id": "m", "mensagem": str(i)}


async def test_gravador_grava_em_lote(db):
    fila = asyncio.Queue()
    for i in range(3):
        fila.put_nowait(doc(i))
    with pytest.raises(TimeoutError):
        await asyncio.wait_for(syslog.gravar(db, fila, intervalo_s=0.05), 0.2)
    assert await db.eventos.count_documents({}) == 3


async def test_gravador_sobrevive_erro_do_mongo(db, monkeypatch):
    original = store.inserir_eventos
    n = []

    async def falha(db, docs):
        n.append(1)
        if len(n) == 1:
            raise RuntimeError("x")
        await original(db, docs)

    monkeypatch.setattr(store, "inserir_eventos", falha)
    fila = asyncio.Queue()
    fila.put_nowait(doc(1))
    task = asyncio.create_task(syslog.gravar(db, fila, intervalo_s=0.05))
    await asyncio.sleep(0.2)
    fila.put_nowait(doc(2))
    await asyncio.sleep(0.2)
    task.cancel()
    assert await db.eventos.count_documents({}) == 1


def test_desconhecidos_com_teto_por_minuto():
    rec = syslog.Receptor({}, asyncio.Queue(), Mock())
    for i in range(syslog.MAX_DESCONHECIDOS + 10):
        rec.datagram_received(MSG, (f"192.0.2.{i}", 1))
    rec.datagram_received(MSG, ("192.0.2.0", 1))  # já contado: continua na própria chave
    desc = [k for k in rec.descartes if k[0] == "desconhecido"]
    assert len(desc) == syslog.MAX_DESCONHECIDOS + 1
    assert rec.descartes["desconhecido", "outros"] == 10
    assert rec.descartes["desconhecido", "192.0.2.0"] == 2
