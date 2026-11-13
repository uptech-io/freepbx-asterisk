# FreePBX/Asterisk

Imagem Docker do **FreePBX 17** sobre **Asterisk 22**, feita para rodar no Docker Swarm.

## O que a imagem traz

- **PBX**: Asterisk 22 compilado no build e FreePBX 17, servido por Apache e PHP 8.2;
- **Processos**: o `supervisord` é o processo principal do container (PID 1) e cuida de `asterisk`, `apache2`, `fail2ban`, `cron` e `dbus`;
- **Segurança**: firewall `nftables` que descarta o que não foi liberado, `fail2ban` para o SIP e GUI acessível só pelo proxy reverso;
- **Integrações**: ODBC para o CDR e envio de e-mail por um relay SMTP (sSMTP).

## Requisitos

- **MariaDB 11.4 ou mais novo**, acessível em `DBHOST:3306`. MySQL não é suportado. Use um servidor MariaDB para cada PBX, porque o banco de CDR tem nome fixo (`asteriskcdrdb`);
- **Volume persistente em `/data`**. No Swarm, um volume local só existe no nó onde foi criado: fixe o serviço nesse nó;
- **Uma única réplica** do serviço, atualizada com `order: stop-first` (o padrão): duas PBX não podem usar o mesmo volume ao mesmo tempo;
- **`cap_add: [NET_ADMIN]`**, para o entrypoint (o script de inicialização do container) carregar o firewall e ajustar IPs e rotas. Sem ela, o container não sobe;
- **Proxy reverso na rede `10.5.0.0/16`**: a GUI só responde a conexões vindas dessa faixa;
- **`stop_grace_period: 90s`** no stack, porque a parada é sequencial.

## Build

```bash
docker build --pull \
  --build-arg ASTVERSION=22 \
  --build-arg IONCUBE_ARCH=x86-64 \
  --build-arg TZ=America/Recife \
  -t freepbx:latest .
```

| Argumento | Padrão | Uso |
| --- | --- | --- |
| `ASTVERSION` | `22` | Versão principal do Asterisk |
| `IONCUBE_ARCH` | `x86-64` | Arquitetura do ionCube loader |
| `TZ` | `America/Recife` | Fuso horário da imagem |

O FreePBX vem do tarball `freepbx-17.0-latest-EDGE`, que traz só os módulos básicos (como `core`, `dashboard`, `sipsettings`, `voicemail` e `certman`). IVR, filas, grupos de toque, `userman`, UCP e backup não vêm: instale depois, com `fwconsole ma downloadinstall <módulo>` ou pelo Module Admin.

## Variáveis de ambiente

### Banco de dados

| Variável | Padrão | Uso |
| --- | --- | --- |
| `DBHOST` | `db` | Host do MariaDB (porta 3306) |
| `DBROOT_PASSWORD` | `root` | Senha de root, usada só até a instalação terminar |
| `DBNAME` | `asterisk` | Banco do FreePBX. Só letras, números e `_` |
| `DBUSER` | `dev` | Usuário da aplicação. Não pode ser `root` |
| `DBPASSWORD` | sem padrão | Senha do usuário da aplicação. Obrigatória na instalação |

Na instalação, a imagem cria os bancos `DBNAME` e `asteriskcdrdb` (o CDR, de nome fixo) e dá ao `DBUSER` acesso aos dois. Se o usuário já existir, a senha dele passa a ser `DBPASSWORD`.

- Depois de instalada, a PBX não usa mais a senha de root: `DBROOT_PASSWORD` pode sair do stack;
- Não use aspa simples (`'`) nem barra invertida (`\`) em `DBUSER` e `DBPASSWORD`: a instalação quebra.

### FreePBX

| Variável | Padrão | Uso |
| --- | --- | --- |
| `FREEPBX_AUTO_UPGRADE` | `0` | Com `1`, cada boot executa `fwconsole ma upgradeall`, que atualiza todos os módulos e pode migrar o banco. Faça backup do banco antes |

### Rede

As variáveis abaixo só se aplicam quando o container tem uma interface de rede do tipo `ipvlan`. Sem ela, são ignoradas.

| Variável | Uso |
| --- | --- |
| `EXTRA_IPV4` | Endereço IPv4 em CIDR. **Substitui** os IPv4 da interface |
| `IPV4_GATEWAY` | Rota padrão IPv4. Só vale junto com `EXTRA_IPV4`. Com `EXTRA_IPV4` e sem `IPV4_GATEWAY`, o container pode ficar sem rota padrão |
| `EXTRA_IPV6` | Endereço IPv6 em CIDR, somado aos que a interface já tem |
| `IPV6_GATEWAY` | Rota padrão IPv6. Só vale junto com `EXTRA_IPV6` |

### SMTP

| Variável | Padrão |
| --- | --- |
| `MAIL_FROM_ADDRESS` | `pbx@uptech.com.br` |
| `MAIL_DOMAIN` | `uptech.com.br` |
| `SMTP_HOST` | sem padrão |
| `SMTP_PORT` | `587` |
| `SMTP_NAME` | sem padrão |
| `SMTP_PASSWORD` | sem padrão |

Informe `SMTP_HOST`, `SMTP_NAME` e `SMTP_PASSWORD` juntos. Sem `SMTP_HOST`, o container não envia nenhum e-mail (correio de voz, avisos do FreePBX). O relay precisa aceitar STARTTLS com autenticação; para outro tipo de relay, ajuste `rootfs/usr/local/bin/docker-entrypoint.d/ssmtp.sh` e reconstrua a imagem.

O `MAIL_FROM_ADDRESS` é o endereço que recebe os e-mails destinados a usuários do sistema, como o `root`. O remetente vem de cada mensagem.

## Instalação e atualização

Com o volume vazio, o primeiro boot instala a PBX: copia o Asterisk da imagem para `/data/asterisk`, cria os bancos e roda o instalador do FreePBX. Leva alguns minutos, e a GUI só responde no fim.

- **Instalação incompleta**: se o instalador falhar, o log mostra `FreePBX install did not complete; will retry on next boot` e o container continua no ar. A nova tentativa só acontece no boot seguinte: force uma task nova com `docker service update --force <serviço>`;
- **Volume vazio com banco em uso**: se `/data` estiver vazio e o banco `DBNAME` já tiver tabelas, o container se recusa a instalar (`refusing to install over it`) e sai. É sinal de volume errado ou perdido. Monte o volume certo ou, para reinstalar do zero, apague os bancos `DBNAME` e `asteriskcdrdb`.

Depois de instalada, cada boot usa o que está no volume:

- **Asterisk**: acompanha a imagem. Se o binário da imagem for diferente do que está no volume, o boot copia por cima os binários (`sbin`), os módulos (`usr/lib64`) e a documentação XML da imagem. Módulos instalados à parte continuam lá;
- **Configurações do Asterisk**: não são alteradas. Isso inclui `pjsip_custom_post.conf` e `pjsip.transports_custom.conf`, que a imagem só copia na instalação;
- **FreePBX e seus módulos**: não mudam com a imagem. Atualize com `fwconsole ma upgradeall` ou com `FREEPBX_AUTO_UPGRADE=1`.

## Persistência

```text
/data
├── asterisk/                  # Asterisk: binários, configurações, spool (gravações, correio de voz) e logs
├── web/                       # arquivos do FreePBX servidos pelo Apache
├── cron/crontabs/             # agendamentos (crontabs; o FreePBX usa o do usuário asterisk)
├── fail2ban/                  # banco de dados do fail2ban (banimentos)
│   └── jail.d/                # ajustes do jail (*.local), como a lista de IPs ignorados
└── entrypoint-hooks.d/
    ├── nftables.d/            # arquivos .nft aplicados no boot
    └── scripts.d/             # scripts .sh executados no boot
```

O backup da PBX é o volume mais os dois bancos (`DBNAME` e `asteriskcdrdb`): um sem o outro não restaura a PBX. A cada boot, `/data/asterisk` e `/data/web` passam a pertencer ao usuário `asterisk`, e `/data` e `/data/cron/crontabs`, ao root. O dono do restante do volume não muda.

## Supervisão de processos

| Programa | Comando | Prioridade | Reinício automático |
| --- | --- | --- | --- |
| `dbus` | `dbus-daemon --system --nofork` | 10 | sempre |
| `fail2ban` | `fail2ban-server -xf start` | 20 | sempre |
| `asterisk` | `asterisk -f -n -U asterisk -G asterisk` | 30 | só em queda (saída diferente de 0) |
| `cron` | `cron -f` | 40 | sempre |
| `bootstrap` | `docker-bootstrap` | 50 | não (roda uma vez por boot) |
| `apache2` | `apache2-foreground` | 60 | sempre (iniciado pelo bootstrap) |

Para ver o estado de um programa ou agir sobre ele:

```bash
docker exec <container> supervisorctl status            # estado de todos os programas
docker exec <container> supervisorctl restart apache2   # reinicia um programa
```

### Logs

- **Log do container** (`docker logs`): saída de `dbus`, `fail2ban`, `bootstrap` e `apache2`, com cada acesso à GUI. A imagem não limita esse log: defina `max-size` no driver de log do stack;
- **Asterisk**: o log completo fica em `/data/asterisk/var/log/asterisk/full`. A saída do processo vai para `/var/log/supervisor/asterisk.log`, dentro do container (no máximo 2 MB). Se o Asterisk não subir, o motivo aparece em `docker exec <container> supervisorctl tail asterisk`;
- **`cron`**: a saída é descartada.

### Convivência com o `fwconsole`

Rode o `fwconsole` como root, que é o padrão do `docker exec`.

- `fwconsole stop`: o Asterisk encerra com código 0 e fica parado, sem reinício pelo `supervisord`;
- `fwconsole start`: o `safe_asterisk` do container é um atalho para `supervisorctl start asterisk`, então o Asterisk volta sob supervisão;
- `fwconsole restart`: stop seguido de start;
- **Queda do Asterisk** (código diferente de 0, SIGKILL, SIGSEGV): reinício automático;
- **`kill` comum (SIGTERM)**: conta como parada pedida. O Asterisk fica parado até `fwconsole start` ou `supervisorctl start asterisk`;
- **Parada nos primeiros 5 s após o início**: conta como falha de partida, e o `supervisord` inicia o Asterisk de novo.

O healthcheck só consulta o Asterisk. Se o Asterisk ficar parado por 2 a 2,5 minutos (5 checagens falhas, uma a cada 30 s), o container fica `unhealthy` e o Swarm o encerra. Com a política de reinício padrão, o Swarm sobe uma task nova; com `condition: on-failure`, o serviço fica sem nenhuma. Em manutenções, não deixe o Asterisk parado por tanto tempo.

### Parada

A imagem usa `STOPSIGNAL SIGTERM` e encerra os programas um de cada vez. Só o Asterisk tem até 30 s para encerrar, por isso o prazo padrão do `docker stop` (10 s) não basta: no stack, use `stop_grace_period: 90s`.

## Rede e firewall

O entrypoint carrega as regras do `nftables` antes de qualquer serviço. Se elas não carregarem, o container não sobe. A entrada é descartada por padrão; ficam liberados:

- **SIP**: portas 5060 e 5061, TCP e UDP, com limite de conexões novas por origem;
- **RTP**: portas UDP 10000 a 20000;
- **HTTP (80) por IPv4**: só a partir de `10.5.0.0/16`, a rede do proxy reverso;
- **HTTP (80) por IPv6**: qualquer origem, com limite de taxa, para a validação ACME (emissão de certificados, como os do Let's Encrypt). De fora da rede do proxy, o Apache só entrega `/.well-known/acme-challenge/` e `/.freepbx-known/` e responde 403 ao resto;
- **ICMP e ICMPv6**: mensagens de erro, ping com limite de taxa e descoberta de vizinhos do IPv6.

A faixa `10.5.0.0/16` está fixa em `rootfs/etc/nftables.nft` e em `rootfs/etc/apache2/apache2.conf`. Com o proxy em outra rede, altere os dois arquivos e reconstrua a imagem.

O Apache lê o IP do cliente no cabeçalho `X-Forwarded-For` enviado pelo proxy. Se o cabeçalho trouxer um endereço privado ou de loopback, o Apache o ignora e registra o IP do proxy como cliente.

Para liberar outra porta (IAX, WebSocket, SIP em porta diferente), crie um arquivo em `/data/entrypoint-hooks.d/nftables.d/` que acrescente uma regra à chain `input` da tabela `inet filter`, a da imagem:

```nft
add rule inet filter input tcp dport 8089 accept
```

Uma tabela ou chain própria não serve: o que a chain da imagem descarta não volta a ser aceito.

## fail2ban

### Ignorar um endereço IP

Um IP ignorado nunca é banido. Ponha na lista os IPs fixos de escritórios, troncos, operadoras e monitoramento: eles podem errar a autenticação sem ser ataque, e a origem de um pacote SIP por UDP pode ser forjada para banir um IP legítimo.

Para tornar a lista permanente, grave-a em `/data/fail2ban/jail.d/ignoreip.local`. O `/etc/fail2ban/jail.d` do container é um link para essa pasta do volume:

```bash
docker exec -i <container> sh -c 'cat > /data/fail2ban/jail.d/ignoreip.local' <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 <ip> <rede/CIDR>
EOF
docker exec <container> fail2ban-client -t                      # valida a sintaxe
docker exec <container> fail2ban-client reload                  # aplica sem reiniciar a PBX
docker exec <container> fail2ban-client get asterisk ignoreip   # confere a lista em vigor
```

O arquivo substitui a lista da imagem, por isso mantenha `127.0.0.1/8 ::1`. Valide sempre com o `-t`. Com erro de sintaxe, o `reload` é recusado; no boot seguinte, o `fail2ban` não sobe, e a PBX fica sem banimento.

## Hooks

O boot aplica o que estiver em `/data/entrypoint-hooks.d`:

- **`nftables.d/*.nft`**: carregados pelo entrypoint, logo depois das regras base (exemplo em [Rede e firewall](#rede-e-firewall));
- **`scripts.d/*.sh`**: executados pelo bootstrap com o Asterisk já no ar, antes do `fwconsole reload` e do Apache.

Os scripts rodam como root, com `bash`, em ordem alfabética, em todo boot. Um script que falha não interrompe o boot, mas um que não termina impede o Apache de subir. Eles não recebem `DBROOT_PASSWORD` nem `SMTP_PASSWORD`.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Exemplo: rota para a rede dos telefones.
ip route replace 192.168.50.0/24 via 10.5.0.1
```

## Vivo Voz Negócio (VVN)

Em troncos da VVN, ajuste o `sdp_session` do endpoint em `pjsip.endpoint_custom_post.conf`, trocando `SIP_TRUNK_NAME` pelo nome do tronco:

```ini
[SIP_TRUNK_NAME](+type=endpoint)
sdp_session=UPTECH/PBX:A22
```

Se o tronco for removido ou renomeado, ajuste o bloco: sem o tronco, o Asterisk ignora o restante desse arquivo.
