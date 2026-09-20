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
 * Ces fonctions ne font aucun I/O et n'ont aucun état réseau. Elles vivent ici
 * pour éviter que jellyfinBridge mélange transport/API et mécanique de pagination.
 * Les pages de bibliothèque conservent uniquement l'orchestration QML et le focus.
 */
function _rdfS(v) {
    return (v === undefined || v === null) ? "" : String(v);
}
function _rdfInt(v) {
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
    var limit = Math.max(1, _rdfInt(characterLimit));
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
function emptyText(mode, musicVideoMode) {
    if (musicVideoMode) return "Aucun clip trouvé.";
    var m = normalizeMode(mode);
    if (m === "personal") return "Aucune photo ou vidéo trouvée.";
    if (m === "collections") return "Aucune collection trouvée.";
    return m === "series" ? "Aucune série trouvée."
         : (m === "mixed" ? "Aucun film ou série trouvé." : "Aucun film trouvé.");
}
var FOLDER_SORT_LABELS = [
    "Nom",
    "Date d'ajout",
    "Date de sortie",
    "Note de la communauté",
    "Dernière lecture",
    "Durée de lecture"
];
function folderSortOptionLabels() {
    return FOLDER_SORT_LABELS.slice(0);
}
function _sortCleanName(it) {
    var n = _rdfS((it && (it.SortName || it.Name)) || "");
    return n.toLowerCase ? n.toLowerCase() : n;
}
function _sortDateMs(v) {
    v = _rdfS(v);
    if (!v) return 0;
    try {
        var t = Date.parse(v);
        return isFinite(t) ? t : 0;
    } catch (e) {
        return 0;
    }
}
function _sortYearMs(v) {
    var y = Number(v || 0);
    if (!isFinite(y) || y <= 0) return 0;
    return Date.UTC(Math.floor(y), 0, 1);
}
function _sortNum(v) {
    var n = Number(v || 0);
    return (isFinite(n) && !isNaN(n)) ? n : 0;
}
function _sortDateAddedKey(it) {
    if (!it) return 0;
    return _sortDateMs(it.DateCreated)
        || _sortDateMs(it.DateLastMediaAdded)
        || _sortDateMs(it.DateLastRefreshed)
        || _sortDateMs(it.PremiereDate)
        || _sortYearMs(it.ProductionYear);
}
function _sortReleaseDateKey(it) {
    if (!it) return 0;
    return _sortDateMs(it.PremiereDate) || _sortYearMs(it.ProductionYear);
}
function _sortLastPlayedKey(it) {
    var ud = userDataOf(it);
    return _sortDateMs(ud.LastPlayedDate)
        || _sortDateMs(it.LastPlayedDate)
        || _sortDateMs(it.DatePlayed);
}
function _folderSortKey(it, mode) {
    mode = _rdfInt(mode);
    if (mode === 1) return _sortDateAddedKey(it);
    if (mode === 2) return _sortReleaseDateKey(it);
    if (mode === 3) return _sortNum(it && it.CommunityRating);
    if (mode === 4) return _sortLastPlayedKey(it);
    if (mode === 5) return _sortNum(it && (it.RunTimeTicks || it.CumulativeRunTimeTicks));
    return _sortCleanName(it);
}
function folderSortCompare(a, b, mode) {
    mode = _rdfInt(mode);
    var desc = mode > 0;
    if (mode === 0) {
        var na = _sortCleanName(a), nb = _sortCleanName(b);
        return na < nb ? -1 : (na > nb ? 1 : 0);
    }
    var ka = _folderSortKey(a, mode), kb = _folderSortKey(b, mode);
    var az = (ka === undefined || ka === null || ka === "" || ka === 0);
    var bz = (kb === undefined || kb === null || kb === "" || kb === 0);
    if (az && !bz) return 1;
    if (bz && !az) return -1;
    if (ka < kb) return desc ? 1 : -1;
    if (ka > kb) return desc ? -1 : 1;
    var fa = _sortCleanName(a), fb = _sortCleanName(b);
    return fa < fb ? -1 : (fa > fb ? 1 : 0);
}
function folderSortItems(items, mode) {
    var arr = (items || []).slice(0);
    arr.sort(function(a, b) {
        return folderSortCompare(a, b, mode);
    });
    return arr;
}
// Helpers purs de fenêtre de pagination partagés par Movie/Collection/PersonalMedia.
function _browserString(v) { return _rdfS(v); }
function _browserInt(v) { return _rdfInt(v); }
function _browserPosInt(v) { return Math.max(0, _rdfInt(v)); }
// Ils ne touchent ni au GridView ni au focus : les pages gardent l'orchestration UI.

function _mediaBrowserReturnStack(shared) {
    if (!shared) return null;
    if (!shared.__mediaBrowserReturnStack) shared.__mediaBrowserReturnStack = [];
    return shared.__mediaBrowserReturnStack;
}
function _trimMediaBrowserReturnStack(shared) {
    var stack = _mediaBrowserReturnStack(shared);
    if (!stack) return null;
    var now = Date.now();
    var out = [];
    for (var i = 0; i < stack.length; ++i) {
        var entry = stack[i];
        if (entry && entry.folderId && (now - Number(entry.ts || 0)) < 1200000) out.push(entry);
    }
    while (out.length > 12) out.shift();
    shared.__mediaBrowserReturnStack = out;
    return out;
}
function pushBrowserReturn(shared, folderId, childFolderId, browserTitle, index, y, libraryMode) {
    var stack = _trimMediaBrowserReturnStack(shared);
    if (!stack || !folderId) return false;
    stack.push({
        folderId: _rdfS(folderId), childFolderId: _rdfS(childFolderId), browserTitle: _rdfS(browserTitle),
        index: _rdfInt(index), y: Math.max(0, Math.floor(Number(y) || 0)),
        libraryMode: normalizeMode(libraryMode), ts: Date.now()
    });
    while (stack.length > 12) stack.shift();
    shared.__mediaBrowserReturnStack = stack;
    return true;
}
function popBrowserParent(shared, currentFolderId) {
    var stack = _trimMediaBrowserReturnStack(shared);
    if (!stack || !stack.length) return null;
    var top = stack[stack.length - 1];
    if (!top || (top.childFolderId && _rdfS(top.childFolderId) !== _rdfS(currentFolderId))) return null;
    var entry = stack.pop();
    shared.__mediaBrowserReturnStack = stack;
    return entry || null;
}

function browserRestoreIndex(restoreIndex, startIndex) {
    var restore = _browserInt(restoreIndex);
    if (Number(restoreIndex) >= 0) return restore;
    var start = _browserInt(startIndex);
    return Number(startIndex) >= 0 ? start : -1;
}
function browserRestoreY(restoreY) {
    var y = Number(restoreY);
    return isFinite(y) && y >= 0 ? y : -1;
}
function browserSortedWindow(items, mode, serverSortedPage, keepId, currentIndex, forceFirst) {
    var sorted = serverSortedPage === true ? (items || []) : folderSortItems(items || [], mode);
    if (!sorted.length) return { items: sorted, index: -1 };
    var idx = forceFirst === true ? 0 : (keepId ? browserFindItemIndexById(sorted, keepId) : _browserInt(currentIndex));
    if (idx < 0 || idx >= sorted.length) idx = 0;
    return { items: sorted, index: idx };
}
function browserSelectedItemId(items, localIndex) {
    localIndex = _browserInt(localIndex);
    var it = items && localIndex >= 0 && localIndex < items.length ? items[localIndex] : null;
    return it && it.Id ? _browserString(it.Id) : "";
}
function browserSelectedItem(items, localIndex) {
    localIndex = _browserInt(localIndex);
    return items && localIndex >= 0 && localIndex < items.length ? items[localIndex] : null;
}
function browserFindItemIndexById(items, id) {
    id = _browserString(id); items = items || [];
    if (!id) return -1;
    for (var i = 0; i < items.length; i++) if (items[i] && _browserString(items[i].Id) === id) return i;
    return -1;
}
function browserGlobalIndex(items, windowStart, localIndex) {
    localIndex = _browserInt(localIndex); windowStart = _browserPosInt(windowStart);
    if (localIndex < 0) return -1;
    var it = items && localIndex < items.length ? items[localIndex] : null;
    return (it && it._windowGlobalIndex !== undefined) ? _browserInt(it._windowGlobalIndex) : windowStart + localIndex;
}
function browserLocalIndex(items, windowStart, globalIndex) {
    items = items || []; windowStart = _browserPosInt(windowStart); globalIndex = _browserInt(globalIndex);
    if (globalIndex < 0) return -1;
    for (var i = 0; i < items.length; i++) {
        var it = items[i];
        var gi = (it && it._windowGlobalIndex !== undefined) ? _browserInt(it._windowGlobalIndex) : windowStart + i;
        if (gi === globalIndex) return i;
    }
    return -1;
}
function browserWindowKnownEnd(items, windowStart) {
    items = items || []; windowStart = _browserPosInt(windowStart);
    if (!items.length) return windowStart;
    var last = items[items.length - 1];
    return (last && last._windowGlobalIndex !== undefined) ? _browserInt(last._windowGlobalIndex) + 1 : windowStart + items.length;
}
function browserPreviousPageStart(windowStart, pageSize) {
    windowStart = _browserPosInt(windowStart);
    pageSize = Math.max(1, _browserPosInt(pageSize));
    if (windowStart <= 0) return -1;
    var start = Math.max(0, windowStart - pageSize);
    return start < windowStart ? start : -1;
}
function browserViewportLoadDirection(localIndex, itemCount, hasPrevious, hasMore, prependThreshold, appendThreshold) {
    localIndex = _browserInt(localIndex);
    itemCount = _browserPosInt(itemCount);
    if (localIndex < 0) return 0;
    if (hasPrevious === true && localIndex <= _browserPosInt(prependThreshold)) return -1;
    var appendAt = Math.max(0, itemCount - Math.max(1, _browserPosInt(appendThreshold)));
    if (hasMore === true && localIndex >= appendAt) return 1;
    return 0;
}
function hasPrimaryOrThumb(it) {
    if (!it) return false;
    var tags = it.ImageTags || {};
    return !!(tags.Primary || tags.Thumb);
}
function browserLoadedIds(items) {
    items = items || []; var seen = {};
    for (var i = 0; i < items.length; i++) { var id = items[i] && items[i].Id ? _browserString(items[i].Id) : ""; if (id) seen[id] = 1; }
    return seen;
}

function browserInitialPagingState(targetIndex, pageSize) {
    var size = Math.max(1, _browserPosInt(pageSize));
    var target = _browserInt(targetIndex);
    var start = target >= 0 ? Math.max(0, Math.floor(target / size) * size) : 0;
    return {
        windowStartIndex: start,
        nextStart: start,
        hasMore: true,
        hasPrevious: start > 0
    };
}
function browserPageProgress(page, start, pageSize, prepend) {
    page = page || {};
    start = Math.max(0, _browserInt(start));
    var size = Math.max(1, _browserPosInt(pageSize));
    var items = page.items || [];
    if (prepend === true) {
        return { hasPrevious: start > 0, nextStart: null, hasMore: null };
    }
    var nextStart = (page.nextStartIndex !== undefined && page.nextStartIndex !== null)
            ? _browserInt(page.nextStartIndex)
            : start + size;
    if (nextStart <= start && items.length > 0) nextStart = start + items.length;
    if (nextStart <= start) nextStart = start + size;
    return { hasPrevious: null, nextStart: nextStart, hasMore: page.hasMore === true };
}
function browserAppendWindowItems(currentItems, incomingItems, start, prepend, pageSize, windowMaxItems, keepId, currentWindowStart) {
    currentItems = currentItems || [];
    incomingItems = incomingItems || [];
    start = Math.max(0, _browserInt(start));
    prepend = prepend === true;
    var size = Math.max(1, _browserPosInt(pageSize));
    var maxItems = Math.max(size, _browserPosInt(windowMaxItems));
    keepId = _browserString(keepId);
    currentWindowStart = Math.max(0, _browserInt(currentWindowStart));

    var seen = browserLoadedIds(currentItems);
    var incoming = [];
    for (var i = 0; i < incomingItems.length; i++) {
        var it = incomingItems[i];
        var id = it && it.Id ? _browserString(it.Id) : "";
        if (!id || seen[id]) continue;
        seen[id] = 1;
        var decorated = {};
        for (var k in it) decorated[k] = it[k];
        decorated._windowGlobalIndex = start + i;
        incoming.push(decorated);
    }
    if (!incoming.length) {
        return {
            items: currentItems,
            added: 0,
            windowStartIndex: currentItems.length ? browserGlobalIndex(currentItems, currentWindowStart, 0) : currentWindowStart,
            nextStart: null,
            hasMore: null,
            hasPrevious: null,
            loadedIds: browserLoadedIds(currentItems)
        };
    }

    var current = currentItems.slice(0);
    var next = prepend ? incoming.concat(current) : current.concat(incoming);
    var nextStart = null, hasMore = null, hasPrevious = null;

    if (next.length > maxItems) {
        var removeCount = Math.min(size, next.length);
        if (prepend) {
            var tailStart = next.length - removeCount;
            var keepInTail = false;
            for (var ti = tailStart; ti < next.length; ti++) {
                if (keepId && next[ti] && _browserString(next[ti].Id) === keepId) { keepInTail = true; break; }
            }
            if (!keepInTail) {
                var firstRemoved = next[tailStart];
                nextStart = firstRemoved && firstRemoved._windowGlobalIndex !== undefined
                        ? _browserInt(firstRemoved._windowGlobalIndex)
                        : start + tailStart;
                hasMore = true;
                next.splice(tailStart, removeCount);
            }
        } else {
            var keepInHead = false;
            for (var hi = 0; hi < removeCount; hi++) {
                if (keepId && next[hi] && _browserString(next[hi].Id) === keepId) { keepInHead = true; break; }
            }
            if (!keepInHead) {
                next.splice(0, removeCount);
                hasPrevious = true;
            }
        }
    }

    var windowStart = next.length && next[0]._windowGlobalIndex !== undefined
            ? _browserInt(next[0]._windowGlobalIndex)
            : (prepend ? start : currentWindowStart);
    return {
        items: next,
        added: incoming.length,
        windowStartIndex: windowStart,
        nextStart: nextStart,
        hasMore: hasMore,
        hasPrevious: hasPrevious,
        loadedIds: browserLoadedIds(next)
    };
}
function browserResolvedSortMode(persistedMode, sharedState, optionCount, fallbackMode) {
    var count = Math.max(1, _browserInt(optionCount));
    var p = _browserInt(persistedMode);
    if (p >= 0 && p < count && Number(persistedMode) >= 0) return p;
    if (sharedState && typeof sharedState.sort === "number") { var s = _browserInt(sharedState.sort); if (s >= 0 && s < count) return s; }
    var f = _browserInt(fallbackMode); return (f >= 0 && f < count) ? f : 0;
}
function browserReadSharedState(bucket, key) {
    if (!bucket || !key) return null;
    return Object.prototype.hasOwnProperty.call(bucket, key) ? bucket[key] : null;
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
function collectionPrimaryImageUrl(Jellyfin, serverUrl, it, options) {
    if (!Jellyfin || !it || !it.Id || !serverUrl) return "";
    var tag = collectionPrimaryImageTag(it);
    return tag ? Jellyfin.itemImageUrl(serverUrl, it.Id, "Primary", tag, options || {}) : "";
}
function collectionPosterOrThumbImageUrl(Jellyfin, serverUrl, it, options) {
    if (!Jellyfin || !it || !it.Id || !serverUrl) return "";
    var primary = collectionPrimaryImageTag(it);
    if (primary) return Jellyfin.itemImageUrl(serverUrl, it.Id, "Primary", primary, options || {});
    var thumb = collectionThumbImageTag(it);
    return thumb ? Jellyfin.itemImageUrl(serverUrl, it.Id, "Thumb", thumb, options || {}) : "";
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
    var max = _rdfInt(limit);
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
    var n = _rdfInt(limit);
    if (n <= 0) n = 50;
    return Math.max(1, Math.min(50, n));
}

/* ------------------------------------------------------------------------- */
/* Projections de cartes Home et Search                                      */
/* ------------------------------------------------------------------------- */

function trimObjectMemo(memo, maxEntries) {
    var source = memo || ({});
    var keys = Object.keys(source);
    var limit = Math.max(1, Number(maxEntries) | 0);
    if (keys.length <= limit) return source;
    var out = ({});
    var start = Math.max(0, keys.length - limit);
    for (var i = start; i < keys.length; ++i) out[keys[i]] = source[keys[i]];
    return out;
}

function homeCardUsesLandscape(item, sectionKind) {
    var kind = safeString(sectionKind).toLowerCase();
    if (kind === "nextup") return true;
    if (kind === "latest-series") return false;
    if (!item || item.IsFolder === true) return true;
    var type = itemTypeLower(item);
    if (type === "episode" || type === "video" || type === "musicvideo" || type === "trailer")
        return true;
    if (type.indexOf("folder") >= 0 || type === "collectionfolder" || type === "userview")
        return true;
    return safeString(item.CollectionType) !== "" && type !== "movie" && type !== "series";
}

function homeCardTileWidthFor(item, sectionKind, portraitWidth, landscapeWidth) {
    return homeCardUsesLandscape(item, sectionKind) ? landscapeWidth : portraitWidth;
}

function homeCardSidePadFor(item, sectionKind, portraitPad, landscapePad) {
    return homeCardUsesLandscape(item, sectionKind) ? landscapePad : portraitPad;
}

function homeCardFocusBleedFor(item, sectionKind, portraitBleed, landscapeBleed) {
    return homeCardUsesLandscape(item, sectionKind) ? landscapeBleed : portraitBleed;
}

function homeCardPrefersBackdrop(item, sectionKind) {
    var kind = safeString(sectionKind).toLowerCase();
    return kind !== "nextup" && homeCardUsesLandscape(item, kind);
}

function homeCardFallbackKind(item, sectionKind) {
    var kind = safeString(sectionKind).toLowerCase();
    if (kind === "library") return "folder";
    if (kind === "nextup") return "series";
    var type = itemTypeLower(item);
    if (type === "series" || type === "season") return "series";
    if (type === "episode") return "episode";
    if (type === "movie") return "movie";
    return homeCardUsesLandscape(item, kind) ? "video" : "";
}

function prepareHomeRowMetrics(items, sectionKind, layout) {
    var list = items || [];
    var cfg = layout || ({});
    var x = 0;
    for (var i = 0; i < list.length; ++i) {
        var item = list[i];
        if (!item) continue;
        var tileWidth = homeCardTileWidthFor(item, sectionKind,
                                             Number(cfg.portraitWidth || 0),
                                             Number(cfg.landscapeWidth || 0));
        var sidePad = homeCardSidePadFor(item, sectionKind,
                                         Number(cfg.portraitSidePad || 0),
                                         Number(cfg.landscapeSidePad || 0));
        var width = tileWidth + sidePad * 2;
        item._pgDelegateWidth = width;
        item._pgFocusBleed = homeCardFocusBleedFor(item, sectionKind,
                                                   Number(cfg.portraitFocusBleed || 0),
                                                   Number(cfg.landscapeFocusBleed || 0));
        item._pgRowLeft = x;
        x += width + Number(cfg.spacing || 0);
    }
    return list;
}

function homeRowItemWidthAt(items, index, sectionKind, layout) {
    var item = items && index >= 0 && index < items.length ? items[index] : null;
    var cached = Number(item && item._pgDelegateWidth || 0);
    if (cached > 0) return cached;
    if (!item) return 0;
    var cfg = layout || ({});
    return homeCardTileWidthFor(item, sectionKind, Number(cfg.portraitWidth || 0),
                                Number(cfg.landscapeWidth || 0))
         + homeCardSidePadFor(item, sectionKind, Number(cfg.portraitSidePad || 0),
                              Number(cfg.landscapeSidePad || 0)) * 2;
}

function homeRowItemBleedAt(items, index, sectionKind, layout) {
    var item = items && index >= 0 && index < items.length ? items[index] : null;
    var cached = Number(item && item._pgFocusBleed || 0);
    if (cached > 0) return cached;
    if (!item) return 0;
    var cfg = layout || ({});
    return homeCardFocusBleedFor(item, sectionKind, Number(cfg.portraitFocusBleed || 0),
                                 Number(cfg.landscapeFocusBleed || 0));
}

function homeRowItemLeftAt(items, index, sectionKind, spacing, layout) {
    if (!items || index <= 0) return 0;
    if (index < items.length && items[index] && items[index]._pgRowLeft !== undefined)
        return Number(items[index]._pgRowLeft || 0);
    var x = 0;
    for (var i = 0; i < Math.min(index, items.length); ++i)
        x += homeRowItemWidthAt(items, i, sectionKind, layout) + Number(spacing || 0);
    return x;
}

function homeRowLogicalWidth(items, sectionKind, spacing, edgePad, viewportWidth, layout) {
    if (!items || items.length === 0) return viewportWidth;
    var last = items.length - 1;
    var total = Number(edgePad || 0) * 2
              + homeRowItemLeftAt(items, last, sectionKind, spacing, layout)
              + homeRowItemWidthAt(items, last, sectionKind, layout);
    return Math.max(Number(viewportWidth || 0), total);
}

/* ------------------------------------------------------------------------- */
/* Géométrie pure des rails QML                                              */
/* ------------------------------------------------------------------------- */

function searchRowItemWidthAt(items, index) {
    var item = items && index >= 0 && index < items.length ? items[index] : null;
    return Math.max(0, Number(item && item._searchDelegateWidth || 0));
}

function searchRowItemLeftAt(items, index) {
    var item = items && index >= 0 && index < items.length ? items[index] : null;
    return Math.max(0, Number(item && item._searchRowLeft || 0));
}

function searchRowItemBleedAt(items, index) {
    var item = items && index >= 0 && index < items.length ? items[index] : null;
    return Math.max(0, Number(item && item._searchFocusBleed || 0));
}

function searchRowLogicalWidth(items, spacing, edgePad, viewportWidth) {
    if (!items || items.length === 0) return Number(viewportWidth || 0);
    var last = items.length - 1;
    return Math.max(Number(viewportWidth || 0),
                    Number(edgePad || 0) * 2 + searchRowItemLeftAt(items, last)
                    + searchRowItemWidthAt(items, last));
}

function searchRowMinX(edgePad) {
    return -Math.max(0, Number(edgePad || 0));
}

function rowMaxX(minimum, logicalContentWidth, viewportWidth) {
    var minX = Number(minimum || 0);
    return Math.max(minX, minX + Math.max(0, Number(logicalContentWidth || 0))
                    - Math.max(0, Number(viewportWidth || 0)));
}

function rowClampX(value, minimum, maximum) {
    var minX = Number(minimum || 0);
    var maxX = Math.max(minX, Number(maximum || minX));
    var x = Number(value || 0);
    if (!isFinite(x) || isNaN(x)) x = minX;
    return Math.max(minX, Math.min(maxX, x));
}

function searchRowTargetX(items, index, contentX, viewportWidth, edgePad, logicalContentWidth, padding) {
    var minX = searchRowMinX(edgePad);
    var maxX = rowMaxX(minX, logicalContentWidth, viewportWidth);
    if (!items || index < 0 || index >= items.length) return minX;

    var left = searchRowItemLeftAt(items, index);
    var width = searchRowItemWidthAt(items, index);
    var bleed = searchRowItemBleedAt(items, index);
    var pad = Math.max(0, Number(padding || 0));
    var current = Number(contentX || 0);
    var visualLeft = left - bleed;
    var visualRight = left + width + bleed;
    var target = current;

    if (visualLeft < current + pad) target = visualLeft - pad;
    else if (visualRight > current + Number(viewportWidth || 0) - pad)
        target = visualRight - Number(viewportWidth || 0) + pad;

    return rowClampX(target, minX, maxX);
}

function homeRowMinX(originX, edgePad) {
    var ox = Number(originX);
    return isFinite(ox) && !isNaN(ox) ? ox : -Math.max(0, Number(edgePad || 0));
}

function homeRowTargetX(items, index, sectionKind, spacing, contentX, viewportWidth,
                        revealMargin, minimum, maximum, layout) {
    var minX = Number(minimum || 0);
    var maxX = Math.max(minX, Number(maximum || minX));
    if (!items || index < 0 || index >= items.length) return minX;

    var left = homeRowItemLeftAt(items, index, sectionKind, spacing, layout);
    var width = homeRowItemWidthAt(items, index, sectionKind, layout);
    var bleed = homeRowItemBleedAt(items, index, sectionKind, layout);
    var pad = Math.max(0, Number(revealMargin || 0));
    var current = Number(contentX || 0);
    var visualLeft = left - bleed;
    var visualRight = left + width + bleed;
    var target = current;

    if (visualLeft < current + pad) target = visualLeft - pad;
    else if (visualRight > current + Number(viewportWidth || 0) - pad)
        target = visualRight - Number(viewportWidth || 0) + pad;

    return rowClampX(target, minX, maxX);
}

function searchIsFolderType(typeName) {
    var type = safeString(typeName).toLowerCase();
    return type === "folder" || type === "collectionfolder" || type === "userview" ||
           type === "aggregatefolder" || type === "userrootfolder" ||
           type === "manualplaylistsfolder" || type === "playlistsfolder";
}

function searchIsMovieLike(item) {
    var type = itemTypeLower(item);
    return type === "movie" || type === "video" || type === "musicvideo";
}

function searchSectionKey(item) {
    var type = itemTypeLower(item);
    if (type === "series") return "series";
    if (type === "episode") return "episodes";
    if (searchIsMovieLike(item))
        return safeString(item && item._searchLibraryId) ? "library-only" : "movies";
    if (type === "boxset") return "collections";
    if (searchIsFolderType(type) || (item && item.IsFolder === true)) return "folders";
    return "others";
}

function searchSectionTitle(key) {
    if (key === "series") return "Séries";
    if (key === "episodes") return "Épisodes de séries";
    if (key === "movies") return "Films";
    if (key === "collections") return "Collections";
    return "Autres résultats";
}

function searchItemUsesFolderLayout(item) {
    return searchIsFolderType(itemTypeLower(item)) || !!(item && item.IsFolder === true);
}

function searchItemUsesLandscape(item, sectionKey) {
    if (sectionKey === "episodes") return true;
    if (sectionKey === "series" || sectionKey === "movies" || sectionKey === "collections") return false;
    if (searchItemUsesFolderLayout(item)) return true;
    var type = itemTypeLower(item);
    return type === "episode" || type === "video" || type === "musicvideo" || type === "trailer";
}

function searchItemLayout(item, sectionKey, layout) {
    var cfg = layout || ({});
    var folder = searchItemUsesFolderLayout(item);
    var landscape = searchItemUsesLandscape(item, sectionKey);
    var tileWidth = folder ? Number(cfg.libraryTileWidth || 0)
                           : (landscape ? Number(cfg.landscapeWidth || 0) : Number(cfg.portraitWidth || 0));
    var tileHeight = folder ? Number(cfg.libraryTileHeight || 0) : Number(cfg.portraitHeight || 0);
    var sidePad = (folder || landscape) ? Number(cfg.focusSidePad || 0)
                                       : Number(cfg.portraitSidePad || 0);
    var topPad = Math.ceil(tileHeight * (Number(cfg.zoomScale || 1) - 1))
               + Number(cfg.frameWidth || 0) + 2 + Number(cfg.focusLift || 0);
    var cardWidth = tileWidth + sidePad * 2;
    var cardHeight = tileHeight + Number(cfg.titleHeight || 0) + topPad;
    var focusBleed = Math.max(0, Math.ceil((tileWidth * (Number(cfg.zoomScale || 1) - 1)) * 0.5)
                                  + 3 - sidePad);
    return { tileWidth:tileWidth, tileHeight:tileHeight, sidePad:sidePad, topPad:topPad,
             cardWidth:cardWidth, cardHeight:cardHeight, focusBleed:focusBleed,
             landscape:landscape };
}

function prepareSearchSectionItems(items, sectionKey, layout) {
    var source = items || [], out = [], x = 0, maxHeight = 0, maxBleed = 0;
    for (var i = 0; i < source.length; ++i) {
        var original = source[i], item = {};
        if (original) {
            for (var key in original)
                if (Object.prototype.hasOwnProperty.call(original, key)) item[key] = original[key];
        }
        var metrics = searchItemLayout(item, sectionKey, layout);
        item._searchRowLeft = x;
        item._searchDelegateWidth = metrics.cardWidth;
        item._searchCardHeight = metrics.cardHeight;
        item._searchFocusBleed = metrics.focusBleed;
        item._searchTileW = metrics.tileWidth;
        item._searchTileH = metrics.tileHeight;
        item._searchSidePad = metrics.sidePad;
        item._searchTopPad = metrics.topPad;
        out.push(item);
        x += metrics.cardWidth + Number(layout && layout.spacing || 0);
        maxHeight = Math.max(maxHeight, metrics.cardHeight);
        maxBleed = Math.max(maxBleed, metrics.focusBleed);
    }
    return { items:out, cardHeight:maxHeight, edgePad:maxBleed + 14 };
}

function searchCardFallbackKind(item) {
    var type = itemTypeLower(item);
    if (type === "series") return "series";
    if (type === "episode") return "episode";
    if (type === "movie" || type === "video" || type === "musicvideo") return "movie";
    if (type === "boxset") return "collection";
    if (searchIsFolderType(type) || (item && item.IsFolder === true)) return "folder";
    return "video";
}

/* ------------------------------------------------------------------------- */
/* DTO compacts et métadonnées de fiches                                     */
/* ------------------------------------------------------------------------- */

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

function prepareHomeLatestGroups(groups, layout) {
    groups = safeArray(groups);
    var out = [];
    for (var i = 0; i < groups.length; ++i) {
        var group = groups[i];
        if (!group || isKnownUnsupportedLibraryFolder(group)) continue;
        var prepared = shallowCloneObject(group);
        var sectionKind = isSeriesLibraryFolder(prepared) ? "latest-series" : "latest";
        prepared._pgSectionKind = sectionKind;
        prepared.items = prepareHomeRowMetrics(safeArray(group.items), sectionKind, layout);
        out.push(prepared);
    }
    return out;
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

/* ===== Transformations séries/épisodes partagées ===== */
function _catalogString(v) {
    return (v === undefined || v === null) ? "" : (v + "");
}
function seriesYearFromDateLike(v) {
    if (v === undefined || v === null) return "";
    var s = _catalogString(v);
    if (s.length >= 4) {
        var y = parseInt(s.substr(0, 4), 10);
        if (y > 1800 && y < 2500) return _catalogString(y);
    }
    var n = Number(v || 0);
    return (n > 1800 && n < 2500) ? _catalogString(Math.floor(n)) : "";
}
function seriesYearRangeParts(item, seasons, ended) {
    var start = "", end = "";
    if (item) {
        start = seriesYearFromDateLike(item.ProductionYear) || seriesYearFromDateLike(item.PremiereDate || item.StartDate || item.DateCreated);
        end = seriesYearFromDateLike(item.EndDate || item.DateEnded || item.EndYear);
    }
    if (!end && ended && seasons && seasons.length) {
        var best = 0;
        for (var i = 0; i < seasons.length; i++) {
            var season = seasons[i];
            var y = seriesYearFromDateLike(season && (season.ProductionYear || season.PremiereDate));
            var n = Number(y || 0);
            if (n > best) best = n;
        }
        if (best > 0) end = _catalogString(best);
    }
    return { start: start, end: end };
}
function _catalogNum(v, fallback) {
    return (v === undefined || v === null) ? fallback : +v;
}
function sortSeasonsInPlace(items) {
    if (!items || !items.sort) return items;
    items.sort(function (a, b) {
        var ia = _catalogNum(a && a.IndexNumber, 9999), ib = _catalogNum(b && b.IndexNumber, 9999);
        if (ia === 0 && ib !== 0) return 1;
        if (ib === 0 && ia !== 0) return -1;
        return ia - ib;
    });
    return items;
}
function sortEpisodesInPlace(items) {
    if (!items || !items.sort) return items;
    items.sort(function (a, b) {
        var sa = _catalogNum(a && a.ParentIndexNumber, 9999), sb = _catalogNum(b && b.ParentIndexNumber, 9999);
        if (sa !== sb) return sa - sb;
        var ea = _catalogNum(a && a.IndexNumber, 9999), eb = _catalogNum(b && b.IndexNumber, 9999);
        return ea - eb;
    });
    return items;
}
function _catalogFlagTrue(v) {
    if (v === true || v === 1) return true;
    var s = String(v === undefined || v === null ? "" : v).toLowerCase();
    return s === "true" || s === "1" || s === "yes" || s === "oui";
}
function episodeMissingReason(ep) {
    if (!ep) return "null";
    var loc = _catalogString(ep.LocationType || ep.locationType).toLowerCase();
    if (loc === "virtual") return "LocationType=Virtual";
    if (loc === "missing") return "LocationType=Missing";
    if (loc === "placeholder") return "LocationType=Placeholder";
    if (_catalogFlagTrue(ep.IsMissing) || _catalogFlagTrue(ep.Missing)) return "IsMissing/Missing=true";
    if (_catalogFlagTrue(ep.IsVirtual) || _catalogFlagTrue(ep.Virtual) ||
            _catalogFlagTrue(ep.IsVirtualItem) || _catalogFlagTrue(ep.VirtualItem)) return "IsVirtual=true";
    if (_catalogFlagTrue(ep.IsVirtualUnaired) || _catalogFlagTrue(ep.VirtualUnaired)) return "IsVirtualUnaired=true";
    if (_catalogFlagTrue(ep.IsPlaceholder) || _catalogFlagTrue(ep.IsPlaceHolder) || _catalogFlagTrue(ep.Placeholder)) return "IsPlaceholder=true";
    if (_catalogFlagTrue(ep.IsUnaired)) return "IsUnaired=true";
    return "";
}
function episodeHasPlayableHints(ep) {
    if (!ep) return false;
    var loc = _catalogString(ep.LocationType || ep.locationType).toLowerCase();
    if (loc === "filesystem" || loc === "file system") return true;
    try { if (ep.MediaSources && ep.MediaSources.length > 0) return true; } catch (e) {}
    try {
        var ms = ep.MediaStreams || [];
        for (var i = 0; i < ms.length; i++) {
            var stream = ms[i] || {};
            var typ = _catalogString(stream.Type || stream.type).toLowerCase();
            if (typ === "video" || typ === "audio") return true;
        }
    } catch (e2) {}
    return Number(ep.RunTimeTicks || ep.RuntimeTicks || 0) > 0;
}
function episodeIsPlayableForPlaylist(ep) {
    if (!ep || !ep.Id) return false;
    var typ = String(ep.Type || "").toLowerCase();
    if (typ && typ !== "episode") return false;
    if (episodeMissingReason(ep)) return false;
    var hasSources = false, hasPath = false;
    try { hasSources = typeof ep.MediaSources !== "undefined"; } catch(e0) {}
    try { hasPath = typeof ep.Path !== "undefined"; } catch(e1) {}
    if (hasSources && hasPath && (!(ep.MediaSources || []).length && !String(ep.Path || ""))) return false;
    return true;
}
function shuffleEpisodeId(ep) {
    return ep ? String(ep.Id || ep.ItemId || ep.id || "") : "";
}
function episodePlayableForShuffle(ep) {
    return !!(shuffleEpisodeId(ep) && !episodeMissingReason(ep) && episodeHasPlayableHints(ep));
}
function ownedShuffleCandidates(items, preferUnplayed) {
    var source = items || [], out = [];
    for (var i = 0; i < source.length; ++i) {
        var episode = source[i];
        if (!episodePlayableForShuffle(episode)) continue;
        if (preferUnplayed === true && episode.UserData && episode.UserData.Played === true) continue;
        out.push(episode);
    }
    return out;
}
function pickOwnedShuffleEpisode(items, preferUnplayed) {
    var pool = ownedShuffleCandidates(items, preferUnplayed === true);
    if (!pool.length && preferUnplayed === true) pool = ownedShuffleCandidates(items, false);
    if (!pool.length) return null;
    var index = Math.max(0, Math.min(pool.length - 1, Math.floor(Math.random() * pool.length)));
    return pool[index];
}
function normalizeIdList(raw) {
    var out = [], seen = {};
    raw = raw || [];
    for (var i = 0; i < raw.length; i++) {
        var id = String(raw[i] || "");
        if (!id || seen[id]) continue;
        seen[id] = 1;
        out.push(id);
    }
    return out;
}
function episodeIdListFromItems(items, preferredOrderIds) {
    items = items || [];
    preferredOrderIds = preferredOrderIds || [];
    var byId = {}, out = [], seen = {}, i;
    for (i = 0; i < items.length; i++) {
        if (items[i] && items[i].Id) byId[String(items[i].Id)] = items[i];
    }
    if (preferredOrderIds.length) {
        for (i = 0; i < preferredOrderIds.length; i++) {
            var wanted = String(preferredOrderIds[i] || ""), item = byId[wanted];
            if (wanted && !seen[wanted] && item && episodeIsPlayableForPlaylist(item)) {
                seen[wanted] = 1;
                out.push(wanted);
            }
        }
        return out;
    }
    for (i = 0; i < items.length; i++) {
        var ep = items[i], id = ep && ep.Id ? String(ep.Id) : "";
        if (!id || seen[id] || !episodeIsPlayableForPlaylist(ep)) continue;
        seen[id] = 1;
        out.push(id);
    }
    return out;
}
function compactEpisodeDetailsForCache(details) {
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
function episodeSliceWindow(items, centerIndex, requestedCount) {
    var arr = items || [], length = arr.length;
    if (!length) return { start:0, items:[] };
    var count = Math.max(4, Number(requestedCount) | 0);
    if (length <= count) return { start:0, items:arr };
    var center = Math.max(0, Math.min(Number(centerIndex) | 0, length - 1));
    var start = Math.max(0, center - Math.floor(count / 2));
    var end = start + count;
    if (end > length) { end = length; start = Math.max(0, end - count); }
    return { start:start, items:arr.slice(start, end) };
}
function isUnknownSeasonEpisode(e) {
    if (!e)
        return true;
    var sNum = (e.ParentIndexNumber !== undefined && e.ParentIndexNumber !== null)
             ? e.ParentIndexNumber
             : null;
    return ((!e.SeasonId || e.SeasonId === "") || (sNum === null)) && sNum !== 0;
}
function sortUnknownSeasonEpisodesInPlace(items) {
    if (!items || !items.sort) return items;
    items.sort(function(a, b) {
        var sa = (a && a.ParentIndexNumber !== null && a.ParentIndexNumber !== undefined) ? a.ParentIndexNumber : -1;
        var sb = (b && b.ParentIndexNumber !== null && b.ParentIndexNumber !== undefined) ? b.ParentIndexNumber : -1;
        if (sa !== sb) return sa - sb;
        var ea = (a && a.IndexNumber !== null && a.IndexNumber !== undefined) ? a.IndexNumber : 999999;
        var eb = (b && b.IndexNumber !== null && b.IndexNumber !== undefined) ? b.IndexNumber : 999999;
        if (ea !== eb) return ea - eb;
        var ad = a && a.PremiereDate ? String(a.PremiereDate) : "";
        var bd = b && b.PremiereDate ? String(b.PremiereDate) : "";
        return ad < bd ? -1 : (ad > bd ? 1 : 0);
    });
    return items;
}
function seriesRuntimeTicksFallback(ticks) {
    var t = Number(ticks || 0), maxEpisodeLike = 4 * 60 * 60 * 10000000;
    return (t > 0 && t <= maxEpisodeLike) ? Math.round(t) : 0;
}
/* Traitements purs partagés par le bridge et PlayerOverlay. */
function shuffledCopy(items) {
    var out = (items || []).slice(0);
    for (var i = out.length - 1; i > 0; i--) {
        var j = Math.floor(Math.random() * (i + 1));
        var tmp = out[i]; out[i] = out[j]; out[j] = tmp;
    }
    return out;
}
function averageEpisodeRuntimeTicks(items, fallbackTicks) {
    var total = 0, count = 0;
    items = items || [];
    for (var i = 0; i < items.length; i++) {
        var t = Number((items[i] && (items[i].RunTimeTicks || items[i].RuntimeTicks)) || 0);
        if (isFinite(t) && t > 0) { total += t; count++; }
    }
    return count > 0 ? Math.round(total / count) : seriesRuntimeTicksFallback(fallbackTicks);
}
