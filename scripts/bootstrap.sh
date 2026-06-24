#!/usr/bin/env bash
# Install prerequisites: Node 22 LTS, @waishnav/devspace, cloudflared.
# Idempotent — safe to re-run.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

NODE_MAJOR=22

install_node() {
  load_nvm
  if have nvm; then
    log "Installing Node $NODE_MAJOR via nvm..."
    nvm install "$NODE_MAJOR" --latest-npm >/dev/null
    nvm alias default "$NODE_MAJOR" >/dev/null
    nvm use "$NODE_MAJOR" >/dev/null
  elif have node; then
    warn "nvm not found; using system node $(node -v)"
  else
    die "Neither nvm nor node found. Install Node >=22.19 first."
  fi
  log "node: $(node -v), npm: $(npm -v)"
}

install_devspace() {
  if have devspace; then
    log "devspace already installed: $(command -v devspace)"
  else
    log "Installing @waishnav/devspace globally..."
    npm install -g @waishnav/devspace >/dev/null
  fi
}

install_cloudflared() {
  if have cloudflared; then
    log "cloudflared already installed: $(cloudflared --version 2>&1 | head -1)"
    return
  fi
  log "Installing cloudflared..."
  local arch deb
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) deb="cloudflared-linux-amd64.deb" ;;
    aarch64|arm64) deb="cloudflared-linux-arm64.deb" ;;
    *) die "Unsupported arch for cloudflared: $arch" ;;
  esac
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/cf.deb" "https://github.com/cloudflare/cloudflared/releases/latest/download/$deb"
  sudo dpkg -i "$tmp/cf.deb" >/dev/null
  rm -rf "$tmp"
  log "cloudflared: $(cloudflared --version 2>&1 | head -1)"
}

install_node
install_devspace
install_cloudflared
log "Bootstrap complete. Next: devspace-kit start"
