.pragma library
.import "MediaCatalog.js" as MediaCatalog
.import "SafeLog.js" as SafeLog
.import "clientId.js" as ClientId
function _s(v){ return (v === undefined || v === null) ? "" : (v + ""); }
function _safeCode(err, fallback) {
    return SafeLog.safeErrorCode(err, fallback || "network_error");
}
function enc(v) {
    try { return encodeURIComponent(_s(v)); } catch (e) { return _s(v); }
}
function _isArray(a) {
    if (typeof Array !== "undefined" && Array.isArray)
        return Array.isArray(a);
    return Object.prototype.toString.call(a) === "[object Array]";
}
function _int(v) {
    var n = Number(v);
    if (!isFinite(n) || isNaN(n)) return 0;
    n = Math.floor(n);
    return n;
}
function _posInt(v) {
    var n = _int(v);
    return n > 0 ? n : 0;
}
function _errCode(err, fallback){ return _safeCode(err, fallback || "network_error"); }
function _safeHttpErrorPayload(status) {
    status = status | 0;
    return {
        code: "http_" + status,
        message: "HTTP " + status,
        data: "",
        status: status
    };
}
var MAX_HTTP_TEXT_LEN = 262144; var MAX_TEXT_RESPONSE_LEN = 4194304; var DEFAULT_XHR_TIMEOUT_MS = 15000; var DEFAULT_NATIVE_TIMEOUT_MS = 15000;
// Budget unique des opérations qui enchaînent plusieurs pages/fallbacks.
// 14 s reste dans la fenêtre 12–15 s demandée et inclut toutes les sous-requêtes.
var PAGED_OPERATION_BUDGET_MS = 14000;
// Watchdog commun aux transports XHR et Freebox. Le bridge ne crée aucun Timer
// QML dynamique : ShellPage réveille un unique Timer uniquement tant qu'une
// opération est enregistrée. Sur les firmwares qui exposent abort()/cancel(),
// le transport est réellement interrompu ; sinon la réponse tardive est ignorée
// avant lecture/parsing de son corps.
var _httpOperationSeq = 0; var _httpOperations = {}; var _httpOperationCount = 0; var _httpWatchdogWake = null; var _httpWatchdogSignaled = false;
function setHttpWatchdogWake(callback) {
    _httpWatchdogWake = (typeof callback === "function") ? callback : null;
    _httpWatchdogSignaled = !_httpOperationCount;
    _syncHttpWatchdogWake();
}
function _syncHttpWatchdogWake() {
    var active = _httpOperationCount > 0;
    if (active === _httpWatchdogSignaled) return;
    _httpWatchdogSignaled = active;
    try { if (_httpWatchdogWake) _httpWatchdogWake(active); } catch(e0) {}
}
function _tryAbortTransport(transport) {
    if (!transport) return false;
    try {
        if (typeof transport.abort === "function") {
            transport.abort();
            return true;
        }
    } catch(e0) {}
    try {
        if (typeof transport.cancel === "function") {
            transport.cancel();
            return true;
        }
    } catch(e1) {}
    return false;
}
function _unregisterHttpOperation(op) {
    if (!op || !_httpOperations[op.id]) return;
    delete _httpOperations[op.id];
    _httpOperationCount = Math.max(0, _httpOperationCount - 1);
    _syncHttpWatchdogWake();
}
function _newHttpOperation(onSuccess, onError, timeoutMs) {
    _httpOperationSeq++;
    if (_httpOperationSeq > 2147483000) _httpOperationSeq = 1;
    var op = {
        id: _httpOperationSeq,
        active: true,
        deadlineAt: _nowMsBridge() + Math.max(100, Number(timeoutMs || DEFAULT_NATIVE_TIMEOUT_MS)),
        transport: null,
        transportPromise: null,
        setTransport: function(transport, promise) {
            this.transport = transport || null;
            this.transportPromise = promise || null;
        },
        isActive: function() { return this.active === true; },
        succeed: function(payload) {
            if (!this.active) return false;
            this.active = false;
            _unregisterHttpOperation(this);
            if (onSuccess) onSuccess(payload);
            return true;
        },
        fail: function(error) {
            if (!this.active) return false;
            this.active = false;
            _unregisterHttpOperation(this);
            if (onError) onError(error || { code: "network_error", message: "network_error" });
            return true;
        },
        cancel: function(reason, notifyError) {
            if (!this.active) return false;
            this.active = false;
            _tryAbortTransport(this.transport);
            _tryAbortTransport(this.transportPromise);
            this.transport = null;
            this.transportPromise = null;
            _unregisterHttpOperation(this);
            if (notifyError !== false && onError) {
                var code = reason === "timeout" ? "timeout" : "cancelled";
                onError({ code: code, message: code, cancelled: code === "cancelled" });
            }
            return true;
        }
    };
    _httpOperations[op.id] = op;
    _httpOperationCount++;
    _syncHttpWatchdogWake();
    return op;
}
function _completedHttpHandle() {
    return {
        active: false,
        isActive: function() { return false; },
        cancel: function() { return false; }
    };
}
function createPagedRequestController(budgetMs) {
    var budget = Number(budgetMs || PAGED_OPERATION_BUDGET_MS);
    if (!isFinite(budget) || budget <= 0) budget = PAGED_OPERATION_BUDGET_MS;
    budget = Math.max(12000, Math.min(15000, budget));
    return {
        active: true,
        done: false,
        cancelled: false,
        deadlineAt: _nowMsBridge() + budget,
        transport: null,
        isActive: function() { return this.active === true && !this.done && !this.cancelled; },
        remainingMs: function() { return Math.max(0, Number(this.deadlineAt || 0) - _nowMsBridge()); },
        expired: function() { return this.remainingMs() <= 0; },
        _setTransport: function(handle) {
            if (!this.isActive()) {
                try { if (handle && typeof handle.cancel === "function") handle.cancel("cancelled"); } catch(e0) {}
                return false;
            }
            this.transport = handle || null;
            return true;
        },
        _clearTransport: function(handle) {
            if (!handle || this.transport === handle) this.transport = null;
        },
        _finish: function() {
            if (!this.isActive()) return false;
            this.active = false;
            this.done = true;
            this.transport = null;
            return true;
        },
        cancel: function(reason) {
            if (!this.isActive()) return false;
            this.active = false;
            this.cancelled = true;
            var handle = this.transport;
            this.transport = null;
            try {
                if (handle && typeof handle.cancel === "function")
                    handle.cancel(reason || "cancelled");
            } catch(e0) {}
            return true;
        }
    };
}
function sweepHttpWatchdogs(nowMs) {
    var now = Number(nowMs || _nowMsBridge()); var expired = [];
    for (var key in _httpOperations) {
        if (!Object.prototype.hasOwnProperty.call(_httpOperations, key)) continue;
        var op = _httpOperations[key];
        if (op && op.active && Number(op.deadlineAt || 0) <= now)
            expired.push(op);
    }
    for (var i = 0; i < expired.length; i++)
        expired[i].cancel("timeout", true);
    return _httpOperationCount;
}
function cancelAllHttpRequests(reason) {
    var pending = [];
    for (var key in _httpOperations) {
        if (Object.prototype.hasOwnProperty.call(_httpOperations, key) && _httpOperations[key])
            pending.push(_httpOperations[key]);
    }
    for (var i = 0; i < pending.length; i++)
        pending[i].cancel(reason || "cancelled", false);
    return pending.length;
}
function _safeResponseText(txt, maxLen) {
    txt = _s(txt);
    var limit = maxLen || MAX_HTTP_TEXT_LEN;
    if (txt.length > limit)
        return "";
    return txt;
}
function _parseJsonBounded(txt) {
    try {
        var s = _s(txt);
        if (!s || s.length > MAX_HTTP_TEXT_LEN)
            return null;
        return JSON.parse(s);
    } catch(e) {
        return null;
    }
}
function _headersWantText(headers) {
    try {
        headers = headers || {};
        for (var k in headers) {
            if (!Object.prototype.hasOwnProperty.call(headers, k)) continue;
            var kk = _s(k).toLowerCase(); var vv = _s(headers[k]).toLowerCase();
            if ((kk === "accept" || kk === "content-type") &&
                (vv.indexOf("text/plain") >= 0 || vv.indexOf("text/vtt") >= 0 || vv.indexOf("application/x-subrip") >= 0))
                return true;
        }
    } catch(e0) {}
    return false;
}
function _isSubtitleTextUrl(url) {
    var u = _s(url).toLowerCase();
    return (u.indexOf("/subtitles/") >= 0 ||
            u.indexOf("/stream.vtt") >= 0 ||
            u.indexOf("/stream.srt") >= 0 ||
            u.indexOf("/stream.ass") >= 0 ||
            u.indexOf("/stream.ssa") >= 0);
}
function _shouldReturnTextForRequest(method, url, headers) {
    method = _s(method || "GET").toUpperCase();
    if (method !== "GET") return false;
    return _headersWantText(headers) || _isSubtitleTextUrl(url);
}
function _safeResponseHeaderValue(value, maxLen) {
    var s = _s(value); var limit = Math.max(64, Math.min(4096, Number(maxLen || 2048)));
    if (!s) return "";
    // Réponse serveur non fiable : aucune CR/LF et taille bornée.
    s = s.replace(/[\r\n\u0000]/g, "");
    return s.length > limit ? s.substr(0, limit) : s;
}
function _safeResponseHeaders(headers) {
    headers = headers || {};
    var out = {};
    var allow = {
        "content-type": "Content-Type",
        "content-length": "Content-Length",
        "content-range": "Content-Range",
        "accept-ranges": "Accept-Ranges",
        "location": "Location",
        "etag": "ETag",
        "last-modified": "Last-Modified",
        "cache-control": "Cache-Control"
    };
    try {
        for (var k in headers) {
            if (!Object.prototype.hasOwnProperty.call(headers, k)) continue;
            var lower = _s(k).toLowerCase(); var canonical = allow[lower];
            if (!canonical) continue;
            var value = _safeResponseHeaderValue(headers[k], lower === "location" ? 2048 : 1024);
            if (!value) continue;
            // Une redirection peut être nécessaire au bridge, mais un token
            // renvoyé dans sa query ne doit pas ressortir dans le payload public.
            if (lower === "location")
                value = stripAuthQueryFromUrl(value);
            out[canonical] = value;
        }
    } catch(e0) {}
    return out;
}
function _makeSafeHttpSuccessPayload(status, rawText, headersObj, jsonParseFn, returnText) {
    var raw = _s(rawText); var maxLen = returnText ? MAX_TEXT_RESPONSE_LEN : MAX_HTTP_TEXT_LEN;
    if (raw.length > maxLen)
        return { tooLarge: true };
    var json = null;
    if (!returnText) {
        try {
            json = (typeof jsonParseFn === "function") ? jsonParseFn() : _parseJsonBounded(raw);
        } catch(e0) {
            json = _parseJsonBounded(raw);
        }
    }
    return {
        tooLarge: false,
        payload: {
            status: status | 0,
            text: returnText ? _safeResponseText(raw, maxLen) : "",
            json: json,
            headers: _safeResponseHeaders(headersObj)
        }
    };
}
function _stripQueryAndFragment(url) {
    var s = _s(url); var cut = s.search(/[?#]/);
    return cut >= 0 ? s.substring(0, cut) : s;
}
function _isAuthQueryKey(key) {
    var k = _s(key).toLowerCase().replace(/[^a-z0-9]/g, "");
    return k === "apikey" || k === "accesstoken" || k === "token" ||
           k === "xembytoken" || k === "xmediabrowsertoken" ||
           k === "authorization" || k === "cookie" || k === "setcookie";
}
function stripAuthQueryFromUrl(url) {
    var s = _s(url);
    // Les fragments ne sont jamais utiles à l'API et peuvent eux aussi transporter
    // accidentellement un secret copié depuis une interface web.
    var hashPos = s.indexOf("#");
    if (hashPos >= 0) s = s.substring(0, hashPos);
    var qPos = s.indexOf("?");
    if (qPos < 0) return s;
    var base = s.substring(0, qPos); var query = s.substring(qPos + 1); var parts = query.split("&"); var out = [];
    for (var i = 0; i < parts.length; i++) {
        var part = parts[i];
        if (!part) continue;
        var rawKey = part.split("=")[0] || ""; var key = rawKey;
        try { key = decodeURIComponent(rawKey.replace(/\+/g, "%20")); } catch(e0) {}
        if (_isAuthQueryKey(key)) continue;
        out.push(part);
    }
    return base + (out.length ? ("?" + out.join("&")) : "");
}
var _fbx = null;
function setFbx(fbxCtx) { _fbx = fbxCtx; }
var _apiGetCache = {}; var _apiGetInflight = {}; var _apiGetFailUntil = {}; var _apiLatestParentFailUntil = {}; var _apiGetMaxEntries = 64; var _apiCooldownMaxEntries = 96; var _apiSweepTick = 0; var _apiCacheEpoch = 1;
function _apiHashHex(h) {
    var out = (h >>> 0).toString(16);
    while (out.length < 8) out = "0" + out;
    return out.substr(0, 8);
}
function _apiCacheFingerprint(value) {
    var s = _s(value); var h1 = 2166136261; var h2 = 2166136261;
    // Deux parcours sans chaîne inversée temporaire : moins d'allocations sur CE4100.
    for (var i = 0, j = s.length - 1; i < s.length; i++, j--) {
        h1 ^= s.charCodeAt(i);
        h1 += (h1 << 1) + (h1 << 4) + (h1 << 7) + (h1 << 8) + (h1 << 24);
        h2 ^= s.charCodeAt(j);
        h2 += (h2 << 1) + (h2 << 4) + (h2 << 7) + (h2 << 8) + (h2 << 24);
    }
    h2 ^= s.length;
    h2 += (h2 << 1) + (h2 << 4) + (h2 << 7) + (h2 << 8) + (h2 << 24);
    // Aucune valeur sensible n'est conservée en clair dans les clés mémoire.
    return _apiHashHex(h1) + _apiHashHex(h2);
}
function _apiOriginForCache(url) {
    var s = _s(url).trim();
    var m = /^(https?):\/\/(\[[^\]]+\]|[^\/:?#]+)(?::(\d+))?/i.exec(s);
    if (!m) return "";
    var scheme = _s(m[1]).toLowerCase(); var host = _s(m[2]).toLowerCase(); var port = m[3] ? _s(m[3]) : (scheme === "https" ? "443" : "80");
    return scheme + "://" + host + ":" + port;
}
function _apiHeaderValue(headers, wantedName) {
    if (!headers || typeof headers !== "object") return "";
    var want = _normalizedHeaderName(wantedName);
    try {
        for (var k in headers) {
            if (!Object.prototype.hasOwnProperty.call(headers, k)) continue;
            if (_normalizedHeaderName(k) === want)
                return _s(headers[k]);
        }
    } catch(e) {}
    return "";
}
function _authorizationTokenFromHeaderValue(value) {
    var auth = _s(value);
    if (!auth) return "";
    var m = /(?:^|[,\s])Token\s*=\s*"([^"]*)"/i.exec(auth);
    if (!m || !m[1]) return "";
    try { return decodeURIComponent(m[1]); } catch(e0) { return _s(m[1]); }
}
function _apiTokenForCache(headers) {
    // ReDeFin émet l’authentification Jellyfin via Authorization: MediaBrowser.
    // Une seule source de vérité évite deux générations de headers dans le cache.
    return _authorizationTokenFromHeaderValue(_apiHeaderValue(headers, "Authorization"));
}
function _apiUserIdForCache(url) {
    var s = _s(url); var m = /\/Users\/([^\/?#]+)/i.exec(s);
    if (!m || !m[1])
        m = /[?&](?:userId|UserId)=([^&#]+)/.exec(s);
    if (!m || !m[1]) return "";
    try { return decodeURIComponent(m[1]); } catch(e) { return _s(m[1]); }
}
function _apiAuthContextFingerprint(url, headers) {
    var origin = _apiOriginForCache(url); var token = _apiTokenForCache(headers); var userId = _apiUserIdForCache(url); var kind = token ? "auth" : "public";
    return kind
        + "#o" + _apiCacheFingerprint(origin)
        + "#u" + _apiCacheFingerprint(userId)
        + "#t" + _apiCacheFingerprint(token);
}
function _apiInflightWaiters(entry) {
    if (!entry) return [];
    return _isArray(entry) ? entry : (entry.waiters || []);
}
function _apiInflightActiveWaiterCount(entry) {
    var waiters = _apiInflightWaiters(entry), count = 0;
    for (var i = 0; i < waiters.length; i++)
        if (waiters[i] && waiters[i].active !== false) count++;
    return count;
}
function _apiCancelInflightLeader(entry, reason) {
    if (!entry || _isArray(entry)) return false;
    var leader = entry.leader;
    entry.leader = null;
    try {
        if (leader && typeof leader.cancel === "function")
            return leader.cancel(reason || "cancelled");
    } catch(e0) {}
    return false;
}
function _apiAddInflightWaiter(key, entry, onSuccess, onError) {
    var waiter = { ok: onSuccess, ko: onError, active: true };
    entry.waiters.push(waiter);
    return {
        isActive: function() {
            return waiter.active === true;
        },
        cancel: function(reason) {
            if (waiter.active !== true) return false;
            waiter.active = false;
            // Un abonné ne coupe le leader que lorsqu'il était le dernier
            // consommateur réel de cette réponse coalescée.
            if (entry.done !== true && _apiGetInflight[key] === entry && _apiInflightActiveWaiterCount(entry) <= 0) {
                delete _apiGetInflight[key];
                entry.done = true;
                _apiCancelInflightLeader(entry, reason || "no_subscriber");
            }
            return true;
        }
    };
}
function clearApiCaches(cancelInflightLeaders) {
    var pending = _apiGetInflight;
    _apiCacheEpoch++;
    if (_apiCacheEpoch > 2147483000) _apiCacheEpoch = 1;
    _apiGetCache = {};
    _apiGetInflight = {};
    _apiGetFailUntil = {};
    _apiLatestParentFailUntil = {};
    _apiSweepTick = 0;
    // Les consommateurs déjà coalescés ne doivent pas rester suspendus. Ils
    // reçoivent une erreur locale neutre et les callbacks réseau de l'ancien
    // epoch seront ignorés.
    try {
        for (var key in pending) {
            if (!Object.prototype.hasOwnProperty.call(pending, key)) continue;
            var entry = pending[key]; var waiters = _apiInflightWaiters(entry);
            if (entry && !_isArray(entry)) entry.done = true;
            if (cancelInflightLeaders === true)
                _apiCancelInflightLeader(entry, "session_changed");
            for (var i = 0; i < waiters.length; i++) {
                (function(w) {
                    if (!w || w.active === false) return;
                    _laterBridge(function() {
                        try {
                            if (!w || w.active === false) return;
                            w.active = false;
                            if (w && typeof w.ko === "function")
                                w.ko({ code: "cache_cleared", message: "cache_cleared", status: 0 });
                        } catch(e0) {}
                    });
                })(waiters[i]);
            }
        }
    } catch(e1) {}
    return true;
}
function evictLatestParentApiCache(parentId) {
    parentId = _s(parentId);
    if (!parentId) return false;
    var removed = false;
    try {
        for (var key in _apiGetCache) {
            if (!Object.prototype.hasOwnProperty.call(_apiGetCache, key)) continue;
            var entry = _apiGetCache[key];
            if (entry && _s(entry.latestParentId) === parentId) {
                delete _apiGetCache[key];
                removed = true;
            }
        }
    } catch(e0) {}
    return removed;
}
function evictUserItemApiCache(itemId) {
    itemId = _s(itemId);
    if (!itemId) return false;
    var removed = false;
    try {
        for (var key in _apiGetCache) {
            if (!Object.prototype.hasOwnProperty.call(_apiGetCache, key)) continue;
            var entry = _apiGetCache[key];
            if (entry && _s(entry.userItemId) === itemId) {
                delete _apiGetCache[key];
                removed = true;
            }
        }
    } catch(e0) {}
    return removed;
}
function _nowMsBridge() {
    try { return Date.now(); } catch(e) { return (new Date()).getTime(); }
}
function _laterBridge(fn) {
    try {
        if (typeof Qt !== "undefined" && Qt && Qt.callLater) {
            Qt.callLater(fn);
            return;
        }
    } catch(e0) {}
    try { fn(); } catch(e1) {}
}
function putBoundedMemory(bucket, key, value, maxEntries) {
    if (!bucket || typeof bucket !== "object" || !key) return false;
    maxEntries = Math.max(8, Math.min(128, _int(maxEntries) || 48));
    var previous = bucket.__redefinOrder; var order = [], tracked = {}, i;
    if (_isArray(previous)) {
        for (i = 0; i < previous.length; i++) {
            var remembered = previous[i];
            if (remembered && remembered !== key && Object.prototype.hasOwnProperty.call(bucket, remembered) && !tracked[remembered]) {
                tracked[remembered] = 1;
                order.push(remembered);
            }
        }
    }
    // Reprend aussi les entrées créées avant l'introduction du bornage ou par
    // un ancien composant : sans cela elles resteraient hors quota à vie.
    for (var existing in bucket) {
        if (!Object.prototype.hasOwnProperty.call(bucket, existing) || existing === "__redefinOrder" ||
                existing === key || tracked[existing]) continue;
        tracked[existing] = 1;
        order.push(existing);
    }
    order.push(key);
    while (order.length > maxEntries) {
        var oldest = order.shift();
        if (oldest && oldest !== key) delete bucket[oldest];
    }
    bucket[key] = value;
    bucket.__redefinOrder = order;
    return true;
}
function _apiGetTrimCache() {
    try {
        var keys = [];
        for (var k in _apiGetCache) {
            if (Object.prototype.hasOwnProperty.call(_apiGetCache, k))
                keys.push(k);
        }
        if (keys.length <= _apiGetMaxEntries) return;
        keys.sort(function(a, b) {
            var aa = _apiGetCache[a] ? (_apiGetCache[a].ts || 0) : 0; var bb = _apiGetCache[b] ? (_apiGetCache[b].ts || 0) : 0;
            return aa - bb;
        });
        var removeCount = Math.max(1, keys.length - _apiGetMaxEntries);
        for (var i = 0; i < removeCount; i++)
            delete _apiGetCache[keys[i]];
    } catch(e) {}
}
function _apiTrimDeadlineMap(map, now, maxEntries) {
    var entries = [];
    try {
        for (var k in map) {
            if (!Object.prototype.hasOwnProperty.call(map, k)) continue;
            var until = Number(map[k] || 0);
            if (!isFinite(until) || until <= now) {
                delete map[k];
                continue;
            }
            entries.push({ key: k, until: until });
        }
        if (entries.length <= maxEntries) return;
        entries.sort(function(a, b) { return a.until - b.until; });
        for (var i = 0; i < entries.length - maxEntries; i++)
            delete map[entries[i].key];
    } catch(e) {}
}
function _apiPurgeExpiredMaps(now, force) {
    _apiSweepTick++;
    if (!force && (_apiSweepTick % 16) !== 0) return;
    try {
        for (var k in _apiGetCache) {
            if (!Object.prototype.hasOwnProperty.call(_apiGetCache, k)) continue;
            var entry = _apiGetCache[k];
            if (!entry || (entry.expiresAt && entry.expiresAt <= now))
                delete _apiGetCache[k];
        }
    } catch(e0) {}
    _apiTrimDeadlineMap(_apiGetFailUntil, now, _apiCooldownMaxEntries);
    _apiTrimDeadlineMap(_apiLatestParentFailUntil, now, _apiCooldownMaxEntries);
}
function _isMemoizableApiGet(method, url, body) {
    method = _s(method || "GET").toUpperCase();
    url = _s(url);
    if (method !== "GET") return false;
    if (body !== undefined && body !== null && _s(body) !== "") return false;
    if (url.indexOf("/Images/") >= 0 || url.indexOf("/UserImage") >= 0) return false;
    if (url.indexOf("/Sessions/") >= 0) return false;
    if (url.indexOf("/PlaybackInfo") >= 0) return false;
    if (url.indexOf("/UserData") >= 0) return false;
    if (_apiIsUserItemDetailsUrl(url)) return true;
    return (url.indexOf("/UserViews") >= 0) ||
           (url.indexOf("/UserItems/Resume") >= 0) ||
           (url.indexOf("/Items/Latest") >= 0) ||
           (url.indexOf("/Shows/NextUp") >= 0);
}
function _apiGetCacheKey(method, url, headers) {
    // Isolation stricte : méthode + epoch + contexte serveur/profil/token + URL.
    // Aucune donnée d'authentification n'est conservée en clair dans la clé.
    return _s(method || "GET").toUpperCase()
        + "#api#e" + _apiCacheEpoch
        + "#" + _apiAuthContextFingerprint(url, headers)
        + "#r" + _apiCacheFingerprint(url);
}
function _apiGetTtlMs(url) {
    url = _s(url);
    if (_apiIsUserItemDetailsUrl(url)) return 2500;
    if (url.indexOf("/UserViews") >= 0) return 90000;
    if (url.indexOf("/Items/Latest") >= 0) return 120000;
    if (url.indexOf("/Shows/NextUp") >= 0) return 15000;
    if (url.indexOf("/UserItems/Resume") >= 0) return 12000;
    return 0;
}
function _apiLatestParentIdFromUrl(url) {
    url = _s(url);
    if (url.indexOf("/Items/Latest") < 0) return "";
    var m = /[?&]ParentId=([^&]+)/.exec(url);
    if (!m || !m[1]) return "";
    try { return decodeURIComponent(m[1]); } catch(e) { return _s(m[1]); }
}
function _apiIsUserItemDetailsUrl(url) {
    url = _s(url);
    if (url.indexOf("/Items/") < 0) return false;
    if (url.indexOf("/Items?") >= 0) return false;
    if (url.indexOf("/Images/") >= 0) return false;
    if (url.indexOf("/PlaybackInfo") >= 0) return false;
    if (url.indexOf("/UserData") >= 0) return false;
    if (!/[?&](?:UserId|userId)=([^&#]+)/.test(url)) return false;
    return /\/Items\/[^\/\?]+(?:\?|$)/.test(url);
}
function _apiUserItemIdFromUrl(url) {
    url = _s(url);
    if (!_apiIsUserItemDetailsUrl(url)) return "";
    var m = /\/Items\/([^\/\?]+)(?:\?|$)/.exec(url);
    if (!m || !m[1]) return "";
    try { return decodeURIComponent(m[1]); } catch(e0) { return _s(m[1]); }
}
function _apiGetFailCooldownMs(url, err) {
    url = _s(url);
    var c = _errCode(err, "");
    if (url.indexOf("/Items/Latest") < 0) return 0;
    if (c === "http_500" || c === "http_502" || c === "http_503" || c === "http_504")
        return 600000;
    if (c === "network_error" || c === "timeout")
        return 60000;
    return 0;
}
function _apiGetFlush(key, expectedEntry, ok, payload) {
    var entry = _apiGetInflight[key];
    // Un ancien leader annulé ne doit jamais vider les abonnés d'un nouveau
    // leader créé ensuite sous la même clé.
    if (!entry || (expectedEntry && entry !== expectedEntry)) return false;
    var waiters = _apiInflightWaiters(entry);
    delete _apiGetInflight[key];
    if (entry && !_isArray(entry)) {
        entry.done = true;
        entry.leader = null;
    }
    for (var i = 0; i < waiters.length; i++) {
        (function(w) {
            if (!w || w.active === false) return;
            _laterBridge(function() {
                try {
                    if (!w || w.active === false) return;
                    w.active = false;
                    if (ok) {
                        if (w && typeof w.ok === "function") w.ok(payload);
                    } else {
                        if (w && typeof w.ko === "function") w.ko(payload);
                    }
                } catch(e) {}
            });
        })(waiters[i]);
    }
    return true;
}
function setClientIdentity(info) {
    if (!info || typeof info !== "object") return;
    try { ClientId.initFromQmlDevice(info); }
    catch(e0) {}
}
function _hostFromServerUrlLike(value) {
    var s = _s(value).trim().toLowerCase();
    if (!s || s.length > 512 || /[\r\n\t]/.test(s)) return "";
    s = s.replace(/\\/g, "/");
    var scheme = s.indexOf("://");
    if (scheme >= 0) s = s.substring(scheme + 3);
    var cut = s.search(/[\/?#]/);
    if (cut >= 0) s = s.substring(0, cut);
    if (!s || s.indexOf("@") >= 0) return "";
    if (s.charAt(0) === "[") {
        var rb = s.indexOf("]");
        if (rb <= 1) return "";
        return s.substring(1, rb);
    }
    var firstColon = s.indexOf(":"); var lastColon = s.lastIndexOf(":");
    if (firstColon > 0 && firstColon === lastColon && /^\d+$/.test(s.substring(firstColon + 1)))
        s = s.substring(0, firstColon);
    while (s.length && s.charAt(s.length - 1) === ".") s = s.substring(0, s.length - 1);
    return s;
}
function isShortLanHostName(value){ return !!(SafeLog && SafeLog.isShortLanHostName && SafeLog.isShortLanHostName(value)); }
function trustLanHost(value){ return !!(SafeLog && SafeLog.trustLanHost && SafeLog.trustLanHost(value)); }
function forgetTrustedLanHost(value){ return !!(SafeLog && SafeLog.forgetTrustedLanHost && SafeLog.forgetTrustedLanHost(value)); }
function clearTrustedLanHosts(){ if (SafeLog && SafeLog.clearTrustedLanHosts) SafeLog.clearTrustedLanHosts(); }
function isTrustedLanHost(value){ return !!(SafeLog && SafeLog.isTrustedLanHost && SafeLog.isTrustedLanHost(value)); }
function _isLikelyLanHostForUrl(value) {
    var h = _hostFromServerUrlLike(value);
    return !!(h && SafeLog && SafeLog.isLocalHost && SafeLog.isLocalHost(h));
}
function isWanHttpUrl(value){ return !!(SafeLog && SafeLog.isWanHttpUrl && SafeLog.isWanHttpUrl(_s(value).trim())); }
function isValidPublicSystemInfo(info) {
    if (!info || typeof info !== "object") return false;
    var version = _s(info.Version || info.version).trim();
    var identity = _s(info.ServerName || info.ProductName || info.Id || info.ServerId ||
                      info.serverName || info.productName || info.id || info.serverId).trim();
    if (!version || !identity) return false;
    if (version.length > 64 || identity.length > 256) return false;
    return true;
}
// ===== Sécurité transport : aucun secret Jellyfin sur HTTP hors LAN =====
function _normalizedHeaderName(name){ return _s(name).toLowerCase().replace(/[^a-z0-9]/g, ""); }
function _headersContainAuthSecret(headers) {
    if (!headers || typeof headers !== "object") return false;
    try {
        for (var k in headers) {
            if (!Object.prototype.hasOwnProperty.call(headers, k)) continue;
            var nk = _normalizedHeaderName(k); var value = _s(headers[k]);
            if (nk === "authorization")
                return /(?:^|[,\s])Token\s*=/i.test(value);
            // Détection défensive des anciens formats, sans jamais les émettre.
            if (nk === "xembytoken" || nk === "xmediabrowsertoken")
                return value.length > 0;
            if ((nk === "xembyauthorization" || nk === "xmediabrowserauthorization") &&
                    /(?:^|[,\s])(?:token|api[_-]?key)\s*=/i.test(value))
                return true;
        }
    } catch(e0) {}
    return false;
}
function _urlContainsAuthSecret(url) {
    var s = _s(url); var q = s.indexOf("?");
    if (q < 0) return false;
    var end = s.indexOf("#", q + 1); var query = s.substring(q + 1, end >= 0 ? end : s.length); var parts = query.split("&");
    for (var i = 0; i < parts.length; i++) {
        var rawKey = parts[i].split("=")[0] || ""; var key = rawKey;
        try { key = decodeURIComponent(rawKey.replace(/\+/g, "%20")); } catch(e0) {}
        key = _s(key).toLowerCase().replace(/[^a-z0-9]/g, "");
        if (key === "apikey" || key === "accesstoken" || key === "token" ||
                key === "xembytoken" || key === "xmediabrowsertoken")
            return true;
    }
    return false;
}
function _bodyContainsCredentialSecret(url, body) {
    if (body === undefined || body === null || _s(body) === "") return false;
    var path = _stripQueryAndFragment(_s(url)).toLowerCase();
    return path.indexOf("/users/authenticatebyname") >= 0 ||
           path.indexOf("/users/authenticatewithquickconnect") >= 0;
}
function requestContainsAuthSecret(url, headers, body) {
    return _headersContainAuthSecret(headers) ||
           _urlContainsAuthSecret(url) ||
           _bodyContainsCredentialSecret(url, body);
}
function isSensitiveRequestAllowed(url, headers, body) {
    var sensitive = requestContainsAuthSecret(url, headers, body);
    if (!sensitive) return true;
    var s = _s(url).trim();
    // Un secret ne doit jamais partir vers une URL relative ou un schéma inattendu.
    if (!/^https?:\/\//i.test(s)) return false;
    return !isWanHttpUrl(s);
}
function _insecureTransportPayload() {
    return {
        code: "insecure_transport",
        message: "insecure_transport",
        data: "",
        status: 0
    };
}
function _rejectInsecureTransport(url, headers, body, onError) {
    if (isSensitiveRequestAllowed(url, headers, body)) return false;
    _laterBridge(function() {
        try { if (typeof onError === "function") onError(_insecureTransportPayload()); } catch(e0) {}
    });
    return true;
}
function _hasInvalidSchemeLikeForUrl(value) {
    var t = _s(value).trim();
    if (!t) return false;
    if (/^[a-zA-Z][a-zA-Z0-9+\-.]*:\/\//.test(t))
        return true;
    var slash = t.search(/[\/\?#]/); var head = slash >= 0 ? t.substring(0, slash) : t;
    if (!/^[a-zA-Z][a-zA-Z0-9+\-.]*:/.test(head))
        return false;
    // Autorise host:port sans schéma.
    return !/:\d+$/.test(head);
}
function _isHttpLike(u) {
    u = _s(u).trim();
    return /^https?:\/\//i.test(u);
}
function normalizeServerUrl(input, preferHttps) {
    var u = _s(input).trim();
    if (!u || u.length > 512) return "";
    if (u.indexOf("\n") >= 0 || u.indexOf("\r") >= 0 || u.indexOf("\t") >= 0)
        return "";
    u = u.replace(/\\/g, "/");
    if (!_isHttpLike(u)) {
        if (_hasInvalidSchemeLikeForUrl(u))
            return "";
        // preferHttps garde sa sémantique historique, mais LAN sans schéma reste en HTTP.
        u = (_isLikelyLanHostForUrl(u) ? "http://" : "https://") + u;
    }
    if (!_isHttpLike(u))
        return "";
    var authority = u.replace(/^https?:\/\//i, "").split("/")[0];
    if (!authority || authority.length > 255)
        return "";
    if (authority.indexOf("@") >= 0)
        return "";
    if (/\s/.test(authority))
        return "";
    u = _stripQueryAndFragment(u);
    u = u.replace(/\/web\/index\.html.*$/i, "");
    u = u.replace(/\/web\/?$/i, "");
    while (u.length > 1 && u.charAt(u.length - 1) === "/")
        u = u.slice(0, -1);
    return u;
}
function _normalizeBase(url){ return normalizeServerUrl(url, true); }
function _u(base, path) {
    base = _normalizeBase(base);
    if (!base) return "";
    path = _s(path);
    if (!path) return base;
    return base + (path.charAt(0) === "/" ? path : ("/" + path));
}
function _mbAuthHeaderValue(accessToken) {
    try { return ClientId.authorizationHeader(accessToken); }
    catch (e0) {}

    // Fallback défensif si le module d’identité devient indisponible :
    // conserver un header minimal plutôt que casser toutes les requêtes Jellyfin.
    var base = "";
    try { base = ClientId.embyAuthHeader(); } catch (e1) {}
    accessToken = _s(accessToken).replace(/["\\,\u0000-\u001F\u007F]/g, "");
    if (!accessToken) return base;
    return base ? (base + ', Token="' + accessToken + '"')
                : ('MediaBrowser Token="' + accessToken + '"');
}

function headersWithToken(accessToken) {
    var auth = _mbAuthHeaderValue(accessToken);
    var h = {
        "Content-Type": "application/json",
        "Accept": "application/json"
    };
    if (auth)
        h["Authorization"] = auth;
    return h;
}
function jsonNormalize(json) {
    if (!json) return null;
    if (json && json.data && typeof json.data === "object") return json.data;
    return json;
}
function _swapHost(url, altHost) {
    url = _s(url);
    altHost = _s(altHost);
    if (!altHost) return url;
    return url.replace(/^(https?:\/\/)([^/]+)/i, function (_, p1) {
        return p1 + altHost;
    });
}
function _safeTrim(v) {
    v = _s(v);
    return (v.trim ? v.trim() : v);
}
function _parseRawHeaders(raw) {
    var out = {};
    raw = _s(raw);
    if (!raw) return out;
    var lines = raw.split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
        var L = _s(lines[i]); var p = L.indexOf(":");
        if (p > 0) {
            var key = _safeTrim(L.slice(0, p)); var val = _safeTrim(L.slice(p + 1));
            if (key) out[key] = val;
        }
    }
    return out;
}
function _resolveRedirect(currentUrl, location) {
    var loc = _s(location).trim();
    if (!loc) return "";
    if (/^https?:\/\//i.test(loc)) return stripAuthQueryFromUrl(loc);
    var cur = _s(currentUrl); var m = cur.match(/^(https?:\/\/[^/]+)([^?#]*)/i); var origin = m ? m[1] : "";
    if (!origin) return "";
    if (loc.charAt(0) === '/') return stripAuthQueryFromUrl(origin + loc);
    var path = m[2] || "/"; var slash = path.lastIndexOf("/"); var dir = slash >= 0 ? path.substring(0, slash + 1) : "/";
    return stripAuthQueryFromUrl(origin + dir + loc);
}
function _redirectHost(url) {
    var s = _s(url); var m = s.match(/^[a-zA-Z][a-zA-Z0-9+\-.]*:\/\/([^\/\?#]+)/);
    if (!m) return "";
    var hostPort = _s(m[1]).toLowerCase();
    if (hostPort.charAt(0) === "[") {
        var end = hostPort.indexOf("]");
        if (end > 0)
            return hostPort.substr(1, end - 1);
        return hostPort;
    }
    var colon = hostPort.indexOf(":");
    if (colon >= 0)
        return hostPort.substr(0, colon);
    return hostPort;
}
function _redirectOrigin(url) {
    var s = _s(url).trim();
    var m = s.match(/^(https?):\/\/(\[[^\]]+\]|[^\/:?#]+)(?::(\d+))?(?:[\/?#]|$)/i);
    if (!m) return null;
    var scheme = _s(m[1]).toLowerCase(); var host = _s(m[2]).toLowerCase(); var port = m[3] ? parseInt(m[3], 10) : (scheme === "https" ? 443 : 80);
    if (!host || !isFinite(port) || port < 1 || port > 65535)
        return null;
    return { scheme: scheme, host: host, port: port };
}
function _sameHostRedirect(fromUrl, toUrl) {
    // Nom conservé pour compatibilité interne, mais la comparaison est désormais
    // une stricte same-origin : schéma + hôte + port effectif.
    var a = _redirectOrigin(fromUrl); var b = _redirectOrigin(toUrl);
    return !!(a && b &&
              a.scheme === b.scheme &&
              a.host === b.host &&
              a.port === b.port);
}
function _hostFromAuthority(authority) {
    var s = _s(authority).toLowerCase();
    if (!s) return "";
    var m = s.match(/^[a-zA-Z][a-zA-Z0-9+\-.]*:\/\/([^\/\?#]+)/);
    if (m) s = m[1];
    if (s.charAt(0) === "[") {
        var end = s.indexOf("]");
        if (end > 0)
            return s.substr(1, end - 1);
        return s;
    }
    var slash = s.indexOf("/");
    if (slash >= 0)
        s = s.substr(0, slash);
    var colon = s.indexOf(":");
    if (colon >= 0)
        return s.substr(0, colon);
    return s;
}
function _authorityForSwap(authority) {
    var s = _s(authority);
    if (!s) return "";
    var m = s.match(/^[a-zA-Z][a-zA-Z0-9+\-.]*:\/\/([^\/\?#]+)/);
    if (m) s = m[1];
    var slash = s.indexOf("/");
    if (slash >= 0)
        s = s.substr(0, slash);
    return s;
}
function _isLocalAuthHost(host){ return _isLikelyLanHostForUrl(_hostFromAuthority(host)); }
function _safeAltUrlForAuth(url, altHost) {
    var altAuthority = _authorityForSwap(altHost); var alt = _hostFromAuthority(altAuthority);
    if (!altAuthority || !alt) return "";
    var current = _redirectHost(url);
    if (current && alt === _hostFromAuthority(current))
        return _swapHost(url, altAuthority);
    if (_isLocalAuthHost(alt))
        return _swapHost(url, altAuthority);
    return "";
}
function _xhrSend(method, url, headers, body, onSuccess, onError, timeoutMs) { if (_rejectInsecureTransport(url, headers, body, onError)) { return _completedHttpHandle(); }
    var xhr = null; var op = null;
    try {
        if (typeof XMLHttpRequest === "undefined")
            throw new Error("XMLHttpRequest indisponible");
        xhr = new XMLHttpRequest();
        var effectiveTimeout = Math.max(100, Number(timeoutMs || DEFAULT_XHR_TIMEOUT_MS));
        op = _newHttpOperation(onSuccess, onError, effectiveTimeout);
        op.setTransport(xhr, null);
        xhr.open(_s(method || "GET").toUpperCase(), url, true);
        try { xhr.timeout = effectiveTimeout; } catch(eTimeout) {}
        if (headers && typeof headers === "object") {
            for (var k in headers) {
                if (Object.prototype.hasOwnProperty.call(headers, k)) {
                    try { xhr.setRequestHeader(k, headers[k]); } catch (e) {}
                }
            }
        }
        xhr.onreadystatechange = function () {
            if (!op || !op.isActive()) return;
            try {
                var DONE = (typeof XMLHttpRequest !== "undefined" && XMLHttpRequest && XMLHttpRequest.DONE != null)
                    ? XMLHttpRequest.DONE
                    : 4;
                if (xhr.readyState !== DONE) return;
                var status = xhr.status || 0; var rawTxt = (typeof xhr.responseText === "string") ? xhr.responseText : ""; var raw = (xhr.getAllResponseHeaders && xhr.getAllResponseHeaders()) || ""; var headersObj = _parseRawHeaders(raw);
                if ((status | 0) === 0 && !rawTxt) {
                    op.fail({ code: "network_error", message: "network_error" });
                    return;
                }
                var safe = _makeSafeHttpSuccessPayload(
                    status,
                    rawTxt,
                    headersObj,
                    function() { return _parseJsonBounded(rawTxt); },
                    _shouldReturnTextForRequest(method, url, headers)
                );
                if (safe.tooLarge) {
                    op.fail({ code: "too_large", message: "too_large" });
                    return;
                }
                op.succeed(safe.payload);
            } catch (e2) {
                op.fail({ code: "network_error", message: "network_error" });
            }
        };
        xhr.onerror = function () {
            if (op) op.fail({ code: "network_error", message: "network_error" });
        };
        xhr.ontimeout = function () {
            if (op) op.fail({ code: "timeout", message: "timeout" });
        };
        var payload = (body == null)
            ? null
            : (typeof body === "string" ? body : JSON.stringify(body));
        xhr.send(payload);
        return op;
    } catch (e3) {
        if (op) {
            op.fail({ code: "network_error", message: "network_error" });
            return op;
        }
        if (onError) onError({ code: "network_error", message: "network_error" });
        return _completedHttpHandle();
    }
}
function _doHttp(method, url, headers, body, onSuccess, onError, timeoutMs) { if (_rejectInsecureTransport(url, headers, body, onError)) { return _completedHttpHandle(); }
    var effectiveTimeout = Math.max(100, Number(timeoutMs || DEFAULT_NATIVE_TIMEOUT_MS)); var tx = null; var txOp = null;
    try {
        if (_fbx && _fbx.web && _fbx.web.http && _fbx.web.http.transaction && _fbx.web.http.transaction.factory) {
            tx = _fbx.web.http.transaction.factory(_s(method || "GET").toUpperCase(), url);
            if (headers) {
                for (var hk in headers) {
                    if (Object.prototype.hasOwnProperty.call(headers, hk)) {
                        try { tx.setHeader(hk, headers[hk]); } catch (eh) {}
                    }
                }
            }
            if (body !== undefined && body !== null) {
                try { tx.setBody(typeof body === "string" ? body : JSON.stringify(body)); } catch (eb) {}
            }
            var txPromise = tx.send();
            if (!txPromise || typeof txPromise.then !== "function")
                throw new Error("invalid_fbx_transaction_promise");
            txOp = _newHttpOperation(onSuccess, onError, effectiveTimeout);
            txOp.setTransport(tx, txPromise);
            txPromise.then(function (resp) {
                if (!txOp.isActive()) return;
                var status = resp.status || 0; var rawTxt = resp.responseText || resp.body || "";
                var safe = _makeSafeHttpSuccessPayload(
                    status,
                    rawTxt,
                    resp.headers || {},
                    function() { return resp.jsonParse ? resp.jsonParse() : _parseJsonBounded(rawTxt); },
                    _shouldReturnTextForRequest(method, url, headers)
                );
                if (safe.tooLarge) {
                    txOp.fail({ code: "too_large", message: "too_large" });
                    return;
                }
                txOp.succeed(safe.payload);
            }, function (err) {
                txOp.fail({
                    code: "network_error",
                    message: "network_error"
                });
            });
            return txOp;
        }
    } catch (e0) {
        if (txOp) txOp.cancel("transport_error", false);
        _tryAbortTransport(tx);
    }
    var req = null; var reqOp = null;
    try {
        if (typeof Http !== "undefined" && Http && Http.Transaction && Http.Transaction.factory) {
            req = Http.Transaction.factory({
                method: _s(method || "GET").toUpperCase(),
                url: url,
                headers: headers || {},
                body: (typeof body === "string") ? body : (body ? JSON.stringify(body) : undefined)
            });
            var reqPromise = req.send();
            if (!reqPromise || typeof reqPromise.then !== "function")
                throw new Error("invalid_http_transaction_promise");
            reqOp = _newHttpOperation(onSuccess, onError, effectiveTimeout);
            reqOp.setTransport(req, reqPromise);
            reqPromise.then(function (res) {
                if (!reqOp.isActive()) return;
                var status2 = res.status || 0; var rawTxt2 = res.responseText || res.body || "";
                var safe2 = _makeSafeHttpSuccessPayload(
                    status2,
                    rawTxt2,
                    res.headers || {},
                    function() { return res.jsonParse ? res.jsonParse() : _parseJsonBounded(rawTxt2); },
                    _shouldReturnTextForRequest(method, url, headers)
                );
                if (safe2.tooLarge) {
                    reqOp.fail({ code: "too_large", message: "too_large" });
                    return;
                }
                reqOp.succeed(safe2.payload);
            }, function (err2) {
                reqOp.fail({
                    code: "network_error",
                    message: "network_error"
                });
            });
            return reqOp;
        }
    } catch (e2) {
        if (reqOp) reqOp.cancel("transport_error", false);
        _tryAbortTransport(req);
    }
    return _xhrSend(method, url, headers, body, onSuccess, onError, effectiveTimeout);
}
function _computeAltHost() {
    try { return _s(ClientId.ipv4AltHost()); }
    catch(e0) { return ""; }
}
function _probeHeaderValue(headers, name) {
    headers = headers || {};
    var wanted = _s(name).toLowerCase();
    for (var k in headers) {
        if (!Object.prototype.hasOwnProperty.call(headers, k)) continue;
        if (_s(k).toLowerCase() === wanted) return _s(headers[k]);
    }
    return "";
}
function _probeMetadataXhr(url, headers, onSuccess, onError, timeoutMs) {
    if (_rejectInsecureTransport(url, headers, null, onError)) return null;
    var xhr = null; var finished = false;
    function fail(code) {
        if (finished) return;
        finished = true;
        try { if (xhr && xhr.abort) xhr.abort(); } catch(e0) {}
        if (onError) onError({ code: code || "network_error", message: code || "network_error" });
    }
    function finish(status, contentType) {
        if (finished) return;
        finished = true;
        var ok = status >= 200 && status < 300;
        try { if (xhr && xhr.abort) xhr.abort(); } catch(e0) {}
        if (ok) {
            if (onSuccess) onSuccess({ status: status | 0, contentType: _s(contentType).toLowerCase() });
        } else if (onError) {
            onError(_safeHttpErrorPayload(status | 0));
        }
    }
    try {
        xhr = new XMLHttpRequest();
        xhr.open("GET", stripAuthQueryFromUrl(url), true);
        try { xhr.timeout = Math.max(1000, Math.min(15000, Number(timeoutMs || 8000))); } catch(eTimeout) {}
        for (var k in headers) {
            if (!Object.prototype.hasOwnProperty.call(headers, k)) continue;
            try { xhr.setRequestHeader(k, headers[k]); } catch(eHeader) {}
        }
        // Le corps n'est pas utile : on coupe dès réception des headers.
        try { xhr.setRequestHeader("Range", "bytes=0-0"); } catch(eRange) {}
        xhr.onreadystatechange = function() {
            if (finished || xhr.readyState < 2) return;
            var status = xhr.status || 0; var finalUrl = "";
            try { finalUrl = _s(xhr.responseURL || ""); } catch(eFinal) {}
            if (finalUrl && !_sameHostRedirect(url, finalUrl)) {
                fail("redirect_refused");
                return;
            }
            var contentType = "";
            try { contentType = xhr.getResponseHeader("Content-Type") || ""; } catch(eCt) {}
            if (status > 0 && (contentType || xhr.readyState === 4))
                finish(status, contentType);
            else if (xhr.readyState === 4)
                fail("network_error");
        };
        xhr.onerror = function() { fail("network_error"); };
        xhr.ontimeout = function() { fail("timeout"); };
        xhr.send(null);
        return xhr;
    } catch(e) {
        fail("network_error");
        return null;
    }
}
/*
 * Probe léger pour les images/logos/avatars.
 * - existence: passe par sendRequest et ses redirections same-origin/limites.
 * - metadataOnly: lit uniquement les headers puis coupe le transfert.
 */
function probeResource(url, accessToken, options, onSuccess, onError) {
    options = options || {};
    var token = _s(accessToken); var headers = token ? headersWithToken(token) : {};
    if (options.accept) headers["Accept"] = _s(options.accept);
    if (options.metadataOnly === true)
        return _probeMetadataXhr(url, headers, onSuccess, onError, options.timeoutMs);
    sendRequest("get", url, headers, null,
        function(res) {
            if (onSuccess) {
                onSuccess({
                    status: res && res.status ? (res.status | 0) : 200,
                    contentType: _probeHeaderValue(res && res.headers, "content-type").toLowerCase()
                });
            }
        },
        function(err) {
            if (onError) onError(err || { code: "network_error", message: "network_error" });
        }
    );
    return null;
}
function sendRequestNoCache(method, url, headers, body, onSuccess, onError) {
    return sendRequest(method, url, headers, body, onSuccess, onError,
                       { redirects: 0, usedAlt: false, cacheBypass: true });
}
function sendRequestWithDeadline(method, url, headers, body, onSuccess, onError, deadlineAt) {
    var deadline = Number(deadlineAt || 0);
    return sendRequest(method, url, headers, body, onSuccess, onError,
                       { redirects: 0, usedAlt: false, cacheBypass: true,
                         deadlineAt: isFinite(deadline) && deadline > 0 ? deadline : 0 });
}

// Primitives Search : SearchPage conserve ses quotas/orchestration, tandis que
// le bridge reste l'unique propriétaire des routes HTTP, headers et parsing JSON.
function searchHintsUrl(serverUrl, queryString) {
    queryString = _s(queryString);
    return _u(serverUrl, "/Search/Hints" + (queryString ? ("?" + queryString) : ""));
}
function searchItemsUrl(serverUrl, userId, queryString) {
    queryString = _s(queryString);
    var q = "UserId=" + enc(userId);
    if (queryString) q += "&" + queryString;
    return _u(serverUrl, "/Items?" + q);
}
function fetchSearchJsonUrl(url, accessToken, deadlineAt, onSuccess, onError) {
    return sendRequestWithDeadline(
        "get", url, headersWithToken(accessToken), null,
        function(res) {
            var payload = jsonNormalize(res && res.json);
            if (!payload) {
                if (onError) onError({
                    code: "parse_error",
                    status: (res && res.status) || 0
                });
                return;
            }
            if (onSuccess) onSuccess(payload, res);
        },
        function(err) { if (onError) onError(err); },
        deadlineAt
    );
}
function _newRequestController() {
    return {
        cancelled: false,
        done: false,
        transport: null,
        _setTransport: function(handle) {
            if (this.done || this.cancelled) {
                try { if (handle && typeof handle.cancel === "function") handle.cancel("cancelled", false); } catch(e0) {}
                return;
            }
            this.transport = handle || null;
        },
        _finish: function() {
            this.done = true;
            this.transport = null;
        },
        isActive: function() { return !this.done && !this.cancelled; },
        cancel: function(reason, notifyError) {
            if (this.done || this.cancelled) return false;
            this.cancelled = true;
            var handle = this.transport;
            try {
                if (handle && typeof handle.cancel === "function")
                    handle.cancel(reason || "cancelled", notifyError);
            } catch(e0) {}
            return true;
        }
    };
}
function sendRequest(method, url, headers, body, onSuccess, onError, _state) { // L'authentification ReDeFin passe exclusivement par les headers. Toute copie
    // de token dans la query est supprimée avant cache, redirection ou transport.
    url = stripAuthQueryFromUrl(url);
    if (_rejectInsecureTransport(url, headers, body, onError)) { return _completedHttpHandle(); }
    var __methodUpper = _s(method || "GET").toUpperCase(); var __url = _s(url);
    if (!_state && _isMemoizableApiGet(__methodUpper, __url, body)) {
        var __cacheEpoch = _apiCacheEpoch; var __authScope = _apiAuthContextFingerprint(__url, headers); var __key = _apiGetCacheKey(__methodUpper, __url, headers); var __now = _nowMsBridge();
        _apiPurgeExpiredMaps(__now, false);
        var __latestParentId = _apiLatestParentIdFromUrl(__url); var __userItemId = _apiUserItemIdFromUrl(__url); var __latestParentKey = __latestParentId
                ? (__authScope + "#p" + _apiCacheFingerprint(__latestParentId))
                : "";
        var __parentFailUntil = __latestParentKey ? (_apiLatestParentFailUntil[__latestParentKey] || 0) : 0;
        if (__parentFailUntil > __now) {
            _laterBridge(function() {
                if (onError) onError({ code: "http_500", message: "latest_parent_cooldown", parentId: __latestParentId });
            });
            return _completedHttpHandle();
        }
        var __failUntil = _apiGetFailUntil[__key] || 0;
        if (__failUntil > __now) {
            _laterBridge(function() {
                if (onError) onError({ code: "http_500", message: "cooldown", parentId: __latestParentId });
            });
            return _completedHttpHandle();
        }
        var __ttl = _apiGetTtlMs(__url); var __cached = _apiGetCache[__key];
        if (__cached && __ttl > 0 && (__now - (__cached.ts || 0)) < __ttl) {
            _laterBridge(function() {
                if (onSuccess) onSuccess(__cached.res);
            });
            return _completedHttpHandle();
        }
        var __existingEntry = _apiGetInflight[__key];
        if (__existingEntry && !_isArray(__existingEntry))
            return _apiAddInflightWaiter(__key, __existingEntry, onSuccess, onError);
        // Chaque consommateur, y compris le premier, reçoit son propre handle.
        // Annuler une page ne laisse donc plus une entrée coalescée orpheline.
        var __entry = { waiters: [], leader: null, done: false, epoch: __cacheEpoch };
        _apiGetInflight[__key] = __entry;
        var __subscriberHandle = _apiAddInflightWaiter(__key, __entry, onSuccess, onError);
        __entry.leader = sendRequest(__methodUpper, __url, headers, body,
            function(res) {
                // Une réponse appartenant à une ancienne session ne doit jamais
                // réhydrater le cache du nouveau profil.
                if (__cacheEpoch !== _apiCacheEpoch) return;
                if (__latestParentKey)
                    delete _apiLatestParentFailUntil[__latestParentKey];
                if (__ttl > 0) {
                    var storedAt = _nowMsBridge();
                    _apiGetCache[__key] = { ts: storedAt, expiresAt: storedAt + __ttl,
                                            latestParentId: __latestParentId || "",
                                            userItemId: __userItemId || "", res: res };
                    _apiGetTrimCache();
                }
                _apiGetFlush(__key, __entry, true, res);
            },
            function(err) {
                if (__cacheEpoch !== _apiCacheEpoch) return;
                var cd = _apiGetFailCooldownMs(__url, err);
                if (cd > 0) {
                    var until = _nowMsBridge() + cd;
                    _apiGetFailUntil[__key] = until;
                    if (__latestParentKey)
                        _apiLatestParentFailUntil[__latestParentKey] = until;
                }
                _apiGetFlush(__key, __entry, false, err);
            },
            { redirects: 0, usedAlt: false, cacheBypass: true }
        );
        return __subscriberHandle;
    }
    _state = _state || { redirects: 0, usedAlt: false };
    if (!_state.controller) _state.controller = _newRequestController();
    var controller = _state.controller;
    if (!controller.isActive()) return controller;
    var requestTimeoutMs = DEFAULT_NATIVE_TIMEOUT_MS;
    if (_state.deadlineAt) {
        requestTimeoutMs = Number(_state.deadlineAt) - _nowMsBridge();
        if (!isFinite(requestTimeoutMs) || requestTimeoutMs <= 0) {
            controller._finish();
            if (onError) onError({ code: "timeout", message: "paged_budget_exhausted", status: 0 });
            return controller;
        }
    }
    var transportHandle = _doHttp(method, url, headers, body, function (res) {
        if (!controller.isActive()) return;
        var s = (res.status | 0); if ((s === 301 || s === 302 || s === 307 || s === 308) && _state.redirects < 4) {
            var loc = (res.headers && (res.headers.Location || res.headers.location)) || "";
            loc = _s(loc);
            if (loc) {
                var resolved = _resolveRedirect(url, loc);
                if (!_sameHostRedirect(url, resolved)) {
                    controller._finish();
                    if (onError) onError(_safeHttpErrorPayload(s));
                    return;
                }
                _state.redirects++;
                sendRequest(method, resolved, headers, body, onSuccess, onError, _state);
                return;
            }
        }
        controller._finish();
        if (s >= 200 && s < 300) {
            if (onSuccess) onSuccess(res);
            return;
        }
        if (onError) onError(_safeHttpErrorPayload(s));
    }, function (err) {
        if (controller.cancelled) {
            controller._finish();
            return;
        }
        var altHost = _computeAltHost();
        if (!_state.disableAlt && altHost && !_state.usedAlt) {
            _state.usedAlt = true;
            var alt = _safeAltUrlForAuth(url, altHost);
            if (alt) {
                sendRequest(method, alt, headers, body, onSuccess, onError, _state);
                return;
            }
        }
        controller._finish();
        if (onError) onError(err);
    }, requestTimeoutMs);
    controller._setTransport(transportHandle);
    return controller;
}
function pingServer(serverUrl, onSuccess, onError) {
    var url = _u(serverUrl, "/System/Info/Public");
    sendRequest("get", url, { "Accept": "application/json" }, null, function (res) {
        if (res.status >= 200 && res.status < 300)
            onSuccess(jsonNormalize(res.json));
        else
            onError({ code: "http_" + res.status, message: "Ping HTTP " + res.status });
    }, function (err) {
        onError(err);
    });
}
// Configuration visuelle publique du serveur. Les pages restent responsables
// de la présentation du texte, le bridge possède uniquement transport et parsing.
function fetchBrandingConfiguration(serverUrl, onSuccess, onError) {
    var base = normalizeServerUrl(serverUrl, false);
    if (!base) {
        if (onError) onError({ code: "invalid_url", message: "invalid_url", status: 0 });
        return _completedHttpHandle();
    }
    return sendRequest("get", _u(base, "/Branding/Configuration"),
        { "Accept": "application/json" }, null,
        function(res) {
            var cfg = jsonNormalize(res && res.json) || {};
            if ((!cfg || typeof cfg !== "object" ||
                    (cfg.LoginDisclaimer === undefined && cfg.loginDisclaimer === undefined)) &&
                    res && typeof res === "object") {
                cfg = res;
            }
            if (onSuccess) onSuccess(cfg, res);
        },
        function(err) { if (onError) onError(err); });
}
// Probe public Jellyfin sans authentification. Utilisé par la saisie manuelle
// et par la découverte LAN afin de conserver un seul transport/cancellation path.
function probePublicServer(serverUrl, timeoutMs, onSuccess, onError) {
    var base = normalizeServerUrl(serverUrl, false);
    if (!base) {
        if (onError) onError({ code: "invalid_url", message: "invalid_url", status: 0 });
        return _completedHttpHandle();
    }
    var startedAt = _nowMsBridge();
    var timeout = Math.max(250, Number(timeoutMs || 1500));
    var state = {
        redirects: 0,
        usedAlt: false,
        disableAlt: true,
        cacheBypass: true,
        deadlineAt: startedAt + timeout
    };
    return sendRequest("get", _u(base, "/System/Info/Public"), { "Accept": "application/json" }, null,
        function(res) {
            var info = jsonNormalize(res && res.json);
            if (!isValidPublicSystemInfo(info)) {
                if (onError) onError({ code: "invalid_response", message: "invalid_response", status: res && res.status ? (res.status | 0) : 0 });
                return;
            }
            try { trustLanHost(base); } catch(e0) {}
            if (onSuccess) onSuccess(info, Math.max(0, _nowMsBridge() - startedAt));
        },
        function(err) {
            if (onError) onError(err || { code: "network_error", message: "network_error", status: 0 });
        }, state);
}
function _discoveryCleanHost(raw) {
    var h = _s(raw).trim();
    if (!h) return "";
    h = h.replace(/\\/g, "/");
    var scheme = h.indexOf("://");
    if (scheme >= 0) h = h.substring(scheme + 3);
    var cut = h.search(/[\/?#]/);
    if (cut >= 0) h = h.substring(0, cut);
    if (!h || h.indexOf("@") >= 0) return "";
    if (h.charAt(0) === "[") {
        var rb = h.indexOf("]");
        return rb > 1 ? h.substring(0, rb + 1) : "";
    }
    var firstColon = h.indexOf(":"), lastColon = h.lastIndexOf(":");
    if (firstColon > 0 && firstColon === lastColon && /^\d+$/.test(h.substring(firstColon + 1)))
        h = h.substring(0, firstColon);
    else if (firstColon >= 0 && firstColon !== lastColon)
        h = "[" + h.replace(/^\[|\]$/g, "") + "]";
    return h;
}
function _discoveryIpv4(raw) {
    var s = _s(raw).trim(), m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s);
    if (!m) return "";
    for (var i = 1; i <= 4; i++)
        if ((Number(m[i]) | 0) < 0 || (Number(m[i]) | 0) > 255) return "";
    return s;
}
function _discoveryPushHost(out, seen, raw, maxHosts) {
    if (out.length >= maxHosts) return false;
    var h = _discoveryCleanHost(raw), key = h.toLowerCase();
    if (!h || seen[key]) return false;
    seen[key] = true; out.push(h); return true;
}
function _discoveryLanHosts(fbxCtx, maxHosts) {
    var ranked = [], byKey = {};
    function rankHost(raw, score) {
        var h = _discoveryCleanHost(raw), key = h.toLowerCase();
        if (!h) return;
        if (byKey[key]) {
            if (score > byKey[key].score) byKey[key].score = score;
            return;
        }
        var rec = { host: h, score: score || 0 };
        byKey[key] = rec; ranked.push(rec);
    }
    try {
        if (fbxCtx && fbxCtx.lan && typeof fbxCtx.lan.hosts === "function") {
            var arr = fbxCtx.lan.hosts() || [];
            for (var i = 0; i < arr.length; i++) {
                var it = arr[i] || {};
                var hostScore = (it.active === true ? 420 : 0) +
                                (it.reachable === true ? 360 : 0);
                var l3 = it.l3connectivities || it.l3Connectivities || [];
                if (_isArray(l3)) {
                    for (var j = 0; j < l3.length; j++) {
                        var c = l3[j] || {}, addr = _discoveryIpv4(c.addr || c.address || "");
                        if (!addr) continue;
                        var score = hostScore +
                                    (c.active === true ? 700 : 0) +
                                    (c.reachable === true ? 620 : 0);
                        var last = Number(c.last_activity || c.lastActivity || c.last_time_reachable || 0);
                        if (isFinite(last) && last > 0) score += Math.min(80, Math.floor(last / 100000000));
                        rankHost(addr, score);
                    }
                }
                rankHost(it.ip || it.address || it.host || it.hostname || it.name || "", hostScore + 40);
            }
        }
    } catch(e0) {}
    ranked.sort(function(a, b) { return b.score - a.score; });
    var out = [];
    for (var k = 0; k < ranked.length && out.length < maxHosts; k++)
        out.push(ranked[k].host);
    return out;
}
function _discoveryFallbackHosts(maxHosts, hints) {
    var out = [], seen = {}, prefixes = [], prefixSeen = {};
    function addPrefix(ip) {
        ip = _discoveryIpv4(ip);
        if (!ip) return;
        var p = ip.split(".").slice(0, 3).join(".") + ".";
        if (!prefixSeen[p]) { prefixSeen[p] = true; prefixes.push(p); }
    }
    hints = hints || [];
    for (var i = 0; i < hints.length; i++) addPrefix(_discoveryCleanHost(hints[i]));
    if (!prefixes.length) {
        prefixes.push("192.168.1."); prefixes.push("192.168.0."); prefixes.push("10.0.0.");
    }
    // /24 : .0 = réseau, .255 = broadcast. ReDeFin réserve .1 à la
    // passerelle et balaie donc les 253 candidats .2 -> .254 dans l'ordre.
    for (var p = 0; p < prefixes.length && out.length < maxHosts; p++) {
        for (var n = 2; n <= 254 && out.length < maxHosts; n++)
            _discoveryPushHost(out, seen, prefixes[p] + n, maxHosts);
    }
    return out;
}
function _discoveryBaseParts(base) {
    var m = /^(https?):\/\/(\[[^\]]+\]|[^\/:?#]+)(?::(\d+))?/i.exec(_s(base));
    if (!m) return { host:"", port:0 };
    return {
        host: _s(m[2]).replace(/^\[|\]$/g, ""),
        port: m[3] ? (Number(m[3]) | 0) : (_s(m[1]).toLowerCase() === "https" ? 443 : 80)
    };
}
// Découverte Jellyfin optimisée Révolution :
// 1) IP réellement vues par la Freebox, actives/reachable en tête ;
// 2) phase HTTP 8096 complète avant tout HTTPS 8920 ;
// 3) HTTPS seulement pour les hôtes où HTTP n'a pas déjà trouvé Jellyfin ;
// 4) fallback /24 exhaustif de .2 à .254 en HTTP puis en HTTPS pour les hôtes
//    qui n'ont pas déjà fourni un Jellyfin ; aucun arrêt au premier serveur ;
// 5) aucun hôte n'est reprobé entre phase initiale et fallback.
// Aucun Timer/probe supplémentaire n'est créé : maxParallel reste le garde-fou CPU/RAM.
function discoverServers(options, onUpdate, onDone) {
    options = options || {};
    var maxHosts = Math.max(1, Math.min(256, Number(options.maxHosts || 96) | 0));
    var maxParallel = Math.max(1, Math.min(4, Number(options.maxParallel || 2) | 0));
    var httpTimeout = Math.max(250, Number(options.httpTimeoutMs || 700));
    var httpsTimeout = Math.max(350, Number(options.httpsTimeoutMs || 1600));
    var fallbackEnabled = options.fallbackSubnetScan !== false;
    var fallbackMaxHosts = Math.max(1, Math.min(maxHosts, Number(options.fallbackMaxHosts || maxHosts) | 0));
    var stopOnFirst = options.stopOnFirstFound === true;
    var fbxCtx = options.fbx || _fbx || null;
    var localNames = options.localNames && options.localNames.length
            ? options.localNames : ["jellyfin.local", "jellyfin", "media", "nas", "synology"];
    var results = [], seenServers = {}, seenServerIds = {}, foundHosts = {}, activeHandles = [], probedHttpHosts = {}, probedHttpsHosts = {};
    var controller = {
        cancelled: false, done: false,
        cancel: function(reason) {
            if (this.cancelled || this.done) return false;
            this.cancelled = true;
            var list = activeHandles.slice(0); activeHandles = [];
            for (var i = 0; i < list.length; i++) {
                try { if (list[i] && typeof list[i].cancel === "function") list[i].cancel(reason || "cancelled"); } catch(e0) {}
            }
            return true;
        },
        isActive: function() { return !this.cancelled && !this.done; }
    };
    function snapshot() { return results.slice(0); }
    function dropHandle(handle) {
        if (!handle) return;
        for (var i = activeHandles.length - 1; i >= 0; i--)
            if (activeHandles[i] === handle) { activeHandles.splice(i, 1); break; }
    }
    function finish() {
        if (controller.cancelled || controller.done) return;
        controller.done = true; activeHandles = [];
        if (onDone) onDone(snapshot());
    }
    function addServer(info, base, ping) {
        if (controller.cancelled || !isValidPublicSystemInfo(info)) return false;
        var normalized = _normalizeBase(base), key = normalized.toLowerCase();
        var id = _s(info.Id || info.ServerId || "").toLowerCase();
        if (!key || seenServers[key] || (id && seenServerIds[id])) return false;
        seenServers[key] = true; if (id) seenServerIds[id] = true;
        var parts = _discoveryBaseParts(normalized), hostKey = _discoveryCleanHost(parts.host).toLowerCase();
        if (hostKey) foundHosts[hostKey] = true;
        var rec = {
            name: info.ServerName || info.ProductName || "Jellyfin",
            url: normalized,
            pingMs: Math.max(0, Number(ping || 0) | 0),
            version: _s(info.Version || ""),
            id: _s(info.Id || info.ServerId || ""),
            host: parts.host,
            port: parts.port
        };
        results.push(rec);
        try { trustLanHost(normalized); } catch(e0) {}
        if (onUpdate) onUpdate(snapshot(), rec);
        return true;
    }
    function runPhase(hosts, scheme, port, timeout, skipFound, done) {
        hosts = hosts || [];
        if (!hosts.length || controller.cancelled || (stopOnFirst && results.length)) { done(); return; }
        var cursor = 0, inFlight = 0, ended = false, phaseSeen = {};
        function complete() { if (!ended) { ended = true; done(); } }
        function pump() {
            if (ended || controller.cancelled) return;
            if ((stopOnFirst && results.length) || (cursor >= hosts.length && inFlight === 0)) {
                if (inFlight === 0) complete();
                return;
            }
            while (inFlight < maxParallel && cursor < hosts.length && !(stopOnFirst && results.length)) {
                var host = _discoveryCleanHost(hosts[cursor++]), hk = host.toLowerCase();
                var probedMap = (scheme === "https") ? probedHttpsHosts : probedHttpHosts;
                if (!host || phaseSeen[hk] || probedMap[hk] || (skipFound && foundHosts[hk])) continue;
                phaseSeen[hk] = true;
                probedMap[hk] = true;
                inFlight++;
                (function(hostValue) {
                    var base = scheme + "://" + hostValue + ":" + port, handle = null;
                    function doneOne() { inFlight = Math.max(0, inFlight - 1); pump(); }
                    handle = probePublicServer(base, timeout,
                        function(info, ping) {
                            dropHandle(handle);
                            if (!controller.cancelled) addServer(info, base, ping);
                            doneOne();
                        },
                        function() {
                            dropHandle(handle);
                            if (!controller.cancelled) doneOne();
                        });
                    activeHandles.push(handle);
                })(host);
            }
            if (cursor >= hosts.length && inFlight === 0) complete();
        }
        pump();
    }
    var lan = _discoveryLanHosts(fbxCtx, maxHosts), initial = [], seen = {};
    for (var i = 0; i < lan.length && initial.length < maxHosts; i++)
        _discoveryPushHost(initial, seen, lan[i], maxHosts);
    for (var j = 0; j < localNames.length && initial.length < maxHosts; j++)
        _discoveryPushHost(initial, seen, localNames[j], maxHosts);

    runPhase(initial, "http", 8096, httpTimeout, false, function() {
        if (controller.cancelled) return;
        if (stopOnFirst && results.length) { finish(); return; }
        runPhase(initial, "https", 8920, httpsTimeout, true, function() {
            if (controller.cancelled) return;
            if (stopOnFirst && results.length) { finish(); return; }
            if (!fallbackEnabled) { finish(); return; }

            // Le fallback HTTP du sous-réseau est volontairement exécuté même si
            // un serveur a déjà été trouvé dans la table LAN Freebox. Cela évite
            // qu'un second Jellyfin absent/inactif dans fbx.lan.hosts() soit ignoré.
            // Les maps probedHttpHosts/probedHttpsHosts empêchent de retester les
            // mêmes hôtes lorsqu'ils réapparaissent dans cette phase.
            var fallback = _discoveryFallbackHosts(fallbackMaxHosts, lan);
            runPhase(fallback, "http", 8096, httpTimeout, false, function() {
                if (controller.cancelled) return;
                if (stopOnFirst && results.length) { finish(); return; }

                // Deuxième passe exhaustive : un second serveur peut n'écouter
                // qu'en HTTPS 8920. Les hôtes déjà identifiés comme Jellyfin en
                // HTTP sont sautés via foundHosts afin d'éviter un probe inutile.
                runPhase(fallback, "https", 8920, httpsTimeout, true, finish);
            });
        });
    });
    return controller;
}
function authenticate(serverUrl, username, password, onSuccess, onError) {
    serverUrl = _normalizeBase(serverUrl);
    username  = _s(username);
    password  = _s(password);
    if (!serverUrl || !username) {
        if (onError) onError("missing_params");
        return;
    }
    // Le mot de passe est un secret au même titre qu'un token : aucun pré-ping WAN HTTP.
    if (isWanHttpUrl(serverUrl)) {
        if (onError) onError("insecure_transport");
        return;
    }
    pingServer(serverUrl, function () {
        var url = _u(serverUrl, "/Users/AuthenticateByName");
        sendRequest("post", url, headersWithToken(""), {
            Username: username,
            Pw: password
        }, function (res) {
            var j = jsonNormalize(res.json);
            if (j && j.AccessToken)
                onSuccess({ accessToken: j.AccessToken, userId: j.User && j.User.Id, raw: j });
            else if (onError)
                onError("invalid_response");
        }, function (err) {
            if (onError) onError(_errCode(err, "network_error"));
        });
    }, function (e) {
        if (onError) onError(_errCode(e, "network_error"));
    });
}
function validateToken(serverUrl, accessToken, onSuccess, onError) {
    var url = _u(serverUrl, "/Users/Me");
    sendRequest("get", url, headersWithToken(accessToken), null, function (res) {
        var j = jsonNormalize(res.json) || {};
        if (j && (j.Id || j.Name))
            onSuccess && onSuccess(j);
        else
            onError && onError("invalid_token");
    }, function (err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function fetchUser(serverUrl, accessToken, userId, onSuccess, onError) {
    var url = _u(serverUrl, "/Users/" + enc(userId));
    sendRequest("get", url, headersWithToken(accessToken), null, function (res) {
        var j = jsonNormalize(res.json);
        if (j && j.Id) onSuccess(j);
        else onError && onError("bad_response");
    }, function (err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function fetchPublicUsers(serverUrl, onSuccess, onError) {
    var url = _u(serverUrl, "/Users/Public");
    sendRequest("get", url, { "Accept": "application/json" }, null, function (res) {
        var j = jsonNormalize(res.json); var items = [];
        if (j && j.Items && j.Items.length) items = j.Items;
        else if (_isArray(j)) items = j;
        onSuccess && onSuccess(items || []);
    }, function (err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function logout(serverUrl, accessToken, onSuccess, onError) {
    var url = _u(serverUrl, "/Sessions/Logout");
    sendRequest("post", url, headersWithToken(accessToken), {}, function () {
        onSuccess && onSuccess(true);
    }, function (err) {
        if (err && (err.code === "http_401" || err.code === "http_403")) {
            onSuccess && onSuccess(true);
            return;
        }
        onError && onError(_errCode(err, "network_error"));
    });
}
function quickConnectInitiate(serverUrl, onSuccess, onError) {
    var url = _u(serverUrl, "/QuickConnect/Initiate");
    return sendRequest("post", url, headersWithToken(""), {}, function (res) {
        var j = jsonNormalize(res.json) || {}; var secret = j.Secret || j.secret; var code = j.Code || j.code;
        if (secret && code)
            onSuccess && onSuccess(j);
        else
            onError && onError("invalid_response");
    }, function (err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function quickConnectTryAuthenticate(serverUrl, secret, onSuccess, onError) {
    if (!secret) {
        _laterBridge(function() { if (onError) onError("missing_secret"); });
        return _completedHttpHandle();
    }

    // Une invocation = une vraie tentative réseau.
    // Le cadencement et l'anti-chevauchement appartiennent à LoginPage.qml,
    // qui possède le Timer QuickConnect et le cycle de vie de l'overlay.
    //
    // ReDeFin conserve volontairement le POST /Users/AuthenticateWithQuickConnect
    // plutôt qu'un GET /QuickConnect/Connect?Secret=... : le secret reste ainsi
    // dans le corps de la requête et ne peut pas apparaître dans les logs d'URL
    // du Player Freebox.
    var url = _u(serverUrl, "/Users/AuthenticateWithQuickConnect");
    return sendRequest("post", url, headersWithToken(""), { Secret: secret }, function (res) {
        var j = jsonNormalize(res.json) || {};
        if (j && j.AccessToken) {
            if (onSuccess) {
                onSuccess({
                    accessToken: j.AccessToken,
                    userId: j.User && j.User.Id,
                    raw: j
                });
            }
        } else if (onError) {
            onError("invalid_response");
        }
    }, function (err) {
        var code = _errCode(err, "");
        // Tant que le code n'a pas encore été autorisé, Jellyfin peut répondre
        // 401/404. Ce n'est pas une erreur utilisateur : LoginPage repollera.
        if (code === "http_401" || code === "http_404") {
            if (onError) onError("pending");
            return;
        }
        if (onError) onError(code || "network_error");
    });
}
function fetchViews(serverUrl, accessToken, userId, onSuccess, onError) {
    var url = _u(serverUrl, "/UserViews?UserId=" + enc(userId));
    return sendRequest("get", url, headersWithToken(accessToken), null, function (res) {
        var j = jsonNormalize(res.json); var items = (j && j.Items) ? j.Items : (_isArray(j) ? j : null);
        if (items && items.length > 0) onSuccess(items);
        else onError && onError("empty");
    }, function (err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
var _MODERN_ITEM_FIELDS = {
    AirTime:1, CanDelete:1, CanDownload:1, ChannelInfo:1, Chapters:1, Trickplay:1,
    ChildCount:1, CumulativeRunTimeTicks:1, CustomRating:1, DateCreated:1,
    DateLastMediaAdded:1, DisplayPreferencesId:1, Etag:1, ExternalUrls:1,
    Genres:1, ItemCounts:1, MediaSourceCount:1, MediaSources:1, OriginalTitle:1,
    Overview:1, ParentId:1, Path:1, People:1, PlayAccess:1, ProductionLocations:1,
    ProviderIds:1, PrimaryImageAspectRatio:1, RecursiveItemCount:1, Settings:1,
    SeriesStudio:1, SortName:1, SpecialEpisodeNumbers:1, Studios:1, Taglines:1, Tags:1,
    RemoteTrailers:1, MediaStreams:1, SeasonUserData:1, DateLastRefreshed:1,
    DateLastSaved:1, RefreshState:1, ChannelImage:1, EnableMediaSourceDisplay:1,
    Width:1, Height:1, ExtraIds:1, LocalTrailerCount:1, IsHD:1, SpecialFeatureCount:1
};
function _modernItemFields(raw) {
    raw = _s(raw);
    if (!raw) return "";
    var parts = raw.split(","); var out = []; var seen = {};
    for (var i = 0; i < parts.length; i++) {
        var k = _safeTrim(parts[i]);
        if (!k || !_MODERN_ITEM_FIELDS[k] || seen[k]) continue;
        seen[k] = 1;
        out.push(k);
    }
    return out.join(",");
}
function _homeListFields() {
    // Jellyfin actuel : Fields ne contient que les valeurs ItemFields officielles.
    // Les propriétés BaseItemDto (ImageTags, RunTimeTicks, UserData, Type, etc.)
    // sont renvoyées normalement et ne doivent plus être demandées comme ItemFields.
    return _modernItemFields(
        "PrimaryImageAspectRatio,CumulativeRunTimeTicks,CustomRating,ParentId,SortName," +
        "DateCreated,DateLastMediaAdded,DateLastRefreshed,ChildCount,RecursiveItemCount,ItemCounts"
    );
}
function homeMediaFields(extra) {
    var fields = "PrimaryImageAspectRatio,CustomRating";
    extra = _s(extra);
    return _modernItemFields(extra ? (fields + "," + extra) : fields);
}
function homeItemsFromResponse(res) {
    var j = jsonNormalize(res && res.json);
    if (j && j.Items) return j.Items || [];
    if (_isArray(j)) return j;
    return [];
}

// Types réellement lisibles dans "Continuer de regarder".
// Jellyfin 12 RC peut renvoyer des Season/Series dans /UserItems/Resume.
// Le filtre serveur reste la première barrière, celui-ci est volontairement
// conservé comme garde-fou local afin de ne jamais créer de cartes parasites.
function fetchHomeResumeItems(serverUrl, accessToken, userId, limit, onSuccess, onError) {
    if (!serverUrl || !accessToken || !userId) {
        onError && onError("missing_params");
        return;
    }

    var safeLimit = MediaCatalog.homeSectionLimit(limit);

    var url = _u(serverUrl,
        "/UserItems/Resume?UserId=" + enc(userId) +
        "&Limit=" + enc(safeLimit) +
        // Jellyfin 12 RC peut renvoyer Season/Series dans Resume si le type
        // n'est pas borné explicitement. ReDeFin ne veut ici que des médias
        // effectivement lisibles et reprenables.
        "&MediaTypes=Video" +
        "&IncludeItemTypes=Movie,Episode,Video,MusicVideo" +
        "&EnableImages=true" +
        "&EnableUserData=true" +
        "&EnableTotalRecordCount=false" +
        // ParentId permet à Home de rouvrir une vidéo personnelle dans
        // son dossier PersonalMediaPage sans requête supplémentaire au clic.
        "&Fields=" + homeMediaFields("BackdropImageTags,Type,CollectionType,ParentId")
    );

    sendRequest("get", url, headersWithToken(accessToken), null, function(res) {
        var items = homeItemsFromResponse(res);
        // Garde-fou local : ne dépend pas du respect des filtres par le serveur.
        onSuccess && onSuccess(MediaCatalog.filterHomeResumeItems(items, safeLimit));
    }, function(err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function fetchHomeNextUpItems(serverUrl, accessToken, userId, limit, onSuccess, onError, seriesId, enableResumable) {
    if (!serverUrl || !accessToken || !userId) {
        onError && onError("missing_params");
        return _completedHttpHandle();
    }
    var safeLimit = MediaCatalog.homeSectionLimit(limit);
    var path = "/Shows/NextUp?UserId=" + enc(userId) +
        "&Limit=" + enc(safeLimit) +
        "&EnableImages=true&EnableUserData=true&EnableTotalRecordCount=false" +
        "&Fields=" + homeMediaFields("ParentId,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,SeriesPrimaryImageTag");
    if (seriesId) path += "&SeriesId=" + enc(seriesId);
    if (enableResumable === true) path += "&EnableResumable=true";
    var url = _u(serverUrl, path);
    return sendRequest("get", url, headersWithToken(accessToken), null, function(res) {
        onSuccess && onSuccess(homeItemsFromResponse(res));
    }, function(err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function fetchSeasonItemsFromIndex(serverUrl, accessToken, userId, seasonId, startIndex, limit, onSuccess, onError) {
    if (!serverUrl || !accessToken || !userId || !seasonId) {
        onError && onError("missing_params");
        return _completedHttpHandle();
    }

    var safeStart = Math.max(0, Number(startIndex) || 0);
    var safeLimit = Math.max(1, Math.min(200, Number(limit) || 100));
    var url = _u(serverUrl,
        "/Items?UserId=" + enc(userId) +
        "&ParentId=" + enc(seasonId) +
        "&StartIndex=" + enc(safeStart) +
        "&Limit=" + enc(safeLimit) +
        "&IncludeItemTypes=Episode" +
        "&EnableImages=true&EnableUserData=true&EnableTotalRecordCount=false" +
        "&Fields=" + homeMediaFields("ParentId,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,SeriesPrimaryImageTag")
    );

    return sendRequest("get", url, headersWithToken(accessToken), null, function(res) {
        onSuccess && onSuccess(homeItemsFromResponse(res));
    }, function(err) {
        onError && onError(_errCode(err, "network_error"));
    });
}

function fetchSimilarItems(serverUrl, accessToken, userId, itemId, limit, onSuccess, onError) {
    if (!serverUrl || !accessToken || !userId || !itemId) {
        onError && onError("missing_params");
        return _completedHttpHandle();
    }
    var url = _u(serverUrl,
        "/Items/" + enc(itemId) + "/Similar?UserId=" + enc(userId) +
        "&Limit=" + enc(limit || 20) +
        "&Fields=PrimaryImageAspectRatio,CustomRating,ItemCounts,RecursiveItemCount"
    );
    return sendRequest("get", url, headersWithToken(accessToken), null, function(res) {
        var j = jsonNormalize(res && res.json);
        var items = (j && j.Items) ? j.Items : (_isArray(j) ? j : []);
        onSuccess && onSuccess(items || []);
    }, function(err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function fetchHomeLatestItemsForParent(serverUrl, accessToken, userId, parentId, limit,
                                           onSuccess, onError, groupItems) {
    if (!serverUrl || !accessToken || !userId || !parentId) {
        onError && onError("missing_params");
        return _completedHttpHandle();
    }

    var safeLimit = MediaCatalog.homeSectionLimit(limit);
    var shouldGroup = groupItems === true;

    var url = _u(serverUrl,
        "/Items/Latest?UserId=" + enc(userId) +
        "&ParentId=" + enc(parentId) +
        "&Limit=" + enc(safeLimit) +
        // Bibliothèque Séries : on laisse Jellyfin regrouper les épisodes
        // récents sous leur Season. Les autres bibliothèques restent non
        // groupées pour conserver des cartes média individuelles.
        "&GroupItems=" + (shouldGroup ? "true" : "false") +
        "&IncludeItemTypes=Episode,Movie,Video,MusicVideo,Photo" +
        "&EnableImages=true" +
        "&EnableUserData=true" +
        "&Fields=" + homeMediaFields(
            "BackdropImageTags,SeriesPrimaryImageTag,ParentId,Type,CollectionType"
        )
    );

    return sendRequest("get", url, headersWithToken(accessToken), null, function(res) {
        var items = homeItemsFromResponse(res);
        // Si GroupItems=true pour une bibliothèque Séries, Season et Series
        // sont des résultats attendus. Les autres conteneurs restent filtrés.
        onSuccess && onSuccess(MediaCatalog.filterHomeLatestItems(items, safeLimit, shouldGroup));
    }, function(err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function fetchFolderItems(serverUrl, accessToken, userId, folderId, onSuccess, onError) {
    var fields = _folderListFields();
    var url = _u(serverUrl,
        "/Items?UserId=" + enc(userId) +
        "&ParentId=" + enc(folderId) +
        "&EnableTotalRecordCount=false" +
        "&Fields=" + fields
    );
    return sendRequest("get", url, headersWithToken(accessToken), null, function (res) {
        var j = jsonNormalize(res.json); var items = (j && j.Items) ? j.Items : (_isArray(j) ? j : null);
        if (items) onSuccess(items);
        else onError && onError("empty");
    }, function (err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function fetchFolderItemCount(serverUrl, accessToken, userId, folderId, includeItemTypes,
                              recursive, onSuccess, onError) {
    if (!serverUrl || !accessToken || !userId || !folderId) {
        onError && onError("missing_params");
        return _completedHttpHandle();
    }
    var url = _u(serverUrl,
        "/Items?UserId=" + enc(userId) +
        "&ParentId=" + enc(folderId) +
        "&Recursive=" + (recursive === true ? "true" : "false") +
        "&StartIndex=0&Limit=1" +
        "&EnableImages=false&EnableUserData=false&EnableTotalRecordCount=true" +
        (includeItemTypes ? ("&IncludeItemTypes=" + _encItemTypeList(includeItemTypes)) : "")
    );
    return sendRequest("get", url, headersWithToken(accessToken), null, function(res) {
        var j = jsonNormalize(res && res.json);
        if (!j) {
            onError && onError("parse_error");
            return;
        }
        var count = Number(j.TotalRecordCount);
        if (!isFinite(count) || count < 0) {
            var items = j.Items ? j.Items : (_isArray(j) ? j : []);
            count = items ? items.length : 0;
        }
        onSuccess && onSuccess(Math.max(0, Math.floor(count)));
    }, function(err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function _folderListFields(typeName) {
    // Les grilles MoviePage n'ont pas besoin du profil Home complet. Réduire les
    // ItemFields diminue à la fois le travail serveur, la taille JSON et le coût
    // de parsing/copie sur Freebox. Les propriétés BaseItemDto (Name, Type,
    // ImageTags, UserData, RunTimeTicks, etc.) restent renvoyées normalement.
    var types = _s(typeName).toLowerCase();
    if (!types) return _homeListFields();

    // Dossiers, séries et collections utilisent les compteurs dans l'UI.
    if (types.indexOf("folder") >= 0 || types.indexOf("series") >= 0 ||
            types.indexOf("boxset") >= 0) {
        return _modernItemFields(
            "PrimaryImageAspectRatio,CustomRating,ParentId," +
            "ChildCount,RecursiveItemCount,ItemCounts"
        );
    }

    // Médias personnels : dimensions utiles pour les photos/vidéos sans demander
    // les très lourds MediaStreams/MediaSources sur toute la page.
    if (types.indexOf("photo") >= 0) {
        return _modernItemFields(
            "PrimaryImageAspectRatio,CustomRating,ParentId,Width,Height"
        );
    }

    // Films/vidéos : le header enrichit uniquement l'élément focalisé via
    // fetchItem(), donc trois champs suffisent au listing initial.
    return _modernItemFields("PrimaryImageAspectRatio,CustomRating,ParentId");
}

/* ========= Bibliothèques média unifiées : Films / Séries / Mixte ========= */
function _encItemTypeList(typeName) {
    var raw = _s(typeName).split(","); var out = [];
    for (var i = 0; i < raw.length; i++) {
        var t = _s(raw[i]);
        if (t) out.push(enc(t));
    }
    return out.join(",");
}
function _folderServerSortBy(mode) {
    mode = _int(mode);
    if (mode === 1) return "DateCreated";
    if (mode === 2) return "PremiereDate";
    if (mode === 3) return "CommunityRating";
    if (mode === 4) return "DatePlayed";
    if (mode === 5) return "Runtime";
    return "SortName";
}
function _folderServerSortOrder(mode) { return (_int(mode) > 0) ? "Descending" : "Ascending"; }
function _folderSafePageLimit(limit) { limit = _int(limit); return limit < 40 ? 40 : (limit > 600 ? 600 : limit); }
function _folderSafeStartIndex(startIndex) { startIndex = _int(startIndex); return startIndex > 0 ? startIndex : 0; }
function _folderPagePayload(startIndex, limit, rawLen, filteredItems, sortMode,
                            sourceMode, hasMore, errorCode) {
    var safeStart = _folderSafeStartIndex(startIndex);
    return {
        items: filteredItems || [],
        startIndex: safeStart,
        nextStartIndex: safeStart + Math.max(0, rawLen | 0),
        limit: _folderSafePageLimit(limit),
        hasMore: hasMore === true,
        sortMode: _int(sortMode),
        sourceMode: sourceMode || "primary",
        error: errorCode || ""
    };
}
function _fetchFolderItemsByTypePage(serverUrl, accessToken, userId, folderId, typeName, recursive, startIndex, limit, sortMode, onSuccess, onError, _controller, _finishController) {
    var controller = _controller || createPagedRequestController(); var finishController = (_finishController !== false);
    if (!serverUrl || !accessToken || !userId || !folderId || !typeName) {
        if (finishController) controller._finish();
        onError && onError("missing_params");
        return controller;
    }
    startIndex = _folderSafeStartIndex(startIndex); limit = _folderSafePageLimit(limit); sortMode = _int(sortMode);
    var chunk = Math.min(80, limit), minChunk = 20, consumed = 0, out = [], seen = {};
    var scopeRecursive = recursive !== false;
    function makeUrl(localStart, pageLimit) {
        var query = "/Items?UserId=" + enc(userId) +
                    "&ParentId=" + enc(folderId) +
                    "&Recursive=" + (scopeRecursive ? "true" : "false");
        query += "&IncludeItemTypes=" + _encItemTypeList(typeName) +
                 "&EnableTotalRecordCount=false&SortBy=" + enc(_folderServerSortBy(sortMode)) +
                 "&SortOrder=" + enc(_folderServerSortOrder(sortMode)) +
                 "&StartIndex=" + localStart + "&Limit=" + pageLimit +
                 "&Fields=" + _folderListFields(typeName);
        return _u(serverUrl, query);
    }
    function finish(more, partialCode) {
        if (!controller.isActive()) return;
        var page = _folderPagePayload(startIndex, limit, consumed, out, sortMode,
                                      scopeRecursive ? "recursive-parent" : "direct-parent",
                                      more, partialCode || "");
        if (partialCode) {
            page.partial = true;
            page.hasMore = true;
        }
        if (finishController) controller._finish();
        onSuccess && onSuccess(page);
    }
    function fail(code) {
        if (!controller.isActive()) return;
        code = _errCode(code, "network_error");
        if ((code === "timeout" || code === "budget_exhausted") && out.length > 0) {
            finish(true, "budget_exhausted");
            return;
        }
        if (finishController) controller._finish();
        onError && onError(code === "timeout" ? "budget_exhausted" : code);
    }
    function next() {
        if (!controller.isActive()) return;
        if (controller.expired()) { fail("budget_exhausted"); return; }
        if (out.length >= limit) { finish(true); return; }
        var want = Math.max(1, Math.min(chunk, limit - out.length)); var requestHandle = null;
        requestHandle = sendRequestWithDeadline("get", makeUrl(startIndex + consumed, want), headersWithToken(accessToken), null, function(res) {
            controller._clearTransport(requestHandle);
            if (!controller.isActive()) return;
            var items = _folderItemsFromResponse(res);
            if (!items) { fail("empty"); return; }
            consumed += items.length;
            _folderAppendTypedUnique(out, seen, items || [], typeName);
            if (items.length < want) { finish(false); return; }
            _laterBridge(next);
        }, function(err) {
            controller._clearTransport(requestHandle);
            if (!controller.isActive()) return;
            var code = _errCode(err, "network_error");
            if (code === "too_large" && chunk > minChunk) { chunk = Math.max(minChunk, Math.floor(chunk / 2)); _laterBridge(next); return; }
            fail(code);
        }, controller.deadlineAt);
        controller._setTransport(requestHandle);
    }
    next();
    return controller;
}
function _fetchFolderItemsByTypePageWithDirectFallback(serverUrl, accessToken, userId, folderId, typeName, recursive, startIndex, limit, sortMode, onSuccess, onError) {
    var controller = createPagedRequestController();
    function complete(page) {
        if (!controller.isActive()) return;
        controller._finish();
        onSuccess && onSuccess(page);
    }
    function failFinal(err) {
        if (!controller.isActive()) return;
        controller._finish();
        onError && onError(_errCode(err, "network_error"));
    }
    function accept(page, fallback) {
        if (!controller.isActive()) return;
        if (page && ((page.items && page.items.length > 0) || page.hasMore)) { complete(page); return; }
        fallback();
    }
    function finishDirect(errForFinal) {
        if (!controller.isActive()) return;
        if (controller.expired()) { failFinal("budget_exhausted"); return; }
        _fetchFolderItemsByTypePage(serverUrl, accessToken, userId, folderId, typeName, false, startIndex, limit, sortMode,
            function(page2) {
                if (page2) page2.sourceMode = "direct-parent";
                complete(page2 || _folderPagePayload(startIndex, limit, 0, [], sortMode, "direct-parent", false));
            },
            function(err2) {
                if (errForFinal) failFinal(errForFinal || err2);
                else complete(_folderPagePayload(startIndex, limit, 0, [], sortMode, "direct-parent", false));
            }, controller, false);
    }
    _fetchFolderItemsByTypePage(serverUrl, accessToken, userId, folderId, typeName, recursive, startIndex, limit, sortMode,
        function(page) { accept(page, function() { finishDirect(null); }); },
        function(err) { finishDirect(err); }, controller, false);
    return controller;
}
function fetchMovieFolderItemsPage(serverUrl, accessToken, userId, folderId,
                                   startIndex, limit, sortMode, onSuccess, onError) {
    return _fetchFolderItemsByTypePageWithDirectFallback(
        serverUrl, accessToken, userId, folderId,
        "Movie,Video,MusicVideo", true,
        startIndex, limit, sortMode, onSuccess, onError
    );
}
var _PM_MEDIA_TYPES = "Photo,Video,Movie,MusicVideo";
function fetchPersonalMediaFolderItemsPage(serverUrl, accessToken, userId, folderId,
                                           startIndex, limit, sortMode,
                                           onSuccess, onError) {
    return _fetchFolderItemsByTypePage(
        serverUrl, accessToken, userId, folderId, _PM_MEDIA_TYPES, false,
        startIndex, limit, sortMode,
        function(page) {
            if (page) page.sourceMode = "personal-direct";
            if (onSuccess) onSuccess(page);
        },
        onError
    );
}
// CollectionType=mixed : films + séries uniquement. Folder reste autorisé afin
// de pouvoir descendre dans un éventuel sous-dossier sans aplatir toute la
// bibliothèque. Video/MusicVideo/Episode/Season sont exclus de ce mode.
function fetchMixedFolderItemsPage(serverUrl, accessToken, userId, folderId, startIndex, limit, sortMode, onSuccess, onError) {
    return _fetchFolderItemsByTypePage(serverUrl, accessToken, userId, folderId,
                                       "Series,Folder,Movie", false,
                                       startIndex, limit, sortMode, onSuccess, onError);
}
// Navigation hiérarchique des bibliothèques Séries. Une Series ouvre sa fiche
// dédiée, donc Season/Episode n'ont pas à être remontés dans cette grille. On
// conserve Folder/Movie/Video/MusicVideo pour les bibliothèques atypiques.
function fetchMediaBrowserItemsPage(serverUrl, accessToken, userId, folderId,
                                    startIndex, limit, sortMode, onSuccess, onError) {
    return _fetchFolderItemsByTypePage(
        serverUrl, accessToken, userId, folderId,
        "Series,Folder,Movie,Video,MusicVideo", false,
        startIndex, limit, sortMode, onSuccess, onError
    );
}
function fetchCollectionFolderItemsPage(serverUrl, accessToken, userId, folderId,
                                        startIndex, limit, sortMode, onSuccess, onError) {
    return _fetchFolderItemsByTypePageWithDirectFallback(
        serverUrl, accessToken, userId, folderId,
        "BoxSet", true,
        startIndex, limit, sortMode, onSuccess, onError
    );
}
function fetchCollectionChildrenPage(serverUrl, accessToken, userId, folderId, startIndex, limit, mode, deadlineAt, onSuccess, onError) {
    if (!serverUrl || !accessToken || !userId || !folderId) {
        if (onError) onError("missing_params");
        return null;
    }
    mode = Math.max(0, Math.min(3, _int(mode)));
    startIndex = _folderSafeStartIndex(startIndex);
    limit = _folderSafePageLimit(limit);
    var recursive = mode === 1 || mode === 3;
    var noCollapse = mode >= 2;
    var query = "/Items?UserId=" + enc(userId) +
                "&ParentId=" + enc(folderId) +
                "&Recursive=" + (recursive ? "true" : "false") +
                (noCollapse ? "&CollapseBoxSetItems=false" : "") +
                "&EnableTotalRecordCount=false" +
                "&EnableImages=true&EnableUserData=true" +
                "&SortBy=SortName&SortOrder=Ascending" +
                "&StartIndex=" + startIndex +
                "&Limit=" + limit +
                "&Fields=" + _modernItemFields("PrimaryImageAspectRatio,CumulativeRunTimeTicks,CustomRating,ParentId,SortName,DateCreated,DateLastMediaAdded,ChildCount,RecursiveItemCount,ItemCounts");
    return sendRequestWithDeadline(
        "get", _u(serverUrl, query), headersWithToken(accessToken), null,
        function(res) {
            var items = _folderItemsFromResponse(res);
            if (!items) { if (onError) onError("empty"); return; }
            if (onSuccess) onSuccess({ items: items, startIndex: startIndex, limit: limit, mode: mode });
        },
        function(err) { if (onError) onError(_errCode(err, "network_error")); },
        deadlineAt
    );
}
function _folderItemsFromResponse(res) {
    var j = jsonNormalize(res && res.json);
    if (j && j.Items) return j.Items || [];
    if (_isArray(j)) return j;
    return null;
}
function _folderAppendTypedUnique(out, seen, items, typeName) {
    items = MediaCatalog.filterRealTypedMediaItems(items || [], typeName);
    for (var i = 0; i < items.length; i++) {
        var it = items[i];
        var id = it && it.Id ? _s(it.Id) : "";
        if (!id) continue;
        if (seen[id]) continue;
        seen[id] = 1;
        out.push(it);
    }
}
function fetchIntros(serverUrl, accessToken, userId, itemId, onSuccess, onError) {
    serverUrl = _normalizeBase(serverUrl);
    accessToken = _s(accessToken);
    userId = _s(userId);
    itemId = _s(itemId);
    if (!serverUrl || !accessToken || !itemId) {
        if (onSuccess) onSuccess([]);
        return;
    }
    var path = "/Items/" + enc(itemId) + "/Intros";
    if (userId) path += "?UserId=" + enc(userId);
    sendRequest("get", _u(serverUrl, path), headersWithToken(accessToken), null, function(res) {
        var j = jsonNormalize(res && res.json !== undefined ? res.json : res) || {};
        var items = _isArray(j) ? j : (j.Items && _isArray(j.Items) ? j.Items : []);
        if (onSuccess) onSuccess(items || []);
    }, function(err) {
        if (onError) onError(_errCode(err, "network_error"));
    });
}
function fetchItem(serverUrl, accessToken, itemId, onSuccess, onError) {
    var url = _u(serverUrl, "/Items/" + enc(itemId));
    return sendRequest("get", url, headersWithToken(accessToken), null, function (res) {
        var j = jsonNormalize(res.json);
        if (j && j.Id) onSuccess(j);
        else onError && onError("bad_response");
    }, function (err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function fetchItemAncestors(serverUrl, accessToken, userId, itemId, onSuccess, onError) {
    if (!serverUrl || !accessToken || !itemId) {
        onError && onError("missing_params");
        return null;
    }
    var path = "/Items/" + enc(itemId) + "/Ancestors";
    if (userId) path += "?UserId=" + enc(userId);
    var url = _u(serverUrl, path);
    return sendRequest("get", url, headersWithToken(accessToken), null, function(res) {
        var j = jsonNormalize(res && res.json);
        var items = _isArray(j) ? j : (j && _isArray(j.Items) ? j.Items : []);
        if (onSuccess) onSuccess(items || []);
    }, function(err) {
        if (onError) onError(_errCode(err, "network_error"));
    });
}
function fetchItemChapters(serverUrl, accessToken, itemId, onSuccess, onError) {
    return fetchItem(serverUrl, accessToken, itemId, function(item) {
        var arr = item && (item.Chapters || item.chapters) ? (item.Chapters || item.chapters) : [];
        if (!arr || typeof arr.length !== "number") arr = [];
        if (onSuccess) onSuccess(arr);
    }, onError);
}
function fetchUserItem(serverUrl, accessToken, userId, itemId, onSuccess, onError) {
    if (!serverUrl || !accessToken || !userId || !itemId) {
        onError && onError("missing_params");
        return null;
    }
    var controller = _newRequestController();
    var directUrl = _u(serverUrl, "/Items/" + enc(itemId) + "?UserId=" + enc(userId));
    function failDirect(err) {
        if (controller.cancelled || controller.done) return;
        var fallbackUrl = _u(serverUrl, "/Items?UserId=" + enc(userId)
            + "&Ids=" + enc(itemId)
            + "&EnableUserData=true&EnableImages=false&Limit=1");
        controller._setTransport(sendRequest("get", fallbackUrl, headersWithToken(accessToken), null, function(res) {
            if (controller.cancelled || controller.done) return;
            var j = jsonNormalize(res && res.json);
            var items = j && j.Items ? j.Items : [];
            var item = items && items.length ? items[0] : null;
            controller._finish();
            if (item && item.Id) onSuccess && onSuccess(item);
            else onError && onError("bad_response");
        }, function(fallbackErr) {
            if (controller.cancelled || controller.done) return;
            controller._finish();
            onError && onError(_errCode(fallbackErr || err, "network_error"));
        }));
    }
    controller._setTransport(sendRequest("get", directUrl, headersWithToken(accessToken), null, function(res) {
        if (controller.cancelled || controller.done) return;
        var j = jsonNormalize(res && res.json);
        if (j && j.Id) { controller._finish(); onSuccess && onSuccess(j); }
        else failDirect("bad_response");
    }, failDirect));
    return controller;
}
function fetchUserItemWithPublicFallback(serverUrl, accessToken, userId, itemId, onSuccess, onError) {
    itemId = _s(itemId);
    if (!itemId) {
        onError && onError("missing_params");
        return null;
    }

    var controller = _newRequestController();
    function finishSuccess(item) {
        if (controller.cancelled || controller.done) return;
        controller._finish();
        onSuccess && onSuccess(item);
    }
    function finishError(err) {
        if (controller.cancelled || controller.done) return;
        controller._finish();
        onError && onError(err || "network_error");
    }
    function fetchPublic(previousError) {
        if (controller.cancelled || controller.done) return;
        controller._setTransport(fetchItem(serverUrl, accessToken, itemId, finishSuccess, function(err) {
            finishError(err || previousError || "network_error");
        }));
    }

    if (userId) {
        controller._setTransport(fetchUserItem(serverUrl, accessToken, userId, itemId, finishSuccess, fetchPublic));
    } else {
        fetchPublic("missing_user");
    }
    return controller;
}
function fetchRandomEpisode(serverUrl, accessToken, userId, parentId, preferUnplayed, onSuccess, onError) {
    if (!serverUrl || !accessToken || !userId || !parentId) {
        onError && onError("missing_params");
        return null;
    }
    var controller = _newRequestController();
    function run(unplayed, allowFallback) {
        if (controller.cancelled || controller.done) return;
        var path = "/Items?IncludeItemTypes=Episode&Recursive=true"
            + "&UserId=" + enc(userId)
            + "&ParentId=" + enc(parentId)
            + "&Limit=1&SortBy=Random"
            + (unplayed ? "&Filters=IsUnplayed" : "");
        controller._setTransport(sendRequest("get", _u(serverUrl, path), headersWithToken(accessToken), null, function(res) {
            if (controller.cancelled || controller.done) return;
            var j = jsonNormalize(res && res.json) || {};
            var items = j.Items || [];
            if (items.length) { controller._finish(); onSuccess && onSuccess(items[0]); return; }
            if (allowFallback) { run(false, false); return; }
            controller._finish();
            onError && onError("empty");
        }, function(err) {
            if (controller.cancelled || controller.done) return;
            if (allowFallback) { run(false, false); return; }
            controller._finish();
            onError && onError(_errCode(err, "network_error"));
        }));
    }
    run(preferUnplayed === true, preferUnplayed === true);
    return controller;
}
// Ordre des éléments à l'intérieur d'une collection Jellyfin.
// SortName correspond au champ « Titre de tri ». Le nom visible reste uniquement
// un fallback si le serveur ne renvoie pas SortName. Les égalités sont départagées
// par Name puis Id afin de conserver un ordre déterministe pendant la pagination.
function itemImageUrl(serverUrl, itemId, type, tag, opts) {
    var u = _normalizeBase(serverUrl);
    if (!u || !itemId || !type) return "";
    opts = opts || {};
    var q = [];
    if (tag) q.push("tag=" + enc(tag));
    if (opts.fillHeight) q.push("fillHeight=" + _posInt(opts.fillHeight));
    if (opts.fillWidth)  q.push("fillWidth="  + _posInt(opts.fillWidth));
    if (opts.maxHeight)  q.push("maxHeight="  + _posInt(opts.maxHeight));
    if (opts.maxWidth)   q.push("maxWidth="   + _posInt(opts.maxWidth));
    if (opts.quality != null) q.push("quality=" + _posInt(opts.quality));
    if (opts.blur) q.push("blur=" + Math.max(1, Math.min(50, _posInt(opts.blur))));
    if (opts.format) q.push("format=" + enc(opts.format));
    var qs = q.length ? ("?" + q.join("&")) : "";
    return stripAuthQueryFromUrl(u + "/Items/" + enc(itemId) + "/Images/" + enc(type) + qs);
}
function itemBackdropOrPrimaryUrl(serverUrl, item, opts) {
    if (!item || !item.Id) return "";
    var backdrops = item.BackdropImageTags || [];
    if (backdrops.length)
        return itemImageUrl(serverUrl, item.Id, "Backdrop", backdrops[0], opts || {});
    var tags = item.ImageTags || {};
    var primary = tags.Primary || item.PrimaryImageTag || "";
    return primary ? itemImageUrl(serverUrl, item.Id, "Primary", primary, opts || {}) : "";
}
function fetchPersonItemsPage(serverUrl, accessToken, userId, personId, includeTypes,
                              startIndex, limit, deadlineAt, onSuccess, onError) {
    var base = normalizeServerUrl(serverUrl, false);
    var uid = _s(userId);
    var pid = _s(personId);
    if (!base || !accessToken || !uid || !pid) {
        if (onError) onError({ code: "missing_params", message: "missing_params", status: 0 });
        return _completedHttpHandle();
    }
    var start = Math.max(0, _int(startIndex));
    var pageLimit = Math.max(1, _int(limit));
    var types = _s(includeTypes);
    var query = "UserId=" + enc(uid)
              + "&Recursive=true"
              + "&PersonIds=" + enc(pid)
              + "&IncludeItemTypes=" + enc(types)
              + "&CollapseBoxSetItems=false"
              + "&EnableImages=true"
              + "&EnableUserData=true"
              + "&EnableTotalRecordCount=false"
              + "&SortBy=SortName"
              + "&SortOrder=Ascending"
              + "&StartIndex=" + start
              + "&Limit=" + pageLimit
              + "&Fields=PrimaryImageAspectRatio,SortName";
    return sendRequestWithDeadline(
        "get", _u(base, "/Items?" + query), headersWithToken(accessToken), null,
        function(res) {
            var payload = jsonNormalize(res && res.json) || {};
            var items = payload && payload.Items ? payload.Items
                      : ((payload && payload.length !== undefined) ? payload : []);
            if (onSuccess) onSuccess(items || [], payload, res);
        },
        function(err) { if (onError) onError(err); },
        deadlineAt
    );
}

function fetchPerson(serverUrl, accessToken, personId, onSuccess, onError) {
    if (!serverUrl || !accessToken || !personId) { onError && onError("missing_params"); return; }
    // Une personne Jellyfin est un BaseItem et se récupère par son Id via
    // l'endpoint Library actuel /Items/{itemId}. /Persons/{name} est une
    // recherche par nom et ne doit pas servir de fallback à un Id.
    var urlItems = _u(serverUrl, "/Items/" + enc(personId));
    sendRequest("get", urlItems, headersWithToken(accessToken), null, function (res) {
        var j = jsonNormalize(res.json) || {};
        if (j && (j.Id || j.Name)) {
            onSuccess && onSuccess(j);
            return;
        }
        onError && onError("bad_response");
    }, function (err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function fetchItemPeople(serverUrl, accessToken, itemId, onSuccess, onError) {
    if (!serverUrl || !accessToken || !itemId) { onError && onError("missing_params"); return; }
    var url = _u(serverUrl, "/Items/" + enc(itemId));
    sendRequest("get", url, headersWithToken(accessToken), null, function (res) {
        var j = jsonNormalize(res.json) || {};
        var list = _isArray(j)
            ? j
            : (j && j.People) ? j.People
            : (j && j.Items) ? j.Items
            : [];
        onSuccess && onSuccess(list || []);
    }, function (e) {
        onError && onError(_errCode(e, "network_error"));
    });
}
function fetchSeasons(serverUrl, accessToken, userId, seriesId, onSuccess, onError) {
    if (!serverUrl || !accessToken || !userId || !seriesId) { onError && onError("missing_params"); return; }
    var url1 = _u(serverUrl,
        "/Shows/" + enc(seriesId) +
        "/Seasons?UserId=" + enc(userId) +
        "&EnableImages=true&EnableUserData=true" +
        "&Fields=" + _modernItemFields("PrimaryImageAspectRatio,Overview,ChildCount")
    );
    sendRequest("get", url1, headersWithToken(accessToken), null, function (res) {
        var j = jsonNormalize(res.json);
        var items = (j && j.Items) ? j.Items : (_isArray(j) ? j : []);
        if (items && items.length) {
            MediaCatalog.sortSeasonsInPlace(items);
            onSuccess && onSuccess(items);
            return;
        }
        var url2 = _u(serverUrl,
            "/Items?UserId=" + enc(userId) +
            "&ParentId=" + enc(seriesId) +
            "&IncludeItemTypes=Season&Recursive=false&SortBy=SortName" +
            "&EnableTotalRecordCount=false&EnableImages=true&EnableUserData=true" +
            "&Fields=" + _modernItemFields("PrimaryImageAspectRatio,Overview,ChildCount")
        );
        sendRequest("get", url2, headersWithToken(accessToken), null, function (res2) {
            var jj = jsonNormalize(res2.json);
            var it = (jj && jj.Items) ? jj.Items : (_isArray(jj) ? jj : []);
            MediaCatalog.sortSeasonsInPlace(it);
            onSuccess && onSuccess(it || []);
        }, function (e2) {
            onError && onError(_errCode(e2, "network_error"));
        });
    }, function (e1) {
        onError && onError(_errCode(e1, "network_error"));
    });
}
function fetchEpisodes(serverUrl, accessToken, userId, seasonId, onSuccess, onError) {
    if (!serverUrl || !accessToken || !userId || !seasonId) { onError && onError("missing_params"); return _completedHttpHandle(); }
    var fields = _modernItemFields("PrimaryImageAspectRatio");
    var baseUrl = _u(serverUrl,
        "/Items?UserId=" + enc(userId) + "&ParentId=" + enc(seasonId) +
        "&IncludeItemTypes=Episode&Recursive=false&EnableTotalRecordCount=false" +
        "&EnableImages=true&EnableUserData=true" +
        "&Fields=" + fields + "&SortBy=IndexNumber,PremiereDate&SortOrder=Ascending"
    );
    return _fetchPagedItems(baseUrl, accessToken, 50, 1000, function (items, meta) {
        items = items || [];
        MediaCatalog.sortEpisodesInPlace(items);
        onSuccess && onSuccess(items || [], meta || { partial: false });
    }, function (e) { onError && onError(_errCode(e, "network_error")); });
}
function fetchUnknownSeasonEpisodesItems(serverUrl, accessToken, userId, seriesId, onSuccess, onError) {
    if (!serverUrl || !accessToken || !userId || !seriesId) {
        onError && onError("missing_params");
        return _completedHttpHandle();
    }
    var fields = _modernItemFields("PrimaryImageAspectRatio");
    var baseUrl = _u(serverUrl,
        "/Items?UserId=" + enc(userId) +
        "&ParentId=" + enc(seriesId) +
        "&IncludeItemTypes=Episode&Recursive=true&EnableTotalRecordCount=false" +
        "&EnableImages=true&EnableUserData=true" +
        "&Fields=" + fields +
        "&SortBy=ParentIndexNumber,IndexNumber,PremiereDate&SortOrder=Ascending"
    );
    return _fetchPagedItems(baseUrl, accessToken, 50, 1000, function(items, meta) {
        items = items || [];
        var filtered = [];
        for (var i = 0; i < items.length; i++) {
            if (MediaCatalog.isUnknownSeasonEpisode(items[i])) filtered.push(items[i]);
        }
        MediaCatalog.sortUnknownSeasonEpisodesInPlace(filtered);
        if (meta && meta.partial && filtered.length === 0) {
            onError && onError({ code:"budget_exhausted", message:"paged_budget_exhausted" });
            return;
        }
        onSuccess && onSuccess(filtered, meta || { partial:false });
    }, function(err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function _seriesPlayableEpisodeFields(){ return _modernItemFields("Path,MediaSources,MediaStreams,PrimaryImageAspectRatio"); }
function _itemsArrayFromResponse(json) {
    var j = jsonNormalize(json) || {};
    if (j && j.Items) return j.Items || [];
    if (_isArray(j)) return j;
    return [];
}
function _fetchPagedItems(baseUrl, accessToken, pageSize, maxItems, onSuccess, onError, _controller, _finishController) {
    var controller = _controller || createPagedRequestController();
    var finishController = (_finishController !== false);
    baseUrl = _s(baseUrl);
    var limit = Math.max(20, pageSize | 0);
    var minLimit = 50;
    var hardMax = Math.max(limit, maxItems | 0);
    var out = [];
    var start = 0;
    function pageUrl(startIndex, pageLimit) {
        var sep = baseUrl.indexOf("?") >= 0 ? "&" : "?";
        return baseUrl + sep + "StartIndex=" + Math.max(0, startIndex | 0) + "&Limit=" + Math.max(1, pageLimit | 0);
    }
    function finish(meta) {
        if (!controller.isActive()) return;
        if (finishController) controller._finish();
        onSuccess && onSuccess(out || [], meta || { partial: false, nextStartIndex: start });
    }
    function fail(code) {
        if (!controller.isActive()) return;
        code = _errCode(code, "network_error");
        if ((code === "timeout" || code === "budget_exhausted") && out.length > 0) {
            finish({ partial: true, code: "budget_exhausted",
                     message: "paged_budget_exhausted", nextStartIndex: start });
            return;
        }
        if (finishController) controller._finish();
        onError && onError(code === "timeout" ? "budget_exhausted" : code);
    }
    function next() {
        if (!controller.isActive()) return;
        if (controller.expired()) { fail("budget_exhausted"); return; }
        var url = pageUrl(start, limit);
        var requestHandle = null;
        requestHandle = sendRequestWithDeadline("get", url, headersWithToken(accessToken), null, function(res) {
            controller._clearTransport(requestHandle);
            if (!controller.isActive()) return;
            var arr = _itemsArrayFromResponse(res && res.json);
            if (!arr || !arr.length) {
                finish();
                return;
            }
            for (var i = 0; i < arr.length && out.length < hardMax; i++)
                out.push(arr[i]);
            if (arr.length < limit || out.length >= hardMax) {
                finish();
                return;
            }
            start += arr.length;
            _laterBridge(next);
        }, function(e) {
            controller._clearTransport(requestHandle);
            if (!controller.isActive()) return;
            var code = _errCode(e, "network_error");
            if (code === "too_large" && limit > minLimit) {
                limit = Math.max(minLimit, Math.floor(limit / 2));
                _laterBridge(next);
                return;
            }
            fail(code);
        }, controller.deadlineAt);
        controller._setTransport(requestHandle);
    }
    next();
    return controller;
}
function _fetchSeriesEpisodesItemsViaUsers(serverUrl, accessToken, userId, seriesId, onSuccess, onError, _controller, _finishController) {
    var baseUrl = _u(serverUrl,
        "/Items?UserId=" + enc(userId) +
        "&Recursive=true" +
        "&ParentId=" + enc(seriesId) +
        "&IncludeItemTypes=Episode" +
        "&EnableTotalRecordCount=false" +
        "&EnableImages=true&EnableUserData=true" +
        "&SortBy=ParentIndexNumber,IndexNumber" +
        "&SortOrder=Ascending" +
        "&Fields=" + _seriesPlayableEpisodeFields()
    );
    return _fetchPagedItems(baseUrl, accessToken, 300, 3000, function (arr, meta) {
        MediaCatalog.sortEpisodesInPlace(arr);
        onSuccess && onSuccess(arr || [], meta);
    }, function (e) {
        onError && onError(_errCode(e, "network_error"));
    }, _controller, _finishController);
}
function _fetchSeriesEpisodesItemsViaShows(serverUrl, accessToken, userId, seriesId, onSuccess, onError, _controller, _finishController) {
    var baseUrl = _u(serverUrl,
        "/Shows/" + enc(seriesId) +
        "/Episodes?UserId=" + enc(userId) +
        "&IsMissing=false" +
        "&EnableImages=true&EnableUserData=true" +
        "&SortBy=IndexNumber" +
        "&Fields=" + _seriesPlayableEpisodeFields()
    );
    return _fetchPagedItems(baseUrl, accessToken, 300, 3000, function (arr, meta) {
        MediaCatalog.sortEpisodesInPlace(arr);
        onSuccess && onSuccess(arr || [], meta);
    }, function (e) {
        onError && onError(_errCode(e, "network_error"));
    }, _controller, _finishController);
}
function _fetchSeriesItemsWithShowsFallback(serverUrl, accessToken, userId, seriesId,
                                                fetchViaShows, fetchViaUsers,
                                                onSuccess, onError) {
    if (!serverUrl || !accessToken || !userId || !seriesId) {
        onError && onError("missing_params");
        return _completedHttpHandle();
    }

    var controller = createPagedRequestController();
    function complete(items, meta) {
        if (!controller.isActive()) return;
        controller._finish();
        onSuccess && onSuccess(items || [], meta || { partial:false });
    }
    function failFinal(err) {
        if (!controller.isActive()) return;
        controller._finish();
        onError && onError(_errCode(err, "network_error"));
    }
    function fallbackToUsers() {
        if (!controller.isActive()) return;
        if (controller.expired()) {
            failFinal("budget_exhausted");
            return;
        }
        fetchViaUsers(serverUrl, accessToken, userId, seriesId,
                      complete, failFinal, controller, false);
    }

    fetchViaShows(serverUrl, accessToken, userId, seriesId, function(items, meta) {
        if (items && items.length > 0) {
            complete(items, meta);
            return;
        }
        fallbackToUsers();
    }, fallbackToUsers, controller, false);
    return controller;
}

function fetchSeriesEpisodesItems(serverUrl, accessToken, userId, seriesId, onSuccess, onError) {
    return _fetchSeriesItemsWithShowsFallback(
                serverUrl, accessToken, userId, seriesId,
                _fetchSeriesEpisodesItemsViaShows, _fetchSeriesEpisodesItemsViaUsers,
                onSuccess, onError);
}
function _fetchSeriesLightEpisodeItemsViaShows(serverUrl, accessToken, userId, seriesId, onSuccess, onError, _controller, _finishController) {
    // Chemin volontairement léger pour les actions de fiche série et le calcul
    // de durée moyenne. Une playlist n'a pas besoin de Path/MediaSources/
    // MediaStreams, d'images ni de UserData. Sur Révolution ces champs peuvent
    // faire dépasser MAX_HTTP_TEXT_LEN même avec seulement 50 épisodes.
    var baseUrl = _u(serverUrl,
        "/Shows/" + enc(seriesId) +
        "/Episodes?UserId=" + enc(userId) +
        "&IsMissing=false" +
        "&IsVirtualUnaired=false" +
        "&EnableImages=false&EnableUserData=false" +
        "&EnableTotalRecordCount=false" +
        "&SortBy=ParentIndexNumber,IndexNumber" +
        "&SortOrder=Ascending"
    );
    return _fetchPagedItems(baseUrl, accessToken, 100, 3000, function (arr, meta) {
        MediaCatalog.sortEpisodesInPlace(arr);
        onSuccess && onSuccess(arr || [], meta);
    }, function (e) {
        onError && onError(_errCode(e, "network_error"));
    }, _controller, _finishController);
}
function _fetchSeriesLightEpisodeItemsViaUsers(serverUrl, accessToken, userId, seriesId, onSuccess, onError, _controller, _finishController) {
    var baseUrl = _u(serverUrl,
        "/Items?UserId=" + enc(userId) +
        "&Recursive=true" +
        "&ParentId=" + enc(seriesId) +
        "&IncludeItemTypes=Episode" +
        "&EnableImages=false&EnableUserData=false" +
        "&EnableTotalRecordCount=false" +
        "&SortBy=ParentIndexNumber,IndexNumber" +
        "&SortOrder=Ascending"
    );
    return _fetchPagedItems(baseUrl, accessToken, 100, 3000, function (arr, meta) {
        MediaCatalog.sortEpisodesInPlace(arr);
        onSuccess && onSuccess(arr || [], meta);
    }, function (e) {
        onError && onError(_errCode(e, "network_error"));
    }, _controller, _finishController);
}
function _fetchSeriesLightEpisodeItems(serverUrl, accessToken, userId, seriesId, onSuccess, onError) {
    return _fetchSeriesItemsWithShowsFallback(
                serverUrl, accessToken, userId, seriesId,
                _fetchSeriesLightEpisodeItemsViaShows, _fetchSeriesLightEpisodeItemsViaUsers,
                onSuccess, onError);
}
function fetchSeriesPlayableEpisodeIds(serverUrl, accessToken, userId, seriesId, onSuccess, onError) {
    return _fetchSeriesLightEpisodeItems(serverUrl, accessToken, userId, seriesId, function (items, meta) {
        items = items || [];
        // Le endpoint est déjà limité à la série. Ce filtre est volontairement
        // tolérant quand Path/MediaSources ne sont pas demandés, mais exclut les
        // épisodes virtuels/manquants/placeholder grâce aux champs BaseItemDto.
        var ids = MediaCatalog.episodeIdListFromItems(items);
        if (meta && meta.partial) {
            onError && onError({ code: "budget_exhausted", message: "paged_budget_exhausted",
                                 partial: true, partialCount: ids.length });
            return;
        }
        onSuccess && onSuccess(ids || []);
    }, function(err){
        onError && onError(err);
    });
}
function fetchSeriesAverageEpisodeRuntimeTicks(serverUrl, accessToken, userId, seriesId, fallbackTicks, onSuccess, onError) {
    var fb = MediaCatalog.seriesRuntimeTicksFallback(fallbackTicks);
    if (!serverUrl || !accessToken || !userId || !seriesId) {
        if (fb > 0) { onSuccess && onSuccess(fb); return _completedHttpHandle(); }
        onError && onError("missing_params");
        return _completedHttpHandle();
    }
    return _fetchSeriesLightEpisodeItems(serverUrl, accessToken, userId, seriesId, function (items) {
        var eps = [];
        for (var i = 0; items && i < items.length; i++) {
            var ep = items[i];
            if (MediaCatalog.episodeIsPlayableForPlaylist(ep)) eps.push(ep);
        }
        onSuccess && onSuccess(MediaCatalog.averageEpisodeRuntimeTicks(eps, fb));
    }, function (err) {
        if (fb > 0) { onSuccess && onSuccess(fb); return; }
        onError && onError(err || "network_error");
    });
}
function buildRandomPlayableSeriesPlaylist(serverUrl, accessToken, userId, seriesId, onSuccess, onError) {
    return fetchSeriesPlayableEpisodeIds(serverUrl, accessToken, userId, seriesId, function (ids) {
        var a = MediaCatalog.shuffledCopy(ids);
        if (typeof onSuccess === "function") onSuccess(a || []);
    }, function(err){
        if (typeof onError === "function") onError(err);
    });
}

function _bool(v) { return !!v; }
function setPlayedState(serverUrl, accessToken, userId, itemId, played, onSuccess, onError) {
    if (!serverUrl || !userId || !itemId) { onError && onError("missing_params"); return; }
    var url = _u(serverUrl,
        "/UserPlayedItems/" + enc(itemId) + "?UserId=" + enc(userId));
    var m = _bool(played) ? "post" : "delete";
    return sendRequest(m, url, headersWithToken(accessToken), _bool(played) ? {} : null, function () {
        onSuccess && onSuccess(true);
    }, function (err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function setFavorite(serverUrl, accessToken, userId, itemId, favorite, onSuccess, onError) {
    if (!serverUrl || !userId || !itemId) { onError && onError("missing_params"); return; }
    var url = _u(serverUrl,
        "/UserFavoriteItems/" + enc(itemId) + "?UserId=" + enc(userId));
    var m = _bool(favorite) ? "post" : "delete";
    return sendRequest(m, url, headersWithToken(accessToken), _bool(favorite) ? {} : null, function () {
        onSuccess && onSuccess(true);
    }, function (err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function _postPlayingEvent(serverUrl, accessToken, path, payload, onSuccess, onError) {
    return sendRequest("post", _u(serverUrl, path), headersWithToken(accessToken), payload, function () {
        onSuccess && onSuccess();
    }, function (err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
function sessionsPlayingStart(serverUrl, accessToken, payload, onSuccess, onError) {
    return _postPlayingEvent(serverUrl, accessToken, "/Sessions/Playing", payload, onSuccess, onError);
}
function sessionsPlayingProgress(serverUrl, accessToken, payload, onSuccess, onError) {
    return _postPlayingEvent(serverUrl, accessToken, "/Sessions/Playing/Progress", payload, onSuccess, onError);
}
function sessionsPlayingStopped(serverUrl, accessToken, payload, onSuccess, onError) {
    return _postPlayingEvent(serverUrl, accessToken, "/Sessions/Playing/Stopped", payload, onSuccess, onError);
}
function updateUserPlaybackPosition(serverUrl, accessToken, userId, itemId, ticks, onSuccess, onError) {
    var url = _u(serverUrl,
        "/UserItems/" + enc(itemId) + "/UserData?UserId=" + enc(userId));
    var safeTicks = Math.max(0, Math.floor(+ticks || 0));
    var body = { PlaybackPositionTicks: safeTicks };
    // Une lecture per-item déjà mise en cache ne doit jamais réinjecter une
    // ancienne position après cette écriture.
    try { evictUserItemApiCache(itemId); } catch(e0) {}
    return sendRequest("post", url, headersWithToken(accessToken), body, function () {
        try { evictUserItemApiCache(itemId); } catch(e1) {}
        onSuccess && onSuccess();
    }, function (err) {
        onError && onError(_errCode(err, "network_error"));
    });
}
