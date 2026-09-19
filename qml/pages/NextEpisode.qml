// NextEpisode.qml — QtQuick 2.15
import QtQuick 2.15
import "../js/jellyfinBridge.js" as Jellyfin

FocusScope {
    id: root

    /* ==== API injectée ==== */
    property string serverUrl: ""
    property string accessToken: ""
    property string currentItemId: ""
    property var    playlist: []
    property int    uiMs: 0
    property int    durMs: 0
    property int    triggerWindowMs: 30000
    property bool   autoStartWhenZero: false

    /* ==== Safe area ==== */
    property int safeMarginRight: 48
    property int safeMarginBottom: 48

    /* ==== Couleurs ==== */
    property color focusBlue:   "#2F6BFF"
    property color ringWhite:   "white"
    property int   ringWidth:   2
    property color neutralBg:   "#2b2f47"
    property color neutralBor:  "#3c4566"
    property color frameColor:  Qt.rgba(0,0,0,0.60)
    property color frameBorder: "#66FFFFFF"

    /* ==== Clamp texte ==== */
    property int maxTitleChars: 50
    function clampTitle(s) {
        s = (s === undefined || s === null) ? "" : ("" + s)
        // 30 chars max, "…" inclus
        return (s.length > maxTitleChars) ? (s.slice(0, maxTitleChars - 1) + "…") : s
    }

    /* ==== État interne ==== */
    property string nextItemId: ""
    property var    nextItem: null
    property string nextTitle: ""        // version clampée (affichage)
    property string nextTitleRaw: ""     // SÉCURITÉ : titre complet interne uniquement, ne jamais logger brut
    property int    nextDurationMin: 0
    property string endTimeStr: ""
    property bool   dismissed: false
    property bool   ready: true                 // prêt côté NextEpisode (métadonnées chargées)
    property bool   locallyHidden: false        // masquage local (anti-clignotement)
    property bool   externGate: true            // 🔒 porte externe (pilotée par le parent)

    // Expose pour le parent
    readonly property bool panelVisible: showPanel
    function _p2(n){ return (n<10?"0":"")+n }

    readonly property int  remainingMs: Math.max(0, durMs - uiMs)
    readonly property int  secondsLeft: Math.max(0, Math.ceil(remainingMs/1000))
    readonly property bool hasNext: !!nextItemId

    // 🔒 gating par externGate + ready + états locaux
    readonly property bool showPanel:
        externGate && ready && !locallyHidden && !dismissed && hasNext &&
        durMs>0 && remainingMs>0 && remainingMs<=triggerWindowMs

    width: implicitWidth
    height: implicitHeight
    visible: showPanel
    enabled: showPanel          // coupe aussi les events quand masqué
    opacity: visible ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

    // Focus interne: 1 = Regarder, 2 = Cacher
    property int focusIndex: 2
    function setFocus(i){ focusIndex = (i<=1 ? 1 : 2) }
    focus: visible

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: {
        if (!visible) return
        if (event.key === Qt.Key_Left)  { setFocus(focusIndex-1); event.accepted = true; return }
        if (event.key === Qt.Key_Right) { setFocus(focusIndex+1); event.accepted = true; return }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
            if (focusIndex === 1) {
                // hide d'abord, puis start
                ready = false
                locallyHidden = true
                requestHide()
                requestStartNow()
            } else {
                dismissForThisItem()
                locallyHidden = true
                requestHide()
            }
            event.accepted = true; return
        }
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
            dismissForThisItem(); locallyHidden = true; requestHide(); event.accepted = true; return
        }
    }
    onVisibleChanged: if (visible) Qt.callLater(function(){ setFocus(2); root.forceActiveFocus() })

    /* ==== Normalisation playlist ==== */
    function normalizeList(list) {
        var a = list || [], out = []
        for (var i=0;i<a.length;i++){
            var v = a[i]
            if (v && typeof v === "object") {
                if (v.Id!=null) out.push(String(v.Id))
                else if (v.id!=null) out.push(String(v.id))
                else out.push(String(v))
            } else out.push(String(v))
        }
        return out
    }

    /* ==== API publique ==== */
    function resetForNewItem(){
        // réarmement propre à CHAQUE épisode → corrige la persistance du “hide”
        dismissed = false
        locallyHidden = false
        ready = false
        nextItemId = ""; nextItem = null; nextTitle = ""; nextTitleRaw = ""; nextDurationMin = 0; endTimeStr = ""
        Qt.callLater(function(){ findNextByPlaylist(currentItemId, playlist) })
    }

    onCurrentItemIdChanged: Qt.callLater(function(){
        dismissed = false
        locallyHidden = false
        ready = false
        findNextByPlaylist(currentItemId, playlist)
    })
    onPlaylistChanged: Qt.callLater(function(){
        findNextByPlaylist(currentItemId, playlist)
    })

    function findNextByPlaylist(curId, list){
        var iid = String(curId||"")
        var arr = normalizeList(list)
        var i = arr.indexOf(iid)
        if (i>=0 && i < arr.length-1) {
            nextItemId = arr[i+1]
            fetchNextMeta()
        } else {
            nextItemId = ""
            nextItem=null; nextTitle=""; nextTitleRaw=""; nextDurationMin=0; endTimeStr=""
            // Pas de prochain → rien à afficher, mais on est “prêt”
            ready = true
        }
    }

    function fetchNextMeta(){
        if (!serverUrl || !accessToken || !nextItemId) { ready = true; return }
        Jellyfin.fetchItem(serverUrl, accessToken, nextItemId,
            function(res){
                nextItem = res || null
                var name = (res && res.Name) ? res.Name : ""
                if (res && res.Type==="Episode") {
                    var s=(res.ParentIndexNumber!=null)?res.ParentIndexNumber:""
                    var e=(res.IndexNumber!=null)?res.IndexNumber:""
                    if (s!=="" && e!=="") name = "S"+s+"E"+e+" • "+name
                    if (res.SeriesName) name = res.SeriesName + " — " + name
                }

                nextTitleRaw = name
                nextTitle = clampTitle(name)

                nextDurationMin = (res && res.RunTimeTicks)
                                ? Math.max(1, Math.round((res.RunTimeTicks/10000)/60000))
                                : 0

                var end = new Date(Date.now() + nextDurationMin*60000)
                endTimeStr = _p2(end.getHours()) + ":" + _p2(end.getMinutes())

                ready = true   // ré-autorise l’affichage quand les metas sont là
            },
            function(){
                nextItem=null; nextTitle=""; nextTitleRaw=""; nextDurationMin=0; endTimeStr=""; ready = true
            }
        )
    }

    function dismissForThisItem(){ dismissed = true }
    signal requestStartNow()
    signal requestHide()

    // Auto-start (hide d'abord, puis start)
    Timer {
        interval: 200
        repeat: true
        running: root.visible && root.autoStartWhenZero
        onTriggered: {
            if (root.secondsLeft <= 0 && root.visible) {
                root.ready = false
                root.locallyHidden = true
                root.requestHide()
                root.requestStartNow()
            }
        }
    }

    /* ===== UI ===== */
    Item {
        id: dock
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: root.safeMarginRight
        anchors.bottomMargin: root.safeMarginBottom

        Rectangle {
            id: card
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            radius: 12
            color: frameColor
            border.width: 1
            border.color: frameBorder
            clip: true                          // 🔥 anti-débordement ultime
            transformOrigin: Item.BottomRight

            width:  Math.min(460, Math.max(360, content.implicitWidth + 32))
            height: content.implicitHeight + 32

            Column {
                id: content
                x: 16; y: 16
                spacing: 8

                Text {
                    id: txtCountdown
                    text: "Prochain épisode dans " + root.secondsLeft + " s"
                    textFormat: Text.PlainText
                    color: "#f1f4ff"
                    font.pixelSize: 18
                    font.bold: true
                    elide: Text.ElideRight
                }

                Text {
                    id: txtTitle
                    text: root.nextTitle   // déjà clampé à 30 chars
                    textFormat: Text.PlainText
                    color: "#ffffff"
                    font.pixelSize: 16
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                }

                Row {
                    spacing: 12
                    Text {
                        text: (nextDurationMin>0 ? (nextDurationMin + " min") : "")
                        textFormat: Text.PlainText
                        color: "#c9d1ff"
                        font.pixelSize: 13
                        visible: nextDurationMin>0
                    }
                    Text {
                        text: (endTimeStr.length ? ("fin ~ " + endTimeStr) : "")
                        textFormat: Text.PlainText
                        color: "#c9d1ff"
                        font.pixelSize: 13
                        visible: endTimeStr.length>0
                    }
                }

                Row {
                    id: rowButtons
                    spacing: 10

                    // Regarder maintenant
                    Item {
                        width: 220; height: 40
                        Rectangle {
                            anchors.fill: parent; anchors.margins: -ringWidth; radius: 8 + ringWidth
                            color: "transparent"
                            border.color: (root.focusIndex===1 ? ringWhite : "transparent")
                            border.width: ringWidth
                        }
                        Rectangle {
                            anchors.fill: parent; radius: 8
                            color: (root.focusIndex===1 ? focusBlue : neutralBg)
                            border.width: 1
                            border.color: (root.focusIndex===1 ? "#88A7FF" : neutralBor)
                        }
                        MouseArea {
                            anchors.fill: parent; hoverEnabled: true
                            onEntered: root.setFocus(1)
                            onClicked: {
                                root.setFocus(1)
                                root.ready = false
                                root.locallyHidden = true   // cache d’abord
                                root.requestHide()          // notifie le parent (verrou UI off)
                                root.requestStartNow()      // puis switch
                            }
                        }
                        Text {
                            anchors.centerIn: parent
                            text: "Regarder maintenant"
                            textFormat: Text.PlainText
                            color: "white"
                            font.pixelSize: 16
                        }
                    }

                    // Cacher
                    Item {
                        width: 120; height: 40
                        Rectangle {
                            anchors.fill: parent; anchors.margins: -ringWidth; radius: 8 + ringWidth
                            color: "transparent"
                            border.color: (root.focusIndex===2 ? ringWhite : "transparent")
                            border.width: ringWidth
                        }
                        Rectangle {
                            anchors.fill: parent; radius: 8
                            color: (root.focusIndex===2 ? focusBlue : neutralBg)
                            border.width: 1
                            border.color: (root.focusIndex===2 ? "#88A7FF" : neutralBor)
                        }
                        MouseArea {
                            anchors.fill: parent; hoverEnabled: true
                            onEntered: root.setFocus(2)
                            onClicked: {
                                root.setFocus(2)
                                root.dismissForThisItem()
                                root.locallyHidden = true
                                root.requestHide()
                            }
                        }
                        Text {
                            anchors.centerIn: parent
                            text: "Cacher"
                            textFormat: Text.PlainText
                            color: "white"
                            font.pixelSize: 16
                        }
                    }
                }
            }
        }
    }
}
