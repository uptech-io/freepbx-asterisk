# Testes

`tests/run.sh` faz o build da imagem, sobe um ambiente de teste, roda as conferências e remove o ambiente no fim.

## Pré-requisitos

- Host de teste com Docker, `sudo` e internet (o build baixa pacotes; o `DB_IMAGE` é baixado se faltar).
- Rode como usuário comum: o script chama `sudo -n docker` e pede a senha uma vez no início (`sudo -v`), exceto quando a única fase é `lint`.
- A faixa `10.5.0.0/16` livre no host: a rede de teste a ocupa enquanto o ambiente existe. Se outra rede a usa, `up` falha em N1 e lista as redes com suas faixas.
- Kernel com `ipvlan` e IPv6: sem eles, o G4 falha.
- Opcional: `shellcheck` e `hadolint`. Sem eles, `lint` dá `warn`.

## Como rodar

```bash
tests/run.sh                    # todas as fases
tests/run.sh lint               # sem sudo e sem Docker
tests/run.sh up smoke           # o ambiente fica de pé
tests/run.sh down               # remove o ambiente
KEEP=1 IMAGE=freepbx:dev tests/run.sh   # outra imagem; mantém o ambiente
```

As fases rodam na ordem da tabela, qualquer que seja a ordem dos argumentos. Sem `build`, a imagem `IMAGE` precisa existir no host; ela nunca é baixada. O build do zero compila o Asterisk e leva dezenas de minutos.

| Fase | Faz | Ids | Precisa de |
| --- | --- | --- | --- |
| `lint` | sintaxe, `shellcheck`, `hadolint` | S1–S3 | só o repositório |
| `build` | `docker build` e metadados da imagem | I1 | internet |
| `image` | conferências num container descartável | I2–I14 | a imagem |
| `up` | remove o ambiente anterior, sobe tudo e instala o FreePBX | T1, N1, G1, B1–B4 | a imagem |
| `smoke` | serviços, banco, firewall, HTTP pelo proxy, healthcheck | M1–M29, X1–X6, H1, H2 | ambiente de pé |
| `lifecycle` | reinícios do Asterisk, boot recusado, boot numa rede `ipvlan`, troca do container `app` e `smoke` de novo | L1–L4, G2–G5, R0, R2–R4 | ambiente de pé |
| `fail2ban` | `logrotate`, bane o proxy e desbane | L5, F1–F7 | ambiente de pé |
| `down` | `docker stop` cronometrado e remoção | R1, T1 | nada |

Cada fase está em `tests/lib/<fase>.sh`; o que é comum a mais de uma, em `tests/lib/common.sh`.

Se `build`, `up` ou a troca do container (R2) falha, as fases de teste seguintes são puladas (`## <fase>: skipped, <motivo>`).

## O que a bateria cria

Todos os nomes derivam de `NAME`, sem portas publicadas:

- redes `<NAME>-front` (bridge `10.5.0.0/16`), `<NAME>-back` (bridge interna) e, de passagem, `<NAME>-ipvlan` (`ipvlan` sem interface pai, `192.0.2.0/24` e `2001:db8:5::/64`);
- volumes `<NAME>-data` e `<NAME>-dbdata`;
- containers `<NAME>-db`, `<NAME>-app`, `<NAME>-proxy` e, de passagem, `<NAME>-g2` a `<NAME>-g5`.

`up` e `down` removem qualquer objeto com esses nomes: use no `down` o mesmo `NAME` do `up`.

## Variáveis

| Variável | Padrão | Uso |
| --- | --- | --- |
| `IMAGE` | `freepbx:test` | Imagem sob teste |
| `NAME` | `fpbxtest` | Prefixo dos objetos |
| `DB_IMAGE` | `mariadb:11.8` | Imagem do banco |
| `BOOT_TIMEOUT` | `900` | Segundos de espera por boot do `app` (B4, R2) |
| `KEEP` | `0` | `1`: a execução completa não remove o ambiente |

## Saída

- Cada conferência é uma linha `ok`, `warn` ou `FAIL`, em geral com o id (`M11`, `F4`). A evidência sai abaixo, recuada.
- `warn` não conta como falha.
- No fim: `SUMMARY: N FAIL, M warn` e `run dir: <caminho>`.

| Status | Quando |
| --- | --- |
| `0` | nenhum `FAIL` |
| `1` | algum `FAIL` |
| `2` | fase desconhecida, arquivo de `tests/lib` ausente ou inválido, `BOOT_TIMEOUT` não inteiro ou `sudo -v` recusado |
| `130` | Ctrl+C |

O diretório da execução (`${TMPDIR:-/tmp}/fpbx-test.*`) guarda:

- `run.log`: tudo o que saiu na tela;
- `build.log`: saída completa do build;
- `app-<id>.log` e `db.log`: logs dos containers, salvos em `FAIL` ou saída com erro.

## O que sobra

- Execução completa: nada do ambiente, mesmo com `FAIL` ou Ctrl+C. `KEEP=1` o mantém.
- Fases nomeadas: o ambiente fica até `tests/run.sh down`, e o script avisa com `environment kept`.
- Se o script sai com o proxy banido, ele o desbane. Se aparecer `unban failed`, rode o comando impresso.
- Ficam sempre o diretório da execução e as imagens `IMAGE` e `DB_IMAGE`
  (`sudo docker image rm freepbx:test mariadb:11.8`).

## `snapshot.sh`

Retrato somente leitura de uma instância. Chama `docker` sem `sudo`; `DBHOST` tem padrão `db`.

```bash
CONTAINER=<c> DBHOST=<h> DBROOT_PASSWORD=<s> tests/snapshot.sh > antes.txt
CONTAINER=<c> DBHOST=<h> DBROOT_PASSWORD=<s> tests/snapshot.sh > depois.txt
diff antes.txt depois.txt
```
