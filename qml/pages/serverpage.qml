// serverpage.qml — Découverte locale Jellyfin + saisie URL (side-menu, D-Pad, IME Back handling)
// QtQuick 2.15 — sans QtQuick Controls
// ReDeFin — découverte Jellyfin + saisie manuelle avec timeout HTTPS renforcé

import QtQuick 2.15
import fbx.ui.base 1.0 as FbxBase
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/clientId.js" as ClientId

FocusScope {
    id: serverPage
    width: 1280
    height: 720
    focus: true

    /* ===== Palette commune LoginPage ===== */
    readonly property color uiBg: "#000000"
    readonly property color uiSurface: "#101010"
    readonly property color uiSurfaceRaised: "#171717"
    readonly property color uiSurfaceFocus: "#202020"
    readonly property color uiBorder: "#383838"
    readonly property color uiBorderStrong: "#5A5A5A"
    readonly property color uiFocus: "#FFFFFF"
    readonly property color uiText: "#FFFFFF"
    readonly property color uiTextSecondary: "#C8C8C8"
    readonly property color uiTextMuted: "#969696"
    readonly property color uiDanger: "#FFB4B4"
    // Même transparence que LoginPage / ServerOverlay.
    // ServerPage : menus opaques, sans transparence.
    readonly property color uiMenuPanel: "#000000"
    readonly property real uiMenuShadeOpacity: 0.22
    readonly property int uiRadiusLarge: 20
    readonly property int uiRadiusCard: 18
    readonly property real uiCardFocusScale: 1.025
    readonly property real uiButtonFocusScale: 1.035
    readonly property int uiFocusLiftPx: 4

    function s(x) { return (x === undefined || x === null) ? "" : String(x); }

    /* ===== Contexte / API ===== */
    property var    fbx
    property var    shared: null
    readonly property string deviceId: ClientId.clientId()

    signal requestNavigation(string pageName)
    // Pour ShellPage: diffusion de la liste de serveurs découverts
    signal discoveredServersUpdated(var list)

    /* ===== Logo (même logique que Splash/PosterGrid) ===== */
    readonly property url brandLogoUrl: Qt.resolvedUrl("../images/Redefin-logo2-512.png")

    /* ===== Réglages position / taille du logo ===== */
    // Valeurs modifiables directement ici.
    property int brandLogoLeftMargin: 8
    property int brandLogoTopMargin: -30
    property int brandLogoWidth: 320
    property int brandLogoHeight: 200
    property real brandLogoOversample: 1.8

    /* ===== Réglage position bouton recherche ===== */
    // Valeur négative = remonte le bouton ; positive = le descend.
    property int rescanButtonOffsetY: -10

    /* ===== État ===== */
    property bool   discovering: false
    property string infoText: "Recherche de serveurs Jellyfin sur le réseau…"
    property string manualUrl: ""
    property string lastError: ""
    property var    servers: []    // [{ name,url,pingMs,version,id,host,port }]

    /* ===== Limites scan ===== */
    // Profil Freebox Revolution : scan /24 exhaustif (.2 -> .254), seulement deux
    // requêtes simultanées. Les serveurs trouvés sont publiés sans attendre la fin.
    property int    scanMaxHosts: 253
    property int    maxParallel: 2
    property int    httpTimeoutMs: 500
    property int    httpsTimeoutMs: 1000
    // Timeout dédié à la saisie manuelle : le handshake HTTPS domaine + redirection + VM peut être lent.
    // La découverte auto reste rapide, mais l'URL entrée manuellement a le droit de respirer.
    property int    manualHttpTimeoutMs: 3500
    property int    manualHttpsTimeoutMs: 9000
    property bool   fallbackSubnetScan: true

    /* ===== Transport découverte ===== */
    property var _discoveryHandle: null

    function _cancelDiscovery() {
        discovering = false
        var h = _discoveryHandle
        _discoveryHandle = null
        try { if (h && typeof h.cancel === "function") h.cancel("serverpage-cancel") } catch(e0) {}
    }

    /* ===== HTTP utils ===== */
    function _safeHttpCode(status) {
        status = status | 0
        return status > 0 ? ("HTTP " + status) : ""
    }
    function _describeHttpError(err) {
        if (err === undefined || err === null) return "network"
        if (typeof err === "string") return String(err)
        var parts = []
        try { if (err.code) parts.push(String(err.code).replace(/_/g, " ")) } catch(e0) {}
        var hc = _safeHttpCode(err && err.status || 0)
        if (hc.length && parts.indexOf(hc) < 0) parts.push(hc)
        return parts.length ? parts.join(" / ") : "network"
    }
    function _httpsHelp(base, err) {
        var b = normalizeUrl(base)
        if (b.indexOf("https://") !== 0) return ""
        var d = _describeHttpError(err).toLowerCase()
        if (d.indexOf("ssl") >= 0 || d.indexOf("tls") >= 0 || d.indexOf("network") >= 0 || d.indexOf("timeout") >= 0)
            return " Vérifiez aussi le certificat TLS complet, fullchain.pem, TLS 1.2 activé, et évitez /web dans l’URL."
        return ""
    }

    /* ===== Normalisation host & URL ===== */
    function hasScheme(u) {
        var t = s(u).trim().toLowerCase();
        return t.indexOf("http://") === 0 || t.indexOf("https://") === 0;
    }

    function _shortHostName(value) {
        var h = cleanHost(value).replace(/^\[/, "").replace(/\]$/, "").toLowerCase();
        return !!(h && h.indexOf(":") < 0 && h.indexOf(".") < 0 && /^[a-z0-9][a-z0-9-]{0,62}$/.test(h));
    }

    function _markTrustedLanHost(value) {
        try { return Jellyfin.trustLanHost(value) === true; } catch(e0) { return false; }
    }

    function isWanHttpUrl(url) {
        try { return Jellyfin.isWanHttpUrl(url) === true; } catch(e0) { return false; }
    }

    function _wanHttpError() {
        return "Connexion HTTP externe refusée. Utilisez HTTPS ou une adresse locale.";
    }

    function cleanHost(raw) {
        var h = s(raw).trim();
        if (!h) return "";
        if (h.indexOf("://") > 0) h = h.split("://")[1];
        var slash = h.indexOf("/");
        if (slash > 0) h = h.substring(0, slash);
        if (h.charAt(0) === "[") {
            var rb = h.indexOf("]");
            if (rb > 0) return h.substring(0, rb+1);
            return h;
        }
        var colon = h.indexOf(":");
        if (colon > 0) h = h.substring(0, colon);
        return h;
    }

    function makeBase(scheme, host, port) { return scheme + "://" + host + ":" + port; }

    function normalizeUrl(sin) {
        try { return String(Jellyfin.normalizeServerUrl(s(sin).trim(), false) || ""); }
        catch(e0) { return ""; }
    }

    function _urlHostPart(u) {
        var t = normalizeUrl(u).replace(/^https?:\/\//i, "");
        var slash = t.indexOf("/");
        return slash >= 0 ? t.substring(0, slash) : t;
    }

    function _urlHasPath(u) {
        var t = normalizeUrl(u).replace(/^https?:\/\//i, "");
        return t.indexOf("/") >= 0;
    }

    function _urlHasExplicitPort(u) {
        var h = _urlHostPart(u);
        if (!h) return false;
        if (h.charAt(0) === "[") return h.indexOf("]:") > 0;
        return h.indexOf(":") > 0;
    }

    /* ===== Publication vers LoginPage / ShellPage ===== */
    function publishDiscovered() {
        var snapshot = servers.slice(0);

        try { if (fbx)   fbx.discoveredServers   = snapshot; } catch(e){  }
        try {
            if (shared && shared.hasOwnProperty("discoveredServers"))
                shared.discoveredServers = snapshot;
        } catch(e2){  }
        try {
            discoveredServersUpdated(snapshot);
        } catch(e3){  }
    }

    function _storeServerNavContext(url) {
        try {
            var u = normalizeUrl(url)
            if (!u) return false
            var api = shared && shared.__redefinNavApi ? shared.__redefinNavApi : null
            return api && api.storeValues ? api.storeValues({
                serverUrl: u,
                fbx: fbx || null,
                forceServerUrl: true,
                sourcePage: "serverpage"
            }) : false
        } catch(e0) { return false }
    }

    /* ===== Choisir un serveur ===== */
    function chooseServer(url) {
        var u = normalizeUrl(url);
        if (!u || !u.length) return;
        _cancelDiscovery()
        if (isWanHttpUrl(u)) {
            lastError = _wanHttpError();

            return;
        }

        publishDiscovered();
        try { _storeServerNavContext(u); requestNavigation("LoginPage.qml?ctx=1"); } catch(e){  }
    }
    function validateAndChoose(hostClean, preferHttps, doneCb) {
        var host = cleanHost(hostClean);
        if (!host) {
            lastError = "Adresse invalide.";

            if (doneCb) doneCb(false, lastError);
            return;
        }

        var order = preferHttps ? [8920, 8096] : [8096, 8920];
        var idx = 0;

        function tryNext() {
            if (idx >= order.length) {
                lastError = "Impossible de joindre le serveur sur 8096/8920.";

                if (doneCb) doneCb(false, lastError);
                return;
            }
            var port = order[idx++], scheme = (port===8920)?"https":"http";
            var base = makeBase(scheme, host, port);
            if (scheme === "http" && isWanHttpUrl(base) && !_shortHostName(host)) {

                tryNext();
                return;
            }
            var timeout = (port===8920 ? manualHttpsTimeoutMs : manualHttpTimeoutMs);

            Jellyfin.probePublicServer(base, timeout,
                function(j, ping){

                    _markTrustedLanHost(base)
                    if (doneCb) doneCb(true, "")
                    chooseServer(base)
                },
                function(err){

                    tryNext()
                })
        }
        tryNext();
    }

    function validateExactUrlAndChoose(baseUrl, doneCb) {
        var base = normalizeUrl(baseUrl);
        if (!base) {
            if (doneCb) doneCb(false, "Adresse vide.");
            return;
        }
        if (isWanHttpUrl(base) && !_shortHostName(base)) {
            lastError = _wanHttpError();
            if (doneCb) doneCb(false, lastError);
            return;
        }
        var isHttps = (base.indexOf("https://") === 0);
        var timeout = isHttps ? manualHttpsTimeoutMs : manualHttpTimeoutMs;

        Jellyfin.probePublicServer(base, timeout,
            function(j, ping){

                _markTrustedLanHost(base)
                if (doneCb) doneCb(true, "")
                chooseServer(base)
            },
            function(err){
                var desc = _describeHttpError(err)
                var msg = (err && err.code === "invalid_response")
                        ? "La réponse reçue n'est pas un serveur Jellyfin valide."
                        : ("Impossible de joindre le serveur à cette adresse (" + desc + ")." + _httpsHelp(base, err))

                if (doneCb) doneCb(false, msg)
            })
    }

    /* ===== Découverte réseau ===== */
    function startDiscovery() {
        _cancelDiscovery()
        servers = []
        publishDiscovered()
        lastError = ""
        discovering = true
        infoText = "Recherche de serveurs Jellyfin sur le réseau…"
        try { if (fbx && Jellyfin.setFbx) Jellyfin.setFbx(fbx) } catch(e0) {}

        _discoveryHandle = Jellyfin.discoverServers({
            fbx: fbx || null,
            maxHosts: scanMaxHosts,
            maxParallel: maxParallel,
            httpTimeoutMs: httpTimeoutMs,
            httpsTimeoutMs: httpsTimeoutMs,
            fallbackSubnetScan: fallbackSubnetScan,
            fallbackMaxHosts: scanMaxHosts,
            stopOnFirstFound: false
        }, function(list) {
            if (!discovering) return
            servers = list && list.slice ? list.slice(0) : (list || [])
            infoText = servers.length ? "Serveurs découverts" : "Recherche de serveurs Jellyfin sur le réseau…"
            publishDiscovered()
        }, function(list) {
            if (!discovering) return
            _discoveryHandle = null
            servers = list && list.slice ? list.slice(0) : (list || [])
            discovering = false
            infoText = servers.length ? "Serveurs découverts" : "Aucun serveur trouvé. Entrez l’adresse complète du serveur."
            publishDiscovered()
        })
    }

    onVisibleChanged: {
        if (!visible && discovering)
            _cancelDiscovery()
    }

    Component.onCompleted: {

        if (fbx && Jellyfin.setFbx) Jellyfin.setFbx(fbx);
        startDiscovery();
        Qt.callLater(function(){ urlEntryLauncher.forceActiveFocus(); });
    }

    Component.onDestruction: _cancelDiscovery()

    /* ====== UI de fond ====== */
    Rectangle {
        anchors.fill: parent
        color: serverPage.uiBg
    }

    /* ====== GROS LOGO — TOUT EN HAUT À GAUCHE ====== */
    Item {
        id: bigLogoBox
        anchors.left: parent.left
        anchors.leftMargin: serverPage.brandLogoLeftMargin
        anchors.top: parent.top
        anchors.topMargin: serverPage.brandLogoTopMargin
        width: serverPage.brandLogoWidth
        height: serverPage.brandLogoHeight

        Image {
            id: bigLogo
            source: serverPage.brandLogoUrl
            asynchronous: true; cache: true; mipmap: false; smooth: true
            fillMode: Image.PreserveAspectFit
            anchors.fill: parent
            opacity: (status === Image.Ready ? 1.0 : 0.0)
            Behavior on opacity { NumberAnimation { duration: 220 } }
            sourceSize.width: Math.max(1, Math.round(parent.width * serverPage.brandLogoOversample))
            sourceSize.height: Math.max(1, Math.round(parent.height * serverPage.brandLogoOversample))
        }
        Text { textFormat: Text.PlainText;
            anchors.centerIn: parent
            text: "ReDeFin"
            visible: bigLogo.status !== Image.Ready
            color: serverPage.uiText; font.pixelSize: 40; font.bold: true
            opacity: 0.85
        }
    }

    /* ====== Header (horloge seule, à droite) ====== */
    Item {
        id: header
        anchors.left: parent.left;  anchors.leftMargin: 64
        anchors.right: parent.right; anchors.rightMargin: 64
        anchors.top: parent.top;    anchors.topMargin: 44
        height: 48

        Text { textFormat: Text.PlainText;
            id: clock
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: Qt.formatTime(new Date(), "hh:mm")
            color: serverPage.uiTextSecondary; font.pixelSize: 22
            function _syncClockToMinute() {
                var d = new Date()
                clock.text = Qt.formatTime(d, "hh:mm")
                clockMinuteTimer.interval = Math.max(250, 61000 - (d.getSeconds() * 1000) - d.getMilliseconds())
                clockMinuteTimer.restart()
            }
            Component.onCompleted: _syncClockToMinute()
            Timer {
                id: clockMinuteTimer
                repeat: false
                running: false
                onTriggered: clock._syncClockToMinute()
            }
        }
    }

    /* ====== Colonne gauche : sous le logo ====== */
    Column {
        // La colonne s'arrête exactement au milieu de l'écran. Le bouton peut donc
        // occuper toute la première moitié sans empiéter sur le scan réseau à droite.
        anchors.left: parent.left
        anchors.leftMargin: 64
        anchors.right: parent.horizontalCenter
        anchors.rightMargin: 28
        anchors.top: bigLogoBox.bottom
        anchors.topMargin: 20
        spacing: 18

        Text {
            textFormat: Text.PlainText
            text: "Bienvenue sur ReDeFin !"
            color: serverPage.uiText
            font.pixelSize: 38
            font.bold: true
        }

        Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "Connectez ReDeFin à votre serveur Jellyfin."
            color: serverPage.uiTextSecondary
            font.pixelSize: 18
            wrapMode: Text.WordWrap
        }

        Rectangle {
            id: urlEntryLauncher
            height: 72
            radius: serverPage.uiRadiusLarge
            width: parent.width
            color: activeFocus ? serverPage.uiSurfaceRaised : serverPage.uiSurface
            border.width: activeFocus ? 2 : 1
            border.color: activeFocus ? serverPage.uiFocus : serverPage.uiBorder
            focus: true
            scale: activeFocus ? serverPage.uiCardFocusScale : 1.0
            transform: Translate {
                y: urlEntryLauncher.activeFocus ? -serverPage.uiFocusLiftPx : 0
                Behavior on y {
                    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                }
            }
            Behavior on scale {
                NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
            }
            Behavior on color { ColorAnimation { duration: 100 } }

            Text { textFormat: Text.PlainText;
                id: label
                anchors.centerIn: parent
                color: serverPage.uiText; font.pixelSize: 20
                text: "Entrer l'adresse du serveur"
                font.bold: urlEntryLauncher.activeFocus
            }

            MouseArea { anchors.fill: parent; onClicked: openUrlEntry() }
            Keys.onReturnPressed: openUrlEntry()
            Keys.onEnterPressed:  openUrlEntry()
            Keys.onPressed: {
                if (event.key === Qt.Key_Select) { openUrlEntry(); event.accepted = true; }
                if (event.key === Qt.Key_Right)  { lv.forceActiveFocus(); event.accepted = true; }
                if (event.key === Qt.Key_Down)   { btnRescan.forceActiveFocus(); event.accepted = true; }
            }
        }
    }

    /* ====== Colonne droite : serveurs — aussi sous le logo ====== */
    Column {
        anchors.right: parent.right
        anchors.rightMargin: 64
        anchors.top: bigLogoBox.bottom
        anchors.topMargin: 20
        width: parent.width * 0.39
        spacing: 12

        Item {
            width: parent.width
            height: 42

            Text {
                id: discoveredTitle
                textFormat: Text.PlainText
                text: "Serveurs découverts"
                color: serverPage.uiText
                font.pixelSize: 28
                font.bold: true
            }

            Rectangle {
                anchors.left: discoveredTitle.left
                anchors.top: discoveredTitle.bottom
                anchors.topMargin: 6
                width: lv.activeFocus ? 72 : 34
                height: 2
                radius: 1
                color: serverPage.uiFocus
                opacity: lv.activeFocus ? 1.0 : 0.28
                Behavior on width {
                    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                }
                Behavior on opacity {
                    NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
                }
            }
        }

        Text {
            width: parent.width
            textFormat: Text.PlainText
            visible: discovering || servers.length === 0
            text: discovering ? s(infoText) : "Aucun serveur détecté."
            color: serverPage.uiTextMuted
            font.pixelSize: 16
            elide: Text.ElideRight
        }

        ListView {
            id: lv
            width: parent.width; height: 380
            model: servers
            spacing: 8
            clip: true
            focus: true
            interactive: false

            currentIndex: (count > 0 ? 0 : -1)
            onCountChanged: if (count > 0 && currentIndex < 0) currentIndex = 0
            onFocusChanged: if (focus && count > 0 && currentIndex < 0) currentIndex = 0

            highlight: Rectangle { color: "transparent"; border.width: 0 }

            Keys.onReturnPressed: {
                var it = serverPage.servers[lv.currentIndex];
                if (it && it.url) { chooseServer(it.url); event.accepted = true; }
            }
            Keys.onEnterPressed: {
                var it = serverPage.servers[lv.currentIndex];
                if (it && it.url) { chooseServer(it.url); event.accepted = true; }
            }
            Keys.onPressed: {
                if (event.key === Qt.Key_Select) {
                    var it = serverPage.servers[lv.currentIndex];
                    if (it && it.url) { chooseServer(it.url); event.accepted = true; }
                }
                if (event.key === Qt.Key_Left) { urlEntryLauncher.forceActiveFocus(); event.accepted = true; }
                if (event.key === Qt.Key_Down && lv.currentIndex === lv.count-1) { btnRescan.forceActiveFocus(); event.accepted = true; }
            }

            delegate: Rectangle {
                id: card
                width: lv.width
                height: 72
                radius: serverPage.uiRadiusCard
                readonly property bool isHot: ListView.isCurrentItem && lv.activeFocus
                color: isHot ? serverPage.uiSurfaceFocus : serverPage.uiSurface
                border.width: isHot ? 2 : 1
                border.color: isHot ? serverPage.uiFocus : serverPage.uiBorder
                Behavior on color { ColorAnimation { duration: 100 } }
                Behavior on border.color { ColorAnimation { duration: 100 } }

                Row {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 12

                    Item {
                        width: 24
                        height: 24
                        anchors.verticalCenter: parent.verticalCenter

                        Rectangle { x: 3; y: 5;  width: 18; height: 5; radius: 2; color: "transparent"; border.width: 1; border.color: serverPage.uiTextSecondary; antialiasing: true }
                        Rectangle { x: 3; y: 11; width: 18; height: 5; radius: 2; color: "transparent"; border.width: 1; border.color: serverPage.uiTextSecondary; antialiasing: true }
                        Rectangle { x: 3; y: 17; width: 18; height: 5; radius: 2; color: "transparent"; border.width: 1; border.color: serverPage.uiTextSecondary; antialiasing: true }
                        Rectangle { x: 17; y: 7;  width: 2; height: 1; color: serverPage.uiTextSecondary }
                        Rectangle { x: 17; y: 13; width: 2; height: 1; color: serverPage.uiTextSecondary }
                        Rectangle { x: 17; y: 19; width: 2; height: 1; color: serverPage.uiTextSecondary }
                    }

                    Column {
                        width: Math.max(100, lv.width - 214)
                        spacing: 2

                        Text {
                            width: parent.width
                            textFormat: Text.PlainText
                            text: s(modelData.name) || "Jellyfin"
                            color: serverPage.uiText
                            font.pixelSize: 18
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            textFormat: Text.PlainText
                            text: s(modelData.url)
                            color: serverPage.uiTextSecondary
                            font.pixelSize: 14
                            elide: Text.ElideRight
                        }
                    }

                    Item {
                        width: 72
                        height: parent.height
                        clip: true

                        Text {
                            anchors.fill: parent
                            anchors.leftMargin: 2
                            anchors.rightMargin: 2
                            textFormat: Text.PlainText
                            text: s(modelData.version)
                            color: serverPage.uiTextMuted
                            font.pixelSize: 14
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                        }
                    }

                    Item {
                        width: 58
                        height: parent.height
                        clip: true

                        Text {
                            anchors.fill: parent
                            anchors.leftMargin: 2
                            anchors.rightMargin: 2
                            textFormat: Text.PlainText
                            text: modelData.pingMs > 0 ? (modelData.pingMs + " ms") : ""
                            color: serverPage.uiTextMuted
                            font.pixelSize: 13
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        lv.currentIndex = index;
                        chooseServer(modelData.url);
                    }
                }
                Keys.onReturnPressed: chooseServer(modelData.url)
                Keys.onEnterPressed:  chooseServer(modelData.url)
                Keys.onPressed: {
                    if (event.key === Qt.Key_Select) {
                        chooseServer(modelData.url); event.accepted = true;
                    }
                }
            }
        }

        Rectangle {
            id: btnRescan
            width: 230
            height: 48
            transform: Translate { y: serverPage.rescanButtonOffsetY }
            radius: 16
            color: activeFocus ? serverPage.uiFocus : serverPage.uiSurface
            border.width: activeFocus ? 0 : 1
            border.color: serverPage.uiBorder
            Behavior on color { ColorAnimation { duration: 100 } }
            Keys.onReturnPressed: startDiscovery()
            Keys.onEnterPressed:  startDiscovery()
            Keys.onPressed: {
                if (event.key===Qt.Key_Select) { startDiscovery(); event.accepted = true; }
                if (event.key===Qt.Key_Up)     { lv.forceActiveFocus(); event.accepted = true; }
                if (event.key===Qt.Key_Left)   { urlEntryLauncher.forceActiveFocus(); event.accepted = true; }
            }
            MouseArea { anchors.fill: parent; onClicked: startDiscovery() }
            Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: discovering ? "Recherche…" : "Relancer la recherche"
                color: btnRescan.activeFocus ? "#000000" : serverPage.uiText
                font.pixelSize: 14
                font.bold: btnRescan.activeFocus
                Behavior on color { ColorAnimation { duration: 100 } }
            }
        }
    }

    /* ===== Footer ===== */
    Row {
        anchors.left: parent.left; anchors.leftMargin: 64
        anchors.right: parent.right; anchors.rightMargin: 64
        anchors.bottom: parent.bottom; anchors.bottomMargin: 24
        spacing: 12
        Text { textFormat: Text.PlainText; text: s(lastError); color: serverPage.uiDanger; font.pixelSize: 14; visible: s(lastError).length > 0 }
        Item { width: 1; height: 1 }
        Text { textFormat: Text.PlainText; text: (servers.length + " serveur(s)") ; color: serverPage.uiTextMuted; font.pixelSize: 14 }
    }

    /* ===== Overlay saisie URL — SIDE MENU ===== */
    Component {
        id: fieldComponent
        FocusScope {
            id: field
            width: 560; height: 60

            property alias text: input.text
            signal textEdited(string value)
            property string label: ""
            property bool   password: false
            property Item   upTarget: null
            property Item   downTarget: null
            property var    consumeBack: null

            onActiveFocusChanged: if (activeFocus) hit.forceActiveFocus()

            KeyNavigation.up:   upTarget
            KeyNavigation.down: downTarget
            Keys.onUpPressed:   { if (upTarget)   upTarget.forceActiveFocus();   event.accepted = true; }
            Keys.onDownPressed: { if (downTarget) downTarget.forceActiveFocus(); event.accepted = true; }

            Rectangle {
                id: fieldSurface
                anchors.fill: parent
                radius: 18
                readonly property bool focused: hit.activeFocus || input.activeFocus
                color: focused ? serverPage.uiSurfaceRaised : serverPage.uiSurface
                border.width: focused ? 2 : 1
                border.color: focused ? serverPage.uiFocus : serverPage.uiBorder
                Behavior on color { ColorAnimation { duration: 100 } }
                Behavior on border.color { ColorAnimation { duration: 100 } }
            }

            Text { textFormat: Text.PlainText;
                id: placeholder
                text: field.label
                anchors.left: parent.left; anchors.leftMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                color: serverPage.uiTextMuted
                font.pixelSize: 16
                visible: !input.activeFocus && field.text.length === 0
            }

            Text { textFormat: Text.PlainText;
                id: display
                anchors.left: parent.left; anchors.leftMargin: 18
                anchors.right: parent.right; anchors.rightMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignLeft
                elide: Text.ElideRight
                color: "white"
                font.pixelSize: 20
                text: field.password && field.text.length>0
                      ? Array(field.text.length+1).join("•")
                      : field.text
                visible: !input.activeFocus && field.text.length > 0
            }

            FbxBase.Clickable {
                id: hit
                anchors.fill: parent
                focus: true
                onClicked: input.forceActiveFocus()
                Keys.onReturnPressed: input.forceActiveFocus()
                Keys.onEnterPressed:  input.forceActiveFocus()

                KeyNavigation.up:   field.upTarget
                KeyNavigation.down: field.downTarget
                Keys.onUpPressed:   { if (field.upTarget)   field.upTarget.forceActiveFocus();   event.accepted=true; }
                Keys.onDownPressed: { if (field.downTarget) field.downTarget.forceActiveFocus(); event.accepted=true; }
            }

            TextInput {
                id: input
                anchors.left: parent.left;  anchors.leftMargin: 18
                anchors.right: parent.right; anchors.rightMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: 20
                height: Math.round(font.pixelSize * 1.4)
                visible: activeFocus
                focus: false
                clip: true
                color: "white"
                selectionColor: "#666666"
                cursorVisible: true
                cursorDelegate: Rectangle {
                    width: 2
                    height: Math.round(input.font.pixelSize * 1.15)
                    color: "white"
                    radius: 1
                    anchors.verticalCenter: parent.verticalCenter
                }
                echoMode: field.password ? TextInput.Password : TextInput.Normal
                inputMethodHints: Qt.ImhNoPredictiveText

                function submit(){
                    Qt.inputMethod.hide();
                    if (field.downTarget) field.downTarget.forceActiveFocus();
                    else hit.forceActiveFocus();
                }

                onActiveFocusChanged: {
                    if (activeFocus) Qt.inputMethod.show();
                    else Qt.inputMethod.hide();
                }

                onTextChanged: field.textEdited(text)
                onAccepted: submit()
                Keys.onReturnPressed: submit()
                Keys.onEnterPressed:  submit()

                Keys.onUpPressed:   { Qt.inputMethod.hide(); if (field.upTarget)   field.upTarget.forceActiveFocus();   event.accepted=true; }
                Keys.onDownPressed: { Qt.inputMethod.hide(); if (field.downTarget) field.downTarget.forceActiveFocus(); event.accepted=true; }
                Keys.onBackPressed: {
                    // Étape IME → si visible, on la ferme d’abord (comportement TV-friendly inchangé)
                    Qt.inputMethod.hide();
                    if (field.consumeBack) field.consumeBack();
                    hit.forceActiveFocus();
                    event.accepted=true;
                }
            }
        }
    }

    Component {
        id: urlEntryComponent
        FocusScope {
            id: urlPage
            width: parent ? parent.width : 1280
            height: parent ? parent.height : 720
            focus: true

            /* Reçoit les touches AVANT ses enfants — pour avaler Back/Escape à la source */
            Keys.priority: Keys.BeforeItem

            property string urlText: serverPage.s(serverPage.manualUrl)
            property bool   busy: false
            property string err: ""

            property bool backJustHandled: false
            property bool closing: false
            function consumeBack() { backJustHandled = true; backGuard.restart(); }
            Timer { id: backGuard; interval: 300; repeat: false; running: false; onTriggered: urlPage.backJustHandled = false }

            function closePanel() {
                if (closing) return
                closing = true
                Qt.inputMethod.hide()
                panelOpenAnimation.stop()
                panelCloseAnimation.start()
            }

            function backAction() {
                if (Qt.inputMethod.visible) {
                    // Le relâchement de la même touche ne doit pas fermer le volet.
                    consumeBack()
                    Qt.inputMethod.hide()
                    if (urlField.item) urlField.item.forceActiveFocus()
                } else {
                    closePanel()
                }
            }

            Rectangle {
                id: modalShade
                anchors.fill: parent
                color: "#000000"
                opacity: 0.0
                MouseArea {
                    anchors.fill: parent
                    enabled: !urlPage.closing
                    onClicked: urlPage.closePanel()
                }
            }

            Rectangle {
                id: panel
                width: Math.round(parent.width * 0.56)
                height: parent.height
                x: -width
                color: serverPage.uiMenuPanel
                clip: true

                readonly property int padL: 68
                readonly property int padR: 40
                readonly property int padT: 54
                readonly property int contentWidth: width - padL - padR

                Rectangle {
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.right: parent.right
                    width: 1
                    color: "#242424"
                }

                Column {
                    anchors.left: parent.left; anchors.leftMargin: panel.padL
                    anchors.top: parent.top;   anchors.topMargin:  panel.padT
                    spacing: 22
                    width: panel.contentWidth

                    Text { textFormat: Text.PlainText;
                        text: "Saisir l'adresse du serveur"
                        color: serverPage.uiText
                        font.pixelSize: 44; font.bold: true
                        width: panel.contentWidth
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }
                    Loader {
                        id: urlField
                        sourceComponent: fieldComponent
                        onLoaded: {
                            item.width = panel.contentWidth
                            item.label = "Adresse du serveur"
                            item.password = false
                            item.text = urlPage.urlText
                            item.consumeBack = urlPage.consumeBack
                            item.downTarget  = btnConnect
                            if (item.textEdited) {
                                item.textEdited.connect(function(value){
                                    urlPage.urlText = value;
                                    serverPage.manualUrl = value;
                                });
                            }
                        }
                    }

                    Rectangle {
                        id: btnConnect
                        width: 260
                        height: 54
                        radius: 18
                        color: activeFocus ? serverPage.uiFocus : serverPage.uiSurfaceRaised
                        border.width: activeFocus ? 0 : 1
                        border.color: serverPage.uiBorder
                        focus: true
                        scale: activeFocus ? serverPage.uiButtonFocusScale : 1.0
                        transform: Translate {
                            y: btnConnect.activeFocus ? -serverPage.uiFocusLiftPx : 0
                            Behavior on y {
                                NumberAnimation { duration: 115; easing.type: Easing.OutCubic }
                            }
                        }
                        Behavior on scale {
                            NumberAnimation { duration: 115; easing.type: Easing.OutCubic }
                        }
                        Behavior on color { ColorAnimation { duration: 90 } }
                        Keys.onReturnPressed: submit()
                        Keys.onEnterPressed:  submit()
                        Keys.onUpPressed:     { if (urlField.item) urlField.item.forceActiveFocus(); event.accepted = true }
                        Keys.onBackPressed:   { urlPage.backAction(); event.accepted = true }
                        Keys.onEscapePressed: { urlPage.backAction(); event.accepted = true }
                        MouseArea { anchors.fill: parent; onClicked: submit() }
                        Text {
                            textFormat: Text.PlainText
                            anchors.centerIn: parent
                            text: urlPage.busy ? "Connexion…" : "Connecter"
                            color: btnConnect.activeFocus ? "#000000" : serverPage.uiText
                            font.pixelSize: 18
                            font.bold: btnConnect.activeFocus
                            Behavior on color { ColorAnimation { duration: 90 } }
                        }
                    }

                    Rectangle {
                        visible: urlPage.err.length>0
                        width: panel.contentWidth; height: visible ? 76 : 0
                        radius: 16
                        color: "#211416"
                        border.width: 1
                        border.color: "#7A3F48"
                        Row {
                            anchors.fill: parent; anchors.margins: 12; spacing: 10
                            Text { textFormat: Text.PlainText; text: "!"; color: "#ffb4b4"; font.pixelSize: 22; font.bold: true; width: 18 }
                            Text { textFormat: Text.PlainText; text: urlPage.err; color: "#ffb4b4"; font.pixelSize: 15; width: panel.contentWidth - 58; wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight }
                        }
                    }
                }
            }

            // Animation volontairement légère : translation d'un seul bloc opaque
            // et fondu du voile. Aucun changement de largeur, layer, shader ou blur.
            ParallelAnimation {
                id: panelOpenAnimation
                PropertyAnimation {
                    target: panel
                    property: "x"
                    to: 0
                    duration: 220
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: modalShade
                    property: "opacity"
                    to: serverPage.uiMenuShadeOpacity
                    duration: 160
                    easing.type: Easing.OutCubic
                }
            }

            ParallelAnimation {
                id: panelCloseAnimation
                PropertyAnimation {
                    target: panel
                    property: "x"
                    to: -panel.width
                    duration: 180
                    easing.type: Easing.InCubic
                }
                NumberAnimation {
                    target: modalShade
                    property: "opacity"
                    to: 0.0
                    duration: 140
                    easing.type: Easing.InCubic
                }
                onStopped: {
                    overlay.active = false
                    urlEntryLauncher.forceActiveFocus()
                }
            }

            function submit() {
                if (busy) {  return; }
                err = "";

                var rawIn = urlPage.urlText;
                var hadScheme = hasScheme(rawIn);
                var baseIn = normalizeUrl(rawIn);

                if (!baseIn) { err = "Adresse vide.";  return; }

                busy = true;
                serverPage.manualUrl = baseIn;

                function fallbackPorts(message) {
                    var scheme = baseIn.indexOf("https://")===0 ? "https" : "http";

                    validateAndChoose(cleanHost(baseIn), scheme==="https", function(ok2, message2){

                        if (!ok2) {
                            busy = false;
                            err = message2 || message;
                        }
                    });
                }

                // Adresse simple tapée sans schéma : évite de perdre un aller-retour sur http://host:80.
                if (!hadScheme && !_urlHasExplicitPort(baseIn) && !_urlHasPath(baseIn)) {
                    fallbackPorts("");
                    return;
                }

                validateExactUrlAndChoose(baseIn, function(ok, message){

                    if (ok) return;

                    // Fallback volontaire uniquement pour les adresses simples sans port ni chemin.
                    // Exemple: "https://monjellyfin.domaine" -> teste aussi 8920/8096 si le 443 ne répond pas.
                    if (!_urlHasExplicitPort(baseIn) && !_urlHasPath(baseIn))
                        fallbackPorts(message);
                    else {
                        busy = false;
                        err = message;
                    }
                });
            }

            /* >>> Fix: avale Back/Escape dès la phase "Pressed" pour empêcher la remontée vers Home <<< */
            Keys.onPressed: {
                if (event.key===Qt.Key_Back || event.key===Qt.Key_Escape) {
                    urlPage.backAction();
                    event.accepted = true;
                }
            }
            Keys.onReleased: {
                if (event.key===Qt.Key_Back || event.key===Qt.Key_Escape) {
                    if (urlPage.backJustHandled) { urlPage.backJustHandled = false; event.accepted = true; return; }
                    // redondant, au cas où un device n’émettrait que Released
                    urlPage.backAction();
                    event.accepted = true;
                }
            }

            Component.onCompleted: Qt.callLater(function(){
                panelOpenAnimation.start()
                if (urlField.item) urlField.item.forceActiveFocus()
            })
        }
    }

    Loader {
        id: overlay
        anchors.fill: parent
        active: false
        visible: active
        z: 100
        sourceComponent: urlEntryComponent
        onActiveChanged: {
            if (active && item && item.forceActiveFocus) item.forceActiveFocus();
        }
    }
    function openUrlEntry() {  overlay.active = true; }

    /* ===== Swallow Back/Escape quand aucun overlay n’est ouvert ===== */
    Keys.onPressed: {
        if (!overlay.active && (event.key === Qt.Key_Back || event.key === Qt.Key_Escape)) {
            event.accepted = true;
        }
    }
    Keys.onReleased: {
        if (!overlay.active && (event.key === Qt.Key_Back || event.key === Qt.Key_Escape)) {
            event.accepted = true;
        }
    }
}
