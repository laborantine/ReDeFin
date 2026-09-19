// qml/js/DevLog.js
// Journal de diagnostic actif UNIQUEMENT lors d'un lancement en mode
// développeur via tools/fbx-run.py.
//
// Principe : dans le dépôt et dans tout paquet .fbxqml, ENABLED vaut false et
// log() ne fait rien. Quand l'application est lancée par tools/fbx-run.py, le
// serveur HTTP du script sert CE fichier en basculant à la volée le drapeau
// ci-dessous sur true. Aucun autre fichier n'est modifié, et
// rien n'est écrit sur disque : le build public reste muet par construction.
// build.sh refuse d'ailleurs d'empaqueter ce fichier si le drapeau n'est pas
// à false.
//
// Les traces sortent sur la console du Player, relayée par fbx-run.py sous la
// forme « [err] … qml: DevLog: [RDF] <tag> <message> » : le Player nomme le
// fichier qui appelle console.log, donc toujours DevLog. C'est le tag qui
// identifie l'origine de la trace.
//
// Règles d'usage :
//   - ne jamais journaliser de secret : passer toute URL par maskUrl() ;
//   - chaque identifiant cité dans un message doit être dans la portée, une
//     exception dans les chemins de lecture casse la lecture ;
//   - dans un chemin chaud, garder l'appel derrière « if (DevLog.ENABLED) »
//     pour ne pas payer la construction du message sur Freebox Révolution.

.pragma library

// NE PAS reformater cette ligne : tools/fbx-run.py et build.sh la cherchent
// à l'identique.
var ENABLED = false;

var PREFIX = "[RDF]";

/** Masque les jetons d'authentification présents dans une URL. */
function maskUrl(url) {
    var s = "";
    try { s = String(url === undefined || url === null ? "" : url); } catch (e) { return ""; }
    return s.replace(/(api_key|ApiKey|X-Emby-Token|X-MediaBrowser-Token|AccessToken|access_token)=[^&#\s]*/gi, "$1=***");
}

/** Écrit « [RDF] <tag> <message> » sur la console, seulement si ENABLED. */
function log(tag, message) {
    if (!ENABLED) return false;
    try {
        console.log(PREFIX + " " + String(tag) + " " + String(message === undefined ? "" : message));
    } catch (e) {
        return false;
    }
    return true;
}
