#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FRONTEND_CLIENT_DIR="$(cd "$ROOT_DIR/../.." && pwd)/frontend/var1-client"
RUN_TIMEOUT_SECONDS=90
BRIDGE_PORT=4311
SMOKE_DIR="$ROOT_DIR/.zig-cache/smoke"
SANITY_PROMPT='Count the lowercase letter r in this exact character sequence: s t r a w b e r r y. Return only the number.'
BRIDGE_PID=""

to_windows_path() {
  local path="$1"
  if command -v wslpath >/dev/null 2>&1; then
    wslpath -w "$path"
    return
  fi
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$path"
    return
  fi
  printf '%s\n' "$path"
}

if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* || -n "${MSYSTEM:-}" ]]; then
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(to_windows_path "$SCRIPT_DIR/local_gemma_smoke.ps1")" -Port "$BRIDGE_PORT"
fi

WINDOWS_ROOT="$(to_windows_path "$ROOT_DIR")"

cd "$ROOT_DIR"
mkdir -p "$SMOKE_DIR"

BRIDGE_OUT="$SMOKE_DIR/bridge-out.txt"
BRIDGE_ERR="$SMOKE_DIR/bridge-err.txt"

if ! grep -q '^BASE_URL=http://127.0.0.1:1234$' .env; then
  echo "GEMMA_LOCAL expected BASE_URL=http://127.0.0.1:1234 in .env" >&2
  exit 1
fi

if ! grep -q '^MODEL=gemma-4-26b-a4b-it-apex$' .env; then
  echo "GEMMA_LOCAL expected MODEL=gemma-4-26b-a4b-it-apex in .env" >&2
  exit 1
fi

provider_models_url() {
  local base_url="$1"
  base_url="${base_url%/}"
  if [[ "$base_url" =~ /v[0-9]+$ ]]; then
    printf '%s/models\n' "$base_url"
    return
  fi
  printf '%s/v1/models\n' "$base_url"
}

BASE_URL="$(grep '^BASE_URL=' .env | cut -d= -f2-)"
API_KEY="$(grep '^API_KEY=' .env | cut -d= -f2-)"
MODEL="$(grep '^MODEL=' .env | cut -d= -f2-)"
PROVIDER_MODELS_URL="$(provider_models_url "$BASE_URL")"
models_payload="$(curl -fsS -H "Authorization: Bearer $API_KEY" "$PROVIDER_MODELS_URL")" || {
  echo "GEMMA_LOCAL expected reachable provider at $PROVIDER_MODELS_URL" >&2
  exit 1
}

if ! python3 - <<'PY' "$models_payload" "$MODEL"
import json, sys
payload = json.loads(sys.argv[1])
target = sys.argv[2]
available = [item.get("id", "") for item in payload.get("data", [])]
if target in available:
    raise SystemExit(0)
print("GEMMA_LOCAL expected model %s to be served. Available models: %s" % (target, ", ".join(available) or "<none>"), file=sys.stderr)
raise SystemExit(1)
PY
then
  exit 1
fi

run_windows_var1() {
  local label="$1"
  shift

  local output
  if ! output="$(run_with_optional_timeout "$ROOT_DIR/zig-out/bin/VAR1.exe" "$@" | sed 's/\r$//')"; then
    echo "GEMMA_LOCAL $label timed out or failed before completion" >&2
    return 1
  fi

  printf '%s\n' "$output"
  REPLY="$output"
}

run_with_optional_timeout() {
  if command -v timeout >/dev/null 2>&1 && timeout --version >/dev/null 2>&1; then
    timeout "$RUN_TIMEOUT_SECONDS" "$@"
    return
  fi

  "$@"
}

get_bridge_owner() {
  powershell.exe -NoProfile -Command "\$connection = Get-NetTCPConnection -LocalPort $BRIDGE_PORT -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1; if (\$connection) { \$process = Get-Process -Id \$connection.OwningProcess -ErrorAction SilentlyContinue; if (\$process) { Write-Output (\$process.Id.ToString() + '|' + \$process.ProcessName) } }" | tr -d '\r'
}

clear_bridge_port() {
  local owner
  owner="$(get_bridge_owner)"
  if [[ -z "$owner" ]]; then
    return 0
  fi

  local pid="${owner%%|*}"
  local name="${owner#*|}"
  if [[ "$name" != "VAR1" ]]; then
    echo "GEMMA_LOCAL bridge port $BRIDGE_PORT is already owned by non-VAR1 process $name (PID $pid)" >&2
    return 1
  fi

  cmd.exe /c "taskkill /F /PID $pid" >/dev/null 2>&1
}

start_bridge() {
  clear_bridge_port
  rm -f "$BRIDGE_OUT" "$BRIDGE_ERR" "$ROOT_DIR/bridge-out.txt" "$ROOT_DIR/bridge-err.txt"
  "$ROOT_DIR/zig-out/bin/VAR1.exe" serve --host 127.0.0.1 --port "$BRIDGE_PORT" > "$BRIDGE_OUT" 2> "$BRIDGE_ERR" &
  BRIDGE_PID="$!"
}

stop_started_bridge() {
  if [[ -n "${BRIDGE_PID:-}" ]]; then
    kill "$BRIDGE_PID" >/dev/null 2>&1 || true
    wait "$BRIDGE_PID" 2>/dev/null || true
    BRIDGE_PID=""
  fi
  clear_bridge_port || true
}

windows_http_get() {
  local path="$1"
  local output_file="$2"
  rm -f "$output_file"
  curl.exe -fsS "http://127.0.0.1:$BRIDGE_PORT$path" | sed 's/\r$//' > "$output_file"
  cat "$output_file"
}

json_string_param() {
  local key="$1"
  local value="$2"
  python3 - <<'PY' "$key" "$value"
import json, sys
print(json.dumps({sys.argv[1]: sys.argv[2]}))
PY
}

windows_rpc_call() {
  local method="$1"
  local params_json="$2"
  local request_file="$3"
  local output_file="$4"
  local windows_request_file

  python3 - <<'PY' "$method" "$params_json" > "$request_file"
import json, sys
method = sys.argv[1]
params = json.loads(sys.argv[2])
print(json.dumps({
    "jsonrpc": "2.0",
    "id": "gemma-smoke",
    "method": method,
    "params": params,
}))
PY

  windows_request_file="$(to_windows_path "$request_file")"
  rm -f "$output_file"
  curl.exe -fsS -X POST \
    -H "Content-Type: application/json" \
    -H "X-VAR1-Bridge-Token: $BRIDGE_TOKEN" \
    --data-binary "@$windows_request_file" \
    "http://127.0.0.1:$BRIDGE_PORT/rpc" | sed 's/\r$//' > "$output_file"
  cat "$output_file"
}

echo "GEMMA_LOCAL suite"
./scripts/zigw.sh build test --summary all

echo "GEMMA_LOCAL windows build"
./scripts/zigw.sh build -Dtarget=x86_64-windows-gnu --summary all

prompt_file="$(mktemp "$SMOKE_DIR/gemma-delegated-prompt.XXXXXX.txt")"
trap 'rm -f "$prompt_file"' EXIT
cat > "$prompt_file" <<'EOF'
Launch a child agent named berry-child.
Child prompt: Count the lowercase letter r in this exact character sequence: s t r a w b e r r y. Return only the number.
Use agent_status as the primary supervision surface.
Use wait_agent only when you are ready to collect a current or terminal snapshot.
Return only the child's final answer and nothing else.
EOF
WINDOWS_PROMPT_FILE="$(to_windows_path "$prompt_file")"

echo "GEMMA_LOCAL direct run"
run_windows_var1 "direct-run" run --prompt "$SANITY_PROMPT"
direct_run_output="$REPLY"
if [[ "$direct_run_output" != *"3"* ]]; then
  echo "GEMMA_LOCAL direct run did not clearly report 3" >&2
  exit 1
fi

echo "GEMMA_LOCAL delegated"
run_windows_var1 "delegated" run --prompt-file "$WINDOWS_PROMPT_FILE"
delegated_output="$REPLY"
if [[ "$delegated_output" != *"3"* ]]; then
  echo "GEMMA_LOCAL delegated run did not clearly report 3" >&2
  exit 1
fi

echo "GEMMA_LOCAL bridge"
start_bridge

health_file="$(mktemp "$SMOKE_DIR/gemma-bridge-health.XXXXXX.json")"
create_output_file="$(mktemp "$SMOKE_DIR/gemma-bridge-create.XXXXXX.json")"
detail_output_file="$(mktemp "$SMOKE_DIR/gemma-bridge-detail.XXXXXX.json")"
journal_output_file="$(mktemp "$SMOKE_DIR/gemma-bridge-journal.XXXXXX.json")"
trap 'rm -f "$prompt_file" "${bridge_request:-}" "$health_file" "$create_output_file" "$detail_output_file" "$journal_output_file"; stop_started_bridge' EXIT

health_output=""
for _ in $(seq 1 40); do
  if health_output="$(windows_http_get "/api/health" "$health_file")"; then
    break
  fi
  sleep 1
done

if [[ "$health_output" != *"gemma-4-26b-a4b-it-apex"* ]]; then
  echo "GEMMA_LOCAL bridge health did not report the active gemma model" >&2
  exit 1
fi

if [[ ! -f "$FRONTEND_CLIENT_DIR/index.html" ]]; then
  echo "GEMMA_LOCAL expected external browser client at $FRONTEND_CLIENT_DIR" >&2
  exit 1
fi

bridge_home="$(windows_http_get "/" "$health_file")"
if [[ "$bridge_home" != *"VAR1 HTTP bridge ready"* ]]; then
  echo "GEMMA_LOCAL bridge root did not return bridge-only text" >&2
  exit 1
fi
if [[ "$bridge_home" != *"apps/frontend/var1-client"* ]]; then
  echo "GEMMA_LOCAL bridge root did not point operators to apps/frontend/var1-client" >&2
  exit 1
fi

bridge_request="$(mktemp "$SMOKE_DIR/gemma-bridge-request.XXXXXX.json")"
BRIDGE_TOKEN="$(python3 - <<'PY' "$health_output"
import json, sys
payload = json.loads(sys.argv[1])
print(payload["bridge_token"])
PY
)"

if [[ -z "$BRIDGE_TOKEN" ]]; then
  echo "GEMMA_LOCAL bridge health did not return a bridge token" >&2
  exit 1
fi

create_params="$(json_string_param "prompt" "$SANITY_PROMPT")"
create_output="$(windows_rpc_call "session/create" "$create_params" "$bridge_request" "$create_output_file")"

session_id="$(python3 - <<'PY' "$create_output"
import json, sys
payload = json.loads(sys.argv[1])
print(payload["result"]["session"]["session_id"])
PY
)"

if [[ -z "$session_id" ]]; then
  echo "GEMMA_LOCAL bridge RPC create did not return a session id" >&2
  exit 1
fi

send_params="$(json_string_param "session_id" "$session_id")"
send_output="$(windows_rpc_call "session/send" "$send_params" "$bridge_request" "$detail_output_file")"
if ! python3 - <<'PY' "$send_output"
import json, sys
payload = json.loads(sys.argv[1])
session = payload["result"]["session"]
status = session["status"]
answer = session.get("output") or ""
raise SystemExit(0 if status == "completed" and "3" in answer else 1)
PY
then
  echo "GEMMA_LOCAL bridge RPC session did not complete with the expected answer" >&2
  exit 1
fi

get_params="$(json_string_param "session_id" "$session_id")"
detail_output="$(windows_rpc_call "session/get" "$get_params" "$bridge_request" "$journal_output_file")"
if [[ "$detail_output" != *"assistant_response"* ]]; then
  echo "GEMMA_LOCAL bridge RPC detail did not expose assistant_response" >&2
  exit 1
fi

echo "GEMMA_LOCAL bridge ok"
