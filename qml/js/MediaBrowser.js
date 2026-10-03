.pragma library
.import "MediaCatalog.js" as MediaCatalog

/* MediaBrowser.js — tri, pagination bornée et retour de dossier.
 * Les pages décident du focus et des requêtes ; ces calculs ne
 * touchent ni au GridView, ni au transport Jellyfin.
 */
function emptyText(mode, musicVideoMode) {
    if (musicVideoMode) return "Aucun clip trouvé.";
    var m = MediaCatalog.normalizeMode(mode);
    if (m === "personal") return "Aucune photo ou vidéo trouvée.";
    if (m === "collections") return "Aucune collection trouvée.";
    return m === "series" ? "Aucune série trouvée."
         : (m === "mixed" ? "Aucun film ou série trouvé." : "Aucun film trouvé.");
}
var FOLDER_SORT_LABELS = [
    "Nom",
    "Date d'ajout",
    "Date de sortie",
    "Note de la communauté",
    "Dernière lecture",
    "Durée de lecture"
];
function folderSortOptionLabels() {
    return FOLDER_SORT_LABELS.slice(0);
}
function _sortCleanName(it) {
    var n = _browserString((it && (it.SortName || it.Name)) || "");
    return n.toLowerCase ? n.toLowerCase() : n;
}
function _sortDateMs(v) {
    v = _browserString(v);
    if (!v) return 0;
    try {
        var t = Date.parse(v);
        return isFinite(t) ? t : 0;
    } catch (e) {
        return 0;
    }
}
function _sortYearMs(v) {
    var y = Number(v || 0);
    if (!isFinite(y) || y <= 0) return 0;
    return Date.UTC(Math.floor(y), 0, 1);
}
function _sortNum(v) {
    var n = Number(v || 0);
    return (isFinite(n) && !isNaN(n)) ? n : 0;
}
function _sortDateAddedKey(it) {
    if (!it) return 0;
    return _sortDateMs(it.DateCreated)
        || _sortDateMs(it.DateLastMediaAdded)
        || _sortDateMs(it.DateLastRefreshed)
        || _sortDateMs(it.PremiereDate)
        || _sortYearMs(it.ProductionYear);
}
function _sortReleaseDateKey(it) {
    if (!it) return 0;
    return _sortDateMs(it.PremiereDate) || _sortYearMs(it.ProductionYear);
}
function _sortLastPlayedKey(it) {
    var ud = MediaCatalog.userDataOf(it);
    return _sortDateMs(ud.LastPlayedDate)
        || _sortDateMs(it.LastPlayedDate)
        || _sortDateMs(it.DatePlayed);
}
function _folderSortKey(it, mode) {
    mode = _browserInt(mode);
    if (mode === 1) return _sortDateAddedKey(it);
    if (mode === 2) return _sortReleaseDateKey(it);
    if (mode === 3) return _sortNum(it && it.CommunityRating);
    if (mode === 4) return _sortLastPlayedKey(it);
    if (mode === 5) return _sortNum(it && (it.RunTimeTicks || it.CumulativeRunTimeTicks));
    return _sortCleanName(it);
}
function folderSortCompare(a, b, mode) {
    mode = _browserInt(mode);
    var desc = mode > 0;
    if (mode === 0) {
        var na = _sortCleanName(a), nb = _sortCleanName(b);
        return na < nb ? -1 : (na > nb ? 1 : 0);
    }
    var ka = _folderSortKey(a, mode), kb = _folderSortKey(b, mode);
    var az = (ka === undefined || ka === null || ka === "" || ka === 0);
    var bz = (kb === undefined || kb === null || kb === "" || kb === 0);
    if (az && !bz) return 1;
    if (bz && !az) return -1;
    if (ka < kb) return desc ? 1 : -1;
    if (ka > kb) return desc ? -1 : 1;
    var fa = _sortCleanName(a), fb = _sortCleanName(b);
    return fa < fb ? -1 : (fa > fb ? 1 : 0);
}
function folderSortItems(items, mode) {
    var arr = (items || []).slice(0);
    arr.sort(function(a, b) {
        return folderSortCompare(a, b, mode);
    });
    return arr;
}
// Helpers purs de fenêtre de pagination partagés par Movie/Collection/PersonalMedia.
function _browserString(v) { return (v === undefined || v === null) ? "" : String(v); }
function _browserInt(v) {
    var n = Number(v);
    return isFinite(n) && !isNaN(n) ? Math.floor(n) : 0;
}
function _browserPosInt(v) { return Math.max(0, _browserInt(v)); }
// Ils ne touchent ni au GridView ni au focus : les pages gardent l'orchestration UI.

function _mediaBrowserReturnStack(shared) {
    if (!shared) return null;
    if (!shared.__mediaBrowserReturnStack) shared.__mediaBrowserReturnStack = [];
    return shared.__mediaBrowserReturnStack;
}
function _trimMediaBrowserReturnStack(shared) {
    var stack = _mediaBrowserReturnStack(shared);
    if (!stack) return null;
    var now = Date.now();
    var out = [];
    for (var i = 0; i < stack.length; ++i) {
        var entry = stack[i];
        if (entry && entry.folderId && (now - Number(entry.ts || 0)) < 1200000) out.push(entry);
    }
    while (out.length > 12) out.shift();
    shared.__mediaBrowserReturnStack = out;
    return out;
}
function pushBrowserReturn(shared, folderId, childFolderId, browserTitle, index, y, libraryMode) {
    var stack = _trimMediaBrowserReturnStack(shared);
    if (!stack || !folderId) return false;
    stack.push({
        folderId: _browserString(folderId), childFolderId: _browserString(childFolderId), browserTitle: _browserString(browserTitle),
        index: _browserInt(index), y: Math.max(0, Math.floor(Number(y) || 0)),
        libraryMode: MediaCatalog.normalizeMode(libraryMode), ts: Date.now()
    });
    while (stack.length > 12) stack.shift();
    shared.__mediaBrowserReturnStack = stack;
    return true;
}
function popBrowserParent(shared, currentFolderId) {
    var stack = _trimMediaBrowserReturnStack(shared);
    if (!stack || !stack.length) return null;
    var top = stack[stack.length - 1];
    if (!top || (top.childFolderId && _browserString(top.childFolderId) !== _browserString(currentFolderId))) return null;
    var entry = stack.pop();
    shared.__mediaBrowserReturnStack = stack;
    return entry || null;
}

function browserRestoreIndex(restoreIndex, startIndex) {
    var restore = _browserInt(restoreIndex);
    if (Number(restoreIndex) >= 0) return restore;
    var start = _browserInt(startIndex);
    return Number(startIndex) >= 0 ? start : -1;
}
function browserRestoreY(restoreY) {
    var y = Number(restoreY);
    return isFinite(y) && y >= 0 ? y : -1;
}
function browserSortedWindow(items, mode, serverSortedPage, keepId, currentIndex, forceFirst) {
    var sorted = serverSortedPage === true ? (items || []) : folderSortItems(items || [], mode);
    if (!sorted.length) return { items: sorted, index: -1 };
    var idx = forceFirst === true ? 0 : (keepId ? browserFindItemIndexById(sorted, keepId) : _browserInt(currentIndex));
    if (idx < 0 || idx >= sorted.length) idx = 0;
    return { items: sorted, index: idx };
}
function browserSelectedItemId(items, localIndex) {
    localIndex = _browserInt(localIndex);
    var it = items && localIndex >= 0 && localIndex < items.length ? items[localIndex] : null;
    return it && it.Id ? _browserString(it.Id) : "";
}
function browserSelectedItem(items, localIndex) {
    localIndex = _browserInt(localIndex);
    return items && localIndex >= 0 && localIndex < items.length ? items[localIndex] : null;
}
function browserFindItemIndexById(items, id) {
    id = _browserString(id); items = items || [];
    if (!id) return -1;
    for (var i = 0; i < items.length; i++) if (items[i] && _browserString(items[i].Id) === id) return i;
    return -1;
}
function browserGlobalIndex(items, windowStart, localIndex) {
    localIndex = _browserInt(localIndex); windowStart = _browserPosInt(windowStart);
    if (localIndex < 0) return -1;
    var it = items && localIndex < items.length ? items[localIndex] : null;
    return (it && it._windowGlobalIndex !== undefined) ? _browserInt(it._windowGlobalIndex) : windowStart + localIndex;
}
function browserLocalIndex(items, windowStart, globalIndex) {
    items = items || []; windowStart = _browserPosInt(windowStart); globalIndex = _browserInt(globalIndex);
    if (globalIndex < 0) return -1;
    for (var i = 0; i < items.length; i++) {
        var it = items[i];
        var gi = (it && it._windowGlobalIndex !== undefined) ? _browserInt(it._windowGlobalIndex) : windowStart + i;
        if (gi === globalIndex) return i;
    }
    return -1;
}
function browserWindowKnownEnd(items, windowStart) {
    items = items || []; windowStart = _browserPosInt(windowStart);
    if (!items.length) return windowStart;
    var last = items[items.length - 1];
    return (last && last._windowGlobalIndex !== undefined) ? _browserInt(last._windowGlobalIndex) + 1 : windowStart + items.length;
}
function browserPreviousPageStart(windowStart, pageSize) {
    windowStart = _browserPosInt(windowStart);
    pageSize = Math.max(1, _browserPosInt(pageSize));
    if (windowStart <= 0) return -1;
    var start = Math.max(0, windowStart - pageSize);
    return start < windowStart ? start : -1;
}
function browserViewportLoadDirection(localIndex, itemCount, hasPrevious, hasMore, prependThreshold, appendThreshold) {
    localIndex = _browserInt(localIndex);
    itemCount = _browserPosInt(itemCount);
    if (localIndex < 0) return 0;
    if (hasPrevious === true && localIndex <= _browserPosInt(prependThreshold)) return -1;
    var appendAt = Math.max(0, itemCount - Math.max(1, _browserPosInt(appendThreshold)));
    if (hasMore === true && localIndex >= appendAt) return 1;
    return 0;
}
function browserLoadedIds(items) {
    items = items || []; var seen = {};
    for (var i = 0; i < items.length; i++) { var id = items[i] && items[i].Id ? _browserString(items[i].Id) : ""; if (id) seen[id] = 1; }
    return seen;
}

function browserInitialPagingState(targetIndex, pageSize) {
    var size = Math.max(1, _browserPosInt(pageSize));
    var target = _browserInt(targetIndex);
    var start = target >= 0 ? Math.max(0, Math.floor(target / size) * size) : 0;
    return {
        windowStartIndex: start,
        nextStart: start,
        hasMore: true,
        hasPrevious: start > 0
    };
}
function browserPageProgress(page, start, pageSize, prepend) {
    page = page || {};
    start = Math.max(0, _browserInt(start));
    var size = Math.max(1, _browserPosInt(pageSize));
    var items = page.items || [];
    if (prepend === true) {
        return { hasPrevious: start > 0, nextStart: null, hasMore: null };
    }
    var nextStart = (page.nextStartIndex !== undefined && page.nextStartIndex !== null)
            ? _browserInt(page.nextStartIndex)
            : start + size;
    if (nextStart <= start && items.length > 0) nextStart = start + items.length;
    if (nextStart <= start) nextStart = start + size;
    return { hasPrevious: null, nextStart: nextStart, hasMore: page.hasMore === true };
}
function browserAppendWindowItems(currentItems, incomingItems, start, prepend, pageSize, windowMaxItems, keepId, currentWindowStart) {
    currentItems = currentItems || [];
    incomingItems = incomingItems || [];
    start = Math.max(0, _browserInt(start));
    prepend = prepend === true;
    var size = Math.max(1, _browserPosInt(pageSize));
    var maxItems = Math.max(size, _browserPosInt(windowMaxItems));
    keepId = _browserString(keepId);
    currentWindowStart = Math.max(0, _browserInt(currentWindowStart));

    var seen = browserLoadedIds(currentItems);
    var incoming = [];
    for (var i = 0; i < incomingItems.length; i++) {
        var it = incomingItems[i];
        var id = it && it.Id ? _browserString(it.Id) : "";
        if (!id || seen[id]) continue;
        seen[id] = 1;
        var decorated = {};
        for (var k in it) decorated[k] = it[k];
        decorated._windowGlobalIndex = start + i;
        incoming.push(decorated);
    }
    if (!incoming.length) {
        return {
            items: currentItems,
            added: 0,
            windowStartIndex: currentItems.length ? browserGlobalIndex(currentItems, currentWindowStart, 0) : currentWindowStart,
            nextStart: null,
            hasMore: null,
            hasPrevious: null,
            loadedIds: browserLoadedIds(currentItems)
        };
    }

    var current = currentItems.slice(0);
    var next = prepend ? incoming.concat(current) : current.concat(incoming);
    var nextStart = null, hasMore = null, hasPrevious = null;

    if (next.length > maxItems) {
        var removeCount = Math.min(size, next.length);
        if (prepend) {
            var tailStart = next.length - removeCount;
            var keepInTail = false;
            for (var ti = tailStart; ti < next.length; ti++) {
                if (keepId && next[ti] && _browserString(next[ti].Id) === keepId) { keepInTail = true; break; }
            }
            if (!keepInTail) {
                var firstRemoved = next[tailStart];
                nextStart = firstRemoved && firstRemoved._windowGlobalIndex !== undefined
                        ? _browserInt(firstRemoved._windowGlobalIndex)
                        : start + tailStart;
                hasMore = true;
                next.splice(tailStart, removeCount);
            }
        } else {
            var keepInHead = false;
            for (var hi = 0; hi < removeCount; hi++) {
                if (keepId && next[hi] && _browserString(next[hi].Id) === keepId) { keepInHead = true; break; }
            }
            if (!keepInHead) {
                next.splice(0, removeCount);
                hasPrevious = true;
            }
        }
    }

    var windowStart = next.length && next[0]._windowGlobalIndex !== undefined
            ? _browserInt(next[0]._windowGlobalIndex)
            : (prepend ? start : currentWindowStart);
    return {
        items: next,
        added: incoming.length,
        windowStartIndex: windowStart,
        nextStart: nextStart,
        hasMore: hasMore,
        hasPrevious: hasPrevious,
        loadedIds: browserLoadedIds(next)
    };
}
function browserResolvedSortMode(persistedMode, sharedState, optionCount, fallbackMode) {
    var count = Math.max(1, _browserInt(optionCount));
    var p = _browserInt(persistedMode);
    if (p >= 0 && p < count && Number(persistedMode) >= 0) return p;
    if (sharedState && typeof sharedState.sort === "number") { var s = _browserInt(sharedState.sort); if (s >= 0 && s < count) return s; }
    var f = _browserInt(fallbackMode); return (f >= 0 && f < count) ? f : 0;
}
function browserReadSharedState(bucket, key) {
    if (!bucket || !key) return null;
    return Object.prototype.hasOwnProperty.call(bucket, key) ? bucket[key] : null;
}
