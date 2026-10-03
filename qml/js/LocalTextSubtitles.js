.pragma library
.import "SafeLog.js" as SafeLog

// Téléchargement annulable et décodage SRT/VTT pour le DirectPlay.
// Le transport Jellyfin est injecté par le lecteur et reste centralisé.

function _s(v) { return (v === undefined || v === null) ? "" : (v + ""); }
function _safeHelperCode(err, fallback) {
    var fb = fallback || "network_error";
    var raw = (typeof err === "string") ? err.toLowerCase() : "";
    if (raw === "ctx" || raw === "http" || raw === "404" || raw === "too_large") return raw;
    return SafeLog.safeErrorCode(err, fb);
}
function _safeSubtitleText(txt) {
    txt = _s(txt);
    var maxLen = 4194304; // 4 Mo, garde-fou RAM Freebox pour SRT/VTT aberrants.
    if (txt.length > maxLen)
        return "";
    return txt;
}
function _normalizeBase(url) {
    url = _s(url);
    if (!url) return "";
    return url.charAt(url.length - 1) === "/" ? url.slice(0, -1) : url;
}
function _u(base, path) {
    base = _normalizeBase(base || "");
    path = _s(path);
    if (!path) return base;
    return base + (path.charAt(0) === "/" ? path : ("/" + path));
}
function _appendParam(url, key, value) {
    if (value === undefined || value === null || value === "") return url;
    var sep = (url.indexOf("?") >= 0) ? "&" : "?";
    return url + sep + encodeURIComponent(key) + "=" + encodeURIComponent(String(value));
}
/* ===== Sous-titres locaux déplacés depuis JellyfinPlaybackCore ===== */
function _toMs(h, m, s, ms) { return ((h * 3600 + m * 60 + s) * 1000 + ms); }
function _fracToMs(frac) {
    var f = _s(frac).replace(/[^0-9]/g, "");
    if (!f) return 0;
    while (f.length < 3) f += "0";
    if (f.length > 3) f = f.substring(0, 3);
    var n = parseInt(f, 10);
    return isFinite(n) ? n : 0;
}
function _parseSubtitleTimeMs(raw) {
    var t = _s(raw).trim();
    if (!t) return -1;
    t = t.split(/\s+/)[0];
    t = t.replace(",", ".");
    var parts = t.split(":"); var secPart = parts.pop();
    if (secPart === undefined) return -1;
    var sm = String(secPart).match(/^(\d+)(?:\.(\d+))?$/);
    if (!sm) return -1;
    var sec = parseInt(sm[1], 10); var ms = _fracToMs(sm[2] || "0"); var min = 0; var hrs = 0;
    if (parts.length >= 1) min = parseInt(parts.pop(), 10);
    if (parts.length >= 1) hrs = parseInt(parts.pop(), 10);
    if (!isFinite(sec) || !isFinite(min) || !isFinite(hrs)) return -1;
    return _toMs(hrs, min, sec, ms);
}
function _parseCueTiming(line) {
    line = _s(line);
    var p = line.indexOf("-->");
    if (p < 0) return null;
    var left = line.substring(0, p).trim(); var right = line.substring(p + 3).trim(); var s = _parseSubtitleTimeMs(left); var e = _parseSubtitleTimeMs(right);
    if (s < 0 || e < 0 || e < s) return null;
    return { s: s, e: e };
}
function parseSrt(txt) {
    var lines = String(txt || "").replace(/\r/g, "").split("\n"); var cues = []; var i = 0; var n = lines.length;
    while (i < n) {
        while (i < n && lines[i].trim() === "") i++;
        if (i >= n) break;
        if (/^\d+$/.test(lines[i].trim())) i++;
        if (i >= n) break;
        var timing = _parseCueTiming(lines[i]);
        if (!timing) {
            i++;
            continue;
        }
        i++;
        var t = [];
        while (i < n && lines[i].trim() !== "") {
            t.push(lines[i]);
            i++;
        }
        cues.push({ s: timing.s, e: timing.e, t: t.join("\n") });
        while (i < n && lines[i].trim() === "") i++;
    }
    return cues;
}
function parseVtt(txt) {
    var s = String(txt || "").replace(/\r/g, "");
    s = s.replace(/^\uFEFF/, "");
    s = s.replace(/^WEBVTT[^\n]*\n+/i, "");
    var blocks = s.split(/\n\n+/); var cues = [];
    for (var b = 0; b < blocks.length; b++) {
        var block = blocks[b].trim();
        if (!block) continue;
        var lines = block.split("\n");
        if (lines.length && /^(NOTE|STYLE|REGION)(\s|$)/i.test(lines[0].trim())) continue;
        if (lines.length && lines[0].indexOf("-->") < 0) lines.shift();
        if (!lines.length) continue;
        var timing = _parseCueTiming(lines[0]);
        if (!timing) continue;
        cues.push({ s: timing.s, e: timing.e, t: lines.slice(1).join("\n") });
    }
    return cues;
}
function buildSubtitleFileUrl(serverUrl, itemId, mediaSourceId, subtitleIndex, format, options) {
    options = options || {};
    var ext = (format && format.length > 0) ? format : "vtt"; var startTicks = 0;
    try {
        startTicks = Math.max(0, Math.floor(Number(options.startPositionTicks || 0)));
    } catch(e) {
        startTicks = 0;
    }
    var path = "/Videos/" + encodeURIComponent(itemId) + "/" +
               encodeURIComponent(mediaSourceId) + "/Subtitles/" +
               encodeURIComponent(subtitleIndex) + "/" +
               encodeURIComponent(startTicks) + "/Stream." + ext;
    var url = _u(serverUrl, path);
    // SRT/VTT est fournie par _sendSubtitleRequest() via Authorization.
    if (startTicks > 0) {
        // /Videos/{item}/{source}/Subtitles/{index}/{ticks}/Stream.{format}.
        url = _appendParam(url, "copyTimestamps", options.copyTimestamps === true ? "true" : "false");
        url = _appendParam(url, "addVttTimeMap", options.addVttTimeMap === true ? "true" : "false");
    }
    return url;
}
function _subtitleRequestHeaders(options) {
    options = options || {};
    var headers = {}; var token = _s(options.accessToken || "");
    try {
        if (options.bridge && typeof options.bridge.headersWithToken === "function")
            headers = options.bridge.headersWithToken(token) || {};
        else if (typeof options.headersWithTokenFn === "function")
            headers = options.headersWithTokenFn(token) || {};
    } catch(e0) {
        headers = {};
    }
    var authorization = "";
    try {
        for (var k in headers) {
            if (!Object.prototype.hasOwnProperty.call(headers, k)) continue;
            if (_s(k).toLowerCase() === "authorization") {
                authorization = _s(headers[k]);
                break;
            }
        }
    } catch(e1) {}
    var out = { "Accept": "text/plain" };
    if (authorization)
        out["Authorization"] = authorization;
    return out;
}
function _sendSubtitleRequest(url, options, onSuccess, onError) {
    options = options || {};
    var headers = _subtitleRequestHeaders(options);
    // loadLocalSubtitleByStreamIndex exige déjà un token. S'il n'a pas pu être
    if (_s(options.accessToken || "") && !headers.Authorization) {
        if (onError)
            onError({ code: "auth_headers_missing", message: "auth_headers_missing" });
        return null;
    }
    function safeSuccess(res) {
        try {
            var raw = "";
            if (res && res.text !== undefined && res.text !== null)
                raw = res.text;
            else if (res && res.body !== undefined && res.body !== null)
                raw = res.body;
            raw = _s(raw);
            var txt = _safeSubtitleText(raw);
            if (!txt && raw.length > 0) {
                onError && onError({ code: "too_large", message: "too_large" });
                return;
            }
            if (!res || typeof res !== "object")
                res = { status: 0 };
            res.text = txt;
            onSuccess && onSuccess(res);
        } catch(e0) {
            onError && onError({ code: "parse_error", message: "parse_error" });
        }
    }
    if (typeof options.requestFn === "function")
        return options.requestFn("get", url, headers, null, safeSuccess, onError) || null;
    if (options.bridge && typeof options.bridge.sendRequest === "function")
        return options.bridge.sendRequest("get", url, headers, null, safeSuccess, onError) || null;
    if (onError)
        onError({ code: "bridge_missing", message: "bridge_missing" });
    return null;
}
function loadLocalSubtitleByStreamIndex(serverUrl, accessToken, itemId, mediaSourceId, streamIdx, onDone, options) {
    options = options || {};
    var controller = {
        active: true,
        transport: null,
        isActive: function() { return this.active === true; },
        cancel: function(reason) {
            if (!this.active) return false;
            this.active = false;
            var handle = this.transport;
            this.transport = null;
            try {
                if (handle && typeof handle.cancel === "function")
                    handle.cancel(reason || "cancelled", false);
            } catch(e0) {}
            return true;
        }
    };
    function finish(ok, payload) {
        if (!controller.active) return;
        controller.active = false;
        controller.transport = null;
        if (onDone) onDone(ok === true, payload);
    }
    if (!serverUrl || !accessToken || !itemId || !mediaSourceId) {
        finish(false, "ctx");
        return controller;
    }
    function tryFetch(extList, accErr) {
        if (!controller.active) return;
        if (extList.length === 0) {
            finish(false, _safeHelperCode(accErr || "404", "404"));
            return;
        }
        var ext = extList[0];
        var url = buildSubtitleFileUrl(serverUrl, itemId, mediaSourceId, streamIdx, ext, options);
        var handle = _sendSubtitleRequest(url, options, function(res) {
            if (!controller.active) return;
            controller.transport = null;
            var raw = (res && res.text !== undefined && res.text !== null) ? res.text : "";
            var txt = _safeSubtitleText(raw);
            if (!txt && _s(raw).length > 0) {
                finish(false, "too_large");
                return;
            }
            try {
                var cues = (ext === "srt") ? parseSrt(txt) : parseVtt(txt);
                if (!cues || cues.length === 0) {
                    tryFetch(extList.slice(1), "empty_" + ext);
                    return;
                }
                finish(true, {
                    format: ext,
                    cues: cues,
                    startPositionTicks: Math.max(0, Math.floor(Number(options.startPositionTicks || 0))),
                    copyTimestamps: options.copyTimestamps === true,
                    addVttTimeMap: options.addVttTimeMap === true
                });
            } catch(e1) {
                tryFetch(extList.slice(1), "parse_error");
            }
        }, function(err) {
            if (!controller.active) return;
            controller.transport = null;
            tryFetch(extList.slice(1), _safeHelperCode(err, "http"));
        });
        if (controller.active)
            controller.transport = handle || null;
        else {
            try {
                if (handle && typeof handle.cancel === "function")
                    handle.cancel("completed", false);
            } catch(e2) {}
        }
    }
    tryFetch(["vtt", "srt"], null);
    return controller;
}
