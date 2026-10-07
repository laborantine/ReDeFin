// qml/js/ForcedSubtitlePolicy.js
// Politique pure de RÉINJECTION du sous-titre FORCÉ français dans un flux
// serveur (« carry safe French forced subtitle »).
//
// Intention de la règle, héritée de l'upstream : quand ReDeFin quitte la
// lecture directe, la piste de sous-titres forcés française (les passages en
// langue étrangère) disparaît, parce que Jellyfin ne remet aucun sous-titre
// dans le flux qu'il fabrique tant que le client n'en demande pas un
// explicitement. La règle la redemande donc au serveur avec
// SubtitleStreamIndex=<piste forcée>&SubtitleMethod=Embed, ce qui produit un
// « -map 0:<n> -codec:s:0 copy -disposition:s:0 default » côté ffmpeg.
//
// Le défaut corrigé ici : l'upstream conditionnait cette réinjection au seul
// drapeau forceServerRemux. Le même fichier perdait donc ses sous-titres
// forcés en transcodage de politique (lecture initiale) et les retrouvait
// après un changement de piste audio ou en sortie stéréo. La décision porte
// désormais sur le FAIT que le flux final est un flux serveur capable
// d'embarquer du texte, quel que soit le chemin technique emprunté.
//
// Module pur : pas d'état global mutable, aucune dépendance Qt, ES5.

.pragma library

var METHOD_EMBED = "Embed";

function _flag(v) { return v === true; }
function _index(v) {
    var n = Number(v);
    if (!isFinite(n)) return -1;
    n = Math.floor(n);
    return n >= 0 ? n : -1;
}

/**
 * Le flux final peut-il embarquer une piste de sous-titres TEXTE du serveur ?
 *
 * Vrai pour un remux progressif, un transcodage audio seul et un transcodage
 * vidéo progressif (conteneur MKV). Faux pour tout ce qui ne sait pas, ou ne
 * doit pas, porter un SubRip embarqué :
 *
 *   - hlsUrl / mustHls / policyTranscodeHls : en HLS/TS, Jellyfin ne sait pas
 *     copier du texte dans les segments ; « Embed » y serait au mieux ignoré,
 *     au pire converti en incrustation ;
 *   - preserveTranscodingUrl : la TranscodingUrl fabriquée par Jellyfin est
 *     conservée telle quelle, aucun paramètre de piste n'y est réécrit ;
 *     demander l'injection produirait une coche d'interface mensongère ;
 *   - dvdSubtitleTranscode : le transcodage « DVDSub dormant » choisit
 *     lui-même sa piste (incrustation de la piste forcée DVD). Ce chemin garde
 *     exactement le comportement historique, donc il ne suit la règle que
 *     lorsqu'un remux serveur l'accompagnait déjà.
 *
 * @param {object} flags serverRemux, policyTranscode, policyTranscodeHls,
 *        serverSelect, mustHls, hlsUrl, preserveTranscodingUrl,
 *        dvdSubtitleTranscode.
 * @returns {boolean}
 */
function isEmbeddableServerStream(flags) {
    if (!flags) return false;
    if (_flag(flags.hlsUrl) || _flag(flags.mustHls)) return false;
    if (_flag(flags.policyTranscode) && _flag(flags.policyTranscodeHls)) return false;
    if (_flag(flags.preserveTranscodingUrl)) return false;
    if (_flag(flags.dvdSubtitleTranscode)) return _flag(flags.serverRemux);
    return _flag(flags.serverRemux) || _flag(flags.policyTranscode) || _flag(flags.serverSelect);
}

/**
 * Décide la réinjection du sous-titre forcé français.
 *
 * @param {object} input
 *        smartRules            règles ReDeFin actives (mode « Original » = faux)
 *        serverStream          résultat de isEmbeddableServerStream()
 *        forcedIndex           index de la piste forcée française, -1 si aucune
 *        forcedIsText          cette piste est du TEXTE (SubRip/ASS/VTT...)
 *        useLocalSubs          overlay QML local en cours
 *        explicitSubtitleIndex sous-titre choisi par l'utilisateur, -1 si aucun
 *        explicitSubtitlesOff  l'utilisateur a explicitement choisi « Aucun »
 *        imageBurnIn           incrustation serveur d'un sous-titre image
 *        imageRemux            sous-titre image embarqué dans un remux
 *        textSubtitleSelected  sous-titre texte choisi par l'utilisateur
 *        serverExternalSubtitle sidecar texte servie par Jellyfin
 *        internalSubtitleRisk  HEVC Main10 + E-AC3 + sous-titre interne
 * @returns {{carry: boolean, index: number, method: (string|null), reason: string}}
 */
function decideCarry(input) {
    var i = input || {};
    var reason = "";

    if (!_flag(i.smartRules)) reason = "originalMode";
    else if (_flag(i.explicitSubtitlesOff)) reason = "explicitOff";
    else if (_index(i.explicitSubtitleIndex) >= 0) reason = "explicitSubtitle";
    else if (_flag(i.useLocalSubs)) reason = "localSubtitles";
    else if (_index(i.forcedIndex) < 0) reason = "noForcedSubtitle";
    else if (!_flag(i.forcedIsText)) reason = "forcedSubtitleNotText";
    else if (_flag(i.imageBurnIn)) reason = "imageBurnIn";
    else if (_flag(i.imageRemux)) reason = "imageRemux";
    else if (_flag(i.textSubtitleSelected)) reason = "textSubtitleSelected";
    else if (_flag(i.serverExternalSubtitle)) reason = "serverExternalSubtitle";
    else if (_flag(i.internalSubtitleRisk)) reason = "internalSubtitleRisk";
    // En dernier, afin que la trace nomme d'abord la raison liée au contenu ou
    // au choix de l'utilisateur, et seulement ensuite le chemin technique.
    else if (!_flag(i.serverStream)) reason = "notServerStream";

    if (reason) return { carry: false, index: -1, method: null, reason: reason };
    return { carry: true, index: _index(i.forcedIndex), method: METHOD_EMBED, reason: "serverStream" };
}

