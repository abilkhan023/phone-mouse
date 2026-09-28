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
| Remote | Media keys, slides and quick actions | The gyroscope, for the laser pointer |

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
click, drag with two fingers to scroll. Tap and then touch again and slide to
drag, as on a Mac trackpad. Two buttons under the pad are there for
dragging. The keyboard button between them opens the iPhone keyboard: what you
type is sent to the Mac and echoed on the phone.

Scrolling on the touchpad behaves like a Mac trackpad: the page bounces at the
edges, two fingers sideways go back and forward in Safari and Finder, and after
the fingers lift the page glides on and slows down.

**Remote.** Five pages. Media: play, pause, tracks, volume and brightness.
Slides: big previous and next buttons, the volume buttons turn slides like a
presenter clicker, and holding the pointer button steers the cursor with the
phone as a laser pointer. Apps: every app open on the Mac with its windows; a
tap brings an app forward or raises one particular window, a swipe quits the
app, and Next window does what ⌘` does. Screen: a live picture of the Mac's main
display, a few frames a second; a tap clicks at that spot, two taps
double-click, and a finger sliding over the picture leads the cursor without
clicking. The picture lies sideways so it fills the page with the phone held
on its side, and the frames come as many pixels wide as it has; a button in
its corner stands it upright. The Mac asks once for permission to record the screen. Actions: find
the pointer, next window, lock the screen, sleep the display, screenshots,
Mission Control, show the desktop, Apps, emoji, force quit, and sending the
clipboard.

**Find the pointer.** Shake the phone and a ring pulses around the cursor on the
Mac for a moment.

**Clipboard.** Text and images copied on the Mac show up on the phone's
clipboard. To send the phone's clipboard to the Mac, tap the paste button in
the key row or on the Actions page; iOS asks for permission every time an app
reads the clipboard on its own, but not through that button. The clipboard
travels over its own TCP connection, encrypted like everything else, up to
20 MB. It can be turned off in the Mac's menu.

**Gestures.** The touchpad also knows the Mac trackpad gestures. macOS has no
public way to post real gestures, so each one runs the system action it stands
for through its default shortcut.

| Gesture | Action |
| --- | --- |
| Three or four fingers up | Mission Control |
| Three or four fingers down | App Exposé |
| Three or four fingers left or right | Next or previous desktop |
| Four or five fingers together | Apps (Launchpad) |
| Four or five fingers apart | Show Desktop |
| Tap with three fingers | Look Up |
| Pinch with two fingers | Zoom in or out |

**Dictation.** The microphone button under the touchpad types what you say on
the Mac as it is heard, with punctuation; when the phone revises a word, the
Mac corrects it. Recognition runs on the phone where it can. The language is in
settings.

**Keyboard.** Above the iPhone keyboard sits a row of Mac keys that iOS lacks:
fn, esc, tab, forward delete, home, end, page up and down, the top row, the
arrows, and the modifiers ⌃ ⌥ ⌘ ⇧. A modifier stays on until the next key, so ⌘
then C copies. The top row works as on a MacBook: brightness, Mission Control,
Spotlight, media and volume; with fn it sends F1 to F12. The keys repeat while
held. A modifier held with a finger stays down on the Mac, so ⌘ held while
tapping ⇥ walks through apps and ⌘-click works; a short tap latches it for the
next key instead. The globe key, and ⌃Space, switch the Mac's input language. Shortcuts work with the Russian keyboard too. Holding delete repeats
and speeds up to whole words, as on the phone.

Key events are numbered and the phone sends them again until the Mac confirms
them, so nothing typed is lost when the connection drops: it arrives, in order,
once the phone is back. The line of typed text survives restarts and scrolls
sideways to show all of it. Its clear button erases the same text on the Mac.

**Volume.** While connected, the phone's volume buttons change the Mac's volume.
The phone's own volume stays where it was.

## Pairing and encryption

The first time the Mac companion starts it opens a window with a QR code. Scan
it with the phone. The code carries a random 256-bit key, and every packet is
encrypted and signed with it (ChaCha20-Poly1305). The Mac ignores anything that
was not sealed with that key and any packet it has already seen, so nobody else
on the network can move the cursor or type. To pair again, choose Pair iPhone in
the menu. New code there unpairs the old phone. The pairing window closes by
itself once the phone connects.

Without a camera, choose the Mac under Pair by code on the phone while the
pairing window is open, and type the six-digit code the window shows. This
works like Bluetooth passkey entry: the two devices agree on a key with
Curve25519, then prove they know the code one bit per round, each side
committing to its bit before the other reveals. A device in the middle is
caught with even odds in each of the twenty rounds, and the code cannot be
worked out from what goes over the air. A wrong code makes the Mac show a new
one, and after five the window has to be opened again.

The phone's glow lights up only while the Mac answers, which only a Mac with the
same key can do.

## Cable or Wi-Fi

Settings choose the way to the Mac. Automatic tries a cable first whenever one
is plugged in and falls back to Wi-Fi if the Mac does not answer over it within
a few seconds; plugging the cable in or out switches on the fly. Cable only and
Wi-Fi only stick to one. If Cable only never connects, turn on Personal Hotspot
on the phone while the cable is in; that gives the Mac a network link over USB.

## Settings and several Macs

The name at the top left opens a menu: switch between paired Macs, pair
another one, forget one, and open settings for pointer and scroll speed,
natural scrolling, left-handed buttons, the dictation language, and the line
under the name that shows how the phone reaches the Mac (Wi-Fi, Wi-Fi direct or
cable) and the delay in milliseconds.

That line also shows what is open on the Mac: the app in front and the title
of its window. In the remote, a presentation app switches to Slides by itself,
and a music or video player, or YouTube in a browser, to Media.

## Requirements

- iPhone with iOS 17 or later
- Mac with macOS 14 or later
- Xcode 16 or later

## Build and run

With the iPhone connected and both targets signed, `scripts/deploy.sh` builds
everything, installs the app on the phone and the companion in Applications,
and starts it. Installed there, the companion opens at login; the menu has a
switch for that.

Or by hand:

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
