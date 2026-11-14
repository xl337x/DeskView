# DeskView

**One keyboard and mouse for two computers - and every screen of each computer on any monitor of the other.**

## Install - one line

Open **PowerShell** on each Windows 10 (1703 or newer) / Windows 11 computer and paste:

```powershell
irm https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1 | iex
```

That's it. It downloads everything, asks one question (*is this the computer whose keyboard and mouse you use?*),
shows a **pairing code** on that computer - type it on the other one - and starts DeskView now and at every sign-in.
The two computers find each other on the network by themselves.

<details>
<summary>Options, updates, uninstall, locked-down PCs</summary>

```powershell
# options: -Role Server|Client, -PairCode CODE, -ServerAddress IP, -VirtualScreens 0-4, -Ref <branch|tag>
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1))) -Role Client -PairCode ABCD2345EFGH

# update: run the same one line again (settings, pairing and extra screens are kept)

# uninstall (removes the app, settings, startup entry, firewall rules and the extra screens it added)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1))) -Uninstall

# security software that blocks piped scripts: save the installer and run the file
iwr https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1 -OutFile $env:TEMP\dv.ps1; powershell -ExecutionPolicy Bypass -File $env:TEMP\dv.ps1
```

- One Windows prompt asks for administrator approval once: firewall rules limited to the local network
  (UDP 9000-9009 video, TCP 9002 control, UDP 9010 discovery) and, on a laptop, optional **extra screens**
  (asked once; see below).
- FFmpeg comes as one pinned build checked by SHA256 (82 MB, once). Offline PC: `-FFmpegZip <the zip>`.
- DeskView runs **from source** inside Windows PowerShell (compiled in memory in about a second, by the compiler
  that is part of Windows): no .exe to block or sign, nothing to build. PCs that only allow restricted PowerShell
  are told so plainly.
</details>

## What it does

- **Move the mouse off the edge** of one screen and it continues on the other computer, with the keyboard and the
  clipboard. Built in - nothing else to install.
- **Any screen on any monitor**: each computer streams all its screens; click a monitor in the app (or press
  **Ctrl+Alt+1..9**) to show one of the other computer's screens there, and just move the mouse onto it to work.
- **Extra screens for a laptop**: the laptop gets up to 4 extra (virtual) screens. Drag a laptop window onto one and
  it appears on a desktop monitor by itself (**smart screens**); empty it and the monitor is yours again.
- **Drag files** onto the other computer's picture to send them (confirmed when saved there).
- **A guide** along the top of every monitor that shows the other computer, with *Give back* and *All back*.
- Everything encrypted and paired with a code.

| Where you sit | Keys | What happens |
|---|---|---|
| Either | push the mouse off the edge facing the other computer | keyboard, mouse and clipboard continue there; push back to return |
| Server | **Ctrl+Alt+1..9** | the laptop's main screen appears on your monitor 1..9; move the mouse onto it to work there |
| Client | **Ctrl+Alt+1..9** | the server's monitor 1..9 fills this screen; this computer's keyboard and touchpad control it |
| Either | **Ctrl+Alt+0** | everything back: pictures hidden, pointer home |
| Either | **Ctrl+Alt+D** | cycle the other computer's picture through the monitors |

Double-click the tray icon for the app: live status, a guided setup assistant, the screen map, pairing, switching,
clipboard and security options, logs.

## How well it works (measured)

- Mouse and keyboard switch in milliseconds; held keys and buttons never stay stuck on either computer.
- A picture of the other computer appears in about 1 s and follows with roughly 150-200 ms of delay on a wired
  network (more on Wi-Fi); after a network hiccup it catches up by itself. A lost picture is back in ~2 s.
- Details, numbers and how they were measured: [`docs/QA-LOG.md`](docs/QA-LOG.md).

## Security

- The pairing code is never sent: both computers prove they know it (PBKDF2-SHA256 + HMAC over fresh nonces); then
  every message is AES-256 encrypted and HMAC-authenticated with a sequence number (no replay, no tampering,
  reflected frames refused). 5 wrong attempts lock an address out for a minute.
- Video is always encrypted (SRT, AES-256) with a key derived from the pairing code. Discovery is sealed with the
  code too.
- Firewall rules allow the local network only.

## Limits

- Two Windows 10 (1703+) / Windows 11 computers with .NET Framework 4.7.2 or newer (built into Windows 10 1803+ and
  Windows 11), on the same local network (wired is smoothest).
- Secure screens (lock screen, UAC prompts) can't be captured; windows running as administrator on the other
  computer can't be controlled by the built-in engine. Clipboard: text (send files by dragging them onto a picture).
- Extra screens need a driver (installed by setup, needs administrator rights; often blocked on company PCs).

## For developers (and for Claude Code)

Start with [`CLAUDE.md`](CLAUDE.md), then [`docs/`](docs): architecture, every decision and why, the review
findings and verdicts, the QA log, open issues and ideas. Edit the `.cs` files and start `app\DeskView.ps1` -
that's the whole build. All tests: `tests\run-all.ps1`. Releasing is pushing to `main`.

## License

MIT (see `LICENSE`). Third-party components: `THIRD_PARTY_NOTICES.md`.
