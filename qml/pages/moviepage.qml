// qml/pages/moviepage.qml — QtQuick 2.15, sans QtQuick Controls
// Grille unifiée ReDeFin : Films, Séries, Films+Séries, médias personnels,
// Clips musicaux et Collections.
// Pagination/restauration, D-Pad, backdrop et mode MusicVideo 16:9 conservés.

import QtQuick 2.15
import QtGraphicalEffects 1.15

import "../components" as Components
import "." as Pages
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/MediaCatalog.js" as MediaCatalog
import "../js/UserStore.js" as UserStore
Item {
    id: moviepage
    width: parent ? parent.width : 1920
    height: parent ? parent.height : 1080
    focus: true

    /* ========= Contexte ========= */
    property string accessToken
    property string userId
    property string serverUrl
    property string folderId
    property string libraryMode: "movies"   // movies | series | mixed | collections | personal
    property string browserTitle: ""
    readonly property string normalizedLibraryMode: MediaCatalog.normalizeMode(libraryMode)
    readonly property bool hierarchicalMode: MediaCatalog.isHierarchicalMode(libraryMode)
    readonly property bool collectionsMode: MediaCatalog.isCollectionsMode(libraryMode)
    readonly property bool personalMode: normalizedLibraryMode === "personal"
    // Une visionneuse propriétaire peut recouvrir la grille sans recréer le
    // navigateur ni lui laisser reprendre le focus.
    property bool externalModalOpen: false
    property string userName
    property string userImageTag
    property var    fbx
    // Injecté par ShellPage. Les optimisations restent identiques sur les deux
    // Players ; seule la taille de page bibliothèque diffère afin de limiter le
    // premier burst JSON/QML sur l'Atom CE4100 de la Révolution.
    property string playbackDeviceMode: "auto"
    property string itemId

    /* ========= Injection cross-pages (ShellPage.shared) ========= */
    property var shared

    /* ========= Mémoire focus/scroll ========= */
    property int  startIndex: -1
    property int  restoreIndex: -1
    property real restoreY: -1

    /* ========= Données ========= */
    property var  folderItems: []
    property var  _rawFolderItems: []
    property var  sortOptionLabels: MediaCatalog.folderSortOptionLabels()
    property int  sortMode: 0
    property bool ready: false
    property bool loadingItems: false
    property bool fetchedOnce: false
    property bool musicVideoMode: false
    // P3 Freebox : état de pagination explicite pour éviter les faux écrans vides
    // et conserver la grille si une page suivante échoue.
    property string folderLoadState: "initial"
    property string folderLoadErrorText: ""
    readonly property bool folderInitialLoading: folderLoadState === "loadingInitial"
    readonly property bool folderLoadingMore: folderLoadState === "loadingMore"

    /* ========= Pagination visuelle bibliothèque ========= */
    // Devialet : fenêtre historique de 220 éléments.
    // Révolution : 50 éléments, soit une seule sous-requête du bridge au premier
    // affichage. Le préchargement anticipé existant recharge la suite avant la fin.
    readonly property int folderPageSize: String(playbackDeviceMode || "").toLowerCase() === "revolution" ? 50 : 220
    property int  folderPageNextStart: 0
    property bool folderPageHasMore: true
    property bool folderPageHasPrevious: false
    property bool folderPageInFlight: false
    property var  _folderPageHandle: null
    property bool folderPageRestorePending: false
    property int  folderWindowStartIndex: 0
    property int  folderPrependNavSteps: 0
    readonly property int folderWindowMaxItems: folderPageSize * 4
    // Garde le loader plein écran tant que l'index mémorisé n'est pas réellement
    // chargé, positionné et matérialisé par le GridView.
    property bool folderRestoreVisualLoading: false
    property int  folderRestoreVisualTargetIndex: -1
    property int  folderRestoreRevealAttempts: 0
    property real folderRestoreStableSinceMs: 0
    readonly property int folderRestoreVisualSettleMs: 1100
    readonly property int folderRestoreRevealMaxAttempts: 80
    readonly property bool folderBlockingLoading: folderInitialLoading || folderRestoreVisualLoading
    // Le Shell garde son curtain pendant tout le premier cycle de fetch.
    // Cela couvre aussi la courte fenêtre où la restauration de grille n'a pas
    // encore eu le temps d'armer folderRestoreVisualLoading.
    readonly property bool shellLoading: (!fetchedOnce || folderBlockingLoading) && !externalModalOpen
    readonly property string shellLoadingError: ""
    readonly property int folderPageAppendThreshold: Math.max(24, ((grid && grid.columns > 0) ? grid.columns * 5 : 35))
    readonly property int folderPagePrependThreshold: Math.max(14, ((grid && grid.columns > 0) ? grid.columns * 3 : 21))

    // Détails enrichis pour restaurer les tags média de la ligne header.
    // Les listings Jellyfin sont volontairement allégés côté bridge ; MediaStreams
    // est donc récupéré à la demande sur l'item focus, sans alourdir toute la grille.
    property var  _detailCacheById: ({})
    property var  _detailCacheOrder: []
    property int  _detailFetchToken: 0
    property string _detailFetchInFlightId: ""
    property var _detailFetchHandle: null
    readonly property int detailCacheMax: personalMode ? 24 : 80

    /* ========= Compteur léger des BoxSet (mode Collections uniquement) ========= */
    property var childCountCache: ({})
    property var noCountMetaCache: ({})
    property var _countQueue: []
    property bool _countInFlight: false
    property string _countTargetId: ""
    property string _countFocusDwellId: ""
    property string _countFallbackPendingId: ""
    property int _countSeq: 0

    /* Expose l'index courant pour ShellPage */
    readonly property int currentIndex: _globalIndexForLocal(grid.currentIndex)

    /* ========= Layout / constantes ========= */
    readonly property int marginL: 40
    readonly property int marginR: 40
    readonly property int headerTop: 30
    readonly property int gridTopGap: 24

    /* ========= Posters ========= */
    readonly property int  posterW: musicVideoMode ? 270 : 162
    readonly property int  posterH: musicVideoMode ? 152 : 243
    readonly property real posterOversample: 1.20
    readonly property int  reqPosterW: Math.round(posterW * posterOversample)
    readonly property int  reqPosterH: Math.round(posterH * posterOversample)
    readonly property real posterHqOversample: 1.50
    readonly property int  reqPosterHqW: Math.round(posterW * posterHqOversample)
    readonly property int  reqPosterHqH: Math.round(posterH * posterHqOversample)

    readonly property real focusScale: 1.14
    readonly property int  focusLiftPx: 6

    // Viser 7 colonnes (sur 1280 typiquement) via le padding.
    readonly property int focusPad: {
        var avail = Math.max(1, (moviepage.width - (marginL + marginR)))
        // Même espacement horizontal que la grille films 162 px / 7 colonnes.
        // En mode clips, seule la largeur de la vignette change : le "gutter" reste identique.
        var portraitTargetCellW = Math.floor(avail / 7)
        var portraitPad = Math.floor((portraitTargetCellW - 162) / 2)
        return Math.max(2, Math.min(6, portraitPad))
    }

    readonly property real frameWidth: 2.0
    function topPadFor(h) {
        return Math.ceil(h * (focusScale - 1)) + focusLiftPx + Math.ceil(frameWidth) + 2
    }

    readonly property int  gridCellW: posterW + focusPad * 2
    readonly property int  gridCellH: posterH + focusPad + topPadFor(posterH)

    // ✅ TWEAK 2: qualité JPEG abaissée (URL unique)
    readonly property int jpgQltPosters: 82
    readonly property int posterHqQuality: 90
    property string _hqPosterCandidateId: ""
    property string hqPosterTargetId: ""
    function _cancelPosterHq(){ posterHqTimer.stop(); _hqPosterCandidateId = ""; hqPosterTargetId = "" }
    // Politique image du ZIP 30082026 : le glide D-Pad programmatique
    // n'est pas considéré comme un scroll Flickable. Le HQ reste donc armé
    // pendant le glide et seul moving/dragging/flicking le suspend.
    function _schedulePosterHq(){
        posterHqTimer.stop()
        hqPosterTargetId = ""
        if (!visible || !grid || !grid.activeFocus || isScrolling) {
            _hqPosterCandidateId = ""
            return
        }
        var id = _selectedItemId()
        _hqPosterCandidateId = id
        if (id.length) posterHqTimer.restart()
    }
    Timer {
        id: posterHqTimer
        // Laisser la première vague de delegates/posters se stabiliser avant le
        // remplacement HQ. Même délai sur Révolution et Devialet.
        interval: 600
        repeat: false
        onTriggered: {
            var id = moviepage._selectedItemId()
            moviepage.hqPosterTargetId = (!moviepage.isScrolling
                                           && grid.activeFocus
                                           && id
                                           && id === moviepage._hqPosterCandidateId) ? id : ""
        }
    }
    // LQIP Freebox-safe : mini image Jellyfin très compressée, agrandie pour un flou naturel.
    // La vraie image est volontairement différée pour que la preview soit visible.

    /* ========= HUD ========= */
    readonly property int avatarSize: 48

    /* ========= Backdrop (unique 1280×720) ========= */
    readonly property int bgW: 1280
    readonly property int bgH: 720
    property int bgBlur: 8
    property real bgDarken: 0.40

    /* ========= Navigation ========= */
    signal requestNavigation(string page)
    signal requestBackToMenu()
    signal requestPersonalViewer(int index)

    function _sharedNavApi(){ try { return shared && shared.__redefinNavApi ? shared.__redefinNavApi : null } catch(e) { return null } }
    function _hydrateSensitiveContextFromShared(){
        var api = _sharedNavApi()
        return api && api.hydrate ? api.hydrate(moviepage, false, 0, false) : false
    }

    function _storeSensitiveNavContext(){
        var api = _sharedNavApi()
        return api && api.storeTarget ? api.storeTarget(moviepage) : false
    }

    function _navRoute(page, params){
        var api = _sharedNavApi()
        return api && api.route ? api.route(moviepage, page, params || ({})) : (page + "?ctx=1")
    }


    /* ========= Helpers perf ========= */
    // Le glide clavier reste distinct du drag/flick afin de conserver le zoom
    // de focus. En mode Collections, les décos et fades sont toutefois coupés
    // pendant le glide, en conservant le comportement optimisé historique des Collections.
    readonly property bool isScrolling: !!(grid && (grid.moving || grid.dragging || grid.flicking))
    // Le déplacement D-Pad anime directement contentY : Flickable.moving/flicking
    // ne couvre donc pas ce cas. isGridInMotion est la vérité unique pour tout
    // traitement coûteux qui peut attendre la stabilisation de la grille.
    readonly property bool isGridInMotion: !!(moviepage.isScrolling || (glideY && glideY.running))
    readonly property bool isSettling: moviepage.isGridInMotion
    // Pendant un glide D-Pad, aucune animation décorative n'a besoin de tourner
    // en parallèle du déplacement de la grille. Le focus reste immédiatement
    // à sa bonne taille, puis les animations redeviennent disponibles à l'arrêt.
    // Même politique que la v3 pour les transitions de focus : un glide D-Pad
    // n'est pas un drag/flick et ne doit pas supprimer le zoom. Les traitements
    // vraiment coûteux (smooth/HQ/backdrop) continuent d'utiliser isGridInMotion.
    readonly property bool allowAnims: !!(moviepage.visible && !moviepage.externalModalOpen && !moviepage.isScrolling)
    readonly property bool allowDecos: !!(moviepage.visible && !moviepage.externalModalOpen && !moviepage.isGridInMotion)
    readonly property bool allowBgAnims: !!(moviepage.visible && !moviepage.externalModalOpen && !moviepage.isGridInMotion)

    /* ========= Focus state (anti focus perdu HUD) ========= */
    readonly property int focusGrid: 0
    readonly property int focusHud: -1
    readonly property int focusSort: -2
    property int currentFocusTarget: focusGrid

    property bool hudPinned: false
    Timer {
        id: hudPinTimer
        interval: 900
        repeat: false
        onTriggered: moviepage.hudPinned = false
    }

    /* ========= Backdrop update (sticky idle + scroll-stop) ========= */
    readonly property int stickyBackdropDelayMs: 750
    readonly property int firstBackdropDelayMs: 180
    property int _bgPendingIndex: -1

    Timer {
        id: bgIdleTimer
        interval: stickyBackdropDelayMs
        repeat: false
        onTriggered: {
            if (!moviepage.visible || !backdrop || !grid) return
            if (moviepage.collectionsMode ? moviepage.isSettling : moviepage.isScrolling) {
                _bgPendingIndex = grid.currentIndex
                bgIdleTimer.interval = stickyBackdropDelayMs
                bgIdleTimer.restart()
                return
            }

            var idx = (_bgPendingIndex >= 0) ? _bgPendingIndex : grid.currentIndex
            if (idx < 0) return

            // Sticky backdrop : le poster/titre suit le focus tout de suite,
            // le fond ne change que quand le focus est vraiment stabilisé.
            if (grid.currentIndex !== idx) {
                _bgPendingIndex = grid.currentIndex
                bgIdleTimer.interval = stickyBackdropDelayMs
                bgIdleTimer.restart()
                return
            }

            _bgPendingIndex = -1
            backdrop.updateBackdropNow(idx)
        }
    }

    function _scheduleBackdropUpdate(idleAfterScroll) {
        if (!grid) return
        _bgPendingIndex = grid.currentIndex
        var hasStableBackdrop = !!(backdrop && backdrop.visibleUrl && backdrop.visibleUrl.length)
        bgIdleTimer.interval = (!hasStableBackdrop && !(moviepage.collectionsMode ? moviepage.isSettling : moviepage.isScrolling)) ? firstBackdropDelayMs : stickyBackdropDelayMs
        bgIdleTimer.restart()
    }

    /* ========= HUD fade helper ========= */
    property real scrollProgress: 0.0
    function updateScrollProgress() {
        var t = 100
        var p = (grid ? (grid.contentY / t) : 0)
        scrollProgress = p < 0 ? 0 : (p > 1 ? 1 : p)
    }

    function _selectedCollectionItem() {
        if (!collectionsMode || !grid || !folderItems || folderItems.length <= 0) return null
        var idx = grid.currentIndex
        return (idx >= 0 && idx < folderItems.length) ? folderItems[idx] : null
    }

    function directCollectionItemCount(it) {
        if (!it) return 0
        var c = -1
        try {
            if (it.ChildCount !== undefined) c = Number(it.ChildCount)
            else if (it.ItemCount !== undefined) c = Number(it.ItemCount)
        } catch(e) { c = -1 }
        return (!isFinite(c) || c < 0) ? 0 : Math.floor(c)
    }

    function _cachedCollectionItemCount(boxSetId) {
        boxSetId = String(boxSetId || "")
        if (!boxSetId.length) return -1
        try {
            if (childCountCache && Object.prototype.hasOwnProperty.call(childCountCache, boxSetId))
                return Number(childCountCache[boxSetId]) || 0
        } catch(e) {}
        return -1
    }

    function _putCollectionItemCount(boxSetId, n) {
        boxSetId = String(boxSetId || "")
        if (!boxSetId.length) return
        n = Number(n)
        if (!isFinite(n) || n < 0) n = 0
        var next = ({})
        try {
            for (var key in childCountCache)
                if (Object.prototype.hasOwnProperty.call(childCountCache, key)) next[key] = childCountCache[key]
        } catch(e0) {}
        Jellyfin.putBoundedMemory(next, boxSetId, Math.floor(n), 96)
        try { delete noCountMetaCache[boxSetId] } catch(e1) {}
        childCountCache = next
    }

    function _markCollectionCountUnavailable(boxSetId) {
        boxSetId = String(boxSetId || "")
        if (!boxSetId.length) return
        try { Jellyfin.putBoundedMemory(noCountMetaCache, boxSetId, Date.now() + 60000, 48) } catch(e) {}
    }

    function _collectionCountUnavailable(boxSetId) {
        boxSetId = String(boxSetId || "")
        if (!boxSetId.length) return false
        try {
            var until = Number(noCountMetaCache && noCountMetaCache[boxSetId] || 0)
            if (until > Date.now()) return true
            if (until) delete noCountMetaCache[boxSetId]
        } catch(e) {}
        return false
    }

    function effectiveCollectionItemCount(it) {
        if (!collectionsMode || !it) return 0
        var base = directCollectionItemCount(it)
        if (base > 0) return base
        var id = String(it.Id || "")
        var cached = _cachedCollectionItemCount(id)
        return cached >= 0 ? cached : -1
    }

    function _queueCollectionCount(id, highPriority) {
        id = String(id || "")
        if (!collectionsMode || !id.length || _cachedCollectionItemCount(id) >= 0) return
        if (_countInFlight && _countTargetId === id) return
        for (var i = 0; i < _countQueue.length; ++i) {
            if (_countQueue[i] !== id) continue
            if (highPriority && i > 0) {
                _countQueue.splice(i, 1)
                _countQueue.unshift(id)
            }
            return
        }
        if (highPriority) _countQueue.unshift(id)
        else _countQueue.push(id)
    }

    Timer {
        id: countPumpTimer
        interval: 0
        repeat: false
        onTriggered: moviepage._pumpCollectionCountQueue()
    }
    Timer {
        id: countFocusFallbackTimer
        interval: 900
        repeat: false
        onTriggered: {
            var it = moviepage._selectedCollectionItem()
            var id = String(it && it.Id || "")
            if (!id.length || id !== moviepage._countFocusDwellId) return
            if (moviepage.isScrolling || (glideY && glideY.running)) { restart(); return }
            if (moviepage.directCollectionItemCount(it) > 0) return
            if (moviepage._cachedCollectionItemCount(id) >= 0) return
            if (moviepage._countInFlight && moviepage._countTargetId === id) {
                moviepage._countFallbackPendingId = id
                return
            }
            moviepage._queueCollectionCount(id, true)
            countPumpTimer.restart()
        }
    }

    function _pumpCollectionCountQueue() {
        if (!collectionsMode || _countInFlight || !accessToken || !serverUrl || !_countQueue.length) return
        if (isScrolling || (glideY && glideY.running)) { countPumpTimer.restart(); return }
        var id = String(_countQueue.shift() || "")
        if (!id.length || _cachedCollectionItemCount(id) >= 0) { countPumpTimer.restart(); return }
        var selected = _selectedCollectionItem()
        var focused = !!(selected && String(selected.Id || "") === id)
        var allowFallback = focused && _countFocusDwellId === id && !countFocusFallbackTimer.running
        _fetchCollectionItemCount(id, allowFallback)
    }

    function _fetchCollectionItemCount(boxSetId, allowFallbackListing) {
        boxSetId = String(boxSetId || "")
        if (!collectionsMode || !boxSetId.length || _cachedCollectionItemCount(boxSetId) >= 0) return
        if (_countInFlight && _countTargetId === boxSetId) return
        _countInFlight = true
        _countTargetId = boxSetId
        var seq = ++_countSeq
        function finishNoMeta() {
            if (seq !== _countSeq) return
            _countInFlight = false
            _markCollectionCountUnavailable(boxSetId)
            if (_countFallbackPendingId === boxSetId) {
                _countFallbackPendingId = ""
                _queueCollectionCount(boxSetId, true)
            }
            Qt.callLater(_pumpCollectionCountQueue)
        }
        function finishWith(n) {
            if (seq !== _countSeq) return
            _countInFlight = false
            if (_countFallbackPendingId === boxSetId) _countFallbackPendingId = ""
            _putCollectionItemCount(boxSetId, n)
            Qt.callLater(_pumpCollectionCountQueue)
        }
        if (allowFallbackListing !== true || !userId) { finishNoMeta(); return }
        Jellyfin.fetchFolderItemCount(
            serverUrl, accessToken, userId, boxSetId, "", false,
            function(n) { if (seq === _countSeq) finishWith(n) },
            function() { if (seq === _countSeq) finishNoMeta() }
        )
    }

    function _requestCollectionCountForFocusNow() {
        if (!collectionsMode) return
        var it = _selectedCollectionItem()
        if (!it || !it.Id) { _countFocusDwellId = ""; countFocusFallbackTimer.stop(); return }
        var id = String(it.Id)
        if (directCollectionItemCount(it) > 0 || _cachedCollectionItemCount(id) >= 0 || _collectionCountUnavailable(id)) {
            _countFocusDwellId = ""
            countFocusFallbackTimer.stop()
            return
        }
        _countFocusDwellId = id
        countFocusFallbackTimer.restart()
    }

    function _scheduleSelectedAuxiliaryFetch() {
        if (collectionsMode) _requestCollectionCountForFocusNow()
        else _scheduleSelectedItemDetailFetch()
    }

    /* ========= Utils visibilité ========= */
    function indexVisible(idx) {
        var cols = (grid && grid.columns > 0) ? grid.columns : 1
        var row = Math.floor(idx / cols)
        var rowTop = row * grid.cellHeight
        var rowBottom = rowTop + grid.cellHeight
        var margin = Math.max(360, grid.cellHeight * 1.5)
        return !(rowBottom < (grid.contentY - margin) || rowTop > (grid.contentY + grid.height + margin))
    }

    /* ========= Focus target ========= */
    function forceInitialFocus() {
        // Ne jamais exposer/focaliser provisoirement l'index 0 pendant une
        // restauration nécessitant plusieurs pages de 220 éléments.
        if (folderBlockingLoading || externalModalOpen) return
        currentFocusTarget = focusGrid
        hudPinned = false
        hudPinTimer.stop()

        if (!grid) return
        if (grid.count > 0 && grid.currentIndex < 0) grid.currentIndex = 0
        try { grid.forceActiveFocus(Qt.OtherFocusReason) } catch(e) {}
        try { grid.ensureVisible(grid.currentIndex, true) } catch(e2) {}
    }

    // Handoff post-curtain : le restore d'index a déjà été appliqué.
    // On reprend uniquement l'activeFocus sans modifier l'index ni contentY.
    function restoreFocusAfterShellCurtain() {
        if (!visible || folderBlockingLoading || externalModalOpen || !grid || grid.count <= 0)
            return false

        if (currentFocusTarget === focusSort && sortButton && sortButton.visible) {
            try { sortButton.focusButton() } catch(e0) {}
            return true
        }
        if (currentFocusTarget === focusHud) {
            try { focusHudAvatar() } catch(e1) {}
            return true
        }

        currentFocusTarget = focusGrid
        hudPinned = false
        hudPinTimer.stop()
        try { grid.forceActiveFocus(Qt.OtherFocusReason) } catch(e2) {}
        try {
            if (grid.currentIndex >= 0)
                grid.ensureVisible(grid.currentIndex, true)
        } catch(e3) {}
        return true
    }

    /* ========= Tri HUD ========= */
    function sortButtonText() { return "A-Z" }

    function _sortPreferenceKey() {
        if (personalMode) return "sortMode.personalMedia"
        return collectionsMode ? "sortMode.collections" : ("sortMode.movie." + normalizedLibraryMode)
    }

    function _storedSortMode() {
        if (!serverUrl || !userId) return -1
        try {
            UserStore.init(moviepage)
            var raw = UserStore.getUserPref(serverUrl, userId, _sortPreferenceKey(), -1)
            var m = Number(raw)
            if (isFinite(m)) {
                m = m | 0
                if (m >= 0 && m < sortOptionLabels.length) return m
            }
        } catch(e) {}
        return -1
    }

    function _saveSortPreference() {
        if (!serverUrl || !userId) return
        var m = sortMode | 0
        if (m < 0 || m >= sortOptionLabels.length) return
        try {
            UserStore.init(moviepage)
            UserStore.setUserPref(serverUrl, userId, _sortPreferenceKey(), m)
        } catch(e) {}
    }

    function _restoreSortFromShared() {
        sortMode = MediaCatalog.browserResolvedSortMode(_storedSortMode(), _readSharedState(), sortOptionLabels.length, sortMode)
    }

    function _selectedItemId() { return MediaCatalog.browserSelectedItemId(folderItems, grid ? grid.currentIndex : -1) }


    function _globalIndexForLocal(localIndex) { return MediaCatalog.browserGlobalIndex(folderItems, folderWindowStartIndex, localIndex) }

    function _localIndexForGlobal(globalIndex) { return MediaCatalog.browserLocalIndex(folderItems, folderWindowStartIndex, globalIndex) }

    function _windowKnownEnd() { return MediaCatalog.browserWindowKnownEnd(_rawFolderItems, folderWindowStartIndex) }

    // Contrat étroit pour PersonalMediaPage : la grille et sa pagination restent
    // ici, la visionneuse ne reçoit que les données et commandes nécessaires.
    readonly property var catalogItems: folderItems
    readonly property int catalogWindowStart: folderWindowStartIndex
    readonly property int catalogKnownEnd: _windowKnownEnd()
    readonly property bool catalogHasMore: folderPageHasMore
    readonly property bool catalogHasPrevious: folderPageHasPrevious
    readonly property bool catalogPageInFlight: folderPageInFlight
    readonly property real catalogContentY: grid ? grid.contentY : 0
    function findCatalogItemIndex(id) { return MediaCatalog.browserFindItemIndexById(folderItems, id) }
    function catalogGlobalIndex(localIndex) { return _globalIndexForLocal(localIndex) }
    function catalogItemWithDetail(base) { return itemWithDetailForHeader(base) }
    function focusCatalogIndex(index) {
        if (!grid || grid.count <= 0) return false
        index = Math.max(0, Math.min(grid.count - 1, Number(index) | 0))
        grid.currentIndex = index
        grid.ensureVisible(index, true)
        _scheduleSelectedAuxiliaryFetch()
        return true
    }
    function requestCatalogPage(direction) {
        if (direction < 0) _requestFolderPageBefore(false)
        else _requestFolderPage(false)
    }
    function restoreCatalogGlobalIndex(index) {
        index = Number(index)
        if (!(index >= 0)) return false
        restoreIndex = index | 0
        _armFolderRestoreVisualLoading()
        _applyRestore()
        return true
    }
    function saveCatalogState() { _writeSharedStateNow() }


    function _applySort(keepSelection, forceFirst, serverSortedPage) {
        var resetFirst = forceFirst === true
        var keepId = (keepSelection && !resetFirst) ? _selectedItemId() : ""
        var result = MediaCatalog.browserSortedWindow(
                    _rawFolderItems || [], sortMode, serverSortedPage === true,
                    keepId, grid ? grid.currentIndex : -1, resetFirst)
        folderItems = result.items || []

        if (result.index >= 0) {
            grid.currentIndex = result.index
            if (resetFirst) {
                try { grid.cancelFlick() } catch(e0) {}
                try { grid.contentY = 0 } catch(e1) {}
                updateScrollProgress()
            }
            Qt.callLater(function() {
                if (grid && grid.count > 0) grid.ensureVisible(grid.currentIndex, true)
                _scheduleBackdropUpdate(false)
            })
        } else {
            _scheduleBackdropUpdate(false)
        }
    }

    function setSortMode(mode) {
        mode = mode | 0
        if (mode < 0 || mode >= sortOptionLabels.length) mode = 0
        sortMode = mode
        _saveSortPreference()
        try { grid.cancelFlick() } catch(e0) {}
        try { grid.currentIndex = 0 } catch(e1) {}
        try { grid.contentY = 0 } catch(e2) {}
        updateScrollProgress()
        _writeSharedStateNow()
        fetchFolder()
    }

    function focusSortButton() {
        if (!sortButton || !sortButton.visible) {
            currentFocusTarget = focusGrid
            hudPinned = false
            hudPinTimer.stop()
            forceInitialFocus()
            return
        }

        currentFocusTarget = focusSort
        hudPinned = true
        hudPinTimer.restart()

        try { grid.glideStop() } catch(e0) {}
        try { grid.cancelFlick() } catch(e1) {}
        try { grid.contentY = 0 } catch(e2) {}
        updateScrollProgress()

        Qt.callLater(function() {
            try { sortButton.focusButton() } catch(e3) {}
        })
    }

    function focusGridFromSort() {
        currentFocusTarget = focusGrid
        hudPinned = false
        hudPinTimer.stop()
        try { sortButton.closeMenu() } catch(e) {}
        forceInitialFocus()
    }

    /* ========= Avatar HUD (ClockHUD) ========= */
    function _openLoginRoot() {
        if (typeof moviepage.requestNavigation !== "function") return
        moviepage._writeSharedStateNow()
        moviepage._storeSensitiveNavContext()
        moviepage.requestNavigation("LoginPage.qml?ctx=1")
    }

    function focusHudAvatar() {
        if (!grid) return

        currentFocusTarget = focusHud
        hudPinned = true
        hudPinTimer.restart()

        try { grid.glideStop() } catch(e0) {}
        try { grid.cancelFlick() } catch(e1) {}
        try { grid.contentY = 0 } catch(e2) {}
        updateScrollProgress()

        Qt.callLater(function() {
            var hud = clockHudLoader.item
            if (hud && hud.focusAvatar) {
                try { hud.focusAvatar() } catch(e3) {}
                return
            }
            if (hud && hud.forceActiveFocus) {
                try { hud.forceActiveFocus(Qt.OtherFocusReason) } catch(e4) {}
            } else {
                try { topBar.forceActiveFocus(Qt.OtherFocusReason) } catch(e5) {}
            }
        })
    }

    /* ========= State persistence (shared) ========= */
    property bool _restoring: false

    function _stateKey() { return "moviepage|" + normalizedLibraryMode + "|" + (folderId || "") }

    function _sharedBucket() {
        if (!shared) return null
        if (!shared.__focusState) shared.__focusState = {}
        if (!shared.__focusState.movie) shared.__focusState.movie = {}
        return shared.__focusState.movie
    }

    function _readSharedState() { var b = _sharedBucket(); return MediaCatalog.browserReadSharedState(b, b ? _stateKey() : "") }

    function _writeSharedStateNow() {
        var b = _sharedBucket()
        if (!b) return
        var k = _stateKey()
        Jellyfin.putBoundedMemory(b, k,
            { index: _globalIndexForLocal(grid.currentIndex),
              y: Math.floor(grid.contentY || 0),
              windowStart: folderWindowStartIndex,
              sort: (sortMode|0) }, 48)
    }

    Timer {
        id: stateSaveTimer
        interval: 180
        repeat: false
        onTriggered: _writeSharedStateNow()
    }
    function _scheduleStateSave() { stateSaveTimer.restart() }

    /* ========= Navigation hiérarchique Séries / Mixte ========= */
    function _isBrowserSeries(it) { return !collectionsMode && hierarchicalMode && MediaCatalog.isSeries(it) }
    function _isBrowserFolder(it) { return !collectionsMode && hierarchicalMode && MediaCatalog.isFolder(it) }
    function _isCollectionItem(it) {
        if (!collectionsMode || !it) return false
        return String(it.Type || it.CollectionType || "").toLowerCase() === "boxset"
    }
    function unreadCountFor(it) { return hierarchicalMode ? MediaCatalog.unreadCount(it) : 0 }
    function _pushBrowserReturnState(childId) {
        return hierarchicalMode && MediaCatalog.pushBrowserReturn(shared, folderId, childId, browserTitle,
                                                        _globalIndexForLocal(grid.currentIndex),
                                                        grid.contentY, normalizedLibraryMode)
    }
    function _navigateToBrowserParent() {
        if (!hierarchicalMode || typeof requestNavigation !== "function") return false
        var e = MediaCatalog.popBrowserParent(shared, folderId); if (!e || !e.folderId) return false
        _writeSharedStateNow()
        requestNavigation(_navRoute(personalMode ? "PersonalMediaPage.qml" : "moviepage.qml", {
            folderId: e.folderId,
            libraryMode: e.libraryMode || normalizedLibraryMode,
            browserTitle: e.browserTitle || "",
            restoreIndex: Math.max(0, Number(e.index) | 0),
            restoreY: Math.max(0, Math.floor(Number(e.y) || 0))
        })); return true
    }

    /* ========= Helpers image ========= */


    // SÉCURITÉ : URL image Jellyfin sans token, mais elle contient le host et un itemId.
    // Ne jamais logger Image.source, posterSrc, backdrop URL ou cette URL brute.
    function posterUrlFor(it, w, h, opts) {
        if (!it || !serverUrl) return ""
        opts = opts || {}
        var W = w || reqPosterW
        var H = h || reqPosterH
        var quality = (opts.quality !== undefined) ? opts.quality : jpgQltPosters
        var imageOpts = {
            quality: quality > 0 ? quality : undefined,
            blur: opts.blur ? MediaCatalog.clampBlur(opts.blur) : undefined
        }
        if (opts.fit) { imageOpts.maxWidth = W; imageOpts.maxHeight = H }
        else { imageOpts.fillWidth = W; imageOpts.fillHeight = H }

        var tags = it.ImageTags || {}

        // Collections : séparer strictement la source du fond et celle du poster.
        // Le précédent tweak anti-404 mettait Thumb avant Primary partout : les
        // BoxSet possédant une Thumb horizontale affichaient alors cette image
        // dans une carte poster verticale, avec un cadrage visuellement démesuré.
        // Fond : Backdrop -> Thumb -> Primary -> noir.
        // Poster : Primary -> Thumb -> fallback graphique (traité plus bas).
        if (collectionsMode && opts.preferBackdrop) {
            if (it.BackdropImageTags && it.BackdropImageTags.length > 0)
                return Jellyfin.itemImageUrl(serverUrl, it.Id, "Backdrop",
                                               it.BackdropImageTags[0], imageOpts)
            if (tags.Thumb)
                return Jellyfin.itemImageUrl(serverUrl, it.Id, "Thumb", tags.Thumb, imageOpts)
            if (tags.Primary)
                return Jellyfin.itemImageUrl(serverUrl, it.Id, "Primary", tags.Primary, imageOpts)
            return ""
        }

        if (collectionsMode) {
            // Une carte Collection reste prioritairement un poster vertical.
            if (tags.Primary)
                return Jellyfin.itemImageUrl(serverUrl, it.Id, "Primary", tags.Primary, imageOpts)
            if (tags.Thumb) {
                // Thumb est souvent horizontal : ne pas demander fillWidth/fillHeight
                // qui le recadre brutalement en portrait. On limite seulement sa
                // taille et LibraryPosterCard l'affiche en PreserveAspectFit.
                var thumbOpts = {
                    maxWidth: W,
                    maxHeight: H,
                    quality: quality > 0 ? quality : undefined
                }
                return Jellyfin.itemImageUrl(serverUrl, it.Id, "Thumb", tags.Thumb, thumbOpts)
            }
            // Anti-404 : aucune fabrication de /Images/Primary sans ImageTag.
            return ""
        }

        if (opts.preferBackdrop) {
            if (it.BackdropImageTags && it.BackdropImageTags.length > 0)
                return Jellyfin.itemImageUrl(serverUrl, it.Id, "Backdrop", it.BackdropImageTags[0], imageOpts)
            if (it.SeriesId)
                return Jellyfin.itemImageUrl(serverUrl, it.SeriesId, "Backdrop", "", imageOpts)
        }
        if (tags.Primary) return Jellyfin.itemImageUrl(serverUrl, it.Id, "Primary", tags.Primary, imageOpts)
        if (tags.Thumb) return Jellyfin.itemImageUrl(serverUrl, it.Id, "Thumb", tags.Thumb, imageOpts)
        if (personalMode) return ""
        // Préserve le fallback historique MoviePage hors Collections.
        return Jellyfin.itemImageUrl(serverUrl, it.Id, "Primary", "", imageOpts)
    }



    /* ========= Vu / reprise : transformations pures dans MediaCatalog ========= */

    /* ========= Restore ========= */

    // La position partagée sert encore à mémoriser le tri, mais elle ne doit
    // jamais restaurer le focus lors d'une ouverture depuis HomePage.
    // Seuls les paramètres explicites transmis par une page de détail sont admis.


    function _armFolderRestoreVisualLoading() {
        var idx = MediaCatalog.browserRestoreIndex(restoreIndex, startIndex)
        folderRestoreVisualTargetIndex = idx
        folderRestoreVisualLoading = (idx >= 0)
        folderRestoreRevealAttempts = 0
        folderRestoreStableSinceMs = 0
        try { restoreRevealTimer.stop() } catch(e) {}
    }

    function _releaseFolderRestoreVisualLoading() {
        try { restoreRevealTimer.stop() } catch(e) {}
        folderRestoreVisualLoading = false
        folderRestoreVisualTargetIndex = -1
        folderRestoreRevealAttempts = 0
        folderRestoreStableSinceMs = 0
        _restoring = false
        Qt.callLater(forceInitialFocus)
    }

    Timer {
        id: restoreRevealTimer
        interval: 60
        repeat: true
        running: false
        onTriggered: {
            folderRestoreRevealAttempts++
            var target = folderRestoreVisualTargetIndex
            var delegateReady = !!(grid && target >= 0 && grid.count > target
                                      && grid.currentIndex === target && grid.currentItem)
            var posterReady = delegateReady
                              && (typeof grid.currentItem.posterVisualReady === "undefined"
                                  || grid.currentItem.posterVisualReady === true)
            var gridStable = delegateReady
                             && !folderPageInFlight
                             && !loadingItems
                             && !grid.moving
                             && !grid.dragging
                             && !grid.flicking
                             && !(glideY && glideY.running)
            var visuallyReady = posterReady && gridStable
            var now = Date.now ? Date.now() : (new Date()).getTime()

            // Le loader reste devant la grille tant que le poster focalisé n'est
            // pas prêt et que la scène n'est pas restée stable pendant 1,1 s.
            // Cette marge absorbe les petits flashs des posters voisins lors de
            // leur création/décodage après une restauration au-delà de 220 items.
            if (visuallyReady) {
                if (folderRestoreStableSinceMs <= 0) folderRestoreStableSinceMs = now
                if ((now - folderRestoreStableSinceMs) >= folderRestoreVisualSettleMs) {
                    _releaseFolderRestoreVisualLoading()
                    return
                }
            } else {
                folderRestoreStableSinceMs = 0
            }

            // Garde-fou de 4,8 s maximum après positionnement final.
            if (folderRestoreRevealAttempts >= folderRestoreRevealMaxAttempts)
                _releaseFolderRestoreVisualLoading()
        }
    }

    function _applyRestore() {
        var idx = MediaCatalog.browserRestoreIndex(restoreIndex, startIndex)

        if (!folderItems || folderItems.length <= 0) {
            if (folderPageHasMore) {
                folderPageRestorePending = true
                if (idx >= 0) {
                    folderRestoreVisualLoading = true
                    folderRestoreVisualTargetIndex = idx
                }
                _requestFolderPage(true)
                return
            }
            _scheduleBackdropUpdate(false)
            _releaseFolderRestoreVisualLoading()
            return
        }

        var localTarget = idx >= 0 ? _localIndexForGlobal(idx) : -1
        if (idx >= 0 && localTarget < 0 && idx < folderWindowStartIndex && folderPageHasPrevious) {
            folderPageRestorePending = true
            folderRestoreVisualLoading = true
            folderRestoreVisualTargetIndex = idx
            _requestFolderPageBefore(true)
            return
        }

        if (idx >= 0 && localTarget < 0 && idx >= _windowKnownEnd() && folderPageHasMore) {
            folderPageRestorePending = true
            folderRestoreVisualLoading = true
            folderRestoreVisualTargetIndex = idx
            _requestFolderPage(true)
            return
        }

        _restoring = true
        var y = MediaCatalog.browserRestoreY(restoreY)

        // contentY est local à la fenêtre. Une coordonnée mémorisée avant un
        // décalage de fenêtre n'est donc pas réutilisable ; l'index global reste
        // l'ancre fiable et ensureVisible replace la ligne sans flash.
        if (y >= 0 && folderWindowStartIndex === 0) {
            grid.glideStop()
            grid.contentY = MediaCatalog.clampScrollableContentY(grid.contentHeight, grid.height, y)
        }

        if (localTarget >= 0 && localTarget < folderItems.length) {
            grid.currentIndex = localTarget
            grid.ensureVisible(localTarget, true)
        } else {
            // Cas défensif : la bibliothèque a rétréci depuis la sauvegarde.
            var fallbackSeed = idx >= 0 ? (idx - folderWindowStartIndex) : grid.currentIndex
            var fallbackIndex = Math.max(0, Math.min(folderItems.length - 1, fallbackSeed))
            grid.currentIndex = fallbackIndex
            grid.ensureVisible(fallbackIndex, true)
        }

        folderRestoreVisualTargetIndex = grid.currentIndex
        restoreIndex = -1
        startIndex   = -1
        restoreY     = -1

        _writeSharedStateNow()
        _scheduleBackdropUpdate(false)

        if (folderRestoreVisualLoading) {
            folderRestoreRevealAttempts = 0
            folderRestoreStableSinceMs = 0
            restoreRevealTimer.restart()
        } else {
            _restoring = false
            Qt.callLater(forceInitialFocus)
        }
    }

    /* ========= Fetch ========= */
    property int _fetchToken: 0

    function _cancelFolderPageRequest(reason) {
        var h = _folderPageHandle
        _folderPageHandle = null
        folderPageInFlight = false
        loadingItems = false
        try { if (h && h.cancel) h.cancel(reason || "context_changed") } catch(e) {}
    }

    function _resetFolderPaging() {
        _cancelFolderPageRequest("paging_reset")
        var state = MediaCatalog.browserInitialPagingState(folderRestoreVisualTargetIndex, folderPageSize)
        folderWindowStartIndex = state.windowStartIndex
        folderPageNextStart = state.nextStart
        folderPageHasMore = state.hasMore
        folderPageHasPrevious = state.hasPrevious
        folderPageInFlight = false
        folderPageRestorePending = false
        folderPrependNavSteps = 0
        folderLoadState = "initial"
        folderLoadErrorText = ""
        _rawFolderItems = []
        folderItems = []
        musicVideoMode = false
    }

    function _normalizePageItems(items) {
        if (!collectionsMode) return items || []
        var out = []
        for (var i = 0; items && i < items.length; ++i)
            if (_isCollectionItem(items[i])) out.push(items[i])
        return out
    }

    function _refreshLibraryMediaMode() {
        if (collectionsMode || hierarchicalMode || personalMode) { musicVideoMode = false; return }
        var a = _rawFolderItems || [], mv = 0, media = 0, n = Math.min(a.length, 16)
        for (var i = 0; i < n; i++) { var t = String(a[i] && a[i].Type || "").toLowerCase(); if (t === "movie" || t === "video" || t === "musicvideo") { media++; if (t === "musicvideo") mv++ } }
        musicVideoMode = media > 0 && mv === media
    }

    function _appendWindowFolderItems(items, start, prepend) {
        items = _normalizePageItems(items || [])
        if (!items || items.length <= 0) return 0
        var keepId = _selectedItemId()
        var result = MediaCatalog.browserAppendWindowItems(
                    _rawFolderItems || [], items, start, prepend,
                    folderPageSize, folderWindowMaxItems, keepId, folderWindowStartIndex)
        if (!result || result.added <= 0) return 0
        _rawFolderItems = result.items || []
        folderWindowStartIndex = result.windowStartIndex | 0
        if (result.nextStart !== null && result.nextStart !== undefined)
            folderPageNextStart = result.nextStart | 0
        if (result.hasMore === true) folderPageHasMore = true
        if (result.hasPrevious === true) folderPageHasPrevious = true
        return result.added | 0
    }

    function _requestFolderPageAt(start, prepend, restoreAfter) {
        _hydrateSensitiveContextFromShared()
        if (!accessToken || !userId || !serverUrl || !folderId) return
        if (folderPageInFlight) {
            if (restoreAfter) folderPageRestorePending = true
            return
        }
        if (prepend) {
            if (!folderPageHasPrevious) return
        } else if (!folderPageHasMore && folderPageNextStart > 0) {
            return
        }

        var t = _fetchToken
        start = Math.max(0, Number(start) | 0)
        var initialLoad = ((!_rawFolderItems || _rawFolderItems.length <= 0) && (!folderItems || folderItems.length <= 0))
        folderPageInFlight = true
        loadingItems = true
        folderLoadErrorText = ""
        folderLoadState = initialLoad ? "loadingInitial" : "loadingMore"

        var fetchPage = Jellyfin.fetchMovieFolderItemsPage
        if (personalMode && Jellyfin.fetchPersonalMediaFolderItemsPage)
            fetchPage = Jellyfin.fetchPersonalMediaFolderItemsPage
        else if (collectionsMode && Jellyfin.fetchCollectionFolderItemsPage)
            fetchPage = Jellyfin.fetchCollectionFolderItemsPage
        else if (normalizedLibraryMode === "mixed" && Jellyfin.fetchMixedFolderItemsPage)
            fetchPage = Jellyfin.fetchMixedFolderItemsPage
        else if (normalizedLibraryMode === "series")
            fetchPage = Jellyfin.fetchMediaBrowserItemsPage

        var requestHandle = null
        requestHandle = fetchPage(
            serverUrl, accessToken, userId, folderId, start, folderPageSize, sortMode,
            function(page) {
                if (t !== _fetchToken) return
                if (_folderPageHandle === requestHandle) _folderPageHandle = null
                folderPageInFlight = false
                loadingItems = false
                fetchedOnce = true

                var arr = (page && page.items) ? page.items : []
                _appendWindowFolderItems(arr, start, prepend)
                _refreshLibraryMediaMode()

                var progress = MediaCatalog.browserPageProgress(page, start, folderPageSize, prepend)
                if (progress.hasPrevious !== null) folderPageHasPrevious = progress.hasPrevious
                if (progress.nextStart !== null) folderPageNextStart = progress.nextStart
                if (progress.hasMore !== null) folderPageHasMore = progress.hasMore

                _applySort(true, false, true)
                if (prepend && folderPrependNavSteps > 0 && grid && grid.count > 0) {
                    var movieNavSteps = folderPrependNavSteps
                    folderPrependNavSteps = 0
                    grid.currentIndex = Math.max(0, grid.currentIndex - Math.max(1, grid.columns) * movieNavSteps)
                    grid.ensureVisible(grid.currentIndex, true)
                }
                folderLoadState = ((_rawFolderItems || []).length <= 0 && (!folderItems || folderItems.length <= 0)) ? "empty" : "ready"
                folderLoadErrorText = ""
                Qt.callLater(function() {
                    if (moviepage._scheduleSelectedAuxiliaryFetch) moviepage._scheduleSelectedAuxiliaryFetch()
                })
                if (restoreAfter || folderPageRestorePending) {
                    folderPageRestorePending = false
                    Qt.callLater(_applyRestore)
                } else {
                    Qt.callLater(function() {
                        _scheduleBackdropUpdate(false)
                        _scheduleMaybeLoadMoreForViewport()
                    })
                }
            },
            function(err) {
                if (t !== _fetchToken) return
                if (_folderPageHandle === requestHandle) _folderPageHandle = null
                folderPageInFlight = false
                loadingItems = false
                fetchedOnce = true
                var hasItems = (folderItems && folderItems.length > 0) || (_rawFolderItems && _rawFolderItems.length > 0)
                if (prepend) {
                    folderPageHasPrevious = false
                    folderPrependNavSteps = 0
                }
                else folderPageHasMore = false
                if (initialLoad && !hasItems) {
                    _rawFolderItems = []
                    folderItems = []
                    folderLoadState = "errorInitial"
                    folderLoadErrorText = "Impossible de charger cette bibliothèque."
                    _scheduleBackdropUpdate(false)
                    Qt.callLater(forceInitialFocus)
                } else {
                    folderLoadState = "errorMore"
                    folderLoadErrorText = "Chargement de la suite impossible."
                }
                if (folderRestoreVisualLoading) {
                    folderPageRestorePending = false
                    Qt.callLater(_applyRestore)
                }
            }
        )
        _folderPageHandle = requestHandle
    }

    function _requestFolderPage(restoreAfter) {
        _requestFolderPageAt(folderPageNextStart, false, restoreAfter)
    }

    function _requestFolderPageBefore(restoreAfter, navigateUp) {
        if (navigateUp === true)
            folderPrependNavSteps = Math.min(6, folderPrependNavSteps + 1)
        if (!folderPageHasPrevious || folderPageInFlight || loadingItems) return
        var start = MediaCatalog.browserPreviousPageStart(folderWindowStartIndex, folderPageSize)
        if (start < 0) {
            folderPageHasPrevious = false
            return
        }
        _requestFolderPageAt(start, true, restoreAfter)
    }

    Timer {
        id: loadMoreCoalesceTimer
        interval: 140
        repeat: false
        onTriggered: moviepage._maybeLoadMoreForViewport()
    }

    function _scheduleMaybeLoadMoreForViewport() {
        if ((!folderPageHasMore && !folderPageHasPrevious) || folderPageInFlight || loadingItems) return
        loadMoreCoalesceTimer.restart()
    }

    function _maybeLoadMoreForViewport() {
        if ((!folderPageHasMore && !folderPageHasPrevious) || folderPageInFlight || loadingItems) return
        if (!folderItems || folderItems.length <= 0) { _requestFolderPage(false); return }
        var idx = grid ? (grid.currentIndex | 0) : -1
        var direction = MediaCatalog.browserViewportLoadDirection(
                    idx, folderItems.length, folderPageHasPrevious, folderPageHasMore,
                    folderPagePrependThreshold, folderPageAppendThreshold)
        if (direction < 0) {
            _requestFolderPageBefore(false)
            return
        }
        if (direction > 0) _requestFolderPage(false)
    }


    // Même garde que seriepage : la navigation ctx=1 injecte le contexte en plusieurs étapes
    // (shared puis accessToken/userId/serverUrl/folderId). On regroupe ces changements pour

    function _baseSelectedItem() {
        return MediaCatalog.browserSelectedItem(folderItems, grid ? grid.currentIndex : -1)
    }

    function _mergeItemForHeader(base, detail) {
        if (!base) return detail || null
        if (!detail) return base
        var out = {}
        var k
        for (k in base) out[k] = base[k]
        for (k in detail) {
            if (detail[k] !== undefined && detail[k] !== null)
                out[k] = detail[k]
        }
        return out
    }

    function itemWithDetailForHeader(base) {
        if (!base || !base.Id) return base
        var cache = _detailCacheById || {}
        var detail = cache[String(base.Id)]
        return detail ? _mergeItemForHeader(base, detail) : base
    }

    function _itemNeedsMediaDetail(it) {
        if (!it || !it.Id || _isBrowserFolder(it)) return false
        if (_isBrowserSeries(it)) return true
        if (it.MediaStreams && it.MediaStreams.length > 0) return false
        return true
    }

    function _compactStreamsForTags(streams) {
        var out = []
        for (var i = 0; streams && i < streams.length; ++i) {
            var st = streams[i]
            if (!st) continue
            out.push({
                Type: st.Type || "", Codec: st.Codec || "", Width: Number(st.Width || 0),
                Height: Number(st.Height || 0), ChannelLayout: st.ChannelLayout || "",
                Channels: Number(st.Channels || 0), Language: st.Language || "",
                DisplayTitle: st.DisplayTitle || "", Title: st.Title || "", Name: st.Name || "",
                BitRate: Number(st.BitRate || 0), IsDefault: !!st.IsDefault
            })
        }
        return out
    }

    function _compactItemDetailForTags(detail) {
        if (!detail) return null
        var out = ({
            Id: detail.Id, Type: detail.Type, CollectionType: detail.CollectionType,
            Name: detail.Name, RunTimeTicks: detail.RunTimeTicks,
            RunTimeSeconds: detail.RunTimeSeconds, AverageRuntime: detail.AverageRuntime,
            Runtime: detail.Runtime, OfficialRating: detail.OfficialRating,
            CustomRating: detail.CustomRating, CommunityRating: detail.CommunityRating,
            ProductionYear: detail.ProductionYear, PremiereDate: detail.PremiereDate,
            Width: detail.Width, Height: detail.Height,
            Bitrate: detail.Bitrate, Container: detail.Container
        })
        if (detail.MediaStreams !== undefined && detail.MediaStreams !== null)
            out.MediaStreams = _compactStreamsForTags(detail.MediaStreams)
        return out
    }

    function _storeItemDetailForTags(id, detail) {
        if (!id || !detail) return
        id = String(id)
        var old = _detailCacheById || {}
        var next = {}
        var k
        for (k in old) next[k] = old[k]
        next[id] = _compactItemDetailForTags(detail)

        var order = (_detailCacheOrder || []).slice(0)
        var idx = order.indexOf(id)
        if (idx >= 0) order.splice(idx, 1)
        order.push(id)
        while (order.length > detailCacheMax) {
            var victim = order.shift()
            if (victim && victim !== id) delete next[victim]
        }
        _detailCacheOrder = order
        _detailCacheById = next
    }

    Timer {
        id: selectedDetailFetchTimer
        // Le détail MediaStreams est purement décoratif pour la ligne header.
        // Le différer évite de concurrencer la première page et ses images.
        interval: 500
        repeat: false
        onTriggered: {
            if (moviepage.isGridInMotion) { restart(); return }
            moviepage._fetchSelectedItemDetailForTags()
        }
    }

    function _scheduleSelectedItemDetailFetch() {
        var selected = _baseSelectedItem()
        var selectedId = selected && selected.Id ? String(selected.Id) : ""
        if (_detailFetchInFlightId && _detailFetchInFlightId !== selectedId)
            _cancelSelectedDetailRequest()
        if (!ready || loadingItems || !accessToken || !serverUrl || !selectedId) return
        if (isGridInMotion) { selectedDetailFetchTimer.restart(); return }
        selectedDetailFetchTimer.restart()
    }

    function _cancelSelectedDetailRequest() {
        selectedDetailFetchTimer.stop()
        ++_detailFetchToken
        var h = _detailFetchHandle
        _detailFetchHandle = null
        _detailFetchInFlightId = ""
        try { if (h && h.cancel) h.cancel() } catch(e) {}
    }

    function _fetchSelectedItemDetailForTags() {
        if (!ready || loadingItems || !accessToken || !serverUrl) return
        if (isGridInMotion) { selectedDetailFetchTimer.restart(); return }
        var it = _baseSelectedItem()
        if (!_itemNeedsMediaDetail(it)) return
        var id = String(it.Id || "")
        if (!id) return
        if ((_detailCacheById || {})[id]) return
        if (_detailFetchInFlightId === id) return

        _detailFetchToken++
        var token = _detailFetchToken
        _detailFetchInFlightId = id
        try {
            _detailFetchHandle = Jellyfin.fetchItem(serverUrl, accessToken, id, function(detail) {
                if (token !== _detailFetchToken) return
                _detailFetchHandle = null
                if (_detailFetchInFlightId === id) _detailFetchInFlightId = ""
                if (detail && detail.Id)
                    _storeItemDetailForTags(id, detail)
            }, function() {
                if (token === _detailFetchToken) _detailFetchHandle = null
                if (token === _detailFetchToken && _detailFetchInFlightId === id)
                    _detailFetchInFlightId = ""
            })
        } catch(e) {
            _detailFetchInFlightId = ""
        }
    }

    // éviter un fetch trop tôt ou une réponse vide qui gagnerait la course côté MoviePage.
    Timer {
        id: fetchDebounceTimer
        interval: 80
        repeat: false
        onTriggered: fetchFolder()
    }

    function scheduleFetchFolder() {
        if (!ready) return
        _cancelFolderPageRequest("context_changed")
        fetchDebounceTimer.restart()
    }

    function fetchFolder() {
        _hydrateSensitiveContextFromShared()
        if (!accessToken || !userId || !serverUrl || !folderId) return

        _fetchToken++
        _restoreSortFromShared()
        _armFolderRestoreVisualLoading()
        _resetFolderPaging()
        if (collectionsMode) {
            childCountCache = ({})
            noCountMetaCache = ({})
            _countQueue = []
            _countInFlight = false
            _countTargetId = ""
            _countFocusDwellId = ""
            _countFallbackPendingId = ""
            _countSeq++
            countFocusFallbackTimer.stop()
        }
        loadingItems = true
        fetchedOnce = false
        folderLoadState = "loadingInitial"
        folderLoadErrorText = ""
        _requestFolderPage(true)
    }

    Component.onCompleted: {

        _hydrateSensitiveContextFromShared()
        ready = true
        scheduleFetchFolder()
        Qt.callLater(forceInitialFocus)
    }

    onVisibleChanged: {
        if (visible) {
            var hydrated = _hydrateSensitiveContextFromShared()
            if (hydrated && ready)
                scheduleFetchFolder()
            else if (ready && accessToken && userId && serverUrl && folderId && (!folderItems || folderItems.length === 0))
                scheduleFetchFolder()
        }
    }

    onSharedChanged: {
        if (_hydrateSensitiveContextFromShared()) {
            if (ready) scheduleFetchFolder()
        }
    }

    onAccessTokenChanged: scheduleFetchFolder()
    onUserIdChanged:      scheduleFetchFolder()
    onServerUrlChanged:   scheduleFetchFolder()
    onFolderIdChanged:    scheduleFetchFolder()
    onLibraryModeChanged: scheduleFetchFolder()
    // ShellPage injecte le backend après la création du Loader. Si l'identité du
    // Player arrive pendant le debounce initial, on annule/reprogramme proprement
    // afin qu'une Révolution ne parte jamais sur une page Devialet de 220.
    onPlaybackDeviceModeChanged: scheduleFetchFolder()

    /* ========= Fond noir + Backdrop ========= */
    Rectangle { anchors.fill: parent; color: "#000" }

    Item {
        id: backdrop
        anchors.fill: parent
        visible: true

        // Lot 2 : double-buffer backdrop. L'ancien fond reste visible tant que le nouveau n'est pas prêt.
        property string lastUrl: ""
        property string visibleUrl: ""
        property string loadingUrl: ""
        property int loadingIndex: -1
        property bool showB: false
        property bool triedNoBackdropFallback: false

        function computeBGUrl(idx, preferBackdrop) {
            var it = (folderItems.length > 0 && idx >= 0 && idx < folderItems.length) ? folderItems[idx] : null
            if (!it) return ""
            var B = MediaCatalog.clampBlur(bgBlur)
            return posterUrlFor(it, bgW, bgH, { preferBackdrop: (preferBackdrop === true), blur: B, quality: 78 })
        }

        function _loadingImage() { return showB ? bgA : bgB }

        function _clearAll() {
            if (String(bgA.source || "") !== "") bgA.source = ""
            if (String(bgB.source || "") !== "") bgB.source = ""
            lastUrl = ""
            visibleUrl = ""
            loadingUrl = ""
            loadingIndex = -1
            showB = false
            triedNoBackdropFallback = false
        }

        function updateBackdropNow(idx) {
            if (!bgA || !bgB) return
            if (!folderItems || folderItems.length <= 0) {
                _clearAll()
                return
            }

            var url = computeBGUrl(idx, true)
            if (!url) { _clearAll(); return }
            if (url === visibleUrl || url === loadingUrl) return

            triedNoBackdropFallback = false
            lastUrl = url
            loadingUrl = url
            loadingIndex = idx

            var img = _loadingImage()
            if (String(img.source || "") !== String(url || "")) img.source = url
            else if (img.status === Image.Ready) { if (showB) _promoteA(); else _promoteB() }
        }

        function _promoteA() {
            var src = String(bgA.source || "")
            if (!src || src !== loadingUrl) return
            visibleUrl = src
            loadingUrl = ""
            loadingIndex = -1
            showB = false
        }

        function _promoteB() {
            var src = String(bgB.source || "")
            if (!src || src !== loadingUrl) return
            visibleUrl = src
            loadingUrl = ""
            loadingIndex = -1
            showB = true
        }

        function _tryFallbackForLoading() {
            if (triedNoBackdropFallback || !loadingUrl.length) return
            triedNoBackdropFallback = true
            var idx = loadingIndex >= 0 ? loadingIndex : (grid ? grid.currentIndex : -1)
            var fb = computeBGUrl(idx, false)
            if (fb && fb !== loadingUrl && fb !== visibleUrl) {
                loadingUrl = fb
                loadingIndex = idx
                lastUrl = fb
                var img = _loadingImage()
                if (String(img.source || "") !== String(fb || "")) img.source = fb
                else if (img.status === Image.Ready) { if (showB) _promoteA(); else _promoteB() }
            } else if (!visibleUrl) {
                _clearAll()
            }
        }

        Image {
            id: bgA
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            mipmap: false
            smooth: false
            opacity: (!backdrop.showB && status === Image.Ready && backdrop.visibleUrl !== "") ? 0.92 : 0.0
            Behavior on opacity { enabled: moviepage.allowBgAnims; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            onStatusChanged: {
                if (status === Image.Ready) backdrop._promoteA()
                else if (status === Image.Error && String(source || "") === backdrop.loadingUrl) backdrop._tryFallbackForLoading()
            }
        }

        Image {
            id: bgB
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            mipmap: false
            smooth: false
            opacity: (backdrop.showB && status === Image.Ready && backdrop.visibleUrl !== "") ? 0.92 : 0.0
            Behavior on opacity { enabled: moviepage.allowBgAnims; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            onStatusChanged: {
                if (status === Image.Ready) backdrop._promoteB()
                else if (status === Image.Error && String(source || "") === backdrop.loadingUrl) backdrop._tryFallbackForLoading()
            }
        }

        Rectangle {
            anchors.fill: parent
            color: "#000"
            readonly property real a: Math.max(0.0, Math.min(1.0, moviepage.bgDarken))
            opacity: (backdrop.visibleUrl !== "") ? a : 0.0
            Behavior on opacity {
                enabled: moviepage.allowBgAnims
                NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
            }
        }
    }

    /* ========= HUD haut-droite ========= */
    FocusScope {
        id: topBar
        z: 10
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: 24
        anchors.topMargin: 20
        width: rightRow.implicitWidth
        height: rightRow.implicitHeight

        readonly property bool hudHasFocus: !!(clockHudLoader.item && clockHudLoader.item.containsActiveFocus)
        readonly property bool sortHasFocus: !!(sortButton && (sortButton.containsActiveFocus || sortButton.popupOpen))
        readonly property bool keepHudVisible: hudHasFocus || sortHasFocus || moviepage.hudPinned || moviepage.currentFocusTarget === moviepage.focusHud || moviepage.currentFocusTarget === moviepage.focusSort
        readonly property real fadeBase: Math.max(0.0, 1.0 - Math.min(1.0, moviepage.scrollProgress * 1.25))

        opacity: keepHudVisible ? 1.0 : fadeBase
        y:      keepHudVisible ? 0 : -(18 * (1.0 - fadeBase))
        visible: keepHudVisible ? true : (opacity > 0.02)

        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on y       { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        Keys.onPressed: {
            if (!clockHudLoader.item || !clockHudLoader.item.containsActiveFocus) return

            if (event.key === Qt.Key_Down) {
                if (sortButton && sortButton.visible) moviepage.focusSortButton()
                else moviepage.focusGridFromSort()
                event.accepted = true
                return
            }

            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                moviepage._openLoginRoot()
                event.accepted = true
                return
            }
        }

        Row {
            id: rightRow
            spacing: 12

            Item {
                id: clockHudWrap
                width: clockHudLoader.item ? clockHudLoader.item.implicitWidth : (avatarSize + 160)
                height: clockHudCoreH + (profileName.visible ? (profileName.height + 2) : 0) + sortAreaH

                readonly property int clockHudCoreH: clockHudLoader.item ? clockHudLoader.item.implicitHeight : avatarSize
                readonly property int sortAreaH: (folderItems && folderItems.length > 1) ? 44 : 0
                readonly property bool sortFocusDecorActive: !!(sortButton && sortButton.visible
                    && (sortButton.containsActiveFocus || sortButton.popupOpen
                        || moviepage.currentFocusTarget === moviepage.focusSort))
                // Le ClockHUD est plus large que l'avatar car il contient aussi l'horloge.
                // Le nom doit donc être centré sur l'avatar lui-même, pas sur le bord droit du HUD.
                readonly property int profileNameW: Math.max(moviepage.avatarSize + 28, Math.min(128, width))

                Loader {
                    id: clockHudLoader
                    width: clockHudWrap.width
                    height: clockHudWrap.clockHudCoreH
                    active: (topBar.visible || moviepage.hudPinned || moviepage.currentFocusTarget === moviepage.focusHud || moviepage.currentFocusTarget === moviepage.focusSort)
                    visible:(topBar.visible || moviepage.hudPinned || moviepage.currentFocusTarget === moviepage.focusHud || moviepage.currentFocusTarget === moviepage.focusSort)
                    sourceComponent: clockHudComp
                }

                Text { textFormat: Text.PlainText;
                    id: profileName
                    anchors.top: clockHudLoader.bottom
                    anchors.topMargin: 2
                    // Avatar placé au début du ClockHUD : on centre le label sur sa largeur réelle.
                    x: Math.round((moviepage.avatarSize - width) / 2)
                    width: clockHudWrap.profileNameW
                    height: visible ? 16 : 0
                    visible: text.length > 0
                    text: String(moviepage.userName || "")
                    color: Qt.rgba(1, 1, 1, 0.82)
                    font.pixelSize: 12
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                }

                Components.SortHudButton {
                    id: sortButton
                    anchors.top: profileName.bottom
                    anchors.topMargin: 4
                    x: Math.round((moviepage.avatarSize - width) / 2)
                    visible: clockHudWrap.sortAreaH > 0
                    options: moviepage.sortOptionLabels
                    selectedIndex: moviepage.sortMode
                    label: moviepage.sortButtonText()
                    accentColor: "#7DEAE4"
                    onActivated: moviepage.setSortMode(index)
                    onRequestFocusAvatar: moviepage.focusHudAvatar()
                    onRequestFocusGrid: moviepage.focusGridFromSort()
                }

                // Double repère de focus du tri : deux traits fins au-dessus et
                // en dessous du bouton A-Z, sans QtQuick Controls ni effet GPU.
                Rectangle {
                    id: sortFocusLineTop
                    z: sortButton.z + 1
                    anchors.horizontalCenter: sortButton.horizontalCenter
                    anchors.bottom: sortButton.top
                    anchors.bottomMargin: 1
                    width: clockHudWrap.sortFocusDecorActive ? Math.max(40, sortButton.width + 2) : 0
                    height: 2
                    radius: 1
                    color: "#FFFFFF"
                    opacity: clockHudWrap.sortFocusDecorActive ? 1.0 : 0.0
                    visible: sortButton.visible && (width > 0 || opacity > 0.01)
                    Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    Behavior on opacity { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
                }

                Rectangle {
                    id: sortFocusLineBottom
                    z: sortButton.z + 1
                    anchors.horizontalCenter: sortButton.horizontalCenter
                    anchors.top: sortButton.bottom
                    anchors.topMargin: 1
                    width: clockHudWrap.sortFocusDecorActive ? Math.max(40, sortButton.width + 2) : 0
                    height: 2
                    radius: 1
                    color: "#FFFFFF"
                    opacity: clockHudWrap.sortFocusDecorActive ? 1.0 : 0.0
                    visible: sortButton.visible && (width > 0 || opacity > 0.01)
                    Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    Behavior on opacity { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
                }

                MouseArea {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: clockHudWrap.clockHudCoreH + (profileName.visible ? (profileName.height + 2) : 0)
                    hoverEnabled: true
                    onEntered: moviepage.focusHudAvatar()
                    onClicked:  moviepage.focusHudAvatar()
                }
            }

            Column {
                spacing: 6
                Rectangle {
                    height: 28
                    width: counterText.paintedWidth + 16
                    radius: 8
                    color: "#23244a"
                    border.color: "#6e7bf4"
                    border.width: 1
                    visible: !!(folderItems && folderItems.length > 0)
                    Text { textFormat: Text.PlainText;
                        id: counterText
                        anchors.centerIn: parent
                        text: {
                            var total = folderItems ? folderItems.length : 0
                            if (total <= 0) return ""
                            var idx = Math.max(0, moviepage._globalIndexForLocal(grid.currentIndex))
                            var known = Math.max(idx + 1, moviepage._windowKnownEnd())
                            return (idx + 1) + "|" + known + (moviepage.folderPageHasMore ? "+" : "")
                        }
                        color: "#ffffff"
                        font.pixelSize: 14
                        font.bold: true
                    }
                }
            }
        }
    }

    Component {
        id: clockHudComp
        Components.ClockHUD {
            fbx:          moviepage.fbx
            serverUrl:    moviepage.serverUrl
            userId:       moviepage.userId
            userImageTag: moviepage.userImageTag

            showAvatar: true
            avatarSize: moviepage.avatarSize
            fontPx: 22

            visible: (topBar.visible || moviepage.hudPinned || moviepage.currentFocusTarget === moviepage.focusHud) && moviepage.visible

            // ✅ TWEAK 7: active strict
            active:  (topBar.visible || moviepage.hudPinned || moviepage.currentFocusTarget === moviepage.focusHud)
                     && moviepage.visible
                     && !moviepage.isScrolling

            onRequestFocusBelow: {
                if (sortButton && sortButton.visible) moviepage.focusSortButton()
                else moviepage.focusGridFromSort()
            }
        }
    }

    Rectangle {
        id: floatingCounter
        z: 11
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 24
        anchors.rightMargin: 24

        height: 28
        radius: 8
        color: "#23244a"
        border.color: "#6e7bf4"
        border.width: 1

        visible: {
            var total = folderItems ? folderItems.length : 0
            return (total > 0) && (moviepage.scrollProgress > 0.15)
        }

        Text { textFormat: Text.PlainText;
            id: floatingCounterText
            anchors.centerIn: parent
            text: {
                var total = folderItems ? folderItems.length : 0
                if (total <= 0) return ""
                var idx = Math.max(0, moviepage._globalIndexForLocal(grid.currentIndex))
                var known = Math.max(idx + 1, moviepage._windowKnownEnd())
                return (idx + 1) + "|" + known + (moviepage.folderPageHasMore ? "+" : "")
            }
            color: "#ffffff"
            font.pixelSize: 14
            font.bold: true
        }

        width: floatingCounterText.paintedWidth + 16
    }

    /* ========= Bandeau infos ========= */
    Item {
        id: headerArea
        z: 3
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: headerTop
        anchors.leftMargin: marginL
        anchors.rightMargin: marginR
        height: headerInfos.implicitHeight
        visible: !!(folderItems && folderItems.length > 0)

        Column {
            id: headerInfos
            width: parent.width
            spacing: 6

            property var selectedItemBase: moviepage._baseSelectedItem()
            property var selectedItem: moviepage.collectionsMode ? selectedItemBase : moviepage.itemWithDetailForHeader(selectedItemBase)
            readonly property int collectionItemsCount: moviepage.collectionsMode ? moviepage.effectiveCollectionItemCount(selectedItem) : 0
            readonly property bool selectedIsSeries: moviepage._isBrowserSeries(selectedItem)
            readonly property bool selectedIsFolder: moviepage._isBrowserFolder(selectedItem)
            readonly property string seriesRange: selectedIsSeries ? MediaCatalog.seriesProductionRange(selectedItem) : ""
            readonly property int seriesRangeArrowPos: seriesRange.indexOf("→")
            readonly property bool seriesRangeHasArrow: selectedIsSeries && seriesRangeArrowPos >= 0
            readonly property string seriesRangeStart: {
                if (!selectedIsSeries || !seriesRange.length) return ""
                var p = seriesRangeArrowPos
                return (p >= 0 ? seriesRange.substring(0, p) : seriesRange).replace(/^\s+|\s+$/g, "")
            }
            readonly property string seriesRangeEnd: {
                if (!selectedIsSeries || seriesRangeArrowPos < 0) return ""
                return seriesRange.substring(seriesRangeArrowPos + 1).replace(/^\s+|\s+$/g, "")
            }
            readonly property int seriesEpisodeMin: selectedIsSeries ? MediaCatalog.seriesEpisodeMinutes(selectedItem) : 0
            property int movieRuntimeSeconds: MediaCatalog.mediaRuntimeSeconds(selectedItem)
            property string movieDurationHms: movieRuntimeSeconds > 0 ? MediaCatalog.formatDurationHms(movieRuntimeSeconds) : ""
            property string ageTag: MediaCatalog.mediaAgeTag(selectedItem)
            // Résumé des flux calculé une seule fois dans MediaCatalog.
            property var streamInfo: moviepage.personalMode
                                     ? MediaCatalog.personalMediaStreamInfo(selectedItem)
                                     : MediaCatalog.movieStreamInfo(selectedItem)
            readonly property string activeTitle: (selectedItem && selectedItem.Name) ? ("" + selectedItem.Name)
                                                : (moviepage.collectionsMode ? "COLLECTIONS"
                                                : (moviepage.musicVideoMode ? "(Aucun clip sélectionné)"
                                                : (moviepage.personalMode ? "(Aucun média sélectionné)"
                                                : (moviepage.hierarchicalMode ? "(Aucun contenu sélectionné)" : "(Aucun film sélectionné)"))))
            property int titleCharLimit: 54
            property int titleFontPx: 34
            property var tagChips: moviepage.personalMode
                                   ? MediaCatalog.personalMediaTagChips(streamInfo)
                                   : MediaCatalog.movieBrowserTagChips(
                                         selectedItem,
                                         streamInfo,
                                         ageTag,
                                         moviepage.collectionsMode,
                                         moviepage._isBrowserSeries(selectedItem),
                                         moviepage._isBrowserFolder(selectedItem))
            FontMetrics {
                id: movieTitleMetrics
                font.pixelSize: headerInfos.titleFontPx
                font.bold: true
            }
            readonly property bool titleShouldMarquee: (activeTitle && activeTitle.length > titleCharLimit)
            /* ===== Titre — marquee identique detailCollectionPage ===== */
            Item {
                id: movieTitleLineBox
                width: headerInfos.titleShouldMarquee ? Math.min(headerInfos.width, MediaCatalog.titleTextCapPx(movieTitleMetrics.averageCharacterWidth, titleCharLimit)) : headerInfos.width
                height: Math.max(38, movieTitleTextItem.implicitHeight + 2)
                clip: false
                visible: !!headerInfos.selectedItem
                readonly property bool allowMarquee: moviepage.visible
                                                     && moviepage.allowDecos
                                                     && !moviepage.loadingItems
                                                     && !moviepage.isScrolling
                                                     && !!headerInfos.selectedItem
                                                     && visible
                readonly property bool marqueeNeeded: movieTitleTextItem.paintedWidth > movieTitleLineBox.width
                readonly property real marqueeOverflow: Math.max(0, movieTitleTextItem.paintedWidth - movieTitleLineBox.width)
                readonly property int  marqueeGap: 44
                readonly property real marqueeTravel: marqueeNeeded ? Math.max(0, movieTitleTextItem.paintedWidth + marqueeGap) : 0
                readonly property real marqueeExitX: marqueeTravel > 0 ? -marqueeTravel : 0
                readonly property int  marqueeScrollMs: marqueeTravel > 0 ? Math.max(3200, Math.min(14000, Math.round(marqueeTravel * 24))) : 0
                readonly property int  marqueeFadeW: Math.min(58, Math.max(28, Math.round(width * 0.12)))
                readonly property bool marqueeArmed: marqueeNeeded && allowMarquee
                property bool marqueeMoving: false
                readonly property bool maskActive: marqueeArmed && marqueeMoving
                readonly property bool leftFadeActive: maskActive && (movieTitleTextItem.x < -2)
                readonly property bool rightFadeActive: maskActive && (movieTitleTextItem.x > -marqueeOverflow + 2)
                onAllowMarqueeChanged: updateMarquee()
                onWidthChanged: updateMarquee()
                onVisibleChanged: updateMarquee()
                onMarqueeNeededChanged: updateMarquee()
                Item {
                    id: movieTitleLineSource
                    anchors.fill: parent
                    clip: true
                    visible: !movieTitleLineBox.maskActive
                    Text { textFormat: Text.PlainText;
                        id: movieTitleTextItem
                        x: 0
                        y: Math.round((movieTitleLineSource.height - height) / 2)
                        text: headerInfos.activeTitle || ""
                        font.pixelSize: headerInfos.titleFontPx
                        font.bold: true
                        color: "#fff"
                        wrapMode: Text.NoWrap
                        elide: movieTitleLineBox.allowMarquee ? Text.ElideNone : Text.ElideRight
                        onTextChanged: movieTitleLineBox.updateMarquee()
                        onPaintedWidthChanged: movieTitleLineBox.updateMarquee()
                    }
                }
                OpacityMask {
                    id: movieTitleMaskedLine
                    anchors.fill: parent
                    visible: movieTitleLineBox.maskActive
                    source: movieTitleLineSource
                    maskSource: movieTitleFadeMask
                    cached: false
                }
                Item {
                    id: movieTitleFadeMask
                    visible: movieTitleLineBox.maskActive
                    x: -10000
                    y: -10000
                    width: movieTitleLineBox.width
                    height: movieTitleLineBox.height
                    readonly property int leftW: movieTitleLineBox.leftFadeActive ? movieTitleLineBox.marqueeFadeW : 0
                    readonly property int rightW: movieTitleLineBox.rightFadeActive ? movieTitleLineBox.marqueeFadeW : 0
                    Rectangle {
                        visible: movieTitleFadeMask.leftW > 0
                        x: 0
                        y: 0
                        width: movieTitleFadeMask.leftW
                        height: parent.height
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "#00FFFFFF" }
                            GradientStop { position: 1.0; color: "#FFFFFFFF" }
                        }
                    }
                    Rectangle {
                        x: movieTitleFadeMask.leftW
                        y: 0
                        width: Math.max(0, parent.width - movieTitleFadeMask.leftW - movieTitleFadeMask.rightW)
                        height: parent.height
                        color: "#FFFFFFFF"
                    }
                    Rectangle {
                        visible: movieTitleFadeMask.rightW > 0
                        x: parent.width - movieTitleFadeMask.rightW
                        y: 0
                        width: movieTitleFadeMask.rightW
                        height: parent.height
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "#FFFFFFFF" }
                            GradientStop { position: 1.0; color: "#00FFFFFF" }
                        }
                    }
                }
                SequentialAnimation {
                    id: movieTitleMarquee
                    running: false
                    loops: Animation.Infinite
                    ScriptAction { script: { movieTitleLineBox.marqueeMoving = false; movieTitleTextItem.x = 0; movieTitleTextItem.opacity = 1.0 } }
                    PauseAnimation { duration: 700 }
                    ScriptAction { script: { movieTitleLineBox.marqueeMoving = true } }
                    NumberAnimation {
                        target: movieTitleTextItem
                        property: "x"
                        from: 0
                        to: movieTitleLineBox.marqueeExitX
                        duration: movieTitleLineBox.marqueeScrollMs
                        easing.type: Easing.Linear
                    }
                    ScriptAction { script: { movieTitleTextItem.x = 0; movieTitleTextItem.opacity = 1.0; movieTitleLineBox.marqueeMoving = false } }
                    PauseAnimation { duration: 180 }
                    PauseAnimation { duration: 260 }
                    onRunningChanged: {
                        if (!running) {
                            movieTitleLineBox.marqueeMoving = false
                            movieTitleTextItem.x = 0
                            movieTitleTextItem.opacity = 1.0
                        }
                    }
                }
                function updateMarquee() {
                    movieTitleMarquee.stop()
                    movieTitleTextItem.x = 0
                    movieTitleTextItem.opacity = 1.0
                    movieTitleLineBox.marqueeMoving = false
                    if (movieTitleLineBox.marqueeArmed && movieTitleLineBox.marqueeScrollMs > 0) {
                        Qt.callLater(function(){
                            if (movieTitleLineBox.marqueeArmed && movieTitleLineBox.marqueeNeeded && movieTitleLineBox.marqueeScrollMs > 0)
                                movieTitleMarquee.start()
                        })
                    }
                }
            }
            Row {
                id: collectionInfoRow
                // En mode Collections, ne réserver une ligne séparée que lorsqu'il
                // n'y a aucun genre/tag à afficher. Si des tags existent, compteur
                // et âge sont fusionnés dans movieMetaLine afin de garder la même
                // hauteur de header que Films/Séries et éviter le petit glide du
                // premier rang vers le second.
                visible: moviepage.collectionsMode
                         && !!headerInfos.selectedItem
                         && !(headerInfos.tagChips && headerInfos.tagChips.length > 0)
                spacing: 10
                height: 28

                Text { textFormat: Text.PlainText;
                    id: collectionCountText
                    anchors.verticalCenter: parent.verticalCenter
                    color: "#e9ecff"
                    opacity: 0.95
                    font.pixelSize: 18
                    text: {
                        if (!headerInfos.selectedItem) return ""
                        var n = headerInfos.collectionItemsCount
                        if (n < 0) return "Chargement…"
                        return n + " " + (n === 1 ? "objet" : "objets")
                    }
                }

                Rectangle {
                    id: collectionAgeBadge
                    anchors.verticalCenter: parent.verticalCenter
                    visible: headerInfos.ageTag.length > 0
                    height: 26
                    radius: 7
                    color: "#FFFFFF"
                    width: collectionAgeBadgeText.paintedWidth + 16

                    Text { textFormat: Text.PlainText;
                        id: collectionAgeBadgeText
                        anchors.centerIn: parent
                        text: {
                            var value = String(headerInfos.ageTag || "")
                            return value.replace(/^\s*Âge\s*:\s*/i, "")
                        }
                        color: "#000000"
                        font.pixelSize: 14
                        font.bold: true
                    }
                }
            }
            Text { textFormat: Text.PlainText;
                visible: moviepage.musicVideoMode && text.length > 0
                text: MediaCatalog.mediaArtistsText(headerInfos.selectedItem)
                color: "#D7DCF2"; font.pixelSize: 18; font.bold: true
                width: headerInfos.width; elide: Text.ElideRight; wrapMode: Text.NoWrap
            }
            /* ===== Ligne méta — note/date/durée fixes + tags marquee detailCollectionPage ===== */
            Item {
                id: movieMetaLine
                width: headerInfos.width
                height: Math.max(30, Math.max(movieFixedMetaRow.implicitHeight, movieTagsClip.height))
                // Collections ne doit jamais cumuler deux lignes méta : quand il
                // n'y a pas de genres, collectionInfoRow suffit ; quand il y en a,
                // cette ligne regroupe compteur + âge + genres.
                visible: !!headerInfos.selectedItem
                         && (!moviepage.collectionsMode
                             || (headerInfos.tagChips && headerInfos.tagChips.length > 0))
                Row {
                    id: movieFixedMetaRow
                    spacing: 12
                    height: 30
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter

                    Text { textFormat: Text.PlainText;
                        visible: moviepage.collectionsMode
                        text: {
                            if (!headerInfos.selectedItem) return ""
                            var n = headerInfos.collectionItemsCount
                            if (n < 0) return "Chargement…"
                            return n + " " + (n === 1 ? "objet" : "objets")
                        }
                        color: "#e9ecff"
                        opacity: 0.95
                        font.pixelSize: 18
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Rectangle {
                        visible: moviepage.collectionsMode && headerInfos.ageTag.length > 0
                        height: 26
                        radius: 7
                        color: "#FFFFFF"
                        width: collectionInlineAgeText.paintedWidth + 16
                        anchors.verticalCenter: parent.verticalCenter
                        Text { textFormat: Text.PlainText;
                            id: collectionInlineAgeText
                            anchors.centerIn: parent
                            text: {
                                var value = String(headerInfos.ageTag || "")
                                return value.replace(/^\s*Âge\s*:\s*/i, "")
                            }
                            color: "#000000"
                            font.pixelSize: 14
                            font.bold: true
                        }
                    }
                    Row {
                        spacing: 6
                        height: parent.height
                        visible: !moviepage.collectionsMode && headerInfos.selectedItem && headerInfos.selectedItem.CommunityRating !== undefined
                        Text { textFormat: Text.PlainText;
                            text: "★"
                            color: "#FFC107"
                            font.pixelSize: 20
                            font.bold: true
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text { textFormat: Text.PlainText;
                            text: (headerInfos.selectedItem && headerInfos.selectedItem.CommunityRating !== undefined)
                                  ? ((headerInfos.selectedItem.CommunityRating || 0).toFixed(1))
                                  : ""
                            color: "#e9ecff"
                            font.pixelSize: 18
                            font.bold: true
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    Item {
                        id: movieDateOrSeriesRange
                        height: parent.height
                        width: headerInfos.selectedIsSeries
                               ? movieSeriesRangeRow.implicitWidth
                               : moviePremiereDateText.implicitWidth
                        visible: !moviepage.collectionsMode
                                 && !headerInfos.selectedIsFolder
                                 && (headerInfos.selectedIsSeries
                                     ? headerInfos.seriesRange.length > 0
                                     : moviePremiereDateText.text.length > 0)

                        Text {
                            id: moviePremiereDateText
                            visible: !headerInfos.selectedIsSeries
                            anchors.verticalCenter: parent.verticalCenter
                            text: headerInfos.selectedItem
                                  ? MediaCatalog.formatDateShortFr(headerInfos.selectedItem.PremiereDate)
                                  : ""
                            textFormat: Text.PlainText
                            color: "#eee"
                            font.pixelSize: 18
                            font.bold: true
                            verticalAlignment: Text.AlignVCenter
                        }

                        Row {
                            id: movieSeriesRangeRow
                            visible: headerInfos.selectedIsSeries
                            anchors.verticalCenter: parent.verticalCenter
                            height: 28
                            spacing: 7

                            Text {
                                text: headerInfos.seriesRangeStart
                                textFormat: Text.PlainText
                                height: 28
                                color: "#eee"
                                font.pixelSize: 18
                                font.bold: true
                                verticalAlignment: Text.AlignVCenter
                            }

                            // Même construction que detailSeriePage :
                            // la flèche ne participe plus aux métriques de la police.
                            Canvas {
                                id: movieSeriesRangeArrow
                                visible: headerInfos.seriesRangeHasArrow
                                width: visible ? 36 : 0
                                height: 28
                                antialiasing: true
                                renderTarget: Canvas.Image
                                readonly property real arrowOpacity: 0.92

                                onPaint: {
                                    var ctx = getContext("2d")
                                    ctx.reset()
                                    ctx.clearRect(0, 0, width, height)

                                    var y = Math.round(height / 2) + 0.5
                                    var c = "rgba(255,255,255," + arrowOpacity + ")"

                                    ctx.strokeStyle = c
                                    ctx.lineWidth = 2
                                    ctx.lineCap = "round"
                                    ctx.lineJoin = "round"

                                    ctx.beginPath()
                                    ctx.moveTo(4, y)
                                    ctx.lineTo(25, y)
                                    ctx.stroke()

                                    ctx.fillStyle = c
                                    ctx.beginPath()
                                    ctx.moveTo(25, y - 6)
                                    ctx.lineTo(33, y)
                                    ctx.lineTo(25, y + 6)
                                    ctx.closePath()
                                    ctx.fill()
                                }

                                Component.onCompleted: requestPaint()
                            }

                            Text {
                                visible: headerInfos.seriesRangeEnd.length > 0
                                text: headerInfos.seriesRangeEnd
                                textFormat: Text.PlainText
                                height: 28
                                color: "#eee"
                                font.pixelSize: 18
                                font.bold: true
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }
                    Row {
                        spacing: 6
                        height: parent.height
                        visible: !moviepage.collectionsMode && (headerInfos.selectedIsSeries ? (headerInfos.seriesEpisodeMin > 0) : (!headerInfos.selectedIsFolder && headerInfos.movieRuntimeSeconds > 0))
                        Text { textFormat: Text.PlainText;
                            text: "\u23F1"
                            color: "#e9ecff"
                            font.pixelSize: 18
                            font.bold: true
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text { textFormat: Text.PlainText;
                            text: headerInfos.selectedIsSeries ? (headerInfos.seriesEpisodeMin + " min/ép.") : headerInfos.movieDurationHms
                            color: "#e9ecff"
                            font.pixelSize: 18
                            font.bold: true
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }
                Item {
                    id: movieTagsClip
                    x: movieFixedMetaRow.visible ? (movieFixedMetaRow.implicitWidth + 18) : 0
                    // Réserve 220 px à droite pour éviter que les tags ne passent sous SortHudButton / ClockHUD.
                    width: Math.max(0, parent.width - x - 220)
                    height: 30
                    anchors.verticalCenter: parent.verticalCenter
                    clip: false
                    visible: headerInfos.tagChips && headerInfos.tagChips.length > 0 && width > 20
                    readonly property real contentW: Math.max(movieTagChipRow.implicitWidth, movieTagChipRow.childrenRect.width)
                    readonly property bool allowMarquee: moviepage.visible
                                                         && moviepage.allowDecos
                                                         && !moviepage.loadingItems
                                                         && !moviepage.isScrolling
                                                         && headerInfos.tagChips
                                                         && headerInfos.tagChips.length > 0
                                                         && visible
                    readonly property bool marqueeNeeded: contentW > (width + 6)
                    readonly property real marqueeOverflow: Math.max(0, contentW - width)
                    readonly property int  marqueeGap: 44
                    readonly property real marqueeTravel: marqueeNeeded ? Math.max(0, contentW + marqueeGap) : 0
                    readonly property real marqueeExitX: marqueeTravel > 0 ? -marqueeTravel : 0
                    readonly property int  marqueeScrollMs: marqueeTravel > 0 ? Math.max(3200, Math.min(14000, Math.round(marqueeTravel * 24))) : 0
                    readonly property int  marqueeFadeW: Math.min(46, Math.max(24, Math.round(width * 0.14)))
                    readonly property bool marqueeArmed: marqueeNeeded && allowMarquee
                    property bool marqueeMoving: false
                    readonly property bool maskActive: marqueeArmed && marqueeMoving
                    readonly property bool leftFadeActive: maskActive && (movieTagChipRow.x < -2)
                    readonly property bool rightFadeActive: maskActive && (movieTagChipRow.x > -marqueeOverflow + 2)
                    onAllowMarqueeChanged: updateMarquee()
                    onWidthChanged: updateMarquee()
                    onVisibleChanged: updateMarquee()
                    onMarqueeNeededChanged: updateMarquee()
                    onContentWChanged: updateMarquee()
                    Connections {
                        target: headerInfos
                        function onTagChipsChanged() { movieTagsClip.updateMarquee() }
                        function onSelectedItemChanged() { movieTagsClip.updateMarquee() }
                    }
                    Item {
                        id: movieTagsSource
                        anchors.fill: parent
                        clip: true
                        visible: !movieTagsClip.maskActive
                        Row {
                            id: movieTagChipRow
                            x: 0
                            y: Math.round((movieTagsSource.height - height) / 2)
                            spacing: 12
                            height: 28
                            onChildrenRectChanged: movieTagsClip.updateMarquee()
                            onImplicitWidthChanged: movieTagsClip.updateMarquee()
                            Repeater {
                                model: headerInfos.tagChips ? headerInfos.tagChips.length : 0
                                Rectangle {
                                    radius: 8
                                    height: 28
                                    color: headerInfos.tagChips[index].c
                                    width: movieTagText.paintedWidth + 16
                                    Text { textFormat: Text.PlainText;
                                        id: movieTagText
                                        anchors.centerIn: parent
                                        text: headerInfos.tagChips[index].t
                                        color: "#fff"
                                        font.pixelSize: headerInfos.tagChips[index].px
                                    }
                                }
                            }
                        }
                    }
                    OpacityMask {
                        id: movieTagsMaskedLine
                        anchors.fill: parent
                        visible: movieTagsClip.maskActive
                        source: movieTagsSource
                        maskSource: movieTagsFadeMask
                        cached: false
                    }
                    Item {
                        id: movieTagsFadeMask
                        visible: movieTagsClip.maskActive
                        x: -10000
                        y: -10000
                        width: movieTagsClip.width
                        height: movieTagsClip.height
                        readonly property int leftW: movieTagsClip.leftFadeActive ? movieTagsClip.marqueeFadeW : 0
                        readonly property int rightW: movieTagsClip.rightFadeActive ? movieTagsClip.marqueeFadeW : 0
                        Rectangle {
                            visible: movieTagsFadeMask.leftW > 0
                            x: 0
                            y: 0
                            width: movieTagsFadeMask.leftW
                            height: parent.height
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: "#00FFFFFF" }
                                GradientStop { position: 1.0; color: "#FFFFFFFF" }
                            }
                        }
                        Rectangle {
                            x: movieTagsFadeMask.leftW
                            y: 0
                            width: Math.max(0, parent.width - movieTagsFadeMask.leftW - movieTagsFadeMask.rightW)
                            height: parent.height
                            color: "#FFFFFFFF"
                        }
                        Rectangle {
                            visible: movieTagsFadeMask.rightW > 0
                            x: parent.width - movieTagsFadeMask.rightW
                            y: 0
                            width: movieTagsFadeMask.rightW
                            height: parent.height
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: "#FFFFFFFF" }
                                GradientStop { position: 1.0; color: "#00FFFFFF" }
                            }
                        }
                    }
                    SequentialAnimation {
                        id: movieTagsMarquee
                        running: false
                        loops: Animation.Infinite
                        ScriptAction { script: { movieTagsClip.marqueeMoving = false; movieTagChipRow.x = 0; movieTagChipRow.opacity = 1.0 } }
                        PauseAnimation { duration: 700 }
                        ScriptAction { script: { movieTagsClip.marqueeMoving = true } }
                        NumberAnimation {
                            target: movieTagChipRow
                            property: "x"
                            from: 0
                            to: movieTagsClip.marqueeExitX
                            duration: movieTagsClip.marqueeScrollMs
                            easing.type: Easing.Linear
                        }
                        ScriptAction { script: { movieTagChipRow.x = 0; movieTagChipRow.opacity = 1.0; movieTagsClip.marqueeMoving = false } }
                        PauseAnimation { duration: 180 }
                        PauseAnimation { duration: 260 }
                        onRunningChanged: {
                            if (!running) {
                                movieTagsClip.marqueeMoving = false
                                movieTagChipRow.x = 0
                                movieTagChipRow.opacity = 1.0
                            }
                        }
                    }
                    function updateMarquee() {
                        movieTagsMarquee.stop()
                        movieTagChipRow.x = 0
                        movieTagChipRow.opacity = 1.0
                        movieTagsClip.marqueeMoving = false
                        if (movieTagsClip.marqueeArmed && movieTagsClip.marqueeScrollMs > 0) {
                            Qt.callLater(function(){
                                if (movieTagsClip.marqueeArmed && movieTagsClip.marqueeNeeded && movieTagsClip.marqueeScrollMs > 0)
                                    movieTagsMarquee.start()
                            })
                        }
                    }
                }
            }
        }
    }
    function _settleGridAfterProgrammaticGlide() {
        if (!moviepage.visible || moviepage.folderBlockingLoading) return
        moviepage.updateScrollProgress()
        moviepage._scheduleStateSave()
        moviepage._scheduleBackdropUpdate(true)
        moviepage._scheduleSelectedAuxiliaryFetch()
        moviepage._scheduleMaybeLoadMoreForViewport()
        // Ne pas réarmer le HQ ici : le ZIP 30082026 démarre son délai au
        // changement de sélection, pas après les 220 ms du glide programmatique.
    }

    /* ========= Grille ========= */
    GridView {
        id: grid
        z: 1
        anchors.top: headerArea.bottom
        anchors.topMargin: gridTopGap
        anchors.left: parent.left
        anchors.leftMargin: marginL
        anchors.right: parent.right
        anchors.rightMargin: marginR
        anchors.bottom: parent.bottom
        cellWidth: gridCellW
        cellHeight: gridCellH
        width: parent.width - (marginL + marginR)
        height: parent.height - (headerArea.y + headerArea.height + gridTopGap)
        model: folderItems
        focus: !folderBlockingLoading && !externalModalOpen
        enabled: !folderBlockingLoading && !externalModalOpen
        keyNavigationWraps: false
        flow: GridView.FlowLeftToRight
        clip: true
        reuseItems: true
        cacheBuffer: Math.round(height * 0.42)
        property int columns: Math.max(1, Math.floor(width / cellWidth))
        property int pendingEnsureIndex: -1
        // Empêche un glide interrompu par une nouvelle touche de déclencher les
        // traitements de fin. En scroll rapide, seule la dernière position stable
        // doit lancer sauvegarde, backdrop, détails, pagination et HQ.
        property bool _suppressNextGlideSettle: false
        Keys.onPressed: {
            if (count <= 0) return
            var idx = currentIndex < 0 ? 0 : currentIndex
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                var it = currentItem
                if (it && it._openDetails) it._openDetails()
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Up && idx - columns < 0 && moviepage.folderPageHasPrevious) {
                moviepage._requestFolderPageBefore(false, true)
                event.accepted = true
                return
            }
            if (!moviepage.hierarchicalMode) {
                if (event.key === Qt.Key_Up && idx - columns < 0) {
                    if (sortButton && sortButton.visible) moviepage.focusSortButton()
                    else moviepage.focusHudAvatar()
                    event.accepted = true
                }
                return
            }
            if (event.key === Qt.Key_Left) {
                var col = idx % columns
                if (col > 0) currentIndex = idx - 1
                else if (idx === 0) {
                    if (sortButton && sortButton.visible) moviepage.focusSortButton()
                    else moviepage.focusHudAvatar()
                } else currentIndex = idx - 1
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Right) {
                var rowStart = idx - (idx % columns)
                var rowEnd = Math.min(rowStart + columns - 1, count - 1)
                if (idx < rowEnd) currentIndex = idx + 1
                else if (rowStart + columns < count) currentIndex = rowStart + columns
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Up) {
                if (idx - columns < 0) {
                    if (sortButton && sortButton.visible) moviepage.focusSortButton()
                    else moviepage.focusHudAvatar()
                } else currentIndex = idx - columns
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Down) {
                var nextIndex = idx + columns
                if (nextIndex < count) currentIndex = nextIndex
                else {
                    var lastIndex = count - 1
                    var lastRowStart = Math.floor(lastIndex / columns) * columns
                    currentIndex = Math.min(lastRowStart + (idx % columns), lastIndex)
                }
                event.accepted = true
                return
            }
        }
        NumberAnimation {
            id: glideY
            target: grid
            property: "contentY"
            duration: 220
            easing.type: Easing.OutCubic
            onStopped: {
                if (grid._suppressNextGlideSettle) {
                    grid._suppressNextGlideSettle = false
                    return
                }
                moviepage._settleGridAfterProgrammaticGlide()
            }
        }
        function glideStop(suppressSettle) {
            if (!glideY.running) return
            if (suppressSettle === true) _suppressNextGlideSettle = true
            glideY.stop()
        }
        function ensureVisible(idx, immediate) {
            if (idx < 0 || idx >= count) return
            if (height <= 0 || contentHeight <= 0 || columns <= 0) { pendingEnsureIndex = idx; return }
            var row = Math.floor(idx / columns)
            var rowTop = row * cellHeight
            var rowBottom = rowTop + cellHeight
            var target = contentY
            if (rowTop < contentY) target = rowTop
            else if (rowBottom > contentY + height) target = rowBottom - height
            target = Math.max(0, Math.min(target, contentHeight - height))
            if (Math.abs(target - contentY) > 1) {
                // Une nouvelle pression remplace le glide précédent : ne pas
                // exécuter un settle intermédiaire pour une position transitoire.
                glideStop(true)
                if (immediate === true) contentY = target
                else { glideY.to = target; glideY.start() }
            }
        }
        function applyPendingEnsure() {
            if (pendingEnsureIndex >= 0) {
                var idx = pendingEnsureIndex
                pendingEnsureIndex = -1
                ensureVisible(idx, true)
            }
        }
        onCountChanged:  Qt.callLater(applyPendingEnsure)
        onWidthChanged:  Qt.callLater(applyPendingEnsure)
        onHeightChanged: Qt.callLater(applyPendingEnsure)
        delegate: Item {
            id: movieLibraryDelegate
            width: grid.cellWidth
            height: grid.cellHeight
            visible: moviepage.indexVisible(index)
            z: selected ? 1000 : 0

            property var itemData: modelData
            property int itemIndex: index
            readonly property bool selected: grid.currentIndex === itemIndex
            readonly property bool browserSeries: moviepage._isBrowserSeries(itemData)
            readonly property bool browserFolder: moviepage._isBrowserFolder(itemData)
            readonly property bool hasPoster: MediaCatalog.hasPrimaryOrThumb(itemData)
            readonly property bool collectionThumbFallback: {
                if (!moviepage.collectionsMode || !itemData) return false
                var tags = itemData.ImageTags || {}
                return !tags.Primary && !!tags.Thumb
            }
            property int unread: moviepage.unreadCountFor(itemData)
            readonly property bool watched: MediaCatalog.isPlayedItem(itemData)
            readonly property real resumeRatio: MediaCatalog.resumeProgressRatioFor(itemData, moviepage.collectionsMode)
            readonly property bool allowLocalFocusAnims: moviepage.visible && !moviepage.externalModalOpen && !moviepage.isScrolling && grid.activeFocus
            readonly property bool posterVisualReady: posterCard ? posterCard.visualReady : true
            readonly property string posterSrc: (visible && moviepage.visible && hasPoster)
                                                ? moviepage.posterUrlFor(itemData,
                                                                         moviepage.reqPosterW,
                                                                         moviepage.reqPosterH,
                                                                         { quality: moviepage.jpgQltPosters })
                                                : ""
            readonly property string posterHqSrc: (selected && grid.activeFocus
                                                    && itemData && itemData.Id
                                                    && moviepage.hqPosterTargetId === String(itemData.Id))
                                                   ? moviepage.posterUrlFor(itemData,
                                                                            moviepage.reqPosterHqW,
                                                                            moviepage.reqPosterHqH,
                                                                            { quality: moviepage.posterHqQuality })
                                                   : ""

            function _openDetails() {
                if (!itemData || !itemData.Id) return
                moviepage._writeSharedStateNow()
                if (moviepage.personalMode && !browserFolder) {
                    moviepage.requestPersonalViewer(movieLibraryDelegate.itemIndex)
                    return
                }
                if (typeof moviepage.requestNavigation !== "function") return
                if (moviepage.collectionsMode) {
                    moviepage.requestNavigation(moviepage._navRoute("detailCollectionPage.qml", {
                        itemId: itemData.Id,
                        boxSetId: itemData.Id,
                        returnFolderId: moviepage.folderId || "",
                        returnIndex: moviepage._globalIndexForLocal(grid.currentIndex),
                        returnY: Math.floor(grid.contentY || 0)
                    }))
                    return
                }
                if (browserFolder) {
                    moviepage._pushBrowserReturnState(itemData.Id)
                    moviepage.requestNavigation(moviepage._navRoute(
                        moviepage.personalMode ? "PersonalMediaPage.qml" : "moviepage.qml", {
                        folderId: itemData.Id,
                        libraryMode: moviepage.normalizedLibraryMode,
                        browserTitle: itemData.Name || ""
                    }))
                    return
                }
                moviepage.requestNavigation(moviepage._navRoute(
                    browserSeries ? "detailSeriePage.qml" : "detailMoviePage.qml", {
                        itemId: itemData.Id,
                        returnFolderId: moviepage.folderId || "",
                        returnIndex: moviepage._globalIndexForLocal(grid.currentIndex),
                        returnY: Math.floor(grid.contentY)
                    }))
            }

            Pages.LibraryPosterCard {
                id: posterCard
                anchors.left: parent.left
                anchors.top: parent.top

                controller: moviepage
                modelData: movieLibraryDelegate.itemData
                tileWidth: moviepage.posterW
                tileHeight: moviepage.posterH
                titleHeight: 0
                sidePad: moviepage.focusPad
                topPad: moviepage.focusPad + moviepage.topPadFor(moviepage.posterH)

                cardIndex: movieLibraryDelegate.itemIndex
                gridColumns: grid.columns
                gridActiveFocus: grid.activeFocus
                selected: movieLibraryDelegate.selected
                allowLoad: movieLibraryDelegate.visible && moviepage.visible
                enableMouseInput: true
                hoverSelectEnabled: true

                useAllowAnimsOverride: true
                allowAnimsOverride: movieLibraryDelegate.allowLocalFocusAnims
                useAllowDecosOverride: true
                allowDecosOverride: moviepage.allowDecos && grid.activeFocus
                zoomScaleOverride: moviepage.focusScale
                focusLiftPxOverride: moviepage.focusLiftPx
                // Politique image du ZIP 30082026 : smooth sur toutes les textures
                // tant qu'il n'y a pas de vrai drag/flick. Le glide D-Pad animé
                // directement sur contentY conserve donc smooth=true.
                smoothImages: !moviepage.isScrolling

                useImageSourceOverride: true
                imageSourceOverride: movieLibraryDelegate.posterSrc
                hqImageSourceOverride: movieLibraryDelegate.posterHqSrc
                imageFillModeOverride: movieLibraryDelegate.collectionThumbFallback
                                       ? Image.PreserveAspectFit
                                       : Image.PreserveAspectCrop
                imageCache: false
                fallbackOnImageError: false
                fallbackKind: (movieLibraryDelegate.browserFolder || moviepage.collectionsMode)
                              ? "folder" : (moviepage.personalMode ? "filmstrip" : "video")
                showVideoIndicator: moviepage.personalMode
                                    && MediaCatalog.itemTypeLower(movieLibraryDelegate.itemData) !== "photo"

                showWatchedBadge: true
                watched: movieLibraryDelegate.watched
                showUnplayedBadge: !moviepage.personalMode && !moviepage.collectionsMode && movieLibraryDelegate.unread > 0
                unplayedCount: movieLibraryDelegate.unread
                showProgress: movieLibraryDelegate.resumeRatio > 0
                progressRatioOverride: movieLibraryDelegate.resumeRatio

                onHovered: grid.currentIndex = movieLibraryDelegate.itemIndex
                onActivated: {
                    grid.currentIndex = movieLibraryDelegate.itemIndex
                    movieLibraryDelegate._openDetails()
                }
            }
        }
        onActiveFocusChanged: moviepage._schedulePosterHq()
        onCurrentIndexChanged: {
            // Politique image 30082026 : armer le HQ dès le changement de focus.
            // Les autres traitements restent coalescés pendant glideY pour ne pas
            // réintroduire la perte de fluidité corrigée depuis.
            if (!moviepage._restoring) ensureVisible(currentIndex)
            moviepage.updateScrollProgress()
            moviepage._schedulePosterHq()
            if (!moviepage.isGridInMotion) {
                moviepage._scheduleStateSave()
                moviepage._scheduleBackdropUpdate(false)
                moviepage._scheduleSelectedAuxiliaryFetch()
                moviepage._scheduleMaybeLoadMoreForViewport()
            }
        }
        onContentYChanged: {
            moviepage.updateScrollProgress()
            // glideY modifie contentY à chaque frame. Relancer les timers de
            // persistance/pagination à chaque frame consomme du CPU sans bénéfice.
            // Le settle du NumberAnimation les déclenche une seule fois à l'arrêt.
            if (!moviepage.isGridInMotion) {
                moviepage._scheduleStateSave()
                moviepage._scheduleMaybeLoadMoreForViewport()
            }
        }
        onMovementStarted: {
            moviepage._cancelPosterHq()
            moviepage.updateScrollProgress()
            moviepage._bgPendingIndex = grid.currentIndex
        }
        onMovementEnded: {
            moviepage._schedulePosterHq()
            moviepage.updateScrollProgress()
            moviepage._scheduleStateSave()
            moviepage._scheduleBackdropUpdate(true)
            moviepage._scheduleSelectedAuxiliaryFetch()
            moviepage._scheduleMaybeLoadMoreForViewport()
        }
        onMovingChanged: {
            if (!moving && !dragging && !flicking) {
                moviepage._schedulePosterHq()
                moviepage._scheduleBackdropUpdate(true)
                moviepage._scheduleSelectedAuxiliaryFetch()
                moviepage._scheduleMaybeLoadMoreForViewport()
            }
        }
    }
    /* ========= Chargement pagination / restauration ========= */
    function _setCircleLoaderRunning(loader, active) {
        try {
            if (loader && loader.hasOwnProperty("running"))
                loader.running = !!active
        } catch(e) {}
    }
    // Loader bloquant : chargement initial + restauration d'un index qui peut
    // nécessiter 2, 3... pages. La grille ne devient visible qu'une fois le
    // focus replacé et les posters visibles stabilisés.
    FocusScope {
        id: folderLoadingOverlay
        anchors.fill: parent
        z: 10000
        visible: folderBlockingLoading && !externalModalOpen
        enabled: visible
        focus: visible
        opacity: visible ? 1.0 : 0.0
        onVisibleChanged: {
            if (!visible) Qt.callLater(moviepage.forceInitialFocus)
        }
        Rectangle { anchors.fill: parent; color: "#000000" }
        // Spinner plein écran délégué à ShellPage.

    }
    // Pagination ordinaire : badge toujours au-dessus des posters.
    Rectangle {
        id: folderMoreLoaderBadge
        z: 9000
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 18
        width: 70
        height: 70
        radius: 35
        color: "#CC090B14"
        border.width: 1
        border.color: "#55FFFFFF"
        visible: folderLoadingMore && !folderRestoreVisualLoading && !externalModalOpen
        opacity: visible ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
        onVisibleChanged: moviepage._setCircleLoaderRunning(folderMoreDots, visible)
        Components.CircleDotsLoader {
            id: folderMoreDots
            width: 48
            height: 48
            anchors.centerIn: parent
            visible: folderMoreLoaderBadge.visible
            Component.onCompleted: moviepage._setCircleLoaderRunning(folderMoreDots, visible)
            onVisibleChanged: moviepage._setCircleLoaderRunning(folderMoreDots, visible)
        }
    }
    Text { textFormat: Text.PlainText;
        anchors.centerIn: parent
        text: MediaCatalog.emptyText(moviepage.normalizedLibraryMode, moviepage.musicVideoMode)
        color: "#fff"
        font.pixelSize: 28
        visible: folderLoadState === "empty"
        z: 8000
    }
    Text { textFormat: Text.PlainText;
        id: folderMoreStatusText
        z: 9000
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 24
        width: Math.min(parent.width - 80, 760)
        text: folderLoadState === "errorMore" ? folderLoadErrorText : ""
        color: "#ffdede"
        font.pixelSize: 18
        visible: text.length > 0
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
    }
    Text { textFormat: Text.PlainText;
        id: folderInitialErrorText
        anchors.centerIn: parent
        width: Math.min(parent.width - 80, 760)
        text: folderLoadErrorText
        color: "#fff"
        font.pixelSize: 24
        visible: folderLoadState === "errorInitial" && folderLoadErrorText.length > 0
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        z: 9000
    }
    /* ========= Retour ========= */
    Component.onDestruction: {
        _cancelFolderPageRequest("destroyed")
        _cancelSelectedDetailRequest()
        _countSeq++
        countFocusFallbackTimer.stop()
        countPumpTimer.stop()
    }
    Keys.onPressed: {
        if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
            if (sortButton && sortButton.popupOpen) {
                sortButton.closeMenu()
                event.accepted = true
                return
            }
            if (moviepage._navigateToBrowserParent()) { event.accepted = true; return }
            if (typeof moviepage.requestBackToMenu === "function") {
                moviepage._writeSharedStateNow()
                moviepage._storeSensitiveNavContext()
                moviepage.requestBackToMenu()
            } else if (typeof moviepage.requestNavigation === "function") {
                moviepage._writeSharedStateNow()
                moviepage._storeSensitiveNavContext()
                moviepage.requestNavigation("HomePage.qml?ctx=1")
            }
            event.accepted = true
        }
    }
}
