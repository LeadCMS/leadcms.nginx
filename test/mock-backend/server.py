from http.server import BaseHTTPRequestHandler, HTTPServer
import json


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, content_type, body, extra_headers=None):
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        if extra_headers:
            for key, value in extra_headers.items():
                self.send_header(key, value)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/":
            self._send(200, "text/plain; charset=utf-8", "backend-root")
            return

        if self.path.startswith("/api"):
            body = json.dumps({"path": self.path, "service": "mock-backend"})
            self._send(200, "application/json", body)
            return

        if self.path == "/events":
            self._send(
                200,
                "text/event-stream",
                "event: ping\ndata: backend-sse\n\n",
                {"Cache-Control": "no-cache"},
            )
            return

        if self.path == "/socket.io":
            self._send(200, "text/plain; charset=utf-8", "backend-wss-route")
            return

        self._send(404, "text/plain; charset=utf-8", "not-found")

    def do_HEAD(self):
        self._send(200, "text/plain; charset=utf-8", "")

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()