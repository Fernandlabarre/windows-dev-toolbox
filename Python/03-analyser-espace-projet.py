"""Mesure les tailles logiques d'un projet à partir des métadonnées.

Le parcours n'ouvre pas le contenu des fichiers et ne modifie pas le projet.
"""

import argparse
import heapq
import json
import os
from pathlib import Path
import re
import stat
import sys
import time


EXCLUDED_NAMES = {
    ".git", ".ssh", ".aws", ".azure", ".gcloud", ".gnupg", ".kube",
    ".codex", ".claude", ".agents", ".ollama", ".secrets", "secrets",
    ".credentials", "credentials", "certs", "certificates", "private",
    "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
}
PROTECTED_SUFFIXES = (
    ".env", ".pem", ".key", ".p12", ".pfx", ".crt", ".cer", ".der",
    ".jks", ".keystore", ".kdbx", ".db", ".sqlite", ".sqlite3", ".sql", ".dump",
)
SENSITIVE_NAME = re.compile(r"(^|[._-])(secrets?|credentials?|passwords?|tokens?|api[_-]?keys?)([._-]|$)", re.I)
TOKEN_NAME = re.compile(r"sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}")
FOLDER_CATEGORIES = {
    **dict.fromkeys(("node_modules", ".venv", "venv"), "dependencies"),
    **dict.fromkeys(("__pycache__", ".cache", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".npm", ".pnpm-store", ".parcel-cache", ".vite", ".turbo", ".gradle"), "caches"),
    **dict.fromkeys(("dist", "build", "target", "coverage", ".next", ".nuxt", ".output", ".nyc_output"), "generated"),
}
CATEGORY_LABELS = {
    "dependencies": "Dependances", "caches": "Caches possibles",
    "generated": "Sorties generees possibles", "archives": "Archives", "other": "Autres",
}
ARCHIVE_SUFFIXES = (".zip", ".7z", ".rar", ".tar", ".gz", ".bz2", ".xz", ".tgz", ".tbz2", ".zst", ".bak", ".backup")


def excluded_name(name):
    """Filtre un nom sensible avant toute lecture de ses métadonnées enfants."""
    lower = name.casefold()
    return (lower in EXCLUDED_NAMES or lower == ".env" or lower.startswith(".env.")
            or lower.endswith(PROTECTED_SUFFIXES) or bool(SENSITIVE_NAME.search(lower))
            or bool(TOKEN_NAME.search(name)))


def is_link(info):
    """Détecte les liens et les points de réanalyse propres à Windows."""
    return (stat.S_ISLNK(info.st_mode)
            or bool(getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT))


def add_size(bucket, size):
    bucket["bytes"] += size
    bucket["files"] += 1


def ranked_rows(buckets, count):
    return [dict(path=path, **values) for path, values in
            sorted(buckets.items(), key=lambda item: (-item[1]["bytes"], item[0]))[:count]]


def remember_largest(heap, count, size, relative):
    item = (size, relative)
    if len(heap) < count:
        heapq.heappush(heap, item)
    elif item > heap[0]:
        heapq.heapreplace(heap, item)


def analyse_project(project, top=10, max_entries=200000, timeout=30, max_depth=64):
    """Analyse un dossier avec des budgets explicites de temps et de volume."""
    if not 1 <= top <= 50 or not 1 <= max_entries <= 2000000 or not 1 <= timeout <= 600 or not 0 <= max_depth <= 256:
        raise ValueError("Limites de parcours invalides.")
    started = time.monotonic()
    root = Path(os.path.abspath(project))
    if any(excluded_name(part) for part in root.parts) or is_link(root.lstat()) or not stat.S_ISDIR(root.lstat().st_mode):
        raise ValueError("Choisis un dossier de projet ordinaire, hors des chemins proteges.")
    categories = {key: {"bytes": 0, "files": 0} for key in CATEGORY_LABELS}
    top_folders, known_folders = {}, {}
    largest_files, largest_archives = [], []
    skipped = {"protected": 0, "links": 0, "special": 0, "depth": 0}
    entries = directories = errors = total_files = total_bytes = 0
    limits = set()
    # Premiere categorie reconnue dans le chemin : groupes non superposes.
    stack = [(root, "", 0, None, None, None)]
    stop = False
    while stack and not stop:
        directory, relative, depth, top_folder, category, known_folder = stack.pop()
        if time.monotonic() - started >= timeout:
            limits.add("time")
            break
        try:
            # Recontroler les dossiers qui ont pu etre remplaces depuis leur decouverte.
            current_info = directory.lstat()
            if is_link(current_info):
                skipped["links"] += 1
                continue
            if not stat.S_ISDIR(current_info.st_mode):
                errors += 1
                continue
            with os.scandir(directory) as children:
                directories += 1
                for entry in children:
                    if entries >= max_entries or time.monotonic() - started >= timeout:
                        limits.add("entries" if entries >= max_entries else "time")
                        stop = True
                        break
                    entries += 1
                    if excluded_name(entry.name):
                        skipped["protected"] += 1
                        continue
                    child_relative = relative + "/" + entry.name if relative else entry.name
                    try:
                        info = entry.stat(follow_symlinks=False)
                    except OSError:
                        errors += 1
                        continue
                    if is_link(info):
                        skipped["links"] += 1
                        continue
                    if stat.S_ISDIR(info.st_mode):
                        if depth + 1 > max_depth:
                            skipped["depth"] += 1
                            limits.add("depth")
                            continue
                        child_top = top_folder if top_folder is not None else entry.name
                        top_folders.setdefault(child_top, {"bytes": 0, "files": 0})
                        child_category, child_known = category, known_folder
                        if child_category is None:
                            child_category = FOLDER_CATEGORIES.get(entry.name.casefold())
                            if child_category:
                                child_known = child_relative
                                known_folders[child_known] = {"bytes": 0, "files": 0, "category": child_category}
                        stack.append((Path(entry.path), child_relative, depth + 1, child_top, child_category, child_known))
                    elif stat.S_ISREG(info.st_mode) and info.st_size >= 0:
                        size = info.st_size
                        archive = entry.name.casefold().endswith(ARCHIVE_SUFFIXES)
                        file_category = category or ("archives" if archive else "other")
                        total_files += 1
                        total_bytes += size
                        add_size(categories[file_category], size)
                        row = top_folders.setdefault(top_folder or "", {"bytes": 0, "files": 0})
                        add_size(row, size)
                        if known_folder:
                            add_size(known_folders[known_folder], size)
                        remember_largest(largest_files, top, size, child_relative)
                        if archive:
                            remember_largest(largest_archives, top, size, child_relative)
                    else:
                        skipped["special"] += 1
        except OSError:
            errors += 1
    largest = lambda heap: [dict(path=path, bytes=size) for size, path in sorted(heap, key=lambda item: (-item[0], item[1]))]
    return {
        "status": "partial" if errors or limits else "complete", "project": str(root),
        "total_bytes": total_bytes, "total_files": total_files,
        "visited_directories": directories, "processed_entries": entries,
        "elapsed_seconds": round(time.monotonic() - started, 3),
        "skipped": skipped, "errors": errors, "limits_hit": sorted(limits),
        "limits": {"max_entries": max_entries, "timeout_seconds": timeout, "max_depth": max_depth},
        "categories": categories, "top_folders": ranked_rows(top_folders, top),
        "known_folders": ranked_rows(known_folders, top),
        "largest_files": largest(largest_files), "largest_archives": largest(largest_archives),
    }


def display_path(value):
    text = re.sub(r"[\x00-\x1f\x7f-\x9f\u2028\u2029\u202a-\u202e\u2066-\u2069]", "?", value)
    return text if len(text) <= 220 else text[:217] + "..."


def format_size(size):
    value = size
    for unit in ("o", "Kio", "Mio", "Gio", "Tio", "Pio"):
        if value < 1024 or unit == "Pio":
            return f"{value:.1f} {unit}" if unit != "o" else f"{value} o"
        value /= 1024


def print_report(report):
    print("=== ESPACE DU PROJET ===")
    print("Projet : " + display_path(report["project"]))
    print("Etat : " + ("Partiel" if report["status"] == "partial" else "Complet dans le perimetre mesure"))
    print(f"Taille logique mesuree : {format_size(report['total_bytes'])} | {report['total_files']} fichiers")
    print(f"Repertoires parcourus : {report['visited_directories']} | Entrees traitees : {report['processed_entries']} | {report['elapsed_seconds']}s")
    print("Tailles logiques des fichiers, hors exclusions. Ce ne sont pas des octets liberables.")
    print("Les liens physiques ne sont pas dedupliques ; le projet peut evoluer pendant le parcours.")
    print("\nREPARTITION (groupes non superposes)")
    for key, values in report["categories"].items():
        print(f"| {format_size(values['bytes']):>12} | {values['files']} fichiers | {CATEGORY_LABELS[key]}")
    sections = (
        ("PREMIER NIVEAU (fichiers de la racine inclus)", "top_folders"),
        ("DOSSIERS IDENTIFIES PAR LEUR NOM (indicatif)", "known_folders"),
        ("FICHIERS LES PLUS VOLUMINEUX", "largest_files"),
        ("ARCHIVES LES PLUS VOLUMINEUSES", "largest_archives"),
    )
    for title, field in sections:
        print("\n" + title)
        if not report[field]:
            print("| Aucun element mesure.")
        for row in report[field]:
            label = display_path(row["path"]) if row["path"] else "[fichiers de la racine]"
            category = " | " + CATEGORY_LABELS[row["category"]] if "category" in row else ""
            print(f"| {format_size(row['bytes']):>12} | {label}{category}")
    skipped = report["skipped"]
    print(f"\nExclusions : {skipped['protected']} entrees internes/sensibles, {skipped['links']} liens/reparse, {skipped['special']} fichiers speciaux.")
    print("Les contenus des dossiers exclus ne sont ni mesures ni denombres.")
    if report["status"] == "partial":
        reasons = {"time": "budget de temps", "entries": "nombre maximal d entrees", "depth": "profondeur maximale"}
        print(f"NON VERIFIE : {report['errors']} erreurs de metadonnees/acces ; " + ", ".join(reasons[key] for key in report["limits_hit"]))
        print("Les chiffres ci-dessus sont partiels.")
    print("\nRapport en lecture seule. Aucun classement ne prouve qu un dossier est inutile.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", nargs="?", default=".")
    parser.add_argument("--top", type=int, default=10)
    parser.add_argument("--max-entries", type=int, default=200000)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--max-depth", type=int, default=64)
    parser.add_argument("--json", action="store_true", help="Rapport JSON sur la sortie standard.")
    args = parser.parse_args(argv)
    try:
        report = analyse_project(args.project, args.top, args.max_entries, args.timeout, args.max_depth)
    except (OSError, ValueError):
        failure = {"status": "error", "detail": "Dossier inaccessible, protege, lie ou limites invalides."}
        print(json.dumps(failure) if args.json else "ERREUR : " + failure["detail"])
        return 1
    print(json.dumps(report, ensure_ascii=True)) if args.json else print_report(report)
    return 2 if report["status"] == "partial" else 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nAnalyse interrompue : rapport incomplet.")
        sys.exit(2)
