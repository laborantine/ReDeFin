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
function movieStreamInfo(it) {
    var out = { res:"", vcodec:"", acodec:"", channels:"", audioProfile:"", multiAudio:"", subs:"" };
    var streams = it && it.MediaStreams ? it.MediaStreams : [];
    var audioLangs = [], subLangs = [], hasSubtitle = false;
    for (var i = 0; streams && i < streams.length; i++) {
        var st = streams[i];
        if (!st) continue;
        var typ = String(st.Type || "").toLowerCase();
        if (typ === "video") {
            if (!out.res && st.Width) {
                var w = Number(st.Width) || 0;
                if (w >= 1900) out.res = "1080p";
                else if (w >= 1200) out.res = "720p";
                else if (w >= 700) out.res = "480p";
                else if (w > 0) out.res = w + "p";
            }
            if (!out.vcodec && st.Codec) out.vcodec = mediaCodecLabel(st.Codec);
        } else if (typ === "audio") {
            if (!out.audioProfile) out.audioProfile = _mediaFrenchAudioFlavor(st);
            if (!out.acodec && st.Codec) out.acodec = mediaCodecLabel(st.Codec);
            if (!out.channels) out.channels = mediaChannelLabel(st);
            _pushUniqueUpper(audioLangs, st.Language);
        } else if (typ === "subtitle") {
            hasSubtitle = true;
            _pushUniqueUpper(subLangs, st.Language);
        }
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
function filterRealTypedMediaItems(items, typeName) {
    var out = [], types = mediaTypeNameList(typeName);
    items = items || [];
    for (var i = 0; i < items.length; i++) {
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
    return t === "folder" || t === "collectionfolder" || t === "season" || it.IsFolder === true;
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
    return _libraryEqAny(ct, ["mixed", "moviesandshows", "moviesandtvshows"])
        || _libraryEqAny(t, ["mixed", "mixedfolder"])
        || ((_libraryHas(n, "serie") || _libraryHas(n, "series"))
            && (_libraryHas(n, "film") || _libraryHas(n, "movie")));
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
function isCollectionsLibraryFolder(lib) {
    if (!lib || isKnownUnsupportedLibraryFolder(lib)) return false;
    var ct = _libraryField(lib, "CollectionType", "ct").toLowerCase();
    var t = _libraryField(lib, "Type", "t").toLowerCase();
    var n = _libraryNormName(_libraryField(lib, "Name", "name"));
    return ct === "boxsets" || t === "boxsets" || n === "collections" || n === "collection"
        || _libraryHas(n, "collection");
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
        var width = Number(video.Width || 0);
        var res = width >= 1900 ? "1080p"
                : width >= 1200 ? "720p"
                : width >= 700 ? "480p"
                : width > 0 ? width + "p"
                : video.Height ? Number(video.Height) + "p" : "";
        if (res) chips.push({ t: res, c: "#232373", px: 14 });
        if (video.Codec) chips.push({ t: String(video.Codec).toUpperCase(), c: "#5a45b6", px: 14 });
    }
    if (audio) {
        if (audio.Codec) chips.push({ t: String(audio.Codec).toUpperCase(), c: "#295393", px: 14 });
        if (Number(audio.Channels) > 0) chips.push({ t: Number(audio.Channels) + ".0", c: "#234", px: 14 });
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

/* ===== Helpers PersonPage ===== */
function personCreditsSortKey(it) {
    return safeString(it && (it.SortName || it.Name)).toLowerCase();
}
function personCreditsSortItems(a, b) {
    var aa = personCreditsSortKey(a), bb = personCreditsSortKey(b);
    if (aa < bb) return -1;
    if (aa > bb) return 1;
    return safeString(a && a.Id) < safeString(b && b.Id) ? -1 : 1;
}
function personEpisodeCode(it) {
    if (!it) return "";
    var season = Number(it.ParentIndexNumber), episode = Number(it.IndexNumber);
    season = isFinite(season) ? season : -1;
    episode = isFinite(episode) ? episode : -1;
    if (season < 0 && episode < 0) return "";
    function pad2(n) { return n < 10 ? ("0" + n) : String(n); }
    if (season >= 0 && episode >= 0) return "S" + pad2(season) + "E" + pad2(episode);
    if (episode >= 0) return "E" + pad2(episode);
    return "S" + pad2(season);
}
function personEpisodeMeta(it) {
    if (!it) return "";
    var seriesName = safeString(it.SeriesName || "");
    var code = personEpisodeCode(it);
    return seriesName.length && code.length ? seriesName + " • " + code
         : seriesName.length ? seriesName : code;
}
function personEpisodeSortItems(a, b) {
    var sa = safeString(a && (a.SeriesName || a.Series || "")).toLowerCase();
    var sb = safeString(b && (b.SeriesName || b.Series || "")).toLowerCase();
    if (sa < sb) return -1;
    if (sa > sb) return 1;
    var sea = Number(a && a.ParentIndexNumber), seb = Number(b && b.ParentIndexNumber);
    sea = isFinite(sea) ? sea : 99999;
    seb = isFinite(seb) ? seb : 99999;
    if (sea !== seb) return sea - seb;
    var ea = Number(a && a.IndexNumber), eb = Number(b && b.IndexNumber);
    ea = isFinite(ea) ? ea : 99999;
    eb = isFinite(eb) ? eb : 99999;
    if (ea !== eb) return ea - eb;
    return personCreditsSortItems(a, b);
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
    var itemType = itemTypeLower(it), ownTags = it.ImageTags || {};
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
function homeCacheEntryValid(entry, schemaVersion, freshMs, now) {
    return !!entry && entry.schemaVersion === schemaVersion && !!entry.ts
        && (now - Number(entry.ts || 0)) <= freshMs;
}
function touchHomeCache(store, key, schemaVersion, freshMs, now) {
    var entry = store ? store[key] : null;
    if (!homeCacheEntryValid(entry, schemaVersion, freshMs, now)) {
        try { if (entry) delete store[key]; } catch (e) {}
        return null;
    }
    entry.lastAccess = now;
    return entry;
}
function trimHomeCacheStore(store, keepKey, schemaVersion, freshMs, maxEntries, now) {
    if (!store) return;
    var entries = [];
    for (var key in store) {
        try {
            if (!Object.prototype.hasOwnProperty.call(store, key)) continue;
            var entry = store[key];
            if (!homeCacheEntryValid(entry, schemaVersion, freshMs, now)) {
                delete store[key];
                continue;
            }
            entries.push({ key:key, touch:Number(entry.lastAccess || entry.ts || 0) });
        } catch (e) {}
    }
    entries.sort(function(a, b) { return a.touch - b.touch; });
    while (entries.length > maxEntries) {
        var victim = entries.shift();
        if (!victim) break;
        if (victim.key === keepKey && entries.length > 0) {
            entries.push(victim);
            continue;
        }
        try { delete store[victim.key]; } catch (e2) {}
    }
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
        if (_rdfS(ga.id) !== _rdfS(gb.id) || !homeItemsEqual(ga.items || [], gb.items || [])) return false;
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
    if (detail.MediaStreams !== undefined && detail.MediaStreams !== null)
        out.MediaStreams = compactHeaderStreams(detail.MediaStreams)
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

function personOverviewPresent(person) {
    return !!person && plainOverview(person.Overview || "").length > 0;
}

function personBirthDatePresent(person) {
    return !!person && safeString(person.BirthDate || person.PremiereDate || "").length > 0;
}

function personMetadataNeedsRefresh(person) {
    return !person || !personOverviewPresent(person) || !personBirthDatePresent(person);
}

function mergePersonMetadata(richPerson, userScopedPerson) {
    var rich = richPerson || null, scoped = userScopedPerson || null;
    if (!rich) return scoped;
    if (!scoped) return rich;
    if (scoped.UserData) rich.UserData = scoped.UserData;
    if (!personOverviewPresent(rich) && personOverviewPresent(scoped)) rich.Overview = scoped.Overview;
    if (!personBirthDatePresent(rich) && personBirthDatePresent(scoped)) {
        if (scoped.BirthDate) rich.BirthDate = scoped.BirthDate;
        else rich.PremiereDate = scoped.PremiereDate;
    }
    if (!rich.DeathDate && scoped.DeathDate) rich.DeathDate = scoped.DeathDate;
    if (!rich.EndDate && scoped.EndDate) rich.EndDate = scoped.EndDate;
    return rich;
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

function catalogPageWindowStart(pages) {
    pages = safeArray(pages);
    return pages.length ? Math.max(0, pages[0].start | 0) : 0;
}

function catalogPageWindowEnd(pages) {
    pages = safeArray(pages);
    if (!pages.length) return 0;
    var last = pages[pages.length - 1] || ({});
    return Math.max(0, (last.start | 0) + safeArray(last.items).length);
}

function catalogPageStartForItemId(pages, id) {
    pages = safeArray(pages);
    id = safeString(id);
    for (var pageIndex = 0; id && pageIndex < pages.length; ++pageIndex) {
        var page = pages[pageIndex] || ({}), items = safeArray(page.items);
        if (findItemIndexById(items, id) >= 0) return Math.max(0, page.start | 0);
    }
    return catalogPageWindowStart(pages);
}

function appendCatalogPageWindow(pages, items, start, limit, direction, maxItems) {
    pages = safeArray(pages).slice(0);
    items = safeArray(items);
    var replaced = false;
    for (var i = 0; i < pages.length; ++i) {
        if ((pages[i].start | 0) !== (start | 0)) continue;
        pages[i] = { start:start, limit:limit, items:items, full:items.length >= limit };
        replaced = true;
        break;
    }
    if (!replaced && items.length)
        pages.push({ start:start, limit:limit, items:items, full:items.length >= limit });
    pages.sort(function(a, b) { return Number(a.start || 0) - Number(b.start || 0); });
    var rawCount = function() {
        var count = 0;
        for (var pageIndex = 0; pageIndex < pages.length; ++pageIndex)
            count += safeArray(pages[pageIndex] && pages[pageIndex].items).length;
        return count;
    };
    while (pages.length > 1 && rawCount() > Number(maxItems || 0)) {
        if (direction === "backward") pages.pop();
        else pages.shift();
    }
    if (!items.length && pages.length) {
        if (direction === "backward") pages[0].start = 0;
        else pages[pages.length - 1].full = false;
    }
    return {
        pages: pages,
        hasMoreBefore: pages.length > 0 && Number(pages[0].start || 0) > 0,
        hasMoreAfter: pages.length > 0 && pages[pages.length - 1].full === true
    };
}

function personCreditBuckets(pages) {
    pages = safeArray(pages).slice(0);
    pages.sort(function(a, b) { return Number(a.start || 0) - Number(b.start || 0); });
    var seen = ({}), movies = [], series = [], episodes = [];
    for (var pageIndex = 0; pageIndex < pages.length; ++pageIndex) {
        var items = safeArray(pages[pageIndex] && pages[pageIndex].items);
        for (var itemIndex = 0; itemIndex < items.length; ++itemIndex) {
            var item = items[itemIndex], id = item && item.Id ? String(item.Id) : "";
            if (!item || !id || seen[id]) continue;
            seen[id] = true;
            var typeName = itemTypeLower(item);
            if (typeName === "movie") movies.push(item);
            else if (typeName === "series") series.push(item);
            else if (typeName === "episode") episodes.push(item);
        }
    }
    try { episodes.sort(personEpisodeSortItems); } catch (sortError) {}
    return { movies:movies, series:series, episodes:episodes };
}

function personCreditsPageContains(items, railKind) {
    if (!railKind) return true;
    var wanted = railKind === "movies" ? "movie" : (railKind === "series" ? "series" : "episode");
    items = safeArray(items);
    for (var i = 0; i < items.length; ++i)
        if (itemTypeLower(items[i]) === wanted) return true;
    return false;
}

// Métadonnées d’épisode, chapitres et choix d’images de saison.
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

function _seasonBackdropBlur(v) {
    var n = (v === undefined || v === null) ? 25 : (v | 0);
    if (n < 1) n = 1;
    if (n > 50) n = 50;
    return n;
}

function _seasonBackdropImageUrl(Jellyfin, serverUrl, id, tag, w, h, q, blur) {
    return Jellyfin.itemImageUrl(serverUrl, id, "Backdrop", tag, {
        fillWidth: w, fillHeight: h, quality: q, blur: blur
    });
}

function _seasonPrimaryImageUrl(Jellyfin, serverUrl, id, tag, w, h, q, blur) {
    return Jellyfin.itemImageUrl(serverUrl, id, "Primary", tag, {
        fillWidth: w, fillHeight: h, quality: q, blur: blur
    });
}

function seasonBackdropUrl(Jellyfin, a, seasonItem, episodes, seriesId, seasonId, bgBlur, backdropQuality) {
    var ctx = null; var serverUrl = ""; var blur = 13; var q = 70; var w = 1280, h = 720;
    if (a && typeof a === "object") {
        ctx = a;
        serverUrl = ctx.serverUrl || "";
        seasonItem = ctx.seasonItem || null;
        episodes = ctx.episodes || null;
        seriesId = ctx.seriesId || "";
        seasonId = ctx.seasonId || "";
        bgBlur = (ctx.bgBlur !== undefined) ? ctx.bgBlur : bgBlur;
        backdropQuality = (ctx.backdropQuality !== undefined) ? ctx.backdropQuality : backdropQuality;
    } else {
        serverUrl = a || "";
    }
    var baseNoSlash = serverUrl;
    if (!baseNoSlash)
        return "";
    blur = _seasonBackdropBlur(bgBlur);
    q = (backdropQuality !== undefined && backdropQuality !== null) ? (backdropQuality | 0) : 70;
    function firstTag(arr) { return (arr && arr.length) ? String(arr[0] || "") : ""; }
    var parentId = ""; var parentTag = "";
    if (seasonItem && seasonItem.ParentBackdropItemId
        && seasonItem.ParentBackdropImageTags
        && seasonItem.ParentBackdropImageTags.length > 0) {
        parentId = seasonItem.ParentBackdropItemId;
        parentTag = firstTag(seasonItem.ParentBackdropImageTags);
    } else if (episodes && episodes.length > 0) {
        var e0 = episodes[0];
        if (e0 && e0.ParentBackdropItemId
            && e0.ParentBackdropImageTags
            && e0.ParentBackdropImageTags.length > 0) {
            parentId = e0.ParentBackdropItemId;
            parentTag = firstTag(e0.ParentBackdropImageTags);
        }
    }
    if (parentId)
        return _seasonBackdropImageUrl(Jellyfin, baseNoSlash, parentId, parentTag, w, h, q, blur);
    if (seriesId)
        return _seasonBackdropImageUrl(Jellyfin, baseNoSlash, seriesId, "", w, h, q, blur);
    if (seasonItem && seasonItem.Id) {
        if (seasonItem.BackdropImageTags && seasonItem.BackdropImageTags.length > 0)
            return _seasonBackdropImageUrl(Jellyfin, baseNoSlash, seasonItem.Id, firstTag(seasonItem.BackdropImageTags), w, h, q, blur);
        if (seasonItem.ImageTags && seasonItem.ImageTags.Primary)
            return _seasonPrimaryImageUrl(Jellyfin, baseNoSlash, seasonItem.Id, seasonItem.ImageTags.Primary, w, h, q, blur);
    }
    if (seasonId)
        return _seasonBackdropImageUrl(Jellyfin, baseNoSlash, seasonId, "", w, h, q, blur);
    return "";
}

function episodeCode(ep, seasonItem) {
    if (!ep)
        return "";
    var s = (ep.ParentIndexNumber !== null && ep.ParentIndexNumber !== undefined)
          ? ep.ParentIndexNumber
          : ((seasonItem && seasonItem.IndexNumber !== null && seasonItem.IndexNumber !== undefined)
                ? seasonItem.IndexNumber
                : "");
    var e = (ep.IndexNumber !== null && ep.IndexNumber !== undefined)
          ? ep.IndexNumber
          : "";
    if (s === "" && e === "")
        return "";
    return "S" + (s === "" ? "?" : s) + ":" + "E" + (e === "" ? "?" : e);
}

function _episodeNameLooksLikeFilename(name) {
    if (!name)
        return false;
    var n = String(name);
    if (/\.(mkv|mp4|avi|mov|wmv|m4v|flv|ts|m2ts)$/i.test(n))
        return true;
    return (n.indexOf(".") >= 0 && n.split(".").length > 2) || /[_-]\d{3,}/.test(n);
}

function episodeDisplayTitle(ep) {
    if (!ep)
        return "";

    var name = (ep.Name !== undefined && ep.Name !== null)
             ? String(ep.Name).replace(/^\s+|\s+$/g, "")
             : "";
    var originalTitle = (ep.OriginalTitle !== undefined && ep.OriginalTitle !== null)
                      ? String(ep.OriginalTitle).replace(/^\s+|\s+$/g, "")
                      : "";

    // Préférer les métadonnées propres sans jamais jeter un titre Jellyfin valide.
    if (name.length && !_episodeNameLooksLikeFilename(name))
        return name;
    if (originalTitle.length && !_episodeNameLooksLikeFilename(originalTitle))
        return originalTitle;

    // Un Name imparfait reste plus informatif que le fallback générique "Épisode N".
    if (name.length)
        return name;
    if (originalTitle.length)
        return originalTitle;

    if (ep.IndexNumber !== null && ep.IndexNumber !== undefined)
        return "Épisode " + ep.IndexNumber;

    return "Épisode";
}

function _seasonSeriesId(seriesId, selectedEpisode, seasonItem) {
    var sid = String(seriesId || "");
    if (!sid && selectedEpisode) {
        try {
            if (selectedEpisode.SeriesId) sid = String(selectedEpisode.SeriesId);
        } catch (e0) {}
    }
    if (!sid && seasonItem) {
        try {
            if (seasonItem.SeriesId) sid = String(seasonItem.SeriesId);
        } catch (e1) {}
    }
    if (!sid && seasonItem) {
        try {
            if (seasonItem.Id) sid = String(seasonItem.Id);
        } catch (e2) {}
    }
    return sid;
}

function _seasonSeriesPrimaryTag(selectedEpisode, seasonItem, ctxSeriesItem) {
    try {
        if (ctxSeriesItem && ctxSeriesItem.ImageTags && ctxSeriesItem.ImageTags.Primary)
            return String(ctxSeriesItem.ImageTags.Primary);
    } catch (e0) {}
    try {
        if (seasonItem && seasonItem.SeriesPrimaryImageTag)
            return String(seasonItem.SeriesPrimaryImageTag);
    } catch (e1) {}
    try {
        if (selectedEpisode && selectedEpisode.SeriesPrimaryImageTag)
            return String(selectedEpisode.SeriesPrimaryImageTag);
    } catch (e2) {}
    try {
        if (seasonItem && seasonItem.ImageTags && seasonItem.ImageTags.Primary && seasonItem.Type === "Series")
            return String(seasonItem.ImageTags.Primary);
    } catch (e3) {}
    return "";
}

function _seasonSeriesPosterUrl(Jellyfin, serverUrl, seriesId, tag, w, h, q) {
    return Jellyfin.itemImageUrl(serverUrl, seriesId, "Primary", tag, {
        format: "jpg", quality: q, fillWidth: w, fillHeight: h
    });
}

function seasonPosterFallbackUrl(Jellyfin, a, seriesId, selectedEpisode, seasonItem,
                                       cardW, cardH, posterRequestScale, posterRequestQuality) {
    var ctx = null; var serverUrl = ""; var episodes = null;
    if (a && typeof a === "object") {
        ctx = a;
        serverUrl = ctx.serverUrl || "";
        seriesId = ctx.seriesId || seriesId || "";
        selectedEpisode = ctx.selectedEpisode || selectedEpisode || null;
        seasonItem = ctx.seasonItem || seasonItem || null;
        cardW = ctx.episodeCardW || ctx.cardW || cardW || 360;
        cardH = ctx.episodeCardH || ctx.cardH || cardH || 240;
        posterRequestScale = (ctx.posterRequestScale !== undefined) ? ctx.posterRequestScale : posterRequestScale;
        posterRequestQuality = (ctx.posterRequestQuality !== undefined) ? ctx.posterRequestQuality : posterRequestQuality;
        episodes = ctx.episodes || null;
    } else {
        serverUrl = a || "";
    }
    if (!serverUrl)
        return "";
    if (!selectedEpisode && episodes && episodes.length) selectedEpisode = episodes[0];
    var sid = _seasonSeriesId(seriesId, selectedEpisode, seasonItem);
    if (!sid)
        return "";
    var base = serverUrl;
    if (!base)
        return "";
    var scale = (posterRequestScale !== undefined && posterRequestScale !== null) ? Number(posterRequestScale) : 1.0;
    if (!(scale > 0)) scale = 1.0;
    var reqW = Math.max(200, Math.round((cardW || 360) * scale)); var reqH = Math.max(140, Math.round((cardH || 240) * scale)); var q = (posterRequestQuality !== undefined && posterRequestQuality !== null) ? (posterRequestQuality | 0) : 72;
    var ctxSeriesItem = null;
    try { if (ctx && ctx.seriesItem) ctxSeriesItem = ctx.seriesItem; } catch (e0) { ctxSeriesItem = null; }
    var tag = _seasonSeriesPrimaryTag(selectedEpisode, seasonItem, ctxSeriesItem);
    return _seasonSeriesPosterUrl(Jellyfin, base, sid, tag, reqW, reqH, q);
}

function _episodeStreamTags(it) {
    if (!it)
        return [];
    var ms = (it.MediaStreams || []); var v = null; var aud = [];
    var i;
    for (i = 0; i < ms.length; i++) {
        var s = ms[i];
        if (s && s.Type === "Video" && !v)
            v = s;
        if (s && s.Type === "Audio")
            aud.push(s);
    }
    var tags = []; var hasSub = false;
    if (it.SubtitleFiles && it.SubtitleFiles.length)
        hasSub = true;
    else {
        for (i = 0; i < ms.length; i++) {
            if (ms[i] && ms[i].Type === "Subtitle") { hasSub = true; break; }
        }
    }
    if (hasSub)
        tags.push("ST");
    if (v) {
        if (v.Width && v.Height) {
            var hh = v.Height;
            if (hh >= 2160)      tags.push("2160p");
            else if (hh >= 1440) tags.push("1440p");
            else if (hh >= 1080) tags.push("1080p");
            else if (hh >= 720)  tags.push("720p");
            else                 tags.push(hh + "p");
        }
        if (v.Codec)
            tags.push(String(v.Codec).toUpperCase());
        if (v.VideoRange)
            tags.push(String(v.VideoRange).toUpperCase());
    }
    if (aud.length > 0) {
        var a = aud[0];
        if (a.Codec)
            tags.push(String(a.Codec).toUpperCase());
        if (a.ChannelLayout)
            tags.push(String(a.ChannelLayout).toUpperCase());
        else if (a.Channels) {
            if (a.Channels >= 6)       tags.push("5.1");
            else if (a.Channels === 2) tags.push("STEREO");
        }
    }
    if (it.Container) {
        var c = String(it.Container).toUpperCase(); var found = false;
        for (i = 0; i < tags.length; i++) {
            if (tags[i] === c) { found = true; break; }
        }
        if (!found)
            tags.push(c);
    }
    return tags;
}

function seasonLogoUrl(Jellyfin, serverUrl, seriesId, selectedEpisode, seasonItem,
                              maxW, seriesLogoMaxW) {
    var sid = seriesId ||
              (selectedEpisode &&
                (selectedEpisode.SeriesId ||
                 (selectedEpisode.SeriesPrimaryImageTag && selectedEpisode.SeriesId))) ||
              (seasonItem &&
                (seasonItem.SeriesId || seasonItem.Id)) ||
              "";
    if (!serverUrl || !sid)
        return "";
    var baseW = seriesLogoMaxW || 320;
    var w = Math.max(64, Math.round((maxW || baseW) * 2));
    return Jellyfin.itemImageUrl(serverUrl, sid, "Logo", "", { quality: 85, maxWidth: w });
}

function episodeOverviewPayload(Jellyfin, ep, serverUrl) {
    if (!ep || !ep.Overview)
        return null;
    var posterUrl = "";
    if (serverUrl && ep.ImageTags && ep.ImageTags.Primary) {
        posterUrl = Jellyfin.itemImageUrl(serverUrl, ep.Id, "Primary", ep.ImageTags.Primary,
                                           { quality: 88 });
    }
    return {
        posterUrl: posterUrl,
        overview: ep.Overview
    };
}

function _episodeTagFold(v) {
    var s = String(v || "").toLowerCase();
    s = s.replace(/[àáâãäåā]/g, "a");
    s = s.replace(/[ç]/g, "c");
    s = s.replace(/[èéêëēėę]/g, "e");
    s = s.replace(/[îïíīįì]/g, "i");
    s = s.replace(/[ôöòóõøō]/g, "o");
    s = s.replace(/[ùúûüū]/g, "u");
    s = s.replace(/[ÿ]/g, "y");
    s = s.replace(/\s+/g, " ");
    s = s.replace(/^\s+/, "").replace(/\s+$/, "");
    return s;
}

function _episodeStreamType(st) {
    if (!st) return "";
    if (st.Type === 0) return "Audio";
    if (st.Type === 1) return "Video";
    if (st.Type === 2) return "Subtitle";
    var t = String(st.Type || st.type || "").toLowerCase();
    if (t === "audio") return "Audio";
    if (t === "video") return "Video";
    if (t === "subtitle") return "Subtitle";
    return "";
}

function _episodeTagHasAny(s, arr) {
    for (var i = 0; i < arr.length; i++) {
        if (s.indexOf(arr[i]) >= 0) return true;
    }
    return false;
}

function _episodeStreamLangCode(st) {
    var raw = _episodeTagFold((st && (st.Language || st.language)) || ""); var blob = _episodeTagFold((st && (st.DisplayTitle || st.Title || st.displayTitle || st.title)) || "");
    if (raw === "fr" || raw === "fra" || raw === "fre" || raw === "french" || raw === "francais" || _episodeTagHasAny(blob, ["francais", "french"])) return "FR";
    if (raw === "en" || raw === "eng" || raw === "english" || _episodeTagHasAny(blob, ["anglais", "english"])) return "EN";
    if (raw === "ja" || raw === "jp" || raw === "jpn" || raw === "japanese" || _episodeTagHasAny(blob, ["japonais", "japanese"])) return "JP";
    if (raw === "es" || raw === "spa" || raw === "esp" || raw === "spanish" || _episodeTagHasAny(blob, ["espagnol", "spanish"])) return "ES";
    if (raw === "de" || raw === "ger" || raw === "deu" || raw === "german" || _episodeTagHasAny(blob, ["allemand", "german"])) return "DE";
    if (raw === "it" || raw === "ita" || raw === "italian" || _episodeTagHasAny(blob, ["italien", "italian"])) return "IT";
    if (raw === "pt" || raw === "por" || raw === "portuguese" || _episodeTagHasAny(blob, ["portugais", "portuguese"])) return "PT";
    if (raw === "ko" || raw === "kor" || raw === "korean" || _episodeTagHasAny(blob, ["coreen", "korean"])) return "KO";
    if (raw === "zh" || raw === "chi" || raw === "zho" || raw === "chinese" || _episodeTagHasAny(blob, ["chinois", "chinese"])) return "ZH";
    if (raw === "ru" || raw === "rus" || raw === "russian" || _episodeTagHasAny(blob, ["russe", "russian"])) return "RU";
    if (raw.length >= 2) return raw.substr(0, 2).toUpperCase();
    return "";
}

function _episodeTagPushUnique(arr, value) {
    value = String(value || "");
    if (!value.length) return;
    for (var i = 0; i < arr.length; i++) {
        if (arr[i] === value) return;
    }
    arr.push(value);
}

function _episodeStreamLangListTag(src, streamType, prefix) {
    if (!src || !src.MediaStreams) return "";
    var langs = []; var count = 0;
    for (var i = 0; i < src.MediaStreams.length; i++) {
        var st = src.MediaStreams[i];
        if (!st || _episodeStreamType(st) !== streamType) continue;
        count++;
        _episodeTagPushUnique(langs, _episodeStreamLangCode(st));
    }
    if (count <= 0) return "";
    if (langs.length > 0) return prefix + " " + langs.join(" / ");
    return prefix + " " + count + " piste" + (count > 1 ? "s" : "");
}

function _isGenericEpisodeTrackTag(tag) {
    var s = _episodeTagFold(tag);
    if (!s || /^\+[0-9]+$/.test(s)) return true;
    if (s === "st" || s === "sub" || s === "subs" || s === "subtitle" || s === "subtitles" || s === "sous titres" || s === "sous-titres") return true;
    if (s === "multi" || s === "multi audio" || s === "multiaudio" || s === "audio multi") return true;
    return false;
}

function _episodeLanguageTags(src, baseTags) {
    var out = [];
    baseTags = baseTags || [];
    for (var i = 0; i < baseTags.length; i++) {
        var tag = String(baseTags[i] || "");
        if (!_isGenericEpisodeTrackTag(tag)) _episodeTagPushUnique(out, tag);
    }
    var audioTag = _episodeStreamLangListTag(src, "Audio", "AUDIO"); var subTag = _episodeStreamLangListTag(src, "Subtitle", "ST");
    if (audioTag.length > 0) _episodeTagPushUnique(out, audioTag);
    if (subTag.length > 0) _episodeTagPushUnique(out, subTag);
    return out;
}

function episodeTechChips(src) {
    if (!src) return [];
    var t = [];
    try { t = _episodeStreamTags(src) || []; } catch (e0) { t = []; }
    return _episodeLanguageTags(src, t);
}

function compactEpisodeDetails(details) {
    if (!details) return null;
    var streams = [], sourceStreams = details.MediaStreams || [];
    for (var i = 0; i < sourceStreams.length; ++i) {
        var stream = sourceStreams[i];
        if (!stream) continue;
        streams.push({
            Type: stream.Type, Codec: stream.Codec || "", Width: Number(stream.Width || 0),
            Height: Number(stream.Height || 0), VideoRange: stream.VideoRange || "",
            ChannelLayout: stream.ChannelLayout || "", Channels: Number(stream.Channels || 0),
            Language: stream.Language || "", DisplayTitle: stream.DisplayTitle || "",
            Title: stream.Title || ""
        });
    }
    var directors = [], people = details.People || [];
    for (var p = 0; p < people.length; ++p) {
        var person = people[p] || {};
        var role = String(person.Type || person.Role || person.Job || "");
        if (/director/i.test(role)) {
            directors.push({ Name: person.Name || "", Type: person.Type || "",
                               Role: person.Role || "", Job: person.Job || "" });
        }
    }
    var tags = details.ImageTags || {};
    return {
        Id: details.Id || "", Name: details.Name || "", Type: details.Type || "Episode",
        Overview: details.Overview || "", CommunityRating: details.CommunityRating,
        OfficialRating: details.OfficialRating || "", ProductionYear: details.ProductionYear,
        PremiereDate: details.PremiereDate || "", RunTimeTicks: Number(details.RunTimeTicks || 0),
        Container: details.Container || "", UserData: details.UserData || null,
        ImageTags: tags.Primary ? { Primary: tags.Primary } : {}, People: directors,
        SubtitleFiles: (details.SubtitleFiles && details.SubtitleFiles.length) ? [true] : [],
        MediaStreams: streams
    };
}
