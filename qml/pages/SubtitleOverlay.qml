// SubtitleOverlay.qml — rendu local proche Jellyfin serveur/remux
// QtQuick 2.15 uniquement, sans QtQuick Controls
import QtQuick 2.15

Item {
    id: root

    // ===== API lecture =====
    // "enabled" existe déjà sur Item : PlayerOverlay peut continuer à faire item.enabled = ...
    enabled: false

    property var   cues: []            // [{s:ms,e:ms,t:""}] triés par s
    // Décalage utilisateur optionnel :
    //   +500 ms = afficher le sous-titre 500 ms PLUS TARD.
    // La synchronisation normale reste toujours à 0 ms.
    property int   delayMs: 0

    // Horloge ABSOLUE du média en millisecondes, fournie par PlayerOverlay.
    // Elle correspond à baseOffsetMs + MediaPlayer.position et non à une
    // position UI/prédictive de seek.
    property int   uiMs: 0
    property bool  controlsVisible: false
    property bool  gateArmed: false
    property bool  hideWhenControlsVisible: false

    // ===== Positionnement universel =====
    // Optionnel : rectangle exact de la zone vidéo dans le repère du parent fullscreen.
    // Exemple possible : Qt.rect(videoItem.x, videoItem.y, videoItem.width, videoItem.height)
    property rect  videoRect: Qt.rect(0, 0, 0, 0)

    // Marges quand le composant est utilisé en mode fullscreen.
    // Objectif : bas écran, proche rendu serveur/remux.
    property int   padNoControls: -100
    property int   padWithControls: -100

    // + => plus bas, - => plus haut.
    // Valeur par défaut volontairement plus agressive pour descendre les sous-titres.
    property int   yOffset: 150

    // Safe area TVs / overscan.
    // Baissé à 2 % pour éviter que le safe area garde les ST trop haut.
    property int   safeBottomPct: 2

    // Si true : remonte les sous-titres au-dessus du bas réel de l’image vidéo.
    // Si false : vise le bas de l’écran, plus proche de ce que tu veux ici.
    property bool  respectVideoBottomInset: false

    // ===== Rendu / style façon remux serveur =====
    property string currentText: ""
    property int    tickMs: 0

    property int    maxWidthPx: 1480
    property real   widthRatio: 0.80

    property int    subtitlePixelSize: 40
    property bool   subtitleBold: true
    property color  subtitleColor: "#F7F7F7"
    property color  subtitleOutlineColor: "#000000"

    // Contour manuel + contour Qt.
    // Le contour manuel donne l'épaisseur visible, le contour Qt bouche les micro-trous.
    property int    subtitleOutlinePx: 3
    property bool   useBuiltInOutline: true

    property real   subtitleLineHeight: 0.92
    property int    subtitleMaxLines: 2

    // Important : QtRendering garde mieux les contours Text.Outline sur Qt 5 / Freebox.
    property bool   nativeRendering: false
    property string subtitleFontFamily: ""

    // Ombre légère en plus du contour, pour retrouver le côté "net écran TV".
    property bool   subtitleShadow: true
    property int    subtitleShadowOffset: 2
    property color  subtitleShadowColor: "#CC000000"

    // ===== Géométrie robuste =====
    readonly property bool _hasRect: (videoRect.width > 0 && videoRect.height > 0)

    // Si le parent ressemble à une surface écran, le composant se positionne seul.
    // Si le parent est un Loader sans taille fullscreen, on laisse PlayerOverlay gérer le bas.
    readonly property bool _useInternalPosition: (
        parent &&
        parent.width >= 640 &&
        parent.height >= 360
    )

    readonly property real _surfaceW: _useInternalPosition
                                      ? parent.width
                                      : 1920

    readonly property real _usableW: _hasRect
                                     ? videoRect.width
                                     : _surfaceW

    readonly property int _outlinePad: Math.max(3, subtitleOutlinePx + 3)
    readonly property int _manualOutlinePx: Math.max(1, subtitleOutlinePx)
    readonly property int _manualOutlineDiagPx: Math.max(1, Math.round(subtitleOutlinePx * 0.72))

    readonly property int _contentYOffset: _useInternalPosition ? 0 : yOffset

    readonly property bool _subtitleVisible: enabled
                                             && !gateArmed
                                             && (!hideWhenControlsVisible || !controlsVisible)
                                             && currentText.length > 0

    width: Math.min(_usableW * widthRatio, maxWidthPx)

    height: Math.max(
        1,
        Math.ceil(mainText.paintedHeight + (_outlinePad * 2) + Math.abs(_contentYOffset))
    )

    x: {
        if (_useInternalPosition && _hasRect)
            return Math.round(videoRect.x + (videoRect.width - width) / 2)

        if (_useInternalPosition && parent)
            return Math.round((parent.width - width) / 2)

        return 0
    }

    anchors.bottom: (_useInternalPosition && parent) ? parent.bottom : undefined

    anchors.bottomMargin: {
        if (!_useInternalPosition || !parent)
            return 0

        var safe = Math.round(parent.height * (safeBottomPct / 100.0))
        var base = padNoControls

        var letterbox = 0
        if (respectVideoBottomInset && _hasRect)
            letterbox = Math.max(0, parent.height - (videoRect.y + videoRect.height))

        var m = Math.max(safe, base) + letterbox - yOffset

        // On garde une mini marge pour éviter l'overscan violent sur certaines TV.
        return Math.max(8, m)
    }

    visible: _subtitleVisible
    z: 500
    focus: false
    clip: false

    // ===== Nettoyage texte =====
    function _limitText(s, maxLen) {
        s = String(s || "")
        maxLen = maxLen || 900
        return s.length > maxLen ? s.substr(0, maxLen) : s
    }

    function _cleanText(raw) {
        var s = String(raw || "")

        // ASS/SSA : {\an8}, {\i1}, etc.
        s = s.replace(/\{\\[^}]*\}/g, "")

        // Retours ligne ASS
        s = s.replace(/\\N/g, "\n")
        s = s.replace(/\\n/g, "\n")

        // Tags WebVTT/SRT simples : <i>, <b>, <font>, <c.color>, etc.
        s = s.replace(/<[^>]+>/g, "")

        // Entités fréquentes
        s = s.replace(/&nbsp;/g, " ")
        s = s.replace(/&amp;/g, "&")
        s = s.replace(/&lt;/g, "<")
        s = s.replace(/&gt;/g, ">")
        s = s.replace(/&quot;/g, "\"")
        s = s.replace(/&#39;/g, "'")

        // Nettoyage espaces
        s = s.replace(/[ \t]+\n/g, "\n")
        s = s.replace(/\n[ \t]+/g, "\n")
        s = s.replace(/\n{3,}/g, "\n\n")

        return _limitText(s.trim(), 900)
    }

    // ===== Recherche binaire sur cues =====
    function findTextAt(t) {
        if (!cues || cues.length === 0)
            return ""

        var lo = 0
        var hi = cues.length - 1
        var mid
        var c

        while (lo <= hi) {
            mid = (lo + hi) >> 1
            c = cues[mid]

            if (!c)
                return ""

            if (t < c.s) {
                hi = mid - 1
            } else if (t >= c.e) {
                lo = mid + 1
            } else {
                return _cleanText(c.t)
            }
        }

        return ""
    }

    function updateText() {
        var next = ""

        if (enabled && cues && cues.length > 0 && !gateArmed) {
            // uiMs est déjà l'horloge absolue du média.
            // Aucun offset automatique/empirique n'est appliqué ici.
            //
            // Signe volontaire :
            //   delayMs > 0 => sous-titre retardé
            //   delayMs < 0 => sous-titre avancé
            var mediaMs = Math.max(0, Math.floor(Number(uiMs) || 0))
            var userDelay = Math.floor(Number(delayMs) || 0)
            var cueClockMs = Math.max(0, mediaMs - userDelay)
            next = findTextAt(cueClockMs)
        }

        if (next !== currentText)
            currentText = next
    }

    onUiMsChanged: updateText()
    onDelayMsChanged: updateText()
    onCuesChanged: updateText()
    onEnabledChanged: updateText()
    onGateArmedChanged: updateText()
    onControlsVisibleChanged: updateText()
    // Optionnel : ré-échantillonnage périodique
    Timer {
        id: tick
        interval: Math.max(60, root.tickMs)
        repeat: true
        running: root.tickMs > 0 && root.enabled && !root.gateArmed
        onTriggered: root.updateText()
    }

    onTickMsChanged: {
        if (tickMs > 0 && enabled && !gateArmed)
            tick.start()
        else
            tick.stop()
    }

    // ===== Sous-titre : contour manuel multi-couches =====
    Item {
        id: subtitleLayer
        visible: root._subtitleVisible
        width: root.width
        height: Math.max(1, mainText.paintedHeight + (root._outlinePad * 2))
        y: root._outlinePad + root._contentYOffset
        clip: false

        // Ombre douce arrière
        Text {
            visible: root.subtitleShadow
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.horizontalCenterOffset: root.subtitleShadowOffset
            y: root.subtitleShadowOffset
            width: parent.width

            text: root.currentText
            color: root.subtitleShadowColor
            textFormat: Text.PlainText

            font.family: root.subtitleFontFamily
            font.pixelSize: root.subtitlePixelSize
            font.bold: root.subtitleBold

            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            maximumLineCount: root.subtitleMaxLines
            lineHeight: root.subtitleLineHeight
            lineHeightMode: Text.ProportionalHeight

            renderType: root.nativeRendering ? Text.NativeRendering : Text.QtRendering
            smooth: true
        }

        // Contour noir manuel allégé.
        // 8 directions au lieu de 20 Text : même intention visuelle, beaucoup moins de glyphes
        // à rasteriser pendant la lecture. Le Text.Outline du mainText reste le filet de sécurité
        // pour boucher les micro-trous sur Qt 5 / Freebox.
        Repeater {
            model: [
                { dx: -root._manualOutlinePx,     dy:  0 },
                { dx:  root._manualOutlinePx,     dy:  0 },
                { dx:  0,                         dy: -root._manualOutlinePx },
                { dx:  0,                         dy:  root._manualOutlinePx },
                { dx: -root._manualOutlineDiagPx, dy: -root._manualOutlineDiagPx },
                { dx:  root._manualOutlineDiagPx, dy: -root._manualOutlineDiagPx },
                { dx: -root._manualOutlineDiagPx, dy:  root._manualOutlineDiagPx },
                { dx:  root._manualOutlineDiagPx, dy:  root._manualOutlineDiagPx }
            ]

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.horizontalCenterOffset: modelData.dx
                y: modelData.dy
                width: parent.width

                text: root.currentText
                color: root.subtitleOutlineColor
                textFormat: Text.PlainText

                font.family: root.subtitleFontFamily
                font.pixelSize: root.subtitlePixelSize
                font.bold: root.subtitleBold

                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                maximumLineCount: root.subtitleMaxLines
                lineHeight: root.subtitleLineHeight
                lineHeightMode: Text.ProportionalHeight

                renderType: root.nativeRendering ? Text.NativeRendering : Text.QtRendering
                smooth: true
            }
        }

        // Texte principal blanc + Text.Outline en filet de sécurité.
        Text {
            id: mainText
            anchors.horizontalCenter: parent.horizontalCenter
            y: 0
            width: parent.width

            text: root.currentText
            color: root.subtitleColor
            textFormat: Text.PlainText

            font.family: root.subtitleFontFamily
            font.pixelSize: root.subtitlePixelSize
            font.bold: root.subtitleBold

            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            maximumLineCount: root.subtitleMaxLines
            lineHeight: root.subtitleLineHeight
            lineHeightMode: Text.ProportionalHeight

            style: root.useBuiltInOutline ? Text.Outline : Text.Normal
            styleColor: root.subtitleOutlineColor

            renderType: root.nativeRendering ? Text.NativeRendering : Text.QtRendering
            smooth: true
        }
    }

}
