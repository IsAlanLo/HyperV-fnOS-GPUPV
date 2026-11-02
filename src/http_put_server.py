#!/usr/bin/env python3
"""Throwaway HTTP PUT receiver: move files host -> guest when there is no
SMB share the agent can read and no SSH/WinRM into the Windows host.

Run in the guest as the agent account (no root needed) against a directory the
agent owns, then push from Windows with curl.exe (present since Win10 1803):

  guest:  python3 http_put_server.py /tmp/incoming
  host:   curl.exe -s --max-time 5 http://<guest-ip>:8899/           # expect 'alive'
  host:   Get-ChildItem '<src>' -File | ForEach-Object { curl.exe -s --max-time 600 -T $_.FullName 'http://<guest-ip>:8899/' }

Every PUT answers `ok <name> <bytes>`, so the pushing console prints a per-file
receipt that can be checked against the host listing instead of trusting a
silent copy. Only the basename is written, so a crafted request path cannot
escape the output directory. Unauthenticated by design: trusted LAN only, and
stop it as soon as the batch has landed.
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/incoming"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8899
os.makedirs(OUT, exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    def do_PUT(self):
        name = os.path.basename(self.path.split("?")[0].replace("\\", "/"))
        if not name or name in (".", ".."):
            self.send_response(400)
            self.end_headers()
            return
        total = int(self.headers.get("Content-Length", 0) or 0)
        got = 0
        with open(os.path.join(OUT, name), "wb") as f:
            while got < total:
                chunk = self.rfile.read(min(1 << 20, total - got))
                if not chunk:
                    break
                f.write(chunk)
                got += len(chunk)
        self.send_response(201)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(f"ok {name} {got}\n".encode())

    def do_GET(self):
        body = ["alive"]
        for n in sorted(os.listdir(OUT)):
            p = os.path.join(OUT, n)
            if os.path.isfile(p):
                body.append(f"{n} {os.path.getsize(p)}")
        data = ("\n".join(body) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"listening on 0.0.0.0:{PORT}, writing to {OUT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
