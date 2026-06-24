# devspace-kit

Expose the current machine as a secure, remotely-drivable coding workspace —
[DevSpace](https://www.npmjs.com/package/@waishnav/devspace) (a self-hosted MCP
server) published to the public internet through a
[Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/),
with a reusable OAuth + MCP client.

It packages the whole flow into one command set:

```
bootstrap  ->  start  ->  (external MCP client connects)  ->  stop
```

## Why

`DevSpace` turns a real machine into an MCP workspace (`read`/`write`/`edit`/`bash`
over your files). `cloudflared` makes that workspace reachable from anywhere
without opening inbound ports. Together they let an external agent (ChatGPT,
Claude, or the bundled Python client) safely drive this machine. `devspace-kit`
automates install, lifecycle, URL handling, and the OAuth handshake.

## Install

```bash
./bin/devspace-kit bootstrap
```

Installs Node 22 LTS (via nvm), `@waishnav/devspace`, and `cloudflared`. Idempotent.

## Start

```bash
./bin/devspace-kit start
```

- Launches the tunnel with `--protocol http2` (required where outbound QUIC/UDP
  is blocked).
- Parses the fresh `https://<name>.trycloudflare.com` URL.
- Writes `~/.devspace/config.json` (port, allowed roots, public URL) and
  generates an Owner token in `~/.devspace/auth.json` if absent — **no
  interactive `devspace init` needed**.
- Starts `devspace serve` and waits until `/mcp` is live.
- Prints the public `/mcp` URL and Owner token.

Configure via env:

| Var | Default | Meaning |
|-----|---------|---------|
| `DEVSPACE_PORT` | `7676` | Local port |
| `DEVSPACE_ROOTS` | `$HOME` | Comma-separated allowed roots |

## Use the client

The bundled client performs the full MCP OAuth handshake (Dynamic Client
Registration → PKCE authorization with Owner-password approval → token exchange)
and then speaks MCP. It auto-discovers the URL from `state/` and the Owner token
from `~/.devspace/auth.json`.

```bash
./bin/devspace-kit client connect          # handshake + server info
./bin/devspace-kit client list-tools
WS=$(./bin/devspace-kit client open /home/ubuntu/repos/myproj)
./bin/devspace-kit client bash "$WS" "ls -la && git status -s"
./bin/devspace-kit client call write '{"workspaceId":"'"$WS"'","path":"notes.md","content":"hi\n"}'
```

As a library:

```python
from client.devspace_client import DevSpaceClient
c = DevSpaceClient("https://<name>.trycloudflare.com", owner_token="...")
c.connect()
ws = c.open_workspace("/home/ubuntu/repos/myproj")
print(c.bash(ws, "pytest -q"))
```

## Status / stop

```bash
./bin/devspace-kit status
./bin/devspace-kit stop
```

## Layout

```
bin/devspace-kit       dispatcher (bootstrap|start|stop|restart|status|client)
scripts/               bootstrap / start / stop / status
lib/common.sh          shared helpers + state-file paths
client/devspace_client.py   reusable OAuth+MCP client (library + CLI)
state/                 runtime state (public_url, pids, logs) — gitignored
```

## Security

- The Owner token in `~/.devspace/auth.json` and `state/` are **secrets**.
  `state/` is gitignored; never commit the token.
- Quick (account-less) tunnels are **ephemeral**: the URL changes on every
  `start` and dies with the process. `start` re-points DevSpace at the new URL
  automatically.
- Anyone with the public URL **and** the Owner token can drive this machine.
  Treat them like SSH credentials.

## Requirements

Linux with `nvm`, `curl`, `python3`, `sudo` (for the `cloudflared` `.deb`).
Node `>=22.19` (DevSpace dependency). `pip install -r client/requirements.txt`.
