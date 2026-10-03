.pragma library
.import "MediaCatalog.js" as MediaCatalog

// Géométrie et présentation des rails Home/Recherche, sans état QML.
// Les pages conservent le focus, les animations et le chargement réseau.

/* ------------------------------------------------------------------------- */
/* Projections de cartes Home et Search                                      */
/* ------------------------------------------------------------------------- */

function trimObjectMemo(memo, maxEntries) {
    var source = memo || ({});
    var keys = Object.keys(source);
    var limit = Math.max(1, Number(maxEntries) | 0);
    if (keys.length <= limit) return source;
    var out = ({});
    var start = Math.max(0, keys.length - limit);
    for (var i = start; i < keys.length; ++i) out[keys[i]] = source[keys[i]];
    return out;
}

function homeCardUsesLandscape(item, sectionKind) {
    var kind = MediaCatalog.safeString(sectionKind).toLowerCase();
    if (kind === "nextup") return true;
    if (kind === "latest-series") return false;
    if (!item || item.IsFolder === true) return true;
    var type = MediaCatalog.itemTypeLower(item);
    if (type === "episode" || type === "video" || type === "musicvideo" || type === "trailer")
        return true;
    if (type.indexOf("folder") >= 0 || type === "collectionfolder" || type === "userview")
        return true;
    return MediaCatalog.safeString(item.CollectionType) !== "" && type !== "movie" && type !== "series";
}

function homeCardTileWidthFor(item, sectionKind, portraitWidth, landscapeWidth) {
    return homeCardUsesLandscape(item, sectionKind) ? landscapeWidth : portraitWidth;
}

function homeCardSidePadFor(item, sectionKind, portraitPad, landscapePad) {
    return homeCardUsesLandscape(item, sectionKind) ? landscapePad : portraitPad;
}

function homeCardFocusBleedFor(item, sectionKind, portraitBleed, landscapeBleed) {
    return homeCardUsesLandscape(item, sectionKind) ? landscapeBleed : portraitBleed;
}

function homeCardPrefersBackdrop(item, sectionKind) {
    var kind = MediaCatalog.safeString(sectionKind).toLowerCase();
    return kind !== "nextup" && homeCardUsesLandscape(item, kind);
}

function homeCardFallbackKind(item, sectionKind) {
    var kind = MediaCatalog.safeString(sectionKind).toLowerCase();
    if (kind === "library") return "folder";
    if (kind === "nextup") return "series";
    var type = MediaCatalog.itemTypeLower(item);
    if (type === "series" || type === "season") return "series";
    if (type === "episode") return "episode";
    if (type === "movie") return "movie";
    return homeCardUsesLandscape(item, kind) ? "video" : "";
}

function prepareHomeRowMetrics(items, sectionKind, layout) {
    var list = items || [];
    var cfg = layout || ({});
    var x = 0;
    for (var i = 0; i < list.length; ++i) {
        var item = list[i];
        if (!item) continue;
        var tileWidth = homeCardTileWidthFor(item, sectionKind,
                                             Number(cfg.portraitWidth || 0),
                                             Number(cfg.landscapeWidth || 0));
        var sidePad = homeCardSidePadFor(item, sectionKind,
                                         Number(cfg.portraitSidePad || 0),
                                         Number(cfg.landscapeSidePad || 0));
        var width = tileWidth + sidePad * 2;
        item._pgDelegateWidth = width;
        item._pgFocusBleed = homeCardFocusBleedFor(item, sectionKind,
                                                   Number(cfg.portraitFocusBleed || 0),
                                                   Number(cfg.landscapeFocusBleed || 0));
        item._pgRowLeft = x;
        x += width + Number(cfg.spacing || 0);
    }
    return list;
}

// Projection des rails récents : la classification reste dans MediaCatalog,
// les métriques de cartes sont calculées ici avec les autres rails Home.
function prepareHomeLatestGroups(groups, layout) {
    groups = MediaCatalog.safeArray(groups);
    var out = [];
    for (var i = 0; i < groups.length; ++i) {
        var group = groups[i];
        if (!group || MediaCatalog.isKnownUnsupportedLibraryFolder(group)) continue;
        var prepared = MediaCatalog.shallowCloneObject(group);
        var sectionKind = MediaCatalog.isSeriesLibraryFolder(prepared) ? "latest-series" : "latest";
        prepared._pgSectionKind = sectionKind;
        prepared.items = prepareHomeRowMetrics(MediaCatalog.safeArray(group.items), sectionKind, layout);
        out.push(prepared);
    }
    return out;
}

function homeRowItemWidthAt(items, index, sectionKind, layout) {
    var item = items && index >= 0 && index < items.length ? items[index] : null;
    var cached = Number(item && item._pgDelegateWidth || 0);
    if (cached > 0) return cached;
    if (!item) return 0;
    var cfg = layout || ({});
    return homeCardTileWidthFor(item, sectionKind, Number(cfg.portraitWidth || 0),
                                Number(cfg.landscapeWidth || 0))
         + homeCardSidePadFor(item, sectionKind, Number(cfg.portraitSidePad || 0),
                              Number(cfg.landscapeSidePad || 0)) * 2;
}

function homeRowItemBleedAt(items, index, sectionKind, layout) {
    var item = items && index >= 0 && index < items.length ? items[index] : null;
    var cached = Number(item && item._pgFocusBleed || 0);
    if (cached > 0) return cached;
    if (!item) return 0;
    var cfg = layout || ({});
    return homeCardFocusBleedFor(item, sectionKind, Number(cfg.portraitFocusBleed || 0),
                                 Number(cfg.landscapeFocusBleed || 0));
}

function homeRowItemLeftAt(items, index, sectionKind, spacing, layout) {
    if (!items || index <= 0) return 0;
    if (index < items.length && items[index] && items[index]._pgRowLeft !== undefined)
        return Number(items[index]._pgRowLeft || 0);
    var x = 0;
    for (var i = 0; i < Math.min(index, items.length); ++i)
        x += homeRowItemWidthAt(items, i, sectionKind, layout) + Number(spacing || 0);
    return x;
}

function homeRowLogicalWidth(items, sectionKind, spacing, edgePad, viewportWidth, layout) {
    if (!items || items.length === 0) return viewportWidth;
    var last = items.length - 1;
    var total = Number(edgePad || 0) * 2
              + homeRowItemLeftAt(items, last, sectionKind, spacing, layout)
              + homeRowItemWidthAt(items, last, sectionKind, layout);
    return Math.max(Number(viewportWidth || 0), total);
}

/* ------------------------------------------------------------------------- */
/* Géométrie pure des rails QML                                              */
/* ------------------------------------------------------------------------- */

function searchRowItemWidthAt(items, index) {
    var item = items && index >= 0 && index < items.length ? items[index] : null;
    return Math.max(0, Number(item && item._searchDelegateWidth || 0));
}

function searchRowItemLeftAt(items, index) {
    var item = items && index >= 0 && index < items.length ? items[index] : null;
    return Math.max(0, Number(item && item._searchRowLeft || 0));
}

function searchRowItemBleedAt(items, index) {
    var item = items && index >= 0 && index < items.length ? items[index] : null;
    return Math.max(0, Number(item && item._searchFocusBleed || 0));
}

function searchRowLogicalWidth(items, spacing, edgePad, viewportWidth) {
    if (!items || items.length === 0) return Number(viewportWidth || 0);
    var last = items.length - 1;
    return Math.max(Number(viewportWidth || 0),
                    Number(edgePad || 0) * 2 + searchRowItemLeftAt(items, last)
                    + searchRowItemWidthAt(items, last));
}

function searchRowMinX(edgePad) {
    return -Math.max(0, Number(edgePad || 0));
}

function rowMaxX(minimum, logicalContentWidth, viewportWidth) {
    var minX = Number(minimum || 0);
    return Math.max(minX, minX + Math.max(0, Number(logicalContentWidth || 0))
                    - Math.max(0, Number(viewportWidth || 0)));
}

function rowClampX(value, minimum, maximum) {
    var minX = Number(minimum || 0);
    var maxX = Math.max(minX, Number(maximum || minX));
    var x = Number(value || 0);
    if (!isFinite(x) || isNaN(x)) x = minX;
    return Math.max(minX, Math.min(maxX, x));
}

// Géométrie QML commune aux rails Home. Les appels itemAtIndex/mapToItem restent
// ici car ils décrivent le layout du rail, sans dépendre de l'état de navigation.
function nativeListMinX(list) {
    if (!list) return 0;
    var origin = Number(list.originX);
    if (isFinite(origin) && !isNaN(origin)) return origin;
    var content = Number(list.contentX);
    return (isFinite(content) && !isNaN(content)) ? content : 0;
}

function nativeListMaxX(list) {
    if (!list) return 0;
    var minimum = nativeListMinX(list);
    var contentWidth = Number(list.contentWidth);
    var viewportWidth = Number(list.width);
    if (!isFinite(contentWidth) || isNaN(contentWidth) || contentWidth < 0) contentWidth = 0;
    if (!isFinite(viewportWidth) || isNaN(viewportWidth) || viewportWidth < 0) viewportWidth = 0;
    return Math.max(minimum, minimum + Math.max(0, contentWidth - viewportWidth));
}

function nativeListClampX(list, value) {
    if (!list) return 0;
    var x = Number(value);
    var minimum = nativeListMinX(list);
    if (!isFinite(x) || isNaN(x)) x = minimum;
    return Math.max(minimum, Math.min(nativeListMaxX(list), x));
}

function homeListMinX(list) {
    return list ? homeRowMinX(list.originX, list.edgePad) : 0;
}

function homeListMaxX(list) {
    if (!list) return 0;
    var minimum = homeListMinX(list);
    return rowMaxX(minimum, list.logicalContentWidth, list.width);
}

function homeListClampX(list, value) {
    if (!list) return 0;
    return rowClampX(value, homeListMinX(list), homeListMaxX(list));
}

function homeRowRealDelegateGeometry(list, index) {
    if (!list || index < 0) return null;
    var delegateItem = null;
    try {
        if (list.itemAtIndex) delegateItem = list.itemAtIndex(index);
    } catch(e0) {}
    if (!delegateItem) return null;

    try {
        var point = delegateItem.mapToItem(list, 0, 0);
        var viewportX = Number(point ? point.x : NaN);
        var viewportY = Number(point ? point.y : NaN);
        var width = Number(delegateItem.width);
        var height = Number(delegateItem.height);
        var contentX = Number(list.contentX || 0);
        var contentLeft = Number(delegateItem.x);
        if (!isFinite(viewportX) || isNaN(viewportX) || !isFinite(width) || isNaN(width) || width <= 0)
            return null;
        return {
            item: delegateItem,
            viewportX: viewportX,
            viewportY: (isFinite(viewportY) && !isNaN(viewportY)) ? viewportY : 0,
            width: width,
            height: (isFinite(height) && !isNaN(height)) ? height : 0,
            contentX: contentX,
            contentLeft: (isFinite(contentLeft) && !isNaN(contentLeft)) ? contentLeft : (contentX + viewportX)
        };
    } catch(e1) {
        return null;
    }
}

// Géométrie commune aux rails Home et Search ; chaque rail garde son propre
// calcul de largeur, de marge et de bornes.
function _rowRevealX(left, width, bleed, current, viewportWidth, padding, minimum, maximum) {
    var visualLeft = left - bleed;
    var visualRight = left + width + bleed;
    var target = current;

    if (visualLeft < current + padding) target = visualLeft - padding;
    else if (visualRight > current + viewportWidth - padding)
        target = visualRight - viewportWidth + padding;

    return rowClampX(target, minimum, maximum);
}

function searchRowTargetX(items, index, contentX, viewportWidth, edgePad, logicalContentWidth, padding) {
    var minX = searchRowMinX(edgePad);
    var maxX = rowMaxX(minX, logicalContentWidth, viewportWidth);
    if (!items || index < 0 || index >= items.length) return minX;

    var left = searchRowItemLeftAt(items, index);
    var width = searchRowItemWidthAt(items, index);
    var bleed = searchRowItemBleedAt(items, index);
    var pad = Math.max(0, Number(padding || 0));
    var current = Number(contentX || 0);
    return _rowRevealX(left, width, bleed, current, Number(viewportWidth || 0),
                       pad, minX, maxX);
}

function homeRowMinX(originX, edgePad) {
    var ox = Number(originX);
    return isFinite(ox) && !isNaN(ox) ? ox : -Math.max(0, Number(edgePad || 0));
}

function homeRowTargetX(items, index, sectionKind, spacing, contentX, viewportWidth,
                        revealMargin, minimum, maximum, layout) {
    var minX = Number(minimum || 0);
    var maxX = Math.max(minX, Number(maximum || minX));
    if (!items || index < 0 || index >= items.length) return minX;

    var left = homeRowItemLeftAt(items, index, sectionKind, spacing, layout);
    var width = homeRowItemWidthAt(items, index, sectionKind, layout);
    var bleed = homeRowItemBleedAt(items, index, sectionKind, layout);
    var pad = Math.max(0, Number(revealMargin || 0));
    var current = Number(contentX || 0);
    return _rowRevealX(left, width, bleed, current, Number(viewportWidth || 0),
                       pad, minX, maxX);
}

function searchIsFolderType(typeName) {
    var type = MediaCatalog.safeString(typeName).toLowerCase();
    return type === "folder" || type === "collectionfolder" || type === "userview" ||
           type === "aggregatefolder" || type === "userrootfolder" ||
           type === "manualplaylistsfolder" || type === "playlistsfolder";
}

function searchIsMovieLike(item) {
    var type = MediaCatalog.itemTypeLower(item);
    return type === "movie" || type === "video" || type === "musicvideo";
}

function searchSectionKey(item) {
    var type = MediaCatalog.itemTypeLower(item);
    if (type === "series") return "series";
    if (type === "episode") return "episodes";
    if (searchIsMovieLike(item))
        return MediaCatalog.safeString(item && item._searchLibraryId) ? "library-only" : "movies";
    if (type === "boxset") return "collections";
    if (searchIsFolderType(type) || (item && item.IsFolder === true)) return "folders";
    return "others";
}

function searchSectionTitle(key) {
    if (key === "series") return "Séries";
    if (key === "episodes") return "Épisodes de séries";
    if (key === "movies") return "Films";
    if (key === "collections") return "Collections";
    return "Autres résultats";
}

function searchItemUsesFolderLayout(item) {
    return searchIsFolderType(MediaCatalog.itemTypeLower(item)) || !!(item && item.IsFolder === true);
}

function searchItemUsesLandscape(item, sectionKey) {
    if (sectionKey === "episodes") return true;
    if (sectionKey === "series" || sectionKey === "movies" || sectionKey === "collections") return false;
    if (searchItemUsesFolderLayout(item)) return true;
    var type = MediaCatalog.itemTypeLower(item);
    return type === "episode" || type === "video" || type === "musicvideo" || type === "trailer";
}

function searchItemLayout(item, sectionKey, layout) {
    var cfg = layout || ({});
    var folder = searchItemUsesFolderLayout(item);
    var landscape = searchItemUsesLandscape(item, sectionKey);
    var tileWidth = folder ? Number(cfg.libraryTileWidth || 0)
                           : (landscape ? Number(cfg.landscapeWidth || 0) : Number(cfg.portraitWidth || 0));
    var tileHeight = folder ? Number(cfg.libraryTileHeight || 0) : Number(cfg.portraitHeight || 0);
    var sidePad = (folder || landscape) ? Number(cfg.focusSidePad || 0)
                                       : Number(cfg.portraitSidePad || 0);
    var topPad = Math.ceil(tileHeight * (Number(cfg.zoomScale || 1) - 1))
               + Number(cfg.frameWidth || 0) + 2 + Number(cfg.focusLift || 0);
    var cardWidth = tileWidth + sidePad * 2;
    var cardHeight = tileHeight + Number(cfg.titleHeight || 0) + topPad;
    var focusBleed = Math.max(0, Math.ceil((tileWidth * (Number(cfg.zoomScale || 1) - 1)) * 0.5)
                                  + 3 - sidePad);
    return { tileWidth:tileWidth, tileHeight:tileHeight, sidePad:sidePad, topPad:topPad,
             cardWidth:cardWidth, cardHeight:cardHeight, focusBleed:focusBleed,
             landscape:landscape };
}

function prepareSearchSectionItems(items, sectionKey, layout) {
    var source = items || [], out = [], x = 0, maxHeight = 0, maxBleed = 0;
    for (var i = 0; i < source.length; ++i) {
        var original = source[i], item = {};
        if (original) {
            for (var key in original)
                if (Object.prototype.hasOwnProperty.call(original, key)) item[key] = original[key];
        }
        var metrics = searchItemLayout(item, sectionKey, layout);
        item._searchRowLeft = x;
        item._searchDelegateWidth = metrics.cardWidth;
        item._searchCardHeight = metrics.cardHeight;
        item._searchFocusBleed = metrics.focusBleed;
        item._searchTileW = metrics.tileWidth;
        item._searchTileH = metrics.tileHeight;
        item._searchSidePad = metrics.sidePad;
        item._searchTopPad = metrics.topPad;
        out.push(item);
        x += metrics.cardWidth + Number(layout && layout.spacing || 0);
        maxHeight = Math.max(maxHeight, metrics.cardHeight);
        maxBleed = Math.max(maxBleed, metrics.focusBleed);
    }
    return { items:out, cardHeight:maxHeight, edgePad:maxBleed + 14 };
}

function searchCardFallbackKind(item) {
    var type = MediaCatalog.itemTypeLower(item);
    if (type === "series") return "series";
    if (type === "episode") return "episode";
    if (type === "movie" || type === "video" || type === "musicvideo") return "movie";
    if (type === "boxset") return "collection";
    if (searchIsFolderType(type) || (item && item.IsFolder === true)) return "folder";
    return "video";
}
/* ===== Géométrie/focus partagés par les rails et fiches ===== */
function frameMargin(frameInsetPx, frameWidth, frameInnerEpsilon) {
    return Number(frameInsetPx || 0) + Number(frameWidth || 0) / 2
         + Number(frameInnerEpsilon || 0);
}

function focusTopPad(itemHeight, focusScale, focusLiftPx, frameWidth) {
    var h = Math.max(0, Number(itemHeight || 0));
    var scale = Math.max(1, Number(focusScale || 1));
    var lift = Math.max(0, Number(focusLiftPx || 0));
    var frame = Math.max(0, Number(frameWidth || 0));
    return Math.ceil(h * (scale - 1)) + lift + Math.ceil(frame) + 2;
}

function seasonsReframeTarget(metrics) {
    if (!metrics) return null;
    var itemHeight = Math.max(Number(metrics.itemImplicitHeight || 0),
                              Number(metrics.itemHeight || 0), 0);
    var loaderHeight = Math.max(Number(metrics.loaderHeight || 0), itemHeight, 140);
    var slotHeight = Math.max(Number(metrics.slotHeight || 0),
                              Number(metrics.slotImplicitHeight || 0), loaderHeight);
    var top = Math.min(Number(metrics.slotY || 0), Number(metrics.loaderY || 0));
    var bottom = Math.max(Number(metrics.slotY || 0) + slotHeight,
                          Number(metrics.loaderY || 0) + loaderHeight);
    var blockHeight = Math.max(1, bottom - top);
    var viewHeight = Number(metrics.viewHeight || 720);
    var contentY = Number(metrics.contentY || 0);
    var maxY = Math.max(0, Number(metrics.contentHeight || 0) - viewHeight);
    var topMargin = Number(metrics.topMargin || 0);
    var bottomMargin = Number(metrics.bottomMargin || 0);
    var relativeTop = top - contentY;
    var relativeBottom = bottom - contentY;
    var margin = blockHeight + topMargin + bottomMargin <= viewHeight ? topMargin : 24;
    var wanted = Math.max(0, Math.min(maxY, Math.round(top - margin)));
    var fullyVisible = relativeTop >= 0 && relativeBottom <= viewHeight;
    var tooLow = relativeTop > topMargin + 38;
    var cutBottom = relativeBottom > viewHeight - bottomMargin;
    var cutTop = relativeTop < 0;
    return { move:!fullyVisible || tooLow || cutBottom || cutTop, y:wanted };
}

function applyViewVirtualization(view) {
    if (!view) return;
    try { view.reuseItems = true; } catch (e0) {}
    try {
        var extent = Math.max(view.width | 0, view.height | 0);
        if (extent <= 0) extent = 720;
        view.cacheBuffer = Math.round(extent * 0.7);
    } catch (e1) {}
}

function applyBlockPerf(block) {
    if (!block) return;
    try { block.perfMode = true; } catch (e0) {}
    var keys = ["grid", "list", "view", "cards", "gridView", "listView"];
    for (var i = 0; i < keys.length; ++i) {
        try { applyViewVirtualization(block[keys[i]]); } catch (e1) {}
    }
}

function ensureItemVisible(flick, target, margin, animateWithScrollToY) {
    if (!flick || !target || target.visible === false) return false;
    var safeMargin = margin === undefined || margin === null ? 20 : Number(margin || 0);
    var point = target.mapToItem(flick.contentItem, 0, 0);
    var top = point.y - safeMargin;
    var bottom = point.y + target.height + safeMargin;
    var viewTop = flick.contentY;
    var viewBottom = flick.contentY + flick.height;
    var maxY = Math.max(0, flick.contentHeight - flick.height);
    var wanted = -1;
    if (top < viewTop) wanted = Math.max(0, top);
    else if (bottom > viewBottom) wanted = Math.max(0, Math.min(maxY, bottom - flick.height));
    if (wanted < 0) return false;
    if (animateWithScrollToY === true && typeof flick.scrollToY === "function")
        flick.scrollToY(wanted, true);
    else
        flick.contentY = wanted;
    return true;
}

function focusFirstSeason(block) {
    if (!block) return false;
    if (typeof block.forceFirstFocus === "function") block.forceFirstFocus();
    else if (block.grid && typeof block.grid.forceFirstFocus === "function") block.grid.forceFirstFocus();
    else return false;
    return true;
}

function restoreCastFocus(block) {
    if (!block) return false;
    if (typeof block.restoreLastActorFocus === "function") block.restoreLastActorFocus();
    else if (typeof block.focusFirstActor === "function") block.focusFirstActor();
    else if (typeof block.forceFirstActorFocus === "function") block.forceFirstActorFocus();
    else if (typeof block.focusLastActor === "function") block.focusLastActor();
    else return false;
    return true;
}

// Projection du bloc NextUp pour les métadonnées affichées par la fiche série.
function nextUpEpisodeFromBlock(block) {
    if (!block || block.hasContent === false) return null;
    var directKeys = ["currentItem", "currentEpisode", "episode", "nextUpItem", "nextUpEpisode", "item"];
    for (var i = 0; i < directKeys.length; ++i) {
        var key = directKeys[i];
        try {
            if (block[key]) return block[key];
        } catch (e0) {}
    }

    var index = block.currentIndex !== undefined ? (block.currentIndex | 0) : 0;
    var arrayKeys = ["items", "episodes", "nextUpItems"];
    for (var j = 0; j < arrayKeys.length; ++j) {
        try {
            var list = block[arrayKeys[j]];
            if (list && list.length !== undefined)
                return list[index] || list[0] || null;
        } catch (e1) {}
    }

    try {
        if (block.model) {
            if (typeof block.model.get === "function") return block.model.get(index);
            if (block.model.length !== undefined) return block.model[index] || block.model[0] || null;
        }
    } catch (e2) {}
    return null;
}
