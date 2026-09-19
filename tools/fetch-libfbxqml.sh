#!/usr/bin/env bash
#
# fetch-libfbxqml.sh - Récupère (ou met à jour) la bibliothèque QML officielle
# Freebox « libfbxqml » utilisée par ReDeFin (fbx.application, fbx.ui.base...).
#
# La bibliothèque est du QML/JS pur : aucun build n'est nécessaire, il suffit
# de pointer QML_IMPORT_PATH / l'option -I de qmllint sur le répertoire cloné.
#
# Elle sert UNIQUEMENT à l'outillage de vérification (check.sh, tests/qml) :
# sur la Freebox, ces modules sont fournis par le firmware. Rien de ce qui est
# cloné ici n'entre dans le paquet .fbxqml produit par build.sh.
#
# Idempotent : si le clone existe déjà, le script tente une mise à jour en
# avance rapide ; il ne détruit jamais un dépôt modifié localement.
#
# Variable d'environnement :
#   REDEFIN_LIBFBXQML   Chemin du clone à créer/réutiliser.
#                        Par défaut : ~/.cache/redefin-qttools/libfbxqml
#
set -euo pipefail

PROG_NAME="$(basename "$0")"
DEFAULT_DIR="${HOME}/.cache/redefin-qttools/libfbxqml"
REPO_URL="https://github.com/fbx/libfbxqml.git"

usage() {
    cat <<USAGE
Usage: ${PROG_NAME} [OPTIONS]

Clone (ou met à jour) ${REPO_URL}
dans le répertoire de cache utilisé par check.sh et tests/qml.

Variable d'environnement :
  REDEFIN_LIBFBXQML   Chemin du clone à créer/réutiliser.
                       Par défaut : ${DEFAULT_DIR}

Options :
  -h, --help   Affiche cette aide et quitte.
USAGE
}

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

TARGET_DIR="${REDEFIN_LIBFBXQML:-${DEFAULT_DIR}}"

if ! command -v git >/dev/null 2>&1; then
    echo "Erreur : git est introuvable, impossible de récupérer libfbxqml." >&2
    exit 1
fi

echo "== libfbxqml (bibliothèque QML Freebox) =="
echo "Cible : ${TARGET_DIR}"

if [ -d "${TARGET_DIR}/.git" ]; then
    echo "-- Clone déjà présent, tentative de mise à jour (git pull --ff-only)..."
    if git -C "${TARGET_DIR}" pull --ff-only --quiet; then
        echo "-- Mise à jour OK."
    else
        echo "-- Avis : mise à jour impossible (pas de réseau, ou historique local"
        echo "   divergent). Le clone existant est conservé tel quel."
    fi
elif [ -e "${TARGET_DIR}" ]; then
    # Répertoire existant mais pas un clone git : on ne touche à rien.
    if [ -d "${TARGET_DIR}/fbx" ]; then
        echo "-- Répertoire existant non-git contenant fbx/ : conservé tel quel."
    else
        echo "Erreur : ${TARGET_DIR} existe mais n'est ni un clone git ni une" >&2
        echo "copie de libfbxqml. Supprimez-le ou changez REDEFIN_LIBFBXQML." >&2
        exit 1
    fi
else
    echo "-- Clonage (profondeur 1) de ${REPO_URL}..."
    mkdir -p "$(dirname "${TARGET_DIR}")"
    git clone --depth 1 --quiet "${REPO_URL}" "${TARGET_DIR}"
    echo "-- Clonage OK."
fi

if [ ! -d "${TARGET_DIR}/fbx" ]; then
    echo "Erreur : ${TARGET_DIR}/fbx est introuvable après récupération." >&2
    exit 1
fi

echo "-- OK : modules disponibles sous ${TARGET_DIR}/fbx"
echo
echo "Utilisation (check.sh et tests/qml le font automatiquement) :"
echo "  export REDEFIN_LIBFBXQML=\"${TARGET_DIR}\""
echo "  ./check.sh"
