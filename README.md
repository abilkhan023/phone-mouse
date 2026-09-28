# Phone Mouse

Turn an iPhone into a mouse for your Mac. Slide the phone across the desk like a
real mouse, or use its screen as a touchpad.

Phone Mouse is two small apps: one on the iPhone that reads the motion sensors
and the touch screen, and a menu bar companion on the Mac that moves the cursor.
They find each other automatically, with nothing to configure.

## How it works

```
iPhone                                   Mac
motion sensors, 100 Hz                   menu bar companion
touch screen                 UDP           receives reports
  -> pointer report   ------------->       posts mouse events
            discovery through Bonjour
```

The phone sends one report per sensor sample. Each report carries the pointer
movement, the scroll amount and the state of both buttons, the same way a USB
mouse does. Because the button state travels in every report, a lost packet
cannot leave a button stuck. If the phone goes silent for half a second, the
companion releases the buttons on its own.

On a shared Wi-Fi network the two talk through the router only. Peer-to-peer
Wi-Fi makes the radio hop between channels and adds jitter, so the phone falls
back to it only when it cannot find the Mac on the network. The Mac smooths out
reports that arrive in bursts.

The connection works over a USB cable, over a shared Wi-Fi network, or directly
between the two devices. Over a cable the measured delay from sensor sample to
the Mac is about 5 ms.

## Modes

| Mode | How to use it | What moves the cursor |
| --- | --- | --- |
| In air | Hold the phone and point it at the screen | The gyroscope |
| On desk | Lay the phone flat and slide it like a mouse | The accelerometer and gyroscope |
| Touchpad | Drag a finger across the screen | The touch screen |

**In air.** Turn your wrist left and right or up and down to move the cursor.
This is the most precise of the two motion modes: a gyroscope measures rotation
directly, so nothing drifts. It works the same whether the phone lies flat in
your hand or stands upright. Small hand tremor is filtered out, and the cursor
holds still for a moment when you press a button.

**On desk.** The screen shows a mouse: two buttons and a scroll wheel. Hold a
button and slide the phone to drag. When the phone is lifted off the desk the
cursor stops, and it starts again after the phone has rested on the desk for a
moment.

**Touchpad.** Drag to move, tap to click, tap with two fingers for a right
click, drag with two fingers to scroll. Two buttons under the pad are there for
dragging. The keyboard button between them opens the iPhone keyboard: what you
type is sent to the Mac and echoed on the phone.

**Gestures.** The touchpad also knows the Mac trackpad gestures. macOS has no
public way to post real gestures, so each one runs the system action it stands
for through its default shortcut.

| Gesture | Action |
| --- | --- |
| Three or four fingers up | Mission Control |
| Three or four fingers down | App Exposé |
| Three or four fingers left or right | Next or previous desktop |
| Five fingers together | Apps (Launchpad) |
| Five fingers apart | Show Desktop |
| Tap with three fingers | Look Up |
| Pinch with two fingers | Zoom in or out |

**Keyboard.** Above the iPhone keyboard sits a row of Mac keys that iOS lacks:
esc, tab, forward delete, home, end, page up and down, F1 to F12, the arrows,
and the modifiers ⌃ ⌥ ⌘ ⇧. A modifier stays on until the next key, so ⌘ then C
copies. Shortcuts work with the Russian keyboard too.

**Volume.** While connected, the phone's volume buttons change the Mac's volume.
The phone's own volume stays where it was.

## Pairing and encryption

The first time the Mac companion starts it opens a window with a QR code. Scan
it with the phone. The code carries a random 256-bit key, and every packet is
encrypted and signed with it (ChaCha20-Poly1305). The Mac ignores anything that
was not sealed with that key and any packet it has already seen, so nobody else
on the network can move the cursor or type. To pair again, choose Pair iPhone in
the menu. New code there unpairs the old phone.

## Requirements

- iPhone with iOS 17 or later
- Mac with macOS 14 or later
- Xcode 16 or later

## Build and run

1. Open `PhoneMouse.xcodeproj` in Xcode.
2. For both targets, choose your own team under Signing & Capabilities. Change
   the bundle identifiers if Xcode reports that they are taken.
3. Run the `PhoneMouseHost` scheme on the Mac. Allow it under System Settings,
   Privacy & Security, Accessibility. Without this permission macOS ignores the
   mouse events.
4. Run the `PhoneMouse` scheme on the iPhone and allow access to the local
   network when asked.

The phone shows the name of the Mac and a red glow once the two are connected.

## Limitations

On desk mode estimates movement from the accelerometer, which measures
acceleration, not position. That sets hard limits:

- Short movements with a pause between them are tracked well. A long movement
  without a stop drifts.
- Very slow movement produces too little acceleration to be measured.
- The phone has to lie flat. Tilting it or shaking it hard stops the cursor.
- After putting the phone down, pause for a moment before moving it.

Touchpad mode has none of these limits.

## Security

There is no pairing and no encryption. Any device on the same network can send
reports to the companion and move the cursor. Use Phone Mouse on networks you
trust.

## Project layout

| Path | Contents |
| --- | --- |
| `iOS/` | iPhone app: interface, motion tracking, touch surface, connection |
| `Mac/` | Menu bar companion: listener and cursor driver |
| `Shared/` | The report format used by both apps |
| `Config/` | Info.plist files for both targets |

## License

MIT. See `LICENSE`.
