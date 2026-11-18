# shellcheck shell=bash

phase_build() {
  local out
  echo "    log: $RUN/build.log"
  if ! dk build -t "$IMAGE" . >"$RUN/build.log" 2>&1; then
    fail "build of $IMAGE"; tail -n 30 "$RUN/build.log" | ev; SKIP='build failed'; return
  fi
  ok "build of $IMAGE"
  out=$(dk image inspect -f '{{.Config.StopSignal}} {{json .Config.Cmd}} {{json .Config.Entrypoint}} {{json .Config.Healthcheck}}' "$IMAGE")
  if [[ $out == 'SIGTERM ["supervisord",'*'] ["docker-entrypoint"] {"Test":'* ]]; then ok "I1 StopSignal, Cmd, Entrypoint, Healthcheck"
  else fail "I1 image metadata"; ev <<<"$out"; fi
}
