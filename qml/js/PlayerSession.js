.pragma library
.import "JellyfinPlaybackRouter.js" as PlaybackRouter
.import "SeasonUtils.js" as SeasonUtils

// Orchestre une session du lecteur : démarrage/pré-roll, choix utilisateur,
// playlist, horloges et reporting ; aucune politique matérielle de codecs.
// Consommateurs : playeroverlay.qml et playerOverlayHelper.js.
// L’état appartient à root ; le MediaPlayer et le bridge sont injectés.
// Les fonctions préfixées par _ sont internes ; les pages utilisent les
// opérations de session, de qualité, d’horloge et de reporting uniquement.
// Les générations, positions figées et séquences Stopped -> UserData sont
// conservées afin de protéger les transitions asynchrones et la reprise.

function _s(v) {
    return (v === undefined || v === null) ? "" : String(v)
}

function _numberOr(value, fallback) {
    var n = Number(value)
    return isFinite(n) ? n : fallback
}

function applyStickyManualDirectPlay(root, ctx) {
    if (!root || !ctx || root.manualDirectPlayMode !== true) return false

    // Le choix explicite DirectPlay reste souverain sur les options ponctuelles
    // ajoutées par les retries, recoveries et changements de piste.
    ctx.manualDirectPlayOverride = true
    ctx.manualRemuxOverride = false
    ctx.forceServerSeek = false
    ctx.forceServerRemux = false
    ctx.forceHls = false
    ctx.forceHlsOnDpSeekFallback = false
    ctx.forceMp4 = false
    ctx.forceHevcMain10Remux = false
    ctx.forceExplicitServerProgressiveSeek = false
    ctx.forceJellyfinTranscodingUrlCopyRemux = false
    ctx.forceAllowTranscoding = false
    ctx.forceTranscodeOnTrackSwitch = false
    ctx.forceVideoTranscodeCodec = null
    ctx.forcePlaybackInfoVideoCodec = null
    ctx.forcePlaybackInfoAudioCodec = null
    ctx.forcePlaybackInfoAudioStreamIndex = -1
    ctx.forcePolicyTranscodeVideoBitrate = 0
    ctx.forcePolicyTranscodeHls = false
    ctx.forcePolicyTranscodeHlsColdStart = false
    ctx.manualQualityRequest = false
    ctx.manualQualityBitrate = 0
    ctx.currentPlaybackVideoTranscodeByPolicy = false
    ctx.forceDirectPlayInPlaybackInfo = true
    ctx.forceDirectStreamInPlaybackInfo = false
    ctx.forceVideoStreamCopyInPlaybackInfo = true
    ctx.forceAudioStreamCopyInPlaybackInfo = true
    ctx.forceSubtitleEncode = false
    ctx.preferImageSubtitleRemux = false
    ctx.forceFullRemuxForImageSubtitles = false
    ctx.forceDvdSubFileTranscode = false
    ctx.forceInterlacedTsTranscode = false
    ctx.preferFrenchAudio = false
    ctx.disableAutoFrenchAudio = true
    ctx.disableDefaultSubtitleRemux = true
    ctx.disableDefaultFrenchAudioOrderRemux = true
    ctx.disableImageSubtitleRiskRemux = true
    ctx.disableHevcMain10MkvRemux = true
    ctx.disableDvdFolderMpegRemux = true
    return true
}

function applyStickyManualRemux(root, ctx) {
    if (!root || !ctx || root.manualRemuxMode !== true) return false

    ctx.manualRemuxOverride = true
    ctx.manualDirectPlayOverride = false
    ctx.forceServerRemux = true
    ctx.forceDvdSubFileTranscode = false
    ctx.forceInterlacedTsTranscode = false
    ctx.forcePlaybackInfoVideoCodec = null
    ctx.forceVideoStreamCopyInPlaybackInfo = true
    ctx.forceAudioStreamCopyInPlaybackInfo = true
    ctx.forceDirectPlayInPlaybackInfo = false
    ctx.forceDirectStreamInPlaybackInfo = false
    ctx.disableDefaultSubtitleRemux = true
    ctx.disableDefaultFrenchAudioOrderRemux = true
    ctx.disableImageSubtitleRiskRemux = true
    ctx.disableHevcMain10MkvRemux = true
    ctx.allowLocalSubtitleOverlay = false
    ctx.preferExternalTextSubtitlesInRemux = false
    ctx.forceTextSubtitleServerBurnIn = false
    ctx.preferServerSubtitleBurnInOnVideoTranscode = false
    return true
}

function applyStickyManualQuality(root, ctx) {
    if (!root || !ctx) return 0
    if (root.manualDirectPlayMode === true || root.manualRemuxMode === true) return 0

    var rate = Math.max(0, Math.floor(_numberOr(root.manualQualityBitrate, 0)))
    if (!(rate > 0)) return 0
    rate = Math.max(420000, Math.min(200000000, rate))

    ctx.manualDirectPlayOverride = false
    ctx.manualRemuxOverride = false
    ctx.forceServerRemux = false
    ctx.forceAllowTranscoding = true
    ctx.forceVideoTranscodeCodec = ctx.forceVideoTranscodeCodec || "h264"
    ctx.forcePlaybackInfoVideoCodec = ctx.forcePlaybackInfoVideoCodec || "h264"
    ctx.forceDirectPlayInPlaybackInfo = false
    ctx.forceDirectStreamInPlaybackInfo = false
    ctx.forceVideoStreamCopyInPlaybackInfo = false
    ctx.forceAudioStreamCopyInPlaybackInfo = (ctx.forceAudioStreamCopyInPlaybackInfo === false) ? false : true
    ctx.forcePolicyTranscodeVideoBitrate = rate

    if (ctx.forcePolicyTranscodeHls === undefined || ctx.forcePolicyTranscodeHls === null) {
        if (root.lastUsedTranscoding === true)
            ctx.forcePolicyTranscodeHls = (root.isHls === true)
    }
    if (ctx.forcePolicyTranscodeHls === true &&
            (ctx.forcePolicyTranscodeHlsColdStart === undefined || ctx.forcePolicyTranscodeHlsColdStart === null))
        ctx.forcePolicyTranscodeHlsColdStart = false
    if (ctx.forcePolicyTranscodeAllowAudioCopy === undefined || ctx.forcePolicyTranscodeAllowAudioCopy === null)
        ctx.forcePolicyTranscodeAllowAudioCopy = true
    return rate
}

function normalizePlayerPlaybackSpeed(rate) {
    var value = Number(rate);
    if (!(value > 0)) value = 1.0;
    value = Math.round(value * 4.0) / 4.0;
    return value < 0.25 ? 0.25 : (value > 2.0 ? 2.0 : value);
}

function _mediaPlayerPlaybackRate(mediaPlayer) {
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

    var current = _mediaPlayerPlaybackRate(mediaPlayer);
    if (Math.abs(current - wanted) <= 0.001) {
        retryTimer.stop();
        root._playbackRateSyncAttempts = 0;
        return true;
    }

    try { mediaPlayer.playbackRate = wanted; } catch (e0) {}
    current = _mediaPlayerPlaybackRate(mediaPlayer);
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

function _audioCodecForStream(root, streamIndex) {
    var map = root.audioStreamIndexMap || [];
    var codecs = root.audioCodecMap || [];
    for (var i = 0; i < map.length; i++) {
        if (map[i] === streamIndex) return String(codecs[i] || "").toLowerCase();
    }
    return "";
}
function _isDtsAudioCodec(codec) {
    var c = String(codec || "").toLowerCase();
    return c === "dts" || c === "dca" || c === "dts,dca" || c === "a_dts";
}
function _isTrueHdAudioCodec(codec) {
    var c = String(codec || "").toLowerCase();
    return c === "truehd" || c === "mlp" || c === "mlp_fba" || c === "a_truehd" ||
           c === "dolby_truehd" || c === "true-hd" || c === "true_hd";
}
function _fullTranscodeAudioNeedsAc3(codec) {
    return _isDtsAudioCodec(codec) || _isTrueHdAudioCodec(codec);
}
function _preferredAutomaticAudioStream(root) {
    if (root.bestFrenchAudioStreamIndex >= 0) return root.bestFrenchAudioStreamIndex;
    if (root.firstAudioStreamIndex >= 0) return root.firstAudioStreamIndex;
    return -1;
}
function _streamsReadyForCurrent(root) {
    if (!root || !root.itemId) return false;
    var key = (root.serverUrl || "") + "|" + (root.itemId || "");
    return root._streamsReadyKey === key;
}
function _shouldForceInitialServerRemux(root) {
    if (!root || PlaybackRouter.normalizePlaybackRuleMode(root.playbackRuleMode) === "directplay") return false;
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
function _fetchResumeMs(root, bridge, cb) {
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
function _startFreshDirectPlayPlayback(root, start) {
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
function _startResolvedMainPlayback(root, start, remux, exactStart) {
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
    var preferredAudio = _preferredAutomaticAudioStream(root);
    var preferredAudioCodec = _audioCodecForStream(root, preferredAudio);
    var incompatibleLosslessOrDtsToAc3 = fullTranscode && _fullTranscodeAudioNeedsAc3(preferredAudioCodec);
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
function _negotiateServerPreroll(root, router, introItemId, onSuccess, onError) {
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
            _startFreshDirectPlayPlayback(root, directPlayStart);
            return;
        }
        var pendingSource = pending ? String(pending.source || "") : ""
        var explicit = !!(pending
            && (pendingSource === "chapter" || pendingSource === "restart" || pendingSource === "remote")
            && String(pending.itemId || "") === String(item)
            && String(pending.serverUrl || "") === String(server)
            && String(pending.userId || "") === String(user)
            && Number(pending.startMs) >= 0
            && (Date.now() - Number(pending.ts || 0)) < 30000)
        if (explicit) {
            var explicitStart = Math.max(0, Math.floor(Number(pending.startMs)))
            try { root.shared.__redefinExplicitPlaybackStart = null } catch(e1) {}
            if (pendingSource === "restart") {
                var restartRemux = _shouldForceInitialServerRemux(root)
                if (typeof root._resetServerPrerollState === "function")
                    root._resetServerPrerollState("restart-from-beginning")
                // Un vrai « Lire depuis le début » reproduit un lancement neuf :
                // position Jellyfin ignorée, mais pré-roll/intro de première lecture
                // conservé s'il est disponible.
                if (typeof root._tryStartServerPreroll === "function" &&
                        root._tryStartServerPreroll(0, restartRemux, 0)) return
                _startResolvedMainPlayback(root, 0, restartRemux, true)
                return
            }
            if (pendingSource === "remote") {
                var remoteRemux = _shouldForceInitialServerRemux(root)
                if (typeof root._resetServerPrerollState === "function")
                    root._resetServerPrerollState("remote-start")
                // Un Play distant à 0 conserve le pré-roll Jellyfin habituel.
                // Une reprise distante (>0) vise exactement la position demandée.
                if (explicitStart <= 0 &&
                        typeof root._tryStartServerPreroll === "function" &&
                        root._tryStartServerPreroll(0, remoteRemux, 0)) return
                _startResolvedMainPlayback(root, explicitStart, remoteRemux, true)
                return
            }
            if (typeof root._resetServerPrerollState === "function")
                root._resetServerPrerollState("chapter-start")
            _startResolvedMainPlayback(root, explicitStart, _shouldForceInitialServerRemux(root), true)
            return
        }
        // Playlist série explicitement lancée depuis DetailSeriePage :
        // ne jamais consulter la reprise Jellyfin. Le choix utilisateur est
        // "Tout lire depuis le début" / "Lecture aléatoire", donc chaque
        // épisode de cette session doit partir de 0. On conserve néanmoins
        // le pré-roll Jellyfin/Intros des premières lectures.
        if (root.forcePlaylistStartAtZero === true) {
            var zeroRemux = _shouldForceInitialServerRemux(root)
            if (typeof root._tryStartServerPreroll === "function" &&
                    root._tryStartServerPreroll(0, zeroRemux, 0)) return
            _startResolvedMainPlayback(root, 0, zeroRemux, true)
            return
        }
        _fetchResumeMs(root, bridge, function(ms, resumeResolved) {
            if (seq !== root._initialPlaybackSeq || item !== root.itemId ||
                    server !== root.serverUrl || user !== root.userId || token !== root.accessToken) return
            var rawResumeMs = Math.max(0, Math.floor(Number(ms || 0)))
            var duration = root.durationMs()
            var start = duration > 0 && rawResumeMs / duration >= 0.97 ? 0 : rawResumeMs
            var remux = _shouldForceInitialServerRemux(root)
            // Local Intros est un pré-roll de première lecture uniquement.
            // Si Jellyfin possède déjà une position de reprise, on démarre directement
            // le média principal. En cas d'échec de lecture de UserData, on n'affiche
            // pas non plus l'intro afin d'éviter un faux pré-roll sur un média repris.
            if (resumeResolved === true && rawResumeMs <= 0 &&
                    typeof root._tryStartServerPreroll === "function" &&
                    root._tryStartServerPreroll(start, remux, rawResumeMs)) return
            _startResolvedMainPlayback(root, start, remux)
        })
    })
}

/* ================== PlayerOverlay: pré-roll Jellyfin / Local Intros ================== */



function _timers(root) {
    try { return root && root._playbackTimers ? (root._playbackTimers() || {}) : {}; }
    catch (e) { return {}; }
}

function _stopTimer(timer) {
    try { if (timer && timer.stop) timer.stop(); } catch (e) {}
}

function _serverPrerollMethodForResult(res) {
    if (res && (res.isHls || res.lastUsedTranscoding)) return "Transcode";
    if (res && (res.lastUsedDirectStream || res.lastUsedServerRemux ||
                res.serverTimedStream || res.timeShifted)) return "DirectStream";
    return "DirectPlay";
}

function _stopServerPrerollSession(root, mediaPlayer, bridge, reason) {
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
        _stopServerPrerollSession(root, mediaPlayer, bridge, reason || "reset");
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
    var timers = _timers(root);
    root.controlsVisible = false;
    root.audioMenuVisible = false;
    root.subMenuVisible = false;
    root.scrubActive = false;
    root.scrubAccumUiMs = -1;
    root._scrubCommitTargetUiMs = -1;
    _stopTimer(timers.controls);
    _stopTimer(timers.scrubCommit);
    root._cancelCoalescedLocalSeek();
    _stopTimer(timers.resumeCheckpoint);
    _stopTimer(timers.seekRestore);
    _stopTimer(timers.frozenWatch);
    root._stopFrozenPlaybackWatch("server-preroll");
    root.disableLocalSubsOverlay();
}

function _startMainAfterServerPreroll(root, reason) {
    if (root._serverPrerollMainStarted) return;
    root._serverPrerollMainStarted = true;
    root.serverPrerollActive = false;
    root._serverPrerollState = 3;
    root._armVideoLoading("server-preroll-main-switch");
    _startResolvedMainPlayback(root, root._serverPrerollMainStartMs,
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
    _negotiateServerPreroll(root, PlaybackRouter,
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
    var timers = _timers(root);
    root._serverPrerollForItemId = expectedItem;
    root._serverPrerollServerUrl = expectedServer;
    root._serverPrerollState = 1;
    _prepareServerPrerollUi(root);
    root._armVideoLoading("server-preroll-resolve");
    root._cancelHardSourceReset("server-preroll-resolve");
    root._cancelStartupPlay("server-preroll-resolve");
    _stopTimer(timers.audioGate);
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
    var timers = _timers(root);
    root._serverPrerollState = 3;
    _stopServerPrerollSession(root, mediaPlayer, bridge, reason || "intro-finished");
    root.serverPrerollActive = false;
    root._cancelStartupPlay("server-preroll-finished");
    _stopTimer(timers.audioGate);
    _stopTimer(timers.seekRestore);
    _stopTimer(timers.resumeCheckpoint);
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
    var timers = _timers(root);
    root._serverPrerollSeq++;
    root._initialPlaybackSeq++;
    root._negotiationSeq++;
    if (root.serverPrerollActive)
        _stopServerPrerollSession(root, mediaPlayer, bridge, reason || "exit");
    root.serverPrerollActive = false;
    root._serverPrerollState = 4;
    root._serverPrerollMainStarted = true;
    root._cancelStartupPlay("server-preroll-exit");
    _stopTimer(timers.audioGate);
    _stopTimer(timers.seekRestore);
    _stopTimer(timers.resumeCheckpoint);
    root._gateArmed = false;
    root._resumeAfterGate = false;
    root._startupPlayWanted = false;
    root.playSessionId = "";
    root.currentMediaSourceId = "";
}

function applyOriginalDirectPlayQuality(root, mediaPlayer) {
    if (!root || !mediaPlayer || root._tearingDownPlayer) return false;
    var fromServerPipeline = root.lastUsedTranscoding === true ||
        root.lastUsedDirectStream === true || root.lastUsedServerRemux === true ||
        root.serverTimedStream === true || root.timeShifted === true ||
        Number(root.baseOffsetMs || 0) > 0;
    if (fromServerPipeline && root.shared && typeof root.requestDirectPlayReload === "function") {
        var freshTarget = root._clampUi(root.uiPositionMs());
        try {
            root.shared.__redefinExplicitPlaybackStart = {
                source: "directplay-reload",
                itemId: String(root.itemId || ""),
                serverUrl: String(root.serverUrl || ""),
                userId: String(root.userId || ""),
                startMs: Math.max(0, Math.floor(Number(freshTarget || 0))),
                ts: Date.now()
            };
            root._internalDirectPlayReload = true;
            root.requestDirectPlayReload();
            return true;
        } catch(eReload) {
            root._internalDirectPlayReload = false;
        }
    }
    var target = root._beginTrackSwitchRebase("quality-directplay", true);
    root.audioIndex = 0;
    root._autoLocalizeSubStream = -1;
    if (root.selectedSubtitleStream >= 0) {
        var li = root.listIndexForStream(root.selectedSubtitleStream);
        if (li >= 0 && li < root.subtitleIsTextMap.length && root.subtitleIsTextMap[li])
            root._autoLocalizeSubStream = root.selectedSubtitleStream;
    }
    root.selectedAudioStream = -1;
    root.selectedSubtitleStream = -1;
    root.effectiveAudioStream = -1;
    root.effectiveSubtitleStream = -1;
    root.manualDirectPlayMode = true;
    root.manualRemuxMode = false;
    root.manualQualityBitrate = 0;
    root.disableLocalSubsOverlay();
    root.audioMenuVisible = false;
    root.lastUsedDirectStream = false;
    root.lastUsedTranscoding = false;
    root.lastUsedServerRemux = false;
    root.serverTimedStream = false;
    root.timeShifted = false;
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
        disableDefaultSubtitleRemux: true,
        disableDefaultFrenchAudioOrderRemux: true,
        disableImageSubtitleRiskRemux: true,
        disableHevcMain10MkvRemux: true,
        trackSwitchRebase: true,
        trackSwitchUseZeroStart: true,
        forceInitialLocalSeekMs: target
    });
    // Conserve le contrat historique du helper : le choix a été pris en charge
    // dès que la renégociation a été déclenchée.
    return true;
}

function applyManualBitrateQuality(root, mediaPlayer, bitrate) {
    if (!root || !mediaPlayer || typeof root.negotiatePlayback !== "function" || root._tearingDownPlayer)
        return false;
    var raw = Math.floor(_numberOr(bitrate, 0));
    if (!(raw > 0) || !root.serverUrl || !root.accessToken || !root.userId || !root.itemId)
        return false;
    var rate = Math.max(420000, Math.min(200000000, raw));
    if (root.manualQualityBitrate === rate && root.currentPlaybackVideoTranscodeByPolicy === true &&
            root.manualDirectPlayMode !== true && root.manualRemuxMode !== true)
        return true;
    var previous = Math.max(0, Math.floor(_numberOr(root.manualQualityBitrate, 0)));
    var previousRemux = root.manualRemuxMode === true;
    var previousDirectPlay = root.manualDirectPlayMode === true;
    var target = _qualityTargetUi(root);
    var resume = mediaPlayer.playbackState === root._mpPlayingState ||
                 root._forceResumeAfterDeferredReload === true;
    root._wasPlayingBeforeSwitch = resume;
    root._resumeWantedAfterNegotiation = resume;
    root.lastUiTargetMs = target;
    root.manualDirectPlayMode = false;
    root.manualRemuxMode = false;
    root.manualQualityBitrate = rate;
    try { if (resume) mediaPlayer.pause(); } catch(e0) {}
    var keepHls = root.isHls === true && root.lastUsedTranscoding === true;
    return root.negotiatePlayback(target, keepHls, true, false, false, {
        manualQualityRequest: true,
        manualQualityBitrate: rate,
        previousManualQualityBitrate: previous,
        previousManualRemuxMode: previousRemux,
        previousManualDirectPlayMode: previousDirectPlay,
        forceRetry: true,
        forceAllowTranscoding: true,
        forceVideoTranscodeCodec: "h264",
        forcePlaybackInfoVideoCodec: "h264",
        forceDirectPlayInPlaybackInfo: false,
        forceDirectStreamInPlaybackInfo: false,
        forceVideoStreamCopyInPlaybackInfo: false,
        forceServerSeek: target > 0,
        forcePolicyTranscodeVideoBitrate: rate,
        forcePolicyTranscodeHls: keepHls ? true : undefined,
        forcePolicyTranscodeHlsColdStart: (target > 0 || keepHls) ? false : undefined,
        forcePolicyTranscodeAllowAudioCopy: true
    }) !== false;
}

function _prepareQualityServerSubtitle(root, forceServerMode) {
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
    // _forceResumeAfterDeferredReload : le choix a été fait en pause et son
    // rejeu est déclenché par la reprise, avant tout mp.play().
    var resume = mediaPlayer.playbackState === root._mpPlayingState ||
                 root._forceResumeAfterDeferredReload === true;
    root._wasPlayingBeforeSwitch = resume;
    root._resumeWantedAfterNegotiation = resume;
    root.lastUiTargetMs = target;
    root.manualQualityBitrate = 0;
    root.manualDirectPlayMode = false;
    root.manualRemuxMode = true;
    _prepareQualityServerSubtitle(root, true);
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
    var resume = mediaPlayer.playbackState === root._mpPlayingState ||
                 root._forceResumeAfterDeferredReload === true;
    root._wasPlayingBeforeSwitch = resume;
    root._resumeWantedAfterNegotiation = resume;
    root.lastUiTargetMs = target;
    root.manualQualityBitrate = 0;
    root.manualDirectPlayMode = false;
    root.manualRemuxMode = false;

    var dvdRemux = root.isDvdSource === true;
    var hardTranscode = (!dvdRemux && root.hasInternalDvdSubtitle === true) ||
                        root.requiresInterlacedTsTranscode === true;
    var autoRemux = _shouldForceInitialServerRemux(root) || dvdRemux;
    _prepareQualityServerSubtitle(root, hardTranscode || autoRemux);
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

function _playerPersistableDurationMs(root, mediaPlayer) {
    var full = root.runtimeTicks > 0 ? Math.floor(Number(root.runtimeTicks) / 10000) : 0;
    return full > 0 ? full : playerDurationMs(root, mediaPlayer);
}

function _clampPlayerPersistableUi(root, mediaPlayer, position) {
    var value = Math.max(0, Math.floor(Number(position || 0)));
    var duration = _playerPersistableDurationMs(root, mediaPlayer);
    return duration > 0 ? Math.min(value, duration) : value;
}

function rememberPlayerPersistablePosition(root, mediaPlayer, position, reason) {
    var value = _clampPlayerPersistableUi(root, mediaPlayer, position);
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

    position = _clampPlayerPersistableUi(root, mediaPlayer, position);
    if (position <= 250 && root._lastPersistableUiMs > 1000 &&
            (mediaPlayer.playbackState === root._mpStoppedState || root._tearingDownPlayer))
        position = root._lastPersistableUiMs;
    return position;
}

function _qualityHasCurrentSource(root, mediaPlayer) {
    if (!root || root.serverPrerollBlocking) return false;
    try {
        return String(root.mediaUrl || "").length > 0 || String(mediaPlayer.source || "").length > 0;
    } catch (e0) {}
    return false;
}

function qualityOriginalDirectPlaySelected(root, mediaPlayer) {
    if (root.manualQualityBitrate > 0 || root.manualRemuxMode) return false;
    if (!_qualityHasCurrentSource(root, mediaPlayer)) return false;
    // Le panneau Qualité décrit le pipeline réellement obtenu, pas uniquement
    // l'intention manuelle qui a précédé la dernière négociation.
    return !root.isHls && !root.lastUsedTranscoding && !root.lastUsedDirectStream &&
           !root.lastUsedServerRemux && !root.serverTimedStream && !root.timeShifted;
}

function qualityRemuxSelected(root, mediaPlayer) {
    if (root.manualQualityBitrate > 0) return false;
    if (root.manualRemuxMode) return true;
    if (root.lastUsedTranscoding || root.isHls) return false;
    if (!_qualityHasCurrentSource(root, mediaPlayer)) return false;
    return root.lastUsedServerRemux === true && root.lastUsedDirectStream !== true;
}

function qualityAutomaticServerSelected(root, mediaPlayer) {
    if (root.manualQualityBitrate > 0) return false;
    if (!_qualityHasCurrentSource(root, mediaPlayer)) return false;
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

/* ================== Méthode effective et playlist ================== */

function _playMethod(root) {
    if (root.isHls || root.lastUsedTranscoding) return "Transcode";
    if (root.lastUsedDirectStream || root.lastUsedServerRemux || root.serverTimedStream || root.timeShifted) return "DirectStream";
    return "DirectPlay";
}
/* ===== Playlist épisode : orchestration device-neutral ===== */
function playlistHasContent(playlist) {
    return !!(playlist && playlist.hasList && playlist.hasList());
}

function clearPlaylist(root) {
    var playlist = root && root.playlistRef;
    if (!root || !root.clearPlaylistOnExit || !playlist) return false;
    playlist.resetAll();
    return true;
}

function syncPlaylistToCurrent(root) {
    var playlist = root && root.playlistRef;
    if (!playlist) return -1;
    playlist.syncTo(root.itemId);
    return playlist.index;
}

function _fetchSeriesEpisodesForPlaylist(root, bridge, seriesId, onOk, onErr) {
    if (!root || !bridge || typeof bridge.fetchSeriesEpisodesItems !== "function" ||
            !root.serverUrl || !root.accessToken || !root.userId || !seriesId) {
        if (onErr) onErr("missing_context");
        return null;
    }
    return bridge.fetchSeriesEpisodesItems(
        root.serverUrl, root.accessToken, root.userId, seriesId,
        function(items) { if (onOk) onOk(items || []); },
        function(err) { if (onErr) onErr(err); }
    );
}

function _fetchSeasonEpisodesForPlaylist(root, bridge, seasonId, onOk, onErr) {
    if (!root || !bridge || typeof bridge.fetchEpisodes !== "function" ||
            !root.serverUrl || !root.accessToken || !root.userId || !seasonId) {
        if (onErr) onErr("missing_context");
        return null;
    }
    return bridge.fetchEpisodes(
        root.serverUrl, root.accessToken, root.userId, seasonId,
        function(items) { if (onOk) onOk(items || []); },
        function(err) { if (onErr) onErr(err); }
    );
}

function _applySeasonPlaylistIds(root, ids, title, scope) {
    ids = SeasonUtils.normalizeIdList(ids || []);
    var playlist = root && root.playlistRef;
    if (!ids.length || !playlist) return false;

    playlist.replaceScopedList(
        ids,
        title || playlist.title || "",
        "playeroverlay",
        scope || "season:unknown"
    );

    var index = syncPlaylistToCurrent(root);
    if (index < 0) playlist.start();
    return true;
}

function ensureSeasonPlaylistFromHints(root, bridge) {
    try {
        if (!root || playlistHasContent(root.playlistRef) || !root.playlistRef) return false;
        var seasonId = root.selectedSeasonId;
        var hints = root.seasonPageOrderIds || [];
        if (!seasonId && !hints.length) return false;

        if (hints.length) {
            var hintIds = SeasonUtils.normalizeIdList(hints);
            if (!hintIds.length) return false;
            if (!seasonId)
                return _applySeasonPlaylistIds(root, hintIds, root.playerPlaylistTitle || root.playlistRef.title || "", "season:unknown");

            _fetchSeasonEpisodesForPlaylist(root, bridge, seasonId, function(items) {
                if (!items || !items.length) {
                    _applySeasonPlaylistIds(root, hintIds, root.playerPlaylistTitle || root.playlistRef.title || "", "season:" + seasonId);
                    return;
                }
                SeasonUtils.sortEpisodesInPlace(items);
                var ids = SeasonUtils.episodeIdListFromItems(items, hintIds);
                _applySeasonPlaylistIds(root, ids.length ? ids : hintIds, root.playerPlaylistTitle || root.playlistRef.title || "", "season:" + seasonId);
            }, function() {
                _applySeasonPlaylistIds(root, hintIds, root.playerPlaylistTitle || root.playlistRef.title || "", "season:" + seasonId);
            });
            return true;
        }

        _fetchSeasonEpisodesForPlaylist(root, bridge, seasonId, function(items) {
            if (!items || !items.length) return;
            SeasonUtils.sortEpisodesInPlace(items);
            var ids = SeasonUtils.episodeIdListFromItems(items, null);
            if (ids.length)
                _applySeasonPlaylistIds(root, ids, root.playerPlaylistTitle || root.playlistRef.title || "", "season:" + seasonId);
        }, function() {});
        return true;
    } catch (e) {}
    return false;
}

function ensureAutoEpisodePlaylist(root, bridge) {
    if (!root || !root.serverUrl || !root.accessToken) return false;
    if (root.selectedSeasonId || (root.seasonPageOrderIds && root.seasonPageOrderIds.length))
        return ensureSeasonPlaylistFromHints(root, bridge);
    if (!root.itemId || !bridge || typeof bridge.fetchItem !== "function") return false;
    bridge.fetchItem(root.serverUrl, root.accessToken, root.itemId, function(item) {
        ensureAutoEpisodePlaylistWithItem(root, bridge, item);
    }, function() {}, root.fbx);
    return true;
}

function ensureAutoEpisodePlaylistWithItem(root, bridge, item) {
    try {
        if (!root || !item || playlistHasContent(root.playlistRef)) return false;
        if (root.selectedSeasonId || (root.seasonPageOrderIds && root.seasonPageOrderIds.length))
            return ensureSeasonPlaylistFromHints(root, bridge);

        var type = _s(item.Type);
        var seasonId = "";
        var seasonNo = 0;
        if (type === "Episode") {
            seasonId = item.SeasonId || (item.Season && item.Season.Id) || "";
            seasonNo = item.ParentIndexNumber != null ? item.ParentIndexNumber : 0;
        } else if (type === "Season") {
            seasonId = item.Id || "";
            seasonNo = item.IndexNumber != null ? item.IndexNumber : 0;
        } else {
            return false;
        }

        var seriesId = item.SeriesId || (item.Series && item.Series.Id) || "";
        var seriesName = item.SeriesName || (item.Series && item.Series.Name) || "";
        var title = (seasonNo === 0 ? "Spéciaux" : "Saison " + seasonNo)
                + (seriesName ? " • " + seriesName : "");

        if (seasonId) {
            _fetchSeasonEpisodesForPlaylist(root, bridge, seasonId, function(items) {
                if (!items || !items.length) return;
                SeasonUtils.sortEpisodesInPlace(items);
                var ids = SeasonUtils.episodeIdListFromItems(items, null);
                if (ids.length) _applySeasonPlaylistIds(root, ids, title, "season:" + seasonId);
            }, function() {});
            return true;
        }

        _fetchSeriesEpisodesForPlaylist(root, bridge, seriesId, function(items) {
            var bucket = [];
            for (var i = 0; items && i < items.length; ++i) {
                if (items[i] && (items[i].ParentIndexNumber != null ? items[i].ParentIndexNumber : 0) === seasonNo)
                    bucket.push(items[i]);
            }
            SeasonUtils.sortEpisodesInPlace(bucket);
            var ids = SeasonUtils.episodeIdListFromItems(bucket, null);
            if (ids.length) _applySeasonPlaylistIds(root, ids, title, "unknown-season:" + seriesId);
        }, function() {});
        return true;
    } catch (e) {}
    return false;
}

/* ================== Reporting Jellyfin ================== */

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
    p = _clampPlayerPersistableUi(root, null, p);
    return {
        ItemId: root.itemId,
        MediaSourceId: root.currentMediaSourceId || "",
        PlaySessionId: root.playSessionId,
        CanSeek: true,
        IsPaused: !!paused,
        PositionTicks: root._ticks(p),
        PlayMethod: _playMethod(root),
        AudioStreamIndex: root.selectedAudioStream >= 0
                        ? root.selectedAudioStream
                        : (root.effectiveAudioStream >= 0
                           ? root.effectiveAudioStream : null),
        SubtitleStreamIndex: (root.useLocalSubs === true
                              && root.localSubStreamIndex >= 0)
                           ? root.localSubStreamIndex
                           : (root.selectedSubtitleStream >= 0
                              ? root.selectedSubtitleStream
                              : (root.effectiveSubtitleStream >= 0
                                 ? root.effectiveSubtitleStream : null)),
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

/* ================== Cycle de vie : resets et destruction ================== */

// Ordre des écritures conservé : les bindings QML peuvent réagir à chaque étape.
function resetPlaybackState(root, resetScrub) {
    var timers = _timers(root);
    root.baseOffsetMs = 0
    root._setPendingSeekMs(-1, "reset-common-runtime")
    root._pendingHardResetBaseMs = -1
    root.lastUiTargetMs = 0
    if (resetScrub === true) {
        root.scrubActive = false
        root.scrubAccumUiMs = -1
        root._scrubCommitTargetUiMs = -1
    }
    root._pauseWatchStartedWallMs = 0
    root._pauseWatchStartedUiMs = 0
    root._pauseWatchLastStableUiMs = 0
    root._pauseWatchLastStableWallMs = 0
    root._pauseWatchInPause = false
    root._mediaErrorRecoveryInProgress = false
    root._mediaErrorRecoverySafeUiMs = 0
    root._mediaErrorProgressGuardUntilWallMs = 0
    root._mediaErrorRecoveryReason = ""
    root._frozenPlaybackWatchActive = false
    root._frozenPlaybackNoProgressSinceWallMs = 0
    root._frozenPlaybackRecoveryCount = 0
    root._frozenPlaybackLastLocalMs = -1
    root._frozenPlaybackLastUiMs = -1
    try { timers.frozenWatch.stop() } catch(eFrozenWatch) {}
    root.lastUsedServerRemux = false
    root.serverTimedStream = false
    root.timeShifted = false
    root.currentPlaybackVideoTranscodeByPolicy = false
    root._trackSwitchVerificationActive = false
    root._trackSwitchTimebaseVerified = false
    root._trackSwitchRequestedUiMs = 0
    root._trackSwitchLocalStrategy = 1
    root._seekRestoreLastCallWallMs = 0
    root._seekRestoreAwaitingResult = false
    root._seekRestoreStableSamples = 0
    root._seekRestoreBestDiffMs = 2147483647
    root._seekRestoreBestLocalMs = -1
    root._seekRestoreAccepted = false
    root._seekRestoreReadyWallMs = 0
    root._seekRestorePrimeWallMs = 0
    root._seekRestorePhase = 0
    root._trackSwitchSourceHevc10 = false
    root._trackSwitchSourceVideoCodec = ""
    root._trackSwitchSourceContainer = ""
    root._directPlayOpenFallbackUsed = false
    root._directPlayOpenStartedWallMs = 0
    root._staticDirectPlaySeekUnsafe = false
    root._staticDirectPlaySeekUnsafeItemId = ""
    root._staticDirectPlaySeekFallbackInProgress = false
    root._staticDirectPlayFallbackAwaitingStableRemux = false
    root._staticDirectPlayFallbackTargetMs = -1
    root._staticDirectPlayFallbackStartedWallMs = 0
    root._startedReported = false
    root._reportedSessionId = ""
    root._stoppedReportedSessionId = ""
    root._stoppedPendingSessionId = ""
    root._lastProgressSentMs = 0
    root._lastUserDataSentMs = 0
    root._playbackExitInProgress = false
    root._finalExitPositionMs = -1
    root._lastPersistableUiMs = 0
}

function _stopRunningTimer(timer) {
    try { if (timer && timer.running) timer.stop(); } catch(e) {}
}

// La position finale est capturée avant mp.stop() et l’URL vide.
function cleanupMediaPlayer(root, mediaPlayer, bridge) {
    var timers = _timers(root);
    var wasServerPreroll = root.serverPrerollBlocking
    if (wasServerPreroll)
        abortServerPrerollForExit(root, mediaPlayer, bridge, "destruction")
    if (root._finalExitPositionMs < 0)
        root._finalExitPositionMs = wasServerPreroll ? 0 : root._capturePersistablePositionMs("destruction")
    try { root._sendStopped() } catch(eStop) {}
    root._tearingDownPlayer = true
    _stopRunningTimer(timers.nextRearm)
    _stopRunningTimer(timers.topBarApply)
    _stopRunningTimer(timers.progress)
    _stopRunningTimer(timers.resumeCheckpoint)
    _stopRunningTimer(timers.controls)
    _stopRunningTimer(timers.startup)
    _stopRunningTimer(timers.sourceReset)
    _stopRunningTimer(timers.audioGate)
    _stopRunningTimer(timers.seekRestore)
    _stopRunningTimer(timers.scrubCommit)
    _stopRunningTimer(timers.coalescedLocalSeek)
    _stopRunningTimer(timers.mediaGuard)
    _stopRunningTimer(timers.pauseResumeProbe)
    _stopRunningTimer(timers.trackSwitchFailureRestart)
    _stopRunningTimer(timers.trackSwitchVerifiedResume)
    _stopRunningTimer(timers.frozenWatch)
    _stopRunningTimer(timers.videoLoadingShow)
    _stopRunningTimer(timers.videoLoadingHide)
    _stopRunningTimer(timers.videoLoadingRelease)
    _stopRunningTimer(timers.speedPopupFadeOut)
    _stopRunningTimer(timers.speedPopupCleanup)
    _stopRunningTimer(timers.playbackRateSync)
    _stopRunningTimer(timers.nextHidden)
    try { root.disableLocalSubsOverlay() } catch(e0) {}
    try {
        if (mediaPlayer) {
            mediaPlayer.stop()
            mediaPlayer.source = ""
        }
    } catch(e1) {}
    root.mediaUrl = ""
    root._setPendingSeekMs(-1, "component-cleanup")
    root._pendingServerTimedBaseMs = -1
    root._sourceResetActive = false
    root._sourceResetPhase = 0
    root._sourceResetPendingUrl = ""
    root._sourceResetExpectedUiMs = -1
    root._sourceResetReadyWallMs = 0
    root._pendingHardResetBaseMs = -1
    root.scrubActive = false
    root.scrubAccumUiMs = -1
    root._scrubCommitTargetUiMs = -1
    root._coalescedLocalSeekTargetUiMs = -1
    root._coalescedLocalSeekDirection = 0
    root._startupPlayWanted = false
    root._directPlayOpenFallbackUsed = false
    root._directPlayOpenStartedWallMs = 0
    root._gateArmed = false
    root._resumeAfterGate = false
    root._deferredReloadReplaying = false
    root._forceResumeAfterDeferredReload = false
    root._coalescedNegotiationActive = false
    root._coalescedNegotiationCall = null
    root._resetDeferredReload("destruction")
    root._mediaErrorRecoveryArmed = false
    root._mediaErrorRecoveryInProgress = false
    root._frozenPlaybackWatchActive = false
    root._pauseWatchInPause = false
    root.videoLoadingGate = false
    root.videoLoadingVisible = false
}
