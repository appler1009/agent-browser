# Test helper: serves two downloads on 127.0.0.1:<port>.
#   /sized   announces its size (3 MB)
#   /stream  does not announce a size and keeps sending 3 MB (so a size cap must stop it on the way)
import sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        chunk = b"x" * 65536
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="big.bin"')
        if self.path == "/sized":
            self.send_header("Content-Length", str(48 * len(chunk)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            for _ in range(48):
                self.wfile.write(chunk)
                self.wfile.flush()
                if self.path == "/stream": time.sleep(0.05)
        except Exception:
            pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
