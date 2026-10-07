// qml/components/UpdateManager.qml
// Vérification légère des mises à jour ReDeFin via un manifest GitHub public.
// Compatible QtQuick 2.15 / Freebox Révolution et Devialet.
// Aucun QtQuick Controls.

import QtQuick 2.15

Item {
    id: root

    width: 0
    height: 0
    visible: false

    property string manifestUrl:
        "https://raw.githubusercontent.com/laborantine/ReDeFin/main/updates/manifest.json"

    property string applicationId: "com.lab.redefin"

    // Version réellement exposée par le runtime Freebox / FreeStore.
    // Formats tolérés :
    // 0.49.true / 0.49-beta / 0.49 / 0.50 / 0.51 / 1.0 / 0.9.7.1
    property string currentVersion:
        Qt.application.version ? String(Qt.application.version) : "dev"

    // Développement uniquement. Laisser vide en production.
    property string testVersionOverride: ""

    // Garde-fous réseau/mémoire raisonnables pour Freebox Révolution.
    property int requestTimeoutMs: 7000
    property int maximumResponseLength: 65536
    property int maximumNotesLength: 16384
    property int maximumDisplayVersionLength: 64

    property bool checking: false

    property var _request: null
    property int _requestSerial: 0

    signal updateAvailable(
        string version,
        string displayVersion,
        string channel,
        string notes,
        string releasedAt,
        string localVersion
    )

    signal noUpdate(string localVersion)

    signal checkFailed(
        string reason,
        string localVersion
    )

    Timer {
        id: requestTimeoutTimer
        interval: root.requestTimeoutMs
        repeat: false
        onTriggered: root._abortActiveRequest("timeout")
    }

    function effectiveVersion() {
        var overrideValue = String(testVersionOverride || "").trim()

        if (overrideValue.length > 0)
            return overrideValue

        return String(currentVersion || "").trim()
    }

    /*
     * Parse les formats FreeStore/ReDeFin rencontrés.
     *
     * Convention ReDeFin :
     * - 0.x = bêta si aucun marqueur explicite
     * - 1.0+ = stable si aucun marqueur explicite
     * - .true / .false / -beta restent prioritaires
     */
    function _parseVersion(rawVersion) {
        var value = String(rawVersion || "").toLowerCase().trim()

        if (!value.length)
            return null

        if (value.charAt(0) === "v")
            value = value.substr(1)

        var beta = false
        var channelExplicit = false

        if (value.length > 5 &&
                value.substr(value.length - 5) === ".true") {

            beta = true
            channelExplicit = true
            value = value.substr(0, value.length - 5)

        } else if (value.length > 6 &&
                   value.substr(value.length - 6) === ".false") {

            beta = false
            channelExplicit = true
            value = value.substr(0, value.length - 6)

        } else if (value.length > 5 &&
                   value.substr(value.length - 5) === "-beta") {

            beta = true
            channelExplicit = true
            value = value.substr(0, value.length - 5)
        }

        var parts = value.split(".")

        // Quatre composantes au plus : « 0.9.7.1 » numérote la révision d'un
        // fork au-dessus d'une version officielle à trois composantes.
        if (parts.length < 2 || parts.length > 4)
            return null

        var numbers = []

        for (var i = 0; i < parts.length; ++i) {
            if (!/^[0-9]+$/.test(parts[i]))
                return null

            var parsed = parseInt(parts[i], 10)

            if (isNaN(parsed))
                return null

            numbers.push(parsed)
        }

        while (numbers.length < 4)
            numbers.push(0)

        if (!channelExplicit)
            beta = numbers[0] === 0

        return {
            major: numbers[0],
            minor: numbers[1],
            patch: numbers[2],
            revision: numbers[3],
            beta: beta,
            channelExplicit: channelExplicit
        }
    }

    function _compareParsed(a, b) {
        if (!a || !b)
            return 0

        if (a.major !== b.major)
            return a.major > b.major ? 1 : -1

        if (a.minor !== b.minor)
            return a.minor > b.minor ? 1 : -1

        if (a.patch !== b.patch)
            return a.patch > b.patch ? 1 : -1

        var aRevision = a.revision || 0
        var bRevision = b.revision || 0
        if (aRevision !== bRevision)
            return aRevision > bRevision ? 1 : -1

        // À numéro identique : stable > bêta.
        if (a.beta !== b.beta)
            return a.beta ? -1 : 1

        return 0
    }

    function _readChannel(document, channelName) {
        if (!document || !document.channels)
            return null

        var channel = document.channels[channelName]

        if (!channel || channel.published !== true)
            return null

        var versionText = String(channel.version || "").trim()
        var parsed = _parseVersion(versionText)

        if (!parsed)
            return null

        // Dans le manifest distant, le nom du canal est l'autorité.
        parsed.beta = channelName === "beta"

        // Version destinée uniquement à l'affichage utilisateur.
        // La comparaison reste strictement basée sur "version".
        // On force une seule ligne, on borne la longueur et on garde un
        // fallback compatible avec les anciens manifests.
        var displayVersionText = String(channel.displayVersion || versionText)
                .replace(/[\r\n\t]+/g, " ")
                .trim()

        if (!displayVersionText.length)
            displayVersionText = versionText

        if (displayVersionText.length > maximumDisplayVersionLength)
            displayVersionText = displayVersionText.substr(
                        0,
                        maximumDisplayVersionLength
                    )

        var notesText = String(channel.notes || "")

        if (notesText.length > maximumNotesLength)
            notesText = notesText.substr(0, maximumNotesLength)

        return {
            name: channelName,
            version: versionText,
            displayVersion: displayVersionText,
            parsed: parsed,
            notes: notesText,
            releasedAt: String(channel.releasedAt || "")
        }
    }

    function _chooseCandidate(document, installedParsed) {
        if (!installedParsed)
            return null

        var stable = _readChannel(document, "stable")

        // Une stable reste sur le canal stable.
        if (!installedParsed.beta)
            return stable

        // Une bêta peut recevoir une bêta plus récente ou la stable.
        var beta = _readChannel(document, "beta")
        var candidate = stable

        if (beta &&
                (!candidate ||
                 _compareParsed(beta.parsed, candidate.parsed) > 0)) {

            candidate = beta
        }

        return candidate
    }

    function _abortActiveRequest(reason) {
        if (!checking)
            return

        var xhr = _request
        var localVersion = effectiveVersion()

        _requestSerial++
        _request = null
        checking = false
        requestTimeoutTimer.stop()

        if (xhr) {
            try { xhr.abort() } catch (e0) {}
        }

        checkFailed(
            String(reason || "network"),
            localVersion
        )
    }

    function _processResponse(
        xhr,
        serial,
        localVersion,
        installedParsed
    ) {
        if (serial !== _requestSerial || !checking)
            return

        requestTimeoutTimer.stop()

        _request = null
        checking = false

        if (!xhr || xhr.status !== 200) {
            checkFailed(
                "http_" + (xhr ? xhr.status : 0),
                localVersion
            )
            return
        }

        var response = String(xhr.responseText || "")

        if (!response.length) {
            checkFailed("empty", localVersion)
            return
        }

        if (response.length > maximumResponseLength) {
            checkFailed("too_large", localVersion)
            return
        }

        var document = null

        try {
            document = JSON.parse(response)
        } catch (e0) {
            checkFailed("invalid_json", localVersion)
            return
        }

        if (!document || document.schemaVersion !== 1) {
            checkFailed("invalid_schema", localVersion)
            return
        }

        if (String(document.appId || "") !== applicationId) {
            checkFailed("wrong_application", localVersion)
            return
        }

        var candidate = _chooseCandidate(
            document,
            installedParsed
        )

        if (!candidate) {
            noUpdate(localVersion)
            return
        }

        if (_compareParsed(
                    candidate.parsed,
                    installedParsed
                ) <= 0) {

            noUpdate(localVersion)
            return
        }

        updateAvailable(
            candidate.version,
            candidate.displayVersion,
            candidate.name,
            candidate.notes,
            candidate.releasedAt,
            localVersion
        )
    }

    // API publique appelée une fois au démarrage par ShellPage.
    function check() {
        if (checking)
            return

        var localVersion = effectiveVersion()

        // En environnement SDK/QtCreator, utiliser testVersionOverride si besoin.
        if (localVersion.toLowerCase() === "dev") {
            noUpdate(localVersion)
            return
        }

        var installedParsed = _parseVersion(localVersion)

        if (!installedParsed) {
            checkFailed(
                "invalid_local_version",
                localVersion
            )
            return
        }

        checking = true
        _requestSerial++

        var serial = _requestSerial
        var xhr = new XMLHttpRequest()

        _request = xhr

        xhr.onreadystatechange = function() {
            if (serial !== root._requestSerial ||
                    xhr.readyState !== 4) {
                return
            }

            root._processResponse(
                xhr,
                serial,
                localVersion,
                installedParsed
            )
        }

        // Cache-buster : le manifest est réellement relu à chaque démarrage.
        var separator =
                manifestUrl.indexOf("?") >= 0
                ? "&"
                : "?"

        var requestUrl =
                manifestUrl +
                separator +
                "_redefinCheck=" +
                Date.now()

        try {
            xhr.open("GET", requestUrl)
            requestTimeoutTimer.restart()
            xhr.send()

        } catch (e0) {
            _abortActiveRequest("request_error")
        }
    }
}
