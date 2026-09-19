#!/usr/bin/env bash
#
# check.sh - Vérifie le dépôt ReDeFin sans lancer de build ni toucher aux
# sources applicatives : lint syntaxique QML, vérification syntaxique des
# bibliothèques JS QML, tests unitaires Node et tests Qt Quick Test.
#
# Ce script ne fait QUE de la vérification. Il ne modifie jamais main.qml,
# qml/** ni aucun fichier applicatif.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
ROOT="$SCRIPT_DIR"
PROG_NAME="$(basename "$0")"

usage() {
    cat <<EOF
Usage: ${PROG_NAME} [OPTIONS]

Enchaîne les vérifications suivantes sur le dépôt ReDeFin :
  1. Lint syntaxique de tous les fichiers .qml (main.qml, qml/**, tests/**)
     avec qmllint (pyside6-qmllint). Seules les erreurs de syntaxe
     ([syntax]) font échouer cette étape : les avertissements de style
     (unqualified, import, missing-property...) attendus sur du code
     Qt 5.15 analysé avec un outil Qt 6 sont volontairement ignorés.
  2. Vérification syntaxique de toutes les bibliothèques JS QML
     (qml/js/*.js) avec « node --check », sur une copie temporaire où les
     directives QML (.pragma, .import) sont neutralisées.
  3. Tests unitaires Node : node --test sur tests/js/.
  4. Tests Qt Quick Test headless : tous les tests/qml/tst_*.qml, via
     tests/qml/run_qml_tests.py (PySide6.QtQuickTest, QT_QPA_PLATFORM=offscreen).

Options :
  --no-lint     Ne pas exécuter le lint qmllint (étape 1).
  --no-tests    Ne pas exécuter les tests (étapes 3 et 4). L'étape 2
                (vérification syntaxique JS) reste exécutée.
  -h, --help    Affiche cette aide et quitte.

Résolution de qmllint (dans cet ordre) :
  1. \$REDEFIN_QT_VENV/bin/pyside6-qmllint
  2. ~/.cache/redefin-qttools/venv/bin/pyside6-qmllint
  3. qmllint (dans le PATH système)

Résolution de libfbxqml (bibliothèque QML officielle Freebox, fournit les
modules fbx.application / fbx.ui.base ; dans cet ordre) :
  1. \$REDEFIN_LIBFBXQML
  2. ~/.cache/redefin-qttools/libfbxqml
  3. ../libfbxqml (dépôt frère)

Le module fbx.system, absent de libfbxqml (il n'existe que sur le Player),
est fourni par les stubs de tests/qml/stubs, également passés à qmllint.

Si un outil est introuvable, lancez d'abord :
  ./tools/setup-qt-tools.sh
(qui enchaîne lui-même tools/fetch-libfbxqml.sh)

Codes de sortie :
  0  Toutes les vérifications activées sont passées.
  1  Au moins une vérification a échoué.
  2  Erreur d'usage, ou outil requis introuvable (sans --no-lint / --no-tests).
EOF
}

RUN_LINT=1
RUN_TESTS=1

while [ $# -gt 0 ]; do
    case "$1" in
        --no-lint)
            RUN_LINT=0
            shift
            ;;
        --no-tests)
            RUN_TESTS=0
            shift
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

# --- Nettoyage centralisé des répertoires temporaires ---
TMP_JS_DIR=""
cleanup() {
    [ -n "${TMP_JS_DIR}" ] && rm -rf "${TMP_JS_DIR}"
    return 0
}
trap cleanup EXIT

STEP_OK=()
STEP_LABEL=()

record_step() {
    STEP_LABEL+=("$1")
    STEP_OK+=("$2")
}

echo "== ReDeFin : vérifications (check.sh) =="
echo "Racine : ${ROOT}"
echo

OVERALL_STATUS=0

# =============================================================================
# 1. Lint syntaxique QML (qmllint)
# =============================================================================
if [ "${RUN_LINT}" -eq 1 ]; then
    echo "-- [1/5] Lint syntaxique QML (qmllint) --"

    QMLLINT_BIN=""
    if [ -n "${REDEFIN_QT_VENV:-}" ] && [ -x "${REDEFIN_QT_VENV}/bin/pyside6-qmllint" ]; then
        QMLLINT_BIN="${REDEFIN_QT_VENV}/bin/pyside6-qmllint"
    elif [ -x "${HOME}/.cache/redefin-qttools/venv/bin/pyside6-qmllint" ]; then
        QMLLINT_BIN="${HOME}/.cache/redefin-qttools/venv/bin/pyside6-qmllint"
    elif command -v qmllint >/dev/null 2>&1; then
        QMLLINT_BIN="$(command -v qmllint)"
    fi

    if [ -z "${QMLLINT_BIN}" ]; then
        echo "Erreur : qmllint introuvable." >&2
        echo "Lancez d'abord : ./tools/setup-qt-tools.sh" >&2
        echo "(ou relancez avec --no-lint pour sauter cette étape)" >&2
        exit 2
    fi

    echo "qmllint utilisé : ${QMLLINT_BIN}"

    # --- Chemins d'import QML ---
    # libfbxqml (fbx.application, fbx.ui.base...) : clone géré par
    # tools/fetch-libfbxqml.sh. Sans lui, le lint reste utilisable, mais tous
    # les imports fbx.* remontent en avertissements [import].
    LIBFBXQML_DIR=""
    for candidate in \
        "${REDEFIN_LIBFBXQML:-}" \
        "${HOME}/.cache/redefin-qttools/libfbxqml" \
        "${ROOT}/../libfbxqml"
    do
        if [ -n "${candidate}" ] && [ -d "${candidate}/fbx" ]; then
            LIBFBXQML_DIR="${candidate}"
            break
        fi
    done

    IMPORT_ARGS=()
    if [ -n "${LIBFBXQML_DIR}" ]; then
        echo "libfbxqml utilisée : ${LIBFBXQML_DIR}"
        IMPORT_ARGS+=(-I "${LIBFBXQML_DIR}")
    else
        echo "Avis : libfbxqml introuvable, les imports fbx.application et"
        echo "       fbx.ui.base ne seront pas résolus (lint non bloqué)."
        echo "       Pour les résoudre : ./tools/fetch-libfbxqml.sh"
    fi

    # Stubs locaux des modules que Qt 6 / libfbxqml ne fournissent pas
    # (fbx.system, QtGraphicalEffects). Passés APRÈS libfbxqml : un module
    # réellement fourni par la bibliothèque officielle n'est jamais masqué.
    if [ -d "${ROOT}/tests/qml/stubs" ]; then
        IMPORT_ARGS+=(-I "${ROOT}/tests/qml/stubs")
    fi

    # Tous les .qml du dépôt (racine, qml/**, tests/**), hors build/ et hors
    # répertoires cachés (.git, worktrees d'outils...).
    mapfile -t QML_FILES < <(find "${ROOT}" \
        -name ".*" -prune -o \
        -path "${ROOT}/build" -prune -o \
        -name "*.qml" -print | LC_ALL=C sort)

    if [ "${#QML_FILES[@]}" -eq 0 ]; then
        echo "Avis : aucun fichier .qml trouvé." >&2
    fi

    export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"

    LINT_OUT="$(mktemp)"
    LINT_HAD_ERROR=0
    # Avertissements [import] restants : indicateur de la qualité de
    # résolution des modules (fbx.*, QtGraphicalEffects, QtMultimedia...).
    # Purement informatif, ne fait jamais échouer le lint.
    LINT_IMPORT_WARNINGS=0

    # On lance qmllint fichier par fichier : ça permet d'identifier
    # précisément quel(s) fichier(s) contiennent une erreur de syntaxe, et
    # ça évite qu'une erreur sur un fichier masque le résultat des autres.
    #
    # Fiabilité du diagnostic : le code retour du wrapper pyside6-qmllint
    # est fiable dans cette version (255 sur erreur de syntaxe, 0 sinon),
    # mais on double-vérifie en cherchant le tag [syntax] dans la sortie,
    # qui est la méthode la plus robuste (indépendante du code retour exact
    # d'un wrapper qui pourrait un jour l'avaler). Seul [syntax] fait
    # échouer : les avertissements de style (unqualified, import,
    # missing-property...), très nombreux sur ce code Qt 5.15 analysé par
    # un outil Qt 6, sont ignorés.
    for f in "${QML_FILES[@]}"; do
        # Le code de retour du wrapper n'est pas déterminant ici : on analyse
        # dans tous les cas la sortie, seule source fiable de diagnostic.
        "${QMLLINT_BIN}" "${IMPORT_ARGS[@]}" "$f" >"${LINT_OUT}" 2>&1 || true

        if grep -q '\[syntax\]' "${LINT_OUT}"; then
            echo "ERREUR DE SYNTAXE : ${f#"${ROOT}"/}"
            grep '\[syntax\]' "${LINT_OUT}" | sed 's/^/    /'
            LINT_HAD_ERROR=1
        fi

        FILE_IMPORT_WARNINGS="$(grep -c '\[import\]' "${LINT_OUT}" || true)"
        LINT_IMPORT_WARNINGS=$((LINT_IMPORT_WARNINGS + FILE_IMPORT_WARNINGS))
    done

    rm -f "${LINT_OUT}"

    if [ "${LINT_HAD_ERROR}" -eq 1 ]; then
        echo "Résultat : ÉCHEC (erreur(s) de syntaxe détectée(s))."
        record_step "Lint QML (qmllint, [syntax] uniquement)" 1
        OVERALL_STATUS=1
    else
        echo "Résultat : OK (${#QML_FILES[@]} fichier(s) analysé(s), aucune erreur de syntaxe)."
        record_step "Lint QML (qmllint, [syntax] uniquement)" 0
    fi
    echo "Avertissements [import] restants : ${LINT_IMPORT_WARNINGS} (informatif)."
    echo
else
    echo "-- [1/5] Lint syntaxique QML : ignoré (--no-lint) --"
    echo
fi

# =============================================================================
# 2. Vérification syntaxique des bibliothèques JS QML (node --check)
# =============================================================================
echo "-- [2/5] Vérification syntaxique JS (node --check) --"

if ! command -v node >/dev/null 2>&1; then
    echo "Erreur : node est introuvable dans le PATH." >&2
    exit 2
fi

TMP_JS_DIR="$(mktemp -d)"
JS_HAD_ERROR=0
JS_COUNT=0

mapfile -t JS_FILES < <(find "${ROOT}/qml/js" -name "*.js" | LC_ALL=C sort)

for f in "${JS_FILES[@]}"; do
    JS_COUNT=$((JS_COUNT + 1))
    rel="${f#"${ROOT}"/}"
    dest="${TMP_JS_DIR}/${rel}"
    mkdir -p "$(dirname "${dest}")"
    # Neutralise les directives QML (.pragma library / .import "X.js" as Y)
    # qui ne sont pas du JavaScript valide pour node --check, en les
    # remplaçant par des lignes vides (préserve la numérotation des lignes
    # pour que les messages d'erreur restent exploitables).
    sed -E \
        -e 's/^[ \t]*\.pragma\b.*$//' \
        -e 's/^[ \t]*\.import\b.*$//' \
        "$f" > "${dest}"

    NODE_CHECK_ERR="${TMP_JS_DIR}/.node-check-err"
    if ! node --check "${dest}" 2>"${NODE_CHECK_ERR}"; then
        echo "ERREUR DE SYNTAXE JS : ${rel}"
        sed "s|${dest}|${rel}|g" "${NODE_CHECK_ERR}" | sed 's/^/    /'
        JS_HAD_ERROR=1
    fi
    rm -f "${NODE_CHECK_ERR}"
done

if [ "${JS_HAD_ERROR}" -eq 1 ]; then
    echo "Résultat : ÉCHEC."
    record_step "Syntaxe JS (node --check)" 1
    OVERALL_STATUS=1
else
    echo "Résultat : OK (${JS_COUNT} fichier(s) vérifié(s))."
    record_step "Syntaxe JS (node --check)" 0
fi
echo

# =============================================================================
# 3. Tests unitaires Node (tests/js)
# =============================================================================
if [ "${RUN_TESTS}" -eq 1 ]; then
    echo "-- [3/5] Tests unitaires Node (tests/js) --"

    mapfile -t NODE_TEST_FILES < <(find "${ROOT}/tests/js" -name "*.test.js" | LC_ALL=C sort)

    if [ "${#NODE_TEST_FILES[@]}" -eq 0 ]; then
        echo "Avis : aucun fichier tests/js/*.test.js trouvé, étape ignorée."
        record_step "Tests Node (tests/js)" 0
    else
        # NB : « node --test tests/js/ » (répertoire) n'est pas fiable dans
        # toutes les versions de node (certaines tentent de charger le
        # répertoire comme un module unique via require() et échouent avec
        # MODULE_NOT_FOUND au lieu de découvrir les fichiers *.test.js).
        # On liste donc explicitement les fichiers de test, ce qui est
        # équivalent et fonctionne de façon fiable partout.
        if node --test "${NODE_TEST_FILES[@]}"; then
            record_step "Tests Node (tests/js)" 0
        else
            record_step "Tests Node (tests/js)" 1
            OVERALL_STATUS=1
        fi
    fi
    echo
else
    echo "-- [3/5] Tests unitaires Node : ignorés (--no-tests) --"
    echo
fi

# =============================================================================
# 4. Tests Qt Quick Test headless (tests/qml)
# =============================================================================
if [ "${RUN_TESTS}" -eq 1 ]; then
    echo "-- [4/5] Tests Qt Quick Test (tests/qml) --"

    QML_TEST_FILES_COUNT="$(find "${ROOT}/tests/qml" -name "tst_*.qml" | wc -l | tr -d '[:space:]')"

    if [ "${QML_TEST_FILES_COUNT}" -eq 0 ]; then
        echo "Avis : aucun fichier tests/qml/tst_*.qml trouvé, étape ignorée."
        record_step "Tests Qt Quick Test (tests/qml)" 0
    else
        PYTHON_BIN=""
        if [ -n "${REDEFIN_QT_VENV:-}" ] && [ -x "${REDEFIN_QT_VENV}/bin/python3" ]; then
            PYTHON_BIN="${REDEFIN_QT_VENV}/bin/python3"
        elif [ -x "${HOME}/.cache/redefin-qttools/venv/bin/python3" ]; then
            PYTHON_BIN="${HOME}/.cache/redefin-qttools/venv/bin/python3"
        elif python3 -c "import PySide6.QtQuickTest" >/dev/null 2>&1; then
            PYTHON_BIN="$(command -v python3)"
        fi

        if [ -z "${PYTHON_BIN}" ]; then
            echo "Erreur : aucun interpréteur Python avec PySide6.QtQuickTest n'a été trouvé." >&2
            echo "Lancez d'abord : ./tools/setup-qt-tools.sh" >&2
            echo "(ou relancez avec --no-tests pour sauter cette étape)" >&2
            exit 2
        fi

        echo "Python utilisé : ${PYTHON_BIN}"
        export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"

        if "${PYTHON_BIN}" "${ROOT}/tests/qml/run_qml_tests.py"; then
            record_step "Tests Qt Quick Test (tests/qml)" 0
        else
            record_step "Tests Qt Quick Test (tests/qml)" 1
            OVERALL_STATUS=1
        fi
    fi
    echo
else
    echo "-- [4/5] Tests Qt Quick Test : ignorés (--no-tests) --"
    echo
fi

# =============================================================================
# 5. Tests Python de l'outillage (tests/py : tools/fbx-run.py)
# =============================================================================
if [ "${RUN_TESTS}" -eq 1 ]; then
    echo "-- [5/5] Tests Python de l'outillage (tests/py) --"

    PY_TEST_FILES_COUNT="$(find "${ROOT}/tests/py" -name "test_*.py" 2>/dev/null | wc -l | tr -d '[:space:]')"

    if [ "${PY_TEST_FILES_COUNT}" -eq 0 ]; then
        echo "Avis : aucun fichier tests/py/test_*.py trouvé, étape ignorée."
        record_step "Tests Python (tests/py)" 0
    elif ! command -v python3 >/dev/null 2>&1; then
        echo "Avis : python3 introuvable, étape ignorée."
        record_step "Tests Python (tests/py)" 0
    else
        # Bibliothèque standard uniquement : l'interpréteur système suffit.
        if python3 -m unittest discover -s "${ROOT}/tests/py"; then
            record_step "Tests Python (tests/py)" 0
        else
            record_step "Tests Python (tests/py)" 1
            OVERALL_STATUS=1
        fi
    fi
    echo
else
    echo "-- [5/5] Tests Python de l'outillage : ignorés (--no-tests) --"
    echo
fi

# =============================================================================
# Résumé
# =============================================================================
echo "== Résumé =="
if [ "${RUN_LINT}" -eq 1 ]; then
    echo "  Avertissements [import] qmllint restants : ${LINT_IMPORT_WARNINGS}"
fi
for i in "${!STEP_LABEL[@]}"; do
    if [ "${STEP_OK[$i]}" -eq 0 ]; then
        printf '  [OK]    %s\n' "${STEP_LABEL[$i]}"
    else
        printf '  [ÉCHEC] %s\n' "${STEP_LABEL[$i]}"
    fi
done

if [ "${OVERALL_STATUS}" -eq 0 ]; then
    echo
    echo "Toutes les vérifications activées sont passées."
else
    echo
    echo "Au moins une vérification a échoué." >&2
fi

exit "${OVERALL_STATUS}"
