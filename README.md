# DeskView

**One keyboard and mouse for several computers - and every computer's screens on any monitor, in both directions.**

- Use one keyboard and mouse across your computers: move the mouse off the edge of one screen and it continues on
  the other computer, with a shared clipboard.
- Put your laptop's screens on any monitors of your desktop, then just move the mouse onto them - keyboard and mouse
  hand over to the laptop at the exact spot you pointed, and the cursor moves across all of the laptop's screens like
  a normal multi-monitor desktop. Drag the laptop's windows between them.
- From the laptop, pull up any of the desktop's monitors full screen and control it with the laptop's own keyboard
  and touchpad.
- Encrypted end to end, paired with a code. One install command, the same on both computers. Lives in the tray.

## Install

On **each** Windows computer, in PowerShell (it downloads the installer to a file and runs it):

```powershell
iwr https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1 -OutFile $env:TEMP\deskview-install.ps1; powershell -ExecutionPolicy Bypass -File $env:TEMP\deskview-install.ps1
```

- One administrator prompt (only if something is missing): the keyboard/mouse engine, and two firewall rules limited
  to your local network (UDP 9000-9009 video, TCP 9002 control). FFmpeg is downloaded next to DeskView if needed.
- Setup asks which computer is the **server** (the one whose keyboard and mouse you use) if it can't tell.
- The server prints a **pairing code** (also in the tray menu); the client asks for it. To pass it directly, add
  `-PairCode ABCD2345` at the end of the command. Other options: `-Role Server|Client`, `-VirtualScreens 2`, `-Uninstall`.

## Every monitor can show any screen of the other computer

Each computer streams **all** of its screens (screen 1 = its left-most monitor). On the server, the tray menu
**Monitors** lets every local monitor show any screen of the client - or its own desktop.

Give a laptop more screens than it physically has (they appear on your monitors) - add `-VirtualScreens 2` to the
install command on the laptop. This installs the open-source
[Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver); arrange the new screens in
Windows *Settings > System > Display*, e.g. to the right of the laptop screen.

## Use

| Where you sit | Keys | What happens |
|---|---|---|
| Server | **Ctrl+Alt+1..9** | The client's main screen appears on your monitor 1..9 (counted left to right). Move the mouse onto it to work there. |
| Server | **Ctrl+Alt+0** | Hide all of them |
| Client | **Ctrl+Alt+1..9** | The server's monitor 1..9 fills this screen; this computer's keyboard and touchpad control it |
| Client | **Ctrl+Alt+0** | Back to this computer |
| Either | **Ctrl+Alt+D** | Cycle through the monitors |

Hotkeys only react to keys you physically press on that computer - keys forwarded from the other computer never
trigger them.

The tray icon menu has the same choices plus **Picture** (*Fit* keeps the other screen's shape, *Stretch* fills
the monitor), **Quality** (*Auto*, *Wired* 20 Mbps, *Wi-Fi* 10 Mbps) and **Interactive** (mouse hand-over on/off).

Command line: `DeskView.ps1 -Show 2` (or `DISPLAY2`, or `Off`) controls the running copy; on the server
`-Show 2=1` puts the client's screen 1 on monitor 2 (`2=0` gives monitor 2 its own desktop back).

## Built-in keyboard & mouse engine (new)

DeskView can switch the keyboard and mouse between the computers by itself - no separate engine running:

- push the pointer off the edge that faces the other computer and it continues there, with the keyboard; it comes back the same way (about 40 ms round trip on a LAN)
- the clipboard (text, up to the size set on *Switching & input*) follows the pointer, both ways
- everything is encrypted and authenticated with the pairing code; Ctrl+Alt+0 always brings the pointer home, and so does a dropped link
- the laptop keeps its pointer visible (Windows hides it when no mouse is plugged in)

Turn it on with **Switching & input > Keyboard & mouse engine > DeskView built-in** in the app, or **Keyboard & mouse: DeskView built-in** in the tray menu - on both computers. The classic engine stays the default until the built-in one has more field testing; turning DeskView off hands switching back to the classic engine.

Not yet in the built-in engine: windows that run as administrator and the Windows sign-in / UAC screens on the other computer (they need an elevated helper), and copying images or files through the clipboard (use drag and drop for files).

## The DeskView app (preview)

`gui/` holds **DeskView.exe**, a native Windows app with a guided setup assistant and pages for everything:
live status and health checks, a visual screen map (click a monitor to choose what it shows), connection and
pairing, every switching / input / clipboard option, security and logs. Build it with
`powershell -ExecutionPolicy Bypass -File gui\build.ps1` (needs Visual Studio 2022 Build Tools; runs on the
.NET Framework 4.8 that comes with Windows). It is not signed yet, so managed computers with strict Defender
"attack surface reduction" rules may block it; the PowerShell DeskView (installed by the command above) keeps
working either way and steps aside while the app runs.

## How it works

| Piece | File | What it does |
|---|---|---|
| Tray app | `app/DeskView.ps1` | Detects its role, streams its own screens, shows the other computer's, manages everything below. |
| Keyboard/mouse engine | (installed separately) | Shares one keyboard and mouse; DeskView's build adds **portals** - the rectangles where another computer's screens are shown behave like that computer's screens. |
| Video | FFmpeg / ffplay | Desktop Duplication capture -> hardware H.264 (NVENC / Quick Sync / AMF / Media Foundation, else x264), frames kept on the GPU -> encrypted SRT over UDP. The viewer decodes on the GPU and shows it borderless, 1:1 pixels on scaled monitors. |
| Control channel | `app/DeskView-Input.cs` | The reverse direction: the *forwarder* captures your physical input while you view the other computer and sends it; the *agent* there replays it. Your local cursor keeps moving over the picture, so pointing feels instant. |
| Portal fallback | `app/DeskView-Portal.cs` | For an engine without portals: a low-level mouse hook that hands over at the matching edge. |
| Monitor mapping | `app/DeskView-Dxgi.cs` | Maps Windows monitor names (`DISPLAY2`) to the capture index. |
| Setup | `app/DeskView-Setup.ps1`, `install.ps1` | Install / update / uninstall. |

Resolutions and scaling are detected automatically: each stream says which screen it is and where it sits, the
other computer's resolution comes from the stream itself, monitors being plugged in or changed are picked up within
seconds, and everything works in physical pixels (mixed 100% / 150% scaling is handled).

## Security

- **Keyboard and mouse** traffic is encrypted with TLS; each side remembers the other's certificate fingerprint.
- **Video** is encrypted (SRT, AES-256) with a key derived from the pairing code; without it nobody on the network
  can watch your screen.
- **Remote control** uses mutual authentication - the pairing code is never sent: both sides prove they know it
  (PBKDF2-SHA256 + HMAC challenges over fresh nonces) - then every message is AES-256 encrypted and HMAC-authenticated
  with a sequence number (no replay or tampering). Only the paired computer's address is accepted, unauthenticated
  peers get 5 s, and 5 wrong attempts lock an address out for a minute.
- The 12-character pairing code comes from a cryptographic random generator.

## Performance

Measured on an i7-1255U laptop (Intel Iris Xe):

| | |
|---|---|
| Mouse hand-over into / out of a portal | under a millisecond |
| Picture delay (loopback, wired) | ~150-250 ms |
| Sender CPU | frames stay on the GPU: ~3x less CPU than copying them back |
| Viewer CPU | GPU decoding (D3D11): ~3.5x less CPU than software decoding |

The viewer reconnects automatically if the stream stalls or drops.

## Tests

```powershell
tests\run-all.ps1          # height mapping + control channel (loopback) - any Windows computer
tests\run-all.ps1 -Live    # + live portal tests on every monitor (on the server, client connected)
```

The live tests move your mouse by themselves for a minute or two.

## Uninstall

Run the install command with `-Uninstall` at the end. It removes DeskView, its startup entry, settings and firewall
rules; the keyboard/mouse engine and FFmpeg stay.

## Requirements and limits

- Windows 10 1607+ / Windows 11 on both computers, on the same local network.
- Wired is smoothest; Wi-Fi works with a little more delay.
- What you see of the other computer is video: about 150-250 ms behind (mouse and keyboard switch in under a millisecond).
- Windows' secure screens (lock screen, UAC prompts) can't be captured and show black while they're up.
- Two computers today (one server + one client). One screen is shown on one monitor at a time.

## License

DeskView is MIT licensed (see `LICENSE`). Third-party components and their licenses: `THIRD_PARTY_NOTICES.md`.
