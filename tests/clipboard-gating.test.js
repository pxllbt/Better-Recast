// A native text field is not inert, and in a permanently loaded panel it is
// not even optional.
//
// Panel.qml is loaded for the whole life of the shell -- BarWidget mounts it
// through `Loader { active: true; visible: false }`, so the panel exists while
// the popup is closed. That means its editable text inputs are live C++
// objects, and Qt does not leave them alone.
//
// QQuickTextInputPrivate::init() connects every TextInput to the clipboard:
//
//     qmlobject_connect(QGuiApplication::clipboard(), QClipboard,
//         SIGNAL(dataChanged()), q, QQuickTextInput, SLOT(q_canPasteChanged()));
//
// Unconditionally, in the constructor, whether or not any QML ever binds
// `canPaste` -- this plugin never does. The slot re-evaluates canPaste, and in
// Qt <= 6.12 that means calling mimeData()->text():
//
//     if (const QMimeData *mimeData = QGuiApplication::clipboard()->mimeData())
//         canPaste = mimeData->hasText() && !mimeData->text().isEmpty();
//
// Under Wayland with a clipboard owned by another client, that text() lands in
// QWaylandMimeData::retrieveData_sys(), which writes a wl_data_offer.receive to
// the foreign owner and then blocks reading the pipe --
//
//     m_dataOffer->startReceiving(mime, pipefd[1]);
//     ...
//     readData(pipefd[0], content)   // qt_safe_poll(..., QDeadlineTimer(1s))
//
// up to a second, on the GUI thread, per live field, per clipboard-owner
// change, with no paste and no focus involved. `hasText()` on its own only
// reads the format list that the compositor already delivered; it is the
// `.text()` that makes it a transfer.
//
// THE GATE, AND WHY GATING ON "THE PANEL IS CLOSED" IS NOT ENOUGH.
//
// `readOnly` is the lever that works, because both canPaste and
// q_canPasteChanged early-out on it:
//
//     if (!d->m_readOnly) { ...clipboard... }
//
// But the gate has to be RELEASED for the field to be editable, and the moment
// it is released the clipboard read happens again. A field that is read-only
// while the panel is closed and editable while it is open is therefore an
// unbounded, deadline-free transfer of foreign clipboard text for as long as
// somebody is typing in it -- and the panel is open exactly when somebody is
// typing in it.
//
// So the gate does not open. Every native field is `readOnly: true`
// PERMANENTLY, and the editing is driven from `TextEntry.js`, which writes
// the field's text itself. A read-only TextField still reports
// cursorPosition, selectionStart and selectionEnd, and its `text` is still
// assignable -- so the editing works without the native editing path ever
// running, and without the clipboard ever being read.
//
// What this costs, stated plainly: no native IME, no middle-click paste, and
// no native text selection. For a handful of single-line settings values,
// that is the right trade.
//
// Run from the plugin root:  node tests/clipboard-gating.test.js
const fs = require("fs");
const assert = require("node:assert/strict");

// The files that are instantiated for the shell's whole lifetime.
const QML = ["Panel.qml", "BarWidget.qml", "Service.qml"];

// Pull out whole `Type { ... }` blocks by brace matching, so a gate can only be
// credited to the field it actually belongs to.
function blocks(source, type) {
    const out = [];
    const lines = source.split("\n");
    lines.forEach((line, i) => {
        if (!new RegExp(`\\b${type}\\s*\\{`).test(line)) return;
        let depth = 0;
        let start = -1;
        for (let j = i; j < lines.length; j++) {
            const opens = (lines[j].match(/\{/g) || []).length;
            const closes = (lines[j].match(/\}/g) || []).length;
            if (start < 0 && opens > 0) start = j;
            depth += opens - closes;
            if (depth <= 0 && start >= 0) {
                out.push({ name: `${type} at line ${i + 1}`, body: lines.slice(start, j + 1).join("\n") });
                return;
            }
        }
        out.push({ name: `${type} at line ${i + 1}`, body: lines.slice(i).join("\n") });
    });
    return out;
}

const ungated = [];
const opens = [];
let gated = 0;

for (const file of QML) {
    if (!fs.existsSync(file)) continue;
    const source = fs.readFileSync(file, "utf8");

    for (const type of ["TextField", "TextInput", "TextArea"]) {
        for (const field of blocks(source, type)) {
            if (/readOnly\s*:\s*true/.test(field.body)) {
                gated++;
            } else {
                ungated.push(`${file}: ${field.name} has no permanent readOnly gate`);
            }
            // A CONDITIONAL gate is the failure this whole file exists for:
            // `readOnly: !root.opened` closes while the panel is shut and
            // reopens the clipboard read the moment the user types.
            if (/readOnly\s*:\s*!/.test(field.body)) {
                opens.push(`${file}: ${field.name} is read-only only while closed`);
            }
        }
    }
}

assert.equal(ungated.length, 0, "native text inputs without a permanent readOnly gate: " + ungated.join("; "));
assert.equal(
    opens.length,
    0,
    "a readOnly gate that opens reopens the clipboard read: " + opens.join("; ")
);
assert(gated >= 1, `expected at least one gated field, found ${gated}`);

// The gate must be permanent, not a constant that merely looks like one: the
// old `readOnly: !root.opened` shape is exactly what this file forbids.
const panel = fs.readFileSync("Panel.qml", "utf8");
assert(
    /readOnly:\s*true/.test(panel),
    "the panel's fields are permanently read-only"
);
assert(
    !/readOnly:\s*!/.test(panel),
    "the panel has no readOnly gate that reopens while the panel is open"
);

// The panel must still be able to take text. A fix that simply removed the
// fields would pass the checks above and break the feature -- so the editing
// has to be driven from the shared engine.
assert(
    /TextEntry\.handle\(/.test(panel),
    "the panel's fields are edited through TextEntry, not by the native path"
);
assert(
    /onEditingFinished/.test(panel),
    "the panel still commits the edited value"
);

// The engine the panel leans on has to exist and be a real library.
const engine = fs.readFileSync("TextEntry.js", "utf8");
assert(/pragma\s+library/.test(engine), "TextEntry.js is a QML library");
assert(/function\s+handle\s*\(/.test(engine), "TextEntry.js exports handle()");
assert(/function\s+insert\s*\(/.test(engine), "TextEntry.js exports insert()");

// Sanity: the panel really is permanently instantiated while closed. If that
// Loader ever becomes lazy this file becomes belt-and-braces, not load-bearing.
const bar = fs.readFileSync("BarWidget.qml", "utf8");
const loader = bar.slice(bar.indexOf("Loader {"), bar.indexOf("Loader {") + 200);
assert(/active:\s*true/.test(loader), "the panel Loader is active: true (always instantiated)");

console.log("ok - every native text field is permanently read-only, so Qt never queries the clipboard");
