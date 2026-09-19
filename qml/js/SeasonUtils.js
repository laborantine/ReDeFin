.pragma library
.import "SafeLog.js" as SafeLog

// Compatibilité historique : les tokens Jellyfin ne sont jamais ajoutés aux URL Image.source.
function _safeCacheId(prefix, value) {
    value = String(value || "");
    if (!value) return prefix + "#empty";
    return prefix + "#" + SafeLog.shortHash(value);
}
function _serverBaseNoSlash(serverUrl) {
    var b = String(serverUrl || "");
    if (b.length && b.charAt(b.length - 1) === "/")
        b = b.slice(0, -1);
    return b;
}
function msFromTicks(t) {
    t = Number(t || 0);
    return t ? Math.round(t / 10000) : 0; // ticks Jellyfin = 100ns
}
function pad2(n) {
    n = +n;
    return (n < 10 ? "0" : "") + n;
}
function fmtDateLong(iso) {
    var s = (iso === undefined || iso === null) ? "" : String(iso);
    if (s.length < 10) return "";
    var y = parseInt(s.substr(0, 4), 10);
    var m = parseInt(s.substr(5, 2), 10);
    var d = parseInt(s.substr(8, 2), 10);
    if (!y || m < 1 || m > 12 || d < 1 || d > 31) return "";
    var mois = ["janv.", "févr.", "mars", "avr.", "mai", "juin",
                "juil.", "août", "sept.", "oct.", "nov.", "déc."];
    return d + " " + mois[m - 1] + " " + y;
}
function fmtMinutesFromTicks(t) {
    var ms = msFromTicks(t);
    if (!ms)
        return "";
    var s = Math.round(ms / 1000);
    return Math.floor(s / 60) + " min";
}
function chapterTitle(chapter) {
    if (!chapter || chapter.Name === undefined || chapter.Name === null) return "";
    return String(chapter.Name).replace(/^\s+|\s+$/g, "");
}
function chapterTimeLabel(chapter) {
    var ticks = Number(chapter && chapter.StartPositionTicks || 0);
    var sec = Math.max(0, Math.floor(ticks / 10000000));
    var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    return h > 0 ? (h + ":" + pad2(m) + ":" + pad2(s)) : (m + ":" + pad2(s));
}
function chapterStartMs(chapter) {
    return Math.max(0, Math.floor(Number(chapter && chapter.StartPositionTicks || 0) / 10000));
}
function chapterIndexForPosition(chapters, positionMs, toleranceMs) {
    var list = chapters || [];
    if (!list.length) return -1;
    var pos = Math.max(0, Number(positionMs || 0));
    var tolerance = Math.max(0, Number(toleranceMs || 0));
    var idx = 0;
    for (var i = 0; i < list.length; ++i) {
        if (chapterStartMs(list[i]) <= pos + tolerance) idx = i;
        else break;
    }
    return Math.max(0, Math.min(list.length - 1, idx));
}
function chapterImageUrl(serverUrl, itemId, chapters, index, width, height, quality) {
    var base = _serverBaseNoSlash(serverUrl);
    var idx = Number(index) | 0;
    var list = chapters || [];
    var chapter = (idx >= 0 && idx < list.length) ? list[idx] : null;
    var imagePath = chapter ? String(chapter.ImagePath || chapter.imagePath || "") : "";
    var imageTag = chapter ? String(chapter.ImageTag || chapter.imageTag || "") : "";
    if (!base || !itemId || idx < 0 || (!imagePath && !imageTag)) return "";
    var url = base + "/Items/" + encodeURIComponent(itemId) + "/Images/Chapter/" + idx
            + "?maxWidth=" + Math.max(1, Number(width) | 0)
            + "&maxHeight=" + Math.max(1, Number(height) | 0)
            + "&quality=" + Math.max(1, Number(quality) | 0) + "&format=jpg";
    if (imageTag) url += "&tag=" + encodeURIComponent(imageTag);
    return url;
}
function fmtRatingFr(n) {
    if (n === undefined || n === null)
        return "";
    return Number(n).toLocaleString(Qt.locale(), "f", 1);
}
function endTimeFor(ticks) {
    var ms = msFromTicks(ticks);
    if (!ms)
        return "";
    var end = new Date(Date.now() + ms);
    return Qt.formatTime(end, "hh:mm");
}
function _clampBlurInt(v) {
    var n = (v === undefined || v === null) ? 25 : (v | 0);
    if (n < 1) n = 1;
    if (n > 50) n = 50;
    return n;
}
function _bgBuildBackdropUrl(baseNoSlash, id, tag, w, h, q, blur) {
    if (!baseNoSlash || !id) return "";
    var base = String(baseNoSlash) + "/Items/" + encodeURIComponent(id) + "/Images/Backdrop"; var qs = "?fillWidth=" + (w | 0) + "&fillHeight=" + (h | 0)
           + "&quality=" + (q | 0) + "&blur=" + (blur | 0);
    if (tag && String(tag).length) qs += "&tag=" + encodeURIComponent(String(tag));
    return base + qs;
}
function _bgBuildPrimaryUrl(baseNoSlash, id, tag, w, h, q, blur) {
    if (!baseNoSlash || !id) return "";
    var base = String(baseNoSlash) + "/Items/" + encodeURIComponent(id) + "/Images/Primary"; var qs = "?fillWidth=" + (w | 0) + "&fillHeight=" + (h | 0)
           + "&quality=" + (q | 0) + "&blur=" + (blur | 0);
    if (tag && String(tag).length) qs += "&tag=" + encodeURIComponent(String(tag));
    return base + qs;
}
function computeBgUrl(a, seasonItem, episodes, seriesId, seasonId, bgBlur, backdropQuality) {
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
    var baseNoSlash = _serverBaseNoSlash(serverUrl);
    if (!baseNoSlash)
        return "";
    blur = _clampBlurInt(bgBlur);
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
        return _bgBuildBackdropUrl(baseNoSlash, parentId, parentTag, w, h, q, blur);
    if (seriesId)
        return _bgBuildBackdropUrl(baseNoSlash, seriesId, "", w, h, q, blur);
    if (seasonItem && seasonItem.Id) {
        if (seasonItem.BackdropImageTags && seasonItem.BackdropImageTags.length > 0)
            return _bgBuildBackdropUrl(baseNoSlash, seasonItem.Id, firstTag(seasonItem.BackdropImageTags), w, h, q, blur);
        if (seasonItem.ImageTags && seasonItem.ImageTags.Primary)
            return _bgBuildPrimaryUrl(baseNoSlash, seasonItem.Id, seasonItem.ImageTags.Primary, w, h, q, blur);
    }
    if (seasonId)
        return _bgBuildBackdropUrl(baseNoSlash, seasonId, "", w, h, q, blur);
    return "";
}
function sxeCode(ep, seasonItem) {
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
function isLikelyFilename(name) {
    if (!name)
        return false;
    var n = String(name);
    if (/\.(mkv|mp4|avi|mov|wmv|m4v|flv|ts|m2ts)$/i.test(n))
        return true;
    return (n.indexOf(".") >= 0 && n.split(".").length > 2) || /[_-]\d{3,}/.test(n);
}
function displayEpisodeTitle(ep) {
    if (!ep)
        return "";

    var name = (ep.Name !== undefined && ep.Name !== null)
             ? String(ep.Name).replace(/^\s+|\s+$/g, "")
             : "";
    var originalTitle = (ep.OriginalTitle !== undefined && ep.OriginalTitle !== null)
                      ? String(ep.OriginalTitle).replace(/^\s+|\s+$/g, "")
                      : "";

    // Préférer les métadonnées propres sans jamais jeter un titre Jellyfin valide.
    if (name.length && !isLikelyFilename(name))
        return name;
    if (originalTitle.length && !isLikelyFilename(originalTitle))
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
function _seriesIdFrom(seriesId, selectedEpisode, seasonItem) {
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
function _seriesPrimaryTagFrom(selectedEpisode, seasonItem, ctxSeriesItem) {
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
function _seriesPosterUrlQ(baseNoSlash, seriesId, tag, w, h, q) {
    if (!baseNoSlash || !seriesId) return "";
    var u = baseNoSlash + "/Items/" + encodeURIComponent(seriesId) + "/Images/Primary"
          + "?format=jpg"
          + "&quality=" + (q | 0)
          + "&fillWidth=" + (w | 0)
          + "&fillHeight=" + (h | 0);
    if (tag && String(tag).length) u += "&tag=" + encodeURIComponent(String(tag));
    return u;
}
function computeSeriesPosterFallbackUrl(a, seriesId, selectedEpisode, seasonItem,
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
    var sid = _seriesIdFrom(seriesId, selectedEpisode, seasonItem);
    if (!sid)
        return "";
    var base = _serverBaseNoSlash(serverUrl);
    if (!base)
        return "";
    var scale = (posterRequestScale !== undefined && posterRequestScale !== null) ? Number(posterRequestScale) : 1.0;
    if (!(scale > 0)) scale = 1.0;
    var reqW = Math.max(200, Math.round((cardW || 360) * scale)); var reqH = Math.max(140, Math.round((cardH || 240) * scale)); var q = (posterRequestQuality !== undefined && posterRequestQuality !== null) ? (posterRequestQuality | 0) : 72;
    var ctxSeriesItem = null;
    try { if (ctx && ctx.seriesItem) ctxSeriesItem = ctx.seriesItem; } catch (e0) { ctxSeriesItem = null; }
    var tag = _seriesPrimaryTagFrom(selectedEpisode, seasonItem, ctxSeriesItem);
    return _seriesPosterUrlQ(base, sid, tag, reqW, reqH, q);
}
function computeEpisodesRowFallbackPosterUrl(ctx){ return computeSeriesPosterFallbackUrl(ctx); }
function computeTags(it) {
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
function computeSeriesLogoUrl(serverUrl, seriesId, selectedEpisode, seasonItem,
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
    var base = _serverBaseNoSlash(serverUrl); var baseW = seriesLogoMaxW || 320; var w = Math.max(64, Math.round((maxW || baseW) * 2)); var u = base + "/Items/" + encodeURIComponent(sid)
          + "/Images/Logo?quality=85&maxWidth=" + w;
    return u;
}
function directorNames(item) {
    var p = (item && item.People) ? item.People : []; var out = [];
    for (var i = 0; i < p.length; i++) {
        var role = String(p[i].Type || p[i].Role || p[i].Job || "");
        if (/director/i.test(role))
            out.push(p[i].Name);
    }
    return out.join(", ");
}
function normName(s) {
    s = String(s || "").toLowerCase();
    s = s.replace(/[àáâãäå]/g, "a")
         .replace(/ç/g, "c")
         .replace(/[èéêë]/g, "e")
         .replace(/[ìíîï]/g, "i")
         .replace(/ñ/g, "n")
         .replace(/[òóôõö]/g, "o")
         .replace(/[ùúûü]/g, "u")
         .replace(/[ýÿ]/g, "y")
         .replace(/œ/g, "oe")
         .replace(/æ/g, "ae");
    s = s.replace(/\s+/g, " ");
    s = s.replace(/^\s+/, "").replace(/\s+$/, "");
    return s;
}
function mapByName(arr) {
    var m = {};
    arr = arr || [];
    for (var i = 0; i < arr.length; i++) {
        var n = (arr[i] && arr[i].Name) ? arr[i].Name : arr[i]; var k = normName(n);
        if (k)
            m[k] = arr[i];
    }
    return m;
}
function isGuestStarEntry(p) {
    if (!p)
        return false;
    if (p.IsGuestStar === true || p.IsGuest === true)
        return true;
    var role = String(p.Role || p.Type || p.Category || p.Job || "").toLowerCase();
    if (role.indexOf("guest") >= 0)
        return true;
    if (role.indexOf("invité") >= 0 || role.indexOf("invite") >= 0)
        return true;
    if ((p.Type || "").toLowerCase() === "gueststar")
        return true;
    return false;
}
function isActorLike(p) {
    if (!p)
        return false;
    var t = String(p.Type || "").toLowerCase();
    if (t === "actor")
        return true;
    if (t === "actress" || t === "cast")
        return true;
    var r = String(p.Role || p.Job || "").toLowerCase();
    if (r.indexOf("actor") >= 0 || r.indexOf("actress") >= 0 || r.indexOf("cast") >= 0)
        return true;
    return false;
}
function normalizePersonLike(p, fallbackName) {
    p = p || {};
    var id = (p.Id || p.PersonId || p.ItemId) ? String(p.Id || p.PersonId || p.ItemId) : ""; var pid = (p.PersonId || p.Id) ? String(p.PersonId || p.Id) : ""; var iid = (p.ItemId || p.Id) ? String(p.ItemId || p.Id) : "";
    return {
        Id: id,
        PersonId: pid,
        ItemId: iid,
        Name: (p.Name ? String(p.Name) : String(fallbackName || "")),
        Role: (p.Role || p.Type || p.Job) ? String(p.Role || p.Type || p.Job) : "Invité·e",
        PrimaryImageTag: (p.PrimaryImageTag ? String(p.PrimaryImageTag) : ""),
        ImageTags: (p.ImageTags ? p.ImageTags : null)
    };
}

// Normalisation canonique des personnes affichées par guestpage.qml.
// Cette variante conserve volontairement la sémantique historique de la page :
// une entrée sans Type explicite est considérée comme acteur potentiel et le rôle
// visuel privilégie Character/Role/Job tout en filtrant les labels génériques.
function _guestTrim(value) { return String(value || "").trim(); }
function _isGenericGuestLabel(value) {
    var s = _guestTrim(value).toLowerCase();
    if (!s) return true;
    if (s === "gueststar" || s === "guest star" || s === "guest") return true;
    if (s === "invité" || s === "invite" || s === "invité·e" || s === "invitee") return true;
    if (s.indexOf("guest star") >= 0 || s.indexOf("guest") >= 0) return true;
    return s.indexOf("invité") >= 0 || s.indexOf("invite") >= 0;
}
function guestDisplayRole(person) {
    var p = person || {};
    var character = _guestTrim(p.Character || p.CharacterName || p.CharacterRole || "");
    if (character && !_isGenericGuestLabel(character)) return character;

    var role = _guestTrim(p.Role || "");
    if (role && !_isGenericGuestLabel(role)) return role;

    var job = _guestTrim(p.Job || p.Type || p.Category || "");
    if (job && !_isGenericGuestLabel(job)) return job;
    return "Invité·e";
}
function _guestPageIsGuestStarEntry(person) {
    if (!person) return false;
    var role = String(person.Role || person.Type || person.Category || "").toLowerCase();
    if (person.IsGuestStar === true || person.IsGuest === true) return true;
    if (String(person.Type || "").toLowerCase() === "gueststar") return true;
    if (role.indexOf("guest") >= 0) return true;
    if (role.indexOf("invité") >= 0 || role.indexOf("invite") >= 0) return true;
    return String(person.Job || "").toLowerCase() === "guest star";
}
function _guestPageActorLike(person) {
    if (!person) return false;
    if (person.Type === undefined || person.Type === null || String(person.Type).length === 0)
        return true;
    var typeName = String(person.Type).toLowerCase();
    return typeName === "actor" || typeName === "actress" || typeName === "cast";
}
function _guestUiShape(person) {
    var p = person || {};
    var id = p.Id || p.PersonId || p.ItemId || "";
    return {
        Id: id,
        PersonId: p.PersonId || id || "",
        ItemId: p.ItemId || id || "",
        Name: p.Name || "",
        Role: guestDisplayRole(p),
        PrimaryImageTag: p.PrimaryImageTag || "",
        ImageTags: p.ImageTags || null,
        Type: p.Type || ""
    };
}
function normalizeGuestUiList(source) {
    var src = source || [];
    var out = [];
    if (!src.length) return out;

    if (typeof src[0] === "string") {
        for (var stringIndex = 0; stringIndex < src.length; ++stringIndex)
            out.push({ Id:"", PersonId:"", ItemId:"", Name:String(src[stringIndex] || ""), Role:"Invité·e" });
        return out;
    }

    var flagged = [];
    var actors = [];
    for (var i = 0; i < src.length; ++i) {
        var person = src[i];
        if (!person) continue;
        if (_guestPageActorLike(person)) actors.push(_guestUiShape(person));
        if (_guestPageIsGuestStarEntry(person)) flagged.push(_guestUiShape(person));
    }

    var candidates = flagged.length ? flagged.concat(actors) : actors;
    var seen = {};
    for (var candidateIndex = 0; candidateIndex < candidates.length; ++candidateIndex) {
        var candidate = candidates[candidateIndex];
        var key = candidate.PersonId ? ("pid:" + candidate.PersonId)
                : (candidate.Id ? ("id:" + candidate.Id) : ("nm:" + normName(candidate.Name)));
        if (!key || seen[key]) continue;
        seen[key] = true;
        out.push(candidate);
    }
    return out;
}
function _pushUniq(out, seen, rec) {
    if (!rec)
        return;
    var k = "";
    if (rec.Id)
        k = "id:" + String(rec.Id);
    else if (rec.PersonId)
        k = "pid:" + String(rec.PersonId);
    else
        k = "n:" + normName(rec.Name);
    if (!k)
        return;
    if (!seen[k]) {
        out.push(rec);
        seen[k] = true;
    }
}
function extractGuestStars(details) {
    var out = []; var seen = {}; var people   = (details && details.People) ? details.People : []; var explicit = (details && details.GuestStars) ? details.GuestStars : [];
    var i;
    if (explicit && explicit.length) {
        var pByName = mapByName(people);
        for (i = 0; i < explicit.length; i++) {
            var n = explicit[i];
            if (!n)
                continue;
            var key = normName(n); var src = (key && pByName[key]) ? pByName[key] : null; var rec = src ? normalizePersonLike(src, n)
                          : { Id: "", PersonId: "", ItemId: "", Name: String(n), Role: "Invité·e", PrimaryImageTag: "", ImageTags: null };
            _pushUniq(out, seen, rec);
        }
    }
    for (i = 0; i < people.length; i++) {
        var p = people[i];
        if (isGuestStarEntry(p))
            _pushUniq(out, seen, normalizePersonLike(p, p && p.Name));
    }
    if (out.length === 0) {
        for (i = 0; i < people.length; i++) {
            var p2 = people[i];
            if (isActorLike(p2))
                _pushUniq(out, seen, normalizePersonLike(p2, p2 && p2.Name));
        }
    }
    return out;
}
function hasGuestStars(guestStars) { return !!(guestStars && guestStars.length > 0); }
function slice(list, n) {
    if (!list || !list.length) return [];
    var k = Math.max(0, n | 0);
    return list.slice(0, k);
}
var __ctxGuestState = [];      // fifo { ctx:<qml>, guestId:"" }
var __ctxGuestStateMax = 12;
function _ctxTryGetProp(ctx, name) {
    try { if (!ctx) return undefined; return ctx[name]; }
    catch (e) { return undefined; }
}
function _ctxTrySetProp(ctx, name, value) {
    try { if (!ctx) return false; ctx[name] = value; return true; }
    catch (e) { return false; }
}
function _ctxStateGet(ctx, create) {
    if (!ctx) return null;
    for (var i = 0; i < __ctxGuestState.length; i++) {
        if (__ctxGuestState[i] && __ctxGuestState[i].ctx === ctx)
            return __ctxGuestState[i];
    }
    if (!create) return null;
    var rec = { ctx: ctx, guestId: "" };
    __ctxGuestState.push(rec);
    while (__ctxGuestState.length > __ctxGuestStateMax)
        __ctxGuestState.shift();
    return rec;
}
function _getCtxGuestId(ctx) {
    var v = _ctxTryGetProp(ctx, "_guestStarsItemId");
    if (v !== undefined)
        return String(v || "");
    var r = _ctxStateGet(ctx, false);
    return r ? String(r.guestId || "") : "";
}
function _setCtxGuestId(ctx, id) {
    var s = String(id || "");
    if (_ctxTrySetProp(ctx, "_guestStarsItemId", s))
        return;
    var r = _ctxStateGet(ctx, true);
    if (r) r.guestId = s;
}
function _applyGuestPeopleToGuestpage(ctx, list) {
    try {
        if (ctx && typeof ctx._applyGuestsToGuestpage === "function") {
            ctx._applyGuestsToGuestpage();
            return;
        }
        var refs = getRefs(ctx); var guestLoader = refs.guestLoader || null;
        if (!guestLoader || !guestLoader.item) return;
        var g = guestLoader.item;
        if (g.applyPeople) {
            var epoch = (ctx.guestDataEpoch !== undefined) ? ctx.guestDataEpoch : undefined;
            g.applyPeople(list || [], epoch);
        } else if (g.people !== undefined) g.people = list || [];
    } catch (e) {}
}
var __peopleCache = {};           // key -> array
var __peopleCacheOrder = [];      // fifo
var __peopleCacheMax = 24;
function _peopleCacheKey(serverUrl, itemId) {
    return _safeCacheId("server", serverUrl) + "|people|" + _safeCacheId("item", itemId);
}
function _peopleCacheGet(key) {
    return __peopleCache.hasOwnProperty(key) ? __peopleCache[key] : null;
}
function _peopleCachePut(key, arr) {
    if (!key) return;
    if (!__peopleCache.hasOwnProperty(key)) {
        __peopleCacheOrder.push(key);
        while (__peopleCacheOrder.length > __peopleCacheMax) {
            var k = __peopleCacheOrder.shift();
            try { delete __peopleCache[k]; } catch (e) {}
        }
    }
    __peopleCache[key] = arr || [];
}
function fetchItemPeople(serverUrl, accessToken, itemId, Jellyfin, done, fail) {
    if (!serverUrl || !itemId || !Jellyfin || !Jellyfin.fetchItemPeople) {
        if (done) done([]);
        return;
    }
    var key = _peopleCacheKey(serverUrl, itemId); var cached = _peopleCacheGet(key);
    if (cached !== null) {
        if (done) done(cached);
        return;
    }
    // Une seule implémentation réseau : jellyfinBridge utilise
    // /Items/{id}, endpoint détail actuel ; People est lu depuis le BaseItemDto retourné.
    Jellyfin.fetchItemPeople(serverUrl, accessToken, itemId,
        function (peopleList) {
            var arr = (peopleList && peopleList.length !== undefined)
                    ? peopleList
                    : [];
            _peopleCachePut(key, arr);
            if (done) done(arr);
        },
        function (err) {
            if (fail) fail(err);
            else if (done) done([]);
        }
    );
}
function mergeGuestLists(a, b) {
    var out = []; var seen = {};
    a = a || [];
    b = b || [];
    for (var i = 0; i < a.length; i++)
        _pushUniq(out, seen, a[i]);
    for (var j = 0; j < b.length; j++)
        _pushUniq(out, seen, b[j]);
    return out;
}
function extractGuestStarsFromPeopleList(list) {
    var out = []; var seen = {};
    list = list || [];
    for (var i = 0; i < list.length; i++) {
        var p = list[i];
        if (isGuestStarEntry(p))
            _pushUniq(out, seen, normalizePersonLike(p, p && p.Name));
    }
    if (out.length === 0) {
        for (var j = 0; j < list.length; j++) {
            var p2 = list[j];
            if (isActorLike(p2))
                _pushUniq(out, seen, normalizePersonLike(p2, p2 && p2.Name));
        }
    }
    return out;
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
    try {
        if (playlist.setAllowedFromList)
            playlist.setAllowedFromList(ids);
        else if (playlist.setAllowed)
            playlist.setAllowed(ids);
        else if (playlist.hasOwnProperty("allowedIds")) {
            var m = {};
            for (var i = 0; i < ids.length; i++)
                m[ids[i]] = true;
            playlist.allowedIds = m;
        }
    } catch (e) {}
    try {
        var title = seasonPlaylistTitle(seasonItem, unknownSeasonNumber, sntSentinel);
        if (playlist.title !== undefined)
            playlist.title = title;
    } catch (e2) {}
    try {
        if (playlist.setList)
            playlist.setList(ids);
        else
            playlist.list = ids;
    } catch (e3) {}
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
        try {
            if (playlist.setCurrentItemId)
                playlist.setCurrentItemId(String(finalId));
            else if (playlist.currentItemId !== undefined)
                playlist.currentItemId = String(finalId);
        } catch (e5) {}
    }
}
function syncPlaylistCursor(playlist, episode) {
    if (!playlist || !episode || !episode.Id)
        return;
    var id = String(episode.Id);
    try {
        if (playlist.setCurrentItemId)
            playlist.setCurrentItemId(id);
        else if (playlist.currentItemId !== undefined)
            playlist.currentItemId = id;
    } catch (e) {}
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
function fetchUnknownSeasonEpisodes(serverUrl, userId, seriesId, accessToken,
                                    Jellyfin, done, fail) {
    if (!serverUrl || !userId || !seriesId || !Jellyfin ||
            typeof Jellyfin.fetchUnknownSeasonEpisodesItems !== "function") {
        if (done) done([]);
        return null;
    }
    return Jellyfin.fetchUnknownSeasonEpisodesItems(
        serverUrl, accessToken, userId, seriesId,
        function(items, meta) { if (done) done(items || [], meta || { partial:false }); },
        function(err) {
            if (fail) fail(err);
            else if (done) done([]);
        }
    );
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
function _fallbackSeasonItem(seasonId, seriesId) {
    var sid = seasonId || seriesId || "";
    return { Id: sid, Name: "", SeriesName: "", IndexNumber: null };
}
function _seasonErrCode(err) {
    try {
        if (!err) return "network_error";
        if (typeof err === "string") return String(err || "network_error");
        if (err.code !== undefined && err.code !== null) return String(err.code || "network_error");
        if (err.status !== undefined && err.status !== null) return "http_" + (err.status | 0);
    } catch (e0) {}
    return "network_error";
}
function _seasonLoadErrorMessage(err) {
    var c = _seasonErrCode(err).toLowerCase();
    if (c === "too_large")
        return "Réponse Jellyfin trop lourde. Chargement paginé requis.";
    if (c === "timeout" || c === "budget_exhausted")
        return "Timeout réseau / API.";
    if (c === "missing_params")
        return "Paramètres manquants.";
    if (c === "http_401" || c === "http_403")
        return "Session Jellyfin expirée ou accès refusé.";
    if (c === "http_404")
        return "Saison introuvable côté Jellyfin.";
    if (c.indexOf("http_") === 0)
        return "Erreur Jellyfin " + c.replace("http_", "HTTP ") + ".";
    return "Erreur réseau / API lors du chargement des épisodes.";
}
function _clearSeasonLoadError(ctx) {
    try { if (ctx && ctx.loadingError !== undefined) ctx.loadingError = ""; } catch (e0) {}
}
function _applySeasonEpisodesLoadError(ctx, err) {
    if (!ctx) return;
    try { if (ctx.loadingError !== undefined) ctx.loadingError = _seasonLoadErrorMessage(err); } catch (e0) {}
    // Ne pas forcer [] sur erreur : [] signifie vraie saison vide et déclenche “Aucun épisode trouvé”.
    // null garde le sens “chargement impossible/erreur” et laisse loadingError parler clairement.
    try { ctx.episodes = null; } catch (e1) {}
    try { if (ctx._episodesFetchedOnce !== undefined) ctx._episodesFetchedOnce = true; } catch (e2) {}
    try { ctx.currentIndex = 0; } catch (e3) {}
    try { if (ctx.episodesPartial !== undefined) ctx.episodesPartial = false; } catch (eP) {}
    try { ctx.fallbackPosterUrl = computeEpisodesRowFallbackPosterUrl(ctx); } catch (eFP) {}
    updatePlaylistFromEpisodes(ctx);
    try { if (ctx.maybeEndLoading) ctx.maybeEndLoading(); } catch (e4) {}
}
function cancelSeasonLoadRequests(ctx, reason) {
    if (!ctx) return false;
    var cancelled = false; var names = ["_seasonItemLoadHandle", "_episodesLoadHandle"];
    for (var i = 0; i < names.length; i++) {
        var name = names[i], h = null;
        try { h = ctx[name]; ctx[name] = null; } catch(e0) { h = null; }
        try { if (h && h.cancel) cancelled = h.cancel(reason || "context_changed") || cancelled; } catch(e1) {}
    }
    return cancelled;
}
function fetchSeasonAndEpisodes(ctx, Jellyfin) {
    if (!ctx || !Jellyfin)
        return;
    cancelSeasonLoadRequests(ctx, "replaced");
    ctx.reqSeq = (ctx.reqSeq || 0) + 1;
    var mySeq = ctx.reqSeq; var serverUrl   = ctx.serverUrl; var accessToken = ctx.accessToken; var seasonId    = ctx.seasonId; var seriesId    = ctx.seriesId; var userId      = ctx.userId;
    ctx.seasonItem      = null;
    ctx.episodes        = null;
    ctx.selectedDetails = null;
    ctx.guestStars      = [];
    try { if (ctx.episodesPartial !== undefined) ctx.episodesPartial = false; } catch (eP0) {}
    _setCtxGuestId(ctx, "");
    updatePlaylistFromEpisodes(ctx);
    if (serverUrl && accessToken && seasonId) {
        if (Jellyfin.fetchItem) {
            var seasonItemHandle = null;
            seasonItemHandle = Jellyfin.fetchItem(serverUrl, accessToken, seasonId,
                function (res) {
                    if (ctx.disposed || mySeq !== ctx.reqSeq)
                        return;
                    try { if (ctx._seasonItemLoadHandle === seasonItemHandle) ctx._seasonItemLoadHandle = null; } catch(eH0) {}
                    ctx.seasonItem = res || _fallbackSeasonItem(seasonId, "");
                    updatePlaylistFromEpisodes(ctx);
                },
                function () {
                    if (ctx.disposed || mySeq !== ctx.reqSeq)
                        return;
                    try { if (ctx._seasonItemLoadHandle === seasonItemHandle) ctx._seasonItemLoadHandle = null; } catch(eH1) {}
                    ctx.seasonItem = _fallbackSeasonItem(seasonId, "");
                    updatePlaylistFromEpisodes(ctx);
                }
            );
            try { ctx._seasonItemLoadHandle = seasonItemHandle; } catch(eH2) {}
        } else {
            ctx.seasonItem = _fallbackSeasonItem(seasonId, "");
            updatePlaylistFromEpisodes(ctx);
        }
        if (Jellyfin.fetchEpisodes && userId) {
            var episodesHandle = null;
            episodesHandle = Jellyfin.fetchEpisodes(serverUrl, accessToken, userId, seasonId,
                function (items, meta) {
                    if (ctx.disposed || mySeq !== ctx.reqSeq)
                        return;
                    try { if (ctx._episodesLoadHandle === episodesHandle) ctx._episodesLoadHandle = null; } catch(eH3) {}
                    items = items || [];
                    items.sort(function (a, b) {
                        var ia = (a.IndexNumber !== null && a.IndexNumber !== undefined)
                               ? a.IndexNumber : 9999;
                        var ib = (b.IndexNumber !== null && b.IndexNumber !== undefined)
                               ? b.IndexNumber : 9999;
                        return ia - ib;
                    });
                    _clearSeasonLoadError(ctx);
                    try { if (ctx.episodesPartial !== undefined) ctx.episodesPartial = !!(meta && meta.partial); } catch(eP1) {}
                    ctx.episodes = items;
                    var want = desiredIndexFromInputs(
                        items,
                        ctx.preselectEpisodeId,
                        ctx.restoreEpisodeId,
                        ctx.restoreIndex,
                        ctx.playlist
                    );
                    ctx.currentIndex = (want >= 0 ? want : 0);
                    try { ctx.fallbackPosterUrl = computeEpisodesRowFallbackPosterUrl(ctx); } catch (eFP0) {}
                    updatePlaylistFromEpisodes(ctx);
                },
                function (err) {
                    if (ctx.disposed || mySeq !== ctx.reqSeq)
                        return;
                    try { if (ctx._episodesLoadHandle === episodesHandle) ctx._episodesLoadHandle = null; } catch(eH4) {}
                    _applySeasonEpisodesLoadError(ctx, err);
                }
            );
            try { ctx._episodesLoadHandle = episodesHandle; } catch(eH5) {}
        } else {
            ctx.episodes = [];
            try { ctx.fallbackPosterUrl = computeEpisodesRowFallbackPosterUrl(ctx); } catch (eFP2) {}
            updatePlaylistFromEpisodes(ctx);
        }
        try { return ctx._episodesLoadHandle || ctx._seasonItemLoadHandle || null; } catch(eRet0) { return null; }
    }
    if (serverUrl && accessToken && seriesId) {
        if (Jellyfin.fetchItem) {
            var seriesItemHandle = null;
            seriesItemHandle = Jellyfin.fetchItem(serverUrl, accessToken, seriesId,
                function (res) {
                    if (ctx.disposed || mySeq !== ctx.reqSeq)
                        return;
                    try { if (ctx._seasonItemLoadHandle === seriesItemHandle) ctx._seasonItemLoadHandle = null; } catch(eH6) {}
                    var series = res || {};
                    ctx.seasonItem = {
                        Id: series.Id || seriesId,
                        SeriesName: series.Name || "",
                        Name: "Saison inconnue",
                        IndexNumber: null
                    };
                    try { ctx.seriesItem = series; } catch (eS0) {}
                    try { ctx.fallbackPosterUrl = computeEpisodesRowFallbackPosterUrl(ctx); } catch (eFP3) {}
                    updatePlaylistFromEpisodes(ctx);
                },
                function () {
                    if (ctx.disposed || mySeq !== ctx.reqSeq)
                        return;
                    try { if (ctx._seasonItemLoadHandle === seriesItemHandle) ctx._seasonItemLoadHandle = null; } catch(eH7) {}
                    ctx.seasonItem = {
                        Id: seriesId,
                        SeriesName: "",
                        Name: "Saison inconnue",
                        IndexNumber: null
                    };
                    try { ctx.fallbackPosterUrl = computeEpisodesRowFallbackPosterUrl(ctx); } catch (eFP4) {}
                    updatePlaylistFromEpisodes(ctx);
                }
            );
            try { ctx._seasonItemLoadHandle = seriesItemHandle; } catch(eH8) {}
        } else {
            ctx.seasonItem = {
                Id: seriesId,
                SeriesName: "",
                Name: "Saison inconnue",
                IndexNumber: null
            };
            try { ctx.fallbackPosterUrl = computeEpisodesRowFallbackPosterUrl(ctx); } catch (eFP5) {}
            updatePlaylistFromEpisodes(ctx);
        }
        if (!userId) {
            ctx.episodes = [];
            ctx.currentIndex = 0;
            try { ctx.fallbackPosterUrl = computeEpisodesRowFallbackPosterUrl(ctx); } catch (eFP6) {}
            updatePlaylistFromEpisodes(ctx);
            try { return ctx._seasonItemLoadHandle || null; } catch(eRet1) { return null; }
        }
        var unknownEpisodesHandle = null;
        unknownEpisodesHandle = fetchUnknownSeasonEpisodes(serverUrl, userId, seriesId, accessToken, Jellyfin,
            function (items, meta) {
                if (ctx.disposed || mySeq !== ctx.reqSeq)
                    return;
                try { if (ctx._episodesLoadHandle === unknownEpisodesHandle) ctx._episodesLoadHandle = null; } catch(eH9) {}
                var filtered = bucketUnknownEpisodes(
                    items || [],
                    ctx.unknownSeasonNumber,
                    ctx.sntSentinel,
                    ctx.preselectEpisodeId
                );
                _clearSeasonLoadError(ctx);
                try { if (ctx.episodesPartial !== undefined) ctx.episodesPartial = !!(meta && meta.partial); } catch(eP2) {}
                ctx.episodes = filtered;
                var want2 = desiredIndexFromInputs(
                    filtered,
                    ctx.preselectEpisodeId,
                    ctx.restoreEpisodeId,
                    ctx.restoreIndex,
                    ctx.playlist
                );
                ctx.currentIndex = (want2 >= 0 ? want2 : 0);
                try { ctx.fallbackPosterUrl = computeEpisodesRowFallbackPosterUrl(ctx); } catch (eFP7) {}
                updatePlaylistFromEpisodes(ctx);
            },
            function (err) {
                if (ctx.disposed || mySeq !== ctx.reqSeq)
                    return;
                try { if (ctx._episodesLoadHandle === unknownEpisodesHandle) ctx._episodesLoadHandle = null; } catch(eH10) {}
                _applySeasonEpisodesLoadError(ctx, err);
            }
        );
        try { ctx._episodesLoadHandle = unknownEpisodesHandle; } catch(eH11) {}
        return unknownEpisodesHandle;
    }
    ctx.seasonItem      = _fallbackSeasonItem(seasonId, seriesId);
    ctx.episodes        = [];
    ctx.selectedDetails = null;
    ctx.guestStars      = [];
    _setCtxGuestId(ctx, "");
    try { ctx.fallbackPosterUrl = computeEpisodesRowFallbackPosterUrl(ctx); } catch (eFP9) {}
    updatePlaylistFromEpisodes(ctx);
}
function shouldFetchFullPeople(ctx) {
    if (!ctx) return false;
    if (ctx.currentFocus === 2) return true;
    if (ctx.wantsGuestFocus === true) return true;
    if (ctx.autoRevealGuests === true) return true;
    if (ctx._guestPrefetch === true) return true;
    return false;
}
function fetchSelectedDetails(ctx, Jellyfin) {
    if (!ctx || !Jellyfin) return;
    var ep = ctx.selectedEpisode;
    if (!ep || !ctx.serverUrl || !ctx.accessToken) {
        ctx.selectedDetails = null;
        ctx.guestStars = [];
        _setCtxGuestId(ctx, "");
        updatePlaylistFromEpisodes(ctx);
        _applyGuestPeopleToGuestpage(ctx, ctx.guestStars);
        return;
    }
    ctx.detailsReqSeq = (ctx.detailsReqSeq || 0) + 1;
    var mySeq = ctx.detailsReqSeq;
    var idAt = ep.Id;
    var nextId = String(ep.Id || "");
    if (_getCtxGuestId(ctx) !== nextId) {
        ctx.guestStars = [];
        _applyGuestPeopleToGuestpage(ctx, ctx.guestStars);
    }

    function applyDetails(j) {
        if (ctx.disposed || mySeq !== ctx.detailsReqSeq) return;
        if (!ctx.selectedEpisode || ctx.selectedEpisode.Id !== idAt) return;
        ctx.selectedDetails = j || {};
        var baseGuests = extractGuestStars(ctx.selectedDetails);
        ctx.guestStars = baseGuests;
        _setCtxGuestId(ctx, idAt);
        _applyGuestPeopleToGuestpage(ctx, ctx.guestStars);
        if (!shouldFetchFullPeople(ctx)) return;
        fetchItemPeople(ctx.serverUrl, ctx.accessToken, idAt, Jellyfin,
            function(peopleList) {
                if (ctx.disposed || mySeq !== ctx.detailsReqSeq) return;
                if (!ctx.selectedEpisode || ctx.selectedEpisode.Id !== idAt) return;
                var extraGuests = extractGuestStarsFromPeopleList(peopleList || []);
                var merged = mergeGuestLists(baseGuests, extraGuests);
                if (!merged || merged.length === 0) return;
                var changed = true;
                try {
                    var cur = ctx.guestStars || [];
                    if (cur.length === merged.length) {
                        var a0 = cur[0] ? (cur[0].Id || cur[0].Name) : "";
                        var b0 = merged[0] ? (merged[0].Id || merged[0].Name) : "";
                        var aN = cur[cur.length - 1] ? (cur[cur.length - 1].Id || cur[cur.length - 1].Name) : "";
                        var bN = merged[merged.length - 1] ? (merged[merged.length - 1].Id || merged[merged.length - 1].Name) : "";
                        changed = !(a0 === b0 && aN === bN);
                    }
                } catch(eCmp) {}
                if (changed) {
                    ctx.guestStars = merged;
                    _setCtxGuestId(ctx, idAt);
                    _applyGuestPeopleToGuestpage(ctx, ctx.guestStars);
                }
            },
            function() {}
        );
    }
    function applyFallback() {
        if (ctx.disposed || mySeq !== ctx.detailsReqSeq) return;
        if (!ctx.selectedEpisode || ctx.selectedEpisode.Id !== idAt) return;
        ctx.selectedDetails = ep;
        var fallbackGuests = extractGuestStars(ep);
        ctx.guestStars = fallbackGuests;
        _setCtxGuestId(ctx, idAt);
        _applyGuestPeopleToGuestpage(ctx, ctx.guestStars);
    }

    if (ctx.userId && typeof Jellyfin.fetchUserItem === "function") {
        Jellyfin.fetchUserItem(ctx.serverUrl, ctx.accessToken, ctx.userId, idAt, applyDetails, applyFallback);
    } else if (typeof Jellyfin.fetchItem === "function") {
        Jellyfin.fetchItem(ctx.serverUrl, ctx.accessToken, idAt, applyDetails, applyFallback);
    } else {
        applyFallback();
    }
}
function buildOverviewOverlayPayload(ep, serverUrl) {
    if (!ep || !ep.Overview)
        return null;
    var posterUrl = "";
    if (serverUrl && ep.ImageTags && ep.ImageTags.Primary) {
        var base = _serverBaseNoSlash(serverUrl);
        posterUrl = base + "/Items/" + encodeURIComponent(ep.Id) +
                    "/Images/Primary?quality=88&tag=" +
                    encodeURIComponent(ep.ImageTags.Primary);
    }
    return {
        posterUrl: posterUrl,
        overview: ep.Overview
    };
}
function getRefs(ctx) {
    var r = null;
    try { r = ctx ? ctx.__seasonRefs : null; } catch (e) { r = null; }
    return r || {};
}
function _tagFold(v) {
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
function _streamTypeName(st) {
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
function _tagHasAny(s, arr) {
    for (var i = 0; i < arr.length; i++) {
        if (s.indexOf(arr[i]) >= 0) return true;
    }
    return false;
}
function _streamLangCode(st) {
    var raw = _tagFold((st && (st.Language || st.language)) || ""); var blob = _tagFold((st && (st.DisplayTitle || st.Title || st.displayTitle || st.title)) || "");
    if (raw === "fr" || raw === "fra" || raw === "fre" || raw === "french" || raw === "francais" || _tagHasAny(blob, ["francais", "french"])) return "FR";
    if (raw === "en" || raw === "eng" || raw === "english" || _tagHasAny(blob, ["anglais", "english"])) return "EN";
    if (raw === "ja" || raw === "jp" || raw === "jpn" || raw === "japanese" || _tagHasAny(blob, ["japonais", "japanese"])) return "JP";
    if (raw === "es" || raw === "spa" || raw === "esp" || raw === "spanish" || _tagHasAny(blob, ["espagnol", "spanish"])) return "ES";
    if (raw === "de" || raw === "ger" || raw === "deu" || raw === "german" || _tagHasAny(blob, ["allemand", "german"])) return "DE";
    if (raw === "it" || raw === "ita" || raw === "italian" || _tagHasAny(blob, ["italien", "italian"])) return "IT";
    if (raw === "pt" || raw === "por" || raw === "portuguese" || _tagHasAny(blob, ["portugais", "portuguese"])) return "PT";
    if (raw === "ko" || raw === "kor" || raw === "korean" || _tagHasAny(blob, ["coreen", "korean"])) return "KO";
    if (raw === "zh" || raw === "chi" || raw === "zho" || raw === "chinese" || _tagHasAny(blob, ["chinois", "chinese"])) return "ZH";
    if (raw === "ru" || raw === "rus" || raw === "russian" || _tagHasAny(blob, ["russe", "russian"])) return "RU";
    if (raw.length >= 2) return raw.substr(0, 2).toUpperCase();
    return "";
}
function _tagPushUnique(arr, value) {
    value = String(value || "");
    if (!value.length) return;
    for (var i = 0; i < arr.length; i++) {
        if (arr[i] === value) return;
    }
    arr.push(value);
}
function _streamLangListTag(src, streamType, prefix) {
    if (!src || !src.MediaStreams) return "";
    var langs = []; var count = 0;
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i];
        if (!st || _streamTypeName(st) !== streamType) continue;
        count++;
        _tagPushUnique(langs, _streamLangCode(st));
    }
    if (count <= 0) return "";
    if (langs.length > 0) return prefix + " " + langs.join(" / ");
    return prefix + " " + count + " piste" + (count > 1 ? "s" : "");
}
function _isGenericAudioSubtitleTag(tag) {
    var s = _tagFold(tag);
    if (!s || /^\+[0-9]+$/.test(s)) return true;
    if (s === "st" || s === "sub" || s === "subs" || s === "subtitle" || s === "subtitles" || s === "sous titres" || s === "sous-titres") return true;
    if (s === "multi" || s === "multi audio" || s === "multiaudio" || s === "audio multi") return true;
    return false;
}
function enrichMediaTags(src, baseTags) {
    var out = [];
    baseTags = baseTags || [];
    for (var i = 0; i < baseTags.length; i++) {
        var tag = String(baseTags[i] || "");
        if (!_isGenericAudioSubtitleTag(tag)) _tagPushUnique(out, tag);
    }
    var audioTag = _streamLangListTag(src, "Audio", "AUDIO"); var subTag = _streamLangListTag(src, "Subtitle", "ST");
    if (audioTag.length > 0) _tagPushUnique(out, audioTag);
    if (subTag.length > 0) _tagPushUnique(out, subTag);
    return out;
}
function computeSeasonTags(src) {
    if (!src) return [];
    var t = [];
    try { t = computeTags(src) || []; } catch (e0) { t = []; }
    return enrichMediaTags(src, t);
}
function recomputeTagsFromDetails(ctx, force) {
    if (!ctx) return;
    try { if (ctx.disposed) return; } catch (e0) {}
    var useDetails = false; var src = null;
    try {
        useDetails = !!(ctx.selectedDetails && ctx.selectedDetails.Id);
        src = useDetails ? ctx.selectedDetails : ctx.selectedEpisode;
    } catch (e1) {
        useDetails = false;
        src = null;
    }
    var srcId = "";
    try { srcId = (src && src.Id) ? String(src.Id) : ""; } catch (e2) { srcId = ""; }
    var oldSrcId = ""; var oldUseDetails = false;
    try { oldSrcId = String(ctx._tagsSrcId || ""); } catch (e3) {}
    try { oldUseDetails = !!ctx._tagsSrcIsDetails; } catch (e4) {}
    if (!force && srcId === oldSrcId && useDetails === oldUseDetails)
        return;
    var t = computeSeasonTags(src); var sig = t.join("\u001f");
    try { ctx._tagsSrcId = srcId; } catch (e5) {}
    try { ctx._tagsSrcIsDetails = useDetails; } catch (e6) {}
    try {
        if (sig === String(ctx._tagsSignature || ""))
            return;
    } catch (e7) {}
    try { ctx._tagsSignature = sig; } catch (e8) {}
    try { ctx._tagsAll = t; } catch (e9) {}
    try { ctx._tagsShown = t; } catch (e10) {}
    try { ctx._tagsExtraCount = 0; } catch (e11) {}
}

/* ================== DetailSeriePage: helpers purs ================== */

function ticksToSeconds(ticks) {
    var value = Number(ticks || 0);
    return value > 0 ? Math.floor(value / 10000000) : 0;
}

function formatTicksToHhMm(ticks) {
    var totalSec = ticksToSeconds(ticks);
    if (!totalSec) return "";
    var hours = Math.floor(totalSec / 3600);
    var minutes = Math.floor((totalSec % 3600) / 60);
    if (hours > 0)
        return hours + " h " + (minutes < 10 ? "0" + minutes : String(minutes));
    return minutes + " min";
}

function formatEndClockFromTicks(ticks) {
    var value = Number(ticks || 0);
    if (value <= 0) return "";
    var date = new Date(Date.now() + Math.floor(value / 10000));
    return pad2(date.getHours()) + ":" + pad2(date.getMinutes());
}

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
    return { move: !fullyVisible || tooLow || cutBottom || cutTop, y: wanted };
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

function ensureItemVisible(flick, target, margin) {
    if (!flick || !target || !target.visible) return;
    var safeMargin = margin || 20;
    var point = target.mapToItem(flick.contentItem, 0, 0);
    var top = point.y - safeMargin;
    var bottom = point.y + target.height + safeMargin;
    var viewTop = flick.contentY;
    var viewBottom = flick.contentY + flick.height;
    var maxY = Math.max(0, flick.contentHeight - flick.height);
    if (top < viewTop)
        flick.contentY = Math.max(0, top);
    else if (bottom > viewBottom)
        flick.contentY = Math.max(0, Math.min(maxY, bottom - flick.height));
}

function focusFirstSeason(block) {
    if (!block) return;
    if (block.forceFirstFocus) block.forceFirstFocus();
    else if (block.grid && block.grid.forceFirstFocus) block.grid.forceFirstFocus();
}

function restoreCastFocus(block) {
    if (!block) return;
    if (block.restoreLastActorFocus) block.restoreLastActorFocus();
    else if (block.focusFirstActor) block.focusFirstActor();
    else if (block.forceFirstActorFocus) block.forceFirstActorFocus();
}

