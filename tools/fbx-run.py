#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fbx-run.py - Lance à distance une application QML sur un Freebox Player
(Révolution) placé en « mode développeur ».

Portage Python 3 (stdlib uniquement) du script historique `fbx-qml-run`
(Python 2.7, dépôt Free `freebox-dev-utils`, 2014) et du plugin QtCreator
`freebox-qtcreator-plugin` (même année), qui documentent le seul protocole
connu pour ce mode :

  1. Ce script sert en HTTP le répertoire contenant le manifest.json de
     l'application (serveur HTTP local, jetable, lié à une adresse et un
     port choisis).
  2. Il envoie au Player une requête JSON-RPC 2.0 en POST sur
     `http://<player>/pub/devel`, méthode `debug_qml_app`, avec en
     paramètres l'URL du manifeste (`manifest_url`), le point d'entrée
     (`entry_point`) et un indicateur d'attente de débogueur (`wait`).
  3. Le Player répond avec trois ports TCP (`qml_port`, `stdout_port`,
     `stderr_port`) sur lesquels se connecter pour piloter/observer
     l'application qu'il vient de lancer. Ce script relaie en continu la
     sortie standard et la sortie d'erreur de l'application sur le
     terminal, jusqu'à interruption (Ctrl-C).

Ce protocole n'est pas documenté officiellement par Free : il est déduit du
code source des deux dépôts cités ci-dessus. Il n'a pas été vérifié sur un
Player physique lors de l'écriture de ce script — voir tools/README.md pour
le détail des limites.
"""

import argparse
import functools
import http.server
import json
import os
import posixpath
import random
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# --------------------------------------------------------------------------
# Constantes du protocole
# --------------------------------------------------------------------------

# Répertoires/fichiers jamais servis par le serveur HTTP local, même s'ils
# sont physiquement présents à côté du manifeste (on ne sert que ce dont
# l'application a besoin, jamais l'outillage de développement du dépôt).
BLOCKED_TOP_LEVEL_DIRS = {"build", "tests", "tools"}

# Règles de validation du manifeste, reprises telles quelles du packager
# Free (fileformat/manifest.cc du plugin QtCreator) :
#   - identifier : \w+(\.\w+)+  (ex : com.exemple.application)
#   - entryPoints.<nom>.file : [/\w.+~-]+
#   - entryPoints.<nom>.uiFlavor (optionnel) : multi|classic
IDENTIFIER_RE = re.compile(r"\w+(\.\w+)+")
ENTRY_FILE_RE = re.compile(r"[/\w.+~-]+")
UI_FLAVOR_RE = re.compile(r"(multi|classic)", re.IGNORECASE)

# Répertoire du script et manifeste par défaut (celui du dépôt ReDeFin),
# résolus indépendamment du répertoire courant d'où le script est appelé.
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_MANIFEST = SCRIPT_DIR.parent / "manifest.json"

WSL2_HELP = """\
Note WSL2 :
  Le Freebox Player doit pouvoir joindre ce PC sur le réseau local pour
  récupérer le manifeste et l'application. En réseau NAT (mode par défaut
  de WSL2), ce n'est PAS le cas : l'IP interne de WSL2 n'est pas jointe
  depuis le LAN. Trois solutions :
    1. Passer WSL2 en réseau miroir : ajouter la ligne
       'networkingMode=mirrored' dans %UserProfile%\\.wslconfig, puis
       'wsl --shutdown' et rouvrir un terminal.
    2. Lancer ce script directement avec un interpréteur Python Windows
       (hors WSL2), sur le même réseau que le Player.
    3. Rester sous WSL2 mais annoncer l'IP Windows avec -b/--bind, et
       rediriger le port HTTP local vers WSL2 avec
       'netsh interface portproxy add v4tov4 listenaddress=<ip_windows>
       listenport=<port> connectaddress=<ip_wsl2> connectport=<port>'
       (exécuté côté Windows, en administrateur).
"""


class FbxRunError(Exception):
    """Erreur explicite destinée à être affichée à l'utilisateur (en
    français), sans trace Python."""


# --------------------------------------------------------------------------
# Validation du manifeste
# --------------------------------------------------------------------------

def load_and_validate_manifest(manifest_path, entry_name):
    """Charge et valide manifest_path selon les règles du packager Free.

    Retourne (manifest, app_dir, entry_file) où app_dir est le répertoire
    contenant le manifeste (racine servie en HTTP) et entry_file le chemin
    (relatif à app_dir) du fichier QML du point d'entrée demandé.

    Lève FbxRunError avec un message en français en cas de problème.
    """
    if not os.path.isfile(manifest_path):
        raise FbxRunError("manifeste introuvable : {}".format(manifest_path))

    try:
        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
    except json.JSONDecodeError as e:
        raise FbxRunError(
            "manifeste JSON invalide ({}) : {}".format(manifest_path, e)
        ) from e
    except OSError as e:
        raise FbxRunError(
            "impossible de lire le manifeste {} : {}".format(manifest_path, e)
        ) from e

    if not isinstance(manifest, dict):
        raise FbxRunError("le manifeste doit être un objet JSON (dictionnaire).")

    identifier = manifest.get("identifier")
    if not isinstance(identifier, str) or not IDENTIFIER_RE.fullmatch(identifier):
        raise FbxRunError(
            "le champ 'identifier' est requis et doit être de la forme "
            "'mot.mot' (ex : com.exemple.application) ; valeur actuelle : {!r}"
            .format(identifier)
        )

    entry_points = manifest.get("entryPoints")
    if not isinstance(entry_points, dict) or not entry_points:
        raise FbxRunError("le champ 'entryPoints' doit être un objet non vide.")

    for name, ep in entry_points.items():
        if not isinstance(ep, dict):
            raise FbxRunError("entryPoints.{} doit être un objet.".format(name))

        file_value = ep.get("file")
        if not isinstance(file_value, str) or not ENTRY_FILE_RE.fullmatch(file_value):
            raise FbxRunError(
                "entryPoints.{}.file est requis et doit être un chemin valide."
                .format(name)
            )

        if "uiFlavor" in ep:
            ui_flavor = ep["uiFlavor"]
            if not isinstance(ui_flavor, str) or not UI_FLAVOR_RE.fullmatch(ui_flavor):
                raise FbxRunError(
                    "entryPoints.{}.uiFlavor doit valoir 'multi' ou 'classic'."
                    .format(name)
                )

        if "default" in ep and not isinstance(ep["default"], bool):
            raise FbxRunError(
                "entryPoints.{}.default doit être un booléen.".format(name)
            )

    if entry_name not in entry_points:
        raise FbxRunError(
            "point d'entrée '{}' absent de entryPoints (disponibles : {})."
            .format(entry_name, ", ".join(sorted(entry_points)))
        )

    entry_file = entry_points[entry_name]["file"]
    app_dir = os.path.dirname(os.path.abspath(manifest_path))
    entry_path = os.path.join(app_dir, entry_file)

    if not os.path.isfile(entry_path):
        raise FbxRunError(
            "le fichier du point d'entrée '{}' est introuvable : {}"
            .format(entry_name, entry_path)
        )

    return manifest, app_dir, entry_file


# --------------------------------------------------------------------------
# Serveur HTTP local (sert le répertoire de l'application)
# --------------------------------------------------------------------------

# Journal de diagnostic de l'application (qml/js/DevLog.js) : le dépôt et les
# paquets contiennent le drapeau à false ; ce serveur le bascule à la volée,
# sans jamais toucher au fichier sur disque.
DEVLOG_URL_PATH = "/qml/js/DevLog.js"
DEVLOG_FLAG_OFF = b"var ENABLED = false;"
DEVLOG_FLAG_ON = b"var ENABLED = true;"


def enable_devlog_source(data):
    """Renvoie le contenu de DevLog.js avec le drapeau activé. Lève
    FbxRunError si la ligne du drapeau n'est pas présente exactement une
    fois (fichier reformaté ou déjà activé)."""
    if data.count(DEVLOG_FLAG_OFF) != 1 or DEVLOG_FLAG_ON in data:
        raise FbxRunError(
            "qml/js/DevLog.js ne contient pas exactement une ligne "
            "'{}' : impossible d'activer le journal de debug."
            .format(DEVLOG_FLAG_OFF.decode())
        )
    return data.replace(DEVLOG_FLAG_OFF, DEVLOG_FLAG_ON)


def _is_forbidden_path(url_path):
    """Vrai si le chemin demandé ne doit jamais être servi : fichiers
    cachés (dont .git/...), et répertoires build/, tests/, tools/ à la
    racine servie."""
    path = urllib.parse.unquote(urllib.parse.urlsplit(url_path).path)
    parts = [p for p in path.split("/") if p not in ("", ".")]

    for part in parts:
        if part.startswith("."):
            return True

    if parts and parts[0] in BLOCKED_TOP_LEVEL_DIRS:
        return True

    return False


def _make_handler_class(app_dir, verbose, dev_log=False):
    """Construit une classe de handler HTTP dédiée à app_dir, pour pouvoir
    passer `directory=` à SimpleHTTPRequestHandler tout en gardant un
    indicateur verbose par serveur (et non global au module)."""

    class Handler(http.server.SimpleHTTPRequestHandler):
        def end_headers(self):
            # Le Player ne doit jamais mettre en cache les fichiers servis
            # ici : ils changent à chaque lancement.
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
            super().end_headers()

        def log_message(self, fmt, *args):
            if verbose:
                sys.stderr.write(
                    "[serveur] {} - {}\n".format(self.address_string(), fmt % args)
                )

        def _refuse_if_forbidden(self):
            if _is_forbidden_path(self.path):
                self.send_error(404, "Introuvable")
                return True
            return False

        def _serve_devlog_if_requested(self, with_body):
            """Sert qml/js/DevLog.js avec le drapeau activé. Renvoie True
            si la requête a été traitée ici."""
            if not dev_log:
                return False
            url_path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
            if posixpath.normpath(url_path) != DEVLOG_URL_PATH:
                return False
            local = os.path.join(app_dir, *DEVLOG_URL_PATH.strip("/").split("/"))
            try:
                with open(local, "rb") as fh:
                    body = enable_devlog_source(fh.read())
            except (OSError, FbxRunError):
                # Fichier absent ou drapeau introuvable : on sert le fichier
                # tel quel (journal inactif) plutôt que de casser le lancement.
                return False
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if with_body:
                self.wfile.write(body)
            return True

        def do_GET(self):
            if self._refuse_if_forbidden():
                return
            if self._serve_devlog_if_requested(True):
                return
            super().do_GET()

        def do_HEAD(self):
            if self._refuse_if_forbidden():
                return
            if self._serve_devlog_if_requested(False):
                return
            super().do_HEAD()

    return functools.partial(Handler, directory=app_dir)


class AppServer:
    """Serveur HTTP threadé servant app_dir, lié à (bind_addr, port)."""

    def __init__(self, bind_addr, port, app_dir, verbose=False, dev_log=False):
        handler = _make_handler_class(app_dir, verbose, dev_log)
        self.httpd = http.server.ThreadingHTTPServer((bind_addr, port), handler)
        self.bind_addr = bind_addr
        self.port = port
        self._thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def start(self):
        self._thread.start()

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self._thread.join(timeout=5)

    def file_url(self, name):
        return "http://{}:{}/{}".format(self.bind_addr, self.port, name)


# --------------------------------------------------------------------------
# Découverte de l'adresse locale et du Player (mDNS)
# --------------------------------------------------------------------------

def local_address_to(host, port, timeout=5.0):
    """Adresse IP locale utilisée pour joindre (host, port), obtenue via
    getsockname() sur une connexion TCP réelle (seul moyen fiable de savoir
    quelle interface/IP locale le Player verra)."""
    try:
        with socket.create_connection((host, port), timeout=timeout) as s:
            return s.getsockname()[0]
    except OSError as e:
        raise FbxRunError(
            "Player injoignable sur {}:{} ({}). Vérifiez l'adresse IP indiquée "
            "avec -t et que le Player est bien allumé et sur le même réseau."
            .format(host, port, e)
        ) from e


class _MdnsListener:
    def __init__(self):
        self.found = []

    def add_service(self, zeroconf, service_type, name):
        info = zeroconf.get_service_info(service_type, name)
        if not info:
            return
        addrs = info.parsed_addresses() if hasattr(info, "parsed_addresses") else []
        if addrs:
            self.found.append(addrs[0])

    def update_service(self, zeroconf, service_type, name):
        pass

    def remove_service(self, zeroconf, service_type, name):
        pass


def discover_via_mdns(service="_fbx-devel._tcp.local.", timeout=3.0):
    """Recherche un Player par mDNS. Retourne son IP, ou None si le module
    `zeroconf` n'est pas installé ou si rien n'a répondu à temps."""
    try:
        from zeroconf import ServiceBrowser, Zeroconf
    except ImportError:
        return None

    zc = Zeroconf()
    listener = _MdnsListener()
    ServiceBrowser(zc, service, listener)

    try:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if listener.found:
                return listener.found[0]
            time.sleep(0.1)
        return listener.found[0] if listener.found else None
    finally:
        zc.close()


# --------------------------------------------------------------------------
# Appel JSON-RPC (méthode debug_qml_app)
# --------------------------------------------------------------------------

def jsonrpc_call(endpoint, method, params, timeout=10.0):
    request_id = str(random.randint(1, 1_000_000))
    payload = json.dumps({
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": request_id,
    }).encode("utf-8")

    request = urllib.request.Request(
        endpoint,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status = response.getcode()
            body = response.read()
    except socket.timeout as e:
        raise FbxRunError(
            "délai dépassé ({} s) en attendant la réponse du Player sur {}."
            .format(timeout, endpoint)
        ) from e
    except urllib.error.HTTPError as e:
        raise FbxRunError(
            "le Player a répondu HTTP {} sur {} (le mode développeur est-il "
            "bien activé sur le Player ?)."
            .format(e.code, endpoint)
        ) from e
    except urllib.error.URLError as e:
        if isinstance(e.reason, socket.timeout):
            raise FbxRunError(
                "délai dépassé ({} s) en attendant la réponse du Player sur {}."
                .format(timeout, endpoint)
            ) from e
        raise FbxRunError(
            "impossible de joindre le Player sur {} ({}). Le mode "
            "développeur est-il activé sur le Player ?"
            .format(endpoint, e.reason)
        ) from e

    if status != 200:
        raise FbxRunError(
            "le Player a répondu HTTP {} (attendu : 200) sur {} (le mode "
            "développeur est-il bien activé sur le Player ?)."
            .format(status, endpoint)
        )

    try:
        data = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise FbxRunError(
            "réponse du Player illisible (JSON invalide) sur {}.".format(endpoint)
        ) from e

    if str(data.get("id")) != request_id:
        raise FbxRunError(
            "identifiant de requête JSON-RPC incohérent dans la réponse du Player."
        )

    if "error" in data:
        err = data.get("error") or {}
        raise FbxRunError(
            "erreur JSON-RPC du Player (code {}) : {} (le mode développeur "
            "est-il bien activé sur le Player ?)."
            .format(err.get("code", "?"), err.get("message", ""))
        )

    if "result" not in data:
        raise FbxRunError("réponse du Player sans 'result' ni 'error'.")

    return data["result"]


# --------------------------------------------------------------------------
# Relais des sorties standard / erreur de l'application distante
# --------------------------------------------------------------------------

class StreamRelay(threading.Thread):
    """Se connecte à (host, port) et relaie chaque ligne reçue sur
    out_stream, préfixée par [prefix]. La connexion se fait dans le thread
    appelant (pour pouvoir échouer explicitement avant de lancer le
    thread) ; la lecture se fait ensuite en tâche de fond."""

    def __init__(self, host, port, prefix, out_stream, connect_timeout=10.0):
        super().__init__(daemon=True)
        self.prefix = prefix
        self.out_stream = out_stream
        self.sock = socket.create_connection((host, port), timeout=connect_timeout)
        self.sock.settimeout(0.5)
        self._stop = threading.Event()

    def run(self):
        buf = b""
        while not self._stop.is_set():
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                self._emit(line)
        if buf:
            self._emit(buf)

    def _emit(self, line_bytes):
        text = line_bytes.decode("utf-8", errors="replace").rstrip("\r")
        try:
            print("[{}] {}".format(self.prefix, text), file=self.out_stream, flush=True)
        except (BrokenPipeError, ValueError):
            self._stop.set()

    def stop(self):
        self._stop.set()
        try:
            self.sock.close()
        except OSError:
            pass
        self.join(timeout=2)


# --------------------------------------------------------------------------
# Ligne de commande
# --------------------------------------------------------------------------

def build_arg_parser():
    parser = argparse.ArgumentParser(
        prog="fbx-run.py",
        description=(
            "Lance à distance une application QML sur un Freebox Player "
            "(Révolution) en mode développeur : sert le répertoire du "
            "manifeste en HTTP, demande au Player de la lancer (JSON-RPC "
            "debug_qml_app), puis relaie sa sortie standard/erreur ici."
        ),
        epilog=WSL2_HELP,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    parser.add_argument(
        "manifest", nargs="?", default=str(DEFAULT_MANIFEST),
        help="Chemin du manifest.json de l'application "
             "(défaut : {}).".format(DEFAULT_MANIFEST),
    )
    parser.add_argument(
        "-t", "--target", default=None, metavar="IP",
        help="Adresse IP du Freebox Player. À défaut, tentative de "
             "découverte mDNS (_fbx-devel._tcp.local., module zeroconf).",
    )
    parser.add_argument(
        "-p", "--port", type=int, default=8234, metavar="PORT",
        help="Port TCP local du serveur HTTP servant les fichiers de "
             "l'application (défaut : 8234).",
    )
    parser.add_argument(
        "-b", "--bind", default=None, metavar="IP",
        help="Adresse IP locale à annoncer au Player dans manifest_url "
             "(défaut : détectée automatiquement via getsockname() en "
             "ouvrant une connexion vers le Player).",
    )
    parser.add_argument(
        "-e", "--entry", default="main", metavar="NOM",
        help="Point d'entrée à lancer, tel que déclaré dans entryPoints "
             "du manifeste (défaut : main).",
    )
    parser.add_argument(
        "--wait", action="store_true",
        help="Demande au Player d'attendre l'attache d'un débogueur avant "
             "de démarrer l'application (wait=true dans la requête).",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true",
        help="Journalise chaque requête HTTP reçue du Player sur le "
             "serveur de fichiers local (utile pour voir quels fichiers "
             "il charge).",
    )
    parser.add_argument(
        "--timeout", type=float, default=10.0, metavar="SECONDES",
        help="Délai maximal pour la requête JSON-RPC vers le Player "
             "(défaut : 10).",
    )
    parser.add_argument(
        "--no-dev-log", action="store_true",
        help="Ne pas activer le journal de debug de l'application "
             "(qml/js/DevLog.js). Par défaut ce script sert ce fichier avec "
             "son drapeau ENABLED basculé sur true, ce qui fait apparaître "
             "les traces [RDF] ; avec cette option l'application se comporte "
             "exactement comme le paquet public.",
    )
    parser.add_argument(
        "--player-port", type=int, default=80, metavar="PORT",
        help="Port HTTP du Player pour /pub/devel et pour la détection de "
             "l'adresse locale (80 sur un vrai Player ; à modifier "
             "uniquement pour les tests avec un faux Player).",
    )

    return parser


# --------------------------------------------------------------------------
# Orchestration
# --------------------------------------------------------------------------

def main(argv=None):
    args = build_arg_parser().parse_args(argv)

    try:
        _manifest, app_dir, _entry_file = load_and_validate_manifest(
            args.manifest, args.entry
        )
    except FbxRunError as e:
        print("Erreur : {}".format(e), file=sys.stderr)
        return 2

    target = args.target
    if not target:
        print(
            "Aucune cible indiquée (-t) : recherche mDNS de "
            "_fbx-devel._tcp.local. ...",
            file=sys.stderr,
        )
        target = discover_via_mdns()
        if not target:
            print(
                "Erreur : aucun Freebox Player trouvé par mDNS. Indiquez "
                "son adresse IP avec -t, ou vérifiez que le module "
                "'zeroconf' est installé et que le mode développeur est "
                "activé sur le Player.",
                file=sys.stderr,
            )
            return 2
        print("Player découvert par mDNS : {}".format(target), file=sys.stderr)

    try:
        if args.bind:
            local_addr = args.bind
        else:
            local_addr = local_address_to(
                target, args.player_port, timeout=args.timeout
            )
    except FbxRunError as e:
        print("Erreur : {}".format(e), file=sys.stderr)
        return 1

    dev_log = not args.no_dev_log
    if dev_log:
        devlog_file = os.path.join(app_dir, *DEVLOG_URL_PATH.strip("/").split("/"))
        if not os.path.isfile(devlog_file):
            dev_log = False
            print("Journal de debug : qml/js/DevLog.js absent, inactif.", flush=True)
        else:
            try:
                with open(devlog_file, "rb") as fh:
                    enable_devlog_source(fh.read())
            except (OSError, FbxRunError) as e:
                print("Erreur : {}".format(e), file=sys.stderr)
                return 1
            print("Journal de debug : actif (traces [RDF] ; --no-dev-log pour "
                  "le désactiver).", flush=True)
    else:
        print("Journal de debug : désactivé (--no-dev-log).", flush=True)

    server = AppServer(local_addr, args.port, app_dir, verbose=args.verbose,
                       dev_log=dev_log)
    try:
        server.start()
    except OSError as e:
        print(
            "Erreur : impossible de démarrer le serveur HTTP local sur "
            "{}:{} : {}".format(local_addr, args.port, e),
            file=sys.stderr,
        )
        return 1

    print(
        "Serveur HTTP local démarré sur {} (répertoire {})"
        .format(server.file_url(""), app_dir),
        file=sys.stderr,
    )

    manifest_url = server.file_url("manifest.json")
    if args.player_port == 80:
        endpoint = "http://{}/pub/devel".format(target)
    else:
        endpoint = "http://{}:{}/pub/devel".format(target, args.player_port)

    print(
        "Lancement du point d'entrée '{}' sur {} (manifeste {})..."
        .format(args.entry, target, manifest_url),
        file=sys.stderr,
    )

    try:
        result = jsonrpc_call(
            endpoint,
            "debug_qml_app",
            {
                "manifest_url": manifest_url,
                "entry_point": args.entry,
                "wait": bool(args.wait),
            },
            timeout=args.timeout,
        )
    except FbxRunError as e:
        server.stop()
        print("Erreur : {}".format(e), file=sys.stderr)
        return 1

    qml_port = result.get("qml_port")
    stdout_port = result.get("stdout_port")
    stderr_port = result.get("stderr_port")

    print(
        "Application démarrée : qml_port={} stdout_port={} stderr_port={}"
        .format(qml_port, stdout_port, stderr_port),
        file=sys.stderr,
    )

    relays = []
    try:
        if stdout_port:
            relays.append(StreamRelay(target, stdout_port, "out", sys.stdout))
        if stderr_port:
            relays.append(StreamRelay(target, stderr_port, "err", sys.stderr))
    except OSError as e:
        for r in relays:
            r.stop()
        server.stop()
        print(
            "Erreur : impossible de se connecter aux ports de sortie du "
            "Player : {}".format(e),
            file=sys.stderr,
        )
        return 1

    for r in relays:
        r.start()

    print("Appuyez sur Ctrl-C pour arrêter.", file=sys.stderr)

    try:
        while True:
            time.sleep(0.2)
    except KeyboardInterrupt:
        pass
    finally:
        print("Arrêt en cours...", file=sys.stderr)
        for r in relays:
            r.stop()
        server.stop()
        print("Arrêt terminé.", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
