# A check step checks Topics for Snooze and Unsnooze, and Tags are shortcuts

> **Update 2026-10-21:** [ADR 0036](0036-a-tag-row-in-snooze-topics-checks-only-topics-that-are-not-snoozed.md) changes the Tag row of Snooze Topics…. It reaches only the Topics of the Tag that are not Snoozed, and it shows " · N Snoozed" when the Tag has Already Snoozed Topics.

This replaces [ADR 0025](0025-a-pick-step-collects-topics-and-tags-as-chips.md) for Snooze Topics…. The pick step held the picked Topics and Tags as chips in the search field. To change a set, the user removed a chip and picked again, and one search was necessary for each Topic. Also, a Tag chip held all its Topics, so the user could not take out one Topic of a Tag.

We replace the pick step with a **check step**. The rows are Tags, then Topics, then Already Snoozed, as before. Each row has a box. The search field holds only the query, with no chips. The checked Topics are a set of Topics. The step shows them in the order of the list. Checked rows stay in their place in the list.

- **Space** checks or unchecks the highlighted row, also when the query is not empty. So the query of this step cannot contain a space. ⇥ does the same as Space, and a click on a row does the same as Space. **⌘A** checks every Topic row that the filter shows. When all of them are already checked, ⌘A unchecks them.
- A **Tag row** is a shortcut, not a member of the set. Its box comes from its Topics in this list: none, some or all of them are checked. When some are checked, the row shows "2/3". Else it shows "N Topics". Space on a Tag row with none or some checked checks all its Topics. Space on a Tag row with all checked unchecks all its Topics. Then the user can uncheck one Topic. The box has the colour of the Tag in the Config, as a Tag Mark has.
- **↩**: with one or more Topics checked, ↩ on any row goes on with the checked Topics. With none checked, ↩ on a Topic row goes on with that one Topic, and ↩ on a Tag row checks its Topics and stays in the step.
- The **note line** names the checked Topics ("Snoozes: a, b, c, d +2 more"). When the filter hides checked Topics, it says "2 checked are not shown". It always says what ↩ does now, for example "↩ Snoozes 3 Topics…" or "↩ checks #backend".

The three problems that ADR 0025 named, and how the check step solves them:

1. **The set was not visible.** The note line names the checked Topics, and each checked row has a checked box.
2. **A filter hid the marked rows.** The note line names the checked Topics also when the filter hides their rows, and it counts the hidden ones. The checks stay when the filter changes.
3. **↩ by reflex on the first row, a Tag, Snoozed every Topic of the Tag.** With nothing checked, ↩ on a Tag row only checks its Topics. One ↩ by reflex on a Topic row Snoozes only that Topic, as Snooze Topic does.

**Unsnooze Topics…** is a new Command (`unsnooze_topics`, unbound). It uses the same check step with only the Snoozed Topics, and each row shows "until …". A Tag row counts only the Snoozed Topics. Going on does not open an "until" step: one Unsnooze write runs for the set at once. The note line says "Unsnoozes: …" and "↩ Unsnoozes N Topics". ↩ works as it does for Snooze.

**Unsnooze Topic** now shows when a Snoozed Topic exists. While the Active Topic is Snoozed, it Unsnoozes it at once, as before. Else it opens a "choose a row" step of [ADR 0014](0014-every-action-runs-in-the-palettes-view.md) with the Snoozed Topics, and ↩ Unsnoozes one Topic.

## Considered Options

- **B: a "Checked" section at the top of the list.** The checked rows move to it, and the filter does not apply to it. Rejected: a row moves away when the user checks it, so the highlight jumps, and the list changes under the user.
- **C: chips in the field as a mirror of the checked set.** Rejected: the set then has two views. The user can try to remove a chip with ⌫, and ⌫ then must uncheck the last Topic.
- **E2: with nothing checked, ↩ does the same as Space.** Rejected: one ↩ on a Topic then does not Snooze it, which is different from Snooze Topic.
- **E3: ↩ only checks, and a "→ Snooze N Topics…" row goes on, as in ADR 0025.** Rejected: the user must find the go-on row each time, and the go-on row is the reason for the second meaning of the first row.
- **S1: Space checks only when the query is empty.** Rejected: to check a Topic that the filter found, the user must clear the query or use ⇥.
- **S3: Space checks and clears the query.** Rejected: to check two Topics that one query finds, the user must type the query again.
- **T2: T1, and ↩ on a Tag row puts `#tag` in the query.** Rejected: T1 gives the same result. The user checks the Tag, then unchecks some Topics.
- **U1: keep Unsnooze Topic as it was.** Rejected: it showed only while the Active Topic was Snoozed, which is rare, because a Snooze of the Active Topic opens the Next Topic.
- **U3: Unsnooze Topic is Unsnooze Topics… with the Active Topic checked.** Rejected: it is U1 in a different view, and it needs two steps for one Topic.

## Consequences

- Snooze Topic still starts at the "until" step with its Topic. ⌫ in the empty "until" field goes back to the check step with the checks kept. When ↩ went on with one Topic with nothing checked, ⌫ goes back with that Topic checked.
- "Snooze its Topics…" on a Tag row of Go to… opens the check step with the Topics of the Tag checked.
- The "until" step and the Snooze write do not change: one time for the whole set, and the step names each Snooze that gets shorter.
- The Tag field of New Topic and Edit Tags keeps its chips and the chip keys of ADR 0025.
- Later Actions on several Topics, such as Mark Read or Settle, use the check step and do not need a new ADR.
