// qml/pages/TopBar.qml
// QtQuick 2.15 — logo à gauche, titre CENTRÉ, heure à droite
// ⚙️ L’horloge est rendue par Components.ClockHUD et peut être masquée via root.showClock.
//    Les marges safeMarginLeft/Right évitent l’overscan TV.
//
// ✅ Côté Jellyfin :
//    - TopBar pré-vérifie les logos Jellyfin avant de les donner à Image.source.
//    - Aucun retry cache-buster n’est lancé, afin d’éviter le spam de logs Qt avec URL tokenisée.

import QtQuick 2.15
import "../js/jellyfinBridge.js" as Jellyfin
import "../components" as Components
import "../js/SafeLog.js" as SafeLog

Item {
    id: root
    width: 1920
    height: 70

    /* ====== API ====== */
    property string itemTitle: ""
    // Logo (mode manuel)
    property string itemLogoUrl: ""        // URL brute fournie par le parent (optionnel)

    // Logo (mode auto Jellyfin / fallback)
    property var    currentItem: null      // objet Jellyfin complet (Item), optionnel
    property string serverUrl: ""          // utilisé pour ClockHUD + fallback Primary
    property string accessToken: ""        // pour fallback Primary

    property bool   showLogoFirst: true
    property string baseUrl: ""            // pour les URLs relatives éventuelles
    property bool   stickyLogo: true

    // Safe-area pour TV (antisaut d’horloge hors-écran)
    property int safeMarginLeft: 28
    property int safeMarginRight: 28

    // Horloge
    property bool showClock: true
    readonly property bool clockVisible: showClock

    // Contexte optionnel pour ClockHUD
    property var    fbx
    property string userId: ""
    property string userImageTag: ""
    property string avatarUrl: ""

    /* ====== Nettoyage URL logo ====== */
    function absolutize(u){
        if(!u||!u.length) return "";
        if (u.indexOf("http://")===0 || u.indexOf("https://")===0) return u;
        if (u[0] === "/") return (baseUrl&&baseUrl.length?baseUrl:"") + u;
        return (baseUrl&&baseUrl.length? (baseUrl + "/" + u) : u);
    }
    function normalizeUrl(u){
        if(!u||!u.length) return "";
        var a=absolutize(u), q=a.indexOf("?"); if(q<0) return a;
        var base=a.substring(0,q), qs=a.substring(q+1).split("&").filter(function(p){return p.length>0});
        var kept=[];
        for (var i=0;i<qs.length;i++){
            var kv=qs[i].split("="); var k=decodeURIComponent(kv[0]||"");
            if(k==="cb") continue; // ignorer le cache-buster
            kept.push(qs[i]);
        }
        kept.sort();
        return kept.length ? (base+"?"+kept.join("&")) : base;
    }
    function hasTag(u){
        if(!u||!u.length) return false;
        var q=u.indexOf("?"); if(q<0) return false;
        return u.substring(q+1).split("&").some(function(p){ return (p.split("=")[0]||"")==="tag"; });
    }

    function _queryKey(p){
        var k = String(p || "").split("=")[0] || "";
        try { return decodeURIComponent(k); } catch(e) { return k; }
    }

    function _urlWithoutAuth(u){
        if(!u || !u.length) return "";
        var a = Jellyfin.stripAuthQueryFromUrl(absolutize(u));
        var q = a.indexOf("?");
        if(q < 0) return a;
        var base = a.substring(0, q);
        var qs = a.substring(q + 1).split("&");
        var kept = [];
        var seen = {};
        for(var i = 0; i < qs.length; i++){
            var p = qs[i];
            if(!p || !p.length) continue;
            var k = _queryKey(p);
            if(k === "cb") continue;
            if(seen[k]) continue;
            seen[k] = true;
            kept.push(p);
        }
        return kept.length ? (base + "?" + kept.join("&")) : base;
    }

    function _displayLogoUrl(u){
        // Sécurité FreeStore/GitHub:
        // Image.source ne doit jamais recevoir de token en query string.
        // L'auth éventuelle reste réservée au probe XHR via le header Authorization Jellyfin.
        return _urlWithoutAuth(u);
    }

    function _looksLikeLogoUrl(u){
        return !!(u && u.length && u.indexOf("/Images/Logo") !== -1);
    }

    function _urlTargetsCurrentItem(u){
        try {
            if (!u || !u.length || !currentItem || !currentItem.Id) return false;
            return u.indexOf("/Items/" + currentItem.Id + "/Images/Logo") !== -1;
        } catch(e) {
            return false;
        }
    }

    function _currentItemHasLogoTag(){
        try {
            var tags = currentItem && currentItem.ImageTags ? currentItem.ImageTags : null;
            return !!(tags && tags.Logo && String(tags.Logo).length > 0);
        } catch(e) {
            return false;
        }
    }

    // Évite de donner à QML Image une URL /Images/Logo déjà connue comme absente.
    // Ça supprime les erreurs naturelles Qt avec URL + token pour les épisodes/items sans logo.
    function _shouldSkipMissingLogo(u){
        return _looksLikeLogoUrl(u) && _urlTargetsCurrentItem(u) && !_currentItemHasLogoTag();
    }

    /* ====== État interne ====== */
    property string _lastGoodUrl: ""
    property string _currentUrl: ""
    property bool   _applyPending: false
    property bool   _wantedLogoKnownMissing: false
    property string _lastReason: ""
    property int    _logoProbeSeq: 0
    property string _logoProbePendingKey: ""
    property var    _logoReadyMemo: ({})
    property var    _logoFailureMemo: ({})
    readonly property int _logoMemoLimit: 128

    function _trimLogoMemo(m){
        var keys = Object.keys(m || {});
        if(keys.length <= _logoMemoLimit) return m || {};
        var out = {};
        var start = Math.max(0, keys.length - _logoMemoLimit);
        for(var i = start; i < keys.length; i++) out[keys[i]] = m[keys[i]];
        return out;
    }

    Timer {
        id: debounceTimer
        interval: 140
        repeat: false
        onTriggered: root._applyLogo()
    }

    function _scheduleApply(reason){
        _lastReason = reason || "";
        _applyPending = true;
        debounceTimer.restart();
    }

    // Choix de la source brute “voulu” (avant normalisation)
    // 1) itemLogoUrl explicite (si fourni par le parent)
    // 2) sinon on laisse vide → ce TopBar ne force plus /Images/Logo tout seul
    function _pickWantedRawUrl() {
        _wantedLogoKnownMissing = false;
        if (itemLogoUrl && itemLogoUrl.length) {
            if (_shouldSkipMissingLogo(itemLogoUrl)) {
                _wantedLogoKnownMissing = true;
                return "";
            }
            return itemLogoUrl;
        }
        return "";
    }

    function _chooseEffectiveUrl(){
        var wantedRaw = _pickWantedRawUrl();
        var wanted = normalizeUrl(wantedRaw);

        if(!showLogoFirst){
            if(stickyLogo && _lastGoodUrl.length) return _lastGoodUrl;
            return "";
        }
        if(!wanted || !wanted.length){
            if(!_wantedLogoKnownMissing && stickyLogo && _lastGoodUrl.length) return _lastGoodUrl;
            return "";
        }
        if(_lastGoodUrl && hasTag(_lastGoodUrl) && !hasTag(wanted)){
            return _lastGoodUrl;
        }
        return wanted;
    }

    function _memoHas(m, key){
        return !!(m && key && typeof m[key] !== "undefined" && m[key]);
    }


    // SÉCURITÉ PUBLICATION :
    // les mémos ne doivent pas garder une URL logo complète (serverUrl + itemId).
    // Image.source garde l’URL affichable, mais les clés internes utilisent logo#hash.
    function _logoMemoKey(url) {
        var clean = _urlWithoutAuth(normalizeUrl(url));
        return clean ? ("logo#" + SafeLog.shortHash(clean)) : "";
    }

    function _setLogoSourceIfChanged(url) {
        var s = String(url || "");
        if (String(logo.source || "") !== s)
            logo.source = s;
    }

    function _clearLogoSourceIfNeeded() {
        if (String(logo.source || "") !== "")
            logo.source = "";
    }


    function _memoSetReady(key){
        if(!key || !key.length) return;
        var m = _logoReadyMemo || {};
        if(m[key] === true) return;
        m[key] = true;
        _logoReadyMemo = _trimLogoMemo(m);
    }

    function _memoSetFailure(key){
        if(!key || !key.length) return;
        var m = _logoFailureMemo || {};
        if(m[key] === true) return;
        m[key] = true;
        _logoFailureMemo = _trimLogoMemo(m);
    }

    function _assignLogoSource(eff){
        var src = _displayLogoUrl(eff);
        if(!src || !src.length){
            _currentUrl = "";
            _clearLogoSourceIfNeeded();
            logo.opacity = 0.0;
            leftSlot.width = 0;
            return;
        }
        if(src === _currentUrl){
            if(logo.status === Image.Ready) logo.opacity = 0.95;
            return;
        }
        _currentUrl = src;
        _setLogoSourceIfChanged(_currentUrl);
    }

    function _probeLogoThenAssign(eff){
        var probeUrl = _urlWithoutAuth(eff);
        var memoKey = _logoMemoKey(probeUrl);
        if(!probeUrl || !probeUrl.length || !memoKey.length){
            leftSlot.width = 0;
            return;
        }

        if(_memoHas(_logoFailureMemo, memoKey)){
            _currentUrl = "";
            _clearLogoSourceIfNeeded();
            logo.opacity = 0.0;
            leftSlot.width = 0;
            return;
        }

        if(_memoHas(_logoReadyMemo, memoKey)){
            _assignLogoSource(eff);
            return;
        }

        var seq = ++_logoProbeSeq;
        _logoProbePendingKey = memoKey;
        leftSlot.width = Math.max(120, logo.width);

        function failProbe(){
            if(seq !== root._logoProbeSeq || memoKey !== root._logoProbePendingKey) return;
            root._memoSetFailure(memoKey);
            root._wantedLogoKnownMissing = true;
            root._currentUrl = "";
            _clearLogoSourceIfNeeded();
            logo.opacity = 0.0;
            leftSlot.width = 0;
        }

        if(!Jellyfin || typeof Jellyfin.probeResource !== "function"){
            failProbe();
            return;
        }

        Jellyfin.probeResource(probeUrl, accessToken,
            { accept: "image/*", metadataOnly: true, timeoutMs: 7000 },
            function(){
                if(seq !== root._logoProbeSeq || memoKey !== root._logoProbePendingKey) return;
                root._memoSetReady(memoKey);
                root._assignLogoSource(eff);
            },
            failProbe
        );
    }

    function _applyLogo(){
        _applyPending = false;

        var eff = _chooseEffectiveUrl();
        var wantLogo = eff.length > 0;

        var reserved = ((_lastGoodUrl.length > 0) || (_currentUrl.length > 0) || wantLogo);
        leftSlot.width = reserved ? Math.max(120, logo.width) : 0;

        if(!wantLogo){
            _currentUrl = "";
            _clearLogoSourceIfNeeded();
            logo.opacity = 0.0;
            return;
        }

        if(_looksLikeLogoUrl(eff)){
            _probeLogoThenAssign(eff);
            return;
        }

        _assignLogoSource(eff);
    }

    /* ====== Hooks ====== */
    onItemLogoUrlChanged:     _scheduleApply("itemLogoUrlChanged")
    onShowLogoFirstChanged:   _scheduleApply("showLogoFirstChanged")
    onCurrentItemChanged:     _scheduleApply("currentItemChanged")

    Component.onCompleted: {
        _scheduleApply("onCompleted")
    }

    /* ====== Fond ====== */
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#66000000" }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }

    /* ====== DROITE : ClockHUD ====== */
    Row {
        id: rightRow
        anchors.right: parent.right
        anchors.rightMargin: root.safeMarginRight   // ← safe-area
        anchors.verticalCenter: parent.verticalCenter
        spacing: 16

        // Wrapper: respecte la visibilité interne de ClockHUD ET permet
        // au TopBar de masquer l’ensemble sans écraser son binding interne.
        Item {
            id: clockWrap
            anchors.verticalCenter: parent.verticalCenter
            visible: root.clockVisible

            Components.ClockHUD {
                id: clockHud
                anchors.verticalCenter: parent.verticalCenter
                fontPx: 20
                fbx:       root.fbx
                serverUrl: root.serverUrl
                userId:    root.userId
                userImageTag: root.userImageTag
                avatarUrl: root.avatarUrl
                avatarForceLoop: true
                avatarAnimateAlways: true
                // pas de "visible:" ici → la logique interne du composant reste maîtresse
            }
        }
    }

    /* ====== GAUCHE : logo ====== */
    Item {
        id: leftSlot
        anchors.left: parent.left
        anchors.leftMargin: root.safeMarginLeft     // ← safe-area
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        width: 0

        Image {
            id: logo
            anchors.verticalCenter: parent.verticalCenter
            visible: true
            asynchronous: true
            cache: true
            // Logo topbar fixe: pas de mipmap, sourceSize suffit et allège GPU/RAM Freebox.
            mipmap: false
            smooth: true
            fillMode: Image.PreserveAspectFit
            sourceSize.height: 44
            height: 44

            // Largeur bornée ; implicitWidth peut valoir 0 avant Ready
            width: status === Image.Ready
                   ? Math.min(280, Math.max(implicitWidth > 0 ? implicitWidth : 120, 120))
                   : 120

            opacity: 0.0
            Behavior on opacity { NumberAnimation { duration: 150 } }

            // Pas de retry cb=1/cb=2 ici : Qt loggue l’URL complète en cas d’échec.
            // On tente une seule fois, puis fallback texte/titre silencieux.
            onStatusChanged: {
                if (status === Image.Ready) {
                    if (_currentUrl && _currentUrl.length) {
                        _lastGoodUrl = _currentUrl;
                    }
                    opacity = 0.95;
                } else if (status === Image.Error) {
                    var failedLogo = (_currentUrl && _currentUrl.indexOf("/Images/Logo") !== -1);
                    if (failedLogo) {
                        _memoSetFailure(_logoMemoKey(_currentUrl));
                        if (_urlTargetsCurrentItem(_currentUrl)) {
                            _wantedLogoKnownMissing = true;
                        }
                    }

                    _currentUrl = "";
                    root._clearLogoSourceIfNeeded();
                    opacity = 0.0;
                    leftSlot.width = 0;
                } else if (status === Image.Loading) {
                    if (opacity > 0.0) opacity = 0.6;
                }
            }
        }
    }

    /* ====== CENTRE : titre centré ====== */
    Item {
        id: centerArea
        anchors.left: leftSlot.right
        anchors.leftMargin: 16
        anchors.right: rightRow.left
        anchors.rightMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height

        Text {
            id: title
            text: root.itemTitle
            textFormat: Text.PlainText
            visible: text && text.length > 0
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            color: "#FFFFFF"
            opacity: 0.92
            font.pixelSize: 24
            clip: true
        }
    }
}
