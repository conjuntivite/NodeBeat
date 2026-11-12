"""Cliente RouterOS (API-SSL, somente leitura) com certificado fixado por SHA-256."""
from __future__ import annotations

import hashlib
import ssl
from dataclasses import dataclass

import librouteros
from librouteros.exceptions import LibRouterosError, TrapError


@dataclass(frozen=True)
class Snapshot:
    version: str
    cpu: float
    mem: float
    uptime: str
    ifaces: dict[str, bool]  # TODAS as interfaces da MK


class RouterOsError(Exception):
    def __init__(self, detalhe: str):
        super().__init__(detalhe)
        self.detalhe = detalhe


class CertMismatch(RouterOsError):
    def __init__(self):
        super().__init__("certificado mudou")


def pinned_wrap(ctx: ssl.SSLContext, sock, expected: str | None, seen: list[str]) -> ssl.SSLSocket:
    """Handshake + SHA-256 do certificado em `seen`; fecha o socket se falhar ou não bater com `expected`."""
    try:
        wrapped = ctx.wrap_socket(sock)
    except BaseException:
        sock.close()
        raise
    sha = hashlib.sha256(wrapped.getpeercert(binary_form=True)).hexdigest()
    seen.append(sha)
    if expected is not None and sha != expected:
        wrapped.close()
        raise CertMismatch()
    return wrapped


def _login(api, username: str, password: str) -> None:
    """Login plain (>= 6.43). Resposta com `ret` = desafio do login antigo (< 6.43)."""
    for reply in api("/login", name=username, password=password):
        if "ret" in reply:
            raise RouterOsError("RouterOS anterior a 6.43, atualizar")


def _ctx() -> ssl.SSLContext:
    c = ssl.create_default_context()
    c.check_hostname = False  # a confiança vem do pin SHA-256, não da CA
    c.verify_mode = ssl.CERT_NONE
    return c


def _erro(e: Exception, logando: bool) -> RouterOsError:
    """Traduz exceções de rede/API em RouterOsError; nunca inclui a senha."""
    if isinstance(e, UnicodeEncodeError):
        return RouterOsError("Senha com caractere não ASCII")
    if isinstance(e, TrapError):
        return RouterOsError("Login recusado (usuário ou senha)" if logando else f"Erro da API: {e}")
    if isinstance(e, TimeoutError):
        return RouterOsError("API sem resposta (timeout)")
    if isinstance(e, ssl.SSLError):
        return RouterOsError(f"Falha no TLS: {getattr(e, "reason", None) or e.args[-1]}")
    if isinstance(e, (OSError, LibRouterosError)):
        return RouterOsError("Conexão com a API recusada")
    raise e


def _com_api(host, user, password, pinned_sha256, timeout, usar):
    """Conecta (TLS fixado), roda usar(api, seen) e sempre fecha a conexão."""
    seen: list[str] = []
    ctx = _ctx()
    api = None
    logando = True
    try:
        api = librouteros.connect(
            host, user, password, port=8729, timeout=timeout,
            ssl_wrapper=lambda s: pinned_wrap(ctx, s, pinned_sha256, seen),
            login_method=_login)
        logando = False
        return usar(api, seen)
    except RouterOsError:  # inclui CertMismatch e "anterior a 6.43"
        raise
    except Exception as e:
        raise _erro(e, logando) from None  # from None: não vaza args da exceção original
    finally:
        if api is not None:
            api.close()


def _ifaces(api) -> dict[str, bool]:
    return {i["name"]: bool(i["running"]) for i in api("/interface/print")}


def fetch(host: str, user: str, password: str, pinned_sha256: str | None,
          timeout: float = 5.0) -> tuple[Snapshot, str]:
    """Síncrono; o worker chama via asyncio.to_thread. Devolve (snapshot, sha256 visto)."""
    def usar(api, seen):
        r = next(iter(api("/system/resource/print")))
        snap = Snapshot(
            version=r["version"].split(" (")[0],
            cpu=float(r["cpu-load"]),
            mem=100.0 * (1 - r["free-memory"] / r["total-memory"]),
            uptime=r["uptime"],
            ifaces=_ifaces(api))
        return snap, (seen[0] if seen else "")
    return _com_api(host, user, password, pinned_sha256, timeout, usar)


def list_interfaces(host, user, password, pinned_sha256) -> list[tuple[str, bool]]:
    return _com_api(host, user, password, pinned_sha256, 5.0,
                    lambda api, seen: list(_ifaces(api).items()))
