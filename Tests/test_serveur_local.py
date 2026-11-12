"""Tests HTTP sur fichiers factices et interface de boucle locale."""

import contextlib
import http.client
import importlib.util
import io
import shutil
import tempfile
import threading
import unittest
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[1] / "Python" / "02-serveur-local.py"
SPEC = importlib.util.spec_from_file_location("serveur_local", SOURCE)
BACKEND = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BACKEND)


class LocalServerTests(unittest.TestCase):
    def setUp(self):
        self.temp_parent = Path(tempfile.gettempdir()).resolve()
        self.scratch = Path(tempfile.mkdtemp(prefix="scripts-perso-http-")).resolve()
        self.addCleanup(self.clean_scratch)
        self.project = self.scratch / "Projet avec espaces [1]"
        self.public = self.project / "public"
        self.public.mkdir(parents=True)
        (self.public / "index.html").write_text("PUBLIC_OK", encoding="utf-8")
        self.server = BACKEND.create_server(self.project, self.public, 0)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()
        self.addCleanup(self.clean_server)

    def clean_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def clean_scratch(self):
        if self.scratch.parent != self.temp_parent or not self.scratch.name.startswith("scripts-perso-http-"):
            raise RuntimeError("Nettoyage hors du dossier temporaire refuse")
        shutil.rmtree(self.scratch)

    def request(self, path, method="GET"):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            connection.request(method, path)
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def test_serves_public_index_on_loopback(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.request("/"), (200, b"PUBLIC_OK"))

    def test_blocks_sensitive_files_without_reading_their_content(self):
        for name in (".env", "credentials.json", "secret.txt", "demo.key", "dump.sql", "script.ps1"):
            (self.public / name).write_text("DEMO_PRIVATE_VALUE", encoding="utf-8")
            with self.subTest(name=name), contextlib.redirect_stdout(io.StringIO()):
                status, body = self.request("/" + name)
                self.assertEqual(status, 403)
                self.assertNotIn(b"DEMO_PRIVATE_VALUE", body)

    def test_blocks_traversal_and_windows_paths(self):
        for path in ("/%2e%2e/outside.txt", "/%5coutside.txt", "/C%3A/Windows/win.ini", "/.git/config"):
            with self.subTest(path=path), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(self.request(path)[0], 403)

    def test_directory_listing_is_disabled(self):
        (self.public / "assets").mkdir()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.request("/assets/")[0], 403)

    def test_project_root_and_external_directory_are_refused(self):
        for directory in (self.project, self.scratch):
            with self.subTest(directory=directory):
                with self.assertRaises(ValueError):
                    BACKEND.create_server(self.project, directory, 0)

    def test_request_parameters_are_not_logged(self):
        logs = io.StringIO()
        with contextlib.redirect_stdout(logs):
            self.assertEqual(self.request("/index.html?token=DEMO_QUERY_VALUE")[0], 200)
        self.assertNotIn("DEMO_QUERY_VALUE", logs.getvalue())
        self.assertNotIn("index.html", logs.getvalue())

    def test_post_cannot_modify_files(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.request("/index.html", "POST")[0], 501)
        self.assertEqual((self.public / "index.html").read_text(), "PUBLIC_OK")

    def test_symlink_outside_public_directory_is_refused(self):
        outside = self.scratch / "outside.txt"
        outside.write_text("DEMO_OUTSIDE", encoding="utf-8")
        try:
            (self.public / "link.txt").symlink_to(outside)
        except OSError:
            self.skipTest("Creation de liens symboliques non autorisee")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.request("/link.txt")[0], 403)

    def test_symlink_to_hidden_file_is_refused(self):
        hidden = self.public / ".env"
        hidden.write_text("DEMO_HIDDEN", encoding="utf-8")
        try:
            (self.public / "link.txt").symlink_to(hidden)
        except OSError:
            self.skipTest("Creation de liens symboliques non autorisee")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.request("/link.txt")[0], 403)


if __name__ == "__main__":
    unittest.main()
