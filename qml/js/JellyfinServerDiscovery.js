.pragma library
.import "jellyfinBridge.js" as Jellyfin

// Découverte LAN Jellyfin : candidats Freebox, phases HTTP/HTTPS et annulation.
// API unique : start(options, onUpdate, onDone) -> contrôleur cancel/isActive.
// Les sondes publiques, délais, redirections et règles de confiance restent
// dans jellyfinBridge / JellyfinHttpTransport ; aucune authentification ici.

function _s(v) {
    return (v === undefined || v === null) ? "" : (v + "");
}

function _isArray(a) {
    if (typeof Array !== "undefined" && Array.isArray)
        return Array.isArray(a);
    return Object.prototype.toString.call(a) === "[object Array]";
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
    var firstColon = h.indexOf(":"),
        lastColon = h.lastIndexOf(":");
    if (firstColon > 0 && firstColon === lastColon && /^\d+$/.test(h.substring(firstColon + 1)))
        h = h.substring(0, firstColon);
    else if (firstColon >= 0 && firstColon !== lastColon)
        h = "[" + h.replace(/^\[|\]$/g, "") + "]";
    return h;
}

function _discoveryIpv4(raw) {
    var s = _s(raw).trim(),
        m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s);
    if (!m) return "";
    for (var i = 1; i <= 4; i++)
        if ((Number(m[i]) | 0) < 0 || (Number(m[i]) | 0) > 255) return "";
    return s;
}

function _discoveryPushHost(out, seen, raw, maxHosts) {
    if (out.length >= maxHosts) return false;
    var h = _discoveryCleanHost(raw),
        key = h.toLowerCase();
    if (!h || seen[key]) return false;
    seen[key] = true;
    out.push(h);
    return true;
}

function _discoveryLanHosts(fbxCtx, maxHosts) {
    var ranked = [],
        byKey = {};

    function rankHost(raw, score) {
        var h = _discoveryCleanHost(raw),
            key = h.toLowerCase();
        if (!h) return;
        if (byKey[key]) {
            if (score > byKey[key].score) byKey[key].score = score;
            return;
        }
        var rec = {
            host: h,
            score: score || 0
        };
        byKey[key] = rec;
        ranked.push(rec);
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
                        var c = l3[j] || {},
                            addr = _discoveryIpv4(c.addr || c.address || "");
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
    } catch (e0) {}
    ranked.sort(function(a, b) {
        return b.score - a.score;
    });
    var out = [];
    for (var k = 0; k < ranked.length && out.length < maxHosts; k++)
        out.push(ranked[k].host);
    return out;
}

function _discoveryFallbackHosts(maxHosts, hints) {
    var out = [],
        seen = {},
        prefixes = [],
        prefixSeen = {};

    function addPrefix(ip) {
        ip = _discoveryIpv4(ip);
        if (!ip) return;
        var p = ip.split(".").slice(0, 3).join(".") + ".";
        if (!prefixSeen[p]) {
            prefixSeen[p] = true;
            prefixes.push(p);
        }
    }
    hints = hints || [];
    for (var i = 0; i < hints.length; i++) addPrefix(_discoveryCleanHost(hints[i]));
    if (!prefixes.length) {
        prefixes.push("192.168.1.");
        prefixes.push("192.168.0.");
        prefixes.push("10.0.0.");
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
    if (!m) return {
        host: "",
        port: 0
    };
    return {
        host: _s(m[2]).replace(/^\[|\]$/g, ""),
        port: m[3] ? (Number(m[3]) | 0) : (_s(m[1]).toLowerCase() === "https" ? 443 : 80)
    };
}
// Découverte Jellyfin optimisée Révolution :
// 1) IP réellement vues par la Freebox, actives/reachable en tête ;
// 2) phase HTTP 8096 complète avant tout HTTPS 8920 ;
// 3) HTTPS seulement pour les hôtes où HTTP n'a pas déjà trouvé Jellyfin ;
// 4) fallback /24 depuis .2, borné par le budget maxHosts, en HTTP puis HTTPS ;
// 5) aucun hôte n'est reprobé entre phase initiale et fallback.
// stopOnFirstFound permet au volet compact de s'arrêter au premier résultat ;
// la page de découverte conserve plusieurs serveurs.
// Aucun Timer/probe supplémentaire n'est créé : maxParallel reste le garde-fou CPU/RAM.
// onProgress(percent, details) est optionnel et ne change pas l'API existante.
function start(options, onUpdate, onDone, onProgress) {
    options = options || {};
    var maxHosts = Math.max(1, Math.min(256, Number(options.maxHosts || 96) | 0));
    var maxParallel = Math.max(1, Math.min(4, Number(options.maxParallel || 2) | 0));
    var httpTimeout = Math.max(250, Number(options.httpTimeoutMs || 700));
    var httpsTimeout = Math.max(350, Number(options.httpsTimeoutMs || 1600));
    var fallbackEnabled = options.fallbackSubnetScan !== false;
    var fallbackMaxHosts = Math.max(1, Math.min(maxHosts, Number(options.fallbackMaxHosts || maxHosts) | 0));
    var stopOnFirst = options.stopOnFirstFound === true;
    var fbxCtx = options.fbx || Jellyfin.freeboxContext() || null;
    var localNames = options.localNames && options.localNames.length ?
        options.localNames : ["jellyfin.local", "jellyfin", "media", "nas", "synology"];
    var results = [],
        seenServers = {},
        seenServerIds = {},
        foundHosts = {},
        activeHandles = [],
        probedHttpHosts = {},
        probedHttpsHosts = {},
        progressPlanned = {},
        progressFinished = {},
        progressTotal = 0,
        progressDone = 0;

    // Chaque couple (protocole, hote) n'est comptabilise qu'une fois.
    // Les sondes sautees (doublons / serveur deja trouve) sont egalement
    // soldees pour que 100 % signifie que toutes les phases sont terminees.
    function progressKey(scheme, host) {
        return scheme + "|" + _discoveryCleanHost(host).toLowerCase();
    }
    function planPhase(hosts, scheme) {
        for (var i = 0; i < hosts.length; i++) {
            var h = _discoveryCleanHost(hosts[i]);
            if (!h) continue;
            var key = progressKey(scheme, h);
            if (!progressPlanned[key]) {
                progressPlanned[key] = true;
                progressTotal++;
            }
        }
    }
    function publishProgress(forceDone) {
        if (controller.cancelled || typeof onProgress !== "function") return;
        var pct = forceDone ? 100 : (progressTotal > 0 ? Math.floor(progressDone * 100 / progressTotal) : 0);
        if (!forceDone) pct = Math.min(99, pct);
        try {
            onProgress(pct, { completed: progressDone, total: progressTotal });
        } catch (e0) {} // Un observateur ne doit jamais interrompre le scan.
    }
    function finishProbe(scheme, host) {
        if (controller.cancelled) return;
        var key = progressKey(scheme, host);
        if (!progressPlanned[key] || progressFinished[key]) return;
        progressFinished[key] = true;
        progressDone++;
        publishProgress(false);
    }
    var controller = {
        cancelled: false,
        done: false,
        cancel: function(reason) {
            if (this.cancelled || this.done) return false;
            this.cancelled = true;
            var list = activeHandles.slice(0);
            activeHandles = [];
            for (var i = 0; i < list.length; i++) {
                try {
                    if (list[i] && typeof list[i].cancel === "function") list[i].cancel(reason || "cancelled");
                } catch (e0) {}
            }
            return true;
        },
        isActive: function() {
            return !this.cancelled && !this.done;
        }
    };

    function snapshot() {
        return results.slice(0);
    }

    function dropHandle(handle) {
        if (!handle) return;
        for (var i = activeHandles.length - 1; i >= 0; i--)
            if (activeHandles[i] === handle) {
                activeHandles.splice(i, 1);
                break;
            }
    }

    function finish() {
        if (controller.cancelled || controller.done) return;
        controller.done = true;
        activeHandles = [];
        publishProgress(true);
        if (onDone) onDone(snapshot());
    }

    function addServer(info, base, ping) {
        if (controller.cancelled || !Jellyfin.isValidPublicSystemInfo(info)) return false;
        var normalized = Jellyfin.normalizeServerUrl(base, true),
            key = normalized.toLowerCase();
        var id = _s(info.Id || info.ServerId || "").toLowerCase();
        if (!key || seenServers[key] || (id && seenServerIds[id])) return false;
        seenServers[key] = true;
        if (id) seenServerIds[id] = true;
        var parts = _discoveryBaseParts(normalized),
            hostKey = _discoveryCleanHost(parts.host).toLowerCase();
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
        try {
            Jellyfin.trustLanHost(normalized);
        } catch (e0) {}
        if (onUpdate) onUpdate(snapshot(), rec);
        return true;
    }

    function runPhase(hosts, scheme, port, timeout, skipFound, done) {
        hosts = hosts || [];
        if (!hosts.length || controller.cancelled || (stopOnFirst && results.length)) {
            done();
            return;
        }
        var cursor = 0,
            inFlight = 0,
            ended = false,
            phaseSeen = {};

        function complete() {
            if (!ended) {
                ended = true;
                done();
            }
        }

        function pump() {
            if (ended || controller.cancelled) return;
            if ((stopOnFirst && results.length) || (cursor >= hosts.length && inFlight === 0)) {
                if (inFlight === 0) complete();
                return;
            }
            while (inFlight < maxParallel && cursor < hosts.length && !(stopOnFirst && results.length)) {
                var host = _discoveryCleanHost(hosts[cursor++]),
                    hk = host.toLowerCase();
                var probedMap = (scheme === "https") ? probedHttpsHosts : probedHttpHosts;
                if (!host || phaseSeen[hk] || probedMap[hk]) continue;
                if (skipFound && foundHosts[hk]) {
                    // Requete HTTPS devenue inutile : achevee par exclusion.
                    finishProbe(scheme, host);
                    continue;
                }
                phaseSeen[hk] = true;
                probedMap[hk] = true;
                inFlight++;
                (function(hostValue) {
                    var base = scheme + "://" + hostValue + ":" + port,
                        handle = null;

                    var settled = false;
                    function doneOne() {
                        if (settled) return;
                        settled = true;
                        finishProbe(scheme, hostValue);
                        inFlight = Math.max(0, inFlight - 1);
                        pump();
                    }
                    handle = Jellyfin.probePublicServer(base, timeout,
                        function(info, ping) {
                            dropHandle(handle);
                            if (!controller.cancelled) addServer(info, base, ping);
                            doneOne();
                        },
                        function() {
                            dropHandle(handle);
                            doneOne();
                        });
                    // Protege aussi contre un callback termine synchroniquement.
                    if (!settled && handle) activeHandles.push(handle);
                })(host);
            }
            if (cursor >= hosts.length && inFlight === 0) complete();
        }
        pump();
    }
    var lan = _discoveryLanHosts(fbxCtx, maxHosts),
        initial = [],
        seen = {};
    for (var i = 0; i < lan.length && initial.length < maxHosts; i++)
        _discoveryPushHost(initial, seen, lan[i], maxHosts);
    for (var j = 0; j < localNames.length && initial.length < maxHosts; j++)
        _discoveryPushHost(initial, seen, localNames[j], maxHosts);
    // Calcule le travail maximal prevu AVANT les requetes. La progression
    // reste stable lorsque l'on passe de HTTP a HTTPS et au fallback /24.
    var fallback = fallbackEnabled ? _discoveryFallbackHosts(fallbackMaxHosts, lan) : [];
    planPhase(initial, "http");
    planPhase(initial, "https");
    if (fallbackEnabled) {
        planPhase(fallback, "http");
        planPhase(fallback, "https");
    }
    publishProgress(false);

    runPhase(initial, "http", 8096, httpTimeout, false, function() {
        if (controller.cancelled) return;
        if (stopOnFirst && results.length) {
            finish();
            return;
        }
        runPhase(initial, "https", 8920, httpsTimeout, true, function() {
            if (controller.cancelled) return;
            if (stopOnFirst && results.length) {
                finish();
                return;
            }
            if (!fallbackEnabled) {
                finish();
                return;
            }

            // Le fallback HTTP du sous-réseau est volontairement exécuté même si
            // un serveur a déjà été trouvé dans la table LAN Freebox. Cela évite
            // qu'un second Jellyfin absent/inactif dans fbx.lan.hosts() soit ignoré.
            // Les maps probedHttpHosts/probedHttpsHosts empêchent de retester les
            // mêmes hôtes lorsqu'ils réapparaissent dans cette phase.
            runPhase(fallback, "http", 8096, httpTimeout, false, function() {
                if (controller.cancelled) return;
                if (stopOnFirst && results.length) {
                    finish();
                    return;
                }

                // Deuxième passe exhaustive : un second serveur peut n'écouter
                // qu'en HTTPS 8920. Les hôtes déjà identifiés comme Jellyfin en
                // HTTP sont sautés via foundHosts afin d'éviter un probe inutile.
                runPhase(fallback, "https", 8920, httpsTimeout, true, finish);
            });
        });
    });
    return controller;
}
