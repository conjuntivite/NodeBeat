"""Sondas -> Observation (puro)."""
from __future__ import annotations

from .routeros import Snapshot
from .rules import MkState, Observation


def classify(snapshot: Snapshot | None, api_error: str | None, tunnel_ping: bool | None,
             public_ping: bool | None, watched: list[str]) -> Observation:
    if snapshot is not None:
        ifaces = {n: snapshot.ifaces.get(n, False) for n in watched}
        missing = frozenset(n for n in watched if n not in snapshot.ifaces)
        detalhe = ""
        if missing:
            detalhe = "interface não encontrada: " + ", ".join(n for n in watched if n in missing)
        return Observation(MkState.NO_AR, detalhe, snapshot.cpu, snapshot.mem, ifaces, missing)
    if tunnel_ping:
        return Observation(MkState.ERRO_ACESSO, api_error or "API sem resposta")
    if public_ping:
        return Observation(MkState.VPN_CAIU, "Túnel sem resposta; IP público responde")
    return Observation(MkState.OFFLINE, "Túnel e IP público sem resposta")
