"""Stands in for Selan's control in CI: accepts a registration carrying the expected token."""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        good = self.path == "/register" and body.get("token") == os.environ["EXPECTED_TOKEN"]
        print(f"registration from {body.get('component')} at {body.get('address')}: {'accepted' if good else 'refused'}", flush=True)
        self.send_response(200 if good else 403)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
