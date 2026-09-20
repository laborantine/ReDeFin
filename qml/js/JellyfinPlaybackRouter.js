.pragma library

/*
 * JellyfinPlaybackRouter.js — routeur playback ReDeFin
 *
 * Objectif : sélectionner la policy matérielle et porter l'orchestration
 * playback device-neutral consommée par PlayerOverlay :
 *   - Freebox Revolution  -> JellyfinPlaybackRevolution.js
 *   - Freebox Devialet    -> JellyfinPlaybackDevialet.js
 *   - fallback inconnu    -> Core neutre, sans policy matérielle forcée
 *
 * Important : on utilise des imports JS namespacés, pas Qt.include().
 * Qt.include() fusionnerait les wrappers dans le même scope et les fonctions
 * negotiatePlayback/fetchStreams/etc. se marcheraient dessus.
 *
 * Dans playeroverlay.qml :
 *   import "../js/JellyfinPlaybackRouter.js" as JF
 *
 * API runtime : backend/policy, négociation, démarrage/pré-roll, qualité,
 * positions persistables et reporting Jellyfin. Le D-Pad, les sous-titres
 * locaux et la machine de seek QtMultimedia restent dans playerOverlayHelper.js.
 */

.import "JellyfinPlaybackCore.js" as JFCore
.import "JellyfinPlaybackRevolution.js" as JFRevolution
.import "JellyfinPlaybackDevialet.js" as JFDevialet
.import "clientId.js" as ClientId
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

function _normalizePlaybackRuleMode(value) {
    return _s(value).toLowerCase().trim() === "directplay" ? "directplay" : "smart"
}

function setPlaybackRuleMode(mode) {
    _playbackRuleMode = _normalizePlaybackRuleMode(mode)
    return _playbackRuleMode
}

// Façade dédiée à PlayerOverlay : garde la résolution des préférences et du
// backend dans le routeur, sans déplacer la politique de codecs hors des backends.
function normalizePlaybackRuleMode(value) {
    return _normalizePlaybackRuleMode(value);
}
function syncPlayerBackendContext(root) {
    if (!root) return { wantedMode:"", resolvedMode:currentDeviceMode() };
    var rule = _normalizePlaybackRuleMode(root.playbackRuleMode);
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

/* ================== PlayerOverlay: helpers runtime sans UI ================== */

function normalizePlayerPlaybackSpeed(rate) {
    var value = Number(rate);
    if (!(value > 0)) value = 1.0;
    value = Math.round(value * 4.0) / 4.0;
    return value < 0.25 ? 0.25 : (value > 2.0 ? 2.0 : value);
}

function mediaPlayerPlaybackRate(mediaPlayer) {
    try {
        var value = Number(mediaPlayer.playbackRate);
        return isFinite(value) && !isNaN(value) && value > 0 ? value : 1.0;
    } catch (e) {
        return 1.0;
    }
}

function syncPlayerPlaybackSpeed(root, mediaPlayer, retryTimer, resetBudget) {
    if (!root || !mediaPlayer || root._tearingDownPlayer) return false;
    var wanted = normalizePlayerPlaybackSpeed(root.playbackSpeed);
    if (Math.abs(root.playbackSpeed - wanted) > 0.001) root.playbackSpeed = wanted;
    if (resetBudget === true) root._playbackRateSyncAttempts = 0;

    var current = mediaPlayerPlaybackRate(mediaPlayer);
    if (Math.abs(current - wanted) <= 0.001) {
        retryTimer.stop();
        root._playbackRateSyncAttempts = 0;
        return true;
    }

    try { mediaPlayer.playbackRate = wanted; } catch (e0) {}
    current = mediaPlayerPlaybackRate(mediaPlayer);
    if (Math.abs(current - wanted) <= 0.001) {
        retryTimer.stop();
        root._playbackRateSyncAttempts = 0;
        return true;
    }

    if (root._playbackRateSyncAttempts < root.playbackRateSyncMaxAttempts) {
        root._playbackRateSyncAttempts++;
        retryTimer.restart();
    } else {
        retryTimer.stop();
    }
    return false;
}


/* ================== PlayerOverlay: démarrage principal ================== */

function audioCodecForStream(root, streamIndex) {
    var map = root.audioStreamIndexMap || [];
    var codecs = root.audioCodecMap || [];
    for (var i = 0; i < map.length; i++) {
        if (map[i] === streamIndex) return String(codecs[i] || "").toLowerCase();
    }
    return "";
}
function isDtsAudioCodec(codec) {
    var c = String(codec || "").toLowerCase();
    return c === "dts" || c === "dca" || c === "dts,dca" || c === "a_dts";
}
function isTrueHdAudioCodec(codec) {
    var c = String(codec || "").toLowerCase();
    return c === "truehd" || c === "mlp" || c === "mlp_fba" || c === "a_truehd" ||
           c === "dolby_truehd" || c === "true-hd" || c === "true_hd";
}
function fullTranscodeAudioNeedsAc3(codec) {
    return isDtsAudioCodec(codec) || isTrueHdAudioCodec(codec);
}
function preferredAutomaticAudioStream(root) {
    if (root.bestFrenchAudioStreamIndex >= 0) return root.bestFrenchAudioStreamIndex;
    if (root.firstAudioStreamIndex >= 0) return root.firstAudioStreamIndex;
    return -1;
}
function _streamsReadyForCurrent(root) {
    if (!root || !root.itemId) return false;
    var key = (root.serverUrl || "") + "|" + (root.itemId || "");
    return root._streamsReadyKey === key;
}
function shouldForceInitialServerRemux(root) {
    if (!root || _normalizePlaybackRuleMode(root.playbackRuleMode) === "directplay") return false;
    if (root.manualDirectPlayMode) return false;
    if (!_streamsReadyForCurrent(root)) return true;
    // Les entrées externes du menu restent dormantes et ne déclenchent jamais
    // de remux. Pour les pistes internes, deux risques distincts sont traités :
    // 1) piste Default/Forced non sûre ;
    // 2) aucune priorité Matroska, mais première piste interne susceptible d'être
    //    activée implicitement par QtMultimedia 5.15.
    //
    // L'ancien SRT « FR Forced » unique et le PGS français « Forced » apparié
    // à une piste française complète sont exclus de ce risque par le Core.
    return root.isDvdSource === true ||
           root.hasInternalDvdSubtitle === true ||
           root.requiresInterlacedTsTranscode === true ||
           root.preferredFrenchAudioNeedsServerSelection === true ||
           root.preferredFrenchForcedSubtitleNeedsServerSelection === true ||
           root.hasPriorityInternalSubtitleRisk === true ||
           root.hasImplicitFirstInternalSubtitleRisk === true;
}
function fetchResumeMs(root, bridge, cb) {
    if (!root || !bridge || typeof bridge.fetchUserItem !== "function" ||
            !root.serverUrl || !root.accessToken || !root.userId || !root.itemId) {
        if (cb) cb(0, false);
        return null;
    }
    return bridge.fetchUserItem(root.serverUrl, root.accessToken, root.userId, root.itemId,
        function(item) {
            var ticks = item && item.UserData && typeof item.UserData.PlaybackPositionTicks === "number"
                    ? item.UserData.PlaybackPositionTicks : 0;
            if (cb) cb(ticks > 0 ? Math.floor(ticks / 10000) : 0, true);
        },
        function() { if (cb) cb(0, false); }
    );
}
function startFreshDirectPlayPlayback(root, start) {
    start = Math.max(0, Math.floor(Number(start || 0)));
    root._resumeWantedAfterNegotiation = true;
    // Ce chemin n'existe que pour la reconstruction complete
    // Remux/Transcodage -> DirectPlay demandee depuis Qualite. Sur intelce,
    // certains fichiers gardent des seek() synchrones tres lents meme avec
    // une nouvelle instance MediaPlayer. Le QML coalescera alors les repeats.
    root.coalescedDirectPlaySeekMode = true;
    root.manualDirectPlayMode = true;
    root.manualRemuxMode = false;
    root.manualQualityBitrate = 0;
    root.selectedAudioStream = -1;
    root.selectedSubtitleStream = -1;
    root.effectiveAudioStream = -1;
    root.effectiveSubtitleStream = -1;
    root._autoLocalizeSubStream = -1;
    root.disableLocalSubsOverlay();
    root.negotiatePlayback(0, false, false, false, false, {
        forceRetry: true,
        forceServerSeek: false,
        forceServerRemux: false,
        forceHlsOnDpSeekFallback: false,
        forceDirectPlayInPlaybackInfo: true,
        forceDirectStreamInPlaybackInfo: false,
        forceSubtitleEncode: false,
        preferImageSubtitleRemux: false,
        forceFullRemuxForImageSubtitles: false,
        manualDirectPlayOverride: true,
        manualRemuxOverride: false,
        preferFrenchAudio: false,
        disableAutoFrenchAudio: true,
        disableAutoVoFrenchFullSubtitle: true,
        disableDefaultSubtitleRemux: true,
        disableDefaultFrenchAudioOrderRemux: true,
        disableImageSubtitleRiskRemux: true,
        disableHevcMain10MkvRemux: true,
        forceDvdSubFileTranscode: false,
        forceInterlacedTsTranscode: false,
        forceInitialLocalSeekMs: start
    });
}
function startResolvedMainPlayback(root, start, remux, exactStart) {
    start = Math.max(0, Math.floor(Number(start || 0)));
    remux = remux === true;
    root._resumeWantedAfterNegotiation = true;
    // Un demarrage normal/native DirectPlay ne doit jamais etre ralenti par
    // le coalescer destine au pipeline recree apres un flux serveur.
    root.coalescedDirectPlaySeekMode = false;
    if (!remux && root.strictFrenchForcedDefaultTextSubtitleStream >= 0) {
        root.disableLocalSubsOverlay();
        root.selectedAudioStream = -1;
        root.selectedSubtitleStream = -1;
        root.effectiveSubtitleStream = root.strictFrenchForcedDefaultTextSubtitleStream;
        root._autoLocalizeSubStream = -1;
        var strictSubUi = root.listIndexForStream(root.strictFrenchForcedDefaultTextSubtitleStream);
        if (strictSubUi >= 0) root.subtitleIndex = strictSubUi;
    } else if (!remux && root.legacyFrenchForcedTextSubtitleStream >= 0) {
        root.disableLocalSubsOverlay();
        root.selectedAudioStream = -1;
        root.selectedSubtitleStream = -1;
        root.effectiveSubtitleStream = root.legacyFrenchForcedTextSubtitleStream;
        root._autoLocalizeSubStream = root.legacyFrenchForcedTextSubtitleStream;
        var legacySubUi = root.listIndexForStream(root.legacyFrenchForcedTextSubtitleStream);
        if (legacySubUi >= 0) root.subtitleIndex = legacySubUi;
    } else {
        root._autoLocalizeSubStream = -1;
    }
    var preferOriginal = String(root.playbackRuleMode || "").toLowerCase().trim() === "directplay";
    var dvdRemux = !preferOriginal && root.isDvdSource === true;
    var fullTranscode = (!dvdRemux && root.hasInternalDvdSubtitle === true) ||
                        root.requiresInterlacedTsTranscode === true;
    var preferredAudio = preferredAutomaticAudioStream(root);
    var preferredAudioCodec = audioCodecForStream(root, preferredAudio);
    var incompatibleLosslessOrDtsToAc3 = fullTranscode && fullTranscodeAudioNeedsAc3(preferredAudioCodec);
    root.negotiatePlayback(start, false, false, false, false, {
        resumePreferDP: start > 0 && !remux,
        resumePrerollMs: exactStart === true ? 0 : root.resumePrerollMs,
        // "Original" neutralise les REGLES DE PRECAUTION ReDeFin (DVDSub
        // dormant, TS H.264 entrelace, remux de confort...), mais il ne se fait
        // plus passer pour un DirectPlay MANUEL. Le Core peut ainsi laisser la
        // policy materielle imposer un transcodage si le codec video est
        // reellement incompatible (AV1 sur Devialet, par exemple).
        forceServerRemux: preferOriginal ? false : (remux || dvdRemux),
        forceDvdSubFileTranscode: preferOriginal ? false : (!dvdRemux && root.hasInternalDvdSubtitle === true),
        forceInterlacedTsTranscode: preferOriginal ? false : (root.requiresInterlacedTsTranscode === true),
        forcePlaybackInfoAudioStreamIndex: (!preferOriginal && fullTranscode) ? preferredAudio : undefined,
        forcePlaybackInfoVideoCodec: (!preferOriginal && fullTranscode) ? "h264" : null,
        forcePlaybackInfoAudioCodec: (!preferOriginal && (root.requiresInterlacedTsTranscode === true || incompatibleLosslessOrDtsToAc3)) ? "ac3" : null,
        forceVideoStreamCopyInPlaybackInfo: preferOriginal ? true : (fullTranscode ? false : undefined),
        forceAudioStreamCopyInPlaybackInfo: preferOriginal ? true : ((root.requiresInterlacedTsTranscode === true || incompatibleLosslessOrDtsToAc3) ? false : undefined),
        forceDirectPlayInPlaybackInfo: preferOriginal ? true : (fullTranscode ? false : undefined),
        forceDirectStreamInPlaybackInfo: preferOriginal ? false : (fullTranscode ? false : undefined),
        manualDirectPlayOverride: false,
        manualRemuxOverride: false,
        preferFrenchAudio: preferOriginal ? false : undefined,
        disableAutoFrenchAudio: preferOriginal ? true : undefined,
        disableAutoVoFrenchFullSubtitle: preferOriginal ? true : undefined,
        disableDefaultSubtitleRemux: preferOriginal ? true : undefined,
        disableDefaultFrenchAudioOrderRemux: preferOriginal ? true : undefined,
        disableImageSubtitleRiskRemux: preferOriginal ? true : undefined,
        disableHevcMain10MkvRemux: preferOriginal ? true : undefined
    });
}
function negotiateServerPreroll(root, router, introItemId, onSuccess, onError) {
    introItemId = _s(introItemId);
    if (!root || !router || !introItemId || !root.serverUrl || !root.accessToken || !root.userId) {
        if (onError) onError("missing_context");
        return;
    }
    var expectedMain = _s(root.itemId), expectedServer = _s(root.serverUrl),
        expectedUser = _s(root.userId), expectedToken = _s(root.accessToken);
    var ctx = {
        serverUrl: expectedServer, accessToken: expectedToken, userId: expectedUser, itemId: introItemId,
        selectedAudioStream: -1, selectedSubtitleStream: -1, useLocalSubs: false, selectedSubtitleIsText: false,
        startMs: 0, forceHls: false, forceMp4: false, preferTicks: false, forceDPOnAudioSwitch: false,
        preferFrenchAudio: false, disableAutoFrenchAudio: true, disableAutoVoFrenchFullSubtitle: true,
        disableDefaultSubtitleRemux: true, disableDefaultFrenchAudioOrderRemux: true, disableImageSubtitleRiskRemux: true
    };
    router.negotiatePlayback(ctx, function(res) {
        if (expectedMain !== _s(root.itemId) || expectedServer !== _s(root.serverUrl) ||
                expectedUser !== _s(root.userId) || expectedToken !== _s(root.accessToken)) return;
        if (!res || !res.url) { if (onError) onError("invalid_playback_url"); return; }
        if (onSuccess) onSuccess(res);
    }, function(err) {
        if (expectedMain !== _s(root.itemId) || expectedServer !== _s(root.serverUrl) ||
                expectedUser !== _s(root.userId) || expectedToken !== _s(root.accessToken)) return;
        if (onError) onError(err || "network_error");
    });
}
function startInitialPlayback(root, bridge) {
    var item = root.itemId
    var server = root.serverUrl
    var user = root.userId
    var token = root.accessToken
    var seq = ++root._initialPlaybackSeq
    if (!item || !server || !user || !token) return
    root.refreshStreams(function(ok) {
        if (seq !== root._initialPlaybackSeq || item !== root.itemId ||
                server !== root.serverUrl || user !== root.userId || token !== root.accessToken) return
        var pending = null
        try {
            pending = root.shared && root.shared.__redefinExplicitPlaybackStart
                    ? root.shared.__redefinExplicitPlaybackStart
                    : null
        } catch(e0) {}
        var directPlayReload = !!(pending
            && String(pending.source || "") === "directplay-reload"
            && String(pending.itemId || "") === String(item)
            && String(pending.serverUrl || "") === String(server)
            && String(pending.userId || "") === String(user)
            && Number(pending.startMs) >= 0
            && (Date.now() - Number(pending.ts || 0)) < 30000);
        if (directPlayReload) {
            var directPlayStart = Math.max(0, Math.floor(Number(pending.startMs)));
            try { root.shared.__redefinExplicitPlaybackStart = null; } catch(eDirectClear) {}
            if (typeof root._resetServerPrerollState === "function")
                root._resetServerPrerollState("directplay-reload");
            startFreshDirectPlayPlayback(root, directPlayStart);
            return;
        }
        var pendingSource = pending ? String(pending.source || "") : ""
        var explicit = !!(pending
            && (pendingSource === "chapter" || pendingSource === "restart")
            && String(pending.itemId || "") === String(item)
            && String(pending.serverUrl || "") === String(server)
            && String(pending.userId || "") === String(user)
            && Number(pending.startMs) >= 0
            && (Date.now() - Number(pending.ts || 0)) < 30000)
        if (explicit) {
            var explicitStart = Math.max(0, Math.floor(Number(pending.startMs)))
            try { root.shared.__redefinExplicitPlaybackStart = null } catch(e1) {}
            if (pendingSource === "restart") {
                var restartRemux = shouldForceInitialServerRemux(root)
                if (typeof root._resetServerPrerollState === "function")
                    root._resetServerPrerollState("restart-from-beginning")
                // Un vrai « Lire depuis le début » reproduit un lancement neuf :
                // position Jellyfin ignorée, mais pré-roll/intro de première lecture
                // conservé s'il est disponible.
                if (typeof root._tryStartServerPreroll === "function" &&
                        root._tryStartServerPreroll(0, restartRemux, 0)) return
                startResolvedMainPlayback(root, 0, restartRemux, true)
                return
            }
            if (typeof root._resetServerPrerollState === "function")
                root._resetServerPrerollState("chapter-start")
            startResolvedMainPlayback(root, explicitStart, shouldForceInitialServerRemux(root), true)
            return
        }
        // Playlist série explicitement lancée depuis DetailSeriePage :
        // ne jamais consulter la reprise Jellyfin. Le choix utilisateur est
        // "Tout lire depuis le début" / "Lecture aléatoire", donc chaque
        // épisode de cette session doit partir de 0. On conserve néanmoins
        // le pré-roll Jellyfin/Intros des premières lectures.
        if (root.forcePlaylistStartAtZero === true) {
            var zeroRemux = shouldForceInitialServerRemux(root)
            if (typeof root._tryStartServerPreroll === "function" &&
                    root._tryStartServerPreroll(0, zeroRemux, 0)) return
            startResolvedMainPlayback(root, 0, zeroRemux, true)
            return
        }
        fetchResumeMs(root, bridge, function(ms, resumeResolved) {
            if (seq !== root._initialPlaybackSeq || item !== root.itemId ||
                    server !== root.serverUrl || user !== root.userId || token !== root.accessToken) return
            var rawResumeMs = Math.max(0, Math.floor(Number(ms || 0)))
            var duration = root.durationMs()
            var start = duration > 0 && rawResumeMs / duration >= 0.97 ? 0 : rawResumeMs
            var remux = shouldForceInitialServerRemux(root)
            // Local Intros est un pré-roll de première lecture uniquement.
            // Si Jellyfin possède déjà une position de reprise, on démarre directement
            // le média principal. En cas d'échec de lecture de UserData, on n'affiche
            // pas non plus l'intro afin d'éviter un faux pré-roll sur un média repris.
            if (resumeResolved === true && rawResumeMs <= 0 &&
                    typeof root._tryStartServerPreroll === "function" &&
                    root._tryStartServerPreroll(start, remux, rawResumeMs)) return
            startResolvedMainPlayback(root, start, remux)
        })
    })
}

/* ================== PlayerOverlay: pré-roll Jellyfin / Local Intros ================== */

var _playerOverlayRouterFacade = {
    negotiatePlayback: function(ctx, onSuccess, onError) {
        return negotiatePlayback(ctx, onSuccess, onError);
    }
};

function _playerOverlayTimers(root) {
    try { return root && root._playbackTimers ? (root._playbackTimers() || {}) : {}; }
    catch (e) { return {}; }
}

function _stopPlayerOverlayTimer(timer) {
    try { if (timer && timer.stop) timer.stop(); } catch (e) {}
}

function _serverPrerollMethodForResult(res) {
    if (res && (res.isHls || res.lastUsedTranscoding)) return "Transcode";
    if (res && (res.lastUsedDirectStream || res.lastUsedServerRemux ||
                res.serverTimedStream || res.timeShifted)) return "DirectStream";
    return "DirectPlay";
}

function stopServerPrerollSession(root, mediaPlayer, bridge, reason) {
    if (!root || !mediaPlayer || !bridge || root._serverPrerollStopReported ||
            !root._serverPrerollPlaySessionId || !root._serverPrerollItemId ||
            !root.serverUrl || !root.accessToken) return;
    root._serverPrerollStopReported = true;
    bridge.sessionsPlayingStopped(root.serverUrl, root.accessToken, {
        ItemId: root._serverPrerollItemId,
        MediaSourceId: root._serverPrerollMediaSourceId || "",
        PlaySessionId: root._serverPrerollPlaySessionId,
        PositionTicks: Math.max(0, Math.floor(Number(mediaPlayer.position || 0))) * 10000
    }, function(){}, function(){});
}

function resetServerPrerollState(root, mediaPlayer, bridge, reason) {
    if (!root) return;
    root._serverPrerollSeq++;
    if (root.serverPrerollActive && root._serverPrerollServerUrl === root.serverUrl)
        stopServerPrerollSession(root, mediaPlayer, bridge, reason || "reset");
    root.serverPrerollActive = false;
    root._serverPrerollState = 0;
    root._serverPrerollForItemId = "";
    root._serverPrerollServerUrl = "";
    root._serverPrerollItemId = "";
    root._serverPrerollPlaySessionId = "";
    root._serverPrerollMediaSourceId = "";
    root._serverPrerollMediaUrl = "";
    root._serverPrerollPlayMethod = "DirectPlay";
    root._serverPrerollStartReported = false;
    root._serverPrerollStopReported = false;
    root._serverPrerollMainStartMs = 0;
    root._serverPrerollMainForceRemux = false;
    root._serverPrerollMainStarted = false;
}

function sendServerPrerollStartIfNeeded(root, mediaPlayer, bridge) {
    if (!root || !mediaPlayer || !bridge || !root.serverPrerollActive ||
            root._serverPrerollStartReported || !root._serverPrerollItemId ||
            !root._serverPrerollPlaySessionId || !root.serverUrl || !root.accessToken) return;
    root._serverPrerollStartReported = true;
    bridge.sessionsPlayingStart(root.serverUrl, root.accessToken, {
        ItemId: root._serverPrerollItemId,
        MediaSourceId: root._serverPrerollMediaSourceId || "",
        PlaySessionId: root._serverPrerollPlaySessionId,
        CanSeek: false,
        IsPaused: false,
        PositionTicks: Math.max(0, Math.floor(Number(mediaPlayer.position || 0))) * 10000,
        PlayMethod: root._serverPrerollPlayMethod,
        AudioStreamIndex: null,
        SubtitleStreamIndex: null,
        RepeatMode: "RepeatNone"
    }, function(){}, function(){});
}

function _prepareServerPrerollUi(root) {
    var timers = _playerOverlayTimers(root);
    root.controlsVisible = false;
    root.audioMenuVisible = false;
    root.subMenuVisible = false;
    root.scrubActive = false;
    root.scrubAccumUiMs = -1;
    root._scrubCommitTargetUiMs = -1;
    _stopPlayerOverlayTimer(timers.controls);
    _stopPlayerOverlayTimer(timers.scrubCommit);
    root._cancelCoalescedLocalSeek();
    _stopPlayerOverlayTimer(timers.resumeCheckpoint);
    _stopPlayerOverlayTimer(timers.seekRestore);
    _stopPlayerOverlayTimer(timers.frozenWatch);
    root._stopFrozenPlaybackWatch("server-preroll");
    root.disableLocalSubsOverlay();
}

function _startMainAfterServerPreroll(root, reason) {
    if (root._serverPrerollMainStarted) return;
    root._serverPrerollMainStarted = true;
    root.serverPrerollActive = false;
    root._serverPrerollState = 3;
    root._armVideoLoading("server-preroll-main-switch");
    startResolvedMainPlayback(root, root._serverPrerollMainStartMs,
                              root._serverPrerollMainForceRemux);
}

function _playServerPreroll(root, mediaPlayer, bridge, introId, seq) {
    if (root._serverPrerollState !== 1 || seq !== root._serverPrerollSeq) return;
    root._serverPrerollState = 2;
    root.serverPrerollActive = true;
    root._serverPrerollItemId = String(introId || "");
    root._serverPrerollPlaySessionId = "";
    root._serverPrerollMediaSourceId = "";
    root._serverPrerollMediaUrl = "";
    root._serverPrerollStartReported = false;
    root._serverPrerollStopReported = false;
    negotiateServerPreroll(root, _playerOverlayRouterFacade,
                           root._serverPrerollItemId, function(res) {
        if (seq !== root._serverPrerollSeq || root._serverPrerollState !== 2 ||
                String(root.itemId || "") !== root._serverPrerollForItemId) return;
        root._serverPrerollPlaySessionId = String(res.playSessionId || "");
        root._serverPrerollMediaSourceId = String(res.mediaSourceId || "");
        root._serverPrerollMediaUrl = String(res.url || "");
        root._serverPrerollPlayMethod = _serverPrerollMethodForResult(res);
        root.baseOffsetMs = 0;
        root._setPendingSeekMs(-1, "server-preroll-negotiate");
        root._pendingServerTimedBaseMs = -1;
        root._pendingHardResetBaseMs = -1;
        root.lastUiTargetMs = 0;
        root.playSessionId = "";
        root.currentMediaSourceId = "";
        root._mediaUrlSwap(root._serverPrerollMediaUrl, true);
    }, function() {
        if (seq !== root._serverPrerollSeq || root._serverPrerollState !== 2) return;
        finishServerPreroll(root, mediaPlayer, bridge, "intro-negotiation-failed");
    });
}

function tryStartServerPreroll(root, mediaPlayer, bridge,
                               mainStartMs, forceMainRemux, rawResumeMs) {
    if (!root || !mediaPlayer || !bridge) return false;
    if (Math.max(0, Math.floor(Number(rawResumeMs || 0))) > 0) return false;
    if (!root.serverPrerollEnabled || !root.serverUrl || !root.accessToken ||
            !root.userId || !root.itemId || typeof bridge.fetchIntros !== "function") return false;

    var expectedItem = String(root.itemId || "");
    var expectedServer = String(root.serverUrl || "");
    var expectedUser = String(root.userId || "");
    var expectedToken = String(root.accessToken || "");
    root._serverPrerollMainStartMs = Math.max(0, Math.floor(Number(mainStartMs || 0)));
    root._serverPrerollMainForceRemux = forceMainRemux === true;
    if (root._serverPrerollForItemId && root._serverPrerollForItemId !== expectedItem)
        resetServerPrerollState(root, mediaPlayer, bridge, "item-mismatch");
    if (root._serverPrerollMainStarted || root._serverPrerollState > 0) return true;

    var seq = ++root._serverPrerollSeq;
    var timers = _playerOverlayTimers(root);
    root._serverPrerollForItemId = expectedItem;
    root._serverPrerollServerUrl = expectedServer;
    root._serverPrerollState = 1;
    _prepareServerPrerollUi(root);
    root._armVideoLoading("server-preroll-resolve");
    root._cancelHardSourceReset("server-preroll-resolve");
    root._cancelStartupPlay("server-preroll-resolve");
    _stopPlayerOverlayTimer(timers.audioGate);
    try { mediaPlayer.stop(); } catch (e0) {}
    root.mediaUrl = "";
    root._setMediaPlayerSource("", "server-preroll-resolve");

    bridge.fetchIntros(expectedServer, expectedToken, expectedUser, expectedItem, function(items) {
        if (seq !== root._serverPrerollSeq || expectedItem !== String(root.itemId || "") ||
                expectedServer !== String(root.serverUrl || "") ||
                expectedUser !== String(root.userId || "") ||
                expectedToken !== String(root.accessToken || "")) return;
        var introId = "";
        for (var i = 0; items && i < items.length; i++) {
            var candidate = items[i] && items[i].Id ? String(items[i].Id) : "";
            if (candidate && candidate !== expectedItem) { introId = candidate; break; }
        }
        if (!introId) {
            _startMainAfterServerPreroll(root, "no-intro");
            return;
        }
        _playServerPreroll(root, mediaPlayer, bridge, introId, seq);
    }, function() {
        if (seq !== root._serverPrerollSeq || expectedItem !== String(root.itemId || "")) return;
        _startMainAfterServerPreroll(root, "intro-query-failed");
    });
    return true;
}

function finishServerPreroll(root, mediaPlayer, bridge, reason) {
    if (!root || root._serverPrerollState !== 2) return;
    var timers = _playerOverlayTimers(root);
    root._serverPrerollState = 3;
    stopServerPrerollSession(root, mediaPlayer, bridge, reason || "intro-finished");
    root.serverPrerollActive = false;
    root._cancelStartupPlay("server-preroll-finished");
    _stopPlayerOverlayTimer(timers.audioGate);
    _stopPlayerOverlayTimer(timers.seekRestore);
    _stopPlayerOverlayTimer(timers.resumeCheckpoint);
    root._gateArmed = false;
    root._resumeAfterGate = false;
    root._startupPlayWanted = false;
    root._setPendingSeekMs(-1, "server-preroll-finished");
    root._pendingServerTimedBaseMs = -1;
    root._pendingHardResetBaseMs = -1;
    root.baseOffsetMs = 0;
    try { mediaPlayer.stop(); } catch (e0) {}
    root.mediaUrl = "";
    root._setMediaPlayerSource("", "server-preroll-finished");
    root._serverPrerollPlaySessionId = "";
    root._serverPrerollMediaSourceId = "";
    root._serverPrerollMediaUrl = "";
    _startMainAfterServerPreroll(root, reason || "intro-finished");
}

function completeServerPrerollTransition(root) {
    if (!root || root._serverPrerollState !== 3 || !root._serverPrerollMainStarted) return;
    root._serverPrerollState = 4;
    root.serverPrerollActive = false;
    root.controlsVisible = true;
    root.controlsFocus = root.cF_CONTROLS;
    root._lastUiClockPushWallMs = 0;
    root.updateClocksFromPlayback();
    root._syncControlsTimer();
    root._pushTopBar();
    try { Qt.callLater(function(){ root._focusControlsLater(); }); }
    catch (e0) { root._focusControlsLater(); }
}

function abortServerPrerollForExit(root, mediaPlayer, bridge, reason) {
    if (!root) return;
    var timers = _playerOverlayTimers(root);
    root._serverPrerollSeq++;
    root._initialPlaybackSeq++;
    root._negotiationSeq++;
    if (root.serverPrerollActive)
        stopServerPrerollSession(root, mediaPlayer, bridge, reason || "exit");
    root.serverPrerollActive = false;
    root._serverPrerollState = 4;
    root._serverPrerollMainStarted = true;
    root._cancelStartupPlay("server-preroll-exit");
    _stopPlayerOverlayTimer(timers.audioGate);
    _stopPlayerOverlayTimer(timers.seekRestore);
    _stopPlayerOverlayTimer(timers.resumeCheckpoint);
    root._gateArmed = false;
    root._resumeAfterGate = false;
    root._startupPlayWanted = false;
    root.playSessionId = "";
    root.currentMediaSourceId = "";
}

function prepareQualityServerSubtitle(root, forceServerMode) {
    if (!root || !forceServerMode || !root.useLocalSubs || root.localSubStreamIndex < 0)
        return;
    root.selectedSubtitleStream = root.localSubStreamIndex;
    var index = root.listIndexForStream(root.localSubStreamIndex);
    if (index >= 0) root.subtitleIndex = index;
    root.disableLocalSubsOverlay();
}

function _qualityTargetUi(root) {
    try { return root._clampUi(root.uiPositionMs()); }
    catch (e0) { return Math.max(0, Math.floor(Number(root.lastUiTargetMs || 0))); }
}

function applyManualRemuxQuality(root, mediaPlayer) {
    if (!root || !mediaPlayer || root._tearingDownPlayer ||
            !root.serverUrl || !root.accessToken || !root.userId || !root.itemId)
        return false;

    var target = _qualityTargetUi(root);
    var resume = mediaPlayer.playbackState === root._mpPlayingState;
    root._wasPlayingBeforeSwitch = resume;
    root._resumeWantedAfterNegotiation = resume;
    root.lastUiTargetMs = target;
    root.manualQualityBitrate = 0;
    root.manualDirectPlayMode = false;
    root.manualRemuxMode = true;
    prepareQualityServerSubtitle(root, true);
    try { if (resume) mediaPlayer.pause(); } catch (e0) {}

    return root.negotiatePlayback(target, false, true, false, false, {
        forceRetry: true,
        forceServerSeek: target > 0,
        forceServerRemux: true,
        forceHlsOnDpSeekFallback: false,
        forceDirectPlayInPlaybackInfo: false,
        forceDirectStreamInPlaybackInfo: false,
        forceVideoStreamCopyInPlaybackInfo: true,
        forceAudioStreamCopyInPlaybackInfo: true,
        forceDvdSubFileTranscode: false,
        forceInterlacedTsTranscode: false,
        forcePlaybackInfoVideoCodec: null,
        manualDirectPlayOverride: false,
        manualRemuxOverride: true,
        disableImageSubtitleRiskRemux: true,
        disableHevcMain10MkvRemux: true,
        disableDefaultSubtitleRemux: true
    });
}

function applyAutomaticQuality(root, mediaPlayer) {
    if (!root || !mediaPlayer || root._tearingDownPlayer ||
            !root.serverUrl || !root.accessToken || !root.userId || !root.itemId)
        return false;

    var target = _qualityTargetUi(root);
    var resume = mediaPlayer.playbackState === root._mpPlayingState;
    root._wasPlayingBeforeSwitch = resume;
    root._resumeWantedAfterNegotiation = resume;
    root.lastUiTargetMs = target;
    root.manualQualityBitrate = 0;
    root.manualDirectPlayMode = false;
    root.manualRemuxMode = false;

    var dvdRemux = root.isDvdSource === true;
    var hardTranscode = (!dvdRemux && root.hasInternalDvdSubtitle === true) ||
                        root.requiresInterlacedTsTranscode === true;
    var autoRemux = shouldForceInitialServerRemux(root) || dvdRemux;
    prepareQualityServerSubtitle(root, hardTranscode || autoRemux);
    try { if (resume) mediaPlayer.pause(); } catch (e0) {}

    return root.negotiatePlayback(target, false, true, false, false, {
        forceRetry: true,
        forceServerSeek: (hardTranscode || autoRemux) && target > 0,
        forceServerRemux: autoRemux,
        forceHlsOnDpSeekFallback: false,
        forceDvdSubFileTranscode: !dvdRemux && root.hasInternalDvdSubtitle === true,
        forceInterlacedTsTranscode: root.requiresInterlacedTsTranscode === true,
        forcePlaybackInfoVideoCodec: hardTranscode ? "h264" : null,
        forceVideoStreamCopyInPlaybackInfo: hardTranscode ? false : undefined,
        forceDirectPlayInPlaybackInfo: hardTranscode ? false : undefined,
        forceDirectStreamInPlaybackInfo: hardTranscode ? false : undefined,
        manualDirectPlayOverride: false
    });
}

function playerDurationMs(root, mediaPlayer) {
    var full = root.runtimeTicks > 0 ? Math.floor(Number(root.runtimeTicks) / 10000) : 0;
    if (full > 0) return full;

    var local = mediaPlayer.duration > 0 ? Math.floor(Number(mediaPlayer.duration)) : 0;
    if (root.baseOffsetMs > 0 && local > 0 && (root.serverTimedStream || root.timeShifted))
        local += Math.max(0, Math.floor(Number(root.baseOffsetMs) || 0));
    return Math.max(0, local);
}

function playerUiPositionMs(root, mediaPlayer) {
    if (root._sourceResetActive && root._sourceResetExpectedUiMs >= 0)
        return Math.max(0, root._sourceResetExpectedUiMs);
    if (root._trackSwitchRebaseActive && root._trackSwitchVerificationActive && root._trackSwitchRequestedUiMs >= 0)
        return Math.max(0, root._trackSwitchRequestedUiMs);
    return Math.max(0, root.baseOffsetMs + mediaPlayer.position);
}

function playerSubtitleClockMs(root, mediaPlayer) {
    var localMs = Math.max(0, Math.floor(Number(mediaPlayer.position) || 0));
    var baseMs = Math.max(0, Math.floor(Number(root.baseOffsetMs) || 0));
    return Math.max(0, baseMs + localMs);
}

function playerKeepUiPosition(root, mediaPlayer) {
    if (root.scrubActive) {
        if (root.scrubAccumUiMs >= 0) return root.scrubAccumUiMs;
        if (root._scrubCommitTargetUiMs >= 0) return root._scrubCommitTargetUiMs;
        return playerUiPositionMs(root, mediaPlayer);
    }
    if (root._pendingSeekMs >= 0) return root._pendingSeekMs;
    return playerUiPositionMs(root, mediaPlayer);
}

function playerPersistableDurationMs(root, mediaPlayer) {
    var full = root.runtimeTicks > 0 ? Math.floor(Number(root.runtimeTicks) / 10000) : 0;
    return full > 0 ? full : playerDurationMs(root, mediaPlayer);
}

function clampPlayerPersistableUi(root, mediaPlayer, position) {
    var value = Math.max(0, Math.floor(Number(position || 0)));
    var duration = playerPersistableDurationMs(root, mediaPlayer);
    return duration > 0 ? Math.min(value, duration) : value;
}

function rememberPlayerPersistablePosition(root, mediaPlayer, position, reason) {
    var value = clampPlayerPersistableUi(root, mediaPlayer, position);
    if (value <= 0) return root._lastPersistableUiMs;
    root._lastPersistableUiMs = value;
    return value;
}

function capturePlayerPersistablePosition(root, mediaPlayer, reason) {
    if (root.serverPrerollBlocking) return 0;
    if (root._playbackExitInProgress && root._finalExitPositionMs >= 0)
        return root._finalExitPositionMs;

    var position = 0;
    try { position = root._reportUiPositionMs(reason || "persist", true); }
    catch (e0) {
        try { position = playerUiPositionMs(root, mediaPlayer); }
        catch (e1) { position = 0; }
    }

    if (root.scrubActive) {
        if (root.scrubAccumUiMs >= 0) position = root.scrubAccumUiMs;
        else if (root._scrubCommitTargetUiMs >= 0) position = root._scrubCommitTargetUiMs;
    } else if (root._pendingSeekMs >= 0) {
        position = root._pendingSeekMs;
    } else if (root._sourceResetActive && root._sourceResetExpectedUiMs >= 0) {
        position = root._sourceResetExpectedUiMs;
    } else if (root._trackSwitchRebaseActive && root._trackSwitchRequestedUiMs >= 0) {
        position = root._trackSwitchRequestedUiMs;
    }

    position = clampPlayerPersistableUi(root, mediaPlayer, position);
    if (position <= 250 && root._lastPersistableUiMs > 1000 &&
            (mediaPlayer.playbackState === root._mpStoppedState || root._tearingDownPlayer))
        position = root._lastPersistableUiMs;
    return position;
}

function qualityHasCurrentSource(root, mediaPlayer) {
    if (!root || root.serverPrerollBlocking) return false;
    try {
        return String(root.mediaUrl || "").length > 0 || String(mediaPlayer.source || "").length > 0;
    } catch (e0) {}
    return false;
}

function qualityOriginalDirectPlaySelected(root, mediaPlayer) {
    if (root.manualQualityBitrate > 0 || root.manualRemuxMode) return false;
    if (!qualityHasCurrentSource(root, mediaPlayer)) return false;
    // Le panneau Qualité décrit le pipeline réellement obtenu, pas uniquement
    // l'intention manuelle qui a précédé la dernière négociation.
    return !root.isHls && !root.lastUsedTranscoding && !root.lastUsedDirectStream &&
           !root.lastUsedServerRemux && !root.serverTimedStream && !root.timeShifted;
}

function qualityRemuxSelected(root, mediaPlayer) {
    if (root.manualQualityBitrate > 0) return false;
    if (root.manualRemuxMode) return true;
    if (root.lastUsedTranscoding || root.isHls) return false;
    if (!qualityHasCurrentSource(root, mediaPlayer)) return false;
    return root.lastUsedServerRemux === true && root.lastUsedDirectStream !== true;
}

function qualityAutomaticServerSelected(root, mediaPlayer) {
    if (root.manualQualityBitrate > 0) return false;
    if (!qualityHasCurrentSource(root, mediaPlayer)) return false;
    if (qualityOriginalDirectPlaySelected(root, mediaPlayer) || qualityRemuxSelected(root, mediaPlayer))
        return false;
    return root.lastUsedTranscoding || root.lastUsedDirectStream || root.isHls ||
           root.serverTimedStream || root.timeShifted || root.currentPlaybackVideoTranscodeByPolicy;
}

function qualityAutomaticServerLabel(root) {
    if (root.lastUsedTranscoding && root.isHls) return "Automatique · Transcodage HLS";
    if (root.lastUsedTranscoding) return "Automatique · Transcodage serveur";
    if (root.lastUsedDirectStream) return "Automatique · DirectStream";
    if (root.serverTimedStream || root.timeShifted) return "Automatique · Flux serveur";
    return "Automatique";
}

function qualityStatusText(root, mediaPlayer) {
    if (root.manualQualityBitrate > 0) {
        var mb = Number(root.manualQualityBitrate) / 1000000.0;
        var text = mb >= 1
                ? mb.toFixed(mb % 1 === 0 ? 0 : 1).replace(".", ",") + " Mbit/s"
                : Math.round(Number(root.manualQualityBitrate) / 1000.0) + " Kbit/s";
        return "Transcodage manuel · " + text;
    }
    if (root.manualDirectPlayMode && qualityOriginalDirectPlaySelected(root, mediaPlayer)) return "DirectPlay manuel";
    if (root.manualRemuxMode) return "Remux serveur manuel";
    if (qualityOriginalDirectPlaySelected(root, mediaPlayer)) return "DirectPlay automatique";
    if (qualityRemuxSelected(root, mediaPlayer)) return "Remux serveur automatique";
    if (root.lastUsedTranscoding && root.isHls) return "Transcodage HLS automatique";
    if (root.lastUsedTranscoding) return "Transcodage serveur automatique";
    if (root.lastUsedDirectStream) return "DirectStream automatique";
    if (root.serverTimedStream || root.timeShifted) return "Flux serveur automatique";
    return "Décision ReDeFin / Jellyfin";
}

/* ================== PlayerOverlay: reporting Jellyfin ================== */

function playMethod(root) {
    if (root.isHls || root.lastUsedTranscoding) return "Transcode";
    if (root.lastUsedDirectStream || root.lastUsedServerRemux || root.serverTimedStream || root.timeShifted) return "DirectStream";
    return "DirectPlay";
}
function _sessionPayload(root, paused, positionMs) {
    var p = Number(positionMs);
    if (!isFinite(p) || p < 0) {
        try {
            p = root._pendingSeekMs >= 0
              ? root._pendingSeekMs
              : root._reportUiPositionMs("session", !!paused);
        } catch(e0) {
            p = 0;
        }
    }
    p = clampPlayerPersistableUi(root, null, p);
    return {
        ItemId: root.itemId,
        MediaSourceId: root.currentMediaSourceId || "",
        PlaySessionId: root.playSessionId,
        CanSeek: true,
        IsPaused: !!paused,
        PositionTicks: root._ticks(p),
        PlayMethod: playMethod(root),
        AudioStreamIndex: root.selectedAudioStream >= 0 ? root.selectedAudioStream : null,
        SubtitleStreamIndex: root.selectedSubtitleStream >= 0 ? root.selectedSubtitleStream : null,
        RepeatMode: "RepeatNone"
    };
}
function sendStartIfNeeded(root, bridge, positionMs) {
    if (root && root.serverPrerollBlocking === true) return;
    if (!root.scrobbleEnabled || root._startedReported && root._reportedSessionId === root.playSessionId) return;
    if (!root.serverUrl || !root.accessToken || !root.userId || !root.itemId || !root.playSessionId) return;
    bridge.sessionsPlayingStart(root.serverUrl, root.accessToken, _sessionPayload(root, false, positionMs), function(){}, function(){});
    root._startedReported = true;
    root._reportedSessionId = root.playSessionId;
}
function sendProgress(root, bridge, paused, positionMs, done) {
    if (root && root.serverPrerollBlocking === true) {
        if (typeof done === "function") done(false);
        return false;
    }
    if (!root.scrobbleEnabled || !root.serverUrl || !root.accessToken || !root.userId || !root.itemId || !root.playSessionId) {
        if (typeof done === "function") done(false);
        return false;
    }
    bridge.sessionsPlayingProgress(root.serverUrl, root.accessToken,
        _sessionPayload(root, paused, positionMs),
        function(){ if (typeof done === "function") done(true); },
        function(){ if (typeof done === "function") done(false); });
    return true;
}
function _finishStoppedCallback(done, ok) {
    if (typeof done !== "function") return;
    try { done(ok === true); } catch(e) {}
}
function sendStoppedAtPosition(root, bridge, positionMs, done) {
    if (root && root.serverPrerollBlocking === true) {
        _finishStoppedCallback(done, false);
        return false;
    }
    if (!root || !bridge || !root.scrobbleEnabled || !root.serverUrl || !root.accessToken ||
            !root.userId || !root.itemId || !root.playSessionId) {
        _finishStoppedCallback(done, false);
        return false;
    }
    var sessionId = String(root.playSessionId || "");
    if (!sessionId) {
        _finishStoppedCallback(done, false);
        return false;
    }
    if (root._stoppedReportedSessionId === sessionId) {
        _finishStoppedCallback(done, true);
        return true;
    }
    if (root._stoppedPendingSessionId === sessionId) {
        _finishStoppedCallback(done, true);
        return true;
    }
    var frozenMs = Math.max(0, Math.floor(Number(positionMs || 0)));
    var ticks = root._ticks(frozenMs);
    var serverUrl = root.serverUrl;
    var accessToken = root.accessToken;
    var userId = root.userId;
    var itemId = root.itemId;
    var mediaSourceId = root.currentMediaSourceId || "";
    root._stoppedPendingSessionId = sessionId;
    function finishAll(ok) {
        try {
            if (root && root._stoppedPendingSessionId === sessionId)
                root._stoppedPendingSessionId = "";
            if (root && ok === true)
                root._stoppedReportedSessionId = sessionId;
        } catch(e0) {}
        _finishStoppedCallback(done, ok === true);
    }
    function sendUserDataRequest(retried, stoppedOk) {
        try {
            bridge.updateUserPlaybackPosition(serverUrl, accessToken, userId, itemId, ticks,
                function() { finishAll(true); },
                function() {
                    if (retried !== true) sendUserDataRequest(true, stoppedOk);
                    else finishAll(stoppedOk === true);
                }
            );
        } catch(e0) {
            if (retried !== true) sendUserDataRequest(true, stoppedOk);
            else finishAll(stoppedOk === true);
        }
    }
    function sendStoppedRequest(retried) {
        try {
            bridge.sessionsPlayingStopped(serverUrl, accessToken, {
                ItemId: itemId,
                MediaSourceId: mediaSourceId,
                PlaySessionId: sessionId,
                PositionTicks: ticks
            }, function() {
                // L'écriture UserData exacte est volontairement DERNIERE.
                sendUserDataRequest(false, true);
            }, function() {
                if (retried !== true) sendStoppedRequest(true);
                else sendUserDataRequest(false, false);
            });
        } catch(e0) {
            if (retried !== true) sendStoppedRequest(true);
            else sendUserDataRequest(false, false);
        }
    }
    // Ordre strict : Stopped -> UserData exact.
    // Cela évite que la logique de fin de session réécrive ensuite la position.
    sendStoppedRequest(false);
    return true;
}
function sendStopped(root, bridge, done) {
    if (!root) {
        _finishStoppedCallback(done, false);
        return false;
    }
    var positionMs = -1;
    try {
        if (typeof root._finalExitPositionMs === "number" && root._finalExitPositionMs >= 0)
            positionMs = root._finalExitPositionMs;
        else if (typeof root._capturePersistablePositionMs === "function")
            positionMs = root._capturePersistablePositionMs("stopped");
        else
            positionMs = root._reportUiPositionMs("stopped", true);
    } catch(e0) {
        positionMs = 0;
    }
    return sendStoppedAtPosition(root, bridge, positionMs, done);
}

