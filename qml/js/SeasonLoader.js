.pragma library
.import "SeasonUtils.js" as SeasonUtils
.import "MediaCatalog.js" as MediaCatalog
.import "GuestCredits.js" as GuestCredits

// Chargement de la saison et de ses épisodes, sans rendu ni navigation.
// API : load(ctx, Jellyfin), cancel(ctx, reason), refreshSelectedTags(ctx, force).
// ctx conserve les handles et générations ; aucun état de page n’est global.
// Les callbacks restent protégés par disposed/reqSeq, y compris après annulation.

function _fetchUnknownEpisodes(serverUrl, userId, seriesId, accessToken,
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

function _applySeasonEpisodesLoadError(ctx, err, Jellyfin) {
    if (!ctx) return;
    try { if (ctx.loadingError !== undefined) ctx.loadingError = _seasonLoadErrorMessage(err); } catch (e0) {}
    // Ne pas forcer [] sur erreur : [] signifie vraie saison vide et déclenche “Aucun épisode trouvé”.
    // null garde le sens “chargement impossible/erreur” et laisse loadingError parler clairement.
    try { ctx.episodes = null; } catch (e1) {}
    try { if (ctx._episodesFetchedOnce !== undefined) ctx._episodesFetchedOnce = true; } catch (e2) {}
    try { ctx.currentIndex = 0; } catch (e3) {}
    try { if (ctx.episodesPartial !== undefined) ctx.episodesPartial = false; } catch (eP) {}
    _publishPlaylistAndPoster(ctx, Jellyfin);
    try { if (ctx.maybeEndLoading) ctx.maybeEndLoading(); } catch (e4) {}
}

function cancel(ctx, reason) {
    if (!ctx) return false;
    var cancelled = false; var names = ["_seasonItemLoadHandle", "_episodesLoadHandle"];
    for (var i = 0; i < names.length; i++) {
        var name = names[i], h = null;
        try { h = ctx[name]; ctx[name] = null; } catch(e0) { h = null; }
        try { if (h && h.cancel) cancelled = h.cancel(reason || "context_changed") || cancelled; } catch(e1) {}
    }
    return cancelled;
}

function load(ctx, Jellyfin) {
    if (!ctx || !Jellyfin) return;
    cancel(ctx, "replaced");
    ctx.reqSeq = (ctx.reqSeq || 0) + 1;
    // Capturer les identifiants avant le premier callback : un changement de
    // contexte ne doit pas retargeter les requêtes d’une génération précédente.
    var request = {
        seq: ctx.reqSeq,
        serverUrl: ctx.serverUrl,
        accessToken: ctx.accessToken,
        seasonId: ctx.seasonId,
        seriesId: ctx.seriesId,
        userId: ctx.userId
    };
    ctx.seasonItem = null;
    ctx.episodes = null;
    ctx.selectedDetails = null;
    ctx.guestStars = [];
    try { if (ctx.episodesPartial !== undefined) ctx.episodesPartial = false; } catch(e) {}
    GuestCredits.clearContextGuestId(ctx);
    SeasonUtils.updatePlaylistFromEpisodes(ctx);

    if (request.serverUrl && request.accessToken && request.seasonId)
        return _loadLinkedSeason(ctx, Jellyfin, request);
    if (request.serverUrl && request.accessToken && request.seriesId)
        return _loadUnlinkedSeason(ctx, Jellyfin, request);

    ctx.seasonItem = _fallbackSeasonItem(request.seasonId, request.seriesId);
    ctx.episodes = [];
    ctx.selectedDetails = null;
    ctx.guestStars = [];
    GuestCredits.clearContextGuestId(ctx);
    _publishPlaylistAndPoster(ctx, Jellyfin);
}

// Publier les résultats dans le même ordre pour les deux types de saison.
function _publishPlaylistAndPoster(ctx, Jellyfin) {
    try { ctx.fallbackPosterUrl = MediaCatalog.seasonPosterFallbackUrl(Jellyfin, ctx); } catch(e) {}
    SeasonUtils.updatePlaylistFromEpisodes(ctx);
}

function _applyEpisodes(ctx, Jellyfin, items, meta) {
    _clearSeasonLoadError(ctx);
    try { if (ctx.episodesPartial !== undefined) ctx.episodesPartial = !!(meta && meta.partial); } catch(e) {}
    ctx.episodes = items;
    var index = SeasonUtils.desiredIndexFromInputs(items, ctx.preselectEpisodeId,
                                                 ctx.restoreEpisodeId, ctx.restoreIndex, ctx.playlist);
    ctx.currentIndex = index >= 0 ? index : 0;
    _publishPlaylistAndPoster(ctx, Jellyfin);
}

function _applyUnlinkedSeason(ctx, Jellyfin, seriesId, series) {
    ctx.seasonItem = {
        Id: series ? (series.Id || seriesId) : seriesId,
        SeriesName: series ? (series.Name || "") : "",
        Name: "Saison inconnue",
        IndexNumber: null
    };
    if (series) {
        try { ctx.seriesItem = series; } catch(e) {}
    }
    _publishPlaylistAndPoster(ctx, Jellyfin);
}

function _loadLinkedSeason(ctx, Jellyfin, request) {
    var mySeq = request.seq;
    var serverUrl = request.serverUrl;
    var accessToken = request.accessToken;
    var seasonId = request.seasonId;
    var userId = request.userId;

    if (Jellyfin.fetchItem) {
        var seasonItemHandle = null;
        seasonItemHandle = Jellyfin.fetchItem(serverUrl, accessToken, seasonId,
            function (res) {
                if (ctx.disposed || mySeq !== ctx.reqSeq)
                    return;
                try { if (ctx._seasonItemLoadHandle === seasonItemHandle) ctx._seasonItemLoadHandle = null; } catch(eH0) {}
                ctx.seasonItem = res || _fallbackSeasonItem(seasonId, "");
                SeasonUtils.updatePlaylistFromEpisodes(ctx);
            },
            function () {
                if (ctx.disposed || mySeq !== ctx.reqSeq)
                    return;
                try { if (ctx._seasonItemLoadHandle === seasonItemHandle) ctx._seasonItemLoadHandle = null; } catch(eH1) {}
                ctx.seasonItem = _fallbackSeasonItem(seasonId, "");
                SeasonUtils.updatePlaylistFromEpisodes(ctx);
            }
        );
        try { ctx._seasonItemLoadHandle = seasonItemHandle; } catch(eH2) {}
    } else {
        ctx.seasonItem = _fallbackSeasonItem(seasonId, "");
        SeasonUtils.updatePlaylistFromEpisodes(ctx);
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
                _applyEpisodes(ctx, Jellyfin, items, meta);
            },
            function (err) {
                if (ctx.disposed || mySeq !== ctx.reqSeq)
                    return;
                try { if (ctx._episodesLoadHandle === episodesHandle) ctx._episodesLoadHandle = null; } catch(eH4) {}
                _applySeasonEpisodesLoadError(ctx, err, Jellyfin);
            }
        );
        try { ctx._episodesLoadHandle = episodesHandle; } catch(eH5) {}
    } else {
        ctx.episodes = [];
        _publishPlaylistAndPoster(ctx, Jellyfin);
    }
    try { return ctx._episodesLoadHandle || ctx._seasonItemLoadHandle || null; } catch(eRet0) { return null; }
}

function _loadUnlinkedSeason(ctx, Jellyfin, request) {
    var mySeq = request.seq;
    var serverUrl = request.serverUrl;
    var accessToken = request.accessToken;
    var seriesId = request.seriesId;
    var userId = request.userId;

    if (Jellyfin.fetchItem) {
        var seriesItemHandle = null;
        seriesItemHandle = Jellyfin.fetchItem(serverUrl, accessToken, seriesId,
            function (res) {
                if (ctx.disposed || mySeq !== ctx.reqSeq)
                    return;
                try { if (ctx._seasonItemLoadHandle === seriesItemHandle) ctx._seasonItemLoadHandle = null; } catch(eH6) {}
                var series = res || {};
                _applyUnlinkedSeason(ctx, Jellyfin, seriesId, series);
            },
            function () {
                if (ctx.disposed || mySeq !== ctx.reqSeq)
                    return;
                try { if (ctx._seasonItemLoadHandle === seriesItemHandle) ctx._seasonItemLoadHandle = null; } catch(eH7) {}
                _applyUnlinkedSeason(ctx, Jellyfin, seriesId, null);
            }
        );
        try { ctx._seasonItemLoadHandle = seriesItemHandle; } catch(eH8) {}
    } else {
        _applyUnlinkedSeason(ctx, Jellyfin, seriesId, null);
    }
    if (!userId) {
        ctx.episodes = [];
        ctx.currentIndex = 0;
        _publishPlaylistAndPoster(ctx, Jellyfin);
        try { return ctx._seasonItemLoadHandle || null; } catch(eRet1) { return null; }
    }
    var unknownEpisodesHandle = null;
    unknownEpisodesHandle = _fetchUnknownEpisodes(serverUrl, userId, seriesId, accessToken, Jellyfin,
        function (items, meta) {
            if (ctx.disposed || mySeq !== ctx.reqSeq)
                return;
            try { if (ctx._episodesLoadHandle === unknownEpisodesHandle) ctx._episodesLoadHandle = null; } catch(eH9) {}
            var filtered = SeasonUtils.bucketUnknownEpisodes(
                items || [],
                ctx.unknownSeasonNumber,
                ctx.sntSentinel,
                ctx.preselectEpisodeId
            );
            _applyEpisodes(ctx, Jellyfin, filtered, meta);
        },
        function (err) {
            if (ctx.disposed || mySeq !== ctx.reqSeq)
                return;
            try { if (ctx._episodesLoadHandle === unknownEpisodesHandle) ctx._episodesLoadHandle = null; } catch(eH10) {}
            _applySeasonEpisodesLoadError(ctx, err, Jellyfin);
        }
    );
    try { ctx._episodesLoadHandle = unknownEpisodesHandle; } catch(eH11) {}
    return unknownEpisodesHandle;
}

function refreshSelectedTags(ctx, force) {
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
    var t = MediaCatalog.episodeTechChips(src); var sig = t.join("\u001f");
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
