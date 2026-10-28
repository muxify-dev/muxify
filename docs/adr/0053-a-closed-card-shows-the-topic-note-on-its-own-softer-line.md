# A closed card shows the Topic Note on its own, softer line

[ADR-0052](0052-a-topic-note-shows-in-full-on-an-open-card-and-in-the-summary-of-a-closed-card.md) put the Note of a closed card first in its Summary, in the grey of the Summary. There, the Note looked like the rest of the Summary, and a long Note cut off the Sessions and Windows after it. The Note is the line that tells the user which Topic to pick, so it must stand out on a closed card too.

- **Every card shows the Note on its own line.** A closed card shows the same ✎ and yellow line as an open card, under the title and above the Summary. The line wraps, so all of the Note shows.
- **On a closed card, the yellow is softer.** It is at 60% opacity. The Note of the Location's card stays the one that stands out most.
- **The default Topic Summary does not have `#{topic_note}`.** The card already shows the Note, so the default Summary does not show it a second time. The placeholder stays, and a Config that puts it in `sidebar.formats.topic.summary` shows the Note in both places.

## Considered Options

- **Only the Note part of the Summary in yellow.** Rejected: Formats have no colour, so this needs styled spans in the Format engine. A long Note still cuts off the Sessions and Windows.
- **The Note on a closed card cut to one line.** Rejected: the user wants to read all of the Note before they pick the Topic.
- **The same yellow as the open card, at full strength.** Rejected: with Notes on many cards, the Location's Note does not stand out. 75% and 45% were also compared; 60% is quieter than the open card and still easy to read.
