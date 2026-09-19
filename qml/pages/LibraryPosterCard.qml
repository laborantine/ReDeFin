// ReDeFin LibraryPosterCard : renderer léger des grandes grilles.
// IMPORTANT Freebox Révolution : ne pas fusionner les deux arbres visuels.
// Le rendu riche dans chaque delegate de bibliothèque dégrade le scroll sur CE4100/GMA500.
// QtQuick 2.15, sans QtQuick Controls.
import QtQuick 2.15

FocusScope {
    id: cardRoot

    property var controller: null
    property var modelData: null
    property int tileWidth: 260
    property int tileHeight: 160
    property int titleHeight: 46
    property bool selected: false
    property bool showProgress: false
    property string titleText: ""
    property string subtitleText: ""
    property int sidePad: 6
    property int topPad: 0
    property bool allowLoad: true
    property bool suppressFocusTransform: false

    property int cardIndex: -1
    property int gridColumns: 0
    property bool gridActiveFocus: selected
    property bool enableMouseInput: true
    property bool hoverSelectEnabled: false

    property bool useAllowAnimsOverride: false
    property bool allowAnimsOverride: false
    property bool useAllowDecosOverride: false
    property bool allowDecosOverride: false
    property real zoomScaleOverride: 0
    property string fallbackKind: ""

    property bool useImageSourceOverride: false
    property string imageSourceOverride: ""
    property string hqImageSourceOverride: ""
    // Par défaut, comportement historique des posters. Les rares fallbacks
    // horizontaux (ex. Thumb de BoxSet sans Primary) peuvent demander AspectFit.
    property int imageFillModeOverride: Image.PreserveAspectCrop
    property bool imageCache: false
    property bool smoothImages: _effectiveAllowAnims

    property string fallbackGlyph: ""
    property bool fallbackOnImageError: true
    property bool showFolderIndicator: false
    property bool showVideoIndicator: false

    property int titleTopMargin: 0
    property int titleFontPxOverride: 0
    property int subtitleFontPxOverride: 0
    property int focusLiftPxOverride: -1
    property bool titleBoldAlways: true
    property bool subtitleBoldAlways: true
    property color titleColor: "#e7eaff"
    property color selectedTitleColor: "#ffffff"
    property color subtitleColor: "#cfd6ff"
    property color selectedSubtitleColor: "#ffffff"
    property bool useAllowMarqueeOverride: false
    property bool allowMarqueeOverride: false
    property real marqueeSpeedPxPerSec: 1000.0 / 24.0
    property int marqueeStartDelayMs: 700
    property int marqueeEndPauseMs: 260
    property int marqueeGapPx: 44

    property bool showWatchedBadge: false
    property bool watched: false
    property string watchedBadgePosition: "topRight"
    property int watchedBadgeSize: 24
    property int watchedBadgeMargin: 6
    property bool suppressWatchedWhenUnplayed: true
    property bool showUnplayedBadge: false
    property int unplayedCount: 0
    property string unplayedText: unplayedCount > 99 ? "99+" : String(unplayedCount)
    property real progressRatioOverride: -1
    property int progressSideInsetOverride: -1
    property int progressBottomMarginOverride: -1
    property int progressHeightOverride: -1
    property int progressRadiusOverride: -1
    property string progressTrackColorOverride: ""
    property string progressFillColorOverride: ""
    property int progressMinWidthOverride: -1
    property real fallbackGlyphScale: 0.30

    signal activated()
    signal doubleActivated()
    signal hovered()

    function _boolProp(obj, name, fallback) {
        try {
            if (obj && obj[name] !== undefined && obj[name] !== null)
                return obj[name] === true
        } catch(e) {}
        return fallback === true
    }
    function _numProp(obj, name, fallback) {
        try {
            var v = obj ? Number(obj[name]) : NaN
            if (isFinite(v) && !isNaN(v)) return v
        } catch(e) {}
        return fallback
    }

    readonly property var _effectiveController: controller
    readonly property bool _effectiveAllowAnims: useAllowAnimsOverride
                                                 ? allowAnimsOverride
                                                 : _boolProp(_effectiveController, "allowAnims",
                                                             _boolProp(_effectiveController, "allowFocusAnims", false))
    // API visuelle historique du PosterGridCard 30/08 : le pilotage du
    // zoom bibliothèque reste au niveau racine, comme dans le composant original.
    readonly property bool allowAnims: _effectiveAllowAnims
    readonly property bool _effectiveAllowDecos: useAllowDecosOverride
                                                 ? allowDecosOverride
                                                 : _boolProp(_effectiveController, "allowDecos", _effectiveAllowAnims)
    readonly property bool _effectiveAllowMarquee: useAllowMarqueeOverride
                                                   ? allowMarqueeOverride
                                                   : _boolProp(_effectiveController, "allowMarquee", false)
    readonly property real _effectiveZoomScale: zoomScaleOverride > 0
                                                ? zoomScaleOverride
                                                : _numProp(_effectiveController, "zoomScale",
                                                           _numProp(_effectiveController, "focusScale", 1.14))
    readonly property int _effectiveFocusLiftPx: focusLiftPxOverride >= 0
                                                 ? focusLiftPxOverride
                                                 : Math.round(_numProp(_effectiveController, "focusLiftPx", 6))
    readonly property real _effectiveFrameWidth: _numProp(_effectiveController, "frameWidth", 2.0)
    readonly property int _effectiveTitleFontPx: titleFontPxOverride > 0
                                                 ? titleFontPxOverride
                                                 : Math.round(_numProp(_effectiveController, "cardTitleFontPx", 20))
    readonly property int _effectiveSubtitleFontPx: subtitleFontPxOverride > 0
                                                    ? subtitleFontPxOverride
                                                    : Math.round(_numProp(_effectiveController, "cardSubtitleFontPx", 15))

    readonly property bool allowDecos: _effectiveAllowDecos
    readonly property bool allowMarquee: _effectiveAllowMarquee
    // Une valeur transitoire <= 1 ne doit jamais inverser l'effet de focus.
    // Le renderer extrait conserve le zoom historique 1.14 -> 1.12.
    readonly property real zoomScale: {
        var z = Number(_effectiveZoomScale)
        return isFinite(z) && z > 1.0 ? z : 1.14
    }
    readonly property int focusLiftPx: _effectiveFocusLiftPx
    readonly property real frameWidth: _effectiveFrameWidth
    readonly property string imageSource: useImageSourceOverride ? imageSourceOverride : ""
    readonly property string hqImageSource: hqImageSourceOverride
    readonly property int titleFontPx: _effectiveTitleFontPx
    readonly property int subtitleFontPx: _effectiveSubtitleFontPx
            readonly property bool _focusVisualActive: gridActiveFocus && selected && !suppressFocusTransform
            readonly property string effectiveTitleText: titleText !== ""
                                                         ? titleText
                                                         : (modelData && modelData.Name ? String(modelData.Name) : "")
            readonly property string effectiveSubtitleText: subtitleText !== ""
                                                            ? subtitleText
                                                            : ""
            readonly property bool _sourcePotential: allowLoad && imageSource !== ""
            readonly property bool _imageFailed: posterImg.status === Image.Error
            readonly property bool _needFallback: !_sourcePotential || (fallbackOnImageError && _imageFailed)
            readonly property real _progressRatio: showProgress
                                                       ? Math.max(0, Math.min(1, Number(progressRatioOverride) || 0))
                                                       : 0
            readonly property bool visualReady: !allowLoad || !_sourcePotential
                                                || posterImg.status === Image.Ready
                                                || posterImg.status === Image.Error

            readonly property int cardTitleFontPx: titleFontPx
            readonly property int cardSubtitleFontPx: subtitleFontPx
            readonly property bool marqueeFocusActive: selected && allowMarquee && allowAnims && allowLoad
            property bool _alive: true
            Component.onDestruction: _alive = false

            function _typeOf(item) { return item ? String(item.Type || "").toLowerCase() : "" }
            function isEpisodeItemSafe(item) { return _typeOf(item) === "episode" }
            function fadeWidthFor(lineWidth, minW, maxW) { return Math.min(maxW, Math.max(minW, Math.round(lineWidth * 0.18))) }
            function marqueeTravelFor(paintedWidth, gap, enabled) { return enabled ? Math.max(0, paintedWidth + gap) : 0 }
            function marqueeScrollMsFor(travel) { return _marqueeScrollMs(travel) }
            function centeredTextY(lineHeight, textHeight) { return _centeredTextY(lineHeight, textHeight) }

            width: tileWidth + sidePad * 2
            height: tileHeight + titleHeight + topPad

            function _fallbackIs(name) { return String(fallbackKind || "").toLowerCase() === name }
            function _useFolderFallback() {
                var k = String(fallbackKind || "").toLowerCase()
                return k === "folder" || k === "collection" || k === "boxset"
            }
            function _useSeriesFallback() { return _fallbackIs("series") }
            function _useFilmstripFallback() { return _fallbackIs("filmstrip") }
            function _useClapperboardFallback() { return _fallbackIs("clapperboard") }
            function _useGlyphFallback() { return fallbackGlyph.length > 0 }
            function _useVideoFallback() {
                var k = String(fallbackKind || "").toLowerCase()
                return k === "video" || k === "movie" || k === "episode" || k === ""
            }
            function _centeredTextY(lineHeight, textHeight) { return Math.round((lineHeight - textHeight) / 2) }
            function _marqueeScrollMs(travel) {
                var speed = Math.max(1, Number(marqueeSpeedPxPerSec) || (1000.0 / 24.0))
                return travel > 0 ? Math.max(3200, Math.min(14000, Math.round((travel / speed) * 1000))) : 0
            }

        Component {
            id: musicNoteComp
            Item {
                anchors.fill: parent
                Rectangle { anchors.fill: parent; color: "#2e3355" }
                Text {
                    anchors.centerIn: parent
                    text: "♪"
                    color: "#cfd6ff"
                    font.pixelSize: Math.round(Math.min(parent.width, parent.height) * 0.42)
                    font.bold: true
                    opacity: 0.95
                }
            }
        }
        Component {
            id: videoLogoComp
            Item {
                anchors.fill: parent
                Rectangle { anchors.fill: parent; color: "#2e3355" }
                Rectangle {
                    width: parent.width * 0.72
                    height: parent.height * 0.56
                    radius: Math.round(Math.min(width, height) * 0.10)
                    anchors.centerIn: parent
                    color: "transparent"
                    border.color: "#cfd6ff"
                    border.width: Math.max(2, Math.round(Math.min(parent.width, parent.height) * 0.04))
                    opacity: 0.95
                }
                Text {
                    anchors.centerIn: parent
                    text: "▶"
                    color: "#cfd6ff"
                    font.pixelSize: Math.round(Math.min(parent.width, parent.height) * 0.34)
                    opacity: 0.95
                }
            }
        }

        Component {
            id: clapperboardFallbackComp
            Item {
                anchors.fill: parent
                Rectangle { anchors.fill: parent; color: "#262a39" }
                Canvas {
                    anchors.centerIn: parent
                    width: 74
                    height: 62
                    antialiasing: false
                    onPaint: {
                        var c = getContext("2d")
                        c.reset()
                        c.clearRect(0, 0, width, height)
                        c.fillStyle = "#77819d"
                        c.fillRect(8, 20, 58, 35)
                        c.fillStyle = "#9aa3bd"
                        c.beginPath()
                        c.moveTo(8, 20)
                        c.lineTo(18, 7)
                        c.lineTo(68, 7)
                        c.lineTo(58, 20)
                        c.closePath()
                        c.fill()
                        c.strokeStyle = "#2a2f4f"
                        c.lineWidth = 3
                        for (var x = 19; x < 60; x += 14) {
                            c.beginPath()
                            c.moveTo(x, 8)
                            c.lineTo(x - 8, 19)
                            c.stroke()
                        }
                    }
                }
            }
        }

        Component {
            id: filmstripFallbackComp
            Item {
                anchors.fill: parent
                Rectangle { anchors.fill: parent; color: "#2a2f4f" }
                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: Math.max(10, Math.round(parent.width * 0.12))
                    color: "#202444"
                }
                Repeater {
                    model: 7
                    delegate: Rectangle {
                        width: Math.max(4, Math.round(parent.width * 0.05))
                        height: Math.max(6, Math.round(parent.height * 0.06))
                        radius: 2
                        color: "#39405f"
                        x: Math.round(parent.width * 0.035)
                        y: Math.round((index + 1) * (parent.height / 8) - height / 2)
                    }
                }
                Text {
                    anchors.centerIn: parent
                    text: "\u25B6"
                    textFormat: Text.PlainText
                    color: "#E7ECFF"
                    font.pixelSize: Math.round(parent.height * 0.34)
                    opacity: 0.95
                }
                Text {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.rightMargin: 10
                    anchors.bottomMargin: 8
                    text: (cardRoot.modelData && cardRoot.modelData.ProductionYear)
                          ? String(cardRoot.modelData.ProductionYear) : ""
                    textFormat: Text.PlainText
                    color: "#b9c0ff"
                    font.pixelSize: 14
                    visible: text.length > 0
                }
            }
        }

        Component {
            id: seriesFallbackComp
            Item {
                anchors.fill: parent
                Rectangle { anchors.fill: parent; color: "#2a2f4f" }
                Item {
                    anchors.centerIn: parent
                    width: parent.width * 0.72
                    height: parent.height * 0.62
                    Rectangle {
                        width: parent.width * 0.44
                        height: width
                        radius: width / 2
                        color: "#9aa3bd"
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 0
                    }
                    Rectangle {
                        width: parent.width * 0.78
                        height: parent.height * 0.58
                        radius: Math.min(width, height) * 0.22
                        color: "#7d86a4"
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: parent.height * 0.38
                    }
                }
            }
        }
        Component {
            id: folderFallbackComp
            Item {
                anchors.fill: parent
                Rectangle { anchors.fill: parent; color: "#2e3355" }
                Rectangle {
                    width: parent.width * 0.55
                    height: parent.height * 0.18
                    anchors.left: parent.left
                    anchors.leftMargin: parent.width * 0.10
                    anchors.top: parent.top
                    anchors.topMargin: parent.height * 0.18
                    radius: 4
                    color: "#cfd6ff"
                    opacity: 0.18
                }
                Rectangle {
                    width: parent.width * 0.78
                    height: parent.height * 0.52
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: parent.height * 0.32
                    radius: 10
                    color: "transparent"
                    border.color: "#cfd6ff"
                    border.width: Math.max(2, Math.round(Math.min(parent.width, parent.height) * 0.04))
                    opacity: 0.75
                }
            }
        }


        Component {
            id: glyphFallbackComp
            Item {
                anchors.fill: parent
                Rectangle { anchors.fill: parent; color: "#2a2f4f" }
                Text {
                    anchors.centerIn: parent
                    text: cardRoot.fallbackGlyph
                    textFormat: Text.PlainText
                    color: "#E7ECFF"
                    font.pixelSize: Math.round(parent.height * cardRoot.fallbackGlyphScale)
                    opacity: 0.95
                }
            }
        }

        Component {
            id: folderIndicatorComp
            Item {
                anchors.fill: parent
                Item {
                    z: 18
                    anchors.centerIn: parent
                    width: Math.round(parent.width * 0.58)
                    height: Math.round(parent.height * 0.28)
                    Rectangle {
                        width: Math.round(parent.width * 0.44)
                        height: Math.round(parent.height * 0.24)
                        radius: 4
                        color: "#B7C2EA"
                    }
                    Rectangle {
                        y: Math.round(parent.height * 0.15)
                        width: parent.width
                        height: Math.round(parent.height * 0.78)
                        radius: 7
                        color: "#7D8EC8"
                        border.width: 1
                        border.color: "#D6DDF7"
                    }
                }
            }
        }

        Component {
            id: videoIndicatorComp
            Item {
                anchors.fill: parent
                Rectangle {
                    z: 18
                    width: 42
                    height: 42
                    radius: 21
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: 8
                    anchors.bottomMargin: 8
                    color: Qt.rgba(0.02, 0.025, 0.04, 0.82)
                    border.width: 1
                    border.color: "#CCFFFFFF"
                    Canvas {
                        anchors.centerIn: parent
                        width: 15
                        height: 18
                        onPaint: {
                            var c = getContext("2d")
                            c.clearRect(0, 0, width, height)
                            c.fillStyle = "#FFFFFF"
                            c.beginPath()
                            c.moveTo(2, 1)
                            c.lineTo(14, 9)
                            c.lineTo(2, 17)
                            c.closePath()
                            c.fill()
                        }
                    }
                }
            }
        }
            Item {
                id: visual
                width: cardRoot.tileWidth
                height: cardRoot.tileHeight
                anchors.top: parent.top
                anchors.topMargin: cardRoot.topPad
                anchors.horizontalCenter: parent.horizontalCenter
                transformOrigin: Item.Bottom
                scale: 1.0
                readonly property real focusPeakScale: cardRoot.zoomScale
                readonly property real focusSettledScale: Math.max(1.01, focusPeakScale - 0.02)

                states: [
                    State {
                        name: "focused"
                        when: cardRoot._focusVisualActive
                        PropertyChanges { target: visual; scale: visual.focusSettledScale }
                    }
                ]

                transitions: [
                    Transition {
                        from: ""
                        to: "focused"
                        SequentialAnimation {
                            NumberAnimation {
                                target: visual
                                property: "scale"
                                to: visual.focusPeakScale
                                duration: cardRoot.allowAnims ? 120 : 0
                                easing.type: Easing.OutCubic
                            }
                            NumberAnimation {
                                target: visual
                                property: "scale"
                                to: visual.focusSettledScale
                                duration: cardRoot.allowAnims ? 90 : 0
                                easing.type: Easing.OutCubic
                            }
                        }
                    },
                    Transition {
                        from: "focused"
                        to: ""
                        NumberAnimation {
                            target: visual
                            property: "scale"
                            to: 1.0
                            duration: cardRoot.allowAnims ? 130 : 0
                            easing.type: Easing.OutCubic
                        }
                    }
                ]

                readonly property int col: (cardRoot.gridColumns > 0 && cardRoot.cardIndex >= 0)
                                           ? (cardRoot.cardIndex % cardRoot.gridColumns) : -1
                readonly property bool firstCol: col === 0
                readonly property bool lastCol: cardRoot.gridColumns > 0 && col === cardRoot.gridColumns - 1
                readonly property real edgeNudge: Math.max(0, Math.ceil(cardRoot.tileWidth * (cardRoot.zoomScale - 1.0) * 0.55))

                transform: Translate {
                    x: cardRoot._focusVisualActive
                       ? (visual.firstCol ? visual.edgeNudge : (visual.lastCol ? -visual.edgeNudge : 0)) : 0
                    y: cardRoot._focusVisualActive ? -cardRoot.focusLiftPx : 0
                    Behavior on x {
                        enabled: cardRoot.allowAnims
                        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                    }
                    Behavior on y {
                        enabled: cardRoot.allowAnims
                        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -3
                    color: "#ffffff"
                    opacity: (cardRoot._focusVisualActive && cardRoot.allowDecos) ? 0.05 : 0.0
                    visible: opacity > 0.0
                    Behavior on opacity {
                        enabled: cardRoot.allowAnims
                        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                    }
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: Math.round(parent.height * 0.22)
                    opacity: (cardRoot._focusVisualActive && cardRoot.allowDecos) ? 1.0 : 0.0
                    visible: opacity > 0.0
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "#00000000" }
                        GradientStop { position: 1.0; color: "#22000000" }
                    }
                    Behavior on opacity {
                        enabled: cardRoot.allowAnims
                        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    color: "#1f233a"
                    visible: cardRoot._sourcePotential && posterImg.status !== Image.Ready
                }

                Image {
                    id: posterImg
                    anchors.fill: parent
                    fillMode: cardRoot.imageFillModeOverride
                    asynchronous: true
                    cache: cardRoot.imageCache
                    mipmap: false
                    smooth: cardRoot.smoothImages
                    source: cardRoot.allowLoad ? cardRoot.imageSource : ""
                    visible: source !== "" && !cardRoot._needFallback
                    opacity: status === Image.Ready ? 1.0 : 0.0
                    Behavior on opacity {
                        enabled: cardRoot.allowAnims
                        NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
                    }
                }

                Loader {
                    id: posterHqLoader
                    anchors.fill: parent
                    z: 0
                    readonly property string requestedSource: posterImg.status === Image.Ready
                                                              ? String(cardRoot.hqImageSource || "") : ""
                    active: requestedSource !== ""
                    visible: active && !cardRoot._needFallback
                    sourceComponent: Component {
                        Image {
                            anchors.fill: parent
                            fillMode: cardRoot.imageFillModeOverride
                            asynchronous: true
                            cache: false
                            mipmap: false
                            smooth: cardRoot.smoothImages
                            source: posterHqLoader.requestedSource
                            visible: status === Image.Ready
                            opacity: status === Image.Ready ? 1.0 : 0.0
                            Behavior on opacity {
                                enabled: cardRoot.allowAnims
                                NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
                            }
                        }
                    }
                }

                Loader {
                    id: fallbackLoader
                    anchors.fill: parent
                    active: cardRoot._needFallback
                    visible: active
                    sourceComponent: cardRoot._useFolderFallback() ? folderFallbackComp
                                     : (cardRoot._useSeriesFallback() ? seriesFallbackComp
                                     : (cardRoot._useClapperboardFallback() ? clapperboardFallbackComp
                                     : (cardRoot._useFilmstripFallback() ? filmstripFallbackComp
                                     : (cardRoot._useGlyphFallback() ? glyphFallbackComp : videoLogoComp))))
                }

                Loader {
                    anchors.fill: parent
                    active: cardRoot.showFolderIndicator && cardRoot._needFallback
                    visible: active
                    sourceComponent: folderIndicatorComp
                }

                Loader {
                    anchors.fill: parent
                    active: cardRoot.showVideoIndicator
                    visible: active
                    sourceComponent: videoIndicatorComp
                }

                Rectangle {
                    z: 10
                    anchors.fill: parent
                    color: "transparent"
                    border.color: "#FFFFFF"
                    border.width: cardRoot.frameWidth
                    radius: 0
                    antialiasing: false
                    opacity: cardRoot._focusVisualActive ? 1.0 : 0.0
                    Behavior on opacity {
                        enabled: cardRoot.allowAnims
                        NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
                    }
                }

                Rectangle {
                    z: 20
                    height: 24
                    radius: 12
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.topMargin: 6
                    anchors.rightMargin: 6
                    color: "#3B82F6"
                    border.color: "#1E3A8A"
                    border.width: 1
                    visible: cardRoot.showUnplayedBadge && cardRoot.unplayedCount > 0
                    width: Math.max(height, unplayedBadgeText.paintedWidth + 12)
                    Text {
                        id: unplayedBadgeText
                        anchors.centerIn: parent
                        text: cardRoot.unplayedText
                        color: "white"
                        font.pixelSize: 13
                        font.bold: true
                    }
                }

                Rectangle {
                    z: 20
                    width: cardRoot.watchedBadgeSize
                    height: cardRoot.watchedBadgeSize
                    radius: width / 2
                    x: cardRoot.watchedBadgePosition === "topLeft"
                       ? cardRoot.watchedBadgeMargin
                       : parent.width - width - cardRoot.watchedBadgeMargin
                    y: cardRoot.watchedBadgeMargin
                    color: "#3B82F6"
                    border.color: "#1E3A8A"
                    border.width: 1
                    visible: cardRoot.showWatchedBadge && cardRoot.watched
                             && (!cardRoot.suppressWatchedWhenUnplayed
                                 || !(cardRoot.showUnplayedBadge && cardRoot.unplayedCount > 0))
                    Item {
                        anchors.centerIn: parent
                        width: 15
                        height: 12
                        Rectangle { x: 2.1; y: 6.6; width: 5.4; height: 2.1; radius: 1.05; color: "#FFFFFF"; rotation: 42; transformOrigin: Item.Left; antialiasing: true }
                        Rectangle { x: 5.8; y: 9.1; width: 8.6; height: 2.1; radius: 1.05; color: "#FFFFFF"; rotation: -42; transformOrigin: Item.Left; antialiasing: true }
                        Rectangle { x: 5.1; y: 8.1; width: 2.0; height: 2.0; radius: 1.0; color: "#FFFFFF"; antialiasing: true }
                    }
                }

                Rectangle {
                    z: 19
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: cardRoot.progressSideInsetOverride >= 0 ? cardRoot.progressSideInsetOverride : 5
                    anchors.rightMargin: anchors.leftMargin
                    anchors.bottomMargin: cardRoot.progressBottomMarginOverride >= 0 ? cardRoot.progressBottomMarginOverride : 5
                    height: cardRoot.progressHeightOverride > 0 ? cardRoot.progressHeightOverride : 4
                    radius: cardRoot.progressRadiusOverride >= 0 ? cardRoot.progressRadiusOverride : Math.max(0, Math.round(height / 2))
                    color: cardRoot.progressTrackColorOverride.length > 0 ? cardRoot.progressTrackColorOverride : "#66000000"
                    visible: cardRoot._progressRatio > 0
                    Rectangle {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        height: parent.height
                        width: Math.max(cardRoot.progressMinWidthOverride >= 0 ? cardRoot.progressMinWidthOverride : parent.height,
                                        parent.width * cardRoot._progressRatio)
                        radius: parent.radius
                        color: cardRoot.progressFillColorOverride.length > 0 ? cardRoot.progressFillColorOverride : "#3B82F6"
                    }
                }
            }

            // Chargement explicite : qml/pages est servi en HTTP sur Freebox et
            // son qmldir n'est pas garanti. Ne pas dépendre de la résolution
            // implicite du type PosterCardTitleLayer.
            Loader {
                id: titleLayerLoader
                active: cardRoot.titleHeight > 0
                asynchronous: false
                source: active ? Qt.resolvedUrl("PosterCardTitleLayer.qml") : ""
                width: cardRoot.tileWidth
                height: cardRoot.titleHeight
                anchors.top: visual.bottom
                anchors.topMargin: cardRoot.titleTopMargin
                anchors.horizontalCenter: visual.horizontalCenter

                onLoaded: {
                    if (item)
                        item.card = cardRoot
                }
            }

            MouseArea {
                anchors.fill: parent
                enabled: cardRoot.enableMouseInput
                hoverEnabled: cardRoot.hoverSelectEnabled
                onEntered: cardRoot.hovered()
                onClicked: cardRoot.activated()
                onDoubleClicked: cardRoot.doubleActivated()
            }

    // Le focus est declaratif : une reevaluation de selected/gridActiveFocus
    // ne peut plus interrompre ou inverser l'animation en cours.
    readonly property bool homeVisualReady: visualReady
}
