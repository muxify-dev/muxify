# A Topic Note shows in full on an open card, and in the Summary of a closed card

A user who works on many Topics loses track of what they were doing in each one. A Topic Note is one line of text on the Topic's record that tells them. The goal is to see the Note at the moment of a switch: before the user picks a Topic, and when they arrive at it.

- **An open card shows the Note on its own line.** The line is under the title, in yellow, with a ✎, and it wraps so that all of the text shows. The card of the Location is open, and an open card shows no Summary, so the Note needs its own line there.
- **A closed card shows the Note through its Summary.** `#{topic_note}` is a Format placeholder, and the default Topic Summary puts the Note first: `#{?topic_note,#{topic_note} · ,}` followed by the earlier default. The text is grey and has no ✎, as all Summaries do. A Topic with no Note shows the same Summary as before. The user can move or remove the Note in `sidebar.formats.topic.summary`.
- **Topic rows in a Command Palette show the Note under the title,** so a search for a Topic also shows where the user stopped.
- **Set Topic Note and Clear Topic Note are Actions on a Topic.** Set Topic Note types one value, and the field starts with the current Note, so a change is a small edit. ↩ on an empty field clears the Note. Clear Topic Note runs at once and is listed only when the Topic has a Note. Both are also Commands on the Active Topic. Set Topic Note has the keybinding `set_topic_note`.
- **The Note is one line.** It is a reminder, not a document. A longer text belongs in a file of the Topic's repository.
- **The Note stays on the Topic's record.** Snooze, Zen, Dormant, Settle and Reopen do not change it. A Reopened Topic shows where the user stopped.
- **A Locked Session has no Note.** It is not a Topic, as with Snooze and Pin.

## Considered Options

- **The name Next Step.** Rejected: it is wrong for a Note such as "waiting on Ana's review", and the Actions become longer.
- **The Note only as a Format placeholder.** Rejected: an open card shows no Summary, so the user would not see the Note of the Topic they are on.
- **A ✎ mark on closed cards, and the Note only on the open card.** Rejected: the user must open a card to read its Note, so the Note does not help them pick a Topic.
- **The Note over the Terminal for a few seconds after a switch.** Rejected for now: the Location's card already shows it.
- **The age of the Note, such as "2d".** Rejected for now: it adds text to every card for a small gain.
