.pragma library

// Interprétation pure des MediaStreams Jellyfin et sélection audio/sous-titres.
// Aucun réseau, aucun état de session et aucune politique de matériel.
// Core, CoreUrl et les backends partagent ces règles sans injection de callbacks.
// Les fonctions préfixées par _ restent internes à cette bibliothèque.

function _s(v){ return (v === undefined || v === null) ? "" : (v + "") }

function extensionOf(urlOrName) {
    var s = _s(urlOrName)
    var m = s.match(/\.([a-z0-9]{2,5})(?:$|\?)/i)
    return m ? m[1].toLowerCase() : ""
}

function normalizePlaybackRuleMode(value) {
    return _s(value).toLowerCase().trim() === "directplay" ? "directplay" : "smart"
}

function smartPlaybackRulesEnabled(ctx) {
    return normalizePlaybackRuleMode(ctx && ctx.playbackRuleMode) !== "directplay"
}

function fold(s) {
    s = _s(s).toLowerCase()
    s = s.replace(/[àáâãäå]/g, "a")
    s = s.replace(/[ç]/g, "c")
    s = s.replace(/[èéêë]/g, "e")
    s = s.replace(/[ìíîï]/g, "i")
    s = s.replace(/[ñ]/g, "n")
    s = s.replace(/[òóôõö]/g, "o")
    s = s.replace(/[ùúûü]/g, "u")
    s = s.replace(/[ýÿ]/g, "y")
    return s
}

function _hasLooseToken(haystack, token) {
    haystack = fold(haystack)
    token = fold(token)
    if (!haystack || !token) return false
    try {
        var rx = new RegExp("(^|[^a-z0-9])" + token.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "([^a-z0-9]|$)")
        return rx.test(haystack)
    } catch(e) {}
    return haystack.indexOf(token) >= 0
}

function _typeName(st) {
    if (!st) return ""
    var t = st.Type
    if (t === 0) return "Audio"
    if (t === 1) return "Video"
    if (t === 2) return "Subtitle"
    var name = _s(t).toLowerCase()
    if (name === "audio") return "Audio"
    if (name === "video") return "Video"
    if (name === "subtitle") return "Subtitle"
    return ""
}

function isType(st, name) { return _typeName(st) === name }

function firstStream(src, type) {
    if (!src || !src.MediaStreams) return null
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var s = src.MediaStreams[i]
        if (s && isType(s, type)) return s
    }
    return null
}

function subtitleStreamByIndex(src, subIndex) {
    if (!src || !src.MediaStreams || typeof subIndex !== "number" || subIndex < 0) return null
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (st && isType(st, "Subtitle") && st.Index === subIndex) return st
    }
    return null
}

function audioStreamByIndex(src, audioIndex) {
    if (!src || !src.MediaStreams || typeof audioIndex !== "number" || audioIndex < 0) return null
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (st && isType(st, "Audio") && st.Index === audioIndex) return st
    }
    return null
}

function firstAudioStreamIndex(src) {
    if (!src || !src.MediaStreams) return -1
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !isType(st, "Audio")) continue
        return (typeof st.Index === "number") ? st.Index : i
    }
    return -1
}

function defaultAudioStreamIndex(src) {
    if (!src || !src.MediaStreams) return -1
    var firstAudio = -1; var forcedAudio = -1
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !isType(st, "Audio")) continue
        var idx = (typeof st.Index === "number") ? st.Index : i
        if (firstAudio < 0)
            firstAudio = idx
        if (forcedAudio < 0 && st.IsForced === true)
            forcedAudio = idx
        if (st.IsDefault === true) return idx
    }
    if (forcedAudio >= 0) return forcedAudio
    return firstAudio
}

function streamCountOfType(src, typeName) {
    if (!src || !src.MediaStreams) return 0
    var count = 0
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (st && isType(st, typeName))
            count++
    }
    return count
}

function hasExplicitAudio(ctx) { return !!(ctx && typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0) }

function _preferFrenchAudioEnabled(ctx) { if (!ctx) return true; if (ctx.disableAutoFrenchAudio === true) return false; if (ctx.preferFrenchAudio === false) return false; return true }

function _audioBlob(st) { if (!st) return ""; return [ st.Language || "", st.Title || "", st.DisplayTitle || "", st.Profile || "", st.Codec || "", st.ChannelLayout || "" ].join(" ") }

function _isBadAudioVariant(st) {
    var b = fold(_audioBlob(st))
    if (b.indexOf("commentaire") >= 0) return true
    if (b.indexOf("commentary") >= 0) return true
    if (b.indexOf("director") >= 0) return true
    if (b.indexOf("realisateur") >= 0) return true
    if (b.indexOf("audio description") >= 0) return true
    if (b.indexOf("description audio") >= 0) return true
    if (b.indexOf("audiodescription") >= 0) return true
    if (b.indexOf("descriptive audio") >= 0) return true
    if (b.indexOf("malvoyant") >= 0) return true
    if (b.indexOf("hearing impaired") >= 0) return true
    return false
}

function _frenchAudioVariantTier(st) {
    if (!st || !isType(st, "Audio")) return -1
    if (_isBadAudioVariant(st)) return -1
    var lang = fold(st.Language || ""); var blob = fold(_audioBlob(st)); var languageIsFrench = lang === "fra" ||
        lang === "fre" || lang === "fr" ||
        lang === "french" || lang === "francais"
    var labelIsFrench = _hasLooseToken(blob, "fr") ||
        _hasLooseToken(blob, "fra") || _hasLooseToken(blob, "fre") ||
        _hasLooseToken(blob, "francais") || _hasLooseToken(blob, "french") ||
        _hasLooseToken(blob, "vf") || _hasLooseToken(blob, "vff") ||
        _hasLooseToken(blob, "vfi") || _hasLooseToken(blob, "vfq") ||
        blob.indexOf("truefrench") >= 0
    if (!languageIsFrench && !labelIsFrench) return -1
    if (blob.indexOf("truefrench") >= 0 || _hasLooseToken(blob, "vff") ||
        _hasLooseToken(blob, "vfi"))
        return 3
    if (_hasLooseToken(blob, "vfq") || _hasLooseToken(blob, "quebec") ||
        _hasLooseToken(blob, "quebecois") || blob.indexOf("french canadian") >= 0 ||
        blob.indexOf("canadian french") >= 0)
        return 1
    return 2
}

function _frenchAudioTechnicalTieBreak(st) {
    if (!st) return 0
    var score = 0
    if (st.IsDefault === true) score += 40
    if (st.IsForced === true) score -= 20
    var ch = 0
    try { ch = parseInt(_s(st.Channels || 0), 10) } catch(e) {}
    if (isFinite(ch) && ch > 0)
        score += Math.min(24, ch * 4)
    var br = 0
    try { br = parseInt(_s(st.BitRate || 0), 10) } catch(e2) {}
    if (isFinite(br) && br > 0)
        score += Math.min(20, Math.floor(br / 192000))
    return score
}

function scoreFrenchAudioStream(st) { var tier = _frenchAudioVariantTier(st); if (tier < 0) return -9999; return (tier * 1000) + _frenchAudioTechnicalTieBreak(st) }

function _bestFrenchAudioStreamIndex(src) {
    if (!src || !src.MediaStreams) return -1
    var bestIdx = -1; var bestScore = -9999
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !isType(st, "Audio")) continue
        var idx = (typeof st.Index === "number") ? st.Index : i; var score = scoreFrenchAudioStream(st)
        if (score > bestScore) {
            bestScore = score
            bestIdx = idx
        }
    }
    return bestScore >= 80 ? bestIdx : -1
}

function _hasReliableFrenchAudio(src) {
    return _bestFrenchAudioStreamIndex(src) >= 0
}

function _isReliableNonFrenchAudioStream(st) {
    if (!st || !isType(st, "Audio") || _isBadAudioVariant(st)) return false
    if (scoreFrenchAudioStream(st) >= 80) return false
    var lang = fold(st.Language || "").trim(); var blob = fold(_audioBlob(st))
    if (_hasLooseToken(blob, "vo") || _hasLooseToken(blob, "original") ||
        _hasLooseToken(blob, "anglais") || _hasLooseToken(blob, "english"))
        return true
    if (!lang || lang === "und" || lang === "undefined" || lang === "unknown" || lang === "zxx" || lang === "mul") return false
    return !(lang === "fr" || lang === "fra" || lang === "fre" || lang === "french" || lang === "francais")
}

function _hasReliableNonFrenchAudio(src) {
    if (!src || !src.MediaStreams) return false
    for (var i = 0; i < src.MediaStreams.length; i++) {
        if (_isReliableNonFrenchAudioStream(src.MediaStreams[i])) return true
    }
    return false
}

function _isVoFrenchSubtitleMediaCandidate(st) {
    if (!st || !isType(st, "Subtitle") || st.IsExternal === true) return false
    if (!_isFrenchSubtitleLanguage(st)) return false
    if (st.IsForced === true || _subtitleLooksForcedOnly(st)) return false
    var codec = _s(st.Codec).toLowerCase()
    if (isDvdSubtitleCodec(codec)) return false
    var textish = (st.IsTextSubtitleStream === true) || isTextSubtitleCodec(codec)
    return textish || _isPgsSubtitleStream(st)
}

function _isUniqueVoFrenchUnforcedSubtitleCandidate(src, st) {
    if (!src || !src.MediaStreams || !_isVoFrenchSubtitleMediaCandidate(st)) return false
    // Secours volontairement étroit : une seule piste audio, explicitement VO,
    // et un seul sous-titre français interne non forcé exploitable. Cela couvre
    // les MKV dont la piste complète est seulement nommée "French"/"Français"
    // sans élargir la règle aux fichiers multiaudio ou aux pistes ambiguës.
    if (streamCountOfType(src, "Audio") !== 1) return false
    if (_hasReliableFrenchAudio(src) || !_hasReliableNonFrenchAudio(src)) return false
    var wantedIndex = (typeof st.Index === "number") ? st.Index : -1; var candidateCount = 0; var onlyIndex = -1
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var other = src.MediaStreams[i]
        if (!_isVoFrenchSubtitleMediaCandidate(other)) continue
        candidateCount++
        onlyIndex = (typeof other.Index === "number") ? other.Index : i
        if (candidateCount > 1) return false
    }
    return candidateCount === 1 && wantedIndex >= 0 && onlyIndex === wantedIndex
}

function _isFrenchFullSubtitleCandidate(src, st) {
    if (!_isVoFrenchSubtitleMediaCandidate(st)) return false
    if (_subtitleLooksFullOrAccessibility(st)) return true
    return _isUniqueVoFrenchUnforcedSubtitleCandidate(src, st)
}

function _frenchFullSubtitleAutoScore(src, st) {
    if (!_isFrenchFullSubtitleCandidate(src, st)) return -1
    var codec = _s(st.Codec).toLowerCase(); var textish = (st.IsTextSubtitleStream === true) || isTextSubtitleCodec(codec); var accessibility = st.IsHearingImpaired === true || _subtitleMatchText(st).indexOf("sdh") >= 0 ||
                        _subtitleMatchText(st).indexOf("malentendant") >= 0 || _subtitleMatchText(st).indexOf("hearing") >= 0
    var explicitlyFull = _subtitleLooksFullOrAccessibility(st); var score = textish ? 400 : 300
    if (!explicitlyFull) score -= 80
    if (accessibility) score -= 200
    if (st.IsDefault === true) score += 10
    return score
}

function _bestFrenchFullSubtitleIndex(src) {
    if (!src || !src.MediaStreams) return -1
    var bestIndex = -1; var bestScore = -1
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]; var score = _frenchFullSubtitleAutoScore(src, st)
        if (score > bestScore) {
            bestScore = score
            bestIndex = (typeof st.Index === "number") ? st.Index : i
        }
    }
    return bestIndex
}

function autoVoFrenchFullSubtitleIndex(ctx, src) {
    if (!ctx || !src) return -1
    if (ctx.manualDirectPlayOverride === true) return -1
    if (ctx.disableAutoVoFrenchFullSubtitle === true) return -1
    if (ctx.useLocalSubs === true) return -1
    if (typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) return -1
    if (hasExplicitAudio(ctx)) return -1
    if (_hasReliableFrenchAudio(src)) return -1
    if (!_hasReliableNonFrenchAudio(src)) return -1
    return _bestFrenchFullSubtitleIndex(src)
}

function preferredFrenchAudioNeedsServerSelection(ctx, src) {
    if (!_preferFrenchAudioEnabled(ctx) || hasExplicitAudio(ctx)) return false
    if (!src || !src.MediaStreams) return false
    var bestFrench = _bestFrenchAudioStreamIndex(src)
    var firstAudio = firstAudioStreamIndex(src)
    return bestFrench >= 0 && firstAudio >= 0 && bestFrench !== firstAudio
}

function _shouldAutoSelectFrenchAudio(ctx, src) {
    if (!_preferFrenchAudioEnabled(ctx) || hasExplicitAudio(ctx)) return false
    if (!src || !src.MediaStreams) return false
    var bestFrench = _bestFrenchAudioStreamIndex(src)
    if (bestFrench < 0) return false
    var defaultAudio = defaultAudioStreamIndex(src)
    var firstAudio = firstAudioStreamIndex(src)
    return bestFrench !== defaultAudio || bestFrench !== firstAudio
}

function autoFrenchAudioStreamIndex(ctx, src) { if (!_shouldAutoSelectFrenchAudio(ctx, src)) return -1; return _bestFrenchAudioStreamIndex(src) }

function shouldPinDefaultAudioForNoSubRemux(ctx, src, remuxNoSubs) { if (!remuxNoSubs) return false; if (!ctx || !src) return false; if (hasExplicitAudio(ctx)) return false; var def = defaultAudioStreamIndex(src); if (def < 0) return false; return true }

function shouldRemuxDefaultFrenchAudioNotFirst(ctx, src) {
    if (!ctx || !src || ctx.disableDefaultFrenchAudioOrderRemux === true) return false
    if (hasExplicitAudio(ctx)) return false
    var defaultIndex = defaultAudioStreamIndex(src)
    var firstIndex = firstAudioStreamIndex(src)
    if (defaultIndex < 0 || firstIndex < 0 || defaultIndex === firstIndex) return false
    return scoreFrenchAudioStream(audioStreamByIndex(src, defaultIndex)) >= 80
}

function effectiveAudioStreamForServer(ctx, src, imageSubtitleSelected, forceImageBurnIn, preferImageRemux, forcePinDefaultAudio, autoFrenchAudioIndex) {
    if (ctx && typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0) return ctx.selectedAudioStream
    if (typeof autoFrenchAudioIndex === "number" && autoFrenchAudioIndex >= 0) return autoFrenchAudioIndex
    if (!ctx || !src) return -1
    var needsPinnedAudio = (forcePinDefaultAudio === true) ||
        (imageSubtitleSelected === true) || (forceImageBurnIn === true) ||
        (preferImageRemux === true)
    if (!needsPinnedAudio) return -1
    return defaultAudioStreamIndex(src)
}

function isTextSubtitleCodec(codec) { codec = _s(codec).toLowerCase(); return codec === "srt" || codec === "subrip" || codec === "ass" || codec === "ssa" || codec === "webvtt" || codec === "vtt" || codec === "mov_text" || codec === "tx3g" || codec === "dvbtxt" }

function isImageSubtitleCodec(codec) { codec = _s(codec).toLowerCase(); return codec === "pgssub" || codec === "pgs" || codec === "hdmv_pgs_subtitle" || codec === "dvdsub" || codec === "dvd_subtitle" || codec === "vobsub" || codec === "dvbsub" || codec === "dvb_subtitle" || codec === "xsub" }

function isDvdSubtitleCodec(codec) { codec = _s(codec).toLowerCase(); return codec === "dvdsub" || codec === "dvd_subtitle" || codec === "vobsub" }

function _isDvdSubtitleStream(st) { if (!st || !isType(st, "Subtitle")) return false; return isDvdSubtitleCodec(st.Codec) }

function hasInternalDvdSubtitle(src) {
    if (!src || !src.MediaStreams) return false
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (_isDvdSubtitleStream(st) && st.IsExternal !== true) return true
    }
    return false
}

function isTransportStreamContainer(container, path) { var c = _s(container).toLowerCase().trim(); if (c.indexOf(",") >= 0) c = c.split(",")[0]; if (!c) c = extensionOf(path || ""); return c === "ts" || c === "m2ts" || c === "mts" || c === "mpegts" }

function hasInterlacedH264Video(streams) {
    if (!streams) return false
    for (var i = 0; i < streams.length; i++) {
        var st = streams[i]
        if (!st || !isType(st, "Video")) continue
        var codec = _s(st.Codec).toLowerCase()
        if ((codec === "h264" || codec === "avc") && st.IsInterlaced === true) return true
    }
    return false
}

function safeFrenchForcedDvdSubtitleIndex(src) {
    if (!src || !src.MediaStreams) return -1
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!_isDvdSubtitleStream(st) || st.IsExternal === true) continue
        if (isSafeFrenchForcedSubtitle(st, src)) return (typeof st.Index === "number") ? st.Index : i
    }
    return -1
}

function isImageSubtitleSelected(src, subIndex) { var st = subtitleStreamByIndex(src, subIndex); if (!st) return false; var codec = _s(st.Codec).toLowerCase(); var textish = (st.IsTextSubtitleStream === true) || isTextSubtitleCodec(codec); if (isImageSubtitleCodec(codec)) return true; return !textish }

function isTextSubtitleSelected(src, subIndex) { var st = subtitleStreamByIndex(src, subIndex); if (!st) return false; var codec = _s(st.Codec).toLowerCase(); if (st.IsTextSubtitleStream === true) return true; return isTextSubtitleCodec(codec) }

function containerOrExt(src) {
    var cont = _s(src && src.Container).toLowerCase()
    if (cont.indexOf(",") >= 0) cont = cont.split(",")[0]
    if (cont) return cont
    return extensionOf(src && src.Path ? src.Path : "")
}

function _plainSubtitleMatchText(v) {
    var s = _s(v).toLowerCase()
    s = s.replace(/[àáâãäåā]/g, "a")
    s = s.replace(/[ç]/g, "c")
    s = s.replace(/[èéêëēėę]/g, "e")
    s = s.replace(/[îïíīįì]/g, "i")
    s = s.replace(/[ôöòóõøō]/g, "o")
    s = s.replace(/[ùúûüū]/g, "u")
    s = s.replace(/[ÿ]/g, "y")
    return s
}

function _subtitleMatchText(st) {
    if (!st) return ""
    return _plainSubtitleMatchText( _s(st.Title) + " " +
        _s(st.DisplayTitle) + " " + _s(st.Language)
    )
}

function _rawSubtitleTitleDeclaresFrench(st) {
    if (!st) return false
    var t = _plainSubtitleMatchText(_s(st.Title))
    if (!t)
        t = _plainSubtitleMatchText(_s(st.DisplayTitle))
    if (!t) return false
    return /(^|[^a-z0-9])(fr|fra|fre|vff|vfi|vfq|truefrench)([^a-z0-9]|$)/.test(t)
}

function _isFrenchSubtitleLanguage(st) {
    if (!st) return false
    var lang = _plainSubtitleMatchText(st.Language)
    if (lang === "fr" || lang === "fra" || lang === "fre" || lang === "french" || lang === "francais") return true
    var t = _subtitleMatchText(st)
    if (t.indexOf("francais") >= 0 || t.indexOf("french") >= 0) return true
    return _rawSubtitleTitleDeclaresFrench(st)
}

function _subtitleLooksFullOrAccessibility(st) {
    if (!st) return false
    var t = _subtitleMatchText(st)
    return t.indexOf("complet") >= 0 || t.indexOf("complete") >= 0 ||
           t.indexOf("full") >= 0 || t.indexOf("integral") >= 0 ||
           t.indexOf("sdh") >= 0 || t.indexOf("malentendant") >= 0 ||
           t.indexOf("hearing") >= 0
}

function _subtitleLooksForcedOnly(st) {
    if (!st) return false
    var t = _subtitleMatchText(st); var forced = (st.IsForced === true) || t.indexOf("force") >= 0 ||
                 t.indexOf("forced") >= 0
    if (!forced) return false
    if (_subtitleLooksFullOrAccessibility(st)) return false
    return true
}

function _rawSubtitleTitleText(st) {
    return _plainSubtitleMatchText(st ? _s(st.Title) : "")
}

function _rawSubtitleTitleLooksForcedOnly(st) {
    var t = _rawSubtitleTitleText(st)
    if (!t) return false
    var forced = t.indexOf("force") >= 0 || t.indexOf("forced") >= 0
    if (!forced) return false
    return !(t.indexOf("complet") >= 0 || t.indexOf("complete") >= 0 ||
             t.indexOf("full") >= 0 || t.indexOf("integral") >= 0 ||
             t.indexOf("sdh") >= 0 || t.indexOf("malentendant") >= 0 ||
             t.indexOf("hearing") >= 0)
}

function _isPgsSubtitleStream(st) {
    if (!st) return false
    var codec = _s(st.Codec).toLowerCase()
    return codec === "pgssub" || codec === "pgs" ||
           codec === "hdmv_pgs_subtitle" || codec === "s_hdmv/pgs"
}

function _isPairedLegacyFrenchForcedPgsSubtitle(src, st) {
    if (!src || !src.MediaStreams || !st || st.IsExternal === true || st.IsForced === true) return false
    if (!_isPgsSubtitleStream(st) || !_isFrenchSubtitleLanguage(st) || !_rawSubtitleTitleLooksForcedOnly(st)) return false
    if (_subtitleLooksFullOrAccessibility(st)) return false
    var candidateIndex = (typeof st.Index === "number") ? st.Index : -1
    if (candidateIndex < 0 || firstInternalSubtitleStreamIndex(src) !== candidateIndex) return false
    var fullAfter = false, forcedCandidates = 0, otherPriority = false
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var other = src.MediaStreams[i]
        if (!other || !isType(other, "Subtitle") || other.IsExternal === true) continue
        if (other !== st && (other.IsDefault === true || other.IsForced === true)) otherPriority = true
        if (_isPgsSubtitleStream(other) && _isFrenchSubtitleLanguage(other) &&
            _rawSubtitleTitleLooksForcedOnly(other) && !_subtitleLooksFullOrAccessibility(other)) forcedCandidates++
        if (other !== st && _isPgsSubtitleStream(other) && _isFrenchSubtitleLanguage(other) && !_rawSubtitleTitleLooksForcedOnly(other)) {
            var otherIndex = (typeof other.Index === "number") ? other.Index : i; var otherTitle = _rawSubtitleTitleText(other)
            var accessibility = otherTitle.indexOf("sdh") >= 0 || otherTitle.indexOf("malentendant") >= 0 || otherTitle.indexOf("hearing") >= 0
            if (otherIndex > candidateIndex && otherTitle && !accessibility) fullAfter = true
        }
    }
    return fullAfter && forcedCandidates === 1 && !otherPriority
}

function isSafeFrenchForcedSubtitle(st, src) {
    if (!st || !isType(st, "Subtitle")) return false
    if (st.IsExternal === true) return false
    if (!_isFrenchSubtitleLanguage(st)) return false
    var codec = _s(st.Codec).toLowerCase(); var textish = (st.IsTextSubtitleStream === true) || isTextSubtitleCodec(codec); var imageish = isImageSubtitleCodec(codec)
    if (!textish && !imageish) return false
    if (imageish && st.IsForced !== true && !_isPairedLegacyFrenchForcedPgsSubtitle(src, st)) return false
    return _subtitleLooksForcedOnly(st)
}

function isSafeFrenchForcedTextSubtitle(st) {
    if (!isSafeFrenchForcedSubtitle(st)) return false
    var codec = _s(st.Codec).toLowerCase(); var textish = (st.IsTextSubtitleStream === true) || isTextSubtitleCodec(codec)
    return !!(textish && !isImageSubtitleCodec(codec))
}

function isLegacyTitleOnlyFrenchForcedTextSubtitle(st) {
    if (!isSafeFrenchForcedTextSubtitle(st)) return false
    if (st.IsDefault === true || st.IsForced === true) return false
    var t = _subtitleMatchText(st)
    return t.indexOf("force") >= 0 || t.indexOf("forced") >= 0
}

function safeFrenchForcedSubtitleIndex(src) {
    if (!src || !src.MediaStreams) return -1
    var imageFallback = -1
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !isType(st, "Subtitle") || st.IsExternal === true) continue
        if (!(st.IsDefault === true || st.IsForced === true || _isPairedLegacyFrenchForcedPgsSubtitle(src, st))) continue
        if (!isSafeFrenchForcedSubtitle(st, src)) continue
        var idx = (typeof st.Index === "number") ? st.Index : i
        if (isSafeFrenchForcedTextSubtitle(st)) return idx
        if (imageFallback < 0) imageFallback = idx
    }
    return imageFallback
}

function firstInternalSubtitleStreamIndex(src) {
    if (!src || !src.MediaStreams) return -1
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !isType(st, "Subtitle")) continue
        if (st.IsExternal === true) continue
        return (typeof st.Index === "number") ? st.Index : i
    }
    return -1
}

function nativeDirectPlaySubtitleIndex(src) {
    return firstInternalSubtitleStreamIndex(src)
}

function preferredFrenchForcedSubtitleNeedsServerSelection(ctx, src) {
    if (!ctx || !src) return false
    if (!smartPlaybackRulesEnabled(ctx)) return false
    if (ctx.manualDirectPlayOverride === true) return false
    if (ctx.useLocalSubs === true) return false
    if (typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) return false
    var preferred = safeFrenchForcedSubtitleIndex(src)
    if (preferred < 0) return false
    var preferredStream = subtitleStreamByIndex(src, preferred)
    if (!isSafeFrenchForcedTextSubtitle(preferredStream)) return false
    var firstInternal = firstInternalSubtitleStreamIndex(src)
    return firstInternal >= 0 && firstInternal !== preferred
}

function _hasSafeFrenchForcedSelectionAnchors(src) {
    if (!src || !src.MediaStreams) return false
    var firstInternal = firstInternalSubtitleStreamIndex(src)
    if (firstInternal < 0) return false
    var firstStream = subtitleStreamByIndex(src, firstInternal)
    if (!isSafeFrenchForcedSubtitle(firstStream, src)) return false
    // Toute piste explicitement Default reste susceptible de gagner la sélection
    // native QtMultimedia. Elle doit donc être française et réellement forcée.
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !isType(st, "Subtitle") || st.IsExternal === true) continue
        if (st.IsDefault !== true) continue
        if (!isSafeFrenchForcedSubtitle(st, src)) return false
    }
    return true
}

function isIgnorableTrailingForeignForcedSubtitle(src, st) {
    if (!src || !st || !isType(st, "Subtitle")) return false
    if (st.IsExternal === true) return false
    if (st.IsForced !== true || st.IsDefault === true) return false
    if (_isFrenchSubtitleLanguage(st)) return false
    if (!_hasSafeFrenchForcedSelectionAnchors(src)) return false
    var firstInternal = firstInternalSubtitleStreamIndex(src); var idx = (typeof st.Index === "number") ? st.Index : -1
    return idx > firstInternal
}

function hasDefaultOrForcedInternalSubtitle(src) {
    if (!src || !src.MediaStreams) return false
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !isType(st, "Subtitle")) continue
        if (st.IsExternal === true) continue
        if (st.IsDefault === true || st.IsForced === true) {
            if (isSafeFrenchForcedSubtitle(st, src))
                continue
            if (isIgnorableTrailingForeignForcedSubtitle(src, st))
                continue
            return true
        }
    }
    return false
}

function hasInternalSubtitle(src) {
    if (!src || !src.MediaStreams) return false
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !isType(st, "Subtitle")) continue
        if (st.IsExternal === true) continue
        return true
    }
    return false
}

function exactAudioCodecHint(codec) {
    var c = _s(codec).toLowerCase().trim()
    if (!c) return null
    if (c === "a_dts" || c === "dca" || c === "dts") return "dts,dca"
    if (c === "eac3" || c === "ddp" || c === "dolby_digital_plus") return "eac3"
    if (c === "ac3") return "ac3"
    if (c === "truehd" || c === "mlp" || c === "mlp_fba" || c === "a_truehd" || c === "dolby_truehd" || c === "true-hd" || c === "true_hd") return "truehd"
    if (c === "aac" || c === "mp4a") return "aac"
    if (c === "mp3") return "mp3"
    if (c === "flac") return "flac"
    if (c === "opus") return "opus"
    if (c === "vorbis") return "vorbis"
    return c
}

function selectedAudioCodec(src, audioIndex) {
    var st = audioStreamByIndex(src, audioIndex)
    if (!st) return null
    return exactAudioCodecHint(st.Codec)
}

// Projection des pistes en menus et indices de démarrage ; DTO sans état UI.
function describeStreams(j) {
    j = j || {};
    var streams = j.MediaStreams || []
    var aLabels = []
    var aMap = []
    var aCodecMap = []
    var aChannelMap = []
    var aBitrateMap = []
    var sLabels = []
    var sMap = [-1]
    var sIsText = [false]
    // Aligné sur sMap : l'entrée 0 représente « Aucun ». Conserver le codec
    // exact permet au Player de distinguer MOV_TEXT/TX3G des autres textes et
    // de sélectionner leur affichage par l’overlay QML sans remux MP4.
    var sCodecMap = [""]
    var defaultAudioStreamIndex = -1
    var defaultSubtitleStreamIndex = -1
    var firstAudioStreamIndex = -1
    var firstSubtitleStreamIndex = -1
    var forcedAudioStreamIndex = -1
    var forcedSubtitleStreamIndex = -1
    var bestFrenchAudioStreamIndex = -1
    var bestFrenchAudioScore = -9999
    var frenchAudioScoreByIndex = {}
    var strictFrenchForcedDefaultTextSubtitleStreamIndex = -1
    var strictFrenchForcedDefaultSubtitleStreamIndex = -1
    var legacyFrenchForcedTextSubtitleStreamIndex = -1
    var legacyFrenchForcedTextSubtitleCandidateCount = 0
    var firstInternalSubtitleStreamIndex = -1
    var hasAnyPriorityInternalSubtitle = false
    var defaultForcedInternalSubtitlesAreSafeFrenchForced = true
    var hasPriorityInternalSubtitleRisk = false
    var hasImplicitFirstInternalSubtitleRisk = false
    var hasInternalDvdSubtitle = false
    var safeFrenchForcedDvdSubtitleStreamIndex = -1
    var requiresInterlacedTsTranscode = false
    var hasDvdNavPacket = false
    for (var i = 0; i < streams.length; i++) {
        var st = streams[i]
        if (_s(st && st.Codec).toLowerCase() === "dvd_nav_packet")
            hasDvdNavPacket = true
        if (isType(st, "Audio")) {
            var audioIdx = (typeof st.Index === "number") ? st.Index : i
            if (firstAudioStreamIndex < 0)
                firstAudioStreamIndex = audioIdx
            if (forcedAudioStreamIndex < 0 && st.IsForced === true)
                forcedAudioStreamIndex = audioIdx
            if (defaultAudioStreamIndex < 0 && st.IsDefault === true)
                defaultAudioStreamIndex = audioIdx
            var frenchScore = scoreFrenchAudioStream(st)
            frenchAudioScoreByIndex[String(audioIdx)] = frenchScore
            if (frenchScore > bestFrenchAudioScore) {
                bestFrenchAudioScore = frenchScore
                bestFrenchAudioStreamIndex = audioIdx
            }
            var lbl = (st.DisplayTitle && st.DisplayTitle.length > 0)
                    ? st.DisplayTitle
                    : ((st.Language ? st.Language : "Audio") + (st.Channels ? (" (" + st.Channels + "ch)") : ""))
            aLabels.push(lbl)
            aMap.push(audioIdx)
            aCodecMap.push(exactAudioCodecHint(st.Codec) || "")
            aChannelMap.push((typeof st.Channels === "number" && isFinite(st.Channels))
                             ? Math.max(0, Math.floor(st.Channels)) : 0)
            aBitrateMap.push((typeof st.BitRate === "number" && isFinite(st.BitRate) && st.BitRate > 0)
                             ? Math.floor(st.BitRate) : 0)
        } else if (isType(st, "Subtitle")) {
            var subIdx = (typeof st.Index === "number") ? st.Index : i
            if (firstSubtitleStreamIndex < 0)
                firstSubtitleStreamIndex = subIdx
            if (forcedSubtitleStreamIndex < 0 && st.IsForced === true)
                forcedSubtitleStreamIndex = subIdx
            if (defaultSubtitleStreamIndex < 0 && st.IsDefault === true)
                defaultSubtitleStreamIndex = subIdx
            var lab = (st.DisplayTitle && st.DisplayTitle.length > 0)
                    ? st.DisplayTitle
                    : (st.Language ? st.Language : "Sous-titres")
            sLabels.push(lab)
            sMap.push(subIdx)
            var codec = _s(st.Codec).toLowerCase()
            var codecTag = _s(st.CodecTag).toLowerCase()
            var normalizedSubtitleCodec = (codec === "tx3g" || codecTag === "tx3g") ? "mov_text" : codec
            sCodecMap.push(normalizedSubtitleCodec)
            var textish = (st.IsTextSubtitleStream === true) || isTextSubtitleCodec(codec)
            sIsText.push(!!textish)

            if (st.IsExternal !== true && isDvdSubtitleCodec(codec)) {
                hasInternalDvdSubtitle = true
                if (safeFrenchForcedDvdSubtitleStreamIndex < 0 && isSafeFrenchForcedSubtitle(st, j))
                    safeFrenchForcedDvdSubtitleStreamIndex = subIdx
            }

            // QtMultimedia peut sélectionner la première piste de sous-titres
            // physiquement interne même si Matroska ne lui donne aucun drapeau.
            // On mémorise donc la première piste INTERNE séparément des entrées
            // externes, qui restent toujours dormantes tant qu'elles ne sont pas choisies.
            if (st.IsExternal !== true && firstInternalSubtitleStreamIndex < 0)
                firstInternalSubtitleStreamIndex = subIdx

            // Le DirectPlay automatique est autorisé lorsque toutes les pistes
            // internes prioritaires sont françaises et réellement forcées. Pour une
            // piste image, IsForced=true est obligatoire : le titre seul ne suffit pas.
            // On garde séparément le meilleur candidat texte pour l'overlay/remux.
            if (st.IsExternal !== true && (st.IsDefault === true || st.IsForced === true)) {
                hasAnyPriorityInternalSubtitle = true
                if (isSafeFrenchForcedSubtitle(st, j)) {
                    if (strictFrenchForcedDefaultSubtitleStreamIndex < 0)
                        strictFrenchForcedDefaultSubtitleStreamIndex = subIdx
                    if (isSafeFrenchForcedTextSubtitle(st) &&
                        strictFrenchForcedDefaultTextSubtitleStreamIndex < 0)
                        strictFrenchForcedDefaultTextSubtitleStreamIndex = subIdx
                } else if (!isIgnorableTrailingForeignForcedSubtitle(j, st)) {
                    // Une piste étrangère uniquement Forced, non Default et placée
                    // après des ancrages français forcés sûrs ne peut pas gagner la
                    // sélection native : elle ne doit pas annuler le DirectPlay.
                    defaultForcedInternalSubtitlesAreSafeFrenchForced = false
                    hasPriorityInternalSubtitleRisk = true
                }
            } else if (isLegacyTitleOnlyFrenchForcedTextSubtitle(st)) {
                legacyFrenchForcedTextSubtitleCandidateCount++
                if (legacyFrenchForcedTextSubtitleStreamIndex < 0)
                    legacyFrenchForcedTextSubtitleStreamIndex = subIdx
            }
        }
    }
    requiresInterlacedTsTranscode = !!(
        isTransportStreamContainer(j.Container, j.Path) &&
        hasInterlacedH264Video(streams)
    )
    var videoType = (typeof j.VideoType === "number") ? j.VideoType : parseInt(_s(j.VideoType), 10)
    var sourcePathLower = _s(j.Path).toLowerCase()
    var sourceNameLower = _s(j.Name).toLowerCase()
    var isDvdSource = !!(videoType === 1 || videoType === 2 || hasDvdNavPacket ||
        sourcePathLower.indexOf("video_ts") >= 0 || /\.iso$/.test(sourcePathLower) ||
        sourceNameLower.indexOf("/dvd") >= 0 || sourceNameLower.indexOf("video_ts") >= 0)

    if (defaultAudioStreamIndex < 0 && forcedAudioStreamIndex >= 0)
        defaultAudioStreamIndex = forcedAudioStreamIndex
    if (defaultAudioStreamIndex < 0)
        defaultAudioStreamIndex = firstAudioStreamIndex
    if (defaultSubtitleStreamIndex < 0 && forcedSubtitleStreamIndex >= 0)
        defaultSubtitleStreamIndex = forcedSubtitleStreamIndex
    if (defaultSubtitleStreamIndex < 0)
        defaultSubtitleStreamIndex = firstSubtitleStreamIndex
    if (bestFrenchAudioScore < 80)
        bestFrenchAudioStreamIndex = -1

    // Décision précoce transmise au PlayerOverlay : si la meilleure piste
    // française (VFF/VFI prioritaire) n'est pas la première piste physique,
    // le démarrage doit passer par le serveur afin d'épingler son index.
    var preferredFrenchAudioNeedsServerSelection = !!(
        bestFrenchAudioStreamIndex >= 0 &&
        firstAudioStreamIndex >= 0 &&
        bestFrenchAudioStreamIndex !== firstAudioStreamIndex
    )

    // Important : Jellyfin peut ne marquer aucune piste audio IsDefault.
    // Dans ce cas la sélection ci-dessus retombe naturellement sur la première
    // piste. On juge donc la piste effectivement sélectionnée, pas uniquement
    // le drapeau IsDefault. Cela couvre le cas d'une unique piste DTS française.
    var effectiveDefaultAudioFrench = false
    if (defaultAudioStreamIndex >= 0) {
        var effectiveFrenchScore = frenchAudioScoreByIndex[String(defaultAudioStreamIndex)]
        effectiveDefaultAudioFrench = (typeof effectiveFrenchScore === "number" && effectiveFrenchScore >= 80)
    }
    // Le secours « titre uniquement » n'est accepté que s'il existe un seul
    // candidat texte français forcé. Cette unicité évite d'activer au hasard
    // une piste mal balisée parmi plusieurs variantes anciennes.
    if (legacyFrenchForcedTextSubtitleCandidateCount !== 1)
        legacyFrenchForcedTextSubtitleStreamIndex = -1

    // Sans aucun drapeau Default/Forced, QtMultimedia 5.15 peut activer la
    // première piste interne physique. Cela a été observé avec une piste FR
    // « Complet » : le fichier semblait sans piste prioritaire côté Jellyfin,
    // mais le DirectPlay affichait malgré tout les sous-titres complets.
    //
    // On force donc un remux no-sub si une première piste interne existe et
    // qu'aucune priorité Matroska ne permet de prévoir le choix du lecteur.
    // Seule exception : l'unique ancien SRT « FR Forced » déjà reconnu, qui
    // reste pris en charge en DirectPlay via SubtitleOverlay.
    if (!hasAnyPriorityInternalSubtitle && firstInternalSubtitleStreamIndex >= 0) {
        var uniqueLegacyForcedIsFirst =
                legacyFrenchForcedTextSubtitleStreamIndex >= 0 &&
                legacyFrenchForcedTextSubtitleStreamIndex === firstInternalSubtitleStreamIndex
        hasImplicitFirstInternalSubtitleRisk = !uniqueLegacyForcedIsFirst
    }

    // Même si le SRT français forcé est correctement balisé, Qt peut ouvrir
    // la première piste interne physique. Si le Forced sûr est situé après une
    // piste complète, le démarrage doit obligatoirement passer par Jellyfin.
    var preferredFrenchForcedSubtitleNeedsServerSelection = !!(
        strictFrenchForcedDefaultTextSubtitleStreamIndex >= 0 &&
        firstInternalSubtitleStreamIndex >= 0 &&
        strictFrenchForcedDefaultTextSubtitleStreamIndex !== firstInternalSubtitleStreamIndex
    )

    var strictFrenchAutoDirectPlayEligible = !!(
        effectiveDefaultAudioFrench &&
        defaultForcedInternalSubtitlesAreSafeFrenchForced &&
        !preferredFrenchForcedSubtitleNeedsServerSelection &&
        (strictFrenchForcedDefaultSubtitleStreamIndex >= 0 ||
         legacyFrenchForcedTextSubtitleStreamIndex >= 0)
    )

    return {
        runtimeTicks: j.RunTimeTicks || 0,
        chapters: j.Chapters !== undefined ? j.Chapters : null,
        audioLabels: aLabels,
        subtitleLabels: sLabels,
        audioMap: aMap,
        audioCodecMap: aCodecMap,
        audioChannelMap: aChannelMap,
        audioBitrateMap: aBitrateMap,
        subtitleMap: sMap,
        subtitleIsText: sIsText,
        subtitleCodecMap: sCodecMap,
        defaultAudioStreamIndex: defaultAudioStreamIndex,
        defaultSubtitleStreamIndex: defaultSubtitleStreamIndex,
        firstAudioStreamIndex: firstAudioStreamIndex,
        bestFrenchAudioStreamIndex: bestFrenchAudioStreamIndex,
        preferredFrenchAudioNeedsServerSelection: preferredFrenchAudioNeedsServerSelection,
        firstInternalSubtitleStreamIndex: firstInternalSubtitleStreamIndex,
        preferredFrenchForcedSubtitleNeedsServerSelection: preferredFrenchForcedSubtitleNeedsServerSelection,
        strictFrenchForcedDefaultTextSubtitleStreamIndex: strictFrenchForcedDefaultTextSubtitleStreamIndex,
        strictFrenchForcedDefaultSubtitleStreamIndex: strictFrenchForcedDefaultSubtitleStreamIndex,
        legacyFrenchForcedTextSubtitleStreamIndex: legacyFrenchForcedTextSubtitleStreamIndex,
        strictFrenchAutoDirectPlayEligible: strictFrenchAutoDirectPlayEligible,
        hasPriorityInternalSubtitleRisk: hasPriorityInternalSubtitleRisk,
        hasImplicitFirstInternalSubtitleRisk: hasImplicitFirstInternalSubtitleRisk,
        hasInternalDvdSubtitle: hasInternalDvdSubtitle,
        safeFrenchForcedDvdSubtitleStreamIndex: safeFrenchForcedDvdSubtitleStreamIndex,
        isDvdSource: isDvdSource,
        requiresInterlacedTsTranscode: requiresInterlacedTsTranscode
    }
}
