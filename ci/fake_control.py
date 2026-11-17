"""Stands in for Selan's control in CI: OwnServersService/RegisterServer as Connect JSON, as selan-proto has it.

Accepts each component's expected one-time token once, with an Ed25519 public_key and an X25519
sealing_public_key of 32 bytes each and an https address; refuses anything else, as control does.
selan-keys has a token of its own; OWN_SERVERS_COMPONENT_KEYS is not in selan-proto's enum yet and
stands for the value control will add.
"""
import base64
import binascii
import json
import os
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PATH = "/control.v1.OwnServersService/RegisterServer"
TOKENS = {
    "OWN_SERVERS_COMPONENT_PROXY": os.environ["EXPECTED_TOKEN"],
    "OWN_SERVERS_COMPONENT_GATEWAY": os.environ["EXPECTED_TOKEN"],
    "OWN_SERVERS_COMPONENT_KEYS": os.environ["EXPECTED_KEYS_TOKEN"],
}
registered = set()


def raw_key(body, field):
    try:
        key = base64.b64decode(body.get(field) or "", validate=True)
    except binascii.Error:
        return None
    return key if len(key) == 32 else None


def refusal(body):
    if body.get("component") not in TOKENS:
        return "invalid_argument", "component"
    if body.get("registrationToken") != TOKENS[body["component"]]:
        return "permission_denied", "unknown registration token"
    if body["component"] in registered:
        return "permission_denied", "token already used for this component"
    if not str(body.get("address", "")).startswith("https://"):
        return "invalid_argument", "address is not https"
    signing, sealing = raw_key(body, "publicKey"), raw_key(body, "sealingPublicKey")
    if signing is None or sealing is None:
        return "invalid_argument", "public_key and sealing_public_key must be 32 raw bytes each"
    if signing == sealing:
        return "invalid_argument", "the sealing key is the signing key"
    return None


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])) or b"{}")
        refused = ("unimplemented", self.path) if self.path != PATH else refusal(body)
        if refused:
            code, message = refused
            print(f"RegisterServer from {body.get('component')}: refused, {message}", flush=True)
            self.answer(403 if code == "permission_denied" else 400, {"code": code, "message": message})
            return
        registered.add(body["component"])
        print(f"RegisterServer from {body['component']} at {body['address']}: accepted, "
              f"signing {body['publicKey']} sealing {body['sealingPublicKey']}", flush=True)
        self.answer(200, {"companyId": "company-ci", "serverId": str(uuid.uuid4()), "controlPublicKeys": []})

    def answer(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *_):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
