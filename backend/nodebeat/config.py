"""Configuração por variáveis de ambiente NODEBEAT_*."""
from __future__ import annotations

import ipaddress
import os
from dataclasses import dataclass, field


@dataclass
class Settings:
    mongo_url: str
    redis_url: str
    secret_key: str
    webhook_url: str
    webhook_token: str | None
    reference_host: str
    interval_s: int = 30
    inventario_s: int = 3600
    sede_redes: list[str] = field(default_factory=list)


def _req(nome: str) -> str:
    v = os.environ.get(nome)
    if not v:
        raise RuntimeError(f"variável de ambiente obrigatória ausente: {nome}")
    return v


def _sede_redes() -> list[str]:
    try:
        return [str(ipaddress.ip_network(c.strip(), strict=False))
                for c in (os.environ.get("NODEBEAT_SEDE_REDES") or "").split(",") if c.strip()]
    except ValueError:
        raise RuntimeError("NODEBEAT_SEDE_REDES inválida") from None


def load_settings() -> Settings:
    return Settings(
        _req("NODEBEAT_MONGO_URL"), _req("NODEBEAT_REDIS_URL"), _req("NODEBEAT_SECRET_KEY"),
        _req("NODEBEAT_WEBHOOK_URL"), os.environ.get("NODEBEAT_WEBHOOK_TOKEN") or None,
        _req("NODEBEAT_REFERENCE_HOST"), int(os.environ.get("NODEBEAT_INTERVAL_S") or 30),
        int(os.environ.get("NODEBEAT_INVENTARIO_S") or 3600), _sede_redes())
