#!/usr/bin/python3
"""Regression tests for the helper's HTTP boundary: redirects are never
followed, credentials never leave the pinned origin, proxies are ignored, and
resolved addresses are vetted and pinned.

A real TLS server runs in-process on 127.0.0.1 with a self-signed certificate
(generated with openssl into a temp dir). The helper module is loaded directly
and its SSL context is pointed at that certificate; the pinned API origin is
pointed at the test server through the developer override, which is the one
place loopback is permitted by design.

Run: python3 tests/http_boundary_test.py
"""

import http.server
import importlib.machinery
import importlib.util
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.normpath(os.path.join(HERE, "..", "bin", "nowah-sync"))
TOKEN = "nowah_dev_" + "a" * 43


def make_cert(directory):
    cert = os.path.join(directory, "cert.pem")
    key = os.path.join(directory, "key.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
         "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
        check=True, capture_output=True)
    return cert, key


class Recorder:
    """What the server saw: (path, Authorization header) per request."""

    def __init__(self):
        self.requests = []
        self.lock = threading.Lock()

    def record(self, path, auth):
        with self.lock:
            self.requests.append((path, auth))

    def snapshot(self):
        with self.lock:
            return list(self.requests)


def make_handler(recorder, self_origin, other_origin):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def _redirect(self, code, location):
            self.send_response(code)
            self.send_header("Location", location)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def _json(self, status, doc):
            body = json.dumps(doc).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            recorder.record(self.path, self.headers.get("Authorization"))
            if self.path == "/ok":
                return self._json(200, {"success": True, "data": {"ok": True}})
            if self.path == "/redirect-same":
                return self._redirect(302, self_origin + "/landed")
            if self.path == "/redirect-cross":
                return self._redirect(302, other_origin + "/landed")
            if self.path == "/redirect-downgrade":
                return self._redirect(302, self_origin.replace("https://", "http://") + "/landed")
            if self.path == "/redirect-loopback":
                return self._redirect(302, "https://127.0.0.1:1/landed")
            if self.path == "/redirect-private":
                return self._redirect(302, "https://10.0.0.1/landed")
            if self.path == "/redirect-loop":
                return self._redirect(302, self_origin + "/redirect-loop")
            if self.path == "/redirect-308":
                return self._redirect(308, self_origin + "/landed")
            if self.path == "/landed":
                return self._json(200, {"success": True, "data": {"landed": True}})
            return self._json(404, {"success": False, "error": {"code": "NOT_FOUND"}})

        do_POST = do_GET

    return Handler


def load_helper(origin):
    env_backup = dict(os.environ)
    os.environ["NOWAH_DEV_API_ORIGIN"] = origin
    os.environ["NOWAH_DEV_CONSENT"] = "1"
    try:
        loader = importlib.machinery.SourceFileLoader("nowah_sync", HELPER)
        spec = importlib.util.spec_from_loader("nowah_sync", loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
    finally:
        os.environ.clear()
        os.environ.update(env_backup)
    return module


class HttpBoundaryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cert, key = make_cert(cls.tmp)
        cls.recorder = Recorder()
        # Two listeners on the same cert: "self" (the pinned origin) and
        # "other" (a different origin that must never see a request).
        cls.self_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), None)
        cls.other_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), None)
        self_port = cls.self_server.server_address[1]
        other_port = cls.other_server.server_address[1]
        cls.self_origin = "https://127.0.0.1:%d" % self_port
        cls.other_origin = "https://127.0.0.1:%d" % other_port
        cls.other_recorder = Recorder()
        cls.self_server.RequestHandlerClass = make_handler(cls.recorder, cls.self_origin, cls.other_origin)
        cls.other_server.RequestHandlerClass = make_handler(cls.other_recorder, cls.other_origin, cls.self_origin)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        for server in (cls.self_server, cls.other_server):
            server.socket = ctx.wrap_socket(server.socket, server_side=True)
            threading.Thread(target=server.serve_forever, daemon=True).start()

        cls.mod = load_helper(cls.self_origin)
        trust = ssl.create_default_context(cafile=cert)
        trust.minimum_version = ssl.TLSVersion.TLSv1_2
        cls.mod.SSL_CONTEXT = trust

    @classmethod
    def tearDownClass(cls):
        cls.self_server.shutdown()
        cls.other_server.shutdown()

    def setUp(self):
        self.recorder.requests.clear()
        self.other_recorder.requests.clear()
        self.mod.DEADLINE = self.mod.time.monotonic() + 40

    def get(self, path, bearer=TOKEN):
        return self.mod.request(self.self_origin + path, 32 * 1024, bearer=bearer)

    def assert_only_initial_request(self, path):
        seen = self.recorder.snapshot()
        self.assertEqual([p for p, _ in seen], [path], "exactly one request, to the initial path, and nothing else")
        self.assertEqual(self.other_recorder.snapshot(), [], "the other origin must never be contacted")

    def test_same_origin_request_carries_the_bearer(self):
        status, body = self.get("/ok")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["data"], {"ok": True})
        self.assertEqual(self.recorder.snapshot(), [("/ok", "Bearer " + TOKEN)])

    def test_same_origin_redirect_is_not_followed(self):
        status, body = self.get("/redirect-same")
        self.assertEqual((status, body), (0, b""), "a 3xx is a transport failure, never followed")
        self.assert_only_initial_request("/redirect-same")

    def test_cross_origin_redirect_is_not_followed_and_credential_never_forwarded(self):
        status, _ = self.get("/redirect-cross")
        self.assertEqual(status, 0)
        self.assert_only_initial_request("/redirect-cross")
        self.assertEqual(self.other_recorder.snapshot(), [], "bearer must never reach another origin")

    def test_http_downgrade_redirect_is_not_followed(self):
        status, _ = self.get("/redirect-downgrade")
        self.assertEqual(status, 0)
        self.assert_only_initial_request("/redirect-downgrade")

    def test_loopback_and_private_redirects_are_not_followed(self):
        for path in ("/redirect-loopback", "/redirect-private"):
            self.recorder.requests.clear()
            status, _ = self.get(path)
            self.assertEqual(status, 0, path)
            self.assert_only_initial_request(path)

    def test_redirect_loop_terminates_after_one_request(self):
        status, _ = self.get("/redirect-loop")
        self.assertEqual(status, 0)
        self.assert_only_initial_request("/redirect-loop")

    def test_308_redirect_is_not_followed_for_post(self):
        status, _ = self.mod.request(self.self_origin + "/redirect-308", 32 * 1024, bearer=TOKEN, body={"x": 1})
        self.assertEqual(status, 0)
        self.assert_only_initial_request("/redirect-308")

    def test_off_origin_url_is_refused_before_any_network(self):
        status, _ = self.mod.request(self.other_origin + "/ok", 32 * 1024, bearer=TOKEN)
        self.assertEqual(status, 0)
        self.assertEqual(self.recorder.snapshot(), [])
        self.assertEqual(self.other_recorder.snapshot(), [])
        status, _ = self.mod.request("http://127.0.0.1:80/ok", 32 * 1024, bearer=TOKEN)
        self.assertEqual(status, 0)

    def test_environment_proxies_are_ignored(self):
        backup = dict(os.environ)
        try:
            os.environ["https_proxy"] = "http://127.0.0.1:1"
            os.environ["HTTPS_PROXY"] = "http://127.0.0.1:1"
            os.environ["all_proxy"] = "http://127.0.0.1:1"
            status, _ = self.get("/ok")
            self.assertEqual(status, 200, "a proxy in the environment must not intercept the request")
        finally:
            os.environ.clear()
            os.environ.update(backup)

    def test_production_origin_refuses_non_public_resolution(self):
        saved = self.mod.API_ORIGIN
        try:
            self.mod.API_ORIGIN = self.mod.PROD_API_ORIGIN
            self.assertIsNone(self.mod.resolve_pinned_address("localhost", 443))
            self.assertIsNone(self.mod.resolve_pinned_address("127.0.0.1", 443))
        finally:
            self.mod.API_ORIGIN = saved

    def test_address_classifier(self):
        public = self.mod.address_is_public
        for bad in ("127.0.0.1", "10.1.2.3", "172.16.0.9", "192.168.1.1", "169.254.169.254", "::1",
                    "fe80::1", "fc00::1", "0.0.0.0", "224.0.0.1", "::ffff:127.0.0.1", "not-an-ip"):
            self.assertFalse(public(bad), bad)
        for good in ("1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"):
            self.assertTrue(public(good), good)

    def test_app_path_grammar_accepts_what_the_panel_builds_and_rejects_the_rest(self):
        accept = self.mod.APP_PATH_RE.match
        for good in ("/", "/trips", "/trips/abc_DEF-123", "/device?code=ABCD-EFGH", "/plan",
                     "/?q=Flights%20to%20Tokyo%20in%20March", "/?q=" + "%C3%A9" * 200,
                     "/?q=Rome%20(kids)%20~5-day%20*trip*%20!"):
            self.assertTrue(accept(good), good)
        for bad in ("", "trips", "//evil.example", "/x\nnewline", "/x y", "https://app.nowah.xyz/",
                    "/?q=<script>", "/?q=\"quoted\"", "/" + "a" * 1500, "/\u200b"):
            self.assertFalse(accept(bad), repr(bad))

    def test_helper_runs_isolated_and_reexecs_if_it_is_not(self):
        # A subprocess launched WITHOUT -I must still end up isolated (self re-exec),
        # and PYTHONPATH must have no effect on what it imports.
        import subprocess, tempfile
        with tempfile.TemporaryDirectory() as evil:
            with open(os.path.join(evil, "json.py"), "w") as fh:
                fh.write("raise SystemExit(99)\n")
            proc = subprocess.run(
                [sys.executable, HELPER, "launch", "https://evil.example"],
                env={"HOME": evil, "XDG_STATE_HOME": evil, "PYTHONPATH": evil, "PATH": ""},
                capture_output=True, timeout=30)
            # Reached our own argument validation (exit 1 + message), not the planted module.
            self.assertEqual(proc.returncode, 1, proc.stderr)
            self.assertIn(b"refusing to launch", proc.stderr)

    def test_deeply_nested_json_is_rejected_not_crashing(self):
        deep = ("[" * 100000) + ("]" * 100000)
        self.assertIsNone(self.mod.envelope(deep.encode()))

    def test_opener_has_no_file_ftp_or_data_handlers(self):
        opener = self.mod.build_opener("127.0.0.1", socket.AF_INET, "127.0.0.1")
        names = {type(h).__name__ for h in opener.handlers}
        for forbidden in ("FileHandler", "FTPHandler", "DataHandler", "HTTPHandler", "HTTPCookieProcessor",
                          "HTTPBasicAuthHandler", "HTTPDigestAuthHandler"):
            self.assertNotIn(forbidden, names)
        self.assertIn("NoRedirectHandler", names)
        self.assertNotIn("ProxyHandler", names, "no proxy handler exists, so the environment is never consulted")
        self.assertEqual(self.mod.MAX_REDIRECTS, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
