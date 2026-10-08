.import "PlayerTrackSelection.js" as TrackSelection
.import "JellyfinPlaybackRouter.js" as PlaybackRouter
.import "PlayerSession.js" as PlayerSession

// ReDeFin subtitle routing: local text subtitles only on pure DirectPlay; remux/DirectStream/transcode/HLS use server-managed subtitles.
/* playerOverlayHelper.js — interaction et présentation du lecteur.
 * Télécommande / focus, logo et HUD, puis raccord négociation -> interface.
 * PlayerSession possède le cycle média, le seek et la récupération.
 * PlayerTrackSelection possède pistes, qualité et choix différés en pause.
 * JellyfinPlaybackRouter/Core conservent les politiques Freebox inchangées.
 */
/* ===== Utils sûrs ===== */
function _s(v) {
    return (v === undefined || v === null) ? "" : (v + "");
}

function _has(o, k) {
    return o && typeof o[k] !== "undefined" && o[k] !== null;
}

function _call(o, k) {
    if (_has(o, k) && typeof o[k] === "function")
        return o[k].apply(o, Array.prototype.slice.call(arguments, 2));
}

function _set(o, k, v) {
    if (_has(o, k)) o[k] = v;
}

function _inc(o, k, d) {
    if (_has(o, k)) o[k] = (o[k] || 0) + d;
}
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
    if (root && typeof root.transportToggle === "function") {
        root.transportToggle("helper-toggle");
        return;
    }
    if (root && typeof root.mediaToggle === "function") {
        root.mediaToggle();
        return;
    }
    if (_has(root, "mp")) {
        try {
            root.mp.playbackState === 2 ? root.mp.pause() : root.mp.play();
        } catch (e) {}
    }
}

function _seek(root, delta) {
    _call(root, "seekBy", delta);
}

function _toastSubs(root) {
    _call(root, "showSubsToast");
}

function _backToDetails(root) {
    if (!root || typeof root.requestBackToDetails !== "function") return;
    var id = "";
    try {
        id = String(root.itemId || root.currentItemId || "");
    } catch (e) {
        id = "";
    }
    try {
        root.requestBackToDetails(id);
    } catch (e1) {
        try {
            root.requestBackToDetails("");
        } catch (e2) {}
    }
}

function _finalizeExit(root, reason) {
    if (!root) return false;
    if (typeof root.finalizePlaybackAndExit === "function") {
        try {
            return root.finalizePlaybackAndExit(reason || "helper-exit") !== false;
        } catch (e0) {}
    }
    if (typeof root.mediaStop === "function") root.mediaStop();
    else if (_has(root, "mp")) _call(root.mp, "stop");
    _backToDetails(root);
    return true;
}
// Règle de référence sous-titres ReDeFin : seul un vrai DirectPlay, sans base
// selectedAudioStream n'entre volontairement pas dans ce prédicat : on se base
function labelForItem(it, fallback) {
    if (!it) return fallback || "";
    var t = (it.Type || "");
    if (t === "Episode") {
        var s = (it.ParentIndexNumber != null) ? it.ParentIndexNumber : "";
        var e = (it.IndexNumber != null) ? it.IndexNumber : "";
        var parts = [];
        if (s !== "" && e !== "") parts.push("S" + s + "E" + e);
        if (it.Name) parts.push(it.Name);
        return parts.join(" • ");
    }
    return it.Name || (fallback || "");
}
/* ===== Classification légère des URL du player ===== */
/* Raccourcis de clés */
var K = (typeof Qt !== "undefined") ? Qt : {
    Key_Left: 0x01000012,
    Key_Right: 0x01000014,
    Key_Up: 0x01000013,
    Key_Down: 0x01000015,
    Key_Return: 0x01000004,
    Key_Enter: 0x01000005,
    Key_Select: 0x01000000,
    Key_Back: 0x01000061,
    Key_Escape: 0x01000000,
    Key_MediaNext: 0x01000031,
    Key_MediaPrevious: 0x01000030,
    Key_MediaPlay: 0x01000028,
    Key_MediaTogglePlayPause: 0x0100003B,
    Key_MediaPause: 0x01000029,
    Key_MediaStop: 0x01000024,
    Key_Plus: 0x2B,
    Key_Equal: 0x3D,
    Key_Minus: 0x2D
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
    } catch (e) {}
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
    try {
        if (root && typeof root.forceActiveFocus === "function") root.forceActiveFocus();
    } catch (e) {}
}

function _focusProgress(root) {
    var CF_PROGRESS = _has(root, "cF_PROGRESS") ? root.cF_PROGRESS : 0;
    if (root && typeof root._focusProgressBarSilent === "function") {
        root._focusProgressBarSilent();
        return;
    }
    _set(root, "controlsFocus", CF_PROGRESS);
    try {
        if (root && typeof root.forceActiveFocus === "function") root.forceActiveFocus();
    } catch (e) {}
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
        } catch (e) {}
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
        } catch (e) {}
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
        if (event.key === K.Key_Left) {
            _focusProgress(root);
            _transportRewind(root, "hidden-progress-left");
            event.accepted = true;
            return;
        }
        if (event.key === K.Key_Right) {
            _focusProgress(root);
            _transportForward(root, "hidden-progress-right");
            event.accepted = true;
            return;
        }
        if (_isOkKey(event.key)) {
            _focusProgress(root);
            _transportToggle(root, "hidden-progress-ok");
            event.accepted = true;
            return;
        }
    }
    var cf = root.controlsFocus || 0;
    var CF_PROGRESS = _has(root, "cF_PROGRESS") ? root.cF_PROGRESS : 0;
    var CF_CONTROLS = _has(root, "cF_CONTROLS") ? root.cF_CONTROLS : 1;
    var CF_MENU = _has(root, "cF_MENU") ? root.cF_MENU : 4;
    var CF_CHAPTERS = _has(root, "cF_CHAPTERS") ? root.cF_CHAPTERS : 5;
    var CF_QUALITY = _has(root, "cF_QUALITY") ? root.cF_QUALITY : 6;
    var hasModernFocusModel = _has(root, "cF_PROGRESS") && _has(root, "cF_CONTROLS") && _has(root, "cF_MENU");
    if (hasModernFocusModel) {
        /* ProgressBar : gauche/droite = seek, OK = pause/play.
           Bas = PlayerControls. Haut = rester sur ProgressBar pour éviter le ping-pong haut/bas. */
        if (cf === CF_PROGRESS) {
            if (event.key === K.Key_Left) {
                _transportRewind(root, "progress-left");
                event.accepted = true;
                return;
            }
            if (event.key === K.Key_Right) {
                _transportForward(root, "progress-right");
                event.accepted = true;
                return;
            }
            if (_isOkKey(event.key)) {
                _transportToggle(root, "progress-ok");
                event.accepted = true;
                return;
            }
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
                if (idx <= 1 && root && typeof root._focusQualityButtonSilent === "function" && root._focusQualityButtonSilent("controls-left-to-quality")) {
                    event.accepted = true;
                    return;
                }
                if (idx <= 1 && root && typeof root._focusChaptersButtonSilent === "function" && root._focusChaptersButtonSilent("controls-left-to-chapters")) {
                    event.accepted = true;
                    return;
                }
                _setControlsButtonIndex(root, Math.max(1, idx - 1), "controls-left");
                event.accepted = true;
                return;
            }
            if (event.key === K.Key_Right) {
                if (idx < 5) {
                    _setControlsButtonIndex(root, idx + 1, "controls-right");
                } else if (root && typeof root._focusChaptersButtonSilent === "function" && root._focusChaptersButtonSilent("controls-right-to-chapters")) {} else {
                    _set(root, "controlsFocus", CF_MENU);
                    if (_has(root, "menuIndex")) _set(root, "menuIndex", 1);
                    try {
                        if (root && typeof root.forceActiveFocus === "function") root.forceActiveFocus();
                    } catch (e) {}
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
            if (event.key === K.Key_Up) {
                _focusProgress(root);
                event.accepted = true;
                return;
            }
            if (event.key === K.Key_Right) {
                _set(root, "controlsFocus", CF_MENU);
                if (_has(root, "menuIndex")) _set(root, "menuIndex", 1);
                try {
                    if (root && typeof root.forceActiveFocus === "function") root.forceActiveFocus();
                } catch (eChaptersRight) {}
                event.accepted = true;
                return;
            }
            if (event.key === K.Key_Left || event.key === K.Key_Down) {
                _setControlsButtonIndex(root, 5, "chapters-to-controls");
                _focusControls(root, "chapters-to-controls");
                event.accepted = true;
                return;
            }
            if (_isOkKey(event.key)) {
                if (root && typeof root._openChaptersPanel === "function") root._openChaptersPanel();
                event.accepted = true;
                return;
            }
        }
        if (_has(root, "cF_QUALITY") && cf === CF_QUALITY) {
            if (event.key === K.Key_Up) {
                _focusProgress(root);
                event.accepted = true;
                return;
            }
            if (event.key === K.Key_Left) {
                event.accepted = true;
                return;
            }
            if (event.key === K.Key_Right || event.key === K.Key_Down) {
                _setControlsButtonIndex(root, 1, "quality-to-controls");
                _focusControls(root, "quality-to-controls");
                event.accepted = true;
                return;
            }
            if (_isOkKey(event.key)) {
                if (root && typeof root._openQualityPanel === "function") root._openQualityPanel();
                event.accepted = true;
                return;
            }
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
    if (event.key === K.Key_MediaNext) {
        _transportNext(root, "media-next");
        event.accepted = true;
        return;
    }
    if (event.key === K.Key_MediaPrevious) {
        _transportPrev(root, "media-prev");
        event.accepted = true;
        return;
    }
    if (event.key === K.Key_MediaPlay || event.key === K.Key_MediaTogglePlayPause) {
        _transportToggle(root, "media-toggle");
        event.accepted = true;
        return;
    }
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
    u = _s(u);
    var q = u.indexOf("?");
    if (q < 0) return u;
    var kept = u.substring(q + 1).split("&").filter(function(x) {
        return x.length > 0 && x.split("=")[0] !== "cb";
    });
    kept.sort();
    return kept.length ? u.substring(0, q) + "?" + kept.join("&") : u.substring(0, q);
}

function hasQueryTag(u) {
    u = _s(u);
    var q = u.indexOf("?");
    if (q < 0) return false;
    return u.substring(q + 1).split("&").some(function(p) {
        return (p.split("=")[0] || "") === "tag";
    });
}

function queryInt(url, key) {
    try {
        var m = _s(url).match(new RegExp("(?:\\?|&)" + key + "=([^&]+)"));
        if (!m) return -1;
        var n = parseInt(decodeURIComponent(m[1]), 10);
        return isFinite(n) ? n : -1;
    } catch (e) {
        return -1;
    }
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
    } catch (e) {}
    return -1;
}

function showNextPanel(root, item) {
    root.nextUserHidden = false;
    if (!item) return;
    try {
        item.externGate = true;
    } catch (e) {}
}

function hideNextPanel(root, item) {
    root.nextUserHidden = true;
    root.controlsVisible = true;
    root._syncControlsTimer();
    if (!item) return;
    try {
        item.externGate = false;
    } catch (e) {}
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
    var tags = it.ImageTags || {},
        tag = tags.Logo || tags.logo || "";
    // QNetworkReplyImplPrivate observé sur Qt 5.15/Freebox.
    return tag && it.Id ? bridge.itemImageUrl(root.serverUrl, it.Id, "Logo", tag, {}) : "";
}

function ensureSeriesLogoTag(root, bridge, it, onSettled) {
    // Callback facultatif : terminer la decision d'affichage meme sans logo.
    function done() { if (typeof onSettled === "function") onSettled(); }
    if (!root.serverUrl || !root.accessToken || !it || hasQueryTag(root.currentItemLogoUrl)) {
        done(); return;
    }
    var t = _s(it.Type);
    var sid = (t === "Episode" || t === "Season") ?
        (it.SeriesId || (it.Series && it.Series.Id) || "") : "";
    if (!sid) { done(); return; }
    var expectedItemId = _s(it.Id || root.itemId || "");
    var expectedSeriesId = _s(sid);
    bridge.fetchItem(root.serverUrl, root.accessToken, expectedSeriesId, function(series) {
        if (_s(root.itemId || "") !== expectedItemId ||
                !series || _s(series.Id || "") !== expectedSeriesId) {
            done(); return;
        }
        var tags = series.ImageTags || {},
            tag = tags.Logo || tags.logo || "";
        if (tag) {
            var u = bridge.itemImageUrl(root.serverUrl, expectedSeriesId, "Logo", tag, {});
            root.currentItemLogoUrl = u;
            root.lastGoodLogoUrl = u;
            root.lastGoodLogoItemId = expectedItemId;
        }
        if (typeof onSettled === "function") done();
        else root._pushTopBar();
    }, function() { done(); });
}

function pushLocalSubsUiMs(root, item, pos, force) {
    if (!item) return;
    var p = Math.max(0, pos | 0);
    if (!root.useLocalSubs || !root.localCues || !root.localCues.length) {
        if (force === true) {
            root._lastSubsUiPushMs = -1;
            item.uiMs = p;
        }
        return;
    }
    if (force === true || root._lastSubsUiPushMs < 0 || Math.abs(p - root._lastSubsUiPushMs) >= root.subsUiPushMinDeltaMs) {
        root._lastSubsUiPushMs = p;
        item.uiMs = p;
    }
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
        try {
            if (typeof root[names[i]] === "function" && root[names[i]]() === true) return true;
        } catch (e0) {}
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
    try {
        root.forceActiveFocus();
    } catch (e0) {}
    try {
        root._updateControlsActive();
    } catch (e1) {}
    try {
        root.resetControlsTimer();
    } catch (e2) {}
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
    try {
        root.forceActiveFocus();
    } catch (e0) {}
    try {
        root._updateControlsActive();
    } catch (e1) {}
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
/* ===== Application du résultat de négociation ===== */
function abortNegotiationWithoutDirectPlay(root, code, reason) {
    root._resumeWantedAfterNegotiation = false;
    root._startupPlayWanted = false;
    root._startupPlayTries = 0;
    root._pendingSeekMs = -1;
    root._pendingServerTimedBaseMs = -1;
    root._pendingHardResetBaseMs = -1;
    root._releaseVideoLoading("negotiation-abort");
}

function _numberOr(value, fallback) {
    var n = Number(value);
    return isFinite(n) ? n : fallback;
}

function _negotiationStillCurrent(root, seq, item, server, user, token) {
    return !!root && !root._tearingDownPlayer && seq === root._negotiationSeq &&
        String(root.itemId || "") === item && String(root.serverUrl || "") === server &&
        String(root.userId || "") === user && String(root.accessToken || "") === token;
}

function _restoreAfterNegotiationError(root, mp, timers, extra, resume, code) {
    PlayerSession.stopSourceNegotiationTimers(timers);
    try {
        if (root._sourceResetActive && typeof root._cancelHardSourceReset === "function") root._cancelHardSourceReset("negotiation-error");
    } catch (eCancel) {}
    if (extra && extra.manualQualityRequest === true && extra.previousManualQualityBitrate !== undefined) {
        root.manualQualityBitrate = Math.max(0, Math.floor(_numberOr(extra.previousManualQualityBitrate, 0)));
        if (extra.previousManualRemuxMode !== undefined) root.manualRemuxMode = extra.previousManualRemuxMode === true;
        if (extra.previousManualDirectPlayMode !== undefined) root.manualDirectPlayMode = extra.previousManualDirectPlayMode === true;
    }
    TrackSelection.restoreAudioSwitchTransaction(root, extra);
    // Échec du rejeu des réglages différés : le rollback ci-dessus a déjà
    // restauré l'ancienne piste ; il ne doit rester aucune attente fantôme.
    if (extra && extra.deferredReplay === true) TrackSelection.resetDeferredReload(root, "negotiation-error");
    if (extra && extra.trackSwitchRebase === true && root._trackSwitchRebaseActive && typeof root._finishTrackSwitchRebase === "function")
        root._finishTrackSwitchRebase("negotiation-error");
    abortNegotiationWithoutDirectPlay(root, code, "negotiate");
    if (resume && mp && root.mediaUrl) {
        try {
            mp.play();
        } catch (e0) {}
    }
    try {
        root.updateClocksFromPlaybackThrottled(true);
    } catch (e1) {}
}
/*
 * Raccord PlayerOverlay -> JellyfinPlaybackRouter.
 * Les politiques codec restent dans JellyfinPlaybackCore : ce helper ne fait
 * qu'injecter l'état UI, ignorer les réponses devenues obsolètes et appliquer
 * le résultat à QtMultimedia sans exposer un écran noir pendant PlaybackInfo.
 */
function negotiateAndApply(root, mp, router, subtitleItem, timers, startMs, forceHls, preferTicks, forceMp4, forceDPOnAudioSwitch, extra) {
    extra = extra || {};
    var internalPrefetchedResult = extra._prefetchedResult || null;
    if (internalPrefetchedResult) {
        var cleanExtra = {};
        TrackSelection.copyNegotiationOptions(cleanExtra, extra);
        try {
            delete cleanExtra._prefetchedResult;
        } catch (ePrefetchDelete) {}
        extra = cleanExtra;
    }
    if (!root || !mp || !router || typeof router.negotiatePlayback !== "function") return false;
    // Rejeu d'attentes : on n'émet rien tout de suite, les appels des handlers
    // sont fusionnés en une seule négociation par replayDeferredReload().
    if (TrackSelection.coalesceNegotiationIfActive(root, startMs, forceHls, preferTicks, forceMp4,
            forceDPOnAudioSwitch, extra)) return true;
    var item = String(root.itemId || ""),
        server = String(root.serverUrl || ""),
        user = String(root.userId || ""),
        token = String(root.accessToken || "");
    if (!item || !server || !user || !token) return false;
    var requested = Math.max(0, Math.floor(_numberOr(startMs, 0)));
    if (extra.trackSwitchRebase === true && extra.trackSwitchUseZeroStart !== true && typeof root._trackSwitchRebasedStartMs === "function")
        requested = Math.max(0, Math.floor(_numberOr(root._trackSwitchRebasedStartMs(requested), requested)));
    var negotiated = requested;
    if (extra.resumePreferDP === true && negotiated > 0) {
        var preroll = Math.max(0, Math.floor(_numberOr(extra.resumePrerollMs, 0)));
        negotiated = Math.max(0, negotiated - preroll);
    }
    var seq = ++root._negotiationSeq;
    var resume = !!(root._resumeWantedAfterNegotiation || root._wasPlayingBeforeSwitch || root._trackSwitchWasPlaying || mp.playbackState === root._mpPlayingState);
    var subType = TrackSelection.subtitleTypeForStream(root, root.selectedSubtitleStream);
    var ctx = TrackSelection.makeNegotiationContext(root, root, negotiated, {
        forceHls: forceHls === true,
        preferTicks: preferTicks === true,
        forceMp4: forceMp4 === true,
        forceDPOnAudioSwitch: forceDPOnAudioSwitch === true
    });
    TrackSelection.copyNegotiationOptions(ctx, extra);
    ctx.serverUrl = server;
    ctx.accessToken = token;
    ctx.userId = user;
    ctx.itemId = item;
    ctx.startMs = negotiated;
    ctx.forceHls = forceHls === true || extra.forceHls === true;
    ctx.preferTicks = preferTicks === true || extra.preferTicks === true;
    ctx.forceMp4 = forceMp4 === true || extra.forceMp4 === true;
    ctx.forceDPOnAudioSwitch = forceDPOnAudioSwitch === true || extra.forceDPOnAudioSwitch === true;
    ctx.selectedAudioStream = typeof root.selectedAudioStream === "number" ? root.selectedAudioStream : -1;
    ctx.selectedSubtitleStream = typeof root.selectedSubtitleStream === "number" ? root.selectedSubtitleStream : -1;
    ctx.useLocalSubs = root.useLocalSubs === true;
    if (extra.selectedSubtitleIsText === undefined) ctx.selectedSubtitleIsText = subType === "text";
    if (extra.selectedSubtitleIsImage === undefined) ctx.selectedSubtitleIsImage = subType === "image";
    if (extra.disableAutoVoFrenchFullSubtitle === undefined) ctx.disableAutoVoFrenchFullSubtitle = root.disableAutoVoFrenchFullSubtitle === true;
    if (extra.preferServerSubtitleBurnInOnVideoTranscode === undefined)
        ctx.preferServerSubtitleBurnInOnVideoTranscode = root.preferServerSubtitleBurnInOnVideoTranscode !== false;
    if (extra.currentPlaybackVideoTranscodeByPolicy === undefined)
        ctx.currentPlaybackVideoTranscodeByPolicy = root.currentPlaybackVideoTranscodeByPolicy === true;
    // Reappliquer les modes manuels APRES toutes les options ponctuelles du
    // call-site. Ordre de souverainete : DirectPlay ou Remux explicitement
    // choisi, puis debit manuel, puis seulement les politiques automatiques.
    var stickyManualDirectPlay = TrackSelection.applyStickyManualDirectPlay(root, ctx);
    var stickyManualRemux = !stickyManualDirectPlay && TrackSelection.applyStickyManualRemux(root, ctx);
    if (!stickyManualDirectPlay && !stickyManualRemux) TrackSelection.applyStickyManualQuality(root, ctx);
    ctx.playbackRuleMode = root.playbackRuleMode || "smart";
    ctx.audioOutputMode = root.audioOutputMode || "multichannel";
    ctx.playbackRouterMode = root.playbackDeviceMode || "";
    ctx.playbackRouterBackend = root.playbackBackendMode || "";

    root.lastUiTargetMs = negotiated;
    // L'ouverture initiale garde une raison distincte : elle ne doit pas
    // verrouiller le transport comme un rechargement.
    try {
        root._armVideoLoading(String(root.mediaUrl || "").length > 0 ? "negotiation" : "initial-negotiation");
    } catch (e0) {}

    function fail(err) {
        if (!_negotiationStillCurrent(root, seq, item, server, user, token)) return;
        var code = router.negotiationErrorCode(err);
        _restoreAfterNegotiationError(root, mp, timers, extra, resume, code);
    }

    function success(res) {
        if (!_negotiationStillCurrent(root, seq, item, server, user, token)) return;
        if (!res || !res.url) {
            fail("invalid_playback_url");
            return;
        }
        var nextUrl = String(res.url || "");
        var manualRate = Math.max(0, Math.floor(_numberOr(ctx.forcePolicyTranscodeVideoBitrate, 0)));
        if (manualRate > 0 && res.lastUsedTranscoding === true) {
            // PlaybackInfo/TranscodingUrl reste autoritatif. Ne réécrire le
            // bitrate côté UI que si Jellyfin n'en a fourni aucun. Il peut
            // volontairement réserver une petite marge à l'audio et retourner
            // par exemple 199552000 pour un plafond demandé à 200 Mbit/s.
            var currentVideoRate = 0;
            try {
                var rm = nextUrl.match(/(?:[?&])VideoBit(?:Rate|rate)=([0-9]+)/i);
                currentVideoRate = rm ? Math.max(0, parseInt(rm[1], 10) || 0) : 0;
            } catch (eRate) {
                currentVideoRate = 0;
            }
            if (!(currentVideoRate > 0))
                nextUrl = router.replaceQueryParameter(nextUrl, "VideoBitrate", manualRate);
        }
        if (!nextUrl) {
            fail("invalid_playback_url");
            return;
        }
        var oldSession = String(root.playSessionId || "");
        var nextSession = String(res.playSessionId || "");
        root.playSessionId = nextSession;
        root.currentMediaSourceId = String(res.mediaSourceId || "");
        var sourceVideoRate = Math.max(0, Math.floor(_numberOr(res.sourceVideoBitrate, 0)));
        if (sourceVideoRate > 0 && _has(root, "sourceVideoBitrate")) root.sourceVideoBitrate = sourceVideoRate;
        if (nextSession !== oldSession) {
            root._startedReported = false;
            root._reportedSessionId = "";
            root._stoppedPendingSessionId = "";
        }
        root.isHls = res.isHls === true;
        root.lastUsedTranscoding = res.lastUsedTranscoding === true;
        root.lastUsedDirectStream = res.lastUsedDirectStream === true;
        root.lastUsedServerRemux = res.lastUsedServerRemux === true;
        root.serverTimedStream = res.serverTimedStream === true;
        root.timeShifted = res.timeShifted === true;
        root.currentPlaybackVideoTranscodeByPolicy = res.policyTranscode === true ||
            (extra.manualQualityRequest === true && res.lastUsedTranscoding === true);
        var effectiveAudio = resultInt(res, ["effectiveAudioStreamIndex", "audioStreamIndex"]);
        if (effectiveAudio < 0) effectiveAudio = queryInt(nextUrl, "AudioStreamIndex");
        root.effectiveAudioStream = effectiveAudio;
        var effectiveSub = resultInt(res, ["effectiveSubtitleStreamIndex", "subtitleStreamIndex"]);
        if (effectiveSub < 0) effectiveSub = queryInt(nextUrl, "SubtitleStreamIndex");
        root.effectiveSubtitleStream = effectiveSub;
        root._trackSwitchSourceVideoCodec = String(res.sourceVideoCodec || "");
        root._trackSwitchSourceContainer = String(res.sourceContainer || "");
        root._trackSwitchSourceHevc10 = res.sourceVideoIsHevcMain10 === true;
        if (typeof extra.trackSwitchLocalStrategy === "number")
            root._trackSwitchLocalStrategy = extra.trackSwitchLocalStrategy;
        try {
            if (root._sourceResetActive && typeof root._cancelHardSourceReset === "function") root._cancelHardSourceReset("new-negotiation-result");
        } catch (eCancel) {}
        var streamBase = Math.max(0, Math.floor(_numberOr(res.streamBaseMs, 0)));
        var localSeek = Math.floor(_numberOr(res.initialLocalSeekMs, -1));
        var forcedLocalSeek = Math.floor(_numberOr(extra.forceInitialLocalSeekMs, -1));
        // Une cible locale séparée du startMs n'est valide que si le
        // résultat est réellement le fichier statique DirectPlay. Si le
        // Core/Jellyfin renvoie malgré tout un flux serveur, on conserve
        // strictement sa base temporelle et son mécanisme de seek.
        var forcedSeekOnPureStaticDp = forcedLocalSeek > 0 &&
            PlaybackRouter.urlKind(nextUrl) === "http-dp-static" &&
            res.isHls !== true && res.lastUsedTranscoding !== true &&
            res.lastUsedDirectStream !== true && res.lastUsedServerRemux !== true &&
            res.serverTimedStream !== true && res.timeShifted !== true;
        if (forcedSeekOnPureStaticDp) localSeek = forcedLocalSeek;
        root._pendingSeekMs = localSeek > 0 ? root._clampUi(localSeek) : -1;
        root._pendingServerTimedBaseMs = root.serverTimedStream ? streamBase : -1;
        var hardReset = !!(root.serverTimedStream && streamBase >= 0 &&
            (extra.staticDirectPlayFallbackOwner === true ||
                (extra.trackSwitchRebase === true && extra.trackSwitchColdLocalSeek !== true)));
        root._pendingHardResetBaseMs = hardReset ? streamBase : -1;
        if (!root.serverTimedStream) root.baseOffsetMs = 0;
        if (root._pendingSeekMs >= 0 && typeof root._resetSeekRestoreGuard === "function")
            root._resetSeekRestoreGuard(root._pendingSeekMs, extra.trackSwitchRebase === true ? "track-switch" : "boot-seek");
        else if (extra.trackSwitchRebase === true && !hardReset) {
            root._trackSwitchVerificationActive = false;
            root._trackSwitchTimebaseVerified = true;
        }
        root._pendingAudioStream = root.snt;
        root._pendingAudioIndex = -1;
        if (root.hasOwnProperty("_pendingAudioManualDirectPlay")) root._pendingAudioManualDirectPlay = false;
        root._pendingSubStream = root.snt;
        root._pendingSubIndex = -1;
        root._resumeWantedAfterNegotiation = false;
        try {
            root._syncTrackMenuIndexes("negotiation");
        } catch (e2) {}
        PlayerSession.mediaUrlSwap(root, mp, timers, subtitleItem, nextUrl, resume);
        if (extra.trackSwitchRebase === true && typeof root._armTrackSwitchTimebaseSettle === "function")
            root._armTrackSwitchTimebaseSettle("negotiation");
        var resultPureDirectPlay = PlaybackRouter.isPureDirectPlay({
            isHls: root.isHls,
            lastUsedTranscoding: root.lastUsedTranscoding,
            lastUsedDirectStream: root.lastUsedDirectStream,
            lastUsedServerRemux: root.lastUsedServerRemux,
            serverTimedStream: root.serverTimedStream,
            timeShifted: root.timeShifted,
            baseOffsetMs: streamBase
        });
        // MOV_TEXT/TX3G est deja converti en VTT/SRT puis rendu par l'overlay QML.
        // Une renegociation servant a enlever une ancienne piste serveur ne doit
        // pas effacer ces cues simplement parce que la video est en remux/HLS.
        // Garde stricte: selection locale explicite, cues presentes et absence
        // d'une piste serveur effectivement incrustee/embarquee dans le resultat.
        var keepMovTextLocalOverlay = root.useLocalSubs === true &&
            root.localSubStreamIndex >= 0 && root.localCues &&
            root.localCues.length > 0 && root.selectedSubtitleStream === -1 &&
            TrackSelection.isMovTextSubtitleStream(root, root.localSubStreamIndex) &&
            res.forcedServerSubtitleBurnIn !== true &&
            res.effectiveSubtitleMode !== "encode" &&
            res.effectiveSubtitleMode !== "embed" &&
            res.effectiveSubtitleMode !== "hls";
        // Un sous-titre sidecar propose par le Core hors selection manuelle
        // conserve ses garde-fous DirectPlay existants.
        if (keepMovTextLocalOverlay) {
            // Le chargement et les cues appartiennent deja a PlayerTrackSelection.
        } else if (res.forceLocalSubs === true && resultPureDirectPlay &&
            res.externalSubtitle && effectiveSub >= 0 && typeof root.loadLocalSubtitleByStreamIndex === "function") {
            root.loadLocalSubtitleByStreamIndex(effectiveSub, function() {}, true);
        } else if (!resultPureDirectPlay ||
            res.forcedServerSubtitleBurnIn === true ||
            res.effectiveSubtitleMode === "encode" ||
            res.effectiveSubtitleMode === "embed" ||
            res.effectiveSubtitleMode === "hls") {
            if (root.useLocalSubs === true) root.disableLocalSubsOverlay();
        } else if (resultPureDirectPlay) {
            try {
                root._tryAutoLocalizeAfterDP();
            } catch (e3) {}
        }
        try {
            root.updateClocksFromPlaybackThrottled(true);
        } catch (e4) {}
        if ((root.serverTimedStream || root.lastUsedServerRemux) && typeof root._armFrozenPlaybackWatch === "function")
            root._armFrozenPlaybackWatch("negotiation", root.frozenPlaybackWatchWindowMs);
    }
    try {
        if (internalPrefetchedResult) {
            success(internalPrefetchedResult);
        } else {
            router.negotiatePlayback(ctx, success, fail);
        }
    } catch (e5) {
        fail(e5);
    }
    return true;
}
