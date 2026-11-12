"""Motor de alertas puro (sem I/O): recebe observações, devolve eventos."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from typing import Literal
from zoneinfo import ZoneInfo

SP = ZoneInfo("America/Sao_Paulo")
LIMITE = 80  # CPU/memória alertam acima disso (estrito)


class MkState(StrEnum):
    NO_AR = "no_ar"
    VPN_CAIU = "vpn_caiu"
    OFFLINE = "offline"
    ERRO_ACESSO = "erro_acesso"


@dataclass(frozen=True)
class MkRef:
    id: str
    nome: str


@dataclass(frozen=True)
class Observation:
    state: MkState
    detalhe: str = ""
    cpu: float | None = None
    mem: float | None = None
    ifaces: dict[str, bool] = field(default_factory=dict)  # nome -> running (só as vigiadas)


@dataclass(frozen=True)
class Event:
    evento: Literal["queda", "retorno", "encerrado"]  # "encerrado" só vai para o histórico
    tipo: str
    mk: MkRef | None
    detalhe: str
    inicio: datetime
    fim: datetime | None
    duracao_s: int | None

    def to_payload(self) -> dict:
        def iso(d):
            return d.astimezone(SP).isoformat() if d else None

        return {
            "evento": self.evento,
            "tipo": self.tipo,
            "mk": {"id": self.mk.id, "nome": self.mk.nome} if self.mk else None,
            "detalhe": self.detalhe,
            "inicio": iso(self.inicio),
            "fim": iso(self.fim),
            "duracao_s": self.duracao_s,
        }


@dataclass
class _Tracker:
    phase: Literal["pending", "alerting", "recovering"]
    tipo: str
    primeiro: datetime
    detalhe: str
    mk: MkRef | None
    voltou: datetime | None = None


def _pct(v: float) -> str:
    return f"{v:.1f}".replace(".", ",")


class AlertEngine:
    def __init__(self, confirm_s: int = 120, recover_s: int = 60):
        self.confirm_s = confirm_s
        self.recover_s = recover_s
        self.frozen = False
        # chave: "sede" ou "<mk_id>|mk", "<mk_id>|cpu_alta", "<mk_id>|interface_caida:<nome>"
        self._t: dict[str, _Tracker] = {}

    def _step(self, key: str, bad: bool, now: datetime, tipo: str, detalhe: str,
              mk: MkRef | None) -> list[Event]:
        t = self._t.get(key)
        if t is None:
            if bad:
                self._t[key] = _Tracker("pending", tipo, now, detalhe, mk)
            return []
        if t.phase == "pending":
            if not bad:
                del self._t[key]
                return []
            t.tipo, t.detalhe = tipo, detalhe
            if (now - t.primeiro).total_seconds() >= self.confirm_s:
                t.phase = "alerting"
                return [Event("queda", tipo, mk, detalhe, t.primeiro, None, None)]
            return []
        if bad:
            evs: list[Event] = []
            if tipo != t.tipo:  # só a chave "mk" muda de tipo
                evs.append(self._encerrado(t, now))
                t.tipo, t.detalhe = tipo, detalhe
                evs.append(Event("queda", tipo, mk, detalhe, t.primeiro, None, None))
            t.phase, t.voltou = "alerting", None
            return evs
        if t.phase == "alerting":
            t.phase, t.voltou = "recovering", now
            return []
        if (now - t.voltou).total_seconds() >= self.recover_s:
            del self._t[key]
            return [Event("retorno", t.tipo, t.mk, t.detalhe, t.primeiro, t.voltou,
                          int((t.voltou - t.primeiro).total_seconds()))]
        return []

    @staticmethod
    def _encerrado(t: _Tracker, now: datetime) -> Event:
        return Event("encerrado", t.tipo, t.mk, t.detalhe, t.primeiro, now,
                     int((now - t.primeiro).total_seconds()))

    def observe_reference(self, ok: bool, now: datetime) -> list[Event]:
        was_frozen = self.frozen
        self.frozen = not ok
        evs = self._step("sede", not ok, now, "falha_sede",
                         "Referência da sede sem resposta", None)
        if ok and was_frozen:
            for k in [k for k, t in self._t.items()
                      if k != "sede" and t.phase == "pending"]:
                del self._t[k]
        return evs

    def observe_mk(self, mk: MkRef, obs: Observation, now: datetime) -> list[Event]:
        if self.frozen:
            return []
        evs = self._step(f"{mk.id}|mk", obs.state != MkState.NO_AR, now,
                         obs.state.value, obs.detalhe, mk)
        prefix = f"{mk.id}|"
        parallel = [k for k in self._t if k.startswith(prefix) and k != prefix + "mk"]
        if obs.state != MkState.NO_AR:
            # só fecha as paralelas quando a queda da MK é confirmada
            if any(e.evento == "queda" for e in evs):
                for k in parallel:
                    t = self._t.pop(k)
                    if t.phase != "pending":
                        evs.append(self._encerrado(t, now))
            return evs
        for k in parallel:  # interface que deixou de ser vigiada: descarta sem evento
            if k.startswith(prefix + "interface_caida:") \
                    and k[len(prefix + "interface_caida:"):] not in obs.ifaces:
                del self._t[k]
        for key, tipo, bad, det in (
            ("cpu_alta", "cpu_alta", obs.cpu is not None and obs.cpu > LIMITE,
             f"CPU em {_pct(obs.cpu or 0)}%"),
            ("memoria_alta", "memoria_alta", obs.mem is not None and obs.mem > LIMITE,
             f"Memória em {_pct(obs.mem or 0)}%"),
            *((f"interface_caida:{n}", "interface_caida", not running,
               f"Interface {n} caída") for n, running in obs.ifaces.items()),
        ):
            evs += self._step(prefix + key, bad, now, tipo, det, mk)
        return evs

    def forget_mk(self, mk_id: str) -> None:
        for k in [k for k in self._t if k.startswith(f"{mk_id}|")]:
            del self._t[k]

    def dump(self) -> dict:
        def d(t: _Tracker) -> dict:
            return {
                "phase": t.phase, "tipo": t.tipo, "detalhe": t.detalhe,
                "primeiro": t.primeiro.isoformat(),
                "voltou": t.voltou.isoformat() if t.voltou else None,
                "mk": {"id": t.mk.id, "nome": t.mk.nome} if t.mk else None,
            }

        return {"confirm_s": self.confirm_s, "recover_s": self.recover_s,
                "frozen": self.frozen, "trackers": {k: d(t) for k, t in self._t.items()}}

    @classmethod
    def load(cls, d: dict) -> AlertEngine:
        e = cls(d["confirm_s"], d["recover_s"])
        e.frozen = d["frozen"]
        for k, t in d["trackers"].items():
            e._t[k] = _Tracker(
                t["phase"], t["tipo"], datetime.fromisoformat(t["primeiro"]), t["detalhe"],
                MkRef(**t["mk"]) if t["mk"] else None,
                datetime.fromisoformat(t["voltou"]) if t["voltou"] else None)
        return e
