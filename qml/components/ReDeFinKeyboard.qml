// ReDeFinKeyboard.qml
// Clavier virtuel compact AZERTY pour ReDeFin / Freebox.
// QtQuick 2.15 uniquement. Aucun QtQuick Controls.
// Conçu pour télécommande D-Pad et Freebox Révolution.
//
// API conservée : openFor(item), close(), cancelKeyboard(),
// accepted(text), canceled(), textEdited(text), characterInserted(value).

import QtQuick 2.15

Item {
    id: root
    anchors.fill: parent
    z: 9000

    // ------------------------------------------------------------------
    // API publique
    // ------------------------------------------------------------------

    property bool opened: false
    property var target: null
    property string internalText: ""
    property int maximumLength: 4096

    property bool closeOnAccept: true
    property bool closeOnCancel: true
    property bool revertOnCancel: false
    property bool oneShotShift: true
    property bool capsLock: false
    property bool _oneShotUpper: false
    property bool _shiftHoldPending: false
    property bool _shiftLongActivated: false
    property bool _shiftLockCandidate: false

    // lower / upper / accents / symbols1 / symbols2
    property string mode: "lower"

    // Sélection logique : zone "main" ou "num".
    property string selectedZone: "main"
    property int selectedRow: 0
    property int selectedColumn: 0

    property string pressedZone: ""
    property int pressedRow: -1
    property int pressedColumn: -1

    // Proportions proches du clavier Freebox de référence.
    property real panelWidthRatio: 0.89
    property real panelHeightRatio: 0.40
    property real panelBottomMargin: 18

    // OLED.
    property color accentColor: "#FFFFFFFF"
    property color panelColor: "#FC000000"
    property color keyColor: "#00000000"
    property color actionKeyColor: "#00000000"
    property color pressedKeyColor: "#FF2A2A2E"
    property color textColor: "#FFF5F5F7"
    property color secondaryTextColor: "#FF9C9DA8"
    property color subtleBorderColor: "#FF22242A"

    property real keySpacing: 6
    property real rowSpacing: 5

    readonly property var mainRows: _mainRowsForMode(mode)
    readonly property var numberRows: [
        [
            { label: "7", value: "7" },
            { label: "8", value: "8" },
            { label: "9", value: "9" }
        ],
        [
            { label: "4", value: "4" },
            { label: "5", value: "5" },
            { label: "6", value: "6" }
        ],
        [
            { label: "1", value: "1" },
            { label: "2", value: "2" },
            { label: "3", value: "3" }
        ],
        [
            { label: "◀", action: "cursorLeft", actionKey: true },
            { label: "0", value: "0" },
            { label: "▶", action: "cursorRight", actionKey: true }
        ]
    ]

    signal accepted(string text)
    signal canceled()
    signal textEdited(string text)
    signal characterInserted(string value)

    visible: opacity > 0.001
    enabled: opened
    opacity: opened ? 1.0 : 0.0
    focus: opened

    Behavior on opacity {
        NumberAnimation {
            duration: 130
            easing.type: Easing.OutQuad
        }
    }

    // ------------------------------------------------------------------
    // Dispositions : 3 rangées de caractères + 1 rangée d'actions.
    // Les chiffres restent toujours accessibles à droite.
    // ------------------------------------------------------------------

    property var lowerRows: [
        [
            { label: "a", value: "a" }, { label: "z", value: "z" },
            { label: "e", value: "e" }, { label: "r", value: "r" },
            { label: "t", value: "t" }, { label: "y", value: "y" },
            { label: "u", value: "u" }, { label: "i", value: "i" },
            { label: "o", value: "o" }, { label: "p", value: "p" },
            { label: "SUPPR", action: "backspace", widthFactor: 1.18, actionKey: true }
        ],
        [
            { label: "q", value: "q" }, { label: "s", value: "s" },
            { label: "d", value: "d" }, { label: "f", value: "f" },
            { label: "g", value: "g" }, { label: "h", value: "h" },
            { label: "j", value: "j" }, { label: "k", value: "k" },
            { label: "l", value: "l" }, { label: "m", value: "m" },
            { label: "EFF", action: "clear", widthFactor: 1.18, actionKey: true }
        ],
        [
            { label: "MAJ", action: "shift", widthFactor: 1.18, actionKey: true },
            { label: "w", value: "w" }, { label: "x", value: "x" },
            { label: "c", value: "c" }, { label: "v", value: "v" },
            { label: "b", value: "b" }, { label: "n", value: "n" },
            { label: "@", value: "@" }, { label: ".", value: "." },
            { label: "ÉÀÇ", action: "accents", widthFactor: 1.18, actionKey: true },
            { label: "#+=", action: "symbols1", widthFactor: 1.18, actionKey: true }
        ],
        [
            { label: ":", value: ":" },
            { label: "/", value: "/" },
            { label: "-", value: "-" },
            { label: "_", value: "_" },
            { label: "ESPACE", value: " ", widthFactor: 4.10, actionKey: true },
            { label: "'", value: "'" },
            { label: "?", value: "?" },
            { label: "OK", action: "accept", widthFactor: 1.55, actionKey: true }
        ]
    ]

    property var upperRows: [
        [
            { label: "A", value: "A" }, { label: "Z", value: "Z" },
            { label: "E", value: "E" }, { label: "R", value: "R" },
            { label: "T", value: "T" }, { label: "Y", value: "Y" },
            { label: "U", value: "U" }, { label: "I", value: "I" },
            { label: "O", value: "O" }, { label: "P", value: "P" },
            { label: "SUPPR", action: "backspace", widthFactor: 1.18, actionKey: true }
        ],
        [
            { label: "Q", value: "Q" }, { label: "S", value: "S" },
            { label: "D", value: "D" }, { label: "F", value: "F" },
            { label: "G", value: "G" }, { label: "H", value: "H" },
            { label: "J", value: "J" }, { label: "K", value: "K" },
            { label: "L", value: "L" }, { label: "M", value: "M" },
            { label: "EFF", action: "clear", widthFactor: 1.18, actionKey: true }
        ],
        [
            { label: "MAJ", action: "shift", widthFactor: 1.18, actionKey: true },
            { label: "W", value: "W" }, { label: "X", value: "X" },
            { label: "C", value: "C" }, { label: "V", value: "V" },
            { label: "B", value: "B" }, { label: "N", value: "N" },
            { label: "@", value: "@" }, { label: ".", value: "." },
            { label: "ÉÀÇ", action: "accents", widthFactor: 1.18, actionKey: true },
            { label: "#+=", action: "symbols1", widthFactor: 1.18, actionKey: true }
        ],
        [
            { label: ":", value: ":" },
            { label: "/", value: "/" },
            { label: "-", value: "-" },
            { label: "_", value: "_" },
            { label: "ESPACE", value: " ", widthFactor: 4.10, actionKey: true },
            { label: "'", value: "'" },
            { label: "?", value: "?" },
            { label: "OK", action: "accept", widthFactor: 1.55, actionKey: true }
        ]
    ]

    property var accentRows: [
        [
            { label: "é", value: "é" }, { label: "è", value: "è" },
            { label: "ê", value: "ê" }, { label: "ë", value: "ë" },
            { label: "à", value: "à" }, { label: "â", value: "â" },
            { label: "ä", value: "ä" }, { label: "æ", value: "æ" },
            { label: "ç", value: "ç" }, { label: "œ", value: "œ" },
            { label: "SUPPR", action: "backspace", widthFactor: 1.18, actionKey: true }
        ],
        [
            { label: "î", value: "î" }, { label: "ï", value: "ï" },
            { label: "ô", value: "ô" }, { label: "ö", value: "ö" },
            { label: "ù", value: "ù" }, { label: "û", value: "û" },
            { label: "ü", value: "ü" }, { label: "ÿ", value: "ÿ" },
            { label: "É", value: "É" }, { label: "È", value: "È" },
            { label: "EFF", action: "clear", widthFactor: 1.18, actionKey: true }
        ],
        [
            { label: "Ê", value: "Ê" }, { label: "Ë", value: "Ë" },
            { label: "À", value: "À" }, { label: "Â", value: "Â" },
            { label: "Ä", value: "Ä" }, { label: "Æ", value: "Æ" },
            { label: "Ç", value: "Ç" }, { label: "Œ", value: "Œ" },
            { label: "Î", value: "Î" }, { label: "Ï", value: "Ï" },
            { label: "ABC", action: "letters", widthFactor: 1.18, actionKey: true }
        ],
        [
            { label: "Ô", value: "Ô" }, { label: "Ö", value: "Ö" },
            { label: "Ù", value: "Ù" }, { label: "Û", value: "Û" },
            { label: "Ü", value: "Ü" }, { label: "Ÿ", value: "Ÿ" },
            { label: "ESPACE", value: " ", widthFactor: 2.80, actionKey: true },
            { label: "#+=", action: "symbols1", widthFactor: 1.20, actionKey: true },
            { label: "OK", action: "accept", widthFactor: 1.45, actionKey: true }
        ]
    ]

    property var symbolRows1: [
        [
            { label: "!", value: "!" }, { label: "?", value: "?" },
            { label: "@", value: "@" }, { label: "#", value: "#" },
            { label: "€", value: "€" }, { label: "$", value: "$" },
            { label: "£", value: "£" }, { label: "%", value: "%" },
            { label: "&", value: "&" }, { label: "*", value: "*" },
            { label: "SUPPR", action: "backspace", widthFactor: 1.18, actionKey: true }
        ],
        [
            { label: "+", value: "+" }, { label: "=", value: "=" },
            { label: "\\", value: "\\" }, { label: "|", value: "|" },
            { label: "~", value: "~" }, { label: "^", value: "^" },
            { label: "`", value: "`" }, { label: "°", value: "°" },
            { label: "§", value: "§" }, { label: ";", value: ";" },
            { label: "EFF", action: "clear", widthFactor: 1.18, actionKey: true }
        ],
        [
            { label: "(", value: "(" }, { label: ")", value: ")" },
            { label: "[", value: "[" }, { label: "]", value: "]" },
            { label: "{", value: "{" }, { label: "}", value: "}" },
            { label: "<", value: "<" }, { label: ">", value: ">" },
            { label: "\"", value: "\"" }, { label: "…", value: "…" },
            { label: "2/2", action: "symbols2", widthFactor: 1.18, actionKey: true }
        ],
        [
            { label: "ABC", action: "letters", widthFactor: 1.15, actionKey: true },
            { label: "ÉÀÇ", action: "accents", widthFactor: 1.15, actionKey: true },
            { label: "«", value: "«" }, { label: "»", value: "»" },
            { label: "ESPACE", value: " ", widthFactor: 3.40, actionKey: true },
            { label: ",", value: "," }, { label: ".", value: "." },
            { label: "OK", action: "accept", widthFactor: 1.45, actionKey: true }
        ]
    ]

    property var symbolRows2: [
        [
            { label: "©", value: "©" }, { label: "®", value: "®" },
            { label: "™", value: "™" }, { label: "µ", value: "µ" },
            { label: "¢", value: "¢" }, { label: "¥", value: "¥" },
            { label: "¤", value: "¤" }, { label: "‰", value: "‰" },
            { label: "¶", value: "¶" }, { label: "•", value: "•" },
            { label: "SUPPR", action: "backspace", widthFactor: 1.18, actionKey: true }
        ],
        [
            { label: "×", value: "×" }, { label: "÷", value: "÷" },
            { label: "±", value: "±" }, { label: "≠", value: "≠" },
            { label: "≈", value: "≈" }, { label: "≤", value: "≤" },
            { label: "≥", value: "≥" }, { label: "∞", value: "∞" },
            { label: "√", value: "√" }, { label: "¬", value: "¬" },
            { label: "EFF", action: "clear", widthFactor: 1.18, actionKey: true }
        ],
        [
            { label: "¿", value: "¿" }, { label: "¡", value: "¡" },
            { label: "·", value: "·" }, { label: "–", value: "–" },
            { label: "—", value: "—" }, { label: "′", value: "′" },
            { label: "″", value: "″" }, { label: "✓", value: "✓" },
            { label: "←", value: "←" }, { label: "→", value: "→" },
            { label: "1/2", action: "symbols1", widthFactor: 1.18, actionKey: true }
        ],
        [
            { label: "ABC", action: "letters", widthFactor: 1.15, actionKey: true },
            { label: "ÉÀÇ", action: "accents", widthFactor: 1.15, actionKey: true },
            { label: "↑", value: "↑" }, { label: "↓", value: "↓" },
            { label: "ESPACE", value: " ", widthFactor: 3.40, actionKey: true },
            { label: "↔", value: "↔" }, { label: "✓", value: "✓" },
            { label: "OK", action: "accept", widthFactor: 1.45, actionKey: true }
        ]
    ]

    function _mainRowsForMode(value) {
        if (value === "upper") return upperRows
        if (value === "accents") return accentRows
        if (value === "symbols1") return symbolRows1
        if (value === "symbols2") return symbolRows2
        return lowerRows
    }

    // ------------------------------------------------------------------
    // Texte / cible
    // ------------------------------------------------------------------

    property string _initialText: ""
    property var _focusReturnTarget: null

    function currentText() {
        try {
            if (target && target.text !== undefined)
                return String(target.text)
        } catch (e) {}
        return String(internalText)
    }

    function openFor(item) {
        target = item || null
        _focusReturnTarget = item || null
        _initialText = currentText()
        capsLock = false
        _oneShotUpper = false
        _shiftHoldPending = false
        _shiftLongActivated = false
        _shiftLockCandidate = false
        mode = "lower"
        selectedZone = "main"
        selectedRow = 0
        selectedColumn = 0
        opened = true
        Qt.callLater(function() { root.forceActiveFocus() })
    }

    function close() {
        opened = false
    }

    function _restoreFocusAfterClose(kind) {
        var item = _focusReturnTarget
        Qt.callLater(function() {
            if (!item)
                return

            // Les pages ReDeFin peuvent définir précisément où doit revenir
            // le focus : conteneur de saisie, champ suivant, recherche, etc.
            try {
                if (kind === "accepted"
                        && typeof item.virtualKeyboardAccepted === "function") {
                    item.virtualKeyboardAccepted()
                    return
                }
            } catch (e0) {}

            try {
                if (kind === "canceled"
                        && typeof item.virtualKeyboardCanceled === "function") {
                    item.virtualKeyboardCanceled()
                    return
                }
            } catch (e1) {}

            // Fallback générique pour tout futur TextInput/TextEdit.
            try {
                if (item.forceActiveFocus)
                    item.forceActiveFocus()
            } catch (e2) {}
        })
    }

    function setMode(newMode) {
        mode = newMode
        selectedZone = "main"
        selectedRow = Math.max(0, Math.min(3, selectedRow))
        selectedColumn = Math.max(0, Math.min(_mainColumnCount(selectedRow) - 1,
                                              selectedColumn))
    }

    function _targetSelectionStart() {
        try {
            var v = Number(target.selectionStart)
            return isFinite(v) && !isNaN(v) ? v : -1
        } catch (e) {}
        return -1
    }

    function _targetSelectionEnd() {
        try {
            var v = Number(target.selectionEnd)
            return isFinite(v) && !isNaN(v) ? v : -1
        } catch (e) {}
        return -1
    }

    function _targetCursor() {
        try {
            var v = Number(target.cursorPosition)
            if (isFinite(v) && !isNaN(v))
                return Math.max(0, v)
        } catch (e) {}
        return currentText().length
    }

    function _emitEdited() {
        textEdited(currentText())
    }

    function insertText(value) {
        value = String(value === undefined || value === null ? "" : value)
        if (!value.length)
            return false

        var before = currentText()
        if (before.length + value.length > maximumLength)
            return false

        try {
            if (target && target.text !== undefined) {
                var start = _targetSelectionStart()
                var end = _targetSelectionEnd()
                var pos = _targetCursor()

                if (start >= 0 && end > start && typeof target.remove === "function") {
                    target.remove(start, end)
                    pos = start
                }

                if (typeof target.insert === "function") {
                    target.insert(pos, value)
                    try { target.cursorPosition = pos + value.length } catch (e1) {}
                } else {
                    var oldText = String(target.text)
                    target.text = oldText.substring(0, pos)
                            + value + oldText.substring(pos)
                    try { target.cursorPosition = pos + value.length } catch (e2) {}
                }

                characterInserted(value)
                _emitEdited()
                return true
            }
        } catch (e3) {}

        internalText += value
        characterInserted(value)
        _emitEdited()
        return true
    }

    function backspace() {
        try {
            if (target && target.text !== undefined) {
                var start = _targetSelectionStart()
                var end = _targetSelectionEnd()
                var pos = _targetCursor()

                if (start >= 0 && end > start && typeof target.remove === "function") {
                    target.remove(start, end)
                    try { target.cursorPosition = start } catch (e0) {}
                    _emitEdited()
                    return true
                }

                if (pos <= 0)
                    return false

                if (typeof target.remove === "function") {
                    target.remove(pos - 1, pos)
                } else {
                    var oldText = String(target.text)
                    target.text = oldText.substring(0, pos - 1)
                            + oldText.substring(pos)
                }
                try { target.cursorPosition = pos - 1 } catch (e1) {}
                _emitEdited()
                return true
            }
        } catch (e2) {}

        if (!internalText.length)
            return false
        internalText = internalText.substring(0, internalText.length - 1)
        _emitEdited()
        return true
    }

    function clearText() {
        try {
            if (target && target.text !== undefined) {
                target.text = ""
                try { target.cursorPosition = 0 } catch (e0) {}
                _emitEdited()
                return
            }
        } catch (e1) {}
        internalText = ""
        _emitEdited()
    }

    function moveCursor(delta) {
        try {
            if (target && target.cursorPosition !== undefined) {
                var length = currentText().length
                target.cursorPosition = Math.max(0, Math.min(length,
                                              _targetCursor() + delta))
                return true
            }
        } catch (e) {}
        return false
    }

    function _restoreInitialText() {
        try {
            if (target && target.text !== undefined) {
                target.text = _initialText
                try { target.cursorPosition = _initialText.length } catch (e0) {}
                return
            }
        } catch (e1) {}
        internalText = _initialText
    }

    // ------------------------------------------------------------------
    // Navigation D-Pad
    // ------------------------------------------------------------------

    function _mainColumnCount(row) {
        if (!mainRows || row < 0 || row >= mainRows.length)
            return 0
        return mainRows[row].length
    }

    function _numberColumnCount(row) {
        return (row >= 0 && row < numberRows.length) ? numberRows[row].length : 0
    }

    function _currentColumnCount() {
        return selectedZone === "num"
                ? _numberColumnCount(selectedRow)
                : _mainColumnCount(selectedRow)
    }

    function moveHorizontal(delta) {
        var mainCount = _mainColumnCount(selectedRow)
        var numCount = _numberColumnCount(selectedRow)
        var total = mainCount + numCount
        if (total <= 0)
            return

        var absoluteIndex = selectedZone === "num"
                ? mainCount + selectedColumn
                : selectedColumn

        absoluteIndex += delta
        if (absoluteIndex < 0)
            absoluteIndex = total - 1
        else if (absoluteIndex >= total)
            absoluteIndex = 0

        if (absoluteIndex < mainCount) {
            selectedZone = "main"
            selectedColumn = absoluteIndex
        } else {
            selectedZone = "num"
            selectedColumn = absoluteIndex - mainCount
        }
    }

    function moveVertical(delta) {
        var oldRow = selectedRow
        var oldCount = _currentColumnCount()
        var oldColumn = selectedColumn

        selectedRow += delta
        if (selectedRow < 0)
            selectedRow = 3
        else if (selectedRow > 3)
            selectedRow = 0

        var newCount = _currentColumnCount()
        if (newCount <= 1 || oldCount <= 1) {
            selectedColumn = 0
            return
        }

        var ratio = oldColumn / Math.max(1, oldCount - 1)
        selectedColumn = Math.round(ratio * Math.max(1, newCount - 1))
        selectedColumn = Math.max(0, Math.min(newCount - 1, selectedColumn))
    }

    function _selectedKey() {
        var rows = selectedZone === "num" ? numberRows : mainRows
        if (!rows || selectedRow < 0 || selectedRow >= rows.length)
            return null
        var row = rows[selectedRow]
        if (!row || selectedColumn < 0 || selectedColumn >= row.length)
            return null
        return row[selectedColumn]
    }

    function triggerSelected() {
        var key = _selectedKey()
        if (!key)
            return false

        pressedZone = selectedZone
        pressedRow = selectedRow
        pressedColumn = selectedColumn
        pressReleaseTimer.restart()

        if (key.action)
            return _runAction(String(key.action))

        if (key.value !== undefined) {
            var ok = insertText(String(key.value))
            if (ok && mode === "upper" && oneShotShift
                    && _oneShotUpper && !capsLock) {
                _oneShotUpper = false
                setMode("lower")
            }
            return ok
        }
        return false
    }

    function _activateOneShotShift() {
        if (capsLock) {
            capsLock = false
            _oneShotUpper = false
            setMode("lower")
            return
        }

        if (mode === "upper") {
            _oneShotUpper = false
            setMode("lower")
            return
        }

        _oneShotUpper = true
        setMode("upper")
    }

    function _activateCapsLock() {
        capsLock = true
        _oneShotUpper = false
        setMode("upper")
    }

    function _isActivationKey(key) {
        return key === Qt.Key_Return
                || key === Qt.Key_Enter
                || key === Qt.Key_Select
                || key === Qt.Key_Space
    }

    function _selectedIsShift() {
        var key = _selectedKey()
        return key && String(key.action || "") === "shift"
    }

    function _beginShiftPress() {
        // Si Caps Lock est déjà actif, un nouvel appui le désactive.
        if (capsLock) {
            shiftHoldTimer.stop()
            shiftCandidateTimer.stop()
            _shiftHoldPending = false
            _shiftLongActivated = false
            _shiftLockCandidate = false
            capsLock = false
            _oneShotUpper = false
            setMode("lower")
            return
        }

        // Second press rapproché : certains firmwares Freebox représentent
        // un appui long par une succession de press/release.
        if (_shiftLockCandidate) {
            shiftHoldTimer.stop()
            shiftCandidateTimer.stop()
            _shiftHoldPending = false
            _shiftLongActivated = true
            _shiftLockCandidate = false
            _activateCapsLock()
            return
        }

        // Le mode one-shot est visible immédiatement, sans latence.
        _activateOneShotShift()

        _shiftHoldPending = true
        _shiftLongActivated = false
        _shiftLockCandidate = true
        shiftHoldTimer.restart()
        shiftCandidateTimer.restart()
    }

    function _runAction(action) {
        if (action === "shift") {
            _beginShiftPress()
            return true
        }
        if (action === "letters") {
            _oneShotUpper = false
            setMode(capsLock ? "upper" : "lower")
            return true
        }
        if (action === "accents") {
            setMode("accents")
            return true
        }
        if (action === "symbols1") {
            setMode("symbols1")
            return true
        }
        if (action === "symbols2") {
            setMode("symbols2")
            return true
        }
        if (action === "backspace")
            return backspace()
        if (action === "clear") {
            clearText()
            return true
        }
        if (action === "cursorLeft")
            return moveCursor(-1)
        if (action === "cursorRight")
            return moveCursor(1)
        if (action === "accept") {
            accepted(currentText())
            if (closeOnAccept) {
                close()
                _restoreFocusAfterClose("accepted")
            }
            return true
        }
        return false
    }

    function cancelKeyboard() {
        if (mode !== "lower" && mode !== "upper") {
            _oneShotUpper = false
            setMode(capsLock ? "upper" : "lower")
            return
        }

        if (revertOnCancel)
            _restoreInitialText()

        canceled()
        if (closeOnCancel) {
            close()
            _restoreFocusAfterClose("canceled")
        }
    }

    function _insertRemoteDigit(event) {
        if (!event)
            return false

        var key = Number(event.key)
        if (key >= Qt.Key_0 && key <= Qt.Key_9) {
            insertText(String(key - Qt.Key_0))
            return true
        }

        // Secours pour certains runtimes/firmwares Freebox qui exposent
        // correctement event.text mais utilisent un keycode différent.
        var t = String(event.text || "")
        if (t.length === 1 && t >= "0" && t <= "9") {
            insertText(t)
            return true
        }

        return false
    }

    Keys.onPressed: {
        if (!opened)
            return

        if (_insertRemoteDigit(event)) {
            event.accepted = true
            return
        }

        if (event.key === Qt.Key_Left) {
            moveHorizontal(-1)
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_Right) {
            moveHorizontal(1)
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_Up) {
            moveVertical(-1)
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_Down) {
            moveVertical(1)
            event.accepted = true
            return
        }

        if (_isActivationKey(event.key)) {
            if (_selectedIsShift()) {
                // Appui initial : one-shot immédiat + armement du verrouillage.
                // Auto-repeat ou nouveau press rapproché : verrouillage.
                if (event.isAutoRepeat) {
                    if (!capsLock) {
                        shiftHoldTimer.stop()
                        shiftCandidateTimer.stop()
                        _shiftHoldPending = false
                        _shiftLongActivated = true
                        _shiftLockCandidate = false
                        _activateCapsLock()
                    }
                } else {
                    _beginShiftPress()
                }
                event.accepted = true
                return
            }

            if (!event.isAutoRepeat)
                triggerSelected()
            event.accepted = true
            return
        }

        if (event.key === Qt.Key_Back || event.key === Qt.Key_Escape) {
            cancelKeyboard()
            event.accepted = true
        }
    }

    Keys.onReleased: {
        if (!opened)
            return

        if (_isActivationKey(event.key) && _shiftHoldPending) {
            // Un vrai release arrête uniquement le timer de maintien.
            // La fenêtre candidate reste brièvement ouverte pour les firmwares
            // qui découpent un maintien en plusieurs press/release.
            shiftHoldTimer.stop()
            _shiftHoldPending = false
            event.accepted = true
        }
    }

    onOpenedChanged: {
        if (opened)
            Qt.callLater(function() { root.forceActiveFocus() })
    }

    Timer {
        id: shiftHoldTimer
        interval: 500
        repeat: false
        onTriggered: {
            if (root._shiftHoldPending && !root.capsLock) {
                root._shiftLongActivated = true
                root._shiftLockCandidate = false
                root._shiftHoldPending = false
                shiftCandidateTimer.stop()
                root._activateCapsLock()
            }
        }
    }

    Timer {
        id: shiftCandidateTimer
        interval: 900
        repeat: false
        onTriggered: {
            root._shiftLockCandidate = false
            root._shiftLongActivated = false
        }
    }

    Timer {
        id: pressReleaseTimer
        interval: 90
        repeat: false
        onTriggered: {
            root.pressedZone = ""
            root.pressedRow = -1
            root.pressedColumn = -1
        }
    }

    // ------------------------------------------------------------------
    // Présentation OLED compacte
    // ------------------------------------------------------------------

    Rectangle {
        anchors.fill: parent
        color: "#26000000"
    }

    Rectangle {
        id: keyboardPanel

        width: Math.max(760, Math.min(parent.width - 24,
                                      parent.width * root.panelWidthRatio))
        height: Math.max(260, Math.min(parent.height - 24,
                                       parent.height * root.panelHeightRatio))

        x: Math.round((parent.width - width) / 2)
        y: root.opened
           ? parent.height - height - root.panelBottomMargin
           : parent.height + 12

        radius: 15
        color: root.panelColor
        border.width: 1
        border.color: root.subtleBorderColor
        antialiasing: true

        Behavior on y {
            NumberAnimation {
                duration: 185
                easing.type: Easing.OutCubic
            }
        }

        // Zone principale : environ 78 %.
        Item {
            id: mainArea
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.leftMargin: 12
            anchors.topMargin: 12
            anchors.bottomMargin: 12
            width: parent.width * 0.775

            Column {
                anchors.fill: parent
                spacing: root.rowSpacing

                property real rowHeight:
                    (height - root.rowSpacing * 3) / 4.0

                Repeater {
                    model: root.mainRows

                    delegate: Item {
                        id: rowHolder
                        width: mainArea.width
                        height: parent.rowHeight

                        property int keyboardRow: index
                        property var rowData: modelData

                        Row {
                            anchors.fill: parent
                            spacing: root.keySpacing

                            Repeater {
                                model: rowHolder.rowData

                                delegate: Rectangle {
                                    id: keyRect

                                    property int keyboardColumn: index
                                    property var keyData: modelData
                                    property real widthFactor: {
                                        var n = Number(keyData.widthFactor)
                                        return isFinite(n) && !isNaN(n) && n > 0 ? n : 1.0
                                    }
                                    property bool selected:
                                        root.selectedZone === "main"
                                        && root.selectedRow === rowHolder.keyboardRow
                                        && root.selectedColumn === keyboardColumn
                                    property bool pressed:
                                        root.pressedZone === "main"
                                        && root.pressedRow === rowHolder.keyboardRow
                                        && root.pressedColumn === keyboardColumn
                                    property bool action:
                                        keyData.actionKey === true
                                        || keyData.action !== undefined

                                    property bool lockedShift:
                                        String(keyData.action || "") === "shift"
                                        && root.capsLock

                                    width: root._keyBaseWidth(rowHolder.rowData,
                                                             rowHolder.width,
                                                             root.keySpacing)
                                           * widthFactor
                                    height: rowHolder.height
                                    radius: 8
                                    antialiasing: true
                                    transformOrigin: Item.Center
                                    z: selected ? 20 : 1

                                    color: pressed
                                           ? root.pressedKeyColor
                                           : action
                                             ? root.actionKeyColor
                                             : root.keyColor

                                    border.width: (selected || lockedShift)
                                                  ? 2 : (action ? 1 : 0)
                                    border.color: (selected || lockedShift)
                                                  ? "#FFFFFFFF"
                                                  : root.subtleBorderColor

                                    scale: pressed ? 0.97 : 1.0

                                    Behavior on scale {
                                        NumberAnimation {
                                            duration: 85
                                            easing.type: Easing.OutQuad
                                        }
                                    }

                                    // Anneau de focus blanc : apparition courte,
                                    // sans animation permanente ni effet GPU lourd.
                                    Rectangle {
                                        z: 2
                                        x: -3
                                        y: -3
                                        width: parent.width + 6
                                        height: parent.height + 6
                                        radius: parent.radius + 3
                                        color: "transparent"
                                        border.width: 2
                                        border.color: "#FFFFFFFF"
                                        opacity: keyRect.selected ? 1.0 : 0.0
                                        scale: keyRect.selected ? 1.0 : 0.92
                                        antialiasing: true

                                        Behavior on opacity {
                                            NumberAnimation {
                                                duration: 105
                                                easing.type: Easing.OutQuad
                                            }
                                        }
                                        Behavior on scale {
                                            NumberAnimation {
                                                duration: 145
                                                easing.type: Easing.OutCubic
                                            }
                                        }
                                    }

                                    Text {
                                        id: keyLabel
                                        z: 3
                                        anchors.centerIn: parent
                                        width: parent.width - 8
                                        scale: keyRect.selected ? 1.32 : 1.0
                                        transformOrigin: Item.Center

                                        Behavior on scale {
                                            NumberAnimation {
                                                duration: 145
                                                easing.type: Easing.OutBack
                                                easing.overshoot: 1.12
                                            }
                                        }
                                        text: String(keyRect.keyData.label || "")
                                        color: keyRect.selected
                                               ? "#FFFFFFFF"
                                               : root.textColor
                                        font.pixelSize:
                                            Math.max(13,
                                                     Math.min(20,
                                                              keyboardPanel.height * 0.065))
                                        font.weight: keyRect.selected
                                                     ? Font.Bold
                                                     : (keyRect.action
                                                        ? Font.DemiBold
                                                        : Font.Normal)
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                        elide: Text.ElideRight
                                        textFormat: Text.PlainText
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            id: separator
            width: 1
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: 14
            anchors.bottomMargin: 14
            anchors.left: mainArea.right
            anchors.leftMargin: 10
            color: "#FF1E2026"
        }

        // Pavé numérique permanent : 3 colonnes x 4 rangées.
        Item {
            id: numberArea
            anchors.left: separator.right
            anchors.leftMargin: 10
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.top: parent.top
            anchors.topMargin: 12
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12

            Column {
                anchors.fill: parent
                spacing: root.rowSpacing

                property real rowHeight:
                    (height - root.rowSpacing * 3) / 4.0

                Repeater {
                    model: root.numberRows

                    delegate: Item {
                        id: numberRowHolder
                        width: numberArea.width
                        height: parent.rowHeight

                        property int keyboardRow: index
                        property var rowData: modelData

                        Row {
                            anchors.fill: parent
                            spacing: root.keySpacing

                            Repeater {
                                model: numberRowHolder.rowData

                                delegate: Rectangle {
                                    id: numberKey

                                    property int keyboardColumn: index
                                    property var keyData: modelData
                                    property bool selected:
                                        root.selectedZone === "num"
                                        && root.selectedRow === numberRowHolder.keyboardRow
                                        && root.selectedColumn === keyboardColumn
                                    property bool pressed:
                                        root.pressedZone === "num"
                                        && root.pressedRow === numberRowHolder.keyboardRow
                                        && root.pressedColumn === keyboardColumn
                                    property bool action:
                                        keyData.actionKey === true
                                        || keyData.action !== undefined

                                    width: (numberRowHolder.width
                                            - root.keySpacing * 2) / 3.0
                                    height: numberRowHolder.height
                                    radius: 8
                                    antialiasing: true
                                    transformOrigin: Item.Center
                                    z: selected ? 20 : 1

                                    color: pressed
                                           ? root.pressedKeyColor
                                           : action
                                             ? root.actionKeyColor
                                             : root.keyColor

                                    border.width: selected ? 2 : (action ? 1 : 0)
                                    border.color: selected
                                                  ? root.accentColor
                                                  : root.subtleBorderColor

                                    scale: pressed ? 0.97 : 1.0

                                    Behavior on scale {
                                        NumberAnimation {
                                            duration: 85
                                            easing.type: Easing.OutQuad
                                        }
                                    }

                                    Rectangle {
                                        z: 2
                                        x: -3
                                        y: -3
                                        width: parent.width + 6
                                        height: parent.height + 6
                                        radius: parent.radius + 3
                                        color: "transparent"
                                        border.width: 2
                                        border.color: "#FFFFFFFF"
                                        opacity: numberKey.selected ? 1.0 : 0.0
                                        scale: numberKey.selected ? 1.0 : 0.92
                                        antialiasing: true

                                        Behavior on opacity {
                                            NumberAnimation {
                                                duration: 105
                                                easing.type: Easing.OutQuad
                                            }
                                        }
                                        Behavior on scale {
                                            NumberAnimation {
                                                duration: 145
                                                easing.type: Easing.OutCubic
                                            }
                                        }
                                    }

                                    Text {
                                        id: numberLabel
                                        z: 3
                                        anchors.centerIn: parent
                                        scale: numberKey.selected ? 1.32 : 1.0
                                        transformOrigin: Item.Center

                                        Behavior on scale {
                                            NumberAnimation {
                                                duration: 145
                                                easing.type: Easing.OutBack
                                                easing.overshoot: 1.12
                                            }
                                        }

                                        text: String(numberKey.keyData.label || "")
                                        color: numberKey.selected
                                               ? "#FFFFFFFF"
                                               : root.textColor
                                        font.pixelSize:
                                            Math.max(14,
                                                     Math.min(21,
                                                              keyboardPanel.height * 0.068))
                                        font.weight: numberKey.selected
                                                     ? Font.Bold
                                                     : (numberKey.action
                                                        ? Font.DemiBold
                                                        : Font.Normal)
                                        textFormat: Text.PlainText
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    function _rowUnits(rowData) {
        if (!rowData || !rowData.length)
            return 1

        var total = 0
        for (var i = 0; i < rowData.length; ++i) {
            var factor = Number(rowData[i].widthFactor)
            if (!isFinite(factor) || isNaN(factor) || factor <= 0)
                factor = 1
            total += factor
        }
        return Math.max(1, total)
    }

    function _keyBaseWidth(rowData, rowWidth, spacing) {
        if (!rowData || !rowData.length)
            return rowWidth
        var spaces = Math.max(0, rowData.length - 1) * spacing
        return Math.max(1, rowWidth - spaces) / _rowUnits(rowData)
    }
}
