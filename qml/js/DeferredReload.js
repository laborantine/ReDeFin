/* DeferredReload.js — modèle pur des réglages du lecteur ReDeFin.
 *
 * Ce module décrit UNIQUEMENT les sélections Audio / Sous-titres / Qualité
 * vidéo sous forme de valeurs comparables. Il ne connaît ni Qt, ni QtMultimedia,
 * ni PlayerOverlay : aucune dépendance, aucun état global mutable, donc
 * testable directement avec Node (tests/js/deferredreload.test.js).
 *
 * Convention d'égalité : deux sélections sont identiques lorsqu'elles
 * désignent la MÊME LIGNE que le panneau de réglages affiche comme appliquée.
 * C'est exactement ce que voit l'utilisateur (la coche), et donc le bon
 * critère pour décider qu'une resélection ne doit rien déclencher.
 */
.pragma library

var KIND_AUDIO = "audio";
var KIND_SUBTITLE = "subtitle";
var KIND_QUALITY = "quality";

/* Valeurs négatives réservées aux modes de lecture du panneau Qualité vidéo.
 * Elles reprennent strictement PlayerSettingsOverlay.qml. */
var QUALITY_AUTO = -3;
var QUALITY_REMUX = -2;
var QUALITY_DIRECTPLAY = -1;
var QUALITY_NONE = 0;

function _int(value, fallback) {
    // Number(null) et Number("") valent 0 : on refuse explicitement les
    // valeurs vides avant toute conversion.
    if (value === undefined || value === null || value === "") return fallback;
    var n = Number(value);
    if (!isFinite(n) || isNaN(n)) return fallback;
    return Math.floor(n);
}

/* ===== Descripteurs de sélection ===== */

function audioSelection(streamIdx, uiIndex, manualDirectPlay) {
    return {
        kind: KIND_AUDIO,
        stream: _int(streamIdx, -1),
        uiIndex: _int(uiIndex, -1),
        manualDirectPlay: manualDirectPlay === true
    };
}

function subtitleSelection(streamIdx, uiIndex) {
    return {
        kind: KIND_SUBTITLE,
        stream: _int(streamIdx, -1),
        uiIndex: _int(uiIndex, -1)
    };
}

function qualitySelection(value) {
    return {
        kind: KIND_QUALITY,
        value: _int(value, QUALITY_NONE)
    };
}

/*
 * Égalité de sélection.
 *
 * Audio et sous-titres sont comparés sur l'index visuel du menu : c'est la
 * ligne cochée, donc la seule notion de « déjà actif » que l'utilisateur
 * perçoit. L'index de flux n'est pas utilisé : en DirectPlay pur, Jellyfin ne
 * renvoie aucun AudioStreamIndex et effectiveAudioStream vaut -1 alors que le
 * menu coche bien la piste réellement lue.
 *
 * La qualité est comparée sur la valeur du panneau (Automatique, DirectPlay,
 * Remux ou plafond de transcodage).
 */
function sameSelection(a, b) {
    if (!a || !b) return false;
    if (a.kind !== b.kind) return false;
    if (a.kind === KIND_QUALITY)
        return a.value === b.value && a.value !== QUALITY_NONE;
    return a.uiIndex >= 0 && a.uiIndex === b.uiIndex;
}

function describeSelection(selection) {
    if (!selection) return "";
    if (selection.kind === KIND_QUALITY)
        return KIND_QUALITY + ":" + selection.value;
    return selection.kind + ":ui=" + selection.uiIndex + ",stream=" + selection.stream;
}

/* ===== Réducteur : différer un rechargement choisi en pause ===== */
/*
 * Décision produit (identique au client officiel Jellyfin Android TV) : un
 * réglage modifié PENDANT UNE PAUSE ne relance pas la lecture. Le choix est
 * mémorisé, l'UI le reflète immédiatement, et le rechargement réel n'a lieu
 * qu'à la reprise (ou au prochain seek réseau, qui renégocie de toute façon).
 *
 * L'état est un simple sac de trois attentes :
 *   { audio: <selection|null>, subtitle: <selection|null>, quality: <selection|null> }
 *
 * Événements acceptés :
 *   { type: "pick", kind, value, active, paused }
 *   { type: "resume" }
 *   { type: "seek" }
 *   { type: "reset" }
 *   { type: "negotiationDone" } / { type: "negotiationFailed" }
 *
 * reduce() ne mute jamais l'état reçu : il renvoie { state, actions }, où
 * actions contient des ordres explicites pour la couche QML :
 *   { type: "noop", kind }
 *   { type: "applyNow", kind, value }
 *   { type: "defer", kind, value }
 *   { type: "cancelPending", kind }
 *   { type: "replayOnResume", reason, picks: [ { kind, value } ] }
 */

var ORDER = [KIND_AUDIO, KIND_SUBTITLE, KIND_QUALITY];

function createState() {
    return { audio: null, subtitle: null, quality: null };
}

function _copyState(state) {
    var s = state || createState();
    return {
        audio: s.audio || null,
        subtitle: s.subtitle || null,
        quality: s.quality || null
    };
}

function _isKind(kind) {
    return kind === KIND_AUDIO || kind === KIND_SUBTITLE || kind === KIND_QUALITY;
}

function pendingFor(state, kind) {
    if (!state || !_isKind(kind)) return null;
    return state[kind] || null;
}

function pendingPicks(state) {
    var out = [];
    if (!state) return out;
    for (var i = 0; i < ORDER.length; ++i) {
        var kind = ORDER[i];
        if (state[kind]) out.push({ kind: kind, value: state[kind] });
    }
    return out;
}

function pendingCount(state) {
    return pendingPicks(state).length;
}

function _result(state, actions) {
    return { state: state, actions: actions };
}

function _clearAll(state, actions) {
    var next = createState();
    var picks = pendingPicks(state);
    for (var i = 0; i < picks.length; ++i)
        actions.push({ type: "cancelPending", kind: picks[i].kind });
    if (!picks.length) actions.push({ type: "noop", kind: "" });
    return next;
}

function _reducePick(state, event) {
    var actions = [];
    var kind = event.value ? event.value.kind : event.kind;
    if (!_isKind(kind)) {
        actions.push({ type: "noop", kind: "" });
        return _result(_copyState(state), actions);
    }

    var next = _copyState(state);
    var pending = next[kind];
    var value = event.value;
    var active = event.active || null;
    var isActive = sameSelection(value, active);

    if (event.paused !== true) {
        // En lecture, le comportement historique est conservé : application
        // immédiate. Une attente résiduelle est simplement annulée.
        if (pending) {
            next[kind] = null;
            actions.push({ type: "cancelPending", kind: kind });
        }
        if (isActive && !pending) actions.push({ type: "noop", kind: kind });
        else actions.push({ type: "applyNow", kind: kind, value: value });
        return _result(next, actions);
    }

    if (isActive) {
        // Retour au réglage réellement actif : l'attente disparaît, il ne
        // restera rien à renégocier à la reprise.
        if (pending) {
            next[kind] = null;
            actions.push({ type: "cancelPending", kind: kind });
        } else {
            actions.push({ type: "noop", kind: kind });
        }
        return _result(next, actions);
    }

    if (pending && sameSelection(value, pending)) {
        actions.push({ type: "noop", kind: kind });
        return _result(next, actions);
    }

    next[kind] = value;
    actions.push({ type: "defer", kind: kind, value: value });
    return _result(next, actions);
}

function reduce(state, event) {
    var actions = [];
    if (!event || !event.type) {
        actions.push({ type: "noop", kind: "" });
        return _result(_copyState(state), actions);
    }

    if (event.type === "pick") return _reducePick(state, event);

    if (event.type === "resume" || event.type === "seek") {
        var picks = pendingPicks(state);
        if (!picks.length) {
            actions.push({ type: "noop", kind: "" });
            return _result(_copyState(state), actions);
        }
        actions.push({
            type: "replayOnResume",
            reason: event.type,
            picks: picks
        });
        return _result(createState(), actions);
    }

    if (event.type === "cancel") {
        var cur = _copyState(state);
        if (_isKind(event.kind) && cur[event.kind]) {
            cur[event.kind] = null;
            actions.push({ type: "cancelPending", kind: event.kind });
        } else {
            actions.push({ type: "noop", kind: event.kind || "" });
        }
        return _result(cur, actions);
    }

    if (event.type === "reset" || event.type === "negotiationDone" ||
            event.type === "negotiationFailed")
        return _result(_clearAll(state, actions), actions);

    actions.push({ type: "noop", kind: "" });
    return _result(_copyState(state), actions);
}

function firstActionType(actions) {
    if (!actions || !actions.length) return "noop";
    for (var i = 0; i < actions.length; ++i)
        if (actions[i] && actions[i].type !== "cancelPending") return actions[i].type;
    return actions[actions.length - 1].type;
}
