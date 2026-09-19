.pragma library
.import "JellyfinPlaybackCore.js" as Core

/* JellyfinPlaybackRevolution.js
 * Wrapper statique Freebox Revolution.
 * Le Core est importé par namespace, jamais avec inclusion dynamique, afin que les
 * fonctions soient disponibles avant la première négociation HTTP/QML.
 */

var REVOLUTION_POLICY_ID = "revolution";
var REVOLUTION_POLICY_REVISION = 10;

// Sorties serveur privilégiées sur Révolution : le progressif HTTP reste utilisé
// pour préserver StartTimeTicks/seek, mais le conteneur passe en MKV afin de
// supporter proprement l'Embed des sous-titres texte et d'éviter le chemin MP4
// problématique observé sur certains transcodages HEVC 4K. AV1 conserve HLS/TS.
var REVOLUTION_TRANSCODE_VIDEO_CODEC = "h264";
var REVOLUTION_TRANSCODE_CONTAINER_HTTP = "mkv";
var REVOLUTION_TRANSCODE_CONTAINER_HLS = "ts";

/* ================== Helpers ================== */
function _num(v) {
    v = Number(v);
    return isNaN(v) ? 0 : v;
}

function _codec(v) {
    return String(v || "").toLowerCase();
}

function _selectedAudioCodecSafe(src, audioIndex) {
    var coreCodec = Core._selectedAudioCodec(src, audioIndex);
    if (coreCodec) return _codec(coreCodec);
    var first = Core._firstStream(src, "Audio");
    return _codec(first && first.Codec);
}

function _revAudioCopySafe(codec) {
    var c = _codec(codec);
    return c === "aac" || c === "ac3" || c === "mp3" || c === "mp2";
}

function _revVideoCopySafe(codec) {
    var c = _codec(codec);
    return c === "h264" || c === "mpeg4" || c === "mpeg2video" || c === "msmpeg4v3";
}

function _subtitleStreamByIndexSafe(src, streamIndex) {
    if (!src || !src.MediaStreams || typeof streamIndex !== "number" || streamIndex < 0)
        return null;

    try {
        var coreStream = Core._subtitleStreamByIndex(src, streamIndex);
        if (coreStream) return coreStream;
    } catch (e) {}

    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i];
        if (!st) continue;
        var type = String(st.Type || "").toLowerCase();
        if (type !== "subtitle" && Number(st.Type) !== 2) continue;
        var idx = (typeof st.Index === "number") ? st.Index : i;
        if (idx === streamIndex) return st;
    }
    return null;
}

function _audioStreamByIndexSafe(src, streamIndex) {
    if (!src || !src.MediaStreams) return null;

    if (typeof streamIndex === "number" && streamIndex >= 0) {
        try {
            var coreStream = Core._audioStreamByIndex(src, streamIndex);
            if (coreStream) return coreStream;
        } catch (e) {}
    }

    return Core._firstStream(src, "Audio");
}

function _isPgsSubtitleStream(st) {
    if (!st) return false;
    var c = _codec(st.Codec);
    return c === "pgssub" || c === "pgs" ||
           c === "hdmv_pgs_subtitle" || c === "s_hdmv/pgs";
}

function _selectedPgsSubtitle(ctx, src) {
    if (!ctx || ctx.useLocalSubs === true) return null;
    if (typeof ctx.selectedSubtitleStream !== "number" || ctx.selectedSubtitleStream < 0)
        return null;

    var st = _subtitleStreamByIndexSafe(src, ctx.selectedSubtitleStream);
    return _isPgsSubtitleStream(st) ? st : null;
}

function _revPgsRemuxEligible(ctx, src) {
    if (!_selectedPgsSubtitle(ctx, src)) return false;
    if (_revRequiresHardVideoTranscode(ctx, src)) return false;

    var v = Core._firstStream(src, "Video");
    if (!_revVideoCopySafe(v && v.Codec)) return false;

    var selectedAudioIndex = (ctx && typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0)
                           ? ctx.selectedAudioStream : -1;
    var a = _audioStreamByIndexSafe(src, selectedAudioIndex);
    var audioCodec = _codec(a && a.Codec);
    var channels = _num(a && a.Channels);

    if (!_revAudioCopySafe(audioCodec)) return false;
    if (channels > 6) return false;

    return true;
}

function _revPgsNeedsEncode(ctx, src, st) {
    if (!_isPgsSubtitleStream(st)) return false;

    // Un vrai transcodage vidéo demandé explicitement doit toujours incruster le
    // PGS. Cela couvre aussi le choix manuel d'un débit de transcodage.
    if (ctx && Number(ctx.forcePolicyTranscodeVideoBitrate || 0) > 0) return true;
    if (ctx && ctx.forceTranscodeOnTrackSwitch === true) return true;
    if (ctx && ctx.forceAllowTranscoding === true && ctx.forceVideoTranscodeCodec) return true;

    // Le DirectPlay manuel reste volontairement souverain. Le changement vers un
    // PGS quitte normalement ce mode avant la négociation, mais cette garde évite
    // de transformer silencieusement un choix explicite en transcodage.
    if (ctx && ctx.manualDirectPlayOverride === true) return false;

    // En mode global Original et en Remux manuel, seules les incompatibilités
    // vidéo matérielles doivent gagner. Les heuristiques audio/conteneur restent
    // neutralisées comme dans le Core.
    var ruleMode = String(ctx && ctx.playbackRuleMode || "").toLowerCase().trim();
    if (ruleMode === "directplay" || (ctx && ctx.manualRemuxOverride === true))
        return _revRequiresHardVideoTranscode(ctx, src);

    // En Automatique, si le PGS ne peut pas suivre la voie Remux sûre (vidéo et
    // audio copiables), la policy conserve le transcodage et demande le burn-in.
    return !_revPgsRemuxEligible(ctx, src);
}

function _containerOf(src) {
    var c = _codec(src && src.Container);
    if (c) return c;

    // SÉCURITÉ PUBLICATION :
    // src.Path peut contenir un chemin média serveur ou un nom de fichier sensible.
    // On l'utilise uniquement en lecture locale pour déduire l'extension.
    // Ne jamais logger src, src.Path ou un ctx playback complet en brut.
    return Core._extFrom(src && src.Path);
}

function _isRiskyVideoCodec(c) {
    c = _codec(c);
    return (
        c === "hevc"   ||
        c === "h265"   ||
        c === "vp9"    ||
        c === "av1"    ||
        c === "vp8"    ||
        c === "vc1"    ||
        c === "wmv3"   ||
        c === "theora" ||
        c === "dirac"  ||
        c === "rv30"   ||
        c === "rv40"
    );
}

function _isRiskyAudioCodec(c) {
    c = _codec(c);
    return (
        c === "dts"       ||
        c === "dca"       ||
        c === "truehd"    ||
        c === "eac3"      ||
        c === "flac"      ||
        c === "opus"      ||
        c === "vorbis"    ||
        c === "alac"      ||
        c === "ape"       ||
        c === "wavpack"   ||
        c === "tta"       ||
        c === "pcm_s24le" ||
        c === "pcm_s32le" ||
        c === "pcm_f32le" ||
        c === "pcm_f64le"
    );
}

/* ================== DeviceProfile Revolution ================== */
function _revProfile(mode) {
    var dp = {
        Name: "Freebox-Revolution",
        MaxStreamingBitrate: 200000000,
        MaxStaticBitrate: 200000000,
        MaxAudioChannels: 6,

        DirectPlayProfiles: [
            { Container: "mp4,m4v,mov",      Type: "Video", VideoCodec: "h264,mpeg4",            AudioCodec: "aac,ac3,mp3,mp2" },
            { Container: "ts,m2ts,mpg,mpeg", Type: "Video", VideoCodec: "h264,mpeg2video",       AudioCodec: "aac,ac3,mp3,mp2" },
            { Container: "avi",              Type: "Video", VideoCodec: "mpeg4,msmpeg4v3,h264",  AudioCodec: "mp3,mp2,aac,ac3" }
        ],

        DirectStreamProfiles: [
            // MKV est le conteneur de remux/progressif privilégié côté serveur.
            // On ne l'ajoute pas au DirectPlay ici afin de ne pas élargir les
            // chemins statiques historiques de la Révolution.
            { Container: "mkv", Type: "Video", VideoCodec: "h264,mpeg4,mpeg2video,msmpeg4v3", AudioCodec: "aac,ac3,mp3,mp2" },
            { Container: "mp4", Type: "Video", VideoCodec: "h264,mpeg4",       AudioCodec: "aac,ac3,mp3,mp2" },
            { Container: "ts",  Type: "Video", VideoCodec: "h264,mpeg2video",  AudioCodec: "aac,ac3,mp3,mp2" }
        ],

        TranscodingProfiles: [],

        // Contraintes matérielles du CE4100 communiquées directement à Jellyfin.
        // Elles s'appliquent au PlaybackInfo lui-même et empêchent qu'une
        // TranscodingUrl pré-calculée conserve une sortie H.264 UHD/10 bits.
        CodecProfiles: [
            {
                Type: "Video",
                Codec: "h264",
                Conditions: [
                    { Condition: "LessThanEqual", Property: "Width",         Value: "1920", IsRequired: false },
                    { Condition: "LessThanEqual", Property: "Height",        Value: "1080", IsRequired: false },
                    { Condition: "LessThanEqual", Property: "VideoBitDepth",  Value: "8",    IsRequired: false },
                    { Condition: "LessThanEqual", Property: "VideoFramerate", Value: "60",   IsRequired: false },
                    { Condition: "LessThanEqual", Property: "VideoLevel",     Value: "41",   IsRequired: false }
                ],
                ApplyConditions: []
            },
            {
                Type: "VideoAudio",
                Conditions: [
                    { Condition: "LessThanEqual", Property: "AudioChannels", Value: "6", IsRequired: false }
                ],
                ApplyConditions: []
            }
        ],

        SubtitleProfiles: [
            // Overlay local en DirectPlay pur.
            { Format: "srt", Method: "External" },
            { Format: "subrip", Method: "External" },
            { Format: "vtt", Method: "External" },
            { Format: "webvtt", Method: "External" },

            // Flux serveur (remux/transcodage progressif) : le Core demande
            // volontairement Embed pour éviter une sidecar locale hors DirectPlay.
            // MKV est choisi précisément pour rendre ce contrat cohérent.
            { Format: "srt", Method: "Embed" },
            { Format: "subrip", Method: "Embed" },
            { Format: "vtt", Method: "Embed" },
            { Format: "webvtt", Method: "Embed" },

            // PGS sélectionné : la Révolution reçoit la piste bitmap dans un
            // remux lorsque vidéo/audio sont déjà compatibles. Si un vrai
            // transcodage est nécessaire, shouldForceSubtitleEncode() bascule
            // automatiquement vers Encode/burn-in.
            { Format: "pgssub", Method: "Embed" },
            { Format: "pgs", Method: "Embed" }
        ]
    };

    // En négociation initiale (auto), annoncer HLS/TS volontairement.
    // Après réception des MediaSources, une incompatibilité vidéo Révolution
    // choisit HTTP/MKV via preferredTranscodeProtocol(). Le mismatch HLS/HTTP
    // empêche alors le Core de conserver aveuglément la TranscodingUrl initiale
    // et le force à reconstruire l'URL finale avec MaxWidth/MaxHeight 1080p.
    if (mode === "hls" || mode === "auto") {
        dp.TranscodingProfiles = [
            { Container: REVOLUTION_TRANSCODE_CONTAINER_HLS, Type: "Video", Protocol: "hls", VideoCodec: REVOLUTION_TRANSCODE_VIDEO_CODEC, AudioCodec: "ac3,aac" }
        ];
    } else {
        dp.TranscodingProfiles = [
            { Container: REVOLUTION_TRANSCODE_CONTAINER_HTTP, Type: "Video", Protocol: "http", VideoCodec: REVOLUTION_TRANSCODE_VIDEO_CODEC, AudioCodec: "ac3,aac" }
        ];
    }

    return dp;
}

/* ================== Container préféré ================== */
function _revPreferredContainer(ctx, src) {
    if (!ctx) return null;

    var needServerSelect =
        (typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0) ||
        (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ||
        (ctx.forceDPOnAudioSwitch === true);

    if (!needServerSelect) return null;

    var v = Core._firstStream(src, "Video");
    var ext = _containerOf(src);
    var videoCodec = _codec(v && v.Codec);

    // PGS + vidéo/audio déjà compatibles : privilégier un vrai conteneur de
    // remux bitmap. Les sources Blu-ray/TS restent en TS ; les autres passent en
    // MKV afin d'éviter une tentative d'Embed PGS dans un MP4.
    if (_revPgsRemuxEligible(ctx, src)) {
        if (ext === "ts" || ext === "m2ts" || ext === "mpg" || ext === "mpeg" || videoCodec === "mpeg2video")
            return "ts";
        return "mkv";
    }

    if (ext === "ts" || ext === "m2ts" || ext === "mpg" || ext === "mpeg" || videoCodec === "mpeg2video")
        return "ts";

    // Pour tout remux/progressif serveur non-TS, utiliser MKV. Cela aligne la
    // Révolution sur le chemin progressif fiable de la Devialet sans modifier
    // la policy Devialet elle-même.
    return REVOLUTION_TRANSCODE_CONTAINER_HTTP;
}

function _revPreferredTranscodeProtocol(ctx, src) {
    var v = Core._firstStream(src, "Video");
    var vc = _codec(v && v.Codec);

    // Conserver le traitement AV1 historique en HLS/TS. Pour HEVC 4K et les
    // autres incompatibilités vidéo, préférer HTTP/MKV afin de garder le seek
    // serveur progressif et StartTimeTicks.
    if (vc === "av1" || vc === "aom" || vc === "av01")
        return "hls";

    return "http";
}

function _revPreferredTranscodeVideoCodec(ctx, src) {
    return REVOLUTION_TRANSCODE_VIDEO_CODEC;
}

function _revPreferredTranscodeAudioCodec(ctx, src, audioIndex, useHls) {
    var sourceCodec = _selectedAudioCodecSafe(src, audioIndex);

    // AC3/AAC/MP3/MP2 déjà compatibles : conserver le flux en stream-copy.
    if (_revAudioCopySafe(sourceCodec))
        return sourceCodec;

    // E-AC3/DD+, DTS, TrueHD et autres codecs non sûrs pour la Révolution :
    // conversion AC3. Le Core conserve jusqu'à 6 canaux et demande 640 kb/s en 5.1.
    return "ac3";
}

function _revAllowTranscodeAudioStreamCopy(ctx, src, audioIndex, useHls) {
    var sourceCodec = _selectedAudioCodecSafe(src, audioIndex);
    if (!_revAudioCopySafe(sourceCodec)) return false;

    var a = Core._audioStreamByIndex(src, audioIndex);
    if (!a) a = Core._firstStream(src, "Audio");
    return _num(a && a.Channels) <= 6;
}

function _revPreferredTranscodeDimensions(ctx, src) {
    var v = Core._firstStream(src, "Video");
    var w = _num(v && v.Width);
    var h = _num(v && v.Height);
    if (w <= 0) w = 1920;
    if (h <= 0) h = 1080;

    // Ne jamais suréchantillonner une source déjà <= 1080p. Pour une source 4K+
    // on réduit proportionnellement afin de rester dans l'enveloppe 1920x1080.
    var scale = Math.min(1, 1920 / w, 1080 / h);
    w = Math.max(2, Math.floor((w * scale) / 2) * 2);
    h = Math.max(2, Math.floor((h * scale) / 2) * 2);
    return { width: w, height: h };
}

/* ================== Force transcode ? ================== */
function _revRequiresHardVideoTranscode(ctx, src) {
    if (!src) return false;
    var v = Core._firstStream(src, "Video");
    var width     = _num(v && v.Width);
    var height    = _num(v && v.Height);
    var bitDepth  = _num(v && v.BitDepth);
    var frameRate = _num(v && (v.RealFrameRate || v.AverageFrameRate || v.FrameRate));
    var videoCodec = _codec(v && v.Codec);

    // Capacites video du CE4100. Les contraintes audio/conteneur restent dans
    // _revForceTranscode(), donc Original peut ignorer ces heuristiques sans
    // tenter de decoder une video reellement hors capacites.
    if (width > 1920 || height > 1080) return true;
    if (bitDepth > 8) return true;
    if (frameRate > 60) return true;
    if (_isRiskyVideoCodec(videoCodec)) return true;
    return false;
}

function _revForceTranscode(ctx, src) {
    if (!src) return false;

    var v = Core._firstStream(src, "Video");
    var selectedPgs = _selectedPgsSubtitle(ctx, src);
    var selectedAudioIndex = (selectedPgs && ctx && typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0)
                           ? ctx.selectedAudioStream : -1;
    var a = selectedPgs ? _audioStreamByIndexSafe(src, selectedAudioIndex)
                        : Core._firstStream(src, "Audio");

    var width     = _num(v && v.Width);
    var height    = _num(v && v.Height);
    var bitDepth  = _num(v && v.BitDepth);
    var frameRate = _num(v && (v.RealFrameRate || v.AverageFrameRate || v.FrameRate));
    var channels  = _num(a && a.Channels);

    var videoCodec = _codec(v && v.Codec);
    var audioCodec = _codec(a && a.Codec);
    var container  = _containerOf(src);

    if (width > 1920 || height > 1080) return true;
    if (bitDepth > 8) return true;
    if (frameRate > 60) return true;

    if (_isRiskyVideoCodec(videoCodec)) return true;
    if (_isRiskyAudioCodec(audioCodec)) return true;

    if (channels > 6) return true;

    // Cas PGS Révolution : un MKV n'est plus, à lui seul, une raison de
    // réencoder la vidéo. Si les codecs réellement choisis sont copiables, on
    // laisse le Core construire un remux + SubtitleMethod=Embed.
    if (_revPgsRemuxEligible(ctx, src)) return false;

    // MKV n'est plus une raison de réencoder la vidéo : c'est désormais le
    // conteneur serveur privilégié pour le remux/progressif Révolution. Les
    // conteneurs réellement non sûrs conservent le transcodage de policy.
    if (container === "webm" || container === "flv" || container === "ogv")
        return true;

    return false;
}

function _policyObject() {
    return {
        policyId: REVOLUTION_POLICY_ID,
        policyRevision: REVOLUTION_POLICY_REVISION,
        getPolicyId: function(){ return REVOLUTION_POLICY_ID },
        getPolicyRevision: function(){ return REVOLUTION_POLICY_REVISION },
        buildDeviceProfile: _revProfile,
        decidePreferredContainer: _revPreferredContainer,
        shouldForceTranscode: _revForceTranscode,
        shouldForceSubtitleEncode: _revPgsNeedsEncode,
        requiresHardVideoTranscode: _revRequiresHardVideoTranscode,
        preferredTranscodeProtocol: _revPreferredTranscodeProtocol,
        preferredTranscodeVideoCodec: _revPreferredTranscodeVideoCodec,
        preferredTranscodeDimensions: _revPreferredTranscodeDimensions,
        preferredTranscodeAudioCodec: _revPreferredTranscodeAudioCodec,
        allowTranscodeAudioStreamCopy: _revAllowTranscodeAudioStreamCopy
    }
}
function _ensurePolicy() {
    if (!Core || typeof Core.setDevicePolicy !== "function") {
        return false
    }
    Core.setDevicePolicy(_policyObject())
    return true
}
function setFbx(fbxCtx) { if (!_ensurePolicy()) return; return Core.setFbx(fbxCtx) }
function _cloneCtxForRevolution(ctx) {
    var out = {};
    ctx = ctx || {};

    for (var k in ctx) {
        try {
            if (Object.prototype.hasOwnProperty.call(ctx, k))
                out[k] = ctx[k];
        } catch (e) {
            out[k] = ctx[k];
        }
    }

    // Quand la vidéo dépasse réellement les capacités CE4100, demander à
    // PlaybackInfo une vraie sortie H.264 sans video-copy. Ainsi, si le Core
    // conserve ensuite la TranscodingUrl Jellyfin, celle-ci a déjà été calculée
    // avec la policy Révolution (MKV/H.264 + CodecProfiles 1080p/8 bits).
    var src = null;
    try {
        if (out.mediaSource && out.mediaSource.MediaStreams) src = out.mediaSource;
        else if (out.mediaSourceInfo && out.mediaSourceInfo.MediaStreams) src = out.mediaSourceInfo;
        else if (out.source && out.source.MediaStreams) src = out.source;
        else if (out.src && out.src.MediaStreams) src = out.src;
        else if (out.MediaSource && out.MediaSource.MediaStreams) src = out.MediaSource;
        else if (out.MediaSources && out.MediaSources.length) src = out.MediaSources[0];
        else if (out.mediaSources && out.mediaSources.length) src = out.mediaSources[0];
        else if (out.playbackInfo && out.playbackInfo.MediaSources && out.playbackInfo.MediaSources.length)
            src = out.playbackInfo.MediaSources[0];
    } catch (e0) { src = null; }

    if (src && _revRequiresHardVideoTranscode(out, src)) {
        out.forceAllowTranscoding = true;
        out.forceVideoStreamCopyInPlaybackInfo = false;
        out.forceDirectStreamInPlaybackInfo = false;
        out.forcePlaybackInfoVideoCodec = REVOLUTION_TRANSCODE_VIDEO_CODEC;

        var v = Core._firstStream(src, "Video");
        var vc = _codec(v && v.Codec);
        if (vc === "av1" || vc === "aom" || vc === "av01")
            out.forceHlsProfileInPlaybackInfo = true;
    }

    return out;
}

function negotiatePlayback(ctx, onSuccess, onError) {
    if (!_ensurePolicy() || typeof Core.negotiatePlayback !== "function") { if (onError) onError("core_missing"); return }
    return Core.negotiatePlayback(_cloneCtxForRevolution(ctx), onSuccess, onError)
}
