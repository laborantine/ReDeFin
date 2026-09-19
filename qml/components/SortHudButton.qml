// qml/components/SortHudButton.qml — QtQuick 2.15 only, aucun QtQuick Controls
// Petit bouton de tri HUD + menu popup léger pour Freebox.

import QtQuick 2.15

FocusScope {
    id: root

    width: 56
    height: 32
    focus: false

    property var options: []
    property int selectedIndex: 0
    property int currentMenuIndex: selectedIndex
    property bool popupOpen: false
    property real popupProgress: popupOpen ? 1.0 : 0.0

    Behavior on popupProgress { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

    property string label: "A-Z"
    property color accentColor: "#7DEAE4"
    property color panelColor: "#202126"
    property color textColor: "#FFFFFF"
    property int menuWidth: 372
    property int rowHeight: 54

    signal activated(int index)
    signal requestFocusAvatar()
    signal requestFocusGrid()

    function _closeAndFocus() {
        popupOpen = false
        try { root.forceActiveFocus(Qt.OtherFocusReason) } catch(e) {}
    }

    function focusButton() {
        _closeAndFocus()
    }

    function openMenu() {
        if (!options || options.length <= 0) return
        currentMenuIndex = Math.max(0, Math.min(selectedIndex | 0, options.length - 1))
        popupOpen = true
        try { root.forceActiveFocus(Qt.OtherFocusReason) } catch(e) {}
    }

    function closeMenu() {
        _closeAndFocus()
    }

    function triggerCurrent() {
        if (!options || options.length <= 0) return
        var idx = Math.max(0, Math.min(currentMenuIndex | 0, options.length - 1))
        popupOpen = false
        activated(idx)
        try { root.forceActiveFocus(Qt.OtherFocusReason) } catch(e) {}
    }

    Keys.onPressed: {
        if (popupOpen) {
            if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape || event.key === Qt.Key_Left) {
                closeMenu()
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Up) {
                currentMenuIndex = Math.max(0, currentMenuIndex - 1)
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Down) {
                currentMenuIndex = Math.min((options ? options.length : 1) - 1, currentMenuIndex + 1)
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                triggerCurrent()
                event.accepted = true
                return
            }
            return
        }

        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
            openMenu()
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_Up) {
            requestFocusAvatar()
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_Down) {
            requestFocusGrid()
            event.accepted = true
            return
        }
    }

    Text {
        id: iconText
        anchors.centerIn: parent
        text: root.label
        textFormat: Text.PlainText
        color: (root.activeFocus || root.popupOpen) ? "#FFFFFF" : Qt.rgba(1, 1, 1, 0.68)
        font.pixelSize: 17
        font.bold: (root.activeFocus || root.popupOpen)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: false
        onClicked: {
            try { root.forceActiveFocus(Qt.MouseFocusReason) } catch(e) {}
            if (root.popupOpen) root.closeMenu()
            else root.openMenu()
        }
    }

    Item {
        id: popup
        z: 2000
        visible: root.popupOpen || root.popupProgress > 0.01
        width: root.menuWidth
        readonly property int optionCount: root.options ? root.options.length : 0
        readonly property int fullHeight: root.rowHeight * optionCount + 16
        height: Math.round(fullHeight * root.popupProgress)
        x: root.width - width
        y: root.height + 8 - Math.round((1.0 - root.popupProgress) * 6)
        opacity: Math.max(0.0, Math.min(1.0, root.popupProgress))
        clip: true

        Rectangle {
            anchors.fill: parent
            radius: 8
            color: root.panelColor
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.10)
            opacity: 0.98
        }

        Rectangle {
            id: focusPill
            x: 8
            y: 8 + root.currentMenuIndex * root.rowHeight
            width: popup.width - 16
            height: root.rowHeight
            radius: 7
            visible: popup.optionCount > 0
            color: Qt.rgba(1, 1, 1, 0.08)

            Behavior on y { NumberAnimation { duration: 135; easing.type: Easing.OutCubic } }
        }

        Repeater {
            model: root.options ? root.options.length : 0

            Item {
                id: rowItem
                x: 8
                y: 8 + index * root.rowHeight
                width: popup.width - 16
                height: root.rowHeight

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 18
                    anchors.right: radioOuter.left
                    anchors.rightMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.options[index]
                    textFormat: Text.PlainText
                    color: root.textColor
                    font.pixelSize: 23
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                }

                Rectangle {
                    id: radioOuter
                    width: 30
                    height: 30
                    radius: 15
                    anchors.right: parent.right
                    anchors.rightMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    color: Qt.rgba(0, 0, 0, 0)
                    border.width: 3
                    border.color: index === root.selectedIndex ? root.accentColor : Qt.rgba(1, 1, 1, 0.70)

                    Rectangle {
                        width: 16
                        height: 16
                        radius: 8
                        anchors.centerIn: parent
                        visible: index === root.selectedIndex
                        color: root.accentColor
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: false
                    onClicked: {
                        root.currentMenuIndex = index
                        root.triggerCurrent()
                    }
                }
            }
        }
    }
}
