#!/usr/bin/env bash
#
# build.sh - Construit le paquet .fbxqml de ReDeFin (tar+gzip) à partir des
# sources présentes à la racine du dépôt, en respectant la liste blanche
# déclarée dans ReDeFin.fbxproject.
#
# IMPORTANT : la liste des fichiers embarqués ci-dessous (fonction
# build_file_list) doit être maintenue manuellement en miroir de
# ReDeFin.fbxproject. Si ce dernier change (nouveau répertoire, nouveau
# filtre...), il faut répercuter la modification ici.
#
set -euo pipefail

# --- Résolution du répertoire du script, pour fonctionner depuis n'importe où ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
ROOT="$SCRIPT_DIR"

PROG_NAME="$(basename "$0")"

usage() {
    cat <<EOF
Usage: ${PROG_NAME} [OPTIONS]

Construit le paquet ReDeFin (.fbxqml) en archivant (tar+gzip) les fichiers
sources whitelistés dans ReDeFin.fbxproject, de façon reproductible.

Options :
  -o, --output <fichier>      Chemin du paquet produit.
                               Par défaut : build/ReDeFin_<version>.fbxqml
                               (la version est lue dans manifest.json).
  -v, --verify <reference>    Après construction, compare le paquet produit
                               à une archive .fbxqml de référence (liste des
                               fichiers + sha256 de chaque fichier extrait).
                               Affiche les différences et sort en erreur (1)
                               si le contenu diffère.
  -h, --help                   Affiche cette aide et quitte.

Codes de sortie :
  0  Succès.
  1  Échec de la vérification (--verify) : contenu différent.
  2  Erreur d'usage ou de pré-vérification (fichier manquant, JSON invalide...).
EOF
}

# --- Analyse des arguments ---
OUTPUT=""
VERIFY_REF=""

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output)
            [ $# -ge 2 ] || { echo "Erreur : ${1} nécessite un argument." >&2; exit 2; }
            OUTPUT="$2"
            shift 2
            ;;
        -v|--verify)
            [ $# -ge 2 ] || { echo "Erreur : ${1} nécessite un argument." >&2; exit 2; }
            VERIFY_REF="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Erreur : option inconnue '$1'." >&2
            usage >&2
            exit 2
            ;;
    esac
done

# --- Pré-vérifications : fichiers indispensables ---
if [ ! -f "${ROOT}/main.qml" ]; then
    echo "Erreur : main.qml est introuvable à la racine (${ROOT})." >&2
    exit 2
fi

if [ ! -f "${ROOT}/manifest.json" ]; then
    echo "Erreur : manifest.json est introuvable à la racine (${ROOT})." >&2
    exit 2
fi

HAVE_PYTHON3=0
if command -v python3 >/dev/null 2>&1; then
    HAVE_PYTHON3=1
fi

# --- Validation du JSON de manifest.json (si python3 disponible) ---
if [ "${HAVE_PYTHON3}" -eq 1 ]; then
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${ROOT}/manifest.json"; then
        echo "Erreur : manifest.json n'est pas un JSON valide." >&2
        exit 2
    fi
else
    echo "Avis : python3 introuvable, validation JSON de manifest.json ignorée." >&2
fi

# --- Validation des règles métier de manifest.json (si python3 disponible) ---
# Mêmes règles que le packager FreeStore d'origine (fileformat/manifest.cc
# du plugin QtCreator Freebox, 2014) : identifier, entryPoints, uiFlavor.
if [ "${HAVE_PYTHON3}" -eq 1 ]; then
    if ! python3 - "${ROOT}/manifest.json" <<'PYEOF'
import json
import re
import sys

IDENTIFIER_RE = re.compile(r"\w+(\.\w+)+")
FILE_RE = re.compile(r"[/\w.+~-]+")
UI_FLAVOR_RE = re.compile(r"(multi|classic)", re.IGNORECASE)


def fail(msg):
    print("Erreur : " + msg, file=sys.stderr)
    sys.exit(1)


with open(sys.argv[1], encoding="utf-8") as f:
    manifest = json.load(f)

if not isinstance(manifest, dict):
    fail("le manifeste doit être un objet JSON.")

identifier = manifest.get("identifier")
if not isinstance(identifier, str) or not IDENTIFIER_RE.fullmatch(identifier):
    fail(
        "le champ 'identifier' est requis et doit être de la forme "
        "'mot.mot' (ex : com.exemple.app) ; valeur actuelle : {!r}".format(identifier)
    )

entry_points = manifest.get("entryPoints")
if not isinstance(entry_points, dict) or not entry_points:
    fail("le champ 'entryPoints' doit être un objet non vide.")

for name, ep in entry_points.items():
    if not isinstance(ep, dict):
        fail("entryPoints.{}. doit être un objet.".format(name))

    file_value = ep.get("file")
    if not isinstance(file_value, str) or not FILE_RE.fullmatch(file_value):
        fail("entryPoints.{}.file est requis et doit être un chemin valide.".format(name))

    if "uiFlavor" in ep:
        ui_flavor = ep["uiFlavor"]
        if not isinstance(ui_flavor, str) or not UI_FLAVOR_RE.fullmatch(ui_flavor):
            fail("entryPoints.{}.uiFlavor doit valoir 'multi' ou 'classic'.".format(name))

    if "default" in ep and not isinstance(ep["default"], bool):
        fail("entryPoints.{}.default doit être un booléen.".format(name))
PYEOF
    then
        exit 2
    fi
else
    echo "Avis : python3 introuvable, validation des règles de manifest.json ignorée." >&2
fi

# --- Lecture de la version depuis manifest.json ---
if [ "${HAVE_PYTHON3}" -eq 1 ]; then
    VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "${ROOT}/manifest.json")"
else
    # Repli grep/sed si python3 n'est pas disponible.
    VERSION="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "${ROOT}/manifest.json" | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
fi

if [ -z "${VERSION}" ]; then
    echo "Erreur : impossible de lire le champ 'version' de manifest.json." >&2
    exit 2
fi

if [ -z "${OUTPUT}" ]; then
    OUTPUT="build/ReDeFin_${VERSION}.fbxqml"
fi

# Rendre le chemin de sortie absolu (l'utilisateur peut lancer le script
# depuis n'importe où, mais on a déjà fait un cd vers SCRIPT_DIR).
case "${OUTPUT}" in
    /*) : ;;
    *) OUTPUT="${ROOT}/${OUTPUT}" ;;
esac

mkdir -p "$(dirname "${OUTPUT}")"

# --- Construction de la liste des fichiers (miroir de ReDeFin.fbxproject) ---
LIST_FILE="$(mktemp)"
TMP_ARCHIVE=""
EXTRACT_NEW=""
EXTRACT_REF=""

cleanup() {
    rm -f "${LIST_FILE}"
    [ -n "${TMP_ARCHIVE}" ] && rm -f "${TMP_ARCHIVE}"
    [ -n "${EXTRACT_NEW}" ] && rm -rf "${EXTRACT_NEW}"
    [ -n "${EXTRACT_REF}" ] && rm -rf "${EXTRACT_REF}"
    # Ne jamais laisser le code de sortie du script être écrasé par le
    # statut de la dernière commande du nettoyage (ex : test '[ -n ... ]'
    # qui échoue simplement parce que la variable est vide).
    return 0
}
trap cleanup EXIT

shopt -s nullglob

{
    # Fichiers QML à la racine, non récursif (point d'entrée : main.qml).
    for f in "${ROOT}"/*.qml; do
        [ -f "$f" ] && echo "${f#"${ROOT}"/}"
    done

    # Composants et pages QML.
    for f in "${ROOT}"/qml/components/*.qml; do
        [ -f "$f" ] && echo "${f#"${ROOT}"/}"
    done
    for f in "${ROOT}"/qml/pages/*.qml; do
        [ -f "$f" ] && echo "${f#"${ROOT}"/}"
    done

    # Bibliothèques JavaScript.
    for f in "${ROOT}"/qml/js/*.js; do
        [ -f "$f" ] && echo "${f#"${ROOT}"/}"
    done

    # Ressources graphiques (formats publiables uniquement).
    for ext in png jpg jpeg gif svg; do
        for f in "${ROOT}"/qml/images/*."${ext}"; do
            [ -f "$f" ] && echo "${f#"${ROOT}"/}"
        done
    done

    # Déclaration des singletons/composants QML.
    if [ -f "${ROOT}/qml/components/qmldir" ]; then
        echo "qml/components/qmldir"
    fi

    # Manifeste FreeStore.
    echo "manifest.json"

    # Le fichier de projet lui-même (inclus dans le paquet original).
    if [ -f "${ROOT}/ReDeFin.fbxproject" ]; then
        echo "ReDeFin.fbxproject"
    fi
} | LC_ALL=C sort -u > "${LIST_FILE}"

shopt -u nullglob

NB_FILES="$(wc -l < "${LIST_FILE}" | tr -d '[:space:]')"

if [ "${NB_FILES}" -eq 0 ]; then
    echo "Erreur : la liste des fichiers à empaqueter est vide." >&2
    exit 2
fi

# --- Vérification que les fichiers de entryPoints seront bien empaquetés ---
# Même contrôle que le packager FreeStore d'origine (freestorepackager.cc) :
# un fichier de entryPoints absent ou mal orthographié bloque le paquet.
if [ "${HAVE_PYTHON3}" -eq 1 ]; then
    if ! python3 - "${ROOT}/manifest.json" "${LIST_FILE}" <<'PYEOF'
import json
import sys

manifest_path, list_path = sys.argv[1], sys.argv[2]

with open(manifest_path, encoding="utf-8") as f:
    manifest = json.load(f)

with open(list_path, encoding="utf-8") as f:
    packaged = {line.strip() for line in f if line.strip()}

entry_points = manifest.get("entryPoints", {})
missing = []
for name, ep in entry_points.items():
    file_value = ep.get("file") if isinstance(ep, dict) else None
    if file_value and file_value not in packaged:
        missing.append("{} ({})".format(file_value, name))

if missing:
    print(
        "Erreur : fichier(s) de entryPoints manquant(s) ou mal orthographié(s) "
        "dans la liste des fichiers empaquetés : " + ", ".join(missing),
        file=sys.stderr,
    )
    sys.exit(1)
PYEOF
    then
        exit 2
    fi
else
    echo "Avis : python3 introuvable, vérification des fichiers entryPoints ignorée." >&2
fi

# --- Garde-fou : le journal de debug doit être inactif dans tout paquet ---
# qml/js/DevLog.js n'est activé qu'à la volée par tools/fbx-run.py. Un paquet
# ne doit jamais embarquer le drapeau à true.
DEVLOG_FILE="${ROOT}/qml/js/DevLog.js"
if [ -f "${DEVLOG_FILE}" ]; then
    DEVLOG_OFF_COUNT="$(grep -c '^var ENABLED = false;$' "${DEVLOG_FILE}" || true)"
    if [ "${DEVLOG_OFF_COUNT}" != "1" ] || grep -q 'var ENABLED = true;' "${DEVLOG_FILE}"; then
        echo "Erreur : qml/js/DevLog.js doit contenir exactement une ligne 'var ENABLED = false;' et aucune activation." >&2
        exit 2
    fi
fi

# --- Construction reproductible de l'archive ---
# SOURCE_DATE_EPOCH : on respecte la variable d'environnement si elle est
# définie (reproductibilité stricte), sinon on prend l'heure courante (et
# surtout pas 0, qui donnerait une date en 1970 pour tous les fichiers).
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}"

TMP_ARCHIVE="$(mktemp)"

tar --format=ustar \
    -C "${ROOT}" \
    --owner=0 --group=0 --numeric-owner \
    --sort=name \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    -T "${LIST_FILE}" \
    -cf - \
    | gzip -n -9 > "${TMP_ARCHIVE}"

# mktemp crée le fichier en 600 ; on aligne les droits sur un fichier
# normal avant de le déplacer vers sa destination finale.
chmod 644 "${TMP_ARCHIVE}"
mv "${TMP_ARCHIVE}" "${OUTPUT}"
TMP_ARCHIVE=""

# --- Résumé ---
ARCHIVE_COUNT="$(tar -tzf "${OUTPUT}" | wc -l | tr -d '[:space:]')"
SIZE="$(du -h "${OUTPUT}" | cut -f1)"

echo "Paquet construit avec succès :"
echo "  Fichiers embarqués      : ${NB_FILES}"
echo "  Fichier de sortie       : ${OUTPUT}"
echo "  Taille                  : ${SIZE}"
echo "  Entrées dans l'archive  : ${ARCHIVE_COUNT}"

# --- Vérification optionnelle par rapport à une archive de référence ---
if [ -n "${VERIFY_REF}" ]; then
    if [ ! -f "${VERIFY_REF}" ]; then
        echo "Erreur : archive de référence introuvable : ${VERIFY_REF}" >&2
        exit 2
    fi

    case "${VERIFY_REF}" in
        /*) : ;;
        *) VERIFY_REF="${ROOT}/${VERIFY_REF}" ;;
    esac

    EXTRACT_NEW="$(mktemp -d)"
    EXTRACT_REF="$(mktemp -d)"

    tar -xzf "${OUTPUT}" -C "${EXTRACT_NEW}"
    # L'archive de référence peut émettre un avertissement inoffensif
    # ("lone zero block") sans que l'extraction échoue : on ne fait donc
    # pas échouer le script sur son seul code de retour.
    tar -xzf "${VERIFY_REF}" -C "${EXTRACT_REF}" || true

    LIST_NEW="$(mktemp)"
    LIST_REF="$(mktemp)"
    (cd "${EXTRACT_NEW}" && find . -type f | sed 's|^\./||') | LC_ALL=C sort > "${LIST_NEW}"
    (cd "${EXTRACT_REF}" && find . -type f | sed 's|^\./||') | LC_ALL=C sort > "${LIST_REF}"

    MISMATCH=0

    if ! diff -u "${LIST_REF}" "${LIST_NEW}" > "${LIST_NEW}.difflist"; then
        echo "Différence de liste de fichiers entre '${OUTPUT}' et '${VERIFY_REF}' :" >&2
        cat "${LIST_NEW}.difflist" >&2
        MISMATCH=1
    fi
    rm -f "${LIST_NEW}.difflist"

    # Comparaison des sha256 pour les fichiers communs aux deux listes.
    while IFS= read -r rel; do
        if [ -f "${EXTRACT_REF}/${rel}" ] && [ -f "${EXTRACT_NEW}/${rel}" ]; then
            SUM_REF="$(sha256sum "${EXTRACT_REF}/${rel}" | cut -d' ' -f1)"
            SUM_NEW="$(sha256sum "${EXTRACT_NEW}/${rel}" | cut -d' ' -f1)"
            if [ "${SUM_REF}" != "${SUM_NEW}" ]; then
                echo "Contenu différent pour '${rel}' (sha256 ${SUM_REF} != ${SUM_NEW})." >&2
                MISMATCH=1
            fi
        fi
    done < "${LIST_REF}"

    rm -f "${LIST_NEW}" "${LIST_REF}"

    if [ "${MISMATCH}" -ne 0 ]; then
        echo "Échec de la vérification : '${OUTPUT}' diffère de '${VERIFY_REF}'." >&2
        exit 1
    fi

    echo "Vérification OK : '${OUTPUT}' et '${VERIFY_REF}' contiennent les mêmes fichiers (mêmes sha256)."
fi

exit 0
