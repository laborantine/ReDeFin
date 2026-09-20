// qml/components/CircleDotsLoader.qml
import QtQuick 2.15

Item {
    id: root
    width: 64
    height: 64

    // Nombre de points sur le cercle
    property int dotCount: 12
    // Taille des points
    property int dotSize: 8
    // Durée d’un tour complet (ms)
    property int cycleDuration: 900

    // Rayon (distance du centre au point)
    property int radius: 26

    // 0 → aucun point / 1 → 1er point / ... / dotCount → cercle complet
    property int litCount: 0

    // Active/inactive (permet de couper l’anim sans jouer avec visible/enabled)
    property bool active: true

    // Les petits loaders locaux peuvent être pilotés explicitement.
    // preservePhase est utilisé uniquement par le loader global Shell afin de
    // reprendre la même phase sans laisser tourner le Timer hors écran.
    property bool running: true
    property bool preservePhase: false

    // Anti-timer zombie quand dotCount/cycleDuration changent
    function _recomputeInterval() {
        return Math.max(40, Math.floor(cycleDuration / Math.max(1, dotCount + 2)));
    }

    Timer {
        id: stepTimer
        interval: root._recomputeInterval()
        running: root.visible && root.enabled && root.active && root.running
        repeat: true
        onTriggered: root.litCount = (root.litCount + 1) % (root.dotCount + 1)
    }

    // Reset propre si on réactive / si on change la géométrie
    onActiveChanged: {
        if (!active) {
            if (!preservePhase) litCount = 0;
        } else if (visible && enabled && running) {
            stepTimer.restart();
        }
    }
    onRunningChanged: {
        if (!running) {
            if (!preservePhase) litCount = 0;
        } else if (visible && enabled && active) {
            stepTimer.restart();
        }
    }
    onDotCountChanged: {
        litCount = 0;
        stepTimer.interval = _recomputeInterval();
        if (stepTimer.running) stepTimer.restart();
    }
    onCycleDurationChanged: {
        stepTimer.interval = _recomputeInterval();
        if (stepTimer.running) stepTimer.restart();
    }

    // Points disposés en cercle, qui se révèlent progressivement
    Repeater {
        model: Math.max(0, root.dotCount)

        delegate: Item {
            width: root.width
            height: root.height
            anchors.centerIn: root

            // Angle par point
            readonly property real angleDeg: index * (360 / Math.max(1, root.dotCount))

            transform: Rotation {
                origin.x: width / 2
                origin.y: height / 2
                angle: angleDeg
            }

            Rectangle {
                width: root.dotSize
                height: root.dotSize
                radius: width / 2

                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.max(0, Math.round((parent.height / 2) - root.radius - (height / 2)))

                color: "#E7ECFF"

                // Opacité :
                //  - très faible si le point n’est pas encore “allumé”
                //  - forte si index < litCount
                opacity: (index < root.litCount) ? 1.0 : 0.12

                // Sur Freebox, l’AA sur plein de petits items peut coûter cher → off par défaut
                antialiasing: false

                Behavior on opacity {
                    NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                }
            }
        }
    }
}
