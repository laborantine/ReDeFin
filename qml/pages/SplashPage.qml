// qml/pages/SplashPage.qml
// Splash + routage auto : si un serveur a des profils tokenisés → LoginPage prébranchée,
// sinon → ServerPage. Compatible Freebox, sans QtQuick Controls.
// ✅ Loader circulaire (CircleDots) identique au style utilisé dans les pages (type Detail/MoviePage).

import QtQuick 2.15
import "../js/UserStore.js" as Store

FocusScope {
    id: page
    width: 1280
    height: 720
    focus: true

    property var fbx
    property var shared
    signal requestNavigation(string pageName)

    /* --- Fond --- */
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#12151B" }
            GradientStop { position: 1.0; color: "#1C2230" }
        }
    }

    /* ========= Loader circulaire (style “CircleDots”) ========= */
    Component {
        id: circleDotsLoaderComp
        Item {
            id: circle
            width: 80
            height: 80
            property int  dotCount: 12
            property real radius: width * 0.38
            property real dotSize: 6

            Repeater {
                model: circle.dotCount
                delegate: Rectangle {
                    width: circle.dotSize
                    height: circle.dotSize
                    radius: width / 2
                    color: "#E7ECFF"
                    antialiasing: true

                    x: circle.width  / 2 + circle.radius * Math.cos(2 * Math.PI * index / circle.dotCount) - width / 2
                    y: circle.height / 2 + circle.radius * Math.sin(2 * Math.PI * index / circle.dotCount) - height / 2

                    opacity: 0.0

                    SequentialAnimation on opacity {
                        running: true
                        loops: Animation.Infinite

                        PauseAnimation { duration: index * 80 }

                        NumberAnimation {
                            from: 0.0
                            to: 1.0
                            duration: 220
                            easing.type: Easing.OutCubic
                        }

                        PauseAnimation { duration: (circle.dotCount - 1) * 80 }

                        NumberAnimation {
                            from: 1.0
                            to: 0.0
                            duration: 220
                            easing.type: Easing.InCubic
                        }
                    }
                }
            }
        }
    }

    /* --- Logo centré + CircleDots dessous --- */
    Column {
        id: centerCol
        width: parent.width
        spacing: 22
        anchors.centerIn: parent

        Image {
            id: logo
            source: "../images/Redefin-logo-256.png"
            asynchronous: true
            cache: true
            sourceSize.width: 512
            sourceSize.height: 512
            mipmap: false
            fillMode: Image.PreserveAspectFit
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(page.width * 0.80, 560)
            height: width * 0.50
            opacity: 0.0
            Behavior on opacity { NumberAnimation { duration: 220 } }
            Component.onCompleted: opacity = 1.0
        }

        Loader {
            id: loadingDots
            anchors.horizontalCenter: parent.horizontalCenter
            active: true
            sourceComponent: circleDotsLoaderComp
            opacity: 0.0
            Behavior on opacity { NumberAnimation { duration: 220 } }
            Component.onCompleted: opacity = 1.0
        }
    }

    /* --- Routage --- */
    property bool   _routed: false
    property int    _minSplashMs: 2000   // 2 s minimum
    property double _startMs: 0


    function _storeServerNavContext(su) {
        try {
            var api = shared && shared.__redefinNavApi ? shared.__redefinNavApi : null
            return api && api.storeValues ? api.storeValues({ serverUrl: su || "", fbx: fbx || null }) : false
        } catch(e) { return false }
    }

    function _loginRouteForServer(su) {
        if (_storeServerNavContext(su))
            return "LoginPage.qml?ctx=1"

        // Fallback volontairement sans serverUrl en query string:
        // mieux vaut repasser par LoginPage sans préremplissage que fuiter domaine/IP/port Jellyfin.
        return "LoginPage.qml"
    }

    function routeNow() {
        if (_routed) return
        _routed = true

        // 1) Tente serveur actif + profils tokenisés
        var active = {}
        try { Store.init(page) } catch(e) {}
        try { active = Store.getActive ? (Store.getActive() || {}) : {} } catch(e) {}

        var su = active.serverUrl || ""
        var hasProfiles = false
        try {
            var listForActive = (su && Store.listUsers) ? (Store.listUsers(su) || []) : []
            for (var i = 0; i < listForActive.length; i++) {
                if (listForActive[i] && listForActive[i].accessToken) { hasProfiles = true; break }
            }
        } catch(e) {}

        if (su && hasProfiles) {
            page.requestNavigation(_loginRouteForServer(su))
            return
        }

        // 2) Sinon, cherche n’importe quel serveur avec au moins un token
        try {
            var all = Store.listUsers ? (Store.listUsers() || []) : []
            var byServer = {}
            for (var j = 0; j < all.length; j++) {
                var it = all[j]
                if (!it || !it.serverUrl) continue
                if (it.accessToken) byServer[it.serverUrl] = true
            }
            var candidates = Object.keys(byServer)
            if (candidates.length > 0) {
                page.requestNavigation(_loginRouteForServer(candidates[0]))
                return
            }
        } catch(e) {}

        // 3) Rien en cache → ServerPage
        page.requestNavigation("serverpage.qml")
    }

    Timer {
        id: bootTimer
        interval: page._minSplashMs
        running: false
        repeat: false
        onTriggered: page.routeNow()
    }

    Component.onCompleted: {
        _startMs = Date.now()
        bootTimer.start()
    }

    // On ne “bloque” pas Back/Escape au splash (laisse l’app gérer globalement si besoin)
    Keys.onPressed: {
        if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
            event.accepted = false
        }
    }
}
