---
name: devspace-remote-workspace
description: Expose this machine as a DevSpace MCP coding workspace over a Cloudflare tunnel, and drive it with the bundled OAuth+MCP client. Use when asked to set up DevSpace, expose a workspace to ChatGPT/Claude/an MCP client, or run the tunnel+serve+OAuth flow.
---

# DevSpace remote workspace (devspace-kit)

Turns this machine into a remotely-drivable MCP coding workspace:
`@waishnav/devspace` (self-hosted MCP server) + `cloudflared` tunnel + OAuth.

## Commands (from repo root)

```bash
./bin/devspace-kit bootstrap   # install Node 22, devspace, cloudflared (idempotent)
./bin/devspace-kit start       # tunnel(http2) + serve; prints public /mcp URL + Owner token
./bin/devspace-kit status      # running state + /mcp probe (401 = up & protected)
./bin/devspace-kit stop
./bin/devspace-kit client list-tools
./bin/devspace-kit client open <abs-path>   # -> prints workspaceId
./bin/devspace-kit client bash <wsId> "<cmd>"
```

## Critical gotchas

- **Force http2.** This environment blocks outbound QUIC/UDP (port 7844). The
  tunnel MUST run with `--protocol http2`, otherwise it never registers and the
  public URL returns HTTP 530. `start.sh` already does this.
- **URL drifts every start.** Quick tunnels mint a new `*.trycloudflare.com`
  host each run and die with the process. `start` re-points DevSpace via the
  config's `publicBaseUrl` automatically and saves it to `state/public_url`.
- **No interactive init needed.** `~/.devspace/config.json` and `auth.json` are
  plain JSON; `start.sh` writes them directly (and generates an Owner token if
  missing), avoiding the interactive `devspace init` prompts.
- **OAuth requires a `resource` param.** The `/authorize` and `/token` calls must
  include `resource=<base>/mcp` (RFC 8707), else `invalid_request`. The client
  handles this.
- **MCP transport** is Streamable HTTP: send `Accept: application/json,
  text/event-stream`, capture `mcp-session-id` from the `initialize` response,
  and send `notifications/initialized` before `tools/list`/`tools/call`.

## OAuth flow (what the client does)

1. `POST /register` (Dynamic Client Registration) → `client_id`.
2. `POST /authorize` with PKCE (`S256`) + `owner_token` (the Owner password) →
   302 redirect carrying `code`.
3. `POST /token` with `code` + `code_verifier` + `resource` → `access_token`.
4. MCP `initialize` → `notifications/initialized` → `tools/list` / `tools/call`
   with `Authorization: Bearer <token>`.

## Tools exposed by DevSpace

`open_workspace` (call first, returns `workspaceId`), `read`, `write`, `edit`,
`bash` (read-only/test/build use; not for writing files).

## Secrets

Owner token lives in `~/.devspace/auth.json` and is echoed by `start`. With the
public URL it grants full machine access — treat like SSH creds. `state/` is
gitignored; never commit it.
