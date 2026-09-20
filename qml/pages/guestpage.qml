// guestpage.qml — rail des invités, optimisé pour le D-Pad Freebox.
// Le glide, le swap d’images A/B et le chargement borné sont conservés pour
// éviter les pics de décodage et les sauts de focus sur Révolution.

import QtQuick 2.15
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/SeasonUtils.js" as SeasonUtils
import QtGraphicalEffects 1.15

FocusScope {
    id: guestPage
    width: 1280
    height: cardHeight
    implicitHeight: cardHeight
    focus: true

    /* ==== Lifecycle safety ==== */
    property bool disposed: false
    readonly property bool parentEnabledGate: (!parent || parent.enabled !== false)
    readonly property bool runGate: !disposed && visible && parentEnabledGate

    onRunGateChanged: {
        if (!runGate) {
            focusLaterTimer.stop()
            focusTryTimer.stop()
            _cancelImageProbes("guest-inactive")
            _scheduleHqPoster("")
        }
    }

    /* ==== Perf tier ==== */
    property int perfTier: 0         // 0: Revolution, 1: comfy
    readonly property int  posterQuality: 85
    readonly property bool allowHover: (perfTier === 1)
    readonly property bool allowSmooth: true

    /* ==== Données / Contexte (injecté) ==== */
    property var    people: []
    property var    peopleAll: null
    property string serverUrl
    property string accessToken
    property string userId
    property string userName
    property string userImageTag
    // Sécurité publication : Image.source ne doit jamais recevoir de token en query string.
    readonly property bool publicBuildNoImageTokenInUrl: true
    property bool   allowImageTokenInUrl: false
    property var    fbx
    property var    host: null

    /* ==== Tweak 3: epoch anti-stale ==== */
    property int dataEpoch: 0
    property bool _applyingPeople: false

    function applyPeople(list, epoch) {
        if (!runGate) return
        var hasEpoch = (epoch !== undefined && epoch !== null && !isNaN(epoch))
        var e = hasEpoch ? (epoch | 0) : (dataEpoch | 0)

        if (hasEpoch && (e < (dataEpoch | 0))) return

        if (!hasEpoch || e !== (dataEpoch | 0)) {
            dataEpoch = e
            _hydratedFullOnce = false
            _lastModelFp = ""
        }

        _applyingPeople = true
        people = list || []
        _applyingPeople = false

        recomputeGuests()
    }

    function applyPeopleAll(list, epoch) {
        if (!runGate) return
        var hasEpoch = (epoch !== undefined && epoch !== null && !isNaN(epoch))
        var e = hasEpoch ? (epoch | 0) : (dataEpoch | 0)

        if (hasEpoch && (e < (dataEpoch | 0))) return

        if (!hasEpoch || e !== (dataEpoch | 0)) {
            dataEpoch = e
            _hydratedFullOnce = false
            _lastModelFp = ""
        }

        _applyingPeople = true
        peopleAll = list || null
        _applyingPeople = false

        recomputeGuests()
    }

    /* ==== HYDRATION ==== */
    property bool hydrateEnabled: true
    property int  hydrateInitialCount: 12
    property bool _hydratedFullOnce: false

    /* ==== Layout ==== */
    property int  cardWidth: 180
    property int  cardGap: 10
    property int  posterAspectW: 2
    property int  posterAspectH: 3
    readonly property int posterW: Math.round(cardWidth - cardGap)
    readonly property int posterH: Math.round(posterW * posterAspectH / posterAspectW)

    property int  nameH: 22
    property int  roleH: 19
    property int  vSpacing: 6
    property int  cardSpacing: 12

    // remonte légèrement les posters pour réduire l'espace sous le titre de section
    property int postersTopPullPx: 12

    // ✅ Zoom identique SeasonsBlock
    readonly property real focusScale: 1.14
    readonly property int  focusLiftPx: 6
    readonly property int  edgeNudgePx: Math.max(0, Math.ceil(posterW * (focusScale - 1) * 0.55))
    readonly property int  edgePad: Math.max(18, edgeNudgePx + 10)

    function topPadFor(h) {
        return Math.ceil(h * (focusScale - 1)) + focusLiftPx + Math.ceil(frameWidth) + 2
    }

    readonly property int effectiveTopPad: Math.max(0, topPadFor(posterH) - postersTopPullPx)

    // 4 items dans la Column => 3 spacings réels
    readonly property int cardHeight: effectiveTopPad + posterH + nameH + roleH + (vSpacing * 3)

    // Cadre
    readonly property real frameWidth: 2.0
    readonly property real frameInsetPx: 0.0
    readonly property real frameInnerEpsilon: 0.2
    function frameMargin() { return frameInsetPx + frameWidth / 2 + frameInnerEpsilon }

    // Images
    readonly property real posterOversample: 1.30
    readonly property int  reqPosterW: Math.round(posterW * posterOversample)
    readonly property int  reqPosterH: Math.round(posterH * posterOversample)
    readonly property real hqPosterOversample: 1.50
    readonly property int  hqPosterQuality: 90
    readonly property int  hqReqPosterW: Math.round(posterW * hqPosterOversample)
    readonly property int  hqReqPosterH: Math.round(posterH * hqPosterOversample)
    property string hqPosterTargetId: ""
    property string _hqPosterPendingId: ""

    property int lastFocusedIndex: 0
    property string lastFocusedKey: ""

    property var listModel: []
    readonly property bool hasContent: listModel && listModel.length > 0

    property bool keepLayoutWhenEmpty: true
    visible: keepLayoutWhenEmpty ? true : hasContent
    opacity: hasContent ? 1.0 : 0.0
    enabled: hasContent

    readonly property bool isScrolling: !!(castList && (castList.moving || castList.dragging || castList.flicking))
    readonly property bool allowCardAnims: runGate && !isScrolling

    signal actorActivated(var personObj)

    /* ==== Résolution ctx ==== */
    readonly property string resolvedServerUrl: {
        if (serverUrl && serverUrl.length) return serverUrl
        if (host) {
            if (host.serverUrl && host.serverUrl.length) return host.serverUrl
            if (host.shared && host.shared.serverUrl && host.shared.serverUrl.length) return host.shared.serverUrl
            if (host.settings && host.settings.serverUrl && host.settings.serverUrl.length) return host.settings.serverUrl
        }
        if (fbx && fbx.serverUrl && fbx.serverUrl.length) return fbx.serverUrl
        return ""
    }

    readonly property string resolvedAccessToken: {
        if (accessToken && accessToken.length) return accessToken
        if (host) {
            if (host.accessToken && host.accessToken.length) return host.accessToken
            if (host.shared && host.shared.accessToken && host.shared.accessToken.length) return host.shared.accessToken
}
        if (fbx && fbx.accessToken && fbx.accessToken.length) return fbx.accessToken
        return ""
    }

    readonly property bool ctxImgOk: !!(resolvedServerUrl && resolvedServerUrl.length > 0)

    property var requestFocusAbove: null
    property var requestFocusBelow: null

    /* ==== Refresh broadcast ==== */
    property int  refreshGen: 0
    property bool refreshBust: false
    property var imageFailureMemo: ({})
    property var imageReadyUrlMemo: ({})
    // Coalescence locale des probes 16x24 : plusieurs delegates représentant
    // la même personne partagent une seule requête.
    property var imageProbePending: ({})
    readonly property int imageMemoLimit: 128

    function _trimImageMemo(m) {
        var keys = Object.keys(m || ({}))
        if (keys.length <= imageMemoLimit) return m || ({})
        var out = ({})
        var start = Math.max(0, keys.length - imageMemoLimit)
        for (var i = start; i < keys.length; i++) out[keys[i]] = m[keys[i]]
        return out
    }

    function _cancelImageProbes(reason) {
        var pending = imageProbePending || ({})
        imageProbePending = ({})
        for (var k in pending) {
            if (!Object.prototype.hasOwnProperty.call(pending, k)) continue
            var e = pending[k]
            try {
                // Un cancel de navigation ne doit jamais devenir un faux
                // "portrait absent" si le bridge rappelle onError ensuite.
                if (e) { e.done = true; e.callbacks = [] }
                if (e && e.handle && typeof e.handle.cancel === "function")
                    e.handle.cancel(reason || "cancelled")
            } catch(e0) {}
        }
    }

    function retryAll(forceBust) {
        if (!runGate) return
        refreshBust = false
        if (forceBust === true) {
            _cancelImageProbes("guest-retry")
            imageFailureMemo = ({})
            imageReadyUrlMemo = ({})
        }
        refreshGen++
    }

    /* ==== Helpers ==== */
    function _focusKey(p){
        if (!p) return ""
        var pid = (p.PersonId || "")
        var id  = (p.Id || "")
        if (pid && pid.length) return "pid:" + pid
        if (id && id.length)   return "id:" + id
        return "nm:" + SeasonUtils.normName(p.Name || "")
    }

    function _indexFromKey(k){
        if (!k || !k.length || !listModel || !listModel.length) return -1
        for (var i = 0; i < listModel.length; i++) {
            if (_focusKey(listModel[i]) === k) return i
        }
        return -1
    }

    function normalizeGuests(src){
        return SeasonUtils.normalizeGuestUiList(src || [])
    }

    function _sliceGuests(list){
        if (!list || !list.length) return []
        return list.slice(0, Math.max(0, hydrateInitialCount | 0))
    }

    function _episodeListRaw(){
        if (people && people.length !== undefined && people.length > 0) return people
        if (host && host.guestStars && host.guestStars.length !== undefined && host.guestStars.length > 0) return host.guestStars
        return (people && people.length !== undefined) ? people : []
    }

    function _fullCandidateRaw(){
        if (peopleAll && peopleAll.length !== undefined && peopleAll.length > 0) return peopleAll
        if (!host) return null
        var b = host._guestStarsFull || host.guestStarsFull || host.guestStarsAll
        if (b && b.length !== undefined && b.length > 0) return b
        return null
    }

    function _fingerprint(listNorm){
        if (!listNorm || !listNorm.length) return ""
        var parts = []
        for (var i = 0; i < listNorm.length; i++) {
            var p = listNorm[i]
            parts.push((p.PersonId || "") + "|" + (p.Id || "") + "|" + (p.Name || "") + "|" + (p.Role || ""))
        }
        return parts.join("§")
    }

    property string _lastModelFp: ""

    function recomputeGuests(){
        if (!runGate) return

        var epRaw = _episodeListRaw()
        var fullCand = _fullCandidateRaw()

        var baseRaw
        if (_hydratedFullOnce && fullCand && fullCand.length) baseRaw = fullCand
        else if (epRaw && epRaw.length)                       baseRaw = epRaw
        else if (fullCand && fullCand.length)                 baseRaw = fullCand
        else                                                  baseRaw = epRaw

        var norm = normalizeGuests(baseRaw)

        var shown
        if (!hydrateEnabled) shown = norm
        else if (!_hydratedFullOnce) shown = _sliceGuests(norm)
        else shown = norm

        var fp = _fingerprint(shown)
        if (fp === _lastModelFp) return
        _lastModelFp = fp

        listModel = shown || []

        if (listModel && listModel.length) {
            var byKey = _indexFromKey(lastFocusedKey)
            if (byKey >= 0) lastFocusedIndex = byKey

            lastFocusedIndex = Math.max(0, Math.min(lastFocusedIndex, listModel.length - 1))
            if (castList) castList.currentIndex = lastFocusedIndex
        }

        retryAll(false)
    }

    function ensureFullNow(){
        if (_hydratedFullOnce) return
        _hydratedFullOnce = true
        recomputeGuests()
    }

    onActiveFocusChanged: {
        if (activeFocus) ensureFullNow()
    }

    onPeopleChanged: {
        if (_applyingPeople) return
        _hydratedFullOnce = false
        _lastModelFp = ""
        recomputeGuests()
    }

    onPeopleAllChanged: {
        if (_applyingPeople) return
        _hydratedFullOnce = false
        _lastModelFp = ""
        recomputeGuests()
    }

    Component.onCompleted: {
        recomputeGuests()
        if (activeFocus && hasContent)
            takeFocus(Math.min(lastFocusedIndex, (listModel ? listModel.length - 1 : 0)))
    }

    Component.onDestruction: {
        disposed = true
        _cancelImageProbes("guest-destroyed")
    }

    /* ==== URL helpers ==== */

    function _imgTagFor(p){
        return (p && p.ImageTags && p.ImageTags.Primary) ? p.ImageTags.Primary
             : (p && p.PrimaryImageTag ? p.PrimaryImageTag : "")
    }

    function _setImageSourceIfChanged(img, url) {
        if (!img) return;
        var s = String(url || "");
        if (String(img.source || "") !== s)
            img.source = s;
    }

    function _clearImageSourceIfNeeded(img) {
        if (!img) return;
        if (String(img.source || "") !== "")
            img.source = "";
    }

    function _personId(p){
        if (!p) return ""
        return (p.PersonId || p.Id || p.ItemId || "")
    }

    function _imageFailKey(p){
        if (!p) return ""
        var id = _personId(p)
        if (!id) return ""
        var tag = _imgTagFor(p)
        return id + "|" + (tag || "notag")
    }

    function _isImageMemoFailed(p){
        var k = _imageFailKey(p)
        return !!(k && imageFailureMemo && imageFailureMemo[k] === true)
    }

    function _markImageMemoFailed(p){
        var k = _imageFailKey(p)
        if (!k) return
        var m = imageFailureMemo || ({})
        if (m[k] === true) return
        m[k] = true
        guestPage.imageFailureMemo = _trimImageMemo(m)
    }

    function _imageRouteKey(p, usePersons){
        var k = _imageFailKey(p)
        if (!k) return ""
        return k + "|items"
    }

    function _imageReadyUrlFor(p, usePersons){
        var k = _imageRouteKey(p, usePersons)
        if (!k || !imageReadyUrlMemo) return ""
        return imageReadyUrlMemo[k] || ""
    }

    function _markImageReadyUrl(p, usePersons, url){
        var k = _imageRouteKey(p, usePersons)
        if (!k || !url) return
        var m = imageReadyUrlMemo || ({})
        if (m[k] === url) return
        m[k] = url
        guestPage.imageReadyUrlMemo = _trimImageMemo(m)
    }



    function imgUrl(person, w, h, mode, usePersons) {
        if (!person || !resolvedServerUrl) return ""
        var id = person.Id || person.ItemId || person.PersonId || ""
        if (!id) return ""
        var options = { format: "jpg", quality: posterQuality }
        if (mode === "max") { options.maxWidth = w; options.maxHeight = h }
        else if (mode === "fill") { options.fillWidth = w; options.fillHeight = h }
        return Jellyfin.itemImageUrl(resolvedServerUrl, id, "Primary", _imgTagFor(person), options)
    }

    function imgHqUrl(person, mode, usePersons) {
        if (!person || !resolvedServerUrl) return ""
        var id = person.Id || person.ItemId || person.PersonId || ""
        if (!id) return ""
        var options = { format: "jpg", quality: hqPosterQuality }
        if (mode === "max") { options.maxWidth = hqReqPosterW; options.maxHeight = hqReqPosterH }
        else if (mode === "fill") { options.fillWidth = hqReqPosterW; options.fillHeight = hqReqPosterH }
        return Jellyfin.itemImageUrl(resolvedServerUrl, id, "Primary", _imgTagFor(person), options)
    }

    function imgProbeUrl(person, usePersons) {
        if (!person || !resolvedServerUrl) return ""
        var tag = _imgTagFor(person)
        var id = person.Id || person.ItemId || person.PersonId || ""
        if (!tag || !id) return ""
        return Jellyfin.itemImageUrl(resolvedServerUrl, id, "Primary", tag, {
            format: "jpg", quality: 35, maxWidth: 16, maxHeight: 24
        })
    }

    function probePersonImage(person, usePersons, callback){
        if (!callback) return

        var key = _imageRouteKey(person, usePersons)
        if (!key || _isImageMemoFailed(person)) {
            callback(false)
            return
        }

        if (_imageReadyUrlFor(person, usePersons)) {
            callback(true)
            return
        }

        var u = imgProbeUrl(person, usePersons)
        if (!u) {
            _markImageMemoFailed(person)
            callback(false)
            return
        }

        var pending = imageProbePending || ({})
        var existing = pending[key]
        if (existing && existing.callbacks) {
            existing.callbacks.push(callback)
            return
        }

        if (!Jellyfin || typeof Jellyfin.probeResource !== "function") {
            _markImageMemoFailed(person)
            callback(false)
            return
        }

        var entry = { callbacks: [callback], handle: null, done: false }
        pending[key] = entry
        imageProbePending = pending

        function finish(ok) {
            if (entry.done) return
            entry.done = true
            var current = guestPage.imageProbePending || ({})
            if (current[key] === entry) delete current[key]
            guestPage.imageProbePending = current

            if (!ok) guestPage._markImageMemoFailed(person)

            var callbacks = entry.callbacks || []
            entry.callbacks = []
            for (var i = 0; i < callbacks.length; i++) {
                try { callbacks[i](ok === true) } catch(eCb) {}
            }
        }

        entry.handle = Jellyfin.probeResource(u, resolvedAccessToken,
            { accept: "image/*", metadataOnly: true, timeoutMs: 7000 },
            function(){ finish(true) },
            function(){ finish(false) }
        )
    }

    /* ==== Focus/scroll ==== */
    property int _pendingFocusIndex: -1

    Timer {
        id: focusLaterTimer
        interval: 0
        repeat: false
        onTriggered: {
            if (!guestPage.runGate) return

            var idx = guestPage._pendingFocusIndex >= 0 ? guestPage._pendingFocusIndex : guestPage.lastFocusedIndex
            var byKey = guestPage._indexFromKey(guestPage.lastFocusedKey)
            if (byKey >= 0) idx = byKey

            guestPage.focusGuest(idx)
        }
    }

    function takeFocus(preferIndex) {
        if (typeof preferIndex === "number") {
            lastFocusedIndex = Math.max(0, Math.min(preferIndex, (listModel ? listModel.length - 1 : 0)))
        } else {
            var byKey = _indexFromKey(lastFocusedKey)
            if (byKey >= 0) lastFocusedIndex = byKey
        }
        _pendingFocusIndex = lastFocusedIndex
        forceActiveFocus()
        if (runGate) focusLaterTimer.restart()
    }

    function forceFirstFocus()      { ensureFullNow(); takeFocus(0) }
    function forceFirstGuestFocus() { ensureFullNow(); takeFocus(0) }

    function restoreLastGuestFocus() {
        ensureFullNow()
        var byKey = _indexFromKey(lastFocusedKey)
        takeFocus(byKey >= 0 ? byKey : lastFocusedIndex)
    }

    // Snapshot minimal de focus utilisé par seasonpage lors de l'ouverture
    // d'une PersonPage. La clé est prioritaire sur l'index si l'ordre change.
    function focusSnapshot() {
        return {
            index: lastFocusedIndex | 0,
            key: String(lastFocusedKey || "")
        }
    }

    function applyFocusSnapshot(snapshot) {
        if (!snapshot) return

        var idx = (snapshot.index !== undefined && snapshot.index !== null)
                ? (Number(snapshot.index) | 0) : lastFocusedIndex
        var key = (snapshot.key !== undefined && snapshot.key !== null)
                ? String(snapshot.key) : ""

        if (key.length) lastFocusedKey = key

        if (listModel && listModel.length) {
            var byKey = _indexFromKey(lastFocusedKey)
            if (byKey >= 0) idx = byKey
            idx = Math.max(0, Math.min(idx, listModel.length - 1))
            lastFocusedIndex = idx
            if (castList) castList.currentIndex = idx
        } else {
            lastFocusedIndex = Math.max(0, idx)
        }
    }

    property int  _focusTryIndex: -1
    property int  _focusTryCount: 0
    property bool _didPositionOnce: false

    Timer {
        id: focusTryTimer
        interval: 16
        repeat: false
        onTriggered: {
            if (!guestPage.runGate) return
            if (!castList) return

            var idx = guestPage._focusTryIndex
            if (idx < 0) return

            if (guestPage.listModel && guestPage.listModel.length) {
                idx = Math.max(0, Math.min(idx, guestPage.listModel.length - 1))
            }

            var obj = castList.itemAtIndex(idx)
            if (obj && obj.forceActiveFocus) {
                castList.currentIndex = idx
                obj.forceActiveFocus()
                guestPage._focusTryIndex = -1
                return
            }

            if (!guestPage._didPositionOnce && castList.positionViewAtIndex) {
                guestPage._didPositionOnce = true
                castList.positionViewAtIndex(idx, ListView.Contain)
                focusTryTimer.restart()
                return
            }

            if (guestPage._focusTryCount >= 14) {
                guestPage._focusTryIndex = -1
                return
            }

            guestPage._focusTryCount++
            focusTryTimer.restart()
        }
    }

    function _focusGuestWhenReady(idx) {
        _focusTryIndex = idx
        _focusTryCount = 0
        _didPositionOnce = false
        if (runGate) focusTryTimer.restart()
    }

    function focusGuest(i) {
        if (!listModel || !listModel.length) return
        var idx = Math.max(0, Math.min(i, listModel.length - 1))
        lastFocusedIndex = idx
        castList.currentIndex = idx
        _focusGuestWhenReady(idx)
    }

    function ensureVisible(idx) {
        if (!castList || castList.count <= 0) return
        castList.currentIndex = Math.max(0, Math.min(idx, castList.count - 1))
    }

    function _currentHqGuestId(){
        if (!castList || !castList.activeFocus || !listModel || castList.currentIndex < 0 || castList.currentIndex >= listModel.length)
            return ""
        return _personId(listModel[castList.currentIndex])
    }
    function _scheduleHqPoster(id){
        id = id ? String(id) : ""
        hqPosterTargetId = ""
        _hqPosterPendingId = id
        hqPosterTimer.stop()
        if (id.length && runGate && !isScrolling)
            hqPosterTimer.restart()
    }
    Timer {
        id: hqPosterTimer
        interval: 300
        repeat: false
        onTriggered: {
            var id = guestPage._currentHqGuestId()
            if (id.length && id === guestPage._hqPosterPendingId && !guestPage.isScrolling)
                guestPage.hqPosterTargetId = id
        }
    }

    /* ==== UI ==== */
    ListView {
        id: castList
        anchors.fill: parent
        clip: true

        orientation: ListView.Horizontal
        spacing: cardSpacing
        model: guestPage.listModel || []

        snapMode: ListView.NoSnap
        highlightFollowsCurrentItem: true
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: guestPage.edgePad
        preferredHighlightEnd: Math.max(0, width - guestPage.cardWidth - guestPage.edgePad)
        highlightMoveDuration: guestPage.runGate ? 170 : 0
        highlightMoveVelocity: -1
        highlight: Item { width: guestPage.cardWidth; height: guestPage.cardHeight; visible: false }

        interactive: guestPage.runGate && (contentWidth > width + 2)
        boundsBehavior: Flickable.StopAtBounds
        flickDeceleration: 5000
        maximumFlickVelocity: 3200

        reuseItems: true

        header: Item { width: guestPage.edgePad; height: 1 }
        footer: Item { width: guestPage.edgePad; height: 1 }

        onEnabledChanged: {
            if (!enabled) {
                if (castList.cancelFlick) castList.cancelFlick()
                if (castList.returnToBounds) castList.returnToBounds()
            }
        }

        onVisibleChanged: {
            if (!visible) {
                if (castList.cancelFlick) castList.cancelFlick()
                if (castList.returnToBounds) castList.returnToBounds()
            }
        }

        readonly property int dynCacheBuffer: {
            var n = (guestPage.listModel && guestPage.listModel.length) ? guestPage.listModel.length : 0
            var base = (guestPage.perfTier === 0) ? 140 : 360
            var bonus = (n <= 10) ? 80 : ((n <= 25) ? 40 : 0)
            var maxv = (guestPage.perfTier === 0) ? 240 : 620
            return Math.max(80, Math.min(maxv, base + bonus))
        }
        cacheBuffer: dynCacheBuffer

        Keys.onPressed: {
            if (event.key === Qt.Key_Up) {
                if (guestPage.requestFocusAbove) guestPage.requestFocusAbove()
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                if (guestPage.requestFocusBelow) guestPage.requestFocusBelow()
                event.accepted = true
            }
        }

        delegate: FocusScope {
            id: card
            width: guestPage.cardWidth
            height: guestPage.cardHeight
            z: activeFocus ? 1000 : 0
            focus: ListView.isCurrentItem

            property var guest: modelData
            property bool showFallback: true

            readonly property bool isHot: activeFocus || (ma && ma.containsMouse)
            readonly property bool inView: {
                var v = ListView.view
                if (!v) return true
                var cx = v.contentX
                var w = v.width
                var p = Math.max(guestPage.cardWidth * 2, 240)
                return (x + width) > (cx - p) && x < (cx + w + p)
            }

            property bool frontIsA: true
            property int  _stage: 0
            property bool _usePersons: false
            property bool _triedAltRoute: false
            property int  _probeSeq: 0
            property bool _probingImage: false

            function _backImg(){ return frontIsA ? imgB : imgA }
            function _anyReady(){ return (imgA.status === Image.Ready) || (imgB.status === Image.Ready) }
            function _p(){ return guest || null }

            function _handleImgStatus(imgObj){
                if (!imgObj || imgObj !== _backImg()) return

                if (imgObj.status === Image.Ready) {
                    frontIsA = !frontIsA
                    showFallback = false
                    _stage = 0
                    _triedAltRoute = false
                    if (card.activeFocus)
                        guestPage._scheduleHqPoster(guestPage._personId(card._p()))
                } else if (imgObj.status === Image.Error) {
                    _retryNext()
                }
            }

            function refresh(forceBust){
                if (!guestPage.runGate) return

                var p = _p()
                var id = guestPage._personId(p)

                _probeSeq++
                _probingImage = false

                if (!id || guestPage._isImageMemoFailed(p)) {
                    showFallback = true
                    guestPage._clearImageSourceIfNeeded(imgA)
                    guestPage._clearImageSourceIfNeeded(imgB)
                    _stage = 0
                    _triedAltRoute = false
                    return
                }

                if (!inView) {
                    if (!_anyReady()) {
                        showFallback = true
                        guestPage._clearImageSourceIfNeeded(imgA)
                        guestPage._clearImageSourceIfNeeded(imgB)
                        _stage = 0
                    } else {
                        showFallback = false
                        guestPage._clearImageSourceIfNeeded(_backImg())
                    }
                    return
                }

                if (!guestPage.ctxImgOk) {
                    showFallback = !_anyReady()
                    _stage = 0
                    guestPage._clearImageSourceIfNeeded(_backImg())
                    return
                }

                _usePersons = false
                _triedAltRoute = true

                _stage = 0
                _tryCurrentImageRoute()
                showFallback = !_anyReady()
            }

            function _tryCurrentImageRoute(){
                if (!guestPage.runGate) return

                var p = _p()
                if (!p || !guestPage.ctxImgOk || !guestPage._personId(p)) {
                    showFallback = !_anyReady()
                    return
                }

                var cachedUrl = guestPage._imageReadyUrlFor(p, _usePersons)
                if (cachedUrl && cachedUrl.length > 0) {
                    _probingImage = false
                    guestPage._setImageSourceIfChanged(_backImg(), cachedUrl)
                    showFallback = !_anyReady()
                    return
                }

                var seq = ++_probeSeq
                var routeUsePersons = _usePersons
                var expectedKey = guestPage._imageFailKey(p)

                _probingImage = true
                guestPage._clearImageSourceIfNeeded(_backImg())
                showFallback = !_anyReady()

                guestPage.probePersonImage(p, routeUsePersons, function(ok){
                    if (!guestPage.runGate) return
                    if (seq !== card._probeSeq) return
                    if (expectedKey !== guestPage._imageFailKey(card._p())) return

                    card._probingImage = false

                    if (ok) {
                        var fullUrl = guestPage.imgUrl(card._p(), guestPage.reqPosterW, guestPage.reqPosterH, "max", routeUsePersons)
                        if (fullUrl && fullUrl.length > 0) {
                            guestPage._markImageReadyUrl(card._p(), routeUsePersons, fullUrl)
                            guestPage._setImageSourceIfChanged(card._backImg(), fullUrl)
                        } else {
                            card._retryNext()
                        }
                    } else {
                        card._retryNext()
                    }
                })
            }

            function _retryNext(){
                if (!guestPage.runGate) return

                var p = _p()
                if (!p || !guestPage.ctxImgOk || !guestPage._personId(p)) {
                    showFallback = !_anyReady()
                    return
                }

                // Une seule route alternative suffit. Les anciennes variantes
                // max -> fill -> raw + &_b=1/_b=2 créaient jusqu'à 6 erreurs Qt
                // pour une personne sans image. La nouvelle version pré-teste
                // l'image en XHR avec header token avant de la donner à Image.source,
                // ce qui évite même la première erreur QML sur portrait absent.
                guestPage._markImageMemoFailed(p)
                guestPage._clearImageSourceIfNeeded(_backImg())
                showFallback = !_anyReady()
            }

            Connections {
                target: guestPage
                function onRefreshGenChanged() {
                    if (!guestPage.runGate) return
                    if (card.inView) card.refresh(guestPage.refreshBust === true)
                    else if (!card._anyReady()) {
                        card.showFallback = true
                        guestPage._clearImageSourceIfNeeded(imgA)
                        guestPage._clearImageSourceIfNeeded(imgB)
                        card._stage = 0
                    }
                }
            }

            Timer {
                id: deferRefresh
                interval: 0
                repeat: false
                onTriggered: {
                    if (!guestPage.runGate) return
                    card.refresh(false)
                }
            }

            onGuestChanged: {
                showFallback = true
                frontIsA = true
                _stage = 0
                _triedAltRoute = false
                _usePersons = false

                _probeSeq++
                _probingImage = false
                guestPage._clearImageSourceIfNeeded(imgA)
                guestPage._clearImageSourceIfNeeded(imgB)

                if (inView && guestPage.ctxImgOk && guestPage._personId(_p()))
                    deferRefresh.restart()
            }

            onInViewChanged: {
                if (inView && guestPage.ctxImgOk && !_anyReady() && guestPage._personId(_p()) && !guestPage._isImageMemoFailed(_p()))
                    refresh(false)
            }

            function _setCurrentAndFocus() {
                castList.currentIndex = index
                guestPage.lastFocusedIndex = index
                guestPage.lastFocusedKey = guestPage._focusKey(card.guest)
                card.forceActiveFocus()
            }

            Keys.onPressed: {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Select) {
                    if (guest) guestPage.actorActivated(guest)
                    event.accepted = true

                } else if (event.key === Qt.Key_Left) {
                    if (index > 0) guestPage.focusGuest(index - 1)
                    event.accepted = true

                } else if (event.key === Qt.Key_Right) {
                    if (guestPage.listModel && index < guestPage.listModel.length - 1) guestPage.focusGuest(index + 1)
                    event.accepted = true

                } else if (event.key === Qt.Key_Up) {
                    if (guestPage.requestFocusAbove) {
                        guestPage.requestFocusAbove()
                        event.accepted = true
                    }

                } else if (event.key === Qt.Key_Down) {
                    if (guestPage.requestFocusBelow) {
                        guestPage.requestFocusBelow()
                        event.accepted = true
                    }
                }
            }

            MouseArea {
                id: ma
                anchors.fill: parent
                hoverEnabled: guestPage.allowHover
                onClicked: {
                    card._setCurrentAndFocus()
                    if (card.guest) guestPage.actorActivated(card.guest)
                }
                onEntered: { card._setCurrentAndFocus() }
            }

            /* ==== Zoom identique SeasonsBlock ==== */
            SequentialAnimation {
                id: scaleIn
                running: false
                PropertyAnimation {
                    target: posterCard
                    property: "scale"
                    to: guestPage.focusScale
                    duration: 120
                    easing.type: Easing.OutCubic
                }
                PropertyAnimation {
                    target: posterCard
                    property: "scale"
                    to: (guestPage.focusScale - 0.02)
                    duration: 90
                    easing.type: Easing.OutCubic
                }
            }

            NumberAnimation {
                id: scaleOut
                target: posterCard
                property: "scale"
                to: 1.0
                duration: 130
                easing.type: Easing.OutCubic
                running: false
            }

            function _stopAllZoomHard() {
                scaleIn.stop()
                scaleOut.stop()
                if (posterCard) posterCard.scale = 1.0
            }

            Connections {
                target: guestPage
                function onRunGateChanged() {
                    if (!guestPage.runGate) _stopAllZoomHard()
                }
                function onIsScrollingChanged() {
                    if (guestPage.isScrolling && posterCard) posterCard._applyScaleImmediate()
                }
            }

            onActiveFocusChanged: {
                if (!guestPage.runGate) {
                    _stopAllZoomHard()
                    return
                }

                if (activeFocus) {
                    guestPage.ensureFullNow()
                    guestPage.lastFocusedIndex = index
                    guestPage._scheduleHqPoster(guestPage._personId(card._p()))
                    guestPage.lastFocusedKey = guestPage._focusKey(card.guest)

                    if (guestPage.ctxImgOk && !_anyReady() && guestPage._personId(_p()))
                        refresh(false)

                    if (!posterCard.allowLocalAnims) posterCard._applyScaleImmediate()
                    else {
                        scaleOut.stop()
                        scaleIn.start()
                    }

                } else {
                    if (guestPage._hqPosterPendingId === guestPage._personId(card._p())
                            || guestPage.hqPosterTargetId === guestPage._personId(card._p()))
                        guestPage._scheduleHqPoster("")
                    if (!posterCard.allowLocalAnims) posterCard._applyScaleImmediate()
                    else {
                        scaleIn.stop()
                        scaleOut.start()
                    }
                }
            }

            Column {
                width: parent.width
                height: parent.height
                spacing: guestPage.vSpacing

                Item {
                    width: 1
                    height: guestPage.effectiveTopPad
                }

                Item {
                    id: posterCard
                    width: parent.width
                    height: guestPage.posterH
                    transformOrigin: Item.Bottom
                    scale: 1.0

                    readonly property bool allowLocalAnims: guestPage.allowCardAnims && castList.activeFocus
                    readonly property bool selected: card.activeFocus
                    readonly property bool isFirst: index === 0
                    readonly property bool isLast: (castList.count > 0) ? (index === castList.count - 1) : false

                    transform: Translate {
                        x: (posterCard.selected && castList.activeFocus)
                           ? (posterCard.isFirst ? guestPage.edgeNudgePx : (posterCard.isLast ? -guestPage.edgeNudgePx : 0))
                           : 0
                        y: (posterCard.selected && castList.activeFocus) ? -guestPage.focusLiftPx : 0

                        Behavior on x {
                            enabled: posterCard.allowLocalAnims
                            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                        }
                        Behavior on y {
                            enabled: posterCard.allowLocalAnims
                            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                        }
                    }

                    function _applyScaleImmediate() {
                        scaleIn.stop()
                        scaleOut.stop()
                        posterCard.scale = (posterCard.selected && castList.activeFocus) ? (guestPage.focusScale - 0.02) : 1.0
                    }

                    onVisibleChanged: {
                        if (visible) _applyScaleImmediate()
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: "#ffffff"
                        opacity: (posterCard.selected && guestPage.allowCardAnims) ? 0.05 : 0.0
                        visible: opacity > 0.0
                        Behavior on opacity {
                            enabled: posterCard.allowLocalAnims
                            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                        }
                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: Math.round(parent.height * 0.22)
                        opacity: (posterCard.selected && guestPage.allowCardAnims) ? 1.0 : 0.0
                        visible: opacity > 0.0
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: "#00000000" }
                            GradientStop { position: 1.0; color: "#22000000" }
                        }
                        Behavior on opacity {
                            enabled: posterCard.allowLocalAnims
                            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                        }
                    }

                    Item {
                        id: thumbBox
                        anchors.fill: parent
                        clip: true

                        Item {
                            id: paintLayer
                            anchors.fill: parent
                            y: (posterCard.selected && posterCard.allowLocalAnims) ? -3 : 0
                            Behavior on y {
                                enabled: posterCard.allowLocalAnims
                                NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                            }

                            Item {
                                id: imgLayer
                                anchors.fill: parent
                                visible: !card.showFallback

                                Item {
                                    id: imgContent
                                    anchors.fill: parent
                                    transformOrigin: Item.Center

                                    Image {
                                        id: imgA
                                        anchors.fill: parent
                                        visible: card.frontIsA
                                        fillMode: Image.PreserveAspectCrop
                                        cache: false
                                        asynchronous: true
                                        mipmap: false
                                        smooth: guestPage.allowSmooth && !guestPage.isScrolling
                                        onStatusChanged: card._handleImgStatus(imgA)
                                    }

                                    Image {
                                        id: imgB
                                        anchors.fill: parent
                                        visible: !card.frontIsA
                                        fillMode: Image.PreserveAspectCrop
                                        cache: false
                                        asynchronous: true
                                        mipmap: false
                                        smooth: guestPage.allowSmooth && !guestPage.isScrolling
                                        onStatusChanged: card._handleImgStatus(imgB)
                                    }

                                    Image {
                                        id: imgHq
                                        anchors.fill: parent
                                        fillMode: Image.PreserveAspectCrop
                                        cache: false
                                        asynchronous: true
                                        mipmap: false
                                        smooth: guestPage.allowSmooth && !guestPage.isScrolling
                                        source: {
                                            var id = guestPage._personId(card._p())
                                            if (!guestPage.runGate || !card.activeFocus || guestPage.isScrolling || !card._anyReady() || !id.length || guestPage.hqPosterTargetId !== id)
                                                return ""
                                            return guestPage.imgHqUrl(card._p(), "max", card._usePersons)
                                        }
                                        visible: source !== "" && status === Image.Ready
                                        opacity: visible ? 1.0 : 0.0
                                        Behavior on opacity { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                                    }

                                    Component.onCompleted: {
                                        if (guestPage.runGate) card.refresh(false)
                                    }
                                }
                            }

                            Item {
                                id: fbLayer
                                anchors.fill: parent
                                visible: card.showFallback

                                Rectangle {
                                    anchors.fill: parent
                                    color: "#25282E"
                                }

                                Item {
                                    id: avatarContent
                                    anchors.fill: parent
                                    transformOrigin: Item.Center

                                    Rectangle {
                                        width: parent.width * 0.36
                                        height: width
                                        radius: width / 2
                                        color: "#9aa3bd"
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        y: parent.height * 0.18
                                    }

                                    Rectangle {
                                        width: parent.width * 0.62
                                        height: parent.height * 0.42
                                        radius: Math.min(width, height) * 0.22
                                        color: "#7d86a4"
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        y: (parent.height * 0.18) + (parent.width * 0.36) + 6
                                    }
                                }
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 0
                            radius: 0
                            color: "transparent"
                            border.color: "#FFFFFF"
                            border.width: guestPage.frameWidth
                            antialiasing: false
                            opacity: (posterCard.selected && castList.activeFocus) ? 1.0 : 0.0
                            Behavior on opacity {
                                enabled: posterCard.allowLocalAnims
                                NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
                            }
                            z: 2
                        }
                    }
                }

                Item {
                    id: actorNameViewport
                    width: parent.width
                    height: guestPage.nameH
                    clip: true

                    property string lineText: (card.guest && card.guest.Name) ? card.guest.Name : ""
                    property real _mx: 0
                    readonly property real overflow: Math.max(0, Math.ceil(actorNameText.implicitWidth - width + 12))
                    readonly property bool marqueeOn: guestPage.runGate && card.activeFocus && overflow > 6
                    property bool marqueeMoving: false
                    readonly property bool atStart: _mx >= -1
                    readonly property bool atEnd: overflow <= 1 || _mx <= -(overflow - 1)

                    function restartMarquee() {
                        actorNameMarquee.stop()
                        marqueeMoving = false
                        _mx = 0
                        if (marqueeOn)
                            actorNameMarquee.restart()
                    }

                    onMarqueeOnChanged: restartMarquee()
                    onLineTextChanged: restartMarquee()
                    onWidthChanged: restartMarquee()
                    onOverflowChanged: restartMarquee()

                    Item {
                        id: actorNameSourceViewport
                        anchors.fill: parent
                        clip: true

                        Text { textFormat: Text.PlainText;
                            id: actorNameText
                            x: actorNameViewport._mx
                            width: actorNameViewport.marqueeOn ? Math.ceil(implicitWidth) : actorNameViewport.width
                            height: parent.height
                            verticalAlignment: Text.AlignVCenter
                            text: actorNameViewport.lineText
                            color: card.activeFocus ? "#ffffff" : "#e7ecff"
                            font.pixelSize: 15
                            font.bold: card.activeFocus
                            wrapMode: Text.NoWrap
                            elide: actorNameViewport.marqueeOn ? Text.ElideNone : Text.ElideRight
                            onPaintedWidthChanged: actorNameViewport.restartMarquee()
                        }
                    }

                    ShaderEffectSource {
                        id: actorNameTexture
                        sourceItem: actorNameSourceViewport
                        hideSource: actorNameViewport.marqueeMoving
                        live: actorNameViewport.marqueeMoving
                        recursive: false
                        visible: false
                    }

                    Item {
                        id: actorNameFadeMask
                        anchors.fill: actorNameSourceViewport
                        visible: false

                        Rectangle {
                            anchors.fill: parent
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.00; color: actorNameViewport.atStart ? "#ff000000" : "#00000000" }
                                GradientStop { position: 0.10; color: "#ff000000" }
                                GradientStop { position: 0.90; color: "#ff000000" }
                                GradientStop { position: 1.00; color: actorNameViewport.atEnd ? "#ff000000" : "#00000000" }
                            }
                        }
                    }

                    OpacityMask {
                        id: actorNameMasked
                        anchors.fill: actorNameSourceViewport
                        source: actorNameTexture
                        maskSource: actorNameFadeMask
                        visible: actorNameViewport.marqueeMoving
                        cached: false
                    }

                    SequentialAnimation {
                        id: actorNameMarquee
                        running: actorNameViewport.marqueeOn
                        loops: Animation.Infinite

                        PauseAnimation { duration: 650 }
                        ScriptAction { script: { actorNameViewport.marqueeMoving = true } }

                        NumberAnimation {
                            target: actorNameViewport
                            property: "_mx"
                            from: 0
                            to: -actorNameViewport.overflow
                            duration: Math.max(1800, Math.min(12000, Math.round(actorNameViewport.overflow * 38)))
                            easing.type: Easing.Linear
                        }

                        ScriptAction { script: { actorNameViewport._mx = 0; actorNameViewport.marqueeMoving = false } }
                        PauseAnimation { duration: 900 }
                        PauseAnimation { duration: 260 }
                    }
                }

                Item {
                    id: characterNameViewport
                    width: parent.width
                    height: guestPage.roleH
                    clip: true

                    property string lineText: (card.guest && card.guest.Role) ? card.guest.Role : ""
                    property real _mx: 0
                    readonly property real overflow: Math.max(0, Math.ceil(characterNameText.implicitWidth - width + 12))
                    readonly property bool marqueeOn: guestPage.runGate && card.activeFocus && overflow > 6
                    property bool marqueeMoving: false
                    readonly property bool atStart: _mx >= -1
                    readonly property bool atEnd: overflow <= 1 || _mx <= -(overflow - 1)

                    function restartMarquee() {
                        characterNameMarquee.stop()
                        marqueeMoving = false
                        _mx = 0
                        if (marqueeOn)
                            characterNameMarquee.restart()
                    }

                    onMarqueeOnChanged: restartMarquee()
                    onLineTextChanged: restartMarquee()
                    onWidthChanged: restartMarquee()
                    onOverflowChanged: restartMarquee()

                    Item {
                        id: characterNameSourceViewport
                        anchors.fill: parent
                        clip: true

                        Text { textFormat: Text.PlainText;
                            id: characterNameText
                            x: characterNameViewport._mx
                            width: characterNameViewport.marqueeOn ? Math.ceil(implicitWidth) : characterNameViewport.width
                            height: parent.height
                            verticalAlignment: Text.AlignVCenter
                            text: characterNameViewport.lineText
                            color: card.activeFocus ? "#cfd6ff" : "#aeb7d7"
                            font.pixelSize: 13
                            font.bold: card.activeFocus
                            wrapMode: Text.NoWrap
                            elide: characterNameViewport.marqueeOn ? Text.ElideNone : Text.ElideRight
                            onPaintedWidthChanged: characterNameViewport.restartMarquee()
                        }
                    }

                    ShaderEffectSource {
                        id: characterNameTexture
                        sourceItem: characterNameSourceViewport
                        hideSource: characterNameViewport.marqueeMoving
                        live: characterNameViewport.marqueeMoving
                        recursive: false
                        visible: false
                    }

                    Item {
                        id: characterNameFadeMask
                        anchors.fill: characterNameSourceViewport
                        visible: false

                        Rectangle {
                            anchors.fill: parent
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.00; color: characterNameViewport.atStart ? "#ff000000" : "#00000000" }
                                GradientStop { position: 0.10; color: "#ff000000" }
                                GradientStop { position: 0.90; color: "#ff000000" }
                                GradientStop { position: 1.00; color: characterNameViewport.atEnd ? "#ff000000" : "#00000000" }
                            }
                        }
                    }

                    OpacityMask {
                        id: characterNameMasked
                        anchors.fill: characterNameSourceViewport
                        source: characterNameTexture
                        maskSource: characterNameFadeMask
                        visible: characterNameViewport.marqueeMoving
                        cached: false
                    }

                    SequentialAnimation {
                        id: characterNameMarquee
                        running: characterNameViewport.marqueeOn
                        loops: Animation.Infinite

                        PauseAnimation { duration: 650 }
                        ScriptAction { script: { characterNameViewport.marqueeMoving = true } }

                        NumberAnimation {
                            target: characterNameViewport
                            property: "_mx"
                            from: 0
                            to: -characterNameViewport.overflow
                            duration: Math.max(1800, Math.min(12000, Math.round(characterNameViewport.overflow * 38)))
                            easing.type: Easing.Linear
                        }

                        ScriptAction { script: { characterNameViewport._mx = 0; characterNameViewport.marqueeMoving = false } }
                        PauseAnimation { duration: 900 }
                        PauseAnimation { duration: 260 }
                    }
                }
            }
        }
    }

    function _initFocusIfNeeded(){
        if (!runGate || !hasContent) return
        if (castList) castList.currentIndex = Math.max(0, Math.min(lastFocusedIndex, listModel.length - 1))
    }

    onHasContentChanged: {
        if (hasContent) _initFocusIfNeeded()
    }
}