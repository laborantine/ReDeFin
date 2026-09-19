import QtQuick 2.15
import "../js/jellyfinBridge.js" as Jellyfin
import "../js/MediaCatalog.js" as MediaCatalog

// Fond dynamique de l'accueil : sélection de l'image, double buffer et temporisation.
Item {
    id: backdropLayer

    property var host: null
    property int fadeMs: 180
    property int debounceMs: 80
    property real targetOpacity: 0.90
    property string _pendingUrl: ""
    property string _visibleUrl: ""
    property string _loadingUrl: ""
    property bool _showB: false
    property int _pendingSection: -99
    property int _pendingFolderIndex: -1
    property int _pendingResumeIndex: -1
    property int _pendingNextUpIndex: -1
    property int _pendingLatestGroup: -1
    property int _pendingLatestIndex: -1
    property var _failureMemo: ({})
    readonly property int failureMemoLimit: 128

    function _rememberFailure(url) {
        if (!url) return
        var memo = _failureMemo || ({})
        if (memo[url] === true) return
        memo[url] = true
        _failureMemo = MediaCatalog.trimObjectMemo(memo, failureMemoLimit)
    }

    function _backdropUrlForItem(item) {
        if (!host || !item || !host.serverUrl) return ""
        var spec = MediaCatalog.posterGridBackdropImageSpec(item)
        if (!spec.id || !spec.type || !spec.tag) return ""
        return Jellyfin.itemImageUrl(host.serverUrl, spec.id, spec.type, spec.tag, {
            fillWidth: Math.max(1, Math.min(host.width || 1280, host.bgCapW)),
            fillHeight: Math.max(1, Math.min(host.height || 720, host.bgCapH)),
            quality: host.bgQuality,
            blur: MediaCatalog.clampBlur(host.bgBlur)
        })
    }

    function currentUrl() {
        if (!host || host.focusSection === 0) return ""
        var item = null
        if (host.focusSection === 1) {
            var resumeItems = host.cappedResumeItems
            if (host.currentResumeIndex >= 0 && host.currentResumeIndex < resumeItems.length)
                item = resumeItems[host.currentResumeIndex]
        } else if (host.focusSection === 2) {
            var nextUpItems = host.cappedNextUpItems
            if (host.currentNextUpIndex >= 0 && host.currentNextUpIndex < nextUpItems.length)
                item = nextUpItems[host.currentNextUpIndex]
        } else if (host.focusSection === 3) {
            item = host.currentLatestItem()
        }
        return item ? _backdropUrlForItem(item) : ""
    }

    function scheduleUpdate() {
        if (!host) return
        if (host.suspendVisualTextures) {
            scheduleTimer.stop()
            releaseTextures()
            return
        }
        if (host.focusSection === 0) {
            scheduleTimer.stop()
            clearForLibraryFocus()
            return
        }
        scheduleTimer.interval = (_visibleUrl === "" && !host.isScrollingEff) ? 180 : 750
        scheduleTimer.restart()
    }

    function update(fullUrl) {
        if (!host) return
        fullUrl = fullUrl || ""
        if (host.focusSection === 0) {
            clearForLibraryFocus()
            return
        }
        _pendingUrl = fullUrl
        _pendingSection = host.focusSection
        _pendingFolderIndex = host.currentFolderIndex
        _pendingResumeIndex = host.currentResumeIndex
        _pendingNextUpIndex = host.currentNextUpIndex
        _pendingLatestGroup = host.currentLatestGroup
        _pendingLatestIndex = host.latestIndexFor(host.currentLatestGroup)
        if (fullUrl === _visibleUrl || fullUrl === _loadingUrl) return
        debounce.restart()
    }

    function _focusStillOnPending() {
        if (!host || _pendingSection !== host.focusSection) return false
        if (_pendingSection === 0) return _pendingFolderIndex === host.currentFolderIndex
        if (_pendingSection === 1) return _pendingResumeIndex === host.currentResumeIndex
        if (_pendingSection === 2) return _pendingNextUpIndex === host.currentNextUpIndex
        if (_pendingSection === 3) {
            return _pendingLatestGroup === host.currentLatestGroup
                    && _pendingLatestIndex === host.latestIndexFor(host.currentLatestGroup)
        }
        return true
    }

    function _loadingImage() { return _showB ? bgA : bgB }

    function _clearAll() {
        _visibleUrl = ""
        _loadingUrl = ""
        _showB = false
        if (String(bgA.source || "") !== "") bgA.source = ""
        if (String(bgB.source || "") !== "") bgB.source = ""
    }

    function releaseTextures() {
        scheduleTimer.stop()
        debounce.stop()
        _pendingUrl = ""
        _pendingSection = -99
        _clearAll()
    }

    function clearForLibraryFocus() {
        scheduleTimer.stop()
        debounce.stop()
        _pendingUrl = ""
        _pendingSection = 0
        _pendingFolderIndex = host ? host.currentFolderIndex : -1
        _clearAll()
    }

    function _commit() {
        if (!_focusStillOnPending()) {
            update(currentUrl())
            return
        }
        var fullUrl = _pendingUrl || ""
        if (!fullUrl) {
            _clearAll()
            return
        }
        if (_failureMemo && _failureMemo[fullUrl]) {
            _clearAll()
            return
        }
        if (fullUrl === _visibleUrl || fullUrl === _loadingUrl) return
        _loadingUrl = fullUrl
        var image = _loadingImage()
        if (String(image.source || "") !== String(fullUrl || "")) image.source = fullUrl
        else if (image.status === Image.Ready) {
            if (_showB) _promoteA()
            else _promoteB()
        }
    }

    function _promoteA() {
        var source = String(bgA.source || "")
        if (!source || source !== _loadingUrl) return
        _visibleUrl = source
        _loadingUrl = ""
        _showB = false
    }

    function _promoteB() {
        var source = String(bgB.source || "")
        if (!source || source !== _loadingUrl) return
        _visibleUrl = source
        _loadingUrl = ""
        _showB = true
    }

    function _failLoading(source) {
        source = String(source || "")
        if (!source || source !== _loadingUrl) return
        _rememberFailure(source)
        _loadingUrl = ""
        if (!_visibleUrl) _clearAll()
    }

    Timer {
        id: scheduleTimer
        interval: 750
        repeat: false
        onTriggered: {
            if (!backdropLayer.host || !backdropLayer.host.pageActive) return
            if (backdropLayer.host.isScrollingEff) {
                interval = 750
                restart()
                return
            }
            backdropLayer.update(backdropLayer.currentUrl())
        }
    }

    Timer {
        id: debounce
        interval: backdropLayer.debounceMs
        repeat: false
        onTriggered: backdropLayer._commit()
    }

    Image {
        id: bgA
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        mipmap: false
        smooth: false
        opacity: (!backdropLayer._showB && status === Image.Ready && backdropLayer._visibleUrl !== "")
                 ? backdropLayer.targetOpacity : 0.0
        Behavior on opacity {
            enabled: !!backdropLayer.host && backdropLayer.host.allowAnims
            NumberAnimation { duration: backdropLayer.fadeMs; easing.type: Easing.OutCubic }
        }
        onStatusChanged: {
            if (status === Image.Ready) backdropLayer._promoteA()
            else if (status === Image.Error) backdropLayer._failLoading(source)
        }
    }

    Image {
        id: bgB
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        mipmap: false
        smooth: false
        opacity: (backdropLayer._showB && status === Image.Ready && backdropLayer._visibleUrl !== "")
                 ? backdropLayer.targetOpacity : 0.0
        Behavior on opacity {
            enabled: !!backdropLayer.host && backdropLayer.host.allowAnims
            NumberAnimation { duration: backdropLayer.fadeMs; easing.type: Easing.OutCubic }
        }
        onStatusChanged: {
            if (status === Image.Ready) backdropLayer._promoteB()
            else if (status === Image.Error) backdropLayer._failLoading(source)
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "#000"
        readonly property real darken: backdropLayer.host
                                       ? Math.max(0.0, Math.min(1.0, backdropLayer.host.bgDarken))
                                       : 0.0
        opacity: (backdropLayer._visibleUrl !== "") ? darken : 0.0
        Behavior on opacity {
            enabled: !!backdropLayer.host && backdropLayer.host.allowAnims
            NumberAnimation { duration: backdropLayer.fadeMs; easing.type: Easing.OutCubic }
        }
    }

    Rectangle {
        anchors.fill: parent
        z: 100
        color: "#000"
        visible: !!backdropLayer.host && backdropLayer.host.focusSection === 0
    }
}
