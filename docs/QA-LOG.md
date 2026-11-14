# QA log - what was proven, with numbers

All on the owner's two PCs (server SERVER-PC, 3 monitors, wired; laptop laptop, Wi-Fi, 3 extra screens).

## Automated suites (last full run)
csharp5 2/2 · app 41/41 · link 46/46 · files 11/11 · setup 10/10 · mapping 20/20 · gui 40/40 · gui-deep 112/112
(every control, with proof; report `%TEMP%\deskview-deep-qa\report.html`) · input 22/22 (on the laptop, real hooks).

## Live, built-in engine only (classic engine not running)
| what | result |
|---|---|
| server -> laptop over the right edge: pointer | enters at the same height, follows every move (16-30 ms steps) |
| click + typing on the laptop | click lands; "deskview!" typed incl. Shift+1 |
| clipboard server -> laptop | there at the moment of switching |
| clipboard laptop -> server | copied text there when the pointer came back |
| laptop views + controls the server (Ctrl+Alt+1) | 12/12 keys arrived; clipboard laptop -> server on start |
| files laptop -> server, server -> laptop | 2 MB / 1.5 MB, identical SHA256, receiver confirmed (DONE) |

## Pictures
| measure | before | after |
|---|---|---|
| picture start (smart screen, window appears on laptop extra screen) | 5.7 s | 1.0-1.5 s |
| player killed -> picture back | 8.1 s | 2.0 s |
| laptop sender killed -> picture back | 8.5 s | ~6.8 s (3-5 s frozen, then restart) |
| key -> picture loop, loopback on server (video only) | ~400 ms | 150-190 ms median |
| same after a 1.5 s stall | stays behind | back to normal within ~2 s |
| key on laptop -> server -> picture back on laptop (Wi-Fi) | 658 ms median | not re-measured yet with the new player |
| frames per second on an idle extra screen | 57 fps (capture repeats frames) | - |
| window sliding across 3 monitors (laptop screens 4->3->2) | continuous, both halves visible while crossing | - |
| pictures in front of the server's own windows | were hidden behind them | always in front (screenshot) |
| smart screens: show / release | shows in ~1 s; gives back 3 s after empty | survives restarts and disconnects |

## How to repeat (scripts used live)
- Monitor watcher (server): samples each monitor every ~150 ms for the test colours, logs changes with times.
- Laptop actions over SSH run in the signed-in session through a one-shot scheduled task (`/IT`), writing results
  to `C:\Users\Public\*.txt` (helpers `dvqa.ps1`, `laptop-run.ps1`, `laptop-observe.ps1`, `laptop-drive-view.ps1` on the
  laptop; see their headers). Start DeskView with `DESKVIEW_QA_INPUT=1` so injected input counts as real.
- Latency: a test window flips colour on a key press / timer; time until the picture shows it, sampling one pixel
  (GetPixel) - one clock, no sync needed.
- Injected test keys: navigation keys need the extended flag (keybd_event flag 1), or Windows adds fake Shift
  events (looked like a DeskView bug - it wasn't). WinForms multiline TextBox has no Ctrl+A.
- Clock offset laptop vs server measured ~0.2 s (rough, over SSH) - don't compare timestamps across machines.
