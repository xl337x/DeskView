# DeskView

**See and use your other computer's screen on any monitor — in both directions — on top of [Deskflow](https://github.com/deskflow/deskflow).**

Deskflow shares one keyboard and mouse between computers. DeskView adds the missing piece: the *picture*.

- Put your laptop's screen on any monitor of your desktop, then just move the mouse onto it — keyboard and mouse
  hand over to the laptop at the exact spot you pointed, and leaving its edge brings you back beside it.
  It behaves like the laptop is plugged into that monitor.
- From the laptop, pull up any of the desktop's monitors full screen and control it with the laptop's own
  keyboard and touchpad (the direction Deskflow can't do).
- One install command, the same on both machines. Starts at sign-in, lives in the tray.

## Install

On **each** Windows machine (Deskflow installed and connected first), in PowerShell:

```powershell
irm https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1 | iex
```

- You'll get **one** administrator prompt (only if something is missing): two firewall rules limited to your
  local network (UDP 9000 video, TCP 9002 control), plus FFmpeg / Deskflow via `winget` if they aren't installed.
- On the Deskflow **server** the installer prints a **pairing code** (also in the tray menu).
  On the **client** it asks for that code. To pass it directly:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1))) -PairCode ABCD2345
```

## Use

| Where you sit | Keys | What happens |
|---|---|---|
| Deskflow server | **Ctrl+Alt+1..9** | The other machine's screen appears on your monitor 1..9 (counted left to right). Move the mouse onto it to work there. |
| Deskflow server | **Ctrl+Alt+0** | Hide it |
| Deskflow client | **Ctrl+Alt+1..9** | The server's monitor 1..9 fills this screen; this machine's keyboard and touchpad control it |
| Deskflow client | **Ctrl+Alt+0** | Back to this machine |
| Either | **Ctrl+Alt+D** | Cycle through the monitors |

Hotkeys only react to keys you physically press on that machine — keys Deskflow forwards from the other machine never trigger them.

The tray icon menu has the same choices plus:

- **Picture** — *Fit* keeps the other screen's shape (black bars if it differs), *Stretch* fills the monitor.
- **Quality** — *Auto* (detects wired vs Wi-Fi), *Wired* (20 Mbps, lowest lag), *Wi-Fi* (10 Mbps, stutter-resistant).
- **Interactive** — turn the mouse hand-over on/off (view only).

Command line: `DeskView.ps1 -Show 2` (or `DISPLAY2`, or `Off`) controls the running copy.

## How it works

| Piece | File | What it does |
|---|---|---|
| App | `app/DeskView.ps1` | Tray app. Detects its role from Deskflow, streams its own screen, shows the other one, manages everything below. |
| Video | FFmpeg / ffplay | Desktop Duplication capture → hardware H.264 (NVENC / Quick Sync / AMF / Media Foundation, else x264) → SRT over UDP, low-latency settings. ffplay shows it borderless on the chosen monitor, 1:1 pixels on scaled monitors. |
| Portal | `app/DeskView-Portal.cs` | Low-level mouse hook. When the cursor enters the monitor showing the other machine, it is placed on the outer edge Deskflow links to that machine (height mapped by proportion of the picture), so Deskflow hands over exactly there. Deskflow's log tells it when control comes back, and the cursor is put just beside the monitor. DeskView rewrites Deskflow's screen links to match the chosen monitor. |
| Control channel | `app/DeskView-Input.cs` | The reverse direction. The *forwarder* captures your physical input while you view the other machine and sends it; the *agent* there replays it. Your local cursor keeps moving over the picture, so pointing feels instant. Paired by code, local network only, stuck keys released on disconnect. |
| Monitor mapping | `app/DeskView-Dxgi.cs` | Maps Windows monitor names (`DISPLAY2`) to FFmpeg's capture index. |
| Setup | `app/DeskView-Setup.ps1`, `install.ps1` | Install / update / uninstall. |

Resolutions and scaling are detected automatically: the other machine's resolution comes from the stream itself,
monitors being plugged in or changed are picked up within seconds, and everything works in physical pixels
(mixed 100% / 150% scaling is handled).

## Tests

```powershell
tests\run-all.ps1          # height mapping + control channel (loopback) - any Windows machine
tests\run-all.ps1 -Live    # + live portal tests on every monitor (on the Deskflow server, client connected)
```

The live tests move your mouse by themselves for a minute or two.

## Uninstall

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1))) -Uninstall
```

Removes DeskView, its startup entry, settings and firewall rules. Deskflow and FFmpeg stay.

## Requirements and limits

- Windows 10 1607+ / Windows 11 on both machines, Deskflow 1.27+, both on the same local network.
- Wired is smoothest; Wi-Fi works with a little more delay.
- Windows' secure screens (lock screen, UAC prompts) can't be captured and show black while they're up.
- Two machines today (one Deskflow server + one client).
