"""Cliente SNMP v2c mínimo, somente leitura (GET e GETBULK), em asyncio UDP.

Só stdlib: um codificador/decodificador BER do pouco que o SNMP v2c usa. Sem SET.

Convenções dos valores devolvidos:
- OIDs em notação pontilhada sem ponto inicial ("1.3.6.1.2.1.1.1.0").
- INTEGER -> int; Counter32/Gauge32/TimeTicks/Counter64 -> int (sem sinal);
  IpAddress -> str "a.b.c.d"; OBJECT IDENTIFIER -> str; NULL -> None.
- OCTET STRING -> **sempre bytes**: texto (sysDescr, ifName) e MAC
  (dot1dBaseBridgeAddress) chegam iguais; quem chama decodifica
  (`v.decode(errors="replace")` ou `v.hex(":")`).
- noSuchObject/noSuchInstance -> None.

Segurança: a community é segredo. Nunca vai para log nem para mensagem de `SnmpErro`.
"""

import asyncio
import contextlib
import secrets

_GET, _RESPOSTA, _GETBULK = 0xA0, 0xA2, 0xA5
_MAX_REPETICOES = 20
_MAX_LINHAS = 20000  # trava contra agente que nunca termina a subárvore
_WALK_TOTAL = 60.0  # teto de segundos do walk inteiro (o `timeout` vale por pedido)
_FIM = object()  # endOfMibView


class SnmpErro(Exception):
    """Sem resposta (timeout, host sem SNMP, community recusada) ou erro do agente."""


# ---- BER ----

def _tlv(tag: int, conteudo: bytes) -> bytes:
    n = len(conteudo)
    if n < 0x80:
        tam = bytes([n])
    else:
        b = n.to_bytes((n.bit_length() + 7) // 8, "big")
        tam = bytes([0x80 | len(b)]) + b
    return bytes([tag]) + tam + conteudo


def _int(n: int) -> bytes:
    return n.to_bytes((n.bit_length() + 8) // 8, "big", signed=True)


def _int_de(b: bytes) -> int:
    return int.from_bytes(b, "big", signed=True)


def _oid_ber(oid: str) -> bytes:
    arcos = [int(x) for x in oid.split(".")]
    out = bytearray()
    for arco in [40 * arcos[0] + arcos[1], *arcos[2:]]:
        grupo = [arco & 0x7F]
        arco >>= 7
        while arco:
            grupo.append(0x80 | (arco & 0x7F))
            arco >>= 7
        out += bytes(reversed(grupo))
    return bytes(out)


def _oid_str(b: bytes) -> str:
    arcos, v = [], 0
    for byte in b:
        v = (v << 7) | (byte & 0x7F)
        if not byte & 0x80:
            arcos.append(v)
            v = 0
    primeiro = arcos[0]
    x = min(primeiro // 40, 2)
    return ".".join(map(str, [x, primeiro - 40 * x, *arcos[1:]]))


def _ler(data: bytes, i: int) -> tuple[int, bytes, int]:
    """Lê um TLV a partir de `i`: (tag, conteúdo, posição seguinte)."""
    tag, n = data[i], data[i + 1]
    i += 2
    if n & 0x80:
        k = n & 0x7F
        n = int.from_bytes(data[i:i + k], "big")
        i += k
    if i + n > len(data):
        raise ValueError("TLV truncado")
    return tag, data[i:i + n], i + n


def _filhos(conteudo: bytes) -> list[tuple[int, bytes]]:
    out, i = [], 0
    while i < len(conteudo):
        tag, v, i = _ler(conteudo, i)
        out.append((tag, v))
    return out


def _valor(tag: int, v: bytes) -> object:
    if tag == 0x02:
        return _int_de(v)
    if tag == 0x06:
        return _oid_str(v)
    if tag == 0x40:
        return ".".join(map(str, v))
    if tag in (0x41, 0x42, 0x43, 0x46, 0x47):
        return int.from_bytes(v, "big")
    if tag == 0x82:
        return _FIM
    if tag in (0x05, 0x80, 0x81):
        return None
    return v  # OCTET STRING (0x04), Opaque e o que mais vier: bytes crus


def _pedido(tipo: int, community: str, reqid: int, oid: str, a: int = 0, b: int = 0) -> bytes:
    vb = _tlv(0x30, _tlv(0x30, _tlv(0x06, _oid_ber(oid)) + _tlv(0x05, b"")))
    pdu = _tlv(tipo, _tlv(0x02, _int(reqid)) + _tlv(0x02, _int(a)) + _tlv(0x02, _int(b)) + vb)
    return _tlv(0x30, _tlv(0x02, b"\x01") + _tlv(0x04, community.encode()) + pdu)


def _resposta(data: bytes) -> tuple[int, int, list[tuple[str, object]]]:
    _, msg, _ = _ler(data, 0)
    _, _, (tag, pdu) = _filhos(msg)
    if tag != _RESPOSTA:
        raise ValueError("não é Response")
    reqid, status, _, vbs = _filhos(pdu)
    linhas = []
    for _, vb in _filhos(vbs[1]):
        (_, o), (t, v) = _filhos(vb)
        linhas.append((_oid_str(o), _valor(t, v)))
    return _int_de(reqid[1]), _int_de(status[1]), linhas


# ---- transporte ----

class _Udp(asyncio.DatagramProtocol):
    def __init__(self):
        self.fila: asyncio.Queue = asyncio.Queue()

    def datagram_received(self, data, addr):
        self.fila.put_nowait(data)

    def error_received(self, exc):  # ex.: ICMP porta inalcançável
        self.fila.put_nowait(exc)


class _Sessao:
    def __init__(self, ip, community, timeout, transporte, proto):
        self.ip, self.community, self.timeout = ip, community, timeout
        self.transporte, self.proto = transporte, proto

    async def troca(self, tipo: int, oid: str, a: int = 0, b: int = 0) -> list[tuple[str, object]]:
        # ponytail: sem retransmissão; um pacote perdido falha a leitura e o próximo ciclo tenta de novo.
        reqid = secrets.randbelow(2**31)
        self.transporte.sendto(_pedido(tipo, self.community, reqid, oid, a, b))
        async with asyncio.timeout(self.timeout):
            while True:
                item = await self.proto.fila.get()
                if isinstance(item, Exception):
                    raise SnmpErro(f"sem resposta SNMP de {self.ip} (porta inalcançável)")
                try:
                    rid, status, linhas = _resposta(item)
                except (ValueError, IndexError):
                    continue  # lixo ou resposta de outro pedido
                if rid != reqid:
                    continue
                if status:
                    raise SnmpErro(f"{self.ip} respondeu erro SNMP {status} para {oid}")
                return linhas


@contextlib.asynccontextmanager
async def _sessao(ip: str, community: str, timeout: float, port: int):
    try:
        transporte, proto = await asyncio.get_running_loop().create_datagram_endpoint(
            _Udp, remote_addr=(ip, port)
        )
    except OSError as e:
        raise SnmpErro(f"não abriu UDP para {ip}:{port}: {e.strerror or type(e).__name__}") from None
    try:
        yield _Sessao(ip, community, timeout, transporte, proto)
    except TimeoutError:
        raise SnmpErro(
            f"sem resposta SNMP de {ip}:{port} (timeout, host sem SNMP ou community recusada)"
        ) from None
    finally:
        transporte.close()


def _chave(oid: str) -> tuple[int, ...]:
    return tuple(int(x) for x in oid.split("."))


async def get(ip: str, community: str, oid: str, timeout: float = 2.0, port: int = 161) -> object | None:
    """GET de um OID. Devolve o valor convertido (ver docstring do módulo) ou None se não existir."""
    async with _sessao(ip, community, timeout, port) as s:
        linhas = await s.troca(_GET, oid)
    v = linhas[0][1] if linhas else None
    return None if v is _FIM else v


async def walk(ip: str, community: str, oid: str, timeout: float = 2.0, port: int = 161) -> list[tuple[str, object]]:
    """Percorre a subárvore de `oid` com GETBULK. Devolve [(oid, valor)] em ordem.

    Para ao sair da subárvore, no endOfMibView, se o agente voltar OID fora de ordem
    ou em `_MAX_LINHAS` linhas. `timeout` vale por pedido; o walk todo tem teto `_WALK_TOTAL`.
    """
    prefixo = _chave(oid)
    linhas: list[tuple[str, object]] = []
    atual = oid
    async with _sessao(ip, community, timeout, port) as s:
        async with asyncio.timeout(_WALK_TOTAL):
            while len(linhas) < _MAX_LINHAS:
                lote = await s.troca(_GETBULK, atual, 0, _MAX_REPETICOES)
                if not lote:
                    break
                for o, v in lote:
                    k = _chave(o)
                    if v is _FIM or k[:len(prefixo)] != prefixo or k <= _chave(atual):
                        return linhas[:_MAX_LINHAS]
                    linhas.append((o, v))
                    atual = o
    return linhas[:_MAX_LINHAS]
