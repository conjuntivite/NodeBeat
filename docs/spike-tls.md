# Spike TLS — API-SSL em RouterOS v6 e v7

Objetivo: descobrir quais opções de `ssl.SSLContext` funcionam em v6 e v7 e a assinatura do erro de login plain em RouterOS < 6.43. Alimenta a Task 3.

O spike roda da estação (<IP_ESTACAO>), que sai para a internet com o IP público da sede **<IP_PUBLICO_SEDE>**. Alvos: v6 de teste `<IP_MK_V6_TESTE>`; v7 (7.24.4) `<IP_MK_V7_TESTE>`.

## 1. Aplicar o .rsc (humano, em cada MK)

0. **Backup antes de tudo**: Winbox > Files > Backup (o campo de senha da GUI e literal, entao `$` e seguro ali, ao contrario do terminal) e `/export file=antes-monitor` (v6 inclui segredos; v7 precisa de `show-sensitive`). Baixe os dois arquivos.
1. Copie `deploy/routeros-monitor-user.rsc` e preencha os placeholders do topo:
   - `<IP_VM>` = `<IP_PUBLICO_SEDE>` (só no spike)
   - `<IP_PUBLICO_SEDE>` = `<IP_PUBLICO_SEDE>`
   - `<SENHA_MONITOR>` = senha forte nova, **só ASCII alfanumérico** (sem `$`, aspas ou barra invertida): fica entre aspas no .rsc e o librouteros exige ASCII
   - `<WAN_IFACE>` = interface WAN da MK (`/interface print`)
2. Aplique no terminal da MK (Winbox > New Terminal) colando o conteúdo, ou `/import file-name=routeros-monitor-user.rsc` após enviar o arquivo. Vale para v6 e v7.
3. Se o firewall dropar a 8729 no WAN, ative a regra comentada no final do .rsc.
4. Durante o spike a api-ssl fica acessível no WAN apenas a partir de <IP_PUBLICO_SEDE>. **Reverter depois**: trocar `address=` do api-ssl e do usuário `monitor` para o IP do túnel da VM (`/ip service set api-ssl address=<IP_TUNEL_VM>`, `/user set monitor address=<IP_TUNEL_VM>`).

## 2. Rodar o spike (estação Windows)

```powershell
cd backend
python -m venv .venv
.venv\Scripts\python -m pip install librouteros
.venv\Scripts\python scripts\spike_tls.py <IP_MK_V6_TESTE> monitor <SENHA>   # v6
.venv\Scripts\python scripts\spike_tls.py <IP_MK_V7_TESTE> monitor <SENHA>    # v7
```

O script tenta o contexto padrão e, se falhar, `minimum_version=TLSv1` + `DEFAULT:@SECLEVEL=0`, imprimindo qual funcionou ou a exceção (`repr`) de cada um.

## 3. Resultados

| Roteador | RouterOS | TLS | Cifra | SHA-256 do cert | Config que funcionou | Login |
|---|---|---|---|---|---|---|
| <IP_MK_V6_TESTE> (v6, hEX, WAN `PPPoE - ALT`) | 6.49.17 (stable) | TLSv1.2 | ECDHE-RSA-AES256-GCM-SHA384 | `a0e3dcc77313e5e14fa71d9e8687fc27c90b8c4a3bcdf3438d3dee9326dbc43c` (bate com o `fingerprint` do RouterOS) | default (`create_default_context`, `check_hostname=False`, `CERT_NONE`) | plain OK |
| <IP_MK_V7_TESTE> (v7, cliente-v7, hEX, WAN `pppoe-out1`) | 7.24.4 (stable) | TLSv1.2 | ECDHE-RSA-AES256-GCM-SHA384 | `952606fa6d5ebcdff6ff85b508c7969f6c287fbbb55820098d2ade4b5e5c3f10` (bate com `:put [/certificate get monitor-api fingerprint]`; o `/certificate print` da v7 nao mostra a coluna) | default | plain OK |

O contexto legado nao foi necessario em nenhuma das duas.

## 4. Assinatura do RouterOS < 6.43

**Não capturada**: não havia MK < 6.43 disponível. Decisão do controlador: a Task 3 detecta RouterOS < 6.43 pela resposta do `/login` conter a chave `ret` (login antigo por desafio, comportamento documentado pela MikroTik, **não verificado empiricamente**) e levanta `RouterOsError("RouterOS anterior a 6.43, atualizar")`.

## 5. Gate

**Passou**: v6 e v7 funcionam com o contexto padrão.

## 6. Para a Task 3

- `SSLContext` = `ssl.create_default_context()` + `check_hostname=False` + `verify_mode=CERT_NONE`; a confiança vem do pinning por SHA-256. Sem `minimum_version`/`set_ciphers`.
- Comandos precisam da forma completa: `/system/resource/print` (`/system/resource` dá `TrapError('no such command')`).
- `/system/resource/print` devolve `cpu-load`, `free-memory`, `total-memory` como int; `version` vem como `"6.49.17 (stable)"` — remover o sufixo ` (stable)` ao parsear.
- Lembrete: no spike, api-ssl e usuário `monitor` ficam restritos a <IP_PUBLICO_SEDE>; mover para o IP do túnel da VM depois.
