// qml/components/RemoteControl.qml
// Pilotage à distance : ReDeFin se déclare « télécommandable » auprès du serveur
// Jellyfin (capacités de session) et garde un WebSocket ouvert pour recevoir les
// commandes envoyées par les autres clients Jellyfin (icône Cast de l'appli du
// téléphone, client web…) : Play, Pause, Seek, Stop, pistes audio/sous-titres,
// message à l'écran. Les commandes sont traduites vers l'API existante du
// lecteur (playeroverlay.qml) et de ShellPage ; rien n'est dupliqué côté lecture.
//
// Contraintes Freebox :
// - le WebSocket QML ne peut pas poser d'en-tête HTTP : le jeton passe donc
//   dans l'URL (paramètre « ApiKey », le seul accepté par Jellyfin 12 sans mode
//   hérité ; « api_key » est ajouté pour les serveurs plus anciens). C'est la
//   seule exception à la règle « jamais de jeton dans une URL », et elle suit
//   la même règle de transport : aucun jeton en clair hors LAN de confiance.
// - le module QtWebSockets est chargé dynamiquement : s'il manque sur un Player,
//   la fonctionnalité se désactive sans faire tomber l'application.
import QtQuick 2.15
import "../js/jellyfinBridge.js" as Jellyfin

Item {
    id: remote
    anchors.fill: parent
    z: 1500
    enabled: false
    visible: toast.visible

    /* ========= Contexte injecté par ShellPage ========= */
    property var    shell: null
    property var    player: null          // playerOverlayLoader.item quand le lecteur est actif
    property string serverUrl: ""
    property string accessToken: ""
    property string userId: ""
    property string deviceId: ""

    /* ========= État exposé ========= */
    readonly property bool connected: _socket !== null && _socket.status === 1
    readonly property bool moduleAvailable: _moduleState !== "absent"

    property var    _socket: null
    property string _moduleState: "unknown"   // unknown | present | absent
    property bool   _capabilitiesSent: false
    property string _capabilitiesKey: ""
    property int    _reconnectDelayMs: 5000

    // Valeurs de l'énumération GeneralCommandType de Jellyfin uniquement : les
    // commandes de lecture (Pause, Seek, Stop…) arrivent par les messages
    // « Playstate » dès que SupportsMediaControl est vrai, elles ne se déclarent pas ici.
    readonly property var supportedCommands: [
        "Play", "PlayState", "PlayNext",
        "SetAudioStreamIndex", "SetSubtitleStreamIndex",
        "DisplayMessage"
    ]

    function _sessionReady() {
        return enabled
            && String(serverUrl || "").length > 0
            && String(accessToken || "").length > 0
            && String(userId || "").length > 0
            && String(deviceId || "").length > 0
    }

    function _sessionKey() {
        // Empreinte sans le jeton en clair : sert seulement à détecter un changement de session.
        return String(serverUrl || "") + "|" + String(userId || "") + "|" + String(accessToken || "").length
    }

    /* ========= Cycle de vie ========= */
    onEnabledChanged: _refresh()
    onServerUrlChanged: _refresh()
    onAccessTokenChanged: _refresh()
    onUserIdChanged: _refresh()
    onDeviceIdChanged: _refresh()

    function _refresh() {
        if (!_sessionReady()) { _teardown(); return }
        if (_capabilitiesKey !== _sessionKey()) {
            _capabilitiesSent = false
            _capabilitiesKey = _sessionKey()
            _teardown()
        }
        if (!_capabilitiesSent) _declareCapabilities()
        _ensureSocket()
    }

    function _teardown() {
        reconnectTimer.stop()
        keepAliveTimer.stop()
        if (_socket) {
            try { _socket.active = false } catch(e0) {}
            try { _socket.destroy() } catch(e1) {}
            _socket = null
        }
    }

    function _declareCapabilities() {
        var payload = {
            PlayableMediaTypes: ["Video"],
            SupportedCommands: supportedCommands,
            SupportsMediaControl: true,
            SupportsPersistentIdentifier: true
        }
        var key = _capabilitiesKey
        Jellyfin.sessionsCapabilitiesFull(serverUrl, accessToken, payload, function() {
            if (key === remote._capabilitiesKey) remote._capabilitiesSent = true
        }, function() {
            // Nouvel essai au prochain cycle de reconnexion.
        })
    }

    function _ensureSocket() {
        if (_moduleState === "absent") return
        if (_socket) {
            if (_socket.status === 1 || _socket.status === 0) return
            _teardown()
        }
        var url = Jellyfin.webSocketUrl(serverUrl, accessToken, deviceId)
        if (!url) return
        if (_moduleState === "unknown") {
            try {
                _socket = Qt.createQmlObject(
                    'import QtQuick 2.15\nimport QtWebSockets 1.1\nWebSocket { active: false }',
                    remote, "RemoteControlSocket")
                _moduleState = "present"
            } catch(eModule) {
                _moduleState = "absent"
                _socket = null
                return
            }
        } else {
            try {
                _socket = Qt.createQmlObject(
                    'import QtQuick 2.15\nimport QtWebSockets 1.1\nWebSocket { active: false }',
                    remote, "RemoteControlSocket")
            } catch(eCreate) { _socket = null; return }
        }
        var ws = _socket
        ws.statusChanged.connect(function() { remote._onSocketStatus(ws) })
        ws.textMessageReceived.connect(function(message) { remote._onMessage(ws, message) })
        ws.url = url
        ws.active = true
    }

    function _onSocketStatus(ws) {
        if (ws !== _socket) return
        var st = ws.status
        if (st === 1) {
            // Ouvert : le serveur enverra ForceKeepAlive avec son délai ; un
            // rythme par défaut couvre les serveurs qui ne le font pas.
            _reconnectDelayMs = 5000
            keepAliveTimer.interval = 30000
            keepAliveTimer.restart()
            if (!_capabilitiesSent) _declareCapabilities()
        } else if (st === 3 || st === 4) {
            keepAliveTimer.stop()
            if (_sessionReady()) {
                reconnectTimer.interval = _reconnectDelayMs
                _reconnectDelayMs = Math.min(60000, _reconnectDelayMs * 2)
                reconnectTimer.restart()
            }
        }
    }

    Timer {
        id: reconnectTimer
        repeat: false
        onTriggered: if (remote._sessionReady()) remote._ensureSocket()
    }

    Timer {
        id: keepAliveTimer
        repeat: true
        interval: 30000
        onTriggered: remote._send({ MessageType: "KeepAlive" })
    }

    function _send(obj) {
        if (!_socket || _socket.status !== 1) return false
        try { _socket.sendTextMessage(JSON.stringify(obj)); return true } catch(e0) { return false }
    }

    /* ========= Réception ========= */
    function _onMessage(ws, message) {
        if (ws !== _socket) return
        var msg = null
        try { msg = JSON.parse(message) } catch(e0) { return }
        if (!msg || typeof msg !== "object") return
        var type = String(msg.MessageType || "")
        var data = msg.Data

        if (type === "ForceKeepAlive") {
            var seconds = Number(data) || 60
            keepAliveTimer.interval = Math.max(5000, Math.floor(seconds * 1000 / 2))
            keepAliveTimer.restart()
            _send({ MessageType: "KeepAlive" })
        } else if (type === "Play") {
            _handlePlay(data || {})
        } else if (type === "Playstate") {
            _handlePlaystate(data || {})
        } else if (type === "GeneralCommand") {
            _handleGeneralCommand(data || {})
        }
        // KeepAlive, Sessions, UserDataChanged, LibraryChanged… : ignorés.
    }

    function _playerReady() {
        var p = player
        if (!p) return null
        try {
            if (p.serverPrerollBlocking === true) return null
            if (p._playbackExitInProgress === true || p._tearingDownPlayer === true) return null
        } catch(e0) {}
        return p
    }

    function _handlePlay(data) {
        if (!shell || typeof shell.remotePlay !== "function") return
        var ids = data.ItemIds
        if (!ids || ids.length === undefined) ids = data.ItemId ? [data.ItemId] : []
        var list = []
        for (var i = 0; i < ids.length; ++i) {
            var id = String(ids[i] || "")
            if (id.length) list.push(id)
        }
        if (!list.length) return
        var command = String(data.PlayCommand || "PlayNow")
        var startTicks = Number(data.StartPositionTicks) || 0
        var startIndex = Number(data.StartIndex) || 0
        var audioIdx = (data.AudioStreamIndex !== undefined && data.AudioStreamIndex !== null) ? Number(data.AudioStreamIndex) : -1
        var subIdx = (data.SubtitleStreamIndex !== undefined && data.SubtitleStreamIndex !== null) ? Number(data.SubtitleStreamIndex) : -2
        if (command === "PlayNext" || command === "PlayLast") {
            if (shell.remoteEnqueue && shell.remoteEnqueue(list, command === "PlayNext")) return
            // Sans file d'attente exploitable, on lit immédiatement.
        }
        shell.remotePlay(list, startTicks, startIndex, audioIdx, subIdx)
    }

    function _handlePlaystate(data) {
        var p = _playerReady()
        var cmd = String(data.Command || "")
        if (!p) {
            // Sans lecteur actif, seul « Stop » a un sens (déjà arrêté).
            return
        }
        var report = true
        try {
            if (cmd === "Pause")              p.mediaPause()
            else if (cmd === "Unpause")       p.mediaPlay()
            else if (cmd === "PlayPause")     p.mediaToggle()
            else if (cmd === "Stop")        { report = false; p.mediaStop() }
            else if (cmd === "Seek")          p.mediaSeekToMs(Math.floor((Number(data.SeekPositionTicks) || 0) / 10000))
            else if (cmd === "NextTrack")   { report = false; p.transportNext("remote") }
            else if (cmd === "PreviousTrack") { report = false; p.transportPrev("remote") }
            else if (cmd === "Rewind")        p.transportRewind("remote")
            else if (cmd === "FastForward")   p.transportForward("remote")
            else report = false
        } catch(e0) { report = false }
        if (report) reportTimer.restart()
    }

    function _handleGeneralCommand(data) {
        var name = String(data.Name || "")
        var args = data.Arguments || {}
        if (name === "DisplayMessage") {
            showMessage(args.Header, args.Text, Number(args.TimeoutMs) || 0)
            return
        }
        var p = _playerReady()
        if (!p) return
        var report = false
        try {
            if (name === "SetAudioStreamIndex") {
                report = p.mediaSetAudioStream(Number(args.Index))
            } else if (name === "SetSubtitleStreamIndex") {
                report = p.mediaSetSubtitleStream(Number(args.Index))
            } else if (name === "PlayState") {
                report = true
            }
        } catch(e0) { report = false }
        if (report) reportTimer.restart()
    }

    // Laisse au lecteur le temps d'appliquer la commande avant de renvoyer
    // l'état au serveur, pour que le téléphone reflète la pause ou le seek.
    Timer {
        id: reportTimer
        interval: 350
        repeat: false
        onTriggered: {
            var p = remote._playerReady()
            if (!p) return
            try { p.mediaReportState("remote") } catch(e0) {}
        }
    }

    /* ========= Message à l'écran (DisplayMessage) ========= */
    function showMessage(header, text, timeoutMs) {
        var h = String(header || "").trim()
        var t = String(text || "").trim()
        if (!h && !t) return
        toast.header = h
        toast.body = t
        toastTimer.interval = Math.max(1500, Math.min(30000, timeoutMs > 0 ? timeoutMs : 6000))
        toast.visible = true
        toastTimer.restart()
    }

    Timer {
        id: toastTimer
        repeat: false
        onTriggered: toast.visible = false
    }

    Rectangle {
        id: toast
        property string header: ""
        property string body: ""
        visible: false
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 48
        width: Math.min(parent.width * 0.4, 720)
        height: toastColumn.implicitHeight + 36
        radius: 18
        color: "#E6141A2E"
        border.color: "#8EB9FF"
        border.width: 1

        Column {
            id: toastColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 22
            spacing: 6
            Text {
                visible: toast.header.length > 0
                width: parent.width
                text: toast.header
                color: "#FFFFFF"
                font.pixelSize: 26
                font.bold: true
                wrapMode: Text.Wrap
                elide: Text.ElideRight
                maximumLineCount: 2
            }
            Text {
                visible: toast.body.length > 0
                width: parent.width
                text: toast.body
                color: "#D4D9F1"
                font.pixelSize: 22
                wrapMode: Text.Wrap
                maximumLineCount: 6
                elide: Text.ElideRight
            }
        }
    }

    Component.onDestruction: _teardown()
}
