"""Stands in for the proxy, the gateway or selan-keys in CI until a release is pinned in compose.yaml.

It does what the stack needs of them. selan-keys logs in to the vault with its AppRole, writes and reads
a canary under VAULT_PREFIX, is refused outside it, and answers GET /keys/<name> to a caller with its own
token. The proxy and the gateway have no vault identity: they read the canary from selan-keys with their
SELAN_KEYS_TOKEN, and check another token is refused. Each makes its Ed25519 (signing) and X25519
(sealing) key pairs in its identity volume, root only, calls RegisterServer once with its one-time token
and both public halves, and answers /healthz and /readyz.
"""
import base64
import hmac
import json
import os
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from keys import ed25519_public, x25519_public

COMPONENT = os.environ["STAND_IN_COMPONENT"]
CANARY = "not-a-key"
state = {"ready": False, "detail": "starting"}


def call(method, url, body=None, headers=None):
    request = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode())
    request.add_header("Content-Type", "application/json")
    for name, value in (headers or {}).items():
        request.add_header(name, value)
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        return error.code, {}


def vault_url(path):
    mount, _, prefix = os.environ["VAULT_PREFIX"].partition("/")
    return f"{os.environ['VAULT_ADDR'].rstrip('/')}/v1/{mount}/data/{prefix}{path}"


def vault_token():
    status, login = call("POST", os.environ["VAULT_ADDR"].rstrip("/") + "/v1/auth/approle/login",
                         {"role_id": os.environ["VAULT_ROLE_ID"], "secret_id": os.environ["VAULT_SECRET_ID"]})
    assert status == 200, f"approle login answered {status}"
    return login["auth"]["client_token"]


def check_vault():
    token = {"X-Vault-Token": vault_token()}
    status, _ = call("POST", vault_url("canary"), {"data": {"provider": "anthropic", "value": CANARY}}, token)
    assert status in (200, 204), f"writing under the prefix answered {status}"
    status, read = call("GET", vault_url("canary"), headers=token)
    assert status == 200 and read["data"]["data"]["value"] == CANARY, f"reading it back answered {status}"
    mount = os.environ["VAULT_PREFIX"].partition("/")[0]
    status, _ = call("GET", f"{os.environ['VAULT_ADDR'].rstrip('/')}/v1/{mount}/data/elsewhere/canary", headers=token)
    assert status == 403, f"reading outside the prefix answered {status}, not 403"


def check_keys():
    url = os.environ["SELAN_KEYS_URL"].rstrip("/") + "/keys/canary"
    status, read = call("GET", url, headers={"Authorization": "Bearer " + os.environ["SELAN_KEYS_TOKEN"]})
    assert status == 200 and read.get("value") == CANARY, f"selan-keys answered {status} for the canary"
    status, _ = call("GET", url, headers={"Authorization": "Bearer " + "0" * 64})
    assert status == 401, f"selan-keys answered {status}, not 401, to a token nobody was given"


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
            check_vault() if COMPONENT == "keys" else check_keys()
            register_once()
            state.update(ready=True, detail="ready")
        except Exception as error:  # noqa: BLE001 - every failure is retried and shown on /readyz
            state["detail"] = str(error)
            time.sleep(2)
    print(f"{COMPONENT}: ready", flush=True)


def caller_allowed(header):
    tokens = [os.environ.get("CALLER_TOKEN_PROXY", ""), os.environ.get("CALLER_TOKEN_GATEWAY", "")]
    given = header.removeprefix("Bearer ")
    return any(token and hmac.compare_digest(given, token) for token in tokens)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if COMPONENT == "keys" and self.path.startswith("/keys/"):
            self.serve_key(self.path.removeprefix("/keys/"))
            return
        ok = self.path == "/healthz" or (self.path == "/readyz" and state["ready"])
        self.answer(200 if ok else 503, (state["detail"] + "\n").encode())

    def serve_key(self, name):
        if not caller_allowed(self.headers.get("Authorization", "")):
            self.answer(401, b"unknown caller\n")
            return
        status, read = call("GET", vault_url(name), headers={"X-Vault-Token": vault_token()})
        if status != 200:
            self.answer(404 if status == 404 else 502, b"not readable\n")
            return
        self.answer(200, json.dumps({"value": read["data"]["data"]["value"]}).encode())

    def answer(self, status, body):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


threading.Thread(target=setup, daemon=True).start()
ThreadingHTTPServer(("0.0.0.0", int(os.environ["PORT"])), Handler).serve_forever()
