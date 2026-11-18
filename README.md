# FreePBX/Asterisk

Imagem Docker do **FreePBX 17** sobre **Asterisk 22**, com Apache e PHP 8.2, ODBC para o CDR e sSMTP, feita para rodar no Docker Swarm.

## Requisitos

- **MariaDB** (MySQL não é suportado). Um servidor MariaDB por PBX: o banco de CDR tem nome fixo (`asteriskcdrdb`);
- **Volume persistente em `/data`**, com o serviço fixado no nó do volume;
- **Uma única réplica**, com `order: stop-first` (o padrão): duas PBX não podem usar o mesmo volume;
- **`cap_add: [NET_ADMIN]`**, para o firewall, os IPs e as rotas. Sem ela, o container não sobe;
- **Proxy reverso na rede `10.5.0.0/16`**: a GUI só responde a essa faixa;
- **`stop_grace_period: 90s`**: os programas param um de cada vez, e o prazo padrão de 10 s não basta;
- **`max-size` no driver de log**: a imagem não limita o log do container.

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

O FreePBX vem só com os módulos básicos. IVR, filas, grupos de toque, `userman`, UCP e backup não vêm: instale com `fwconsole ma downloadinstall <módulo>` ou pelo Module Admin.

## Variáveis de ambiente

| Variável | Padrão | Uso |
| --- | --- | --- |
| `DBHOST` | `db` | Host do MariaDB (porta 3306) |
| `DBROOT_PASSWORD` | `root` | Senha de root, usada até a instalação terminar; depois pode sair do stack |
| `DBNAME` | `asterisk` | Banco do FreePBX. Só letras, números e `_` |
| `DBUSER` | `dev` | Usuário da aplicação. Não pode ser `root` |
| `DBPASSWORD` | sem padrão | Senha do `DBUSER`. Obrigatória na instalação |
| `FREEPBX_AUTO_UPGRADE` | `0` | Com `1`, cada boot roda `fwconsole ma upgradeall`, que pode migrar o banco. Faça backup antes |
| `SMTP_HOST` | sem padrão | Relay SMTP, com STARTTLS e autenticação. Sem ele, nenhum e-mail sai |
| `SMTP_PORT` | `587` | Porta do relay |
| `SMTP_NAME` | sem padrão | Usuário no relay |
| `SMTP_PASSWORD` | sem padrão | Senha no relay |
| `MAIL_FROM_ADDRESS` | `pbx@uptech.com.br` | Destino dos e-mails para usuários do sistema, como o `root`. Não é o remetente |
| `MAIL_DOMAIN` | `uptech.com.br` | Domínio com que a PBX se apresenta ao relay |

- A instalação cria os bancos `DBNAME` e `asteriskcdrdb` e dá ao `DBUSER` acesso aos dois. Um `DBUSER` que já existe passa a ter a senha `DBPASSWORD`;
- Aspa simples (`'`) ou barra invertida (`\`) em `DBUSER` e `DBPASSWORD` quebram a instalação;
- Para um relay sem STARTTLS ou sem autenticação, ajuste `rootfs/usr/local/bin/docker-entrypoint.d/ssmtp.sh` e reconstrua a imagem.

As variáveis de rede só valem com uma interface `ipvlan` no container; sem ela, são ignoradas:

| Variável | Uso |
| --- | --- |
| `EXTRA_IPV4` | IPv4 em CIDR. **Substitui** os IPv4 da interface |
| `IPV4_GATEWAY` | Rota padrão IPv4, só com `EXTRA_IPV4`. Sem ela, o container pode ficar sem rota padrão |
| `EXTRA_IPV6` | IPv6 em CIDR, somado aos da interface |
| `IPV6_GATEWAY` | Rota padrão IPv6, só com `EXTRA_IPV6` |

## Instalação e atualização

Com o volume vazio, o primeiro boot instala a PBX em alguns minutos; a GUI só responde no fim.

| Mensagem no log | Ação |
| --- | --- |
| `FreePBX install did not complete; will retry on next boot` | `docker service update --force <serviço>` |
| `refusing to install over it` (volume vazio, `DBNAME` com tabelas) | Monte o volume certo ou, para reinstalar, apague os bancos `DBNAME` e `asteriskcdrdb` |

Depois da instalação:

- **Asterisk**: acompanha a imagem. Se o binário mudar, o boot copia por cima `sbin`, `usr/lib64` e a documentação XML; módulos instalados à parte ficam;
- **Configurações do Asterisk**: a atualização não as troca. `pjsip_custom_post.conf` e `pjsip.transports_custom.conf` só são copiados na instalação;
- **FreePBX e módulos**: não mudam com a imagem. Atualize com `fwconsole ma upgradeall` ou `FREEPBX_AUTO_UPGRADE=1`.

## Persistência

```text
/data
├── asterisk/                  # Asterisk: binários, configurações, spool e logs
├── web/                       # FreePBX servido pelo Apache
├── cron/crontabs/             # agendamentos (crontabs)
├── fail2ban/                  # banco do fail2ban (banimentos)
│   └── jail.d/                # ajustes do jail (*.local)
└── entrypoint-hooks.d/
    ├── nftables.d/            # .nft aplicados no boot
    └── scripts.d/             # .sh executados no boot
```

O backup é o volume mais os bancos `DBNAME` e `asteriskcdrdb`: um sem o outro não restaura a PBX.

Cada boot acerta os donos:

| Caminho | Dono |
| --- | --- |
| `/data`, `/data/asterisk`, `/data/asterisk/sbin`, `/data/asterisk/usr` | root, sem escrita para grupo e outros |
| `/data/asterisk/etc`, `/data/asterisk/var`, `/data/web` | `asterisk` |
| `/data/entrypoint-hooks.d`, `/data/fail2ban` | root. Se a pasta for de outro dono (volume antigo), volta ao root com todo o conteúdo |

## Supervisão de processos

O `supervisord` é o processo principal do container (PID 1):

| Programa | Reinício automático |
| --- | --- |
| `dbus` | sempre |
| `fail2ban` | sempre |
| `asterisk` | só em queda |
| `cron` | sempre |
| `bootstrap` | não: roda uma vez por boot e inicia o `apache2` |
| `apache2` | sempre |

Logs:

- **`docker logs`**: `dbus`, `fail2ban`, `bootstrap` e `apache2`;
- **Asterisk**: `/data/asterisk/var/log/asterisk/full`;
- **`cron`**: saída descartada.

### Convivência com o `fwconsole`

Rode o `fwconsole` como root, o padrão do `docker exec`.

- **`fwconsole stop`** ou **SIGTERM**: o Asterisk fica parado até `fwconsole start` ou `supervisorctl start asterisk`;
- **Queda** (código diferente de 0, SIGKILL, SIGSEGV) ou **parada nos primeiros 5 s**: o `supervisord` reinicia o Asterisk.

O healthcheck só consulta o Asterisk. Parado por 2 a 2,5 minutos, o container fica `unhealthy` e o Swarm o encerra; com `condition: on-failure`, o serviço fica sem task. Em manutenções, não deixe o Asterisk parado tanto tempo.

## Rede e firewall

O entrypoint carrega o `nftables` antes de qualquer serviço; se falhar, o container não sobe. A entrada é descartada por padrão, exceto:

- **SIP**: 5060 e 5061, TCP e UDP, com limite de conexões novas por origem;
- **RTP**: UDP 10000 a 20000;
- **HTTP (80) por IPv4**: só de `10.5.0.0/16`, a rede do proxy reverso;
- **HTTP (80) por IPv6**: qualquer origem, com limite de taxa, para a validação ACME. Fora da rede do proxy, o Apache só entrega `/.well-known/acme-challenge/` e `/.freepbx-known/`; o resto recebe 403;
- **ICMP e ICMPv6**: erros, ping com limite de taxa e descoberta de vizinhos.

A faixa `10.5.0.0/16` está fixa em `rootfs/etc/nftables.nft` e `rootfs/etc/apache2/apache2.conf`. Com o proxy em outra rede, altere os dois e reconstrua a imagem.

Para liberar outra porta (IAX, WebSocket, SIP em outra porta), crie um hook em `/data/entrypoint-hooks.d/nftables.d/` que acrescente a regra à chain `inet filter input`. Tabela ou chain própria não serve: o que a chain da imagem descarta não volta a ser aceito.

```nft
add rule inet filter input tcp dport 8089 accept
```

## fail2ban

Ignore os IPs fixos de escritórios, troncos, operadoras e monitoramento: a origem de um pacote SIP por UDP pode ser forjada para banir um IP legítimo. A lista fica no volume (`/etc/fail2ban/jail.d` aponta para `/data/fail2ban/jail.d`):

```bash
docker exec -i <container> sh -c 'cat > /data/fail2ban/jail.d/ignoreip.local' <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 <ip> <rede/CIDR>
EOF
docker exec <container> fail2ban-client -t                      # valida a sintaxe
docker exec <container> fail2ban-client reload                  # aplica sem reiniciar a PBX
docker exec <container> fail2ban-client get asterisk ignoreip   # confere a lista em vigor
```

O arquivo substitui a lista da imagem: mantenha `127.0.0.1/8 ::1`. Valide sempre com `-t`: com erro de sintaxe, o `reload` é recusado e, no boot seguinte, o `fail2ban` não sobe e nada é banido.

## Hooks

| Hook | Quando | Se falhar |
| --- | --- | --- |
| `/data/entrypoint-hooks.d/nftables.d/*.nft` | logo após as regras base do firewall | o boot para |
| `/data/entrypoint-hooks.d/scripts.d/*.sh` | no bootstrap, antes do `fwconsole reload` e do Apache | o boot segue |

- Um hook só vale se ele e a pasta dele forem do root, sem escrita para grupo e outros, e não for link simbólico. Fora disso, um `.nft` para o boot e um `.sh` é pulado, com aviso no log;
- Depois dos `.nft`, o boot para se a chain `inet filter input` perdeu a `policy drop` ou a regra de loopback da imagem, como acontece com um `flush ruleset`;
- Os scripts rodam como root, com `bash`, em ordem alfabética, sem `DBROOT_PASSWORD` nem `SMTP_PASSWORD`. Um script que não termina impede o Apache de subir.

Valide um `.nft` antes do próximo boot:

```bash
docker exec <container> nft -c -f /data/entrypoint-hooks.d/nftables.d/<arquivo>.nft
```

Se um hook impedir o boot, corrija-o num container temporário que monte o volume.

## Vivo Voz Negócio (VVN)

Em troncos da VVN, ajuste o `sdp_session` em `pjsip.endpoint_custom_post.conf`, trocando `SIP_TRUNK_NAME` pelo nome do tronco:

```ini
[SIP_TRUNK_NAME](+type=endpoint)
sdp_session=UPTECH/PBX:A22
```

Se o tronco for removido ou renomeado, ajuste o bloco: sem o tronco, o Asterisk ignora o restante desse arquivo.
