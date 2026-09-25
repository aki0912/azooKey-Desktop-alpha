"""Loopback-only model review UI. Live raw/context is neither logged nor persisted."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path

from pipeline_io import HERE, encoded, parse
from review_support import ReviewSession

ASSETS = HERE / "review_ui"


def make_server(session, port=0):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def permitted(self):
            hosts = {f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"}
            host = self.headers.get("Host")
            origin = self.headers.get("Origin")
            return host in hosts and (origin is None or origin == "http://" + host)

        def send(self, status, body, mime="application/json; charset=utf-8"):
            self.send_response(status)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass  # The browser may abort an obsolete prefix request.

        def do_GET(self):
            if not self.permitted():
                return self.send(403, encoded(dict(error="Local origin required")))
            if self.path == "/api/report":
                return self.send(200, encoded(session.report))
            if self.path == "/favicon.ico":
                return self.send(204, b"")
            asset = {"/": ("index.html", "text/html"), "/app.js": ("app.js", "text/javascript"),
                     "/style.css": ("style.css", "text/css")}.get(self.path)
            if not asset:
                return self.send(404, encoded(dict(error="Not found")))
            return self.send(200, (ASSETS / asset[0]).read_bytes(), asset[1] + "; charset=utf-8")

        def do_POST(self):
            if not self.permitted():
                self.close_connection = True
                return self.send(403, encoded(dict(error="Local origin required")))
            if self.path != "/api/infer":
                self.close_connection = True
                return self.send(404, encoded(dict(error="Not found")))
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 16384 or self.headers.get_content_type() != "application/json":
                    self.close_connection = True
                    return self.send(400, encoded(dict(error="Invalid JSON request size or content type")))
                payload = parse(self.rfile.read(length))
                response = session.infer(payload)
            except (ValueError, TypeError, KeyError, UnicodeError):
                return self.send(400, encoded(dict(error="rawは1〜256文字、左文脈は30文字以内で入力してください。")))
            except Exception:
                # Do not include live text or subprocess arguments in diagnostics.
                return self.send(500, encoded(dict(error="判定処理に失敗しました。入力は保存していません。")))
            return self.send(200, encoded(response))

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    return server


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True, type=Path)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    with make_server(ReviewSession(args.run), args.port) as server:
        print(f"Review UI: http://127.0.0.1:{server.server_port} (input logging disabled)", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
