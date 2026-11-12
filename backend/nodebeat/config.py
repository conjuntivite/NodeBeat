"""Configuração por variáveis de ambiente NODEBEAT_*."""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass
class Settings:
    mongo_url: str
    redis_url: str
    secret_key: str
    webhook_url: str
    webhook_token: str | None
    reference_host: str
    interval_s: int = 30


def _req(nome: str) -> str:
    v = os.environ.get(nome)
    if not v:
        raise RuntimeError(f"variável de ambiente obrigatória ausente: {nome}")
    return v


def load_settings() -> Settings:
    return Settings(
        _req("NODEBEAT_MONGO_URL"), _req("NODEBEAT_REDIS_URL"), _req("NODEBEAT_SECRET_KEY"),
        _req("NODEBEAT_WEBHOOK_URL"), os.environ.get("NODEBEAT_WEBHOOK_TOKEN") or None,
        _req("NODEBEAT_REFERENCE_HOST"), int(os.environ.get("NODEBEAT_INTERVAL_S") or 30))
