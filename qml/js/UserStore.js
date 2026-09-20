// qml/js/UserStore.js
// Autorité unique des profils Jellyfin : Freebox App Settings > mémoire.
// API de base :
//   init(parent), addOrUpdateUser(u), listUsers(serverUrl?), getActive(), setActive(serverUrl,userId),
//   removeUser(serverUrl,userId), clearAll()
// AJOUT prefs par utilisateur :
//   getUserPrefs(serverUrl,userId) -> { ... }
//   saveUserPrefs(serverUrl,userId, patchObj) -> prefs fusionnés
//   getUserPref(serverUrl,userId, key, def)
//   setUserPref(serverUrl,userId, key, value)

.pragma library
.import "jellyfinBridge.js" as JellyfinBridge
.import "SafeLog.js" as SafeLog

var _parent = null;
var _backend = null;

// Ancres stables capturées dès qu'elles sont disponibles.
// Elles empêchent un composant secondaire (ex. AppSettings) de modifier
// indirectement le contexte utilisé par le coffre de session.
var _settingsAnchor = null;
var _legacyFbxAnchor = null;

// ----- Constantes -----
var NS_KEY_USERS  = "redefin_users.usersJson";  // clé logique pour la liste
var NS_KEY_ACTIVE = "redefin_users.activeKey";  // clé logique pour l'utilisateur actif
var NS_KEY_SERVERS = "redefin_users.serversJson"; // serveurs Jellyfin déjà utilisés, même sans profil connecté
var MAX_USERS     = 24;                         // garde-fou
var MAX_USERS_JSON_LEN = 262144;                // garde-fou stockage (~256 KiB)
var MAX_SERVERS  = 24;                         // garde-fou serveurs mémorisés
var MAX_SERVERS_JSON_LEN = 65536;              // garde-fou liste serveurs (~64 KiB)
var MAX_PREFS_JSON_LEN = 32768;                 // garde-fou prefs par utilisateur (~32 KiB)

// Politique de session.
// Le token Jellyfin n'est JAMAIS écrit dans fbx.application.Settings / usersJson.
// Le mode confort le conserve dans un coffre dédié de fbx.application.Settings,
// sous forme obfusquée. L'implémentation Freebox peut journaliser la valeur du
// Setting, mais jamais le token Jellyfin brut. Le mode sécurité maximale purge ce coffre.
var PUBLIC_BUILD_ALLOW_SESSION_VAULT = true;
var DEFAULT_REMEMBER_TOKEN = true;
var MAX_VAULT_JSON_LEN = 131072;

// Cache de session RAM, utilisé en priorité pendant le processus courant.
var _sessionTokens = {};

// Coffre persistant supporté nativement par la Freebox. Il est stocké dans une
// propriété dédiée de fbx.application.Settings. Ce n'est pas un Keychain matériel :
// l'obfuscation vise surtout à empêcher qu'un log Settings contienne un token
// Jellyfin directement exploitable.

// Politique runtime injectée par ShellPage/LoginPage. null signifie : lire l'objet Settings.
var _rememberSessionOverride = null;
var _maximumSecurityOverride = null;


function _scanSettingsObject(obj) {
    var p = obj;
    for (var depth = 0; depth < 10 && p; depth++) {
        try { if (p.settingsRef) return p.settingsRef; } catch(e0) {}
        try { if (p.settings) return p.settings; } catch(e1) {}
        try { if (p.fbx && p.fbx.settings) return p.fbx.settings; } catch(e2) {}
        try { if (p.app && p.app.settings) return p.app.settings; } catch(e3) {}
        try { if (p.application && p.application.settings) return p.application.settings; } catch(e4) {}
        try { p = p.parent; } catch(e5) { p = null; }
    }
    return null;
}

function _findSettingsObject(obj) {
    var found = _scanSettingsObject(obj || _parent);
    if (found) return found;
    return _settingsAnchor;
}

function _settingsBool(name, def) {
    var s = _findSettingsObject(_parent);
    if (!s) return def === true;
    try {
        if (s[name] !== undefined && s[name] !== null)
            return s[name] === true;
    } catch(e) {}
    return def === true;
}


function maximumSecurityModeEnabled() {
    if (_maximumSecurityOverride !== null)
        return _maximumSecurityOverride === true;
    return _settingsBool("maximumSessionSecurity", false);
}

function configureSecurityPolicy(rememberEnabled, maximumSecurityEnabled) {
    var nextMaximum = maximumSecurityEnabled === true;
    var nextRemember = rememberEnabled === true && !nextMaximum;
    var unchanged = (_rememberSessionOverride === nextRemember
                     && _maximumSecurityOverride === nextMaximum);

    _rememberSessionOverride = nextRemember;
    _maximumSecurityOverride = nextMaximum;

    // Idempotence importante sur Freebox : une simple resynchronisation de
    // Settings ne doit jamais réécrire usersJson ou le coffre dans la même pile.
    if (unchanged) return true;

    // `rememberJellyfinSession` est désormais une capacité UI/legacy.
    // La présence du token dans le coffre est une décision PAR PROFIL.
    // Seul le mode sécurité maximale (ou un build sans coffre) a le droit
    // d'effectuer une purge globale.
    if (nextMaximum || PUBLIC_BUILD_ALLOW_SESSION_VAULT !== true)
        purgePersistedTokens();

    return true;
}


function canPersistTokens() {
    // La persistance est désormais un choix PAR PROFIL, matérialisé par la
    // présence ou non de son token dans le coffre. Le booléen global
    // rememberJellyfinSession reste un réglage legacy/capacité UI, mais il ne
    // doit plus empêcher la relecture d'un token déjà explicitement mémorisé.
    // Le mode sécurité maximale reste le verrou global absolu.
    return PUBLIC_BUILD_ALLOW_SESSION_VAULT === true
        && !maximumSecurityModeEnabled()
        && _sessionVaultAvailable();
}


// ============== INIT ==============
function init(parentObj) {
    if (!parentObj) return;

    var previousSettings = _settingsAnchor;
    var foundSettings = null;
    var foundFbx = null;

    try { foundSettings = _scanSettingsObject(parentObj); } catch(e0) {}
    try { foundFbx = _scanFbx(parentObj); } catch(e1) {}

    if (foundSettings)
        _settingsAnchor = foundSettings;

    // Conservée uniquement pour relire/migrer les anciens coffres V2.
    if (foundFbx)
        _legacyFbxAnchor = foundFbx;

    _parent = parentObj;

    // Pas de churn du backend à chaque get/set d'AppSettings si l'objet Settings
    // officiel est le même. Sur CE4100, on évite ainsi des introspections inutiles.
    if (_settingsAnchor !== previousSettings)
        _backend = null;
}

// ============== BACKENDS ==============
// Helpers utils pour introspecter les différentes API possibles
function _tryCall(obj, candidates, args, def) {
    if (!obj) return def;
    for (var i=0; i<candidates.length; i++) {
        var fn = obj[candidates[i]];
        if (typeof fn === "function") {
            try { return fn.apply(obj, args||[]); } catch(e) {}
        }
    }
    return def;
}

// 1) Backend Freebox Application Settings
function _scanFbx(obj) {
    var p = obj;
    for (var depth = 0; depth < 8 && p; depth++) {
        try { if (p.fbx) return p.fbx; } catch(e0) {}
        try { if (p.app && p.app.settings) return p; } catch(e1) {}
        try { if (p.application && p.application.settings) return p; } catch(e2) {}
        try { p = p.parent; } catch(e3) { p = null; }
    }
    return null;
}

function _findFbx(obj) {
    var found = _scanFbx(obj || _parent);
    if (found) return found;
    return _legacyFbxAnchor;
}

function _makeFbxBackend() {
    try {
        // Priorité à l'objet Settings explicitement injecté par l'application.
        // Le backend mémoire n'est utilisé qu'en dernier recours lorsque Settings
        // n'est réellement pas disponible.
        var s = _findSettingsObject(_parent);
        if (!s) {
            var fbx = _findFbx(_parent);
            s =
                (fbx && fbx.app && fbx.app.settings) ||
                (fbx && fbx.application && fbx.application.settings) ||
                null;
        }
        if (!s) return null;

        function mapKey(k) {
            if (k === NS_KEY_USERS) return "usersJson";
            if (k === NS_KEY_SERVERS) return "usersServersJson";
            if (k === NS_KEY_ACTIVE) return "usersActiveKey";
            return k;
        }
        function _get(k, d) {
            var prop = mapKey(k);
            var v = _tryCall(s, ["get","getValue","read","value","readString"], [prop], undefined);
            if (v === undefined) { try { v = s[prop]; } catch(e) {} }
            if (v === undefined || v === null || v === "") return (d !== undefined ? d : "");
            return String(v);
        }
        function _set(k, val) {
            var prop = mapKey(k);
            var ok = _tryCall(s, ["set","setValue","write","writeString"], [prop, String(val)], false);
            if (!ok) { try { s[prop] = String(val); ok = true; } catch(e) {} }
            return ok ? true : false;
        }
        return { type:"fbx", persistent:true, tokenCapable:false, getString:_get, setString:_set };
    } catch(e) { return null; }
}

// 2) Coffre de session persistant Freebox
// ------------------------------------------
function _vaultSettingsObject() {
    var s = _findSettingsObject(_parent);
    if (!s) return null;
    try {
        if (!("usersSessionVaultJson" in s)) return null;
        String(s.usersSessionVaultJson || "{}");
        return s;
    } catch(e0) {}
    return null;
}

function _sessionVaultAvailable() {
    return !!_vaultSettingsObject();
}

function _vaultEntryKey(serverUrl, userId) {
    var srv = _normalizeUrl(serverUrl);
    var uid = String(userId || "");
    if (!srv || !uid) return "";
    return "u#" + SafeLog.shortHash(srv + "|" + uid) + SafeLog.shortHash(uid + "|" + srv);
}

function _vaultDomain() {
    var domain = "";
    try {
        if (Qt && Qt.application)
            domain = String(Qt.application.domain || Qt.application.name || "ReDeFin");
    } catch(e0) {}
    return domain || "ReDeFin";
}

function _vaultInstallDeviceId() {
    var s = _vaultSettingsObject();
    if (!s) return "";

    var id = "";
    try { id = String(s.jellyfinDeviceId || "").toLowerCase(); } catch(e0) { return ""; }
    id = id.replace(/^\s+|\s+$/g, "");

    // Même contrat que clientId.js, dupliqué ici volontairement pour ne pas
    // créer de dépendance circulaire UserStore -> JellyfinBridge -> clientId.
    if (id.length < 20 || id.length > 96) return "";
    if (!/^rdf-[a-z0-9]+(?:-[a-z0-9]+){2,5}$/.test(id)) return "";
    return id;
}

function _vaultStableDeviceScope() {
    var installId = _vaultInstallDeviceId();
    if (!installId) return "";
    return SafeLog.shortHash(
        "rdf-vault-v3|" + _vaultDomain() + "|" + installId
    );
}

function _legacyVaultDeviceScopeForApp(app) {
    var account = "";
    var profile = "";

    try {
        if (app) {
            if (app.accountId !== undefined && app.accountId !== null)
                account = String(app.accountId);
            if (app.profileId !== undefined && app.profileId !== null)
                profile = String(app.profileId);
        }
    } catch(e0) {}

    return SafeLog.shortHash(
        "rdf-vault|" + _vaultDomain() + "|" + account + "|" + profile
    );
}

function _pushUniqueString(arr, value) {
    value = String(value || "");
    if (!value) return;
    for (var i = 0; i < arr.length; i++) {
        if (arr[i] === value) return;
    }
    arr.push(value);
}

function _legacyVaultDeviceScopeCandidates() {
    var out = [];

    // 1) Scope historique normal, lorsque ShellPage/LoginPage fournit encore
    //    l'objet Application Freebox contenant accountId/profileId.
    try {
        var currentFbx = _scanFbx(_parent);
        if (currentFbx)
            _pushUniqueString(out, _legacyVaultDeviceScopeForApp(currentFbx));
    } catch(e0) {}

    // 2) Dernier contexte Freebox fiable mémorisé avant qu'un singleton comme
    //    AppSettings ne devienne l'appelant courant.
    try {
        if (_legacyFbxAnchor)
            _pushUniqueString(out, _legacyVaultDeviceScopeForApp(_legacyFbxAnchor));
    } catch(e1) {}

    // 3) Scope V2 accidentel possible lorsque l'ancien code était appelé depuis
    //    AppSettings sans accountId/profileId.
    _pushUniqueString(out, _legacyVaultDeviceScopeForApp(null));

    return out;
}

function _vaultXorKeyV3(serverUrl, userId, nonce) {
    var scope = _vaultStableDeviceScope();
    if (!scope) return "";

    return "ReDeFinSessionVaultV3:"
        + scope
        + ":" + SafeLog.shortHash(_normalizeUrl(serverUrl))
        + ":" + SafeLog.shortHash(String(userId || ""))
        + ":" + String(nonce || "");
}

function _vaultXorKeyV2WithScope(serverUrl, userId, nonce, legacyScope) {
    if (!legacyScope) return "";

    return "ReDeFinSessionVaultV2:"
        + legacyScope
        + ":" + SafeLog.shortHash(_normalizeUrl(serverUrl))
        + ":" + SafeLog.shortHash(String(userId || ""))
        + ":" + String(nonce || "");
}

function _vaultNonce(token) {
    var seed = String(Date.now()) + "|" + String(Math.random()) + "|" + SafeLog.shortHash(token || "");
    return SafeLog.shortHash(seed);
}

function _vaultEncodeWithKey(prefix, key, token) {
    var src = _safeStoredToken(token);
    if (!src || !key) return "";

    var hex = "";
    for (var i = 0; i < src.length; i++) {
        var v = (src.charCodeAt(i) & 0xff)
              ^ (key.charCodeAt(i % key.length) & 0xff)
              ^ ((i * 29 + 17) & 0xff);
        var h = (v & 0xff).toString(16);
        if (h.length < 2) h = "0" + h;
        hex += h;
    }

    var check = SafeLog.shortHash(key + "|" + src + "|" + src.length);
    return prefix + ":" + check + ":" + hex;
}

function _vaultDecodeWithKey(expected, hex, key) {
    if (!key || !hex || (hex.length % 2) !== 0) return "";

    var out = "";
    try {
        for (var i = 0; i < hex.length; i += 2) {
            var n = parseInt(hex.substr(i, 2), 16);
            if (!isFinite(n) || isNaN(n)) return "";

            var pos = i / 2;
            var v = n
                  ^ (key.charCodeAt(pos % key.length) & 0xff)
                  ^ ((pos * 29 + 17) & 0xff);
            out += String.fromCharCode(v & 0xff);
        }
    } catch(e0) {
        return "";
    }

    out = _safeStoredToken(out);
    if (!out) return "";

    var actual = SafeLog.shortHash(key + "|" + out + "|" + out.length).toLowerCase();
    return actual === String(expected || "").toLowerCase() ? out : "";
}

function _vaultEncodeToken(serverUrl, userId, token) {
    var src = _safeStoredToken(token);
    if (!src) return "";

    var nonce = _vaultNonce(src);
    var key = _vaultXorKeyV3(serverUrl, userId, nonce);
    if (!key) return "";

    return _vaultEncodeWithKey("v3:" + nonce, key, src);
}

function _vaultDecodeToken(serverUrl, userId, encoded) {
    var raw = String(encoded || "");
    var m = /^v3:([0-9a-f]{8}):([0-9a-f]{8}):([0-9a-f]+)$/i.exec(raw);
    if (!m) return "";

    var key = _vaultXorKeyV3(serverUrl, userId, m[1]);
    return _vaultDecodeWithKey(m[2], m[3], key);
}

function _vaultDecodeLegacyV2Token(serverUrl, userId, encoded) {
    var raw = String(encoded || "");
    var m = /^v2:([0-9a-f]{8}):([0-9a-f]{8}):([0-9a-f]+)$/i.exec(raw);
    if (!m) return "";

    var scopes = _legacyVaultDeviceScopeCandidates();
    for (var i = 0; i < scopes.length; i++) {
        var key = _vaultXorKeyV2WithScope(serverUrl, userId, m[1], scopes[i]);
        var token = _vaultDecodeWithKey(m[2], m[3], key);
        if (token) return token;
    }

    return "";
}

function _readVaultMap() {
    var s = _vaultSettingsObject();
    if (!s) return {};
    var raw = "";
    try { raw = String(s.usersSessionVaultJson || "{}"); } catch(e0) { return {}; }
    if (!raw || raw.length > MAX_VAULT_JSON_LEN) {
        try { if (String(s.usersSessionVaultJson || "{}") !== "{}") s.usersSessionVaultJson = "{}"; } catch(e1) {}
        return {};
    }
    try {
        var map = JSON.parse(raw);
        if (!map || typeof map !== "object" || Array.isArray(map)) return {};
        return map;
    } catch(e2) {
        try { if (String(s.usersSessionVaultJson || "{}") !== "{}") s.usersSessionVaultJson = "{}"; } catch(e3) {}
        return {};
    }
}

function _writeVaultMap(map) {
    var s = _vaultSettingsObject();
    if (!s) return false;
    try {
        var raw = JSON.stringify(map || {});
        if (!raw || raw.length > MAX_VAULT_JSON_LEN) raw = "{}";
        if (String(s.usersSessionVaultJson || "{}") === raw)
            return true;
        s.usersSessionVaultJson = raw;
        return true;
    } catch(e0) {}
    return false;
}

function _persistentTokenFor(serverUrl, userId) {
    if (PUBLIC_BUILD_ALLOW_SESSION_VAULT !== true || maximumSecurityModeEnabled())
        return "";

    var k = _vaultEntryKey(serverUrl, userId);
    if (!k) return "";

    var map = _readVaultMap();
    var encoded = String(map[k] || "");
    if (!encoded) return "";

    // Format courant stable.
    var token = _vaultDecodeToken(serverUrl, userId, encoded);
    if (token) return token;

    // Migration douce depuis les coffres V2 :
    // - scope normal accountId/profileId
    // - scope V2 accidentel sans ces identifiants
    token = _vaultDecodeLegacyV2Token(serverUrl, userId, encoded);
    if (token) {
        var migrated = _vaultEncodeToken(serverUrl, userId, token);
        if (migrated && migrated !== encoded) {
            map[k] = migrated;
            _writeVaultMap(map);
        }
        return token;
    }

    // Ne jamais supprimer une entrée uniquement parce que le contexte courant
    // n'a pas permis de la décoder. Une reconnexion réussie l'écrasera proprement.
    return "";
}

function _persistTokenToVault(serverUrl, userId, token) {
    if (!canPersistTokens() || _isWanHttpUrl(serverUrl)) return false;
    var k = _vaultEntryKey(serverUrl, userId);
    var encoded = _vaultEncodeToken(serverUrl, userId, token);
    if (!k || !encoded) return false;
    var map = _readVaultMap();
    map[k] = encoded;
    var count = 0;
    for (var p in map) {
        if (Object.prototype.hasOwnProperty.call(map, p) && ++count > MAX_USERS) {
            map = {};
            map[k] = encoded;
            break;
        }
    }
    return _writeVaultMap(map);
}

function _clearPersistentToken(serverUrl, userId) {
    var k = _vaultEntryKey(serverUrl, userId);
    if (!k) return false;
    var map = _readVaultMap();
    if (!Object.prototype.hasOwnProperty.call(map, k)) return false;
    delete map[k];
    _writeVaultMap(map);
    return true;
}

function _clearPersistentVault() {
    var s = _vaultSettingsObject();
    if (!s) return false;
    try {
        if (String(s.usersSessionVaultJson || "{}") === "{}")
            return false;
        s.usersSessionVaultJson = "{}";
        return true;
    } catch(e0) {}
    return false;
}


// 4) Backend mémoire (non persistant)
var _mem = { usersJson: "[]", serversJson: "[]", activeKey: "" };
function _makeMemoryBackend() {
    return {
        type: "mem",
        persistent: false,
        tokenCapable: false,
        getString: function(k, d) {
            var v = (k === NS_KEY_USERS) ? _mem.usersJson
                  : (k === NS_KEY_SERVERS) ? _mem.serversJson
                  : (k === NS_KEY_ACTIVE) ? _mem.activeKey
                  : "";
            if (v === undefined || v === null || v === "") return (d || "");
            return String(v);
        },
        setString: function(k, v) {
            var val = String(v || "");
            if (k === NS_KEY_USERS) _mem.usersJson = val;
            else if (k === NS_KEY_SERVERS) _mem.serversJson = val;
            else if (k === NS_KEY_ACTIVE) _mem.activeKey = val;
            return true;
        }
    };
}

// Backend choisi, avec priorité dynamique vers Freebox.
function _getBackend() {
    // Toujours retenter le backend Freebox afin de pouvoir passer du fallback RAM
    // au stockage officiel dès que le contexte fbx devient disponible.
    var b = _makeFbxBackend();
    if (b) {
        _backend = b;
        return b;
    }
    if (_backend) return _backend;
    return (_backend = _makeMemoryBackend());
}

// ============== LECTURE / ÉCRITURE ==============
function _readUsersArr() {
    var b = _getBackend();
    var raw = b.getString(NS_KEY_USERS, "[]");

    if (raw && raw.length > MAX_USERS_JSON_LEN) {
        b.setString(NS_KEY_USERS, "[]");
        return [];
    }

    try {
        var arr = JSON.parse(raw || "[]");
        if (!Array.isArray(arr)) arr = [];
        if (arr.length > MAX_USERS) arr = arr.slice(0, MAX_USERS);

        var safe = _sanitizeStoredUsersList(arr, true);
        var safeRaw = JSON.stringify(safe);

        // Migration immédiate : tout ancien token présent dans usersJson est
        // déplacé vers le coffre (si autorisé) puis retiré du backend de profils.
        if (safeRaw !== JSON.stringify(arr))
            b.setString(NS_KEY_USERS, safeRaw);

        // Le backend reste sans token. L'overlay réinjecte la copie RAM ou coffre.
        return _overlaySessionTokens(safe);
    } catch(e) {
        try { b.setString(NS_KEY_USERS, "[]"); } catch(e2) {}
        return [];
    }
}
function _writeUsersArr(arr) {
    var b = _getBackend();
    try {
        arr = _sanitizeStoredUsersList(arr || [], false);
        if (arr.length > MAX_USERS) arr = arr.slice(0, MAX_USERS);

        var raw = JSON.stringify(arr);
        if (raw.length > MAX_USERS_JSON_LEN)
            raw = "[]";

        var current = b.getString(NS_KEY_USERS, "[]");
        if (String(current || "[]") !== raw)
            b.setString(NS_KEY_USERS, raw);
    } catch(e) { /* no-op */ }
}

function _serverLabelFromUrl(serverUrl) {
    var h = _hostPartFromUrlLike(serverUrl);
    return h || "Jellyfin";
}

function _sanitizeServerEntry(v, fillMissingLastUsed) {
    if (!v) return null;
    var srv = _normalizeUrl(v.serverUrl || v.url || "");
    if (!srv) return null;

    var name = String(v.name || v.serverName || "");
    if (!name) name = _serverLabelFromUrl(srv);
    if (name.length > 96) name = name.substr(0, 96);

    var version = String(v.version || "");
    if (version.length > 48) version = version.substr(0, 48);

    var id = String(v.id || v.serverId || "");
    if (id.length > 96) id = id.substr(0, 96);

    var last = Number(v.lastUsed || 0) || 0;
    if (!last && fillMissingLastUsed !== false) last = _now();

    return {
        serverUrl: srv,
        url: srv,
        name: name,
        version: version,
        id: id,
        lastUsed: last
    };
}

function _readServersArr() {
    var b = _getBackend();
    var raw = b.getString(NS_KEY_SERVERS, "[]");
    if (raw && raw.length > MAX_SERVERS_JSON_LEN)
        return [];

    try {
        var arr = JSON.parse(raw || "[]");
        if (!Array.isArray(arr)) arr = [];

        var out = [];
        var seen = {};
        for (var i = 0; i < arr.length && out.length < MAX_SERVERS; i++) {
            var it = _sanitizeServerEntry(arr[i]);
            if (!it || seen[it.serverUrl]) continue;
            seen[it.serverUrl] = true;
            out.push(it);
        }
        out.sort(function(a, b) { return (b.lastUsed || 0) - (a.lastUsed || 0); });
        return out;
    } catch(e) { return []; }
}

function _writeServersArr(arr) {
    var b = _getBackend();
    try {
        arr = arr || [];
        var out = [];
        var seen = {};
        for (var i = 0; i < arr.length && out.length < MAX_SERVERS; i++) {
            var it = _sanitizeServerEntry(arr[i]);
            if (!it || seen[it.serverUrl]) continue;
            seen[it.serverUrl] = true;
            out.push(it);
        }
        out.sort(function(a, b) { return (b.lastUsed || 0) - (a.lastUsed || 0); });

        var raw = JSON.stringify(out);
        if (raw.length > MAX_SERVERS_JSON_LEN)
            raw = "[]";
        var current = b.getString(NS_KEY_SERVERS, "[]");
        if (String(current || "[]") !== raw)
            b.setString(NS_KEY_SERVERS, raw);
    } catch(e) {}
}

function addOrUpdateServer(v) {
    var rec = _sanitizeServerEntry(v);
    if (!rec) return false;

    var list = _readServersArr();
    var found = false;
    for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].serverUrl === rec.serverUrl) {
            list[i].name = rec.name || list[i].name || _serverLabelFromUrl(rec.serverUrl);
            list[i].version = rec.version || list[i].version || "";
            list[i].id = rec.id || list[i].id || "";
            list[i].url = rec.serverUrl;
            list[i].lastUsed = _now();
            found = true;
            break;
        }
    }
    if (!found) {
        rec.lastUsed = _now();
        list.push(rec);
    }
    _writeServersArr(list);
    return true;
}


function listServers() {
    return _readServersArr();
}

function _removeServerOnly(serverUrl) {
    var srv = _normalizeUrl(serverUrl);
    if (!srv) return;
    var list = _readServersArr().filter(function(it) {
        return it && it.serverUrl !== srv;
    });
    _writeServersArr(list);
}

function removeServer(serverUrl) {
    var srv = _normalizeUrl(serverUrl);
    if (!srv) return false;
    _removeServerOnly(srv);
    return true;
}


function _getActiveKey() {
    var b = _getBackend();
    return b.getString(NS_KEY_ACTIVE, "");
}
function _setActiveKey(k) {
    var b = _getBackend();
    var next = String(k || "");
    var current = b.getString(NS_KEY_ACTIVE, "");
    if (String(current || "") !== next)
        b.setString(NS_KEY_ACTIVE, next);
}

// ============== HELPERS MÉTIER ==============
function _now() { return Date.now(); }

function _hostPartFromUrlLike(v) {
    var s = String(v || "").trim();
    s = s.replace(/^https?:\/\//i, "");
    s = s.split("/")[0].split("?")[0].split("#")[0];
    return s;
}

function _normalizeUrl(u) {
    try {
        if (JellyfinBridge && typeof JellyfinBridge.normalizeServerUrl === "function")
            return String(JellyfinBridge.normalizeServerUrl(u || "", false) || "");
    } catch(e0) {}
    return "";
}

function _isWanHttpUrl(u) {
    var s = _normalizeUrl(u);
    if (!s) return false;
    try {
        if (JellyfinBridge && typeof JellyfinBridge.isWanHttpUrl === "function")
            return JellyfinBridge.isWanHttpUrl(s) === true;
    } catch(e0) {}
    // Repli fail-closed : si la politique centrale devenait indisponible,
    // aucun token n'est persisté sur une URL HTTP non qualifiée.
    return /^http:\/\//i.test(s);
}

function isWanHttpUrl(u) { return _isWanHttpUrl(u); }




function _key(srv, uid) { return _normalizeUrl(srv) + "|" + (uid || ""); }

function _sessionTokenKey(srv, uid) {
    var server = _normalizeUrl(srv);
    var user = String(uid || "");
    return (server && user) ? (server + "|" + user) : "";
}

function _setSessionToken(srv, uid, token) {
    var key = _sessionTokenKey(srv, uid);
    if (!key) return false;
    var safe = _safeStoredToken(token);
    if (!safe) {
        delete _sessionTokens[key];
        return false;
    }
    _sessionTokens[key] = safe;
    return true;
}

function _sessionTokenFor(srv, uid) {
    var key = _sessionTokenKey(srv, uid);
    return key && _sessionTokens[key] ? String(_sessionTokens[key]) : "";
}

function _clearSessionToken(srv, uid) {
    var key = _sessionTokenKey(srv, uid);
    if (!key) return false;
    var existed = !!_sessionTokens[key];
    delete _sessionTokens[key];
    return existed;
}

function _clearAllSessionTokens() {
    _sessionTokens = {};
}

function _clearSessionTokensForServer(serverUrl) {
    var srv = _normalizeUrl(serverUrl);
    if (!srv) return;
    var prefix = srv + "|";
    for (var key in _sessionTokens) {
        if (!Object.prototype.hasOwnProperty.call(_sessionTokens, key)) continue;
        if (key.indexOf(prefix) === 0)
            delete _sessionTokens[key];
    }
}

function _overlaySessionTokens(list) {
    list = list || [];
    var vaultAllowed = canPersistTokens();
    for (var i = 0; i < list.length; i++) {
        var u = list[i];
        if (!u) continue;

        var token = _sessionTokenFor(u.serverUrl, u.userId);
        var fromVault = false;

        // Le coffre est la source de vérité du choix "Mémoriser ce profil".
        // main.qml des anciennes versions peut avoir réécrit remember:false dans
        // usersJson parce que le token brut n'y figure plus. Cela ne doit pas
        // invalider une session que l'utilisateur a explicitement mémorisée.
        // Si la case a été décochée, addOrUpdateUser() a déjà supprimé l'entrée
        // du coffre, donc cette récupération ne peut pas ressusciter la session.
        if (!token && vaultAllowed) {
            token = _persistentTokenFor(u.serverUrl, u.userId);
            if (token) {
                fromVault = true;
                _setSessionToken(u.serverUrl, u.userId, token);
            }
        }

        u.accessToken = token || "";
        u.remember = !!(vaultAllowed && token && (fromVault || u.remember === true));
    }
    return list;
}

function _legacyActiveKey(srv, uid) { return _key(srv, uid); }
function _activeKey(srv, uid) {
    var raw = _normalizeUrl(srv) + "|" + String(uid || "");
    if (!raw || raw === "|") return "";
    return "active#" + SafeLog.shortHash(raw);
}
function _matchesActiveKey(storedKey, srv, uid) {
    storedKey = String(storedKey || "");
    if (!storedKey) return false;
    var ak = _activeKey(srv, uid);
    if (ak && storedKey === ak) return true;
    return storedKey === _legacyActiveKey(srv, uid);
}
function _listKeyIdx(list, srv, uid) {
    var k = _key(srv, uid);
    for (var i=0;i<list.length;i++) if (_key(list[i].serverUrl, list[i].userId) === k) return i;
    return -1;
}

// ============== HELPERS AVATAR ==============
// Avatar utilisateur Jellyfin:
// - l'URL animée est canonique et sans token, pour préserver les GIF animés.
// - les variantes statiques sont réservées aux vues qui demandent explicitement une image fixe.
// - ne jamais ajouter format=jpg sur l'URL animée, sinon Jellyfin peut casser la boucle GIF.

function animatedAvatarUrl(serverUrl, userId, imageTag) {
    var srv = _normalizeUrl(serverUrl);
    var uid = String(userId || "");
    var tag = String(imageTag || "");
    if (!srv || !uid || !tag) return "";
    return srv + "/UserImage?UserId=" + encodeURIComponent(uid)
         + "&tag=" + encodeURIComponent(tag);
}


function staticAvatarUrl(serverUrl, userId, imageTag) {
    var srv = _normalizeUrl(serverUrl);
    var uid = String(userId || "");
    var tag = String(imageTag || "");
    if (!srv || !uid || !tag) return "";

    // /UserImage est volontairement sans paramètres de redimensionnement :
    // Qt/Jellyfin conserve ainsi un contrat d'URL simple et stable.
    return srv + "/UserImage?UserId=" + encodeURIComponent(uid)
         + "&tag=" + encodeURIComponent(tag)
         + "&format=jpg";
}


// ============== HELPERS SÉCURITÉ / STOCKAGE ==============

function _hasOwn(obj, key) {
    try { return !!(obj && Object.prototype.hasOwnProperty.call(obj, key)); } catch(e) {}
    try { return !!(obj && obj.hasOwnProperty && obj.hasOwnProperty(key)); } catch(e2) {}
    return false;
}

function _shouldRememberUser(u, previousRemember) {
    if (!canPersistTokens()) return false;
    if (!u) return previousRemember === true;
    if (_hasOwn(u, "remember"))
        return u.remember === true;
    if (_hasOwn(u, "accessToken") && String(u.accessToken || "").length > 0)
        return DEFAULT_REMEMBER_TOKEN === true;
    return previousRemember === true;
}

function _safeStoredToken(value) {
    var token = String(value || "");
    if (!token || token.length > 4096) return "";
    if (/[\u0000-\u0020\u007f]/.test(token)) return "";
    return token;
}


function _isSensitivePrefsKey(key) {
    var k = String(key || "").toLowerCase().replace(/[^a-z0-9]/g, "");
    return k === "token" || k === "accesstoken" || k === "lastaccesstoken" ||
           k === "refreshtoken" || k === "apikey" || k === "xapikey" ||
           k === "xembytoken" || k === "xmediabrowsertoken" ||
           k === "authorization" || k === "cookie" || k === "setcookie" ||
           k === "password" || k === "secret" || k === "playsessionid";
}

function _sanitizePrefsValue(value, depth) {
    depth = Number(depth || 0);
    if (depth > 3) return undefined;

    var t = typeof value;
    if (value === null || t === "boolean" || t === "number") return value;
    if (t === "string") return value.length > 512 ? value.substr(0, 512) : value;

    if (Object.prototype.toString.call(value) === "[object Array]") {
        var arr = [];
        for (var i = 0; i < value.length && i < 24; i++) {
            var av = _sanitizePrefsValue(value[i], depth + 1);
            if (av !== undefined) arr.push(av);
        }
        return arr;
    }

    if (value && t === "object") {
        var out = {};
        var count = 0;
        for (var k in value) {
            try { if (!Object.prototype.hasOwnProperty.call(value, k)) continue; } catch(e0) { continue; }
            var key = String(k || "");
            if (!key || key.length > 80 || _isSensitivePrefsKey(key)) continue;
            if (++count > 48) break;
            var child = _sanitizePrefsValue(value[k], depth + 1);
            if (child !== undefined) out[key] = child;
        }
        return out;
    }

    return undefined;
}

function _sanitizePrefsObject(prefs) {
    if (!prefs || typeof prefs !== "object") return {};
    var out = _sanitizePrefsValue(prefs, 0);
    if (!out || typeof out !== "object" || Object.prototype.toString.call(out) === "[object Array]")
        return {};
    try {
        var raw = JSON.stringify(out);
        if (!raw || raw.length > MAX_PREFS_JSON_LEN) return {};
    } catch(e0) {
        return {};
    }
    return out;
}

function _mergePrefs(base, patch) {
    base = _sanitizePrefsObject(base);
    patch = _sanitizePrefsObject(patch);

    var merged = {};
    var p;
    for (p in base) merged[p] = base[p];
    for (p in patch) merged[p] = patch[p];

    return _sanitizePrefsObject(merged);
}


function _sanitizeStoredUserEntry(u, allowRemember, migrateLegacyToken) {
    if (!u || typeof u !== "object") return null;

    var serverUrl = _normalizeUrl(u.serverUrl || "");
    var userId = String(u.userId || "");
    if (!serverUrl || !userId) return null;
    if (userId.length > 160) userId = userId.substr(0, 160);

    var rawToken = _safeStoredToken(u.accessToken);
    var requestedRemember = false;

    if (allowRemember === true && !_isWanHttpUrl(serverUrl)) {
        if (_hasOwn(u, "remember"))
            requestedRemember = (u.remember === true);
        else if (rawToken)
            requestedRemember = (DEFAULT_REMEMBER_TOKEN === true);
    }

    // Migration d'une ancienne version : le token brut est déplacé vers le
    // coffre puis supprimé de usersJson lors de la réécriture.
    if (migrateLegacyToken === true && rawToken && requestedRemember)
        _persistTokenToVault(serverUrl, userId, rawToken);

    var userName = String(u.userName || "");
    if (userName.length > 192) userName = userName.substr(0, 192);
    var imageTag = String(u.imageTag || "");
    if (imageTag.length > 256) imageTag = imageTag.substr(0, 256);

    // Depuis 09/2026, un tag d'avatar persistant n'est considéré fiable que
    // s'il porte explicitement l'ID du profil auquel il appartient. Les anciens
    // stores n'avaient pas cette information : leur tag est conservé pour
    // migration, mais LoginPage le revalide auprès de Jellyfin avant usage.
    var imageTagOwnerId = String(u.imageTagOwnerId || "");
    if (imageTagOwnerId.length > 160) imageTagOwnerId = imageTagOwnerId.substr(0, 160);
    if (!imageTag || imageTagOwnerId !== userId) imageTagOwnerId = "";

    return {
        serverUrl: serverUrl,
        userId: userId,
        userName: userName,
        accessToken: "",
        imageTag: imageTag,
        imageTagOwnerId: imageTagOwnerId,
        remember: requestedRemember,
        lastUsed: Number(u.lastUsed || 0) || 0,
        prefs: _sanitizePrefsObject(u.prefs)
    };
}

function _sanitizeStoredUsersList(arr, migrateLegacyToken) {
    var out = [];
    arr = arr || [];
    var migrate = migrateLegacyToken === true;

    for (var i = 0; i < arr.length && out.length < MAX_USERS; i++) {
        var u = _sanitizeStoredUserEntry(arr[i], canPersistTokens(), migrate);
        if (u && u.serverUrl && u.userId)
            out.push(u);
    }
    return out;
}

function sanitizeUsersJsonForStorage(value, maximumSecurityEnabled) {
    var raw = String(value || "[]");
    if (!raw || raw.length > MAX_USERS_JSON_LEN) return "[]";

    var arr = [];
    try { arr = JSON.parse(raw); } catch(e0) { arr = []; }
    if (!Array.isArray(arr)) arr = [];

    var out = [];
    var allowRemember = maximumSecurityEnabled !== true;
    for (var i = 0; i < arr.length && out.length < MAX_USERS; i++) {
        var u = _sanitizeStoredUserEntry(arr[i], allowRemember, false);
        if (u && u.serverUrl && u.userId) out.push(u);
    }

    try {
        var safe = JSON.stringify(out);
        return safe.length <= MAX_USERS_JSON_LEN ? safe : "[]";
    } catch(e1) {
        return "[]";
    }
}

function sanitizeServersJsonForStorage(value) {
    var raw = String(value || "[]");
    if (!raw || raw.length > MAX_SERVERS_JSON_LEN) return "[]";

    var arr = [];
    try { arr = JSON.parse(raw); } catch(e0) { arr = []; }
    if (!Array.isArray(arr)) arr = [];

    var out = [];
    var seen = {};
    for (var i = 0; i < arr.length && out.length < MAX_SERVERS; i++) {
        var it = _sanitizeServerEntry(arr[i], false);
        if (!it || seen[it.serverUrl]) continue;
        seen[it.serverUrl] = true;
        out.push(it);
    }

    try {
        var safe = JSON.stringify(out);
        return safe.length <= MAX_SERVERS_JSON_LEN ? safe : "[]";
    } catch(e1) {
        return "[]";
    }
}

function sanitizeStoredUsers() {
    var list = _sanitizeStoredUsersList(_readUsersArr(), false);
    _writeUsersArr(list);
    return _overlaySessionTokens(list);
}

function purgePersistedTokens() {
    var vaultChanged = _clearPersistentVault();
    var b = _getBackend();
    var raw = b.getString(NS_KEY_USERS, "[]");
    var arr = [];
    try { arr = JSON.parse(raw || "[]"); } catch(e0) { arr = []; }
    if (!Array.isArray(arr)) arr = [];

    var changed = false;
    for (var i = 0; i < arr.length; i++) {
        if (!arr[i] || typeof arr[i] !== "object") continue;
        if (String(arr[i].accessToken || "").length > 0 || arr[i].remember === true)
            changed = true;
        arr[i].accessToken = "";
        arr[i].remember = false;
    }
    if (changed) {
        try {
            var cleaned = JSON.stringify(arr);
            b.setString(NS_KEY_USERS, cleaned.length <= MAX_USERS_JSON_LEN ? cleaned : "[]");
        } catch(e1) {}
    }
    return changed || vaultChanged;
}

// ============== API (UTILISATEURS) ==============
function addOrUpdateUser(u) {
    if (!u) return;
    var srv = _normalizeUrl(u.serverUrl);
    var uid = String(u.userId || "");
    if (!srv || !uid) return;

    var tokenTransportAllowed = !_isWanHttpUrl(srv);
    var hasTokenField = _hasOwn(u, "accessToken");
    var incomingToken = hasTokenField ? _safeStoredToken(u.accessToken) : "";

    if (tokenTransportAllowed && hasTokenField) {
        if (incomingToken) _setSessionToken(srv, uid, incomingToken);
        else _clearSessionToken(srv, uid);
    }

    addOrUpdateServer({
        serverUrl: srv,
        name: u.serverName || u.name || "",
        version: u.version || "",
        id: u.serverId || u.id || ""
    });

    var list = _readUsersArr();
    var idx = _listKeyIdx(list, srv, uid);
    var cur = idx >= 0 ? (list[idx] || {}) : {};
    var previousRemember = cur.remember === true;
    var nextRemember = tokenTransportAllowed && _shouldRememberUser(u, previousRemember);

    if (hasTokenField) {
        if (incomingToken && nextRemember)
            _persistTokenToVault(srv, uid, incomingToken);
        else
            _clearPersistentToken(srv, uid);
    } else if (_hasOwn(u, "remember") && u.remember !== true) {
        _clearPersistentToken(srv, uid);
    }

    var hasImageTagField = _hasOwn(u, "imageTag");
    var incomingImageTag = hasImageTagField ? String(u.imageTag || "") : "";
    if (incomingImageTag.length > 256) incomingImageTag = incomingImageTag.substr(0, 256);
    var incomingImageOwner = String(u.imageTagOwnerId || "");
    if (!incomingImageTag || incomingImageOwner !== uid) incomingImageOwner = "";

    if (idx >= 0) {
        cur.serverUrl = srv;
        cur.userId = uid;
        cur.userName = (u.userName !== undefined ? (u.userName || "") : (cur.userName || ""));
        if (hasImageTagField) {
            cur.imageTag = incomingImageTag;
            cur.imageTagOwnerId = incomingImageOwner;
        }
        cur.remember = nextRemember;
        cur.accessToken = "";
        cur.lastUsed = _now();
        if (u.prefs !== undefined)
            cur.prefs = _mergePrefs(cur.prefs, u.prefs);
        list[idx] = cur;
    } else {
        list.push({
            serverUrl: srv,
            userId: uid,
            userName: u.userName || "",
            accessToken: "",
            imageTag: incomingImageTag,
            imageTagOwnerId: incomingImageOwner,
            remember: nextRemember,
            lastUsed: _now(),
            prefs: _sanitizePrefsObject(u.prefs)
        });
    }

    list.sort(function(a,b){ return (b.lastUsed||0) - (a.lastUsed||0); });
    if (list.length > MAX_USERS) list = list.slice(0, MAX_USERS);
    _writeUsersArr(list);
    _setActiveKey(_activeKey(srv, uid));
}


// Met à jour uniquement les métadonnées d'avatar sans modifier lastUsed,
// l'ordre des profils ni la politique de persistance du token. Cette API est
// utilisée par LoginPage après validation de /Users/Public ou /Users/{id}.
function updateUserAvatarMetadata(serverUrl, userId, userName, imageTag) {
    var srv = _normalizeUrl(serverUrl);
    var uid = String(userId || "");
    if (!srv || !uid) return false;

    var tag = String(imageTag || "");
    if (tag.length > 256) tag = tag.substr(0, 256);
    var name = String(userName || "");
    if (name.length > 192) name = name.substr(0, 192);

    var list = _readUsersArr();
    var idx = _listKeyIdx(list, srv, uid);
    if (idx < 0) return false;

    var cur = list[idx] || {};
    var changed = false;
    if (name && name !== String(cur.userName || "")) {
        cur.userName = name;
        changed = true;
    }
    if (tag !== String(cur.imageTag || "")) {
        cur.imageTag = tag;
        changed = true;
    }

    // Même si le tag n'a pas changé, un ancien enregistrement sans propriétaire
    // doit être marqué comme validé après confirmation serveur. Si aucun avatar
    // n'existe, imageTag reste vide et aucun /UserImage ne sera construit.
    var owner = tag ? uid : "";
    if (owner !== String(cur.imageTagOwnerId || "")) {
        cur.imageTagOwnerId = owner;
        changed = true;
    }

    if (!changed) return true;
    list[idx] = cur;
    _writeUsersArr(list);
    return true;
}

function setActive(serverUrl, userId) {
    var srv = _normalizeUrl(serverUrl);
    var uid = String(userId || "");

    // Ne jamais écrire une clé active "serveur|" sans utilisateur.
    // La liste des serveurs utilisés est gérée par addOrUpdateServer()/listServers().
    if (!srv || !uid)
        return;

    var list = _readUsersArr();
    var idx  = _listKeyIdx(list, srv, uid);
    if (idx >= 0) list[idx].lastUsed = _now();
    list.sort(function(a,b){ return (b.lastUsed||0) - (a.lastUsed||0); });
    _writeUsersArr(list);
    _setActiveKey(_activeKey(srv, uid));
}

function getActive() {
    var list = _readUsersArr();
    var key  = _getActiveKey();
    if (key && key.length) {
        for (var i=0; i<list.length; i++) {
            if (_matchesActiveKey(key, list[i].serverUrl, list[i].userId)) {
                var modern = _activeKey(list[i].serverUrl, list[i].userId);
                if (modern && key !== modern)
                    _setActiveKey(modern); // migration douce depuis serverUrl|userId
                return list[i];
            }
        }
        // Clé active orpheline ou legacy non résolue : purge locale.
        _setActiveKey("");
    }
    if (list.length) {
        list.sort(function(a,b){ return (b.lastUsed||0) - (a.lastUsed||0); });
        return list[0];
    }
    return null;
}

function listUsers(serverUrl) {
    var list = _readUsersArr();
    if (serverUrl && serverUrl.length) {
        var srv = _normalizeUrl(serverUrl);
        list = list.filter(function(u){ return _normalizeUrl(u.serverUrl) === srv; });
    }
    list.sort(function(a,b){ return (b.lastUsed||0) - (a.lastUsed||0); });
    return list;
}

function removeUser(serverUrl, userId) {
    var srv = _normalizeUrl(serverUrl);
    var uid = String(userId || "");
    var key = _key(srv, uid);
    _clearSessionToken(srv, uid);
    _clearPersistentToken(srv, uid);
    var source = _readUsersArr();
    var list = source.filter(function(u){
        return _key(_normalizeUrl(u.serverUrl), u.userId) !== key;
    });
    _writeUsersArr(list);
    if (_matchesActiveKey(_getActiveKey(), srv, uid)) _setActiveKey("");
}

function clearAll() {
    // Purge d'abord les secrets dans le tableau courant, puis supprime toutes les
    // entrées et les métadonnées serveur. Aucun token ne survit au fallback backend.
    clearTokens();
    _writeUsersArr([]);
    _writeServersArr([]);
    _setActiveKey("");
}


function clearTokens() {
    _clearAllSessionTokens();
    _clearPersistentVault();
    var list = _readUsersArr();
    for (var i = 0; i < list.length; i++) {
        if (list[i]) { list[i].accessToken = ""; list[i].remember = false; }
    }
    _writeUsersArr(list);
}

function clearUserToken(serverUrl, userId) {
    var srv = _normalizeUrl(serverUrl);
    var uid = String(userId || "");
    _clearSessionToken(srv, uid);
    _clearPersistentToken(srv, uid);
    var list = _readUsersArr();
    var idx = _listKeyIdx(list, srv, uid);
    if (idx >= 0 && list[idx]) {
        list[idx].accessToken = "";
        list[idx].remember = false;
        _writeUsersArr(list);
    }
}

function clearServer(serverUrl) {
    var srv = _normalizeUrl(serverUrl);
    if (!srv) return;

    _clearSessionTokensForServer(srv);
    var source = _readUsersArr();
    var list = [];
    for (var i = 0; i < source.length; i++) {
        var u = source[i];
        if (_normalizeUrl(u.serverUrl) === srv) {
            _clearPersistentToken(srv, u.userId || "");
            continue;
        }
        list.push(u);
    }

    _writeUsersArr(list);
    _removeServerOnly(srv);

    var active = _getActiveKey();
    if (active) {
        var stillValid = false;
        for (var j = 0; j < list.length; j++) {
            if (_matchesActiveKey(active, list[j].serverUrl, list[j].userId)) {
                stillValid = true;
                break;
            }
        }
        if (!stillValid) _setActiveKey("");
    }
}


// Oubli appareil/serveur : purge profils, tokens et préférences stockées.

function forgetThisDevice() {
    clearAll();
}

function forgetServer(serverUrl) {
    clearServer(serverUrl);
}


// ============== API (PREFS PAR UTILISATEUR) ==============
function _getCtx(serverUrl, userId) {
    var srv = _normalizeUrl(serverUrl);
    var list = _readUsersArr();
    var idx  = _listKeyIdx(list, srv, userId);
    return { list:list, idx:idx, srv:srv };
}


function ensureUserPrefsContext(serverUrl, userId) {
    var srv = _normalizeUrl(serverUrl);
    var uid = String(userId || "");
    if (!srv || !uid) return false;

    var list = _readUsersArr();
    if (_listKeyIdx(list, srv, uid) >= 0) return true;

    list.push({
        serverUrl: srv,
        userId: uid,
        userName: "",
        accessToken: "",
        imageTag: "",
        remember: false,
        lastUsed: _now(),
        prefs: {}
    });
    list.sort(function(a,b){ return (b.lastUsed||0) - (a.lastUsed||0); });
    if (list.length > MAX_USERS) list = list.slice(0, MAX_USERS);
    _writeUsersArr(list);
    return _listKeyIdx(list, srv, uid) >= 0;
}

// Renvoie toutes les prefs d'un utilisateur (objet) — {} si absent
function getUserPrefs(serverUrl, userId) {
    var ctx = _getCtx(serverUrl, userId);
    if (ctx.idx < 0) return {};
    var p = ctx.list[ctx.idx].prefs;
    return (p && typeof p === "object") ? p : {};
}

// Merge + sauvegarde, renvoie l'objet prefs résultant
function saveUserPrefs(serverUrl, userId, patch) {
    var ctx = _getCtx(serverUrl, userId);
    if (ctx.idx < 0) return {}; // utilisateur inconnu
    var cur = ctx.list[ctx.idx];
    var out = _mergePrefs(cur.prefs, patch);
    cur.prefs = out;
    cur.lastUsed = _now();
    ctx.list[ctx.idx] = cur;
    ctx.list.sort(function(a,b){ return (b.lastUsed||0) - (a.lastUsed||0); });
    _writeUsersArr(ctx.list);
    return out;
}

function getUserPref(serverUrl, userId, key, def) {
    var p = getUserPrefs(serverUrl, userId);
    return (p.hasOwnProperty(key) ? p[key] : def);
}

function setUserPref(serverUrl, userId, key, value) {
    var obj = {}; obj[key] = value;
    return saveUserPrefs(serverUrl, userId, obj);
}

