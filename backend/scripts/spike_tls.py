"""Spike descartavel: TLS + login plain na API-SSL (8729) de uma MikroTik.
Uso: python spike_tls.py <host> <user> <senha>"""
import hashlib
import ssl
import sys

import librouteros
from librouteros.login import plain


def ctx_default():
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    c.check_hostname = False
    c.verify_mode = ssl.CERT_NONE
    return c


def ctx_legacy():
    c = ctx_default()
    c.minimum_version = ssl.TLSVersion.TLSv1
    c.set_ciphers("DEFAULT:@SECLEVEL=0")
    return c


def tentar(nome, ctx, host, user, senha):
    socks = []  # captura o socket TLS p/ ler versao/cifra/cert

    def wrap(s):
        w = ctx.wrap_socket(s)
        socks.append(w)
        return w

    try:
        api = librouteros.connect(host, user, senha, port=8729, timeout=10,
                                  ssl_wrapper=wrap, login_method=plain)
    except Exception as e:
        print(f"[{nome}] FALHOU: {e!r}")
        # handshake ok mas login falhou? socks[0] existe e ja negociou
        if socks and socks[0].version():
            print(f"[{nome}] (handshake OK: {socks[0].version()}, {socks[0].cipher()[0]}; falha foi no login)")
        return False
    s = socks[0]
    print(f"[{nome}] OK")
    print("  TLS:", s.version())
    print("  cifra:", s.cipher()[0])
    print("  sha256:", hashlib.sha256(s.getpeercert(binary_form=True)).hexdigest())
    print("  /system/resource:", list(api("/system/resource")))
    api.close()
    return True


def main():
    if len(sys.argv) != 4:
        sys.exit("uso: python spike_tls.py <host> <user> <senha>")
    host, user, senha = sys.argv[1:]
    for nome, f in (("default", ctx_default), ("legacy TLSv1+SECLEVEL=0", ctx_legacy)):
        if tentar(nome, f(), host, user, senha):
            return
    sys.exit(1)


main()
