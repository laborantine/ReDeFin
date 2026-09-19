import QtQuick 2.15
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/MediaCatalog.js" as MediaCatalog
import "../js/SafeLog.js" as SafeLog
Item {
    id: postergrid
    objectName: "postergrid"
    width: parent ? parent.width : 1280
    height: parent ? parent.height : 720
    property bool focusRepairEnabled: true
    focus: true
    visible: true

    property string accessToken: ""
    property string userId: ""
    property string serverUrl: ""
    property var fbx
    property var libraryItems: []
    property var resumeItems: []
    property var nextUpItems: []
    property var latestByFolder: []
    property var _latestTemp: []
    property var shared: null
    property string focusMemoryKey: "postergrid.home"

    property bool _restoringFocus: false
    property bool _focusRestorePending: false
    property int _focusRestoreRetryLeft: 0
    property bool _focusRestoreSettle: false
    property int _focusRestoreSettleMs: 900
    property double _lastFocusRestoreOkMs: 0
    property bool _navigationSnapshotArmed: false
    property bool _exclusiveNavigationMemoryArmed: false
    property bool _latestRestoreAnchorActive: false

    property bool _resumeRestoreHorizontalPending: false
    property real _resumeRestoreSavedContentX: 0
    property var _resumeRestoreSavedViewportX: null
    property var _resumeRestoreSavedViewportWidth: null
    property int _resumeRestoreHorizontalRetryLeft: 0

    // "Mes médias" possède un ListView natif (ApplyRange/SnapOneItem). Son currentIndex seul ne suffit pas à restaurer le viewport horizontal.
    property bool _folderRestoreHorizontalPending: false
    property real _folderRestoreSavedContentX: 0
    property int _folderRestoreHorizontalRetryLeft: 0

    property bool _homeRevealReady: false
    property bool _homeRevealPrepareActive: false
    property int homeRevealSettleMs: 240
    readonly property bool homeRevealReady: _homeRevealReady
                                             && !_restoringFocus
                                             && !_focusRestorePending
                                             && !_resumeRestoreHorizontalPending
                                             && !_folderRestoreHorizontalPending

    property int _latestRestoreAnchorGroup: -1
    property int _latestRestoreAnchorIndex: -1
    property string _latestRestoreAnchorGroupId: ""
    property string _latestRestoreAnchorItemId: ""
    property int currentFolderIndex: 0
    property int currentResumeIndex: 0
    property int currentNextUpIndex: 0
    property int currentLatestGroup: 0
    property var latestIndicesByGroup: []
    property int focusSection: 0
    property bool ready: false
    property bool _syncFolderIndex: false
    property bool _alive: false
    property int _fetchSeq: 0
    property int _nextUpSeq: 0
    property bool _syncNextUpIndex: false
    property bool _folderModelSyncGuard: false
    property bool _folderUserNavActive: false
    function _safeCanTouch(seq) {
        try {
            return !!postergrid && postergrid._alive && postergrid.ready && postergrid.hasCreds()
                    && (seq === undefined || seq === null || seq === postergrid._fetchSeq)
        } catch(e) { return false }
    }
    function _setFolderIndexFromUser(idx, reason) {
        if (!folderList) return
        // Si l'utilisateur agit pendant le settle du retour, finaliser d'abord l'ancien viewport. Sinon ApplyRange peut corriger le contentX dans le sens opposé au déplacement du focus.
        try {
            if (folderList.commitRestoreCalibrationForUser)
                folderList.commitRestoreCalibrationForUser()
        } catch(eRestore) {}
        var want = MediaCatalog.clampIndex(idx, folderList.count)
        _folderUserNavActive = true
        currentFolderIndex = want
        if (folderList.currentIndex !== want) {
            _syncFolderIndex = true
            folderList.currentIndex = want
            _syncFolderIndex = false
        }
        // D-Pad / souris : seul ce chemin anime horizontalement le rail.
        try { if (folderList.ensureIndexVisible) folderList.ensureIndexVisible(want, true) } catch(e0) {}
        updateBackdrop()
        if (focusSection === 0 && !_restoringFocus && !_focusRestorePending && !_focusRestoreSettle) saveFocusSnapshot(reason || "folderIndex")
        Qt.callLater(function(){ _folderUserNavActive = false })
    }
    function _syncFolderListFromSaved() {
        if (!folderList) return
        _folderModelSyncGuard = true
        var want = MediaCatalog.clampIndex(currentFolderIndex, folderList.count)
        if (folderList.currentIndex !== want) {
            _syncFolderIndex = true
            folderList.currentIndex = want
            _syncFolderIndex = false
        }
        // Chargement/cache/restauration : placement immédiat, jamais de glide visible.
        try { if (folderList.ensureIndexVisible) folderList.ensureIndexVisible(want, false) } catch(e0) {}
        Qt.callLater(function(){ _folderModelSyncGuard = false })
    }
    function _setListIfChanged(name, arr) {
        arr = MediaCatalog.safeArray(arr)
        try {
            if (name === "libraryItems") {
                if (!MediaCatalog.homeItemsEqual(libraryItems, arr)) {
                    if (!libraryItems || libraryItems.length === 0) _restartHomeImageSettle()
                    libraryItems = arr
                    _saveHomeCacheSoon()
                }
            } else if (name === "resumeItems") {
                arr = _prepareRowMetrics(arr, "resume")
                if (!MediaCatalog.homeItemsEqual(resumeItems, arr)) {
                    if (!resumeItems || resumeItems.length === 0) _restartHomeImageSettle()
                    resumeItems = arr
                    _saveHomeCacheSoon()
                }
            } else if (name === "nextUpItems") {
                if (!MediaCatalog.homeItemsEqual(nextUpItems, arr)) {
                    if (!nextUpItems || nextUpItems.length === 0) _restartHomeImageSettle()
                    nextUpItems = arr
                    _saveHomeCacheSoon()
                }
            }
        } catch(e) {}
    }
    function _setLatestByFolderIfChanged(arr) {
        arr = _prepareLatestGroupsForCards(MediaCatalog.safeArray(arr))
        if (!MediaCatalog.homeLatestGroupsEqual(latestByFolder || [], arr)) {
            if (!latestByFolder || latestByFolder.length === 0) _restartHomeImageSettle()
            latestByFolder = arr
            _saveHomeCacheSoon()
        }
    }
    Timer { id: focusRestoreTimer; interval: 110; repeat: false; onTriggered: postergrid._applyFocusSnapshotToViews() }
    Timer { id: focusRestoreSettleTimer; interval: postergrid._focusRestoreSettleMs; repeat: false; onTriggered: postergrid._focusRestoreSettle = false }
    Timer {
        id: folderRestoreHorizontalTimer
        interval: 55
        repeat: false
        onTriggered: {
            if (!postergrid._folderRestoreHorizontalPending) return
            if (!postergrid._alive || !folderList || folderList.count <= 0 || postergrid.focusSection !== 0) {
                postergrid._folderRestoreHorizontalPending = false
                postergrid._folderRestoreHorizontalRetryLeft = 0
                return
            }
            folderList.restoreHorizontalFromSnapshot(
                        postergrid._folderRestoreSavedContentX,
                        "restore-settle")
            postergrid._folderRestoreHorizontalRetryLeft =
                    Math.max(0, postergrid._folderRestoreHorizontalRetryLeft - 1)
            if (postergrid._folderRestoreHorizontalRetryLeft > 0) {
                restart()
            } else {
                postergrid._folderRestoreHorizontalPending = false
            }
        }
    }
    Timer {
        id: resumeRestoreHorizontalTimer; interval: 55; repeat: false
        onTriggered: {
            if (!postergrid._resumeRestoreHorizontalPending) return
            if (!postergrid._alive || !resumeList || resumeList.count <= 0 || postergrid.focusSection !== 1) {
                postergrid._resumeRestoreHorizontalPending = false
                postergrid._resumeRestoreHorizontalRetryLeft = 0
                postergrid._resumeRestoreSavedViewportX = null
                postergrid._resumeRestoreSavedViewportWidth = null
                return
            }
            resumeList.restoreHorizontalFromSnapshot( postergrid._resumeRestoreSavedContentX, postergrid._resumeRestoreSavedViewportX, "restore-settle")
            postergrid._resumeRestoreHorizontalRetryLeft = Math.max(0, postergrid._resumeRestoreHorizontalRetryLeft - 1)
            if (postergrid._resumeRestoreHorizontalRetryLeft > 0) {
                restart()
            } else {
                postergrid._resumeRestoreHorizontalPending = false
                postergrid._resumeRestoreSavedViewportX = null
                postergrid._resumeRestoreSavedViewportWidth = null
            }
        }
    }
    Timer {
        id: homeRevealReadyTimer; interval: postergrid.homeRevealSettleMs; repeat: false
        onTriggered: {
            if (!postergrid._alive) {
                return
            }
            if (postergrid._restoringFocus || postergrid._focusRestorePending) {
                restart()
                return
            }
            postergrid._homeRevealPrepareActive = false
            postergrid._homeRevealReady = true
        }
    }
    function _armHomeRevealReady(){ _homeRevealReady = false; homeRevealReadyTimer.restart(); }
    function prepareHomeReveal(reason) {
        if (!focusRepairEnabled) {
            _homeRevealPrepareActive = false
            _homeRevealReady = true
            return true
        }
        if (_homeRevealReady && !_focusRestorePending && !_restoringFocus) {
            return true
        }
        if (_homeRevealPrepareActive) {
            return false
        }
        _homeRevealPrepareActive = true
        _homeRevealReady = false
        var snap = _focusSnapshot()
        if (_snapshotNeedsRestore(snap)) {
            restoreFocusSnapshot()
            return false
        }
        if (snap) {
            scheduleHomeFocusRepair()
        } else {
            forceFirstFocus()
        }
        _armHomeRevealReady(reason || "home-reveal")
        return false
    }

    function _sharedStore(name) {
        if (!shared || !name) return null
        try {
            if (!shared[name]) shared[name] = ({})
            return shared[name]
        } catch(e) { return null }
    }
    function _focusStoreRoot() { return _sharedStore("__redefinFocus") }
    function _focusSnapshotKey() {
        return focusMemoryKey + "|srv#" + SafeLog.shortHash(serverUrl) + "|usr#" + SafeLog.shortHash(userId) + "|fld#" + SafeLog.shortHash("")
    }
    function _currentContentY() {
        try { return _vFlick ? (_vFlick.contentY || 0) : 0 } catch(e) { return 0 }
    }
    function _idOf(it){ return it && it.Id !== undefined && it.Id !== null ? String(it.Id) : ""; }
    function _currentFocusTarget() {
        var out = ({ itemId:"", latestGroupId:"", latestGroupName:"", latestItemId:"" })
        try {
            if (focusSection < 3) {
                var rows = [cappedLibraryItems, cappedResumeItems, cappedNextUpItems]
                var indexes = [currentFolderIndex, currentResumeIndex, currentNextUpIndex]
                var row = rows[focusSection] || []
                var selected = row.length ? row[MediaCatalog.clampIndex(indexes[focusSection], row.length)] : null
                out.itemId = _idOf(selected)
                return out
            }
            var g = MediaCatalog.clampIndex(currentLatestGroup, latestByFolder ? latestByFolder.length : 0)
            var entry = latestByFolder && latestByFolder.length ? latestByFolder[g] : null
            var items = entry && entry.items ? capItems(entry.items) : []
            var selectedLatest = items.length ? items[MediaCatalog.clampIndex(latestIndexFor(g), items.length)] : null
            out.latestGroupId = entry ? String(entry.id || "") : ""
            out.latestGroupName = entry ? String(entry.name || "") : ""
            out.latestItemId = _idOf(selectedLatest)
            out.itemId = out.latestItemId
        } catch(e) {}
        return out
    }
    function _latestGroupIndexFromSnapshot(snap) {
        return MediaCatalog.posterGridLatestGroupIndexFromSnapshot(latestByFolder, snap)
    }
    function _setLatestRestoreAnchor(group, idx, groupId, itemId) {
        _latestRestoreAnchorActive = true
        _latestRestoreAnchorGroup = Math.max(0, group | 0)
        _latestRestoreAnchorIndex = Math.max(0, idx | 0)
        _latestRestoreAnchorGroupId = String(groupId || "")
        _latestRestoreAnchorItemId = String(itemId || "")
    }
    function _clearLatestRestoreAnchor() {
        _latestRestoreAnchorActive = false
        _latestRestoreAnchorGroup = -1
        _latestRestoreAnchorIndex = -1
        _latestRestoreAnchorGroupId = ""
        _latestRestoreAnchorItemId = ""
    }
    function _isLatestRestoreAnchoredGroup(groupIndex) {
        if (!_latestRestoreAnchorActive) return false
        if (_latestRestoreAnchorGroup === groupIndex) return true
        var gid = String(_latestRestoreAnchorGroupId || "")
        if (!gid || !latestByFolder || groupIndex < 0 || groupIndex >= latestByFolder.length) return false
        var entry = latestByFolder[groupIndex]
        return !!(entry && String(entry.id || "") === gid)
    }
    function _latestRestoreAnchorIndexForGroup(groupIndex) {
        return _isLatestRestoreAnchoredGroup(groupIndex)
                ? Math.max(0, _latestRestoreAnchorIndex | 0)
                : -1
    }
    function _canWriteFocusSnapshot(force) {
        if (force === true) return true
        if (_restoringFocus || _focusRestorePending || _focusRestoreSettle) return false
        var pendingSnapshot = _focusSnapshot()
        if (_snapshotNeedsRestore(pendingSnapshot)) return false
        return true
    }
    function _isRestoreLatestTargetGroup(groupIndex) {
        if (_latestRestoreAnchorActive) return _isLatestRestoreAnchoredGroup(groupIndex)
        if (!_focusRestorePending) return true
        var snap = _focusSnapshot()
        if (!snap || Math.max(0, Math.min(3, snap.focusSection || 0)) !== 3) return true
        var g = _latestGroupIndexFromSnapshot(snap)
        return g >= 0 && g === groupIndex
    }
    function _isRestoreLatestVisualSelection(groupIndex, index, it) {
        if (_latestRestoreAnchorActive) {
            if (!_isLatestRestoreAnchoredGroup(groupIndex)) return false
            var anchorId = String(_latestRestoreAnchorItemId || "")
            if (anchorId.length > 0) return !!(it && String(it.Id || "") === anchorId)
            return index === Math.max(0, _latestRestoreAnchorIndex|0)
        }
        if (!_focusRestorePending) return true
        var snap = _focusSnapshot()
        if (!snap || Math.max(0, Math.min(3, snap.focusSection || 0)) !== 3) return true
        if (!_isRestoreLatestTargetGroup(groupIndex)) return false
        var targetId = String(snap.latestItemId || snap.targetItemId || "")
        if (targetId.length > 0) {
            return !!(it && String(it.Id || "") === targetId)
        }
        var want = 0
        if (snap.latestIndicesByGroup && snap.latestIndicesByGroup.length > groupIndex) want = snap.latestIndicesByGroup[groupIndex] || 0
        else
            want = snap.currentLatestGroup === groupIndex ? latestIndexFor(groupIndex) : 0
        return index === want
    }
    function _exclusiveLatestIndices(section, group) {
        var out = [], count = latestByFolder ? latestByFolder.length : 0
        for (var i = 0; i < count; ++i) out.push(0)
        if (section === 3 && group >= 0 && group < count) out[group] = Math.max(0, latestIndexFor(group) | 0)
        return out
    }

    function saveFocusSnapshot(reason, force, exclusiveRail) {
        if (!_canWriteFocusSnapshot(force)) return
        if (force !== true && _navigationSnapshotArmed) return
        var root = _focusStoreRoot()
        if (!root) return
        if (focusSection < 0) return
        var target = _currentFocusTarget()
        var exclusive = exclusiveRail === true
        var sourceSection = Math.max(0, Math.min(3, focusSection | 0))
        var sourceLatestGroup = Math.max(0, currentLatestGroup | 0)
        try {
            var snapshotKey = _focusSnapshotKey()
            var previousSnapshot = null
            try {
                previousSnapshot = root[snapshotKey] || null
            } catch(e0) {}
            var resumeViewport = _resumeSnapshotViewportGeometry()
            var savedResumeViewportX = resumeViewport
                    ? Number(resumeViewport.viewportX)
                    : (previousSnapshot && previousSnapshot.resumeViewportX !== undefined
                       ? previousSnapshot.resumeViewportX : null)
            var savedResumeViewportWidth = resumeViewport
                    ? Number(resumeViewport.width)
                    : (previousSnapshot && previousSnapshot.resumeViewportWidth !== undefined
                       ? previousSnapshot.resumeViewportWidth : null)
            // Navigation depuis Home vers un conteneur : seul le rail qui a déclenché la navigation conserve sa mémoire.
            var snapFolderIndex = exclusive && sourceSection !== 0
                    ? 0 : Math.max(0, currentFolderIndex | 0)
            var snapResumeIndex = exclusive && sourceSection !== 1
                    ? 0 : Math.max(0, currentResumeIndex | 0)
            var snapNextUpIndex = exclusive && sourceSection !== 2
                    ? 0 : Math.max(0, currentNextUpIndex | 0)
            var snapLatestGroup = exclusive && sourceSection !== 3
                    ? 0 : sourceLatestGroup
            var snapLatestIndices = exclusive
                    ? _exclusiveLatestIndices(sourceSection, sourceLatestGroup)
                    : ((latestIndicesByGroup && latestIndicesByGroup.slice)
                       ? latestIndicesByGroup.slice(0) : [])
            var snapshot = ({
                needsRestore: force === true,
                focusSection: sourceSection,
                currentFolderIndex: snapFolderIndex,
                folderContentX: (exclusive && sourceSection !== 0)
                                ? 0
                                : (folderList ? Number(folderList.contentX || 0) : 0),
                currentResumeIndex: snapResumeIndex,
                resumeContentX: (exclusive && sourceSection !== 1)
                                ? 0
                                : (resumeList ? Number(resumeList.contentX || 0) : 0),
                resumeViewportX: (exclusive && sourceSection !== 1)
                                 ? null : savedResumeViewportX,
                resumeViewportWidth: (exclusive && sourceSection !== 1)
                                     ? null : savedResumeViewportWidth,
                currentNextUpIndex: snapNextUpIndex,
                currentLatestGroup: snapLatestGroup,
                latestIndicesByGroup: snapLatestIndices,
                latestGroupId: target.latestGroupId || "",
                latestGroupName: target.latestGroupName || "",
                latestItemId: target.latestItemId || "",
                targetItemId: target.itemId || "",
                contentY: _currentContentY(),
                exclusiveRailMemory: exclusive
            })
            Jellyfin.putBoundedMemory(root, snapshotKey, snapshot, 48)
        } catch(e) {}
    }
    function saveFocusSnapshotForce(reason) {
        _exclusiveNavigationMemoryArmed = false
        saveFocusSnapshot(reason || "navigate", true, false)
        _navigationSnapshotArmed = true
        _homeRevealReady = false
        _homeRevealPrepareActive = false
        try { homeRevealReadyTimer.stop() } catch(e0) {}
    }
    function saveExclusiveRailFocusSnapshot(reason) {
        saveFocusSnapshot(reason || "navigate-container", true, true)
        _navigationSnapshotArmed = true
        _exclusiveNavigationMemoryArmed = true
        _homeRevealReady = false
        _homeRevealPrepareActive = false
        try { homeRevealReadyTimer.stop() } catch(e0) {}
        // Même politique dans le cache Home : une recréation ultérieure ne doit pas ressusciter les anciens index des autres rails.
        try { _saveHomeCacheNow() } catch(e1) {}
    }
    function _focusSnapshot() {
        var root = _focusStoreRoot()
        if (!root) return null
        var key = _focusSnapshotKey()
        try { return root[key] || null } catch(e) { return null }
    }
    function hasFocusSnapshot(){ return !!_focusSnapshot(); }
    function _snapshotNeedsRestore(snap){ return !!snap && snap.needsRestore !== false; }
    function _markFocusSnapshotRestored() {
        var root = _focusStoreRoot()
        if (!root) return
        try { if (root[_focusSnapshotKey()]) root[_focusSnapshotKey()].needsRestore = false } catch(e) {}
    }
    function hasPendingFocusRestore(){ return _snapshotNeedsRestore(_focusSnapshot()); }

    function consumeFocusSnapshotKeepState() {
        var snap = _focusSnapshot()
        if (!snap) return false
        try { focusRestoreTimer.stop() } catch(e0) {}
        try { focusRestoreSettleTimer.stop() } catch(e1) {}
        try { resumeRestoreHorizontalTimer.stop() } catch(e2) {}
        try { folderRestoreHorizontalTimer.stop() } catch(eFolder0) {}
        _focusRestorePending = false
        _focusRestoreRetryLeft = 0
        _focusRestoreSettle = false
        _resumeRestoreHorizontalPending = false
        _resumeRestoreHorizontalRetryLeft = 0
        _resumeRestoreSavedViewportX = null
        _resumeRestoreSavedViewportWidth = null
        _folderRestoreHorizontalPending = false
        _folderRestoreHorizontalRetryLeft = 0
        // Recherche masque/désactive momentanément les ListView. Qt peut alors faire évoluer leurs currentIndex alors que focusSection == -1. Le snapshot pris AVANT l'entrée dans Recherche reste donc la vérité.
        _restoringFocus = true
        try {
            if (snap.latestIndicesByGroup && snap.latestIndicesByGroup.slice)
                latestIndicesByGroup = snap.latestIndicesByGroup.slice(0)
            currentFolderIndex = Math.max(0, snap.currentFolderIndex || 0)
            currentResumeIndex = Math.max(0, snap.currentResumeIndex || 0)
            currentNextUpIndex = Math.max(0, snap.currentNextUpIndex || 0)
            var savedLatestGroup = _latestGroupIndexFromSnapshot(snap)
            currentLatestGroup = savedLatestGroup >= 0
                    ? savedLatestGroup
                    : Math.max(0, snap.currentLatestGroup || 0)
            // Réappliquer également la position verticale exacte. Aucun focus n'est demandé ici : HomePage reste propriétaire de la topbar.
            _restoreContentY(snap)
            // Mes médias : restaurer exactement le viewport horizontal mémorisé avec son index. Sans cela, ListView.Contain peut laisser l'index correct sur une position de début de rail incorrecte.
            if (Math.max(0, Math.min(3, snap.focusSection || 0)) === 0
                    && folderList && folderList.count > 0) {
                var savedFolderX = Number(snap.folderContentX)
                if (!isFinite(savedFolderX) || isNaN(savedFolderX))
                    savedFolderX = Number(folderList.contentX || 0)
                _folderRestoreSavedContentX = savedFolderX
                _folderRestoreHorizontalPending = true
                _folderRestoreHorizontalRetryLeft = 4
                folderList.restoreHorizontalFromSnapshot(
                            savedFolderX,
                            "local-tab-handoff")
                folderRestoreHorizontalTimer.restart()
            }
            // Continuer de regarder a une géométrie variable. Réutiliser son ancrage mémorisé sans lancer la restauration globale asynchrone.
            if (resumeList && resumeList.count > 0) {
                var savedResumeX = Number(snap.resumeContentX)
                if (!isFinite(savedResumeX) || isNaN(savedResumeX))
                    savedResumeX = Number(resumeList.contentX || 0)
                var savedViewportX = null
                if (snap.resumeViewportX !== undefined
                        && snap.resumeViewportX !== null) {
                    var rawViewportX = Number(snap.resumeViewportX)
                    if (isFinite(rawViewportX) && !isNaN(rawViewportX))
                        savedViewportX = rawViewportX
                }
                resumeList.restoreHorizontalFromSnapshot(
                            savedResumeX,
                            savedViewportX,
                            "local-tab-handoff")
            }
        } catch(e3) {}
        _restoringFocus = false
        _navigationSnapshotArmed = false
        _exclusiveNavigationMemoryArmed = false
        _markFocusSnapshotRestored()
        _homeRevealPrepareActive = false
        _homeRevealReady = true
        try { homeRevealReadyTimer.stop() } catch(e4) {}
        updateBackdrop()
        return true
    }

    function restoreFocusSnapshot() {
        var snap = _focusSnapshot()
        if (!snap) return false
        if (!_snapshotNeedsRestore(snap)) return true
        _homeRevealReady = false
        _homeRevealPrepareActive = true
        try { homeRevealReadyTimer.stop() } catch(e0) {}
        _focusRestorePending = true
        _restoringFocus = true
        try {
            if (snap.latestIndicesByGroup && snap.latestIndicesByGroup.slice) latestIndicesByGroup = snap.latestIndicesByGroup.slice(0)
            currentFolderIndex = Math.max(0, snap.currentFolderIndex || 0)
            currentResumeIndex = Math.max(0, snap.currentResumeIndex || 0)
            currentNextUpIndex = Math.max(0, snap.currentNextUpIndex || 0)
            currentLatestGroup = Math.max(0, snap.currentLatestGroup || 0)
            focusSection = Math.max(0, Math.min(3, snap.focusSection || 0))
        } catch(e) {}
        _restoringFocus = false
        _focusRestoreRetryLeft = 36
        focusRestoreTimer.restart()
        return true
    }
    function _restoreContentY(snap){ if (!_vFlick || !snap) return; var maxY = Math.max(0, (_vFlick.contentHeight || 0) - (_vFlick.height || 0)); _vFlick.contentY = Math.max(0, Math.min(maxY, snap.contentY || 0)); }
    function _applyFocusSnapshotToViews() {
        if (!focusRepairEnabled) {
            return false
        }
        var snap = _focusSnapshot()
        if (!snap) {
            return false
        }
        var ok = false
        _restoringFocus = true
        try {
            var secWanted = Math.max(0, Math.min(3, snap.focusSection || 0))
            if (focusSection !== secWanted) focusSection = secWanted
            if (secWanted === 0 && folderList && folderList.count > 0) {
                var libModel = cappedLibraryItems; var fiById = MediaCatalog.findItemIndexById(libModel, snap.targetItemId); var fi = (fiById >= 0) ? fiById : MediaCatalog.clampIndex(snap.currentFolderIndex || 0, folderList.count)
                currentFolderIndex = fi
                if (folderList.currentIndex !== fi) folderList.currentIndex = fi
                var savedFolderX = Number(snap.folderContentX)
                if (!isFinite(savedFolderX) || isNaN(savedFolderX))
                    savedFolderX = Number(folderList.contentX || 0)
                _folderRestoreSavedContentX = savedFolderX
                _folderRestoreHorizontalPending = true
                _folderRestoreHorizontalRetryLeft = 4
                _restoreContentY(snap)
                folderList.forceActiveFocus()
                // forceActiveFocus + ApplyRange peuvent programmer leur propre correction du viewport. Réappliquer ensuite la position mémorisée et la stabiliser durant ~220 ms.
                folderList.restoreHorizontalFromSnapshot(
                            savedFolderX,
                            "restore-immediate")
                folderRestoreHorizontalTimer.restart()
                ok = true
            } else if (secWanted === 1 && resumeList && resumeList.count > 0) {
                var resModel = cappedResumeItems; var riById = MediaCatalog.findItemIndexById(resModel, snap.targetItemId); var ri = (riById >= 0) ? riById : MediaCatalog.clampIndex(snap.currentResumeIndex || 0, resumeList.count)
                currentResumeIndex = ri
                _restoreContentY(snap)
                var savedResumeX = Number(snap.resumeContentX)
                if (!isFinite(savedResumeX) || isNaN(savedResumeX)) savedResumeX = Number(resumeList.contentX || 0)
                var savedViewportX = null
                if (snap.resumeViewportX !== undefined && snap.resumeViewportX !== null) {
                    var rawViewportX = Number(snap.resumeViewportX)
                    if (isFinite(rawViewportX) && !isNaN(rawViewportX)) savedViewportX = rawViewportX
                }
                var savedViewportWidth = null
                if (snap.resumeViewportWidth !== undefined && snap.resumeViewportWidth !== null) {
                    var rawViewportWidth = Number(snap.resumeViewportWidth)
                    if (isFinite(rawViewportWidth) && !isNaN(rawViewportWidth)) savedViewportWidth = rawViewportWidth
                }
                _resumeRestoreSavedContentX = savedResumeX
                _resumeRestoreSavedViewportX = savedViewportX
                _resumeRestoreSavedViewportWidth = savedViewportWidth
                _resumeRestoreHorizontalPending = true
                _resumeRestoreHorizontalRetryLeft = 4
                resumeList.restoreHorizontalFromSnapshot( savedResumeX, savedViewportX, "restore-immediate")
                resumeList.forceActiveFocus()
                _vFlick.ensureSectionVisible(resumeSection, 12)
                resumeRestoreHorizontalTimer.restart()
                ok = true
            } else if (secWanted === 2 && nextUpList && nextUpList.count > 0) {
                var nextModel = cappedNextUpItems; var niById = MediaCatalog.findItemIndexById(nextModel, snap.targetItemId); var ni = (niById >= 0) ? niById : MediaCatalog.clampIndex(snap.currentNextUpIndex || 0, nextUpList.count)
                currentNextUpIndex = ni
                if (nextUpList.currentIndex !== ni) nextUpList.currentIndex = ni
                if (nextUpList.ensureIndexVisible) nextUpList.ensureIndexVisible(ni, false)
                _restoreContentY(snap)
                nextUpList.forceActiveFocus()
                _vFlick.ensureSectionVisible(nextUpSection, 12)
                ok = true
            } else if (secWanted === 3) {
                var g = _latestGroupIndexFromSnapshot(snap)
                if (g >= 0) {
                    currentLatestGroup = g
                    var e = latestByFolder[g]
                    if (e && e._evicted) {
                        _ensureLatestGroupData(g, "focus-restore")
                        _focusRestoreRetryLeft = Math.max(_focusRestoreRetryLeft, 140)
                    }
                    var arr = e && e.items ? capItems(e.items) : []; var targetLatestId = String(snap.latestItemId || snap.targetItemId || ""); var liById = MediaCatalog.findItemIndexById(arr, targetLatestId)
                    var li = (liById >= 0) ? liById : latestIndexFor(g)
                    if (liById < 0 && snap.latestIndicesByGroup && snap.latestIndicesByGroup.length > g) li = snap.latestIndicesByGroup[g]
                    li = MediaCatalog.clampIndex(li || 0, arr.length)
                    var sec = latestRepeater ? latestRepeater.itemAt(g) : null
                    if (sec) sec.evicted = false
                    if (sec && sec.listObj && sec.listObj.count > 0) {
                        _setLatestRestoreAnchor(g, li, e ? e.id : snap.latestGroupId, targetLatestId || (arr && arr[li] ? arr[li].Id : ""))
                        _forceLatestIndexForGroup(g, li)
                        sec.listObj.ensureSelectedItemVisible(false)
                        _restoreContentY(snap)
                        sec.listObj.forceActiveFocus()
                        _vFlick.ensureSectionVisible(sec, 16)
                        ok = true
                    }
                }
            }
        } catch(e) { ok = false }
        _restoringFocus = false
        if (ok) {
            _focusRestorePending = false
            _focusRestoreSettle = true
            _lastFocusRestoreOkMs = Date.now()
            _navigationSnapshotArmed = false
            _exclusiveNavigationMemoryArmed = false
            _markFocusSnapshotRestored()
            focusRestoreSettleTimer.restart()
            updateBackdrop()
            _armHomeRevealReady()
            return true
        }
        if (_focusRestoreRetryLeft > 0) {
            _focusRestoreRetryLeft--
            focusRestoreTimer.restart()
        } else {
            _focusRestorePending = false
            _navigationSnapshotArmed = false
            _exclusiveNavigationMemoryArmed = false
            _markFocusSnapshotRestored()
            scheduleHomeFocusRepair()
            _armHomeRevealReady()
        }
        return false
    }
    function scheduleFocusRestore(){ if (!focusRepairEnabled) return; var snap = _focusSnapshot(); if (!_snapshotNeedsRestore(snap)) return; _focusRestorePending = true; _focusRestoreRetryLeft = Math.max(_focusRestoreRetryLeft, 24); focusRestoreTimer.restart(); }
    readonly property int sectionMaxItems: 50
    function capItems(arr, maxN){ var n = (maxN !== undefined) ? maxN : sectionMaxItems; if (!arr || !arr.length) return []; if (arr.length <= n) return arr; return arr.slice(0, n); }
    readonly property var cappedLibraryItems: capItems(libraryItems); readonly property var cappedResumeItems: capItems(resumeItems); readonly property var cappedNextUpItems: capItems(nextUpItems)
    property bool overlayOpen: false; readonly property bool pageActive: !!(visible && enabled && !overlayOpen && focusRepairEnabled); property alias vFlick: _vFlick; readonly property bool isScrollingEff: !!(_vFlick && (_vFlick.moving || _vFlick.dragging || _vFlick.flicking))
    property int _homeFocusRepairLeft: 0
    readonly property bool allowAnims: !!(pageActive && !isScrollingEff && _homeRevealReady)
    readonly property bool allowMarquee: allowAnims; property bool fetchedOnce: false
    property bool libraryFetchCompleted: false; property bool resumeFetchCompleted: false; property bool nextUpFetchCompleted: false
    property bool _bootFetchPending: false; property string _bootFetchKey: ""; property bool _fetchInFlight: false; property string _activeFetchKey: ""
    property double _lastFetchStartMs: 0; property double _lastHomeCacheWriteMs: 0; property bool _homeImagesReady: false; property bool _homeImageReturnFreeze: false
    property bool _homePosterVisualReady: false; readonly property bool homePosterVisualReady: _homePosterVisualReady; property int homePosterProbeMs: 45; property int homePosterReadySettleMs: 90
    property bool suspendVisualTextures: false; property bool homeCurtainVisible: false; property bool _homeCurtainWarmupLatched: false; property int homeImageSettleMs: 240; property int homeImageReturnFreezeMs: 240
    readonly property bool _homeImageLoadGate: !suspendVisualTextures && _homeImagesReady && (homeCurtainVisible || _homeCurtainWarmupLatched || !_homeImageReturnFreeze)
    onSuspendVisualTexturesChanged: {
        if (suspendVisualTextures) {
            try {
                var backdrop = backdropLayerLoader.item
                if (backdrop && backdrop.releaseTextures)
                    backdrop.releaseTextures()
            } catch(e1) {}
        } else {
            _freezeHomeImagesOnReturn()
            Qt.callLater(function() {
                if (postergrid._alive && postergrid.pageActive && !postergrid.suspendVisualTextures) postergrid.updateBackdrop()
            })
        }
    }
    onHomeCurtainVisibleChanged: {
        if (homeCurtainVisible) {
            _homeCurtainWarmupLatched = true
            _scheduleHomePosterVisualProbe()
        } else {
            if (!_homeImageReturnFreeze) _homeCurtainWarmupLatched = false
            homePosterProbeTimer.stop()
            homePosterReadySettleTimer.stop()
        }
    }

    readonly property int homeCacheFreshMs: 180000; readonly property int visibleRefetchMinAgeMs: 180000
    function hasCreds() { return !!(accessToken && userId && serverUrl) }
    function _dataEmpty() {
        return (!libraryItems || libraryItems.length === 0) && (!resumeItems  || resumeItems.length  === 0) && (!nextUpItems  || nextUpItems.length  === 0) && (!latestByFolder || latestByFolder.length === 0)
    }
    function _hasVisibleHomeData() {
        return (!!(libraryItems && libraryItems.length > 0) || !!(resumeItems && resumeItems.length > 0) || !!(nextUpItems && nextUpItems.length > 0) || !!(latestByFolder && latestByFolder.length > 0))
    }
    function _restartHomeImageSettle(){ try { if (_homeImagesReady && _hasVisibleHomeData()) return; _homeImagesReady=false; homeImageSettleTimer.restart() } catch(e) {} }
    Timer { id: homeImageSettleTimer; interval: postergrid.homeImageSettleMs; repeat: false; onTriggered: postergrid._homeImagesReady = true }
    Timer { id: homeImageReturnFreezeTimer; interval: postergrid.homeImageReturnFreezeMs; repeat: false; onTriggered: { postergrid._homeImageReturnFreeze = false; postergrid._homeCurtainWarmupLatched = false; postergrid._scheduleHomePosterVisualProbe() } }
    function _freezeHomeImagesOnReturn() {
        try {
            if (!_hasVisibleHomeData()) {
                return
            }
            _homeImageReturnFreeze = true
            _homeCurtainWarmupLatched = homeCurtainVisible
            homeImageReturnFreezeTimer.restart()
        } catch(e) {}
    }
    function _sectionIntersectsViewport(sectionItem, margin) {
        if (!sectionItem || !sectionItem.visible || sectionItem.height <= 0 || !_vFlick) return false
        try {
            var m = (margin !== undefined) ? margin : 36; var p = sectionItem.mapToItem(_vFlick.contentItem, 0, 0); var top = p.y; var bottom = p.y + sectionItem.height; var viewTop = _vFlick.contentY - m
            var viewBottom = _vFlick.contentY + _vFlick.height + m
            return bottom >= viewTop && top <= viewBottom
        } catch(e) {
            return false
        }
    }
    function _scanHomeCardNode(node, state, depth) {
        if (!node || !state || depth > 3) return
        var isCardLoader = false
        try {
            isCardLoader = node.cardAllowLoad !== undefined && node.cardData !== undefined
        } catch(e0) {}
        if (isCardLoader) {
            var allowed = false
            try { allowed = node.cardAllowLoad === true } catch(e1) {}
            if (allowed) {
                state.total++
                var ready = false
                try {
                    ready = !!(node.item && node.item.homeVisualReady === true)
                } catch(e2) {}
                if (!ready) state.pending++
            }
            return
        }
        if (depth >= 3) return
        var children = null
        try { children = node.children } catch(e3) {}
        if (!children) return
        for (var i = 0; i < children.length; ++i)
            _scanHomeCardNode(children[i], state, depth + 1)
    }
    function _scanHomeList(list, state) {
        if (!list || !state) return
        try {
            if (list.count <= 0 || !list.contentItem) return
            _scanHomeCardNode(list.contentItem, state, 0)
        } catch(e) {}
    }
    function _visibleHomePosterState() {
        var state = ({ total: 0, pending: 0 })
        if (_sectionIntersectsViewport(libSection, 36)) _scanHomeList(folderList, state)
        if (_sectionIntersectsViewport(resumeSection, 36)) _scanHomeList(resumeList, state)
        if (_sectionIntersectsViewport(nextUpSection, 36)) _scanHomeList(nextUpList, state)
        if (latestRepeater) {
            for (var g = 0; g < latestRepeater.count; ++g) {
                var sec = latestRepeater.itemAt(g)
                if (!sec || !_sectionIntersectsViewport(sec, 36)) continue
                try { _scanHomeList(sec.listObj, state) } catch(e0) {}
            }
        }
        return state
    }
    function _scheduleHomePosterVisualProbe(){ if (_alive && homeCurtainVisible && !homePosterProbeTimer.running) homePosterProbeTimer.restart() }
    function _probeHomePosterVisualReady() {
        if (!_alive || !homeCurtainVisible) return
        if (!_hasVisibleHomeData()) {
            _homePosterVisualReady = true
            return
        }
        if (!_homeImagesReady || _homeImageReturnFreeze) {
            _homePosterVisualReady = false
            homePosterReadySettleTimer.stop()
            homePosterProbeTimer.restart()
            return
        }
        var state = _visibleHomePosterState()
        if (state.total <= 0) {
            _homePosterVisualReady = false
            homePosterReadySettleTimer.stop()
            homePosterProbeTimer.restart()
            return
        }
        if (state.pending > 0) {
            _homePosterVisualReady = false
            homePosterReadySettleTimer.stop()
            homePosterProbeTimer.restart()
            return
        }
        if (!_homePosterVisualReady && !homePosterReadySettleTimer.running) homePosterReadySettleTimer.restart()
    }
    function prepareHomeVisualReturn(reason) {
        _homePosterVisualReady = false
        homePosterReadySettleTimer.stop()
        if (!_hasVisibleHomeData()) {
            _homePosterVisualReady = true
            return true
        }
        if (!_homeImagesReady) _restartHomeImageSettle()
        _freezeHomeImagesOnReturn()
        _scheduleHomePosterVisualProbe()
        return false
    }
    Timer { id: homePosterProbeTimer; interval: Math.max(25, postergrid.homePosterProbeMs); repeat: false; onTriggered: postergrid._probeHomePosterVisualReady() }
    Timer {
        id: homePosterReadySettleTimer
        interval: Math.max(40, postergrid.homePosterReadySettleMs)
        repeat: false
        onTriggered: {
            if (!postergrid._alive || !postergrid.homeCurtainVisible) return
            if (postergrid._homeImageReturnFreeze || !postergrid._homeImagesReady) {
                postergrid._scheduleHomePosterVisualProbe()
                return
            }
            var state = postergrid._visibleHomePosterState()
            if ((state.total > 0 && state.pending === 0) || !postergrid._hasVisibleHomeData()) {
                postergrid._homePosterVisualReady = true
            } else {
                postergrid._homePosterVisualReady = false
                postergrid._scheduleHomePosterVisualProbe()
            }
        }
    }
    readonly property int homeCacheSchemaVersion: 16; readonly property int homeCacheMaxEntries: 2
    property string _lastHomeCacheRestoreKey: ""
    property double _lastHomeCacheRestoreCacheTs: 0
    property double _lastHomeCacheRestoreAtMs: 0
    readonly property int homeCacheRestoreDedupMs: 900
    function _touchHomeCache(store, key, now) {
        return MediaCatalog.touchHomeCache(store, key, homeCacheSchemaVersion, homeCacheFreshMs, now)
    }
    function _trimHomeCacheStore(store, keepKey) {
        MediaCatalog.trimHomeCacheStore(store, keepKey, homeCacheSchemaVersion,
                                       homeCacheFreshMs, homeCacheMaxEntries, Date.now())
    }
    function _homeCacheKey(){ return "home|" + SafeLog.shortHash(serverUrl) + "|" + SafeLog.shortHash(userId) + "|" + SafeLog.shortHash("") }
    function _homeCacheStore() { return _sharedStore("__redefinPosterGridHomeCache") }
    function _saveHomeCacheSoon() {
        if (!fetchedOnce) return
        var now = Date.now()
        if ((now - _lastHomeCacheWriteMs) < 350) return
        _lastHomeCacheWriteMs = now
        Qt.callLater(function(){ postergrid._saveHomeCacheNow() })
    }
    function _saveHomeCacheNow() {
        try {
            if (!postergrid._alive) return
            if (!postergrid.fetchedOnce || !postergrid.shared) return
            var st = postergrid._homeCacheStore()
            if (!st) return
            var cacheKey = postergrid._homeCacheKey(); var now = Date.now()
            var navSnap = postergrid._exclusiveNavigationMemoryArmed
                    ? postergrid._focusSnapshot() : null
            var cacheLatestIndices = navSnap && navSnap.latestIndicesByGroup
                    ? navSnap.latestIndicesByGroup
                    : (postergrid.latestIndicesByGroup || [])
            var cacheFolderIndex = navSnap
                    ? Math.max(0, navSnap.currentFolderIndex || 0)
                    : (postergrid.currentFolderIndex || 0)
            var cacheResumeIndex = navSnap
                    ? Math.max(0, navSnap.currentResumeIndex || 0)
                    : (postergrid.currentResumeIndex || 0)
            var cacheNextUpIndex = navSnap
                    ? Math.max(0, navSnap.currentNextUpIndex || 0)
                    : (postergrid.currentNextUpIndex || 0)
            var cacheLatestGroup = navSnap
                    ? Math.max(0, navSnap.currentLatestGroup || 0)
                    : (postergrid.currentLatestGroup || 0)
            st[cacheKey] = ({
                schemaVersion: postergrid.homeCacheSchemaVersion,
                ts: now,
                lastAccess: now,
                libraryItems: postergrid.libraryItems || [],
                resumeItems: postergrid.resumeItems || [],
                nextUpItems: postergrid.nextUpItems || [],
                latestByFolder: postergrid.latestByFolder || [],
                latestIndicesByGroup: cacheLatestIndices,
                currentFolderIndex: cacheFolderIndex,
                currentResumeIndex: cacheResumeIndex,
                currentNextUpIndex: cacheNextUpIndex,
                currentLatestGroup: cacheLatestGroup
            })
            postergrid._trimHomeCacheStore(st, cacheKey)
        } catch(e) {}
    }
    function _restoreHomeCacheIfFresh() {
        try {
            var st = _homeCacheStore()
            if (!st) {
                return false
            }
            var now = Date.now()
            var cacheKey = _homeCacheKey(); var c = _touchHomeCache(st, cacheKey, now)
            if (!c) {
                _trimHomeCacheStore(st, "")
                return false
            }
            var cacheTs = Number(c.ts || 0)
            if (_lastHomeCacheRestoreKey === cacheKey && _lastHomeCacheRestoreCacheTs === cacheTs && _lastHomeCacheRestoreAtMs > 0 && (now - _lastHomeCacheRestoreAtMs) >= 0 && (now - _lastHomeCacheRestoreAtMs) <= homeCacheRestoreDedupMs && fetchedOnce === true && libraryFetchCompleted === true && resumeFetchCompleted === true && nextUpFetchCompleted === true && latestFetchCompleted === true) {
                return true
            }
            _trimHomeCacheStore(st, cacheKey)
            var cachedLibrary = MediaCatalog.safeArray(c.libraryItems); var cachedResume  = _prepareRowMetrics(MediaCatalog.safeArray(c.resumeItems), "resume"); var cachedNextUp  = MediaCatalog.safeArray(c.nextUpItems)
            var cachedLatest  = _prepareLatestGroupsForCards(MediaCatalog.safeArray(c.latestByFolder))
            if (!MediaCatalog.homeItemsEqual(libraryItems || [], cachedLibrary)) libraryItems = cachedLibrary
            if (!MediaCatalog.homeItemsEqual(resumeItems  || [], cachedResume))  resumeItems  = cachedResume
            if (!MediaCatalog.homeItemsEqual(nextUpItems  || [], cachedNextUp))  nextUpItems  = cachedNextUp
            if (!MediaCatalog.homeLatestGroupsEqual(latestByFolder || [], cachedLatest)) latestByFolder = cachedLatest
            latestIndicesByGroup = MediaCatalog.safeArray(c.latestIndicesByGroup)
            currentFolderIndex = MediaCatalog.clampIndex(c.currentFolderIndex || 0, Math.min(libraryItems.length, sectionMaxItems))
            currentResumeIndex = MediaCatalog.clampIndex(c.currentResumeIndex || 0, Math.min(resumeItems.length, sectionMaxItems))
            currentNextUpIndex = MediaCatalog.clampIndex(c.currentNextUpIndex || 0, Math.min(nextUpItems.length, sectionMaxItems))
            currentLatestGroup = MediaCatalog.clampIndex(c.currentLatestGroup || 0, latestByFolder.length)
            fetchedOnce = true
            libraryFetchCompleted = true
            resumeFetchCompleted = true
            nextUpFetchCompleted = true
            latestFetchCompleted = true
            _fetchInFlight = false
            _bootFetchPending = false
            _bootFetchKey = _fetchKey()
            _lastFetchStartMs = Date.now()
            _homeImagesReady = true
            _freezeHomeImagesOnReturn()
            _scheduleHomePosterVisualProbe()
            updateBackdrop()
            scheduleFocusRestore()
            _lastHomeCacheRestoreKey = cacheKey
            _lastHomeCacheRestoreCacheTs = cacheTs
            _lastHomeCacheRestoreAtMs = Date.now()
            return true
        } catch(e) {
            return false
        }
    }
    function _fetchKey(){ return String(serverUrl || "") + "|" + String(userId || "") }
    function _scheduleFetchData(force) {
        if (!ready || !hasCreds()) return
        var key = _fetchKey()
        if (_restoreHomeCacheIfFresh()) return
        if (force !== true && fetchedOnce && !_dataEmpty() && key === _bootFetchKey) return
        if (_bootFetchPending && key === _bootFetchKey) return
        _bootFetchPending = true
        _bootFetchKey = key
        Qt.callLater(function(){
            try {
                if (!postergrid._alive || !postergrid.ready || !postergrid.hasCreds()) return
                if (!postergrid._bootFetchPending) return
                postergrid._bootFetchPending = false
                postergrid.fetchData()
            } catch(e) { postergrid._bootFetchPending = false }
        })
    }
    function ensureBootFetch() {
        if (!ready || !hasCreds()) return
        if (_restoreHomeCacheIfFresh()) return
        if (!fetchedOnce || _dataEmpty()) _scheduleFetchData(false)
    }
    function beginStaggeredFetch() { ensureBootFetch() }
    function fetchHomeData() { _scheduleFetchData(true) }
    Timer {
        id: _visRefetch; interval: 900; repeat: false
        onTriggered: {
            if (!postergrid.ready || !postergrid.visible) return
            if (!postergrid.hasCreds()) return
            if (postergrid.hasFocusSnapshot() && (postergrid._focusRestorePending || postergrid._focusRestoreSettle)) return
            if (postergrid.hasFocusSnapshot() && postergrid._lastFocusRestoreOkMs > 0 && (Date.now() - postergrid._lastFocusRestoreOkMs) < 30000) return
            if (postergrid.fetchedOnce && !postergrid._dataEmpty() && postergrid._lastFetchStartMs > 0 && (Date.now() - postergrid._lastFetchStartMs) < postergrid.visibleRefetchMinAgeMs) return
            postergrid._scheduleFetchData(false)
        }
    }

    onVisibleChanged: {
        if (visible) {
            ensureBootFetch()
            if (hasPendingFocusRestore()) scheduleFocusRestore()
            else _visRefetch.restart()
            scheduleBackdropHomeRepair()
        } else {
            try { if (homeImageReturnFreezeTimer.running) homeImageReturnFreezeTimer.stop() } catch(e0) {}
            try { if (homeFocusRepairTimer.running) homeFocusRepairTimer.stop() } catch(e1) {}
            _homeFocusRepairLeft = 0
            _homeImageReturnFreeze = false
        }
    }
    property int tileW: 360; property int tileH: 221; property int portW: 156; property int portH: 234; readonly property int libraryTileW: 340; readonly property int libraryTileH: 209
    property int titleH: 46; readonly property int cardTitleFontPx: 20; readonly property int cardSubtitleFontPx: 15; readonly property int sectionTitleFontPx: 26
    property int spacingW: 2; property int viewLeftMargin: 12; property int viewRightMargin: 12; property int topMargin: 120; property int bottomSpacer: 140; readonly property real frameWidth: 2.0
    readonly property real zoomScale: 1.14; readonly property int  focusLiftPx: 6; readonly property int  focusPadSide: 6; readonly property int  portraitSidePad: 2
    readonly property int  libraryCardW: libraryTileW + focusPadSide * 2; readonly property int  resumeLandscapeH: portH
    readonly property int  resumeLandscapeW: Math.round(tileW * resumeLandscapeH / tileH)
    readonly property int  resumeLandscapeCardW: resumeLandscapeW + focusPadSide * 2; readonly property int  edgePadLandscape: Math.ceil((tileW * (zoomScale - 1)) * 0.5) + 6; readonly property int  libraryEdgePad: Math.ceil((libraryTileW * (zoomScale - 1)) * 0.5) + 6
    readonly property int  resumeLandscapeEdgePad: Math.ceil((resumeLandscapeW * (zoomScale - 1)) * 0.5) + 6; readonly property int  resumePortraitFocusBleed:
        Math.max(0, Math.ceil((portW * (zoomScale - 1)) * 0.5) + 3 - portraitSidePad)
    readonly property int resumeLandscapeFocusBleed: Math.max(0, Math.ceil((resumeLandscapeW * (zoomScale - 1)) * 0.5) + 3 - focusPadSide)
    readonly property int resumeRowEdgePad: Math.max(resumePortraitFocusBleed, resumeLandscapeFocusBleed) + 14
    // Scroll manuel conservé pour « Continuer de regarder » et les rails « Récemment ajouté ». « Mes médias » et « À suivre » utilisent, eux, le comportement ListView natif historique de l'ancien « À suivre ».
    readonly property int railScrollDurationMs: 180
    readonly property int railRevealMarginPx: 10
    function topPadFor(h){ return Math.ceil(h * (zoomScale - 1)) + frameWidth + 2 + focusLiftPx; }
    readonly property int topPadLandscape: topPadFor(tileH); readonly property int libraryTopPad: topPadFor(libraryTileH); readonly property int topPadPortrait: topPadFor(portH); readonly property int cardHLandscape: tileH + titleH + topPadLandscape
    readonly property int libraryCardH: libraryTileH + titleH + libraryTopPad; readonly property int cardHPortrait: portH + titleH + topPadPortrait
    readonly property int hydrationStep: 6; readonly property int hydrationMax:  30; property int  hydrationRadius: 6; property bool hydrationDone: false
    readonly property bool hydrationAllowed: !!(pageActive && !isScrollingEff && focusSection === 3 && latestByFolder && latestByFolder.length > 0)
    Timer {
        id: hydrationTimer; interval: 120; repeat: false; running: false
        onTriggered: {
            if (!postergrid.hydrationAllowed) { stop(); return }
            if (postergrid.hydrationDone) { stop(); return }
            var r = postergrid.hydrationRadius + postergrid.hydrationStep
            if (r >= postergrid.hydrationMax) {
                postergrid.hydrationRadius = postergrid.hydrationMax
                postergrid.hydrationDone = true
                stop()
            } else {
                postergrid.hydrationRadius = r
                if (postergrid.hydrationAllowed && !postergrid.hydrationDone) restart()
            }
        }
    }
    function _resetHydration() {
        hydrationDone = false
        hydrationRadius = 6
        if (hydrationAllowed) hydrationTimer.restart()
        else hydrationTimer.stop()
    }
    onHydrationAllowedChanged: {
        if (!hydrationAllowed) hydrationTimer.stop()
        else if (!hydrationDone) hydrationTimer.restart()
    }
    property int bgBlur: 8

    property real bgDarken: 0.40; readonly property int  bgCapW: 1280; readonly property int  bgCapH: 720; readonly property int  bgQuality: 80; readonly property real posterScale: 1.35; readonly property int posterQFast: 90
    readonly property real hqPosterScale: 1.60; readonly property int hqPosterQuality: 92; property string hqPosterTargetId: ""; readonly property string hqPosterCandidateId: { if (!pageActive || isScrollingEff || focusSection < 0 || !_hasAnyHomeListFocus()) return ""; var d = _currentFocusTarget(); return d && d.itemId ? String(d.itemId) : "" }
    Timer { id: hqPosterTimer; interval: 320; repeat: false; onTriggered: { var id = postergrid.hqPosterCandidateId; postergrid.hqPosterTargetId = (id && postergrid.pageActive && !postergrid.isScrollingEff && postergrid._hasAnyHomeListFocus()) ? id : "" } }
    onHqPosterCandidateIdChanged: { hqPosterTargetId = ""; hqPosterTimer.stop(); if (hqPosterCandidateId.length) hqPosterTimer.restart() }
    readonly property var homeCardLayout: ({
        portraitWidth: portW,
        landscapeWidth: resumeLandscapeW,
        portraitSidePad: portraitSidePad,
        landscapeSidePad: focusPadSide,
        portraitFocusBleed: resumePortraitFocusBleed,
        landscapeFocusBleed: resumeLandscapeFocusBleed,
        spacing: spacingW
    })
    function _mediaCardUsesLandscape(it, sectionKind) {
        return MediaCatalog.homeCardUsesLandscape(it, sectionKind)
    }
    function mediaCardTileWidthFor(it, sectionKind) {
        return MediaCatalog.homeCardTileWidthFor(it, sectionKind, portW, resumeLandscapeW)
    }
    function mediaCardTileHeightFor(it, sectionKind){ return portH; }
    function mediaCardTopPadFor(it, sectionKind){ return topPadPortrait; }
    function mediaCardSidePadFor(it, sectionKind) {
        return MediaCatalog.homeCardSidePadFor(it, sectionKind, portraitSidePad, focusPadSide)
    }
    function mediaCardDelegateWidthFor(it, sectionKind) {
        return mediaCardTileWidthFor(it, sectionKind)
                + mediaCardSidePadFor(it, sectionKind) * 2
    }
    function mediaCardPreferBackdropFor(it, sectionKind) {
        return MediaCatalog.homeCardPrefersBackdrop(it, sectionKind)
    }
    function mediaCardFallbackKindFor(it, sectionKind) {
        return MediaCatalog.homeCardFallbackKind(it, sectionKind)
    }
    function _prepareRowMetrics(items, sectionKind) {
        return MediaCatalog.prepareHomeRowMetrics(items, sectionKind, homeCardLayout)
    }
    function _rowItemWidthAt(arr, idx, sectionKind) {
        return MediaCatalog.homeRowItemWidthAt(arr, idx, sectionKind, homeCardLayout)
    }
    function _rowItemBleedAt(arr, idx, sectionKind) {
        return MediaCatalog.homeRowItemBleedAt(arr, idx, sectionKind, homeCardLayout)
    }
    function _rowItemLeftAt(arr, idx, sectionKind, spacing) {
        return MediaCatalog.homeRowItemLeftAt(arr, idx, sectionKind, spacing, homeCardLayout)
    }
    function _rowLogicalWidth(arr, sectionKind, spacing, edgePad, viewportWidth) {
        return MediaCatalog.homeRowLogicalWidth(arr, sectionKind, spacing, edgePad,
                                                 viewportWidth, homeCardLayout)
    }
    function _rowRealDelegateGeometry(list, idx) {
        if (!list || idx < 0) return null
        var delegateItem = null
        try {
            if (list.itemAtIndex) delegateItem = list.itemAtIndex(idx)
        } catch(e0) {}
        if (!delegateItem) return null
        try {
            var p = delegateItem.mapToItem(list, 0, 0); var vx = Number(p ? p.x : NaN); var vy = Number(p ? p.y : NaN); var w = Number(delegateItem.width); var h = Number(delegateItem.height); var cx = Number(list.contentX || 0)
            var contentLeft = Number(delegateItem.x)
            if (!isFinite(vx) || isNaN(vx) || !isFinite(w) || isNaN(w) || w <= 0) return null
            return ({
                item: delegateItem, viewportX: vx, viewportY: (isFinite(vy) && !isNaN(vy)) ? vy : 0, width: w, height: (isFinite(h) && !isNaN(h)) ? h : 0, contentX: cx, contentLeft: (isFinite(contentLeft) && !isNaN(contentLeft)) ? contentLeft : (cx + vx)
            })
        } catch(e1) {
            return null
        }
    }
    function _resumeSnapshotViewportGeometry(){ if (!resumeList || resumeList.count <= 0) return null; var idx = MediaCatalog.clampIndex(currentResumeIndex, resumeList.count); return _rowRealDelegateGeometry(resumeList, idx); }

    // MOTEUR MANUEL DE GLISSEMENT HORIZONTAL Utilisé uniquement par « Continuer de regarder » et « Récemment ajouté ». « Mes médias » et « À suivre » conservent le glide natif historique ListView (SnapOneItem + ApplyRange + highlightMoveDuration 120).
    function _railNativeMinX(list) {
        if (!list) return 0
        var ox = Number(list.originX)
        if (isFinite(ox) && !isNaN(ox)) return ox
        var cx = Number(list.contentX)
        return (isFinite(cx) && !isNaN(cx)) ? cx : 0
    }
    function _railNativeMaxX(list) {
        if (!list) return 0
        var minX = _railNativeMinX(list)
        var cw = Number(list.contentWidth)
        var vw = Number(list.width)
        if (!isFinite(cw) || isNaN(cw) || cw < 0) cw = 0
        if (!isFinite(vw) || isNaN(vw) || vw < 0) vw = 0
        return Math.max(minX, minX + Math.max(0, cw - vw))
    }
    function _railNativeClampX(list, value) {
        if (!list) return 0
        var x = Number(value)
        if (!isFinite(x) || isNaN(x)) x = _railNativeMinX(list)
        return Math.max(_railNativeMinX(list), Math.min(_railNativeMaxX(list), x))
    }
    function _animateRailX(list, animation, target) {
        if (!list || !animation) return
        target = Number(target)
        if (!isFinite(target) || isNaN(target)) return
        var fromX = Number(list.contentX || 0)
        var delta = Math.abs(target - fromX)
        if (animation.running && Math.abs(Number(animation.to || 0) - target) < 0.75) return
        // Retarget : aucune file d'animations. Le nouveau glide repart de la position réellement affichée au moment du nouvel appui D-Pad.
        animation.stop()
        if (delta < 0.75) {
            list.contentX = target
            return
        }
        if (!allowAnims || _restoringFocus || _focusRestorePending || _focusRestoreSettle || !_homeRevealReady) {
            list.contentX = target
            return
        }
        animation.from = fromX
        animation.to = target
        animation.duration = railScrollDurationMs
        animation.start()
    }
    function _setRailXImmediate(list, animation, target) {
        if (!list) return
        if (animation) animation.stop()
        target = Number(target)
        if (isFinite(target) && !isNaN(target)) list.contentX = target
    }
    // Alias conservés pour la restauration spécifique de Continuer de regarder.
    function _resumeNativeClampX(list, value) { return _railNativeClampX(list, value) }
    function _resumeRealTargetX(list, idx) {
        if (!list || idx < 0) return NaN
        var real = _rowRealDelegateGeometry(list, idx)
        if (!real) return NaN
        var arr = cappedResumeItems || []
        var bleed = _rowItemBleedAt(arr, idx, "resume")
        var pad = railRevealMarginPx
        var visualLeft = real.viewportX - bleed
        var visualRight = real.viewportX + real.width + bleed
        var delta = 0
        if (visualLeft < pad) delta = visualLeft - pad
        else if (visualRight > list.width - pad) delta = visualRight - (list.width - pad)
        return _resumeNativeClampX(list, Number(list.contentX || 0) + delta)
    }
    function _resumeDirectionalNaturalTargetX(list, fromIdx, toIdx, direction) {
        if (!list || direction === 0 || fromIdx < 0 || toIdx < 0) return NaN
        var arr = cappedResumeItems || []
        if (toIdx >= arr.length || fromIdx >= arr.length) return NaN
        var spacing = Number(list.spacing || 0)
        if (!isFinite(spacing) || isNaN(spacing)) spacing = 0
        var currentReal = _rowRealDelegateGeometry(list, fromIdx)
        var targetWidth = _rowItemWidthAt(arr, toIdx, "resume")
        var currentWidth = _rowItemWidthAt(arr, fromIdx, "resume")
        var targetBleed = _rowItemBleedAt(arr, toIdx, "resume")
        var pad = railRevealMarginPx
        if (currentReal) {
            var predictedViewportX
            if (direction < 0) predictedViewportX = currentReal.viewportX - spacing - targetWidth
            else predictedViewportX = currentReal.viewportX + currentReal.width + spacing
            var visualLeft = predictedViewportX - targetBleed
            var visualRight = predictedViewportX + targetWidth + targetBleed
            var delta = 0
            if (visualLeft < pad) delta = visualLeft - pad
            else if (visualRight > list.width - pad) delta = visualRight - (list.width - pad)
            return _resumeNativeClampX(list, Number(list.contentX || 0) + delta)
        }
        var step = direction < 0 ? -(targetWidth + spacing) : (currentWidth + spacing)
        return _resumeNativeClampX(list, Number(list.contentX || 0) + step)
    }
    function _rowMinX(list){
        return list ? MediaCatalog.homeRowMinX(list.originX, list.edgePad) : 0
    }
    function _rowMaxX(list){
        if (!list) return 0
        var minX = _rowMinX(list)
        return MediaCatalog.rowMaxX(minX, list.logicalContentWidth, list.width)
    }
    function _rowClampX(list, x) {
        if (!list) return 0
        return MediaCatalog.rowClampX(x, _rowMinX(list), _rowMaxX(list))
    }
    function _rowTargetX(list, arr, idx, sectionKind) {
        if (!list) return 0
        if (!arr || idx < 0 || idx >= arr.length) return _rowMinX(list)

        var bleed = _rowItemBleedAt(arr, idx, sectionKind)
        var pad = railRevealMarginPx
        if (sectionKind === "resume") {
            var real = _rowRealDelegateGeometry(list, idx)
            if (real) {
                var realVisualLeft = real.viewportX - bleed
                var realVisualRight = real.viewportX + real.width + bleed
                var delta = 0
                if (realVisualLeft < pad) delta = realVisualLeft - pad
                else if (realVisualRight > list.width - pad)
                    delta = realVisualRight - (list.width - pad)
                return _rowClampX(list, Number(list.contentX || 0) + delta)
            }
        }

        return MediaCatalog.homeRowTargetX(arr, idx, sectionKind, list.spacing,
                                             list.contentX, list.width, pad,
                                             _rowMinX(list), _rowMaxX(list),
                                             homeCardLayout)
    }
    function _ensureRowIndexVisible(list, items, idx, sectionKind, animation, animateMove, seq) {
        function apply() {
            if (!postergrid._alive || seq !== list._ensureVisibleSeq || idx < 0 || idx >= items.length) return
            var target = postergrid._rowTargetX(list, items, idx, sectionKind)
            if (animateMove === true) postergrid._animateRailX(list, animation, target)
            else postergrid._setRailXImmediate(list, animation, target)
        }
        if (animateMove === true) Qt.callLater(apply)
        else apply()
    }
    function _prepareLatestGroupsForCards(groups) {
        return MediaCatalog.prepareHomeLatestGroups(groups, homeCardLayout)
    }
    function latestIndexFor(group) { var v = (latestIndicesByGroup && latestIndicesByGroup.length > group) ? latestIndicesByGroup[group] : 0; return (typeof v === "number" && v >= 0) ? v : 0 }
    function _forceLatestIndexForGroup(group, idx) {
        group = Math.max(0, group | 0)
        var wanted = Math.max( 0, Math.min(idx | 0, sectionMaxItems - 1)
        )
        if (latestIndexFor(group) === wanted) return false
        var values = (latestIndicesByGroup && latestIndicesByGroup.slice) ? latestIndicesByGroup.slice(0) : []
        values[group] = wanted
        latestIndicesByGroup = values
        return true
    }
    function setLatestIndexForGroup(group, idx) {
        if (_restoringFocus || _focusRestorePending || _focusRestoreSettle || focusSection !== 3 || currentLatestGroup !== group) return
        if (_forceLatestIndexForGroup(group, idx)) saveFocusSnapshot("latestIndex")
    }
    function armLatestSnapshotForNavigation(group, idx, reason) {
        group = Math.max(0, Math.min(group|0, latestByFolder ? latestByFolder.length - 1 : 0)); idx = Math.max(0, idx|0)
        focusSection = 3; currentLatestGroup = group; _forceLatestIndexForGroup(group, idx)
        var sec = latestRepeater ? latestRepeater.itemAt(group) : null
        if (sec && sec.listObj) { _forceLatestIndexForGroup(group, MediaCatalog.clampIndex(idx, sec.listObj.count)); sec.listObj.ensureSelectedItemVisible(false) }
        saveFocusSnapshotForce(reason || "nav-latest")
    }
    function currentLatestItem() {
        if (!latestByFolder || latestByFolder.length === 0) return null
        var group = Math.max(0, Math.min(currentLatestGroup, latestByFolder.length - 1))
        var items = latestByFolder[group] ? (latestByFolder[group].items || []) : []
        if (!items || items.length === 0) return null
        var idx = MediaCatalog.clampIndex(latestIndexFor(group), Math.min(items.length, sectionMaxItems))
        return (idx >= 0 && idx < items.length) ? items[idx] : null
    }
    function navIdsForEpisodeLike(it) {
        return MediaCatalog.navigationIdsForEpisodeLike(it)
    }

    function openEpisodeLike(it) {
        if (!it) return
        var ids = navIdsForEpisodeLike(it)
        if (ids.seasonId && ids.seriesId) { requestSeasonPage(ids.seriesId, ids.seasonId, ids.episodeId); return }
        var seriesId = ids.seriesId || (it.SeriesId || "")
        if (!seriesId) { requestSeasonPage("", "", ids.episodeId); return }
        var targetSeasonIndex = (it.ParentIndexNumber != null) ? it.ParentIndexNumber : -1
        Jellyfin.fetchSeasons(serverUrl, accessToken, userId, seriesId, function(seasons) {
            seasons = seasons || []
            var seasonId = it.SeasonId || ""
            if (!seasonId && targetSeasonIndex >= 0) for (var i=0; i<seasons.length; ++i) { var s = seasons[i] || {}; if (s.IndexNumber != null && s.IndexNumber === targetSeasonIndex) { seasonId = s.Id || ""; break } }
            if (!seasonId && seasons.length > 0) seasonId = seasons[0].Id || ""
            requestSeasonPage(seriesId, seasonId, ids.episodeId)
        }, function(){ requestSeasonPage(seriesId, "", ids.episodeId) })
    }
    function openSeries(seriesId) {
        if (!seriesId || !serverUrl || !accessToken || !userId) return
        Jellyfin.fetchSeasons(serverUrl, accessToken, userId, seriesId, function(items) {
            items = items || []
            var first = items.length > 0 ? items[0] : null
            requestSeasonPage(seriesId, first ? (first.Id || "") : "", "")
        }, function() { requestSeasonPage(seriesId, "", "") })
    }
    property int _personalResumeRouteSeq: 0
    function _openStandardContentItem(it) {
        if (!it) return
        var t = MediaCatalog.itemTypeLower(it)
        if (t === "movie" || t === "video" || t === "musicvideo") {
            requestDetailMovie(it.Id)
        } else if (t === "season") {
            // /Items/Latest groupé renvoie la saison comme vraie carte. SeriesId est normalement présent ; ParentId est son fallback DTO.
            var seasonId = String(it.Id || "")
            var seriesId = String(it.SeriesId || it.ParentId || "")
            requestSeasonPage(seriesId, seasonId, "")
        } else if (t === "series") {
            openSeries(it.Id)
        } else if (t === "episode") {
            openEpisodeLike(it)
        } else {
            playItem(it)
        }
    }
    function _openPersonalMediaResumeItem(it) {
        if (!it || !it.Id || !MediaCatalog.personalMediaTypeCanUseViewer(it)) return false
        var itemId = String(it.Id)
        // Preuve la plus rapide : l'item figure déjà dans un rail récent rattaché à une bibliothèque personnelle. C'est exactement le chemin déjà utilisé par « Récemment ajouté ».
        var recentRoot = MediaCatalog.personalMediaRecentRootIdForItem(it, latestByFolder)
        if (recentRoot) {
            requestPersonalMediaPage(recentRoot, itemId)
            return true
        }
        var rootMap = MediaCatalog.personalMediaRootMap(libraryItems)
        var hasPersonalRoot = false
        for (var rk in rootMap) {
            if (Object.prototype.hasOwnProperty.call(rootMap, rk)) { hasPersonalRoot = true; break }
        }
        if (!hasPersonalRoot) return false
        // ParentId n'est pas une preuve de bibliothèque : il pointe souvent vers un sous-dossier. L'API Jellyfin dédiée /Items/{id}/Ancestors fournit la chaîne exacte jusqu'à la racine. Le clic est donc retenu jusqu'à cette décision, sans jamais passer prématurément à DetailMoviePage.
        var seq = ++_personalResumeRouteSeq
        Jellyfin.fetchItemAncestors(serverUrl, accessToken, userId, itemId, function(ancestors) {
            if (!postergrid._alive || seq !== postergrid._personalResumeRouteSeq) return
            var rootId = MediaCatalog.personalRootIdFromAncestors(ancestors, rootMap)
            if (rootId) {
                postergrid.requestPersonalMediaPage(rootId, itemId)
                return
            }
            postergrid._openStandardContentItem(it)
        }, function() {
            if (!postergrid._alive || seq !== postergrid._personalResumeRouteSeq) return
            postergrid._openStandardContentItem(it)
        })
        return true
    }
    function openContentItem(it, unsupportedMessage, sourceEntry) {
        if (!it) return
        if (MediaCatalog.isPersonalMediaLatestEntry(sourceEntry) && sourceEntry.id && it.Id) {
            requestPersonalMediaPage(sourceEntry.id, String(it.Id))
            return
        }
        // « Continuer de regarder » n'a pas de sourceEntry. Les vidéos/photos issues d'une bibliothèque personnelle doivent pourtant suivre le même chemin que « Récemment ajouté » et s'ouvrir dans PersonalMediaPage.
        if (!sourceEntry && _openPersonalMediaResumeItem(it)) return
        if (unsupportedMessage && MediaCatalog.isUnsupportedMediaItem(it)) {
            unsupportedLoader.openUnsupported(unsupportedMessage)
            return
        }
        _openStandardContentItem(it)
    }

    // La taxonomie de bibliothèques est pure et partagée dans MediaCatalog. PosterGrid conserve uniquement la décision de navigation et le focus Home.
    function openUnsupportedFolder(lib) {
        var name = lib && lib.Name ? String(lib.Name) : "Ce média"
        unsupportedLoader.openUnsupported(name + " : fonctionnalité non supportée")
    }
    function openLibraryEntry(it) {
        if (!it) return
        var t = MediaCatalog.itemTypeLower(it)
        // Refus explicite avant toute route. Important pour les vues plugin qui peuvent être marquées IsFolder=false ou utiliser un Type générique.
        if (MediaCatalog.isKnownUnsupportedLibraryFolder(it)) {
            openUnsupportedFolder(it)
            return
        }
        if (it.IsFolder && !MediaCatalog.isSupportedRootMediaFolder(it)) {
            openUnsupportedFolder(it)
            return
        }
        if (MediaCatalog.isCollectionsLibraryFolder(it)) requestCollectionPage(it.Id)
        else if (MediaCatalog.isPersonalMediaLibraryFolder(it)) requestPersonalMediaPage(it.Id, "")
        else if (MediaCatalog.isMixedLibraryFolder(it)) requestSeriesPage(it.Id, "mixed")
        else if (MediaCatalog.folderShouldOpenOnMoviePage(it)) requestMoviePage(it.Id)
        else if (MediaCatalog.isSeriesLibraryFolder(it)) requestSeriesPage(it.Id, "series")
        else if (t === "movie") requestDetailMovie(it.Id)
        else if (t === "series") openSeries(it.Id)
        else if (MediaCatalog.isUnsupportedMediaItem(it)) openUnsupportedFolder(it)
        else playItem(it)
    }
    readonly property int latestFullLimit: 50; readonly property int latestMaxInflight: 2; readonly property int latestStartDelayMs: 110; readonly property int latestProximityLibraryStep: 3
    readonly property int latestInitialRequestTimeoutMs: 6500
    property var _latestLibs: []; property int _latestPos: 0; property int _latestInFlight: 0; property int _latestQueueSeq: 0; property var _latestReloadHandles: ({})
    property var _latestInitialPending: ({})

    property int _latestStageTarget: 0; property bool _latestInitialComplete: false; property bool _latestAllComplete: false; property bool latestFetchCompleted: false
    function _latestQueueDone(){ return _latestLibs && _latestPos >= _latestLibs.length && _latestInFlight <= 0; }
    Timer { id: latestPumpTimer; interval: postergrid.latestStartDelayMs; repeat: false; onTriggered: postergrid._pumpLatestInitial() }
    Timer { id: latestInitialWatchdog; interval: 500; repeat: true; running: postergrid._alive && postergrid._latestInFlight > 0; onTriggered: postergrid._sweepLatestInitialRequests() }
    function _registerLatestInitialRequest(idx, handle) {
        var key = String(idx)
        var pending = _latestInitialPending || ({})
        var rec = pending[key]
        if (!rec) {
            rec = ({
                idx: idx, seq: _latestQueueSeq, startedAt: Date.now(), handle: handle || null
            })
            pending[key] = rec
            _latestInitialPending = pending
        } else {
            rec.handle = handle || null
        }
        return rec
    }
    function _cancelLatestInitialRequests(reason, finishAsFailure) {
        var pending = _latestInitialPending || ({})
        var keys = []
        for (var key in pending)
            if (Object.prototype.hasOwnProperty.call(pending, key) && pending[key]) keys.push(key)
        for (var i = 0; i < keys.length; ++i) {
            var rec = pending[keys[i]]
            if (!rec) continue
            var handle = rec.handle
            if (finishAsFailure === true) _finishLatestRequest(rec.idx, null, reason || "cancel")
            else {
                try { delete pending[keys[i]] } catch(e0) {}
                _latestInFlight = Math.max(0, _latestInFlight - 1)
            }
            try {
                if (handle && typeof handle.cancel === "function") handle.cancel(reason || "cancelled")
            } catch(e1) {}
        }
        if (finishAsFailure !== true)
            _latestInitialPending = ({})
    }
    function _sweepLatestInitialRequests() {
        if (!_alive || _latestInFlight <= 0) return
        var now = Date.now()
        var pending = _latestInitialPending || ({})
        var expired = []
        for (var key in pending) {
            if (!Object.prototype.hasOwnProperty.call(pending, key)) continue
            var rec = pending[key]
            if (rec && (now - Number(rec.startedAt || now)) >= latestInitialRequestTimeoutMs) expired.push(rec)
        }
        for (var i = 0; i < expired.length; ++i) {
            var rec = expired[i]
            var handle = rec ? rec.handle : null
            if (rec) _finishLatestRequest(rec.idx, null, "watchdog-timeout")
            try {
                if (handle && typeof handle.cancel === "function") handle.cancel("latest-watchdog-timeout")
            } catch(e0) {}
        }
    }

    function _startLatestInitialQueue(libs, fetchSeq) {
        _cancelLatestReloads("latest_queue_restarted")
        _cancelLatestInitialRequests("latest_queue_restarted", false)
        postergrid._latestInitialPending = ({})
        postergrid._latestQueueSeq = (fetchSeq !== undefined && fetchSeq !== null) ? fetchSeq : postergrid._fetchSeq
        postergrid._latestLibs = MediaCatalog.safeArray(libs)
        postergrid._latestPos = 0
        postergrid._latestInFlight = 0
        postergrid._latestTemp = new Array(postergrid._latestLibs.length)
        for (var i=0;i<postergrid._latestTemp.length;i++) {
            postergrid._latestTemp[i] = null
            var lid = postergrid._latestLibs[i] && postergrid._latestLibs[i].Id ? String(postergrid._latestLibs[i].Id) : ""
            for (var c=0; lid && postergrid.latestByFolder && c<postergrid.latestByFolder.length; ++c) {
                if (postergrid.latestByFolder[c] && String(postergrid.latestByFolder[c].id || "") === lid) {
                    postergrid._latestTemp[i] = postergrid.latestByFolder[c]
                    break
                }
            }
        }
        postergrid._latestStageTarget = postergrid._latestLibs.length
        postergrid._latestInitialComplete = false
        postergrid._latestAllComplete = false
        postergrid.latestFetchCompleted = false
        if (!postergrid.fetchedOnce || !postergrid.latestByFolder || postergrid.latestByFolder.length === 0) postergrid._setLatestByFolderIfChanged([])
        if (!_focusRestorePending && !_restoringFocus) {
            postergrid.latestIndicesByGroup = []
            postergrid.currentLatestGroup = 0
        }
        if (postergrid._latestLibs.length === 0) {
            postergrid._latestInitialComplete = true
                postergrid.latestFetchCompleted = true
            postergrid._rebuildLatestByFolderFromTemp()
            return
        }
        latestPumpTimer.restart()
    }
    function _publishLatestFromTemp() {
        var out = []
        for (var i=0; i<postergrid._latestTemp.length; i++) {
            var e = postergrid._latestTemp[i]
            if (e && ((e.items && e.items.length > 0) || (e._evicted && e._hadItems))) out.push(e)
        }
        postergrid._setLatestByFolderIfChanged(out)
        var inds = (postergrid.latestIndicesByGroup && postergrid.latestIndicesByGroup.slice) ? postergrid.latestIndicesByGroup.slice(0) : []
        while (inds.length < out.length) inds.push(0)
        if (!postergrid.latestIndicesByGroup || inds.length !== postergrid.latestIndicesByGroup.length) postergrid.latestIndicesByGroup = inds
        if (!_focusRestorePending && !_restoringFocus) postergrid.currentLatestGroup = MediaCatalog.clampIndex(postergrid.currentLatestGroup, out.length)
    }
    function _rebuildLatestByFolderFromTemp() {
        postergrid._publishLatestFromTemp()
        postergrid._latestAllComplete = postergrid._latestQueueDone()
        postergrid.latestFetchCompleted = postergrid._latestAllComplete
    }
    function _fetchLatestForFolderId(parentId, limit, groupItems, ok, ko) {
        return Jellyfin.fetchHomeLatestItemsForParent(
                    serverUrl, accessToken, userId, parentId, limit,
                    function(items) { if (ok) ok(MediaCatalog.safeArray(items)) },
                    function(code) { if (ko) ko(String(code || "network_error")) },
                    groupItems === true
        )
    }
    function _cancelLatestReloads(reason) {
        var handles = _latestReloadHandles || ({})
        _latestReloadHandles = ({})
        for (var key in handles) {
            if (!Object.prototype.hasOwnProperty.call(handles, key)) continue
            try { if (handles[key] && handles[key].cancel) handles[key].cancel(reason || "cancelled") } catch(e) {}
        }
    }
    function _latestReloadCount() {
        var handles = _latestReloadHandles || ({}), count = 0
        for (var key in handles)
            if (Object.prototype.hasOwnProperty.call(handles, key) && handles[key]) count++
        return count
    }
    function _latestEntryIndexById(id) {
        id = String(id || "")
        for (var i = 0; id && latestByFolder && i < latestByFolder.length; ++i)
            if (latestByFolder[i] && String(latestByFolder[i].id || "") === id) return i
        return -1
    }
    function _updateLatestTempEntry(entry) {
        var id = String(entry && entry.id || "")
        for (var i = 0; id && _latestLibs && i < _latestLibs.length; ++i) {
            if (_latestLibs[i] && String(_latestLibs[i].Id || "") === id) {
                _latestTemp[i] = entry
                return true
            }
        }
        return false
    }
    function _replaceLatestEntry(groupIndex, entry, saveNow) {
        if (!latestByFolder || groupIndex < 0 || groupIndex >= latestByFolder.length || !entry) return false
        var next = latestByFolder.slice(0)
        next[groupIndex] = entry
        _updateLatestTempEntry(entry)
        _setLatestByFolderIfChanged(next)
        if (saveNow === true) _saveHomeCacheNow()
        return true
    }
    function _ensureLatestGroupData(groupIndex, reason) {
        if (!_alive || !hasCreds() || !latestByFolder || groupIndex < 0 || groupIndex >= latestByFolder.length) return false
        var entry = latestByFolder[groupIndex]
        if (!entry || !entry._evicted || !entry.id) return false
        var id = String(entry.id)
        if (_latestReloadHandles && _latestReloadHandles[id]) return true
        var urgent = reason === "focus" || reason === "focus-restore" || reason === "force-load"
        if (!urgent && _latestReloadCount() >= latestMaxInflight) {
            latestReloadRetryTimer.restart()
            return true
        }
        var seq = _fetchSeq; var handle = null
        handle = _fetchLatestForFolderId(
                    id,
                    latestFullLimit,
                    MediaCatalog.isSeriesLibraryFolder(entry),
                    function(items) {
                if (!_safeCanTouch(seq) || !_latestReloadHandles || _latestReloadHandles[id] !== handle) return
                delete _latestReloadHandles[id]
                var arr = MediaCatalog.safeArray(items); var idx = _latestEntryIndexById(id)
                if (idx < 0 || arr.length <= 0) {
                    latestReloadRetryTimer.restart()
                    return
                }
                var current = latestByFolder[idx] || entry; var restored = MediaCatalog.shallowCloneObject(current)
                restored.items = arr
                restored._evicted = false
                restored._hadItems = true
                restored._evictedAt = 0
                _replaceLatestEntry(idx, restored, true)
                var sec = latestRepeater ? latestRepeater.itemAt(idx) : null
                if (sec) sec.evicted = false
                updateBackdrop()
                if (_focusRestorePending) {
                    _focusRestoreRetryLeft = Math.max(_focusRestoreRetryLeft, 36)
                    focusRestoreTimer.restart()
                } else if (focusSection === 3 && currentLatestGroup === idx) {
                    Qt.callLater(function(){ if (_alive) focusLatestGroup(idx) })
                }
            }, function() {
                if (_latestReloadHandles && _latestReloadHandles[id] === handle) delete _latestReloadHandles[id]
                if (_alive) latestReloadRetryTimer.restart()
            }
        )
        _latestReloadHandles[id] = handle
        return true
    }
    function _finishLatestRequest(idx, entry, reason) {
        var key = String(idx)
        var pending = _latestInitialPending || ({})
        var rec = pending[key]
        if (!rec) {
            return false
        }
        try { delete pending[key] } catch(e0) {}
        _latestInitialPending = pending
        _latestInFlight = Math.max(0, _latestInFlight - 1)
        _latestTemp[idx] = entry
        var stageDone = _latestPos >= _latestStageTarget && _latestInFlight <= 0
        if (stageDone && !_latestInitialComplete) _latestInitialComplete = true
        _rebuildLatestByFolderFromTemp()
        if (stageDone) {
            _resetHydration()
            updateBackdrop()
            if ((!latestByFolder || latestByFolder.length === 0) && _latestPos < _latestLibs.length) requestMoreLatestForProximity()
        } else if (_latestPos < _latestStageTarget) {
            latestPumpTimer.restart()
        }
        return true
    }
    function _pumpLatestInitial() {
        if (!postergrid._safeCanTouch(postergrid._latestQueueSeq)) return
        var target = Math.min(postergrid._latestLibs.length, postergrid._latestStageTarget)
        if (postergrid._latestPos >= target) {
            if (postergrid._latestInFlight <= 0) {
                if (!postergrid._latestInitialComplete) postergrid._latestInitialComplete = true
                postergrid._rebuildLatestByFolderFromTemp()
                postergrid._resetHydration()
                postergrid.updateBackdrop()
            }
            return
        }
        if (postergrid._latestInFlight >= postergrid.latestMaxInflight) { latestPumpTimer.restart(); return }
        var idx = postergrid._latestPos++; var lib = postergrid._latestLibs[idx]
        if (!lib || !lib.Id) {
            postergrid._latestTemp[idx] = null
            var invalidStageDone = postergrid._latestPos >= target && postergrid._latestInFlight <= 0
            if (invalidStageDone) postergrid._latestInitialComplete = true
            postergrid._rebuildLatestByFolderFromTemp()
            if (postergrid._latestPos < target) latestPumpTimer.restart()
            else if (invalidStageDone && (!latestByFolder || latestByFolder.length === 0) && postergrid._latestPos < postergrid._latestLibs.length) requestMoreLatestForProximity()
            return
        }
        postergrid._latestInFlight++
        postergrid._registerLatestInitialRequest(idx, null)
        var latestHandle = _fetchLatestForFolderId(
                    lib.Id,
                    latestFullLimit,
                    MediaCatalog.isSeriesLibraryFolder(lib),
                    function(arr) {
                try {
                    if (!postergrid._safeCanTouch(postergrid._latestQueueSeq)) return
                    postergrid._finishLatestRequest(idx, {
                        id: lib.Id, name: lib.Name || "Section", items: MediaCatalog.safeArray(arr), ct: lib.CollectionType || "", t: lib.Type || ""
                    }, "success")
                } catch(e1) {}
            }, function(code) {
                try {
                    if (postergrid._safeCanTouch(postergrid._latestQueueSeq)) postergrid._finishLatestRequest(idx, null, String(code || "error"))
                } catch(e2) {}
            }
        )
        postergrid._registerLatestInitialRequest(idx, latestHandle)
        if (postergrid._latestPos < target) latestPumpTimer.restart()
    }
    function requestMoreLatestForProximity() {
        if (!postergrid._safeCanTouch(postergrid._latestQueueSeq)) return false
        if (!_latestLibs || _latestPos >= _latestLibs.length) {
            _latestAllComplete = _latestInFlight <= 0
            return false
        }
        var nextTarget = Math.min(_latestLibs.length, Math.max(_latestStageTarget, _latestPos) + latestProximityLibraryStep)
        if (nextTarget <= _latestStageTarget && _latestPos >= _latestStageTarget) return false
        _latestStageTarget = nextTarget
        latestPumpTimer.restart()
        return true
    }
    function forceHomeBootstrapCompletion(reason) {
        if (!_alive) return false
        try { latestPumpTimer.stop() } catch(e0) {}
        _cancelLatestInitialRequests(reason || "home-timeout", true)
        try { latestPumpTimer.stop() } catch(e1) {}
        _latestPos = _latestLibs ? _latestLibs.length : _latestPos
        _latestStageTarget = _latestPos
        _latestInitialComplete = true
        _latestAllComplete = true
        latestFetchCompleted = true
        libraryFetchCompleted = true
        resumeFetchCompleted = true
        nextUpFetchCompleted = true
        _fetchInFlight = false
        _bootFetchPending = false
        _rebuildLatestByFolderFromTemp()
        _resetHydration()
        updateBackdrop()
        prepareHomeReveal(reason || "home-timeout")
        return true
    }
    function forceHomeRevealReady() {
        if (!_alive) return false
        try { focusRestoreTimer.stop() } catch(e0) {}
        try { resumeRestoreHorizontalTimer.stop() } catch(e1) {}
        try { folderRestoreHorizontalTimer.stop() } catch(eFolderForce) {}
        _restoringFocus = false
        _focusRestorePending = false
        _focusRestoreRetryLeft = 0
        _focusRestoreSettle = false
        _resumeRestoreHorizontalPending = false
        _resumeRestoreHorizontalRetryLeft = 0
        _resumeRestoreSavedViewportX = null
        _resumeRestoreSavedViewportWidth = null
        _folderRestoreHorizontalPending = false
        _folderRestoreHorizontalRetryLeft = 0
        _navigationSnapshotArmed = false
        _exclusiveNavigationMemoryArmed = false
        _markFocusSnapshotRestored()
        _homeRevealPrepareActive = false
        _homeRevealReady = true
        try { homeRevealReadyTimer.stop() } catch(e2) {}
        scheduleHomeFocusRepair()
        return true
    }
    function _maybeLoadLatestByVerticalProximity() {
        if (!_vFlick || !_latestInitialComplete || _latestAllComplete) return
        var remaining = Math.max(0, _vFlick.contentHeight - (_vFlick.contentY + _vFlick.height))
        if (remaining <= _vFlick.height * 1.15) requestMoreLatestForProximity()
    }
    function _fetchStillValid(seq){ return postergrid._safeCanTouch(seq); }
    function _clearDataAfterFetchFailure() {
        try {
            if (!postergrid._safeCanTouch()) return
            if (!postergrid.fetchedOnce || postergrid._dataEmpty()) {
                postergrid._setListIfChanged("libraryItems", [])
                postergrid._setListIfChanged("resumeItems", [])
                postergrid._setListIfChanged("nextUpItems", [])
                postergrid._setLatestByFolderIfChanged([])
                postergrid.latestIndicesByGroup = []
            }
            postergrid.currentFolderIndex = 0
            postergrid.currentResumeIndex = 0
            postergrid.currentNextUpIndex = 0
            postergrid._resetHydration()
            postergrid.updateBackdrop()
        } catch(e) {}
    }

    function fetchData() {
        if (!hasCreds()) return
        var root = postergrid
        if (root._restoreHomeCacheIfFresh()) return
        var key = root._fetchKey()
        if (root._fetchInFlight && root._activeFetchKey === key) return
        root._fetchInFlight = true
        root._activeFetchKey = key
        root._lastFetchStartMs = Date.now()
        root.libraryFetchCompleted = false
        root.resumeFetchCompleted = false
        root.nextUpFetchCompleted = false
        var seq = ++root._fetchSeq
        function applyLibraryItems(items) {
            if (!root._fetchStillValid(seq)) return
            root._fetchInFlight = false
            root.fetchedOnce = true
            root.libraryFetchCompleted = true
            var raw = (items && items.length !== undefined) ? items : []
            var safe = raw.filter(function(i){ return i && i.Name !== "Playlists" })
            root._setListIfChanged("libraryItems", safe)
            root.currentFolderIndex = MediaCatalog.clampIndex(root.currentFolderIndex, Math.min(root.libraryItems.length, root.sectionMaxItems))
            Jellyfin.fetchHomeResumeItems( root.serverUrl, root.accessToken, root.userId, root.sectionMaxItems, function(it) {
                    if (!root._fetchStillValid(seq)) return
                    root._setListIfChanged("resumeItems", it || [])
                    root.resumeFetchCompleted = true
                    root.currentResumeIndex = MediaCatalog.clampIndex(root.currentResumeIndex, Math.min(root.resumeItems.length, root.sectionMaxItems))
                    root.updateBackdrop()
                    root.scheduleFocusRestore()
                }, function() {
                    if (!root._fetchStillValid(seq)) return
                    root._setListIfChanged("resumeItems", [])
                    root.resumeFetchCompleted = true
                    root.currentResumeIndex = 0
                    root.updateBackdrop()
                    root.scheduleFocusRestore()
                }
            )
            root.fetchNextUpItems(seq)
            root.fetchLatestPerFolder(seq)
            root._resetHydration()
            root.updateBackdrop()
            root.scheduleFocusRestore()
        }
        function failLibraryItems() {
            if (!root._fetchStillValid(seq)) return
            root._fetchInFlight = false
            root._clearDataAfterFetchFailure()
        }
        Jellyfin.fetchViews(root.serverUrl, root.accessToken, root.userId, applyLibraryItems, failLibraryItems)
    }
    function fetchNextUpItems(fetchSeq) {
        var root = postergrid; var seq = (fetchSeq !== undefined && fetchSeq !== null) ? fetchSeq : root._fetchSeq; var nextSeq = ++root._nextUpSeq
        try {
            if (!root._safeCanTouch(seq)) return
            if (!root.nextUpItems || root.nextUpItems.length === 0) root._setListIfChanged("nextUpItems", [])
        } catch(e0) { return }
        Jellyfin.fetchHomeNextUpItems( root.serverUrl, root.accessToken, root.userId, root.sectionMaxItems, function(items) {
                try {
                    if (!root._safeCanTouch(seq) || nextSeq !== root._nextUpSeq) return
                    root._setListIfChanged("nextUpItems", items || [])
                    root.nextUpFetchCompleted = true
                    root.currentNextUpIndex = MediaCatalog.clampIndex(root.currentNextUpIndex, Math.min(root.nextUpItems.length, root.sectionMaxItems))
                    root.updateBackdrop()
                    root.scheduleFocusRestore()
                } catch(e1) {}
            }, function(e) {
                try {
                    if (!root._safeCanTouch(seq) || nextSeq !== root._nextUpSeq) {
                        return
                    }
                    root._setListIfChanged("nextUpItems", [])
                    root.nextUpFetchCompleted = true
                    root.currentNextUpIndex = 0
                    root.updateBackdrop()
                    root.scheduleFocusRestore()
                } catch(e2) {}
            }
        )
    }
    function fetchLatestPerFolder(fetchSeq) {
        var root = postergrid; var seq = (fetchSeq !== undefined && fetchSeq !== null) ? fetchSeq : root._fetchSeq
        try {
            if (!root._safeCanTouch(seq)) return
            if (!root.fetchedOnce || !root.latestByFolder || root.latestByFolder.length === 0) root._setLatestByFolderIfChanged([])
            root._latestTemp = []
            root.latestFetchCompleted = false
            if (!root._focusRestorePending && !root._restoringFocus) root.latestIndicesByGroup = []
            var libs = MediaCatalog.safeArray(root.libraryItems).filter(function(i){
                return i
                        && (i.CollectionType || i.IsFolder)
                        && !MediaCatalog.isKnownUnsupportedLibraryFolder(i)
            })
            if (libs.length === 0) {
                root.latestFetchCompleted = true
                if (!root.latestByFolder || root.latestByFolder.length === 0) root._setLatestByFolderIfChanged([])
                return
            }
            root._startLatestInitialQueue(libs, seq)
        } catch(e) {}
    }

    Component.onCompleted: {
        _alive = true
        ready = true
        ensureBootFetch()
        scheduleBackdropFocusRefresh()
    }
    Component.onDestruction: {
        _alive = false
        _personalResumeRouteSeq++
        try { if (resumeRestoreHorizontalTimer.running) resumeRestoreHorizontalTimer.stop() } catch(eResumeRestore) {}
        try { if (folderRestoreHorizontalTimer.running) folderRestoreHorizontalTimer.stop() } catch(eFolderRestore) {}
        _folderRestoreHorizontalPending = false
        _folderRestoreHorizontalRetryLeft = 0
        _resumeRestoreHorizontalPending = false
        _resumeRestoreHorizontalRetryLeft = 0
        _resumeRestoreSavedViewportX = null
        _resumeRestoreSavedViewportWidth = null
        _fetchSeq++
        _nextUpSeq++
        _latestQueueSeq++
        _cancelLatestReloads("destroyed")
        _cancelLatestInitialRequests("destroyed", false)
        try { if (latestInitialWatchdog.running) latestInitialWatchdog.stop() } catch(eLatestWd) {}
        try { if (_visRefetch.running) _visRefetch.stop() } catch(e1) {}
        try { if (hydrationTimer.running) hydrationTimer.stop() } catch(e2) {}
        try { if (homeImageSettleTimer.running) homeImageSettleTimer.stop() } catch(e4) {}
        try { if (homeImageReturnFreezeTimer.running) homeImageReturnFreezeTimer.stop() } catch(e5) {}
        try { if (homeFocusRepairTimer.running) homeFocusRepairTimer.stop() } catch(e6) {}
        try { if (homeRevealReadyTimer.running) homeRevealReadyTimer.stop() } catch(e7) {}
        try { if (latestEvictTimer.running) latestEvictTimer.stop() } catch(e8) {}
        try { if (latestDataEvictTimer.running) latestDataEvictTimer.stop() } catch(e9) {}
        try { if (latestReloadRetryTimer.running) latestReloadRetryTimer.stop() } catch(e10) {}
    }
    function _resetHomeCacheRestoreDedup(){ _lastHomeCacheRestoreKey=""; _lastHomeCacheRestoreCacheTs=0; _lastHomeCacheRestoreAtMs=0 }
    onAccessTokenChanged: { _resetHomeCacheRestoreDedup(); if (ready) ensureBootFetch() }
    onUserIdChanged: { _resetHomeCacheRestoreDedup(); if (ready) ensureBootFetch() }
    onServerUrlChanged: { _resetHomeCacheRestoreDedup(); if (ready) ensureBootFetch() }
    onBgBlurChanged:      updateBackdrop()
    onLibraryItemsChanged:   {  updateBackdrop() }
    onResumeItemsChanged:    {  updateBackdrop() }
    onNextUpItemsChanged:    {  updateBackdrop() }
    onLatestByFolderChanged: {  updateBackdrop(); scheduleFocusRestore(); scheduleLatestEvict() }
    onPageActiveChanged: {
        if (pageActive) Qt.callLater(function(){
            if (postergrid._alive && postergrid.focusRepairEnabled) postergrid.scheduleHomeFocusRepair()
        })
    }
    onOverlayOpenChanged: if (!overlayOpen && pageActive) Qt.callLater(function(){
        if (postergrid._alive && postergrid.focusRepairEnabled) postergrid.scheduleHomeFocusRepair()
    })
    onFocusRepairEnabledChanged: if (!focusRepairEnabled) cancelHomeFocusRepair()
    Rectangle { anchors.fill: parent; color: "#000" }
    // Chargement explicite du fond Home.
    // postergrid.qml est servi en HTTP et qml/pages/qmldir n'est pas disponible
    // sur Freebox. Un Loader avec URL relative évite donc la résolution implicite
    // du type local dans ce dossier.
    Loader {
        id: backdropLayerLoader
        anchors.fill: parent
        asynchronous: false
        source: Qt.resolvedUrl("HomeBackdrop.qml")

        onLoaded: {
            if (item)
                item.host = postergrid
        }
    }

    function updateBackdrop() {
        var backdrop = backdropLayerLoader.item
        if (backdrop && backdrop.scheduleUpdate)
            backdrop.scheduleUpdate()
    }
    property bool _homeMaintenanceQueued: false; property bool _homeMaintenanceRestoreFocus: false; property bool _homeMaintenanceRepairFocus: false
    Timer {
        id: homeMaintenanceTimer; interval: 0; repeat: false
        onTriggered: {
            _homeMaintenanceQueued = false
            if (!postergrid._alive) return
            postergrid.updateBackdrop()
            if (_homeMaintenanceRestoreFocus) postergrid.scheduleFocusRestore()
            if (_homeMaintenanceRepairFocus) postergrid.scheduleHomeFocusRepair()
            _homeMaintenanceRestoreFocus = false
            _homeMaintenanceRepairFocus = false
        }
    }
    function _scheduleHomeMaintenance(restoreFocus, repairFocus){ if (!_alive) return; _homeMaintenanceRestoreFocus = _homeMaintenanceRestoreFocus || restoreFocus; _homeMaintenanceRepairFocus = _homeMaintenanceRepairFocus || repairFocus; if (_homeMaintenanceQueued) return; _homeMaintenanceQueued = true; homeMaintenanceTimer.restart(); }
    function scheduleBackdropFocusRefresh() { _scheduleHomeMaintenance(true, false) }
    function scheduleBackdropHomeRepair() { _scheduleHomeMaintenance(false, true) }
    readonly property url posterGridCardSource: Qt.resolvedUrl("PosterGridCard.qml")
    signal playItem(var item)
    signal requestBackToMenu()
    signal requestMoviePage(var folderId)
    signal requestPersonalMediaPage(var folderId, string preselectItemId)
    signal requestSeriesPage(var folderId, string libraryMode)
    signal requestCollectionPage(var folderId)
    signal requestDetailMovie(string movieId)
    signal requestSeasonPage(string seriesId, string seasonId, string preselectEpisodeId)
    function _sectionHasContent(section) {
        if (section === 0) return !!(folderList && folderList.count > 0)
        if (section === 1) return !!(resumeList && resumeList.count > 0)
        if (section === 2) return !!(nextUpList && nextUpList.count > 0)
        if (section === 3) return !!(latestByFolder && latestByFolder.length > 0)
        return false
    }
    function _nearestSection(from, direction) {
        var s = from + direction
        while (s >= 0 && s <= 3) {
            if (_sectionHasContent(s)) return s
            s += direction
        }
        return -1
    }

    function _focusSection(section, latestGroup, reason) {
        if (!focusRepairEnabled) return false
        if (!_sectionHasContent(section)) return false
        focusSection = section
        if (section === 0) {
            currentFolderIndex = MediaCatalog.clampIndex(currentFolderIndex, folderList.count)
            folderList.currentIndex = currentFolderIndex
            if (!postergrid._folderRestoreHorizontalPending
                    && folderList.ensureIndexVisible)
                folderList.ensureIndexVisible(currentFolderIndex, false)
            _vFlick.contentY = 0
            folderList.forceActiveFocus()
        } else if (section === 1) {
            currentResumeIndex = MediaCatalog.clampIndex(currentResumeIndex, resumeList.count)
            resumeList.ensureCurrentItemVisible(reason || "section-focus")
            resumeList.forceActiveFocus()
            _vFlick.ensureSectionVisible(resumeSection, 12)
        } else if (section === 2) {
            currentNextUpIndex = MediaCatalog.clampIndex(currentNextUpIndex, nextUpList.count)
            nextUpList.currentIndex = currentNextUpIndex
            if (nextUpList.ensureIndexVisible) nextUpList.ensureIndexVisible(currentNextUpIndex, false)
            nextUpList.forceActiveFocus()
            _vFlick.ensureSectionVisible(nextUpSection, 12)
        } else {
            focusLatestGroup(latestGroup === undefined ? currentLatestGroup : latestGroup)
        }
        if (section !== 3) updateBackdrop()
        return true
    }
    function _focusAdjacentSection(from, direction, latestGroup){ var target = _nearestSection(from, direction); return target >= 0 && _focusSection(target, target === 3 ? (latestGroup === undefined ? 0 : latestGroup) : currentLatestGroup); }
    function forceFocus(){ return _focusSection(focusSection, currentLatestGroup, "force-focus"); }
    function _latestActiveList(){ if(!latestRepeater || !latestByFolder || latestByFolder.length<=0) return null; var g=Math.max(0, Math.min(currentLatestGroup||0, latestByFolder.length-1)); var sec=latestRepeater.itemAt(g); return (sec && sec.listObj) ? sec.listObj : null }
    function _hasAnyHomeListFocus(){ var l=_latestActiveList(); return !!((folderList && folderList.activeFocus) || (resumeList && resumeList.activeFocus) || (nextUpList && nextUpList.activeFocus) || (l && l.activeFocus)) }
    function cancelHomeFocusRepair() {
        _homeFocusRepairLeft = 0
        try { homeFocusRepairTimer.stop() } catch(e0) {}
        try { focusRestoreTimer.stop() } catch(e1) {}
    }

    function scheduleHomeFocusRepair(){ if(!_alive || !pageActive || !focusRepairEnabled) return; _homeFocusRepairLeft=6; homeFocusRepairTimer.restart(); }
    function _repairHomeFocus(){
        if(!_alive || !pageActive || !focusRepairEnabled) return
        if(_restoringFocus || _focusRestorePending || _focusRestoreSettle || hasPendingFocusRestore()){
            scheduleFocusRestore()
            return
        }
        if(_hasAnyHomeListFocus()) return
        var section = _sectionHasContent(focusSection) ? focusSection : _nearestSection(-1, 1)
        if (section >= 0) _focusSection(section, currentLatestGroup, "focus-repair")
    }
    Timer { id: homeFocusRepairTimer; interval: 80; repeat: false; onTriggered: { postergrid._repairHomeFocus(); if(!postergrid._hasAnyHomeListFocus() && postergrid._homeFocusRepairLeft>0){ postergrid._homeFocusRepairLeft--; restart() } } }
    property int _focusSectionScrollQueued: -1
    function _scheduleFocusSectionScroll(){ _focusSectionScrollQueued = focusSection; focusSectionScrollTimer.restart() }
    Timer { id: focusSectionScrollTimer; interval: 0; repeat: false; onTriggered: {
        var s = _focusSectionScrollQueued; _focusSectionScrollQueued = -1
        if (postergrid._sectionHasContent(s)) postergrid._focusSection(s, postergrid.currentLatestGroup, "section-scroll")
    } }
    property int _firstFocusRetryLeft: 18
    function forceFirstFocus() {
        if (hasPendingFocusRestore() && restoreFocusSnapshot()) return true
        var section = _nearestSection(-1, 1)
        if (section >= 0) {
            _firstFocusRetryLeft = 18
            if (section === 0) currentFolderIndex = 0
            else if (section === 1) currentResumeIndex = 0
            else if (section === 2) currentNextUpIndex = 0
            else currentLatestGroup = 0
            Qt.callLater(function(){ postergrid._focusSection(section, 0, "first-focus") })
        } else if (_firstFocusRetryLeft > 0) {
            _firstFocusRetryLeft--
            Qt.callLater(function(){ postergrid.forceFirstFocus() })
        }
        scheduleBackdropFocusRefresh()
    }
    function focusLatestGroup(g) {
        if (_focusRestorePending && !_restoringFocus) {
            scheduleFocusRestore()
            return
        }
        g = Math.max(0, Math.min(g, latestByFolder.length-1))
        currentLatestGroup = g
        if (_ensureLatestGroupData(g, "focus")) {
            var waitingSec = latestRepeater ? latestRepeater.itemAt(g) : null
            if (waitingSec) {
                _vFlick.ensureSectionVisible(waitingSec, 16)
                if (waitingSec.listObj) waitingSec.listObj.forceActiveFocus()
                else postergrid.forceActiveFocus()
            } else postergrid.forceActiveFocus()
            return
        }
        if (g >= Math.max(0, latestByFolder.length - 2)) requestMoreLatestForProximity()
        Qt.callLater(function(){
            var sec = latestRepeater.itemAt(g)
            if (sec) sec.evicted = false
            if (sec && sec.listObj) {
                var want = MediaCatalog.clampIndex(latestIndexFor(g), sec.listObj.count)
                postergrid._forceLatestIndexForGroup(g, want)
                sec.listObj.ensureSelectedItemVisible(false)
                sec.listObj.forceActiveFocus()
                _vFlick.ensureSectionVisible(sec, 16)
            }
            updateBackdrop()
            if (hydrationAllowed && !hydrationDone && !hydrationTimer.running) hydrationTimer.restart()
        })
    }
    property real _lastScrollY: 0; signal scrolled(real y, int direction); readonly property real latestEvictScreens: 2.2; readonly property int latestDataEvictDelayMs: 4200
    Timer { id: latestEvictTimer; interval: 650; repeat: false; running: false; onTriggered: postergrid._evictLatestSections() }
    Timer { id: latestDataEvictTimer; interval: postergrid.latestDataEvictDelayMs; repeat: false; running: false; onTriggered: postergrid._evictFarLatestData() }
    Timer {
        id: latestReloadRetryTimer; interval: 5500; repeat: false; running: false
        onTriggered: {
            if (!postergrid._alive || !postergrid.pageActive || !latestRepeater) return
            for (var i = 0; i < latestRepeater.count; ++i) {
                var sec = latestRepeater.itemAt(i)
                if (sec && (sec.nearViewport || sec.forceLoad)) postergrid._ensureLatestGroupData(i, "retry")
            }
        }
    }
    function scheduleLatestEvict(){ if (!postergrid.pageActive || !latestByFolder || latestByFolder.length <= 0) return; latestEvictTimer.restart(); latestDataEvictTimer.restart() }
    function _evictLatestSections() {
        if (!latestRepeater) return
        if (!sections || !_vFlick) return
        if (!postergrid.pageActive) return
        var viewTop = _vFlick.contentY; var viewBot = _vFlick.contentY + _vFlick.height; var farPad = postergrid.height * latestEvictScreens
        for (var i=0; i<latestRepeater.count; i++) {
            var sec = latestRepeater.itemAt(i)
            if (!sec) continue
            if (!sec.visible || sec.height <= 0) { sec.evicted = false; continue }
            var top = sec.y + sections.y; var bot = top + sec.height; var far = (bot < (viewTop - farPad)) || (top > (viewBot + farPad)); var pinned = (postergrid.focusSection === 3 && postergrid.currentLatestGroup === sec.groupIndex)
            sec.evicted = (!!far && !pinned)
        }
    }
    function _evictFarLatestData() {
        if (!latestRepeater || !sections || !_vFlick || !pageActive || !latestByFolder) return
        var viewTop = _vFlick.contentY; var viewBot = viewTop + _vFlick.height; var farPad = height * latestEvictScreens; var next = latestByFolder.slice(0); var changed = false
        for (var i = 0; i < next.length; ++i) {
            var sec = latestRepeater.itemAt(i); var entry = next[i]
            if (!sec || !entry || entry._evicted || !entry.items || entry.items.length <= 0) continue
            var top = sec.y + sections.y; var bot = top + sec.height; var far = (bot < (viewTop - farPad)) || (top > (viewBot + farPad)); var pinned = (focusSection === 3 && currentLatestGroup === i) || _isLatestRestoreAnchoredGroup(i)
            if (!far || pinned) continue
            var trimmed = MediaCatalog.shallowCloneObject(entry)
            trimmed.items = []
            trimmed._evicted = true
            trimmed._hadItems = true
            trimmed._evictedAt = Date.now()
            next[i] = trimmed
            _updateLatestTempEntry(trimmed)
            sec.evicted = true
            try {
                if (Jellyfin.evictLatestParentApiCache) Jellyfin.evictLatestParentApiCache(String(entry.id || ""))
            } catch(e0) {}
            changed = true
        }
        if (changed) {
            _setLatestByFolderIfChanged(next)
            _saveHomeCacheNow()
        }
    }
    Flickable {

        id: _vFlick; anchors.fill: parent; clip: true
        contentWidth: width
        contentHeight: sections.implicitHeight + bottomSpacer
        boundsBehavior: Flickable.StopAtBounds; interactive: !postergrid.overlayOpen
        Behavior on contentY {
            enabled: postergrid.allowAnims && !(_vFlick.moving || _vFlick.dragging || _vFlick.flicking)
            NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
        }
        onContentYChanged: {
            var dir = (contentY > postergrid._lastScrollY) ? 1 : ((contentY < postergrid._lastScrollY) ? -1 : 0)
            postergrid._lastScrollY = contentY
            postergrid.scrolled(contentY, dir)
            if (postergrid.isScrollingEff) hydrationTimer.stop()
            else if (postergrid.hydrationAllowed && !postergrid.hydrationDone && !hydrationTimer.running) hydrationTimer.restart()
            postergrid.scheduleLatestEvict()
            postergrid._maybeLoadLatestByVerticalProximity()
        }
        function ensureSectionVisible(sectionItem, margin) {
            if (!sectionItem || !sectionItem.visible) return
            var m = (margin !== undefined) ? margin : 20; var p = sectionItem.mapToItem(_vFlick.contentItem, 0, 0); var top = p.y; var bottom = p.y + sectionItem.height; var viewTop = _vFlick.contentY
            var viewBot = _vFlick.contentY + _vFlick.height
            if (top < viewTop + m) _vFlick.contentY = Math.max(0, top - m)
            else if (bottom > viewBot - m) {
                var target = bottom - _vFlick.height + m
                _vFlick.contentY = Math.min(_vFlick.contentHeight - _vFlick.height, Math.max(0, target))
            }
        }
        Column {
            id: sections; width: _vFlick.width; spacing: 44; anchors.top: parent.top
            anchors.left: parent.left; anchors.topMargin: postergrid.topMargin
            Item {
                id: libSection; width: parent.width; height: libraryCardH + 80
                Text { textFormat: Text.PlainText;
                    text: "Mes médias"; color: "#fff"; font.pixelSize: postergrid.sectionTitleFontPx; font.bold: true
                    font.weight: Font.Bold; anchors.left: parent.left; anchors.leftMargin: 40
                    anchors.top: parent.top
                }
                ListView {
                    id: folderList; anchors.top: parent.top; anchors.topMargin: 50; anchors.left: parent.left
                    anchors.right: parent.right; anchors.leftMargin: viewLeftMargin; anchors.rightMargin: viewRightMargin; height: libraryCardH
                    model: postergrid.cappedLibraryItems; orientation: ListView.Horizontal; spacing: spacingW; snapMode: ListView.SnapOneItem
                    // Effet historique de l'ancien rail « À suivre » : le ListView reste propriétaire du glide via son highlight natif QtQuick.
                    highlightMoveDuration: 120
                    highlightRangeMode: ListView.ApplyRange
                    property int edgePad: postergrid.libraryEdgePad
                    header: Item { width: folderList.edgePad; height: 1 }
                    footer: Item { width: folderList.edgePad; height: 1 }
                    preferredHighlightBegin: edgePad
                    preferredHighlightEnd: width - edgePad - postergrid.libraryCardW
                    highlightFollowsCurrentItem: true
                    highlight: Rectangle { color: "transparent"; width: postergrid.libraryCardW; height: postergrid.libraryCardH }
                    reuseItems: true; cacheBuffer: Math.round(libraryCardW * 1.4); focus: focusSection === 0; boundsBehavior: Flickable.StopAtBounds
                    interactive: true; clip: true
                    // Compatibilité avec les chemins cache/focus existants : lors d'une restauration on place immédiatement le viewport. Les déplacements D-Pad, eux, restent 100 % natifs ListView.
                    function ensureIndexVisible(idx, animateMove) {
                        idx = MediaCatalog.clampIndex(idx, count)
                        if (count <= 0) return
                        if (animateMove === true) return
                        // Pendant la restauration horizontale, Contain est interdit : il ne connaît pas la position historique du viewport et peut remettre contentX au début du rail.
                        if (postergrid._folderRestoreHorizontalPending) return
                        try { positionViewAtIndex(idx, ListView.Contain) } catch(e0) {}
                    }
                    function ensureSelectedItemVisible(animateMove) { ensureIndexVisible(currentIndex, animateMove === true) }
                    function restoreHorizontalFromSnapshot(savedX, reason) {
                        if (count <= 0) return false
                        var x = Number(savedX)
                        if (!isFinite(x) || isNaN(x)) return false
                        folderList.contentX = postergrid._railNativeClampX(
                                    folderList,
                                    x)
                        return true
                    }
                    function commitRestoreCalibrationForUser() {
                        if (!postergrid._folderRestoreHorizontalPending) return
                        folderRestoreHorizontalTimer.stop()
                        restoreHorizontalFromSnapshot(
                                    postergrid._folderRestoreSavedContentX,
                                    "user-input")
                        postergrid._folderRestoreHorizontalPending = false
                        postergrid._folderRestoreHorizontalRetryLeft = 0
                    }
                    Component.onCompleted: { postergrid._syncFolderListFromSaved(); ensureSelectedItemVisible(false) }
                    onModelChanged: { postergrid._syncFolderListFromSaved(); ensureSelectedItemVisible(false) }
                    onCountChanged: { postergrid._syncFolderListFromSaved(); ensureSelectedItemVisible(false) }
                    onWidthChanged: ensureSelectedItemVisible(false)
                    onContentWidthChanged: ensureSelectedItemVisible(false)
                    delegate: Loader {
                        id: folderCardLoader; width: libraryCardW; height: libraryCardH; z: cardSelected ? 100 : 0
                        property var cardData: modelData; property var cardController: postergrid; property bool cardSelected: folderList.activeFocus && focusSection === 0 && folderList.currentIndex === index; property bool cardShowProgress: false
                        property bool cardPreferBackdrop: true; property bool cardMusicFallback: false; property bool cardAllowLoad: postergrid._homeImageLoadGate; property bool cardEnableMouseInput: true
                        property bool cardSuppressFocusTransform: false; property string cardImagePolicy: "standard"; property string cardFallbackKind: "folder"; property int cardTileW: libraryTileW
                        property int cardTileH: libraryTileH; property int cardTitleH: titleH; property int cardSidePad: focusPadSide; property int cardTopPad: libraryTopPad
                        source: postergrid.posterGridCardSource
                        onLoaded: if (item) item.homeLoader = folderCardLoader
                        Connections {
                            target: folderCardLoader.item
                            ignoreUnknownSignals: true
                            function onActivated(){ focusSection = 0; postergrid._setFolderIndexFromUser(index, "folderMouse"); folderList.forceActiveFocus(); _vFlick.contentY = 0; }
                            function onDoubleActivated() {
                                focusSection = 0
                                postergrid._setFolderIndexFromUser(index, "folderDoubleMouse")
                                folderList.forceActiveFocus()
                                var items = postergrid.cappedLibraryItems; var it = items && index >= 0 && index < items.length ? items[index] : null
                                if (it) openLibraryEntry(it)
                            }
                        }
                    }
                    Keys.onPressed: {
                        if (event.key === Qt.Key_Right) { if (currentIndex < count - 1) postergrid._setFolderIndexFromUser(currentIndex + 1, "folderKeyRight"); event.accepted = true }
                        else if (event.key === Qt.Key_Left) { postergrid._setFolderIndexFromUser(Math.max(0, currentIndex - 1), "folderKeyLeft"); event.accepted = true }
                        else if (event.key === Qt.Key_Down) {
                            postergrid._focusAdjacentSection(0, 1, 0)
                            event.accepted = true
                        } else if (event.key === Qt.Key_Up) {
                            if (_vFlick.contentY <= 0) requestBackToMenu()
                            else _vFlick.contentY = 0
                            event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                            var libModel = postergrid.cappedLibraryItems
                            if (!libModel || libModel.length === 0) { event.accepted = true; return }
                            var it = libModel[currentIndex]; if (!it) { event.accepted = true; return }
                            openLibraryEntry(it)
                            event.accepted = true
                        } else if (event.key === Qt.Key_Home) {
                            _vFlick.contentY = 0
                            event.accepted = true
                        }
                    }
                    onCurrentIndexChanged: {
                        if (postergrid._syncFolderIndex || postergrid._folderModelSyncGuard) return
                        if (!postergrid._folderUserNavActive && postergrid.focusSection === 0 && currentIndex === 0 && postergrid.currentFolderIndex > 0) {
                            postergrid._syncFolderListFromSaved()
                            return
                        }
                        postergrid.currentFolderIndex = currentIndex
                        postergrid.updateBackdrop()
                    }
                }
            }
            Item {
                id: resumeSection; width: parent.width
                readonly property int rowCardHeight: Math.max(cardHLandscape, cardHPortrait)
                height: resumeItems.length > 0 ? (rowCardHeight + 65) : 0; visible: resumeItems.length > 0
                Text { textFormat: Text.PlainText;
                    text: "Continuer de regarder"; color: "#fff"; font.pixelSize: postergrid.sectionTitleFontPx; font.bold: true
                    font.weight: Font.Bold; anchors.left: parent.left; anchors.leftMargin: 40
                    anchors.top: parent.top
                }
                ListView {
                    id: resumeList; anchors.top: parent.top; anchors.topMargin: 45; anchors.left: parent.left
                    anchors.right: parent.right; anchors.leftMargin: viewLeftMargin; anchors.rightMargin: viewRightMargin; height: resumeSection.rowCardHeight
                    model: postergrid.cappedResumeItems; orientation: ListView.Horizontal; spacing: spacingW; snapMode: ListView.NoSnap
                    highlightMoveDuration: 0
                    highlightRangeMode: ListView.NoHighlightRange
                    property int edgePad: postergrid.resumeRowEdgePad
                    header: Item { width: resumeList.edgePad; height: 1 }
                    footer: Item { width: resumeList.edgePad; height: 1 }
                    preferredHighlightBegin: 0; preferredHighlightEnd: 0
                    highlightFollowsCurrentItem: false
                    highlight: Item { width: 1; height: 1 }
                    reuseItems: true; cacheBuffer: Math.round(postergrid.resumeLandscapeCardW * 1.6); focus: focusSection === 1; boundsBehavior: Flickable.StopAtBounds
                    interactive: false
                    keyNavigationEnabled: false
                    currentIndex: -1; clip: true
                    readonly property int selectedIndex: count > 0 ? MediaCatalog.clampIndex(postergrid.currentResumeIndex, count) : -1
                    property int _ensureVisibleSeq: 0
                    property bool _directionalKeyNavigationActive: false
                    property int _visibilityRepairLeft: 0
                    function _positionIndexIntoView(idx) {
                        if (idx < 0 || idx >= count) return false
                        try {
                            if (resumeList.positionViewAtIndex) {
                                resumeList.positionViewAtIndex(idx, ListView.Contain)
                                return true
                            }
                        } catch(e0) {}
                        return false
                    }
                    function _applySelectedVisibility(animateMove) {
                        var idx = selectedIndex
                        if (count <= 0 || idx < 0 || idx >= count) return false
                        var targetX = postergrid._resumeRealTargetX( resumeList, idx)
                        if (isFinite(targetX) && !isNaN(targetX)) {
                            if (animateMove === true) {
                                postergrid._animateRailX( resumeList, resumeContentXAnim, targetX)
                            } else {
                                resumeContentXAnim.stop()
                                resumeList.contentX = postergrid._resumeNativeClampX( resumeList, targetX)
                            }
                            return true
                        }
                        _positionIndexIntoView(idx)
                        return false
                    }
                    function scheduleVisibilityRepair(retries) {
                        if (count <= 0 || selectedIndex < 0) return
                        _visibilityRepairLeft = Math.max(_visibilityRepairLeft, Math.max(1, retries || 1))
                        resumeVisibilityRepairTimer.restart()
                    }
                    function ensureCurrentItemVisible(reason) {
                        var seq = ++_ensureVisibleSeq
                        var immediate = reason === "index" || reason === "selected-index" || reason === "mouse" || reason === "restore" || reason === "first-focus" || reason === "nav-fallback"
                        function apply() {
                            if (!postergrid._alive || seq !== resumeList._ensureVisibleSeq) return
                            var ready = resumeList._applySelectedVisibility( !immediate)
                            if (!ready || immediate) resumeList.scheduleVisibilityRepair(3)
                        }
                        if (immediate) apply()
                        else
                            Qt.callLater(apply)
                    }
                    function navigateHorizontal(direction) {
                        if (count <= 0 || direction === 0) return
                        commitRestoreCalibrationForUser()
                        resumeContentXAnim.stop()
                        var fromIdx = selectedIndex
                        if (fromIdx < 0) fromIdx = MediaCatalog.clampIndex( postergrid.currentResumeIndex, count)
                        var toIdx = MediaCatalog.clampIndex( fromIdx + (direction < 0 ? -1 : 1), count)
                        if (toIdx === fromIdx) return
                        var targetX = postergrid._resumeDirectionalNaturalTargetX( resumeList, fromIdx, toIdx, direction)
                        ++_ensureVisibleSeq
                        _directionalKeyNavigationActive = true
                        postergrid.currentResumeIndex = toIdx
                        _directionalKeyNavigationActive = false
                        if (isFinite(targetX) && !isNaN(targetX)) {
                            postergrid._animateRailX( resumeList, resumeContentXAnim, targetX)
                        } else {
                            _positionIndexIntoView(toIdx)
                        }
                        // Appuis D-Pad rapides : le targetX directionnel est volontairement calculé à partir de la position affichée au moment de l'appui. Une fois le dernier glide terminé, on recalcule avec la géométrie réelle du delegate afin que le poster focusé, notamment le dernier, soit entier.
                        scheduleVisibilityRepair(toIdx === count - 1 ? 3 : 2)
                        postergrid.updateBackdrop()
                    }
                    function restoreHorizontalFromSnapshot(savedX, savedViewportX, reason) {
                        if (count <= 0 || selectedIndex < 0) return false
                        resumeContentXAnim.stop()
                        var hasViewportAnchor = savedViewportX !== undefined && savedViewportX !== null
                        var viewportX = hasViewportAnchor ? Number(savedViewportX) : NaN
                        hasViewportAnchor = hasViewportAnchor && isFinite(viewportX) && !isNaN(viewportX)
                        if (reason === "restore-immediate" && !hasViewportAnchor) {
                            var x = Number(savedX)
                            if (isFinite(x) && !isNaN(x)) resumeList.contentX = postergrid._resumeNativeClampX( resumeList, x)
                        }
                        var real = postergrid._rowRealDelegateGeometry( resumeList, selectedIndex)
                        if (real && hasViewportAnchor) {
                            var delta = real.viewportX - viewportX
                            if (Math.abs(delta) >= 0.5) {
                                resumeList.contentX = postergrid._resumeNativeClampX( resumeList, Number(resumeList.contentX || 0)
                                            + delta)
                            }
                            scheduleVisibilityRepair(2)
                            return true
                        }
                        if (real) {
                            var realTarget = postergrid._resumeRealTargetX( resumeList, selectedIndex)
                            if (isFinite(realTarget) && !isNaN(realTarget)) {
                                resumeList.contentX = postergrid._resumeNativeClampX( resumeList, realTarget)
                                scheduleVisibilityRepair(2)
                                return true
                            }
                        }
                        _positionIndexIntoView(selectedIndex)
                        scheduleVisibilityRepair(3)
                        return false
                    }
                    function commitRestoreCalibrationForUser() {
                        if (!postergrid._resumeRestoreHorizontalPending) return
                        resumeRestoreHorizontalTimer.stop()
                        restoreHorizontalFromSnapshot( postergrid._resumeRestoreSavedContentX, postergrid._resumeRestoreSavedViewportX, "user-input")
                        postergrid._resumeRestoreHorizontalPending = false
                        postergrid._resumeRestoreHorizontalRetryLeft = 0
                        postergrid._resumeRestoreSavedViewportX = null
                        postergrid._resumeRestoreSavedViewportWidth = null
                    }
                    Timer {
                        id: resumeVisibilityRepairTimer
                        interval: 32
                        repeat: false
                        onTriggered: {
                            if (!postergrid._alive || resumeList.count <= 0 || resumeList.selectedIndex < 0) {
                                resumeList._visibilityRepairLeft = 0
                                return
                            }
                            if (resumeContentXAnim.running) {
                                // Ne jamais consommer le budget de réparation pendant le glide. Sinon des appuis rapides épuisent les retries avant la fin des 180 ms et le dernier poster peut rester à moitié hors écran malgré son focus.
                                restart()
                                return
                            }
                            var idx = resumeList.selectedIndex
                            var real = postergrid._rowRealDelegateGeometry( resumeList, idx)
                            if (!real) {
                                resumeList._positionIndexIntoView(idx)
                            } else {
                                var targetX = postergrid._resumeRealTargetX( resumeList, idx)
                                if (isFinite(targetX) && !isNaN(targetX) && Math.abs( Number(resumeList.contentX || 0)
                                            - targetX) >= 0.75) {
                                    resumeList.contentX = postergrid._resumeNativeClampX( resumeList, targetX)
                                }
                            }
                            resumeList._visibilityRepairLeft = Math.max( 0, resumeList._visibilityRepairLeft - 1)
                            if (resumeList._visibilityRepairLeft > 0) restart()
                        }
                    }
                    NumberAnimation {
                        id: resumeContentXAnim
                        target: resumeList
                        property: "contentX"
                        duration: postergrid.railScrollDurationMs
                        easing.type: Easing.OutCubic
                        onStopped: {
                            if (resumeList._visibilityRepairLeft > 0
                                    && !resumeVisibilityRepairTimer.running)
                                resumeVisibilityRepairTimer.restart()
                        }
                    }
                    Component.onCompleted: ensureCurrentItemVisible("completed")
                    onCountChanged: {
                        postergrid.currentResumeIndex = MediaCatalog.clampIndex( postergrid.currentResumeIndex, count)
                        ensureCurrentItemVisible("count")
                    }
                    onWidthChanged: ensureCurrentItemVisible("width")
                    onContentWidthChanged: {
                        if (postergrid.focusSection === 1 && !postergrid._restoringFocus) scheduleVisibilityRepair(2)
                    }
                    delegate: Loader {
                        id: resumeCardLoader
                        readonly property bool portraitMovie: !postergrid._mediaCardUsesLandscape(cardData, "resume")
                        width: postergrid.mediaCardDelegateWidthFor(cardData, "resume")
                        height: resumeSection.rowCardHeight; z: cardSelected ? 100 : 0
                        property var cardData: modelData; property var cardController: postergrid; property bool cardSelected: resumeList.activeFocus && focusSection === 1 && resumeList.selectedIndex === index; property bool cardShowProgress: true
                        property bool cardPreferBackdrop: !portraitMovie; property bool cardMusicFallback: false; property string cardFallbackKind: portraitMovie ? "movie" : "episode"; property string cardImagePolicy: "standard"
                        property bool cardAllowLoad: postergrid._homeImageLoadGate; property bool cardEnableMouseInput: true; property bool cardSuppressFocusTransform: false; property int cardTileW: postergrid.mediaCardTileWidthFor(cardData, "resume")
                        property int cardTileH: postergrid.mediaCardTileHeightFor(cardData, "resume"); property int cardTitleH: titleH; property int cardSidePad: postergrid.mediaCardSidePadFor(cardData, "resume"); property int cardTopPad: postergrid.mediaCardTopPadFor(cardData, "resume")
                        source: postergrid.posterGridCardSource
                        onLoaded: {
                            if (item) item.homeLoader = resumeCardLoader
                            if (resumeCardLoader.cardSelected) resumeList.scheduleVisibilityRepair(2)
                        }
                        Connections {
                            target: resumeCardLoader.item
                            ignoreUnknownSignals: true
                            function onActivated(){ postergrid.currentResumeIndex = index; postergrid._focusSection(1, 0, "resume-mouse"); }
                            function onDoubleActivated(){ postergrid.currentResumeIndex = index; postergrid._focusSection(1, 0, "resume-mouse"); }
                        }
                    }
                    Keys.onPressed: {
                        if (event.key === Qt.Key_Right) {
                            resumeList.navigateHorizontal(1)
                            event.accepted = true
                        }
                        else if (event.key === Qt.Key_Left) {
                            resumeList.navigateHorizontal(-1)
                            event.accepted = true
                        }
                        else if (event.key === Qt.Key_Up) { postergrid._focusAdjacentSection(1, -1); event.accepted = true }
                        else if (event.key === Qt.Key_Down) {
                            postergrid._focusAdjacentSection(1, 1, 0)
                            event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                            var resModel = postergrid.cappedResumeItems
                            if (!resModel || resModel.length === 0) { event.accepted = true; return }
                            var it = resModel[resumeList.selectedIndex]; if (!it) { event.accepted = true; return }
                            openContentItem(it)
                            event.accepted = true
                        } else if (event.key === Qt.Key_Home) {
                            postergrid._focusSection(0, 0, "home-key")
                            event.accepted = true
                        }
                    }
                    onSelectedIndexChanged: {
                        // Un déplacement D-Pad est déjà entièrement piloté par navigateHorizontal() : aucune seconde correction animée.
                        if (!resumeList._directionalKeyNavigationActive) {
                            resumeList.ensureCurrentItemVisible("index")
                            resumeList.scheduleVisibilityRepair(3)
                        }
                        postergrid.updateBackdrop()
                    }
                }
            }
            Item {
                id: nextUpSection; width: parent.width; height: nextUpItems.length > 0 ? (cardHPortrait + 65) : 0; visible: nextUpItems.length > 0
                Text { textFormat: Text.PlainText;
                    text: "À suivre"; color: "#fff"; font.pixelSize: postergrid.sectionTitleFontPx; font.bold: true
                    font.weight: Font.Bold; anchors.left: parent.left; anchors.leftMargin: 40
                    anchors.top: parent.top
                }
                ListView {
                    id: nextUpList; anchors.top: parent.top; anchors.topMargin: 45; anchors.left: parent.left
                    anchors.right: parent.right; anchors.leftMargin: viewLeftMargin; anchors.rightMargin: viewRightMargin; height: cardHPortrait
                    model: postergrid.cappedNextUpItems; orientation: ListView.Horizontal; spacing: spacingW; snapMode: ListView.SnapOneItem
                    // Comportement historique exact de « À suivre » avant harmonisation manuelle du contentX.
                    highlightMoveDuration: 120
                    highlightRangeMode: ListView.ApplyRange
                    property int edgePad: postergrid.resumeLandscapeEdgePad
                    header: Item { width: nextUpList.edgePad; height: 1 }
                    footer: Item { width: nextUpList.edgePad; height: 1 }
                    preferredHighlightBegin: edgePad
                    preferredHighlightEnd: width - edgePad - postergrid.resumeLandscapeCardW
                    highlightFollowsCurrentItem: true
                    highlight: Rectangle { color: "transparent"; width: postergrid.resumeLandscapeCardW; height: cardHPortrait }
                    reuseItems: true; cacheBuffer: Math.round(postergrid.resumeLandscapeCardW * 1.4); focus: focusSection === 2; boundsBehavior: Flickable.StopAtBounds
                    interactive: true; clip: true
                    function ensureIndexVisible(idx, animateMove) {
                        idx = MediaCatalog.clampIndex(idx, count)
                        if (count <= 0) return
                        if (animateMove === true) return
                        try { positionViewAtIndex(idx, ListView.Contain) } catch(e0) {}
                    }
                    function selectIndex(idx, animateMove) {
                        var want = MediaCatalog.clampIndex(idx, count)
                        if (currentIndex !== want) currentIndex = want
                        if (animateMove !== true) ensureIndexVisible(want, false)
                    }
                    Component.onCompleted: {
                        currentIndex = MediaCatalog.clampIndex(postergrid.currentNextUpIndex, count)
                        ensureIndexVisible(currentIndex, false)
                    }
                    onCountChanged: {
                        var want = MediaCatalog.clampIndex(postergrid.currentNextUpIndex, count)
                        if (currentIndex !== want) currentIndex = want
                        ensureIndexVisible(want, false)
                    }
                    onWidthChanged: ensureIndexVisible(currentIndex, false)
                    onContentWidthChanged: ensureIndexVisible(currentIndex, false)
                    delegate: Loader {
                        id: nextUpCardLoader; width: postergrid.resumeLandscapeCardW; height: cardHPortrait; z: cardSelected ? 100 : 0
                        property var cardData: modelData; property var cardController: postergrid; property bool cardSelected: nextUpList.activeFocus && focusSection === 2 && nextUpList.currentIndex === index; property bool cardShowProgress: false
                        property bool cardPreferBackdrop: false; property bool cardMusicFallback: false; property string cardFallbackKind: "series"; property string cardImagePolicy: "nextup-series"
                        property bool cardAllowLoad: postergrid._homeImageLoadGate; property bool cardEnableMouseInput: true; property bool cardSuppressFocusTransform: false; property int cardTileW: postergrid.resumeLandscapeW
                        property int cardTileH: portH; property int cardTitleH: titleH; property int cardSidePad: focusPadSide; property int cardTopPad: topPadPortrait
                        source: postergrid.posterGridCardSource
                        onLoaded: if (item) item.homeLoader = nextUpCardLoader
                        Connections {
                            target: nextUpCardLoader.item
                            ignoreUnknownSignals: true
                            function onActivated(){ nextUpList.selectIndex(index, true); postergrid._focusSection(2, 0, "nextup-mouse"); }
                            function onDoubleActivated() {
                                var it = nextUpList.model[index]
                                if (it) openEpisodeLike(it)
                            }
                        }
                    }
                    Keys.onPressed: {
                        if (event.key === Qt.Key_Right) { if (currentIndex < count - 1) nextUpList.selectIndex(currentIndex + 1, true); event.accepted = true }
                        else if (event.key === Qt.Key_Left) { nextUpList.selectIndex(Math.max(0, currentIndex - 1), true); event.accepted = true }
                        else if (event.key === Qt.Key_Up) {
                            postergrid._focusAdjacentSection(2, -1)
                            event.accepted = true
                        } else if (event.key === Qt.Key_Down) {
                            postergrid._focusAdjacentSection(2, 1, 0)
                            event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                            var nuModel = postergrid.cappedNextUpItems; var it = (nuModel && nuModel.length > 0) ? nuModel[currentIndex] : null
                            if (it) openEpisodeLike(it)
                            event.accepted = true
                        } else if (event.key === Qt.Key_Home) {
                            postergrid._focusSection(0, 0, "home-key")
                            event.accepted = true
                        }
                    }
                    onCurrentIndexChanged: {
                        if (postergrid._syncNextUpIndex) return
                        postergrid.currentNextUpIndex = currentIndex
                        postergrid.updateBackdrop()
                    }
                }
            }
            Repeater {
                id: latestRepeater; model: latestByFolder.length
                delegate: Item {
                    id: latestSection
                    property int groupIndex: index; property var entry: latestByFolder[index]; property string sectionName: (entry && entry.name) ? entry.name : "Médias"; property var sectionItemsRaw: (entry && entry.items) ? entry.items : []
                    property var sectionItems: postergrid.capItems(sectionItemsRaw); property alias listObj: latestList; property bool isMusicSection: MediaCatalog.isMusicLibraryFolder(entry)
                    readonly property string cardSectionKind: (entry && entry._pgSectionKind) ? String(entry._pgSectionKind) : (MediaCatalog.isSeriesLibraryFolder(entry) ? "latest-series" : "latest")
                    readonly property int cardH: postergrid.cardHPortrait; readonly property int viewportMarginY: postergrid.height; readonly property real absY: y + sections.y
                    readonly property bool nearViewport: ((absY + height) >= (_vFlick.contentY - viewportMarginY)) && (absY <= (_vFlick.contentY + _vFlick.height + viewportMarginY))
                    readonly property bool forceLoad: postergrid.focusSection === 3 && postergrid.currentLatestGroup === groupIndex
                    readonly property bool sectionActiveNow: forceLoad || nearViewport; property bool _everSectionActive: false
                    onNearViewportChanged: {
                        if (nearViewport) {
                            _everSectionActive = true
                            evicted = false
                            postergrid._ensureLatestGroupData(groupIndex, "near-viewport")
                        }
                    }
                    onForceLoadChanged: {
                        if (forceLoad) {
                            _everSectionActive = true
                            evicted = false
                            postergrid._ensureLatestGroupData(groupIndex, "force-load")
                        }
                    }
                    Component.onCompleted: {
                        if (nearViewport || forceLoad) {
                            _everSectionActive = true
                            postergrid._ensureLatestGroupData(groupIndex, "delegate-created")
                        }
                    }
                    property bool evicted: false
                    onEntryChanged: {
                        if (entry && entry._evicted) {
                            evicted = true
                            if (nearViewport || forceLoad) postergrid._ensureLatestGroupData(groupIndex, "entry-changed")
                        } else {
                            evicted = false
                        }
                    }
                    readonly property bool sectionModelActive: (sectionActiveNow || _everSectionActive) && !evicted && !(entry && entry._evicted)
                    width: sections.width; height: (sectionItems.length > 0 || (entry && entry._evicted && entry._hadItems)) ? (cardH + 65) : 0; visible: height > 0
                    Text { textFormat: Text.PlainText;
                        text: "Récemment ajouté dans " + sectionName; color: "#fff"; font.pixelSize: postergrid.sectionTitleFontPx; font.bold: true
                        font.weight: Font.Bold; anchors.left: parent.left; anchors.leftMargin: 40
                        anchors.top: parent.top
                    }
                    Text { textFormat: Text.PlainText;
                        anchors.left: parent.left; anchors.leftMargin: 40; anchors.verticalCenter: parent.verticalCenter; text: "Rechargement…"
                        color: "#AEB5C9"; font.pixelSize: 18
                        visible: !!(entry && entry._evicted && (nearViewport || forceLoad))
                    }
                    ListView {
                        id: latestList; anchors.top: parent.top; anchors.topMargin: 45; anchors.left: parent.left
                        anchors.right: parent.right; anchors.leftMargin: viewLeftMargin; anchors.rightMargin: viewRightMargin; height: latestSection.cardH
                        model: latestSection.sectionModelActive ? latestSection.sectionItems : null
                        orientation: ListView.Horizontal; spacing: spacingW; snapMode: ListView.NoSnap
                        highlightMoveDuration: 0
                        highlightRangeMode: ListView.NoHighlightRange
                        property int edgePad: postergrid.resumeRowEdgePad
                        header: Item { width: latestList.edgePad; height: 1 }
                        footer: Item { width: latestList.edgePad; height: 1 }
                        preferredHighlightBegin: 0; preferredHighlightEnd: 0
                        highlightFollowsCurrentItem: false
                        highlight: Item { width: 1; height: 1 }
                        reuseItems: latestSection.sectionModelActive
                        cacheBuffer: latestSection.sectionModelActive ? Math.round(postergrid.resumeLandscapeCardW * 1.15) : 0
                        focus: (focusSection === 3 && currentLatestGroup === groupIndex && (!postergrid._focusRestorePending || postergrid._isRestoreLatestTargetGroup(groupIndex)) && (!postergrid._latestRestoreAnchorActive || postergrid._isLatestRestoreAnchoredGroup(groupIndex)))
                        boundsBehavior: Flickable.StopAtBounds; interactive: false
                        keyNavigationEnabled: false
                        currentIndex: -1; clip: true
                        readonly property int selectedIndex: {
                            if (count <= 0) return -1
                            if (postergrid._latestRestoreAnchorActive && postergrid._isLatestRestoreAnchoredGroup(groupIndex)) return MediaCatalog.clampIndex( postergrid._latestRestoreAnchorIndexForGroup(groupIndex), count)
                            return MediaCatalog.clampIndex(postergrid.latestIndexFor(groupIndex), count)
                        }
                        property int _ensureVisibleSeq: 0
                        function _modelArray() {
                            return latestSection.sectionModelActive ? (latestSection.sectionItems || []) : []
                        }
                        readonly property real logicalContentWidth:
                            postergrid._rowLogicalWidth(_modelArray(), latestSection.cardSectionKind, spacing, edgePad, width)
                        contentWidth: logicalContentWidth
                        function ensureSelectedItemVisible(animateMove) {
                            var seq = ++_ensureVisibleSeq
                            postergrid._ensureRowIndexVisible(latestList, _modelArray(), selectedIndex, latestSection.cardSectionKind, latestContentXAnim, animateMove === true, seq)
                        }
                        NumberAnimation {
                            id: latestContentXAnim
                            target: latestList
                            property: "contentX"
                            duration: postergrid.railScrollDurationMs
                            easing.type: Easing.OutCubic
                        }
                        function syncFromSaved(){ latestList.ensureSelectedItemVisible(false); }
                        Component.onCompleted: syncFromSaved()
                        onModelChanged: syncFromSaved()
                        onCountChanged: syncFromSaved()
                        onWidthChanged: ensureSelectedItemVisible(false)
                        onContentWidthChanged: ensureSelectedItemVisible(false)
                        delegate: Loader {
                            id: latestCardLoader
                            width: postergrid.mediaCardDelegateWidthFor(cardData, latestSection.cardSectionKind)
                            height: latestSection.cardH; z: cardSelected ? 100 : 0
                            property var cardData: modelData; property var cardController: postergrid; property bool cardSelected: latestList.activeFocus && focusSection === 3 && currentLatestGroup === groupIndex && latestList.selectedIndex === index && postergrid._isRestoreLatestVisualSelection(groupIndex, index, cardData)
                            property int currentIndexSafe: latestList.selectedIndex >= 0 ? latestList.selectedIndex : 0; property bool nearFocusedIndex: Math.abs(index - currentIndexSafe) <= postergrid.hydrationRadius
                            property bool cardAllowLoad: postergrid._homeImageLoadGate && (cardSelected || latestSection.nearViewport || latestSection._everSectionActive || postergrid.hydrationDone || (postergrid.hydrationAllowed && nearFocusedIndex))
                            property bool cardEnableMouseInput: true; property bool cardSuppressFocusTransform: false; property bool cardShowProgress: true; property bool cardPreferBackdrop: postergrid.mediaCardPreferBackdropFor(cardData, latestSection.cardSectionKind)
                            property bool cardMusicFallback: latestSection.isMusicSection; property string cardFallbackKind: postergrid.mediaCardFallbackKindFor(cardData, latestSection.cardSectionKind)
                            property string cardImagePolicy: latestSection.cardSectionKind === "latest-series" ? "latest-series" : "standard"
                            property int cardTileW: postergrid.mediaCardTileWidthFor(cardData, latestSection.cardSectionKind); property int cardTileH: postergrid.mediaCardTileHeightFor(cardData, latestSection.cardSectionKind); property int cardTitleH: titleH
                            property int cardSidePad: postergrid.mediaCardSidePadFor(cardData, latestSection.cardSectionKind); property int cardTopPad: postergrid.mediaCardTopPadFor(cardData, latestSection.cardSectionKind)
                            source: postergrid.posterGridCardSource
                            onLoaded: if (item) item.homeLoader = latestCardLoader
                            Connections {
                                target: latestCardLoader.item
                                ignoreUnknownSignals: true
                                function onActivated() {
                                    postergrid._forceLatestIndexForGroup(groupIndex, index)
                                    postergrid._focusSection(3, groupIndex, "latest-mouse")
                                    if (postergrid.hydrationAllowed && !postergrid.hydrationDone && !hydrationTimer.running) hydrationTimer.restart()
                                }
                                function onDoubleActivated(){ var it = latestList.model[index]; if (!it) return; armLatestSnapshotForNavigation(groupIndex, index, "nav-latest-double"); openContentItem(it, "Fonctionnalité non supportée", latestSection.entry); }
                            }
                        }
                        Keys.onPressed: {
                            var idx = latestList.selectedIndex >= 0 ? latestList.selectedIndex : 0
                            if (event.key === Qt.Key_Right) {
                                postergrid._clearLatestRestoreAnchor()
                                if (idx < count - 1) postergrid._forceLatestIndexForGroup(groupIndex, idx + 1)
                                event.accepted = true
                            } else if (event.key === Qt.Key_Left) {
                                postergrid._clearLatestRestoreAnchor()
                                postergrid._forceLatestIndexForGroup(groupIndex, Math.max(0, idx - 1))
                                event.accepted = true
                            } else if (event.key === Qt.Key_Up) {
                                postergrid._clearLatestRestoreAnchor()
                                if (groupIndex > 0) focusLatestGroup(groupIndex - 1)
                                else postergrid._focusAdjacentSection(3, -1)
                                event.accepted = true
                            } else if (event.key === Qt.Key_Down) {
                                postergrid._clearLatestRestoreAnchor()
                                if (groupIndex < latestByFolder.length - 1) {
                                    currentLatestGroup = groupIndex + 1
                                    focusLatestGroup(currentLatestGroup)
                                } else postergrid.requestMoreLatestForProximity()
                                event.accepted = true
                            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                                var navIdx = latestList.selectedIndex >= 0 ? latestList.selectedIndex : 0; var it2 = latestList.model[navIdx]
                                if (it2) {
                                    armLatestSnapshotForNavigation(groupIndex, navIdx, "nav-latest-key")
                                    openContentItem(it2, "Fonctionnalité non supportée", latestSection.entry)
                                }
                                event.accepted = true
                            } else if (event.key === Qt.Key_Home) {
                                postergrid._clearLatestRestoreAnchor()
                                postergrid._focusSection(0, 0, "home-key")
                                event.accepted = true
                            }
                        }
                        onSelectedIndexChanged: {
                            latestList.ensureSelectedItemVisible(true)
                            if (!latestSection.sectionModelActive) return
                            if (postergrid._focusRestorePending || postergrid._restoringFocus || postergrid._focusRestoreSettle) return
                            if (focusSection !== 3 || currentLatestGroup !== groupIndex) return
                            if (!latestList.activeFocus) return
                            postergrid.setLatestIndexForGroup(groupIndex, selectedIndex)
                            postergrid.updateBackdrop()
                            if (postergrid.hydrationAllowed && !postergrid.hydrationDone && !hydrationTimer.running) hydrationTimer.restart()
                        }
                    }
                }
            }
            Item { width: parent.width; height: bottomSpacer }
        }
    }
    onCurrentFolderIndexChanged: {
        if (!folderList) return
        var want = MediaCatalog.clampIndex(currentFolderIndex, folderList.count)
        if (folderList.currentIndex !== want) {
            _syncFolderIndex = true
            folderList.currentIndex = want
            _syncFolderIndex = false
        }
        if ((_restoringFocus || _focusRestorePending || _focusRestoreSettle)
                && !_folderRestoreHorizontalPending
                && folderList.ensureIndexVisible)
            folderList.ensureIndexVisible(want, false)
        if (focusSection === 0 && !_restoringFocus && !_focusRestorePending && !_focusRestoreSettle) saveFocusSnapshot("folderIndex")
    }
    onCurrentResumeIndexChanged: {
        if (!resumeList) return
        if (focusSection === 1 && !_restoringFocus && !_focusRestorePending && !_focusRestoreSettle) saveFocusSnapshot("resumeIndex")
    }
    onCurrentNextUpIndexChanged: {
        if (!nextUpList) return
        var want = MediaCatalog.clampIndex(currentNextUpIndex, nextUpList.count)
        if (nextUpList.currentIndex !== want) {
            _syncNextUpIndex = true
            nextUpList.currentIndex = want
            _syncNextUpIndex = false
        }
        if ((_restoringFocus || _focusRestorePending || _focusRestoreSettle) && nextUpList.ensureIndexVisible)
            nextUpList.ensureIndexVisible(want, false)
        if (focusSection === 2 && !_restoringFocus && !_focusRestorePending && !_focusRestoreSettle) saveFocusSnapshot("nextUpIndex")
    }
    onFocusSectionChanged: {
        if (focusSection !== 0 && _folderRestoreHorizontalPending) {
            folderRestoreHorizontalTimer.stop()
            _folderRestoreHorizontalPending = false
            _folderRestoreHorizontalRetryLeft = 0
        }
        if (focusSection !== 1 && _resumeRestoreHorizontalPending) {
            resumeRestoreHorizontalTimer.stop()
            _resumeRestoreHorizontalPending = false
            _resumeRestoreHorizontalRetryLeft = 0
            _resumeRestoreSavedViewportX = null
            _resumeRestoreSavedViewportWidth = null
        }
        if (!_restoringFocus && !_focusRestorePending && !_focusRestoreSettle) _scheduleFocusSectionScroll()
        updateBackdrop()
        _resetHydration()
        scheduleLatestEvict()
        if (!_restoringFocus && !_focusRestorePending && !_focusRestoreSettle) saveFocusSnapshot("focusSection")
    }
    Loader {
        id: unsupportedLoader
        anchors.fill: parent
        z: 5000
        // Préchargé avec PosterGrid : le premier OK sur une bibliothèque non supportée ne doit jamais dépendre du temps de création du composant. UnsupportedDialog reste invisible (_open=false) tant qu'il n'est pas utilisé.
        active: true
        asynchronous: false
        source: Qt.resolvedUrl("../components/UnsupportedDialog.qml")
        property string pendingMessage: ""
        function _showPendingUnsupported() {
            if (!overlayOpen || !item) return false
            var message = pendingMessage.length
                        ? pendingMessage
                        : "Fonctionnalité non supportée"
            pendingMessage = ""
            try { item.overlayOpacity = 0.55 } catch(e0) {}
            try { item.z = 5001 } catch(e1) {}
            item.open(message)
            try { item.forceActiveFocus() } catch(e2) {}
            return true
        }
        function openUnsupported(message) {
            pendingMessage = message || "Fonctionnalité non supportée"
            overlayOpen = true
            // Le composant est normalement déjà prêt grâce au préchargement. Si l'utilisateur agit pendant sa création, onLoaded consommera le message en attente au lieu de perdre ce premier appui.
            if (_showPendingUnsupported()) return
            Qt.callLater(function(){ unsupportedLoader._showPendingUnsupported() })
        }
        onLoaded: {
            if (!item) return
            function restorePageFocus() {
                if (!postergrid.overlayOpen && !unsupportedLoader.pendingMessage.length)
                    return
                overlayOpen = false
                pendingMessage = ""
                try { item.focus = false } catch(e0) {}
                Qt.callLater(function(){ postergrid.forceFocus() })
            }
            if (item.requestClose) item.requestClose.connect(restorePageFocus)
            if (item.closed) item.closed.connect(restorePageFocus)
            // Cas rare : activation utilisateur arrivée pendant la toute première création du Loader. L'ouverture est rejouée dès que l'item existe.
            Qt.callLater(function(){ unsupportedLoader._showPendingUnsupported() })
        }
    }
}
