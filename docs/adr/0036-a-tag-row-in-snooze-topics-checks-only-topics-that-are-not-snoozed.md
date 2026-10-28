---
status: superseded by ADR-0054
---

# A Tag row in Snooze Topics… checks only the Topics that are not Snoozed

> **Superseded by [ADR-0054](0054-choose-in-play-and-replace-from-bench-replace-snooze-and-zen.md):** Snooze Topics… is removed. The Check step now serves Choose In Play, and it has no Tag rows.

This changes the Tag row rule of [ADR 0035](0035-a-check-step-checks-topics-for-snooze-and-unsnooze.md) for Snooze Topics….

In ADR 0035, a Tag row of Snooze Topics… reached every Topic with the Tag in the list: the Topics section and the Already Snoozed section. A user checked #personal to Snooze its open Topics until tomorrow. One Topic of #personal was already Snoozed until next week, so the Tag checked it too, and the Snooze made it come back sooner. The note "Gets shorter: …" showed only in the next step, the "until" step. In the check step, nothing told the user that the Tag had checked an Already Snoozed Topic.

We decide that a Tag row of Snooze Topics… reaches only the Topics of the Tag in the Topics section. It does not reach the Already Snoozed Topics.

- The box of a Tag row (none, some or all), its "N/M" text and ↩ with nothing checked use only the Topics of the Tag that are not Snoozed. Space on a Tag row checks or unchecks only these Topics.
- When the Tag also has Already Snoozed Topics, the row adds " · N Snoozed" to its text, for example "1 Topic · 1 Snoozed" or "1/2 · 1 Snoozed".
- A Tag whose Topics are all Snoozed has no row in the Tags section of Snooze Topics….
- To Snooze an Already Snoozed Topic again, the user checks its own row. ⌘A does not change: it checks every Topic row that the filter shows, Already Snoozed rows too.
- "Snooze its Topics…" on a Tag row of Go to… uses the same rule. It opens the check step with only the Topics of the Tag that are not Snoozed checked.

Unsnooze Topics… does not change, because there a Tag row already reaches only the Snoozed Topics. Snooze Topic for one Topic does not change. The Snooze write does not change.

## Considered Options

- **B: the Tag checks all its Topics, and the Snooze write keeps a later Snooze.** Rejected: the user checks Topic A, chooses a time, and A does not get that time. To make a Snooze shorter, the user must Unsnooze the Topic first.
- **C: a second row for the Tag in the Already Snoozed section.** Rejected: two rows have the same name, and the list gets longer for an action that the user seldom does.
- **D: ⌥↩ in the "until" step keeps the later Snoozes.** Rejected: the default stays the surprise, and the user can easily forget a hidden key.

## Consequences

- A Tag row can show "all" checked while an Already Snoozed Topic of the Tag stays unchecked.
- The " · N Snoozed" text tells the user in the check step that the Tag has Already Snoozed Topics that it does not check.
- The "until" step still names each Snooze that gets shorter. Now that happens only when the user checked the Already Snoozed Topic by its own row or with ⌘A.
