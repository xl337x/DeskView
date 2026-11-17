# History: what the owner asked for, and what was delivered

Newest last. Use it to understand intent behind the code ("why is it like this?").

## Goals the owner set (still the target)
- "DeskView": any window ("tab") from either computer onto any monitor, **smooth** ("full smooth is a must").
- Works both ways; **one single download** on any system; clipboard and **drag-and-drop files** work.
- **Without the classic engine** - DeskView's own keyboard/mouse engine must do everything.
- Easy to develop (no pre-compile), deeply QA'd **with proof**, many **fallbacks** ("don't assume the best scenario").
- Commits as xl337x only, never name the classic engine, push everything.

## Timeline
1. Use the existing DeskView repo (not a WPF rewrite); critic agents + one judge chose the architecture: run from
   source inside Windows PowerShell (no unsigned exe), C# 5.
2. Overview page blinking fixed; deep GUI tests with proof (112 checks, every control).
3. Laptop windows onto the server's monitors: **virtual extra screens** on the laptop (Virtual Display Driver),
   screen n shown on monitor n-1; multi-portal support for the classic engine.
4. On-screen **guide** (strip with "Give back"/"All back", toast on switching) - the owner asked for a "roller /
   transparent window that tells the user how to get back".
5. **Smart screens**: a window dragged onto a laptop extra screen makes that screen appear on a server monitor by
   itself; given back when empty. Screen counts detected dynamically.
6. Stress/fallback campaign ("move all tabs from all screens, detect all errors"):
   - pictures hidden behind local windows -> picture host (topmost window of ours holding the player);
   - picture start 5.7 s -> ~1 s (nobuffer dropped the first key frame; 2 s GOP);
   - player/sender recovery 8 s -> 2 s (`RS` message);
   - setup stuck on a question during updates -> asked once.
7. Critic round 1 (26 fixes) and round 2 (15 fixes to the fixes) - see `docs/REVIEWS.md`.
8. Live QA found what reviews missed: pictures restarted every 12 s with the pinned FFmpeg (no stream info with
   -nostats) -> screen geometry over the link (`SR`); smart screens grabbing monitors after restarts/disconnects ->
   persisted memory + 5 s rule.
9. Owner: "check smoothness, make it fast, test from the other laptop, mouse/keyboard/clipboard/files, all without
   the classic engine". Both PCs switched to the built-in engine; proven: edge switching, typing, clipboard both
   ways, laptop controlling the server, files both ways. Latency found 400-650 ms -> player fix to ~170 ms
   (loopback); the real-link number is still to be re-measured (OPEN-ISSUES #1).
10. Owner asked to make the repo a "brain" so a new session understands everything: AGENTS.md + docs.

## Machine state when this was written
- Both PCs: latest `main`, built-in engine (`InputEngine = DeskView`), DeskView running normally (no QA mode).
- Server: no monitors assigned; laptop screens 3 and 4 remembered as "given back" (they hold the owner's windows).
- Laptop: 3 extra screens on the left of its panel.
