.pragma library

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
