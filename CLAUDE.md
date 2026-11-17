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
5. `docs/REVIEWS.md`     - both critic/judge review rounds verbatim: every finding, verdict, fix, and what was
   rejected and why (the "criticism" record - check it before re-proposing something).
6. `docs/HISTORY.md`     - what the owner asked for over time, what was delivered, machine state at the end.
7. `tests/live/README.md` - the scripts that drive live QA on the two real PCs.
8. `docs/COUNCIL.md`    - the critic council's plan: chosen technology per layer, releases R1-R4 with numbers to hit, the
   owner's answers. Work follows its roadmap.

## Resuming work in a new session (checklist)
1. Read the docs above; `git log --oneline -20` for the latest changes.
2. Run `tests\run-all.ps1` - everything must pass before changing anything (Windows 10 1703+, .NET Framework 4.7.2+).
3. Take the top item of `docs/OPEN-ISSUES.md` ("To verify next") unless the owner asks otherwise.
4. After a fix: test, live-prove if it touches pictures/input (`tests/live`), record numbers in QA-LOG, the reason in
   DECISIONS, update OPEN-ISSUES, commit as xl337x, push `next` (laptop installs it) and `main`.
5. For bigger changes: run independent critic agents + one judge (as in REVIEWS.md) before calling it done.

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
  It leaves the mouse and keyboard alone; `-WithInput` adds input.tests + gui-deep (they drive the real mouse/keyboard
  - say so first), `-Live` the classic-engine portal test. Two-PC live tests: `tests\live`.
- Install from a checkout: `powershell -ExecutionPolicy Bypass -File app\DeskView-Setup.ps1 -Source app -Role Server|Client`
  (`-SkipAdmin` skips firewall/driver; `-PairCode`, `-ServerAddress`, `-VirtualScreens N`, `-FFmpegZip <zip>`).
- One-line install: `irm https://raw.githubusercontent.com/xl337x/DeskView/main/install.ps1 | iex` (options: see README).
- Logs: `%APPDATA%\DeskView\deskview.log` (every player restart reason, smart-screen decisions, manual changes);
  player/sender reports: `%TEMP%\deskview-ffplay-*.log`, `%TEMP%\deskview-ffmpeg-screen*.log`.
- Live-test switches: env `DESKVIEW_QA_INPUT=1` (injected input counts as real), `DESKVIEW_NOMEDIA=1` (no video),
  `DESKVIEW_HOME` (settings folder instead of %APPDATA%\DeskView) / `DESKVIEW_INSTALL` (install folder instead of
  %LOCALAPPDATA%\DeskView) - tests use throwaway folders so the real install is never touched.
- Branches: `next` = what the test laptop installs; `main` = released.

## The two test machines (shapes only - never write their names, users or addresses into the repo)
- Server: desktop, 3 monitors side by side (main one on the left), wired network, Intel GPU (h264_qsv encoder),
  company-managed PC (security policies apply - never try to bypass them).
- Client: laptop on Wi-Fi, Intel + NVIDIA GPUs, 3 virtual extra screens to the LEFT of its panel (screen 1 = panel,
  screens 2/3/4 to its left). Reached for QA over SSH (host, user and key come from `DV_LAPTOP`, `DV_SSHKEY`);
  GUI actions there run through a scheduled task in the signed-in session (see `tests/live/README.md`).
