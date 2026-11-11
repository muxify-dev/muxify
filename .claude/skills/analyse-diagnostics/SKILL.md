---
name: analyse-diagnostics
description: Analyse Muxify's Diagnostics log into ranked findings about its code. Use when the user asks to analyse a day's Diagnostics, or why Muxify was slow, hot, frozen or growing in memory.
---

# Analyse Diagnostics

Turn one day of the Diagnostics log into ranked, evidenced findings about Muxify's code, then stop. Every record and field is defined in `docs/development.md` "## Diagnostics"; read it when a name below is unclear. The work is read-only: the summary, the log and the samples change nothing.

## 1. Run the summary

Run `muxify diagnostics summary` for today, or `muxify diagnostics summary --date YYYY-MM-DD` for another day ("yesterday" is a date too). `--folder PATH` reads another folder, such as a verify Sandbox's kept logs in `build/verify/runs/<run>/<suite>/app-logs/<sandbox>/`. Without an installed `muxify`, use the Debug build's: `build/Build/Products/Debug/Muxify.app/Contents/Resources/bin/muxify`. Exit 1 means there is no file for that day; tell the user which folder and date.

The summary is the count. Take every figure from it, or from the records it points to, never from hand-counting or grepping totals out of the raw log.

Done when you have read every section: Day, CPU, Main thread, Memory, Bursts, Freezes, Errors and Trend.

## 2. Pick suspects

Go through these in order and write down each suspect with its time and figures:

1. **Idle minutes with high app CPU or main-thread busy share.** The CPU section's `idle` rows (`app` p50, p90, max) and the Main thread section's `idle` row. An idle app should be near zero; a p90 of several % or a `main.busy` above a few % is a suspect. Find its minutes with `grep " minute " <day file>` and keep those with `input=idle`.
2. **The worst Bursts**, as the summary ranks them by `cpu.avg × length`.
3. **Freezes**, with their lengths.
4. **Memory growth**: `app` start, end and peak; an end well above the start, or a group's peak far above its usual.
5. **A trend line that jumped**: today's Trend line against the earlier days' (idle p50, with input p50, bursts, freezes, peak mem).

Done when each suspect has a time window and its figures, or the day has none. A calm day is a finding: say so and stop.

## 3. Read the evidence behind each suspect

- **Its `digest` lines.** The summary prints them under each Burst and freeze; the full records are `grep " digest sample=<file>" <day file>`.
  - `busy` high: the cost is on the main thread. `busy` low while `cpu.avg` is high: it is off the main thread, so read the other threads of the raw sample.
  - `libraries` led by `AttributeGraph`, `SwiftUICore` or `SwiftUI` means SwiftUI's view graph updating.
  - `frames` are the app's own frames by inclusive time. `__debug_main_executable_dylib_entry_point` and `MuxifyApp.$main()` are always 100%; read past them.
- **The raw sample**, `burst-<time>.txt` or `freeze-<time>.txt` in the same folder, while it is still kept (3 days, 300 MB in all). Read the main thread, the one on `DispatchQueue_1: com.apple.main-thread`: follow the heavy branches down to the app frame under SwiftUI's update, such as `TimelineView<>.UpdateFilter.updateValue()` or `<View>.body.getter`. An idle minute has no sample; its record is the evidence.
- **The moving state and `bodies` on its record**: `input`, `window`, `working_marks`, `marks_move`, `sidebar`, `topic_cards`, `session_rows` and `bodies`. Weigh `bodies` against the input: a `SidebarCard` count near `topic_cards + session_rows` for each `sidebar_switches` means every card ran again on each switch.

Done when each suspect has its digest's leading library and top app frames, its raw sample's main thread read (or a note that the sample is gone), and its moving state and bodies.

## 4. Map it to code

- Find each app frame in `Sources/`: `closure_#1_in_X.body.getter` is inside `X`'s body; search for the type and method names.
- Find each counted view with `grep -rn 'BodyCount.tick("<Name>")' Sources/`; the tick is the first line of its body.
- In a verify Sandbox's logs, `TestDriver.poll`, `TestDriver.dump` and `TestDriver.value` frames are the harness reading the accessibility tree, and `IdleClockCost` and `CardRebuildCost` (`Sources/Muxify/App/TestDriverCosts.swift`) are the two known patterns brought back on purpose. Name them as such.

Check both known patterns against every suspect:

- **Motion that runs every frame through SwiftUI state** (`docs/adr/0074-motion-that-runs-every-frame-goes-through-core-animation.md`). Signs: `input=idle` or a swipe, high `main.busy`, a SwiftUI-led digest, and `TimelineView`, `repeatForever`, `phaseAnimator` or a spring on `@State` in the frames; `working_marks` above 0 with `marks_move=true`. Search `grep -rn "TimelineView\|repeatForever\|phaseAnimator" Sources/`. The fix moves the motion into layers Muxify owns, as the Working marks (`CAKeyframeAnimation` in `UI/AgentMarks.swift`) and the Sidebar pager's layer transforms do.
- **A view body that reads a value that changes often**, such as the Quick Switch Hints in a card body. Signs: a Burst during `sidebar_switches`, card `bodies` (`SidebarCard`, `TopicCard`) far above the switches times the cards that changed, and a SwiftUI-led digest. Find the value the body reads at the top of the counted view. The fix reads it in a small view of its own, as `CardHints` and `HintHidesMark` in `UI/HintView.swift` do, so a change runs that view and not the card.

Done when each suspect has a file:line for its likely cause, or is marked too thin to name one.

## 5. Write ranked findings

Rank by expected gain: the CPU, main-thread share or freeze time it costs, times how long and how often it happens. Write each finding as:

- **Evidence**: times, figures, the digest lines, the body counts, and what was moving.
- **Likely cause**: the code, with `file:line`, and which known pattern it is, if any.
- **Proposed fix.**
- **Expected gain**: in the log's own units, such as "idle app CPU from 50% to near 0" or "no Burst during switches".
- **How to prove the fix**: normally a check in a verify suite, modelled on the `diagnostics` suite's proof checks (`DiagnosticsIdleCost`, `DiagnosticsSwipeCost` in `scripts/verify/suites/diagnostics.py`): reproduce the case in a Sandbox, then assert on the `burst` record's fields, the digest's leading library and the summary's Burst. A fix's check asserts the opposite, as `SidebarSwipeBurst` in `scripts/verify/suites/sidebar_swipe.py` bounds the card bodies of a swipe Burst.

When the evidence is too thin to name a cause, say so plainly in that finding and name what would decide it, such as a sample of the next Burst or `diagnostics.display_links: true`.

## 6. Stop

Give the user the findings and ask which to take. Your turn ends there, with the code untouched: never edit code on your own. When the user picks findings, start `/cook:plan` with them as the feature, passing each picked finding's text whole.

## Limits

- **Local app only.** Diagnostics is a setting of the Local app. It measures the Local app and the Local tmux server, never a Remote Environment's host.
- **`webkit` is a lower bound.** A page can have more processes than the one it names, and a new page counts from the minute after it starts.
- **`tmux` covers all clients.** The Local server serves terminals attached outside Muxify too, so its load is not all Muxify's.
- **Gaps are not calm minutes.** A gap (system sleep, screens asleep, Diagnostics off, quit, unknown) holds no data; leave it out of every idle figure and every claim that a stretch was quiet.
- A log written before body counts shipped has no `bodies` field, so the summary shows no minutes or Bursts for it.
