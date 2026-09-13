// Exercise the pure JS in Model.js against real CLI shapes, the way the panel
// uses it: auto-detection must pick the right pair without being told.
const fs = require('fs')
const path = require('path').join(__dirname, '..')

let src = fs.readFileSync(path + '/Model.js', 'utf8')
src += '\nmodule.exports={nothingDevices,resolveDevice,findDevice,addressFromSinkName,parseSinkList,LEVEL_UNKNOWN};'
const mod = { exports: {} }
new Function('module', 'exports', src)(mod, mod.exports)
const M = mod.exports

const OPEN = '3C:B0:ED:51:18:FD'
const EAR3 = '2C:BE:EE:4B:CF:24'

function dev(address, name, connected) {
  return { address, deviceName: name, connected, paired: true, batteryAvailable: true, battery: 0.95 }
}
const bothConnected = [dev(OPEN, 'Nothing Ear (open)', true), dev(EAR3, 'Nothing Ear (3)', true)]
const onlyOpen = [dev(OPEN, 'Nothing Ear (open)', true), dev(EAR3, 'Nothing Ear (3)', false)]

let failures = 0
function check(label, actual, expected) {
  const ok = actual === expected
  if (!ok) failures++
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}: ${JSON.stringify(actual)}${ok ? '' : ' != ' + JSON.stringify(expected)}`)
}

// device list
check('paired list drops unpaired', M.nothingDevices([dev(OPEN, 'Nothing Ear (open)', true), { address: 'AA:BB:CC:DD:EE:FF', name: 'Nothing X', paired: false, connected: false }]).length, 1)
check('device list keeps only Nothing names', M.nothingDevices([dev(OPEN, 'Nothing Ear (open)', true), dev('11:22:33:44:55:66', 'Jabra Elite', true)]).length, 1)
check('battery is a percent', M.nothingDevices([dev(OPEN, 'Nothing Ear (open)', true)])[0].battery, 95)

// sink parsing, with the shape pactl actually prints (index, name, driver, spec, state).
// The playing pair is deliberately SECOND in the list, so "it picked the first
// bluez sink" cannot masquerade as "it picked the pair carrying audio".
const sinks = [
  '1405\tbluez_output.3C_B0_ED_51_18_FD.1\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED',
  '1634\tbluez_output.2C_BE_EE_4B_CF_24.1\tPipeWire\ts16le 2ch 48000Hz\tRUNNING',
  '60\talsa_output.pci-0000_05_00.6.HiFi__Speaker__sink\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED',
].join('\n')
check('sink name -> address', M.addressFromSinkName('bluez_output.2C_BE_EE_4B_CF_24.1'), EAR3)
check('non-bluez sink -> empty', M.addressFromSinkName('alsa_output.pci-0000_05_00.6.HiFi__Speaker__sink'), '')
check('playing sink wins', M.parseSinkList('bluez_output.2C_BE_EE_4B_CF_24.1\n---\n' + sinks), EAR3)
check('default sink when nothing plays',
  M.parseSinkList('bluez_output.2C_BE_EE_4B_CF_24.1\n---\n' + sinks.replace('RUNNING', 'SUSPENDED')), EAR3)
check('no bluez sink -> empty', M.parseSinkList('alsa_output.pci-0000_05_00.6.HiFi__Speaker__sink\n---\nalsa_output.pci-0000_05_00.6.HiFi__Speaker__sink\tPipeWire\ts16le 2ch 48000Hz\tRUNNING'), '')

// resolution
check('one connected pair is used', M.resolveDevice(onlyOpen, '', '').address, OPEN)
check('audio picks the playing pair', M.resolveDevice(bothConnected, '', EAR3).address, EAR3)
check('pinned address beats audio', M.resolveDevice(bothConnected, EAR3, OPEN).address, EAR3)
check('pinned address survives being away', M.resolveDevice(onlyOpen, EAR3, '').address, EAR3)
check('no known pair -> null', M.resolveDevice([], '', ''), null)

console.log(failures === 0 ? 'ALL PASS' : failures + ' FAILURES')
process.exit(failures === 0 ? 0 : 1)
