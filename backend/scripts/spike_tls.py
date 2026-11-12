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
    info = {}  # capturado logo apos o handshake (depois de falha o socket ja foi fechado)

    def wrap(s):
        w = ctx.wrap_socket(s)
        info["tls"], info["cifra"] = w.version(), w.cipher()[0]
        info["sha256"] = hashlib.sha256(w.getpeercert(binary_form=True)).hexdigest()
        return w

    api = None
    try:
        api = librouteros.connect(host, user, senha, port=8729, timeout=10,
                                  ssl_wrapper=wrap, login_method=plain)
        # RouterOS < 6.43 responde /login com =ret= sem erro; a falha real aparece aqui
        recurso = list(api("/system/resource/print"))
    except Exception as e:
        print(f"[{nome}] FALHOU: {e!r}")
        if info:
            print(f"[{nome}] handshake OK: {info}; falha foi depois (login/API)")
        return False
    finally:
        if api:
            api.close()
    print(f"[{nome}] OK")
    for k, v in info.items():
        print(f"  {k}: {v}")
    print("  /system/resource:", recurso)
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
