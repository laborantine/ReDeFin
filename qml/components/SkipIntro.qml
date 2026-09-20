// qml/components/SkipIntro.qml — QtQuick 2.15
// Bouton Skip Intro léger pour PlayerOverlay.
// PlayerOverlay reste l'autorité sur la fenêtre Jellyfin ; ce composant gère
// uniquement l'animation, le focus télécommande et l'interaction utilisateur.

import QtQuick 2.15
FocusScope {
    id: root
    objectName: "SkipIntroButton"
    anchors.fill: parent
    clip: false

    /* ===================== API ===================== */
    // État canonique poussé par PlayerOverlay.
    property bool show: false
    property string label: "Passer le générique"

    // Contexte poussé par playeroverlay.qml
    property int uiMs: 0
    property int endMs: -1
    // Contrat PlayerOverlay actuel.
    signal skipRequested(int targetMs)
    signal dismissed()
    signal focusBelowRequested()
    // Émis uniquement lorsque la fenêtre de 10 s expire d’elle-même.
    // Contrairement à dismissed(), ce signal ne doit jamais réveiller le chrome PlayerOverlay.
    signal visualExpired()

    // Compat: certains binders poussent un safeMargin unique (ex: 60)
    property int safeMargin: 0

    // PlayerOverlay peut binder ces propriétés (safe area)
    property int safeMarginLeft: 0
    property int safeMarginRight: 0
    property int safeMarginTop: 0
    property int safeMarginBottom: 0

    // Si wrapper externe applique déjà le safe-area
    property bool safeAreaAlreadyApplied: false

    // Remonter au-dessus de la progressbar
    property int avoidBottom: 0

    property bool stealFocusOnShow: false
    // Le bouton peut être prioritaire visuellement/logiquement sans voler le
    // focus natif QML. Quand les panneaux sont visibles, le cadre blanc et le
    // routage prioritaire restent actifs, mais les directions peuvent libérer
    // cette priorité vers le PlayerOverlay.
    property bool prioritizeOnShow: true

    // État de focus réclamé explicitement par PlayerOverlay / D-Pad.
    // On le mémorise car, sur certains backends Freebox, PlayerOverlay garde
    // Keys.BeforeItem et activeFocus peut rebondir brièvement vers le parent.
    // Le visuel doit malgré tout rester stable jusqu'à une sortie explicite (↓/Back/skip).
    property bool focusClaimed: false
    readonly property bool priorityFocusActive:
        effectiveShow && !_exitAnimating && focusClaimed

    function showPanel() { show = true }
    function hidePanel() { show = false }

    /* ===================== UI / PERF ===================== */
    readonly property int w: 360
    readonly property int h: 72
    readonly property int m: 24

    // Animation SVOD sobre : translation + opacité uniquement.
    // Aucun blur / ShaderEffect afin de rester très léger sur Freebox Révolution.
    property int enterDurationMs: 220
    property int exitDurationMs: 180
    property int enterOffsetPx: 55
    property int exitOffsetPx: 35
    property int fillStartDelayMs: 180

    // Anti-flicker / anti-auto-click
    property int armDelayMs: 250
    property int minShowHoldMs: 450

    /* ===================== Animation visuelle 10 s ===================== */
    // Comportement volontaire façon Netflix :
    // - le bouton reste affiché au maximum 10 s ;
    // - le voile clair progresse de gauche à droite pendant ces 10 s ;
    // - l'expiration VISUELLE ne vaut jamais "dismissed".
    // Le parent reste l'unique autorité sur le segment Jellyfin et son état.
    property bool autoHideEnabled: true
    property int  autoHideMs: 10000
    property real fillT: 0

    function _startFillCountdown() {
        fillAnim.stop()
        fillT = 0
        if (!autoHideEnabled || autoHideMs <= 0 || !effectiveShow)
            return
        fillAnim.duration = Math.max(1, autoHideMs | 0)
        fillAnim.start()
    }

    function _stopFillCountdown() {
        fillAnim.stop()
        fillT = 0
    }

    // Fin des 10 s : disparition uniquement locale.
    // Ne pas émettre dismissed(), sinon PlayerOverlay considérerait
    // à tort que l'utilisateur a explicitement refusé le Skip Intro.
    function _expireVisualWindow() {
        if (!effectiveShow || _exitAnimating)
            return
        armed = false
        focusDelay.stop()
        fillT = 1
        // Informer PlayerOverlay AVANT de désactiver le FocusScope : il peut ainsi
        // récupérer le focus natif sans réafficher ses panneaux haut/bas.
        visualExpired()
        _startExitAnimation("visual-expired")
    }

    /* ===================== TIMING / SAFE AREA ===================== */
    property double _lastShowTs: 0
    property double _lastHideRequestTs: 0
    function nowMs() { return Date.now() }

    function _pickMargin(primary, fallback) {
        var p = (primary|0)
        if (p > 0) return p
        var f = (fallback|0)
        return f > 0 ? f : 0
    }

    function _safeL() { return safeAreaAlreadyApplied ? 0 : _pickMargin(safeMarginLeft,  safeMargin) }
    function _safeR() {
        return safeAreaAlreadyApplied ? 0 : _pickMargin(safeMarginRight, safeMargin)
    }
    function _safeT() { return safeAreaAlreadyApplied ? 0 : _pickMargin(safeMarginTop,   safeMargin) }
    function _safeB() {
        return safeAreaAlreadyApplied ? 0 : _pickMargin(safeMarginBottom, safeMargin)
    }

    function _padL() { return Math.max(m, _safeL()) }
    function _padR() { return Math.max(m, _safeR()) }
    function _padT() { return Math.max(m, _safeT()) }
    function _padB() { return Math.max(m, _safeB()) + Math.max(0, avoidBottom|0) }

    /* ===================== ÉTAT INTERNE ===================== */
    property bool effectiveShow: false
    property bool armed: false

    // revealT pilote uniquement le rendu : 0 = caché, 1 = position/opacité finales.
    property real revealT: 0.0
    property bool _exitAnimating: false

    function _startEnterAnimation() {
        exitAnim.stop()
        _exitAnimating = false
        revealT = 0.0
        enterAnim.stop()
        enterAnim.start()
    }

    // Réclame explicitement la priorité D-Pad. Le PlayerOverlay utilise
    // Keys.BeforeItem : une simple propriété focus:true ne suffit donc pas
    // toujours lors d'une apparition asynchrone du Loader.
    function claimPriorityFocus(reason, requestNativeFocus) {
        var nativeFocus = requestNativeFocus !== false

        if (!effectiveShow || _exitAnimating) {
    
            return false
        }
        enabled = true
        armed = true
        focusClaimed = true

        // Avec chrome visible, la priorité est logique/visuelle uniquement.
        // Chrome masqué, on réclame aussi le focus natif QML.
        if (nativeFocus) {
            try { root.forceActiveFocus(Qt.OtherFocusReason) } catch(e0) {  }
            try { inner.forceActiveFocus(Qt.OtherFocusReason) } catch(e1) {  }
        }

        return true
    }

    // Rend le focus logique sans masquer SkipIntro. Utilisé lorsque le bouton avait
    // pris le focus automatiquement pendant que le chrome était caché et que les
    // panneaux PlayerOverlay réapparaissent ensuite.
    function releasePriorityFocus(reason) {

        focusClaimed = false
        stealFocusOnShow = false
        focusDelay.stop()
        priorityFocusRetry.stop()
        try { root.focus = false } catch(e0) {  }
        try { inner.focus = false } catch(e1) {  }

    }

    function _startExitAnimation(reason) {
        if (!effectiveShow || _exitAnimating)
            return
        _exitAnimating = true
        armed = false
        focusClaimed = false
        armTimer.stop()
        focusDelay.stop()
        priorityFocusRetry.stop()
        fillDelay.stop()
        enabled = false
        enterAnim.stop()
        exitAnim.stop()
        exitAnim.start()

    }

    function _finishExitAnimation() {
        if (!_exitAnimating)
            return
        _exitAnimating = false
        effectiveShow = false
        focusClaimed = false
        enabled = false
        revealT = 0.0

    }

    function _doSkip(where) {

        if (!effectiveShow) return

        // Même non-armé, on consomme l’intention, mais on ne skip pas.
        if (!armed) {

            return
        }

        var target = endMs > 0 ? endMs : Math.max(0, uiMs)
        _stopFillCountdown()
        _startExitAnimation("skip")

        // Émettre le signal du contrat actuel. playeroverlay écoute skipRequested(int).
        skipRequested(target)
    }

    function _doHide(where) {

        if (!effectiveShow) return
        _stopFillCountdown()
        _startExitAnimation("dismiss")
        dismissed()
        // Met à jour les alias logiques ; la disparition visuelle reste animée.
        hidePanel()
    }

    function _doFocusBelow(where) {
        // ↓ doit libérer le FocusScope natif aussi complètement que ←/→.
        // Sans cela, certains backends Freebox conservent activeFocus sur SkipIntro :
        // la ProgressBar répond encore, mais les transports/réglages restent inertes
        // jusqu'à une direction horizontale qui, elle, appelait déjà releasePriorityFocus().
        releasePriorityFocus(where || "focus-below")
        focusBelowRequested()
    }

    /* ===================== KEY POLICY ===================== */
    // ⚠️ IMPORTANT :
    // - Down NE DOIT PAS HIDE ici (PlayerOverlay gère ↓ = descendre vers progressbar)
    // - On CONSOMME quand même ↓ pour éviter que certains chemins internes déclenchent un hide.
    //   (Mais idéalement PlayerOverlay intercepte avant, Keys.priority: BeforeItem)

    Keys.enabled: effectiveShow && !_exitAnimating
    Keys.onPressed: function(ev) {

        if (!root.effectiveShow) return

        var ok = (ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter || ev.key === Qt.Key_Select || ev.key === Qt.Key_Space)
        if (ok) {
            ev.accepted = true
            root._doSkip("root")
            return
        }

        // ✅ Hide only with Back/Escape (Down removed)
        var hide = (ev.key === Qt.Key_Back || ev.key === Qt.Key_Escape)
        if (hide) {
            ev.accepted = true
            root._doHide("root")
            return
        }

        // ✅ Down: rendre le focus au playeroverlay/controls sans cacher SkipIntro.
        if (ev.key === Qt.Key_Down) {
            ev.accepted = true
            root._doFocusBelow("root")
            return
        }
    }

    /* ===================== LIFECYCLE ===================== */
    Component.onCompleted: {

        effectiveShow = show
        armed = false
        focusClaimed = false
        enabled = effectiveShow
        revealT = effectiveShow ? 1.0 : 0.0


    }
    onEffectiveShowChanged: {

        if (!effectiveShow) {
            enabled = false
            fillDelay.stop()
            if (fillAnim.running) fillAnim.stop()
        } else if (!_exitAnimating) {
            enabled = true
        }

    }
    /* ===================== SHOW PIPELINE ===================== */
    onShowChanged: {

        if (show) {
            _lastShowTs = nowMs()
            holdOff.stop()

            effectiveShow = true
            enabled = true

            _startEnterAnimation()
            armTimer.restart()

            if (prioritizeOnShow) {
                // Priorité visuelle/logique systématique. Le focus natif n'est
                // demandé que si PlayerOverlay a marqué stealFocusOnShow.
                Qt.callLater(function() {
                    if (root.show && root.effectiveShow && root.prioritizeOnShow &&
                            !root._exitAnimating)
                        root.claimPriorityFocus("show-callLater", root.stealFocusOnShow)
                })
            }

            if (stealFocusOnShow) {
                focusDelay.restart()
                priorityFocusRetry.restart()
            }

            fillDelay.restart()

        } else {
            _lastHideRequestTs = nowMs()

            armed = false
            focusClaimed = false
            armTimer.stop()
            focusDelay.stop()
            priorityFocusRetry.stop()
            fillDelay.stop()
            _stopFillCountdown()

            var age = _lastHideRequestTs - _lastShowTs
            if (effectiveShow && minShowHoldMs > 0 && age < minShowHoldMs) {
                var wait = Math.max(0, minShowHoldMs - age)
                holdOff.interval = wait
                holdOff.restart()

                return
            }

            _startExitAnimation("parent-hide")

        }
    }

    Timer {
        id: holdOff
        interval: 0
        repeat: false
        onTriggered: {
            if (root.show) return
            root._startExitAnimation("hold-off")

        }
    }

    Timer {
        id: armTimer
        interval: root.armDelayMs
        repeat: false
        onTriggered: {
            // Compat historique : si aucun focus prioritaire n'a encore été
            // obtenu, le bouton devient tout de même activable à l'issue du délai.
            if (root.effectiveShow && !root._exitAnimating)
                root.armed = true

        }
    }

    Timer {
        id: focusDelay
        interval: 70
        repeat: false
        onTriggered: {
            if (root.show && root.effectiveShow && root.stealFocusOnShow &&
                    !root._exitAnimating)
                root.claimPriorityFocus("focus-delay", true)
        }
    }

    Timer {
        id: priorityFocusRetry
        interval: 170
        repeat: false
        onTriggered: {
            if (root.show && root.effectiveShow && root.stealFocusOnShow &&
                    !root._exitAnimating && !root.priorityFocusActive)
                root.claimPriorityFocus("focus-retry", true)
        }
    }

    Timer {
        id: fillDelay
        interval: Math.max(0, root.fillStartDelayMs | 0)
        repeat: false
        onTriggered: {
            if (root.effectiveShow && root.show && !root._exitAnimating)
                root._startFillCountdown()
        }
    }

    /* ===================== Apparition / disparition SVOD ===================== */
    NumberAnimation {
        id: enterAnim
        target: root
        property: "revealT"
        to: 1.0
        duration: Math.max(1, root.enterDurationMs | 0)
        easing.type: Easing.OutCubic
    }

    NumberAnimation {
        id: exitAnim
        target: root
        property: "revealT"
        to: 0.0
        duration: Math.max(1, root.exitDurationMs | 0)
        easing.type: Easing.InCubic

        onRunningChanged: {
            if (!running && root._exitAnimating && root.revealT <= 0.001)
                root._finishExitAnimation()
        }
    }

    /* ===================== Remplissage clair 10 s ===================== */
    NumberAnimation {
        id: fillAnim
        target: root
        property: "fillT"
        from: 0
        to: 1
        duration: Math.max(1, root.autoHideMs)
        easing.type: Easing.Linear

        onRunningChanged: {
            if (!running &&
                    root.autoHideEnabled &&
                    root.effectiveShow &&
                    root.fillT >= 0.999) {
                root._expireVisualWindow()
            }
        }
    }

    /* ===================== PANEL ===================== */
    Item {
        id: panel
        width: root.w
        height: root.h

        property real t: Math.max(0.0, Math.min(1.0, root.revealT))

        readonly property real _baseX: root.width - width - root._padR()
        readonly property real _slideOffset:
            (1.0 - t) *
            Math.max(0, root._exitAnimating ? root.exitOffsetPx : root.enterOffsetPx)

        // Le bouton entre depuis la droite et repart vers la droite.
        // Pas de Behavior supplémentaire : revealT est l'unique animation,
        // ce qui garde translation et opacité parfaitement synchronisées.
        x: Math.max(root._padL(), _baseX + _slideOffset)

        y: Math.max(root._padT(),
                    Math.min(root.height - height - root._padB(),
                             root.height - height - root._padB()))

        opacity: t
        scale: 1.0
        enabled: root.effectiveShow && !root._exitAnimating
        visible: opacity > 0.01

        // Fond du bouton : rectangle noir pur, sans bordure extérieure.
        Rectangle {
            id: glass
            anchors.fill: parent
            radius: 12
            color: root.priorityFocusActive ? "#1B1B1B" : "#101010"
            opacity: root.priorityFocusActive ? 0.90 : 0.82
            // Focus télécommande explicite : bord blanc sans effet ni rendu hors-écran.
            border.width: root.priorityFocusActive ? 2 : 0
            border.color: "#FFFFFFFF"

            Behavior on color {
                ColorAnimation { duration: 90 }
            }
            Behavior on opacity {
                NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
            }
        }

        // Balayage temporel façon SVOD : une teinte gris clair remplit
        // progressivement l'intérieur de gauche à droite pendant 10 secondes,
        // sans curseur ni bord lumineux en tête de progression.
        // Aucun Behavior intermédiaire : le bord du remplissage atteint
        // réellement l'extrémité droite au même instant que fillAnim.
        Item {
            id: fillClip
            anchors.fill: parent
            anchors.margins: 2
            clip: true
            visible: root.effectiveShow && root.autoHideEnabled

            readonly property real sweepWidth:
                Math.max(0, Math.min(width, width * root.fillT))

            // Un seul remplissage gris. Le rectangle possède les mêmes coins
            // arrondis que le bouton, mais il est révélé dans une fenêtre dont
            // la largeur augmente. La coupe droite de cette fenêtre produit un
            // bord de progression parfaitement vertical, sans curseur ni joint.
            Item {
                id: sweepViewport
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: fillClip.sweepWidth
                clip: true

                Rectangle {
                    id: sweepFill
                    x: 0
                    y: 0
                    width: fillClip.width
                    height: fillClip.height
                    radius: 10
                    color: "#B8BCC2"
                    opacity: 0.34 * panel.t
                }
            }

        }

        FocusScope {
            id: inner
            z: 2
            anchors.fill: parent
            anchors.margins: 10
            clip: true
            focus: true
            Text {
                anchors.centerIn: parent
                text: root.label
                color: (root.priorityFocusActive || mouse.containsMouse) ? "#FFFFFFFF" : "#E6FFFFFF"
                opacity: panel.t
                font.pixelSize: (root.priorityFocusActive || mouse.containsMouse) ? 19 : 18
                font.bold: true
                Behavior on color { ColorAnimation { duration: 120 } }
                Behavior on font.pixelSize { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            }

            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: function(ev) {
                    if (!root.effectiveShow) return
                    ev.accepted = true
                    root._doSkip("mouse")
                }
            }

            Keys.enabled: root.effectiveShow && !root._exitAnimating
            Keys.onPressed: function(ev) {
        
                if (!root.effectiveShow) return

                var ok = (ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter || ev.key === Qt.Key_Select || ev.key === Qt.Key_Space)
                if (ok) {
                    ev.accepted = true
                    root._doSkip("inner")
                    return
                }

                // ✅ Hide only with Back/Escape (Down removed)
                var hide = (ev.key === Qt.Key_Back || ev.key === Qt.Key_Escape)
                if (hide) {
                    ev.accepted = true
                    root._doHide("inner")
                    return
                }

                // ✅ Down: rendre le focus au playeroverlay/controls sans cacher SkipIntro.
                if (ev.key === Qt.Key_Down) {
                    ev.accepted = true
                    root._doFocusBelow("inner")
                    return
                }
            }
        }
    }

}
