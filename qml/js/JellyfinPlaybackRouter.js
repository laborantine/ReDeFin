.pragma library

// Sélectionne le backend Freebox et négocie un plan de lecture Jellyfin.
// La politique de codecs reste dans Core/Revolution/Devialet ; la session
// du lecteur appartient à PlayerSession.js, le D-Pad et le seek au helper.
// Import namespacé uniquement : Qt.include fusionnerait les backends.

.import "JellyfinPlaybackCore.js" as JFCore
.import "JellyfinPlaybackRevolution.js" as JFRevolution
.import "JellyfinPlaybackDevialet.js" as JFDevialet
.import "clientId.js" as ClientId
.import "AudioOutputPolicy.js" as AudioOutput
var _MODE_AUTO       = "auto"
var _MODE_CORE       = "core"
var _MODE_REVOLUTION = "revolution"
var _MODE_DEVIALET   = "devialet"

var _fbx = null
var _requestedMode = _MODE_AUTO
var _detectedMode = ""
var _resolvedMode = _MODE_CORE
var _lastBackendName = "core"
var _playbackRuleMode = "smart"
function _s(v) {
    return (v === undefined || v === null) ? "" : String(v)
}

function negotiationErrorCode(err) {
    var code = ""
    try {
        if (typeof err === "string") code = err
        else if (err && err.code !== undefined) code = String(err.code)
        else if (err && err.message !== undefined) code = String(err.message)
    } catch(e0) {}
    code = String(code || "network_error").toLowerCase().replace(/^error[:\s]*/i, "")
    if (code.indexOf("insecure_transport") >= 0) return "insecure_transport"
    if (code.indexOf("invalid_playback_url") >= 0) return "invalid_playback_url"
    if (code.indexOf("core_url_unavailable") >= 0) return "core_url_unavailable"
    return code || "network_error"
}

function replaceQueryParameter(url, key, value) {
    var source = String(url || "")
    var hash = ""
    var hashIndex = source.indexOf("#")
    if (hashIndex >= 0) {
        hash = source.substring(hashIndex)
        source = source.substring(0, hashIndex)
    }

    var queryIndex = source.indexOf("?")
    var base = queryIndex >= 0 ? source.substring(0, queryIndex) : source
    var parts = queryIndex >= 0 ? source.substring(queryIndex + 1).split("&") : []
    var out = []
    var wanted = String(key || "").toLowerCase()
    var found = false

    for (var i = 0; i < parts.length; ++i) {
        var part = parts[i]
        if (!part) continue
        var eq = part.indexOf("=")
        var raw = eq >= 0 ? part.substring(0, eq) : part
        var name = raw
        try { name = decodeURIComponent(raw) } catch(e0) {}
        if (String(name || "").toLowerCase() === wanted) {
            if (!found && value !== undefined && value !== null && value !== "")
                out.push(encodeURIComponent(String(key)) + "=" + encodeURIComponent(String(value)))
            found = true
        } else {
            out.push(part)
        }
    }

    if (!found && value !== undefined && value !== null && value !== "")
        out.push(encodeURIComponent(String(key)) + "=" + encodeURIComponent(String(value)))
    return base + (out.length ? "?" + out.join("&") : "") + hash
}

function normalizePlaybackRuleMode(value) {
    return JFCore.normalizePlaybackRuleMode(value)
}

function normalizeAudioOutputMode(mode) { return AudioOutput.normalizeMode(mode) }

function setPlaybackRuleMode(mode) {
    _playbackRuleMode = normalizePlaybackRuleMode(mode)
    return _playbackRuleMode
}

// Façade dédiée à PlayerOverlay : garde la résolution des préférences et du
// backend dans le routeur, sans déplacer la politique de codecs hors des backends.
function syncPlayerBackendContext(root) {
    if (!root) return { wantedMode:"", resolvedMode:currentDeviceMode() };
    var rule = normalizePlaybackRuleMode(root.playbackRuleMode);
    try { if (root.playbackRuleMode !== rule) root.playbackRuleMode = rule; } catch(e0) {}
    setPlaybackRuleMode(rule);
    var wanted = "";
    try { wanted = _s(root.playbackDeviceMode || ""); } catch(e1) {}
    if (!wanted) {
        try { if (root.settingsRef && root.settingsRef.playbackDeviceMode) wanted = _s(root.settingsRef.playbackDeviceMode); } catch(e2) {}
        try { if (!wanted && root.settingsRef && root.settingsRef.freeboxModel) wanted = _s(root.settingsRef.freeboxModel); } catch(e3) {}
        try { if (!wanted && root.settingsRef && root.settingsRef.deviceModel) wanted = _s(root.settingsRef.deviceModel); } catch(e4) {}
    }
    var resolved = "";
    try { resolved = wanted ? (setDeviceMode(wanted) || "") : (resetDeviceMode() || ""); } catch(e5) {}
    try { var byFbx = setFbx(root.fbx); if (byFbx) resolved = byFbx; } catch(e6) {}
    try { resolved = currentDeviceMode() || resolved; } catch(e7) {}
    try { root.playbackBackendMode = resolved || root.playbackBackendMode; } catch(e8) {}
    return { wantedMode:wanted || "auto", resolvedMode:resolved || "" };
}

function _normalizeMode(mode) {
    var m = _s(mode).toLowerCase().trim()

    if (!m || m === "auto" || m === "detect" || m === "default")
        return _MODE_AUTO

    if (m === "core" || m === "generic" || m === "fallback-core")
        return _MODE_CORE

    // Alias explicites acceptés par le réglage manuel du routeur.
    if (m === "rev" || m === "v6" || m === "fbx6")
        return _MODE_REVOLUTION
    if (m === "delta")
        return _MODE_DEVIALET

    var detected = _modeFromString(mode)
    return detected || _MODE_AUTO
}

function _modeFromString(value) {
    try {
        return ClientId.freeboxPlayerModeFromModel(value) || ""
    } catch (e) {
        return ""
    }
}

function _isPrimitive(v) {
    var t = typeof v
    return v === null || t === "undefined" || t === "string" || t === "number" || t === "boolean"
}

function _seenIndex(arr, obj) {
    for (var i = 0; i < arr.length; i++) {
        if (arr[i] === obj) return i
    }
    return -1
}

function _scanObjectForMode(obj, depth, seen) {
    if (!obj || depth <= 0) return ""

    if (_isPrimitive(obj))
        return _modeFromString(obj)

    seen = seen || []
    if (_seenIndex(seen, obj) >= 0) return ""
    seen.push(obj)

    // Champs probables en priorité. On évite une introspection trop large qui
    // pourrait coûter inutilement sur Freebox.
    var keys = [
        "model", "Model", "modelName", "ModelName", "deviceModel", "DeviceModel",
        "device", "Device", "deviceName", "DeviceName", "product", "Product",
        "productName", "ProductName", "hardware", "Hardware", "box", "Box",
        "boxModel", "BoxModel", "player", "Player", "name", "Name",
        "friendlyName", "FriendlyName", "platform", "Platform", "type", "Type"
    ]

    for (var i = 0; i < keys.length; i++) {
        var k = keys[i]
        try {
            if (obj[k] !== undefined && obj[k] !== null) {
                var direct = _modeFromString(obj[k])
                if (direct) return direct
            }
        } catch (e1) {}
    }

    // Petit scan secondaire limité : utile si l'API Freebox expose le modèle
    // dans un sous-objet, sans transformer le routeur en aspirateur à propriétés.
    if (depth > 1) {
        for (var p in obj) {
            try {
                if (!obj.hasOwnProperty || !obj.hasOwnProperty(p)) {
                    // Certains objets QML n'ont pas hasOwnProperty fiable.
                }
                var v = obj[p]
                if (v === undefined || v === null) continue

                if (_isPrimitive(v)) {
                    var m1 = _modeFromString(v)
                    if (m1) return m1
                } else {
                    var m2 = _scanObjectForMode(v, depth - 1, seen)
                    if (m2) return m2
                }
            } catch (e2) {}
        }
    }

    return ""
}

function _detectModeFromFbx(fbxCtx) {
    if (!fbxCtx) return ""

    var direct = _scanObjectForMode(fbxCtx, 2, [])
    if (direct) return direct

    // Quelques méthodes éventuelles, appelées prudemment.
    var methods = [
        "model", "getModel", "deviceModel", "getDeviceModel",
        "productName", "getProductName", "boxModel", "getBoxModel"
    ]

    for (var i = 0; i < methods.length; i++) {
        try {
            var fn = fbxCtx[methods[i]]
            if (typeof fn === "function") {
                var val = fn.call(fbxCtx)
                var m = _modeFromString(val)
                if (m) return m
            }
        } catch (e) {}
    }

    return ""
}

function _resolveMode() {
    if (_requestedMode === _MODE_REVOLUTION ||
        _requestedMode === _MODE_DEVIALET ||
        _requestedMode === _MODE_CORE) {
        _resolvedMode = _requestedMode
        return _resolvedMode
    }

    if (_detectedMode === _MODE_REVOLUTION || _detectedMode === _MODE_DEVIALET) {
        _resolvedMode = _detectedMode
        return _resolvedMode
    }

    // Modèle réellement inconnu : rester sur le Core neutre. Sélectionner
    // Revolution ici appliquerait une policy matérielle incorrecte à une Devialet
    // lorsque Device.model n'a pas encore été transmis par ShellPage.
    _resolvedMode = _MODE_CORE
    return _resolvedMode
}

function _backendForMode(mode) {
    mode = _normalizeMode(mode || _resolveMode())

    if (mode === _MODE_DEVIALET) {
        _lastBackendName = _MODE_DEVIALET
        return JFDevialet
    }

    if (mode === _MODE_CORE) {
        if (JFCore && typeof JFCore.setDevicePolicy === "function") JFCore.setDevicePolicy(null)
        _lastBackendName = _MODE_CORE
        return JFCore
    }

    _lastBackendName = _MODE_REVOLUTION
    return JFRevolution
}

function _backend() {
    return _backendForMode(_resolveMode())
}

function _callSetFbx(api, fbxCtx) {
    try {
        if (api && typeof api.setFbx === "function")
            api.setFbx(fbxCtx)
    } catch (e) {}
}

function _primeSelectedBackendWithFbx() {
    // Important Freebox/QML: on initialise le Core pour les fonctions neutres
    // metadata/streams/subtitles, puis uniquement le backend playback choisi.
    // Ne pas appeler Revolution + Devialet ensemble : chacun installe sa policy.
    _callSetFbx(JFCore, _fbx)

    var api = _backend()
    if (api !== JFCore)
        _callSetFbx(api, _fbx)
}

/* ================== Configuration publique ================== */

function setFbx(fbxCtx) {
    _fbx = fbxCtx || null
    // ShellPage transmet normalement un mode explicite issu de Device.model.
    // L'introspection de l'objet fbx n'est donc qu'un fallback du mode auto.
    _detectedMode = (_requestedMode === _MODE_AUTO) ? _detectModeFromFbx(_fbx) : ""
    _resolveMode()

    _primeSelectedBackendWithFbx()
    return _resolvedMode
}

function setDeviceMode(mode) {
    _requestedMode = _normalizeMode(mode)
    // Si l'utilisateur/relais repasse en auto après un mode explicite, reconstruire
    // immédiatement le fallback à partir du contexte fbx déjà disponible.
    _detectedMode = (_requestedMode === _MODE_AUTO) ? _detectModeFromFbx(_fbx) : ""
    _resolveMode()

    if (_fbx) _primeSelectedBackendWithFbx()
    return _resolvedMode
}

function resetDeviceMode() {
    _requestedMode = _MODE_AUTO
    _detectedMode = _detectModeFromFbx(_fbx)
    _resolveMode()
    if (_fbx) _primeSelectedBackendWithFbx()
    return _resolvedMode
}

function currentDeviceMode() {
    return _resolveMode()
}

/* ================== API playback exposée ================== */

function fetchStreams(serverUrl, accessToken, itemId, onSuccess, onError) {
    if (JFCore && typeof JFCore.fetchStreams === "function")
        return JFCore.fetchStreams(serverUrl, accessToken, itemId, onSuccess, onError);
    if (onError) onError("core_missing");
}

function negotiatePlayback(ctx, onSuccess, onError) {
    var api = _backend()

    // Anti-policy fantôme : le backend sélectionné réinstalle sa policy
    // juste avant la négociation, sans toucher aux backends non sélectionnés.
    if (api && api !== JFCore)
        _callSetFbx(api, _fbx)

    if (ctx) {
        try {
            ctx.playbackRouterMode = _resolvedMode
            ctx.playbackRouterBackend = _lastBackendName
            ctx.playbackRuleMode = _playbackRuleMode || "smart"
            ctx.audioOutputMode = normalizeAudioOutputMode(ctx.audioOutputMode)
        } catch (e) {}
    }

    if (api && typeof api.negotiatePlayback === "function")
        return api.negotiatePlayback(ctx, function(res){
            if (onSuccess) onSuccess(res)
        }, function(err){
            if (onError) onError(err)
        })

    if (onError) onError("backend_missing")
}


// Classification du résultat de lecture, commune à la session et aux choix de pistes.
function shouldNetworkSeek(flags, durMs) {
    if (!flags) return true;
    return !!(flags.isHls || flags.lastUsedTranscoding || flags.lastUsedDirectStream || flags.serverTimedStream ||
              flags.timeShifted || flags.lastUsedServerRemux || !(durMs > 0));
}

function keepUi(scrubActive, scrubAccumUiMs, lastUiTargetMs, uiNowMs) {
    return scrubActive && scrubAccumUiMs >= 0 ? scrubAccumUiMs : (lastUiTargetMs > 0 ? lastUiTargetMs : (uiNowMs || 0));
}

function isPureDirectPlay(flagsOrState) {
    var s = flagsOrState || {}, base = 0;
    try { base = Math.max(0, Math.floor(Number(s.baseOffsetMs || 0))); } catch(e0) {}
    return !(s.isHls || s.lastUsedTranscoding || s.lastUsedDirectStream || s.serverTimedStream || s.timeShifted ||
             s.lastUsedServerRemux || base > 0);
}

function urlKind(u) {
    u = "" + u;
    if (!u) return "none";
    if (u.indexOf(".m3u8") >= 0 || u.indexOf("/hls") >= 0) return "hls";
    if (u.indexOf("/Videos/") >= 0 && u.indexOf("/stream") >= 0 && u.indexOf("static=true") >= 0) return "http-dp-static";
    if (u.indexOf("/Videos/") >= 0 && u.indexOf("/stream") >= 0) return "http-progressive";
    return "other";
}
