.pragma library
.import "JellyfinPlaybackCoreUrl.js" as CoreUrl
.import "clientId.js" as ClientId
// ReDeFin playback policy: VFF priority, dormant subtitle safety, VO + French full auto-remux, TrueHD 5.1 audio-only transcoding and global high-quality DVDSub transcoding.
// Text subtitles: local QML overlay is reserved for pure DirectPlay. Server-side modes use server-managed Embed by default; burn-in remains an explicit fallback.
// Any internal DVDSub/VobSub forces a progressive H.264 transcode only in Smart mode; global Original and manual DirectPlay bypass this soft safety rule.
// Image subtitles require IsForced=true, except one first French PGS "Forced" structurally paired with a later French PGS full track.
// Legacy audio/subtitle tracks may infer French from bounded raw title tokens such as FR/VFF/VFI/VFQ.
// VO auto-sub: an explicit French Full/Complet/SDH track is preferred; with exactly one explicit non-French audio, a unique internal French non-forced text/PGS track may be treated as the full translation.
var _fbx = null
var setFbx = function(fbxCtx) {
    _fbx = fbxCtx || null

    try {
        if (_ensureCoreUrlConfigured())
            CoreUrl.setFbx(_fbx)
    } catch(e) {}
}
var _devicePolicy = null; var _devicePolicyId = "none"; var _devicePolicyRevision = 0
// Plafond de streaming/transcodage ReDeFin, aligné sur le profil maximal Jellyfin Android TV.
// Ce plafond n'est PAS un bitrate vidéo imposé : Jellyfin reste libre de calculer
// le VideoBitrate réellement pertinent pour chaque source, jusqu'à 200 Mb/s.
var REDEFIN_MAX_STREAMING_BITRATE = 200000000
function _policyIdentityValue(policy, key, getter, fallback) {
    try {
        if (policy && typeof policy[getter] === "function") return policy[getter]()
        if (policy && policy[key] !== undefined && policy[key] !== null) return policy[key]
    } catch(e) {}
    return fallback
}
var setDevicePolicy = function(policy) {

    policy = policy || null
    var nextId = _s(_policyIdentityValue(policy, "policyId", "getPolicyId", "unknown")).toLowerCase().trim(); var nextRev = 0
    try { nextRev = _policyIdentityValue(policy, "policyRevision", "getPolicyRevision", 0) | 0 } catch(e0) { nextRev = 0 }
    if (!nextId)
        nextId = policy ? "unknown" : "none"
    var changed = (_devicePolicyId !== nextId || _devicePolicyRevision !== nextRev)
    _devicePolicy = policy
    _devicePolicyId = nextId
    _devicePolicyRevision = nextRev
    if (changed && typeof _resetNegotiationCache === "function")
        _resetNegotiationCache()

}
function _policy() {
    return _devicePolicy || {}
}
function _normalizePlaybackRuleMode(value) {
    return _s(value).toLowerCase().trim() === "directplay" ? "directplay" : "smart"
}
function _smartPlaybackRulesEnabled(ctx) {
    return _normalizePlaybackRuleMode(ctx && ctx.playbackRuleMode) !== "directplay"
}
function _isTechnicalForcedServerRemuxRequest(ctx) {
    if (!ctx) return false
    if (ctx.forceRetry === true) return true
    if (ctx.forceServerSeek === true || ctx.forceHlsOnDpSeekFallback === true) return true
    if (ctx.forceExplicitServerProgressiveSeek === true || ctx.forceJellyfinTranscodingUrlCopyRemux === true) return true
    if (ctx.forceSubtitleEncode === true || ctx.forceFullRemuxForImageSubtitles === true) return true
    if (ctx.forceDvdSubFileTranscode === true || ctx.forceInterlacedTsTranscode === true) return true
    if (ctx.forceAllowTranscoding === true || ctx.forceTranscodeOnTrackSwitch === true || !!ctx.forceVideoTranscodeCodec) return true
    if (typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0) return true
    if (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) return true
    return false
}
function _applyPlaybackRuleMode(ctx) {
    if (!ctx) return ctx
    var mode = _normalizePlaybackRuleMode(ctx.playbackRuleMode)
    ctx.playbackRuleMode = mode
    if (mode !== "directplay") return ctx
    // Direct Play prioritaire : on neutralise uniquement les heuristiques de
    // confort/sélection automatique. Les contraintes matérielles, les codecs
    // incompatibles, le seek serveur, les changements manuels de piste et les
    // transcodages réellement nécessaires restent actifs.
    ctx.preferFrenchAudio = false
    ctx.disableAutoFrenchAudio = true
    ctx.disableAutoVoFrenchFullSubtitle = true
    ctx.disableDefaultSubtitleRemux = true
    ctx.disableDefaultFrenchAudioOrderRemux = true
    ctx.disableImageSubtitleRiskRemux = true
    ctx.disableHevcMain10MkvRemux = true
    ctx.disableMp4EditListRemux = true
    ctx.forceHevcMain10Remux = false
    ctx.forceDvdSubFileTranscode = false
    ctx.forceInterlacedTsTranscode = false
    // playerOverlayHelper peut demander un remux initial uniquement parce que
    // des pistes audio/sous-titres existent. En mode Direct Play prioritaire,
    // on retire ce remux "nu", mais on conserve toute demande accompagnée d'un
    // indice technique (seek/recovery, piste choisie manuellement, transcodage...).
    if (ctx.forceServerRemux === true &&
            ctx.manualRemuxOverride !== true &&
            !_isTechnicalForcedServerRemuxRequest(ctx))
        ctx.forceServerRemux = false
    return ctx
}
function _applyReDeFinBitrateCeiling(profile) {
    if (!profile) return profile
    try {
        profile.MaxStreamingBitrate = REDEFIN_MAX_STREAMING_BITRATE
        profile.MaxStaticBitrate = REDEFIN_MAX_STREAMING_BITRATE
    } catch(e) {}
    return profile
}
function _policyBuildDeviceProfile(mode) {
    var p = _policy()
    if (p && typeof p.buildDeviceProfile === "function") {
        try { return _applyReDeFinBitrateCeiling(p.buildDeviceProfile(mode)) } catch(e) {}
    }
    return null
}
function _policyPreferredContainer(ctx, src) { var p = _policy(); if (p && typeof p.decidePreferredContainer === "function") return p.decidePreferredContainer(ctx, src); return null }
function _sourceVideoCodec(src) { var v = _firstStream(src, "Video"); return _s(v && v.Codec).toLowerCase().trim() }
function _sourceVideoBitrate(src) {
    var v = _firstStream(src, "Video"), n = 0
    try {
        if (v) {
            if (v.BitRate !== undefined && v.BitRate !== null) n = _numSafe(v.BitRate)
            else if (v.Bitrate !== undefined && v.Bitrate !== null) n = _numSafe(v.Bitrate)
        }
    } catch(e0) { n = 0 }
    if (n > 0) return Math.floor(n)
    try {
        if (src) {
            if (src.Bitrate !== undefined && src.Bitrate !== null) n = _numSafe(src.Bitrate)
            else if (src.BitRate !== undefined && src.BitRate !== null) n = _numSafe(src.BitRate)
        }
    } catch(e1) { n = 0 }
    return n > 0 ? Math.floor(n) : 0
}
function _isAv1Source(src) { var c = _sourceVideoCodec(src); return c === "av1" || c === "aom" || c === "av01" }
function _policyRequiresHardVideoTranscode(ctx, src) {
    var p = _policy()
    if (p && typeof p.requiresHardVideoTranscode === "function") {
        try { return !!p.requiresHardVideoTranscode(ctx, src) } catch(e) {}
    }
    // Fallback Core neutre : AV1 est la seule incompatibilite video certaine
    // connue ici. Les policies materiel peuvent declarer une liste plus large.
    return _isAv1Source(src)
}
function _policyTranscodeVideoCodecHint(ctx, src) {
    if (ctx && ctx.forceVideoTranscodeCodec) return _s(ctx.forceVideoTranscodeCodec).toLowerCase().trim()
    var p = _policy()
    if (p && typeof p.preferredTranscodeVideoCodec === "function") {
        try {
            var pc = _s(p.preferredTranscodeVideoCodec(ctx, src)).toLowerCase().trim()
            if (pc) return pc
        } catch(e) {}
    }
    // ReDeFin / Freebox: codec vidéo non supporté (AV1 notamment) => transcodage H.264.
    if (_isAv1Source(src)) return "h264"
    return "h264"
}
function _policyTranscodeUseHls(ctx, src) {
    if (ctx && ctx.forcePolicyTranscodeHls === false) return false
    if (ctx && ctx.forcePolicyTranscodeHls === true) return true
    var p = _policy()
    if (p && typeof p.preferredTranscodeProtocol === "function") {
        try {
            var proto = _s(p.preferredTranscodeProtocol(ctx, src)).toLowerCase().trim()
            if (proto === "hls") return true
            if (proto === "http" || proto === "progressive") return false
        } catch(e) {}
    }
    if (_isAv1Source(src)) return true
    return false
}
function _policyTranscodeHlsColdStart(ctx, src) {
    // Une reprise serveur explicite ne doit jamais être transformée en cold-start
    // HLS. La position doit être transmise à PlaybackInfo avant que Jellyfin ne
    // fabrique sa TranscodingUrl.
    if (ctx && ctx.forceServerSeek === true && Number(ctx.startMs || 0) > 0) return false
    if (ctx && ctx.forcePolicyTranscodeHlsColdStart === false) return false
    if (ctx && ctx.forcePolicyTranscodeHlsColdStart === true) return true
    var p = _policy()
    if (p && typeof p.shouldColdStartPolicyHls === "function") {
        try { return !!p.shouldColdStartPolicyHls(ctx, src) } catch(e) {}
    }
    if (_isAv1Source(src)) return true
    return false
}
function _policyTranscodeAudioCodecHint(ctx, src, audioIndex, useHls) {
    var wanted = ""
    if (ctx && ctx.forcePolicyTranscodeAudioCodec)
        wanted = _s(ctx.forcePolicyTranscodeAudioCodec).toLowerCase().trim()
    if (!wanted) {
        var p = _policy()
        if (p && typeof p.preferredTranscodeAudioCodec === "function") {
            try {
                wanted = _s(p.preferredTranscodeAudioCodec(ctx, src, audioIndex, useHls)).toLowerCase().trim()
            } catch(e) {}
        }
    }
    if (!wanted) {
        if (useHls && _isAv1Source(src))
            wanted = _selectedAudioCodec(src, audioIndex) || "aac"
        else
            wanted = _selectedAudioCodec(src, audioIndex) || "ac3,eac3,aac,mp3"
    }
    return _safeFullTranscodeAudioCodecHint(wanted, src, audioIndex)
}
function _policyTranscodeAllowAudioCopy(ctx, src, audioIndex, useHls) {
    if (_fullTranscodeAudioNeedsAc3(src, audioIndex)) return false
    if (ctx && ctx.forcePolicyTranscodeAllowAudioCopy === true) return true
    if (ctx && ctx.forcePolicyTranscodeAllowAudioCopy === false) return false
    var p = _policy()
    if (p && typeof p.allowTranscodeAudioStreamCopy === "function") {
        try { return !!p.allowTranscodeAudioStreamCopy(ctx, src, audioIndex, useHls) } catch(e) {}
    }
    if (useHls && _isAv1Source(src)) return true
    return true
}
function _sourceVideoDimensions(src) {
    var v = _firstStream(src, "Video"); var w = Number(v && v.Width || 0); var h = Number(v && v.Height || 0)
    if (!isFinite(w) || w <= 0) w = 1920
    if (!isFinite(h) || h <= 0) h = 1080
    w = Math.max(2, Math.floor(w / 2) * 2)
    h = Math.max(2, Math.floor(h / 2) * 2)
    return { width: w, height: h }
}
function _jellyfinSuggestedTranscodeVideoBitrate(src) {
    var u = _s(src && src.TranscodingUrl)
    if (!u) return null
    // PlaybackInfo calcule déjà un VideoBitrate adapté à la source et au
    // MaxStreamingBitrate annoncé. On réutilise cette valeur au lieu d'imposer
    // un palier fixe ReDeFin (8/12/30 Mb/s).
    var m = /(?:[?&])VideoBit(?:Rate|rate)=([0-9]+)/i.exec(u)
    if (!m || !m[1]) return null
    var n = Number(m[1])
    if (!isFinite(n) || n <= 0) return null
    return Math.min(REDEFIN_MAX_STREAMING_BITRATE, Math.floor(n))
}
function _forcedPolicyTranscodeVideoBitrate(ctx) {
    var forced = Number(ctx && ctx.forcePolicyTranscodeVideoBitrate || 0)
    if (!isFinite(forced) || forced <= 0) return 0
    return Math.max(420000, Math.min(REDEFIN_MAX_STREAMING_BITRATE, Math.floor(forced)))
}
function _policyTranscodeVideoBitrate(ctx, src) {
    // Un choix utilisateur explicite est prioritaire sur la suggestion du
    // serveur et doit rester identique dans PlaybackInfo, le cache et l'URL.
    var forced = _forcedPolicyTranscodeVideoBitrate(ctx)
    if (forced > 0) return forced
    // Par défaut, la qualité est pilotée par Jellyfin. Les anciennes policies
    // device qui proposaient 12/30 Mb/s ne doivent plus figer le bitrate.
    return _jellyfinSuggestedTranscodeVideoBitrate(src)
}
function _policyTranscodeDimensions(ctx, src) {
    var forcedW = Number(ctx && ctx.forcePolicyTranscodeMaxWidth || 0); var forcedH = Number(ctx && ctx.forcePolicyTranscodeMaxHeight || 0)
    if (isFinite(forcedW) && forcedW > 0 && isFinite(forcedH) && forcedH > 0) return { width: Math.max(2, Math.floor(forcedW / 2) * 2), height: Math.max(2, Math.floor(forcedH / 2) * 2) }
    var p = _policy()
    if (p && typeof p.preferredTranscodeDimensions === "function") {
        try {
            var d = p.preferredTranscodeDimensions(ctx, src); var w = Number(d && d.width || 0); var h = Number(d && d.height || 0)
            if (isFinite(w) && w > 0 && isFinite(h) && h > 0) return { width: Math.max(2, Math.floor(w / 2) * 2), height: Math.max(2, Math.floor(h / 2) * 2) }
        } catch(e) {}
    }
    return _sourceVideoDimensions(src)
}
function _h264LevelForTranscodeDimensions(dims, src) {
    var w = Number(dims && dims.width || 0); var h = Number(dims && dims.height || 0)
    if (w > 1920 || h > 1080) {
        var fps = _sourceVideoFrameRate(src)
        return fps > 30 ? "52" : "51"
    }
    return "41"
}
function _shouldForceTranscodeSource(ctx, src) {
    // Un débit vidéo manuel signifie explicitement "transcoder à ce débit".
    // Il ne doit jamais retomber en remux/DirectPlay parce qu'un appelant a
    // perdu un autre flag de confort pendant une renégociation.
    if (_forcedPolicyTranscodeVideoBitrate(ctx) > 0) return true
    // ReDeFin / Freebox: fallback explicite après changement de piste.
    if (ctx && ctx.forceTranscodeOnTrackSwitch === true) return true
    if (ctx && ctx.forceAllowTranscoding === true && ctx.forceVideoTranscodeCodec) return true
    // Le DirectPlay manuel du menu Qualite reste souverain : c'est un choix
    // explicite de l'utilisateur pendant la lecture, distinct du mode global
    // "Original" de SettingsSidePanel.
    if (ctx && ctx.manualDirectPlayOverride === true) return false
    // Mode global "Original" : neutraliser les REGLES DE PRECAUTION (DVDSub
    // dormant, TS H.264 entrelace, remux de confort, etc.), mais conserver les
    // incompatibilites VIDEO REELLES declarees par la policy materielle.
    // Exemple Devialet : AV1 reste transcode meme en Original.
    if (ctx && _normalizePlaybackRuleMode(ctx.playbackRuleMode) === "directplay")
        return _policyRequiresHardVideoTranscode(ctx, src)
    // Remux manuel : meme logique pour la video impossible a decoder. Un remux
    // ne transforme pas le codec video, donc une incompatibilite dure doit
    // toujours gagner.
    if (ctx && ctx.manualRemuxOverride === true) return _policyRequiresHardVideoTranscode(ctx, src)
    var p = _policy()
    if (p && typeof p.shouldForceTranscode === "function") {
        try {
            if (!!p.shouldForceTranscode(ctx, src)) return true
        } catch(e) {}
    }
    if (_isAv1Source(src)) return true
    return false
}
function _policyForceSubtitleEncode(ctx, src, st) {
    var p = _policy()
    if (p && typeof p.shouldForceSubtitleEncode === "function")
        return !!p.shouldForceSubtitleEncode(ctx, src, st)
    return false
}
function _policyForceServerRemux(ctx, src) {
    var p = _policy()
    if (p && typeof p.shouldForceServerRemux === "function")
        return !!p.shouldForceServerRemux(ctx, src)
    return false
}
function _s(v){ return (v === undefined || v === null) ? "" : (v + "") }
function _fold(s) {
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
    haystack = _fold(haystack)
    token = _fold(token)
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
function _isType(st, name) { return _typeName(st) === name }
function _firstStream(src, type) {
    if (!src || !src.MediaStreams) return null
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var s = src.MediaStreams[i]
        if (s && _isType(s, type)) return s
    }
    return null
}
function _subtitleStreamByIndex(src, subIndex) {
    if (!src || !src.MediaStreams || typeof subIndex !== "number" || subIndex < 0) return null
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (st && _isType(st, "Subtitle") && st.Index === subIndex) return st
    }
    return null
}
function _audioStreamByIndex(src, audioIndex) {
    if (!src || !src.MediaStreams || typeof audioIndex !== "number" || audioIndex < 0) return null
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (st && _isType(st, "Audio") && st.Index === audioIndex) return st
    }
    return null
}
function _firstAudioStreamIndex(src) {
    if (!src || !src.MediaStreams) return -1
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !_isType(st, "Audio")) continue
        return (typeof st.Index === "number") ? st.Index : i
    }
    return -1
}
function _defaultAudioStreamIndex(src) {
    if (!src || !src.MediaStreams) return -1
    var firstAudio = -1; var forcedAudio = -1
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !_isType(st, "Audio")) continue
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
function _streamCountOfType(src, typeName) {
    if (!src || !src.MediaStreams) return 0
    var count = 0
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (st && _isType(st, typeName))
            count++
    }
    return count
}
function _isSingleAudioNoSubtitleDirectPlayCandidate(ctx, src) {
    if (!ctx || !src) return false
    if (_streamCountOfType(src, "Audio") !== 1) return false
    if (_streamCountOfType(src, "Subtitle") !== 0) return false
    if (!_wantsNoServerSubtitle(ctx) || _isDvdFolderSource(src)) return false
    var onlyAudio = _firstAudioStreamIndex(src)
    if (onlyAudio < 0) return false
    return !_hasExplicitAudio(ctx) || ctx.selectedAudioStream === onlyAudio
}
function _hasExplicitAudio(ctx) { return !!(ctx && typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0) }
function _wantsNoServerSubtitle(ctx) { return !!(ctx && !ctx.useLocalSubs && !(typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0)) }
function _numSafe(v) {
    var n = Number(v)
    return (isFinite(n) && !isNaN(n)) ? n : 0
}
function _rateSafe(st) {
    if (!st) return 0
    var v = st.RealFrameRate || st.AverageFrameRate || st.ReferenceFrameRate || 0; var n = parseFloat(_s(v))
    return (isFinite(n) && !isNaN(n)) ? n : 0
}
function _preferFrenchAudioEnabled(ctx) { if (!ctx) return true; if (ctx.disableAutoFrenchAudio === true) return false; if (ctx.preferFrenchAudio === false) return false; return true }
function _audioBlob(st) { if (!st) return ""; return [ st.Language || "", st.Title || "", st.DisplayTitle || "", st.Profile || "", st.Codec || "", st.ChannelLayout || "" ].join(" ") }
function _isBadAudioVariant(st) {
    var b = _fold(_audioBlob(st))
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
    if (!st || !_isType(st, "Audio")) return -1
    if (_isBadAudioVariant(st)) return -1
    var lang = _fold(st.Language || ""); var blob = _fold(_audioBlob(st)); var languageIsFrench = lang === "fra" ||
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
function _scoreFrenchAudioStream(st) { var tier = _frenchAudioVariantTier(st); if (tier < 0) return -9999; return (tier * 1000) + _frenchAudioTechnicalTieBreak(st) }
function _bestFrenchAudioStreamIndex(src) {
    if (!src || !src.MediaStreams) return -1
    var bestIdx = -1; var bestScore = -9999
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !_isType(st, "Audio")) continue
        var idx = (typeof st.Index === "number") ? st.Index : i; var score = _scoreFrenchAudioStream(st)
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
    if (!st || !_isType(st, "Audio") || _isBadAudioVariant(st)) return false
    if (_scoreFrenchAudioStream(st) >= 80) return false
    var lang = _fold(st.Language || "").trim(); var blob = _fold(_audioBlob(st))
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
    if (!st || !_isType(st, "Subtitle") || st.IsExternal === true) return false
    if (!_isFrenchSubtitleLanguage(st)) return false
    if (st.IsForced === true || _subtitleLooksForcedOnly(st)) return false
    var codec = _s(st.Codec).toLowerCase()
    if (_isDvdSubtitleCodec(codec)) return false
    var textish = (st.IsTextSubtitleStream === true) || _isTextSubtitleCodec(codec)
    return textish || _isPgsSubtitleStream(st)
}
function _isUniqueVoFrenchUnforcedSubtitleCandidate(src, st) {
    if (!src || !src.MediaStreams || !_isVoFrenchSubtitleMediaCandidate(st)) return false
    // Secours volontairement étroit : une seule piste audio, explicitement VO,
    // et un seul sous-titre français interne non forcé exploitable. Cela couvre
    // les MKV dont la piste complète est seulement nommée "French"/"Français"
    // sans élargir la règle aux fichiers multiaudio ou aux pistes ambiguës.
    if (_streamCountOfType(src, "Audio") !== 1) return false
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
    var codec = _s(st.Codec).toLowerCase(); var textish = (st.IsTextSubtitleStream === true) || _isTextSubtitleCodec(codec); var accessibility = st.IsHearingImpaired === true || _subtitleMatchText(st).indexOf("sdh") >= 0 ||
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
function _autoVoFrenchFullSubtitleIndex(ctx, src) {
    if (!ctx || !src) return -1
    if (ctx.manualDirectPlayOverride === true) return -1
    if (ctx.disableAutoVoFrenchFullSubtitle === true) return -1
    if (ctx.useLocalSubs === true) return -1
    if (typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) return -1
    if (_hasExplicitAudio(ctx)) return -1
    if (_hasReliableFrenchAudio(src)) return -1
    if (!_hasReliableNonFrenchAudio(src)) return -1
    return _bestFrenchFullSubtitleIndex(src)
}
function _preferredFrenchAudioNeedsServerSelection(ctx, src) {
    if (!_preferFrenchAudioEnabled(ctx) || _hasExplicitAudio(ctx)) return false
    if (!src || !src.MediaStreams) return false
    var bestFrench = _bestFrenchAudioStreamIndex(src)
    var firstAudio = _firstAudioStreamIndex(src)
    return bestFrench >= 0 && firstAudio >= 0 && bestFrench !== firstAudio
}
function _shouldAutoSelectFrenchAudio(ctx, src) {
    if (!_preferFrenchAudioEnabled(ctx) || _hasExplicitAudio(ctx)) return false
    if (!src || !src.MediaStreams) return false
    var bestFrench = _bestFrenchAudioStreamIndex(src)
    if (bestFrench < 0) return false
    var defaultAudio = _defaultAudioStreamIndex(src)
    var firstAudio = _firstAudioStreamIndex(src)
    return bestFrench !== defaultAudio || bestFrench !== firstAudio
}
function _autoFrenchAudioStreamIndex(ctx, src) { if (!_shouldAutoSelectFrenchAudio(ctx, src)) return -1; return _bestFrenchAudioStreamIndex(src) }
function _shouldPinDefaultAudioForNoSubRemux(ctx, src, remuxNoSubs) { if (!remuxNoSubs) return false; if (!ctx || !src) return false; if (_hasExplicitAudio(ctx)) return false; var def = _defaultAudioStreamIndex(src); if (def < 0) return false; return true }
function _shouldRemuxDefaultFrenchAudioNotFirst(ctx, src) {
    if (!ctx || !src || ctx.disableDefaultFrenchAudioOrderRemux === true) return false
    if (_hasExplicitAudio(ctx)) return false
    var defaultIndex = _defaultAudioStreamIndex(src)
    var firstIndex = _firstAudioStreamIndex(src)
    if (defaultIndex < 0 || firstIndex < 0 || defaultIndex === firstIndex) return false
    return _scoreFrenchAudioStream(_audioStreamByIndex(src, defaultIndex)) >= 80
}
function _effectiveAudioStreamForServer(ctx, src, imageSubtitleSelected, forceImageBurnIn, preferImageRemux, forcePinDefaultAudio, autoFrenchAudioIndex) {
    if (ctx && typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0) return ctx.selectedAudioStream
    if (typeof autoFrenchAudioIndex === "number" && autoFrenchAudioIndex >= 0) return autoFrenchAudioIndex
    if (!ctx || !src) return -1
    var needsPinnedAudio = (forcePinDefaultAudio === true) ||
        (imageSubtitleSelected === true) || (forceImageBurnIn === true) ||
        (preferImageRemux === true)
    if (!needsPinnedAudio) return -1
    return _defaultAudioStreamIndex(src)
}
function _isTextSubtitleCodec(codec) { codec = _s(codec).toLowerCase(); return codec === "srt" || codec === "subrip" || codec === "ass" || codec === "ssa" || codec === "webvtt" || codec === "vtt" || codec === "mov_text" || codec === "tx3g" || codec === "dvbtxt" }
function _isImageSubtitleCodec(codec) { codec = _s(codec).toLowerCase(); return codec === "pgssub" || codec === "pgs" || codec === "hdmv_pgs_subtitle" || codec === "dvdsub" || codec === "dvd_subtitle" || codec === "vobsub" || codec === "dvbsub" || codec === "dvb_subtitle" || codec === "xsub" }
function _isDvdSubtitleCodec(codec) { codec = _s(codec).toLowerCase(); return codec === "dvdsub" || codec === "dvd_subtitle" || codec === "vobsub" }
function _isDvdSubtitleStream(st) { if (!st || !_isType(st, "Subtitle")) return false; return _isDvdSubtitleCodec(st.Codec) }
function _hasInternalDvdSubtitle(src) {
    if (!src || !src.MediaStreams) return false
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (_isDvdSubtitleStream(st) && st.IsExternal !== true) return true
    }
    return false
}
function _isTransportStreamContainer(container, path) { var c = _s(container).toLowerCase().trim(); if (c.indexOf(",") >= 0) c = c.split(",")[0]; if (!c) c = _extFrom(path || ""); return c === "ts" || c === "m2ts" || c === "mts" || c === "mpegts" }
function _hasInterlacedH264Video(streams) {
    if (!streams) return false
    for (var i = 0; i < streams.length; i++) {
        var st = streams[i]
        if (!st || !_isType(st, "Video")) continue
        var codec = _s(st.Codec).toLowerCase()
        if ((codec === "h264" || codec === "avc") && st.IsInterlaced === true) return true
    }
    return false
}
function _isInterlacedTransportStreamH264(src) { if (!src || src.IsInfiniteStream === true) return false; return _isTransportStreamContainer(src.Container, src.Path) && _hasInterlacedH264Video(src.MediaStreams || []) }
function _shouldForceInterlacedTsTranscode(ctx, src) {
    if (ctx && (ctx.manualDirectPlayOverride === true || ctx.manualRemuxOverride === true ||
                _normalizePlaybackRuleMode(ctx.playbackRuleMode) === "directplay")) return false
    if (ctx && ctx.forceInterlacedTsTranscode === true) return true
    return _isInterlacedTransportStreamH264(src)
}
function _interlacedTsTranscodeDimensions(src) {
    var v = _firstStream(src, "Video"); var w = Number(v && v.Width || 0); var h = Number(v && v.Height || 0); var anamorphic = !!(v && v.IsAnamorphic === true); var ar = _s(v && v.AspectRatio).toLowerCase()
    if (anamorphic && h >= 1000 && (w === 1440 || ar === "16:9")) return { width: 1920, height: 1080 }
    if (!isFinite(w) || w <= 0) w = 1920
    if (!isFinite(h) || h <= 0) h = 1080
    w = Math.max(2, Math.min(1920, Math.floor(w / 2) * 2))
    h = Math.max(2, Math.min(1080, Math.floor(h / 2) * 2))
    return { width: w, height: h }
}
function _interlacedTsMaxFramerate(src) { var v = _firstStream(src, "Video"); var fr = Number(v && (v.AverageFrameRate || v.ReferenceFrameRate) || 0); if (!isFinite(fr) || fr <= 0) fr = 25; if (fr > 30) fr = 30; return fr }
function _audioChannelsForStream(src, idx) { var a = _audioStreamByIndex(src, idx); var ch = Number(a && a.Channels || 0); if (!isFinite(ch) || ch <= 0) ch = 2; return Math.max(1, Math.min(8, Math.floor(ch))) }
function _ac3BitrateForChannels(ch) { ch = Number(ch || 2); if (ch <= 2) return 192000; if (ch <= 4) return 384000; return 640000 }
function _safeFrenchForcedDvdSubtitleIndex(src) {
    if (!src || !src.MediaStreams) return -1
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!_isDvdSubtitleStream(st) || st.IsExternal === true) continue
        if (_isSafeFrenchForcedSubtitle(st, src)) return (typeof st.Index === "number") ? st.Index : i
    }
    return -1
}
function _isImageSubtitleSelected(src, subIndex) { var st = _subtitleStreamByIndex(src, subIndex); if (!st) return false; var codec = _s(st.Codec).toLowerCase(); var textish = (st.IsTextSubtitleStream === true) || _isTextSubtitleCodec(codec); if (_isImageSubtitleCodec(codec)) return true; return !textish }
function _isTextSubtitleSelected(src, subIndex) { var st = _subtitleStreamByIndex(src, subIndex); if (!st) return false; var codec = _s(st.Codec).toLowerCase(); if (st.IsTextSubtitleStream === true) return true; return _isTextSubtitleCodec(codec) }
function _containerOrExt(src) {
    var cont = _s(src && src.Container).toLowerCase()
    if (cont.indexOf(",") >= 0) cont = cont.split(",")[0]
    if (cont) return cont
    return _extFrom(src && src.Path ? src.Path : "")
}
function _isMkvLike(src) {
    var c = _containerOrExt(src)
    return (c === "mkv" || c === "matroska" || c === "webm")
}
function _isMp4Like(src) {
    var c = _containerOrExt(src)
    return c === "mp4" || c === "m4v" ||
           c === "mov" || c.indexOf("mp4") >= 0 ||
           c.indexOf("mov") >= 0
}
function _streamTextBlob(st) {
    if (!st) return ""
    return _fold([ st.Title || "",
        st.DisplayTitle || "", st.Comment || "",
        st.Language || "", st.Codec || "",
        st.CodecTag || "" ].join(" "))
}
function _sourceLooksGoogleProducedMp4(src) {
    if (!src || !src.MediaStreams) return false
    var nameBlob = _fold([ src.Name || "",
        src.Path || "", src.Container || ""
    ].join(" "))
    if (nameBlob.indexOf("google") >= 0) return true
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]; var b = _streamTextBlob(st)
        if (b.indexOf("google inc") >= 0 || b.indexOf("produced by google") >= 0 ||
            b.indexOf("iso media file produced by google") >= 0)
            return true
    }
    return false
}
function _sourceVideoFrameRate(src) {
    var v = _firstStream(src, "Video")
    if (!v) return 0
    var fr = 0
    try {
        fr = parseFloat(_s(v.RealFrameRate || v.AverageFrameRate || v.ReferenceFrameRate || 0))
    } catch(e) {}
    return isFinite(fr) ? fr : 0
}
function _shouldRemuxMp4EditListTimestampRisk(ctx, src) {
    if (!ctx || !src) return false
    if (ctx.manualDirectPlayOverride === true) return false
    if (ctx.disableMp4EditListRemux === true) return false
    if (!_isMp4Like(src)) return false
    var v = _firstStream(src, "Video"); var a = _firstStream(src, "Audio"); var vc = _s(v && v.Codec).toLowerCase(); var ac = _s(a && a.Codec).toLowerCase(); var isSimpleCodec = (vc === "h264" || vc === "avc1") &&
        (ac === "aac" || ac === "mp4a")
    if (!isSimpleCodec) return false
    var hasSegments = (src.HasSegments === true); var googleLike = _sourceLooksGoogleProducedMp4(src); var highFps = _sourceVideoFrameRate(src) >= 45
    return !!(hasSegments && googleLike && highFps)
}
function _isTimedMetadataDataStream(st) {
    if (!st || st.IsExternal === true) return false
    var type = (typeof st.Type === "number") ? st.Type : _s(st.Type).toLowerCase()
    if (!(type === 4 || type === "data")) return false
    var codec = _s(st.Codec).toLowerCase().trim()
    var tag = _s(st.CodecTag).toLowerCase().trim()
    return codec === "mett" || codec === "metx" || tag === "mett" || tag === "metx"
}
function _shouldRemuxMp4TimedMetadataTrackRisk(ctx, src) {
    if (!ctx || !src) return false
    // Règle de compatibilité douce : en mode Original ou en DirectPlay manuel,
    // le choix utilisateur reste souverain et le fichier brut est tenté.
    if (!_smartPlaybackRulesEnabled(ctx) || ctx.manualDirectPlayOverride === true ||
            ctx.manualRemuxOverride === true) return false
    if (!_isMp4Like(src) || !src.MediaStreams) return false
    for (var i = 0; i < src.MediaStreams.length; i++) {
        if (_isTimedMetadataDataStream(src.MediaStreams[i])) return true
    }
    return false
}
function _isDvdFolderSource(src) {
    if (!src) return false
    var vt = (typeof src.VideoType === "number") ? src.VideoType : parseInt(_s(src.VideoType), 10)
    if (vt === 1 || vt === 2) return true
    if (src.MediaStreams) {
        for (var i = 0; i < src.MediaStreams.length; i++) {
            var st = src.MediaStreams[i]
            if (!st) continue
            var codec = _s(st.Codec).toLowerCase()
            if (codec === "dvd_nav_packet") return true
            if (st.Type === 4 || _s(st.Type).toLowerCase() === "data") {
                if (codec.indexOf("dvd") >= 0 || codec.indexOf("nav") >= 0) return true
            }
        }
    }
    var p = _s(src.Path).toLowerCase(); var n = _s(src.Name).toLowerCase()
    return (p.indexOf("video_ts") >= 0 || /\.iso$/.test(p) || n.indexOf("/dvd") >= 0 || n.indexOf("video_ts") >= 0)
}
function _shouldRemuxDvdFolderMpeg(ctx, src) {
    if (!ctx || !src || !_isDvdFolderSource(src)) return false
    if (ctx.disableDvdFolderMpegRemux === true) return false
    if (ctx.manualDirectPlayOverride === true) return false
    if (ctx.manualRemuxOverride === true) return true
    return _smartPlaybackRulesEnabled(ctx)
}
function _dvdMpegAudioCodecLock(src, audioIndex) {
    var c = _selectedAudioCodec(src, audioIndex)
    if (!c) return null
    c = _normalizeAudioCodecHint(c)
    if (!c) return null
    if (c === "ac3") return "ac3"
    if (c === "dts" || c === "dca" || c === "dts,dca") return "dts,dca"
    if (c === "mp2") return "mp2"
    if (c === "mp3") return "mp3"
    if (c === "pcm_dvd" || c === "pcm_s16be") return c
    return "ac3"
}
function _isHevcMain10Source(src) {
    var v = _firstStream(src, "Video")
    if (!v) return false
    var codec = _s(v.Codec).toLowerCase(); var profile = _s(v.Profile).toLowerCase(); var pix = _s(v.PixelFormat).toLowerCase(); var depth = (typeof v.BitDepth === "number") ? v.BitDepth : parseInt(_s(v.BitDepth), 10)
    var isHevc = (codec === "hevc" || codec === "h265" || codec === "mpegh" || codec === "v_mpegh/iso/hevc")
    if (!isHevc) return false
    if (isFinite(depth) && depth >= 10) return true
    if (profile.indexOf("main 10") >= 0) return true
    if (profile.indexOf("main10") >= 0) return true
    if (pix.indexOf("10") >= 0) return true
    return false
}
function _isMkvHevcMain10Source(src) {
    return _isMkvLike(src) && _isHevcMain10Source(src)
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
    if (candidateIndex < 0 || _firstInternalSubtitleStreamIndex(src) !== candidateIndex) return false
    var fullAfter = false, forcedCandidates = 0, otherPriority = false
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var other = src.MediaStreams[i]
        if (!other || !_isType(other, "Subtitle") || other.IsExternal === true) continue
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
function _isSafeFrenchForcedSubtitle(st, src) {
    if (!st || !_isType(st, "Subtitle")) return false
    if (st.IsExternal === true) return false
    if (!_isFrenchSubtitleLanguage(st)) return false
    var codec = _s(st.Codec).toLowerCase(); var textish = (st.IsTextSubtitleStream === true) || _isTextSubtitleCodec(codec); var imageish = _isImageSubtitleCodec(codec)
    if (!textish && !imageish) return false
    if (imageish && st.IsForced !== true && !_isPairedLegacyFrenchForcedPgsSubtitle(src, st)) return false
    return _subtitleLooksForcedOnly(st)
}
function _isSafeFrenchForcedTextSubtitle(st) {
    if (!_isSafeFrenchForcedSubtitle(st)) return false
    var codec = _s(st.Codec).toLowerCase(); var textish = (st.IsTextSubtitleStream === true) || _isTextSubtitleCodec(codec)
    return !!(textish && !_isImageSubtitleCodec(codec))
}
function _isLegacyTitleOnlyFrenchForcedTextSubtitle(st) {
    if (!_isSafeFrenchForcedTextSubtitle(st)) return false
    if (st.IsDefault === true || st.IsForced === true) return false
    var t = _subtitleMatchText(st)
    return t.indexOf("force") >= 0 || t.indexOf("forced") >= 0
}
function _safeFrenchForcedSubtitleIndex(src) {
    if (!src || !src.MediaStreams) return -1
    var imageFallback = -1
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !_isType(st, "Subtitle") || st.IsExternal === true) continue
        if (!(st.IsDefault === true || st.IsForced === true || _isPairedLegacyFrenchForcedPgsSubtitle(src, st))) continue
        if (!_isSafeFrenchForcedSubtitle(st, src)) continue
        var idx = (typeof st.Index === "number") ? st.Index : i
        if (_isSafeFrenchForcedTextSubtitle(st)) return idx
        if (imageFallback < 0) imageFallback = idx
    }
    return imageFallback
}
function _firstInternalSubtitleStreamIndex(src) {
    if (!src || !src.MediaStreams) return -1
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !_isType(st, "Subtitle")) continue
        if (st.IsExternal === true) continue
        return (typeof st.Index === "number") ? st.Index : i
    }
    return -1
}
function _preferredFrenchForcedSubtitleNeedsServerSelection(ctx, src) {
    if (!ctx || !src) return false
    if (!_smartPlaybackRulesEnabled(ctx)) return false
    if (ctx.manualDirectPlayOverride === true) return false
    if (ctx.useLocalSubs === true) return false
    if (typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) return false
    var preferred = _safeFrenchForcedSubtitleIndex(src)
    if (preferred < 0) return false
    var preferredStream = _subtitleStreamByIndex(src, preferred)
    if (!_isSafeFrenchForcedTextSubtitle(preferredStream)) return false
    var firstInternal = _firstInternalSubtitleStreamIndex(src)
    return firstInternal >= 0 && firstInternal !== preferred
}
function _hasSafeFrenchForcedSelectionAnchors(src) {
    if (!src || !src.MediaStreams) return false
    var firstInternal = _firstInternalSubtitleStreamIndex(src)
    if (firstInternal < 0) return false
    var firstStream = _subtitleStreamByIndex(src, firstInternal)
    if (!_isSafeFrenchForcedSubtitle(firstStream, src)) return false
    // Toute piste explicitement Default reste susceptible de gagner la sélection
    // native QtMultimedia. Elle doit donc être française et réellement forcée.
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !_isType(st, "Subtitle") || st.IsExternal === true) continue
        if (st.IsDefault !== true) continue
        if (!_isSafeFrenchForcedSubtitle(st, src)) return false
    }
    return true
}
function _isIgnorableTrailingForeignForcedSubtitle(src, st) {
    if (!src || !st || !_isType(st, "Subtitle")) return false
    if (st.IsExternal === true) return false
    if (st.IsForced !== true || st.IsDefault === true) return false
    if (_isFrenchSubtitleLanguage(st)) return false
    if (!_hasSafeFrenchForcedSelectionAnchors(src)) return false
    var firstInternal = _firstInternalSubtitleStreamIndex(src); var idx = (typeof st.Index === "number") ? st.Index : -1
    return idx > firstInternal
}
function _hasDefaultOrForcedInternalSubtitle(src) {
    if (!src || !src.MediaStreams) return false
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !_isType(st, "Subtitle")) continue
        if (st.IsExternal === true) continue
        if (st.IsDefault === true || st.IsForced === true) {
            if (_isSafeFrenchForcedSubtitle(st, src))
                continue
            if (_isIgnorableTrailingForeignForcedSubtitle(src, st))
                continue
            return true
        }
    }
    return false
}
function _hasOnlySafeDefaultForcedFrenchSubtitles(src) {
    if (!src || !src.MediaStreams) return true
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !_isType(st, "Subtitle")) continue
        if (st.IsExternal === true) continue
        if (!(st.IsDefault === true || st.IsForced === true)) continue
        if (_isSafeFrenchForcedSubtitle(st, src)) continue
        if (_isIgnorableTrailingForeignForcedSubtitle(src, st)) continue
        return false
    }
    return true
}
function _hasReliableDefaultFrenchAudio(ctx, src) {
    if (!ctx || !src) return false
    if (_hasExplicitAudio(ctx)) return false
    var def = _defaultAudioStreamIndex(src)
    if (def < 0) return false
    var defSt = _audioStreamByIndex(src, def)
    if (_scoreFrenchAudioStream(defSt) < 80) return false
    var first = _firstAudioStreamIndex(src)
    if (first >= 0 && first !== def) {
        var firstSt = _audioStreamByIndex(src, first)
        if (_scoreFrenchAudioStream(firstSt) < 80) return false
    }
    return true
}
function _isFrenchDirectPlayGreenGate(ctx, src) {
    if (!ctx || !src) return false
    if (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) return false
    if (!_hasReliableDefaultFrenchAudio(ctx, src)) return false
    if (!_hasOnlySafeDefaultForcedFrenchSubtitles(src)) return false
    if (_preferredFrenchForcedSubtitleNeedsServerSelection(ctx, src)) return false
    if (ctx.disableImageSubtitleRiskRemux !== true && _hasPriorityInternalImageSubtitleRisk(src)) return false
    if (_isDvdFolderSource(src)) return false
    return true
}
function _hasPriorityInternalImageSubtitleRisk(src) {
    if (!src || !src.MediaStreams) return false
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !_isType(st, "Subtitle")) continue
        if (st.IsExternal === true) continue
        if (!(st.IsDefault === true || st.IsForced === true)) continue
        if (_isSafeFrenchForcedSubtitle(st, src)) continue
        if (_isIgnorableTrailingForeignForcedSubtitle(src, st)) continue
        var codec = _s(st.Codec).toLowerCase(); var textish = (st.IsTextSubtitleStream === true) || _isTextSubtitleCodec(codec)
        if (_isImageSubtitleCodec(codec)) return true
        if (!textish) return true
    }
    return false
}
function _shouldRemuxNoSubsForDirectPlay(ctx, src) {
    if (!ctx || !src) return false
    if (ctx.disableDefaultSubtitleRemux === true) return false
    if (!_wantsNoServerSubtitle(ctx)) return false
    if (_hasDefaultOrForcedInternalSubtitle(src)) return true
    if (ctx.disableImageSubtitleRiskRemux !== true && _hasPriorityInternalImageSubtitleRisk(src)) return true
    return false
}
function _hasInternalSubtitle(src) {
    if (!src || !src.MediaStreams) return false
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !_isType(st, "Subtitle")) continue
        if (st.IsExternal === true) continue
        return true
    }
    return false
}
function _hasAudioCodec(src, codec) {
    codec = _normalizeAudioCodecHint(codec)
    if (!src || !src.MediaStreams || !codec) return false
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !_isType(st, "Audio")) continue
        var c = _normalizeAudioCodecHint(st.Codec)
        if (c === codec) return true
    }
    return false
}
function _shouldRemuxHevcMain10Eac3InternalSubFreeboxRisk(ctx, src) {
    if (!ctx || !src) return false
    if (ctx.manualDirectPlayOverride === true) return false
    if (ctx.disableHevcMain10MkvRemux === true) return false
    if (!_isMkvHevcMain10Source(src)) return false
    if (!_hasAudioCodec(src, "eac3")) return false
    if (!_hasInternalSubtitle(src)) return false
    return true
}
function _shouldServerRemuxHevcMain10(ctx, src) {
    if (!ctx || !src) return false
    if (ctx.disableHevcMain10MkvRemux === true) return false
    if (!_isMkvHevcMain10Source(src)) return false
    if (_shouldRemuxHevcMain10Eac3InternalSubFreeboxRisk(ctx, src)) return true
    var unambiguousSingleAudioNoSubtitle = _isSingleAudioNoSubtitleDirectPlayCandidate(ctx, src)
    if ((unambiguousSingleAudioNoSubtitle || _isFrenchDirectPlayGreenGate(ctx, src)) && ctx.forceHevcMain10Remux !== true &&
        ctx.forceServerSeek !== true && ctx.forceServerRemux !== true)
        return false
    return true
}
function _exactAudioCodecHint(codec) {
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
function _selectedAudioCodec(src, audioIndex) {
    var st = _audioStreamByIndex(src, audioIndex)
    if (!st) return null
    return _exactAudioCodecHint(st.Codec)
}
function _isDtsAudioCodecHint(codec) {
    var c = _normalizeAudioCodecHint(codec)
    return c === "dts" || c === "dca" || c === "dts,dca" || c === "a_dts"
}
function _isTrueHdAudioCodecHint(codec) {
    var c = _normalizeAudioCodecHint(codec)
    return c === "truehd" || c === "mlp" || c === "mlp_fba" || c === "a_truehd" || c === "dolby_truehd" || c === "true-hd" || c === "true_hd"
}
function _isTrueHd51AudioStream(st) {
    if (!st || !_isType(st, "Audio")) return false
    if (!_isTrueHdAudioCodecHint(st.Codec)) return false
    var channels = 0
    try { channels = parseInt(_s(st.Channels || 0), 10) } catch(e0) { channels = 0 }
    if (isFinite(channels) && channels > 0) return channels === 6
    var layout = _fold(st.ChannelLayout || "")
    return layout.indexOf("5.1") >= 0
}
function _plannedAutomaticAudioStreamIndex(ctx, src, autoFrenchAudioIndex) {
    if (ctx && typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0) return ctx.selectedAudioStream
    if (typeof autoFrenchAudioIndex === "number" && autoFrenchAudioIndex >= 0) return autoFrenchAudioIndex
    return _defaultAudioStreamIndex(src)
}
function _shouldForceTrueHd51AudioTranscode(ctx, src, audioIndex) {
    if (!ctx || !src) return false
    if (ctx.manualDirectPlayOverride === true) return false
    if (typeof audioIndex !== "number" || audioIndex < 0) return false
    return _isTrueHd51AudioStream(_audioStreamByIndex(src, audioIndex))
}
function _isUnsafeFullTranscodeAudioCodecHint(codec) {
    return _isDtsAudioCodecHint(codec) || _isTrueHdAudioCodecHint(codec)
}
function _fullTranscodeAudioNeedsAc3(src, audioIndex) {
    return _isUnsafeFullTranscodeAudioCodecHint(_selectedAudioCodec(src, audioIndex))
}
function _safeFullTranscodeAudioCodecHint(wanted, src, audioIndex) {
    var sourceNeedsAc3 = _fullTranscodeAudioNeedsAc3(src, audioIndex); var normalized = _normalizeAudioCodecHint(wanted)
    if (sourceNeedsAc3 || _isUnsafeFullTranscodeAudioCodecHint(normalized)) return "ac3"
    return normalized || "ac3"
}
function _audioChannelCountForStream(src, audioIndex) {
    var st = _audioStreamByIndex(src, audioIndex)
    if (!st) return 2
    var channels = parseInt(_s(st.Channels), 10)
    if (!isFinite(channels) || channels < 1) channels = 2
    if (channels > 6) channels = 6
    return channels
}
function _audioCodecHintContains(codecHint, codec) {
    var wanted = _normalizeAudioCodecHint(codecHint); var source = _normalizeAudioCodecHint(codec)
    if (!wanted || !source) return false
    var parts = wanted.split(",")
    for (var i = 0; i < parts.length; i++) {
        if (_normalizeAudioCodecHint(parts[i]) === source) return true
    }
    return false
}
function _safeFullTranscodeAudioPlan(src, audioIndex, wantedCodec, allowCopyDefault) {
    var sourceCodec = _selectedAudioCodec(src, audioIndex); var sourceNeedsAc3 = _fullTranscodeAudioNeedsAc3(src, audioIndex); var codec = _safeFullTranscodeAudioCodecHint(wantedCodec || sourceCodec, src, audioIndex)
    var targetIsAc3 = _normalizeAudioCodecHint(codec) === "ac3"; var sourceAllowedByTarget = _audioCodecHintContains(codec, sourceCodec); var allowCopy = allowCopyDefault !== false && !sourceNeedsAc3 && sourceAllowedByTarget
    var channels = (!allowCopy && targetIsAc3) ? _audioChannelCountForStream(src, audioIndex) : null
    return {
        sourceNeedsAc3: sourceNeedsAc3,
        sourceIsDts: sourceNeedsAc3 && _isDtsAudioCodecHint(sourceCodec),
        sourceIsTrueHd: sourceNeedsAc3 && _isTrueHdAudioCodecHint(sourceCodec),
        codec: codec,
        allowCopy: allowCopy,
        channels: channels,
        bitrate: (!allowCopy && targetIsAc3) ? (channels > 2 ? 640000 : 192000) : null
    }
}
function _selectedVideoCodec(src) {
    var st = _firstStream(src, "Video")
    if (!st) return null
    var c = _s(st.Codec).toLowerCase().trim()
    if (!c) return null
    if (c === "h265" || c === "mpegh" || c === "v_mpegh/iso/hevc") return "hevc"
    if (c === "h264" || c === "avc1" || c === "avc") return "h264"
    if (c === "mpeg2video") return "mpeg2video"
    if (c === "mpeg4") return "mpeg4"
    if (c === "vp9") return "vp9"
    if (c === "vp8") return "vp8"
    return c
}
function _remuxAudioCodecLock(ctx, src, audioIndex, isServerRemux, forceImageBurnIn, isHls) {
    if (!ctx || !src) return null
    if (!isServerRemux) return null
    if (forceImageBurnIn === true) return null
    if (isHls === true) return null
    if (typeof audioIndex !== "number" || audioIndex < 0) return null
    var st = _audioStreamByIndex(src, audioIndex)
    if (!st) return null
    var codec = _exactAudioCodecHint(st.Codec)
    if (!codec) return null
    return codec
}
/* ===== Module URL/transport statique ===== */
var _coreUrlConfigured = false
function _coreUrlAuthHeaderValue() {
    try { return ClientId.embyAuthHeader() } catch(e0) {}
    return ""
}
function _coreUrlAltHost() {
    try { return _s(ClientId.ipv4AltHost()) } catch(e0) {}
    return ""
}
var _CORE_URL_REQUIRED = [
    "configure", "setFbx",
    "buildProgressiveUrl", "buildServerSeekProgressiveUrl",
    "buildHighQualityProgressiveTranscodeUrl", "buildHlsUrl",
    "getVideoStreamUrl", "_subtitleResultUrl", "buildDeviceProfile",
    "_needsServerTrackSelection_ctx", "_decidePreferredContainerWithSrc",
    "_buildRemuxProgressiveUrl", "_normalizeAudioCodecHint", "_isTx3gSelected",
    "_forceQuery", "_u", "_headersWithToken", "_jsonNormalize", "_sendRequest",
    "_extFrom", "_isProblematicForSeek", "_transportValidateServerUrlStrict",
    "_transportValidatePlaybackUrlStrict", "_transportFetchStreams"
]
function _coreUrlContractValid() {
    try {
        for (var i = 0; i < _CORE_URL_REQUIRED.length; ++i)
            if (typeof CoreUrl[_CORE_URL_REQUIRED[i]] !== "function") return false
        return true
    } catch(e) { return false }
}
function _ensureCoreUrlConfigured() {
    if (_coreUrlConfigured) return true
    if (!_coreUrlContractValid()) return false
    try {
        CoreUrl.configure({
            s:_s,
            policyBuildDeviceProfile:_policyBuildDeviceProfile, policyPreferredContainer:_policyPreferredContainer,
            firstStream:_firstStream, subtitleStreamByIndex:_subtitleStreamByIndex, isType:_isType,
            isTextSubtitleCodec:_isTextSubtitleCodec, isDvdSubtitleCodec:_isDvdSubtitleCodec, isSafeFrenchForcedSubtitle:_isSafeFrenchForcedSubtitle,
            isSafeFrenchForcedTextSubtitle:_isSafeFrenchForcedTextSubtitle, isLegacyTitleOnlyFrenchForcedTextSubtitle:_isLegacyTitleOnlyFrenchForcedTextSubtitle,
            isIgnorableTrailingForeignForcedSubtitle:_isIgnorableTrailingForeignForcedSubtitle,
            scoreFrenchAudioStream:_scoreFrenchAudioStream, exactAudioCodecHint:_exactAudioCodecHint,
            containerOrExt:_containerOrExt, isTransportStreamContainer:_isTransportStreamContainer, hasInterlacedH264Video:_hasInterlacedH264Video,
            mbAuthHeaderValue:_coreUrlAuthHeaderValue, altHost:_coreUrlAltHost
        })
        CoreUrl.setFbx(_fbx)
        _coreUrlConfigured = true
        return true
    } catch(e) {
        return false
    }
}
function buildProgressiveUrl(a,b,c,d) { return _ensureCoreUrlConfigured() ? CoreUrl.buildProgressiveUrl(a,b,c,d) : "" }
function buildServerSeekProgressiveUrl(a,b,c,d) { return _ensureCoreUrlConfigured() ? CoreUrl.buildServerSeekProgressiveUrl(a,b,c,d) : "" }
function buildHighQualityProgressiveTranscodeUrl(a,b,c,d) { return _ensureCoreUrlConfigured() ? CoreUrl.buildHighQualityProgressiveTranscodeUrl(a,b,c,d) : "" }
function buildHlsUrl(a,b,c,d) { return _ensureCoreUrlConfigured() ? CoreUrl.buildHlsUrl(a,b,c,d) : "" }
function getVideoStreamUrl(a,b,c,d) { return _ensureCoreUrlConfigured() ? CoreUrl.getVideoStreamUrl(a,b,c,d) : "" }
function _subtitleResultUrl(a,b,c,d,e,f) { return _ensureCoreUrlConfigured() ? CoreUrl._subtitleResultUrl(a,b,c,d,e,f) : "" }
function buildDeviceProfile(a) { return _ensureCoreUrlConfigured() ? CoreUrl.buildDeviceProfile(a) : null }
function _needsServerTrackSelection_ctx(a) { return _ensureCoreUrlConfigured() ? CoreUrl._needsServerTrackSelection_ctx(a) : false }
function _decidePreferredContainerWithSrc(a,b) { return _ensureCoreUrlConfigured() ? CoreUrl._decidePreferredContainerWithSrc(a,b) : null }
function _buildRemuxProgressiveUrl(a,b,c,d,e,f,g,h,i,j,k) { return _ensureCoreUrlConfigured() ? CoreUrl._buildRemuxProgressiveUrl(a,b,c,d,e,f,g,h,i,j,k) : "" }
function _normalizeAudioCodecHint(a) { return _ensureCoreUrlConfigured() ? CoreUrl._normalizeAudioCodecHint(a) : null }
function _isTx3gSelected(a,b) { return _ensureCoreUrlConfigured() ? CoreUrl._isTx3gSelected(a,b) : false }
function _forceQuery(a,b,c,d) { return _ensureCoreUrlConfigured() ? CoreUrl._forceQuery(a,b,c,d) : a }
function _u(a,b) { return _ensureCoreUrlConfigured() ? CoreUrl._u(a,b) : "" }
function _headersWithToken(a) { return _ensureCoreUrlConfigured() ? CoreUrl._headersWithToken(a) : ({}) }
function _jsonNormalize(a) { return _ensureCoreUrlConfigured() ? CoreUrl._jsonNormalize(a) : (a || null) }
function _sendRequest(a,b,c,d,e,f,g) {
    if (_ensureCoreUrlConfigured()) return CoreUrl._sendRequest(a,b,c,d,e,f,g)
    if (typeof f === "function") f({ code:"core_url_unavailable", status:0, data:null })
}
function _sendPlaybackInfoRequest(url, headers, body, onSuccess, onError) {
    if (_ensureCoreUrlConfigured() && typeof CoreUrl._sendPlaybackInfoExact === "function") return CoreUrl._sendPlaybackInfoExact(url, headers, body, onSuccess, onError)
    return _sendRequest("post", url, headers, body, onSuccess, onError)
}
function _extFrom(a) { return _ensureCoreUrlConfigured() ? CoreUrl._extFrom(a) : "" }
function _isProblematicForSeek(a) { return _ensureCoreUrlConfigured() ? CoreUrl._isProblematicForSeek(a) : false }
function validateServerUrlStrict(a,b) { return _ensureCoreUrlConfigured() ? CoreUrl._transportValidateServerUrlStrict(a,b) : false }
function validatePlaybackUrlStrict(a,b) { return _ensureCoreUrlConfigured() ? CoreUrl._transportValidatePlaybackUrlStrict(a,b) : false }
function fetchStreams(a,b,c,d,e) {
    if (_ensureCoreUrlConfigured()) return CoreUrl._transportFetchStreams(a,b,c,d,e)
    if (typeof e === "function") e("core_url_unavailable")
}
var _negotiating = false; var _lastNegKey  = ""; var _lastNegTs   = 0; var _minIntervalMs = 1100; var _lastNegResultKey = ""; var _lastNegResultTs = 0; var _lastNegResult = null; var _inFlightKeys = {}
var _inFlightWaiters = {}
function _resetNegotiationCache() {

    _negotiating = false
    _lastNegKey = ""
    _lastNegTs = 0
    _lastNegResultKey = ""
    _lastNegResultTs = 0
    _lastNegResult = null
    _inFlightKeys = {}
    _inFlightWaiters = {}

}
function _ctxRequiresServerPipeline(ctx) {
    if (!ctx) return false
    return ctx.forceHls === true ||
           ctx.forceHlsOnDpSeekFallback === true ||
           ctx.forceServerSeek === true ||
           ctx.forceServerRemux === true ||
           ctx.forceAllowTranscoding === true ||
           !!ctx.forceVideoTranscodeCodec ||
           ctx.forceTranscodeOnTrackSwitch === true ||
           ctx.forceDvdSubFileTranscode === true ||
           ctx.forceInterlacedTsTranscode === true ||
           ctx.forceSubtitleEncode === true ||
           ctx.forceFullRemuxForImageSubtitles === true ||
           ctx.forceJellyfinTranscodingUrlCopyRemux === true ||
           ctx.forceExplicitServerProgressiveSeek === true ||
           _forcedPolicyTranscodeVideoBitrate(ctx) > 0 ||
           ctx.currentPlaybackVideoTranscodeByPolicy === true
}
function _makeNegKey(ctx) {
    return [ "policy=" + (_devicePolicyId || "none"),
        "policyRev=" + (_devicePolicyRevision | 0), "playbackRules=" + _normalizePlaybackRuleMode(ctx.playbackRuleMode),
        "routerMode=" + (ctx.playbackRouterMode || ""),
        "routerBackend=" + (ctx.playbackRouterBackend || ""), Math.floor(ctx.startMs || 0),
        !!ctx.forceHls, !!ctx.forceMp4,
        !!ctx.preferTicks, (typeof ctx.selectedAudioStream === "number" ? ctx.selectedAudioStream : -1),
        (ctx.useLocalSubs ? -1 : (typeof ctx.selectedSubtitleStream === "number" ? ctx.selectedSubtitleStream : -1)), !!ctx.useLocalSubs,
        !!ctx.forceDPOnAudioSwitch, !!ctx.forceSubtitleEncode,
        !!ctx.preferImageSubtitleRemux, !!ctx.forceServerSeek,
        !!ctx.forceHlsOnDpSeekFallback, !!ctx.forceServerRemux,
        !!ctx.forceFullRemuxForImageSubtitles, !!ctx.forceHevcMain10Remux,
        !!ctx.forceAllowTranscoding, !!ctx.forceTranscodeOnTrackSwitch,
        !!ctx.forceJellyfinTranscodingUrlCopyRemux, !!ctx.forceExplicitServerProgressiveSeek,
        !!ctx.forceDvdSubFileTranscode, !!ctx.forceInterlacedTsTranscode,
        !!ctx.manualDirectPlayOverride, !!ctx.manualRemuxOverride,
        ctx.forceVideoTranscodeCodec || "", (typeof ctx.forcePlaybackInfoAudioStreamIndex === "number" ? ctx.forcePlaybackInfoAudioStreamIndex : -1),
        ctx.forcePlaybackInfoAudioCodec || "",
        ctx.forceAudioStreamCopyInPlaybackInfo === false ? "piAudioCopy=0" : (ctx.forceAudioStreamCopyInPlaybackInfo === true ? "piAudioCopy=1" : "piAudioCopy=auto"),
        ctx.forcePolicyTranscodeHls === true ? "policyHls=1" : (ctx.forcePolicyTranscodeHls === false ? "policyHls=0" : "policyHls=auto"),
        ctx.forcePolicyTranscodeHlsColdStart === true ? "policyHlsCold=1" : (ctx.forcePolicyTranscodeHlsColdStart === false ? "policyHlsCold=0" : "policyHlsCold=auto"),
        "policyVideoBitrate=" + _forcedPolicyTranscodeVideoBitrate(ctx),
        "policyMax=" + (Number(ctx.forcePolicyTranscodeMaxWidth || 0) | 0) + "x" + (Number(ctx.forcePolicyTranscodeMaxHeight || 0) | 0),
        ctx.forcePolicyTranscodeAllowAudioCopy === true ? "policyAudioCopy=1" : (ctx.forcePolicyTranscodeAllowAudioCopy === false ? "policyAudioCopy=0" : "policyAudioCopy=auto"),
        !!ctx.disableDefaultSubtitleRemux, !!ctx.disableHevcMain10MkvRemux,
        ctx.selectedSubtitleIsText === true ? "sub-text" : (ctx.selectedSubtitleIsImage === true ? "sub-image" : "sub-?"),
        ctx.forceTextSubtitleServerBurnIn === true ? "text-burn=1" : "text-burn=0",
        ctx.currentPlaybackVideoTranscodeByPolicy === true ? "current-video-tc=1" : "current-video-tc=0",
        ctx.preferExternalTextSubtitlesInRemux === true ? "external-text" : "embed-text", !!ctx.disableAutoFrenchAudio,
        !!ctx.disableAutoVoFrenchFullSubtitle, ctx.preferFrenchAudio === false ? "no-fr" : "fr"
    ].join("|")
}
function _cloneResult(obj) {
    if (!obj) return null
    var out = {}
    for (var k in obj) {
        if (obj.hasOwnProperty(k)) out[k] = obj[k]
    }
    return out
}
function _callLaterSafe(fn) {
    try { Qt.callLater(fn); return } catch(e) {}
    fn()
}
function _maybeReplayCached(key, onSuccess) {
    var now = (new Date()).getTime()
    if (key === _lastNegResultKey && _lastNegResult && (now - _lastNegResultTs) < _minIntervalMs) {

        if (onSuccess) {
            var out = _cloneResult(_lastNegResult)
            _callLaterSafe(function(){ onSuccess(out) })
        }
        return true
    }
    return false
}
function _addInFlightWaiter(key, onSuccess) {
    if (!onSuccess) return
    if (!_inFlightWaiters[key]) _inFlightWaiters[key] = []
    _inFlightWaiters[key].push(onSuccess)
}
function _flushInFlightWaiters(key, result) {
    var arr = _inFlightWaiters[key]
    delete _inFlightWaiters[key]
    if (!arr || !arr.length) return
    for (var i = 0; i < arr.length; i++) {
        var cb = arr[i]
        if (!cb) continue
        var out = _cloneResult(result)
        _callLaterSafe((function(fn, payload){
            return function(){ fn(payload) }
        })(cb, out))
    }
}
function _allowTextSubtitleServerBurnIn(ctx) {
    // Sécurité Freebox : le burn-in serveur d'un SRT pendant un vrai transcodage
    // vidéo peut produire un flux sans frames vidéo après seek/reprise. On ne
    // l'autorise que via un flag explicite de fallback.
    return !!(ctx && ctx.forceTextSubtitleServerBurnIn === true)
}
function _chooseSubtitleMethod(ctx, mustHls) {
    if (ctx.useLocalSubs === true) return null
    if (typeof ctx.selectedSubtitleStream !== "number" || ctx.selectedSubtitleStream < 0) return null
    if (ctx.forceSubtitleEncode === true && (ctx.selectedSubtitleIsText !== true || _allowTextSubtitleServerBurnIn(ctx)))
        return "Encode"
    // External n'est jamais le choix implicite : sur un flux serveur, un SRT/VTT
    // reste côté Jellyfin via Embed. Cela empêche le Router/PlayerOverlay de
    // télécharger une sidecar locale sur un remux/transcode.
    if (ctx.selectedSubtitleIsText === true && ctx.preferExternalTextSubtitlesInRemux === true && !mustHls)
        return "External"
    return mustHls ? "Hls" : "Embed"
}
function _preparePlaybackInfoRequest(ctx) {
    var wantsServerSelect = _needsServerTrackSelection_ctx(ctx)
    var mustHls = (ctx.forceHls === true)
    var allowTextSubtitleServerBurnIn = _allowTextSubtitleServerBurnIn(ctx)
    var preflightTextEncode = !!(allowTextSubtitleServerBurnIn &&
        ctx.currentPlaybackVideoTranscodeByPolicy === true && ctx.selectedSubtitleIsText === true &&
        ctx.useLocalSubs !== true && typeof ctx.selectedSubtitleStream === "number" &&
        ctx.selectedSubtitleStream >= 0)
    var explicitEncode = (ctx.forceSubtitleEncode === true &&
        (ctx.selectedSubtitleIsText !== true || allowTextSubtitleServerBurnIn)) || preflightTextEncode
    var forceDvdSubPreflight = (ctx.forceDvdSubFileTranscode === true &&
                                 _smartPlaybackRulesEnabled(ctx) &&
                                 ctx.manualDirectPlayOverride !== true &&
                                 ctx.manualRemuxOverride !== true)
    var forceInterlacedTsPreflight = (ctx.forceInterlacedTsTranscode === true &&
                                      _smartPlaybackRulesEnabled(ctx) &&
                                      ctx.manualDirectPlayOverride !== true &&
                                      ctx.manualRemuxOverride !== true)
    var playbackInfoWantsHlsProfile = (ctx.forceHlsProfileInPlaybackInfo === true)
    var dpMode = (ctx.forceMp4 === true) ? "mp4"
               : (forceDvdSubPreflight ? "encode"
               : (explicitEncode ? "hls-encode"
               : ((mustHls || playbackInfoWantsHlsProfile) ? "hls" : "auto")))
    var subMethodWanted = _chooseSubtitleMethod(ctx, mustHls || explicitEncode)
    var url = _u(ctx.serverUrl, "/Items/" + encodeURIComponent(ctx.itemId) + "/PlaybackInfo")
    var requestedManualVideoBitrate = _forcedPolicyTranscodeVideoBitrate(ctx)
    var playbackInfoMaxBitrate = requestedManualVideoBitrate > 0
                               ? requestedManualVideoBitrate
                               : REDEFIN_MAX_STREAMING_BITRATE

    // Résoudre la base temporelle AVANT le POST PlaybackInfo.
    // forceServerSeek + startMs>0 a priorité absolue sur le cold-start imposé
    // par un profil strict (Devialet/AV1/HLS).
    var playbackInfoStartMs = Math.max(0, Math.floor(Number(ctx.startMs || 0)))
    var playbackInfoForceServerSeek = !!(ctx.forceServerSeek === true && playbackInfoStartMs > 0)
    var playbackInfoColdStartRequested = (ctx.forcePlaybackInfoColdStart === true)
    var playbackInfoColdStartEffective = !!(playbackInfoColdStartRequested && !playbackInfoForceServerSeek)
    var playbackInfoStartTicks = playbackInfoForceServerSeek
                               ? Math.floor(playbackInfoStartMs * 10000)
                               : ((!playbackInfoColdStartEffective && ctx.preferTicks === true && playbackInfoStartMs > 0)
                                  ? Math.floor(playbackInfoStartMs * 10000) : 0)

    var body = {
        UserId: ctx.userId, StartTimeTicks: playbackInfoStartTicks,
        AudioStreamIndex: (typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0) ? ctx.selectedAudioStream
                          : ((typeof ctx.forcePlaybackInfoAudioStreamIndex === "number" && ctx.forcePlaybackInfoAudioStreamIndex >= 0)
                             ? ctx.forcePlaybackInfoAudioStreamIndex : null),
        SubtitleStreamIndex: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? ctx.selectedSubtitleStream : null,
        EnableDirectPlay: (ctx.forceDirectPlayInPlaybackInfo === false) ? false : (wantsServerSelect ? false : true),
        EnableDirectStream: (ctx.forceDirectStreamInPlaybackInfo === false || ctx.forceServerSeek === true || ctx.forceServerRemux === true) ? false : true,
        EnableTranscoding: true,
        AllowVideoStreamCopy: (ctx.forceVideoStreamCopyInPlaybackInfo === false) ? false : true,
        AllowAudioStreamCopy: (ctx.forceAudioStreamCopyInPlaybackInfo === false) ? false : true,
        VideoCodec: ctx.forcePlaybackInfoVideoCodec || null,
        AudioCodec: ctx.forcePlaybackInfoAudioCodec || null,
        MaxStreamingBitrate: playbackInfoMaxBitrate,
        SubtitleDeliveryMethod: subMethodWanted,
        DeviceProfile: buildDeviceProfile(dpMode)
    }

    // Faire calculer le TranscodingUrl directement par Jellyfin avec le débit
    // choisi par l'utilisateur. La réécriture d'URL plus bas reste une défense.
    if (requestedManualVideoBitrate > 0 && body.DeviceProfile) {
        body.DeviceProfile.MaxStreamingBitrate = requestedManualVideoBitrate
        body.DeviceProfile.MaxStaticBitrate = requestedManualVideoBitrate
    }
    if (forceDvdSubPreflight) {
        body.EnableDirectPlay = false
        body.EnableDirectStream = false
        body.EnableTranscoding = true
        body.AllowVideoStreamCopy = false
        body.AllowAudioStreamCopy = (ctx.forceAudioStreamCopyInPlaybackInfo === false) ? false : true
        body.VideoCodec = "h264"
        if (_isUnsafeFullTranscodeAudioCodecHint(body.AudioCodec)) {
            body.AudioCodec = "ac3"
            body.AllowAudioStreamCopy = false
        }
    }
    if (forceInterlacedTsPreflight) {
        body.EnableDirectPlay = false
        body.EnableDirectStream = false
        body.EnableTranscoding = true
        body.AllowVideoStreamCopy = false
        body.AllowAudioStreamCopy = false
        body.VideoCodec = "h264"
        body.AudioCodec = "ac3"
    }
    if (ctx.forceServerSeek === true || mustHls === true)
        body.EnableDirectPlay = false
    if (ctx.forceServerSeek === true || ctx.forceServerRemux === true) {
        body.EnableDirectStream = false
        body.EnableTranscoding = true
    }
    if (ctx.forceTranscodeOnTrackSwitch === true ||
            (ctx.forceAllowTranscoding === true && ctx.forceVideoTranscodeCodec)) {
        body.EnableDirectPlay = false
        body.EnableDirectStream = false
        body.EnableTranscoding = true
        body.AllowVideoStreamCopy = false
        body.VideoCodec = ctx.forcePlaybackInfoVideoCodec || ctx.forceVideoTranscodeCodec || "h264"
    }
    if (_isUnsafeFullTranscodeAudioCodecHint(body.AudioCodec)) {
        body.AudioCodec = "ac3"
        body.AllowAudioStreamCopy = false
    }

    return {
        wantsServerSelect: wantsServerSelect,
        mustHls: mustHls,
        allowTextSubtitleServerBurnIn: allowTextSubtitleServerBurnIn,
        explicitEncode: explicitEncode,
        subMethodWanted: subMethodWanted,
        requestedManualVideoBitrate: requestedManualVideoBitrate,
        playbackInfoStartTicks: playbackInfoStartTicks,
        url: url,
        body: body
    }
}

function _finishPlaybackInfoFailure(ctx, key, explicitEncode, allowTextSubtitleServerBurnIn, onSuccess, onError) {
    var forceHlsFallback = (ctx.forceHls === true || ctx.forceHlsOnDpSeekFallback === true || ctx.forceServerSeek === true)
    var requiresServerPipeline = _ctxRequiresServerPipeline(ctx)
    var hasFallbackTicks = !!(ctx.startMs && ctx.startMs > 0)
    var fbUrl = ""

    // Une erreur PlaybackInfo ne doit jamais convertir une demande explicite
    // de remux/transcodage en DirectPlay statique non vérifié.
    if (requiresServerPipeline && !forceHlsFallback) {
        delete _inFlightWaiters[key]
        if (onError) onError("server_pipeline_required")
        return
    }
    if (forceHlsFallback) {
        var fallbackManualVideoBitrate = _forcedPolicyTranscodeVideoBitrate(ctx)
        fbUrl = buildHlsUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
            audioStreamIndex: (typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0) ? ctx.selectedAudioStream : null,
            subtitleStreamIndex: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? ctx.selectedSubtitleStream : null,
            subtitleMethod: explicitEncode ? "Encode" : "Hls",
            startTimeTicks: hasFallbackTicks ? Math.floor(ctx.startMs * 10000) : 0,
            audioCodec: "ac3,eac3,aac,mp3",
            videoBitrate: fallbackManualVideoBitrate > 0 ? fallbackManualVideoBitrate : null,
            maxBitrate: REDEFIN_MAX_STREAMING_BITRATE,
            allowAudioStreamCopy: true, allowVideoStreamCopy: true,
            enableAutoStreamCopy: true, enableDirectStream: true
        })
        var qctx = {
            accessToken: ctx.accessToken, selectedAudioStream: ctx.selectedAudioStream,
            selectedSubtitleStream: ctx.selectedSubtitleStream, useLocalSubs: ctx.useLocalSubs,
            startMs: ctx.startMs, audioCodecHint: "ac3,eac3,aac,mp3",
            forceAudioCodecHint: true,
            videoBitrate: fallbackManualVideoBitrate > 0 ? fallbackManualVideoBitrate : null,
            forcePolicyTranscodeVideoBitrate: fallbackManualVideoBitrate > 0 ? fallbackManualVideoBitrate : null,
            maxStreamingBitrate: REDEFIN_MAX_STREAMING_BITRATE,
            allowAudioStreamCopy: true, allowVideoStreamCopy: true,
            enableAutoStreamCopy: true, enableDirectStream: true
        }
        fbUrl = _forceQuery(fbUrl, qctx, explicitEncode ? "Encode" : "Hls", true)
    } else {
        fbUrl = getVideoStreamUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId)
    }
    if (!fbUrl || !/[?&]ApiKey=/i.test(fbUrl) ||
            !validatePlaybackUrlStrict(fbUrl, ctx.serverUrl)) {
        delete _inFlightWaiters[key]
        if (onError) onError("invalid_playback_url")
        return
    }
    var result = {
        url: fbUrl, playSessionId: "",
        mediaSourceId: "", isHls: (fbUrl.indexOf(".m3u8") >= 0),
        lastUsedTranscoding: forceHlsFallback, lastUsedDirectStream: false,
        lastUsedServerRemux: false, includeTicks: hasFallbackTicks && forceHlsFallback,
        streamBaseMs: (hasFallbackTicks && forceHlsFallback) ? Math.floor(ctx.startMs) : 0,
        initialLocalSeekMs: (hasFallbackTicks && forceHlsFallback) ? 0 : ((ctx.startMs > 0) ? Math.floor(ctx.startMs) : -1),
        serverTimedStream: hasFallbackTicks && forceHlsFallback, timeShifted: hasFallbackTicks && forceHlsFallback,
        subMethod: forceHlsFallback ? (explicitEncode ? "encode" : "hls") : "none", externalSubtitle: null,
        forceLocalSubs: false, forcedImageBurnIn: !!ctx.forceSubtitleEncode,
        forcedTextBurnIn: !!(explicitEncode && ctx.selectedSubtitleIsText === true && allowTextSubtitleServerBurnIn),
        forcedServerSubtitleBurnIn: !!(explicitEncode && (ctx.selectedSubtitleIsText !== true || allowTextSubtitleServerBurnIn)),
        imageSubtitleRemux: false, imageSubtitleFullRemux: false,
        remuxNoDefaultSubtitle: false, remuxMkvHevcMain10: false,
        singleAudioNoSubtitleDirectPlay: false, autoFrenchAudio: false,
        autoFrenchAudioStreamIndex: -1, pinNoSubDefaultAudio: false,
        fragileSeekRemux: false,
        effectiveAudioStreamIndex: (typeof ctx.selectedAudioStream === "number" ? ctx.selectedAudioStream : -1),
        effectiveSubtitleStreamIndex: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" ? ctx.selectedSubtitleStream : -1),
        effectiveSubtitleMode: forceHlsFallback ? (explicitEncode ? "encode" : "hls") : "none",
        effectiveSubtitleReason: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? "manualFallback" : "none",
        forceServerSeek: !!ctx.forceServerSeek,
        finalUrlKind: forceHlsFallback ? "hls" : "http-dp",
        sourceVideoCodec: "", sourceContainer: "", sourceVideoBitrate: 0,
        sourceVideoIsHevcMain10: false,
        sourceVideoProfile: "", sourceVideoLevel: "", sourceVideoBitDepth: 0,
        sourceVideoPixelFormat: "", sourceVideoWidth: 0, sourceVideoHeight: 0,
        sourceVideoFrameRate: 0
    }
    _lastNegResultKey = key
    _lastNegResultTs = (new Date()).getTime()
    _lastNegResult = _cloneResult(result)
    if (onSuccess) onSuccess(result)
    _flushInFlightWaiters(key, result)
}

function negotiatePlayback(ctx, onSuccess, onError) {

    if (!ctx || !ctx.serverUrl || !ctx.accessToken || !ctx.itemId || !ctx.userId) {

        if (onError) onError("ctx")
        return
    }
    if (!_ensureCoreUrlConfigured()) {

        if (onError) onError("core_url_unavailable")
        return
    }
    // Playback porte toujours un token/API key : WAN HTTP interdit avant toute négociation.
    if (!validateServerUrlStrict(ctx.serverUrl, false)) {

        if (onError) onError("insecure_transport")
        return
    }
    _applyPlaybackRuleMode(ctx)

    if (ctx.forceHlsOnDpSeekFallback === true)
        ctx.forceHls = true
    if (ctx.forceServerSeek === true)
        ctx.preferTicks = true
    var now = (new Date()).getTime(); var key = _makeNegKey(ctx); var forceRetry = (ctx.forceRetry === true)

    if (!forceRetry) {
        if (_inFlightKeys[key]) {

            _addInFlightWaiter(key, onSuccess)
            return
        }
        if (key === _lastNegKey && (now - _lastNegTs) < _minIntervalMs) {
            var replayed = _maybeReplayCached(key, onSuccess)

            if (replayed) return
            return
        }
    }
    _negotiating = true
    _inFlightKeys[key] = true
    _lastNegKey = key
    _lastNegTs = now
    var playbackInfoPlan = _preparePlaybackInfoRequest(ctx)
    var wantsServerSelect = playbackInfoPlan.wantsServerSelect
    var mustHls = playbackInfoPlan.mustHls
    var allowTextSubtitleServerBurnIn = playbackInfoPlan.allowTextSubtitleServerBurnIn
    var explicitEncode = playbackInfoPlan.explicitEncode
    var subMethodWanted = playbackInfoPlan.subMethodWanted
    var requestedManualVideoBitrate = playbackInfoPlan.requestedManualVideoBitrate
    var playbackInfoStartTicks = playbackInfoPlan.playbackInfoStartTicks
    var url = playbackInfoPlan.url
    var body = playbackInfoPlan.body

    _sendPlaybackInfoRequest(url, _headersWithToken(ctx.accessToken), body, function (res) {
        _negotiating = false
        delete _inFlightKeys[key]
        _lastNegTs = (new Date()).getTime()
        var resp = _jsonNormalize(res.json) || {}; var playSessionId = resp && resp.PlaySessionId ? resp.PlaySessionId : ""; var src = (resp && resp.MediaSources && resp.MediaSources.length > 0) ? resp.MediaSources[0] : null
        var mediaSourceId = (src && src.Id) ? src.Id : ""


        var autoVoFrenchFullSubtitleIndex = _autoVoFrenchFullSubtitleIndex(ctx, src); var autoVoFrenchFullSubtitle = autoVoFrenchFullSubtitleIndex >= 0
        if (autoVoFrenchFullSubtitle) {
            ctx.selectedSubtitleStream = autoVoFrenchFullSubtitleIndex
            ctx.useLocalSubs = false
            subMethodWanted = "Embed"

        }
        var selectedSubStream = _subtitleStreamByIndex(src, ctx.selectedSubtitleStream); var imageSubtitleSelected = false; var textSubtitleSelected = false
        if (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) {
            imageSubtitleSelected = _isImageSubtitleSelected(src, ctx.selectedSubtitleStream)
            textSubtitleSelected = _isTextSubtitleSelected(src, ctx.selectedSubtitleStream)
        }

        var serverExternalTextSubtitle = !!( textSubtitleSelected &&
            !mustHls && !explicitEncode &&
            ctx.preferExternalTextSubtitlesInRemux === true )
        if (serverExternalTextSubtitle)
            subMethodWanted = "External"
        var forceTranscodeByPolicy = _shouldForceTranscodeSource(ctx, src); var policyTranscodeVideoCodec = forceTranscodeByPolicy ? _policyTranscodeVideoCodecHint(ctx, src) : null
        var policyTranscodeUseHls = forceTranscodeByPolicy ? _policyTranscodeUseHls(ctx, src) : false
        // Sur QtMultimedia 5.15, un changement de qualité avec reprise doit éviter
        // HLS : Jellyfin omet volontairement StartTimeTicks de ses URL HLS et le
        // seek local du nouveau flux peut figer la Freebox. Le progressif permet
        // d'envoyer StartTimeTicks directement au endpoint /stream.<container>.
        if (policyTranscodeUseHls && ctx.manualQualityRequest === true &&
                ctx.forceServerSeek === true && Number(ctx.startMs || 0) > 0) {
            policyTranscodeUseHls = false

        }
        var policyTranscodeHlsColdStart = (forceTranscodeByPolicy && policyTranscodeUseHls) ? _policyTranscodeHlsColdStart(ctx, src) : false; var fullTranscodeVideoBitrate = _policyTranscodeVideoBitrate(ctx, src)
        var fullTranscodeDims = _policyTranscodeDimensions(ctx, src); var fullTranscodeH264Level = _h264LevelForTranscodeDimensions(fullTranscodeDims, src)
        var forceRemuxByPolicy = (ctx.manualDirectPlayOverride === true || ctx.manualRemuxOverride === true) ? false
                               : _policyForceServerRemux(ctx, src)
        var forceEncodeByPolicy = imageSubtitleSelected && _policyForceSubtitleEncode(ctx, src, selectedSubStream); var hasInternalDvdSubtitle = _hasInternalDvdSubtitle(src)
        var dvdSourceRemuxPreferred = _isDvdFolderSource(src)
        // DVDSub/VobSub dormant est une regle de securite/compatibilite d'usage,
        // pas une incompatibilite du codec video. En mode Original, si la video
        // elle-meme est compatible, on laisse donc le fichier en DirectPlay.
        // Si le codec video est incompatible (AV1, etc.), forceTranscodeByPolicy
        // reste vrai via requiresHardVideoTranscode et garde la priorite.
        var forceDvdSubFileTranscode = !!( hasInternalDvdSubtitle &&
            _smartPlaybackRulesEnabled(ctx) &&
            ctx.manualDirectPlayOverride !== true &&
            ctx.manualRemuxOverride !== true &&
            (!dvdSourceRemuxPreferred || imageSubtitleSelected || explicitEncode) )
        var forceInterlacedTsTranscode = _shouldForceInterlacedTsTranscode(ctx, src)
        var forceTextSubtitleBurnIn = !!( textSubtitleSelected &&
            ctx.useLocalSubs !== true && allowTextSubtitleServerBurnIn &&
            (explicitEncode || forceTranscodeByPolicy || forceDvdSubFileTranscode || forceInterlacedTsTranscode) )
        if (forceTextSubtitleBurnIn) {
            serverExternalTextSubtitle = false
            subMethodWanted = "Encode"
        }
        var autoFrenchForcedDvdSubIndex = _safeFrenchForcedDvdSubtitleIndex(src)
        var forceImageBurnIn = imageSubtitleSelected && (explicitEncode || forceEncodeByPolicy); var preferImageRemux = imageSubtitleSelected && !forceImageBurnIn
        var safeFrenchForcedSubIndex = _safeFrenchForcedSubtitleIndex(src)
        var preferredFrenchForcedSubtitleNeedsServerSelection = _preferredFrenchForcedSubtitleNeedsServerSelection(ctx, src); var frenchDirectPlayGreenGate = _isFrenchDirectPlayGreenGate(ctx, src)
        var remuxNoSubs = (ctx.manualDirectPlayOverride === true || ctx.manualRemuxOverride === true) ? false
                          : _shouldRemuxNoSubsForDirectPlay(ctx, src)
        var hevcMain10Eac3InternalSubRisk = _shouldRemuxHevcMain10Eac3InternalSubFreeboxRisk(ctx, src)
        if (hevcMain10Eac3InternalSubRisk)
            remuxNoSubs = true
        var mp4EditListTimestampRisk = _shouldRemuxMp4EditListTimestampRisk(ctx, src); var mp4TimedMetadataTrackRisk = _shouldRemuxMp4TimedMetadataTrackRisk(ctx, src); var mp4ContainerTimelineRisk = !!(mp4EditListTimestampRisk || mp4TimedMetadataTrackRisk); var singleAudioNoSubtitleDirectPlay = _isSingleAudioNoSubtitleDirectPlayCandidate(ctx, src)
        var remuxMkvHevcMain10 = _shouldServerRemuxHevcMain10(ctx, src); var autoFrenchAudioIndex = _autoFrenchAudioStreamIndex(ctx, src); var autoFrenchAudio = autoFrenchAudioIndex >= 0
        var plannedAudioStreamIndex = _plannedAutomaticAudioStreamIndex(ctx, src, autoFrenchAudioIndex); var forceTrueHd51AudioTranscode = _shouldForceTrueHd51AudioTranscode(ctx, src, plannedAudioStreamIndex)
        var preferredFrenchAudioNeedsServerSelection = _preferredFrenchAudioNeedsServerSelection(ctx, src); var defaultFrenchAudioNotFirst = _shouldRemuxDefaultFrenchAudioNotFirst(ctx, src)
        var dvdFolderMpegRemux = _shouldRemuxDvdFolderMpeg(ctx, src); var pinNoSubDefaultAudio = _shouldPinDefaultAudioForNoSubRemux(ctx, src, remuxNoSubs); var forceServerRemux = forceRemuxByPolicy ||
            forceInterlacedTsTranscode || forceTrueHd51AudioTranscode ||
            remuxNoSubs || remuxMkvHevcMain10 ||
            mp4ContainerTimelineRisk || autoFrenchAudio ||
            preferredFrenchAudioNeedsServerSelection || preferredFrenchForcedSubtitleNeedsServerSelection ||
            defaultFrenchAudioNotFirst || dvdFolderMpegRemux ||
            preferImageRemux || textSubtitleSelected ||
            serverExternalTextSubtitle || ctx.forceServerRemux === true

        var dvdSubTranscodeSubtitleIndex = -1; var dvdSubTranscodeSubtitleMethod = null
        if (forceDvdSubFileTranscode && !ctx.useLocalSubs) {
            if (typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) {
                if (_isImageSubtitleSelected(src, ctx.selectedSubtitleStream)) {
                    dvdSubTranscodeSubtitleIndex = ctx.selectedSubtitleStream
                    dvdSubTranscodeSubtitleMethod = "Encode"
                } else if (_isTextSubtitleSelected(src, ctx.selectedSubtitleStream)) {
                    // Le fichier peut contenir un DVDSub/VobSub dormant qui force
                    // déjà le transcodage vidéo Freebox. Si l'utilisateur choisit
                    // un SRT/VTT, on l'embarque dans le MKV serveur en Embed.
                    // Surtout pas d'overlay QML local, et pas de burn-in Encode
                    // implicite afin d'éviter le bug ffmpeg Encode + seek/reprise.
                    dvdSubTranscodeSubtitleIndex = ctx.selectedSubtitleStream
                    dvdSubTranscodeSubtitleMethod = "Embed"
                } else {
                    dvdSubTranscodeSubtitleIndex = -1
                    dvdSubTranscodeSubtitleMethod = null
                }
            } else if (_smartPlaybackRulesEnabled(ctx) && autoFrenchForcedDvdSubIndex >= 0) {
                dvdSubTranscodeSubtitleIndex = autoFrenchForcedDvdSubIndex
                dvdSubTranscodeSubtitleMethod = "Encode"
            }
        }
        var safeFrenchForcedSubStream = _subtitleStreamByIndex(src, safeFrenchForcedSubIndex); var safeFrenchForcedSubIsText = _isSafeFrenchForcedTextSubtitle(safeFrenchForcedSubStream)
        var carrySafeFrenchForcedSubtitle = !!( _smartPlaybackRulesEnabled(ctx) && forceServerRemux &&
            safeFrenchForcedSubIndex >= 0 && safeFrenchForcedSubIsText &&
            !ctx.useLocalSubs && !(typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) &&
            !forceImageBurnIn && !preferImageRemux &&
            !textSubtitleSelected && !serverExternalTextSubtitle &&
            !hevcMain10Eac3InternalSubRisk )
        var autoSubtitleEmbedIndex = carrySafeFrenchForcedSubtitle ? safeFrenchForcedSubIndex : -1
        if (carrySafeFrenchForcedSubtitle)
            subMethodWanted = "Embed"

        var pinDefaultAudio = _hasExplicitAudio(ctx) ||
            autoFrenchAudio || preferredFrenchAudioNeedsServerSelection ||
            preferredFrenchForcedSubtitleNeedsServerSelection || defaultFrenchAudioNotFirst ||
            dvdFolderMpegRemux || preferImageRemux ||
            forceImageBurnIn || forceDvdSubFileTranscode ||
            forceInterlacedTsTranscode || forceTrueHd51AudioTranscode ||
            forceTranscodeByPolicy || forceServerRemux ||
            ctx.forceServerSeek === true || textSubtitleSelected ||
            serverExternalTextSubtitle || (imageSubtitleSelected === true) ||
            pinNoSubDefaultAudio
        if (forceServerRemux || forceTranscodeByPolicy || forceDvdSubFileTranscode || forceInterlacedTsTranscode || forceTrueHd51AudioTranscode)
            wantsServerSelect = true
        var effectiveAudioStreamIndex = _effectiveAudioStreamForServer( ctx,
            src, imageSubtitleSelected,
            forceImageBurnIn, preferImageRemux,
            pinDefaultAudio, autoFrenchAudioIndex
        )
        forceTrueHd51AudioTranscode = _shouldForceTrueHd51AudioTranscode(ctx, src, effectiveAudioStreamIndex)

        var tx3gSelected = _isTx3gSelected(src, ctx.selectedSubtitleStream)
        // Aucun overlay local ne doit être créé pendant une négociation serveur,
        // sauf opt-in explicite d'un vrai DirectPlay. Le chemin manuel SRT
        // DirectPlay ne passe de toute façon pas par cette négociation.
        var forceLocalOverlay = (ctx.allowLocalSubtitleOverlay === true &&
            tx3gSelected && !mustHls && !forceImageBurnIn)
        if (forceLocalOverlay)
            subMethodWanted = null
        if (forceDvdSubFileTranscode) {
            mustHls = false
            wantsServerSelect = true
            if (dvdSubTranscodeSubtitleMethod)
                subMethodWanted = dvdSubTranscodeSubtitleMethod

        } else if (forceImageBurnIn) {
            mustHls = true
            subMethodWanted = "Encode"
            wantsServerSelect = true

        } else if (forceTextSubtitleBurnIn) {
            mustHls = !!policyTranscodeUseHls
            subMethodWanted = "Encode"
            wantsServerSelect = true

        } else if (preferImageRemux) {
            mustHls = false
            subMethodWanted = "Embed"
            wantsServerSelect = true

        } else if (serverExternalTextSubtitle) {
            wantsServerSelect = true

        } else if (textSubtitleSelected) {
            mustHls = false
            subMethodWanted = "Embed"
            wantsServerSelect = true

        }
        var newUrl = ""; var includeTicks = !!ctx.preferTicks; var lastUsedTranscoding = false; var lastUsedDirectStream = false; var isServerRemux = false; var remuxAudioCodecLock = null; var fragileSeekRemux = false; var dvdDims = null
        var dvdVideoBitrate = 0; var dvdTicks = 0; var dvdAudioCodec = null; var dvdAudioAllowCopy = true; var dvdAudioChannels = null; var dvdAudioBitrate = null; var imageBurnAudioPlan = null; var trueHd51AudioChannels = forceTrueHd51AudioTranscode ? 6 : null
        var trueHd51AudioBitrate = forceTrueHd51AudioTranscode ? 640000 : null; var trueHd51Ticks = 0; var trueHd51AudioOnlyTranscodeActive = false
        // Quand PlaybackInfo fournit déjà une TranscodingUrl HLS pour un
        // transcodage de politique (dont la qualité manuelle), cette URL est
        // désormais considérée comme la source de vérité. Le CoreUrl ne doit
        // alors plus reconstruire les contraintes décidées par Jellyfin.
        var preserveJellyfinTranscodingUrl = false
        if (src) {
            var hasTC   = !!(src.TranscodingUrl && src.TranscodingUrl.length > 0); var cont    = _s(src.Container).toLowerCase(); var pathExt = _extFrom(src.Path || ""); var isFrag  = _isProblematicForSeek(cont || pathExt)
            fragileSeekRemux = !!( isFrag &&
                ctx.manualDirectPlayOverride !== true &&
                !mustHls && !forceTranscodeByPolicy &&
                !forceDvdSubFileTranscode && !forceInterlacedTsTranscode &&
                (ctx.startMs || 0) > 0 )
            var forceTicksForServerRemux = forceServerRemux && (ctx.startMs || 0) > 0; var wantDpStatic = (!wantsServerSelect) &&
                !forceServerRemux && !mustHls &&
                !ctx.forceServerSeek && !forceTranscodeByPolicy &&
                !forceDvdSubFileTranscode && !forceInterlacedTsTranscode &&
                !fragileSeekRemux
            var wantDpLocalSeek = wantDpStatic &&
                (includeTicks && (ctx.startMs || 0) > 0)
            if (forceInterlacedTsTranscode) {
                var tsDims = _interlacedTsTranscodeDimensions(src); var tsVideoBitrate = _policyTranscodeVideoBitrate(ctx, src); var tsMaxFramerate = _interlacedTsMaxFramerate(src)
                var tsAudioChannels = _audioChannelsForStream(src, effectiveAudioStreamIndex); var tsAudioBitrate = _ac3BitrateForChannels(tsAudioChannels); var tsTicks = (ctx.startMs > 0) ? Math.floor(ctx.startMs * 10000) : 0
                var tsSubtitleIndex = (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0)
                                      ? ctx.selectedSubtitleStream : -1
                var tsSubtitleMethod = tsSubtitleIndex >= 0
                                      ? (_isTextSubtitleSelected(src, tsSubtitleIndex) ? "Embed" : "Encode")
                                      : null

                newUrl = buildHighQualityProgressiveTranscodeUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    audioStreamIndex: effectiveAudioStreamIndex, subtitleStreamIndex: tsSubtitleIndex >= 0 ? tsSubtitleIndex : null,
                    subtitleMethod: tsSubtitleMethod, forceNoSubtitle: tsSubtitleIndex < 0,
                    mediaSourceId: mediaSourceId, playSessionId: playSessionId,
                    container: "mkv", startTimeTicks: tsTicks,
                    videoCodec: "h264", audioCodec: "ac3",
                    videoBitrate: tsVideoBitrate, maxWidth: tsDims.width,
                    maxHeight: tsDims.height, maxFramerate: tsMaxFramerate,
                    maxVideoBitDepth: 8, maxStreamingBitrate: REDEFIN_MAX_STREAMING_BITRATE,
                    transcodingMaxAudioChannels: tsAudioChannels, audioChannels: tsAudioChannels,
                    audioBitrate: tsAudioBitrate, allowAudioStreamCopy: false,
                    allowVideoStreamCopy: false, enableAutoStreamCopy: false,
                    enableDirectStream: false, enableTranscoding: true,
                    requireAvc: true, requireNonAnamorphic: true,
                    deInterlace: true, h264Profile: "high",
                    h264Level: "41", copyTimestamps: false,
                    context: "Streaming", transcodeReasons: "VideoProfileNotSupported"
                })
                includeTicks = !!(tsTicks > 0)
                lastUsedTranscoding = true
                lastUsedDirectStream = false
                isServerRemux = false
            } else if (forceDvdSubFileTranscode) {
                dvdDims = _policyTranscodeDimensions(ctx, src)
                dvdVideoBitrate = _policyTranscodeVideoBitrate(ctx, src)
                dvdTicks = (ctx.startMs > 0) ? Math.floor(ctx.startMs * 10000) : 0
                var dvdAudioPlan = _safeFullTranscodeAudioPlan(src, effectiveAudioStreamIndex, _selectedAudioCodec(src, effectiveAudioStreamIndex), true)
                dvdAudioCodec = dvdAudioPlan.codec
                dvdAudioAllowCopy = dvdAudioPlan.allowCopy
                dvdAudioChannels = dvdAudioPlan.channels
                dvdAudioBitrate = dvdAudioPlan.bitrate

                newUrl = buildHighQualityProgressiveTranscodeUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    audioStreamIndex: effectiveAudioStreamIndex, subtitleStreamIndex: dvdSubTranscodeSubtitleIndex >= 0 ? dvdSubTranscodeSubtitleIndex : null,
                    subtitleMethod: dvdSubTranscodeSubtitleIndex >= 0 ? dvdSubTranscodeSubtitleMethod : null, forceNoSubtitle: dvdSubTranscodeSubtitleIndex < 0,
                    mediaSourceId: mediaSourceId, playSessionId: playSessionId,
                    container: "mkv", startTimeTicks: dvdTicks,
                    videoCodec: "h264", audioCodec: dvdAudioCodec || null,
                    videoBitrate: dvdVideoBitrate, maxWidth: dvdDims.width,
                    maxHeight: dvdDims.height, maxVideoBitDepth: 8,
                    maxStreamingBitrate: REDEFIN_MAX_STREAMING_BITRATE, transcodingMaxAudioChannels: dvdAudioChannels || 8,
                    audioChannels: dvdAudioChannels, audioBitrate: dvdAudioBitrate,
                    allowAudioStreamCopy: dvdAudioAllowCopy, allowVideoStreamCopy: false,
                    enableAutoStreamCopy: dvdAudioAllowCopy, enableDirectStream: false,
                    enableTranscoding: true, requireAvc: true,
                    h264Profile: "high", h264Level: fullTranscodeH264Level,
                    copyTimestamps: false, context: "Streaming",
                    transcodeReasons: dvdSubTranscodeSubtitleIndex >= 0 ? "SubtitleCodecNotSupported" : "ContainerNotSupported"
                })
                includeTicks = !!(dvdTicks > 0)
                lastUsedTranscoding = true
                lastUsedDirectStream = false
                isServerRemux = false
            } else if (forceImageBurnIn) {

                var hlsTicksBurn = (ctx.startMs > 0) ? Math.floor(ctx.startMs * 10000) : 0
                var imageBurnAudioCodec = _policyTranscodeAudioCodecHint(ctx, src, effectiveAudioStreamIndex, true)
                var imageBurnAllowAudioCopy = _policyTranscodeAllowAudioCopy(ctx, src, effectiveAudioStreamIndex, true)
                imageBurnAudioPlan = _safeFullTranscodeAudioPlan(src, effectiveAudioStreamIndex, imageBurnAudioCodec, imageBurnAllowAudioCopy)
                newUrl = buildHlsUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    audioStreamIndex: effectiveAudioStreamIndex,
                    subtitleStreamIndex: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? ctx.selectedSubtitleStream : null,
                    subtitleMethod: "Encode", mediaSourceId: mediaSourceId,
                    playSessionId: playSessionId, startTimeTicks: hlsTicksBurn,
                    videoCodec: "h264", audioCodec: imageBurnAudioPlan.codec || imageBurnAudioCodec || "ac3",
                    segmentContainer: "ts", videoBitrate: fullTranscodeVideoBitrate,
                    maxWidth: fullTranscodeDims.width, maxHeight: fullTranscodeDims.height,
                    maxBitrate: REDEFIN_MAX_STREAMING_BITRATE,
                    transcodingMaxAudioChannels: imageBurnAudioPlan.channels,
                    audioChannels: imageBurnAudioPlan.channels, audioBitrate: imageBurnAudioPlan.bitrate,
                    allowAudioStreamCopy: imageBurnAudioPlan.allowCopy, allowVideoStreamCopy: false,
                    enableAutoStreamCopy: imageBurnAudioPlan.allowCopy, enableDirectStream: false
                })
                includeTicks = !!(hlsTicksBurn > 0)
                lastUsedTranscoding = true
                lastUsedDirectStream = false
            } else if (forceTranscodeByPolicy) {
                // Réutiliser la TranscodingUrl Jellyfin seulement si son protocole
                // correspond à celui demandé par la politique ReDeFin. Jellyfin peut
                // renvoyer HLS alors que la qualité manuelle attend un progressif.
                // Dans ce cas, laisser newUrl vide déclenche le fallback progressif
                // commun plus bas, avec StartTimeTicks et sans seek local HLS.
                var jellyfinTcCandidate = hasTC ? _u(ctx.serverUrl, src.TranscodingUrl) : ""
                var jellyfinTcIsHls = !!(jellyfinTcCandidate &&
                    (jellyfinTcCandidate.indexOf(".m3u8") >= 0 || jellyfinTcCandidate.indexOf("/hls") >= 0 ||
                     _s(src && src.TranscodingSubProtocol).toLowerCase() === "hls"))
                var jellyfinTcProtocolMatches = !!(hasTC &&
                    ((policyTranscodeUseHls && jellyfinTcIsHls) || (!policyTranscodeUseHls && !jellyfinTcIsHls)))
                if (jellyfinTcProtocolMatches) {

                    newUrl = jellyfinTcCandidate
                    preserveJellyfinTranscodingUrl = true
                    // Pour un seek HLS interactif, demander au builder URL de
                    // matérialiser StartTimeTicks sur la TranscodingUrl réellement
                    // ouverte par QtMultimedia. PlaybackInfo seul ne suffit pas : les
                    // logs serveur ont montré qu'une URL sans ticks peut recréer FFmpeg
                    // depuis 00:00 malgré un StartTimeTicks présent dans PlaybackInfo.
                    var requestHlsServerSeekTicks = !!(jellyfinTcIsHls &&
                        ctx.forceServerSeek === true && playbackInfoStartTicks > 0)
                    includeTicks = /(?:[?&])StartTimeTicks=[1-9][0-9]*/i.test(newUrl) || requestHlsServerSeekTicks
                    lastUsedTranscoding = true
                    lastUsedDirectStream = false
                } else if (!hasTC && policyTranscodeUseHls) {
                    // Repli uniquement si le serveur n'a fourni aucune URL de
                    // transcodage. Ce chemin conserve la construction historique.
                    var policyHlsAudioCodec = _policyTranscodeAudioCodecHint(ctx, src, effectiveAudioStreamIndex, true); var policyHlsAllowAudioCopy = _policyTranscodeAllowAudioCopy(ctx, src, effectiveAudioStreamIndex, true)

                    var policyHlsTicks = (!policyTranscodeHlsColdStart && ctx.startMs > 0) ? Math.floor(ctx.startMs * 10000) : 0
                    newUrl = buildHlsUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                        audioStreamIndex: effectiveAudioStreamIndex,
                        subtitleStreamIndex: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? ctx.selectedSubtitleStream : null,
                        subtitleMethod: subMethodWanted || null, mediaSourceId: mediaSourceId,
                        playSessionId: playSessionId, startTimeTicks: policyHlsTicks,
                        videoCodec: policyTranscodeVideoCodec || "h264", audioCodec: policyHlsAudioCodec || "",
                        segmentContainer: "ts", transcodeReasons: "VideoCodecNotSupported",
                        requireAvc: ((policyTranscodeVideoCodec || "h264") === "h264") ? true : undefined, minSegments: 1,
                        breakOnNonKeyFrames: true, h264Profile: ((policyTranscodeVideoCodec || "h264") === "h264") ? "high,main,baseline,constrainedbaseline" : null,
                        h264Level: ((policyTranscodeVideoCodec || "h264") === "h264") ? fullTranscodeH264Level : null, h264VideoBitDepth: null,
                        h264RangeType: null, h264Deinterlace: undefined,
                        transcodingMaxAudioChannels: null, audioBitrate: null,
                        videoBitrate: fullTranscodeVideoBitrate, maxVideoBitDepth: null,
                        maxWidth: fullTranscodeDims.width, maxHeight: fullTranscodeDims.height,
                        maxBitrate: REDEFIN_MAX_STREAMING_BITRATE, allowAudioStreamCopy: policyHlsAllowAudioCopy,
                        allowVideoStreamCopy: false, strictNoVideoCopy: true,
                        strictNoAudioCopy: !policyHlsAllowAudioCopy, enableAutoStreamCopy: policyHlsAllowAudioCopy,
                        enableDirectStream: false
                    })
                    includeTicks = !!(policyHlsTicks > 0)
                    lastUsedTranscoding = true
                    lastUsedDirectStream = false
                }
            } else if (forceTrueHd51AudioTranscode && !mustHls && !forceTranscodeByPolicy) {
                trueHd51AudioOnlyTranscodeActive = true
                trueHd51Ticks = (ctx.startMs > 0) ? Math.floor(ctx.startMs * 10000) : 0
                var trueHd51SubtitleIndex = serverExternalTextSubtitle ? -1
                                            : (carrySafeFrenchForcedSubtitle ? safeFrenchForcedSubIndex
                                               : ((!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0)
                                                  ? ctx.selectedSubtitleStream : -1))
                var trueHd51SubtitleMethod = trueHd51SubtitleIndex >= 0 ? (carrySafeFrenchForcedSubtitle ? "Embed" : (subMethodWanted || "Embed"))
                                           : null
                var trueHd51Container = mp4EditListTimestampRisk ? "mkv"
                                      : (_decidePreferredContainerWithSrc(ctx, src) || "mkv")

                newUrl = buildServerSeekProgressiveUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    audioStreamIndex: effectiveAudioStreamIndex, subtitleStreamIndex: trueHd51SubtitleIndex >= 0 ? trueHd51SubtitleIndex : null,
                    subtitleMethod: trueHd51SubtitleMethod, forceNoSubtitle: trueHd51SubtitleIndex < 0,
                    mediaSourceId: mediaSourceId, playSessionId: playSessionId,
                    container: trueHd51Container, startTimeTicks: trueHd51Ticks,
                    videoCodec: _selectedVideoCodec(src), audioCodec: "ac3",
                    allowAudioStreamCopy: false, allowVideoStreamCopy: true,
                    enableAutoStreamCopy: false, enableDirectStream: false,
                    enableTranscoding: true, copyTimestamps: false,
                    context: "Streaming", transcodeReasons: "AudioCodecNotSupported"
                })
                includeTicks = !!(trueHd51Ticks > 0)
                lastUsedTranscoding = true
                lastUsedDirectStream = false
                isServerRemux = false
            } else if (ctx.forceExplicitServerProgressiveSeek === true && (ctx.startMs || 0) > 0 && !mustHls && !forceTranscodeByPolicy) {
                remuxAudioCodecLock = dvdFolderMpegRemux ? _dvdMpegAudioCodecLock(src, effectiveAudioStreamIndex)
                                   : _remuxAudioCodecLock(ctx, src, effectiveAudioStreamIndex, true, false, false)
                var explicitSeekContainer = mp4ContainerTimelineRisk ? "mkv"
                                          : (dvdFolderMpegRemux ? "mpeg" : (_decidePreferredContainerWithSrc(ctx, src) || (cont || pathExt || "mkv")))
                var explicitSeekSubMethod = carrySafeFrenchForcedSubtitle ? "Embed"
                                          : ((!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0)
                                              ? (subMethodWanted || (preferImageRemux ? "Embed" : null)) : null)

                includeTicks = true
                newUrl = buildServerSeekProgressiveUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    audioStreamIndex: effectiveAudioStreamIndex,
                    subtitleStreamIndex: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? ctx.selectedSubtitleStream : null,
                    subtitleMethod: explicitSeekSubMethod,
                    forceNoSubtitle: !(!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0),
                    mediaSourceId: mediaSourceId, playSessionId: playSessionId,
                    container: explicitSeekContainer, startTimeTicks: Math.floor(ctx.startMs * 10000),
                    videoCodec: _selectedVideoCodec(src), audioCodec: remuxAudioCodecLock || _selectedAudioCodec(src, effectiveAudioStreamIndex),
                    forceAudioCodecHint: true, allowAudioStreamCopy: true,
                    allowVideoStreamCopy: true, enableAutoStreamCopy: true,
                    enableDirectStream: false, enableTranscoding: true,
                    copyTimestamps: true, context: "Streaming",
                    transcodeReasons: "ContainerNotSupported"
                })
                lastUsedDirectStream = false
                lastUsedTranscoding = false
                isServerRemux = true
            } else if (ctx.forceJellyfinTranscodingUrlCopyRemux === true && hasTC && !mustHls && !forceTranscodeByPolicy) {
                remuxAudioCodecLock = dvdFolderMpegRemux ? _dvdMpegAudioCodecLock(src, effectiveAudioStreamIndex)
                                   : _remuxAudioCodecLock(ctx, src, effectiveAudioStreamIndex, true, false, false)

                includeTicks = !!(includeTicks || forceTicksForServerRemux || ctx.forceServerSeek || (ctx.startMs || 0) > 0)
                newUrl = _u(ctx.serverUrl, src.TranscodingUrl)
                lastUsedDirectStream = false
                lastUsedTranscoding = false
                isServerRemux = true
            } else if (fragileSeekRemux) {
                remuxAudioCodecLock = _remuxAudioCodecLock(ctx, src, effectiveAudioStreamIndex, true, false, false)

                includeTicks = true
                newUrl = _buildRemuxProgressiveUrl( ctx,
                    src, mediaSourceId,
                    playSessionId, effectiveAudioStreamIndex,
                    carrySafeFrenchForcedSubtitle ? "Embed" : null, includeTicks,
                    "mkv", remuxAudioCodecLock,
                    serverExternalTextSubtitle, autoSubtitleEmbedIndex
                )
                lastUsedDirectStream = false
                lastUsedTranscoding = false
                isServerRemux = true
            } else if (forceServerRemux && !mustHls && !forceTranscodeByPolicy) {
                remuxAudioCodecLock = dvdFolderMpegRemux ? _dvdMpegAudioCodecLock(src, effectiveAudioStreamIndex)
                                   : _remuxAudioCodecLock(ctx, src, effectiveAudioStreamIndex, true, false, false)

                includeTicks = !!(includeTicks || forceTicksForServerRemux || ctx.forceServerSeek)
                var forcedCont0 = mp4ContainerTimelineRisk ? "mkv"
                                : (dvdFolderMpegRemux ? "mpeg" : (_decidePreferredContainerWithSrc(ctx, src) || (cont || pathExt || "mkv")))
                var strictSubMethod = carrySafeFrenchForcedSubtitle ? "Embed"
                                    : ((!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0)
                                        ? (subMethodWanted || (preferImageRemux ? "Embed" : null)) : null)
                newUrl = _buildRemuxProgressiveUrl( ctx,
                    src, mediaSourceId,
                    playSessionId, effectiveAudioStreamIndex,
                    strictSubMethod, includeTicks,
                    forcedCont0, remuxAudioCodecLock,
                    serverExternalTextSubtitle, autoSubtitleEmbedIndex
                )
                lastUsedDirectStream = false
                lastUsedTranscoding = false
                isServerRemux = true
            } else if (wantDpLocalSeek) {

                newUrl = getVideoStreamUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    mediaSourceId: mediaSourceId, container: _containerOrExt(src)
                })
                includeTicks = false
                lastUsedDirectStream = false
                lastUsedTranscoding = false
            } else if (wantDpStatic) {

                newUrl = getVideoStreamUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    mediaSourceId: mediaSourceId, container: _containerOrExt(src)
                })
                includeTicks = false
                lastUsedDirectStream = false
                lastUsedTranscoding = false
            } else if (mustHls) {

                var hlsTicks = (ctx.startMs > 0) ? Math.floor(ctx.startMs * 10000) : 0
                newUrl = buildHlsUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    audioStreamIndex: effectiveAudioStreamIndex,
                    subtitleStreamIndex: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? ctx.selectedSubtitleStream : null,
                    subtitleMethod: subMethodWanted || "Hls", mediaSourceId: mediaSourceId,
                    playSessionId: playSessionId, startTimeTicks: hlsTicks,
                    audioCodec: "ac3,eac3,aac,mp3", maxBitrate: REDEFIN_MAX_STREAMING_BITRATE,
                    allowAudioStreamCopy: true, allowVideoStreamCopy: true,
                    enableAutoStreamCopy: true, enableDirectStream: true
                })
                includeTicks = !!(hlsTicks > 0)
                lastUsedTranscoding = true
                lastUsedDirectStream = false
            } else if ((wantsServerSelect || subMethodWanted === "Embed" || ctx.forceServerSeek === true) && !forceTranscodeByPolicy) {
                remuxAudioCodecLock = _remuxAudioCodecLock(ctx, src, effectiveAudioStreamIndex, true, false, false)

                var includeRemuxTicks = !!((includeTicks && (ctx.startMs || 0) > 0) || ctx.forceServerSeek === true); var forcedCont1 = _decidePreferredContainerWithSrc(ctx, src) || (cont || pathExt || "mkv")
                newUrl = _buildRemuxProgressiveUrl( ctx,
                    src, mediaSourceId,
                    playSessionId, effectiveAudioStreamIndex,
                    subMethodWanted, includeRemuxTicks,
                    forcedCont1, remuxAudioCodecLock,
                    serverExternalTextSubtitle, autoSubtitleEmbedIndex
                )
                lastUsedDirectStream = false
                lastUsedTranscoding = false
                includeTicks = !!(includeRemuxTicks && ctx.startMs > 0)
                isServerRemux = true
            } else if (hasTC && ctx.forceAllowTranscoding === true) {

                newUrl = _u(ctx.serverUrl, src.TranscodingUrl)
                includeTicks = true
                lastUsedTranscoding = true
                lastUsedDirectStream = false
            }
        }
        if (!newUrl || newUrl.length === 0) {
            if (forceTranscodeByPolicy) {

                var policyTicks = (policyTranscodeUseHls && policyTranscodeHlsColdStart) ? 0 : ((ctx.startMs > 0) ? Math.floor(ctx.startMs * 10000) : 0)
                if (policyTranscodeUseHls) {
                    var fallbackPolicyAudioCodec = _policyTranscodeAudioCodecHint(ctx, src, effectiveAudioStreamIndex, true); var fallbackPolicyAllowAudioCopy = _policyTranscodeAllowAudioCopy(ctx, src, effectiveAudioStreamIndex, true)
                    newUrl = buildHlsUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                        audioStreamIndex: effectiveAudioStreamIndex,
                        subtitleStreamIndex: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? ctx.selectedSubtitleStream : null,
                        subtitleMethod: subMethodWanted || null, mediaSourceId: mediaSourceId,
                        playSessionId: playSessionId || "", startTimeTicks: policyTicks,
                        videoCodec: policyTranscodeVideoCodec || "h264", audioCodec: fallbackPolicyAudioCodec || "",
                        segmentContainer: "ts", transcodeReasons: "VideoCodecNotSupported",
                        requireAvc: ((policyTranscodeVideoCodec || "h264") === "h264") ? true : undefined, minSegments: 1,
                        breakOnNonKeyFrames: true, h264Profile: ((policyTranscodeVideoCodec || "h264") === "h264") ? "high,main,baseline,constrainedbaseline" : null,
                        h264Level: ((policyTranscodeVideoCodec || "h264") === "h264") ? fullTranscodeH264Level : null, transcodingMaxAudioChannels: null,
                        audioBitrate: null, videoBitrate: fullTranscodeVideoBitrate,
                        maxWidth: fullTranscodeDims.width, maxHeight: fullTranscodeDims.height,
                        maxBitrate: REDEFIN_MAX_STREAMING_BITRATE,
                        allowAudioStreamCopy: fallbackPolicyAllowAudioCopy, allowVideoStreamCopy: false,
                        enableAutoStreamCopy: fallbackPolicyAllowAudioCopy, enableDirectStream: false
                    })
                } else {
                    var fallbackProgressiveAudioPlan = _safeFullTranscodeAudioPlan( src,
                        effectiveAudioStreamIndex, _policyTranscodeAudioCodecHint(ctx, src, effectiveAudioStreamIndex, false),
                        _policyTranscodeAllowAudioCopy(ctx, src, effectiveAudioStreamIndex, false) )
                    newUrl = buildHighQualityProgressiveTranscodeUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                        audioStreamIndex: effectiveAudioStreamIndex,
                        subtitleStreamIndex: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? ctx.selectedSubtitleStream : null,
                        subtitleMethod: subMethodWanted, mediaSourceId: mediaSourceId,
                        container: _decidePreferredContainerWithSrc(ctx, src) || "mkv", playSessionId: playSessionId || "",
                        startTimeTicks: policyTicks, videoCodec: policyTranscodeVideoCodec || "h264",
                        audioCodec: fallbackProgressiveAudioPlan.codec,
                        forceNoSubtitle: !(typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0),
                        allowAudioStreamCopy: fallbackProgressiveAudioPlan.allowCopy, audioChannels: fallbackProgressiveAudioPlan.channels,
                        audioBitrate: fallbackProgressiveAudioPlan.bitrate, transcodingMaxAudioChannels: fallbackProgressiveAudioPlan.channels,
                        allowVideoStreamCopy: false, enableAutoStreamCopy: fallbackProgressiveAudioPlan.allowCopy,
                        enableDirectStream: false, enableTranscoding: true,
                        requireAvc: ((policyTranscodeVideoCodec || "h264") === "h264"), h264Profile: ((policyTranscodeVideoCodec || "h264") === "h264") ? "high" : null,
                        h264Level: ((policyTranscodeVideoCodec || "h264") === "h264") ? fullTranscodeH264Level : null,
                        videoBitrate: fullTranscodeVideoBitrate,
                        maxWidth: fullTranscodeDims.width, maxHeight: fullTranscodeDims.height,
                        maxStreamingBitrate: REDEFIN_MAX_STREAMING_BITRATE,
                        copyTimestamps: false, context: "Streaming",
                        transcodeReasons: "VideoCodecNotSupported"
                    })
                }
                includeTicks = !!(policyTicks > 0)
                lastUsedTranscoding = true
                lastUsedDirectStream = false
                isServerRemux = false
            } else if (forceTrueHd51AudioTranscode && !mustHls) {
                trueHd51AudioOnlyTranscodeActive = true
                trueHd51Ticks = (ctx.startMs > 0) ? Math.floor(ctx.startMs * 10000) : 0
                var fallbackTrueHd51SubIndex = serverExternalTextSubtitle ? -1
                                               : (carrySafeFrenchForcedSubtitle ? safeFrenchForcedSubIndex
                                                  : ((!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0)
                                                     ? ctx.selectedSubtitleStream : -1))
                newUrl = buildServerSeekProgressiveUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    audioStreamIndex: effectiveAudioStreamIndex, subtitleStreamIndex: fallbackTrueHd51SubIndex >= 0 ? fallbackTrueHd51SubIndex : null,
                    subtitleMethod: fallbackTrueHd51SubIndex >= 0 ? (carrySafeFrenchForcedSubtitle ? "Embed" : (subMethodWanted || "Embed")) : null,
                    forceNoSubtitle: fallbackTrueHd51SubIndex < 0, mediaSourceId: mediaSourceId,
                    playSessionId: playSessionId || "", container: _decidePreferredContainerWithSrc(ctx, src) || "mkv",
                    startTimeTicks: trueHd51Ticks, videoCodec: _selectedVideoCodec(src),
                    audioCodec: "ac3", allowAudioStreamCopy: false,
                    allowVideoStreamCopy: true, enableAutoStreamCopy: false,
                    enableDirectStream: false, enableTranscoding: true,
                    copyTimestamps: false, context: "Streaming",
                    transcodeReasons: "AudioCodecNotSupported"
                })
                includeTicks = !!(trueHd51Ticks > 0)
                lastUsedTranscoding = true
                lastUsedDirectStream = false
                isServerRemux = false
            } else if (mustHls) {

                var fallbackHlsTicks = (ctx.startMs > 0) ? Math.floor(ctx.startMs * 10000) : 0
                newUrl = buildHlsUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    audioStreamIndex: effectiveAudioStreamIndex,
                    subtitleStreamIndex: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? ctx.selectedSubtitleStream : null,
                    subtitleMethod: subMethodWanted || "Hls", mediaSourceId: mediaSourceId,
                    playSessionId: playSessionId, startTimeTicks: fallbackHlsTicks,
                    audioCodec: "ac3,eac3,aac,mp3", maxBitrate: REDEFIN_MAX_STREAMING_BITRATE,
                    allowAudioStreamCopy: true, allowVideoStreamCopy: true,
                    enableAutoStreamCopy: true, enableDirectStream: true
                })
                includeTicks = !!(fallbackHlsTicks > 0)
                lastUsedTranscoding = true
                lastUsedDirectStream = false
            } else if (!wantsServerSelect && !forceServerRemux && !forceTranscodeByPolicy && !fragileSeekRemux) {

                newUrl = getVideoStreamUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    mediaSourceId: mediaSourceId, container: _containerOrExt(src)
                })
                includeTicks = false
                lastUsedTranscoding = false
                lastUsedDirectStream = false
                isServerRemux = false
            } else {
                remuxAudioCodecLock = _remuxAudioCodecLock(ctx, src, effectiveAudioStreamIndex, true, false, false)

                var fbCont = src ? (_decidePreferredContainerWithSrc(ctx, src) || _containerOrExt(src) || "mkv") : "mkv"
                newUrl = buildProgressiveUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    audioStreamIndex: effectiveAudioStreamIndex,
                    subtitleStreamIndex: (serverExternalTextSubtitle ? null : (carrySafeFrenchForcedSubtitle ? safeFrenchForcedSubIndex : ((!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? ctx.selectedSubtitleStream : null))),
                    subtitleMethod: serverExternalTextSubtitle ? null : (carrySafeFrenchForcedSubtitle ? "Embed" : subMethodWanted), mediaSourceId: mediaSourceId,
                    container: fbCont, playSessionId: playSessionId || "",
                    startTimeTicks: (ctx.startMs > 0 && (ctx.preferTicks || ctx.forceServerSeek || forceServerRemux || fragileSeekRemux)) ? Math.floor(ctx.startMs * 10000) : 0,
                    audioCodec: remuxAudioCodecLock || null, forceAudioCodecHint: !!remuxAudioCodecLock,
                    enableTranscoding: false,
                    forceNoSubtitle: serverExternalTextSubtitle || (!carrySafeFrenchForcedSubtitle && !(typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0)),
                    allowAudioStreamCopy: true, allowVideoStreamCopy: true,
                    enableAutoStreamCopy: true, enableDirectStream: true
                })
                includeTicks = !!(ctx.startMs > 0 && (ctx.preferTicks || ctx.forceServerSeek || forceServerRemux || fragileSeekRemux))
                lastUsedTranscoding = false
                lastUsedDirectStream = false
                isServerRemux = true
            }
        }
        var forcedContainer = mp4ContainerTimelineRisk ? "mkv" : (ctx.preferredContainer || _decidePreferredContainerWithSrc(ctx, src)); var looksLikeHls = (newUrl.indexOf(".m3u8") >= 0) || (newUrl.indexOf("/hls") >= 0)
        var policyTranscode = !!(forceTranscodeByPolicy && lastUsedTranscoding); var dvdSubFileTranscodeActive = !!(forceDvdSubFileTranscode && lastUsedTranscoding && !looksLikeHls)
        var interlacedTsTranscodeActive = !!(forceInterlacedTsTranscode && lastUsedTranscoding && !looksLikeHls)
        var policyTranscodeAudioCodecLock = policyTranscode ? _policyTranscodeAudioCodecHint(ctx, src, effectiveAudioStreamIndex, looksLikeHls) : null
        var policyTranscodeAllowAudioCopy = policyTranscode ? _policyTranscodeAllowAudioCopy(ctx, src, effectiveAudioStreamIndex, looksLikeHls) : true; var policyTranscodeAudioPlan = policyTranscode
                                     ? _safeFullTranscodeAudioPlan(src, effectiveAudioStreamIndex, policyTranscodeAudioCodecLock, policyTranscodeAllowAudioCopy) : null
        if (policyTranscodeAudioPlan) {
            policyTranscodeAudioCodecLock = policyTranscodeAudioPlan.codec
            policyTranscodeAllowAudioCopy = policyTranscodeAudioPlan.allowCopy
        }
        var imageSubtitleFullRemux = !!(isServerRemux && preferImageRemux && !looksLikeHls && !forceImageBurnIn && ctx.forceFullRemuxForImageSubtitles === true); var fullRemuxPipe = !!(isServerRemux && !looksLikeHls)
        if (isServerRemux && !looksLikeHls && !remuxAudioCodecLock)
            remuxAudioCodecLock = dvdFolderMpegRemux ? _dvdMpegAudioCodecLock(src, effectiveAudioStreamIndex)
                               : _remuxAudioCodecLock(ctx, src, effectiveAudioStreamIndex, true, false, false)
        var ctxForQuery = {
            serverUrl: ctx.serverUrl, accessToken: ctx.accessToken,
            itemId: ctx.itemId,
            selectedAudioStream: (isServerRemux || policyTranscode || dvdSubFileTranscodeActive || interlacedTsTranscodeActive || trueHd51AudioOnlyTranscodeActive) ? effectiveAudioStreamIndex : -1,
            selectedSubtitleStream: interlacedTsTranscodeActive ? tsSubtitleIndex
                                    : (dvdSubFileTranscodeActive ? dvdSubTranscodeSubtitleIndex
                                       : (serverExternalTextSubtitle ? -1 : (carrySafeFrenchForcedSubtitle ? safeFrenchForcedSubIndex : ctx.selectedSubtitleStream))),
            useLocalSubs: ctx.useLocalSubs || (forceLocalOverlay && !looksLikeHls), startMs: ctx.startMs,
            playSessionId: (isServerRemux || policyTranscode || dvdSubFileTranscodeActive || interlacedTsTranscodeActive || trueHd51AudioOnlyTranscodeActive || looksLikeHls || ctx.forceServerSeek) ? playSessionId : "",
            preferredContainer: (dvdSubFileTranscodeActive || interlacedTsTranscodeActive || trueHd51AudioOnlyTranscodeActive) ? "mkv" : ((isServerRemux || (policyTranscode && !looksLikeHls)) ? (forcedContainer || "mkv") : null),
            forceServerSeek: !!ctx.forceServerSeek, forceServerRemux: !!isServerRemux,
            forcePolicyTranscode: !!policyTranscode,
            playbackInfoStartTimeTicks: playbackInfoStartTicks,
            preserveJellyfinTranscodingUrl: !!preserveJellyfinTranscodingUrl,
            forceServerTranscode: !!(dvdSubFileTranscodeActive || interlacedTsTranscodeActive || trueHd51AudioOnlyTranscodeActive || policyTranscode || (lastUsedTranscoding && !looksLikeHls)),
            lastUsedTranscoding: !!lastUsedTranscoding, audioCodecHint: interlacedTsTranscodeActive
                            ? "ac3" : (dvdSubFileTranscodeActive
                               ? (dvdAudioCodec || null) : (trueHd51AudioOnlyTranscodeActive
                                  ? "ac3"
                                  : (forceImageBurnIn ? (imageBurnAudioPlan && imageBurnAudioPlan.codec ? imageBurnAudioPlan.codec : "ac3") : (isServerRemux ? remuxAudioCodecLock : (policyTranscode ? policyTranscodeAudioCodecLock : null))))),
            forceAudioCodecHint: trueHd51AudioOnlyTranscodeActive ? true : (interlacedTsTranscodeActive ? true : (dvdSubFileTranscodeActive ? !!dvdAudioCodec : (forceImageBurnIn ? !!(imageBurnAudioPlan && imageBurnAudioPlan.codec) : (!!remuxAudioCodecLock || !!policyTranscodeAudioCodecLock)))),
            allowRemuxAudioCodecLock: !!remuxAudioCodecLock,
            videoCodecHint: interlacedTsTranscodeActive ? "h264" : (dvdSubFileTranscodeActive ? "h264" : (forceImageBurnIn ? "h264" : (policyTranscode ? (policyTranscodeVideoCodec || "h264") : ((isServerRemux || trueHd51AudioOnlyTranscodeActive) ? _selectedVideoCodec(src) : null)))),
            segmentContainer: (forceImageBurnIn || (policyTranscode && looksLikeHls)) ? "ts" : null, transcodeReasons: interlacedTsTranscodeActive
                              ? "VideoProfileNotSupported" : (dvdSubFileTranscodeActive
                                 ? (dvdSubTranscodeSubtitleIndex >= 0 ? "SubtitleCodecNotSupported" : "ContainerNotSupported") : (trueHd51AudioOnlyTranscodeActive
                                    ? "AudioCodecNotSupported" : (ctx.forceExplicitServerProgressiveSeek === true
                                       ? "ContainerNotSupported" : ((policyTranscode && looksLikeHls) ? "VideoCodecNotSupported" : null)))),
            copyTimestamps: (dvdSubFileTranscodeActive || interlacedTsTranscodeActive || trueHd51AudioOnlyTranscodeActive) ? false : (ctx.forceExplicitServerProgressiveSeek === true ? true : undefined),
            context: (dvdSubFileTranscodeActive || interlacedTsTranscodeActive || trueHd51AudioOnlyTranscodeActive || ctx.forceExplicitServerProgressiveSeek === true) ? "Streaming" : null,
            forceExplicitServerProgressiveSeek: !!ctx.forceExplicitServerProgressiveSeek,
            requireAvc: (dvdSubFileTranscodeActive || interlacedTsTranscodeActive) ? true : ((policyTranscode && looksLikeHls && (policyTranscodeVideoCodec || "h264") === "h264") ? true : undefined),
            deInterlace: interlacedTsTranscodeActive ? true : undefined, requireNonAnamorphic: interlacedTsTranscodeActive ? true : undefined,
            minSegments: (policyTranscode && looksLikeHls) ? 1 : null, breakOnNonKeyFrames: (policyTranscode && looksLikeHls) ? true : undefined,
            h264Profile: (dvdSubFileTranscodeActive || interlacedTsTranscodeActive) ? "high" : ((policyTranscode && looksLikeHls && (policyTranscodeVideoCodec || "h264") === "h264") ? "high,main,baseline,constrainedbaseline" : null),
            h264Level: interlacedTsTranscodeActive ? "41"
                     : (dvdSubFileTranscodeActive ? fullTranscodeH264Level
                        : ((policyTranscode && (policyTranscodeVideoCodec || "h264") === "h264") ? fullTranscodeH264Level : null)),
            h264VideoBitDepth: null, h264RangeType: null,
            h264Deinterlace: undefined, transcodingMaxAudioChannels: interlacedTsTranscodeActive
                                         ? tsAudioChannels : (dvdSubFileTranscodeActive
                                            ? (dvdAudioChannels || 8) : (trueHd51AudioOnlyTranscodeActive
                                               ? trueHd51AudioChannels : (forceImageBurnIn && imageBurnAudioPlan
                                                  ? imageBurnAudioPlan.channels : (policyTranscodeAudioPlan ? policyTranscodeAudioPlan.channels : null)))),
            audioChannels: interlacedTsTranscodeActive ? tsAudioChannels
                           : (dvdSubFileTranscodeActive ? dvdAudioChannels
                              : (trueHd51AudioOnlyTranscodeActive ? trueHd51AudioChannels
                                 : (forceImageBurnIn && imageBurnAudioPlan ? imageBurnAudioPlan.channels
                                    : (policyTranscodeAudioPlan ? policyTranscodeAudioPlan.channels : null)))), audioBitrate: interlacedTsTranscodeActive
                          ? tsAudioBitrate : (dvdSubFileTranscodeActive
                             ? dvdAudioBitrate : (trueHd51AudioOnlyTranscodeActive
                                ? trueHd51AudioBitrate : (forceImageBurnIn && imageBurnAudioPlan
                                   ? imageBurnAudioPlan.bitrate : (policyTranscodeAudioPlan ? policyTranscodeAudioPlan.bitrate : null)))),
            videoBitrate: requestedManualVideoBitrate > 0 && lastUsedTranscoding
                        ? requestedManualVideoBitrate
                        : (interlacedTsTranscodeActive ? tsVideoBitrate
                           : (dvdSubFileTranscodeActive ? dvdVideoBitrate
                              : ((forceImageBurnIn || policyTranscode) ? fullTranscodeVideoBitrate : null))),
            forcePolicyTranscodeVideoBitrate: requestedManualVideoBitrate > 0 ? requestedManualVideoBitrate : null,
            maxVideoBitDepth: (dvdSubFileTranscodeActive || interlacedTsTranscodeActive) ? 8 : null,
            maxWidth: interlacedTsTranscodeActive && tsDims ? tsDims.width
                    : (dvdSubFileTranscodeActive && dvdDims ? dvdDims.width
                       : ((forceImageBurnIn || policyTranscode) ? fullTranscodeDims.width : null)),
            maxHeight: interlacedTsTranscodeActive && tsDims ? tsDims.height
                     : (dvdSubFileTranscodeActive && dvdDims ? dvdDims.height
                        : ((forceImageBurnIn || policyTranscode) ? fullTranscodeDims.height : null)),
            maxFramerate: interlacedTsTranscodeActive ? tsMaxFramerate : null,
            maxStreamingBitrate: (dvdSubFileTranscodeActive || interlacedTsTranscodeActive || trueHd51AudioOnlyTranscodeActive || forceImageBurnIn || policyTranscode) ? REDEFIN_MAX_STREAMING_BITRATE : null,
            allowAudioStreamCopy: trueHd51AudioOnlyTranscodeActive ? false
                                  : (interlacedTsTranscodeActive ? false
                                     : (dvdSubFileTranscodeActive ? dvdAudioAllowCopy
                                        : (forceImageBurnIn && imageBurnAudioPlan ? imageBurnAudioPlan.allowCopy
                                           : (policyTranscode ? policyTranscodeAllowAudioCopy : true)))),
            allowVideoStreamCopy: trueHd51AudioOnlyTranscodeActive ? true : ((dvdSubFileTranscodeActive || interlacedTsTranscodeActive || forceImageBurnIn || policyTranscode) ? false : true),
            enableAutoStreamCopy: trueHd51AudioOnlyTranscodeActive ? false
                                  : (interlacedTsTranscodeActive ? false
                                     : (dvdSubFileTranscodeActive ? dvdAudioAllowCopy
                                        : (forceImageBurnIn && imageBurnAudioPlan ? imageBurnAudioPlan.allowCopy
                                           : (policyTranscode ? policyTranscodeAllowAudioCopy : true)))),
            enableDirectStream: trueHd51AudioOnlyTranscodeActive ? false : ((dvdSubFileTranscodeActive || interlacedTsTranscodeActive) ? false : (policyTranscode ? false : ((!looksLikeHls && isServerRemux) ? false : ((forceImageBurnIn || imageSubtitleFullRemux) ? false : true)))),
            enableTranscoding: trueHd51AudioOnlyTranscodeActive ? true : ((dvdSubFileTranscodeActive || interlacedTsTranscodeActive) ? true : (policyTranscode ? true : ((!looksLikeHls && isServerRemux) ? true : (imageSubtitleFullRemux ? true : ((!looksLikeHls && !forceImageBurnIn) ? false : true)))))
        }
        var finalSubMethodForQuery = interlacedTsTranscodeActive ? (tsSubtitleIndex >= 0 ? tsSubtitleMethod : null)
                                   : (dvdSubFileTranscodeActive ? dvdSubTranscodeSubtitleMethod
                                      : (serverExternalTextSubtitle ? null
                                      : (carrySafeFrenchForcedSubtitle ? "Embed"
                                         : (forceImageBurnIn ? "Encode"
                                               : (looksLikeHls ? (subMethodWanted || "Hls") : subMethodWanted)))))

        newUrl = _forceQuery( newUrl,
            ctxForQuery, finalSubMethodForQuery,
            includeTicks )

        // Une URL média complète peut dépasser 512 caractères. Elle doit être
        // validée comme ressource de lecture, pas comme simple URL serveur.
        if (!newUrl || !/[?&]ApiKey=/i.test(newUrl)) {
            delete _inFlightWaiters[key]

            if (onError) onError("invalid_playback_url")
            return
        }
        if (!validatePlaybackUrlStrict(newUrl, ctx.serverUrl)) {
            delete _inFlightWaiters[key]

            if (onError) onError("invalid_playback_url")
            return
        }
        // Jellyfin n'inclut pas StartTimeTicks dans ToUrl() pour HLS. Sur la
        // Freebox, ne jamais compenser par un seek local du nouveau HLS. Les
        // qualités manuelles sont déroutées vers le progressif ; cette garde
        // protège les rares chemins explicitement HLS qui demanderaient encore
        // une reprise non représentable proprement par QtMultimedia 5.15.
        // Pour HLS, la preuve de la timeline serveur doit être portée par l'URL
        // finale réellement donnée à QtMultimedia, pas seulement par le POST
        // PlaybackInfo. Cela évite de déclarer serverTimed=true alors que le job
        // FFmpeg repart en réalité de zéro.
        if (looksLikeHls && ctx.forceServerSeek === true && ctx.startMs > 0) {
            var finalHlsHasStartTimeTicks = /(?:[?&])StartTimeTicks=[1-9][0-9]*/i.test(newUrl)
            includeTicks = finalHlsHasStartTimeTicks

        }

        if (looksLikeHls && ctx.forceServerSeek === true && ctx.startMs > 0 && !includeTicks) {

            delete _inFlightWaiters[key]

            if (onError) onError("hls_seek_requires_progressive")
            return
        }
        var externalSub = null
        if ((forceLocalOverlay || serverExternalTextSubtitle) && !looksLikeHls && mediaSourceId && typeof ctx.selectedSubtitleStream === "number") {
            externalSub = {
                urlSrt: _subtitleResultUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, mediaSourceId, ctx.selectedSubtitleStream, "srt"),
                urlVtt: _subtitleResultUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, mediaSourceId, ctx.selectedSubtitleStream, "vtt"),
                index:  ctx.selectedSubtitleStream, serverExternal: !!serverExternalTextSubtitle
            }

        } else {

        }
        var isHls = looksLikeHls; var effectiveSubtitleStreamIndex = -1; var effectiveSubtitleMode = "none"; var effectiveSubtitleReason = "none"
        if (interlacedTsTranscodeActive && tsSubtitleIndex >= 0) {
            effectiveSubtitleStreamIndex = tsSubtitleIndex
            effectiveSubtitleMode = tsSubtitleMethod ? String(tsSubtitleMethod).toLowerCase() : "none"
            effectiveSubtitleReason = (tsSubtitleMethod === "Embed")
                                      ? "manualInterlacedTsServerEmbed"
                                      : "manualInterlacedTsBurnIn"
        } else if (dvdSubFileTranscodeActive && dvdSubTranscodeSubtitleIndex >= 0) {
            effectiveSubtitleStreamIndex = dvdSubTranscodeSubtitleIndex
            effectiveSubtitleMode = dvdSubTranscodeSubtitleMethod ? String(dvdSubTranscodeSubtitleMethod).toLowerCase() : "none"
            effectiveSubtitleReason = (typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? "manualDvdSubFileTranscode" : "safeFrenchForcedDvdSubAuto"
        } else if (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) {
            effectiveSubtitleStreamIndex = ctx.selectedSubtitleStream
            effectiveSubtitleMode = forceImageBurnIn ? "encode" : (serverExternalTextSubtitle ? "external" :
                                     ((forceLocalOverlay && !isHls) ? "overlay" : (subMethodWanted ? String(subMethodWanted).toLowerCase() : (isHls ? "hls" : "embed"))))
            effectiveSubtitleReason = forceTextSubtitleBurnIn ? "videoTranscodeServerBurnIn"
                                      : (autoVoFrenchFullSubtitle ? "voFrenchFullAutoRemux" : "manual")
        } else if (carrySafeFrenchForcedSubtitle && safeFrenchForcedSubIndex >= 0) {
            effectiveSubtitleStreamIndex = safeFrenchForcedSubIndex
            effectiveSubtitleMode = "embed"
            effectiveSubtitleReason = "safeFrenchForcedAutoRemux"
        } else if (!isServerRemux && frenchDirectPlayGreenGate && safeFrenchForcedSubIndex >= 0) {
            effectiveSubtitleStreamIndex = safeFrenchForcedSubIndex
            effectiveSubtitleMode = "directplay"
            effectiveSubtitleReason = "safeFrenchForcedDefault"
        }
        // Un forceServerSeek doit toujours prendre le pas sur le cold-start local.
        // Sinon un HLS correctement reconstruit avec StartTimeTicks serait encore
        // marqué pour un seek local après ouverture, ce qui annulerait le bénéfice
        // de la reprise serveur et peut figer QtMultimedia sur Freebox.
        var policyHlsColdLocalSeek = !!(policyTranscode && isHls && policyTranscodeHlsColdStart &&
                                        ctx.startMs > 0 && ctx.forceServerSeek !== true)
        var hasServerTimeBase = !!(includeTicks && ctx.startMs > 0); var serverTimed = hasServerTimeBase && !policyHlsColdLocalSeek && (isHls || lastUsedDirectStream || lastUsedTranscoding || ctx.forceServerSeek === true || isServerRemux)
        var initialLocalSeek = policyHlsColdLocalSeek ? Math.floor(ctx.startMs) : (serverTimed ? 0 : ((ctx.startMs > 0) ? Math.floor(ctx.startMs) : -1))
        var result = {
            url: newUrl, playSessionId: playSessionId,
            mediaSourceId: mediaSourceId, isHls: isHls,
            lastUsedTranscoding: lastUsedTranscoding, lastUsedDirectStream: lastUsedDirectStream,
            lastUsedServerRemux: isServerRemux, includeTicks: hasServerTimeBase,
            streamBaseMs: serverTimed ? Math.floor(ctx.startMs) : 0, initialLocalSeekMs: initialLocalSeek,
            serverTimedStream: serverTimed, timeShifted: serverTimed,
            subMethod: interlacedTsTranscodeActive ? (tsSubtitleIndex >= 0 ? "encode" : "none")
                       : (dvdSubFileTranscodeActive ? (dvdSubTranscodeSubtitleMethod ? String(dvdSubTranscodeSubtitleMethod).toLowerCase() : "none")
                          : (forceImageBurnIn ? "encode" : (serverExternalTextSubtitle ? "external" : ((forceLocalOverlay && !isHls) ? "overlay" : (subMethodWanted ? String(subMethodWanted).toLowerCase() : "none"))))),
            externalSubtitle: externalSub, forceLocalSubs: (!!(forceLocalOverlay && !isHls)),
            forceServerExternalSubtitle: !!(serverExternalTextSubtitle && !isHls), forcedImageBurnIn: forceImageBurnIn,
            forcedTextBurnIn: forceTextSubtitleBurnIn, forcedServerSubtitleBurnIn: !!(forceImageBurnIn || forceTextSubtitleBurnIn),
            imageSubtitleRemux: preferImageRemux, imageSubtitleFullRemux: imageSubtitleFullRemux,
            fullRemuxPipe: fullRemuxPipe, remuxNoDefaultSubtitle: remuxNoSubs,
            hevcMain10Eac3InternalSubRisk: hevcMain10Eac3InternalSubRisk, carrySafeFrenchForcedSubtitle: carrySafeFrenchForcedSubtitle,
            safeFrenchForcedSubtitleIndex: safeFrenchForcedSubIndex, autoVoFrenchFullSubtitle: autoVoFrenchFullSubtitle,
            autoVoFrenchFullSubtitleIndex: autoVoFrenchFullSubtitleIndex, remuxMkvHevcMain10: remuxMkvHevcMain10,
            singleAudioNoSubtitleDirectPlay: singleAudioNoSubtitleDirectPlay, autoFrenchAudio: autoFrenchAudio,
            autoFrenchAudioStreamIndex: autoFrenchAudioIndex, preferredFrenchAudioNeedsServerSelection: preferredFrenchAudioNeedsServerSelection,
            preferredFrenchForcedSubtitleNeedsServerSelection: preferredFrenchForcedSubtitleNeedsServerSelection,
            firstInternalSubtitleStreamIndex: _firstInternalSubtitleStreamIndex(src), defaultFrenchAudioNotFirst: defaultFrenchAudioNotFirst,
            dvdFolderMpegRemux: dvdFolderMpegRemux, pinNoSubDefaultAudio: pinNoSubDefaultAudio,
            fragileSeekRemux: fragileSeekRemux, effectiveAudioStreamIndex: effectiveAudioStreamIndex,
            effectiveSubtitleStreamIndex: effectiveSubtitleStreamIndex, effectiveSubtitleMode: effectiveSubtitleMode,
            effectiveSubtitleReason: effectiveSubtitleReason, forceServerSeek: !!ctx.forceServerSeek,
            explicitServerProgressiveSeek: !!ctx.forceExplicitServerProgressiveSeek,
            copyTimestamps: interlacedTsTranscodeActive ? false : !!(ctx.forceExplicitServerProgressiveSeek === true),
            nativeTimestampExpectedMs: (ctx.forceExplicitServerProgressiveSeek === true && serverTimed) ? Math.floor(ctx.startMs) : 0,
            forceTranscodeByPolicy: !!forceTranscodeByPolicy, dvdSubFileTranscode: !!dvdSubFileTranscodeActive,
            dvdSubFilePresent: !!hasInternalDvdSubtitle, interlacedTsTranscodeActive: interlacedTsTranscodeActive,
            requiresInterlacedTsTranscode: !!forceInterlacedTsTranscode, dvdSubSubtitleIndex: dvdSubTranscodeSubtitleIndex,
            dvdSubVideoBitrate: dvdVideoBitrate || 0, dvdSubMaxWidth: dvdDims ? dvdDims.width : 0,
            dvdSubMaxHeight: dvdDims ? dvdDims.height : 0, policyTranscode: !!policyTranscode,
            policyTranscodeUseHls: !!(policyTranscode && looksLikeHls), policyTranscodeHlsColdStart: !!(policyTranscode && looksLikeHls && policyTranscodeHlsColdStart),
            policyTranscodeVideoCodec: policyTranscodeVideoCodec || "", policyTranscodeAudioCodec: policyTranscodeAudioCodecLock || "",
            policyTranscodeAudioCopy: policyTranscodeAllowAudioCopy, trueHd51AudioOnlyTranscode: !!trueHd51AudioOnlyTranscodeActive,
            trueHd51AudioStreamIndex: trueHd51AudioOnlyTranscodeActive ? effectiveAudioStreamIndex : -1,
            trueHd51TargetAudioCodec: trueHd51AudioOnlyTranscodeActive ? "ac3" : "",
            trueHd51TargetAudioChannels: trueHd51AudioOnlyTranscodeActive ? trueHd51AudioChannels : 0,
            trueHd51TargetAudioBitrate: trueHd51AudioOnlyTranscodeActive ? trueHd51AudioBitrate : 0,
            finalUrlKind: isHls ? "hls" : ((dvdSubFileTranscodeActive || interlacedTsTranscodeActive || trueHd51AudioOnlyTranscodeActive || policyTranscode) ? "http-transcode" : (isServerRemux ? "http-remux" : "http-dp")),
            sourceVideoCodec: _sourceVideoCodec(src), sourceContainer: _s(src && src.Container).toLowerCase(),
            sourceVideoBitrate: _sourceVideoBitrate(src),
            sourceVideoIsHevcMain10: _isHevcMain10Source(src),
            sourceVideoProfile: _s((_firstStream(src, "Video") || {}).Profile || ""),
            sourceVideoLevel: _s((_firstStream(src, "Video") || {}).Level !== undefined ? (_firstStream(src, "Video") || {}).Level : ""),
            sourceVideoBitDepth: _numSafe((_firstStream(src, "Video") || {}).BitDepth),
            sourceVideoPixelFormat: _s((_firstStream(src, "Video") || {}).PixelFormat || ""),
            sourceVideoWidth: _numSafe((_firstStream(src, "Video") || {}).Width),
            sourceVideoHeight: _numSafe((_firstStream(src, "Video") || {}).Height),
            sourceVideoFrameRate: _rateSafe(_firstStream(src, "Video"))
        }
        _lastNegResultKey = key
        _lastNegResultTs = (new Date()).getTime()
        _lastNegResult = _cloneResult(result)


        onSuccess && onSuccess(result)
        _flushInFlightWaiters(key, result)
    }, function (err) {

        _negotiating = false
        delete _inFlightKeys[key]
        _lastNegTs = (new Date()).getTime()

        _finishPlaybackInfoFailure(ctx, key, explicitEncode, allowTextSubtitleServerBurnIn, onSuccess, onError)
    })
}
