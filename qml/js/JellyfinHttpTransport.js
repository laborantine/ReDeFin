.pragma library

// Couche HTTP Jellyfin/Freebox : transport natif ou XHR, taille des réponses,
// annulation et délais. Le bridge conserve les routes, le cache API et la
// politique de sécurité, et valide chaque requête avant d’appeler send().
function _s(v) { return (v === undefined || v === null) ? "" : (v + ""); }
function httpErrorPayload(status) {
    status = status | 0;
    return {
        code: "http_" + status,
        message: "HTTP " + status,
        data: "",
        status: status
    };
}
var _fbx = null;
function setFbx(fbxCtx) { _fbx = fbxCtx; }
function nowMs() {
    try { return Date.now(); } catch(e) { return (new Date()).getTime(); }
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
        deadlineAt: nowMs() + Math.max(100, Number(timeoutMs || DEFAULT_NATIVE_TIMEOUT_MS)),
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
function completedHttpHandle() {
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
        deadlineAt: nowMs() + budget,
        transport: null,
        isActive: function() { return this.active === true && !this.done && !this.cancelled; },
        remainingMs: function() { return Math.max(0, Number(this.deadlineAt || 0) - nowMs()); },
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
    var now = Number(nowMs || nowMs()); var expired = [];
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
function stripQueryAndFragment(url) {
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
function _safeTrimHeader(v) {
    v = _s(v);
    return v.trim ? v.trim() : v;
}
function _parseRawHeaders(raw) {
    var out = {};
    raw = _s(raw);
    if (!raw) return out;
    var lines = raw.split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
        var L = _s(lines[i]); var p = L.indexOf(":");
        if (p > 0) {
            var key = _safeTrimHeader(L.slice(0, p)); var val = _safeTrimHeader(L.slice(p + 1));
            if (key) out[key] = val;
        }
    }
    return out;
}
function _xhrSend(method, url, headers, body, onSuccess, onError, timeoutMs) {
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
        return completedHttpHandle();
    }
}
function _bindNativeReply(op, promise, method, url, headers) {
    promise.then(function (response) {
        if (!op.isActive()) return;
        var status = response.status || 0;
        var rawText = response.responseText || response.body || "";
        var safe = _makeSafeHttpSuccessPayload(
            status,
            rawText,
            response.headers || {},
            function() { return response.jsonParse ? response.jsonParse() : _parseJsonBounded(rawText); },
            _shouldReturnTextForRequest(method, url, headers)
        );
        if (safe.tooLarge) {
            op.fail({ code: "too_large", message: "too_large" });
            return;
        }
        op.succeed(safe.payload);
    }, function () {
        op.fail({ code: "network_error", message: "network_error" });
    });
}

function send(method, url, headers, body, onSuccess, onError, timeoutMs) {
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
            _bindNativeReply(txOp, txPromise, method, url, headers);
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
            _bindNativeReply(reqOp, reqPromise, method, url, headers);
            return reqOp;
        }
    } catch (e2) {
        if (reqOp) reqOp.cancel("transport_error", false);
        _tryAbortTransport(req);
    }
    return _xhrSend(method, url, headers, body, onSuccess, onError, effectiveTimeout);
}

function probeMetadata(url, headers, onSuccess, onError, timeoutMs, sameOrigin) {
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
            onError(httpErrorPayload(status | 0));
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
            if (finalUrl && !sameOrigin(url, finalUrl)) {
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
