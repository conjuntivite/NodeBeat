import asyncio
import time

import pytest

from nodebeat import snmp

COMMUNITY = "segredo-teste"

# Subárvore pequena (dot1dTpFdbPort) + um vizinho fora dela, para o walk parar na fronteira.
MIB = {
    "1.3.6.1.2.1.1.1.0": b"Switch de teste",
    "1.3.6.1.2.1.1.3.0": ("ticks", 12345),
    "1.3.6.1.2.1.17.1.1.0": b"\x44\x19\xb6\x00\x00\x01",
    "1.3.6.1.2.1.17.4.3.1.2.68.25.182.0.0.1": 1,
    "1.3.6.1.2.1.17.4.3.1.2.68.25.182.0.0.2": 2,
    "1.3.6.1.2.1.17.4.3.1.2.68.25.182.0.0.10": 3,
    "1.3.6.1.2.1.17.4.3.1.3.68.25.182.0.0.1": 3,
}


def _chave(oid):
    return tuple(int(x) for x in oid.split("."))


def _seguinte(oid):
    for o in sorted(MIB, key=_chave):
        if _chave(o) > _chave(oid):
            return o
    return None


def _valor(v):
    if isinstance(v, tuple):
        return snmp._tlv(0x43, snmp._int(v[1]))
    if isinstance(v, int):
        return snmp._tlv(0x02, snmp._int(v))
    return snmp._tlv(0x04, v)


class Agente(asyncio.DatagramProtocol):
    """Respondedor SNMPv2c falso: responde só à community certa; outra = silêncio."""

    def __init__(self, community):
        self.community = community

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        _, msg, _ = snmp._ler(data, 0)
        versao, community, pdu = snmp._filhos(msg)
        if community[1] != self.community.encode():
            return
        tag, corpo = pdu
        reqid, a, b, vbs = snmp._filhos(corpo)
        oids = [snmp._oid_str(snmp._filhos(vb[1])[0][1]) for vb in snmp._filhos(vbs[1])]
        resp = []
        if tag == 0xA0:  # GET
            for o in oids:
                resp.append((o, _valor(MIB[o]) if o in MIB else snmp._tlv(0x81, b"")))
        elif tag == 0xA5:  # GETBULK, non-repeaters 0
            o = oids[0]
            for _ in range(snmp._int_de(b[1])):
                o2 = _seguinte(o)
                if o2 is None:
                    resp.append((o, snmp._tlv(0x82, b"")))
                    break
                resp.append((o2, _valor(MIB[o2])))
                o = o2
        lista = b"".join(
            snmp._tlv(0x30, snmp._tlv(0x06, snmp._oid_ber(o)) + v) for o, v in resp
        )
        corpo_resp = (
            snmp._tlv(0x02, reqid[1]) + snmp._tlv(0x02, b"\x00") + snmp._tlv(0x02, b"\x00")
            + snmp._tlv(0x30, lista)
        )
        out = snmp._tlv(0x30, snmp._tlv(0x02, b"\x01") + snmp._tlv(0x04, community[1])
                        + snmp._tlv(0xA2, corpo_resp))
        self.transport.sendto(out, addr)


@pytest.fixture
async def agente():
    loop = asyncio.get_running_loop()
    transport, _ = await loop.create_datagram_endpoint(
        lambda: Agente(COMMUNITY), local_addr=("127.0.0.1", 0)
    )
    yield transport.get_extra_info("sockname")[1]
    transport.close()


@pytest.fixture
async def mudo():
    """Porta UDP aberta que nunca responde (host sem SNMP / community recusada)."""
    loop = asyncio.get_running_loop()
    transport, _ = await loop.create_datagram_endpoint(
        asyncio.DatagramProtocol, local_addr=("127.0.0.1", 0)
    )
    yield transport.get_extra_info("sockname")[1]
    transport.close()


def test_get_codifica_igual_ao_ber_de_referencia():
    # GET v2c, community "public", request-id 1, sysDescr.0 (gerado pelo encoder do pysnmp 7.1.33).
    esperado = bytes.fromhex(
        "302602010104067075626c6963a019020101020100020100300e300c06082b060102010101000500"
    )
    assert snmp._pedido(0xA0, "public", 1, "1.3.6.1.2.1.1.1.0") == esperado


async def test_get_devolve_valor(agente):
    assert await snmp.get("127.0.0.1", COMMUNITY, "1.3.6.1.2.1.1.1.0", port=agente) == b"Switch de teste"
    assert await snmp.get("127.0.0.1", COMMUNITY, "1.3.6.1.2.1.1.3.0", port=agente) == 12345
    # OctetString fica bytes (MAC do dot1dBaseBridgeAddress).
    assert await snmp.get("127.0.0.1", COMMUNITY, "1.3.6.1.2.1.17.1.1.0", port=agente) == bytes.fromhex("4419b6000001")


async def test_get_inexistente_devolve_none(agente):
    assert await snmp.get("127.0.0.1", COMMUNITY, "1.3.6.1.2.1.1.9.0", port=agente) is None


async def test_walk_traz_subarvore_em_ordem_e_para_na_fronteira(agente, monkeypatch):
    monkeypatch.setattr(snmp, "_MAX_REPETICOES", 2)  # força mais de um GETBULK
    linhas = await snmp.walk("127.0.0.1", COMMUNITY, "1.3.6.1.2.1.17.4.3.1.2", port=agente)
    assert linhas == [
        ("1.3.6.1.2.1.17.4.3.1.2.68.25.182.0.0.1", 1),
        ("1.3.6.1.2.1.17.4.3.1.2.68.25.182.0.0.2", 2),
        ("1.3.6.1.2.1.17.4.3.1.2.68.25.182.0.0.10", 3),
    ]


async def test_walk_ate_o_fim_da_mib(agente):
    linhas = await snmp.walk("127.0.0.1", COMMUNITY, "1.3.6.1.2.1.17.4.3.1.3", port=agente)
    assert linhas == [("1.3.6.1.2.1.17.4.3.1.3.68.25.182.0.0.1", 3)]


async def test_sem_resposta_levanta_dentro_do_timeout(mudo):
    t = time.monotonic()
    with pytest.raises(snmp.SnmpErro) as e:
        await snmp.get("127.0.0.1", COMMUNITY, "1.3.6.1.2.1.1.1.0", timeout=0.3, port=mudo)
    assert time.monotonic() - t < 1.0
    assert COMMUNITY not in str(e.value)


async def test_community_errada_levanta_sem_vazar(agente):
    errada = "community-errada"
    with pytest.raises(snmp.SnmpErro) as e:
        await snmp.get("127.0.0.1", errada, "1.3.6.1.2.1.1.1.0", timeout=0.3, port=agente)
    assert errada not in str(e.value)
    with pytest.raises(snmp.SnmpErro) as e:
        await snmp.walk("127.0.0.1", errada, "1.3.6.1.2.1.17", timeout=0.3, port=agente)
    assert errada not in str(e.value)
