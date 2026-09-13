// Parsing and formatting for the Nothing Ear helper's JSON, kept out of QML so
// the data contract has one home and stays testable on its own.

var LEVEL_UNKNOWN = -1
var SUPPORTED_SCHEMA = 1

// Panel order: quietest first, then the noise-cancelling strengths.
var ANC_VALUES = ["off", "transparency", "adaptive", "low", "mid", "high"]
var ANC_LABELS = {
  off: "Off",
  transparency: "Transparency",
  adaptive: "Adaptive",
  low: "Low",
  mid: "Medium",
  high: "High"
}

// The firmware's preset numbering, as the phone app sends it.
var EQ_VALUES = ["balanced", "voice", "treble", "bass", "custom"]
var EQ_LABELS = {
  balanced: "Balanced",
  voice: "Voice",
  treble: "More treble",
  bass: "More bass",
  custom: "Custom"
}
var EQ_WIRE = { balanced: 0, voice: 1, treble: 2, bass: 3, advanced: 4, custom: 5 }

var BASS_MAX_LEVEL = 5

function battery() {
  return { level: LEVEL_UNKNOWN, charging: false, available: false, stale: false }
}

function defaultStatus() {
  return {
    ok: false,
    connected: false,
    protocol: false,
    deviceName: "",
    deviceAddress: "",
    left: battery(),
    right: battery(),
    caseBattery: battery(),
    // Headphones report one battery for the whole device instead of per bud.
    headset: battery(),
    aggregate: LEVEL_UNKNOWN,
    wearAvailable: false,
    wearLeft: null,
    wearRight: null,
    noiseAvailable: false,
    noiseKey: "",
    eqAvailable: false,
    eqKey: "",
    bassAvailable: false,
    bassEnabled: false,
    bassLevel: 0,
    latencyAvailable: false,
    latencyEnabled: false,
    firmware: "",
    protocolVersion: "",
    dualConnection: null,
    inEarDetection: null,
    codecAvailable: false,
    activeCodec: "unknown",
    codecOptions: [],
    deviceCodecCode: LEVEL_UNKNOWN,
    deviceCodecMode: "Unknown",
    lastError: "",
    schemaTooNew: false
  }
}

function integer(value, fallback) {
  var number = Number(value)
  return isFinite(number) ? Math.round(number) : fallback
}

function bool(value, fallback) {
  if (value === true || value === false) return value
  return fallback
}

function component(raw, fallback) {
  var source = raw && typeof raw === "object" ? raw : {}
  var level = integer(source.level, LEVEL_UNKNOWN)
  return {
    level: level >= 0 && level <= 100 ? level : LEVEL_UNKNOWN,
    charging: bool(source.charging, false),
    available: bool(source.available, false) && level >= 0 && level <= 100,
    stale: bool(source.stale, false)
  }
}

function parseStatus(text) {
  var status = defaultStatus()
  var raw
  try {
    raw = JSON.parse(String(text))
  } catch (error) {
    status.lastError = "The helper did not return readable JSON"
    return status
  }
  if (!raw || typeof raw !== "object") {
    status.lastError = "The helper returned nothing"
    return status
  }

  var schema = integer(raw.schema_version, SUPPORTED_SCHEMA)
  if (schema > SUPPORTED_SCHEMA) status.schemaTooNew = true

  var device = raw.device && typeof raw.device === "object" ? raw.device : {}
  var batteryRaw = raw.battery && typeof raw.battery === "object" ? raw.battery : {}
  var wear = raw.wear && typeof raw.wear === "object" ? raw.wear : {}
  var noise = raw.noise && typeof raw.noise === "object" ? raw.noise : {}
  var eq = raw.eq && typeof raw.eq === "object" ? raw.eq : {}
  var bass = raw.bass && typeof raw.bass === "object" ? raw.bass : {}
  var latency = raw.latency && typeof raw.latency === "object" ? raw.latency : {}
  var codec = raw.codec && typeof raw.codec === "object" ? raw.codec : {}
  var features = raw.features && typeof raw.features === "object" ? raw.features : {}

  status.ok = true
  status.connected = bool(raw.connected, false)
  status.protocol = bool(raw.protocol, false)
  status.deviceName = String(device.name || "")
  status.deviceAddress = String(device.address || "")

  status.left = component(batteryRaw.left)
  status.right = component(batteryRaw.right)
  status.caseBattery = component(batteryRaw.case)
  status.headset = component(batteryRaw.headset)
  status.aggregate = integer(batteryRaw.aggregate, LEVEL_UNKNOWN)

  status.wearAvailable = bool(wear.available, false)
  status.wearLeft = wear.left === true ? true : (wear.left === false ? false : null)
  status.wearRight = wear.right === true ? true : (wear.right === false ? false : null)

  status.noiseAvailable = bool(noise.available, false)
  status.noiseKey = String(noise.key || "")
  status.eqAvailable = bool(eq.available, false)
  status.eqKey = String(eq.preset || "")
  status.bassAvailable = bool(bass.available, false)
  status.bassEnabled = bool(bass.enabled, false)
  status.bassLevel = integer(bass.level, 0)
  status.latencyAvailable = bool(latency.available, false)
  status.latencyEnabled = bool(latency.enabled, false)

  status.firmware = String(raw.firmware || "")
  status.protocolVersion = String(raw.protocol_version || "")
  status.dualConnection = features.dual_connection === true
    ? true
    : (features.dual_connection === false ? false : null)
  status.inEarDetection = features.in_ear_detection === true
    ? true
    : (features.in_ear_detection === false ? false : null)

  status.codecAvailable = bool(codec.available, false)
  status.activeCodec = String(codec.active || "unknown")
  status.codecOptions = Array.isArray(codec.options) ? codec.options : []
  status.deviceCodecCode = integer(codec.device_code, LEVEL_UNKNOWN)
  status.deviceCodecMode = String(codec.device_mode || "Unknown")

  status.lastError = String(raw.error || "")
  return status
}

// A helper that cannot run says nothing about the earbuds, so its stderr is
// summarised rather than shown raw.
function errorText(message) {
  var text = String(message || "").trim()
  if (text === "") return ""
  var line = text.split("\n").filter(function (item) { return item.trim() !== "" })
  if (line.length === 0) return ""
  var first = line[line.length - 1].replace(/^Traceback.*$/, "The helper failed to run")
  return first.length > 180 ? first.substring(0, 177) + "..." : first
}

function levelFraction(level) {
  if (level === LEVEL_UNKNOWN || !isFinite(level)) return 0
  return Math.max(0, Math.min(100, level)) / 100
}

function levelText(level) {
  return level === LEVEL_UNKNOWN ? "--" : String(level) + "%"
}

function ancLabel(key) {
  return ANC_LABELS[key] || (key === "anc" ? "Noise cancelling" : "Unknown")
}

function eqLabel(key) {
  return EQ_LABELS[key] || (key === "advanced" ? "Advanced" : "Unknown")
}

function cycleIndex(values, current) {
  var index = values.indexOf(current)
  return index < 0 ? 0 : (index + 1) % values.length
}

// The panel and the service hand readings around as objects, so the helpers
// take them explicitly instead of guessing at a property name — a dynamic
// lookup on a QML object is not the same thing as one on parsed JSON.
function available(reading) {
  return !!(reading && reading.available)
}

// The smallest available bud reading — the number worth putting on the bar.
function lowestBudLevel(left, right, headset) {
  if (available(headset)) return headset.level
  var levels = []
  if (available(left)) levels.push(left.level)
  if (available(right)) levels.push(right.level)
  if (levels.length === 0) return LEVEL_UNKNOWN
  return Math.min.apply(null, levels)
}

function anyBattery(left, right, caseReading, headset, aggregate) {
  return available(left) || available(right) || available(caseReading) || available(headset)
    || integer(aggregate, LEVEL_UNKNOWN) !== LEVEL_UNKNOWN
}

// "In ear", "Out of ear", or nothing when the device does not report wear.
function wearText(worn) {
  if (worn === true) return "in ear"
  if (worn === false) return "out of ear"
  return ""
}

function anyCharging(left, right, caseReading, headset) {
  return charging(left) || charging(right) || charging(caseReading) || charging(headset)
}

function charging(reading) {
  return !!(reading && reading.charging)
}
