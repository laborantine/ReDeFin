.pragma library
.import "jellyfinBridge.js" as JellyfinBridge

// Navigation sensible et mémoire de retour : le module travaille sur shared,
// sans dépendre de ShellPage. Les pages conservent leurs décisions de parcours.
// Les identifiants sensibles restent hors des URL ctx=1 ; quotas/TTL sont conservés.

function trim(str){ return (str||"").trim() }

function baseOf(url) { return trim(url).split("?")[0] }

function _queryOf(url)   {
    var s = trim(url)
    var p = s.indexOf("?")
    return (p >= 0) ? s.substring(p + 1) : ""
}

function param(param, str) {
    var q = (String(str || "").split("?")[1] || "")
    if (!q.length) return ""
    var params = q.split("&")
    for (var i = 0; i < params.length; ++i) {
        var kv = params[i].split("=")
        if (kv[0] === param) return decodeURIComponent(kv[1] || "")
    }
    return ""
}

function url(page, params) {
    var qs = []
    for (var k in params) {
        if (params[k] !== undefined && params[k] !== null)
            qs.push(k + "=" + encodeURIComponent(params[k]))
    }
    return page + (qs.length ? ("?" + qs.join("&")) : "")
}

function withParam(url, key, value) {
    var base = baseOf(url)
    var qs = _queryOf(url)
    var parts = qs ? qs.split("&") : []
    var out = []
    for (var i = 0; i < parts.length; ++i) {
        var k = parts[i].split("=")[0]
        if (k && k !== key && parts[i] !== "")
            out.push(parts[i])
    }
    out.push(key + "=" + encodeURIComponent(value))
    return base + (out.length ? ("?" + out.join("&")) : "")
}

function withoutParams(url, keys) {
    var base = baseOf(url)
    var qs = _queryOf(url)
    if (!qs) return base
    var parts = qs.split("&")
    var out = []
    for (var i = 0; i < parts.length; ++i) {
        var p = parts[i]
        if (!p) continue
        var k = p.split("=")[0]
        if (keys.indexOf(k) >= 0) continue
        out.push(p)
    }
    return base + (out.length ? ("?" + out.join("&")) : "")
}

function usesSharedContext(url) {
    return param("ctx", url) === "1"
}

function stripCredentials(url) {
    if (!usesSharedContext(url)) return url
    return withoutParams(url, [
        "serverUrl",
        "accessToken",
        "userId",
        "userName",
        "userImageTag"
    ])
}

function peek(shared) {
    try {
        return shared ? shared.__redefinNavContext : null
    } catch(e) {
        return null
    }
}

function clear(shared) {
    if (!shared) return false;
    try {
        if (shared) shared.__redefinNavContext = null
        return true
    } catch(e) {}
    return false
}

function _contextFresh(ctx, maxAgeMs) {
    if (!ctx) return false
    var maxAge = Number(maxAgeMs || 0)
    if (maxAge <= 0) return true
    var ts = Number(ctx.ts || 0)
    if (ts <= 0) return true
    var age = Date.now() - ts
    return age >= 0 && age <= maxAge
}

function storeValues(shared, values) {
    try {
        if (!shared) return false
        values = values || ({})
        shared.__redefinNavContext = ({
            accessToken: values.accessToken || "",
            userId: values.userId || "",
            serverUrl: values.serverUrl || "",
            userName: values.userName || "",
            userImageTag: values.userImageTag || "",
            fbx: values.fbx || null,
            remember: values.remember === true,
            forceServerUrl: values.forceServerUrl === true,
            sourcePage: values.sourcePage || "",
            personSource: values.personSource || "",
            personId: values.personId || "",
            ts: Date.now()
        })
        return true
    } catch(e) {}
    return false
}

function storeTarget(shared, target) {
    if (!target) return false
    try {
        return storeValues(shared, {
            accessToken: target.accessToken || "",
            userId: target.userId || "",
            serverUrl: target.serverUrl || "",
            userName: target.userName || "",
            userImageTag: target.userImageTag || "",
            fbx: target.fbx || null,
            remember: target.remember === true || target.rememberProfileOnLogin === true
        })
    } catch(e) {}
    return false
}

function storeServerTarget(shared, target) {
    if (!target) return false
    try {
        return storeValues(shared, {
            serverUrl: target.serverUrl || "",
            fbx: target.fbx || null,
            remember: false
        })
    } catch(e) {}
    return false
}

function hydrate(shared, target, overwrite, maxAgeMs, clearAlways) {
    if (!target) return false
    var ctx = peek(shared)
    if (!ctx) return false
    if (!_contextFresh(ctx, maxAgeMs)) {
        clear(shared)
        return false
    }
    var changed = false
    var fields = ["accessToken", "userId", "serverUrl", "userName", "userImageTag"]
    try {
        for (var i = 0; i < fields.length; i++) {
            var key = fields[i]
            var value = ctx[key]
            if (value === undefined || value === null || String(value) === "") continue
            if (!(key in target)) continue
            var current = String(target[key] || "")
            if (overwrite === true ? current !== String(value) : current === "") {
                target[key] = String(value)
                changed = true
            }
        }
        if (("fbx" in target) && !target.fbx && ctx.fbx) {
            target.fbx = ctx.fbx
            changed = true
        }
    } catch(e) {}
    if (clearAlways === true || changed)
        clear(shared)
    return changed
}

function appendParam(url, key, value) {
    if (value === undefined || value === null || value === "") return url
    return url + (String(url).indexOf("?") >= 0 ? "&" : "?")
         + encodeURIComponent(String(key)) + "=" + encodeURIComponent(String(value))
}

function base(shared, target, pageName) {
    storeTarget(shared, target)
    return String(pageName || "") + "?ctx=1"
}

function route(shared, target, pageName, params) {
    if (!shared) return pageName + "?ctx=1";
    var url = base(shared, target, pageName)
    params = params || ({})
    for (var key in params) {
        try { if (!Object.prototype.hasOwnProperty.call(params, key)) continue } catch(e0) { continue }
        url = appendParam(url, key, params[key])
    }
    return url
}

function patch(shared, values) {
    var ctx = peek(shared)
    if (!ctx || !values) return false
    try {
        for (var key in values) {
            if (!Object.prototype.hasOwnProperty.call(values, key)) continue
            ctx[key] = values[key]
        }
        ctx.ts = Date.now()
        return true
    } catch(e) {}
    return false
}

function _transientProperty(key) {
    if (key === "personReturn") return "__redefinPersonReturnContext"
    if (key === "detailReturnRefresh") return "__redefinDetailReturnRefresh"
    if (key === "seasonGuestReturn") return "__redefinSeasonGuestReturn"
    if (key === "explicitPlaybackStart") return "__redefinExplicitPlaybackStart"
    return ""
}

function getTransient(shared, key) {
    var prop = _transientProperty(String(key || ""))
    try { return prop && shared ? (shared[prop] || null) : null } catch(e) { return null }
}

function setTransient(shared, key, value) {
    var prop = _transientProperty(String(key || ""))
    try {
        if (!prop || !shared) return false
        shared[prop] = value === undefined ? null : value
        return true
    } catch(e) {}
    return false
}

function clearFocusPrefix(shared, prefix) {
    prefix = String(prefix || "")
    if (!prefix.length || !shared) return false
    try {
        var store = shared.__redefinFocus
        if (!store) return true
        for (var key in store) {
            if (String(key).indexOf(prefix) === 0) delete store[key]
        }
        return true
    } catch(e) {}
    return false
}

function _detailFocusRoot(shared) {
    if (!shared) return null
    if (!shared.__detailFocus) shared.__detailFocus = ({})
    return shared.__detailFocus
}

function _detailFocusSnapshotBucket(shared) {
    var root = _detailFocusRoot(shared)
    if (!root) return null
    if (!root.__snapshots) root.__snapshots = ({})
    return root.__snapshots
}

function _detailFocusArm(shared, itemId, scope) {
    var root = _detailFocusRoot(shared)
    itemId = String(itemId || "")
    if (!root || !itemId.length) return false
    if (!root.__arms) root.__arms = ({})
    JellyfinBridge.putBoundedMemory(root.__arms, itemId, ({
        scope: String(scope || ""),
        t: Date.now()
    }), 48)
    return true
}

function _detailFocusIsArmed(shared, itemId) {
    var root = _detailFocusRoot(shared)
    itemId = String(itemId || "")
    return !!(root && root.__arms && itemId.length && root.__arms[itemId])
}

function _detailFocusActiveScope(shared, itemId) {
    var root = _detailFocusRoot(shared)
    itemId = String(itemId || "")
    if (!root || !root.__arms || !itemId.length || !root.__arms[itemId]) return ""
    return String(root.__arms[itemId].scope || "").toLowerCase()
}

function _detailFocusDisarm(shared, itemId) {
    var root = _detailFocusRoot(shared)
    itemId = String(itemId || "")
    if (!root || !root.__arms || !itemId.length || !root.__arms[itemId]) return false
    delete root.__arms[itemId]
    return true
}

function _detailFocusPut(shared, key, snapshot) {
    var bucket = _detailFocusSnapshotBucket(shared)
    key = String(key || "")
    if (!bucket || !key.length || !snapshot) return false
    return JellyfinBridge.putBoundedMemory(bucket, key, snapshot, 48)
}

function _detailFocusGet(shared, key) {
    var bucket = _detailFocusSnapshotBucket(shared)
    key = String(key || "")
    return bucket && key.length && bucket[key] ? bucket[key] : null
}

function _detailFocusRemove(shared, key) {
    var bucket = _detailFocusSnapshotBucket(shared)
    key = String(key || "")
    if (!bucket || !key.length || !Object.prototype.hasOwnProperty.call(bucket, key)) return false
    delete bucket[key]
    return true
}

function clearTransient(shared, key) {
    return setTransient(shared, key, null);
}

// API de focus stable, liée au conteneur partagé plutôt qu’au QObject ShellPage.
// Chaque méthode relit le bucket : une purge de profil invalide bien les snapshots.
function detailFocusApi(shared) {
    if (!shared) return null;
    if (!shared.__detailFocusApi) {
        shared.__detailFocusApi = {
            arm: function(itemId, scope) { return _detailFocusArm(shared, itemId, scope); },
            isArmed: function(itemId) { return _detailFocusIsArmed(shared, itemId); },
            activeScope: function(itemId) { return _detailFocusActiveScope(shared, itemId); },
            disarm: function(itemId) { return _detailFocusDisarm(shared, itemId); },
            put: function(key, snapshot) { return _detailFocusPut(shared, key, snapshot); },
            get: function(key) { return _detailFocusGet(shared, key); },
            remove: function(key) { return _detailFocusRemove(shared, key); }
        };
    }
    return shared.__detailFocusApi;
}

function personReturn(shared) {
    return getTransient(shared, "personReturn")
}

function setPersonReturn(shared, value) {
    return setTransient(shared, "personReturn", value)
}

function clearPersonReturn(shared) {
    return clearTransient(shared, "personReturn")
}

function detailReturnRefresh(shared) {
    return getTransient(shared, "detailReturnRefresh")
}

function setDetailReturnRefresh(shared, value) {
    return setTransient(shared, "detailReturnRefresh", value)
}

function clearDetailReturnRefresh(shared) {
    return clearTransient(shared, "detailReturnRefresh")
}

function seasonGuestReturn(shared) {
    return getTransient(shared, "seasonGuestReturn")
}

function setSeasonGuestReturn(shared, value) {
    return setTransient(shared, "seasonGuestReturn", value)
}

function clearSeasonGuestReturn(shared) {
    return clearTransient(shared, "seasonGuestReturn")
}

function setExplicitPlaybackStart(shared, value) {
    return setTransient(shared, "explicitPlaybackStart", value)
}
