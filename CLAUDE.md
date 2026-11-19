# CLAUDE.md

Docker image of FreePBX 17 on Asterisk 22 for a single-replica Docker Swarm service. No application code: a `Dockerfile`, the `rootfs/` overlay (copied verbatim to `/`) and Bash boot scripts. `README.md` (Portuguese) is the operator contract; read it before changing behaviour.

## Boot

1. `docker-entrypoint` (root, before any service): database wait, IPs, volume, symlinks, firewall, ODBC/sSMTP, then `unset DBROOT_PASSWORD SMTP_PASSWORD` and `exec` supervisord. A failure exits the container.
2. supervisord (PID 1) starts `dbus`, `fail2ban`, `asterisk`, `cron`, `bootstrap`; `apache2` has `autostart=false`.
3. `docker-bootstrap` (one-shot): FreePBX install if pending, `.sh` hooks, `fwconsole reload`, starts Apache. Failures are logged and the boot goes on.

Both source functions from `rootfs/usr/local/bin/docker-entrypoint.d/*.sh`.

Not obvious from the code:

- All state lives in `/data`. Every boot deletes the image's `/usr/local/asterisk` and symlinks it, `/etc/asterisk`, `/var/www/html` and `/etc/freepbx.conf` into the volume.
- Installed = `/data/asterisk/etc/asterisk/asterisk.conf` exists. `/data/.freepbx-install-pending` marks an install the bootstrap still has to run.
- Asterisk follows the image (binary compared with `cmp`); FreePBX, its modules and all configuration never change with the image.
- FreePBX `./install` exits 1 even on success: only its last output line tells.
- `fwconsole start` reaches supervisord through the `safe_asterisk` shim; `fwconsole stop` keeps Asterisk down (`autorestart=unexpected`).
- The database schema belongs to the FreePBX installer; this repository has no migrations.

## Commands

```bash
./build.sh                  # cold build compiles Asterisk: tens of minutes
tests/run.sh lint           # no sudo, no daemon
tests/run.sh build image    # needs sudo docker
tests/run.sh                # full battery: needs sudo docker; see tests/README.md
```

## Conventions

- Library files only define functions and have no shebang; the entry scripts source only the libraries they use.
- Shared paths come from `common.sh`. Output goes through `log`, in English, with `Error:` / `Warning:`.
- No `set -e`: handle each error where it happens (`exit 1` in the entrypoint, `return 1` / `failed=1` in the bootstrap).
- Environment defaults are repeated inline (`${DBHOST-db}`): change every occurrence and the README table.
- Comments: English, 1 to 3 lines, only the why.
- `tests/lib/*.sh` grep exact boot log messages (`BAD_LOG`, `in_order`, the G2–G5 checks): changing a log string means updating the test.
- A behaviour change needs its check in `tests/lib/<phase>.sh` and the phase table in `tests/README.md`.
- Commits: Conventional Commits, component scope, Portuguese subject (`fix(entrypoint): ...`), one component per commit.
- READMEs are in Portuguese, short and direct.

## Rules

- No service may listen before `load_nftables_configs`; no secret may survive past the `unset`. Never log variable values.
- Code in the volume stays root's (`/data`, `/data/asterisk`, `sbin`, `usr`), and so do `entrypoint-hooks.d`, `fail2ban` and `cron`; only `asterisk/{etc,var}` and `web` belong to `asterisk`. The boot refuses a symlink in place of those root directories.
- Root never writes through a path the `asterisk` user could have planted as a symlink (see `cp --remove-destination`, `hook_trusted`, `runuser -u asterisk`).
- A hook counts only if it and its directory are root's and not group/other-writable (`hook_trusted`). An untrusted or failing `.nft`, or one that removes the base input rules, stops the boot; an untrusted `.sh` is skipped.
- Do not change the `/data` layout, the install marker, environment variable names or defaults, or the hook contract without authorization: production volumes depend on them. Every boot must stay idempotent and safe to interrupt.
- The proxy range is `PROXY_SUBNET`. Its default (`10.5.0.0/16`) lives only in the Dockerfile `ENV`, not inline: Apache reads it from its environment, also under `docker exec`. `tests/lib/{up,common}.sh` and both READMEs assume that default: change them together.
- Never run anything against a production host or stack. `tests/run.sh up`, `down` and every full run delete the containers, volumes and networks named `$NAME-*` (default `fpbxtest`).
- Justify every new `apt` package.

## Workflow

- The working tree usually holds the developer's uncommitted work: never revert, reformat or stage it. Stay inside the requested scope.
- Work on `master`. Commit only when asked; never push.
- After a change run `tests/run.sh lint`. If the other phases cannot run in the session, give the developer the exact commands and expected result, and report the change as not validated.
- Update `README.md` when operator-visible behaviour changes.
- Report the impact on existing volumes and databases.

## Known inconsistencies

Not patterns to follow; fix only when asked.

- `network.sh` logs `${subnet_prefix}`, never defined.
- `services.sh` hardcodes `/data` instead of `INSTANCE_DIR`.
- FreePBX, ionCube and Asterisk downloads are unpinned; only Asterisk has a checksum.
- Image tags differ between `build.sh`, README, tests and compose.
