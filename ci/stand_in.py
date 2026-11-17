"""Stands in for the proxy or the gateway in CI until a release is pinned in compose.yaml.

It does what the stack needs of them: log in to the vault with its AppRole, write and read a key
under VAULT_PREFIX, be refused outside it, register with control using the one-time token once,
keeping that in its identity volume as the real ones keep their key pair, and answer /healthz and /readyz.
"""
import json
import os
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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
    identity = os.path.join(os.environ["SELAN_IDENTITY_DIR"], "identity")
    if os.path.exists(identity):
        return
    status, _ = call("POST", os.environ["CONTROL_BASE_URL"] + "/register",
                     {"component": COMPONENT, "token": os.environ["SELAN_REGISTRATION_TOKEN"],
                      "address": os.environ["PUBLIC_BASE_URL"]})
    assert status == 200, f"control answered {status} to the registration"
    with open(identity, "w") as handle:
        handle.write(COMPONENT)


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
