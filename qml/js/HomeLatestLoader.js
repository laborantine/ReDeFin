.pragma library
.import "jellyfinBridge.js" as Jellyfin
.import "MediaCatalog.js" as MediaCatalog
.import "MediaRailLayout.js" as MediaRailLayout
.import "SafeLog.js" as SafeLog

// Chargement et publication progressive des rails récents de Home.
// État et données restent sur la page ; les Timers QML sont injectés.
// Aucun focus, delegate ou objet QML n’est créé ici. La page conserve
// le scroll, le rendu, la restauration du focus et les reprises de rails.
// Les limites, générations, callbacks synchrones et annulations sont conservés.

function markDirty(root, idx) {
    if (root._latestDirtyIndex >= 0 && root._latestDirtyIndex !== idx) root._latestDirtyMany = true
    root._latestDirtyIndex = idx
}

function queueDone(root) {
    return root._latestLibs && root._latestPos >= root._latestLibs.length && root._latestInFlight <= 0;
}

function registerInitialRequest(root, idx, handle) {
    var key = String(idx)
    var pending = root._latestInitialPending || ({})
    var rec = pending[key]
    if (!rec) {
        rec = ({
            idx: idx, seq: root._latestQueueSeq, startedAt: Date.now(), handle: handle || null
        })
        pending[key] = rec
        root._latestInitialPending = pending
    } else {
        rec.handle = handle || null
    }
    return rec
}

function cancelInitialRequests(root, reason) {
    var pending = root._latestInitialPending || ({})
    var keys = []
    for (var key in pending)
        if (Object.prototype.hasOwnProperty.call(pending, key) && pending[key]) keys.push(key)
    for (var i = 0; i < keys.length; ++i) {
        var rec = pending[keys[i]]
        if (!rec) continue
        var handle = rec.handle
        delete pending[keys[i]]
        root._latestInFlight = Math.max(0, root._latestInFlight - 1)
        try {
            if (handle && typeof handle.cancel === "function") handle.cancel(reason || "cancelled")
        } catch(e1) {}
    }
    root._latestInitialPending = ({})
}

function sweepInitialRequests(root, timers) {
    if (!root._alive || root._latestInFlight <= 0) return
    var now = Date.now()
    var pending = root._latestInitialPending || ({})
    var expired = []
    for (var key in pending) {
        if (!Object.prototype.hasOwnProperty.call(pending, key)) continue
        var rec = pending[key]
        if (rec && (now - Number(rec.startedAt || now)) >= root.latestInitialRequestTimeoutMs) expired.push(rec)
    }
    for (var i = 0; i < expired.length; ++i) {
        var rec = expired[i]
        var handle = rec ? rec.handle : null
        if (rec) finishInitialRequest(root, timers, rec.idx, null)
        try {
            if (handle && typeof handle.cancel === "function") handle.cancel("latest-watchdog-timeout")
        } catch(e0) {}
    }
}

function startInitialQueue(root, timers, libs, fetchSeq) {
    root._clearLatestWarmRails() // Ne jamais servir d'anciens DTO après un refresh.
    cancelReloads(root, "latest_queue_restarted")
    cancelInitialRequests(root, "latest_queue_restarted")
    timers.ready.stop()
    timers.publish.stop()
    root._latestResponsesDone = 0
    root._latestInitialPending = ({})
    root._latestQueueSeq = (fetchSeq !== undefined && fetchSeq !== null) ? fetchSeq : root._fetchSeq
    root._latestLibs = MediaCatalog.safeArray(libs)
    root._latestPos = 0
    root._latestInFlight = 0
    root._latestDirtyIndex = -1
    root._latestDirtyMany = true // Premier affichage : structure à reconstruire.
    root._latestTemp = new Array(root._latestLibs.length)
    for (var i=0;i<root._latestTemp.length;i++) {
        root._latestTemp[i] = null
        var lid = root._latestLibs[i] && root._latestLibs[i].Id ? String(root._latestLibs[i].Id) : ""
        for (var c=0; lid && root.latestByFolder && c<root.latestByFolder.length; ++c) {
            if (root.latestByFolder[c] && String(root.latestByFolder[c].id || "") === lid) {
                root._latestTemp[i] = root.latestByFolder[c]
                break
            }
        }
    }
    root._latestStageTarget = root._latestLibs.length
    root._latestInitialComplete = false
    root._latestAllComplete = false
    root._latestHadFailures = false
    // Des données déjà visibles (cache ou refresh) n'ont pas à attendre
    // la fin de toutes les bibliothèques pour rouvrir Home.
    root.latestFetchCompleted = false
    if (!root.fetchedOnce || !root.latestByFolder || root.latestByFolder.length === 0) root._setLatestByFolderIfChanged([])
    if ((!root.latestByFolder || root.latestByFolder.length === 0)
            && !root._focusRestorePending && !root._restoringFocus) {
        root.latestIndicesByGroup = []
        root.currentLatestGroup = 0
    }
    if (root._latestLibs.length === 0) {
        root._setLatestByFolderIfChanged([])
        root._latestInitialComplete = true
        root.latestFetchCompleted = true
        updateInitialCompletion(root, timers)
        return
    }
    if (!root.latestFetchCompleted) timers.ready.restart()
    timers.pump.restart()
}

function publishPending(root) {
    var dirtyIndex = root._latestDirtyIndex, multiple = root._latestDirtyMany
    root._latestDirtyIndex = -1
    root._latestDirtyMany = false
    // Une bibliothèque déjà publiée se met à jour sans recalculer les index,
    // positions et métriques des autres rails (focus/scroll inchangés).
    if (!multiple && dirtyIndex >= 0) {
        var changedEntry = root._latestTemp[dirtyIndex]
        if (changedEntry && changedEntry.id &&
                ((changedEntry.items && changedEntry.items.length > 0) || (changedEntry._evicted && changedEntry._hadItems)) &&
                !MediaCatalog.isKnownUnsupportedLibraryFolder(changedEntry)) {
            var existingIndex = entryIndexById(root, changedEntry.id)
            if (existingIndex >= 0 && replaceEntry(root, existingIndex, changedEntry, false, true)) return
        }
    } else if (!multiple && dirtyIndex < 0) {
        return // Pas de changement depuis la dernière projection.
    }
    var previous = root.latestByFolder || []
    var previousIndices = root.latestIndicesByGroup || []
    var previousFocus = previous[root.currentLatestGroup]
    var selectedId = previousFocus ? String(previousFocus.id || "") : ""
    var positions = ({})
    for (var p = 0; p < previous.length; ++p) {
        if (previous[p] && previous[p].id)
            positions["#" + String(previous[p].id)] = p
    }
    var out = []
    for (var i=0; i<root._latestTemp.length; i++) {
        var e = root._latestTemp[i]
        if (e && ((e.items && e.items.length > 0) || (e._evicted && e._hadItems))) out.push(e)
    }
    root._setLatestByFolderIfChanged(out)
    var inds = [], indicesChanged = out.length !== previousIndices.length
    var focusedIndex = -1
    for (var j = 0; j < out.length; ++j) {
        var id = String(out[j].id || "")
        var previousPosition = positions["#" + id]
        inds[j] = previousPosition !== undefined ? (previousIndices[previousPosition] || 0) : 0
        if (inds[j] !== previousIndices[j]) indicesChanged = true
        if (selectedId && selectedId === id) focusedIndex = j
    }
    if (indicesChanged) root.latestIndicesByGroup = inds
    if (!root._focusRestorePending && !root._restoringFocus)
        root.currentLatestGroup = focusedIndex >= 0 ? focusedIndex
                : MediaCatalog.clampIndex(root.currentLatestGroup, out.length)
}

function updateInitialCompletion(root, timers) {
    var done = queueDone(root)
    if (done) {
        // Dernière livraison synchrone : le cache doit être complet.
        timers.publish.stop()
        publishPending(root)
        var wasComplete = root._latestAllComplete
        root._latestAllComplete = true
        root._latestInitialComplete = true
        root.latestFetchCompleted = true
        timers.ready.stop()
        if (!wasComplete) root._saveHomeCacheNow()
    } else if (!timers.publish.running) {
        timers.publish.start()
    }
    // T1: le gate Home attend seulement le premier rail valide ou trois
    // réponses Latest, jamais l'ensemble d'une grosse bibliothèque.
    if (!root.latestFetchCompleted &&
            (root._latestResponsesDone >= root.latestRevealResponseCount ||
             done || (root.latestByFolder && root.latestByFolder.length > 0))) {
        root._latestInitialComplete = true
        root.latestFetchCompleted = true
        timers.ready.stop()
    }
}

function fetchForFolder(root, parentId, limit, groupItems, ok, ko) {
    return Jellyfin.fetchHomeLatestItemsForParent(
                root.serverUrl, root.accessToken, root.userId, parentId, limit,
                function(items) { if (ok) ok(MediaCatalog.safeArray(items)) },
                function(code) { if (ko) ko(SafeLog.safeErrorCode(code, "network_error")) },
                groupItems === true
    )
}

function cancelReloads(root, reason) {
    var handles = root._latestReloadHandles || ({})
    root._latestReloadHandles = ({})
    root._latestPriorityReload = ({ id: "", reason: "" })
    for (var key in handles) {
        if (!Object.prototype.hasOwnProperty.call(handles, key)) continue
        var rec = handles[key]
        try { if (rec && rec.handle && rec.handle.cancel) rec.handle.cancel(reason || "cancelled") } catch(e) {}
    }
}

function wakeQueues(root, timers) {
    if (!root._alive) return
    // Priorité au focus en attente lors de la libération d'une connexion.
    var wanted = root._latestPriorityReload
    if (wanted && wanted.id && root._latestInFlight + reloadCount(root) < root.latestTotalMaxInflight) {
        root._latestPriorityReload = ({ id: "", reason: "" })
        var idx = entryIndexById(root, wanted.id)
        if (idx >= 0) root._ensureLatestGroupData(idx, wanted.reason)
    }
    if (root._latestPos < root._latestStageTarget && root._latestInFlight < root.latestMaxInflight
            && root._latestInFlight + reloadCount(root) < root.latestTotalMaxInflight)
        timers.pump.restart()
}

function reloadCount(root) {
    var handles = root._latestReloadHandles || ({}), count = 0
    for (var key in handles)
        if (Object.prototype.hasOwnProperty.call(handles, key) && handles[key]) count++
    return count
}

function entryIndexById(root, id) {
    id = String(id || "")
    for (var i = 0; id && root.latestByFolder && i < root.latestByFolder.length; ++i)
        if (root.latestByFolder[i] && String(root.latestByFolder[i].id || "") === id) return i
    return -1
}

function updatePendingEntry(root, entry) {
    var id = String(entry && entry.id || "")
    for (var i = 0; id && root._latestLibs && i < root._latestLibs.length; ++i) {
        if (root._latestLibs[i] && String(root._latestLibs[i].Id || "") === id) {
            root._latestTemp[i] = entry
            return true
        }
    }
    return false
}

function replaceEntry(root, groupIndex, entry, saveNow, tempAlreadyUpdated) {
    if (!root.latestByFolder || groupIndex < 0 || groupIndex >= root.latestByFolder.length || !entry) return false
    var prior = root.latestByFolder[groupIndex]
    if (!prior || String(prior.id || "") !== String(entry.id || "")) return false
    if (!tempAlreadyUpdated) updatePendingEntry(root, entry)
    var unchanged = MediaCatalog.homeLatestGroupsEqual([prior], [entry])
            && Number(prior._loadedAt || 0) === Number(entry._loadedAt || 0)
            && Number(prior._evictedAt || 0) === Number(entry._evictedAt || 0)
    if (!unchanged) {
        var prepared = MediaRailLayout.prepareHomeLatestGroups([entry], root.homeCardLayout)
        if (prepared.length !== 1) return false
        var next = root.latestByFolder.slice(0)
        next[groupIndex] = prepared[0]
        root.latestByFolder = next
        root._saveHomeCacheSoon()
    }
    if (saveNow === true) root._saveHomeCacheNow()
    return true
}

function finishInitialRequest(root, timers, idx, entry) {
    var key = String(idx)
    var pending = root._latestInitialPending || ({})
    var rec = pending[key]
    if (!rec) {
        return false
    }
    try { delete pending[key] } catch(e0) {}
    root._latestInitialPending = pending
    root._latestInFlight = Math.max(0, root._latestInFlight - 1)
    if (!entry) {
        root._latestHadFailures = true
        root._warnHomeOnce("latest-network")
    }
    // Un échec transitoire ne retire pas un rail restauré du cache.
    if (entry && entry.items && entry.items.length) entry._loadedAt = Date.now()
    root._latestTemp[idx] = entry || root._latestTemp[idx] || null
    markDirty(root, idx)
    ++root._latestResponsesDone
    // Première section publiable avant de rendre la main au gate Home.
    if (!root.latestFetchCompleted && entry && entry.items && entry.items.length)
        publishPending(root)
    var stageDone = root._latestPos >= root._latestStageTarget && root._latestInFlight <= 0
    if (stageDone && !root._latestInitialComplete) root._latestInitialComplete = true
    updateInitialCompletion(root, timers)
    wakeQueues(root, timers)
    if (stageDone) {
        root._resetHydration()
        root.updateBackdrop()
        if ((!root.latestByFolder || root.latestByFolder.length === 0) && root._latestPos < root._latestLibs.length) root.requestMoreLatestForProximity()
    } else if (root._latestPos < root._latestStageTarget) {
        timers.pump.restart()
    }
    return true
}

function pumpInitial(root, timers) {
    if (!root._safeCanTouch(root._latestQueueSeq)) return
    var target = Math.min(root._latestLibs.length, root._latestStageTarget)
    if (root._latestPos >= target) {
        if (root._latestInFlight <= 0) {
            if (!root._latestInitialComplete) root._latestInitialComplete = true
            updateInitialCompletion(root, timers)
            root._resetHydration()
            root.updateBackdrop()
        }
        return
    }
    if (root._latestInFlight >= root.latestMaxInflight ||
            root._latestInFlight + reloadCount(root) >= root.latestTotalMaxInflight) {
        // Les callbacks de libération relanceront la pompe.
        return
    }
    var idx = root._latestPos++; var lib = root._latestLibs[idx]
    var requestSeq = root._latestQueueSeq
    if (!lib || !lib.Id) {
        root._latestTemp[idx] = null
        ++root._latestResponsesDone
        var invalidStageDone = root._latestPos >= target && root._latestInFlight <= 0
        if (invalidStageDone) root._latestInitialComplete = true
        updateInitialCompletion(root, timers)
        if (root._latestPos < target) timers.pump.restart()
        else if (invalidStageDone && (!root.latestByFolder || root.latestByFolder.length === 0) && root._latestPos < root._latestLibs.length) root.requestMoreLatestForProximity()
        return
    }
    root._latestInFlight++
    registerInitialRequest(root, idx, null)
    var latestHandle = fetchForFolder(root,
                lib.Id,
                root.latestFullLimit,
                MediaCatalog.isSeriesLibraryFolder(lib),
                function(arr) {
            try {
                if (!root._safeCanTouch(requestSeq) || requestSeq !== root._latestQueueSeq) return
                finishInitialRequest(root, timers, idx, {
                    id: lib.Id, name: lib.Name || "Section", items: MediaCatalog.safeArray(arr), ct: lib.CollectionType || "", t: lib.Type || ""
                })
            } catch(e1) {
            }
        }, function() {
            try {
                if (root._safeCanTouch(requestSeq) && requestSeq === root._latestQueueSeq)
                    finishInitialRequest(root, timers, idx, null)
            } catch(e2) {
            }
        }
    )
    // Une réponse servie synchroniquement par le cache peut déjà avoir
    // terminé le slot ; ne pas recréer un faux pending après le callback.
    if (requestSeq === root._latestQueueSeq && root._latestInitialPending[String(idx)])
        registerInitialRequest(root, idx, latestHandle)
    if (root._latestPos < target) timers.pump.restart()
}

function fetchLibraries(root, timers, fetchSeq) {
    var seq = (fetchSeq !== undefined && fetchSeq !== null) ? fetchSeq : root._fetchSeq
    try {
        if (!root._safeCanTouch(seq)) return
        var libs = MediaCatalog.safeArray(root.libraryItems).filter(function(i){
            return i
                    && (i.CollectionType || i.IsFolder)
                    && !MediaCatalog.isVirtualCollectionsFolderId(i.Id)
                    && !MediaCatalog.isKnownUnsupportedLibraryFolder(i)
        })
        startInitialQueue(root, timers, libs, seq)
    } catch(e) {
        root._warnHomeOnce("latest-setup")
        root._latestHadFailures = true
        root.latestFetchCompleted = true
    }
}

