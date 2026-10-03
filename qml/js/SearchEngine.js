.pragma library
.import "jellyfinBridge.js" as Jellyfin
.import "MediaCatalog.js" as MediaCatalog
.import "SafeLog.js" as SafeLog

/* SearchEngine.js — recherche Jellyfin progressive et bornée.
 * La page possède le rendu, le focus et les messages utilisateur ; ici
 * restent les requêtes, les quotas, l’hydratation et l’annulation.
 * Un état par page évite de partager une continuation entre vues.
 */
function createState() { return { epoch: 0, handles: [], continuation: null }; }
function _s(v) { return (v === undefined || v === null) ? "" : String(v); }
function _trim(v) { return _s(v).replace(/^\s+|\s+$/g, ""); }

function _searchEnc(v) {
    try { return encodeURIComponent(_s(v)); } catch (e0) { return _s(v); }
}
function _searchIsArray(v) {
    if (typeof Array !== "undefined" && Array.isArray)
        return Array.isArray(v);
    return Object.prototype.toString.call(v) === "[object Array]";
}
function _searchTrackHandle(state, handle) {
    if (!handle || typeof handle.cancel !== "function") return handle
    try {
        if (typeof handle.isActive === "function" && !handle.isActive()) return handle
    } catch(e0) {}
    var list = state.handles || []
    list.push(handle)
    state.handles = list
    return handle
}
function _searchUntrackHandle(state, handle) {
    var list = state.handles || []
    if (!list.length || !handle) return
    var next = []
    for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i] !== handle) next.push(list[i])
    }
    state.handles = next
}
function _searchCancelHandles(state, reason) {
    var list = state.handles || []
    state.handles = []
    for (var i = 0; i < list.length; i++) {
        try {
            if (list[i] && typeof list[i].cancel === "function")
                list[i].cancel(reason || "cancelled")
        } catch(e0) {}
    }
}
function cancel(state, reason) {
    state.epoch++
    if (state.epoch > 2147483000) state.epoch = 1
    state.continuation = null
    _searchCancelHandles(state, reason || "cancelled")
}
function hasContinuation(state, requestSequence) {
    var c = state.continuation
    return !!(c && c.requestId === requestSequence &&
               c.epoch === state.epoch && c.running !== true)
}
function continueSearch(state, requestSequence) {
    var c = state.continuation
    if (!c || c.requestId !== requestSequence ||
            c.epoch !== state.epoch || c.running === true)
        return false
    c.running = true
    state.continuation = null
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

function start(root, state, seq, searchTerm, startIndex, limit, onSuccess, onError) {
    var epoch = state.epoch
    var term = _trim(searchTerm)
    var srv = _s(root.serverUrl)
    var uid = _s(root.userId)
    var token = _s(root.accessToken)
    // Le quota global Jellyfin ne doit pas laisser les épisodes évincer les
    // séries lorsqu'un préfixe court (2-3 caractères) produit beaucoup de
    // correspondances. Les deux types disposent donc de petits pools dédiés.
    var generalTypes = "Movie,Video,MusicVideo,BoxSet,Folder,CollectionFolder,UserView,AggregateFolder,UserRootFolder"
    var allTypes = generalTypes + ",Series,Episode"
    var deadlineAt = Date.now() + root.searchBudgetMs
    var partialSent = false
    var lastPartialItems = []
    var lastTotal = 0
    var dedicatedSeedItems = []
    // Coalescence limitée à cette recherche : deux chemins progressifs qui
    // demandent exactement la même URL partagent un seul transport.
    var jsonInflight = ({})
    startIndex = Math.max(0, MediaCatalog.intValue(startIndex))
    limit = Math.max(1, Math.min(60, MediaCatalog.intValue(limit) || 40))
    var seriesSeedLimit = Math.max(12, Math.min(20, Math.floor(limit * 0.50)))
    var episodeSeedLimit = Math.max(12, Math.min(20, Math.floor(limit * 0.50)))
    // On accepte au plus 20 cartes globales supplémentaires afin de garder
    // des films/collections visibles sans sacrifier les quotas Series/Episode.
    var mergedResultLimit = Math.min(80, Math.max(limit, limit + 20))

    function current() {
        return seq === root.requestSequence && epoch === state.epoch
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
            _searchCancelHandles(state, "completed")
    }
    function emitError(payload) {
        if (!current()) return
        if (onError) onError(payload)
        _searchCancelHandles(state, "completed")
    }
    if (!srv || !token || !uid) {
        emitError({ code: "missing_params", message: "missing_params", status: 0 })
        return
    }
    if (term.length < root.minimumQueryLength) {
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
                _searchUntrackHandle(state, handle)
                finishAll(true, j, res)
            },
            function(err) {
                _searchUntrackHandle(state, handle)
                finishAll(false, err, null)
            }
        )
        entry.handle = handle
        _searchTrackHandle(state, handle)
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
                _searchUntrackHandle(state, viewsHandle)
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
                _searchUntrackHandle(state, viewsHandle)
                if (current()) done([])
            }
        )
        _searchTrackHandle(state, viewsHandle)
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
                    state.continuation = {
                        requestId: seq,
                        epoch: epoch,
                        running: false,
                        run: function() {
                            if (!current()) return
                            deadlineAt = Date.now() + root.searchBudgetMs
                            runStage()
                        }
                    }
                } else if (state.continuation &&
                           state.continuation.requestId === seq &&
                           state.continuation.epoch === epoch) {
                    state.continuation = null
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
