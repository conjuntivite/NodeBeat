import datetime
import hashlib
import socket
import ssl
import threading

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from librouteros.exceptions import TrapError

from nodebeat import routeros
from nodebeat.routeros import (CertMismatch, RouterOsError, Snapshot, fetch,
                               list_interfaces, pinned_wrap)


@pytest.fixture
def tls_server(tmp_path):
    """Servidor TLS local (127.0.0.1) com cert autoassinado; devolve (porta, sha256 do cert)."""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "teste")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=1))
            .sign(key, hashes.SHA256()))
    cert_f, key_f = tmp_path / "c.pem", tmp_path / "k.pem"
    cert_f.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_f.write_bytes(key.private_bytes(serialization.Encoding.PEM,
                                        serialization.PrivateFormat.PKCS8,
                                        serialization.NoEncryption()))
    sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    sctx.load_cert_chain(cert_f, key_f)
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    srv.settimeout(5)

    def serve():
        try:
            conn, _ = srv.accept()
            with conn:
                try:
                    with sctx.wrap_socket(conn, server_side=True) as t:
                        t.recv(1)
                except (ssl.SSLError, OSError):
                    pass
        except OSError:
            pass

    th = threading.Thread(target=serve)
    th.start()
    yield srv.getsockname()[1], hashlib.sha256(cert.public_bytes(serialization.Encoding.DER)).hexdigest()
    srv.close()
    th.join()


def _client_ctx():
    c = ssl.create_default_context()
    c.check_hostname = False
    c.verify_mode = ssl.CERT_NONE
    return c


def test_pinned_wrap_records_fingerprint(tls_server):
    port, sha = tls_server
    seen = []
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    w = pinned_wrap(_client_ctx(), s, None, seen)
    w.close()
    assert seen == [sha]


def test_pinned_wrap_mismatch_raises(tls_server):
    port, sha = tls_server
    seen = []
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    with pytest.raises(CertMismatch) as e:
        pinned_wrap(_client_ctx(), s, "0" * 64, seen)
    assert e.value.detalhe == "certificado mudou"
    assert seen == [sha]
    assert s.fileno() == -1  # socket fechado


class FakeApi:
    def __init__(self, login_reply=None, resource=None, ifaces=None):
        self.login_reply, self.closed = login_reply or [], False
        self.resource = resource or [{"version": "6.49.17 (stable)", "cpu-load": 12,
                                      "free-memory": 25, "total-memory": 100, "uptime": "1d2h"}]
        self.ifaces = ifaces if ifaces is not None else [
            {"name": "ether1", "running": True}, {"name": "ether2", "running": False}]

    def __call__(self, cmd, **kw):
        if cmd == "/login":
            return iter(self.login_reply)
        return iter({"/system/resource/print": self.resource,
                     "/interface/print": self.ifaces}[cmd])

    def close(self):
        self.closed = True


def _patch_connect(monkeypatch, api):
    monkeypatch.setattr(routeros, "pinned_wrap", lambda ctx, s, exp, seen: seen.append("abc"))
    def fake(host, user, password, **kw):
        kw["ssl_wrapper"](None)
        kw["login_method"](api, user, password)
        return api
    monkeypatch.setattr(routeros.librouteros, "connect", fake)


def test_fetch_maps_resource(monkeypatch):
    api = FakeApi()
    _patch_connect(monkeypatch, api)
    snap, seen = fetch("h", "u", "p", None)
    assert snap == Snapshot("6.49.17", 12.0, 75.0, "1d2h", {"ether1": True, "ether2": False})
    assert seen == "abc"
    assert api.closed


def test_list_interfaces(monkeypatch):
    _patch_connect(monkeypatch, FakeApi())
    assert list_interfaces("h", "u", "p", None) == [("ether1", True), ("ether2", False)]


def test_old_routeros_detalhe(monkeypatch):
    api = FakeApi(login_reply=[{"ret": "abcdef"}])
    _patch_connect(monkeypatch, api)
    with pytest.raises(RouterOsError) as e:
        fetch("h", "u", "p", None)
    assert e.value.detalhe == "RouterOS anterior a 6.43, atualizar"


def _raising(exc):
    def fake(*a, **kw):
        raise exc
    return fake


@pytest.mark.parametrize("exc,detalhe", [
    (TimeoutError(), "API sem resposta (timeout)"),
    (ConnectionRefusedError(), "Conexão com a API recusada"),
    (ConnectionResetError(), "Conexão com a API recusada"),
    (TrapError("cannot log in"), "Login recusado (usuário ou senha)"),
    (UnicodeEncodeError("ascii", "ç", 0, 1, "x"), "Senha com caractere não ASCII"),
    (ssl.SSLError(1, "boom"), "Falha no TLS: boom"),
])
def test_error_mapping(monkeypatch, exc, detalhe):
    monkeypatch.setattr(routeros.librouteros, "connect", _raising(exc))
    with pytest.raises(RouterOsError) as e:
        fetch("h", "u", "senha-secreta", None)
    assert e.value.detalhe == detalhe
    assert "senha-secreta" not in str(e.value)


def test_cert_mismatch_passes_through(monkeypatch):
    monkeypatch.setattr(routeros.librouteros, "connect", _raising(CertMismatch()))
    with pytest.raises(CertMismatch):
        list_interfaces("h", "u", "p", "0" * 64)


def test_closes_on_failure_after_connect(monkeypatch):
    api = FakeApi(ifaces=None)
    api.resource = [{"version": "x"}]  # KeyError no parse
    _patch_connect(monkeypatch, api)
    with pytest.raises(KeyError):
        fetch("h", "u", "p", None)
    assert api.closed
