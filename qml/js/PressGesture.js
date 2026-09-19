// qml/js/PressGesture.js
// Décision pure du geste « appui / relâchement de OK » utilisé par les
// tuiles de profil (LoginPage) et les lignes de serveurs mémorisés
// (ServerOverlay).
//
// Ce module ne contient AUCUN état global mutable et ne dépend d'aucune API
// Qt / fbx.* : il est donc testable en Node (tests/js/pressgesture.test.js)
// et rejouable à l'identique quel que soit l'appelant.
//
// Règle du geste :
//   - un appui long confirmé (anneau de progression arrivé au bout, ou appui
//     maintenu au-delà du garde-fou) demande la SUPPRESSION ;
//   - tout autre relâchement SÉLECTIONNE. Il n'existe plus de « zone morte »
//     entre le tap court et l'appui long : un appui de 300 ms, ou un appui
//     long abandonné avant la confirmation, sélectionne normalement.

.pragma library

// Valeurs de repli, alignées sur les réglages des appelants.
var DEFAULT_COMMIT_MS = 1000;
var DEFAULT_FALLBACK_LONG_MS = 2000;

function _num(v, def) {
    var n = Number(v);
    if (typeof n !== "number" || isNaN(n) || !isFinite(n)) return def;
    return n;
}

function _posMs(v, def) {
    var n = _num(v, def);
    return n > 0 ? n : def;
}

/**
 * Décide de l'action à exécuter au relâchement de la touche OK.
 *
 * @param {object} opts
 *   - active         {bool}   faux si aucun appui n'était en cours (relâchement
 *                             fantôme) : aucune action. Absent => appui en cours.
 *   - dur            {number} durée totale de l'appui, en ms.
 *   - armed          {bool}   vrai si la phase « appui long » est amorcée.
 *   - armedDur       {number} durée écoulée depuis l'amorçage, en ms.
 *   - commitMs       {number} durée d'amorçage nécessaire pour supprimer.
 *   - fallbackLongMs {number} garde-fou : appui total au-delà => suppression.
 * @returns {string} "select" | "remove" | "none"
 */
function decideRelease(opts) {
    var o = opts || {};

    if (o.active === false) return "none";

    var dur = _num(o.dur, 0);
    var commitMs = _posMs(o.commitMs, DEFAULT_COMMIT_MS);
    var fallbackLongMs = _posMs(o.fallbackLongMs, DEFAULT_FALLBACK_LONG_MS);

    // Garde-fou : la touche est restée enfoncée très longtemps, même si le
    // timer d'amorçage n'a pas pu se déclencher (interface figée, etc.).
    if (dur >= fallbackLongMs) return "remove";

    // Appui long amorcé et maintenu jusqu'au bout de l'anneau de progression.
    if (o.armed === true && _num(o.armedDur, 0) >= commitMs) return "remove";

    // Tout le reste sélectionne : tap court, appui moyen, appui long relâché
    // avant la confirmation.
    return "select";
}

/**
 * Petite machine à états d'appui/relâchement, sans dépendance Qt.
 *
 * Elle porte le verrou de touche (keyHeld) et l'état d'appui (pressActive),
 * afin qu'aucun chemin d'erreur ne puisse laisser le verrou posé : un appui
 * refusé par l'appelant ne pose jamais le verrou, et un relâchement le lève
 * toujours, même s'il n'y avait aucun appui en cours.
 *
 * Chaque appelant crée SA machine (createMachine()) : rien n'est partagé
 * entre les instances, malgré le .pragma library.
 *
 * Cycle nominal :
 *   keyDown(now, canStart) -> "begin"  (démarrer le timer d'amorçage)
 *   armedNow(now)          -> true     (le timer d'amorçage a tiré)
 *   keyUp(now, cfg)        -> "select" | "remove" | "none"
 */
function createMachine() {
    return {
        // Vrai entre un keyDown accepté et le keyUp correspondant.
        keyHeld: false,
        // Vrai tant qu'un appui est réellement en cours de mesure.
        pressActive: false,
        // Vrai une fois la phase « appui long » amorcée.
        armed: false,
        downAtMs: 0,
        armedAtMs: 0,

        /**
         * Touche OK enfoncée.
         * @param {number} now horodatage en ms.
         * @param {bool} canStart faux si l'appelant refuse l'appui (latch
         *        post-logout, bouclier OK, identifiant manquant...).
         * @returns {string} "begin" si un appui démarre, "ignore" sinon.
         */
        keyDown: function (now, canStart) {
            // Répétition automatique ou évènement en double : un seul appui.
            if (this.keyHeld) return "ignore";
            // Appui refusé : on ne pose surtout PAS le verrou, sans quoi la
            // tuile ignorerait définitivement la touche OK.
            if (canStart === false) return "ignore";

            this.keyHeld = true;
            this.pressActive = true;
            this.armed = false;
            this.downAtMs = _num(now, 0);
            this.armedAtMs = 0;
            return "begin";
        },

        /**
         * Le timer d'amorçage a tiré : bascule en phase « appui long ».
         * @returns {bool} vrai si l'amorçage s'applique (appui toujours en cours).
         */
        armedNow: function (now) {
            if (!this.pressActive) return false;
            this.armed = true;
            this.armedAtMs = _num(now, 0);
            return true;
        },

        /**
         * Touche OK relâchée. Lève TOUJOURS le verrou de touche, puis rend
         * l'action à exécuter et remet l'appui à zéro.
         * @param {number} now horodatage en ms.
         * @param {object} cfg { commitMs, fallbackLongMs }.
         * @returns {string} "select" | "remove" | "none"
         */
        keyUp: function (now, cfg) {
            var wasActive = this.pressActive;
            var t = _num(now, 0);
            var c = cfg || {};

            this.keyHeld = false;

            var action = decideRelease({
                active: wasActive,
                dur: t - this.downAtMs,
                armed: this.armed,
                armedDur: this.armed ? (t - this.armedAtMs) : 0,
                commitMs: c.commitMs,
                fallbackLongMs: c.fallbackLongMs
            });

            this.reset();
            return action;
        },

        /** Abandonne l'appui en cours. Ne touche pas au verrou de touche :
         *  celui-ci n'est levé que par le relâchement réel de la touche. */
        reset: function () {
            this.pressActive = false;
            this.armed = false;
            this.downAtMs = 0;
            this.armedAtMs = 0;
        }
    };
}

/**
 * Confirmation d'une suppression par appui long, sur le modèle du bouton
 * « Oublier cet appareil » (un premier OK arme, un second exécute).
 *
 * Fonction pure : l'appelant lui passe l'identifiant actuellement armé,
 * l'identifiant visé et l'action rendue par decideRelease(), et reçoit le
 * nouvel identifiant armé ainsi que l'ordre d'exécuter ou non.
 *
 * Règles :
 *   - "remove" sur un identifiant déjà armé  => exécution, désarmement ;
 *   - "remove" sur un autre identifiant      => armement, rien d'exécuté ;
 *   - "select" (tap ou appui long abandonné) => désarmement, rien d'exécuté :
 *     la sélection normale reprend la main, elle appartient à l'appelant ;
 *   - toute autre action ("none")            => état inchangé.
 *
 * @param {string} currentArmedUid identifiant actuellement armé ("" si aucun).
 * @param {string} uid identifiant visé par le geste.
 * @param {string} action "remove" | "select" | "none".
 * @returns {object} { armedUid: string, execute: bool }
 */
function nextRemoveState(currentArmedUid, uid, action) {
    var armed = (currentArmedUid === undefined || currentArmedUid === null)
        ? "" : String(currentArmedUid);
    var target = (uid === undefined || uid === null) ? "" : String(uid);

    if (action === "remove") {
        // Sans identifiant, il n'y a rien à armer ni à supprimer.
        if (!target) return { armedUid: "", execute: false };
        if (armed && armed === target) return { armedUid: "", execute: true };
        return { armedUid: target, execute: false };
    }

    // Une sélection désarme toujours : un appui court pendant l'armement
    // doit rendre la tuile à son usage normal, sans rien supprimer.
    if (action === "select") return { armedUid: "", execute: false };

    return { armedUid: armed, execute: false };
}
