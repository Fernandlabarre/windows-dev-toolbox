"""Regressions de l'exportateur sur des fichiers factices uniquement."""

import contextlib
import importlib.util
import io
import json
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / "Python" / "01-exporter-contexte-projet.py"
SPEC = importlib.util.spec_from_file_location("exporter", SOURCE)
EXPORTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORTER)
DEMO_VALUE = "DEMO_VALUE_FOR_TESTS_ONLY"


class ExporterTests(unittest.TestCase):
    def setUp(self):
        self.temp_parent = Path(tempfile.gettempdir()).resolve()
        self.scratch = Path(tempfile.mkdtemp(prefix="scripts-perso-tests-")).resolve()
        self.addCleanup(self.clean_scratch)
        self.project = self.scratch / "Projet de test"
        self.project.mkdir()

    def clean_scratch(self):
        # Ne supprimer que le dossier temporaire cree par ce test.
        if (
            self.scratch.parent != self.temp_parent
            or not self.scratch.name.startswith("scripts-perso-tests-")
        ):
            raise RuntimeError("Nettoyage hors du dossier temporaire refuse")
        shutil.rmtree(self.scratch)

    def source_file(self, content):
        path = self.project / "app_config.py"
        path.write_text(content, encoding="utf-8")
        return path

    def test_blocks_unprefixed_and_prefixed_assignments(self):
        for name in (
            "API_KEY", "ACCESS_TOKEN", "CLIENT_SECRET", "PASSWORD",
            "APP_API_KEY", "APP_PASSWORD", "api_key", "ApiKey", "$ApiKey",
        ):
            with self.subTest(field=name):
                path = self.source_file(f'{name} = "{DEMO_VALUE}"')
                raw, reason = EXPORTER.read_source(path)
                self.assertIsNone(raw)
                self.assertEqual(reason, "Secret potentiel detecte")

    def test_blocks_json_yaml_and_javascript_literals(self):
        samples = (
            json.dumps({"api_key": DEMO_VALUE}),
            f"password: {DEMO_VALUE}\n",
            f"'client_secret': '{DEMO_VALUE}'\n",
            f'export ACCESS_TOKEN="{DEMO_VALUE}"',
            f'const apiKey = "{DEMO_VALUE}";',
            f'const config = {{"api_key": "{DEMO_VALUE}"}};',
        )
        for content in samples:
            with self.subTest(format=content.split(" ", 1)[0]):
                self.assertIsNone(EXPORTER.read_source(self.source_file(content))[0])

    def test_preserves_runtime_references_and_empty_placeholders(self):
        for content in (
            'API_KEY = os.getenv("API_KEY")',
            "const apiKey = process.env.API_KEY;",
            'PASSWORD = ""',
            'API_KEY = "short"',
            'APPLICATION_NAME = "public application name"',
        ):
            with self.subTest(content=content):
                path = self.source_file(content)
                self.assertEqual(EXPORTER.read_source(path), (content.encode(), None))

    def test_rejects_binary_content(self):
        path = self.project / "binary.py"
        path.write_bytes(b"demo\x00data")
        self.assertEqual(EXPORTER.read_source(path), (None, "Contenu binaire"))

    def test_preserves_original_non_utf8_bytes(self):
        path = self.project / "main.py"
        original = b'# commentaire avec accent: \xe9\nprint("ok")\n'
        path.write_bytes(original)
        self.assertEqual(EXPORTER.read_source(path), (original, None))

    def test_excludes_sensitive_paths_and_files_outside_project(self):
        for name in (".env", ".env.local", "demo.key", "credentials-demo.json"):
            with self.subTest(name=name):
                path = self.project / name
                path.touch()
                self.assertIsNotNone(EXPORTER.exclusion_reason(self.project, path))
        outside = self.scratch / "outside.py"
        outside.touch()
        self.assertIsNotNone(EXPORTER.exclusion_reason(self.project, outside))

    def test_export_filters_literals_and_preserves_zip_content(self):
        original = b'# commentaire: \xe9\nprint("ok")\n'
        (self.project / "main.py").write_bytes(original)
        helper = b"public static class Demo { }\n"
        (self.project / "helper.cs").write_bytes(helper)
        self.source_file(f'API_KEY = "{DEMO_VALUE}"')
        fake_home = self.scratch / "home"
        with patch.object(Path, "home", return_value=fake_home):
            with contextlib.redirect_stdout(io.StringIO()):
                EXPORTER.export_project(self.project)
        destinations = list((fake_home / "Exports-IA").iterdir())
        self.assertEqual(len(destinations), 1)
        destination = destinations[0]
        with zipfile.ZipFile(destination / "02-CODE-SOURCE.zip") as archive:
            self.assertEqual(set(archive.namelist()), {"main.py", "helper.cs"})
            self.assertEqual(archive.read("main.py"), original)
            self.assertEqual(archive.read("helper.cs"), helper)
            self.assertIsNone(archive.testzip())
        context = (destination / "01-CONTEXTE.md").read_text(encoding="utf-8")
        self.assertIn("Secret potentiel detecte", context)
        self.assertNotIn(DEMO_VALUE, context)
        self.assertEqual((self.project / "main.py").read_bytes(), original)
        self.assertEqual(len(list(self.project.iterdir())), 3)

    @unittest.skipUnless(shutil.which("git"), "Git indisponible")
    def test_git_inventory_respects_ignored_files(self):
        subprocess.run(["git", "init", "--quiet", str(self.project)], check=True)
        (self.project / ".gitignore").write_text("ignored.txt\n", encoding="utf-8")
        (self.project / "ignored.txt").write_text("demo", encoding="utf-8")
        (self.project / "main.py").write_text('print("ok")', encoding="utf-8")
        files, git_used = EXPORTER.collect_files(self.project)
        self.assertTrue(git_used)
        self.assertEqual({path.name for path in files}, {".gitignore", "main.py"})


if __name__ == "__main__":
    unittest.main()
