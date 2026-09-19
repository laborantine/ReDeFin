.pragma library
.import "JellyfinPlaybackCore.js" as Core

/* JellyfinPlaybackDevialet.js
 * Policy Devialet importée statiquement. Aucun inclusion dynamique réseau, donc aucune
 * capture prématurée de negotiatePlayback/fetchStreams pendant le chargement.
 */

var DEVIALET_POLICY_ID = "devialet"
var DEVIALET_POLICY_REVISION = 8

// Devialet : AV1 doit sortir en H.264. Le chemin AV1 -> HEVC/H.265 est moins fiable
// avec QtMultimedia/Freebox et peut provoquer Loading/Stalled selon les médias.
var DEVIALET_TRANSCODE_VIDEO_CODEC = "h264"
var DEVIALET_TRANSCODE_CONTAINER_HLS = "ts"
var DEVIALET_TRANSCODE_CONTAINER_HTTP = "mkv"

// Plafond maximal annoncé à Jellyfin. Il ne force pas un encodage à 200 Mb/s :
// Jellyfin calcule le bitrate réellement nécessaire pour la source, dans cette limite.
var DEVIALET_MAX_STREAMING_BITRATE = 200000000
var DEVIALET_MAX_STATIC_BITRATE = 200000000

function _num(v) {
    v = Number(v)
    return isNaN(v) ? 0 : v
}

function _codec(v) {
    return String(v || "").toLowerCase()
}

function _selectedAudioCodecSafe(src, audioIndex) {
    var c = Core._selectedAudioCodec(src, audioIndex)
    if (c && String(c).length) return _codec(c)
    var a = Core._firstStream(src, "Audio")
    return _codec(a && a.Codec)
}

function _ctxMediaSource(ctx) {
    if (!ctx) return null

    try {
        if (ctx.mediaSource && ctx.mediaSource.MediaStreams) return ctx.mediaSource
        if (ctx.mediaSourceInfo && ctx.mediaSourceInfo.MediaStreams) return ctx.mediaSourceInfo
        if (ctx.source && ctx.source.MediaStreams) return ctx.source
        if (ctx.src && ctx.src.MediaStreams) return ctx.src
        if (ctx.MediaSource && ctx.MediaSource.MediaStreams) return ctx.MediaSource
        if (ctx.media && ctx.media.MediaStreams) return ctx.media
        if (ctx.playbackSource && ctx.playbackSource.MediaStreams) return ctx.playbackSource

        if (ctx.MediaSources && ctx.MediaSources.length && ctx.MediaSources[0].MediaStreams)
            return ctx.MediaSources[0]
        if (ctx.mediaSources && ctx.mediaSources.length && ctx.mediaSources[0].MediaStreams)
            return ctx.mediaSources[0]
        if (ctx.playbackInfo && ctx.playbackInfo.MediaSources && ctx.playbackInfo.MediaSources.length && ctx.playbackInfo.MediaSources[0].MediaStreams)
            return ctx.playbackInfo.MediaSources[0]
    } catch (e) {}

    return null
}

function _isUnsupportedVideoCodec(c) {
    c = _codec(c)
    return c === "av1" ||
           c === "vvc" ||
           c === "h266" ||
           c === "theora" ||
           c === "dirac" ||
           c === "rv40" ||
           c === "rv30"
}

function _isOddVideoCodec(c) {
    return _isUnsupportedVideoCodec(c)
}

function _isOddAudioCodec(c) {
    c = _codec(c)
    return c === "tta" ||
           c === "ape" ||
           c === "wavpack" ||
           c === "alac" ||
           c === "pcm_s16le" ||
           c === "pcm_s24le" ||
           c === "pcm_s32le" ||
           c === "pcm_f32le" ||
           c === "pcm_f64le"
}

function _isHlsAudioCopySafe(c) {
    c = _codec(c)
    return c === "aac" ||
           c === "ac3" ||
           c === "eac3" ||
           c === "mp3" ||
           c === "mp2"
}

function _videoNeedsRealTranscode(src) {
    if (!src) return false

    var v = Core._firstStream(src, "Video")
    var videoCodec = _codec(v && v.Codec)
    var width      = _num(v && v.Width)
    var height     = _num(v && v.Height)
    var bitDepth   = _num(v && v.BitDepth)

    // AV1 et autres codecs vidéo non supportés : vrai transcodage vidéo obligatoire.
    // Un remux ne suffit pas, car la Freebox recevrait toujours un flux vidéo impossible à décoder.
    if (_isOddVideoCodec(videoCodec)) return true

    // Cas suspects extrêmes : transcodage plutôt que DirectPlay aventureux.
    if (bitDepth > 10) return true
    if (width > 4096 || height > 2160) return true

    return false
}

function _devialetProfile(mode) {
    // IMPORTANT : pas d'AV1 ici. Si AV1 est annoncé comme compatible,
    // Jellyfin peut tenter un DirectPlay/DirectStream impossible côté Freebox.
    var videoCommon = "h264,hevc"
    var videoLegacy = "mpeg4,msmpeg4v3,mpeg2video"
    var videoWebm   = "vp8,vp9"
    var videoAll    = videoCommon + "," + videoLegacy + "," + videoWebm

    var audioCommon = "aac,ac3,eac3,mp3,mp2"
    var audioMore   = "dts,dca,opus,vorbis,flac,truehd"
    var audioAll    = audioCommon + "," + audioMore

    // HLS TS : on limite aux codecs audio plus sûrs pour éviter les masters/segments
    // bizarres avec audio copy impossible dans le conteneur.
    var audioHlsSafe = audioCommon

    var dp = {
        Name: "Freebox-Devialet",
        MaxStreamingBitrate: DEVIALET_MAX_STREAMING_BITRATE,
        MaxStaticBitrate: DEVIALET_MAX_STATIC_BITRATE,
        MaxAudioChannels: 8,

        DirectPlayProfiles: [
            { Container: "mkv",              Type: "Video", VideoCodec: videoAll, AudioCodec: audioAll },
            { Container: "mp4,m4v,mov",      Type: "Video", VideoCodec: "h264,hevc,mpeg4", AudioCodec: "aac,ac3,eac3,mp3" },
            { Container: "avi",              Type: "Video", VideoCodec: "mpeg4,msmpeg4v3,h264,mpeg2video", AudioCodec: "mp3,mp2,aac,ac3,eac3,dts,dca" },
            { Container: "ts,m2ts,mpg,mpeg", Type: "Video", VideoCodec: "h264,hevc,mpeg2video", AudioCodec: "aac,ac3,eac3,mp3,mp2,dts,dca" },
            { Container: "webm",             Type: "Video", VideoCodec: "vp8,vp9", AudioCodec: "vorbis,opus" }
        ],

        DirectStreamProfiles: [
            { Container: "mkv",  Type: "Video", VideoCodec: videoAll, AudioCodec: audioAll },
            { Container: "ts",   Type: "Video", VideoCodec: "h264,hevc,mpeg2video", AudioCodec: audioAll },
            { Container: "mp4",  Type: "Video", VideoCodec: "h264,hevc,mpeg4", AudioCodec: "aac,ac3,eac3,mp3" },
            { Container: "avi",  Type: "Video", VideoCodec: "mpeg4,mpeg2video,h264", AudioCodec: "mp3,mp2,aac,ac3,eac3,dts,dca" },
            { Container: "webm", Type: "Video", VideoCodec: "vp8,vp9", AudioCodec: "vorbis,opus" }
        ],

        TranscodingProfiles: [],

        SubtitleProfiles: [
            // Overlay/local text
            { Format: "srt",    Method: "External" },
            { Format: "subrip", Method: "External" },
            { Format: "vtt",    Method: "External" },
            { Format: "webvtt", Method: "External" },

            // Embed text (remux / directstream)
            { Format: "srt",      Method: "Embed" },
            { Format: "subrip",   Method: "Embed" },
            { Format: "ass",      Method: "Embed" },
            { Format: "ssa",      Method: "Embed" },
            { Format: "vtt",      Method: "Embed" },
            { Format: "webvtt",   Method: "Embed" },
            { Format: "mov_text", Method: "Embed" },
            { Format: "tx3g",     Method: "Embed" },

            // Embed image subtitles (remux / directstream)
            { Format: "pgssub", Method: "Embed" },
            { Format: "dvdsub", Method: "Embed" },
            { Format: "vobsub", Method: "Embed" }
        ]
    }

    if (mode === "hls" || mode === "auto") {
        // AV1 et codecs vidéo impossibles : HLS/TS H.264, pas HEVC.
        dp.TranscodingProfiles = [
            { Container: DEVIALET_TRANSCODE_CONTAINER_HLS, Type: "Video", Protocol: "hls", VideoCodec: DEVIALET_TRANSCODE_VIDEO_CODEC, AudioCodec: audioHlsSafe }
        ]
    } else {
        // Fallback HTTP pour les cas hors HLS.
        dp.TranscodingProfiles = [
            { Container: DEVIALET_TRANSCODE_CONTAINER_HTTP, Type: "Video", Protocol: "http", VideoCodec: DEVIALET_TRANSCODE_VIDEO_CODEC, AudioCodec: audioAll }
        ]
    }

    return dp
}

function _devialetPreferredContainer(ctx, src) {
    if (!ctx) return null

    var needServerSelect =
        (typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0) ||
        (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ||
        (ctx.forceDPOnAudioSwitch === true)

    if (!needServerSelect) return null

    try {
        var path = (src && src.Path) ? src.Path : ""
        var ext  = Core._extFrom(path)
        var v    = Core._firstStream(src, "Video")
        var vCdc = v ? String(v.Codec || "").toLowerCase() : ""

        if (ext === "webm" || vCdc === "vp8" || vCdc === "vp9")
            return "webm"
    } catch (e) {}

    return "mkv"
}

function _devialetForceTranscode(ctx, src) {
    if (!src) return false

    // Ne force plus un vrai transcodage vidéo uniquement parce que l'audio est exotique.
    // Si le DeviceProfile refuse l'audio en DirectPlay, Jellyfin/Core peut remuxer ou
    // transcoder l'audio sans envoyer inutilement la vidéo au transcodeur.
    return _videoNeedsRealTranscode(src)
}

function _needsStrictPlaybackInfo(ctx) {
    var src = _ctxMediaSource(ctx)

    // Le Core peut ne pas encore avoir injecté la MediaSource au moment du clone ctx.
    // Dans ce cas, on garde le comportement strict historique pour éviter que Jellyfin
    // prépare une session AV1 en copy vidéo avant l'analyse complète.
    if (!src) return true

    return _videoNeedsRealTranscode(src)
}

function _cloneCtxForDevialet(ctx) {
    var out = {}
    ctx = ctx || {}
    for (var k in ctx) {
        try {
            if (Object.prototype.hasOwnProperty.call(ctx, k))
                out[k] = ctx[k]
        } catch (e) {
            out[k] = ctx[k]
        }
    }

    var strictVideoTranscode = _needsStrictPlaybackInfo(out)

    // Nécessaire avec JellyfinPlaybackCore actuel : sans ce flag, forceTranscodeByPolicy
    // peut empêcher le DirectPlay sans pour autant prendre le TranscodingUrl Jellyfin,
    // ce qui risque de retomber sur un remux copy inutile pour AV1.
    if (out.forceAllowTranscoding !== false)
        out.forceAllowTranscoding = true

    if (strictVideoTranscode) {
        // PlaybackInfo strict seulement pour les vidéos qui doivent réellement sortir
        // du serveur en transcodage vidéo. Le fallback source inconnue reste strict.
        if (out.forceVideoStreamCopyInPlaybackInfo !== true)
            out.forceVideoStreamCopyInPlaybackInfo = false
        if (out.forceDirectStreamInPlaybackInfo !== true)
            out.forceDirectStreamInPlaybackInfo = false

        out.forceHlsProfileInPlaybackInfo = true
        out.forcePlaybackInfoColdStart = true
        out.forcePlaybackInfoVideoCodec = DEVIALET_TRANSCODE_VIDEO_CODEC
        out.forcePlaybackInfoAudioCodec = ""
    }

    out.forcePlaybackInfoMaxStreamingBitrate = DEVIALET_MAX_STREAMING_BITRATE

    return out
}

function _devialetPreferredTranscodeProtocol(ctx, src) {
    var v = Core._firstStream(src, "Video")
    var vc = _codec(v && v.Codec)

    // AV1 : HLS reste le chemin le plus cadré pour éviter le copy vidéo.
    if (vc === "av1") return "hls"

    // Autres codecs vidéo impossibles/suspects : HTTP/MKV H.264, moins bavard que HLS.
    return "http"
}

function _devialetPreferredTranscodeVideoCodec(ctx, src) {
    return DEVIALET_TRANSCODE_VIDEO_CODEC
}
function _devialetPreferredTranscodeDimensions(ctx, src) {
    var v = Core._firstStream(src, "Video")
    var w = _num(v && v.Width)
    var h = _num(v && v.Height)
    if (w <= 0) w = 1920
    if (h <= 0) h = 1080
    // Ne jamais suréchantillonner et borner les sources 5K/8K à l'enveloppe UHD
    // réellement utile au Player Devialet. Le ratio est conservé et les dimensions
    // restent paires pour ffmpeg/Jellyfin.
    var scale = Math.min(1, 3840 / w, 2160 / h)
    w = Math.max(2, Math.floor((w * scale) / 2) * 2)
    h = Math.max(2, Math.floor((h * scale) / 2) * 2)
    return { width: w, height: h }
}

function _devialetPreferredTranscodeAudioCodec(ctx, src, audioIndex, useHls) {
    var ac = _selectedAudioCodecSafe(src, audioIndex)

    // HLS TS : si l'audio source est exotique ou peu sûr en copy, on demande AAC.
    // Cela évite des master.m3u8/segments étranges ou des erreurs ffmpeg côté Jellyfin.
    if (useHls && !_isHlsAudioCopySafe(ac))
        return "aac"

    if (_isOddAudioCodec(ac))
        return "aac"

    return ac || "aac"
}

function _devialetAllowTranscodeAudioStreamCopy(ctx, src, audioIndex, useHls) {
    var ac = _selectedAudioCodecSafe(src, audioIndex)

    // Copy-first : E-AC3/DD+ 5.1 fait partie des codecs HLS/TS sûrs et doit
    // rester bit-perfect lorsque seule la vidéo (AV1 notamment) est transcodée.
    // Les codecs incompatibles sont réencodés par le Core au lieu d'être copiés.
    if (useHls && !_isHlsAudioCopySafe(ac)) return false
    if (_isOddAudioCodec(ac)) return false

    return true
}

function _policyObject() {
    return {
        policyId: DEVIALET_POLICY_ID,
        policyRevision: DEVIALET_POLICY_REVISION,
        getPolicyId: function(){ return DEVIALET_POLICY_ID },
        getPolicyRevision: function(){ return DEVIALET_POLICY_REVISION },
        buildDeviceProfile: _devialetProfile,
        decidePreferredContainer: _devialetPreferredContainer,
        shouldForceTranscode: _devialetForceTranscode,
        // Incompatibilites VIDEO materielles qui restent prioritaires meme
        // lorsque SettingsSidePanel est regle sur Original.
        requiresHardVideoTranscode: _videoNeedsRealTranscode,
        preferredTranscodeProtocol: _devialetPreferredTranscodeProtocol,
        preferredTranscodeVideoCodec: _devialetPreferredTranscodeVideoCodec,
        preferredTranscodeDimensions: _devialetPreferredTranscodeDimensions,
        preferredTranscodeAudioCodec: _devialetPreferredTranscodeAudioCodec,
        allowTranscodeAudioStreamCopy: _devialetAllowTranscodeAudioStreamCopy
    }
}
function _ensurePolicy() {
    if (!Core || typeof Core.setDevicePolicy !== "function") {  return false }
    Core.setDevicePolicy(_policyObject())

    return true
}
function setFbx(v) { if (!_ensurePolicy()) return; return Core.setFbx(v) }
function negotiatePlayback(ctx, onSuccess, onError) {
    if (!_ensurePolicy() || typeof Core.negotiatePlayback !== "function") { if (onError) onError("core_missing"); return }
    var cloned = _cloneCtxForDevialet(ctx)

    return Core.negotiatePlayback(cloned, function(res){

        if (onSuccess) onSuccess(res)
    }, function(err){

        if (onError) onError(err)
    })
}
