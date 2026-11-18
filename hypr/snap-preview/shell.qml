// Click-through preview of where a floating window will land when dropped in
// the top-middle snap zone. Driven by ~/.config/hypr/snap-top.lua, which writes
// "show <monitor> <x> <y> <w> <h>" (monitor-local logical px) or "hide" to
// $XDG_RUNTIME_DIR/hypr-snap-top.preview.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
  id: root

  property bool shown: false
  property string monitor: ""
  property rect box: Qt.rect(0, 0, 0, 0)
  property color accent: "#7aa2f7"

  function parse(raw) {
    const line = String(raw || "").trim()
    if (line === "hide") {
      shown = false
      return
    }
    const p = line.split(/\s+/)
    if (p.length !== 6 || p[0] !== "show") return // partial write; wait for the next change
    const n = p.slice(2).map(Number)
    if (n.some(isNaN)) return
    monitor = p[1]
    box = Qt.rect(n[0], n[1], n[2], n[3])
    if (!shown) colors.reload()
    shown = true
  }

  FileView {
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/hypr-snap-top.preview"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
  }

  FileView {
    id: colors
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    printErrors: false
    onLoaded: {
      const m = text().match(/^\s*accent\s*=\s*["']?(#[0-9A-Fa-f]{6})/m)
      if (m) root.accent = m[1]
    }
  }

  // ---- Layout picker (maximize-button hover), driven by snap-menu.lua ----
  property bool menuShown: false
  property string menuMonitor: ""
  property string menuAddress: ""
  property rect menuRect: Qt.rect(0, 0, 0, 0)
  property var menuBoxes: ({})
  property string hovered: ""

  function parseMenu(raw) {
    const lines = String(raw || "").trim().split("\n")
    if (lines[0].trim() === "hide") {
      menuShown = false
      hovered = ""
      return
    }
    if (lines[lines.length - 1].trim() !== "end") return // partial write
    const h = lines[0].trim().split(/\s+/)
    if (h.length !== 7 || h[0] !== "show") return
    const r = h.slice(3).map(Number)
    const boxes = {}
    for (const l of lines.slice(1)) {
      const p = l.trim().split(/\s+/)
      if (p[0] !== "box" || p.length !== 6) continue
      const n = p.slice(2).map(Number)
      boxes[p[1]] = Qt.rect(n[0], n[1], n[2], n[3])
    }
    menuMonitor = h[1]
    menuAddress = h[2]
    menuRect = Qt.rect(r[0], r[1], r[2], r[3])
    menuBoxes = boxes
    hovered = ""
    if (!menuShown) colors.reload()
    menuShown = true
  }

  FileView {
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/hypr-snap-menu.state"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parseMenu(text())
  }

  Process {
    id: applyProc
  }

  function apply(name) {
    const addr = menuAddress
    menuShown = false
    applyProc.command = ["hyprctl", "eval", "snap_menu.apply('" + addr + "','" + name + "')"]
    applyProc.running = true
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: menuWin
      required property var modelData
      readonly property bool active: root.menuShown && root.menuMonitor === modelData.name
      readonly property var tiles: [
        ["left", 0], ["right", 1], ["top", 2], ["bottom", 3],
        ["tl", 4], ["tr", 5], ["bl", 6], ["br", 7]
      ]

      screen: modelData
      visible: active || popup.opacity > 0
      color: "transparent"
      WlrLayershell.namespace: "snap-menu"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      anchors { top: true; bottom: true; left: true; right: true }
      mask: Region { item: menuWin.active ? popup : null }

      // Preview of the hovered layout.
      Rectangle {
        readonly property rect b: root.menuBoxes[root.hovered] || Qt.rect(0, 0, 0, 0)
        visible: menuWin.active && root.hovered !== ""
        x: b.x; y: b.y; width: b.width; height: b.height
        radius: 12
        color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.30)
        border.color: root.accent
        border.width: 3
      }

      Rectangle {
        id: popup
        x: root.menuRect.x
        y: root.menuRect.y
        width: root.menuRect.width
        height: root.menuRect.height
        radius: 10
        color: Qt.rgba(0.09, 0.10, 0.13, 0.96)
        border.color: Qt.rgba(1, 1, 1, 0.14)
        border.width: 1
        opacity: menuWin.active ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        readonly property real pad: 8
        readonly property real gap: 6
        readonly property real fillH: 40
        readonly property real tileW: (width - 2 * pad - 3 * gap) / 4
        readonly property real tileH: (height - 2 * pad - fillH - 2 * gap) / 2

        // Fill: the primary action.
        Rectangle {
          x: popup.pad; y: popup.pad
          width: popup.width - 2 * popup.pad; height: popup.fillH
          radius: 6
          color: root.hovered === "fill" ? root.accent : Qt.rgba(1, 1, 1, 0.10)
          Text {
            anchors.centerIn: parent
            text: "Fill"
            font.pixelSize: 14
            font.bold: true
            color: root.hovered === "fill" ? "#101218" : "#e6e8ee"
          }
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: root.hovered = "fill"
            onExited: if (root.hovered === "fill") root.hovered = ""
            onClicked: root.apply("fill")
          }
        }

        Repeater {
          model: menuWin.tiles
          delegate: Rectangle {
            required property var modelData
            readonly property string name: modelData[0]
            readonly property int idx: modelData[1]
            readonly property rect b: root.menuBoxes[name] || Qt.rect(0, 0, 1, 1)
            x: popup.pad + (idx % 4) * (popup.tileW + popup.gap)
            y: popup.pad + popup.fillH + popup.gap + Math.floor(idx / 4) * (popup.tileH + popup.gap)
            width: popup.tileW; height: popup.tileH
            radius: 5
            color: Qt.rgba(1, 1, 1, root.hovered === name ? 0.20 : 0.08)

            // Thumbnail of the zone within the screen.
            Rectangle {
              x: 3 + (parent.width - 6) * (b.x - 0) / menuWin.modelData.width
              y: 3 + (parent.height - 6) * (b.y - 0) / menuWin.modelData.height
              width: (parent.width - 6) * b.width / menuWin.modelData.width
              height: (parent.height - 6) * b.height / menuWin.modelData.height
              radius: 2
              color: root.hovered === name ? root.accent : Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.55)
            }
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.hovered = name
              onExited: if (root.hovered === name) root.hovered = ""
              onClicked: root.apply(name)
            }
          }
        }
      }
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      readonly property bool active: root.shown && root.monitor === modelData.name

      screen: modelData
      visible: active || frame.opacity > 0
      color: "transparent"
      WlrLayershell.namespace: "snap-preview"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      anchors { top: true; bottom: true; left: true; right: true }
      mask: Region {}

      // A dark outline under the accent border keeps the preview readable on
      // light wallpapers and windows as well as dark ones.
      Rectangle {
        id: frame
        x: root.box.x
        y: root.box.y
        width: root.box.width
        height: root.box.height
        radius: 12
        color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
        border.color: Qt.rgba(0, 0, 0, 0.55)
        border.width: 2
        opacity: win.active ? 1 : 0

        Rectangle {
          anchors.fill: parent
          anchors.margins: 2
          radius: parent.radius - 2
          color: "transparent"
          border.color: root.accent
          border.width: 4
        }
        scale: win.active ? 1 : 0.97
        Behavior on opacity { NumberAnimation { duration: win.active ? 160 : 110; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      }
    }
  }
}
