"""Stands in for Selan's control in CI: OwnServersService over Connect, binary protobuf, as selan-proto has it.

RegisterServer accepts each component's expected one-time token once, with a 32-byte Ed25519 public_key and an
https address, and for selan-keys a 32-byte X25519 sealing_public_key that is not the signing key; it refuses
anything else, as control does. Poll answers every component with control's clock and no work. It serves TLS
with ci/tls/, as control does: selan-keys takes Selan's address over https alone.

ResolveSession, which the gateway asks at boot and for every session, answers a signed call with no session and
refuses an unsigned one. AUTH_SERVER_URL points here too, and selan-auth's SessionService is refused as
auth.selan.ai refuses a server's token: a gateway that asks it instead of control must fail its boot here as well.
"""
import base64
import os
import ssl
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICE = "/control.v1.OwnServersService/"
SELAN_AUTH = "/auth.v1.SessionService/"
COMPONENTS = {1: "OWN_SERVERS_COMPONENT_PROXY", 2: "OWN_SERVERS_COMPONENT_GATEWAY", 3: "OWN_SERVERS_COMPONENT_KEYS"}
# One token registers any component, as control's does; selan-keys may bring a second of its own.
TOKENS = {
    "OWN_SERVERS_COMPONENT_PROXY": {os.environ["EXPECTED_TOKEN"]},
    "OWN_SERVERS_COMPONENT_GATEWAY": {os.environ["EXPECTED_TOKEN"]},
    "OWN_SERVERS_COMPONENT_KEYS": {os.environ["EXPECTED_TOKEN"], os.environ["EXPECTED_KEYS_TOKEN"]},
}
registered = set()


def varint(data, at):
    value = shift = 0
    while True:
        byte = data[at]
        at += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return value, at


def fields(data):
    """Each top-level field of a protobuf message as number -> value: an int, or bytes for a length-delimited one."""
    out, at = {}, 0
    while at < len(data):
        key, at = varint(data, at)
        number, wire = key >> 3, key & 7
        if wire == 0:
            out[number], at = varint(data, at)
        elif wire == 2:
            size, at = varint(data, at)
            out[number], at = data[at:at + size], at + size
        elif wire == 1:
            out[number], at = data[at:at + 8], at + 8
        elif wire == 5:
            out[number], at = data[at:at + 4], at + 4
        else:
            raise ValueError(f"wire type {wire}")
    return out


def encode_varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        out.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(out)


def message(*parts):
    """parts are (number, value): an int is a varint, bytes or str a length-delimited field."""
    out = bytearray()
    for number, value in parts:
        if isinstance(value, int):
            out += encode_varint(number << 3) + encode_varint(value)
        else:
            raw = value.encode() if isinstance(value, str) else value
            out += encode_varint(number << 3 | 2) + encode_varint(len(raw)) + raw
    return bytes(out)


def register(body):
    """RegisterServerRequest: 1 token, 2 component, 3 address, 4 public_key, 6 sealing_public_key."""
    component = COMPONENTS.get(body.get(2, 0))
    if component is None:
        return ("invalid_argument", "component"), None
    if body.get(1, b"").decode() not in TOKENS[component]:
        return ("permission_denied", "unknown registration token"), component
    if component in registered:
        return ("permission_denied", "token already used for this component"), component
    if not body.get(3, b"").decode().startswith("https://"):
        return ("invalid_argument", "address is not https"), component
    signing, sealing = body.get(4, b""), body.get(6, b"")
    if len(signing) != 32:
        return ("invalid_argument", "public_key must be 32 raw bytes"), component
    if component == "OWN_SERVERS_COMPONENT_KEYS" and (len(sealing) != 32 or sealing == signing):
        return ("invalid_argument", "selan-keys' sealing_public_key must be 32 raw bytes, not the signing key"), component
    return None, component


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        method = self.path[len(SERVICE):] if self.path.startswith(SERVICE) else ""
        signed = self.headers.get("Authorization", "").startswith("Bearer ")
        if method == "RegisterServer":
            self.register(fields(raw))
        elif method == "Poll":
            component = COMPONENTS.get(fields(raw).get(1, 0), "an unnamed component")
            print(f"Poll from {component}, {'signed' if signed else 'UNSIGNED'}", flush=True)
            now = time.time()
            self.answer(200, message((3, message((1, int(now)), (2, int(now % 1 * 1e9))))))
        elif method == "ResolveSession":
            print(f"ResolveSession, {'signed: no session' if signed else 'UNSIGNED: refused'}", flush=True)
            if signed:
                self.answer(200, b"")
            else:
                self.refuse(401, "unauthenticated", "not signed")
        elif self.path.startswith(SELAN_AUTH):
            print(f"selan-auth {self.path[len(SELAN_AUTH):]}: refused, selan-auth takes no server's token", flush=True)
            self.refuse(401, "unauthenticated", "selan-auth takes no server's token")
        else:
            print(f"unimplemented: {self.path}", flush=True)
            self.refuse(404, "unimplemented", self.path)

    def register(self, body):
        refused, component = register(body)
        if refused:
            code, words = refused
            print(f"RegisterServer from {component}: refused, {words}", flush=True)
            self.refuse(403 if code == "permission_denied" else 400, code, words)
            return
        registered.add(component)
        sealing = f" sealing {base64.b64encode(body[6]).decode()}" if 6 in body else ""
        print(f"RegisterServer from {component} at {body[3].decode()}: accepted, "
              f"signing {base64.b64encode(body[4]).decode()}{sealing}", flush=True)
        self.answer(200, message((1, "company-ci"), (2, str(uuid.uuid4()))))

    def answer(self, status, raw, kind="application/proto"):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def refuse(self, status, code, words):
        self.answer(status, ('{"code":"%s","message":"%s"}' % (code, words)).encode(), "application/json")

    def log_message(self, *_):
        pass


server = ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain("/ci/tls/fake-control.pem", "/ci/tls/fake-control.key")
server.socket = tls.wrap_socket(server.socket, server_side=True)
server.serve_forever()
