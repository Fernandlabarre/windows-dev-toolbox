"""API Ollama factice : aucun modele, aucun acces aux projets."""
import argparse
import base64
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import time


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def send_bytes(self, payload, status=200, delay_body=False, location=None):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        if location:
            self.send_header("Location", location)
        self.end_headers()
        self.wfile.flush()
        if delay_body:
            time.sleep(3)
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def do_POST(self):
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 262144:
                raise ValueError("taille")
            request = json.loads(self.rfile.read(size).decode("utf-8"))
            messages = request["messages"]
            if (request["model"] != "qwen2.5-coder:7b" or request["stream"] is not False
                    or len(messages) != 2 or messages[0]["role"] != "system"
                    or messages[1]["role"] != "user" or "N invente jamais" not in messages[0]["content"]
                    or request["options"]["num_predict"] != 1024
                    or request["options"]["num_ctx"] != 16384
                    or request["options"]["temperature"] != 0.1):
                raise ValueError("contrat")
            user_content = messages[1]["content"].replace("\r\n", "\n")
            prefix = "QUESTION_UTILISATEUR:\n"
            if not user_content.startswith(prefix):
                raise ValueError("question")
            question = user_content[len(prefix):].split("\n\nCONTEXTE_FICHIER_LOCAL:", 1)[0]
            if question == "demo:context" and not all(marker in user_content for marker in (
                    "Chemin relatif : server/context-demo.ts", "Etat : modifications non enregistrees incluses",
                    "DEBUT_FICHIER", "UNSAVED_IDE_CONTEXT", "FIN_FICHIER")):
                raise ValueError("contexte")
        except (ValueError, KeyError, TypeError):
            self.send_bytes(b'{"error":"FAKE_BAD_REQUEST"}', 400)
            return
        if self.path == "/redirect-target":
            question = "demo:redirect-followed"
        elif self.path != "/api/chat":
            self.send_bytes(b'{"error":"FAKE_BAD_PATH"}', 404)
            return
        if question == "demo:missing":
            self.send_bytes(b'{"error":"DEMO_PRIVATE_ERROR"}', 404)
            return
        if question == "demo:server-error":
            self.send_bytes(b'{"error":"DEMO_PRIVATE_ERROR"}', 500)
            return
        if question == "demo:redirect":
            self.send_bytes(b"{}", 307, location=f"http://127.0.0.1:{self.server.server_port}/redirect-target")
            return
        if question == "demo:invalid-json":
            self.send_bytes(b"FAKE_NOT_JSON")
            return
        if question == "demo:slow-headers":
            time.sleep(3)
        text = "Reponse locale : caf\u00e9"
        if question.startswith("demo:utf8") and question != "demo:utf8 caf\u00e9":
            self.send_bytes(b'{"error":"FAKE_BAD_UTF8"}', 400)
            return
        if question == "demo:gui":
            marker = base64.b64encode(b"PROMPT_INJECTE (O/N)").decode()
            text = "GUI_OLLAMA_OK\n__SCRIPTS_PERSO_INPUT__:" + marker
        if question == "demo:context":
            text = "CONTEXT_OK"
        if question == "demo:mask":
            text = "API_KEY=DEMO_PRIVATE_VALUE\n-----BEGIN PRIVATE KEY-----\nDEMO_PRIVATE_BODY\n-----END PRIVATE KEY-----\nOK_MASK"
        if question == "demo:oversize":
            text = "x" * 270000
        if question == "demo:display-limit":
            text = "x" * 33000
        if question == "demo:empty":
            text = ""
        reply = {"model": "qwen2.5-coder:7b", "message": {"role": "assistant", "content": text},
                 "done": question != "demo:unfinished", "done_reason": "stop"}
        if question == "demo:length":
            reply["done_reason"] = "length"
        if question == "demo:wrong-model":
            reply["model"] = "MODELE_FACTICE"
        if question == "demo:api-error":
            reply = {"error": "DEMO_PRIVATE_ERROR"}
        self.send_bytes(json.dumps(reply, ensure_ascii=False).encode("utf-8"), delay_body=question == "demo:slow-body")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()
    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        port_file = Path(args.port_file)
        pending_file = port_file.with_suffix(port_file.suffix + ".tmp")
        pending_file.write_text(str(server.server_port), encoding="ascii")
        pending_file.replace(port_file)
        server.serve_forever()
