# Tests et vérifications ReDeFin

Ce dossier contient le harnais de test du dépôt. Il ne fait partie d'aucun
paquet `.fbxqml` : `build.sh` n'embarque que la liste blanche déclarée dans
`ReDeFin.fbxproject` (racine, `qml/components`, `qml/pages`, `qml/js`,
`qml/images`, `manifest.json`...), qui ne référence jamais `tests/` ni
`tools/`.

## Installation des outils

Aucun Qt système n'est requis. Un environnement virtuel Python autonome
fournit `qmllint`, le runtime `qml` et le module `QtQuickTest`, via le
paquet PyPI `PySide6-Essentials` :

```sh
./tools/setup-qt-tools.sh
```

Ceci crée (ou met à jour) un venv dans `~/.cache/redefin-qttools/venv`,
**puis** enchaîne `tools/fetch-libfbxqml.sh` (voir ci-dessous) : c'est le
point d'entrée unique de l'outillage.

Pour utiliser d'autres emplacements :

```sh
REDEFIN_QT_VENV=/chemin/vers/mon-venv ./tools/setup-qt-tools.sh
REDEFIN_QT_VENV=/chemin/vers/mon-venv ./check.sh
```

Node.js (avec `node --test` intégré, Node ≥ 18) doit être disponible dans le
`PATH` pour les étapes JavaScript.

## Modules `fbx.*` : libfbxqml et stubs

Sur la Freebox, les modules `fbx.*` sont fournis par le firmware du Player.
Hors Freebox, l'outillage les reconstitue de deux façons.

### libfbxqml (bibliothèque officielle Freebox)

`tools/fetch-libfbxqml.sh` clone <https://github.com/fbx/libfbxqml> (QML/JS
pur, aucun build nécessaire) dans :

```sh
${REDEFIN_LIBFBXQML:-~/.cache/redefin-qttools/libfbxqml}
```

Le script est idempotent : sur un clone existant il tente un
`git pull --ff-only` et ne détruit jamais un dépôt modifié localement. Il est
appelé automatiquement par `tools/setup-qt-tools.sh`, mais peut être relancé
seul (par exemple après une coupure réseau) :

```sh
./tools/fetch-libfbxqml.sh
```

Elle fournit les modules réellement utilisés par ReDeFin :

| Module | Utilisé par |
| --- | --- |
| `fbx.application` (`Application`, `Settings`) | `main.qml`, `qml/components/UpdateDialog.qml` |
| `fbx.ui.base` (`Clickable`...) | `qml/pages/LoginPage.qml`, `SearchPage.qml`, `serverpage.qml` |

Rien de ce qui est cloné n'entre dans le paquet `.fbxqml` : `build.sh`
n'embarque que la liste blanche de `ReDeFin.fbxproject`.

### Stubs locaux (`tests/qml/stubs/`)

Deux modules ne peuvent pas venir de libfbxqml et sont donc stubbés :

- **`fbx.system`** (singleton `Device`) : absent de libfbxqml, il n'existe
  que sur le Player. ReDeFin le lit dans `main.qml`
  (`Device.model`, passé à `ClientId.initFromQmlDevice()`) et dans
  `qml/pages/ShellPage.qml` (`Device.model`, `Device.firmwareVersion`).
  Le stub expose ces propriétés avec des valeurs de Freebox Révolution
  (`model: "fbx6hd"`), surchargeables depuis un test pour simuler un autre
  Player (`Device.model = "fbx7hd-delta"`).
- **`QtGraphicalEffects`** (`OpacityMask`, `DropShadow`, `FastBlur`) :
  module standard de Qt 5.15, retiré de Qt 6 (et son remplaçant
  `Qt5Compat.GraphicalEffects` n'est pas dans PySide6-Essentials). Les stubs
  sont des enveloppes **neutres** : elles acceptent les mêmes propriétés mais
  ne rendent rien. Aucun test ne doit conclure quoi que ce soit du rendu de
  ces effets.

`check.sh` passe `-I <libfbxqml> -I tests/qml/stubs` à `qmllint`, et
`tests/qml/run_qml_tests.py` positionne `QML_IMPORT_PATH` / `QML2_IMPORT_PATH`
avec les mêmes chemins (plus la racine du dépôt). Dans les deux cas les stubs
passent **après** libfbxqml : un module réellement fourni par la bibliothèque
officielle n'est jamais masqué par un stub.

Si libfbxqml est introuvable, ni le lint ni les tests n'échouent : un message
invite à lancer `tools/fetch-libfbxqml.sh`, et les imports `fbx.*` non
résolus retombent en avertissements `[import]`. Le résumé de `check.sh`
affiche le nombre d'avertissements `[import]` restants, ce qui permet de
repérer d'un coup d'œil une régression de câblage des chemins d'import.

`tests/qml/tst_fbxmodules.qml` vérifie précisément ce câblage : il instancie
un `Clickable` de `fbx.ui.base`, compile `fbx.application.Application` et lit
le singleton `Device` du stub.

## Lancer toutes les vérifications

Depuis la racine du dépôt :

```sh
./check.sh
```

Enchaîne : lint syntaxique de tous les `.qml`, vérification syntaxique de
tous les `.js` de `qml/js`, tests unitaires Node (`tests/js`), tests
Qt Quick Test headless (`tests/qml`) et tests Python de l'outillage
(`tests/py`, bibliothèque standard : ils couvrent `tools/fbx-run.py`, voir
`tools/README.md`). Voir `./check.sh -h` pour les options (`--no-lint`,
`--no-tests`).

## Écrire un test Node (bibliothèques JS de qml/js)

Les bibliothèques `qml/js/*.js` utilisent la syntaxe QML (`.pragma
library`, `.import "Fichier.js" as Alias`), qui n'est pas du JavaScript
valide pour Node. Le chargeur `tests/js/qmljs.js` permet de les importer
tel quel, sans les modifier :

```js
const { loadQmlJs } = require('./qmljs');

const SafeLog = loadQmlJs('qml/js/SafeLog.js');
SafeLog.safeErrorCode('timeout'); // "timeout"
```

- `loadQmlJs(relPathFromRepoRoot, options?)` résout et charge récursivement
  les `.import` du module (relatifs au fichier qui les déclare), avec un
  cache pour ne charger chaque fichier qu'une fois.
- `options.stubs` permet d'injecter des globales absentes de Node mais
  fournies par le runtime QML (`Qt`, `XMLHttpRequest`, une horloge figée via
  un `Date` de substitution...) :

  ```js
  const mod = loadQmlJs('qml/js/UserStore.js', {
      stubs: {
          Qt: { md5: (s) => '...' },
          XMLHttpRequest: class { /* ... */ },
      },
  });
  ```

Voir `tests/js/qmljs.test.js` pour deux exemples complets : un module sans
`.import` (`SafeLog.js`) et un module avec résolution récursive
(`JellyfinPlaybackRouter.js`).

Pour lancer uniquement les tests Node :

```sh
node --test tests/js/*.test.js
```

(`node --test tests/js/` avec un simple chemin de répertoire n'est pas
fiable selon la version de Node installée : `check.sh` liste donc
explicitement les fichiers `*.test.js`.)

## Écrire un test QML (Qt Quick Test)

Un test QML est un fichier `tests/qml/tst_*.qml` basé sur `TestCase` de
`QtTest` :

```qml
import QtQuick 2.15
import QtTest 1.2

TestCase {
    name: "MonTest"
    function test_quelquechose() {
        compare(1 + 1, 2)
    }
}
```

`tests/qml/run_qml_tests.py` découvre et exécute tous les
`tests/qml/tst_*.qml` en une seule session, en headless
(`QT_QPA_PLATFORM=offscreen`, `QT_QUICK_BACKEND=software`), via
`PySide6.QtQuickTest.QUICK_TEST_MAIN`, et renvoie un code de sortie non nul
si un test échoue. Il positionne aussi les chemins d'import QML (libfbxqml,
`tests/qml/stubs`, racine du dépôt), ce qui permet d'importer des pages du
projet qui dépendent de `fbx.*` ou de `QtGraphicalEffects`.

Exemples fournis :

- `tst_smoke.qml` : composant réel sans dépendance firmware
  (`qml/components/CircleDotsLoader.qml`) ;
- `tst_fbxmodules.qml` : résolution des modules `fbx.*` (libfbxqml + stub
  `fbx.system`) ;
- `tst_profiletile.qml` : câblage QML de la tuile de profil, en instanciant
  la vraie `qml/pages/LoginPage.qml` (voir ci-dessous).

### Instancier une page réelle sans réseau

`tst_profiletile.qml` montre le motif à réutiliser pour tester une page
complète du projet :

- `serverUrl` reste vide, donc `_doLoadData()` sort immédiatement et aucune
  requête `XMLHttpRequest` n'est émise ;
- `settingsRef` reste nul, donc `_syncStoreSecurityPolicy()` renvoie `false`
  et `hydrateFromStore()` n'est pas appelée au chargement ;
- le modèle est injecté après coup (`localUsers` puis `_recomputeModel()`),
  après une attente courte laissant passer `Component.onCompleted` et le
  debounce de `loadData()` ;
- les gestes sont joués avec `keyPress` / `wait` / `keyRelease` sur l'élément
  qui a le focus, et observés via les propriétés publiques de la page
  (`overlayOpen`, `_removeArmedUid`, `usersModel`), les `id` internes d'un
  composant n'étant pas accessibles de l'extérieur.

Ce test dure une dizaine de secondes : il rejoue de vrais appuis longs
(2,4 s), ce qui est le seul moyen de couvrir les `Timer` de la tuile.

Pour lancer uniquement les tests QML :

```sh
~/.cache/redefin-qttools/venv/bin/python3 tests/qml/run_qml_tests.py
```

## Limite connue

Le lint (`qmllint`) et les tests Qt Quick Test tournent sous **Qt 6**
(via PySide6), alors que la Freebox exécute le code sous **Qt 5.15**, sans
les modules `fbx.*` du firmware (`fbx.hardware`, etc., non disponibles hors
de la Freebox). Conséquences :

- `qmllint` émet un grand nombre d'avertissements non bloquants sur les
  fichiers de `main.qml`/`qml/**` : imports `fbx.*` introuvables
  (`[import]`), accès non qualifiés (`[unqualified]`), propriétés
  manquantes sur les objets fournis par le firmware (`[missing-property]`),
  etc. C'est attendu : `check.sh` ne fait échouer le lint que sur les
  véritables erreurs de syntaxe (`[syntax]`), qui sont indépendantes de la
  version de Qt.
- Les modules `fbx.*` sont reconstitués hors Freebox (libfbxqml + stubs,
  voir plus haut), ce qui rend testables des composants qui en dépendent.
  Mais **libfbxqml date de 2014 et cible Qt 5** : elle est exécutée ici sous
  Qt 6, et le firmware du Player peut avoir divergé depuis. Un comportement
  observé dans un test `fbx.*` ne prouve donc rien sur la Freebox réelle.
- `fbx.system` est entièrement stubbé (aucune source officielle publique) :
  seules les propriétés lues par ReDeFin existent, avec des valeurs choisies.
- `QtMultimedia` reste non résolu (absent de PySide6-Essentials) :
  `qml/pages/playeroverlay.qml` conserve donc quelques avertissements
  `[import]`, et `MediaPlayer`/`VideoOutput` ne sont pas instanciables ici.
- Les effets graphiques (`OpacityMask`, `DropShadow`, `FastBlur`) sont des
  stubs neutres et le rendu utilise le backend logiciel : aucun test ne doit
  porter sur l'apparence, seulement sur la logique et le câblage QML.
- Ce harnais ne remplace donc pas un test sur Freebox réelle avant
  publication : il attrape les erreurs de syntaxe et les régressions de
  logique pure, pas les problèmes spécifiques au runtime Qt 5.15/fbx.*.
