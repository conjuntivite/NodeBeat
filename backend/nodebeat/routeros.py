"""Tipos do cliente RouterOS (a Task 3 estende este arquivo)."""
from __future__ import annotations

from dataclasses import dataclass


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
