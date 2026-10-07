// qml/js/AudioOutputPolicy.js
// Politique pure de la sortie audio ReDeFin (réglage « Sortie audio »).
//
// Deux modes seulement :
//   - "multichannel" (défaut) : comportement historique, aucune contrainte
//     ajoutée à la négociation. La policy matérielle décide comme auparavant.
//   - "stereo" : l'installation de l'utilisateur est stéréo. On demande au
//     SERVEUR de faire le mixage, afin que Jellyfin applique son amplification
//     de downmix et son algorithme stéréo (dialogues plus audibles) au lieu de
//     laisser le boîtier/téléviseur réduire un 5.1 brut.
//
// Règle unique : on n'engage un transcodage audio QUE si la piste réellement
// envoyée au serveur a plus de 2 canaux. Une piste déjà stéréo/mono reste en
// copie (ou en lecture directe) exactement comme en mode multicanal, et un
// nombre de canaux inconnu ne déclenche jamais de transcodage — seul le
// plafond annoncé au serveur (MaxAudioChannels = 2) reste posé.
//
// Module pur : pas d'état global mutable, aucune dépendance Qt, ES5.

.pragma library

var MODE_MULTICHANNEL = "multichannel";
var MODE_STEREO = "stereo";

// Cible de transcodage SERVEUR : AAC-LC 2.0, mixage effectué par Jellyfin.
// L'API Jellyfin désigne cette cible par AudioCodec="aac". Jellyfin-ffmpeg
// choisit ensuite son encodeur AAC disponible (libfdk_aac lorsqu'il est présent,
// sinon l'encodeur AAC natif). Aucun profil HE-AAC/HE-AACv2 n'est demandé :
// la cible attendue est donc le profil AAC-LC standard, particulièrement adapté
// à une sortie stéréo de haute qualité et largement compatible.
// Le débit suit la piste audio source afin de ne pas gonfler artificiellement
// un flux déjà encodé à un débit inférieur. Les sources très haut débit
// (TrueHD, DTS-HD, AC-3 640 kb/s...) sont plafonnées à 384 kb/s, marge très
// confortable pour de l'AAC-LC stéréo. Si Jellyfin ne fournit aucun bitrate,
// 256 kb/s sert de repli sûr.
var STEREO_CHANNELS = 2;
var STEREO_CODEC = "aac";
var STEREO_DEFAULT_BITRATE = 256000;
var STEREO_MAX_BITRATE = 384000;
// Alias conservé pour compatibilité avec d'éventuels appels historiques.
// Ce n'est plus une cible fixe : la policy utilise stereoBitrateForStream().
var STEREO_BITRATE = STEREO_DEFAULT_BITRATE;

/** Normalise une valeur de réglage ; toute valeur inconnue retombe sur le défaut. */
function normalizeMode(value) {
    var mode = "";
    try {
        mode = (value === undefined || value === null) ? "" : String(value).toLowerCase().trim();
    } catch (e) {
        mode = "";
    }
    if (mode === MODE_STEREO || mode === "stereo2" || mode === "2.0" || mode === "downmix") {
        return MODE_STEREO;
    }
    return MODE_MULTICHANNEL;
}

/** true si le mode demande un mixage stéréo côté serveur. */
function isStereo(mode) {
    return normalizeMode(mode) === MODE_STEREO;
}

/**
 * Nombre de canaux d'une piste audio Jellyfin.
 * Accepte un objet MediaStream ou directement un nombre.
 * Renvoie 0 quand l'information est absente ou inexploitable.
 */
function _channelsFromLayout(audioStream) {
    if (!audioStream || typeof audioStream !== "object") return 0;
    var layout = "";
    try {
        layout = String(audioStream.ChannelLayout || audioStream.channelLayout || "").toLowerCase().trim();
    } catch (e) {
        return 0;
    }
    if (!layout) return 0;

    // Jellyfin peut renvoyer Channels=2 après application de MaxAudioChannels
    // tout en conservant le ChannelLayout original (ex. 5.1). Pour décider si
    // la SOURCE doit être downmixée, on ne doit pas perdre cette information.
    if (layout.indexOf("7.1") === 0) return 8;
    if (layout.indexOf("6.1") === 0) return 7;
    if (layout.indexOf("5.1") === 0) return 6;
    if (layout.indexOf("5.0") === 0) return 5;
    if (layout.indexOf("4.1") === 0) return 5;
    if (layout.indexOf("4.0") === 0 || layout === "quad" || layout.indexOf("quad(") === 0) return 4;
    if (layout.indexOf("3.1") === 0) return 4;
    if (layout.indexOf("3.0") === 0 || layout.indexOf("2.1") === 0) return 3;
    if (layout.indexOf("2.0") === 0 || layout === "stereo") return 2;
    if (layout.indexOf("1.0") === 0 || layout === "mono") return 1;
    return 0;
}

function channelsOf(audioStream) {
    var raw = null;
    if (audioStream === undefined || audioStream === null) return 0;
    if (typeof audioStream === "number" || typeof audioStream === "string") raw = audioStream;
    else {
        try {
            raw = (audioStream.Channels !== undefined && audioStream.Channels !== null)
                ? audioStream.Channels : audioStream.channels;
        } catch (e) {
            raw = null;
        }
    }

    var explicitChannels = 0;
    if (raw !== undefined && raw !== null && raw !== "") {
        explicitChannels = parseInt(String(raw), 10);
        if (!isFinite(explicitChannels) || explicitChannels <= 0) explicitChannels = 0;
        else explicitChannels = Math.floor(explicitChannels);
    }

    var layoutChannels = _channelsFromLayout(audioStream);
    return Math.max(explicitChannels, layoutChannels);
}

/** Débit audio brut annoncé par Jellyfin pour la piste, ou 0 si inconnu. */
function bitrateOf(audioStream) {
    if (!audioStream || typeof audioStream !== "object") return 0;
    var raw = null;
    try {
        if (audioStream.BitRate !== undefined && audioStream.BitRate !== null) raw = audioStream.BitRate;
        else if (audioStream.bitRate !== undefined && audioStream.bitRate !== null) raw = audioStream.bitRate;
        else if (audioStream.Bitrate !== undefined && audioStream.Bitrate !== null) raw = audioStream.Bitrate;
        else raw = audioStream.bitrate;
    } catch (e) {
        raw = null;
    }
    if (raw === undefined || raw === null || raw === "") return 0;
    var n = parseInt(String(raw), 10);
    if (!isFinite(n) || n <= 0) return 0;
    return Math.floor(n);
}

/**
 * Cible du downmix AAC-LC 2.0 : même débit que la piste source lorsque connu,
 * avec plafond 384 kb/s et repli 256 kb/s si le serveur n'annonce rien.
 */
function stereoBitrateForStream(audioStream) {
    var sourceBitrate = bitrateOf(audioStream);
    if (sourceBitrate <= 0) return STEREO_DEFAULT_BITRATE;
    return Math.min(sourceBitrate, STEREO_MAX_BITRATE);
}

/** Plafond de canaux annoncé au serveur : 2 en stéréo, 0 (= aucun) sinon. */
function maxChannels(mode) {
    return isStereo(mode) ? STEREO_CHANNELS : 0;
}

/**
 * Abaisse un nombre de canaux déjà calculé par un chemin de transcodage
 * existant (TS entrelacé, DVD, burn-in...) au plafond du mode.
 * Un nombre inconnu (0) reste inconnu : ce n'est pas à cette fonction
 * d'inventer une valeur.
 */
function capChannels(mode, channels) {
    var n = channelsOf(channels);
    if (n <= 0) return channels;
    if (!isStereo(mode)) return n;
    return Math.min(n, STEREO_CHANNELS);
}

/**
 * Plan audio de la piste effectivement envoyée au serveur.
 *
 * @param mode         valeur du réglage « Sortie audio »
 * @param audioStream  MediaStream Jellyfin de la piste retenue (ou son nombre
 *                     de canaux), éventuellement absent
 * @return { mode, sourceChannels, downmix, channels, codec, bitrate, maxChannels }
 *         downmix=true  -> il faut un flux serveur dont l'audio est transcodé
 *                          en codec/channels/bitrate ci-dessus, la vidéo
 *                          restant copiée si elle est compatible ;
 *         downmix=false -> comportement strictement identique à aujourd'hui.
 */
function plan(mode, audioStream) {
    var normalized = normalizeMode(mode);
    var sourceChannels = channelsOf(audioStream);
    var stereo = (normalized === MODE_STEREO);
    var downmix = stereo && sourceChannels > STEREO_CHANNELS;
    var out = {
        mode: normalized,
        sourceChannels: sourceChannels,
        downmix: downmix,
        channels: downmix ? STEREO_CHANNELS : 0,
        codec: downmix ? STEREO_CODEC : "",
        bitrate: downmix ? stereoBitrateForStream(audioStream) : 0,
        maxChannels: stereo ? STEREO_CHANNELS : 0
    };
    return out;
}

/** Résumé compact d'un plan audio. */
function describe(p) {
    if (!p) return "audio-plan=none";
    return "mode=" + p.mode +
           " srcCh=" + p.sourceChannels +
           " downmix=" + (p.downmix ? "1" : "0") +
           " codec=" + (p.codec || "-") +
           " ch=" + (p.channels || 0) +
           " br=" + (p.bitrate || 0) +
           " maxCh=" + (p.maxChannels || 0);
}
