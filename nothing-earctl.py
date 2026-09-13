#!/usr/bin/python3
"""Talk to Nothing Ear earbuds over the Nothing X RFCOMM control channel.

The Nothing X protocol runs as a small binary protocol on an RFCOMM (serial
port profile) channel.  Every call in this helper is short-lived: it opens the
channel, performs one exchange, and closes it again, so nothing keeps the
earbuds' single control slot busy while the desktop is idle.

Commands
    status                        full snapshot as one line of JSON
    set-anc <mode>                off | transparency | adaptive | low | mid | high
    set-eq <preset>               balanced | voice | treble | bass | custom
    set-bass on|off               bass enhancement at the level the device has
    set-latency on|off            low-latency mode
    set-find left|right on|off    ring that earbud (find my earbuds)
    set-codec <key>               host-side PipeWire A2DP codec
    diagnose                      raw hex payloads for the control channel

Only `status` runs unattended; the rest are always the result of a click.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import struct
import subprocess
import time
from pathlib import Path
from typing import Iterable

# --- wire format -----------------------------------------------------------

SOF = 0x55
CTRL_WITH_CRC = 0x0160
RFCOMM_CHANNEL = 15

DIR_GET = 0xC0
DIR_SET = 0xF0
DIR_RESPONSE = 0x40
DIR_ACK = 0x70

CMD_PROTOCOL = 0x01
CMD_REMOTE_CONFIG = 0x06
CMD_BATTERY = 0x07
CMD_WEAR = 0x0A
CMD_IN_EAR = 0x0E
CMD_GESTURES = 0x18
CMD_ANC_GET = 0x1E
CMD_EQ_GET = 0x1F
CMD_DUAL_GET = 0x27
CMD_CODEC_GET = 0x29
CMD_LATENCY_GET = 0x41
CMD_FIRMWARE = 0x42
CMD_BASS_GET = 0x4E
CMD_ACTIVATE = 0x01
CMD_SET_ANC = 0x0F
CMD_SET_EQ = 0x10
CMD_SET_FIND = 0x02
CMD_SET_LATENCY = 0x40
CMD_SET_BASS = 0x51

# ANC is sent as (mode, level) but the firmware treats the pair as one value:
# a strength carries its own mode, and off/transparency have no strength.
ANC_WIRE = {
    "high": 1,
    "mid": 2,
    "low": 3,
    "adaptive": 4,
    "off": 5,
    "transparency": 7,
}
ANC_WIRE_KEY = {1: "high", 2: "mid", 3: "low", 4: "adaptive", 5: "off", 0: "off", 7: "transparency"}

EQ_WIRE = {"balanced": 0, "voice": 1, "treble": 2, "bass": 3, "custom": 5}
EQ_WIRE_KEY = {0: "balanced", 1: "voice", 2: "treble", 3: "bass", 4: "advanced", 5: "custom"}

# Battery components as the firmware numbers them.
COMPONENT_LEFT = 2
COMPONENT_RIGHT = 3
COMPONENT_CASE = 4
COMPONENT_HEADSET = 6

SIDE_WIRE = {"left": COMPONENT_LEFT, "right": COMPONENT_RIGHT}

# Battery components as the firmware numbers them / wear bit.
WEAR_IN_EAR_BIT = 0x04

CODEC_LABELS = {
    "sbc": "SBC",
    "sbc_xq": "SBC-XQ",
    "aac": "AAC",
    "ldac": "LDAC",
    "lhdc": "LHDC",
    "aptx": "aptX",
    "aptx_hd": "aptX HD",
    "aptx_ll": "aptX LL",
}
DEVICE_CODEC_LABELS = {0: "Standard", 1: "LHDC", 2: "LDAC"}

# A case only reports while it is open.  A reading that is hours old must not be
# presented as live, so it expires rather than lingering all day.
CASE_CACHE_MAX_AGE = 6 * 3600

ADDRESS_RE = re.compile(r"^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$")


def crc16(data: bytes) -> int:
    """CRC-16/MODBUS, as the Nothing protocol uses it."""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc & 0xFFFF


def packet(command: int, direction: int, payload: bytes = b"", operation: int = 1) -> bytes:
    wire_command = (command & 0xFF) | ((direction & 0xFF) << 8)
    body = (
        struct.pack("<BHHH", SOF, CTRL_WITH_CRC, wire_command, len(payload))
        + bytes([operation & 0xFF])
        + payload
    )
    return body + struct.pack("<H", crc16(body))


class Frame:
    __slots__ = ("command", "direction", "payload")

    def __init__(self, command: int, direction: int, payload: bytes):
        self.command = command
        self.direction = direction
        self.payload = payload


class FrameParser:
    """Reassembles frames from a byte stream, discarding anything before 0x55."""

    def __init__(self) -> None:
        self.buffer = bytearray()

    def feed(self, data: bytes) -> None:
        self.buffer.extend(data)

    def frames(self) -> Iterable[Frame]:
        while True:
            try:
                start = self.buffer.index(SOF)
            except ValueError:
                self.buffer.clear()
                return
            if start:
                del self.buffer[:start]
            if len(self.buffer) < 8:
                return
            # 0x55, ctrl (2), command (2), payload length (2), operation (1).
            _, ctrl, command, length = struct.unpack_from("<BHHH", self.buffer)
            total = 8 + length + (2 if ctrl & 0x20 else 0)
            if len(self.buffer) < total:
                return
            raw = bytes(self.buffer[:total])
            del self.buffer[:total]
            yield Frame(command & 0xFF, (command >> 8) & 0xFF, raw[8 : 8 + length])


def exchange(sock: socket.socket, parser: FrameParser, command: int, direction: int = DIR_GET,
             payload: bytes = b"", timeout: float = 1.5) -> bytes | None:
    """Send one frame and return the matching response payload, or None."""
    try:
        sock.sendall(packet(command, direction, payload))
    except OSError:
        return None
    deadline = time.monotonic() + timeout
    wanted = command & 0xFF
    while time.monotonic() < deadline:
        for frame in parser.frames():
            if frame.command == wanted and frame.direction in (DIR_RESPONSE, DIR_ACK):
                return frame.payload
        sock.settimeout(max(0.05, min(0.25, deadline - time.monotonic())))
        try:
            data = sock.recv(512)
        except (socket.timeout, TimeoutError):
            continue
        except OSError:
            return None
        if not data:
            return None
        parser.feed(data)
    return None


def open_channel(address: str) -> socket.socket:
    sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
    sock.settimeout(2.0)
    try:
        sock.connect((address, RFCOMM_CHANNEL))
    except Exception:
        sock.close()
        raise
    return sock


# --- device lookup ---------------------------------------------------------


def bluetoothctl(*args: str) -> str:
    try:
        result = subprocess.run(
            ["bluetoothctl", *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout


def paired_devices() -> list[dict[str, str]]:
    """Bonded devices only, so a pair that is merely in range is never picked."""
    output = bluetoothctl("devices", "Paired")
    if not output.strip():
        output = bluetoothctl("devices")
    devices = []
    for line in output.splitlines():
        parts = line.split(" ", 2)
        if len(parts) == 3 and parts[0] == "Device" and ADDRESS_RE.match(parts[1]):
            devices.append({"address": parts[1], "name": parts[2].strip()})
    return devices


def is_connected(address: str) -> bool:
    return re.search(r"^\s*Connected:\s*yes\s*$", bluetoothctl("info", address), re.M) is not None


def looks_like_nothing(name: str) -> bool:
    value = name.lower()
    return "nothing" in value or "ear" in value or "cmf" in value


def choose_device(requested: str = "") -> dict[str, str] | None:
    devices = paired_devices()
    if requested:
        wanted = requested.lower()
        for device in devices:
            if device["address"].lower() == wanted or device["name"].lower() == wanted:
                return device
        if ADDRESS_RE.match(requested):
            return {"address": requested.upper(), "name": "Nothing device"}
        return None
    connected = [d for d in devices if looks_like_nothing(d["name"]) and is_connected(d["address"])]
    if connected:
        return connected[0]
    known = [d for d in devices if looks_like_nothing(d["name"])]
    return known[0] if known else None


def nothing_device_list() -> list[dict[str, object]]:
    """Every paired Nothing-family device, connected ones first."""
    found: list[dict[str, object]] = []
    for device in paired_devices():
        if not looks_like_nothing(device["name"]):
            continue
        found.append({
            "address": device["address"],
            "name": device["name"],
            "connected": is_connected(device["address"]),
            "battery": aggregate_battery(device["address"]),
        })
    found.sort(key=lambda item: (not item["connected"], str(item["name"])))
    return found


def aggregate_battery(address: str) -> int:
    """The single percentage BlueZ exposes; the fallback when the channel is busy."""
    match = re.search(
        r"Battery Percentage:\s*0x[0-9a-f]+\s*\((\d+)\)", bluetoothctl("info", address), re.I
    )
    return int(match.group(1)) if match else -1


# --- parsing ---------------------------------------------------------------


def unknown_battery() -> dict[str, object]:
    return {"level": -1, "charging": False, "available": False, "stale": False}


def parse_battery(payload: bytes) -> dict[str, dict[str, object]]:
    """Battery replies are (component, value) pairs behind a count byte."""
    result: dict[str, dict[str, object]] = {}
    if not payload:
        return result
    count = payload[0]
    for index in range(count):
        offset = 1 + index * 2
        if offset + 1 >= len(payload):
            break
        component, raw = payload[offset], payload[offset + 1]
        level = raw & 0x7F
        if level > 100:
            continue
        entry = {"level": level, "charging": bool(raw & 0x80), "available": True, "stale": False}
        if component == COMPONENT_LEFT:
            result["left"] = entry
        elif component == COMPONENT_RIGHT:
            result["right"] = entry
        elif component == COMPONENT_CASE:
            result["case"] = entry
        elif component == COMPONENT_HEADSET:
            result["headset"] = entry
    return result


def parse_wear(payload: bytes) -> dict[str, object]:
    """(component, flags) pairs; bit 2 is "in the ear" on the models seen so far."""
    wear: dict[str, object] = {"available": False, "left": None, "right": None}
    if not payload:
        return wear
    count = payload[0]
    for index in range(count):
        offset = 1 + index * 2
        if offset + 1 >= len(payload):
            break
        component, flags = payload[offset], payload[offset + 1]
        if component == COMPONENT_LEFT:
            wear["left"] = bool(flags & WEAR_IN_EAR_BIT)
            wear["available"] = True
        elif component == COMPONENT_RIGHT:
            wear["right"] = bool(flags & WEAR_IN_EAR_BIT)
            wear["available"] = True
    return wear


def parse_anc(payload: bytes) -> dict[str, object]:
    state: dict[str, object] = {"available": False, "mode": "unknown", "level": -1, "key": ""}
    for offset in range(0, len(payload) - 2, 3):
        if payload[offset] != 1:
            continue
        value = payload[offset + 1]
        state["available"] = True
        state["mode"] = ANC_WIRE_KEY.get(value, "unknown")
        state["level"] = value if 1 <= value <= 4 else -1
    if state["available"]:
        state["key"] = state["mode"]
    return state


def parse_eq(payload: bytes) -> dict[str, object]:
    state: dict[str, object] = {"available": False, "preset": "unknown"}
    if payload:
        state["available"] = True
        state["preset"] = EQ_WIRE_KEY.get(payload[0], "unknown")
    return state


def parse_bass(payload: bytes) -> dict[str, object]:
    state: dict[str, object] = {"available": False, "enabled": False, "level": 0}
    if len(payload) >= 2:
        state["available"] = True
        state["enabled"] = payload[0] != 0
        state["level"] = payload[1] // 2
    return state


def parse_latency(payload: bytes) -> dict[str, object]:
    return {"available": bool(payload), "enabled": bool(payload and payload[0] == 1)}


def parse_string(payload: bytes) -> str:
    return payload.decode("utf-8", "replace").strip("\x00 \r\n")


def parse_remote_config(payload: bytes) -> dict[str, str]:
    """Firmware/serial per component: "3,2,<fw>" and "3,4,<serial>" lines."""
    found: dict[str, str] = {}
    for line in parse_string(payload).splitlines():
        parts = line.split(",")
        if len(parts) < 3:
            continue
        component, key, value = parts[0].strip(), parts[1].strip(), parts[2].strip()
        if key == "2" and value:
            found[f"firmware_{component}"] = value
        elif key == "4" and value:
            found[f"serial_{component}"] = value
    return found


# --- host-side codec -------------------------------------------------------


def pactl(*args: str) -> str:
    try:
        result = subprocess.run(
            ["pactl", *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout if result.returncode == 0 else ""


def codec_key(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")


def host_codec_profiles(address: str) -> list[dict[str, str]]:
    """Only the A2DP sink codecs this laptop actually advertises."""
    card = "bluez_card." + address.replace(":", "_")
    text = pactl("list", "cards")
    if not text:
        return []
    blocks = re.split(r"(?=^Card #)", text, flags=re.MULTILINE)
    block = next(
        (b for b in blocks if re.search(r"^\s*Name:\s*" + re.escape(card) + r"\s*$", b, re.MULTILINE)),
        "",
    )
    if not block:
        return []
    found: list[dict[str, str]] = []
    in_profiles = False
    for line in block.splitlines():
        if line.strip() == "Profiles:":
            in_profiles = True
            continue
        if in_profiles and line.strip().startswith("Active Profile:"):
            break
        if not in_profiles or "a2dp-sink" not in line:
            continue
        profile_match = re.match(r"\s*([^:]+):", line)
        codec_match = re.search(r"codec\s+([^()\s]+)", line, re.IGNORECASE)
        if not profile_match or not codec_match:
            continue
        profile = profile_match.group(1).strip()
        key = codec_key(codec_match.group(1))
        if not key or any(option["key"] == key for option in found):
            continue
        found.append({
            "key": key,
            "label": CODEC_LABELS.get(key, codec_match.group(1).upper()),
            "profile": profile,
        })
    return found


def active_host_codec(address: str) -> str:
    text = pactl("list", "sinks")
    if not text:
        return "unknown"
    for block in re.split(r"(?=^Sink #)", text, flags=re.MULTILINE):
        if address not in block:
            continue
        match = re.search(r'api\.bluez5\.codec\s*=\s*"([^"]+)"', block)
        if match:
            return codec_key(match.group(1))
    return "unknown"


def host_codec_state(address: str, device_code: int | None = None) -> dict[str, object]:
    options = host_codec_profiles(address)
    return {
        "available": bool(options),
        "active": active_host_codec(address),
        "options": options,
        "device_code": device_code if device_code is not None else -1,
        "device_mode": DEVICE_CODEC_LABELS.get(device_code, "Unknown") if device_code is not None else "Unknown",
    }


def set_host_codec(address: str, key: str) -> tuple[bool, str]:
    """Codec switching is a host operation; the firmware flag alone changes nothing."""
    options = host_codec_profiles(address)
    selected = next((option for option in options if option["key"] == key), None)
    if selected is None:
        available = ", ".join(option["label"] for option in options) or "none"
        return False, f"{key} is not available on this laptop (available: {available})"
    card = "bluez_card." + address.replace(":", "_")
    try:
        result = subprocess.run(
            ["pactl", "set-card-profile", card, selected["profile"]],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=8,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, f"Could not select {selected['label']}: {exc}"
    if result.returncode != 0:
        return False, result.stderr.strip() or f"Could not select {selected['label']}"
    time.sleep(0.25)
    return True, "ok"


# --- case cache ------------------------------------------------------------


def state_dir() -> Path:
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(base) / "nothing-ear"


def read_case_cache() -> dict[str, object]:
    """One file, one entry per address: two pairs must not overwrite each other."""
    try:
        data = json.loads((state_dir() / "case.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    devices = data.get("devices")
    if isinstance(devices, dict):
        return devices
    # Older single-device file: keep its reading under its own address.
    address = str(data.get("address", "")).lower()
    if address and isinstance(data.get("case"), dict) and isinstance(data.get("saved"), int):
        return {address: {"case": data["case"], "saved": data["saved"]}}
    return {}


def write_case_cache(devices: dict[str, object]) -> None:
    directory = state_dir()
    try:
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "case.json").write_text(
            json.dumps({"schema_version": 1, "devices": devices}),
            encoding="utf-8",
        )
    except OSError:
        pass


def cache_case(case: dict[str, object], address: str) -> None:
    devices = read_case_cache()
    now = int(time.time())
    # Drop the entries that have expired, so the file cannot grow forever.
    devices = {
        key: value
        for key, value in devices.items()
        if isinstance(value, dict) and isinstance(value.get("saved"), int)
        and now - value["saved"] <= CASE_CACHE_MAX_AGE
    }
    devices[address.lower()] = {"case": case, "saved": now}
    write_case_cache(devices)


def cached_case(address: str) -> dict[str, object] | None:
    entry = read_case_cache().get(address.lower())
    if not isinstance(entry, dict):
        return None
    saved = entry.get("saved")
    if not isinstance(saved, int) or time.time() - saved > CASE_CACHE_MAX_AGE:
        return None
    case = entry.get("case")
    if not isinstance(case, dict) or not isinstance(case.get("level"), int):
        return None
    # A remembered reading is not a live one: the panel dims it, and a charge
    # that ended hours ago must not keep a charging animation running.
    return {**case, "charging": False, "stale": True, "age_seconds": int(time.time() - saved)}


# --- snapshot --------------------------------------------------------------


def snapshot(device: dict[str, str] | None) -> dict[str, object]:
    address = device["address"] if device else ""
    name = (device.get("name") if device else "") or ("Nothing device" if address else "")
    battery: dict[str, object] = {
        "left": unknown_battery(),
        "right": unknown_battery(),
        "case": unknown_battery(),
        "headset": unknown_battery(),
        "aggregate": aggregate_battery(address) if address else -1,
    }
    noise: dict[str, object] = {"available": False, "mode": "unknown", "level": -1, "key": ""}
    eq: dict[str, object] = {"available": False, "preset": "unknown"}
    bass: dict[str, object] = {"available": False, "enabled": False, "level": 0}
    latency: dict[str, object] = {"available": False, "enabled": False}
    wear: dict[str, object] = {"available": False, "left": None, "right": None}
    features: dict[str, object] = {"dual_connection": None, "in_ear_detection": None}
    firmware = ""
    protocol_version = ""
    connected = bool(address) and is_connected(address)
    protocol = False
    errors: list[str] = []

    if address:
        device_codec: int | None = None
        sock: socket.socket | None = None
        if connected:
            try:
                sock = open_channel(address)
            except OSError as exc:
                errors.append(f"Nothing control channel refused: {exc.strerror or exc}")

        if sock is not None:
            parser = FrameParser()
            try:
                # A device-info read doubles as the activation step Nothing X
                # performs on a fresh session; later queries can be ignored
                # without it.
                exchange(sock, parser, CMD_REMOTE_CONFIG)

                payload = exchange(sock, parser, CMD_BATTERY)
                if payload is None:
                    errors.append("Battery query timed out")
                else:
                    protocol = True
                    battery.update(parse_battery(payload))

                if payload is not None:
                    anc = exchange(sock, parser, CMD_ANC_GET)
                    if anc is not None:
                        noise = parse_anc(anc)

                    eq_payload = exchange(sock, parser, CMD_EQ_GET)
                    if eq_payload is not None:
                        eq = parse_eq(eq_payload)

                    bass_payload = exchange(sock, parser, CMD_BASS_GET)
                    if bass_payload is not None:
                        bass = parse_bass(bass_payload)

                    latency_payload = exchange(sock, parser, CMD_LATENCY_GET)
                    if latency_payload is not None:
                        latency = parse_latency(latency_payload)

                    wear_payload = exchange(sock, parser, CMD_WEAR)
                    if wear_payload is not None:
                        wear = parse_wear(wear_payload)

                    firmware_payload = exchange(sock, parser, CMD_FIRMWARE)
                    if firmware_payload is not None:
                        firmware = parse_string(firmware_payload)

                    protocol_payload = exchange(sock, parser, CMD_PROTOCOL)
                    if protocol_payload is not None:
                        protocol_version = parse_string(protocol_payload)

                    dual_payload = exchange(sock, parser, CMD_DUAL_GET)
                    if dual_payload:
                        features["dual_connection"] = dual_payload[0] != 0

                    in_ear_payload = exchange(sock, parser, CMD_IN_EAR)
                    if in_ear_payload and len(in_ear_payload) > 2:
                        # A (index, value) list; index 0x0b is the auto-pause
                        # switch the phone app calls "in-ear detection".
                        for index in range(1, len(in_ear_payload) - 1, 2):
                            if in_ear_payload[index] == 0x0B:
                                features["in_ear_detection"] = in_ear_payload[index + 1] != 0

                    device_codec_payload = exchange(sock, parser, CMD_CODEC_GET)
                    if device_codec_payload:
                        device_codec = device_codec_payload[0]
            finally:
                try:
                    sock.close()
                except OSError:
                    pass

        # The case cache is applied whether or not the control channel answered:
        # a busy channel must not blank a reading that is still meaningful.
        case = battery.get("case")
        if isinstance(case, dict) and case.get("available"):
            cache_case(case, address)
        else:
            remembered = cached_case(address)
            if remembered:
                battery["case"] = remembered

    return {
        "schema_version": 1,
        "connected": connected,
        "device": {"address": address, "name": name},
        "battery": battery,
        "wear": wear,
        "noise": noise,
        "eq": eq,
        "bass": bass,
        "latency": latency,
        "codec": host_codec_state(address, device_codec) if address else host_codec_state(""),
        "firmware": firmware,
        "protocol_version": protocol_version,
        "features": features,
        "protocol": protocol,
        "error": "; ".join(errors),
        "timestamp": int(time.time()),
    }


def control(device: dict[str, str], action: str, value: str) -> tuple[bool, str]:
    address = device["address"]
    if not is_connected(address):
        return False, "The device is not connected"
    if action == "codec":
        return set_host_codec(address, value)

    if action == "anc":
        command, payload = CMD_SET_ANC, bytes([1, ANC_WIRE[value], 0])
    elif action == "eq":
        command, payload = CMD_SET_EQ, bytes([EQ_WIRE[value]])
    elif action == "latency":
        command, payload = CMD_SET_LATENCY, bytes([1 if value == "on" else 2, 0])
    elif action == "bass":
        # The firmware takes (enabled, level * 2); keep the level the device
        # already has so a toggle never silently changes how much boost is on.
        sock = None
        try:
            sock = open_channel(address)
        except OSError as exc:
            return False, f"Nothing control channel refused: {exc.strerror or exc}"
        try:
            parser = FrameParser()
            exchange(sock, parser, CMD_REMOTE_CONFIG)
            current = exchange(sock, parser, CMD_BASS_GET)
            level = (current[1] // 2) if current and len(current) >= 2 and current[1] // 2 in range(1, 6) else 3
            command, payload = CMD_SET_BASS, bytes([1 if value == "on" else 0, level * 2])
            if exchange(sock, parser, command, DIR_SET, payload) is None:
                return False, "The device did not acknowledge the change"
            time.sleep(0.35)
            return True, "ok"
        finally:
            try:
                sock.close()
            except OSError:
                pass
    elif action == "find":
        side, state = value.split(":", 1)
        command, payload = CMD_SET_FIND, bytes([SIDE_WIRE[side], 1 if state == "on" else 0])
    else:
        return False, f"Unknown action {action}"

    try:
        sock = open_channel(address)
    except OSError as exc:
        return False, f"Nothing control channel refused: {exc.strerror or exc}"
    try:
        if exchange(sock, FrameParser(), command, DIR_SET, payload) is None:
            return False, "The device did not acknowledge the change"
        # BlueZ can hold the RFCOMM channel busy for a moment after the final
        # ACK; let the controller settle so a rapid second click still works.
        time.sleep(0.35)
        return True, "ok"
    finally:
        try:
            sock.close()
        except OSError:
            pass


def diagnose(device: dict[str, str] | None) -> dict[str, object]:
    """Raw payloads for the control channel — for when a firmware changes."""
    if not device or not is_connected(device["address"]):
        return {"ok": False, "error": "The device is not connected"}
    probes = [
        ("protocol", CMD_PROTOCOL, b""),
        ("remote_config", CMD_REMOTE_CONFIG, b""),
        ("battery", CMD_BATTERY, b""),
        ("wear", CMD_WEAR, b""),
        ("in_ear", CMD_IN_EAR, b""),
        ("anc", CMD_ANC_GET, b"\x03"),
        ("eq", CMD_EQ_GET, b""),
        ("bass", CMD_BASS_GET, b""),
        ("latency", CMD_LATENCY_GET, b""),
        ("firmware", CMD_FIRMWARE, b""),
        ("codec", CMD_CODEC_GET, b""),
        ("dual", CMD_DUAL_GET, b""),
        ("gestures", CMD_GESTURES, b""),
    ]
    result: dict[str, object] = {"ok": True, "device": device, "raw": {}}
    try:
        sock = open_channel(device["address"])
    except OSError as exc:
        return {"ok": False, "error": f"Nothing control channel refused: {exc.strerror or exc}"}
    try:
        parser = FrameParser()
        exchange(sock, parser, CMD_REMOTE_CONFIG)
        for label, command, payload in probes:
            response = exchange(sock, parser, command, DIR_GET, payload)
            result["raw"][label] = response.hex() if response is not None else None
    finally:
        try:
            sock.close()
        except OSError:
            pass
    return result


def emit(data: object) -> None:
    print(json.dumps(data, separators=(",", ":"), sort_keys=True), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Read and control Nothing earbuds over Bluetooth")
    parser.add_argument("--device", default="", help="Bluetooth address or name")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("devices")
    sub.add_parser("diagnose")
    anc = sub.add_parser("set-anc")
    anc.add_argument("mode", choices=sorted(ANC_WIRE))
    eq = sub.add_parser("set-eq")
    eq.add_argument("preset", choices=sorted(EQ_WIRE))
    bass = sub.add_parser("set-bass")
    bass.add_argument("state", choices=["on", "off"])
    latency = sub.add_parser("set-latency")
    latency.add_argument("state", choices=["on", "off"])
    find = sub.add_parser("set-find")
    find.add_argument("side", choices=sorted(SIDE_WIRE))
    find.add_argument("state", choices=["on", "off"])
    codec = sub.add_parser("set-codec")
    codec.add_argument("codec")
    args = parser.parse_args()

    device = choose_device(args.device)

    if args.command == "status":
        emit(snapshot(device))
        return 0
    if args.command == "devices":
        emit({"devices": nothing_device_list()})
        return 0
    if args.command == "diagnose":
        emit(diagnose(device))
        return 0
    if not device:
        emit({"ok": False, "error": "No paired Nothing device found"})
        return 1

    if args.command == "set-anc":
        action, value = "anc", args.mode
    elif args.command == "set-eq":
        action, value = "eq", args.preset
    elif args.command == "set-bass":
        action, value = "bass", args.state
    elif args.command == "set-latency":
        action, value = "latency", args.state
    elif args.command == "set-find":
        action, value = "find", f"{args.side}:{args.state}"
    else:
        action, value = "codec", args.codec

    ok, message = control(device, action, value)
    emit({"ok": ok, "error": "" if ok else message})
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
