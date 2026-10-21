.pragma library

// Keyboard editing for read-only text fields.
//
// WHY EVERY EDITABLE FIELD IN THIS PLUGIN IS `readOnly: true` AND DRIVEN FROM
// HERE:
//
// Panel.qml is mounted for the shell's whole lifetime by BarWidget.qml:
//
//     Loader { id: panelLoader; active: true; source: Qt.resolvedUrl("Panel.qml"); visible: false }
//
// `visible: false` does not unload it, so every text field in it is a live
// QQuickTextInput -- and Qt connects EVERY TextInput to the clipboard in its
// constructor, unconditionally:
//
//     qmlobject_connect(QGuiApplication::clipboard(), QClipboard,
//         SIGNAL(dataChanged()), q, QQuickTextInput, SLOT(q_canPasteChanged()));
//
// The slot re-evaluates canPaste, and up to Qt 6.12 that means calling
// mimeData()->text(). On Wayland, under a clipboard owned by another client,
// that is a wl_data_offer.receive followed by a blocking read of the pipe --
// up to a second, on the GUI thread, per live field, per clipboard-owner
// change, with no paste and no focus involved. `hasText()` alone only reads
// the format list the compositor already delivered; it is the `.text()` that
// makes it a transfer.
//
// The read is gated on `!m_readOnly`, so a field that is read-only CLOSED and
// editable OPEN still transfers foreign clipboard text for as long as the
// panel is open. Gating on "the panel is closed" is therefore not enough:
// the gate has to stay shut. Hence: `readOnly: true` always, and the editing
// is done here, where it can be bounded.
//
// A read-only TextField still reports cursorPosition, selectionStart and
// selectionEnd, and its `text` is still assignable -- so the editing below
// works on it without the native editing path ever running.
//
// What this costs, stated plainly: no native IME, no middle-click paste, and
// no text selection of the native kind. For a handful of single-line settings
// values, that is the right trade.

/**
 * Feed one key event to `field`. Returns true when this engine consumed it,
 * so a site's own `Keys.onPressed` can skip its branches for those keys.
 * Everything unconsumed is left exactly as Qt handles it.
 */
function handle(field, event) {
    if (!field || !event)
        return false;

    if (event.modifiers & Qt.ControlModifier) {
        // Ctrl+A/C/V/X stay with Qt: selection works under readOnly, and
        // cut() would put text on the clipboard, which is the opposite of
        // what this exists to do. Only the word-delete is re-implemented.
        if (event.key === Qt.Key_Backspace) {
            deleteWordBackward(field);
            event.accepted = true;
            return true;
        }
        return false;
    }

    if (event.key === Qt.Key_Backspace) {
        backward(field);
        event.accepted = true;
        return true;
    }
    if (event.key === Qt.Key_Delete) {
        forward(field);
        event.accepted = true;
        return true;
    }

    if (event.text && event.text.length > 0) {
        // Printable input only. Key names carry an empty text, and control
        // characters never belong in a settings value.
        var code = event.text.charCodeAt(0);
        if (code >= 32 && code !== 127) {
            insert(field, event.text);
            event.accepted = true;
            return true;
        }
    }
    return false;
}

/** Characters a field will accept, as a regex source. Empty = any printable. */
function allowed(field) {
    return field.entryChars ? String(field.entryChars) : "";
}

function cap(field) {
    var n = Number(field.maximumLength);
    return (n && n > 0) ? n : 4096;
}

function caret(field) {
    var p = Number(field.cursorPosition);
    if (!isFinite(p))
        p = field.text.length;
    return Math.max(0, Math.min(field.text.length, p));
}

/** Selection bounds, or -1/-1 when nothing is selected. Readable under readOnly. */
function selection(field) {
    var s = Number(field.selectionStart);
    var e = Number(field.selectionEnd);
    if (!isFinite(s) || !isFinite(e) || e <= s)
        return { start: -1, end: -1 };
    return { start: Math.max(0, Math.min(field.text.length, s)),
             end: Math.max(0, Math.min(field.text.length, e)) };
}

function collapse(field, at) {
    field.select(at, at);
    field.cursorPosition = at;
}

function insert(field, str) {
    var allow = allowed(field);
    if (allow.length > 0 && !new RegExp(allow).test(str))
        return;
    var sel = selection(field);
    if (sel.start >= 0) {
        // Typing over a selection replaces it, the way any editor does.
        var t = field.text.substring(0, sel.start) + str + field.text.substring(sel.end);
        if (t.length > cap(field))
            return;
        field.text = t;
        collapse(field, sel.start + str.length);
        return;
    }
    if (field.text.length + str.length > cap(field))
        return;
    var p = caret(field);
    field.text = field.text.substring(0, p) + str + field.text.substring(p);
    field.cursorPosition = p + str.length;
}

function backward(field) {
    var sel = selection(field);
    if (sel.start >= 0) {
        field.text = field.text.substring(0, sel.start) + field.text.substring(sel.end);
        collapse(field, sel.start);
        return;
    }
    var p = caret(field);
    if (p <= 0)
        return;
    field.text = field.text.substring(0, p - 1) + field.text.substring(p);
    field.cursorPosition = p - 1;
}

function forward(field) {
    var sel = selection(field);
    if (sel.start >= 0) {
        field.text = field.text.substring(0, sel.start) + field.text.substring(sel.end);
        collapse(field, sel.start);
        return;
    }
    var p = caret(field);
    if (p >= field.text.length)
        return;
    field.text = field.text.substring(0, p) + field.text.substring(p + 1);
    field.cursorPosition = p;
}

/** Delete back to the previous word boundary, like Ctrl+Backspace in any editor. */
function deleteWordBackward(field) {
    var t = field.text;
    var p = caret(field);
    if (p <= 0)
        return;
    var i = p;
    while (i > 0 && /\s/.test(t.charAt(i - 1)))
        i -= 1;
    while (i > 0 && !/\s/.test(t.charAt(i - 1)))
        i -= 1;
    if (i === p)
        i = Math.max(0, p - 1);
    field.text = t.substring(0, i) + t.substring(p);
    field.cursorPosition = i;
}

/** Replace the whole value, leaving the caret at its end. */
function clear(field) {
    field.text = "";
    field.cursorPosition = 0;
}
