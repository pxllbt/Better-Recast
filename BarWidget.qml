import QtQuick
import qs.Ui
import qs.Commons

// pix.recast bar widget — recording state indicator.
// Idle shows a dimmed resting glyph; left click toggles recording, right click
// opens the control panel as a popup anchored to the button. While recording
// the glyph brightens and shows the elapsed time next to it.
BarWidget {
    id: root

    moduleName: "pix.recast"

    property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function" ? bar.shell.serviceFor("pix.recast") : null

    property string stateText: ""
    property int elapsed: 0

    // Popup is hosted by Panel.qml, which the bar mounts per monitor through
    // this hidden loader. The panel extends qs.Ui Panel, so the bar's popout
    // contract (open/close/opened/closeForPopoutSwitch) forwards straight to it.
    // Besides the bar/anchoring props, the panel needs the shared service — the
    // old panel-host used to inject it (shell.qml panelLoader), the bar-widget
    // loader must do the same.
    function injectPanel() {
        var target = panelLoader.item;
        if (!target)
            return;
        if ("bar" in target)
            target.bar = root.bar;
        if ("settings" in target)
            target.settings = root.settings;
        if ("anchorItem" in target)
            target.anchorItem = root;
        if ("hostWidget" in target)
            target.hostWidget = root;
        if ("service" in target)
            target.service = root.service;
    }

    function refresh() {
        if (!root.service)
            return;
        var s = root.service.recordingState || "idle";
        var e = root.service.recordingElapsed || 0;
        if (root.stateText !== s)
            root.stateText = s;
        if (root.elapsed !== e)
            root.elapsed = e;
    }

    readonly property bool recording: stateText === "recording" || stateText === "paused" || stateText === "starting"
    readonly property bool pausedState: stateText === "paused"
    readonly property bool streaming: root.service && root.service.config && (root.service.config.mode || "record") === "stream"

    function formatElapsed(sec) {
        var h = Math.floor(sec / 3600);
        var m = Math.floor((sec % 3600) / 60);
        var s = sec % 60;
        var pad = function (n) {
            return n < 10 ? "0" + n : String(n);
        };
        return (h > 0 ? pad(h) + ":" : "") + pad(m) + ":" + pad(s);
    }

    // ---- popout contract (Bar.findPanelWidget / bar.requestPopout) ----------
    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

    function open() {
        if (panelLoader.item && panelLoader.item.open)
            panelLoader.item.open();
    }

    function close() {
        if (panelLoader.item && panelLoader.item.close)
            panelLoader.item.close();
    }

    function togglePanel() {
        if (panelLoader.item && panelLoader.item.toggle)
            panelLoader.item.toggle();
    }

    readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

    function closeForPopoutSwitch() {
        if (panelLoader.item)
            panelLoader.item.closeForPopoutSwitch();
    }

    readonly property string glyphText: recording ? (streaming ? "●" : (pausedState ? "󰏥" : "󰻂")) : "󰻂"
    readonly property color glyphColor: recording ? (streaming ? Color.urgent : Color.accent) : (root.bar ? root.bar.barForeground : Color.foreground)
    readonly property string tooltip: recording ? (pausedState ? "Paused" : (streaming ? "Live" : "Recording")) + " · " + formatElapsed(elapsed) + "\nLeft-click to stop · Right-click panel" : (streaming ? "Screen Recorder\nLeft-click to go live · Right-click panel" : "Screen Recorder\nLeft-click to record · Right-click panel")

    onBarChanged: {
        refresh();
        injectPanel();
    }
    onServiceChanged: injectPanel()
    onSettingsChanged: injectPanel()
    Component.onCompleted: refresh()

    Connections {
        target: root.service
        ignoreUnknownSignals: true
        function onRecordingStateChanged(value) {
            root.refresh();
        }
        function onRecordingElapsedChanged(value) {
            root.refresh();
        }
        function onConfigChanged(value) {
            root.refresh();
        }
    }

    Timer {
        interval: 1000
        running: root.recording
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    implicitWidth: row.implicitWidth + Style.space(10)
    implicitHeight: barSize

    Row {
        id: row
        anchors.centerIn: parent
        spacing: Style.space(5)

        Text {
            id: glyph
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyphText
            color: root.glyphColor
            opacity: root.recording ? 1 : 0.6
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            Behavior on color {
                enabled: !root.bar || root.bar.foregroundAnimationEnabled
                ColorAnimation {
                    duration: 160
                }
            }
        }

        Text {
            id: elapsedLabel
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.formatElapsed(root.elapsed)
            visible: root.recording && root.elapsed > 0 && !root.bar.vertical
            color: root.bar.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
        }

        Text {
            id: liveLabel
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: "LIVE"
            visible: root.streaming && root.recording && !root.bar.vertical
            color: Color.urgent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton

        onClicked: function (mouse) {
            if (mouse.button === Qt.RightButton)
                root.togglePanel();
            else if (mouse.button === Qt.LeftButton) {
                if (root.service && typeof root.service.toggle === "function")
                    root.service.toggle();
            }
        }
        onEntered: if (root.bar)
            root.bar.showTooltip(root, root.tooltip)
        onExited: if (root.bar)
            root.bar.hideTooltip(root)
    }

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.injectPanel();
            Qt.callLater(root.injectPanel);
        }
    }
}
