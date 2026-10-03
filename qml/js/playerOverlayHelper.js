// ReDeFin subtitle routing: local text subtitles only on pure DirectPlay; remux/DirectStream/transcode/HLS use server-managed subtitles.
/* playerOverlayHelper.js — build production
 * Glue clavier/navigation + helpers UI pour playeroverlay.qml (Qt 5.15 / QtQuick 2.15).
 *
 * Lecture et reprise fiables :
 * - sauvegarde de position figée avant Stop/Retour avec retry unique
 * - gestion clavier/navigation
 * - helpers PlayerOverlay déplacés depuis JellyfinPlaybackCore
 * - override manuel DirectPlay depuis AudioMenu : bypass des remux préventifs auto
 * - coordination des sous-titres locaux ; téléchargement/parsing dans LocalTextSubtitles
 *
 * Important :
 * - applique au PlayerOverlay les résultats de négociation demandés par l'UI
 * - ne décide PAS du démarrage initial, du pré-roll ou du reporting, désormais
 *   portés par PlayerSession.js
 * - ne décide PAS des politiques codec DirectPlay / remux / transcode, qui restent dans le Core
 * - utilise exclusivement un requestFn/jellyfinBridge central pour charger les sous-titres
 */
.import "LocalTextSubtitles.js" as LocalTextSubtitles
.import "PlayerSession.js" as PlayerSession
/* ===== Utils sûrs ===== */
function _s(v) { return (v === undefined || v === null) ? "" : (v + ""); }
function _has(o, k) { return o && typeof o[k] !== "undefined" && o[k] !== null; }
function _call(o, k) {
    if (_has(o, k) && typeof o[k] === "function")
        return o[k].apply(o, Array.prototype.slice.call(arguments, 2));
}
function _set(o, k, v) { if (_has(o, k)) o[k] = v; }
function _inc(o, k, d) { if (_has(o, k)) o[k] = (o[k] || 0) + d; }
/* Affiche les contrôles et relance le timer centralisé si présent */
function _bumpControls(root) {
    if (!root) return;
    if (typeof root.resetControlsTimer === "function") {
        root.resetControlsTimer();
        return;
    }
    _set(root, "controlsVisible", true);
    if (_has(root, "controlsTimer") && _has(root.controlsTimer, "restart"))
        root.controlsTimer.restart();
}
/* Wrappers média */
function _toggle(root) {
    if (root && typeof root.transportToggle === "function") { root.transportToggle("helper-toggle"); return; }
    if (root && typeof root.mediaToggle === "function") { root.mediaToggle(); return; }
    if (_has(root, "mp")) {
        try { root.mp.playbackState === 2 ? root.mp.pause() : root.mp.play(); } catch(e) {}
    }
}
function _seek(root, delta) { _call(root, "seekBy", delta); }
function _toastSubs(root) { _call(root, "showSubsToast"); }
function _backToDetails(root) {
    if (!root || typeof root.requestBackToDetails !== "function") return;
    var id = "";
    try { id = String(root.itemId || root.currentItemId || ""); } catch(e) { id = ""; }
    try {
        root.requestBackToDetails(id);
    } catch(e1) {
        try { root.requestBackToDetails(""); } catch(e2) {}
    }
}
function _finalizeExit(root, reason) {
    if (!root) return false;
    if (typeof root.finalizePlaybackAndExit === "function") {
        try { return root.finalizePlaybackAndExit(reason || "helper-exit") !== false; }
        catch(e0) {}
    }
    if (typeof root.mediaStop === "function") root.mediaStop();
    else if (_has(root, "mp")) _call(root.mp, "stop");
    _backToDetails(root);
    return true;
}
/* ===== Helpers déplacés depuis JellyfinPlaybackCore : UI / PlayerOverlay ===== */
function shouldNetworkSeek(flags, durMs) {
    if (!flags) return true;
    return !!(flags.isHls || flags.lastUsedTranscoding || flags.lastUsedDirectStream || flags.serverTimedStream ||
              flags.timeShifted || flags.lastUsedServerRemux || !(durMs > 0));
}
function keepUi(scrubActive, scrubAccumUiMs, lastUiTargetMs, uiNowMs) {
    return scrubActive && scrubAccumUiMs >= 0 ? scrubAccumUiMs : (lastUiTargetMs > 0 ? lastUiTargetMs : (uiNowMs || 0));
}
function makeCtx(core, state, startMs, reneg) {
    reneg = reneg || {};
    return {
        serverUrl: core.serverUrl,
        accessToken: core.accessToken,
        userId: core.userId,
        itemId: core.itemId,
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
        allowLocalSubtitleOverlay: reneg.allowLocalSubtitleOverlay === true,
        forceHevcMain10Remux: !!reneg.forceHevcMain10Remux,
        forceAllowTranscoding: !!reneg.forceAllowTranscoding,
        forceVideoTranscodeCodec: reneg.forceVideoTranscodeCodec || null,
        forceDvdSubFileTranscode: !!reneg.forceDvdSubFileTranscode,
        forceInterlacedTsTranscode: !!reneg.forceInterlacedTsTranscode,
        preferFrenchAudio: reneg.preferFrenchAudio === false ? false : true,
        disableAutoFrenchAudio: !!reneg.disableAutoFrenchAudio,
        disableAutoVoFrenchFullSubtitle: (reneg.disableAutoVoFrenchFullSubtitle !== undefined)
                                         ? !!reneg.disableAutoVoFrenchFullSubtitle
                                         : !!state.disableAutoVoFrenchFullSubtitle,
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
// Règle de référence sous-titres ReDeFin : seul un vrai DirectPlay, sans base
// selectedAudioStream n'entre volontairement pas dans ce prédicat : on se base
function isPureDirectPlay(flagsOrState) {
    var s = flagsOrState || {}, base = 0;
    try { base = Math.max(0, Math.floor(Number(s.baseOffsetMs || 0))); } catch(e0) {}
    return !(s.isHls || s.lastUsedTranscoding || s.lastUsedDirectStream || s.serverTimedStream || s.timeShifted ||
             s.lastUsedServerRemux || base > 0);
}
function labelForItem(it, fallback) {
    if (!it) return fallback || "";
    var t = (it.Type || "");
    if (t === "Episode") {
        var s = (it.ParentIndexNumber != null) ? it.ParentIndexNumber : ""; var e = (it.IndexNumber != null) ? it.IndexNumber : ""; var parts = [];
        if (s !== "" && e !== "") parts.push("S" + s + "E" + e);
        if (it.Name) parts.push(it.Name);
        return parts.join(" • ");
    }
    return it.Name || (fallback || "");
}
/* ===== Debug/trace helpers légers déplacés depuis playeroverlay.qml ===== */
function logValue(v) {
    if (v === undefined) return "undefined";
    if (v === null) return "null";
    return "" + v;
}
function urlKind(u) {
    u = logValue(u);
    if (!u) return "none";
    if (u.indexOf(".m3u8") >= 0 || u.indexOf("/hls") >= 0) return "hls";
    if (u.indexOf("/Videos/") >= 0 && u.indexOf("/stream") >= 0 && u.indexOf("static=true") >= 0) return "http-dp-static";
    if (u.indexOf("/Videos/") >= 0 && u.indexOf("/stream") >= 0) return "http-progressive";
    return "other";
}
/* Raccourcis de clés */
var K = (typeof Qt !== "undefined") ? Qt : {
    Key_Left: 0x01000012, Key_Right: 0x01000014, Key_Up: 0x01000013, Key_Down: 0x01000015,
    Key_Return: 0x01000004, Key_Enter: 0x01000005, Key_Select: 0x01000000,
    Key_Back: 0x01000061, Key_Escape: 0x01000000,
    Key_MediaNext: 0x01000031, Key_MediaPrevious: 0x01000030,
    Key_MediaPlay: 0x01000028, Key_MediaTogglePlayPause: 0x0100003B,
    Key_MediaPause: 0x01000029, Key_MediaStop: 0x01000024,
    Key_Plus: 0x2B, Key_Equal: 0x3D, Key_Minus: 0x2D
};
/* ===== Transport / focus unifié télécommande ===== */
function _isOkKey(k) {
    return k === K.Key_Return || k === K.Key_Enter || k === K.Key_Select;
}
function _controlsButtonIndex(root) {
    var v = 3;
    try {
        if (root && typeof root.getControlsButtonIndex === "function")
            v = root.getControlsButtonIndex();
        else if (root && typeof root.controlsButtonIndex === "number")
            v = root.controlsButtonIndex;
    } catch(e) {}
    v = v | 0;
    if (v < 1 || v > 5) v = 3;
    return v;
}
function _setControlsButtonIndex(root, idx, origin) {
    idx = Math.max(1, Math.min(5, idx | 0));
    if (root && typeof root._setControlsButtonIndex === "function") {
        root._setControlsButtonIndex(idx, origin || "helper-controls-index");
        return;
    }
    if (root && typeof root.setControlsButtonIndex === "function") {
        root.setControlsButtonIndex(idx, origin || "helper-controls-index");
        return;
    }
    _set(root, "controlsButtonIndex", idx);
}
function _focusControls(root, origin) {
    var CF_CONTROLS = _has(root, "cF_CONTROLS") ? root.cF_CONTROLS : 1;
    if (root && typeof root._forceControlsFocusNow === "function") {
        root._forceControlsFocusNow(origin || "helper-focus-controls");
        return;
    }
    _set(root, "controlsFocus", CF_CONTROLS);
    try { if (root && typeof root.forceActiveFocus === "function") root.forceActiveFocus(); } catch(e) {}
}
function _focusProgress(root) {
    var CF_PROGRESS = _has(root, "cF_PROGRESS") ? root.cF_PROGRESS : 0;
    if (root && typeof root._focusProgressBarSilent === "function") {
        root._focusProgressBarSilent();
        return;
    }
    _set(root, "controlsFocus", CF_PROGRESS);
    try { if (root && typeof root.forceActiveFocus === "function") root.forceActiveFocus(); } catch(e) {}
}
function _transportToggle(root, origin) {
    if (root && typeof root.transportToggle === "function") {
        root.transportToggle(origin || "helper-toggle");
        return;
    }
    _toggle(root);
}
function _transportRewind(root, origin) {
    if (root && typeof root.transportRewind === "function") {
        root.transportRewind(origin || "helper-rewind");
        return;
    }
    _seek(root, -10000);
}
function _transportForward(root, origin) {
    if (root && typeof root.transportForward === "function") {
        root.transportForward(origin || "helper-forward");
        return;
    }
    _seek(root, 10000);
}
function _transportPrev(root, origin) {
    if (root && typeof root.transportPrev === "function") {
        root.transportPrev(origin || "helper-prev");
        return;
    }
    if (!_call(root, "playPrev")) {
        try {
            if (root && root.playlistRef && typeof root.playlistRef.prevFrom === "function")
                root.playlistRef.prevFrom(root.itemId || "");
        } catch(e) {}
    }
}
function _transportNext(root, origin) {
    if (root && typeof root.transportNext === "function") {
        root.transportNext(origin || "helper-next");
        return;
    }
    if (!_call(root, "playNext")) {
        try {
            if (root && root.playlistRef && typeof root.playlistRef.nextFrom === "function")
                root.playlistRef.nextFrom(root.itemId || "");
        } catch(e) {}
    }
}
function _activateControlsButton(root, origin) {
    if (root && typeof root._activateControlsButton === "function") {
        root._activateControlsButton(origin || "helper-controls-ok");
        return;
    }
    if (root && typeof root.activateControlsButton === "function") {
        root.activateControlsButton(origin || "helper-controls-ok");
        return;
    }
    var idx = _controlsButtonIndex(root);
    if (idx === 1) _transportPrev(root, "helper-controls-prev");
    else if (idx === 2) _transportRewind(root, "helper-controls-rewind");
    else if (idx === 3) _transportToggle(root, "helper-controls-toggle");
    else if (idx === 4) _transportForward(root, "helper-controls-forward");
    else if (idx === 5) _transportNext(root, "helper-controls-next");
}
/* ===== Navigation / clavier ===== */
function handlePressed(root, event) {
    if (!root || !event) return;
    var wasControlsHidden = !root.controlsVisible;
    _bumpControls(root);
    if (event.key === K.Key_Plus || event.key === K.Key_Equal) {
        _inc(root, "subtitleDelayMs", 100);
        _toastSubs(root);
        event.accepted = true;
        return;
    }
    if (event.key === K.Key_Minus) {
        _inc(root, "subtitleDelayMs", -100);
        _toastSubs(root);
        event.accepted = true;
        return;
    }
    if (root && typeof root._qualityPanelOpen === "function" && root._qualityPanelOpen()) {
        if (typeof root._handleQualityPanelKey === "function") root._handleQualityPanelKey(event);
        event.accepted = true;
        return;
    }
    if (root.audioMenuVisible || root.subMenuVisible) {
        if (event.key === K.Key_Back || event.key === K.Key_Escape) {
            _set(root, "audioMenuVisible", false);
            _set(root, "subMenuVisible", false);
            event.accepted = true;
        }
        return;
    }
    if (wasControlsHidden) {
        if (event.key === K.Key_Left)  { _focusProgress(root); _transportRewind(root, "hidden-progress-left"); event.accepted = true; return; }
        if (event.key === K.Key_Right) { _focusProgress(root); _transportForward(root, "hidden-progress-right"); event.accepted = true; return; }
        if (_isOkKey(event.key))       { _focusProgress(root); _transportToggle(root, "hidden-progress-ok"); event.accepted = true; return; }
    }
    var cf = root.controlsFocus || 0; var CF_PROGRESS = _has(root, "cF_PROGRESS") ? root.cF_PROGRESS : 0; var CF_CONTROLS = _has(root, "cF_CONTROLS") ? root.cF_CONTROLS : 1; var CF_MENU = _has(root, "cF_MENU") ? root.cF_MENU : 4;
    var CF_CHAPTERS = _has(root, "cF_CHAPTERS") ? root.cF_CHAPTERS : 5; var CF_QUALITY = _has(root, "cF_QUALITY") ? root.cF_QUALITY : 6;
    var hasModernFocusModel = _has(root, "cF_PROGRESS") && _has(root, "cF_CONTROLS") && _has(root, "cF_MENU");
    if (hasModernFocusModel) {
        /* ProgressBar : gauche/droite = seek, OK = pause/play.
           Bas = PlayerControls. Haut = rester sur ProgressBar pour éviter le ping-pong haut/bas. */
        if (cf === CF_PROGRESS) {
            if (event.key === K.Key_Left)  { _transportRewind(root, "progress-left"); event.accepted = true; return; }
            if (event.key === K.Key_Right) { _transportForward(root, "progress-right"); event.accepted = true; return; }
            if (_isOkKey(event.key))       { _transportToggle(root, "progress-ok"); event.accepted = true; return; }
            if (event.key === K.Key_Down) {
                _focusControls(root, "progress-down-to-controls");
                event.accepted = true;
                return;
            }
            if (event.key === K.Key_Up) {
                if (root && typeof root._focusSkipIntroIfVisible === "function" &&
                        root._focusSkipIntroIfVisible("progress-up", false)) {
                    event.accepted = true;
                    return;
                }
                _focusProgress(root);
                event.accepted = true;
                return;
            }
        }
        /* PlayerControls : gauche/droite déplacent le bouton interne, OK active le bouton */
        if (cf === CF_CONTROLS) {
            var idx = _controlsButtonIndex(root);
            if (event.key === K.Key_Left) {
                if (idx <= 1 && root && typeof root._focusQualityButtonSilent === "function" && root._focusQualityButtonSilent("controls-left-to-quality")) { event.accepted = true; return; }
                if (idx <= 1 && root && typeof root._focusChaptersButtonSilent === "function" && root._focusChaptersButtonSilent("controls-left-to-chapters")) { event.accepted = true; return; }
                _setControlsButtonIndex(root, Math.max(1, idx - 1), "controls-left");
                event.accepted = true;
                return;
            }
            if (event.key === K.Key_Right) {
                if (idx < 5) {
                    _setControlsButtonIndex(root, idx + 1, "controls-right");
                } else if (root && typeof root._focusChaptersButtonSilent === "function" && root._focusChaptersButtonSilent("controls-right-to-chapters")) {
                } else {
                    _set(root, "controlsFocus", CF_MENU);
                    if (_has(root, "menuIndex")) _set(root, "menuIndex", 1);
                    try { if (root && typeof root.forceActiveFocus === "function") root.forceActiveFocus(); } catch(e) {}
                }
                event.accepted = true;
                return;
            }
            if (event.key === K.Key_Up) {
                _focusProgress(root);
                event.accepted = true;
                return;
            }
            if (event.key === K.Key_Down) {
                event.accepted = true;
                return;
            }
            if (_isOkKey(event.key)) {
                if ((idx === 1 || idx === 5) && root && typeof root._startControlsTransportHold === "function") {
                    // Comme LoginPage : les répétitions Freebox ne doivent ni réarmer
                    if (!event.isAutoRepeat) root._startControlsTransportHold();
                } else {
                    _activateControlsButton(root, "controls-ok");
                }
                event.accepted = true;
                return;
            }
        }
        /* Bouton / carrousel chapitres : premier bouton du groupe droit. */
        if (_has(root, "cF_CHAPTERS") && cf === CF_CHAPTERS) {
            if (event.key === K.Key_Up) { _focusProgress(root); event.accepted = true; return; }
            if (event.key === K.Key_Right) {
                _set(root, "controlsFocus", CF_MENU);
                if (_has(root, "menuIndex")) _set(root, "menuIndex", 1);
                try { if (root && typeof root.forceActiveFocus === "function") root.forceActiveFocus(); } catch(eChaptersRight) {}
                event.accepted = true; return;
            }
            if (event.key === K.Key_Left || event.key === K.Key_Down) {
                _setControlsButtonIndex(root, 5, "chapters-to-controls");
                _focusControls(root, "chapters-to-controls");
                event.accepted = true; return;
            }
            if (_isOkKey(event.key)) { if (root && typeof root._openChaptersPanel === "function") root._openChaptersPanel(); event.accepted = true; return; }
        }
        if (_has(root, "cF_QUALITY") && cf === CF_QUALITY) {
            if (event.key === K.Key_Up) { _focusProgress(root); event.accepted=true; return; }
            if (event.key === K.Key_Left) { event.accepted=true; return; }
            if (event.key === K.Key_Right || event.key === K.Key_Down) { _setControlsButtonIndex(root,1,"quality-to-controls"); _focusControls(root,"quality-to-controls"); event.accepted=true; return; }
            if (_isOkKey(event.key)) { if (root && typeof root._openQualityPanel === "function") root._openQualityPanel(); event.accepted=true; return; }
        }
        /* Menus audio / sous-titres */
        if (cf === CF_MENU) {
            if (event.key === K.Key_Left) {
                if (_has(root, "menuIndex") && root.menuIndex > 1) {
                    _set(root, "menuIndex", 1);
                } else if (root && typeof root._focusChaptersButtonSilent === "function" && root._focusChaptersButtonSilent("audio-left-to-chapters")) {
                    // Chapitres est immédiatement à gauche d'Audio.
                } else {
                    _setControlsButtonIndex(root, 5, "menu-left-edge");
                    _focusControls(root, "menu-left-edge");
                }
                event.accepted = true;
                return;
            }
            if (event.key === K.Key_Right) {
                if (_has(root, "menuIndex") && root.menuIndex < 2) _set(root, "menuIndex", 2);
                event.accepted = true;
                return;
            }
            if (event.key === K.Key_Down) {
                _focusControls(root, "menu-down");
                event.accepted = true;
                return;
            }
            if (event.key === K.Key_Up) {
                _focusProgress(root);
                event.accepted = true;
                return;
            }
            if (_isOkKey(event.key)) {
                if (_has(root, "menuIndex") && root.menuIndex === 1) _call(root, "openAudioMenu");
                else _call(root, "openSubMenu");
                event.accepted = true;
                return;
            }
        }
    }
    if (event.key === K.Key_MediaNext) { _transportNext(root, "media-next"); event.accepted = true; return; }
    if (event.key === K.Key_MediaPrevious) { _transportPrev(root, "media-prev"); event.accepted = true; return; }
    if (event.key === K.Key_MediaPlay || event.key === K.Key_MediaTogglePlayPause) { _transportToggle(root, "media-toggle"); event.accepted = true; return; }
    if (event.key === K.Key_MediaPause) {
        if (typeof root.mediaPause === "function") root.mediaPause();
        else if (_has(root, "mp")) _call(root.mp, "pause");
        event.accepted = true;
        return;
    }
    if (event.key === K.Key_MediaStop) {
        _finalizeExit(root, "media-stop-key");
        event.accepted = true;
        return;
    }
    if (event.key === K.Key_Back || event.key === K.Key_Escape) {
        _finalizeExit(root, "back-key");
        event.accepted = true;
        return;
    }
}
function handleReleased(root, event) {
    if (!root || !event) return;
    var k = event.key;
    if (_isOkKey(k) && root && typeof root._finishControlsTransportHold === "function") {
        // CRITIQUE Freebox : un maintien produit des Released auto-repeat intermédiaires.
        // LoginPage les ignore ; faire pareil uniquement lorsqu'un hold transport est actif.
        var transportHoldActive = (typeof root._controlsTransportHoldActive === "function") && root._controlsTransportHoldActive();
        if (event.isAutoRepeat && transportHoldActive) {
            event.accepted = true;
            return;
        }
        if (!event.isAutoRepeat && root._finishControlsTransportHold()) {
            event.accepted = true;
            return;
        }
    }
    if (!root.commitOnKeyRelease) return;
    if (!root.scrubActive) return;
    if (k === K.Key_Right || k === K.Key_Left ||
        k === K.Key_MediaNext || k === K.Key_MediaPrevious) {
        if (root && typeof root.stopScrubCommitTimer === "function") root.stopScrubCommitTimer();
        else if (_has(root, "scrubCommitTimer") && _has(root.scrubCommitTimer, "stop")) root.scrubCommitTimer.stop();
        _call(root, "commitScrub");
        event.accepted = true;
    }
}
/* ===== Runtime/UI allégé déplacé depuis playeroverlay.qml ===== */
function normalizeUrl(u) {
    u = _s(u); var q = u.indexOf("?");
    if (q < 0) return u;
    var kept = u.substring(q + 1).split("&").filter(function(x) {
        return x.length > 0 && x.split("=")[0] !== "cb";
    });
    kept.sort();
    return kept.length ? u.substring(0, q) + "?" + kept.join("&") : u.substring(0, q);
}
function hasQueryTag(u) {
    u = _s(u); var q = u.indexOf("?");
    if (q < 0) return false;
    return u.substring(q + 1).split("&").some(function(p) { return (p.split("=")[0] || "") === "tag"; });
}
function indexForStream(map, stream) {
    if (!map || typeof map.length !== "number") return -1;
    for (var i = 0; i < map.length; i++) if (Number(map[i]) === Number(stream)) return i;
    return -1;
}
function queryInt(url, key) {
    try {
        var m = _s(url).match(new RegExp("(?:\\?|&)" + key + "=([^&]+)"));
        if (!m) return -1;
        var n = parseInt(decodeURIComponent(m[1]), 10);
        return isFinite(n) ? n : -1;
    } catch(e) { return -1; }
}
function resultInt(res, keys) {
    try {
        for (var i = 0; i < keys.length; i++) {
            var v = res && res[keys[i]];
            if (v !== undefined && v !== null) {
                var n = parseInt(v, 10);
                if (isFinite(n)) return n;
            }
        }
    } catch(e) {}
    return -1;
}
function syncTrackMenuIndexes(root, audioItem, subItem) {
    var aStream = root.selectedAudioStream >= 0 ? root.selectedAudioStream : root.effectiveAudioStream; var ai = aStream >= 0 ? indexForStream(root.audioStreamIndexMap, aStream) : 0;
    ai = root.audioTracks && root.audioTracks.length ? Math.max(0, Math.min(ai < 0 ? 0 : ai, root.audioTracks.length - 1)) : 0;
    var sStream = root.useLocalSubs && root.localSubStreamIndex >= 0 ? root.localSubStreamIndex
                : (root.selectedSubtitleStream >= 0 ? root.selectedSubtitleStream : root.effectiveSubtitleStream);
    var si = sStream >= 0 ? indexForStream(root.subtitleStreamIndexMap, sStream) : 0;
    si = root.subtitleTracks && root.subtitleTracks.length ? Math.max(0, Math.min(si < 0 ? 0 : si, root.subtitleTracks.length - 1)) : 0;
    if (root.audioIndex !== ai) root.audioIndex = ai;
    if (root.subtitleIndex !== si) root.subtitleIndex = si;
    try { if (audioItem) { audioItem.currentIndex = ai; if (audioItem.syncIndex) audioItem.syncIndex(); } } catch(e0) {}
    try { if (subItem) { subItem.currentIndex = si; if (subItem.syncIndex) subItem.syncIndex(); } } catch(e1) {}
}
function showNextPanel(root, item) {
    root.nextUserHidden = false;
    if (!item) return;
    try { item.externGate = true; } catch(e) {}
}
function hideNextPanel(root, item) {
    root.nextUserHidden = true;
    root.controlsVisible = true;
    root._syncControlsTimer();
    if (!item) return;
    try { item.externGate = false; } catch(e) {}
}
function syncNextOverlayContext(root, item) {
    if (!item) return;
    item.serverUrl = root.serverUrl;
    item.accessToken = root.accessToken;
    item.currentItemId = root.itemId;
    item.triggerWindowMs = root.nextOverlayWindowMs;
    item.autoStartWhenZero = root.nextOverlayAutostart;
    item.externGate = !root.nextUserHidden;
    var playlist = root.playlistRef;
    var hasScopedList = !!(playlist && playlist.hasList && playlist.hasList());
    item.playlist = hasScopedList ? (playlist.list || []) : (root.playerPlaylist || []);
}
function logoUrlFromItem(root, bridge, it) {
    if (!it || !bridge || typeof bridge.itemImageUrl !== "function") return "";
    var tags = it.ImageTags || {}, tag = tags.Logo || tags.logo || "";
    // QNetworkReplyImplPrivate observé sur Qt 5.15/Freebox.
    return tag && it.Id ? bridge.itemImageUrl(root.serverUrl, it.Id, "Logo", tag, {}) : "";
}
function ensureSeriesLogoTag(root, bridge, it) {
    if (!root.serverUrl || !root.accessToken || !it || hasQueryTag(root.currentItemLogoUrl)) return;
    var t = _s(it.Type);
    var sid = (t === "Episode" || t === "Season")
            ? (it.SeriesId || (it.Series && it.Series.Id) || "") : "";
    if (!sid) return;
    var expectedItemId = _s(it.Id || root.itemId || "");
    var expectedSeriesId = _s(sid);
    bridge.fetchItem(root.serverUrl, root.accessToken, expectedSeriesId, function(series) {
        if (_s(root.itemId || "") !== expectedItemId) return;
        if (!series || _s(series.Id || "") !== expectedSeriesId) return;
        var tags = series.ImageTags || {}, tag = tags.Logo || tags.logo || "";
        if (!tag) return;
        var u = bridge.itemImageUrl(root.serverUrl, expectedSeriesId, "Logo", tag, {});
        root.currentItemLogoUrl = u;
        root.lastGoodLogoUrl = u;
        root.lastGoodLogoItemId = expectedItemId;
        root._pushTopBar();
    }, function() {});
}
function pushLocalSubsUiMs(root, item, pos, force) {
    if (!item) return;
    var p = Math.max(0, pos | 0);
    if (!root.useLocalSubs || !root.localCues || !root.localCues.length) {
        if (force === true) { root._lastSubsUiPushMs = -1; item.uiMs = p; }
        return;
    }
    if (force === true || root._lastSubsUiPushMs < 0 || Math.abs(p - root._lastSubsUiPushMs) >= root.subsUiPushMinDeltaMs) {
        root._lastSubsUiPushMs = p; item.uiMs = p;
    }
}
function cancelLocalSubtitleRequest(root, reason) {
    if (!root) return false;
    var handle = null;
    try { handle = root._localSubtitleRequestHandle; } catch(e0) { handle = null; }
    try { root._localSubtitleRequestHandle = null; } catch(e1) {}
    if (!handle || typeof handle.cancel !== "function") return false;
    try { return handle.cancel(reason || "superseded") !== false; } catch(e2) {}
    return false;
}
function disableLocalSubsOverlay(root, item, audioItem, subItem) {
    cancelLocalSubtitleRequest(root, "local-subtitles-disabled");
    root.useLocalSubs = false; root.localCues = []; root.localSubStreamIndex = -1; root._lastSubsUiPushMs = -1;
    if (item) { item.cues = []; item.enabled = false; }
    syncTrackMenuIndexes(root, audioItem, subItem);
}
function tryAutoLocalizeAfterDP(root, item) {
    if (root._autoLocalizeSubStream < 0 || !isPureDirectPlay(root)) { root._autoLocalizeSubStream = -1; return; }
    var stream = root._autoLocalizeSubStream; root._autoLocalizeSubStream = -1;
    root.loadLocalSubtitleByStreamIndex(stream, function(ok) {
        if (!ok) return;
        root.selectedSubtitleStream = -1;
        var idx = root.listIndexForStream(stream); root.subtitleIndex = idx < 0 ? 0 : idx;
        if (item) { item.cues = root.localCues; item.enabled = root.localCues.length > 0; }
    });
}
function streamsKeyForCurrent(root) { return (root.serverUrl || "") + "|" + (root.itemId || ""); }
function flushStreamsWaiters(root, ok) {
    var w = root._streamsWaiters || []; root._streamsWaiters = [];
    for (var i = 0; i < w.length; i++) try { if (typeof w[i] === "function") w[i](ok === true); } catch(e) {}
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
function _normalizeSubtitleTables(labels, map, isText) {
    labels = labels && typeof labels.length === "number" ? labels.slice(0) : [];
    map = map && typeof map.length === "number" ? map.slice(0) : [];
    isText = isText && typeof isText.length === "number" ? isText.slice(0) : [];
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
    return { labels: labels, map: map, isText: isText };
}
function refreshStreams(root, router, done) {
    if (!root.serverUrl || !root.accessToken || !root.itemId) {  if (typeof done === "function") done(false); return; }
    var key = streamsKeyForCurrent(root);
    if (typeof done === "function") {
        if (root._streamsReadyKey === key) {  done(true); return; }
        if (root._streamsLoadingKey === key) { var q = root._streamsWaiters || []; q.push(done); root._streamsWaiters = q;  return; }
    } else if (root._streamsLoadingKey === key) {  return; }
    var item = root.itemId, server = root.serverUrl, token = root.accessToken, seq = ++root._streamsSeq;
    root._streamsLoadingKey = key; root._streamsReadyKey = "";
    if (typeof done === "function") { var list = root._streamsWaiters || []; list.push(done); root._streamsWaiters = list; } else root._streamsWaiters = [];
    router.fetchStreams(server, token, item, function(res) {
        if (seq !== root._streamsSeq || item !== root.itemId || server !== root.serverUrl || token !== root.accessToken) {  return; }
        root._streamsLoadingKey = ""; root._streamsReadyKey = key; root.runtimeTicks = res.runtimeTicks || 0;
        root.audioTracks = res.audioLabels || [];
        root.audioStreamIndexMap = res.audioMap && res.audioMap.length ? res.audioMap : [];
        root.audioCodecMap = res.audioCodecMap && res.audioCodecMap.length ? res.audioCodecMap : [];
        var subTables = _normalizeSubtitleTables(res.subtitleLabels || [], res.subtitleMap || [], res.subtitleIsText || []);
        root.subtitleTracks = subTables.labels;
        root.subtitleStreamIndexMap = subTables.map;
        root.subtitleIsTextMap = subTables.isText;
        root.firstAudioStreamIndex =
                (typeof res.firstAudioStreamIndex === "number")
                ? res.firstAudioStreamIndex : -1;
        root.bestFrenchAudioStreamIndex =
                (typeof res.bestFrenchAudioStreamIndex === "number")
                ? res.bestFrenchAudioStreamIndex : -1;
        root.preferredFrenchAudioNeedsServerSelection =
                res.preferredFrenchAudioNeedsServerSelection === true;
        root.firstInternalSubtitleStreamIndex =
                (typeof res.firstInternalSubtitleStreamIndex === "number")
                ? res.firstInternalSubtitleStreamIndex : -1;
        root.preferredFrenchForcedSubtitleNeedsServerSelection =
                res.preferredFrenchForcedSubtitleNeedsServerSelection === true;
        root.strictFrenchAutoDirectPlayEligible = res.strictFrenchAutoDirectPlayEligible === true;
        root.hasPriorityInternalSubtitleRisk = res.hasPriorityInternalSubtitleRisk === true;
        root.hasImplicitFirstInternalSubtitleRisk = res.hasImplicitFirstInternalSubtitleRisk === true;
        root.hasInternalDvdSubtitle = res.hasInternalDvdSubtitle === true;
        root.isDvdSource = res.isDvdSource === true;
        root.requiresInterlacedTsTranscode = res.requiresInterlacedTsTranscode === true;
        root.safeFrenchForcedDvdSubtitleStream =
                (typeof res.safeFrenchForcedDvdSubtitleStreamIndex === "number")
                ? res.safeFrenchForcedDvdSubtitleStreamIndex : -1;
        root.strictFrenchForcedDefaultTextSubtitleStream =
                (typeof res.strictFrenchForcedDefaultTextSubtitleStreamIndex === "number")
                ? res.strictFrenchForcedDefaultTextSubtitleStreamIndex : -1;
        root.legacyFrenchForcedTextSubtitleStream =
                (typeof res.legacyFrenchForcedTextSubtitleStreamIndex === "number")
                ? res.legacyFrenchForcedTextSubtitleStreamIndex : -1;
        root._syncTrackMenuIndexes("refreshStreams"); root.updateClocksFromPlayback(); flushStreamsWaiters(root, true);
    }, function(err) {
        if (seq !== root._streamsSeq || item !== root.itemId || server !== root.serverUrl || token !== root.accessToken) {  return; }
        root._streamsLoadingKey = ""; root._streamsReadyKey = key; flushStreamsWaiters(root, false);
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
        root.currentMediaSourceId, streamIdx, function(ok, payload) {
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
            if (item) { item.cues = root.localCues; item.enabled = true; }
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
    } catch(e0) {}
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
        preferExternalTextSubtitlesInRemux: false,
        allowLocalSubtitleOverlay: false
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
/* ===== Verrou transport pendant un rechargement ===== */
/*
 * Raisons d'armement de la gate de chargement qui correspondent réellement à
 * un RECHARGEMENT de source : négociation en vol, reset dur et remplacement
 * d'URL. Les raisons d'ouverture initiale ("initial-negotiation",
 * "media-url-first", "completed", "item-changed") en sont volontairement
 * exclues : le démarrage ne doit pas être bloqué plus que nécessaire.
 */
var RELOAD_LOADING_REASONS = ["negotiation", "hard-source-reset",
                              "fresh-directplay-reset", "media-url-swap"];
function isReloadLoadingReason(reason) {
    var r = String(reason === undefined || reason === null ? "" : reason);
    for (var i = 0; i < RELOAD_LOADING_REASONS.length; ++i)
        if (RELOAD_LOADING_REASONS[i] === r) return true;
    return false;
}
/*
 * Vrai tant qu'un rechargement est en cours. Pendant cette fenêtre, reculer,
 * avancer, scruber et sauter de chapitre sont ignorés : ces commandes
 * lanceraient une seconde négociation concurrente sur un pipeline en cours de
 * construction. Retour, Stop et la sortie du lecteur ne sont jamais bloqués.
 */
function reloadBlocksTransport(root) {
    if (!root || root._tearingDownPlayer === true || root.serverPrerollBlocking === true)
        return false;
    if (root._sourceResetActive === true) return true;
    return root.videoLoadingGate === true && isReloadLoadingReason(root._videoLoadingReason);
}
/* ===== Focus des boutons de réglages du HUD ===== */
/*
 * Identifiants des boutons de réglages. Ils reprennent à l'identique la
 * numérotation exposée par PlayerSettingsOverlay.qml ET PlayerControls.qml.
 */
var SETTINGS_CONTROL_QUALITY = 0;
var SETTINGS_CONTROL_ZOOM = 1;
var SETTINGS_CONTROL_SPEED = 2;
var SETTINGS_CONTROL_AUDIO = 3;
var SETTINGS_CONTROL_SUBTITLE = 4;
function normalizeSettingsControl(control) {
    var c = Math.floor(Number(control));
    if (!isFinite(c) || isNaN(c) || c < 0 || c > SETTINGS_CONTROL_SUBTITLE)
        return SETTINGS_CONTROL_QUALITY;
    return c;
}
function settingsControlFocusTarget(root, control) {
    control = normalizeSettingsControl(control);
    if (control === SETTINGS_CONTROL_ZOOM) return root.cF_ZOOM;
    if (control === SETTINGS_CONTROL_SPEED) return root.cF_SPEED;
    if (control === SETTINGS_CONTROL_AUDIO || control === SETTINGS_CONTROL_SUBTITLE)
        return root.cF_MENU;
    return root.cF_QUALITY;
}
/* 0 = le bouton ne dépend pas de menuIndex. */
function settingsControlMenuIndex(control) {
    control = normalizeSettingsControl(control);
    if (control === SETTINGS_CONTROL_AUDIO) return 1;
    if (control === SETTINGS_CONTROL_SUBTITLE) return 2;
    return 0;
}
function settingsFocusStillOnControl(root, control) {
    if (!root || !(control >= 0) || control > SETTINGS_CONTROL_SUBTITLE) return false;
    if (root.controlsFocus !== settingsControlFocusTarget(root, control)) return false;
    var wanted = settingsControlMenuIndex(control);
    return wanted > 0 ? root.menuIndex === wanted : true;
}
function _settingsPanelBusy(root) {
    var names = ["_qualityPanelOpen", "_chaptersPanelOpen"];
    for (var i = 0; i < names.length; ++i) {
        try { if (typeof root[names[i]] === "function" && root[names[i]]() === true) return true; }
        catch(e0) {}
    }
    return false;
}
/*
 * Retour de focus déterministe après un choix ou une fermeture de menu : le
 * focus revient TOUJOURS sur le bouton du HUD qui a ouvert le panneau, avec
 * le HUD visible, quel que soit le chemin emprunté (validation, Retour,
 * fermeture latérale) et que le réglage ait été appliqué, différé ou ignoré.
 */
function restoreFocusAfterSettingsChoice(root, control, origin) {
    if (!root) return false;
    control = normalizeSettingsControl(control);
    // Remis en fin de fonction : les handlers de changement de controlsFocus /
    root._lastSettingsFocusControl = -1;
    root.audioMenuVisible = false;
    root.subMenuVisible = false;
    var menuIndex = settingsControlMenuIndex(control);
    if (menuIndex > 0) root.menuIndex = menuIndex;
    root.controlsFocus = settingsControlFocusTarget(root, control);
    root.controlsVisible = true;
    root._lastSettingsFocusControl = control;
    try { root.forceActiveFocus(); } catch(e0) {}
    try { root._updateControlsActive(); } catch(e1) {}
    try { root.resetControlsTimer(); } catch(e2) {}
    return true;
}
/*
 * Un rechargement peut détruire et reconstruire le chrome : on réaffirme le
 * focus natif sur le bouton d'origine, tant que l'utilisateur n'a pas navigué
 * ailleurs entre-temps.
 */
function reassertSettingsFocus(root, origin) {
    if (!root) return false;
    var control = root._lastSettingsFocusControl;
    if (!(control >= 0)) return false;
    if (root._tearingDownPlayer === true || root.nextUiLocked === true ||
            root.serverPrerollBlocking === true) return false;
    if (root.audioMenuVisible === true || root.subMenuVisible === true) return false;
    if (_settingsPanelBusy(root)) return false;
    if (root.controlsVisible !== true || !settingsFocusStillOnControl(root, control)) {
        root._lastSettingsFocusControl = -1;
        return false;
    }
    try { root.forceActiveFocus(); } catch(e0) {}
    try { root._updateControlsActive(); } catch(e1) {}
    return true;
}
/* L'utilisateur a navigué ailleurs : plus rien à réaffirmer. */
function forgetSettingsFocusIfMoved(root) {
    if (!root) return false;
    var control = root._lastSettingsFocusControl;
    if (!(control >= 0)) return false;
    if (settingsFocusStillOnControl(root, control)) return false;
    root._lastSettingsFocusControl = -1;
    return true;
}
/* ===== Réglages différés Audio / Sous-titres / Qualité ===== */
var _K_AUDIO = "audio", _K_SUBTITLE = "subtitle", _K_QUALITY = "quality";
var _Q_AUTO = -3, _Q_NONE = 0;
function _audioSelection(stream, ui, manualDp) {
    return { kind: _K_AUDIO, stream: Math.floor(_numberOr(stream, -1)),
             uiIndex: Math.floor(_numberOr(ui, -1)), manualDirectPlay: manualDp === true };
}
function _subtitleSelection(stream, ui) {
    return { kind: _K_SUBTITLE, stream: Math.floor(_numberOr(stream, -1)),
             uiIndex: Math.floor(_numberOr(ui, -1)) };
}
function _qualitySelection(value) {
    return { kind: _K_QUALITY, value: Math.floor(_numberOr(value, _Q_NONE)) };
}
function _sameSelection(a, b) {
    if (!a || !b || a.kind !== b.kind) return false;
    if (a.kind === _K_QUALITY) return a.value === b.value && a.value !== _Q_NONE;
    return a.uiIndex >= 0 && a.uiIndex === b.uiIndex;
}
function currentAudioSelection(root) {
    var ui = -1;
    try { ui = root._effectiveAudioUiIndexForSettings(); } catch(e0) {}
    var stream = root.selectedAudioStream >= 0 ? root.selectedAudioStream : root.effectiveAudioStream;
    return _audioSelection(stream, ui, root.manualDirectPlayMode === true);
}
function currentSubtitleSelection(root) {
    var ui = -1;
    try { ui = root._effectiveSubtitleUiIndexForSettings(); } catch(e0) {}
    var stream = root.useLocalSubs && root.localSubStreamIndex >= 0
            ? root.localSubStreamIndex
            : (root.selectedSubtitleStream >= 0 ? root.selectedSubtitleStream : root.effectiveSubtitleStream);
    return _subtitleSelection(stream, ui);
}
function currentQualitySelection(root) {
    var value = _Q_AUTO;
    try { value = root._activeQualityChoiceValue(); } catch(e0) {}
    return _qualitySelection(value);
}
function deferredReloadState(root) {
    if (!root._deferredReloadState)
        root._deferredReloadState = { audio: null, subtitle: null, quality: null };
    return root._deferredReloadState;
}
function _deferredPauseActive(root) {
    if (!root || root._deferredReloadReplaying === true
            || typeof root._deferredReloadPauseActive !== "function") return false;
    try { return root._deferredReloadPauseActive() === true; } catch(e0) { return false; }
}
function _setDeferredUi(root, kind, value) {
    if (kind === _K_AUDIO) root._deferredAudioUiIndex = value ? value.uiIndex : -1;
    else if (kind === _K_SUBTITLE) root._deferredSubtitleUiIndex = value ? value.uiIndex : -1;
    else if (kind === _K_QUALITY) root._deferredQualityValue = value ? value.value : _Q_NONE;
    try { root._syncTrackMenuIndexes("deferred-ui"); } catch(e0) {}
}
function clearDeferredReloadUi(root) {
    if (!root) return false;
    root._deferredAudioUiIndex = -1;
    root._deferredSubtitleUiIndex = -1;
    root._deferredQualityValue = _Q_NONE;
    try { root._syncTrackMenuIndexes("deferred-clear"); } catch(e0) {}
    return true;
}
function decideSettingChange(root, pick, active) {
    if (!root || !pick) return "noop";
    if (root._deferredReloadReplaying === true) return "applyNow";
    var state = deferredReloadState(root), kind = pick.kind;
    var pending = state[kind] || null;
    var paused = _deferredPauseActive(root), sameActive = _sameSelection(pick, active);
    if (!paused) {
        if (pending) { state[kind] = null; _setDeferredUi(root, kind, null); }
        return sameActive && !pending ? "noop" : "applyNow";
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
    if (pending && _sameSelection(pick, pending)) return "noop";
    state[kind] = pick;
    _setDeferredUi(root, kind, pick);
    _refreshDeferredPrefetch(root, "defer-" + kind);
    return "defer";
}
function decideQualityChoice(root, requested) {
    var pick = _qualitySelection(requested);
    return pick.value === _Q_NONE ? "noop"
            : decideSettingChange(root, pick, currentQualitySelection(root));
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
    root._deferredReloadState = { audio: null, subtitle: null, quality: null };
    clearDeferredReloadUi(root);
    try {
        if (typeof root._invalidateDeferredPrefetch === "function")
            root._invalidateDeferredPrefetch(reason || "reset");
    } catch(e0) {}
    return true;
}
function _pendingPicks(root) {
    var state = deferredReloadState(root), picks = [];
    if (state.audio) picks.push({ kind: _K_AUDIO, value: state.audio });
    if (state.subtitle) picks.push({ kind: _K_SUBTITLE, value: state.subtitle });
    if (state.quality) picks.push({ kind: _K_QUALITY, value: state.quality });
    return picks;
}
/* PlaybackInfo anticipé pendant PAUSE. QtMultimedia reste sur la source courante. */
function deferredPrefetchKey(root) {
    if (!root) return "";
    var state = deferredReloadState(root), audio = state.audio, subtitle = state.subtitle;
    if (state.quality || (!audio && !subtitle)
            || (audio && audio.manualDirectPlay === true)) return "";
    return [
        String(root.itemId || ""), String(root.serverUrl || ""), String(root.userId || ""),
        audio ? ("a:" + audio.stream + ":" + audio.uiIndex) : "a:-",
        subtitle ? ("s:" + subtitle.stream + ":" + subtitle.uiIndex) : "s:-",
        "ca:" + root.selectedAudioStream, "cs:" + root.selectedSubtitleStream,
        "ls:" + root.localSubStreamIndex, "ul:" + (root.useLocalSubs ? 1 : 0),
        "mr:" + (root.manualRemuxMode ? 1 : 0),
        "mq:" + Math.max(0, Math.floor(_numberOr(root.manualQualityBitrate, 0))),
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
    } catch(e0) {}
    return false;
}
function prefetchDeferredReload(root,router,requestSeq){
    if (!root || !router || typeof router.negotiatePlayback !== "function"
            || root._tearingDownPlayer || !_deferredPauseActive(root)
            || requestSeq !== root._deferredPrefetchSeq) return false;
    var key = deferredPrefetchKey(root);
    if (!key) return false;
    var state = deferredReloadState(root), audioPick = state.audio, subtitlePick = state.subtitle;
    var audio = root.selectedAudioStream, subtitle = root.selectedSubtitleStream;
    var useLocal = root.useLocalSubs === true, extra = {};
    if (audioPick) {
        if (!(audioPick.stream >= 0) || audioPick.manualDirectPlay === true) return false;
        audio = audioPick.stream;
        if (useLocal && root.localSubStreamIndex >= 0) {
            subtitle = root.localSubStreamIndex;
            useLocal = false;
        }
        extra = _mergeExtra(extra, {
            forceServerSeek: false, forceServerRemux: true, forceRetry: true,
            forceDirectPlayInPlaybackInfo: false, forceDirectStreamInPlaybackInfo: false,
            forceVideoStreamCopyInPlaybackInfo: true, forceAudioStreamCopyInPlaybackInfo: true,
            forceExplicitServerProgressiveSeek: false, forceJellyfinTranscodingUrlCopyRemux: false,
            forcePlaybackInfoAudioStreamIndex: audio
        });
    }
    if (subtitlePick) {
        subtitle = subtitlePick.stream;
        useLocal = false;
        var type = _subtitleTypeForStream(root, subtitle);
        extra = _mergeExtra(extra, {
            forceServerSeek: false, forceServerRemux: true, forceRetry: true,
            forceDirectPlayInPlaybackInfo: false, forceDirectStreamInPlaybackInfo: false,
            forceVideoStreamCopyInPlaybackInfo: true, forceAudioStreamCopyInPlaybackInfo: true,
            forceExplicitServerProgressiveSeek: false, forceJellyfinTranscodingUrlCopyRemux: false,
            forceSubtitleEncode: false, forceTextSubtitleServerBurnIn: false,
            preferServerSubtitleBurnInOnVideoTranscode: false,
            preferExternalTextSubtitlesInRemux: false, allowLocalSubtitleOverlay: false,
            preferImageSubtitleRemux: type === "image", forceFullRemuxForImageSubtitles: false,
            disableDefaultSubtitleRemux: true, disableAutoVoFrenchFullSubtitle: !(subtitle >= 0)
        });
    }
    extra = _mergeExtra(extra, _manualRemuxExtra(root));
    var start = 0;
    try { start = Math.max(0, Math.floor(_numberOr(root.keepUi(), 0))); }
    catch(e0) {
        try { start = Math.max(0, Math.floor(_numberOr(root.uiPositionMs(), 0))); }
        catch(e1) {}
    }
    var ctx = makeCtx(root, {
        selectedAudioStream: audio, selectedSubtitleStream: subtitle, useLocalSubs: useLocal,
        disableAutoVoFrenchFullSubtitle: subtitlePick ? !(subtitle >= 0)
                : root.disableAutoVoFrenchFullSubtitle === true
    }, start, { preferTicks: true });
    _copyOwn(ctx, extra);
    ctx.serverUrl = String(root.serverUrl || "");
    ctx.accessToken = String(root.accessToken || "");
    ctx.userId = String(root.userId || "");
    ctx.itemId = String(root.itemId || "");
    ctx.startMs = start;
    ctx.preferTicks = true;
    ctx.selectedAudioStream = audio;
    ctx.selectedSubtitleStream = subtitle;
    ctx.useLocalSubs = useLocal;
    var streamType = _subtitleTypeForStream(root, subtitle);
    if (extra.selectedSubtitleIsText === undefined) ctx.selectedSubtitleIsText = streamType === "text";
    if (extra.selectedSubtitleIsImage === undefined) ctx.selectedSubtitleIsImage = streamType === "image";
    if (extra.currentPlaybackVideoTranscodeByPolicy === undefined)
        ctx.currentPlaybackVideoTranscodeByPolicy = root.currentPlaybackVideoTranscodeByPolicy === true;
    if (!PlayerSession.applyStickyManualRemux(root, ctx))
        PlayerSession.applyStickyManualQuality(root, ctx);
    ctx.playbackRuleMode = root.playbackRuleMode || "smart";
    ctx.playbackRouterMode = root.playbackDeviceMode || "";
    ctx.playbackRouterBackend = root.playbackBackendMode || "";
    var seq = root._deferredPrefetchSeq;
    try {
        router.negotiatePlayback(ctx, function(res) {
            if (seq !== root._deferredPrefetchSeq || !_deferredPauseActive(root)
                    || deferredPrefetchKey(root) !== key || !res || !res.url) return;
            root._deferredPrefetchResult = {
                key: key, result: res, startMs: start, createdAt: _poNowMs()
            };
        }, function() {});
    } catch(e2) { return false; }
    return true;
}
function _takeDeferredPrefetch(root, key, start, event) {
    if (!root || event !== "resume" || !key) return null;
    var cached = root._deferredPrefetchResult;
    if (!cached || cached.key !== key || !cached.result || !cached.result.url) return null;
    var ttl = Math.max(5000, Math.floor(_numberOr(root.deferredPrefetchTtlMs, 60000)));
    var age = Math.max(0, _poNowMs() - _numberOr(cached.createdAt, 0));
    var delta = Math.abs(Math.floor(_numberOr(cached.startMs, 0))
                         - Math.floor(_numberOr(start, 0)));
    return age <= ttl && delta <= 1500 ? cached.result : null;
}
function mergeCoalescedNegotiationCall(previous, next) {
    if (!previous) return next;
    if (!next) return previous;
    var merged = {
        startMs: next.startMs, forceHls: next.forceHls === true,
        preferTicks: next.preferTicks === true, forceMp4: next.forceMp4 === true,
        forceDPOnAudioSwitch: next.forceDPOnAudioSwitch === true, extra: {}
    };
    var oldExtra = previous.extra || {}, newExtra = next.extra || {};
    var keepAudioTransaction = oldExtra.audioSwitchTransaction === true, key;
    for (key in oldExtra)
        if (Object.prototype.hasOwnProperty.call(oldExtra, key)) merged.extra[key] = oldExtra[key];
    for (key in newExtra) {
        if (!Object.prototype.hasOwnProperty.call(newExtra, key)) continue;
        if (keepAudioTransaction && (key === "audioSwitchTransaction"
                || key.indexOf("previous") === 0)) continue;
        merged.extra[key] = newExtra[key];
    }
    return merged;
}
function coalesceNegotiationIfActive(root, startMs, forceHls, preferTicks,
                                     forceMp4, forceDPOnAudioSwitch, extra) {
    if (!root || root._coalescedNegotiationActive !== true) return false;
    root._coalescedNegotiationCall = mergeCoalescedNegotiationCall(root._coalescedNegotiationCall, {
        startMs: Math.max(0, Math.floor(_numberOr(startMs, 0))),
        forceHls: forceHls === true, preferTicks: preferTicks === true,
        forceMp4: forceMp4 === true, forceDPOnAudioSwitch: forceDPOnAudioSwitch === true,
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
    if (pick.kind === _K_AUDIO)
        handleAudioPick(root, pick.value.stream, pick.value.uiIndex,
                        pick.value.manualDirectPlay === true);
    else if (pick.kind === _K_SUBTITLE)
        switchServerSubtitleStable(root, "deferred-subtitle", pick.value.stream, pick.value.uiIndex);
    else if (pick.kind === _K_QUALITY) {
        try { root._applyQualityChoice(pick.value.value); } catch(e0) {}
    }
}
function replayDeferredReload(root, mp, options) {
    if (!root || !mp || root._tearingDownPlayer) return false;
    options = options || {};
    var event = options.event === "seek" ? "seek" : "resume";
    var key = deferredPrefetchKey(root), snapshot = root._deferredPrefetchResult || null;
    var picks = _pendingPicks(root);
    if (!picks.length) return false;
    root._deferredReloadState = { audio: null, subtitle: null, quality: null };
    clearDeferredReloadUi(root);
    root._deferredReloadReplaying = true;
    root._forceResumeAfterDeferredReload = options.forceResume === true;
    beginCoalescedNegotiation(root);
    try {
        for (var i = 0; i < picks.length; i++) _replayOneDeferredPick(root, picks[i]);
    } catch(e0) {}
    var call = endCoalescedNegotiation(root);
    var target = Math.floor(_numberOr(options.targetUiMs, -1));
    if (call && root._internalDirectPlayReload !== true) {
        if (target >= 0) _retargetQueuedAudioSwitch(root, target, options.forceResume === true);
        call.extra = _mergeExtra(call.extra, { deferredReplay: true });
        var start = target >= 0 ? target : call.startMs;
        if (target < 0 && snapshot && root._deferredPrefetchResult === snapshot) {
            var ready = _takeDeferredPrefetch(root, key, start, event);
            if (ready) call.extra = _mergeExtra(call.extra, { _prefetchedResult: ready });
        }
        try {
            if (typeof root._invalidateDeferredPrefetch === "function")
                root._invalidateDeferredPrefetch("replay");
        } catch(e1) {}
        try {
            root.negotiatePlayback(start, call.forceHls, call.preferTicks,
                                   call.forceMp4, call.forceDPOnAudioSwitch, call.extra);
        } catch(e2) {}
    }
    root._deferredReloadReplaying = false;
    root._forceResumeAfterDeferredReload = false;
    try { root._syncTrackMenuIndexes("deferred-replay"); } catch(e3) {}
    return true;
}
function resumeDeferredReload(root, mp, reason) {
    return replayDeferredReload(root, mp, {
        event: "resume", forceResume: true, targetUiMs: -1, reason: reason
    });
}
function seekDeferredReload(root, mp, targetUiMs, reason, forceResume) {
    return replayDeferredReload(root, mp, {
        event: "seek", forceResume: forceResume === true,
        targetUiMs: targetUiMs, reason: reason
    });
}
function _audioSwitchTransactionExtra(root) {
    return {
        audioSwitchTransaction: true,
        previousAudioIndex: root.audioIndex | 0,
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
    try { root.showScrubPreview(target) } catch(e0) {}
    try { root._pushLocalSubsUiMs(target, true) } catch(e1) {}
    return target
}
function handleAudioPick(root, streamIdx, uiIdx, explicitManualDirectPlay, targetUiOverride) {
    var k = root.keepUi()
    var serverPick = streamIdx >= 0
    var keepManualRemux = root.manualRemuxMode === true
    var queuedResume = (targetUiOverride !== undefined && targetUiOverride !== null)
            ? root._wasPlayingBeforeSwitch === true : false
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
            forceRetry: true, forceServerSeek: false, forceServerRemux: false, forceHlsOnDpSeekFallback: false,
            forceDirectPlayInPlaybackInfo: true, forceDirectStreamInPlaybackInfo: false,
            forceSubtitleEncode: false, preferImageSubtitleRemux: false, forceFullRemuxForImageSubtitles: false,
            manualDirectPlayOverride: true, manualRemuxOverride: false,
            preferFrenchAudio: false, disableAutoFrenchAudio: true,
            disableDefaultSubtitleRemux: true, disableDefaultFrenchAudioOrderRemux: true,
            disableImageSubtitleRiskRemux: true, disableHevcMain10MkvRemux: true, trackSwitchRebase: true
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
            trackSwitchRebase: true, trackSwitchColdLocalSeek: false, trackSwitchLocalStrategy: 0,
            forceExplicitServerProgressiveSeek: false, forceJellyfinTranscodingUrlCopyRemux: false,
            forceServerSeek: false, forceServerRemux: true, forceRetry: true,
            forceDirectPlayInPlaybackInfo: false, forceDirectStreamInPlaybackInfo: false,
            forceVideoStreamCopyInPlaybackInfo: true, forceAudioStreamCopyInPlaybackInfo: true,
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
    // Une piste gérée par Jellyfin quitte nécessairement le DirectPlay manuel.
    // Conserver ce marqueur après un PGS/DVDSub rendait le menu Qualité faux :
    // Vitesse voyait bien le remux réel, tandis que Qualité restait sur DP.
    if (root.manualDirectPlayMode === true)
        root.manualDirectPlayMode = false
    if (root && root.hasOwnProperty("disableAutoVoFrenchFullSubtitle"))
        root.disableAutoVoFrenchFullSubtitle = !(typeof streamIdx === "number" && streamIdx >= 0)
    var subtitleType = _subtitleTypeForStream(root, streamIdx)
    var isImage = subtitleType === "image"
    root.subMenuVisible = false
    var k = root._beginTrackSwitchRebase(reason || "subsServer", false)
    var extra = _mergeExtra({
        trackSwitchRebase: true, trackSwitchColdLocalSeek: false, trackSwitchLocalStrategy: 0,
        forceExplicitServerProgressiveSeek: false, forceJellyfinTranscodingUrlCopyRemux: false,
        forceServerSeek: false, forceServerRemux: true, forceRetry: true,
        forceDirectPlayInPlaybackInfo: false, forceDirectStreamInPlaybackInfo: false,
        forceVideoStreamCopyInPlaybackInfo: true, forceAudioStreamCopyInPlaybackInfo: true,
        forceSubtitleEncode: false,
        forceTextSubtitleServerBurnIn: false,
        preferServerSubtitleBurnInOnVideoTranscode: false,
        preferExternalTextSubtitlesInRemux: false,
        allowLocalSubtitleOverlay: false,
        preferImageSubtitleRemux: isImage,
        forceFullRemuxForImageSubtitles: false,
        disableDefaultSubtitleRemux: true,
        disableAutoVoFrenchFullSubtitle: !(typeof streamIdx === "number" && streamIdx >= 0)
    }, _manualRemuxExtra(root))
    root.negotiatePlayback(k, false, true, false, false, extra)
    root.resetControlsTimer()
}
function handleSubsOff(root) {
    if (!root.isDsLike()) {
        // Coupure purement locale : instantanée, même en pause. Elle rend
        // caduque une éventuelle attente de sous-titre serveur.
        cancelDeferredReload(root, _K_SUBTITLE, "subs-off-local");
        root._localSubtitlePickSeq++; root.subtitleIndex = 0; root.selectedSubtitleStream = -1;
        if (root.hasOwnProperty("disableAutoVoFrenchFullSubtitle")) root.disableAutoVoFrenchFullSubtitle = true;
        root.effectiveSubtitleStream = -1; root._autoLocalizeSubStream = -1;
        root.disableLocalSubsOverlay(); root.subMenuVisible = false;
        root.updateClocksFromPlaybackThrottled(true); root.resetControlsTimer(); return;
    }
    switchServerSubtitleStable(root, "subsOffServer", -1, 0);
}
function handleSubsText(root, item, streamIdx, listIdx) {
    // Contrat ReDeFin :
    //   - DirectPlay pur => overlay local QML
    if (!isPureDirectPlay(root)) {
        switchServerSubtitleStable(root, "subsTextServer", streamIdx, listIdx);
        return;
    }
    // Overlay texte local en DirectPlay pur : aucune négociation, donc aucun
    // report en pause. L'attente serveur éventuelle est annulée.
    cancelDeferredReload(root, _K_SUBTITLE, "subs-text-local");
    if (root.hasOwnProperty("disableAutoVoFrenchFullSubtitle")) root.disableAutoVoFrenchFullSubtitle = false;
    var seq = ++root._localSubtitlePickSeq;
    var old = { index: root.subtitleIndex, selected: root.selectedSubtitleStream, effective: root.effectiveSubtitleStream,
                local: root.useLocalSubs, cues: root.localCues, format: root.localSubFormat, stream: root.localSubStreamIndex };
    root.subMenuVisible = false; root._pendingSubStream = -1; root._pendingSubIndex = -1;
    root._autoLocalizeSubStream = -1;
    root.loadLocalSubtitleByStreamIndex(streamIdx, function(ok) {
        if (seq !== root._localSubtitlePickSeq) return;
        if (ok) {
            root.subtitleIndex = listIdx; root.selectedSubtitleStream = -1; root.effectiveSubtitleStream = -1;
            root._autoLocalizeSubStream = -1; root._lastSubsUiPushMs = -1;
            if (item) { item.cues = root.localCues; item.enabled = root.localCues.length > 0; item.gateArmed = root._gateArmed; }
            root._pushLocalSubsUiMs(root.uiPositionMs(), true); root._syncTrackMenuIndexes("subs-text-local-success");
        } else {
            root.subtitleIndex = old.index; root.selectedSubtitleStream = old.selected; root.effectiveSubtitleStream = old.effective;
            root.useLocalSubs = old.local; root.localCues = old.cues; root.localSubFormat = old.format; root.localSubStreamIndex = old.stream;
            root._lastSubsUiPushMs = -1;
            if (item) { item.cues = old.cues; item.enabled = old.local && old.cues && old.cues.length > 0; item.gateArmed = root._gateArmed; }
            root._syncTrackMenuIndexes("subs-text-local-restore");
        }
        root.updateClocksFromPlaybackThrottled(true); root.resetControlsTimer();
    }, true);
}
function handleSubsImage(root, streamIdx, listIdx) {
    // PGS/VobSub sont bitmap. L'overlay QML actuel accepte uniquement des cues
    // texte SRT/VTT : la piste reste donc gérée par Jellyfin. La policy de la
    // Freebox décide ensuite entre Remux+Embed (codecs déjà compatibles) et
    // Encode/burn-in lorsqu'un vrai transcodage vidéo est nécessaire.
    switchServerSubtitleStable(root, "subsImageServer", streamIdx, listIdx);
}
/* ===== Machines seek/source PlayerOverlay ===== */
function _poNowMs(){ return Date.now ? Date.now() : (new Date()).getTime(); }
function resetSeekRestoreState(root, targetMs) {
    root._seekRestoreAttempts = 0;
    root._seekRestoreHlsFallbackTried = false;
    root._seekRestoreLastTargetMs = (targetMs !== undefined && targetMs !== null)
            ? Math.max(0, Math.floor(Number(targetMs || 0))) : -1;
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
function resetSeekRestoreGuard(root,targetMs,reason){
    resetSeekRestoreState(root,targetMs);
    if((reason||"")==="boot-seek"&&root._seekRestoreLastTargetMs>0) root._armSkipIntroResumeGate(root._seekRestoreLastTargetMs,"boot-seek");
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
        try { mp.pause(); } catch(e0) {}
    }
    return p;
}
function trackSwitchRebasedStartMs(root,fallbackMs){
    var p=root._trackSwitchRebaseActive?root._trackSwitchAnchorUiMs:Math.max(0,Math.floor(Number(fallbackMs||0))); return root._clampUi(p);
}
function armTrackSwitchTimebaseSettle(root,timer){
    if(!root._trackSwitchRebaseActive)return; root._trackSwitchSettleTicks=0; root._lastUiClockPushWallMs=0; root.updateClocksFromPlayback(); timer.restart();
}
function trackSwitchFragileHevc(root){
    var c=String(root._trackSwitchSourceVideoCodec||"").toLowerCase(),k=String(root._trackSwitchSourceContainer||"").toLowerCase();
    return !!(root._trackSwitchSourceHevc10||((c==="hevc"||c==="h265")&&(k==="mkv"||k==="matroska")));
}
function seekRestoreAttemptLimit(root){ return trackSwitchFragileHevc(root)?1:Math.max(1,root.trackSwitchSeekMaxAttempts); }
function seekRestoreDeadlineMs(root){ return trackSwitchFragileHevc(root)?root.trackSwitchSeekHevcMaxTotalMs:root.trackSwitchSeekMaxTotalMs; }
function seekRestoreIsTrueTrackSwitch(root){ return !!(root._trackSwitchRebaseActive&&root._trackSwitchVerificationActive); }
function seekRestoreToleranceMs(root){ return seekRestoreIsTrueTrackSwitch(root)?Math.max(1,root.trackSwitchSeekToleranceMs|0):Math.max(1,root.seekRestoreBootToleranceMs|0); }
function rememberSeekRestoreSample(root,localNow,localTarget){
    var d=Math.abs(Math.max(0,localNow|0)-Math.max(0,localTarget|0));
    if(d<root._seekRestoreBestDiffMs){root._seekRestoreBestDiffMs=d;root._seekRestoreBestLocalMs=Math.max(0,localNow|0);} return d;
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
    try { seekTimer.stop(); } catch(e0) {}
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
function abandonBootSeekRestoreWithoutReload(root,seekTimer,targetUi,reason){
    root._pendingSeekMs=-1; resetSeekRestoreState(root,null); try{seekTimer.stop();}catch(e0){}
    root._releaseSkipIntroResumeGate(Math.max(targetUi,root.uiPositionMs())); root.updateClocksFromPlaybackThrottled(true);
}
function shouldEscalateSeekRestore(root,diff){
    var t=seekRestoreToleranceMs(root); if(root._seekRestoreAccepted||root._seekRestoreBestDiffMs<=t||diff<=t)return false;
    return root._seekRestoreAttempts>=seekRestoreAttemptLimit(root);
}
function failTrackSwitchExactSeek(root, mp, seekTimer, settleTimer, restartTimer) {
    var restart = !!(root._trackSwitchWasPlaying || root._wasPlayingBeforeSwitch);
    try { seekTimer.stop(); } catch(e0) {}
    try { settleTimer.stop(); } catch(e1) {}
    root._pendingSeekMs = -1;
    root.baseOffsetMs = 0;
    root.serverTimedStream = false;
    root.timeShifted = false;
    root._trackSwitchVerificationActive = false;
    root._trackSwitchTimebaseVerified = false;
    resetSeekRestoreState(root, null);
    root._trackSwitchRestartAfterFailure = restart;
    try { mp.stop(); } catch(e2) {}
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
    try { settleTimer.stop(); } catch(e0) {}
}
function tickSeekRestore(root,mp,timer){
    if(root._pendingSeekMs<0){timer.stop();return;} if(mp.status!==root._mpBuffered&&mp.status!==root._mpLoaded)return;
    var now=_poNowMs(); if(root._seekRestoreReadyWallMs<=0)root._seekRestoreReadyWallMs=now;
    var target=root._pendingSeekMs,localTarget=root._trackSwitchVerificationActive?target:Math.max(0,target-root.baseOffsetMs);
    if(mp.duration>0)localTarget=Math.min(localTarget,mp.duration); if(root._seekRestoreLastTargetMs!==target)root._resetSeekRestoreGuard(target,"target-changed");
    var local=Math.max(0,mp.position|0),diff=rememberSeekRestoreSample(root,local,localTarget),tol=seekRestoreToleranceMs(root);
    if(root._seekRestoreAttempts>0&&diff<=tol){root._completeSeekRestoreVerified(target,local,diff,"first-acceptable-sample");return;}
    root._seekRestoreStableSamples=0;
    if(now-root._seekRestoreReadyWallMs>=seekRestoreDeadlineMs(root)){
        if(root._seekRestoreBestDiffMs<=tol&&root._seekRestoreBestLocalMs>=0)root._completeSeekRestoreVerified(target,root._seekRestoreBestLocalMs,root._seekRestoreBestDiffMs,"best-sample-at-timeout");
        else root._retrySeekRestoreWithJellyfinCopyRemux(target,"local-seek-timeout"); return;
    }
    if(root._seekRestoreAwaitingResult){
        if(now-root._seekRestoreLastCallWallMs<root.trackSwitchSeekRetryDelayMs)return; root._seekRestoreAwaitingResult=false;
        if(shouldEscalateSeekRestore(root,diff)){root._retrySeekRestoreWithJellyfinCopyRemux(target,"local-seek-unverified");return;}
    }
    if(root._trackSwitchVerificationActive&&root._seekRestorePhase<3){
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
        var keepPlayingStaticDp = root.manualDirectPlayMode===true &&
                                  root._trackSwitchWasPlaying===true &&
                                  isStaticDirectPlaySource(root);
        if(root._seekRestorePhase===0){
            root._seekRestorePhase=1;root._seekRestorePrimeWallMs=now;root._seekRestorePauseWallMs=0;
            if(mp.playbackState!==root._mpPlayingState){try{mp.play();}catch(e0){}}
            return;
        }
        if(root._seekRestorePhase===1){
            if(now-root._seekRestorePrimeWallMs<root.trackSwitchPrimeMinMs&&local<80){
                if(mp.playbackState!==root._mpPlayingState){try{mp.play();}catch(e1){}}
                return;
            }
            if(keepPlayingStaticDp){
                // Pas de pause intermédiaire : évite qu'un pause asynchrone du
                // backend intelce ne rattrape la commande play après le seek.
                root._seekRestorePhase=3;
            }else{
                root._seekRestorePhase=2;root._seekRestorePauseWallMs=now;try{mp.pause();}catch(e2){}return;
            }
        }
        if(root._seekRestorePhase===2&&now-root._seekRestorePauseWallMs<root.trackSwitchPauseGraceMs)return;
    }
    root._seekRestoreAttempts++; root._seekRestoreAwaitingResult=true; root._seekRestoreLastCallWallMs=now; root._seekRestorePhase=3;
    try{root._seekLocalPosition(localTarget);}catch(e3){}
}
function uniqueMediaSourceUrl(root,url){
    var s=String(url||""); if(!s)return s; root._sourceResetRevision++;
    return s+(s.indexOf("?")>=0?"&":"?")+"RdfSourceRevision="+root._sourceResetRevision+"_"+Math.floor(_poNowMs());
}
function cancelHardSourceReset(root, timer) {
    if (!root._sourceResetActive && root._sourceResetPhase === 0) return;
    try { timer.stop(); } catch(e0) {}
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
/*
 * Filet de sécurité du loader vidéo.
 *
 * _scheduleVideoLoadingRelease() et les libérations « position-progress » /
 * « state-playing » exigent toutes l'état Playing. Un rechargement qui se
 * termine volontairement en pause (changement de piste, de sous-titre ou de
 * qualité effectué pendant une pause) ne repasse donc jamais par ces chemins :
 * la gate doit être libérée explicitement, sinon le spinner reste affiché
 * au-dessus d'une image déjà décodée.
 */
function releaseVideoLoadingWhenPaused(root, reason) {
    if (!root || typeof root._releaseVideoLoading !== "function") return false;
    try { root._releaseVideoLoading(reason || "ready-paused"); } catch(e0) { return false; }
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
    try { timer.stop(); } catch(e0) {}
    root._gateArmed = false;
    root._resumeAfterGate = false;
    root._startupPlayWanted = false;
    if (subtitleItem) subtitleItem.gateArmed = false;
    root._scheduleVideoLoadingRelease("fresh-source-reset-complete");
}
function completeFreshServerTimedSource(root,mp,timer,subtitleItem){
    if(!root._sourceResetActive||root._sourceResetPhase!==2)return;
    var expected=Math.max(0,Math.floor(Number(root._sourceResetExpectedUiMs||0))),resume=root._sourceResetShouldResume;
    root.baseOffsetMs=expected; root._pendingServerTimedBaseMs=-1; root._pendingHardResetBaseMs=-1;
    root.serverTimedStream=true; root.timeShifted=expected>0; root._trackSwitchTimebaseVerified=true;
    completeFreshSourceResetState(root,timer,subtitleItem);
    if(resume){if(mp.playbackState!==root._mpPlayingState){try{mp.play();}catch(e0){}}}
    else{
        try{mp.pause();}catch(e1){}
        // La lecture était en pause avant le rechargement : on restaure la pause,
        // mais toutes les libérations de la gate de chargement exigent l'état
        // Playing. Sans libération explicite ici, le loader resterait affiché
        // indéfiniment par-dessus une vidéo pourtant prête.
        releaseVideoLoadingWhenPaused(root,"fresh-source-ready-paused");
    }
    root.updateClocksFromPlaybackThrottled(true);
}
function beginHardSourceReset(root, mp, timer, audioGateTimer, startupTimer,
                              subtitleItem, url, shouldResume) {
    root._armVideoLoading("hard-source-reset");
    root._cancelStartupPlay("hard-source-reset");
    try { audioGateTimer.stop(); } catch(e0) {}
    try { startupTimer.stop(); } catch(e1) {}
    root._sourceResetActive = true;
    root._sourceResetPhase = 1;
    root._sourceResetMode = "server-timed";
    root._sourceResetPendingUrl = uniqueMediaSourceUrl(root, url);
    root._sourceResetShouldResume = !!shouldResume;
    var base = root._pendingHardResetBaseMs >= 0
            ? root._pendingHardResetBaseMs : root._pendingServerTimedBaseMs;
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
    try { mp.stop(); } catch(e2) {}
    root.mediaUrl = "";
    root._setMediaPlayerSource("", "hard-reset-clear");
    timer.restart();
}
function beginFreshDirectPlayReset(root, mp, timer, audioGateTimer, startupTimer,
                                   subtitleItem, url, shouldResume, targetUi) {
    root._armVideoLoading("fresh-directplay-reset");
    root._cancelStartupPlay("fresh-directplay-reset");
    try { audioGateTimer.stop(); } catch(e0) {}
    try { startupTimer.stop(); } catch(e1) {}
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
    try { mp.stop(); } catch(e2) {}
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
    try { timer.stop(); } catch(e0) {}
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
            try { mp.play(); } catch(e1) {}
        }
        try { seekTimer.restart(); } catch(e2) {}
        return;
    }
    root._trackSwitchTimebaseVerified = true;
    root._gateArmed = false;
    root._resumeAfterGate = false;
    root._startupPlayWanted = false;
    if (subtitleItem) subtitleItem.gateArmed = false;
    root._scheduleVideoLoadingRelease("fresh-directplay-reset-complete");
    if (resume && mp.playbackState !== root._mpPlayingState) {
        try { mp.play(); } catch(e3) {}
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
        var cleared = mp.playbackState === root._mpStoppedState
                   && mp.status === root._mpNoMedia;
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
        try { mp.play(); } catch(e0) {}
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
        if (ready
                && mp.playbackState === root._mpStoppedState
                && elapsed >= root.sourceResetStartRetryMs
                && root._sourceResetPlayRetries < 1) {
            root._sourceResetPlayRetries++;
            try { mp.play(); } catch(e1) {}
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
    if (ready
            && mp.playbackState === root._mpStoppedState
            && elapsed >= root.sourceResetStartRetryMs
            && root._sourceResetPlayRetries < 1) {
        root._sourceResetPlayRetries++;
        try { mp.play(); } catch(e2) {}
        return;
    }
    if (elapsed >= root.sourceResetStartTimeoutMs)
        root._finishFreshServerTimedSourceTimeout("startup-timeout");
}
/* ===== DirectPlay statique / remux de secours ===== */
function isCurrentItemDirectPlaySeekUnsafe(root) {
    return !!(root && root._staticDirectPlaySeekUnsafe === true &&
              String(root._staticDirectPlaySeekUnsafeItemId || "") === String(root.itemId || ""));
}
function markCurrentItemDirectPlaySeekUnsafe(root) {
    root._staticDirectPlaySeekUnsafe = true;
    root._staticDirectPlaySeekUnsafeItemId = String(root.itemId || "");
}
function isStaticDirectPlaySource(root) {
    try { return urlKind(root.mediaUrl || "") === "http-dp-static"; } catch(e0) { return false; }
}
function directPlayOpenFallbackTargetMs(root) {
    var target=0;
    if (root._pendingSeekMs >= 0) target=Math.max(0,Math.floor(Number(root._pendingSeekMs||0)));
    else if (root.lastUiTargetMs > 0) target=Math.max(0,Math.floor(Number(root.lastUiTargetMs||0)));
    else { try { target=Math.max(0,Math.floor(Number(root.uiPositionMs()||0))); } catch(e0) { target=0; } }
    return target;
}
function fallbackStaticDirectPlayToServerRemux(root, mp, timers, targetUi, reason) {
    if (!root || root._tearingDownPlayer) return false;
    if (root._staticDirectPlaySeekFallbackInProgress) return true;
    if (!isStaticDirectPlaySource(root) && !isCurrentItemDirectPlaySeekUnsafe(root)) return false;
    targetUi=root._clampUi(Math.max(0,Math.floor(Number(targetUi||0))));
    markCurrentItemDirectPlaySeekUnsafe(root);
    root._staticDirectPlaySeekFallbackInProgress=true;
    root._staticDirectPlayFallbackAwaitingStableRemux=true;
    root._staticDirectPlayFallbackTargetMs=targetUi;
    root._staticDirectPlayFallbackStartedWallMs=root._nowMs();
    root.manualDirectPlayMode=false;
    root.coalescedDirectPlaySeekMode=false;
    var resume=root._trackSwitchWasPlaying||root._wasPlayingBeforeSwitch||mp.playbackState===root._mpPlayingState;
    root._resumeWantedAfterNegotiation=resume; root.lastUiTargetMs=targetUi; root.showScrubPreview(targetUi);
    _timerStop(timers && timers.startup); _timerStop(timers && timers.seekRestore); _timerStop(timers && timers.scrubCommit);
    root._startupPlayWanted=false; root._startupPlayTries=0; root._pendingSeekMs=-1;
    root._pendingServerTimedBaseMs=-1; root._pendingHardResetBaseMs=-1;
    root._seekRestoreAttempts=0; root._seekRestoreLastTargetMs=-1; root._seekRestoreAwaitingResult=false;
    root._seekRestoreReadyWallMs=0; root._trackSwitchForceLocalSeek=false;
    root._trackSwitchVerificationActive=false; root._trackSwitchTimebaseVerified=true;
    root.negotiatePlayback(targetUi,false,true,false,false,{
        staticDirectPlayFallbackOwner:true, trackSwitchRebase:root._trackSwitchRebaseActive,
        trackSwitchColdLocalSeek:false, forceServerSeek:true, forceServerRemux:true,
        forceExplicitServerProgressiveSeek:true, forceJellyfinTranscodingUrlCopyRemux:false,
        forceHlsOnDpSeekFallback:false, forceRetry:true, forceDirectPlayInPlaybackInfo:false,
        forceDirectStreamInPlaybackInfo:false, forceVideoStreamCopyInPlaybackInfo:true,
        forceAudioStreamCopyInPlaybackInfo:true, manualDirectPlayOverride:false,
        preferFrenchAudio:true, disableAutoFrenchAudio:false, disableDefaultSubtitleRemux:false,
        disableDefaultFrenchAudioOrderRemux:false, disableImageSubtitleRiskRemux:false,
        disableHevcMain10MkvRemux:false
    });
    return true;
}
function guardUnsafeManualDirectPlayRequest(root, mp, timers, targetUi, reason) {
    if (!isCurrentItemDirectPlaySeekUnsafe(root)) return false;
    targetUi=root._clampUi(Math.max(0,Math.floor(Number(targetUi||0))));
    root.manualDirectPlayMode=false; root.lastUiTargetMs=targetUi; root.showScrubPreview(targetUi);
    if (root._staticDirectPlaySeekFallbackInProgress || root.lastUsedServerRemux ||
            root.lastUsedDirectStream || root.serverTimedStream || root.timeShifted || root.baseOffsetMs>0) return true;
    return fallbackStaticDirectPlayToServerRemux(root,mp,timers,targetUi,reason||"unsafe-manual-directplay-blocked");
}
function maybeCompleteStaticDirectPlayFallback(root, mp) {
    if (!root._staticDirectPlaySeekFallbackInProgress || !root._staticDirectPlayFallbackAwaitingStableRemux) return false;
    if (isStaticDirectPlaySource(root)) return false;
    if (!(mp.status===root._mpLoaded || mp.status===root._mpBuffered)) return false;
    var remuxLike=root.lastUsedServerRemux||root.lastUsedDirectStream||root.serverTimedStream||root.timeShifted||root.baseOffsetMs>0;
    if (!remuxLike) return false;
    var target=Math.max(0,Number(root._staticDirectPlayFallbackTargetMs||0)), ui=0;
    try { ui=Math.max(0,Number(root.uiPositionMs()||0)); } catch(e0) {}
    var coherent=target<=0||Math.abs(ui-target)<=5000||root.baseOffsetMs>=Math.max(0,target-2500)||
                 (mp.position>0&&ui>=Math.max(0,target-2500));
    if (!coherent) return false;
    root._staticDirectPlaySeekFallbackInProgress=false; root._staticDirectPlayFallbackAwaitingStableRemux=false;
    root._staticDirectPlayFallbackTargetMs=-1; root._staticDirectPlayFallbackStartedWallMs=0;
    return true;
}
function tryDirectPlayOpenRemuxFallback(root, mp, timers, reason) {
    if (root._directPlayOpenFallbackUsed || root._tearingDownPlayer) return false;
    if (!isStaticDirectPlaySource(root) || root.lastUsedServerRemux || root.lastUsedTranscoding || root.lastUsedDirectStream || root.isHls) return false;
    if (root._sourceResetActive || root._mediaErrorRecoveryInProgress || root._mediaErrorRecoveryArmed) return false;
    var stopped=mp.playbackState===root._mpStoppedState || mp.playbackState===root._mpPausedState;
    var opening=mp.status===root._mpLoading || mp.status===root._mpStalled;
    var local=Math.max(0,Math.floor(Number(mp.position||0)));
    var elapsed=root._directPlayOpenStartedWallMs>0 ? root._nowMs()-root._directPlayOpenStartedWallMs : 0;
    if (!stopped||!opening||local>250||elapsed<root.directPlayOpenFallbackMinMs) return false;
    var target=directPlayOpenFallbackTargetMs(root); root._directPlayOpenFallbackUsed=true;
    if (root.manualDirectPlayMode) {
        if (target<=0) return false;
        return fallbackStaticDirectPlayToServerRemux(root,mp,timers,target,reason||"dp-open-manual");
    }
    root._startupPlayWanted=false; root._startupPlayTries=0; root._gateArmed=false; root._resumeAfterGate=false;
    _timerStop(timers&&timers.startup); _timerStop(timers&&timers.audioGate); _timerStop(timers&&timers.seekRestore);
    root._pendingSeekMs=-1; root._pendingServerTimedBaseMs=-1; root._pendingHardResetBaseMs=-1;
    root._seekRestoreAttempts=0; root._seekRestoreLastTargetMs=-1;
    try { mp.stop(); } catch(e4) {}
    root.mediaUrl=""; root._setMediaPlayerSource("","dp-open-remux-fallback-clear");
    root._resumeWantedAfterNegotiation=true;
    root.negotiatePlayback(target,false,target>0,false,false,{
        forceServerRemux:true, forceRetry:true, forceDirectPlayInPlaybackInfo:false,
        forceDirectStreamInPlaybackInfo:false, forceVideoStreamCopyInPlaybackInfo:true,
        forceAudioStreamCopyInPlaybackInfo:true
    });
    return true;
}
/* ===== Reprise, gel et erreurs média ===== */
function recoveryCandidateUiMs(root, mp) {
    var cur=root._clampUi(root.uiPositionMs()), target=cur;
    var stable=root._pauseWatchLastStableUiMs, pause=root._pauseWatchStartedUiMs;
    var reset=!!(root._serverTimedLike()&&mp.position<=1000&&cur<=root.baseOffsetMs+1500);
    if(root.lastUiTargetMs>0)target=Math.max(target,root._clampUi(root.lastUiTargetMs));
    if(stable>0&&(reset||stable>cur+2500))target=Math.max(target,root._clampUi(stable));
    if(pause>0&&(reset||pause>cur+2500))target=Math.max(target,root._clampUi(pause));
    return root._clampUi(target);
}
function markMediaRecoveryPosition(root,targetUi,reason){
    targetUi=root._clampUi(targetUi); root._mediaErrorRecoverySafeUiMs=targetUi;
    root._mediaErrorProgressGuardUntilWallMs=root._nowMs()+45000;
    root._mediaErrorRecoveryInProgress=true; root._mediaErrorRecoveryReason=reason||"mediaError";
}
function reportUiPositionMs(root,mp){
    var pos=root._clampUi(root.uiPositionMs()), now=root._nowMs();
    var safe=root._mediaErrorRecoverySafeUiMs>0?root._mediaErrorRecoverySafeUiMs:root._pauseWatchLastStableUiMs;
    var guard=!!(root._mediaErrorRecoveryArmed||root._mediaErrorRecoveryInProgress||now<root._mediaErrorProgressGuardUntilWallMs);
    var reset=!!(root._serverTimedLike()&&(mp.position<=1000||pos<=root.baseOffsetMs+1500));
    if(guard&&safe>0&&pos<safe-2500&&reset)return root._clampUi(safe);
    return pos;
}
function sameModeRecoveryFlags(root){var h=!!root.isHls;return{keepHls:h,keepServerRemux:!!(root.lastUsedServerRemux&&!h)};}
function recoverSameModeAt(root,targetUi,reason){
    targetUi=root._clampUi(targetUi); var safe=root._clampUi(targetUi>2500?targetUi-root.resumePrerollMs:targetUi);
    if(root._serverTimedLike()&&root.baseOffsetMs>0&&safe<root.baseOffsetMs)safe=root.baseOffsetMs;
    var f=sameModeRecoveryFlags(root); markMediaRecoveryPosition(root,targetUi,reason||"sameModeRetry");
    root._resumeWantedAfterNegotiation=true;
    root.negotiatePlayback(safe,f.keepHls,true,false,false,{forceRetry:true,forceServerSeek:false,
        forceServerRemux:f.keepServerRemux,forceHlsOnDpSeekFallback:false});
}
function armFrozenPlaybackWatch(root,mp,timer,reason,windowMs){
    if(!root._serverTimedLike()&&!root.lastUsedServerRemux)return;
    var now=root._nowMs(); root._frozenPlaybackWatchActive=true; root._frozenPlaybackWatchArmedWallMs=now;
    root._frozenPlaybackWatchUntilWallMs=now+Math.max(8000,windowMs||root.frozenPlaybackWatchWindowMs);
    root._frozenPlaybackNoProgressSinceWallMs=0; root._frozenPlaybackLastLocalMs=Math.max(0,mp.position||0);
    root._frozenPlaybackLastUiMs=root._clampUi(root.uiPositionMs()); _timerRestart(timer);
}
function stopFrozenPlaybackWatch(root,timer){
    root._frozenPlaybackWatchActive=false; root._frozenPlaybackNoProgressSinceWallMs=0;
    root._frozenPlaybackLastLocalMs=-1; root._frozenPlaybackLastUiMs=-1; _timerStop(timer);
}
function recoverFromFrozenPlayback(root,mp,watchTimer,guardTimer,reason){
    if(root._mediaErrorRecoveryArmed||root._mediaErrorRecoveryInProgress)return;
    root._frozenPlaybackRecoveryCount++; root._mediaErrorRecoveryArmed=true; _timerRestart(guardTimer);
    if(root._frozenPlaybackRecoveryCount>3){stopFrozenPlaybackWatch(root,watchTimer);return;}
    var target=root._clampUi(recoveryCandidateUiMs(root,mp)); stopFrozenPlaybackWatch(root,watchTimer);
    recoverSameModeAt(root,target,"frozenPlaybackSameModeRetry");
    armFrozenPlaybackWatch(root,mp,watchTimer,"postFrozenRecovery",root.frozenPlaybackWatchWindowMs);
}
function tickFrozenPlaybackWatch(root,mp,watchTimer,guardTimer){
    if(!root._frozenPlaybackWatchActive)return; var now=root._nowMs();
    if(root._frozenPlaybackWatchUntilWallMs>0&&now>root._frozenPlaybackWatchUntilWallMs){stopFrozenPlaybackWatch(root,watchTimer);return;}
    if(!root._serverTimedLike()&&!root.lastUsedServerRemux){stopFrozenPlaybackWatch(root,watchTimer);return;}
    if(root._mediaErrorRecoveryInProgress||root._mediaErrorRecoveryArmed||root._gateArmed||root._startupPlayWanted||root.scrubActive){
        root._frozenPlaybackLastLocalMs=Math.max(0,mp.position||0);root._frozenPlaybackLastUiMs=root._clampUi(root.uiPositionMs());
        root._frozenPlaybackNoProgressSinceWallMs=0;_timerRestart(watchTimer);return;}
    if(mp.playbackState!==root._mpPlayingState||!(mp.status===root._mpBuffered||mp.status===root._mpLoaded)){
        root._frozenPlaybackLastLocalMs=Math.max(0,mp.position||0);root._frozenPlaybackLastUiMs=root._clampUi(root.uiPositionMs());
        root._frozenPlaybackNoProgressSinceWallMs=0;_timerRestart(watchTimer);return;}
    if(root._frozenPlaybackWatchArmedWallMs>0&&now-root._frozenPlaybackWatchArmedWallMs<root.frozenPlaybackStartupGraceMs){_timerRestart(watchTimer);return;}
    var local=Math.max(0,mp.position||0),ui=root._clampUi(root.uiPositionMs()),progressed=false;
    if(root._frozenPlaybackLastLocalMs>=0&&local>root._frozenPlaybackLastLocalMs+300)progressed=true;
    if(root._frozenPlaybackLastUiMs>=0&&ui>root._frozenPlaybackLastUiMs+300)progressed=true;
    if(progressed){root._frozenPlaybackLastLocalMs=local;root._frozenPlaybackLastUiMs=ui;root._frozenPlaybackNoProgressSinceWallMs=0;
        root._frozenPlaybackRecoveryCount=0;if(ui>0&&local>0){root._pauseWatchLastStableUiMs=Math.max(root._pauseWatchLastStableUiMs,ui);root._pauseWatchLastStableWallMs=now;}
        _timerRestart(watchTimer);return;}
    if(root._frozenPlaybackNoProgressSinceWallMs<=0){root._frozenPlaybackNoProgressSinceWallMs=now;_timerRestart(watchTimer);return;}
    if(Math.floor(now-root._frozenPlaybackNoProgressSinceWallMs)>=root.frozenPlaybackNoProgressMs){
        recoverFromFrozenPlayback(root,mp,watchTimer,guardTimer,"playingBufferedNoProgress");return;}
    _timerRestart(watchTimer);
}
function recoverFromMediaError(root,mp,watchTimer,guardTimer){
    if(root._mediaErrorRecoveryArmed)return;
    if(root.isHls&&root._serverTimedLike()&&root.lastUiTargetMs>2500&&root._mediaErrorRecoveryCount<2){
        root._mediaErrorRecoveryCount++;root._mediaErrorRecoveryArmed=true;_timerRestart(guardTimer);
        markMediaRecoveryPosition(root,root.lastUiTargetMs,"hlsInvalidFallbackRemux");root._resumeWantedAfterNegotiation=true;
        root.negotiatePlayback(root._clampUi(root.lastUiTargetMs),false,true,false,false,{forceRetry:true,forceServerSeek:true,
            forceServerRemux:true,forceHlsOnDpSeekFallback:false,forcePolicyTranscodeHls:false,
            forcePolicyTranscodeAllowAudioCopy:true,forceVideoStreamCopyInPlaybackInfo:true,
            forceAudioStreamCopyInPlaybackInfo:true});return;}
    root._mediaErrorRecoveryArmed=true;_timerRestart(guardTimer);root._mediaErrorRecoveryCount++;
    var target=root._clampUi(recoveryCandidateUiMs(root,mp));
    if(root._mediaErrorRecoveryCount>4)return;
    recoverSameModeAt(root,target,"mediaErrorSameModeRetry");
    armFrozenPlaybackWatch(root,mp,watchTimer,"postMediaErrorRecovery",root.frozenPlaybackWatchWindowMs);
}
/* ===== Source, seek et négociation ===== */
function _timerStop(t) {
    try {
        if (t && t.stop) t.stop();
    } catch(e) {}
}

function _timerRestart(t) {
    try {
        if (t && t.restart) t.restart();
        else if (t && t.start) t.start();
    } catch(e) {}
}

function mediaUrlSwap(root, mp, timers, subtitleItem, u, resume) {
    var first = (!root.mediaUrl || root.mediaUrl.length === 0) && !root._sourceResetActive;
    root._armVideoLoading(first ? "media-url-first" : "media-url-swap");

    var shouldResume = !!resume || first;
    var freshManualStaticDp = root.manualDirectPlayMode === true
        && root._trackSwitchVerificationActive === true
        && root._pendingSeekMs >= 0
        && urlKind(u || "") === "http-dp-static";

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
    root._directPlayOpenStartedWallMs = urlKind(u || "") === "http-dp-static" ? root._nowMs() : 0;

    if (subtitleItem) subtitleItem.gateArmed = true;
    if (root.mediaUrl !== u) root.mediaUrl = u;
    try { mp.stop(); } catch(e0) {}

    if (root._pendingServerTimedBaseMs >= 0) {
        root.baseOffsetMs = Math.max(0, Math.floor(Number(root._pendingServerTimedBaseMs || 0)));
        root._pendingServerTimedBaseMs = -1;
    }

    root._setMediaPlayerSource(root.mediaUrl, "mediaUrlSwap");
    try { mp.play(); } catch(e1) {}

    if (!shouldResume) {
        if (root._trackSwitchVerificationActive && root._pendingSeekMs >= 0) {
            root._seekRestorePhase = 0;
            root._seekRestorePrimeWallMs = 0;
            root._seekRestorePauseWallMs = 0;
        } else {
            try { mp.pause(); } catch(e2) {}
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

    root._resumeWantedAfterNegotiation = root._wasPlayingBeforeSwitch
        || mp.playbackState === root._mpPlayingState;
    var hls = false;
    var remux = root.lastUsedServerRemux
        || root.serverTimedStream
        || root.timeShifted
        || root.baseOffsetMs > 0;
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
    } catch(e) {
        serverSeekFallback(root, mp, timers, targetUi, (reason || "localSeek") + ":seek-error");
        return false;
    }
}

function seekToChapter(root, mp, timers, targetUi) {
    if (!root || !mp || root._tearingDownPlayer) return false;
    targetUi = root._clampUi(Math.max(0, Math.floor(Number(targetUi || 0))));

    try {
        if (timers && timers.scrubCommit) timers.scrubCommit.stop();
    } catch(e0) {}
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
        try { mp.pause(); } catch(e1) {}
        root._resumeWantedAfterNegotiation = resume;
        // Un réglage différé doit voyager avec la renégociation du chapitre :
        // une seule négociation, à la position du chapitre.
        if (seekDeferredReload(root, mp, targetUi, "chapter-carousel", resume)) return true;
        serverSeekFallback(root, mp, timers, targetUi, "chapter-carousel");
        return true;
    }

    var ok = localSeekTo(root, mp, timers, targetUi, "chapter-carousel");
    if (resume) {
        try { mp.play(); } catch(e2) {}
    }
    return ok;
}

function abortNegotiationWithoutDirectPlay(root, code, reason) {
    root._resumeWantedAfterNegotiation = false;
    root._startupPlayWanted = false;
    root._startupPlayTries = 0;
    root._pendingSeekMs = -1;
    root._pendingServerTimedBaseMs = -1;
    root._pendingHardResetBaseMs = -1;
    root._releaseVideoLoading("negotiation-abort");
}

function _copyOwn(dst, src) {
    if (!dst || !src) return dst;
    for (var k in src) {
        if (Object.prototype.hasOwnProperty.call(src, k)) dst[k] = src[k];
    }
    return dst;
}

function _numberOr(value, fallback) {
    var n = Number(value);
    return isFinite(n) ? n : fallback;
}
function _subtitleTypeForStream(root,streamIdx){
    var map=root&&root.subtitleStreamIndexMap?root.subtitleStreamIndexMap:[];
    var textMap=root&&root.subtitleIsTextMap?root.subtitleIsTextMap:[];
    for(var i=0;i<map.length;i++)if(Number(map[i])===Number(streamIdx))
        return textMap[i]===true?"text":"image";
    return "unknown";
}
function _negotiationStillCurrent(root,seq,item,server,user,token){
    return !!root&&!root._tearingDownPlayer&&seq===root._negotiationSeq&&
        String(root.itemId||"")===item&&String(root.serverUrl||"")===server&&
        String(root.userId||"")===user&&String(root.accessToken||"")===token;
}
function _stopNegotiationTimers(timers){
    _timerStop(timers&&timers.seekRestore);
    _timerStop(timers&&timers.sourceReset);
}
function _restoreAudioSwitchTransaction(root, extra) {
    if (!root || !extra || extra.audioSwitchTransaction !== true) return false;
    root.audioIndex = Math.max(0, Math.floor(_numberOr(extra.previousAudioIndex, 0)));
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
    try { root._syncTrackMenuIndexes("audio-negotiation-restore"); } catch(e0) {}
    return true;
}
function _restoreAfterNegotiationError(root,mp,timers,extra,resume,code){
    _stopNegotiationTimers(timers);
    try{if(root._sourceResetActive&&typeof root._cancelHardSourceReset==="function")root._cancelHardSourceReset("negotiation-error");}catch(eCancel){}
    if(extra&&extra.manualQualityRequest===true&&extra.previousManualQualityBitrate!==undefined){
        root.manualQualityBitrate=Math.max(0,Math.floor(_numberOr(extra.previousManualQualityBitrate,0)));
        if(extra.previousManualRemuxMode!==undefined)root.manualRemuxMode=extra.previousManualRemuxMode===true;
        if(extra.previousManualDirectPlayMode!==undefined)root.manualDirectPlayMode=extra.previousManualDirectPlayMode===true;
    }
    _restoreAudioSwitchTransaction(root,extra);
    // Échec du rejeu des réglages différés : le rollback ci-dessus a déjà
    // restauré l'ancienne piste ; il ne doit rester aucune attente fantôme.
    if(extra&&extra.deferredReplay===true)resetDeferredReload(root,"negotiation-error");
    if(extra&&extra.trackSwitchRebase===true&&root._trackSwitchRebaseActive&&typeof root._finishTrackSwitchRebase==="function")
        root._finishTrackSwitchRebase("negotiation-error");
    abortNegotiationWithoutDirectPlay(root,code,"negotiate");
    if(resume&&mp&&root.mediaUrl){try{mp.play();}catch(e0){}}
    try{root.updateClocksFromPlaybackThrottled(true);}catch(e1){}
}
/*
 * Raccord PlayerOverlay -> JellyfinPlaybackRouter.
 * Les politiques codec restent dans JellyfinPlaybackCore : ce helper ne fait
 * qu'injecter l'état UI, ignorer les réponses devenues obsolètes et appliquer
 * le résultat à QtMultimedia sans exposer un écran noir pendant PlaybackInfo.
 */
function negotiateAndApply(root,mp,router,subtitleItem,timers,startMs,forceHls,preferTicks,forceMp4,forceDPOnAudioSwitch,extra){
    extra=extra||{};
    var internalPrefetchedResult=extra._prefetchedResult||null;
    if(internalPrefetchedResult){
        var cleanExtra={};_copyOwn(cleanExtra,extra);
        try{delete cleanExtra._prefetchedResult;}catch(ePrefetchDelete){}
        extra=cleanExtra;
    }
    if(!root||!mp||!router||typeof router.negotiatePlayback!=="function")return false;
    // Rejeu d'attentes : on n'émet rien tout de suite, les appels des handlers
    // sont fusionnés en une seule négociation par replayDeferredReload().
    if(coalesceNegotiationIfActive(root,startMs,forceHls,preferTicks,forceMp4,
                                   forceDPOnAudioSwitch,extra))return true;
    var item=String(root.itemId||""),server=String(root.serverUrl||""),user=String(root.userId||""),token=String(root.accessToken||"");
    if(!item||!server||!user||!token)return false;
    var requested=Math.max(0,Math.floor(_numberOr(startMs,0)));
    if(extra.trackSwitchRebase===true&&extra.trackSwitchUseZeroStart!==true&&typeof root._trackSwitchRebasedStartMs==="function")
        requested=Math.max(0,Math.floor(_numberOr(root._trackSwitchRebasedStartMs(requested),requested)));
    var negotiated=requested;
    if(extra.resumePreferDP===true&&negotiated>0){
        var preroll=Math.max(0,Math.floor(_numberOr(extra.resumePrerollMs,0)));
        negotiated=Math.max(0,negotiated-preroll);
    }
    var seq=++root._negotiationSeq;
    var resume=!!(root._resumeWantedAfterNegotiation||root._wasPlayingBeforeSwitch||root._trackSwitchWasPlaying||mp.playbackState===root._mpPlayingState);
    var subType=_subtitleTypeForStream(root,root.selectedSubtitleStream);
    var ctx=makeCtx(root,root,negotiated,{
        forceHls:forceHls===true,preferTicks:preferTicks===true,forceMp4:forceMp4===true,
        forceDPOnAudioSwitch:forceDPOnAudioSwitch===true
    });
    _copyOwn(ctx,extra);
    ctx.serverUrl=server;ctx.accessToken=token;ctx.userId=user;ctx.itemId=item;
    ctx.startMs=negotiated;ctx.forceHls=forceHls===true||extra.forceHls===true;
    ctx.preferTicks=preferTicks===true||extra.preferTicks===true;
    ctx.forceMp4=forceMp4===true||extra.forceMp4===true;
    ctx.forceDPOnAudioSwitch=forceDPOnAudioSwitch===true||extra.forceDPOnAudioSwitch===true;
    ctx.selectedAudioStream=typeof root.selectedAudioStream==="number"?root.selectedAudioStream:-1;
    ctx.selectedSubtitleStream=typeof root.selectedSubtitleStream==="number"?root.selectedSubtitleStream:-1;
    ctx.useLocalSubs=root.useLocalSubs===true;
    if(extra.selectedSubtitleIsText===undefined)ctx.selectedSubtitleIsText=subType==="text";
    if(extra.selectedSubtitleIsImage===undefined)ctx.selectedSubtitleIsImage=subType==="image";
    if(extra.disableAutoVoFrenchFullSubtitle===undefined)ctx.disableAutoVoFrenchFullSubtitle=root.disableAutoVoFrenchFullSubtitle===true;
    if(extra.preferServerSubtitleBurnInOnVideoTranscode===undefined)
        ctx.preferServerSubtitleBurnInOnVideoTranscode=root.preferServerSubtitleBurnInOnVideoTranscode!==false;
    if(extra.currentPlaybackVideoTranscodeByPolicy===undefined)
        ctx.currentPlaybackVideoTranscodeByPolicy=root.currentPlaybackVideoTranscodeByPolicy===true;
    // Reappliquer les modes manuels APRES toutes les options ponctuelles du
    // call-site. Ordre de souverainete : DirectPlay ou Remux explicitement
    // choisi, puis debit manuel, puis seulement les politiques automatiques.
    var stickyManualDirectPlay=PlayerSession.applyStickyManualDirectPlay(root,ctx);
    var stickyManualRemux=!stickyManualDirectPlay&&PlayerSession.applyStickyManualRemux(root,ctx);
    if(!stickyManualDirectPlay&&!stickyManualRemux)PlayerSession.applyStickyManualQuality(root,ctx);
    ctx.playbackRuleMode=root.playbackRuleMode||"smart";
    ctx.playbackRouterMode=root.playbackDeviceMode||"";
    ctx.playbackRouterBackend=root.playbackBackendMode||"";
    root.lastUiTargetMs=negotiated;
    // L'ouverture initiale garde une raison distincte : elle ne doit pas
    // verrouiller le transport comme un rechargement.
    try{root._armVideoLoading(String(root.mediaUrl||"").length>0?"negotiation":"initial-negotiation");}catch(e0){}
    function fail(err){
        if(!_negotiationStillCurrent(root,seq,item,server,user,token))return;
        var code=router.negotiationErrorCode(err);
        _restoreAfterNegotiationError(root,mp,timers,extra,resume,code);
    }
    function success(res){
            if(!_negotiationStillCurrent(root,seq,item,server,user,token))return;
            if(!res||!res.url){fail("invalid_playback_url");return;}
            var nextUrl=String(res.url||"");
            var manualRate=Math.max(0,Math.floor(_numberOr(ctx.forcePolicyTranscodeVideoBitrate,0)));
            if(manualRate>0&&res.lastUsedTranscoding===true){
                // PlaybackInfo/TranscodingUrl reste autoritatif. Ne réécrire le
                // bitrate côté UI que si Jellyfin n'en a fourni aucun. Il peut
                // volontairement réserver une petite marge à l'audio et retourner
                // par exemple 199552000 pour un plafond demandé à 200 Mbit/s.
                var currentVideoRate=0;
                try{
                    var rm=nextUrl.match(/(?:[?&])VideoBit(?:Rate|rate)=([0-9]+)/i);
                    currentVideoRate=rm?Math.max(0,parseInt(rm[1],10)||0):0;
                }catch(eRate){currentVideoRate=0;}
                if(!(currentVideoRate>0))
                    nextUrl=router.replaceQueryParameter(nextUrl,"VideoBitrate",manualRate);
            }
            if(!nextUrl){fail("invalid_playback_url");return;}
            var oldSession=String(root.playSessionId||"");
            var nextSession=String(res.playSessionId||"");
            root.playSessionId=nextSession;
            root.currentMediaSourceId=String(res.mediaSourceId||"");
            var sourceVideoRate=Math.max(0,Math.floor(_numberOr(res.sourceVideoBitrate,0)));
            if(sourceVideoRate>0&&_has(root,"sourceVideoBitrate")) root.sourceVideoBitrate=sourceVideoRate;
            if(nextSession!==oldSession){
                root._startedReported=false;root._reportedSessionId="";
                root._stoppedPendingSessionId="";
            }
            root.isHls=res.isHls===true;
            root.lastUsedTranscoding=res.lastUsedTranscoding===true;
            root.lastUsedDirectStream=res.lastUsedDirectStream===true;
            root.lastUsedServerRemux=res.lastUsedServerRemux===true;
            root.serverTimedStream=res.serverTimedStream===true;
            root.timeShifted=res.timeShifted===true;
            root.currentPlaybackVideoTranscodeByPolicy=res.policyTranscode===true||
                (extra.manualQualityRequest===true&&res.lastUsedTranscoding===true);
            var effectiveAudio=resultInt(res,["effectiveAudioStreamIndex","audioStreamIndex"]);
            if(effectiveAudio<0)effectiveAudio=queryInt(nextUrl,"AudioStreamIndex");
            root.effectiveAudioStream=effectiveAudio;
            var effectiveSub=resultInt(res,["effectiveSubtitleStreamIndex","subtitleStreamIndex"]);
            if(effectiveSub<0)effectiveSub=queryInt(nextUrl,"SubtitleStreamIndex");
            root.effectiveSubtitleStream=effectiveSub;
            root._trackSwitchSourceVideoCodec=String(res.sourceVideoCodec||"");
            root._trackSwitchSourceContainer=String(res.sourceContainer||"");
            root._trackSwitchSourceHevc10=res.sourceVideoIsHevcMain10===true;
            if(typeof extra.trackSwitchLocalStrategy==="number")
                root._trackSwitchLocalStrategy=extra.trackSwitchLocalStrategy;
            try{if(root._sourceResetActive&&typeof root._cancelHardSourceReset==="function")root._cancelHardSourceReset("new-negotiation-result");}catch(eCancel){}
            var streamBase=Math.max(0,Math.floor(_numberOr(res.streamBaseMs,0)));
            var localSeek=Math.floor(_numberOr(res.initialLocalSeekMs,-1));
            var forcedLocalSeek=Math.floor(_numberOr(extra.forceInitialLocalSeekMs,-1));
            // Une cible locale séparée du startMs n'est valide que si le
            // résultat est réellement le fichier statique DirectPlay. Si le
            // Core/Jellyfin renvoie malgré tout un flux serveur, on conserve
            // strictement sa base temporelle et son mécanisme de seek.
            var forcedSeekOnPureStaticDp = forcedLocalSeek>0 &&
                urlKind(nextUrl)==="http-dp-static" &&
                res.isHls!==true && res.lastUsedTranscoding!==true &&
                res.lastUsedDirectStream!==true && res.lastUsedServerRemux!==true &&
                res.serverTimedStream!==true && res.timeShifted!==true;
            if(forcedSeekOnPureStaticDp) localSeek=forcedLocalSeek;
            root._pendingSeekMs=localSeek>0?root._clampUi(localSeek):-1;
            root._pendingServerTimedBaseMs=root.serverTimedStream?streamBase:-1;
            var hardReset=!!(root.serverTimedStream&&streamBase>=0&&
                (extra.staticDirectPlayFallbackOwner===true||
                 (extra.trackSwitchRebase===true&&extra.trackSwitchColdLocalSeek!==true)));
            root._pendingHardResetBaseMs=hardReset?streamBase:-1;
            if(!root.serverTimedStream)root.baseOffsetMs=0;
            if(root._pendingSeekMs>=0&&typeof root._resetSeekRestoreGuard==="function")
                root._resetSeekRestoreGuard(root._pendingSeekMs,extra.trackSwitchRebase===true?"track-switch":"boot-seek");
            else if(extra.trackSwitchRebase===true&&!hardReset){
                root._trackSwitchVerificationActive=false;
                root._trackSwitchTimebaseVerified=true;
            }
            root._pendingAudioStream=root.snt;root._pendingAudioIndex=-1;
            if(root.hasOwnProperty("_pendingAudioManualDirectPlay"))root._pendingAudioManualDirectPlay=false;
            root._pendingSubStream=root.snt;root._pendingSubIndex=-1;
            root._resumeWantedAfterNegotiation=false;
            try{root._syncTrackMenuIndexes("negotiation");}catch(e2){}
            mediaUrlSwap(root,mp,timers,subtitleItem,nextUrl,resume);
            if(extra.trackSwitchRebase===true&&typeof root._armTrackSwitchTimebaseSettle==="function")
                root._armTrackSwitchTimebaseSettle("negotiation");
            var resultPureDirectPlay = isPureDirectPlay({
                isHls: root.isHls,
                lastUsedTranscoding: root.lastUsedTranscoding,
                lastUsedDirectStream: root.lastUsedDirectStream,
                lastUsedServerRemux: root.lastUsedServerRemux,
                serverTimedStream: root.serverTimedStream,
                timeShifted: root.timeShifted,
                baseOffsetMs: streamBase
            });
            // Une sidecar externe renvoyée par le Core ne doit être rendue en
            // QML que si le résultat final est réellement DirectPlay ET que le
            // Core l'a explicitement demandé. Jamais sur un flux serveur.
            if(res.forceLocalSubs===true && resultPureDirectPlay &&
                    res.externalSubtitle&&effectiveSub>=0&&typeof root.loadLocalSubtitleByStreamIndex==="function"){
                root.loadLocalSubtitleByStreamIndex(effectiveSub,function(){},true);
            }else if(!resultPureDirectPlay ||
                     res.forcedServerSubtitleBurnIn===true||
                     res.effectiveSubtitleMode==="encode"||
                     res.effectiveSubtitleMode==="embed"||
                     res.effectiveSubtitleMode==="hls"){
                if(root.useLocalSubs===true)root.disableLocalSubsOverlay();
            }else if(resultPureDirectPlay){
                try{root._tryAutoLocalizeAfterDP();}catch(e3){}
            }
            try{root.updateClocksFromPlaybackThrottled(true);}catch(e4){}
            if((root.serverTimedStream||root.lastUsedServerRemux)&&typeof root._armFrozenPlaybackWatch==="function")
                root._armFrozenPlaybackWatch("negotiation",root.frozenPlaybackWatchWindowMs);
    }
    try{
        if(internalPrefetchedResult){
            success(internalPrefetchedResult);
        }else{
            router.negotiatePlayback(ctx,success,fail);
        }
    }catch(e5){fail(e5);}
    return true;
}
