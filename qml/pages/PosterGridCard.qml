// ReDeFin PosterGridCard : renderer riche de Home et Search.
// Les grandes grilles utilisent LibraryPosterCard.qml afin de préserver le CE4100/GMA500.
// QtQuick 2.15, sans QtQuick Controls.
import QtQuick 2.15
import "../js/jellyfinBridge.js" as Jellyfin

FocusScope {
    id: cardRoot

    property var controller: null
    property var modelData: null
    property int tileWidth: 260
    property int tileHeight: 160
    property int titleHeight: 46
    property bool selected: false
    property bool showProgress: false
    property bool preferBackdrop: false
    property string titleText: ""
    property string subtitleText: ""
    property int sidePad: 6
    property int topPad: 0
    property bool musicFallback: false
    property bool allowLoad: true
    property bool suppressFocusTransform: false

    property int cardIndex: -1
    property int gridColumns: 0
    property bool gridActiveFocus: selected
    property bool enableMouseInput: true
    property bool hoverSelectEnabled: false

    property int imageRequestWidth: 0
    property int imageRequestHeight: 0
    property int posterQuality: 0
    property bool useAllowAnimsOverride: false
    property bool allowAnimsOverride: false
    property bool useAllowDecosOverride: false
    property bool allowDecosOverride: false
    property real zoomScaleOverride: 0
    property string fallbackKind: ""
    property string imagePolicy: "standard"
    property bool homeDelegateMode: false
    property var homeLoader: null

    property bool useImageSourceOverride: false
    property string imageSourceOverride: ""
    property string hqImageSourceOverride: ""
    property bool imageCache: false
    property bool smoothImages: allowAnims

    property string fallbackGlyph: ""
    property bool fallbackOnImageError: true
    property bool showFolderIndicator: false
    property bool showVideoIndicator: false

    property int titleTopMargin: 0
    property int titleFontPxOverride: 0
    property int subtitleFontPxOverride: 0
    property int focusLiftPxOverride: -1
    property bool titleBoldAlways: true
    property bool subtitleBoldAlways: true
    property color titleColor: "#e7eaff"
    property color selectedTitleColor: "#ffffff"
    property color subtitleColor: "#cfd6ff"
    property color selectedSubtitleColor: "#ffffff"
    property bool useAllowMarqueeOverride: false
    property bool allowMarqueeOverride: false
    property real marqueeSpeedPxPerSec: 1000.0 / 24.0
    property int marqueeStartDelayMs: 700
    property int marqueeEndPauseMs: 260
    property int marqueeGapPx: 44

    property bool showWatchedBadge: false
    property bool watched: false
    property string watchedBadgePosition: "topRight"
    property int watchedBadgeSize: 24
    property int watchedBadgeMargin: 6
    property bool suppressWatchedWhenUnplayed: true
    property bool showUnplayedBadge: false
    property int unplayedCount: 0
    property string unplayedText: unplayedCount > 99 ? "99+" : String(unplayedCount)
    property real progressRatioOverride: -1
    property int progressSideInsetOverride: -1
    property int progressBottomMarginOverride: -1
    property int progressHeightOverride: -1
    property int progressRadiusOverride: -1
    property string progressTrackColorOverride: ""
    property string progressFillColorOverride: ""
    property int progressMinWidthOverride: -1
    property real fallbackGlyphScale: 0.30

    signal activated()
    signal doubleActivated()
    signal hovered()

    function _boolProp(obj, name, fallback) {
        try {
            if (obj && obj[name] !== undefined && obj[name] !== null)
                return obj[name] === true
        } catch(e) {}
        return fallback === true
    }
    function _numProp(obj, name, fallback) {
        try {
            var v = obj ? Number(obj[name]) : NaN
            if (isFinite(v) && !isNaN(v)) return v
        } catch(e) {}
        return fallback
    }

            // Transaction légère : les propriétés du Loader Home arrivent en grappe.
            // La résolution d'URL ne doit voir que l'état final, jamais les tailles intermédiaires.
            property bool _homeSyncing: false
            signal homeSyncCommitted()

            function _syncHomeLoader() {
                var h = homeLoader
                if (!h) return

                _homeSyncing = true
                try {
                    controller = h.cardController || null
                    modelData = h.cardData || null
                    tileWidth = h.cardTileW || tileWidth
                    tileHeight = h.cardTileH || tileHeight
                    titleHeight = h.cardTitleH || 0
                    sidePad = h.cardSidePad || 0
                    topPad = h.cardTopPad || 0
                    selected = h.cardSelected === true
                    showProgress = h.cardShowProgress === true
                    preferBackdrop = h.cardPreferBackdrop === true
                    musicFallback = h.cardMusicFallback === true
                    allowLoad = h.cardAllowLoad === true
                    imagePolicy = h.cardImagePolicy || "standard"
                    fallbackKind = h.cardFallbackKind || ""
                    enableMouseInput = h.cardEnableMouseInput !== false
                    suppressFocusTransform = h.cardSuppressFocusTransform === true
                    homeDelegateMode = true
                } finally {
                    _homeSyncing = false
                }

                homeSyncCommitted()
            }
            onHomeLoaderChanged: _syncHomeLoader()
            Connections {
                target: cardRoot.homeLoader
                ignoreUnknownSignals: true
                function onCardControllerChanged() { cardRoot._syncHomeLoader() }
                function onCardDataChanged() { cardRoot._syncHomeLoader() }
                function onCardTileWChanged() { cardRoot._syncHomeLoader() }
                function onCardTileHChanged() { cardRoot._syncHomeLoader() }
                function onCardTitleHChanged() { cardRoot._syncHomeLoader() }
                function onCardSidePadChanged() { cardRoot._syncHomeLoader() }
                function onCardTopPadChanged() { cardRoot._syncHomeLoader() }
                function onCardSelectedChanged() { cardRoot._syncHomeLoader() }
                function onCardShowProgressChanged() { cardRoot._syncHomeLoader() }
                function onCardPreferBackdropChanged() { cardRoot._syncHomeLoader() }
                function onCardMusicFallbackChanged() { cardRoot._syncHomeLoader() }
                function onCardAllowLoadChanged() { cardRoot._syncHomeLoader() }
                function onCardImagePolicyChanged() { cardRoot._syncHomeLoader() }
                function onCardFallbackKindChanged() { cardRoot._syncHomeLoader() }
                function onCardEnableMouseInputChanged() { cardRoot._syncHomeLoader() }
                function onCardSuppressFocusTransformChanged() { cardRoot._syncHomeLoader() }
            }

            // Image.source conserve l’URL complète nécessaire au rendu. Les états internes
            // ne recopient jamais cette URL dans des journaux ou caches de diagnostic.

            readonly property bool allowAnims: useAllowAnimsOverride ? allowAnimsOverride : cardRoot._boolProp(controller, "allowAnims", cardRoot._boolProp(controller, "allowFocusAnims", false))
            readonly property bool allowDecos: useAllowDecosOverride ? allowDecosOverride : cardRoot._boolProp(controller, "allowDecos", allowAnims)
            readonly property bool allowMarquee: useAllowMarqueeOverride
                                                 ? allowMarqueeOverride
                                                 : (controller ? cardRoot._boolProp(controller, "allowMarquee", false) : false)
            readonly property int focusLiftPx: focusLiftPxOverride >= 0
                                               ? focusLiftPxOverride
                                               : Math.round(cardRoot._numProp(controller, "focusLiftPx", 6))
            readonly property real frameWidth: cardRoot._numProp(controller, "frameWidth", 2.0)
            readonly property real zoomScale: zoomScaleOverride > 0 ? zoomScaleOverride : cardRoot._numProp(controller, "zoomScale", cardRoot._numProp(controller, "focusScale", 1.14))
            readonly property int cardTitleFontPx: titleFontPxOverride > 0
                                                   ? titleFontPxOverride
                                                   : Math.round(cardRoot._numProp(controller, "cardTitleFontPx", 20))
            readonly property int cardSubtitleFontPx: subtitleFontPxOverride > 0
                                                      ? subtitleFontPxOverride
                                                      : Math.round(cardRoot._numProp(controller, "cardSubtitleFontPx", 15))
            readonly property int posterQFastValue: Math.round(cardRoot._numProp(controller, "posterQFast", 90))
            readonly property real posterScaleValue: cardRoot._numProp(controller, "posterScale", 1.35)
            readonly property int hqPosterQualityValue: Math.round(cardRoot._numProp(controller, "hqPosterQuality", 92))
            readonly property real hqPosterScaleValue: cardRoot._numProp(controller, "hqPosterScale", 1.60)
            readonly property string hqPosterTargetIdValue: { try { return controller && controller.hqPosterTargetId ? String(controller.hqPosterTargetId) : "" } catch(e) { return "" } }
            readonly property bool hqPosterActive: !!(allowLoad && selected && modelData && modelData.Id && hqPosterTargetIdValue.length && String(modelData.Id) === hqPosterTargetIdValue)
            readonly property bool marqueeFocusActive: selected && allowMarquee && allowAnims && allowLoad
            function _focusVisualActive() {
                return selected && !suppressFocusTransform
            }

            function marqueeTravelFor(paintedWidth, gap, enabled) {
                return enabled ? Math.max(0, paintedWidth + gap) : 0
            }
            function marqueeScrollMsFor(travel) {
                var speed = Math.max(1, Number(marqueeSpeedPxPerSec) || (1000.0 / 24.0))
                return travel > 0
                        ? Math.max(3200, Math.min(14000, Math.round((travel / speed) * 1000)))
                        : 0
            }
            function fadeWidthFor(lineWidth, minW, maxW) {
                return Math.min(maxW, Math.max(minW, Math.round(lineWidth * 0.18)))
            }
            function centeredTextY(lineHeight, textHeight) {
                return Math.round((lineHeight - textHeight) / 2)
            }

            function _pad2(v) { var n = Number(v); if (!isFinite(n) || n < 0) return ""; n = Math.floor(n); return (n < 10 ? "0" : "") + n }
            function _typeOf(item) { return item ? String(item.Type || "").toLowerCase() : "" }
            function isEpisodeItemSafe(item) { return _typeOf(item) === "episode" }
            function isSeasonItemSafe(item) { return _typeOf(item) === "season" }
            function isSeriesItemSafe(item) { return _typeOf(item) === "series" }
            function isMovieItemSafe(item) { return _typeOf(item) === "movie" }
            function classificationForSafe(item) { if (!isMovieItemSafe(item)) return ""; return String(item.OfficialRating || item.CustomRating || item.ParentalRating || item.AgeRating || "").replace(/^\s+|\s+$/g, "") }
            function seriesNameForSafe(item) { if (!item) return ""; return String(item.SeriesName || item.SeriesTitle || item.Series || item.ShowName || "").replace(/^\s+|\s+$/g, "") }
            function _yearFromDateSafe(v) {
                var s = String(v || "")
                var m = /^(\d{4})/.exec(s)
                return m && m[1] ? m[1] : ""
            }
            function seriesBroadcastRangeSafe(item) {
                if (!isSeriesItemSafe(item)) return ""

                var start = ""
                if (item.ProductionYear !== undefined
                        && item.ProductionYear !== null
                        && String(item.ProductionYear).length > 0) {
                    var py = Number(item.ProductionYear)
                    if (isFinite(py) && !isNaN(py) && py >= 1800 && py <= 3000)
                        start = String(Math.floor(py))
                }
                if (!start)
                    start = _yearFromDateSafe(item.PremiereDate)

                var end = _yearFromDateSafe(item.EndDate)
                       || _yearFromDateSafe(item.DateEnded)
                       || _yearFromDateSafe(item.SeriesEndDate)

                if (start && end)
                    return start === end ? start : (start + " - " + end)

                // Si Jellyfin ne fournit pas de date de fin, ne jamais inventer
                // une plage. La seule année connue reste préférable.
                return start || end
            }
            function seasonNameForSafe(item) {
                if (!isSeasonItemSafe(item)) return ""
                var label = String(item.Name || "").replace(/^\s+|\s+$/g, "")
                if (label) return label
                if (item.IndexNumber !== undefined && item.IndexNumber !== null) {
                    var n = Number(item.IndexNumber)
                    if (isFinite(n) && !isNaN(n) && n >= 0) return "Saison " + Math.floor(n)
                }
                return ""
            }
            function episodeCodeForSafe(item) { if (!item) return ""; var s = (item.ParentIndexNumber !== undefined && item.ParentIndexNumber !== null) ? _pad2(item.ParentIndexNumber) : "", e = (item.IndexNumber !== undefined && item.IndexNumber !== null) ? _pad2(item.IndexNumber) : ""; return s && e ? "S" + s + "E" + e : (s ? "S" + s : (e ? "E" + e : "")) }
            function cardMainTitleFor(item) {
                if (!item) return ""
                if (isEpisodeItemSafe(item)) {
                    var serie = seriesNameForSafe(item), code = episodeCodeForSafe(item)
                    if (serie && code) return serie + " — " + code
                    if (serie) return serie
                    if (code) return code
                }
                if (isSeasonItemSafe(item)) {
                    var seasonSerie = seriesNameForSafe(item)
                    if (seasonSerie) return seasonSerie
                    return seasonNameForSafe(item)
                }
                return item.Name || ""
            }
            function cardSubtitleTitleFor(item) {
                if (!item) return ""
                if (isEpisodeItemSafe(item))
                    return item.Name ? item.Name : ""

                if (isSeasonItemSafe(item)) {
                    // Saison groupée : Nom de série / Saison X.
                    return seriesNameForSafe(item) ? seasonNameForSafe(item) : ""
                }

                if (isSeriesItemSafe(item) && imagePolicy === "latest-series") {
                    // Intégrale groupée par Jellyfin : ne pas afficher le mot
                    // "Intégrale", mais la période de diffusion, ex. 2004 - 2010.
                    return seriesBroadcastRangeSafe(item)
                }

                return isMovieItemSafe(item) ? classificationForSafe(item) : ""
            }
            function isVideoLikeSafe(item) { var t = _typeOf(item); return t === "movie" || t === "video" || t === "episode" || t === "musicvideo" || t === "trailer" }
            function isFolderLikeSafe(item) { if (!item) return false; if (item.IsFolder) return true; var t = _typeOf(item); return t !== "series" && (t.indexOf("folder") >= 0 || String(item.CollectionType || "") !== "" || t === "boxset" || t === "collection") }
            function fallbackWantsVideo() { return fallbackKind === "video" || fallbackKind === "movie" || fallbackKind === "episode" }
            function fallbackWantsFilmstrip() { return fallbackKind === "filmstrip" }
            function fallbackWantsClapperboard() { return fallbackKind === "clapperboard" }
            function fallbackWantsFolder() { return fallbackKind === "folder" || fallbackKind === "collection" || fallbackKind === "boxset" }
            function fallbackWantsSeries() { return fallbackKind === "series" }
            function _serverUrlSafe() {
                try { return String(controller && controller.serverUrl ? controller.serverUrl : "") } catch(e) { return "" }
            }
            function _imageQuery(width, height, quality, scale, preserveFit) {
                var capW = Math.max(1, Math.round(cardRoot._numProp(controller, "bgCapW", 1280)))
                var capH = Math.max(1, Math.round(cardRoot._numProp(controller, "bgCapH", 720)))
                var w = Math.max(1, Math.min(width || tileWidth, capW))
                var h = Math.max(1, Math.min(height || tileHeight, capH))
                var fw = Math.max(1, Math.round(w * scale))
                var fh = Math.max(1, Math.round(h * scale))
                return preserveFit
                    ? ({ maxWidth: fw, maxHeight: fh, quality: quality })
                    : ({ fillWidth: fw, fillHeight: fh, quality: quality })
            }
            function _itemImageUrl(id, type, tag, options) {
                var server = _serverUrlSafe()
                if (!server || !id || !type) return ""
                return Jellyfin.itemImageUrl(server, id, type, tag, options || {})
            }
            function _imageVariantUnavailable(id, type, tag) {
                try {
                    return !!(controller && controller.isImageVariantUnavailable
                              && controller.isImageVariantUnavailable(id, type, tag) === true)
                } catch(e0) {}
                return false
            }
            function _markImageVariantUnavailable(id, type, tag) {
                try {
                    if (controller && controller.markImageVariantUnavailable)
                        return controller.markImageVariantUnavailable(id, type, tag) === true
                } catch(e0) {}
                return false
            }
            function _resolvedSpec(id, type, tag, query, fit) {
                id = String(id || "")
                type = String(type || "")
                tag = String(tag || "")
                if (!id || !type || !tag || _imageVariantUnavailable(id, type, tag))
                    return null
                return {
                    url: _itemImageUrl(id, type, tag, query),
                    potential: true,
                    fit: fit === true,
                    id: id,
                    type: type,
                    tag: tag
                }
            }
            function _standardImageSpec(item, qualityOverride, scaleOverride) {
                if (!item) return ({ url:"", potential:false, fit:false, id:"", type:"", tag:"" })
                var rw = imageRequestWidth > 0 ? imageRequestWidth : tileWidth
                var rh = imageRequestHeight > 0 ? imageRequestHeight : tileHeight
                var rq = Number(qualityOverride) > 0 ? Number(qualityOverride) : (posterQuality > 0 ? posterQuality : posterQFastValue)
                var rs = Number(scaleOverride) > 0 ? Number(scaleOverride) : posterScaleValue
                var query = _imageQuery(rw, rh, rq, rs, false)
                var tags = item.ImageTags || {}
                var backdropTag = item.BackdropImageTags && item.BackdropImageTags.length > 0
                        ? String(item.BackdropImageTags[0] || "") : ""
                var backdropId = String(item.BackdropImageItemId || item.Id || "")
                var primaryTag = String(tags.Primary || item.PrimaryImageTag || "")
                var thumbTag = String(tags.Thumb || item.ThumbImageTag || "")
                var thumbId = String(item.ThumbImageItemId || item.ParentThumbItemId || item.Id || "")
                var parentBackdropTags = item.ParentBackdropImageTags || []
                var parentBackdropTag = parentBackdropTags.length > 0 ? String(parentBackdropTags[0] || "") : ""
                var parentBackdropId = String(item.ParentBackdropItemId || "")
                var seriesId = String(item.SeriesId || "")
                var seriesPrimaryTag = String(item.SeriesPrimaryImageTag || "")
                var hadPotential = !!(backdropTag || primaryTag || thumbTag || parentBackdropTag || seriesPrimaryTag)
                var spec = null

                if (preferBackdrop && backdropTag) {
                    spec = _resolvedSpec(backdropId, "Backdrop", backdropTag, query, false)
                    if (spec) return spec
                }

                if (primaryTag) {
                    spec = _resolvedSpec(item.Id, "Primary", primaryTag, query, false)
                    if (spec) return spec
                }

                if (thumbTag) {
                    // Search/Hints peut fournir une Thumb appartenant à un autre item.
                    // Utiliser ThumbImageItemId/ParentThumbItemId évite les 404 produits
                    // par l'ancien /Items/<item.Id>/Images/Thumb systématique.
                    spec = _resolvedSpec(thumbId, "Thumb", thumbTag, query, false)
                    if (spec) return spec
                }

                if (parentBackdropId && parentBackdropTag) {
                    spec = _resolvedSpec(parentBackdropId, "Backdrop", parentBackdropTag, query, false)
                    if (spec) return spec
                }

                if (_typeOf(item) === "episode" && seriesId && seriesPrimaryTag) {
                    spec = _resolvedSpec(seriesId, "Primary", seriesPrimaryTag,
                                         _imageQuery(rw, rh, rq, rs, true), true)
                    if (spec) return spec
                }

                // Le contrôleur peut connaître des champs SearchHint supplémentaires.
                // Si toutes les variantes connues ont déjà été blacklistées, ne lui
                // redemander cependant pas la même Thumb en boucle.
                if (!hadPotential && controller && controller.posterUrlFor) {
                    try {
                        var url = controller.posterUrlFor(item, rw, rh,
                                { preferBackdrop: preferBackdrop, quality: rq, scale: rs }) || ""
                        if (url)
                            return ({ url:url, potential:true, fit:false, id:"", type:"", tag:"" })
                    } catch(e0) {}
                }

                return ({ url:"", potential:false, fit:false, id:"", type:"", tag:"" })
            }
            function _nextUpSeriesImageSpec(item, qualityOverride, scaleOverride) {
                if (!item) return ({ url:"", potential:false, fit:false })
                var seriesId = String(item.SeriesId || "")
                if (!seriesId) return ({ url:"", potential:false, fit:false })
                var rw = imageRequestWidth > 0 ? imageRequestWidth : tileWidth
                var rh = imageRequestHeight > 0 ? imageRequestHeight : tileHeight
                var rq = Number(qualityOverride) > 0 ? Number(qualityOverride) : (posterQuality > 0 ? posterQuality : posterQFastValue)
                var rs = Number(scaleOverride) > 0 ? Number(scaleOverride) : posterScaleValue
                var fillQ = _imageQuery(rw, rh, rq, rs, false)
                var fitQ = _imageQuery(rw, rh, rq, rs, true)
                var thumbId = String(item.ParentThumbItemId || "")
                var thumbTag = String(item.ParentThumbImageTag || "")
                if (thumbTag && thumbId === seriesId)
                    return ({ url:_itemImageUrl(seriesId, "Thumb", thumbTag, fillQ), potential:true, fit:false,
                               id:seriesId, type:"Thumb", tag:thumbTag })
                var backdropId = String(item.ParentBackdropItemId || "")
                var backdropTags = item.ParentBackdropImageTags || []
                var backdropTag = backdropTags.length > 0 ? String(backdropTags[0] || "") : ""
                if (backdropTag && backdropId)
                    return ({ url:_itemImageUrl(backdropId, "Backdrop", backdropTag, fillQ), potential:true, fit:false,
                               id:backdropId, type:"Backdrop", tag:backdropTag })
                var primaryTag = String(item.SeriesPrimaryImageTag || "")
                if (primaryTag)
                    return ({ url:_itemImageUrl(seriesId, "Primary", primaryTag, fitQ), potential:true, fit:true,
                               id:seriesId, type:"Primary", tag:primaryTag })
                return ({ url:"", potential:false, fit:false })
            }
            function _latestSeriesImageSpec(item, qualityOverride, scaleOverride) {
                if (!item) return ({ url:"", potential:false, fit:false })
                var type = _typeOf(item)
                var tags = item.ImageTags || {}
                var seriesId = type === "series"
                        ? String(item.Id || "")
                        : String(item.SeriesId || (type === "season" ? item.ParentId : "") || "")
                var primaryTag = type === "series"
                        ? String(tags.Primary || item.PrimaryImageTag || item.SeriesPrimaryImageTag || "")
                        : String(item.SeriesPrimaryImageTag || "")
                var rw = imageRequestWidth > 0 ? imageRequestWidth : tileWidth
                var rh = imageRequestHeight > 0 ? imageRequestHeight : tileHeight
                var rq = Number(qualityOverride) > 0 ? Number(qualityOverride) : (posterQuality > 0 ? posterQuality : posterQFastValue)
                var rs = Number(scaleOverride) > 0 ? Number(scaleOverride) : posterScaleValue

                if (seriesId && primaryTag) {
                    return ({
                        url: _itemImageUrl(seriesId, "Primary", primaryTag,
                                           _imageQuery(rw, rh, rq, rs, false)),
                        potential: true,
                        fit: false,
                        id: seriesId,
                        type: "Primary",
                        tag: primaryTag
                    })
                }

                // Fallback Season : certains DTO Latest groupés n'exposent pas
                // SeriesPrimaryImageTag mais possèdent leur propre poster.
                if (type === "season") {
                    var seasonPrimary = String(tags.Primary || item.PrimaryImageTag || "")
                    if (item.Id && seasonPrimary) {
                        return ({
                            url: _itemImageUrl(String(item.Id), "Primary", seasonPrimary,
                                               _imageQuery(rw, rh, rq, rs, false)),
                            potential: true,
                            fit: false,
                            id: String(item.Id),
                            type: "Primary",
                            tag: seasonPrimary
                        })
                    }
                }

                return ({ url:"", potential:false, fit:false })
            }
            function _resolveImageSpec(item, qualityOverride, scaleOverride) {
                if (imagePolicy === "nextup-series") return _nextUpSeriesImageSpec(item, qualityOverride, scaleOverride)
                if (imagePolicy === "latest-series") return _latestSeriesImageSpec(item, qualityOverride, scaleOverride)
                return _standardImageSpec(item, qualityOverride, scaleOverride)
            }
            function _hqImageSource() {
                if (!hqPosterActive) return ""
                var spec = _resolveImageSpec(modelData, hqPosterQualityValue, hqPosterScaleValue)
                return spec && spec.url ? String(spec.url) : ""
            }
            function _cardIdentityKey(item) {
                if (!item) return ""
                var tags = item.ImageTags || {}
                var backdrops = item.BackdropImageTags || []
                var parentBackdrops = item.ParentBackdropImageTags || []
                return String(item.Id || "") + "|" + imagePolicy + "|"
                     + String(item.SeriesId || "") + "|" + String(item.ParentThumbItemId || "") + "|"
                     + String(tags.Primary || item.PrimaryImageTag || "") + "|"
                     + String(tags.Thumb || item.ThumbImageTag || "") + "|"
                     + String(backdrops.length ? backdrops[0] : "") + "|"
                     + String(item.ParentThumbImageTag || "") + "|"
                     + String(item.ParentBackdropItemId || "") + "|"
                     + String(parentBackdrops.length ? parentBackdrops[0] : "") + "|"
                     + String(item.SeriesPrimaryImageTag || "") + "|"
                     + String(imageRequestWidth || tileWidth) + "x" + String(imageRequestHeight || tileHeight) + "|"
                     + String(preferBackdrop ? 1 : 0)
            }
            function resumeRatioSafe(item) { if (progressRatioOverride >= 0) return Math.max(0, Math.min(1, progressRatioOverride)); if (!item) return 0; var dur = item.RunTimeTicks || item.CumulativeRunTimeTicks || 0, pos = (item.UserData && item.UserData.PlaybackPositionTicks) ? item.UserData.PlaybackPositionTicks : 0; if (!dur || pos <= 0) return 0; var r = pos / dur; return r < 0 ? 0 : (r > 1 ? 1 : r) }
            readonly property string effectiveTitleText: titleText !== "" ? titleText : cardMainTitleFor(modelData)
            readonly property string effectiveSubtitleText: subtitleText !== "" ? subtitleText : cardSubtitleTitleFor(modelData)
            // Garde de vie delegate : les Qt.callLater du marquee peuvent revenir
            // après recyclage/destruction du delegate sur Freebox.
            property bool _alive: true
            Component.onDestruction: { _alive = false }
        Component {
            id: musicNoteComp
            Item {
                anchors.fill: parent
                Rectangle { anchors.fill: parent; color: "#2e3355" }
                Text {
                    anchors.centerIn: parent
                    text: "♪"
                    color: "#cfd6ff"
                    font.pixelSize: Math.round(Math.min(parent.width, parent.height) * 0.42)
                    font.bold: true
                    opacity: 0.95
                }
            }
        }
        Component {
            id: videoLogoComp
            Item {
                anchors.fill: parent
                Rectangle { anchors.fill: parent; color: "#2e3355" }
                Rectangle {
                    width: parent.width * 0.72
                    height: parent.height * 0.56
                    radius: Math.round(Math.min(width, height) * 0.10)
                    anchors.centerIn: parent
                    color: "transparent"
                    border.color: "#cfd6ff"
                    border.width: Math.max(2, Math.round(Math.min(parent.width, parent.height) * 0.04))
                    opacity: 0.95
                }
                Text {
                    anchors.centerIn: parent
                    text: "▶"
                    color: "#cfd6ff"
                    font.pixelSize: Math.round(Math.min(parent.width, parent.height) * 0.34)
                    opacity: 0.95
                }
            }
        }

        Component {
            id: clapperboardFallbackComp
            Item {
                anchors.fill: parent
                Rectangle { anchors.fill: parent; color: "#262a39" }
                Canvas {
                    anchors.centerIn: parent
                    width: 74
                    height: 62
                    antialiasing: false
                    onPaint: {
                        var c = getContext("2d")
                        c.reset()
                        c.clearRect(0, 0, width, height)
                        c.fillStyle = "#77819d"
                        c.fillRect(8, 20, 58, 35)
                        c.fillStyle = "#9aa3bd"
                        c.beginPath()
                        c.moveTo(8, 20)
                        c.lineTo(18, 7)
                        c.lineTo(68, 7)
                        c.lineTo(58, 20)
                        c.closePath()
                        c.fill()
                        c.strokeStyle = "#2a2f4f"
                        c.lineWidth = 3
                        for (var x = 19; x < 60; x += 14) {
                            c.beginPath()
                            c.moveTo(x, 8)
                            c.lineTo(x - 8, 19)
                            c.stroke()
                        }
                    }
                }
            }
        }

        Component {
            id: filmstripFallbackComp
            Item {
                anchors.fill: parent
                Rectangle { anchors.fill: parent; color: "#2a2f4f" }
                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: Math.max(10, Math.round(parent.width * 0.12))
                    color: "#202444"
                }
                Repeater {
                    model: 7
                    delegate: Rectangle {
                        width: Math.max(4, Math.round(parent.width * 0.05))
                        height: Math.max(6, Math.round(parent.height * 0.06))
                        radius: 2
                        color: "#39405f"
                        x: Math.round(parent.width * 0.035)
                        y: Math.round((index + 1) * (parent.height / 8) - height / 2)
                    }
                }
                Text {
                    anchors.centerIn: parent
                    text: "\u25B6"
                    textFormat: Text.PlainText
                    color: "#E7ECFF"
                    font.pixelSize: Math.round(parent.height * 0.34)
                    opacity: 0.95
                }
                Text {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.rightMargin: 10
                    anchors.bottomMargin: 8
                    text: (cardRoot.modelData && cardRoot.modelData.ProductionYear)
                          ? String(cardRoot.modelData.ProductionYear) : ""
                    textFormat: Text.PlainText
                    color: "#b9c0ff"
                    font.pixelSize: 14
                    visible: text.length > 0
                }
            }
        }

        Component {
            id: seriesFallbackComp
            Item {
                anchors.fill: parent
                Rectangle { anchors.fill: parent; color: "#2a2f4f" }
                Item {
                    anchors.centerIn: parent
                    width: parent.width * 0.72
                    height: parent.height * 0.62
                    Rectangle {
                        width: parent.width * 0.44
                        height: width
                        radius: width / 2
                        color: "#9aa3bd"
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 0
                    }
                    Rectangle {
                        width: parent.width * 0.78
                        height: parent.height * 0.58
                        radius: Math.min(width, height) * 0.22
                        color: "#7d86a4"
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: parent.height * 0.38
                    }
                }
            }
        }
        Component {
            id: folderFallbackComp
            Item {
                anchors.fill: parent
                Rectangle { anchors.fill: parent; color: "#2e3355" }
                Rectangle {
                    width: parent.width * 0.55
                    height: parent.height * 0.18
                    anchors.left: parent.left
                    anchors.leftMargin: parent.width * 0.10
                    anchors.top: parent.top
                    anchors.topMargin: parent.height * 0.18
                    radius: 4
                    color: "#cfd6ff"
                    opacity: 0.18
                }
                Rectangle {
                    width: parent.width * 0.78
                    height: parent.height * 0.52
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: parent.height * 0.32
                    radius: 10
                    color: "transparent"
                    border.color: "#cfd6ff"
                    border.width: Math.max(2, Math.round(Math.min(parent.width, parent.height) * 0.04))
                    opacity: 0.75
                }
            }
        }
            width: tileWidth + sidePad * 2
            height: tileHeight + titleHeight + topPad
            Item {
                id: visual
                width: tileWidth
                height: tileHeight
                anchors.top: parent.top
                anchors.topMargin: topPad
                anchors.horizontalCenter: parent.horizontalCenter
                transformOrigin: Item.Bottom
                scale: 1.0
                transform: Translate {
                    x: 0
                    y: cardRoot._focusVisualActive() ? -cardRoot.focusLiftPx : 0
                    Behavior on y {
                        enabled: cardRoot.allowAnims
                        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -3
                    color: "#ffffff"
                    opacity: cardRoot.selected ? 0.06 : 0.0
                    radius: 0
                    visible: opacity > 0.0
                    Behavior on opacity {
                        enabled: cardRoot.allowAnims
                        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                    }
                }
                property bool _hasPotentialImg: false
                property bool _imgError: false
                property bool _stablePreserveAspectFit: false
                readonly property bool _needFallback: !visual._hasPotentialImg
                                                      || (cardRoot.fallbackOnImageError && visual._imgError)
                readonly property bool _useMusicFallback: cardRoot.musicFallback && visual._needFallback
                readonly property bool _useNonMusicFallback: !cardRoot.musicFallback && visual._needFallback
                readonly property bool _useClapperboardFallback: visual._useNonMusicFallback && cardRoot.fallbackWantsClapperboard()
                readonly property bool _useFilmstripFallback: visual._useNonMusicFallback && !visual._useClapperboardFallback && cardRoot.fallbackWantsFilmstrip()
                readonly property bool _useGlyphFallback: visual._useNonMusicFallback && !visual._useClapperboardFallback && !visual._useFilmstripFallback && cardRoot.fallbackGlyph.length > 0
                readonly property bool _useVideoFallback: visual._useNonMusicFallback && !visual._useFilmstripFallback && !visual._useGlyphFallback && !cardRoot.fallbackWantsSeries() && (cardRoot.fallbackWantsVideo() || cardRoot.isVideoLikeSafe(cardRoot.modelData))
                readonly property bool _useSeriesFallback: visual._useNonMusicFallback && !visual._useFilmstripFallback && !visual._useGlyphFallback && cardRoot.fallbackWantsSeries()
                readonly property bool _useFolderFallback: visual._useNonMusicFallback && !visual._useFilmstripFallback && !visual._useGlyphFallback && !visual._useSeriesFallback && (cardRoot.fallbackWantsFolder() || cardRoot.isFolderLikeSafe(cardRoot.modelData))
                readonly property real _progressRatio: cardRoot.showProgress ? cardRoot.resumeRatioSafe(cardRoot.modelData) : 0
                property string _stableSource: ""
                property string _stableKey: ""
                property string _requestKey: ""
                property string _stableImageId: ""
                property string _stableImageType: ""
                property string _stableImageTag: ""

                function _syncStableSource() {
                    try {
                        var key = cardRoot._cardIdentityKey(cardRoot.modelData)
                        if (key !== _stableKey) {
                            _stableKey = key
                            _stableSource = ""
                            _requestKey = ""
                            _stableImageId = ""
                            _stableImageType = ""
                            _stableImageTag = ""
                            _imgError = false
                        }
                        var spec = null
                        if (cardRoot.useImageSourceOverride) {
                            var directUrl = String(cardRoot.imageSourceOverride || "")
                            spec = ({ url: directUrl, potential: directUrl.length > 0, fit: false,
                                      id: "", type: "", tag: "" })
                        } else {
                            spec = cardRoot._resolveImageSpec(cardRoot.modelData)
                        }
                        _hasPotentialImg = spec && spec.potential === true
                        _stablePreserveAspectFit = !!(spec && spec.fit === true)
                        var url = spec && spec.url ? String(spec.url) : ""
                        var nextImageId = spec && spec.id ? String(spec.id) : ""
                        var nextImageType = spec && spec.type ? String(spec.type) : ""
                        var nextImageTag = spec && spec.tag ? String(spec.tag) : ""
                        if (cardRoot.allowLoad && url) {
                            if (_stableSource !== url || _requestKey !== _stableKey) {
                                _stableImageId = nextImageId
                                _stableImageType = nextImageType
                                _stableImageTag = nextImageTag
                                _stableSource = url
                                _requestKey = _stableKey
                                _imgError = false
                            }
                        } else if (!cardRoot.allowLoad || !_hasPotentialImg) {
                            // Un simple gel du binding conserverait encore la texture et
                            // sa requête. Vider réellement source libère le décodage/cache
                            // QML lorsque Home passe sous Search ou qu'un rail est éloigné.
                            _stableSource = ""
                            _requestKey = ""
                            _stableImageId = ""
                            _stableImageType = ""
                            _stableImageTag = ""
                            _imgError = false
                        }
                    } catch(e) {}
                }
                function requestImageSync() {
                    if (!cardRoot._homeSyncing)
                        visual._syncStableSource()
                }
                Component.onCompleted: visual.requestImageSync()
                Connections {
                    target: cardRoot
                    ignoreUnknownSignals: true
                    function onHomeSyncCommitted() { visual._syncStableSource() }
                    function onAllowLoadChanged() { visual.requestImageSync() }
                    function onModelDataChanged() { visual.requestImageSync() }
                    function onTileWidthChanged() { visual.requestImageSync() }
                    function onTileHeightChanged() { visual.requestImageSync() }
                    function onImageRequestWidthChanged() { visual.requestImageSync() }
                    function onImageRequestHeightChanged() { visual.requestImageSync() }
                    function onPosterQualityChanged() { visual.requestImageSync() }
                    function onPreferBackdropChanged() { visual.requestImageSync() }
                    function onImagePolicyChanged() { visual.requestImageSync() }
                    function onControllerChanged() { visual.requestImageSync() }
                    function onUseImageSourceOverrideChanged() { visual.requestImageSync() }
                    function onImageSourceOverrideChanged() { visual.requestImageSync() }
                }
                Connections {
                    target: cardRoot.controller
                    ignoreUnknownSignals: true
                    function onServerUrlChanged() { visual.requestImageSync() }
                    function onPosterQFastChanged() { visual.requestImageSync() }
                    function onPosterScaleChanged() { visual.requestImageSync() }
                }
        Rectangle {
            anchors.fill: parent
            color: "#1f233a"
            visible: visual._hasPotentialImg
                     && !visual._useMusicFallback
                     && !visual._useClapperboardFallback
                     && !visual._useFilmstripFallback
                     && !visual._useGlyphFallback
                     && !visual._useVideoFallback
                     && !visual._useSeriesFallback
                     && !visual._useFolderFallback
                     && (posterImg.status !== Image.Ready
                         || visual._stablePreserveAspectFit)
        }
        Image {
            id: posterImg
            anchors.fill: parent
            fillMode: visual._stablePreserveAspectFit ? Image.PreserveAspectFit : Image.PreserveAspectCrop
            asynchronous: true
            cache: cardRoot.imageCache
            // Freebox: le cache reste désactivé par défaut sur une card recyclée.
            mipmap: false
            smooth: cardRoot.smoothImages
            source: visual._stableSource ? visual._stableSource : ""
            visible: !visual._useMusicFallback && !visual._useClapperboardFallback
                     && !visual._useFilmstripFallback && !visual._useGlyphFallback
                     && !visual._useVideoFallback && !visual._useSeriesFallback && !visual._useFolderFallback
                     && source !== ""
            opacity: status === Image.Ready ? 1.0 : 0.0
            Behavior on opacity {
                enabled: cardRoot.allowAnims
                NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
            }
            onStatusChanged: {
                // Un Loader recyclé peut encore recevoir le statut terminal de l'ancienne
                // requête. Ne jamais appliquer cette erreur à la nouvelle carte.
                var sourceMatches = String(source || "") === String(visual._stableSource || "")
                var keyMatches = visual._requestKey !== "" && visual._requestKey === visual._stableKey
                if (status === Image.Error) {
                    if (sourceMatches && keyMatches) {
                        visual._imgError = true

                        // SearchPage mémorise uniquement les Thumb en 404/erreur.
                        // PosterGridCard reste générique : si le contrôleur n'expose
                        // pas ce contrat, aucun cache négatif n'est utilisé.
                        var marked = cardRoot._markImageVariantUnavailable(
                                    visual._stableImageId,
                                    visual._stableImageType,
                                    visual._stableImageTag)
                        if (marked) {
                            Qt.callLater(function() {
                                if (cardRoot._alive)
                                    visual._syncStableSource()
                            })
                        }
                    }
                } else if (status === Image.Ready) {
                    if (sourceMatches && keyMatches) {
                        visual._imgError = false
                    }
                }
            }
        }
        Loader {
            id: posterHqLoader
            anchors.fill: parent
            // L'image HQ remplace uniquement la texture du poster. Elle doit rester
            // sous les overlays, badges et surtout sous le cadre blanc de focus.
            // Un z positif ici recouvrait le cadre quelques centaines de ms après
            // l'arrivée du focus, exactement au moment où le HQ devenait Ready.
            z: posterImg.z

            // Une Image HQ n'est plus instanciée dans chaque delegate de bibliothèque.
            // Le Loader ne crée l'objet que pour la carte qui a réellement une source HQ.
            readonly property string requestedSource: posterImg.status === Image.Ready
                                                      ? (cardRoot.useImageSourceOverride
                                                         ? String(cardRoot.hqImageSourceOverride || "")
                                                         : (cardRoot.hqPosterActive ? cardRoot._hqImageSource() : ""))
                                                      : ""
            active: requestedSource !== ""
            visible: active

            sourceComponent: Component {
                Image {
                    anchors.fill: parent
                    fillMode: visual._stablePreserveAspectFit ? Image.PreserveAspectFit : Image.PreserveAspectCrop
                    asynchronous: true
                    cache: false
                    mipmap: false
                    smooth: cardRoot.smoothImages
                    source: posterHqLoader.requestedSource
                    visible: status === Image.Ready
                    opacity: status === Image.Ready ? 1.0 : 0.0
                    Behavior on opacity {
                        enabled: cardRoot.allowAnims
                        NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
                    }
                }
            }
        }
                Loader { anchors.fill: parent; active: visual._useMusicFallback;       visible: active; sourceComponent: musicNoteComp }
                Loader { anchors.fill: parent; active: visual._useClapperboardFallback; visible: active; sourceComponent: clapperboardFallbackComp }
                Loader { anchors.fill: parent; active: visual._useFilmstripFallback;    visible: active; sourceComponent: filmstripFallbackComp }
                Item {
                    anchors.fill: parent
                    visible: visual._useGlyphFallback
                    Rectangle { anchors.fill: parent; color: "#2a2f4f" }
                    Text {
                        anchors.centerIn: parent
                        text: cardRoot.fallbackGlyph
                        textFormat: Text.PlainText
                        color: "#E7ECFF"
                        font.pixelSize: Math.round(parent.height * cardRoot.fallbackGlyphScale)
                        opacity: 0.95
                    }
                }
                Loader { anchors.fill: parent; active: visual._useVideoFallback;  visible: active; sourceComponent: videoLogoComp }
                Loader { anchors.fill: parent; active: visual._useSeriesFallback; visible: active; sourceComponent: seriesFallbackComp }
                Loader { anchors.fill: parent; active: visual._useFolderFallback; visible: active; sourceComponent: folderFallbackComp }
                Item {
                    z: 18
                    anchors.centerIn: parent
                    width: Math.round(parent.width * 0.58)
                    height: Math.round(parent.height * 0.28)
                    visible: cardRoot.showFolderIndicator && visual._needFallback
                    Rectangle {
                        x: 0; y: 0
                        width: Math.round(parent.width * 0.44)
                        height: Math.round(parent.height * 0.24)
                        radius: 4
                        color: "#B7C2EA"
                    }
                    Rectangle {
                        x: 0
                        y: Math.round(parent.height * 0.15)
                        width: parent.width
                        height: Math.round(parent.height * 0.78)
                        radius: 7
                        color: "#7D8EC8"
                        border.width: 1
                        border.color: "#D6DDF7"
                    }
                }
                Rectangle {
                    z: 18
                    width: 42
                    height: 42
                    radius: 21
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: 8
                    anchors.bottomMargin: 8
                    color: Qt.rgba(0.02, 0.025, 0.04, 0.82)
                    border.width: 1
                    border.color: "#CCFFFFFF"
                    visible: cardRoot.showVideoIndicator
                    Canvas {
                        anchors.centerIn: parent
                        width: 15
                        height: 18
                        onPaint: {
                            var c = getContext("2d")
                            c.clearRect(0, 0, width, height)
                            c.fillStyle = "#FFFFFF"
                            c.beginPath()
                            c.moveTo(2, 1)
                            c.lineTo(14, 9)
                            c.lineTo(2, 17)
                            c.closePath()
                            c.fill()
                        }
                    }
                }
                Rectangle {
                    // Toujours au-dessus des textures standard/HQ, mais sous les badges
                    // explicites (z >= 18). Le cadre ne peut plus être recouvert par le HQ.
                    z: 10
                    anchors.fill: parent
                    radius: 0
                    color: "transparent"
                    border.color: "#FFFFFF"
                    border.width: cardRoot.frameWidth
                    antialiasing: false
                    opacity: cardRoot.selected ? 1.0 : 0.0
                    Behavior on opacity {
                        enabled: cardRoot.allowAnims
                        NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
                    }
                }
                Rectangle {
                    z: 20
                    height: 24
                    radius: 12
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.topMargin: 6
                    anchors.rightMargin: 6
                    color: "#3B82F6"
                    border.color: "#1E3A8A"
                    border.width: 1
                    visible: cardRoot.showUnplayedBadge && cardRoot.unplayedCount > 0
                    width: Math.max(height, unplayedBadgeText.paintedWidth + 12)
                    Text {
                        id: unplayedBadgeText
                        anchors.centerIn: parent
                        text: cardRoot.unplayedText
                        color: "white"
                        font.pixelSize: 13
                        font.bold: true
                    }
                }
                Rectangle {
                    z: 20
                    width: cardRoot.watchedBadgeSize
                    height: cardRoot.watchedBadgeSize
                    radius: width / 2
                    x: cardRoot.watchedBadgePosition === "topLeft"
                       ? cardRoot.watchedBadgeMargin
                       : parent.width - width - cardRoot.watchedBadgeMargin
                    y: cardRoot.watchedBadgeMargin
                    color: "#3B82F6"
                    border.color: "#1E3A8A"
                    border.width: 1
                    visible: cardRoot.showWatchedBadge && cardRoot.watched
                             && (!cardRoot.suppressWatchedWhenUnplayed
                                 || !(cardRoot.showUnplayedBadge && cardRoot.unplayedCount > 0))
                    Item {
                        anchors.centerIn: parent
                        width: 15
                        height: 12
                        Rectangle { x: 2.1; y: 6.6; width: 5.4; height: 2.1; radius: 1.05; color: "#FFFFFF"; rotation: 42; transformOrigin: Item.Left; antialiasing: true }
                        Rectangle { x: 5.8; y: 9.1; width: 8.6; height: 2.1; radius: 1.05; color: "#FFFFFF"; rotation: -42; transformOrigin: Item.Left; antialiasing: true }
                        Rectangle { x: 5.1; y: 8.1; width: 2.0; height: 2.0; radius: 1.0; color: "#FFFFFF"; antialiasing: true }
                    }
                }
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: cardRoot.progressSideInsetOverride >= 0
                                        ? cardRoot.progressSideInsetOverride : 10
                    anchors.rightMargin: anchors.leftMargin
                    anchors.bottomMargin: cardRoot.progressBottomMarginOverride >= 0
                                          ? cardRoot.progressBottomMarginOverride : 10
                    height: cardRoot.progressHeightOverride > 0
                            ? cardRoot.progressHeightOverride : 6
                    radius: cardRoot.progressRadiusOverride >= 0
                            ? cardRoot.progressRadiusOverride
                            : Math.max(0, Math.round(height / 2))
                    color: cardRoot.progressTrackColorOverride.length > 0
                           ? cardRoot.progressTrackColorOverride : "#2a2f4f"
                    visible: visual._progressRatio > 0
                    Rectangle {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        height: parent.height
                        width: Math.max(cardRoot.progressMinWidthOverride >= 0
                                        ? cardRoot.progressMinWidthOverride : 6,
                                        parent.width * visual._progressRatio)
                        radius: parent.radius
                        color: cardRoot.progressFillColorOverride.length > 0
                               ? cardRoot.progressFillColorOverride : "#6e7bf4"
                    }
                }
            }

            // Utilisé uniquement par le curtain Home lors d'un retour externe.
            // Une carte est prête si son image est réellement disponible ou si son
            // fallback définitif est déjà connu.
            readonly property bool homeVisualReady: {
                if (!homeDelegateMode || !allowLoad || !modelData)
                    return true
                if (!visual._hasPotentialImg || visual._imgError)
                    return true
                if (visual._stableSource === "")
                    return false
                return posterImg.status === Image.Ready || posterImg.status === Image.Error
            }

            // Prêt pour les curtains des pages bibliothèque, indépendamment du mode Home.
            readonly property bool visualReady: !allowLoad || !visual._hasPotentialImg || visual._imgError
                                                || posterImg.status === Image.Ready
                                                || posterImg.status === Image.Error

            // Le moteur de texte/marquee est instancié uniquement quand une carte
            // affiche réellement du texte. Les grilles bibliothèque (titleHeight=0)
            // évitent ainsi OpacityMask/animations inutiles sur chaque delegate.
            // Chargement explicite : qml/pages est servi en HTTP sur Freebox et
            // son qmldir n'est pas garanti. Ne pas dépendre de la résolution
            // implicite du type PosterCardTitleLayer.
            Loader {
                id: titleLayerLoader
                active: cardRoot.titleHeight > 0
                asynchronous: false
                source: active ? Qt.resolvedUrl("PosterCardTitleLayer.qml") : ""
                width: cardRoot.tileWidth
                height: cardRoot.titleHeight
                anchors.top: visual.bottom
                anchors.topMargin: cardRoot.titleTopMargin
                anchors.horizontalCenter: visual.horizontalCenter

                onLoaded: {
                    if (item)
                        item.card = cardRoot
                }
            }

            MouseArea {
                anchors.fill: parent
                enabled: cardRoot.homeDelegateMode && cardRoot.enableMouseInput
                hoverEnabled: cardRoot.hoverSelectEnabled
                onEntered: cardRoot.hovered()
                onClicked: cardRoot.activated()
                onDoubleClicked: cardRoot.doubleActivated()
            }
            SequentialAnimation {
                id: scaleIn
                running: false
                PropertyAnimation { target: visual; property: "scale"; to: cardRoot.zoomScale; duration: 120; easing.type: Easing.OutCubic }
                PropertyAnimation { target: visual; property: "scale"; to: (cardRoot.zoomScale - 0.02); duration: 90; easing.type: Easing.OutCubic }
            }
            NumberAnimation {
                id: scaleOut
                target: visual
                property: "scale"
                to: 1.0
                duration: 130
                easing.type: Easing.OutCubic
                running: false
            }
            // Home/Search suivent le signal du contrôleur pour couper immédiatement
            // une animation devenue indésirable pendant un défilement.
            Connections {
                target: cardRoot.controller
                ignoreUnknownSignals: true
                onAllowAnimsChanged: {
                    if (cardRoot.allowAnims) return
                    scaleIn.stop()
                    scaleOut.stop()
                    visual.scale = cardRoot._focusVisualActive() ? (cardRoot.zoomScale - 0.02) : 1.0
                }
            }
            onSuppressFocusTransformChanged: {
                scaleIn.stop()
                scaleOut.stop()
                if (!cardRoot.allowAnims) {
                    visual.scale = cardRoot._focusVisualActive() ? (cardRoot.zoomScale - 0.02) : 1.0
                    return
                }
                if (cardRoot._focusVisualActive()) scaleIn.start()
                else scaleOut.start()
            }
            onSelectedChanged: {
                var titleLayer = titleLayerLoader.item
                if (titleLayer && titleLayer._requestUpdateMarquee)
                    titleLayer._requestUpdateMarquee()
                if (!cardRoot.allowAnims) {
                    scaleIn.stop()
                    scaleOut.stop()
                    visual.scale = cardRoot._focusVisualActive() ? (cardRoot.zoomScale - 0.02) : 1.0
                    return
                }
                if (cardRoot._focusVisualActive()) { scaleOut.stop(); scaleIn.start() }
                else { scaleIn.stop(); scaleOut.start() }
            }
        }
