"""Plain Python - no framework, just the standard library's HTTP server.

The runtime's start command points here:
    dx config set runtime.start_cmd 'python main.py'
"""

import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from status import status

# 0.0.0.0, not localhost: bound to loopback inside a container the process is
# unreachable from Caddy, and the symptom is a 502 with an empty app log.
HOST = "0.0.0.0"
PORT = int(os.environ.get("PORT") or os.environ.get("DX_APP_PORT") or 8000)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802  (stdlib naming)
        body = status("none").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        # Structured, so `dx logs` filtering and `dx verify`'s error diff work
        # the same way they do for every other runtime.
        print('{"level":"info","msg":"%s"}' % (fmt % args), flush=True)


if __name__ == "__main__":
    print('{"level":"info","msg":"listening","port":%d}' % PORT, flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
