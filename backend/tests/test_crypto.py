import pytest
from cryptography.fernet import Fernet

from nodebeat.crypto import decrypt, encrypt


def test_encrypt_roundtrip():
    key = Fernet.generate_key().decode()
    token = encrypt("segredo", key)
    assert token != "segredo"
    assert decrypt(token, key) == "segredo"


def test_decrypt_wrong_key_raises():
    token = encrypt("segredo", Fernet.generate_key().decode())
    with pytest.raises(ValueError):
        decrypt(token, Fernet.generate_key().decode())


def test_decrypt_malformed_raises():
    key = Fernet.generate_key().decode()
    with pytest.raises(ValueError):
        decrypt("nao-e-token", key)
    with pytest.raises(ValueError):
        decrypt(encrypt("x", key), "chave-invalida")
