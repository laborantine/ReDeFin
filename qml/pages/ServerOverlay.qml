// qml/pages/ServerOverlay.qml
// Overlay plein écran : serveurs sauvegardés / découverts + bouton "Entrer une adresse"
// + SUPPR serveurs sauvegardés via "press & hold OK" (même feeling que logout profil)
// ✅ FIX UX: focus visuel beaucoup plus perceptible (ring + accent bar + scale + glow léger)
// ✅ FIX CRITIQUE: après suppression, refocus immédiat sur une cible valide (plus de "freeze")
// ✅ FIX CLIP: le zoom + glow ne rogne plus les extrémités (viewport clip + list clip:false + padding)
// ✅ FIX VISUEL: aucune “trace” de focus sur les listes quand on focus le bouton "Entrez l'adresse…"
// Conçu pour télécommande (D-Pad) – sans QtQuick Controls

import QtQuick 2.15
import "../js/jellyfinBridge.js" as Jellyfin

FocusScope {
    id: root
    width: 1280
    height: 720
    focus: true

    /* -------- Palette moderne / AMOLED -------- */
    readonly property color uiBackdrop: "#000000"
    readonly property color uiSurface: "#111111"
    readonly property color uiSurfaceFocus: "#1A1A1A"
    readonly property color uiBorder: "#333333"
    readonly property color uiBorderStrong: "#555555"
    readonly property color uiFocus: "#FFFFFF"
    readonly property color uiText: "#FFFFFF"
    readonly property color uiTextSecondary: "#B8B8B8"
    readonly property color uiTextMuted: "#888888"
    // Même transparence que LoginPage / ServerPage.
    // ServerOverlay : fenêtre opaque, sans transparence.
    readonly property color uiMenuPanel: "#000000"
    readonly property real uiMenuShadeOpacity: 0.22
    readonly property int uiRadiusLarge: 24
    readonly property int uiRadiusCard: 18

    /* -------- API exposée au parent (LoginPage) -------- */
    // SÉCURITÉ : les URLs des serveurs sont affichées volontairement pour que
    // l'utilisateur choisisse son serveur. Ne jamais logger savedServers/discoveredServers en brut.
    property var  savedServers: []        // [{name, url, version}]
    property var  discoveredServers: []   // idem, rempli par ServerPage
    property var  serverInfo: ({})
    property string currentServerUrl: ""

    signal closeRequested()
    signal chooseServer(var server)
    signal removeSavedServer(string url)
    signal enterAddressRequested()

    /* -------- Découverte locale, chargée uniquement avec l'overlay -------- */
    property var fbx: null
    property var shared: null
    property bool discoveryInFlight: false
    property double _lastDiscoveryAt: 0
    property int _discoveryMaxParallel: 2
    property int _discoveryHttpTimeoutMs: 650
    property int _discoveryHttpsTimeoutMs: 1200
    property int _discoveryFallbackMaxHosts: 32
    property bool _discoveryStopOnFirstFound: true
    property var _discoveryHandle: null

    signal discoveryResultsChanged(var servers)

    function _serverKey(s) {
        if (!s) return ""
        var u = String(s.url || s.Url || s.URL || "").replace(/\/+$/, "").toLowerCase()
        if (u.length) return u
        return String((s.host || "") + ":" + (s.port || "")).toLowerCase()
    }

    function _copyList(list) {
        return list && list.slice ? list.slice(0) : (list || [])
    }

    function _mergeServerLists(lists) {
        var out = []
        var seen = {}
        lists = lists || []
        for (var n = 0; n < lists.length; n++) {
            var list = lists[n] || []
            for (var i = 0; i < list.length; i++) {
                var it = list[i]
                var key = _serverKey(it)
                if (!it || !key || seen[key]) continue
                seen[key] = true
                out.push(it)
            }
        }
        return out
    }

    function _serverSignature(s) {
        s = s || {}
        return _serverKey(s) + "|"
                + String(s.name || s.ServerName || s.ProductName || "") + "|"
                + String(s.version || s.Version || "") + "|"
                + String(s.id || s.Id || s.ServerId || "")
    }

    function _sameServerList(a, b) {
        a = a || []
        b = b || []
        if (a.length !== b.length) return false
        for (var i = 0; i < a.length; i++) {
            if (_serverSignature(a[i]) !== _serverSignature(b[i])) return false
        }
        return true
    }

    function _externalDiscovered() {
        var lists = []
        try { lists.push(fbx && fbx.discoveredServers ? fbx.discoveredServers : []) } catch(e0) {}
        try { lists.push(shared && shared.discoveredServers ? shared.discoveredServers : []) } catch(e1) {}
        return _mergeServerLists(lists)
    }

    function _storePublishedDiscovered(list) {
        var copy = _copyList(list)
        try { if (fbx) fbx.discoveredServers = _copyList(copy) } catch(e0) {}
        try { if (shared) shared.discoveredServers = _copyList(copy) } catch(e1) {}
    }

    function _applyDiscovered(list, publish) {
        var next = _mergeServerLists([list || []])
        var changed = !_sameServerList(next, discoveredServers || [])
        if (changed)
            discoveredServers = _copyList(next)
        if (publish === true) {
            _storePublishedDiscovered(next)
            if (changed)
                discoveryResultsChanged(_copyList(next))
        }
        return changed
    }

    function _seedExternalDiscovered(extra) {
        var merged = _mergeServerLists([
            extra || [],
            discoveredServers || [],
            _externalDiscovered()
        ])
        _applyDiscovered(merged, true)
        return merged
    }

    function _publishDiscovered(list) {
        var merged = _mergeServerLists([
            list || [],
            discoveredServers || [],
            _externalDiscovered()
        ])
        _applyDiscovered(merged, true)
    }

    function startDiscovery(force) {
        _seedExternalDiscovered([])
        if (discoveryInFlight) return false

        var now = Date.now()
        if (!force && discoveredServers && discoveredServers.length > 0 &&
                (now - _lastDiscoveryAt) < 30000)
            return false
        if (!force && (now - _lastDiscoveryAt) < 12000)
            return false

        _lastDiscoveryAt = now
        discoveryInFlight = true
        try { if (fbx && Jellyfin.setFbx) Jellyfin.setFbx(fbx) } catch(e0) {}
        _discoveryHandle = Jellyfin.discoverServers({
            fbx: fbx || null,
            maxHosts: 96,
            maxParallel: _discoveryMaxParallel,
            httpTimeoutMs: _discoveryHttpTimeoutMs,
            httpsTimeoutMs: _discoveryHttpsTimeoutMs,
            fallbackSubnetScan: true,
            fallbackMaxHosts: _discoveryFallbackMaxHosts,
            stopOnFirstFound: _discoveryStopOnFirstFound
        }, function(list) {
            if (!discoveryInFlight) return
            _publishDiscovered(list || [])
        }, function(list) {
            if (!discoveryInFlight) return
            _discoveryHandle = null
            discoveryInFlight = false
            _publishDiscovered(list || [])
        })
        return true
    }

    function cancelDiscovery() {
        discoveryInFlight = false
        var h = _discoveryHandle
        _discoveryHandle = null
        try { if (h && typeof h.cancel === "function") h.cancel("overlay-close") } catch(e0) {}
    }

    // Frontière d'hébergement : LoginPage fournit un seul contexte cohérent au
    // lieu de connaître chaque propriété interne de l'overlay.
    function applyHostContext(context) {
        var c = context || {}
        if (c.savedServers !== undefined) savedServers = _copyList(c.savedServers)
        if (c.fbx !== undefined) fbx = c.fbx
        if (c.shared !== undefined) shared = c.shared
        if (c.currentServerUrl !== undefined) currentServerUrl = String(c.currentServerUrl || "")
        if (c.serverInfo !== undefined) serverInfo = c.serverInfo || ({})
        if (c.discoveredServers !== undefined) updateDiscovered(c.discoveredServers)
        return true
    }

    function focusDefaultTarget() {
        if (!focusFirst(savedList) && !focusFirst(discoveredList))
            enterBtn.forceActiveFocus()
    }

    function activate(context) {
        applyHostContext(context)
        startDiscovery(false)
        Qt.callLater(focusDefaultTarget)
        return true
    }

    function deactivate() {
        cancelDiscovery()
        _resetSavedHold()
    }

    /* -------- FIX CLIP (zoom) -------- */
    // padding interne du viewport (doit couvrir: scale + border + glow)
    property int _listPad: 8

    /* --------- Utilitaires ---------- */
    function _isOkKey(k){
        return k===Qt.Key_Return || k===Qt.Key_Enter || k===Qt.Key_Select || k===Qt.Key_Okay
    }
    function _clamp(v, a, b){
        v = v|0;
        if (v < a) return a;
        if (v > b) return b;
        return v;
    }
    function _normUrl(u){ return String(u||"").trim().replace(/\/+$/,""); }

    function focusFirst(list){
        if (!list || list.count===0) return false;
        list.currentIndex = _clamp((list.currentIndex|0), 0, list.count-1);
        // ✅ important: callLater pour laisser Qt finaliser currentItem & focus chain
        Qt.callLater(function(){
            if (list && list.count > 0) list.forceActiveFocus();
        });
        return true;
    }

    function _moveList(list, delta){
        if (!list || list.count<=0) return;
        var ni = (list.currentIndex|0) + (delta|0);
        ni = _clamp(ni, 0, list.count-1);
        if (ni === (list.currentIndex|0)) return;
        list.currentIndex = ni;
        list.positionViewAtIndex(ni, ListView.Contain);
    }

    // Mémorise la dernière liste qui a eu le focus ("saved" | "discovered")
    property string _lastListFocused: ""

    /* -------- FIX POST-SUPPRESSION : re-focus robuste ---------- */
    property bool _postDeleteRefocusPending: false
    property int  _postDeletePreferIndex: 0

    function _requestPostDeleteRefocus(preferIndex){
        _postDeleteRefocusPending = true;
        _postDeletePreferIndex = preferIndex|0;
        Qt.callLater(_applyPostDeleteRefocus);
    }

    function _applyPostDeleteRefocus(){
        if (!_postDeleteRefocusPending) return;

        if (savedList && savedList.count > 0) {
            savedList.currentIndex = _clamp(_postDeletePreferIndex, 0, savedList.count-1);
            savedList.positionViewAtIndex(savedList.currentIndex, ListView.Contain);
            savedList.forceActiveFocus();
            _postDeleteRefocusPending = false;
            return;
        }

        if (discoveredList && discoveredList.count > 0) {
            discoveredList.currentIndex = _clamp((discoveredList.currentIndex|0), 0, discoveredList.count-1);
            discoveredList.positionViewAtIndex(discoveredList.currentIndex, ListView.Contain);
            discoveredList.forceActiveFocus();
            _postDeleteRefocusPending = false;
            return;
        }

        if (enterBtn) {
            enterBtn.forceActiveFocus();
            _postDeleteRefocusPending = false;
        }
    }

    onSavedServersChanged: {
        if (_postDeleteRefocusPending) Qt.callLater(_applyPostDeleteRefocus);
        else {
            if (savedList.count > 0) savedList.currentIndex = _clamp(savedList.currentIndex|0, 0, savedList.count-1);
            else savedList.currentIndex = -1;
        }
    }

    onDiscoveredServersChanged: {
        if (discoveredList.count > 0) discoveredList.currentIndex = _clamp(discoveredList.currentIndex|0, 0, discoveredList.count-1);
        else discoveredList.currentIndex = -1;
    }

    /* -------- Press & Hold OK (suppression) — AU NIVEAU DE LA LISTE -------- */
    property bool _savedPressActive: false
    property bool _savedArmed: false
    property bool _savedKeyHeld: false
    property int  _savedHoldIndex: -1
    property real _savedDownAtMs: 0
    property real _savedArmedAtMs: 0
    property real _savedHoldProgress: 0
    property real _savedDeleteSwallowUntilMs: 0

    property int _shortTapMs: 220
    property int _preArmMs: 1000
    property int _commitMs: 1000
    property int _fallbackLongMs: 2000

    function _resetSavedHold(){
        _savedPressActive = false;
        _savedArmed = false;
        _savedKeyHeld = false;
        _savedHoldIndex = -1;
        _savedDownAtMs = 0;
        _savedArmedAtMs = 0;
        _savedHoldProgress = 0;
        savedPreArm.stop();
        savedCommit.stop();
        savedProgressTick.stop();
    }

    function _savedHoldUrl(){
        var idx = _savedHoldIndex|0;
        if (idx < 0 || idx >= savedServers.length) return "";
        return _normUrl(savedServers[idx] && savedServers[idx].url ? savedServers[idx].url : "");
    }

    function _beginSavedHold(){
        if (savedList.count<=0) return;
        _savedHoldIndex = savedList.currentIndex|0;
        if (_savedHoldIndex < 0) _savedHoldIndex = 0;

        var u = _savedHoldUrl();
        if (!u) { _resetSavedHold(); return; }

        _savedDownAtMs = Date.now();
        _savedPressActive = true;
        _savedArmed = false;

        savedPreArm.restart();
    }

    function _commitSavedDelete(){
        var u = _savedHoldUrl();
        if (!u) { _resetSavedHold(); return; }

        var prefer = savedList.currentIndex|0;
        if (savedList.count <= 1) prefer = 0;
        else if (prefer >= savedList.count - 1) prefer = savedList.count - 2;

        // Empêche le MouseArea.onClicked généré après un appui long
        // de sélectionner le serveur supprimé et de relancer un ping réseau.
        _savedDeleteSwallowUntilMs = Date.now() + 650;

        _requestPostDeleteRefocus(prefer);
        root.removeSavedServer(u);
        _resetSavedHold();
    }

    function _endSavedHold(){
        if (Date.now() < _savedDeleteSwallowUntilMs) {
            _resetSavedHold();
            return;
        }
        if (!_savedPressActive) return;

        var now = Date.now();
        var dur = now - _savedDownAtMs;

        if (_savedArmed) {
            var armedDur = now - _savedArmedAtMs;
            if (armedDur >= _commitMs || dur >= _fallbackLongMs) {
                _commitSavedDelete();
                return;
            }
            _resetSavedHold();
            return;
        }

        if (dur >= _fallbackLongMs) {
            _commitSavedDelete();
            return;
        }

        if (dur <= _shortTapMs) {
            var s = savedServers[savedList.currentIndex|0];
            if (s) root.chooseServer(s);
        }
        _resetSavedHold();
    }

    Timer {
        id: savedPreArm
        interval: root._preArmMs
        repeat: false
        onTriggered: {
            if (!root._savedPressActive) return;
            root._savedArmed = true;
            root._savedArmedAtMs = Date.now();
            root._savedHoldProgress = 0;
            savedCommit.restart();
            savedProgressTick.restart();
        }
    }

    Timer {
        id: savedCommit
        interval: root._commitMs
        repeat: false
        onTriggered: {
            if (root._savedPressActive && root._savedArmed) root._commitSavedDelete();
            else root._resetSavedHold();
        }
    }

    Timer {
        id: savedProgressTick
        interval: 66
        repeat: true
        running: false
        onTriggered: {
            if (!root._savedPressActive || !root._savedArmed) { stop(); return; }
            root._savedHoldProgress = Math.max(0, Math.min(1, (Date.now() - root._savedArmedAtMs) / Math.max(1, root._commitMs)));
        }
    }

    // Delegate visuel unique pour les deux ListView. Les comportements D-Pad
    // restent gérés par chaque liste ; seule la carte est mutualisée. Le delegate
    // détecte son propriétaire via ListView.view, sans Loader ni objet intermédiaire.
    Component {
        id: serverRowDelegate

        Item {
            id: serverCell
            width: ListView.view ? ListView.view.width : 0
            height: 68

            property var server: modelData
            readonly property var ownerList: ListView.view
            readonly property bool savedRow: ownerList === savedList
            readonly property bool isSelected: ownerList && index === (ownerList.currentIndex | 0)
            readonly property bool listFocused: !!(ownerList && ownerList.activeFocus)
            readonly property bool isHot: isSelected && listFocused
            readonly property string normalizedUrl: root._normUrl(server && server.url ? server.url : "")
            readonly property bool isCurrentServer: savedRow && normalizedUrl
                                                    && root._normUrl(root.currentServerUrl) === normalizedUrl
            readonly property bool isHoldTarget: savedRow && root._savedPressActive
                                                  && index === (root._savedHoldIndex | 0)

            Item {
                anchors.fill: parent

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 2
                    radius: root.uiRadiusCard
                    color: serverCell.isHot ? root.uiSurfaceFocus : root.uiSurface
                    border.width: serverCell.isHot ? 2 : 1
                    border.color: serverCell.isHot ? root.uiFocus : root.uiBorder
                    Behavior on color { ColorAnimation { duration: 100 } }
                    Behavior on border.color { ColorAnimation { duration: 100 } }
                }

                Row {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 12

                    Item {
                        width: 24
                        height: 24
                        anchors.verticalCenter: parent.verticalCenter

                        Rectangle { x: 3; y: 5;  width: 18; height: 5; radius: 2; color: "transparent"; border.width: 1; border.color: root.uiTextSecondary; antialiasing: true }
                        Rectangle { x: 3; y: 11; width: 18; height: 5; radius: 2; color: "transparent"; border.width: 1; border.color: root.uiTextSecondary; antialiasing: true }
                        Rectangle { x: 3; y: 17; width: 18; height: 5; radius: 2; color: "transparent"; border.width: 1; border.color: root.uiTextSecondary; antialiasing: true }
                        Rectangle { x: 17; y: 7;  width: 2; height: 1; color: root.uiTextSecondary }
                        Rectangle { x: 17; y: 13; width: 2; height: 1; color: root.uiTextSecondary }
                        Rectangle { x: 17; y: 19; width: 2; height: 1; color: root.uiTextSecondary }
                    }

                    Column {
                        width: Math.max(80, serverCell.width - (serverCell.savedRow ? 232 : 148))
                        spacing: 2
                        Text {
                            width: parent.width
                            textFormat: Text.PlainText
                            text: (serverCell.server && serverCell.server.name)
                                  || (serverCell.savedRow ? "Jellyfin" : "Serveur")
                            color: root.uiText
                            font.pixelSize: 18
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            textFormat: Text.PlainText
                            text: (serverCell.server && serverCell.server.url) || ""
                            color: root.uiTextSecondary
                            font.pixelSize: 14
                            elide: Text.ElideRight
                        }
                    }

                    // Row ignore l'Item invisible : la colonne découverte conserve
                    // exactement sa géométrie historique sans emplacement de badge.
                    Item {
                        visible: serverCell.savedRow
                        width: 64
                        height: parent.height

                        Rectangle {
                            visible: serverCell.isCurrentServer
                            width: 64
                            height: 22
                            radius: 11
                            anchors.centerIn: parent
                            color: serverCell.isHot ? root.uiFocus : "#202020"
                            border.width: 1
                            border.color: serverCell.isHot ? root.uiFocus : root.uiBorderStrong

                            Text {
                                anchors.centerIn: parent
                                textFormat: Text.PlainText
                                text: "Actif"
                                color: serverCell.isHot ? "#000000" : root.uiText
                                font.pixelSize: 12
                                font.bold: true
                            }
                        }
                    }

                    Item {
                        width: 76
                        height: parent.height
                        clip: true

                        Text {
                            anchors.fill: parent
                            anchors.leftMargin: 4
                            anchors.rightMargin: 2
                            textFormat: Text.PlainText
                            text: (serverCell.server && serverCell.server.version) || ""
                            color: root.uiTextMuted
                            font.pixelSize: 15
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                        }
                    }
                }

                Item {
                    anchors.centerIn: parent
                    width: 76
                    height: 76
                    visible: serverCell.isHoldTarget && root._savedArmed

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: "#CC0A0A0A"
                        border.width: 1
                        border.color: "#55FFFFFF"
                        antialiasing: true
                    }

                    Repeater {
                        model: 16
                        Item {
                            anchors.fill: parent
                            rotation: index * 360 / 16
                            Rectangle {
                                width: 4
                                height: 12
                                radius: 2
                                anchors.horizontalCenter: parent.horizontalCenter
                                y: 4
                                color: "#ffffff"
                                opacity: (index + 1) / 16 <= root._savedHoldProgress ? 1.0 : 0.20
                                antialiasing: true
                                Behavior on opacity { NumberAnimation { duration: 60 } }
                            }
                        }
                    }
                }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    var list = serverCell.ownerList
                    if (!list) return
                    if (serverCell.savedRow && Date.now() < root._savedDeleteSwallowUntilMs)
                        return
                    list.currentIndex = index
                    list.forceActiveFocus()
                    root.chooseServer(serverCell.server)
                }
                onPressed: {
                    var list = serverCell.ownerList
                    if (!list) return
                    list.currentIndex = index
                    if (serverCell.savedRow) {
                        list.forceActiveFocus()
                        root._savedKeyHeld = true
                        root._beginSavedHold()
                    }
                }
                onReleased: {
                    if (!serverCell.savedRow) return
                    root._savedKeyHeld = false
                    root._endSavedHold()
                }
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: root.uiBackdrop
        opacity: root.uiMenuShadeOpacity
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }
    }

    Rectangle {
        id: sheet
        width: Math.round(parent.width * 0.92)
        height: Math.round(parent.height * 0.82)
        color: root.uiMenuPanel
        radius: root.uiRadiusLarge
        border.width: 1
        border.color: "#202020"
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter

        Row {
            id: columns
            anchors.fill: parent
            anchors.margins: 34
            spacing: 40

            /* ================== Colonne gauche : sauvegardés ================== */
            Column {
                id: leftCol
                width: Math.round(columns.width * 0.45)
                spacing: 16

                Item {
                    width: leftCol.width
                    height: 42
                    Text { textFormat: Text.PlainText;
                        id: savedTitle
                        text: "Serveurs sauvegardés"
                        color: root.uiText
                        font.pixelSize: 28
                        font.bold: true
                    }
                    Rectangle {
                        anchors.left: savedTitle.left
                        anchors.top: savedTitle.bottom
                        anchors.topMargin: 6
                        width: savedList.activeFocus ? 72 : 34
                        height: 2
                        radius: 1
                        color: root.uiFocus
                        opacity: savedList.activeFocus ? 1.0 : 0.28
                        Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        Behavior on opacity { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                    }
                }

                // ✅ viewport clipé + ListView non clipé + padding => plus de bord rogné au zoom
                Item {
                    id: savedViewport
                    width: leftCol.width
                    height: 300
                    clip: true

                    ListView {
                        id: savedList
                        x: root._listPad
                        y: root._listPad
                        width: parent.width - 2*root._listPad
                        height: parent.height - 2*root._listPad

                        model: root.savedServers
                        interactive: false
                        clip: false
                        currentIndex: 0
                        keyNavigationWraps: false
                        focus: true

                        onActiveFocusChanged: {
                            if (activeFocus) root._lastListFocused = "saved";
                            if (!activeFocus && root._savedPressActive) root._resetSavedHold();
                        }

                        onCountChanged: {
                            if (count > 0) currentIndex = root._clamp(currentIndex|0, 0, count-1);
                            else currentIndex = -1;

                            if (root._postDeleteRefocusPending) Qt.callLater(root._applyPostDeleteRefocus);
                            else {
                                if (activeFocus && count === 0) Qt.callLater(function(){
                                    if (discoveredList.count > 0) discoveredList.forceActiveFocus();
                                    else enterBtn.forceActiveFocus();
                                });
                            }
                        }

                        Keys.onPressed: {
                            if (root._savedPressActive && !root._isOkKey(event.key)) { event.accepted = true; return; }

                            if (root._isOkKey(event.key)) {
                                event.accepted = true;
                                if (event.isAutoRepeat) return;
                                if (!root._savedKeyHeld) {
                                    root._savedKeyHeld = true;
                                    root._beginSavedHold();
                                }
                                return;
                            }

                            if (event.key === Qt.Key_Up) {
                                root._moveList(savedList, -1);
                                event.accepted = true;
                                return;
                            }
                            if (event.key === Qt.Key_Down) {
                                if (savedList.count === 0) { enterBtn.forceActiveFocus(); event.accepted = true; return; }
                                if ((savedList.currentIndex|0) >= savedList.count - 1) { enterBtn.forceActiveFocus(); event.accepted = true; return; }
                                root._moveList(savedList, +1);
                                event.accepted = true;
                                return;
                            }
                            if (event.key === Qt.Key_Right) {
                                if (!focusFirst(discoveredList)) enterBtn.forceActiveFocus();
                                event.accepted = true;
                                return;
                            }
                            if (event.key === Qt.Key_Left) {
                                enterBtn.forceActiveFocus();
                                event.accepted = true;
                                return;
                            }
                        }

                        Keys.onReleased: {
                            if (root._isOkKey(event.key)) {
                                event.accepted = true;
                                if (event.isAutoRepeat) return;
                                root._savedKeyHeld = false;
                                root._endSavedHold();
                            }
                        }

                        delegate: serverRowDelegate
                    }
                }

                Rectangle {
                    id: enterBtn
                    width: leftCol.width
                    height: 56
                    radius: root.uiRadiusCard
                    color: activeFocus ? root.uiFocus : root.uiSurface
                    border.width: activeFocus ? 0 : 1
                    border.color: root.uiBorder
                    focus: true
                    Behavior on color { ColorAnimation { duration: 100 } }

                    Keys.onReturnPressed: { root.enterAddressRequested(); event.accepted = true }
                    Keys.onEnterPressed:  { root.enterAddressRequested(); event.accepted = true }
                    Keys.onPressed: {
                        if (event.key === Qt.Key_Right) {
                            if (!focusFirst(discoveredList)) focusFirst(savedList);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Up) {
                            if (root._lastListFocused === "discovered" && discoveredList.count>0) focusFirst(discoveredList);
                            else if (savedList.count>0) focusFirst(savedList);
                            else if (discoveredList.count>0) focusFirst(discoveredList);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Left) {
                            event.accepted = true;
                        }
                    }
                    MouseArea { anchors.fill: parent; onClicked: root.enterAddressRequested() }

                    Row {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 10
                        Rectangle {
                            width: 24; height: 24; radius: 12
                            color: "transparent"
                            border.width: 2
                            border.color: enterBtn.activeFocus ? "#000000" : root.uiTextSecondary
                            Behavior on border.color { ColorAnimation { duration: 100 } }
                        }
                        Text { textFormat: Text.PlainText;
                            text: "Entrer l'adresse du serveur"
                            color: enterBtn.activeFocus ? "#000000" : root.uiText
                            font.pixelSize: 18
                            font.bold: enterBtn.activeFocus
                            Behavior on color { ColorAnimation { duration: 100 } }
                        }
                    }
                }

                Text { textFormat: Text.PlainText;
                    text: "Astuce : appui long sur OK = supprimer un serveur."
                    color: root.uiTextMuted
                    font.pixelSize: 14
                    wrapMode: Text.WordWrap
                    width: leftCol.width
                    opacity: 0.9
                }
            }

            /* ================== Colonne droite : découverts ================== */
            Column {
                id: rightCol
                width: Math.round(columns.width * 0.45)
                spacing: 16

                Item {
                    width: rightCol.width
                    height: 42
                    Text { textFormat: Text.PlainText;
                        id: discTitle
                        text: "Serveurs découverts"
                        color: root.uiText
                        font.pixelSize: 28
                        font.bold: true
                    }
                    Rectangle {
                        anchors.left: discTitle.left
                        anchors.top: discTitle.bottom
                        anchors.topMargin: 6
                        width: discoveredList.activeFocus ? 72 : 34
                        height: 2
                        radius: 1
                        color: root.uiFocus
                        opacity: discoveredList.activeFocus ? 1.0 : 0.28
                        Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        Behavior on opacity { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                    }
                }

                // ✅ viewport clipé + ListView non clipé + padding => plus de bord rogné au zoom
                Item {
                    id: discoveredViewport
                    width: rightCol.width
                    height: 300
                    clip: true

                    ListView {
                        id: discoveredList
                        x: root._listPad
                        y: root._listPad
                        width: parent.width - 2*root._listPad
                        height: parent.height - 2*root._listPad

                        model: root.discoveredServers
                        interactive: false
                        clip: false
                        currentIndex: 0
                        keyNavigationWraps: false
                        focus: true

                        onActiveFocusChanged: if (activeFocus) root._lastListFocused = "discovered"

                        onCountChanged: {
                            if (count > 0) currentIndex = root._clamp(currentIndex|0, 0, count-1);
                            else currentIndex = -1;
                        }

                        Keys.onPressed: {
                            if (root._isOkKey(event.key)) {
                                event.accepted = true;
                                if (event.isAutoRepeat) return;
                                var s = discoveredServers[discoveredList.currentIndex|0];
                                if (s) root.chooseServer(s);
                                return;
                            }

                            if (event.key === Qt.Key_Up) {
                                root._moveList(discoveredList, -1);
                                event.accepted = true;
                                return;
                            }
                            if (event.key === Qt.Key_Down) {
                                if (discoveredList.count === 0) { enterBtn.forceActiveFocus(); event.accepted = true; return; }
                                if ((discoveredList.currentIndex|0) >= discoveredList.count - 1) { enterBtn.forceActiveFocus(); event.accepted = true; return; }
                                root._moveList(discoveredList, +1);
                                event.accepted = true;
                                return;
                            }

                            if (event.key === Qt.Key_Left) {
                                if (!focusFirst(savedList)) enterBtn.forceActiveFocus();
                                event.accepted = true;
                                return;
                            }
                        }

                        delegate: serverRowDelegate
                    }

                    // placeholder vide : doit rester aligné au viewport (pas au ListView décalé)
                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        visible: discoveredList.count === 0
                        Text { textFormat: Text.PlainText;
                            anchors.centerIn: parent
                            text: root.discoveryInFlight ? "Recherche de serveurs…" : "Aucun serveur détecté."
                            color: root.uiTextMuted
                            font.pixelSize: 18
                        }
                    }
                }
            }
        }
    }

    Keys.onPressed: {
        if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
            root._resetSavedHold();
            root.closeRequested();
            event.accepted = true;
        }
    }

    Component.onCompleted: {
        focusDefaultTarget()
    }

    Component.onDestruction: { try { cancelDiscovery() } catch(e0) {} }

    onFbxChanged: {
        try { if (fbx && Jellyfin.setFbx) Jellyfin.setFbx(fbx) } catch(e0) {}
        _seedExternalDiscovered([])
    }

    onSharedChanged: _seedExternalDiscovered([])

    function updateDiscovered(list) {
        _seedExternalDiscovered(list || [])
        if (discoveredList.visible && discoveredList.count > 0 &&
                !savedList.activeFocus && !enterBtn.activeFocus)
            focusFirst(discoveredList)
    }
}
