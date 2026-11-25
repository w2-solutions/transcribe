"""Static server for the release-gate tests: serves ROOT on 127.0.0.1:PORT like the site Worker's pointers.

.json is application/json and .xml application/xml; a file <name>.type next to <name> overrides the type (for
example text/html, to play the old Worker). A missing file is a 404 text/plain.

    python3 -I serve.py ROOT PORT
"""
import http.server
import os
import sys

ROOT = os.path.realpath(sys.argv[1])
TYPES = {".json": "application/json", ".xml": "application/xml; charset=utf-8"}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = os.path.realpath(os.path.join(ROOT, self.path.split("?")[0].lstrip("/")))
        if not path.startswith(ROOT + os.sep) or not os.path.isfile(path):
            self.reply(404, "text/plain; charset=utf-8", b"Not found")
            return
        ctype = TYPES.get(os.path.splitext(path)[1], "application/octet-stream")
        if os.path.isfile(path + ".type"):
            with open(path + ".type") as f:
                ctype = f.read().strip()
        with open(path, "rb") as f:
            self.reply(200, ctype, f.read())

    def reply(self, code, ctype, body):
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), Handler).serve_forever()
