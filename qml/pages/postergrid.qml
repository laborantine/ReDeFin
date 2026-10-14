import QtQuick 2.15
import "../js/MediaBrowser.js" as MediaBrowser
import "../js/HomeLatestLoader.js" as HomeLatest
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/MediaCatalog.js" as MediaCatalog
import "../js/MediaRailLayout.js" as MediaRailLayout
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
    property int homeRevealSettleMs: 60
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
                if (!MediaCatalog.homeItemsEqual(resumeItems, arr)) {
                    // Ne pas réannoter 50 DTO / positions quand Jellyfin renvoie
                    // des données équivalentes (les métriques sont purement locales).
                    arr = MediaRailLayout.prepareHomeRowMetrics(arr, "resume", homeCardLayout)
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
        arr = MediaCatalog.safeArray(arr)
        if (!MediaCatalog.homeLatestGroupsEqual(latestByFolder || [], arr)) {
            // Projection et recalcul des positions des rails seulement si le
            // contenu effectif a changé, pas à chaque passage du watchdog.
            arr = MediaRailLayout.prepareHomeLatestGroups(arr, homeCardLayout)
            if (!latestByFolder || latestByFolder.length === 0) _restartHomeImageSettle()
            latestByFolder = arr
            _saveHomeCacheSoon()
        }
    }
    // Un seul ordonnanceur pour la restauration du snapshot ET les réparations
    // ordinaires. La restauration a priorité ; les calibrations horizontales
    // spécialisées restent inchangées (ApplyRange de ListView sur Freebox).
    property int _focusRecoveryScheduledKind: -1 // -1 aucun, 0 réparation, 1 snapshot
    Timer { id: focusRecoveryTimer; interval: 80; repeat: false; onTriggered: postergrid._runFocusRecovery() }
    function _queueFocusRecovery(kind) {
        if (!_alive || !focusRepairEnabled) return
        var restore = (kind === "restore" || _focusRestorePending)
        if (restore) {
            if (_focusRecoveryScheduledKind !== 1 || !focusRecoveryTimer.running) {
                _focusRecoveryScheduledKind = 1
                focusRecoveryTimer.interval = 110
                focusRecoveryTimer.restart()
            }
        } else if (!focusRecoveryTimer.running) {
            _focusRecoveryScheduledKind = 0
            focusRecoveryTimer.interval = 80
            focusRecoveryTimer.start()
        }
    }
    function _runFocusRecovery() {
        _focusRecoveryScheduledKind = -1
        if (!_alive || !focusRepairEnabled) return
        if (_focusRestorePending || hasPendingFocusRestore()) {
            if (_focusRestorePending) _applyFocusSnapshotToViews()
            else scheduleFocusRestore()
            return
        }
        if (!pageActive || _homeFocusRepairLeft <= 0) return
        _repairHomeFocus()
        if (!_hasAnyHomeListFocus() && _homeFocusRepairLeft > 0) {
            --_homeFocusRepairLeft
            _queueFocusRecovery("repair")
        } else _homeFocusRepairLeft = 0
    }
    function _cancelFocusRepairRetry() {
        _homeFocusRepairLeft = 0
        if (_focusRecoveryScheduledKind === 0) {
            focusRecoveryTimer.stop()
            _focusRecoveryScheduledKind = -1
        }
    }
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
    function pendingFocusRestoreTargetsLatest() {
        var snap = _focusSnapshot()
        return _snapshotNeedsRestore(snap) && Math.max(0, Math.min(3, snap.focusSection || 0)) === 3
    }

    function consumeFocusSnapshotKeepState() {
        var snap = _focusSnapshot()
        if (!snap) return false
        try { focusRecoveryTimer.stop() } catch(e0) {}
        _focusRecoveryScheduledKind = -1
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
        _queueFocusRecovery("restore")
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
            _queueFocusRecovery("restore")
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
    function scheduleFocusRestore(){ if (!focusRepairEnabled) return; var snap = _focusSnapshot(); if (!_snapshotNeedsRestore(snap)) return; _focusRestorePending = true; _focusRestoreRetryLeft = Math.max(_focusRestoreRetryLeft, 24); _queueFocusRecovery("restore"); }
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
    property bool _homePosterVisualReady: false; readonly property bool homePosterVisualReady: _homePosterVisualReady; property int homePosterProbeMs: 45; property int homePosterPendingProbeMs: 120; property int homePosterReadySettleMs: 90
    property bool _homePosterProbeWaiting: false
    property int _homePosterUnreadyPolls: 0
    // La cadence reste rapide au démarrage, puis ralentit si Jellyfin tarde.
    // Ne modifie ni le délai maximal du rideau ni les images déjà présentes.
    function _homePosterProbeInterval() {
        if (!_homePosterProbeWaiting) return Math.max(25, homePosterProbeMs)
        var base = Math.max(25, homePosterPendingProbeMs)
        if (_homePosterUnreadyPolls >= 20) return Math.max(base, 360)
        if (_homePosterUnreadyPolls >= 7) return Math.max(base, 220)
        return base
    }
    function _waitForHomePosters() {
        _homePosterProbeWaiting = true
        _homePosterVisualReady = false
        _homePosterUnreadyPolls = Math.min(40, _homePosterUnreadyPolls + 1)
        homePosterReadySettleTimer.stop()
        homePosterProbeTimer.restart()
    }
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
        _homePosterUnreadyPolls = 0
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
            _homePosterProbeWaiting = false
            _homePosterUnreadyPolls = 0
            _homePosterVisualReady = true
            return
        }
        if (!_homeImagesReady || _homeImageReturnFreeze) {
            _waitForHomePosters()
            return
        }
        var state = _visibleHomePosterState()
        if (state.total <= 0 || state.pending > 0) {
            _waitForHomePosters()
            return
        }
        _homePosterProbeWaiting = false
        _homePosterUnreadyPolls = 0
        if (!_homePosterVisualReady && !homePosterReadySettleTimer.running) homePosterReadySettleTimer.restart()
    }
    function prepareHomeVisualReturn(reason) {
        _homePosterVisualReady = false
        _homePosterProbeWaiting = false
        _homePosterUnreadyPolls = 0
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
    Timer { id: homePosterProbeTimer; interval: postergrid._homePosterProbeInterval(); repeat: false; onTriggered: postergrid._probeHomePosterVisualReady() }
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
                postergrid._homePosterUnreadyPolls = 0
            } else {
                postergrid._waitForHomePosters()
            }
        }
    }
    readonly property int homeCacheSchemaVersion: 19; readonly property int homeCacheMaxEntries: 2
    property string _lastHomeCacheRestoreKey: ""
    property double _lastHomeCacheRestoreCacheTs: 0
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
            // Ne jamais écraser le dernier snapshot complet par un instantané
            // partiel pendant le streaming de bibliothèques T1.
            if (!postergrid._latestAllComplete && postergrid._latestLibs.length > 0) return
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
                // Un snapshot pris pendant la file Latest ou après un échec
                // ne doit pas empêcher de recharger les dossiers au retour.
                latestAllComplete: postergrid._latestAllComplete && !postergrid._latestHadFailures,
                latestIndicesByGroup: cacheLatestIndices,
                currentFolderIndex: cacheFolderIndex,
                currentResumeIndex: cacheResumeIndex,
                currentNextUpIndex: cacheNextUpIndex,
                currentLatestGroup: cacheLatestGroup
            })
            MediaBrowser.trimHomeCacheStore(st, cacheKey, postergrid.homeCacheSchemaVersion,
                                               postergrid.homeCacheFreshMs, postergrid.homeCacheMaxEntries, Date.now())
        } catch(e) {}
    }
    function _restoreHomeCacheIfFresh() {
        try {
            // Une restauration demandée pendant un refresh du même profil ne
            // doit pas remplacer les résultats qui arrivent encore du réseau.
            if (fetchedOnce && _latestLibs.length > 0 && !_latestAllComplete
                    && _activeFetchKey === _fetchKey()) return false
            var st = _homeCacheStore()
            if (!st) {
                return false
            }
            var now = Date.now()
            var cacheKey = _homeCacheKey(); var c = MediaBrowser.touchHomeCache(st, cacheKey, homeCacheSchemaVersion, homeCacheFreshMs, now)
            if (!c) {
                MediaBrowser.trimHomeCacheStore(st, "", homeCacheSchemaVersion, homeCacheFreshMs, homeCacheMaxEntries, now)
                return false
            }
            if (c.latestAllComplete !== true) {
                return false
            }
            var cacheTs = Number(c.ts || 0)
            if (_lastHomeCacheRestoreKey === cacheKey && _lastHomeCacheRestoreCacheTs === cacheTs
                    && fetchedOnce === true && libraryFetchCompleted === true
                    && resumeFetchCompleted === true && nextUpFetchCompleted === true
                    && latestFetchCompleted === true) {
                return true
            }
            MediaBrowser.trimHomeCacheStore(st, cacheKey, homeCacheSchemaVersion, homeCacheFreshMs, homeCacheMaxEntries, now)
            // Annule les callbacks de l'ancienne session avant d'installer le
            // snapshot du nouveau profil. Un ancien dossier ne peut ainsi
            // pas revenir dans le modèle restauré.
            _fetchSeq++
            _nextUpSeq++
            HomeLatest.cancelReloads(postergrid, "home_cache_restored")
            HomeLatest.cancelInitialRequests(postergrid, "home_cache_restored")
            latestPumpTimer.stop()
            latestInitialReadyTimer.stop()
            latestPublishTimer.stop()
            _latestLibs = []
            _latestTemp = []
            _latestPos = 0
            _latestInFlight = 0
            _latestAllComplete = true
            _latestInitialComplete = true
            _latestHadFailures = false
            var cachedLibrary = MediaCatalog.safeArray(c.libraryItems); var cachedResume  = MediaRailLayout.prepareHomeRowMetrics(MediaCatalog.safeArray(c.resumeItems), "resume", homeCardLayout); var cachedNextUp  = MediaCatalog.safeArray(c.nextUpItems)
            var cachedLatest  = MediaRailLayout.prepareHomeLatestGroups(MediaCatalog.safeArray(c.latestByFolder), homeCardLayout)
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
            _cancelFocusRepairRetry()
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
    function topPadFor(h) {
        return MediaRailLayout.focusTopPad(h, zoomScale, focusLiftPx, frameWidth)
    }
    readonly property int topPadLandscape: topPadFor(tileH)
    readonly property int libraryTopPad: topPadFor(libraryTileH)
    readonly property int topPadPortrait: topPadFor(portH)
    readonly property int cardHLandscape: tileH + titleH + topPadLandscape
    readonly property int libraryCardH: libraryTileH + titleH + libraryTopPad
    readonly property int cardHPortrait: portH + titleH + topPadPortrait
    readonly property int hydrationStep: 6
    readonly property int hydrationMax: 30
    property int hydrationRadius: 6
    property bool hydrationDone: false
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

    property real bgDarken: 0.40; readonly property int  bgCapW: 1280; readonly property int  bgCapH: 720; readonly property int  bgQuality: 80; readonly property real posterScale: 1.15; readonly property int posterQFast: 82
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

    function mediaCardTileWidthFor(it, sectionKind) {
        return MediaRailLayout.homeCardTileWidthFor(it, sectionKind, portW, resumeLandscapeW)
    }
    function mediaCardTileHeightFor(it, sectionKind){ return portH; }
    function mediaCardTopPadFor(it, sectionKind){ return topPadPortrait; }
    function mediaCardSidePadFor(it, sectionKind) {
        return MediaRailLayout.homeCardSidePadFor(it, sectionKind, portraitSidePad, focusPadSide)
    }
    function mediaCardDelegateWidthFor(it, sectionKind) {
        return mediaCardTileWidthFor(it, sectionKind)
                + mediaCardSidePadFor(it, sectionKind) * 2
    }
    function mediaCardPreferBackdropFor(it, sectionKind) {
        return MediaRailLayout.homeCardPrefersBackdrop(it, sectionKind)
    }
    function mediaCardFallbackKindFor(it, sectionKind) {
        return MediaRailLayout.homeCardFallbackKind(it, sectionKind)
    }
    function _resumeSnapshotViewportGeometry(){ if (!resumeList || resumeList.count <= 0) return null; var idx = MediaCatalog.clampIndex(currentResumeIndex, resumeList.count); return MediaRailLayout.homeRowRealDelegateGeometry(resumeList, idx); }

    // MOTEUR MANUEL DE GLISSEMENT HORIZONTAL Utilisé uniquement par « Continuer de regarder » et « Récemment ajouté ». « Mes médias » et « À suivre » conservent le glide natif historique ListView (SnapOneItem + ApplyRange + highlightMoveDuration 120).
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

    function _resumeRealTargetX(list, idx) {
        return MediaRailLayout.resumeRealTargetX(list, idx, cappedResumeItems, homeCardLayout, railRevealMarginPx)
    }
    function _resumeDirectionalNaturalTargetX(list, fromIdx, toIdx, direction) {
        return MediaRailLayout.resumeDirectionalTargetX(list, fromIdx, toIdx, direction, cappedResumeItems, homeCardLayout, railRevealMarginPx)
    }
    function _rowTargetX(list, arr, idx, sectionKind) {
        return MediaRailLayout.homeListTargetX(list, arr, idx, sectionKind, homeCardLayout, railRevealMarginPx)
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
    function openEpisodeLike(it) {
        if (!it) return
        var ids = MediaCatalog.navigationIdsForEpisodeLike(it)
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
        if (t === "boxset") {
            requestDetailCollection(it.Id)
        } else if (t === "movie" || t === "video" || t === "musicvideo") {
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
        // Le CollectionType=mixed explicite prime sur les heuristiques de nom
        // (« Collections », « Vidéos »...) pour garantir la bonne page.
        if (MediaCatalog.isMixedLibraryFolder(it)) requestSeriesPage(it.Id, "mixed")
        else if (MediaCatalog.isCollectionsLibraryFolder(it)) requestCollectionPage(it.Id)
        else if (MediaCatalog.isPersonalMediaLibraryFolder(it)) requestPersonalMediaPage(it.Id, "")
        else if (MediaCatalog.folderShouldOpenOnMoviePage(it)) requestMoviePage(it.Id)
        else if (MediaCatalog.isSeriesLibraryFolder(it)) requestSeriesPage(it.Id, "series")
        else if (t === "movie") requestDetailMovie(it.Id)
        else if (t === "series") openSeries(it.Id)
        else if (MediaCatalog.isUnsupportedMediaItem(it)) openUnsupportedFolder(it)
        else playItem(it)
    }
    // Identités stables des timers, sans duplication de leurs objets QML.
    readonly property var _latestLoadTimers: ({
        pump: latestPumpTimer,
        publish: latestPublishTimer,
        ready: latestInitialReadyTimer
    })

    readonly property int latestFullLimit: 50; readonly property int latestMaxInflight: 2
    // Deux requêtes initiales et une place possible pour un focus prioritaire.
    // Le plafond s'applique à l'ensemble (initial + rechargements), pas par file.
    readonly property int latestTotalMaxInflight: 3
    readonly property int latestStartDelayMs: 110; readonly property int latestProximityLibraryStep: 3
    // Le transport Jellyfin a déjà un délai de 15 s. Ne pas supprimer une
    // réponse encore valide à 6,5 s sur un serveur lent.
    readonly property int latestInitialRequestTimeoutMs: 16500
    readonly property int latestInitialReadyMs: 1800
    property var _latestLibs: []; property int _latestPos: 0; property int _latestInFlight: 0; property int _latestQueueSeq: 0; property var _latestReloadHandles: ({})
    property var _latestInitialPending: ({})
    // Une seule demande urgente en attente : le dernier focus D-Pad l'emporte.
    property var _latestPriorityReload: ({ id: "", reason: "" })
    property int _latestDirtyIndex: -1
    property bool _latestDirtyMany: false
    property var _homeWarningLastMs: ({})
    readonly property int homeWarningThrottleMs: 60000
    function _warnHomeOnce(key) {
        var last = Number(_homeWarningLastMs[key] || 0)
        var now = Date.now()
        if (last > 0 && now - last < homeWarningThrottleMs) return
        _homeWarningLastMs[key] = now
    }

    property int _latestStageTarget: 0; property bool _latestInitialComplete: false; property bool _latestAllComplete: false; property bool _latestHadFailures: false; property bool latestFetchCompleted: false
    readonly property int latestRevealResponseCount: 3
    property int _latestResponsesDone: 0
    // T6: regrouper plusieurs callbacks Latest dans une seule projection QML.
    Timer { id: latestPublishTimer; interval: 65; repeat: false; onTriggered: HomeLatest.publishPending(postergrid) }

    Timer { id: latestPumpTimer; interval: postergrid.latestStartDelayMs; repeat: false; onTriggered: HomeLatest.pumpInitial(postergrid, postergrid._latestLoadTimers) }
    Timer {
        id: latestInitialReadyTimer
        interval: postergrid.latestInitialReadyMs
        repeat: false
        onTriggered: {
            if (!postergrid._alive || postergrid.latestFetchCompleted) return
            // Le délai borne le rideau, PAS la file réseau : les autres rails
            // continuent à arriver sans bloquer le scroll ni le D-Pad.
            postergrid._latestInitialComplete = true
            postergrid.latestFetchCompleted = true
            postergrid.prepareHomeReveal("latest-background")
        }
    }
    Timer { id: latestInitialWatchdog; interval: 500; repeat: true; running: postergrid._alive && postergrid._latestInFlight > 0; onTriggered: HomeLatest.sweepInitialRequests(postergrid, postergrid._latestLoadTimers) }

    // Les textures restent gérées par ListView/Image (aucune image conservée ici).
    // Conserver au maximum 3 tableaux de DTO récemment évincés pendant 22 s
    // permet un retour D-Pad instantané sans nouvelle requête Jellyfin.
    readonly property int latestWarmRailMax: 3
    readonly property int latestWarmRailTTL: 22000
    readonly property int latestReloadGraceMs: 10000
    property var _latestWarmRails: []
    // Un seul réveil à la première expiration : pas de timer périodique pendant le scroll.
    Timer {
        id: latestWarmRailExpiryTimer
        interval: postergrid.latestWarmRailTTL
        repeat: false
        running: false
        onTriggered: postergrid._pruneLatestWarmRails()
    }
    function _scheduleLatestWarmRailExpiry(now) {
        var rails = _latestWarmRails || []
        if (!rails.length) { latestWarmRailExpiryTimer.stop(); return }
        var waitMs = latestWarmRailTTL + 1
        for (var i = 0; i < rails.length; ++i) {
            var rec = rails[i]
            if (!rec) continue
            var remaining = Math.max(1, latestWarmRailTTL - (now - Number(rec.at || 0)) + 1)
            if (remaining < waitMs) waitMs = remaining
        }
        latestWarmRailExpiryTimer.interval = waitMs
        latestWarmRailExpiryTimer.restart()
    }
    function _pruneLatestWarmRails() {
        var old = _latestWarmRails || [], now = Date.now(), next = []
        for (var i = 0; i < old.length; ++i) {
            var rec = old[i]
            if (rec && now - Number(rec.at || 0) < latestWarmRailTTL) next.push(rec)
        }
        if (next.length !== old.length) _latestWarmRails = next
        _scheduleLatestWarmRailExpiry(now)
    }
    function _clearLatestWarmRails() {
        latestWarmRailExpiryTimer.stop()
        _latestWarmRails = []
    }
    function _rememberLatestRail(entry, now) {
        if (!entry || !entry.id || !entry.items || !entry.items.length) return
        var id = String(entry.id), previous = _latestWarmRails || [], next = []
        for (var i = 0; i < previous.length; ++i) {
            var rec = previous[i]
            if (rec && rec.id !== id && now - rec.at <= latestWarmRailTTL) next.push(rec)
        }
        next.push(({ id: id, items: entry.items, at: now }))
        if (next.length > latestWarmRailMax) next = next.slice(next.length - latestWarmRailMax)
        _latestWarmRails = next
        _scheduleLatestWarmRailExpiry(now)
    }
    function _takeWarmLatestRail(id) {
        var now = Date.now(), old = _latestWarmRails || [], next = [], result = null
        for (var i = 0; i < old.length; ++i) {
            var rec = old[i]
            if (!rec || now - rec.at > latestWarmRailTTL) continue
            if (rec.id === id) result = rec.items
            else next.push(rec)
        }
        _latestWarmRails = next
        _scheduleLatestWarmRailExpiry(now)
        return result
    }
    function _ensureLatestGroupData(groupIndex, reason) {
        if (!_alive || !hasCreds() || !latestByFolder || groupIndex < 0 || groupIndex >= latestByFolder.length) return false
        var entry = latestByFolder[groupIndex]
        if (!entry || !entry._evicted || !entry.id) return false
        var id = String(entry.id)
        if (_latestReloadHandles && _latestReloadHandles[id]) return true
        var warmItems = _takeWarmLatestRail(id)
        if (warmItems && warmItems.length) {
            var warmEntry = MediaCatalog.shallowCloneObject(entry)
            warmEntry.items = warmItems
            warmEntry._evicted = false
            warmEntry._hadItems = true
            warmEntry._evictedAt = 0
            warmEntry._loadedAt = Date.now()
            HomeLatest.replaceEntry(postergrid, groupIndex, warmEntry, true)
            var warmSection = latestRepeater ? latestRepeater.itemAt(groupIndex) : null
            if (warmSection) warmSection.evicted = false
            if (_focusRestorePending) {
                _focusRestoreRetryLeft = Math.max(_focusRestoreRetryLeft, 36)
                _queueFocusRecovery("restore")
            }
            return false
        }
        var urgent = reason === "focus" || reason === "focus-restore" || reason === "force-load"
        var reloadCount = HomeLatest.reloadCount(postergrid)
        if (_latestInFlight + reloadCount >= latestTotalMaxInflight ||
                (!urgent && reloadCount >= latestMaxInflight)) {
            if (urgent) {
                // Un force-load d'un delegate ne doit pas déloger un vrai focus.
                var wanted = _latestPriorityReload || ({})
                var priority = reason === "focus-restore" ? 3 : (reason === "focus" ? 2 : 1)
                var currentPriority = wanted.reason === "focus-restore" ? 3 : (wanted.reason === "focus" ? 2 : 1)
                if (!wanted.id || String(wanted.id) === id || priority >= currentPriority)
                    _latestPriorityReload = ({ id: id, reason: reason })
            }
            // File de secours sans attente active pour les erreurs/annulations.
            latestReloadRetryTimer.restart()
            return true
        }
        var seq = _fetchSeq
        // Enregistrer AVANT fetch : le cache Jellyfin peut appeler le callback
        // synchroniquement. L'identité du record protège les retours périmés.
        var rec = ({ handle: null })
        _latestReloadHandles[id] = rec
        var handle = null
        try {
            handle = HomeLatest.fetchForFolder(postergrid, 
                    id,
                    latestFullLimit,
                    MediaCatalog.isSeriesLibraryFolder(entry),
                    function(items) {
                if (!_safeCanTouch(seq) || !_latestReloadHandles || _latestReloadHandles[id] !== rec) return
                delete _latestReloadHandles[id]
                HomeLatest.wakeQueues(postergrid, postergrid._latestLoadTimers)
                var arr = MediaCatalog.safeArray(items); var idx = HomeLatest.entryIndexById(postergrid, id)
                if (idx < 0 || arr.length <= 0) {
                    latestReloadRetryTimer.restart()
                    return
                }
                var current = latestByFolder[idx] || entry; var restored = MediaCatalog.shallowCloneObject(current)
                restored.items = arr
                restored._evicted = false
                restored._hadItems = true
                restored._evictedAt = 0
                restored._loadedAt = Date.now()
                HomeLatest.replaceEntry(postergrid, idx, restored, true)
                var sec = latestRepeater ? latestRepeater.itemAt(idx) : null
                if (sec) sec.evicted = false
                updateBackdrop()
                if (_focusRestorePending) {
                    _focusRestoreRetryLeft = Math.max(_focusRestoreRetryLeft, 36)
                    _queueFocusRecovery("restore")
                } else if (focusSection === 3 && currentLatestGroup === idx) {
                    Qt.callLater(function(){ if (_alive) focusLatestGroup(idx) })
                }
            }, function() {
                if (_latestReloadHandles && _latestReloadHandles[id] === rec) {
                    delete _latestReloadHandles[id]
                    HomeLatest.wakeQueues(postergrid, postergrid._latestLoadTimers)
                }
                if (_alive) latestReloadRetryTimer.restart()
            }
            )
        } catch(e0) {
            if (_latestReloadHandles && _latestReloadHandles[id] === rec) {
                delete _latestReloadHandles[id]
                HomeLatest.wakeQueues(postergrid, postergrid._latestLoadTimers)
            }
            if (_alive) latestReloadRetryTimer.restart()
            return true
        }
        // Si réponse immédiate, rec a déjà été retiré : ne jamais le ressusciter.
        if (_latestReloadHandles && _latestReloadHandles[id] === rec) rec.handle = handle
        return true
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
        // La fin du rideau n'annule pas les téléchargements des rails ; les
        // réponses tardives doivent encore pouvoir remplir chaque dossier.
        latestInitialReadyTimer.stop()
        latestFetchCompleted = true
        libraryFetchCompleted = true
        resumeFetchCompleted = true
        nextUpFetchCompleted = true
        _resetHydration()
        updateBackdrop()
        prepareHomeReveal(reason || "home-timeout")
        return true
    }
    function forceHomeRevealReady() {
        if (!_alive) return false
        try { focusRecoveryTimer.stop() } catch(e0) {}
        _focusRecoveryScheduledKind = -1
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
            if (!postergrid._safeCanTouch(seq)) return
            root._fetchInFlight = false
            root.fetchedOnce = true
            root.libraryFetchCompleted = true
            var raw = (items && items.length !== undefined) ? items : []
            var safe = raw.filter(function(i){ return i && i.Name !== "Playlists" })
            root._setListIfChanged("libraryItems", safe)
            if (!MediaCatalog.hasCollectionsLibrary(safe) && Jellyfin.probeAccessibleCollections) {
                // /UserViews reste la référence de la Home. Si elle omet
                // Collections, ne pas déduire la visibilité du simple fait
                // que /Items renvoie un BoxSet : la vue peut être masquée.
                // Un raccourci de secours n’est créé qu’avec l’accord explicite
                // du profil, et uniquement si un BoxSet est réellement présent.
                Jellyfin.fetchUser(root.serverUrl, root.accessToken, root.userId,
                    function(user) {
                        if (!postergrid._safeCanTouch(seq) ||
                                !MediaCatalog.mayOfferVirtualCollectionsLibrary(user, root.userId)) return
                        Jellyfin.probeAccessibleCollections(root.serverUrl, root.accessToken, root.userId,
                            function(hasBoxsets) {
                                if (!hasBoxsets || !postergrid._safeCanTouch(seq)) return
                                var current = root.libraryItems || []
                                if (MediaCatalog.hasCollectionsLibrary(current)) return
                                root._setListIfChanged("libraryItems", current.concat([MediaCatalog.virtualCollectionsLibrary()]))
                                root._resetHydration()
                                root.updateBackdrop()
                                root.scheduleFocusRestore()
                            }, function() {
                                // La sonde a échoué : ne rien ajouter à l’accueil.
                            })
                    }, function() {
                        // Préférences indisponibles : comportement conservateur.
                    })
            }
            root.currentFolderIndex = MediaCatalog.clampIndex(root.currentFolderIndex, Math.min(root.libraryItems.length, root.sectionMaxItems))
            Jellyfin.fetchHomeResumeItems( root.serverUrl, root.accessToken, root.userId, root.sectionMaxItems, function(it) {
                    if (!postergrid._safeCanTouch(seq)) return
                    root._setListIfChanged("resumeItems", it || [])
                    root.resumeFetchCompleted = true
                    root.currentResumeIndex = MediaCatalog.clampIndex(root.currentResumeIndex, Math.min(root.resumeItems.length, root.sectionMaxItems))
                    root.updateBackdrop()
                    root.scheduleFocusRestore()
                }, function() {
                    if (!postergrid._safeCanTouch(seq)) return
                    root._setListIfChanged("resumeItems", [])
                    root.resumeFetchCompleted = true
                    root.currentResumeIndex = 0
                    root.updateBackdrop()
                    root.scheduleFocusRestore()
                }
            )
            root.fetchNextUpItems(seq)
            HomeLatest.fetchLibraries(postergrid, postergrid._latestLoadTimers, seq)
            root._resetHydration()
            root.updateBackdrop()
            root.scheduleFocusRestore()
        }
        function failLibraryItems() {
            if (!postergrid._safeCanTouch(seq)) return
            root._fetchInFlight = false
            _warnHomeOnce("views-failed")
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
        latestInitialReadyTimer.stop()
        latestPublishTimer.stop()
        _clearLatestWarmRails()
        HomeLatest.cancelReloads(postergrid, "destroyed")
        HomeLatest.cancelInitialRequests(postergrid, "destroyed")
        try { if (latestInitialWatchdog.running) latestInitialWatchdog.stop() } catch(eLatestWd) {}
        try { if (_visRefetch.running) _visRefetch.stop() } catch(e1) {}
        try { if (hydrationTimer.running) hydrationTimer.stop() } catch(e2) {}
        try { if (homeImageSettleTimer.running) homeImageSettleTimer.stop() } catch(e4) {}
        try { if (homeImageReturnFreezeTimer.running) homeImageReturnFreezeTimer.stop() } catch(e5) {}
        try { if (focusRecoveryTimer.running) focusRecoveryTimer.stop() } catch(e6) {}
        _focusRecoveryScheduledKind = -1
        try { if (homeRevealReadyTimer.running) homeRevealReadyTimer.stop() } catch(e7) {}
        try { if (latestEvictTimer.running) latestEvictTimer.stop() } catch(e8) {}
        try { if (latestDataEvictTimer.running) latestDataEvictTimer.stop() } catch(e9) {}
        try { if (latestReloadRetryTimer.running) latestReloadRetryTimer.stop() } catch(e10) {}
        try { if (latestProximityScrollTimer.running) latestProximityScrollTimer.stop() } catch(e11) {}
    }
    function _resetHomeCacheRestoreDedup(){ _lastHomeCacheRestoreKey=""; _lastHomeCacheRestoreCacheTs=0 }
    onAccessTokenChanged: { _clearLatestWarmRails(); _resetHomeCacheRestoreDedup(); if (ready) ensureBootFetch() }
    onUserIdChanged: { _clearLatestWarmRails(); _resetHomeCacheRestoreDedup(); if (ready) ensureBootFetch() }
    onServerUrlChanged: { _clearLatestWarmRails(); _resetHomeCacheRestoreDedup(); if (ready) ensureBootFetch() }
    onBgBlurChanged:      updateBackdrop()
    onLibraryItemsChanged:   {  updateBackdrop() }
    onResumeItemsChanged:    {  updateBackdrop() }
    onNextUpItemsChanged:    {  updateBackdrop() }
    // Une Repeater basée sur un entier recrée potentiellement tous les rails
    // lorsque la taille change. ListModel append/remove stabilise les delegates
    // déjà focusés pendant la livraison progressive des bibliothèques.
    ListModel { id: latestRailModel }
    function _syncLatestRailCount() {
        var target = latestByFolder ? latestByFolder.length : 0
        while (latestRailModel.count > target)
            latestRailModel.remove(latestRailModel.count - 1)
        while (latestRailModel.count < target)
            latestRailModel.append({ slot: latestRailModel.count })
    }
    onLatestByFolderChanged: {
        _syncLatestRailCount()
        updateBackdrop()
        scheduleFocusRestore()
        scheduleLatestEvict()
    }
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
    // Recherche prolongée : n'évacuer que les 2 textures backdrop, jamais les
    // posters/indices du Home. Retour et focus D-Pad restent immédiatement actifs.
    function releaseInactiveHomeBackdrop() {
        if (!_alive || visible || pageActive || suspendVisualTextures) return false
        var backdrop = backdropLayerLoader.item
        if (!backdrop || !backdrop.releaseTextures) return false
        backdrop.releaseTextures()
        return true
    }
    function restoreInactiveHomeBackdrop() {
        if (!_alive || suspendVisualTextures) return
        var backdrop = backdropLayerLoader.item
        if (backdrop && backdrop.update && backdrop.currentUrl)
            backdrop.update(backdrop.currentUrl())
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
    signal requestDetailCollection(var boxSetId)
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
        _cancelFocusRepairRetry()
        try { focusRecoveryTimer.stop() } catch(e1) {}
        _focusRecoveryScheduledKind = -1
    }

    function scheduleHomeFocusRepair(){
        if (!_alive || !pageActive || !focusRepairEnabled) return
        _homeFocusRepairLeft = Math.max(_homeFocusRepairLeft, 6)
        _queueFocusRecovery("repair")
    }
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
        // Si le focus a changé pendant une saturation réseau, la demande
        // urgente précédente ne doit pas recharger un rail quitté.
        var newlyFocused = latestByFolder[g]
        if (_latestPriorityReload.id && (!newlyFocused || String(newlyFocused.id || "") !== _latestPriorityReload.id))
            _latestPriorityReload = ({ id: "", reason: "" })
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
    property real _lastScrollY: 0; signal scrolled(real y, int direction); readonly property real latestEvictScreens: 2.2; readonly property int latestDataEvictDelayMs: 4800
    property real _latestViewportScanY: 0
    readonly property int latestViewportStepPx: 64
    function _updateLatestViewportScan(force) {
        if (!_vFlick) return
        var y = _vFlick.contentY
        if (force || Math.abs(y - _latestViewportScanY) >= latestViewportStepPx)
            _latestViewportScanY = y
    }
    Timer {
        id: latestProximityScrollTimer; interval: 90; repeat: false
        onTriggered: postergrid._maybeLoadLatestByVerticalProximity()
    }
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
        var viewTop = _vFlick.contentY; var viewBot = viewTop + _vFlick.height; var farPad = height * latestEvictScreens
        var source = latestByFolder, next = null, changed = false, now = Date.now()
        for (var i = 0; i < source.length; ++i) {
            var sec = latestRepeater.itemAt(i); var entry = source[i]
            if (!sec || !entry || entry._evicted || !entry.items || entry.items.length <= 0) continue
            var top = sec.y + sections.y; var bot = top + sec.height; var far = (bot < (viewTop - farPad)) || (top > (viewBot + farPad)); var pinned = (focusSection === 3 && currentLatestGroup === i) || _isLatestRestoreAnchoredGroup(i)
            if (!far || pinned || (now - Number(entry._loadedAt || 0)) < latestReloadGraceMs) continue
            if (!next) next = latestByFolder.slice(0)
            _rememberLatestRail(entry, now)
            var trimmed = MediaCatalog.shallowCloneObject(entry)
            trimmed.items = []
            trimmed._evicted = true
            trimmed._hadItems = true
            trimmed._evictedAt = now
            next[i] = trimmed
            HomeLatest.updatePendingEntry(postergrid, trimmed)
            sec.evicted = true
            // Laisser vivre l'entrée API et les autres partages de requêtes :
            // vider les DTO QML ne signifie pas qu'une requête doit être refaite.
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
            postergrid._updateLatestViewportScan(false)
            // Ne jamais bloquer le scroll : seul le travail réseau de proximité
            // est mutualisé, avec une cadence bornée à 90 ms.
            if (!latestProximityScrollTimer.running) latestProximityScrollTimer.start()
        }
        onMovementEnded: {
            postergrid._updateLatestViewportScan(true)
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
                        folderList.contentX = MediaRailLayout.nativeListClampX(
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
                        property bool cardPooled: false
                        ListView.onPooled: cardPooled = true
                        ListView.onReused: cardPooled = false
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
                                resumeList.contentX = MediaRailLayout.nativeListClampX( resumeList, targetX)
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
                            if (isFinite(x) && !isNaN(x)) resumeList.contentX = MediaRailLayout.nativeListClampX( resumeList, x)
                        }
                        var real = MediaRailLayout.homeRowRealDelegateGeometry( resumeList, selectedIndex)
                        if (real && hasViewportAnchor) {
                            var delta = real.viewportX - viewportX
                            if (Math.abs(delta) >= 0.5) {
                                resumeList.contentX = MediaRailLayout.nativeListClampX( resumeList, Number(resumeList.contentX || 0)
                                            + delta)
                            }
                            scheduleVisibilityRepair(2)
                            return true
                        }
                        if (real) {
                            var realTarget = postergrid._resumeRealTargetX( resumeList, selectedIndex)
                            if (isFinite(realTarget) && !isNaN(realTarget)) {
                                resumeList.contentX = MediaRailLayout.nativeListClampX( resumeList, realTarget)
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
                            var real = MediaRailLayout.homeRowRealDelegateGeometry( resumeList, idx)
                            if (!real) {
                                resumeList._positionIndexIntoView(idx)
                            } else {
                                var targetX = postergrid._resumeRealTargetX( resumeList, idx)
                                if (isFinite(targetX) && !isNaN(targetX) && Math.abs( Number(resumeList.contentX || 0)
                                            - targetX) >= 0.75) {
                                    resumeList.contentX = MediaRailLayout.nativeListClampX( resumeList, targetX)
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
                        readonly property bool portraitMovie: !MediaRailLayout.homeCardUsesLandscape(cardData, "resume")
                        width: postergrid.mediaCardDelegateWidthFor(cardData, "resume")
                        height: resumeSection.rowCardHeight; z: cardSelected ? 100 : 0
                        property var cardData: modelData; property var cardController: postergrid; property bool cardSelected: resumeList.activeFocus && focusSection === 1 && resumeList.selectedIndex === index; property bool cardShowProgress: true
                        property bool cardPreferBackdrop: !portraitMovie; property bool cardMusicFallback: false; property string cardFallbackKind: portraitMovie ? "movie" : "episode"; property string cardImagePolicy: "standard"
                        property bool cardAllowLoad: postergrid._homeImageLoadGate; property bool cardEnableMouseInput: true; property bool cardSuppressFocusTransform: false; property int cardTileW: postergrid.mediaCardTileWidthFor(cardData, "resume")
                        property int cardTileH: postergrid.mediaCardTileHeightFor(cardData, "resume"); property int cardTitleH: titleH; property int cardSidePad: postergrid.mediaCardSidePadFor(cardData, "resume"); property int cardTopPad: postergrid.mediaCardTopPadFor(cardData, "resume")
                        // Éviter les timers/marquees des cartes conservées dans le pool Qt 5.15.
                        property bool cardPooled: false
                        ListView.onPooled: cardPooled = true
                        ListView.onReused: cardPooled = false
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
                        property bool cardPooled: false
                        ListView.onPooled: cardPooled = true
                        ListView.onReused: cardPooled = false
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
                id: latestRepeater; model: latestRailModel
                delegate: Item {
                    id: latestSection
                    property int groupIndex: index; property var entry: latestByFolder[index]; property string sectionName: (entry && entry.name) ? entry.name : "Médias"; property var sectionItemsRaw: (entry && entry.items) ? entry.items : []
                    property var sectionItems: postergrid.capItems(sectionItemsRaw); readonly property var listObj: latestListLoader.item; property bool isMusicSection: MediaCatalog.isMusicLibraryFolder(entry)
                    readonly property string cardSectionKind: (entry && entry._pgSectionKind) ? String(entry._pgSectionKind) : (MediaCatalog.isSeriesLibraryFolder(entry) ? "latest-series" : "latest")
                    readonly property int cardH: postergrid.cardHPortrait; readonly property int viewportMarginY: postergrid.height; readonly property real absY: y + sections.y
                    readonly property bool nearViewport: ((absY + height) >= (postergrid._latestViewportScanY - viewportMarginY)) && (absY <= (postergrid._latestViewportScanY + _vFlick.height + viewportMarginY))
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
                    // T8: conserver les wrappers/hauteurs stables dans Column,
                    // mais ne créer le vrai ListView horizontal qu'à proximité.
                    // L'éviction existante (650 ms) évite les churns au scroll rapide.
                    // Chargement synchrone pour préserver focus D-Pad/restauration.
                    Loader {
                        id: latestListLoader
                        anchors.top: parent.top; anchors.topMargin: 45; anchors.left: parent.left
                        anchors.right: parent.right; anchors.leftMargin: viewLeftMargin; anchors.rightMargin: viewRightMargin
                        height: latestSection.cardH
                        asynchronous: false
                        active: latestSection.sectionModelActive
                        sourceComponent: Component {
                            ListView {
                                id: latestList
                                anchors.fill: parent
                                model: latestSection.sectionItems
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
                            MediaRailLayout.homeRowLogicalWidth(_modelArray(), latestSection.cardSectionKind, spacing, edgePad, width, postergrid.homeCardLayout)
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
                            property bool cardPooled: false
                            ListView.onPooled: cardPooled = true
                            ListView.onReused: cardPooled = false
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
