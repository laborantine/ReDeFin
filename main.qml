// main.qml — entry point Freebox ReDeFin
// QtQuick 2.15, aucun QtQuick Controls, persistance via fbx.application.Settings
// ✅ Version sécurité : aucun console.log, purge locale, garde-fous Settings

import QtQuick 2.15
import fbx.application 1.0
import fbx.system 1.0
import "qml/components" as Components
import "qml/js/clientId.js" as ClientId
import "qml/js/UserStore.js" as UserStore
import "qml/js/jellyfinBridge.js" as JellyfinBridge

Application {
    id: fbx
    width: 1920
    height: 1080

    // Flag interne : Settings prêts avant ShellPage ?
    property bool _settingsReady: false
    readonly property var settingsRef: settings


    // Limites défensives légères pour éviter de persister accidentellement un dump énorme
    // ou une réponse API complète dans Settings. Valeurs volontairement larges pour ne pas
    // casser les usages existants.
    readonly property int _maxServerUrlLen: 512
    readonly property int _maxUserIdLen: 160
    readonly property int _maxUserNameLen: 160

    function _safeString(value, maxLen, fallbackValue) {
        if (value === undefined || value === null)
            return fallbackValue === undefined ? "" : fallbackValue

        var s = ""
        try {
            s = String(value)
        } catch (e) {
            return fallbackValue === undefined ? "" : fallbackValue
        }

        if (maxLen > 0 && s.length > maxLen)
            return s.substr(0, maxLen)

        return s
    }


    function _purgePersistedSessionTokens() {
        // Purge seulement les anciennes copies de token qui auraient pu rester
        // dans fbx.application.Settings. La métadonnée `remember` reste autorisée.
        try {
            var current = settings.usersJson || "[]"
            var safe = UserStore.sanitizeUsersJsonForStorage(current, settings.maximumSessionSecurity === true)
            if (String(current) !== String(safe))
                settings.usersJson = safe
        } catch (e0) {}
        try {
            if (settings.lastAccessToken)
                settings.lastAccessToken = ""
        } catch (e1) {}
    }

    function _normalizeServerUrl(value) {
        var s = _safeString(value, _maxServerUrlLen, "").trim()
        if (!s || !/^https?:\/\//i.test(s))
            return ""

        try {
            return String(JellyfinBridge.normalizeServerUrl(s, false) || "")
        } catch (e) {
            return ""
        }
    }

    // Purge complète des données locales sensibles et des caches de profils.
    // Le jellyfinDeviceId n'est volontairement PAS effacé ici : il identifie
    // l'installation ReDeFin, pas une session ou un profil Jellyfin.
    // ShellPage passe exclusivement par saveSettingsRequested({clearSensitiveSettings:true}).
    function clearSensitiveSettings() {
        settings.serverUrl = ""
        settings.lastUserId = ""
        settings.lastUserName = ""
        settings.lastAccessToken = ""
        settings.usersJson = "[]"
        settings.usersServersJson = "[]"
        settings.usersActiveKey = ""
        settings.usersSessionVaultJson = "{}"
        settings.rememberJellyfinSession = false

        // Après purge, on notifie ShellPage si elle sait restaurer son état depuis Settings.
        try {
            if (mainLoader.item && typeof mainLoader.item.restoreFromSettings === "function") {
                mainLoader.item.restoreFromSettings(settings)
            }
        } catch (e) {
            // no-op volontaire : ne jamais logger ici
        }
    }

    function _applySettingsPayload(payload) {
        if (!payload)
            return

        // Permet à ShellPage d'envoyer une demande de purge dans le même signal
        // saveSettingsRequested, sans créer de nouvelle dépendance.
        if (payload.clearSensitiveSettings === true || payload.resetLocalSettings === true) {
            clearSensitiveSettings()
            return
        }

        // La politique est appliquée avant usersJson pour qu'un payload ne puisse jamais
        // réintroduire un token alors que le mode sécurité maximale est actif.
        if (payload.maximumSessionSecurity !== undefined && payload.maximumSessionSecurity !== null) {
            var nextMaximumSecurity = payload.maximumSessionSecurity === true
            if (settings.maximumSessionSecurity !== nextMaximumSecurity)
                settings.maximumSessionSecurity = nextMaximumSecurity
            if (nextMaximumSecurity && settings.rememberJellyfinSession !== false)
                settings.rememberJellyfinSession = false
        }

        if (payload.rememberJellyfinSession !== undefined && payload.rememberJellyfinSession !== null) {
            // Préférence non secrète : elle autorise le coffre UserStore mais
            // n'autorise jamais l'écriture d'un accessToken dans Settings.
            var nextRememberSession = settings.maximumSessionSecurity !== true
                    && payload.rememberJellyfinSession === true
            if (settings.rememberJellyfinSession !== nextRememberSession)
                settings.rememberJellyfinSession = nextRememberSession
        }

        if (payload.serverUrl !== undefined && payload.serverUrl !== null)
            settings.serverUrl = _normalizeServerUrl(payload.serverUrl)

        if (payload.lastUserId !== undefined && payload.lastUserId !== null)
            settings.lastUserId = _safeString(payload.lastUserId, _maxUserIdLen, "")

        if (payload.lastUserName !== undefined && payload.lastUserName !== null)
            settings.lastUserName = _safeString(payload.lastUserName, _maxUserNameLen, "")

        if (payload.lastAccessToken !== undefined && payload.lastAccessToken !== null)
            settings.lastAccessToken = ""

        if (payload.usersJson !== undefined && payload.usersJson !== null)
            settings.usersJson = UserStore.sanitizeUsersJsonForStorage(payload.usersJson, settings.maximumSessionSecurity === true)

        if (payload.usersServersJson !== undefined && payload.usersServersJson !== null)
            settings.usersServersJson = UserStore.sanitizeServersJsonForStorage(payload.usersServersJson)

        if (payload.usersActiveKey !== undefined && payload.usersActiveKey !== null)
            settings.usersActiveKey = _safeString(payload.usersActiveKey, _maxServerUrlLen + _maxUserIdLen + 8, "")

    }

    Component.onCompleted: {
        // Init identité Jellyfin à partir du vrai modèle Freebox (fbx7hd-delta, fbx6hd, etc.)
        try {
            // Force la lecture pour déclencher d’éventuels init côté plateforme
            var _m = ""
            try { _m = Device.model || "" } catch (eDev) {}

            // clientId.js gère le label modèle ; le DeviceId persistant est finalisé dans Settings.onReady.
            if (typeof ClientId.initFromQmlDevice === "function") {
                ClientId.initFromQmlDevice(Device)
            }
        } catch (e) {
            // no-op
        }

        // New style : si AppSettings expose init(fbx), on lui passe le contexte Freebox
        try {
            if (Components.AppSettings && typeof Components.AppSettings.init === "function") {
                Components.AppSettings.init(fbx, settings)
            }
        } catch (e3) {
            // no-op
        }
    }

    /* ====================== SETTINGS PERSISTÉS ====================== */
    // Persistance officielle Freebox (doc application/settings.html).
    // Sécurité : les secrets persistants doivent être considérés sensibles.
    // Ne jamais logger ces propriétés, même en debug.
    Settings {
        id: settings

        // Identité technique de CETTE installation ReDeFin pour Jellyfin.
        // Générée aléatoirement au premier lancement, stable ensuite et indépendante
        // des profils/serveurs. Ce n'est ni un token ni un identifiant matériel Freebox.
        property string jellyfinDeviceId: ""

        // Données que l'on veut garder entre deux lancements
        property string serverUrl: ""
        property string lastUserId: ""
        property string lastUserName: ""
        property string lastAccessToken: ""

        // Multi-profils ReDeFin (UserStore persistant)
        property string usersJson: "[]"
        property string usersServersJson: "[]"
        property string usersActiveKey: ""

        // Coffre de session obfusqué géré exclusivement par UserStore.
        // Ne contient jamais un accessToken Jellyfin en clair.
        property string usersSessionVaultJson: "{}"

        // Politique de session. `rememberJellyfinSession` est une préférence
        // non secrète autorisant le coffre séparé de UserStore. Aucun accessToken
        // n'est jamais écrit dans ces Settings, même lorsque cette valeur vaut true.
        property bool rememberJellyfinSession: false
        property bool maximumSessionSecurity: false

        onRememberJellyfinSessionChanged: {
            // Le booléen est non sensible. Il ne doit jamais être forcé à false
            // simplement parce que les tokens bruts sont interdits dans Settings.
            fbx._purgePersistedSessionTokens()
        }

        onMaximumSessionSecurityChanged: {
            if (maximumSessionSecurity) {
                if (rememberJellyfinSession !== false)
                    rememberJellyfinSession = false
                if (usersSessionVaultJson !== "{}")
                    usersSessionVaultJson = "{}"
            }
            fbx._purgePersistedSessionTokens()
        }

        onReady: {
            // Identité Jellyfin par installation : recharge l'ID existant ou en crée
            // un au premier lancement. L'ancien DeviceId partagé "redefin-freebox"
            // n'est jamais réutilisé.
            //
            // Lors de la première exécution de cette version sur une installation
            // existante, on invalide uniquement le coffre LOCAL de sessions. Les
            // anciens tokens ont été émis lorsque toutes les Freebox partageaient le
            // même DeviceId : les restaurer empêcherait Jellyfin d'associer le nouveau
            // DeviceId au prochain login. Les profils/serveurs restent conservés et
            // l'utilisateur ne doit donc se réauthentifier qu'une fois.
            var hadStableDeviceId = false
            try {
                hadStableDeviceId = (typeof ClientId.isInstallDeviceId === "function")
                        && ClientId.isInstallDeviceId(jellyfinDeviceId)
            } catch (eDeviceIdCheck) {}

            try { ClientId.ensurePersistentDeviceId(settings) } catch (eDeviceId) {}

            if (!hadStableDeviceId) {
                try {
                    if (usersSessionVaultJson !== "{}")
                        usersSessionVaultJson = "{}"
                } catch (eVaultMigration) {}
                try {
                    if (lastAccessToken)
                        lastAccessToken = ""
                } catch (eLegacyTokenMigration) {}
            }

            try {
                // Remet aussi le libellé Revolution/Devialet puis propage immédiatement
                // l'identité stabilisée au bridge Jellyfin partagé.
                if (typeof ClientId.initFromQmlDevice === "function")
                    ClientId.initFromQmlDevice(Device)
                if (JellyfinBridge && JellyfinBridge.setClientIdentity
                        && typeof ClientId.info === "function")
                    JellyfinBridge.setClientIdentity(ClientId.info())
            } catch (eIdentity) {}

            // Migration sécurité : supprime toute ancienne copie de token de session.
            if (lastAccessToken)
                lastAccessToken = ""

            // Le mode sécurité maximale interdit le coffre persistant.
            if (maximumSessionSecurity === true) {
                if (rememberJellyfinSession !== false)
                    rememberJellyfinSession = false
                if (usersSessionVaultJson !== "{}")
                    usersSessionVaultJson = "{}"
            }

            // Migration immédiate : tous les anciens accessToken sont retirés de
            // usersJson, mais la métadonnée non secrète `remember` est conservée.
            var safeUsersJson = UserStore.sanitizeUsersJsonForStorage(usersJson || "[]", maximumSessionSecurity === true)
            if (String(usersJson || "[]") !== String(safeUsersJson))
                usersJson = safeUsersJson

            // Si ShellPage est déjà chargée, on lui pousse la restauration
            if (mainLoader.item && typeof mainLoader.item.restoreFromSettings === "function") {
                mainLoader.item.restoreFromSettings(settings)
            } else {
                fbx._settingsReady = true
            }
        }
    }

    /* ======================= CHARGEMENT SHELLPAGE ======================= */

    Loader {
        id: mainLoader
        anchors.fill: parent
        source: "qml/pages/ShellPage.qml"

        onLoaded: {
            if (!item) return

            // Injection explicite de l’objet `fbx` dans ShellPage (API Freebox)
            try {
                if (item.hasOwnProperty("fbx")) {
                    item.fbx = fbx
                }
            } catch (e) {
                // no-op
            }

            // Injection de l’objet Settings Freebox dans ShellPage
            try {
                if (item.hasOwnProperty("settings")) {
                    item.settings = settings
                }
            } catch (e2) {
                // no-op
            }

            // Si Settings étaient déjà prêts, on déclenche la restauration maintenant
            if (fbx._settingsReady && typeof item.restoreFromSettings === "function") {
                item.restoreFromSettings(settings)
            }

            // Récupération du signal saveSettingsRequested de ShellPage
            // pour pousser les valeurs dans fbx.application.Settings.
            // Ne jamais logger le payload: il peut contenir serverUrl/accessToken/userId.
            if (item.saveSettingsRequested && typeof item.saveSettingsRequested.connect === "function") {
                item.saveSettingsRequested.connect(function (payload) {
                    fbx._applySettingsPayload(payload)
                })
            }
        }

        onStatusChanged: {
            // Pas de logs: on laisse l’UI / ShellPage gérer l’erreur.
            // Loader.Error est observable côté QML si tu veux afficher un écran d’erreur.
        }
    }
}
