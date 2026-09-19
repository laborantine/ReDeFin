// qml/pages/PlayerControls.qml
// QtQuick 2.15 — barre de progression + commandes de transport unifiées.
// 5 boutons : prev ⏮ / rewind 10 / Play-Pause / forward 10 / next ⏭
// Appui court ⏮/⏭ = chapitre ; maintien 2 s = épisode précédent/suivant si lecture d'un épisode.
// Aucun QtQuick Controls : compatible Freebox Révolution / Devialet.
import QtQuick 2.15

Item {
    id: root
    width: 1600
    height: 1080
    focus: true
    clip: false

    // Géométrie réellement utilisée dans PlayerOverlay :
    // ProgressBar affichée dans 32 px + espace 32 px + PlayerControls 96 px.
    // Les labels de la barre peuvent dépasser de sa zone, comme avant (clip=false).
    readonly property int progressAreaHeight: 32
    readonly property int controlsAreaHeight: 96
    readonly property int sectionGap: 32
    // Marge basse de la barre de transport dans le repere plein ecran.
    property int transportBottomInset: 48
    property int transportSideInset: 80

    // Focus des boutons centraux, piloté par PlayerOverlay.
    property bool active: true
    property bool isPlaying: false
    property int focusIndex: 3
    property int posMs: 0
    property int durMs: 0
    property bool focused: false
    property bool allowEpisodeLongPress: false

    // Boutons latéraux du chrome lecteur. Le panneau et sa navigation restent
    // dans PlayerSettingsOverlay ; ce composant ne possède que leur rendu.
    readonly property int controlQuality: 0
    readonly property int controlZoom: 1
    readonly property int controlSpeed: 2
    readonly property int controlAudio: 3
    readonly property int controlSubtitle: 4
    property bool settingsVisible: false
    property bool settingsAllowed: true
    property int settingsFocusedControl: -1
    property int settingsBottomInset: 30
    property real selectedRate: 1.0
    // Appui long calé sur LoginPage : 1 s de pré-armement + 1 s d'anneau = 2 s.
    property int transportPreArmMs: 1000
    property int transportCommitMs: 1000
    property int transportHoldMs: transportPreArmMs + transportCommitMs
    property int _transportHoldIndex: 0
    property bool _transportPressActive: false
    property bool _transportArmed: false
    property bool _transportLongTriggered: false
    property real _transportDownAtMs: 0
    property real _transportArmedAtMs: 0
    property real _transportHoldProgress: 0

    signal previousChapter()
    signal nextChapter()
    signal previousEpisode()
    signal rewind()
    signal togglePlay()
    signal forward()
    signal nextEpisode()
    signal moveRight()
    signal focusChanged(int idx)
    signal settingsButtonClicked(int control)

    // Signaux historiques de ProgressBar.
    signal seekRequested(int deltaMs)
    signal toggleRequested()
    signal focusUp()
    signal focusDown()

    signal userActivity()
    onFocusedChanged: {
        
        if (focused) {
            if (_transportPressActive) _cancelTransportHold()
            userActivity()
        }
    }

    function _c(a){ return Qt.rgba(1,1,1,a) }
    function _isOk(k){ return k===Qt.Key_Return || k===Qt.Key_Enter || k===Qt.Key_Select || k===Qt.Key_Ok }

    function _fmtTime(ms){
        ms = Math.max(0, Number(ms) || 0)
        var s = Math.floor(ms / 1000)
        var h = Math.floor(s / 3600)
        var m = Math.floor((s % 3600) / 60)
        var ss = s % 60
        function f2(n){ return (n < 10 ? "0" : "") + n }
        return h > 0 ? (h + ":" + f2(m) + ":" + f2(ss)) : (m + ":" + f2(ss))
    }

    function _endLabel(){
        if (durMs <= 0) return ""
        var remaining = Math.max(0, durMs - posMs)
        var end = new Date(Date.now() + remaining)
        function f2(n){ return (n < 10 ? "0" : "") + n }
        return "Se termine à " + f2(end.getHours()) + ":" + f2(end.getMinutes())
    }

    function _startTransportHold(idx){
        if (idx !== 1 && idx !== 5) return false
        // Les auto-repeat Freebox repassent par Keys.onPressed : ne jamais réarmer.
        if (_transportPressActive && _transportHoldIndex === idx) return true
        _cancelTransportHold()
        _transportHoldIndex = idx
        _transportPressActive = true
        _transportArmed = false
        _transportLongTriggered = false
        _transportDownAtMs = Date.now()
        _transportArmedAtMs = 0
        _transportHoldProgress = 0
        if (allowEpisodeLongPress) transportPreArmTimer.restart()
        return true
    }
    function _triggerTransportEpisode(){
        if (!_transportPressActive || _transportLongTriggered || !allowEpisodeLongPress) return false
        var idx = _transportHoldIndex
        if (idx !== 1 && idx !== 5) return false
        _transportLongTriggered = true
        _transportHoldProgress = 1.0
        transportPreArmTimer.stop()
        transportCommitTimer.stop()
        transportProgressTick.stop()
        if (idx === 1) previousEpisode()
        else nextEpisode()
        userActivity()
        return true
    }
    function _finishTransportHold(){
        var idx = _transportHoldIndex
        if (!_transportPressActive || (idx !== 1 && idx !== 5)) return false

        // Filet de sécurité identique à LoginPage : si les timers ont pris du retard,
        // la durée murale >= 2 s valide tout de même l'appui long.
        var elapsed = Math.max(0, Date.now() - _transportDownAtMs)
        if (!_transportLongTriggered && allowEpisodeLongPress && elapsed >= Math.max(2000, transportHoldMs))
            _triggerTransportEpisode()

        if (!_transportLongTriggered) {
            if (idx === 1) previousChapter()
            else nextChapter()
        }
        _resetTransportHold()
        return true
    }
    function _resetTransportHold(){
        transportPreArmTimer.stop()
        transportCommitTimer.stop()
        transportProgressTick.stop()
        _transportHoldIndex = 0
        _transportPressActive = false
        _transportArmed = false
        _transportLongTriggered = false
        _transportDownAtMs = 0
        _transportArmedAtMs = 0
        _transportHoldProgress = 0
    }
    function _cancelTransportHold(){ _resetTransportHold() }

    Timer {
        id: transportPreArmTimer
        interval: Math.max(1, root.transportPreArmMs)
        repeat: false
        onTriggered: {
            if (!root.active || !root.allowEpisodeLongPress || !root._transportPressActive || (root._transportHoldIndex !== 1 && root._transportHoldIndex !== 5)) return
            root._transportArmed = true
            root._transportArmedAtMs = Date.now()
            root._transportHoldProgress = 0
            transportProgressTick.restart()
            transportCommitTimer.restart()
        }
    }
    Timer {
        id: transportCommitTimer
        interval: Math.max(1, root.transportCommitMs)
        repeat: false
        onTriggered: {
            if (root._transportPressActive && root._transportArmed)
                root._triggerTransportEpisode()
        }
    }
    Timer {
        id: transportProgressTick
        interval: 100
        repeat: true
        onTriggered: {
            if (!root._transportPressActive || !root._transportArmed || root._transportLongTriggered) { stop(); return }
            root._transportHoldProgress = Math.max(0, Math.min(1, (Date.now() - root._transportArmedAtMs) / Math.max(1, root.transportCommitMs)))
        }
    }

    // Même langage visuel « verre sombre » que Chapitres / Qualité / Zoom /
    // Vitesse / Audio / Sous-titres. Les ±10 s conservent leur glow Canvas.
    readonly property color glassBase: Qt.rgba(0,0,0,0.45)
    readonly property color glassFocus: Qt.rgba(1,1,1,0.15)
    readonly property color glassBorder: Qt.rgba(1,1,1,0.25)
    readonly property color glassBorderFocus: Qt.rgba(1,1,1,0.75)
    readonly property color iconColor: _c(0.92)
    readonly property int btnSize: 72
    readonly property int spacing: 36

    // =========================================================================
    // ProgressBar intégrée
    // =========================================================================
    readonly property color progressBase: Qt.rgba(1,1,1,0.18)
    readonly property color progressFill: Qt.rgba(1,1,1,0.92)
    readonly property color progressKnob: Qt.rgba(1,1,1,1)
    readonly property int progressLineH: 3
    readonly property int progressKnobR: 9

    Item {
        id: progressArea
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: root.transportSideInset
        anchors.rightMargin: root.transportSideInset
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.transportBottomInset
                              + root.controlsAreaHeight
                              + root.sectionGap
        height: root.progressAreaHeight

        Rectangle {
            id: progressTrack
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: root.progressLineH
            color: root.progressBase
            radius: height / 2
        }

        Rectangle {
            id: progressFillRect
            anchors.verticalCenter: progressTrack.verticalCenter
            x: 0
            height: root.progressLineH
            width: root.durMs > 0
                   ? Math.max(0, Math.min(progressTrack.width,
                              progressTrack.width * root.posMs / root.durMs))
                   : 0
            color: root.progressFill
            radius: height / 2
        }

        Rectangle {
            id: progressKnobRect
            width: root.progressKnobR * 2
            height: root.progressKnobR * 2
            radius: root.progressKnobR
            anchors.verticalCenter: progressTrack.verticalCenter
            x: Math.max(0, Math.min(progressTrack.width - width,
                 (root.durMs > 0 ? (progressTrack.width * root.posMs / root.durMs) : 0) - width / 2))
            color: root.progressKnob
            opacity: 1.0
            border.width: root.focused ? 2 : 0
            border.color: Qt.rgba(0,0,0,0.35)
        }

        Text {
            id: endText
            text: root._endLabel()
            textFormat: Text.PlainText
            visible: text.length > 0
            anchors.right: parent.right
            anchors.bottom: progressTrack.top
            anchors.rightMargin: 8
            anchors.bottomMargin: 8
            color: Qt.rgba(1,1,1,0.9)
            font.pixelSize: 18
        }

        Row {
            id: timesRow
            spacing: 10
            anchors.right: parent.right
            anchors.top: progressTrack.bottom
            anchors.rightMargin: 8
            anchors.topMargin: 8

            Text {
                text: root._fmtTime(root.posMs)
                textFormat: Text.PlainText
                color: Qt.rgba(1,1,1,0.85)
                font.pixelSize: 16
            }
            Text {
                text: "/"
                textFormat: Text.PlainText
                color: Qt.rgba(1,1,1,0.55)
                font.pixelSize: 16
            }
            Text {
                text: root._fmtTime(root.durMs)
                textFormat: Text.PlainText
                color: Qt.rgba(1,1,1,0.85)
                font.pixelSize: 16
            }
        }

        MouseArea {
            anchors.fill: progressTrack
            hoverEnabled: true
            onPressed: root.userActivity()
            onPositionChanged: if (pressed) root.userActivity()
            onReleased: root.userActivity()
        }
    }

    // Zone historique PlayerControls (96 px), placée exactement 32 px sous
    // l'ancienne ProgressBar.
    Item {
        id: controlsArea
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: root.transportSideInset
        anchors.rightMargin: root.transportSideInset
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.transportBottomInset
        height: root.controlsAreaHeight

        Row {
            id: row
            anchors.centerIn: parent
            spacing: root.spacing

        Component {
            id: roundButton
            Item {
                id: btn
                width: root.btnSize; height: root.btnSize
                property int index: 0
                property string kind: "play"
                property bool focused: false
                property bool playing: false
                readonly property bool seekButton: kind === "rew" || kind === "fwd"
                property var iconRef: icon

                // Les boutons ±10 s restent volontairement sans disque : uniquement
                // le pictogramme Canvas + son halo lumineux au focus, comme avant
                // l'harmonisation visuelle des autres commandes centrales.
                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: root.glassBase
                    opacity: 0.98
                    visible: !btn.seekButton
                }
                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: root.glassFocus
                    opacity: (btn.focused && root.active && !btn.seekButton) ? 1.0 : 0.0
                    visible: !btn.seekButton
                    Behavior on opacity { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                }
                Rectangle {
                    id: ring
                    anchors.fill: parent
                    radius: width / 2
                    color: "transparent"
                    visible: !btn.seekButton
                    border.width: (btn.focused && root.active) ? 2 : 1
                    border.color: (btn.focused && root.active) ? root.glassBorderFocus : root.glassBorder
                    antialiasing: false
                }

                // Anneau d'appui long, même approche que LoginPage : il n'apparaît
                // qu'après 1 s puis se remplit jusqu'au changement d'épisode à 2 s.
                Item {
                    id: holdOverlay
                    anchors.centerIn: parent
                    width: root.btnSize + 14
                    height: width
                    z: 8
                    visible: root.active
                             && root.allowEpisodeLongPress
                             && root._transportPressActive
                             && root._transportArmed
                             && root._transportHoldIndex === btn.index
                             && (btn.kind === "prev" || btn.kind === "next")
                    property real displayedFrac: Math.max(0.0, Math.min(1.0, root._transportHoldProgress))
                    Behavior on displayedFrac {
                        NumberAnimation { duration: 90; easing.type: Easing.Linear }
                    }
                    onDisplayedFracChanged: holdProgressRing.requestPaint()
                    onWidthChanged: holdProgressRing.requestPaint()
                    onHeightChanged: holdProgressRing.requestPaint()
                    onVisibleChanged: holdProgressRing.requestPaint()

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 5
                        radius: width / 2
                        color: "#22000000"
                        border.width: 1
                        border.color: "#445078"
                        antialiasing: true
                    }
                    Canvas {
                        id: holdProgressRing
                        anchors.fill: parent
                        antialiasing: true
                        onPaint: {
                            var ctx = getContext("2d")
                            var cx = width * 0.5
                            var cy = height * 0.5
                            var lineW = 5
                            var radius = Math.max(1, Math.min(width, height) * 0.5 - lineW * 0.5 - 2)
                            var startAngle = -Math.PI * 0.5
                            var endAngle = startAngle + Math.PI * 2 * holdOverlay.displayedFrac
                            ctx.clearRect(0, 0, width, height)
                            ctx.lineWidth = lineW
                            ctx.lineCap = "round"
                            ctx.beginPath()
                            ctx.strokeStyle = "#35405f"
                            ctx.arc(cx, cy, radius, 0, Math.PI * 2, false)
                            ctx.stroke()
                            if (holdOverlay.displayedFrac > 0.001) {
                                ctx.beginPath()
                                ctx.strokeStyle = "#9aa9ff"
                                ctx.arc(cx, cy, radius, startAngle, endAngle, false)
                                ctx.stroke()
                            }
                        }
                        Component.onCompleted: requestPaint()
                    }
                }

                Canvas {
                    id: icon
                    anchors.fill: parent
                    antialiasing: true
                    function drawSeekJump(ctx, cx, cy, w, h, forward) {
                        ctx.save()
                        var isFocus = btn.focused && root.active
                        var col = isFocus ? Qt.rgba(1,1,1,1.0) : root.iconColor
                        ctx.strokeStyle = col; ctx.fillStyle = col
                        ctx.lineWidth = Math.max(isFocus ? 3.2 : 2.35, Math.round(w * (isFocus ? 0.044 : 0.034)))
                        ctx.lineCap = "butt"; ctx.lineJoin = "round"
                        if (isFocus) { ctx.shadowColor = "rgba(255,255,255,0.85)"; ctx.shadowBlur = 7 }
                        var r = Math.min(w,h)*0.318, deg = Math.PI/180.0
                        var start = forward ? (-332*deg) : (152*deg)
                        var end = forward ? (-38*deg) : (-142*deg)
                        ctx.beginPath(); ctx.arc(cx,cy,r,start,end,!forward); ctx.stroke()
                        var ex = cx+r*Math.cos(end), ey = cy+r*Math.sin(end)
                        var tangent = end + (forward ? Math.PI/2 : -Math.PI/2)
                        var tx=Math.cos(tangent), ty=Math.sin(tangent)
                        var len=Math.max(7.5,w*0.112), half=Math.max(4.8,w*0.072), push=Math.max(2.2,ctx.lineWidth*1.15)
                        var tipX=ex+push*tx, tipY=ey+push*ty, bx=tipX-len*tx, by=tipY-len*ty
                        var nx=Math.cos(tangent-Math.PI/2), ny=Math.sin(tangent-Math.PI/2)
                        ctx.beginPath(); ctx.moveTo(tipX,tipY); ctx.lineTo(bx+half*nx,by+half*ny); ctx.lineTo(bx-half*nx,by-half*ny); ctx.closePath(); ctx.fill()
                        if (isFocus) ctx.shadowBlur=4
                        ctx.font="bold "+Math.round(h*(isFocus?0.235:0.220))+"px sans-serif"
                        ctx.textAlign="center"; ctx.textBaseline="middle"; ctx.fillText("10",cx,cy+h*0.047)
                        ctx.restore()
                    }
                    function drawPrevNext(ctx,cx,cy,w,h,next) {
                        ctx.save(); ctx.fillStyle=root.iconColor
                        var triW=Math.round(w*0.18), triH=Math.round(h*0.34), gap=Math.round(w*0.02), barW=Math.round(w*0.06), yTop=cy-triH/2
                        if (next) {
                            ctx.fillRect(cx+triW+gap,cy-triH/2,barW,triH)
                            ctx.beginPath(); ctx.moveTo(cx-triW-gap,yTop); ctx.lineTo(cx-gap,cy); ctx.lineTo(cx-triW-gap,yTop+triH); ctx.closePath(); ctx.fill()
                            ctx.beginPath(); ctx.moveTo(cx,yTop); ctx.lineTo(cx+triW,cy); ctx.lineTo(cx,yTop+triH); ctx.closePath(); ctx.fill()
                        } else {
                            ctx.fillRect(cx-triW-gap-barW,cy-triH/2,barW,triH)
                            ctx.beginPath(); ctx.moveTo(cx+triW+gap,yTop); ctx.lineTo(cx+gap,cy); ctx.lineTo(cx+triW+gap,yTop+triH); ctx.closePath(); ctx.fill()
                            ctx.beginPath(); ctx.moveTo(cx,yTop); ctx.lineTo(cx-triW,cy); ctx.lineTo(cx,yTop+triH); ctx.closePath(); ctx.fill()
                        }
                        ctx.restore()
                    }
                    onPaint: {
                        var ctx=getContext("2d"); ctx.clearRect(0,0,width,height); var cx=width/2, cy=height/2
                        if (btn.kind === "play") {
                            ctx.fillStyle=root.iconColor
                            if (btn.playing) {
                                var w2=Math.round(width*0.08), h2=Math.round(height*0.38), gap2=Math.round(width*0.08), y=cy-h2/2
                                ctx.fillRect(cx-gap2-w2,y,w2,h2); ctx.fillRect(cx+gap2,y,w2,h2)
                            } else {
                                var rr=Math.min(width,height)*0.23
                                ctx.beginPath(); ctx.moveTo(cx-rr*0.6,cy-rr); ctx.lineTo(cx-rr*0.6,cy+rr); ctx.lineTo(cx+rr,cy); ctx.closePath(); ctx.fill()
                            }
                        } else if (btn.kind === "rew" || btn.kind === "fwd") drawSeekJump(ctx,cx,cy,width,height,btn.kind === "fwd")
                        else if (btn.kind === "prev" || btn.kind === "next") drawPrevNext(ctx,cx,cy,width,height,btn.kind === "next")
                    }
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                }
                Connections {
                    target: btn
                    function onFocusedChanged(){ icon.requestPaint(); root.userActivity() }
                    function onPlayingChanged(){ icon.requestPaint() }
                }
                Connections { target: root; function onIsPlayingChanged(){ if (btn.kind === "play") { btn.playing=root.isPlaying; icon.requestPaint() } } }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.userActivity()
                        if (btn.index===1) root.previousChapter()
                        else if (btn.index===2) root.rewind()
                        else if (btn.index===3) root.togglePlay()
                        else if (btn.index===4) root.forward()
                        else if (btn.index===5) root.nextChapter()
                    }
                }
            }
        }

        Loader { width: root.btnSize; height: root.btnSize; sourceComponent: roundButton; onLoaded: { item.index=1; item.kind="prev"; item.playing=false; item.focused=(root.focusIndex===1&&root.active) } }
        Loader { width: root.btnSize; height: root.btnSize; sourceComponent: roundButton; onLoaded: { item.index=2; item.kind="rew"; item.playing=false; item.focused=(root.focusIndex===2&&root.active) } }
        Loader { id: playLoader; width: root.btnSize; height: root.btnSize; sourceComponent: roundButton; onLoaded: { item.index=3; item.kind="play"; item.playing=root.isPlaying; item.focused=(root.focusIndex===3&&root.active) } }
        Loader { width: root.btnSize; height: root.btnSize; sourceComponent: roundButton; onLoaded: { item.index=4; item.kind="fwd"; item.playing=false; item.focused=(root.focusIndex===4&&root.active) } }
        Loader { width: root.btnSize; height: root.btnSize; sourceComponent: roundButton; onLoaded: { item.index=5; item.kind="next"; item.playing=false; item.focused=(root.focusIndex===5&&root.active) } }
        }
    }

    Rectangle {
        id: qualityButton

        width: 56
        height: 56
        radius: 28

        anchors.right: trackButtons.left
        anchors.rightMargin: 18

        anchors.bottom: parent.bottom
        anchors.bottomMargin:
            root.settingsBottomInset

        visible:
            root.settingsAllowed &&
            root.settingsVisible

        color:
            Qt.rgba(
                0,
                0,
                0,
                0.45)

        opacity:
            visible
                ? 0.98
                : 0.0

        border.width:
            root.settingsFocusedControl ===
            root.controlQuality
                ? 2
                : 1

        border.color:
            root.settingsFocusedControl ===
            root.controlQuality
                ? Qt.rgba(
                      1,
                      1,
                      1,
                      0.75)
                : Qt.rgba(
                      1,
                      1,
                      1,
                      0.25)

        z: 5

        Behavior on opacity {
            NumberAnimation {
                duration: 140
                easing.type:
                    Easing.OutCubic
            }
        }

        Rectangle {
            anchors.fill: parent

            radius:
                parent.radius

            color:
                Qt.rgba(
                    1,
                    1,
                    1,
                    0.15)

            opacity:
                root.settingsFocusedControl ===
                root.controlQuality
                    ? 1.0
                    : 0.0

            Behavior on opacity {
                NumberAnimation {
                    duration: 110
                    easing.type:
                        Easing.OutCubic
                }
            }
        }

        Item {
            anchors.centerIn: parent

            width: 30
            height: 28

            Rectangle {
                id: tvScreen

                anchors.horizontalCenter:
                    parent.horizontalCenter

                anchors.top:
                    parent.top

                width: 30
                height: 21
                radius: 3

                color: "transparent"

                border.width: 2
                border.color: "white"

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 4

                    radius: 1

                    color:
                        Qt.rgba(
                            1,
                            1,
                            1,
                            0.08)
                }
            }

            Rectangle {
                width: 2
                height: 5

                anchors.horizontalCenter:
                    parent.horizontalCenter

                anchors.top:
                    tvScreen.bottom

                color: "white"
            }

            Rectangle {
                width: 13
                height: 2
                radius: 1

                anchors.horizontalCenter:
                    parent.horizontalCenter

                anchors.bottom:
                    parent.bottom

                color: "white"
            }
        }

        MouseArea {
            anchors.fill: parent

            onClicked:
                root.settingsButtonClicked(
                    root.controlQuality)
        }
    }

    Rectangle {
        id: zoomButton

        width: 56
        height: 56
        radius: 28

        anchors.left: parent.left
        anchors.leftMargin: 80

        anchors.bottom: parent.bottom
        anchors.bottomMargin:
            root.settingsBottomInset

        visible:
            root.settingsAllowed &&
            root.settingsVisible

        color:
            Qt.rgba(
                0,
                0,
                0,
                0.45)

        opacity:
            visible
                ? 0.98
                : 0.0

        border.width:
            root.settingsFocusedControl ===
            root.controlZoom
                ? 2
                : 1

        border.color:
            root.settingsFocusedControl ===
            root.controlZoom
                ? Qt.rgba(
                      1,
                      1,
                      1,
                      0.75)
                : Qt.rgba(
                      1,
                      1,
                      1,
                      0.25)

        z: 5

        Behavior on opacity {
            NumberAnimation {
                duration: 140
                easing.type:
                    Easing.OutCubic
            }
        }

        Rectangle {
            anchors.fill: parent

            radius:
                parent.radius

            color:
                Qt.rgba(
                    1,
                    1,
                    1,
                    0.15)

            opacity:
                root.settingsFocusedControl ===
                root.controlZoom
                    ? 1.0
                    : 0.0

            Behavior on opacity {
                NumberAnimation {
                    duration: 110
                    easing.type:
                        Easing.OutCubic
                }
            }
        }

        Item {
            anchors.centerIn: parent

            width: 32
            height: 28

            Rectangle {
                anchors.centerIn: parent

                width: 27
                height: 18
                radius: 2

                color: "transparent"

                border.width: 2
                border.color: "white"
            }

            Rectangle {
                anchors.centerIn: parent

                width: 17
                height: 10
                radius: 1

                color: "transparent"

                border.width: 1

                border.color:
                    Qt.rgba(
                        1,
                        1,
                        1,
                        0.85)
            }

            Rectangle {
                width: 5
                height: 2

                anchors.right:
                    parent.right

                anchors.top:
                    parent.top

                color: "white"
            }

            Rectangle {
                width: 2
                height: 5

                anchors.right:
                    parent.right

                anchors.top:
                    parent.top

                color: "white"
            }
        }

        MouseArea {
            anchors.fill: parent

            onClicked:
                root.settingsButtonClicked(
                    root.controlZoom)
        }
    }

    Rectangle {
        id: speedButton

        width: 56
        height: 56
        radius: 28

        anchors.left: parent.left
        anchors.leftMargin: 150

        anchors.bottom: parent.bottom
        anchors.bottomMargin:
            root.settingsBottomInset

        visible:
            root.settingsAllowed &&
            root.settingsVisible

        color:
            Qt.rgba(
                0,
                0,
                0,
                0.45)

        opacity:
            visible
                ? 0.98
                : 0.0

        border.width:
            root.settingsFocusedControl ===
            root.controlSpeed
                ? 2
                : 1

        border.color:
            root.settingsFocusedControl ===
            root.controlSpeed
                ? Qt.rgba(
                      1,
                      1,
                      1,
                      0.75)
                : Qt.rgba(
                      1,
                      1,
                      1,
                      0.25)

        z: 5

        Behavior on opacity {
            NumberAnimation {
                duration: 140
                easing.type:
                    Easing.OutCubic
            }
        }

        Rectangle {
            anchors.fill: parent

            radius:
                parent.radius

            color:
                Qt.rgba(
                    1,
                    1,
                    1,
                    0.15)

            opacity:
                root.settingsFocusedControl ===
                root.controlSpeed
                    ? 1.0
                    : 0.0

            Behavior on opacity {
                NumberAnimation {
                    duration: 110
                    easing.type:
                        Easing.OutCubic
                }
            }
        }

        Text {
            anchors.centerIn: parent

            text:
                Math.abs(
                    root.selectedRate - 1.0) < 0.001
                    ? "1x"
                    : root.selectedRate
                          .toFixed(2)
                          .replace(".", ",") +
                      "x"

            color: "white"

            font.pixelSize:
                Math.abs(
                    root.selectedRate - 1.0) < 0.001
                    ? 19
                    : 14

            font.bold: true
        }

        MouseArea {
            anchors.fill: parent

            onClicked:
                root.settingsButtonClicked(
                    root.controlSpeed)
        }
    }

    Row {
        id: trackButtons

        anchors.right:
            parent.right

        anchors.rightMargin: 32

        anchors.bottom:
            parent.bottom

        anchors.bottomMargin:
            root.settingsBottomInset

        spacing: 18

        visible:
            root.settingsAllowed &&
            root.settingsVisible

        z: 5

        Rectangle {
            width: 56
            height: 56
            radius: 28

            opacity: 0.98

            color:
                Qt.rgba(
                    0,
                    0,
                    0,
                    0.45)

            border.width:
                root.settingsFocusedControl ===
                root.controlAudio
                    ? 2
                    : 1

            border.color:
                root.settingsFocusedControl ===
                root.controlAudio
                    ? Qt.rgba(
                          1,
                          1,
                          1,
                          0.75)
                    : Qt.rgba(
                          1,
                          1,
                          1,
                          0.25)

            Rectangle {
                anchors.fill: parent

                radius: 28

                color:
                    Qt.rgba(
                        1,
                        1,
                        1,
                        0.15)

                visible:
                    root.settingsFocusedControl ===
                    root.controlAudio
            }

            Item {
                anchors.centerIn: parent

                width: 24
                height: 24

                opacity: 0.96

                Rectangle {
                    x: 4
                    y: 8

                    width: 3
                    height: 12

                    radius: 1.5

                    color: "white"
                }

                Rectangle {
                    x: 11
                    y: 4

                    width: 3
                    height: 16

                    radius: 1.5

                    color: "white"
                }

                Rectangle {
                    x: 18
                    y: 11

                    width: 3
                    height: 9

                    radius: 1.5

                    color: "white"
                }
            }

            MouseArea {
                anchors.fill: parent

                onClicked:
                    root.settingsButtonClicked(
                        root.controlAudio)
            }
        }

        Rectangle {
            width: 56
            height: 56
            radius: 28

            opacity: 0.98

            color:
                Qt.rgba(
                    0,
                    0,
                    0,
                    0.45)

            border.width:
                root.settingsFocusedControl ===
                root.controlSubtitle
                    ? 2
                    : 1

            border.color:
                root.settingsFocusedControl ===
                root.controlSubtitle
                    ? Qt.rgba(
                          1,
                          1,
                          1,
                          0.75)
                    : Qt.rgba(
                          1,
                          1,
                          1,
                          0.25)

            Rectangle {
                anchors.fill: parent

                radius: 28

                color:
                    Qt.rgba(
                        1,
                        1,
                        1,
                        0.15)

                visible:
                    root.settingsFocusedControl ===
                    root.controlSubtitle
            }

            Item {
                anchors.centerIn: parent

                width: 25
                height: 20

                opacity: 0.96

                Rectangle {
                    anchors.fill: parent

                    radius: 4

                    color: "transparent"

                    border.width: 2
                    border.color: "white"
                }

                Rectangle {
                    x: 5
                    y: 6

                    width: 15
                    height: 2

                    radius: 1

                    color: "white"
                }

                Rectangle {
                    x: 5
                    y: 12

                    width: 11
                    height: 2

                    radius: 1

                    color: "white"
                }
            }

            MouseArea {
                anchors.fill: parent

                onClicked:
                    root.settingsButtonClicked(
                        root.controlSubtitle)
            }
        }
    }

    onFocusIndexChanged: {
        
        if (_transportHoldIndex && _transportHoldIndex !== focusIndex) _cancelTransportHold()
        for (var i=0;i<row.children.length;i++){ var c=row.children[i]; if(c.item) c.item.focused=(c.item.index===focusIndex&&active) }
        userActivity(); focusChanged(focusIndex)
    }
    onActiveChanged: {
        
        if (!active) _cancelTransportHold()
        for (var i=0;i<row.children.length;i++){ var l=row.children[i]; if(l.item){ try{l.item.iconRef.requestPaint()}catch(e){} } }
    }
    Component.onDestruction: _cancelTransportHold()

    Keys.onPressed: {
        
        // Quand la barre est focalisée, elle reprend exactement les raccourcis
        // de l'ancienne barre de progression séparée.
        if (focused) {
            userActivity()
            if (event.key === Qt.Key_Left) {
                
                seekRequested(-10000)
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Right) {
                
                seekRequested(10000)
                event.accepted = true
                return
            }
            if (_isOk(event.key) || event.key === Qt.Key_Space) {
                toggleRequested()
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Up) {
                
                focusUp()
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Down) {
                
                focusDown()
                event.accepted = true
                return
            }
            return
        }

        if (!active) return
        userActivity()
        if (event.key===Qt.Key_Left) {
            
            focusIndex=Math.max(1,focusIndex-1)
            event.accepted=true
        } else if (event.key===Qt.Key_Right) {
            
            if(focusIndex<5) focusIndex++
            else moveRight()
            event.accepted=true
        } else if (_isOk(event.key)) {
            if (focusIndex===1 || focusIndex===5) {
                if (!event.isAutoRepeat) _startTransportHold(focusIndex)
            } else if (focusIndex===2) rewind()
            else if (focusIndex===3) togglePlay()
            else if (focusIndex===4) forward()
            event.accepted=true
        } else if (event.key===Qt.Key_Space) {
            togglePlay()
            event.accepted=true
        }
    }

    Keys.onReleased: {
        
        if (focused) return
        if (!active) return
        if (_isOk(event.key) && (_transportHoldIndex===1 || _transportHoldIndex===5)) {
            event.accepted=true
            if (event.isAutoRepeat) return
            _finishTransportHold()
            userActivity()
        }
    }
}
