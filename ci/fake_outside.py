"""Stands in for public DNS over HTTPS and check-host.net for install.sh's check from outside, by mode.

SELAN_PUBLIC_DNS=http://127.0.0.1:8099/public answers 203.0.113.7 for every name and 203.0.113.8 as this
server's way out; /private answers no name and a private way out. SELAN_CHECK_HOST=http://127.0.0.1:8099/<mode>:
  mixed    443 answers; 80 fails a result read, is pending once, then closed; 8080 cannot start; 8200 has no id
  closed   every port closed
  unknown  443 stays pending past install.sh's wait; no other probe can start
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

reads = {}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        mode, _, route = url.path.lstrip("/").partition("/")
        query = parse_qs(url.query)
        if route == "dns-query":
            answer = [{"data": "203.0.113.7"}] if mode == "public" else []
            self.answer(200, json.dumps({"Status": 0, "Answer": answer}))
        elif route == "cdn-cgi/trace":
            self.answer(200, "ip=" + ("203.0.113.8" if mode == "public" else "10.0.0.8") + "\n")
        elif route == "check-tcp":
            self.start(mode, query["host"][0])
        elif route.startswith("check-result/"):
            self.result(route.removeprefix("check-result/"))
        else:
            self.answer(404, "")

    def start(self, mode, host):
        port = host.rsplit(":", 1)[1]
        if (mode == "unknown" and port != "443") or (mode == "mixed" and port == "8080"):
            self.answer(500, "")
        elif mode == "mixed" and port == "8200":
            self.answer(200, json.dumps({"ok": 1}))
        else:
            request = f"{mode}-{port}-{len(reads)}"
            reads[request] = 0
            self.answer(200, json.dumps({"ok": 1, "request_id": request}))

    def result(self, request):
        mode, port, _ = request.split("-")
        reads[request] += 1
        node = {"node1.check-host.net": [{"time": 0.04, "address": "203.0.113.7"}]}
        if mode == "mixed" and port == "443":
            self.answer(200, json.dumps(node))
        elif mode == "mixed" and port == "80" and reads[request] == 1:
            self.answer(500, "")
        elif (mode == "mixed" and port == "80" and reads[request] == 2) or mode == "unknown":
            self.answer(200, json.dumps({"node1.check-host.net": None}))
        else:
            self.answer(200, json.dumps({"node1.check-host.net": [{"error": "Connection refused"}]}))

    def answer(self, status, body):
        raw = body.encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *_):
        pass


ThreadingHTTPServer(("0.0.0.0", 8099), Handler).serve_forever()
