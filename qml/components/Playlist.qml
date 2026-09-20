import QtQuick 2.15

Item {
    id: pl
    width: 0; height: 0; visible: false    // tête sans UI

    /* ===== Entrées ===== */
    property var    list: []                // tableau d'IDs Jellyfin (episodes)
    property string title: ""               // "Tout lire — Saison 1" (optionnel)
    property bool   autoplayNext: true

    /* (optionnel) méta-provenance si d'autres composants veulent étiqueter la playlist */
    property string controller: ""          // ex: "seasonpage" | "playeroverlay"
    property string scope: ""               // ex: "season:<id>" | "unknown-season:<seriesId>" | "series:<id>"

    /* ===== État ===== */
    property int index: -1
    // Curseur par ID (attendu par seasonpage / playeroverlay)
    property string currentItemId: ""

    /* ===== Garde de périmètre (anti-mélange) =====
       Set optionnel d’IDs autorisées pour cette playlist (saison).
       Quand défini, toute écriture/append filtre les IDs non autorisées. */
    property var allowedIds: null   // { "id1": true, "id2": true, ... }

    /* ===== Sorties ===== */
    signal requestPlayItem(string itemId)

    /* ===== Garde anti-réentrance ===== */
    property bool _normalizing: false

    /* ===== Helpers ===== */
    function _normalizedCopy(arr){
        var out = [];
        if (!arr) return out;
        for (var i=0;i<arr.length;i++){
            var v = arr[i];
            if (v===undefined || v===null) continue;
            var s = String(v);
            if (!s.length) continue;
            out.push(s);
        }
        return out;
    }
    function _arraysEqual(a,b){
        if (a===b) return true;
        if (!a || !b) return (!a && !b);
        if (a.length !== b.length) return false;
        for (var i=0;i<a.length;i++) if (a[i] !== b[i]) return false;
        return true;
    }
    function hasList(){ return list && list.length>0; }
    function _idxOf(id){
        if (!hasList()) return -1;
        var sid = String(id);
        return list.indexOf(sid);
    }
    function _sync(currId){
        var i = _idxOf(currId);
        index = (i>=0 ? i : (hasList()?0:-1));
        return index;
    }
    function _syncCurrentItemFromIndex(){
        var id = (index >= 0 && index < list.length) ? String(list[index]) : ""
        if (id !== currentItemId) currentItemId = id
    }

    /* ===== Périmètre (allowedIds) ===== */
    function _accept(id){ return !allowedIds || !!allowedIds[String(id)]; }

    function setAllowed(ids){
        // ids: tableau d'IDs autorisées (saison en cours)
        var s = {};
        var a = _normalizedCopy(ids||[]);
        for (var i=0;i<a.length;i++) s[a[i]] = true;
        allowedIds = s;

        // Filtre la liste courante si nécessaire
        if (list && list.length){
            var kept = [];
            for (var j=0;j<list.length;j++) if (_accept(list[j])) kept.push(list[j]);
            if (!_arraysEqual(kept, list)){
                setList(kept);    // gère recalc + signaux
            } else {
                // Si le courant n’est plus autorisé, recale l’index
                if (currentItemId && !_accept(currentItemId)) {
                    setIndex(0);
                }
            }
        } else {
            // Si pas de liste mais currentItemId hors périmètre, purge le curseur
            if (currentItemId && !_accept(currentItemId)) {
                index = -1; currentItemId = "";
                _syncCurrentItemFromIndex();
            }
        }
    }
    function setAllowedFromList(ids){ setAllowed(ids); } // alias pratique

    /* ===== Normalisation sûre ===== */
    onListChanged: {
        if (_normalizing) return;           // évite les reboucles
        var norm = _normalizedCopy(list);

        // Applique le périmètre si défini
        if (allowedIds){
            var filtered=[];
            for (var k=0;k<norm.length;k++) if (_accept(norm[k])) filtered.push(norm[k]);
            norm = filtered;
        }

        if (_arraysEqual(norm, list)) {
            // Si l'index devient hors bornes, recale
            if (index >= list.length) index = list.length-1;

            // Re-sync sur currentItemId si on en a un
            if (currentItemId) {
                var i = _idxOf(currentItemId);
                if (i !== index) { index = (i>=0 ? i : (hasList()?0:-1)); _syncCurrentItemFromIndex(); }
            } else if (index>=0 && index<list.length) {
                // met à jour currentItemId depuis l’index si besoin
                var cid = String(list[index]);
                if (cid !== currentItemId) currentItemId = cid
            }
            return;
        }

        _normalizing = true;
        list = norm;                         // une seule écriture contrôlée
        _normalizing = false;

        if (index >= list.length) index = list.length-1;

        // Après normalisation, on tente de conserver le curseur par ID si possible
        if (currentItemId) {
            var j = _idxOf(currentItemId);
            index = (j>=0 ? j : (hasList()?0:-1));
        }
        _syncCurrentItemFromIndex();
    }

    /* ===== API publique ===== */

    // Remplace la liste en une fois (sans reboucle)
    function setList(ids){
        var norm = _normalizedCopy(ids||[]);

        // Périmètre
        if (allowedIds){
            var filtered=[];
            for (var i=0;i<norm.length;i++) if (_accept(norm[i])) filtered.push(norm[i]);
            norm = filtered;
        }

        _normalizing = true;
        list = norm;
        _normalizing = false;

        if (index >= list.length) index = list.length-1;

        // conserve le curseur par ID si possible
        if (currentItemId) {
            var ix = _idxOf(currentItemId);
            index = (ix>=0 ? ix : (hasList()?0:-1));
        }
        _syncCurrentItemFromIndex();
    }

    // Ajoute des ids (uniques, en fin)

    // Curseur par ID (attendu par seasonpage / overlay)
    function setCurrentItemId(id){
        var sid = String(id||"");
        if (!sid.length) { return; }
        if (!_accept(sid)) { return; }
        var i = _idxOf(sid);
        index = (i>=0 ? i : (hasList()?0:-1));
        currentItemId = (index>=0 ? sid : "");
        _syncCurrentItemFromIndex();
    }

    // Curseur par index (compat avec overlay) — protège contre NaN
    function setIndex(i){
        i = +i;
        if (isNaN(i)) i = 0;
        if (!(list && list.length)) { index=-1; currentItemId=""; _syncCurrentItemFromIndex(); return; }
        if (i<0) i=0; if (i>=list.length) i=list.length-1;
        index=i; currentItemId=String(list[i]); _syncCurrentItemFromIndex();
    }

    // Utilitaires
    function clear(){ setList([]); index = -1; currentItemId = ""; }

    // Lancements
    function start(){
        if (!hasList()) { return false; }
        index = (index>=0 && index<list.length) ? index : 0;
        currentItemId = String(list[index]);
        requestPlayItem(currentItemId);
        _syncCurrentItemFromIndex();
        return true;
    }

    // Navigation relative
    function nextFrom(currId){
        var i = _sync(currId);
        if (i>=0 && i < list.length-1) {
            var id = String(list[i+1]);
            index = i+1; currentItemId = id;
            requestPlayItem(id);
            _syncCurrentItemFromIndex();
            return true;
        }
        return false;
    }
    function prevFrom(currId){
        var i = _sync(currId);
        if (i>0) {
            var id = String(list[i-1]);
            index = i-1; currentItemId = id;
            requestPlayItem(id);
            _syncCurrentItemFromIndex();
            return true;
        }
        return false;
    }

    // Fin de média

    /* ===== Compat overlay : resynchro externe sur ID courant ===== */
    function syncTo(id){ setCurrentItemId(id); }

    /* ===== Réactions ===== */
    onCurrentItemIdChanged: {
        // Si l’ID courant change de l’extérieur, on recale l’index
        if (!currentItemId) {
            index = hasList() ? 0 : -1
            return
        }
        if (!_accept(currentItemId)) { // hors périmètre → annule
            index = (hasList()?0:-1);
            var newId = (index>=0?String(list[index]):"");
            if (newId !== currentItemId) currentItemId = newId;
            return;
        }
        var i = _idxOf(currentItemId);
        if (i !== index) { index = (i>=0 ? i : (hasList()?0:-1)); }
    }
}
