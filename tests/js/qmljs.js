'use strict';

/*
 * qmljs.js - Petit chargeur Node.js pour les bibliothèques JavaScript QML
 * du projet (fichiers `.pragma library` de qml/js/*.js), afin de pouvoir
 * les tester unitairement avec `node --test` sans runtime Qt.
 *
 * Ce module NE modifie PAS les fichiers sources : il lit le fichier tel
 * quel, neutralise les directives QML (`.pragma library`, `.import "X.js"
 * as Y`) qui ne sont pas du JavaScript valide pour Node, puis évalue le
 * code résultant dans un contexte `vm` dédié (un objet "global" isolé par
 * module). Les `var` et `function` déclarés au niveau racine d'un module
 * QML deviennent des propriétés globales de ce contexte : l'objet retourné
 * par loadQmlJs() EST ce contexte, donc `mod.maFonction(...)` fonctionne
 * exactement comme depuis un autre fichier QML qui ferait
 * `.import "Module.js" as Mod` puis `Mod.maFonction(...)`.
 *
 * Résolution des `.import` :
 *   Les imports sont résolus récursivement, relativement au répertoire du
 *   fichier qui les déclare (comme le ferait le moteur QML), avec un cache
 *   partagé pour tout l'arbre d'un même appel à loadQmlJs() (un module
 *   importé deux fois n'est évalué qu'une seule fois).
 *
 * Injection de stubs :
 *   Les bibliothèques QML utilisent parfois des globales fournies par le
 *   runtime QML (`Qt`, `XMLHttpRequest`, ...) qui n'existent pas sous
 *   Node. loadQmlJs(relPath, { stubs: {...} }) permet d'injecter ces
 *   globales (ou de figer `Date.now`, etc.) dans le contexte de TOUS les
 *   modules chargés pour cet appel (le module demandé + ses imports
 *   récursifs). Exemple :
 *
 *     const { loadQmlJs } = require('./qmljs');
 *     const mod = loadQmlJs('qml/js/UserStore.js', {
 *       stubs: {
 *         Qt: { md5: (s) => '...' },
 *         XMLHttpRequest: class { ... },
 *         Date: Object.assign(
 *           function (...a) { return new Date(...a); },
 *           Date,
 *           { now: () => 1700000000000 }
 *         ),
 *       },
 *     });
 *
 * Voir qmljs.test.js pour des exemples concrets.
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');

// tests/js/qmljs.js -> racine du dépôt (deux niveaux au-dessus).
const REPO_ROOT = path.resolve(__dirname, '..', '..');

const IMPORT_RE = /^[ \t]*\.import\s+"([^"]+)"\s+as\s+([A-Za-z_$][A-Za-z0-9_$]*)[ \t]*$/;
const PRAGMA_RE = /^[ \t]*\.pragma\b.*$/;

/**
 * Neutralise les lignes `.pragma ...` et `.import "..." as ...` (directives
 * QML, pas du JavaScript) en les remplaçant par des lignes vides, pour
 * conserver la numérotation des lignes en cas d'erreur.
 */
function stripQmlDirectives(source) {
    return source
        .split('\n')
        .map((line) => (PRAGMA_RE.test(line) || IMPORT_RE.test(line) ? '' : line))
        .join('\n');
}

/**
 * Extrait la liste des `.import "fichier.js" as Alias` d'un module QML.
 * Retourne un tableau de { file, alias }.
 */
function parseImports(source) {
    const imports = [];
    for (const line of source.split('\n')) {
        const m = IMPORT_RE.exec(line);
        if (m) imports.push({ file: m[1], alias: m[2] });
    }
    return imports;
}

/**
 * Globales minimales toujours présentes, indépendamment des stubs fournis
 * par l'appelant (un contexte vm est sinon totalement vide de tout ce qui
 * n'est pas déjà standard JS).
 */
function baseGlobals() {
    return {
        console,
    };
}

/**
 * Charge récursivement un module QML JS (chemin absolu) dans son propre
 * contexte vm, avec les imports résolus en alias, et le met en cache.
 */
function loadModuleAbs(absPath, stubs, cache) {
    const key = path.resolve(absPath);
    if (cache.has(key)) return cache.get(key);

    const source = fs.readFileSync(key, 'utf8');
    const imports = parseImports(source);
    const cleaned = stripQmlDirectives(source);

    const sandbox = Object.assign({}, baseGlobals(), stubs);
    const context = vm.createContext(sandbox);

    // Garde-fou anti-cycle : on enregistre le sandbox dans le cache AVANT
    // d'exécuter le code du module, pour qu'un import circulaire retrouve
    // une référence (même partiellement initialisée) plutôt que de boucler
    // indéfiniment. Les fichiers actuels de qml/js n'ont pas de cycle, mais
    // ça évite une surprise si un jour ils en ont un.
    cache.set(key, sandbox);

    const dir = path.dirname(key);
    for (const imp of imports) {
        const importAbs = path.resolve(dir, imp.file);
        sandbox[imp.alias] = loadModuleAbs(importAbs, stubs, cache);
    }

    vm.runInContext(cleaned, context, { filename: key });

    return sandbox;
}

/**
 * Charge une bibliothèque JS QML et retourne un objet exposant ses
 * fonctions/variables de niveau module (celles déclarées avec `var` ou
 * `function` au premier niveau du fichier).
 *
 * @param {string} relPathFromRepoRoot Chemin du fichier .js, relatif à la
 *        racine du dépôt (ex: "qml/js/SafeLog.js").
 * @param {object} [options]
 * @param {object} [options.stubs] Globales additionnelles à injecter dans
 *        le contexte du module ET de tous ses imports récursifs (ex: Qt,
 *        XMLHttpRequest, Date...).
 * @param {Map} [options.cache] Cache module (chemin absolu -> objet
 *        contexte) à réutiliser entre plusieurs appels. Par défaut, un
 *        nouveau cache est créé à chaque appel de loadQmlJs (les modules
 *        importés PAR ce module partagent ce cache entre eux, mais deux
 *        appels distincts à loadQmlJs sont isolés l'un de l'autre, sauf si
 *        on repasse explicitement le même cache).
 * @returns {object} Le contexte du module (propriétés = globales du
 *          fichier .js : fonctions, variables...).
 */
function loadQmlJs(relPathFromRepoRoot, options) {
    const opts = options || {};
    const stubs = opts.stubs || {};
    const cache = opts.cache || new Map();
    const absPath = path.resolve(REPO_ROOT, relPathFromRepoRoot);
    return loadModuleAbs(absPath, stubs, cache);
}

module.exports = {
    loadQmlJs,
    REPO_ROOT,
    // Exposés pour des tests avancés / debug, pas nécessaires à l'usage courant.
    _internal: { stripQmlDirectives, parseImports },
};
