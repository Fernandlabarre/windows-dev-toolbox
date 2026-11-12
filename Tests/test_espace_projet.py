"""Mesures et protections sur arborescences factices uniquement."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / "Python" / "03-analyser-espace-projet.py"
SPEC = importlib.util.spec_from_file_location("analyse_espace", SOURCE)
ANALYSER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ANALYSER)


class SpaceTests(unittest.TestCase):
    def setUp(self):
        self.temp_parent = Path(tempfile.gettempdir()).resolve()
        self.scratch = Path(tempfile.mkdtemp(prefix="scripts-perso-space-")).resolve()
        self.project = self.scratch / "Projet [1] avec l'apostrophe caf\u00e9"
        self.project.mkdir()
        self.junctions = []
        self.addCleanup(self.clean_scratch)

    def clean_scratch(self):
        if self.scratch.parent != self.temp_parent or not self.scratch.name.startswith("scripts-perso-space-"):
            raise RuntimeError("Nettoyage hors du dossier temporaire refuse")
        for junction in self.junctions:
            if not junction.absolute().is_relative_to(self.scratch) or not junction.resolve().is_relative_to(self.scratch):
                raise RuntimeError("Jonction de test hors du dossier temporaire")
            os.rmdir(junction)
        shutil.rmtree(self.scratch)

    def file(self, relative, size):
        path = self.project / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x" * size)
        return path

    def link(self):
        outside = self.scratch / "hors-projet"
        outside.mkdir()
        (outside / "volume.bin").write_bytes(b"x" * 1000)
        linked = self.project / "raccourci"
        try:
            os.symlink(outside, linked, target_is_directory=True)
        except OSError:
            if os.name != "nt":
                self.skipTest("Liens non autorises sur ce systeme")
            try:
                import _winapi
                _winapi.CreateJunction(str(outside), str(linked))
            except (OSError, AttributeError):
                self.skipTest("Jonctions non disponibles sur ce systeme")
            self.junctions.append(linked)
        return linked

    def test_totals_categories_and_first_level_are_consistent(self):
        fixtures = {"main.py": 10, "src/app.py": 20, "node_modules/pkg/a.js": 40,
                    "src/.cache/result.bin": 50, "dist/app.js": 60, "archives/demo.zip": 70}
        for name, size in fixtures.items():
            self.file(name, size)
        report = ANALYSER.analyse_project(self.project)
        self.assertEqual(report["status"], "complete")
        self.assertEqual(report["total_bytes"], sum(fixtures.values()))
        self.assertEqual(report["total_files"], len(fixtures))
        self.assertEqual(sum(row["bytes"] for row in report["categories"].values()), report["total_bytes"])
        self.assertEqual(sum(row["bytes"] for row in report["top_folders"]), report["total_bytes"])
        self.assertEqual(report["categories"]["caches"]["bytes"], 50)
        self.assertEqual(report["categories"]["dependencies"]["bytes"], 40)
        self.assertEqual(report["largest_archives"][0]["path"], "archives/demo.zip")

    def test_nested_known_folders_do_not_double_count(self):
        self.file("node_modules/.cache/pack.zip", 15)
        self.file("node_modules/pkg/build/output.bin", 25)
        report = ANALYSER.analyse_project(self.project)
        self.assertEqual(report["known_folders"], [{"path": "node_modules", "bytes": 40, "files": 2, "category": "dependencies"}])
        self.assertEqual(report["categories"]["archives"]["bytes"], 0)
        self.assertEqual(report["largest_archives"][0]["bytes"], 15)

    def test_rankings_are_bounded_and_sorted(self):
        for index in range(6):
            self.file(f"d{index}/archive{index}.ZIP", index + 1)
        report = ANALYSER.analyse_project(self.project, top=2)
        for field in ("top_folders", "largest_files", "largest_archives"):
            self.assertEqual(len(report[field]), 2)
            self.assertEqual([row["bytes"] for row in report[field]], [6, 5])

    def test_protected_paths_are_not_measured_or_reported(self):
        for name in (".env", ".env.local", "client-secret.json", "certificat.pem", "database.sqlite",
                     ".git/objects/large", ".codex/sessions/large", "secrets/large", ".ssh/large"):
            self.file(name, 100)
        self.file("public.txt", 7)
        report = ANALYSER.analyse_project(self.project)
        self.assertEqual(report["total_bytes"], 7)
        self.assertEqual(report["skipped"]["protected"], 9)
        encoded = json.dumps(report)
        for name in (".env", "client-secret", "certificat.pem", "database.sqlite", ".git", ".codex", "secrets/", ".ssh"):
            self.assertNotIn(name, encoded)

    def test_analysis_does_not_open_contents_or_modify_files(self):
        sample = self.file("ordinary.bin", 19)
        self.file(".env", 11)
        before = (sample.stat().st_size, sample.stat().st_mtime_ns, sorted(p.name for p in self.project.iterdir()))
        failure = AssertionError("Lecture de contenu ou ecriture interdite")
        with contextlib.ExitStack() as stack:
            for target in ("builtins.open", "io.open", "os.open", "os.read", "os.remove", "os.unlink", "os.rename", "os.replace", "pathlib.Path.mkdir"):
                stack.enter_context(patch(target, side_effect=failure))
            report = ANALYSER.analyse_project(self.project)
        after = (sample.stat().st_size, sample.stat().st_mtime_ns, sorted(p.name for p in self.project.iterdir()))
        self.assertEqual(before, after)
        self.assertEqual(report["total_bytes"], 19)

    def test_access_error_produces_partial_report(self):
        self.file("visible.bin", 9)
        self.file("indisponible/other.bin", 30)
        original = os.scandir

        def guarded(path):
            if Path(path).name == "indisponible":
                raise PermissionError("DEMO_PRIVATE_PATH")
            return original(path)

        with patch.object(ANALYSER.os, "scandir", side_effect=guarded):
            report = ANALYSER.analyse_project(self.project)
        self.assertEqual(report["status"], "partial")
        self.assertEqual(report["errors"], 1)
        self.assertEqual(report["total_bytes"], 9)
        self.assertNotIn("DEMO_PRIVATE_PATH", json.dumps(report))

    def test_disappeared_file_is_not_silently_ignored(self):
        def missing(**_kwargs):
            raise FileNotFoundError("DEMO_MISSING")
        entry = SimpleNamespace(name="disparu.bin", path="unused", stat=missing)
        with patch.object(ANALYSER.os, "scandir", return_value=contextlib.nullcontext([entry])):
            report = ANALYSER.analyse_project(self.project)
        self.assertEqual((report["status"], report["errors"], report["total_files"]), ("partial", 1, 0))

    def test_entry_budget_produces_partial_report(self):
        for index in range(4):
            self.file(f"f{index}.bin", 3)
        report = ANALYSER.analyse_project(self.project, max_entries=2)
        self.assertEqual((report["status"], report["processed_entries"], report["total_files"]), ("partial", 2, 2))
        self.assertIn("entries", report["limits_hit"])

    def test_exact_entry_budget_is_still_complete(self):
        self.file("only.bin", 1)
        self.assertEqual(ANALYSER.analyse_project(self.project, max_entries=1)["status"], "complete")

    def test_time_budget_is_checked_after_directory_open(self):
        self.file("ordinary.bin", 5)
        elapsed = {"seconds": 0}
        original = os.scandir

        def delayed(path):
            elapsed["seconds"] = 2
            return original(path)

        with patch.object(ANALYSER.time, "monotonic", side_effect=lambda: elapsed["seconds"]), patch.object(ANALYSER.os, "scandir", side_effect=delayed):
            report = ANALYSER.analyse_project(self.project, timeout=1)
        self.assertEqual(report["status"], "partial")
        self.assertIn("time", report["limits_hit"])
        self.assertEqual(report["total_files"], 0)

    def test_depth_budget_does_not_count_unvisited_files(self):
        self.file("ordinary.bin", 5)
        self.file("nested/other.bin", 20)
        report = ANALYSER.analyse_project(self.project, max_depth=0)
        self.assertEqual((report["status"], report["total_bytes"]), ("partial", 5))
        self.assertIn("depth", report["limits_hit"])

    def test_real_link_or_windows_junction_is_not_followed(self):
        self.link()
        self.file("ordinary.bin", 5)
        report = ANALYSER.analyse_project(self.project)
        self.assertEqual(report["total_bytes"], 5)
        self.assertEqual(report["skipped"]["links"], 1)
        self.assertEqual(report["visited_directories"], 1)

    def test_linked_root_is_rejected(self):
        with self.assertRaises(ValueError):
            ANALYSER.analyse_project(self.link())

    def test_windows_reparse_file_is_not_measured(self):
        metadata = SimpleNamespace(st_mode=stat.S_IFREG, st_file_attributes=stat.FILE_ATTRIBUTE_REPARSE_POINT, st_size=100)
        entry = SimpleNamespace(name="cloud.bin", path="unused", stat=lambda **_kwargs: metadata)
        with patch.object(ANALYSER.os, "scandir", return_value=contextlib.nullcontext([entry])):
            report = ANALYSER.analyse_project(self.project)
        self.assertEqual((report["total_bytes"], report["skipped"]["links"]), (0, 1))

    def test_display_cannot_inject_launcher_protocol(self):
        report = ANALYSER.analyse_project(self.project)
        report["largest_files"] = [{"bytes": 1, "path": "demo\n__SCRIPTS_PERSO_INPUT__:ZGVtbw==\x1b[2J"}]
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            ANALYSER.print_report(report)
        self.assertFalse(any(line.startswith("__SCRIPTS_PERSO_INPUT__:") for line in output.getvalue().splitlines()))
        self.assertNotIn("\x1b", output.getvalue())

    def test_cli_json_complete_partial_and_error(self):
        def run(*arguments):
            result = subprocess.run([sys.executable, "-B", str(SOURCE), *map(str, arguments), "--json"], capture_output=True, encoding="utf-8", timeout=10)
            self.assertEqual(result.stderr, "")
            return result.returncode, json.loads(result.stdout)
        code, report = run(self.project)
        self.assertEqual((code, report["status"], report["total_bytes"]), (0, "complete", 0))
        self.file("one.bin", 1)
        self.file("two.bin", 2)
        code, report = run(self.project, "--max-entries", 1)
        self.assertEqual((code, report["status"]), (2, "partial"))
        for arguments in ((self.scratch / "absent",), (self.project, "--top", 0)):
            code, report = run(*arguments)
            self.assertEqual((code, report["status"]), (1, "error"))


if __name__ == "__main__":
    unittest.main()
