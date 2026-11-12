"""Serveur statique minimal utilisé par le gestionnaire PowerShell.

Le serveur n'expose jamais la racine du projet : il sert uniquement un
sous-dossier public validé, sur l'interface de boucle locale.
"""

import argparse
import functools
import re
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit


PRIVATE_EXTENSIONS = {".pem", ".key", ".p12", ".pfx", ".p8", ".jks", ".keystore", ".sql", ".sqlite", ".db", ".py", ".ps1", ".bat", ".cmd", ".sh"}
PRIVATE_NAMES = {"node_modules", "id_rsa", "id_ed25519", "package.json", "package-lock.json"}


def private_part(part):
    """Indique si un composant de chemin ne doit jamais être servi."""
    name = part.casefold()
    return (
        name.startswith(".")
        or name in PRIVATE_NAMES
        or name.endswith(".env")
        or re.search(r"credentials|secrets?|private[_-]?key", name) is not None
        or Path(name).suffix in PRIVATE_EXTENSIONS
    )


class PublicFilesHandler(SimpleHTTPRequestHandler):
    """Gestionnaire HTTP sans listing ni journalisation des URL demandées."""

    def send_head(self):
        # Décoder avant le contrôle empêche de contourner les règles avec une
        # séquence URL encodée. Le second resolve() bloque aussi les liens qui
        # sortiraient du dossier public.
        decoded = unquote(urlsplit(self.path).path)
        parts = [part for part in decoded.split("/") if part]
        if "\\" in decoded or ":" in decoded or any(private_part(part) for part in parts):
            self.send_error(403)
            return None
        root = Path(self.directory).resolve()
        candidate = root.joinpath(*parts).resolve()
        if not candidate.is_relative_to(root) or any(private_part(part) for part in candidate.relative_to(root).parts):
            self.send_error(403)
            return None
        if candidate.is_dir():
            for index in ("index.html", "index.htm"):
                target = candidate / index
                if target.exists():
                    resolved = target.resolve()
                    if not resolved.is_relative_to(root) or any(private_part(part) for part in resolved.relative_to(root).parts):
                        self.send_error(403)
                        return None
        return super().send_head()

    def list_directory(self, path):
        self.send_error(403)
        return None

    def log_request(self, code="-", size="-"):
        # Aucun chemin, parametre de requete ou identifiant de client dans les logs.
        print(f"HTTP {code}", flush=True)

    def log_message(self, format, *args):
        print("Incident HTTP local", flush=True)


def create_server(project, directory, port):
    """Construit un serveur lié à 127.0.0.1 après validation du dossier."""
    project = Path(project).resolve()
    root = Path(directory).resolve()
    if not root.is_dir() or root == project or not root.is_relative_to(project):
        raise ValueError("Choisir un sous-dossier public du projet")
    handler = functools.partial(PublicFilesHandler, directory=str(root))
    return ThreadingHTTPServer(("127.0.0.1", port), handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--directory", required=True)
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error("Port hors limites")
    try:
        with create_server(args.project, args.directory, args.port) as server:
            print(f"Adresse locale : http://127.0.0.1:{server.server_port}/", flush=True)
            server.serve_forever()
    except (OSError, ValueError):
        print("ERREUR : dossier refuse ou port indisponible.", flush=True)
        return 1
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
