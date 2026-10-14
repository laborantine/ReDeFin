.pragma library
.import "MediaBrowser.js" as MediaBrowser
.import "MediaCatalog.js" as MediaCatalog

// Filmographie paginée d'une personne : deux fenêtres indépendantes,
// annulations et budget réseau borné. Aucun ListView, focus ou état visuel.
// create(options) reçoit fetchPage, isCurrent, pageSize, windowMaxItems,
// prefetchThreshold, onPages, onLoadingChanged et onLoaded.
// Chaque visite crée une instance ; cancel invalide aussi les callbacks différés.
// API du contrôleur : load, requestWindow, requestMore, pageStartForId, cancel.
function create(options) {
    var active = true;
    var branches = {
        base: _newBranch(),
        episodes: _newBranch()
    };

    function branchFor(kind) {
        return kind === "episodes" ? branches.episodes : branches.base;
    }

    function current() {
        return active && options.isCurrent();
    }

    function setLoading(kind, loading) {
        options.onLoadingChanged(kind, loading);
    }

    function cancelBranch(kind) {
        var state = branchFor(kind);
        var handle = state.handle;
        state.handle = null;
        setLoading(kind, false);
        ++state.attempt;
        try {
            if (handle && handle.cancel) handle.cancel("context_changed");
        } catch (error) {}
    }

    function finishInitial(kind) {
        branchFor(kind).done = true;
        if (branches.base.done && branches.episodes.done)
            options.onLoaded();
    }

    function appendPage(kind, items, start, limit, direction) {
        var state = branchFor(kind);
        var window = MediaBrowser.appendCatalogPageWindow(
            state.pages, items, start, limit, direction, options.windowMaxItems);
        state.pages = window.pages;
        state.hasMoreBefore = window.hasMoreBefore;
        state.hasMoreAfter = window.hasMoreAfter;
        options.onPages(kind, state.pages);
    }

    function fetchPage(kind, start, limit, direction, railKind, autoPages, initial) {
        if (!current()) return;
        var state = branchFor(kind);
        if (!state.deadline) state.deadline = Date.now() + 14000;
        if (Date.now() >= state.deadline) {
            setLoading(kind, false);
            if (initial) finishInitial(kind);
            return null;
        }
        direction = direction === "backward" ? "backward" : "forward";
        limit = Math.max(40, (limit || options.pageSize()) | 0);
        start = Math.max(0, start | 0);
        autoPages = Math.max(0, autoPages | 0);
        cancelBranch(kind);
        var attempt = ++state.attempt;
        setLoading(kind, !initial);
        var handle = options.fetchPage(kind, start, limit, state.deadline,
            function(items) {
                if (!current() || attempt !== state.attempt) return;
                if (state.handle === handle) state.handle = null;
                setLoading(kind, false);
                items = items || [];
                if (initial && start > 0 && items.length === 0) {
                    Qt.callLater(function() {
                        fetchPage(kind, 0, limit, "forward", "", 0, true);
                    });
                    return;
                }
                appendPage(kind, items, start, limit, direction);
                var full = items.length >= limit;
                var canContinue = !personCreditsPageContains(items, railKind)
                    && autoPages < 3
                    && ((direction === "forward" && full)
                        || (direction === "backward" && start > 0));
                if (canContinue) {
                    var next = direction === "backward"
                        ? Math.max(0, start - limit) : start + items.length;
                    Qt.callLater(function() {
                        fetchPage(kind, next, limit, direction, railKind, autoPages + 1, false);
                    });
                    return;
                }
                if (initial) finishInitial(kind);
            },
            function(error) {
                if (!current() || attempt !== state.attempt) return;
                if (state.handle === handle) state.handle = null;
                setLoading(kind, false);
                if (initial) finishInitial(kind);
            });
        state.handle = handle;
        return handle;
    }

    function requestWindow(kind, direction, railKind) {
        var state = branchFor(kind);
        if (!current() || state.handle || !state.pages.length) return false;
        var limit = Math.max(40, options.pageSize() | 0);
        var start = 0;
        if (direction === "backward") {
            if (!state.hasMoreBefore) return false;
            var first = MediaBrowser.catalogPageWindowStart(state.pages);
            start = Math.max(0, first - limit);
            limit = Math.max(40, first - start);
        } else {
            if (!state.hasMoreAfter) return false;
            start = MediaBrowser.catalogPageWindowEnd(state.pages);
        }
        state.deadline = Date.now() + 14000;
        fetchPage(kind, start, limit, direction, railKind, 0, false);
        return true;
    }

    function load(restoredState) {
        if (!current()) return;
        restoredState = restoredState || {};
        var baseStart = Math.max(0, Number(restoredState.baseStart || 0) | 0);
        var episodeStart = Math.max(0, Number(restoredState.episodeStart || 0) | 0);
        branches.base.deadline = Date.now() + 14000;
        branches.episodes.deadline = Date.now() + 14000;
        fetchPage("base", baseStart, options.pageSize(), "forward", "", 0, true);
        fetchPage("episodes", episodeStart, options.pageSize(), "forward", "", 0, true);
    }

    function requestMore(railKind, index, count) {
        if (!current() || index < 0 || count <= 0) return;
        var kind = railKind === "episodes" ? "episodes" : "base";
        var state = branchFor(kind);
        if (state.hasMoreBefore && index <= 1) {
            requestWindow(kind, "backward", railKind);
            return;
        }
        if (state.hasMoreAfter && index >= Math.max(0, count - options.prefetchThreshold))
            requestWindow(kind, "forward", railKind);
    }

    function pageStartForId(kind, id) {
        return MediaBrowser.catalogPageStartForItemId(branchFor(kind).pages, id);
    }

    function cancel() {
        active = false;
        cancelBranch("base");
        cancelBranch("episodes");
    }

    return {
        load: load,
        requestWindow: requestWindow,
        requestMore: requestMore,
        pageStartForId: pageStartForId,
        cancel: cancel
    };
}

function _newBranch() {
    return {
        pages: [],
        handle: null,
        deadline: 0,
        attempt: 0,
        done: false,
        hasMoreBefore: false,
        hasMoreAfter: false
    };
}

// Fonctions pures propres aux filmographies/personnes (depuis MediaCatalog).
/* ===== Helpers PersonPage ===== */
function personCreditsSortKey(it) {
    return MediaCatalog.safeString(it && (it.SortName || it.Name)).toLowerCase();
}
function personCreditsSortItems(a, b) {
    var aa = personCreditsSortKey(a), bb = personCreditsSortKey(b);
    if (aa < bb) return -1;
    if (aa > bb) return 1;
    return MediaCatalog.safeString(a && a.Id) < MediaCatalog.safeString(b && b.Id) ? -1 : 1;
}
function personEpisodeCode(it) {
    if (!it) return "";
    var season = Number(it.ParentIndexNumber), episode = Number(it.IndexNumber);
    season = isFinite(season) ? season : -1;
    episode = isFinite(episode) ? episode : -1;
    if (season < 0 && episode < 0) return "";
    function pad2(n) { return n < 10 ? ("0" + n) : String(n); }
    if (season >= 0 && episode >= 0) return "S" + pad2(season) + "E" + pad2(episode);
    if (episode >= 0) return "E" + pad2(episode);
    return "S" + pad2(season);
}
function personEpisodeMeta(it) {
    if (!it) return "";
    var seriesName = MediaCatalog.safeString(it.SeriesName || "");
    var code = personEpisodeCode(it);
    return seriesName.length && code.length ? seriesName + " • " + code
         : seriesName.length ? seriesName : code;
}
function personEpisodeSortItems(a, b) {
    var sa = MediaCatalog.safeString(a && (a.SeriesName || a.Series || "")).toLowerCase();
    var sb = MediaCatalog.safeString(b && (b.SeriesName || b.Series || "")).toLowerCase();
    if (sa < sb) return -1;
    if (sa > sb) return 1;
    var sea = Number(a && a.ParentIndexNumber), seb = Number(b && b.ParentIndexNumber);
    sea = isFinite(sea) ? sea : 99999;
    seb = isFinite(seb) ? seb : 99999;
    if (sea !== seb) return sea - seb;
    var ea = Number(a && a.IndexNumber), eb = Number(b && b.IndexNumber);
    ea = isFinite(ea) ? ea : 99999;
    eb = isFinite(eb) ? eb : 99999;
    if (ea !== eb) return ea - eb;
    return personCreditsSortItems(a, b);
}


function personOverviewPresent(person) {
    return !!person && MediaCatalog.plainOverview(person.Overview || "").length > 0;
}

function personBirthDatePresent(person) {
    return !!person && MediaCatalog.safeString(person.BirthDate || person.PremiereDate || "").length > 0;
}

function personMetadataNeedsRefresh(person) {
    return !person || !personOverviewPresent(person) || !personBirthDatePresent(person);
}

function mergePersonMetadata(richPerson, userScopedPerson) {
    var rich = richPerson || null, scoped = userScopedPerson || null;
    if (!rich) return scoped;
    if (!scoped) return rich;
    if (scoped.UserData) rich.UserData = scoped.UserData;
    if (!personOverviewPresent(rich) && personOverviewPresent(scoped)) rich.Overview = scoped.Overview;
    if (!personBirthDatePresent(rich) && personBirthDatePresent(scoped)) {
        if (scoped.BirthDate) rich.BirthDate = scoped.BirthDate;
        else rich.PremiereDate = scoped.PremiereDate;
    }
    if (!rich.DeathDate && scoped.DeathDate) rich.DeathDate = scoped.DeathDate;
    if (!rich.EndDate && scoped.EndDate) rich.EndDate = scoped.EndDate;
    return rich;
}


function personCreditBuckets(pages) {
    pages = MediaCatalog.safeArray(pages).slice(0);
    pages.sort(function(a, b) { return Number(a.start || 0) - Number(b.start || 0); });
    var seen = ({}), movies = [], series = [], episodes = [];
    for (var pageIndex = 0; pageIndex < pages.length; ++pageIndex) {
        var items = MediaCatalog.safeArray(pages[pageIndex] && pages[pageIndex].items);
        for (var itemIndex = 0; itemIndex < items.length; ++itemIndex) {
            var item = items[itemIndex], id = item && item.Id ? String(item.Id) : "";
            if (!item || !id || seen[id]) continue;
            seen[id] = true;
            var typeName = MediaCatalog.itemTypeLower(item);
            if (typeName === "movie") movies.push(item);
            else if (typeName === "series") series.push(item);
            else if (typeName === "episode") episodes.push(item);
        }
    }
    try { episodes.sort(personEpisodeSortItems); } catch (sortError) {}
    return { movies:movies, series:series, episodes:episodes };
}

function personCreditsPageContains(items, railKind) {
    if (!railKind) return true;
    var wanted = railKind === "movies" ? "movie" : (railKind === "series" ? "series" : "episode");
    items = MediaCatalog.safeArray(items);
    for (var i = 0; i < items.length; ++i)
        if (MediaCatalog.itemTypeLower(items[i]) === wanted) return true;
    return false;
}

