# FreePBX/Asterisk

Este repositório empacota uma imagem Docker para executar **FreePBX 17** sobre **Asterisk 22**, com foco em operação contínua: a instalação real é movida para um volume persistente em `/data`, o bootstrap é automatizado via entrypoint e o runtime já sobe com regras de rede, ODBC, `fail2ban`, `nftables` e ajustes básicos do Apache.

## O que a imagem entrega

- **PBX**: Asterisk compilado
- **Dashboard**: FreePBX 17
- **Banco externo**: MariaDB
- **Persistência**: estado da instalação em `/data`
- **Integração**:
  - ODBC para `asteriskcdrdb`
  - sSMTP com relay externo
- **Serviços internos** (gerenciados pelo `supervisord`, ver [Supervisão de processos](#supervisão-de-processos)):
  - `dbus`
  - `cron`
  - `asterisk`
  - `fail2ban`
  - `apache2`
- **Segurança embarcada**:
  - regras base de `nftables`
  - jails de `fail2ban` para Asterisk
  - hardening simples do Apache

## Persistência

O projeto depende de um volume montado em `/data`.

```text
/data
├── asterisk/                  # binários, configs, spool, logs e runtime do Asterisk
├── web/                       # arquivos servidos pelo Apache
├── fail2ban/                  # configs, db e logs do Fail2Ban
└── entrypoint-hooks.d/
    ├── nftables.d/            # arquivos .nft aplicados no boot
    └── scripts.d/             # scripts .sh executados no boot
```

Esse layout permite recriar o container sem reinstalar manualmente a PBX, desde que o volume seja mantido.

## Supervisão de processos

| Programa | Comando | Prioridade | Reinício automático |
| --- | --- | --- | --- |
| `dbus` | `dbus-daemon --system --nofork` | 10 | sempre |
| `fail2ban` | `fail2ban-server -xf start` | 20 | sempre |
| `asterisk` | `asterisk -f -n -U asterisk -G asterisk` | 30 | só em queda (saída diferente de 0) |
| `cron` | `cron -f` | 40 | sempre |
| `bootstrap` | `docker-bootstrap` | 50 | não (roda uma vez por boot) |
| `apache2` | `apache2-foreground` | 60 | sempre (iniciado pelo bootstrap) |

Convivência com o `fwconsole`:

- `fwconsole stop`: o Asterisk encerra com código 0 e fica parado (o `supervisord` não o reinicia);
- `fwconsole start`: o `safe_asterisk` do container é um shim que executa `supervisorctl start asterisk`, então o Asterisk volta sob supervisão;
- `fwconsole restart`: stop seguido de start, com o mesmo comportamento;
- Uma parada nos primeiros 5 s após o início (`startsecs`) é tratada como falha de partida e o `supervisord` reinicia o Asterisk;
- Queda do Asterisk (código diferente de 0 ou morte por sinal não tratado, como SIGKILL ou SIGSEGV): reinício automático. `kill`/`killall asterisk` (SIGTERM) contam como parada pedida e o Asterisk fica parado até `supervisorctl start asterisk` ou `fwconsole start`.

Parada: a imagem usa `STOPSIGNAL SIGTERM` e a parada é sequencial (o Asterisk tem até 30 s para encerrar). O prazo padrão do `docker stop` (10 s) é curto; no stack, use `stop_grace_period: 90s`.

## fail2ban

O jail `asterisk` lê `/data/asterisk/var/log/asterisk/fail2ban` e bane falhas de autenticação SIP (eventos `SECURITY` do Asterisk) e chamadas anônimas rejeitadas pelo FreePBX (`Rejecting unknown SIP connection`). Limites em `rootfs/etc/fail2ban/jail.local`: 10 falhas em 10 min banem o IP por 12 h, em todas as portas TCP/UDP; cada novo banimento do mesmo IP dobra o tempo, até 1 semana.

O canal de log é a linha `fail2ban => warning,security` em `/etc/asterisk/logger_logfiles_custom.conf`. O bootstrap a acrescenta quando nem `logger_logfiles_additional.conf` nem `logger_logfiles_custom.conf` declaram um canal `fail2ban` (um módulo comercial pode declarar o seu; duas linhas contariam cada falha duas vezes). Se o módulo passar a declarar o canal depois, apague a linha do `_custom` e rode `asterisk -rx 'logger reload'`. O entrypoint recria o arquivo de log se ele faltar (sem ele o `fail2ban` não sobe). Se o Asterisk não estiver gravando no arquivo, o boot mostra `Warning: Asterisk is not writing to the fail2ban log; the jail cannot ban.`

```bash
docker exec <container> fail2ban-client status asterisk             # IPs banidos
docker exec <container> fail2ban-client set asterisk unbanip <ip>   # desbanir um IP
```

### Ignorar um endereço IP

Um IP ignorado nunca é banido pelo jail. Use para troncos, operadoras e monitoramento, que podem errar a autenticação sem ser ataque.

```bash
docker exec <container> fail2ban-client set asterisk addignoreip <ip>   # ignorar; aceita vários IPs e redes (CIDR)
docker exec <container> fail2ban-client get asterisk ignoreip           # listar os ignorados
docker exec <container> fail2ban-client set asterisk delignoreip <ip>   # deixar de ignorar; um por comando
```

O `addignoreip` vale na hora, mas:

- **não desbane:** se o IP já estiver banido, rode também o `unbanip`;
- **não é permanente:** a lista volta ao que está na imagem quando o `fail2ban` reinicia ou recarrega (restart ou recriação do container, `fail2ban-client reload`).

## Variáveis de ambiente

### Banco de dados

| Variável | Padrão | Uso |
| --- | --- | --- |
| `DBHOST` | `db` | Host do banco |
| `DBROOT_PASSWORD` | `root` | Senha de root do banco |
| `DBNAME` | `asterisk` | Banco principal do FreePBX |
| `DBCDR` | `asteriskcdrdb` | Banco de CDR |
| `DBUSER` | `dev` | Usuário da aplicação |
| `DBPASSWORD` | `1234567890` | Senha da aplicação |

### FreePBX

| Variável | Padrão | Uso |
| --- | --- | --- |
| `FREEPBX_AUTO_UPGRADE` | `0` | Com `1`, cada boot executa `fwconsole ma upgradeall` (atualiza todos os módulos e pode migrar o banco). Com `0`, os módulos só mudam por ação deliberada |

### Rede

| Variável | Uso |
| --- | --- |
| `EXTRA_IPV4` | Adiciona IPv4 extra à interface `ipvlan` detectada |
| `IPV4_GATEWAY` | Substitui a rota padrão IPv4 |
| `EXTRA_IPV6` | Adiciona IPv6 extra à interface `ipvlan` detectada |
| `IPV6_GATEWAY` | Substitui a rota padrão IPv6 |

### SMTP

| Variável | Padrão |
| --- | --- |
| `MAIL_FROM_ADDRESS` | `pbx@uptech.com.br` |
| `MAIL_DOMAIN` | `uptech.com.br` |
| `SMTP_HOST` | sem padrão |
| `SMTP_PORT` | `587` |
| `SMTP_NAME` | sem padrão |
| `SMTP_PASSWORD` | sem padrão |

Se `SMTP_HOST`, `SMTP_NAME` ou `SMTP_PASSWORD` não forem informados, autenticação SMTP ficará incompleta.

### Build args

| Argumento | Padrão | Uso |
| --- | --- | --- |
| `ASTVERSION` | `22` | Versão principal do Asterisk |
| `IONCUBE_ARCH` | `x86-64` | Arquitetura do ionCube loader |
| `TZ` | `America/Recife` | Fuso horário da imagem |

## Requisitos operacionais

- Docker para build e execução da imagem;
- Acesso à internet durante o build para baixar Asterisk e FreePBX;
- Banco MariaDB/MySQL acessível no boot;
- Volume persistente montado em `/data`;
- Capacidade `CAP_NET_ADMIN`, porque o entrypoint aplica `nftables` e pode manipular IPs/rotas.

## Build

Build usando o script do repositório:

```bash
./build.sh
```

Build com argumentos customizados:

```bash
docker build \
  --build-arg ASTVERSION=22 \
  --build-arg IONCUBE_ARCH=x86-64 \
  --build-arg TZ=America/Recife \
  -t freepbx:latest .
```

## Hooks e extensões

O bootstrap procura por customizações em:

- `/data/entrypoint-hooks.d/nftables.d/*.nft`
- `/data/entrypoint-hooks.d/scripts.d/*.sh`

Exemplo de regra extra:

```nft
table inet custom {
  chain input {
    type filter hook input priority 10; policy accept;
    tcp dport 443 accept
  }
}
```

Exemplo de script extra:

```bash
#!/usr/bin/env bash
set -euo pipefail

fwconsole reload
```

### Observação para Vivo Voz Negócio (VVN)

Se o ambiente usar **Vivo Voz Negócio (VVN)**, ajuste o `sdp_session` no endpoint do tronco SIP. Um ponto adequado para esse override é o arquivo `pjsip.endpoint_custom_post.conf`, substituindo `SIP_TRUNK_NAME` pelo nome real do tronco:

```ini
[SIP_TRUNK_NAME](+type=endpoint)
sdp_session=UPTECH/PBX:A22
```

## Observações importantes

- O build usa `freepbx-17.0-latest-EDGE`, então o artefato final pode variar ao longo do tempo;
- O pós-boot só executa `fwconsole ma upgradeall` com `FREEPBX_AUTO_UPGRADE=1`; antes de atualizar módulos, faça backup do banco;
- O container pressupõe um ambiente onde `CAP_NET_ADMIN` é aceitável;
- A configuração SMTP é montada por variáveis de ambiente no boot; se o relay exigir outro formato além do previsto em `ssmtp.sh`, ajuste o script;
- As regras base do `nftables` já embutem premissas de rede local, como `10.5.0.0/16` para HTTP.
