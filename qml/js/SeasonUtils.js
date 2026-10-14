.pragma library

// Données des saisons et épisodes : tri, sélection, playlists et présentation.
// Les URL d’images reçoivent le bridge en paramètre ; aucun appel réseau.
// SeasonLoader orchestre le chargement ; les pages conservent leur focus/rendu.

// Domaine saisons/épisodes : ordre, disponibilité et playlists.
// Aucun accès réseau, aucune dépendance QML ou vers le bridge Jellyfin.

function slice(list, n) {
    if (!list || !list.length) return [];
    var k = Math.max(0, n | 0);
    return list.slice(0, k);
}
function idsFromEpisodes(list) {
    var ids = [];
    list = list || [];
    for (var i = 0; i < list.length; i++) {
        var e = list[i];
        if (e && (e.Id || e.id))
            ids.push(String(e.Id || e.id));
    }
    return ids;
}
function seasonPlaylistTitle(seasonItem, unknownSeasonNumber, sntSentinel) {
    var s = seasonItem || {}; var series = s.SeriesName || ""; var sIdx = (s.IndexNumber !== null && s.IndexNumber !== undefined)
             ? s.IndexNumber
             : null;
    var sName = s.Name || "";
    if (!s.Id && series) {
        var bucket = (unknownSeasonNumber !== sntSentinel) ? unknownSeasonNumber : null;
        return bucket !== null
             ? (series + " — Saison " + bucket + " (non liée)")
             : (series + " — Saison inconnue");
    }
    var t = series || sName;
    if (series && sIdx !== null)
        t = series + " — Saison " + sIdx;
    else if (series && sName && sName.toLowerCase() !== series.toLowerCase())
        t = series + " — " + sName;
    return t || "";
}
function indexFromPlaylistIfAny(playlist, list) {
    if (!playlist || !list || !list.length)
        return -1;
    var ids = idsFromEpisodes(list); var idx = -1;
    try {
        if (typeof playlist.index === "number" &&
            playlist.index >= 0 &&
            playlist.index < ids.length) {
            idx = playlist.index;
        }
    } catch (e) {}
    if (idx < 0) {
        var curId = "";
        try {
            if (playlist.currentItemId !== undefined && playlist.currentItemId) {
                curId = String(playlist.currentItemId);
            } else if (typeof playlist.getCurrentItemId === "function") {
                curId = String(playlist.getCurrentItemId() || "");
            }
        } catch (e2) {}
        if (curId) {
            var j = ids.indexOf(curId);
            if (j >= 0)
                idx = j;
        }
    }
    return idx;
}
function applyRestoreIndexIfAny(list, preselectEpisodeId, restoreEpisodeId, restoreIndex) {
    if (!list || !list.length)
        return -1;
    var i;
    var idx = -1;
    if (preselectEpisodeId) {
        for (i = 0; i < list.length; i++) {
            if (list[i] && list[i].Id === preselectEpisodeId) { idx = i; break; }
        }
    } else if (restoreEpisodeId) {
        for (i = 0; i < list.length; i++) {
            if (list[i] && list[i].Id === restoreEpisodeId) { idx = i; break; }
        }
    } else if (restoreIndex >= 0 && restoreIndex < list.length) {
        idx = restoreIndex;
    }
    return (idx >= 0 ? idx : -1);
}
function desiredIndexFromInputs(list, preselectEpisodeId, restoreEpisodeId,
                                restoreIndex, playlist) {
    if (!list || !list.length)
        return -1;
    var idxFromInputs = applyRestoreIndexIfAny(list, preselectEpisodeId,
                                               restoreEpisodeId, restoreIndex);
    if (idxFromInputs >= 0)
        return idxFromInputs;
    var idxFromPl = indexFromPlaylistIfAny(playlist, list);
    if (idxFromPl >= 0)
        return idxFromPl;
    return 0;
}
function pushPlaylist(playlist, episodes, seasonItem,
                      unknownSeasonNumber, sntSentinel,
                      currentEpisode) {
    if (!playlist)
        return;
    var ids = idsFromEpisodes(episodes || []); var currentId = currentEpisode && currentEpisode.Id
                  ? String(currentEpisode.Id)
                  : "";
    var title = seasonPlaylistTitle(seasonItem, unknownSeasonNumber, sntSentinel);
    playlist.replaceScopedList(
        ids,
        title,
        "seasonpage",
        seasonItem && seasonItem.Id ? ("season:" + String(seasonItem.Id)) : "season"
    );
    var preferredId = "";
    try {
        if (playlist.currentItemId !== undefined && playlist.currentItemId &&
            ids.indexOf(String(playlist.currentItemId)) >= 0) {
            preferredId = String(playlist.currentItemId);
        } else if (typeof playlist.index === "number" &&
                   playlist.index >= 0 &&
                   playlist.index < ids.length) {
            preferredId = ids[playlist.index];
        }
    } catch (e4) {}
    var finalId = currentId || preferredId;
    if (finalId && ids.indexOf(String(finalId)) >= 0) {
        playlist.setCurrentItemId(String(finalId));
    }
}
function syncPlaylistCursor(playlist, episode) {
    if (!playlist || !episode || !episode.Id)
        return;
    var id = String(episode.Id);
    playlist.setCurrentItemId(id);
}
function updatePlaylistFromEpisodes(ctx) {
    if (!ctx || !ctx.playlist)
        return;
    // La liste partielle reste affichable, mais ne doit jamais devenir une
    // playlist automatique tronquée. Une playlist/hint complet déjà présent
    // est ainsi conservé jusqu'à une prochaine requête réussie.
    try { if (ctx.episodesPartial === true) return; } catch (e0) {}
    var episodes = ctx.episodes || []; var currentEpisode = ctx.selectedEpisode || null;
    pushPlaylist(ctx.playlist,
                 episodes,
                 ctx.seasonItem,
                 ctx.unknownSeasonNumber,
                 ctx.sntSentinel,
                 currentEpisode);
}

function bucketUnknownEpisodes(items, unknownSeasonNumber, sntSentinel,
                               preselectEpisodeId) {
    var arr = items || [];
    if (!arr.length)
        return arr;
    var wanted = (unknownSeasonNumber !== sntSentinel)
               ? unknownSeasonNumber
               : null;
    var i;
    if (wanted === null && preselectEpisodeId) {
        for (i = 0; i < arr.length; i++) {
            var ep = arr[i];
            if (ep && ep.Id === preselectEpisodeId) {
                wanted = (ep.ParentIndexNumber !== null && ep.ParentIndexNumber !== undefined)
                       ? ep.ParentIndexNumber
                       : null;
                break;
            }
        }
    }
    if (wanted === null) {
        for (i = 0; i < arr.length; i++) {
            var e = arr[i];
            if (e && e.ParentIndexNumber !== null && e.ParentIndexNumber !== undefined) {
                wanted = e.ParentIndexNumber;
                break;
            }
        }
    }
    if (wanted === null)
        return arr;
    var out = [];
    for (i = 0; i < arr.length; i++) {
        var s = (arr[i] && arr[i].ParentIndexNumber !== null && arr[i].ParentIndexNumber !== undefined)
              ? arr[i].ParentIndexNumber
              : null;
        if (s === wanted)
            out.push(arr[i]);
    }
    return out;
}

function countDisplaySeasons(seasons) {
    if (!seasons || !seasons.length) return 0;
    var numbered = 0;
    for (var i = 0; i < seasons.length; ++i) {
        var season = seasons[i];
        var index = season && season.IndexNumber !== null && season.IndexNumber !== undefined
                ? Number(season.IndexNumber) : -1;
        if (index > 0) ++numbered;
    }
    return numbered > 0 ? numbered : seasons.length;
}

/* Séries et épisodes : tri, disponibilité, playlists et cache léger.
 * Fonctions pures partagées par les pages, le bridge et le lecteur.
 */
function _seriesString(v) {
    return (v === undefined || v === null) ? "" : (v + "");
}
function _seriesNumberOr(v, fallback) {
    return (v === undefined || v === null) ? fallback : +v;
}
function sortSeasonsInPlace(items) {
    if (!items || !items.sort) return items;
    items.sort(function (a, b) {
        var ia = _seriesNumberOr(a && a.IndexNumber, 9999), ib = _seriesNumberOr(b && b.IndexNumber, 9999);
        if (ia === 0 && ib !== 0) return 1;
        if (ib === 0 && ia !== 0) return -1;
        return ia - ib;
    });
    return items;
}
function sortEpisodesInPlace(items) {
    if (!items || !items.sort) return items;
    items.sort(function (a, b) {
        var sa = _seriesNumberOr(a && a.ParentIndexNumber, 9999), sb = _seriesNumberOr(b && b.ParentIndexNumber, 9999);
        if (sa !== sb) return sa - sb;
        var ea = _seriesNumberOr(a && a.IndexNumber, 9999), eb = _seriesNumberOr(b && b.IndexNumber, 9999);
        return ea - eb;
    });
    return items;
}
function _episodeFlagTrue(v) {
    if (v === true || v === 1) return true;
    var s = String(v === undefined || v === null ? "" : v).toLowerCase();
    return s === "true" || s === "1" || s === "yes" || s === "oui";
}
function episodeMissingReason(ep) {
    if (!ep) return "null";
    var loc = _seriesString(ep.LocationType || ep.locationType).toLowerCase();
    if (loc === "virtual") return "LocationType=Virtual";
    if (loc === "missing") return "LocationType=Missing";
    if (loc === "placeholder") return "LocationType=Placeholder";
    if (_episodeFlagTrue(ep.IsMissing) || _episodeFlagTrue(ep.Missing)) return "IsMissing/Missing=true";
    if (_episodeFlagTrue(ep.IsVirtual) || _episodeFlagTrue(ep.Virtual) ||
            _episodeFlagTrue(ep.IsVirtualItem) || _episodeFlagTrue(ep.VirtualItem)) return "IsVirtual=true";
    if (_episodeFlagTrue(ep.IsVirtualUnaired) || _episodeFlagTrue(ep.VirtualUnaired)) return "IsVirtualUnaired=true";
    if (_episodeFlagTrue(ep.IsPlaceholder) || _episodeFlagTrue(ep.IsPlaceHolder) || _episodeFlagTrue(ep.Placeholder)) return "IsPlaceholder=true";
    if (_episodeFlagTrue(ep.IsUnaired)) return "IsUnaired=true";
    return "";
}
function episodeHasPlayableHints(ep) {
    if (!ep) return false;
    var loc = _seriesString(ep.LocationType || ep.locationType).toLowerCase();
    if (loc === "filesystem" || loc === "file system") return true;
    try { if (ep.MediaSources && ep.MediaSources.length > 0) return true; } catch (e) {}
    try {
        var ms = ep.MediaStreams || [];
        for (var i = 0; i < ms.length; i++) {
            var stream = ms[i] || {};
            var typ = _seriesString(stream.Type || stream.type).toLowerCase();
            if (typ === "video" || typ === "audio") return true;
        }
    } catch (e2) {}
    return Number(ep.RunTimeTicks || ep.RuntimeTicks || 0) > 0;
}
function episodeIsPlayableForPlaylist(ep) {
    if (!ep || !ep.Id) return false;
    var typ = String(ep.Type || "").toLowerCase();
    if (typ && typ !== "episode") return false;
    if (episodeMissingReason(ep)) return false;
    var hasSources = false, hasPath = false;
    try { hasSources = typeof ep.MediaSources !== "undefined"; } catch(e0) {}
    try { hasPath = typeof ep.Path !== "undefined"; } catch(e1) {}
    if (hasSources && hasPath && (!(ep.MediaSources || []).length && !String(ep.Path || ""))) return false;
    return true;
}
function shuffleEpisodeId(ep) {
    return ep ? String(ep.Id || ep.ItemId || ep.id || "") : "";
}
function episodePlayableForShuffle(ep) {
    return !!(shuffleEpisodeId(ep) && !episodeMissingReason(ep) && episodeHasPlayableHints(ep));
}
function ownedShuffleCandidates(items, preferUnplayed) {
    var source = items || [], out = [];
    for (var i = 0; i < source.length; ++i) {
        var episode = source[i];
        if (!episodePlayableForShuffle(episode)) continue;
        if (preferUnplayed === true && episode.UserData && episode.UserData.Played === true) continue;
        out.push(episode);
    }
    return out;
}
function pickOwnedShuffleEpisode(items, preferUnplayed) {
    var pool = ownedShuffleCandidates(items, preferUnplayed === true);
    if (!pool.length && preferUnplayed === true) pool = ownedShuffleCandidates(items, false);
    if (!pool.length) return null;
    var index = Math.max(0, Math.min(pool.length - 1, Math.floor(Math.random() * pool.length)));
    return pool[index];
}
function normalizeIdList(raw) {
    var out = [], seen = {};
    raw = raw || [];
    for (var i = 0; i < raw.length; i++) {
        var id = String(raw[i] || "");
        if (!id || seen[id]) continue;
        seen[id] = 1;
        out.push(id);
    }
    return out;
}
function episodeIdListFromItems(items, preferredOrderIds) {
    items = items || [];
    preferredOrderIds = preferredOrderIds || [];
    var byId = {}, out = [], seen = {}, i;
    for (i = 0; i < items.length; i++) {
        if (items[i] && items[i].Id) byId[String(items[i].Id)] = items[i];
    }
    if (preferredOrderIds.length) {
        for (i = 0; i < preferredOrderIds.length; i++) {
            var wanted = String(preferredOrderIds[i] || ""), item = byId[wanted];
            if (wanted && !seen[wanted] && item && episodeIsPlayableForPlaylist(item)) {
                seen[wanted] = 1;
                out.push(wanted);
            }
        }
        return out;
    }
    for (i = 0; i < items.length; i++) {
        var ep = items[i], id = ep && ep.Id ? String(ep.Id) : "";
        if (!id || seen[id] || !episodeIsPlayableForPlaylist(ep)) continue;
        seen[id] = 1;
        out.push(id);
    }
    return out;
}

function episodeSliceWindow(items, centerIndex, requestedCount) {
    var arr = items || [], length = arr.length;
    if (!length) return { start:0, items:[] };
    var count = Math.max(4, Number(requestedCount) | 0);
    if (length <= count) return { start:0, items:arr };
    var center = Math.max(0, Math.min(Number(centerIndex) | 0, length - 1));
    var start = Math.max(0, center - Math.floor(count / 2));
    var end = start + count;
    if (end > length) { end = length; start = Math.max(0, end - count); }
    return { start:start, items:arr.slice(start, end) };
}
function isUnknownSeasonEpisode(e) {
    if (!e)
        return true;
    var sNum = (e.ParentIndexNumber !== undefined && e.ParentIndexNumber !== null)
             ? e.ParentIndexNumber
             : null;
    return ((!e.SeasonId || e.SeasonId === "") || (sNum === null)) && sNum !== 0;
}
function sortUnknownSeasonEpisodesInPlace(items) {
    if (!items || !items.sort) return items;
    items.sort(function(a, b) {
        var sa = (a && a.ParentIndexNumber !== null && a.ParentIndexNumber !== undefined) ? a.ParentIndexNumber : -1;
        var sb = (b && b.ParentIndexNumber !== null && b.ParentIndexNumber !== undefined) ? b.ParentIndexNumber : -1;
        if (sa !== sb) return sa - sb;
        var ea = (a && a.IndexNumber !== null && a.IndexNumber !== undefined) ? a.IndexNumber : 999999;
        var eb = (b && b.IndexNumber !== null && b.IndexNumber !== undefined) ? b.IndexNumber : 999999;
        if (ea !== eb) return ea - eb;
        var ad = a && a.PremiereDate ? String(a.PremiereDate) : "";
        var bd = b && b.PremiereDate ? String(b.PremiereDate) : "";
        return ad < bd ? -1 : (ad > bd ? 1 : 0);
    });
    return items;
}
function seriesRuntimeTicksFallback(ticks) {
    var t = Number(ticks || 0), maxEpisodeLike = 4 * 60 * 60 * 10000000;
    return (t > 0 && t <= maxEpisodeLike) ? Math.round(t) : 0;
}
/* Traitements purs partagés par le bridge et PlayerOverlay. */
function shuffledCopy(items) {
    var out = (items || []).slice(0);
    for (var i = out.length - 1; i > 0; i--) {
        var j = Math.floor(Math.random() * (i + 1));
        var tmp = out[i]; out[i] = out[j]; out[j] = tmp;
    }
    return out;
}
function averageEpisodeRuntimeTicks(items, fallbackTicks) {
    var total = 0, count = 0;
    items = items || [];
    for (var i = 0; i < items.length; i++) {
        var t = Number((items[i] && (items[i].RunTimeTicks || items[i].RuntimeTicks)) || 0);
        if (isFinite(t) && t > 0) { total += t; count++; }
    }
    return count > 0 ? Math.round(total / count) : seriesRuntimeTicksFallback(fallbackTicks);
}


// Présentation des épisodes et images de saison : même domaine que le tri et les playlists.

function _seasonBackdropBlur(v) {
    var n = (v === undefined || v === null) ? 25 : (v | 0);
    if (n < 1) n = 1;
    if (n > 50) n = 50;
    return n;
}

function _seasonBackdropImageUrl(Jellyfin, serverUrl, id, tag, w, h, q, blur) {
    return Jellyfin.itemImageUrl(serverUrl, id, "Backdrop", tag, {
        fillWidth: w, fillHeight: h, quality: q, blur: blur
    });
}

function _seasonPrimaryImageUrl(Jellyfin, serverUrl, id, tag, w, h, q, blur) {
    return Jellyfin.itemImageUrl(serverUrl, id, "Primary", tag, {
        fillWidth: w, fillHeight: h, quality: q, blur: blur
    });
}

function seasonBackdropUrl(Jellyfin, a, seasonItem, episodes, seriesId, seasonId, bgBlur, backdropQuality) {
    var ctx = null; var serverUrl = ""; var blur = 13; var q = 70; var w = 1280, h = 720;
    if (a && typeof a === "object") {
        ctx = a;
        serverUrl = ctx.serverUrl || "";
        seasonItem = ctx.seasonItem || null;
        episodes = ctx.episodes || null;
        seriesId = ctx.seriesId || "";
        seasonId = ctx.seasonId || "";
        bgBlur = (ctx.bgBlur !== undefined) ? ctx.bgBlur : bgBlur;
        backdropQuality = (ctx.backdropQuality !== undefined) ? ctx.backdropQuality : backdropQuality;
    } else {
        serverUrl = a || "";
    }
    var baseNoSlash = serverUrl;
    if (!baseNoSlash)
        return "";
    blur = _seasonBackdropBlur(bgBlur);
    q = (backdropQuality !== undefined && backdropQuality !== null) ? (backdropQuality | 0) : 70;
    function firstTag(arr) { return (arr && arr.length) ? String(arr[0] || "") : ""; }
    var parentId = ""; var parentTag = "";
    if (seasonItem && seasonItem.ParentBackdropItemId
        && seasonItem.ParentBackdropImageTags
        && seasonItem.ParentBackdropImageTags.length > 0) {
        parentId = seasonItem.ParentBackdropItemId;
        parentTag = firstTag(seasonItem.ParentBackdropImageTags);
    } else if (episodes && episodes.length > 0) {
        var e0 = episodes[0];
        if (e0 && e0.ParentBackdropItemId
            && e0.ParentBackdropImageTags
            && e0.ParentBackdropImageTags.length > 0) {
            parentId = e0.ParentBackdropItemId;
            parentTag = firstTag(e0.ParentBackdropImageTags);
        }
    }
    if (parentId)
        return _seasonBackdropImageUrl(Jellyfin, baseNoSlash, parentId, parentTag, w, h, q, blur);
    if (seriesId)
        return _seasonBackdropImageUrl(Jellyfin, baseNoSlash, seriesId, "", w, h, q, blur);
    if (seasonItem && seasonItem.Id) {
        if (seasonItem.BackdropImageTags && seasonItem.BackdropImageTags.length > 0)
            return _seasonBackdropImageUrl(Jellyfin, baseNoSlash, seasonItem.Id, firstTag(seasonItem.BackdropImageTags), w, h, q, blur);
        if (seasonItem.ImageTags && seasonItem.ImageTags.Primary)
            return _seasonPrimaryImageUrl(Jellyfin, baseNoSlash, seasonItem.Id, seasonItem.ImageTags.Primary, w, h, q, blur);
    }
    if (seasonId)
        return _seasonBackdropImageUrl(Jellyfin, baseNoSlash, seasonId, "", w, h, q, blur);
    return "";
}

function episodeCode(ep, seasonItem) {
    if (!ep)
        return "";
    var s = (ep.ParentIndexNumber !== null && ep.ParentIndexNumber !== undefined)
          ? ep.ParentIndexNumber
          : ((seasonItem && seasonItem.IndexNumber !== null && seasonItem.IndexNumber !== undefined)
                ? seasonItem.IndexNumber
                : "");
    var e = (ep.IndexNumber !== null && ep.IndexNumber !== undefined)
          ? ep.IndexNumber
          : "";
    if (s === "" && e === "")
        return "";
    return "S" + (s === "" ? "?" : s) + ":" + "E" + (e === "" ? "?" : e);
}

function _episodeNameLooksLikeFilename(name) {
    if (!name)
        return false;
    var n = String(name);
    if (/\.(mkv|mp4|avi|mov|wmv|m4v|flv|ts|m2ts)$/i.test(n))
        return true;
    return (n.indexOf(".") >= 0 && n.split(".").length > 2) || /[_-]\d{3,}/.test(n);
}

function episodeDisplayTitle(ep) {
    if (!ep)
        return "";

    var name = (ep.Name !== undefined && ep.Name !== null)
             ? String(ep.Name).replace(/^\s+|\s+$/g, "")
             : "";
    var originalTitle = (ep.OriginalTitle !== undefined && ep.OriginalTitle !== null)
                      ? String(ep.OriginalTitle).replace(/^\s+|\s+$/g, "")
                      : "";

    // Préférer les métadonnées propres sans jamais jeter un titre Jellyfin valide.
    if (name.length && !_episodeNameLooksLikeFilename(name))
        return name;
    if (originalTitle.length && !_episodeNameLooksLikeFilename(originalTitle))
        return originalTitle;

    // Un Name imparfait reste plus informatif que le fallback générique "Épisode N".
    if (name.length)
        return name;
    if (originalTitle.length)
        return originalTitle;

    if (ep.IndexNumber !== null && ep.IndexNumber !== undefined)
        return "Épisode " + ep.IndexNumber;

    return "Épisode";
}

function _seasonSeriesId(seriesId, selectedEpisode, seasonItem) {
    var sid = String(seriesId || "");
    if (!sid && selectedEpisode) {
        try {
            if (selectedEpisode.SeriesId) sid = String(selectedEpisode.SeriesId);
        } catch (e0) {}
    }
    if (!sid && seasonItem) {
        try {
            if (seasonItem.SeriesId) sid = String(seasonItem.SeriesId);
        } catch (e1) {}
    }
    if (!sid && seasonItem) {
        try {
            if (seasonItem.Id) sid = String(seasonItem.Id);
        } catch (e2) {}
    }
    return sid;
}

function _seasonSeriesPrimaryTag(selectedEpisode, seasonItem, ctxSeriesItem) {
    try {
        if (ctxSeriesItem && ctxSeriesItem.ImageTags && ctxSeriesItem.ImageTags.Primary)
            return String(ctxSeriesItem.ImageTags.Primary);
    } catch (e0) {}
    try {
        if (seasonItem && seasonItem.SeriesPrimaryImageTag)
            return String(seasonItem.SeriesPrimaryImageTag);
    } catch (e1) {}
    try {
        if (selectedEpisode && selectedEpisode.SeriesPrimaryImageTag)
            return String(selectedEpisode.SeriesPrimaryImageTag);
    } catch (e2) {}
    try {
        if (seasonItem && seasonItem.ImageTags && seasonItem.ImageTags.Primary && seasonItem.Type === "Series")
            return String(seasonItem.ImageTags.Primary);
    } catch (e3) {}
    return "";
}

function _seasonSeriesPosterUrl(Jellyfin, serverUrl, seriesId, tag, w, h, q) {
    return Jellyfin.itemImageUrl(serverUrl, seriesId, "Primary", tag, {
        format: "jpg", quality: q, fillWidth: w, fillHeight: h
    });
}

function seasonPosterFallbackUrl(Jellyfin, a, seriesId, selectedEpisode, seasonItem,
                                       cardW, cardH, posterRequestScale, posterRequestQuality) {
    var ctx = null; var serverUrl = ""; var episodes = null;
    if (a && typeof a === "object") {
        ctx = a;
        serverUrl = ctx.serverUrl || "";
        seriesId = ctx.seriesId || seriesId || "";
        selectedEpisode = ctx.selectedEpisode || selectedEpisode || null;
        seasonItem = ctx.seasonItem || seasonItem || null;
        cardW = ctx.episodeCardW || ctx.cardW || cardW || 360;
        cardH = ctx.episodeCardH || ctx.cardH || cardH || 240;
        posterRequestScale = (ctx.posterRequestScale !== undefined) ? ctx.posterRequestScale : posterRequestScale;
        posterRequestQuality = (ctx.posterRequestQuality !== undefined) ? ctx.posterRequestQuality : posterRequestQuality;
        episodes = ctx.episodes || null;
    } else {
        serverUrl = a || "";
    }
    if (!serverUrl)
        return "";
    if (!selectedEpisode && episodes && episodes.length) selectedEpisode = episodes[0];
    var sid = _seasonSeriesId(seriesId, selectedEpisode, seasonItem);
    if (!sid)
        return "";
    var base = serverUrl;
    if (!base)
        return "";
    var scale = (posterRequestScale !== undefined && posterRequestScale !== null) ? Number(posterRequestScale) : 1.0;
    if (!(scale > 0)) scale = 1.0;
    var reqW = Math.max(200, Math.round((cardW || 360) * scale)); var reqH = Math.max(140, Math.round((cardH || 240) * scale)); var q = (posterRequestQuality !== undefined && posterRequestQuality !== null) ? (posterRequestQuality | 0) : 72;
    var ctxSeriesItem = null;
    try { if (ctx && ctx.seriesItem) ctxSeriesItem = ctx.seriesItem; } catch (e0) { ctxSeriesItem = null; }
    var tag = _seasonSeriesPrimaryTag(selectedEpisode, seasonItem, ctxSeriesItem);
    return _seasonSeriesPosterUrl(Jellyfin, base, sid, tag, reqW, reqH, q);
}

function _episodeStreamTags(it) {
    if (!it)
        return [];
    var ms = (it.MediaStreams || []); var v = null; var aud = [];
    var i;
    for (i = 0; i < ms.length; i++) {
        var s = ms[i];
        if (s && s.Type === "Video" && !v)
            v = s;
        if (s && s.Type === "Audio")
            aud.push(s);
    }
    var tags = []; var hasSub = false;
    if (it.SubtitleFiles && it.SubtitleFiles.length)
        hasSub = true;
    else {
        for (i = 0; i < ms.length; i++) {
            if (ms[i] && ms[i].Type === "Subtitle") { hasSub = true; break; }
        }
    }
    if (hasSub)
        tags.push("ST");
    if (v) {
        if (v.Width && v.Height) {
            var hh = v.Height;
            if (hh >= 2160)      tags.push("2160p");
            else if (hh >= 1440) tags.push("1440p");
            else if (hh >= 1080) tags.push("1080p");
            else if (hh >= 720)  tags.push("720p");
            else                 tags.push(hh + "p");
        }
        if (v.Codec)
            tags.push(String(v.Codec).toUpperCase());
        if (v.VideoRange)
            tags.push(String(v.VideoRange).toUpperCase());
    }
    if (aud.length > 0) {
        var a = aud[0];
        if (a.Codec)
            tags.push(String(a.Codec).toUpperCase());
        if (a.ChannelLayout)
            tags.push(String(a.ChannelLayout).toUpperCase());
        else if (a.Channels) {
            if (a.Channels >= 6)       tags.push("5.1");
            else if (a.Channels === 2) tags.push("STEREO");
        }
    }
    if (it.Container) {
        var c = String(it.Container).toUpperCase(); var found = false;
        for (i = 0; i < tags.length; i++) {
            if (tags[i] === c) { found = true; break; }
        }
        if (!found)
            tags.push(c);
    }
    return tags;
}

function seasonLogoUrl(Jellyfin, serverUrl, seriesId, selectedEpisode, seasonItem,
                              maxW, seriesLogoMaxW) {
    var sid = seriesId ||
              (selectedEpisode &&
                (selectedEpisode.SeriesId ||
                 (selectedEpisode.SeriesPrimaryImageTag && selectedEpisode.SeriesId))) ||
              (seasonItem &&
                (seasonItem.SeriesId || seasonItem.Id)) ||
              "";
    if (!serverUrl || !sid)
        return "";
    var baseW = seriesLogoMaxW || 320;
    var w = Math.max(64, Math.round((maxW || baseW) * 2));
    return Jellyfin.itemImageUrl(serverUrl, sid, "Logo", "", { quality: 85, maxWidth: w });
}

function episodeOverviewPayload(Jellyfin, ep, serverUrl) {
    if (!ep || !ep.Overview)
        return null;
    var posterUrl = "";
    if (serverUrl && ep.ImageTags && ep.ImageTags.Primary) {
        posterUrl = Jellyfin.itemImageUrl(serverUrl, ep.Id, "Primary", ep.ImageTags.Primary,
                                           { quality: 88 });
    }
    return {
        posterUrl: posterUrl,
        overview: ep.Overview
    };
}

function _episodeTagFold(v) {
    var s = String(v || "").toLowerCase();
    s = s.replace(/[àáâãäåā]/g, "a");
    s = s.replace(/[ç]/g, "c");
    s = s.replace(/[èéêëēėę]/g, "e");
    s = s.replace(/[îïíīįì]/g, "i");
    s = s.replace(/[ôöòóõøō]/g, "o");
    s = s.replace(/[ùúûüū]/g, "u");
    s = s.replace(/[ÿ]/g, "y");
    s = s.replace(/\s+/g, " ");
    s = s.replace(/^\s+/, "").replace(/\s+$/, "");
    return s;
}

function _episodeStreamType(st) {
    if (!st) return "";
    if (st.Type === 0) return "Audio";
    if (st.Type === 1) return "Video";
    if (st.Type === 2) return "Subtitle";
    var t = String(st.Type || st.type || "").toLowerCase();
    if (t === "audio") return "Audio";
    if (t === "video") return "Video";
    if (t === "subtitle") return "Subtitle";
    return "";
}

function _episodeTagHasAny(s, arr) {
    for (var i = 0; i < arr.length; i++) {
        if (s.indexOf(arr[i]) >= 0) return true;
    }
    return false;
}

function _episodeStreamLangCode(st) {
    var raw = _episodeTagFold((st && (st.Language || st.language)) || ""); var blob = _episodeTagFold((st && (st.DisplayTitle || st.Title || st.displayTitle || st.title)) || "");
    if (raw === "fr" || raw === "fra" || raw === "fre" || raw === "french" || raw === "francais" || _episodeTagHasAny(blob, ["francais", "french"])) return "FR";
    if (raw === "en" || raw === "eng" || raw === "english" || _episodeTagHasAny(blob, ["anglais", "english"])) return "EN";
    if (raw === "ja" || raw === "jp" || raw === "jpn" || raw === "japanese" || _episodeTagHasAny(blob, ["japonais", "japanese"])) return "JP";
    if (raw === "es" || raw === "spa" || raw === "esp" || raw === "spanish" || _episodeTagHasAny(blob, ["espagnol", "spanish"])) return "ES";
    if (raw === "de" || raw === "ger" || raw === "deu" || raw === "german" || _episodeTagHasAny(blob, ["allemand", "german"])) return "DE";
    if (raw === "it" || raw === "ita" || raw === "italian" || _episodeTagHasAny(blob, ["italien", "italian"])) return "IT";
    if (raw === "pt" || raw === "por" || raw === "portuguese" || _episodeTagHasAny(blob, ["portugais", "portuguese"])) return "PT";
    if (raw === "ko" || raw === "kor" || raw === "korean" || _episodeTagHasAny(blob, ["coreen", "korean"])) return "KO";
    if (raw === "zh" || raw === "chi" || raw === "zho" || raw === "chinese" || _episodeTagHasAny(blob, ["chinois", "chinese"])) return "ZH";
    if (raw === "ru" || raw === "rus" || raw === "russian" || _episodeTagHasAny(blob, ["russe", "russian"])) return "RU";
    if (raw.length >= 2) return raw.substr(0, 2).toUpperCase();
    return "";
}

function _episodeTagPushUnique(arr, value) {
    value = String(value || "");
    if (!value.length) return;
    for (var i = 0; i < arr.length; i++) {
        if (arr[i] === value) return;
    }
    arr.push(value);
}

function _episodeStreamLangListTag(src, streamType, prefix) {
    if (!src || !src.MediaStreams) return "";
    var langs = []; var count = 0;
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i];
        if (!st || _episodeStreamType(st) !== streamType) continue;
        count++;
        _episodeTagPushUnique(langs, _episodeStreamLangCode(st));
    }
    if (count <= 0) return "";
    if (langs.length > 0) return prefix + " " + langs.join(" / ");
    return prefix + " " + count + " piste" + (count > 1 ? "s" : "");
}

function _isGenericEpisodeTrackTag(tag) {
    var s = _episodeTagFold(tag);
    if (!s || /^\+[0-9]+$/.test(s)) return true;
    if (s === "st" || s === "sub" || s === "subs" || s === "subtitle" || s === "subtitles" || s === "sous titres" || s === "sous-titres") return true;
    if (s === "multi" || s === "multi audio" || s === "multiaudio" || s === "audio multi") return true;
    return false;
}

function _episodeLanguageTags(src, baseTags) {
    var out = [];
    baseTags = baseTags || [];
    for (var i = 0; i < baseTags.length; i++) {
        var tag = String(baseTags[i] || "");
        if (!_isGenericEpisodeTrackTag(tag)) _episodeTagPushUnique(out, tag);
    }
    var audioTag = _episodeStreamLangListTag(src, "Audio", "AUDIO"); var subTag = _episodeStreamLangListTag(src, "Subtitle", "ST");
    if (audioTag.length > 0) _episodeTagPushUnique(out, audioTag);
    if (subTag.length > 0) _episodeTagPushUnique(out, subTag);
    return out;
}

function episodeTechChips(src) {
    if (!src) return [];
    var t = [];
    try { t = _episodeStreamTags(src) || []; } catch (e0) { t = []; }
    return _episodeLanguageTags(src, t);
}

function compactEpisodeDetails(details) {
    if (!details) return null;
    var streams = [], sourceStreams = details.MediaStreams || [];
    for (var i = 0; i < sourceStreams.length; ++i) {
        var stream = sourceStreams[i];
        if (!stream) continue;
        streams.push({
            Type: stream.Type, Codec: stream.Codec || "", Width: Number(stream.Width || 0),
            Height: Number(stream.Height || 0), VideoRange: stream.VideoRange || "",
            ChannelLayout: stream.ChannelLayout || "", Channels: Number(stream.Channels || 0),
            Language: stream.Language || "", DisplayTitle: stream.DisplayTitle || "",
            Title: stream.Title || ""
        });
    }
    var directors = [], people = details.People || [];
    for (var p = 0; p < people.length; ++p) {
        var person = people[p] || {};
        var role = String(person.Type || person.Role || person.Job || "");
        if (/director/i.test(role)) {
            directors.push({ Name: person.Name || "", Type: person.Type || "",
                               Role: person.Role || "", Job: person.Job || "" });
        }
    }
    var tags = details.ImageTags || {};
    return {
        Id: details.Id || "", Name: details.Name || "", Type: details.Type || "Episode",
        Overview: details.Overview || "", CommunityRating: details.CommunityRating,
        OfficialRating: details.OfficialRating || "", ProductionYear: details.ProductionYear,
        PremiereDate: details.PremiereDate || "", RunTimeTicks: Number(details.RunTimeTicks || 0),
        Container: details.Container || "", UserData: details.UserData || null,
        ImageTags: tags.Primary ? { Primary: tags.Primary } : {}, People: directors,
        SubtitleFiles: (details.SubtitleFiles && details.SubtitleFiles.length) ? [true] : [],
        MediaStreams: streams
    };
}
