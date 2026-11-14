# Open issues, next steps, ideas

Ordered by importance. When fixing one, add the reason to DECISIONS.md and numbers to QA-LOG.md.

## To verify next (changed last, not yet proven live)
1. **New low-latency player on the real link** (laptop <-> server over Wi-Fi). Loopback went ~400 -> ~170 ms;
   repeat `laptop-drive-view.ps1` (it measures key -> picture on the laptop). Target < 200 ms wired, < 300 ms Wi-Fi.
2. **First picture with `nobuffer`** now waits up to one key frame (0.5 s): re-measure smart-screen start.
3. Built-in engine **edge switching from the laptop to the server** (only the "view" mode was tested from the laptop).
4. **Drag a real file onto a picture** (OLE drag into the drop zone). Transfer itself is proven both ways; the
   synthetic OLE drag hung the test (DoDragDrop) - needs a real-hand test or a better harness.

## Known problems
- **Wi-Fi SRT latency 150 ms** adds ~150-280 ms. Try 80-100 ms on the owner's Wi-Fi and watch for drops
  (`discardcorrupt` hides them; count them).
- **Sender killed -> 3-5 s frozen picture** before the player notices (SRT `timeout` 3 s didn't fire earlier than
  SRT's own 5 s idle). Idea: the sending side tells the viewer "my sender restarted" (like `RS` the other way), but
  it must not restart a player that just connected to the new listener (race - compare start times).
- **Smart screens are a fixed mapping** (screen n -> monitor n-1). Users may want screen 2 on monitor 3. Idea: let
  smart screens remember where the user last put each screen.
- **The classic engine's Windows service stays installed** on the server when the built-in engine is used (idle).
  Setup could offer to remove it (admin).
- **Pointer acceleration**: relative moves over the edge carry Windows' acceleration twice (local + remote feel).
  Consider sending raw input deltas (RAWINPUT) instead of hook positions.
- **Old ffmpeg in `%TEMP%`**: FFmpeg zip cache (82 MB) is kept in %TEMP% for re-installs; could move to
  `%LOCALAPPDATA%\DeskView-cache` and be cleaned by uninstall.
- **Virtual display driver comes from winget (unpinned).** Mirror a signed, pinned release like FFmpeg.
- **gui tests take over a monitor for ~1 s** (picture host tests): fine on a dev PC, annoying on a shared one.

## Ideas (owner asked "what would you add")
- **Warm standby pictures**: keep the extra screens connected but hidden so smart screens show in < 100 ms
  (cost: constant bandwidth + decode; maybe only on wired).
- **One stream for all extra screens** (a wide capture) to cut processes and connections.
- **Audio** of the laptop on the server's speakers (same SRT path, `-f dshow`/WASAPI loopback).
- **Drag a window across machines with the mouse held** (today: drop on an extra screen, or edge without button).
- **Status page in the app**: per picture fps, latency, drops, restarts (all already in the logs).
- **Signed release zip + winget manifest** for a cleaner "one download".
- **Linux/macOS client**: the protocol is plain text over an HMAC session; ffmpeg exists there.
