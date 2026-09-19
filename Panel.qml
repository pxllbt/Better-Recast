import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Config.js" as Config

// pix.recast control panel — the settings popup anchored to the bar widget
// (right click) or `omarchy-shell shell summon pix.recast`. Reads recording state
// and config off the pix.recast service; writes settings through service.setConfig.
// Two modes share one optimized encode pipeline:
//   record  — regular screen recording (the "Better Recast")
//   stream  — RTMP live streaming to TikTok/Twitch/YouTube/any platform
//
// Extends qs.Ui Panel so the bar's popout contract (opened/open/close/toggle/
// closeForPopoutSwitch) comes from the shared base; the popup window is a
// KeyboardPanel anchored to the bar button.
Panel {
    id: root

    moduleName: "pix.recast"
    ipcTarget: "pix.recast"
    manageIpc: false

    // ---- host injections ----------------------------------------------------
    property var shell: null
    property var manifest: null
    property var service: null
    property var serviceState: ({})
    // Optimistic override for config keys set while the service is unreachable.
    // Cleared when the state file is next polled and confirms the change.
    property var _pendingConfig: ({})
    // Only clear pending config when the state file has caught up to our
    // optimistic change — otherwise the UI flickers back between the
    // optimistic update and the 2 s poll interval.
    function _clearPendingIfConfirmed() {
        if (!root.serviceState || !root.serviceState.config)
            return;
        var allConfirmed = true;
        for (var k in root._pendingConfig) {
            if (root.serviceState.config[k] !== root._pendingConfig[k]) {
                allConfirmed = false;
                break;
            }
        }
        if (allConfirmed)
            root._pendingConfig = ({});
    }
    // Error message: pulled from the live service, the state file, or set
    // locally for fallback-path errors (e.g. region picker cancelled).
    property string _localError: ""
    readonly property string errorMessage: root.service
        ? (root.service.errorMessage || "")
        : (root.serviceState
            ? (root.serviceState.errorMessage || root._localError || "")
            : root._localError)
    property var anchorItem: null
    property var hostWidget: null
    property string omarchyPath: ""

    // ---- theme --------------------------------------------------------------
    readonly property color foreground: Color.foreground
    readonly property color background: Color.background
    readonly property color accent: Color.accent
    readonly property color muted: Color.muted
    readonly property color urgent: Color.urgent
    readonly property string fontFamily: Style.font.family

    // Effective config: live service config → state file config (with optimistic
    // overrides) → settings → defaults
    // Using a mutable property allows us to force re-evaluation via the
    // handlers below, working around Qt 6's QML engine not always
    // re-evaluating complex readonly property var bindings.
    property var cfg: root._computeCfg()

    function _computeCfg() {
        if (root.service && root.service.config)
            return root.service.config;
        var base = {};
        if (root.serviceState && root.serviceState.config)
            base = root.serviceState.config;
        if (root.settings && typeof root.settings === "object")
            base = Object.assign({}, base, root.settings);
        if (Object.keys(base).length === 0)
            base = Config.defaultConfig();
        if (Object.keys(root._pendingConfig).length > 0) {
            var merged = Object.assign({}, base);
            for (var k in root._pendingConfig)
                merged[k] = root._pendingConfig[k];
            return merged;
        }
        return base;
    }

    onServiceChanged: {
        root.cfg = root._computeCfg();
    }
    onSettingsChanged: {
        root.cfg = root._computeCfg();
    }
    onServiceStateChanged: {
        root._clearPendingIfConfirmed();
        root.cfg = root._computeCfg();
    }

    Connections {
        target: root.service
        ignoreUnknownSignals: true
        onConfigChanged: {
            root.cfg = root._computeCfg();
        }
    }

    // GPU info: live service → state file → defaults
    readonly property var gpu: root.service
        ? (root.service.gpuInfo || {})
        : (root.serviceState && root.serviceState.gpuInfo
            ? root.serviceState.gpuInfo
            : { vendor: "unknown", codecs: [] })
    readonly property string state: root.service
        ? (root.service.recordingState || root.service.state || "idle")
        : (root.serviceState && (root.serviceState.recordingState || root.serviceState.state) || "idle")
    readonly property bool recording: state === "recording" || state === "paused"
    readonly property bool paused: state === "paused"
    readonly property bool busy: state === "starting" || state === "stopping"
    readonly property bool isStream: root.service && root.service.config
        ? root.service.config.mode === "stream"
        : (root.cfg && root.cfg.mode === "stream")

    function formatElapsed(sec) {
        var h = Math.floor(sec / 3600);
        var m = Math.floor((sec % 3600) / 60);
        var s = sec % 60;
        var pad = function (n) {
            return n < 10 ? "0" + n : String(n);
        };
        return (h > 0 ? pad(h) + ":" : "") + pad(m) + ":" + pad(s);
    }

    function stateLabel() {
        if (state === "recording") {
            var kind = root.isStream ? "LIVE" : "REC";
            var elapsed = root.service ? (root.service.recordingElapsed || 0) : (root.serviceState.recordingElapsed || 0);
            return kind + " " + formatElapsed(elapsed);
        }
        if (state === "paused") {
            var elapsed2 = root.service ? (root.service.recordingElapsed || 0) : (root.serviceState.recordingElapsed || 0);
            return "PAUSED " + formatElapsed(elapsed2);
        }
        if (state === "starting")
            return "STARTING…";
        if (state === "stopping")
            return "STOPPING…";
        if (state === "error")
            return "ERROR";
        return root.isStream ? "Ready to go live" : "Idle";
    }

    function targetLabel() {
        var mode = root.cfg.targetMode || "portal";
        if (mode === "monitor")
            return root.cfg.monitorName || root.cfg._lastMonitor || "Monitor";
        if (mode === "region")
            return root.cfg._lastRegion || "Pick region";
        return "Portal / window";
    }

    function platformLabel() {
        var def = Config.streamPlatformDefaults(root.cfg.streamPlatform || "custom");
        return def.label;
    }

    function effectiveEncoder() {
        if (root.service && root.service.config && root.service.config.encoder) {
            return root.service.config.encoder;
        }
        if (root.serviceState && root.serviceState.config && root.serviceState.config.encoder)
            return root.serviceState.config.encoder;
        var eff = Config.applyGpuProfile(root.cfg, root.gpu);
        return eff.encoder || "gpu";
    }

    function effectiveCodec() {
        if (root.isStream)
            return "h264";
        if (root.service && root.service.config && root.service.config.codec && root.service.config.codec !== "auto") {
            return root.service.config.codec;
        }
        if (root.serviceState && root.serviceState.config && root.serviceState.config.codec && root.serviceState.config.codec !== "auto")
            return root.serviceState.config.codec;
        var eff = Config.applyGpuProfile(root.cfg, root.gpu);
        return eff.codec || "h264";
    }

    function effectiveQuality() {
        if (root.isStream)
            return String(root.cfg.streamKbps || 6000) + " kbps";
        if (root.service && root.service.config && root.service.config.quality && root.service.config.quality !== "auto") {
            return root.service.config.quality;
        }
        if (root.serviceState && root.serviceState.config && root.serviceState.config.quality && root.serviceState.config.quality !== "auto")
            return root.serviceState.config.quality;
        var eff = Config.applyGpuProfile(root.cfg, root.gpu);
        return eff.quality || "very_high";
    }

    function effectiveBitrate() {
        if (root.isStream)
            return "CBR";
        var eff = Config.applyGpuProfile(root.cfg, root.gpu);
        return eff.bitrateMode || "vbr";
    }

    function monitorOptions() {
        var list = [];
        var ms = root.service ? (root.service.monitors || [])
            : (root.serviceState ? (root.serviceState.monitors || []) : []);
        for (var i = 0; i < ms.length; i++) {
            list.push({
                value: ms[i].name,
                label: ms[i].name + " (" + ms[i].resolution + ")"
            });
        }
        return list;
    }

    function setConfig(key, value) {
        if (root.service && typeof root.service.setConfig === "function") {
            root.service.setConfig(key, value);
            return;
        }
        // Try the bar shell's updateEntryInline — this only works for the
        // built-in omarchy.bar because the scoped PluginShellApi resolves the
        // service and writes to shell.json directly. For replacement bars
        // (px.bar) the scoped API exists but updateEntryInline silently
        // returns false because it only accepts the bar widget's own plugin ID.
        if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
            var entry = { id: "pix.recast" };
            var cfg = root.cfg || Config.defaultConfig();
            for (var k in cfg)
                if (k !== "id")
                    entry[k] = cfg[k];
            entry[key] = value;
            if (root.bar.shell.updateEntryInline("pix.recast", entry))
                return;
        }
        // IPC fallback for replacement bars (px.bar): no service access,
        // so write the config change into the state file via IPC.
        configIpcProc.running = false;
        configIpcProc.command = ["omarchy-shell", "px-recast", "config", key, String(value)];
        configIpcProc.running = true;
        // Optimistically update local state so the UI responds immediately.
        var next = Object.assign({}, root._pendingConfig);
        next[key] = value;
        root._pendingConfig = next;
    }

    // Stream URL/key are session-only unless "remember" is on, so the key never
    // lands in shell.json by default.
    function setStreamField(key, value) {
        if (root.service) {
            if (root.cfg.streamRemember === true)
                root.service.setConfig(key, value);
            else if (typeof root.service.setSessionConfig === "function")
                root.service.setSessionConfig(key, value);
            else if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
                var entry = { id: "pix.recast" };
                for (var k in root.settings)
                    if (k !== "id") entry[k] = root.settings[k];
                entry[key] = value;
                root.bar.shell.updateEntryInline("pix.recast", entry);
            }
            else
                root.service.setConfig(key, value);
        } else if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
            var entry = {
                id: "pix.recast"
            };
            for (var k in root.settings)
                if (k !== "id")
                    entry[k] = root.settings[k];
            entry[key] = value;
            root.bar.shell.updateEntryInline("pix.recast", entry);
        }
    }

    function platformOptions() {
        return [
            {
                value: "tiktok",
                label: "TikTok Live"
            },
            {
                value: "twitch",
                label: "Twitch"
            },
            {
                value: "youtube",
                label: "YouTube"
            },
            {
                value: "custom",
                label: "Custom / Other"
            }
        ];
    }

    // Apply gsr's recommended encode profile for the chosen platform. Resolution
    // is only suggested when the user hasn't pinned their own.
    function applyPlatformDefaults(platform) {
        var def = Config.streamPlatformDefaults(platform);
        var hadResolution = root.cfg.resolution && root.cfg.resolution !== "";
        root.setConfig("streamPlatform", platform);
        root.setConfig("streamKbps", def.kbps);
        root.setConfig("fps", def.fps);
        if (!hadResolution)
            root.setConfig("resolution", def.resolution);
    }

    function toggleRecording() {
        if (root.service && typeof root.service.toggle === "function") {
            root.service.toggle();
        } else {
            toggleIpcAction.command = ["omarchy-shell", "px-recast", "toggle"];
            toggleIpcAction.running = true;
        }
    }

    function pauseRecording() {
        if (root.service && typeof root.service.pause === "function") {
            root.service.pause();
        } else {
            ipcActionProc.command = ["omarchy-shell", "px-recast", "pause"];
            ipcActionProc.running = true;
        }
    }

    function resumeRecording() {
        if (root.service && typeof root.service.resume === "function") {
            root.service.resume();
        } else {
            ipcActionProc.command = ["omarchy-shell", "px-recast", "resume"];
            ipcActionProc.running = true;
        }
    }

    // Popup is driven by the qs.Ui Panel base: open()/close()/toggle()/opened
    // come from the PanelController, closeForPopoutSwitch() keeps the card
    // visible while the bar hands the popout over to another panel, and
    // KeyboardPanel shows it anchored to the bar button.
    function open() {
        root.controller.show();
        if (root.service && typeof root.service.refreshGpuInfo === "function")
            root.service.refreshGpuInfo();
    }

    function requestClose() {
        root.close();
    }

    // ---- popup window -------------------------------------------------------
    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        bar: root.bar
        owner: root.hostWidget || root
        focusTarget: keyCatcher
        open: root.opened
        centerOnBar: false
        contentWidth: panel.fittedContentWidth(Style.space(400))
        contentHeight: panel.fittedContentHeight(Style.space(440))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.requestClose()
            onActivateRequested: root.toggleRecording()

            ScrollView {
                anchors.fill: parent
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ScrollBar.vertical.policy: contentColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

                Column {
                    id: contentColumn
                    width: parent.width
                    spacing: Style.space(12)

                    // ---- Header: title + live state ------------------------------------
                    RowLayout {
                        width: parent.width
                        spacing: Style.space(10)

                        Text {
                            text: "Better Recast"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                            font.bold: true
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }

                        Text {
                            text: root.stateLabel()
                            color: {
                                if (root.state === "recording")
                                    return root.isStream ? root.urgent : root.accent;
                                if (root.state === "error")
                                    return root.urgent;
                                return root.muted;
                            }
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
                        }
                    }

                    // ---- Mode toggle (record / stream) ----------------------------------
                    RowLayout {
                        width: parent.width
                        spacing: Style.space(8)

                        Button {
                            text: "Record"
                            Layout.fillWidth: true
                            selected: !root.isStream
                            foreground: root.foreground
                            accent: root.accent
                            fontFamily: root.fontFamily
                            fontSize: Style.font.body
                            onClicked: {
                                if (root.isStream)
                                    root.setConfig("mode", "record");
                            }
                        }

                        Button {
                            text: "Stream"
                            Layout.fillWidth: true
                            selected: root.isStream
                            foreground: root.foreground
                            accent: root.accent
                            fontFamily: root.fontFamily
                            fontSize: Style.font.body
                            onClicked: {
                                if (!root.isStream)
                                    root.setConfig("mode", "stream");
                            }
                        }
                    }

                    // ---- Primary action button ------------------------------------------
                    Button {
                        width: parent.width
                        height: Style.spacing.controlHeight * 1.4
                        foreground: root.foreground
                        accent: root.accent
                        fontFamily: root.fontFamily
                        fontSize: Style.font.title
                        text: {
                            if (root.busy)
                                return root.state === "starting" ? "Starting…" : "Stopping…";
                            if (root.recording)
                                return root.paused ? "▶  Resume" : (root.isStream ? "■  Stop stream" : "■  Stop");
                            return root.isStream ? "●  Go live" : "●  Record";
                        }
                        onClicked: root.toggleRecording()
                    }

                    Row {
                        width: parent.width
                        spacing: Style.space(8)
                        visible: root.recording && !root.isStream

                        Button {
                            id: pauseButton
                            text: root.paused ? "Resume" : "Pause"
                            onClicked: {
                                if (root.paused)
                                    root.resumeRecording();
                                else
                                    root.pauseRecording();
                            }
                        }

                        Text {
                            text: (root.service && root.service.recordingFile) ? "Saving to:\n" + root.service.recordingFile
                                : (root.serviceState && root.serviceState.recordingFile ? "Saving to:\n" + root.serviceState.recordingFile : "")
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - pauseButton.width - Style.space(8)
                            wrapMode: Text.WordWrap
                        }
                    }

                    Text {
                        visible: root.recording && root.isStream
                        text: "Streaming to " + root.platformLabel() + " · " + String(root.cfg.streamKbps || 6000) + " kbps CBR"
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        width: parent.width
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        visible: !root.recording && root.isStream && (!root.cfg.streamUrl || !root.cfg.streamKey)
                        text: "Set a stream URL and key below, then press Go live."
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        width: parent.width
                        wrapMode: Text.WordWrap
                    }

                    Text {
                visible: root.state === "error" && root.errorMessage.length > 0
                text: "Error: " + root.errorMessage
                        color: root.urgent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }

                    PanelSeparator {
                        foreground: root.foreground
                    }

                    // ---- Capture target --------------------------------------------------
                    Column {
                        width: parent.width
                        spacing: Style.space(8)

                        PanelSectionHeader {
                            text: "CAPTURE"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        GridLayout {
                            width: parent.width
                            columns: 2
                            columnSpacing: Style.space(10)
                            rowSpacing: Style.space(8)

                            Text {
                                text: "Target"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Dropdown {
                                id: targetDropdown
                                label: ""
                                value: root.cfg.targetMode || "portal"
                                options: [
                                    {
                                        value: "portal",
                                        label: "Window / portal"
                                    },
                                    {
                                        value: "monitor",
                                        label: "Monitor"
                                    },
                                    {
                                        value: "region",
                                        label: "Region"
                                    }
                                ]
                                foreground: root.foreground
                                background: root.background
                                accent: root.accent
                                fontFamily: root.fontFamily
                                Layout.fillWidth: true
                                onChanged: function (v) {
                                    root.setConfig("targetMode", v);
                                }
                            }

                            Text {
                                text: "Monitor"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                visible: (root.cfg.targetMode || "portal") === "monitor"
                            }
                            Dropdown {
                                id: monitorDropdown
                                label: ""
                                visible: (root.cfg.targetMode || "portal") === "monitor"
                                value: root.cfg.monitorName || ""
                                options: root.monitorOptions()
                                foreground: root.foreground
                                background: root.background
                                accent: root.accent
                                fontFamily: root.fontFamily
                                Layout.fillWidth: true
                                onChanged: function (v) {
                                    root.setConfig("monitorName", v);
                                }
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: Style.space(8)
                            visible: (root.cfg.targetMode || "portal") === "region"

                            Button {
                                text: root.cfg._lastRegion ? "Re-pick region" : "Pick region"
                                onClicked: {
                                    if (root.service && typeof root.service.pickRegion === "function")
                                        root.service.pickRegion();
                                    else {
                                        fallbackRegionPicker.command = ["omarchy-capture-region", "smart", "--match-monitor"];
                                        fallbackRegionPicker.running = true;
                                    }
                                }
                            }

                            Text {
                                text: root.cfg._lastRegion ? root.cfg._lastRegion : "No region selected"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }

                    PanelSeparator {
                        foreground: root.foreground
                    }

                    // ---- Hardware / detection -------------------------------------------
                    Column {
                        width: parent.width
                        spacing: Style.space(8)

                        PanelSectionHeader {
                            text: "DETECTED HARDWARE"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        GridLayout {
                            width: parent.width
                            columns: 2
                            columnSpacing: Style.space(10)
                            rowSpacing: Style.space(4)

                            Text {
                                text: "GPU"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Text {
                                text: String(root.gpu.vendor || "unknown").toUpperCase()
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }

                            Text {
                                text: "Encoder"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Text {
                                text: root.effectiveEncoder().toUpperCase() + " (" + String(root.gpu.backend || "cpu").toUpperCase() + ")"
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }

                            Text {
                                text: "Codec"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Text {
                                text: root.effectiveCodec().toUpperCase()
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }

                            Text {
                                text: "Bitrate"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Text {
                                text: root.effectiveBitrate().toUpperCase()
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }

                            Text {
                                text: "Quality"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Text {
                                text: root.effectiveQuality().toUpperCase()
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }
                        }

                        Text {
                            text: "Codecs: " + (root.gpu.codecs || []).join(", ")
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            wrapMode: Text.WordWrap
                            width: parent.width
                        }
                    }

                    PanelSeparator {
                        foreground: root.foreground
                    }

                    // ---- Streaming (mode == stream) --------------------------------------
                    Column {
                        width: parent.width
                        spacing: Style.space(8)
                        visible: root.isStream

                        PanelSectionHeader {
                            text: "STREAM"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        GridLayout {
                            width: parent.width
                            columns: 2
                            columnSpacing: Style.space(10)
                            rowSpacing: Style.space(8)

                            Text {
                                text: "Platform"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            Dropdown {
                                id: platformDropdown
                                label: ""
                                value: root.cfg.streamPlatform || "custom"
                                options: root.platformOptions()
                                foreground: root.foreground
                                background: root.background
                                accent: root.accent
                                fontFamily: root.fontFamily
                                Layout.fillWidth: true
                                onChanged: function (v) {
                                    root.applyPlatformDefaults(v);
                                }
                            }

                            Text {
                                text: "Server URL"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            TextField {
                                text: root.cfg.streamUrl || ""
                                placeholderText: "rtmp://push.tiktokcdn.com/live/"
                                foreground: root.foreground
                                accent: root.accent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.fillWidth: true
                                onEditingFinished: root.setStreamField("streamUrl", text)
                            }

                            Text {
                                text: "Stream key"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            TextField {
                                text: root.cfg.streamKey || ""
                                password: true
                                placeholderText: "live stream key"
                                foreground: root.foreground
                                accent: root.accent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.fillWidth: true
                                onEditingFinished: root.setStreamField("streamKey", text)
                            }

                            Text {
                                text: "Bitrate"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            NumberField {
                                value: Number(root.cfg.streamKbps || 6000)
                                from: 32
                                to: 20000
                                stepSize: 500
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                onModified: function (v) {
                                    root.setConfig("streamKbps", v);
                                }
                            }

                            Text {
                                text: "Remember key"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            ToggleSwitch {
                                checked: root.cfg.streamRemember === true
                                foreground: root.foreground
                                accent: root.accent
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                onToggled: {
                                    var next = !root.cfg.streamRemember;
                                    root.setConfig("streamRemember", next);
                                    // Persist the session URL/key the moment remembering is enabled.
                                    if (next && root.service && typeof root.service.persistConfig === "function") {
                                        root.service.persistConfig();
                                    }
                                }
                            }

                            Text {
                                text: "Save local copy"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            ToggleSwitch {
                                checked: root.cfg.streamBackupLocal === true
                                foreground: root.foreground
                                accent: root.accent
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                onToggled: root.setConfig("streamBackupLocal", !root.cfg.streamBackupLocal)
                            }
                        }

                        Button {
                            text: "Reset to " + root.platformLabel() + " defaults"
                            onClicked: root.applyPlatformDefaults(root.cfg.streamPlatform || "custom")
                        }

                        Text {
                            text: {
                                var p = root.cfg.streamPlatform || "custom";
                                if (p === "tiktok")
                                    return "TikTok: H.264 + AAC, CBR, portrait 9:16 recommended. Requires 18+ and 1000+ followers; the key is temporary and only works with the matching Server URL.";
                                if (p === "twitch")
                                    return "Twitch: ingest rtmp://live.twitch.tv/app + your stream key from the Creator Dashboard.";
                                if (p === "youtube")
                                    return "YouTube: find your stream key under Go live; the Server URL is usually rtmp://a.rtmp.youtube.com/live2.";
                                return "Custom: point the Server URL + key at any RTMP-compatible service.";
                            }
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            wrapMode: Text.WordWrap
                            width: parent.width
                        }
                    }

                    // ---- Settings --------------------------------------------------------
                    Column {
                        width: parent.width
                        spacing: Style.space(8)

                        PanelSectionHeader {
                            text: "SETTINGS"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        GridLayout {
                            id: settingsGrid
                            width: parent.width
                            columns: 2
                            columnSpacing: Style.space(10)
                            rowSpacing: Style.space(8)

                            Text {
                                text: "Frame rate"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            NumberField {
                                value: Number(root.cfg.fps || 60)
                                from: 1
                                to: 240
                                stepSize: 15
                                foreground: root.foreground
                                accent: root.accent
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                onModified: function (v) {
                                    root.setConfig("fps", v);
                                }
                            }

                            Text {
                                text: "Container"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                visible: !root.isStream
                            }
                            Dropdown {
                                id: containerDropdown
                                label: ""
                                visible: !root.isStream
                                value: root.cfg.container || "mp4"
                                options: [
                                    {
                                        value: "mp4",
                                        label: "mp4"
                                    },
                                    {
                                        value: "mkv",
                                        label: "mkv"
                                    },
                                    {
                                        value: "webm",
                                        label: "webm"
                                    }
                                ]
                                foreground: root.foreground
                                background: root.background
                                accent: root.accent
                                fontFamily: root.fontFamily
                                Layout.fillWidth: true
                                onChanged: function (v) {
                                    root.setConfig("container", v);
                                }
                            }
                        }

                        // ---- Audio / cursor toggles ----------------------------------------
                        GridLayout {
                            width: parent.width
                            columns: 2
                            columnSpacing: Style.space(10)
                            rowSpacing: Style.space(8)

                            Text {
                                text: "Audio"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            ToggleSwitch {
                                checked: root.cfg.audioEnabled === true
                                foreground: root.foreground
                                accent: root.accent
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                onToggled: root.setConfig("audioEnabled", !root.cfg.audioEnabled)
                            }

                            Text {
                                text: "Mic"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            ToggleSwitch {
                                checked: root.cfg.audioMicrophone === true
                                foreground: root.foreground
                                accent: root.accent
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                onToggled: root.setConfig("audioMicrophone", !root.cfg.audioMicrophone)
                            }

                            Text {
                                text: "Cursor"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                            }
                            ToggleSwitch {
                                checked: root.cfg.cursor !== false
                                foreground: root.foreground
                                accent: root.accent
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
                                onToggled: root.setConfig("cursor", root.cfg.cursor !== true)
                            }
                        }

                        Column {
                            width: parent.width
                            spacing: Style.space(6)

                            Text {
                                text: "Output folder"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }

                            TextField {
                                text: root.cfg.outputDir || ""
                                foreground: root.foreground
                                accent: root.accent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                placeholderText: root.service ? root.service.outputDir
                                    : (root.serviceState ? (root.serviceState.outputDir || "") : "")
                                onEditingFinished: root.setConfig("outputDir", text)
                            }
                        }

                        // ---- Advanced encoder profile --------------------------------------
                        Row {
                            spacing: Style.space(8)
                            Button {
                                text: root.cfg.advanced ? "Hide advanced" : "Advanced (encoder)"
                                onClicked: root.setConfig("advanced", !root.cfg.advanced)
                            }
                        }

                        Column {
                            width: parent.width
                            spacing: Style.space(8)
                            visible: root.cfg.advanced === true
                            // Encoder tweaks apply to recordings; streams always use
                            // H.264 + CBR with the bitrate above.

                            GridLayout {
                                width: parent.width
                                columns: 2
                                columnSpacing: Style.space(10)
                                rowSpacing: Style.space(8)

                                Text {
                                    text: "Codec"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                    visible: !root.isStream
                                }
                                Dropdown {
                                    id: codecDropdown
                                    label: ""
                                    visible: !root.isStream
                                    value: root.cfg.codec || "auto"
                                    options: [
                                        {
                                            value: "auto",
                                            label: "Auto (detected)"
                                        },
                                        {
                                            value: "h264",
                                            label: "H.264"
                                        },
                                        {
                                            value: "hevc",
                                            label: "HEVC / H.265"
                                        },
                                        {
                                            value: "av1",
                                            label: "AV1"
                                        },
                                        {
                                            value: "vp9",
                                            label: "VP9"
                                        },
                                        {
                                            value: "vp8",
                                            label: "VP8"
                                        }
                                    ]
                                    foreground: root.foreground
                                    background: root.background
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    Layout.fillWidth: true
                                    onChanged: function (v) {
                                        root.setConfig("codec", v);
                                    }
                                }

                                Text {
                                    text: "Quality"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                    visible: !root.isStream
                                }
                                Dropdown {
                                    id: qualityDropdown
                                    label: ""
                                    visible: !root.isStream
                                    value: root.cfg.quality || "auto"
                                    options: [
                                        {
                                            value: "auto",
                                            label: "Auto (detected)"
                                        },
                                        {
                                            value: "medium",
                                            label: "Medium"
                                        },
                                        {
                                            value: "high",
                                            label: "High"
                                        },
                                        {
                                            value: "very_high",
                                            label: "Very high"
                                        },
                                        {
                                            value: "ultra",
                                            label: "Ultra"
                                        }
                                    ]
                                    foreground: root.foreground
                                    background: root.background
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    Layout.fillWidth: true
                                    onChanged: function (v) {
                                        root.setConfig("quality", v);
                                    }
                                }

                                Text {
                                    text: "Bitrate mode"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                    visible: !root.isStream
                                }
                                Dropdown {
                                    id: bitrateDropdown
                                    label: ""
                                    visible: !root.isStream
                                    value: root.cfg.bitrateMode || "auto"
                                    options: [
                                        {
                                            value: "auto",
                                            label: "Auto (detected)"
                                        },
                                        {
                                            value: "qp",
                                            label: "QP (constant quality)"
                                        },
                                        {
                                            value: "vbr",
                                            label: "VBR"
                                        },
                                        {
                                            value: "cbr",
                                            label: "CBR"
                                        }
                                    ]
                                    foreground: root.foreground
                                    background: root.background
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    Layout.fillWidth: true
                                    onChanged: function (v) {
                                        root.setConfig("bitrateMode", v);
                                    }
                                }

                                Text {
                                    text: "Encoder"
                                    color: root.muted
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                }
                                Dropdown {
                                    id: encoderDropdown
                                    label: ""
                                    value: root.cfg.encoder || "gpu"
                                    options: [
                                        {
                                            value: "gpu",
                                            label: "GPU (hardware)"
                                        },
                                        {
                                            value: "cpu",
                                            label: "CPU (software)"
                                        }
                                    ]
                                    foreground: root.foreground
                                    background: root.background
                                    accent: root.accent
                                    fontFamily: root.fontFamily
                                    Layout.fillWidth: true
                                    onChanged: function (v) {
                                        root.setConfig("encoder", v);
                                    }
                                }
                            }
                        }
                    }

                    PanelSeparator {
                        foreground: root.foreground
                    }

                    // ---- Footer: re-detect + diagnostics --------------------------------
                    Row {
                        width: parent.width
                        spacing: Style.space(8)

                        Button {
                            text: "Re-detect hardware"
                            onClicked: {
                                if (root.service) {
                                    root.service.refreshGpuInfo();
                                    root.service.refreshMonitors();
                                } else {
                                    ipcActionProc.command = ["omarchy-shell", "px-recast", "refreshGpu"];
                                    ipcActionProc.running = true;
                                }
                            }
                        }

                        Text {
                            text: root.service ? (root.service.gpuDetected ? "Detected" : "Detecting…")
                                : (root.serviceState ? (root.serviceState.gpuDetected ? "Detected" : "Detecting…") : "Detecting…")
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Text {
                        visible: Boolean(root.service ? root.service.gpuDetected : (root.serviceState ? root.serviceState.gpuDetected : false)) && (root.gpu.codecs || []).indexOf("h264_software") === -1
                        text: "Hardware encoding active. CPU fallback is enabled automatically if the GPU encoder is unavailable."
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }
                }
            }
        }
    }

    // Fallback IPC action process — used when service object is null
    // (replacement bars can't resolve third-party services)
    Process {
        id: ipcActionProc
        running: false
    }

    Process {
        id: toggleIpcAction
        running: false
    }

    Process {
        id: configIpcProc
        running: false
    }

    // Fallback region picker — used when service object is null
    Process {
        id: fallbackRegionPicker
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var out = text.trim();
                if (!out || out === "cancelled" || out === "null") {
                    root._localError = "Region selection was cancelled";
                    return;
                }
                if (out.match(/^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/)) {
                    root.setConfig("_lastRegion", out);
                } else {
                    var m = out.match(/^(-?[0-9]+),(-?[0-9]+)\s+([0-9]+)x([0-9]+)$/);
                    if (m) {
                        var geom = m[3] + "x" + m[4] + "+" + m[1] + "+" + m[2];
                        root.setConfig("_lastRegion", geom);
                    }
                }
            }
        }
        onExited: function (exitCode) {
            if (exitCode !== 0) {
                root._localError = "Region selection failed";
            }
        }
    }
}
