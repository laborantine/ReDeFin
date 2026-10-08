// qml/components/SettingsSidePanel.qml
// Panneau latéral (droite -> gauche) avec toggle "Afficher l’horloge"
// API: open(), close(); signals: requestClose(), closed()
// Props externes utiles: versionText, panelWidthRatio, showClock (bool)

import QtQuick 2.15
import QtGraphicalEffects 1.15
import "." as Components
import "../js/clientId.js" as ClientId

FocusScope {
    id: panel
    anchors.fill: parent
    z: 5000
    focus: visible
    visible: _open
    enabled: visible

    /* === API / état === */
    signal requestClose()
    signal closed()
    property bool _open: false
    property bool _playbackInfoOpen: false
    // Une même touche INFO génère généralement un pressed puis un released.
    // Ce verrou garantit qu'un cycle physique ne déclenche qu'un seul toggle.
    property bool _playbackInfoKeyHeld: false

    /* === Personnalisation === */
    property real  panelWidthRatio: 0.18
    property string versionText: "ReDeFin " + ClientId.applicationVersion()
    readonly property int panelWidth: Math.max(360, Math.round(width * panelWidthRatio))

    /* === Option: Afficher l’horloge === */
    // ⚠️ La PERSISTENCE est gérée par HomePage + Components.AppSettings.
    // Ici, on se contente d'exposer une prop bindable.
    property bool showClock: true

    /* === Option: Mode de lecture (Original / Intelligent) === */
    property string playbackMode: "smart"
    /* === Option: pilotage depuis les autres clients Jellyfin === */
    property bool remoteControlEnabled: true

    // Télécommande Freebox : la touche « i / Infos » du Player est remontée
    // par le runtime Freebox comme Qt.Key_Help (0x01000058 / 16777304).
    // Les autres variantes restent acceptées pour les autres Players et claviers.
    function _isPlaybackInfoKey(event) {
        if (!event) return false;
        return event.key === Qt.Key_Help
            || event.key === 16777304
            || event.key === Qt.Key_Info
            || event.key === Qt.Key_Yellow
            || event.key === Qt.Key_F4
            || event.key === Qt.Key_I;
    }

    function _syncPlaybackModeFromSettings() {
        var mode = "smart";
        try {
            if (Components.AppSettings && Components.AppSettings.playbackMode !== undefined)
                mode = Components.AppSettings.normalizePlaybackMode(Components.AppSettings.playbackMode);
        } catch (e) {}
        if (panel.playbackMode !== mode)
            panel.playbackMode = mode;
    }

    function _setPlaybackMode(value) {
        var mode = Components.AppSettings.normalizePlaybackMode(value);
        if (panel.playbackMode !== mode)
            panel.playbackMode = mode;
        try {
            if (Components.AppSettings) {
                // Persistance explicite : ne pas dépendre uniquement du handler
                // onPlaybackModeChanged du Singleton, qui peut être concurrencé
                // par une resynchronisation UserStore lors de l'ouverture/fermeture.
                if (typeof Components.AppSettings.set === "function")
                    Components.AppSettings.set("playbackMode", mode);
                if (Components.AppSettings.playbackMode !== mode)
                    Components.AppSettings.playbackMode = mode;
            }
        } catch (e) {}
    }

    function _togglePlaybackMode() {
        _setPlaybackMode(panel.playbackMode === "directplay" ? "smart" : "directplay");
    }

    function _syncRemoteControlFromSettings() {
        var on = true;
        try {
            if (Components.AppSettings
                    && Components.AppSettings.remoteControlEnabled !== undefined)
                on = Components.AppSettings.remoteControlEnabled !== false;
        } catch (e) {}
        if (panel.remoteControlEnabled !== on)
            panel.remoteControlEnabled = on;
    }

    function _setRemoteControl(value) {
        var on = !!value;
        if (panel.remoteControlEnabled !== on)
            panel.remoteControlEnabled = on;
        try {
            if (Components.AppSettings) {
                if (typeof Components.AppSettings.set === "function")
                    Components.AppSettings.set("remoteControlEnabled", on);
                if (Components.AppSettings.remoteControlEnabled !== on)
                    Components.AppSettings.remoteControlEnabled = on;
            }
        } catch (e) {}
    }

    function _openPlaybackInfo() {
        _playbackInfoOpen = true;
        Qt.callLater(function() {
            playbackInfoDialog.forceActiveFocus();
        });
    }

    function _closePlaybackInfo() {
        if (!_playbackInfoOpen) return;
        _playbackInfoOpen = false;
        Qt.callLater(function() {
            if (panel._open) playbackModeRow.forceActiveFocus();
        });
    }

    function _togglePlaybackInfo() {
        if (_playbackInfoOpen)
            _closePlaybackInfo();
        else
            _openPlaybackInfo();
    }

    // Retourne true si l'événement est une touche INFO prise en charge.
    // Le released correspondant est consommé sans retoggler, sinon la boîte
    // se refermerait sur pressed puis se rouvrirait aussitôt sur released.
    function _handlePlaybackInfoPressed(event) {
        if (!_isPlaybackInfoKey(event)) return false;
        if (!_playbackInfoKeyHeld) {
            _playbackInfoKeyHeld = true;
            _togglePlaybackInfo();
        }
        event.accepted = true;
        return true;
    }

    function _handlePlaybackInfoReleased(event) {
        if (!_isPlaybackInfoKey(event)) return false;
        if (_playbackInfoKeyHeld)
            _playbackInfoKeyHeld = false;
        else
            // Compatibilité avec un runtime qui ne remonterait que le released.
            _togglePlaybackInfo();
        event.accepted = true;
        return true;
    }

    /* === Ouverture / fermeture === */
    function open() {
        _syncPlaybackModeFromSettings();
        _syncRemoteControlFromSettings();
        _playbackInfoOpen = false;
        _playbackInfoKeyHeld = false;
        _open = true;
        sheet.x = parent.width;
        overlay.opacity = 0;

        Qt.callLater(function() {
            animIn.start();
            clockRow.forceActiveFocus();
        });
    }

    function close() {
        if (!_open) return;
        animOut.start();
    }

    /* === Raccourcis globaux === */
    Keys.onPressed: {
        if (panel._playbackInfoOpen) {
            if (panel._handlePlaybackInfoPressed(event))
                return;
            if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape ||
                event.key === Qt.Key_Menu || event.key === Qt.Key_Return ||
                event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                panel._closePlaybackInfo();
                event.accepted = true;
            }
            return;
        }

        if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape || event.key === Qt.Key_Menu) {
            panel.requestClose();
            panel.close();
            event.accepted = true;
        }
    }

    Keys.onReleased: {
        if ((panel._playbackInfoOpen || playbackModeRow.activeFocus) && panel._isPlaybackInfoKey(event))
            panel._handlePlaybackInfoReleased(event);
    }

    /* === Voile modal === */
    Rectangle {
        id: overlay
        anchors.fill: parent
        color: "#000"
        opacity: 0.0
        visible: panel.visible
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        MouseArea { anchors.fill: parent; onClicked: { panel.requestClose(); panel.close() } }
    }

    /* === Feuille latérale (droite) === */
    Rectangle {
        id: sheet
        width: panel.panelWidth
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        x: panel.width
        color: "#0F1326"
        border.color: "#FFFFFF"
        border.width: 2

        // Liseré intérieur gauche
        Rectangle {
            anchors { top: parent.top; bottom: parent.bottom; left: parent.left }
            width: 10
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#6e7bf4" }
                GradientStop { position: 1.0; color: "#6e7bf400" }
            }
            opacity: 0.55
        }

        /* === Contenu === */
        Column {
            id: content
            anchors.fill: parent
            // Conserver le pilotage distant accessible aussi en sortie video basse.
            // Pas de Flickable ni de rendu supplementaire sur Freebox Revolution.
            anchors.margins: sheet.height < 620 ? 12 : 22
            spacing: sheet.height < 620 ? 9 : 18

            /* Titre */
            FocusScope {
                id: titleFocus
                width: parent.width
                height: 36
                Keys.onPressed: {
                    if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape || event.key === Qt.Key_Menu) {
                        panel.requestClose();
                        panel.close();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down) {
                        clockRow.forceActiveFocus();
                        event.accepted = true;
                    }
                }
                Row {
                    anchors.fill: parent
                    spacing: 10
                    Text { text: "\u2699"; color: "#ffffff"; font.pixelSize: 22; y: 2 }
                    Text { text: "Paramètres"; color: "#ffffff"; font.pixelSize: 22; font.bold: true }
                }
            }

            Rectangle { width: parent.width; height: 2; color: "#e0d200" }

            /* ===== Section: Affichage ===== */
            Text { text: "Affichage"; color: "#cfd6ff"; font.pixelSize: 16; font.bold: true }

            /* Rangée: "Afficher l’horloge" — surbrillance légère */
            FocusScope {
                id: clockRow
                width: parent.width
                height: 52

                // Surbrillance douce légère
                Rectangle {
                    id: hi
                    anchors.fill: parent
                    anchors.margins: 6
                    radius: 12
                    color: clockRow.activeFocus ? "#1b2142" : "transparent"
                    opacity: clockRow.activeFocus ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                }
                // Contenu (label gauche / toggle droite)
                Item {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14

                    Text {
                        text: "Afficher l’horloge"
                        color: clockRow.activeFocus ? "#FFFFFF" : "#cfd6ff"
                        font.pixelSize: 16
                        verticalAlignment: Text.AlignVCenter
                        anchors.left: parent.left
                        anchors.right: toggleWrap.left
                        anchors.rightMargin: 12
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        elide: Text.ElideRight
                    }

                    Item {
                        id: toggleWrap
                        width: 68
                        height: 30
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter

                        // Rail
                        Rectangle {
                            id: track
                            anchors.fill: parent
                            radius: height / 2
                            border.width: 1
                            border.color: panel.showClock ? "#E6EEFF" : "#4B5685"
                            gradient: Gradient {
                                GradientStop {
                                    position: 0.0
                                    color: panel.showClock ? "#2F7CFF" : "#2A3152"
                                }
                                GradientStop {
                                    position: 1.0
                                    color: panel.showClock ? "#7EC4FF" : "#1C2342"
                                }
                            }
                            Behavior on border.color { ColorAnimation { duration: 140 } }
                        }

                        // Bouton
                        Rectangle {
                            width: 24; height: 24
                            radius: height / 2
                            anchors.verticalCenter: parent.verticalCenter
                            x: panel.showClock ? (toggleWrap.width - width - 3) : 3
                            color: panel.showClock ? "#FFFFFF" : "#D4D9F1"
                            border.color: panel.showClock ? "#FFFFFF" : "#C7CCE6"
                            border.width: 1
                            Behavior on x           { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                            Behavior on color       { ColorAnimation { duration: 140 } }
                            Behavior on border.color{ ColorAnimation { duration: 140 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: clockRow.forceActiveFocus()
                            onClicked: {
                                panel.showClock = !panel.showClock;
                                mouse.accepted = true;
                            }
                        }
                    }
                }

                // Clavier + clic rangée
                Keys.onPressed: {
                    if (event.key === Qt.Key_Left || event.key === Qt.Key_Right ||
                        event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                        panel.showClock = !panel.showClock;
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up) {
                        titleFocus.forceActiveFocus();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down) {
                        playbackModeRow.forceActiveFocus();
                        event.accepted = true;
                    }
                }
                MouseArea { anchors.fill: parent; onClicked: panel.showClock = !panel.showClock }
            }


            Rectangle { width: parent.width; height: 2; color: "#e0d200" }

            /* ===== Section: Lecture ===== */
            Row {
                width: parent.width
                height: 24
                spacing: 7

                Text {
                    text: "Lecture"
                    color: "#cfd6ff"
                    font.pixelSize: 16
                    font.bold: true
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                }

                Rectangle {
                    width: 18
                    height: 18
                    y: Math.round((parent.height - height) / 2)
                    radius: 9
                    color: "transparent"
                    border.width: 1
                    border.color: "#8EB9FF"

                    Text {
                        anchors.centerIn: parent
                        text: "i"
                        color: "#8EB9FF"
                        font.pixelSize: 12
                        font.bold: true
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: panel._openPlaybackInfo()
                    }
                }
            }

            FocusScope {
                id: playbackModeRow
                width: parent.width
                height: 58

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 6
                    radius: 12
                    color: playbackModeRow.activeFocus ? "#1b2142" : "transparent"
                    opacity: playbackModeRow.activeFocus ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                }

                Row {
                    anchors.centerIn: parent
                    height: parent.height
                    spacing: 9

                    Text {
                        text: "Original"
                        color: panel.playbackMode === "directplay" ? "#FFFFFF" : "#8EB9FF"
                        font.pixelSize: 12
                        font.bold: panel.playbackMode === "directplay"
                        verticalAlignment: Text.AlignVCenter
                        horizontalAlignment: Text.AlignRight
                        width: 72
                        height: parent.height
                    }

                    Item {
                        id: playbackModeSelector
                        width: 68
                        height: 30
                        y: Math.round((parent.height - height) / 2)

                        Rectangle {
                            anchors.fill: parent
                            radius: height / 2
                            border.width: 1
                            border.color: "#E6EEFF"
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: "#2F7CFF" }
                                GradientStop { position: 1.0; color: "#7EC4FF" }
                            }
                        }

                        Rectangle {
                            width: 24
                            height: 24
                            radius: height / 2
                            anchors.verticalCenter: parent.verticalCenter
                            x: panel.playbackMode === "smart"
                               ? (playbackModeSelector.width - width - 3) : 3
                            color: "#FFFFFF"
                            border.color: "#FFFFFF"
                            border.width: 1
                            Behavior on x {
                                NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                            }
                        }
                    }

                    Text {
                        text: "Intelligent"
                        color: panel.playbackMode === "smart" ? "#FFFFFF" : "#8EB9FF"
                        font.pixelSize: 12
                        font.bold: panel.playbackMode === "smart"
                        verticalAlignment: Text.AlignVCenter
                        horizontalAlignment: Text.AlignLeft
                        width: 108
                        height: parent.height
                        elide: Text.ElideRight
                    }
                }

                Keys.onPressed: {
                    if (event.key === Qt.Key_Left) {
                        panel._setPlaybackMode("directplay");
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Right) {
                        panel._setPlaybackMode("smart");
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                        panel._togglePlaybackMode();
                        event.accepted = true;
                    } else if (panel._isPlaybackInfoKey(event)) {
                        panel._handlePlaybackInfoPressed(event);
                    } else if (event.key === Qt.Key_Up) {
                        clockRow.forceActiveFocus();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down) {
                        remoteControlRow.forceActiveFocus();
                        event.accepted = true;
                    }
                }

                Keys.onReleased: {
                    if (panel._isPlaybackInfoKey(event))
                        panel._handlePlaybackInfoReleased(event);
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: playbackModeRow.forceActiveFocus()
                    onClicked: {
                        panel._setPlaybackMode(mouse.x < width / 2 ? "directplay" : "smart");
                        mouse.accepted = true;
                    }
                }
            }

            Rectangle { width: parent.width; height: 2; color: "#e0d200" }

            /* ===== Section: Pilotage distant Jellyfin ===== */
            Text {
                text: "Pilotage distant Jellyfin"
                color: "#cfd6ff"
                font.pixelSize: 16
                font.bold: true
            }

            FocusScope {
                id: remoteControlRow
                width: parent.width
                height: 52

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 6
                    radius: 12
                    color: remoteControlRow.activeFocus ? "#1b2142" : "transparent"
                    opacity: remoteControlRow.activeFocus ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                }

                Item {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14

                    Item {
                        id: remoteLabelBox
                        anchors.left: parent.left
                        anchors.right: remoteToggleWrap.left
                        anchors.rightMargin: 12
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        clip: false

                        readonly property bool allowMarquee:
                            remoteControlRow.activeFocus
                            && panel.visible
                            && visible
                        readonly property bool marqueeNeeded:
                            remoteLabelText.paintedWidth > width + 1
                        readonly property real marqueeOverflow:
                            Math.max(0, remoteLabelText.paintedWidth - width)
                        readonly property int marqueeGap: 44
                        readonly property real marqueeTravel:
                            marqueeNeeded
                            ? Math.max(0, remoteLabelText.paintedWidth + marqueeGap)
                            : 0
                        readonly property real marqueeExitX:
                            marqueeTravel > 0 ? -marqueeTravel : 0
                        readonly property int marqueeScrollMs:
                            marqueeTravel > 0
                            ? Math.max(3200, Math.min(
                                  14000,
                                  Math.round((marqueeTravel / 56.0) * 1000)))
                            : 0
                        readonly property int marqueeFadeW:
                            Math.min(42, Math.max(22, Math.round(width * 0.12)))

                        property bool marqueeMoving: false

                        readonly property bool maskActive:
                            marqueeNeeded
                            && allowMarquee
                            && marqueeMoving
                            && width > 0
                            && height > 0
                        readonly property bool leftFadeActive:
                            maskActive && remoteLabelText.x < -2
                        readonly property bool rightFadeActive:
                            maskActive
                            && remoteLabelText.x > -marqueeOverflow + 2

                        onAllowMarqueeChanged: updateMarquee()
                        onWidthChanged: updateMarquee()
                        onVisibleChanged: updateMarquee()
                        onMarqueeNeededChanged: updateMarquee()

                        Connections {
                            target: remoteControlRow
                            function onActiveFocusChanged() {
                                remoteLabelBox.updateMarquee()
                            }
                        }

                        Item {
                            id: remoteLabelSource
                            anchors.fill: parent
                            clip: true
                            visible: !remoteLabelBox.maskActive

                            Text {
                                id: remoteLabelText
                                x: 0
                                y: Math.round((parent.height - height) / 2)
                                text: "Piloter depuis l’appli Jellyfin"
                                color: remoteControlRow.activeFocus
                                       ? "#FFFFFF" : "#cfd6ff"
                                font.pixelSize: 16
                                wrapMode: Text.NoWrap
                                textFormat: Text.PlainText
                                elide: remoteLabelBox.allowMarquee
                                       ? Text.ElideNone : Text.ElideRight
                                onTextChanged: remoteLabelBox.updateMarquee()
                                onPaintedWidthChanged:
                                    remoteLabelBox.updateMarquee()
                            }
                        }

                        OpacityMask {
                            anchors.fill: parent
                            visible: remoteLabelBox.maskActive
                            enabled: remoteLabelBox.maskActive
                            source: remoteLabelSource
                            maskSource: remoteLabelFadeMask
                            cached: false
                        }

                        Item {
                            id: remoteLabelFadeMask
                            visible: remoteLabelBox.maskActive
                            x: -10000
                            y: -10000
                            width: remoteLabelBox.width
                            height: remoteLabelBox.height

                            readonly property int leftW:
                                remoteLabelBox.leftFadeActive
                                ? remoteLabelBox.marqueeFadeW : 0
                            readonly property int rightW:
                                remoteLabelBox.rightFadeActive
                                ? remoteLabelBox.marqueeFadeW : 0

                            Rectangle {
                                visible: remoteLabelFadeMask.leftW > 0
                                x: 0
                                y: 0
                                width: remoteLabelFadeMask.leftW
                                height: parent.height
                                gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop {
                                        position: 0.0
                                        color: "#00FFFFFF"
                                    }
                                    GradientStop {
                                        position: 1.0
                                        color: "#FFFFFFFF"
                                    }
                                }
                            }

                            Rectangle {
                                x: remoteLabelFadeMask.leftW
                                y: 0
                                width: Math.max(
                                    0,
                                    parent.width
                                    - remoteLabelFadeMask.leftW
                                    - remoteLabelFadeMask.rightW)
                                height: parent.height
                                color: "#FFFFFFFF"
                            }

                            Rectangle {
                                visible: remoteLabelFadeMask.rightW > 0
                                x: parent.width - remoteLabelFadeMask.rightW
                                y: 0
                                width: remoteLabelFadeMask.rightW
                                height: parent.height
                                gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop {
                                        position: 0.0
                                        color: "#FFFFFFFF"
                                    }
                                    GradientStop {
                                        position: 1.0
                                        color: "#00FFFFFF"
                                    }
                                }
                            }
                        }

                        SequentialAnimation {
                            id: remoteLabelMarquee
                            running: false
                            loops: Animation.Infinite

                            ScriptAction {
                                script: {
                                    remoteLabelBox.marqueeMoving = false
                                    remoteLabelText.x = 0
                                    remoteLabelText.opacity = 1.0
                                }
                            }
                            PauseAnimation { duration: 700 }
                            ScriptAction {
                                script: remoteLabelBox.marqueeMoving = true
                            }
                            NumberAnimation {
                                target: remoteLabelText
                                property: "x"
                                from: 0
                                to: remoteLabelBox.marqueeExitX
                                duration: remoteLabelBox.marqueeScrollMs
                                easing.type: Easing.Linear
                            }
                            ScriptAction {
                                script: remoteLabelBox.marqueeMoving = false
                            }
                            PauseAnimation { duration: 180 }
                            ScriptAction {
                                script: {
                                    remoteLabelText.x = 0
                                    remoteLabelText.opacity = 1.0
                                    remoteLabelBox.marqueeMoving = false
                                }
                            }
                            PauseAnimation { duration: 260 }

                            onRunningChanged: {
                                if (!running) {
                                    remoteLabelBox.marqueeMoving = false
                                    remoteLabelText.x = 0
                                    remoteLabelText.opacity = 1.0
                                }
                            }
                        }

                        function updateMarquee() {
                            remoteLabelMarquee.stop()
                            marqueeMoving = false
                            remoteLabelText.x = 0
                            remoteLabelText.opacity = 1.0

                            if (marqueeNeeded
                                    && allowMarquee
                                    && marqueeScrollMs > 0) {
                                Qt.callLater(function() {
                                    if (remoteLabelBox.marqueeNeeded
                                            && remoteLabelBox.allowMarquee
                                            && remoteLabelBox.visible
                                            && remoteLabelBox.marqueeScrollMs > 0)
                                        remoteLabelMarquee.start()
                                })
                            }
                        }
                    }

                    Item {
                        id: remoteToggleWrap
                        width: 68
                        height: 30
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter

                        Rectangle {
                            anchors.fill: parent
                            radius: height / 2
                            border.width: 1
                            border.color: panel.remoteControlEnabled ? "#E6EEFF" : "#4B5685"
                            gradient: Gradient {
                                GradientStop {
                                    position: 0.0
                                    color: panel.remoteControlEnabled ? "#2F7CFF" : "#2A3152"
                                }
                                GradientStop {
                                    position: 1.0
                                    color: panel.remoteControlEnabled ? "#7EC4FF" : "#1C2342"
                                }
                            }
                        }

                        Rectangle {
                            width: 24
                            height: 24
                            radius: height / 2
                            anchors.verticalCenter: parent.verticalCenter
                            x: panel.remoteControlEnabled
                               ? (remoteToggleWrap.width - width - 3) : 3
                            color: panel.remoteControlEnabled ? "#FFFFFF" : "#D4D9F1"
                            border.color: panel.remoteControlEnabled ? "#FFFFFF" : "#C7CCE6"
                            border.width: 1
                            Behavior on x {
                                NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                            }
                        }
                    }
                }

                Keys.onPressed: {
                    if (event.key === Qt.Key_Left) {
                        panel._setRemoteControl(false);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Right) {
                        panel._setRemoteControl(true);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return
                               || event.key === Qt.Key_Enter
                               || event.key === Qt.Key_Select) {
                        panel._setRemoteControl(!panel.remoteControlEnabled);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up) {
                        playbackModeRow.forceActiveFocus();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down) {
                        aboutTitle.forceActiveFocus();
                        event.accepted = true;
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: remoteControlRow.forceActiveFocus()
                    onClicked: {
                        panel._setRemoteControl(!panel.remoteControlEnabled);
                        mouse.accepted = true;
                    }
                }
            }

            Rectangle { width: parent.width; height: 2; color: "#e0d200" }

            /* ===== À propos ===== */
            FocusScope {
                id: aboutTitle
                width: parent.width
                height: 28
                Keys.onPressed: {
                    if (event.key === Qt.Key_Up)  { remoteControlRow.forceActiveFocus(); event.accepted = true }
                    else if (event.key === Qt.Key_Down) { remoteControlRow.forceActiveFocus(); event.accepted = true }
                }
                Text { text: "À propos"; color: "#cfd6ff"; font.pixelSize: 16; font.bold: true }
            }
            Text { width: parent.width; text: panel.versionText; color: "#ffffff"; font.pixelSize: 18 }

            Item { width: parent.width; height: 0 }
        }

        // Anti-fuite focus + raccourcis sur la feuille
        Keys.onPressed: {
            if (event.key === Qt.Key_Menu || event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
                panel.requestClose();
                panel.close();
                event.accepted = true;
            } else if (event.key === Qt.Key_Right) {
                event.accepted = true;
            }
        }
    }

    /* === Aide des modes de lecture : boîte de dialogue sans QtQuick Controls === */
    FocusScope {
        id: playbackInfoDialog
        anchors.fill: parent
        z: 7000
        visible: panel._playbackInfoOpen
        enabled: visible
        focus: visible

        Rectangle {
            anchors.fill: parent
            color: "#000000"
            opacity: 0.72

            MouseArea {
                anchors.fill: parent
                onClicked: panel._closePlaybackInfo()
            }
        }

        Rectangle {
            width: Math.min(760, Math.max(620, panel.width * 0.44))
            height: 430
            anchors.centerIn: parent
            radius: 18
            color: "#11172D"
            border.width: 2
            border.color: "#7EC4FF"

            Item {
                anchors.fill: parent
                anchors.margins: 28

                Row {
                    id: playbackInfoHeader
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: 24
                    spacing: 10

                    Rectangle {
                        width: 24
                        height: 24
                        radius: 12
                        color: "#2F7CFF"
                        border.width: 1
                        border.color: "#E6EEFF"
                        Text {
                            anchors.centerIn: parent
                            text: "i"
                            color: "#FFFFFF"
                            font.pixelSize: 16
                            font.bold: true
                        }
                    }

                    Text {
                        text: "Modes de lecture"
                        color: "#FFFFFF"
                        font.pixelSize: 23
                        font.bold: true
                        height: parent.height
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Rectangle {
                    id: playbackInfoSeparator
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: playbackInfoHeader.bottom
                    anchors.topMargin: 14
                    height: 1
                    color: "#38436C"
                }

                Text {
                    id: smartModeTitle
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: playbackInfoSeparator.bottom
                    anchors.topMargin: 14
                    text: "Intelligent"
                    color: "#8EB9FF"
                    font.pixelSize: 17
                    font.bold: true
                }

                Text {
                    id: smartModeDescription
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: smartModeTitle.bottom
                    anchors.topMargin: 8
                    text: "ReDeFin applique automatiquement ses règles pour maximiser les chances de démarrer avec la piste audio française et sans sous-titres indésirables. Pour cela, il peut demander à Jellyfin un remux. Un remux ne réencode ni la vidéo ni l’audio : il change seulement le conteneur et réorganise les pistes. Il demande donc très peu de ressources CPU au serveur et n’ajoute pratiquement aucune charge au lecteur."
                    color: "#E8ECFF"
                    font.pixelSize: 14
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                }

                Text {
                    id: originalModeTitle
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: smartModeDescription.bottom
                    anchors.topMargin: 14
                    text: "Original"
                    color: "#8EB9FF"
                    font.pixelSize: 17
                    font.bold: true
                }

                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: originalModeTitle.bottom
                    anchors.topMargin: 8
                    text: "ReDeFin privilégie le fichier tel qu’il est stocké et neutralise les règles préventives qui auraient choisi un remux ou un transcodage pour contourner un risque, par exemple la présence de sous-titres DVDSub. Les incompatibilités matérielles réelles restent prioritaires : un codec vidéo non pris en charge, comme AV1 sur Freebox Devialet, sera toujours transcodé. La piste audio et les sous-titres dépendent davantage de l’ordre et des réglages du fichier."
                    color: "#E8ECFF"
                    font.pixelSize: 14
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                }

                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 8
                    text: "i / INFO, OK ou Retour pour fermer"
                    color: "#8F98BD"
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }

        Keys.onPressed: {
            if (panel._handlePlaybackInfoPressed(event))
                return;
            if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape ||
                event.key === Qt.Key_Menu || event.key === Qt.Key_Return ||
                event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                panel._closePlaybackInfo();
                event.accepted = true;
            } else {
                event.accepted = true;
            }
        }

        Keys.onReleased: {
            if (panel._isPlaybackInfoKey(event))
                panel._handlePlaybackInfoReleased(event);
            else
                event.accepted = true;
        }
    }

    /* === Animations === */
    ParallelAnimation {
        id: animIn
        PropertyAnimation {
            target: sheet
            property: "x"
            to: panel.width - sheet.width
            duration: 220
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: overlay
            property: "opacity"
            to: 0.55
            duration: 160
            easing.type: Easing.OutCubic
        }
    }

    ParallelAnimation {
        id: animOut
        PropertyAnimation {
            target: sheet
            property: "x"
            to: panel.width
            duration: 180
            easing.type: Easing.InCubic
        }
        NumberAnimation {
            target: overlay
            property: "opacity"
            to: 0.0
            duration: 140
            easing.type: Easing.InCubic
        }
        onStopped: {
            panel._playbackInfoOpen = false;
            panel._open = false;
            panel.closed();
        }
    }
}
