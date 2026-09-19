// qml/pages/PersonPage.qml Fiche personne Jellyfin dédiée — QtQuick 2.15, aucun QtQuick Controls. - Détails user-scoped pour récupérer UserData.IsFavorite - Favori via GlassCircleButton + Jellyfin.setFavorite() - Filmographie locale uniquement via /Items?PersonIds=... - Rails Films / Séries TV / Épisodes liés à la personne, légers et virtualisés.
import QtQuick 2.15
import QtGraphicalEffects 1.15
import "." as Pages
import "../components" as Components
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/SeasonUtils.js" as SeasonUtils
import "../js/MediaCatalog.js" as MediaCatalog
FocusScope {
    id: personPage
    width: parent ? parent.width : 1280
    height: parent ? parent.height : 720
    focus: true

    property string accessToken: ""
    property string userId: ""
    property string serverUrl: ""
    property string itemId: ""              // Id Jellyfin de la personne
    property string personSource: ""         // "guest" quand ouvert depuis GuestPage
    property string userName: ""
    property string userImageTag: ""
    property var fbx
    property var shared: null
    signal requestNavigation(string page)
    signal requestBackToMenu()

    property var person: null
    property var movies: []
    property var series: []
    property var episodes: []
    property bool personLoading: false
    property bool personMetadataPending: false

    // Contrat avec ShellPage : le CircleDotsLoader global reste actif tant que la fiche personne n'a pas terminé sa fenêtre de récupération des métadonnées différées (bio / date de naissance). Cette attente est strictement bornée : après le retry final, la page est révélée même si Jellyfin n'a réellement aucune donnée supplémentaire à fournir.
    readonly property bool shellLoading: personLoading || personMetadataPending
    readonly property string shellLoadingError: ""
    property bool creditsLoading: false
    property bool creditsLoaded: false
    property bool favorite: false
    property bool favoriteBusy: false
    property string loadingError: ""
    property int _fetchSeq: 0

    // Certains serveurs Jellyfin renvoient ponctuellement un Person sans Overview lors du tout premier accès, puis exposent la bio quelques secondes plus tard. Un seul retry différé suffit et évite tout polling.
    property int _personBioRetrySeq: 0
    property string _personBioRetryItemId: ""
    property bool _personBioRetryInFlight: false

    readonly property int focusHud: -1
    readonly property int focusFavorite: 0
    readonly property int focusMovies: 1
    readonly property int focusSeries: 2
    readonly property int focusBio: 3
    readonly property int focusPortrait: 4
    readonly property int focusEpisodes: 5
    property int currentFocus: focusFavorite
    // Une sortie volontaire de PersonPage ne doit jamais laisser les signaux
    // de teardown (ListView.currentIndexChanged, focus, etc.) recréer un snapshot
    // juste après son effacement. Le verrou ne vit que dans cette instance.
    property bool _focusStateSaveBlocked: false

    // Handoff anti-race lors d'une remontée verticale rapide.
    property bool _hudFocusPending: false
    property int _hudFocusRetryLeft: 0
    property bool bioOverlayOpen: false
    property bool photoViewerOpen: false
    readonly property bool modalOpen: bioOverlayOpen || photoViewerOpen
    property real photoZoom: 1.0
    readonly property real photoZoomMin: 1.0
    readonly property real photoZoomMax: 3.0
    property real photoPanX: 0
    property real photoPanY: 0

    readonly property color glassFocus: "#1AFFFFFF"
    readonly property color glassBorder: "#33FFFFFF"
    readonly property int marginL: 54
    readonly property int marginR: 54
    readonly property int topGap: 78
    readonly property int portraitW: 250
    readonly property int portraitH: 360
    readonly property real portraitHqScale: 1.60
    readonly property int portraitHqQuality: 92
    readonly property int portraitTopShiftY: 36
    readonly property int bioMaxLines: 7
    readonly property int bioMinH: 190
    readonly property int mediaCardW: 158
    readonly property int mediaPosterW: 154
    readonly property int mediaPosterH: 231
    readonly property real mediaPosterHqScale: 1.50
    readonly property int mediaPosterHqQuality: 90
    readonly property int mediaGap: 4
    // Même zoom que PosterGrid : pic 1.14, stabilisation 1.12, lift 6 px.
    readonly property real focusScale: 1.14
    readonly property int mediaFocusLiftPx: 6
    readonly property int mediaPosterTopPad: Math.max(30, Math.ceil(mediaPosterH * (focusScale - 1)) + mediaFocusLiftPx + 8)
    readonly property int railH: mediaPosterTopPad + mediaPosterH + 66
    readonly property int railEdgePad: Math.max(marginL, Math.ceil(mediaPosterW * (focusScale - 1) * 0.6) + 24)

    // Rail épisodes paysage, proche de SeasonEpisodesRow mais beaucoup plus léger.
    readonly property int episodeCardW: 298
    readonly property int episodeThumbW: 292
    readonly property int episodeThumbH: 164
    readonly property real episodeThumbHqScale: 1.50
    readonly property int episodeThumbHqQuality: 90
    property string hqTargetKind: ""
    property string hqTargetId: ""
    property string _hqPendingKind: ""
    property string _hqPendingId: ""
    readonly property int episodeGap: 4
    // Rail épisodes aligné sur le zoom PosterGrid.
    readonly property real episodeFocusScale: 1.14
    readonly property int episodeFocusLiftPx: 6
    readonly property int episodeTopPad: Math.max(24, Math.ceil(episodeThumbH * (episodeFocusScale - 1)) + episodeFocusLiftPx + 8)
    readonly property int episodeRailH: episodeTopPad + episodeThumbH + 72
    readonly property int episodeEdgePad: Math.max(marginL, Math.ceil(episodeThumbW * (episodeFocusScale - 1) * 0.6) + 24)

    // Marquee titres des rails : mêmes constantes que CastPage.
    property bool mediaMarqueeEnabled: true
    property real mediaMarqueeSpeedPxPerSec: 56
    property int mediaMarqueeStartDelayMs: 700
    property int mediaMarqueeEndPauseMs: 260
    property int mediaMarqueeGapPx: 44

    property int creditsPageSize: 160
    readonly property int creditsWindowMaxItems: 480
    readonly property int creditsPrefetchThreshold: 8
    property var _creditsBasePages: []
    property var _creditsEpisodePages: []
    property var _creditsBaseHandle: null
    property var _creditsEpisodeHandle: null
    property double _creditsBaseDeadlineAt: 0
    property double _creditsEpisodeDeadlineAt: 0
    property int _creditsBaseAttempt: 0
    property int _creditsEpisodeAttempt: 0
    property bool creditsBaseHasMoreBefore: false
    property bool creditsBaseHasMoreAfter: false
    property bool creditsEpisodeHasMoreBefore: false
    property bool creditsEpisodeHasMoreAfter: false
    property bool _creditsBaseLoadingMore: false
    property bool _creditsEpisodeLoadingMore: false

    // Restauration retour média -> PersonPage.
    // Le focus peut être prêt avant le layout final du Flickable. Dans ce cas,
    // appliquer contentY immédiatement le clampait à 0. On conserve donc le
    // viewport demandé jusqu'à ce que contentHeight soit réellement exploitable.
    property bool _restoreViewportPending: false
    property real _restoreViewportY: 0
    property int _restoreViewportFocus: -1

    readonly property real hudScrollOpacity: {
        var y = rootFlick ? Number(rootFlick.contentY || 0) : 0
        var t = y / 90.0
        if (t < 0) t = 0
        if (t > 1) t = 1
        return 1.0 - t
    }

    function _sharedNavApi(){ try { return shared && shared.__redefinNavApi ? shared.__redefinNavApi : null } catch(e) { return null } }
    function _hydrateSensitiveContextFromShared(){
        var api = _sharedNavApi()
        return api && api.hydrate ? api.hydrate(personPage, false, 0, false) : false
    }
    function _storeSensitiveNavContext(){
        var api = _sharedNavApi()
        return api && api.storeTarget ? api.storeTarget(personPage) : false
    }

    function _navRoute(page, params){
        var api = _sharedNavApi()
        return api && api.route ? api.route(personPage, page, params || ({})) : (page + "?ctx=1")
    }

    function _detailReturnContext(){
        try {
            if (!shared || !shared.__redefinPersonReturnContext)
                return null
            var ctx = shared.__redefinPersonReturnContext
            var personId = String(ctx.personId || "")
            var ts = Number(ctx.ts || 0)
            // Protection anti-contexte ancien ou provenant d'une autre PersonPage.
            if (!itemId || !personId || personId !== String(itemId))
                return null
            if (ts > 0 && (Date.now() - ts) > 6 * 60 * 60 * 1000) {
                shared.__redefinPersonReturnContext = null
                return null
            }
            return ctx
        } catch(e) {
            return null
        }
    }
    function _markDetailReturnBeforeBack(){
        try {
            var ctx = _detailReturnContext()
            if (!ctx || !shared)
                return false
            var detailId = String(ctx.detailItemId || "")
            if (!detailId.length)
                return false
            // Marker frais, consommé par la fiche Movie/Serie au moment exact du retour. Pas de refresh forcé : si la fiche chaude est encore valide, elle est simplement révélée proprement après le passage du debounce.
            shared.__redefinDetailReturnRefresh = ({
                itemId: detailId,
                scope: "person",
                detailKind: String(ctx.detailKind || ""),
                castIndex: (ctx.castIndex !== undefined && ctx.castIndex !== null) ? (Number(ctx.castIndex)|0) : 0,
                castPersonId: String(ctx.personId || ""),
                returnScrollY: (ctx.returnScrollY !== undefined && ctx.returnScrollY !== null) ? Number(ctx.returnScrollY) : null,
                returnCastViewportY: (ctx.returnCastViewportY !== undefined && ctx.returnCastViewportY !== null) ? Number(ctx.returnCastViewportY) : null,
                forceRefresh: false,
                ts: Date.now()
            })
            shared.__redefinPersonReturnContext = null
            return true
        } catch(e) {
            return false
        }
    }

    function _personStateBucket(){
        if (!shared) return null
        if (!shared.__personPageFocus) shared.__personPageFocus = ({})
        return shared.__personPageFocus
    }
    function _saveFocusState(){
        if (_focusStateSaveBlocked) return
        var b = _personStateBucket()
        if (!b || !itemId) return
        var movieId = (moviesList && movies && moviesList.currentIndex >= 0 && moviesList.currentIndex < movies.length && movies[moviesList.currentIndex]) ? String(movies[moviesList.currentIndex].Id || "") : ""
        var seriesId = (seriesList && series && seriesList.currentIndex >= 0 && seriesList.currentIndex < series.length && series[seriesList.currentIndex]) ? String(series[seriesList.currentIndex].Id || "") : ""
        var episodeId = (episodesList && episodes && episodesList.currentIndex >= 0 && episodesList.currentIndex < episodes.length && episodes[episodesList.currentIndex]) ? String(episodes[episodesList.currentIndex].Id || "") : ""
        var baseAnchorId = currentFocus === focusSeries ? seriesId : movieId
        if (!baseAnchorId.length) baseAnchorId = seriesId || movieId
        var state = {
            focus: currentFocus,
            movieIndex: moviesList ? (moviesList.currentIndex | 0) : 0,
            seriesIndex: seriesList ? (seriesList.currentIndex | 0) : 0,
            episodeIndex: episodesList ? (episodesList.currentIndex | 0) : 0,
            movieId: movieId,
            seriesId: seriesId,
            episodeId: episodeId,
            baseStart: _creditsPageStartForId("base", baseAnchorId),
            episodeStart: _creditsPageStartForId("episodes", episodeId),
            y: rootFlick ? Math.round(rootFlick.contentY || 0) : 0,
            ts: Date.now()
        }
        Jellyfin.putBoundedMemory(b, String(itemId), state, 48)
    }

    function _readFocusState(){
        var b = _personStateBucket()
        if (!b || !itemId) return null
        return b.hasOwnProperty(String(itemId)) ? b[String(itemId)] : null
    }
    function _clearFocusState(){
        var b = _personStateBucket()
        if (!b || !itemId) return
        var key = String(itemId)
        if (b.hasOwnProperty(key))
            delete b[key]
    }

    function _restoreSectionForFocus(f){
        if (f === focusMovies) return moviesSection
        if (f === focusSeries) return seriesSection
        if (f === focusEpisodes) return episodesSection
        return null
    }

    function _cancelPendingViewportRestore(){
        _restoreViewportPending = false
        _restoreViewportFocus = -1
        _restoreViewportY = 0
    }

    function _queueViewportRestore(savedY, focusCode){
        if (!rootFlick)
            return
        _restoreViewportY = Math.max(0, Number(savedY || 0))
        _restoreViewportFocus = Number(focusCode)
        _restoreViewportPending = true
        // Un passage après le polish QML suffit généralement. Si le layout des
        // rails n'est pas encore final, on laisse pending=true : contentHeight
        // relancera automatiquement la tentative, sans polling.
        Qt.callLater(_commitPendingViewportRestore)
    }

    function _commitPendingViewportRestore(){
        if (!_restoreViewportPending || !rootFlick)
            return false

        // Si l'utilisateur a déjà changé de section, ne jamais provoquer un
        // retour de scroll tardif vers l'ancien focus.
        if (currentFocus !== _restoreViewportFocus) {
            _cancelPendingViewportRestore()
            return false
        }

        var target = _restoreSectionForFocus(_restoreViewportFocus)
        if (!target || !target.visible || target.height <= 0)
            return false

        var maxY = Math.max(0, rootFlick.contentHeight - rootFlick.height)
        var wantedY = Math.max(0, Number(_restoreViewportY || 0))

        // Le bug observé se produit précisément ici : wantedY > 0 alors que le
        // layout provisoire annonce encore maxY=0. Ne surtout pas clampler à 0.
        if (wantedY > 0 && maxY <= 0)
            return false

        var restoreY = Math.max(0, Math.min(maxY, wantedY))
        rootFlick.scrollToY(restoreY, false)

        // Si la hauteur de page a légèrement changé depuis la sauvegarde,
        // garantir malgré tout que la section focalisée reste à l'écran.
        ensureItemVisible(target, 22)

        _cancelPendingViewportRestore()
        return true
    }

    function _restoreFocusState(){
        var st = _readFocusState()
        if (!st) {
            focusBiography()
            return
        }
        if (moviesList && moviesList.count > 0) {
            var mi = MediaCatalog.findItemIndexById(movies, st.movieId)
            moviesList.currentIndex = mi >= 0 ? mi : Math.max(0, Math.min(moviesList.count - 1, Number(st.movieIndex || 0) | 0))
        }
        if (seriesList && seriesList.count > 0) {
            var si = MediaCatalog.findItemIndexById(series, st.seriesId)
            seriesList.currentIndex = si >= 0 ? si : Math.max(0, Math.min(seriesList.count - 1, Number(st.seriesIndex || 0) | 0))
        }
        if (episodesList && episodesList.count > 0) {
            var ei = MediaCatalog.findItemIndexById(episodes, st.episodeId)
            episodesList.currentIndex = ei >= 0 ? ei : Math.max(0, Math.min(episodesList.count - 1, Number(st.episodeIndex || 0) | 0))
        }
        var f = Number(st.focus)
        var railFocusRestored = false
        if (f === focusMovies && movies.length) {
            focusMoviesRail()
            railFocusRestored = true
        } else if (f === focusSeries && series.length) {
            focusSeriesRail()
            railFocusRestored = true
        } else if (f === focusEpisodes && episodes.length) {
            focusEpisodesRail()
            railFocusRestored = true
        } else if (f === focusBio) {
            focusBiography()
        } else if (f === focusPortrait) {
            focusPortraitImage()
        } else {
            focusFavoriteButton()
        }

        if (railFocusRestored && rootFlick && typeof st.y === "number")
            _queueViewportRestore(st.y, f)
        else
            _cancelPendingViewportRestore()
    }

    function _personBirthDateIso(){
        if (!person) return ""
        return MediaCatalog.safeString(person.BirthDate || person.PremiereDate || "")
    }
    function _personDeathDateIso(){
        if (!person) return ""
        return MediaCatalog.safeString(person.DeathDate || person.EndDate || "")
    }

    readonly property string birthAgeLine: {
        var iso = _personBirthDateIso()
        if (!iso.length) return ""
        var d = MediaCatalog.personDateLongFr(iso)
        var a = MediaCatalog.personAgeFromDates(iso, _personDeathDateIso())
        if (!d) return ""
        return a >= 0 ? (d + " (" + a + " ans)") : d
    }
    readonly property string biographyText: MediaCatalog.plainOverview(
                                                person && person.Overview ? person.Overview : "")
    function hasBiography(){ return biographyText.length > 0 }
    function _personPrimaryUrl(it, options) {
        return MediaCatalog.primaryImageUrl(Jellyfin, serverUrl, it, options)
    }

    function personViewerUrl() {
        return _personPrimaryUrl(person, {
            maxWidth: 1280, maxHeight: 720, quality: 95, format: "jpg"
        })
    }

    function openBiography(){
        _cancelHudFocusPending()
        _saveFocusState()
        bioOverlayOpen = true
        Qt.callLater(function(){
            try { biographyOverlay.forceActiveFocus(Qt.OtherFocusReason) } catch(e) {}
        })
    }
    function closeBiography(){
        bioOverlayOpen = false
        Qt.callLater(function(){ focusBiography() })
    }

    function _resetPhotoViewer(){
        photoZoom = 1.0
        photoPanX = 0
        photoPanY = 0
    }
    function openPhotoViewer(){
        if (!personViewerUrl().length) return
        _cancelHudFocusPending()
        _saveFocusState()
        _resetPhotoViewer()
        photoViewerOpen = true
        Qt.callLater(function(){
            try { photoViewer.forceActiveFocus(Qt.OtherFocusReason) } catch(e) {}
        })
    }

    function closePhotoViewer(){
        photoViewerOpen = false
        _resetPhotoViewer()
        Qt.callLater(function(){ focusPortraitImage() })
    }
    function _adjustPhotoZoom(delta){
        var z = Math.max(photoZoomMin, Math.min(photoZoomMax, photoZoom + delta))
        photoZoom = z
        if (z <= photoZoomMin + 0.001) {
            photoPanX = 0
            photoPanY = 0
        }
    }

    function _panPhoto(dx, dy){
        if (photoZoom <= photoZoomMin + 0.001) return
        var mx = Math.max(0, Math.round(width * (photoZoom - 1) * 0.34))
        var my = Math.max(0, Math.round(height * (photoZoom - 1) * 0.34))
        photoPanX = Math.max(-mx, Math.min(mx, photoPanX + dx))
        photoPanY = Math.max(-my, Math.min(my, photoPanY + dy))
    }
    function personPortraitUrl() {
        return _personPrimaryUrl(person, {
            fillWidth: Math.round(portraitW * 1.35),
            fillHeight: Math.round(portraitH * 1.35),
            quality: 88, format: "jpg"
        })
    }

    function mediaPosterUrl(it) {
        return _personPrimaryUrl(it, {
            fillWidth: Math.round(mediaPosterW * 1.30),
            fillHeight: Math.round(mediaPosterH * 1.30),
            quality: 85, format: "jpg"
        })
    }
    function episodeThumbUrl(it) {
        return _personPrimaryUrl(it, {
            fillWidth: Math.round(episodeThumbW * 1.30),
            fillHeight: Math.round(episodeThumbH * 1.30),
            quality: 85, format: "jpg"
        })
    }

    function personPortraitHqUrl() {
        return _personPrimaryUrl(person, {
            fillWidth: Math.round(portraitW * portraitHqScale),
            fillHeight: Math.round(portraitH * portraitHqScale),
            quality: portraitHqQuality, format: "jpg"
        })
    }
    function mediaPosterHqUrl(it) {
        return _personPrimaryUrl(it, {
            fillWidth: Math.round(mediaPosterW * mediaPosterHqScale),
            fillHeight: Math.round(mediaPosterH * mediaPosterHqScale),
            quality: mediaPosterHqQuality, format: "jpg"
        })
    }
    function episodeThumbHqUrl(it) {
        return _personPrimaryUrl(it, {
            fillWidth: Math.round(episodeThumbW * episodeThumbHqScale),
            fillHeight: Math.round(episodeThumbH * episodeThumbHqScale),
            quality: episodeThumbHqQuality, format: "jpg"
        })
    }
    function _focusedHqCandidate(){
        if (modalOpen) return ({kind:"", id:""})
        if (currentFocus === focusPortrait && portraitFocus && portraitFocus.activeFocus && person && person.Id)
            return ({kind:"portrait", id:String(person.Id)})
        if (currentFocus === focusMovies && moviesList && moviesList.activeFocus && movies && moviesList.currentIndex >= 0 && moviesList.currentIndex < movies.length) {
            var m = movies[moviesList.currentIndex]
            return ({kind:"media", id:(m && m.Id) ? String(m.Id) : ""})
        }
        if (currentFocus === focusSeries && seriesList && seriesList.activeFocus && series && seriesList.currentIndex >= 0 && seriesList.currentIndex < series.length) {
            var s = series[seriesList.currentIndex]
            return ({kind:"media", id:(s && s.Id) ? String(s.Id) : ""})
        }
        if (currentFocus === focusEpisodes && episodesList && episodesList.activeFocus && episodes && episodesList.currentIndex >= 0 && episodesList.currentIndex < episodes.length) {
            var e = episodes[episodesList.currentIndex]
            return ({kind:"episode", id:(e && e.Id) ? String(e.Id) : ""})
        }
        return ({kind:"", id:""})
    }
    function _scheduleHq(kind, id){
        kind = kind ? String(kind) : ""
        id = id ? String(id) : ""
        hqTargetKind = ""
        hqTargetId = ""
        _hqPendingKind = kind
        _hqPendingId = id
        hqPromotionTimer.stop()
        if (kind.length && id.length)
            hqPromotionTimer.restart()
    }
    Timer {
        id: hqPromotionTimer
        interval: 300
        repeat: false
        onTriggered: {
            var c = personPage._focusedHqCandidate()
            if (c.kind === personPage._hqPendingKind && c.id === personPage._hqPendingId
                    && c.kind.length && c.id.length) {
                personPage.hqTargetKind = c.kind
                personPage.hqTargetId = c.id
            }
        }
    }

    property bool _creditsBaseDone: false
    property bool _creditsEpisodesDone: false
    function _maybeFinishCredits(){
        if (!_creditsBaseDone) return
        if (!_creditsEpisodesDone) return
        creditsLoading = false
        creditsLoaded = true
        Qt.callLater(_restoreFocusState)
    }

    function _creditsPages(branch){ return branch === "episodes" ? (_creditsEpisodePages || []) : (_creditsBasePages || []) }
    function _creditsHandle(branch){ return branch === "episodes" ? _creditsEpisodeHandle : _creditsBaseHandle }
    function _creditsAttempt(branch){ return branch === "episodes" ? _creditsEpisodeAttempt : _creditsBaseAttempt }
    function _creditsDeadline(branch){ return branch === "episodes" ? _creditsEpisodeDeadlineAt : _creditsBaseDeadlineAt }
    function _setCreditsDeadline(branch, value){ if (branch === "episodes") _creditsEpisodeDeadlineAt = value; else _creditsBaseDeadlineAt = value }
    function _setCreditsHandle(branch, value){ if (branch === "episodes") _creditsEpisodeHandle = value; else _creditsBaseHandle = value }
    function _setCreditsLoadingMore(branch, value){ if (branch === "episodes") _creditsEpisodeLoadingMore = value; else _creditsBaseLoadingMore = value }
    function _creditsWindowStart(branch){
        return MediaCatalog.catalogPageWindowStart(_creditsPages(branch))
    }
    function _creditsPageStartForId(branch, id){
        return MediaCatalog.catalogPageStartForItemId(_creditsPages(branch), id)
    }
    function _creditsWindowEnd(branch){
        return MediaCatalog.catalogPageWindowEnd(_creditsPages(branch))
    }
    function _cancelCreditsRequest(branch){
        var h = _creditsHandle(branch)
        _setCreditsHandle(branch, null)
        _setCreditsLoadingMore(branch, false)
        if (branch === "episodes") ++_creditsEpisodeAttempt; else ++_creditsBaseAttempt
        try { if (h && h.cancel) h.cancel("context_changed") } catch(e) {}
    }
    function _cancelAllCreditsRequests(){ _cancelCreditsRequest("base"); _cancelCreditsRequest("episodes") }
    function _creditsSelectedId(list, data){
        var idx = list ? (list.currentIndex | 0) : -1
        return data && idx >= 0 && idx < data.length && data[idx] ? String(data[idx].Id || "") : ""
    }
    function _rebuildCredits(branch){
        var oldMovieId = _creditsSelectedId(moviesList, movies)
        var oldSeriesId = _creditsSelectedId(seriesList, series)
        var oldEpisodeId = _creditsSelectedId(episodesList, episodes)
        var buckets = MediaCatalog.personCreditBuckets(_creditsPages(branch))
        // Films/séries suivent SortName côté serveur. Les épisodes conservent l'ordre historique Série/Saison/Épisode à chaque continuation (jamais au focus).
        if (branch === "episodes") episodes = buckets.episodes
        else { movies = buckets.movies; series = buckets.series }
        Qt.callLater(function(){
            var mi = MediaCatalog.findItemIndexById(movies, oldMovieId), si = MediaCatalog.findItemIndexById(series, oldSeriesId), ei = MediaCatalog.findItemIndexById(episodes, oldEpisodeId)
            if (mi >= 0 && moviesList) moviesList.currentIndex = mi
            if (si >= 0 && seriesList) seriesList.currentIndex = si
            if (ei >= 0 && episodesList) episodesList.currentIndex = ei
        })
    }
    function _appendCreditsPage(branch, arr, start, limit, direction){
        var state = MediaCatalog.appendCatalogPageWindow(
                    _creditsPages(branch), arr, start, limit, direction, creditsWindowMaxItems)
        if (branch === "episodes") {
            _creditsEpisodePages = state.pages
            creditsEpisodeHasMoreBefore = state.hasMoreBefore
            creditsEpisodeHasMoreAfter = state.hasMoreAfter
        } else {
            _creditsBasePages = state.pages
            creditsBaseHasMoreBefore = state.hasMoreBefore
            creditsBaseHasMoreAfter = state.hasMoreAfter
        }
        _rebuildCredits(branch)
    }
    function _creditsPageContains(arr, railKind){
        return MediaCatalog.personCreditsPageContains(arr, railKind)
    }
    function _finishCreditsInitialBranch(branch){
        if (branch === "episodes") _creditsEpisodesDone = true
        else _creditsBaseDone = true
        _maybeFinishCredits()
    }
    function _fetchPersonItemsPage(seq, branch, includeTypes, start, limit, direction, railKind, autoPages, initial){
        if (seq !== _fetchSeq) return
        var deadlineAt = _creditsDeadline(branch)
        if (!deadlineAt) { deadlineAt = Date.now() + 14000; _setCreditsDeadline(branch, deadlineAt) }
        if (Date.now() >= deadlineAt) {
            _setCreditsLoadingMore(branch, false)
            if (initial) _finishCreditsInitialBranch(branch)
            return null
        }
        direction = direction === "backward" ? "backward" : "forward"
        limit = Math.max(40, (limit || creditsPageSize) | 0)
        start = Math.max(0, start | 0)
        autoPages = Math.max(0, autoPages | 0)
        _cancelCreditsRequest(branch)
        var attempt = branch === "episodes" ? ++_creditsEpisodeAttempt : ++_creditsBaseAttempt
        _setCreditsLoadingMore(branch, !initial)
        var handle = Jellyfin.fetchPersonItemsPage(
            serverUrl, accessToken, userId, itemId, includeTypes, start, limit, deadlineAt,
            function(arr){
                if (seq !== _fetchSeq || attempt !== _creditsAttempt(branch)) return
                if (_creditsHandle(branch) === handle) _setCreditsHandle(branch, null)
                _setCreditsLoadingMore(branch, false)
                arr = arr || []
                if (initial && start > 0 && arr.length === 0) {
                    Qt.callLater(function(){ _fetchPersonItemsPage(seq, branch, includeTypes, 0, limit, "forward", "", 0, true) })
                    return
                }
                _appendCreditsPage(branch, arr, start, limit, direction)
                var full = arr.length >= limit
                var canContinue = !_creditsPageContains(arr, railKind) && autoPages < 3 &&
                                  ((direction === "forward" && full) || (direction === "backward" && start > 0))
                if (canContinue) {
                    var next = direction === "backward" ? Math.max(0, start - limit) : start + arr.length
                    Qt.callLater(function(){ _fetchPersonItemsPage(seq, branch, includeTypes, next, limit, direction, railKind, autoPages + 1, false) })
                    return
                }
                if (initial) _finishCreditsInitialBranch(branch)
            },
            function(err){
                if (seq !== _fetchSeq || attempt !== _creditsAttempt(branch)) return
                if (_creditsHandle(branch) === handle) _setCreditsHandle(branch, null)
                _setCreditsLoadingMore(branch, false)
                if (initial) _finishCreditsInitialBranch(branch)
            }
        )
        _setCreditsHandle(branch, handle)
        return handle
    }
    function _requestCreditsWindow(branch, direction, railKind){
        if (_creditsHandle(branch)) return false
        var pages = _creditsPages(branch)
        if (!pages.length) return false
        var before = branch === "episodes" ? creditsEpisodeHasMoreBefore : creditsBaseHasMoreBefore
        var after = branch === "episodes" ? creditsEpisodeHasMoreAfter : creditsBaseHasMoreAfter
        var limit = Math.max(40, creditsPageSize | 0), start = 0
        if (direction === "backward") {
            if (!before) return false
            var first = _creditsWindowStart(branch)
            start = Math.max(0, first - limit)
            limit = Math.max(40, first - start)
        } else {
            if (!after) return false
            start = _creditsWindowEnd(branch)
        }
        _setCreditsDeadline(branch, Date.now() + 14000)
        _fetchPersonItemsPage(_fetchSeq, branch, branch === "episodes" ? "Episode" : "Movie,Series",
                              start, limit, direction, railKind, 0, false)
        return true
    }
    function _maybeRequestCreditsMore(railKind, index, count){
        if (index < 0 || count <= 0) return
        var branch = railKind === "episodes" ? "episodes" : "base"
        var before = branch === "episodes" ? creditsEpisodeHasMoreBefore : creditsBaseHasMoreBefore
        var after = branch === "episodes" ? creditsEpisodeHasMoreAfter : creditsBaseHasMoreAfter
        if (before && index <= 1) { _requestCreditsWindow(branch, "backward", railKind); return }
        if (after && index >= Math.max(0, count - creditsPrefetchThreshold))
            _requestCreditsWindow(branch, "forward", railKind)
    }
    function fetchCredits(seq){
        _cancelAllCreditsRequests()
        creditsLoading = true
        creditsLoaded = false
        _creditsBaseDone = false
        _creditsEpisodesDone = false
        _creditsBasePages = []; _creditsEpisodePages = []
        creditsBaseHasMoreBefore = false; creditsBaseHasMoreAfter = false
        creditsEpisodeHasMoreBefore = false; creditsEpisodeHasMoreAfter = false
        movies = []; series = []; episodes = []
        var state = _readFocusState() || ({})
        var baseStart = Math.max(0, Number(state.baseStart || 0) | 0)
        var episodeStart = Math.max(0, Number(state.episodeStart || 0) | 0)
        _creditsBaseDeadlineAt = Date.now() + 14000
        _creditsEpisodeDeadlineAt = Date.now() + 14000
        _fetchPersonItemsPage(seq, "base", "Movie,Series", baseStart, creditsPageSize, "forward", "", 0, true)
        _fetchPersonItemsPage(seq, "episodes", "Episode", episodeStart, creditsPageSize, "forward", "", 0, true)
    }
    function _applyPerson(p){
        person = p || null
        favorite = !!(person && person.UserData && person.UserData.IsFavorite)
        if (favoriteBtn && favoriteBtn.checked !== favorite)
            favoriteBtn.checked = favorite
        personLoading = false
        loadingError = person ? "" : "Informations de la personne indisponibles."
        Qt.callLater(function(){
            if (personPage.activeFocus)
                _restoreFocusState()
        })
    }

    function _cancelPersonBioRetry(){
        _personBioRetrySeq = 0
        _personBioRetryItemId = ""
        _personBioRetryInFlight = false
        personBioRetryTimer.stop()
    }
    function _finishPersonMetadataWait(){
        personMetadataPending = false
        _cancelPersonBioRetry()
    }

    function _schedulePersonBioRetry(seq){
        if (seq !== _fetchSeq || !itemId) return
        if (!MediaCatalog.personMetadataNeedsRefresh(person)) {
            personMetadataPending = false
            return
        }
        // Important : activer le loader AVANT que _applyPerson() puisse désactiver personLoading, sinon on obtient un flash de la page partielle entre les deux phases de chargement.
        personMetadataPending = true
        _personBioRetrySeq = seq
        _personBioRetryItemId = String(itemId)
        _personBioRetryInFlight = false
        personBioRetryTimer.restart()
    }
    function _runPersonBioRetry(){
        var seq = _personBioRetrySeq
        var retryItemId = _personBioRetryItemId
        if (!seq || seq !== _fetchSeq || !retryItemId
                || retryItemId !== String(itemId)
                || !MediaCatalog.personMetadataNeedsRefresh(person)
                || !serverUrl || !accessToken || !userId) {
            _finishPersonMetadataWait()
            return
        }
        _personBioRetryInFlight = true
        // Le cache user-scoped du bridge expire après 2,5 s. Le retry est volontairement déclenché à 2,7 s pour éviter de relire le DTO vide.
        Jellyfin.fetchUserItem(serverUrl, accessToken, userId, retryItemId,
            function(scoped){
                if (seq !== _fetchSeq || retryItemId !== String(itemId)) {
                    _finishPersonMetadataWait()
                    return
                }
                var currentPerson = person
                var scopedMerged = MediaCatalog.mergePersonMetadata(scoped, currentPerson)
                if (!MediaCatalog.personMetadataNeedsRefresh(scopedMerged)) {
                    _finishPersonMetadataWait()
                    _applyPerson(scopedMerged)
                    return
                }
                // Dernière chance via la fiche générique, sans boucle.
                Jellyfin.fetchPerson(serverUrl, accessToken, retryItemId,
                    function(rich){
                        if (seq !== _fetchSeq || retryItemId !== String(itemId)) {
                            _finishPersonMetadataWait()
                            return
                        }
                        var previous = person
                        var merged = MediaCatalog.mergePersonMetadata(rich, scoped || previous)
                        _finishPersonMetadataWait()
                        if ((MediaCatalog.personOverviewPresent(merged) && !MediaCatalog.personOverviewPresent(previous))
                                || (MediaCatalog.personBirthDatePresent(merged) && !MediaCatalog.personBirthDatePresent(previous))
                                || !MediaCatalog.personMetadataNeedsRefresh(merged))
                            _applyPerson(merged)
                    },
                    function(){
                        _finishPersonMetadataWait()
                    }
                )
            },
            function(){
                if (seq !== _fetchSeq || retryItemId !== String(itemId)) {
                    _finishPersonMetadataWait()
                    return
                }
                Jellyfin.fetchPerson(serverUrl, accessToken, retryItemId,
                    function(rich){
                        if (seq !== _fetchSeq || retryItemId !== String(itemId)) {
                            _finishPersonMetadataWait()
                            return
                        }
                        var previous = person
                        var merged = MediaCatalog.mergePersonMetadata(rich, previous)
                        _finishPersonMetadataWait()
                        if ((MediaCatalog.personOverviewPresent(merged) && !MediaCatalog.personOverviewPresent(previous))
                                || (MediaCatalog.personBirthDatePresent(merged) && !MediaCatalog.personBirthDatePresent(previous))
                                || !MediaCatalog.personMetadataNeedsRefresh(merged))
                            _applyPerson(merged)
                    },
                    function(){
                        _finishPersonMetadataWait()
                    }
                )
            }
        )
    }
    Timer {
        id: personBioRetryTimer
        interval: 2700
        repeat: false
        onTriggered: personPage._runPersonBioRetry()
    }

    function fetchPerson(seq){
        personLoading = true
        loadingError = ""
        if (Jellyfin.fetchUserItem && userId) {
            Jellyfin.fetchUserItem(serverUrl, accessToken, userId, itemId,
                function(p){
                    if (seq !== _fetchSeq) return
                    // Jellyfin peut renvoyer au premier accès un DTO user-scoped partiel : Overview peut être présent sans PremiereDate, ou l'inverse. La fiche n'est considérée complète que lorsque bio ET date de naissance sont disponibles.
                    if (!MediaCatalog.personMetadataNeedsRefresh(p)) {
                        personMetadataPending = false
                        _applyPerson(p)
                        return
                    }
                    // Un seul enrichissement immédiat si une métadonnée manque. fetchPerson() interroge /Items/{id} sans le cache user-scoped.
                    Jellyfin.fetchPerson(serverUrl, accessToken, itemId,
                        function(p2){
                            if (seq !== _fetchSeq) return
                            var merged = MediaCatalog.mergePersonMetadata(p2, p)
                            var needsRetry = MediaCatalog.personMetadataNeedsRefresh(merged)
                            if (needsRetry) {
                                // person n'est pas encore affecté à merged : activer explicitement l'attente avant apply.
                                personMetadataPending = true
                            }
                            _applyPerson(merged)
                            if (needsRetry)
                                _schedulePersonBioRetry(seq)
                        },
                        function(){
                            if (seq !== _fetchSeq) return
                            // Le DTO initial reste exploitable si l'enrichissement échoue. Le retry différé donnera une dernière chance au serveur sans bloquer l'affichage de PersonPage.
                            var needsRetry = MediaCatalog.personMetadataNeedsRefresh(p)
                            if (needsRetry)
                                personMetadataPending = true
                            _applyPerson(p)
                            if (needsRetry)
                                _schedulePersonBioRetry(seq)
                        }
                    )
                },
                function(){
                    if (seq !== _fetchSeq) return
                    Jellyfin.fetchPerson(serverUrl, accessToken, itemId,
                        function(p2){
                            if (seq !== _fetchSeq) return
                            var needsRetry = MediaCatalog.personMetadataNeedsRefresh(p2)
                            if (needsRetry)
                                personMetadataPending = true
                            _applyPerson(p2)
                            if (needsRetry)
                                _schedulePersonBioRetry(seq)
                        },
                        function(){
                            if (seq === _fetchSeq) {
                                personMetadataPending = false
                                _applyPerson(null)
                            }
                        }
                    )
                }
            )
        } else {
            Jellyfin.fetchPerson(serverUrl, accessToken, itemId,
                function(p){
                    if (seq !== _fetchSeq) return
                    var needsRetry = MediaCatalog.personMetadataNeedsRefresh(p)
                    if (needsRetry)
                        personMetadataPending = true
                    _applyPerson(p)
                    if (needsRetry)
                        _schedulePersonBioRetry(seq)
                },
                function(){
                    if (seq === _fetchSeq) {
                        personMetadataPending = false
                        _applyPerson(null)
                    }
                }
            )
        }
    }

    function fetchAll(){
        _hydrateSensitiveContextFromShared()
        if (!serverUrl || !accessToken || !userId || !itemId) return
        personMetadataPending = false
        _cancelPersonBioRetry()
        var seq = ++_fetchSeq
        person = null
        movies = []
        series = []
        episodes = []
        favorite = false
        favoriteBusy = false
        fetchPerson(seq)
        fetchCredits(seq)
    }
    function setPersonFavorite(next){
        next = !!next
        if (favoriteBusy || !itemId || !userId) {
            if (favoriteBtn) favoriteBtn.checked = favorite
            return
        }
        var previous = favorite
        favorite = next
        favoriteBusy = true
        Jellyfin.setFavorite(serverUrl, accessToken, userId, itemId, next,
            function(){
                favoriteBusy = false
                favorite = next
                if (person) {
                    var ud = person.UserData || ({})
                    ud.IsFavorite = next
                    person.UserData = ud
                }
                if (favoriteBtn && favoriteBtn.checked !== next)
                    favoriteBtn.checked = next
            },
            function(){
                favoriteBusy = false
                favorite = previous
                if (favoriteBtn && favoriteBtn.checked !== previous)
                    favoriteBtn.checked = previous
            }
        )
    }

    onFavoriteChanged: {
        if (favoriteBtn && favoriteBtn.checked !== favorite)
            favoriteBtn.checked = favorite
    }
    function _openMedia(it){
        if (!it || !it.Id || typeof requestNavigation !== "function") return
        _cancelPendingViewportRestore()
        _saveFocusState()
        var t = MediaCatalog.safeString(it.Type).toLowerCase()
        var page = (t === "series") ? "detailSeriePage.qml" : "detailMoviePage.qml"
        requestNavigation(_navRoute(page, { itemId: it.Id }))
    }

    function _openEpisode(ep){
        if (!ep || !ep.Id || typeof requestNavigation !== "function") return
        _cancelPendingViewportRestore()
        _saveFocusState()
        var seasonId = MediaCatalog.safeString(ep.ParentId || ep.SeasonId || "")
        var seriesId = MediaCatalog.safeString(ep.SeriesId || "")
        if (seasonId.length && seriesId.length) {
            // Navigation volontaire vers un épisode depuis PersonPage : le snapshot de retour vers GuestPage ne doit pas reprendre le focus après que seasonpage a appliqué preselectEpisodeId.
            try {
                if (shared && shared.__redefinSeasonGuestReturn)
                    shared.__redefinSeasonGuestReturn = null
            } catch(eGuestReturn) {}
            requestNavigation(_navRoute("seasonpage.qml", {
                seasonId: seasonId,
                seriesId: seriesId,
                preselectEpisodeId: ep.Id
            }))
            return
        }
        // Fallback défensif si un serveur ne renvoie pas ParentId sur le DTO Episode.
        if (seriesId.length) {
            requestNavigation(_navRoute("detailSeriePage.qml", { itemId: seriesId }))
        }
    }
    function _goBack(){
        // Quitter volontairement PersonPage termine cette visite de la personne.
        // Bloquer D'ABORD toute nouvelle sauvegarde : pendant le changement de source
        // du Loader, les ListView/focus peuvent encore émettre des signaux et rappeler
        // _saveFocusState(). Sans ce verrou, le snapshot effacé ci-dessous pouvait être
        // recréé pendant le teardown et réapparaître à la prochaine ouverture du même acteur.
        _focusStateSaveBlocked = true
        _clearFocusState()
        // IMPORTANT : marker posé AVANT requestBackToMenu(). Si la fiche détail doit être recréée, son Component.onCompleted verra déjà le gate.
        _markDetailReturnBeforeBack()
        _storeSensitiveNavContext()
        if (typeof requestBackToMenu === "function")
            requestBackToMenu()
    }

    function gotoSelectProfile(){
        _saveFocusState()
        _storeSensitiveNavContext()
        if (typeof requestNavigation === "function")
            requestNavigation("LoginPage.qml?ctx=1")
    }
    function ensureItemVisible(target, margin){
        if (!target || !rootFlick) return
        var m = margin === undefined ? 24 : margin
        var p = target.mapToItem(rootFlick.contentItem, 0, 0)
        var top = p.y - m
        var bot = p.y + target.height + m
        var viewTop = rootFlick.contentY
        var viewBot = viewTop + rootFlick.height
        var maxY = Math.max(0, rootFlick.contentHeight - rootFlick.height)
        if (top < viewTop) rootFlick.scrollToY(Math.max(0, top), true)
        else if (bot > viewBot) rootFlick.scrollToY(Math.max(0, Math.min(maxY, bot - rootFlick.height)), true)
    }

    function _cancelHudFocusPending(){
        _hudFocusPending = false
        _hudFocusRetryLeft = 0
        try { hudFocusRetryTimer.stop() } catch(e) {}
    }
    function _forceFocusStable(target, expectedFocus){
        if (!target) return false
        // Prise de focus synchrone pour que la touche suivante soit déjà traitée par la nouvelle section, même pendant un scroll rapide.
        try { target.forceActiveFocus(Qt.OtherFocusReason) }
        catch(e0) {
            try { target.forceActiveFocus() } catch(e1) {}
        }
        // Retry unique pour absorber un éventuel cycle de layout/reuseItems.
        Qt.callLater(function(){
            if (personPage.modalOpen
                    || personPage.currentFocus !== expectedFocus
                    || !target)
                return
            try { target.forceActiveFocus(Qt.OtherFocusReason) }
            catch(e2) {
                try { target.forceActiveFocus() } catch(e3) {}
            }
        })
        return true
    }

    function _tryCommitHudFocus(){
        if (!_hudFocusPending || modalOpen || personLoading)
            return false
        // ClockHUD est caché tant que hudScrollOpacity est trop faible. Ne jamais abandonner le focus courant avant qu'il soit focalisable.
        if (!clockHud || !clockHud.visible || !clockHud.active)
            return false
        _hudFocusPending = false
        _hudFocusRetryLeft = 0
        currentFocus = focusHud
        try {
            if (clockHud.focusAvatar)
                clockHud.focusAvatar()
            else
                clockHud.forceActiveFocus(Qt.OtherFocusReason)
        } catch(e0) {
            try { clockHud.forceActiveFocus() } catch(e1) {}
        }
        return true
    }
    Timer {
        id: hudFocusRetryTimer
        interval: 24
        repeat: true
        running: false
        onTriggered: {
            if (!personPage._hudFocusPending
                    || personPage.modalOpen
                    || personPage.personLoading) {
                stop()
                personPage._hudFocusPending = false
                personPage._hudFocusRetryLeft = 0
                return
            }
            if (personPage._tryCommitHudFocus()) {
                stop()
                return
            }
            personPage._hudFocusRetryLeft--
            if (personPage._hudFocusRetryLeft <= 0) {
                stop()
                // Garde-fou CE4100 : si le scroll animé a pris du retard, terminer le retour en haut sans animation.
                if (rootFlick)
                    rootFlick.scrollToY(0, false)
                Qt.callLater(function(){
                    if (!personPage._hudFocusPending)
                        return
                    if (!personPage._tryCommitHudFocus()) {
                        // Jamais de currentFocus pointant vers un HUD caché.
                        personPage._hudFocusPending = false
                        personPage.currentFocus = personPage.focusBio
                        personPage._forceFocusStable(
                                    bioBox,
                                    personPage.focusBio)
                    }
                })
            }
        }
    }

    function focusBiography(){
        _cancelHudFocusPending()
        currentFocus = focusBio
        if (rootFlick) rootFlick.scrollToY(0, true)
        _forceFocusStable(bioBox, focusBio)
    }
    function focusFavoriteButton(){
        _cancelHudFocusPending()
        currentFocus = focusFavorite
        if (rootFlick) rootFlick.scrollToY(0, true)
        _forceFocusStable(favoriteBtn, focusFavorite)
    }

    function focusPortraitImage(){
        _cancelHudFocusPending()
        currentFocus = focusPortrait
        if (rootFlick) rootFlick.scrollToY(0, true)
        _forceFocusStable(portraitFocus, focusPortrait)
    }
    function focusMoviesRail(){
        if (!movies || !movies.length) {
            if (series && series.length) focusSeriesRail()
            else if (episodes && episodes.length) focusEpisodesRail()
            else _focusTopArea()
            return
        }
        _cancelHudFocusPending()
        currentFocus = focusMovies
        ensureItemVisible(moviesSection, 22)
        _forceFocusStable(moviesList, focusMovies)
    }

    function focusSeriesRail(){
        if (!series || !series.length) {
            if (episodes && episodes.length) focusEpisodesRail()
            else if (movies && movies.length) focusMoviesRail()
            else _focusTopArea()
            return
        }
        _cancelHudFocusPending()
        currentFocus = focusSeries
        ensureItemVisible(seriesSection, 22)
        _forceFocusStable(seriesList, focusSeries)
    }
    function focusEpisodesRail(){
        if (!episodes || !episodes.length) {
            if (series && series.length) focusSeriesRail()
            else if (movies && movies.length) focusMoviesRail()
            else _focusTopArea()
            return
        }
        _cancelHudFocusPending()
        currentFocus = focusEpisodes
        ensureItemVisible(episodesSection, 22)
        _forceFocusStable(episodesList, focusEpisodes)
    }

    function focusHudAvatar(){
        if (modalOpen || personLoading)
            return false
        // Ne pas basculer currentFocus vers le HUD tant qu'il est caché. Le contrôle courant continue donc à recevoir le D-Pad pendant la remontée.
        _hudFocusPending = true
        _hudFocusRetryLeft = 28
        if (rootFlick)
            rootFlick.scrollToY(0, true)
        if (_tryCommitHudFocus())
            return true
        hudFocusRetryTimer.restart()
        return true
    }
    function _focusTopArea(){
        focusBiography()
    }

    function _firstRail(){
        if (movies && movies.length) focusMoviesRail()
        else if (series && series.length) focusSeriesRail()
        else if (episodes && episodes.length) focusEpisodesRail()
        else _focusTopArea()
    }
    Component.onCompleted: {
        _hydrateSensitiveContextFromShared()
        fetchAll()
    }
    onSharedChanged: if (_hydrateSensitiveContextFromShared()) fetchAll()
    onAccessTokenChanged: if (accessToken && userId && serverUrl && itemId) fetchAll()
    onUserIdChanged: if (accessToken && userId && serverUrl && itemId) fetchAll()
    onServerUrlChanged: if (accessToken && userId && serverUrl && itemId) fetchAll()
    onItemIdChanged: if (accessToken && userId && serverUrl && itemId) fetchAll()
    onPersonSourceChanged: {
        if (accessToken && userId && serverUrl && itemId)
            fetchAll()
    }

    Rectangle { anchors.fill: parent; color: "#0b0b0e"; z: -10 }

    Components.ClockHUD {
        id: clockHud
        z: 50
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 20 - Math.round((1.0 - hudScrollOpacity) * 8)
        anchors.rightMargin: 24
        fbx: personPage.fbx
        serverUrl: personPage.serverUrl
        userId: personPage.userId
        userImageTag: personPage.userImageTag
        userName: personPage.userName
        showAvatar: true
        avatarSize: 52
        fontPx: 22
        opacity: hudScrollOpacity
        active: !personLoading && !modalOpen && hudScrollOpacity > 0.08
        visible: !personLoading && !modalOpen && hudScrollOpacity > 0.01
        focus: currentFocus === focusHud
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        Behavior on anchors.topMargin { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    }
    Connections {
        target: clockHud
        ignoreUnknownSignals: true
        onRequestFocusBelow: _focusTopArea()
        onRequestOpenProfile: gotoSelectProfile()
        onAvatarActivated: gotoSelectProfile()
        onActivated: gotoSelectProfile()
    }

    Flickable {
        id: rootFlick
        anchors.fill: parent
        clip: true
        interactive: !personLoading && !modalOpen
        contentWidth: width
        contentHeight: pageColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        property bool progScroll: false

        onContentHeightChanged: {
            if (personPage._restoreViewportPending)
                Qt.callLater(personPage._commitPendingViewportRestore)
        }
        onHeightChanged: {
            if (personPage._restoreViewportPending)
                Qt.callLater(personPage._commitPendingViewportRestore)
        }
        function _maxY(){ return Math.max(0, contentHeight - height) }
        function _clampY(y){
            var v = Number(y || 0), maxY = _maxY()
            return Math.max(0, Math.min(maxY, v))
        }
        function scrollToY(y, smooth){
            var ty = _clampY(y)
            if (!smooth) { verticalScrollAnim.stop(); contentY = ty; return }
            if (dragging) { contentY = ty; return }
            try { if (cancelFlick) cancelFlick() } catch(e) {}
            progScroll = true
            verticalScrollAnim.stop()
            var dist = Math.abs(Number(contentY) - Number(ty))
            verticalScrollAnim.duration = Math.round(Math.max(180, Math.min(520, 140 + dist * 0.14)))
            verticalScrollAnim.to = ty
            verticalScrollAnim.restart()
        }
        NumberAnimation {
            id: verticalScrollAnim
            target: rootFlick
            property: "contentY"
            duration: 240
            easing.type: Easing.OutCubic
            onRunningChanged: if (!running) rootFlick.progScroll = false
        }
        Column {
            id: pageColumn
            width: rootFlick.width
            // Espace vertical resserré entre Films / Séries TV / Épisodes. Les hauteurs internes des rails restent inchangées afin de ne pas perturber le zoom, le focus D-Pad ni le clipping des posters.
            spacing: 10
            anchors.top: parent.top
            anchors.topMargin: topGap
            Item {
                id: hero
                width: parent.width
                height: Math.max(heroLeft.implicitHeight, portraitTopShiftY + portraitFocus.height) + 14
                Column {
                    id: heroLeft
                    x: marginL
                    width: Math.max(420, hero.width - marginL - marginR - portraitW - 78)
                    spacing: 11
                    Text {
                        width: parent.width
                        text: person && person.Name ? person.Name : ""
                        color: "#FFFFFF"
                        font.pixelSize: 40
                        font.bold: false
                        wrapMode: Text.WordWrap
                        textFormat: Text.PlainText
                    }
                    Text {
                        id: birthAgeText
                        width: parent.width
                        height: visible ? Math.max(26, implicitHeight) : 0
                        visible: text.length > 0
                        text: birthAgeLine
                        color: "#FFFFFF"
                        font.pixelSize: 20
                        font.bold: true
                        wrapMode: Text.WordWrap
                        verticalAlignment: Text.AlignVCenter
                        textFormat: Text.PlainText
                    }
                    FocusScope {
                        id: bioBox
                        width: parent.width
                        // Slot vertical volontairement stable : le bouton Favori reste exactement au même Y avec ou sans biographie. bioMaxLines=7 tient entièrement dans bioMinH+18 = 208 px.
                        height: bioMinH + 18
                        visible: true
                        enabled: true
                        opacity: 1.0
                        focus: currentFocus === focusBio
                        property bool focused: activeFocus || currentFocus === focusBio
                        scale: focused ? 1.012 : 1.0
                        transformOrigin: Item.Center
                        Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                        Rectangle {
                            anchors.fill: parent
                            radius: 12
                            color: bioBox.focused ? glassFocus : "transparent"
                            border.width: bioBox.focused ? 1 : 0
                            border.color: bioBox.focused ? glassBorder : "transparent"
                            antialiasing: bioBox.focused
                        }
                        Text {
                            id: bioText
                            anchors.fill: parent
                            anchors.margins: 12
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            text: personPage.hasBiography()
                                  ? personPage.biographyText
                                  : "Aucune biographie pour cette personne"
                            color: personPage.hasBiography() ? "#E3E5EC" : "#AEB4C2"
                            font.pixelSize: 19
                            lineHeightMode: Text.ProportionalHeight
                            lineHeight: 1.14
                            wrapMode: Text.WordWrap
                            elide: Text.ElideRight
                            maximumLineCount: bioMaxLines
                            verticalAlignment: Text.AlignTop
                            textFormat: Text.PlainText
                        }
                        Keys.onPressed: {
                            if (event.key === Qt.Key_Right) {
                                personPage.focusPortraitImage()
                                event.accepted = true
                            } else if (event.key === Qt.Key_Up) {
                                personPage.focusHudAvatar()
                                event.accepted = true
                            } else if (event.key === Qt.Key_Down) {
                                personPage.focusFavoriteButton()
                                event.accepted = true
                            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                                personPage.openBiography()
                                event.accepted = true
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: false
                            enabled: true
                            onClicked: {
                                personPage.currentFocus = personPage.focusBio
                                bioBox.forceActiveFocus()
                                personPage.openBiography()
                            }
                        }
                    }
                    Item {
                        width: parent.width
                        height: 90
                        Components.GlassCircleButton {
                            id: favoriteBtn
                            anchors.left: parent.left
                            anchors.top: parent.top
                            size: 58
                            // GlassCircleButton applique _stackScale=1.06 au focus. On contre uniquement ce grossissement sur ce bouton. Le shrink d'appui (_stackScale=0.96) reste intact.
                            scale: (activeFocus && _stackScale > 1.0)
                                   ? (1.0 / _stackScale)
                                   : 1.0
                            transformOrigin: Item.Center
                            actionType: "toggleLike"
                            checkable: true
                            tintColor: "#E6FFFFFF"
                            tintColorChecked: "#FF3B30"
                            focusRingColor: "#FFFFFF"
                            showLabel: true
                            labelText: "Favori"
                            labelTextChecked: "Favori"
                            hintText: "Ajouter aux favoris"
                            hintTextChecked: "Retirer des favoris"
                            hintMode: "none"
                            disabled: favoriteBusy || !person
                            getState: function(){ return personPage.favorite }
                            setState: function(v){ personPage.setPersonFavorite(v) }
                            Keys.onPressed: {
                                if (event.key === Qt.Key_Up) {
                                    personPage.focusBiography()
                                    event.accepted = true
                                } else if (event.key === Qt.Key_Right) {
                                    personPage.focusPortraitImage()
                                    event.accepted = true
                                } else if (event.key === Qt.Key_Down) {
                                    personPage._firstRail()
                                    event.accepted = true
                                }
                            }
                            onActiveFocusChanged: if (activeFocus) personPage.currentFocus = personPage.focusFavorite
                        }
                    }
                }
                FocusScope {
                    id: portraitFocus
                    width: portraitW
                    height: portraitH
                    anchors.right: parent.right
                    anchors.rightMargin: marginR + 18
                    anchors.top: parent.top
                    anchors.topMargin: portraitTopShiftY
                    focus: currentFocus === focusPortrait
                    property bool focused: activeFocus || currentFocus === focusPortrait
                    onActiveFocusChanged: {
                        if (activeFocus && person && person.Id) personPage._scheduleHq("portrait", person.Id)
                        else if (!activeFocus && (personPage._hqPendingKind === "portrait" || personPage.hqTargetKind === "portrait"))
                            personPage._scheduleHq("", "")
                    }
                    scale: focused ? 1.025 : 1.0
                    transformOrigin: Item.Center
                    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    Keys.onPressed: {
                        if (event.key === Qt.Key_Left) {
                            personPage.focusBiography()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Up) {
                            personPage.focusHudAvatar()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Down) {
                            personPage._firstRail()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                            personPage.openPhotoViewer()
                            event.accepted = true
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: false
                        onClicked: {
                            personPage.currentFocus = personPage.focusPortrait
                            portraitFocus.forceActiveFocus()
                            personPage.openPhotoViewer()
                        }
                    }
                    Item {
                        id: portraitFrame
                        anchors.fill: parent
                        clip: true
                        Rectangle { anchors.fill: parent; color: "#252936" }
                        Image {
                            id: personPortrait
                            anchors.fill: parent
                            source: personPage.personPortraitUrl()
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: true
                            mipmap: false
                            smooth: !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking))
                            visible: source !== "" && status === Image.Ready
                            onStatusChanged: {
                                if (status === Image.Ready && portraitFocus.activeFocus && person && person.Id)
                                    personPage._scheduleHq("portrait", person.Id)
                            }
                        }
                        Image {
                            id: personPortraitHq
                            anchors.fill: parent
                            source: (!personPage.modalOpen && portraitFocus.activeFocus && !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking))
                                     && personPortrait.status === Image.Ready
                                     && person && person.Id && personPage.hqTargetKind === "portrait"
                                     && personPage.hqTargetId === String(person.Id))
                                    ? personPage.personPortraitHqUrl() : ""
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: false
                            mipmap: false
                            smooth: !(rootFlick && (rootFlick.moving || rootFlick.dragging || rootFlick.flicking))
                            visible: source !== "" && status === Image.Ready
                            opacity: visible ? 1.0 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                        }
                        Item {
                            anchors.fill: parent
                            visible: !personPortrait.visible
                            Rectangle { anchors.fill: parent; color: "#2a2f4f" }
                            Item {
                                anchors.centerIn: parent
                                width: parent.width * 0.70
                                height: parent.height * 0.61
                                Rectangle {
                                    width: parent.width * 0.44
                                    height: width
                                    radius: width / 2
                                    color: "#9aa3bd"
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    y: 0
                                }
                                Rectangle {
                                    width: parent.width * 0.78
                                    height: parent.height * 0.57
                                    radius: Math.min(width, height) * 0.20
                                    color: "#7d86a4"
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    y: parent.height * 0.39
                                }
                            }
                        }
                    }
                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: portraitFocus.focused ? 2 : 1
                        border.color: portraitFocus.focused ? "#FFFFFF" : "#45FFFFFF"
                        antialiasing: false
                    }
                }
            }
            Item {
                id: creditsStatus
                width: parent.width
                height: creditsLoading ? 44 : 0
                visible: creditsLoading
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: marginL
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Recherche des films, séries et épisodes de la bibliothèque…"
                    color: "#AEB5C9"
                    font.pixelSize: 17
                    textFormat: Text.PlainText
                }
            }
            Item {
                id: moviesSection
                width: parent.width
                height: visible ? (36 + railH) : 0
                visible: movies && movies.length > 0
                Text {
                    x: marginL
                    y: 0
                    text: "Films"
                    color: "#FFFFFF"
                    font.pixelSize: 28
                    font.bold: true
                    textFormat: Text.PlainText
                }
                Text {
                    anchors.right: parent.right; anchors.rightMargin: marginR; y: 8
                    text: _creditsBaseLoadingMore ? "Chargement…" : ""
                    visible: text.length > 0; color: "#AEB5C9"; font.pixelSize: 15; textFormat: Text.PlainText
                }
                ListView {
                    id: moviesList
                    x: 0
                    y: 38
                    width: parent.width
                    height: railH
                    orientation: ListView.Horizontal
                    snapMode: ListView.NoSnap
                    highlightFollowsCurrentItem: true
                    highlightRangeMode: ListView.StrictlyEnforceRange
                    preferredHighlightBegin: railEdgePad
                    preferredHighlightEnd: Math.max(railEdgePad, width - mediaCardW - railEdgePad)
                    highlightMoveDuration: 170
                    highlightMoveVelocity: -1
                    highlight: Item { width: mediaCardW; height: railH; visible: false }
                    model: movies || []
                    spacing: mediaGap
                    clip: true
                    reuseItems: true
                    cacheBuffer: 430
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentWidth > width + 2
                    flickDeceleration: 5000
                    maximumFlickVelocity: 3200
                    onCountChanged: {
                        if (count <= 0) currentIndex = -1
                        else if (currentIndex < 0 || currentIndex >= count) currentIndex = 0
                    }
                    header: Item { width: railEdgePad; height: 1 }
                    footer: Item { width: railEdgePad; height: 1 }
                    Keys.onPressed: {
                        if (event.key === Qt.Key_Left) {
                            if (currentIndex > 0) currentIndex--
                            else personPage._requestCreditsWindow("base", "backward", "movies")
                            event.accepted = true
                        } else if (event.key === Qt.Key_Right) {
                            if (currentIndex < count - 1) currentIndex++
                            else personPage._requestCreditsWindow("base", "forward", "movies")
                            event.accepted = true
                        } else if (event.key === Qt.Key_Up) {
                            personPage.focusFavoriteButton()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Down) {
                            if (series && series.length) personPage.focusSeriesRail()
                            else if (episodes && episodes.length) personPage.focusEpisodesRail()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                            if (currentIndex >= 0 && currentIndex < movies.length)
                                personPage._openMedia(movies[currentIndex])
                            event.accepted = true
                        }
                    }
                    onActiveFocusChanged: {
                        if (activeFocus) {
                            personPage.currentFocus = personPage.focusMovies
                            var it = (movies && currentIndex >= 0 && currentIndex < movies.length) ? movies[currentIndex] : null
                            personPage._scheduleHq("media", it && it.Id ? it.Id : "")
                        } else {
                            personPage._scheduleHq("", "")
                        }
                    }
                    onCurrentIndexChanged: {
                        personPage._maybeRequestCreditsMore("movies", currentIndex, count)
                        if (activeFocus) {
                            personPage._saveFocusState()
                            var it = (movies && currentIndex >= 0 && currentIndex < movies.length) ? movies[currentIndex] : null
                            personPage._scheduleHq("media", it && it.Id ? it.Id : "")
                        }
                    }
                    delegate: mediaCardDelegate
                }
            }
            Item {
                id: seriesSection
                width: parent.width
                height: visible ? (36 + railH) : 0
                visible: series && series.length > 0
                Text {
                    x: marginL
                    y: 0
                    text: "Séries TV"
                    color: "#FFFFFF"
                    font.pixelSize: 28
                    font.bold: true
                    textFormat: Text.PlainText
                }
                Text {
                    anchors.right: parent.right; anchors.rightMargin: marginR; y: 8
                    text: _creditsBaseLoadingMore ? "Chargement…" : ""
                    visible: text.length > 0; color: "#AEB5C9"; font.pixelSize: 15; textFormat: Text.PlainText
                }
                ListView {
                    id: seriesList
                    x: 0
                    y: 38
                    width: parent.width
                    height: railH
                    orientation: ListView.Horizontal
                    snapMode: ListView.NoSnap
                    highlightFollowsCurrentItem: true
                    highlightRangeMode: ListView.StrictlyEnforceRange
                    preferredHighlightBegin: railEdgePad
                    preferredHighlightEnd: Math.max(railEdgePad, width - mediaCardW - railEdgePad)
                    highlightMoveDuration: 170
                    highlightMoveVelocity: -1
                    highlight: Item { width: mediaCardW; height: railH; visible: false }
                    model: series || []
                    spacing: mediaGap
                    clip: true
                    reuseItems: true
                    cacheBuffer: 430
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentWidth > width + 2
                    flickDeceleration: 5000
                    maximumFlickVelocity: 3200
                    onCountChanged: {
                        if (count <= 0) currentIndex = -1
                        else if (currentIndex < 0 || currentIndex >= count) currentIndex = 0
                    }
                    header: Item { width: railEdgePad; height: 1 }
                    footer: Item { width: railEdgePad; height: 1 }
                    Keys.onPressed: {
                        if (event.key === Qt.Key_Left) {
                            if (currentIndex > 0) currentIndex--
                            else personPage._requestCreditsWindow("base", "backward", "series")
                            event.accepted = true
                        } else if (event.key === Qt.Key_Right) {
                            if (currentIndex < count - 1) currentIndex++
                            else personPage._requestCreditsWindow("base", "forward", "series")
                            event.accepted = true
                        } else if (event.key === Qt.Key_Up) {
                            if (movies && movies.length) personPage.focusMoviesRail()
                            else personPage.focusFavoriteButton()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Down) {
                            if (episodes && episodes.length) personPage.focusEpisodesRail()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                            if (currentIndex >= 0 && currentIndex < series.length)
                                personPage._openMedia(series[currentIndex])
                            event.accepted = true
                        }
                    }
                    onActiveFocusChanged: {
                        if (activeFocus) {
                            personPage.currentFocus = personPage.focusSeries
                            var it = (series && currentIndex >= 0 && currentIndex < series.length) ? series[currentIndex] : null
                            personPage._scheduleHq("media", it && it.Id ? it.Id : "")
                        } else {
                            personPage._scheduleHq("", "")
                        }
                    }
                    onCurrentIndexChanged: {
                        personPage._maybeRequestCreditsMore("series", currentIndex, count)
                        if (activeFocus) {
                            personPage._saveFocusState()
                            var it = (series && currentIndex >= 0 && currentIndex < series.length) ? series[currentIndex] : null
                            personPage._scheduleHq("media", it && it.Id ? it.Id : "")
                        }
                    }
                    delegate: mediaCardDelegate
                }
            }
            Item {
                id: episodesSection
                width: parent.width
                height: visible ? (36 + episodeRailH) : 0
                visible: episodes && episodes.length > 0
                Text {
                    x: marginL
                    y: 0
                    text: "Épisodes"
                    color: "#FFFFFF"
                    font.pixelSize: 28
                    font.bold: true
                    textFormat: Text.PlainText
                }
                Text {
                    anchors.right: parent.right; anchors.rightMargin: marginR; y: 8
                    text: _creditsEpisodeLoadingMore ? "Chargement…" : ""
                    visible: text.length > 0; color: "#AEB5C9"; font.pixelSize: 15; textFormat: Text.PlainText
                }
                ListView {
                    id: episodesList
                    x: 0
                    y: 38
                    width: parent.width
                    height: episodeRailH
                    orientation: ListView.Horizontal
                    snapMode: ListView.NoSnap
                    highlightFollowsCurrentItem: true
                    highlightRangeMode: ListView.StrictlyEnforceRange
                    preferredHighlightBegin: episodeEdgePad
                    preferredHighlightEnd: Math.max(episodeEdgePad, width - episodeCardW - episodeEdgePad)
                    highlightMoveDuration: 170
                    highlightMoveVelocity: -1
                    highlight: Item { width: episodeCardW; height: episodeRailH; visible: false }
                    model: episodes || []
                    spacing: episodeGap
                    clip: true
                    reuseItems: true
                    cacheBuffer: 600
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentWidth > width + 2
                    flickDeceleration: 5000
                    maximumFlickVelocity: 3200
                    onCountChanged: {
                        if (count <= 0) currentIndex = -1
                        else if (currentIndex < 0 || currentIndex >= count) currentIndex = 0
                    }
                    header: Item { width: episodeEdgePad; height: 1 }
                    footer: Item { width: episodeEdgePad; height: 1 }
                    Keys.onPressed: {
                        if (event.key === Qt.Key_Left) {
                            if (currentIndex > 0) currentIndex--
                            else personPage._requestCreditsWindow("episodes", "backward", "episodes")
                            event.accepted = true
                        } else if (event.key === Qt.Key_Right) {
                            if (currentIndex < count - 1) currentIndex++
                            else personPage._requestCreditsWindow("episodes", "forward", "episodes")
                            event.accepted = true
                        } else if (event.key === Qt.Key_Up) {
                            if (series && series.length) personPage.focusSeriesRail()
                            else if (movies && movies.length) personPage.focusMoviesRail()
                            else personPage.focusFavoriteButton()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                            if (currentIndex >= 0 && currentIndex < episodes.length)
                                personPage._openEpisode(episodes[currentIndex])
                            event.accepted = true
                        }
                    }
                    onActiveFocusChanged: {
                        if (activeFocus) {
                            personPage.currentFocus = personPage.focusEpisodes
                            var it = (episodes && currentIndex >= 0 && currentIndex < episodes.length) ? episodes[currentIndex] : null
                            personPage._scheduleHq("episode", it && it.Id ? it.Id : "")
                        } else {
                            personPage._scheduleHq("", "")
                        }
                    }
                    onCurrentIndexChanged: {
                        personPage._maybeRequestCreditsMore("episodes", currentIndex, count)
                        if (activeFocus) {
                            personPage._saveFocusState()
                            var it = (episodes && currentIndex >= 0 && currentIndex < episodes.length) ? episodes[currentIndex] : null
                            personPage._scheduleHq("episode", it && it.Id ? it.Id : "")
                        }
                    }
                    delegate: Item {
                        id: episodeCard
                        width: episodeCardW
                        height: episodeRailH - 8
                        readonly property var ownerView: ListView.view
                        readonly property bool selected: !!(ownerView && ownerView.activeFocus && ListView.isCurrentItem)
                        // Le delegate complet doit passer devant ses voisins. Sinon le débordement du zoom 1.14, notamment le bord droit de l'encadré blanc, peut être repeint par le delegate suivant.
                        z: selected ? 100 : 0
                        readonly property bool allowFocusAnims: personPage.visible && !personPage.modalOpen
                        property string thumbSource: personPage.episodeThumbUrl(modelData)
                        onAllowFocusAnimsChanged: {
                            if (!allowFocusAnims && episodePosterWrap)
                                episodePosterWrap._applyScaleImmediate()
                        }
                        onSelectedChanged: {
                            if (!episodePosterWrap)
                                return
                            if (!allowFocusAnims) {
                                episodePosterWrap._applyScaleImmediate()
                                return
                            }
                            if (selected)
                                episodePosterWrap._startScaleIn()
                            else
                                episodePosterWrap._startScaleOut()
                        }
                        Item {
                            id: episodePosterWrap
                            x: Math.round((episodeCard.width - episodeThumbW) / 2)
                            y: episodeTopPad
                            width: episodeThumbW
                            height: episodeThumbH
                            transformOrigin: Item.Bottom
                            scale: 1.0
                            z: episodeCard.selected ? 20 : 1
                            transform: Translate {
                                y: episodeCard.selected ? -episodeFocusLiftPx : 0
                                Behavior on y {
                                    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                                }
                            }
                            // Zoom strictement calqué sur PosterGridCard : 1.00 -> 1.14 en 120 ms -> 1.12 en 90 ms.
                            SequentialAnimation {
                                id: episodeScaleIn
                                running: false
                                PropertyAnimation {
                                    target: episodePosterWrap
                                    property: "scale"
                                    to: personPage.episodeFocusScale
                                    duration: 120
                                    easing.type: Easing.OutCubic
                                }
                                PropertyAnimation {
                                    target: episodePosterWrap
                                    property: "scale"
                                    to: personPage.episodeFocusScale - 0.02
                                    duration: 90
                                    easing.type: Easing.OutCubic
                                }
                            }
                            NumberAnimation {
                                id: episodeScaleOut
                                target: episodePosterWrap
                                property: "scale"
                                to: 1.0
                                duration: 130
                                easing.type: Easing.OutCubic
                                running: false
                            }
                            function _applyScaleImmediate() {
                                episodeScaleIn.stop()
                                episodeScaleOut.stop()
                                scale = episodeCard.selected
                                        ? (personPage.episodeFocusScale - 0.02)
                                        : 1.0
                            }
                            function _startScaleIn() {
                                episodeScaleOut.stop()
                                episodeScaleIn.start()
                            }
                            function _startScaleOut() {
                                episodeScaleIn.stop()
                                episodeScaleOut.start()
                            }
                            Component.onCompleted: _applyScaleImmediate()
                            Connections {
                                target: episodeCard.ownerView
                                ignoreUnknownSignals: true
                                function onActiveFocusChanged() {
                                    episodePosterWrap._applyScaleImmediate()
                                }
                            }
                            Rectangle {
                                anchors.fill: parent
                                color: "#151821"
                            }
                            Image {
                                id: episodeImage
                                anchors.fill: parent
                                source: episodeCard.thumbSource
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: false
                                mipmap: false
                                smooth: !!episodeCard.ownerView && !(episodeCard.ownerView.moving || episodeCard.ownerView.dragging || episodeCard.ownerView.flicking)
                                onStatusChanged: {
                                    if (status === Image.Ready && episodeCard.selected && modelData && modelData.Id)
                                        personPage._scheduleHq("episode", modelData.Id)
                                }
                            }
                            Image {
                                id: episodeImageHq
                                anchors.fill: parent
                                source: (!personPage.modalOpen && episodeCard.selected && episodeCard.ownerView
                                         && !(episodeCard.ownerView.moving || episodeCard.ownerView.dragging || episodeCard.ownerView.flicking)
                                         && episodeImage.status === Image.Ready && modelData && modelData.Id
                                         && personPage.hqTargetKind === "episode"
                                         && personPage.hqTargetId === String(modelData.Id))
                                        ? personPage.episodeThumbHqUrl(modelData) : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: false
                                mipmap: false
                                smooth: !!episodeCard.ownerView && !(episodeCard.ownerView.moving || episodeCard.ownerView.dragging || episodeCard.ownerView.flicking)
                                visible: source !== "" && status === Image.Ready
                                opacity: visible ? 1.0 : 0.0
                                Behavior on opacity { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                            }
                            Item {
                                anchors.fill: parent
                                visible: episodeCard.thumbSource === "" || episodeImage.status === Image.Error
                                Rectangle {
                                    anchors.fill: parent
                                    color: "#252936"
                                }
                                Rectangle {
                                    width: parent.width * 0.38
                                    height: parent.height * 0.16
                                    radius: 4
                                    anchors.centerIn: parent
                                    color: "#69738A"
                                }
                                Rectangle {
                                    width: parent.width * 0.24
                                    height: 4
                                    radius: 2
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.verticalCenterOffset: -14
                                    color: "#AEB6C8"
                                }
                                Rectangle {
                                    width: parent.width * 0.31
                                    height: 4
                                    radius: 2
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.verticalCenterOffset: 2
                                    color: "#929CB2"
                                }
                            }
                            Rectangle {
                                // Cadre exactement superposé aux limites de la vignette. Aucun retrait : le poster ne peut plus apparaître au-delà du bord blanc pendant le zoom au focus.
                                anchors.fill: parent
                                anchors.margins: 0
                                color: "transparent"
                                border.width: episodeCard.selected ? 2 : 0
                                border.color: "#FFFFFF"
                                antialiasing: false
                                opacity: episodeCard.selected ? 1.0 : 0.0
                                z: 30
                            }
                        }
                        // ===== TITRE EPISODE : marquee 20 fps Freebox ===== Déplacement manuel de x, identique au mécanisme éprouvé de NextUpBlock. Aucun ShaderEffectSource / OpacityMask : coût minimal et mouvement fiable QtQuick 2.15.
                        Item {
                            id: episodeTitleClip
                            anchors.top: episodePosterWrap.bottom
                            anchors.topMargin: 8
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: episodeThumbW
                            height: 20
                            clip: true
                            readonly property bool railMoving: !!(episodeCard.ownerView
                                                                  && (episodeCard.ownerView.moving
                                                                      || episodeCard.ownerView.dragging
                                                                      || episodeCard.ownerView.flicking))
                            readonly property bool focusHot: episodeCard.selected
                            readonly property bool allowMarquee: personPage.mediaMarqueeEnabled
                                                                 && personPage.visible
                                                                 && !personPage.modalOpen
                                                                 && episodeCard.visible
                                                                 && focusHot
                                                                 && !railMoving
                                                                 && visible
                                                                 && width > 0
                                                                 && height > 0
                            readonly property bool marqueeNeeded: episodeTitleText.paintedWidth > (width + 1)
                            readonly property real marqueeOverflow: Math.max(0, episodeTitleText.paintedWidth - width)
                            readonly property real marqueeTravel: marqueeNeeded
                                                                   ? Math.max(0, episodeTitleText.paintedWidth + personPage.mediaMarqueeGapPx)
                                                                   : 0
                            readonly property real marqueeExitX: marqueeTravel > 0 ? -marqueeTravel : 0
                            readonly property bool marqueeEligible: marqueeNeeded && allowMarquee
                            onAllowMarqueeChanged: updateMarquee()
                            onFocusHotChanged: updateMarquee()
                            onWidthChanged: updateMarquee()
                            onVisibleChanged: updateMarquee()
                            onMarqueeNeededChanged: updateMarquee()
                            Component.onCompleted: updateMarquee()
                            Text {
                                id: episodeTitleText
                                textFormat: Text.PlainText
                                text: SeasonUtils.displayEpisodeTitle(modelData)
                                x: 0
                                y: Math.round((episodeTitleClip.height - height) / 2) - 1
                                color: episodeTitleClip.focusHot ? "#FFFFFF" : "#E0E3EC"
                                font.pixelSize: 15
                                font.bold: episodeTitleClip.focusHot
                                wrapMode: Text.NoWrap
                                elide: episodeTitleClip.allowMarquee ? Text.ElideNone : Text.ElideRight
                                onTextChanged: episodeTitleClip.updateMarquee()
                                onPaintedWidthChanged: episodeTitleClip.updateMarquee()
                            }
                            Timer {
                                id: episodeTitleMarqueeTick
                                interval: 50
                                repeat: true
                                running: false
                                property real posX: 0
                                property int phase: 0       // 0 pause départ, 1 scroll, 2 pause fin
                                property int waitMs: 0
                                onTriggered: {
                                    if (!episodeTitleClip.marqueeEligible || episodeTitleClip.railMoving) {
                                        episodeTitleClip.resetMarquee()
                                        return
                                    }
                                    if (phase === 0) {
                                        waitMs -= interval
                                        if (waitMs <= 0) phase = 1
                                        return
                                    }
                                    if (phase === 1) {
                                        posX -= (personPage.mediaMarqueeSpeedPxPerSec * interval / 1000.0)
                                        if (posX <= episodeTitleClip.marqueeExitX) {
                                            posX = episodeTitleClip.marqueeExitX
                                            episodeTitleText.x = Math.round(posX)
                                            phase = 2
                                            waitMs = personPage.mediaMarqueeEndPauseMs
                                            return
                                        }
                                        episodeTitleText.x = Math.round(posX)
                                        return
                                    }
                                    waitMs -= interval
                                    if (waitMs <= 0) {
                                        posX = 0
                                        episodeTitleText.x = 0
                                        phase = 0
                                        waitMs = personPage.mediaMarqueeStartDelayMs
                                    }
                                }
                            }
                            function resetMarquee() {
                                episodeTitleMarqueeTick.stop()
                                episodeTitleMarqueeTick.posX = 0
                                episodeTitleMarqueeTick.phase = 0
                                episodeTitleMarqueeTick.waitMs = personPage.mediaMarqueeStartDelayMs
                                episodeTitleText.x = 0
                            }
                            function updateMarquee() {
                                resetMarquee()
                                if (episodeTitleClip.marqueeEligible) {
                                    Qt.callLater(function(){
                                        if (!episodeTitleClip.marqueeEligible || episodeTitleClip.railMoving) {
                                            episodeTitleClip.resetMarquee()
                                            return
                                        }
                                        episodeTitleMarqueeTick.posX = 0
                                        episodeTitleMarqueeTick.phase = 0
                                        episodeTitleMarqueeTick.waitMs = personPage.mediaMarqueeStartDelayMs
                                        episodeTitleMarqueeTick.restart()
                                    })
                                }
                            }
                            Connections {
                                target: episodeCard.ownerView
                                ignoreUnknownSignals: true
                                function onMovingChanged() { episodeTitleClip.updateMarquee() }
                                function onDraggingChanged() { episodeTitleClip.updateMarquee() }
                                function onFlickingChanged() { episodeTitleClip.updateMarquee() }
                                function onCurrentIndexChanged() { episodeTitleClip.updateMarquee() }
                                function onActiveFocusChanged() { episodeTitleClip.updateMarquee() }
                            }
                            Component.onDestruction: episodeTitleClip.resetMarquee()
                        }
                        // ===== META EPISODE : marquee premium + fondu ===== Même mécanique visuelle que les titres premium : animation au focus uniquement, arrêt pendant le scroll, fondu progressif aux bords sans modifier la donnée affichée.
                        Item {
                            id: episodeMetaClip
                            anchors.top: episodePosterWrap.bottom
                            anchors.topMargin: 29
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: episodeThumbW
                            height: 18
                            clip: false
                            readonly property bool railMoving: !!(episodeCard.ownerView
                                                                  && (episodeCard.ownerView.moving
                                                                      || episodeCard.ownerView.dragging
                                                                      || episodeCard.ownerView.flicking))
                            readonly property bool focusHot: episodeCard.selected
                            readonly property bool allowMarquee: personPage.mediaMarqueeEnabled
                                                                 && personPage.visible
                                                                 && !personPage.modalOpen
                                                                 && episodeCard.visible
                                                                 && focusHot
                                                                 && !railMoving
                                                                 && visible
                                                                 && width > 0
                                                                 && height > 0
                            readonly property bool marqueeNeeded: episodeMetaText.paintedWidth > (width + 1)
                            readonly property real marqueeOverflow: Math.max(0, episodeMetaText.paintedWidth - width)
                            readonly property int marqueeGap: personPage.mediaMarqueeGapPx
                            readonly property real marqueeTravel: marqueeNeeded
                                                                   ? Math.max(0, episodeMetaText.paintedWidth + marqueeGap)
                                                                   : 0
                            readonly property real marqueeExitX: marqueeTravel > 0 ? -marqueeTravel : 0
                            readonly property int marqueeScrollMs: marqueeTravel > 0
                                                                   ? Math.max(3200, Math.min(14000,
                                                                       Math.round((marqueeTravel / Math.max(1, personPage.mediaMarqueeSpeedPxPerSec)) * 1000)))
                                                                   : 0
                            readonly property int marqueeFadeW: Math.min(34, Math.max(18, Math.round(width * 0.12)))
                            readonly property bool marqueeEligible: marqueeNeeded && allowMarquee
                            property bool marqueeMoving: false
                            readonly property bool maskActive: marqueeEligible
                                                               && marqueeMoving
                                                               && allowMarquee
                                                               && episodeCard.visible
                                                               && focusHot
                                                               && !railMoving
                            readonly property bool leftFadeActive: maskActive && episodeMetaText.x < -2
                            readonly property bool rightFadeActive: maskActive && episodeMetaText.x > -marqueeOverflow + 2
                            onAllowMarqueeChanged: updateMarquee()
                            onFocusHotChanged: updateMarquee()
                            onWidthChanged: updateMarquee()
                            onVisibleChanged: updateMarquee()
                            onMarqueeNeededChanged: updateMarquee()
                            onMarqueeMovingChanged: {
                                if (episodeMetaTexture && episodeMetaTexture.scheduleUpdate)
                                    episodeMetaTexture.scheduleUpdate()
                            }
                            Component.onCompleted: updateMarquee()
                            Item {
                                id: episodeMetaSource
                                anchors.fill: parent
                                clip: true
                                visible: true
                                Text {
                                    id: episodeMetaText
                                    textFormat: Text.PlainText
                                    text: MediaCatalog.personEpisodeMeta(modelData)
                                    x: 0
                                    y: Math.round((episodeMetaSource.height - height) / 2) - 1
                                    color: episodeMetaClip.focusHot ? "#C9D0E3" : "#9EA7BC"
                                    font.pixelSize: 13
                                    wrapMode: Text.NoWrap
                                    elide: episodeMetaClip.allowMarquee ? Text.ElideNone : Text.ElideRight
                                    onTextChanged: episodeMetaClip.updateMarquee()
                                    onPaintedWidthChanged: episodeMetaClip.updateMarquee()
                                    onXChanged: {
                                        if (episodeMetaClip.maskActive
                                                && episodeMetaTexture
                                                && episodeMetaTexture.scheduleUpdate)
                                            episodeMetaTexture.scheduleUpdate()
                                    }
                                }
                            }
                            ShaderEffectSource {
                                id: episodeMetaTexture
                                sourceItem: episodeMetaSource
                                live: episodeMetaClip.maskActive
                                enabled: episodeMetaClip.maskActive
                                hideSource: episodeMetaClip.maskActive
                                recursive: true
                                smooth: false
                                visible: false
                                wrapMode: ShaderEffectSource.ClampToEdge
                            }
                            Timer {
                                id: episodeMetaTexturePulse
                                interval: 140
                                repeat: true
                                running: episodeMetaClip.maskActive
                                         && episodeMetaMarquee.running
                                         && episodeMetaClip.allowMarquee
                                         && personPage.visible
                                         && !personPage.modalOpen
                                         && episodeCard.visible
                                         && episodeMetaClip.focusHot
                                         && !episodeMetaClip.railMoving
                                onTriggered: {
                                    if (!episodeMetaClip.maskActive
                                            || !episodeMetaClip.allowMarquee
                                            || !episodeCard.visible
                                            || !episodeMetaClip.focusHot
                                            || episodeMetaClip.railMoving) {
                                        stop()
                                        return
                                    }
                                    if (episodeMetaTexture && episodeMetaTexture.scheduleUpdate)
                                        episodeMetaTexture.scheduleUpdate()
                                }
                            }
                            OpacityMask {
                                anchors.fill: parent
                                visible: episodeMetaClip.maskActive
                                enabled: episodeMetaClip.maskActive
                                source: episodeMetaTexture
                                maskSource: episodeMetaFadeMask
                                cached: false
                            }
                            Item {
                                id: episodeMetaFadeMask
                                visible: episodeMetaClip.maskActive
                                x: -10000
                                y: -10000
                                width: episodeMetaClip.width
                                height: episodeMetaClip.height
                                readonly property int leftW: episodeMetaClip.leftFadeActive ? episodeMetaClip.marqueeFadeW : 0
                                readonly property int rightW: episodeMetaClip.rightFadeActive ? episodeMetaClip.marqueeFadeW : 0
                                Rectangle {
                                    visible: episodeMetaFadeMask.leftW > 0
                                    x: 0
                                    y: 0
                                    width: episodeMetaFadeMask.leftW
                                    height: parent.height
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: "#00FFFFFF" }
                                        GradientStop { position: 1.0; color: "#FFFFFFFF" }
                                    }
                                }
                                Rectangle {
                                    x: episodeMetaFadeMask.leftW
                                    y: 0
                                    width: Math.max(0, parent.width - episodeMetaFadeMask.leftW - episodeMetaFadeMask.rightW)
                                    height: parent.height
                                    color: "#FFFFFFFF"
                                }
                                Rectangle {
                                    visible: episodeMetaFadeMask.rightW > 0
                                    x: parent.width - episodeMetaFadeMask.rightW
                                    y: 0
                                    width: episodeMetaFadeMask.rightW
                                    height: parent.height
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: "#FFFFFFFF" }
                                        GradientStop { position: 1.0; color: "#00FFFFFF" }
                                    }
                                }
                            }
                            SequentialAnimation {
                                id: episodeMetaMarquee
                                running: false
                                loops: Animation.Infinite
                                ScriptAction {
                                    script: {
                                        episodeMetaText.x = 0
                                        episodeMetaText.opacity = 1.0
                                        episodeMetaClip.marqueeMoving = false
                                    }
                                }
                                PauseAnimation { duration: personPage.mediaMarqueeStartDelayMs }
                                ScriptAction {
                                    script: {
                                        episodeMetaClip.marqueeMoving = true
                                        if (episodeMetaTexture && episodeMetaTexture.scheduleUpdate)
                                            episodeMetaTexture.scheduleUpdate()
                                    }
                                }
                                NumberAnimation {
                                    target: episodeMetaText
                                    property: "x"
                                    from: 0
                                    to: episodeMetaClip.marqueeExitX
                                    duration: episodeMetaClip.marqueeScrollMs
                                    easing.type: Easing.Linear
                                }
                                ScriptAction {
                                    script: {
                                        episodeMetaClip.marqueeMoving = false
                                        if (episodeMetaTexture && episodeMetaTexture.scheduleUpdate)
                                            episodeMetaTexture.scheduleUpdate()
                                    }
                                }
                                PauseAnimation { duration: 180 }
                                ScriptAction {
                                    script: {
                                        episodeMetaText.x = 0
                                        episodeMetaText.opacity = 1.0
                                        episodeMetaClip.marqueeMoving = false
                                    }
                                }
                                PauseAnimation { duration: personPage.mediaMarqueeEndPauseMs }
                                onRunningChanged: {
                                    if (!running) {
                                        episodeMetaClip.marqueeMoving = false
                                        episodeMetaText.x = 0
                                        episodeMetaText.opacity = 1.0
                                    }
                                    if (episodeMetaTexture && episodeMetaTexture.scheduleUpdate)
                                        episodeMetaTexture.scheduleUpdate()
                                }
                            }
                            Timer {
                                id: episodeMetaMarqueeKick
                                interval: 40
                                repeat: false
                                onTriggered: {
                                    if (episodeMetaClip.marqueeEligible
                                            && episodeMetaClip.marqueeScrollMs > 0
                                            && !episodeMetaMarquee.running
                                            && episodeCard.visible
                                            && episodeMetaClip.focusHot
                                            && personPage.visible
                                            && !personPage.modalOpen
                                            && !episodeMetaClip.railMoving)
                                        episodeMetaMarquee.start()
                                }
                            }
                            function updateMarquee() {
                                episodeMetaMarquee.stop()
                                episodeMetaMarqueeKick.stop()
                                marqueeMoving = false
                                episodeMetaText.x = 0
                                episodeMetaText.opacity = 1.0
                                if (episodeMetaTexture && episodeMetaTexture.scheduleUpdate)
                                    episodeMetaTexture.scheduleUpdate()
                                if (episodeMetaClip.marqueeEligible && episodeMetaClip.marqueeScrollMs > 0)
                                    episodeMetaMarqueeKick.restart()
                            }
                            Connections {
                                target: episodeCard.ownerView
                                ignoreUnknownSignals: true
                                function onMovingChanged() { episodeMetaClip.updateMarquee() }
                                function onDraggingChanged() { episodeMetaClip.updateMarquee() }
                                function onFlickingChanged() { episodeMetaClip.updateMarquee() }
                                function onCurrentIndexChanged() { episodeMetaClip.updateMarquee() }
                                function onActiveFocusChanged() { episodeMetaClip.updateMarquee() }
                            }
                            Component.onDestruction: {
                                episodeMetaMarqueeKick.stop()
                                episodeMetaMarquee.stop()
                                episodeMetaClip.marqueeMoving = false
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                if (!episodeCard.ownerView) return
                                episodeCard.ownerView.currentIndex = index
                                episodeCard.ownerView.forceActiveFocus()
                                personPage._openEpisode(modelData)
                            }
                        }
                    }
                }
            }
            Item {
                width: parent.width
                height: visible ? 72 : 0
                visible: creditsLoaded && !creditsLoading && (!movies || movies.length === 0) && (!series || series.length === 0) && (!episodes || episodes.length === 0)
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: marginL
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Aucun film, série ou épisode avec cette personne dans votre bibliothèque."
                    color: "#AEB5C9"
                    font.pixelSize: 18
                    textFormat: Text.PlainText
                }
            }
            Item { width: 1; height: 70 }
        }
    }
    Component {
        id: mediaCardDelegate
        Item {
            id: mediaCard
            width: mediaCardW
            height: railH - 8
            readonly property var ownerView: ListView.view
            readonly property bool railScrolling: !!(ownerView
                                                       && (ownerView.moving
                                                           || ownerView.dragging
                                                           || ownerView.flicking))
            readonly property bool selected: !!(ownerView
                                                 && ownerView.activeFocus
                                                 && ListView.isCurrentItem)
            // Même règle que PosterGrid : la carte sélectionnée doit être au-dessus des delegates voisins pendant son débordement de zoom.
            z: selected ? 100 : 0
            property var itemData: modelData
            Pages.LibraryPosterCard {
                id: mediaPosterCard
                anchors.left: parent.left
                anchors.top: parent.top
                controller: personPage
                modelData: mediaCard.itemData
                tileWidth: personPage.mediaPosterW
                tileHeight: personPage.mediaPosterH
                // Le texte est rendu localement ci-dessous afin d'utiliser le marquee/fondu Freebox fiable de SimilarItems sur tous les rails.
                titleHeight: 0
                sidePad: Math.max(0, Math.round((personPage.mediaCardW - personPage.mediaPosterW) / 2))
                topPad: personPage.mediaPosterTopPad
                gridActiveFocus: !!mediaCard.ownerView && mediaCard.ownerView.activeFocus
                selected: mediaCard.selected
                allowLoad: personPage.visible && mediaCard.visible
                enableMouseInput: true
                hoverSelectEnabled: false
                focusLiftPxOverride: personPage.mediaFocusLiftPx
                zoomScaleOverride: personPage.focusScale
                useAllowAnimsOverride: true
                allowAnimsOverride: personPage.visible && !personPage.modalOpen
                useAllowDecosOverride: true
                allowDecosOverride: false
                smoothImages: !mediaCard.railScrolling
                useImageSourceOverride: true
                imageSourceOverride: allowLoad ? personPage.mediaPosterUrl(mediaCard.itemData) : ""
                hqImageSourceOverride: (!personPage.modalOpen && mediaCard.selected
                                        && !mediaCard.railScrolling
                                        && mediaCard.itemData && mediaCard.itemData.Id
                                        && personPage.hqTargetKind === "media"
                                        && personPage.hqTargetId === String(mediaCard.itemData.Id))
                                       ? personPage.mediaPosterHqUrl(mediaCard.itemData)
                                       : ""
                imageCache: true
                fallbackKind: "clapperboard"
                onActivated: {
                    if (!mediaCard.ownerView)
                        return
                    mediaCard.ownerView.currentIndex = index
                    mediaCard.ownerView.forceActiveFocus()
                    personPage._openMedia(mediaCard.itemData)
                }
            }
            // ===== TITRE FILM / SERIE : marquee premium SimilarItems =====
            Item {
                id: mediaTitleClip
                anchors.top: mediaPosterCard.bottom
                anchors.topMargin: 8
                anchors.horizontalCenter: parent.horizontalCenter
                width: personPage.mediaPosterW
                height: 20
                clip: false
                readonly property bool focusHot: mediaCard.selected
                readonly property bool allowMarquee: personPage.mediaMarqueeEnabled
                                                     && personPage.visible
                                                     && !personPage.modalOpen
                                                     && mediaCard.visible
                                                     && focusHot
                                                     && !mediaCard.railScrolling
                                                     && visible
                                                     && width > 0
                                                     && height > 0
                readonly property bool marqueeNeeded: mediaTitleText.paintedWidth > (width + 1)
                readonly property real marqueeOverflow: Math.max(0, mediaTitleText.paintedWidth - width)
                readonly property int marqueeGap: personPage.mediaMarqueeGapPx
                readonly property real marqueeTravel: marqueeNeeded
                                                       ? Math.max(0, mediaTitleText.paintedWidth + marqueeGap)
                                                       : 0
                readonly property real marqueeExitX: marqueeTravel > 0 ? -marqueeTravel : 0
                readonly property int marqueeScrollMs: marqueeTravel > 0
                                                       ? Math.max(3200, Math.min(14000,
                                                           Math.round((marqueeTravel / Math.max(1, personPage.mediaMarqueeSpeedPxPerSec)) * 1000)))
                                                       : 0
                readonly property int marqueeFadeW: Math.min(34, Math.max(18, Math.round(width * 0.16)))
                readonly property bool marqueeEligible: marqueeNeeded && allowMarquee
                property bool marqueeMoving: false
                readonly property bool maskActive: marqueeEligible
                                                   && marqueeMoving
                                                   && allowMarquee
                                                   && mediaCard.visible
                                                   && focusHot
                readonly property bool leftFadeActive: maskActive && mediaTitleText.x < -2
                readonly property bool rightFadeActive: maskActive && mediaTitleText.x > -marqueeOverflow + 2
                onAllowMarqueeChanged: updateMarquee()
                onFocusHotChanged: updateMarquee()
                onWidthChanged: updateMarquee()
                onVisibleChanged: updateMarquee()
                onMarqueeNeededChanged: updateMarquee()
                onMarqueeMovingChanged: {
                    if (mediaTitleTexture && mediaTitleTexture.scheduleUpdate)
                        mediaTitleTexture.scheduleUpdate()
                }
                Component.onCompleted: updateMarquee()
                Item {
                    id: mediaTitleSource
                    anchors.fill: parent
                    clip: true
                    visible: true
                    Text {
                        id: mediaTitleText
                        textFormat: Text.PlainText
                        text: mediaCard.itemData && mediaCard.itemData.Name
                              ? String(mediaCard.itemData.Name) : ""
                        x: 0
                        y: Math.round((mediaTitleSource.height - height) / 2) - 1
                        color: mediaTitleClip.focusHot ? "#FFFFFF" : "#E0E3EC"
                        font.pixelSize: 15
                        font.bold: mediaTitleClip.focusHot
                        wrapMode: Text.NoWrap
                        elide: mediaTitleClip.allowMarquee ? Text.ElideNone : Text.ElideRight
                        onTextChanged: mediaTitleClip.updateMarquee()
                        onPaintedWidthChanged: mediaTitleClip.updateMarquee()
                        onXChanged: {
                            if (mediaTitleClip.maskActive
                                    && mediaTitleTexture
                                    && mediaTitleTexture.scheduleUpdate)
                                mediaTitleTexture.scheduleUpdate()
                        }
                    }
                }
                ShaderEffectSource {
                    id: mediaTitleTexture
                    sourceItem: mediaTitleSource
                    live: mediaTitleClip.maskActive
                    enabled: mediaTitleClip.maskActive
                    hideSource: mediaTitleClip.maskActive
                    recursive: true
                    smooth: false
                    visible: false
                    wrapMode: ShaderEffectSource.ClampToEdge
                }
                Timer {
                    id: mediaTitleTexturePulse
                    interval: 140
                    repeat: true
                    running: mediaTitleClip.maskActive
                             && mediaTitleMarquee.running
                             && mediaTitleClip.allowMarquee
                             && personPage.visible
                             && !personPage.modalOpen
                             && mediaCard.visible
                             && mediaTitleClip.focusHot
                             && !mediaCard.railScrolling
                    onTriggered: {
                        if (!mediaTitleClip.maskActive
                                || !mediaTitleClip.allowMarquee
                                || !mediaCard.visible
                                || !mediaTitleClip.focusHot
                                || mediaCard.railScrolling) {
                            stop()
                            return
                        }
                        if (mediaTitleTexture && mediaTitleTexture.scheduleUpdate)
                            mediaTitleTexture.scheduleUpdate()
                    }
                }
                OpacityMask {
                    anchors.fill: parent
                    visible: mediaTitleClip.maskActive
                    enabled: mediaTitleClip.maskActive
                    source: mediaTitleTexture
                    maskSource: mediaTitleFadeMask
                    cached: false
                }
                Item {
                    id: mediaTitleFadeMask
                    visible: mediaTitleClip.maskActive
                    x: -10000
                    y: -10000
                    width: mediaTitleClip.width
                    height: mediaTitleClip.height
                    readonly property int leftW: mediaTitleClip.leftFadeActive ? mediaTitleClip.marqueeFadeW : 0
                    readonly property int rightW: mediaTitleClip.rightFadeActive ? mediaTitleClip.marqueeFadeW : 0
                    Rectangle {
                        visible: mediaTitleFadeMask.leftW > 0
                        x: 0; y: 0
                        width: mediaTitleFadeMask.leftW
                        height: parent.height
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "#00FFFFFF" }
                            GradientStop { position: 1.0; color: "#FFFFFFFF" }
                        }
                    }
                    Rectangle {
                        x: mediaTitleFadeMask.leftW
                        y: 0
                        width: Math.max(0, parent.width - mediaTitleFadeMask.leftW - mediaTitleFadeMask.rightW)
                        height: parent.height
                        color: "#FFFFFFFF"
                    }
                    Rectangle {
                        visible: mediaTitleFadeMask.rightW > 0
                        x: parent.width - mediaTitleFadeMask.rightW
                        y: 0
                        width: mediaTitleFadeMask.rightW
                        height: parent.height
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "#FFFFFFFF" }
                            GradientStop { position: 1.0; color: "#00FFFFFF" }
                        }
                    }
                }
                SequentialAnimation {
                    id: mediaTitleMarquee
                    running: false
                    loops: Animation.Infinite
                    ScriptAction {
                        script: {
                            mediaTitleText.x = 0
                            mediaTitleText.opacity = 1.0
                            mediaTitleClip.marqueeMoving = false
                        }
                    }
                    PauseAnimation { duration: personPage.mediaMarqueeStartDelayMs }
                    ScriptAction {
                        script: {
                            mediaTitleClip.marqueeMoving = true
                            if (mediaTitleTexture && mediaTitleTexture.scheduleUpdate)
                                mediaTitleTexture.scheduleUpdate()
                        }
                    }
                    NumberAnimation {
                        target: mediaTitleText
                        property: "x"
                        from: 0
                        to: mediaTitleClip.marqueeExitX
                        duration: mediaTitleClip.marqueeScrollMs
                        easing.type: Easing.Linear
                    }
                    ScriptAction {
                        script: {
                            mediaTitleClip.marqueeMoving = false
                            if (mediaTitleTexture && mediaTitleTexture.scheduleUpdate)
                                mediaTitleTexture.scheduleUpdate()
                        }
                    }
                    PauseAnimation { duration: 180 }
                    ScriptAction {
                        script: {
                            mediaTitleText.x = 0
                            mediaTitleText.opacity = 1.0
                            mediaTitleClip.marqueeMoving = false
                        }
                    }
                    PauseAnimation { duration: personPage.mediaMarqueeEndPauseMs }
                    onRunningChanged: {
                        if (!running) {
                            mediaTitleClip.marqueeMoving = false
                            mediaTitleText.x = 0
                            mediaTitleText.opacity = 1.0
                        }
                        if (mediaTitleTexture && mediaTitleTexture.scheduleUpdate)
                            mediaTitleTexture.scheduleUpdate()
                    }
                }
                Timer {
                    id: mediaTitleMarqueeKick
                    interval: 40
                    repeat: false
                    onTriggered: {
                        if (mediaTitleClip.marqueeEligible
                                && mediaTitleClip.marqueeScrollMs > 0
                                && !mediaTitleMarquee.running
                                && mediaCard.visible
                                && mediaTitleClip.focusHot
                                && personPage.visible
                                && !personPage.modalOpen
                                && !mediaCard.railScrolling)
                            mediaTitleMarquee.start()
                    }
                }
                function updateMarquee() {
                    mediaTitleMarquee.stop()
                    mediaTitleMarqueeKick.stop()
                    marqueeMoving = false
                    mediaTitleText.x = 0
                    mediaTitleText.opacity = 1.0
                    if (mediaTitleTexture && mediaTitleTexture.scheduleUpdate)
                        mediaTitleTexture.scheduleUpdate()
                    if (mediaTitleClip.marqueeEligible && mediaTitleClip.marqueeScrollMs > 0)
                        mediaTitleMarqueeKick.restart()
                }
                Connections {
                    target: mediaCard.ownerView
                    ignoreUnknownSignals: true
                    function onMovingChanged() { mediaTitleClip.updateMarquee() }
                    function onDraggingChanged() { mediaTitleClip.updateMarquee() }
                    function onFlickingChanged() { mediaTitleClip.updateMarquee() }
                    function onCurrentIndexChanged() { mediaTitleClip.updateMarquee() }
                    function onActiveFocusChanged() { mediaTitleClip.updateMarquee() }
                }
                Component.onDestruction: {
                    mediaTitleMarqueeKick.stop()
                    mediaTitleMarquee.stop()
                    mediaTitleClip.marqueeMoving = false
                }
            }
            Text {
                anchors.top: mediaTitleClip.bottom
                anchors.topMargin: 0
                anchors.horizontalCenter: parent.horizontalCenter
                width: personPage.mediaPosterW
                text: mediaCard.itemData && mediaCard.itemData.ProductionYear
                      ? String(mediaCard.itemData.ProductionYear) : ""
                color: "#AEB5C9"
                font.pixelSize: 13
                font.bold: false
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
        }
    }
    FocusScope {
        id: biographyOverlay
        anchors.fill: parent
        z: 20000
        visible: bioOverlayOpen
        enabled: visible
        focus: visible
        Rectangle { anchors.fill: parent; color: "#F20A0B10" }
        Rectangle {
            id: bioDialog
            anchors.centerIn: parent
            width: Math.min(parent.width - 120, 1040)
            height: Math.min(parent.height - 80, 610)
            radius: 16
            color: "#F2161820"
            border.width: 0
            Text {
                id: bioDialogTitle
                anchors.left: parent.left
                anchors.leftMargin: 28
                anchors.top: parent.top
                anchors.topMargin: 24
                width: parent.width - 56
                text: (person && person.Name ? person.Name : "") + " — Biographie"
                color: "#FFFFFF"
                font.pixelSize: 28
                font.bold: true
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }
            Flickable {
                id: bioFlick
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: bioDialogTitle.bottom
                anchors.bottom: parent.bottom
                anchors.margins: 28
                anchors.topMargin: 18
                anchors.bottomMargin: 28
                anchors.rightMargin: 48
                clip: true
                contentWidth: width
                contentHeight: fullBioText.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                property bool progScroll: false
                function scrollBy(delta){
                    var maxY = Math.max(0, contentHeight - height)
                    var target = Math.max(0, Math.min(maxY, contentY + delta))
                    bioScrollAnim.stop()
                    bioScrollAnim.to = target
                    bioScrollAnim.restart()
                }
                NumberAnimation {
                    id: bioScrollAnim
                    target: bioFlick
                    property: "contentY"
                    duration: 200
                    easing.type: Easing.OutCubic
                }
                Text {
                    id: fullBioText
                    width: bioFlick.width
                    text: personPage.hasBiography()
                          ? personPage.biographyText
                          : "Aucune biographie pour cette personne"
                    color: personPage.hasBiography() ? "#ECEEF5" : "#AEB4C2"
                    font.pixelSize: 21
                    lineHeightMode: Text.ProportionalHeight
                    lineHeight: 1.18
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                }
            }
            Item {
                id: bioScrollIndicator
                anchors.top: bioFlick.top
                anchors.bottom: bioFlick.bottom
                anchors.right: parent.right
                anchors.rightMargin: 25
                width: 8
                visible: bioFlick.contentHeight > bioFlick.height + 2
                Rectangle {
                    id: bioScrollTrack
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 4
                    height: parent.height
                    radius: 2
                    color: "#28FFFFFF"
                    antialiasing: false
                }
                Rectangle {
                    id: bioScrollThumb
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 6
                    radius: 3
                    color: "#C8FFFFFF"
                    antialiasing: false
                    readonly property real visibleRatio: Math.max(0.0, Math.min(1.0,
                        bioFlick.contentHeight > 0 ? (bioFlick.height / bioFlick.contentHeight) : 1.0))
                    readonly property real maxScrollY: Math.max(0, bioFlick.contentHeight - bioFlick.height)
                    readonly property real scrollRatio: maxScrollY > 0
                        ? Math.max(0.0, Math.min(1.0, bioFlick.contentY / maxScrollY))
                        : 0.0
                    height: Math.max(36, Math.round(bioScrollIndicator.height * visibleRatio))
                    y: Math.round((bioScrollIndicator.height - height) * scrollRatio)
                    Behavior on y {
                        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                    }
                }
            }
        }
        Keys.onPressed: {
            if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape
                    || event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                personPage.closeBiography()
                event.accepted = true
            } else if (event.key === Qt.Key_Up) {
                bioFlick.scrollBy(-120)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                bioFlick.scrollBy(120)
                event.accepted = true
            } else if (event.key === Qt.Key_PageUp) {
                bioFlick.scrollBy(-Math.round(bioFlick.height * 0.76))
                event.accepted = true
            } else if (event.key === Qt.Key_PageDown) {
                bioFlick.scrollBy(Math.round(bioFlick.height * 0.76))
                event.accepted = true
            } else {
                event.accepted = true
            }
        }
    }
    FocusScope {
        id: photoViewer
        anchors.fill: parent
        z: 21000
        visible: photoViewerOpen
        enabled: visible
        focus: visible
        Rectangle { anchors.fill: parent; color: "#68000000" }
        Item {
            anchors.fill: parent
            anchors.margins: 26
            clip: true
            Image {
                id: fullPersonImage
                anchors.fill: parent
                source: photoViewerOpen ? personPage.personViewerUrl() : ""
                asynchronous: true
                cache: false
                mipmap: false
                smooth: true
                fillMode: Image.PreserveAspectFit
                transformOrigin: Item.Center
                scale: photoZoom
                transform: Translate { x: photoPanX; y: photoPanY }
            }
            Item {
                anchors.centerIn: parent
                width: 190
                height: 230
                visible: fullPersonImage.source === "" || fullPersonImage.status === Image.Error
                Rectangle { anchors.fill: parent; color: "#252a3d" }
                Rectangle {
                    width: 78; height: 78; radius: 39
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 25
                    color: "#9aa3bd"
                }
                Rectangle {
                    width: 132; height: 92; radius: 26
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 116
                    color: "#7d86a4"
                }
            }
        }
        Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: 28
            anchors.topMargin: 24
            width: 84
            height: 34
            radius: 17
            color: "#B312141B"
            border.width: 1
            border.color: "#44FFFFFF"
            Text {
                anchors.centerIn: parent
                text: Math.round(photoZoom * 100) + "%"
                color: "#FFFFFF"
                font.pixelSize: 14
                font.bold: true
                textFormat: Text.PlainText
            }
        }
        Keys.onPressed: {
            if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape
                    || event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                personPage.closePhotoViewer()
                event.accepted = true
            } else if (event.key === Qt.Key_PageUp || event.key === Qt.Key_ChannelUp || event.key === Qt.Key_Plus) {
                personPage._adjustPhotoZoom(0.25)
                event.accepted = true
            } else if (event.key === Qt.Key_PageDown || event.key === Qt.Key_ChannelDown || event.key === Qt.Key_Minus) {
                personPage._adjustPhotoZoom(-0.25)
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                personPage._panPhoto(54, 0)
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                personPage._panPhoto(-54, 0)
                event.accepted = true
            } else if (event.key === Qt.Key_Up) {
                personPage._panPhoto(0, 54)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                personPage._panPhoto(0, -54)
                event.accepted = true
            } else {
                event.accepted = true
            }
        }
    }

    Text {
        z: 5100
        anchors.centerIn: parent
        width: parent.width * 0.82
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        visible: !personLoading && !person && loadingError.length > 0
        text: loadingError
        color: "#FFD5D5"
        font.pixelSize: 21
        textFormat: Text.PlainText
    }
    Component.onDestruction: {
        personMetadataPending = false
        _cancelPersonBioRetry()
        _cancelHudFocusPending()
        ++_fetchSeq
        _cancelAllCreditsRequests()
    }

    Keys.onPressed: {
        if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
            if (photoViewerOpen) closePhotoViewer()
            else if (bioOverlayOpen) closeBiography()
            else _goBack()
            event.accepted = true
        }
    }
}
