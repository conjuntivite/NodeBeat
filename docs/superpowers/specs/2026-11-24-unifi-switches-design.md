# Switches pela API do UniFi Network — design

Aprovado pelo dono em 2026-11-24 ("sim, pode seguir pelos subagentes").

## Intenção

O dono quer ver no NodeBeat o que a UniFi mostra de cada switch: consumo PoE, tráfego, erros, STP, **quais equipamentos (nome, IP, MAC) estão em cada porta** e os eventos do System Log. Hoje o NodeBeat lê só link e velocidade por SNMP, e nenhum switch manda syslog.

O controlador UniFi Network (UniFi OS Server 10.6, num servidor da empresa) já gerencia os dois switches (USW Pro 48 e USW-48-PoE). A chave de API foi gerada e está em `deploy/.env` do CT 119 (`NODEBEAT_UNIFI_URL`, `NODEBEAT_UNIFI_API_KEY`).

## Objetivos

1. Na tela do switch:
   - cabeçalho com CPU, memória, temperatura, uptime, firmware (e se há atualização), PoE usado de total e número de clientes;
   - colunas novas na tabela de portas: PoE (W), tráfego ↓/↑, erros, STP e clientes;
   - ao tocar numa porta, a lista dos equipamentos ligados nela, com nome (ou fabricante), IP, MAC e velocidade.
2. Na tela de Eventos, abaixo do bloco das MKs, um bloco **Switches** com:
   - contadores por grupo;
   - a lista dos últimos eventos, no formato do System Log da UniFi.

## Não objetivos

- Abrir ticket pelo UniFi (o webhook está desligado, e eventos de switch são só tela e histórico).
- Escrever no UniFi (religar PoE, configurar porta).
- Eventos de Wi-Fi/AP e roaming.
- Trocar a leitura SNMP: ela continua dando o estado e o alerta de uplink.

## Anti-objetivo

Barulho. A tela não pode virar um log cru de 17 mil linhas: os eventos são filtrados para os que citam um switch e agrupados.

## O que a API entrega (verificado em 2026-11-24)

Cabeçalho `X-API-Key`. TLS com certificado autoassinado.

- `GET {URL}/proxy/network/api/s/default/stat/device`, itens com `type == "usw"`:
  - `name`, `model`, `ip`, `mac`, `version`, `upgradable`, `uptime`, `system-stats.cpu/mem` (strings), `general_temperature` (pode faltar), `total_used_power`/`total_max_power` (só no PoE), `num_sta`;
  - `uplink.port_idx`, `uplink.uplink_device_name`, `uplink.uplink_remote_port`;
  - `port_table[]`: `port_idx`, `up`, `speed`, `poe_power` (string W, só PoE), `poe_class`, `rx_bytes-r`/`tx_bytes-r` (bytes/s), `rx_errors`/`tx_errors`, `rx_dropped`/`tx_dropped`, `stp_state`, `link_down_count`, `is_uplink`, `mac_table_count`.
- `GET .../stat/sta`, clientes com `is_wired`:
  - `sw_mac`, `sw_port`, `mac`, `ip`/`last_ip`, `hostname` ou `name` (só 33 de 126 têm), `oui` (fabricante), `wired_rate_mbps`.
- `POST {URL}/proxy/network/v2/api/site/default/system-log/all` e `.../system-log/device-alert`:
  - corpo `{"pageNumber":0,"pageSize":N,"timestampFrom":ms,"timestampTo":ms}`;
  - resposta `data[]` com `id`, `timestamp` (ms), `category`, `event`, `severity`, `message_raw` e `parameters` (dicts com `id`/`name`).
  - Eventos de switch vistos:
    - `CLIENT_CONNECTED_WIRED` e `CLIENT_DISCONNECTED_WIRED`, com `DEVICE`, `PORT`, `CLIENT`, `IP`, `DURATION`, `DATA_UP`, `DATA_DOWN`, `CONNECTION_SPEED`;
    - `DEVICE_UNREACHABLE`, `DEVICE_RECONNECTED`, `DEVICE_RECONNECTED_WITH_DOWNLINKS` e `MULTIPLE_DEVICES_UNREACHABLE`;
    - `POWER_SUPERVISOR_POWER_CYCLE_TRIGGERED`, `PORT_TRANSMISSION_ERRORS`, `MADE_CHANGES` (com `OBJECT` = nome do switch) e `CLIENT_IP_CONFLICT`.

## Abordagem escolhida

API do controlador (opção 1 das três apresentadas). As outras duas foram descartadas:
- **Syslog do controlador:** só dá eventos, sem PoE nem tráfego.
- **SNMP ampliado:** não dá eventos nem os clientes por porta.

## Design

- **Configuração:**
  - `NODEBEAT_UNIFI_URL` e `NODEBEAT_UNIFI_API_KEY` são opcionais; sem as duas, a integração fica desligada, sem erro;
  - o `compose.yml` passa as duas só ao worker;
  - a chave é segredo: nunca vai para log, mensagem de erro, resposta da API ou Redis/Mongo;
  - em log, só `type(e).__name__`.
- **Coleta (worker, a cada `mapa_s` = 60 s):**
  - tarefa própria, como `run_equipamentos`: pula se a anterior não terminou e nunca derruba o worker;
  - o switch do UniFi casa com o equipamento cadastrado pelo **IP**; switch do UniFi sem equipamento é ignorado.
- **Estado por switch:** Redis `unifi:eq:<id>`, JSON com `lido_em`, `sistema{...}` e `portas{"<port_idx>": {...}}`.
  - Em cada porta, `clientes[]` com `nome`, `ip`, `mac`, `fabricante` e `mbps`.
  - O nome é `hostname` ou `name` do cliente; quando não há nome ou ele é igual ao MAC, fica `null`, e a tela mostra o fabricante.
- **Eventos:**
  - **Filtro:** do System Log, só os que citam um switch casado (algum `parameters[*].id` igual ao MAC do switch, `DEVICE`/`OBJECT` com o nome dele ou `DEVICE_WITH_PORT` começando pelo nome dele).
  - **Gravação:** vão para a coleção `eventos` existente com `mk_id = "eq:<id>"`, `origem = "unifi"`, `unifi_id` (índice único, para não duplicar), `recebido_em = timestamp`, `tipo` (lista abaixo), `severidade`, `campos{porta, cliente, ip, duracao, dados_up, dados_down}` e `mensagem` em pt-BR.
  - **Leitura:** o cursor fica em Redis `unifi:log:ultimo_ms`; na 1ª vez, lê as últimas 24 h.
  - **Tipos:** `cliente_conectou`, `cliente_desconectou`, `inalcancavel`, `reconectou`, `poe_religado`, `erros_transmissao`, `mudanca_admin`, `conflito_ip`, `outro`.
  - **Grupos na tela:**
    - Clientes com fio = `cliente_*`;
    - Alertas = `inalcancavel`, `reconectou`, `erros_transmissao`, `conflito_ip`;
    - PoE religado = `poe_religado`;
    - Mudanças = `mudanca_admin`.
- **API:**
  - `GET /api/equipamentos/{id}` ganha `unifi` (ou `null`).
  - O mapa de portas casa o `port_idx` do UniFi com o número no fim do nome SNMP (`0/12` → 12).
  - Nova rota `GET /api/eventos/switches?periodo=1h|24h|7d|30d`, que devolve `contagens` por grupo e os 100 eventos mais novos: `quando`, `switch_id`, `switch_nome`, `porta`, `tipo`, `grupo`, `mensagem`, `severidade`.
  - O `/api/eventos/painel` das MKs continua sem eventos `eq:`.
- **Telas** (visual Inviolável/pink, dois temas, ≥ 4,5:1):
  - **Switch:**
    - os indicadores novos aparecem quando há `unifi`;
    - a tabela ganha as colunas PoE, ↓/↑, Erros, STP e Clientes;
    - o detalhe da porta lista os equipamentos;
    - com mais de 8 clientes, mostra a contagem e a lista rolável;
    - na porta de uplink, mostra "uplink para <nome remoto> (porta N)".
  - **Eventos:** o bloco Switches usa o mesmo período da página, com 4 Indicadores e a lista: hora, "switch · Porta N", mensagem e Selo de severidade.

## Restrições

- TDD.
- Amostras de teste com IPs e MACs falsos (documentação: 192.0.2.x, 02:00:00:…); nunca IP, MAC ou nome real de cliente no repositório.
- `flutter analyze` limpo.

## Deixado para o builder

- Formato exato das mensagens em pt-BR.
- Conversão de unidades: bytes/s para Mbps com 1 casa; W com 1 casa.
- Paginação do log: até 5 páginas de 500 por rodada.
