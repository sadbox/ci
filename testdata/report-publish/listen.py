"""listen.py <file> <status>: a stand-in for Grafana Cloud's Influx endpoint.

Prints its port, then answers every POST with <status> and writes what it
was sent to <file>: the path, the basic-auth credentials, the content type
and the body. For scripts/selftest.sh and ci.yml (report-publish).
"""

import base64
import http.server
import sys

got, status = sys.argv[1], int(sys.argv[2])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
        scheme, _, cred = self.headers.get("Authorization", "").partition(" ")
        auth = base64.b64decode(cred).decode() if scheme == "Basic" else "none"
        with open(got, "w") as f:
            f.write(f"{self.path}\n{auth}\n{self.headers.get('Content-Type')}\n{body}")
        self.send_response(status)
        self.end_headers()

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
