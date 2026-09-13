# Nothing Ear for Omarchy

An Omarchy bar widget for Nothing earbuds: the earbud artwork with the battery
percentage on the bar, and a panel with per-earbud and case battery, noise
control, equalizer presets, bass enhance, low latency, find-my-earbuds, and the
host audio codec. It is an unofficial desktop port of the everyday surface of
the Nothing X / Smart Center phone app.

![The panel: per-bud battery with in-ear state, noise control, equalizer, bass enhance, low latency, find-my-earbuds and codec chips](docs/screenshot.png)

The widget talks to the earbuds over their own Bluetooth control channel (the
Nothing X binary protocol on RFCOMM channel 15) through a short-lived Python
helper, so there is no daemon and no dependency beyond `python3`, `bluetoothctl`
and `pactl`.

## Features

- Bar icon: the earbud artwork with the weakest bud's percentage beside it
  (switchable with the `showBatteryPercent` setting), turning urgent below 20%,
  and the full breakdown in the tooltip
- Left, right and case battery, with a charging pulse and `in ear` / `out of
  ear` state per bud; the case reports through a docked earbud, so its last
  reading stays on screen dimmed with its age for six hours
- Noise control: Off, Transparency, Adaptive, Low, Medium, High
- Equalizer: Balanced, Voice, More treble, More bass, Custom
- Bass enhance toggle at the level the earbuds already have
- Low latency mode
- Find my earbuds: ring either bud, stopping itself after 20 seconds
- Audio codec, limited to what this laptop can actually negotiate over PipeWire
- Firmware, protocol version and dual-connection state in the panel footer
- Falls back to the single Bluetooth percentage if the control channel is busy

The case only reports while an earbud is docked in it and the lid is open.
Once the earbuds come out, the last reading stays on screen, dimmed and aged,
for 6 hours.

## Requirements

- Omarchy 4 (the shell plugin API this is built against)
- `python3` — the helper runs on system Python (`/usr/bin/python3`), which must
  be built with Bluetooth socket support; a version-manager Python (mise,
  pyenv, uv) may not be, and the plugin calls `/usr/bin/python3` directly for
  that reason
- `bluez` / `bluez-utils` for `bluetoothctl`
- PipeWire with `pactl` for the codec picker (the rest of the panel needs
  neither)

No third-party modules and no daemon: the helper is Python standard library
only and runs for the length of one call.

## Install

```bash
omarchy plugin add https://github.com/alanwcurry-dev/omarchy-nothing-ear --enable --yes
omarchy bar move nothing-ear --after omarchy.bluetooth
```

Pair the earbuds through the normal Bluetooth panel first.

## Remove

```bash
omarchy plugin remove nothing-ear --yes
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/nothing-ear"   # the case cache
```

Removing the plugin from the bar is enough to stop it; the second line clears
the remembered case readings. The earbuds keep whatever settings they had.

## Multiple pairs

Everything paired is detected on its own — there is no device picker. The
widget follows:

1. `deviceAddress` from settings, if you set one (an escape hatch, not the
   normal path),
2. the pair currently carrying audio — the one the desktop is playing through,
3. otherwise any connected pair, so taking one set off the desk and picking up
   the other just works.

The pick is made from PipeWire's own state: a BlueZ sink is named
`bluez_output.<address>.1`, so the address of the pair that is playing (or the
default) is read straight out of `pactl`, and re-checked every 15 seconds while
two pairs are connected at once.

Verified with both pairs connected: switching audio output from the Ear (open)
to the Ear (3) moved the widget to the Ear (3) within one poll, with no manual
selection.

A name fragment or address still works as an override from a script:

```bash
omarchy-shell nothing-ear devices          # JSON: every paired pair, connected first
omarchy-shell nothing-ear use open         # name fragment or a full address
omarchy-shell nothing-ear use 2C:BE:EE:4B:CF:24
omarchy-shell nothing-ear auto             # back to detecting it
./nothing-earctl.py devices                # the same list from the CLI
```

Models differ in what they expose: the Ear (open) has no noise control, so the
panel leaves that section out and right-click stops cycling it, while battery,
equalizer, bass enhance, low latency, find-my-earbuds and codec all still work.

## Case battery

The case has no radio of its own — it reports its charge through a docked
earbud — so a reading only exists while an earbud sits in it with the lid open.
The battery section says which of the three states you are looking at:

- a live percentage, while an earbud is docked in an open case,
- a dimmed `seen 12m ago` value for the last reading the case left behind, kept
  per pair for six hours,
- `docked only`, when nothing has been seen yet.

The cache is applied whether or not the control channel answers, so a busy
channel never blanks a reading that is still meaningful.

## Settings

| Key | Default | What it does |
| --- | --- | --- |
| `hideWhenDisconnected` | `true` | Hide the icon while the earbuds are away. An error keeps it visible. |
| `showBatteryPercent` | `true` | Show the battery percentage beside the icon. Off leaves the artwork alone; the tooltip and panel still report the battery. |
| `deviceAddress` | `""` | Pin a Bluetooth address, for when several matching devices are paired. |
| `helperPath` | `""` | Use a different `nothing-earctl.py`. Empty uses the bundled one. |
| `refreshSeconds` | `60` | How often the bar icon re-reads the earbuds while connected. |

Which pair is detected automatically; `deviceAddress` only pins one. The
settings UI is Setup → Plugins, or `omarchy bar set nothing-ear <key> <value>`.

Toggle the percentage without opening a settings UI:

```bash
omarchy bar set nothing-ear showBatteryPercent false --json
omarchy bar set nothing-ear showBatteryPercent true  --json
```

## Controls

Left click opens the panel, right click cycles noise control.

| Key | Action |
| --- | --- |
| `j` `k` `↓` `↑` | Move between groups |
| `h` `l` `←` `→` | Move between options |
| `Enter` `Space` | Activate |
| `o` `t` `a` | Off, Transparency, Adaptive |
| `Shift+L` `Shift+M` `Shift+H` | Low, Medium, High noise cancelling |
| `n` | Cycle noise control |
| `e` | Cycle equalizer preset |
| `b` | Toggle bass enhance |
| `g` | Toggle low latency |
| `p` `Shift+P` | Ring the left / right earbud (`x` is the shell's own delete key) |
| `c` | Cycle codec |
| `r` | Refresh |
| `Esc` | Close |

Plain `h` and `l` walk the chips, so the noise-control levels take the shifted
letters. The panel is also scriptable:

```bash
omarchy-shell nothing-ear toggle
omarchy-shell nothing-ear refresh
omarchy-shell nothing-ear noise        # prints the new mode
omarchy-shell nothing-ear eq
omarchy-shell nothing-ear find left
omarchy-shell nothing-ear status
```

## Helper

`nothing-earctl.py` is the only part that touches the hardware, and each call
opens the control channel, does one exchange, and closes it:

```bash
./nothing-earctl.py status
./nothing-earctl.py devices
./nothing-earctl.py set-anc high
./nothing-earctl.py set-eq bass
./nothing-earctl.py set-bass on
./nothing-earctl.py set-latency on
./nothing-earctl.py set-find right on
./nothing-earctl.py --device 3C:B0:ED:51:18:FD status
./nothing-earctl.py diagnose          # raw payloads, for firmware changes
```

`status` always prints a full snapshot and exits 0; the `connected` and
`protocol` fields say which state the earbuds are in, and `error` carries only
what genuinely went wrong. Every other command prints `{"ok":...}`.

## Artwork

`assets/buds.png` is the bar artwork: the user's own picture, kept
white-on-transparent (generated from `assets/buds-source.png` with
`magick buds-source.png -colorspace gray -alpha copy -channel RGB -evaluate set
100% +channel -trim +repage -border 3 -resize 64x64 buds.png`) so it sits on any
bar background. Swap either file to change the icon; the theme colour is not
applied, so a light bar wants a dark source image.

## Notes and caveats

- Writes are optimistic: the panel shows the new value immediately and reverts
  it if the firmware does not confirm within five seconds.
- Firmware updates, gesture remapping and the advanced 8-band EQ editor are not
  ported. The control channel speaks them (see `diagnose`), but the phone app's
  own UI for them is out of scope here.
- Preset numbering (0 Balanced, 1 Voice, 2 More treble, 3 More bass, 5 Custom)
  is verified by write-and-read-back on Nothing Ear (3), firmware 1.0.1.69.
- Verified on Nothing Ear (3) (firmware 1.0.1.69) and Nothing Ear (open)
  (1.0.1.28). The protocol is shared across the Ear family, so other Nothing
  earbuds should work; `diagnose` is there when one does not.

## Credits

The Nothing X protocol was not documented by Nothing; this port stands on the
reverse-engineering work of the community, in particular
[r-witz/omarchy-nothing-ear](https://github.com/r-witz/omarchy-nothing-ear)
(MIT, the framing and the case-cache idea) and
[Dospacite/NothingLinux](https://github.com/Dospacite/NothingLinux) (the
command table and payload layouts).

Nothing, Nothing Ear and Nothing X are trademarks of Nothing Technology
Limited. This project is unofficial and unaffiliated.
