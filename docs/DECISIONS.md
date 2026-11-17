# Decisions and why

Each entry: the problem, what was decided, why, and what was rejected. Most were settled by critic agents reviewing
the code independently and one judge verifying each claim against the code (two rounds so far, see the end).

## Shape of the product
- **Run from source inside Windows PowerShell, no compiled .exe.** Managed PCs (Defender/ASR, AppLocker) block or
  flag unsigned executables; `powershell.exe` + Add-Type of the C# source is allowed and easy to change. Rejected:
  a pre-compiled build (owner: "not pre-compile; very easy to develop and install"), and a WPF rewrite. Cost: ~1-2 s
  compile at start. Constrained Language Mode PCs cannot run it (setup says so).
- **C# 5** because the compiler that ships with .NET Framework is C# 5. Enforced by a test.
- **Own input engine as default; the classic engine optional.** One install with nothing else; the classic engine
  needs its own program and service. Old installs keep the classic engine until the user switches (never switched
  silently by an update).
- **Pinned FFmpeg, always installed next to the app**, checked by SHA256, mirrored on this repo's release. A random
  FFmpeg on PATH may lack ddagrab/SRT or change. Lookup order: the app folder's `ffmpeg\` first, then the process
  folder (powershell.exe's - a leftover fallback, harmless), PATH, winget links. (It used to look only next to
  powershell.exe, so a fresh PC without FFmpeg on PATH had no video.)
- **Video always encrypted.** An earlier fallback connected without the passphrase after two failed attempts, for the
  old pre-app script version (one unencrypted screen). Nobody runs that version and the fallback meant a picture
  could travel unencrypted, so it was removed (found by a cold-start review: README said "everything encrypted").
- **Requirements: Windows 10 1703+ and .NET Framework 4.7.2+** (SetThreadDpiAwarenessContext; PBKDF2 with SHA-256).
  Both are in every supported Windows today; documented in README.

## Pictures
- **Topmost via our own window holding the player as a child.** Windows silently ignores SetWindowPos(TOPMOST) for
  a window of a process started in the background (measured: only processes with a new console got it). Windows
  created with WS_EX_TOPMOST work, so DeskView's host is created topmost and ffplay's window is re-parented into it.
  Adoption is verified; if Windows refuses twice, the player's own window is used. Resizes are asynchronous so a
  hung player can't freeze DeskView; a hung player is restarted.
- **Latency: `-fflags nobuffer` + `-vf setpts=N*0.001/TB`.** ffplay doesn't treat srt:// as live: it schedules
  frames from the first one and never catches up, so any start-up delay (probing, Vulkan renderer init) stayed as
  permanent lag (~400 ms on loopback, ~650 ms laptop<->server). nobuffer drops the probe backlog; 1 ms timestamps
  make every frame "late" so the newest is shown and older dropped - lag drains by itself after stalls.
  Rejected: `setpts=0` (frame duration then comes from a guessed frame rate - inconsistent), wall-clock pts (drains
  too slowly after a stall), mpegts `-muxdelay 0` (no gain).
- **Key frame every 0.5 s (`-g 30`).** With nobuffer the first picture waits for the next key frame; 0.5 s bounds
  that. Earlier `-g 120` = 2 s waits.
- **No `-hwaccel d3d11va` for ffplay.** This ffplay's renderer can't use it (decode stayed on CPU) and it made the
  start slower.
- **`-nostats`** (the report grew ~7 MB/h and was re-read 4x/s). Side effect found live: ffplay then doesn't write
  the stream's size into the report -> pictures were never "live" and got restarted every 12 s. Fix: a picture is
  live when its window shows (first frame); size/position come from the other computer's own screen list (`SR`).
- **Dead streams end the player** (SRT `timeout`, `-autoexit`) instead of a frozen last frame; restarts back off
  0.5/1/2 s. Once a screen has shown a picture, never fall back to the "old unencrypted sender" or the slow 2 MB
  probe (those are for a first contact with an old DeskView only).
- **`RS` (restart listener).** SRT keeps a vanished viewer's connection ~5 s, refusing the next viewer; ffmpeg here
  has no option to shorten it. The viewing side tells the sending side over the link, which restarts the listener at
  once. Measured: player killed -> picture back 8.1 s before, 2.0 s after.
- **Sender back-off counts only real failures.** A listener that served a viewer and ended (viewer switched away) is
  restarted at once; detected from its own report ("Output #0" appears only once a viewer connected).

## Input (built-in engine)
- **Several pictures take input, each for its own screen (`MS n x y`).** Previously only the first picture worked.
  With an older agent (no `<V 2`) only one picture takes input, because it switches screens on a 250 ms timer.
- **Keyboard follows clicks on a server.** Otherwise every key typed on the server went to the laptop whenever any
  picture was live (smart screens make that common).
- **Keys/buttons released where pressed; `U` on stop.** Stops stuck Ctrl/Shift/buttons on either side. Stale held
  entries (a release missed during a locked screen) expire after 1.5 s without repeats.
- **Liveness by answered pings, timed from the oldest unanswered ping.** A dead link (laptop asleep) hands input
  back within ~4 s; idle gaps and long clipboard writes don't count.
- **Moves may be dropped on a stalled link, presses/keys/releases and the move placing a press never.**
- **File errors reach the sender.** The receiver answers `<ERR why` when it can't save, then reads away what the sender
  already sent before closing (closing with unread data makes Windows reset the connection, which also destroyed the
  reason); the sender checks for an early answer while sending. Was flaky 3 of 4 runs, now 10/10.
- **Pointer back first, clipboard after** (a big clipboard no longer holds the keyboard hostage). Clipboard also
  follows the keyboard in picture mode (`CQ`).

## Smart screens
- Screen n -> monitor n-1 (the main screen stays the laptop's own). Give-back after 3 s empty.
- **User intent wins and survives**: a monitor the user gave back stays given back until that screen is really empty
  for 5 s with the laptop connected; a disconnect is not "empty". Persisted in settings (a restart once grabbed the
  owner's monitors - found live).
- A screen whose picture never comes is not retried for 5 minutes (it looped every ~25 s).

## Setup
- Questions and downloads first while the old DeskView runs; stop/copy/start in `try/finally` (always started
  again); FFmpeg swapped by folder renames with roll-back (a half-deleted FFmpeg broke the app).
- Extra-screens question asked once per laptop (an update hung waiting for an answer in a scheduled task); the
  answer is remembered only after it worked.
- Uninstall removes only what DeskView installed (virtual display driver marker), never someone's own driver.
- Settings: `.bak` kept on every save; a corrupt file falls back to it (a server must never silently mint a new
  pairing code); a briefly locked file is retried, not treated as corrupt.
- Start at sign-in = the Startup shortcut (the old Run-key entry pointed at powershell.exe and failed).

## Review rounds (how these were found)
- Round 1 (3 critics: pictures / input / install + judge): 26 confirmed, all fixed. Judge rejected: warm standby
  players (cost vs 1-2 s gain), roaming-profile and SYSTEM-install worries (speculative), blocking Program firewall
  rules (too invasive), mirrored driver release (later).
- Round 2 (critics on the round-1 diff): 15 confirmed fixes-to-fixes (false link drop at forwarding start, lasting
  lag on the long probe, older-agent multi-picture, shared report files, FFmpeg swap, live->dead between ticks,
  uninstalling foreign drivers, focus-stealing re-raise, held buttons on keyboard-only switch, toast buried, drive
  roots, setup reading .bak, settings lock retry, long ERR replies, dropped press-move). Rejected: "shorter GOP has no
  benefit" (a critic's claim - wrong: with nobuffer the key-frame interval bounds the first picture, so -g 30 stays), GPU-path fallback by exit code (speculative), clipboard race (ms window).
- Live QA then found three more the reviews missed: report without stream info (-nostats), smart screens grabbing
  monitors after a restart / after a disconnect, ~400-650 ms video lag. All fixed with tests where testable.

## Video key never written to a file (reports written by the app, not FFREPORT)
- FFREPORT copies the whole command line into `%TEMP%\deskview-ff*.log`, and the SRT address on it carries the
  passphrase. The video key is an unsalted SHA256 of the short pairing code, so one leaked report allows an offline
  search for the code - which is also the input link's key.
- FFmpeg 9 cannot take SRT options from a file (`-/passphrase file` -> "Unrecognized option"), so the key stays on the
  command line (other processes of the same user can read it - same trust as the settings file). What we control is
  what gets written: ffmpeg/ffplay now run with `-loglevel info` and the app drains their error output into the
  report itself (`Media.StartReported`), passing every line through `Media.Redact` (`passphrase=***`). Redaction is
  needed beyond the header: ffmpeg prints the full address in its own errors ("Connection to srt://...?passphrase=...
  failed").
- A run that was replaced must not write into its successor's report: each report path has a run number, and late
  lines of an old run are dropped. The file is opened per line (few lines with -nostats) so it can be read, deleted
  and recreated at any time.
- Owner action after updating: change the pairing code on both PCs (old reports may have been copied elsewhere).

## The person at the computer wins; never crossed control (R1, first part)
- Seen live: both PCs typed on each other, and a laptop's touchpad moved the other PC. Cause: each PC's forwarder
  decided alone, and the pointer the other PC hands back rests on this PC's own switching edge - one touch crossed.
- Rule 1, local wins: a real mouse/touchpad/keyboard event on a PC that the other PC drives (agent `edgeIn` set) gives
  the pointer back at once (`DeskViewAgent.GiveBack` -> "<L"). A click, wheel or key wins at once; moves need 3
  within 250 ms (a jittering mouse must not take control). If that PC was also driving the other one (crossed), that
  stops too ("X").
- Rule 2, never both ways: `TryEnter` does nothing while this PC is driven or was in the last 1.5 s.
- Wired in Engine (forwarder.DrivenByOther / DrivenRecently / ClaimLocal); tests and the standalone compile leave
  them null, so the input file still compiles alone. No protocol change ("L"/"X" already exist): works with old peers.
- Every switch, give-back, refused edge and Ctrl+Alt+0 press is logged (with the state at that moment); the log has
  milliseconds now, is thread safe, and rolls to `deskview.log.1` at 2 MB instead of being deleted.

## Mouse speed (council round 3, fixes 1-6)
- Moves waiting to be sent are merged (`DvMoves.Coalesce`: R summed, newest M/MS kept, never across a click/key)
  and a whole wake goes out in ONE write. After a Wi-Fi hiccup the pointer jumps to the hand instead of replaying.
- The clipboard has its own lane on the forwarder (sent only when no input waits); the agent reads its clipboard
  on a worker, never on the input thread (a program may take 400 ms to hand it over).
- AES/HMAC objects are kept per thread and key: a frame costs ~12 us instead of ~140 us (measured, link.tests).
- Input threads run at Highest priority; the process opts out of Windows power throttling (a tray app with no
  window is otherwise run as background work on laptops).
- Wi-Fi: media streaming mode on and background scans off while the computers are linked (`Core/Wifi.cs`,
  wlanapi, per user, no admin, undone by Windows when the handle closes).
- Measurement: every move carries the sender's steady-clock time (old agents read only the first numbers). The
  receiver logs `mouse-rx` every 10 s (gap p50/p95/max) and `mouse-lag` when moves stop arriving > 50 ms while the
  hand kept moving; the sender logs `mouse-tx` (merged count, queue depth, slowest write). Log writes from input
  threads go through `Log.Later` (time taken at the call, file written on a worker).
- Not done (per council): UDP for motion - only if logs show TCP stalls after these fixes.
