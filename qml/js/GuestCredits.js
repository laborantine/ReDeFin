.pragma library
.import "SafeLog.js" as SafeLog

// Identification, chargement et présentation des personnes invitées
// sur une fiche épisode. Cache borné, sans dépendance vers SeasonUtils.

// Compatibilité historique : les tokens Jellyfin ne sont jamais ajoutés aux URL Image.source.
function _safeCacheId(prefix, value) {
    value = String(value || "");
    if (!value) return prefix + "#empty";
    return prefix + "#" + SafeLog.shortHash(value);
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
function clearContextGuestId(ctx) { _setCtxGuestId(ctx, ""); }
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
function shouldFetchFullPeople(ctx) {
    if (!ctx) return false;
    if (ctx.currentFocus === 2) return true;
    if (ctx.wantsGuestFocus === true) return true;
    if (ctx.autoRevealGuests === true) return true;
    if (ctx._guestPrefetch === true) return true;
    return false;
}
function fetchSelectedDetails(ctx, Jellyfin, onMissingEpisode) {
    if (!ctx || !Jellyfin) return;
    var ep = ctx.selectedEpisode;
    if (!ep || !ctx.serverUrl || !ctx.accessToken) {
        ctx.selectedDetails = null;
        ctx.guestStars = [];
        _setCtxGuestId(ctx, "");
        if (typeof onMissingEpisode === "function") onMissingEpisode(ctx);
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
function getRefs(ctx) {
    var r = null;
    try { r = ctx ? ctx.__seasonRefs : null; } catch (e) { r = null; }
    return r || {};
}
