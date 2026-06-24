#!/usr/bin/env python3
"""Reusable OAuth + MCP client for a DevSpace server.

Performs the full handshake an MCP client would:
  Dynamic Client Registration (RFC 7591)
    -> Authorization Code + PKCE (RFC 7636) with Owner-password approval
    -> Token exchange
    -> MCP initialize / tools/list / tools/call (Streamable HTTP).

Usable as a library (DevSpaceClient) or a CLI.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import secrets
import sys
import urllib.parse
from pathlib import Path

import requests


class DevSpaceError(RuntimeError):
    pass


class DevSpaceClient:
    def __init__(self, base_url: str, owner_token: str,
                 redirect_uri: str = "http://127.0.0.1:8765/callback",
                 client_name: str = "devspace-kit"):
        self.base = base_url.rstrip("/")
        self.mcp = f"{self.base}/mcp"
        self.owner_token = owner_token
        self.redirect_uri = redirect_uri
        self.client_name = client_name
        self.s = requests.Session()
        self.access_token: str | None = None
        self.session_id: str | None = None
        self._next_id = 0

    # ---- OAuth ----
    def _register(self) -> str:
        r = self.s.post(f"{self.base}/register", json={
            "client_name": self.client_name,
            "redirect_uris": [self.redirect_uri],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        }, timeout=30)
        r.raise_for_status()
        return r.json()["client_id"]

    @staticmethod
    def _pkce() -> tuple[str, str]:
        verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
        challenge = base64.urlsafe_b64encode(
            hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        return verifier, challenge

    def authenticate(self) -> str:
        """Run DCR + PKCE + owner-password approval; returns access token."""
        client_id = self._register()
        verifier, challenge = self._pkce()
        state = secrets.token_hex(8)
        form = {
            "response_type": "code", "client_id": client_id,
            "redirect_uri": self.redirect_uri, "code_challenge": challenge,
            "code_challenge_method": "S256", "scope": "devspace",
            "state": state, "resource": self.mcp, "owner_token": self.owner_token,
        }
        r = self.s.post(f"{self.base}/authorize", data=form,
                        allow_redirects=False, timeout=30)
        loc = r.headers.get("location", "")
        q = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query)
        if "error" in q:
            raise DevSpaceError(f"authorize failed: {q.get('error_description', q['error'])}")
        if q.get("state", [None])[0] != state:
            raise DevSpaceError("OAuth state mismatch")
        code = q["code"][0]
        r = self.s.post(f"{self.base}/token", data={
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": self.redirect_uri, "client_id": client_id,
            "code_verifier": verifier, "resource": self.mcp,
        }, timeout=30)
        r.raise_for_status()
        self.access_token = r.json()["access_token"]
        return self.access_token

    # ---- MCP (Streamable HTTP) ----
    def _headers(self) -> dict:
        h = {
            "Authorization": f"Bearer {self.access_token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session_id:
            h["mcp-session-id"] = self.session_id
        return h

    @staticmethod
    def _parse(resp: requests.Response) -> dict:
        if "text/event-stream" in resp.headers.get("content-type", ""):
            for line in resp.text.splitlines():
                if line.startswith("data:"):
                    return json.loads(line[5:].strip())
            raise DevSpaceError("empty SSE response")
        return resp.json()

    def _rpc(self, method: str, params: dict | None = None, notify: bool = False) -> dict | None:
        body = {"jsonrpc": "2.0", "method": method}
        if not notify:
            self._next_id += 1
            body["id"] = self._next_id
        if params is not None:
            body["params"] = params
        r = self.s.post(self.mcp, headers=self._headers(), data=json.dumps(body), timeout=120)
        if not self.session_id and r.headers.get("mcp-session-id"):
            self.session_id = r.headers["mcp-session-id"]
        if notify:
            return None
        res = self._parse(r)
        if "error" in res:
            raise DevSpaceError(f"{method} error: {res['error']}")
        return res.get("result", {})

    def connect(self) -> dict:
        """Authenticate (if needed) and run the MCP initialize handshake."""
        if not self.access_token:
            self.authenticate()
        result = self._rpc("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": self.client_name, "version": "1.0"},
        })
        self._rpc("notifications/initialized", notify=True)
        return result

    def list_tools(self) -> list[dict]:
        return self._rpc("tools/list").get("tools", [])

    def call_tool(self, name: str, arguments: dict) -> dict:
        out = self._rpc("tools/call", {"name": name, "arguments": arguments})
        texts = [c.get("text", "") for c in out.get("content", []) if c.get("type") == "text"]
        return {"text": "\n".join(texts), "structured": out.get("structuredContent"), "raw": out}

    # ---- convenience wrappers around DevSpace's tools ----
    def open_workspace(self, path: str, mode: str = "checkout") -> str:
        res = self.call_tool("open_workspace", {"path": path, "mode": mode})
        text = res["text"]
        import re
        m = re.search(r"ws_[0-9a-f-]+", text)
        if not m:
            raise DevSpaceError(f"could not parse workspaceId from: {text[:200]}")
        return m.group(0)

    def bash(self, ws: str, command: str, timeout: int = 60) -> str:
        return self.call_tool("bash", {"workspaceId": ws, "command": command, "timeout": timeout})["text"]

    def read(self, ws: str, path: str) -> str:
        return self.call_tool("read", {"workspaceId": ws, "path": path})["text"]

    def write(self, ws: str, path: str, content: str) -> str:
        return self.call_tool("write", {"workspaceId": ws, "path": path, "content": content})["text"]


# ---------------- CLI ----------------
def _state_url() -> str | None:
    here = Path(__file__).resolve().parent.parent
    f = Path(os.environ.get("DEVSPACE_KIT_STATE", here / "state")) / "public_url"
    return f.read_text().strip() if f.exists() else None


def _owner_token() -> str | None:
    auth = Path.home() / ".devspace" / "auth.json"
    if auth.exists():
        return json.load(open(auth)).get("ownerToken")
    return None


def _make_client(args) -> DevSpaceClient:
    url = args.url or os.environ.get("DEVSPACE_URL") or _state_url()
    if not url:
        raise SystemExit("No DevSpace URL. Start the server or pass --url / DEVSPACE_URL.")
    owner = args.owner or os.environ.get("DEVSPACE_OWNER_TOKEN") or _owner_token()
    if not owner:
        raise SystemExit("No owner token. Pass --owner or set DEVSPACE_OWNER_TOKEN.")
    c = DevSpaceClient(url, owner)
    c.connect()
    return c


def main(argv=None):
    p = argparse.ArgumentParser(description="DevSpace OAuth+MCP client")
    p.add_argument("--url", help="Public base URL (default: from state/ or $DEVSPACE_URL)")
    p.add_argument("--owner", help="Owner token (default: ~/.devspace/auth.json or $DEVSPACE_OWNER_TOKEN)")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("connect", help="Run handshake and print server info")
    sub.add_parser("list-tools", help="List MCP tools")

    sp = sub.add_parser("call", help="Call a tool with JSON args")
    sp.add_argument("tool")
    sp.add_argument("json_args", nargs="?", default="{}")

    sp = sub.add_parser("open", help="open_workspace and print workspaceId")
    sp.add_argument("path")

    sp = sub.add_parser("bash", help="Run a shell command in a workspace")
    sp.add_argument("workspace")
    sp.add_argument("command")

    args = p.parse_args(argv)

    if args.cmd == "connect":
        url = args.url or os.environ.get("DEVSPACE_URL") or _state_url()
        owner = args.owner or os.environ.get("DEVSPACE_OWNER_TOKEN") or _owner_token()
        if not url or not owner:
            raise SystemExit("Need URL and owner token (see --help).")
        c = DevSpaceClient(url, owner)
        info = c.connect()
        print(json.dumps({
            "connected": True,
            "serverInfo": info.get("serverInfo", {}),
            "capabilities": info.get("capabilities", {}),
            "sessionId": c.session_id,
        }, indent=2))
        return
    if args.cmd == "list-tools":
        c = _make_client(args)
        for t in c.list_tools():
            print(f"{t['name']}: {(t.get('description') or '').splitlines()[0]}")
        return
    if args.cmd == "call":
        c = _make_client(args)
        res = c.call_tool(args.tool, json.loads(args.json_args))
        print(res["text"] or json.dumps(res["structured"], indent=2))
        return
    if args.cmd == "open":
        c = _make_client(args)
        print(c.open_workspace(args.path))
        return
    if args.cmd == "bash":
        c = _make_client(args)
        print(c.bash(args.workspace, args.command))
        return


if __name__ == "__main__":
    main()
