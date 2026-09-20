// components/GlassCircleButtonMovie.qml — QtQuick 2.15 — actions Jellyfin pour un item vidéo.
// Le rendu, le focus, les animations et les hints génériques vivent dans GlassCircleButton.qml.

import QtQuick 2.15
import "." as Components
import "../js/jellyfinBridge.js" as Jellyfin

Components.GlassCircleButton {
  id: root

  /* ===== Cycle de vie / focus mémorisé ===== */
  property bool _disposed: false
  property string focusKey: ""
  readonly property string _autoFocusKey: "GCBM_" + (actionType || "restart")
  objectName: (focusKey && focusKey.length) ? focusKey : _autoFocusKey

  /* ===== Contexte Jellyfin ===== */
  property string serverUrl: ""
  property string accessToken: ""
  property string userId: ""
  property string itemId: ""
  property string itemTitle: ""
  property var userData: null
  property real runTimeTicks: 0

  // Permet à GlassCircleButtonSeason de fournir seasonId/seriesId sans recopier ce socle.
  property string contextFallbackItemId: ""
  readonly property string stateItemId: String(itemId || contextFallbackItemId || "")
  readonly property bool ctxReady: !!serverUrl && !!accessToken && !!userId && !!stateItemId

  /* ===== Action média ===== */
  // GlassCircleButton.triggered est l'unique signal public d'activation.
  // La page propriétaire décide ensuite comment ouvrir le player.
  actionType: "restart"

  /* ===== Réglages visuels propres à la variante Movie ===== */
  iconOversample: 3.0
  property bool perfLow: false
  burstCount: perfLow ? 6 : 8

  /* ===== Resume / UserData ===== */
  property real resumeEndCapRatio: 0.97
  // Aligné sur la cadence de checkpoint PlayerOverlay : ~2,5 s suffisent.
  readonly property real minResumeTicks: 2500 * 10000
  property var __fetchedUserData: null
  property real __fetchedRunTimeTicks: 0
  property bool _udFetchPending: false
  property bool _udResolved: false
  property var _userItemHandle: null
  // Certaines pages (SeasonPage) fournissent déjà UserData avec leur modèle.
  // Dans ce cas le bouton ne doit jamais devenir un client Jellyfin autonome.
  property bool allowFallbackUserDataFetch: true
  property int _userItemFetchSeq: 0

  readonly property var effUserData: userData ? userData : __fetchedUserData
  readonly property real effRunTimeTicks: runTimeTicks > 0 ? runTimeTicks
                                  : (__fetchedRunTimeTicks > 0 ? __fetchedRunTimeTicks : 0)

  function _posTicks(ud) {
    if (!ud) return 0
    var v = (ud.PlaybackPositionTicks !== undefined) ? ud.PlaybackPositionTicks
          : (ud.ResumePositionTicks !== undefined) ? ud.ResumePositionTicks
          : (ud.PositionTicks !== undefined) ? ud.PositionTicks : 0
    v = Number(v || 0)
    return (!isFinite(v) || v < 0) ? 0 : v
  }

  readonly property real _resumeTicks: _posTicks(effUserData)
  readonly property bool _hasResume: {
    var ud = effUserData
    if (!ud || ud.Played) return false
    var pos = _resumeTicks
    var dur = effRunTimeTicks
    return pos >= minResumeTicks && (dur === 0 || pos < dur * resumeEndCapRatio)
  }

  shouldShow: actionType !== "resume" || _hasResume

  function _fmtTicks(t) {
    var ms = Math.floor((Number(t) || 0) / 10000)
    var sec = Math.floor(ms / 1000)
    function p2(x) { return (x < 10 ? "0" : "") + x }
    var hh = Math.floor(sec / 3600)
    var mm = Math.floor((sec % 3600) / 60)
    var ss = sec % 60
    return (hh > 0 ? p2(hh) + ":" : "") + p2(mm) + ":" + p2(ss)
  }

  readonly property string _autoHint: {
    if (actionType === "resume") return _hasResume ? ("Reprendre à " + _fmtTicks(_resumeTicks)) : ""
    if (actionType === "restart" || actionType === "play") return "Lire"
    if (actionType === "toggleSeen") return checked ? "Marquer non vu" : "Marquer vu"
    if (actionType === "toggleLike") return checked ? "Retirer favori" : "Favori"
    return ""
  }
  autoHintText: _autoHint

  function _pullUserDataIntoState() {
    var ud = effUserData
    if (!ud) return
    if (actionType === "toggleSeen") {
      checkable = true
      _setCheckedQuiet(!!ud.Played)
    } else if (actionType === "toggleLike") {
      checkable = true
      _setCheckedQuiet(!!ud.IsFavorite)
    }
  }

  function _cancelUserItemFetch() {
    // Invalide aussi les callbacks qui reviendraient après cancel().
    _userItemFetchSeq += 1
    var h = _userItemHandle
    _userItemHandle = null
    if (!h) return
    try { if (typeof h.cancel === "function") h.cancel("button_context_changed", false) } catch(e) {}
  }

  function _actionNeedsUserData() {
    return actionType === "resume" || actionType === "toggleSeen" || actionType === "toggleLike"
  }

  function _ensureUserDataAvailable() {
    if (_disposed || !_ensureCtx() || _udResolved || _udFetchPending) return

    // restart/play/shuffle n'ont pas besoin de UserData pour être utilisables.
    if (!_actionNeedsUserData()) return

    // UserData suffit aux décisions Resume/Vu/Favori. Une durée à 0 est valide
    // pour un épisode virtuel/non encore disponible et ne justifie JAMAIS un GET.
    // _hasResume sait déjà fonctionner sans durée grâce à son garde dur === 0.
    if (effUserData) {
      _udResolved = true
      _pullUserDataIntoState()
      return
    }

    // SeasonPage et les autres propriétaires de contexte peuvent déclarer leur
    // état autoritaire afin d'éviter toute requête concurrente par bouton.
    if (!allowFallbackUserDataFetch) {
      _udResolved = true
      return
    }

    var requestedId = String(stateItemId || "")
    if (!requestedId) return

    _cancelUserItemFetch()
    var requestSeq = ++_userItemFetchSeq
    _udFetchPending = true
    _userItemHandle = Jellyfin.fetchUserItem(serverUrl, accessToken, userId, requestedId,
      function(obj) {
        if (!root || root._disposed) return
        if (requestSeq !== root._userItemFetchSeq || String(root.stateItemId || "") !== requestedId) return
        root._userItemHandle = null
        root._udFetchPending = false
        if (obj && obj.UserData) root.__fetchedUserData = obj.UserData
        var dur = obj && obj.RunTimeTicks ? Number(obj.RunTimeTicks) || 0 : 0
        if (!root.runTimeTicks && dur > 0) root.__fetchedRunTimeTicks = dur
        // Un seul essai par contexte suffit. Ne jamais boucler parce que la
        // durée serveur vaut légitimement zéro.
        root._udResolved = true
        root._pullUserDataIntoState()
        root._emitHint()
      },
      function() {
        if (!root || root._disposed) return
        if (requestSeq !== root._userItemFetchSeq || String(root.stateItemId || "") !== requestedId) return
        root._userItemHandle = null
        root._udFetchPending = false
        // Évite une boucle de retry automatique sur erreur/404. Un changement
        // d'item réinitialise _udResolved et autorise un nouvel essai.
        root._udResolved = true
      })
  }

  function _adoptContext() {
    var p = root.parent
    var hop = 20
    var touched = false
    while (p && hop-- > 0) {
      if (!serverUrl && p.serverUrl) { serverUrl = p.serverUrl; touched = true }
      if (!accessToken && p.accessToken) { accessToken = p.accessToken; touched = true }
      if (!userId && p.userId) { userId = p.userId; touched = true }
      if (!itemId && p.itemId) { itemId = p.itemId; touched = true }
      if (!itemTitle && p.itemTitle) { itemTitle = p.itemTitle; touched = true }
      if (!userData && p.item && p.item.UserData) { userData = p.item.UserData; touched = true }
      if (!runTimeTicks && p.item && p.item.RunTimeTicks) {
        runTimeTicks = Number(p.item.RunTimeTicks) || 0
        touched = true
      }
      p = p.parent
    }
    if (touched) _pullUserDataIntoState()
  }

  function _ensureCtx() {
    if (ctxReady) return true
    _adoptContext()
    return ctxReady
  }

  function _resetFetchedState() {
    _cancelUserItemFetch()
    _udFetchPending = false
    _udResolved = false
    __fetchedUserData = null
    __fetchedRunTimeTicks = 0
  }

  function _applyToggleLocally(kind, value) {
    var ud = effUserData
    if (!ud) ud = (__fetchedUserData = {})
    if (kind === "seen") ud.Played = !!value
    else if (kind === "fav") ud.IsFavorite = !!value
  }

  function _setPlayedAsync(value) {
    var targetId = stateItemId
    try {
      Jellyfin.setPlayedState(serverUrl, accessToken, userId, targetId, value,
        function(){},
        function() {
          if (!root || root._disposed) return
          root._applyToggleLocally("seen", !value)
          root.checked = !value
          root._emitHint()
        })
    } catch(e) {
      _applyToggleLocally("seen", !value)
      checked = !value
      _emitHint()
    }
  }

  function _setFavoriteAsync(value) {
    var targetId = stateItemId
    try {
      Jellyfin.setFavorite(serverUrl, accessToken, userId, targetId, value,
        function(){},
        function() {
          if (!root || root._disposed) return
          root._applyToggleLocally("fav", !value)
          root.checked = !value
          root._emitHint()
        })
    } catch(e) {
      _applyToggleLocally("fav", !value)
      checked = !value
      _emitHint()
    }
  }

  actionGuard: function(action) {
    if (!root._ensureCtx()) return false
    if (action === "resume" && !root._hasResume) return false
    return true
  }
  onToggleSeen: function(value) {
    root._applyToggleLocally("seen", value)
    root._setPlayedAsync(value)
  }
  onToggleLike: function(value) {
    root._applyToggleLocally("fav", value)
    root._setFavoriteAsync(value)
  }

  onParentChanged: { _invalidateHintCache(); _adoptContext() }
  onUserDataChanged: { _pullUserDataIntoState(); _ensureUserDataAvailable(); _emitHint() }
  onActionTypeChanged: { _pullUserDataIntoState(); _ensureUserDataAvailable(); requestGlyphPaint(); _emitHint() }
  onItemIdChanged: { _resetFetchedState(); _pullUserDataIntoState(); _ensureUserDataAvailable(); _emitHint() }
  onContextFallbackItemIdChanged: { _resetFetchedState(); _ensureUserDataAvailable() }
  onActiveFocusChanged: {
    _emitHint()
  }

  Component.onCompleted: {
    _invalidateHintCache()
    _adoptContext()
    _pullUserDataIntoState()
    _ensureUserDataAvailable()
    _applyStateFromGetter()
    requestGlyphPaint()
    _emitHint()
  }

  Component.onDestruction: {
    _disposed = true
    _cancelUserItemFetch()
  }
}
