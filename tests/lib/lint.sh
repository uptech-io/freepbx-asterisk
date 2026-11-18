# shellcheck shell=bash

phase_lint() {
  local f out bad=0 sh=(rootfs/usr/local/bin/docker-entrypoint rootfs/usr/local/bin/docker-bootstrap
                        rootfs/usr/local/bin/docker-entrypoint.d/*.sh build.sh tests/*.sh)
  # tests/lib is not listed for shellcheck: -x follows the "source" lines of run.sh and -a reports what
  # it finds there. Checked alone, each file would report the variables it shares with the others.
  local lib=(tests/lib/*.sh)
  for f in "${sh[@]}" "${lib[@]}"; do out=$(bash -n "$f" 2>&1) || { fail "S1 bash -n $f"; ev <<<"$out"; bad=1; }; done
  out=$(sh -n rootfs/usr/local/bin/safe_asterisk 2>&1) || { fail "S1 sh -n safe_asterisk"; ev <<<"$out"; bad=1; }
  (( bad )) || ok "S1 syntax of $(( ${#sh[@]} + ${#lib[@]} + 1 )) scripts"
  if command -v shellcheck >/dev/null; then
    out=$({ shellcheck -S warning -x -a -s bash -f gcc "${sh[@]}"; shellcheck -S warning -s sh -f gcc rootfs/usr/local/bin/safe_asterisk; } 2>&1)
    if [[ -z $out ]]; then ok "S2 shellcheck clean"; else warn "S2 shellcheck: $(wc -l <<<"$out") findings"; ev <<<"$out"; fi
  else warn "S2 shellcheck not installed"; fi
  if command -v hadolint >/dev/null; then
    out=$(hadolint Dockerfile 2>&1) && ok "S3 hadolint clean" || { warn "S3 hadolint findings"; ev <<<"$out"; }
  else warn "S3 hadolint not installed"; fi
}
