#!/usr/bin/env bash
#
# setup-qt-tools.sh - Prépare un environnement Python virtuel autonome
# fournissant les outils Qt/QML nécessaires à check.sh (qmllint, qml, et le
# module QtQuickTest), sans avoir besoin d'installer Qt système ni de sudo.
#
# Le venv est basé sur le paquet PyPI "PySide6-Essentials", qui embarque une
# distribution Qt 6 complète (binaires qmllint/qml + modules QML QtTest).
#
# Ce script est le point d'entrée UNIQUE de l'outillage : il enchaîne aussi
# tools/fetch-libfbxqml.sh, qui récupère la bibliothèque QML officielle
# Freebox (modules fbx.application, fbx.ui.base...).
#
# Idempotent : si le venv existe déjà et fonctionne, le script ne fait rien
# (sauf s'assurer que PySide6-Essentials est bien installé).
#
# Variables d'environnement :
#   REDEFIN_QT_VENV     Chemin du venv à créer/réutiliser.
#                        Par défaut : ~/.cache/redefin-qttools/venv
#   REDEFIN_LIBFBXQML   Chemin du clone libfbxqml (voir fetch-libfbxqml.sh).
#                        Par défaut : ~/.cache/redefin-qttools/libfbxqml
#
set -euo pipefail

PROG_NAME="$(basename "$0")"

usage() {
    cat <<EOF
Usage: ${PROG_NAME} [OPTIONS]

Crée (si nécessaire) un environnement virtuel Python contenant
PySide6-Essentials, qui fournit :
  - pyside6-qmllint : vérificateur syntaxique/lint pour les fichiers QML,
  - pyside6-qml      : runtime QML headless,
  - le module Python PySide6.QtQuickTest (exécution de tests Qt Quick Test),
  - le module QML QtTest (TestCase, SignalSpy...).

Puis appelle tools/fetch-libfbxqml.sh pour récupérer la bibliothèque QML
officielle Freebox (fbx.application, fbx.ui.base...), utilisée comme chemin
d'import par check.sh et tests/qml.

Le script est idempotent : le réexécuter sur un venv déjà valide ne fait
rien de destructeur, il complète seulement l'installation si besoin.

Variables d'environnement :
  REDEFIN_QT_VENV     Chemin du venv à créer/réutiliser.
                       Par défaut : ${DEFAULT_VENV}
  REDEFIN_LIBFBXQML   Chemin du clone libfbxqml.
                       Par défaut : ${HOME}/.cache/redefin-qttools/libfbxqml

Options :
  -h, --help   Affiche cette aide et quitte.
EOF
}

DEFAULT_VENV="${HOME}/.cache/redefin-qttools/venv"

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Erreur : option inconnue '$arg'." >&2
            usage >&2
            exit 2
            ;;
    esac
done

VENV_DIR="${REDEFIN_QT_VENV:-${DEFAULT_VENV}}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "Erreur : python3 est introuvable, impossible de créer le venv." >&2
    exit 1
fi

echo "== Environnement Qt/QML pour ReDeFin =="
echo "Venv cible : ${VENV_DIR}"

if [ ! -x "${VENV_DIR}/bin/python3" ]; then
    echo "-- Création du venv..."
    mkdir -p "$(dirname "${VENV_DIR}")"
    python3 -m venv "${VENV_DIR}"
else
    echo "-- Venv déjà présent, réutilisation."
fi

echo "-- Installation/mise à jour de PySide6-Essentials..."
"${VENV_DIR}/bin/python3" -m pip install --upgrade pip --quiet
"${VENV_DIR}/bin/python3" -m pip install --upgrade PySide6-Essentials --quiet

if [ ! -x "${VENV_DIR}/bin/pyside6-qmllint" ]; then
    echo "Erreur : pyside6-qmllint est introuvable après installation." >&2
    exit 1
fi

echo "-- OK : ${VENV_DIR}/bin/pyside6-qmllint disponible."
"${VENV_DIR}/bin/pyside6-qmllint" --version || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo
echo "-- Récupération de la bibliothèque QML Freebox (libfbxqml)..."
# Non bloquant : sans réseau, check.sh reste utilisable (lint purement
# syntaxique, imports fbx.* non résolus).
if ! "${SCRIPT_DIR}/fetch-libfbxqml.sh"; then
    echo "Avis : libfbxqml n'a pas pu être récupérée." >&2
    echo "check.sh et les tests QML resteront utilisables, mais les imports" >&2
    echo "fbx.* ne seront pas résolus. Relancez tools/fetch-libfbxqml.sh" >&2
    echo "quand le réseau sera disponible." >&2
fi

echo
echo "Terminé. Pour utiliser ce venv explicitement :"
echo "  export REDEFIN_QT_VENV=\"${VENV_DIR}\""
echo "  ./check.sh"
