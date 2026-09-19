#!/usr/bin/env python3
"""
run_qml_tests.py - Exécute tous les tests Qt Quick Test (tests/qml/tst_*.qml)
en mode headless, via le module Python PySide6.QtQuickTest.

Usage :
    python3 tests/qml/run_qml_tests.py

Ce script est appelé par check.sh, mais peut aussi être lancé seul (il faut
alors que le venv Qt (voir tools/setup-qt-tools.sh) soit sur le PYTHONPATH,
ce qui est le cas si on utilise l'interpréteur du venv directement :

    ~/.cache/redefin-qttools/venv/bin/python3 tests/qml/run_qml_tests.py

QUICK_TEST_MAIN() découvre et exécute TOUS les fichiers tst_*.qml présents
dans le répertoire donné (ici : le répertoire de ce script), les agrège en
une seule session de test, et renvoie un code de sortie non nul si au moins
un test a échoué.

Chemins d'import QML positionnés ici (QML_IMPORT_PATH / QML2_IMPORT_PATH) :
  - le clone libfbxqml (fbx.application, fbx.ui.base... ; cf.
    tools/fetch-libfbxqml.sh),
  - tests/qml/stubs (modules absents sous Qt 6 : fbx.system,
    QtGraphicalEffects),
  - la racine du dépôt, pour que « import "qml/components" » et consorts
    soient résolus de la même façon que sur la Freebox.

Limite connue : ceci exécute les tests sous Qt 6 (PySide6), alors que la
Freebox exécute Qt 5.15 sans les modules fbx.*. Voir tests/README.md.
"""
import os
import sys

# Headless obligatoire : pas de serveur d'affichage disponible en CI/sandbox.
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
# Filet de sécurité : certains environnements sans GPU/logiciel Mesa complet
# n'arrivent pas à initialiser le backend RHI par défaut de QtQuick pour le
# rendu offscreen. Le backend logiciel évite ce genre de soucis.
os.environ.setdefault("QT_QUICK_BACKEND", "software")

TESTS_QML_DIR = os.path.dirname(os.path.abspath(__file__))
STUBS_DIR = os.path.join(TESTS_QML_DIR, "stubs")
REPO_ROOT = os.path.dirname(os.path.dirname(TESTS_QML_DIR))


def libfbxqml_dir():
    """Chemin du clone libfbxqml, ou None s'il est introuvable.

    Même ordre de résolution que check.sh : variable d'environnement, puis
    cache partagé de l'outillage, puis dépôt frère du projet.
    """
    candidates = [
        os.environ.get("REDEFIN_LIBFBXQML"),
        os.path.join(os.path.expanduser("~"), ".cache", "redefin-qttools",
                     "libfbxqml"),
        os.path.join(os.path.dirname(REPO_ROOT), "libfbxqml"),
    ]
    for path in candidates:
        if path and os.path.isdir(os.path.join(path, "fbx")):
            return os.path.abspath(path)
    return None


def setup_qml_import_path():
    """Ajoute libfbxqml, les stubs et la racine du dépôt aux chemins QML."""
    paths = []

    libfbx = libfbxqml_dir()
    if libfbx:
        paths.append(libfbx)
    else:
        sys.stderr.write(
            "Avis : libfbxqml est introuvable, les imports fbx.application et "
            "fbx.ui.base ne seront pas résolus.\n"
            "Lancez tools/fetch-libfbxqml.sh (ou définissez "
            "REDEFIN_LIBFBXQML).\n"
        )

    # Les stubs passent APRÈS libfbxqml : un module réellement fourni par la
    # bibliothèque officielle ne doit jamais être masqué par un stub.
    paths.append(STUBS_DIR)
    paths.append(REPO_ROOT)

    for var in ("QML_IMPORT_PATH", "QML2_IMPORT_PATH"):
        existing = os.environ.get(var, "")
        merged = paths + ([existing] if existing else [])
        os.environ[var] = os.pathsep.join(merged)


def main():
    setup_qml_import_path()

    try:
        from PySide6.QtQuickTest import QUICK_TEST_MAIN
    except ImportError as exc:
        sys.stderr.write(
            "Erreur : impossible d'importer PySide6.QtQuickTest ({}).\n"
            "Lancez d'abord tools/setup-qt-tools.sh, ou exécutez ce script "
            "avec l'interpréteur du venv Qt "
            "(ex: ~/.cache/redefin-qttools/venv/bin/python3).\n".format(exc)
        )
        return 1

    # "redefin-qml-tests" est juste un nom de session affiché dans les logs ;
    # le répertoire donné en 3e argument est celui où QUICK_TEST_MAIN va
    # chercher tous les fichiers tst_*.qml à exécuter (non récursif).
    return QUICK_TEST_MAIN("redefin-qml-tests", sys.argv, TESTS_QML_DIR)


if __name__ == "__main__":
    sys.exit(main())
