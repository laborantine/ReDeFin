// clientId.js — identité Jellyfin propre à chaque installation ReDeFin
// Qt/QML JS module partagé
.pragma library

// ⚙️ Configuration de base (valeurs par défaut)
var APP_VERSION = "0.9.6";
var DEVICE_ID_PREFIX = "rdf-";
var LEGACY_SHARED_DEVICE_ID = "redefin-freebox";

// Le DeviceId Jellyfin doit identifier UNE installation ReDeFin, pas toutes les
// Freebox. On crée donc immédiatement un identifiant de runtime unique. Lorsque
// fbx.application.Settings devient prêt, main.qml le persiste via
// ensurePersistentDeviceId() ou recharge l'identifiant déjà sauvegardé.
//
// IMPORTANT : ce DeviceId n'est pas un secret et n'utilise volontairement aucun
// identifiant matériel Freebox (MAC, numéro de série, accountId...).
function _randomDeviceWord() {
    var n = Math.floor(Math.random() * 0x100000000);
    if (!isFinite(n) || n < 0) n = Math.floor(Math.random() * 0x7fffffff);
    var s = (n >>> 0).toString(36);
    while (s.length < 7) s = "0" + s;
    return s;
}

function _newInstallDeviceId() {
    var now = 0;
    try { now = Date.now ? Date.now() : (new Date()).getTime(); } catch(e0) {}
    if (!isFinite(now) || now <= 0) now = Math.floor(Math.random() * 0x7fffffff);

    return DEVICE_ID_PREFIX
        + Math.floor(now).toString(36) + "-"
        + _randomDeviceWord() + "-"
        + _randomDeviceWord() + "-"
        + _randomDeviceWord();
}

function _normalizedInstallDeviceId(value) {
    var s = "";
    try { s = String(value || "").toLowerCase(); } catch(e0) { return ""; }
    s = s.replace(/^\s+|\s+$/g, "");

    // L'ancien identifiant partagé doit impérativement être migré.
    if (!s || s === LEGACY_SHARED_DEVICE_ID) return "";
    if (s.length < 20 || s.length > 96) return "";
    if (!/^rdf-[a-z0-9]+(?:-[a-z0-9]+){2,5}$/.test(s)) return "";
    return s;
}

var _startupDeviceId = _newInstallDeviceId();

// → valeurs NEUTRES et brandées ReDeFin
var JF_CLIENT = {
    appName:  "ReDeFin",
    // Libellé affiché côté Jellyfin (sera ajusté selon le modèle)
    device:   "ReDeFin (Freebox)",
    // Unique par installation, stable après chargement de Settings.
    deviceId: _startupDeviceId,
    version:  APP_VERSION,
    ipv4AlternateHost: "",   // ex: "v4.jellyfin.example.fr"

    // Info modèle détecté (ex: "fbx7hd-delta", "Freebox Player Devialet", etc.)
    deviceModel: ""
};

// ================================
//  HELPERS SÉCURITÉ / NORMALISATION
// ================================

function _s(v) {
    return (v === undefined || v === null) ? "" : String(v);
}

function _boundedString(v, maxLen) {
    var s = _s(v);

    // Pas de CR/LF ou caractères de contrôle dans une identité qui peut finir
    // dans un header HTTP Authorization MediaBrowser.
    s = s.replace(/[\u0000-\u001F\u007F]/g, " ");
    s = s.replace(/^\s+|\s+$/g, "");

    maxLen = Number(maxLen || 0);
    if (maxLen > 0 && s.length > maxLen)
        s = s.substr(0, maxLen);

    return s;
}

function _headerValue(v, fallback, maxLen) {
    var s = _boundedString(v, maxLen || 96);
    if (!s) s = fallback || "";

    // Le header MediaBrowser utilise des valeurs entre guillemets et séparées par virgules.
    // On retire donc les caractères qui peuvent casser la structure du header.
    s = s.replace(/["\\,]/g, " ");
    s = s.replace(/\s{2,}/g, " ");
    s = s.replace(/^\s+|\s+$/g, "");

    return s || (fallback || "");
}

function _cleanHostValue(host) {
    var h = _boundedString(host, 160);
    if (!h) return "";

    // Une URL complète est réduite à son autorité. Aucune query, aucun fragment
    // et surtout aucun userinfo ne doivent pouvoir atteindre le swap IPv4.
    var m = h.match(/^[a-zA-Z][a-zA-Z0-9+\-.]*:\/\/([^\/\?#]+)/);
    if (m) h = m[1];
    var cut = h.search(/[\/\?#]/);
    if (cut >= 0) h = h.substr(0, cut);
    h = h.replace(/^\s+|\s+$/g, "");

    if (!h || h.length > 128 || h.indexOf("@") >= 0 || /[\s\u0000-\u001F\u007F]/.test(h))
        return "";

    // IPv6 entre crochets, éventuellement suivi d'un port.
    if (h.charAt(0) === "[") {
        if (!/^\[[0-9a-fA-F:.]+\](?::\d{1,5})?$/.test(h)) return "";
    } else {
        if (!/^[A-Za-z0-9._-]+(?::\d{1,5})?$/.test(h)) return "";
    }

    var pm = /:(\d{1,5})$/.exec(h);
    if (pm) {
        var port = parseInt(pm[1], 10);
        if (!isFinite(port) || port < 1 || port > 65535) return "";
    }
    return h;
}

// ================================
//  MAPPAGE MODELES FREEBOX
//  Source unique et légère partagée par ShellPage et le routeur playback.
//  (d’après fbx.system.Device.*)
//  - fbx6hd / Freebox Revolution : Freebox Revolution
//  - fbx7hd / Delta / Devialet   : Freebox Devialet
// ================================
function _foldFreeboxModelValue(v) {
    var s = _boundedString(v, 160).toLowerCase();
    s = s.replace(/[àáâãäåā]/g, "a");
    s = s.replace(/[ç]/g, "c");
    s = s.replace(/[èéêëēėę]/g, "e");
    s = s.replace(/[ìíîïīį]/g, "i");
    s = s.replace(/[òóôõöøō]/g, "o");
    s = s.replace(/[ùúûüū]/g, "u");
    s = s.replace(/[ÿý]/g, "y");
    return s.replace(/^\s+|\s+$/g, "");
}

function freeboxPlayerModeFromModel(value) {
    var s = _foldFreeboxModelValue(value);
    if (!s) return "";

    if (s.indexOf("devialet") >= 0 || s.indexOf("fbx7hd") >= 0)
        return "devialet";

    if (s === "delta" ||
        (s.indexOf("delta") >= 0 &&
         (s.indexOf("freebox") >= 0 || s.indexOf("player") >= 0 || s.indexOf("fbx") >= 0)))
        return "devialet";

    if (s.indexOf("revolution") >= 0 || s.indexOf("fbx6hd") >= 0 || s.indexOf("fbx6") >= 0)
        return "revolution";

    if (s === "v6" || (s.indexOf("v6") >= 0 && s.indexOf("freebox") >= 0))
        return "revolution";

    return "";
}

function _applyModel(modelCode) {
    var raw = _boundedString(modelCode, 96);
    if (!raw)
        return;

    // On garde le modèle "brut" borné pour éventuels usages UI/debug externes.
    JF_CLIENT.deviceModel = raw;

    var mode = freeboxPlayerModeFromModel(raw);
    if (mode === "revolution") {
        JF_CLIENT.device = "Freebox Revolution";
        return;
    }
    if (mode === "devialet") {
        JF_CLIENT.device = "Freebox Devialet";
        return;
    }

    // Autres modèles : on conserve le libellé déjà fourni ou le fallback générique.
}

// ======================================================
//  API PUBLIQUE — à appeler depuis QML
// ======================================================

// 🔹 Initialisation directe depuis le singleton QML fbx.system.Device
// ou depuis un objet de config (appName/device/deviceId/version/model)
function initFromQmlDevice(deviceObj) {
    if (!deviceObj)
        return;

    // 1) Overrides facultatifs (si on passe un objet de config)
    try {
        if (deviceObj.appName !== undefined && deviceObj.appName !== null && deviceObj.appName !== "")
            JF_CLIENT.appName = _headerValue(deviceObj.appName, "ReDeFin", 48);

        if (deviceObj.device !== undefined && deviceObj.device !== null && deviceObj.device !== "")
            JF_CLIENT.device = _headerValue(deviceObj.device, "ReDeFin (Freebox)", 64);

        // On n'accepte ici qu'un DeviceId au format ReDeFin. Cela évite qu'un
        // champ homonyme éventuellement exposé par fbx.system.Device ne remplace
        // notre identifiant d'installation par un identifiant matériel Freebox.
        if (deviceObj.deviceId !== undefined && deviceObj.deviceId !== null && deviceObj.deviceId !== "") {
            var incomingDeviceId = _normalizedInstallDeviceId(deviceObj.deviceId);
            if (incomingDeviceId) JF_CLIENT.deviceId = incomingDeviceId;
        }

        if (deviceObj.version !== undefined && deviceObj.version !== null && deviceObj.version !== "")
            JF_CLIENT.version = _headerValue(deviceObj.version, APP_VERSION, 32);

        if (deviceObj.ipv4AlternateHost !== undefined && deviceObj.ipv4AlternateHost !== null && deviceObj.ipv4AlternateHost !== "")
            JF_CLIENT.ipv4AlternateHost = _cleanHostValue(deviceObj.ipv4AlternateHost);
    } catch (e0) {
        // no-op
    }

    // 2) Récup du code modèle via plusieurs champs possibles
    var m = "";
    try {
        // Cas objet "Device" du SDK Freebox
        if (deviceObj.model !== undefined && deviceObj.model !== null && deviceObj.model !== "")
            m = deviceObj.model;
        else if (deviceObj.modelId !== undefined && deviceObj.modelId !== null && deviceObj.modelId !== "")
            m = deviceObj.modelId;
        else if (deviceObj.deviceName !== undefined && deviceObj.deviceName !== null && deviceObj.deviceName !== "")
            m = deviceObj.deviceName;
        else if (deviceObj.name !== undefined && deviceObj.name !== null && deviceObj.name !== "")
            m = deviceObj.name;
        else if (deviceObj.productName !== undefined && deviceObj.productName !== null && deviceObj.productName !== "")
            m = deviceObj.productName;
        // Cas objet de config : on accepte aussi "modelCode"
        else if (deviceObj.modelCode !== undefined && deviceObj.modelCode !== null && deviceObj.modelCode !== "")
            m = deviceObj.modelCode;
    } catch (e) {
        // no-op
    }

    _applyModel(m);
}

// 🔹 Construit la valeur MediaBrowser du header Authorization moderne
function embyAuthHeader() {
    var appName  = _headerValue(JF_CLIENT.appName,  "ReDeFin", 48);
    var device   = _headerValue(JF_CLIENT.device,   "ReDeFin (Freebox)", 64);
    var deviceId = clientId();
    var version  = _headerValue(JF_CLIENT.version,  APP_VERSION, 32);

    return 'MediaBrowser Client="' + appName +
           '", Device="' + device +
           '", DeviceId="' + deviceId +
           '", Version="' + version + '"';
}

// 🔹 Header Authorization Jellyfin moderne.
// Depuis Jellyfin 12, X-Emby-Authorization / X-Emby-Token sont legacy.
// Le token rejoint donc la valeur MediaBrowser sous la forme Token="...".
function authorizationHeader(accessToken) {
    var base = embyAuthHeader();
    var token = _boundedString(accessToken, 256);
    if (!token) return base;

    // Un token Jellyfin normal est hexadécimal, mais on garde un nettoyage
    // défensif afin qu'aucune valeur ne puisse casser la structure du header.
    token = token.replace(/["\\,\u0000-\u001F\u007F]/g, "");
    if (!token) return base;
    return base + ', Token="' + token + '"';
}

// 🔹 Accès à l’alternate host IPv4 (évite les accès directs à la var)
function ipv4AltHost() {
    return _cleanHostValue(JF_CLIENT.ipv4AlternateHost);
}

// 🔹 Initialise/recharge l'identifiant persistant de CETTE installation.
// À appeler uniquement lorsque fbx.application.Settings a émis ready().
function isInstallDeviceId(value) {
    return _normalizedInstallDeviceId(value) !== "";
}

function ensurePersistentDeviceId(settingsObj) {
    var persisted = "";
    if (settingsObj) {
        try { persisted = _normalizedInstallDeviceId(settingsObj.jellyfinDeviceId); } catch(e0) {}
    }

    if (persisted) {
        JF_CLIENT.deviceId = persisted;
        return persisted;
    }

    // Premier lancement ou migration depuis l'ancien DeviceId global. On conserve
    // l'identifiant créé au démarrage afin qu'une éventuelle requête très précoce
    // et la session persistée utilisent la même identité pendant ce lancement.
    var generated = _normalizedInstallDeviceId(JF_CLIENT.deviceId);
    if (!generated) generated = _newInstallDeviceId();
    JF_CLIENT.deviceId = generated;

    if (settingsObj) {
        try {
            if (("jellyfinDeviceId" in settingsObj)
                    && String(settingsObj.jellyfinDeviceId || "") !== generated)
                settingsObj.jellyfinDeviceId = generated;
        } catch(e1) {}
    }
    return generated;
}

// 🔹 Identifiant "clientId" utilisé ailleurs. Jamais de fallback partagé : si
// l'état était corrompu, on recrée un identifiant de runtime unique.
function clientId() {
    var id = _normalizedInstallDeviceId(JF_CLIENT.deviceId);
    if (!id) {
        id = _newInstallDeviceId();
        JF_CLIENT.deviceId = id;
    }
    return _headerValue(id, _startupDeviceId, 96);
}

// 🔹 Getters pratiques si besoin dans d’autres modules
function deviceLabel() {
    return _headerValue(JF_CLIENT.device, "ReDeFin (Freebox)", 64);
}

function deviceModel() {
    return _boundedString(JF_CLIENT.deviceModel, 96);
}

function clientName() {
    return _headerValue(JF_CLIENT.appName, "ReDeFin", 48);
}

function clientVersion() {
    return _headerValue(JF_CLIENT.version, APP_VERSION, 32);
}

function applicationVersion() {
    return APP_VERSION;
}

// 🔹 Snapshot complet pour usage interne uniquement.
//
// SÉCURITÉ PUBLICATION :
// - ne jamais logger ce retour en brut ;
// - deviceId, ipv4AlternateHost et deviceModel peuvent aider à corréler un appareil ;
// - les diagnostics ne doivent journaliser que des champs explicitement anonymisés.
function info() {
    return {
        appName:           clientName(),
        device:            deviceLabel(),
        deviceId:          clientId(),
        version:           clientVersion(),
        ipv4AlternateHost: ipv4AltHost(),
        deviceModel:       deviceModel()
    };
}
