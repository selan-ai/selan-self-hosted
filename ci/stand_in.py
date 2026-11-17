"""Stands in for the proxy or the gateway in CI until a release is pinned in compose.yaml.

It does what the stack needs of them: log in to the vault with its AppRole, write and read a key
under VAULT_PREFIX, be refused outside it, make its Ed25519 (signing) and X25519 (sealing) key pairs in
its identity volume, root only, call RegisterServer once with the one-time token and both public halves,
and answer /healthz and /readyz.
"""
import base64
import json
import os
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from keys import ed25519_public, x25519_public

COMPONENT = os.environ["STAND_IN_COMPONENT"]
VAULT = os.environ["VAULT_ADDR"].rstrip("/")
MOUNT, _, PATH = os.environ["VAULT_PREFIX"].partition("/")
state = {"ready": False, "detail": "starting"}


def call(method, url, body=None, token=None):
    request = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode())
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("X-Vault-Token", token)
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        return error.code, {}


def check_once():
    status, login = call("POST", f"{VAULT}/v1/auth/approle/login",
                         {"role_id": os.environ["VAULT_ROLE_ID"], "secret_id": os.environ["VAULT_SECRET_ID"]})
    assert status == 200, f"approle login answered {status}"
    token = login["auth"]["client_token"]
    key = f"{VAULT}/v1/{MOUNT}/data/{PATH}canary-{COMPONENT}"
    status, _ = call("POST", key, {"data": {"provider": "anthropic", "value": "not-a-key"}}, token)
    assert status in (200, 204), f"writing under the prefix answered {status}"
    status, read = call("GET", key, token=token)
    assert status == 200 and read["data"]["data"]["value"] == "not-a-key", f"reading it back answered {status}"
    status, _ = call("GET", f"{VAULT}/v1/{MOUNT}/data/elsewhere/canary", token=token)
    assert status == 403, f"reading outside the prefix answered {status}, not 403"
    register_once()


def private_key(name):
    """A 32-byte private half, made once and kept in the identity volume, mode 0600."""
    path = os.path.join(os.environ["SELAN_IDENTITY_DIR"], name)
    if not os.path.exists(path):
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(os.urandom(32))
    with open(path, "rb") as handle:
        return handle.read()


def register_once():
    registered = os.path.join(os.environ["SELAN_IDENTITY_DIR"], "registered")
    signing, sealing = private_key("signing.key"), private_key("sealing.key")
    if os.path.exists(registered):
        return
    status, answer = call("POST", os.environ["CONTROL_BASE_URL"] + "/control.v1.OwnServersService/RegisterServer", {
        "registrationToken": os.environ["SELAN_REGISTRATION_TOKEN"],
        "component": f"OWN_SERVERS_COMPONENT_{COMPONENT.upper()}",
        "address": os.environ["PUBLIC_BASE_URL"],
        "publicKey": base64.b64encode(ed25519_public(signing)).decode(),
        "sealingPublicKey": base64.b64encode(x25519_public(sealing)).decode(),
        "version": "0.0.0-ci",
    })
    assert status == 200, f"control answered {status} to RegisterServer"
    with open(registered, "w") as handle:
        handle.write(answer["serverId"])


def setup():
    while not state["ready"]:
        try:
            check_once()
            state.update(ready=True, detail="ready")
        except Exception as error:  # noqa: BLE001 - every failure is retried and shown on /readyz
            state["detail"] = str(error)
            time.sleep(2)
    print(f"{COMPONENT}: ready", flush=True)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.path == "/healthz" or (self.path == "/readyz" and state["ready"])
        body = (state["detail"] + "\n").encode()
        self.send_response(200 if ok else 503)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


threading.Thread(target=setup, daemon=True).start()
ThreadingHTTPServer(("0.0.0.0", int(os.environ["PORT"])), Handler).serve_forever()
