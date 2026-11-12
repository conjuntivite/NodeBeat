"""CLI: python -m nodebeat.cli create-user <usuario>"""
from __future__ import annotations

import argparse
import asyncio
import getpass as _getpass
import sys

from pymongo.errors import DuplicateKeyError

from nodebeat import auth, store

MIN_SENHA = 12


def main(argv=None, *, getpass=_getpass.getpass, db=None) -> int:
    p = argparse.ArgumentParser(prog="nodebeat.cli")
    p.add_argument("comando", choices=["create-user"])
    p.add_argument("usuario")
    a = p.parse_args(argv)
    usuario = a.usuario.strip().lower()
    senha = getpass("Senha: ")
    if len(senha) < MIN_SENHA:
        print(f"A senha deve ter ao menos {MIN_SENHA} caracteres.")
        return 1
    if getpass("Confirme a senha: ") != senha:
        print("As senhas não conferem.")
        return 1
    if db is None:
        from motor.motor_asyncio import AsyncIOMotorClient

        from nodebeat.config import load_settings
        db = AsyncIOMotorClient(load_settings().mongo_url).get_default_database("nodebeat")

    async def criar() -> bool:
        if await store.get_user(db, usuario):
            return False
        try:
            await store.insert_user(db, usuario, auth.hash_password(senha))
        except DuplicateKeyError:
            return False
        return True

    if not asyncio.run(criar()):
        print(f"Usuário já existe: {usuario}")
        return 1
    print(f"Usuário criado: {usuario}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
