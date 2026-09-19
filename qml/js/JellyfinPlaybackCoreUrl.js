.pragma library
.import "jellyfinBridge.js" as JellyfinBridge
.import "SafeLog.js" as SafeLog
// Module URL/transport statiquement importé par JellyfinPlaybackCore.js.
// Aucune Qt.include() asynchrone : les dépendances de politique sont injectées
// une seule fois par le Core afin de préserver le premier démarrage Freebox.
var _deps = {}
function configure(deps) { _deps = deps || {}; return true }
function setFbx(fbxCtx) {

    try {
        if (JellyfinBridge && typeof JellyfinBridge.setFbx === "function")
            JellyfinBridge.setFbx(fbxCtx || null)
    } catch(e0) {}
}
function _dep(name) { return _deps && typeof _deps[name] === "function" ? _deps[name] : null }
function _s(v) { var f = _dep("s"); return f ? f(v) : ((v === undefined || v === null) ? "" : (v + "")) }
function _policyBuildDeviceProfile(mode) { var f = _dep("policyBuildDeviceProfile"); return f ? f(mode) : null }
function _policyPreferredContainer(ctx, src) { var f = _dep("policyPreferredContainer"); return f ? f(ctx, src) : null }
function _firstStream(src, type) { var f = _dep("firstStream"); return f ? f(src, type) : null }
function _subtitleStreamByIndex(src, index) { var f = _dep("subtitleStreamByIndex"); return f ? f(src, index) : null }
function _isType(st, name) { var f = _dep("isType"); return f ? f(st, name) : false }
function _isTextSubtitleCodec(codec) { var f = _dep("isTextSubtitleCodec"); return f ? f(codec) : false }
function _isDvdSubtitleCodec(codec) { var f = _dep("isDvdSubtitleCodec"); return f ? f(codec) : false }
function _isSafeFrenchForcedSubtitle(st, src) { var f = _dep("isSafeFrenchForcedSubtitle"); return f ? f(st, src) : false }
function _isSafeFrenchForcedTextSubtitle(st) { var f = _dep("isSafeFrenchForcedTextSubtitle"); return f ? f(st) : false }
function _isLegacyTitleOnlyFrenchForcedTextSubtitle(st) { var f = _dep("isLegacyTitleOnlyFrenchForcedTextSubtitle"); return f ? f(st) : false }
function _isIgnorableTrailingForeignForcedSubtitle(src, st) { var f = _dep("isIgnorableTrailingForeignForcedSubtitle"); return f ? f(src, st) : false }
function _scoreFrenchAudioStream(st) { var f = _dep("scoreFrenchAudioStream"); return f ? f(st) : -9999 }
function _exactAudioCodecHint(codec) { var f = _dep("exactAudioCodecHint"); return f ? f(codec) : null }
function _containerOrExt(src) { var f = _dep("containerOrExt"); return f ? f(src) : "" }
function _isTransportStreamContainer(container, path) { var f = _dep("isTransportStreamContainer"); return f ? f(container, path) : false }
function _hasInterlacedH264Video(streams) { var f = _dep("hasInterlacedH264Video"); return f ? f(streams) : false }

// JellyfinPlaybackCoreUrl.js
// Helpers URL, transport et profil extraits de JellyfinPlaybackCore.js.
// Import statique depuis le Core pour garantir un chargement synchrone sur Freebox. ES5 / Qt 5.x.

function _appendOpt(url, options, optKey, queryKey) {
    if (!options) return url
    var v = options[optKey]
    if (v === undefined || v === null || v === "") return url
    return _appendParam(url, queryKey || optKey, v)
}
function _positiveVideoBitrate(value) {
    var n = Number(value || 0)
    if (!isFinite(n) || n <= 0) return 0
    return Math.max(420000, Math.min(200000000, Math.floor(n)))
}
function _setVideoBitrateQuery(params, value) {
    if (!params) return 0
    delete params.VideoBitRate
    delete params.VideoBitrate
    var n = _positiveVideoBitrate(value)
    if (n > 0) params.VideoBitrate = String(n)
    return n
}
function _appendBoolFlag(url, options, optKey, queryKey, defaultTrue) {
    var v = (options && options[optKey] === false) ? "false" : "true"
    if (defaultTrue === false && (!options || options[optKey] === undefined)) return url
    return _appendParam(url, queryKey || optKey, v)
}
function _appendPlaybackFlags(url, options) {
    url = _appendBoolFlag(url, options, "allowAudioStreamCopy", "AllowAudioStreamCopy", true)
    url = _appendBoolFlag(url, options, "allowVideoStreamCopy", "AllowVideoStreamCopy", true)
    return _appendBoolFlag(url, options, "enableAutoStreamCopy", "EnableAutoStreamCopy", true)
}
function _appendTrackParams(url, options) {
    url = _appendOpt(url, options, "audioStreamIndex", "AudioStreamIndex")
    if (options && typeof options.subtitleStreamIndex === "number" && options.subtitleStreamIndex >= 0)
        url = _appendParam(url, "SubtitleStreamIndex", options.subtitleStreamIndex)
    else if (options && options.forceNoSubtitle === true)
        url = _appendParam(url, "SubtitleStreamIndex", "-1")
    url = _appendOpt(url, options, "subtitleMethod", "SubtitleMethod")
    return url
}
function buildProgressiveUrl(serverUrl, accessToken, itemId, options) {
    options = options || {}

    var url = _u(serverUrl, "/Videos/" + encodeURIComponent(itemId) + "/stream")
    if (options.staticFile === true) url = _appendParam(url, "static", "true")
    // Sécurité : URL média consommée par QtMultimedia/Jellyfin.
    // Ne jamais journaliser cette URL brute.
    url = _appendParam(url, "ApiKey", accessToken)
    url = _appendTrackParams(url, options)
    var directMap = [
        ["mediaSourceId", "MediaSourceId"], ["container", "Container"],
        ["playSessionId", "PlaySessionId"], ["videoCodec", "VideoCodec"]
    ]
    for (var i = 0; i < directMap.length; i++)
        url = _appendOpt(url, options, directMap[i][0], directMap[i][1])
    if (typeof options.startTimeTicks === "number" && options.startTimeTicks > 0)
        url = _appendParam(url, "StartTimeTicks", options.startTimeTicks)
    url = _appendPlaybackFlags(url, options)
    if (options.strictNoVideoCopy === true) {
        url = _appendParam(url, "allowVideoStreamCopy", "false")
        url = _appendParam(url, "enableAutoStreamCopy", "false")
    }
    if (options.strictNoAudioCopy === true)
        url = _appendParam(url, "allowAudioStreamCopy", "false")
    if (options.audioCodec && options.forceAudioCodecHint === true)
        url = _appendParam(url, "AudioCodec", options.audioCodec)

    return url
}

// Reprise serveur progressive dédiée aux changements de piste.
// Cette URL doit lancer un vrai job FFmpeg avec StartTimeTicks tout en
// conservant les codecs vidéo/audio par stream-copy lorsque Jellyfin le permet.
function buildServerSeekProgressiveUrl(serverUrl, accessToken, itemId, options) {
    options = options || {}

    var cont = String(options.container || "mkv").toLowerCase().replace(/[^a-z0-9]/g, "") || "mkv"
    var url = _u(serverUrl, "/Videos/" + encodeURIComponent(itemId) + "/stream." + encodeURIComponent(cont))
    url = _appendParam(url, "ApiKey", accessToken)
    url = _appendTrackParams(url, options)
    url = _appendOpt(url, options, "mediaSourceId", "MediaSourceId")
    url = _appendOpt(url, options, "playSessionId", "PlaySessionId")
    url = _appendParam(url, "Container", cont)
    if (typeof options.startTimeTicks === "number" && options.startTimeTicks > 0)
        url = _appendParam(url, "StartTimeTicks", options.startTimeTicks)
    url = _appendOpt(url, options, "videoCodec", "VideoCodec")
    if (options.audioCodec)
        url = _appendParam(url, "AudioCodec", options.audioCodec)
    url = _appendBoolFlag(url, options, "allowAudioStreamCopy", "AllowAudioStreamCopy", true)
    url = _appendBoolFlag(url, options, "allowVideoStreamCopy", "AllowVideoStreamCopy", true)
    url = _appendBoolFlag(url, options, "enableAutoStreamCopy", "EnableAutoStreamCopy", true)
    url = _appendParam(url, "CopyTimestamps", options.copyTimestamps === true ? "true" : "false")
    url = _appendParam(url, "Context", options.context || "Streaming")
    url = _appendParam(url, "TranscodeReasons", options.transcodeReasons || "ContainerNotSupported")

    return url
}
function buildHighQualityProgressiveTranscodeUrl(serverUrl, accessToken, itemId, options) {
    options = options || {}

    var cont = String(options.container || "mkv").toLowerCase().replace(/[^a-z0-9]/g, "") || "mkv"
    var url = _u(serverUrl, "/Videos/" + encodeURIComponent(itemId) + "/stream." + encodeURIComponent(cont))
    url = _appendParam(url, "ApiKey", accessToken)
    url = _appendTrackParams(url, options)
    url = _appendOpt(url, options, "mediaSourceId", "MediaSourceId")
    url = _appendOpt(url, options, "playSessionId", "PlaySessionId")
    url = _appendParam(url, "Container", cont)
    if (typeof options.startTimeTicks === "number" && options.startTimeTicks > 0)
        url = _appendParam(url, "StartTimeTicks", options.startTimeTicks)

    var map = [
        ["videoCodec", "VideoCodec"], ["audioCodec", "AudioCodec"],
        ["videoBitrate", "VideoBitrate"], ["maxWidth", "MaxWidth"],
        ["maxHeight", "MaxHeight"], ["maxFramerate", "MaxFramerate"],
        ["maxVideoBitDepth", "MaxVideoBitDepth"],
                ["transcodingMaxAudioChannels", "TranscodingMaxAudioChannels"],
        ["audioChannels", "AudioChannels"], ["audioBitrate", "AudioBitRate"],
        ["h264Profile", "Profile"],
        ["h264Level", "Level"]
    ]
    for (var i = 0; i < map.length; i++)
        url = _appendOpt(url, options, map[i][0], map[i][1])

    if (typeof options.requireAvc !== "undefined")
        url = _appendParam(url, "RequireAvc", options.requireAvc ? "true" : "false")
    if (typeof options.deInterlace !== "undefined")
        url = _appendParam(url, "DeInterlace", options.deInterlace ? "true" : "false")
    if (typeof options.requireNonAnamorphic !== "undefined")
        url = _appendParam(url, "RequireNonAnamorphic", options.requireNonAnamorphic ? "true" : "false")
    url = _appendParam(url, "AllowAudioStreamCopy", options.allowAudioStreamCopy === false ? "false" : "true")
    url = _appendParam(url, "AllowVideoStreamCopy", "false")
    url = _appendParam(url, "EnableAutoStreamCopy", "false")
    url = _appendParam(url, "CopyTimestamps", options.copyTimestamps === true ? "true" : "false")
    url = _appendParam(url, "Context", options.context || "Streaming")
    url = _appendParam(url, "TranscodeReasons", options.transcodeReasons || "SubtitleCodecNotSupported")

    return url
}

function _appendHlsPolicyParams(url, options) {
    var map = [
        ["videoBitrate", "VideoBitrate"],
        ["maxVideoBitDepth", "MaxVideoBitDepth"], ["maxWidth", "MaxWidth"],
        ["maxHeight", "MaxHeight"], ["videoCodec", "VideoCodec"],
        ["audioCodec", "AudioCodec"], ["segmentContainer", "SegmentContainer"],
        ["transcodeReasons", "TranscodeReasons"], ["minSegments", "MinSegments"],
        ["h264Profile", "Profile"], ["h264Level", "Level"],
        ["h264VideoBitDepth", "MaxVideoBitDepth"],
        ["transcodingMaxAudioChannels", "TranscodingMaxAudioChannels"],
        ["audioBitrate", "AudioBitRate"]
    ]
    for (var i = 0; i < map.length; i++)
        url = _appendOpt(url, options, map[i][0], map[i][1])
    if (options && typeof options.requireAvc !== "undefined")
        url = _appendParam(url, "RequireAvc", options.requireAvc ? "true" : "false")
    if (options && typeof options.h264Deinterlace !== "undefined")
        url = _appendParam(url, "DeInterlace", options.h264Deinterlace ? "true" : "false")
    return url
}
function buildHlsUrl(serverUrl, accessToken, itemId, options) {
    options = options || {}
    if (!(Number(options.videoBitrate) > 0) && Number(options.forcePolicyTranscodeVideoBitrate) > 0)
        options.videoBitrate = _positiveVideoBitrate(options.forcePolicyTranscodeVideoBitrate)

    var url = _u(serverUrl, "/Videos/" + encodeURIComponent(itemId) + "/master.m3u8")
    // Sécurité : URL média consommée par QtMultimedia/Jellyfin.
    // Ne jamais journaliser cette URL brute.
    url = _appendParam(url, "ApiKey", accessToken)
    url = _appendTrackParams(url, options)
    var directMap = [
        ["mediaSourceId", "MediaSourceId"], ["playSessionId", "PlaySessionId"]
    ]
    for (var i = 0; i < directMap.length; i++)
        url = _appendOpt(url, options, directMap[i][0], directMap[i][1])
    if (typeof options.startTimeTicks === "number" && options.startTimeTicks > 0)
        url = _appendParam(url, "StartTimeTicks", options.startTimeTicks)
    url = _appendHlsPolicyParams(url, options)
    url = _appendPlaybackFlags(url, options)

    return url
}
function getVideoStreamUrl(serverUrl, accessToken, itemId, options) {
    options = options || {}
    var ext = String(options.container || "").toLowerCase().replace(/^\./, "")
    if (ext === "matroska") ext = "mkv"
    if (ext === "mpegts" || ext === "m2ts" || ext === "mts") ext = "ts"
    if (!/^[a-z0-9]{2,8}$/.test(ext)) ext = ""
    var suffix = ext ? ("." + ext) : ""
    var url = _u(serverUrl, "/Videos/" + encodeURIComponent(itemId) + "/stream" + suffix)
    // Sécurité : URL média consommée par QtMultimedia/Jellyfin.
    // Ne jamais journaliser cette URL brute.
    url = _appendParam(url, "ApiKey", accessToken)
    url = _appendParam(url, "static", "true")
    url = _appendParam(url, "SubtitleStreamIndex", "-1")
    if (options.mediaSourceId)
        url = _appendParam(url, "MediaSourceId", options.mediaSourceId)
    url = _appendParam(url, "AllowAudioStreamCopy", "true")
    url = _appendParam(url, "AllowVideoStreamCopy", "true")
    url = _appendParam(url, "EnableAutoStreamCopy", "true")

    return url
}
function _subtitleResultUrl(serverUrl, accessToken, itemId, mediaSourceId, subtitleIndex, format) {
    var url = _u(serverUrl, "/Videos/" + encodeURIComponent(itemId) + "/" +
                 encodeURIComponent(mediaSourceId) + "/Subtitles/" +
                 encodeURIComponent(subtitleIndex) + "/Stream." + (format || "vtt"))
    // Sécurité : URL sous-titre consommée comme ressource Jellyfin.
    // Ne jamais logger cette URL brute.
    return _appendParam(url, "ApiKey", accessToken)
}
function _splitUrl(u) {
    var qpos = u.indexOf("?")
    if (qpos < 0) return { base: u, params: {} }
    var base = u.substring(0, qpos)
    var q = u.substring(qpos + 1)
    var out = {}
    var parts = q.split("&")
    for (var i = 0; i < parts.length; i++) {
        var kv = parts[i].split("=")
        if (!kv[0]) continue
        out[decodeURIComponent(kv[0])] = (kv.length > 1) ? decodeURIComponent(kv.slice(1).join("=")) : ""
    }
    return { base: base, params: out }
}
function _joinUrl(base, params) {
    if (!base) return ""
    if (_isWanHttpUrl(base) && params) {
        for (var authKey in params) {
            if (!params.hasOwnProperty(authKey)) continue
            var nk = _s(authKey).toLowerCase().replace(/[^a-z0-9]/g, "")
            if ((nk === "apikey" || nk === "accesstoken" || nk === "token" ||
                    nk === "xembytoken" || nk === "xmediabrowsertoken") && _s(params[authKey]) !== "")
                return ""
        }
    }
    var keys = []
    for (var k in params) {
        if (params.hasOwnProperty(k) && params[k] !== undefined && params[k] !== null && params[k] !== "")
            keys.push(k)
    }
    keys.sort()
    var qs = []
    for (var i = 0; i < keys.length; i++) {
        var kk = keys[i]
        qs.push(encodeURIComponent(kk) + "=" + encodeURIComponent(params[kk]))
    }
    return base + (qs.length > 0 ? "?" + qs.join("&") : "")
}

// Helpers URL/profil déplacés depuis JellyfinPlaybackCore.js pour garder le core sous la limite de lignes.

function _subtitleProfiles(encodeImages) {
    var text = ["srt", "subrip", "vtt", "webvtt", "ass", "ssa", "dvbtxt"]
    var embedOnly = ["mov_text", "tx3g"]
    var image = ["pgssub", "pgs", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "vobsub", "dvbsub", "dvb_subtitle", "xsub"]
    var out = []
    for (var i = 0; i < text.length; i++) {
        out.push({ Format: text[i], Method: "External" })
        out.push({ Format: text[i], Method: "Embed" })
        if (encodeImages)
            out.push({ Format: text[i], Method: "Encode" })
    }
    for (var e = 0; e < embedOnly.length; e++)
        out.push({ Format: embedOnly[e], Method: "Embed" })
    for (var im = 0; im < image.length; im++)
        out.push({ Format: image[im], Method: encodeImages ? "Encode" : "Embed" })
    return out
}

function buildDeviceProfile(mode) {
    var prof = _policyBuildDeviceProfile(mode)
    if (prof) return prof
    var videoCommon = "h264,hevc"
    var videoLegacy = "mpeg4,msmpeg4v3,mpeg2video"
    var videoWebm = "vp8,vp9"
    var videoAll = videoCommon + "," + videoLegacy + "," + videoWebm
    var audioAll = "ac3,eac3,dts,dca,truehd,flac,opus,vorbis,aac,mp3,mp2"
    var audioMp4 = "ac3,eac3,aac,mp3"
    var hlsMode = (mode === "hls" || mode === "hls-encode")
    return {
        Name: "Freebox-Qt5",
        MaxStreamingBitrate: 200000000,
        MaxStaticBitrate: 200000000,
        MaxAudioChannels: 8,
        DirectPlayProfiles: [
            { Container: "mkv", Type: "Video", VideoCodec: videoAll, AudioCodec: audioAll },
            { Container: "mp4,m4v,mov", Type: "Video", VideoCodec: videoAll, AudioCodec: audioMp4 },
            { Container: "avi", Type: "Video", VideoCodec: "mpeg4,msmpeg4v3,h264,mpeg2video", AudioCodec: audioAll },
            { Container: "ts,m2ts,mpg,mpeg", Type: "Video", VideoCodec: "h264,mpeg2video", AudioCodec: audioAll },
            { Container: "webm", Type: "Video", VideoCodec: videoWebm, AudioCodec: "vorbis,opus" }
        ],
        DirectStreamProfiles: [
            { Container: "mkv", Type: "Video", VideoCodec: videoAll, AudioCodec: audioAll },
            { Container: "ts", Type: "Video", VideoCodec: "h264,mpeg2video", AudioCodec: audioAll },
            { Container: "mp4", Type: "Video", VideoCodec: videoAll, AudioCodec: audioMp4 },
            { Container: "avi", Type: "Video", VideoCodec: "mpeg4,mpeg2video,h264", AudioCodec: audioAll },
            { Container: "webm", Type: "Video", VideoCodec: videoWebm, AudioCodec: "vorbis,opus" }
        ],
        TranscodingProfiles: [
            hlsMode
                ? { Container: "ts", Type: "Video", Protocol: "hls", VideoCodec: "h264", AudioCodec: "ac3,eac3,aac,mp3" }
                : { Container: "mkv", Type: "Video", Protocol: "http", VideoCodec: videoAll, AudioCodec: audioAll }
        ],
        SubtitleProfiles: _subtitleProfiles(mode === "hls-encode" || mode === "encode")
    }
}

function _needsServerTrackSelection_ctx(ctx) {
    if (!ctx) return false
    if (typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0) return true
    if (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) return true
    if (ctx.forceServerSeek === true) return true
    if (ctx.forceServerRemux === true) return true
    if (ctx.forceHevcMain10Remux === true) return true
    return false
}
function _decidePreferredContainer(ctx) {
    var p = _policyPreferredContainer(ctx, null)
    if (p) return p
    if (!ctx) return null
    var needServerSelect =
        (typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0) ||
        (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ||
        (ctx.forceDPOnAudioSwitch === true) ||
        (ctx.forceServerSeek === true) ||
        (ctx.forceServerRemux === true)
    return needServerSelect ? "mkv" : null
}
function _decidePreferredContainerWithSrc(ctx, src) {
    var p = _policyPreferredContainer(ctx, src)
    if (p) return p
    var wanted = _decidePreferredContainer(ctx)
    try {
        var path = (src && src.Path) ? src.Path : ""
        var ext  = _extFrom(path)
        var v    = _firstStream(src, "Video")
        var vCdc = v ? _s(v.Codec).toLowerCase() : ""
        if (ext === "webm" || vCdc === "vp8" || vCdc === "vp9") return "webm"
        if (wanted) return wanted
        if (ext === "mkv" || ext === "matroska") return "mkv"
    } catch(e){}
    return wanted
}

// Construction URL remux progressive centralisée avec les helpers URL.
function _buildRemuxProgressiveUrl(ctx, src, mediaSourceId, playSessionId, effectiveAudioStreamIndex, subMethodWanted, includeTicks, forcedContainer, remuxAudioCodecLock, suppressVideoSubtitle, subtitleOverrideIndex) {
    var ticks = (includeTicks && ctx.startMs > 0) ? Math.floor(ctx.startMs * 10000) : 0
    var selectedSub = null
    if (!suppressVideoSubtitle && !ctx.useLocalSubs) {
        if (typeof subtitleOverrideIndex === "number" && subtitleOverrideIndex >= 0)
            selectedSub = subtitleOverrideIndex
        else if (typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0)
            selectedSub = ctx.selectedSubtitleStream
    }
    return buildProgressiveUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
        audioStreamIndex: effectiveAudioStreamIndex,
        subtitleStreamIndex: selectedSub,
        subtitleMethod: selectedSub !== null ? subMethodWanted : null,
        mediaSourceId: mediaSourceId,
        container: forcedContainer || _decidePreferredContainerWithSrc(ctx, src) || _containerOrExt(src) || "mkv",
        playSessionId: playSessionId || "",
        startTimeTicks: ticks,
        audioCodec: remuxAudioCodecLock || null,
        forceAudioCodecHint: !!remuxAudioCodecLock,
        enableTranscoding: false,
        forceNoSubtitle: selectedSub === null,
        allowAudioStreamCopy: true,
        allowVideoStreamCopy: true,
        enableAutoStreamCopy: true,
        enableDirectStream: true
    })
}

function _normalizeAudioCodecHint(s) {
    if (!s) return null
    var c = String(s).toLowerCase().trim()
    if (c.indexOf(",") >= 0) return c
    if (c === "a_dts" || c === "dca" || c === "dts") return "dts,dca"
    if (c === "ac3") return "ac3"
    if (c === "eac3" || c === "ddp" || c === "dolby_digital_plus") return "eac3"
    if (c === "truehd" || c === "mlp") return "truehd"
    if (c === "flac") return "flac"
    if (c === "opus") return "opus"
    if (c === "vorbis") return "vorbis"
    if (c === "mp3") return "mp3"
    if (c === "aac" || c === "mp4a") return "aac"
    return c
}
function _isTx3gSelected(src, subIndex) {
    var st = _subtitleStreamByIndex(src, subIndex)
    if (!st) return false
    var c = _s(st.Codec).toLowerCase()
    var tag = _s(st.CodecTag).toLowerCase()
    return (c === "mov_text" || c === "tx3g" || tag === "tx3g")
}
var _forceQueryCleanKeys = [
    "static", "Static", "AudioStreamIndex", "SubtitleStreamIndex", "SubtitleMethod",
    "StartTimeTicks", "PlaySessionId", "ApiKey", "Container",
    "AllowAudioStreamCopy", "AllowVideoStreamCopy", "EnableAutoStreamCopy",
    "EnableDirectStream", "EnableTranscoding", "allowAudioStreamCopy",
    "allowVideoStreamCopy", "enableAutoStreamCopy", "enableDirectStream",
    "enableTranscoding", "AudioCodec", "VideoCodec", "SegmentContainer",
    "TranscodeReasons", "RequireAvc", "MinSegments", "BreakOnNonKeyFrames",
    "h264-profile", "h264-level", "h264-videobitdepth", "h264-rangetype",
    "h264-deinterlace", "Profile", "Level", "DeInterlace", "RequireNonAnamorphic",
    "AudioBitrate", "AudioBitRate", "AudioChannels", "VideoBitrate", "VideoBitRate", "MaxVideoBitDepth",
    "CopyTimestamps", "Context",
    "MaxWidth", "MaxHeight", "MaxFramerate", "MaxStreamingBitrate", "TranscodingMaxAudioChannels"
]
function _clearQueryParams(p, keys) {
    for (var i = 0; i < keys.length; i++)
        delete p[keys[i]]
}
function _setQuery(p, key, value) {
    if (value !== undefined && value !== null && value !== "")
        p[key] = String(value)
}
function _setBoolQuery(p, key, value) {
    if (typeof value !== "undefined")
        p[key] = value ? "true" : "false"
}
function _applyHlsCtxQuery(p, ctx, isHlsUrl) {
    if (!isHlsUrl) return
    if (ctx.allowVideoStreamCopy === false) p.allowVideoStreamCopy = "false"
    if (ctx.allowAudioStreamCopy === false) p.allowAudioStreamCopy = "false"
    if (ctx.enableAutoStreamCopy === false) p.enableAutoStreamCopy = "false"
    _setQuery(p, "SegmentContainer", ctx.segmentContainer)
    _setQuery(p, "TranscodeReasons", ctx.transcodeReasons)
    _setBoolQuery(p, "RequireAvc", ctx.requireAvc)
    _setQuery(p, "MinSegments", ctx.minSegments)
    _setQuery(p, "Profile", ctx.h264Profile)
    _setQuery(p, "Level", ctx.h264Level)
    _setQuery(p, "MaxVideoBitDepth", ctx.h264VideoBitDepth)
    _setBoolQuery(p, "DeInterlace", ctx.h264Deinterlace)
    _setQuery(p, "TranscodingMaxAudioChannels", ctx.transcodingMaxAudioChannels)
    _setQuery(p, "AudioBitRate", ctx.audioBitrate)
    var requestedVideoBitrate = _positiveVideoBitrate(ctx.videoBitrate)
    if (!(requestedVideoBitrate > 0))
        requestedVideoBitrate = _positiveVideoBitrate(ctx.forcePolicyTranscodeVideoBitrate)
    if (requestedVideoBitrate > 0)
        _setVideoBitrateQuery(p, requestedVideoBitrate)
    _setQuery(p, "MaxVideoBitDepth", ctx.maxVideoBitDepth)
    _setQuery(p, "MaxWidth", ctx.maxWidth)
    _setQuery(p, "MaxHeight", ctx.maxHeight)
    _setQuery(p, "MaxFramerate", ctx.maxFramerate)
}
// Conserve la TranscodingUrl produite par PlaybackInfo. Ce chemin est
// volontairement minimal : authentification canonique et garde-fous manquants
// uniquement. Les décisions Jellyfin (TranscodeReasons, codecs, profil H.264,
// dimensions, framerate, segmentation...) ne sont jamais réécrites ici.
function _preserveJellyfinTranscodingQuery(url, ctx, includeTicks) {
    if (!url) return ""

    var sp = _splitUrl(url)
    var p = sp.params || {}
    if (!sp.base) return ""

    // La validation playback du Core attend la forme canonique ApiKey. Éviter
    // aussi les doublons de clés historiques que Jellyfin peut retourner.
    delete p.api_key
    delete p.apikey
    _setQuery(p, "ApiKey", ctx && ctx.accessToken ? ctx.accessToken : "")

    if (ctx && ctx.playSessionId && (p.PlaySessionId === undefined || p.PlaySessionId === null || p.PlaySessionId === ""))
        _setQuery(p, "PlaySessionId", ctx.playSessionId)

    // Le bitrate manuel est déjà envoyé dans PlaybackInfo. Ne remplacer la
    // valeur calculée par Jellyfin que si son URL n'en contient aucune.
    var hasJellyfinRate = _positiveVideoBitrate(p.VideoBitrate) > 0 || _positiveVideoBitrate(p.VideoBitRate) > 0
    if (!hasJellyfinRate && ctx) {
        var requested = _positiveVideoBitrate(ctx.forcePolicyTranscodeVideoBitrate)
        if (!(requested > 0)) requested = _positiveVideoBitrate(ctx.videoBitrate)
        if (requested > 0) _setVideoBitrateQuery(p, requested)
    }

    // Seek HLS serveur : PlaybackInfo accepte StartTimeTicks mais la TranscodingUrl
    // renvoyée par Jellyfin peut l'omettre. Dans ce cas, le simple fait d'avoir
    // envoyé StartTimeTicks à PlaybackInfo ne positionne PAS nécessairement le job
    // FFmpeg réellement ouvert par QtMultimedia. Le log serveur peut alors montrer
    // un nouveau transcodage sans -ss et donc un redémarrage réel à 00:00.
    //
    // Pour un forceServerSeek uniquement, matérialiser donc explicitement la cible
    // dans l'URL HLS qui sera effectivement GET par QtMultimedia. Le contrôleur
    // DynamicHls Jellyfin expose StartTimeTicks et le convertit en seek d'entrée
    // FFmpeg. Ne pas modifier les autres TranscodingUrl afin de conserver la
    // stratégie historique hors seek interactif.
    if (ctx && includeTicks === true && ctx.forceServerSeek === true && Number(ctx.startMs) > 0) {
        delete p.startTimeTicks
        delete p.StartTimeTicks
        _setQuery(p, "StartTimeTicks", Math.floor(Number(ctx.startMs) * 10000))
    }

    var preserved=_joinUrl(sp.base,p)

    return preserved
}

function _forceQuery(url, ctx, subMethodWanted, includeTicks) {
    if (!url) return ""

    if (ctx && ctx.accessToken && _isWanHttpUrl(url)) return ""
    var sp = _splitUrl(url)
    var p = sp.params
    var isHlsUrl = (sp.base.indexOf(".m3u8") >= 0) || (sp.base.indexOf("/hls") >= 0)
    if (ctx && ctx.preserveJellyfinTranscodingUrl === true)
        return _preserveJellyfinTranscodingQuery(url, ctx, includeTicks)
    // Conserver le bitrate calculé par Jellyfin dans TranscodingUrl. Le Core peut
    // réécrire l'URL pour les pistes/sous-titres, mais ne doit plus remplacer ce
    // choix dynamique par un ancien palier fixe ReDeFin.
    var jellyfinVideoBitrate = p.VideoBitRate || p.VideoBitrate || ""
    var requestedVideoBitrate = _positiveVideoBitrate(ctx && ctx.videoBitrate)
    if (!(requestedVideoBitrate > 0))
        requestedVideoBitrate = _positiveVideoBitrate(ctx && ctx.forcePolicyTranscodeVideoBitrate)
    _clearQueryParams(p, _forceQueryCleanKeys)
    // Sécurité : reconstruction d’URL média, à ne jamais logger brute.
    _setQuery(p, "ApiKey", ctx.accessToken)
    if (typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0)
        p.AudioStreamIndex = String(ctx.selectedAudioStream)
    if (!ctx.useLocalSubs) {
        if (typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) {
            p.SubtitleStreamIndex = String(ctx.selectedSubtitleStream)
            _setQuery(p, "SubtitleMethod", subMethodWanted)
        } else {
            p.SubtitleStreamIndex = "-1"
        }
    } else {
        p.SubtitleStreamIndex = "-1"
    }
    p.AllowAudioStreamCopy = (ctx.allowAudioStreamCopy === false) ? "false" : "true"
    p.AllowVideoStreamCopy = (ctx.allowVideoStreamCopy === false) ? "false" : "true"
    p.EnableAutoStreamCopy = (ctx.enableAutoStreamCopy === false) ? "false" : "true"
    _setQuery(p, "VideoCodec", ctx.videoCodecHint)
    var remuxAudioCodecLock = !!(ctx.allowRemuxAudioCodecLock === true && ctx.forceServerRemux === true && !isHlsUrl)
    var canPushAudioCodecHint = !!ctx.audioCodecHint &&
        (isHlsUrl || ctx.forceAudioCodecHint === true || remuxAudioCodecLock) &&
        (!(ctx.forceServerRemux === true && !isHlsUrl) || remuxAudioCodecLock)
    if (canPushAudioCodecHint) {
        var norm = _normalizeAudioCodecHint(ctx.audioCodecHint)
        if (norm) p.AudioCodec = norm
    }
    _applyHlsCtxQuery(p, ctx, isHlsUrl)
    // Priorité stricte : choix manuel > bitrate calculé par le Core > valeur
    // fournie par Jellyfin. Une seule casse de clé est conservée dans l'URL.
    if (requestedVideoBitrate > 0)
        _setVideoBitrateQuery(p, requestedVideoBitrate)
    else if (jellyfinVideoBitrate)
        _setVideoBitrateQuery(p, jellyfinVideoBitrate)
    if (!isHlsUrl && (ctx.forceExplicitServerProgressiveSeek === true || ctx.forceServerTranscode === true)) {
        p.AllowAudioStreamCopy = (ctx.allowAudioStreamCopy === false) ? "false" : "true"
        p.AllowVideoStreamCopy = (ctx.allowVideoStreamCopy === false) ? "false" : "true"
        p.EnableAutoStreamCopy = (ctx.enableAutoStreamCopy === false) ? "false" : "true"
        p.CopyTimestamps = (ctx.copyTimestamps === true) ? "true" : "false"
        p.Context = ctx.context || "Streaming"
        p.TranscodeReasons = ctx.transcodeReasons || "ContainerNotSupported"
        _setBoolQuery(p, "RequireAvc", ctx.requireAvc)
        _setBoolQuery(p, "DeInterlace", ctx.deInterlace)
        _setBoolQuery(p, "RequireNonAnamorphic", ctx.requireNonAnamorphic)
        _setQuery(p, "Profile", ctx.h264Profile)
        _setQuery(p, "Level", ctx.h264Level)
        if (requestedVideoBitrate > 0)
            _setVideoBitrateQuery(p, requestedVideoBitrate)
        _setQuery(p, "MaxVideoBitDepth", ctx.maxVideoBitDepth)
        _setQuery(p, "MaxWidth", ctx.maxWidth)
        _setQuery(p, "MaxHeight", ctx.maxHeight)
        _setQuery(p, "MaxFramerate", ctx.maxFramerate)
        _setQuery(p, "TranscodingMaxAudioChannels", ctx.transcodingMaxAudioChannels)
        _setQuery(p, "AudioChannels", ctx.audioChannels)
        _setQuery(p, "AudioBitRate", ctx.audioBitrate)
        if (!(requestedVideoBitrate > 0) && jellyfinVideoBitrate)
            _setVideoBitrateQuery(p, jellyfinVideoBitrate)
    }
    if (includeTicks && ctx.startMs && ctx.startMs > 0)
        p.StartTimeTicks = String(Math.floor(ctx.startMs * 10000))
    if (ctx.playSessionId && (isHlsUrl || ctx.forceServerRemux === true || ctx.forceServerSeek === true ||
            ctx.forcePolicyTranscode === true || ctx.forceServerTranscode === true || ctx.lastUsedTranscoding === true))
        p.PlaySessionId = ctx.playSessionId
    var prefCont = ctx.preferredContainer || _decidePreferredContainer(ctx)
    if (!isHlsUrl && prefCont)
        p.Container = prefCont
    if (!isHlsUrl && !_needsServerTrackSelection_ctx(ctx) && !(includeTicks && ctx.startMs > 0) && ctx.forceServerRemux !== true)
        p.static = "true"
    var forced=_joinUrl(sp.base,p)

    return forced
}

/* ===== Transport HTTP, validation et normalisation PlaybackInfo ===== */
// _hostFromUrlForValidation

function _secIsValidIpv6Literal(host) {
    return SafeLog.isValidIpv6Literal(host)
}

function _secHostFromValue(value) {
    return SafeLog.normalizeHostLike(value, 8192)
}
function _secIsLanHost(value) {
    return SafeLog.isLanHostLike(value)
}

function _hostFromUrlForValidation(url) {
    var s = _s(url).trim()
    var m = s.match(/^[a-zA-Z][a-zA-Z0-9+\-.]*:\/\/([^\/\?#]+)/)
    return m ? _s(m[1]) : ""
}

// _isWanHttpUrl
function _isWanHttpUrl(url) {
    var s = _s(url).trim();
    if (s.toLowerCase().indexOf("http://") !== 0) return false;
    return !_secIsLanHost(s);
}

// normalizeServerUrlStrict
function _transportNormalizeServerUrlStrict(url, allowWanHttp) {
    var s = _s(url).trim();
    if (!s || s.length > 512 || /[\r\n\t]/.test(s)) return "";
    var low = s.toLowerCase();
    if (low.indexOf("http://") !== 0 && low.indexOf("https://") !== 0) return "";
    var authority = _hostFromUrlForValidation(s);
    if (!authority || authority.length > 255 || authority.indexOf("@") >= 0 || /\s/.test(authority)) return "";
    if (!_secHostFromValue(s)) return "";
    if (allowWanHttp !== true && _isWanHttpUrl(s)) return "";
    var hash = s.indexOf("#");
    if (hash >= 0) s = s.substring(0, hash);
    while (s.length > 1 && s.charAt(s.length - 1) === "/") s = s.slice(0, -1);
    return s;
}

// validateServerUrlStrict
function _transportValidateServerUrlStrict(url, allowWanHttp) {
    return _transportNormalizeServerUrlStrict(url, allowWanHttp) !== ""
}

// Les URL média Jellyfin sont nettement plus longues qu'une URL serveur :
// api_key, PlaySessionId, MediaSourceId, codecs, pistes et options HLS/remux.
// Elles gardent toutefois des contraintes plus fortes : URL absolue, même
// origine que le serveur validé et aucun secret en HTTP WAN.
function _secPlaybackOrigin(url) {
    var s = _s(url).trim()
    if (!s || s.length > 8192 || /[\r\n\t]/.test(s)) return null
    var m = /^(https?):\/\/([^\/?#]+)(?:[\/?#]|$)/i.exec(s)
    if (!m) return null
    var scheme = _s(m[1]).toLowerCase()
    var authority = _s(m[2])
    if (!authority || authority.length > 255 || authority.indexOf("@") >= 0 || /\s/.test(authority))
        return null

    var host = ""
    var port = ""
    if (authority.charAt(0) === "[") {
        var rb = authority.indexOf("]")
        if (rb <= 1) return null
        host = authority.substring(1, rb).toLowerCase()
        var tail = authority.substring(rb + 1)
        if (tail) {
            if (tail.charAt(0) !== ":" || !/^:\d+$/.test(tail)) return null
            port = tail.substring(1)
        }
        if (!_secIsValidIpv6Literal(host)) return null
    } else {
        var firstColon = authority.indexOf(":")
        var lastColon = authority.lastIndexOf(":")
        if (firstColon >= 0 && firstColon !== lastColon) return null
        if (lastColon > 0) {
            var possiblePort = authority.substring(lastColon + 1)
            if (!/^\d+$/.test(possiblePort)) return null
            port = possiblePort
            host = authority.substring(0, lastColon).toLowerCase()
        } else {
            host = authority.toLowerCase()
        }
        while (host.length && host.charAt(host.length - 1) === ".")
            host = host.substring(0, host.length - 1)
        if (!host || !_secHostFromValue(scheme + "://" + host)) return null
    }

    if (port) {
        var portNumber = Number(port)
        if (!isFinite(portNumber) || Math.floor(portNumber) !== portNumber ||
                portNumber < 1 || portNumber > 65535)
            return null
        port = String(portNumber)
    } else {
        port = scheme === "https" ? "443" : "80"
    }
    return { scheme: scheme, host: host, port: port }
}

function _transportValidatePlaybackUrlStrict(url, expectedServerUrl) {
    var s = _s(url).trim()
    var reason = "ok"
    if (!s || s.length > 8192 || /[\r\n\t]/.test(s) || s.indexOf("#") >= 0) { reason="shape"; return false }

    var expected = _transportNormalizeServerUrlStrict(expectedServerUrl, false)
    if (!expected) { reason="expected-server"; return false }
    var mediaOrigin = _secPlaybackOrigin(s)
    var serverOrigin = _secPlaybackOrigin(expected)
    if (!mediaOrigin || !serverOrigin) { reason="origin-parse"; return false }
    if (mediaOrigin.scheme !== serverOrigin.scheme || mediaOrigin.host !== serverOrigin.host || mediaOrigin.port !== serverOrigin.port) { reason="origin-mismatch"; return false }

    // HTTPS est toujours accepté après contrôle d'origine. HTTP n'est admis
    // que pour un hôte LAN réellement validé, y compris sur une URL longue.
    if (mediaOrigin.scheme === "http" && !_secIsLanHost("http://" + _hostFromUrlForValidation(s))) { reason="http-non-lan"; return false }
    if (_isWanHttpUrl(s)) { reason="wan-http"; return false }

    return true
}

// _normalizeBase
function _normalizeBase(url) {
    // Playback toujours authentifié : HTTPS sur WAN, HTTP uniquement sur LAN.
    // Aucun appelant ne peut réactiver HTTP WAN via un flag de compatibilité.
    return _transportNormalizeServerUrlStrict(url, false)
}

// _u
function _u(base, path) {
    base = _normalizeBase(base || "")
    if (!base) return ""
    path = _s(path)
    if (!path) return base
    return base + (path.charAt(0) === "/" ? path : ("/" + path))
}

// _headersWithToken
function _headersWithToken(accessToken) {
    try {
        if (JellyfinBridge && typeof JellyfinBridge.headersWithToken === "function")
            return JellyfinBridge.headersWithToken(accessToken || "") || {}
    } catch(e0) {}
    return {}
}

// _jsonNormalize
function _jsonNormalize(json) {
    if (!json) return null
    if (json && json.data && typeof json.data === "object") return json.data
    return json
}

// _appendParam
function _appendParam(url, key, value) {
    if (!url) return ""
    if (value === undefined || value === null || value === "") return url
    var normalizedKey = _s(key).toLowerCase().replace(/[^a-z0-9]/g, "")
    if ((normalizedKey === "apikey" || normalizedKey === "accesstoken" || normalizedKey === "token" ||
            normalizedKey === "xembytoken" || normalizedKey === "xmediabrowsertoken") && _isWanHttpUrl(url))
        return ""
    var sep = (url.indexOf("?") >= 0) ? "&" : "?"
    return url + sep + encodeURIComponent(key) + "=" + encodeURIComponent(String(value))
}

// _extFrom
function _extFrom(urlOrName) {
    var s = _s(urlOrName)
    var m = s.match(/\.([a-z0-9]{2,5})(?:$|\?)/i)
    return m ? m[1].toLowerCase() : ""
}

// _isProblematicForSeek
function _isProblematicForSeek(containerOrPath) {
    var e = _s(containerOrPath).toLowerCase()
    if (e.indexOf(".") >= 0) e = _extFrom(e)
    return (e === "avi" || e === "ts" || e === "mpeg" || e === "mpg" || e === "m2ts" || e === "vob")
}

// PlaybackInfo repart sur un body JSON unique. Le miroir Query+Body était
// StartTimeTicks est conservé explicitement jusqu’à l’URL finale envoyée à Jellyfin.
// Le supprimer réduit la longueur des URL et évite deux sources de vérité.
function _sendPlaybackInfoExact(url, headers, body, onSuccess, onError) {
    body = body || {}

    var bodyText = ""
    try {
        bodyText = JSON.stringify(body)
    } catch(eJson) {
        if (typeof onError === "function")
            onError({ code:"playbackinfo_serialize_error", message:"playbackinfo_serialize_error", status:0 })
        return null
    }
    return _sendRequest("post", url, headers, bodyText, onSuccess, onError)
}

// _sendRequest
function _sendRequest(method, url, headers, body, onSuccess, onError) {
    try {
        if (JellyfinBridge && typeof JellyfinBridge.sendRequestNoCache === "function")
            return JellyfinBridge.sendRequestNoCache(method, url, headers || {}, body, function(res){
                if (typeof onSuccess === "function") onSuccess(res)
            }, function(err){

                if (typeof onError === "function") onError(err)
            })
    } catch(e0) { }
    if (typeof onError === "function")
        onError({ code: "bridge_missing", message: "bridge_missing", status: 0 })
    return null
}

// fetchStreams
function _transportFetchStreams(serverUrl, accessToken, itemId, onSuccess, onError) {

    var url = _u(serverUrl, "/Items/" + encodeURIComponent(itemId))

    _sendRequest("get", url, _headersWithToken(accessToken), null, function (res) {
        var j = _jsonNormalize(res.json) || {}
        var streams = j.MediaStreams || []
        var aLabels = []
        var aMap = []
        var aCodecMap = []
        var sLabels = []
        var sMap = [-1]
        var sIsText = [false]
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
            if (_isType(st, "Audio")) {
                var audioIdx = (typeof st.Index === "number") ? st.Index : i
                if (firstAudioStreamIndex < 0)
                    firstAudioStreamIndex = audioIdx
                if (forcedAudioStreamIndex < 0 && st.IsForced === true)
                    forcedAudioStreamIndex = audioIdx
                if (defaultAudioStreamIndex < 0 && st.IsDefault === true)
                    defaultAudioStreamIndex = audioIdx
                var frenchScore = _scoreFrenchAudioStream(st)
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
                aCodecMap.push(_exactAudioCodecHint(st.Codec) || "")
            } else if (_isType(st, "Subtitle")) {
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
                var textish = (st.IsTextSubtitleStream === true) || _isTextSubtitleCodec(codec)
                sIsText.push(!!textish)

                if (st.IsExternal !== true && _isDvdSubtitleCodec(codec)) {
                    hasInternalDvdSubtitle = true
                    if (safeFrenchForcedDvdSubtitleStreamIndex < 0 && _isSafeFrenchForcedSubtitle(st, j))
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
                    if (_isSafeFrenchForcedSubtitle(st, j)) {
                        if (strictFrenchForcedDefaultSubtitleStreamIndex < 0)
                            strictFrenchForcedDefaultSubtitleStreamIndex = subIdx
                        if (_isSafeFrenchForcedTextSubtitle(st) &&
                            strictFrenchForcedDefaultTextSubtitleStreamIndex < 0)
                            strictFrenchForcedDefaultTextSubtitleStreamIndex = subIdx
                    } else if (!_isIgnorableTrailingForeignForcedSubtitle(j, st)) {
                        // Une piste étrangère uniquement Forced, non Default et placée
                        // après des ancrages français forcés sûrs ne peut pas gagner la
                        // sélection native : elle ne doit pas annuler le DirectPlay.
                        defaultForcedInternalSubtitlesAreSafeFrenchForced = false
                        hasPriorityInternalSubtitleRisk = true
                    }
                } else if (_isLegacyTitleOnlyFrenchForcedTextSubtitle(st)) {
                    legacyFrenchForcedTextSubtitleCandidateCount++
                    if (legacyFrenchForcedTextSubtitleStreamIndex < 0)
                        legacyFrenchForcedTextSubtitleStreamIndex = subIdx
                }
            }
        }
        requiresInterlacedTsTranscode = !!(
            _isTransportStreamContainer(j.Container, j.Path) &&
            _hasInterlacedH264Video(streams)
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

        onSuccess && onSuccess({
            runtimeTicks: j.RunTimeTicks || 0,
            audioLabels: aLabels,
            subtitleLabels: sLabels,
            audioMap: aMap,
            audioCodecMap: aCodecMap,
            subtitleMap: sMap,
            subtitleIsText: sIsText,
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
        })
    }, function (err) {
        onError && onError(err && err.code || "network_error")
    })
}
