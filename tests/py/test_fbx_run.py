# -*- coding: utf-8 -*-
"""
Test d'intégration de tools/fbx-run.py avec un faux Freebox Player local.

Lancé par : python3 -m unittest discover -s tests/py -v

Sans réseau externe : tout se passe sur 127.0.0.1, sur des ports choisis
dynamiquement par l'OS pour éviter toute collision.

Le faux Player :
  - répond au POST /pub/devel en JSON-RPC 2.0 (vérifie la méthode, les
    params, que manifest_url est bien une URL http vers le PC exécutant le
    script, et que entry_point est bien transmis) ;
  - va réellement récupérer manifest.json puis le fichier de l'entry point
    (main.qml) sur le serveur HTTP démarré par fbx-run.py, ce qui prouve
    que ce serveur sert correctement les fichiers de l'application ;
  - vérifie aussi qu'un fichier sous build/ n'est pas servi (404), preuve
    que le serveur bloque bien ce répertoire ;
  - ouvre deux ports TCP bruts (stdout_port / stderr_port) qui émettent
    chacun quelques lignes, pour vérifier le relais [out]/[err] de
    fbx-run.py.

fbx-run.py est lancé en sous-processus, avec -t 127.0.0.1 et
--player-port <port libre> (le protocole réel utilise le port 80, mais on
le rend configurable pour que le faux Player puisse écouter sur un port
quelconque).
"""

import http.server
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FBX_RUN = REPO_ROOT / "tools" / "fbx-run.py"


def free_tcp_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class RawLineServer(threading.Thread):
    """Petit serveur TCP brut qui, à la première connexion, envoie
    quelques lignes puis garde la connexion ouverte (comme les ports
    stdout_port/stderr_port du Player)."""

    def __init__(self, lines):
        super().__init__(daemon=True)
        self.lines = lines
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.sock.settimeout(0.5)
        self.port = self.sock.getsockname()[1]
        self._stop = threading.Event()
        self._conn = None

    def run(self):
        conn = None
        while not self._stop.is_set() and conn is None:
            try:
                conn, _addr = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return

        if conn is None:
            return

        self._conn = conn
        try:
            for line in self.lines:
                conn.sendall((line + "\n").encode("utf-8"))
            while not self._stop.is_set():
                time.sleep(0.05)
        except OSError:
            pass

    def stop(self):
        self._stop.set()
        for sock in (self._conn, self.sock):
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
        self.join(timeout=2)


class FakePlayerState:
    def __init__(self):
        self.requests = []
        self.manifest_fetch = None  # (code, body) ou ("erreur", message)
        self.entry_fetch = None
        self.build_status = None
        self.lock = threading.Lock()


def make_fake_player_handler(state, stdout_port, stderr_port):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass  # silence pendant les tests

        def do_POST(self):
            if self.path != "/pub/devel":
                self.send_response(404)
                self.end_headers()
                return

            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)

            try:
                data = json.loads(body.decode("utf-8"))
            except ValueError:
                self.send_response(400)
                self.end_headers()
                return

            with state.lock:
                state.requests.append(data)

            params = data.get("params", {}) or {}
            manifest_url = params.get("manifest_url", "")

            # Récupère réellement manifest.json depuis le serveur du script.
            try:
                with urllib.request.urlopen(manifest_url, timeout=5) as r:
                    state.manifest_fetch = (r.getcode(), r.read())
            except Exception as e:  # pragma: no cover - diagnostic seulement
                state.manifest_fetch = ("erreur", str(e))

            # Puis le fichier de l'entry point, déduit du manifeste reçu.
            try:
                manifest_json = json.loads(state.manifest_fetch[1])
                entry_name = params.get("entry_point", "main")
                entry_file = manifest_json["entryPoints"][entry_name]["file"]
                base = manifest_url.rsplit("/", 1)[0]
                entry_url = base + "/" + entry_file
                with urllib.request.urlopen(entry_url, timeout=5) as r:
                    state.entry_fetch = (r.getcode(), r.read())
            except Exception as e:  # pragma: no cover
                state.entry_fetch = ("erreur", str(e))

            # Vérifie que build/ est bien bloqué par le serveur.
            try:
                base = manifest_url.rsplit("/", 1)[0]
                build_url = base + "/build/secret.txt"
                with urllib.request.urlopen(build_url, timeout=5) as r:
                    state.build_status = r.getcode()
            except urllib.error.HTTPError as e:
                state.build_status = e.code
            except Exception as e:  # pragma: no cover
                state.build_status = str(e)

            result = {
                "jsonrpc": "2.0",
                "id": data.get("id"),
                "result": {
                    "qml_port": 0,
                    "stdout_port": stdout_port,
                    "stderr_port": stderr_port,
                },
            }
            payload = json.dumps(result).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    return Handler


def _drain(stream, sink, stop_event):
    for line in iter(stream.readline, ""):
        if not line:
            break
        sink.append(line.rstrip("\n"))
        if stop_event.is_set():
            break


class FbxRunIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        root = Path(self.tmpdir.name)

        (root / "build").mkdir()
        (root / "build" / "secret.txt").write_text("ne doit jamais être servi\n")

        (root / "main.qml").write_text(
            "import QtQuick 2.0\nItem {\n    // contenu de test\n}\n"
        )

        manifest = {
            "name": "Test",
            "identifier": "com.exemple.test",
            "version": "1.0",
            "entryPoints": {
                "main": {"file": "main.qml", "default": True},
            },
        }
        self.manifest_path = root / "manifest.json"
        self.manifest_path.write_text(json.dumps(manifest))

        self.stdout_server = RawLineServer(["ligne stdout 1", "ligne stdout 2"])
        self.stderr_server = RawLineServer(["ligne stderr 1"])
        self.stdout_server.start()
        self.stderr_server.start()
        self.addCleanup(self.stdout_server.stop)
        self.addCleanup(self.stderr_server.stop)

        self.state = FakePlayerState()
        handler_cls = make_fake_player_handler(
            self.state, self.stdout_server.port, self.stderr_server.port
        )
        self.player_httpd = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), handler_cls
        )
        self.player_port = self.player_httpd.server_address[1]
        self.player_thread = threading.Thread(
            target=self.player_httpd.serve_forever, daemon=True
        )
        self.player_thread.start()
        self.addCleanup(self.player_httpd.shutdown)
        self.addCleanup(self.player_httpd.server_close)

        self.local_http_port = free_tcp_port()

        self.proc = subprocess.Popen(
            [
                sys.executable, str(FBX_RUN), str(self.manifest_path),
                "-t", "127.0.0.1",
                "--player-port", str(self.player_port),
                "-p", str(self.local_http_port),
                "--timeout", "5",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.addCleanup(self._kill_proc)

        self.out_lines = []
        self.err_lines = []
        self.stop_drain = threading.Event()
        self.out_thread = threading.Thread(
            target=_drain, args=(self.proc.stdout, self.out_lines, self.stop_drain),
            daemon=True,
        )
        self.err_thread = threading.Thread(
            target=_drain, args=(self.proc.stderr, self.err_lines, self.stop_drain),
            daemon=True,
        )
        self.out_thread.start()
        self.err_thread.start()

    def _kill_proc(self):
        self.stop_drain.set()
        if self.proc.poll() is None:
            try:
                self.proc.send_signal(signal.SIGINT)
                self.proc.wait(timeout=5)
            except Exception:
                self.proc.kill()
                self.proc.wait(timeout=5)
        for stream in (self.proc.stdout, self.proc.stderr):
            try:
                stream.close()
            except Exception:
                pass

    def _wait_for(self, predicate, timeout=10.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate():
                return True
            if self.proc.poll() is not None:
                # Le processus s'est arrêté prématurément : on abandonne
                # tout de suite plutôt que d'attendre le timeout complet.
                return predicate()
            time.sleep(0.05)
        return predicate()

    def test_run_relays_output_and_serves_files(self):
        # Le sous-processus doit atteindre le point où il relaie la sortie.
        ok = self._wait_for(
            lambda: any("ligne stdout 1" in l for l in self.out_lines)
            and any("ligne stderr 1" in l for l in self.err_lines)
        )
        self.assertTrue(
            ok,
            "sortie attendue non reçue.\nstdout={}\nstderr={}".format(
                self.out_lines, self.err_lines
            ),
        )

        # Préfixes attendus.
        self.assertTrue(any(l.startswith("[out]") for l in self.out_lines))
        self.assertTrue(any(l.startswith("[err]") for l in self.err_lines))
        self.assertTrue(any("ligne stdout 2" in l for l in self.out_lines))

        # La requête JSON-RPC reçue par le faux Player doit être conforme.
        self._wait_for(lambda: len(self.state.requests) >= 1, timeout=5)
        self.assertEqual(len(self.state.requests), 1)
        req = self.state.requests[0]
        self.assertEqual(req.get("jsonrpc"), "2.0")
        self.assertEqual(req.get("method"), "debug_qml_app")
        self.assertIn("id", req)

        params = req.get("params", {})
        self.assertEqual(params.get("entry_point"), "main")
        self.assertIn("wait", params)
        self.assertFalse(params.get("wait"))

        manifest_url = params.get("manifest_url", "")
        self.assertTrue(manifest_url.startswith("http://127.0.0.1:"))
        self.assertIn(":{}/manifest.json".format(self.local_http_port), manifest_url)

        # Le faux Player a bien pu récupérer manifest.json...
        self._wait_for(lambda: self.state.manifest_fetch is not None, timeout=5)
        self.assertIsNotNone(self.state.manifest_fetch)
        code, manifest_body = self.state.manifest_fetch
        self.assertEqual(code, 200)
        self.assertIn(b"com.exemple.test", manifest_body)

        # ...puis main.qml...
        self.assertIsNotNone(self.state.entry_fetch)
        entry_code, entry_body = self.state.entry_fetch
        self.assertEqual(entry_code, 200)
        self.assertIn(b"contenu de test", entry_body)

        # ...mais pas un fichier sous build/ (bloqué : 404).
        self.assertEqual(self.state.build_status, 404)

        # Arrêt propre par SIGINT : code de retour 0.
        self.proc.send_signal(signal.SIGINT)
        self.assertEqual(self.proc.wait(timeout=10), 0)


if __name__ == "__main__":
    unittest.main()
