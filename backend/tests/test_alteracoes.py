"""Peer do IPsec: leitura e troca de endereco.

Campos confirmados numa v7 real (RouterOS 7.24.4, print anonimizado) e na doc da v6, com IPs de exemplo:
- peer (v6 e v7): `.id`, `name` (v7; na v6 pode faltar), `address` (IP, IP/prefixo ou dominio como
  vpn.exemplo.com), `disabled` ("true"/"false"), `comment`.
- policy v7: tem `peer=<name do peer>` e `sa-dst-address` (somente leitura, derivado do peer);
  a policy template (`template=true`) deve ser ignorada.
- policy v6: sem `peer`; `sa-dst-address` (ex.: 203.0.113.1) precisa acompanhar o novo endereco.
"""
import pytest
from librouteros.exceptions import TrapError

from nodebeat import alteracoes

PEER = "/ip/ipsec/peer"
POLICY = "/ip/ipsec/policy"


class FakeApi:
    def __init__(self, respostas: dict, falhas: dict | None = None):
        self.respostas, self.falhas, self.chamadas = respostas, falhas or {}, []

    def __call__(self, cmd, **kw):
        self.chamadas.append((cmd, kw))
        f = self.falhas.get(cmd)
        if f is not None and (not isinstance(f, list) or f.pop(0)):
            raise (f if not isinstance(f, list) else OSError("caiu"))
        return iter(self.respostas.get(cmd, []))

    def sets(self, prefixo):
        return [kw for c, kw in self.chamadas if c == prefixo + "/set"]


def peer(id="*1", address="203.0.113.1/32", name="peer-ipsec", **kw):
    return {".id": id, "name": name, "address": address, "disabled": "false", **kw}


def test_ler_peers_dominio():
    api = FakeApi({PEER + "/print": [peer(address="vpn.exemplo.com", comment="x"),
                                     peer(id="*2", address="203.0.113.1/32"),
                                     peer(id="*3", address="203.0.113.9", disabled="true")]})
    a, b, c = alteracoes.ler_peers(api)
    assert a == {"id": "*1", "nome": "peer-ipsec", "endereco": "vpn.exemplo.com", "desativado": False,
                 "comentario": "x", "por_dominio": True}
    assert b["por_dominio"] is False and c["por_dominio"] is False and c["desativado"] is True


def test_ler_peers_v6_sem_nome():
    [p] = alteracoes.ler_peers(FakeApi({PEER + "/print": [{".id": "*1", "address": "203.0.113.1/32"}]}))
    assert p["nome"] is None and p["comentario"] == ""


def test_trocar_peer_v7_nao_mexe_policy():
    api = FakeApi({PEER + "/print": [peer()],
                   POLICY + "/print": [{".id": "*5", "peer": "peer-ipsec", "sa-dst-address": "203.0.113.1"}]})
    r = alteracoes.trocar_peer(api, "*1", "203.0.113.2")
    assert api.sets(PEER) == [{".id": "*1", "address": "203.0.113.2"}]
    assert api.sets(POLICY) == [] and r["policies"] == [] and r["policies_erro"] == []
    assert r["antigo"] == "203.0.113.1/32" and r["novo"] == "203.0.113.2"


def test_trocar_peer_v6_atualiza_sa_dst():
    api = FakeApi({PEER + "/print": [peer()],
                   POLICY + "/print": [{".id": "*5", "sa-dst-address": "203.0.113.1"},
                                       {".id": "*6", "sa-dst-address": "203.0.113.77"},
                                       {".id": "*7", "template": "true", "sa-dst-address": "203.0.113.1"}]})
    r = alteracoes.trocar_peer(api, "*1", "203.0.113.2")
    assert api.sets(POLICY) == [{".id": "*5", "sa-dst-address": "203.0.113.2"}]
    assert r["policies"] == ["*5"] and r["policies_erro"] == []


def test_trocar_peer_set_policy_falha():
    api = FakeApi({PEER + "/print": [peer()], POLICY + "/print": [{".id": "*5", "sa-dst-address": "203.0.113.1"}]},
                  {POLICY + "/set": TrapError("failure: x")})
    r = alteracoes.trocar_peer(api, "*1", "203.0.113.2")
    assert r["policies_erro"] == ["*5"] and r["policies"] == [] and api.sets(PEER)


def test_trocar_peer_conexao_cai_depois_do_set():
    # primeiro print (localizar) funciona; o segundo (confirmar) cai
    api = FakeApi({PEER + "/print": [peer()]}, {PEER + "/print": [False, True]})
    r = alteracoes.trocar_peer(api, "*1", "203.0.113.2")
    assert r["confirmado"] is False and api.sets(PEER)


def test_trocar_peer_confirma():
    class Api(FakeApi):
        def __call__(self, cmd, **kw):
            out = super().__call__(cmd, **kw)
            if cmd == PEER + "/set":
                self.respostas[PEER + "/print"] = [peer(address=kw["address"])]
            return out
    api = Api({PEER + "/print": [peer()]})
    assert alteracoes.trocar_peer(api, "*1", "203.0.113.2")["confirmado"] is True


def test_trocar_peer_igual_valueerror():
    api = FakeApi({PEER + "/print": [peer()]})
    with pytest.raises(ValueError):
        alteracoes.trocar_peer(api, "*1", "203.0.113.1")
    assert api.sets(PEER) == []


def test_trocar_peer_id_inexistente_keyerror():
    with pytest.raises(KeyError):
        alteracoes.trocar_peer(FakeApi({PEER + "/print": [peer()]}), "*9", "203.0.113.2")
