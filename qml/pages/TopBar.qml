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
import "../js/JellyfinHttpTransport.js" as HttpTransport
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

    // Taille adaptative au ratio reel du logo (large, carre ou vertical).
    // Boite bornee : une seule texture jusqu'a 600 x 144 px en RAM/GPU.
    readonly property real logoMaxWidth: Math.min(500, Math.max(250, root.width * 0.31))
    readonly property real logoMaxHeight: 98
    readonly property real logoTopMargin: 12
    readonly property real logoAspectRatio: (logo.status === Image.Ready &&
            logo.implicitWidth > 0 && logo.implicitHeight > 0)
            ? logo.implicitWidth / logo.implicitHeight : 3.0
    // Position du bord inferieur du dessin, pour le titre de l'episode.
    readonly property real logoBottomY: logoReady ? (logo.y + logo.paintedHeight) : 0

    // Safe-area pour TV (antisaut d’horloge hors-écran)
    property int safeMarginLeft: 28
    property int safeMarginRight: 28
    // Recul discret de 16 px, sans passer sous les 28 px anti-overscan.
    // Egalement utilise par le titre de l'episode dans PlayerOverlay.
    readonly property int mediaLeftInset: Math.max(28, safeMarginLeft - 16)

    // Horloge
    property bool showClock: true
    readonly property bool clockVisible: showClock
    property bool showUserProfile: true
    // Même ancrage que detailMoviePage/detailSeriePage/seasonpage.
    property int clockHudTopMargin: 20
    property int clockHudRightMargin: 24
    // Le lecteur stoppe uniquement le décodage GIF lorsque le chrome est masqué.
    property bool clockHudActive: true

    // Contexte optionnel pour ClockHUD
    property var    fbx
    property string userId: ""
    property string userName: ""
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
        var a = HttpTransport.stripAuthQueryFromUrl(absolutize(u));
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
    // True lorsque le logo est pret OU definitivement absent/echec pour l'item.
    // Le Player ne montre le titre qu'apres cette decision, sans titre provisoire.
    property bool logoResolutionComplete: false
    readonly property bool logoReady: logo.status === Image.Ready && _currentUrl.length > 0
    readonly property string readyLogoUrl: logoReady ? _lastGoodUrl : ""

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
    // Un logo lent ou une image bloquee ne peut cacher le titre indefiniment.
    // Au dela de cette borne, on fige le fallback texte sans deplacement tardif.
    Timer {
        id: logoDecisionDeadline
        interval: 5000
        repeat: false
        onTriggered: {
            ++root._logoProbeSeq
            root._logoProbePendingKey = ""
            root._currentUrl = ""
            root._clearLogoSourceIfNeeded()
            logo.opacity = 0.0
            leftSlot.width = 0
            root.logoResolutionComplete = true
        }
    }

    function _scheduleApply(reason){
        _lastReason = reason || "";
        _applyPending = true;
        // Invalider les anciens probes avant meme l'expiration du debounce.
        ++_logoProbeSeq;
        _logoProbePendingKey = "";
        logoResolutionComplete = false;
        logoDecisionDeadline.stop();
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
        if(stickyLogo && _lastGoodUrl && hasTag(_lastGoodUrl) && !hasTag(wanted)){
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
            logoDecisionDeadline.stop();
            logoResolutionComplete = true;
            return;
        }
        if(src === _currentUrl){
            if(logo.status === Image.Ready) {
                logo.opacity = 0.95;
                logoDecisionDeadline.stop();
                logoResolutionComplete = true;
            }
            return;
        }
        _currentUrl = src;
        _setLogoSourceIfChanged(_currentUrl);
        if(logo.status === Image.Ready) {
            logoDecisionDeadline.stop();
            logoResolutionComplete = true;
        }
    }

    function _probeLogoThenAssign(eff){
        var probeUrl = _urlWithoutAuth(eff);
        var memoKey = _logoMemoKey(probeUrl);
        if(!probeUrl || !probeUrl.length || !memoKey.length){
            leftSlot.width = 0;
            logoDecisionDeadline.stop();
            logoResolutionComplete = true;
            return;
        }

        if(_memoHas(_logoFailureMemo, memoKey)){
            _currentUrl = "";
            _clearLogoSourceIfNeeded();
            logo.opacity = 0.0;
            leftSlot.width = 0;
            logoDecisionDeadline.stop();
            logoResolutionComplete = true;
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
            logoDecisionDeadline.stop();
            logoResolutionComplete = true;
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
        logoDecisionDeadline.stop();
        if(eff.length) logoDecisionDeadline.start();
        var wantLogo = eff.length > 0;

        var reserved = ((stickyLogo && _lastGoodUrl.length > 0) || (_currentUrl.length > 0) || wantLogo);
        leftSlot.width = reserved ? Math.max(120, logo.width) : 0;

        if(!wantLogo){
            _currentUrl = "";
            _clearLogoSourceIfNeeded();
            logo.opacity = 0.0;
            leftSlot.width = 0;
            logoResolutionComplete = true;
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
    // Avatar, nom et heure gardent exactement la géométrie des pages de détail.
    // Ne pas centrer ce bloc dans la TopBar de 70 px : le HUD serait décalé
    // vers le haut et sa position varierait avec la présence du nom.
    Item {
        id: clockHudSlot
        anchors.top: parent.top
        anchors.topMargin: root.clockHudTopMargin
        anchors.right: parent.right
        anchors.rightMargin: root.clockHudRightMargin
        visible: root.clockVisible || (root.showUserProfile && root.userId.length > 0)
        width: clockHud.implicitWidth
        height: clockHud.implicitHeight

        Components.ClockHUD {
            id: clockHud
            anchors.fill: parent
            fontPx: 22
            fbx: root.fbx
            serverUrl: root.serverUrl
            userId: root.userId
            userName: root.userName
            userImageTag: root.userImageTag
            avatarUrl: root.avatarUrl
            clockEnabled: root.showClock
            showAvatar: root.showUserProfile && root.userId.length > 0
            showUserName: true
            avatarSize: 52
            userNameFontPx: 12
            userNameMaxWidth: 96
            avatarInteractive: false
            // AnimatedImage et watchdog existants : GIF animé en boucle,
            // sans modifier l'URL ni lancer de nouveaux chargements périodiques.
            avatarStaticOnly: false
            avatarForceLoop: true
            avatarAnimateAlways: true
            active: root.clockHudActive
            fadeWithScroll: false
            // La visibilité interne du composant reste sous son contrôle.
        }
    }

    /* ====== GAUCHE : logo ====== */
    Item {
        id: leftSlot
        anchors.left: parent.left
        anchors.leftMargin: root.mediaLeftInset
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        width: 0

        Image {
            id: logo
            // Ne jamais etirer le logo ni reserver de faux espace horizontal.
            anchors.top: parent.top
            anchors.topMargin: root.logoTopMargin
            visible: true
            asynchronous: true
            cache: true
            mipmap: false
            smooth: true
            fillMode: Image.PreserveAspectFit
            // Decodage plafonne, plus detaille que l'ancienne hauteur 44 px.
            // Conserver les DEUX dimensions fixes evite de charger en RAM
            // une immense texture pour un logo panoramique ou vertical.
            sourceSize.width: 600
            sourceSize.height: 144
            width: status === Image.Ready
                   ? Math.min(root.logoMaxWidth, root.logoMaxHeight * root.logoAspectRatio)
                   : 140
            height: status === Image.Ready
                    ? Math.min(root.logoMaxHeight, root.logoMaxWidth / root.logoAspectRatio)
                    : root.logoMaxHeight

            onWidthChanged: {
                if (status === Image.Ready && root._currentUrl.length > 0)
                    leftSlot.width = Math.ceil(width)
            }

            opacity: 0.0
            Behavior on opacity { NumberAnimation { duration: 150 } }

            // Pas de retry cb=1/cb=2 ici : Qt loggue l’URL complète en cas d’échec.
            // On tente une seule fois, puis fallback texte/titre silencieux.
            onStatusChanged: {
                if (status === Image.Ready) {
                    if (_currentUrl && _currentUrl.length) {
                        _lastGoodUrl = _currentUrl;
                        leftSlot.width = Math.ceil(width);
                        logoDecisionDeadline.stop();
                        root.logoResolutionComplete = true;
                        opacity = 0.95;
                    } else {
                        opacity = 0.0;
                    }
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
                    logoDecisionDeadline.stop();
                    root.logoResolutionComplete = true;
                } else if (status === Image.Loading) {
                    if (opacity > 0.0) opacity = 0.6;
                }
            }
        }
    }

    /* ====== CENTRE : titre centré ====== */
    Item {
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
