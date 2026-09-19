import QtQuick 2.15

FocusScope {
    id: root
    anchors.fill: parent
    focus: false

    // Overlay unifié des réglages lecteur ReDeFin.
    // QtQuick 2.15 uniquement, sans QtQuick.Controls.
    // Un seul panneau et une seule ListView servent à Qualité / Zoom / Vitesse / Audio / Sous-titres.
    readonly property int controlQuality: 0
    readonly property int controlZoom: 1
    readonly property int controlSpeed: 2
    readonly property int controlAudio: 3
    readonly property int controlSubtitle: 4

    readonly property int panelNone: 0
    readonly property int panelQuality: 1
    readonly property int panelZoom: 2
    readonly property int panelSpeed: 3
    readonly property int panelAudio: 4
    readonly property int panelSubtitle: 5

    property bool allowUi: true
    property int focusedControl: -1
    property bool chaptersPanelOpen: false
    property int safeBottomMargin: 40

    // Réglages locaux / transcodage.
    property int selectedBitrate: 0

    // Débit vidéo de la source originale sélectionnée par Jellyfin.
    // 0 = information absente ; dans ce cas seulement, la jauge conserve
    // l'ancienne référence prudente de 200 Mbit/s.
    property real sourceVideoBitrate: 0

    // Etat réel / choix manuel remonté par PlayerOverlay.
    // Le panneau Qualité affiche toujours une ligne appliquée :
    // DirectPlay, Remux, mode automatique serveur ou débit manuel.
    property bool directPlaySelected: false
    property bool remuxSelected: false
    property bool automaticServerSelected: false
    property string automaticQualityLabel: "Automatique"
    property string qualityStatusText: ""

    property int selectedMode: 0
    property real selectedRate: 1.0
    // La vitesse peut être choisie uniquement lorsque le média courant est en
    // DirectPlay pur. Le menu reste accessible hors DirectPlay afin que
    // PlayerOverlay puisse expliquer la contrainte à l'utilisateur au moment
    // où il valide une vitesse.
    property bool speedDirectPlayAvailable: true

    // État Audio / Sous-titres piloté par PlayerOverlay. Les index Audio
    // correspondent directement aux pistes réellement affichées.
    property bool audioMenuOpen: false
    property bool subtitleMenuOpen: false
    property var audioTracks: []
    property var audioStreamIndexMap: []
    property int audioCurrentIndex: 0
    property string audioSelectionNote: ""
    property var subtitleTracks: []
    property var subtitleStreamIndexMap: []
    property var subtitleIsTextMap: []
    property int subtitleCurrentIndex: 0
    property string subtitleSelectionNote: ""

    property int activePanel: panelNone
    property int selectedIndex: 0

    // Aide contextuelle du menu Qualité vidéo.
    // La Freebox remonte principalement la touche i / Infos comme Qt.Key_Help.
    property bool qualityInfoOpen: false
    property int qualityInfoIndex: -1

    readonly property bool panelOpen: activePanel !== panelNone
    readonly property bool qualityPanelOpen: activePanel === panelQuality
    readonly property bool zoomPanelOpen: activePanel === panelZoom
    readonly property bool speedPanelOpen: activePanel === panelSpeed
    readonly property bool audioPanelOpen: activePanel === panelAudio
    readonly property bool subtitlePanelOpen: activePanel === panelSubtitle
    readonly property bool settingsPanelOpen: qualityPanelOpen || zoomPanelOpen || speedPanelOpen
    readonly property bool trackPanelOpen: audioPanelOpen || subtitlePanelOpen

    // Libère explicitement la branche de focus du panneau lorsqu'il se ferme.
    // forceActiveFocus() réarme root.focus/settingsList.focus à l'ouverture ;
    // il faut donc les remettre à false dès qu'activePanel revient à panelNone.
    function _releasePanelFocus() {
        try { settingsList.focus = false } catch(e0) {}
        root.focus = false
    }
    onActivePanelChanged: {
        if (activePanel === panelNone)
            _releasePanelFocus()
    }

    // Valeurs négatives réservées aux modes de lecture.
    // Les débits positifs restent les plafonds de transcodage manuel.
    readonly property int qualityAutoValue: -3
    readonly property int qualityDirectPlayValue: -1
    readonly property int qualityRemuxValue: -2

    readonly property var qualityValues: [
        qualityAutoValue,
        qualityDirectPlayValue,
        qualityRemuxValue,
        200000000, 180000000, 140000000, 120000000,
        110000000, 100000000, 90000000, 80000000,
        70000000, 60000000, 50000000, 40000000,
        30000000, 20000000, 15000000, 10000000,
        5000000, 3000000, 2000000, 1000000,
        720000, 420000
    ]

    readonly property var qualityLabels: [
        "Automatique",
        "Original (DirectPlay)",
        "Remux (serveur)",
        "Transcodage - 200 Mbit/s", "Transcodage - 180 Mbit/s", "Transcodage - 140 Mbit/s", "Transcodage - 120 Mbit/s",
        "Transcodage - 110 Mbit/s", "Transcodage - 100 Mbit/s", "Transcodage - 90 Mbit/s", "Transcodage - 80 Mbit/s",
        "Transcodage - 70 Mbit/s", "Transcodage - 60 Mbit/s", "Transcodage - 50 Mbit/s", "Transcodage - 40 Mbit/s",
        "Transcodage - 30 Mbit/s", "Transcodage - 20 Mbit/s", "Transcodage - 15 Mbit/s", "Transcodage - 10 Mbit/s",
        "Transcodage - 5 Mbit/s", "Transcodage - 3 Mbit/s", "Transcodage - 2 Mbit/s", "Transcodage - 1 Mbit/s",
        "Transcodage - 720 Kbit/s", "Transcodage - 420 Kbit/s"
    ]

    readonly property var modeValues: [0, 1, 2, 3]

    readonly property var modeLabels: [
        "Original · 100 %",
        "Zoom léger · 110 %",
        "Zoom · 125 %",
        "Zoom fort · 150 %"
    ]

    readonly property var modeHints: [
        "Cadre vidéo normal, image entière",
        "Agrandissement léger, centré",
        "Agrandissement moyen, centré",
        "Agrandissement fort, centré"
    ]

    readonly property var rateValues: [
        0.25, 0.50, 0.75, 1.00,
        1.25, 1.50, 1.75, 2.00
    ]

    readonly property var rateLabels: [
        "0,25x", "0,50x", "0,75x", "1,00x",
        "1,25x", "1,50x", "1,75x", "2,00x"
    ]

    readonly property var rateHints: [
        "Lecture au quart de la vitesse normale",
        "Lecture à la moitié de la vitesse normale",
        "Lecture ralentie",
        "Vitesse normale",
        "Lecture accélérée légère",
        "Lecture accélérée",
        "Lecture accélérée forte",
        "Lecture à deux fois la vitesse normale"
    ]

    readonly property bool activeTrackPanel:
        activePanel === panelAudio || activePanel === panelSubtitle

    readonly property int activeRowHeight:
        activePanel === panelQuality ? 40
      : activePanel === panelZoom ? 52
      : activePanel === panelSpeed ? 46
      : 56

    readonly property int activeHighlightDuration:
        activePanel === panelQuality ? 145
      : activePanel === panelZoom ? 130
      : 120

    readonly property int activeHighlightTail:
        activePanel === panelQuality ? 42
      : activePanel === panelZoom ? 54
      : activePanel === panelSpeed ? 48
      : 56

    readonly property int activeHintFontSize:
        activePanel === panelZoom ? 13 : 12

    readonly property string panelTitle:
        activePanel === panelQuality ? "Qualité vidéo"
      : activePanel === panelZoom ? "Zoom vidéo"
      : activePanel === panelSpeed ? "Vitesse de lecture"
      : activePanel === panelAudio ? "Audio"
      : activePanel === panelSubtitle ? "Sous-titres"
      : ""

    readonly property string panelInfoText:
        activePanel === panelQuality
            ? (qualityStatusText.length > 0
               ? qualityStatusText
               : "Décision ReDeFin / Jellyfin")
      : activePanel === panelZoom
            ? "Zoom géométrique local QtMultimedia"
      : activePanel === panelSpeed
            ? (speedDirectPlayAvailable
               ? "Lecture locale QtMultimedia"
               : "DirectPlay requis pour modifier la vitesse")
      : activePanel === panelAudio
            ? _trackInfoText(
                  audioTracks,
                  audioCurrentIndex,
                  audioSelectionNote)
      : activePanel === panelSubtitle
            ? _subtitleInfoText(
                  subtitleCurrentIndex,
                  subtitleSelectionNote)
      : ""

    signal requestQuality(int bitrate)
    signal requestZoom(int mode)
    signal requestSpeed(real rate)

    signal requestAudioPick(int streamIdx, int uiIdx)

    signal requestSubtitleOff()
    signal requestSubtitleText(int streamIdx, int uiIdx)
    signal requestSubtitleImage(int streamIdx, int uiIdx)

    signal requestTrackClose(int control)

    signal requestFocusProgress()
    signal requestFocusControls(int fromControl)
    signal requestFocusControlsLeft()
    signal requestFocusChapters()

    signal requestButtonFocus(int control)
    signal requestOpenControl(int control)

    signal userActivity()

    function _clamp(n, lo, hi) {
        return Math.max(lo, Math.min(n, hi))
    }

    // Télécommande Freebox : la touche « i / Infos » est généralement
    // remontée comme Qt.Key_Help. Les variantes ci-dessous restent acceptées
    // pour les autres Players, claviers et anciennes versions runtime.
    function _isInfoKey(event) {
        if (!event)
            return false

        return event.key === Qt.Key_Help
            || event.key === 16777304
            || event.key === Qt.Key_Info
            || event.key === Qt.Key_Yellow
            || event.key === Qt.Key_F4
            || event.key === Qt.Key_I
    }

    function _qualityIndexHasInfo(idx) {
        return activePanel === panelQuality &&
               idx >= 0 && idx < qualityValues.length
    }

    function _qualityInfoTitleFor(idx) {
        if (idx === 0)
            return "Automatique"

        if (idx === 1)
            return "Original (DirectPlay)"

        if (idx === 2)
            return "Remux (serveur)"

        if (idx >= 3 && idx < qualityLabels.length)
            return String(qualityLabels[idx] || "Transcodage")

        return ""
    }

    // Deux jauges indicatives dans le menu Qualité.
    // Elles sont recalibrées sur le débit vidéo de la source réellement
    // sélectionnée par Jellyfin pour le média courant.
    // Ce ne sont pas des mesures CPU/qualité réelles.
    function _qualityGaugeVisible(idx) {
        return activePanel === panelQuality && idx >= 1
    }

    function _qualityReferenceBitrate() {
        var source = Math.max(0, Number(sourceVideoBitrate || 0))
        // Fallback seulement lorsque Jellyfin ne fournit aucun bitrate source.
        return source > 0 ? source : 200000000.0
    }

    function _qualityTargetRatio(idx) {
        idx = idx | 0
        if (idx < 3 || idx >= qualityValues.length)
            return 0.0

        var target = Math.max(0, Number(qualityValues[idx] || 0))
        var reference = _qualityReferenceBitrate()
        if (!(target > 0) || !(reference > 0))
            return 0.0

        // Au-dessus du débit source, le transcodage ne peut pas recréer
        // davantage d'information que l'original : on plafonne donc à 1.
        return _clamp(target / reference, 0.0, 1.0)
    }

    function _qualityCpuLoad(idx) {
        idx = idx | 0

        // Original / DirectPlay : serveur quasiment au repos.
        if (idx === 1) return 0.0

        // Remux : faible charge, sans réencodage vidéo.
        if (idx === 2) return 0.10

        if (idx < 3 || idx >= qualityValues.length) return 0.0

        // Le transcodage au débit de la source (ou au-dessus) devient la
        // référence haute. Les débits plus faibles font redescendre l'aiguille.
        var ratio = _qualityTargetRatio(idx)
        return _clamp(0.22 + 0.78 * Math.sqrt(ratio), 0.0, 1.0)
    }

    function _qualityCpuAngle(idx) {
        // PNG : vert à gauche, rouge à droite.
        return -68.0 + (_qualityCpuLoad(idx) * 136.0)
    }

    function _qualityVisualScore(idx) {
        idx = idx | 0

        // DirectPlay : source originale.
        if (idx === 1) return 1.0

        // Remux : vidéo originale, seulement le conteneur/flux change.
        if (idx === 2) return 0.98

        if (idx < 3 || idx >= qualityValues.length) return 0.0

        // Un transcodage au débit source ou supérieur reste volontairement
        // "presque" au maximum, jamais au niveau du DirectPlay/Remux car il y
        // a tout de même un réencodage. Ensuite la qualité baisse avec le débit.
        var ratio = _qualityTargetRatio(idx)
        return _clamp(0.10 + 0.82 * Math.sqrt(ratio), 0.0, 0.92)
    }

    function _qualityVisualAngle(idx) {
        // Qualité maximale = zone verte à gauche.
        // Qualité minimale = zone rouge à droite.
        return 68.0 - (_qualityVisualScore(idx) * 136.0)
    }

    function _qualityInfoTextFor(idx) {
        if (idx === 0)
            return "ReDeFin choisit automatiquement la méthode de lecture la plus adaptée au média et à la Freebox. Selon les codecs, le conteneur, les pistes audio et les sous-titres, il peut utiliser le DirectPlay, un remux ou, lorsque c’est nécessaire, un traitement serveur. Ce mode privilégie la compatibilité et la continuité de lecture sans demander à l’utilisateur de choisir manuellement la méthode."

        if (idx === 1)
            return "Le DirectPlay envoie le fichier original à la Freebox sans réencoder la vidéo ni l’audio. C’est le chemin le plus léger pour le serveur et il conserve la qualité d’origine. Il dépend toutefois de la compatibilité du conteneur, des codecs et des pistes avec le Player. Si le média ne peut pas être lu correctement tel quel, ReDeFin peut devoir utiliser une méthode serveur pour permettre la lecture."

        if (idx === 2)
            return "Le remux ne réencode ni la vidéo ni l’audio. Jellyfin réorganise les pistes et peut changer le conteneur afin de fournir un flux plus adapté à la Freebox. La qualité audio et vidéo reste donc inchangée et la charge CPU du serveur est très faible, contrairement à un transcodage qui réencode réellement le média."

        if (idx >= 3 && idx < qualityValues.length) {
            var bitrateLabel = String(_labelAt(idx) || "Transcodage")
            bitrateLabel = bitrateLabel.replace("Transcodage - ", "")
            return "Ce choix force Jellyfin à transcoder la vidéo avec un débit cible de " + bitrateLabel + ". La vidéo est réencodée afin de produire un flux compatible avec la Freebox. Plus le débit choisi est élevé, plus la qualité peut rester proche de la source, au prix d’une bande passante plus importante et d’une charge serveur généralement plus élevée. Si le débit choisi dépasse celui de la vidéo d’origine, cela ne crée pas de détails supplémentaires : ReDeFin considère alors la qualité comme proche du maximum. Les jauges CPU et Qualité sont des estimations indicatives et non des mesures en temps réel."
        }

        return ""
    }

    function _openQualityInfo(idx) {
        idx = idx | 0

        if (!_qualityIndexHasInfo(idx))
            return false

        qualityInfoIndex = idx
        qualityInfoOpen = true
        userActivity()
        return true
    }

    function _closeQualityInfo() {
        if (!qualityInfoOpen)
            return false

        qualityInfoOpen = false
        qualityInfoIndex = -1
        userActivity()

        Qt.callLater(function() {
            if (root.qualityPanelOpen && root.allowUi)
                settingsList.forceActiveFocus()
        })

        return true
    }

    function _normalizeRate(rate) {
        var r = Number(rate)

        if (!(r > 0))
            r = 1.0

        r = Math.round(r * 4.0) / 4.0

        if (r < 0.25)
            r = 0.25

        if (r > 2.0)
            r = 2.0

        return r
    }

    function _normalizeMode(mode) {
        var value = Math.floor(Number(mode) || 0)

        if (value < 0)
            return 0

        if (value > 3)
            return 3

        return value
    }

    function _indexForBitrate(bitrate) {
        if (directPlaySelected)
            return 1

        if (remuxSelected)
            return 2

        if (automaticServerSelected)
            return 0

        var b = Math.max(
                    0,
                    Math.floor(Number(bitrate || 0)))

        if (b <= 0)
            return 0

        var firstBitrateIndex = 3

        for (var i = firstBitrateIndex;
             i < qualityValues.length;
             ++i) {

            if (qualityValues[i] === b)
                return i
        }

        var best = firstBitrateIndex
        var diff =
            Math.abs(
                qualityValues[firstBitrateIndex] - b)

        for (var j = firstBitrateIndex + 1;
             j < qualityValues.length;
             ++j) {

            var d =
                Math.abs(
                    qualityValues[j] - b)

            if (d < diff) {
                diff = d
                best = j
            }
        }

        return best
    }

    function _indexForRate(rate) {
        var r = _normalizeRate(rate)

        return _clamp(
                    Math.round(
                        (r - 0.25) / 0.25),
                    0,
                    rateValues.length - 1)
    }

    function _subtitleRealCount() {
        return subtitleTracks &&
               subtitleTracks.length
                ? subtitleTracks.length
                : 0
    }

    // Contrat PlayerOverlay :
    // - subtitleTracks contient uniquement les vraies pistes Jellyfin ;
    // - subtitleStreamIndexMap / subtitleIsTextMap contiennent déjà l'entrée 0
    //   synthétique correspondant à « Aucun » (-1 / false).
    // Le panneau ajoute donc « Aucun » uniquement à l'affichage, sans modifier
    // les tableaux transmis par le player. Cela garde labels, streamIndex et
    // isText parfaitement alignés.
    function _subtitleLabelAt(uiIdx) {
        uiIdx = uiIdx | 0

        if (uiIdx === 0)
            return "Aucun"

        var realIdx = uiIdx - 1

        return subtitleTracks &&
               realIdx >= 0 &&
               realIdx < subtitleTracks.length
                ? String(
                      subtitleTracks[realIdx] || "")
                : ""
    }

    function _modelCount() {
        if (activePanel === panelQuality)
            return qualityValues.length

        if (activePanel === panelZoom)
            return modeValues.length

        if (activePanel === panelSpeed)
            return rateValues.length

        if (activePanel === panelAudio)
            return audioTracks
                    ? audioTracks.length
                    : 0

        // « Aucun » reste toujours disponible, même si le média ne possède
        // aucune vraie piste de sous-titres.
        if (activePanel === panelSubtitle)
            return _subtitleRealCount() + 1

        return 0
    }

    function _labelAt(idx) {
        if (idx < 0)
            return ""

        if (activePanel === panelQuality) {
            if (idx === 0 &&
                automaticQualityLabel.length > 0)
                return automaticQualityLabel

            return qualityLabels[idx] || ""
        }

        if (activePanel === panelZoom)
            return modeLabels[idx] || ""

        if (activePanel === panelSpeed)
            return rateLabels[idx] || ""

        if (activePanel === panelAudio)
            return audioTracks &&
                   idx < audioTracks.length
                    ? String(
                          audioTracks[idx] || "")
                    : ""

        if (activePanel === panelSubtitle)
            return _subtitleLabelAt(idx)

        return ""
    }

    function _hintAt(idx) {
        if (activePanel === panelZoom)
            return modeHints[idx] || ""

        if (activePanel === panelSpeed)
            return rateHints[idx] || ""

        return ""
    }

    function _valueAt(idx) {
        if (activePanel === panelQuality)
            return qualityValues[idx]

        if (activePanel === panelZoom)
            return modeValues[idx]

        if (activePanel === panelSpeed)
            return rateValues[idx]

        return 0
    }

    function _trackInfoText(tracks, idx, note) {
        var n =
            tracks && tracks.length
                ? tracks.length
                : 0

        if (!n)
            return ""

        idx =
            _clamp(
                idx | 0,
                0,
                n - 1)

        var label =
            String(
                tracks[idx] || "")

        if (!label)
            return ""

        var suffix =
            String(note || "")

        return "Piste utilisée : " +
               label +
               (suffix.length > 0
                    ? (" • " + suffix)
                    : "")
    }

    function _subtitleInfoText(uiIdx, note) {
        var count =
            _subtitleRealCount() + 1

        uiIdx =
            _clamp(
                uiIdx | 0,
                0,
                Math.max(
                    0,
                    count - 1))

        var suffix =
            String(note || "")

        // L'état réel prime sur le simple index visuel. Si la map indique -1,
        // le panneau doit clairement annoncer que les sous-titres sont coupés.
        var streamIdx = -1

        if (subtitleStreamIndexMap &&
            subtitleStreamIndexMap.length > uiIdx)
            streamIdx =
                Number(
                    subtitleStreamIndexMap[uiIdx])

        if (uiIdx === 0 ||
            !(streamIdx >= 0))
            return "Sous-titres désactivés" +
                   (suffix.length > 0
                        ? (" • " + suffix)
                        : "")

        var label =
            _subtitleLabelAt(uiIdx)

        if (!label)
            return ""

        return "Piste utilisée : " +
               label +
               (suffix.length > 0
                    ? (" • " + suffix)
                    : "")
    }

    function _controlForPanel(panel) {
        if (panel === panelZoom)
            return controlZoom

        if (panel === panelSpeed)
            return controlSpeed

        if (panel === panelAudio)
            return controlAudio

        if (panel === panelSubtitle)
            return controlSubtitle

        return controlQuality
    }

    function _appliedIndex() {
        if (activePanel === panelQuality) {
            if (directPlaySelected)
                return 1

            if (remuxSelected)
                return 2

            if (automaticServerSelected)
                return 0

            for (var i = 3;
                 i < qualityValues.length;
                 ++i)
                if (selectedBitrate ===
                    qualityValues[i])
                    return i

            return 0
        }

        if (activePanel === panelZoom)
            return _normalizeMode(
                        selectedMode)

        if (activePanel === panelSpeed)
            return _indexForRate(
                        selectedRate)

        if (activePanel === panelAudio)
            return audioCurrentIndex | 0

        if (activePanel === panelSubtitle)
            return subtitleCurrentIndex | 0

        return -1
    }

    function _isAppliedIndex(idx) {
        return idx === _appliedIndex()
    }

    function _setIndex(idx) {
        var count = _modelCount()

        if (count <= 0) {
            selectedIndex = 0
            settingsList.currentIndex = 0
            return false
        }

        idx =
            _clamp(
                idx | 0,
                0,
                count - 1)

        selectedIndex = idx
        settingsList.currentIndex = idx

        return true
    }

    property int _trackFocusRetryLeft: 0

    function _focusCurrentTrackNow() {
        if (!root.activeTrackPanel ||
            !root.allowUi)
            return false

        var idx =
            root.activePanel === root.panelAudio
                ? root.audioCurrentIndex
                : root.subtitleCurrentIndex

        root._setIndex(idx)

        if (root._modelCount() > 0)
            settingsList.positionViewAtIndex(
                        root.selectedIndex,
                        ListView.Center)

        settingsList.forceActiveFocus()

        return settingsList.activeFocus &&
               settingsList.currentIndex ===
               root.selectedIndex
    }

    function focusCurrentTrack() {
        if (!root.activeTrackPanel ||
            !root.allowUi)
            return false

        root._trackFocusRetryLeft = 3

        var ok =
            root._focusCurrentTrackNow()

        if (!ok)
            trackFocusRetry.restart()

        return ok
    }

    Timer {
        id: trackFocusRetry

        interval: 24
        repeat: false
        running: false

        onTriggered: {
            if (!root.activeTrackPanel ||
                !root.allowUi) {
                root._trackFocusRetryLeft = 0
                return
            }

            var ok =
                root._focusCurrentTrackNow()

            root._trackFocusRetryLeft =
                Math.max(
                    0,
                    root._trackFocusRetryLeft - 1)

            if (!ok &&
                root._trackFocusRetryLeft > 0)
                restart()
        }
    }

    function _focusListLater() {
        Qt.callLater(function() {
            if (!root.panelOpen ||
                !root.allowUi)
                return

            if (root.activeTrackPanel) {
                root.focusCurrentTrack()
                return
            }

            var count =
                root._modelCount()

            if (count > 0)
                settingsList.positionViewAtIndex(
                            root.selectedIndex,
                            ListView.Contain)

            settingsList.forceActiveFocus()
        })
    }

    function openPanel(panel, currentValue) {
        if (!allowUi ||
            chaptersPanelOpen ||
            activePanel !== panelNone)
            return false

        if (panel !== panelQuality &&
            panel !== panelZoom &&
            panel !== panelSpeed)
            return false

        activePanel = panel

        if (panel === panelQuality)
            _setIndex(
                _indexForBitrate(
                    currentValue > 0
                        ? currentValue
                        : selectedBitrate))

        else if (panel === panelZoom)
            _setIndex(
                _normalizeMode(
                    currentValue))

        else if (panel === panelSpeed)
            _setIndex(
                _indexForRate(
                    currentValue))

        userActivity()
        _focusListLater()

        return true
    }

    function openQualityPanel(currentBitrate) {
        return openPanel(
                    panelQuality,
                    currentBitrate > 0
                        ? currentBitrate
                        : selectedBitrate)
    }

    function openZoomPanel(currentMode) {
        return openPanel(
                    panelZoom,
                    currentMode)
    }

    function openSpeedPanel(currentRate) {
        return openPanel(
                    panelSpeed,
                    currentRate)
    }

    function _syncExternalTrackPanel() {
        if (!allowUi ||
            chaptersPanelOpen) {

            if (trackPanelOpen)
                activePanel = panelNone

            return
        }

        if (audioMenuOpen) {
            if (activePanel !== panelAudio) {
                activePanel = panelAudio
                _setIndex(audioCurrentIndex)
                _focusListLater()
            }

            return
        }

        if (subtitleMenuOpen) {
            if (activePanel !== panelSubtitle) {
                activePanel = panelSubtitle
                _setIndex(subtitleCurrentIndex)
                _focusListLater()
            }

            return
        }

        if (trackPanelOpen)
            activePanel = panelNone
    }

    function syncTrackIndexes(
        audioIdx,
        subtitleIdx) {

        if (activePanel === panelAudio) {
            _setIndex(audioIdx)

            Qt.callLater(function() {
                if (root.audioPanelOpen)
                    root.focusCurrentTrack()
            })
        }

        else if (activePanel === panelSubtitle) {
            _setIndex(subtitleIdx)

            Qt.callLater(function() {
                if (root.subtitlePanelOpen)
                    root.focusCurrentTrack()
            })
        }
    }

    function _closeSettingsToButton() {
        if (!settingsPanelOpen)
            return false

        if (qualityInfoOpen)
            _closeQualityInfo()

        var control =
            _controlForPanel(
                activePanel)

        activePanel = panelNone

        userActivity()
        requestButtonFocus(control)

        return true
    }

    function _closeSettingsAndFocus(control) {
        if (qualityInfoOpen) {
            qualityInfoOpen = false
            qualityInfoIndex = -1
        }
        activePanel = panelNone

        userActivity()
        requestButtonFocus(control)

        return true
    }

    function _closeSettingsAndFocusControls() {
        if (qualityInfoOpen) {
            qualityInfoOpen = false
            qualityInfoIndex = -1
        }

        var control =
            _controlForPanel(
                activePanel)

        activePanel = panelNone

        userActivity()
        requestFocusControls(control)

        return true
    }

    function _closeSettingsAndFocusChapters() {
        if (qualityInfoOpen) {
            qualityInfoOpen = false
            qualityInfoIndex = -1
        }
        activePanel = panelNone

        userActivity()
        requestFocusChapters()

        return true
    }

    function _closeTrackToButton() {
        if (!trackPanelOpen)
            return false

        var control =
            _controlForPanel(
                activePanel)

        userActivity()
        requestTrackClose(control)

        return true
    }

    function _activateSettingsFocused() {
        if (!settingsPanelOpen ||
            _modelCount() <= 0)
            return false

        var panel = activePanel

        var idx =
            _clamp(
                settingsList.currentIndex | 0,
                0,
                _modelCount() - 1)

        var value =
            _valueAt(idx)

        var control =
            _controlForPanel(panel)

        selectedIndex = idx
        activePanel = panelNone

        if (panel === panelQuality)
            requestQuality(
                Math.floor(
                    Number(
                        value || 0)))

        else if (panel === panelZoom)
            requestZoom(
                Math.floor(
                    Number(
                        value || 0)))

        else if (panel === panelSpeed)
            requestSpeed(
                Number(
                    value || 1.0))

        requestButtonFocus(control)
        userActivity()

        return true
    }

    function _activateTrackFocused() {
        if (!trackPanelOpen ||
            _modelCount() <= 0)
            return false

        var idx =
            _clamp(
                settingsList.currentIndex | 0,
                0,
                _modelCount() - 1)

        var panel = activePanel
        var control =
            _controlForPanel(
                panel)

        selectedIndex = idx

        // IMPORTANT Freebox :
        // rendre le focus au bouton AVANT de lancer une renégociation de source.
        // Sinon settingsList peut conserver l'activeFocus alors que le panneau
        // est déjà invisible, surtout lors d'un DirectPlay -> Remux/Transcodage avec PGS.
        // Le focus ne revenait alors qu'au masquage du chrome, via la progressbar.
        activePanel = panelNone
        _releasePanelFocus()
        requestTrackClose(control)

        if (panel === panelAudio) {
            var audioStream =
                audioStreamIndexMap &&
                audioStreamIndexMap.length > idx
                    ? audioStreamIndexMap[idx]
                    : -1

            requestAudioPick(
                audioStream,
                idx)
        }

        else if (panel === panelSubtitle) {
            // Index visuel 0 = choix synthétique « Aucun ». Les index > 0
            // correspondent directement aux maps transmises par PlayerOverlay.
            if (idx === 0) {
                requestSubtitleOff()
            }

            else {
                var subStream =
                    subtitleStreamIndexMap &&
                    subtitleStreamIndexMap.length > idx
                        ? subtitleStreamIndexMap[idx]
                        : -1

                var isText =
                    subtitleIsTextMap &&
                    subtitleIsTextMap.length > idx
                        ? !!subtitleIsTextMap[idx]
                        : false

                if (isText)
                    requestSubtitleText(
                        subStream,
                        idx)
                else
                    requestSubtitleImage(
                        subStream,
                        idx)
            }
        }

        userActivity()

        return true
    }

    function activateFocused() {
        return trackPanelOpen
                ? _activateTrackFocused()
                : _activateSettingsFocused()
    }

    // Navigation D-Pad des boutons de réglages hors panneau. PlayerOverlay ne
    // conserve qu'un petit routeur vers cette fonction ; les règles restent
    // dans le composant qui possède Qualité / Zoom / Vitesse.
    function handlePlayerFocusKey(
        event,
        control,
        transportControlsFocused,
        controlsButtonIndex) {

        if (!event ||
            panelOpen ||
            !allowUi ||
            chaptersPanelOpen)
            return false

        var key = event.key

        // Les transports sont au centre. Chapitres est leur voisin immédiat à
        // gauche ; Qualité est leur voisin immédiat à droite.
        if (transportControlsFocused) {
            if (key === Qt.Key_Left &&
                (controlsButtonIndex | 0) <= 1) {

                requestFocusChapters()

                event.accepted = true
                return true
            }

            if (key === Qt.Key_Right &&
                (controlsButtonIndex | 0) >= 5) {

                requestButtonFocus(
                    controlQuality)

                event.accepted = true
                return true
            }

            return false
        }

        if (control !== controlQuality &&
            control !== controlZoom &&
            control !== controlSpeed)
            return false

        if (key === Qt.Key_Up) {
            requestFocusProgress()
            event.accepted = true
            return true
        }

        if (key === Qt.Key_Down) {
            if (control === controlQuality)
                requestFocusControls(
                    controlQuality)
            else
                requestFocusControlsLeft()

            event.accepted = true
            return true
        }

        if (key === Qt.Key_Return ||
            key === Qt.Key_Enter ||
            key === Qt.Key_Select ||
            key === Qt.Key_Space) {

            requestOpenControl(control)

            event.accepted = true
            return true
        }

        if (control === controlZoom) {
            if (key === Qt.Key_Left) {
                event.accepted = true
                return true
            }

            if (key === Qt.Key_Right) {
                requestButtonFocus(
                    controlSpeed)

                event.accepted = true
                return true
            }
        }

        else if (control === controlSpeed) {
            if (key === Qt.Key_Left) {
                requestButtonFocus(
                    controlZoom)

                event.accepted = true
                return true
            }

            if (key === Qt.Key_Right) {
                requestFocusChapters()

                event.accepted = true
                return true
            }
        }

        else if (control === controlQuality) {
            if (key === Qt.Key_Left) {
                requestFocusControls(
                    controlQuality)

                event.accepted = true
                return true
            }

            if (key === Qt.Key_Right) {
                requestButtonFocus(
                    controlAudio)

                event.accepted = true
                return true
            }
        }

        return false
    }

    function handleKey(event) {
        if (!panelOpen ||
            !event)
            return false

        var key = event.key

        // La boîte d'aide est modale : INFO, OK ou Retour la ferme sans
        // déclencher l'option de qualité sous-jacente.
        if (qualityInfoOpen) {
            if (_isInfoKey(event) ||
                key === Qt.Key_Back ||
                key === Qt.Key_Escape ||
                key === Qt.Key_Return ||
                key === Qt.Key_Enter ||
                key === Qt.Key_Select ||
                key === Qt.Key_Ok ||
                key === Qt.Key_Space) {
                _closeQualityInfo()
            }
            event.accepted = true
            return true
        }

        // INFO est disponible pour chaque choix du panneau Qualité.
        if (qualityPanelOpen &&
            _isInfoKey(event) &&
            _qualityIndexHasInfo(settingsList.currentIndex)) {
            _openQualityInfo(settingsList.currentIndex)
            event.accepted = true
            return true
        }

        var count = _modelCount()

        if (key === Qt.Key_Up) {
            if (count > 0 &&
                settingsList.currentIndex > 0)
                _setIndex(
                    settingsList.currentIndex - 1)

            userActivity()
            return true
        }

        if (key === Qt.Key_Down) {
            if (count > 0 &&
                settingsList.currentIndex < count - 1)
                _setIndex(
                    settingsList.currentIndex + 1)

            userActivity()
            return true
        }

        if (key === Qt.Key_Return ||
            key === Qt.Key_Enter ||
            key === Qt.Key_Select ||
            key === Qt.Key_Space)
            return activateFocused()

        if (trackPanelOpen) {
            if (key === Qt.Key_Left ||
                key === Qt.Key_Back ||
                key === Qt.Key_Escape)
                return _closeTrackToButton()

            return true
        }

        // Même ordre horizontal que les boutons visibles :
        // Zoom → Vitesse → Chapitres | transports | Qualité → Audio → Sous-titres.
        if (activePanel === panelQuality) {
            if (key === Qt.Key_Left)
                return _closeSettingsAndFocusControls()

            if (key === Qt.Key_Right)
                return _closeSettingsAndFocus(
                            controlAudio)

            if (key === Qt.Key_Back ||
                key === Qt.Key_Escape)
                return _closeSettingsToButton()
        }

        else if (activePanel === panelZoom) {
            if (key === Qt.Key_Left ||
                key === Qt.Key_Back ||
                key === Qt.Key_Escape)
                return _closeSettingsToButton()

            if (key === Qt.Key_Right)
                return _closeSettingsAndFocus(
                            controlSpeed)
        }

        else if (activePanel === panelSpeed) {
            if (key === Qt.Key_Left)
                return _closeSettingsAndFocus(
                            controlZoom)

            if (key === Qt.Key_Right)
                return _closeSettingsAndFocusChapters()

            if (key === Qt.Key_Back ||
                key === Qt.Key_Escape)
                return _closeSettingsToButton()
        }

        return true
    }

    onAllowUiChanged: {
        if (!allowUi) {
            qualityInfoOpen = false
            qualityInfoIndex = -1
            activePanel = panelNone
        } else {
            _syncExternalTrackPanel()
        }
    }

    onChaptersPanelOpenChanged: {
        if (chaptersPanelOpen) {
            qualityInfoOpen = false
            qualityInfoIndex = -1
            activePanel = panelNone
        } else {
            _syncExternalTrackPanel()
        }
    }

    onAudioMenuOpenChanged:
        _syncExternalTrackPanel()

    onSubtitleMenuOpenChanged:
        _syncExternalTrackPanel()

    onAudioCurrentIndexChanged:
        if (audioPanelOpen) {
            _setIndex(
                audioCurrentIndex)

            _focusListLater()
        }

    onSubtitleCurrentIndexChanged:
        if (subtitlePanelOpen) {
            _setIndex(
                subtitleCurrentIndex)

            _focusListLater()
        }

    onAudioTracksChanged:
        if (audioPanelOpen) {
            _setIndex(
                audioCurrentIndex)

            _focusListLater()
        }

    onSubtitleTracksChanged:
        if (subtitlePanelOpen) {
            _setIndex(
                subtitleCurrentIndex)

            _focusListLater()
        }

    Component.onCompleted:
        _syncExternalTrackPanel()

    // Aide contextuelle des trois modes principaux de Qualité vidéo.
    // Même langage visuel que les menus Audio / Sous-titres / Qualité :
    // même panneau 520x360, même verre sombre, même bordure et même typographie.
    FocusScope {
        id: qualityInfoDialog

        anchors.fill: parent

        z: 100

        visible:
            root.qualityInfoOpen &&
            root.qualityPanelOpen &&
            root.allowUi

        enabled: visible
        focus: visible

        // Zone invisible de capture afin que la fenêtre reste réellement modale
        // sans ajouter de voile ou de couleur qui n'existe pas dans les autres menus.
        MouseArea {
            anchors.fill: parent
            z: 0
            onClicked: root._closeQualityInfo()
        }

        Rectangle {
            id: qualityInfoCard

            width: 520
            height: 360

            x:
                root.width -
                32 -
                width

            y:
                (root.height -
                 root.safeBottomMargin -
                 56) -
                height -
                18

            radius: 14

            color:
                Qt.rgba(
                    0,
                    0,
                    0,
                    1.0)

            border.width: 1

            border.color:
                Qt.rgba(
                    1,
                    1,
                    1,
                    0.25)

            clip: true
            z: 1

            opacity:
                qualityInfoDialog.visible
                    ? 1.0
                    : 0.0

            scale:
                qualityInfoDialog.visible
                    ? 1.0
                    : 0.98

            Behavior on opacity {
                NumberAnimation {
                    duration: 140
                    easing.type: Easing.OutCubic
                }
            }

            Behavior on scale {
                NumberAnimation {
                    duration: 180
                    easing.type: Easing.OutCubic
                }
            }

            Item {
                id: qualityInfoInner

                anchors.fill: parent
                anchors.margins: 12

                Item {
                    id: qualityInfoHeader

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top

                    height: 55
                    clip: true

                    Row {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top

                        height: 28
                        spacing: 10

                        Rectangle {
                            width: 22
                            height: 22
                            radius: 11

                            anchors.verticalCenter:
                                parent.verticalCenter

                            color: "transparent"

                            border.width: 1

                            border.color:
                                Qt.rgba(
                                    1,
                                    1,
                                    1,
                                    0.75)

                            Text {
                                anchors.centerIn: parent

                                text: "i"
                                textFormat: Text.PlainText

                                color: "#FFFFFF"

                                font.pixelSize: 14
                                font.bold: true
                            }
                        }

                        Text {
                            width:
                                parent.width -
                                32

                            height: parent.height

                            text:
                                root._qualityInfoTitleFor(
                                    root.qualityInfoIndex)

                            textFormat:
                                Text.PlainText

                            color: "#FFFFFF"

                            font.pixelSize: 22
                            font.bold: true

                            verticalAlignment:
                                Text.AlignVCenter

                            elide:
                                Text.ElideRight

                            wrapMode:
                                Text.NoWrap

                            maximumLineCount: 1

                            clip: true
                        }
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.right: parent.right

                        anchors.top: parent.top
                        anchors.topMargin: 34

                        height: 21

                        text: "Informations sur le mode de lecture"

                        textFormat:
                            Text.PlainText

                        color:
                            Qt.rgba(
                                1,
                                1,
                                1,
                                0.62)

                        font.pixelSize: 15

                        elide:
                            Text.ElideRight

                        wrapMode:
                            Text.NoWrap

                        maximumLineCount: 1

                        clip: true
                    }
                }

                Item {
                    id: qualityInfoBody

                    anchors.left: parent.left
                    anchors.right: parent.right

                    anchors.top:
                        qualityInfoHeader.bottom

                    anchors.topMargin: 6

                    anchors.bottom: parent.bottom

                    clip: true

                    Text {
                        id: qualityInfoBodyText

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top

                        text:
                            root._qualityInfoTextFor(
                                root.qualityInfoIndex)

                        textFormat:
                            Text.PlainText

                        color: "#FFFFFF"

                        font.pixelSize: 17

                        lineHeightMode:
                            Text.ProportionalHeight

                        lineHeight: 1.16

                        wrapMode:
                            Text.WordWrap
                    }

                }
            }
        }
    }

    Rectangle {
        id: settingsPanel

        width: 520
        height: 360

        x:
            (root.activeTrackPanel ||
             root.activePanel ===
             root.panelQuality)
                ? (root.width - 32 - width)
          : root.activePanel ===
            root.panelZoom
                ? 80
          : 150

        y:
            (root.height -
             root.safeBottomMargin -
             56) -
            height -
            18

        visible:
            root.panelOpen &&
            root.allowUi

        opacity:
            root.panelOpen
                ? 1.0
                : 0.0

        scale:
            root.panelOpen
                ? 1.0
                : 0.98

        color:
            Qt.rgba(
                0,
                0,
                0,
                0.75)

        border.width: 1

        border.color:
            Qt.rgba(
                1,
                1,
                1,
                0.25)

        radius: 14
        clip: true

        z: 20

        Behavior on opacity {
            NumberAnimation {
                duration: 140
                easing.type:
                    Easing.OutCubic
            }
        }

        Behavior on scale {
            NumberAnimation {
                duration: 180
                easing.type:
                    Easing.OutCubic
            }
        }

        Item {
            id: panelInner

            anchors.fill: parent

            anchors.margins:
                root.activeTrackPanel
                    ? 14
                    : 12

            Item {
                id: menuHeader

                anchors.left:
                    parent.left

                anchors.right:
                    parent.right

                anchors.top:
                    parent.top

                height:
                    root.activeTrackPanel
                        ? 52
                        : (root.activePanel ===
                           root.panelQuality
                               ? 55
                               : 54)

                clip: true

                Text {
                    id: trackHeaderIcon

                    visible:
                        root.activeTrackPanel

                    text:
                        root.activePanel ===
                        root.panelAudio
                            ? "🎵"
                            : "📄"

                    color: "white"

                    font.pixelSize: 22

                    width:
                        visible
                            ? 28
                            : 0

                    height: 52

                    verticalAlignment:
                        Text.AlignVCenter

                    horizontalAlignment:
                        Text.AlignHCenter

                    anchors.left:
                        parent.left

                    anchors.top:
                        parent.top
                }

                Item {
                    id: headerTextBox

                    anchors.left:
                        root.activeTrackPanel
                            ? trackHeaderIcon.right
                            : parent.left

                    anchors.leftMargin:
                        root.activeTrackPanel
                            ? 10
                            : 0

                    anchors.right:
                        parent.right

                    anchors.top:
                        parent.top

                    anchors.bottom:
                        parent.bottom

                    clip: true

                    Text {
                        id: titleText

                        text:
                            root.panelTitle

                        textFormat:
                            Text.PlainText

                        color: "white"

                        font.pixelSize: 22

                        font.bold:
                            !root.activeTrackPanel

                        height: 28

                        width:
                            parent.width

                        anchors.top:
                            parent.top

                        verticalAlignment:
                            Text.AlignVCenter

                        elide:
                            Text.ElideRight

                        wrapMode:
                            Text.NoWrap

                        maximumLineCount: 1

                        clip: true
                    }

                    Text {
                        text:
                            root.panelInfoText

                        textFormat:
                            Text.PlainText

                        color:
                            root.activeTrackPanel
                                ? Qt.rgba(
                                      1,
                                      1,
                                      1,
                                      0.70)
                                : Qt.rgba(
                                      1,
                                      1,
                                      1,
                                      0.62)

                        font.pixelSize:
                            root.activeTrackPanel
                                ? 14
                                : 15

                        height:
                            root.activePanel ===
                            root.panelQuality
                                ? 21
                                : 20

                        width:
                            parent.width

                        anchors.top:
                            titleText.bottom

                        anchors.topMargin:
                            root.activeTrackPanel
                                ? 1
                                : 6

                        elide:
                            Text.ElideRight

                        wrapMode:
                            Text.NoWrap

                        maximumLineCount: 1

                        clip: true
                    }
                }
            }

            Item {
                id: listArea

                anchors.left:
                    parent.left

                anchors.right:
                    parent.right

                anchors.top:
                    menuHeader.bottom

                anchors.topMargin:
                    root.activeTrackPanel
                        ? 10
                        : 6

                anchors.bottom:
                    parent.bottom

                clip: true

                Column {
                    anchors.centerIn:
                        parent

                    spacing: 8

                    visible:
                        root.activeTrackPanel &&
                        root._modelCount() === 0

                    Text {
                        text:
                            "¯\\_(ツ)_/¯"

                        font.pixelSize: 22

                        color:
                            Qt.rgba(
                                1,
                                1,
                                1,
                                0.70)

                        width:
                            listArea.width

                        horizontalAlignment:
                            Text.AlignHCenter

                        elide:
                            Text.ElideRight

                        clip: true
                    }

                    Text {
                        text:
                            root.activePanel ===
                            root.panelAudio
                                ? "Aucune piste audio"
                                : "Aucun sous-titre"

                        font.pixelSize: 16

                        color:
                            Qt.rgba(
                                1,
                                1,
                                1,
                                0.70)

                        width:
                            listArea.width

                        horizontalAlignment:
                            Text.AlignHCenter

                        elide:
                            Text.ElideRight

                        clip: true
                    }
                }

                ListView {
                    id: settingsList

                    anchors.fill: parent

                    anchors.rightMargin:
                        panelScrollBg.visible
                            ? 10
                            : 0

                    visible:
                        root._modelCount() > 0

                    model:
                        root._modelCount()

                    currentIndex:
                        root.selectedIndex

                    clip: true
                    focus: false
                    onVisibleChanged: {
                        if (!visible)
                            focus = false
                    }

                    spacing:
                        root.activeTrackPanel
                            ? 0
                            : 2

                    interactive:
                        root.activeTrackPanel

                    boundsBehavior:
                        Flickable.StopAtBounds

                    reuseItems: true

                    cacheBuffer:
                        root.activePanel ===
                        root.panelQuality
                            ? 120
                      : root.activeTrackPanel
                            ? Math.round(
                                  root.activeRowHeight *
                                  2)
                            : 0

                    highlightFollowsCurrentItem:
                        true

                    highlightRangeMode:
                        root.activeTrackPanel
                            ? ListView.NoHighlightRange
                            : ListView.StrictlyEnforceRange

                    preferredHighlightBegin:
                        root.activeTrackPanel
                            ? root.activeRowHeight
                            : 0

                    preferredHighlightEnd:
                        height -
                        root.activeHighlightTail

                    highlightMoveDuration:
                        root.activeHighlightDuration

                    highlightMoveVelocity: -1

                    // Focus unifié sur les cinq menus :
                    // Qualité / Zoom / Vitesse / Audio / Sous-titres.
                    // Une seule couche blanche translucide, sans cadre blanc
                    // supplémentaire.
                    highlight: Rectangle {
                        width:
                            settingsList.width

                        height:
                            root.activeRowHeight

                        radius:
                            root.activeTrackPanel
                                ? 10
                                : 6

                        color:
                            Qt.rgba(
                                1,
                                1,
                                1,
                                0.16)

                        border.width: 0
                    }

                    delegate: Item {
                        id: row

                        width:
                            settingsList.width

                        height:
                            root.activeRowHeight

                        clip: true

                        property bool applied:
                            root._isAppliedIndex(
                                index)

                        property bool hasHint:
                            root.activePanel ===
                            root.panelZoom ||
                            root.activePanel ===
                            root.panelSpeed

                        Rectangle {
                            anchors.fill:
                                parent

                            radius: 10

                            visible:
                                root.activeTrackPanel

                            color:
                                trackMouse.containsMouse
                                    ? Qt.rgba(
                                          1,
                                          1,
                                          1,
                                          0.08)
                                    : "transparent"
                        }

                        Item {
                            id: radioBox

                            width: 22
                            height: 22

                            anchors.left:
                                parent.left

                            anchors.leftMargin: 10

                            anchors.verticalCenter:
                                parent.verticalCenter

                            Rectangle {
                                anchors.fill:
                                    parent

                                radius:
                                    height / 2

                                color:
                                    "transparent"

                                border.width: 2

                                border.color:
                                    Qt.rgba(
                                        1,
                                        1,
                                        1,
                                        0.50)
                            }

                            Rectangle {
                                anchors.centerIn:
                                    parent

                                width: 10
                                height: 10

                                radius: 5

                                color:
                                    row.applied
                                        ? "white"
                                        : "transparent"
                            }
                        }

                        Column {
                            anchors.left:
                                radioBox.right

                            anchors.leftMargin: 12

                            anchors.right:
                                qualityGaugePair.visible
                                    ? qualityGaugePair.left
                                    : (qualityInfoBadge.visible
                                       ? qualityInfoBadge.left
                                       : parent.right)

                            anchors.rightMargin:
                                qualityGaugePair.visible
                                    ? 8
                                    : (qualityInfoBadge.visible
                                       ? 10
                                       : 12)

                            anchors.verticalCenter:
                                parent.verticalCenter

                            spacing:
                                root.activePanel ===
                                root.panelZoom
                                    ? 1
                                    : 0

                            Text {
                                width:
                                    parent.width

                                text:
                                    root._labelAt(
                                        index)

                                textFormat:
                                    Text.PlainText

                                color: "white"

                                font.pixelSize: 18

                                font.bold:
                                    row.applied

                                verticalAlignment:
                                    Text.AlignVCenter

                                elide:
                                    Text.ElideRight

                                wrapMode:
                                    Text.NoWrap

                                maximumLineCount: 1

                                clip: true
                            }

                            Text {
                                width:
                                    parent.width

                                visible:
                                    row.hasHint

                                text:
                                    row.hasHint
                                        ? root._hintAt(
                                              index)
                                        : ""

                                textFormat:
                                    Text.PlainText

                                color:
                                    Qt.rgba(
                                        1,
                                        1,
                                        1,
                                        0.58)

                                font.pixelSize:
                                    root.activeHintFontSize

                                elide:
                                    Text.ElideRight

                                wrapMode:
                                    Text.NoWrap

                                maximumLineCount: 1

                                clip: true
                            }
                        }

                        // Deux mini-jauges utilisant LA MÊME image source.
                        // Coût Révolution : deux aiguilles/pivots + deux Text ; aucun
                        // Timer, Canvas, shader, masque ou QtGraphicalEffects.
                        Item {
                            id: qualityGaugePair

                            visible:
                                root._qualityGaugeVisible(index)

                            width: 94
                            height: 36

                            anchors.right:
                                qualityInfoBadge.visible
                                    ? qualityInfoBadge.left
                                    : parent.right

                            anchors.rightMargin:
                                qualityInfoBadge.visible
                                    ? 7
                                    : 9

                            anchors.verticalCenter:
                                parent.verticalCenter

                            opacity:
                                (settingsList.currentIndex === index)
                                    ? 1.0
                                    : 0.82

                            // Charge serveur estimée.
                            Item {
                                id: qualityCpuGauge
                                width: 44
                                height: parent.height
                                anchors.left: parent.left
                                anchors.top: parent.top

                                Text {
                                    anchors.top: parent.top
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: "CPU"
                                    textFormat: Text.PlainText
                                    color: "#DCE2EE"
                                    font.pixelSize: 8
                                    font.bold: true
                                }

                                Item {
                                    width: 44
                                    height: 24
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.bottom: parent.bottom

                                    Image {
                                        anchors.fill: parent
                                        source: "../images/cpu_load_gauge.png"
                                        fillMode: Image.Stretch
                                        asynchronous: false
                                        cache: true
                                        smooth: true
                                        mipmap: false
                                    }

                                    Rectangle {
                                        width: 2
                                        height: 10
                                        radius: 1
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: 3
                                        color: "#FFFFFF"
                                        transformOrigin: Item.Bottom
                                        rotation: root._qualityCpuAngle(index)
                                    }

                                    Rectangle {
                                        width: 5
                                        height: 5
                                        radius: 2.5
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: 1
                                        color: "#FFFFFF"
                                    }
                                }
                            }

                            // Fidélité visuelle estimée.
                            Item {
                                id: qualityVisualGauge
                                width: 46
                                height: parent.height
                                anchors.right: parent.right
                                anchors.top: parent.top

                                Text {
                                    anchors.top: parent.top
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: "Qualité"
                                    textFormat: Text.PlainText
                                    color: "#DCE2EE"
                                    font.pixelSize: 8
                                    font.bold: true
                                }

                                Item {
                                    width: 44
                                    height: 24
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.bottom: parent.bottom

                                    Image {
                                        anchors.fill: parent
                                        source: "../images/cpu_load_gauge.png"
                                        fillMode: Image.Stretch
                                        asynchronous: false
                                        cache: true
                                        smooth: true
                                        mipmap: false
                                    }

                                    Rectangle {
                                        width: 2
                                        height: 10
                                        radius: 1
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: 3
                                        color: "#FFFFFF"
                                        transformOrigin: Item.Bottom
                                        rotation: root._qualityVisualAngle(index)
                                    }

                                    Rectangle {
                                        width: 5
                                        height: 5
                                        radius: 2.5
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: 1
                                        color: "#FFFFFF"
                                    }
                                }
                            }
                        }

                        Rectangle {
                            id: qualityInfoBadge

                            visible:
                                root._qualityIndexHasInfo(index)

                            width: 20
                            height: 20
                            radius: 10

                            anchors.right:
                                parent.right

                            anchors.rightMargin: 10

                            anchors.verticalCenter:
                                parent.verticalCenter

                            color: "transparent"

                            border.width: 1

                            border.color:
                                (settingsList.currentIndex === index)
                                    ? Qt.rgba(1, 1, 1, 0.92)
                                    : Qt.rgba(1, 1, 1, 0.58)

                            Text {
                                anchors.centerIn:
                                    parent

                                text: "i"
                                textFormat:
                                    Text.PlainText

                                color:
                                    (settingsList.currentIndex === index)
                                        ? "#FFFFFF"
                                        : Qt.rgba(1, 1, 1, 0.72)

                                font.pixelSize: 13
                                font.bold: true
                            }

                            MouseArea {
                                anchors.fill:
                                    parent

                                enabled:
                                    qualityInfoBadge.visible

                                onClicked: {
                                    settingsList.currentIndex = index
                                    root.selectedIndex = index
                                    root._openQualityInfo(index)
                                }
                            }
                        }

                        Rectangle {
                            id: ripple

                            anchors.fill:
                                parent

                            radius: 10

                            color:
                                Qt.rgba(
                                    1,
                                    1,
                                    1,
                                    0.10)

                            visible:
                                root.activeTrackPanel &&
                                opacity > 0

                            opacity: 0.0

                            Behavior on opacity {
                                NumberAnimation {
                                    duration: 180
                                    easing.type:
                                        Easing.OutCubic
                                }
                            }
                        }

                        MouseArea {
                            id: trackMouse

                            anchors.fill:
                                parent

                            enabled:
                                root.activeTrackPanel

                            hoverEnabled:
                                enabled

                            onPressed:
                                ripple.opacity = 1.0

                            onReleased:
                                ripple.opacity = 0.0

                            onCanceled:
                                ripple.opacity = 0.0

                            onClicked: {
                                settingsList.currentIndex =
                                    index

                                root.selectedIndex =
                                    index

                                root._activateTrackFocused()
                            }
                        }
                    }

                    Keys.onPressed: {
                        if (root.handleKey(event))
                            event.accepted = true
                    }
                }

                // Indicateur de défilement commun aux cinq panneaux :
                // Qualité / Zoom / Vitesse / Audio / Sous-titres.
                // Il n'est instancié visuellement que lorsqu'une partie de la
                // liste se trouve hors de la zone visible. Le curseur suit
                // visibleArea, donc sa position indique immédiatement s'il
                // reste des options au-dessus ou au-dessous.
                Rectangle {
                    id: panelScrollBg

                    anchors.top:
                        parent.top

                    anchors.bottom:
                        parent.bottom

                    anchors.right:
                        parent.right

                    width: 6

                    color:
                        Qt.rgba(
                            1,
                            1,
                            1,
                            0.10)

                    radius: 3

                    readonly property bool hasOverflow:
                        settingsList.visible &&
                        settingsList.height > 0 &&
                        settingsList.contentHeight >
                        settingsList.height + 1

                    visible:
                        hasOverflow

                    Rectangle {
                        id: panelScrollThumb

                        width: 4

                        anchors.horizontalCenter:
                            parent.horizontalCenter

                        radius: 2

                        color:
                            Qt.rgba(
                                1,
                                1,
                                1,
                                0.45)

                        height:
                            Math.max(
                                24,
                                Math.min(
                                    panelScrollBg.height,
                                    (settingsList.height *
                                     settingsList.height) /
                                    Math.max(
                                        1,
                                        settingsList.contentHeight)))

                        y:
                            Math.max(
                                0,
                                Math.min(
                                    panelScrollBg.height -
                                    height,
                                    settingsList.visibleArea.yPosition *
                                    panelScrollBg.height))
                    }
                }
            }
        }
    }
}
