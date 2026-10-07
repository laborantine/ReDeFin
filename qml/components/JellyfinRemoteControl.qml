// qml/components/JellyfinRemoteControl.qml
// Contrôle distant natif Jellyfin ("Play On").
//
// QtWebSockets n'est PAS importé statiquement. Le type WebSocket est créé
// dynamiquement uniquement si le module QtWebSockets 1.15 existe réellement
// sur le Player. Si le module est absent, ReDeFin reste entièrement utilisable
// et seule cette fonction est désactivée.
//
// Aucun QtQuick Controls. Aucun secret n'est journalisé.
import QtQuick 2.15
import "../js/jellyfinBridge.js" as JFB

Item {
    id: root
    width: 0
    height: 0
    visible: false
    enabled: false

    property string serverUrl: ""
    property string accessToken: ""
    property string deviceId: ""
    property bool active: false

    readonly property bool connected: _connected
    readonly property bool transportAvailable: _transportAvailable
    readonly property bool capabilitiesPublished: _capabilitiesPublished

    signal playRequested(var data)
    signal playstateRequested(var data)
    signal generalCommandRequested(var data)

    property var _socket: null
    property bool _connected: false
    property bool _transportAvailable: false
    property bool _transportProbeDone: false
    property bool _capabilitiesPublished: false
    property bool _intentionalClose: false
    property int _reconnectDelayMs: 1000
    property int _capabilityRetryCount: 0
    property int _keepAliveIntervalMs: 30000

    function _s(v) {
        return (v === undefined || v === null) ? "" : String(v)
    }

    function _trimBase(v) {
        var s = _s(v).trim()
        while (s.length > 0 && s.charAt(s.length - 1) === "/")
            s = s.substring(0, s.length - 1)
        return s
    }

    function _contextValid() {
        var base = _trimBase(serverUrl)
        if (active !== true
                || base.length <= 0
                || _s(accessToken).length <= 0
                || _s(deviceId).length <= 0
                || (base.indexOf("http://") !== 0
                    && base.indexOf("https://") !== 0))
            return false

        // Le token WebSocket doit être placé dans l'URL. On refuse donc
        // explicitement un serveur HTTP public qui deviendrait un ws:// public.
        try {
            if (JFB.isWanHttpUrl && JFB.isWanHttpUrl(base))
                return false
        } catch (e0) {}
        return true
    }

    function _socketUrl() {
        var base = _trimBase(serverUrl)
        if (base.indexOf("https://") === 0)
            base = "wss://" + base.substring(8)
        else if (base.indexOf("http://") === 0)
            base = "ws://" + base.substring(7)
        else
            return ""
        // Jellyfin 12 n'accepte plus forcément le paramètre legacy
        // "api_key" lorsque LegacyAuthorization est désactivé. "ApiKey"
        // est la forme moderne et reste compatible avec les versions 10.x.
        return base + "/socket?ApiKey=" + encodeURIComponent(_s(accessToken))
                + "&deviceId=" + encodeURIComponent(_s(deviceId))
    }

    function _dynamicSocketSource() {
        return "import QtQuick 2.15\n"
             + "import QtWebSockets 1.15\n"
             + "WebSocket {\n"
             + "  property int redefinOpenStatus: WebSocket.Open\n"
             + "  property int redefinClosedStatus: WebSocket.Closed\n"
             + "  property int redefinErrorStatus: WebSocket.Error\n"
             + "}\n"
    }

    function _ensureSocket() {
        if (_socket)
            return true
        if (_transportProbeDone && !_transportAvailable)
            return false

        _transportProbeDone = true
        try {
            var obj = Qt.createQmlObject(_dynamicSocketSource(), root,
                                         "ReDeFinJellyfinRemoteSocket")
            if (!obj) {
                _transportAvailable = false
                return false
            }
            _socket = obj
            _transportAvailable = true
            obj.textMessageReceived.connect(_onTextMessage)
            obj.statusChanged.connect(_onSocketStatusChanged)
            return true
        } catch (e) {
            _socket = null
            _transportAvailable = false
            return false
        }
    }

    function _detachAndDestroySocket() {
        var s = _socket
        _socket = null
        _connected = false
        _capabilitiesPublished = false
        keepAliveTimer.stop()
        capabilityRetryTimer.stop()
        if (!s)
            return
        try { s.textMessageReceived.disconnect(_onTextMessage) } catch (e0) {}
        try { s.statusChanged.disconnect(_onSocketStatusChanged) } catch (e1) {}
        try { s.active = false } catch (e2) {}
        try { s.destroy() } catch (e3) {}
    }

    function _shutdown(intentional) {
        _intentionalClose = intentional === true
        reconnectTimer.stop()
        _detachAndDestroySocket()
        _intentionalClose = false
    }

    function _start() {
        reconnectTimer.stop()
        if (!_contextValid()) {
            _shutdown(true)
            return
        }
        if (!_ensureSocket())
            return

        var url = _socketUrl()
        if (!url.length)
            return

        var s = _socket
        _connected = false
        _capabilitiesPublished = false
        _capabilityRetryCount = 0
        try {
            s.active = false
            s.url = url
            s.active = true
        } catch (e) {
            _scheduleReconnect()
        }
    }

    function _restartForContextChange() {
        _shutdown(true)
        if (_contextValid())
            startTimer.restart()
    }

    function _scheduleReconnect() {
        if (!_contextValid() || _intentionalClose)
            return
        reconnectTimer.interval = Math.max(500, Math.min(15000, _reconnectDelayMs))
        _reconnectDelayMs = Math.min(15000, Math.max(1000, _reconnectDelayMs * 2))
        reconnectTimer.restart()
    }

    function _publishCapabilities() {
        if (!_connected || !_contextValid())
            return

        var expectedServer = _s(serverUrl)
        var expectedToken = _s(accessToken)
        JFB.postRemoteControlCapabilities(expectedServer, expectedToken, true,
            function() {
                if (!_connected
                        || expectedServer !== _s(serverUrl)
                        || expectedToken !== _s(accessToken))
                    return
                _capabilitiesPublished = true
                _capabilityRetryCount = 0
                capabilityRetryTimer.stop()
            },
            function() {
                if (!_connected
                        || expectedServer !== _s(serverUrl)
                        || expectedToken !== _s(accessToken))
                    return
                _capabilitiesPublished = false
                if (_capabilityRetryCount < 3) {
                    _capabilityRetryCount++
                    capabilityRetryTimer.restart()
                }
            })
    }

    function _onSocketStatusChanged() {
        var s = _socket
        if (!s)
            return

        var st = Number(s.status)
        if (st === Number(s.redefinOpenStatus)) {
            _connected = true
            _reconnectDelayMs = 1000
            _capabilityRetryCount = 0
            _sendKeepAlive()
            _publishCapabilities()
            return
        }

        if (st === Number(s.redefinClosedStatus)
                || st === Number(s.redefinErrorStatus)) {
            var shouldReconnect = _contextValid() && !_intentionalClose
            _connected = false
            _capabilitiesPublished = false
            keepAliveTimer.stop()
            capabilityRetryTimer.stop()
            _detachAndDestroySocket()
            if (shouldReconnect)
                _scheduleReconnect()
        }
    }

    function _sendObject(obj) {
        if (!_connected || !_socket || !obj)
            return false
        try {
            _socket.sendTextMessage(JSON.stringify(obj))
            return true
        } catch (e) {
            return false
        }
    }

    function _sendKeepAlive() {
        return _sendObject({ MessageType: "KeepAlive" })
    }

    function _armKeepAlive(timeoutSeconds) {
        var sec = Number(timeoutSeconds)
        if (!isFinite(sec) || isNaN(sec) || sec <= 0)
            sec = 60
        _keepAliveIntervalMs = Math.max(5000, Math.min(30000,
                                    Math.floor(sec * 500)))
        keepAliveTimer.interval = _keepAliveIntervalMs
        _sendKeepAlive()
        keepAliveTimer.restart()
    }

    function _onTextMessage(text) {
        text = _s(text)
        if (!text.length || text.length > 131072)
            return

        var msg = null
        try { msg = JSON.parse(text) } catch (e0) { return }
        if (!msg || typeof msg !== "object")
            return

        var type = _s(msg.MessageType || msg.messageType)
        var data = (msg.Data !== undefined) ? msg.Data : msg.data

        if (type === "ForceKeepAlive") {
            _armKeepAlive(data)
            return
        }
        if (type === "KeepAlive")
            return
        if (type === "Play") {
            playRequested(data || ({}))
            return
        }
        if (type === "Playstate") {
            playstateRequested(data || ({}))
            return
        }
        if (type === "GeneralCommand")
            generalCommandRequested(data || ({}))
    }

    onActiveChanged: _restartForContextChange()
    onServerUrlChanged: _restartForContextChange()
    onAccessTokenChanged: _restartForContextChange()
    onDeviceIdChanged: _restartForContextChange()

    Timer {
        id: startTimer
        interval: 40
        repeat: false
        onTriggered: root._start()
    }

    Timer {
        id: reconnectTimer
        interval: 1000
        repeat: false
        onTriggered: root._start()
    }

    Timer {
        id: capabilityRetryTimer
        interval: 5000
        repeat: false
        onTriggered: root._publishCapabilities()
    }

    Timer {
        id: keepAliveTimer
        interval: root._keepAliveIntervalMs
        repeat: true
        onTriggered: root._sendKeepAlive()
    }

    Component.onCompleted: {
        if (_contextValid())
            startTimer.restart()
    }

    Component.onDestruction: _shutdown(true)
}
