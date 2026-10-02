"""Exercise nginx's real location/auth/header behavior on private test ports."""

import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[1]


class Upstream(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(f"{self.path}|{self.headers.get('Host')}|{self.headers.get('X-Forwarded-Proto')}".encode())

    def log_message(self, *args):
        pass


@unittest.skipUnless(shutil.which("nginx"), "nginx executable required")
class NginxDeploymentTests(unittest.TestCase):
    def exercise(self, variant):
        temp = tempfile.TemporaryDirectory(prefix="osticket-nginx-test-")
        self.addCleanup(temp.cleanup)
        directory = Path(temp.name)
        upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        password = "test-password"
        htpasswd = directory / "htpasswd"
        digest = base64.b64encode(hashlib.sha1(password.encode()).digest()).decode()
        htpasswd.write_text(f"review:{{SHA}}{digest}\n")
        snippet = (ROOT / "docker" / f"nginx-prsmusa-osticket{variant}.conf.example").read_text()
        snippet = snippet.replace("127.0.0.1:18003", f"127.0.0.1:{upstream.server_port}")
        snippet = snippet.replace("/etc/nginx/secrets/osticket-install.htpasswd", str(htpasswd))
        config = directory / "nginx.conf"
        config.write_text(f"daemon off; pid {directory}/nginx.pid; error_log stderr; events {{}} "
                          f"http {{ access_log off; server {{ listen 127.0.0.1:{port}; {snippet} }} }}")
        process = subprocess.Popen(["nginx", "-c", str(config), "-p", str(directory)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: process.communicate(timeout=10))
        self.addCleanup(process.terminate)
        base = f"http://127.0.0.1:{port}"

        def request(path, authenticated=False):
            headers = {"Host": "prsmusa.com"}
            if authenticated:
                headers["Authorization"] = "Basic " + base64.b64encode(f"review:{password}".encode()).decode()
            try:
                with urllib.request.urlopen(urllib.request.Request(base + path, headers=headers), timeout=2) as response:
                    return response.status, response.read().decode()
            except urllib.error.HTTPError as error:
                return error.code, error.read().decode()

        for _ in range(50):
            if process.poll() is not None:
                self.fail(process.communicate()[1])
            try:
                request("/ticket/index.php")
                break
            except urllib.error.URLError:
                time.sleep(0.05)
        else:
            self.fail("nginx did not start")
        return request

    def test_install_requires_auth_for_entire_helpdesk_and_proxies_setup(self):
        request = self.exercise("-install")
        for path in ["/ticket/index.php", "/ticket/scp/login.php", "/ticket/setup/install.php"]:
            self.assertEqual(request(path)[0], 401)
            status, body = request(path, True)
            self.assertEqual(status, 200)
            self.assertEqual(body, f"{path}|prsmusa.com|http")

    def test_protected_acceptance_requires_auth_and_blocks_setup(self):
        request = self.exercise("-protected")
        self.assertEqual(request("/ticket/index.php")[0], 401)
        self.assertEqual(request("/ticket/index.php", True)[0], 200)
        for path in ["/ticket/setup", "/ticket/setup/", "/ticket/setup/install.php"]:
            self.assertEqual(request(path, True)[0], 404)

    def test_public_variant_blocks_setup_and_preserves_uri(self):
        request = self.exercise("")
        status, body = request("/ticket/api/http.php/test?example=1")
        self.assertEqual(status, 200)
        self.assertEqual(body, "/ticket/api/http.php/test?example=1|prsmusa.com|http")
        for path in ["/ticket/setup", "/ticket/setup/", "/ticket/setup/install.php"]:
            self.assertEqual(request(path)[0], 404)


if __name__ == "__main__":
    unittest.main()
