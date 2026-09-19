// qml/pages/PersonalMediaPage.qml — visionneuse des médias personnels.
// La grille, le tri, la pagination, le backdrop et le focus D-Pad sont fournis
// par moviepage.qml en mode "personal" ; cette page ne conserve que le viewer.
import QtQuick 2.15
import "../components" as Components
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/MediaCatalog.js" as MediaCatalog

Item {
    id: personalMediaPage
    width: parent ? parent.width : 1920
    height: parent ? parent.height : 1080
    focus: true

    property string accessToken
    property string userId
    property string serverUrl
    property string folderId
    property string browserTitle: ""
    property string libraryMode: "personal"
    property string userName
    property string userImageTag
    property var fbx
    property string itemId
    property string playbackDeviceMode: "auto"
    property var shared
    property int startIndex: -1
    property int restoreIndex: -1
    property real restoreY: -1

    signal requestNavigation(string page)
    signal requestBackToMenu()
    signal requestPlay(string itemId, string accessToken, string userId,
                       string serverUrl, string itemTitle)

    readonly property var browser: browserLoader.item
    readonly property var folderItems: browser && browser.catalogItems ? browser.catalogItems : []
    readonly property bool folderPageHasMore: !!(browser && browser.catalogHasMore)
    readonly property bool folderPageHasPrevious: !!(browser && browser.catalogHasPrevious)
    readonly property bool folderPageInFlight: !!(browser && browser.catalogPageInFlight)
    readonly property int folderWindowStartIndex: browser ? browser.catalogWindowStart : 0
    readonly property int currentIndex: browser ? browser.currentIndex : -1
    readonly property bool shellLoading: !viewerOpen
                                         && (_entrySearchPending
                                             || !browser
                                             || browser.shellLoading)
    readonly property string shellLoadingError: ""

    property bool viewerOpen: false
    property int viewerIndex: 0
    property bool viewerSlideLocked: false
    readonly property int viewerSlideMs: 220
    readonly property int viewerPreloadRadius: 1
    readonly property int viewerLoadMoreThreshold: 6
    readonly property int viewerSafeMargin: 42
    readonly property int viewerBaseMaxW: 1920
    readonly property int viewerBaseMaxH: 1080
    readonly property bool viewerUsesDevialetTier:
        String(playbackDeviceMode || "").toLowerCase() === "devialet"
    readonly property int viewerHighMaxW: viewerUsesDevialetTier ? 3840 : 2560
    readonly property int viewerHighMaxH: viewerUsesDevialetTier ? 2160 : 1440
    property bool _photoHighResArmed: false
    readonly property real photoHighResZoomThreshold: 1.12

    property real photoZoom: 1.0
    property real photoPanX: 0.0
    property real photoPanY: 0.0
    property int _photoHoldKey: 0
    property bool _photoHoldTriggered: false
    readonly property real photoZoomMin: 1.0
    readonly property real photoZoomMax: 4.0
    readonly property real photoZoomUnitsPerSecond: 0.75
    readonly property real photoPanPxPerSecond: 520.0
    readonly property int photoPanHoldMs: 1000
    readonly property int photoPanStepPx: 96

    property bool _entrySearchPending: false
    property bool _pendingViewerOpen: false
    property string _pendingViewerId: ""
    property int _pendingViewerGlobalIndex: -1
    property int _restoreRequestedGlobalIndex: -1
    property string _consumedEntryItemId: ""
    property string _viewerAnchorId: ""
    property int _viewerPendingDelta: 0

    onPhotoZoomChanged: {
        if (photoZoomContinuousAnim.running
                && (Math.abs(photoPanX) > 0.01 || Math.abs(photoPanY) > 0.01))
            _clampPhotoPan()
        if (photoZoomContinuousAnim.running) {
            if (photoHighResTimer.running) photoHighResTimer.stop()
            if (_photoHighResArmed) _photoHighResArmed = false
        } else {
            _schedulePhotoHighResolution()
        }
    }

    function _sharedNavApi() {
        try { return shared && shared.__redefinNavApi ? shared.__redefinNavApi : null }
        catch(e) { return null }
    }
    function _storeSensitiveNavContext() {
        var api = _sharedNavApi()
        return api && api.storeTarget ? api.storeTarget(personalMediaPage) : false
    }
    function _stateKey() { return "personalmedia|" + (folderId || "") }
    function _sharedBucket() {
        if (!shared) return null
        if (!shared.__focusState) shared.__focusState = {}
        if (!shared.__focusState.personalMedia) shared.__focusState.personalMedia = {}
        return shared.__focusState.personalMedia
    }
    function _readViewerState() {
        var b = _sharedBucket()
        return MediaCatalog.browserReadSharedState(b, b ? _stateKey() : "")
    }
    function _writeViewerState() {
        if (browser && browser.saveCatalogState) browser.saveCatalogState()
        var b = _sharedBucket()
        if (!b) return
        var it = _viewerItem()
        var globalIndex = browser && browser.catalogGlobalIndex
                ? browser.catalogGlobalIndex(viewerIndex) : viewerIndex
        Jellyfin.putBoundedMemory(b, _stateKey(), {
            index: browser ? browser.currentIndex : -1,
            y: browser ? Math.floor(browser.catalogContentY || 0) : 0,
            windowStart: folderWindowStartIndex,
            viewerOpen: viewerOpen === true,
            viewerIndex: viewerOpen ? globalIndex : -1,
            viewerItemId: (viewerOpen && it && it.Id) ? String(it.Id) : ""
        }, 48)
    }

    function _globalIndexForLocal(localIndex) {
        return browser && browser.catalogGlobalIndex
                ? browser.catalogGlobalIndex(localIndex) : localIndex
    }
    function _windowKnownEnd() {
        return browser ? Math.max(0, Number(browser.catalogKnownEnd) | 0) : 0
    }
    function _findItemIndexById(id) {
        return browser && browser.findCatalogItemIndex
                ? browser.findCatalogItemIndex(String(id || "")) : -1
    }
    function itemWithDetailForHeader(base) {
        return browser && browser.catalogItemWithDetail
                ? browser.catalogItemWithDetail(base) : base
    }
    function forceInitialFocus() {
        if (viewerOpen) {
            try { viewerLayer.forceActiveFocus(Qt.OtherFocusReason) } catch(e0) {}
            return true
        }
        if (!browser || !browser.forceInitialFocus) return false
        browser.forceInitialFocus()
        return true
    }
    function restoreFocusAfterShellCurtain() {
        if (viewerOpen) {
            try { viewerLayer.forceActiveFocus(Qt.OtherFocusReason) } catch(e0) {}
            return true
        }
        if (_entrySearchPending) return false
        return !!(browser && browser.restoreFocusAfterShellCurtain
                  && browser.restoreFocusAfterShellCurtain())
    }

    function _armViewerTarget(id, useSavedState) {
        id = String(id || "")
        var st = _readViewerState()
        _pendingViewerOpen = true
        _pendingViewerId = id || (useSavedState && st ? String(st.viewerItemId || "") : "")
        var savedIndex = useSavedState && st ? Number(st.viewerIndex) : -1
        _pendingViewerGlobalIndex = savedIndex >= 0 ? (savedIndex | 0) : -1
        _restoreRequestedGlobalIndex = -1
        _entrySearchPending = true
        if (browser && _pendingViewerGlobalIndex >= 0 && browser.restoreCatalogGlobalIndex) {
            _restoreRequestedGlobalIndex = _pendingViewerGlobalIndex
            browser.restoreCatalogGlobalIndex(_pendingViewerGlobalIndex)
        }
        viewerResolveTimer.restart()
        return true
    }
    function _resolvePendingViewer() {
        if (!_pendingViewerOpen || !browser) return
        var idx = _pendingViewerId ? _findItemIndexById(_pendingViewerId) : -1
        if (idx < 0 && _pendingViewerGlobalIndex >= folderWindowStartIndex
                && _pendingViewerGlobalIndex < _windowKnownEnd())
            idx = _pendingViewerGlobalIndex - folderWindowStartIndex
        if (idx >= 0 && idx < folderItems.length) {
            _pendingViewerOpen = false
            _entrySearchPending = false
            _restoreRequestedGlobalIndex = -1
            openViewer(idx)
            return
        }
        if (folderPageInFlight || browser.shellLoading) return
        if (_pendingViewerGlobalIndex >= 0
                && (_pendingViewerGlobalIndex < folderWindowStartIndex
                    || _pendingViewerGlobalIndex >= _windowKnownEnd())) {
            if (_restoreRequestedGlobalIndex !== _pendingViewerGlobalIndex
                    && browser.restoreCatalogGlobalIndex) {
                _restoreRequestedGlobalIndex = _pendingViewerGlobalIndex
                browser.restoreCatalogGlobalIndex(_pendingViewerGlobalIndex)
                return
            }
        }
        if (_pendingViewerId && folderPageHasMore) {
            browser.requestCatalogPage(1)
            return
        }
        if (_pendingViewerGlobalIndex >= 0 && folderPageHasPrevious) {
            browser.requestCatalogPage(-1)
            return
        }
        _pendingViewerOpen = false
        _entrySearchPending = false
        _pendingViewerId = ""
        _pendingViewerGlobalIndex = -1
    }
    function _onCatalogChanged() {
        if (viewerOpen && _viewerAnchorId) {
            var anchorIndex = _findItemIndexById(_viewerAnchorId)
            if (anchorIndex >= 0) viewerIndex = anchorIndex
            _viewerAnchorId = ""
            Qt.callLater(_viewerSnap)
        }
        viewerResolveTimer.restart()
        if (viewerOpen && _viewerPendingDelta !== 0 && !folderPageInFlight) {
            var delta = _viewerPendingDelta
            _viewerPendingDelta = 0
            Qt.callLater(function() {
                personalMediaPage._viewerSnap()
                personalMediaPage.viewerGo(delta)
            })
        }
    }

    Timer {
        id: viewerResolveTimer
        interval: 0
        repeat: false
        onTriggered: personalMediaPage._resolvePendingViewer()
    }

    Loader {
        id: browserLoader
        anchors.fill: parent
        z: 0
        source: "moviepage.qml"
        onLoaded: {
            item.accessToken = Qt.binding(function(){ return personalMediaPage.accessToken })
            item.userId = Qt.binding(function(){ return personalMediaPage.userId })
            item.serverUrl = Qt.binding(function(){ return personalMediaPage.serverUrl })
            item.folderId = Qt.binding(function(){ return personalMediaPage.folderId })
            item.browserTitle = Qt.binding(function(){ return personalMediaPage.browserTitle })
            item.libraryMode = "personal"
            item.userName = Qt.binding(function(){ return personalMediaPage.userName })
            item.userImageTag = Qt.binding(function(){ return personalMediaPage.userImageTag })
            item.fbx = Qt.binding(function(){ return personalMediaPage.fbx })
            item.shared = Qt.binding(function(){ return personalMediaPage.shared })

            // Propager explicitement le modèle Freebox au MoviePage interne.
            // MoviePage applique ainsi sa pagination optimisée :
            // - Révolution : 50 éléments/page
            // - Devialet   : 220 éléments/page
            // Sans ce binding, le navigateur interne restait sur "auto" et
            // utilisait donc la pagination Devialet même sur Révolution.
            if (item.hasOwnProperty("playbackDeviceMode")) {
                item.playbackDeviceMode = Qt.binding(function(){
                    return personalMediaPage.playbackDeviceMode
                })
            }

            item.externalModalOpen = Qt.binding(function(){ return personalMediaPage.viewerOpen })
            if (personalMediaPage.startIndex >= 0) item.startIndex = personalMediaPage.startIndex
            if (personalMediaPage.restoreIndex >= 0) item.restoreIndex = personalMediaPage.restoreIndex
            if (personalMediaPage.restoreY >= 0) item.restoreY = personalMediaPage.restoreY
            Qt.callLater(function(){ viewerResolveTimer.restart() })
        }
    }
    Connections {
        target: browserLoader.item
        ignoreUnknownSignals: true
        function onRequestNavigation(page) { personalMediaPage.requestNavigation(page) }
        function onRequestBackToMenu() { personalMediaPage.requestBackToMenu() }
        function onRequestPersonalViewer(index) { personalMediaPage.openViewer(index) }
        function onCatalogItemsChanged() { personalMediaPage._onCatalogChanged() }
        function onCatalogPageInFlightChanged() { viewerResolveTimer.restart() }
        function onCatalogHasMoreChanged() { viewerResolveTimer.restart() }
        function onCatalogHasPreviousChanged() { viewerResolveTimer.restart() }
    }

    function isVideoItem(it) {
        var t = it && it.Type ? String(it.Type).toLowerCase() : ""
        return t === "video" || t === "movie" || t === "musicvideo"
    }
    function isPhotoItem(it) {
        return !!(it && String(it.Type || "").toLowerCase() === "photo")
    }
    function _viewerClampIndex(idx){ var n = folderItems ? folderItems.length : 0; return n > 0 ? Math.max(0, Math.min(n - 1, Number(idx) | 0)) : 0; }
    function _viewerItem(){ return (folderItems && viewerIndex >= 0 && viewerIndex < folderItems.length) ? folderItems[viewerIndex] : null; }
    function _viewerImageTag(it, kind) {
        try {
            var tags = it && it.ImageTags ? it.ImageTags : {}
            if (kind === "Primary") return String(tags.Primary || it.PrimaryImageTag || "")
            if (kind === "Thumb") return String(tags.Thumb || it.ThumbImageTag || "")
            if (kind === "Backdrop") {
                var a = it && it.BackdropImageTags ? it.BackdropImageTags : []
                return a && a.length ? String(a[0] || "") : ""
            }
        } catch(e) {}
        return ""
    }
    function viewerImageUrl(it, highResolution) {
        if (!it || !it.Id || !serverUrl) return ""
        var photo = isPhotoItem(it)
        var high = photo && highResolution === true
        var w = high ? viewerHighMaxW : viewerBaseMaxW
        var h = high ? viewerHighMaxH : viewerBaseMaxH
        var kind = "Primary"
        var tag = _viewerImageTag(it, kind)
        if (!tag) { kind = "Thumb"; tag = _viewerImageTag(it, kind) }
        if (!tag) { kind = "Backdrop"; tag = _viewerImageTag(it, kind) }
        if (!tag) return ""
        // JPEG explicite : Qt 5.15 de la Freebox ne décode pas WebP de façon fiable.
        return Jellyfin.itemImageUrl(serverUrl, it.Id, kind, tag, {
            maxWidth: w,
            maxHeight: h,
            quality: high ? 88 : 84,
            format: "jpg"
        })
    }
    function _viewerCurrentIsPhoto() { return isPhotoItem(_viewerItem()) }
    function _schedulePhotoHighResolution() {
        photoHighResTimer.stop()
        _photoHighResArmed = false
        if (viewerOpen && _viewerCurrentIsPhoto() && photoZoom >= photoHighResZoomThreshold)
            photoHighResTimer.restart()
    }
    function _resetPhotoView() {
        photoHighResTimer.stop(); _photoHighResArmed=false
        photoPanHoldTimer.stop(); _stopPhotoZoomAnimation(); _stopPhotoPanAnimation(); _photoHoldKey=0; _photoHoldTriggered=false
        photoZoom=photoZoomMin; photoPanX=0; photoPanY=0
    }
    function _photoBaseSize() {
        var vw=Math.max(1,viewerLayer?viewerLayer.width:width), vh=Math.max(1,viewerLayer?viewerLayer.height:height)
        var it=itemWithDetailForHeader(_viewerItem()), iw=Number(it&&(it.Width||it.ImageWidth)||0), ih=Number(it&&(it.Height||it.ImageHeight)||0)
        if (!(iw>0 && ih>0)) return ({w:vw,h:vh})
        var fit=Math.min(vw/iw,vh/ih); return ({w:iw*fit,h:ih*fit})
    }
    function _photoPanLimits() {
        var b=_photoBaseSize(), vw=Math.max(1,viewerLayer?viewerLayer.width:width), vh=Math.max(1,viewerLayer?viewerLayer.height:height)
        return ({x:Math.max(0,(b.w*photoZoom-vw)*0.5), y:Math.max(0,(b.h*photoZoom-vh)*0.5)})
    }
    function _clampPhotoPan(){ var l=_photoPanLimits(); photoPanX=Math.max(-l.x,Math.min(l.x,photoPanX)); photoPanY=Math.max(-l.y,Math.min(l.y,photoPanY)); }
    function _stopPhotoZoomAnimation() {
        if (photoZoomContinuousAnim.running) photoZoomContinuousAnim.stop()
        if (photoZoom <= photoZoomMin + 0.001) {
            photoZoom = photoZoomMin
            photoPanX = 0
            photoPanY = 0
        } else {
            _clampPhotoPan()
        }
    }
    function _startPhotoZoomContinuous(direction) {
        if (!_viewerCurrentIsPhoto()) return false
        _stopPhotoZoomAnimation(); var target=direction>0?photoZoomMax:photoZoomMin, delta=Math.abs(target-photoZoom)
        if (delta<0.001) return false
        photoZoomContinuousAnim.from=photoZoom; photoZoomContinuousAnim.to=target
        photoZoomContinuousAnim.duration=Math.max(80,Math.round((delta/photoZoomUnitsPerSecond)*1000)); photoZoomContinuousAnim.start(); return true
    }
    function _stopPhotoPanAnimation() { if (photoPanContinuousAnim.running) photoPanContinuousAnim.stop(); _clampPhotoPan() }
    function _startPhotoPanContinuous(key) {
        if (!_viewerCurrentIsPhoto() || photoZoom<=photoZoomMin+0.001) return false
        _stopPhotoPanAnimation(); var l=_photoPanLimits(), vertical=key===Qt.Key_Up||key===Qt.Key_Down
        var current=vertical?photoPanY:photoPanX, target=vertical?(key===Qt.Key_Up?l.y:-l.y):(key===Qt.Key_Left?l.x:-l.x)
        var delta=Math.abs(target-current); if (delta<0.5) return false
        photoPanContinuousAnim.property=vertical?"photoPanY":"photoPanX"; photoPanContinuousAnim.from=current; photoPanContinuousAnim.to=target
        photoPanContinuousAnim.duration=Math.max(80,Math.round((delta/photoPanPxPerSecond)*1000)); photoPanContinuousAnim.start(); return true
    }
    function panPhotoByKey(key) {
        if (!_viewerCurrentIsPhoto() || photoZoom<=photoZoomMin+0.001) return false
        var l=_photoPanLimits(), s=photoPanStepPx
        if (key===Qt.Key_Left) photoPanX=Math.min(l.x,photoPanX+s); else if (key===Qt.Key_Right) photoPanX=Math.max(-l.x,photoPanX-s)
        else if (key===Qt.Key_Up) photoPanY=Math.min(l.y,photoPanY+s); else if (key===Qt.Key_Down) photoPanY=Math.max(-l.y,photoPanY-s); else return false
        return true
    }
    function _isPhotoZoomKey(key){ return key===Qt.Key_ChannelUp || key===Qt.Key_PageUp || key===Qt.Key_ChannelDown || key===Qt.Key_PageDown; }
    function _photoZoomDirection(key) { return (key===Qt.Key_ChannelUp || key===Qt.Key_PageUp) ? 1 : -1 }
    function _beginPhotoHold(key) {
        if (!_viewerCurrentIsPhoto() || photoZoom<=photoZoomMin+0.001) return false
        if (key!==Qt.Key_Left && key!==Qt.Key_Right && key!==Qt.Key_Up && key!==Qt.Key_Down) return false
        _photoHoldKey=key; _photoHoldTriggered=false; _stopPhotoZoomAnimation(); _stopPhotoPanAnimation(); photoPanHoldTimer.restart(); return true
    }
    function _endPhotoHold(key) {
        if (key!==_photoHoldKey) return false
        photoPanHoldTimer.stop(); _stopPhotoPanAnimation(); var wasLong=_photoHoldTriggered; _photoHoldKey=0; _photoHoldTriggered=false
        if (!wasLong) panPhotoByKey(key); return true
    }
    Timer {
        id: photoHighResTimer
        interval: 260
        repeat: false
        onTriggered: {
            if (personalMediaPage.viewerOpen && personalMediaPage._viewerCurrentIsPhoto() &&
                    personalMediaPage.photoZoom >= personalMediaPage.photoHighResZoomThreshold)
                personalMediaPage._photoHighResArmed = true
        }
    }
    Timer {
        id: photoPanHoldTimer
        interval: personalMediaPage.photoPanHoldMs
        repeat: false
        onTriggered: {
            if (!personalMediaPage.viewerOpen || !personalMediaPage._viewerCurrentIsPhoto() || personalMediaPage._photoHoldKey===0) return
            personalMediaPage._photoHoldTriggered=true; personalMediaPage._startPhotoPanContinuous(personalMediaPage._photoHoldKey)
        }
    }
    NumberAnimation {
        id: photoZoomContinuousAnim; target: personalMediaPage; property: "photoZoom"; easing.type: Easing.Linear
        onStopped: {
            if (personalMediaPage.photoZoom<=personalMediaPage.photoZoomMin+0.001) { personalMediaPage.photoZoom=personalMediaPage.photoZoomMin; personalMediaPage.photoPanX=0; personalMediaPage.photoPanY=0 }
            else personalMediaPage._clampPhotoPan()
            personalMediaPage._schedulePhotoHighResolution()
        }
    }
    NumberAnimation {
        id: photoPanContinuousAnim; target: personalMediaPage; property: "photoPanX"; easing.type: Easing.Linear
        onStopped: personalMediaPage._clampPhotoPan()
    }
    function _viewerTargetX(idx) { return Math.max(0, _viewerClampIndex(idx) * Math.max(1, viewerStrip.width)) }
    function _viewerSnap() {
        if (!viewerStrip) return
        viewerSlide.stop()
        viewerStrip.contentX = _viewerTargetX(viewerIndex)
    }

    function _viewerMaybeLoadMore() {
        if (!viewerOpen || folderPageInFlight || !folderItems || !folderItems.length || !browser) return
        var it = _viewerItem()
        _viewerAnchorId = it && it.Id ? String(it.Id) : ""
        if (folderPageHasPrevious && viewerIndex <= viewerLoadMoreThreshold) {
            browser.requestCatalogPage(-1)
            return
        }
        if (folderPageHasMore && viewerIndex >= Math.max(0, folderItems.length - viewerLoadMoreThreshold))
            browser.requestCatalogPage(1)
    }
    function openViewer(index) {
        if (!folderItems || !folderItems.length) return false
        _pendingViewerOpen = false
        _entrySearchPending = false
        _pendingViewerId = ""
        _pendingViewerGlobalIndex = -1
        viewerIndex = _viewerClampIndex(index)
        if (browser && browser.focusCatalogIndex) browser.focusCatalogIndex(viewerIndex)
        _resetPhotoView()
        viewerOpen = true
        viewerSlideLocked = false
        _writeViewerState()
        Qt.callLater(function() {
            personalMediaPage._viewerSnap()
            personalMediaPage._viewerMaybeLoadMore()
            try { viewerLayer.forceActiveFocus(Qt.OtherFocusReason) } catch(e) {}
        })
        return true
    }
    function closeViewer() {
        if (!viewerOpen) return
        var idx = _viewerClampIndex(viewerIndex)
        viewerSlide.stop()
        _resetPhotoView()
        viewerOpen = false
        viewerSlideLocked = false
        _viewerPendingDelta = 0
        _viewerAnchorId = ""
        if (browser && browser.focusCatalogIndex) browser.focusCatalogIndex(idx)
        _writeViewerState()
        Qt.callLater(forceInitialFocus)
    }
    function viewerGo(delta) {
        if (!viewerOpen || viewerSlideLocked || !folderItems || !folderItems.length) return
        delta = delta < 0 ? -1 : 1
        var target = _viewerClampIndex(viewerIndex + delta)
        if (target === viewerIndex) {
            if ((delta > 0 && folderPageHasMore) || (delta < 0 && folderPageHasPrevious)) {
                var it = _viewerItem()
                _viewerAnchorId = it && it.Id ? String(it.Id) : ""
                _viewerPendingDelta = delta
                browser.requestCatalogPage(delta)
            }
            return
        }
        _resetPhotoView()
        viewerIndex = target
        if (browser && browser.focusCatalogIndex) browser.focusCatalogIndex(target)
        _writeViewerState()
        viewerSlideLocked = true
        viewerSlide.stop()
        viewerSlide.from = viewerStrip.contentX
        viewerSlide.to = _viewerTargetX(target)
        viewerSlide.start()
        _viewerMaybeLoadMore()
    }
    function playViewerVideo() {
        var it = _viewerItem()
        if (!isVideoItem(it) || !it.Id) return false
        _writeViewerState()
        _storeSensitiveNavContext()
        requestPlay(String(it.Id), accessToken || "", userId || "",
                    serverUrl || "", String(it.Name || ""))
        return true
    }
    function requestFocusItem(id) {
        return _armViewerTarget(String(id || ""), true)
    }

    /* ========= Visionneuse plein écran intégrée ========= */
    FocusScope {
        id: viewerLayer
        anchors.fill: parent
        z: 20000
        visible: personalMediaPage.viewerOpen
        enabled: visible
        focus: visible
        readonly property var currentBaseItem: personalMediaPage._viewerItem()
        readonly property var currentItem: personalMediaPage.itemWithDetailForHeader(currentBaseItem)
        readonly property var currentStreamInfo: MediaCatalog.personalMediaStreamInfo(currentItem)
        readonly property var currentTagChips: MediaCatalog.personalMediaTagChips(currentStreamInfo)
        Rectangle { anchors.fill: parent; color: "#000000" }
        ListView {
            id: viewerStrip
            anchors.fill: parent
            model: personalMediaPage.folderItems
            orientation: ListView.Horizontal
            interactive: false
            keyNavigationEnabled: false
            boundsBehavior: Flickable.StopAtBounds
            spacing: 0
            clip: true
            reuseItems: true
            cacheBuffer: Math.round(width * 0.40)
            delegate: Item {
                id: viewerCard
                width: viewerStrip.width
                height: viewerStrip.height
                property var mediaData: modelData
                readonly property bool nearCurrent: Math.abs(index - personalMediaPage.viewerIndex) <= personalMediaPage.viewerPreloadRadius
                readonly property bool current: index === personalMediaPage.viewerIndex
                readonly property bool video: personalMediaPage.isVideoItem(mediaData)
                Rectangle { anchors.fill: parent; color: "#000000" }
                Image {
                    id: viewerImage
                    anchors.fill: parent
                    source: viewerCard.nearCurrent ? personalMediaPage.viewerImageUrl(viewerCard.mediaData, false) : ""
                    asynchronous: true; cache: false; mipmap: false
                    smooth: viewerCard.current
                    fillMode: Image.PreserveAspectFit
                    transformOrigin: Item.Center
                    scale: (viewerCard.current && !viewerCard.video) ? personalMediaPage.photoZoom : 1.0
                    transform: Translate {
                        x: (viewerCard.current && !viewerCard.video) ? personalMediaPage.photoPanX : 0
                        y: (viewerCard.current && !viewerCard.video) ? personalMediaPage.photoPanY : 0
                        Behavior on x { enabled: !photoPanContinuousAnim.running; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                        Behavior on y { enabled: !photoPanContinuousAnim.running; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                    }
                    sourceSize.width: personalMediaPage.viewerBaseMaxW
                    sourceSize.height: personalMediaPage.viewerBaseMaxH
                    opacity: status === Image.Ready ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                }
                Image {
                    id: viewerHighImage
                    anchors.fill: parent
                    source: (viewerCard.current
                             && !viewerCard.video
                             && personalMediaPage._photoHighResArmed
                             && String(viewerImage.source || "") !== "")
                            ? personalMediaPage.viewerImageUrl(viewerCard.mediaData, true) : ""
                    asynchronous: true; cache: false; mipmap: false; smooth: true
                    fillMode: Image.PreserveAspectFit
                    transformOrigin: Item.Center
                    scale: viewerCard.current ? personalMediaPage.photoZoom : 1.0
                    transform: Translate {
                        x: viewerCard.current ? personalMediaPage.photoPanX : 0
                        y: viewerCard.current ? personalMediaPage.photoPanY : 0
                        Behavior on x { enabled: !photoPanContinuousAnim.running; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                        Behavior on y { enabled: !photoPanContinuousAnim.running; NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                    }
                    sourceSize.width: personalMediaPage.viewerHighMaxW
                    sourceSize.height: personalMediaPage.viewerHighMaxH
                    opacity: status === Image.Ready ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                }
                Rectangle {
                    id: viewerPlayCircle
                    anchors.centerIn: parent
                    width: 118; height: 118; radius: 59
                    color: Qt.rgba(0.02, 0.025, 0.04, 0.82)
                    border.width: 2; border.color: "#E6FFFFFF"
                    visible: viewerCard.video && viewerCard.current
                    scale: 1.0
                    Canvas {
                        anchors.centerIn: parent; width: 42; height: 52
                        onPaint: {
                            var c=getContext("2d"); c.clearRect(0,0,width,height); c.fillStyle="#FFFFFF"
                            c.beginPath(); c.moveTo(7,4); c.lineTo(38,26); c.lineTo(7,48); c.closePath(); c.fill()
                        }
                    }
                }
                Column {
                    anchors.centerIn: parent
                    width: Math.min(parent.width - 120, 760)
                    spacing: 10
                    visible: viewerCard.nearCurrent
                             && (String(viewerImage.source || "") === ""
                                 || viewerImage.status === Image.Error)
                    Text { width: parent.width; text: viewerCard.mediaData && viewerCard.mediaData.Name ? String(viewerCard.mediaData.Name) : "Média indisponible"; color: "#FFFFFF"; font.pixelSize: 28; font.bold: true; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; textFormat: Text.PlainText }
                    Text { width: parent.width; text: "Aperçu indisponible"; color: "#AEB5CF"; font.pixelSize: 18; horizontalAlignment: Text.AlignHCenter; textFormat: Text.PlainText }
                }
            }
        }
        NumberAnimation {
            id: viewerSlide
            target: viewerStrip
            property: "contentX"
            duration: personalMediaPage.viewerSlideMs
            easing.type: Easing.OutCubic
            onStopped: {
                if (!personalMediaPage.viewerOpen) return
                viewerStrip.contentX = personalMediaPage._viewerTargetX(personalMediaPage.viewerIndex)
                personalMediaPage.viewerSlideLocked = false
                personalMediaPage._viewerMaybeLoadMore()
            }
        }
        Rectangle {
            z: 20; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 154
            gradient: Gradient { GradientStop { position: 0.0; color: "#D8000000" } GradientStop { position: 1.0; color: "#00000000" } }
        }
        Text {
            id: viewerTitle
            z: 21; anchors.left: parent.left; anchors.top: parent.top
            anchors.leftMargin: personalMediaPage.viewerSafeMargin; anchors.topMargin: 24
            width: Math.max(200, parent.width - 330)
            text: viewerLayer.currentItem && viewerLayer.currentItem.Name ? String(viewerLayer.currentItem.Name) : ""
            color: "#FFFFFF"; font.pixelSize: 26; font.bold: true; elide: Text.ElideRight; textFormat: Text.PlainText
        }
        Item {
            id: viewerTagsClip
            z: 21
            anchors.left: viewerTitle.left
            anchors.top: viewerTitle.bottom
            anchors.topMargin: 9
            width: Math.max(120, parent.width - personalMediaPage.viewerSafeMargin * 2 - 170)
            height: 28
            clip: true
            Row {
                spacing: 8
                Repeater {
                    model: viewerLayer.currentTagChips ? viewerLayer.currentTagChips.length : 0
                    Rectangle {
                        height: 26; radius: 8
                        color: viewerLayer.currentTagChips[index].c
                        width: viewerTagText.paintedWidth + 14
                        Text {
                            id: viewerTagText; anchors.centerIn: parent
                            text: viewerLayer.currentTagChips[index].t
                            color: "#FFFFFF"; font.pixelSize: viewerLayer.currentTagChips[index].px
                            textFormat: Text.PlainText
                        }
                    }
                }
            }
        }
        Rectangle {
            z: 21; anchors.right: parent.right; anchors.top: parent.top
            anchors.rightMargin: personalMediaPage.viewerSafeMargin; anchors.topMargin: 26
            width: viewerCounter.paintedWidth + 24; height: 34; radius: 12
            color: Qt.rgba(0.04,0.05,0.09,0.78); border.width: 1; border.color: "#55FFFFFF"
            visible: personalMediaPage.folderItems && personalMediaPage.folderItems.length > 0
            Text {
                id: viewerCounter; anchors.centerIn: parent
                text: {
                    var idx = Math.max(0, personalMediaPage._globalIndexForLocal(personalMediaPage.viewerIndex))
                    var known = Math.max(idx + 1, personalMediaPage._windowKnownEnd())
                    return (idx + 1) + " / " + known + (personalMediaPage.folderPageHasMore ? "+" : "")
                }
                color: "#FFFFFF"; font.pixelSize: 16; font.bold: true; textFormat: Text.PlainText
            }
        }
        Item {
            id: photoZoomRuler; z: 32; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; anchors.rightMargin: 34; width: 82; height: 314
            readonly property real norm: Math.max(0.0, Math.min(1.0, (personalMediaPage.photoZoom-personalMediaPage.photoZoomMin)/Math.max(0.001, personalMediaPage.photoZoomMax-personalMediaPage.photoZoomMin)))
            readonly property bool active: personalMediaPage._viewerCurrentIsPhoto()
                                          && (personalMediaPage.photoZoom > personalMediaPage.photoZoomMin + 0.001
                                              || photoZoomContinuousAnim.running)
            visible: opacity > 0.01
            opacity: active ? 1.0 : 0.0
            Behavior on opacity {
                NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
            }
            Rectangle {
                anchors.fill: parent
                radius: 16
                color: Qt.rgba(0.02, 0.025, 0.04, 0.76)
                border.width: 1
                border.color: "#44FFFFFF"
            }
            Item {
                id: photoZoomScaleArea
                anchors.top: parent.top
                anchors.topMargin: 18
                anchors.horizontalCenter: parent.horizontalCenter
                width: 54
                height: 260

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 2
                    radius: 1
                    color: "#66FFFFFF"
                }
                Repeater {
                    model: 13
                    delegate: Rectangle {
                        readonly property bool major: index % 4 === 0
                        readonly property bool medium: index % 2 === 0
                        width: major ? 28 : (medium ? 20 : 13)
                        height: major ? 2 : 1
                        radius: 1
                        color: major ? "#FFFFFFFF" : "#A8FFFFFF"
                        x: Math.round((photoZoomScaleArea.width - width) / 2)
                        y: Math.round((photoZoomScaleArea.height - height) * (1.0 - index / 12.0))
                    }
                }
                Rectangle {
                    z: 4
                    width: 42
                    height: 4
                    radius: 2
                    color: "#FFFFFF"
                    x: Math.round((photoZoomScaleArea.width - width) / 2)
                    y: Math.round((photoZoomScaleArea.height - height) * (1.0 - photoZoomRuler.norm))
                }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 10
                text: Math.round(personalMediaPage.photoZoom * 100) + "%"
                color: "#FFFFFF"
                font.pixelSize: 15
                font.bold: true
                textFormat: Text.PlainText
            }
        }
        Rectangle {
            z: 30; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 32
            width: 58; height: 58; radius: 29; color: "#CC090B14"; border.width: 1; border.color: "#55FFFFFF"
            visible: personalMediaPage.folderPageInFlight
            Components.CircleDotsLoader { anchors.centerIn: parent; width: 42; height: 42; visible: parent.visible }
        }
        Keys.onPressed: {
            if (event.isAutoRepeat) { event.accepted=true; return }
            if (personalMediaPage._viewerCurrentIsPhoto() && personalMediaPage._isPhotoZoomKey(event.key)) {
                personalMediaPage._stopPhotoPanAnimation(); personalMediaPage._startPhotoZoomContinuous(personalMediaPage._photoZoomDirection(event.key)); event.accepted=true; return
            }
            if ((event.key===Qt.Key_Up || event.key===Qt.Key_Down) && personalMediaPage._viewerCurrentIsPhoto()) {
                if (personalMediaPage.photoZoom>personalMediaPage.photoZoomMin+0.001) personalMediaPage._beginPhotoHold(event.key)
                event.accepted=true; return
            }
            if (event.key===Qt.Key_Left || event.key===Qt.Key_Right) {
                if (personalMediaPage._viewerCurrentIsPhoto() && personalMediaPage.photoZoom>personalMediaPage.photoZoomMin+0.001) personalMediaPage._beginPhotoHold(event.key)
                else personalMediaPage.viewerGo(event.key===Qt.Key_Left?-1:1)
                event.accepted=true; return
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select || event.key === Qt.Key_Ok || event.key === Qt.Key_Space) {
                personalMediaPage.playViewerVideo(); event.accepted = true; return
            }
            if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) { personalMediaPage.closeViewer(); event.accepted = true; return }
        }
        Keys.onReleased: {
            if (event.isAutoRepeat) { event.accepted=true; return }
            if (personalMediaPage._isPhotoZoomKey(event.key)) { personalMediaPage._stopPhotoZoomAnimation(); event.accepted=true; return }
            if (personalMediaPage._photoHoldKey===event.key) { personalMediaPage._endPhotoHold(event.key); event.accepted=true }
        }
        onVisibleChanged: {
            if (!visible) { personalMediaPage._resetPhotoView(); return }
            Qt.callLater(function(){ personalMediaPage._viewerSnap(); viewerLayer.forceActiveFocus(Qt.OtherFocusReason) })
        }
    }

    Component.onCompleted: {
        var incoming = String(itemId || "")
        if (incoming.length) {
            _consumedEntryItemId = incoming
            _armViewerTarget(incoming, false)
        } else {
            var st = _readViewerState()
            if (st && st.viewerOpen === true) _armViewerTarget("", true)
        }
    }
    onItemIdChanged: {
        var incoming = String(itemId || "")
        if (incoming.length && incoming !== _consumedEntryItemId) {
            _consumedEntryItemId = incoming
            _armViewerTarget(incoming, false)
        }
    }
    onVisibleChanged: {
        if (visible && viewerOpen)
            Qt.callLater(function(){ viewerLayer.forceActiveFocus(Qt.OtherFocusReason) })
    }
    Component.onDestruction: {
        if (viewerOpen) _writeViewerState()
        viewerResolveTimer.stop()
        _stopPhotoZoomAnimation()
        _stopPhotoPanAnimation()
    }
    Keys.onPressed: {
        if ((event.key === Qt.Key_Back || event.key === Qt.Key_Escape) && !browser) {
            requestBackToMenu()
            event.accepted = true
        }
    }
}
