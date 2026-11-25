"""Local stand-in for the site Worker's update routes, for the update end-to-end test (tools/update-e2e/run.sh).

Serves, on 127.0.0.1 only:
    /transcribe/appcast.xml          <root>/transcribe/appcast.xml        application/xml; charset=utf-8
    /transcribe/download/<file>.dmg  <root>/transcribe/<file>.dmg         application/x-apple-diskimage
    /transcribe/download/<a>-<b>.delta  <root>/transcribe/<a>-<b>.delta   application/octet-stream
Anything else, or a missing file, is a 404 text/plain. GET and HEAD only (else 405). Bytes are served unchanged.

Every request is appended to the log as one JSON line: time, method, path, query and every header, as received, so
the test can check what an update check sends.

    python3 -I feed-server.py --root DIR --port 8788 --log FILE
"""
import argparse
import http.server
import json
import os
import re
import shutil
import time

DMG = re.compile(r"^/transcribe/download/(Transcribe-[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}\.dmg)$")
DELTA = re.compile(r"^/transcribe/download/(Transcribe-[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}-[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}\.delta)$")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--log", required=True)
    args = parser.parse_args()
    root = os.path.realpath(args.root)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            self.serve(body=True)

        def do_HEAD(self):
            self.serve(body=False)

        def do_POST(self):
            self.record()
            self.reply_text(405, "Method not allowed", True)

        do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_POST

        def record(self):
            path, _, query = self.path.partition("?")
            entry = {
                "time": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "method": self.command,
                "path": path,
                "query": query,
                "headers": [[name, value] for name, value in self.headers.items()],
            }
            with open(args.log, "a") as log:
                log.write(json.dumps(entry) + "\n")

        def serve(self, body):
            self.record()
            path = self.path.partition("?")[0]
            match = DMG.match(path)
            delta = DELTA.match(path)
            if path == "/transcribe/appcast.xml":
                file, ctype = os.path.join(root, "transcribe", "appcast.xml"), "application/xml; charset=utf-8"
            elif match:
                file, ctype = os.path.join(root, "transcribe", match.group(1)), "application/x-apple-diskimage"
            elif delta:
                file, ctype = os.path.join(root, "transcribe", delta.group(1)), "application/octet-stream"
            else:
                file, ctype = None, None
            if file is None or not os.path.isfile(file):
                self.reply_text(404, "Not found", body)
                return
            size = os.path.getsize(file)
            self.send_response(200)
            self.send_header("content-type", ctype)
            self.send_header("content-length", str(size))
            self.send_header("cache-control", "no-cache")
            self.end_headers()
            if body:
                with open(file, "rb") as f:
                    shutil.copyfileobj(f, self.wfile, 1 << 20)

        def reply_text(self, code, text, body):
            data = text.encode()
            self.send_response(code)
            self.send_header("content-type", "text/plain; charset=utf-8")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            if body:
                self.wfile.write(data)

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
