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

    def __call__(self, cmd, **kw):  # gerador como o librouteros: so age quando consumido
        self.chamadas.append((cmd, kw))
        f = self.falhas.get(cmd)
        if f is not None and (not isinstance(f, list) or f.pop(0)):
            raise (f if not isinstance(f, list) else OSError("caiu"))
        yield from self.respostas.get(cmd, [])

    def sets(self, prefixo):
        return [kw for c, kw in self.chamadas if c == prefixo + "/set"]


def peer(id="*1", address="203.0.113.1/32", name="peer-ipsec", **kw):
    return {".id": id, "name": name, "address": address, "disabled": False, **kw}


def test_ler_peers_dominio():
    api = FakeApi({PEER + "/print": [peer(address="vpn.exemplo.com", comment="x"),
                                     peer(id="*2", address="203.0.113.1/32"),
                                     peer(id="*3", address="203.0.113.9", disabled=True)]})
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
                                       {".id": "*7", "template": True, "sa-dst-address": "203.0.113.1"}]})
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


def test_trocar_peer_conexao_cai_durante_o_set():
    api = FakeApi({PEER + "/print": [peer()]}, {PEER + "/set": OSError("caiu")})
    r = alteracoes.trocar_peer(api, "*1", "203.0.113.2")
    assert r["confirmado"] is False and r["policies"] == []


def test_trocar_peer_trap_no_set_propaga():
    api = FakeApi({PEER + "/print": [peer()]}, {PEER + "/set": TrapError("failure: x")})
    with pytest.raises(TrapError):
        alteracoes.trocar_peer(api, "*1", "203.0.113.2")


def test_trocar_peer_avisa_antes_de_escrever():
    visto = []
    api = FakeApi({PEER + "/print": [peer()]})
    alteracoes.trocar_peer(api, "*1", "203.0.113.2", lambda: visto.append(api.sets(PEER)))
    assert visto == [[]]


def test_trocar_peer_confirma():
    class Api(FakeApi):
        def __call__(self, cmd, **kw):
            if cmd == PEER + "/set":
                self.respostas[PEER + "/print"] = [peer(address=kw["address"] + "/32")]  # a MK guarda com /32
            yield from super().__call__(cmd, **kw)
    api = Api({PEER + "/print": [peer()]})
    assert alteracoes.trocar_peer(api, "*1", "203.0.113.2")["confirmado"] is True


def test_trocar_peer_v6_policy_com_prefixo():
    api = FakeApi({PEER + "/print": [peer(address="203.0.113.1")],
                   POLICY + "/print": [{".id": "*5", "sa-dst-address": "203.0.113.1/32"}]})
    assert alteracoes.trocar_peer(api, "*1", "203.0.113.2")["policies"] == ["*5"]


def test_ler_peers_campos_numericos_viram_texto():
    # librouteros converte palavra so de digitos em int
    [p] = alteracoes.ler_peers(FakeApi({PEER + "/print": [peer(name=2, comment=1)]}))
    assert p["nome"] == "2" and p["comentario"] == "1"


def test_liberacoes_wan_numerica_vira_texto():
    [x] = alteracoes.liberacoes([nat(protocol="tcp", comment="nodebeat:A", **{"in-interface": 1})])
    assert x["wan"] == "1"


def test_trocar_peer_igual_valueerror():
    api = FakeApi({PEER + "/print": [peer()]})
    with pytest.raises(ValueError):
        alteracoes.trocar_peer(api, "*1", "203.0.113.1")
    assert api.sets(PEER) == []


def test_trocar_peer_id_inexistente_keyerror():
    with pytest.raises(KeyError):
        alteracoes.trocar_peer(FakeApi({PEER + "/print": [peer()]}), "*9", "203.0.113.2")


# ---- liberar porta ----
NAT = "/ip/firewall/nat"
IFACES = {"ether1", "ether2"}


def test_wan_pelo_ip_publico():
    assert alteracoes.wan([{"address": "8.8.4.4/30", "interface": "ether1"}], [], IFACES, "8.8.4.4") == "ether1"


def test_wan_rota_menor_distance():
    rotas = [{"dst-address": "0.0.0.0/0", "active": True, "distance": 2, "gateway": "ether2"},
             {"dst-address": "0.0.0.0/0", "active": True, "distance": 1, "gateway": "ether1"},
             {"dst-address": "0.0.0.0/0", "active": False, "distance": 0, "gateway": "ether2"}]
    assert alteracoes.wan([], rotas, IFACES, None) == "ether1"


def test_wan_v7_immediate_gw():
    rotas = [{"dst-address": "0.0.0.0/0", "active": True, "distance": 1, "gateway": "192.0.2.1",
              "immediate-gw": "192.0.2.1%ether1"}]
    assert alteracoes.wan([], rotas, IFACES, None) == "ether1"


def test_wan_v6_gateway_status():
    rotas = [{"dst-address": "0.0.0.0/0", "active": True, "distance": 1, "gateway": "192.0.2.1",
              "gateway-status": "192.0.2.1 reachable via  ether1"}]
    assert alteracoes.wan([], rotas, IFACES, None) == "ether1"


def test_wan_nenhuma():
    assert alteracoes.wan([], [], IFACES, "8.8.4.4") is None
    rotas = [{"dst-address": "0.0.0.0/0", "active": True, "distance": 1, "gateway": "192.0.2.1%vlan9"}]
    assert alteracoes.wan([], rotas, IFACES, None) is None


class RwApi(FakeApi):
    def __init__(self, nat=(), falha_add=None):
        super().__init__({NAT + "/print": list(nat), "/ip/service/print": [{"name": "api-ssl", "port": 8729}],
                          "/ip/address/print": [{"address": "8.8.4.4/30", "interface": "ether1"}],
                          "/ip/route/print": [], "/interface/print": [{"name": "ether1"}]})
        self.falha_add, self.n_add, self.removidos = falha_add, 0, []

    def __call__(self, cmd, **kw):
        if cmd == NAT + "/add":
            self.n_add += 1
            if self.n_add == self.falha_add:
                self.chamadas.append((cmd, kw))
                raise TrapError("falhou")
            self.chamadas.append((cmd, kw))
            yield {"ret": f"*{self.n_add}"}
            return
        if cmd == NAT + "/remove":
            self.removidos.append(kw[".id"])
        yield from super().__call__(cmd, **kw)

    def adds(self):
        return [kw for c, kw in self.chamadas if c == NAT + "/add"]


PEDIDO = {"protocolo": "tcp", "porta_externa": 8080, "ip_interno": "192.168.88.50", "porta_interna": 80,
          "descricao": "DVR bloco B"}
RES = {8729, 18729, 8291, 18291}


def nat(**kw):
    return {".id": "*9", "chain": "dstnat", "action": "dst-nat", "disabled": False, **kw}


@pytest.mark.parametrize("porta", [8050, 8080])
def test_liberar_conflito_faixa_e_lista(porta):
    api = RwApi([nat(protocol="tcp", **{"dst-port": "8000-8100"}), nat(protocol="tcp", **{"dst-port": "80,8080"})])
    with pytest.raises(ValueError, match="em uso"):
        alteracoes.liberar_porta(api, PEDIDO | {"porta_externa": porta}, "8.8.4.4", RES)
    assert api.adds() == []


def test_liberar_regra_desativada_nao_conflita():
    api = RwApi([nat(protocol="tcp", disabled=True, **{"dst-port": "8080"})])
    assert alteracoes.liberar_porta(api, PEDIDO, "8.8.4.4", RES)["regras"] == ["*1"]


def test_liberar_ambos_cria_duas_com_comentario():
    api = RwApi()
    r = alteracoes.liberar_porta(api, PEDIDO | {"protocolo": "ambos"}, "8.8.4.4", RES)
    assert r == {"wan": "ether1", "regras": ["*1", "*2"]}
    assert api.adds() == [{"chain": "dstnat", "action": "dst-nat", "protocol": p, "dst-port": "8080",
                           "to-addresses": "192.168.88.50", "to-ports": "80", "in-interface": "ether1",
                           "comment": "nodebeat:DVR bloco B"} for p in ("tcp", "udp")]


def test_liberar_ambos_segunda_falha_remove_primeira():
    api = RwApi(falha_add=2)
    with pytest.raises(TrapError):
        alteracoes.liberar_porta(api, PEDIDO | {"protocolo": "ambos"}, "8.8.4.4", RES)
    assert api.removidos == ["*1"]


def test_liberar_conexao_cai_vira_routeroserror_simples():
    from nodebeat import routeros

    class Cai(RwApi):
        def __call__(self, cmd, **kw):
            if cmd == NAT + "/add":
                raise OSError("caiu")
            yield from super().__call__(cmd, **kw)
    with pytest.raises(routeros.RouterOsError) as e:
        alteracoes.liberar_porta(Cai(), PEDIDO, "8.8.4.4", RES)
    assert not isinstance(e.value, routeros.SemConexao) and "Conexão caiu" in e.value.detalhe


def test_liberar_porta_reservada():
    for porta in (8729, 8729 + 0):
        with pytest.raises(ValueError, match="reservada"):
            alteracoes.liberar_porta(RwApi(), PEDIDO | {"porta_externa": porta}, "8.8.4.4", RES)
    api = RwApi()
    api.respostas["/ip/service/print"].append({"name": "www", "port": 8088, "disabled": True})
    with pytest.raises(ValueError, match="reservada"):
        alteracoes.liberar_porta(api, PEDIDO | {"porta_externa": 8088}, "8.8.4.4", RES)


def test_liberar_descricao_repetida_case_insensitive():
    api = RwApi([nat(protocol="tcp", comment="nodebeat:dvr BLOCO b", **{"dst-port": "9000"})])
    with pytest.raises(ValueError, match="descrição"):
        alteracoes.liberar_porta(api, PEDIDO, "8.8.4.4", RES)


def test_liberar_wan_nao_reconhecida():
    with pytest.raises(ValueError, match="WAN"):
        alteracoes.liberar_porta(RwApi(), PEDIDO, "9.9.9.9", RES)


def test_liberacoes_agrupa_e_ignora_sem_prefixo():
    rows = [nat(protocol="udp", comment="nodebeat:B", **{"dst-port": "81", "to-addresses": "192.168.88.2",
                                                           "to-ports": "81", "in-interface": "ether1"}),
            nat(protocol="tcp", comment="nodebeat:A", disabled=True, **{"dst-port": "80", "to-addresses": "192.168.88.1",
                                                                         "to-ports": "8080", "in-interface": "ether1"}),
            nat(protocol="udp", comment="nodebeat:A", **{"dst-port": "80", "to-addresses": "192.168.88.1",
                                                          "to-ports": "8080", "in-interface": "ether1"}),
            nat(protocol="tcp", comment="DVR", **{"dst-port": "80"})]
    a, b = alteracoes.liberacoes(rows)
    assert a == {"descricao": "A", "protocolos": ["tcp", "udp"], "porta_externa": "80", "ip_interno": "192.168.88.1",
                 "porta_interna": "8080", "wan": "ether1", "desativada": True}
    assert b["descricao"] == "B"


def test_remover_so_mexe_com_prefixo():
    api = RwApi([nat(**{".id": "*1"}, comment="nodebeat:DVR bloco B"), nat(**{".id": "*2"}, comment="nodebeat:DVR bloco B"),
                 nat(**{".id": "*3"}, comment="DVR bloco B")])
    assert alteracoes.remover_porta(api, "dvr bloco b") == 2
    assert api.removidos == ["*1", "*2"]
    assert alteracoes.remover_porta(RwApi(), "x") == 0
