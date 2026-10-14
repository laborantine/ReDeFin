.pragma library
.import "JellyfinPlaybackCoreUrl.js" as CoreUrl
.import "JellyfinStreamRules.js" as StreamRules
.import "AudioOutputPolicy.js" as AudioOutput
.import "ForcedSubtitlePolicy.js" as ForcedSubs
// Négociation Jellyfin : construit PlaybackInfo puis résout le contrat de lecture.
// StreamRules possède les métadonnées/pistes ; CoreUrl construit et valide les URL.
// Les politiques matérielles sont injectées par les backends ; aucune UI/MediaPlayer.
// ReDeFin playback policy: VFF priority, dormant subtitle safety, VO + French full auto-remux, TrueHD 5.1 audio-only transcoding and global high-quality DVDSub transcoding.
// Text subtitles: local QML overlay is used for pure DirectPlay and for explicitly chosen MOV_TEXT/TX3G, including Remux/HLS. Other server-side subtitles follow Embed/Burn-in policy.
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

function normalizePlaybackRuleMode(value) {
    return StreamRules.normalizePlaybackRuleMode(value)
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
    var mode = StreamRules.normalizePlaybackRuleMode(ctx.playbackRuleMode)
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
function _sourceVideoCodec(src) { var v = StreamRules.firstStream(src, "Video"); return _s(v && v.Codec).toLowerCase().trim() }
function _sourceVideoBitrate(src) {
    var v = StreamRules.firstStream(src, "Video"), n = 0
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
function _policyRequiresAudioOnlyTranscode(ctx, src, audioIndex) {
    // Incompatibilite AUDIO SEULE declaree par la policy materielle : la video
    // reste copiee et seul le son est reencode. Les choix explicites de
    // l'utilisateur (DirectPlay manuel, mode global Original) restent
    // souverains, comme pour les autres regles de precaution.
    if (!ctx || !src) return false
    if (ctx.manualDirectPlayOverride === true) return false
    if (StreamRules.normalizePlaybackRuleMode(ctx.playbackRuleMode) === "directplay") return false
    var p = _policy()
    if (p && typeof p.requiresAudioOnlyTranscode === "function") {
        try { return !!p.requiresAudioOnlyTranscode(ctx, src, audioIndex) } catch(e) {}
    }
    return false
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
            wanted = StreamRules.selectedAudioCodec(src, audioIndex) || "aac"
        else
            wanted = StreamRules.selectedAudioCodec(src, audioIndex) || "ac3,eac3,aac,mp3"
    }
    // Sortie audio stéréo : le mixage serveur impose la cible AAC-LC 2.0
    // via AudioCodec=aac. Cette cible gagne aussi lorsque la policy matérielle
    // demanderait normalement AC-3 pour un codec source non sûr (DTS/TrueHD).
    var stereoPlan = _audioOutputPlan(ctx, src, audioIndex)
    if (stereoPlan.downmix === true) return stereoPlan.codec
    return _safeFullTranscodeAudioCodecHint(wanted, src, audioIndex)
}
function _policyTranscodeAllowAudioCopy(ctx, src, audioIndex, useHls) {
    if (_shouldStereoDownmixAudio(ctx, src, audioIndex)) return false
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
/* ===== Sortie audio (réglage Multicanal / Stéréo) ===== */
// Le réglage est lu à CHAQUE négociation : changer de piste audio d'une 5.1
// vers une stéréo réautorise la copie, et inversement.
function _audioOutputMode(ctx) {
    try { return AudioOutput.normalizeMode(ctx && ctx.audioOutputMode) } catch(e0) {}
    return AudioOutput.MODE_MULTICHANNEL
}
function _audioOutputPlan(ctx, src, audioIndex) {
    try {
        var stream = StreamRules.audioStreamByIndex(src, audioIndex)
        var plan = AudioOutput.plan(_audioOutputMode(ctx), stream)
        return plan
    } catch(e0) { }
    var fallback = { mode: AudioOutput.MODE_MULTICHANNEL, sourceChannels: 0, downmix: false,
                     channels: 0, codec: "", bitrate: 0, maxChannels: 0 }
    return fallback
}
function _shouldStereoDownmixAudio(ctx, src, audioIndex) {
    return _audioOutputPlan(ctx, src, audioIndex).downmix === true
}
// Abaisse au plafond du mode un nombre de canaux déjà calculé par un chemin
// de transcodage existant (TS entrelacé...), sans inventer de valeur.
function _capAudioChannelsForOutput(ctx, channels) {
    try { return AudioOutput.capChannels(_audioOutputMode(ctx), channels) } catch(e0) {}
    return channels
}
// Plafond de canaux à annoncer quand aucun plan audio n'en impose un : celui
// du profil de l'appareil actif (6 sur Révolution, 8 sur Devialet), abaissé
// par le mode stéréo. Sans policy matérielle, le Core neutre garde sa valeur
// historique de 8, cohérente avec son propre DeviceProfile.
function _defaultTranscodingMaxAudioChannels(ctx) {
    var n = 0
    try {
        var prof = _policyBuildDeviceProfile("http")
        if (prof) n = Number(prof.MaxAudioChannels)
    } catch(e0) { n = 0 }
    if (!isFinite(n) || n <= 0) n = 8
    return _capAudioChannelsForOutput(ctx, n)
}
// Applique le plafond stéréo à un plan audio de transcodage déjà calculé :
// la copie devient impossible pour une piste de plus de 2 canaux.
function _audioOutputTranscodePlan(ctx, src, audioIndex, plan) {
    var out = _audioOutputPlan(ctx, src, audioIndex)
    if (!plan || out.downmix !== true) {
        return plan
    }
    return {
        sourceNeedsAc3: plan.sourceNeedsAc3,
        sourceIsDts: plan.sourceIsDts,
        sourceIsTrueHd: plan.sourceIsTrueHd,
        codec: out.codec,
        allowCopy: false,
        channels: out.channels,
        bitrate: out.bitrate
    }
}
// Point d'étranglement unique du profil envoyé dans PlaybackInfo : Révolution,
// Devialet et profil générique passent tous par ici. En mode stéréo, le
// plafond est annoncé pour TOUTES les pistes (une 2.0 reste donc éligible à la
// lecture directe, une 5.1 ne l'est plus).
function _applyStereoAudioProfileCeiling(profile, targetBitrate) {
    if (!profile) return profile
    var max = AudioOutput.STEREO_CHANNELS
    var bitrate = Number(targetBitrate || 0)
    if (!isFinite(bitrate) || bitrate <= 0) bitrate = AudioOutput.STEREO_DEFAULT_BITRATE
    bitrate = Math.max(32000, Math.min(AudioOutput.STEREO_MAX_BITRATE, Math.floor(bitrate)))
    try {
        var current = Number(profile.MaxAudioChannels || 0)
        if (!isFinite(current) || current <= 0 || current > max)
            profile.MaxAudioChannels = max
        var list = profile.CodecProfiles
        var found = false
        if (list && list.length) {
            for (var i = 0; i < list.length; i++) {
                var conds = list[i] ? list[i].Conditions : null
                if (!conds || !conds.length) continue
                for (var j = 0; j < conds.length; j++) {
                    var cond = conds[j]
                    if (!cond || _s(cond.Property) !== "AudioChannels") continue
                    if (_s(cond.Condition) !== "LessThanEqual") continue
                    if (!(Number(cond.Value || 0) > 0) || Number(cond.Value) > max)
                        cond.Value = String(max)
                    found = true
                }
            }
        }
        if (!found) {
            if (!list) {
                list = []
                profile.CodecProfiles = list
            }
            list.push({
                Type: "VideoAudio",
                Conditions: [ { Condition: "LessThanEqual", Property: "AudioChannels", Value: String(max), IsRequired: false } ],
                ApplyConditions: []
            })
        }
        // Pour la VIDEO, Jellyfin peut sinon choisir son propre débit audio par défaut
        // lors d'un downmix. Un CodecProfile VideoAudio avec AudioBitrate
        // est la façon prise en charge par StreamBuilder de plafonner la valeur
        // AVANT la génération du TranscodingUrl. Ainsi le master HLS reçu peut
        // être utilisé tel quel, sans le réécrire après PlaybackInfo.
        list.push({
            Type: "VideoAudio",
            Codec: AudioOutput.STEREO_CODEC,
            Conditions: [
                { Condition: "LessThanEqual", Property: "AudioChannels", Value: String(max), IsRequired: false },
                { Condition: "LessThanEqual", Property: "AudioBitrate", Value: String(bitrate), IsRequired: false }
            ],
            ApplyConditions: []
        })
    } catch(e0) {}
    return profile
}
function _sourceVideoDimensions(src) {
    var v = StreamRules.firstStream(src, "Video"); var w = Number(v && v.Width || 0); var h = Number(v && v.Height || 0)
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
    if (ctx && StreamRules.normalizePlaybackRuleMode(ctx.playbackRuleMode) === "directplay")
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

function _isSingleAudioNoSubtitleDirectPlayCandidate(ctx, src) {
    if (!ctx || !src) return false
    if (StreamRules.streamCountOfType(src, "Audio") !== 1) return false
    if (StreamRules.streamCountOfType(src, "Subtitle") !== 0) return false
    if (!_wantsNoServerSubtitle(ctx) || _isDvdFolderSource(src)) return false
    var onlyAudio = StreamRules.firstAudioStreamIndex(src)
    if (onlyAudio < 0) return false
    return !StreamRules.hasExplicitAudio(ctx) || ctx.selectedAudioStream === onlyAudio
}

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

function _isInterlacedTransportStreamH264(src) { if (!src || src.IsInfiniteStream === true) return false; return StreamRules.isTransportStreamContainer(src.Container, src.Path) && StreamRules.hasInterlacedH264Video(src.MediaStreams || []) }
function _shouldForceInterlacedTsTranscode(ctx, src) {
    if (ctx && (ctx.manualDirectPlayOverride === true || ctx.manualRemuxOverride === true ||
                StreamRules.normalizePlaybackRuleMode(ctx.playbackRuleMode) === "directplay")) return false
    if (ctx && ctx.forceInterlacedTsTranscode === true) return true
    return _isInterlacedTransportStreamH264(src)
}
function _interlacedTsTranscodeDimensions(src) {
    var v = StreamRules.firstStream(src, "Video"); var w = Number(v && v.Width || 0); var h = Number(v && v.Height || 0); var anamorphic = !!(v && v.IsAnamorphic === true); var ar = _s(v && v.AspectRatio).toLowerCase()
    if (anamorphic && h >= 1000 && (w === 1440 || ar === "16:9")) return { width: 1920, height: 1080 }
    if (!isFinite(w) || w <= 0) w = 1920
    if (!isFinite(h) || h <= 0) h = 1080
    w = Math.max(2, Math.min(1920, Math.floor(w / 2) * 2))
    h = Math.max(2, Math.min(1080, Math.floor(h / 2) * 2))
    return { width: w, height: h }
}
function _interlacedTsMaxFramerate(src) { var v = StreamRules.firstStream(src, "Video"); var fr = Number(v && (v.AverageFrameRate || v.ReferenceFrameRate) || 0); if (!isFinite(fr) || fr <= 0) fr = 25; if (fr > 30) fr = 30; return fr }
function _audioChannelsForStream(src, idx) { var a = StreamRules.audioStreamByIndex(src, idx); var ch = Number(a && a.Channels || 0); if (!isFinite(ch) || ch <= 0) ch = 2; return Math.max(1, Math.min(8, Math.floor(ch))) }
function _ac3BitrateForChannels(ch) { ch = Number(ch || 2); if (ch <= 2) return 192000; if (ch <= 4) return 384000; return 640000 }

function _isMkvLike(src) {
    var c = StreamRules.containerOrExt(src)
    return (c === "mkv" || c === "matroska" || c === "webm")
}
function _isMp4Like(src) {
    var c = StreamRules.containerOrExt(src)
    return c === "mp4" || c === "m4v" ||
           c === "mov" || c.indexOf("mp4") >= 0 ||
           c.indexOf("mov") >= 0
}
function _streamTextBlob(st) {
    if (!st) return ""
    return StreamRules.fold([ st.Title || "",
        st.DisplayTitle || "", st.Comment || "",
        st.Language || "", st.Codec || "",
        st.CodecTag || "" ].join(" "))
}
function _sourceLooksGoogleProducedMp4(src) {
    if (!src || !src.MediaStreams) return false
    var nameBlob = StreamRules.fold([ src.Name || "",
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
    var v = StreamRules.firstStream(src, "Video")
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
    var v = StreamRules.firstStream(src, "Video"); var a = StreamRules.firstStream(src, "Audio"); var vc = _s(v && v.Codec).toLowerCase(); var ac = _s(a && a.Codec).toLowerCase(); var isSimpleCodec = (vc === "h264" || vc === "avc1") &&
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
    if (!StreamRules.smartPlaybackRulesEnabled(ctx) || ctx.manualDirectPlayOverride === true ||
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
    return StreamRules.smartPlaybackRulesEnabled(ctx)
}
function _dvdMpegAudioCodecLock(src, audioIndex) {
    var c = StreamRules.selectedAudioCodec(src, audioIndex)
    if (!c) return null
    c = CoreUrl._normalizeAudioCodecHint(c)
    if (!c) return null
    if (c === "ac3") return "ac3"
    if (c === "dts" || c === "dca" || c === "dts,dca") return "dts,dca"
    if (c === "mp2") return "mp2"
    if (c === "mp3") return "mp3"
    if (c === "pcm_dvd" || c === "pcm_s16be") return c
    return "ac3"
}
function _isHevcMain10Source(src) {
    var v = StreamRules.firstStream(src, "Video")
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

// En DirectPlay natif QtMultimedia 5.15 peut ignorer les drapeaux Matroska
// Default/Forced et afficher la première piste de sous-titres interne physique.
// Cette valeur sert uniquement à synchroniser l'UI avec le comportement Qt.

function _hasOnlySafeDefaultForcedFrenchSubtitles(src) {
    if (!src || !src.MediaStreams) return true
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !StreamRules.isType(st, "Subtitle")) continue
        if (st.IsExternal === true) continue
        if (!(st.IsDefault === true || st.IsForced === true)) continue
        if (StreamRules.isSafeFrenchForcedSubtitle(st, src)) continue
        if (StreamRules.isIgnorableTrailingForeignForcedSubtitle(src, st)) continue
        return false
    }
    return true
}
function _hasReliableDefaultFrenchAudio(ctx, src) {
    if (!ctx || !src) return false
    if (StreamRules.hasExplicitAudio(ctx)) return false
    var def = StreamRules.defaultAudioStreamIndex(src)
    if (def < 0) return false
    var defSt = StreamRules.audioStreamByIndex(src, def)
    if (StreamRules.scoreFrenchAudioStream(defSt) < 80) return false
    var first = StreamRules.firstAudioStreamIndex(src)
    if (first >= 0 && first !== def) {
        var firstSt = StreamRules.audioStreamByIndex(src, first)
        if (StreamRules.scoreFrenchAudioStream(firstSt) < 80) return false
    }
    return true
}
function _isFrenchDirectPlayGreenGate(ctx, src) {
    if (!ctx || !src) return false
    if (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) return false
    if (!_hasReliableDefaultFrenchAudio(ctx, src)) return false
    if (!_hasOnlySafeDefaultForcedFrenchSubtitles(src)) return false
    if (StreamRules.preferredFrenchForcedSubtitleNeedsServerSelection(ctx, src)) return false
    if (ctx.disableImageSubtitleRiskRemux !== true && _hasPriorityInternalImageSubtitleRisk(src)) return false
    if (_isDvdFolderSource(src)) return false
    return true
}
function _hasPriorityInternalImageSubtitleRisk(src) {
    if (!src || !src.MediaStreams) return false
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !StreamRules.isType(st, "Subtitle")) continue
        if (st.IsExternal === true) continue
        if (!(st.IsDefault === true || st.IsForced === true)) continue
        if (StreamRules.isSafeFrenchForcedSubtitle(st, src)) continue
        if (StreamRules.isIgnorableTrailingForeignForcedSubtitle(src, st)) continue
        var codec = _s(st.Codec).toLowerCase(); var textish = (st.IsTextSubtitleStream === true) || StreamRules.isTextSubtitleCodec(codec)
        if (StreamRules.isImageSubtitleCodec(codec)) return true
        if (!textish) return true
    }
    return false
}
function _shouldRemuxNoSubsForDirectPlay(ctx, src) {
    if (!ctx || !src) return false
    if (ctx.disableDefaultSubtitleRemux === true) return false
    if (!_wantsNoServerSubtitle(ctx)) return false
    if (StreamRules.hasDefaultOrForcedInternalSubtitle(src)) return true
    if (ctx.disableImageSubtitleRiskRemux !== true && _hasPriorityInternalImageSubtitleRisk(src)) return true
    return false
}

function _hasAudioCodec(src, codec) {
    codec = CoreUrl._normalizeAudioCodecHint(codec)
    if (!src || !src.MediaStreams || !codec) return false
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i]
        if (!st || !StreamRules.isType(st, "Audio")) continue
        var c = CoreUrl._normalizeAudioCodecHint(st.Codec)
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
    if (!StreamRules.hasInternalSubtitle(src)) return false
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

function _isDtsAudioCodecHint(codec) {
    var c = CoreUrl._normalizeAudioCodecHint(codec)
    return c === "dts" || c === "dca" || c === "dts,dca" || c === "a_dts"
}
function _isTrueHdAudioCodecHint(codec) {
    var c = CoreUrl._normalizeAudioCodecHint(codec)
    return c === "truehd" || c === "mlp" || c === "mlp_fba" || c === "a_truehd" || c === "dolby_truehd" || c === "true-hd" || c === "true_hd"
}
function _isTrueHd51AudioStream(st) {
    if (!st || !StreamRules.isType(st, "Audio")) return false
    if (!_isTrueHdAudioCodecHint(st.Codec)) return false
    var channels = 0
    try { channels = parseInt(_s(st.Channels || 0), 10) } catch(e0) { channels = 0 }
    // TrueHD 7.1 / Atmos (8 canaux) exige la meme protection que 5.1.
    if (isFinite(channels) && channels > 0) return channels >= 6
    var layout = StreamRules.fold(st.ChannelLayout || "")
    return layout.indexOf("5.1") >= 0 || layout.indexOf("7.1") >= 0
}
function _plannedAutomaticAudioStreamIndex(ctx, src, autoFrenchAudioIndex) {
    if (ctx && typeof ctx.selectedAudioStream === "number" && ctx.selectedAudioStream >= 0) return ctx.selectedAudioStream
    if (typeof autoFrenchAudioIndex === "number" && autoFrenchAudioIndex >= 0) return autoFrenchAudioIndex
    return StreamRules.defaultAudioStreamIndex(src)
}
function _shouldForceTrueHd51AudioTranscode(ctx, src, audioIndex) {
    if (!ctx || !src) return false
    if (ctx.manualDirectPlayOverride === true) return false
    if (typeof audioIndex !== "number" || audioIndex < 0) return false
    return _isTrueHd51AudioStream(StreamRules.audioStreamByIndex(src, audioIndex))
}
function _isUnsafeFullTranscodeAudioCodecHint(codec) {
    return _isDtsAudioCodecHint(codec) || _isTrueHdAudioCodecHint(codec)
}
function _fullTranscodeAudioNeedsAc3(src, audioIndex) {
    return _isUnsafeFullTranscodeAudioCodecHint(StreamRules.selectedAudioCodec(src, audioIndex))
}
function _safeFullTranscodeAudioCodecHint(wanted, src, audioIndex) {
    var sourceNeedsAc3 = _fullTranscodeAudioNeedsAc3(src, audioIndex); var normalized = CoreUrl._normalizeAudioCodecHint(wanted)
    if (sourceNeedsAc3 || _isUnsafeFullTranscodeAudioCodecHint(normalized)) return "ac3"
    return normalized || "ac3"
}
function _audioChannelCountForStream(src, audioIndex) {
    var st = StreamRules.audioStreamByIndex(src, audioIndex)
    if (!st) return 2
    var channels = parseInt(_s(st.Channels), 10)
    if (!isFinite(channels) || channels < 1) channels = 2
    if (channels > 6) channels = 6
    return channels
}
function _audioCodecHintContains(codecHint, codec) {
    var wanted = CoreUrl._normalizeAudioCodecHint(codecHint); var source = CoreUrl._normalizeAudioCodecHint(codec)
    if (!wanted || !source) return false
    var parts = wanted.split(",")
    for (var i = 0; i < parts.length; i++) {
        if (CoreUrl._normalizeAudioCodecHint(parts[i]) === source) return true
    }
    return false
}
function _safeFullTranscodeAudioPlan(src, audioIndex, wantedCodec, allowCopyDefault) {
    var sourceCodec = StreamRules.selectedAudioCodec(src, audioIndex); var sourceNeedsAc3 = _fullTranscodeAudioNeedsAc3(src, audioIndex); var codec = _safeFullTranscodeAudioCodecHint(wantedCodec || sourceCodec, src, audioIndex)
    var targetIsAc3 = CoreUrl._normalizeAudioCodecHint(codec) === "ac3"; var sourceAllowedByTarget = _audioCodecHintContains(codec, sourceCodec); var allowCopy = allowCopyDefault !== false && !sourceNeedsAc3 && sourceAllowedByTarget
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
    var st = StreamRules.firstStream(src, "Video")
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
    var st = StreamRules.audioStreamByIndex(src, audioIndex)
    if (!st) return null
    var codec = StreamRules.exactAudioCodecHint(st.Codec)
    if (!codec) return null
    return codec
}
/* ===== Module URL/transport statique ===== */
var _coreUrlConfigured = false
var _CORE_URL_REQUIRED = [
    "configure", "setFbx",
    "buildProgressiveUrl", "buildServerSeekProgressiveUrl",
    "buildHighQualityProgressiveTranscodeUrl", "buildHlsUrl",
    "getVideoStreamUrl", "_subtitleResultUrl", "buildDeviceProfile",
    "_needsServerTrackSelection_ctx", "_decidePreferredContainerWithSrc",
    "_buildRemuxProgressiveUrl", "_normalizeAudioCodecHint",
    "_forceQuery", "_u", "_headersWithToken", "_jsonNormalize", "_sendRequest",
    "_sendPlaybackInfoExact", "_extFrom", "_isProblematicForSeek", "_transportValidateServerUrlStrict",
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
            policyBuildDeviceProfile: _policyBuildDeviceProfile,
            policyPreferredContainer: _policyPreferredContainer
        })
        CoreUrl.setFbx(_fbx)
        _coreUrlConfigured = true
        return true
    } catch(e) {
        return false
    }
}
// Public compatibility surfaces used outside the Core. Internal URL/transport
// helpers call CoreUrl directly after _ensureCoreUrlConfigured() succeeds.
function _extFrom(a) { return _ensureCoreUrlConfigured() ? CoreUrl._extFrom(a) : "" }
function fetchStreams(a, b, c, d, e) {
    if (_ensureCoreUrlConfigured()) return CoreUrl._transportFetchStreams(a, b, c, d, e)
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
        "policyRev=" + (_devicePolicyRevision | 0), "playbackRules=" + StreamRules.normalizePlaybackRuleMode(ctx.playbackRuleMode),
        "audioOut=" + _audioOutputMode(ctx),
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
// T14 : StartTimeTicks dans le corps POST PlaybackInfo est une intention, PAS
// une preuve que la TranscodingUrl ouverte par Qt est positionnee. Les logs
// materiels T13 ont confirme un FFmpeg sans -ss et start_number=0 malgre ce POST.
// Seul un offset present dans l'URL finale ET correspondant a la cible permet
// ici de considerer le flux comme pre-positionne. Ne loguer jamais cette URL.
function _stereoHlsUrlHasTargetOffset(url, targetMs) {
    var target = Math.floor(Number(targetMs) || 0)
    if (target <= 0) return false
    var m = String(url || "").match(/(?:[?&])StartTimeTicks=([0-9]+)(?=[&#]|$)/i)
    if (!m) return false
    var ticks = Number(m[1])
    return isFinite(ticks) && ticks > 0 && Math.abs(ticks - target * 10000) <= 10000 * 1000
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
    var wantsServerSelect = CoreUrl._needsServerTrackSelection_ctx(ctx)
    var mustHls = (ctx.forceHls === true)
    var allowTextSubtitleServerBurnIn = _allowTextSubtitleServerBurnIn(ctx)
    var preflightTextEncode = !!(allowTextSubtitleServerBurnIn &&
        ctx.currentPlaybackVideoTranscodeByPolicy === true && ctx.selectedSubtitleIsText === true &&
        ctx.useLocalSubs !== true && typeof ctx.selectedSubtitleStream === "number" &&
        ctx.selectedSubtitleStream >= 0)
    var explicitEncode = (ctx.forceSubtitleEncode === true &&
        (ctx.selectedSubtitleIsText !== true || allowTextSubtitleServerBurnIn)) || preflightTextEncode
    var forceDvdSubPreflight = (ctx.forceDvdSubFileTranscode === true &&
                                 StreamRules.smartPlaybackRulesEnabled(ctx) &&
                                 ctx.manualDirectPlayOverride !== true &&
                                 ctx.manualRemuxOverride !== true)
    var forceInterlacedTsPreflight = (ctx.forceInterlacedTsTranscode === true &&
                                      StreamRules.smartPlaybackRulesEnabled(ctx) &&
                                      ctx.manualDirectPlayOverride !== true &&
                                      ctx.manualRemuxOverride !== true)
    var playbackInfoWantsHlsProfile = (ctx.forceHlsProfileInPlaybackInfo === true)
    var stereoPlaybackInfo = AudioOutput.isStereo(_audioOutputMode(ctx))
    var stereoPlaybackCodec = AudioOutput.STEREO_CODEC
    // Un downmix audio seul doit conserver la vidéo en stream-copy. Le profil
    // exact dépend du Player : HTTP/MKV reste possible, tandis que Devialet
    // privilégie HLS/TS pour éviter le MKV progressif live rejeté par QtMultimedia.
    // Sur Devialet, un MKV progressif produit en temps réel par le serveur est
    // rejeté par QtMultimedia alors que la même source MKV statique est lue.
    // Pour le downmix 5.1 -> 2.0, la policy peut donc demander HLS/TS tout en
    // conservant explicitement le stream-copy vidéo. La Révolution garde son
    // chemin HTTP historique tant que sa policy ne demande pas ce mode.
    var stereoPreferHls = stereoPlaybackInfo && ctx.preferStereoAudioOnlyHls === true
    var dpMode = (ctx.forceMp4 === true) ? "mp4"
               : (forceDvdSubPreflight ? "encode"
               : (explicitEncode ? "hls-encode"
               : ((mustHls || playbackInfoWantsHlsProfile || stereoPreferHls) ? "hls"
               : (stereoPlaybackInfo ? "http" : "auto"))))
    var subMethodWanted = _chooseSubtitleMethod(ctx, mustHls || explicitEncode)
    var url = CoreUrl._u(ctx.serverUrl, "/Items/" + encodeURIComponent(ctx.itemId) + "/PlaybackInfo")
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
        DeviceProfile: CoreUrl.buildDeviceProfile(dpMode)
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
    // Sortie audio stéréo : le plafond de canaux est annoncé au serveur dès
    // PlaybackInfo. Le nombre de canaux de la piste retenue n'est connu qu'à
    // la réponse, mais annoncer 2 est inoffensif pour une piste déjà stéréo et
    // c'est la seule façon d'obtenir une TranscodingUrl Jellyfin déjà mixée.
    if (stereoPlaybackInfo) {
        var sourceBitrateHint = Number(ctx.audioSourceBitrateHint || 0)
        if (!isFinite(sourceBitrateHint) || sourceBitrateHint <= 0) sourceBitrateHint = 0
        var stereoPlaybackBitrate = AudioOutput.stereoBitrateForStream({ BitRate: sourceBitrateHint })
        // Contrat explicite du sélecteur 5.1 -> 2.0 : le serveur doit encoder
        // l'audio, mais la vidéo doit rester éligible au stream-copy.
        body.EnableDirectPlay = false
        // Le downmix n'est pas un DirectStream : l'audio doit passer par le
        // TranscodingProfile afin que Jellyfin respecte le codec cible. La vidéo
        // reste néanmoins copiable via AllowVideoStreamCopy=true.
        body.EnableDirectStream = false
        body.EnableTranscoding = true
        body.AllowVideoStreamCopy = true
        body.AllowAudioStreamCopy = false
        body.MaxAudioChannels = AudioOutput.STEREO_CHANNELS
        // AudioCodec reste un hint toléré par certaines versions Jellyfin ;
        // le verrou réel est porté par DeviceProfile.TranscodingProfiles.
        // Ne pas imposer ici un bitrate fixe : le débit de la piste sélectionnée
        // a déjà été collecté avant PlaybackInfo et plafonné à 384 kb/s.
        body.AudioCodec = stereoPlaybackCodec
        // Un changement de canaux doit reprendre exactement à la position courante.
        // En HLS, forcer les ticks même si une policy avait demandé un cold-start.
        if (playbackInfoStartMs > 0) {
            playbackInfoStartTicks = Math.floor(playbackInfoStartMs * 10000)
            body.StartTimeTicks = playbackInfoStartTicks
        }
        _applyStereoAudioProfileCeiling(body.DeviceProfile, stereoPlaybackBitrate)
        // StreamBuilder prend le codec audio cible dans le TranscodingProfile.
        // Ne laisser aucune liste concurrente (aac/mp3/...) pour ce PlaybackInfo.
        var stereoProfiles = body.DeviceProfile.TranscodingProfiles || []
        for (var sp = 0; sp < stereoProfiles.length; sp++) {
            if (stereoProfiles[sp].Type === "Video") {
                stereoProfiles[sp].AudioCodec = stereoPlaybackCodec
                stereoProfiles[sp].MaxAudioChannels = String(AudioOutput.STEREO_CHANNELS)
            }
        }
        // MusicStreamingTranscodingBitrate ne pilote pas ce chemin vidéo. Le
        // plafond audio est porté par CodecProfiles/VideoAudio ci-dessus.
        try { delete body.DeviceProfile.MusicStreamingTranscodingBitrate } catch(eStereoBitrate) {}
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
    if (AudioOutput.isStereo(_audioOutputMode(ctx))) {
        delete _inFlightWaiters[key]
        if (onError) onError("server_pipeline_required")
        return
    }
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
        fbUrl = CoreUrl.buildHlsUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
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
        fbUrl = CoreUrl._forceQuery(fbUrl, qctx, explicitEncode ? "Encode" : "Hls", true)
    } else {
        fbUrl = CoreUrl.getVideoStreamUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId)
    }
    if (!fbUrl || !/[?&]ApiKey=/i.test(fbUrl) ||
            !CoreUrl._transportValidatePlaybackUrlStrict(fbUrl, ctx.serverUrl)) {
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
    if (!CoreUrl._transportValidateServerUrlStrict(ctx.serverUrl, false)) {

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

    CoreUrl._sendPlaybackInfoExact(url, CoreUrl._headersWithToken(ctx.accessToken), body, function (res) {
        _negotiating = false
        delete _inFlightKeys[key]
        _lastNegTs = (new Date()).getTime()
        var resp = CoreUrl._jsonNormalize(res.json) || {}; var playSessionId = resp && resp.PlaySessionId ? resp.PlaySessionId : ""; var src = (resp && resp.MediaSources && resp.MediaSources.length > 0) ? resp.MediaSources[0] : null
        var mediaSourceId = (src && src.Id) ? src.Id : ""

        var autoVoFrenchFullSubtitleIndex = StreamRules.autoVoFrenchFullSubtitleIndex(ctx, src); var autoVoFrenchFullSubtitle = autoVoFrenchFullSubtitleIndex >= 0
        if (autoVoFrenchFullSubtitle) {
            ctx.selectedSubtitleStream = autoVoFrenchFullSubtitleIndex
            ctx.useLocalSubs = false
            subMethodWanted = "Embed"

        }
        var selectedSubStream = StreamRules.subtitleStreamByIndex(src, ctx.selectedSubtitleStream); var imageSubtitleSelected = false; var textSubtitleSelected = false
        if (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) {
            imageSubtitleSelected = StreamRules.isImageSubtitleSelected(src, ctx.selectedSubtitleStream)
            textSubtitleSelected = StreamRules.isTextSubtitleSelected(src, ctx.selectedSubtitleStream)
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
        var forceEncodeByPolicy = imageSubtitleSelected && _policyForceSubtitleEncode(ctx, src, selectedSubStream); var hasInternalDvdSubtitle = StreamRules.hasInternalDvdSubtitle(src)
        var dvdSourceRemuxPreferred = _isDvdFolderSource(src)
        // DVDSub/VobSub dormant est une regle de securite/compatibilite d'usage,
        // pas une incompatibilite du codec video. En mode Original, si la video
        // elle-meme est compatible, on laisse donc le fichier en DirectPlay.
        // Si le codec video est incompatible (AV1, etc.), forceTranscodeByPolicy
        // reste vrai via requiresHardVideoTranscode et garde la priorite.
        var forceDvdSubFileTranscode = !!( hasInternalDvdSubtitle &&
            StreamRules.smartPlaybackRulesEnabled(ctx) &&
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
        var autoFrenchForcedDvdSubIndex = StreamRules.safeFrenchForcedDvdSubtitleIndex(src)
        var forceImageBurnIn = imageSubtitleSelected && (explicitEncode || forceEncodeByPolicy); var preferImageRemux = imageSubtitleSelected && !forceImageBurnIn
        var safeFrenchForcedSubIndex = StreamRules.safeFrenchForcedSubtitleIndex(src)
        var preferredFrenchForcedSubtitleNeedsServerSelection = StreamRules.preferredFrenchForcedSubtitleNeedsServerSelection(ctx, src); var frenchDirectPlayGreenGate = _isFrenchDirectPlayGreenGate(ctx, src)
        var remuxNoSubs = (ctx.manualDirectPlayOverride === true || ctx.manualRemuxOverride === true) ? false
                          : _shouldRemuxNoSubsForDirectPlay(ctx, src)
        var hevcMain10Eac3InternalSubRisk = _shouldRemuxHevcMain10Eac3InternalSubFreeboxRisk(ctx, src)
        if (hevcMain10Eac3InternalSubRisk)
            remuxNoSubs = true
        var mp4EditListTimestampRisk = _shouldRemuxMp4EditListTimestampRisk(ctx, src); var mp4TimedMetadataTrackRisk = _shouldRemuxMp4TimedMetadataTrackRisk(ctx, src); var mp4ContainerTimelineRisk = !!(mp4EditListTimestampRisk || mp4TimedMetadataTrackRisk); var singleAudioNoSubtitleDirectPlay = _isSingleAudioNoSubtitleDirectPlayCandidate(ctx, src)
        var remuxMkvHevcMain10 = _shouldServerRemuxHevcMain10(ctx, src); var autoFrenchAudioIndex = StreamRules.autoFrenchAudioStreamIndex(ctx, src); var autoFrenchAudio = autoFrenchAudioIndex >= 0
        var plannedAudioStreamIndex = _plannedAutomaticAudioStreamIndex(ctx, src, autoFrenchAudioIndex); var forceTrueHd51AudioTranscode = _shouldForceTrueHd51AudioTranscode(ctx, src, plannedAudioStreamIndex)
        var forcePolicyAudioOnlyTranscode = _policyRequiresAudioOnlyTranscode(ctx, src, plannedAudioStreamIndex)
        // Première estimation du downmix stéréo, sur la piste pressentie, afin
        // de sortir du DirectPlay statique comme le fait le TrueHD 5.1. Elle est
        // recalculée plus bas sur la piste réellement retenue.
        var stereoDownmixAudio = _shouldStereoDownmixAudio(ctx, src, plannedAudioStreamIndex)
        var preferredFrenchAudioNeedsServerSelection = StreamRules.preferredFrenchAudioNeedsServerSelection(ctx, src); var defaultFrenchAudioNotFirst = StreamRules.shouldRemuxDefaultFrenchAudioNotFirst(ctx, src)
        var dvdFolderMpegRemux = _shouldRemuxDvdFolderMpeg(ctx, src); var pinNoSubDefaultAudio = StreamRules.shouldPinDefaultAudioForNoSubRemux(ctx, src, remuxNoSubs); var forceServerRemux = forceRemuxByPolicy ||
            forceInterlacedTsTranscode || forceTrueHd51AudioTranscode || forcePolicyAudioOnlyTranscode || stereoDownmixAudio ||
            remuxNoSubs || remuxMkvHevcMain10 ||
            mp4ContainerTimelineRisk || autoFrenchAudio ||
            preferredFrenchAudioNeedsServerSelection || preferredFrenchForcedSubtitleNeedsServerSelection ||
            defaultFrenchAudioNotFirst || dvdFolderMpegRemux ||
            preferImageRemux || textSubtitleSelected ||
            serverExternalTextSubtitle || ctx.forceServerRemux === true

        var dvdSubTranscodeSubtitleIndex = -1; var dvdSubTranscodeSubtitleMethod = null
        if (forceDvdSubFileTranscode && !ctx.useLocalSubs) {
            if (typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) {
                if (StreamRules.isImageSubtitleSelected(src, ctx.selectedSubtitleStream)) {
                    dvdSubTranscodeSubtitleIndex = ctx.selectedSubtitleStream
                    dvdSubTranscodeSubtitleMethod = "Encode"
                } else if (StreamRules.isTextSubtitleSelected(src, ctx.selectedSubtitleStream)) {
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
            } else if (StreamRules.smartPlaybackRulesEnabled(ctx) && autoFrenchForcedDvdSubIndex >= 0) {
                dvdSubTranscodeSubtitleIndex = autoFrenchForcedDvdSubIndex
                dvdSubTranscodeSubtitleMethod = "Encode"
            }
        }
        var safeFrenchForcedSubStream = StreamRules.subtitleStreamByIndex(src, safeFrenchForcedSubIndex); var safeFrenchForcedSubIsText = StreamRules.isSafeFrenchForcedTextSubtitle(safeFrenchForcedSubStream)
        // Réinjection du sous-titre FORCÉ français. Elle ne dépend plus du seul
        // forceServerRemux : le même fichier perdait ses sous-titres forcés en
        // transcodage de politique et les retrouvait après un changement de
        // piste audio. Le critère est désormais « le flux final est un flux
        // SERVEUR capable d'embarquer du texte » (remux, transcodage audio seul
        // ou transcodage vidéo progressif), tous les autres garde-fous étant
        // conservés. Le chemin réel n'est pas encore arrêté ici : les drapeaux
        // sont mémorisés et la décision est réévaluée plus bas, une fois l'URL
        // construite, pour écarter HLS et la TranscodingUrl Jellyfin conservée.
        var forcedSubtitleStreamFlags = {
            serverRemux: forceServerRemux, policyTranscode: forceTranscodeByPolicy,
            policyTranscodeHls: policyTranscodeUseHls, serverSelect: wantsServerSelect,
            mustHls: mustHls, dvdSubtitleTranscode: forceDvdSubFileTranscode,
            hlsUrl: false, preserveTranscodingUrl: false
        }
        var forcedSubtitleCarry = ForcedSubs.decideCarry({
            smartRules: StreamRules.smartPlaybackRulesEnabled(ctx),
            serverStream: ForcedSubs.isEmbeddableServerStream(forcedSubtitleStreamFlags),
            forcedIndex: safeFrenchForcedSubIndex, forcedIsText: safeFrenchForcedSubIsText,
            useLocalSubs: ctx.useLocalSubs === true,
            explicitSubtitleIndex: (typeof ctx.selectedSubtitleStream === "number") ? ctx.selectedSubtitleStream : -1,
            // « Aucun » explicite : playerOverlayHelper pose ce drapeau dès que
            // l'utilisateur coupe les sous-titres, et il survit aux
            // négociations suivantes (seek réseau, changement de piste, rejeu
            // différé). Un choix explicite ne doit jamais être écrasé.
            explicitSubtitlesOff: ctx.disableAutoVoFrenchFullSubtitle === true,
            imageBurnIn: forceImageBurnIn, imageRemux: preferImageRemux,
            textSubtitleSelected: textSubtitleSelected, serverExternalSubtitle: serverExternalTextSubtitle,
            internalSubtitleRisk: hevcMain10Eac3InternalSubRisk
        })
        var carrySafeFrenchForcedSubtitle = forcedSubtitleCarry.carry; var forcedSubtitleCarryReason = forcedSubtitleCarry.reason
        var autoSubtitleEmbedIndex = carrySafeFrenchForcedSubtitle ? safeFrenchForcedSubIndex : -1
        var subMethodBeforeForcedCarry = subMethodWanted
        if (carrySafeFrenchForcedSubtitle)
            subMethodWanted = forcedSubtitleCarry.method

        var pinDefaultAudio = StreamRules.hasExplicitAudio(ctx) ||
            autoFrenchAudio || preferredFrenchAudioNeedsServerSelection ||
            preferredFrenchForcedSubtitleNeedsServerSelection || defaultFrenchAudioNotFirst ||
            dvdFolderMpegRemux || preferImageRemux ||
            forceImageBurnIn || forceDvdSubFileTranscode ||
            forceInterlacedTsTranscode || forceTrueHd51AudioTranscode || forcePolicyAudioOnlyTranscode ||
            forceTranscodeByPolicy || forceServerRemux ||
            ctx.forceServerSeek === true || textSubtitleSelected ||
            serverExternalTextSubtitle || (imageSubtitleSelected === true) ||
            pinNoSubDefaultAudio
        if (forceServerRemux || forceTranscodeByPolicy || forceDvdSubFileTranscode || forceInterlacedTsTranscode || forceTrueHd51AudioTranscode || forcePolicyAudioOnlyTranscode)
            wantsServerSelect = true
        var effectiveAudioStreamIndex = StreamRules.effectiveAudioStreamForServer( ctx,
            src, imageSubtitleSelected,
            forceImageBurnIn, preferImageRemux,
            pinDefaultAudio, autoFrenchAudioIndex
        )
        forceTrueHd51AudioTranscode = _shouldForceTrueHd51AudioTranscode(ctx, src, effectiveAudioStreamIndex)
        forcePolicyAudioOnlyTranscode = _policyRequiresAudioOnlyTranscode(ctx, src, effectiveAudioStreamIndex)
        // Piste réellement envoyée au serveur : soit l'index explicite/auto,
        // soit la piste par défaut que le serveur choisira. Le plan audio, et
        // donc la sélection automatique française, portent sur CELLE-LÀ.
        var audioOutputStreamIndex = (typeof effectiveAudioStreamIndex === "number" && effectiveAudioStreamIndex >= 0)
                                     ? effectiveAudioStreamIndex : plannedAudioStreamIndex
        var audioOutputPlan = _audioOutputPlan(ctx, src, audioOutputStreamIndex)
        // Le downmix serveur cible AAC-LC 2.0 via AudioCodec=aac. Les codecs source
        // (E-AC-3, AC-3, DTS, etc.) restent traités normalement hors de ce mode ;
        // ici la cible stéréo explicite gagne sur la policy audio matérielle.
        stereoDownmixAudio = audioOutputPlan.downmix === true
        // Transcodage AUDIO SEUL, vidéo copiée : historiquement le TrueHD 5.1,
        // désormais aussi le mixage stéréo demandé par l'utilisateur et toute
        // incompatibilité audio seule déclarée par la policy matérielle. Quand
        // plusieurs s'appliquent, le downmix stéréo gagne (AAC-LC 2.0).
        var audioOnlyTranscodeNeeded = !!(forceTrueHd51AudioTranscode || forcePolicyAudioOnlyTranscode || stereoDownmixAudio)
        var audioOnlyTranscodeCodec = stereoDownmixAudio ? audioOutputPlan.codec
                                    : (forceTrueHd51AudioTranscode ? "ac3"
                                       : (forcePolicyAudioOnlyTranscode ? _policyTranscodeAudioCodecHint(ctx, src, audioOutputStreamIndex, false) : null))

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
        var dvdVideoBitrate = 0; var dvdTicks = 0; var dvdAudioCodec = null; var dvdAudioAllowCopy = true; var dvdAudioChannels = null; var dvdAudioBitrate = null; var imageBurnAudioPlan = null; var audioOnlyTranscodeChannels = stereoDownmixAudio ? audioOutputPlan.channels : (forceTrueHd51AudioTranscode ? 6 : (forcePolicyAudioOnlyTranscode ? _audioChannelCountForStream(src, audioOutputStreamIndex) : null))
        var audioOnlyTranscodeBitrate = stereoDownmixAudio ? audioOutputPlan.bitrate : ((forceTrueHd51AudioTranscode || forcePolicyAudioOnlyTranscode) ? 640000 : null); var audioOnlyTicks = 0; var audioOnlyTranscodeActive = false
        // Quand PlaybackInfo fournit déjà une TranscodingUrl HLS pour un
        // transcodage de politique (dont la qualité manuelle), cette URL est
        // désormais considérée comme la source de vérité. Le CoreUrl ne doit
        // alors plus reconstruire les contraintes décidées par Jellyfin.
        var preserveJellyfinTranscodingUrl = false
        // Downmix Devialet : ne jamais deduire le seek serveur du seul POST.
        // La TranscodingUrl peut redemarrer au debut du film (T13 confirme).
        var stereoHlsClientSeekAfterOpen = false
        var stereoHlsUrlSeekVerified = false
        if (src) {
            var hasTC   = !!(src.TranscodingUrl && src.TranscodingUrl.length > 0); var cont    = _s(src.Container).toLowerCase(); var pathExt = _extFrom(src.Path || ""); var isFrag  = CoreUrl._isProblematicForSeek(cont || pathExt)
            // Devialet + downmix HLS : conserver la TranscodingUrl complète
            // fournie par Jellyfin. Les URLs reconstruites avec StartTimeTicks
            // peuvent échouer avant même d'exposer une durée sur QtMultimedia,
            // alors que le manifeste complet + seek local est stable.
            var playbackInfoTranscodingUrl = hasTC ? CoreUrl._u(ctx.serverUrl, src.TranscodingUrl) : ""
            var playbackInfoTranscodingIsHls = !!(playbackInfoTranscodingUrl &&
                (playbackInfoTranscodingUrl.indexOf(".m3u8") >= 0 || playbackInfoTranscodingUrl.indexOf("/hls") >= 0 ||
                 _s(src && src.TranscodingSubProtocol).toLowerCase() === "hls"))
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
                // Transcodage complet TS entrelacé : la cible AC3 est conservée,
                // seul le nombre de canaux est ramené au plafond stéréo.
                var tsAudioChannels = _capAudioChannelsForOutput(ctx, _audioChannelsForStream(src, effectiveAudioStreamIndex)); var tsAudioBitrate = _ac3BitrateForChannels(tsAudioChannels); var tsTicks = (ctx.startMs > 0) ? Math.floor(ctx.startMs * 10000) : 0
                var tsSubtitleIndex = (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0)
                                      ? ctx.selectedSubtitleStream : -1
                var tsSubtitleMethod = tsSubtitleIndex >= 0
                                      ? (StreamRules.isTextSubtitleSelected(src, tsSubtitleIndex) ? "Embed" : "Encode")
                                      : null

                newUrl = CoreUrl.buildHighQualityProgressiveTranscodeUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
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
                var dvdAudioPlan = _audioOutputTranscodePlan(ctx, src, effectiveAudioStreamIndex,
                    _safeFullTranscodeAudioPlan(src, effectiveAudioStreamIndex, StreamRules.selectedAudioCodec(src, effectiveAudioStreamIndex), true))
                dvdAudioCodec = dvdAudioPlan.codec
                dvdAudioAllowCopy = dvdAudioPlan.allowCopy
                dvdAudioChannels = dvdAudioPlan.channels
                dvdAudioBitrate = dvdAudioPlan.bitrate

                newUrl = CoreUrl.buildHighQualityProgressiveTranscodeUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    audioStreamIndex: effectiveAudioStreamIndex, subtitleStreamIndex: dvdSubTranscodeSubtitleIndex >= 0 ? dvdSubTranscodeSubtitleIndex : null,
                    subtitleMethod: dvdSubTranscodeSubtitleIndex >= 0 ? dvdSubTranscodeSubtitleMethod : null, forceNoSubtitle: dvdSubTranscodeSubtitleIndex < 0,
                    mediaSourceId: mediaSourceId, playSessionId: playSessionId,
                    container: "mkv", startTimeTicks: dvdTicks,
                    videoCodec: "h264", audioCodec: dvdAudioCodec || null,
                    videoBitrate: dvdVideoBitrate, maxWidth: dvdDims.width,
                    maxHeight: dvdDims.height, maxVideoBitDepth: 8,
                    maxStreamingBitrate: REDEFIN_MAX_STREAMING_BITRATE, transcodingMaxAudioChannels: dvdAudioChannels || _defaultTranscodingMaxAudioChannels(ctx),
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
                imageBurnAudioPlan = _audioOutputTranscodePlan(ctx, src, effectiveAudioStreamIndex,
                    _safeFullTranscodeAudioPlan(src, effectiveAudioStreamIndex, imageBurnAudioCodec, imageBurnAllowAudioCopy))
                newUrl = CoreUrl.buildHlsUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
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
                var jellyfinTcCandidate = hasTC ? CoreUrl._u(ctx.serverUrl, src.TranscodingUrl) : ""
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
                    newUrl = CoreUrl.buildHlsUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
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
                        transcodingMaxAudioChannels: stereoDownmixAudio ? audioOutputPlan.channels : null,
                        audioBitrate: stereoDownmixAudio ? audioOutputPlan.bitrate : null,
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
            } else if (audioOnlyTranscodeNeeded && !mustHls && !forceTranscodeByPolicy) {
                // Vidéo copiée, audio réencodé par le serveur : TrueHD 5.1 non
                // décodable, ou mixage stéréo demandé par l'utilisateur.
                audioOnlyTranscodeActive = true
                audioOnlyTicks = (ctx.startMs > 0) ? Math.floor(ctx.startMs * 10000) : 0
                var audioOnlySubtitleIndex = serverExternalTextSubtitle ? -1
                                            : (carrySafeFrenchForcedSubtitle ? safeFrenchForcedSubIndex
                                               : ((!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0)
                                                  ? ctx.selectedSubtitleStream : -1))
                var audioOnlySubtitleMethod = audioOnlySubtitleIndex >= 0 ? (carrySafeFrenchForcedSubtitle ? "Embed" : (subMethodWanted || "Embed"))
                                           : null
                var audioOnlyContainer = ctx.forceMp4 === true ? "mp4"
                                      : (mp4EditListTimestampRisk ? "mkv"
                                         : (CoreUrl._decidePreferredContainerWithSrc(ctx, src) || "mkv"))

                // PlaybackInfo a été négocié avec un profil HTTP/MKV dédié au
                // downmix. Si Jellyfin fournit une URL progressive, elle est
                // prioritaire : elle contient les choix exacts du StreamBuilder
                // (dont la décision video-copy) et évite de reconstruire à la main
                // une URL incompatible avec la session de transcodage préparée.
                var audioOnlyServerUrl = (src && src.TranscodingUrl) ? CoreUrl._u(ctx.serverUrl, src.TranscodingUrl) : ""
                var audioOnlyServerIsHls = !!(audioOnlyServerUrl &&
                    (audioOnlyServerUrl.indexOf(".m3u8") >= 0 || audioOnlyServerUrl.indexOf("/hls") >= 0 ||
                     _s(src && src.TranscodingSubProtocol).toLowerCase() === "hls"))
                if (stereoDownmixAudio && audioOnlyServerUrl &&
                        (!audioOnlyServerIsHls || ctx.preferStereoAudioOnlyHls === true)) {
                    // T15 : pour le HTTP/MKV, Jellyfin peut omettre les ticks
                    // de l'URL pourtant fournie avec PlaybackInfo(StartTimeTicks).
                    // Une telle URL demarrerait a 00:00 comme en T13. Dans ce cas
                    // on reconstruit l'URL progressive explicite avec seek serveur
                    // plutot que d'inventer un offset UI ou seeker un MKV live.
                    var progressivePreseek = !!(!audioOnlyServerIsHls &&
                        _stereoHlsUrlHasTargetOffset(audioOnlyServerUrl, ctx.startMs))
                    if (!audioOnlyServerIsHls && ctx.startMs > 0 && !progressivePreseek) {
                        newUrl = CoreUrl.buildServerSeekProgressiveUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                            audioStreamIndex: effectiveAudioStreamIndex,
                            subtitleStreamIndex: audioOnlySubtitleIndex >= 0 ? audioOnlySubtitleIndex : null,
                            subtitleMethod: audioOnlySubtitleMethod, forceNoSubtitle: audioOnlySubtitleIndex < 0,
                            mediaSourceId: mediaSourceId, playSessionId: playSessionId,
                            container: "mkv", startTimeTicks: audioOnlyTicks,
                            videoCodec: _selectedVideoCodec(src), audioCodec: AudioOutput.STEREO_CODEC,
                            allowAudioStreamCopy: false, allowVideoStreamCopy: true,
                            enableAutoStreamCopy: false, enableDirectStream: false,
                            enableTranscoding: true, copyTimestamps: false,
                            context: "Streaming", transcodeReasons: "AudioCodecNotSupported",
                            audioChannels: audioOutputPlan.channels, audioBitrate: audioOutputPlan.bitrate,
                            transcodingMaxAudioChannels: audioOutputPlan.channels
                        })
                        includeTicks = true
                    } else {
                        // T14 : ne pas modifier le contrat Jellyfin HLS. Le seek
                        // local est obligatoire si son URL ne porte pas de ticks.
                        newUrl = audioOnlyServerUrl
                        preserveJellyfinTranscodingUrl = true
                        stereoHlsUrlSeekVerified = !!(audioOnlyServerIsHls &&
                            _stereoHlsUrlHasTargetOffset(newUrl, ctx.startMs))
                        stereoHlsClientSeekAfterOpen = !!(audioOnlyServerIsHls &&
                            ctx.startMs > 0 && !stereoHlsUrlSeekVerified)
                        includeTicks = audioOnlyServerIsHls ? stereoHlsUrlSeekVerified : progressivePreseek
                    }
                } else {
                    newUrl = CoreUrl.buildServerSeekProgressiveUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                        audioStreamIndex: effectiveAudioStreamIndex, subtitleStreamIndex: audioOnlySubtitleIndex >= 0 ? audioOnlySubtitleIndex : null,
                        subtitleMethod: audioOnlySubtitleMethod, forceNoSubtitle: audioOnlySubtitleIndex < 0,
                        mediaSourceId: mediaSourceId, playSessionId: playSessionId,
                        container: audioOnlyContainer, startTimeTicks: audioOnlyTicks,
                        videoCodec: _selectedVideoCodec(src), audioCodec: stereoDownmixAudio ? AudioOutput.STEREO_CODEC : (audioOnlyTranscodeCodec || "ac3"),
                        allowAudioStreamCopy: false, allowVideoStreamCopy: true,
                        enableAutoStreamCopy: false, enableDirectStream: false,
                        enableTranscoding: true, copyTimestamps: false,
                        context: "Streaming", transcodeReasons: "AudioCodecNotSupported"
                    })
                    includeTicks = !!(audioOnlyTicks > 0)
                }
                lastUsedTranscoding = true
                lastUsedDirectStream = false
                isServerRemux = false
            } else if (ctx.forceExplicitServerProgressiveSeek === true && (ctx.startMs || 0) > 0 && !mustHls && !forceTranscodeByPolicy) {
                remuxAudioCodecLock = dvdFolderMpegRemux ? _dvdMpegAudioCodecLock(src, effectiveAudioStreamIndex)
                                   : _remuxAudioCodecLock(ctx, src, effectiveAudioStreamIndex, true, false, false)
                var explicitSeekContainer = ctx.forceMp4 === true ? "mp4"
                                          : (mp4ContainerTimelineRisk ? "mkv"
                                             : (dvdFolderMpegRemux ? "mpeg" : (CoreUrl._decidePreferredContainerWithSrc(ctx, src) || (cont || pathExt || "mkv"))))
                var explicitSeekSubMethod = carrySafeFrenchForcedSubtitle ? "Embed"
                                          : ((!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0)
                                              ? (subMethodWanted || (preferImageRemux ? "Embed" : null)) : null)

                includeTicks = true
                newUrl = CoreUrl.buildServerSeekProgressiveUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    audioStreamIndex: effectiveAudioStreamIndex,
                    subtitleStreamIndex: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? ctx.selectedSubtitleStream : null,
                    subtitleMethod: explicitSeekSubMethod,
                    forceNoSubtitle: !(!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0),
                    mediaSourceId: mediaSourceId, playSessionId: playSessionId,
                    container: explicitSeekContainer, startTimeTicks: Math.floor(ctx.startMs * 10000),
                    videoCodec: _selectedVideoCodec(src), audioCodec: remuxAudioCodecLock || StreamRules.selectedAudioCodec(src, effectiveAudioStreamIndex),
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
                newUrl = CoreUrl._u(ctx.serverUrl, src.TranscodingUrl)
                lastUsedDirectStream = false
                lastUsedTranscoding = false
                isServerRemux = true
            } else if (fragileSeekRemux) {
                remuxAudioCodecLock = _remuxAudioCodecLock(ctx, src, effectiveAudioStreamIndex, true, false, false)

                includeTicks = true
                newUrl = CoreUrl._buildRemuxProgressiveUrl( ctx,
                    src, mediaSourceId,
                    playSessionId, effectiveAudioStreamIndex,
                    carrySafeFrenchForcedSubtitle ? "Embed" : null, includeTicks,
                    ctx.forceMp4 === true ? "mp4" : "mkv", remuxAudioCodecLock,
                    serverExternalTextSubtitle, autoSubtitleEmbedIndex
                )
                lastUsedDirectStream = false
                lastUsedTranscoding = false
                isServerRemux = true
            } else if (forceServerRemux && !mustHls && !forceTranscodeByPolicy) {
                remuxAudioCodecLock = dvdFolderMpegRemux ? _dvdMpegAudioCodecLock(src, effectiveAudioStreamIndex)
                                   : _remuxAudioCodecLock(ctx, src, effectiveAudioStreamIndex, true, false, false)

                includeTicks = !!(includeTicks || forceTicksForServerRemux || ctx.forceServerSeek)
                var forcedCont0 = ctx.forceMp4 === true ? "mp4"
                                : (mp4ContainerTimelineRisk ? "mkv"
                                   : (dvdFolderMpegRemux ? "mpeg" : (CoreUrl._decidePreferredContainerWithSrc(ctx, src) || (cont || pathExt || "mkv"))))
                var strictSubMethod = carrySafeFrenchForcedSubtitle ? "Embed"
                                    : ((!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0)
                                        ? (subMethodWanted || (preferImageRemux ? "Embed" : null)) : null)
                newUrl = CoreUrl._buildRemuxProgressiveUrl( ctx,
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

                newUrl = CoreUrl.getVideoStreamUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    mediaSourceId: mediaSourceId, container: StreamRules.containerOrExt(src)
                })
                includeTicks = false
                lastUsedDirectStream = false
                lastUsedTranscoding = false
            } else if (wantDpStatic) {

                newUrl = CoreUrl.getVideoStreamUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    mediaSourceId: mediaSourceId, container: StreamRules.containerOrExt(src)
                })
                includeTicks = false
                lastUsedDirectStream = false
                lastUsedTranscoding = false
            } else if (ctx.forceServerSeek === true && stereoDownmixAudio && playbackInfoTranscodingIsHls) {
                // Seek interactif HLS + downmix 2.0 : ne pas reconstruire le
                // manifeste. Si Jellyfin a déjà fourni StartTimeTicks, on respecte
                // sa timeline ; sinon le Player ouvre le manifeste intact puis
                // restaure la cible par seek local après Loaded/Buffered.
                newUrl = playbackInfoTranscodingUrl
                preserveJellyfinTranscodingUrl = true
                var jellyfinProvidedSeekTicks = /(?:[?&])StartTimeTicks=[1-9][0-9]*/i.test(newUrl)
                includeTicks = jellyfinProvidedSeekTicks
                stereoHlsClientSeekAfterOpen = !!(!jellyfinProvidedSeekTicks && ctx.startMs > 0)
                lastUsedTranscoding = true
                lastUsedDirectStream = false
                isServerRemux = false
            } else if (mustHls) {

                var hlsTicks = (ctx.startMs > 0) ? Math.floor(ctx.startMs * 10000) : 0
                newUrl = CoreUrl.buildHlsUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    audioStreamIndex: effectiveAudioStreamIndex,
                    subtitleStreamIndex: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? ctx.selectedSubtitleStream : null,
                    subtitleMethod: subMethodWanted || "Hls", mediaSourceId: mediaSourceId,
                    playSessionId: playSessionId, startTimeTicks: hlsTicks,
                    audioCodec: stereoDownmixAudio ? AudioOutput.STEREO_CODEC : "ac3,eac3,aac,mp3", maxBitrate: REDEFIN_MAX_STREAMING_BITRATE,
                    allowAudioStreamCopy: true, allowVideoStreamCopy: true,
                    enableAutoStreamCopy: true, enableDirectStream: true
                })
                includeTicks = !!(hlsTicks > 0)
                lastUsedTranscoding = true
                lastUsedDirectStream = false
            } else if ((wantsServerSelect || subMethodWanted === "Embed" || ctx.forceServerSeek === true) && !forceTranscodeByPolicy) {
                remuxAudioCodecLock = _remuxAudioCodecLock(ctx, src, effectiveAudioStreamIndex, true, false, false)

                var includeRemuxTicks = !!((includeTicks && (ctx.startMs || 0) > 0) || ctx.forceServerSeek === true); var forcedCont1 = CoreUrl._decidePreferredContainerWithSrc(ctx, src) || (cont || pathExt || "mkv")
                newUrl = CoreUrl._buildRemuxProgressiveUrl( ctx,
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

                newUrl = CoreUrl._u(ctx.serverUrl, src.TranscodingUrl)
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
                    newUrl = CoreUrl.buildHlsUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                        audioStreamIndex: effectiveAudioStreamIndex,
                        subtitleStreamIndex: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? ctx.selectedSubtitleStream : null,
                        subtitleMethod: subMethodWanted || null, mediaSourceId: mediaSourceId,
                        playSessionId: playSessionId || "", startTimeTicks: policyTicks,
                        videoCodec: policyTranscodeVideoCodec || "h264", audioCodec: fallbackPolicyAudioCodec || "",
                        segmentContainer: "ts", transcodeReasons: "VideoCodecNotSupported",
                        requireAvc: ((policyTranscodeVideoCodec || "h264") === "h264") ? true : undefined, minSegments: 1,
                        breakOnNonKeyFrames: true, h264Profile: ((policyTranscodeVideoCodec || "h264") === "h264") ? "high,main,baseline,constrainedbaseline" : null,
                        h264Level: ((policyTranscodeVideoCodec || "h264") === "h264") ? fullTranscodeH264Level : null,
                        transcodingMaxAudioChannels: stereoDownmixAudio ? audioOutputPlan.channels : null,
                        audioBitrate: stereoDownmixAudio ? audioOutputPlan.bitrate : null, videoBitrate: fullTranscodeVideoBitrate,
                        maxWidth: fullTranscodeDims.width, maxHeight: fullTranscodeDims.height,
                        maxBitrate: REDEFIN_MAX_STREAMING_BITRATE,
                        allowAudioStreamCopy: fallbackPolicyAllowAudioCopy, allowVideoStreamCopy: false,
                        enableAutoStreamCopy: fallbackPolicyAllowAudioCopy, enableDirectStream: false
                    })
                } else {
                    var fallbackProgressiveAudioPlan = _audioOutputTranscodePlan( ctx, src, effectiveAudioStreamIndex,
                        _safeFullTranscodeAudioPlan( src,
                            effectiveAudioStreamIndex, _policyTranscodeAudioCodecHint(ctx, src, effectiveAudioStreamIndex, false),
                            _policyTranscodeAllowAudioCopy(ctx, src, effectiveAudioStreamIndex, false) ) )
                    newUrl = CoreUrl.buildHighQualityProgressiveTranscodeUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                        audioStreamIndex: effectiveAudioStreamIndex,
                        subtitleStreamIndex: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? ctx.selectedSubtitleStream : null,
                        subtitleMethod: subMethodWanted, mediaSourceId: mediaSourceId,
                        container: CoreUrl._decidePreferredContainerWithSrc(ctx, src) || "mkv", playSessionId: playSessionId || "",
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
            } else if (audioOnlyTranscodeNeeded && !mustHls) {
                audioOnlyTranscodeActive = true
                audioOnlyTicks = (ctx.startMs > 0) ? Math.floor(ctx.startMs * 10000) : 0
                var fallbackTrueHd51SubIndex = serverExternalTextSubtitle ? -1
                                               : (carrySafeFrenchForcedSubtitle ? safeFrenchForcedSubIndex
                                                  : ((!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0)
                                                     ? ctx.selectedSubtitleStream : -1))
                newUrl = CoreUrl.buildServerSeekProgressiveUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    audioStreamIndex: effectiveAudioStreamIndex, subtitleStreamIndex: fallbackTrueHd51SubIndex >= 0 ? fallbackTrueHd51SubIndex : null,
                    subtitleMethod: fallbackTrueHd51SubIndex >= 0 ? (carrySafeFrenchForcedSubtitle ? "Embed" : (subMethodWanted || "Embed")) : null,
                    forceNoSubtitle: fallbackTrueHd51SubIndex < 0, mediaSourceId: mediaSourceId,
                    playSessionId: playSessionId || "", container: CoreUrl._decidePreferredContainerWithSrc(ctx, src) || "mkv",
                    startTimeTicks: audioOnlyTicks, videoCodec: _selectedVideoCodec(src),
                    audioCodec: stereoDownmixAudio ? AudioOutput.STEREO_CODEC : (audioOnlyTranscodeCodec || "ac3"), allowAudioStreamCopy: false,
                    allowVideoStreamCopy: true, enableAutoStreamCopy: false,
                    enableDirectStream: false, enableTranscoding: true,
                    copyTimestamps: false, context: "Streaming",
                    transcodeReasons: "AudioCodecNotSupported"
                })
                includeTicks = !!(audioOnlyTicks > 0)
                lastUsedTranscoding = true
                lastUsedDirectStream = false
                isServerRemux = false
            } else if (mustHls) {

                var fallbackHlsTicks = (ctx.startMs > 0) ? Math.floor(ctx.startMs * 10000) : 0
                newUrl = CoreUrl.buildHlsUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    audioStreamIndex: effectiveAudioStreamIndex,
                    subtitleStreamIndex: (!ctx.useLocalSubs && typeof ctx.selectedSubtitleStream === "number" && ctx.selectedSubtitleStream >= 0) ? ctx.selectedSubtitleStream : null,
                    subtitleMethod: subMethodWanted || "Hls", mediaSourceId: mediaSourceId,
                    playSessionId: playSessionId, startTimeTicks: fallbackHlsTicks,
                    audioCodec: stereoDownmixAudio ? AudioOutput.STEREO_CODEC : "ac3,eac3,aac,mp3", maxBitrate: REDEFIN_MAX_STREAMING_BITRATE,
                    allowAudioStreamCopy: true, allowVideoStreamCopy: true,
                    enableAutoStreamCopy: true, enableDirectStream: true
                })
                includeTicks = !!(fallbackHlsTicks > 0)
                lastUsedTranscoding = true
                lastUsedDirectStream = false
            } else if (!wantsServerSelect && !forceServerRemux && !forceTranscodeByPolicy && !fragileSeekRemux) {

                newUrl = CoreUrl.getVideoStreamUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
                    mediaSourceId: mediaSourceId, container: StreamRules.containerOrExt(src)
                })
                includeTicks = false
                lastUsedTranscoding = false
                lastUsedDirectStream = false
                isServerRemux = false
            } else {
                remuxAudioCodecLock = _remuxAudioCodecLock(ctx, src, effectiveAudioStreamIndex, true, false, false)

                var fbCont = src ? (CoreUrl._decidePreferredContainerWithSrc(ctx, src) || StreamRules.containerOrExt(src) || "mkv") : "mkv"
                newUrl = CoreUrl.buildProgressiveUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, {
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
        var forcedContainer = ctx.forceMp4 === true ? "mp4" : (mp4ContainerTimelineRisk ? "mkv" : (ctx.preferredContainer || CoreUrl._decidePreferredContainerWithSrc(ctx, src))); var looksLikeHls = (newUrl.indexOf(".m3u8") >= 0) || (newUrl.indexOf("/hls") >= 0)
        var policyTranscode = !!(forceTranscodeByPolicy && lastUsedTranscoding); var dvdSubFileTranscodeActive = !!(forceDvdSubFileTranscode && lastUsedTranscoding && !looksLikeHls)
        var interlacedTsTranscodeActive = !!(forceInterlacedTsTranscode && lastUsedTranscoding && !looksLikeHls)
        // Décision finale de la réinjection du sous-titre forcé : le chemin
        // réellement retenu est connu. Une URL HLS ne peut pas porter de texte
        // embarqué, et une TranscodingUrl Jellyfin conservée n'est jamais
        // réécrite par _forceQuery : l'injection n'y serait pas demandée.
        if (carrySafeFrenchForcedSubtitle) {
            forcedSubtitleStreamFlags.hlsUrl = looksLikeHls
            forcedSubtitleStreamFlags.preserveTranscodingUrl = preserveJellyfinTranscodingUrl
            if (!ForcedSubs.isEmbeddableServerStream(forcedSubtitleStreamFlags)) {
                carrySafeFrenchForcedSubtitle = false
                autoSubtitleEmbedIndex = -1
                subMethodWanted = subMethodBeforeForcedCarry
                forcedSubtitleCarryReason = looksLikeHls ? "hlsStream" : "jellyfinTranscodingUrl"
            }
        }
        var policyTranscodeAudioCodecLock = policyTranscode ? _policyTranscodeAudioCodecHint(ctx, src, effectiveAudioStreamIndex, looksLikeHls) : null
        var policyTranscodeAllowAudioCopy = policyTranscode ? _policyTranscodeAllowAudioCopy(ctx, src, effectiveAudioStreamIndex, looksLikeHls) : true; var policyTranscodeAudioPlan = policyTranscode
                                     ? _audioOutputTranscodePlan(ctx, src, effectiveAudioStreamIndex,
                                         _safeFullTranscodeAudioPlan(src, effectiveAudioStreamIndex, policyTranscodeAudioCodecLock, policyTranscodeAllowAudioCopy)) : null
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
            selectedAudioStream: (isServerRemux || policyTranscode || dvdSubFileTranscodeActive || interlacedTsTranscodeActive || audioOnlyTranscodeActive) ? effectiveAudioStreamIndex : -1,
            selectedSubtitleStream: interlacedTsTranscodeActive ? tsSubtitleIndex
                                    : (dvdSubFileTranscodeActive ? dvdSubTranscodeSubtitleIndex
                                       : (serverExternalTextSubtitle ? -1 : (carrySafeFrenchForcedSubtitle ? safeFrenchForcedSubIndex : ctx.selectedSubtitleStream))),
            useLocalSubs: ctx.useLocalSubs === true, startMs: ctx.startMs,
            playSessionId: (isServerRemux || policyTranscode || dvdSubFileTranscodeActive || interlacedTsTranscodeActive || audioOnlyTranscodeActive || looksLikeHls || ctx.forceServerSeek) ? playSessionId : "",
            preferredContainer: (dvdSubFileTranscodeActive || interlacedTsTranscodeActive || audioOnlyTranscodeActive) ? "mkv" : ((isServerRemux || (policyTranscode && !looksLikeHls)) ? (forcedContainer || "mkv") : null),
            forceServerSeek: !!ctx.forceServerSeek, forceServerRemux: !!isServerRemux,
            forcePolicyTranscode: !!policyTranscode,
            playbackInfoStartTimeTicks: playbackInfoStartTicks,
            preserveJellyfinTranscodingUrl: !!preserveJellyfinTranscodingUrl,
            forceServerTranscode: !!(dvdSubFileTranscodeActive || interlacedTsTranscodeActive || audioOnlyTranscodeActive || policyTranscode || (lastUsedTranscoding && !looksLikeHls)),
            lastUsedTranscoding: !!lastUsedTranscoding, audioCodecHint: interlacedTsTranscodeActive
                            ? "ac3" : (dvdSubFileTranscodeActive
                               ? (dvdAudioCodec || null) : (audioOnlyTranscodeActive
                                  ? (audioOnlyTranscodeCodec || "ac3")
                                  : (forceImageBurnIn ? (imageBurnAudioPlan && imageBurnAudioPlan.codec ? imageBurnAudioPlan.codec : "ac3") : (isServerRemux ? remuxAudioCodecLock : (policyTranscode ? policyTranscodeAudioCodecLock : null))))),
            forceAudioCodecHint: audioOnlyTranscodeActive ? true : (interlacedTsTranscodeActive ? true : (dvdSubFileTranscodeActive ? !!dvdAudioCodec : (forceImageBurnIn ? !!(imageBurnAudioPlan && imageBurnAudioPlan.codec) : (!!remuxAudioCodecLock || !!policyTranscodeAudioCodecLock)))),
            allowRemuxAudioCodecLock: !!remuxAudioCodecLock,
            videoCodecHint: interlacedTsTranscodeActive ? "h264" : (dvdSubFileTranscodeActive ? "h264" : (forceImageBurnIn ? "h264" : (policyTranscode ? (policyTranscodeVideoCodec || "h264") : ((isServerRemux || audioOnlyTranscodeActive) ? _selectedVideoCodec(src) : null)))),
            segmentContainer: (forceImageBurnIn || (policyTranscode && looksLikeHls)) ? "ts" : null, transcodeReasons: interlacedTsTranscodeActive
                              ? "VideoProfileNotSupported" : (dvdSubFileTranscodeActive
                                 ? (dvdSubTranscodeSubtitleIndex >= 0 ? "SubtitleCodecNotSupported" : "ContainerNotSupported") : (audioOnlyTranscodeActive
                                    ? "AudioCodecNotSupported" : (ctx.forceExplicitServerProgressiveSeek === true
                                       ? "ContainerNotSupported" : ((policyTranscode && looksLikeHls) ? "VideoCodecNotSupported" : null)))),
            copyTimestamps: (dvdSubFileTranscodeActive || interlacedTsTranscodeActive || audioOnlyTranscodeActive) ? false : (ctx.forceExplicitServerProgressiveSeek === true ? true : undefined),
            context: (dvdSubFileTranscodeActive || interlacedTsTranscodeActive || audioOnlyTranscodeActive || ctx.forceExplicitServerProgressiveSeek === true) ? "Streaming" : null,
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
                                            ? (dvdAudioChannels || _defaultTranscodingMaxAudioChannels(ctx)) : (audioOnlyTranscodeActive
                                               ? audioOnlyTranscodeChannels : (forceImageBurnIn && imageBurnAudioPlan
                                                  ? imageBurnAudioPlan.channels : (policyTranscodeAudioPlan ? policyTranscodeAudioPlan.channels : null)))),
            audioChannels: interlacedTsTranscodeActive ? tsAudioChannels
                           : (dvdSubFileTranscodeActive ? dvdAudioChannels
                              : (audioOnlyTranscodeActive ? audioOnlyTranscodeChannels
                                 : (forceImageBurnIn && imageBurnAudioPlan ? imageBurnAudioPlan.channels
                                    : (policyTranscodeAudioPlan ? policyTranscodeAudioPlan.channels : null)))), audioBitrate: interlacedTsTranscodeActive
                          ? tsAudioBitrate : (dvdSubFileTranscodeActive
                             ? dvdAudioBitrate : (audioOnlyTranscodeActive
                                ? audioOnlyTranscodeBitrate : (forceImageBurnIn && imageBurnAudioPlan
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
            maxStreamingBitrate: (dvdSubFileTranscodeActive || interlacedTsTranscodeActive || audioOnlyTranscodeActive || forceImageBurnIn || policyTranscode) ? REDEFIN_MAX_STREAMING_BITRATE : null,
            allowAudioStreamCopy: audioOnlyTranscodeActive ? false
                                  : (interlacedTsTranscodeActive ? false
                                     : (dvdSubFileTranscodeActive ? dvdAudioAllowCopy
                                        : (forceImageBurnIn && imageBurnAudioPlan ? imageBurnAudioPlan.allowCopy
                                           : (policyTranscode ? policyTranscodeAllowAudioCopy : true)))),
            allowVideoStreamCopy: audioOnlyTranscodeActive ? true : ((dvdSubFileTranscodeActive || interlacedTsTranscodeActive || forceImageBurnIn || policyTranscode) ? false : true),
            enableAutoStreamCopy: audioOnlyTranscodeActive ? false
                                  : (interlacedTsTranscodeActive ? false
                                     : (dvdSubFileTranscodeActive ? dvdAudioAllowCopy
                                        : (forceImageBurnIn && imageBurnAudioPlan ? imageBurnAudioPlan.allowCopy
                                           : (policyTranscode ? policyTranscodeAllowAudioCopy : true)))),
            enableDirectStream: audioOnlyTranscodeActive ? false : ((dvdSubFileTranscodeActive || interlacedTsTranscodeActive) ? false : (policyTranscode ? false : ((!looksLikeHls && isServerRemux) ? false : ((forceImageBurnIn || imageSubtitleFullRemux) ? false : true)))),
            enableTranscoding: audioOnlyTranscodeActive ? true : ((dvdSubFileTranscodeActive || interlacedTsTranscodeActive) ? true : (policyTranscode ? true : ((!looksLikeHls && isServerRemux) ? true : (imageSubtitleFullRemux ? true : ((!looksLikeHls && !forceImageBurnIn) ? false : true)))))
        }
        var finalSubMethodForQuery = interlacedTsTranscodeActive ? (tsSubtitleIndex >= 0 ? tsSubtitleMethod : null)
                                   : (dvdSubFileTranscodeActive ? dvdSubTranscodeSubtitleMethod
                                      : (serverExternalTextSubtitle ? null
                                      : (carrySafeFrenchForcedSubtitle ? "Embed"
                                         : (forceImageBurnIn ? "Encode"
                                               : (looksLikeHls ? (subMethodWanted || "Hls") : subMethodWanted)))))
        // Verrou final du downmix stéréo, quelle que soit la branche retenue :
        // aucune copie audio, cible AAC-LC 2.0 et plafond de canaux explicites
        // dans l'URL réellement ouverte par QtMultimedia. La vidéo garde la
        // décision de sa branche (copie si elle est compatible).
        // Le choix 2.0 reste explicite sur tous les chemins serveur.
        if (stereoDownmixAudio) {
            ctxForQuery.audioOutputStereoDownmix = true
            ctxForQuery.audioCodecHint = audioOutputPlan.codec
            ctxForQuery.forceAudioCodecHint = true
            ctxForQuery.allowRemuxAudioCodecLock = false
            ctxForQuery.allowAudioStreamCopy = false
            ctxForQuery.enableAutoStreamCopy = false
            ctxForQuery.transcodingMaxAudioChannels = audioOutputPlan.channels
            ctxForQuery.audioChannels = audioOutputPlan.channels
            ctxForQuery.audioBitrate = audioOutputPlan.bitrate
            ctxForQuery.forceServerTranscode = true
        }

        // Pour le downmix stéréo Devialet en HLS, PlaybackInfo vient déjà de faire
        // construire par Jellyfin une TranscodingUrl complète. Ne jamais la
        // réécrire ensuite : les paramètres HLS (Tag, SegmentContainer, profil,
        // segmentation, PlaySessionId...) forment ensemble le contrat du job
        // généré par StreamBuilder. Les anciens correctifs rajoutaient notamment
        // AudioChannels/StartTimeTicks/EnableAutoStreamCopy après coup, ce qui
        // pouvait faire ouvrir à QtMultimedia une variante différente du job
        // préparé et aboutir immédiatement à MediaError.
        var keepStereoServerTranscodingUrlVerbatim = !!(stereoDownmixAudio &&
            preserveJellyfinTranscodingUrl)
        if (keepStereoServerTranscodingUrlVerbatim) {
            // Le Player ne sait pas fournir un header d'authentification à la source
            // média. Hormis la canonicalisation de la clé API, garder STRICTEMENT le
            // job HLS généré par Jellyfin. Le codec, le bitrate, la segmentation, le
            // Tag et les paramètres de session ont déjà été décidés par StreamBuilder
            // à partir du DeviceProfile du POST PlaybackInfo. Les modifier ici peut
            // désynchroniser master.m3u8 et le job enfant et provoquer MediaError.
            newUrl = CoreUrl._canonicalizePlaybackAuthOnly(newUrl, ctx.accessToken)
        } else {
            newUrl = CoreUrl._forceQuery( newUrl,
                ctxForQuery, finalSubMethodForQuery,
                includeTicks )
        }

        // Une URL média complète peut dépasser 512 caractères. Elle doit être
        // validée comme ressource de lecture, pas comme simple URL serveur.
        if (!newUrl || !/[?&]ApiKey=/i.test(newUrl)) {
            delete _inFlightWaiters[key]

            if (onError) onError("invalid_playback_url")
            return
        }
        if (!CoreUrl._transportValidatePlaybackUrlStrict(newUrl, ctx.serverUrl)) {
            delete _inFlightWaiters[key]

            if (onError) onError("invalid_playback_url")
            return
        }
        // Jellyfin n'inclut pas toujours StartTimeTicks dans ToUrl() pour HLS.
        // Les qualités manuelles restent déroutées vers le progressif ; le
        // downmix Devialet T14 est une exception contrôlée avec seek local.
        // Ailleurs, un HLS non positionnable côté serveur est refusé.
        // Pour HLS, la preuve de la timeline serveur doit être portée par l'URL
        // finale réellement donnée à QtMultimedia, pas seulement par le POST
        // PlaybackInfo. Cela évite de déclarer serverTimed=true alors que le job
        // FFmpeg repart en réalité de zéro.
        if (looksLikeHls && ctx.forceServerSeek === true && ctx.startMs > 0) {
            var finalHlsHasStartTimeTicks = /(?:[?&])StartTimeTicks=[1-9][0-9]*/i.test(newUrl)
            includeTicks = finalHlsHasStartTimeTicks

        }

        // Devialet stereo HLS : conserver l'URL intacte en cas de seek local.
        // Les autres pipelines gardent leur comportement forceServerSeek.
        if (looksLikeHls && ctx.forceServerSeek === true && ctx.startMs > 0 && !includeTicks &&
                !stereoHlsClientSeekAfterOpen && !stereoHlsUrlSeekVerified) {

            delete _inFlightWaiters[key]

            if (onError) onError("hls_seek_requires_progressive")
            return
        }
        var externalSub = null
        if (serverExternalTextSubtitle && !looksLikeHls && mediaSourceId && typeof ctx.selectedSubtitleStream === "number") {
            externalSub = {
                urlSrt: CoreUrl._subtitleResultUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, mediaSourceId, ctx.selectedSubtitleStream, "srt"),
                urlVtt: CoreUrl._subtitleResultUrl(ctx.serverUrl, ctx.accessToken, ctx.itemId, mediaSourceId, ctx.selectedSubtitleStream, "vtt"),
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
                                     (subMethodWanted ? String(subMethodWanted).toLowerCase() : (isHls ? "hls" : "embed")))
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
        // En DirectPlay statique, Jellyfin ne porte pas forcément les index de
        // pistes dans l'URL : QtMultimedia choisit alors directement dans le
        // conteneur. On expose ce choix natif à l'UI uniquement, sans modifier
        // la source ni déclencher une nouvelle négociation.
        var pureStaticDirectPlay = !isServerRemux && !isHls &&
                !lastUsedTranscoding && !lastUsedDirectStream
        if (pureStaticDirectPlay) {
            if (effectiveSubtitleStreamIndex < 0 && ctx.useLocalSubs !== true &&
                    !serverExternalTextSubtitle) {
                var nativeDpSubtitleIndex = StreamRules.nativeDirectPlaySubtitleIndex(src)
                if (nativeDpSubtitleIndex >= 0) {
                    effectiveSubtitleStreamIndex = nativeDpSubtitleIndex
                    effectiveSubtitleMode = "directplay"
                    effectiveSubtitleReason = "nativeDirectPlayFirstInternal"
                }
            }
        }
        // Un forceServerSeek doit toujours prendre le pas sur le cold-start local.
        // Sinon un HLS correctement reconstruit avec StartTimeTicks serait encore
        // marqué pour un seek local après ouverture, ce qui annulerait le bénéfice
        // de la reprise serveur et peut figer QtMultimedia sur Freebox.
        var policyHlsColdLocalSeek = !!(policyTranscode && isHls && policyTranscodeHlsColdStart &&
                                        ctx.startMs > 0 && ctx.forceServerSeek !== true)
        // T14 : pas de base temporelle inventee depuis PlaybackInfo.
        // Sans StartTimeTicks verifiable dans le manifeste utilise, la reprise
        // Devialet 2.0 est un vrai seek local et son offset UI reste nul.
        var hasServerTimeBase = !!(includeTicks && ctx.startMs > 0)
        var serverTimed = hasServerTimeBase && !policyHlsColdLocalSeek && (isHls || lastUsedDirectStream || lastUsedTranscoding || ctx.forceServerSeek === true || isServerRemux)
        if (stereoHlsClientSeekAfterOpen) serverTimed = false
        var initialLocalSeek = policyHlsColdLocalSeek ? Math.floor(ctx.startMs) : (serverTimed ? 0 : ((ctx.startMs > 0) ? Math.floor(ctx.startMs) : -1))
        var result = {
            url: newUrl, playSessionId: playSessionId,
            mediaSourceId: mediaSourceId, isHls: isHls,
            lastUsedTranscoding: lastUsedTranscoding, lastUsedDirectStream: lastUsedDirectStream,
            lastUsedServerRemux: isServerRemux, includeTicks: hasServerTimeBase,
            devialetStereoHlsNeedsLocalSeek: (_devicePolicyId === "devialet" && stereoHlsClientSeekAfterOpen),
            devialetStereoProgressiveDownmix: (_devicePolicyId === "devialet" && stereoDownmixAudio && audioOnlyTranscodeActive && !isHls),
            streamBaseMs: serverTimed ? Math.floor(ctx.startMs) : 0, initialLocalSeekMs: initialLocalSeek,
            serverTimedStream: serverTimed, timeShifted: serverTimed,
            subMethod: interlacedTsTranscodeActive ? (tsSubtitleIndex >= 0 ? "encode" : "none")
                       : (dvdSubFileTranscodeActive ? (dvdSubTranscodeSubtitleMethod ? String(dvdSubTranscodeSubtitleMethod).toLowerCase() : "none")
                          : (forceImageBurnIn ? "encode" : (serverExternalTextSubtitle ? "external" : (subMethodWanted ? String(subMethodWanted).toLowerCase() : "none")))),
            externalSubtitle: externalSub, forceLocalSubs: (ctx.useLocalSubs === true),
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
            firstInternalSubtitleStreamIndex: StreamRules.firstInternalSubtitleStreamIndex(src), defaultFrenchAudioNotFirst: defaultFrenchAudioNotFirst,
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
            policyTranscodeAudioCopy: policyTranscodeAllowAudioCopy, trueHd51AudioOnlyTranscode: !!(audioOnlyTranscodeActive && forceTrueHd51AudioTranscode),
            trueHdMultichannelAudioOnlyTranscode: !!(audioOnlyTranscodeActive && forceTrueHd51AudioTranscode),
            audioOnlyTranscode: !!audioOnlyTranscodeActive,
            trueHd51AudioStreamIndex: (audioOnlyTranscodeActive && forceTrueHd51AudioTranscode) ? effectiveAudioStreamIndex : -1,
            trueHd51TargetAudioCodec: audioOnlyTranscodeActive ? (audioOnlyTranscodeCodec || "ac3") : "",
            trueHd51TargetAudioChannels: audioOnlyTranscodeActive ? audioOnlyTranscodeChannels : 0,
            trueHd51TargetAudioBitrate: audioOnlyTranscodeActive ? audioOnlyTranscodeBitrate : 0,
            audioOutputMode: audioOutputPlan.mode, audioOutputStereoDownmix: !!stereoDownmixAudio,
            audioOutputSourceChannels: audioOutputPlan.sourceChannels, audioOutputStreamIndex: audioOutputStreamIndex,
            finalUrlKind: isHls ? "hls" : ((dvdSubFileTranscodeActive || interlacedTsTranscodeActive || audioOnlyTranscodeActive || policyTranscode) ? "http-transcode" : (isServerRemux ? "http-remux" : "http-dp")),
            sourceVideoCodec: _sourceVideoCodec(src), sourceContainer: _s(src && src.Container).toLowerCase(),
            sourceVideoBitrate: _sourceVideoBitrate(src),
            sourceVideoIsHevcMain10: _isHevcMain10Source(src),
            sourceVideoProfile: _s((StreamRules.firstStream(src, "Video") || {}).Profile || ""),
            sourceVideoLevel: _s((StreamRules.firstStream(src, "Video") || {}).Level !== undefined ? (StreamRules.firstStream(src, "Video") || {}).Level : ""),
            sourceVideoBitDepth: _numSafe((StreamRules.firstStream(src, "Video") || {}).BitDepth),
            sourceVideoPixelFormat: _s((StreamRules.firstStream(src, "Video") || {}).PixelFormat || ""),
            sourceVideoWidth: _numSafe((StreamRules.firstStream(src, "Video") || {}).Width),
            sourceVideoHeight: _numSafe((StreamRules.firstStream(src, "Video") || {}).Height),
            sourceVideoFrameRate: _rateSafe(StreamRules.firstStream(src, "Video"))
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
