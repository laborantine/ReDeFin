.pragma library

/*
 * ReDeFin - SafeLog.js
 *
 * Malgré son nom historique, ce module ne journalise plus rien dans le build
 * public. Il conserve uniquement les primitives de sécurité réellement
 * partagées par le bridge Jellyfin, le playback et le stockage utilisateur :
 *
 * - hash court non cryptographique pour clés/cache anonymisées ;
 * - normalisation des codes d'erreur publics ;
 * - validation des hôtes IPv4/IPv6 locaux ;
 * - registre borné des noms LAN courts explicitement approuvés ;
 * - détection HTTP WAN afin d'interdire l'envoi de secrets en clair.
 *
 * Garder ce fichier léger est important sur Freebox Révolution : l'ancien
 * moteur de redaction/sérialisation de logs était définitivement neutralisé
 * par le verrou production et n'avait plus aucun effet runtime observable.
 */

var _trustedLanHosts = {};
var _trustedLanHostCount = 0;
var MAX_TRUSTED_LAN_HOSTS = 64;

function _lower(value) {
    return String(value || "").toLowerCase();
}

function _startsWith(value, prefix) {
    value = String(value || "");
    prefix = String(prefix || "");
    return value.indexOf(prefix) === 0;
}

function shortHash(value) {
    var s = String(value || "");
    var h = 2166136261;

    for (var i = 0; i < s.length; i++) {
        h ^= s.charCodeAt(i);
        h += (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24);
    }

    var out = (h >>> 0).toString(16);
    while (out.length < 8) out = "0" + out;
    return out.substr(0, 8);
}

/* ------------------------------------------------------------------------- */
/* Détection LAN / WAN                                                       */
/* ------------------------------------------------------------------------- */

function _stripIpv6Zone(host) {
    var h = _lower(host);
    var zone = h.indexOf("%");
    return zone >= 0 ? h.substring(0, zone) : h;
}

function _parseIpv4Literal(host) {
    var h = String(host || "");
    if (!/^\d{1,3}(?:\.\d{1,3}){3}$/.test(h)) return null;

    var raw = h.split(".");
    var out = [];
    for (var i = 0; i < 4; i++) {
        if (raw[i].length > 1 && raw[i].charAt(0) === "0" && raw[i] !== "0")
            return null;

        var n = Number(raw[i]);
        if (!isFinite(n) || Math.floor(n) !== n || n < 0 || n > 255)
            return null;
        out.push(n);
    }
    return out;
}

function isPrivateIpv4Literal(host) {
    var p = _parseIpv4Literal(host);
    if (!p) return false;
    if (p[0] === 10) return true;
    if (p[0] === 127 && p[1] === 0 && p[2] === 0 && p[3] === 1) return true;
    if (p[0] === 169 && p[1] === 254) return true;
    if (p[0] === 172 && p[1] >= 16 && p[1] <= 31) return true;
    if (p[0] === 192 && p[1] === 168) return true;
    return false;
}

function isValidIpv6Literal(host) {
    var h = _stripIpv6Zone(host);
    if (!h || h.indexOf(":") < 0 || !/^[0-9a-f:]+$/.test(h)) return false;
    if (h.indexOf(":::") >= 0) return false;

    var compressed = h.indexOf("::") >= 0;
    if (compressed && h.indexOf("::") !== h.lastIndexOf("::")) return false;

    var halves = compressed ? h.split("::") : [h];
    var count = 0;
    for (var i = 0; i < halves.length; i++) {
        if (!halves[i]) continue;
        var groups = halves[i].split(":");
        for (var j = 0; j < groups.length; j++) {
            if (!/^[0-9a-f]{1,4}$/.test(groups[j])) return false;
            count++;
        }
    }
    return compressed ? count < 8 : count === 8;
}

function isLocalIpv6Literal(host) {
    var h = _stripIpv6Zone(host);
    if (!isValidIpv6Literal(h)) return false;
    if (h === "::1") return true;

    var firstText = h.split(":")[0];
    if (!firstText) return false;
    var first = parseInt(firstText, 16);
    if (!isFinite(first)) return false;

    // fc00::/7 et fe80::/10 uniquement.
    return ((first & 0xfe00) === 0xfc00) || ((first & 0xffc0) === 0xfe80);
}

function _hostWithoutPort(host) {
    host = String(host || "");

    if (_startsWith(host, "[")) {
        var end = host.indexOf("]");
        if (end > 0) return host.substr(1, end - 1);
    }

    var first = host.indexOf(":");
    var last = host.lastIndexOf(":");
    // host:port IPv4/domaine uniquement. Une IPv6 non bracketée contient plusieurs ':'.
    if (first >= 0 && first === last)
        return host.substr(0, first);

    return host;
}

function extractHost(url) {
    var s = String(url || "").trim().toLowerCase();
    var match = /^[a-zA-Z][a-zA-Z0-9+\-.]*:\/\/([^\/?#]+)/.exec(s);
    if (!match || !match[1] || match[1].indexOf("@") >= 0) return "";

    var authority = match[1];
    if (authority.charAt(0) === "[") {
        var end = authority.indexOf("]");
        return end > 1 ? authority.substr(1, end - 1) : "";
    }

    var first = authority.indexOf(":");
    var last = authority.lastIndexOf(":");
    if (first > 0 && first === last)
        authority = authority.substr(0, first);

    while (authority.length && authority.charAt(authority.length - 1) === ".")
        authority = authority.substr(0, authority.length - 1);

    return authority;
}

function _hostKey(value) {
    var h = extractHost(value);
    if (!h) h = _hostWithoutPort(_lower(value));
    while (h.length && h.charAt(h.length - 1) === ".")
        h = h.substring(0, h.length - 1);
    return h.toLowerCase();
}

function _isTrustableShortLanHost(value) {
    var h = _hostKey(value);
    return !!(h && h.indexOf(":") < 0 && h.indexOf(".") < 0
              && /^[a-z0-9][a-z0-9-]{0,62}$/.test(h));
}

function isShortLanHostName(value) {
    return _isTrustableShortLanHost(value);
}

function trustLanHost(value) {
    var h = _hostKey(value);
    // Réservé aux noms LAN courts validés auparavant via /System/Info/Public.
    // Les IP privées, .local et .home.arpa sont déjà locales par définition.
    if (!_isTrustableShortLanHost(h)) return false;
    if (_trustedLanHosts[h] === true) return true;

    if (_trustedLanHostCount >= MAX_TRUSTED_LAN_HOSTS) {
        _trustedLanHosts = {};
        _trustedLanHostCount = 0;
    }

    _trustedLanHosts[h] = true;
    _trustedLanHostCount++;
    return true;
}

function forgetTrustedLanHost(value) {
    var h = _hostKey(value);
    if (!h || _trustedLanHosts[h] !== true) return false;
    delete _trustedLanHosts[h];
    if (_trustedLanHostCount > 0) _trustedLanHostCount--;
    return true;
}

function clearTrustedLanHosts() {
    _trustedLanHosts = {};
    _trustedLanHostCount = 0;
}

function isTrustedLanHost(value) {
    var h = _hostKey(value);
    return !!(h && _trustedLanHosts[h] === true);
}

function isLocalHost(host) {
    var h = _lower(_hostWithoutPort(host || ""));
    while (h.length && h.charAt(h.length - 1) === ".")
        h = h.substring(0, h.length - 1);

    if (!h) return false;
    if (h === "localhost" || h === "127.0.0.1" || h === "::1") return true;
    if (isPrivateIpv4Literal(h) || isLocalIpv6Literal(h)) return true;
    if (/\.local$/.test(h) || /\.home\.arpa$/.test(h)) return true;
    return isTrustedLanHost(h);
}

function normalizeHostLike(value, maxLen) {
    var s = String(value || "").trim().toLowerCase();
    var limit = Math.max(1, Number(maxLen || 8192) | 0);
    if (!s || s.length > limit || /[\r\n\t]/.test(s)) return "";

    var match = /^[a-zA-Z][a-zA-Z0-9+\-.]*:\/\/([^\/?#]+)/.exec(s);
    if (match) s = match[1];
    var cut = s.search(/[\/?#]/);
    if (cut >= 0) s = s.substring(0, cut);
    if (!s || s.indexOf("@") >= 0) return "";

    if (s.charAt(0) === "[") {
        var rb = s.indexOf("]");
        return rb > 1 ? s.substring(1, rb) : "";
    }

    var firstColon = s.indexOf(":");
    var lastColon = s.lastIndexOf(":");
    if (firstColon > 0 && firstColon === lastColon && /^\d+$/.test(s.substring(firstColon + 1)))
        s = s.substring(0, firstColon);
    while (s.length && s.charAt(s.length - 1) === ".")
        s = s.substring(0, s.length - 1);
    return s;
}

function isLanHostLike(value) {
    var host = normalizeHostLike(value, 8192);
    return !!host && isLocalHost(host);
}

function isHttpUrl(url) {
    return _startsWith(_lower(url), "http://");
}

function isWanHttpUrl(url) {
    var host = extractHost(url);
    return isHttpUrl(url) && !isLocalHost(host);
}

/* ------------------------------------------------------------------------- */
/* Codes d'erreur publics                                                    */
/* ------------------------------------------------------------------------- */

function safeErrorCode(value, fallback) {
    var fb = fallback || "network_error";
    var s = "";

    try {
        if (value === undefined || value === null) return fb;

        if (typeof value === "string") {
            s = value;
        } else if (typeof value === "number") {
            return "http_" + String(value | 0);
        } else if (typeof value === "object") {
            if (value.code !== undefined && value.code !== null) s = String(value.code);
            else if (value.status !== undefined && value.status !== null) s = "http_" + String(value.status | 0);
            else if (value.ErrorCode !== undefined && value.ErrorCode !== null) s = String(value.ErrorCode);
            else if (value.errorCode !== undefined && value.errorCode !== null) s = String(value.errorCode);
            else return fb;
        } else {
            return fb;
        }
    } catch (e) {
        return fb;
    }

    s = String(s || "").toLowerCase();

    if (s === "network" || s === "network_error") return "network_error";
    if (s === "timeout") return "timeout";
    if (s === "parse" || s === "parse_error") return "parse_error";
    if (s === "missing_params" || s === "missing_secret") return s;
    if (s === "invalid_response" || s === "invalid_token" || s === "bad_response") return s;
    if (s === "empty" || s === "pending" || s === "ctx" || s === "too_large"
            || s === "insecure_transport" || s === "budget_exhausted"
            || s === "cancelled" || s === "cache_cleared")
        return s;
    if (s === "401" || s === "403" || s === "404") return "http_" + s;

    var match = /^http_?(\d{3})$/.exec(s);
    if (match) return "http_" + match[1];
    if (s.indexOf("param_missing") >= 0) return "param_missing";

    return fb;
}
