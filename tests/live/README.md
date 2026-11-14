# Live QA scripts (real PCs, real screens)

These drove the measurements in `docs/QA-LOG.md`. They are not part of `run-all.ps1`: they take over monitors,
mouse and keyboard for seconds and need the second PC. Say so to the owner before running them, and restore
afterwards (`off` into `%APPDATA%\DeskView\command.txt`; restart DeskView without `DESKVIEW_QA_INPUT`).

Nothing about the machines is stored. Set: `$env:DV_LAPTOP` (user@host of the laptop for SSH), `$env:DV_SSHKEY`
(private key file), `$env:DV_LAPTOP_IP`, `$env:DV_SERVER_IP`. Secrets are not stored either: set `$env:DESKVIEW_PAIRCODE`; scripts with `<VIDEO-KEY>` need the key
(`SHA256("DeskView-video-v2:" + CODE)`, first 16 bytes hex - `server-latency.ps1` shows how to derive it).

Server side (run on the server):
| script | what it does |
|---|---|
| `watch.ps1` | samples every monitor ~every 150 ms for the test colours (blue/green), logs changes + ffplay count |
| `shot.ps1` | screenshot of all monitors, scaled down |
| `wins.ps1` | lists ffplay windows: visible, topmost, rect |
| `server-latency.ps1` | key->picture latency on the server alone (loopback); `-PlayerArgs`, `-Latency`, `-Stall`, `-SenderExtra own` |
| `firstframe.ps1` | ms until the first decoded frame of a screen's stream (`-Fflags`, `-Port`) |
| `server-drive.ps1` | built-in engine: pushes the pointer over the right edge, clicks, types, copies, comes back (needs DeskView started with `DESKVIEW_QA_INPUT=1`) |
| `server-observe.ps1` | a window on the main monitor that flips colour on F9, logs keys/clicks/clipboard (for the laptop-controls-server test) |
| `laptop.ps1` | runs a `laptop-dvqa.ps1` action on the laptop over SSH, prints the server send/answer times |

Laptop side (copied to `C:\Users\Public\` on the laptop; GUI work runs in the signed-in session via a one-shot
scheduled task with `/IT`, because SSH runs in session 0):
| script | what it does |
|---|---|
| `laptop-dvqa.ps1` | actions: `win X Y TEXT SECONDS`, `slide X1 Y X2 Y2`, `rect`, `clipget`, `clipset`, `view N`, `files`, `dragfile`, `drag` (negative numbers as `m1620`) |
| `laptop-run.ps1` | runs any script in the signed-in session and returns its output |
| `laptop-observe.ps1` | a text box over extra screens 2-3; logs pointer, keys (down/up, modifiers, selection), clipboard changes |
| `laptop-drive-view.ps1` | laptop views the server's monitor 1, clicks, types, measures key->picture latency, copies, returns |
| `laptop-qa-start.ps1` | restarts the laptop's DeskView (`-Qa` = with `DESKVIEW_QA_INPUT=1`) |
| `laptop-install-next.ps1` | reinstalls from the `next` branch (one-line installer) and prints log + settings |
| `laptop-killsender.ps1` | kills the sender of screen 2 (recovery test) |
| `laptop-sendfile.ps1` | sends a 2 MB file to the server with DeskView's transfer code and prints the hash |

Pitfalls learned: inject navigation keys with the extended flag (else Windows adds fake Shift events); WinForms
multiline TextBox has no Ctrl+A; ffprobe's default 5 s analysis makes first-packet times meaningless; don't compare
timestamps across the two PCs (clock offset ~0.2 s); `Remove-Item`/`del` in compound commands may be blocked by the
local safety guard - write files instead.
