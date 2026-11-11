# Diagnostics is on by default and keeps a week

Diagnostics used to be off unless the Config turned it on, and was documented as costing nothing while off. It was off for both CPU problems the user hit: the Working marks that kept the app at 40–55% CPU at idle, and the Sidebar swipe that held it at about 42% in bursts (ADR 0074). Each one took a hand-run profiling session, with the user repeating the problem on cue, before anything explained it. Evidence that is only collected after someone notices a problem comes too late. So `diagnostics.enabled` now defaults to true, in Release builds too, and the Diagnostics log keeps one file per local day for 7 days. Its raw samples are kept for 3 days. An agent can then read any day back, through `muxify diagnostics summary`, and find what was costly and what the user was doing at the time.

## Considered Options

- **Off by default, turned on when a problem shows.** No steady cost, but the minutes before and during the first occurrence are lost, and a burst that lasts seconds is gone before anyone turns it on. Rejected.
- **On by default, rotating at a fixed size (the old 20 MB × 2).** One noisy probe filled 20 MB in an hour, so a fixed size gives no promise about how far back the log reaches. Rejected in favour of one file per day with a size guard.

## Consequences

- The steady cost must stay small: one CPU read a second, the existing run-loop observer, and one line a minute. Anything costlier, such as the display-link probe, sits behind its own Config key and is off by default (`diagnostics.display_links`).
- Disk use is bounded: each day's file stops taking all but the key lines at 50 MB, and the raw samples have a total size cap.
- The log holds counts and kinds of input only, never keys, text, titles or URLs.
- A remote Config still cannot turn Diagnostics on or off. It is a setting of the Local app.
