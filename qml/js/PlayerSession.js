.pragma library
.import "JellyfinPlaybackRouter.js" as PlaybackRouter
.import "SeasonUtils.js" as SeasonUtils
.import "PlayerTrackSelection.js" as TrackSelection

// Orchestre le cycle média : démarrage/pré-roll, seek, récupération,
// playlist, horloges et reporting ; aucune politique matérielle de codecs.
// Consommateurs : playeroverlay.qml et playerOverlayHelper.js.
// L’état appartient à root ; le MediaPlayer et le bridge sont injectés.
// Les fonctions préfixées par _ sont internes ; les pages utilisent les
// opérations de session, de seek, d’horloge et de reporting uniquement.
// Les générations, positions figées et séquences Stopped -> UserData sont
// conservées afin de protéger les transitions asynchrones et la reprise.

function _s(v) {
    return (v === undefined || v === null) ? "" : String(v)
}

function _numberOr(value, fallback) {
    var n = Number(value)
    return isFinite(n) ? n : fallback
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

    try {
        mediaPlayer.playbackRate = wanted;
    } catch (e0) {}
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

function _fetchResumeMs(root, bridge, cb) {
    if (!root || !bridge || typeof bridge.fetchUserItem !== "function" ||
        !root.serverUrl || !root.accessToken || !root.userId || !root.itemId) {
        if (cb) cb(0, false);
        return null;
    }
    return bridge.fetchUserItem(root.serverUrl, root.accessToken, root.userId, root.itemId,
        function(item) {
            var ticks = item && item.UserData && typeof item.UserData.PlaybackPositionTicks === "number" ?
                item.UserData.PlaybackPositionTicks : 0;
            if (cb) cb(ticks > 0 ? Math.floor(ticks / 10000) : 0, true);
        },
        function() {
            if (cb) cb(0, false);
        }
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
    var expectedMain = _s(root.itemId),
        expectedServer = _s(root.serverUrl),
        expectedUser = _s(root.userId),
        expectedToken = _s(root.accessToken);
    var ctx = {
        serverUrl: expectedServer,
        accessToken: expectedToken,
        userId: expectedUser,
        itemId: introItemId,
        selectedAudioStream: -1,
        selectedSubtitleStream: -1,
        useLocalSubs: false,
        selectedSubtitleIsText: false,
        startMs: 0,
        forceHls: false,
        forceMp4: false,
        preferTicks: false,
        forceDPOnAudioSwitch: false,
        preferFrenchAudio: false,
        disableAutoFrenchAudio: true,
        disableAutoVoFrenchFullSubtitle: true,
        disableDefaultSubtitleRemux: true,
        disableDefaultFrenchAudioOrderRemux: true,
        disableImageSubtitleRiskRemux: true
    };
    router.negotiatePlayback(ctx, function(res) {
        if (expectedMain !== _s(root.itemId) || expectedServer !== _s(root.serverUrl) ||
            expectedUser !== _s(root.userId) || expectedToken !== _s(root.accessToken)) return;
        if (!res || !res.url) {
            if (onError) onError("invalid_playback_url");
            return;
        }
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
            pending = root.shared && root.shared.__redefinExplicitPlaybackStart ?
                root.shared.__redefinExplicitPlaybackStart :
                null
        } catch (e0) {}
        var directPlayReload = !!(pending &&
            String(pending.source || "") === "directplay-reload" &&
            String(pending.itemId || "") === String(item) &&
            String(pending.serverUrl || "") === String(server) &&
            String(pending.userId || "") === String(user) &&
            Number(pending.startMs) >= 0 &&
            (Date.now() - Number(pending.ts || 0)) < 30000);
        if (directPlayReload) {
            var directPlayStart = Math.max(0, Math.floor(Number(pending.startMs)));
            try {
                root.shared.__redefinExplicitPlaybackStart = null;
            } catch (eDirectClear) {}
            if (typeof root._resetServerPrerollState === "function")
                root._resetServerPrerollState("directplay-reload");
            _startFreshDirectPlayPlayback(root, directPlayStart);
            return;
        }
        var pendingSource = pending ? String(pending.source || "") : ""
        var explicit = !!(pending &&
            (pendingSource === "chapter" || pendingSource === "restart" || pendingSource === "remote") &&
            String(pending.itemId || "") === String(item) &&
            String(pending.serverUrl || "") === String(server) &&
            String(pending.userId || "") === String(user) &&
            Number(pending.startMs) >= 0 &&
            (Date.now() - Number(pending.ts || 0)) < 30000)
        if (explicit) {
            var explicitStart = Math.max(0, Math.floor(Number(pending.startMs)))
            try {
                root.shared.__redefinExplicitPlaybackStart = null
            } catch (e1) {}
            if (pendingSource === "restart") {
                var restartRemux = TrackSelection.shouldForceInitialServerRemux(root)
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
                var remoteRemux = TrackSelection.shouldForceInitialServerRemux(root)
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
            _startResolvedMainPlayback(root, explicitStart, TrackSelection.shouldForceInitialServerRemux(root), true)
            return
        }
        // Playlist série explicitement lancée depuis DetailSeriePage :
        // ne jamais consulter la reprise Jellyfin. Le choix utilisateur est
        // "Tout lire depuis le début" / "Lecture aléatoire", donc chaque
        // épisode de cette session doit partir de 0. On conserve néanmoins
        // le pré-roll Jellyfin/Intros des premières lectures.
        if (root.forcePlaylistStartAtZero === true) {
            var zeroRemux = TrackSelection.shouldForceInitialServerRemux(root)
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
            var remux = TrackSelection.shouldForceInitialServerRemux(root)
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
    try {
        return root && root._playbackTimers ? (root._playbackTimers() || {}) : {};
    } catch (e) {
        return {};
    }
}

function _stopTimer(timer) {
    try {
        if (timer && timer.stop) timer.stop();
    } catch (e) {}
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
    }, function() {}, function() {});
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
    }, function() {}, function() {});
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
        root._serverPrerollItemId,
        function(res) {
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
        },
        function() {
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
    try {
        mediaPlayer.stop();
    } catch (e0) {}
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
            if (candidate && candidate !== expectedItem) {
                introId = candidate;
                break;
            }
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
    try {
        mediaPlayer.stop();
    } catch (e0) {}
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
    try {
        Qt.callLater(function() {
            root._focusControlsLater();
        });
    } catch (e0) {
        root._focusControlsLater();
    }
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
    try {
        position = root._reportUiPositionMs(reason || "persist", true);
    } catch (e0) {
        try {
            position = playerUiPositionMs(root, mediaPlayer);
        } catch (e1) {
            position = 0;
        }
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
        function(items) {
            if (onOk) onOk(items || []);
        },
        function(err) {
            if (onErr) onErr(err);
        }
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
        function(items) {
            if (onOk) onOk(items || []);
        },
        function(err) {
            if (onErr) onErr(err);
        }
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
        var title = (seasonNo === 0 ? "Spéciaux" : "Saison " + seasonNo) +
            (seriesName ? " • " + seriesName : "");

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
            p = root._pendingSeekMs >= 0 ?
                root._pendingSeekMs :
                root._reportUiPositionMs("session", !!paused);
        } catch (e0) {
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
        AudioStreamIndex: root.selectedAudioStream >= 0 ?
            root.selectedAudioStream :
            (root.effectiveAudioStream >= 0 ?
                root.effectiveAudioStream : null),
        SubtitleStreamIndex: (root.useLocalSubs === true &&
                root.localSubStreamIndex >= 0) ?
            root.localSubStreamIndex :
            (root.selectedSubtitleStream >= 0 ?
                root.selectedSubtitleStream :
                (root.effectiveSubtitleStream >= 0 ?
                    root.effectiveSubtitleStream : null)),
        RepeatMode: "RepeatNone"
    };
}

function sendStartIfNeeded(root, bridge, positionMs) {
    if (root && root.serverPrerollBlocking === true) return;
    if (!root.scrobbleEnabled || root._startedReported && root._reportedSessionId === root.playSessionId) return;
    if (!root.serverUrl || !root.accessToken || !root.userId || !root.itemId || !root.playSessionId) return;
    bridge.sessionsPlayingStart(root.serverUrl, root.accessToken, _sessionPayload(root, false, positionMs), function() {}, function() {});
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
        function() {
            if (typeof done === "function") done(true);
        },
        function() {
            if (typeof done === "function") done(false);
        });
    return true;
}

function _finishStoppedCallback(done, ok) {
    if (typeof done !== "function") return;
    try {
        done(ok === true);
    } catch (e) {}
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
        } catch (e0) {}
        _finishStoppedCallback(done, ok === true);
    }

    function sendUserDataRequest(retried, stoppedOk) {
        try {
            bridge.updateUserPlaybackPosition(serverUrl, accessToken, userId, itemId, ticks,
                function() {
                    finishAll(true);
                },
                function() {
                    if (retried !== true) sendUserDataRequest(true, stoppedOk);
                    else finishAll(stoppedOk === true);
                }
            );
        } catch (e0) {
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
        } catch (e0) {
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
    } catch (e0) {
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
    try {
        timers.frozenWatch.stop()
    } catch (eFrozenWatch) {}
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
    try {
        if (timer && timer.running) timer.stop();
    } catch (e) {}
}

// La position finale est capturée avant mp.stop() et l’URL vide.
function cleanupMediaPlayer(root, mediaPlayer, bridge) {
    var timers = _timers(root);
    var wasServerPreroll = root.serverPrerollBlocking
    if (wasServerPreroll)
        abortServerPrerollForExit(root, mediaPlayer, bridge, "destruction")
    if (root._finalExitPositionMs < 0)
        root._finalExitPositionMs = wasServerPreroll ? 0 : root._capturePersistablePositionMs("destruction")
    try {
        root._sendStopped()
    } catch (eStop) {}
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
    try {
        root.disableLocalSubsOverlay()
    } catch (e0) {}
    try {
        if (mediaPlayer) {
            mediaPlayer.stop()
            mediaPlayer.source = ""
        }
    } catch (e1) {}
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

// Temps de lecture, remplacement de source et récupération du backend média.
// Seuls les remplacements de source verrouillent le transport.
// L’ouverture initiale garde ses commandes disponibles.
var RELOAD_LOADING_REASONS = ["negotiation", "hard-source-reset",
    "fresh-directplay-reset", "media-url-swap"
];

function isReloadLoadingReason(reason) {
    var r = String(reason === undefined || reason === null ? "" : reason);
    for (var i = 0; i < RELOAD_LOADING_REASONS.length; ++i)
        if (RELOAD_LOADING_REASONS[i] === r) return true;
    return false;
}

function reloadBlocksTransport(root) {
    if (!root || root._tearingDownPlayer === true || root.serverPrerollBlocking === true)
        return false;
    if (root._sourceResetActive === true) return true;
    return root.videoLoadingGate === true && isReloadLoadingReason(root._videoLoadingReason);
}

function _poNowMs() {
    return Date.now ? Date.now() : (new Date()).getTime();
}

function resetSeekRestoreState(root, targetMs) {
    root._seekRestoreAttempts = 0;
    root._seekRestoreHlsFallbackTried = false;
    root._seekRestoreLastTargetMs = (targetMs !== undefined && targetMs !== null) ?
        Math.max(0, Math.floor(Number(targetMs || 0))) : -1;
    root._seekRestoreLastCallWallMs = 0;
    root._seekRestoreAwaitingResult = false;
    root._seekRestoreStableSamples = 0;
    root._seekRestoreBestDiffMs = 2147483647;
    root._seekRestoreBestLocalMs = -1;
    root._seekRestoreAccepted = false;
    root._seekRestoreReadyWallMs = 0;
    root._seekRestorePrimeWallMs = 0;
    root._seekRestorePauseWallMs = 0;
    root._seekRestorePhase = 0;
}

function resetSeekRestoreGuard(root, targetMs, reason) {
    resetSeekRestoreState(root, targetMs);
    if ((reason || "") === "boot-seek" && root._seekRestoreLastTargetMs > 0) root._armSkipIntroResumeGate(root._seekRestoreLastTargetMs, "boot-seek");
}

function beginTrackSwitchRebase(root, mp, forceLocalSeek) {
    var p = root._clampUi(root.uiPositionMs());
    root._trackSwitchRebaseActive = true;
    root._trackSwitchRebaseSeq++;
    root._trackSwitchAnchorUiMs = p;
    root._trackSwitchAnchorWallMs = _poNowMs();
    // Le rejeu d'un réglage différé est déclenché PAR la reprise : la lecture
    // n'a pas encore repris au moment où l'on capture l'état, mais la
    // négociation doit se terminer en lecture.
    root._trackSwitchWasPlaying = (mp.playbackState === root._mpPlayingState) ||
        root._forceResumeAfterDeferredReload === true;
    root._trackSwitchSettleTicks = 0;
    root._trackSwitchForceLocalSeek = (forceLocalSeek !== false);
    root._trackSwitchLocalSeekMs = p;
    root._trackSwitchRequestedUiMs = p;
    root._trackSwitchVerificationActive = root._trackSwitchForceLocalSeek && p > 0;
    root._trackSwitchTimebaseVerified = !root._trackSwitchVerificationActive;
    root._trackSwitchLocalStrategy = 1;
    root._trackSwitchSourceVideoCodec = "";
    root._trackSwitchSourceContainer = "";
    root._trackSwitchSourceHevc10 = false;
    resetSeekRestoreState(root, null);
    root._wasPlayingBeforeSwitch = root._trackSwitchWasPlaying;
    root._resumeWantedAfterNegotiation = root._trackSwitchWasPlaying;
    root.lastUiTargetMs = p;
    root._pendingSeekMs = -1;
    root.showScrubPreview(p);
    root._pushLocalSubsUiMs(p, true);
    if (root._trackSwitchWasPlaying) {
        try {
            mp.pause();
        } catch (e0) {}
    }
    return p;
}

function trackSwitchRebasedStartMs(root, fallbackMs) {
    var p = root._trackSwitchRebaseActive ? root._trackSwitchAnchorUiMs : Math.max(0, Math.floor(Number(fallbackMs || 0)));
    return root._clampUi(p);
}

function armTrackSwitchTimebaseSettle(root, timer) {
    if (!root._trackSwitchRebaseActive) return;
    root._trackSwitchSettleTicks = 0;
    root._lastUiClockPushWallMs = 0;
    root.updateClocksFromPlayback();
    timer.restart();
}

function trackSwitchFragileHevc(root) {
    var c = String(root._trackSwitchSourceVideoCodec || "").toLowerCase(),
        k = String(root._trackSwitchSourceContainer || "").toLowerCase();
    return !!(root._trackSwitchSourceHevc10 || ((c === "hevc" || c === "h265") && (k === "mkv" || k === "matroska")));
}

function seekRestoreAttemptLimit(root) {
    return trackSwitchFragileHevc(root) ? 1 : Math.max(1, root.trackSwitchSeekMaxAttempts);
}

function seekRestoreDeadlineMs(root) {
    return trackSwitchFragileHevc(root) ? root.trackSwitchSeekHevcMaxTotalMs : root.trackSwitchSeekMaxTotalMs;
}

function seekRestoreIsTrueTrackSwitch(root) {
    return !!(root._trackSwitchRebaseActive && root._trackSwitchVerificationActive);
}

function seekRestoreToleranceMs(root) {
    return seekRestoreIsTrueTrackSwitch(root) ? Math.max(1, root.trackSwitchSeekToleranceMs | 0) : Math.max(1, root.seekRestoreBootToleranceMs | 0);
}

function rememberSeekRestoreSample(root, localNow, localTarget) {
    var d = Math.abs(Math.max(0, localNow | 0) - Math.max(0, localTarget | 0));
    if (d < root._seekRestoreBestDiffMs) {
        root._seekRestoreBestDiffMs = d;
        root._seekRestoreBestLocalMs = Math.max(0, localNow | 0);
    }
    return d;
}

function completeSeekRestoreVerified(root, seekTimer, resumeTimer, targetUi) {
    if (root._seekRestoreAccepted) return;
    var track = seekRestoreIsTrueTrackSwitch(root);
    root._seekRestoreAccepted = true;
    root._pendingSeekMs = -1;
    root._seekRestoreAttempts = 0;
    root._seekRestoreLastTargetMs = -1;
    root._seekRestoreLastCallWallMs = 0;
    root._seekRestoreAwaitingResult = false;
    root._seekRestoreStableSamples = 0;
    root._seekRestoreReadyWallMs = 0;
    root._seekRestorePrimeWallMs = 0;
    root._seekRestorePauseWallMs = 0;
    root._seekRestorePhase = 0;
    root.baseOffsetMs = 0;
    if (track) {
        root._trackSwitchVerificationActive = false;
        root._trackSwitchTimebaseVerified = true;
    }
    try {
        seekTimer.stop();
    } catch (e0) {}
    if (!track) root._releaseSkipIntroResumeGate(targetUi);
    root.updateClocksFromPlaybackThrottled(true);
    if (root._wasPlayingBeforeSwitch && track) {
        root._trackSwitchResumeAfterVerified = true;
        resumeTimer.restart();
        return;
    }
    // Restauration vérifiée sans reprise de lecture : la gate armée par
    // mediaUrlSwap/beginFreshDirectPlayReset n'a plus aucun chemin de sortie.
    releaseVideoLoadingWhenPaused(root, "seek-restore-verified-paused");
}

function abandonBootSeekRestoreWithoutReload(root, seekTimer, targetUi, reason) {
    root._pendingSeekMs = -1;
    resetSeekRestoreState(root, null);
    try {
        seekTimer.stop();
    } catch (e0) {}
    root._releaseSkipIntroResumeGate(Math.max(targetUi, root.uiPositionMs()));
    root.updateClocksFromPlaybackThrottled(true);
}

function shouldEscalateSeekRestore(root, diff) {
    var t = seekRestoreToleranceMs(root);
    if (root._seekRestoreAccepted || root._seekRestoreBestDiffMs <= t || diff <= t) return false;
    return root._seekRestoreAttempts >= seekRestoreAttemptLimit(root);
}

function failTrackSwitchExactSeek(root, mp, seekTimer, settleTimer, restartTimer) {
    var restart = !!(root._trackSwitchWasPlaying || root._wasPlayingBeforeSwitch);
    try {
        seekTimer.stop();
    } catch (e0) {}
    try {
        settleTimer.stop();
    } catch (e1) {}
    root._pendingSeekMs = -1;
    root.baseOffsetMs = 0;
    root.serverTimedStream = false;
    root.timeShifted = false;
    root._trackSwitchVerificationActive = false;
    root._trackSwitchTimebaseVerified = false;
    resetSeekRestoreState(root, null);
    root._trackSwitchRestartAfterFailure = restart;
    try {
        mp.stop();
    } catch (e2) {}
    root.lastUiTargetMs = 0;
    root.updateClocksFromPlaybackThrottled(true);
    root._finishTrackSwitchRebase("exact-seek-unavailable");
    if (restart) restartTimer.restart();
}

function finishTrackSwitchRebase(root, settleTimer) {
    root._trackSwitchRebaseActive = false;
    root._trackSwitchAnchorUiMs = 0;
    root._trackSwitchAnchorWallMs = 0;
    root._trackSwitchWasPlaying = false;
    root._trackSwitchSettleTicks = 0;
    root._trackSwitchForceLocalSeek = false;
    root._trackSwitchLocalSeekMs = 0;
    root._pendingServerTimedBaseMs = -1;
    root._pendingHardResetBaseMs = -1;
    root._cancelHardSourceReset("state-reset");
    root._trackSwitchVerificationActive = false;
    root._trackSwitchTimebaseVerified = false;
    root._trackSwitchRequestedUiMs = 0;
    root._trackSwitchLocalStrategy = 1;
    root._trackSwitchSourceVideoCodec = "";
    root._trackSwitchSourceContainer = "";
    root._trackSwitchSourceHevc10 = false;
    resetSeekRestoreState(root, null);
    try {
        settleTimer.stop();
    } catch (e0) {}
}

function tickSeekRestore(root, mp, timer) {
    if (root._pendingSeekMs < 0) {
        timer.stop();
        return;
    }
    if (mp.status !== root._mpBuffered && mp.status !== root._mpLoaded) return;
    var now = _poNowMs();
    if (root._seekRestoreReadyWallMs <= 0) root._seekRestoreReadyWallMs = now;
    var target = root._pendingSeekMs,
        localTarget = root._trackSwitchVerificationActive ? target : Math.max(0, target - root.baseOffsetMs);
    if (mp.duration > 0) localTarget = Math.min(localTarget, mp.duration);
    if (root._seekRestoreLastTargetMs !== target) root._resetSeekRestoreGuard(target, "target-changed");
    var local = Math.max(0, mp.position | 0),
        diff = rememberSeekRestoreSample(root, local, localTarget),
        tol = seekRestoreToleranceMs(root);
    if (root._seekRestoreAttempts > 0 && diff <= tol) {
        root._completeSeekRestoreVerified(target, local, diff, "first-acceptable-sample");
        return;
    }
    root._seekRestoreStableSamples = 0;
    if (now - root._seekRestoreReadyWallMs >= seekRestoreDeadlineMs(root)) {
        if (root._seekRestoreBestDiffMs <= tol && root._seekRestoreBestLocalMs >= 0) root._completeSeekRestoreVerified(target, root._seekRestoreBestLocalMs, root._seekRestoreBestDiffMs, "best-sample-at-timeout");
        else root._retrySeekRestoreWithJellyfinCopyRemux(target, "local-seek-timeout");
        return;
    }
    if (root._seekRestoreAwaitingResult) {
        if (now - root._seekRestoreLastCallWallMs < root.trackSwitchSeekRetryDelayMs) return;
        root._seekRestoreAwaitingResult = false;
        if (shouldEscalateSeekRestore(root, diff)) {
            root._retrySeekRestoreWithJellyfinCopyRemux(target, "local-seek-unverified");
            return;
        }
    }
    if (root._trackSwitchVerificationActive && root._seekRestorePhase < 3) {
        // Sur la Revolution, le backend Intel CE4100 peut appliquer mp.pause()
        // avec un retard important. Lors d'un switch Remux/Transcode ->
        // DirectPlay statique, l'ancienne séquence play -> pause -> seek -> play
        // laissait alors un pause différé arriver APRES la reprise. Le fichier
        // était bien un vrai http-dp-static, mais les seeks suivants se faisaient
        // dans un pipeline semi-pausé et devenaient nettement moins fluides.
        //
        // Si la vidéo jouait avant le switch et que la nouvelle source est bien
        // le DirectPlay statique demandé manuellement, on garde le pipeline en
        // PlayingState pendant la restauration et on seek directement après le
        // court priming. Les autres cas conservent l'ancien protocole prudent.
        var keepPlayingStaticDp = root.manualDirectPlayMode === true &&
            root._trackSwitchWasPlaying === true &&
            isStaticDirectPlaySource(root);
        if (root._seekRestorePhase === 0) {
            root._seekRestorePhase = 1;
            root._seekRestorePrimeWallMs = now;
            root._seekRestorePauseWallMs = 0;
            if (mp.playbackState !== root._mpPlayingState) {
                try {
                    mp.play();
                } catch (e0) {}
            }
            return;
        }
        if (root._seekRestorePhase === 1) {
            if (now - root._seekRestorePrimeWallMs < root.trackSwitchPrimeMinMs && local < 80) {
                if (mp.playbackState !== root._mpPlayingState) {
                    try {
                        mp.play();
                    } catch (e1) {}
                }
                return;
            }
            if (keepPlayingStaticDp) {
                // Pas de pause intermédiaire : évite qu'un pause asynchrone du
                // backend intelce ne rattrape la commande play après le seek.
                root._seekRestorePhase = 3;
            } else {
                root._seekRestorePhase = 2;
                root._seekRestorePauseWallMs = now;
                try {
                    mp.pause();
                } catch (e2) {}
                return;
            }
        }
        if (root._seekRestorePhase === 2 && now - root._seekRestorePauseWallMs < root.trackSwitchPauseGraceMs) return;
    }
    root._seekRestoreAttempts++;
    root._seekRestoreAwaitingResult = true;
    root._seekRestoreLastCallWallMs = now;
    root._seekRestorePhase = 3;
    try {
        root._seekLocalPosition(localTarget);
    } catch (e3) {}
}

function uniqueMediaSourceUrl(root, url) {
    var s = String(url || "");
    if (!s) return s;
    root._sourceResetRevision++;
    return s + (s.indexOf("?") >= 0 ? "&" : "?") + "RdfSourceRevision=" + root._sourceResetRevision + "_" + Math.floor(_poNowMs());
}

function cancelHardSourceReset(root, timer) {
    if (!root._sourceResetActive && root._sourceResetPhase === 0) return;
    try {
        timer.stop();
    } catch (e0) {}
    root._sourceResetActive = false;
    root._sourceResetPhase = 0;
    root._sourceResetMode = "";
    root._sourceResetPendingUrl = "";
    root._sourceResetShouldResume = false;
    root._sourceResetExpectedUiMs = -1;
    root._sourceResetStartedWallMs = 0;
    root._sourceResetAssignedWallMs = 0;
    root._sourceResetReadyWallMs = 0;
    root._sourceResetPlayRetries = 0;
    root._pendingHardResetBaseMs = -1;
}

// Une source reconstruite en pause ne reçoit pas de signal Playing :
// libérer explicitement sa gate pour ne pas conserver le spinner.
function releaseVideoLoadingWhenPaused(root, reason) {
    if (!root || typeof root._releaseVideoLoading !== "function") return false;
    try {
        root._releaseVideoLoading(reason || "ready-paused");
    } catch (e0) {
        return false;
    }
    return true;
}

function completeFreshSourceResetState(root, timer, subtitleItem) {
    root._sourceResetActive = false;
    root._sourceResetPhase = 0;
    root._sourceResetMode = "";
    root._sourceResetPendingUrl = "";
    root._sourceResetExpectedUiMs = -1;
    root._sourceResetStartedWallMs = 0;
    root._sourceResetAssignedWallMs = 0;
    root._sourceResetReadyWallMs = 0;
    root._sourceResetPlayRetries = 0;
    try {
        timer.stop();
    } catch (e0) {}
    root._gateArmed = false;
    root._resumeAfterGate = false;
    root._startupPlayWanted = false;
    if (subtitleItem) subtitleItem.gateArmed = false;
    root._scheduleVideoLoadingRelease("fresh-source-reset-complete");
}

function completeFreshServerTimedSource(root, mp, timer, subtitleItem) {
    if (!root._sourceResetActive || root._sourceResetPhase !== 2) return;
    var expected = Math.max(0, Math.floor(Number(root._sourceResetExpectedUiMs || 0))),
        resume = root._sourceResetShouldResume;
    root.baseOffsetMs = expected;
    root._pendingServerTimedBaseMs = -1;
    root._pendingHardResetBaseMs = -1;
    root.serverTimedStream = true;
    root.timeShifted = expected > 0;
    root._trackSwitchTimebaseVerified = true;
    completeFreshSourceResetState(root, timer, subtitleItem);
    if (resume) {
        if (mp.playbackState !== root._mpPlayingState) {
            try {
                mp.play();
            } catch (e0) {}
        }
    } else {
        try {
            mp.pause();
        } catch (e1) {}
        // La lecture était en pause avant le rechargement : on restaure la pause,
        // mais toutes les libérations de la gate de chargement exigent l'état
        // Playing. Sans libération explicite ici, le loader resterait affiché
        // indéfiniment par-dessus une vidéo pourtant prête.
        releaseVideoLoadingWhenPaused(root, "fresh-source-ready-paused");
    }
    root.updateClocksFromPlaybackThrottled(true);
}

function beginHardSourceReset(root, mp, timer, audioGateTimer, startupTimer,
    subtitleItem, url, shouldResume) {
    root._armVideoLoading("hard-source-reset");
    root._cancelStartupPlay("hard-source-reset");
    try {
        audioGateTimer.stop();
    } catch (e0) {}
    try {
        startupTimer.stop();
    } catch (e1) {}
    root._sourceResetActive = true;
    root._sourceResetPhase = 1;
    root._sourceResetMode = "server-timed";
    root._sourceResetPendingUrl = uniqueMediaSourceUrl(root, url);
    root._sourceResetShouldResume = !!shouldResume;
    var base = root._pendingHardResetBaseMs >= 0 ?
        root._pendingHardResetBaseMs : root._pendingServerTimedBaseMs;
    root._sourceResetExpectedUiMs = Math.max(0, Math.floor(Number(base || 0)));
    root._sourceResetStartedWallMs = _poNowMs();
    root._sourceResetAssignedWallMs = 0;
    root._sourceResetReadyWallMs = 0;
    root._sourceResetPlayRetries = 0;
    root._trackSwitchTimebaseVerified = false;
    root.baseOffsetMs = 0;
    root._gateArmed = true;
    root._resumeAfterGate = false;
    root._startupPlayWanted = false;
    if (subtitleItem) subtitleItem.gateArmed = true;
    try {
        mp.stop();
    } catch (e2) {}
    root.mediaUrl = "";
    root._setMediaPlayerSource("", "hard-reset-clear");
    timer.restart();
}

function beginFreshDirectPlayReset(root, mp, timer, audioGateTimer, startupTimer,
    subtitleItem, url, shouldResume, targetUi) {
    root._armVideoLoading("fresh-directplay-reset");
    root._cancelStartupPlay("fresh-directplay-reset");
    try {
        audioGateTimer.stop();
    } catch (e0) {}
    try {
        startupTimer.stop();
    } catch (e1) {}
    root._sourceResetActive = true;
    root._sourceResetPhase = 1;
    root._sourceResetMode = "directplay-local";
    // Important : garder exactement l'URL statique Jellyfin négociée. Le reset
    // serveur ajoute volontairement un query de révision ; ici on veut reproduire
    // le plus fidèlement possible un DirectPlay natif cold-start.
    root._sourceResetPendingUrl = String(url || "");
    root._sourceResetShouldResume = !!shouldResume;
    root._sourceResetExpectedUiMs = Math.max(0, Math.floor(Number(targetUi || 0)));
    root._sourceResetStartedWallMs = _poNowMs();
    root._sourceResetAssignedWallMs = 0;
    root._sourceResetReadyWallMs = 0;
    root._sourceResetPlayRetries = 0;
    root._trackSwitchTimebaseVerified = false;
    root.baseOffsetMs = 0;
    root.serverTimedStream = false;
    root.timeShifted = false;
    root._gateArmed = true;
    root._resumeAfterGate = false;
    root._startupPlayWanted = false;
    if (subtitleItem) subtitleItem.gateArmed = true;
    // Contrairement à mediaUrlSwap(), on NE réassigne pas la nouvelle URL dans
    // le même tour d'event. On attend NoMedia pour forcer intelce à détruire
    // l'ancien pipeline remux/transcode avant de créer le DP statique.
    try {
        mp.stop();
    } catch (e2) {}
    root.mediaUrl = "";
    root._setMediaPlayerSource("", "fresh-directplay-clear");
    timer.restart();
}

function completeFreshDirectPlaySource(root, mp, timer, seekTimer, subtitleItem) {
    if (!root._sourceResetActive || root._sourceResetMode !== "directplay-local") return;
    var resume = root._sourceResetShouldResume;
    root._sourceResetActive = false;
    root._sourceResetPhase = 0;
    root._sourceResetMode = "";
    root._sourceResetPendingUrl = "";
    root._sourceResetShouldResume = false;
    root._sourceResetExpectedUiMs = -1;
    root._sourceResetStartedWallMs = 0;
    root._sourceResetAssignedWallMs = 0;
    root._sourceResetReadyWallMs = 0;
    root._sourceResetPlayRetries = 0;
    root._pendingHardResetBaseMs = -1;
    root._pendingServerTimedBaseMs = -1;
    root.baseOffsetMs = 0;
    root.serverTimedStream = false;
    root.timeShifted = false;
    try {
        timer.stop();
    } catch (e0) {}
    // Le seek de reprise est toujours vérifié par le mécanisme existant, mais
    // il part désormais d'un backend réellement recréé. L'opacité du
    // PlayerOverlay est déjà verrouillée par _trackSwitchVerificationActive,
    // donc on peut libérer la gate audio ici sans exposer la frame 00:00.
    root._gateArmed = false;
    root._resumeAfterGate = false;
    root._startupPlayWanted = false;
    if (subtitleItem) subtitleItem.gateArmed = false;
    if (root._pendingSeekMs >= 0) {
        root._seekRestoreReadyWallMs = 0;
        root._seekRestorePrimeWallMs = 0;
        root._seekRestorePauseWallMs = 0;
        root._seekRestorePhase = 0;
        root._seekRestoreAwaitingResult = false;
        if (resume && mp.playbackState !== root._mpPlayingState) {
            try {
                mp.play();
            } catch (e1) {}
        }
        try {
            seekTimer.restart();
        } catch (e2) {}
        return;
    }
    root._trackSwitchTimebaseVerified = true;
    root._gateArmed = false;
    root._resumeAfterGate = false;
    root._startupPlayWanted = false;
    if (subtitleItem) subtitleItem.gateArmed = false;
    root._scheduleVideoLoadingRelease("fresh-directplay-reset-complete");
    if (resume && mp.playbackState !== root._mpPlayingState) {
        try {
            mp.play();
        } catch (e3) {}
    } else if (!resume) {
        // Même défaut que le reset server-timed : sans reprise de lecture,
        // aucune libération automatique de la gate n'arrive jamais.
        releaseVideoLoadingWhenPaused(root, "fresh-directplay-ready-paused");
    }
}

function tickSourceReset(root, mp, timer, seekTimer, subtitleItem) {
    if (!root._sourceResetActive) {
        timer.stop();
        return;
    }

    var now = _poNowMs();
    var mode = String(root._sourceResetMode || "server-timed");

    if (root._sourceResetPhase === 1) {
        var cleared = mp.playbackState === root._mpStoppedState &&
            mp.status === root._mpNoMedia;
        if (!cleared && now - root._sourceResetStartedWallMs < root.sourceResetClearTimeoutMs)
            return;

        root._sourceResetPhase = 2;
        root._sourceResetAssignedWallMs = now;
        root._pendingServerTimedBaseMs = -1;
        root._pendingHardResetBaseMs = -1;

        if (mode === "directplay-local") {
            root.baseOffsetMs = 0;
            root.serverTimedStream = false;
            root.timeShifted = false;
        } else {
            root.baseOffsetMs = Math.max(0, Math.floor(Number(root._sourceResetExpectedUiMs || 0)));
            root.serverTimedStream = true;
            root.timeShifted = root.baseOffsetMs > 0;
        }

        root.mediaUrl = root._sourceResetPendingUrl;
        root._setMediaPlayerSource(
            root.mediaUrl,
            mode === "directplay-local" ? "fresh-directplay-source" : "hard-reset-fresh-source"
        );
        try {
            mp.play();
        } catch (e0) {}
        return;
    }

    if (root._sourceResetPhase !== 2) return;

    var elapsed = now - root._sourceResetAssignedWallMs;
    var ready = mp.status === root._mpBuffered || mp.status === root._mpLoaded;
    var local = Math.max(0, Math.floor(Number(mp.position || 0)));
    if (ready && root._sourceResetReadyWallMs <= 0)
        root._sourceResetReadyWallMs = now;

    if (mode === "directplay-local") {
        if (ready && (local > 0 || mp.playbackState === root._mpPlayingState)) {
            completeFreshDirectPlaySource(root, mp, timer, seekTimer, subtitleItem);
            return;
        }
        if (ready &&
            mp.playbackState === root._mpStoppedState &&
            elapsed >= root.sourceResetStartRetryMs &&
            root._sourceResetPlayRetries < 1) {
            root._sourceResetPlayRetries++;
            try {
                mp.play();
            } catch (e1) {}
            return;
        }
        // En timeout, ne retransformer surtout pas le DP en flux server-timed.
        // On libère le reset et laisse seekRestore/fallback décider proprement.
        if (elapsed >= root.sourceResetStartTimeoutMs) {
            completeFreshDirectPlaySource(root, mp, timer, seekTimer, subtitleItem);
            return;
        }
        return;
    }

    if (ready && (local > 0 || mp.playbackState === root._mpPlayingState)) {
        root._commitFreshServerTimedSource("fresh-pipeline-progress");
        return;
    }
    if (ready &&
        mp.playbackState === root._mpStoppedState &&
        elapsed >= root.sourceResetStartRetryMs &&
        root._sourceResetPlayRetries < 1) {
        root._sourceResetPlayRetries++;
        try {
            mp.play();
        } catch (e2) {}
        return;
    }
    if (elapsed >= root.sourceResetStartTimeoutMs)
        root._finishFreshServerTimedSourceTimeout("startup-timeout");
}

function isCurrentItemDirectPlaySeekUnsafe(root) {
    return !!(root && root._staticDirectPlaySeekUnsafe === true &&
        String(root._staticDirectPlaySeekUnsafeItemId || "") === String(root.itemId || ""));
}

function markCurrentItemDirectPlaySeekUnsafe(root) {
    root._staticDirectPlaySeekUnsafe = true;
    root._staticDirectPlaySeekUnsafeItemId = String(root.itemId || "");
}

function isStaticDirectPlaySource(root) {
    try {
        return PlaybackRouter.urlKind(root.mediaUrl || "") === "http-dp-static";
    } catch (e0) {
        return false;
    }
}

function directPlayOpenFallbackTargetMs(root) {
    var target = 0;
    if (root._pendingSeekMs >= 0) target = Math.max(0, Math.floor(Number(root._pendingSeekMs || 0)));
    else if (root.lastUiTargetMs > 0) target = Math.max(0, Math.floor(Number(root.lastUiTargetMs || 0)));
    else {
        try {
            target = Math.max(0, Math.floor(Number(root.uiPositionMs() || 0)));
        } catch (e0) {
            target = 0;
        }
    }
    return target;
}

function fallbackStaticDirectPlayToServerRemux(root, mp, timers, targetUi, reason) {
    if (!root || root._tearingDownPlayer) return false;
    if (root._staticDirectPlaySeekFallbackInProgress) return true;
    if (!isStaticDirectPlaySource(root) && !isCurrentItemDirectPlaySeekUnsafe(root)) return false;
    targetUi = root._clampUi(Math.max(0, Math.floor(Number(targetUi || 0))));
    markCurrentItemDirectPlaySeekUnsafe(root);
    root._staticDirectPlaySeekFallbackInProgress = true;
    root._staticDirectPlayFallbackAwaitingStableRemux = true;
    root._staticDirectPlayFallbackTargetMs = targetUi;
    root._staticDirectPlayFallbackStartedWallMs = root._nowMs();
    root.manualDirectPlayMode = false;
    root.coalescedDirectPlaySeekMode = false;
    var resume = root._trackSwitchWasPlaying || root._wasPlayingBeforeSwitch || mp.playbackState === root._mpPlayingState;
    root._resumeWantedAfterNegotiation = resume;
    root.lastUiTargetMs = targetUi;
    root.showScrubPreview(targetUi);
    _timerStop(timers && timers.startup);
    _timerStop(timers && timers.seekRestore);
    _timerStop(timers && timers.scrubCommit);
    root._startupPlayWanted = false;
    root._startupPlayTries = 0;
    root._pendingSeekMs = -1;
    root._pendingServerTimedBaseMs = -1;
    root._pendingHardResetBaseMs = -1;
    root._seekRestoreAttempts = 0;
    root._seekRestoreLastTargetMs = -1;
    root._seekRestoreAwaitingResult = false;
    root._seekRestoreReadyWallMs = 0;
    root._trackSwitchForceLocalSeek = false;
    root._trackSwitchVerificationActive = false;
    root._trackSwitchTimebaseVerified = true;
    root.negotiatePlayback(targetUi, false, true, false, false, {
        staticDirectPlayFallbackOwner: true,
        trackSwitchRebase: root._trackSwitchRebaseActive,
        trackSwitchColdLocalSeek: false,
        forceServerSeek: true,
        forceServerRemux: true,
        forceExplicitServerProgressiveSeek: true,
        forceJellyfinTranscodingUrlCopyRemux: false,
        forceHlsOnDpSeekFallback: false,
        forceRetry: true,
        forceDirectPlayInPlaybackInfo: false,
        forceDirectStreamInPlaybackInfo: false,
        forceVideoStreamCopyInPlaybackInfo: true,
        forceAudioStreamCopyInPlaybackInfo: true,
        manualDirectPlayOverride: false,
        preferFrenchAudio: true,
        disableAutoFrenchAudio: false,
        disableDefaultSubtitleRemux: false,
        disableDefaultFrenchAudioOrderRemux: false,
        disableImageSubtitleRiskRemux: false,
        disableHevcMain10MkvRemux: false
    });
    return true;
}

function guardUnsafeManualDirectPlayRequest(root, mp, timers, targetUi, reason) {
    if (!isCurrentItemDirectPlaySeekUnsafe(root)) return false;
    targetUi = root._clampUi(Math.max(0, Math.floor(Number(targetUi || 0))));
    root.manualDirectPlayMode = false;
    root.lastUiTargetMs = targetUi;
    root.showScrubPreview(targetUi);
    if (root._staticDirectPlaySeekFallbackInProgress || root.lastUsedServerRemux ||
        root.lastUsedDirectStream || root.serverTimedStream || root.timeShifted || root.baseOffsetMs > 0) return true;
    return fallbackStaticDirectPlayToServerRemux(root, mp, timers, targetUi, reason || "unsafe-manual-directplay-blocked");
}

function maybeCompleteStaticDirectPlayFallback(root, mp) {
    if (!root._staticDirectPlaySeekFallbackInProgress || !root._staticDirectPlayFallbackAwaitingStableRemux) return false;
    if (isStaticDirectPlaySource(root)) return false;
    if (!(mp.status === root._mpLoaded || mp.status === root._mpBuffered)) return false;
    var remuxLike = root.lastUsedServerRemux || root.lastUsedDirectStream || root.serverTimedStream || root.timeShifted || root.baseOffsetMs > 0;
    if (!remuxLike) return false;
    var target = Math.max(0, Number(root._staticDirectPlayFallbackTargetMs || 0)),
        ui = 0;
    try {
        ui = Math.max(0, Number(root.uiPositionMs() || 0));
    } catch (e0) {}
    var coherent = target <= 0 || Math.abs(ui - target) <= 5000 || root.baseOffsetMs >= Math.max(0, target - 2500) ||
        (mp.position > 0 && ui >= Math.max(0, target - 2500));
    if (!coherent) return false;
    root._staticDirectPlaySeekFallbackInProgress = false;
    root._staticDirectPlayFallbackAwaitingStableRemux = false;
    root._staticDirectPlayFallbackTargetMs = -1;
    root._staticDirectPlayFallbackStartedWallMs = 0;
    return true;
}

function tryDirectPlayOpenRemuxFallback(root, mp, timers, reason) {
    if (root._directPlayOpenFallbackUsed || root._tearingDownPlayer) return false;
    if (!isStaticDirectPlaySource(root) || root.lastUsedServerRemux || root.lastUsedTranscoding || root.lastUsedDirectStream || root.isHls) return false;
    if (root._sourceResetActive || root._mediaErrorRecoveryInProgress || root._mediaErrorRecoveryArmed) return false;
    var stopped = mp.playbackState === root._mpStoppedState || mp.playbackState === root._mpPausedState;
    var opening = mp.status === root._mpLoading || mp.status === root._mpStalled;
    var local = Math.max(0, Math.floor(Number(mp.position || 0)));
    var elapsed = root._directPlayOpenStartedWallMs > 0 ? root._nowMs() - root._directPlayOpenStartedWallMs : 0;
    if (!stopped || !opening || local > 250 || elapsed < root.directPlayOpenFallbackMinMs) return false;
    var target = directPlayOpenFallbackTargetMs(root);
    root._directPlayOpenFallbackUsed = true;
    if (root.manualDirectPlayMode) {
        if (target <= 0) return false;
        return fallbackStaticDirectPlayToServerRemux(root, mp, timers, target, reason || "dp-open-manual");
    }
    root._startupPlayWanted = false;
    root._startupPlayTries = 0;
    root._gateArmed = false;
    root._resumeAfterGate = false;
    _timerStop(timers && timers.startup);
    _timerStop(timers && timers.audioGate);
    _timerStop(timers && timers.seekRestore);
    root._pendingSeekMs = -1;
    root._pendingServerTimedBaseMs = -1;
    root._pendingHardResetBaseMs = -1;
    root._seekRestoreAttempts = 0;
    root._seekRestoreLastTargetMs = -1;
    try {
        mp.stop();
    } catch (e4) {}
    root.mediaUrl = "";
    root._setMediaPlayerSource("", "dp-open-remux-fallback-clear");
    root._resumeWantedAfterNegotiation = true;
    root.negotiatePlayback(target, false, target > 0, false, false, {
        forceServerRemux: true,
        forceRetry: true,
        forceDirectPlayInPlaybackInfo: false,
        forceDirectStreamInPlaybackInfo: false,
        forceVideoStreamCopyInPlaybackInfo: true,
        forceAudioStreamCopyInPlaybackInfo: true
    });
    return true;
}

function recoveryCandidateUiMs(root, mp) {
    var cur = root._clampUi(root.uiPositionMs()),
        target = cur;
    var stable = root._pauseWatchLastStableUiMs,
        pause = root._pauseWatchStartedUiMs;
    var reset = !!(root._serverTimedLike() && mp.position <= 1000 && cur <= root.baseOffsetMs + 1500);
    if (root.lastUiTargetMs > 0) target = Math.max(target, root._clampUi(root.lastUiTargetMs));
    if (stable > 0 && (reset || stable > cur + 2500)) target = Math.max(target, root._clampUi(stable));
    if (pause > 0 && (reset || pause > cur + 2500)) target = Math.max(target, root._clampUi(pause));
    return root._clampUi(target);
}

function markMediaRecoveryPosition(root, targetUi, reason) {
    targetUi = root._clampUi(targetUi);
    root._mediaErrorRecoverySafeUiMs = targetUi;
    root._mediaErrorProgressGuardUntilWallMs = root._nowMs() + 45000;
    root._mediaErrorRecoveryInProgress = true;
    root._mediaErrorRecoveryReason = reason || "mediaError";
}

function reportUiPositionMs(root, mp) {
    var pos = root._clampUi(root.uiPositionMs()),
        now = root._nowMs();
    var safe = root._mediaErrorRecoverySafeUiMs > 0 ? root._mediaErrorRecoverySafeUiMs : root._pauseWatchLastStableUiMs;
    var guard = !!(root._mediaErrorRecoveryArmed || root._mediaErrorRecoveryInProgress || now < root._mediaErrorProgressGuardUntilWallMs);
    var reset = !!(root._serverTimedLike() && (mp.position <= 1000 || pos <= root.baseOffsetMs + 1500));
    if (guard && safe > 0 && pos < safe - 2500 && reset) return root._clampUi(safe);
    return pos;
}

function sameModeRecoveryFlags(root) {
    var h = !!root.isHls;
    return {
        keepHls: h,
        keepServerRemux: !!(root.lastUsedServerRemux && !h)
    };
}

function recoverSameModeAt(root, targetUi, reason) {
    targetUi = root._clampUi(targetUi);
    var safe = root._clampUi(targetUi > 2500 ? targetUi - root.resumePrerollMs : targetUi);
    if (root._serverTimedLike() && root.baseOffsetMs > 0 && safe < root.baseOffsetMs) safe = root.baseOffsetMs;
    var f = sameModeRecoveryFlags(root);
    markMediaRecoveryPosition(root, targetUi, reason || "sameModeRetry");
    root._resumeWantedAfterNegotiation = true;
    root.negotiatePlayback(safe, f.keepHls, true, false, false, {
        forceRetry: true,
        forceServerSeek: false,
        forceServerRemux: f.keepServerRemux,
        forceHlsOnDpSeekFallback: false
    });
}

function armFrozenPlaybackWatch(root, mp, timer, reason, windowMs) {
    if (!root._serverTimedLike() && !root.lastUsedServerRemux) return;
    var now = root._nowMs();
    root._frozenPlaybackWatchActive = true;
    root._frozenPlaybackWatchArmedWallMs = now;
    root._frozenPlaybackWatchUntilWallMs = now + Math.max(8000, windowMs || root.frozenPlaybackWatchWindowMs);
    root._frozenPlaybackNoProgressSinceWallMs = 0;
    root._frozenPlaybackLastLocalMs = Math.max(0, mp.position || 0);
    root._frozenPlaybackLastUiMs = root._clampUi(root.uiPositionMs());
    _timerRestart(timer);
}

function stopFrozenPlaybackWatch(root, timer) {
    root._frozenPlaybackWatchActive = false;
    root._frozenPlaybackNoProgressSinceWallMs = 0;
    root._frozenPlaybackLastLocalMs = -1;
    root._frozenPlaybackLastUiMs = -1;
    _timerStop(timer);
}

function recoverFromFrozenPlayback(root, mp, watchTimer, guardTimer, reason) {
    if (root._mediaErrorRecoveryArmed || root._mediaErrorRecoveryInProgress) return;
    root._frozenPlaybackRecoveryCount++;
    root._mediaErrorRecoveryArmed = true;
    _timerRestart(guardTimer);
    if (root._frozenPlaybackRecoveryCount > 3) {
        stopFrozenPlaybackWatch(root, watchTimer);
        return;
    }
    var target = root._clampUi(recoveryCandidateUiMs(root, mp));
    stopFrozenPlaybackWatch(root, watchTimer);
    recoverSameModeAt(root, target, "frozenPlaybackSameModeRetry");
    armFrozenPlaybackWatch(root, mp, watchTimer, "postFrozenRecovery", root.frozenPlaybackWatchWindowMs);
}

function tickFrozenPlaybackWatch(root, mp, watchTimer, guardTimer) {
    if (!root._frozenPlaybackWatchActive) return;
    var now = root._nowMs();
    if (root._frozenPlaybackWatchUntilWallMs > 0 && now > root._frozenPlaybackWatchUntilWallMs) {
        stopFrozenPlaybackWatch(root, watchTimer);
        return;
    }
    if (!root._serverTimedLike() && !root.lastUsedServerRemux) {
        stopFrozenPlaybackWatch(root, watchTimer);
        return;
    }
    if (root._mediaErrorRecoveryInProgress || root._mediaErrorRecoveryArmed || root._gateArmed || root._startupPlayWanted || root.scrubActive) {
        root._frozenPlaybackLastLocalMs = Math.max(0, mp.position || 0);
        root._frozenPlaybackLastUiMs = root._clampUi(root.uiPositionMs());
        root._frozenPlaybackNoProgressSinceWallMs = 0;
        _timerRestart(watchTimer);
        return;
    }
    if (mp.playbackState !== root._mpPlayingState || !(mp.status === root._mpBuffered || mp.status === root._mpLoaded)) {
        root._frozenPlaybackLastLocalMs = Math.max(0, mp.position || 0);
        root._frozenPlaybackLastUiMs = root._clampUi(root.uiPositionMs());
        root._frozenPlaybackNoProgressSinceWallMs = 0;
        _timerRestart(watchTimer);
        return;
    }
    if (root._frozenPlaybackWatchArmedWallMs > 0 && now - root._frozenPlaybackWatchArmedWallMs < root.frozenPlaybackStartupGraceMs) {
        _timerRestart(watchTimer);
        return;
    }
    var local = Math.max(0, mp.position || 0),
        ui = root._clampUi(root.uiPositionMs()),
        progressed = false;
    if (root._frozenPlaybackLastLocalMs >= 0 && local > root._frozenPlaybackLastLocalMs + 300) progressed = true;
    if (root._frozenPlaybackLastUiMs >= 0 && ui > root._frozenPlaybackLastUiMs + 300) progressed = true;
    if (progressed) {
        root._frozenPlaybackLastLocalMs = local;
        root._frozenPlaybackLastUiMs = ui;
        root._frozenPlaybackNoProgressSinceWallMs = 0;
        root._frozenPlaybackRecoveryCount = 0;
        if (ui > 0 && local > 0) {
            root._pauseWatchLastStableUiMs = Math.max(root._pauseWatchLastStableUiMs, ui);
            root._pauseWatchLastStableWallMs = now;
        }
        _timerRestart(watchTimer);
        return;
    }
    if (root._frozenPlaybackNoProgressSinceWallMs <= 0) {
        root._frozenPlaybackNoProgressSinceWallMs = now;
        _timerRestart(watchTimer);
        return;
    }
    if (Math.floor(now - root._frozenPlaybackNoProgressSinceWallMs) >= root.frozenPlaybackNoProgressMs) {
        recoverFromFrozenPlayback(root, mp, watchTimer, guardTimer, "playingBufferedNoProgress");
        return;
    }
    _timerRestart(watchTimer);
}

function recoverFromMediaError(root, mp, watchTimer, guardTimer) {
    if (root._mediaErrorRecoveryArmed) return;
    // Un MediaError HLS stéréo ne prouve pas que le codec demandé est fautif.
    // Le profil 2.0 cible désormais AAC-LC dès la première négociation ; on
    // reconstruit UNE fois le même pipeline depuis PlaybackInfo à la position
    // courante, puis les mécanismes
    // génériques de récupération prennent le relais si l'erreur persiste.
    if (String(root.audioOutputMode || "") === "stereo" && root.lastUsedTranscoding === true &&
        root._mediaErrorRecoveryCount < 1) {
        var stereoTarget = root._clampUi(recoveryCandidateUiMs(root, mp));
        root._mediaErrorRecoveryCount++;
        root._mediaErrorRecoveryArmed = true;
        _timerRestart(guardTimer);
        root._resumeWantedAfterNegotiation = true;
        markMediaRecoveryPosition(root, stereoTarget, "stereoHlsFreshRetry");
        root.negotiatePlayback(stereoTarget, false, true, false, false, {
            forceRetry: true,
            preferStereoAudioOnlyHls: true,
            forceVideoStreamCopyInPlaybackInfo: true,
            forceAudioStreamCopyInPlaybackInfo: false
        });
        return;
    }
    if (root.isHls && root._serverTimedLike() && root.lastUiTargetMs > 2500 && root._mediaErrorRecoveryCount < 2) {
        root._mediaErrorRecoveryCount++;
        root._mediaErrorRecoveryArmed = true;
        _timerRestart(guardTimer);
        markMediaRecoveryPosition(root, root.lastUiTargetMs, "hlsInvalidFallbackRemux");
        root._resumeWantedAfterNegotiation = true;
        root.negotiatePlayback(root._clampUi(root.lastUiTargetMs), false, true, false, false, {
            forceRetry: true,
            forceServerSeek: true,
            forceServerRemux: true,
            forceHlsOnDpSeekFallback: false,
            forcePolicyTranscodeHls: false,
            forcePolicyTranscodeAllowAudioCopy: true,
            forceVideoStreamCopyInPlaybackInfo: true,
            forceAudioStreamCopyInPlaybackInfo: true
        });
        return;
    }
    root._mediaErrorRecoveryArmed = true;
    _timerRestart(guardTimer);
    root._mediaErrorRecoveryCount++;
    var target = root._clampUi(recoveryCandidateUiMs(root, mp));
    if (root._mediaErrorRecoveryCount > 4) return;
    recoverSameModeAt(root, target, "mediaErrorSameModeRetry");
    armFrozenPlaybackWatch(root, mp, watchTimer, "postMediaErrorRecovery", root.frozenPlaybackWatchWindowMs);
}

function _timerStop(t) {
    try {
        if (t && t.stop) t.stop();
    } catch (e) {}
}

function _timerRestart(t) {
    try {
        if (t && t.restart) t.restart();
        else if (t && t.start) t.start();
    } catch (e) {}
}

function mediaUrlSwap(root, mp, timers, subtitleItem, u, resume) {
    var first = (!root.mediaUrl || root.mediaUrl.length === 0) && !root._sourceResetActive;
    root._armVideoLoading(first ? "media-url-first" : "media-url-swap");

    var shouldResume = !!resume || first;
    var freshManualStaticDp = root.manualDirectPlayMode === true &&
        root._trackSwitchVerificationActive === true &&
        root._pendingSeekMs >= 0 &&
        PlaybackRouter.urlKind(u || "") === "http-dp-static";

    if (freshManualStaticDp && typeof root._beginFreshDirectPlayReset === "function") {
        root._beginFreshDirectPlayReset(u, shouldResume, root._pendingSeekMs);
        return;
    }
    if (root._pendingHardResetBaseMs >= 0) {
        root._beginHardSourceReset(u, shouldResume);
        return;
    }

    root._gateArmed = true;
    root._resumeAfterGate = shouldResume;
    root._startupPlayWanted = shouldResume;
    root._startupPlayTries = 0;
    root._directPlayOpenStartedWallMs = PlaybackRouter.urlKind(u || "") === "http-dp-static" ? root._nowMs() : 0;

    if (subtitleItem) subtitleItem.gateArmed = true;
    if (root.mediaUrl !== u) root.mediaUrl = u;
    try {
        mp.stop();
    } catch (e0) {}

    if (root._pendingServerTimedBaseMs >= 0) {
        root.baseOffsetMs = Math.max(0, Math.floor(Number(root._pendingServerTimedBaseMs || 0)));
        root._pendingServerTimedBaseMs = -1;
    }

    root._setMediaPlayerSource(root.mediaUrl, "mediaUrlSwap");
    try {
        mp.play();
    } catch (e1) {}

    if (!shouldResume) {
        if (root._trackSwitchVerificationActive && root._pendingSeekMs >= 0) {
            root._seekRestorePhase = 0;
            root._seekRestorePrimeWallMs = 0;
            root._seekRestorePauseWallMs = 0;
        } else {
            try {
                mp.pause();
            } catch (e2) {}
        }
    } else {
        _timerRestart(timers && timers.startup);
    }

    if (timers && timers.audioGate) {
        timers.audioGate.interval = root.audioGateMsDefault;
        _timerRestart(timers.audioGate);
    }
}

function retrySeekRestoreWithJellyfinCopyRemux(root, mp, timers, targetUi, reason) {
    if (!root._seekRestoreIsTrueTrackSwitch()) {
        var tol = root._seekRestoreToleranceMs();
        if (root._seekRestoreBestDiffMs <= tol && root._seekRestoreBestLocalMs >= 0) {
            root._completeSeekRestoreVerified(
                targetUi,
                root._seekRestoreBestLocalMs,
                root._seekRestoreBestDiffMs,
                "best-sample-before-boot-fallback"
            );
        } else {
            root._abandonBootSeekRestoreWithoutReload(targetUi, reason || "boot-seek-no-track-fallback");
        }
        return;
    }

    if (isStaticDirectPlaySource(root) && root.manualDirectPlayMode) {
        fallbackStaticDirectPlayToServerRemux(
            root, mp, timers, targetUi, reason || "manual-directplay-local-seek-ignored"
        );
        return;
    }
    if (root._trackSwitchFragileHevc()) {
        root._failTrackSwitchExactSeek(reason || "fragile-hevc-local-seek-ignored");
        return;
    }

    if (root._trackSwitchLocalStrategy < 2) {
        root._trackSwitchLocalStrategy = 2;
        root._seekRestoreAttempts = 0;
        root._seekRestoreLastTargetMs = -1;
        root._seekRestoreLastCallWallMs = 0;
        root._seekRestoreAwaitingResult = false;
        root._seekRestoreStableSamples = 0;
        root._seekRestoreReadyWallMs = 0;
        root._seekRestorePrimeWallMs = 0;
        root._seekRestorePauseWallMs = 0;
        root._seekRestorePhase = 0;
        root._pendingSeekMs = -1;
        root.baseOffsetMs = 0;
        root.serverTimedStream = false;
        root.timeShifted = false;
        root.negotiatePlayback(targetUi, false, false, false, false, {
            trackSwitchRebase: true,
            trackSwitchColdLocalSeek: true,
            trackSwitchLocalStrategy: 2,
            forceJellyfinTranscodingUrlCopyRemux: true,
            forceServerSeek: false,
            forceServerRemux: false,
            forceHlsOnDpSeekFallback: false,
            forceRetry: true
        });
        return;
    }

    root._failTrackSwitchExactSeek(reason || "local-seek-ignored");
}

function serverSeekFallback(root, mp, timers, targetUi, reason) {
    targetUi = root._clampUi(targetUi);
    root.lastUiTargetMs = targetUi;
    root.showScrubPreview(targetUi);

    if (isStaticDirectPlaySource(root) && !root._mediaSeekable()) {
        if (fallbackStaticDirectPlayToServerRemux(
                root, mp, timers, targetUi, reason || "static-directplay-unseekable"))
            return;
    }

    root._resumeWantedAfterNegotiation = root._wasPlayingBeforeSwitch ||
        mp.playbackState === root._mpPlayingState;
    var hls = false;
    var remux = root.lastUsedServerRemux ||
        root.serverTimedStream ||
        root.timeShifted ||
        root.baseOffsetMs > 0;
    if (root.isHls && root.lastUsedTranscoding && !remux) hls = true;

    root.negotiatePlayback(targetUi, hls, true, false, false, {
        forceServerSeek: true,
        forceServerRemux: !hls,
        forceHlsOnDpSeekFallback: false,
        forceRetry: true
    });
}

function localSeekTo(root, mp, timers, targetUi, reason) {
    targetUi = root._clampUi(targetUi);
    root.lastUiTargetMs = targetUi;
    var local = Math.max(0, targetUi - root.baseOffsetMs);
    if (mp.duration > 0) local = Math.min(local, mp.duration);

    try {
        root._seekLocalPosition(local);
        root.updateClocksFromPlayback();
        return true;
    } catch (e) {
        serverSeekFallback(root, mp, timers, targetUi, (reason || "localSeek") + ":seek-error");
        return false;
    }
}

function seekToChapter(root, mp, timers, targetUi) {
    if (!root || !mp || root._tearingDownPlayer) return false;
    targetUi = root._clampUi(Math.max(0, Math.floor(Number(targetUi || 0))));

    try {
        if (timers && timers.scrubCommit) timers.scrubCommit.stop();
    } catch (e0) {}
    root.scrubActive = false;
    root.scrubAccumUiMs = -1;
    root._scrubCommitTargetUiMs = -1;

    if (root._pendingSeekMs >= 0) {
        root._pendingSeekMs = targetUi;
        root.lastUiTargetMs = targetUi;
        root.showScrubPreview(targetUi);
        return true;
    }

    var resume = mp.playbackState === root._mpPlayingState;
    root._wasPlayingBeforeSwitch = resume;
    root.lastUiTargetMs = targetUi;
    root.showScrubPreview(targetUi);

    if (root.shouldNetworkSeek && root.shouldNetworkSeek()) {
        try {
            mp.pause();
        } catch (e1) {}
        root._resumeWantedAfterNegotiation = resume;
        // Un réglage différé doit voyager avec la renégociation du chapitre :
        // une seule négociation, à la position du chapitre.
        if (TrackSelection.seekDeferredReload(root, mp, targetUi, "chapter-carousel", resume)) return true;
        serverSeekFallback(root, mp, timers, targetUi, "chapter-carousel");
        return true;
    }

    var ok = localSeekTo(root, mp, timers, targetUi, "chapter-carousel");
    if (resume) {
        try {
            mp.play();
        } catch (e2) {}
    }
    return ok;
}

function stopSourceNegotiationTimers(timers) {
    _timerStop(timers && timers.seekRestore);
    _timerStop(timers && timers.sourceReset);
}

// Coordination des commandes exposées par PlayerOverlay.
function mediaSeekable(root, mp) {
    try {
        return !!(mp && mp.seek && mp.seekable === true)
    } catch (e) {
        return false
    }
}

function playerShouldNetworkSeek(root, mp) {
    // Un fichier DirectPlay statique non seekable ne doit jamais recevoir un mp.seek() local : on bascule sur un remux serveur positionné.
    if (root._isStaticDirectPlaySource() && !root._mediaSeekable()) return true
    if (root.isHls) return true
    if (root.lastUsedTranscoding) return true
    if (root.lastUsedDirectStream) return true
    if (root.lastUsedServerRemux) return true
    if (root.serverTimedStream || root.timeShifted) return true
    if (root.baseOffsetMs > 0) return true
    if (!root.durationMs() || root.durationMs() <= 0) return true
    return false
}

function clampPlayerUi(root, t) {
    var d = root.durationMs();
    if (d <= 0) d = 24 * 3600 * 1000;
    return Math.max(0, Math.min(t, d))
}

function coalescedLocalSeekEligible(root) {
    if (!root.coalescedDirectPlaySeekMode) return false
    if (!root._isStaticDirectPlaySource()) return false
    if (root._pendingSeekMs >= 0 || root._trackSwitchVerificationActive || root._sourceResetActive) return false
    return !root.shouldNetworkSeek()
}

function cancelCoalescedLocalSeek(root, timer) {
    root._coalescedLocalSeekTargetUiMs = -1
    root._coalescedLocalSeekDirection = 0
    try {
        timer.stop()
    } catch (e0) {}
}

function queueCoalescedLocalSeek(root, timer, deltaMs) {
    if (!root._coalescedLocalSeekEligible()) return false
    var nowUi = root._clampUi(root.uiPositionMs())
    var dir = deltaMs < 0 ? -1 : 1
    var base = (root._coalescedLocalSeekTargetUiMs >= 0 && root._coalescedLocalSeekDirection === dir) ?
        root._coalescedLocalSeekTargetUiMs : nowUi
    var target = root._clampUi(base + deltaMs)
    // Quand mp.seek() bloque le thread QML, plusieurs secondes d'auto-repeat
    // peuvent etre livrees d'un coup au retour. Elles ne doivent jamais
    // transformer une seule frame actualisee en saut de plusieurs minutes.
    var maxJump = Math.max(Math.abs(deltaMs), root.coalescedDirectPlaySeekMaxJumpMs | 0)
    if (dir > 0) target = Math.min(target, root._clampUi(nowUi + maxJump))
    else target = Math.max(target, root._clampUi(nowUi - maxJump))
    root._coalescedLocalSeekDirection = dir
    root._coalescedLocalSeekTargetUiMs = target
    root.lastUiTargetMs = target
    root.showScrubPreview(target)
    // Throttle, pas debounce : le timer ne redemarre pas a chaque repeat.
    // Il doit pouvoir produire des frames pendant un maintien continu.
    if (!timer.running) timer.start()
    return true
}

function flushCoalescedLocalSeek(root) {
    if (!root._coalescedLocalSeekEligible()) {
        root._cancelCoalescedLocalSeek();
        return
    }
    var target = root._coalescedLocalSeekTargetUiMs
    root._coalescedLocalSeekTargetUiMs = -1
    root._coalescedLocalSeekDirection = 0
    if (target < 0) return
    root._localSeekTo(target, "coalesced-directplay")
}

function commitScrub(root, mp, subtitleItem) {
    if (!root.scrubActive) return
    var target = (root.scrubAccumUiMs >= 0) ? root.scrubAccumUiMs : root._scrubCommitTargetUiMs
    if (target < 0) target = (root.lastUiTargetMs >= 0 ? root.lastUiTargetMs : root.uiPositionMs())
    target = root._clampUi(target)
    // Un choix audio effectué pendant la fenêtre de scrub doit être appliqué
    // avec CE target final. L'ancienne implémentation remplissait ces champs
    // sans jamais les consommer, d'où un premier choix parfois "avalé".
    var pendingAudioStream = root._pendingAudioStream
    var pendingAudioIndex = root._pendingAudioIndex
    var pendingAudioManualDirectPlay = root._pendingAudioManualDirectPlay
    var hasPendingAudio = pendingAudioStream !== root.snt && pendingAudioIndex >= 0
    root._pendingAudioStream = root.snt
    root._pendingAudioIndex = -1
    root._pendingAudioManualDirectPlay = false
    root.scrubActive = false
    root.scrubAccumUiMs = -1
    root._scrubCommitTargetUiMs = -1
    if (subtitleItem) subtitleItem.gateArmed = false
    if (hasPendingAudio) {
        try {
            // Une seule négociation : sélection de piste + reprise à la
            // position de scrub. Si une garde DirectPlay refuse la demande,
            // on retombe simplement sur le seek normal ci-dessous.
            if (TrackSelection.handleAudioPick(root, pendingAudioStream, pendingAudioIndex,
                    pendingAudioManualDirectPlay, target) !== false)
                return
        } catch (eAudio) {}
    }
    if (root._pendingSeekMs >= 0) {
        root._setPendingSeekMs(root._clampUi(target), "commitScrub-existing-pending")
        root.lastUiTargetMs = root._pendingSeekMs
        root.showScrubPreview(root._pendingSeekMs)
        return
    }
    // Un réglage différé embarque dans la négociation du seek : une seule
    // négociation, à la position finale, et la pause reste conservée si le
    // scrub a été lancé depuis une pause.
    if (TrackSelection.seekDeferredReload(root, mp, target, "commitScrub", root._wasPlayingBeforeSwitch))
        return
    if (root.shouldNetworkSeek()) {
        root._resumeWantedAfterNegotiation = root._wasPlayingBeforeSwitch
        root._serverSeekFallback(target, "commitScrub")
    } else {
        root._localSeekTo(target, "commitScrub")
        if (root._wasPlayingBeforeSwitch) mp.play()
    }
}

function seekBy(root, mp, timers, subtitleItem, deltaMs) {
    if (root._transportLocked("seekBy")) return
    var d = root.durationMs();
    if (d <= 0) d = 24 * 3600 * 1000
    var nowUi = root.uiPositionMs()
    if (root._pendingSeekMs >= 0) {
        var base = (root._pendingSeekMs >= 0) ? root._pendingSeekMs : nowUi
        var targetUi = root._clampUi(base + deltaMs)
        root._setPendingSeekMs(targetUi, "seekBy-existing-pending")
        root.lastUiTargetMs = targetUi
        root.showScrubPreview(targetUi)
        return
    }
    if (root.shouldNetworkSeek()) {
        root._cancelCoalescedLocalSeek()
        if (!root.scrubActive) {
            root.scrubActive = true
            if (subtitleItem) subtitleItem.gateArmed = true
            root._wasPlayingBeforeSwitch = (mp.playbackState === root._mpPlayingState)
            mp.pause()
        }
        var base2 = (root.scrubAccumUiMs >= 0 ? root.scrubAccumUiMs : nowUi)
        root.scrubAccumUiMs = root._clampUi(base2 + deltaMs)
        root._scrubCommitTargetUiMs = root.scrubAccumUiMs
        root.lastUiTargetMs = root.scrubAccumUiMs
        root.showScrubPreview(root.scrubAccumUiMs)
        timers.scrubCommit.restart()
        return
    }
    if (root._queueCoalescedLocalSeek(deltaMs)) return
    root._localSeekTo(nowUi + deltaMs, "seekBy")
}
