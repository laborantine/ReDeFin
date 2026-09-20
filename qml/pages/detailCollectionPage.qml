import QtQuick 2.15
import QtGraphicalEffects 1.15
import "." as Pages
import "../components" as Components
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/MediaCatalog.js" as MediaCatalog
import "../js/SafeLog.js" as SafeLog
FocusScope {
    id: detailCollectionPage
    width: 1280
    height: 720
    focus: true
    property string accessToken
    property string userId
    property string serverUrl
    property string boxSetId
    property string userName
    property string userImageTag
    property var    fbx
    property var    shared: null
    property string returnFolderId
    property int    returnIndex: -1
    property int    returnY: -1
    /* Présentation collection : calculs purs centralisés dans MediaCatalog. */
    function _collectionBgUrlFor(it, fillW, fillH, blur, quality) {
        if (!it) return ""
        return Jellyfin.itemBackdropOrPrimaryUrl(serverUrl, it, {
            fillWidth: MediaCatalog.positiveIntOr(fillW, 1280),
            fillHeight: MediaCatalog.positiveIntOr(fillH, 720),
            quality: MediaCatalog.positiveIntOr(quality, 85),
            blur: MediaCatalog.clampBlur(blur || 8)
        })
    }
    function _collectionPosterThumbUrl(it, reqW, reqH, quality) {
        if (!it || !it.Id || !serverUrl) return ""
        var tags = it.ImageTags || {}
        var W = MediaCatalog.positiveIntOr(reqW, 240)
        var H = MediaCatalog.positiveIntOr(reqH, 360)
        var Q = MediaCatalog.positiveIntOr(quality, 85)
        if (tags.Primary) {
            return Jellyfin.itemImageUrl(serverUrl, it.Id, "Primary", tags.Primary, {
                fillWidth: W, fillHeight: H, quality: Q
            })
        }
        if (tags.Thumb) {
            // Un Thumb peut être horizontal. Le demander en fit évite de le
            // transformer en gros crop portrait dans les rails de CollectionPage.
            return Jellyfin.itemImageUrl(serverUrl, it.Id, "Thumb", tags.Thumb, {
                maxWidth: W, maxHeight: H, quality: Q
            })
        }
        return ""
    }
    function _collectionHeroLogoUrl(it, maxW, maxH, quality) {
        return MediaCatalog.collectionLogoImageUrl(Jellyfin, serverUrl, it, {
            maxHeight: Math.max(0, Number(maxH) | 0),
            maxWidth: Math.max(0, Number(maxW) | 0),
            quality: MediaCatalog.positiveIntOr(quality, 90)
        })
    }
    function _collectionHeroCoverUrl(it, fillW, fillH, quality) {
        return MediaCatalog.collectionPrimaryImageUrl(Jellyfin, serverUrl, it, {
            fillWidth: MediaCatalog.positiveIntOr(fillW, 360),
            fillHeight: MediaCatalog.positiveIntOr(fillH, 540),
            quality: MediaCatalog.positiveIntOr(quality, 85)
        })
    }
    property bool disposed: false
    function _setPropSafe(obj, propName, value){ if (!obj) return; try { if (propName in obj) obj[propName] = value } catch(e) {} }
    readonly property string effectiveBoxSetId: boxSetId || ""
    onBoxSetIdChanged: _ctxChanged()
    readonly property bool flickBusy: (rootFlick && (rootFlick.moving || rootFlick.dragging))
    readonly property color glassFocus     : "#1AFFFFFF"
    readonly property color glassBorder    : "#33FFFFFF"
    readonly property color glassBorderDim : "#18FFFFFF"
    property var item: null
    readonly property bool hasItem: !!item
    property var _warmDetailSnapshot: null
    property bool warmSnapshotVisible: false
    function applyDetailSnapshot(snapshot){
        try {
            if (!MediaCatalog.detailSnapshotCanApply(snapshot, effectiveBoxSetId)) return false
            _warmDetailSnapshot = snapshot
            return _useWarmDetailSnapshot()
        } catch(e) {}
        return false
    }
    function _useWarmDetailSnapshot(){
        var snap = _warmDetailSnapshot
        if (!snap || !snap.item || String(snap.itemId || "") !== String(effectiveBoxSetId || "")) {
            warmSnapshotVisible = false
            return false
        }
        item = snap.item
        warmSnapshotVisible = true
        loadingError = ""
        _resetLogoState()
        _itemFetchedOnce = true
        _startHeroPreload()
        scheduleEndLoading()
        _releaseExtendedGates()
        return true
    }
    property int marginL: 40
    property int marginR: 40
    property int contentTopGap: 72
    property int sectionsSpacing: 8
    // Les rails doivent pouvoir afficher simultanément leur titre et le halo
    // complet du poster focalisé sous le hero épinglé.
    property int sectionHeaderDropY: 6
    property int sectionListGap: 6
    property int sectionBottomPad: 2
    property int headerTopNudgeY: -12
    property int titleCharLimit: 45
    property int titleFontPx: 38
    property real titleMarqueeSpeedPxPerSec: 56
    property int titleMarqueePauseStartMs: 750
    property int titleMarqueePauseEndMs: 520
    property int overviewMinH: 190
    property int overviewTopShift: -5
    property int overviewMaxLines: 7
    property int posterW: 230
    property int posterH: 330
    property int posterEdgeGap: 20
    // Position absolue dans le viewport du hero épinglé : l'avatar ClockHUD
    // finit vers y=68, donc l'art démarre un peu plus bas avec 24 px d'air.
    property int posterViewportTop: 92
    property int seriesSectionNudgeY: 0     // FIX PINNED HERO: ne plus remonter les rails sous le résumé
    property int filmsSectionNudgeY:  0     // FIX PINNED HERO: ne plus remonter les rails sous le résumé
    property int bottomScrollPad: pinDynamicHero ? Math.max(380, pinnedHeroReserveH + 24) : 64
    property bool pinDynamicHero: true
    readonly property real pinnedHeroCounterY: (pinDynamicHero && rootFlick) ? rootFlick.contentY : 0
    // Bas du hero : poster à y=92, hauteur 330, puis quelques pixels pour
    // absorber son scale 1.02. Les rails commencent sous cette limite.
    readonly property int pinnedHeroReserveH: posterViewportTop + posterH + 4
    function safeRowHeight(){
        // Garantit que la première section réelle débute sous le hero, sans que
        // le masque vertical n'attaque son titre. headerBlock est indépendant de
        // rowBlock, donc cette liaison n'introduit pas de boucle géométrique.
        var hh = 0
        try { hh = headerBlock ? Math.max(0, Number(headerBlock.implicitHeight || headerBlock.height || 0)) : 0 } catch(e) { hh = 0 }
        var minForPinned = pinnedHeroReserveH - contentTopGap - hh - (sectionsSpacing * 2)
        return Math.max(overviewMinH + 24, Math.ceil(minForPinned))
    }
    readonly property real frameRadiusRatio: 0.06
    readonly property real frameWidth: 2.0
    readonly property real frameInsetPx: 0.0
    readonly property real frameInnerEpsilon: 0.2
    function frameMargin(){ return frameInsetPx + frameWidth/2 + frameInnerEpsilon }
    function railFocusTopPad(cardHeight, scaleValue, liftValue) {
        // Un scale centré agrandit de moitié vers le haut et de moitié vers le
        // bas. Réserver l'agrandissement total gaspillait inutilement la hauteur.
        var halfGrow = Math.max(0, cardHeight * (scaleValue - 1) * 0.5)
        return Math.ceil(halfGrow) + Math.max(0, liftValue|0) + Math.ceil(frameWidth) + 2
    }
    readonly property int avatarSize: 48
    function _anyCarouselMoving(){
        var sm = (seriesList && (seriesList.moving || seriesList.flicking)) ? true : false; var fm = (filmsList  && (filmsList.moving  || filmsList.flicking )) ? true : false
        return sm || fm
    }
    property real posterImgOversample: 1.35  // Hero : marge qualité supérieure, coût borné à un seul grand visuel
    property int  posterFetchW: Math.max(1, Math.round(posterW * posterImgOversample))
    property int  posterFetchH: Math.max(1, Math.round(posterH * posterImgOversample))
    readonly property bool hasCollectionLogo: hasItem && MediaCatalog.hasLogoImage(item)
    readonly property bool hasCollectionCover: hasItem && MediaCatalog.hasPrimaryImage(item)
    readonly property bool hasCollectionArt: hasItem && MediaCatalog.hasLogoOrPrimaryImage(item)
    property string collectionLogoUrl: _collectionHeroLogoUrl(item, posterFetchW, posterFetchH, 85)
    property string collectionCoverUrl: _collectionHeroCoverUrl(item, posterFetchW, posterFetchH, 88)
    readonly property real heroPosterHqOversample: 1.60
    readonly property int heroPosterHqQuality: 92
    readonly property string collectionCoverHqUrl: _collectionHeroCoverUrl(item,
        Math.round(posterW * heroPosterHqOversample), Math.round(posterH * heroPosterHqOversample), heroPosterHqQuality)
    property bool heroPosterHqArmed: false
    readonly property real railPosterHqOversample: 1.55
    readonly property int railPosterHqQuality: 92
    property string railPosterHqTargetId: ""
    property string _railPosterHqPendingId: ""
    property string _hqPendingKind: ""
    property string overlayMode: "none" // none|poster|overview
    property var overlayData: ({})
    readonly property int overlayPosterMaxW: Math.round(width * 0.92)
    readonly property int overlayPosterMaxH: Math.round(height * 0.92)
    onOverlayModeChanged: {
        if (rootFlick) rootFlick.interactive = (overlayMode === "none") && !visualLoading
        _syncClockHud() // throttled wrapper
    }
    property int bgBlur: 8
    property int bgFillW: 1280
    property int bgFillH: 720
    property real bgDarken: 0.40
    readonly property int stickyBackdropDelayMs: 750
    readonly property int firstBackdropDelayMs: 180
    property var    bgOverrideItem: null
    onBgOverrideItemChanged: _kickBackdropLoad()
    property string _bgOverrideId: ""
    property var    _bgPendingItem: null
    // P1 Freebox : double-buffer de backdrop dynamique.
    // L'ancien fond reste affiché tant que le nouveau n'est pas Image.Ready.
    property bool   _bgFrontA: true
    property string _bgUrlA: ""
    property string _bgUrlB: ""
    property string _bgRequestedUrl: ""
    property string _bgPromotedUrl: ""
    readonly property string activeBackdropSource: _bgFrontA ? _bgUrlA : _bgUrlB
    readonly property bool   activeBackdropVisible: activeBackdropSource.length > 0
    function _activeBackdropImage(){
        try { return _bgFrontA ? blurredBGA : blurredBGB } catch(e) { return null }
    }
    function _pendingBackdropImage(){
        try { return _bgFrontA ? blurredBGB : blurredBGA } catch(e) { return null }
    }
    function _activeBackdropReady(){ var img = _activeBackdropImage(); return !!(img && img.status === Image.Ready && ("" + img.source).length); }
    function _backdropGateDone(){
        if (!bgPreReady) return false
        if (!_bgRequestedUrl || !_bgRequestedUrl.length) return true
        if (_bgPromotedUrl === _bgRequestedUrl) return true
        return _imgDone(_pendingBackdropImage())
    }
    function _clearBackdropBuffers(){
        _bgFrontA = true
        _bgUrlA = ""
        _bgUrlB = ""
        _bgRequestedUrl = ""
        _bgPromotedUrl = ""
    }
    function _backdropUrlForCurrent(){
        if (!bgPreReady || !item) return ""
        var u = _collectionBgUrlFor(bgOverrideItem, bgFillW, bgFillH, bgBlur, 85)
        if (u && u.length) return u
        return _collectionBgUrlFor(item, bgFillW, bgFillH, bgBlur, 85)
    }
    function _promoteCachedPendingBackdrop(u){
        if (!u || !u.length) return false
        var img = _pendingBackdropImage()
        if (!img) return false
        var src = ""
        try {
            src = (img.source !== undefined && img.source !== null)
                    ? ("" + img.source) : ""
        } catch(e) { src = "" }
        if (src !== u || img.status !== Image.Ready) return false

        // A -> B -> A : l'ancien A est encore prêt dans le buffer inactif.
        // Réassigner la même URL n'émet aucun signal Image sous Qt 5.15.
        // On repromeut donc directement ce buffer sans nouveau téléchargement.
        _bgFrontA = !_bgFrontA
        _bgPromotedUrl = u
        _updateHeroGate()
        return true
    }
    function _kickBackdropLoad(){
        var u = _backdropUrlForCurrent()
        if (!u || !u.length) {
            _bgRequestedUrl = ""
            if (!_bgPromotedUrl.length) _updateHeroGate()
            return
        }
        if (u === _bgPromotedUrl) {
            _bgRequestedUrl = u
            _updateHeroGate()
            return
        }

        _bgRequestedUrl = u

        // Important pour la navigation inverse d'un rail : le fond précédent
        // peut déjà être Ready dans le buffer arrière. Dans ce cas aucun
        // onSourceChanged/onStatusChanged ne sera émis par une même URL.
        if (_promoteCachedPendingBackdrop(u))
            return

        // Si ce même buffer charge déjà l'URL demandée, ne pas le perturber :
        // son prochain onStatusChanged assurera la promotion.
        var pending = _pendingBackdropImage()
        var pendingSource = ""
        try {
            pendingSource = (pending && pending.source !== undefined
                             && pending.source !== null)
                    ? ("" + pending.source) : ""
        } catch(e2) { pendingSource = "" }
        if (pendingSource === u) {
            _updateHeroGate()
            return
        }

        if (_bgFrontA) _bgUrlB = u
        else _bgUrlA = u
    }
    function _onBackdropImageChanged(img, isA){
        if (!img) return
        var s = ""
        try { s = (img.source !== undefined && img.source !== null) ? ("" + img.source) : "" } catch(e) { s = "" }
        if (s.length && img.status === Image.Ready && s === _bgRequestedUrl) {
            _bgFrontA = (isA === true)
            _bgPromotedUrl = s
        }
        _updateHeroGate()
    }
    Timer {
        id: bgSwapTimer
        interval: stickyBackdropDelayMs
        repeat: false
        onTriggered: {
            if (detailCollectionPage.disposed || !detailCollectionPage.visible) return
            if (detailCollectionPage._anyCarouselMoving()) {
                bgSwapTimer.interval = stickyBackdropDelayMs
                restart()
                return
            }
            var it = detailCollectionPage._bgPendingItem; var id = (it && it.Id) ? (""+it.Id) : ""
            if (id === detailCollectionPage._bgOverrideId) return
            detailCollectionPage._bgOverrideId = id
            detailCollectionPage.bgOverrideItem = it
        }
    }
    function _requestBgOverride(it){
        _bgPendingItem = it
        var hasStableBg = _activeBackdropReady()
        bgSwapTimer.interval = (!hasStableBg && !detailCollectionPage._anyCarouselMoving()) ? firstBackdropDelayMs : stickyBackdropDelayMs
        bgSwapTimer.restart()
    }
    function _scheduleHeroPosterHq(){
        hqPromotionTimer.stop()
        heroPosterHqArmed = false
        railPosterHqTargetId = ""
        _railPosterHqPendingId = effectiveBoxSetId ? String(effectiveBoxSetId) : ""
        _hqPendingKind = "hero"
        if (_railPosterHqPendingId.length && posterFocus && posterFocus.activeFocus
                && artStage === "poster" && artImage && artImage.status === Image.Ready && !flickBusy)
            hqPromotionTimer.restart()
    }
    function _clearHeroPosterHq(){
        if (_hqPendingKind === "hero") {
            hqPromotionTimer.stop()
            _hqPendingKind = ""
            _railPosterHqPendingId = ""
        }
        heroPosterHqArmed = false
    }
    function _clearRailPosterHq(){
        if (_hqPendingKind === "rail") {
            hqPromotionTimer.stop()
            _hqPendingKind = ""
            _railPosterHqPendingId = ""
        }
        railPosterHqTargetId = ""
    }
    function _scheduleRailPosterHq(it){
        var id = (it && it.Id) ? String(it.Id) : ""
        if (!id.length) {
            _clearRailPosterHq()
            return
        }
        hqPromotionTimer.stop()
        heroPosterHqArmed = false
        railPosterHqTargetId = ""
        _railPosterHqPendingId = id
        _hqPendingKind = "rail"
        if ((currentFocus === 3 || currentFocus === 4) && !_anyCarouselMoving())
            hqPromotionTimer.restart()
    }
    Timer {
        id: hqPromotionTimer
        interval: 300
        repeat: false
        onTriggered: {
            if (detailCollectionPage._hqPendingKind === "hero") {
                if (posterFocus && posterFocus.activeFocus && artStage === "poster"
                        && artImage && artImage.status === Image.Ready && !detailCollectionPage.flickBusy)
                    detailCollectionPage.heroPosterHqArmed = true
                return
            }
            if (detailCollectionPage._hqPendingKind === "rail") {
                if (detailCollectionPage._anyCarouselMoving()) return
                var it = detailCollectionPage._focusedChild()
                var id = (it && it.Id) ? String(it.Id) : ""
                if (id.length && id === detailCollectionPage._railPosterHqPendingId)
                    detailCollectionPage.railPosterHqTargetId = id
            }
        }
    }

    signal requestNavigation(string page)
    signal requestBackToMenu()
    function _sharedNavApi(){ try { return shared && shared.__redefinNavApi ? shared.__redefinNavApi : null } catch(e) { return null } }
    function _hydrateSensitiveContextFromShared(){
        var api = _sharedNavApi()
        return api && api.hydrate ? api.hydrate(detailCollectionPage, false, 0, false) : false
    }
    function _storeSensitiveNavContext(){
        var api = _sharedNavApi()
        return api && api.storeTarget ? api.storeTarget(detailCollectionPage) : false
    }
    function _navRoute(page, params){
        var api = _sharedNavApi()
        return api && api.route ? api.route(detailCollectionPage, page, params || ({})) : (page + "?ctx=1")
    }
    function _goBack(){
        if (returnFolderId && returnFolderId.length && typeof requestNavigation === "function") {
            requestNavigation(_navRoute("moviepage.qml", {
                folderId: returnFolderId, libraryMode: "collections",
                restoreIndex: returnIndex, restoreY: returnY
            }))
        } else if (typeof requestBackToMenu === "function") {
            _storeSensitiveNavContext()
            requestBackToMenu()
        }
    }
    property int currentFocus: 0

    // Armement explicite du premier zoom lors de l'entrée dans un rail.
    // Ne pas dépendre uniquement des bindings currentFocus/activeFocus : sur
    // Qt 5.15 leur propagation peut arriver dans le même cycle que le passage
    // de LibraryPosterCard à l'état focused, ce qui ferait démarrer la
    // transition avec allowAnims=false et donc une durée de 0 ms.
    property int _railEntryAnimFocus: 0
    property bool _railEntryAnimArmed: false
    function _armRailEntryAnimation(focusValue) {
        _railEntryAnimFocus = focusValue
        _railEntryAnimArmed = true
        railEntryAnimDisarmTimer.restart()
    }
    property var filmsAll: []
    property var seriesAll: []
    property int itemsWarmCount: 16
    property var filmsWarm: []
    property bool filmsExpanded: false
    property var seriesWarm: []
    property bool seriesExpanded: false
    property bool itemsLoading: false
    function _applyWarmBuckets(){
        var keepSeriesExpanded = (seriesExpanded === true); var keepFilmsExpanded = (filmsExpanded === true)
        seriesExpanded = keepSeriesExpanded || (!seriesAll || seriesAll.length <= itemsWarmCount)
        seriesWarm = seriesExpanded ? (seriesAll || []) : seriesAll.slice(0, itemsWarmCount)
        filmsExpanded = keepFilmsExpanded || (!filmsAll || filmsAll.length <= itemsWarmCount)
        filmsWarm = filmsExpanded ? (filmsAll || []) : filmsAll.slice(0, itemsWarmCount)
    }
    function _expandFilmsIfNeeded(){
        if (!filmsAll || filmsAll.length === 0 || filmsExpanded) return
        filmsExpanded = true
        filmsWarm = filmsAll
    }
    property int  collectionChildrenPageSize: 160
    readonly property int collectionChildrenWindowMaxItems: 640
    readonly property int collectionChildrenPrefetchThreshold: 8
    property int  _childrenSeq: 0
    property int  _childrenAttemptSeq: 0
    property int  _childrenPendingAttemptSeq: 0
    property int  _childrenPendingFetchSeq: 0
    property int  _childrenPendingChildrenSeq: 0
    property string _childrenPendingFolderId: ""
    property int  _childrenPendingStart: 0
    property int  _childrenPendingMode: 0
    property int  _childrenPendingLimit: 160
    property string _childrenPendingDirection: "forward"
    property string _childrenPendingRailKind: ""
    property int  _collectionChildrenActivePageSize: 160
    property var  _collectionChildrenPages: []
    property var  _collectionChildrenHandle: null
    property double _collectionChildrenDeadlineAt: 0
    property var  _collectionChildrenSeen: ({})
    property bool collectionChildrenLoadingMore: false
    property bool collectionChildrenHasMoreBefore: false
    property bool collectionChildrenHasMoreAfter: false
    // 0: enfants directs, 1: récursif, 2: direct sans collapse BoxSet, 3: récursif sans collapse.
    readonly property int collectionChildrenMaxMode: 3
    Timer {
        id: collectionChildrenTimeoutTimer
        interval: 5200
        repeat: false
        onTriggered: detailCollectionPage._onCollectionChildrenTimeout()
    }
    function _resetCollectionChildrenPaging(){
        _cancelCollectionChildrenRequest()
        _childrenSeq++
        _childrenAttemptSeq++
        _childrenPendingFolderId = ""
        _childrenPendingStart = 0
        _childrenPendingMode = 0
        _childrenPendingLimit = collectionChildrenPageSize
        _childrenPendingDirection = "forward"
        _childrenPendingRailKind = ""
        _collectionChildrenActivePageSize = Math.max(40, collectionChildrenPageSize | 0)
        _collectionChildrenPages = []
        _collectionChildrenDeadlineAt = 0
        _collectionChildrenSeen = ({})
        collectionChildrenLoadingMore = false
        collectionChildrenHasMoreBefore = false
        collectionChildrenHasMoreAfter = false
    }
    function _cancelCollectionChildrenRequest(){
        collectionChildrenTimeoutTimer.stop()
        var h = _collectionChildrenHandle
        _collectionChildrenHandle = null
        try { if (h && h.cancel) h.cancel("context_changed") } catch(e) {}
    }
    function _collectionRailSelectedId(list, data){
        try {
            var idx = list ? (list.currentIndex | 0) : -1
            return (data && idx >= 0 && idx < data.length && data[idx] && data[idx].Id) ? String(data[idx].Id) : ""
        } catch(e) { return "" }
    }
    function _collectionRebuildRails(){
        var oldSeriesId = _collectionRailSelectedId(seriesList, seriesWarm); var oldFilmId = _collectionRailSelectedId(filmsList, filmsWarm)
        var rails = MediaCatalog.collectionRailsFromPages(_collectionChildrenPages)
        // SortBy=SortName est appliqué par Jellyfin avant pagination : ne pas
        // retrier les centaines de DTO à chaque page/focus.
        _collectionChildrenSeen = rails.seen
        seriesAll = rails.series
        filmsAll = rails.films
        _applyWarmBuckets()
        Qt.callLater(function(){
            if (disposed) return
            var si = MediaCatalog.findItemIndexById(seriesWarm, oldSeriesId); var fi = MediaCatalog.findItemIndexById(filmsWarm, oldFilmId)
            if (si >= 0 && seriesList) seriesList.currentIndex = si
            if (fi >= 0 && filmsList) filmsList.currentIndex = fi
        })
    }
    function _appendCollectionChildrenPage(arr, pageStart, limit, direction){
        var windowState = MediaCatalog.appendCatalogPageWindow(
                    _collectionChildrenPages, arr || [], pageStart, limit,
                    direction, collectionChildrenWindowMaxItems)
        _collectionChildrenPages = windowState.pages
        collectionChildrenHasMoreBefore = windowState.hasMoreBefore
        collectionChildrenHasMoreAfter = windowState.hasMoreAfter
        _collectionRebuildRails()
    }
    function _collectionCountLabel(data){
        var n = data ? data.length : 0
        return n > 0 ? ("(" + n + ((collectionChildrenHasMoreBefore || collectionChildrenHasMoreAfter) ? "+" : "") + ")") : ""
    }
    function _requestCollectionWindow(direction, railKind){
        if (disposed || _collectionChildrenHandle || collectionChildrenLoadingMore) return false
        var pages = _collectionChildrenPages || []
        if (!pages.length) return false
        var start = 0, limit = Math.max(40, _collectionChildrenActivePageSize | 0)
        if (direction === "backward") {
            if (!collectionChildrenHasMoreBefore) return false
            var first = MediaCatalog.catalogPageWindowStart(_collectionChildrenPages)
            start = Math.max(0, first - limit)
            limit = Math.max(40, first - start)
        } else {
            if (!collectionChildrenHasMoreAfter) return false
            start = MediaCatalog.catalogPageWindowEnd(_collectionChildrenPages)
        }
        _collectionChildrenDeadlineAt = Date.now() + 14000
        _fetchCollectionChildrenPage(_fetchSeq, _childrenSeq, effectiveBoxSetId, start,
                                     _childrenPendingMode, limit, direction, railKind || "", 0)
        return true
    }
    function _maybeRequestCollectionMore(kind, index, count){
        if (count <= 0 || index < 0) return
        if (collectionChildrenHasMoreBefore && index <= 1) {
            _requestCollectionWindow("backward", kind)
            return
        }
        if (collectionChildrenHasMoreAfter && index >= Math.max(0, count - collectionChildrenPrefetchThreshold))
            _requestCollectionWindow("forward", kind)
    }
    function _finishCollectionChildrenLoad(){
        collectionChildrenLoadingMore = false
        itemsLoading = false
        Qt.callLater(function(){
            if (disposed) return
            if (seriesList && seriesList.count > 0 && seriesList.currentIndex < 0) seriesList.currentIndex = 0
            if (filmsList  && filmsList.count  > 0 && filmsList.currentIndex  < 0) filmsList.currentIndex  = 0
            _markCollectionItemsLoaded()
        })
    }
    function _tryNextCollectionChildrenMode(fetchSeq, childrenSeq, folderId, mode){
        mode = Math.max(0, mode | 0)
        if (disposed || fetchSeq !== _fetchSeq || childrenSeq !== _childrenSeq) return false
        if (!_collectionChildrenDeadlineAt || Date.now() >= _collectionChildrenDeadlineAt) return false
        if (mode < collectionChildrenMaxMode) {
            _cancelCollectionChildrenRequest()
            ++_childrenAttemptSeq
            _collectionChildrenPages = []
            _collectionChildrenSeen = ({})
            filmsAll = []; seriesAll = []; filmsWarm = []; seriesWarm = []
            filmsExpanded = false; seriesExpanded = false
            collectionChildrenHasMoreBefore = false
            collectionChildrenHasMoreAfter = false
            Qt.callLater(function(){
                detailCollectionPage._fetchCollectionChildrenPage(fetchSeq, childrenSeq, folderId, 0, mode + 1)
            })
            return true
        }
        return false
    }
    function _onCollectionChildrenTimeout(){
        if (disposed) return
        var fetchSeq = _childrenPendingFetchSeq; var childrenSeq = _childrenPendingChildrenSeq; var folderId = _childrenPendingFolderId; var pageStart = _childrenPendingStart | 0; var mode = _childrenPendingMode | 0
        var attemptSeq = _childrenPendingAttemptSeq | 0
        if (!folderId || fetchSeq !== _fetchSeq || childrenSeq !== _childrenSeq || attemptSeq !== _childrenAttemptSeq) return
        _cancelCollectionChildrenRequest()
        ++_childrenAttemptSeq
        if (!_collectionChildrenDeadlineAt || Date.now() >= _collectionChildrenDeadlineAt) {
            if ((filmsAll && filmsAll.length) || (seriesAll && seriesAll.length))
                _finishCollectionChildrenLoad()
            else
                _finishCollectionChildrenLoad()
            return
        }
        if (pageStart === 0 && _tryNextCollectionChildrenMode(fetchSeq, childrenSeq, folderId, mode)) return
        if ((filmsAll && filmsAll.length) || (seriesAll && seriesAll.length)) _finishCollectionChildrenLoad()
        else {
            filmsAll = []; seriesAll = []
            filmsWarm = []; seriesWarm = []
            filmsExpanded = false; seriesExpanded = false
            _finishCollectionChildrenLoad()
        }
    }
    function _fetchCollectionChildrenPage(fetchSeq, childrenSeq, folderId, start, mode, limitOverride, direction, railKind, autoPages){
        if (disposed || fetchSeq !== _fetchSeq || childrenSeq !== _childrenSeq) return
        if (!serverUrl || !accessToken || !userId || !folderId) { _finishCollectionChildrenLoad(); return }
        if (!_collectionChildrenDeadlineAt) _collectionChildrenDeadlineAt = Date.now() + 14000
        var remainingBudget = _collectionChildrenDeadlineAt - Date.now()
        if (remainingBudget <= 0) {
            if ((filmsAll && filmsAll.length) || (seriesAll && seriesAll.length))
                _finishCollectionChildrenLoad()
            else
                _finishCollectionChildrenLoad()
            return
        }
        mode = Math.max(0, mode | 0)
        direction = direction === "backward" ? "backward" : "forward"
        railKind = railKind || ""
        autoPages = Math.max(0, autoPages | 0)
        var limit = Math.max(40, (limitOverride || _collectionChildrenActivePageSize || collectionChildrenPageSize) | 0)
        var pageStart = Math.max(0, start | 0)
        _cancelCollectionChildrenRequest()
        var attemptSeq = ++_childrenAttemptSeq
        _childrenPendingAttemptSeq = attemptSeq
        _childrenPendingFetchSeq = fetchSeq
        _childrenPendingChildrenSeq = childrenSeq
        _childrenPendingFolderId = folderId
        _childrenPendingStart = pageStart
        _childrenPendingMode = mode
        _childrenPendingLimit = limit
        _childrenPendingDirection = direction
        _childrenPendingRailKind = railKind
        collectionChildrenLoadingMore = pageStart > 0
        collectionChildrenTimeoutTimer.interval = Math.max(100, Math.floor(remainingBudget))
        collectionChildrenTimeoutTimer.restart()
        var requestHandle = Jellyfin.fetchCollectionChildrenPage(
            serverUrl, accessToken, userId, folderId, pageStart, limit, mode, _collectionChildrenDeadlineAt,
            function(page){
                if (disposed || fetchSeq !== _fetchSeq || childrenSeq !== _childrenSeq || attemptSeq !== _childrenAttemptSeq) return
                if (_collectionChildrenHandle === requestHandle) _collectionChildrenHandle = null
                collectionChildrenTimeoutTimer.stop()
                var arr = (page && page.items) ? page.items : []
                if (pageStart === 0 && arr.length === 0 && _tryNextCollectionChildrenMode(fetchSeq, childrenSeq, folderId, mode)) return
                var got = arr.length | 0
                var beforeRailCount = railKind === "series" ? seriesAll.length : (railKind === "films" ? filmsAll.length : -1)
                _appendCollectionChildrenPage(arr, pageStart, limit, direction)
                var afterRailCount = railKind === "series" ? seriesAll.length : (railKind === "films" ? filmsAll.length : -1)
                var canContinue = direction === "forward" && got >= limit && railKind.length &&
                                  beforeRailCount === afterRailCount && autoPages < 3
                if (canContinue) {
                    var nextStart = pageStart + got
                    Qt.callLater(function(){
                        detailCollectionPage._fetchCollectionChildrenPage(fetchSeq, childrenSeq, folderId,
                            nextStart, mode, limit, direction, railKind, autoPages + 1)
                    })
                    return
                }
                _finishCollectionChildrenLoad()
            },
            function(err){
                if (disposed || fetchSeq !== _fetchSeq || childrenSeq !== _childrenSeq || attemptSeq !== _childrenAttemptSeq) return
                if (_collectionChildrenHandle === requestHandle) _collectionChildrenHandle = null
                collectionChildrenTimeoutTimer.stop()
                var code = String((err && err.code) ? err.code : (err || "")).toLowerCase()
                if (code === "timeout" || code === "budget_exhausted") {
                    if ((filmsAll && filmsAll.length) || (seriesAll && seriesAll.length))
                        _finishCollectionChildrenLoad()
                    else
                        _finishCollectionChildrenLoad()
                    return
                }
                if (code === "too_large" && limit > 40) {
                    var smaller = limit > 80 ? 80 : 40
                    _collectionChildrenActivePageSize = smaller
                    Qt.callLater(function(){
                        detailCollectionPage._fetchCollectionChildrenPage(fetchSeq, childrenSeq, folderId,
                            pageStart, mode, smaller, direction, railKind, autoPages)
                    })
                    return
                }
                if (pageStart === 0 && _tryNextCollectionChildrenMode(fetchSeq, childrenSeq, folderId, mode)) return
                if ((filmsAll && filmsAll.length) || (seriesAll && seriesAll.length)) _finishCollectionChildrenLoad()
                else {
                    filmsAll = []; seriesAll = []
                    filmsWarm = []; seriesWarm = []
                    filmsExpanded = false; seriesExpanded = false
                    _finishCollectionChildrenLoad()
                }
            }
        )
        _collectionChildrenHandle = requestHandle
        return requestHandle
    }
    function _expandSeriesIfNeeded(){
        if (!seriesAll || seriesAll.length === 0 || seriesExpanded) return
        seriesExpanded = true
        seriesWarm = seriesAll
    }
    property var    detailsCache: ({})
    property var    detailsCacheOrder: []
    property int    detailsCacheMax: 48
    property string selectedDetailsId: ""
    property var    selectedDetails: null
    property bool   selectedDetailsLoading: false
    property int    _detailsSeq: 0
    property var    _detailsHandle: null
    property string _detailsPendingId: ""
    property var    _detailsPendingItem: null
    property int detailsDebounceMs: 280
    property var    seriesTechCache: ({})
    property var    seriesTechCacheOrder: []
    property int    seriesTechCacheMax: 24
    property var    techEpisodeDetails: null
    property bool   techEpisodeLoading: false
    property string _techTargetId: ""
    property int    _techSeq: 0
    property string _techDwellSeriesId: ""
    Timer {
        id: techDwellTimer
        interval: 900
        repeat: false
        onTriggered: {
            if (detailCollectionPage.disposed) return
            if (detailCollectionPage._anyCarouselMoving()) { restart(); return }
            var id = detailCollectionPage._techDwellSeriesId
            if (!id || !id.length) return
            if (!(detailCollectionPage.currentFocus === 3 || detailCollectionPage.currentFocus === 4)) return
            if (detailCollectionPage.selectedDetailsId !== id) return
            detailCollectionPage._ensureSeriesTech(id)
        }
    }
    function _scheduleSeriesTechDwell(seriesId){
        seriesId = seriesId ? (""+seriesId) : ""
        if (!seriesId.length) { _techDwellSeriesId=""; techDwellTimer.stop(); return }
        _techDwellSeriesId = seriesId
        techDwellTimer.restart()
    }
    property string activeDurationExtra: ""
    property var    activeTechChips: []
    Timer {
        id: extrasCoalesceTimer
        interval: 0
        repeat: false
        onTriggered: detailCollectionPage._refreshActiveExtrasNow()
    }
    function _refreshActiveExtras(){ extrasCoalesceTimer.restart(); }
    function _focusedChild(){
        if (currentFocus === 3 && seriesList && seriesWarm && seriesList.currentIndex >= 0 && seriesList.currentIndex < seriesWarm.length)
            return seriesWarm[seriesList.currentIndex]
        if (currentFocus === 4 && filmsList && filmsWarm && filmsList.currentIndex >= 0 && filmsList.currentIndex < filmsWarm.length)
            return filmsWarm[filmsList.currentIndex]
        return null
    }
    function _needsDetails(it){
        return MediaCatalog.collectionDetailsNeedHydration(it)
    }
    function _refreshActiveExtrasNow(){
        if (!(currentFocus === 3 || currentFocus === 4)) {
            activeDurationExtra = ""
            activeTechChips = []
            techEpisodeDetails = null
            techEpisodeLoading = false
            _techTargetId = ""
            _techDwellSeriesId = ""
            techDwellTimer.stop()
            return
        }
        var base = selectedDetails || _focusedChild()
        if (!base) { activeDurationExtra=""; activeTechChips=[]; return }
        var isSeries = MediaCatalog.isSeries(base)
        if (isSeries) {
            var ticks = Number(base.RunTimeTicks || 0)
            if ((!ticks || ticks<=0) && techEpisodeDetails && techEpisodeDetails.RunTimeTicks) ticks = Number(techEpisodeDetails.RunTimeTicks || 0)
            var f = MediaCatalog.formatDurationTicksCompact(ticks)
            activeDurationExtra = f.length ? ("Ép. " + f) : ""
        } else {
            var ticks2 = Number(base.RunTimeTicks || 0)
            var f2 = MediaCatalog.formatDurationTicksCompact(ticks2)
            activeDurationExtra = f2.length ? ("⏱ " + f2) : ""
        }
        var src = null
        if (selectedDetails && selectedDetails.MediaStreams && selectedDetails.MediaStreams.length) src = selectedDetails
        else if (techEpisodeDetails && techEpisodeDetails.MediaStreams && techEpisodeDetails.MediaStreams.length) src = techEpisodeDetails
        else if (base && base.MediaStreams && base.MediaStreams.length) src = base
        activeTechChips = MediaCatalog.collectionTechChips(src, base)
    }
    function _lruTouch(order, id){
        order = order || []
        id = id ? ("" + id) : ""
        if (!id.length) return order
        for (var i = order.length - 1; i >= 0; --i) {
            if (order[i] === id) order.splice(i, 1)
        }
        order.push(id)
        return order
    }
    function _lruTrim(cache, order, maxCount){
        cache = cache || ({})
        order = order || []
        maxCount = Math.max(1, maxCount | 0)
        while (order.length > maxCount) {
            var oldId = order.shift()
            try { if (oldId && cache[oldId]) delete cache[oldId] } catch(e) {}
        }
        return { cache: cache, order: order }
    }
    function _getDetailsCache(id){
        id = id ? ("" + id) : ""
        if (!id.length || !detailsCache || !detailsCache[id]) return null
        detailsCacheOrder = _lruTouch(detailsCacheOrder, id)
        return detailsCache[id]
    }
    function _putDetailsCache(id, value){
        id = id ? ("" + id) : ""
        if (!id.length || !value) return
        var cache = detailsCache || ({})
        cache[id] = MediaCatalog.compactCollectionDetails(value)
        var order = _lruTouch(detailsCacheOrder, id)
        var trimmed = _lruTrim(cache, order, detailsCacheMax)
        detailsCache = trimmed.cache
        detailsCacheOrder = trimmed.order
    }
    function _getSeriesTechCache(id){
        id = id ? ("" + id) : ""
        if (!id.length || !seriesTechCache || !seriesTechCache[id]) return null
        seriesTechCacheOrder = _lruTouch(seriesTechCacheOrder, id)
        return seriesTechCache[id]
    }
    function _putSeriesTechCache(id, value){
        id = id ? ("" + id) : ""
        if (!id.length || !value) return
        var cache = seriesTechCache || ({})
        cache[id] = MediaCatalog.compactCollectionDetails(value)
        var order = _lruTouch(seriesTechCacheOrder, id)
        var trimmed = _lruTrim(cache, order, seriesTechCacheMax)
        seriesTechCache = trimmed.cache
        seriesTechCacheOrder = trimmed.order
    }
    function _ensureSeriesTech(seriesId){
        seriesId = seriesId ? (""+seriesId) : ""
        if (!seriesId.length) return
        var cachedSeriesTech = _getSeriesTechCache(seriesId)
        if (cachedSeriesTech) {
            techEpisodeDetails = cachedSeriesTech
            techEpisodeLoading = false
            _techTargetId = seriesId
            _refreshActiveExtras()
            return
        }
        techEpisodeDetails = null
        techEpisodeLoading = true
        _techTargetId = seriesId
        var seq = ++_techSeq
        Jellyfin.fetchFolderItems(serverUrl, accessToken, userId, seriesId,
            function(children){
                if (disposed || seq !== _techSeq || _techTargetId !== seriesId) return
                var arr = children || []
                var seasons=[]
                for (var i=0;i<arr.length;++i){
                    var it=arr[i]
                    var t=(it && it.Type)?(""+it.Type).toLowerCase():""
                    if (t==="season") seasons.push(it)
                }
                if (!seasons.length) { techEpisodeLoading=false; return }
                try {
                    seasons.sort(function(a,b){
                        var ia = (a && a.IndexNumber!==undefined) ? Number(a.IndexNumber) : 9999
                        var ib = (b && b.IndexNumber!==undefined) ? Number(b.IndexNumber) : 9999
                        if (ia<ib) return -1
                        if (ia>ib) return 1
                        return MediaCatalog.collectionSortAlpha(a,b)
                    })
                } catch(e) {}
                var seasonId = seasons[0].Id
                if (!seasonId) { techEpisodeLoading=false; return }
                Jellyfin.fetchFolderItems(serverUrl, accessToken, userId, seasonId,
                    function(children2){
                        if (disposed || seq !== _techSeq || _techTargetId !== seriesId) return
                        var arr2 = children2 || []
                        var eps=[]
                        for (var j=0;j<arr2.length;++j){
                            var e=arr2[j]
                            var tt=(e && e.Type)?(""+e.Type).toLowerCase():""
                            if (tt==="episode") eps.push(e)
                        }
                        if (!eps.length) { techEpisodeLoading=false; return }
                        try {
                            eps.sort(function(a,b){
                                var ia = (a && a.IndexNumber!==undefined) ? Number(a.IndexNumber) : 9999
                                var ib = (b && b.IndexNumber!==undefined) ? Number(b.IndexNumber) : 9999
                                if (ia<ib) return -1
                                if (ia>ib) return 1
                                return MediaCatalog.collectionSortAlpha(a,b)
                            })
                        } catch(e2) {}
                        var epId = eps[0].Id
                        if (!epId) { techEpisodeLoading=false; return }
                        Jellyfin.fetchUserItemWithPublicFallback(serverUrl, accessToken, userId, epId,
                            function(ep){
                                if (disposed || seq !== _techSeq || _techTargetId !== seriesId) return
                                techEpisodeLoading = false
                                if (ep) {
                                    _putSeriesTechCache(seriesId, ep)
                                    techEpisodeDetails = MediaCatalog.compactCollectionDetails(ep)
                                } else {
                                    techEpisodeDetails = null
                                }
                                _refreshActiveExtras()
                            },
                            function(){
                                if (disposed || seq !== _techSeq || _techTargetId !== seriesId) return
                                techEpisodeLoading = false
                                techEpisodeDetails = null
                                _refreshActiveExtras()
                            }
                        )
                    },
                    function(){
                        if (disposed || seq !== _techSeq || _techTargetId !== seriesId) return
                        techEpisodeLoading = false
                    },
                    fbx
                )
            },
            function(){
                if (disposed || seq !== _techSeq || _techTargetId !== seriesId) return
                techEpisodeLoading = false
            },
            fbx
        )
    }
    Timer {
        id: detailsDebounceTimer
        interval: detailsDebounceMs
        repeat: false
        onTriggered: {
            if (detailCollectionPage.disposed) return
            if (detailCollectionPage._anyCarouselMoving()) { restart(); return }
            var id = detailCollectionPage._detailsPendingId
            if (!id || !id.length) {
                detailCollectionPage.selectedDetailsId = ""
                detailCollectionPage.selectedDetails = null
                detailCollectionPage.selectedDetailsLoading = false
                detailCollectionPage._refreshActiveExtras()
                return
            }
            var cachedDetails = detailCollectionPage._getDetailsCache(id)
            if (cachedDetails) {
                detailCollectionPage.selectedDetailsId = id
                detailCollectionPage.selectedDetails = cachedDetails
                detailCollectionPage.selectedDetailsLoading = false
                if (MediaCatalog.isSeries(detailCollectionPage.selectedDetails))
                    detailCollectionPage._scheduleSeriesTechDwell(id)
                else {
                    detailCollectionPage._scheduleSeriesTechDwell("")
                    techEpisodeDetails = null
                    techEpisodeLoading = false
                    _techTargetId = ""
                }
                detailCollectionPage._refreshActiveExtras()
                return
            }
            detailCollectionPage.selectedDetailsId = id
            detailCollectionPage.selectedDetails = null
            detailCollectionPage.selectedDetailsLoading = true
            var seq = ++detailCollectionPage._detailsSeq
            detailCollectionPage._detailsHandle = Jellyfin.fetchUserItemWithPublicFallback(serverUrl, accessToken, userId, id,
                function(res){
                    if (detailCollectionPage.disposed || seq !== detailCollectionPage._detailsSeq) return
                    detailCollectionPage._detailsHandle = null
                    detailCollectionPage.selectedDetailsLoading = false
                    if (res) {
                        detailCollectionPage._putDetailsCache(id, res)
                        detailCollectionPage.selectedDetails = MediaCatalog.compactCollectionDetails(res)
                        if (MediaCatalog.isSeries(res))
                            detailCollectionPage._scheduleSeriesTechDwell(id)
                        else {
                            detailCollectionPage._scheduleSeriesTechDwell("")
                            techEpisodeDetails = null
                            techEpisodeLoading = false
                            _techTargetId = ""
                        }
                    } else {
                        detailCollectionPage.selectedDetails = null
                        detailCollectionPage._scheduleSeriesTechDwell("")
                    }
                    detailCollectionPage._refreshActiveExtras()
                },
                function(){
                    if (detailCollectionPage.disposed || seq !== detailCollectionPage._detailsSeq) return
                    detailCollectionPage._detailsHandle = null
                    detailCollectionPage.selectedDetailsLoading = false
                    detailCollectionPage.selectedDetails = null
                    detailCollectionPage._scheduleSeriesTechDwell("")
                    detailCollectionPage._refreshActiveExtras()
                }
            )
        }
    }
    function _cancelSelectedDetailsRequest(){
        detailsDebounceTimer.stop()
        ++_detailsSeq
        var h = _detailsHandle
        _detailsHandle = null
        try { if (h && h.cancel) h.cancel("focus_changed") } catch(e) {}
        selectedDetailsLoading = false
    }
    function _requestSelectedDetails(arg){
        if (isLoading || overlayMode !== "none") return
        var it = null
        var id = ""
        if (arg && typeof arg === "object") { it = arg; id = arg.Id ? (""+arg.Id) : "" }
        else id = arg ? (""+arg) : ""
        var samePendingId = _detailsPendingId === id
        if (!samePendingId) _cancelSelectedDetailsRequest()
        _detailsPendingId = id
        _detailsPendingItem = it
        if (samePendingId && _detailsHandle) return
        if (it && id.length && !_needsDetails(it)) {
            selectedDetailsId = id
            selectedDetails = it
            selectedDetailsLoading = false
            if (MediaCatalog.isSeries(it)) _scheduleSeriesTechDwell(id)
            else _scheduleSeriesTechDwell("")
            _refreshActiveExtras()
            return
        }
        detailsDebounceTimer.restart()
    }
    function _clearFocusDrivenUI(){
        _scheduleRailPosterHq(null)
        _requestBgOverride(null)
        _cancelSelectedDetailsRequest()
        _detailsPendingId = ""
        _detailsPendingItem = null
        selectedDetailsId = ""
        selectedDetails = null
        selectedDetailsLoading = false
        _scheduleSeriesTechDwell("")
        techEpisodeDetails = null
        techEpisodeLoading = false
        _techTargetId = ""
        _refreshActiveExtras()
    }
    function _updateFocusDrivenUI(){
        if (isLoading || overlayMode !== "none") return
        var it = _focusedChild()
        if (it && it.Id) {
            _scheduleRailPosterHq(it)
            _requestBgOverride(it)
            _requestSelectedDetails(it)
        } else {
            _clearFocusDrivenUI()
        }
        _refreshActiveExtras()
    }
    readonly property bool showingChild: (currentFocus === 3 || currentFocus === 4)
    readonly property var  activeItem: showingChild ? (selectedDetails || _focusedChild()) : item
    readonly property string activeTitle: (activeItem && activeItem.Name) ? (""+activeItem.Name) : ""
    readonly property string activeGenresLine: MediaCatalog.mediaGenresLine(activeItem)
    readonly property string activeDateLine: MediaCatalog.mediaDateLineShortFr(activeItem)
    readonly property bool   activeHasRating: !!(activeItem && (typeof activeItem.CommunityRating !== "undefined"))
    readonly property string activeRatingText: activeHasRating ? Number(activeItem.CommunityRating || 0).toFixed(1) : ""
    readonly property string activeOfficialRating: (activeItem && activeItem.OfficialRating) ? (""+activeItem.OfficialRating) : ""
    function _activeOverviewText(){
        if (showingChild) {
            if (selectedDetailsLoading) return "Chargement du résumé…"
            if (selectedDetails && selectedDetails.Overview && (""+selectedDetails.Overview).length)
                return MediaCatalog.normalizeOverviewLine(selectedDetails.Overview)
            var fc = _focusedChild()
            if (fc && fc.Overview && (""+fc.Overview).length)
                return MediaCatalog.normalizeOverviewLine(fc.Overview)
            return "Pas de résumé disponible."
        }
        if (item && item.Overview && (""+item.Overview).length) return MediaCatalog.normalizeOverviewLine(item.Overview)
        return "Pas de résumé disponible."
    }
    function _setFlickY(y){
        if (!rootFlick) return
        var maxY = Math.max(0, rootFlick.contentHeight - rootFlick.height)
        rootFlick.contentY = Math.max(0, Math.min(maxY, y))
    }
    function ensureItemVisible(target, m){
        if (!target || !target.visible || !rootFlick) return
        var margin = m || 20
        var reserveTop = (pinDynamicHero && (target === seriesSection || target === filmsSection)) ? pinnedHeroReserveH : 0
        var p = target.mapToItem(rootFlick.contentItem, 0, 0)
        var top = p.y - margin, bot = p.y + target.height + margin
        var viewTop = rootFlick.contentY + reserveTop
        var viewBot = rootFlick.contentY + rootFlick.height
        if (top < viewTop) _setFlickY(top - reserveTop)
        else if (bot > viewBot) _setFlickY(bot - rootFlick.height)
    }
    function ensureRailVisible(section, list, m){
        if (!section || !section.visible || !rootFlick) return
        if (!pinDynamicHero || !list) { ensureItemVisible(section, m || 30); return }

        // Cadrer la SECTION entière, et non uniquement la ListView. Sinon le
        // titre reste sous le masque du hero alors que les posters paraissent
        // correctement positionnés.
        var topGap = 0
        var bottomGap = 2
        var p = section.mapToItem(rootFlick.contentItem, 0, 0)
        var railTop = p.y
        var railBot = p.y + section.height
        var safeTop = rootFlick.contentY + pinnedHeroReserveH + topGap
        var safeBot = rootFlick.contentY + rootFlick.height - bottomGap
        var railH = Math.max(1, railBot - railTop)
        var safeH = Math.max(1, safeBot - safeTop)
        if (railH > safeH) {
            _setFlickY(railTop - pinnedHeroReserveH - topGap)
            return
        }
        if (railTop < safeTop)
            _setFlickY(railTop - pinnedHeroReserveH - topGap)
        else if (railBot > safeBot)
            _setFlickY(railBot - rootFlick.height + bottomGap)
    }
    function _maybeExitCarousel(from){
        Qt.callLater(function(){
            if (disposed || overlayMode !== "none") return
            var any = (seriesList && seriesList.activeFocus) || (filmsList && filmsList.activeFocus)
            if (!any && detailCollectionPage.currentFocus === from) {
                detailCollectionPage.currentFocus = 0
                _clearFocusDrivenUI()
                if (detailsBox && detailsBox.forceActiveFocus) detailsBox.forceActiveFocus()
            }
        })
    }
    function goTopBarFocus(){
        if (isLoading) return
        currentFocus = -1
        if (rootFlick) rootFlick.contentY = 0
        if (clockHud && clockHud.focusAvatar) clockHud.focusAvatar()
        _clearFocusDrivenUI()
        _scheduleClockHudSync(true)
    }
    function goToOverview(){
        if (isLoading) return
        currentFocus = 0
        if (pinDynamicHero && rootFlick) rootFlick.contentY = 0
        else ensureItemVisible(detailsBox, 30)
        detailsBox.forceActiveFocus()
        _clearFocusDrivenUI()
    }
    function goToPoster(){
        if (isLoading) return
        if (!hasCollectionArt || artStage === "none") { goToOverview(); return }
        currentFocus = 2
        if (pinDynamicHero && rootFlick) rootFlick.contentY = 0
        posterFocus.forceActiveFocus()
        _clearFocusDrivenUI()
    }
    function goToSeries(){
        if (isLoading) return
        if (!seriesWarm || seriesWarm.length <= 0) { goToFilms(); return }
        if (currentFocus !== 3 && currentFocus !== 4) _armRailEntryAnimation(3)
        currentFocus = 3
        _expandSeriesIfNeeded()
        ensureRailVisible(seriesSection, seriesList, 18)
        seriesList.forceActiveFocus()
        _updateFocusDrivenUI()
    }
    function goToFilms(){
        if (isLoading) return
        if (!filmsWarm || filmsWarm.length <= 0) { goToSeries(); return }
        if (currentFocus !== 3 && currentFocus !== 4) _armRailEntryAnimation(4)
        currentFocus = 4
        _expandFilmsIfNeeded()
        ensureRailVisible(filmsSection, filmsList, 18)
        filmsList.forceActiveFocus()
        _updateFocusDrivenUI()
    }
    function goToItems(){
        if (isLoading) return
        if (seriesWarm && seriesWarm.length > 0) goToSeries()
        else if (filmsWarm && filmsWarm.length > 0) goToFilms()
        else goToOverview()
    }
    function restoreFocusFromHud(){
        if (isLoading) return
        goToOverview()
    }
    onCurrentFocusChanged: {
        if (currentFocus === 3) _expandSeriesIfNeeded()
        else if (currentFocus === 4) _expandFilmsIfNeeded()
        if (currentFocus === 3 || currentFocus === 4) _updateFocusDrivenUI()
        else _clearFocusDrivenUI()
    }
    Timer {
        id: railEntryAnimDisarmTimer
        interval: 360
        repeat: false
        onTriggered: {
            detailCollectionPage._railEntryAnimArmed = false
            detailCollectionPage._railEntryAnimFocus = 0
        }
    }

    readonly property bool ctxOk: !!(serverUrl && accessToken && userId && effectiveBoxSetId)
    property bool isLoading: true
    property bool _itemFetchedOnce: false
    property int  minLoadingMs: 350
    property int  _loadingStartedMs: 0
    property string loadingError: ""
    property bool _missingParamsConfirmed: false
    property bool gateCollectionItemsReady: false
    property bool gateCarouselsReady: false
    property bool gateLayoutReady: false
    property bool extendedLoadingTimedOut: false
    readonly property bool extendedLoading: !isLoading
                                            && !(loadingError && loadingError.length)
                                            && (!gateCollectionItemsReady || !gateCarouselsReady || !gateLayoutReady)
    readonly property bool visualLoading: isLoading || extendedLoading
    readonly property bool shellLoading: visualLoading
    readonly property string shellLoadingError: loadingError || ""
    property int _fetchSeq: 0
    property bool _fetchInFlight: false
    property string _fetchKey: ""
    property var _itemFetchHandle: null
    function _cancelMainItemFetch(reason){
        var h = _itemFetchHandle
        _itemFetchHandle = null
        _fetchInFlight = false
        try { if (h && h.cancel) h.cancel(reason || "context_changed") } catch(e) {}
    }
    function _mkFetchKey(){
        // Cache mémoire uniquement : ne pas conserver serverUrl|userId|collectionId en clair.
        return "collection#" + SafeLog.shortHash(serverUrl + "|" + userId + "|" + effectiveBoxSetId) +
               "|" + (accessToken ? "auth" : "anon")
    }
    property bool bgPreReady: false
    property bool artPreReady: false
    property bool heroBgDone: false
    property bool heroArtDone: false
    property bool heroImagesTimedOut: false
    property bool _endRequested: false
    Timer { id: heroBgKick; interval:80; repeat:false; onTriggered:{ bgPreReady=true; _kickBackdropLoad(); _updateHeroGate() } }
    Timer { id: heroArtKick; interval:140; repeat:false; onTriggered:{ artPreReady=true; _updateHeroGate() } }
    Timer { id: heroImagesTimeout; interval:4500; repeat:false; onTriggered:{ heroImagesTimedOut=true; _updateHeroGate() } }
    function _srcStr(img){ var s=""; try { s=(img && img.source!==undefined && img.source!==null)?(""+img.source):"" } catch(e){ s="" } return s }
    function _imgDone(img){
        if (!img) return true
        var s=_srcStr(img); if (!s || !s.length) return true
        return (img.status===Image.Ready || img.status===Image.Error)
    }
    function _startHeroPreload(){
        bgPreReady=false; artPreReady=false; heroBgDone=false; heroArtDone=false; heroImagesTimedOut=false
        heroBgKick.restart(); heroArtKick.restart(); heroImagesTimeout.restart()
        _updateHeroGate()
    }
    function _updateHeroGate(){
        heroBgDone = _backdropGateDone()
        heroArtDone = artPreReady && _imgDone(artImage)
        _maybeEndLoadingWithGate()
    }
    function _gateSatisfied(){
        if (loadingError && loadingError.length) return true
        if (heroImagesTimedOut) return true
        return (heroBgDone && heroArtDone)
    }
    function _maybeEndLoadingWithGate(){
        if (disposed || !isLoading || !_itemFetchedOnce || !_endRequested || !_gateSatisfied()) return
        var elapsed = Date.now() - _loadingStartedMs
        loadingOffTimer.interval = Math.max(140, minLoadingMs - elapsed)
        if (!loadingOffTimer.running) loadingOffTimer.restart()
    }
    Timer {
        id: loadingHardTimeout
        interval: 15000
        repeat: false
        onTriggered:{
            if (disposed) return
            if (isLoading && ctxOk && !_itemFetchedOnce) {
                loadingError = "Timeout réseau / API. Back pour sortir."
                _endRequested = true
                _updateHeroGate()
            }
        }
    }
    Timer {
        id: missingParamsTimer
        interval: 650
        repeat: false
        onTriggered: {
            if (disposed) return
            if (!ctxOk) {
                _missingParamsConfirmed = true
                loadingError = "Paramètres manquants."
            }
        }
    }
    Timer {
        id: loadingOffTimer
        interval: 140
        repeat: false
        onTriggered:{
            if (disposed) return
            if (!_gateSatisfied()) { _updateHeroGate(); return }
            if (isLoading && _itemFetchedOnce) {
                isLoading = false
                Qt.callLater(function(){
                    if (disposed) return
                    initFocusTimer.restart()
                })
            }
        }
    }
    function beginLoading(startTimeout){
        _loadingStartedMs = Date.now()
        loadingError = ""
        _missingParamsConfirmed = false
        missingParamsTimer.stop()
        isLoading = true
        didInitialFocus = false
        _itemFetchedOnce = false
        _endRequested = false
        bgPreReady=false; artPreReady=false; heroBgDone=false; heroArtDone=false; heroImagesTimedOut=false
        heroBgKick.stop(); heroArtKick.stop(); heroImagesTimeout.stop(); loadingOffTimer.stop()
        _resetExtendedGates()
        overlayMode = "none"
        overlayData = ({})
        if (startTimeout) loadingHardTimeout.restart()
        else loadingHardTimeout.stop()
    }
    function scheduleEndLoading(){ if (disposed || !_itemFetchedOnce) return; _endRequested = true; _updateHeroGate() }
    Timer { id: layoutReadyTimer; interval: 320; repeat: false; onTriggered: gateLayoutReady = true }
    Timer { id: extendedLoadingTimeout; interval: 1900; repeat: false; onTriggered: _releaseExtendedGates() }
    function _resetExtendedGates(){
        gateCollectionItemsReady = false
        gateCarouselsReady = false
        gateLayoutReady = false
        extendedLoadingTimedOut = false
        layoutReadyTimer.stop()
        extendedLoadingTimeout.stop()
    }
    function _releaseExtendedGates(){
        extendedLoadingTimeout.stop()
        layoutReadyTimer.stop()
        gateCollectionItemsReady = true
        gateCarouselsReady = true
        gateLayoutReady = true
        extendedLoadingTimedOut = true
    }
    function _startExtendedLoading(){
        if (disposed || isLoading || (loadingError && loadingError.length)) return
        gateLayoutReady = false
        layoutReadyTimer.restart()
        extendedLoadingTimeout.restart()
        _updateExtendedLoadingGates()
    }
    function _markCollectionItemsLoaded(){
        gateCollectionItemsReady = true
        Qt.callLater(function(){
            if (disposed) return
            _updateExtendedLoadingGates()
        })
    }
    function _updateExtendedLoadingGates(){
        if (disposed || isLoading) return
        if (loadingError && loadingError.length) { _releaseExtendedGates(); return }
        if (extendedLoadingTimedOut) { _releaseExtendedGates(); return }
        if (!gateCollectionItemsReady) return
        var needSeries = !!(seriesWarm && seriesWarm.length > 0)
        var needFilms  = !!(filmsWarm  && filmsWarm.length  > 0)
        var seriesOk = !needSeries || (seriesList && seriesList.count >= seriesWarm.length)
        var filmsOk  = !needFilms  || (filmsList  && filmsList.count  >= filmsWarm.length)
        if (seriesOk && filmsOk) gateCarouselsReady = true
    }
    property bool posterReady: false
    Timer { id: posterWarmupTimer; interval: 160; repeat:false; onTriggered: posterReady = true }
    onIsLoadingChanged: {
        if (disposed) return
        if (!isLoading) {
            loadingHardTimeout.stop()
            posterReady = false; posterWarmupTimer.restart()
            _startExtendedLoading()
        } else {
            posterReady = false; posterWarmupTimer.stop()
        }
        _syncClockHud()
    }
    onVisualLoadingChanged: {
        if (disposed) return
        if (!visualLoading) initFocusTimer.restart()
        _syncClockHud()
    }
    property bool logoOk: false
    property bool logoFailed: false
    property string artStage: "logo" // logo|poster|none
    function _resetLogoState(){
        logoOk = false
        logoFailed = false
        artStage = hasCollectionLogo ? "logo" : (hasCollectionCover ? "poster" : "none")
    }
    property bool uiReady: false
    property bool didInitialFocus: false
    Timer {
        id: initFocusTimer
        interval: 32
        repeat: false
        onTriggered: {
            if (!uiReady || visualLoading)
                return
            if (didInitialFocus)
                return
            currentFocus = 0
            detailsBox.forceActiveFocus()
            didInitialFocus = true
        }
    }
    function fetchIfReady(){
        if (!ctxOk) {
            _cancelMainItemFetch("missing_context")
            warmSnapshotVisible = false
            _warmDetailSnapshot = null
            beginLoading(false)
            item = null
            filmsAll = []; seriesAll = []
            filmsWarm = []; seriesWarm = []
            filmsExpanded = false; seriesExpanded = false
            itemsLoading = false
            _resetCollectionChildrenPaging()
            _cancelSelectedDetailsRequest()
            _clearBackdropBuffers()
            _releaseExtendedGates()
            loadingError = ""
            if (!missingParamsTimer.running)
                missingParamsTimer.restart()
            return
        }
        missingParamsTimer.stop()
        _missingParamsConfirmed = false
        loadingError = ""
        var key=_mkFetchKey()
        if (_fetchInFlight && _fetchKey===key) return
        _cancelMainItemFetch("replaced")
        _fetchKey=key; _fetchInFlight=true
        var seq=++_fetchSeq
        _resetCollectionChildrenPaging()
        beginLoading(true)
        _clearBackdropBuffers()
        bgOverrideItem = null
        _bgOverrideId = ""
        _bgPendingItem = null
        filmsAll = []; seriesAll = []
        filmsWarm = []; seriesWarm = []
        filmsExpanded = false; seriesExpanded = false
        itemsLoading = true
        _cancelSelectedDetailsRequest()
        detailsCache = ({})
        detailsCacheOrder = []
        selectedDetailsId = ""
        selectedDetails = null
        selectedDetailsLoading = false
        _detailsPendingId = ""
        _detailsPendingItem = null
        detailsDebounceTimer.stop()
        seriesTechCache = ({})
        seriesTechCacheOrder = []
        techEpisodeDetails = null
        techEpisodeLoading = false
        _techTargetId = ""
        _scheduleSeriesTechDwell("")
        activeDurationExtra = ""
        activeTechChips = []
        _refreshActiveExtras()
        _useWarmDetailSnapshot()
        var id = effectiveBoxSetId
        var mainHandle = null
        mainHandle = Jellyfin.fetchUserItemWithPublicFallback(serverUrl, accessToken, userId, id,
            function(res){
                if (disposed || seq!==_fetchSeq) return
                if (_itemFetchHandle === mainHandle) _itemFetchHandle = null
                _fetchInFlight=false
                item = res
                warmSnapshotVisible = false
                _warmDetailSnapshot = null
                _resetLogoState()
                _itemFetchedOnce = true
                loadingError = ""
                _startHeroPreload()
                scheduleEndLoading()
                // Les posters de collection chargent en tâche de fond : ne pas bloquer le scroll
                // ni garder le loader plein écran pendant une réponse Jellyfin lente.
                _markCollectionItemsLoaded()
                _resetCollectionChildrenPaging()
                _collectionChildrenDeadlineAt = Date.now() + 14000
                _fetchCollectionChildrenPage(seq, _childrenSeq, id, 0)
            },
            function(err){
                if (disposed || seq!==_fetchSeq) return
                if (_itemFetchHandle === mainHandle) _itemFetchHandle = null
                _fetchInFlight=false
                if (warmSnapshotVisible) {
                    loadingError = ""
                    _itemFetchedOnce = true
                    _releaseExtendedGates()
                    _startHeroPreload()
                    scheduleEndLoading()
                    _resetCollectionChildrenPaging()
                    _collectionChildrenDeadlineAt = Date.now() + 14000
                    _fetchCollectionChildrenPage(seq, _childrenSeq, id, 0)
                } else {
                    item = null
                    filmsAll = []; seriesAll = []
                    filmsWarm = []; seriesWarm = []
                    filmsExpanded = false; seriesExpanded = false
                    itemsLoading = false
                    loadingError = "Erreur réseau / API. Back pour sortir."
                    _releaseExtendedGates()
                    _itemFetchedOnce = true
                    _endRequested = true
                    _updateHeroGate()
                    scheduleEndLoading()
                }
            }
        )
        _itemFetchHandle = mainHandle
    }
    property real _lastHudOpacity: -1
    property bool _hudForcePending: false
    Timer {
        id: hudSyncTimer
        interval: 60
        repeat: false
        onTriggered: {
            var force = detailCollectionPage._hudForcePending
            detailCollectionPage._hudForcePending = false
            detailCollectionPage._syncClockHudCore(force)
        }
    }
    function _scheduleClockHudSync(force){
        if (force) _hudForcePending = true
        hudSyncTimer.restart()
    }
    function _syncClockHudCore(force){
        if (!clockHud) return
        var op = 1.0 - Math.min((rootFlick ? rootFlick.contentY : 0) / 80, 1)
        if (!force && _lastHudOpacity >= 0 && Math.abs(op - _lastHudOpacity) < 0.02) return
        _lastHudOpacity = op
        _setPropSafe(clockHud, "fbx", fbx)
        _setPropSafe(clockHud, "serverUrl", serverUrl)
        _setPropSafe(clockHud, "userId", userId)
        _setPropSafe(clockHud, "userImageTag", userImageTag)
        _setPropSafe(clockHud, "userName", userName)
        _setPropSafe(clockHud, "showAvatar", true)
        _setPropSafe(clockHud, "avatarSize", avatarSize)
        _setPropSafe(clockHud, "active", (!visualLoading && overlayMode==="none"))
        _setPropSafe(clockHud, "scrolling", !!(rootFlick && (rootFlick.moving || rootFlick.dragging)))
        _setPropSafe(clockHud, "hudOpacity", op)
    }
    function _syncClockHud(){ _scheduleClockHudSync(true); }
    Timer {
        id: ctxFetchDebounceTimer
        interval: 90
        repeat: false
        onTriggered: {
            if (detailCollectionPage.disposed)
                return
            detailCollectionPage.fetchIfReady()
        }
    }
    function _ctxChanged(){
        _cancelMainItemFetch("context_changed")
        ctxFetchDebounceTimer.restart()
        _syncClockHud()
    }
    onVisibleChanged: {
        if (visible) {
            var hydrated = _hydrateSensitiveContextFromShared()
            if (hydrated || (accessToken && userId && serverUrl && effectiveBoxSetId)) {
                _ctxChanged()
            }
        }
    }
    onSharedChanged: {
        if (_hydrateSensitiveContextFromShared())
            _ctxChanged()
    }
    onAccessTokenChanged: _ctxChanged()
    onUserIdChanged:      _ctxChanged()
    onServerUrlChanged:   _ctxChanged()
    onUserImageTagChanged:_syncClockHud()
    onUserNameChanged:    _syncClockHud()
    Component.onCompleted: {
        _hydrateSensitiveContextFromShared()
        uiReady = true
        _ctxChanged()
        Qt.callLater(function(){
            if (rootFlick) rootFlick.contentY = 0
            initFocusTimer.restart()
            _syncClockHud()
        })
    }
    Component.onDestruction: {
        disposed = true
        _cancelMainItemFetch("destroyed")
        ++_childrenAttemptSeq
        _cancelCollectionChildrenRequest()
        _cancelSelectedDetailsRequest()
    }
    Component {
        id: railPosterDelegate
        Item {
            id: railDelegate
            readonly property var railList: ListView.view
            readonly property var sec: railList ? railList.railSection : null
            readonly property int railFocus: railList ? railList.railFocus : 0
            readonly property bool selected: !!railList && railList.currentIndex === index
            readonly property bool hasPoster: MediaCatalog.hasPrimaryOrThumbImage(modelData)
            readonly property bool thumbOnlyPoster: {
                if (!modelData) return false
                var tags = modelData.ImageTags || {}
                return !tags.Primary && !!tags.Thumb
            }
            readonly property bool played: MediaCatalog.mediaIsPlayedIncludingPercentage(modelData)
            readonly property bool seriesCard: MediaCatalog.isSeries(modelData)
            readonly property int unreadCount: seriesCard ? MediaCatalog.unreadCount(modelData) : 0
            readonly property real prog: MediaCatalog.mediaProgressRatio(modelData)
            readonly property bool inProgress: (prog > 0.02 && prog < 0.999 && !played)
            readonly property bool railScrolling: !!railList
                                                  && (railList.moving
                                                      || railList.dragging
                                                      || railList.flicking)
            property var itemData: modelData

            width: sec ? sec.cellW : 0
            height: sec ? sec.cellH : 0

            Pages.LibraryPosterCard {
                id: railPosterCard
                anchors.left: parent.left
                anchors.top: parent.top

                controller: detailCollectionPage
                modelData: railDelegate.itemData
                tileWidth: railDelegate.sec ? railDelegate.sec.cardW : 0
                tileHeight: railDelegate.sec ? railDelegate.sec.cardH : 0
                titleHeight: 0
                sidePad: railDelegate.sec ? railDelegate.sec.pad : 0
                topPad: railDelegate.sec
                        ? (railDelegate.sec.pad
                           + detailCollectionPage.railFocusTopPad(
                               railDelegate.sec.cardH,
                               railDelegate.sec.focusScale,
                               railDelegate.sec.focusLiftPx))
                        : 0

                gridColumns: 0
                gridActiveFocus: !!railDelegate.railList && railDelegate.railList.activeFocus
                selected: railDelegate.selected
                allowLoad: detailCollectionPage.visible && railDelegate.visible
                enableMouseInput: true
                hoverSelectEnabled: true
                focusLiftPxOverride: railDelegate.sec ? railDelegate.sec.focusLiftPx : 0
                zoomScaleOverride: railDelegate.sec ? railDelegate.sec.focusScale : 1.0

                useAllowAnimsOverride: true
                // Armer l’animation dès que le routeur de focus cible le rail.
                // Lors du premier passage Résumé -> rail, currentFocus bascule avant
                // que ListView.activeFocus soit stabilisé. Si l’animation dépend
                // uniquement d’activeFocus, LibraryPosterCard peut entrer dans son
                // état focused pendant que allowAnims vaut encore false et appliquer
                // le zoom immédiatement (durée 0). Entre posters, activeFocus étant
                // déjà stable, le bug était invisible.
                allowAnimsOverride: detailCollectionPage.visible
                                    && !!railDelegate.railList
                                    && (railDelegate.railList.activeFocus
                                        || detailCollectionPage.currentFocus === railDelegate.railFocus
                                        || (detailCollectionPage._railEntryAnimArmed
                                            && detailCollectionPage._railEntryAnimFocus === railDelegate.railFocus))
                                    && (!railDelegate.railScrolling
                                        || (detailCollectionPage._railEntryAnimArmed
                                            && detailCollectionPage._railEntryAnimFocus === railDelegate.railFocus))
                useAllowDecosOverride: true
                allowDecosOverride: allowAnimsOverride
                smoothImages: !railDelegate.railScrolling && !detailCollectionPage.flickBusy

                useImageSourceOverride: true
                imageSourceOverride: (allowLoad && railDelegate.hasPoster)
                                     ? detailCollectionPage._collectionPosterThumbUrl(
                                           railDelegate.itemData,
                                           railDelegate.sec ? railDelegate.sec.reqW : 240,
                                           railDelegate.sec ? railDelegate.sec.reqH : 360,
                                           85)
                                     : ""
                imageFillModeOverride: railDelegate.thumbOnlyPoster
                                       ? Image.PreserveAspectFit
                                       : Image.PreserveAspectCrop
                hqImageSourceOverride: {
                    var id = (railDelegate.itemData && railDelegate.itemData.Id)
                             ? String(railDelegate.itemData.Id) : ""
                    if (!railDelegate.hasPoster || !railDelegate.railList
                            || !railDelegate.railList.activeFocus || !railDelegate.selected
                            || railDelegate.railScrolling || detailCollectionPage.flickBusy
                            || !id.length || detailCollectionPage.railPosterHqTargetId !== id)
                        return ""
                    return detailCollectionPage._collectionPosterThumbUrl(
                                railDelegate.itemData,
                                Math.round((railDelegate.sec ? railDelegate.sec.cardW : 150)
                                           * detailCollectionPage.railPosterHqOversample),
                                Math.round((railDelegate.sec ? railDelegate.sec.cardH : 225)
                                           * detailCollectionPage.railPosterHqOversample),
                                detailCollectionPage.railPosterHqQuality)
                }
                imageCache: true
                fallbackOnImageError: false
                fallbackGlyph: railDelegate.railList
                               ? railDelegate.railList.fallbackGlyph : "\u25A6"
                fallbackGlyphScale: 0.34

                showWatchedBadge: true
                watched: railDelegate.played
                watchedBadgePosition: "topLeft"
                watchedBadgeSize: 18
                watchedBadgeMargin: 8
                suppressWatchedWhenUnplayed: false

                showUnplayedBadge: railDelegate.seriesCard
                unplayedCount: railDelegate.unreadCount

                showProgress: railDelegate.inProgress
                progressRatioOverride: railDelegate.prog
                progressSideInsetOverride: 0
                progressBottomMarginOverride: 0
                progressHeightOverride: 6
                progressRadiusOverride: 0
                progressTrackColorOverride: "#59000000"
                progressFillColorOverride: "#F23B82F6"
                progressMinWidthOverride: 2

                onHovered: {
                    if (!railDelegate.railList)
                        return
                    railDelegate.railList.currentIndex = index
                    if (railDelegate.railList.activeFocus
                            && detailCollectionPage.currentFocus === railDelegate.railFocus)
                        detailCollectionPage._updateFocusDrivenUI()
                }
                onActivated: {
                    if (!railDelegate.railList)
                        return
                    railDelegate.railList.currentIndex = index
                    detailCollectionPage.currentFocus = railDelegate.railFocus
                    railDelegate.railList.forceActiveFocus()
                    detailCollectionPage._updateFocusDrivenUI()
                    detailCollectionPage.openChild(railDelegate.itemData)
                }
            }
        }
    }
    Item {
        id: contentLayer
        anchors.fill: parent
        visible: !visualLoading
        enabled: !visualLoading
        opacity: visualLoading ? 0.0 : 1.0
        Behavior on opacity { enabled: !flickBusy; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Loader {
            id: overlayLoader
            anchors.fill: parent
            z: 9999
            active: overlayMode !== "none"
            source: active ? Qt.resolvedUrl("OverlayHub.qml") : ""
            visible: active
            asynchronous: true
            onLoaded: {
                if (!overlayLoader.item) return
                var hub = overlayLoader.item
                hub.host = detailCollectionPage
                hub.posterMaxW = overlayPosterMaxW
                hub.posterMaxH = overlayPosterMaxH
                try {
                    if (hub.requestClose) hub.requestClose.connect(closeOverlay)
                    if (hub.closed) hub.closed.connect(closeOverlay)
                } catch(e) {}
                Qt.callLater(function(){ if (overlayLoader.item && overlayMode !== "none") overlayLoader.item.forceActiveFocus() })
            }
        }
        Item {
            id: staticScene
            anchors.fill: parent
            z: 1
            Rectangle { anchors.fill: parent; color: "#000"; z: -3 }
            Image {
                id: blurredBGA
                anchors.fill: parent
                z: -2
                fillMode: Image.PreserveAspectCrop
                source: detailCollectionPage._bgUrlA
                opacity: detailCollectionPage._bgFrontA ? 0.95 : 0.0
                visible: opacity > 0.001 && ("" + source).length > 0
                cache: false
                asynchronous: true
                mipmap: false
                smooth: false
                onStatusChanged: detailCollectionPage._onBackdropImageChanged(blurredBGA, true)
                onSourceChanged: detailCollectionPage._onBackdropImageChanged(blurredBGA, true)
                Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            }
            Image {
                id: blurredBGB
                anchors.fill: parent
                z: -1
                fillMode: Image.PreserveAspectCrop
                source: detailCollectionPage._bgUrlB
                opacity: detailCollectionPage._bgFrontA ? 0.0 : 0.95
                visible: opacity > 0.001 && ("" + source).length > 0
                cache: false
                asynchronous: true
                mipmap: false
                smooth: false
                onStatusChanged: detailCollectionPage._onBackdropImageChanged(blurredBGB, false)
                onSourceChanged: detailCollectionPage._onBackdropImageChanged(blurredBGB, false)
                Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            }
            Rectangle {
                anchors.fill: parent
                z: 0
                color: "#000000"
                opacity: bgDarken
                visible: detailCollectionPage.activeBackdropVisible && bgDarken > 0.001
            }
            Flickable {
                id: rootFlick
                anchors.fill: parent
                clip: true
                z: 1
                interactive: (overlayMode==="none") && !visualLoading
                contentWidth: width
                contentHeight: pageColumn.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                onContentYChanged: detailCollectionPage._scheduleClockHudSync(false)
                onMovingChanged: detailCollectionPage._scheduleClockHudSync(true)
                onDraggingChanged: detailCollectionPage._scheduleClockHudSync(true)
                Behavior on contentY { enabled: !rootFlick.moving && !rootFlick.dragging; NumberAnimation { duration:160; easing.type:Easing.OutCubic } }
                Column {
                    id: pageColumn
                    width: rootFlick.width
                    spacing: sectionsSpacing
                    anchors.top: parent.top
                    anchors.topMargin: contentTopGap
                    Column {
                        id: headerBlock
                        x: marginL
                        width: parent.width - marginL - marginR
                        spacing: 6
                        z: 60
                        transform: [ Translate { y: headerTopNudgeY + pinnedHeroCounterY } ]
                        FontMetrics { id: titleMetrics; font.pixelSize: titleFontPx; font.bold: true }
                        readonly property bool titleShouldMarquee: (activeTitle && activeTitle.length > titleCharLimit)
                        Item {
                            id: titleLineBox
                            width: headerBlock.titleShouldMarquee ? Math.min(headerBlock.width, MediaCatalog.titleTextCapPx(titleMetrics.averageCharacterWidth, titleCharLimit)) : headerBlock.width
                            height: Math.max(36, titleTextItem.implicitHeight + 2)
                            clip: false
                            visible: hasItem
                            readonly property bool allowMarquee: detailCollectionPage.visible
                                                                 && !isLoading
                                                                 && (overlayMode === "none")
                                                                 && !flickBusy
                                                                 && !detailCollectionPage._anyCarouselMoving()
                                                                 && hasItem
                                                                 && visible
                            readonly property bool marqueeNeeded: titleTextItem.paintedWidth > titleLineBox.width
                            readonly property real marqueeOverflow: Math.max(0, titleTextItem.paintedWidth - titleLineBox.width)
                            readonly property int  marqueeGap: 44
                            readonly property real marqueeTravel: marqueeNeeded ? Math.max(0, titleTextItem.paintedWidth + marqueeGap) : 0
                            readonly property real marqueeExitX: marqueeTravel > 0 ? -marqueeTravel : 0
                            readonly property int  marqueeScrollMs: marqueeTravel > 0 ? Math.max(3200, Math.min(14000, Math.round(marqueeTravel * 24))) : 0
                            readonly property int  marqueeFadeW: Math.min(58, Math.max(28, Math.round(width * 0.12)))
                            property bool marqueeMoving: false
                            readonly property bool maskActive: marqueeNeeded && allowMarquee && marqueeMoving && visible && width > 0 && height > 0 && !visualLoading && !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking))
                            readonly property bool leftFadeActive: maskActive && (titleTextItem.x < -2)
                            readonly property bool rightFadeActive: maskActive && (titleTextItem.x > -marqueeOverflow + 2)
                            onAllowMarqueeChanged: updateMarquee()
                            onWidthChanged: updateMarquee()
                            onVisibleChanged: updateMarquee()
                            onMarqueeNeededChanged: updateMarquee()
                            Item {
                                id: titleLineSource
                                anchors.fill: parent
                                clip: true
                                visible: !titleLineBox.maskActive
                                Text { textFormat: Text.PlainText;
                                    id: titleTextItem
                                    x: 0
                                    y: Math.round((titleLineSource.height - height) / 2)
                                    text: activeTitle || ""
                                    font.pixelSize: titleFontPx
                                    font.bold: true
                                    color: "#fff"
                                    wrapMode: Text.NoWrap
                                    elide: titleLineBox.allowMarquee ? Text.ElideNone : Text.ElideRight
                                    onTextChanged: titleLineBox.updateMarquee()
                                    onPaintedWidthChanged: titleLineBox.updateMarquee()
                                }
                            }
                            OpacityMask {
                                id: titleMaskedLine
                                anchors.fill: parent
                                visible: titleLineBox.maskActive
                                enabled: titleLineBox.maskActive
                                source: titleLineSource
                                maskSource: titleFadeMask
                                cached: false
                            }
                            Item {
                                id: titleFadeMask
                                visible: titleLineBox.maskActive
                                x: -10000
                                y: -10000
                                width: titleLineBox.width
                                height: titleLineBox.height
                                readonly property int leftW: titleLineBox.leftFadeActive ? titleLineBox.marqueeFadeW : 0
                                readonly property int rightW: titleLineBox.rightFadeActive ? titleLineBox.marqueeFadeW : 0
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
                                    width: Math.max(0, parent.width - titleFadeMask.leftW - titleFadeMask.rightW)
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
                            SequentialAnimation {
                                id: titleMarquee
                                running: false
                                loops: Animation.Infinite
                                ScriptAction { script: { titleLineBox.marqueeMoving = false; titleTextItem.x = 0; titleTextItem.opacity = 1.0 } }
                                PauseAnimation { duration: 700 }
                                ScriptAction { script: { titleLineBox.marqueeMoving = true } }
                                NumberAnimation {
                                    target: titleTextItem
                                    property: "x"
                                    from: 0
                                    to: titleLineBox.marqueeExitX
                                    duration: titleLineBox.marqueeScrollMs
                                    easing.type: Easing.Linear
                                }
                                ScriptAction { script: { titleLineBox.marqueeMoving = false } }
                                PauseAnimation { duration: 180 }
                                ScriptAction { script: { titleTextItem.x = 0; titleTextItem.opacity = 1.0; titleLineBox.marqueeMoving = false } }
                                PauseAnimation { duration: 260 }
                                onRunningChanged: {
                                    if (!running) {
                                        titleLineBox.marqueeMoving = false
                                        titleTextItem.x = 0
                                        titleTextItem.opacity = 1.0
                                    }
                                }
                            }
                            function updateMarquee() {
                                titleMarquee.stop()
                                titleLineBox.marqueeMoving = false
                                titleTextItem.x = 0
                                titleTextItem.opacity = 1.0
                                if (titleLineBox.marqueeNeeded && titleLineBox.allowMarquee && titleLineBox.marqueeScrollMs > 0) {
                                    Qt.callLater(function(){
                                        if (titleLineBox.marqueeNeeded && titleLineBox.allowMarquee && titleLineBox.visible && titleLineBox.marqueeScrollMs > 0)
                                            titleMarquee.start()
                                    })
                                }
                            }
                        }
                        Item {
                            id: metaLine
                            width: headerBlock.width
                            height: Math.max(28, Math.max(ratingWrap.height, dateText.implicitHeight))
                            visible: hasItem
                            Item {
                                id: ratingWrap
                                visible: activeHasRating
                                width: ratingText2.paintedWidth + 26
                                height: Math.max(22, ratingText2.paintedHeight)
                                anchors.verticalCenter: parent.verticalCenter
                                Row {
                                    spacing: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    Text { textFormat: Text.PlainText; text:"★"; color:"#FFC53F"; font.pixelSize:20; verticalAlignment: Text.AlignVCenter }
                                    Text { textFormat: Text.PlainText;
                                        id: ratingText2
                                        text: activeRatingText
                                        color: "#FFFFFF"
                                        font.pixelSize: 20
                                        font.bold: true
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                }
                            }
                            Text { textFormat: Text.PlainText;
                                id: dateText
                                text: activeDateLine
                                visible: text.length > 0
                                color: "#E6FFFFFF"
                                font.pixelSize: 20
                                font.bold: true
                                anchors.verticalCenter: parent.verticalCenter
                                x: (ratingWrap.visible ? (ratingWrap.width + 14) : 0)
                            }
                            Rectangle {
                                id: orChip
                                height: 28
                                radius: 8
                                color: "#1151a3"
                                visible: activeOfficialRating.length > 0
                                anchors.verticalCenter: parent.verticalCenter
                                x: (ratingWrap.visible ? (ratingWrap.width + 14) : 0) + (dateText.visible ? (dateText.implicitWidth + 14) : 0)
                                width: orTxt.paintedWidth + 16
                                Text { textFormat: Text.PlainText;
                                    id: orTxt
                                    anchors.centerIn: parent
                                    text: activeOfficialRating
                                    color: "#fff"
                                    font.pixelSize: 14
                                    font.bold: true
                                }
                            }
                            Text { textFormat: Text.PlainText;
                                id: durationText
                                anchors.verticalCenter: parent.verticalCenter
                                x: orChip.x + (orChip.visible ? (orChip.width + 14) : 0)
                                text: activeDurationExtra
                                visible: text.length > 0
                                color: "#E6FFFFFF"
                                font.pixelSize: 18
                                font.bold: true
                            }
                            Item {
                                id: techChipsClip
                                anchors.verticalCenter: parent.verticalCenter
                                height: 28
                                clip: false
                                visible: activeTechChips && activeTechChips.length > 0
                                x: durationText.x + (durationText.visible ? (durationText.implicitWidth + 14) : 0)

                                // Tous les tags restent présents. La fenêtre visible s'arrête juste
                                // avant le poster du hero, quelle que soit la longueur de chaque tag.
                                // Si la ligne dépasse cette frontière, le marquee révèle la suite.
                                readonly property int posterSafetyGap: 18
                                readonly property real posterLeftInMeta: (posterFocus && posterFocus.visible)
                                    ? Math.max(0, posterFocus.x - headerBlock.x)
                                    : metaLine.width
                                readonly property real availableW: Math.max(0,
                                    Math.min(metaLine.width - x,
                                             posterLeftInMeta - posterSafetyGap - x))
                                width: Math.max(0, Math.min(availableW, Math.ceil(contentW)))

                                readonly property bool allowMarquee: detailCollectionPage.visible
                                                                     && (overlayMode === "none")
                                                                     && !flickBusy
                                                                     && !detailCollectionPage._anyCarouselMoving()
                                                                     && visible
                                                                     && activeTechChips
                                                                     && activeTechChips.length > 0
                                readonly property real contentW: Math.max(techChipRow.implicitWidth || 0,
                                                                          techChipRow.childrenRect.width || 0)
                                readonly property bool marqueeNeeded: contentW > (width + 6)
                                readonly property real marqueeOverflow: Math.max(0, contentW - width)
                                readonly property int marqueeGap: 44
                                readonly property real marqueeTravel: marqueeNeeded
                                                                      ? Math.max(0, contentW + marqueeGap)
                                                                      : 0
                                readonly property real marqueeExitX: marqueeTravel > 0 ? -marqueeTravel : 0
                                readonly property int marqueeScrollMs: marqueeTravel > 0
                                    ? Math.max(3200, Math.min(14000,
                                        Math.round((marqueeTravel / 56) * 1000)))
                                    : 0
                                readonly property int marqueeFadeW: Math.min(46,
                                    Math.max(24, Math.round(width * 0.14)))

                                property bool marqueeMoving: false
                                readonly property bool marqueeEligible: marqueeNeeded && allowMarquee
                                readonly property bool maskActive: marqueeEligible
                                                                   && marqueeMoving
                                                                   && visible
                                                                   && width > 0
                                                                   && height > 0
                                                                   && !visualLoading
                                                                   && !(rootFlick && (rootFlick.moving
                                                                                      || rootFlick.dragging
                                                                                      || rootFlick.flicking))
                                readonly property bool leftFadeActive: maskActive && (techChipRow.x < -2)
                                readonly property bool rightFadeActive: maskActive
                                                                       && (techChipRow.x > -marqueeOverflow + 2)

                                function updateMarquee() {
                                    techChipMarquee.stop()
                                    techChipMarqueeKick.stop()
                                    marqueeMoving = false
                                    techChipRow.x = 0
                                    techChipRow.opacity = 1.0
                                    if (techChipTexture && techChipTexture.scheduleUpdate)
                                        techChipTexture.scheduleUpdate()

                                    if (techChipsClip.marqueeEligible
                                            && techChipsClip.marqueeScrollMs > 0)
                                        techChipMarqueeKick.restart()
                                }

                                onAllowMarqueeChanged: updateMarquee()
                                onAvailableWChanged: updateMarquee()
                                onVisibleChanged: updateMarquee()
                                onMarqueeNeededChanged: updateMarquee()
                                onContentWChanged: updateMarquee()
                                onMarqueeMovingChanged: {
                                    if (techChipTexture && techChipTexture.scheduleUpdate)
                                        techChipTexture.scheduleUpdate()
                                }
                                Component.onCompleted: updateMarquee()

                                Connections {
                                    target: detailCollectionPage
                                    function onActiveTechChipsChanged() {
                                        techChipsClip.updateMarquee()
                                    }
                                    function onCurrentFocusChanged() {
                                        techChipsClip.updateMarquee()
                                    }
                                }

                                Item {
                                    id: techChipSource
                                    anchors.fill: parent
                                    clip: true
                                    // La source reste vivante. ShaderEffectSource.hideSource la cache
                                    // uniquement pendant le mouvement masqué, comme les autres marquees.
                                    visible: true
                                    Row {
                                        id: techChipRow
                                        x: 0
                                        spacing: 8
                                        anchors.verticalCenter: parent.verticalCenter
                                        onChildrenRectChanged: techChipsClip.updateMarquee()
                                        onImplicitWidthChanged: techChipsClip.updateMarquee()
                                        onXChanged: {
                                            if (techChipsClip.maskActive
                                                    && techChipTexture
                                                    && techChipTexture.scheduleUpdate)
                                                techChipTexture.scheduleUpdate()
                                        }
                                        Repeater {
                                            id: techChipRepeater
                                            model: activeTechChips ? activeTechChips.length : 0
                                            onCountChanged: Qt.callLater(techChipsClip.updateMarquee)
                                            delegate: Rectangle {
                                                height: 28
                                                radius: 8
                                                color: activeTechChips[index].c
                                                width: ttxt.paintedWidth + 16
                                                onWidthChanged: Qt.callLater(function(){
                                                    if (techChipsClip)
                                                        techChipsClip.updateMarquee()
                                                })
                                                Text { textFormat: Text.PlainText;
                                                    id: ttxt
                                                    anchors.centerIn: parent
                                                    text: activeTechChips[index].t
                                                    color: "#fff"
                                                    font.pixelSize: activeTechChips[index].px
                                                    font.bold: true
                                                }
                                            }
                                        }
                                    }
                                }

                                ShaderEffectSource {
                                    id: techChipTexture
                                    sourceItem: techChipSource
                                    live: techChipsClip.maskActive
                                    enabled: techChipsClip.maskActive
                                    hideSource: techChipsClip.maskActive
                                    recursive: true
                                    smooth: false
                                    visible: false
                                    wrapMode: ShaderEffectSource.ClampToEdge
                                }

                                Timer {
                                    id: techChipTexturePulse
                                    interval: 140
                                    repeat: true
                                    running: techChipsClip.maskActive
                                             && techChipMarquee.running
                                             && techChipsClip.allowMarquee
                                             && detailCollectionPage.visible
                                             && !visualLoading
                                             && !detailCollectionPage._anyCarouselMoving()
                                    onTriggered: {
                                        if (!techChipsClip.maskActive
                                                || !techChipsClip.allowMarquee
                                                || !detailCollectionPage.visible
                                                || detailCollectionPage._anyCarouselMoving()) {
                                            stop()
                                            return
                                        }
                                        if (techChipTexture && techChipTexture.scheduleUpdate)
                                            techChipTexture.scheduleUpdate()
                                    }
                                }

                                OpacityMask {
                                    id: techChipMaskedLine
                                    anchors.fill: parent
                                    visible: techChipsClip.maskActive
                                    enabled: techChipsClip.maskActive
                                    source: techChipTexture
                                    maskSource: techChipFadeMask
                                    cached: false
                                }

                                Item {
                                    id: techChipFadeMask
                                    visible: techChipsClip.maskActive
                                    x: -10000
                                    y: -10000
                                    width: techChipsClip.width
                                    height: techChipsClip.height
                                    readonly property int leftW: techChipsClip.leftFadeActive
                                                                          ? techChipsClip.marqueeFadeW : 0
                                    readonly property int rightW: techChipsClip.rightFadeActive
                                                                           ? techChipsClip.marqueeFadeW : 0
                                    Rectangle {
                                        visible: techChipFadeMask.leftW > 0
                                        x: 0
                                        y: 0
                                        width: techChipFadeMask.leftW
                                        height: parent.height
                                        gradient: Gradient {
                                            orientation: Gradient.Horizontal
                                            GradientStop { position: 0.0; color: "#00FFFFFF" }
                                            GradientStop { position: 1.0; color: "#FFFFFFFF" }
                                        }
                                    }
                                    Rectangle {
                                        x: techChipFadeMask.leftW
                                        y: 0
                                        width: Math.max(0, parent.width
                                            - techChipFadeMask.leftW - techChipFadeMask.rightW)
                                        height: parent.height
                                        color: "#FFFFFFFF"
                                    }
                                    Rectangle {
                                        visible: techChipFadeMask.rightW > 0
                                        x: parent.width - techChipFadeMask.rightW
                                        y: 0
                                        width: techChipFadeMask.rightW
                                        height: parent.height
                                        gradient: Gradient {
                                            orientation: Gradient.Horizontal
                                            GradientStop { position: 0.0; color: "#FFFFFFFF" }
                                            GradientStop { position: 1.0; color: "#00FFFFFF" }
                                        }
                                    }
                                }

                                SequentialAnimation {
                                    id: techChipMarquee
                                    running: false
                                    loops: Animation.Infinite
                                    ScriptAction {
                                        script: {
                                            techChipRow.x = 0
                                            techChipRow.opacity = 1.0
                                            techChipsClip.marqueeMoving = false
                                        }
                                    }
                                    PauseAnimation { duration: 700 }
                                    ScriptAction {
                                        script: {
                                            techChipsClip.marqueeMoving = true
                                            if (techChipTexture && techChipTexture.scheduleUpdate)
                                                techChipTexture.scheduleUpdate()
                                        }
                                    }
                                    NumberAnimation {
                                        target: techChipRow
                                        property: "x"
                                        from: 0
                                        to: techChipsClip.marqueeExitX
                                        duration: techChipsClip.marqueeScrollMs
                                        easing.type: Easing.Linear
                                    }
                                    ScriptAction {
                                        script: {
                                            techChipsClip.marqueeMoving = false
                                            if (techChipTexture && techChipTexture.scheduleUpdate)
                                                techChipTexture.scheduleUpdate()
                                        }
                                    }
                                    PauseAnimation { duration: 180 }
                                    ScriptAction {
                                        script: {
                                            techChipRow.x = 0
                                            techChipRow.opacity = 1.0
                                            techChipsClip.marqueeMoving = false
                                        }
                                    }
                                    PauseAnimation { duration: 260 }
                                    onRunningChanged: {
                                        if (!running) {
                                            techChipsClip.marqueeMoving = false
                                            techChipRow.x = 0
                                            techChipRow.opacity = 1.0
                                        }
                                        if (techChipTexture && techChipTexture.scheduleUpdate)
                                            techChipTexture.scheduleUpdate()
                                    }
                                }

                                Timer {
                                    id: techChipMarqueeKick
                                    interval: 40
                                    repeat: false
                                    onTriggered: {
                                        if (techChipsClip.marqueeEligible
                                                && techChipsClip.marqueeScrollMs > 0
                                                && !techChipMarquee.running
                                                && detailCollectionPage.visible
                                                && !detailCollectionPage._anyCarouselMoving())
                                            techChipMarquee.start()
                                    }
                                }
                            }
                        }
                        Text { textFormat: Text.PlainText;
                            visible: false
                            text: activeGenresLine
                            color: "#DDE1F6"
                            font.pixelSize: 18
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                        }
                    }
                    Item {
                        id: rowBlock
                        width: parent.width
                        height: safeRowHeight()
                        z: 55
                        transform: [ Translate { y: pinnedHeroCounterY } ]
                        FocusScope {
                            id: detailsBox
                            x: marginL
                            y: overviewTopShift
                            width: rowBlock.width - x - (posterW + posterEdgeGap + marginR + 24)
                            property int lineHeight: Math.round(overviewText.font.pixelSize * 1.4)
                            height: Math.max(overviewMinH, lineHeight * overviewMaxLines + 20)
                            clip: true
                            focus: (currentFocus === 0)
                            visible: hasItem
                            onActiveFocusChanged: if (activeFocus) { currentFocus = 0; _clearFocusDrivenUI() }
                            Rectangle {
                                anchors.fill: parent
                                radius: 12
                                color: glassFocus
                                border.width: 1
                                border.color: glassBorder
                                opacity: (currentFocus === 0 || detailsBox.activeFocus) ? 1.0 : 0.28
                                antialiasing: (currentFocus === 0 || detailsBox.activeFocus)
                                Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                            }
                            Text { textFormat: Text.PlainText;
                                id: overviewText
                                anchors { left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom; leftMargin:14; rightMargin:14; topMargin:10; bottomMargin:10 }
                                verticalAlignment: Text.AlignTop
                                color: "#C8CCD8"
                                font.pixelSize: 20
                                wrapMode: Text.WordWrap
                                text: _activeOverviewText()
                                elide: Text.ElideRight
                                maximumLineCount: overviewMaxLines
                            }
                            Keys.onPressed: {
                                if (event.key===Qt.Key_Right) { goToPoster(); event.accepted=true }
                                else if (event.key===Qt.Key_Up) { goTopBarFocus(); event.accepted=true }
                                else if (event.key===Qt.Key_Down) { goToItems(); event.accepted=true }
                                else if (event.key===Qt.Key_Return || event.key===Qt.Key_Enter || event.key===Qt.Key_Select) { openOverviewOverlay(); event.accepted=true }
                            }
                        }
                        Item {
                            id: posterFocus
                            width: posterW
                            height: posterH
                            x: rowBlock.width - (marginR + posterEdgeGap + width)
                            // rowBlock est compensé par pinnedHeroCounterY. Cette
                            // formule garde donc le haut du poster à une position
                            // viewport stable, juste sous l'avatar, même en scroll.
                            y: posterViewportTop - contentTopGap - rowBlock.y
                            visible: hasItem && hasCollectionArt && artStage !== "none"
                            focus: (currentFocus === 2)
                            clip: true
                            onActiveFocusChanged: {
                                if (activeFocus) {
                                    currentFocus = 2
                                    _clearFocusDrivenUI()
                                    _scheduleHeroPosterHq()
                                } else {
                                    _clearHeroPosterHq()
                                }
                            }
                            property bool focused: (currentFocus === 2 || posterFocus.activeFocus)
                            scale: focused ? 1.02 : 1.0
                            transformOrigin: Item.Center
                            Behavior on scale { enabled: !flickBusy; NumberAnimation { duration:120 } }
                            Keys.onPressed: {
                                if (event.key===Qt.Key_Left) { goToOverview(); event.accepted=true }
                                else if (event.key===Qt.Key_Down) { goToItems(); event.accepted=true }
                                else if (event.key===Qt.Key_Up) { goTopBarFocus(); event.accepted=true }
                                else if (event.key===Qt.Key_Return || event.key===Qt.Key_Enter || event.key===Qt.Key_Select) { openPosterOverlay(); event.accepted=true }
                            }
                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked:{ goToPoster(); openPosterOverlay() }
                                onEntered:{ goToPoster() }
                            }
                            Item {
                                anchors.fill: parent
                                // PERF Freebox: plus de layer OpacityMask sur l'art principal.
                                // Le visuel conserve un cadre arrondi premium, mais l'image reste un clip rectangulaire simple.
                                Item {
                                    id: artImageLayer
                                    anchors.fill: parent
                                    anchors.margins: frameMargin()
                                    clip: true
                                    Rectangle {
                                        anchors.fill: parent
                                        color: "#0E1017"
                                        visible: !!artImage.source && ("" + artImage.source).length > 0 && (artImage.status !== Image.Ready)
                                    }
                                    Image {
                                        id: artImage
                                        anchors.fill: parent
                                        asynchronous: true
                                        cache: false
                                        mipmap: false
                                        smooth: artStage === "poster" && !flickBusy
                                        fillMode: (artStage === "poster") ? Image.PreserveAspectCrop : Image.PreserveAspectFit
                                        scale: (artStage === "logo") ? 0.90 : 1.0
                                        // SÉCURITÉ : ne jamais logger artImage.source, collectionLogoUrl ou collectionCoverUrl brut.
                                        source: {
                                            if (!posterReady && !artPreReady) return ""
                                            if (artStage === "logo") return collectionLogoUrl
                                            if (artStage === "poster") return collectionCoverUrl
                                            return ""
                                        }
                                        onStatusChanged: {
                                            if (!posterReady && !artPreReady) { _updateHeroGate(); return }
                                            var src=(""+source);
                                            if (!src || !src.length) { _updateHeroGate(); return }
                                            if (artStage === "logo") {
                                                if (status === Image.Ready) {
                                                    logoOk = true
                                                    logoFailed = false
                                                } else if (status === Image.Error) {
                                                    logoOk = false
                                                    logoFailed = true
                                                    artStage = collectionCoverUrl && collectionCoverUrl.length ? "poster" : "none"
                                                    if (artStage === "none" && currentFocus === 2) goToOverview()
                                                }
                                            } else if (artStage === "poster") {
                                                logoOk = false
                                                logoFailed = true
                                                if (status === Image.Error) {
                                                    artStage = "none"
                                                    if (currentFocus === 2) goToOverview()
                                                }
                                            }
                                            if (status === Image.Ready && artStage === "poster" && posterFocus.activeFocus)
                                                _scheduleHeroPosterHq()
                                            _updateHeroGate()
                                        }
                                        onSourceChanged: {
                                            _clearHeroPosterHq()
                                            _updateHeroGate()
                                        }
                                    }
                                    Image {
                                        id: artImageHq
                                        anchors.fill: parent
                                        asynchronous: true
                                        cache: false
                                        mipmap: false
                                        smooth: artStage === "poster" && !flickBusy
                                        fillMode: Image.PreserveAspectCrop
                                        source: (heroPosterHqArmed && posterFocus.activeFocus && artStage === "poster"
                                                 && !flickBusy && artImage.status === Image.Ready)
                                                ? collectionCoverHqUrl : ""
                                        visible: source !== "" && status === Image.Ready
                                        opacity: visible ? 1.0 : 0.0
                                        Behavior on opacity { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                                    }
                                }
                                Rectangle {
                                    anchors.fill: parent
                                    anchors.margins: frameMargin() + 0.5
                                    radius: Math.max(0, Math.round(Math.min(width, height) * frameRadiusRatio) - 0.5)
                                    color: "transparent"
                                    border.width: frameWidth
                                    border.color: glassBorder
                                    opacity: posterFocus.focused ? 1.0 : 0.0
                                    antialiasing: posterFocus.focused
                                    Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                                }
                            }
                        }
                    }
                    Item {
                        id: seriesSection
                        width: parent.width
                        transform: [ Translate { y: seriesSectionNudgeY } ]
                        visible: (seriesWarm && seriesWarm.length > 0)
                        height: visible ? (sectionHeaderDropY + seriesHeader.implicitHeight
                                             + sectionListGap + seriesList.height + sectionBottomPad) : 0
                        readonly property real _viewportY: contentTopGap + seriesSection.y - (rootFlick ? rootFlick.contentY : 0)
                        readonly property real _clipTop: pinDynamicHero ? Math.max(0, Math.min(seriesSection.height, pinnedHeroReserveH - _viewportY)) : 0
                        readonly property int  cardW: 150
                        readonly property int  cardH: 225
                        readonly property real focusScale: 1.14
                        readonly property int  focusLiftPx: 6
                        readonly property int  pad: 10
                        readonly property int  cellW: cardW + pad * 2
                        readonly property int  cellH: cardH + pad * 2
                                                        + detailCollectionPage.railFocusTopPad(cardH, focusScale, focusLiftPx)
                        readonly property real oversample: 1.30
                        readonly property int  reqW: Math.round(cardW * oversample)
                        readonly property int  reqH: Math.round(cardH * oversample)
                        // PERF Freebox: remplace le layer OpacityMask de section complète par un clip QML simple.
                        // Même découpe verticale sous le hero pinné, sans shader sur toute la rangée.
                        Item {
                            id: seriesClipViewport
                            x: 0
                            y: seriesSection._clipTop
                            width: parent.width
                            height: Math.max(0, parent.height - seriesSection._clipTop)
                            clip: seriesSection._clipTop > 0.5
                            Item {
                                id: seriesClipContent
                                x: 0
                                y: -seriesSection._clipTop
                                width: seriesSection.width
                                height: seriesSection.height
                                                        Column {
                                                            id: seriesHeader
                                                            x: marginL
                                                            y: sectionHeaderDropY
                                                            width: parent.width - marginL - marginR
                                                            spacing: 8
                                                            Row {
                                                                spacing: 10
                                                                Text { textFormat: Text.PlainText; text: "Séries TV de la collection"; color:"#ffe"; font.pixelSize:19; font.bold:true }
                                                                Text { textFormat: Text.PlainText; text: _collectionCountLabel(seriesAll); color:"#DDE1F6"; font.pixelSize:16; visible: text.length>0 }
                                                            }
                                                            Text { textFormat: Text.PlainText; text: ""; color:"#DDE1F6"; font.pixelSize: 14; visible: false; opacity: 0.0 }
                                                        }
                                                        ListView {
                                                            id: seriesList
                                                            property var railSection: seriesSection
                                                            property int railFocus: 3
                                                            property string fallbackGlyph: "\u25A6"
                                                            anchors.top: seriesHeader.bottom
                                                            anchors.topMargin: sectionListGap
                                                            anchors.left: parent.left
                                                            anchors.right: parent.right
                                                            anchors.leftMargin: marginL
                                                            anchors.rightMargin: marginR
                                                            width: parent.width - marginL - marginR
                                                            height: seriesSection.cellH
                                                            orientation: ListView.Horizontal
                                                            clip: true
                                                            focus: (currentFocus === 3)
                                                            keyNavigationWraps: false
                                                            spacing: 0
                                                            boundsBehavior: Flickable.StopAtBounds
                                                            highlightFollowsCurrentItem: true
                                                            highlightRangeMode: ListView.StrictlyEnforceRange
                                                            preferredHighlightBegin: 0
                                                            preferredHighlightEnd: Math.max(0, width - seriesSection.cellW)
                                                            highlightMoveDuration: 140   // PERF QUICK: D-Pad plus nerveux, moins d’animation
                                                            model: seriesWarm
                                                            reuseItems: true
                                                            cacheBuffer: Math.max(0, Math.round((width > 0 ? width : 0) * 0.6))
                                                            onActiveFocusChanged: {
                                                                if (activeFocus) { currentFocus = 3; _updateFocusDrivenUI() }
                                                                else _maybeExitCarousel(3)
                                                            }
                                                            onCountChanged: { if (count > 0 && currentIndex < 0) currentIndex = 0; _updateExtendedLoadingGates() }
                                                            onCurrentIndexChanged: {
                                                                _maybeRequestCollectionMore("series", currentIndex, count)
                                                                if (currentFocus === 3 && activeFocus) {
                                                                    ensureRailVisible(seriesSection, seriesList, 18)
                                                                    _updateFocusDrivenUI()
                                                                }
                                                            }
                                                            onMovingChanged: { if (!moving && !flicking && currentFocus === 3 && activeFocus) _updateFocusDrivenUI() }
                                                            onFlickingChanged: { if (!moving && !flicking && currentFocus === 3 && activeFocus) _updateFocusDrivenUI() }
                                                            Keys.onPressed: {
                                                                if (event.key === Qt.Key_Up) { goToOverview(); event.accepted = true; return }
                                                                if (event.key === Qt.Key_Down) { if (filmsWarm && filmsWarm.length > 0) { goToFilms(); event.accepted = true; return } }
                                                                if (event.key === Qt.Key_Left) {
                                                                    if (currentIndex <= 0) { _requestCollectionWindow("backward", "series"); event.accepted = true; return }
                                                                    currentIndex = Math.max(0, currentIndex - 1)
                                                                    event.accepted = true
                                                                    return
                                                                }
                                                                if (event.key === Qt.Key_Right) {
                                                                    if (count > 0 && currentIndex < count - 1) currentIndex++
                                                                    else _requestCollectionWindow("forward", "series")
                                                                    event.accepted = true
                                                                    return
                                                                }
                                                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                                                                    var it = model && currentIndex>=0 && currentIndex<model.length ? model[currentIndex] : null
                                                                    if (it && it.Id) openChild(it)
                                                                    event.accepted = true
                                                                    return
                                                                }
                                                            }
                                                            delegate: railPosterDelegate
                                                        }
                            }
                        }
                    }
                    Item {
                        id: filmsSection
                        width: parent.width
                        transform: [ Translate { y: filmsSectionNudgeY } ]
                        visible: (itemsLoading || (filmsWarm && filmsWarm.length > 0))
                        height: visible ? (sectionHeaderDropY + filmsHeader.implicitHeight
                                             + sectionListGap + filmsList.height + sectionBottomPad) : 0
                        readonly property real _viewportY: contentTopGap + filmsSection.y - (rootFlick ? rootFlick.contentY : 0)
                        readonly property real _clipTop: pinDynamicHero ? Math.max(0, Math.min(filmsSection.height, pinnedHeroReserveH - _viewportY)) : 0
                        readonly property int  cardW: 150
                        readonly property int  cardH: 225
                        readonly property real focusScale: 1.14
                        readonly property int  focusLiftPx: 6
                        readonly property int  pad: 10
                        readonly property int  cellW: cardW + pad * 2
                        readonly property int  cellH: cardH + pad * 2
                                                        + detailCollectionPage.railFocusTopPad(cardH, focusScale, focusLiftPx)
                        readonly property real oversample: 1.30
                        readonly property int  reqW: Math.round(cardW * oversample)
                        readonly property int  reqH: Math.round(cardH * oversample)
                        // PERF Freebox: clip vertical simple au lieu d'un OpacityMask de section complète.
                        Item {
                            id: filmsClipViewport
                            x: 0
                            y: filmsSection._clipTop
                            width: parent.width
                            height: Math.max(0, parent.height - filmsSection._clipTop)
                            clip: filmsSection._clipTop > 0.5
                            Item {
                                id: filmsClipContent
                                x: 0
                                y: -filmsSection._clipTop
                                width: filmsSection.width
                                height: filmsSection.height
                                                        Column {
                                                            id: filmsHeader
                                                            x: marginL
                                                            y: sectionHeaderDropY
                                                            width: parent.width - marginL - marginR
                                                            spacing: 8
                                                            Row {
                                                                spacing: 10
                                                                Text { textFormat: Text.PlainText; text: "Films de la collection"; color:"#ffe"; font.pixelSize:19; font.bold:true }
                                                                Text { textFormat: Text.PlainText; text: _collectionCountLabel(filmsAll); color:"#DDE1F6"; font.pixelSize:16; visible: text.length>0 }
                                                            }
                                                            Text { textFormat: Text.PlainText; text: (itemsLoading || collectionChildrenLoadingMore) ? "Chargement…" : ""; color:"#DDE1F6"; font.pixelSize: 14; visible: text.length > 0; opacity: 0.9 }
                                                        }
                                                        ListView {
                                                            id: filmsList
                                                            property var railSection: filmsSection
                                                            property int railFocus: 4
                                                            property string fallbackGlyph: "\u25A3"
                                                            anchors.top: filmsHeader.bottom
                                                            anchors.topMargin: sectionListGap
                                                            anchors.left: parent.left
                                                            anchors.right: parent.right
                                                            anchors.leftMargin: marginL
                                                            anchors.rightMargin: marginR
                                                            width: parent.width - marginL - marginR
                                                            height: filmsSection.cellH
                                                            orientation: ListView.Horizontal
                                                            clip: true
                                                            focus: (currentFocus === 4)
                                                            keyNavigationWraps: false
                                                            spacing: 0
                                                            boundsBehavior: Flickable.StopAtBounds
                                                            highlightFollowsCurrentItem: true
                                                            highlightRangeMode: ListView.StrictlyEnforceRange
                                                            preferredHighlightBegin: 0
                                                            preferredHighlightEnd: Math.max(0, width - filmsSection.cellW)
                                                            highlightMoveDuration: 140   // PERF QUICK: D-Pad plus nerveux, moins d’animation
                                                            model: filmsWarm
                                                            reuseItems: true
                                                            cacheBuffer: Math.max(0, Math.round((width > 0 ? width : 0) * 0.6))
                                                            onActiveFocusChanged: {
                                                                if (activeFocus) { currentFocus = 4; _updateFocusDrivenUI() }
                                                                else _maybeExitCarousel(4)
                                                            }
                                                            onCountChanged: { if (count > 0 && currentIndex < 0) currentIndex = 0; _updateExtendedLoadingGates() }
                                                            onCurrentIndexChanged: {
                                                                _maybeRequestCollectionMore("films", currentIndex, count)
                                                                if (currentFocus === 4 && activeFocus) {
                                                                    ensureRailVisible(filmsSection, filmsList, 18)
                                                                    _updateFocusDrivenUI()
                                                                }
                                                            }
                                                            onMovingChanged: { if (!moving && !flicking && currentFocus === 4 && activeFocus) _updateFocusDrivenUI() }
                                                            onFlickingChanged: { if (!moving && !flicking && currentFocus === 4 && activeFocus) _updateFocusDrivenUI() }
                                                            Keys.onPressed: {
                                                                if (event.key === Qt.Key_Up) {
                                                                    if (seriesWarm && seriesWarm.length > 0) { goToSeries(); event.accepted = true; return }
                                                                    goToOverview(); event.accepted = true; return
                                                                }
                                                                if (event.key === Qt.Key_Left) {
                                                                    if (currentIndex <= 0) { _requestCollectionWindow("backward", "films"); event.accepted = true; return }
                                                                    currentIndex = Math.max(0, currentIndex - 1)
                                                                    event.accepted = true
                                                                    return
                                                                }
                                                                if (event.key === Qt.Key_Right) {
                                                                    if (count > 0 && currentIndex < count - 1) currentIndex++
                                                                    else _requestCollectionWindow("forward", "films")
                                                                    event.accepted = true
                                                                    return
                                                                }
                                                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                                                                    var it = model && currentIndex>=0 && currentIndex<model.length ? model[currentIndex] : null
                                                                    if (it && it.Id) openChild(it)
                                                                    event.accepted = true
                                                                    return
                                                                }
                                                            }
                                                            delegate: railPosterDelegate
                                                        }
                            }
                        }
                    }
                    Item { width: parent.width; height: bottomScrollPad }
                }
            }
        }
        Components.ClockHUD {
            id: clockHud
            z: 3000
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: 20
            anchors.rightMargin: 24
            visible: !visualLoading && overlayMode==="none"
            opacity: (clockHud && clockHud.hudOpacity !== undefined) ? clockHud.hudOpacity : 1.0
            Component.onCompleted: detailCollectionPage._syncClockHud()
        }
        Connections {
            target: clockHud
            ignoreUnknownSignals: true
            onRequestFocusBelow: detailCollectionPage.restoreFocusFromHud()
            onActivated: detailCollectionPage.restoreFocusFromHud()
            onAvatarActivated: detailCollectionPage.restoreFocusFromHud()
        }
    }
    FocusScope {
        id: loadingOverlay
        anchors.fill: parent
        z: 999999
        visible: visualLoading
        enabled: visualLoading
        focus: visualLoading
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        Rectangle { anchors.fill: parent; color: "#000000" }
        // Spinner/texte plein écran centralisés dans ShellPage.

        MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: {} }
        Keys.onPressed: {
            if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
                _goBack()
                event.accepted = true
            } else event.accepted = true
        }
    }
    Keys.onPressed: {
        if (visualLoading) { event.accepted = true; return }
        if (currentFocus === -1 && event.key === Qt.Key_Down) {
            restoreFocusFromHud()
            event.accepted = true
            return
        }
        if (overlayMode !== "none" && event.key !== Qt.Key_Back && event.key !== Qt.Key_Escape) { event.accepted = true; return }
        if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
            if (overlayMode !== "none") { closeOverlay(); event.accepted = true; return }
            _goBack()
            event.accepted = true
        }
    }
    function _currentArtUrl(){
        if (logoOk && collectionLogoUrl && collectionLogoUrl.length) return collectionLogoUrl
        if (collectionCoverUrl && collectionCoverUrl.length) return collectionCoverUrl
        if (collectionLogoUrl && collectionLogoUrl.length) return collectionLogoUrl
        return ""
    }
    function openOverlay(mode, payload){
        if (!hasItem) return
        overlayMode = mode
        overlayData = payload || ({})
    }
    function openPosterOverlay(){
        var u = _currentArtUrl()
        if (!u || !u.length) return
        openOverlay("poster", { posterUrl: u })
    }
    function _overviewReaderImageUrl(){
        return item ? Jellyfin.itemBackdropOrPrimaryUrl(serverUrl, item, {
            fillWidth: 720, fillHeight: 405, quality: 88, format: "jpg"
        }) : ""
    }
    function openOverviewOverlay(){
        if (!hasItem) return
        var meta = ["COLLECTION"]
        var dateLine = MediaCatalog.mediaDateLineShortFr(item)
        if (dateLine && dateLine.length) meta.push(dateLine)
        openOverlay("overview", {
            readerStyle: "media",
            title: (item && item.Name) ? String(item.Name) : "Résumé",
            meta: meta.join("  •  "),
            posterUrl: _overviewReaderImageUrl() || collectionCoverUrl || _currentArtUrl(),
            overview: (item && item.Overview) ? MediaCatalog.normalizeOverviewLine(item.Overview) : ""
        })
    }
    function closeOverlay(){
        overlayMode = "none"
        overlayData = ({})
        Qt.callLater(function(){
            if (isLoading) return
            goToOverview()
        })
    }
    function openChild(it){
        if (!it || !it.Id || typeof requestNavigation !== "function") return
        var t = (it.Type || it.CollectionType || "").toLowerCase()
        var isSeries = (t === "series" || t === "tvshow" || t === "tvshows" || t === "season" || t === "episode")
        var page = isSeries ? "detailSeriePage.qml" : "detailMoviePage.qml"
        requestNavigation(_navRoute(page, { itemId: it.Id }))
    }
}
