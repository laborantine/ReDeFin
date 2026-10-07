/* SkipIntro.js — ReDeFin / QtQuick 2.15
 * v10 modern-first + anti-doublons + compat Jellyfin historique
 *
 * Sources de segments essayées :
 *  1) Jellyfin MediaSegments: /MediaSegments/{itemId}?includeSegmentTypes=Intro...
 *  2) Intro Skipper legacy: /Episode/{itemId}/IntroTimestamps (fallback compat)
 *  3) Jellyfin item chapters fallback: /Items/{itemId} (Chapters inclus dans le DTO détail)
 *
 * Retourne des millisecondes UI absolues: {startMs,endMs,promptMs,hideMs,source,type}
 */
.pragma library
.import "jellyfinBridge.js" as JellyfinBridge
.import "SafeLog.js" as SafeLog

var ENABLE_LEGACY_INTRO_SKIPPER_FALLBACK = true;

var _resultCache = {};
var _inflight = {};
var _legacyIntroUnsupportedByServer = {};
var _cacheOrder = [];
var _cacheMaxEntries = 48;

function _now(){ try { return Date.now(); } catch(e) { return (new Date()).getTime(); } }
function _later(fn){
    try {
        if (typeof Qt !== "undefined" && Qt && Qt.callLater) { Qt.callLater(fn); return; }
    } catch(e0) {}
    try { fn(); } catch(e1) {}
}
function _cacheKey(serverUrl, itemId){
    // Cache mémoire uniquement, mais on évite de garder serverUrl|itemId en clair
    // pour rester cohérent avec les autres stockages/logs ReDeFin.
    return "srv#" + SafeLog.shortHash(_base(serverUrl)) + "|item#" + SafeLog.shortHash(_s(itemId));
}
function _serverCapabilityKey(serverUrl){
    return "srv#" + SafeLog.shortHash(_base(serverUrl));
}
function _legacyIntroUnsupported(serverUrl){
    return _legacyIntroUnsupportedByServer[_serverCapabilityKey(serverUrl)] === true;
}
function _markLegacyIntroUnsupported(serverUrl){
    _legacyIntroUnsupportedByServer[_serverCapabilityKey(serverUrl)] = true;
}
function _cloneSeg(seg){
    if (!seg) return null;
    return {
        startMs: seg.startMs,
        endMs: seg.endMs,
        promptMs: seg.promptMs,
        hideMs: seg.hideMs,
        source: seg.source,
        type: seg.type
    };
}
function _cacheSet(key, ok, seg, err){
    if (!key) return;
    _resultCache[key] = { ts: _now(), ok: ok === true, seg: _cloneSeg(seg), err: err || null };
    _cacheOrder.push(key);
    if (_cacheOrder.length > _cacheMaxEntries) {
        var drop = _cacheOrder.shift();
        var still = false;
        for (var i = 0; i < _cacheOrder.length; i++) {
            if (_cacheOrder[i] === drop) { still = true; break; }
        }
        if (!still) delete _resultCache[drop];
    }
}
function _cacheGet(key){
    var e = key ? _resultCache[key] : null;
    if (!e) return null;
    return { ok: e.ok === true, seg: _cloneSeg(e.seg), err: e.err || null };
}
function _isTransientErr(err){
    err = _s(err).toLowerCase();
    return err === "network" || err === "timeout" || err === "parse" || err === "http_0";
}
function _flushInflight(key, ok, seg, err){
    var waiters = _inflight[key] || [];
    delete _inflight[key];
    for (var i = 0; i < waiters.length; i++) {
        (function(cb){
            _later(function(){ try { cb && cb(ok === true, _cloneSeg(seg), err || null); } catch(e) {} });
        })(waiters[i]);
    }
}


function _s(v){ return (v === undefined || v === null) ? "" : String(v); }
function _base(u){ u=_s(u); return u && u.charAt(u.length-1)==='/' ? u.slice(0,-1) : u; }
function _u(base, path){ base=_base(base); return base + (path.charAt(0)==='/' ? path : ('/'+path)); }

// Sécurité transport : aucun secret Jellyfin sur HTTP hors LAN.


function _sensitiveXhrBlocked(url, secret) {
    try {
        var headers = secret && JellyfinBridge.headersWithToken
                    ? (JellyfinBridge.headersWithToken(secret) || {}) : {};
        return JellyfinBridge.isSensitiveRequestAllowed(url, headers, null) !== true;
    } catch(e0) {
        return true;
    }
}

function _append(url,k,v){ if(v===undefined||v===null||v==='') return url; return url + (url.indexOf('?')>=0?'&':'?') + encodeURIComponent(k) + '=' + encodeURIComponent(String(v)); }


function _authHeader(token){
    try { return JellyfinBridge.headersWithToken(token || "") || {}; }
    catch(e0) { return {}; }
}

function _clockMs(v){
    if (v === undefined || v === null || v === "") return -1;
    if (typeof v !== "string") return -1;
    var t = v.trim();
    // HH:MM:SS(.ms) ou MM:SS(.ms)
    var m = t.match(/^(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[\.,](\d{1,3}))?$/);
    if (!m) return -1;
    var hh = m[1] ? parseInt(m[1], 10) : 0;
    var mm = parseInt(m[2], 10);
    var ss = parseInt(m[3], 10);
    var ms = m[4] ? parseInt((m[4] + "000").substr(0, 3), 10) : 0;
    if (!isFinite(hh) || !isFinite(mm) || !isFinite(ss) || !isFinite(ms)) return -1;
    return ((hh * 3600 + mm * 60 + ss) * 1000 + ms);
}
function _numberTime(v){
    if (v === undefined || v === null || v === "") return -1;
    var n = Number(v);
    return (!isFinite(n) || n < 0) ? -1 : n;
}
function _ticksMs(v){
    var clock = _clockMs(v);
    if (clock >= 0) return clock;
    var n = _numberTime(v);
    if (n < 0) return -1;
    // Les propriétés Jellyfin *Ticks sont des ticks .NET : 10 000 ticks = 1 ms.
    return Math.floor(n / 10000);
}
function _millisecondsMs(v){
    var clock = _clockMs(v);
    if (clock >= 0) return clock;
    var n = _numberTime(v);
    return n < 0 ? -1 : Math.floor(n);
}
function _secondsMs(v){
    var clock = _clockMs(v);
    if (clock >= 0) return clock;
    var n = _numberTime(v);
    return n < 0 ? -1 : Math.floor(n * 1000);
}
function _pick(o, keys){
    if(!o) return undefined;
    for(var i=0;i<keys.length;i++){
        var k=keys[i];
        if(o[k] !== undefined && o[k] !== null) return o[k];
    }
    return undefined;
}
function _pickTimeMs(o, tickKeys, msKeys, secondKeys){
    var v = _pick(o, tickKeys || []);
    if (v !== undefined) return _ticksMs(v);
    v = _pick(o, msKeys || []);
    if (v !== undefined) return _millisecondsMs(v);
    v = _pick(o, secondKeys || []);
    if (v !== undefined) return _secondsMs(v);
    return -1;
}

function _xhrJson(url, token, ok, ko){
    if (!JellyfinBridge || typeof JellyfinBridge.sendRequestNoCache !== "function") {
        _later(function(){ try { if (ko) ko("bridge_missing"); } catch(e0) {} });
        return;
    }

    var headers = _authHeader(token);

    JellyfinBridge.sendRequestNoCache("get", url, headers, null,
        function(res){
            var json = null;
            try {
                json = JellyfinBridge.jsonNormalize
                     ? JellyfinBridge.jsonNormalize(res && res.json)
                     : (res && res.json);
            } catch(e0) {}
            if (json === undefined || json === null) {

                if (ko) ko("parse");
                return;
            }

            if (ok) ok(json);
        },
        function(err){
            var code = _s(err && err.code || "network");

            if (ko) ko(code === "network_error" ? "network" : code);
        }
    );
}
function _makeSeg(start, end, prompt, hide, source, type){
    if(start < 0 || end <= start) return null;
    if ((end - start) < 3000) return null; // Jellyfin web évite les segments trop courts.
    return {
        startMs:start,
        endMs:end,
        promptMs:(prompt>=0?prompt:Math.max(0,start-5000)),
        hideMs:(hide>=0?hide:end),
        source:source || 'unknown',
        type:type || 'Intro'
    };
}
function _fromLegacy(j){
    if(!j) return null;
    if(j.Valid === false || j.valid === false) return null;
    // Intro Skipper legacy documente IntroStart/IntroEnd/ShowSkipPromptAt/
    // HideSkipPromptAt en secondes. Les variantes *Ms et *Ticks restent prises
    // en charge explicitement, sans deviner l'unité depuis la valeur numérique.
    var start = _pickTimeMs(j,
        ['StartTicks','StartTimeTicks','startTicks','startTimeTicks'],
        ['IntroStartMs','introStartMs','StartMs','startMs'],
        ['IntroStart','introStart','Start','start']);
    var end = _pickTimeMs(j,
        ['EndTicks','EndTimeTicks','endTicks','endTimeTicks'],
        ['IntroEndMs','introEndMs','EndMs','endMs'],
        ['IntroEnd','introEnd','End','end']);
    var prompt = _pickTimeMs(j,
        ['ShowSkipPromptAtTicks','showSkipPromptAtTicks','PromptTicks','promptTicks'],
        ['ShowSkipPromptAtMs','showSkipPromptAtMs','PromptMs','promptMs'],
        ['ShowSkipPromptAt','showSkipPromptAt','Prompt','prompt']);
    var hide = _pickTimeMs(j,
        ['HideSkipPromptAtTicks','hideSkipPromptAtTicks','HideTicks','hideTicks'],
        ['HideSkipPromptAtMs','hideSkipPromptAtMs','HideMs','hideMs'],
        ['HideSkipPromptAt','hideSkipPromptAt','Hide','hide']);
    return _makeSeg(start, end, prompt, hide, 'intro-skipper', 'Intro');
}
function _listFromMediaSegments(j){
    if(!j) return [];
    if(j.Items && j.Items.length !== undefined) return j.Items;
    if(j.Segments && j.Segments.length !== undefined) return j.Segments;
    if(j.MediaSegments && j.MediaSegments.length !== undefined) return j.MediaSegments;
    if(j.Results && j.Results.length !== undefined) return j.Results;
    if(j.length !== undefined) return j;
    return [];
}
function _fromMediaSegments(j){
    var arr = _listFromMediaSegments(j);

    for(var i=0;i<arr.length;i++){
        var s = arr[i] || {};
        var type = _s(_pick(s, ['Type','SegmentType','type','segmentType','ItemType','MediaSegmentType'])).toLowerCase();

        if(type && type !== 'intro') continue;
        // MediaSegmentDto officiel expose StartTicks / EndTicks.
        // Les variantes sont uniquement des fallbacks de compatibilité.
        var start = _pickTimeMs(s,
            ['StartTicks','StartTimeTicks','startTicks','startTimeTicks'],
            ['StartMs','startMs','BeginMs','beginMs'],
            ['Start','start','Begin','begin']);
        var end = _pickTimeMs(s,
            ['EndTicks','EndTimeTicks','endTicks','endTimeTicks'],
            ['EndMs','endMs','StopMs','stopMs'],
            ['End','end','Stop','stop']);
        var seg = _makeSeg(start, end, Math.max(0,start-5000), end, 'media-segments', type || 'Intro');
        if(seg) return seg;
    }
    return null;
}
function _fromChapters(j){
    var ch = (j && j.Chapters && j.Chapters.length !== undefined) ? j.Chapters : [];
    if (!ch.length) return null;
    var introStart = -1, introEnd = -1;
    for (var i=0;i<ch.length;i++) {
        var c = ch[i] || {};
        var name = _s(c.Name || c.name || c.Title || c.title).toLowerCase();
        var start = _pickTimeMs(c,
            ['StartPositionTicks','StartTicks','StartTimeTicks','startPositionTicks','startTicks','startTimeTicks'],
            ['StartMs','startMs'],
            ['Start','start']);
        if (name.indexOf('intro') >= 0 || name.indexOf('opening') >= 0 || name.indexOf('op ') >= 0 || name === 'op') {
            introStart = start;
            if (i + 1 < ch.length) {
                var next = ch[i+1] || {};
                introEnd = _pickTimeMs(next,
                    ['StartPositionTicks','StartTicks','StartTimeTicks','startPositionTicks','startTicks','startTimeTicks'],
                    ['StartMs','startMs'],
                    ['Start','start']);
            }
            break;
        }
    }
    var seg = _makeSeg(introStart, introEnd, Math.max(0,introStart-5000), introEnd, 'chapters', 'Intro');
    return seg;
}

function fetchIntroSegment(serverUrl, accessToken, itemId, done){
    if(!serverUrl || !accessToken || !itemId){ done && done(false,null,'ctx'); return; }
    if(_sensitiveXhrBlocked(serverUrl, accessToken)){ done && done(false,null,'insecure_transport'); return; }

    var key = _cacheKey(serverUrl, itemId);
    var cached = _cacheGet(key);
    if (cached) {
        _later(function(){ done && done(cached.ok, cached.seg, cached.err); });
        return;
    }

    if (_inflight[key]) {
        _inflight[key].push(done);
        return;
    }

    _inflight[key] = [done];

    function finish(ok, seg, err) {
        if (ok === true || !_isTransientErr(err))
            _cacheSet(key, ok === true, seg, err || null);
        _flushInflight(key, ok === true, seg, err || null);
    }

    // Jellyfin >= 10.10 : MediaSegments est la source canonique.
    // L'ancien endpoint Intro Skipper reste uniquement un fallback pour les
    // serveurs/plugins historiques, puis les chapitres ferment la chaîne.
    _fetchMediaSegmentsNetwork(serverUrl, accessToken, itemId, function(ok, seg, err, modernSupported){
        if (ok && seg) { finish(true, seg, null); return; }

        // Si MediaSegments a répondu correctement, le serveur expose déjà
        // l'API moderne. Ne pas tester IntroTimestamps derrière : sur les
        // Jellyfin récents cet endpoint legacy renvoie 404 et ne fournit rien
        // de plus. Les chapitres restent le fallback local sans bruit réseau.
        if (modernSupported === true) {
            fetchChapterFallback(serverUrl, accessToken, itemId, finish, err || 'no-media-segment');
            return;
        }

        _fetchLegacyIntroNetwork(serverUrl, accessToken, itemId, finish, err || 'no-media-segment');
    });
}

function _fetchMediaSegmentsNetwork(serverUrl, accessToken, itemId, done){
    if(_sensitiveXhrBlocked(serverUrl, accessToken)){ done && done(false,null,'insecure_transport'); return; }
    var base = _u(serverUrl, '/MediaSegments/' + encodeURIComponent(itemId));
    var urls = [
        _append(base, 'includeSegmentTypes', 'Intro'),
        _append(_append(_append(_append(_append(base, 'includeSegmentTypes', 'Intro'), 'includeSegmentTypes', 'Outro'), 'includeSegmentTypes', 'Preview'), 'includeSegmentTypes', 'Recap'), 'includeSegmentTypes', 'Commercial'),
        base
    ];
    var lastErr = 'no-media-segment';
    var modernSupported = false;
    function next(i){
        if(i >= urls.length){ done && done(false, null, lastErr, modernSupported); return; }
        _xhrJson(urls[i], accessToken, function(j){
            modernSupported = true;
            var seg = _fromMediaSegments(j);
            if(seg){ done && done(true, seg, null, true); return; }
            next(i+1);
        }, function(err){
            lastErr = err || lastErr;
            next(i+1);
        });
    }
    next(0);
}

function _fetchLegacyIntroNetwork(serverUrl, accessToken, itemId, done, prevErr){
    if (!ENABLE_LEGACY_INTRO_SKIPPER_FALLBACK) {
        fetchChapterFallback(serverUrl, accessToken, itemId, done, prevErr || 'legacy-disabled');
        return;
    }
    if (_legacyIntroUnsupported(serverUrl)) {
        fetchChapterFallback(serverUrl, accessToken, itemId, done, prevErr || 'legacy-disabled');
        return;
    }
    if(_sensitiveXhrBlocked(serverUrl, accessToken)){ done && done(false,null,'insecure_transport'); return; }

    var legacy = _u(serverUrl, '/Episode/' + encodeURIComponent(itemId) + '/IntroTimestamps');
    _xhrJson(legacy, accessToken, function(j){
        var seg = _fromLegacy(j);
        if(seg){ done && done(true, seg, null); return; }
        fetchChapterFallback(serverUrl, accessToken, itemId, done, prevErr || 'legacy-empty');
    }, function(err){
        if (err === 'http_404')
            _markLegacyIntroUnsupported(serverUrl);
        fetchChapterFallback(serverUrl, accessToken, itemId, done, err || prevErr || 'legacy-error');
    });
}

function fetchChapterFallback(serverUrl, accessToken, itemId, done, prevErr){
    if(_sensitiveXhrBlocked(serverUrl, accessToken)){ done && done(false,null,'insecure_transport'); return; }
    // GET /Items/{itemId} n'expose plus de paramètre Fields. Le DTO détail
    // utilise les DtoOptions complets et contient directement Chapters.
    var url = _u(serverUrl, '/Items/' + encodeURIComponent(itemId));
    _xhrJson(url, accessToken, function(j){
        var seg = _fromChapters(j);
        if(seg){  done && done(true, seg, null); return; }

        done && done(false,null,prevErr || 'no-segment');
    }, function(err){

        done && done(false,null,err || prevErr || 'no-segment');
    });
}

function segNum(seg, keys, defv) {
    seg = seg || {};
    for (var i = 0; i < keys.length; i++) {
        var k = keys[i];
        if (seg[k] !== undefined && seg[k] !== null) {
            var v = Number(seg[k]);
            if (isFinite(v)) return Math.max(0, Math.floor(v));
        }
    }
    return defv;
}
function startMs(seg) { return segNum(seg, ["startMs", "IntroStartMs", "StartMs"], -1); }
function endMs(seg) { return segNum(seg, ["endMs", "IntroEndMs", "EndMs"], -1); }
function promptMs(seg, leadMs) {
    var s = startMs(seg);
    var p = segNum(seg, ["promptMs", "ShowSkipPromptAtMs", "PromptMs"], -1);
    return p >= 0 ? p : Math.max(0, s - (leadMs || 0));
}
function hideMs(seg) {
    var e = endMs(seg);
    var h = segNum(seg, ["hideMs", "HideSkipPromptAtMs", "HideMs"], -1);
    return h >= 0 ? h : e;
}
function segmentTimes(seg, leadMs) {
    var s = startMs(seg), e = endMs(seg), p = promptMs(seg, leadMs), h = hideMs(seg);
    return { s: s, e: e, p: p, h: h };
}
function shouldShow(enabled, armed, seg, nextLocked, audioVisible, subVisible, consumed, dismissed, visualExpired, pos, leadMs) {
    if (!enabled || !armed || !seg || nextLocked || audioVisible || subVisible) return false;
    // Une expiration visuelle de la fenêtre de 10 s doit rester consommée tant
    // que la lecture continue dans la même intro. Ouvrir/fermer AudioMenu ou
    // SubtitleMenu ne doit donc jamais recréer une seconde fenêtre.
    if (consumed || dismissed || visualExpired) return false;
    var t = segmentTimes(seg, leadMs);
    if (t.s < 0 || t.e <= t.s) return false;
    return pos >= t.p && pos < Math.max(t.e, t.h);
}



/* ===== État runtime PlayerOverlay =====
 * Le domaine Skip Intro reste ici : détection + cache + règles temporelles +
 * orchestration d'affichage. PlayerOverlay ne conserve que de minces wrappers
 * liés à son MediaPlayer et à son Loader QML.
 */
function armSkipIntroResumeGate(root, targetMs, reason) {
    var t = Math.max(0, Math.floor(Number(targetMs || 0)));
    if (!t) return;

    root.skipIntroResumeGateActive = true;
    root.skipIntroResumeTargetMs = t;
    root.skipIntroResumeGateReason = reason || "boot-seek";
    root._skipIntroLastShow = false;
    root.skipIntroFocusClaimed = false;
    root.skipIntroAutoFocusClaimed = false;
    root.skipIntroFocusReleasedByUser = false;
}

function consumeSkipIntroIfPastResume(root, targetMs) {
    var t = Math.max(0, Math.floor(Number(targetMs || 0)));
    var s = startMs(root.skipIntroSegment);
    var e = endMs(root.skipIntroSegment);
    var h = hideMs(root.skipIntroSegment);
    if (!root.skipIntroSegment || e <= s || t < Math.max(e, h)) return false;

    root.skipIntroConsumed = true;
    root.skipIntroDismissed = true;
    root.skipIntroFocusClaimed = false;
    root.skipIntroAutoFocusClaimed = false;
    root.skipIntroFocusReleasedByUser = true;
    root._skipIntroWasInside = false;
    root._skipIntroLastShow = false;
    root._skipIntroLastPos = t;
    return true;
}

function releaseSkipIntroResumeGate(root, item, actualUiMs) {
    var t = Math.max(0, Math.floor(Number(actualUiMs || 0)));
    if (root.skipIntroResumeTargetMs > t) t = root.skipIntroResumeTargetMs;

    consumeSkipIntroIfPastResume(root, t);
    root.skipIntroResumeGateActive = false;
    root.skipIntroResumeTargetMs = -1;
    root.skipIntroResumeGateReason = "";

    if (!root.skipIntroConsumed && !root.skipIntroDismissed)
        syncSkipIntroOverlay(root, item);
}

function armSkipIntroPlayback(root, item, positionMs) {
    if (!root || root.serverPrerollBlocking === true || root.skipIntroEnabled !== true)
        return false;

    var pos = Math.max(0, Math.floor(Number(positionMs || 0)));
    if (!root.skipIntroPlaybackArmed) {
        root.skipIntroPlaybackArmed = true;
        root.skipIntroPlaybackStartMs = pos;
    }

    syncSkipIntroOverlay(root, item);
    return true;
}

function setSkipIntroItemActive(root, item, show) {
    if (!item) return;

    try {
        item.uiMs = root.uiPositionMs();
        item.endMs = endMs(root.skipIntroSegment);
        if (item.safeMargin !== undefined) item.safeMargin = Math.max(60, root.tvSafeMargin);
        if (item.safeMarginRight !== undefined) item.safeMarginRight = Math.max(60, root.tvSafeMargin);
        if (item.safeMarginBottom !== undefined) item.safeMarginBottom = Math.max(60, root.tvSafeMargin);
        if (item.avoidBottom !== undefined) item.avoidBottom = root.controlsVisible || root.scrubActive ? 190 : 0;
        if (item.safeAreaAlreadyApplied !== undefined) item.safeAreaAlreadyApplied = false;
        if (item.label !== undefined) item.label = "Passer le générique";

        var autoFocus = false;
        var suppressVisiblePriority = false;
        try {
            autoFocus = show &&
                        typeof root._skipIntroAutoFocusAllowed === "function" &&
                        root._skipIntroAutoFocusAllowed();
            suppressVisiblePriority = show &&
                                      root.skipIntroFocusReleasedByUser === true &&
                                      root.uiChromeRenderVisible === true;
        } catch(eFocusPolicy) {}

        if (item.stealFocusOnShow !== undefined) item.stealFocusOnShow = autoFocus;
        if (item.prioritizeOnShow !== undefined) item.prioritizeOnShow = !suppressVisiblePriority;
        if (item.show !== undefined) item.show = show;

        if (show && !autoFocus && !suppressVisiblePriority &&
                !root.skipIntroFocusClaimed &&
                typeof root._focusSkipIntroIfVisible === "function") {
            try {
                root._focusSkipIntroIfVisible("chrome-visible-priority", false);
            } catch(ePriority) {}
        }
    } catch(e) {}
}

function syncSkipIntroOverlay(root, item) {
    if (!root) return;

    var pos = root.uiPositionMs();
    var s = startMs(root.skipIntroSegment);
    var e = endMs(root.skipIntroSegment);
    var h = hideMs(root.skipIntroSegment);

    if (root.skipIntroResumeGateActive) {
        root._skipIntroLastShow = false;
        root.skipIntroFocusClaimed = false;
        root.skipIntroAutoFocusClaimed = false;
        setSkipIntroItemActive(root, item, false);
        root._skipIntroLastPos = pos;
        return;
    }

    if (root.skipIntroSegment && e > s &&
            root.skipIntroPlaybackStartMs >= Math.max(e, h) &&
            pos >= Math.max(e, h)) {
        consumeSkipIntroIfPastResume(root, Math.max(pos, root.skipIntroPlaybackStartMs));
        setSkipIntroItemActive(root, item, false);
        return;
    }

    if (root.skipIntroSegment && e > s) {
        var rewound = root._skipIntroLastPos >= 0 &&
                      pos < root._skipIntroLastPos - root.skipIntroRearmRewindDeltaMs;
        if ((root.skipIntroConsumed || root.skipIntroDismissed || root.skipIntroVisualExpired) &&
                rewound &&
                pos < Math.max(0, e - root.skipIntroRearmBackMs)) {
            root.skipIntroConsumed = false;
            root.skipIntroDismissed = false;
            root.skipIntroVisualExpired = false;
        }
        root._skipIntroWasInside = pos >= Math.max(0, s - root.skipIntroLeadMs) && pos < e;
    }

    var show = shouldShow(
        root.skipIntroEnabled,
        root.skipIntroPlaybackArmed,
        root.skipIntroSegment,
        root.nextUiLocked,
        root.audioMenuVisible,
        root.subMenuVisible,
        root.skipIntroConsumed,
        root.skipIntroDismissed,
        root.skipIntroVisualExpired,
        pos,
        root.skipIntroLeadMs
    );

    var hasSkipFocus = false;
    try {
        hasSkipFocus = !!(item && item.priorityFocusActive === true);
    } catch(eFocus) {}
    root.skipIntroFocusClaimed = show && hasSkipFocus;

    if (show && hasSkipFocus) {
        try {
            if (root.uiChromeRenderVisible === false)
                root.skipIntroAutoFocusClaimed = true;
        } catch(eAutoFocus) {}
    } else if (!hasSkipFocus) {
        root.skipIntroAutoFocusClaimed = false;
    }

    if (show !== root._skipIntroLastShow)
        root._skipIntroLastShow = show;

    setSkipIntroItemActive(root, item, show);
    root._skipIntroLastPos = pos;
}

function resetSkipIntroState(root, item) {
    root.skipIntroSegment = null;
    root.skipIntroLoadedItemId = "";
    root.skipIntroDismissed = false;
    root.skipIntroConsumed = false;
    root.skipIntroVisualExpired = false;
    root.skipIntroPlaybackArmed = false;
    root.skipIntroPlaybackStartMs = 0;
    if (root._skipIntroMainSourceSeen !== undefined)
        root._skipIntroMainSourceSeen = false;
    root.skipIntroFocusReleasedByUser = false;
    root.skipIntroFocusClaimed = false;
    root.skipIntroResumeGateActive = false;
    root.skipIntroResumeTargetMs = -1;
    root.skipIntroResumeGateReason = "";
    root._skipIntroWasInside = false;
    root._skipIntroLastShow = false;
    root._skipIntroLastPos = -1;
    setSkipIntroItemActive(root, item, false);
}

function loadSkipIntroForCurrentItem(root, item) {
    if (!root.skipIntroEnabled || !root.serverUrl || !root.accessToken || !root.itemId) return;
    if (root.skipIntroLoadedItemId === root.itemId && root.skipIntroSegment) return;

    var expected = root.itemId;
    root.skipIntroLoadedItemId = expected;
    root.skipIntroDismissed = false;
    root.skipIntroConsumed = false;
    root.skipIntroVisualExpired = false;
    root.skipIntroFocusReleasedByUser = false;
    root.skipIntroFocusClaimed = false;
    root.skipIntroAutoFocusClaimed = false;
    root._skipIntroLastPos = -1;
    root.skipIntroSegment = null;

    fetchIntroSegment(root.serverUrl, root.accessToken, expected, function(ok, seg) {
        if (expected !== root.itemId) return;
        if (!ok || !seg) {
            root.skipIntroSegment = null;
            setSkipIntroItemActive(root, item, false);
            return;
        }
        root.skipIntroSegment = seg;
        syncSkipIntroOverlay(root, item);
    });
}

function skipIntroNow(root, item, isPlaying, preserveHiddenChrome) {
    var end = endMs(root.skipIntroSegment);
    var start = startMs(root.skipIntroSegment);
    if (end <= start) return false;

    var pos = Math.max(0, Math.floor(Number(root.uiPositionMs ? root.uiPositionMs() : 0)));
    var target = Math.max(0, end + root.skipIntroEndPadMs);

    root.skipIntroConsumed = true;
    root.skipIntroDismissed = false;
    root.skipIntroVisualExpired = false;
    root.skipIntroFocusClaimed = false;
    root.skipIntroAutoFocusClaimed = false;
    root._skipIntroLastShow = false;
    setSkipIntroItemActive(root, item, false);

    if (pos >= Math.max(start, end - 1000)) {
        if (preserveHiddenChrome !== true)
            root.resetControlsTimer();
        return true;
    }

    if (root.shouldNetworkSeek()) {
        root._wasPlayingBeforeSwitch = !!isPlaying;
        root._resumeWantedAfterNegotiation = root._wasPlayingBeforeSwitch;
        root._serverSeekFallback(target, "skipIntro");
    } else {
        root._localSeekTo(target, "skipIntro");
    }

    if (preserveHiddenChrome !== true)
        root.resetControlsTimer();
    return true;
}

// Gestion clavier spécifique au PlayerOverlay. La décision d'afficher le bouton
// reste dans shouldShow()/PlayerOverlay ; cette fonction ne fait que router les
// trois actions lorsque Skip Intro possède réellement la priorité de focus.
function handlePlayerOverlayKey(root, overlay, event) {
    if (!root || !event || root.skipIntroConsumed || root.skipIntroDismissed) return false;
    var w = overlay;
    if (!w || w.effectiveShow !== true) return false;
    var priority = false;
    try { priority = w.priorityFocusActive === true || w.activeFocus === true; } catch(e0) {}
    
    if (!root.skipIntroFocusClaimed && !priority) {
        
        return false;
    }

    var key = event.key;
    var isUp = key === Qt.Key_Up;
    var isDown = key === Qt.Key_Down;
    var isLeft = key === Qt.Key_Left;
    var isRight = key === Qt.Key_Right;
    var directional = isUp || isDown || isLeft || isRight;

    // Auto-focus : garde le cadre blanc quand le chrome revient, mais la première
    // navigation ne doit jamais devenir un verrou.
    if (directional && root.skipIntroAutoFocusClaimed === true) {
        
        if (isUp) {
            // Rien au-dessus : conserver SkipIntro et convertir l'auto-focus en
            // priorité manuelle stable.
            root.skipIntroAutoFocusClaimed = false;
            root.skipIntroFocusClaimed = true;
            try { if (typeof root.resetControlsTimer === "function") root.resetControlsTimer(); } catch(eAutoUpChrome) {}
            
            event.accepted = true;
            return true;
        }

        root.skipIntroAutoFocusClaimed = false;
        root.skipIntroFocusClaimed = false;
        root.skipIntroFocusReleasedByUser = true;
        try {
            if (w.releasePriorityFocus) w.releasePriorityFocus("auto-direction");
            else if (w.focusClaimed !== undefined) w.focusClaimed = false;
        } catch(eRelease) {}
        try {
            if (typeof root.resetControlsTimer === "function") root.resetControlsTimer();
            else root.controlsVisible = true;
        } catch(eChrome) {}
        try { if (typeof root.forceActiveFocus === "function") root.forceActiveFocus(); } catch(eRootFocus) {}

        if (isDown) {
            try {
                if (typeof root._focusProgressBarSilent === "function")
                    root._focusProgressBarSilent("skipintro-auto-down");
                else if (root.cF_PROGRESS !== undefined)
                    root.controlsFocus = root.cF_PROGRESS;
            } catch(eProgress) {}
            
            event.accepted = true;
            return true;
        }

        // ←/→ : libérer SkipIntro puis LAISSER LA MÊME TOUCHE continuer.
        // ProgressBar => seek ; transports => déplacement horizontal du bouton.
        
        return false;
    }

    if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Select || key === Qt.Key_Space) {
        
        if (w._doSkip) w._doSkip("playeroverlay");
        else if (typeof root.skipIntroNow === "function") root.skipIntroNow("playeroverlay");
        event.accepted = true; return true;
    }
    if (key === Qt.Key_Back || key === Qt.Key_Escape) {
        
        if (w._doHide) w._doHide("playeroverlay");
        else {
            root.skipIntroDismissed = true;
            if (typeof root._setSkipIntroItemActive === "function") root._setSkipIntroItemActive(w, false, "playeroverlay-back");
            if (typeof root._restoreFocusAfterSkipIntro === "function") root._restoreFocusAfterSkipIntro("back");
        }
        event.accepted = true; return true;
    }
    if (isDown) {
        
        if (w._doFocusBelow) w._doFocusBelow("playeroverlay");
        else {
            root.skipIntroFocusReleasedByUser = true;
            if (typeof root._focusProgressBarSilent === "function") root._focusProgressBarSilent("skipintro-manual-down");
        }
        event.accepted = true; return true;
    }
    if (isLeft || isRight) {
        // Priorité oui, prison non : libérer SkipIntro puis transmettre la même
        // direction au modèle de navigation du PlayerOverlay.
        
        root.skipIntroAutoFocusClaimed = false;
        root.skipIntroFocusClaimed = false;
        root.skipIntroFocusReleasedByUser = true;
        try {
            if (w.releasePriorityFocus) w.releasePriorityFocus("manual-horizontal");
            else if (w.focusClaimed !== undefined) w.focusClaimed = false;
        } catch(eHorizontalRelease) {}
        try { if (typeof root.resetControlsTimer === "function") root.resetControlsTimer(); } catch(eHorizontalChrome) {}
        try { if (typeof root.forceActiveFocus === "function") root.forceActiveFocus(); } catch(eHorizontalRootFocus) {}
        
        return false;
    }
    if (isUp) {
        
        event.accepted = true; return true;
    }
    
    return false;
}
