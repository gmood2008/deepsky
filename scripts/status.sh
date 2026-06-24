#!/usr/bin/env bash
# Show current tunnel / server status.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

show() {
  local name="$1" pidfile="$2"
  local pid; pid="$(read_pid "$pidfile")"
  if pid_alive "$pid"; then
    printf '  %-20s \033[1;32mrunning\033[0m (pid %s)\n' "$name" "$pid"
  else
    printf '  %-20s \033[1;31mstopped\033[0m\n' "$name"
  fi
}

echo "devspace-kit status:"
show "cloudflared tunnel" "$TUNNEL_PID_FILE"
show "devspace serve"     "$SERVE_PID_FILE"

URL="$(cat "$URL_FILE" 2>/dev/null || true)"
if [ -n "$URL" ]; then
  echo "  public MCP URL     : $URL/mcp"
  code="$(curl -s -o /dev/null -w '%{http_code}' "$URL/mcp" --max-time 8 || echo '---')"
  echo "  public /mcp probe  : HTTP $code (401 = up & protected)"
fi
local_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/mcp" --max-time 4 || echo '---')"
echo "  local  /mcp probe  : HTTP $local_code"
