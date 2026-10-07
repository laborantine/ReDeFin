.pragma library
.import "SafeLog.js" as SafeLog

/*
 * Diagnostic temporaire ReDeFin : downmix 2.0 / HLS / seek.
 *
 * Objectif : corréler la demande UI, PlaybackInfo, l'URL HLS réellement ouverte,
 * les resets QtMultimedia et la restauration de position sans jamais imprimer de
 * token Jellyfin ni d'URL complète.
 *
 * Ce module est volontairement verbeux et doit être retiré/désactivé avant prod.
 */
var ENABLED = true
var PREFIX = "[RDF-HLS20]"
var _seq = 0

function nowMs() {
    try { return Date.now() } catch(e) { return (new Date()).getTime() }
}
function nextId(kind) {
    _seq++
    return String(kind || "evt") + "#" + _seq
}
function _s(v) { return (v === undefined || v === null) ? "" : String(v) }
function _n(v, defv) {
    var n = Number(v)
    return (isFinite(n) && !isNaN(n)) ? n : (defv === undefined ? 0 : defv)
}
function _b(v) { return v === true ? 1 : 0 }
function _clean(v, maxLen) {
    var s = _s(v).replace(/[\r\n\t]+/g, " ")
    var lim = Math.max(16, Number(maxLen || 220) | 0)
    if (s.length > lim) s = s.substr(0, lim) + "…"
    return s
}
function hash(v) {
    try { return SafeLog.shortHash(_s(v)) } catch(e) { return "00000000" }
}
function _value(v) {
    if (v === undefined) return "u"
    if (v === null) return "null"
    if (typeof v === "boolean") return v ? "1" : "0"
    if (typeof v === "number") return isFinite(v) ? String(v) : "nan"
    if (typeof v === "string") return _clean(v, 260)
    try { return _clean(JSON.stringify(v), 360) } catch(e) { return _clean(v, 260) }
}
function fields(obj) {
    if (!obj) return ""
    var out = []
    for (var k in obj) {
        try {
            if (!Object.prototype.hasOwnProperty.call(obj, k)) continue
            out.push(k + "=" + _value(obj[k]))
        } catch(e) {}
    }
    return out.join(" ")
}
function _emit(level, scope, event, obj) {
    if (!ENABLED) return
    var msg = PREFIX + " t=" + nowMs() + " " + _clean(scope, 48) + "." + _clean(event, 80)
    var tail = fields(obj)
    if (tail) msg += " " + tail
    try {
        if (level === "warn" && console.warn) console.warn(msg)
        else if (level === "error" && console.error) console.error(msg)
        else console.log(msg)
    } catch(e) {}
}
function log(scope, event, obj) { _emit("log", scope, event, obj) }
function warn(scope, event, obj) { _emit("warn", scope, event, obj) }
function error(scope, event, obj) { _emit("error", scope, event, obj) }

function _query(url, name) {
    url = _s(url)
    if (!url || !name) return ""
    try {
        var rx = new RegExp("(?:[?&])" + name.replace(/[.*+?^${}()|[\\]\\]/g, "\\$&") + "=([^&#]*)", "i")
        var m = rx.exec(url)
        return m && m[1] !== undefined ? decodeURIComponent(m[1]) : ""
    } catch(e) { return "" }
}
function urlKind(url) {
    var u = _s(url).toLowerCase()
    if (!u) return "none"
    if (u.indexOf(".m3u8") >= 0 || u.indexOf("/hls") >= 0) return "hls"
    if (u.indexOf("/videos/") >= 0 && u.indexOf("/stream") >= 0 && /(?:[?&])static=true/i.test(u)) return "http-dp-static"
    if (u.indexOf("/videos/") >= 0 && u.indexOf("/stream") >= 0) return "http-progressive"
    return "other"
}
function urlFields(url) {
    url = _s(url)
    var ticks = _query(url, "StartTimeTicks") || _query(url, "startTimeTicks")
    var tag = _query(url, "Tag") || _query(url, "tag")
    return {
        urlKind: urlKind(url),
        urlHash: hash(url),
        urlLen: url.length,
        hasStartTicks: ticks ? 1 : 0,
        startTicks: ticks || "-",
        audioCodec: _query(url, "AudioCodec") || "-",
        audioCh: _query(url, "AudioChannels") || _query(url, "TranscodingMaxAudioChannels") || "-",
        audioBr: _query(url, "AudioBitRate") || _query(url, "AudioBitrate") || "-",
        videoCodec: _query(url, "VideoCodec") || "-",
        videoBr: _query(url, "VideoBitrate") || _query(url, "VideoBitRate") || "-",
        allowACopy: _query(url, "AllowAudioStreamCopy") || "-",
        allowVCopy: _query(url, "AllowVideoStreamCopy") || "-",
        autoCopy: _query(url, "EnableAutoStreamCopy") || "-",
        aIdx: _query(url, "AudioStreamIndex") || "-",
        sIdx: _query(url, "SubtitleStreamIndex") || "-",
        seg: _query(url, "SegmentContainer") || "-",
        minSeg: _query(url, "MinSegments") || "-",
        nonKey: _query(url, "BreakOnNonKeyFrames") || "-",
        ps: hash(_query(url, "PlaySessionId")),
        ms: hash(_query(url, "MediaSourceId")),
        tag: tag ? hash(tag) : "-",
        apiKey: (_query(url, "ApiKey") || _query(url, "api_key")) ? "present" : "absent"
    }
}
function logUrl(scope, event, url, extra) {
    var f = urlFields(url)
    if (extra) {
        for (var k in extra) {
            try { if (Object.prototype.hasOwnProperty.call(extra, k)) f[k] = extra[k] } catch(e) {}
        }
    }
    log(scope, event, f)
}

function ctxFields(ctx) {
    ctx = ctx || {}
    return {
        item: hash(ctx.itemId),
        startMs: Math.floor(_n(ctx.startMs, 0)),
        forceHls: _b(ctx.forceHls),
        preferTicks: _b(ctx.preferTicks),
        serverSeek: _b(ctx.forceServerSeek),
        serverRemux: _b(ctx.forceServerRemux),
        retry: _b(ctx.forceRetry),
        stereo: _s(ctx.audioOutputMode).toLowerCase() === "stereo" ? 1 : 0,
        aIdx: _n(ctx.selectedAudioStream, -1),
        sIdx: _n(ctx.selectedSubtitleStream, -1),
        localSubs: _b(ctx.useLocalSubs),
        allowVCopyPI: ctx.forceVideoStreamCopyInPlaybackInfo === false ? 0 : 1,
        allowACopyPI: ctx.forceAudioStreamCopyInPlaybackInfo === false ? 0 : 1,
        directPI: ctx.forceDirectPlayInPlaybackInfo === false ? 0 : 1,
        dstreamPI: ctx.forceDirectStreamInPlaybackInfo === false ? 0 : 1,
        piVCodec: _s(ctx.forcePlaybackInfoVideoCodec || "-"),
        piACodec: _s(ctx.forcePlaybackInfoAudioCodec || "-"),
        preferStereoHls: _b(ctx.preferStereoAudioOnlyHls),
        currentVideoPolicyTC: _b(ctx.currentPlaybackVideoTranscodeByPolicy),
        trackRebase: _b(ctx.trackSwitchRebase),
        trackLocalStrategy: _n(ctx.trackSwitchLocalStrategy, -1)
    }
}
function logCtx(scope, event, ctx, extra) {
    var f = ctxFields(ctx)
    if (extra) for (var k in extra) { try { if (Object.prototype.hasOwnProperty.call(extra,k)) f[k]=extra[k] } catch(e) {} }
    log(scope, event, f)
}

function sourceFields(src, audioIndex) {
    src = src || {}
    var streams = src.MediaStreams || []
    var video = null, audio = null
    for (var i=0; i<streams.length; i++) {
        var st=streams[i]||{}
        var typ=_s(st.Type).toLowerCase()
        var isVideo = st.Type === 1 || typ === "video"
        var isAudio = st.Type === 0 || typ === "audio"
        if (!video && isVideo) video=st
        if (isAudio && (audio === null || Number(st.Index) === Number(audioIndex))) {
            if (Number(st.Index) === Number(audioIndex)) { audio=st; break }
            if (!audio) audio=st
        }
    }
    video=video||{}; audio=audio||{}
    return {
        mediaSource: hash(src.Id || src.Path || ""),
        container: _s(src.Container || "-"),
        hasTCUrl: src.TranscodingUrl ? 1 : 0,
        tcUrlHash: src.TranscodingUrl ? hash(src.TranscodingUrl) : "-",
        vCodec: _s(video.Codec || "-"),
        vProfile: _s(video.Profile || "-"),
        vDepth: _n(video.BitDepth,0),
        vW: _n(video.Width,0),
        vH: _n(video.Height,0),
        vBr: _n(video.BitRate,0),
        aIdx: _n(audio.Index,-1),
        aCodec: _s(audio.Codec || "-"),
        aCh: _n(audio.Channels,0),
        aLayout: _s(audio.ChannelLayout || "-"),
        aBr: _n(audio.BitRate,0),
        aRate: _n(audio.SampleRate,0)
    }
}
function logSource(scope,event,src,audioIndex,extra) {
    var f=sourceFields(src,audioIndex)
    if(extra) for(var k in extra){try{if(Object.prototype.hasOwnProperty.call(extra,k))f[k]=extra[k]}catch(e){}}
    log(scope,event,f)
}

function resultFields(res) {
    res=res||{}
    return {
        isHls:_b(res.isHls),
        tc:_b(res.lastUsedTranscoding),
        ds:_b(res.lastUsedDirectStream),
        remux:_b(res.lastUsedServerRemux),
        serverTimed:_b(res.serverTimedStream),
        shifted:_b(res.timeShifted),
        includeTicks:_b(res.includeTicks),
        streamBase:_n(res.streamBaseMs,0),
        localSeek:_n(res.initialLocalSeekMs,-1),
        serverSeek:_b(res.forceServerSeek),
        audioOnly:_b(res.audioOnlyTranscode),
        stereoDownmix:_b(res.audioOutputStereoDownmix),
        srcCh:_n(res.audioOutputSourceChannels,0),
        srcV:_s(res.sourceVideoCodec||"-"),
        policyTC:_b(res.policyTranscode),
        policyHls:_b(res.policyTranscodeUseHls),
        final:_s(res.finalUrlKind||"-")
    }
}
function logResult(scope,event,res,extra) {
    var f=resultFields(res)
    if(extra) for(var k in extra){try{if(Object.prototype.hasOwnProperty.call(extra,k))f[k]=extra[k]}catch(e){}}
    log(scope,event,f)
    if(res&&res.url) logUrl(scope,event+".url",res.url)
}

function playerFields(root, mp) {
    root=root||{}; mp=mp||{}
    var ui=0
    try { ui=typeof root.uiPositionMs === "function" ? root.uiPositionMs() : 0 } catch(e) {}
    return {
        ui:Math.floor(_n(ui,0)),
        pos:Math.floor(_n(mp.position,0)),
        dur:Math.floor(_n(mp.duration,0)),
        state:_n(mp.playbackState,-1),
        status:_n(mp.status,-1),
        seekable:mp.seekable===true?1:0,
        isHls:_b(root.isHls),
        tc:_b(root.lastUsedTranscoding),
        ds:_b(root.lastUsedDirectStream),
        remux:_b(root.lastUsedServerRemux),
        serverTimed:_b(root.serverTimedStream),
        shifted:_b(root.timeShifted),
        base:Math.floor(_n(root.baseOffsetMs,0)),
        pending:Math.floor(_n(root._pendingSeekMs,-1)),
        lastTarget:Math.floor(_n(root.lastUiTargetMs,0)),
        srcReset:_b(root._sourceResetActive),
        srcPhase:_n(root._sourceResetPhase,0),
        seekPhase:_n(root._seekRestorePhase,0),
        seekAttempts:_n(root._seekRestoreAttempts,0),
        seekAwait:_b(root._seekRestoreAwaitingResult),
        stereo:_s(root.audioOutputMode).toLowerCase()==="stereo"?1:0
    }
}
function logPlayer(scope,event,root,mp,extra){
    var f=playerFields(root,mp)
    if(extra) for(var k in extra){try{if(Object.prototype.hasOwnProperty.call(extra,k))f[k]=extra[k]}catch(e){}}
    log(scope,event,f)
}
