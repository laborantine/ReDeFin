// SearchPage.qml — Recherche globale Jellyfin triée par sections
// QtQuick 2.15 — sans QtQuick Controls
// Optimisé Freebox Révolution / Devialet : premier résultat progressif, enrichissement borné,
// quotas dédiés Séries/Épisodes pour les préfixes courts, regroupement local léger,
// glissement horizontal bidirectionnel et focus de saisie stable.

import QtQuick 2.15
import fbx.ui.base 1.0 as FbxBase
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/MediaCatalog.js" as MediaCatalog
import "../js/SafeLog.js" as SafeLog
FocusScope {
    id: searchPage
    width: 1920
    height: 1080
    focus: true

    property string accessToken: ""
    property string userId: ""
    property string serverUrl: ""
    property var fbx: null

    property string queryText: ""
    property var results: []
    property var resultSections: []
    property var folderResultSections: []
    property var sectionSelectionIndices: []
    property int activeSectionIndex: -1
    // Le rail actif visuellement ne doit jamais devenir propriétaire du focus
    // tant que l’utilisateur saisit dans la barre de recherche.
    property bool resultsFocusActive: false
    property int totalRecordCount: 0
    property bool loading: false
    property bool enriching: false
    property bool hasMoreLibraryResults: false
    property bool loadingMoreLibraryResults: false
    property bool currentSearchHasPayload: false
    property bool openingItem: false
    property string errorText: ""
    property int requestSequence: 0
    property int resultLimit: 40
    property int minimumQueryLength: 2
    property int searchBudgetMs: 12000
    readonly property int progressiveApplyIntervalMs: 125
    property var _pendingSearchPayload: null
    property int _pendingSearchPayloadSeq: -1
    property int _searchEngineEpoch: 0
    property var _searchRequestHandles: []
    property var _searchContinuation: null

    // Cache négatif très borné pour les Thumb annoncées par Search/Hints mais
    // absentes côté Jellyfin. Il évite de redemander le même 404 à chaque
    // recyclage de PosterGridCard. Les autres types d'image ne sont pas blacklistés.
    property var _imageVariantFailureUntil: ({})
    property var _imageVariantFailureOrder: []
    readonly property int imageVariantFailureTtlMs: 300000
    readonly property int imageVariantFailureMaxEntries: 64

    readonly property bool hasResults: results && results.length > 0
    readonly property bool hasSections: resultSections && resultSections.length > 0

    // Géométrie strictement alignée sur postergrid.qml.
    readonly property int tileW: 360
    readonly property int tileH: 221
    readonly property int portW: 156
    readonly property int portH: 234
    readonly property int libraryTileW: 340
    readonly property int libraryTileH: 209
    property int titleH: 46
    readonly property int cardTitleFontPx: 20
    readonly property int cardSubtitleFontPx: 15
    readonly property int sectionTitleFontPx: 26
    property int spacingW: 2
    readonly property real frameWidth: 2.0
    readonly property real zoomScale: 1.14
    readonly property int focusLiftPx: 6
    readonly property int focusPadSide: 6
    readonly property int portraitSidePad: 2
    readonly property real posterScale: 1.30
    readonly property int posterQFast: 85
    readonly property real hqPosterScale: 1.50; readonly property int hqPosterQuality: 90; property string hqPosterTargetId: ""
    readonly property string hqPosterCandidateId: _hqPosterCandidateIdNow()
    Timer { id: hqPosterTimer; interval: 320; repeat: false; onTriggered: { var id = searchPage.hqPosterCandidateId; searchPage.hqPosterTargetId = (id && searchPage.resultsFocusActive && searchPage.allowAnims) ? id : "" } }
    onHqPosterCandidateIdChanged: { hqPosterTargetId = ""; hqPosterTimer.stop(); if (hqPosterCandidateId.length) hqPosterTimer.restart() }
    readonly property int bgCapW: 1280
    readonly property int bgCapH: 720
    readonly property int resumeLandscapeH: portH
    readonly property int resumeLandscapeW: Math.round(tileW * resumeLandscapeH / tileH)
    readonly property int edgePadLandscape: Math.ceil((tileW * (zoomScale - 1)) * 0.5) + 6
    readonly property int libraryEdgePad: Math.ceil((libraryTileW * (zoomScale - 1)) * 0.5) + 6
    readonly property int resumeLandscapeEdgePad: Math.ceil((resumeLandscapeW * (zoomScale - 1)) * 0.5) + 6
    readonly property int resumePortraitFocusBleed:
        Math.max(0, Math.ceil((portW * (zoomScale - 1)) * 0.5) + 3 - portraitSidePad)
    readonly property int resumeLandscapeFocusBleed:
        Math.max(0, Math.ceil((resumeLandscapeW * (zoomScale - 1)) * 0.5) + 3 - focusPadSide)
    readonly property int resumeRowEdgePad:
        Math.max(resumePortraitFocusBleed, resumeLandscapeFocusBleed) + 14
    readonly property bool allowAnims: !!(visible && !loading && !openingItem
                                          && !resultsFlick.moving
                                          && !resultsFlick.dragging
                                          && !resultsFlick.flicking)
    readonly property bool allowMarquee: allowAnims
    readonly property url posterGridCardSource: Qt.resolvedUrl("PosterGridCard.qml")

    signal requestTopBar()
    signal requestHome()
    signal requestDetailMovie(string itemId)
    signal requestMoviePage(string folderId)
    signal requestSeriesPage(string folderId)
    signal requestCollectionPage(string folderId)
    signal requestSeasonPage(string seriesId, string seasonId, string preselectEpisodeId)

    function _hqPosterCandidateIdNow() {
        if (!resultsFocusActive || !allowAnims || activeSectionIndex < 0 || activeSectionIndex >= resultSections.length) return ""
        var section = resultSections[activeSectionIndex], arr = section && section.items ? section.items : []
        var idx = _selectionFor(activeSectionIndex, arr.length), it = (idx >= 0 && idx < arr.length) ? arr[idx] : null
        return it && it.Id ? String(it.Id) : ""
    }

    function _s(v) {
        return (v === undefined || v === null) ? "" : String(v)
    }

    function _trim(v) {
        return _s(v).replace(/^\s+|\s+$/g, "")
    }

    function _collectionTypeLower(item) {
        return _s(item && item.CollectionType).toLowerCase()
    }

    function _isFolderType(typeName) {
        return MediaCatalog.searchIsFolderType(typeName)
    }

    function _isMovieLike(item) {
        return MediaCatalog.searchIsMovieLike(item)
    }

    function _sectionKeyFor(item) {
        return MediaCatalog.searchSectionKey(item)
    }

    function _sectionTitle(key) {
        return MediaCatalog.searchSectionTitle(key)
    }

    function _itemUsesLandscape(item, sectionKey) {
        return MediaCatalog.searchItemUsesLandscape(item, sectionKey)
    }

    readonly property var searchCardLayout: ({
        libraryTileWidth: libraryTileW,
        libraryTileHeight: libraryTileH,
        landscapeWidth: resumeLandscapeW,
        portraitWidth: portW,
        portraitHeight: portH,
        focusSidePad: focusPadSide,
        portraitSidePad: portraitSidePad,
        zoomScale: zoomScale,
        frameWidth: frameWidth,
        focusLift: focusLiftPx,
        titleHeight: titleH,
        spacing: spacingW
    })
    function _prepareSectionItems(items, sectionKey) {
        return MediaCatalog.prepareSearchSectionItems(items, sectionKey, searchCardLayout)
    }

    function _cardFallbackKind(item, sectionKey) {
        return MediaCatalog.searchCardFallbackKind(item)
    }

    function _cardPrefersBackdrop(item, sectionKey) {
        return _itemUsesLandscape(item, sectionKey)
    }

    function _buildSections(items, folderSections) {
        var previousSelectionByKey = ({})
        var previousActiveKey = ""
        for (var ps = 0; ps < (resultSections || []).length; ps++) {
            var previous = resultSections[ps] || {}
            if (!previous.key) continue
            previousSelectionByKey[_s(previous.key)] = _selectionFor(ps, previous.items ? previous.items.length : 0)
            if (ps === activeSectionIndex) previousActiveKey = _s(previous.key)
        }

        // Invariant Search : les objets Series et Episode ne doivent jamais
        // partager un même rail. Les recherches scoped par bibliothèque Jellyfin
        // peuvent renvoyer les deux types dans une bibliothèque tvshows ; on les
        // reroute donc ici vers les buckets sémantiques dédiés avant affichage.
        var buckets = { series: [], episodes: [], movies: [], collections: [], others: [] }
        var bucketSeen = { series: ({}), episodes: ({}), movies: ({}), collections: ({}), others: ({}) }
        function addBucket(key, item) {
            if (!item || !item.Id) return false
            if (!buckets[key]) key = "others"
            var id = _s(item.Id)
            if (!id || bucketSeen[key][id]) return false
            bucketSeen[key][id] = true
            buckets[key].push(item)
            return true
        }

        folderSections = folderSections || []

        // Les films et collections peuvent arriver deux fois : une première fois
        // dans le résultat global Jellyfin, puis une seconde fois dans le rail de
        // leur bibliothèque. Dès qu'un rail de bibliothèque contient réellement
        // ce type de média, ce rail devient la source d'affichage autoritaire.
        // Le bucket global reste uniquement un fallback pour les serveurs/vues
        // qui ne permettent pas de rattacher le résultat à une bibliothèque.
        var libraryMovieIds = ({})
        var libraryCollectionIds = ({})
        var hasMovieLibraryRail = false
        var hasCollectionLibraryRail = false
        for (var lf = 0; lf < folderSections.length; lf++) {
            var sourceFolder = folderSections[lf] || {}
            var sourceItems = sourceFolder.items || []
            for (var li = 0; li < sourceItems.length; li++) {
                var sourceItem = sourceItems[li]
                if (!sourceItem || !sourceItem.Id) continue
                var sourceType = MediaCatalog.itemTypeLower(sourceItem)
                if (_isMovieLike(sourceItem)) {
                    libraryMovieIds[_s(sourceItem.Id)] = true
                    hasMovieLibraryRail = true
                } else if (sourceType === "boxset") {
                    libraryCollectionIds[_s(sourceItem.Id)] = true
                    hasCollectionLibraryRail = true
                }
            }
        }

        // Résultats globaux d'abord pour conserver l'ordre de pertinence fourni
        // par Jellyfin. Series/Episode restent globaux et strictement séparés.
        // Films/Collections ne sont utilisés globalement qu'en l'absence totale
        // d'un rail de bibliothèque correspondant, ce qui supprime les rails
        // « Films » et « Collections » en double.
        items = items || []
        for (var i = 0; i < items.length; i++) {
            var item = items[i]
            if (!item || !item.Id) continue
            var itemType = MediaCatalog.itemTypeLower(item)
            if (_isMovieLike(item)) {
                if (hasMovieLibraryRail || libraryMovieIds[_s(item.Id)] === true)
                    continue
            } else if (itemType === "boxset") {
                if (hasCollectionLibraryRail || libraryCollectionIds[_s(item.Id)] === true)
                    continue
            }
            var key = _sectionKeyFor(item)
            if (key === "folders" || key === "library-only") continue
            addBucket(key, item)
        }

        // Les requêtes scoped d'une bibliothèque de séries renvoient souvent
        // Series + Episode dans le même tableau. On les récupère comme complément
        // des résultats globaux, mais chacun part uniquement dans son rail dédié.
        for (var sf = 0; sf < folderSections.length; sf++) {
            var scopedFolder = folderSections[sf] || {}
            var scopedItems = scopedFolder.items || []
            for (var si = 0; si < scopedItems.length; si++) {
                var scopedItem = scopedItems[si]
                var scopedType = MediaCatalog.itemTypeLower(scopedItem)
                if (scopedType === "series") addBucket("series", scopedItem)
                else if (scopedType === "episode") addBucket("episodes", scopedItem)
            }
        }

        var sections = [], indices = []
        var order = ["series", "episodes", "movies", "collections", "others"]
        for (var j = 0; j < order.length; j++) {
            var sectionKey = order[j]
            var sectionItems = buckets[sectionKey]
            if (!sectionItems || sectionItems.length === 0) continue

            // Dernière barrière défensive : même si une future évolution du
            // moteur Search alimente mal un bucket, le rail Séries ne rend que
            // des Series et le rail Épisodes ne rend que des Episode.
            if (sectionKey === "series" || sectionKey === "episodes") {
                var expectedType = sectionKey === "series" ? "series" : "episode"
                var strictItems = []
                for (var sj = 0; sj < sectionItems.length; sj++) {
                    if (MediaCatalog.itemTypeLower(sectionItems[sj]) === expectedType)
                        strictItems.push(sectionItems[sj])
                }
                sectionItems = strictItems
                if (sectionItems.length === 0) continue
            }

            var prepared = _prepareSectionItems(sectionItems, sectionKey)
            sections.push({
                key: sectionKey,
                title: _sectionTitle(sectionKey),
                items: prepared.items,
                cardHeight: prepared.cardHeight,
                edgePad: prepared.edgePad
            })
            indices.push(Math.max(0, Number(previousSelectionByKey[sectionKey] || 0)))
        }

        for (var f = 0; f < folderSections.length; f++) {
            var folder = folderSections[f]
            var rawItems = folder && folder.items ? folder.items : []
            if (!folder || !folder.id || rawItems.length === 0) continue

            // Les Series/Episode ont déjà été reroutés vers leurs rails globaux.
            // Ils sont exclus des rails dynamiques de bibliothèque pour garantir
            // qu'un Episode ne puisse jamais réapparaître sous un titre « Séries ».
            var dynamicItems = []
            var folderCollectionType = _s(folder.collectionType).toLowerCase()
            for (var ri = 0; ri < rawItems.length; ri++) {
                var rawItem = rawItems[ri]
                var rawType = MediaCatalog.itemTypeLower(rawItem)
                if (rawType === "series" || rawType === "episode") continue

                // Un rail Jellyfin typé « movies » ne rend que des films/vidéos,
                // et un rail « boxsets » uniquement des collections. Cela évite
                // qu'un résultat secondaire recrée un rail de catégorie ambigu.
                if (folderCollectionType === "movies" && !_isMovieLike(rawItem))
                    continue
                if (folderCollectionType === "boxsets" && rawType !== "boxset")
                    continue

                dynamicItems.push(rawItem)
            }
            if (dynamicItems.length === 0) continue

            var dynamicKey = "library:" + _s(folder.id)
            var folderPrepared = _prepareSectionItems(dynamicItems, dynamicKey)
            sections.push({
                key: dynamicKey,
                folderId: _s(folder.id),
                collectionType: _s(folder.collectionType),
                title: _s(folder.name) || "Bibliothèque",
                items: folderPrepared.items,
                cardHeight: folderPrepared.cardHeight,
                edgePad: folderPrepared.edgePad
            })
            indices.push(Math.max(0, Number(previousSelectionByKey[dynamicKey] || 0)))
        }

        var keepResultsFocus = resultsFocusActive
        var previousSection = activeSectionIndex
        resultSections = sections
        sectionSelectionIndices = indices
        var restoredSection = -1
        if (previousActiveKey) {
            for (var rs = 0; rs < sections.length; rs++) {
                if (_s(sections[rs] && sections[rs].key) === previousActiveKey) {
                    restoredSection = rs
                    break
                }
            }
        }
        activeSectionIndex = sections.length > 0
                ? (restoredSection >= 0 ? restoredSection
                   : Math.max(0, Math.min(previousSection >= 0 ? previousSection : 0,
                                          sections.length - 1)))
                : -1
        resultsFocusActive = keepResultsFocus && sections.length > 0
        if (resultsFocusActive) {
            Qt.callLater(function() {
                if (searchPage && searchPage.resultsFocusActive && searchPage.hasSections)
                    searchPage.focusSection(searchPage.activeSectionIndex)
            })
        }

    }

    function _selectionFor(sectionIndex, count) {
        var value = (sectionSelectionIndices && sectionSelectionIndices.length > sectionIndex)
                ? Number(sectionSelectionIndices[sectionIndex]) : 0
        if (!isFinite(value) || value < 0) value = 0
        if (count <= 0) return -1
        if (value >= count) value = count - 1
        return Math.floor(value)
    }

    function _storeSelection(sectionIndex, itemIndex) {
        if (sectionIndex < 0) return
        var values = (sectionSelectionIndices && sectionSelectionIndices.slice)
                ? sectionSelectionIndices.slice(0) : []
        values[sectionIndex] = Math.max(0, Number(itemIndex || 0))
        sectionSelectionIndices = values
    }

    function _setSectionSelection(sectionIndex, itemIndex, reason) {
        var sectionItem = _sectionDelegate(sectionIndex)
        if (!sectionItem || !sectionItem.listObj) return false
        var list = sectionItem.listObj
        var wanted = Math.max(0, Math.min(Number(itemIndex || 0), Math.max(0, list.count - 1)))
        _storeSelection(sectionIndex, wanted)
        if (list.ensureCurrentItemVisible)
            list.ensureCurrentItemVisible(reason || "selection")
        return true
    }

    function _sectionDelegate(sectionIndex) {
        try { return sectionRepeater.itemAt(sectionIndex) } catch(e) { return null }
    }

    function _ensureSectionVisible(sectionItem) {
        if (!sectionItem || !resultsFlick) return
        var p = sectionItem.mapToItem(resultsFlick.contentItem, 0, 0)
        var top = p.y
        var bottom = p.y + sectionItem.height
        var margin = 18
        var viewTop = resultsFlick.contentY
        var viewBottom = viewTop + resultsFlick.height
        if (top < viewTop + margin)
            resultsFlick.contentY = Math.max(0, top - margin)
        else if (bottom > viewBottom - margin)
            resultsFlick.contentY = Math.max(0, Math.min(resultsFlick.contentHeight - resultsFlick.height,
                                                         bottom - resultsFlick.height + margin))
    }

    // Défilement horizontal repris de postergrid.qml : aucune téléportation via
    // positionViewAtIndex. La cible tient compte du débordement visuel du zoom,
    // puis contentX rejoint cette cible avec une durée proportionnelle à la distance.
    function _rowItemWidthAt(items, index) {
        return MediaCatalog.searchRowItemWidthAt(items, index)
    }

    function _rowItemLeftAt(items, index) {
        return MediaCatalog.searchRowItemLeftAt(items, index)
    }

    function _rowItemBleedAt(items, index) {
        return MediaCatalog.searchRowItemBleedAt(items, index)
    }

    function _rowLogicalWidth(items, spacing, edgePad, viewportWidth) {
        return MediaCatalog.searchRowLogicalWidth(items, spacing, edgePad, viewportWidth)
    }

    // QtQuick 2.15 peut faire varier originX pendant le recyclage de delegates
    // à largeurs mixtes. Search utilise donc volontairement -edgePad, dérivé
    // de sa géométrie logique stable préparée dans MediaCatalog.
    function _rowMinX(list) {
        return list ? MediaCatalog.searchRowMinX(list.edgePad) : 0
    }

    function _rowMaxX(list) {
        if (!list) return 0
        var minimum = _rowMinX(list)
        return MediaCatalog.rowMaxX(minimum, list.logicalContentWidth, list.width)
    }

    function _rowClampX(list, value) {
        if (!list) return 0
        return MediaCatalog.rowClampX(value, _rowMinX(list), _rowMaxX(list))
    }

    // Même calcul que le moteur validé de postergrid.qml pour les rails à
    // largeurs mixtes. _searchRowLeft est déjà la position logique du delegate
    // dans le modèle : ne pas lui rajouter originX ou edgePad une seconde fois.
    function _rowTargetX(list, index) {
        if (!list) return 0
        return MediaCatalog.searchRowTargetX(list.rowItems || [], index, list.contentX,
                                               list.width, list.edgePad,
                                               list.logicalContentWidth, 10)
    }

    function _rowAnimateX(list, animation, target) {
        target = _rowClampX(list, target)
        var fromX = Number(list.contentX || 0)
        var distance = Math.abs(target - fromX)

        if (animation.running &&
                Math.abs(Number(animation.to || 0) - target) < 0.75)
            return

        animation.stop()

        if (distance < 0.75) {
            list.contentX = target
            return
        }

        if (!allowAnims) {
            list.contentX = target
            return
        }

        animation.from = fromX
        animation.to = target
        animation.duration = Math.max(150, Math.min(235,
                                                     Math.round(135 + distance * 0.10)))
        animation.start()
    }

    function _ensureRowIndexVisible(list, index, animation, sequence, immediate) {
        function apply() {
            if (!searchPage || !list || sequence !== list._ensureVisibleSeq) return
            if (index < 0 || index >= list.count) return
            searchPage._rowAnimateX(list, animation,
                                    searchPage._rowTargetX(list, index))
        }

        // Comme postergrid : les changements de sélection provoqués par la
        // télécommande sont traités immédiatement. Qt.callLater reste réservé
        // aux changements de modèle/géométrie. En scroll rapide, on ne calcule
        // donc jamais la position du poster paysage final à partir d'une
        // animation intermédiaire obsolète.
        if (immediate === true)
            apply()
        else
            Qt.callLater(apply)
    }

    function focusSearchField() {
        resultsFocusActive = false
        Qt.inputMethod.hide()
        searchFieldHit.forceActiveFocus()
    }

    function focusSection(sectionIndex) {
        Qt.inputMethod.hide()
        if (!hasSections) {
            focusSearchField()
            return false
        }
        sectionIndex = Math.max(0, Math.min(sectionIndex, resultSections.length - 1))
        resultsFocusActive = true
        activeSectionIndex = sectionIndex
        if (sectionIndex >= Math.max(0, resultSections.length - 2))
            _requestMoreLibraryResults()
        var sectionItem = _sectionDelegate(sectionIndex)
        if (!sectionItem || !sectionItem.listObj) {
            Qt.callLater(function() {
                if (searchPage && searchPage.resultsFocusActive &&
                        searchPage.activeSectionIndex === sectionIndex)
                    searchPage.focusSection(sectionIndex)
            })
            return false
        }
        var list = sectionItem.listObj
        list.forceActiveFocus()
        if (list.selectedIndex >= 0 && list.ensureCurrentItemVisible)
            list.ensureCurrentItemVisible("section-focus")
        _ensureSectionVisible(sectionItem)
        return true
    }

    function focusResults() {
        if (!hasSections) {
            focusSearchField()
            return
        }
        focusSection(activeSectionIndex >= 0 ? activeSectionIndex : 0)
    }

    // Moteur Search local : l'orchestration appartient à la page, le bridge ne
    // conserve que les primitives HTTP/cache génériques. Un seul jeu de handles
    // existe par SearchPage, ce qui évite l'état global Search dans jellyfinBridge.
    function _searchEnc(v) {
        try { return encodeURIComponent(_s(v)); } catch (e0) { return _s(v); }
    }
    function _searchInt(v) {
        var n = Number(v);
        if (!isFinite(n) || isNaN(n)) return 0;
        return Math.floor(n);
    }
    function _searchIsArray(v) {
        if (typeof Array !== "undefined" && Array.isArray)
            return Array.isArray(v);
        return Object.prototype.toString.call(v) === "[object Array]";
    }
    function _searchTrackHandle(handle) {
        if (!handle || typeof handle.cancel !== "function") return handle
        try {
            if (typeof handle.isActive === "function" && !handle.isActive()) return handle
        } catch(e0) {}
        var list = _searchRequestHandles || []
        list.push(handle)
        _searchRequestHandles = list
        return handle
    }
    function _searchUntrackHandle(handle) {
        var list = _searchRequestHandles || []
        if (!list.length || !handle) return
        var next = []
        for (var i = 0; i < list.length; i++) {
            if (list[i] && list[i] !== handle) next.push(list[i])
        }
        _searchRequestHandles = next
    }
    function _searchCancelHandles(reason) {
        var list = _searchRequestHandles || []
        _searchRequestHandles = []
        for (var i = 0; i < list.length; i++) {
            try {
                if (list[i] && typeof list[i].cancel === "function")
                    list[i].cancel(reason || "cancelled")
            } catch(e0) {}
        }
    }
    function _cancelSearchEngine(reason) {
        _searchEngineEpoch++
        if (_searchEngineEpoch > 2147483000) _searchEngineEpoch = 1
        _searchContinuation = null
        _searchCancelHandles(reason || "cancelled")
    }
    function _hasSearchContinuation() {
        var c = _searchContinuation
        return !!(c && c.requestId === requestSequence &&
                   c.epoch === _searchEngineEpoch && c.running !== true)
    }
    function _continueSearchEngine() {
        var c = _searchContinuation
        if (!c || c.requestId !== requestSequence ||
                c.epoch !== _searchEngineEpoch || c.running === true)
            return false
        c.running = true
        _searchContinuation = null
        try {
            c.run()
            return true
        } catch(e0) {
            return false
        }
    }
    function _searchHintItem(h) {
        h = h || {}
        var id = _s(h.Id || h.ItemId)
        var tag = _s(h.PrimaryImageTag)
        return {
            Id: id,
            Name: _s(h.Name || h.MatchedTerm),
            Type: _s(h.Type),
            MediaType: _s(h.MediaType),
            ImageTags: tag ? { Primary: tag } : {},
            PrimaryImageTag: tag,
            PrimaryImageAspectRatio: Number(h.PrimaryImageAspectRatio || 0),
            ProductionYear: Number(h.ProductionYear || 0),
            RunTimeTicks: Number(h.RunTimeTicks || 0),
            SeriesName: _s(h.Series),
            IndexNumber: h.IndexNumber,
            ParentIndexNumber: h.ParentIndexNumber,
            IsFolder: h.IsFolder === true,
            ThumbImageItemId: _s(h.ThumbImageItemId),
            ThumbImageTag: _s(h.ThumbImageTag),
            BackdropImageItemId: _s(h.BackdropImageItemId),
            BackdropImageTag: _s(h.BackdropImageTag),
            _searchHint: true
        }
    }
    function _searchAcceptedItem(it) {
        var t = MediaCatalog.itemTypeLower(it)
        return !!(it && it.Id) &&
            (t === "movie" || t === "video" || t === "musicvideo" ||
             t === "series" || t === "episode" || t === "boxset" ||
             t === "folder" || t === "collectionfolder" || t === "userview" ||
             t === "aggregatefolder" || t === "userrootfolder")
    }

    function _searchPhysicalItem(it) {
        return MediaCatalog.itemTypeLower(it) !== "episode" ||
               _s(it && it.LocationType).toLowerCase() !== "virtual"
    }

    function _searchIdsOf(items) {
        var out = [], seen = ({})
        for (var i = 0; i < (items || []).length; i++) {
            var id = _s(items[i] && items[i].Id)
            if (id && !seen[id] && _searchAcceptedItem(items[i]) && _searchPhysicalItem(items[i])) {
                seen[id] = 1
                out.push(id)
            }
        }
        return out
    }

    function _searchItemMap(items) {
        var out = ({})
        for (var i = 0; i < (items || []).length; i++) {
            var it = items[i]
            var id = _s(it && it.Id)
            if (id && _searchAcceptedItem(it) && _searchPhysicalItem(it) && !out[id])
                out[id] = it
        }
        return out
    }

    function _startSearchEngine(seq, searchTerm, startIndex, limit, onSuccess, onError) {
        var epoch = _searchEngineEpoch
        var term = _trim(searchTerm)
        var srv = _s(serverUrl)
        var uid = _s(userId)
        var token = _s(accessToken)
        // Le quota global Jellyfin ne doit pas laisser les épisodes évincer les
        // séries lorsqu'un préfixe court (2-3 caractères) produit beaucoup de
        // correspondances. Les deux types disposent donc de petits pools dédiés.
        var generalTypes = "Movie,Video,MusicVideo,BoxSet,Folder,CollectionFolder,UserView,AggregateFolder,UserRootFolder"
        var allTypes = generalTypes + ",Series,Episode"
        var deadlineAt = Date.now() + searchBudgetMs
        var partialSent = false
        var lastPartialItems = []
        var lastTotal = 0
        var dedicatedSeedItems = []
        // Coalescence limitée à cette recherche : deux chemins progressifs qui
        // demandent exactement la même URL partagent un seul transport.
        var jsonInflight = ({})
        startIndex = Math.max(0, _searchInt(startIndex))
        limit = Math.max(1, Math.min(60, _searchInt(limit) || 40))
        var seriesSeedLimit = Math.max(12, Math.min(20, Math.floor(limit * 0.50)))
        var episodeSeedLimit = Math.max(12, Math.min(20, Math.floor(limit * 0.50)))
        // On accepte au plus 20 cartes globales supplémentaires afin de garder
        // des films/collections visibles sans sacrifier les quotas Series/Episode.
        var mergedResultLimit = Math.min(80, Math.max(limit, limit + 20))

        function current() {
            return seq === requestSequence && epoch === _searchEngineEpoch
        }
        function budgetExpired() {
            return Date.now() >= deadlineAt
        }
        function budgetError() {
            return { code: "budget_exhausted", message: "budget_exhausted", status: 0 }
        }
        function emitSuccess(payload) {
            if (!current()) return
            if (onSuccess) onSuccess(payload)
            if (!payload || payload.complete !== false)
                _searchCancelHandles("completed")
        }
        function emitError(payload) {
            if (!current()) return
            if (onError) onError(payload)
            _searchCancelHandles("completed")
        }
        if (!srv || !token || !uid) {
            emitError({ code: "missing_params", message: "missing_params", status: 0 })
            return
        }
        if (term.length < minimumQueryLength) {
            emitSuccess({ items: [], folderSections: [], totalRecordCount: 0,
                          startIndex: 0, complete: true })
            return
        }

        var fields = Jellyfin.homeMediaFields(
            "BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags," +
            "ParentThumbItemId,ParentThumbImageTag,ThumbImageTag,SeriesPrimaryImageTag," +
            "LocationType,Path,Type,CollectionType"
        )
        function fetchJson(url, ok, ko) {
            if (!current()) return false
            if (budgetExpired()) {
                Qt.callLater(function() {
                    if (current() && ko) ko(budgetError())
                })
                return false
            }

            var requestKey = _s(url)
            var pending = jsonInflight[requestKey]
            if (pending && pending.done !== true) {
                pending.waiters.push({ ok: ok, ko: ko })
                return true
            }

            var entry = {
                done: false,
                waiters: [{ ok: ok, ko: ko }],
                handle: null
            }
            jsonInflight[requestKey] = entry

            function finishAll(success, payload, response) {
                if (entry.done === true) return
                entry.done = true
                if (jsonInflight[requestKey] === entry)
                    delete jsonInflight[requestKey]

                var waiters = entry.waiters || []
                entry.waiters = []
                if (!current()) return

                for (var wi = 0; wi < waiters.length; wi++) {
                    var waiter = waiters[wi]
                    if (!waiter) continue
                    try {
                        if (success) {
                            if (waiter.ok) waiter.ok(payload, response)
                        } else if (waiter.ko) {
                            waiter.ko(payload)
                        }
                    } catch(eWaiter) {}
                }
            }

            var handle = null
            handle = Jellyfin.fetchSearchJsonUrl(
                url, token, deadlineAt,
                function(j, res) {
                    _searchUntrackHandle(handle)
                    finishAll(true, j, res)
                },
                function(err) {
                    _searchUntrackHandle(handle)
                    finishAll(false, err, null)
                }
            )
            entry.handle = handle
            _searchTrackHandle(handle)
            return true
        }
        function loadViews(done) {
            if (!current() || budgetExpired()) {
                done([])
                return
            }
            var viewsHandle = null
            viewsHandle = Jellyfin.fetchViews(srv, token, uid,
                function(items) {
                    _searchUntrackHandle(viewsHandle)
                    if (!current()) return
                    var out = [], seenViews = ({})
                    for (var i = 0; i < (items || []).length; i++) {
                        var view = items[i] || {}
                        var viewId = _s(view.Id)
                        var ct = _s(view.CollectionType).toLowerCase()
                        if (viewId && ct !== "livetv" && !seenViews[viewId]) {
                            seenViews[viewId] = true
                            out.push({
                                Id: viewId,
                                Name: _s(view.Name) || "Bibliothèque",
                                CollectionType: _s(view.CollectionType)
                            })
                        }
                    }
                    done(out)
                },
                function() {
                    _searchUntrackHandle(viewsHandle)
                    if (current()) done([])
                }
            )
            _searchTrackHandle(viewsHandle)
        }
        function hydrateIds(ids, done) {
            var unique = [], seen = {}
            for (var i = 0; i < (ids || []).length; i++) {
                var id = _s(ids[i])
                if (id && !seen[id]) {
                    seen[id] = 1
                    unique.push(id)
                }
            }
            if (!unique.length || budgetExpired()) {
                done({}, budgetExpired())
                return
            }
            var chunkSize = 55
            var total = Math.ceil(unique.length / chunkSize)
            var next = 0, active = 0, finished = 0, maxParallel = 2
            var map = {}, finalized = false
            function merge(raw) {
                for (var x = 0; x < (raw || []).length; x++) {
                    var it = raw[x]
                    var id = _s(it && it.Id)
                    if (id && _searchAcceptedItem(it) && _searchPhysicalItem(it)) map[id] = it
                }
            }
            function complete(forceBudget) {
                if (finalized || !current()) return
                if (!forceBudget && (finished < total || active > 0)) return
                finalized = true
                done(map, forceBudget === true || budgetExpired())
            }
            function launch() {
                if (!current()) return
                if (budgetExpired()) {
                    complete(true)
                    return
                }
                while (active < maxParallel && next < total && !budgetExpired()) {
                    (function(index) {
                        var part = unique.slice(index * chunkSize,
                                                Math.min(unique.length, (index + 1) * chunkSize))
                        active++
                        var url = Jellyfin.searchItemsUrl(
                            srv, uid,
                            "Ids=" + _searchEnc(part.join(",")) +
                            "&Recursive=true&ExcludeLocationTypes=Virtual" +
                            "&EnableTotalRecordCount=false&Fields=" + _searchEnc(fields)
                        )
                        fetchJson(url,
                            function(j) {
                                if (finalized) return
                                merge(j && j.Items ? j.Items : (_searchIsArray(j) ? j : []))
                                active--
                                finished++
                                launch()
                                complete(false)
                            },
                            function() {
                                if (finalized) return
                                active--
                                finished++
                                launch()
                                complete(budgetExpired())
                            }
                        )
                    })(next++)
                }
                complete(budgetExpired())
            }
            launch()
        }
        function hydrateByViews(seed, done) {
            var seedIds = _searchIdsOf(seed)
            var seedMap = _searchItemMap(seed)
            var maxCandidates = Math.max(mergedResultLimit, Math.min(320, limit * 8))
            var perViewLimit = Math.max(40, limit)
            var seriesViewLimit = Math.max(12, Math.min(20, seriesSeedLimit))
            var episodeViewLimit = Math.max(16, Math.min(28, Math.max(episodeSeedLimit, 16)))
            var viewBatchSize = 6
            var globalOrder = seedIds.slice(0, maxCandidates)
            var globalSeen = {}, hydratedMap = {}
            for (var si = 0; si < globalOrder.length; si++) globalSeen[globalOrder[si]] = 1

            function sourceFor(id) {
                return hydratedMap[id] || seedMap[id] || null
            }
            loadViews(function(views) {
                if (!current()) return
                if (!views.length || budgetExpired()) {
                    hydrateIds(seedIds.slice(0, maxCandidates), function(map, budgetHit) {
                        if (!current()) return
                        var only = []
                        for (var oi = 0; oi < seedIds.length && only.length < mergedResultLimit; oi++) {
                            var src = map[seedIds[oi]] || seedMap[seedIds[oi]]
                            if (src) only.push(src)
                        }
                        done(only, [], budgetHit, false)
                    })
                    return
                }

                var sectionIds = new Array(views.length)
                var nextView = 0
                var stageRunning = false
                var stageHydrationPending = false

                function scopeUrl(view, typed, includeTypes, scopedLimit) {
                    var wantedLimit = Math.max(1, Number(scopedLimit || perViewLimit))
                    var q = "SearchTerm=" + _searchEnc(term) +
                            "&StartIndex=0&Limit=" + wantedLimit +
                            "&UserId=" + _searchEnc(uid) +
                            "&ParentId=" + _searchEnc(view.Id) +
                            "&IncludePeople=false&IncludeMedia=true&IncludeGenres=false" +
                            "&IncludeStudios=false&IncludeArtists=false"
                    if (typed) q += "&IncludeItemTypes=" + _searchEnc(includeTypes || allTypes)
                    return Jellyfin.searchHintsUrl(srv, q)
                }
                function parseScope(j, expectedType, scopedLimit) {
                    var hints = j && j.SearchHints ? j.SearchHints : []
                    var ids = []
                    var wanted = _s(expectedType).toLowerCase()
                    var cap = Math.max(1, Number(scopedLimit || perViewLimit))
                    for (var i = 0; i < hints.length && ids.length < cap; i++) {
                        var item = _searchHintItem(hints[i])
                        var id = _s(item && item.Id)
                        if (!id || !_searchAcceptedItem(item) || !_searchPhysicalItem(item)) continue
                        if (wanted && MediaCatalog.itemTypeLower(item) !== wanted) continue
                        if (!seedMap[id]) seedMap[id] = item
                        if (ids.indexOf(id) < 0) ids.push(id)
                    }
                    return ids
                }
                function mergeIds(first, second) {
                    var out = [], seen = ({})
                    var lists = [first || [], second || []]
                    for (var l = 0; l < lists.length; l++) {
                        for (var i = 0; i < lists[l].length; i++) {
                            var id = _s(lists[l][i])
                            if (id && !seen[id]) { seen[id] = true; out.push(id) }
                        }
                    }
                    return out
                }
                function fetchViewScope(view, done) {
                    var ct = _s(view && view.CollectionType).toLowerCase()
                    if (ct !== "tvshows") {
                        fetchJson(scopeUrl(view, true, allTypes, perViewLimit),
                            function(j) { done(parseScope(j, "", perViewLimit)) },
                            function() {
                                if (budgetExpired()) { done([]); return }
                                fetchJson(scopeUrl(view, false, "", perViewLimit),
                                    function(j2) { done(parseScope(j2, "", perViewLimit)) },
                                    function() { done([]) })
                            })
                        return
                    }

                    // Une bibliothèque tvshows est interrogée séparément : la
                    // requête Series passe en premier, puis Episode. Ainsi une
                    // avalanche d'épisodes ne peut plus remplir le quota Series.
                    fetchJson(scopeUrl(view, true, "Series", seriesViewLimit),
                        function(seriesJson) {
                            var seriesIds = parseScope(seriesJson, "series", seriesViewLimit)
                            if (budgetExpired()) { done(seriesIds); return }
                            fetchJson(scopeUrl(view, true, "Episode", episodeViewLimit),
                                function(episodeJson) {
                                    done(mergeIds(seriesIds, parseScope(episodeJson, "episode", episodeViewLimit)))
                                },
                                function() { done(seriesIds) })
                        },
                        function() {
                            if (budgetExpired()) { done([]); return }
                            fetchJson(scopeUrl(view, true, "Episode", episodeViewLimit),
                                function(episodeJsonOnly) {
                                    done(parseScope(episodeJsonOnly, "episode", episodeViewLimit))
                                },
                                function() { done([]) })
                        })
                }
                function addCandidates(ids) {
                    for (var i = 0; i < (ids || []).length &&
                            globalOrder.length < maxCandidates; i++) {
                        var id = _s(ids[i])
                        if (id && !globalSeen[id]) {
                            globalSeen[id] = 1
                            globalOrder.push(id)
                        }
                    }
                }
                function buildStagePayload(processedCount, budgetHit) {
                    var merged = [], folders = []
                    var seriesItems = [], episodeItems = [], otherItems = []
                    for (var x = 0; x < globalOrder.length; x++) {
                        var globalItem = sourceFor(globalOrder[x])
                        if (!globalItem) continue
                        var gt = MediaCatalog.itemTypeLower(globalItem)
                        if (gt === "series") seriesItems.push(globalItem)
                        else if (gt === "episode") episodeItems.push(globalItem)
                        else otherItems.push(globalItem)
                    }
                    function appendLimited(source, cap) {
                        for (var ai = 0; ai < source.length && ai < cap &&
                                merged.length < mergedResultLimit; ai++)
                            merged.push(source[ai])
                    }
                    appendLimited(seriesItems, seriesSeedLimit)
                    appendLimited(episodeItems, episodeSeedLimit)
                    appendLimited(otherItems, mergedResultLimit)
                    // Si les quotas dédiés n'ont pas été remplis, compléter avec
                    // le reste dans l'ordre Jellyfin sans dépasser la borne RAM.
                    if (merged.length < mergedResultLimit) {
                        var mergedSeen = ({})
                        for (var mi = 0; mi < merged.length; mi++)
                            if (merged[mi] && merged[mi].Id) mergedSeen[_s(merged[mi].Id)] = true
                        for (var gx = 0; gx < globalOrder.length && merged.length < mergedResultLimit; gx++) {
                            var fallbackItem = sourceFor(globalOrder[gx])
                            var fallbackId = _s(fallbackItem && fallbackItem.Id)
                            if (fallbackItem && fallbackId && !mergedSeen[fallbackId]) {
                                mergedSeen[fallbackId] = true
                                merged.push(fallbackItem)
                            }
                        }
                    }
                    for (var z = 0; z < processedCount; z++) {
                        var ids = sectionIds[z] || []
                        var arr = [], used = {}
                        for (var y = 0; y < ids.length && arr.length < perViewLimit; y++) {
                            var src = sourceFor(ids[y])
                            var id = _s(src && src.Id)
                            if (!src || !id || used[id]) continue
                            used[id] = 1
                            var copy = {}
                            for (var k in src) {
                                if (Object.prototype.hasOwnProperty.call(src, k))
                                    copy[k] = src[k]
                            }
                            copy._searchLibraryId = views[z].Id
                            copy._searchLibraryName = views[z].Name
                            copy._searchLibraryCollectionType = views[z].CollectionType
                            arr.push(copy)
                        }
                        if (arr.length) {
                            folders.push({
                                id: views[z].Id,
                                name: views[z].Name,
                                collectionType: views[z].CollectionType,
                                items: arr
                            })
                        }
                    }
                    var hasMore = processedCount < views.length
                    if (hasMore && current()) {
                        _searchContinuation = {
                            requestId: seq,
                            epoch: epoch,
                            running: false,
                            run: function() {
                                if (!current()) return
                                deadlineAt = Date.now() + searchBudgetMs
                                runStage()
                            }
                        }
                    } else if (_searchContinuation &&
                               _searchContinuation.requestId === seq &&
                               _searchContinuation.epoch === epoch) {
                        _searchContinuation = null
                    }
                    done(merged, folders, budgetHit, hasMore)
                }
                function hydrateNewCandidates(processedCount) {
                    var missing = []
                    for (var i = 0; i < globalOrder.length; i++) {
                        var id = globalOrder[i]
                        if (!hydratedMap[id]) missing.push(id)
                    }
                    hydrateIds(missing, function(map, budgetHit) {
                        if (!current()) return
                        for (var id in map) {
                            if (Object.prototype.hasOwnProperty.call(map, id))
                                hydratedMap[id] = map[id]
                        }
                        stageHydrationPending = false
                        stageRunning = false
                        buildStagePayload(processedCount, budgetHit)
                    })
                }
                function runStage() {
                    if (!current() || stageRunning) return
                    stageRunning = true
                    var stageStart = nextView
                    var stageEnd = Math.min(views.length, stageStart + viewBatchSize)
                    var cursor = stageStart, active = 0, finished = 0, maxParallel = 2
                    if (stageStart >= stageEnd) {
                        stageRunning = false
                        buildStagePayload(nextView, false)
                        return
                    }
                    function finishScope(index, ids) {
                        if (!current()) return
                        sectionIds[index] = ids || []
                        addCandidates(sectionIds[index])
                        active--
                        finished++
                        launch()
                        complete()
                    }
                    function complete() {
                        if (!current() || finished < (stageEnd - stageStart) || active > 0)
                            return
                        // finishScope() appelle launch(), et launch() appelle lui-même
                        // complete(). Sans ce verrou, le dernier scope pouvait donc
                        // lancer deux hydrateIds() identiques à quelques ms d'écart.
                        if (stageHydrationPending) return
                        stageHydrationPending = true
                        nextView = stageEnd
                        hydrateNewCandidates(nextView)
                    }
                    function launch() {
                        if (!current()) return
                        while (active < maxParallel && cursor < stageEnd && !budgetExpired()) {
                            (function(index, view) {
                                cursor++
                                active++
                                fetchViewScope(view, function(ids) {
                                    finishScope(index, ids || [])
                                })
                            })(cursor, views[cursor])
                        }
                        if (budgetExpired()) {
                            while (cursor < stageEnd) {
                                sectionIds[cursor++] = []
                                finished++
                            }
                        }
                        complete()
                    }
                    launch()
                }
                runStage()
            })
        }

        function _dedicatedSeedUrl(typeName, quota, useItems) {
            var encodedType = _searchEnc(typeName)
            var common = "SearchTerm=" + _searchEnc(term) +
                         "&StartIndex=0&Limit=" + Math.max(1, quota) +
                         "&IncludeItemTypes=" + encodedType
            if (!useItems) {
                common += "&UserId=" + _searchEnc(uid) +
                          "&IncludePeople=false&IncludeMedia=true" +
                          "&IncludeGenres=false&IncludeStudios=false&IncludeArtists=false"
                return Jellyfin.searchHintsUrl(srv, common)
            }
            common = "Recursive=true&" + common +
                     "&ExcludeLocationTypes=Virtual&EnableUserData=false" +
                     "&EnableTotalRecordCount=false&Fields=" + _searchEnc(fields)
            return Jellyfin.searchItemsUrl(srv, uid, common)
        }
        function _parseDedicatedSeed(j, typeName, quota, fromItems) {
            var raw = []
            if (fromItems) raw = j && j.Items ? j.Items : (_searchIsArray(j) ? j : [])
            else {
                var hints = j && j.SearchHints ? j.SearchHints : []
                for (var h = 0; h < hints.length; h++) raw.push(_searchHintItem(hints[h]))
            }
            var out = [], seen = ({}), wanted = _s(typeName).toLowerCase()
            for (var i = 0; i < raw.length && out.length < quota; i++) {
                var item = raw[i]
                var id = _s(item && item.Id)
                if (!id || seen[id] || MediaCatalog.itemTypeLower(item) !== wanted || !_searchPhysicalItem(item)) continue
                seen[id] = true
                out.push(item)
            }
            return out
        }
        function fetchDedicatedSeed(typeName, quota, done) {
            if (!current() || budgetExpired()) { done([]); return }
            fetchJson(_dedicatedSeedUrl(typeName, quota, false),
                function(j) {
                    var items = _parseDedicatedSeed(j, typeName, quota, false)
                    // Sur préfixe court, un serveur peut rendre Search/Hints vide
                    // malgré des Items correspondants : un seul fallback typé est
                    // alors autorisé, sans multiplier les requêtes normales.
                    if (items.length || term.length > 4 || budgetExpired()) {
                        done(items)
                        return
                    }
                    fetchJson(_dedicatedSeedUrl(typeName, quota, true),
                        function(j2) { done(_parseDedicatedSeed(j2, typeName, quota, true)) },
                        function() { done(items) })
                },
                function() {
                    if (budgetExpired()) { done([]); return }
                    fetchJson(_dedicatedSeedUrl(typeName, quota, true),
                        function(j3) { done(_parseDedicatedSeed(j3, typeName, quota, true)) },
                        function() { done([]) })
                })
        }
        function runDedicatedSeeds(done) {
            var pending = 2, collected = [], seen = ({})
            function accept(items) {
                for (var i = 0; i < (items || []).length; i++) {
                    var item = items[i], id = _s(item && item.Id)
                    if (id && !seen[id]) { seen[id] = true; collected.push(item) }
                }
                pending--
                if (pending > 0) return
                dedicatedSeedItems = collected
                if (collected.length && current()) {
                    lastPartialItems = collected.slice(0, mergedResultLimit)
                    lastTotal = Math.max(lastTotal, lastPartialItems.length)
                    partialSent = true
                    emitSuccess({
                        items: lastPartialItems,
                        folderSections: [],
                        totalRecordCount: lastTotal,
                        startIndex: startIndex,
                        complete: false
                    })
                }
                done()
            }
            fetchDedicatedSeed("Series", seriesSeedLimit, accept)
            fetchDedicatedSeed("Episode", episodeSeedLimit, accept)
        }

        var mode = 0
        var currentLimit = limit
        function routeName() {
            return mode === 0 ? "search-hints-typed" :
                   mode === 1 ? "search-hints-untyped" :
                   mode === 2 ? "items-typed" : "items-untyped"
        }
        function makeUrl() {
            var common = "SearchTerm=" + _searchEnc(term) +
                         "&StartIndex=" + startIndex +
                         "&Limit=" + (mode === 1 ? Math.min(80, currentLimit * 2) : currentLimit)
            if (mode < 2) {
                common += "&UserId=" + _searchEnc(uid) +
                          "&IncludePeople=false&IncludeMedia=true" +
                          "&IncludeGenres=false&IncludeStudios=false&IncludeArtists=false" +
                          (mode === 0 ? "&IncludeItemTypes=" + generalTypes : "")
                return Jellyfin.searchHintsUrl(srv, common)
            }
            common = "Recursive=true&" + common +
                     "&ExcludeLocationTypes=Virtual&EnableUserData=false" +
                     "&EnableTotalRecordCount=true&Fields=" + _searchEnc(fields) +
                     (mode === 2 ? "&IncludeItemTypes=" + generalTypes : "")
            return Jellyfin.searchItemsUrl(srv, uid, common)
        }
        function finishFromPartial(route, status, budgetHit) {
            emitSuccess({
                items: lastPartialItems,
                folderSections: [],
                totalRecordCount: lastTotal || lastPartialItems.length,
                startIndex: startIndex,
                complete: true,
                budgetExhausted: budgetHit === true
            })
        }
        function fail(err) {
            if (!current()) return
            var code = SafeLog.safeErrorCode(err, "network_error")
            if (budgetExpired() || code === "budget_exhausted") {
                if (partialSent) finishFromPartial(routeName(), 0, true)
                else emitError({
                    code: "timeout",
                    message: "search_budget_exhausted",
                    status: 0,
                    requestId: seq,
                    route: routeName()
                })
                return
            }
            if (code === "too_large" && currentLimit > 10) {
                currentLimit = currentLimit > 20 ? 20 : 10
                attempt()
                return
            }
            if (mode < 3) {
                mode++
                attempt()
                return
            }
            emitError({
                code: code,
                message: _s(err && err.message) || code,
                status: (err && err.status) || 0,
                requestId: seq,
                route: routeName()
            })
        }
        function attempt() {
            if (!current()) return
            if (budgetExpired()) {
                fail(budgetError())
                return
            }
            fetchJson(makeUrl(), function(j, res) {
                var raw = [], total = 0
                if (mode < 2) {
                    var hints = j && j.SearchHints ? j.SearchHints : []
                    for (var i = 0; i < hints.length; i++)
                        raw.push(_searchHintItem(hints[i]))
                    total = j && j.TotalRecordCount !== undefined
                          ? Number(j.TotalRecordCount) : raw.length
                } else {
                    raw = j && j.Items ? j.Items : (_searchIsArray(j) ? j : [])
                    total = j && j.TotalRecordCount !== undefined
                          ? Number(j.TotalRecordCount) : raw.length
                }
                // Les pools Series/Episode dédiés passent en tête pour garantir
                // leur présence, puis le moteur général complète films/collections.
                var combinedRaw = [], combinedSeen = ({})
                var sourceLists = [dedicatedSeedItems || [], raw || []]
                for (var sl = 0; sl < sourceLists.length; sl++) {
                    for (var sr = 0; sr < sourceLists[sl].length; sr++) {
                        var sourceItem = sourceLists[sl][sr]
                        var sourceId = _s(sourceItem && sourceItem.Id)
                        if (sourceId && !combinedSeen[sourceId]) {
                            combinedSeen[sourceId] = true
                            combinedRaw.push(sourceItem)
                        }
                    }
                }
                raw = combinedRaw
                var seedIds = _searchIdsOf(raw)
                var seedMap = _searchItemMap(raw)
                var partial = []
                for (var p = 0; p < seedIds.length && partial.length < mergedResultLimit; p++) {
                    if (seedMap[seedIds[p]]) partial.push(seedMap[seedIds[p]])
                }
                lastPartialItems = partial
                lastTotal = isFinite(total) && total >= 0 ? Math.floor(total) : partial.length
                if (partial.length) {
                    partialSent = true
                    emitSuccess({
                        items: partial,
                        folderSections: [],
                        totalRecordCount: lastTotal,
                        startIndex: startIndex,
                        complete: false
                    })
                }
                hydrateByViews(raw, function(items, folderSections, budgetHit, hasMoreLibraries) {
                    if (!current()) return
                    emitSuccess({
                        items: items,
                        folderSections: folderSections,
                        totalRecordCount: Math.max(lastTotal, items.length),
                        startIndex: startIndex,
                        complete: true,
                        budgetExhausted: budgetHit === true,
                        hasMoreLibraries: hasMoreLibraries === true
                    })
                })
            }, fail)
        }
        runDedicatedSeeds(function() {
            if (current()) attempt()
        })
    }

    function clearSearch() {

        requestSequence++
        _cancelSearchEngine("cancelled")
        searchDelay.stop()
        searchBudget.stop()
        _discardPendingSearchPayload()
        loading = false
        enriching = false
        hasMoreLibraryResults = false
        loadingMoreLibraryResults = false
        currentSearchHasPayload = false
        openingItem = false
        errorText = ""
        results = []
        resultSections = []
        folderResultSections = []
        sectionSelectionIndices = []
        activeSectionIndex = -1
        resultsFocusActive = false
        totalRecordCount = 0
        resultsFlick.contentY = 0
    }

    function scheduleSearch() {
        errorText = ""
        var q = _trim(queryText)
        if (q.length < minimumQueryLength) {
            clearSearch()
            return
        }
        if (loading || enriching || hasMoreLibraryResults) {
            requestSequence++
            _cancelSearchEngine("cancelled")
            searchBudget.stop()
            _discardPendingSearchPayload()
            loading = false
            enriching = false
            hasMoreLibraryResults = false
            loadingMoreLibraryResults = false
        }

        searchDelay.restart()
    }

    function _discardPendingSearchPayload() {
        progressiveApplyTimer.stop()
        _pendingSearchPayload = null
        _pendingSearchPayloadSeq = -1
    }

    function _applySearchPayload(payload, seq) {
        if (seq !== requestSequence) return false
        var hadCurrentPayload = currentSearchHasPayload
        var complete = !(payload && payload.complete === false)
        currentSearchHasPayload = true
        loading = false
        enriching = !complete
        loadingMoreLibraryResults = false
        if (payload && payload.hasMoreLibraries !== undefined)
            hasMoreLibraryResults = payload.hasMoreLibraries === true
        if (complete) searchBudget.stop()
        var list = payload && payload.items ? payload.items : []
        var folders = payload && payload.folderSections ? payload.folderSections : []
        if (complete && (!list || list.length === 0) && results && results.length > 0) {
            list = results
            folders = folderResultSections
        }
        var hadSections = hadCurrentPayload && hasSections
        var oldContentY = resultsFlick.contentY
        if (!hadCurrentPayload) {
            resultSections = []
            sectionSelectionIndices = []
            activeSectionIndex = -1
            resultsFocusActive = false
        }
        results = list || []
        folderResultSections = folders || []
        totalRecordCount = payload && payload.totalRecordCount !== undefined
                ? Number(payload.totalRecordCount) : results.length
        // Le propriétaire du focus est mémorisé avant la reconstruction des
        // delegates : le modèle ne peut pas voler le focus au champ de saisie.
        if (searchInput.activeFocus || searchFieldHit.activeFocus || clearHit.activeFocus)
            resultsFocusActive = false
        _buildSections(results, folderResultSections)
        if (!hadSections) {
            resultsFlick.contentY = 0
        } else {
            Qt.callLater(function() {
                if (!searchPage || seq !== searchPage.requestSequence) return
                var maxY = Math.max(0, resultsFlick.contentHeight - resultsFlick.height)
                resultsFlick.contentY = Math.max(0, Math.min(maxY, oldContentY))
            })
        }

        return true
    }

    function _requestMoreLibraryResults() {
        if (!hasMoreLibraryResults || loading || loadingMoreLibraryResults || openingItem) return false
        var hasContinuation = false
        try { hasContinuation = _hasSearchContinuation() }
        catch(e0) { hasContinuation = false }
        if (!hasContinuation) { hasMoreLibraryResults = false; return false }
        loadingMoreLibraryResults = true
        enriching = true
        searchBudget.restart()
        var started = false
        try { started = _continueSearchEngine() }
        catch(e1) { started = false }
        if (!started) {
            loadingMoreLibraryResults = false
            enriching = false
            searchBudget.stop()
            hasMoreLibraryResults = false
        }
        return started
    }

    function _maybeRequestMoreLibrariesByScroll() {
        if (!hasMoreLibraryResults || !resultsFlick) return
        var remaining = Math.max(0, resultsFlick.contentHeight - (resultsFlick.contentY + resultsFlick.height))
        if (remaining <= resultsFlick.height * 1.1)
            _requestMoreLibraryResults()
    }

    function _flushPendingSearchPayload(seq) {
        if (!_pendingSearchPayload || _pendingSearchPayloadSeq !== seq) return false
        var payload = _pendingSearchPayload
        _pendingSearchPayload = null
        _pendingSearchPayloadSeq = -1
        progressiveApplyTimer.stop()
        return _applySearchPayload(payload, seq)
    }

    function _queueSearchPayload(payload, seq) {
        if (seq !== requestSequence) return
        var complete = !(payload && payload.complete === false)
        if (complete) {
            _discardPendingSearchPayload()
            _applySearchPayload(payload, seq)
            return
        }
        _pendingSearchPayload = payload
        _pendingSearchPayloadSeq = seq
        // Ne pas restart() à chaque fragment : une rafale ne peut pas repousser
        // indéfiniment le premier affichage.
        if (!progressiveApplyTimer.running) progressiveApplyTimer.start()
    }

    function performSearch() {
        var q = _trim(queryText)
        searchDelay.stop()

        if (q.length < minimumQueryLength) {
            clearSearch()
            return
        }
        if (!serverUrl || !accessToken || !userId) {
            clearSearch()
            errorText = "La session Jellyfin n’est pas prête."

            return
        }

        _cancelSearchEngine("replaced")
        var seq = ++requestSequence
        _discardPendingSearchPayload()
        loading = true
        enriching = false
        hasMoreLibraryResults = false
        loadingMoreLibraryResults = false
        currentSearchHasPayload = false
        errorText = ""
        searchBudget.restart()

        try {
            _startSearchEngine(seq, q, 0, resultLimit,
                function(payload) {

                    if (seq !== requestSequence) {

                        return
                    }
                    _queueSearchPayload(payload, seq)
                },
                function(code) {

                    if (seq !== requestSequence) {

                        return
                    }
                    _flushPendingSearchPayload(seq)
                    loading = false
                    enriching = false
                    hasMoreLibraryResults = false
                    loadingMoreLibraryResults = false
                    searchBudget.stop()
                    if (currentSearchHasPayload && hasResults) {
                        errorText = ""
                        return
                    }
                    results = []
                    resultSections = []
                    folderResultSections = []
                    sectionSelectionIndices = []
                    activeSectionIndex = -1
                    resultsFocusActive = false
                    totalRecordCount = 0
                    var c = (code && code.code !== undefined) ? _s(code.code) : _s(code)
                    if (c === "timeout")
                        errorText = "Le serveur met trop de temps à répondre. [" + c + "]"
                    else if (c === "http_401" || c === "http_403")
                        errorText = "La session Jellyfin a expiré. [" + c + "]"
                    else
                        errorText = "La recherche Jellyfin a échoué. [" + (c || "unknown") + "]"
                })
        } catch(e) {
            loading = false
            enriching = false
            hasMoreLibraryResults = false
            loadingMoreLibraryResults = false
            searchBudget.stop()
            results = []
            resultSections = []
            folderResultSections = []
            sectionSelectionIndices = []
            activeSectionIndex = -1
            resultsFocusActive = false
            totalRecordCount = 0
            errorText = "Exception locale pendant la recherche."

        }
    }

    Timer {
        id: progressiveApplyTimer
        interval: searchPage.progressiveApplyIntervalMs
        repeat: false
        onTriggered: searchPage._flushPendingSearchPayload(searchPage._pendingSearchPayloadSeq)
    }

    Timer {
        id: searchBudget
        interval: searchPage.searchBudgetMs
        repeat: false
        onTriggered: {
            if (!searchPage.loading && !searchPage.enriching) return
            searchPage._flushPendingSearchPayload(searchPage.requestSequence)
            searchPage._cancelSearchEngine("timeout")
            searchPage.loading = false
            searchPage.enriching = false
            searchPage.hasMoreLibraryResults = false
            searchPage.loadingMoreLibraryResults = false
            if (!searchPage.currentSearchHasPayload) {
                searchPage.results = []
                searchPage.resultSections = []
                searchPage.folderResultSections = []
                searchPage.sectionSelectionIndices = []
                searchPage.activeSectionIndex = -1
                searchPage.resultsFocusActive = false
                searchPage.totalRecordCount = 0
                searchPage.errorText = "Le serveur met trop de temps à répondre. [timeout]"
            }
        }
    }

    function openSeries(item) {
        if (!item || !item.Id || openingItem) return
        openingItem = true
        Jellyfin.fetchSeasons(serverUrl, accessToken, userId, item.Id,
            function(items) {
                openingItem = false
                items = items || []
                requestSeasonPage(_s(item.Id), items.length > 0 ? _s(items[0].Id) : "", "")
            },
            function() {
                openingItem = false
                requestSeasonPage(_s(item.Id), "", "")
            })
    }

    function _routeHydratedFolder(item) {
        if (!item || !item.Id) return
        var t = MediaCatalog.itemTypeLower(item)
        var ct = _collectionTypeLower(item)
        if (t === "boxset" || ct === "boxsets") {
            requestCollectionPage(_s(item.Id))
            return
        }
        if (t === "series" || ct === "tvshows") {
            requestSeriesPage(_s(item.Id))
            return
        }
        requestMoviePage(_s(item.Id))
    }

    function openFolder(item) {
        if (!item || !item.Id || openingItem) return
        openingItem = true

        Jellyfin.fetchUserItem(serverUrl, accessToken, userId, item.Id,
            function(fullItem) {
                openingItem = false
                fullItem = fullItem || item

                _routeHydratedFolder(fullItem)
            },
            function(err) {
                openingItem = false

                requestMoviePage(_s(item.Id))
            })
    }

    function activateResult(item) {
        if (!item || openingItem) return
        var t = MediaCatalog.itemTypeLower(item)
        if (t === "movie" || t === "video" || t === "musicvideo") {
            requestDetailMovie(_s(item.Id))
        } else if (t === "series") {
            openSeries(item)
        } else if (t === "episode") {
            if (item.SeriesId) {
                requestSeasonPage(_s(item.SeriesId), _s(item.SeasonId || item.ParentId), _s(item.Id))
            } else {
                openingItem = true

                Jellyfin.fetchUserItem(serverUrl, accessToken, userId, item.Id,
                    function(fullItem) {
                        openingItem = false
                        fullItem = fullItem || item

                        requestSeasonPage(_s(fullItem.SeriesId),
                                          _s(fullItem.SeasonId || fullItem.ParentId),
                                          _s(fullItem.Id || item.Id))
                    },
                    function(err) {
                        openingItem = false

                    })
            }
        } else if (t === "boxset") {
            requestCollectionPage(_s(item.Id))
        } else if (_isFolderType(t) || item.IsFolder === true) {
            openFolder(item)
        }
    }

    function _primaryTag(item) {
        var tags = item && item.ImageTags ? item.ImageTags : {}
        return _s((tags && tags.Primary) || (item && item.PrimaryImageTag))
    }

    function _imageVariantKey(id, type, tag) {
        return _s(id) + "|" + _s(type).toLowerCase() + "|" + _s(tag)
    }

    function _clearImageVariantFailures() {
        _imageVariantFailureUntil = ({})
        _imageVariantFailureOrder = []
    }

    function _pruneImageVariantFailures(now) {
        now = Number(now || Date.now())
        var map = _imageVariantFailureUntil || ({})
        var order = _imageVariantFailureOrder || []
        var next = [], seen = ({})
        for (var i = 0; i < order.length; i++) {
            var key = _s(order[i])
            if (!key || seen[key]) continue
            var until = Number(map[key] || 0)
            if (until > now) {
                seen[key] = true
                next.push(key)
            } else {
                try { delete map[key] } catch(e0) {}
            }
        }
        while (next.length > imageVariantFailureMaxEntries) {
            var victim = next.shift()
            try { delete map[victim] } catch(e1) {}
        }
        _imageVariantFailureUntil = map
        _imageVariantFailureOrder = next
    }

    // Contrat facultatif utilisé par PosterGridCard.
    function isImageVariantUnavailable(id, type, tag) {
        if (_s(type).toLowerCase() !== "thumb") return false
        var key = _imageVariantKey(id, type, tag)
        var until = Number((_imageVariantFailureUntil || ({}))[key] || 0)
        if (until <= 0) return false
        var now = Date.now()
        if (until <= now) {
            try { delete _imageVariantFailureUntil[key] } catch(e0) {}
            return false
        }
        return true
    }

    function markImageVariantUnavailable(id, type, tag) {
        // On ne blacklist que Thumb : un échec Primary/Backdrop peut être
        // transitoire et ne doit pas masquer un média valide cinq minutes.
        if (_s(type).toLowerCase() !== "thumb" || !_s(id) || !_s(tag))
            return false
        var now = Date.now()
        var key = _imageVariantKey(id, type, tag)
        var map = _imageVariantFailureUntil || ({})
        var order = (_imageVariantFailureOrder && _imageVariantFailureOrder.slice)
                ? _imageVariantFailureOrder.slice(0) : []
        map[key] = now + imageVariantFailureTtlMs
        order.push(key)
        _imageVariantFailureUntil = map
        _imageVariantFailureOrder = order
        _pruneImageVariantFailures(now)
        return true
    }

    function _usableImageSpec(id, type, tag, fit) {
        id = _s(id); type = _s(type); tag = _s(tag)
        if (!id || !type || !tag) return null
        if (isImageVariantUnavailable(id, type, tag)) return null
        return { id: id, type: type, tag: tag, fit: fit === true }
    }

    function _imageSpec(item, sectionKey) {
        if (!item || !item.Id) return { id: "", type: "", tag: "", fit: false }

        var spec = null
        if (MediaCatalog.itemTypeLower(item) === "episode") {
            spec = _usableImageSpec(item.Id, "Primary", _primaryTag(item), false)
            if (spec) return spec

            spec = _usableImageSpec(item.ThumbImageItemId || item.Id,
                                    "Thumb", item.ThumbImageTag, false)
            if (spec) return spec

            spec = _usableImageSpec(item.BackdropImageItemId || item.Id,
                                    "Backdrop", item.BackdropImageTag, false)
            if (spec) return spec

            if (item.ParentBackdropItemId && item.ParentBackdropImageTags &&
                    item.ParentBackdropImageTags.length > 0) {
                spec = _usableImageSpec(item.ParentBackdropItemId, "Backdrop",
                                        item.ParentBackdropImageTags[0], false)
                if (spec) return spec
            }

            spec = _usableImageSpec(item.SeriesId, "Primary",
                                    item.SeriesPrimaryImageTag, true)
            if (spec) return spec
        }

        spec = _usableImageSpec(item.Id, "Primary", _primaryTag(item), false)
        if (spec) return spec

        spec = _usableImageSpec(item.ThumbImageItemId || item.Id,
                                "Thumb", item.ThumbImageTag, false)
        if (spec) return spec

        spec = _usableImageSpec(item.BackdropImageItemId || item.Id,
                                "Backdrop", item.BackdropImageTag, false)
        if (spec) return spec

        return { id: "", type: "", tag: "", fit: false }
    }

    function resultImageUrl(item, sectionKey, portrait, requestedWidth, requestedHeight, options) {
        var spec = _imageSpec(item, sectionKey)
        if (!spec.id || !spec.type || !serverUrl) return ""
        var width = Math.max(1, Number(requestedWidth || (portrait ? portW : resumeLandscapeW)))
        var height = Math.max(1, Number(requestedHeight || (portrait ? portH : resumeLandscapeH)))
        var scale = options && Number(options.scale) > 0 ? Number(options.scale) : posterScale
        var quality = options && Number(options.quality) > 0 ? Number(options.quality) : posterQFast
        var imageOptions = { quality: quality, format: "jpg", disableEnhancers: true }
        if (spec.fit) {
            imageOptions.maxWidth = Math.round(width * scale)
            imageOptions.maxHeight = Math.round(height * scale)
        } else {
            imageOptions.fillWidth = Math.round(width * scale)
            imageOptions.fillHeight = Math.round(height * scale)
        }
        return Jellyfin.itemImageUrl(serverUrl, spec.id, spec.type, spec.tag,
                                     imageOptions)
    }

    // Contrat utilisé par PosterGridCard.qml lorsqu'un résultat SearchHint ne
    // possède pas les champs ImageTags complets d'un BaseItem Jellyfin.
    function posterUrlFor(item, requestedWidth, requestedHeight, options) {
        var key = _sectionKeyFor(item)
        return resultImageUrl(item, key, !_itemUsesLandscape(item, key),
                              requestedWidth, requestedHeight, options || ({}))
    }

    onServerUrlChanged: {
        _clearImageVariantFailures()

    }
    onUserIdChanged: {
        _clearImageVariantFailures()

    }
    Timer {
        id: searchDelay
        interval: 480
        repeat: false
        onTriggered: searchPage.performSearch()
    }

    Rectangle { anchors.fill: parent; color: "#000000" }

    Item {
        id: content
        anchors.fill: parent
        anchors.leftMargin: 0
        anchors.rightMargin: 0
        anchors.topMargin: 86
        anchors.bottomMargin: 34

        // Le titre redondant "Recherche" est retiré. La barre devient le point
        // d'entrée visuel principal et reste centrée sous les onglets HomePage.
        Rectangle {
            id: searchField
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            width: Math.min(900, parent.width * 0.52)
            height: 58
            radius: 13
            color: (searchFieldHit.activeFocus || searchInput.activeFocus) ? "#242a3a" : "#171b24"
            border.width: 2
            border.color: (searchFieldHit.activeFocus || searchInput.activeFocus) ? "#ffffff" : "#4b5266"

            Item {
                anchors.left: parent.left
                anchors.leftMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                width: 26
                height: 26

                Rectangle {
                    width: 15
                    height: 15
                    radius: 8
                    color: "transparent"
                    border.width: 2
                    border.color: "#dce2f5"
                    anchors.left: parent.left
                    anchors.top: parent.top
                }
                Rectangle {
                    width: 10
                    height: 2
                    radius: 1
                    color: "#dce2f5"
                    rotation: 45
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    transformOrigin: Item.Center
                }
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 56
                anchors.right: clearButton.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: "Rechercher un film, une série, un épisode, une collection ou un dossier…"
                color: "#8993aa"
                font.pixelSize: 19
                visible: searchInput.text.length === 0
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }

            FbxBase.Clickable {
                id: searchFieldHit
                anchors.fill: parent
                focus: true
                onActiveFocusChanged: {
                    if (activeFocus) searchPage.resultsFocusActive = false
                }
                onClicked: searchInput.forceActiveFocus()
                Keys.onReturnPressed: searchInput.forceActiveFocus()
                Keys.onEnterPressed: searchInput.forceActiveFocus()
                Keys.onPressed: {
                    if (event.key === Qt.Key_Select || event.key === Qt.Key_Ok) {
                        searchInput.forceActiveFocus()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Up) {
                        searchPage.requestTopBar()
                        event.accepted = true
                    } else if (event.key === Qt.Key_Down) {
                        searchPage.focusResults()
                        event.accepted = true
                    }
                }
            }

            TextInput {
                id: searchInput
                z: 2
                anchors.left: parent.left
                anchors.leftMargin: 56
                anchors.right: clearButton.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                height: Math.round(font.pixelSize * 1.45)
                color: "#ffffff"
                selectionColor: "#5b6daa"
                selectedTextColor: "#ffffff"
                font.pixelSize: 21
                clip: true
                focus: false
                inputMethodHints: Qt.ImhNoPredictiveText
                text: searchPage.queryText
                cursorVisible: activeFocus

                cursorDelegate: Rectangle {
                    width: 2
                    height: Math.round(searchInput.font.pixelSize * 1.2)
                    color: "#ffffff"
                    anchors.verticalCenter: parent.verticalCenter
                }

                onTextChanged: {
                    if (searchPage.queryText !== text) searchPage.queryText = text

                    searchPage.scheduleSearch()
                }
                onActiveFocusChanged: {
                    if (activeFocus) {
                        searchPage.resultsFocusActive = false
                        Qt.inputMethod.show()
                    } else {
                        Qt.inputMethod.hide()
                    }
                }
                onAccepted: {
                    Qt.inputMethod.hide()
                    searchPage.performSearch()
                    searchFieldHit.forceActiveFocus()
                }
                Keys.onReturnPressed: {
                    Qt.inputMethod.hide()
                    searchPage.performSearch()
                    searchFieldHit.forceActiveFocus()
                    event.accepted = true
                }
                Keys.onEnterPressed: {
                    Qt.inputMethod.hide()
                    searchPage.performSearch()
                    searchFieldHit.forceActiveFocus()
                    event.accepted = true
                }
                Keys.onDownPressed: {
                    Qt.inputMethod.hide()
                    searchPage.focusResults()
                    event.accepted = true
                }
                Keys.onUpPressed: {
                    Qt.inputMethod.hide()
                    searchPage.requestTopBar()
                    event.accepted = true
                }
                Keys.onBackPressed: {
                    Qt.inputMethod.hide()
                    searchFieldHit.forceActiveFocus()
                    event.accepted = true
                }
            }

            Rectangle {
                id: clearButton
                z: 3
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 42
                height: 42
                radius: 21
                color: clearHit.activeFocus ? "#3a4257" : "transparent"
                visible: searchInput.text.length > 0

                Text {
                    anchors.centerIn: parent
                    text: "×"
                    color: "#ffffff"
                    font.pixelSize: 26
                    textFormat: Text.PlainText
                }

                FbxBase.Clickable {
                    id: clearHit
                    anchors.fill: parent
                    function clearNow() {
                        searchInput.text = ""
                        searchPage.focusSearchField()
                    }
                    onClicked: clearNow()
                    Keys.onReturnPressed: clearNow()
                    Keys.onEnterPressed: clearNow()
                    Keys.onPressed: {
                        if (event.key === Qt.Key_Select || event.key === Qt.Key_Ok) {
                            clearNow()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Left) {
                            searchPage.focusSearchField()
                            event.accepted = true
                        }
                    }
                }
            }
        }

        Text {
            id: helperText
            anchors.horizontalCenter: searchField.horizontalCenter
            anchors.top: searchField.bottom
            anchors.topMargin: 8
            width: searchField.width
            horizontalAlignment: Text.AlignHCenter
            color: errorText.length > 0 ? "#ff9f9f" : "#9aa4bb"
            font.pixelSize: 16
            textFormat: Text.PlainText
            text: {
                if (errorText.length > 0) return errorText
                if (loading) return "Recherche en cours…"
                if (loadingMoreLibraryResults) return "Chargement d’autres bibliothèques…"
                if (_trim(queryText).length < minimumQueryLength)
                    return "Saisissez au moins " + minimumQueryLength + " caractères."
                if (!hasResults) return "Aucun résultat."
                return results.length + " résultat" + (results.length > 1 ? "s" : "") +
                       " dans " + resultSections.length + " section" +
                       (resultSections.length > 1 ? "s" : "")
            }
        }

        Flickable {
            id: resultsFlick
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: helperText.bottom
            anchors.topMargin: 12
            anchors.bottom: parent.bottom
            contentWidth: width
            contentHeight: sectionsColumn.implicitHeight + 54
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: true
            onContentYChanged: searchPage._maybeRequestMoreLibrariesByScroll()

            Behavior on contentY {
                enabled: searchPage.allowAnims && !resultsFlick.moving && !resultsFlick.dragging
                NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
            }

            Column {
                id: sectionsColumn
                width: resultsFlick.width
                spacing: 44

                Repeater {
                    id: sectionRepeater
                    model: searchPage.resultSections

                    delegate: Item {
                        id: sectionRoot
                        width: sectionsColumn.width
                        property int sectionIndex: index
                        property var sectionData: modelData
                        property string sectionKey: sectionData ? searchPage._s(sectionData.key) : ""
                        property var sectionItems: sectionData && sectionData.items ? sectionData.items : []
                        property var listObj: sectionListLoader.item
                        readonly property int cardHeight: sectionData ? Number(sectionData.cardHeight || 0) : 0
                        readonly property int edgePad: sectionData ? Number(sectionData.edgePad || 14) : 14
                        readonly property real viewportTop: y + sectionsColumn.y
                        readonly property real viewportMargin: Math.max(240, resultsFlick.height * 1.25)
                        readonly property bool nearVerticalViewport:
                            (viewportTop + height) >= (resultsFlick.contentY - viewportMargin) &&
                            viewportTop <= (resultsFlick.contentY + resultsFlick.height + viewportMargin)
                        readonly property bool forceSectionActive:
                            searchPage.resultsFocusActive &&
                            searchPage.activeSectionIndex === sectionIndex
                        readonly property bool sectionLoaderActive:
                            visible && (nearVerticalViewport || forceSectionActive)
                        height: sectionItems.length > 0 ? cardHeight + 65 : 0
                        visible: sectionItems.length > 0

                        Text {
                            id: sectionHeader
                            anchors.left: parent.left
                            anchors.leftMargin: 40
                            anchors.top: parent.top
                            text: sectionRoot.sectionData ? searchPage._s(sectionRoot.sectionData.title) : ""
                            color: "#ffffff"
                            font.pixelSize: searchPage.sectionTitleFontPx
                            font.bold: true
                            font.weight: Font.Bold
                            textFormat: Text.PlainText
                        }

                        Loader {
                            id: sectionListLoader
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            anchors.top: parent.top
                            anchors.topMargin: 45
                            height: sectionRoot.cardHeight
                            active: sectionRoot.sectionLoaderActive
                            asynchronous: false

                            sourceComponent: Component {
                                ListView {
                                    id: sectionList
                                    anchors.fill: parent
                                    orientation: ListView.Horizontal
                                    model: sectionRoot.sectionItems
                                    spacing: searchPage.spacingW
                                    clip: true
                                    reuseItems: true
                                    cacheBuffer: Math.round(searchPage.resumeLandscapeW * 1.6)
                                    boundsBehavior: Flickable.StopAtBounds
                                    // Même stratégie que les rails manuels de postergrid.qml.
                                    // ListView ne déplace plus automatiquement son contenu : cela
                                    // évite les sauts secs lors d'un changement de carte ou de rail.
                                    snapMode: ListView.NoSnap
                                    highlightMoveDuration: 0
                                    highlightRangeMode: ListView.NoHighlightRange
                                    preferredHighlightBegin: 0
                                    preferredHighlightEnd: 0
                                    highlightFollowsCurrentItem: false
                                    highlight: Item { width: 1; height: 1 }
                                    focus: searchPage.resultsFocusActive &&
                                           searchPage.activeSectionIndex === sectionRoot.sectionIndex
                                    // Important : currentIndex reste désactivé. Qt ListView
                                    // ne peut donc plus recaler brutalement contentX quand on
                                    // revient vers la gauche. La sélection est gérée séparément.
                                    currentIndex: -1
                                    interactive: false
                                    keyNavigationEnabled: false
                                    header: Item { width: sectionRoot.edgePad; height: 1 }
                                    footer: Item { width: sectionRoot.edgePad; height: 1 }

                                    property var rowItems: sectionRoot.sectionItems
                                    property int edgePad: sectionRoot.edgePad
                                    property int _ensureVisibleSeq: 0
                                    readonly property int selectedIndex: count > 0
                                            ? searchPage._selectionFor(sectionRoot.sectionIndex, count)
                                            : -1
                                    readonly property real logicalContentWidth:
                                        searchPage._rowLogicalWidth(rowItems, spacing, edgePad, width)
                                    contentWidth: logicalContentWidth

                            // Filet de sécurité très léger contre les variations
                            // tardives de géométrie de ListView sous Qt 5.15.
                            // Deux vérifications maximum, uniquement sur le rail
                            // focalisé. Le calcul lui-même ne dépend plus d'originX.
                            property int _viewportSettlePass: 0

                            function scheduleViewportSettle() {
                                if (!activeFocus || selectedIndex < 0) return
                                _viewportSettlePass = 0
                                sectionViewportSettleTimer.restart()
                            }

                            function _runViewportSettle() {
                                if (!activeFocus || selectedIndex < 0 || selectedIndex >= count)
                                    return

                                // Pendant un scroll rapide, une ancienne animation
                                // peut être interrompue par la suivante. On attend
                                // qu'elle soit réellement terminée avant de corriger.
                                if (sectionContentXAnimation.running) {
                                    if (_viewportSettlePass < 2) {
                                        _viewportSettlePass++
                                        sectionViewportSettleTimer.restart()
                                    }
                                    return
                                }

                                var target = searchPage._rowTargetX(sectionList, selectedIndex)
                                var delta = Math.abs(Number(target) - Number(contentX || 0))
                                if (delta > 0.75)
                                    contentX = target

                                // Une deuxième passe couvre le tour d'event-loop où
                                // Qt finit de recycler un delegate portrait/paysage.
                                if (_viewportSettlePass < 1) {
                                    _viewportSettlePass++
                                    sectionViewportSettleTimer.restart()
                                }
                            }

                            function ensureCurrentItemVisible(reason) {
                                var sequence = ++_ensureVisibleSeq
                                var immediate = reason === "selection" ||
                                                reason === "key-left" ||
                                                reason === "key-right" ||
                                                reason === "mouse" ||
                                                reason === "double-mouse" ||
                                                reason === "section-focus"
                                searchPage._ensureRowIndexVisible(sectionList, selectedIndex,
                                                                  sectionContentXAnimation,
                                                                  sequence,
                                                                  immediate)
                                scheduleViewportSettle()
                            }

                            Timer {
                                id: sectionViewportSettleTimer
                                interval: 32
                                repeat: false
                                onTriggered: sectionList._runViewportSettle()
                            }

                            NumberAnimation {
                                id: sectionContentXAnimation
                                target: sectionList
                                property: "contentX"
                                duration: 170
                                easing.type: Easing.OutCubic
                                onStopped: sectionList.scheduleViewportSettle()
                            }

                            Component.onCompleted: ensureCurrentItemVisible("completed")

                            onCountChanged: {
                                var wanted = searchPage._selectionFor(sectionRoot.sectionIndex, count)
                                if (wanted >= 0)
                                    searchPage._storeSelection(sectionRoot.sectionIndex, wanted)
                                ensureCurrentItemVisible("count")
                            }

                            onWidthChanged: ensureCurrentItemVisible("width")
                            onLogicalContentWidthChanged: ensureCurrentItemVisible("content-width")

                            // Le bug observé venait précisément d'originX qui
                            // changeait après le calcul de la destination. On ne
                            // l'utilise plus pour les bornes, mais son changement
                            // signale que Qt vient de terminer une étape de layout.
                            onOriginXChanged: {
                                if (activeFocus)
                                    scheduleViewportSettle()
                            }

                            onSelectedIndexChanged: ensureCurrentItemVisible("selection")

                            Keys.onPressed: {
                                var idx = selectedIndex
                                if (event.key === Qt.Key_Left) {
                                    if (idx > 0)
                                        searchPage._setSectionSelection(sectionRoot.sectionIndex,
                                                                        idx - 1, "key-left")
                                    event.accepted = true
                                } else if (event.key === Qt.Key_Right) {
                                    if (idx >= 0 && idx + 1 < count)
                                        searchPage._setSectionSelection(sectionRoot.sectionIndex,
                                                                        idx + 1, "key-right")
                                    event.accepted = true
                                } else if (event.key === Qt.Key_Up) {
                                    if (sectionRoot.sectionIndex > 0)
                                        searchPage.focusSection(sectionRoot.sectionIndex - 1)
                                    else
                                        searchPage.focusSearchField()
                                    event.accepted = true
                                } else if (event.key === Qt.Key_Down) {
                                    if (sectionRoot.sectionIndex + 1 < searchPage.resultSections.length)
                                        searchPage.focusSection(sectionRoot.sectionIndex + 1)
                                    event.accepted = true
                                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter ||
                                           event.key === Qt.Key_Select || event.key === Qt.Key_Ok) {
                                    if (idx >= 0 && idx < sectionRoot.sectionItems.length)
                                        searchPage.activateResult(sectionRoot.sectionItems[idx])
                                    event.accepted = true
                                } else if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
                                    searchPage.focusSearchField()
                                    event.accepted = true
                                }

                            }

                            delegate: Loader {
                                id: searchCardLoader
                                width: Math.max(1, Number(modelData && modelData._searchDelegateWidth || 1))
                                height: sectionRoot.cardHeight
                                z: cardSelected ? 100 : 0

                                property var cardData: modelData
                                property var cardController: searchPage
                                property bool cardSelected: sectionList.activeFocus
                                                            && sectionList.selectedIndex === index
                                property bool cardShowProgress: false
                                property bool cardPreferBackdrop:
                                    searchPage._cardPrefersBackdrop(cardData, sectionRoot.sectionKey)
                                property bool cardMusicFallback: false
                                property string cardFallbackKind:
                                    searchPage._cardFallbackKind(cardData, sectionRoot.sectionKey)
                                property string cardImagePolicy: "standard"
                                property bool cardAllowLoad:
                                    sectionRoot.nearVerticalViewport || sectionRoot.forceSectionActive
                                property bool cardEnableMouseInput: true
                                property bool cardSuppressFocusTransform: false
                                property int cardTileW: Math.max(1, Number(cardData && cardData._searchTileW || searchPage.portW))
                                property int cardTileH: Math.max(1, Number(cardData && cardData._searchTileH || searchPage.portH))
                                property int cardTitleH: searchPage.titleH
                                property int cardSidePad: Math.max(0, Number(cardData && cardData._searchSidePad || 0))
                                property int cardTopPad: Math.max(0, Number(cardData && cardData._searchTopPad || 0))

                                source: searchPage.posterGridCardSource
                                onLoaded: if (item) item.homeLoader = searchCardLoader

                                Connections {
                                    target: searchCardLoader.item
                                    ignoreUnknownSignals: true

                                    function onActivated() {
                                        searchPage.resultsFocusActive = true
                                        searchPage.activeSectionIndex = sectionRoot.sectionIndex
                                        searchPage._storeSelection(sectionRoot.sectionIndex, index)
                                        sectionList.forceActiveFocus()
                                        sectionList.ensureCurrentItemVisible("mouse")
                                        searchPage._ensureSectionVisible(sectionRoot)
                                    }

                                    function onDoubleActivated() {
                                        searchPage.resultsFocusActive = true
                                        searchPage.activeSectionIndex = sectionRoot.sectionIndex
                                        searchPage._storeSelection(sectionRoot.sectionIndex, index)
                                        sectionList.forceActiveFocus()
                                        sectionList.ensureCurrentItemVisible("double-mouse")
                                        searchPage.activateResult(cardData)
                                    }
                                }
                                }
                            }
                        }
                    }
                }
            }
        }
        }

        Item {
            id: loadingIndicator
            width: 64
            height: 64
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            visible: searchPage.loading || searchPage.openingItem
            z: 100

            Repeater {
                model: 8
                delegate: Rectangle {
                    width: 7
                    height: 7
                    radius: 4
                    color: "#ffffff"
                    x: loadingIndicator.width / 2 + 24 * Math.cos(2 * Math.PI * index / 8) - width / 2
                    y: loadingIndicator.height / 2 + 24 * Math.sin(2 * Math.PI * index / 8) - height / 2
                    opacity: 0.18

                    SequentialAnimation on opacity {
                        running: loadingIndicator.visible
                        loops: Animation.Infinite
                        PauseAnimation { duration: index * 75 }
                        NumberAnimation { from: 0.18; to: 1.0; duration: 170 }
                        NumberAnimation { from: 1.0; to: 0.18; duration: 420 }
                        PauseAnimation { duration: (7 - index) * 75 }
                    }
                }
            }
        }
    }

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: {
        if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
            if (searchInput.activeFocus && Qt.inputMethod.visible) {
                Qt.inputMethod.hide()
                searchFieldHit.forceActiveFocus()
            } else if (resultsFocusActive) {
                focusSearchField()
            } else {
                requestTopBar()
            }
            event.accepted = true
        }
    }

    Component.onCompleted: {

        Qt.callLater(function() {
            if (searchPage) searchPage.focusSearchField()
        })
    }

    Component.onDestruction: {

        requestSequence++
        searchDelay.stop()
        searchBudget.stop()
        _discardPendingSearchPayload()
        _cancelSearchEngine("destroyed")
        Qt.inputMethod.hide()
    }
}
