#!/usr/bin/env bash
# Launch carrolinha-BE and carrolinha-FE together for local development.
#
#   ./dev.sh                      # backend from :8000, frontend from :5173
#   BE_PORT=9000 FE_PORT=3000 ./dev.sh
#
# Each port is the first free one at or above the requested value. The frontend
# is always pointed at the port the backend actually started on, overriding any
# VITE_API_URL / VITE_AI_ENDPOINT in carrolinha-FE/.env*, and the frontend's
# origin is added to the backend's CARROLINHA_ALLOWED_ORIGINS so the planner
# accepts it. Ctrl+C stops both.
#
# Works with the bash 3.2 that ships with macOS.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_DIR="$ROOT/carrolinha-BE"
FE_DIR="$ROOT/carrolinha-FE"

BE_PORT="${BE_PORT:-8000}"
FE_PORT="${FE_PORT:-5173}"
BE_HOST="${BE_HOST:-127.0.0.1}"
BE_START_TIMEOUT="${BE_START_TIMEOUT:-120}"   # first run may include `uv sync`
FE_START_TIMEOUT="${FE_START_TIMEOUT:-60}"
MAX_PORT_TRIES=50

BE_PID=""
FE_PID=""

# ------------------------------------------------------------------ output
if [ -t 1 ]; then
  C_BE=$'\033[36m' C_FE=$'\033[35m' C_OK=$'\033[32m' C_WARN=$'\033[33m' C_ERR=$'\033[31m' C_OFF=$'\033[0m'
else
  C_BE="" C_FE="" C_OK="" C_WARN="" C_ERR="" C_OFF=""
fi

info() { printf '%s[dev]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s[dev]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s[dev]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

# Prefix every line of a child's output, e.g. "[BE] INFO: ...".
prefix() {
  local tag="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s[%s]%s %s\n' "$2" "$tag" "$C_OFF" "$line"
  done
}

# ------------------------------------------------------------------ helpers
# Print KEY's value from a dotenv file (last assignment wins, quotes stripped).
env_file_get() {
  local file="$1" key="$2" line
  [ -f "$file" ] || return 1
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" | tail -n 1)"
  [ -n "$line" ] || return 1
  line="${line#*=}"
  line="${line%$'\r'}"
  line="${line#[\"\']}"
  line="${line%[\"\']}"
  [ -n "$line" ] || return 1
  printf '%s' "$line"
}

port_in_use() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1
  else
    python3 - "$1" <<'PY'
import socket, sys
port = int(sys.argv[1])
for family, host in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
    try:
        with socket.socket(family) as s:
            s.settimeout(0.3)
            if s.connect_ex((host, port)) == 0:
                sys.exit(0)
    except OSError:
        pass
sys.exit(1)
PY
  fi
}

find_free_port() {
  local port="$1" last=$(( $1 + MAX_PORT_TRIES ))
  while [ "$port" -lt "$last" ]; do
    if ! port_in_use "$port"; then
      printf '%s' "$port"
      return 0
    fi
    port=$(( port + 1 ))
  done
  return 1
}

# Start a command in the background in its own process group, so stop_job can
# kill the whole tree (uv -> uvicorn reloader -> worker, npm -> vite). Job control
# is on only for the launch: left on, every foreground command (sleep, curl) would
# also get its own group, and Ctrl+C would reach that command instead of this script.
# stdin is /dev/null because a background group that reads the terminal is stopped
# (Vite reads it for its keyboard shortcuts).
spawn() {
  local tag="$1" color="$2"
  shift 2
  set -m
  "$@" < /dev/null > >(prefix "$tag" "$color") 2>&1 &
  SPAWNED_PID=$!
  set +m
}

# Stop a spawned job and everything it started; SIGKILL whatever is left after 5s.
stop_job() {
  local pid="$1" waited=0
  [ -n "$pid" ] || return 0
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
  while kill -0 -- "-$pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  kill -KILL -- "-$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

cleanup() {
  trap - EXIT
  trap '' INT TERM   # a second Ctrl+C must not abandon the servers mid-cleanup
  [ -n "$FE_PID$BE_PID" ] && info "Stopping..."
  stop_job "$FE_PID"
  stop_job "$BE_PID"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ------------------------------------------------------------------ preflight
[ -d "$BE_DIR" ] || die "Missing $BE_DIR (run: git submodule update --init)"
[ -d "$FE_DIR" ] || die "Missing $FE_DIR (run: git submodule update --init)"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v npm  >/dev/null 2>&1 || die "npm is required"

if command -v uv >/dev/null 2>&1; then
  BE_CMD=(uv run uvicorn)
elif [ -x "$BE_DIR/.venv/bin/uvicorn" ]; then
  BE_CMD=("$BE_DIR/.venv/bin/uvicorn")
else
  die "Install uv (https://docs.astral.sh/uv/) or create carrolinha-BE/.venv with requirements.txt"
fi

if [ ! -d "$FE_DIR/node_modules" ]; then
  info "Installing frontend dependencies..."
  (cd "$FE_DIR" && npm install) || die "npm install failed"
fi

# ------------------------------------------------------------------ backend env
# Real environment variables win over carrolinha-BE/.env (app/planner.py only
# fills in values that are not already set), so anything exported here must
# preserve what the user configured in either place.
BE_ENV=()

# The OpenAI key belongs in carrolinha-BE/.env. Fall back to carrolinha-FE/.env,
# where it has been kept, so the planner still works; Vite never exposes non-VITE_ vars.
for key in OPENAI_API_KEY OPENAI_MODEL; do
  if [ -z "${!key:-}" ] && ! env_file_get "$BE_DIR/.env" "$key" >/dev/null; then
    if value="$(env_file_get "$FE_DIR/.env" "$key")"; then
      BE_ENV+=("$key=$value")
      [ "$key" = OPENAI_API_KEY ] && warn "Using OPENAI_API_KEY from carrolinha-FE/.env; move it to carrolinha-BE/.env."
    elif [ "$key" = OPENAI_API_KEY ]; then
      warn "No OPENAI_API_KEY found; the AI planner will return 503."
    fi
  fi
done

# ------------------------------------------------------------------ ports
FE_PORT="$(find_free_port "$FE_PORT")" || die "No free frontend port in $FE_PORT..$(( FE_PORT + MAX_PORT_TRIES ))"
FE_URL="http://localhost:$FE_PORT"

origins="${CARROLINHA_ALLOWED_ORIGINS:-$(env_file_get "$BE_DIR/.env" CARROLINHA_ALLOWED_ORIGINS || true)}"
origins="${origins:-http://localhost:5173,http://localhost:5174,http://127.0.0.1:5173,http://127.0.0.1:5174}"
BE_ENV+=("CARROLINHA_ALLOWED_ORIGINS=$origins,http://localhost:$FE_PORT,http://127.0.0.1:$FE_PORT")

# The URL the browser uses to reach the backend.
if [ "$BE_HOST" = "0.0.0.0" ] || [ "$BE_HOST" = "::" ]; then BE_REACH_HOST=127.0.0.1; else BE_REACH_HOST="$BE_HOST"; fi

# ------------------------------------------------------------------ start backend
run_backend() {
  cd "$BE_DIR" || exit 1
  unset VIRTUAL_ENV   # an active conda/venv would make uv warn; uv uses the project .venv
  for kv in ${BE_ENV[@]+"${BE_ENV[@]}"}; do export "$kv"; done
  export PYTHONUNBUFFERED=1
  exec "${BE_CMD[@]}" app.main:app --reload --host "$BE_HOST" --port "$1"
}

start_backend() {
  spawn BE "$C_BE" run_backend "$1"
  BE_PID=$SPAWNED_PID
}

# 0 = healthy, 1 = process exited, 2 = timed out
wait_for_backend() {
  local url="http://$BE_REACH_HOST:$1/api/health" waited=0
  while [ "$waited" -lt "$BE_START_TIMEOUT" ]; do
    kill -0 "$BE_PID" 2>/dev/null || return 1
    curl -fsS --max-time 2 "$url" 2>/dev/null | grep -q '"ok"' && return 0
    sleep 1
    waited=$(( waited + 1 ))
  done
  return 2
}

port="$(find_free_port "$BE_PORT")" || die "No free backend port in $BE_PORT..$(( BE_PORT + MAX_PORT_TRIES ))"
while :; do
  [ "$port" = "$BE_PORT" ] || warn "Port $BE_PORT is busy; backend will use $port."
  info "Starting backend on $BE_REACH_HOST:$port..."
  start_backend "$port"
  wait_for_backend "$port"
  case $? in
    0) break ;;
    2) die "Backend did not become healthy within ${BE_START_TIMEOUT}s." ;;
  esac
  # The process exited. If the port was taken between the check and the bind, try the next one.
  wait "$BE_PID" 2>/dev/null
  BE_PID=""
  port_in_use "$port" || die "Backend exited during startup; see the [BE] output above."
  port="$(find_free_port $(( port + 1 )))" || die "No free backend port found."
done
API_URL="http://$BE_REACH_HOST:$port"

# The frontend needs endpoints that only exist on newer backend branches.
if ! curl -fsS --max-time 5 "$API_URL/openapi.json" 2>/dev/null | grep -q '"/api/planner"'; then
  warn "This backend checkout ($(git -C "$BE_DIR" branch --show-current 2>/dev/null || echo '?')) has no /api/planner."
  warn "The AI planner and journey-path views will fail; check out feature/journey-traffic in carrolinha-BE."
fi

# ------------------------------------------------------------------ start frontend
# Variables already in the environment take priority over Vite's .env files, so
# these override the Render URL (or anything else) configured in carrolinha-FE/.env*.
info "Starting frontend on $FE_URL (API: $API_URL)..."
run_frontend() {
  cd "$FE_DIR" || exit 1
  export VITE_API_URL="$API_URL"
  export VITE_AI_ENDPOINT="$API_URL/api/planner"
  exec npm run dev -- --port "$FE_PORT" --strictPort
}
spawn FE "$C_FE" run_frontend
FE_PID=$SPAWNED_PID

waited=0
until curl -fsS --max-time 2 -o /dev/null "$FE_URL" 2>/dev/null; do
  kill -0 "$FE_PID" 2>/dev/null || die "Frontend exited during startup; see the [FE] output above."
  [ "$waited" -lt "$FE_START_TIMEOUT" ] || die "Frontend did not respond within ${FE_START_TIMEOUT}s."
  sleep 1
  waited=$(( waited + 1 ))
done

info "Ready."
info "  Frontend  $FE_URL"
info "  Backend   $API_URL  (docs: $API_URL/docs)"
info "Press Ctrl+C to stop both."

# ------------------------------------------------------------------ supervise
# bash 3.2 has no `wait -n`, so poll: when either side exits, stop the other.
while kill -0 "$BE_PID" 2>/dev/null && kill -0 "$FE_PID" 2>/dev/null; do
  sleep 1
done
kill -0 "$BE_PID" 2>/dev/null || warn "Backend stopped."
kill -0 "$FE_PID" 2>/dev/null || warn "Frontend stopped."
exit 1
