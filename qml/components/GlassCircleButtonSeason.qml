// components/GlassCircleButtonSeason.qml — QtQuick 2.15 — actions saison/épisode.
// Hérite du contexte Jellyfin de GlassCircleButtonMovie et du rendu de GlassCircleButton.

import QtQuick 2.15
import "." as Components
import "../js/jellyfinBridge.js" as Jellyfin

Components.GlassCircleButtonMovie {
  id: root

  property string seasonId: ""
  property string seriesId: ""
  property bool shuffleAcrossAllSeasons: false
  property bool preferUnplayedForShuffle: true

  // seasonpage peut fournir un épisode déjà filtré sur les médias réellement présents.
  property var shuffleEpisodeProvider: null
  property bool shuffleFallbackToJellyfinWhenProviderEmpty: true
  property bool shuffleRejectCurrentEpisodePick: true

  // Les épisodes virtuels/manquants ne doivent jamais exposer Lire/Reprendre.
  property var itemData: null
  property bool isMissingOverride: false
  property var _adoptedItemData: null

  // SeasonPage possède le contexte de navigation/player : le bouton lui délègue
  // directement l'ouverture de l'épisode au lieu de maintenir deux API de signaux.

  contextFallbackItemId: seasonId || seriesId
  // SeasonPage charge déjà UserData pour chaque épisode. Laisser chacun des
  // cinq boutons refaire son propre GET provoquait jusqu'à >1000 requêtes
  // créées/annulées pendant un scroll rapide sur Freebox Révolution.
  allowFallbackUserDataFetch: false
  iconOversample: 1.5
  pointerHoverEnabled: false
  fireCooldownMs: 320
  focus: false

  function _strId(v) {
    return (v === undefined || v === null) ? "" : String(v)
  }

  function _targetItemId() {
    return String(itemId || seasonId || "")
  }

  function _sameItemId(obj, id) {
    if (!obj) return false
    return String(obj.Id || obj.ItemId || "") === String(id || "")
  }

  function _isMissingFromObj(obj) {
    if (!obj) return false
    try {
      if (obj.IsMissing === true || obj.Missing === true || obj.IsVirtualItem === true
          || obj.IsPlaceholder === true || obj.IsPlaceHolder === true) return true
      var locationType = String(obj.LocationType || "").toLowerCase()
      return locationType === "virtual" || locationType === "missing" || locationType === "placeholder"
    } catch(e) {}
    return false
  }

  function _refreshItemDataFromParent() {
    var wantedId = _targetItemId()
    if (!wantedId) { _adoptedItemData = null; return }
    var found = null
    var p = root.parent
    var hop = 20
    while (p && hop-- > 0 && !found) {
      try {
        if (p.selectedDetails && _sameItemId(p.selectedDetails, wantedId)) found = p.selectedDetails
        if (!found && p.selectedEpisode && _sameItemId(p.selectedEpisode, wantedId)) found = p.selectedEpisode
        if (!found && p.itemData && _sameItemId(p.itemData, wantedId)) found = p.itemData
        if (!found && p.item && _sameItemId(p.item, wantedId)) found = p.item
      } catch(e) {}
      p = p.parent
    }
    _adoptedItemData = found
  }

  readonly property var effectiveItemData: {
    var wantedId = _targetItemId()
    if (!wantedId) return itemData ? itemData : _adoptedItemData
    if (itemData && _sameItemId(itemData, wantedId)) return itemData
    if (_adoptedItemData && _sameItemId(_adoptedItemData, wantedId)) return _adoptedItemData
    return null
  }

  readonly property bool isMissingItem: isMissingOverride || _isMissingFromObj(effectiveItemData)

  shouldShow: {
    if ((actionType === "restart" || actionType === "resume") && isMissingItem) return false
    return actionType !== "resume" || _hasResume
  }

  readonly property string _seasonAutoHint: {
    if ((actionType === "restart" || actionType === "resume") && isMissingItem) return ""
    if (actionType === "resume") return _hasResume ? ("Reprendre à " + _fmtTicks(_resumeTicks)) : ""
    if (actionType === "restart") return "Lire"
    if (actionType === "toggleSeen") return checked ? "Marquer non vu" : "Marquer vu"
    if (actionType === "toggleLike") return checked ? "Retirer favori" : "Favori"
    if (actionType === "shuffle") return "Lire aléatoirement"
    return ""
  }
  autoHintText: _seasonAutoHint

  function _adoptSeasonContext() {
    var p = root.parent
    var hop = 20
    while (p && hop-- > 0) {
      try {
        if (!seasonId && (p.selectedSeasonId || p.seasonId)) seasonId = p.selectedSeasonId || p.seasonId
        if (!seriesId && (p.seriesId || (p.item && p.item.SeriesId)))
          seriesId = p.seriesId || (p.item && p.item.SeriesId) || ""
      } catch(e) {}
      p = p.parent
    }
    if (!seasonId && itemId) seasonId = itemId
    _refreshItemDataFromParent()
  }

  function _findPlayHandler() {
    var p = root.parent
    var hop = 20
    while (p && hop-- > 0) {
      if (typeof p.requestPlayAt === "function" || typeof p.requestPlay === "function") return p
      p = p.parent
    }
    return null
  }

  function _resetResumePosition(done) {
    if (!_ensureCtx()) { if (done) done(); return }
    var targetId = stateItemId
    Jellyfin.updateUserPlaybackPosition(serverUrl, accessToken, userId, targetId, 0,
      function() { if (done) done() },
      function() { if (done) done() })
  }

  function _dispatchPlay(startTicks, playId, title, explicitSource) {
    var handler = _findPlayHandler()
    if (!handler) return false
    playId = playId || stateItemId
    title = title || itemTitle
    if (!playId) return false

    // Seul « Lire depuis le début » exige une cible explicite à 0.
    // « Reprendre » conserve le chemin requestPlay historique afin de laisser
    // Jellyfin/PlayerOverlay appliquer exactement la reprise déjà en place.
    if (explicitSource && typeof handler.requestPlayAt === "function") {
      handler.requestPlayAt(playId, accessToken, userId, serverUrl, title,
                            Math.floor((Number(startTicks) || 0) / 10000),
                            String(explicitSource))
      return true
    }
    if (typeof handler.requestPlay === "function") {
      handler.requestPlay(playId, accessToken, userId, serverUrl, title)
      return true
    }
    if (typeof handler.requestPlayAt === "function") {
      handler.requestPlayAt(playId, accessToken, userId, serverUrl, title,
                            Math.floor((Number(startTicks) || 0) / 10000),
                            String(explicitSource || "chapter"))
      return true
    }
    return false
  }

  function _startSeasonPlayback(mode, startTicks, playId, title) {
    playId = playId || stateItemId
    title = title || itemTitle
    if (!playId) return

    function go() {
      root._dispatchPlay(startTicks, playId, title, mode === "restart" ? "restart" : "")
    }

    if (mode === "restart" && _resumeTicks > minResumeTicks) _resetResumePosition(go)
    else go()
  }

  function _looksLikeEpisode(obj) {
    if (!obj) return false
    var type = String(obj.Type || obj.MediaType || "").toLowerCase()
    if (type === "episode") return true
    return !!(obj.SeasonId || obj.SeriesId || obj.IndexNumber || obj.ParentIndexNumber)
           && type !== "season" && type !== "series"
  }

  function _findSeasonIdInParents() {
    var p = root.parent
    var hop = 24
    while (p && hop-- > 0) {
      try {
        if (p.selectedSeasonId) return _strId(p.selectedSeasonId)
        if (p.currentSeasonId) return _strId(p.currentSeasonId)
        if (p.seasonItemId) return _strId(p.seasonItemId)
        if (p.seasonId) return _strId(p.seasonId)
        if (p.selectedEpisode && p.selectedEpisode.SeasonId) return _strId(p.selectedEpisode.SeasonId)
        if (p.currentEpisode && p.currentEpisode.SeasonId) return _strId(p.currentEpisode.SeasonId)
        if (p.item && String(p.item.Type || "").toLowerCase() === "season" && p.item.Id)
          return _strId(p.item.Id)
      } catch(e) {}
      p = p.parent
    }
    return ""
  }

  function _parentForShuffle() {
    if (shuffleAcrossAllSeasons) {
      try { return seriesId || (root.parent && root.parent.seriesId) || "" } catch(e0) {}
      return seriesId || ""
    }
    var data = effectiveItemData || itemData || _adoptedItemData
    if (data && data.SeasonId) return _strId(data.SeasonId)
    var parentSeason = _findSeasonIdInParents()
    if (parentSeason) return parentSeason
    if (seasonId && (!_looksLikeEpisode(data) || _strId(seasonId) !== _strId(itemId)))
      return _strId(seasonId)
    return _strId(seasonId || itemId || "")
  }

  property bool _shufflePending: false
  property var _shuffleHandle: null

  function _cancelShuffle() {
    var h = _shuffleHandle
    _shuffleHandle = null
    if (h) {
      try { if (typeof h.cancel === "function") h.cancel("shuffle_cancelled", false) } catch(e) {}
    }
    _shufflePending = false
  }

  function _playRandomEpisode() {
    if (_shufflePending || !_ensureCtx()) return
    _shufflePending = true

    function release() {
      root._shuffleHandle = null
      root._shufflePending = false
    }
    function playEpisode(ep, fallbackTitle) {
      var episodeId = ep && (ep.Id || ep.ItemId)
      if (!episodeId) { release(); return }
      episodeId = root._strId(episodeId)
      var title = ep.Name || fallbackTitle || root.itemTitle || "Lecture aléatoire"
      root._dispatchPlay(0, episodeId, title)
      release()
    }

    var parentId = _parentForShuffle()
    if (shuffleEpisodeProvider && typeof shuffleEpisodeProvider === "function") {
      var picked = null
      try { picked = shuffleEpisodeProvider(preferUnplayedForShuffle) } catch(e) {}
      var pickedId = picked && (picked.Id || picked.ItemId)
      if (shuffleRejectCurrentEpisodePick && pickedId
          && _strId(pickedId) === _strId(itemId)
          && parentId && _strId(parentId) !== _strId(pickedId)) {
        picked = null
        pickedId = ""
      }
      if (pickedId) { playEpisode(picked, "Lecture aléatoire"); return }
      if (!shuffleFallbackToJellyfinWhenProviderEmpty) { release(); return }
    }

    if (!parentId) { release(); return }
    _shuffleHandle = Jellyfin.fetchRandomEpisode(serverUrl, accessToken, userId, parentId,
      preferUnplayedForShuffle,
      function(ep) { playEpisode(ep, "Lecture aléatoire") },
      function() { release() })
  }

  actionGuard: function(action) {
    if (!root._ensureCtx()) return false
    if ((action === "restart" || action === "resume") && root.isMissingItem) return false
    if (action === "resume" && !root._hasResume) return false
    return true
  }
  onPlay: function(action) {
    root._startSeasonPlayback(action === "resume" ? "resume" : "restart",
                              action === "resume" ? root._resumeTicks : 0,
                              root.stateItemId, root.itemTitle)
  }
  onShuffle: function() { root._playRandomEpisode() }

  onItemDataChanged: { _refreshItemDataFromParent(); _emitHint() }
  onIsMissingOverrideChanged: _emitHint()
  onSeasonIdChanged: { _adoptSeasonContext(); _emitHint() }
  onSeriesIdChanged: _emitHint()

  Component.onCompleted: {
    _invalidateHintCache()
    _adoptContext()
    _adoptSeasonContext()
    _refreshItemDataFromParent()
    _pullUserDataIntoState()
    _ensureUserDataAvailable()
    _applyStateFromGetter()
    requestGlyphPaint()
    _emitHint()
  }

  Component.onDestruction: {
    _disposed = true
    _cancelUserItemFetch()
    _cancelShuffle()
  }
}
