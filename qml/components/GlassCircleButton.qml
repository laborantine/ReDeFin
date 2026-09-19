// GlassCircleButton.qml — QtQuick 2.15 — Capsule Glass avec actions intégrées
// ✅ Tweaks rapides Freebox appliqués:
// 1) FastBlur/DropShadow remplacés par Rectangles/gradients statiques
// 2) iconOversample 3.0 -> 2.0 pour limiter RAM/texture
// 3) Rendu glass statique sans blur/offscreen
// 4) Burst réellement désactivé quand burstOnCheck=false
// 5) Debug logs supprimés pour la production
// 6) Canvas fallback glyph : repaint uniquement quand visible

import QtQuick 2.15
Item {
  id: root

  /* ====== Dimensions ====== */
  property real  size: 64
  property int   labelFontPx: 12
  property int   labelTopMargin: 6
  property bool  showLabel: false

  property bool shouldShow: true
  width: shouldShow ? size : 0
  implicitWidth: size
  implicitHeight: size + (showLabel ? (labelTopMargin + labelFontPx + 2) : 0)
  height: shouldShow ? implicitHeight : 0
  focus: true
  clip: false

  /* ===== API visuelle ===== */
  property color iconColor: "#FFFFFF"          // off (blanc)
  property color iconColorChecked: "#FF3B30"   // on (rouge)

  // L’icône a son propre scale (press feedback), mais on *contre* le zoom de focus pour rester nette
  property real  iconScale: pressArea.pressed ? 0.92 : 1.0

  // Pulse visuel indépendant du scale réel de l'icône.
  // Ne jamais réutiliser iconWrap.scale comme base d'animation : lors des
  // mises à jour rapides de UserData, cela pouvait multiplier le scale à
  // chaque restart de l'animation jusqu'à faire exploser le layout.
  property real  _iconPulseScale: 1.0

  // Sur-échantillonnage de la texture icône (et du Canvas fallback)
  property real  iconOversample: 2.0

  // Glyph interne
  // "auto"→ selon actionType ; "play"|"resume"|"shuffle"|"check"|"heart"|"none"
  property string glyphKind: "auto"

  function _requestGlyphPaint() {
    try {
      if (glyph && glyph.visible) glyph.requestPaint();
    } catch(e) {}
  }

  // Anneau/halo focus → blanc par défaut
  property color focusRingColor: "#FFFFFF"
  property real  haloStrength: (activeFocus || pressArea.containsMouse) && !disabled ? 1.0 : 0.0

  property real  glassOpacity: disabled ? 0.24 : 0.42
  property bool  disabled: false

  // AA discipline
  property bool aaMainCircle: true
  property bool aaHalo: true
  property bool aaSecondary: false
  property bool pointerHoverEnabled: true

  /* ===== API interaction ===== */
  property bool captureKeys: true

  // Mode toggle générique (utilisé par vu/like)
  property bool checkable: false
  property bool checked: false

  // Hints + Label
  property string hintText: ""
  property string hintTextChecked: ""
  property string autoHintText: ""
  property string hintMode: "focus" // "none"|"focus"|"hover"|"always"
  property string labelText: ""
  property string labelTextChecked: ""

  readonly property string currentHint: (checked && hintTextChecked !== "") ? hintTextChecked
                                       : (hintText !== "") ? hintText : autoHintText
  readonly property bool hintVisible: {
    if (hintMode === "none")   return false;
    if (hintMode === "always") return true;
    if (hintMode === "hover")  return pressArea.containsMouse;
    return (activeFocus || pressArea.containsMouse);
  }

  /* ===== HINT GLOBAL (option zéro câblage) ===== */
  property var    explicitHintTarget: null
  property string autoHintTargetName: "GlassHintBar"

  // Cache du hint target (TWEAK 4)
  property var  _cachedHintTarget: null
  property bool _hintCacheValid: false

  function _invalidateHintCache() {
    _hintCacheValid = false;
    _cachedHintTarget = null;
  }
  onExplicitHintTargetChanged: _invalidateHintCache()
  onAutoHintTargetNameChanged: _invalidateHintCache()
  onParentChanged: _invalidateHintCache()

  function _findByObjectName(start, name, maxDepth) {
    if (!start || maxDepth <= 0) return null;
    if (start.objectName && start.objectName === name) return start;
    var cs = start.children || [];
    for (var i = 0; i < cs.length; ++i) {
      var c = cs[i];
      if (!c) continue;
      if (c.objectName && c.objectName === name) return c;
      var got = _findByObjectName(c, name, maxDepth - 1);
      if (got) return got;
    }
    return null;
  }

  function _findHintTarget() {
    if (explicitHintTarget) return explicitHintTarget;

    if (_hintCacheValid) return _cachedHintTarget;

    var p = root.parent;
    var climb = 8;
    while (p && climb-- > 0) {
      var t = _findByObjectName(p, autoHintTargetName, 2);
      if (t) {
        _cachedHintTarget = t;
        _hintCacheValid = true;
        return t;
      }
      p = p.parent;
    }
    _cachedHintTarget = null;
    _hintCacheValid = true;
    return null;
  }

  function _pushHintToTarget(text, visible) {
    var t = _findHintTarget();
    if (!t) return;

    // Plusieurs GlassCircleButton partagent souvent le même GlassHintBar.
    // Une mise à jour asynchrone d'un bouton non focusé ne doit pas effacer
    // ou remplacer le texte du bouton actuellement focusé. Si le target
    // expose hintOwner (SeasonPage le fait), on applique une ownership légère.
    var supportsOwner = false;
    try { supportsOwner = (t.hintOwner !== undefined); } catch(e0) {}

    if (visible && text) {
      if (supportsOwner) t.hintOwner = root;
      if (t.text !== undefined) t.text = text;
      if (t.opacity !== undefined) t.opacity = 1.0;
      return;
    }

    if (supportsOwner) {
      try {
        if (t.hintOwner && t.hintOwner !== root) return;
        t.hintOwner = null;
      } catch(e1) {}
    }
    if (t.text !== undefined) t.text = "";
    if (t.opacity !== undefined) t.opacity = 0.0;
  }

  /* ===== Actions intégrées ===== */
  // "none"|"play"|"shuffle"|"toggleSeen"|"toggleLike"
  property string actionType: "none"

  // Callbacks externes optionnels
  property var onAction: null
  property var onPlay: null
  property var onShuffle: null
  property var onToggleSeen: null
  property var onToggleLike: null
  property var actionGuard: null

  // Persistance/sync d’état pour toggles
  property var getState: null
  property var setState: null

  /* Compat héritée (laisser tel quel si non utilisé) */
  property color tintColor: iconColor
  onTintColorChanged: iconColor = tintColor
  property color tintColorChecked: iconColorChecked
  onTintColorCheckedChanged: iconColorChecked = tintColorChecked

  /* Animations options */
  property bool burstOnCheck: true
  property int  burstCount: 8
  property bool popOnChange: true
  property int  animDuration: 220
  property int  fireCooldownMs: 0

  /* Interne : interpolation couleur icône */
  property real _tintProgress: checked ? 1 : 0

  /* Garde-fou */
  property bool _firing: false
  Timer {
    id: fireCooldownTimer
    interval: Math.max(1, root.fireCooldownMs)
    repeat: false
    onTriggered: root._firing = false
  }

  /* ==== ACTIONS INTÉGRÉES ==== */
  property bool _quietCheckedSync: false

  function _setCheckedQuiet(value){
    var v = !!value;
    if (checked === v) {
      _tintProgress = v ? 1 : 0;
      _requestGlyphPaint();
      _emitHint();
      return;
    }
    _quietCheckedSync = true;
    checked = v;
    _quietCheckedSync = false;
    _tintProgress = v ? 1 : 0;
    _iconPulseScale = 1.0;
    _requestGlyphPaint();
    _emitHint();
  }

  function _applyStateFromGetter(){
    if (typeof getState === "function") {
      try { _setCheckedQuiet(!!getState()); } catch(e){}
    }
  }

  function _persistState(){
    if (typeof setState === "function") {
      try { setState(!!checked); } catch(e){}
    }
  }

  function _toggleCheckedFromUser(){
    if (!checkable) return;
    checked = !checked;
    _persistState();
  }

  function _finishFire(){
    if (fireCooldownMs > 0) fireCooldownTimer.restart();
    else _firing = false;
  }

  function _fireAction(origin){
    if (disabled || !shouldShow || _firing) return;
    if (typeof actionGuard === "function") {
      try { if (!actionGuard(actionType, origin)) return; } catch(e0) { return; }
    }
    _firing = true;
    try {
      if (actionType === "play" || actionType === "restart" || actionType === "resume") {
        if (typeof onPlay === "function") onPlay(actionType);
        if (typeof onAction === "function") onAction(actionType, checked);
        triggered(actionType);
      } else if (actionType === "shuffle") {
        if (typeof onShuffle === "function") onShuffle();
        if (typeof onAction === "function") onAction("shuffle", checked);
        triggered("shuffle");
      } else if (actionType === "toggleSeen") {
        if (!checkable) checkable = true;
        _toggleCheckedFromUser();
        if (typeof onToggleSeen === "function") onToggleSeen(!!checked);
        if (typeof onAction === "function") onAction("toggleSeen", checked);
        if (burstOnCheck && checked) burstAnim.restart();
        triggered("toggleSeen");
      } else if (actionType === "toggleLike") {
        if (!checkable) checkable = true;
        _toggleCheckedFromUser();
        if (typeof onToggleLike === "function") onToggleLike(!!checked);
        if (typeof onAction === "function") onAction("toggleLike", checked);
        if (burstOnCheck && checked) burstAnim.restart();
        triggered("toggleLike");
      } else {
        if (checkable) _toggleCheckedFromUser();
        if (typeof onAction === "function") onAction("none", checked);
        triggered("none");
      }
    } finally { _finishFire(); }
  }

  function requestGlyphPaint(){ _requestGlyphPaint(); }

  /* Signaux publics */
  signal triggered(var origin)

  /* Hints */
  property string _lastHintText: ""
  property bool   _lastHintVis: false
  function _emitHint(){
    var t = currentHint, v = hintVisible;
    if (t === _lastHintText && v === _lastHintVis) return;
    _lastHintText = t; _lastHintVis = v;
    _pushHintToTarget(t, v);
  }

  /* ====== Keyboard ====== */
  Keys.enabled: captureKeys
  Keys.priority: Keys.AfterItem
  Keys.onPressed: {
    if (!captureKeys || event.accepted) return;
    if (event.key===Qt.Key_Return || event.key===Qt.Key_Enter || event.key===Qt.Key_Select || event.key===Qt.Key_Space) {
      _fireAction("key");
      event.accepted = true;
    }
  }
  Keys.onReleased: event.accepted = false

  /* ===== Layout principal (cercle + label) ===== */
  // État de scale utilisé par les états; exposé pour compenser le scale de l’icône.
  property real _stackScale: 1.0

  Column {
    id: stack
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    spacing: showLabel ? labelTopMargin : 0
    scale: root._stackScale
    visible: root.shouldShow

    /* === Cercle === */
    Item {
      id: circle
      width: size
      height: size

      /* Ombre BASE — FAKE (TWEAK 1) : 0 shader */
      /* Ombre externe supprimée : aucun cercle supplémentaire autour du bouton */

      /* Faux “glass” (fallback/perf) */
      Rectangle {
        id: glass
        anchors.fill: parent
        radius: width/2
        opacity: glassOpacity
        visible: true
        gradient: Gradient {
          GradientStop { position: 0.0; color: "#66FFFFFF" }
          GradientStop { position: 1.0; color: "#1AFFFFFF" }
        }
        border.width: 1
        border.color: "#33FFFFFF"
        antialiasing: aaMainCircle
      }

      // Highlight diagonal (AA réduit)
      Rectangle {
        anchors.fill: parent
        radius: width/2
        visible: glass.visible
        opacity: 0.22
        gradient: Gradient {
          GradientStop { position: 0.00; color: "#33FFFFFF" }
          GradientStop { position: 0.45; color: "#11FFFFFF" }
          GradientStop { position: 1.00; color: "#00FFFFFF" }
        }
        rotation: -24
        antialiasing: aaSecondary
      }

      /* Halo focus/hover (anneau blanc) — rendu seulement si visible (TWEAK 1) */
      /* Focus: un seul contour interne, aucun halo externe */
      Item {
        id: halo
        anchors.centerIn: parent
        width: circle.width
        height: circle.height
        visible: haloStrength > 0.01
        opacity: haloStrength
        scale: 1.0

        Rectangle {
          anchors.fill: parent
          radius: width/2
          color: "transparent"
          border.width: 2
          border.color: Qt.rgba(focusRingColor.r, focusRingColor.g, focusRingColor.b, 0.55)
          antialiasing: aaHalo
        }
      }

      /* Ripple anneau (AA réduit) */

      /* Icône (image ou glyphe interne) — NON-ZOOMÉE avec le focus */
      Item {
        id: iconWrap
        anchors.centerIn: parent
        width: circle.width * 0.5
        height: width

        // Compensation : l’icône n’est pas agrandie par le zoom de focus (reste nette)
        scale: (iconScale * root._iconPulseScale) / Math.max(0.001, root._stackScale)

        // Icône Canvas directe : pas de texture offscreen d'image
        layer.enabled: false
        layer.smooth: false
        layer.samples: 0


        // Icône interne dessinée directement, sans effet GraphicalEffects
        Canvas {
          id: glyph
          anchors.centerIn: parent
          width: Math.round(parent.width  * iconOversample)
          height: Math.round(parent.height * iconOversample)
          scale: 1.0 / iconOversample
          visible: root.visible
          z: 5
          renderTarget: Canvas.Image
          antialiasing: true

          onPaint: {
            var ctx = getContext("2d");
            var w = width, h = height;
            var m = Math.min(w,h);
            ctx.clearRect(0,0,w,h);

            function css(c) {
              if (typeof c === "string") return c;
              var a = (c.a !== undefined) ? c.a : 1;
              return "rgba(" + ((c.r*255)|0) + "," + ((c.g*255)|0) + "," + ((c.b*255)|0) + "," + a + ")";
            }

            var t = Math.max(0, Math.min(1, _tintProgress));
            var useColor = Qt.rgba(
              iconColor.r * (1 - t) + iconColorChecked.r * t,
              iconColor.g * (1 - t) + iconColorChecked.g * t,
              iconColor.b * (1 - t) + iconColorChecked.b * t,
              iconColor.a * (1 - t) + iconColorChecked.a * t
            );
            ctx.fillStyle = css(useColor);
            ctx.strokeStyle = css(useColor);
            ctx.lineCap = "round";
            ctx.lineJoin = "round";

            var kind = glyphKind;
            if (kind === "auto" || kind === "") {
              if (actionType === "play" || actionType === "restart") kind = "play";
              else if (actionType === "resume") kind = "resume";
              else if (actionType === "shuffle") kind = "shuffle";
              else if (actionType === "toggleSeen") kind = "check";
              else if (actionType === "toggleLike") kind = "heart";
              else kind = "none";
            }

            if (kind === "play") {
              ctx.beginPath();
              ctx.moveTo(m*0.30, m*0.22);
              ctx.lineTo(m*0.30, m*0.78);
              ctx.lineTo(m*0.78, m*0.50);
              ctx.closePath();
              ctx.fill();
            } else if (kind === "resume") {
              // Reprendre : triangle de lecture + arc circulaire distinctif.
              // Ce glyph était utilisé avant la régression qui rabattait resume sur play.
              ctx.beginPath();
              ctx.moveTo(m*0.32, m*0.26);
              ctx.lineTo(m*0.32, m*0.74);
              ctx.lineTo(m*0.74, m*0.50);
              ctx.closePath();
              ctx.fill();

              var resumeLw = Math.max(2, Math.round(m*0.10));
              ctx.lineWidth = resumeLw;
              ctx.beginPath();
              ctx.arc(w*0.50, h*0.50, Math.min(w,h)*0.38, Math.PI*1.20, Math.PI*1.95, false);
              ctx.stroke();
            } else if (kind === "shuffle") {
              var lw = Math.max(2, Math.round(Math.min(w,h)*0.10));
              ctx.lineWidth = lw;
              ctx.beginPath(); ctx.moveTo(w*0.18,h*0.30); ctx.lineTo(w*0.42,h*0.30); ctx.lineTo(w*0.62,h*0.60); ctx.lineTo(w*0.82,h*0.60); ctx.stroke();
              ctx.beginPath(); ctx.moveTo(w*0.76,h*0.50); ctx.lineTo(w*0.86,h*0.60); ctx.lineTo(w*0.76,h*0.70); ctx.stroke();
              ctx.beginPath(); ctx.moveTo(w*0.18,h*0.70); ctx.lineTo(w*0.42,h*0.70); ctx.lineTo(w*0.62,h*0.40); ctx.lineTo(w*0.82,h*0.40); ctx.stroke();
              ctx.beginPath(); ctx.moveTo(w*0.76,h*0.30); ctx.lineTo(w*0.86,h*0.40); ctx.lineTo(w*0.76,h*0.50); ctx.stroke();
            } else if (kind === "check") {
              var lw2 = Math.max(2, Math.round(Math.min(w,h)*0.10));
              ctx.lineWidth = lw2;
              ctx.beginPath();
              ctx.moveTo(w*0.20, h*0.55);
              ctx.lineTo(w*0.42, h*0.76);
              ctx.lineTo(w*0.82, h*0.28);
              ctx.stroke();
            } else if (kind === "heart") {
              ctx.beginPath();
              var x = w/2, y = h*0.58, s = Math.min(w,h)/2.2;
              ctx.moveTo(x, y);
              ctx.bezierCurveTo(x+s*0.9, y-s*0.9, x+s*1.2, y+s*0.1, x, y+s*0.8);
              ctx.bezierCurveTo(x-s*1.2, y+s*0.1, x-s*0.9, y-s*0.9, x, y);
              ctx.closePath();
              ctx.fill();
            }
          }

          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
          onVisibleChanged: if (visible) requestPaint()
        }
      }

      /* Burst minimal */
      Item {
        id: burstLayer
        anchors.fill: parent
        visible: false
        property real p: 0

        Repeater {
          model: root.burstOnCheck ? Math.max(0, root.burstCount) : 0
          Rectangle {
            width: 6; height: 6; radius: 3
            color: iconColorChecked
            opacity: Math.max(0, 1.0 - burstLayer.p)
            anchors.centerIn: parent
            property real rad: (index * (2*Math.PI/model))
            x: parent.width/2  + Math.cos(rad) * burstLayer.p * (root.size*0.45) - width/2
            y: parent.height/2 + Math.sin(rad) * burstLayer.p * (root.size*0.45) - height/2
            antialiasing: false
          }
        }
        NumberAnimation on p {
          id: burstAnim
          from: 0; to: 1; duration: 320; easing.type: Easing.OutCubic; running: false
          onStarted: burstLayer.visible = true
          onStopped: burstLayer.visible = false
        }
      }

      /* Zone d’interaction */
      MouseArea {
        id: pressArea
        anchors.fill: parent
        hoverEnabled: root.pointerHoverEnabled
        enabled: !disabled
        cursorShape: Qt.PointingHandCursor
        onPressed: { root.focus = true }
        onClicked: { _fireAction("mouse"); }
        onEntered: { _emitHint(); }
        onExited:  { _emitHint(); }
      }
    }

    /* === Label optionnel local — showLabel=false recommandé (hint global) === */
    Text {
      id: label
      visible: showLabel
      anchors.horizontalCenter: circle.horizontalCenter
      text: {
        var t = (checked && labelTextChecked!=="") ? labelTextChecked
              : (labelText!=="") ? labelText
              : (checked && hintTextChecked!=="") ? hintTextChecked
              : (hintText!=="") ? hintText
              : "";
        return t;
      }
      color: root.activeFocus ? "#FFFFFF" : "#DDE1F6"
      opacity: root.activeFocus ? 1.0 : 0.9
      font.pixelSize: labelFontPx
    }
  } // Column stack

  /* === États/Transitions scale cercle (icône non affectée) === */
  states: [
    State {
      name: "idle"
      when: !(root.activeFocus || pressArea.containsMouse) || root.disabled
      PropertyChanges { target: root; _stackScale: 1.0 }
    },
    State {
      name: "focus"
      when: (root.activeFocus || pressArea.containsMouse) && !root.disabled && !pressArea.pressed
      PropertyChanges { target: root; _stackScale: 1.06 }
    },
    State {
      name: "pressed"
      when: pressArea.pressed && !root.disabled
      PropertyChanges { target: root; _stackScale: 0.96 }
    }
  ]

  transitions: [
    Transition { from: "*"; to: "focus";   NumberAnimation { target: root; property: "_stackScale"; duration: 140; easing.type: Easing.OutBack } },
    Transition { from: "focus"; to: "idle"; NumberAnimation { target: root; property: "_stackScale"; duration: 120; easing.type: Easing.OutCubic } },
    Transition { from: "*"; to: "pressed";  NumberAnimation { target: root; property: "_stackScale"; duration: 80;  easing.type: Easing.OutCubic } },
    Transition { from: "pressed"; to: "focus"; NumberAnimation { target: root; property: "_stackScale"; duration: 120; easing.type: Easing.OutBack } }
  ]

  /* === Couleur icône animée + signal toggle === */
  onCheckedChanged: {
    if (_quietCheckedSync) {
      tintAnim.stop();
      popAnim.stop();
      burstAnim.stop();
      _iconPulseScale = 1.0;
      _tintProgress = checked ? 1 : 0;
      _emitHint();
      _requestGlyphPaint();
      return;
    }

    tintAnim.to = checked ? 1 : 0; tintAnim.restart();
    if (checked && burstOnCheck) burstAnim.restart();
    if (popOnChange) {
      popAnim.stop();
      _iconPulseScale = 1.0;
      popAnim.restart();
    }
    _emitHint();
    _requestGlyphPaint();
  }

  NumberAnimation { id: tintAnim; target: root; property: "_tintProgress"; duration: animDuration; easing.type: Easing.OutCubic }
  Timer {
    id: tintPaintTimer
    interval: 33
    repeat: true
    running: tintAnim.running
    onTriggered: _requestGlyphPaint()
    onRunningChanged: if (!running) _requestGlyphPaint()
  }

  SequentialAnimation {
    id: popAnim
    running: false
    NumberAnimation { target: root; property: "_iconPulseScale"; from: 1.0; to: 1.12; duration: 110; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "_iconPulseScale"; from: 1.12; to: 1.0; duration: 160; easing.type: Easing.OutBack }
    onStopped: root._iconPulseScale = 1.0
  }

  /* === Repaint glyph quand props changent === */
  onActionTypeChanged: _requestGlyphPaint()
  onIconColorChanged: _requestGlyphPaint()
  onIconColorCheckedChanged: _requestGlyphPaint()
  onGlyphKindChanged: _requestGlyphPaint()

  /* === Hints === */
  onActiveFocusChanged: _emitHint()
  onDisabledChanged: _emitHint()

  Component.onCompleted: {
    _invalidateHintCache();
    _emitHint();
    _applyStateFromGetter();
    _requestGlyphPaint();
  }

  /* === Accessibilité === */
  Accessible.role: Accessible.Button
  Accessible.name: currentHint || (showLabel ? label.text : "Button")
  Accessible.onPressAction: _fireAction("accessibility")
}
