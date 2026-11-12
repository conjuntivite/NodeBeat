"""Cifra das senhas dos roteadores (Fernet)."""
from cryptography.fernet import Fernet, InvalidToken


def encrypt(plain: str, key: str) -> str:
    return Fernet(key.encode()).encrypt(plain.encode()).decode()


def decrypt(token: str, key: str) -> str:
    """Chave errada, chave malformada ou token malformado -> ValueError."""
    try:
        return Fernet(key.encode()).decrypt(token.encode()).decode()
    except (InvalidToken, ValueError) as e:  # binascii.Error e Unicode*Error herdam de ValueError
        raise ValueError("falha ao decifrar") from e
