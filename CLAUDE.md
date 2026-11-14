# DeskView - read this first

DeskView makes two Windows PCs work as one desk: keyboard and mouse move between them over the edge, the clipboard
and dragged files go along, and any screen of one computer can be shown on any monitor of the other (the laptop gets
"extra screens" so its windows can be dragged onto the other computer's monitors). One download, one setup command
on each PC.

Start here, then read in this order:
1. `docs/ARCHITECTURE.md` - how it works (processes, threads, protocol, video pipeline).
2. `docs/DECISIONS.md`   - every design judgement made so far and WHY (read before changing a mechanism).
3. `docs/QA-LOG.md`      - what was measured/proven on real hardware, and how to repeat it.
4. `docs/OPEN-ISSUES.md` - known problems, what to fix next, ideas.

## Rules for working on this repo (non-negotiable, from the owner)
- Commit as `xl337x <144266550+xl337x@users.noreply.github.com>` only. No AI attribution, no Co-Authored-By lines.
- Never name the third-party "classic" input engine in anything user-facing (UI, README, setup output, commit
  messages, docs). Call it "the classic engine". Code keeps the paths it needs.
- QA before saying something works: run the suites AND prove it live when it touches pictures/input. Report numbers.
- Do not bypass Defender / ASR / company policy. DeskView runs from source inside Windows PowerShell on purpose
  (no unsigned .exe to block).
- Don't take over the user's mouse, keyboard or monitors for tests without saying so; restore what you changed
  (monitor assignments: `%APPDATA%\DeskView\command.txt` with `off`; engine choice; QA env vars).

## Code rules
- C# 5 only (the in-box `csc` of .NET Framework compiles it at start): no `$""`, `?.`, `nameof`, `out var`,
  expression-bodied members, tuple syntax. `tests\csharp5.tests.ps1` enforces it.
- `app\DeskView-Input.cs` and `app\DeskView-Portal.cs` are also compiled ALONE by tests (link/files/input/mapping):
  they must not depend on other app files (no `DeskView.Tools` etc.). Reference System.Drawing in such tests.
- Comments explain WHY in plain words (match the existing style); user-facing text is plain and short.
- Every fix gets a test when it can be tested without real input; live checks go in docs/QA-LOG.md.

## Layout
```
install.ps1                 one-line installer: downloads the repo zip (-Ref branch) and runs setup
app\DeskView.ps1            launcher: FullLanguage check, Add-Type of app\**\*.cs, [DeskView.Program]::Main
app\DeskView-Setup.ps1      setup/update/uninstall (firewall, pinned FFmpeg, extra screens, pairing hand-over)
app\Core\Program.cs         entry, DPI awareness, migrations (old script settings, setup.json hand-over)
app\Core\AppSettings.cs     settings JSON (%APPDATA%\DeskView\app.json + .bak)
app\Core\Engine.cs          the brain: 250 ms tick + 2 s slow tick; screens, portals, smart screens, guide, files
app\Core\Media.cs           FFmpeg senders (one SRT listener per screen) and players (ffplay held in our window)
app\Core\CoreControl.cs     the optional classic engine (config, daemon pipe)
app\Core\TrayApp.cs         tray icon, start at sign-in
app\DeskView-Input.cs       built-in input engine: agent/forwarder link, edges, clipboard, files, discovery
app\DeskView-Portal.cs      portal (classic mode), MakePassive, job object, DeskViewPictureHost
app\DeskView-Displays.cs    virtual screens arrangement, which screens hold windows
app\DeskView-Dxgi.cs        capture outputs on every graphics adapter
app\UI\*.cs                 main window, screen map, setup wizard, guide strip + toast, theme
tests\*.tests.ps1           run-all.ps1 runs them; input.tests must run on a machine with a real desktop session
```

## Everyday commands
- All tests: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1` (or each `tests\X.tests.ps1`).
- Install from a checkout: `powershell -ExecutionPolicy Bypass -File app\DeskView-Setup.ps1 -Source app -Role Server|Client`
  (`-SkipAdmin` skips firewall/driver; `-PairCode`, `-ServerAddress`, `-VirtualScreens N`, `-FFmpegZip <zip>`).
- One-line install: `iwr https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1 -OutFile i.ps1; .\i.ps1`
- Logs: `%APPDATA%\DeskView\deskview.log` (every player restart reason, smart-screen decisions, manual changes);
  player/sender reports: `%TEMP%\deskview-ffplay-*.log`, `%TEMP%\deskview-ffmpeg-screen*.log`.
- Live-test switches: env `DESKVIEW_QA_INPUT=1` (injected input counts as real), `DESKVIEW_NOMEDIA=1` (no video),
  `DESKVIEW_HOME` / `DESKVIEW_INSTALL` (test folders).
- Branches: `next` = what the test laptop installs; `main` = released.

## The two test machines (owner's setup)
- Server "SERVER-PC": 3 monitors (DISPLAY7 primary 0..1919, DISPLAY2 1920..3839, DISPLAY1 3840..5759), wired,
  Intel Iris Xe (h264_qsv). Managed PC (company-managed, ASR rules).
- Client "laptop": laptop, Wi-Fi, Intel UHD + NVIDIA, 3 virtual extra screens to the LEFT of its panel
  (screen 1 = panel, 2/3/4 at x=-5760/-3840/-1920). Reached for QA over SSH (key `ssh-key`, user laptop-user);
  GUI actions there run through a scheduled task in the signed-in session (see docs/QA-LOG.md).
