#!/usr/bin/env bash
# Stop the DevSpace server and the Cloudflare tunnel.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

stop_one() {
  local name="$1" pidfile="$2"
  local pid; pid="$(read_pid "$pidfile")"
  if pid_alive "$pid"; then
    log "Stopping $name (pid $pid)..."
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 10); do pid_alive "$pid" || break; sleep 0.3; done
    pid_alive "$pid" && kill -9 "$pid" 2>/dev/null || true
  else
    log "$name not running."
  fi
  rm -f "$pidfile"
}

stop_one "devspace serve" "$SERVE_PID_FILE"
stop_one "cloudflared tunnel" "$TUNNEL_PID_FILE"
rm -f "$URL_FILE"
log "Stopped."
