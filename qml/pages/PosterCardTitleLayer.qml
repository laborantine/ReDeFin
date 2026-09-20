// ReDeFin PosterCardTitleLayer
// Moteur texte/marquee commun à PosterGridCard et LibraryPosterCard.
// QtQuick 2.15 + QtGraphicalEffects 1.15, sans QtQuick Controls.
import QtQuick 2.15
import QtGraphicalEffects 1.15

Item {
    id: titleClip
    anchors.fill: parent
    clip: true

    // Contrat volontairement générique : les deux renderers exposent déjà
    // les propriétés/fonctions nécessaires au moteur de titre.
    property var card: null

    readonly property bool hasSubtitle:
        !!card && String(card.effectiveSubtitleText || "").length > 0

    readonly property int marqueeGap:
        !!card && card.marqueeGapPx !== undefined
        ? Math.max(0, Number(card.marqueeGapPx) || 0)
        : 44

    readonly property real titlePaintedW: titleTextItem.paintedWidth
    readonly property bool marqueeNeeded: titlePaintedW > titleLineClip.width
    readonly property real marqueeOverflow:
        Math.max(0, titlePaintedW - titleLineClip.width)
    readonly property real marqueeTravel:
        _travel(titlePaintedW, marqueeGap, marqueeNeeded)
    readonly property real marqueeExitX:
        marqueeTravel > 0 ? -marqueeTravel : 0
    readonly property int marqueeScrollMs:
        _scrollMs(marqueeTravel)
    readonly property int marqueeFadeW:
        _fadeWidth(titleLineClip.width, 26, 46)
    readonly property bool marqueeArmed:
        marqueeNeeded && _marqueeFocusActive()
    property bool marqueeMoving: false
    // Les callbacks différés Qt.callLater survivaient parfois au recyclage d'un
    // delegate. Un Timer enfant est détruit avec ce composant et ne peut donc pas
    // rappeler une fonction QML dans un contexte déjà invalide.
    property bool _destroying: false
    readonly property bool maskActive:
        marqueeArmed && marqueeMoving && _marqueeFocusActive()
    readonly property bool leftFadeActive:
        maskActive && titleTextItem.x < -2
    readonly property bool rightFadeActive:
        maskActive && titleTextItem.x > -marqueeOverflow + 2

    function _isUsable() {
        if (_destroying) return false
        try {
            return !!card && card._alive !== false
        } catch(e) {}
        return false
    }

    function _boolProp(name, fallback) {
        try {
            if (card && card[name] !== undefined && card[name] !== null)
                return card[name] === true
        } catch(e) {}
        return fallback === true
    }

    function _numProp(name, fallback) {
        try {
            var v = card ? Number(card[name]) : NaN
            if (isFinite(v) && !isNaN(v))
                return v
        } catch(e) {}
        return fallback
    }

    function _valueProp(name, fallback) {
        try {
            if (card && card[name] !== undefined && card[name] !== null)
                return card[name]
        } catch(e) {}
        return fallback
    }

    function _marqueeFocusActive() {
        return _boolProp("marqueeFocusActive", false)
    }

    function _travel(paintedWidth, gap, enabled) {
        try {
            if (card && card.marqueeTravelFor)
                return card.marqueeTravelFor(paintedWidth, gap, enabled)
        } catch(e0) {}
        return enabled ? Math.max(0, paintedWidth + gap) : 0
    }

    function _scrollMs(travel) {
        try {
            if (card && card.marqueeScrollMsFor)
                return card.marqueeScrollMsFor(travel)
        } catch(e0) {}
        var speed = Math.max(1, _numProp("marqueeSpeedPxPerSec", 1000.0 / 24.0))
        return travel > 0
                ? Math.max(3200, Math.min(14000,
                           Math.round((travel / speed) * 1000)))
                : 0
    }

    function _fadeWidth(lineWidth, minW, maxW) {
        try {
            if (card && card.fadeWidthFor)
                return card.fadeWidthFor(lineWidth, minW, maxW)
        } catch(e0) {}
        return Math.min(maxW, Math.max(minW, Math.round(lineWidth * 0.18)))
    }

    function _centeredY(lineHeight, textHeight) {
        try {
            if (card && card.centeredTextY)
                return card.centeredTextY(lineHeight, textHeight)
        } catch(e0) {}
        return Math.round((lineHeight - textHeight) / 2)
    }

    function _isEpisode() {
        try {
            if (card && card.isEpisodeItemSafe)
                return card.isEpisodeItemSafe(card.modelData)
        } catch(e0) {}
        try {
            return !!card && card.modelData
                    && String(card.modelData.Type || "").toLowerCase() === "episode"
        } catch(e1) {}
        return false
    }

    function _resetMarqueeState() {
        marqueeUpdateTimer.stop()
        titleMarqueeStartTimer.stop()
        subtitleMarqueeStartTimer.stop()
        marquee.stop()
        subtitleMarquee.stop()

        marqueeMoving = false
        subtitleLineClip.marqueeMoving = false

        titleTextItem.x = 0
        titleTextItem.opacity = 1.0
        subtitleTextItem.x = 0
        subtitleTextItem.opacity = 1.0
    }

    function _requestUpdateMarquee(reason) {
        if (_destroying) return
        marqueeUpdateTimer.restart()
    }

    Timer {
        id: marqueeUpdateTimer
        interval: 0
        repeat: false
        onTriggered: {
            if (titleClip._isUsable())
                titleClip.updateMarquee()
        }
    }

    Timer {
        id: titleMarqueeStartTimer
        interval: 0
        repeat: false
        onTriggered: {
            if (titleClip._isUsable()
                    && titleClip.marqueeNeeded
                    && titleClip._marqueeFocusActive()) {
                marquee.start()
            }
        }
    }

    Timer {
        id: subtitleMarqueeStartTimer
        interval: 0
        repeat: false
        onTriggered: {
            if (titleClip._isUsable()
                    && subtitleLineClip.marqueeNeeded
                    && titleClip._marqueeFocusActive()) {
                subtitleMarquee.start()
            }
        }
    }

    function updateMarquee() {
        _resetMarqueeState()

        if (!_isUsable()
                || !_boolProp("allowMarquee", false)
                || !_boolProp("allowAnims", false)
                || !_boolProp("allowLoad", false)
                || !_boolProp("selected", false)) {
            return
        }

        if (marqueeNeeded && marqueeScrollMs > 0)
            titleMarqueeStartTimer.restart()

        if (subtitleLineClip.marqueeNeeded
                && subtitleLineClip.marqueeScrollMs > 0)
            subtitleMarqueeStartTimer.restart()
    }

    onCardChanged: _requestUpdateMarquee("card")
    onHasSubtitleChanged: _requestUpdateMarquee("subtitle")
    onWidthChanged: _requestUpdateMarquee("width")
    onHeightChanged: _requestUpdateMarquee("height")

    Item {
        id: titleLineClip
        width: parent.width
        height: titleClip.hasSubtitle
                ? Math.min(parent.height,
                           Math.round(titleClip._numProp("cardTitleFontPx", 20) + 8))
                : parent.height
        y: 0
        clip: false

        Item {
            id: titleLineSource
            anchors.fill: parent
            clip: true
            visible: !titleClip.maskActive

            Text {
                id: titleTextItem
                text: titleClip.card
                      ? String(titleClip.card.effectiveTitleText || "")
                      : ""
                textFormat: Text.PlainText
                color: titleClip._boolProp("selected", false)
                       ? titleClip._valueProp("selectedTitleColor", "#ffffff")
                       : titleClip._valueProp("titleColor", "#e7eaff")
                font.pixelSize: Math.max(1,
                    Math.round(titleClip._numProp("cardTitleFontPx", 20)))
                font.bold: titleClip._boolProp("titleBoldAlways", true)
                           || titleClip._boolProp("selected", false)
                wrapMode: Text.NoWrap
                elide: titleClip._boolProp("selected", false)
                       ? Text.ElideNone : Text.ElideRight
                y: titleClip._centeredY(titleLineSource.height, height)
                x: 0

                onPaintedWidthChanged:
                    titleClip._requestUpdateMarquee("title-width")
                onTextChanged:
                    titleClip._requestUpdateMarquee("title-text")
            }
        }

        OpacityMask {
            id: titleMaskedLine
            anchors.fill: parent
            visible: titleClip.maskActive
            source: titleLineSource
            maskSource: titleFadeMask
            cached: false
        }
    }

    Item {
        id: titleFadeMask
        visible: titleClip.maskActive
        x: -10000
        y: -10000
        width: titleLineClip.width
        height: titleLineClip.height

        readonly property int leftW:
            titleClip.leftFadeActive ? titleClip.marqueeFadeW : 0
        readonly property int rightW:
            titleClip.rightFadeActive ? titleClip.marqueeFadeW : 0

        Rectangle {
            visible: titleFadeMask.leftW > 0
            x: 0
            y: 0
            width: titleFadeMask.leftW
            height: parent.height
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#00FFFFFF" }
                GradientStop { position: 1.0; color: "#FFFFFFFF" }
            }
        }

        Rectangle {
            x: titleFadeMask.leftW
            y: 0
            width: Math.max(0,
                parent.width - titleFadeMask.leftW - titleFadeMask.rightW)
            height: parent.height
            color: "#FFFFFFFF"
        }

        Rectangle {
            visible: titleFadeMask.rightW > 0
            x: parent.width - titleFadeMask.rightW
            y: 0
            width: titleFadeMask.rightW
            height: parent.height
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#FFFFFFFF" }
                GradientStop { position: 1.0; color: "#00FFFFFF" }
            }
        }
    }

    Item {
        id: subtitleLineClip
        visible: titleClip.hasSubtitle
        width: parent.width
        height: Math.min(
                    Math.max(0, titleClip.height - titleLineClip.height + 1),
                    Math.round(titleClip._numProp("cardSubtitleFontPx", 15) + 7))
        y: Math.min(titleClip.height - height,
                    titleLineClip.y + titleLineClip.height - 1)
        clip: false

        readonly property bool marqueeEnabled: titleClip._isEpisode()
        readonly property int marqueeGap: titleClip.marqueeGap
        readonly property real subtitlePaintedW: subtitleTextItem.paintedWidth
        readonly property bool marqueeNeeded:
            marqueeEnabled && subtitlePaintedW > width
        readonly property real marqueeOverflow:
            Math.max(0, subtitlePaintedW - width)
        readonly property real marqueeTravel:
            titleClip._travel(subtitlePaintedW, marqueeGap, marqueeNeeded)
        readonly property real marqueeExitX:
            marqueeTravel > 0 ? -marqueeTravel : 0
        readonly property int marqueeScrollMs:
            titleClip._scrollMs(marqueeTravel)
        readonly property int marqueeFadeW:
            titleClip._fadeWidth(width, 22, 42)
        readonly property bool marqueeArmed:
            marqueeNeeded && titleClip._marqueeFocusActive()
        property bool marqueeMoving: false
        readonly property bool maskActive:
            marqueeArmed && marqueeMoving && titleClip._marqueeFocusActive()
        readonly property bool leftFadeActive:
            maskActive && subtitleTextItem.x < -2
        readonly property bool rightFadeActive:
            maskActive && subtitleTextItem.x > -marqueeOverflow + 2

        Item {
            id: subtitleLineSource
            anchors.fill: parent
            clip: true
            visible: !subtitleLineClip.maskActive

            Text {
                id: subtitleTextItem
                text: titleClip.card
                      ? String(titleClip.card.effectiveSubtitleText || "")
                      : ""
                textFormat: Text.PlainText
                color: titleClip._boolProp("selected", false)
                       ? titleClip._valueProp("selectedSubtitleColor", "#ffffff")
                       : titleClip._valueProp("subtitleColor", "#cfd6ff")
                font.pixelSize: Math.max(1,
                    Math.round(titleClip._numProp("cardSubtitleFontPx", 15)))
                font.bold: titleClip._boolProp("subtitleBoldAlways", true)
                           || titleClip._boolProp("selected", false)
                wrapMode: Text.NoWrap
                elide: (subtitleLineClip.marqueeEnabled
                        && titleClip._boolProp("selected", false))
                       ? Text.ElideNone : Text.ElideRight
                y: titleClip._centeredY(subtitleLineSource.height, height)
                x: 0

                onPaintedWidthChanged:
                    titleClip._requestUpdateMarquee("subtitle-width")
                onTextChanged:
                    titleClip._requestUpdateMarquee("subtitle-text")
            }
        }

        OpacityMask {
            anchors.fill: parent
            visible: subtitleLineClip.maskActive
            source: subtitleLineSource
            maskSource: subtitleFadeMask
            cached: false
        }
    }

    Item {
        id: subtitleFadeMask
        visible: subtitleLineClip.maskActive
        x: -10000
        y: -10000
        width: subtitleLineClip.width
        height: subtitleLineClip.height

        readonly property int leftW:
            subtitleLineClip.leftFadeActive
            ? subtitleLineClip.marqueeFadeW : 0
        readonly property int rightW:
            subtitleLineClip.rightFadeActive
            ? subtitleLineClip.marqueeFadeW : 0

        Rectangle {
            visible: subtitleFadeMask.leftW > 0
            x: 0
            y: 0
            width: subtitleFadeMask.leftW
            height: parent.height
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#00FFFFFF" }
                GradientStop { position: 1.0; color: "#FFFFFFFF" }
            }
        }

        Rectangle {
            x: subtitleFadeMask.leftW
            y: 0
            width: Math.max(0,
                parent.width - subtitleFadeMask.leftW - subtitleFadeMask.rightW)
            height: parent.height
            color: "#FFFFFFFF"
        }

        Rectangle {
            visible: subtitleFadeMask.rightW > 0
            x: parent.width - subtitleFadeMask.rightW
            y: 0
            width: subtitleFadeMask.rightW
            height: parent.height
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#FFFFFFFF" }
                GradientStop { position: 1.0; color: "#00FFFFFF" }
            }
        }
    }

    SequentialAnimation {
        id: marquee
        running: false
        loops: Animation.Infinite

        ScriptAction {
            script: {
                titleClip.marqueeMoving = false
                titleTextItem.x = 0
                titleTextItem.opacity = 1.0
            }
        }
        PauseAnimation {
            duration: Math.max(0,
                Math.round(titleClip._numProp("marqueeStartDelayMs", 700)))
        }
        ScriptAction { script: titleClip.marqueeMoving = true }
        NumberAnimation {
            target: titleTextItem
            property: "x"
            from: 0
            to: titleClip.marqueeExitX
            duration: titleClip.marqueeScrollMs
            easing.type: Easing.Linear
        }
        ScriptAction {
            script: {
                titleTextItem.x = 0
                titleTextItem.opacity = 1.0
                titleClip.marqueeMoving = false
            }
        }
        PauseAnimation { duration: 180 }
        PauseAnimation {
            duration: Math.max(0,
                Math.round(titleClip._numProp("marqueeEndPauseMs", 260)))
        }

        onRunningChanged: {
            if (!running) {
                titleClip.marqueeMoving = false
                titleTextItem.x = 0
                titleTextItem.opacity = 1.0
            }
        }
    }

    SequentialAnimation {
        id: subtitleMarquee
        running: false
        loops: Animation.Infinite

        ScriptAction {
            script: {
                subtitleLineClip.marqueeMoving = false
                subtitleTextItem.x = 0
                subtitleTextItem.opacity = 1.0
            }
        }
        PauseAnimation {
            duration: Math.max(0,
                Math.round(titleClip._numProp("marqueeStartDelayMs", 700)))
        }
        ScriptAction { script: subtitleLineClip.marqueeMoving = true }
        NumberAnimation {
            target: subtitleTextItem
            property: "x"
            from: 0
            to: subtitleLineClip.marqueeExitX
            duration: subtitleLineClip.marqueeScrollMs
            easing.type: Easing.Linear
        }
        ScriptAction {
            script: {
                subtitleTextItem.x = 0
                subtitleTextItem.opacity = 1.0
                subtitleLineClip.marqueeMoving = false
            }
        }
        PauseAnimation { duration: 180 }
        PauseAnimation {
            duration: Math.max(0,
                Math.round(titleClip._numProp("marqueeEndPauseMs", 260)))
        }

        onRunningChanged: {
            if (!running) {
                subtitleLineClip.marqueeMoving = false
                subtitleTextItem.x = 0
                subtitleTextItem.opacity = 1.0
            }
        }
    }

    Connections {
        target: titleClip.card
        ignoreUnknownSignals: true

        function onSelectedChanged() {
            titleClip._requestUpdateMarquee("selected")
        }
        function onAllowMarqueeChanged() {
            titleClip._requestUpdateMarquee("allow-marquee")
        }
        function onAllowAnimsChanged() {
            if (!titleClip._boolProp("allowAnims", false))
                titleClip._resetMarqueeState()
            else
                titleClip._requestUpdateMarquee("allow-anims")
        }
        function onAllowLoadChanged() {
            titleClip._requestUpdateMarquee("allow-load")
        }
        function onEffectiveTitleTextChanged() {
            titleClip._requestUpdateMarquee("title")
        }
        function onEffectiveSubtitleTextChanged() {
            titleClip._requestUpdateMarquee("subtitle")
        }
    }

    Component.onCompleted: _requestUpdateMarquee("completed")
    Component.onDestruction: {
        _destroying = true
        _resetMarqueeState()
    }
}
