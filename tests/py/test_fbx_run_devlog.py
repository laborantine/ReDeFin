"""Tests du journal de debug servi par tools/fbx-run.py : le drapeau ENABLED
de qml/js/DevLog.js est basculé à la volée, sans toucher au fichier sur
disque, et uniquement si l'option est active."""

import importlib.util
import socket
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FBX_RUN = REPO_ROOT / "tools" / "fbx-run.py"

_spec = importlib.util.spec_from_file_location("fbx_run", FBX_RUN)
fbx_run = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fbx_run)

DEVLOG_SOURCE = b"// en-tete\n.pragma library\nvar ENABLED = false;\nfunction log(){}\n"


def free_tcp_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class EnableDevlogSourceTest(unittest.TestCase):
    def test_flips_the_flag_once(self):
        out = fbx_run.enable_devlog_source(DEVLOG_SOURCE)
        self.assertIn(b"var ENABLED = true;", out)
        self.assertNotIn(b"var ENABLED = false;", out)
        self.assertEqual(out.count(b"ENABLED"), DEVLOG_SOURCE.count(b"ENABLED"))

    def test_rejects_missing_duplicated_or_already_enabled_flag(self):
        for bad in (
            b"var enabled = false;",
            DEVLOG_SOURCE + b"var ENABLED = false;\n",
            DEVLOG_SOURCE.replace(b"false", b"true"),
            DEVLOG_SOURCE + b"var ENABLED = true;\n",
        ):
            with self.assertRaises(fbx_run.FbxRunError):
                fbx_run.enable_devlog_source(bad)

    def test_real_repository_file_is_accepted(self):
        data = (REPO_ROOT / "qml" / "js" / "DevLog.js").read_bytes()
        self.assertIn(b"var ENABLED = true;", fbx_run.enable_devlog_source(data))


class DevlogServerTest(unittest.TestCase):
    def _serve(self, dev_log):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / "qml" / "js").mkdir(parents=True)
        (root / "qml" / "js" / "DevLog.js").write_bytes(DEVLOG_SOURCE)
        (root / "qml" / "js" / "Other.js").write_bytes(b"var ENABLED = false;\n")
        port = free_tcp_port()
        server = fbx_run.AppServer("127.0.0.1", port, str(root), dev_log=dev_log)
        server.start()
        self.addCleanup(server.stop)
        return root, "http://127.0.0.1:{}".format(port)

    def _get(self, url):
        with urllib.request.urlopen(url, timeout=5) as rsp:
            return rsp.read(), rsp.headers

    def test_flag_is_enabled_on_the_fly_only_for_devlog(self):
        root, base = self._serve(dev_log=True)
        body, headers = self._get(base + "/qml/js/DevLog.js")
        self.assertIn(b"var ENABLED = true;", body)
        self.assertEqual(int(headers["Content-Length"]), len(body))
        self.assertIn("no-cache", headers["Cache-Control"])
        # Le Player ajoute parfois une chaîne de requête : même résultat.
        body2, _ = self._get(base + "/qml/js/DevLog.js?ctx=1")
        self.assertIn(b"var ENABLED = true;", body2)
        # Un chemin avec « .. » reste refusé par la protection du serveur.
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            self._get(base + "/qml/js/../js/DevLog.js")
        self.assertEqual(ctx.exception.code, 404)
        # Les autres fichiers ne sont jamais réécrits.
        other, _ = self._get(base + "/qml/js/Other.js")
        self.assertEqual(other, b"var ENABLED = false;\n")
        # Le fichier sur disque est intact.
        self.assertEqual((root / "qml" / "js" / "DevLog.js").read_bytes(), DEVLOG_SOURCE)

    def test_flag_is_untouched_when_option_is_off(self):
        _, base = self._serve(dev_log=False)
        body, _ = self._get(base + "/qml/js/DevLog.js")
        self.assertEqual(body, DEVLOG_SOURCE)


if __name__ == "__main__":
    unittest.main()
