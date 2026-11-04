# Settle clears the Topic Note

A Topic Note tells the user where they stopped in a Topic ([ADR-0052](0052-a-topic-note-shows-in-full-on-an-open-card-and-in-the-summary-of-a-closed-card.md)). Settle marks the work as done, so a Note that stayed on the record was out of date when the user Reopened the Topic, and they had to clear it by hand. Settle now removes the Note. Dormant, Reopen and Start Fresh do not change it.

## Considered Options

- **Clear the Note on Reopen.** Rejected: a Settled card would show a Note for work that is done.
- **Clear a Note that did not change for a number of days.** Rejected for now: it needs a time stamp in the record and a Config key, and a Note on an open Topic is still where the user stopped.
