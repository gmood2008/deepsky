#!/usr/bin/env bash
# Start the Cloudflare tunnel (http2) + DevSpace MCP server, fully unattended.
# Honors env:
#   DEVSPACE_PORT   (default 7676)
#   DEVSPACE_ROOTS  comma-separated allowed roots (default $HOME)

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

load_nvm
have cloudflared || die "cloudflared not found. Run: devspace-kit bootstrap"
have devspace    || die "devspace not found. Run: devspace-kit bootstrap"

DEVSPACE_HOME="$HOME/.devspace"
CONFIG="$DEVSPACE_HOME/config.json"
AUTH="$DEVSPACE_HOME/auth.json"
ROOTS="${DEVSPACE_ROOTS:-$HOME}"

# --- guard against double-start ---
existing="$(read_pid "$SERVE_PID_FILE")"
if pid_alive "$existing"; then
  warn "devspace serve already running (pid $existing). Run 'devspace-kit stop' first."
  exit 1
fi

# --- 1. start tunnel ---
log "Starting cloudflared tunnel (http2) -> http://localhost:$PORT ..."
: > "$TUNNEL_LOG"
nohup cloudflared tunnel --protocol http2 --url "http://localhost:$PORT" >>"$TUNNEL_LOG" 2>&1 &
echo $! > "$TUNNEL_PID_FILE"

# --- 2. parse public URL ---
PUBLIC_URL=""
for _ in $(seq 1 30); do
  PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | head -1 || true)"
  [ -n "$PUBLIC_URL" ] && break
  sleep 1
done
[ -n "$PUBLIC_URL" ] || { err "Failed to obtain tunnel URL. See $TUNNEL_LOG"; exit 1; }
echo "$PUBLIC_URL" > "$URL_FILE"
log "Public URL: $PUBLIC_URL"

# --- 3. ensure DevSpace config + auth (no interactive init) ---
mkdir -p "$DEVSPACE_HOME"
if [ ! -f "$AUTH" ]; then
  TOKEN="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
  python3 -c "import json,sys;json.dump({'ownerToken':sys.argv[1]},open(sys.argv[2],'w'),indent=2)" "$TOKEN" "$AUTH"
  chmod 600 "$AUTH"
  log "Generated new Owner token at $AUTH"
fi
ROOTS="$ROOTS" PORT="$PORT" PUBLIC_URL="$PUBLIC_URL" CONFIG="$CONFIG" python3 - <<'PY'
import json, os
cfg_path = os.environ["CONFIG"]
roots = [r for r in os.environ["ROOTS"].split(",") if r]
cfg = {}
if os.path.exists(cfg_path):
    try: cfg = json.load(open(cfg_path))
    except Exception: cfg = {}
cfg["host"] = "127.0.0.1"
cfg["port"] = int(os.environ["PORT"])
cfg["allowedRoots"] = roots
cfg["publicBaseUrl"] = os.environ["PUBLIC_URL"]
json.dump(cfg, open(cfg_path, "w"), indent=2)
print("config written:", cfg_path)
PY

# --- 4. start devspace serve ---
log "Starting devspace serve ..."
: > "$SERVE_LOG"
nohup devspace serve >>"$SERVE_LOG" 2>&1 &
echo $! > "$SERVE_PID_FILE"

# --- 5. wait until /mcp answers (401 = up & protected) ---
ok=""
for _ in $(seq 1 20); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/mcp" || true)"
  [ "$code" = "401" ] || [ "$code" = "200" ] && { ok=1; break; }
  sleep 1
done
[ -n "$ok" ] || { err "devspace serve did not come up. See $SERVE_LOG"; exit 1; }

OWNER="$(python3 -c "import json;print(json.load(open('$AUTH'))['ownerToken'])")"
cat >&2 <<EOF

$(printf '\033[1;32m✔ DevSpace is live\033[0m')
  Public MCP URL : $PUBLIC_URL/mcp
  Local MCP URL  : http://127.0.0.1:$PORT/mcp
  Owner token    : $OWNER
  Allowed roots  : $ROOTS

Connect a client:
  devspace-kit client list-tools
EOF
