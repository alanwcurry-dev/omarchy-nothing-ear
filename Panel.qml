import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Nothing Ear bar widget and its panel. Copy for a real product of
// Nothing Technology Limited; this plugin is an unofficial desktop port of the
// phone app's everyday surface: battery, noise control, equalizer, low latency,
// find-my-earbuds and the host audio codec.
Panel {
  id: root
  moduleName: "frank.nothingear"
  ipcTarget: "nothing-ear"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // allows and add its own verbs to it.
  manageIpc: false

  property int cursorGroup: 0
  property int cursorOption: 0
  property bool cursorActive: false
  property int phraseIndex: 0

  readonly property bool hideWhenDisconnected: setting("hideWhenDisconnected", true) === true
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  // The bar icon follows barForeground (which tracks a transparent bar); panel
  // content follows foreground. They are not interchangeable.
  readonly property color barIconColor: ear.connected ? barForeground : Qt.darker(barForeground, 1.6)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string heroPhrase: activePhrases[phraseIndex % activePhrases.length]

  readonly property var activePhrases: [
    "Listening quietly",
    "Nothing on but the music",
    "Keeping the low end low",
    "Talking to the buds",
    "Wireless, not magic",
    "Ear candy, on demand"
  ]

  readonly property var ancOptions: Model.ANC_VALUES.map(function (key) {
    return { key: key, label: Model.ANC_LABELS[key] }
  })
  readonly property var eqOptions: Model.EQ_VALUES.map(function (key) {
    return { key: key, label: Model.EQ_LABELS[key] }
  })

  readonly property bool showNoise: ear.hasControls && ear.noiseAvailable
  readonly property bool showEq: ear.hasControls && ear.eqAvailable
  readonly property bool showBass: ear.hasControls && ear.bassAvailable
  readonly property bool showLatency: ear.hasControls && ear.latencyAvailable
  readonly property bool showFind: ear.hasControls
  readonly property bool showCodec: ear.connected && ear.codecAvailable
  // One pair needs no picker; two do.
  readonly property bool showDevices: ear.nothingDevices.length > 1

  // Cursor groups, in panel order: the same order the eye reads them in.
  readonly property var cursorRows: {
    var rows = []
    if (showDevices)
      for (var d = 0; d < ear.nothingDevices.length; d++) rows.push("device:" + ear.nothingDevices[d].address)
    if (showNoise) for (var n = 0; n < Model.ANC_VALUES.length; n++) rows.push("anc:" + Model.ANC_VALUES[n])
    if (showEq) for (var e = 0; e < Model.EQ_VALUES.length; e++) rows.push("eq:" + Model.EQ_VALUES[e])
    if (showBass) rows.push("bass")
    if (showLatency) rows.push("latency")
    if (showFind) { rows.push("find:left"); rows.push("find:right") }
    if (showCodec) for (var c = 0; c < ear.codecOptions.length; c++) rows.push("codec:" + ear.codecOptions[c].key)
    return rows
  }

  // Group boundaries inside the flat row list: j/k steps by group, h/l by row.
  readonly property var cursorGroups: {
    var groups = []
    if (showDevices) groups.push(ear.nothingDevices.length)
    if (showNoise) groups.push(Model.ANC_VALUES.length)
    if (showEq) groups.push(Model.EQ_VALUES.length)
    if (showBass) groups.push(1)
    if (showLatency) groups.push(1)
    if (showFind) groups.push(2)
    if (showCodec) groups.push(ear.codecOptions.length)
    return groups
  }

  readonly property string cursorRow: {
    if (cursorGroups.length === 0) return ""
    var offsets = groupOffsets()
    var group = Math.min(cursorGroup, cursorGroups.length - 1)
    var count = cursorGroups[group]
    if (count <= 0) return ""
    return cursorRows[offsets[group] + Math.min(cursorOption, count - 1)] || ""
  }

  function groupOffsets() {
    var offsets = []
    var running = 0
    for (var i = 0; i < cursorGroups.length; i++) {
      offsets.push(running)
      running += cursorGroups[i]
    }
    return offsets
  }

  function rowHasCursor(name) {
    return cursorActive && cursorRow === name
  }

  // Landing on the option that is already active makes j/k feel like walking
  // rows: the cursor arrives where the eye already is.
  function activeRowInGroup(group) {
    var rows = cursorRows
    var offsets = groupOffsets()
    if (group < 0 || group >= cursorGroups.length) return ""
    var count = cursorGroups[group]
    for (var i = 0; i < count; i++) {
      var name = rows[offsets[group] + i]
      if (name.indexOf("device:") === 0 && name.substring(7) === ear.targetAddress) return name
      if (name.indexOf("anc:") === 0 && name.substring(4) === ear.noiseKey) return name
      if (name.indexOf("eq:") === 0 && name.substring(3) === ear.eqKey) return name
      if (name === "bass") return name
      if (name === "latency") return name
      if (name.indexOf("codec:") === 0 && name.substring(6) === ear.activeCodec) return name
    }
    return count > 0 ? rows[offsets[group]] : ""
  }

  function optionIndexFor(group, name) {
    var rows = cursorRows
    var offsets = groupOffsets()
    if (group < 0 || group >= cursorGroups.length) return 0
    var index = rows.indexOf(name) - offsets[group]
    return index < 0 ? 0 : index
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (cursorGroups.length === 0) return
    if (dy !== 0) {
      cursorGroup = Math.max(0, Math.min(cursorGroups.length - 1, cursorGroup + dy))
      cursorOption = optionIndexFor(cursorGroup, activeRowInGroup(cursorGroup))
      return
    }
    if (dx !== 0) {
      cursorOption = Math.max(0, Math.min(cursorGroups[cursorGroup] - 1, cursorOption + dx))
    }
  }

  function focusRow(name) {
    if (cursorRows.indexOf(name) < 0) return
    var offsets = groupOffsets()
    for (var group = 0; group < cursorGroups.length; group++) {
      var start = offsets[group]
      var end = start + cursorGroups[group]
      for (var index = start; index < end; index++) {
        if (cursorRows[index] !== name) continue
        cursorActive = true
        cursorGroup = group
        cursorOption = index - start
        return
      }
    }
  }

  function activate(name) {
    if (name.indexOf("device:") === 0) ear.selectDevice(name.substring(7))
    else if (name.indexOf("anc:") === 0) ear.setAnc(name.substring(4))
    else if (name.indexOf("eq:") === 0) ear.setEq(name.substring(3))
    else if (name === "bass") ear.setBass(!ear.bassEnabled)
    else if (name === "latency") ear.setLatency(!ear.latencyEnabled)
    else if (name === "find:left") ear.toggleRing("left")
    else if (name === "find:right") ear.toggleRing("right")
    else if (name.indexOf("codec:") === 0) ear.setCodec(name.substring(6))
  }

  readonly property string barTooltip: {
    if (!ear.connected) return ear.deviceKnown ? ear.deviceName + " — not connected" : "Nothing Audio"
    if (!ear.protocol) return ear.deviceName + " — " + (ear.aggregateBattery >= 0 ? ear.aggregateBattery + "%" : "connected")
    var parts = []
    if (ear.leftBud.available) parts.push("L " + Model.levelText(ear.leftBud.level))
    if (ear.rightBud.available) parts.push("R " + Model.levelText(ear.rightBud.level))
    if (ear.caseBattery.available) parts.push("case " + Model.levelText(ear.caseBattery.level))
    var tail = showNoise ? " — " + Model.ancLabel(ear.noiseKey) : ""
    return ear.deviceName + (parts.length > 0 ? " — " + parts.join(" · ") : "") + tail
  }

  readonly property int lowestBud: Model.lowestBudLevel(ear.leftBud, ear.rightBud, ear.headsetBattery)
  readonly property bool batteryLow: root.lowestBud !== Model.LEVEL_UNKNOWN && root.lowestBud <= 20

  // The number on the bar: the weakest bud, or the single Bluetooth percentage
  // while the control channel does not answer. A vertical bar is only 28px
  // wide, so it keeps the artwork alone.
  readonly property string batteryLabel: {
    if (!ear.connected) return ""
    if (root.lowestBud !== Model.LEVEL_UNKNOWN) return root.lowestBud + "%"
    if (ear.aggregateBattery !== Model.LEVEL_UNKNOWN) return ear.aggregateBattery + "%"
    return ""
  }
  readonly property bool barLabelVisible: setting("showBatteryPercent", true) === true
    && root.batteryLabel !== "" && !(bar ? bar.vertical : false)

  // The bar slot has to reserve the number's width before the icon component
  // exists, so measure the text here rather than reaching into the component.
  TextMetrics {
    id: barLabelMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.bar.iconFont
    text: root.batteryLabel
  }
  readonly property real barLabelWidth: Math.ceil(barLabelMetrics.width)

  // An error keeps the widget on the bar even with the earbuds away: hiding it
  // would leave a helper that cannot run with nowhere to say so.
  visible: !hideWhenDisconnected || ear.connected || ear.lastError !== ""
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursorGroup = 0
      cursorOption = 0
      if (panelFlick) panelFlick.contentY = 0
      ear.refresh()
      Qt.callLater(function () { keyCatcher.forceActiveFocus() })
    } else {
      // A ring that outlives the panel would be impossible to switch off.
      ear.stopRings()
    }
  }

  Service {
    id: ear
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { ear.refresh(); return "ok" }
    function noise(): string { ear.cycleAnc(); return ear.noiseKey }
    function eq(): string { ear.cycleEq(); return ear.eqKey }
    function bass(): string { ear.setBass(!ear.bassEnabled); return ear.bassEnabled ? "on" : "off" }
    function latency(): string { ear.setLatency(!ear.latencyEnabled); return ear.latencyEnabled ? "on" : "off" }
    function codec(): string { ear.cycleCodec(); return ear.activeCodec }
    function use(device: string): string {
      if (!ear.selectDevice(device)) return "unknown device: " + device
      return ear.targetAddress
    }
    function devices(): string { return JSON.stringify(ear.deviceList()) }
    function find(side: string): string {
      if (side !== "left" && side !== "right") return "usage: find left|right"
      ear.toggleRing(side)
      return side + (side === "left" ? (ear.ringLeft ? ":on" : ":off") : (ear.ringRight ? ":on" : ":off"))
    }
    function diagnose(): string {
      Quickshell.execDetached(["/usr/bin/python3", ear.helperPath, "diagnose"])
      return "ok"
    }
    function status(): string {
      if (!ear.connected) return "disconnected"
      if (!ear.protocol) return "connected"
      var parts = [ear.deviceName !== "" ? ear.deviceName : "device", Model.levelText(root.lowestBud)]
      parts.push(ear.noiseAvailable ? Model.ancLabel(ear.noiseKey) : "no noise control")
      return parts.join(" · ")
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.barTooltip
    // The artwork and the battery number share one clickable slot, so the slot
    // grows by the label's width instead of overlapping its neighbour.
    slotSize: Style.bar.iconSlot + (root.barLabelVisible ? Style.space(6) + root.barLabelWidth : 0)
    opticalSize: Style.bar.iconCanvas + (root.barLabelVisible ? Style.space(6) + root.barLabelWidth : 0)
    iconComponent: Component {
      Item {
        anchors.centerIn: parent
        implicitWidth: artwork.width + (levelText.visible ? Style.space(4) + levelText.implicitWidth : 0)
        implicitHeight: Math.max(artwork.height, levelText.implicitHeight)

        BudsArtwork {
          id: artwork
          anchors.verticalCenter: parent.verticalCenter
          size: Style.space(15)
          opacity: ear.connected ? 1.0 : 0.55
        }

        Text {
          id: levelText
          anchors.verticalCenter: parent.verticalCenter
          x: artwork.width + Style.space(4)
          visible: root.barLabelVisible
          text: root.batteryLabel
          color: root.batteryLow ? root.urgent : root.barIconColor
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
        }
      }
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) ear.cycleAnc()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activate(root.cursorRow)
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (text) {
        var key = String(text).toLowerCase()
        if (key === "r") { ear.refresh(); return }
        if (key === "g") { ear.setLatency(!ear.latencyEnabled); return }
        if (key === "b") { ear.setBass(!ear.bassEnabled); return }
        if (key === "c") { ear.cycleCodec(); return }
        if (key === "e") { ear.cycleEq(); return }
        // x / X are taken by PanelKeyCatcher (delete), so ringing uses p / P.
        if (key === "p") { ear.toggleRing("left"); return }
        if (text === "P") { ear.toggleRing("right"); return }
        if (!ear.hasControls) return
        if (key === "o") ear.setAnc("off")
        else if (key === "t") ear.setAnc("transparency")
        else if (key === "a") ear.setAnc("adaptive")
        else if (key === "n") ear.cycleAnc()
        // Plain h / l walk the chips, so a level takes the shifted letter.
        else if (text === "L") ear.setAnc("low")
        else if (text === "M") ear.setAnc("mid")
        else if (text === "H") ear.setAnc("high")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.spacing.xxxl

          PanelHero {
            id: hero
            width: parent.width
            title: ear.deviceName !== "" ? ear.deviceName : "Nothing Audio"
            detail: ear.firmware !== "" ? ear.firmware : ""
            meta: ear.connected
              ? (ear.protocol ? root.heroPhrase : "Bluetooth connected")
              : (ear.deviceKnown ? "Not connected" : "No paired Nothing device")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: ear.connected ? 1.0 : 0.5
            iconComponent: Component {
              BudsArtwork {
                anchors.centerIn: parent
                size: Style.font.display
                opacity: ear.connected ? 1.0 : 0.55
              }
            }
          }

          Text {
            visible: ear.lastError !== ""
            width: parent.width
            text: ear.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            visible: root.showDevices
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              text: "EARBUDS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            GridLayout {
              width: parent.width
              columns: 2
              columnSpacing: Style.spacing.md
              rowSpacing: Style.spacing.md

              Repeater {
                model: ear.nothingDevices
                OptionChip {
                  required property var modelData
                  Layout.fillWidth: true
                  Layout.preferredWidth: 1
                  label: modelData.name + (modelData.connected ? "" : " · off")
                  name: "device:" + modelData.address
                  selected: ear.targetAddress === modelData.address
                }
              }
            }

            Text {
              width: parent.width
              text: "The widget reads and controls the selected pair. The others keep their own settings."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            visible: ear.hasBattery
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              text: "BATTERY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              visible: ear.protocol
              width: parent.width
              spacing: Style.spacing.md

              BatteryRow {
                visible: ear.headsetBattery.available
                width: parent.width
                label: "Headset"
                reading: ear.headsetBattery
              }
              BatteryRow {
                visible: !ear.headsetBattery.available
                width: parent.width
                label: "Left"
                reading: ear.leftBud
                wear: ear.wearAvailable ? ear.wearLeft : null
              }
              BatteryRow {
                visible: !ear.headsetBattery.available
                width: parent.width
                label: "Right"
                reading: ear.rightBud
                wear: ear.wearAvailable ? ear.wearRight : null
              }
              BatteryRow {
                width: parent.width
                label: "Case"
                reading: ear.caseBattery
              }
            }

            BatteryRow {
              visible: !ear.protocol && ear.aggregateBattery !== Model.LEVEL_UNKNOWN
              width: parent.width
              label: "Overall"
              reading: ({ level: ear.aggregateBattery, charging: false, available: true, stale: false })
            }
          }

          Column {
            visible: root.showNoise
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              text: "NOISE CONTROL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            GridLayout {
              width: parent.width
              columns: 3
              columnSpacing: Style.spacing.md
              rowSpacing: Style.spacing.md

              Repeater {
                model: root.ancOptions
                OptionChip {
                  required property var modelData
                  Layout.fillWidth: true
                  Layout.preferredWidth: 1
                  label: modelData.label
                  name: "anc:" + modelData.key
                  selected: ear.noiseKey === modelData.key
                }
              }
            }
          }

          Column {
            visible: root.showEq
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              text: "EQUALIZER"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            GridLayout {
              width: parent.width
              columns: 3
              columnSpacing: Style.spacing.md
              rowSpacing: Style.spacing.md

              Repeater {
                model: root.eqOptions
                OptionChip {
                  required property var modelData
                  Layout.fillWidth: true
                  Layout.preferredWidth: 1
                  label: modelData.label
                  name: "eq:" + modelData.key
                  selected: ear.eqKey === modelData.key
                }
              }
            }
          }

          Column {
            visible: root.showBass || root.showLatency
            width: parent.width
            spacing: Style.spacing.md

            ToggleRow {
              visible: root.showBass
              width: parent.width
              name: "bass"
              label: ear.bassLevel > 0 ? "Bass enhance · level " + ear.bassLevel : "Bass enhance"
              checked: ear.bassEnabled
            }

            ToggleRow {
              visible: root.showLatency
              width: parent.width
              name: "latency"
              label: "Low latency"
              checked: ear.latencyEnabled
            }
          }

          Column {
            visible: root.showFind
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              text: "FIND MY EARBUDS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            GridLayout {
              width: parent.width
              columns: 2
              columnSpacing: Style.spacing.md

              Repeater {
                model: ["left", "right"]
                OptionChip {
                  required property var modelData
                  Layout.fillWidth: true
                  Layout.preferredWidth: 1
                  readonly property string side: String(modelData)
                  readonly property bool ringing: side === "left" ? ear.ringLeft : ear.ringRight
                  label: (ringing ? "Stop " : "Ring ") + side
                  name: "find:" + side
                  selected: ringing
                }
              }
            }

            Text {
              width: parent.width
              text: "The earbud rings for 20 seconds and stops on its own."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            visible: root.showCodec
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              text: "AUDIO CODEC"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            GridLayout {
              width: parent.width
              columns: Math.max(1, Math.min(4, ear.codecOptions.length))
              columnSpacing: Style.spacing.md
              rowSpacing: Style.spacing.md

              Repeater {
                model: ear.codecOptions
                OptionChip {
                  required property var modelData
                  Layout.fillWidth: true
                  Layout.preferredWidth: 1
                  label: modelData.label
                  name: "codec:" + modelData.key
                  selected: ear.activeCodec === modelData.key
                }
              }
            }

            Text {
              width: parent.width
              text: "Codecs come from PipeWire's own Bluetooth profiles, so only what this laptop can negotiate is offered."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Text {
            visible: ear.connected && !ear.protocol
            width: parent.width
            text: ear.aggregateBattery !== Model.LEVEL_UNKNOWN
              ? "Bluetooth reports one overall percentage. Reopen the panel when the Nothing control channel is free for battery detail and controls."
              : "The earbuds are connected, but their Nothing control channel did not answer."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            visible: !ear.connected
            width: parent.width
            text: ear.deviceKnown
              ? "Connect your Nothing earbuds to see battery and listening controls."
              : "Pair Nothing earbuds in the Bluetooth panel, then open this panel again."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            visible: ear.protocol && (ear.firmware !== "" || ear.dualConnection !== null)
            width: parent.width
            text: {
              var parts = []
              if (ear.firmware !== "") parts.push("Firmware " + ear.firmware)
              if (ear.protocolVersion !== "") parts.push("protocol " + ear.protocolVersion)
              if (ear.dualConnection !== null) parts.push("dual connection " + (ear.dualConnection ? "on" : "off"))
              return parts.join(" · ")
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  Timer {
    interval: 6000
    running: root.opened && ear.connected
    repeat: true
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: hero
      property: "metaOpacity"
      to: 0.0
      duration: 180
      easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: root.phraseIndex = (root.phraseIndex + 1) % root.activePhrases.length
    }
    PropertyAnimation {
      target: hero
      property: "metaOpacity"
      to: 1.0
      duration: 260
      easing.type: Easing.InQuad
    }
  }

  // The earbud artwork on the bar and in the panel hero: the picture the user
  // picked, kept white-on-transparent so it sits on any bar background.
  component BudsArtwork: Image {
    property real size: Style.space(15)

    width: Math.round(size * 1.31)
    height: Math.round(size)
    source: Qt.resolvedUrl("assets/buds.png")
    sourceSize.width: Math.round(size * 2.62)
    sourceSize.height: Math.round(size * 2)
    fillMode: Image.PreserveAspectFit
    smooth: true
  }

  component BatteryRow: Item {
    id: batteryRow
    property string label: ""
    property var reading: Model.battery()
    // true, false, or null when the device does not report wear.
    property var wear: null

    readonly property string wearLabel: batteryRow.wear === null ? "" : Model.wearText(batteryRow.wear)
    readonly property bool low: batteryRow.reading.level !== Model.LEVEL_UNKNOWN
      && batteryRow.reading.level <= 20 && !batteryRow.reading.charging
    implicitHeight: batteryLayout.implicitHeight

    RowLayout {
      id: batteryLayout
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.spacing.lg

      Text {
        text: batteryRow.label
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.preferredWidth: Style.space(50)
      }

      Rectangle {
        id: meterTrack
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        implicitHeight: Style.space(6)
        radius: height / 2
        color: Qt.darker(root.foreground, 3.2)

        Rectangle {
          id: meterFill
          width: meterTrack.width * Model.levelFraction(batteryRow.reading.level)
          height: parent.height
          radius: parent.radius
          color: batteryRow.low ? root.urgent : root.foreground
          // A reading the case left behind is faded instead of captioned.
          opacity: batteryRow.reading.stale ? 0.5 : 1.0
        }

        // Charging breathes over the fill instead of spelling itself out.
        Rectangle {
          anchors.fill: meterFill
          radius: meterFill.radius
          color: meterTrack.color
          visible: batteryRow.reading.charging
          opacity: 0

          SequentialAnimation on opacity {
            running: batteryRow.reading.charging
            loops: Animation.Infinite
            NumberAnimation { from: 0.0; to: 0.55; duration: 900; easing.type: Easing.InOutQuad }
            NumberAnimation { from: 0.55; to: 0.0; duration: 900; easing.type: Easing.InOutQuad }
          }
        }
      }

      Text {
        visible: batteryRow.wearLabel !== ""
        text: batteryRow.wearLabel
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: Style.space(52)
      }

      Text {
        text: Model.levelText(batteryRow.reading.level)
        color: root.foreground
        opacity: batteryRow.reading.stale ? 0.5 : 1.0
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: Style.space(38)
      }
    }
  }

  component LoadingRing: Item {
    id: ring
    property bool active: false
    property real size: Style.space(16)

    implicitWidth: size
    implicitHeight: size
    visible: active

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: "transparent"
      border.width: Style.spacing.hairline
      border.color: root.foreground
      opacity: 0.28
    }

    Rectangle {
      width: ring.size * 0.3
      height: width
      radius: width / 2
      anchors.horizontalCenter: parent.horizontalCenter
      y: 0
      color: root.foreground
    }

    RotationAnimation on rotation {
      from: 0
      to: 360
      duration: 700
      loops: Animation.Infinite
      running: ring.active
    }
  }

  // One option of a group. The selected fill carries the state, so a chip needs
  // no tick; while a change is in flight the label fades under the spinner
  // rather than the chip resizing and nudging its neighbours.
  component OptionChip: CursorSurface {
    id: chip
    property string label: ""
    property string name: ""
    property bool selected: false

    readonly property bool pending: ear.pendingRow === name

    hasCursor: root.rowHasCursor(name)
    current: selected
    bordered: true
    foreground: root.foreground
    implicitWidth: chipLabel.implicitWidth + Style.spacing.controlPaddingX * 2
    implicitHeight: chipLabel.implicitHeight + Style.spacing.controlPaddingY * 2
    Layout.minimumWidth: Style.space(60)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.focusRow(chip.name)
      onClicked: root.activate(chip.name)
    }

    Text {
      id: chipLabel
      anchors.centerIn: parent
      width: Math.min(implicitWidth, chip.width - Style.spacing.controlPaddingX * 2)
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      text: chip.label
      color: root.foreground
      opacity: chip.pending ? 0.0 : (chip.selected ? 1.0 : 0.7)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    LoadingRing {
      anchors.centerIn: parent
      active: chip.pending
    }
  }

  component ToggleRow: CursorSurface {
    id: toggleRow
    property string label: ""
    property string name: ""
    property bool checked: false

    readonly property bool pending: ear.pendingRow === name

    hasCursor: root.rowHasCursor(name)
    foreground: root.foreground
    implicitHeight: switchSlot.implicitHeight + Style.spacing.lg

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.focusRow(toggleRow.name)
      onClicked: root.activate(toggleRow.name)
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.xl
      anchors.right: switchSlot.left
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      text: toggleRow.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Item {
      id: switchSlot
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.xl
      anchors.verticalCenter: parent.verticalCenter
      implicitWidth: Style.space(42)
      implicitHeight: Style.space(22)

      ToggleSwitch {
        anchors.centerIn: parent
        visible: !toggleRow.pending
        interactive: false
        checked: toggleRow.checked
        hasCursor: toggleRow.hasCursor
        foreground: root.foreground
      }

      LoadingRing {
        anchors.centerIn: parent
        active: toggleRow.pending
      }
    }
  }
}
