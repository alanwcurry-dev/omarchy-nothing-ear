import QtQuick
import Quickshell.Io
import Quickshell.Bluetooth
import "Model.js" as Model

// Owns everything the panel and the bar icon display. Nothing here talks to
// the earbuds directly: each state change is one short-lived call to
// nothing-earctl.py, which opens the Nothing control channel, does one
// exchange, and closes it again.
Item {
  id: root

  property var settings: ({})

  property bool connected: false
  property bool protocol: false
  property bool deviceKnown: false
  property string deviceName: ""
  property string deviceAddress: ""
  property var leftBud: Model.battery()
  property var rightBud: Model.battery()
  property var caseBattery: Model.battery()
  property var headsetBattery: Model.battery()
  property int aggregateBattery: Model.LEVEL_UNKNOWN
  property bool wearAvailable: false
  property var wearLeft: null
  property var wearRight: null
  property bool noiseAvailable: false
  property string noiseKey: ""
  property bool eqAvailable: false
  property string eqKey: ""
  property bool bassAvailable: false
  property bool bassEnabled: false
  property int bassLevel: 0
  property bool latencyAvailable: false
  property bool latencyEnabled: false
  property string firmware: ""
  property string protocolVersion: ""
  property var dualConnection: null
  property var inEarDetection: null
  property bool codecAvailable: false
  property string activeCodec: "unknown"
  property var codecOptions: []
  property string deviceCodecMode: "Unknown"
  property string lastError: ""

  // Find-my-earbuds state. The firmware keeps ringing until it is told to
  // stop, so the service owns the flag and stops it on a timer, on a
  // disconnect, and when the panel closes.
  property bool ringLeft: false
  property bool ringRight: false

  // A control change carries the row it belongs to so that row can show a
  // spinner until the firmware confirms the new value.
  property var pendingAction: null
  property var queuedAction: null
  property bool refreshQueued: false
  property bool retryArmed: true

  readonly property int minimumVisibleMs: 600
  readonly property int pendingTimeoutMs: 5000
  readonly property int retryDelayMs: 1500

  readonly property string defaultHelperPath:
    Qt.resolvedUrl("nothing-earctl.py").toString().replace(/^file:\/\//, "")
  readonly property string helperPath: String(setting("helperPath", defaultHelperPath) || defaultHelperPath)
  // How often the bar icon refreshes the battery on its own while connected.
  readonly property int refreshSeconds: Math.max(15, Math.min(900, Number(setting("refreshSeconds", 60)) || 60))

  // Which paired earbuds this widget talks to, without anyone choosing: the
  // pair carrying audio wins, then any connected pair, so putting one set down
  // and picking up the other just works.
  readonly property string pinnedAddress: String(setting("deviceAddress", "") || "")
  property string selectedAddress: ""
  readonly property var bluezDevices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property var nothingDevices: Model.nothingDevices(bluezDevices)
  readonly property int connectedCount: countConnected(nothingDevices)
  readonly property string requestedAddress: pinnedAddress !== "" ? pinnedAddress : selectedAddress
  // The pair PipeWire is routing to, only needed when several are connected.
  property string audioAddress: ""
  readonly property bool needsAudioProbe: requestedAddress === "" && connectedCount > 1
  readonly property var targetDevice: Model.resolveDevice(nothingDevices, requestedAddress, audioAddress)
  readonly property string targetAddress: targetDevice ? String(targetDevice.address || "") : ""
  readonly property bool bluezConnected: !!(targetDevice && targetDevice.connected)
  // The aggregate battery BlueZ itself reports for the target, used only to
  // notice that the earbuds' own reading has probably changed.
  readonly property real targetBattery: targetDevice && targetDevice.batteryAvailable
    ? targetDevice.battery : -1

  readonly property bool applying: actionProcess.running || queuedAction !== null
  readonly property bool hasBattery: Model.anyBattery(leftBud, rightBud, caseBattery, headsetBattery, aggregateBattery)
  readonly property bool hasControls: connected && protocol
  readonly property bool ringing: ringLeft || ringRight
  readonly property string pendingRow: !pendingAction
    ? ""
    : pendingAction.row

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function commandFor(args) {
    // System Python, because a version manager's python3 may be built without
    // Bluetooth socket support. The device is always named explicitly so the
    // helper cannot pick a different pair than the panel is showing.
    var command = ["/usr/bin/python3", helperPath]
    if (targetAddress !== "") command.push("--device", targetAddress)
    for (var i = 0; i < args.length; i++) command.push(args[i])
    return command
  }

  // Switch which earbuds the widget follows. No UI needs this: the widget
  // detects the pair by itself, and this exists for scripts and for pinning a
  // choice that must survive a swap.
  function selectDevice(query) {
    var found = Model.findDevice(nothingDevices, query)
    if (!found) return false
    selectedAddress = found.address
    forgetDevice()
    refresh()
    return true
  }

  // Back to detecting the pair by itself.
  function clearSelection() {
    selectedAddress = ""
    refresh()
    return true
  }

  // What the panel lists when more than one pair is known.
  function deviceList() {
    return nothingDevices.map(function (device) {
      return {
        address: device.address,
        name: device.name,
        connected: device.connected,
        battery: device.battery
      }
    })
  }

  function countConnected(devices) {
    var count = 0
    var list = devices || []
    for (var i = 0; i < list.length; i++)
      if (list[i].connected) count++
    return count
  }

  // Only asked when two pairs are connected at once: the one the desktop is
  // playing through — or, failing that, the one it defaults to — is the best
  // guess at which pair is on someone's head.
  function runAudioProbe() {
    if (!needsAudioProbe) {
      audioAddress = ""
      return
    }
    if (!audioProbe.running) audioProbe.running = true
  }

  function parseSinks(text) {
    audioAddress = Model.parseSinkList(text)
  }

  // One process at a time: the control channel is a single slot, so a read
  // asked for while another call runs is remembered and taken next instead of
  // dropped — a device switch must not land on a stale reading.
  function refresh() {
    if (statusProcess.running || actionProcess.running) {
      refreshQueued = true
      return
    }
    refreshQueued = false
    statusProcess.command = commandFor(["status"])
    statusProcess.running = true
  }

  function assign(target, values) {
    for (var key in values) target[key] = values[key]
  }

  function beginPending(row, value, next, previous) {
    pendingAction = {
      row: row,
      value: value,
      next: next,
      previous: previous,
      startedAt: Date.now(),
      confirmed: false
    }
    assign(root, next)
    pendingTimer.restart()
  }

  function clearPending() {
    pendingTimer.stop()
    pendingMinimumTimer.stop()
    pendingAction = null
  }

  function pendingSatisfied(status) {
    var pending = pendingAction
    if (!pending) return true
    if (pending.row.indexOf("anc:") === 0) return status.noiseKey === pending.value
    if (pending.row.indexOf("eq:") === 0) return status.eqKey === pending.value
    if (pending.row === "bass") return status.bassEnabled === pending.value
    if (pending.row === "latency") return status.latencyEnabled === pending.value
    if (pending.row.indexOf("codec:") === 0) return status.activeCodec === pending.value
    if (pending.row.indexOf("find:") === 0) return true
    return true
  }

  function overlayPending(status) {
    var pending = pendingAction
    if (!pending) return
    if (!pendingSatisfied(status)) {
      // The firmware has not caught up yet: keep the requested value, and the
      // spinner with it, on screen.
      pending.confirmed = false
      assign(status, pending.next)
      return
    }
    // A spinner that flashes for a few milliseconds reads as a glitch, so hold
    // it until it has been visible for at least minimumVisibleMs.
    var age = Date.now() - pending.startedAt
    if (age >= minimumVisibleMs) {
      clearPending()
      return
    }
    pending.confirmed = true
    pendingMinimumTimer.interval = minimumVisibleMs - age
    pendingMinimumTimer.restart()
  }

  function revertPending() {
    if (!pendingAction) return
    assign(root, pendingAction.previous)
    clearPending()
  }

  function applyStatus(raw) {
    var status = Model.parseStatus(raw)
    if (!status.ok) {
      lastError = status.lastError
      return
    }

    overlayPending(status)

    // Bluetooth and the host report through to the panel whether or not the
    // earbuds' own control channel answers.
    connected = status.connected
    deviceKnown = status.deviceAddress !== ""
    deviceName = status.deviceName
    deviceAddress = status.deviceAddress
    aggregateBattery = status.aggregate
    codecAvailable = status.codecAvailable
    activeCodec = status.activeCodec
    codecOptions = status.codecOptions
    deviceCodecMode = status.deviceCodecMode

    if (!status.connected) {
      forgetDevice()
      lastError = Model.errorText(status.lastError)
      return
    }

    // A refresh that lands right after a control change often finds the
    // channel still busy and comes back "connected, no protocol". Keeping the
    // last reading costs nothing and spares the panel a full rebuild, which
    // would move every row under the pointer for a second.
    if (!status.protocol) {
      if (!protocol) lastError = Model.errorText(status.lastError)
      if (retryArmed) {
        retryArmed = false
        retryTimer.restart()
      }
      return
    }

    retryArmed = false
    lastError = Model.errorText(status.lastError)
    protocol = true
    leftBud = status.left
    rightBud = status.right
    caseBattery = status.caseBattery
    headsetBattery = status.headset
    wearAvailable = status.wearAvailable
    wearLeft = status.wearLeft
    wearRight = status.wearRight
    noiseAvailable = status.noiseAvailable
    noiseKey = status.noiseKey
    eqAvailable = status.eqAvailable
    eqKey = status.eqKey
    bassAvailable = status.bassAvailable
    bassEnabled = status.bassEnabled
    bassLevel = status.bassLevel
    latencyAvailable = status.latencyAvailable
    latencyEnabled = status.latencyEnabled
    firmware = status.firmware
    protocolVersion = status.protocolVersion
    dualConnection = status.dualConnection
    inEarDetection = status.inEarDetection
  }

  // The earbuds are away: everything the control channel fed is unknown, and
  // a ring still going has nothing left to ring.
  function forgetDevice() {
    protocol = false
    leftBud = Model.battery()
    rightBud = Model.battery()
    caseBattery = Model.battery()
    headsetBattery = Model.battery()
    wearAvailable = false
    wearLeft = null
    wearRight = null
    noiseAvailable = false
    noiseKey = ""
    eqAvailable = false
    eqKey = ""
    bassAvailable = false
    bassEnabled = false
    latencyAvailable = false
    latencyEnabled = false
    firmware = ""
    protocolVersion = ""
    dualConnection = null
    inEarDetection = null
    queuedAction = null
    ringLeft = false
    ringRight = false
    ringTimer.stop()
    clearPending()
  }

  function failedStatus(message) {
    lastError = Model.errorText(message || "Could not query the Nothing device")
  }

  // A status read holds the channel for well under a second, which is long
  // enough to swallow the first click after the panel opens. Queue the change
  // instead of dropping it: the panel already shows the new value.
  function runAction(args) {
    if (statusProcess.running) {
      queuedAction = args
      return
    }
    actionProcess.command = commandFor(args)
    actionProcess.running = true
  }

  function setAnc(key) {
    // Open-ear models (Ear (open)) have no noise control at all.
    if (!hasControls || !noiseAvailable || applying) return
    beginPending("anc:" + key, key, { noiseKey: key }, { noiseKey: noiseKey })
    runAction(["set-anc", key])
  }

  function cycleAnc() {
    if (!hasControls || !noiseAvailable) return
    setAnc(Model.ANC_VALUES[Model.cycleIndex(Model.ANC_VALUES, noiseKey)])
  }

  function setEq(key) {
    if (!hasControls || !eqAvailable || applying) return
    beginPending("eq:" + key, key, { eqKey: key }, { eqKey: eqKey })
    runAction(["set-eq", key])
  }

  function cycleEq() {
    if (!hasControls || !eqAvailable) return
    setEq(Model.EQ_VALUES[Model.cycleIndex(Model.EQ_VALUES, eqKey)])
  }

  function setBass(enabled) {
    if (!hasControls || !bassAvailable || applying) return
    beginPending("bass", enabled, { bassEnabled: enabled }, { bassEnabled: bassEnabled })
    runAction(["set-bass", enabled ? "on" : "off"])
  }

  function setLatency(enabled) {
    if (!hasControls || !latencyAvailable || applying) return
    beginPending("latency", enabled, { latencyEnabled: enabled }, { latencyEnabled: latencyEnabled })
    runAction(["set-latency", enabled ? "on" : "off"])
  }

  function setCodec(key) {
    if (!connected || !codecAvailable || applying) return
    beginPending("codec:" + key, key, { activeCodec: key }, { activeCodec: activeCodec })
    runAction(["set-codec", key])
  }

  function cycleCodec() {
    if (!codecAvailable || codecOptions.length === 0) return
    var keys = codecOptions.map(function (option) { return option.key })
    setCodec(keys[Model.cycleIndex(keys, activeCodec)])
  }

  function ring(side, on) {
    if (!hasControls || applying) return
    var previous = side === "left" ? { ringLeft: ringLeft } : { ringRight: ringRight }
    var next = side === "left" ? { ringLeft: on } : { ringRight: on }
    beginPending("find:" + side, on, next, previous)
    runAction(["set-find", side, on ? "on" : "off"])
    if (on && !ringTimer.running) ringTimer.restart()
  }

  function toggleRing(side) {
    ring(side, side === "left" ? !ringLeft : !ringRight)
  }

  // Nothing keeps the firmware ringing in the background, so every path that
  // ends the interaction tells the earbuds to stop.
  function stopRings() {
    ringTimer.stop()
    if (ringRight) ring("right", false)
    if (ringLeft) ring("left", false)
  }

  Component.onCompleted: refresh()

  onBluezConnectedChanged: {
    if (root.bluezConnected) root.retryArmed = true
    if (root.bluezConnected !== root.connected) root.refresh()
  }

  onTargetBatteryChanged: if (root.bluezConnected) root.refresh()
  onTargetAddressChanged: if (root.bluezConnected) root.refresh()
  onSelectedAddressChanged: root.refresh()

  Timer {
    id: pollTimer
    interval: root.refreshSeconds * 1000
    repeat: true
    running: root.bluezConnected
    onTriggered: root.refresh()
  }

  Timer {
    id: settleTimer
    interval: 250
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: retryTimer
    interval: root.retryDelayMs
    repeat: false
    onTriggered: root.refresh()
  }

  // Ringing is loud and the panel may already be closed, so it stops on its
  // own after a short while.
  Timer {
    id: ringTimer
    interval: 20000
    repeat: false
    onTriggered: {
      if (root.ringLeft) root.ring("left", false)
      if (root.ringRight) root.ring("right", false)
    }
  }

  Timer {
    id: pendingTimer
    interval: root.pendingTimeoutMs
    repeat: false
    onTriggered: {
      root.pendingAction = null
      root.refresh()
    }
  }

  Timer {
    id: pendingMinimumTimer
    interval: root.minimumVisibleMs
    repeat: false
    onTriggered: {
      if (root.pendingAction && root.pendingAction.confirmed) root.clearPending()
    }
  }

  // Re-asked only while two pairs are connected, so the widget follows the
  // audio when someone swaps earbuds mid-session.
  onNeedsAudioProbeChanged: root.runAudioProbe()

  Timer {
    id: audioProbeTimer
    interval: 15000
    repeat: true
    running: root.needsAudioProbe
    onTriggered: root.runAudioProbe()
  }

  Process {
    id: audioProbe
    command: ["sh", "-c", "pactl get-default-sink; echo ---; pactl list short sinks"]
    stdout: StdioCollector { id: audioProbeOut; waitForEnd: true }
    onExited: function () { root.parseSinks(String(audioProbeOut.text || "")) }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function (exitCode) {
      var stdout = String(statusStdout.text || "")
      var stderr = String(statusStderr.text || "")
      if (exitCode === 0) root.applyStatus(stdout)
      else root.failedStatus(stderr || stdout)
      if (root.queuedAction !== null) {
        var next = root.queuedAction
        root.queuedAction = null
        root.runAction(next)
      }
      if (root.refreshQueued) {
        root.refreshQueued = false
        root.refresh()
      }
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function (exitCode) {
      var stdout = String(actionStdout.text || "")
      var stderr = String(actionStderr.text || "")
      if (exitCode === 0) {
        root.lastError = ""
      } else {
        root.revertPending()
        root.lastError = Model.errorText(stderr || stdout || "The device rejected the change")
      }
      settleTimer.restart()
    }
  }
}
