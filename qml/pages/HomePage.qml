// HomePage.qml — Topbar sans fond + logo image
// FIX retour Home : PosterGrid reste rendu sous le loader jusqu'au focus restauré.
// + Loading gate: écran noir + loader cercle de points (anim identique MoviePage/SeriePage)
//   tant que PosterGrid charge encore ses sections
//
// Collections : postergrid demande l’ouverture du mode libraryMode="collections" de moviepage.qml.
// ✅ FIX: leaveTopBarToContent clamp 0..3 (et plus 0..2)
// ✅ V4: navigation Accueil / Recherche + SearchPage chargée à la demande
//
// OPTION 2 (demandée) : délégation AVATAR + HORLOGE à Components.ClockHUD
//
// PERF PACK (Revolution) — Tweaks 1 → 12 appliqués ici :
//  1) Avatar: stop double pipeline -> géré dans ClockHUD (AnimatedImage + still + watchdog)
//  2) Avatar: mask/shader seulement quand utile -> géré dans ClockHUD (opacity threshold + gates)
//  3) Avatar: cache dynamique + stop GIF hors viewport/topbar cachée/scroll -> géré dans ClockHUD (gates)
//  4) Ring Freebox-proof: border.width constant + anim opacity -> géré dans ClockHUD
//  5) PosterGrid: tous les rails Home sont préparés avant reveal
//  6) PosterGrid: hints hydration progressive (soft contract)
//  7) PosterGrid: hints virtualisation (soft contract)
//  8) Images UI: sourceSize (logo + overlay) + requête avatar dimensionnée -> ClockHUD le fait déjà
//  9) AA: focus-only (et mask en layer.effect sans AA) -> ClockHUD
// 10) Disable anims pendant scroll (topbar y/opacity + boutons)
// 11) Loader dots stop net dès reveal (déjà gate via active)

import QtQuick 2.15

import "../components" as Components
import "../js/SafeLog.js" as SafeLog

FocusScope {
    id: homePage

    width: 1920
    height: 1080
    focus: true

    /* ==== Contexte ==== */
    property string accessToken
    property string userId
    property string serverUrl
    property string userName
    property string userImageTag
    property var    fbx
    property var    shared: null
    property string itemId: ""

    // SÉCURITÉ PUBLICATION :
    // shared.__redefinNavContext transporte temporairement accessToken/serverUrl/userId
    // pour éviter les query strings sensibles. Il doit rester court-vivant et être purgé
    // dès hydratation. Ne jamais exposer shared.__redefinNavContext brut.
    readonly property int navContextMaxAgeMs: 30000

    signal requestLogout()
    signal requestNavigation(string page)

    /* ==== V4 : navigation Accueil / Recherche ==== */
    property int currentHomeTab: 0 // 0 = Accueil, 1 = Recherche

    // Contrat de propriété du focus : PosterGrid ne peut réparer/forcer son focus
    // que lorsque l'utilisateur a explicitement quitté la topbar vers le contenu.
    property bool _posterGridFocusAllowed: true

    function _setPosterGridFocusAllowed(allowed, reason) {
        _posterGridFocusAllowed = (allowed === true)
        var pg = posterGridLoader.item
        if (!pg) return
        try {
            if (pg.hasOwnProperty("focusRepairEnabled"))
                pg.focusRepairEnabled = _posterGridFocusAllowed
            if (!_posterGridFocusAllowed && pg.cancelHomeFocusRepair)
                pg.cancelHomeFocusRepair()
        } catch(e0) {}
    }

    // Lors du retour Recherche -> Accueil, la destruction du Loader peut rendre
    // brièvement le focus à PosterGrid. Ce garde garde l'onglet Accueil maître
    // jusqu'à la fin du tour d'événements, sauf si l'utilisateur demande le contenu.
    property bool _keepHomeTabFocused: false
    property bool _focusSearchContentWhenReady: false
    property bool _focusHomeContentWhenReady: false

    Timer {
        id: homeTabFocusReleaseTimer
        interval: 120
        repeat: false
        onTriggered: homePage._keepHomeTabFocused = false
    }

    function _applyContextToSearchPage() {
        try {
            var sp = searchPageLoader.item
            if (!sp) return false
            sp.accessToken = accessToken
            sp.userId = userId
            sp.serverUrl = serverUrl
            sp.fbx = fbx
            return true
        } catch(e) {
            return false
        }
    }

    function focusSearchContent() {
        var sp = searchPageLoader.item
        if (sp && sp.focusSearchField) {
            sp.focusSearchField()
            return true
        }
        return false
    }

    function focusCurrentTopTab() {
        _focusHomeContentWhenReady = false
        _setPosterGridFocusAllowed(false, "focus-current-tab")
        showTopBar()
        if (currentHomeTab === 1) searchTabBtn.forceActiveFocus()
        else homeTabBtn.forceActiveFocus()
    }

    function activateHomeTab(focusContent) {
        Qt.inputMethod.hide()
        showTopBar()
        _focusSearchContentWhenReady = false

        if (focusContent === true) {
            _keepHomeTabFocused = false
            homeTabFocusReleaseTimer.stop()
            currentHomeTab = 0
            _focusHomeContentWhenReady = true

            // Ne jamais autoriser PosterGrid avant le transfert réel.
            // Même si le loading gate travaille encore, Mes médias est focusable
            // dès que son ListView existe.
            _setPosterGridFocusAllowed(false, "home-tab-content-pending")
            if (leaveTopBarToContent())
                _focusHomeContentWhenReady = false
            return
        }

        _focusHomeContentWhenReady = false
        _keepHomeTabFocused = true
        currentHomeTab = 0
        _setPosterGridFocusAllowed(false, "search-to-home-tab")
        homeTabBtn.forceActiveFocus()
        homeTabFocusReleaseTimer.restart()

        Qt.callLater(function() {
            if (!homePage.visible || homePage._loading || homePage.currentHomeTab !== 0) return
            if (homePage._keepHomeTabFocused) homeTabBtn.forceActiveFocus()
        })
    }

    function activateSearchTab(focusContent) {
        if (_loading) return
        _focusHomeContentWhenReady = false
        _setPosterGridFocusAllowed(false, "search-tab")
        if (currentHomeTab === 0) enterTopBar()
        _focusSearchContentWhenReady = focusContent === true
        currentHomeTab = 1
        showTopBar()
        Qt.callLater(function() {
            if (!homePage.visible || homePage.currentHomeTab !== 1) return
            homePage._applyContextToSearchPage()
            if (homePage._focusSearchContentWhenReady) {
                if (homePage.focusSearchContent())
                    homePage._focusSearchContentWhenReady = false
                else
                    searchTabBtn.forceActiveFocus()
            } else {
                searchTabBtn.forceActiveFocus()
            }
        })
    }

    function _openSearchMovie(itemId) {
        requestNavigation(_navRoute("detailMoviePage.qml", { itemId: itemId }))
    }

    function _openSearchMovieFolder(folderId) {
        requestNavigation(_navRoute("moviepage.qml", { folderId: folderId }))
    }

    function _openSearchSeriesFolder(folderId) {
        requestNavigation(_navRoute("moviepage.qml", { folderId: folderId, libraryMode: "series" }))
    }

    function _openSearchCollection(folderId) {
        requestNavigation(_navRoute("moviepage.qml", { folderId: folderId, libraryMode: "collections" }))
    }

    function _openSearchSeason(seriesId, seasonId, episodeId) {
        requestNavigation(_navRoute("seasonpage.qml", {
            seriesId: seriesId, seasonId: seasonId, preselectEpisodeId: episodeId
        }))
    }

    function _sharedNavApi(){ try { return shared && shared.__redefinNavApi ? shared.__redefinNavApi : null } catch(e) { return null } }
    function _hydrateSensitiveContextFromShared(){
        var api = _sharedNavApi()
        return api && api.hydrate ? api.hydrate(homePage, true, navContextMaxAgeMs, true) : false
    }

    function _storeServerNavContext(){
        var api = _sharedNavApi()
        return api && api.storeServerTarget ? api.storeServerTarget(homePage) : false
    }

    function _navRoute(page, params){
        var api = _sharedNavApi()
        return api && api.route ? api.route(homePage, page, params || ({})) : (page + "?ctx=1")
    }

    function _applyContextToPosterGrid(){
        try {
            var pg = posterGridLoader.item
            if (!pg) {
                return
            }

            pg.accessToken = accessToken
            pg.userId = userId
            pg.serverUrl = serverUrl
            pg.fbx = fbx
            if (pg.hasOwnProperty("shared")) pg.shared = Qt.binding(function(){ return homePage.shared })

            if (accessToken && userId && serverUrl) {
                var key = _homeSessionKey()
                var alreadyWarm = !!(pg.fetchedOnce === true
                                     && pg.libraryFetchCompleted === true
                                     && pg.resumeFetchCompleted === true
                                     && pg.nextUpFetchCompleted === true
                                     && pg.latestFetchCompleted === true)
                try {
                    // Les handlers de contexte de PosterGrid peuvent avoir
                    // restauré le cache juste avant cet appel. Ne relire le
                    // snapshot que si PosterGrid n'est pas déjà terminal/chauffé.
                    if (!alreadyWarm && pg._restoreHomeCacheIfFresh
                            && pg._restoreHomeCacheIfFresh()) {
                        try { if (pg._freezeHomeImagesOnReturn) pg._freezeHomeImagesOnReturn("home-apply-cache") } catch(eFreeze0) {}
                        _finishLoadingFromWarmPosterGrid("home-apply-cache")
                        return
                    }
                } catch(eCache) {}

                // Si PosterGrid est déjà entièrement chaud, ses propres handlers
                // viennent soit de restaurer le cache, soit de terminer un fetch.
                // Ne jamais reprogrammer beginStaggeredFetch() juste parce que
                // HomePage n'avait pas encore enregistré cette sessionKey.
                var shouldAskFetch = !alreadyWarm && ((_lastPosterGridApplyKey !== key) || !pg.fetchedOnce)
                try { if (!alreadyWarm && !shouldAskFetch && pg._dataEmpty && pg._dataEmpty()) shouldAskFetch = true } catch(e0) {}
                _lastPosterGridApplyKey = key

                if (alreadyWarm && !shouldAskFetch)

                if (shouldAskFetch) {
                    var now = _nowMs()
                    if (_posterFetchAskKey === key && (now - _posterFetchAskAtMs) < posterFetchAskCooldownMs) {
                        return
                    }
                    if (pg._fetchInFlight === true) {
                        return
                    }

                    _posterFetchAskKey = key
                    _posterFetchAskAtMs = now

                    if (pg.beginStaggeredFetch && typeof pg.beginStaggeredFetch === "function") {
                        pg.beginStaggeredFetch()
                    } else if (pg.fetchHomeData && typeof pg.fetchHomeData === "function") {
                        pg.fetchHomeData()
                    } else {
                    }
                }
            }
        } catch(e) {
        }
    }

    // ✅ Hook appelé par ClockHUD (ou par signal) pour focus Settings
    function requestFocusSettings() {
        if (homePage._loading) return
        showTopBar()
        enterTopBar()
        if (settingsBtn) settingsBtn.forceActiveFocus()
    }

    Rectangle { anchors.fill: parent; color: "#000" }

    /* ============================================================
       LOADING GATE (anti “HomePage qui se construit sous tes yeux”)
       ============================================================ */
    property bool _loading: true
    readonly property bool shellLoading: _loading
    readonly property string shellLoadingError: ""

    // Retour de navigation externe vers l'onglet Accueil.
    // Search <-> Accueil ne modifie pas HomePage.visible et reste donc instantané.
    property bool _externalReturnArmed: false
    property bool _waitForHomePosters: false
    property bool _homeVisualReturnPrepared: false

    // Injecté par ShellPage uniquement lors d'un retour vers HomePage depuis
    // une page de contenu. Le démarrage initial conserve le gate complet.
    property bool fastHomeReturn: false

    property int  minLoadingMs: 900
    property int  settleMs: 450
    property int  afterFetchedOnceMinMs: 900
    property int  maxLoadingMs: 12000
    // Si le timeout global est atteint, on donne d'abord à PosterGrid une courte
    // fenêtre pour terminer proprement son reveal. Le hard fallback ci-dessous
    // n'est utilisé que si même cette remise en cohérence échoue.
    readonly property int gateHardRecoveryMs: 1800
    readonly property int fastReturnSettleMs: 40
    property bool _homeInitialFocusDone: false
    property bool _homeUserTookControl: false
    property bool _homeApplyingInitialFocus: false
    property string _homeBootKey: ""
    property string _lastPosterGridApplyKey: ""

    property double _loadingStartMs: 0
    property double _lastChangeMs: 0
    property double _fetchedOnceAtMs: 0

    // Anti-retour Home : ne pas redemander un fetch PosterGrid pour la même
    // session si un fetch vient déjà d'être demandé. Le vrai cooldown Latest
    // reste côté jellyfinBridge.js, celui-ci évite seulement les doubles coups
    // completed/visible/loader.
    property string _posterFetchAskKey: ""
    property double _posterFetchAskAtMs: 0
    readonly property int posterFetchAskCooldownMs: 15000
    readonly property int posterImageSettleMs: 240

    // “touch” = on a bien reçu/assigné les sections (même vides)
    property bool _touchLib: false
    property bool _touchResume: false
    property bool _touchNextUp: false
    property bool _touchLatest: false

    function _nowMs() { return Date.now(); }

    // Initialise le chrono du gate avant toute tentative de fermeture "warm".
    // HomePage naît avec _loading=true mais _loadingStartMs=0 : un cache chaud
    // peut donc être détecté avant beginLoadingGate(), ce qui produisait
    // Date.now()-0 et court-circuitait artificiellement tous les délais.
    function _ensureLoadingGateClock() {
        if (!_loading) return _nowMs()
        var now = _nowMs()
        var start = Number(_loadingStartMs || 0)
        if (!isFinite(start) || isNaN(start) || start <= 0 || start > now) {
            _loadingStartMs = now
            if (!(Number(_lastChangeMs || 0) > 0) || _lastChangeMs > now)
                _lastChangeMs = now
        }
        return now
    }


    function _homeSessionKey() {
        // SÉCURITÉ : ne jamais conserver serverUrl|userId|accessToken en clair
        // dans les clés mémoire (_homeBootKey, _lastPosterGridApplyKey, _posterFetchAskKey).
        return "home#" + SafeLog.shortHash(String(serverUrl || "") + "|" +
                                    String(userId || "") + "|" +
                                    String(accessToken || ""))
    }

    function _scheduleHomeFocusRelease() {
        // PosterGrid est déjà rendu derrière l'overlay noir. Au reveal, on garde
        // le focus restauré au lieu de repasser brièvement par la première tuile.
        _homeApplyingInitialFocus = true
        Qt.callLater(function () {
            if (!homePage.visible) return

            // Un Bas/OK peut avoir été envoyé pendant le loading gate avant
            // que le premier rail soit matérialisé. Dans ce cas, retenter le
            // transfert demandé par l'utilisateur avant toute logique initiale.
            if (homePage.currentHomeTab === 0
                    && homePage._focusHomeContentWhenReady) {
                if (homePage.leaveTopBarToContent()) {
                    homePage._homeApplyingInitialFocus = false
                    return
                }
            }

            // Tant que la topbar est propriétaire, le gate ne peut jamais
            // réactiver PosterGrid de lui-même.
            if (homePage.currentHomeTab !== 0
                    || homePage._posterGridFocusAllowed !== true) {
                homePage._homeApplyingInitialFocus = false
                return
            }

            homePage._setPosterGridFocusAllowed(true, "home-focus-release")
            var pg = posterGridLoader.item
            var revealReady = !!(pg && pg.homeRevealReady === true)
            var alreadyFocused = false
            try { alreadyFocused = !!(pg && pg._hasAnyHomeListFocus && pg._hasAnyHomeListFocus()) } catch(e0) {}

            if (revealReady) {
                _homeInitialFocusDone = true
                if (!alreadyFocused) {
                    try { if (pg.forceFocus) pg.forceFocus() } catch(e1) {}
                }

                // Ne jamais forcer la topbar visible après une restauration basse.
                // PosterGrid a déjà restauré focusSection et contentY : on recale
                // immédiatement le chrome Home sur cet état, puis une seconde fois
                // après le court settle du focus.
                _syncTopBarToGridState()
                initialFocusReleaseTimer.restart()
                return
            }

            // Aucun snapshot prêt : l'écran démarre en haut et la topbar peut
            // rester visible pendant le premier placement de focus.
            showTopBar()
            try { homePage.forceActiveFocus() } catch(e2) {}
            firstFocusNudge.restart()
        })
    }

    function _prepareHomePosterReturn(reason) {
        if (!_waitForHomePosters || currentHomeTab !== 0)
            return true

        var pg = posterGridLoader.item
        if (!pg) return false

        if (!_homeVisualReturnPrepared) {
            _homeVisualReturnPrepared = true
            try {
                if (pg.prepareHomeVisualReturn)
                    pg.prepareHomeVisualReturn(reason || "home-external-return")
                else if (pg._freezeHomeImagesOnReturn)
                    pg._freezeHomeImagesOnReturn(reason || "home-external-return")
            } catch(e0) {}
        }

        try {
            if (pg.homePosterVisualReady !== undefined)
                return pg.homePosterVisualReady === true
        } catch(e1) {}

        try {
            if (pg._homeImageReturnFreeze !== undefined)
                return pg._homeImageReturnFreeze !== true
        } catch(e2) {}

        return true
    }

    function _preparePosterGridForReveal(reason) {
        var pg = posterGridLoader.item
        if (!pg) return false
        try {
            if (pg.prepareHomeReveal)
                pg.prepareHomeReveal(reason || "home-gate")
        } catch(e0) {}
        try {
            if (pg.homeRevealReady !== undefined)
                return pg.homeRevealReady === true
        } catch(e1) {}
        try {
            if (pg.hasPendingFocusRestore && pg.hasPendingFocusRestore())
                return false
        } catch(e2) {}
        return true
    }

    function _activateFastHomeReturn() {
        if (!fastHomeReturn) return

        if (currentHomeTab === 0) {
            _waitForHomePosters = true
            _homeVisualReturnPrepared = false
        }

        // Le retour peut réutiliser une HomePage déjà créée et donc _loading=false.
        // On réarme immédiatement l'overlay avant toute restauration de ListView.
        _loading = true
        _homeInitialFocusDone = false
        _homeUserTookControl = false
        _homeApplyingInitialFocus = true

        var now = _nowMs()
        _loadingStartMs = now
        _lastChangeMs = now - fastReturnSettleMs
        if (!gateMaxTimer.running) gateMaxTimer.restart()

        var pg = posterGridLoader.item
        if (pg && pg.fetchedOnce === true && pg.latestFetchCompleted === true) {
            if (_finishLoadingFromWarmPosterGrid("shell-fast-return"))
                return
        }

        // La propriété est injectée après création de la page. Le contexte et
        // PosterGrid peuvent finir leur hydratation dans le même tour d'event loop.
        Qt.callLater(function () {
            if (!homePage.fastHomeReturn || !homePage._loading) return
            var warm = posterGridLoader.item
            try {
                // Si PosterGrid a déjà été restauré par ses propres handlers de
                // contexte/visibilité, ne relire surtout pas le même cache.
                if (warm && warm.fetchedOnce === true && warm.latestFetchCompleted === true) {
                    try { if (warm._freezeHomeImagesOnReturn) warm._freezeHomeImagesOnReturn("home-fast-return") } catch(eFreeze0) {}
                    if (homePage._finishLoadingFromWarmPosterGrid("shell-fast-return-ready"))
                        return
                }

                // Le cache n'est relu ici qu'en dernier recours, lorsque le
                // PosterGrid n'est pas encore chaud.
                if (warm && warm._restoreHomeCacheIfFresh && warm._restoreHomeCacheIfFresh()) {
                    try { if (warm._freezeHomeImagesOnReturn) warm._freezeHomeImagesOnReturn("home-fast-return") } catch(eFreeze) {}
                    if (homePage._finishLoadingFromWarmPosterGrid("shell-fast-return-cache"))
                        return
                }
            } catch(eCache) {}
            homePage.tryFinishGate()
        })
    }

    onFastHomeReturnChanged: {
        if (fastHomeReturn)
            _activateFastHomeReturn()
    }

    function beginLoadingGate() {
        var key = _homeSessionKey()
        var pg = posterGridLoader.item
        if (pg && pg.fetchedOnce === true && pg.latestFetchCompleted === true) {
            _homeBootKey = key
            if (_finishLoadingFromWarmPosterGrid("begin-warm"))
                return
        }
        if (_homeBootKey === key && !_loading && pg && pg.fetchedOnce)
            return

        if (_homeBootKey !== key) {
            _homeBootKey = key
            _homeInitialFocusDone = false
            _homeUserTookControl = false
            _homeApplyingInitialFocus = false
        }
        _loading = true;
        _loadingStartMs = _nowMs();
        _lastChangeMs = _loadingStartMs;
        _fetchedOnceAtMs = 0;

        _touchLib = false;
        _touchResume = false;
        _touchNextUp = false;
        _touchLatest = false;

        gateHardRecoveryTimer.stop();
        gateSettleTimer.restart();
        gateMaxTimer.restart();
    }

    function pokeLoadingGate() {
        _lastChangeMs = _nowMs();
        gateSettleTimer.restart();
    }

    function _canFinishGate() {
        var pg = posterGridLoader.item;
        if (!pg) {  return false; }

        // Jamais avant 1er fetch “confirmé”
        if (!pg.fetchedOnce) {  return false; }

        if (_fetchedOnceAtMs === 0) {
            _fetchedOnceAtMs = _nowMs();
        }

        if (pg.libraryFetchCompleted !== true) {  return false; }
        if (pg.resumeFetchCompleted !== true) {  return false; }
        if (pg.nextUpFetchCompleted !== true) {  return false; }
        if (pg.latestFetchCompleted !== true) {  return false; }

        if (!_preparePosterGridForReveal(fastHomeReturn ? "fast-return" : "initial")) {
            return false
        }

        if (_waitForHomePosters
                && !_prepareHomePosterReturn(fastHomeReturn ? "fast-return-posters"
                                                            : "external-return-posters")) {
            return false
        }

        var now = _nowMs();
        var minGate = fastHomeReturn ? 0 : minLoadingMs
        var fetchedGate = fastHomeReturn ? 0 : afterFetchedOnceMinMs
        var stableGate = fastHomeReturn ? fastReturnSettleMs : settleMs
        if ((now - _loadingStartMs) < minGate) {  return false; }
        if ((now - _fetchedOnceAtMs) < fetchedGate) {  return false; }
        if ((now - _lastChangeMs) < stableGate) {  return false; }

        return true;
    }

    function tryFinishGate() {
        if (!_loading) {
            return;
        }

        if (_canFinishGate()) {
            _waitForHomePosters = false
            _homeVisualReturnPrepared = false
            _loading = false;
            gateMaxTimer.stop();
            gateHardRecoveryTimer.stop();

            _scheduleHomeFocusRelease();
        } else {
            gateSettleTimer.restart();
        }
    }

    function _finishLoadingFromWarmPosterGrid(reason) {
        try {
            var pg = posterGridLoader.item
            if (!pg || pg.fetchedOnce !== true)
                return false

            // Retour Home depuis cache postergrid : aucune section ne change forcément,
            // donc les signaux onLibraryItemsChanged/onResumeItemsChanged/etc. peuvent
            // ne pas repasser. On marque le gate comme satisfait seulement si postergrid
            // confirme que le bootstrap Home est déjà terminé.
            if (pg.latestFetchCompleted !== true)
                return false

            // Le chemin cache chaud peut arriver avant beginLoadingGate().
            // Toujours poser une origine de temps valide avant tryFinishGate().
            _ensureLoadingGateClock()

            _touchLib = true
            _touchResume = true
            _touchNextUp = true
            _touchLatest = true

            // Cache chaud = données déjà stables. On court-circuite les délais initiaux
            // pour éviter le loader cercle long au retour arrière.
            var now = _nowMs()
            _fetchedOnceAtMs = now - afterFetchedOnceMinMs
            _lastChangeMs = now - settleMs

            var pendingVisualRestore = false
            try { pendingVisualRestore = !!(pg.hasPendingFocusRestore && pg.hasPendingFocusRestore()) } catch(ePending) {}
            if (pendingVisualRestore && !_loading) {
                _loading = true
                _loadingStartMs = _nowMs()
            }

            if (_loading) {
                // Ne jamais révéler directement ici. Le cache peut être prêt alors
                // que ListView est encore à index 0 et contentY 0. On prépare le
                // focus derrière l'overlay puis tryFinishGate attend homeRevealReady.
                _preparePosterGridForReveal(reason || "warm-postergrid")
                if (!gateMaxTimer.running) gateMaxTimer.restart()
                gateSettleTimer.restart()
                tryFinishGate()
            }

            return true
        } catch(e) {
            return false
        }
    }

    Timer {
        id: gateSettleTimer
        interval: homePage.fastHomeReturn ? homePage.fastReturnSettleMs : homePage.settleMs
        repeat: false
        onTriggered: homePage.tryFinishGate()
    }

    Timer {
        id: gateMaxTimer
        interval: homePage.maxLoadingMs
        repeat: false
        onTriggered: {
            homePage._waitForHomePosters = false
            homePage._homeVisualReturnPrepared = false

            // Ne plus retirer brutalement le curtain avec PosterGrid encore en
            // état bootstrap. On transforme d'abord toutes les sections pendantes
            // en état terminal, puis on laisse le reveal/focus se stabiliser.
            var pg = posterGridLoader.item
            try {
                if (pg && pg.forceHomeBootstrapCompletion)
                    pg.forceHomeBootstrapCompletion("home-gate-timeout")
                else if (pg && pg.prepareHomeReveal)
                    pg.prepareHomeReveal("home-gate-timeout")
            } catch(e0) {
            }

            homePage._lastChangeMs = homePage._nowMs() - homePage.settleMs
            gateSettleTimer.restart()
            gateHardRecoveryTimer.restart()
        }
    }

    Timer {
        id: gateHardRecoveryTimer
        interval: homePage.gateHardRecoveryMs
        repeat: false
        onTriggered: {
            if (!homePage._loading) return
            var pg = posterGridLoader.item
            try {
                if (pg && pg.forceHomeBootstrapCompletion)
                    pg.forceHomeBootstrapCompletion("home-gate-hard-timeout")
                if (pg && pg.forceHomeRevealReady)
                    pg.forceHomeRevealReady("home-gate-hard-timeout")
            } catch(e0) {
            }
            homePage._waitForHomePosters = false
            homePage._homeVisualReturnPrepared = false
            homePage._loading = false
            homePage._scheduleHomeFocusRelease()
        }
    }

    /* ==== Scroll / moving gate (pour couper anims pendant scroll) ==== */
    property var _gridFlick: null
    function _bindGridFlick() {
        var pg = posterGridLoader.item;
        if (pg && pg.vFlick) _gridFlick = pg.vFlick;
    }
    readonly property bool _scrollingEff: !!(
        _gridFlick && ((_gridFlick.moving === true) || (_gridFlick.dragging === true))
    )

    /* ——— Coupe le zoom du grid quand on remonte en haut ——— */
    // 0: Bibliothèque, 1: Continuer, 2: À suivre, 3: Ajouts récents
    property int lastContentSection: 0
    function _markHomeUserControl() {
        if (_loading || _homeApplyingInitialFocus) return
        _homeUserTookControl = true
    }
    function _clearPosterGridFocusMemory(reason) {
        try { if (posterGridLoader.item && posterGridLoader.item.clearFocusSnapshot) posterGridLoader.item.clearFocusSnapshot(reason || "home-clear") } catch(e0) {}
        try {
            if (shared && shared.__redefinFocus) {
                for (var k in shared.__redefinFocus) {
                    if (String(k).indexOf("postergrid.home|") === 0) delete shared.__redefinFocus[k]
                }
            }
        } catch(e1) {}
        _homeInitialFocusDone = false
        _homeUserTookControl = false
        _homeApplyingInitialFocus = false
    }

    function enterTopBar() {
        var pg = posterGridLoader.item

        if (currentHomeTab === 0 && pg) {
            if (pg.focusSection >= 0) {
                lastContentSection = pg.focusSection

                // Sauvegarder AVANT focusSection=-1 : cette transition est aussi
                // utilisée pour Accueil -> Recherche et ne détruit pas HomePage.
                try {
                    if (pg.saveFocusSnapshot)
                        pg.saveFocusSnapshot("home-topbar-transition", true)
                } catch(e0) {}
            }

            _setPosterGridFocusAllowed(false, "enter-topbar")
            pg.focusSection = -1
        } else {
            _setPosterGridFocusAllowed(false, "enter-topbar")
        }

        showTopBar()
    }

    function leaveTopBarToContent(section) {
        if (currentHomeTab === 1) {
            _focusHomeContentWhenReady = false
            _setPosterGridFocusAllowed(false, "search-content")
            focusSearchContent()
            return true
        }

        var pg = posterGridLoader.item
        if (!pg) {
            _setPosterGridFocusAllowed(false, "leave-topbar-no-grid")
            return false
        }

        var s = (section === undefined || section === null)
                ? lastContentSection
                : section
        s = Math.max(0, Math.min(3, s))

        // Si le rail mémorisé n'existe pas encore, utiliser le premier rail
        // réellement disponible. Sinon la topbar reste propriétaire du focus.
        try {
            if (pg._sectionHasContent && !pg._sectionHasContent(s)) {
                if (pg._nearestSection)
                    s = pg._nearestSection(-1, 1)
            }
        } catch(e0) {}
        if (s < 0) {
            _setPosterGridFocusAllowed(false, "leave-topbar-no-content")
            return false
        }

        var localTopBarHandoff = (_posterGridFocusAllowed !== true)

        if (localTopBarHandoff) {
            try {
                if (pg.consumeFocusSnapshotKeepState)
                    pg.consumeFocusSnapshotKeepState()
            } catch(e1) {}
        } else {
            try {
                if (pg.hasPendingFocusRestore
                        && pg.hasPendingFocusRestore()
                        && pg.restoreFocusSnapshot) {
                    if (pg.restoreFocusSnapshot())
                        return true
                }
            } catch(e2) {}
        }

        // Le droit au focus n'est accordé qu'au dernier moment. Il n'existe
        // donc plus de fenêtre où Accueil et un poster peuvent sembler focusés
        // simultanément.
        _setPosterGridFocusAllowed(true, "leave-topbar-to-content")
        pg.focusSection = s

        var focused = false
        try {
            focused = pg.forceFocus ? pg.forceFocus() === true : false
        } catch(e3) {}

        if (!focused) {
            _setPosterGridFocusAllowed(false, "leave-topbar-focus-failed")
            homeTabBtn.forceActiveFocus()
            return false
        }

        _focusHomeContentWhenReady = false
        return true
    }

    /* ==== Focus initial : pousser vers la 1ère tuile de Bibliothèque ==== */
    function focusGridFirst() {
        if (homePage._loading) return;
        _setPosterGridFocusAllowed(true, "initial-grid-focus")
        if (_homeInitialFocusDone || _homeUserTookControl) return;
        var pg = posterGridLoader.item;
        if (!pg) return;
        _homeInitialFocusDone = true;
        _homeApplyingInitialFocus = true;
        if (pg.hasPendingFocusRestore
                && pg.hasPendingFocusRestore()
                && pg.restoreFocusSnapshot) {
            if (pg.restoreFocusSnapshot()) {
                initialFocusReleaseTimer.restart()
                return
            }
        }
        if (pg.forceFirstFocus) { pg.forceFirstFocus(); initialFocusReleaseTimer.restart(); return; }
        pg.focusSection = 0;
        if (pg.currentFolderIndex !== undefined) pg.currentFolderIndex = 0;
        Qt.callLater(function () {
            if (homePage._loading || homePage._homeUserTookControl) return;
            if (pg.forceFocus) pg.forceFocus();
            else if (pg.forceActiveFocus) pg.forceActiveFocus();
            initialFocusReleaseTimer.restart();
        });
    }

    Timer {
        id: firstFocusNudge
        interval: 1
        repeat: false
        onTriggered: {
            if (homePage._loading) { restart(); return; }
            if (homePage._homeInitialFocusDone || homePage._homeUserTookControl) return;
            focusGridFirst();
        }
    }
    Timer {
        id: initialFocusReleaseTimer
        interval: 180
        repeat: false
        onTriggered: {
            homePage._homeApplyingInitialFocus = false
            homePage._syncTopBarToGridState()
        }
    }

    /* ==== PERF HINTS (soft contract vers postergrid.qml) ==== */
    readonly property var perfHints: ({
        // Tweaks 5/6/7 (si postergrid les supporte)
        staggerSections: false,
        staggerMs: 0,
        progressiveHydration: true,
        initialSlice: 10,
        hydrateAfterMs: 650,
        enableVirtualization: true,
        cacheBufferPx: Math.round(homePage.height * 1.15)
    })

    /* ==== Contenu principal (postergrid) ==== */
    Loader {
        id: posterGridLoader
        source: "postergrid.qml"
        anchors.fill: parent

        // Toujours rendu derrière loadingOverlay (opaque, z 5000). Ainsi les
        // ListView peuvent restaurer focus/contentY sans exposer leur trajet visuel.
        visible: opacity > 0.01
        enabled: homePage.currentHomeTab === 0
        opacity: homePage.currentHomeTab === 0 ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 145; easing.type: Easing.OutCubic } }

        property string accessToken: homePage.accessToken
        property string userId: homePage.userId
        property string serverUrl: homePage.serverUrl
        property var    fbx: homePage.fbx

        onLoaded: {
            if (!item) return;

            item.accessToken   = accessToken;
            item.userId        = userId;
            item.serverUrl     = serverUrl;
            item.fbx           = fbx;
            if (item.hasOwnProperty("shared")) item.shared = Qt.binding(function(){ return homePage.shared; });
            if (item.hasOwnProperty("focusRepairEnabled"))
                item.focusRepairEnabled = Qt.binding(function(){
                    return homePage._posterGridFocusAllowed && homePage.currentHomeTab === 0
                });
            // Retour Recherche -> Accueil instantané : PosterGrid reste chaud
            // derrière SearchPage, y compris ses textures déjà chargées.
            if (item.hasOwnProperty("suspendVisualTextures"))
                item.suspendVisualTextures = false;
            homePage._applyContextToPosterGrid()
            if (homePage._waitForHomePosters && homePage.currentHomeTab === 0)
                homePage._prepareHomePosterReturn("postergrid-loaded-return")

            // bind flick pour scroll gate
            homePage._bindGridFlick();

            // Tweak 5/6/7: perf hints (si supporté)
            try {
                if (item.hasOwnProperty("perfHints")) item.perfHints = homePage.perfHints;
                if (item.hasOwnProperty("staggerSections")) item.staggerSections = false;
                if (item.hasOwnProperty("staggerMs")) item.staggerMs = 0;
                if (item.hasOwnProperty("progressiveHydration")) item.progressiveHydration = true;
                if (item.hasOwnProperty("initialSlice")) item.initialSlice = homePage.perfHints.initialSlice;
                if (item.hasOwnProperty("enableVirtualization")) item.enableVirtualization = true;
                if (item.hasOwnProperty("cacheBufferPx")) item.cacheBufferPx = homePage.perfHints.cacheBufferPx;
                if (item.hasOwnProperty("debugLogs")) item.debugLogs = false;
                if (item.hasOwnProperty("homeImageSettleMs")) item.homeImageSettleMs = homePage.posterImageSettleMs;
                if (item.hasOwnProperty("homeImageReturnFreezeMs")) item.homeImageReturnFreezeMs = 240;
                if (item.hasOwnProperty("homeCurtainVisible")) item.homeCurtainVisible = Qt.binding(function(){
                    return homePage._loading
                });
                // Ne pas relancer ici : _applyContextToPosterGrid() orchestre déjà
                // le fetch et postergrid restaure son cache Home si disponible.
            } catch (e) {}

            homePage.pokeLoadingGate();

            function savePosterGridFocus(reason, exclusiveRailMemory) {
                try {
                    if (!item) return

                    if (exclusiveRailMemory === true
                            && item.saveExclusiveRailFocusSnapshot) {
                        item.saveExclusiveRailFocusSnapshot(reason || "navigate-container")
                        return
                    }

                    if (item.saveFocusSnapshotForce)
                        item.saveFocusSnapshotForce(reason || "navigate")
                    else if (item.saveFocusSnapshot)
                        item.saveFocusSnapshot(reason || "navigate", true)
                } catch(e) {}
            }

            if (item.requestBackToMenu) {
                item.requestBackToMenu.connect(function () {
                    if (item.vFlick && item.vFlick.contentY !== undefined) item.vFlick.contentY = 0;
                    homePage._setPosterGridFocusAllowed(false, "postergrid-back-to-menu");
                    enterTopBar();
                    homeTabBtn.forceActiveFocus();
                });
            }

            if (item.requestMoviePage) {
                item.requestMoviePage.connect(function(folderId) {
                    savePosterGridFocus("nav-moviepage", true);
                    homePage.requestNavigation(homePage._navRoute("moviepage.qml", { folderId: folderId }));
                });
            }

            if (item.requestPersonalMediaPage) {
                item.requestPersonalMediaPage.connect(function(folderId, preselectItemId) {
                    savePosterGridFocus("nav-personalmedia", true);
                    homePage.requestNavigation(homePage._navRoute("PersonalMediaPage.qml", { folderId: folderId, itemId: preselectItemId }));
                });
            }

            if (item.requestSeriesPage) {
                item.requestSeriesPage.connect(function(folderId, libraryMode) {
                    savePosterGridFocus("nav-mediapage", true);
                    homePage.requestNavigation(homePage._navRoute("moviepage.qml", { folderId: folderId, libraryMode: libraryMode || "series" }));
                });
            }

            // ✅ NEW: Collections (BoxSets)
            if (item.requestCollectionPage) {
                item.requestCollectionPage.connect(function(folderId) {
                    savePosterGridFocus("nav-collections", true);
                    homePage.requestNavigation(homePage._navRoute("moviepage.qml", { folderId: folderId, libraryMode: "collections" }));
                });
            }

            if (item.requestDetailMovie) {
                item.requestDetailMovie.connect(function(movieId) {
                    savePosterGridFocus("nav-detailmovie", true);
                    homePage.requestNavigation(homePage._navRoute("detailMoviePage.qml", { itemId: movieId }));
                });
            }

            if (item.requestSeasonPage) {
                item.requestSeasonPage.connect(function(seriesId, seasonId, episodeId) {
                    savePosterGridFocus("nav-seasonpage", true);
                    homePage.requestNavigation(homePage._navRoute("seasonpage.qml", { seriesId: seriesId, seasonId: seasonId, preselectEpisodeId: episodeId }));
                });
            }
        }
    }

    /* ==== V4 : SearchPage chargée uniquement lorsque l’onglet est actif ==== */
    Loader {
        id: searchPageLoader
        anchors.fill: parent
        z: 100
        source: "SearchPage.qml"
        active: homePage.currentHomeTab === 1
        asynchronous: true
        visible: active && status === Loader.Ready
        enabled: visible

        onLoaded: {
            if (!item) return
            homePage._applyContextToSearchPage()

            if (item.requestTopBar) item.requestTopBar.connect(function() {
                homePage.showTopBar()
                searchTabBtn.forceActiveFocus()
            })
            if (item.requestHome) item.requestHome.connect(function() {
                homePage.activateHomeTab(false)
            })
            if (item.requestDetailMovie) item.requestDetailMovie.connect(function(itemId) {
                homePage._openSearchMovie(itemId)
            })
            if (item.requestMoviePage) item.requestMoviePage.connect(function(folderId) {
                homePage._openSearchMovieFolder(folderId)
            })
            if (item.requestSeriesPage) item.requestSeriesPage.connect(function(folderId) {
                homePage._openSearchSeriesFolder(folderId)
            })
            if (item.requestCollectionPage) item.requestCollectionPage.connect(function(folderId) {
                homePage._openSearchCollection(folderId)
            })
            if (item.requestSeasonPage) item.requestSeasonPage.connect(function(seriesId, seasonId, episodeId) {
                homePage._openSearchSeason(seriesId, seasonId, episodeId)
            })

            Qt.callLater(function() {
                if (homePage.currentHomeTab !== 1 || !searchPageLoader.item) return
                if (homePage._focusSearchContentWhenReady) {
                    if (homePage.focusSearchContent())
                        homePage._focusSearchContentWhenReady = false
                    else
                        searchTabBtn.forceActiveFocus()
                } else {
                    searchTabBtn.forceActiveFocus()
                }
            })
        }
        onActiveChanged: {
            if (!active) {
                Qt.inputMethod.hide()
                if (homePage._keepHomeTabFocused && homePage.currentHomeTab === 0)
                    homePage._setPosterGridFocusAllowed(false, "search-loader-destroyed")
                if (homePage._keepHomeTabFocused && homePage.currentHomeTab === 0) {
                    Qt.callLater(function() {
                        if (homePage._keepHomeTabFocused && homePage.currentHomeTab === 0)
                            homeTabBtn.forceActiveFocus()
                    })
                }
            }
        }
    }

    FocusScope {
        id: searchLoadCurtain
        anchors.fill: parent
        z: 900
        visible: homePage.currentHomeTab === 1 && searchPageLoader.status === Loader.Loading
        enabled: visible
        focus: visible
        Rectangle { anchors.fill: parent; color: "#000000" }
        Components.CircleDotsLoader {
            anchors.centerIn: parent
            width: 64
            height: 64
            active: parent.visible
        }
        onVisibleChanged: if (visible) forceActiveFocus(Qt.OtherFocusReason)
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: {
            if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape || event.key === Qt.Key_Left)
                homePage.activateHomeTab(false)
            event.accepted = true
        }
        Keys.onReleased: event.accepted = true
    }

    Rectangle {
        anchors.fill: parent
        z: 101
        visible: homePage.currentHomeTab === 1 && searchPageLoader.status === Loader.Error
        color: "#000000"

        Column {
            anchors.centerIn: parent
            spacing: 14

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Impossible de charger SearchPage.qml"
                color: "#ffffff"
                font.pixelSize: 30
                font.bold: true
                textFormat: Text.PlainText
            }
        }
    }

    /* ==== Barre supérieure — overlay sans fond ==== */
    FocusScope {
        id: topBar
        z: 1000
        width: parent.width
        height: Math.max(80, rightRow.implicitHeight + 16)
        anchors.top: parent.top
        y: 0
        opacity: homePage._loading ? 0.0 : 1.0
        visible: !homePage._loading

        // Tweak 10: disable anims pendant scroll
        Behavior on y {
            enabled: !homePage._scrollingEff
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
        Behavior on opacity {
            enabled: !homePage._scrollingEff
            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }

        function show() { topBar.y = 0; topBar.opacity = 1.0; }
        function hide() { topBar.y = -height; topBar.opacity = 0.0; }
        readonly property bool shown: (topBar.opacity > 0.08 && topBar.y === 0)

        /* Logo */
        Image {
            id: redefinLogo
            source: "../images/Redefin-logo2-512.png"
            anchors.left: parent.left
            anchors.leftMargin: -75
            anchors.verticalCenter: parent.verticalCenter
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: true
            // Logo UI: interpolation activée pour éviter le rendu pixelisé
            // lors du scale Freebox/TV. Mipmap coupé: gain GPU/RAM léger sur Freebox.
            smooth: true
            mipmap: false
            height: 100
            width: 324
            sourceSize.width: Math.round(width * 2)
            sourceSize.height: Math.round(height * 2)
            MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: homeTabBtn.forceActiveFocus() }
        }

        /* Onglets V4 centrés — capsule compacte avec focus explicite */
        Item {
            id: homeTabsBar
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: homeTabsRow.implicitWidth
            height: 50

            readonly property Item selectedTab: homePage.currentHomeTab === 0
                                                ? homeTabBtn
                                                : searchTabBtn
            readonly property bool selectedTabHasFocus: selectedTab && selectedTab.activeFocus

            // État sélectionné : capsule sombre conservée lorsque le contenu possède
            // le focus. État focalisé : capsule sensiblement plus claire afin que le
            // D-Pad indique immédiatement que l'utilisateur est revenu sur l'onglet.
            Rectangle {
                id: activeHomeTabCapsule
                x: homeTabsRow.x + homeTabsBar.selectedTab.x
                y: Math.round((homeTabsBar.height - height) / 2)
                width: homeTabsBar.selectedTab.width
                height: 44
                radius: height / 2
                color: homeTabsBar.selectedTabHasFocus ? "#747474" : "#454545"
                border.width: 0
                antialiasing: true
                z: 0

                Behavior on x {
                    enabled: !homePage._scrollingEff
                    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                }
                Behavior on width {
                    enabled: !homePage._scrollingEff
                    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                }
                Behavior on color {
                    ColorAnimation { duration: 110 }
                }
            }

            Row {
                id: homeTabsRow
                anchors.centerIn: parent
                spacing: 6
                z: 1

                FocusScope {
                    id: homeTabBtn
                    width: Math.max(138, homeTabLabel.paintedWidth + 38)
                    height: 44
                    activeFocusOnTab: true

                    Text {
                        id: homeTabLabel
                        anchors.centerIn: parent
                        text: "Accueil"
                        color: homeTabBtn.activeFocus ? "#ffffff"
                              : (homePage.currentHomeTab === 0 ? "#f0f0f0" : "#9b9b9b")
                        opacity: homeTabBtn.activeFocus ? 1.0
                                 : (homePage.currentHomeTab === 0 ? 0.94 : 0.78)
                        font.pixelSize: 22
                        font.bold: homePage.currentHomeTab === 0 || homeTabBtn.activeFocus
                        textFormat: Text.PlainText
                        renderType: Text.NativeRendering

                        Behavior on color { ColorAnimation { duration: 110 } }
                        Behavior on opacity { NumberAnimation { duration: 110 } }
                    }

                    Keys.onPressed: {
                        if (event.key === Qt.Key_Right) {
                            homePage.activateSearchTab(false)
                            event.accepted = true
                        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return ||
                                   event.key === Qt.Key_Enter || event.key === Qt.Key_Select ||
                                   event.key === Qt.Key_Ok) {
                            homePage.activateHomeTab(true)
                            event.accepted = true
                        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                            event.accepted = true
                        }
                    }

                    onActiveFocusChanged: {
                        if (activeFocus) {
                            homePage.currentHomeTab = 0
                            homePage.enterTopBar()
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: {
                            homePage.currentHomeTab = 0
                            homePage.enterTopBar()
                            homeTabBtn.forceActiveFocus()
                        }
                        onClicked: homePage.activateHomeTab(true)
                    }
                }

                FocusScope {
                    id: searchTabBtn
                    width: Math.max(168, searchTabLabel.paintedWidth + 38)
                    height: 44
                    activeFocusOnTab: true

                    Text {
                        id: searchTabLabel
                        anchors.centerIn: parent
                        text: "Recherche"
                        color: searchTabBtn.activeFocus ? "#ffffff"
                              : (homePage.currentHomeTab === 1 ? "#f0f0f0" : "#9b9b9b")
                        opacity: searchTabBtn.activeFocus ? 1.0
                                 : (homePage.currentHomeTab === 1 ? 0.94 : 0.78)
                        font.pixelSize: 22
                        font.bold: homePage.currentHomeTab === 1 || searchTabBtn.activeFocus
                        textFormat: Text.PlainText
                        renderType: Text.NativeRendering

                        Behavior on color { ColorAnimation { duration: 110 } }
                        Behavior on opacity { NumberAnimation { duration: 110 } }
                    }

                    Keys.onPressed: {
                        if (event.key === Qt.Key_Left) {
                            homePage.activateHomeTab(false)
                            event.accepted = true
                        } else if (event.key === Qt.Key_Right) {
                            settingsBtn.forceActiveFocus()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return ||
                                   event.key === Qt.Key_Enter || event.key === Qt.Key_Select ||
                                   event.key === Qt.Key_Ok) {
                            homePage.activateSearchTab(true)
                            event.accepted = true
                        } else if (event.key === Qt.Key_Up) {
                            event.accepted = true
                        } else if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
                            homePage.activateHomeTab(false)
                            event.accepted = true
                        }
                    }

                    onActiveFocusChanged: {
                        if (activeFocus && homePage.currentHomeTab !== 1)
                            homePage.activateSearchTab(false)
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: homePage.activateSearchTab(false)
                        onClicked: homePage.activateSearchTab(true)
                    }
                }
            }
        }

        Row {
            id: rightRow
            spacing: 18
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: 24

            /* Bouton Paramètres */
            FocusScope {
                id: settingsBtn
                width: 48; height: 48
                activeFocusOnTab: true

                Item {
                    anchors.fill: parent
                    transformOrigin: Item.Center
                    scale: settingsBtn.activeFocus ? 1.08 : 1.0
                    Behavior on scale {
                        enabled: !homePage._scrollingEff
                        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                    }
                    Text { anchors.centerIn: parent; text: "\u2699"; color: "white"; font.pixelSize: 22 }
                    Rectangle {
                        height: 2
                        width: settingsBtn.activeFocus ? parent.width : 0
                        color: "#ffffff"
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        Behavior on width {
                            enabled: !homePage._scrollingEff
                            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                        }
                        opacity: settingsBtn.activeFocus ? 1.0 : 0.0
                        Behavior on opacity {
                            enabled: !homePage._scrollingEff
                            NumberAnimation { duration: 100 }
                        }
                    }
                }

                function openSettingsPanel() {
                    settingsPanelLoader.active = true;
                    if (settingsPanelLoader.item && settingsPanelLoader.item.open) {
                        if (settingsPanelLoader.item.hasOwnProperty("showClock"))
                            settingsPanelLoader.item.showClock = Components.AppSettings.showClock;
                        settingsPanelLoader.item.open();
                    }
                }

                Keys.onPressed: {
                    if (event.key === Qt.Key_Left) {
                        homePage.focusCurrentTopTab(); event.accepted = true; return;
                    } else if (event.key === Qt.Key_Right) {
                        // délégation focus vers avatar ClockHUD
                        if (clockHud.focusAvatar && clockHud.focusAvatar()) {
                            event.accepted = true;
                            return;
                        }
                        event.accepted = true;
                        return;
                    } else if (event.key === Qt.Key_Down) {
                        leaveTopBarToContent(); event.accepted = true; return;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                        openSettingsPanel(); event.accepted = true; return;
                    }
                    event.accepted = false;
                }

                onActiveFocusChanged: if (activeFocus) enterTopBar()
                MouseArea {
                    anchors.fill: parent; hoverEnabled: true
                    onEntered: { settingsBtn.forceActiveFocus(); enterTopBar(); }
                    onClicked: settingsBtn.openSettingsPanel()
                }
            }

            /* ClockHUD (Avatar + Horloge) — DÉLÉGUÉ */
            Item {
                id: clockHudWrap
                width: clockHud.implicitWidth
                height: clockHud.implicitHeight
                anchors.verticalCenter: parent.verticalCenter

                Components.ClockHUD {
                    id: clockHud
                    anchors.verticalCenter: parent.verticalCenter

                    // contexte
                    host:      homePage
                    fbx:       homePage.fbx
                    serverUrl: homePage.serverUrl
                    userId:    homePage.userId
                    userImageTag: homePage.userImageTag
                    userName:  homePage.userName

                    // perf gates
                    flick:     homePage._gridFlick
                    scrolling: homePage._scrollingEff
                    hudOpacity: topBar.opacity
                    active:    !!(!homePage._loading && topBar.opacity > 0.02)

                    // délégation UI
                    showAvatar: true
                    avatarSize: 48
                    avatarInteractive: true
                    clockEnabled: true
                    fontPx: 22

                    // HomePage gère déjà l’auto-hide topbar => pas de fade interne lié au scroll
                    fadeWithScroll: false
                }

                // Souris: focus avatar au survol/clic (sans forcer navigation)
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: { if (clockHud.focusAvatar) clockHud.focusAvatar(); enterTopBar(); }
                    onClicked:  { if (clockHud.focusAvatar) clockHud.focusAvatar(); enterTopBar(); }
                }
            }
        }
    }

    /* ==== Auto-hide topbar ==== */
    function hideTopBar(){ if (currentHomeTab === 1) topBar.show(); else topBar.hide(); }
    function showTopBar(){ topBar.show(); }

    property int showY: Math.max(
        Math.round(height * 0.10),
        Math.round(((posterGridLoader.item && posterGridLoader.item.topMargin) ? posterGridLoader.item.topMargin : 0) + topBar.height * 0.25)
    )
    property int hideY: Math.max(
        Math.round(height * 0.18),
        showY + Math.round(topBar.height * 0.60)
    )
    function _syncTopBarToGridState() {
        if (homePage._loading || !homePage.visible)
            return
        if (homePage.currentHomeTab === 1) {
            showTopBar()
            return
        }

        var pg = posterGridLoader.item
        if (!pg) {
            showTopBar()
            return
        }

        var section = -1
        var y = 0
        try { section = Number(pg.focusSection) } catch(e0) { section = -1 }
        try {
            if (pg.vFlick && pg.vFlick.contentY !== undefined)
                y = Number(pg.vFlick.contentY || 0)
        } catch(e1) { y = 0 }

        // focusSection < 0 signifie que le focus est dans la topbar.
        if (section < 0) {
            showTopBar()
            return
        }

        if (y >= hideY) {
            hideTopBar()
            return
        }

        if (y <= showY) {
            showTopBar()
            return
        }

        // Zone d'hystérésis entre showY et hideY :
        // si le focus est déjà sous "Mes médias", on conserve la topbar cachée.
        // Cela évite le flash du logo/ClockHUD au retour d'une page de détail.
        if (section > 0)
            hideTopBar()
        else
            showTopBar()
    }

    function handleScroll(y, dir) {
        if (homePage.currentHomeTab === 1) { showTopBar(); return }
        if (dir > 0 && y >= hideY) { hideTopBar(); }
        else if (dir < 0 && y <= showY) { showTopBar(); }
    }

    /* === Connexions postergrid (scroll/focus) === */
    Connections {
        target: posterGridLoader.item
        ignoreUnknownSignals: true
        onScrolled: function(y, dir) { handleScroll(y, dir); }
        onFocusSectionChanged: function() {
            if (!posterGridLoader.item) return;
            var s = posterGridLoader.item.focusSection;
            if (s >= 0) homePage.lastContentSection = s;
            homePage._markHomeUserControl()
            if (!homePage._loading) {
                Qt.callLater(function(){
                    homePage._syncTopBarToGridState()
                })
            }
        }
        onCurrentFolderIndexChanged: homePage._markHomeUserControl()
        onCurrentResumeIndexChanged: homePage._markHomeUserControl()
        onCurrentNextUpIndexChanged: homePage._markHomeUserControl()
        onCurrentLatestGroupChanged: homePage._markHomeUserControl()
        onRequestBackToMenu: {
            var pg = posterGridLoader.item;
            if (pg && pg.vFlick) pg.vFlick.contentY = 0;
            enterTopBar(); homeTabBtn.forceActiveFocus();
        }
    }

    /* === Connexions postergrid (loading gate) === */
    Connections {
        target: posterGridLoader.item
        ignoreUnknownSignals: true

        onFetchedOnceChanged: {
            homePage.pokeLoadingGate()
        }
        onHomeRevealReadyChanged: {
            homePage.pokeLoadingGate()
            if (posterGridLoader.item
                    && posterGridLoader.item.homeRevealReady === true
                    && !homePage._loading) {
                Qt.callLater(function(){
                    homePage._syncTopBarToGridState()
                })
            }
        }

        onHomePosterVisualReadyChanged: {
            homePage.pokeLoadingGate()
        }

        onLibraryItemsChanged: {
            homePage._touchLib = true
            homePage.pokeLoadingGate()
        }
        onResumeItemsChanged: {
            homePage._touchResume = true
            homePage.pokeLoadingGate()
        }
        onNextUpItemsChanged: {
            homePage._touchNextUp = true
            homePage.pokeLoadingGate()
        }

        // Réponse vide ou données identiques : aucun ItemsChanged n'est requis.
        onLibraryFetchCompletedChanged: {
            if (posterGridLoader.item && posterGridLoader.item.libraryFetchCompleted === true)
                homePage._touchLib = true
            homePage.pokeLoadingGate()
        }
        onResumeFetchCompletedChanged: {
            if (posterGridLoader.item && posterGridLoader.item.resumeFetchCompleted === true)
                homePage._touchResume = true
            homePage.pokeLoadingGate()
        }
        onNextUpFetchCompletedChanged: {
            if (posterGridLoader.item && posterGridLoader.item.nextUpFetchCompleted === true)
                homePage._touchNextUp = true
            homePage.pokeLoadingGate()
        }

        onLatestByFolderChanged: {
            homePage._touchLatest = true
            homePage.pokeLoadingGate()
        }
        onLatestFetchCompletedChanged: {
            if (posterGridLoader.item && posterGridLoader.item.latestFetchCompleted === true)
                homePage._touchLatest = true
            homePage.pokeLoadingGate()
        }
    }

    /* === Connexions ClockHUD (avatar) === */
    Connections {
        target: clockHud
        ignoreUnknownSignals: true

        // ✅ si ClockHUD émet un signal requestFocusSettings(), on le route ici
        function onRequestFocusSettings() { homePage.requestFocusSettings(); }

        // Enter/OK sur l’avatar => on garde l’ancien comportement (LoginPage avec contexte complet)
        onAvatarActivated: {
            homePage._clearPosterGridFocusMemory("avatar-login")
            homePage._storeServerNavContext()
            homePage.requestNavigation("LoginPage.qml?ctx=1");
        }

        // Down depuis l’avatar => revenir au contenu
        onRequestFocusBelow: {
            leaveTopBarToContent();
        }
    }

    /* ==== Loader pour le panneau Paramètres ==== */
    Loader {
        id: settingsPanelLoader
        anchors.fill: parent
        active: false
        z: 3000
        source: "../components/SettingsSidePanel.qml"
        onLoaded: {
            if (!item) return;

            if (item.hasOwnProperty("fbx"))         item.fbx         = homePage.fbx;
            if (item.hasOwnProperty("accessToken")) item.accessToken = homePage.accessToken;
            if (item.hasOwnProperty("userId"))      item.userId      = homePage.userId;
            if (item.hasOwnProperty("serverUrl"))   item.serverUrl   = homePage.serverUrl;

            if (item.hasOwnProperty("showClock")) {
                item.showClock = Components.AppSettings.showClock;
                if (item.showClockChanged && item.showClockChanged.connect) {
                    item.showClockChanged.connect(function(){
                        Components.AppSettings.showClock = !!item.showClock;
                    });
                }
            }

            if (item.closed && item.closed.connect) {
                item.closed.connect(function(){
                    settingsPanelLoader.active = false;
                    settingsBtn.forceActiveFocus();
                });
            }
            if (item.requestClose && item.requestClose.connect) {
                item.requestClose.connect(function(){
                    if (settingsPanelLoader.item && settingsPanelLoader.item.close) settingsPanelLoader.item.close();
                });
            }

            if (item.open) item.open();
        }
    }

    /* ==== Propagation des props vers postergrid + init store ==== */
    Connections {
        target: homePage
        onAccessTokenChanged: {
            if (posterGridLoader.item) posterGridLoader.item.accessToken = accessToken
            homePage._applyContextToSearchPage()
        }
        onUserIdChanged: {
            if (posterGridLoader.item) posterGridLoader.item.userId = userId
            homePage._applyContextToSearchPage()
        }
        onServerUrlChanged: {
            if (posterGridLoader.item) posterGridLoader.item.serverUrl = serverUrl
            homePage._applyContextToSearchPage()
        }
        onFbxChanged: {
            if (posterGridLoader.item) posterGridLoader.item.fbx = fbx;
            homePage._applyContextToSearchPage();
        }
                onSharedChanged: {
            if (_hydrateSensitiveContextFromShared()) {
                _applyContextToPosterGrid()
                if (!(posterGridLoader.item && posterGridLoader.item.fetchedOnce && !_loading))
                    beginLoadingGate()
                pokeLoadingGate()
            } else if (posterGridLoader.item && posterGridLoader.item.hasOwnProperty("shared")) {
                posterGridLoader.item.shared = shared
            }
        }
    }

    // Loader plein écran centralisé dans ShellPage.

    /* =========================
       OVERLAY LOADING (noir + logo + loader animé)
       ========================= */
    Item {
        id: loadingOverlay
        anchors.fill: parent
        z: 5000
        visible: homePage._loading || opacity > 0.01
        opacity: homePage._loading ? 1.0 : 0.0
        Behavior on opacity {
            enabled: !homePage._scrollingEff
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }

        Rectangle { anchors.fill: parent; color: "#000" }
    }

    onVisibleChanged: {
        if (!visible) {
            // Navigation vers une page de contenu. Un changement d'onglet
            // Recherche/Accueil ne passe jamais ici.
            _externalReturnArmed = true
            return
        }

        var externalHomeReturn = _externalReturnArmed && currentHomeTab === 0
        _externalReturnArmed = false

        if (externalHomeReturn) {
            // Lever immédiatement le curtain avant tout repaint de PosterGrid.
            _waitForHomePosters = true
            _homeVisualReturnPrepared = false
            _loading = true
            _loadingStartMs = _nowMs()
            _lastChangeMs = _loadingStartMs
            if (!gateMaxTimer.running) gateMaxTimer.restart()
        }

        _hydrateSensitiveContextFromShared()
        _applyContextToPosterGrid()
        var pg = posterGridLoader.item

        if (externalHomeReturn)
            _prepareHomePosterReturn("home-visible-external-return")

        if (!(pg && pg.fetchedOnce && !_loading))
            beginLoadingGate()

        // _applyContextToPosterGrid() et PosterGrid.ensureBootFetch() sont les
        // deux seuls propriétaires de la restauration cache. onVisible ne relit
        // plus une troisième fois le même snapshot.
        if (externalHomeReturn && pg && pg.fetchedOnce)
            _finishLoadingFromWarmPosterGrid("home-visible-external-return")

        pokeLoadingGate()
    }

    Component.onCompleted: Qt.callLater(function () {
        _hydrateSensitiveContextFromShared()
        _applyContextToPosterGrid()

        // Nouvelle HomePage après LoginPage : le contenu doit pouvoir recevoir
        // son focus initial. Le verrou sera ensuite coupé uniquement lorsque
        // l'utilisateur place explicitement le focus sur les onglets/SearchPage.
        _keepHomeTabFocused = false
        _setPosterGridFocusAllowed(true, "homepage-completed")

        beginLoadingGate();
        pokeLoadingGate();
    })

    Keys.onPressed: {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Up || event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select || event.key === Qt.Key_Ok)
            _markHomeUserControl()
        if (event.key === Qt.Key_Menu) {
            if (!homePage._loading) settingsBtn.openSettingsPanel();
            event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
            if (homePage.currentHomeTab === 1) homePage.activateHomeTab(false);
            event.accepted = true;
            return;
        }
    }
}
