.pragma library

/* MediaCatalog.js
 * Transformations pures du catalogue Jellyfin.
 * Aucun accès réseau, aucun état QML, aucun Timer et aucune logique de focus/player.
 * Les fonctions reçoivent leurs données et retournent uniquement des valeurs dérivées.
 */

function _catalogPad2(value) {
    var n = Number(value) || 0;
    return (n < 10 ? "0" : "") + n;
}
function _catalogDateLong(value) {
    var s = (value === undefined || value === null) ? "" : String(value);
    if (s.length < 10) return "";
    var year = parseInt(s.substr(0, 4), 10);
    var month = parseInt(s.substr(5, 2), 10);
    var day = parseInt(s.substr(8, 2), 10);
    if (!year || month < 1 || month > 12 || day < 1 || day > 31) return "";
    var months = ["janv.", "févr.", "mars", "avr.", "mai", "juin",
                  "juil.", "août", "sept.", "oct.", "nov.", "déc."];
    return day + " " + months[month - 1] + " " + year;
}

function fmtDurationMinutes(totalMin) {
    var m = Math.floor(Number(totalMin) || 0);
    if (m <= 0) return "";
    if (m < 60) return m + " min";
    var h = Math.floor(m / 60), r = m % 60;
    return r > 0 ? (h + "h " + r + "m") : (h + "h");
}
function formatDurationHms(totalSeconds) {
    totalSeconds = Math.max(0, Math.floor(Number(totalSeconds) || 0));
    var h = Math.floor(totalSeconds / 3600);
    var m = Math.floor((totalSeconds % 3600) / 60);
    var sec = totalSeconds % 60;
    return h + ":" + _catalogPad2(m) + ":" + _catalogPad2(sec);
}
function mediaAgeTag(it) {
    if (!it) return "";
    var r = String(it.OfficialRating || it.CustomRating || "").replace(/^\s+|\s+$/g, "");
    if (!r) return "";
    var m = r.match(/(\d{1,2})/);
    return m ? ("Âge: " + m[1] + "+") : r;
}
function formatDateShortFr(value) {
    return _catalogDateLong(value);
}
function formatDateLongFr(value) {
    return _catalogDateLong(value);
}
function mediaTicksToSeconds(ticks) {
    var value = Number(ticks || 0);
    return value > 0 ? Math.floor(value / 10000000) : 0;
}
function formatRuntimeMinutesFromTicks(ticks) {
    var ms = Math.round(Number(ticks || 0) / 10000);
    if (!ms) return "";
    var seconds = Math.round(ms / 1000);
    return Math.floor(seconds / 60) + " min";
}
function formatTicksToHhMm(ticks) {
    var totalSec = mediaTicksToSeconds(ticks);
    if (!totalSec) return "";
    var hours = Math.floor(totalSec / 3600);
    var minutes = Math.floor((totalSec % 3600) / 60);
    if (hours > 0)
        return hours + " h " + _catalogPad2(minutes);
    return minutes + " min";
}
function formatEndClockFromTicks(ticks) {
    var value = Number(ticks || 0);
    if (value <= 0) return "";
    var date = new Date(Date.now() + Math.floor(value / 10000));
    return _catalogPad2(date.getHours()) + ":" + _catalogPad2(date.getMinutes());
}
function formatEndTimeFromTicks(ticks) {
    var ms = Math.round(Number(ticks || 0) / 10000);
    if (!ms) return "";
    var end = new Date(Date.now() + ms);
    return _catalogPad2(end.getHours()) + ":" + _catalogPad2(end.getMinutes());
}
function seriesYearFromDateLike(value) {
    if (value === undefined || value === null) return "";
    var text = safeString(value);
    if (text.length >= 4) {
        var year = parseInt(text.substr(0, 4), 10);
        if (year > 1800 && year < 2500) return String(year);
    }
    var numeric = Number(value || 0);
    return numeric > 1800 && numeric < 2500 ? String(Math.floor(numeric)) : "";
}
function seriesYearRangeParts(item, seasons, ended) {
    var start = "", end = "";
    if (item) {
        start = seriesYearFromDateLike(item.ProductionYear)
                || seriesYearFromDateLike(item.PremiereDate || item.StartDate || item.DateCreated);
        end = seriesYearFromDateLike(item.EndDate || item.DateEnded || item.EndYear);
    }
    if (!end && ended && seasons && seasons.length) {
        var best = 0;
        for (var i = 0; i < seasons.length; ++i) {
            var season = seasons[i];
            var value = seriesYearFromDateLike(season && (season.ProductionYear || season.PremiereDate));
            var numeric = Number(value || 0);
            if (numeric > best) best = numeric;
        }
        if (best > 0) end = String(best);
    }
    return { start:start, end:end };
}
function mediaCodecLabel(codec) {
    var c = String(codec || "").toLowerCase();
    if (c === "hevc" || c === "h265" || c === "h.265") return "HEVC";
    if (c === "h264" || c === "h.264" || c === "avc") return "H.264";
    if (c === "av1") return "AV1";
    if (c === "vp9") return "VP9";
    if (c === "mpeg2video" || c === "mpeg2") return "MPEG-2";
    if (c === "ac3") return "DD";
    if (c === "eac3" || c === "e-ac3") return "DD+";
    if (c === "dca" || c === "dts") return "DTS";
    if (c === "truehd") return "TRUEHD";
    if (c === "aac") return "AAC";
    if (c === "flac") return "FLAC";
    if (c === "opus") return "OPUS";
    if (c === "mp3") return "MP3";
    return c ? c.toUpperCase() : "";
}
function mediaChannelLabel(stream) {
    var layout = String(stream && stream.ChannelLayout ? stream.ChannelLayout : "");
    if (layout.indexOf("7.1") >= 0) return "7.1";
    if (layout.indexOf("5.1") >= 0) return "5.1";
    var ch = stream && stream.Channels ? Number(stream.Channels) : 0;
    if (ch === 8) return "7.1";
    if (ch === 6) return "5.1";
    if (ch === 2) return "2.0";
    if (ch === 1) return "1.0";
    return ch > 0 ? (ch + ".0") : "";
}
function mediaRuntimeMinutes(it) {
    if (!it) return 0;
    if (it.RunTimeTicks) return Math.max(0, Math.round(Number(it.RunTimeTicks) / 600000000));
    if (it.AverageRuntime) return Math.max(0, Math.round(Number(it.AverageRuntime)));
    if (it.Runtime) {
        var m = String(it.Runtime).match(/(\d+)/);
        return m ? Math.max(0, Number(m[1]) || 0) : 0;
    }
    return 0;
}
function mediaRuntimeSeconds(it) {
    if (!it) return 0;
    if (it.RunTimeTicks) return Math.max(0, Math.round(Number(it.RunTimeTicks) / 10000000));
    if (it.RunTimeSeconds) return Math.max(0, Math.round(Number(it.RunTimeSeconds)));
    if (it.AverageRuntime) return Math.max(0, Math.round(Number(it.AverageRuntime) * 60));
    if (it.Runtime) {
        var m = String(it.Runtime).match(/(\d+)/);
        return m ? Math.max(0, Math.round(Number(m[1]) * 60)) : 0;
    }
    var min = mediaRuntimeMinutes(it);
    return min > 0 ? min * 60 : 0;
}
function _mediaFrenchAudioFlavor(stream) {
    var lang = String(stream && stream.Language !== undefined && stream.Language !== null ? stream.Language : "").toLowerCase();
    var label = String(stream && (stream.DisplayTitle || stream.Title || stream.Name) || "").toLowerCase();
    var all = lang + " " + label;
    var isFr = lang === "fr" || lang === "fra" || lang === "fre" ||
            all.indexOf("french") >= 0 || all.indexOf("français") >= 0 || all.indexOf("francais") >= 0 ||
            all.indexOf("vff") >= 0 || all.indexOf("vfq") >= 0 ||
            all.indexOf("truefrench") >= 0 || all.indexOf("true french") >= 0;
    if (!isFr) return "";
    if (all.indexOf("vfq") >= 0 || all.indexOf("québec") >= 0 || all.indexOf("quebec") >= 0 || all.indexOf("canad") >= 0) return "FR-QC";
    if (all.indexOf("truefrench") >= 0 || all.indexOf("true french") >= 0 || all.indexOf("vff") >= 0 || all.indexOf("france") >= 0) return "FR-TP";
    return "FR";
}
function _pushUniqueUpper(list, value) {
    var v = String(value === undefined || value === null ? "" : value).toUpperCase();
    if (v && list.indexOf(v) < 0) list.push(v);
}
// Resolution commune aux affiches et aux fiches. Combiner largeur et hauteur :
// les films cinemas 3840x1608 restent 4K, 1920x800 restent 1080p,
// mais un 2560x1080 ultralarge ne doit pas devenir artificiellement 1440p.
function mediaVideoResolutionLabel(width, height) {
    var w = Math.max(0, Number(width) || 0);
    var h = Math.max(0, Number(height) || 0);
    if (w >= 3800 || h >= 2000) return "4K";
    if (h >= 1350 || (w >= 2500 && h >= 1200)) return "1440p";
    if (w >= 1900 || h >= 1000) return "1080p";
    if (w >= 1200 || h >= 700) return "720p";
    if (w >= 700 || h >= 450) return "480p";
    if (h > 0) return Math.floor(h) + "p";
    return w > 0 ? Math.floor(w) + "p" : "";
}
function movieStreamInfo(it) {
    var out = { res:"", vcodec:"", acodec:"", channels:"", audioProfile:"", multiAudio:"", subs:"" };
    var source = it && it.MediaSources && it.MediaSources.length ? it.MediaSources[0] : null;
    var streams = (it && it.MediaStreams && it.MediaStreams.length) ? it.MediaStreams
                : (source && source.MediaStreams ? source.MediaStreams : []);
    var audioLangs = [], subLangs = [], hasSubtitle = false;
    var video = null, audio = null;
    for (var i = 0; streams && i < streams.length; i++) {
        var st = streams[i];
        if (!st) continue;
        var typ = mediaStreamTypeLower(st);
        if (typ === "video" && (!video || (!video.IsDefault && st.IsDefault))) video = st;
        else if (typ === "audio") {
            if (!audio || (!audio.IsDefault && st.IsDefault)) audio = st;
            _pushUniqueUpper(audioLangs, st.Language);
        } else if (typ === "subtitle") {
            hasSubtitle = true;
            _pushUniqueUpper(subLangs, st.Language);
        }
    }
    if (video) {
        out.res = mediaVideoResolutionLabel(video.Width, video.Height);
        out.vcodec = mediaCodecLabel(video.Codec);
    }
    if (audio) {
        out.audioProfile = _mediaFrenchAudioFlavor(audio);
        out.acodec = mediaCodecLabel(audio.Codec);
        out.channels = mediaChannelLabel(audio);
    }
    if (audioLangs.length > 1) out.multiAudio = "AUDIO: " + audioLangs.join("/");
    if (subLangs.length > 0) out.subs = "ST: " + subLangs.join("/");
    else if (hasSubtitle) out.subs = "ST";
    return out;
}
function mediaContainerLabel(value) {
    var v = String(value || "").toLowerCase().replace(/^\./, "");
    if (v === "jpg" || v === "jpeg") return "JPEG";
    if (v === "png") return "PNG";
    if (v === "webp") return "WEBP";
    if (v === "heic" || v === "heif") return "HEIC";
    if (v === "mkv" || v === "matroska") return "MKV";
    if (v === "mp4" || v === "m4v") return "MP4";
    if (v === "mov" || v === "quicktime") return "MOV";
    if (v === "webm") return "WEBM";
    if (v === "avi") return "AVI";
    if (v === "m2ts") return "M2TS";
    if (v === "ts" || v === "mpegts") return "TS";
    return v ? v.toUpperCase() : "";
}
function personalMediaStreamInfo(it) {
    var out = { kind:"", format:"", dimensions:"", res:"", vcodec:"", acodec:"", channels:"", bitrate:"" };
    if (!it) return out;
    var itemType = String(it.Type || "").toLowerCase();
    var isVideo = itemType === "video" || itemType === "movie" || itemType === "musicvideo";
    out.kind = itemType === "photo" ? "PHOTO" : (isVideo ? "VIDÉO" : "MÉDIA");
    var src = (it.MediaSources && it.MediaSources.length > 0) ? it.MediaSources[0] : null;
    out.format = mediaContainerLabel(it.Container || (src && src.Container) || "");
    if (!out.format) {
        var path = String((src && src.Path) || it.Path || ""), dot = path.lastIndexOf(".");
        if (dot >= 0 && dot < path.length - 1) out.format = mediaContainerLabel(path.substr(dot + 1));
    }
    var streams = it.MediaStreams || (src && src.MediaStreams) || [];
    var w = Number(it.Width || (src && src.Width) || 0), h = Number(it.Height || (src && src.Height) || 0);
    var bit = Number((src && src.Bitrate) || it.Bitrate || 0);
    for (var i = 0; streams && i < streams.length; i++) {
        var st = streams[i];
        if (!st) continue;
        var typ = String(st.Type || "").toLowerCase();
        if (typ === "video") {
            if (!w && st.Width) w = Number(st.Width);
            if (!h && st.Height) h = Number(st.Height);
            if (!out.vcodec && st.Codec) out.vcodec = mediaCodecLabel(st.Codec);
            if (!bit && st.BitRate) bit = Number(st.BitRate);
        } else if (typ === "audio") {
            if (!out.acodec && st.Codec) out.acodec = mediaCodecLabel(st.Codec);
            if (!out.channels) out.channels = mediaChannelLabel(st);
        }
    }
    if (!out.format && itemType === "photo" && out.vcodec) out.format = out.vcodec;
    if (w > 0 && h > 0) out.dimensions = Math.round(w) + "×" + Math.round(h);
    if (h >= 2000) out.res = "4K";
    else if (h >= 1400) out.res = "1440p";
    else if (h >= 1000) out.res = "1080p";
    else if (h >= 700) out.res = "720p";
    else if (h >= 460) out.res = "480p";
    if (bit > 0 && itemType !== "photo") {
        var mb = bit / 1000000;
        out.bitrate = (mb >= 10 ? Math.round(mb) : Math.round(mb * 10) / 10) + " Mbit/s";
    }
    return out;
}

/* ------------------------------------------------------------------------- */
/* Helpers purs partagés avec jellyfinBridge                                 */
/* ------------------------------------------------------------------------- */
/*
 * Ces fonctions ne font aucun I/O et n'ont aucun état réseau. Elles décrivent
 * les objets Jellyfin et les sections du catalogue ; MediaBrowser porte le tri
 * et la fenêtre de pagination des pages de bibliothèque.
 */
function _rdfS(v) {
    return (v === undefined || v === null) ? "" : String(v);
}
function intValue(v) {
    var n = Number(v);
    if (!isFinite(n) || isNaN(n)) return 0;
    return Math.floor(n);
}
function itemTypeLower(it) {
    return (it && it.Type !== undefined && it.Type !== null) ? _rdfS(it.Type).toLowerCase() : "";
}
function mediaTypeNameList(typeName) {
    var raw = _rdfS(typeName).split(","), out = [];
    for (var i = 0; i < raw.length; i++) {
        var t = _rdfS(raw[i]).toLowerCase();
        if (t) out.push(t);
    }
    return out;
}
function isRealTypedMediaItem(it, typeName) {
    if (!it || !it.Id) return false;
    var want = _rdfS(typeName).toLowerCase();
    if (itemTypeLower(it) !== want) return false;
    if (want === "movie" || want === "video" || want === "musicvideo") {
        if (it.IsFolder === true) return false;
        var loc = _rdfS(it.LocationType || it.locationType).toLowerCase();
        if (loc === "virtual" || loc === "missing" || loc === "placeholder") return false;
    }
    return true;
}
function filterRealTypedMediaItems(items, typeName, preserveServerBoxSets) {
    var out = [], types = mediaTypeNameList(typeName);
    // L'API peut substituer un BoxSet aux films d'une bibliothèque regroupée.
    // Ne pas activer nous-mêmes le regroupement ; conserver l'ordre API.
    var allowGroupedBoxSets = preserveServerBoxSets === true && typeName === "Movie,Video,MusicVideo";
    items = items || [];
    for (var i = 0; i < items.length; i++) {
        if (allowGroupedBoxSets && items[i] && items[i].Id && itemTypeLower(items[i]) === "boxset") {
            out.push(items[i]);
            continue;
        }
        for (var t = 0; t < types.length; t++) {
            if (isRealTypedMediaItem(items[i], types[t])) {
                out.push(items[i]);
                break;
            }
        }
    }
    return out;
}
function isMusicVideoItem(it) {
    return itemTypeLower(it) === "musicvideo";
}
function _uniqueTextList(values) {
    var out = [], seen = {};
    for (var i = 0; values && i < values.length; i++) {
        var raw = values[i] && values[i].Name !== undefined ? values[i].Name : values[i];
        var v = _rdfS(raw).trim();
        var k = v.toLowerCase();
        if (v && !seen[k]) {
            seen[k] = true;
            out.push(v);
        }
    }
    return out;
}
function mediaArtistsText(it) {
    if (!it) return "";
    var a = _uniqueTextList(it.Artists || []);
    if (!a.length) a = _uniqueTextList(it.ArtistItems || []);
    return a.join(", ");
}
function mediaDirectorsText(it) {
    var ppl = it && it.People ? it.People : [], names = [], seen = {};
    for (var i = 0; i < ppl.length; i++) {
        var p = ppl[i] || {};
        var kind = _rdfS(p.Type || p.Role).toLowerCase();
        var name = _rdfS(p.Name).trim();
        var key = name.toLowerCase();
        if (kind === "director" && name && !seen[key]) {
            seen[key] = true;
            names.push(name);
        }
    }
    return names.join(", ");
}
function normalizeMode(mode) {
    var m = _rdfS(mode).toLowerCase();
    if (m === "series" || m === "mixed" || m === "collections" || m === "personal") return m;
    return "movies";
}
function clampScrollableContentY(contentHeight, viewportHeight, value) {
    var content = Number(contentHeight || 0);
    var viewport = Number(viewportHeight || 0);
    var y = Number(value || 0);
    if (!isFinite(content) || !isFinite(viewport) || !isFinite(y) || content <= 0 || viewport <= 0) return 0;
    return Math.max(0, Math.min(y, Math.max(0, content - viewport)));
}
function titleTextCapPx(averageCharacterWidth, characterLimit) {
    var aw = Number(averageCharacterWidth || 0);
    var limit = Math.max(1, intValue(characterLimit));
    if (!isFinite(aw) || aw <= 0) aw = 18;
    return Math.max(220, Math.round(aw * limit + 10));
}
function isHierarchicalMode(mode) {
    var m = normalizeMode(mode);
    return m === "series" || m === "mixed" || m === "personal";
}
function isCollectionsMode(mode) {
    return normalizeMode(mode) === "collections";
}
function _mediaLibraryTypeLower(it) {
    return it ? _rdfS(it.Type || it.CollectionType).toLowerCase() : "";
}
function isSeries(it) {
    var t = _mediaLibraryTypeLower(it);
    return t === "series" || t === "tvshow" || t === "tvshows";
}
function isFolder(it) {
    if (!it || isSeries(it)) return false;
    var t = _mediaLibraryTypeLower(it);
    return t === "folder" || t === "photoalbum" || t === "collectionfolder" || t === "season" || it.IsFolder === true;
}
function clampBlur(v) {
    return Math.max(1, Math.min(50, Number(v) | 0));
}
function _libraryField(lib, upperName, lowerName) {
    if (!lib) return "";
    if (lib[upperName] !== undefined && lib[upperName] !== null)
        return _rdfS(lib[upperName]);
    if (lowerName && lib[lowerName] !== undefined && lib[lowerName] !== null)
        return _rdfS(lib[lowerName]);
    return "";
}
function _libraryNormName(value) {
    var s = _rdfS(value);
    if (!s) return "";
    var n = s.normalize ? s.normalize("NFD").replace(/[\u0300-\u036f]/g, "") : s;
    return n.toLowerCase().replace(/\s+/g, " ").trim();
}
function _libraryEqAny(value, values) {
    for (var i = 0; i < values.length; i++) if (value === values[i]) return true;
    return false;
}
function _libraryHas(value, fragment) {
    return _rdfS(value).indexOf(fragment) >= 0;
}
function isClipsOrPersonalLibraryName(name) {
    var n = _libraryNormName(name);
    var exact = [
        "clips videos", "clip videos", "clips video", "clips", "music videos",
        "videos et photos personnelles", "videos personnelles", "photos personnelles",
        "videos et photos", "home videos", "videos perso", "mes videos", "mes photos"
    ];
    if (_libraryEqAny(n, exact)) return true;
    return _libraryHas(n, "clips")
        || (_libraryHas(n, "video") && _libraryHas(n, "photo"))
        || _libraryHas(n, "personnel")
        || _libraryHas(n, "personnelles");
}
function isKnownUnsupportedLibraryFolder(lib) {
    if (!lib) return false;
    var ct = _libraryField(lib, "CollectionType", "ct").toLowerCase();
    var t = _libraryField(lib, "Type", "t").toLowerCase();
    var n = _libraryNormName(_libraryField(lib, "Name", "name"));

    if (_libraryEqAny(ct, ["books", "book", "ebooks", "ebook"])) return true;
    if (_libraryEqAny(t, ["book", "books", "ebook", "ebooks", "bookfolder", "ebookfolder"])) return true;
    if (_libraryHas(n, "ebook") || _libraryHas(n, "e-book") || n === "livres" || n === "livre"
            || _libraryHas(n, "bibliotheque de livres")) return true;

    if (_libraryEqAny(ct, ["livetv", "live-tv", "channels", "channel", "tvchannels"])) return true;
    if (_libraryEqAny(t, ["livetv", "livetvfolder", "livetvchannel", "channel", "channelfolder",
                           "tvchannel", "tvchannelfolder"])) return true;
    if (_libraryHas(n, "live tv") || _libraryHas(n, "livetv") || _libraryHas(n, "chaine tv")
            || _libraryHas(n, "chaines tv") || _libraryHas(n, "tv en direct")) return true;

    if (_libraryHas(n, "nextpvr") || _libraryHas(n, "tvheadend")) return true;
    if (_libraryEqAny(ct, ["recordings", "recording", "dvr"])) return true;
    if (_libraryEqAny(t, ["recording", "recordings", "recordingfolder", "dvr", "dvrfolder"])) return true;
    if ((_libraryHas(n, "recording") || _libraryHas(n, "enregistrement"))
            && (_libraryHas(n, "tv") || _libraryHas(n, "pvr") || _libraryHas(n, "dvr"))) return true;
    return _libraryHas(n, "enregistrements tv") || _libraryHas(n, "enregistrement tv");
}
function isPersonalMediaLibraryFolder(lib) {
    if (!lib || isKnownUnsupportedLibraryFolder(lib)) return false;
    var ct = _libraryField(lib, "CollectionType", "ct").toLowerCase();
    var t = _libraryField(lib, "Type", "t").toLowerCase();
    var n = _libraryNormName(_libraryField(lib, "Name", "name"));
    return ct === "homevideos"
        || _libraryEqAny(t, ["homevideos", "homevideosfolder", "photos", "photofolder", "photoalbum"])
        || (_libraryHas(n, "video") && _libraryHas(n, "photo"))
        || ((_libraryHas(n, "personnel") || _libraryHas(n, "personnelles"))
            && (_libraryHas(n, "video") || _libraryHas(n, "photo")));
}
function isPersonalMediaLatestEntry(entry) {
    if (!entry) return false;
    var ct = _libraryField(entry, "CollectionType", "ct").toLowerCase();
    var t = _libraryField(entry, "Type", "t").toLowerCase();
    var n = _libraryNormName(_libraryField(entry, "Name", "name"));
    return ct === "homevideos"
        || _libraryEqAny(t, ["homevideos", "homevideosfolder", "photos", "photofolder", "photoalbum"])
        || (_libraryHas(n, "video") && _libraryHas(n, "photo"))
        || ((_libraryHas(n, "personnel") || _libraryHas(n, "personnelles"))
            && (_libraryHas(n, "video") || _libraryHas(n, "photo")));
}
function isMovieLibraryFolder(lib) {
    if (!lib || isKnownUnsupportedLibraryFolder(lib)) return false;
    var ct = _libraryField(lib, "CollectionType", "ct").toLowerCase();
    var t = _libraryField(lib, "Type", "t").toLowerCase();
    return _libraryEqAny(ct, ["movies"]) || _libraryEqAny(t, ["movies", "moviefolder"]);
}
function isMixedLibraryFolder(lib) {
    if (!lib || isKnownUnsupportedLibraryFolder(lib)) return false;
    var ct = _libraryField(lib, "CollectionType", "ct").toLowerCase();
    var t = _libraryField(lib, "Type", "t").toLowerCase();
    var n = _libraryNormName(_libraryField(lib, "Name", "name"));
    // CollectionType fait foi lorsqu'il est fourni par Jellyfin. Certaines vues
    // mixtes anciennes arrivent toutefois avec un CollectionFolder sans type.
    if (_libraryEqAny(ct, ["mixed", "moviesandshows", "moviesandtvshows"]) ||
            _libraryEqAny(t, ["mixed", "mixedfolder"])) return true;
    if (ct && ct !== "folders") return false; // ne jamais reclassifier tvshows/movies/music/boxsets
    if ((_libraryHas(n, "serie") || _libraryHas(n, "series")) &&
            (_libraryHas(n, "film") || _libraryHas(n, "movie"))) return true;
    // Route de secours pour les vues Jellyfin génériques dépourvues de type.
    // Les médiathèques Films/Séries/Collections/Photos/Musique gardent leur route.
    if (t !== "collectionfolder" && t !== "userview") return false;
    if (_libraryHas(n, "serie") || _libraryHas(n, "series") ||
            _libraryHas(n, "film") || _libraryHas(n, "movie") ||
            _libraryHas(n, "collection") || n === "saga" || n === "sagas" ||
            _libraryHas(n, "photo") || _libraryHas(n, "video") ||
            _libraryHas(n, "music") || _libraryHas(n, "musique") ||
            _libraryHas(n, "clip")) return false;
    return true;
}
function isSeriesLibraryFolder(lib) {
    if (!lib || isKnownUnsupportedLibraryFolder(lib) || isMixedLibraryFolder(lib)) return false;
    var ct = _libraryField(lib, "CollectionType", "ct").toLowerCase();
    var t = _libraryField(lib, "Type", "t").toLowerCase();
    var n = _libraryNormName(_libraryField(lib, "Name", "name"));
    return ct === "tvshows"
        || _libraryEqAny(t, ["series", "tvshow", "tvshows", "tvshowfolder"])
        || _libraryHas(n, "serie")
        || _libraryHas(n, "series");
}
// Identifiant local réservé : ce n'est JAMAIS un vrai item Jellyfin.
function virtualCollectionsFolderId() { return "redefin.virtual.boxsets"; }
function isVirtualCollectionsFolderId(id) { return _rdfS(id) === virtualCollectionsFolderId(); }
function hasCollectionsLibrary(views) {
    for (var i = 0; views && i < views.length; ++i)
        if (isCollectionsLibraryFolder(views[i])) return true;
    return false;
}
// Ne créer une vue de secours sur l’accueil que si le profil autorise
// explicitement l’affichage des Collections. /Items (BoxSet) seul ne prouve
// jamais que l’utilisateur souhaite voir ce dossier sur son accueil.
// Une exclusion MyMediaExcludes non vide reste ambiguë sans consulter les
// vues cachées : privilégier l’absence de raccourci au contournement d’un choix.
function mayOfferVirtualCollectionsLibrary(user, expectedUserId) {
    if (!user || !expectedUserId || _rdfS(user.Id) !== _rdfS(expectedUserId)) return false;
    var config = user.Configuration;
    if (!config || config.DisplayCollectionsView !== true) return false;
    var excludes = config.MyMediaExcludes;
    if (excludes !== undefined && excludes !== null) {
        if (!Array.isArray(excludes) || excludes.length > 0) return false;
    }
    return true;
}
function virtualCollectionsLibrary() {
    return { Id: virtualCollectionsFolderId(), Name: "Collections",
             CollectionType: "boxsets", Type: "CollectionFolder", IsFolder: true,
             _redefinVirtualCollections: true };
}
function isCollectionsLibraryFolder(lib) {
    if (!lib || isKnownUnsupportedLibraryFolder(lib)) return false;
    var ct = _libraryField(lib, "CollectionType", "ct").toLowerCase();
    var t = _libraryField(lib, "Type", "t").toLowerCase();
    var n = _libraryNormName(_libraryField(lib, "Name", "name"));
    return ct === "boxsets" || t === "boxsets" || n === "collections" || n === "collection"
        || _libraryHas(n, "collection")
        || ((!ct || ct === "boxsets") && (n === "saga" || n === "sagas"));
}
function folderShouldOpenOnMoviePage(lib) {
    if (!lib || isKnownUnsupportedLibraryFolder(lib)) return false;
    if (isMovieLibraryFolder(lib)) return true;
    var ct = _libraryField(lib, "CollectionType", "ct").toLowerCase();
    var t = _libraryField(lib, "Type", "t").toLowerCase();
    var n = _libraryNormName(_libraryField(lib, "Name", "name"));
    return _libraryEqAny(ct, ["homevideos", "videos", "musicvideos"])
        || _libraryEqAny(t, ["homevideos", "homevideosfolder", "videos", "videosfolder",
                             "musicvideos", "musicvideosfolder"])
        || _libraryEqAny(n, ["autres", "autre", "other", "others"])
        || isClipsOrPersonalLibraryName(_libraryField(lib, "Name", "name"));
}
function isSupportedRootMediaFolder(lib) {
    return !!(lib && !isKnownUnsupportedLibraryFolder(lib)
        && (isPersonalMediaLibraryFolder(lib)
            || folderShouldOpenOnMoviePage(lib)
            || isMixedLibraryFolder(lib)
            || isSeriesLibraryFolder(lib)
            || isCollectionsLibraryFolder(lib)));
}
function isUnsupportedMediaItem(it) {
    var t = itemTypeLower(it);
    return t === "audio" || t === "musicalbum" || t === "audiobook" || t === "book";
}
function _pushTagChip(out, text, color, pixelSize) {
    var value = (text === undefined || text === null) ? "" : _rdfS(text);
    if (value.length > 0) out.push({ t: value, c: color, px: pixelSize || 13 });
}
function movieBrowserTagChips(it, streamInfo, ageTag, collectionsMode, seriesItem, folderItem) {
    var out = [];
    var si = streamInfo || {};
    if (collectionsMode === true) {
        // Une collection n'est pas un média lisible : genres uniquement.
    } else if (seriesItem === true) {
        var status = seriesStatusText(it);
        if (status) _pushTagChip(out, status, seriesStatusColor(it), 13);
        _pushTagChip(out, ageTag || "", "#2e4057", 13);
    } else if (folderItem === true) {
        var count = folderCount(it);
        if (count > 0) _pushTagChip(out, count + " éléments", "#2e4057", 13);
    } else {
        _pushTagChip(out, ageTag || "", "#2e4057", 13);
        _pushTagChip(out, si.res || "", "#232373", 14);
        _pushTagChip(out, si.audioProfile || "", "#2c5269", 13);
        _pushTagChip(out, si.vcodec || "", "#5a45b6", 14);
        _pushTagChip(out, si.acodec || "", "#295393", 14);
        _pushTagChip(out, si.channels || "", "#223344", 14);
        _pushTagChip(out, si.multiAudio || "", "#465f9c", 13);
        _pushTagChip(out, si.subs || "", "#27a191", 13);
    }
    var genres = it && it.Genres ? it.Genres : [];
    for (var i = 0; i < genres.length; i++) _pushTagChip(out, genres[i], "#394974", 13);
    return out;
}
function personalMediaTagChips(streamInfo) {
    var out = [];
    var si = streamInfo || {};
    _pushTagChip(out, si.kind, "#2e4057", 13);
    _pushTagChip(out, si.format, "#394974", 14);
    if (si.kind === "PHOTO") {
        _pushTagChip(out, si.dimensions, "#232373", 13);
    } else {
        _pushTagChip(out, si.res || si.dimensions, "#232373", 13);
        _pushTagChip(out, si.vcodec, "#5a45b6", 14);
        _pushTagChip(out, si.acodec, "#295393", 14);
        _pushTagChip(out, si.channels, "#223344", 14);
        _pushTagChip(out, si.bitrate, "#465f9c", 13);
    }
    return out;
}
function detailSnapshotCanApply(snapshot, itemId) {
    return !!(snapshot && snapshot.item && snapshot.userDataInvalid
        && itemId && _rdfS(snapshot.itemId) === _rdfS(itemId));
}
function _parseYmd(iso) {
    var s = _rdfS(iso);
    if (s.length < 10) return null;
    var y = parseInt(s.substr(0, 4), 10);
    var m = parseInt(s.substr(5, 2), 10);
    var d = parseInt(s.substr(8, 2), 10);
    if (!y || m < 1 || m > 12 || d < 1 || d > 31) return null;
    return { y:y, m:m, d:d };
}
function personDateShortFr(iso) {
    var p = _parseYmd(iso);
    if (!p) return "";
    var d = p.d < 10 ? ("0" + p.d) : String(p.d);
    var m = p.m < 10 ? ("0" + p.m) : String(p.m);
    return d + "/" + m + "/" + p.y;
}
function personDateLongFr(iso) {
    var p = _parseYmd(iso);
    if (!p) return "";
    var months = ["janvier", "février", "mars", "avril", "mai", "juin",
                  "juillet", "août", "septembre", "octobre", "novembre", "décembre"];
    return p.d + " " + months[p.m - 1] + " " + p.y;
}
function personAgeFromDates(birthIso, deathIso) {
    var birth = _parseYmd(birthIso);
    if (!birth) return -1;
    var end = _parseYmd(deathIso);
    if (!end) {
        var now = new Date();
        end = { y:now.getFullYear(), m:now.getMonth() + 1, d:now.getDate() };
    }
    var age = end.y - birth.y;
    if (end.m < birth.m || (end.m === birth.m && end.d < birth.d)) age--;
    return age >= 0 ? age : -1;
}
function plainOverview(value) {
    var s = _rdfS(value);
    s = s.replace(/<br\s*\/?>/gi, "\n")
         .replace(/<[^>]+>/g, "")
         .replace(/\r/g, "")
         .replace(/\n{3,}/g, "\n\n");
    return s.trim ? s.trim() : s;
}
function userDataOf(it) {
    try { return (it && it.UserData) ? it.UserData : {}; } catch (e) { return {}; }
}
function isPlayedItem(it) {
    if (!it) return false;
    var ud = userDataOf(it);
    return (ud && ud.Played === true) || it.Played === true;
}
function resumeProgressRatioFor(it, allowCumulativeRuntime) {
    if (!it || isPlayedItem(it)) return 0;
    var ud = userDataOf(it);
    var runtime = Number(it.RunTimeTicks || (allowCumulativeRuntime === true ? it.CumulativeRunTimeTicks : 0) || 0);
    var pos = Number((ud.PlaybackPositionTicks !== undefined) ? ud.PlaybackPositionTicks : it.PlaybackPositionTicks);
    if (!isFinite(runtime) || runtime <= 0 || !isFinite(pos) || pos <= 0) return 0;
    var ratio = pos / runtime;
    if (!isFinite(ratio) || ratio <= 0.01 || ratio >= 0.98) return 0;
    return Math.max(0.03, Math.min(0.97, ratio));
}

function unreadCount(it) {
    if (!it) return 0;
    var c = 0;
    if (it.UserData && it.UserData.UnplayedItemCount !== undefined)
        c = it.UserData.UnplayedItemCount;
    else if (it.UnplayedItemCount !== undefined)
        c = it.UnplayedItemCount;
    else if (it.RecursiveUnplayedItemCount !== undefined)
        c = it.RecursiveUnplayedItemCount;
    c = Number(c) || 0;
    return c < 0 ? 0 : Math.floor(c);
}
function folderCount(it) {
    if (!isFolder(it)) return 0;
    var n = Number(it.ChildCount !== undefined ? it.ChildCount : it.RecursiveItemCount);
    return isFinite(n) && n > 0 ? Math.floor(n) : 0;
}
function _mediaYear(v) {
    var m = _rdfS(v).match(/^(\d{4})/);
    return m ? m[1] : "";
}
function seriesStatusKind(it) {
    var s = _rdfS(it && it.Status).toLowerCase();
    if (!s) return 0;
    if (s.indexOf("continu") >= 0 || s.indexOf("returning") >= 0
            || s.indexOf("inproduction") >= 0 || s.indexOf("production") >= 0)
        return 1;
    if (s.indexOf("ended") >= 0 || s.indexOf("termin") >= 0)
        return 2;
    return 0;
}
function seriesStatusText(it) {
    var kind = seriesStatusKind(it);
    if (kind === 1) return "EN PRODUCTION";
    if (kind === 2) return "TERMINÉE";
    return "";
}
function seriesStatusColor(it) {
    var s = seriesStatusText(it);
    return s === "EN PRODUCTION" ? "#16a34a" : (s === "TERMINÉE" ? "#ef4444" : "#394974");
}
function seriesProductionRange(it) {
    if (!it) return "";
    var a = (it.ProductionYear !== undefined && it.ProductionYear !== null && _rdfS(it.ProductionYear))
          ? _rdfS(it.ProductionYear)
          : _mediaYear(it.PremiereDate);
    var b = _mediaYear(it.EndDate) || _mediaYear(it.DateEnded) || _mediaYear(it.SeriesEndDate);
    var s = seriesStatusText(it);
    if (a && b) return a === b ? a : (a + " → " + b);
    if (a && s === "EN PRODUCTION") return a + " →";
    return a || b;
}
function seriesEpisodeMinutes(it) {
    if (!it) return 0;
    var n = it.RunTimeTicks ? Number(it.RunTimeTicks) / 600000000
                            : (it.AverageRuntime || it.SeriesRuntime || 0);
    n = Number(n);
    return isFinite(n) && n > 0 ? Math.round(n) : 0;
}
function hasPrimaryOrThumb(it) {
    if (!it) return false;
    var tags = it.ImageTags || {};
    return !!(tags.Primary || tags.Thumb);
}
function collectionIsSeriesType(it) {
    var t = (it && (it.Type || it.CollectionType))
          ? _rdfS(it.Type || it.CollectionType).toLowerCase()
          : "";
    return t === "series" || t === "tvshow" || t === "tvshows" ||
           t === "season" || t === "episode";
}
function collectionSortAlpha(a, b) {
    var na = (a && a.Name) ? _rdfS(a.Name).toLowerCase() : "";
    var nb = (b && b.Name) ? _rdfS(b.Name).toLowerCase() : "";
    return na < nb ? -1 : (na > nb ? 1 : 0);
}

/* ===== Helpers de présentation partagés par les pages lourdes ===== */
function safeString(value) {
    return (value === undefined || value === null) ? "" : String(value);
}
function positiveIntOr(value, fallback) {
    var n = Number(value) | 0;
    return n > 0 ? n : fallback;
}
function primaryImageTag(it) {
    if (!it) return "";
    if (it.PrimaryImageTag) return String(it.PrimaryImageTag);
    return (it.ImageTags && it.ImageTags.Primary) ? String(it.ImageTags.Primary) : "";
}
function collectionPrimaryImageTag(it) {
    var tags = (it && it.ImageTags) ? it.ImageTags : {};
    return it ? String(tags.Primary || it.PrimaryImageTag || "") : "";
}
function collectionThumbImageTag(it) {
    var tags = (it && it.ImageTags) ? it.ImageTags : {};
    return it ? String(tags.Thumb || it.ThumbImageTag || "") : "";
}
function collectionLogoImageTag(it) {
    var tags = (it && it.ImageTags) ? it.ImageTags : {};
    return it ? String(tags.Logo || it.LogoImageTag || "") : "";
}
function hasPrimaryOrThumbImage(it) {
    return !!(collectionPrimaryImageTag(it) || collectionThumbImageTag(it));
}
function hasPrimaryImage(it) {
    return !!collectionPrimaryImageTag(it);
}
function hasLogoImage(it) {
    return !!collectionLogoImageTag(it);
}
function hasLogoOrPrimaryImage(it) {
    return hasLogoImage(it) || hasPrimaryImage(it);
}
function mediaDateLineShortFr(it) {
    if (!it) return "";
    if (it.PremiereDate) return formatDateShortFr(it.PremiereDate);
    return it.ProductionYear ? String(it.ProductionYear) : "";
}
function mediaGenresLine(it, separator) {
    var src = (it && it.Genres) ? it.Genres : [], out = [];
    for (var i = 0; i < src.length; ++i) {
        if (src[i] !== undefined && src[i] !== null && String(src[i]).length)
            out.push(String(src[i]));
    }
    return out.join(separator === undefined ? " / " : String(separator));
}
function normalizeOverviewLine(value) {
    var s = safeString(value);
    s = s.replace(/<br\s*\/?>/gi, "\n").replace(/\r/g, "")
         .replace(/\n+/g, " ").replace(/[ \t\u00A0]+/g, " ");
    return s.trim ? s.trim() : s;
}
function formatDurationTicksCompact(ticks) {
    var mins = Math.round((Number(ticks) || 0) / 600000000);
    if (mins <= 0) return "";
    var h = Math.floor(mins / 60), m = mins % 60;
    return h > 0 ? (h + "h" + (m < 10 ? "0" : "") + m) : (m + "m");
}
function mediaUserDataNullable(it) {
    try { return (it && it.UserData) ? it.UserData : null; } catch (e) { return null; }
}
function mediaIsPlayedIncludingPercentage(it) {
    if (!it) return false;
    var ud = mediaUserDataNullable(it);
    if (it.Played === true || (ud && ud.Played === true)) return true;
    try {
        return !!(ud && ud.PlayedPercentage !== undefined
                  && Number(ud.PlayedPercentage) >= 99);
    } catch (e) { return false; }
}
function mediaPlaybackPositionTicks(it) {
    var ud = mediaUserDataNullable(it), value = 0;
    try {
        value = Number(ud && ud.PlaybackPositionTicks !== undefined
                       ? ud.PlaybackPositionTicks
                       : (it && it.PlaybackPositionTicks)) || 0;
    } catch (e) { value = 0; }
    return Math.max(0, value);
}
function mediaProgressRatio(it) {
    var runtime = Number(it && it.RunTimeTicks) || 0;
    if (runtime <= 0) return 0;
    var ratio = mediaPlaybackPositionTicks(it) / runtime;
    return isFinite(ratio) ? Math.max(0, Math.min(1, ratio)) : 0;
}
function mediaStreamTypeLower(stream) {
    var t = safeString(stream && stream.Type).toLowerCase();
    if (t === "1") return "video";
    if (t === "0") return "audio";
    if (t === "2") return "subtitle";
    return t;
}
function uniqueUpperStreamLanguages(streams, wantedType) {
    var out = [], src = streams || [];
    for (var i = 0; i < src.length; ++i) {
        if (mediaStreamTypeLower(src[i]) !== wantedType) continue;
        var lang = src[i] && src[i].Language ? String(src[i].Language).toUpperCase() : "";
        if (lang.length && out.indexOf(lang) < 0) out.push(lang);
    }
    return out;
}
function collectionTechChips(src, genreSrc) {
    var chips = [], streams = (src && src.MediaStreams) ? src.MediaStreams : [];
    var video = null, audio = null, hasSubs = false;
    for (var i = 0; i < streams.length; ++i) {
        var st = streams[i], type = mediaStreamTypeLower(st);
        if (type === "video" && !video) video = st;
        else if (type === "audio" && (!audio || (!audio.IsDefault && st.IsDefault))) audio = st;
        else if (type === "subtitle") hasSubs = true;
    }
    if (video) {
        var res = mediaVideoResolutionLabel(video.Width, video.Height);
        if (res) chips.push({ t: res, c: "#232373", px: 14 });
        if (video.Codec) chips.push({ t: String(video.Codec).toUpperCase(), c: "#5a45b6", px: 14 });
    }
    if (audio) {
        if (audio.Codec) chips.push({ t: String(audio.Codec).toUpperCase(), c: "#295393", px: 14 });
        if (mediaChannelLabel(audio)) chips.push({ t: mediaChannelLabel(audio), c: "#234", px: 14 });
    }
    var audioLangs = uniqueUpperStreamLanguages(streams, "audio");
    if (audioLangs.length > 1)
        chips.push({ t: "AUDIO: " + audioLangs.join("/"), c: "#465f9c", px: 13 });
    if (hasSubs) {
        var subLangs = uniqueUpperStreamLanguages(streams, "subtitle");
        chips.push({ t: subLangs.length ? "ST: " + subLangs.join("/") : "ST", c: "#27a191", px: 13 });
    }
    var genres = (genreSrc && genreSrc.Genres && genreSrc.Genres.length)
               ? genreSrc.Genres : ((src && src.Genres) || []);
    for (var g = 0; g < genres.length; ++g)
        chips.push({ t: String(genres[g]), c: "#394974", px: 13 });
    return chips;
}
function primaryImageUrl(Jellyfin, serverUrl, it, options) {
    if (!Jellyfin || !it || !it.Id || !serverUrl) return "";
    var tag = primaryImageTag(it);
    return tag ? Jellyfin.itemImageUrl(serverUrl, it.Id, "Primary", tag, options || {}) : "";
}
function backdropOrPrimaryUrl(Jellyfin, serverUrl, it, options) {
    if (!Jellyfin || !it || !serverUrl) return "";
    return Jellyfin.itemBackdropOrPrimaryUrl(serverUrl, it, options || {});
}
function collectionPrimaryImageUrl(Jellyfin, serverUrl, it, options) {
    if (!Jellyfin || !it || !it.Id || !serverUrl) return "";
    var tag = collectionPrimaryImageTag(it);
    return tag ? Jellyfin.itemImageUrl(serverUrl, it.Id, "Primary", tag, options || {}) : "";
}
function collectionLogoImageUrl(Jellyfin, serverUrl, it, options) {
    if (!Jellyfin || !it || !it.Id || !serverUrl) return "";
    var tag = collectionLogoImageTag(it);
    return tag ? Jellyfin.itemImageUrl(serverUrl, it.Id, "Logo", tag, options || {}) : "";
}

/* ===== Helpers PosterGrid ===== */
function clampIndex(index, count) {
    if (count <= 0) return 0;
    var value = Number(index);
    if (!isFinite(value)) value = 0;
    if (value < 0) return 0;
    if (value > count - 1) return count - 1;
    return value;
}
function safeArray(value) {
    try {
        if (!value || typeof value === "string" || value.length === undefined) return [];
        var out = [];
        for (var i = 0; i < value.length; ++i) out.push(value[i]);
        return out;
    } catch (e) { return []; }
}
function shallowCloneObject(value) {
    var out = {};
    if (!value) return out;
    for (var key in value)
        if (Object.prototype.hasOwnProperty.call(value, key)) out[key] = value[key];
    return out;
}
function findItemIndexById(items, id) {
    id = safeString(id);
    if (!id || !items || !items.length) return -1;
    for (var i = 0; i < items.length; ++i)
        if (items[i] && safeString(items[i].Id) === id) return i;
    return -1;
}
function isMusicLibraryFolder(lib) {
    if (!lib) return false;
    var ct = _libraryField(lib, "CollectionType", "ct").toLowerCase();
    var t = _libraryField(lib, "Type", "t").toLowerCase();
    var n = _libraryNormName(_libraryField(lib, "Name", "name"));
    return _libraryEqAny(ct, ["music", "audio"])
        || _libraryEqAny(t, ["music", "audio", "musicfolder"])
        || _libraryHas(n, "musique") || _libraryHas(n, "music");
}
function posterGridBackdropImageSpec(it) {
    if (!it) return ({ id:"", type:"", tag:"" });
    var itemType = itemTypeLower(it);
    var ownBackdrop = (it.BackdropImageTags && it.BackdropImageTags.length) ? String(it.BackdropImageTags[0] || "") : "";
    var parentBackdrop = (it.ParentBackdropImageTags && it.ParentBackdropImageTags.length) ? String(it.ParentBackdropImageTags[0] || "") : "";
    var parentId = safeString(it.ParentBackdropItemId), seriesId = safeString(it.SeriesId);
    if ((itemType === "episode" || itemType === "season") && (parentId || seriesId) && parentBackdrop)
        return ({ id: parentId || seriesId, type:"Backdrop", tag:parentBackdrop });
    if (it.Id && ownBackdrop) return ({ id:safeString(it.Id), type:"Backdrop", tag:ownBackdrop });
    var primary = collectionPrimaryImageTag(it);
    if (it.Id && primary) return ({ id:safeString(it.Id), type:"Primary", tag:primary });
    var thumb = collectionThumbImageTag(it);
    if (it.Id && thumb) return ({ id:safeString(it.Id), type:"Thumb", tag:thumb });
    return ({ id:"", type:"", tag:"" });
}
function personalMediaLibraryRoots(libraries) {
    var out = [], libs = libraries || [];
    for (var i = 0; i < libs.length; ++i) {
        var lib = libs[i];
        if (lib && lib.Id && isPersonalMediaLibraryFolder(lib)) out.push(lib);
    }
    return out;
}
function personalMediaRootMap(libraries) {
    var map = {}, roots = personalMediaLibraryRoots(libraries);
    for (var i = 0; i < roots.length; ++i) map[String(roots[i].Id)] = true;
    return map;
}
function personalMediaRecentRootIdForItem(it, latestGroups) {
    var itemId = it && it.Id ? String(it.Id) : "";
    if (!itemId || !latestGroups) return "";
    for (var g = 0; g < latestGroups.length; ++g) {
        var entry = latestGroups[g];
        if (!entry || !isPersonalMediaLatestEntry(entry) || !entry.id) continue;
        var arr = entry.items || [];
        for (var i = 0; i < arr.length; ++i)
            if (arr[i] && String(arr[i].Id || "") === itemId) return String(entry.id);
    }
    return "";
}
function personalMediaTypeCanUseViewer(it) {
    var t = itemTypeLower(it);
    return t === "video" || t === "movie" || t === "musicvideo" || t === "photo";
}
function personalRootIdFromAncestors(ancestors, rootMap) {
    var arr = ancestors || [];
    for (var i = 0; i < arr.length; ++i) {
        var a = arr[i];
        if (!a || !a.Id) continue;
        var id = String(a.Id);
        if ((rootMap && rootMap[id] === true) || isPersonalMediaLibraryFolder(a)) return id;
    }
    return "";
}
function posterGridLatestGroupIndexFromSnapshot(groups, snap) {
    if (!snap || !groups || !groups.length) return -1;
    var gid = safeString(snap.latestGroupId);
    if (gid) {
        for (var i = 0; i < groups.length; ++i)
            if (groups[i] && safeString(groups[i].id) === gid) return i;
    }
    var name = safeString(snap.latestGroupName);
    if (name) {
        for (var j = 0; j < groups.length; ++j)
            if (groups[j] && safeString(groups[j].name) === name) return j;
    }
    return (!gid && !name && snap.currentLatestGroup !== undefined)
         ? clampIndex(snap.currentLatestGroup, groups.length) : -1;
}

/* Comparaison et filtrage des rails Home, sans dépendance réseau. */
function _homeResumeItemAllowed(it) {
    if (!it) return false;
    var t = _rdfS(it.Type).toLowerCase();
    return t === "episode" ||
           t === "movie" ||
           t === "video" ||
           t === "musicvideo";
}

function filterHomeResumeItems(items, limit) {
    items = items || [];
    var out = [];
    var max = intValue(limit);
    if (max <= 0) max = 50;

    for (var i = 0; i < items.length && out.length < max; i++) {
        var it = items[i];
        if (_homeResumeItemAllowed(it))
            out.push(it);
    }
    return out;
}

// Médias autorisés dans "Récemment ajoutés".
// IMPORTANT : Season et Series sont volontairement exclus. Avec GroupItems
// actif Jellyfin peut remplacer des épisodes récents par leur saison parente,
// ce qui fait afficher uniquement "Saison 1" dans PosterGridCard.
function _homeLatestItemAllowed(it, allowGroupedSeriesContainers) {
    if (!it) return false;
    var t = _rdfS(it.Type).toLowerCase();
    if (t === "episode" ||
        t === "movie" ||
        t === "video" ||
        t === "musicvideo" ||
        t === "photo")
        return true;

    // Bibliothèque Séries + GroupItems=true :
    // - Season = ajout récent regroupé au niveau d'une saison ;
    // - Series = série regroupée au niveau intégrale par Jellyfin.
    // Les deux sont des résultats légitimes dans ce seul contexte.
    if (allowGroupedSeriesContainers === true)
        return t === "season" || t === "series";

    return false;
}

function filterHomeLatestItems(items, limit, allowGroupedSeriesContainers) {
    items = items || [];
    var out = [];
    var max = homeSectionLimit(limit);

    for (var i = 0; i < items.length && out.length < max; i++) {
        var it = items[i];
        if (_homeLatestItemAllowed(it, allowGroupedSeriesContainers))
            out.push(it);
    }
    return out;
}
function homeItemSignature(it) {
    if (!it) return "";
    var tags = it.ImageTags || {}; var backdrops = it.BackdropImageTags || []; var parentBackdrops = it.ParentBackdropImageTags || []; var ud = it.UserData || {};
    return _rdfS(it.Id) + "|" + _rdfS(it.Type) + "|" + _rdfS(it.Name) + "|" +
           _rdfS(it.SeriesName) + "|" + _rdfS(it.SeasonName) + "|" +
           _rdfS(it.ParentIndexNumber) + "|" + _rdfS(it.IndexNumber) + "|" +
           _rdfS(it.SeasonId) + "|" +
           _rdfS(tags.Primary || it.PrimaryImageTag) + "|" +
           _rdfS(tags.Thumb || it.ThumbImageTag) + "|" + _rdfS(backdrops[0]) + "|" +
           _rdfS(it.SeriesId) + "|" + _rdfS(it.SeriesPrimaryImageTag) + "|" +
           _rdfS(it.ParentThumbItemId) + "|" + _rdfS(it.ParentThumbImageTag) + "|" +
           _rdfS(it.ParentBackdropItemId) + "|" + _rdfS(parentBackdrops[0]) + "|" +
           _rdfS(it.ParentId) + "|" +
           _rdfS(ud.PlaybackPositionTicks || 0) + "|" + (ud.Played === true ? "1" : "0") + "|" +
           _rdfS(ud.UnplayedItemCount || it.UnplayedItemCount || 0);
}
function homeItemsEqual(a, b) {
    a = a || []; b = b || [];
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++)
        if (homeItemSignature(a[i]) !== homeItemSignature(b[i])) return false;
    return true;
}
function homeLatestGroupsEqual(a, b) {
    a = a || []; b = b || [];
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) {
        var ga = a[i] || {}, gb = b[i] || {};
        if (_rdfS(ga.id) !== _rdfS(gb.id) || _rdfS(ga.name) !== _rdfS(gb.name) ||
            !!ga._evicted !== !!gb._evicted || !!ga._hadItems !== !!gb._hadItems ||
            !homeItemsEqual(ga.items || [], gb.items || [])) return false;
    }
    return true;
}
function homeSectionLimit(limit) {
    var n = intValue(limit);
    if (n <= 0) n = 50;
    return Math.max(1, Math.min(50, n));
}

/* ------------------------------------------------------------------------- */
/* DTO compacts et métadonnées de fiches                                     */
/* ------------------------------------------------------------------------- */

// Projection légère pour les tags du header du navigateur.
// Le cache et son cycle de vie restent dans moviepage.qml.
function mergeHeaderItemDetails(base, detail) {
    if (!base) return detail || null
    if (!detail) return base
    var out = {}
    var k
    for (k in base) out[k] = base[k]
    for (k in detail) {
        if (detail[k] !== undefined && detail[k] !== null)
            out[k] = detail[k]
    }
    return out
}

function compactHeaderStreams(streams) {
    var out = []
    for (var i = 0; streams && i < streams.length; ++i) {
        var st = streams[i]
        if (!st) continue
        out.push({
            Type: st.Type || "", Codec: st.Codec || "", Width: Number(st.Width || 0),
            Height: Number(st.Height || 0), ChannelLayout: st.ChannelLayout || "",
            Channels: Number(st.Channels || 0), Language: st.Language || "",
            DisplayTitle: st.DisplayTitle || "", Title: st.Title || "", Name: st.Name || "",
            BitRate: Number(st.BitRate || 0), IsDefault: !!st.IsDefault
        })
    }
    return out
}

function compactHeaderItemDetails(detail) {
    if (!detail) return null
    var out = ({
        Id: detail.Id, Type: detail.Type, CollectionType: detail.CollectionType,
        Name: detail.Name, RunTimeTicks: detail.RunTimeTicks,
        RunTimeSeconds: detail.RunTimeSeconds, AverageRuntime: detail.AverageRuntime,
        Runtime: detail.Runtime, OfficialRating: detail.OfficialRating,
        CustomRating: detail.CustomRating, CommunityRating: detail.CommunityRating,
        ProductionYear: detail.ProductionYear, PremiereDate: detail.PremiereDate,
        Width: detail.Width, Height: detail.Height,
        Bitrate: detail.Bitrate, Container: detail.Container
    })
    if (detail.Genres && detail.Genres.length) out.Genres = detail.Genres.slice(0, 12)
    var source = detail.MediaSources && detail.MediaSources.length ? detail.MediaSources[0] : null
    // Pour un film multiversion, le MediaSource réellement exposé par Jellyfin
    // fait autorité pour le format vidéo/audio ; ne conserver que les champs
    // techniques compacts dans le cache QML (jamais de Path ni d'URL).
    var streams = source && source.MediaStreams && source.MediaStreams.length ? source.MediaStreams
                : (detail.MediaStreams && detail.MediaStreams.length ? detail.MediaStreams : null)
    if (streams) out.MediaStreams = compactHeaderStreams(streams)
    return out
}

function collectionDetailsNeedHydration(item) {
    if (!item) return true;
    if (!safeString(item.Overview)) return true;
    if (Number(item.RunTimeTicks || 0) <= 0) return true;
    if (typeof item.CommunityRating === "undefined") return true;
    return !(item.MediaStreams && item.MediaStreams.length);
}

function compactCollectionStreams(streams) {
    var out = [], source = streams || [];
    for (var i = 0; i < source.length; ++i) {
        var stream = source[i];
        if (!stream) continue;
        out.push({ Type:stream.Type, Codec:stream.Codec || "", Width:Number(stream.Width || 0),
                   Height:Number(stream.Height || 0), Channels:Number(stream.Channels || 0),
                   Language:stream.Language || "", IsDefault:!!stream.IsDefault });
    }
    return out;
}

function compactCollectionDetails(value) {
    if (!value) return null;
    return { Id:value.Id || "", Name:value.Name || "", Type:value.Type || "",
             CollectionType:value.CollectionType || "", Overview:value.Overview || "",
             Genres:value.Genres ? value.Genres.slice(0) : [], PremiereDate:value.PremiereDate || "",
             ProductionYear:value.ProductionYear, CommunityRating:value.CommunityRating,
             OfficialRating:value.OfficialRating || "", CustomRating:value.CustomRating || "",
             RunTimeTicks:Number(value.RunTimeTicks || 0), UserData:value.UserData || null,
             MediaStreams:compactCollectionStreams(value.MediaStreams || []) };
}

function navigationIdsForEpisodeLike(item) {
    if (!item) return { seriesId: "", seasonId: "", episodeId: "" };
    var typeName = itemTypeLower(item);
    if (typeName === "series") return { seriesId: item.Id || "", seasonId: "", episodeId: "" };
    if (typeName === "season") return { seriesId: item.SeriesId || "", seasonId: item.Id || "", episodeId: "" };
    if (typeName === "episode") return { seriesId: item.SeriesId || "", seasonId: item.SeasonId || item.ParentId || "", episodeId: item.Id || "" };
    return { seriesId: item.SeriesId || "", seasonId: item.SeasonId || item.ParentId || "", episodeId: "" };
}

function collectionRailsFromPages(pages) {
    pages = safeArray(pages).slice(0);
    pages.sort(function(a, b) { return Number(a.start || 0) - Number(b.start || 0); });
    var seen = ({}), films = [], series = [];
    for (var pageIndex = 0; pageIndex < pages.length; ++pageIndex) {
        var page = pages[pageIndex] || ({}), items = safeArray(page.items);
        for (var itemIndex = 0; itemIndex < items.length; ++itemIndex) {
            var item = items[itemIndex];
            if (!item) continue;
            var id = item.Id ? String(item.Id) : ("idx#" + page.start + "#" + itemIndex);
            if (seen[id]) continue;
            seen[id] = true;
            if (collectionIsSeriesType(item)) series.push(item);
            else films.push(item);
        }
    }
    return { seen: seen, films: films, series: series };
}

// Métadonnées de chapitres. Les épisodes et saisons sont dans SeasonUtils.
// Les constructeurs d’URL reçoivent le bridge explicitement : aucun import réseau.
function pad2(n) {
    n = +n;
    return (n < 10 ? "0" : "") + n;
}

function chapterTitle(chapter) {
    if (!chapter || chapter.Name === undefined || chapter.Name === null) return "";
    return String(chapter.Name).replace(/^\s+|\s+$/g, "");
}

function chapterTimeLabel(chapter) {
    var ticks = Number(chapter && chapter.StartPositionTicks || 0);
    var sec = Math.max(0, Math.floor(ticks / 10000000));
    var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    return h > 0 ? (h + ":" + pad2(m) + ":" + pad2(s)) : (m + ":" + pad2(s));
}

function chapterStartMs(chapter) {
    return Math.max(0, Math.floor(Number(chapter && chapter.StartPositionTicks || 0) / 10000));
}

function chapterIndexForPosition(chapters, positionMs, toleranceMs) {
    var list = chapters || [];
    if (!list.length) return -1;
    var pos = Math.max(0, Number(positionMs || 0));
    var tolerance = Math.max(0, Number(toleranceMs || 0));
    var idx = 0;
    for (var i = 0; i < list.length; ++i) {
        if (chapterStartMs(list[i]) <= pos + tolerance) idx = i;
        else break;
    }
    return Math.max(0, Math.min(list.length - 1, idx));
}

function chapterImageUrl(Jellyfin, serverUrl, itemId, chapters, index, width, height, quality) {
    var idx = Number(index) | 0;
    var list = chapters || [];
    var chapter = (idx >= 0 && idx < list.length) ? list[idx] : null;
    var imagePath = chapter ? String(chapter.ImagePath || chapter.imagePath || "") : "";
    var imageTag = chapter ? String(chapter.ImageTag || chapter.imageTag || "") : "";
    if (!itemId || idx < 0 || (!imagePath && !imageTag)) return "";
    return Jellyfin.chapterImageUrl(serverUrl, itemId, idx, imageTag, {
        maxWidth: Math.max(1, Number(width) | 0),
        maxHeight: Math.max(1, Number(height) | 0),
        quality: Math.max(1, Number(quality) | 0),
        format: "jpg"
    });
}

function formatRatingFr(n) {
    if (n === undefined || n === null)
        return "";
    return Number(n).toLocaleString(Qt.locale(), "f", 1);
}

// Titres des cartes Home/Search : séries groupées, saisons et épisodes.
function _posterPad2(v) {
    var n = Number(v);
    if (!isFinite(n) || n < 0) return "";
    n = Math.floor(n);
    return (n < 10 ? "0" : "") + n
}

function _posterItemType(item) {
    return item ? String(item.Type || "").toLowerCase() : ""
}

function _posterIsEpisode(item) {
    return _posterItemType(item) === "episode"
}

function _posterIsSeason(item) {
    return _posterItemType(item) === "season"
}

function _posterIsSeries(item) {
    return _posterItemType(item) === "series"
}

function _posterIsMovie(item) {
    return _posterItemType(item) === "movie"
}

function _posterClassification(item) {
    if (!_posterIsMovie(item)) return "";
    return String(item.OfficialRating || item.CustomRating || item.ParentalRating || item.AgeRating || "").replace(/^\s+|\s+$/g, "")
}

function _posterSeriesName(item) {
    if (!item) return "";
    return String(item.SeriesName || item.SeriesTitle || item.Series || item.ShowName || "").replace(/^\s+|\s+$/g, "")
}

function _posterYearFromDate(v) {
    var s = String(v || "")
    var m = /^(\d{4})/.exec(s)
    return m && m[1] ? m[1] : ""
}

function _posterSeriesBroadcastRange(item) {
    if (!_posterIsSeries(item)) return ""

    var start = ""
    if (item.ProductionYear !== undefined &&
        item.ProductionYear !== null &&
        String(item.ProductionYear).length > 0) {
        var py = Number(item.ProductionYear)
        if (isFinite(py) && !isNaN(py) && py >= 1800 && py <= 3000)
            start = String(Math.floor(py))
    }
    if (!start)
        start = _posterYearFromDate(item.PremiereDate)

    var end = _posterYearFromDate(item.EndDate) ||
        _posterYearFromDate(item.DateEnded) ||
        _posterYearFromDate(item.SeriesEndDate)

    if (start && end)
        return start === end ? start : (start + " - " + end)

    // Si Jellyfin ne fournit pas de date de fin, ne jamais inventer
    // une plage. La seule année connue reste préférable.
    return start || end
}

function _posterSeasonName(item) {
    if (!_posterIsSeason(item)) return ""
    var label = String(item.Name || "").replace(/^\s+|\s+$/g, "")
    if (label) return label
    if (item.IndexNumber !== undefined && item.IndexNumber !== null) {
        var n = Number(item.IndexNumber)
        if (isFinite(n) && !isNaN(n) && n >= 0) return "Saison " + Math.floor(n)
    }
    return ""
}

function _posterEpisodeCode(item) {
    if (!item) return "";
    var s = (item.ParentIndexNumber !== undefined && item.ParentIndexNumber !== null) ? _posterPad2(item.ParentIndexNumber) : "",
        e = (item.IndexNumber !== undefined && item.IndexNumber !== null) ? _posterPad2(item.IndexNumber) : "";
    return s && e ? "S" + s + "E" + e : (s ? "S" + s : (e ? "E" + e : ""))
}

function posterCardTitle(item) {
    if (!item) return ""
    if (_posterIsEpisode(item)) {
        var serie = _posterSeriesName(item),
            code = _posterEpisodeCode(item)
        if (serie && code) return serie + " — " + code
        if (serie) return serie
        if (code) return code
    }
    if (_posterIsSeason(item)) {
        var seasonSerie = _posterSeriesName(item)
        if (seasonSerie) return seasonSerie
        return _posterSeasonName(item)
    }
    return item.Name || ""
}

function posterCardSubtitle(item, imagePolicy) {
    if (!item) return ""
    if (_posterIsEpisode(item))
        return item.Name ? item.Name : ""

    if (_posterIsSeason(item)) {
        // Saison groupée : Nom de série / Saison X.
        return _posterSeriesName(item) ? _posterSeasonName(item) : ""
    }

    if (_posterIsSeries(item) && imagePolicy === "latest-series") {
        // Intégrale groupée par Jellyfin : ne pas afficher le mot
        // "Intégrale", mais la période de diffusion, ex. 2004 - 2010.
        return _posterSeriesBroadcastRange(item)
    }

    return _posterIsMovie(item) ? _posterClassification(item) : ""
}
