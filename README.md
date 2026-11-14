# DeskView

**One keyboard and mouse for several computers - and every computer's screens on any monitor, in both directions.**

- Move the mouse off the edge of one screen and it continues on the other computer, with the keyboard and the
  clipboard. Built in - nothing else to install.
- Put your laptop's screens on any monitors of your desktop, then just move the mouse onto them: the mouse lands on
  the laptop at the exact spot you pointed. Drag the laptop's windows between its screens across your monitors.
- From the laptop, pull up any of the desktop's monitors full screen and control it with the laptop's own keyboard
  and touchpad.
- Drag files onto the other computer's picture to send them.
- Everything encrypted and paired with a code. One install command, the same on both computers.

## Install

On **each** Windows 10/11 computer, in PowerShell:

```powershell
iwr https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1 -OutFile $env:TEMP\deskview-install.ps1; powershell -ExecutionPolicy Bypass -File $env:TEMP\deskview-install.ps1
```

- It downloads DeskView (one zip, every file from the same version) and FFmpeg (one pinned build, checked by its
  SHA256), and asks once for administrator approval to add firewall rules limited to your local network
  (UDP 9000-9009 video, TCP 9002 control, UDP 9010 finding the other computer).
- It asks which computer is the **server** (the one whose keyboard and mouse you use). The server shows a
  **pairing code**; enter it on the other computer. The other computer finds the server on the network by itself.
- Options: `-Role Server|Client`, `-PairCode CODE`, `-ServerAddress IP` (if the computers can't find each other,
  e.g. on guest Wi-Fi), `-VirtualScreens N` (extra screens for a laptop, see below), `-ClassicEngine`, `-Uninstall`.

DeskView runs **from source**: Windows PowerShell compiles its C# code in memory each time it starts (about a
second), with the compiler that is part of Windows. There is no .exe to download, block or sign, and nothing to
build. PCs that only allow restricted PowerShell (constrained language mode) are told so plainly.

## Every monitor can show any screen of the other computer

Each computer streams **all** of its screens. In the app's **Screens** page (or the tray menu), click any monitor
to choose which of the other computer's screens it shows - or its own desktop.

A window can only be dragged onto a screen of its own computer. To spread a laptop's windows over several of your
monitors, give the laptop more screens than it physically has: add `-VirtualScreens 2` to the install command on
the laptop (installs the open-source [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver);
needs administrator rights, often blocked on company-managed PCs). Show each of its screens on one of your monitors
and drag its windows across them like a normal multi-monitor desktop.

## Use

| Where you sit | Keys | What happens |
|---|---|---|
| Either | push the mouse off the edge facing the other computer | keyboard, mouse and clipboard continue there; push back to return |
| Server | **Ctrl+Alt+1..9** | the client's main screen appears on your monitor 1..9 (left to right); move the mouse onto it to work there |
| Client | **Ctrl+Alt+1..9** | the server's monitor 1..9 fills this screen; this computer's keyboard and touchpad control it |
| Either | **Ctrl+Alt+0** | everything back: pictures hidden, pointer home |
| Either | **Ctrl+Alt+D** | cycle through the monitors |

The DeskView window (double-click the tray icon) has a guided setup assistant and pages for everything: live
status and health checks, **What you can do** (step-by-step), the screen map, connection and pairing, switching and
clipboard options, security and logs.

## Keyboard & mouse: built in

DeskView's own engine is the default:

- edge switching in about 40 ms round trip on a LAN; the clipboard (text) follows the pointer both ways
- encrypted and authenticated with the pairing code; a dropped link or Ctrl+Alt+0 always brings the pointer home
- no switching while you drag something; a laptop without a mouse keeps its pointer visible
- not yet: windows running as administrator, UAC prompts and the sign-in screen on the *other* computer, and
  copying images/files through the clipboard (drag files onto the picture instead)

The classic engine (installed with `-ClassicEngine`) is still supported; choose it on **Switching & input**, on
both computers. Updating DeskView never switches a computer's engine by itself.

## How it works

| Piece | Files | What it does |
|---|---|---|
| Launcher | `app/DeskView.ps1` | Checks PowerShell allows it, compiles `app/**/*.cs` in memory, starts the app (`-Tray`, `-Show 2`, `-LoadOnly` for tests). |
| App | `app/Core`, `app/UI` | Settings, the engine loop (video, portals, switching, files), tray and window. C# 5, so every Windows can compile it. |
| Keyboard/mouse, files, discovery | `app/DeskView-Input.cs` | Forwarder (captures your input) and agent (replays it) over an encrypted channel; edge switching, clipboard, file transfer; LAN discovery sealed with the pairing code. |
| Video | FFmpeg / ffplay | Desktop Duplication capture -> hardware H.264 (NVENC / Quick Sync / AMF / Media Foundation) -> SRT encrypted with AES-256. Decoding on the GPU, 1:1 pixels on scaled monitors. |
| Monitor mapping, portals | `app/DeskView-Dxgi.cs`, `app/DeskView-Portal.cs` | Monitor names to capture outputs; physical-pixel helpers; pointer visibility. |
| Setup | `install.ps1`, `app/DeskView-Setup.ps1` | Install / update / uninstall. |

Resolutions and scaling are detected automatically: each stream says which screen it is and where it sits, monitors
being plugged in or changed are picked up within seconds, and everything works in physical pixels.

## Security

- **Keyboard, mouse, clipboard, files**: the pairing code is never sent - both computers prove they know it
  (PBKDF2-SHA256 + HMAC over fresh nonces), then every message is AES-256 encrypted and HMAC-authenticated with a
  sequence number (no replay, no tampering, reflected frames refused). 5 wrong attempts lock an address out for a
  minute.
- **Video** is encrypted (SRT, AES-256) with a key derived from the pairing code.
- **Finding each other**: the client's probe and the server's answer are both sealed with the pairing code; a
  computer without the code gets no answer, and a fake server is ignored.
- Firewall rules allow the local network only. The 12-character pairing code comes from a cryptographic generator.

## Develop

Edit the `.cs` files and start `app\DeskView.ps1` - that's the whole build. Tests:

```powershell
tests\run-all.ps1
```

| Test | What it proves |
|---|---|
| `csharp5.tests.ps1` | every `.cs` compiles with the compiler that ships with Windows (no newer C# syntax slips in) |
| `app.tests.ps1` | settings, pairing codes, engine settings and layout, monitor and picture logic |
| `gui.tests.ps1` | every page opens; setup assistant; tray menu |
| `gui-deep.tests.ps1` | every button, checkbox, list, number and text field on every page, as server and client, with its effect proven (app.json, engine settings, engine commands, clipboard, windows opened) - HTML report and before/after screenshots in `%TEMP%\deskview-deep-qa` |
| `link.tests.ps1` | built-in switching, clipboard, names, discovery (right code, wrong code, fake server) |
| `input.tests.ps1` | control channel security and input replay (moves your real mouse/keyboard for a few seconds) |
| `files.tests.ps1`, `mapping.tests.ps1` | file transfer (incl. hostile names) and resolution mapping |
| `setup.tests.ps1` | install into throwaway folders, hand-off, update, uninstall |

Releasing is pushing to `main` (or a tag; `install.ps1 -Ref <tag>` installs a tag).

## Uninstall

Run the install command with `-Uninstall` at the end: removes DeskView, its startup entry, settings and firewall rules.

## Requirements and limits

- Windows 10 1607+ / Windows 11 on both computers, on the same local network. Wired is smoothest.
- What you see of the other computer is video: about 150-250 ms behind; the mouse and keyboard themselves switch in
  milliseconds.
- Windows' secure screens (lock screen, UAC prompts) can't be captured and show black while they're up.
- Two computers today (one server + one client). One screen is shown on one monitor at a time.

## License

DeskView is MIT licensed (see `LICENSE`). Third-party components: `THIRD_PARTY_NOTICES.md`.
