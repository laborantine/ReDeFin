.pragma library
.import "JellyfinPlaybackRouter.js" as PlaybackRouter
.import "LocalTextSubtitles.js" as LocalTextSubtitles

// Choix utilisateur du lecteur : pistes, sortie audio, qualité et attentes en pause.
// L'état reste sur root ; aucune session, horloge ou instance MediaPlayer n'est créée.
// API : refreshStreams / syncTrackMenuIndexes ; handleAudio* / handleSubs* ;
// apply*Quality / quality* ; decide* / *DeferredReload ; makeNegotiationContext
// et applyStickyManual* pour le raccord de négociation.
// Les politiques matérielles et les fallbacks restent dans le backend / PlayerSession.

var _K_AUDIO = "audio",
    _K_SUBTITLE = "subtitle",
    _K_QUALITY = "quality",
    _K_OUTPUT = "audioOutput";
var _Q_AUTO = -3,
    _Q_NONE = 0;

function _s(v) {
    return (v === undefined || v === null) ? "" : (v + "");
}

function _numberOr(value, fallback) {
    var n = Number(value);
    return isFinite(n) ? n : fallback;
}

function _poNowMs() {
    return Date.now ? Date.now() : (new Date()).getTime();
}

// Contexte et inventaire des pistes.
function makeNegotiationContext(core, state, startMs, reneg) {
    reneg = reneg || {};
    return {
        serverUrl: core.serverUrl,
        accessToken: core.accessToken,
        userId: core.userId,
        itemId: core.itemId,
        audioOutputMode: core.audioOutputMode || "multichannel",
        audioSourceBitrateHint: _audioSourceBitrateHint(core, state),
        selectedAudioStream: (typeof state.selectedAudioStream === "number" ? state.selectedAudioStream : -1),
        selectedSubtitleStream: (typeof state.selectedSubtitleStream === "number" ? state.selectedSubtitleStream : -1),
        useLocalSubs: !!state.useLocalSubs,
        startMs: startMs || 0,
        forceHls: !!reneg.forceHls,
        forceMp4: !!reneg.forceMp4,
        preferTicks: !!reneg.preferTicks,
        forceDPOnAudioSwitch: !!reneg.forceDPOnAudioSwitch,
        forceSubtitleEncode: !!reneg.forceSubtitleEncode,
        preferImageSubtitleRemux: !!reneg.preferImageSubtitleRemux,
        forceRetry: !!reneg.forceRetry,
        forceServerSeek: !!reneg.forceServerSeek,
        forceHlsOnDpSeekFallback: !!reneg.forceHlsOnDpSeekFallback,
        forceServerRemux: !!reneg.forceServerRemux,
        forceFullRemuxForImageSubtitles: !!reneg.forceFullRemuxForImageSubtitles,
        selectedSubtitleIsText: reneg.selectedSubtitleIsText === true,
        selectedSubtitleIsImage: reneg.selectedSubtitleIsImage === true,
        // Par défaut, un sous-titre texte géré par le serveur doit rester dans
        preferExternalTextSubtitlesInRemux: reneg.preferExternalTextSubtitlesInRemux === true,
        forceTextSubtitleServerBurnIn: reneg.forceTextSubtitleServerBurnIn === true,
        preferServerSubtitleBurnInOnVideoTranscode: reneg.preferServerSubtitleBurnInOnVideoTranscode === true,
        forceHevcMain10Remux: !!reneg.forceHevcMain10Remux,
        forceAllowTranscoding: !!reneg.forceAllowTranscoding,
        forceVideoTranscodeCodec: reneg.forceVideoTranscodeCodec || null,
        forceDvdSubFileTranscode: !!reneg.forceDvdSubFileTranscode,
        forceInterlacedTsTranscode: !!reneg.forceInterlacedTsTranscode,
        preferFrenchAudio: reneg.preferFrenchAudio === false ? false : true,
        disableAutoFrenchAudio: !!reneg.disableAutoFrenchAudio,
        disableAutoVoFrenchFullSubtitle: (reneg.disableAutoVoFrenchFullSubtitle !== undefined) ?
            !!reneg.disableAutoVoFrenchFullSubtitle :
            !!state.disableAutoVoFrenchFullSubtitle,
        disableDefaultSubtitleRemux: !!reneg.disableDefaultSubtitleRemux,
        disableDefaultFrenchAudioOrderRemux: !!reneg.disableDefaultFrenchAudioOrderRemux,
        disableImageSubtitleRiskRemux: !!reneg.disableImageSubtitleRiskRemux,
        disableHevcMain10MkvRemux: !!reneg.disableHevcMain10MkvRemux,
        manualDirectPlayOverride: !!reneg.manualDirectPlayOverride,
        manualRemuxOverride: !!reneg.manualRemuxOverride,
        // Qualité manuelle : ces valeurs sont aussi réinjectées centralement
        forcePolicyTranscodeVideoBitrate: Number(reneg.forcePolicyTranscodeVideoBitrate || 0),
        forcePolicyTranscodeHls: reneg.forcePolicyTranscodeHls,
        forcePolicyTranscodeHlsColdStart: reneg.forcePolicyTranscodeHlsColdStart,
        forcePolicyTranscodeAllowAudioCopy: reneg.forcePolicyTranscodeAllowAudioCopy,
        preferredContainer: state.preferredContainer || null
    };
}

function indexForStream(map, stream) {
    if (!map || typeof map.length !== "number") return -1;
    for (var i = 0; i < map.length; i++)
        if (Number(map[i]) === Number(stream)) return i;
    return -1;
}

function _audioSourceBitrateHint(root, state) {
    if (!root) return 0;
    var map = root.audioStreamIndexMap || [];
    var bitrates = root.audioBitrateMap || [];
    var stream = -1;
    try {
        if (state && typeof state.selectedAudioStream === "number" && state.selectedAudioStream >= 0)
            stream = state.selectedAudioStream;
        else if (typeof root.effectiveAudioStream === "number" && root.effectiveAudioStream >= 0)
            stream = root.effectiveAudioStream;
    } catch (e0) {
        stream = -1;
    }
    var idx = stream >= 0 ? indexForStream(map, stream) : -1;
    if (idx < 0) {
        var ui = Number(root.audioIndex || 0);
        idx = isFinite(ui) ? Math.max(0, Math.floor(ui)) : 0;
    }
    if (idx < 0 || idx >= bitrates.length) return 0;
    var n = Number(bitrates[idx] || 0);
    return (isFinite(n) && n > 0) ? Math.floor(n) : 0;
}

function syncTrackMenuIndexes(root, audioItem, subItem) {
    var aStream = root.selectedAudioStream >= 0 ? root.selectedAudioStream : root.effectiveAudioStream;
    var ai = aStream >= 0 ? indexForStream(root.audioStreamIndexMap, aStream) : 0;
    ai = root.audioTracks && root.audioTracks.length ? Math.max(0, Math.min(ai < 0 ? 0 : ai, root.audioTracks.length - 1)) : 0;
    var sStream = root.useLocalSubs && root.localSubStreamIndex >= 0 ? root.localSubStreamIndex :
        (root.selectedSubtitleStream >= 0 ? root.selectedSubtitleStream : root.effectiveSubtitleStream);
    var si = sStream >= 0 ? indexForStream(root.subtitleStreamIndexMap, sStream) : 0;
    si = root.subtitleTracks && root.subtitleTracks.length ? Math.max(0, Math.min(si < 0 ? 0 : si, root.subtitleTracks.length - 1)) : 0;
    if (root.audioIndex !== ai) root.audioIndex = ai;
    if (root.subtitleIndex !== si) root.subtitleIndex = si;
    try {
        if (audioItem) {
            audioItem.currentIndex = ai;
            if (audioItem.syncIndex) audioItem.syncIndex();
        }
    } catch (e0) {}
    try {
        if (subItem) {
            subItem.currentIndex = si;
            if (subItem.syncIndex) subItem.syncIndex();
        }
    } catch (e1) {}
}

function cancelLocalSubtitleRequest(root, reason) {
    if (!root) return false;
    var handle = null;
    try {
        handle = root._localSubtitleRequestHandle;
    } catch (e0) {
        handle = null;
    }
    try {
        root._localSubtitleRequestHandle = null;
    } catch (e1) {}
    if (!handle || typeof handle.cancel !== "function") return false;
    try {
        return handle.cancel(reason || "superseded") !== false;
    } catch (e2) {}
    return false;
}

function disableLocalSubsOverlay(root, item, audioItem, subItem) {
    cancelLocalSubtitleRequest(root, "local-subtitles-disabled");
    root.useLocalSubs = false;
    root.localCues = [];
    root.localSubStreamIndex = -1;
    root._lastSubsUiPushMs = -1;
    if (item) {
        item.cues = [];
        item.enabled = false;
    }
    syncTrackMenuIndexes(root, audioItem, subItem);
}

function tryAutoLocalizeAfterDP(root, item) {
    if (root._autoLocalizeSubStream < 0 || !PlaybackRouter.isPureDirectPlay(root)) {
        root._autoLocalizeSubStream = -1;
        return;
    }
    var stream = root._autoLocalizeSubStream;
    root._autoLocalizeSubStream = -1;
    root.loadLocalSubtitleByStreamIndex(stream, function(ok) {
        if (!ok) return;
        root.selectedSubtitleStream = -1;
        var idx = root.listIndexForStream(stream);
        root.subtitleIndex = idx < 0 ? 0 : idx;
        if (item) {
            item.cues = root.localCues;
            item.enabled = root.localCues.length > 0;
        }
    });
}

function streamsKeyForCurrent(root) {
    return (root.serverUrl || "") + "|" + (root.itemId || "");
}

function flushStreamsWaiters(root, ok) {
    var w = root._streamsWaiters || [];
    root._streamsWaiters = [];
    for (var i = 0; i < w.length; i++) try {
        if (typeof w[i] === "function") w[i](ok === true);
    } catch (e) {}
}

function _subtitleOffLabel(label) {
    var s = _s(label).toLowerCase().trim();
    return s === "aucun" || s === "désactivé" || s === "desactive" || s === "disabled" || s === "off" || s === "none" || s === "no subtitles";
}

function _looksTextSubtitleLabel(label) {
    var s = _s(label).toLowerCase();
    return s.indexOf("srt") >= 0 || s.indexOf("subrip") >= 0 ||
        s.indexOf("webvtt") >= 0 || s.indexOf("vtt") >= 0 ||
        s.indexOf("ass") >= 0 || s.indexOf("ssa") >= 0 ||
        s.indexOf("texte") >= 0 || s.indexOf("text") >= 0;
}

function _normalizeSubtitleTables(labels, map, isText, codecs) {
    labels = labels && typeof labels.length === "number" ? labels.slice(0) : [];
    map = map && typeof map.length === "number" ? map.slice(0) : [];
    isText = isText && typeof isText.length === "number" ? isText.slice(0) : [];
    codecs = codecs && typeof codecs.length === "number" ? codecs.slice(0) : [];
    // Contrat ReDeFin côté PlayerOverlay :
    // - subtitleStreamIndexMap contient toujours l'entrée 0 = -1 pour « Aucun » ;
    // - subtitleIsTextMap est aligné sur subtitleStreamIndexMap ;
    // - subtitleTracks ne contient PAS l'entrée « Aucun » et correspond à map[1..].
    if (labels.length > 0 && _subtitleOffLabel(labels[0]))
        labels.shift();
    if (map.length === 0 || Number(map[0]) !== -1)
        map.unshift(-1);
    if (isText.length === map.length - 1)
        isText.unshift(false);
    else if (isText.length === labels.length)
        isText = [false].concat(isText);
    else if (isText.length === 0)
        isText = [false];
    while (isText.length < map.length) {
        var labelIndex = isText.length - 1;
        isText.push(labelIndex >= 0 && labelIndex < labels.length ? _looksTextSubtitleLabel(labels[labelIndex]) : false);
    }
    if (isText.length > map.length)
        isText = isText.slice(0, map.length);
    while (labels.length > Math.max(0, map.length - 1))
        labels.pop();
    // Le codec partage le même index que le stream et le type :
    // case 0 = « Aucun ». Sans cela, la piste MOV_TEXT suivante
    // pourrait être associée à un mauvais codec après normalisation.
    if (codecs.length === map.length - 1)
        codecs.unshift("");
    if (codecs.length === 0)
        codecs.push("");
    while (codecs.length < map.length)
        codecs.push("");
    if (codecs.length > map.length)
        codecs.length = map.length;
    codecs[0] = "";
    for (var ci = 1; ci < codecs.length; ++ci) {
        var normalizedCodec = _s(codecs[ci]).toLowerCase();
        codecs[ci] = normalizedCodec === "tx3g" ? "mov_text" : normalizedCodec;
    }
    return {
        labels: labels,
        map: map,
        isText: isText,
        codecs: codecs
    };
}

function refreshStreams(root, router, done) {
    if (!root.serverUrl || !root.accessToken || !root.itemId) {
        if (typeof done === "function") done(false);
        return;
    }
    var key = streamsKeyForCurrent(root);
    if (typeof done === "function") {
        if (root._streamsReadyKey === key) {
            done(true);
            return;
        }
        if (root._streamsLoadingKey === key) {
            var q = root._streamsWaiters || [];
            q.push(done);
            root._streamsWaiters = q;
            return;
        }
    } else if (root._streamsLoadingKey === key) {
        return;
    }
    var item = root.itemId,
        server = root.serverUrl,
        token = root.accessToken,
        seq = ++root._streamsSeq;
    root._streamsLoadingKey = key;
    root._streamsReadyKey = "";
    if (typeof done === "function") {
        var list = root._streamsWaiters || [];
        list.push(done);
        root._streamsWaiters = list;
    } else root._streamsWaiters = [];
    router.fetchStreams(server, token, item, function(res) {
        if (seq !== root._streamsSeq || item !== root.itemId || server !== root.serverUrl || token !== root.accessToken) {
            return;
        }
        root._streamsLoadingKey = "";
        root._streamsReadyKey = key;
        root.runtimeTicks = res.runtimeTicks || 0;
        root.itemChapters = res.chapters !== undefined ? res.chapters : null;
        root._chaptersItemId = item;
        root.audioTracks = res.audioLabels || [];
        root.audioStreamIndexMap = res.audioMap && res.audioMap.length ? res.audioMap : [];
        root.audioCodecMap = res.audioCodecMap && res.audioCodecMap.length ? res.audioCodecMap : [];
        root.audioChannelMap = res.audioChannelMap && res.audioChannelMap.length ? res.audioChannelMap : [];
        root.audioBitrateMap = res.audioBitrateMap && res.audioBitrateMap.length ? res.audioBitrateMap : [];
        var subTables = _normalizeSubtitleTables(res.subtitleLabels || [], res.subtitleMap || [],
            res.subtitleIsText || [], res.subtitleCodecMap || []);
        root.subtitleTracks = subTables.labels;
        root.subtitleStreamIndexMap = subTables.map;
        root.subtitleIsTextMap = subTables.isText;
        root.subtitleCodecMap = subTables.codecs;
        root.firstAudioStreamIndex =
            (typeof res.firstAudioStreamIndex === "number") ?
            res.firstAudioStreamIndex : -1;
        root.bestFrenchAudioStreamIndex =
            (typeof res.bestFrenchAudioStreamIndex === "number") ?
            res.bestFrenchAudioStreamIndex : -1;
        root.preferredFrenchAudioNeedsServerSelection =
            res.preferredFrenchAudioNeedsServerSelection === true;
        root.firstInternalSubtitleStreamIndex =
            (typeof res.firstInternalSubtitleStreamIndex === "number") ?
            res.firstInternalSubtitleStreamIndex : -1;
        root.preferredFrenchForcedSubtitleNeedsServerSelection =
            res.preferredFrenchForcedSubtitleNeedsServerSelection === true;
        root.strictFrenchAutoDirectPlayEligible = res.strictFrenchAutoDirectPlayEligible === true;
        root.hasPriorityInternalSubtitleRisk = res.hasPriorityInternalSubtitleRisk === true;
        root.hasImplicitFirstInternalSubtitleRisk = res.hasImplicitFirstInternalSubtitleRisk === true;
        root.hasInternalDvdSubtitle = res.hasInternalDvdSubtitle === true;
        root.isDvdSource = res.isDvdSource === true;
        root.requiresInterlacedTsTranscode = res.requiresInterlacedTsTranscode === true;
        root.safeFrenchForcedDvdSubtitleStream =
            (typeof res.safeFrenchForcedDvdSubtitleStreamIndex === "number") ?
            res.safeFrenchForcedDvdSubtitleStreamIndex : -1;
        root.strictFrenchForcedDefaultTextSubtitleStream =
            (typeof res.strictFrenchForcedDefaultTextSubtitleStreamIndex === "number") ?
            res.strictFrenchForcedDefaultTextSubtitleStreamIndex : -1;
        root.legacyFrenchForcedTextSubtitleStream =
            (typeof res.legacyFrenchForcedTextSubtitleStreamIndex === "number") ?
            res.legacyFrenchForcedTextSubtitleStreamIndex : -1;
        root._syncTrackMenuIndexes("refreshStreams");
        root.updateClocksFromPlayback();
        flushStreamsWaiters(root, true);
    }, function(err) {
        if (seq !== root._streamsSeq || item !== root.itemId || server !== root.serverUrl || token !== root.accessToken) {
            return;
        }
        root._streamsLoadingKey = "";
        root._streamsReadyKey = key;
        root.itemChapters = null;
        root._chaptersItemId = item;
        flushStreamsWaiters(root, false);
    });
}

function loadLocalSubtitleForOverlay(root, bridge, item, streamIdx, cb, preserve) {
    function fail(reason) {
        if (preserve !== true) disableLocalSubsOverlay(root, item, null, null);
        if (cb) cb(false, reason || "load_failed");
    }
    if (!root.serverUrl || !root.accessToken || !root.itemId || !root.currentMediaSourceId) {
        fail("ctx");
        return null;
    }
    cancelLocalSubtitleRequest(root, "superseded");
    var controller = null;
    controller = LocalTextSubtitles.loadLocalSubtitleByStreamIndex(root.serverUrl, root.accessToken, root.itemId,
        root.currentMediaSourceId, streamIdx,
        function(ok, payload) {
            if (root._localSubtitleRequestHandle === controller)
                root._localSubtitleRequestHandle = null;
            if (!ok || !payload || !payload.cues || payload.cues.length === 0) {
                fail(payload || "empty_cues");
                return;
            }
            root.localCues = payload.cues;
            root.localSubFormat = payload.format || "";
            root.localSubStreamIndex = streamIdx;
            root.useLocalSubs = true;
            if (item) {
                item.cues = root.localCues;
                item.enabled = true;
            }
            root._syncTrackMenuIndexes("local-sub-loaded");
            if (cb) cb(true, payload);
        }, {
            requestFn: bridge.sendRequest,
            bridge: bridge,
            accessToken: root.accessToken
        });
    root._localSubtitleRequestHandle = controller;
    try {
        if (controller && typeof controller.isActive === "function" && !controller.isActive())
            root._localSubtitleRequestHandle = null;
    } catch (e0) {}
    return controller;
}

function _manualRemuxExtra(root) {
    if (!root || root.manualRemuxMode !== true)
        return {}
    return {
        manualRemuxOverride: true,
        forceDvdSubFileTranscode: false,
        forceInterlacedTsTranscode: false,
        forcePlaybackInfoVideoCodec: null,
        forceVideoStreamCopyInPlaybackInfo: true,
        forceAudioStreamCopyInPlaybackInfo: true,
        disableImageSubtitleRiskRemux: true,
        disableHevcMain10MkvRemux: true,
        disableDefaultSubtitleRemux: true,
        forceTextSubtitleServerBurnIn: false,
        preferServerSubtitleBurnInOnVideoTranscode: false,
        preferExternalTextSubtitlesInRemux: false
    }
}

function _mergeExtra(base, add) {
    var out = {}
    var k
    base = base || {}
    add = add || {}
    for (k in base) out[k] = base[k]
    for (k in add) out[k] = add[k]
    return out
}

function _audioSelection(stream, ui, manualDp) {
    return {
        kind: _K_AUDIO,
        stream: Math.floor(_numberOr(stream, -1)),
        uiIndex: Math.floor(_numberOr(ui, -1)),
        manualDirectPlay: manualDp === true
    };
}

function _subtitleSelection(stream, ui) {
    return {
        kind: _K_SUBTITLE,
        stream: Math.floor(_numberOr(stream, -1)),
        uiIndex: Math.floor(_numberOr(ui, -1))
    };
}

function _qualitySelection(value) {
    return {
        kind: _K_QUALITY,
        value: Math.floor(_numberOr(value, _Q_NONE))
    };
}

function _sameSelection(a, b) {
    if (!a || !b || a.kind !== b.kind) return false;
    if (a.kind === _K_OUTPUT) return a.mode === b.mode;
    if (a.kind === _K_QUALITY) return a.value === b.value && a.value !== _Q_NONE;
    return a.uiIndex >= 0 && a.uiIndex === b.uiIndex;
}

function currentAudioSelection(root) {
    var ui = -1;
    try {
        ui = root._effectiveAudioUiIndexForSettings();
    } catch (e0) {}
    var stream = root.selectedAudioStream >= 0 ? root.selectedAudioStream : root.effectiveAudioStream;
    return _audioSelection(stream, ui, root.manualDirectPlayMode === true);
}

function currentSubtitleSelection(root) {
    var ui = -1;
    try {
        ui = root._effectiveSubtitleUiIndexForSettings();
    } catch (e0) {}
    var stream = root.useLocalSubs && root.localSubStreamIndex >= 0 ?
        root.localSubStreamIndex :
        (root.selectedSubtitleStream >= 0 ? root.selectedSubtitleStream : root.effectiveSubtitleStream);
    return _subtitleSelection(stream, ui);
}

function currentQualitySelection(root) {
    var value = _Q_AUTO;
    try {
        value = root._activeQualityChoiceValue();
    } catch (e0) {}
    return _qualitySelection(value);
}

function deferredReloadState(root) {
    if (!root._deferredReloadState)
        root._deferredReloadState = {
            audio: null,
            subtitle: null,
            quality: null,
            audioOutput: null
        };
    return root._deferredReloadState;
}

function _deferredPauseActive(root) {
    if (!root || root._deferredReloadReplaying === true ||
        typeof root._deferredReloadPauseActive !== "function") return false;
    try {
        return root._deferredReloadPauseActive() === true;
    } catch (e0) {
        return false;
    }
}

function _setDeferredUi(root, kind, value) {
    if (kind === _K_OUTPUT) {
        root._deferredAudioOutputMode = value ? value.mode : "";
    } else if (kind === _K_AUDIO) root._deferredAudioUiIndex = value ? value.uiIndex : -1;
    else if (kind === _K_SUBTITLE) root._deferredSubtitleUiIndex = value ? value.uiIndex : -1;
    else if (kind === _K_QUALITY) root._deferredQualityValue = value ? value.value : _Q_NONE;
    try {
        root._syncTrackMenuIndexes("deferred-ui");
    } catch (e0) {}
}

function clearDeferredReloadUi(root) {
    if (!root) return false;
    root._deferredAudioOutputMode = "";
    root._deferredAudioUiIndex = -1;
    root._deferredSubtitleUiIndex = -1;
    root._deferredQualityValue = _Q_NONE;
    try {
        root._syncTrackMenuIndexes("deferred-clear");
    } catch (e0) {}
    return true;
}

// Résultat : "noop", "applyNow" ou "defer". Les choix en pause
// sont enregistrés sur root puis fusionnés dans une seule négociation.
function decideSettingChange(root, pick, active) {
    if (!root || !pick) return "noop";
    if (root._deferredReloadReplaying === true) {
        return "applyNow";
    }
    var state = deferredReloadState(root),
        kind = pick.kind;
    var pending = state[kind] || null;
    var paused = _deferredPauseActive(root),
        sameActive = _sameSelection(pick, active);
    if (!paused) {
        if (pending) {
            state[kind] = null;
            _setDeferredUi(root, kind, null);
        }
        var immediateDecision = sameActive && !pending ? "noop" : "applyNow";
        return immediateDecision;
    }
    if (sameActive) {
        if (pending) {
            state[kind] = null;
            _setDeferredUi(root, kind, null);
            _refreshDeferredPrefetch(root, "cancel-active");
            return "cancelPending";
        }
        return "noop";
    }
    if (pending && _sameSelection(pick, pending)) {
        return "noop";
    }
    state[kind] = pick;
    _setDeferredUi(root, kind, pick);
    _refreshDeferredPrefetch(root, "defer-" + kind);
    return "defer";
}

function decideQualityChoice(root, requested) {
    var pick = _qualitySelection(requested);
    return pick.value === _Q_NONE ? "noop" :
        decideSettingChange(root, pick, currentQualitySelection(root));
}

function cancelDeferredReload(root, kind, reason) {
    if (!root) return false;
    var state = deferredReloadState(root);
    if (!state[kind]) return false;
    state[kind] = null;
    _setDeferredUi(root, kind, null);
    _refreshDeferredPrefetch(root, reason || "cancel");
    return true;
}

function resetDeferredReload(root, reason) {
    if (!root) return false;
    root._deferredReloadState = {
        audio: null,
        subtitle: null,
        quality: null,
        audioOutput: null
    };
    clearDeferredReloadUi(root);
    try {
        if (typeof root._invalidateDeferredPrefetch === "function")
            root._invalidateDeferredPrefetch(reason || "reset");
    } catch (e0) {}
    return true;
}

function _pendingPicks(root) {
    var state = deferredReloadState(root),
        picks = [];
    if (state.audioOutput) picks.push({
        kind: _K_OUTPUT,
        value: state.audioOutput
    });
    if (state.audio) picks.push({
        kind: _K_AUDIO,
        value: state.audio
    });
    if (state.subtitle) picks.push({
        kind: _K_SUBTITLE,
        value: state.subtitle
    });
    if (state.quality) picks.push({
        kind: _K_QUALITY,
        value: state.quality
    });
    return picks;
}

function deferredPrefetchKey(root) {
    if (!root) return "";
    var state = deferredReloadState(root),
        audio = state.audio,
        subtitle = state.subtitle;
    if (state.audioOutput || state.quality || (!audio && !subtitle) ||
        (audio && audio.manualDirectPlay === true)) return "";
    return [
        String(root.itemId || ""), String(root.serverUrl || ""), String(root.userId || ""),
        audio ? ("a:" + audio.stream + ":" + audio.uiIndex) : "a:-",
        subtitle ? ("s:" + subtitle.stream + ":" + subtitle.uiIndex) : "s:-",
        "ca:" + root.selectedAudioStream, "cs:" + root.selectedSubtitleStream,
        "ls:" + root.localSubStreamIndex, "ul:" + (root.useLocalSubs ? 1 : 0),
        "mr:" + (root.manualRemuxMode ? 1 : 0),
        "mq:" + Math.max(0, Math.floor(_numberOr(root.manualQualityBitrate, 0))),
        "output:" + String(root.audioOutputMode || "multichannel"),
        "rule:" + String(root.playbackRuleMode || "smart"),
        "dev:" + String(root.playbackDeviceMode || ""),
        "back:" + String(root.playbackBackendMode || ""),
        "hls:" + (root.isHls ? 1 : 0), "tc:" + (root.lastUsedTranscoding ? 1 : 0),
        "rmx:" + (root.lastUsedServerRemux ? 1 : 0),
        "policy:" + (root.currentPlaybackVideoTranscodeByPolicy ? 1 : 0)
    ].join("|");
}

function _refreshDeferredPrefetch(root, reason) {
    if (!root || root._deferredReloadReplaying === true) return false;
    var key = deferredPrefetchKey(root);
    try {
        if (key && typeof root._scheduleDeferredPrefetch === "function")
            return root._scheduleDeferredPrefetch(reason || "change");
        if (typeof root._invalidateDeferredPrefetch === "function")
            root._invalidateDeferredPrefetch(reason || "none");
    } catch (e0) {}
    return false;
}

function prefetchDeferredReload(root, router, requestSeq) {
    if (!root || !router || typeof router.negotiatePlayback !== "function" ||
        root._tearingDownPlayer || !_deferredPauseActive(root) ||
        requestSeq !== root._deferredPrefetchSeq) return false;
    var key = deferredPrefetchKey(root);
    if (!key) return false;
    var state = deferredReloadState(root),
        audioPick = state.audio,
        subtitlePick = state.subtitle;
    var audio = root.selectedAudioStream,
        subtitle = root.selectedSubtitleStream;
    var useLocal = root.useLocalSubs === true,
        extra = {};
    if (audioPick) {
        if (!(audioPick.stream >= 0) || audioPick.manualDirectPlay === true) return false;
        audio = audioPick.stream;
        if (useLocal && root.localSubStreamIndex >= 0) {
            subtitle = root.localSubStreamIndex;
            useLocal = false;
        }
        extra = _mergeExtra(extra, {
            forceServerSeek: false,
            forceServerRemux: true,
            forceRetry: true,
            forceDirectPlayInPlaybackInfo: false,
            forceDirectStreamInPlaybackInfo: false,
            forceVideoStreamCopyInPlaybackInfo: true,
            forceAudioStreamCopyInPlaybackInfo: true,
            forceExplicitServerProgressiveSeek: false,
            forceJellyfinTranscodingUrlCopyRemux: false,
            forcePlaybackInfoAudioStreamIndex: audio
        });
    }
    if (subtitlePick) {
        subtitle = subtitlePick.stream;
        useLocal = false;
        var type = subtitleTypeForStream(root, subtitle);
        extra = _mergeExtra(extra, {
            forceServerSeek: false,
            forceServerRemux: true,
            forceRetry: true,
            forceDirectPlayInPlaybackInfo: false,
            forceDirectStreamInPlaybackInfo: false,
            forceVideoStreamCopyInPlaybackInfo: true,
            forceAudioStreamCopyInPlaybackInfo: true,
            forceExplicitServerProgressiveSeek: false,
            forceJellyfinTranscodingUrlCopyRemux: false,
            forceSubtitleEncode: false,
            forceTextSubtitleServerBurnIn: false,
            preferServerSubtitleBurnInOnVideoTranscode: false,
            preferExternalTextSubtitlesInRemux: false,
            preferImageSubtitleRemux: type === "image",
            forceFullRemuxForImageSubtitles: false,
            disableDefaultSubtitleRemux: true,
            disableAutoVoFrenchFullSubtitle: !(subtitle >= 0)
        });
    }
    extra = _mergeExtra(extra, _manualRemuxExtra(root));
    var start = 0;
    try {
        start = Math.max(0, Math.floor(_numberOr(root.keepUi(), 0)));
    } catch (e0) {
        try {
            start = Math.max(0, Math.floor(_numberOr(root.uiPositionMs(), 0)));
        } catch (e1) {}
    }
    var ctx = makeNegotiationContext(root, {
        selectedAudioStream: audio,
        selectedSubtitleStream: subtitle,
        useLocalSubs: useLocal,
        disableAutoVoFrenchFullSubtitle: subtitlePick ? !(subtitle >= 0) :
            root.disableAutoVoFrenchFullSubtitle === true
    }, start, {
        preferTicks: true
    });
    copyNegotiationOptions(ctx, extra);
    ctx.serverUrl = String(root.serverUrl || "");
    ctx.accessToken = String(root.accessToken || "");
    ctx.userId = String(root.userId || "");
    ctx.itemId = String(root.itemId || "");
    ctx.startMs = start;
    ctx.preferTicks = true;
    ctx.selectedAudioStream = audio;
    ctx.selectedSubtitleStream = subtitle;
    ctx.useLocalSubs = useLocal;
    var streamType = subtitleTypeForStream(root, subtitle);
    if (extra.selectedSubtitleIsText === undefined) ctx.selectedSubtitleIsText = streamType === "text";
    if (extra.selectedSubtitleIsImage === undefined) ctx.selectedSubtitleIsImage = streamType === "image";
    if (extra.currentPlaybackVideoTranscodeByPolicy === undefined)
        ctx.currentPlaybackVideoTranscodeByPolicy = root.currentPlaybackVideoTranscodeByPolicy === true;
    if (!applyStickyManualRemux(root, ctx))
        applyStickyManualQuality(root, ctx);
    ctx.playbackRuleMode = root.playbackRuleMode || "smart";
    ctx.playbackRouterMode = root.playbackDeviceMode || "";
    ctx.playbackRouterBackend = root.playbackBackendMode || "";
    var seq = root._deferredPrefetchSeq;
    try {
        router.negotiatePlayback(ctx, function(res) {
            if (seq !== root._deferredPrefetchSeq || !_deferredPauseActive(root) ||
                deferredPrefetchKey(root) !== key || !res || !res.url) return;
            root._deferredPrefetchResult = {
                key: key,
                result: res,
                startMs: start,
                createdAt: _poNowMs()
            };
        }, function() {});
    } catch (e2) {
        return false;
    }
    return true;
}

function _takeDeferredPrefetch(root, key, start, event) {
    if (!root || event !== "resume" || !key) return null;
    var cached = root._deferredPrefetchResult;
    if (!cached || cached.key !== key || !cached.result || !cached.result.url) return null;
    var ttl = Math.max(5000, Math.floor(_numberOr(root.deferredPrefetchTtlMs, 60000)));
    var age = Math.max(0, _poNowMs() - _numberOr(cached.createdAt, 0));
    var delta = Math.abs(Math.floor(_numberOr(cached.startMs, 0)) -
        Math.floor(_numberOr(start, 0)));
    return age <= ttl && delta <= 1500 ? cached.result : null;
}

function mergeCoalescedNegotiationCall(previous, next) {
    if (!previous) return next;
    if (!next) return previous;
    var merged = {
        startMs: next.startMs,
        forceHls: next.forceHls === true,
        preferTicks: next.preferTicks === true,
        forceMp4: next.forceMp4 === true,
        forceDPOnAudioSwitch: next.forceDPOnAudioSwitch === true,
        extra: {}
    };
    var oldExtra = previous.extra || {},
        newExtra = next.extra || {};
    var keepAudioTransaction = oldExtra.audioSwitchTransaction === true,
        key;
    for (key in oldExtra)
        if (Object.prototype.hasOwnProperty.call(oldExtra, key)) merged.extra[key] = oldExtra[key];
    for (key in newExtra) {
        if (!Object.prototype.hasOwnProperty.call(newExtra, key)) continue;
        if (keepAudioTransaction && (key === "audioSwitchTransaction" ||
                key.indexOf("previous") === 0)) continue;
        merged.extra[key] = newExtra[key];
    }
    return merged;
}

function coalesceNegotiationIfActive(root, startMs, forceHls, preferTicks,
    forceMp4, forceDPOnAudioSwitch, extra) {
    if (!root || root._coalescedNegotiationActive !== true) return false;
    root._coalescedNegotiationCall = mergeCoalescedNegotiationCall(root._coalescedNegotiationCall, {
        startMs: Math.max(0, Math.floor(_numberOr(startMs, 0))),
        forceHls: forceHls === true,
        preferTicks: preferTicks === true,
        forceMp4: forceMp4 === true,
        forceDPOnAudioSwitch: forceDPOnAudioSwitch === true,
        extra: extra || {}
    });
    return true;
}

function beginCoalescedNegotiation(root) {
    root._coalescedNegotiationActive = true;
    root._coalescedNegotiationCall = null;
}

function endCoalescedNegotiation(root) {
    root._coalescedNegotiationActive = false;
    var call = root._coalescedNegotiationCall || null;
    root._coalescedNegotiationCall = null;
    return call;
}

function _replayOneDeferredPick(root, pick) {
    if (!pick || !pick.value) return;
    if (pick.kind === _K_OUTPUT)
        handleAudioOutputPick(root, pick.value.mode);
    else if (pick.kind === _K_AUDIO)
        handleAudioPick(root, pick.value.stream, pick.value.uiIndex,
            pick.value.manualDirectPlay === true);
    else if (pick.kind === _K_SUBTITLE)
        switchServerSubtitleStable(root, "deferred-subtitle", pick.value.stream, pick.value.uiIndex);
    else if (pick.kind === _K_QUALITY) {
        try {
            root._applyQualityChoice(pick.value.value);
        } catch (e0) {}
    }
}

function replayDeferredReload(root, mp, options) {
    if (!root || !mp || root._tearingDownPlayer) return false;
    options = options || {};
    var event = options.event === "seek" ? "seek" : "resume";
    var key = deferredPrefetchKey(root),
        snapshot = root._deferredPrefetchResult || null;
    var picks = _pendingPicks(root);
    var keepOutput = event === "seek" && options.forceResume !== true ?
        deferredReloadState(root).audioOutput : null;
    if (keepOutput) picks = picks.filter(function(pick) {
        return pick.kind !== _K_OUTPUT;
    });
    if (!picks.length) return false;
    root._deferredReloadState = {
        audio: null,
        subtitle: null,
        quality: null,
        audioOutput: keepOutput
    };
    clearDeferredReloadUi(root);
    if (keepOutput) _setDeferredUi(root, _K_OUTPUT, keepOutput);
    root._deferredReloadReplaying = true;
    root._forceResumeAfterDeferredReload = options.forceResume === true;
    beginCoalescedNegotiation(root);
    try {
        for (var i = 0; i < picks.length; i++) _replayOneDeferredPick(root, picks[i]);
    } catch (e0) {}
    var call = endCoalescedNegotiation(root);
    var target = Math.floor(_numberOr(options.targetUiMs, -1));
    if (call && root._internalDirectPlayReload !== true) {
        if (target >= 0) _retargetQueuedAudioSwitch(root, target, options.forceResume === true);
        call.extra = _mergeExtra(call.extra, {
            deferredReplay: true
        });
        var start = target >= 0 ? target : call.startMs;
        if (target < 0 && snapshot && root._deferredPrefetchResult === snapshot) {
            var ready = _takeDeferredPrefetch(root, key, start, event);
            if (ready) call.extra = _mergeExtra(call.extra, {
                _prefetchedResult: ready
            });
        }
        try {
            if (typeof root._invalidateDeferredPrefetch === "function")
                root._invalidateDeferredPrefetch("replay");
        } catch (e1) {}
        try {
            root.negotiatePlayback(start, call.forceHls, call.preferTicks,
                call.forceMp4, call.forceDPOnAudioSwitch, call.extra);
        } catch (e2) {}
    }
    root._deferredReloadReplaying = false;
    root._forceResumeAfterDeferredReload = false;
    try {
        root._syncTrackMenuIndexes("deferred-replay");
    } catch (e3) {}
    return true;
}

function resumeDeferredReload(root, mp, reason) {
    return replayDeferredReload(root, mp, {
        event: "resume",
        forceResume: true,
        targetUiMs: -1,
        reason: reason
    });
}

function seekDeferredReload(root, mp, targetUiMs, reason, forceResume) {
    return replayDeferredReload(root, mp, {
        event: "seek",
        forceResume: forceResume === true,
        targetUiMs: targetUiMs,
        reason: reason
    });
}

function _audioSwitchTransactionExtra(root) {
    return {
        audioSwitchTransaction: true,
        previousAudioIndex: root.audioIndex | 0,
        previousAudioOutputMode: root.audioOutputMode || "multichannel",
        previousSelectedAudioStream: (typeof root.selectedAudioStream === "number") ? root.selectedAudioStream : -1,
        previousEffectiveAudioStream: (typeof root.effectiveAudioStream === "number") ? root.effectiveAudioStream : -1,
        previousManualDirectPlayMode: root.manualDirectPlayMode === true,
        previousManualRemuxMode: root.manualRemuxMode === true,
        previousSubtitleIndex: root.subtitleIndex | 0,
        previousSelectedSubtitleStream: (typeof root.selectedSubtitleStream === "number") ? root.selectedSubtitleStream : -1,
        previousEffectiveSubtitleStream: (typeof root.effectiveSubtitleStream === "number") ? root.effectiveSubtitleStream : -1,
        previousUseLocalSubs: root.useLocalSubs === true,
        previousLocalCues: root.localCues || [],
        previousLocalSubFormat: root.localSubFormat || "",
        previousLocalSubStreamIndex: (typeof root.localSubStreamIndex === "number") ? root.localSubStreamIndex : -1,
        previousAutoLocalizeSubStream: (typeof root._autoLocalizeSubStream === "number") ? root._autoLocalizeSubStream : -1,
        previousIsHls: root.isHls === true,
        previousLastUsedTranscoding: root.lastUsedTranscoding === true,
        previousLastUsedDirectStream: root.lastUsedDirectStream === true,
        previousLastUsedServerRemux: root.lastUsedServerRemux === true,
        previousServerTimedStream: root.serverTimedStream === true,
        previousTimeShifted: root.timeShifted === true,
        previousBaseOffsetMs: Math.max(0, Math.floor(Number(root.baseOffsetMs || 0)))
    }
}

function _retargetQueuedAudioSwitch(root, targetUi, resumeOverride) {
    if (targetUi === undefined || targetUi === null) return -1
    var n = Number(targetUi)
    if (!isFinite(n) || isNaN(n) || n < 0) return -1
    var target = root._clampUi(Math.max(0, Math.floor(n)))
    root._trackSwitchAnchorUiMs = target
    root._trackSwitchAnchorWallMs = _poNowMs()
    root._trackSwitchLocalSeekMs = target
    root._trackSwitchRequestedUiMs = target
    root.lastUiTargetMs = target
    if (root._trackSwitchForceLocalSeek) {
        root._trackSwitchVerificationActive = target > 0
        root._trackSwitchTimebaseVerified = !root._trackSwitchVerificationActive
    }
    if (resumeOverride === true) {
        root._trackSwitchWasPlaying = true
        root._wasPlayingBeforeSwitch = true
        root._resumeWantedAfterNegotiation = true
    }
    try {
        root.showScrubPreview(target)
    } catch (e0) {}
    try {
        root._pushLocalSubsUiMs(target, true)
    } catch (e1) {}
    return target
}

function handleAudioOutputPick(root, mode) {
    if (!root || root._tearingDownPlayer) return false;
    mode = mode === "stereo" ? "stereo" : "multichannel";
    var pick = {
        kind: _K_OUTPUT,
        mode: mode
    };
    var active = {
        kind: _K_OUTPUT,
        mode: root.audioOutputMode || "multichannel"
    };
    var outputDecision = decideSettingChange(root, pick, active);
    if (outputDecision !== "applyNow") return true;
    var transaction = _audioSwitchTransactionExtra(root);
    // Chaque choix utilisateur repart du profil serveur AAC-LC 2.0.
    root.audioOutputMode = mode;
    if (mode === "stereo") root.manualDirectPlayMode = false;
    var position = root._beginTrackSwitchRebase("audio-output", false);
    if (root.useLocalSubs && root.localSubStreamIndex >= 0) {
        root.selectedSubtitleStream = root.localSubStreamIndex;
        root.disableLocalSubsOverlay();
    }
    // Ne pas hériter aveuglément du transport HLS utilisé par le downmix 2.0.
    // En revenant vers le multicanal, la policy doit repartir de la source et
    // recalculer le meilleur chemin (souvent DirectPlay), sinon on force un HLS
    // inutile qui peut même réencoder la vidéo et casser la reprise sur Devialet.
    var keepCurrentHls = (mode === "stereo") && root.isHls === true && root.lastUsedTranscoding === true;
    root.negotiatePlayback(position, keepCurrentHls,
        true, false, false, _mergeExtra({
            forceRetry: true,
            trackSwitchRebase: true,
            audioOutputMode: mode
        }, transaction));
    return true;
}

function handleAudioPick(root, streamIdx, uiIdx, explicitManualDirectPlay, targetUiOverride) {
    var k = root.keepUi()
    var serverPick = streamIdx >= 0
    var keepManualRemux = root.manualRemuxMode === true
    var queuedResume = (targetUiOverride !== undefined && targetUiOverride !== null) ?
        root._wasPlayingBeforeSwitch === true : false
    // Remux manuel est actif. Le menu Audio visible ne fabrique plus de ligne Auto.
    if (keepManualRemux && !serverPick) {
        serverPick = true
        streamIdx = -1
    }
    // Après un échec de seek DirectPlay constaté sur ce média, l'entrée Auto
    if (explicitManualDirectPlay !== true && !keepManualRemux && !serverPick &&
        typeof root._guardUnsafeManualDirectPlayRequest === "function" &&
        root._guardUnsafeManualDirectPlayRequest(k, "audio-auto-directplay-unsafe")) {
        root.audioMenuVisible = false
        root.resetControlsTimer()
        return false
    }
    // Pendant un scrub réseau, ne jamais modifier l'état audio "validé" avant
    if (root.scrubActive) {
        root._pendingAudioStream = serverPick ? streamIdx : -1
        root._pendingAudioIndex = uiIdx
        root._pendingAudioManualDirectPlay = explicitManualDirectPlay === true
        root.audioMenuVisible = false
        root.resetControlsTimer()
        return true
    }
    // PlaybackInfo, ni transcodage, ni changement d'état UI. Le rejeu issu du
    if (targetUiOverride === undefined || targetUiOverride === null) {
        var pick = _audioSelection(serverPick ? streamIdx : -1, uiIdx,
            explicitManualDirectPlay === true)
        if (decideSettingChange(root, pick, currentAudioSelection(root)) !== "applyNow") {
            root.audioMenuVisible = false
            root.resetControlsTimer()
            return true
        }
    }
    var transaction = _audioSwitchTransactionExtra(root)
    root.audioIndex = uiIdx
    k = root._beginTrackSwitchRebase("audio", !serverPick)
    var overriddenTarget = _retargetQueuedAudioSwitch(root, targetUiOverride, queuedResume)
    if (overriddenTarget >= 0) k = overriddenTarget
    if (!serverPick) {
        root._autoLocalizeSubStream = -1
        if (root.selectedSubtitleStream >= 0) {
            var li = root.listIndexForStream(root.selectedSubtitleStream)
            if (li >= 0 && li < root.subtitleIsTextMap.length && root.subtitleIsTextMap[li])
                root._autoLocalizeSubStream = root.selectedSubtitleStream
        }
        root.selectedAudioStream = -1
        root.selectedSubtitleStream = -1
        root.effectiveAudioStream = -1
        root.effectiveSubtitleStream = -1
        root.manualDirectPlayMode = true
        root.manualRemuxMode = false
        root.disableLocalSubsOverlay()
        root.audioMenuVisible = false
        root.lastUsedDirectStream = false
        root.lastUsedTranscoding = false
        root.lastUsedServerRemux = false
        root.serverTimedStream = false
        root.timeShifted = false
        var dpExtra = _mergeExtra({
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
            trackSwitchRebase: true
        }, transaction)
        root.negotiatePlayback(k, false, false, false, false, dpExtra)
    } else {
        root.manualDirectPlayMode = false
        // Ne pas effacer manualRemuxMode ici : un changement de piste audio
        // doit conserver le mode Remux choisi dans Qualité vidéo.
        root.selectedAudioStream = streamIdx
        if (root.useLocalSubs && root.localSubStreamIndex >= 0) {
            root.selectedSubtitleStream = root.localSubStreamIndex
            var idx = root.listIndexForStream(root.localSubStreamIndex)
            root.subtitleIndex = idx < 0 ? 0 : idx
            root.disableLocalSubsOverlay()
        }
        root.audioMenuVisible = false
        var extra = _mergeExtra(_mergeExtra({
            trackSwitchRebase: true,
            trackSwitchColdLocalSeek: false,
            trackSwitchLocalStrategy: 0,
            forceExplicitServerProgressiveSeek: false,
            forceJellyfinTranscodingUrlCopyRemux: false,
            forceServerSeek: false,
            forceServerRemux: true,
            forceRetry: true,
            forceDirectPlayInPlaybackInfo: false,
            forceDirectStreamInPlaybackInfo: false,
            forceVideoStreamCopyInPlaybackInfo: true,
            forceAudioStreamCopyInPlaybackInfo: true,
            // Redondant avec selectedAudioStream, volontairement : le POST
            // PlaybackInfo reçoit ainsi toujours l'index explicite même si un
            forcePlaybackInfoAudioStreamIndex: streamIdx
        }, transaction), _manualRemuxExtra(root))
        root.negotiatePlayback(k, false, true, false, false, extra)
    }
    root.resetControlsTimer()
    return true
}

function switchServerSubtitleStable(root, reason, streamIdx, listIdx) {
    // Même règle que pour l'audio : la ligne déjà cochée est un no-op complet.
    if (decideSettingChange(root, _subtitleSelection(streamIdx, listIdx),
            currentSubtitleSelection(root)) !== "applyNow") {
        root.subMenuVisible = false
        root.resetControlsTimer()
        return
    }
    root._localSubtitlePickSeq++
    root.disableLocalSubsOverlay()
    root._autoLocalizeSubStream = -1
    root.subtitleIndex = Math.max(0, listIdx | 0)
    root.selectedSubtitleStream = typeof streamIdx === "number" ? streamIdx : -1
    // Nouvelle sélection explicite = nouveau contrat média. Réinitialiser le
    // budget de recovery afin qu'un échec précédent MOV_TEXT ne bloque pas une
    // piste différente, tout en laissant PlayerSession borner les retries du
    // contrat courant.
    root._mediaErrorRecoveryArmed = false
    root._mediaErrorRecoveryInProgress = false
    root._mediaErrorRecoveryCount = 0
    // Une piste gérée par Jellyfin quitte nécessairement le DirectPlay manuel.
    // Conserver ce marqueur après un PGS/DVDSub rendait le menu Qualité faux :
    // Vitesse voyait bien le remux réel, tandis que Qualité restait sur DP.
    if (root.manualDirectPlayMode === true)
        root.manualDirectPlayMode = false
    if (root && root.hasOwnProperty("disableAutoVoFrenchFullSubtitle"))
        root.disableAutoVoFrenchFullSubtitle = !(typeof streamIdx === "number" && streamIdx >= 0)
    var subtitleType = subtitleTypeForStream(root, streamIdx)
    var isImage = subtitleType === "image"
    root.subMenuVisible = false
    var k = root._beginTrackSwitchRebase(reason || "subsServer", false)
    var extra = _mergeExtra({
        trackSwitchRebase: true,
        trackSwitchColdLocalSeek: false,
        trackSwitchLocalStrategy: 0,
        forceExplicitServerProgressiveSeek: false,
        forceJellyfinTranscodingUrlCopyRemux: false,
        forceServerSeek: false,
        forceServerRemux: true,
        forceRetry: true,
        forceDirectPlayInPlaybackInfo: false,
        forceDirectStreamInPlaybackInfo: false,
        forceVideoStreamCopyInPlaybackInfo: true,
        forceAudioStreamCopyInPlaybackInfo: true,
        forceSubtitleEncode: false,
        forceTextSubtitleServerBurnIn: false,
        preferServerSubtitleBurnInOnVideoTranscode: false,
        preferExternalTextSubtitlesInRemux: false,
        preferImageSubtitleRemux: isImage,
        forceFullRemuxForImageSubtitles: false,
        disableDefaultSubtitleRemux: true,
        disableAutoVoFrenchFullSubtitle: !(typeof streamIdx === "number" && streamIdx >= 0)
    }, _manualRemuxExtra(root))
    root.negotiatePlayback(k, false, true, false, false, extra)
    root.resetControlsTimer()
}

function handleSubsOff(root) {
    // Un overlay QML seul peut fonctionner pendant un Remux ou une lecture HLS.
    // Son arrêt ne doit pas changer l'URL vidéo. Conserver la voie serveur si
    // une piste serveur est encore effectivement sélectionnée.
    var localOverlayOnly = root.useLocalSubs === true &&
        root.localSubStreamIndex >= 0 &&
        root.selectedSubtitleStream < 0 && root.effectiveSubtitleStream < 0;
    if (localOverlayOnly || !root.isDsLike()) {
        // Coupure purement locale : instantanée, même en pause. Elle rend
        // caduque une éventuelle attente de sous-titre serveur.
        cancelDeferredReload(root, _K_SUBTITLE, "subs-off-local");
        root._localSubtitlePickSeq++;
        root.subtitleIndex = 0;
        root.selectedSubtitleStream = -1;
        if (root.hasOwnProperty("disableAutoVoFrenchFullSubtitle")) root.disableAutoVoFrenchFullSubtitle = true;
        root.effectiveSubtitleStream = -1;
        root._autoLocalizeSubStream = -1;
        root.disableLocalSubsOverlay();
        root.subMenuVisible = false;
        root.updateClocksFromPlaybackThrottled(true);
        root.resetControlsTimer();
        return;
    }
    switchServerSubtitleStable(root, "subsOffServer", -1, 0);
}

function handleSubsText(root, item, streamIdx, listIdx) {
    // Les sous-titres texte utilisent l'overlay local lorsqu'ils sont déjà
    // compatibles avec cette voie. MOV_TEXT/TX3G est TOUJOURS local : Jellyfin
    // expose la piste via /Subtitles/.../Stream.vtt, puis ReDeFin garde la vidéo
    // dans son pipeline courant (DirectPlay/remux/transcodage) sans remux MP4.
    var forceLocalMovText = isMovTextSubtitleStream(root, streamIdx)
    var useLocalOverlay = forceLocalMovText || PlaybackRouter.isPureDirectPlay(root)
    if (!useLocalOverlay) {
        switchServerSubtitleStable(root, "subsTextServer", streamIdx, listIdx)
        return
    }

    cancelDeferredReload(root, _K_SUBTITLE, "subs-text-local")
    if (root.hasOwnProperty("disableAutoVoFrenchFullSubtitle"))
        root.disableAutoVoFrenchFullSubtitle = false

    var hadServerSubtitle = root.useLocalSubs !== true &&
        (((typeof root.selectedSubtitleStream === "number") && root.selectedSubtitleStream >= 0) ||
         ((typeof root.effectiveSubtitleStream === "number") && root.effectiveSubtitleStream >= 0))
    var seq = ++root._localSubtitlePickSeq
    var old = {
        index: root.subtitleIndex,
        selected: root.selectedSubtitleStream,
        effective: root.effectiveSubtitleStream,
        local: root.useLocalSubs,
        cues: root.localCues,
        format: root.localSubFormat,
        stream: root.localSubStreamIndex
    }

    root.subMenuVisible = false
    root._pendingSubStream = -1
    root._pendingSubIndex = -1
    root._autoLocalizeSubStream = -1

    root.loadLocalSubtitleByStreamIndex(streamIdx, function(ok) {
        if (seq !== root._localSubtitlePickSeq) return

        if (ok) {
            root.subtitleIndex = listIdx
            // Le serveur ne sélectionne aucune piste : l'overlay QML est la
            // source de vérité pour l'affichage et évite tout double rendu.
            root.selectedSubtitleStream = -1
            root.effectiveSubtitleStream = -1
            root._autoLocalizeSubStream = -1
            root._lastSubsUiPushMs = -1

            if (item) {
                item.cues = root.localCues
                item.enabled = root.localCues.length > 0
                item.gateArmed = root._gateArmed
            }
            root._pushLocalSubsUiMs(root.uiPositionMs(), true)
            root._syncTrackMenuIndexes(forceLocalMovText
                ? "subs-movtext-local-success"
                : "subs-text-local-success")

            // Si une ancienne piste serveur était réellement embarquée, il faut
            // la retirer une fois les cues locales prêtes. On conserve le type de
            // pipeline courant : HLS reste HLS, remux reste progressif.
            if (hadServerSubtitle) {
                var target = root._beginTrackSwitchRebase(
                    forceLocalMovText ? "subsMovTextLocalRebase" : "subsTextLocalRebase",
                    false)
                var keepHls = root.isHls === true
                root.negotiatePlayback(target, keepHls, true, false, false, {
                    trackSwitchRebase: true,
                    forceRetry: true,
                    forceServerRemux: !keepHls && !PlaybackRouter.isPureDirectPlay(root),
                    forceServerSeek: false,
                    disableDefaultSubtitleRemux: true
                })
            }
        } else {
            root.subtitleIndex = old.index
            root.selectedSubtitleStream = old.selected
            root.effectiveSubtitleStream = old.effective
            root.useLocalSubs = old.local
            root.localCues = old.cues
            root.localSubFormat = old.format
            root.localSubStreamIndex = old.stream
            root._lastSubsUiPushMs = -1
            if (item) {
                item.cues = old.cues
                item.enabled = old.local && old.cues && old.cues.length > 0
                item.gateArmed = root._gateArmed
            }
            root._syncTrackMenuIndexes("subs-text-local-restore")
        }
        root.updateClocksFromPlaybackThrottled(true)
        root.resetControlsTimer()
    }, true)
}
function handleSubsImage(root, streamIdx, listIdx) {
    // PGS/VobSub sont bitmap. L'overlay QML actuel accepte uniquement des cues
    // texte SRT/VTT : la piste reste donc gérée par Jellyfin. La policy de la
    // Freebox décide ensuite entre Remux+Embed (codecs déjà compatibles) et
    // Encode/burn-in lorsqu'un vrai transcodage vidéo est nécessaire.
    switchServerSubtitleStable(root, "subsImageServer", streamIdx, listIdx);
}

function copyNegotiationOptions(dst, src) {
    if (!dst || !src) return dst;
    for (var k in src) {
        if (Object.prototype.hasOwnProperty.call(src, k)) dst[k] = src[k];
    }
    return dst;
}

function subtitleTypeForStream(root, streamIdx) {
    var map = root && root.subtitleStreamIndexMap ? root.subtitleStreamIndexMap : [];
    var textMap = root && root.subtitleIsTextMap ? root.subtitleIsTextMap : [];
    for (var i = 0; i < map.length; i++)
        if (Number(map[i]) === Number(streamIdx))
            return textMap[i] === true ? "text" : "image";
    return "unknown";
}

function subtitleCodecForStream(root, streamIdx) {
    var map = root && root.subtitleStreamIndexMap ? root.subtitleStreamIndexMap : [];
    var codecs = root && root.subtitleCodecMap ? root.subtitleCodecMap : [];
    for (var i = 0; i < map.length; i++) {
        if (Number(map[i]) !== Number(streamIdx)) continue;
        var c = i < codecs.length ? _s(codecs[i]).toLowerCase() : "";
        return c === "tx3g" ? "mov_text" : c;
    }
    return "";
}

function isMovTextSubtitleStream(root, streamIdx) {
    var c = subtitleCodecForStream(root, streamIdx);
    return c === "mov_text" || c === "tx3g";
}

function restoreAudioSwitchTransaction(root, extra) {
    if (!root || !extra || extra.audioSwitchTransaction !== true) return false;
    root.audioIndex = Math.max(0, Math.floor(_numberOr(extra.previousAudioIndex, 0)));
    root.audioOutputMode = String(extra.previousAudioOutputMode || "multichannel");
    root.selectedAudioStream = Math.floor(_numberOr(extra.previousSelectedAudioStream, -1));
    root.effectiveAudioStream = Math.floor(_numberOr(extra.previousEffectiveAudioStream, -1));
    root.manualDirectPlayMode = extra.previousManualDirectPlayMode === true;
    root.manualRemuxMode = extra.previousManualRemuxMode === true;
    root.subtitleIndex = Math.max(0, Math.floor(_numberOr(extra.previousSubtitleIndex, 0)));
    root.selectedSubtitleStream = Math.floor(_numberOr(extra.previousSelectedSubtitleStream, -1));
    root.effectiveSubtitleStream = Math.floor(_numberOr(extra.previousEffectiveSubtitleStream, -1));
    root.useLocalSubs = extra.previousUseLocalSubs === true;
    root.localCues = extra.previousLocalCues || [];
    root.localSubFormat = String(extra.previousLocalSubFormat || "");
    root.localSubStreamIndex = Math.floor(_numberOr(extra.previousLocalSubStreamIndex, -1));
    root._autoLocalizeSubStream = Math.floor(_numberOr(extra.previousAutoLocalizeSubStream, -1));
    root.isHls = extra.previousIsHls === true;
    root.lastUsedTranscoding = extra.previousLastUsedTranscoding === true;
    root.lastUsedDirectStream = extra.previousLastUsedDirectStream === true;
    root.lastUsedServerRemux = extra.previousLastUsedServerRemux === true;
    root.serverTimedStream = extra.previousServerTimedStream === true;
    root.timeShifted = extra.previousTimeShifted === true;
    root.baseOffsetMs = Math.max(0, Math.floor(_numberOr(extra.previousBaseOffsetMs, 0)));
    root._pendingAudioStream = root.snt;
    root._pendingAudioIndex = -1;
    if (root.hasOwnProperty("_pendingAudioManualDirectPlay"))
        root._pendingAudioManualDirectPlay = false;
    try {
        root._syncTrackMenuIndexes("audio-negotiation-restore");
    } catch (e0) {}
    return true;
}

// Modes et qualité : application immédiate et présentation de l’état validé.
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

function _streamsReadyForCurrent(root) {
    if (!root || !root.itemId) return false;
    var key = (root.serverUrl || "") + "|" + (root.itemId || "");
    return root._streamsReadyKey === key;
}

function shouldForceInitialServerRemux(root) {
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

function applyOriginalDirectPlayQuality(root, mediaPlayer) {
    if (!root || !mediaPlayer || root._tearingDownPlayer) return false;
    var fromServerPipeline = root.lastUsedTranscoding === true ||
        root.lastUsedDirectStream === true || root.lastUsedServerRemux === true ||
        root.serverTimedStream === true || root.timeShifted === true ||
        Number(root.baseOffsetMs || 0) > 0;
    if (fromServerPipeline && root.audioOutputMode !== "stereo" && root.shared && typeof root.requestDirectPlayReload === "function") {
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
        } catch (eReload) {
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
    try {
        if (resume) mediaPlayer.pause();
    } catch (e0) {}
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
    try {
        return root._clampUi(root.uiPositionMs());
    } catch (e0) {
        return Math.max(0, Math.floor(Number(root.lastUiTargetMs || 0)));
    }
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
    try {
        if (resume) mediaPlayer.pause();
    } catch (e0) {}

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
    var autoRemux = shouldForceInitialServerRemux(root) || dvdRemux;
    _prepareQualityServerSubtitle(root, hardTranscode || autoRemux);
    try {
        if (resume) mediaPlayer.pause();
    } catch (e0) {}

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
        var text = mb >= 1 ?
            mb.toFixed(mb % 1 === 0 ? 0 : 1).replace(".", ",") + " Mbit/s" :
            Math.round(Number(root.manualQualityBitrate) / 1000.0) + " Kbit/s";
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

// Coordination des commandes exposées par PlayerOverlay.
function effectiveAudioUiIndex(root) {
    var count = root.audioTracks && root.audioTracks.length ? root.audioTracks.length : 0
    if (count <= 0) return 0
    var stream = root.selectedAudioStream >= 0 ? root.selectedAudioStream : root.effectiveAudioStream
    var idx = root._indexInStreamMap(root.audioStreamIndexMap, stream)
    if (idx < 0) idx = root.audioIndex | 0
    return Math.max(0, Math.min(idx, count - 1))
}

function effectiveSubtitleUiIndex(root) {
    var map = root.subtitleStreamIndexMap || []
    var count = map && map.length ? map.length :
        ((root.subtitleTracks && root.subtitleTracks.length ? root.subtitleTracks.length : 0) + 1)
    if (count <= 0) return 0
    var stream = root.useLocalSubs && root.localSubStreamIndex >= 0 ? root.localSubStreamIndex :
        (root.selectedSubtitleStream >= 0 ? root.selectedSubtitleStream : root.effectiveSubtitleStream)
    if (!(stream >= 0)) return 0
    var idx = root._indexInStreamMap(map, stream)
    return idx < 0 ? Math.max(0, Math.min(root.subtitleIndex | 0, count - 1)) :
        Math.max(0, Math.min(idx | 0, count - 1))
}

function activeQualityChoiceValue(root) {
    if (root._qualityOriginalDirectPlaySelected()) return -1
    if (root._qualityRemuxSelected()) return -2
    if (root._qualityAutomaticServerSelected()) return -3
    if (root.manualQualityBitrate > 0) return root.manualQualityBitrate
    return -3
}

function displayQualityBitrate(root) {
    return root._deferredQualityValue > 0 ? root._deferredQualityValue : root.manualQualityBitrate
}

function displayQualityDirectPlaySelected(root) {
    return root._deferredQualityValue !== 0 ? root._deferredQualityValue === -1 :
        root._qualityOriginalDirectPlaySelected()
}

function displayQualityRemuxSelected(root) {
    return root._deferredQualityValue !== 0 ? root._deferredQualityValue === -2 :
        root._qualityRemuxSelected()
}

function displayQualityAutomaticSelected(root) {
    return root._deferredQualityValue !== 0 ? root._deferredQualityValue === -3 :
        root._qualityAutomaticServerSelected()
}

function displayQualityStatusText(root) {
    return root._deferredQualityValue !== 0 ? "Appliqué à la reprise de la lecture" :
        root._qualityStatusText()
}
