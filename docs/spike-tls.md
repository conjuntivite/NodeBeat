# Spike TLS — API-SSL em RouterOS v6 e v7

Objetivo: descobrir quais opções de `ssl.SSLContext` funcionam em v6 e v7 e a assinatura do erro de login plain em RouterOS < 6.43. Alimenta a Task 3.

O spike roda da estação (<IP_ESTACAO>), que sai para a internet com o IP público da sede **<IP_PUBLICO_SEDE>**. Alvos: v6 de teste `<IP_MK_V6_TESTE>`; v7 (7.24.4) `<IP_MK_V7_TESTE>`.

## 1. Aplicar o .rsc (humano, em cada MK)

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
| <IP_MK_V6_TESTE> (v6) | | | | | | |
| <IP_MK_V7_TESTE> (v7) | | | | | | |

## 4. Assinatura do RouterOS < 6.43

Login plain (`/login name= password=`) em RouterOS < 6.43 — colar o `repr()` exato da exceção (ou resposta) e a versão da MK:

```
(preencher)
```

## 5. Gate

Se **nenhuma** configuração funcionar na v6: parar e levar ao usuário antes da Task 3.
