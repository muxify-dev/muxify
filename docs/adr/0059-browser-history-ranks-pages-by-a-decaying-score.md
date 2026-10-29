# Browser History ranks pages by a decaying score, and its hosts and paths get the score of their pages

The address field of a Tab did not suggest anything. The user typed the full URL, or a search, each time. Browser History records the pages that the user loads, so that the address field can suggest them ([ADR 0060](0060-the-address-field-suggests-in-a-list-under-it.md)).

## One store, and the hosts and paths come from it

Browser History keeps one History entry for each page. A History entry has the match key of its URL (as `BrowserTab.matchKey` makes it), the URL, the title, its visits of the last 7 days, one folded score for its older visits, and the ids of the Topics where the user visited it.

The user goes to `github.com` without loading that page. Each visit is to a page below it, such as `github.com/muxify-dev/muxify/pulls`. So the hosts and paths are not stored. Muxify makes a prefix tree from the History entries: a host, then each path segment below it. The score of a node is the sum of the scores of the History entries below it. A node with only one child folds into it. This tree is in memory only. Muxify makes it again after a change.

The tree gives a suggestion for each host and path that holds two or more History entries. Then `gi` suggests `github.com` before any page of it.

## The score decays

```text
score = old score × 0.5 ^ (days since the last visit / 14) + weight
weight: typed 2, link 1, reload 0, redirect 0
```

A load is typed when the user starts it from the address field or from a suggestion. Muxify applies the decay when it reads a score. A page that the user stops visiting loses half its score each 14 days.

## The visits of the last 7 days stay apart

The Command Clear Browser History removes the visits of a time that the user chooses: the last hour, 6 hours, day, 3 days or 7 days, or all time. One number cannot do this, because it cannot tell its visits apart. So a History entry keeps each visit of the last 7 days, with its time and its weight. When a visit becomes older than 7 days, Muxify folds it into one score, at the time of that visit. Muxify folds at each record and when it reads the file.

The score of a History entry is the folded score, decayed from its time, plus the weight of each recent visit, decayed from the time of that visit. The decay is exponential, so this sum is equal to the formula above for the same visits. A unit test checks this.

A range removes each recent visit at or after its start. No range is longer than 7 days, so a range never needs a folded visit. A History entry with no visit left goes, and the prefix tree changes with it. All time removes the file.

A file from before this change has one score and the time of the last visit for each History entry. Muxify reads it as a folded score at that time, with no recent visits. When a range holds that time, the folded score goes as a whole, because Muxify cannot tell which of its visits are in the range. This makes the user lose more than the range, not less.

The Topic ids of a History entry stay when a range removes visits. A Topic id is not tied to a visit.

## The order of the suggestions

Each query word must match by the rules of the palettes ([ADR 0049](0049-a-query-ranks-by-score-across-the-palettes-rows.md)): the history scheme, and 55% of the word's own score or better. Then:

1. **Tier 1.** The query is the start of the host, without `www.`, or the start of a host and its path.
2. **Tier 2.** Each query word matches at the start of a word of the host, the path or the title.
3. **Tier 3.** Each other match.

In a tier, the higher score comes first. A History entry from the Active Topic counts with twice its score. An open Tab of the Window counts as a typed visit of now. The search row is always last.

This is not the rule of ADR 0049, where the better match always comes first. For the palettes, that rule is correct: the user types the name of a thing. For URLs, a site that the user visits each day must come before a site that the user saw once, also when the second site matches a little better. So the tiers are coarse, and the score decides in each tier.

## What Muxify records

- **Recorded:** the end of each load of the main frame of a Tab (`didFinish`), with its URL and title.
- **Not recorded:** a load that a Browser command starts, or a load while a Browser command runs on the Tab. The pages of an Agent are not the habits of the user.
- **Not recorded:** `about:blank`, the source of a redirect, a reload, frames, and a URL whose query or fragment has a key from a fixed list of secrets (`token`, `access_token`, `code`, `sig`, `signature`, `password`, `key`). A sign-in that gives its token to the page puts it in the fragment, as `#access_token=`.
- **Title only:** a navigation in the same document (`pushState`, a fragment). A single-page app changes its URL many times for one visit.

## Where it is stored, and when

Browser History is one file for the Mac, `$XDG_STATE_HOME/muxify/browser-history.json`, beside the Topic records. It is not stored on the tmux Window as Browser state is ([ADR 0003](0003-browser-state-lives-on-the-tmux-window.md)). It must stay after a tmux server restart, and it is for all the Windows of all the Environments. The Browser runs on the Mac, also for a Remote Environment.

Muxify keeps the History entries in memory and writes the file a short time after a change. It keeps 10 000 History entries at most, and removes the one with the lowest score first.

Browser History is on by default. The Config key `browser.history: false` turns it off. When it is off, Muxify records nothing and does not read the file. The address field then suggests nothing: it shows no list and makes no Inline completion, as before Browser History. Clear Browser History is a palette Action with one step: choose a range ([ADR 0014](0014-every-action-runs-in-the-palettes-view.md)). The choice clears at once, so it is the confirmation. The All time row is red. When Browser History is off and its file stays, a range clears the file. When no History entry is left, Muxify removes the file.

## Considered Options

- **A store of hosts and paths beside the store of pages.** Rejected: two stores can disagree, and a host never gets visits of its own. The sum over the tree gives the same result from one store.
- **A score from buckets of age (the older frecency of Firefox).** Rejected: more data for the same order. The decay of each visit gives a smooth score.
- **Only one score, and Clear Browser History removes all or nothing.** Rejected: the user wants to remove only the last hour, day or week, and keep the older pages.
- **A full log of every visit.** Rejected: the file grows with each visit and never stops. Clearing needs the visits of 7 days only, so the older visits fold into one score.
- **Clear a range by removing each History entry with a visit in it.** Rejected: it removes the older visits of a page that the user wants to keep.
- **SQLite.** Rejected for now: 10 000 History entries and their visits of 7 days fit in memory, and the matcher runs in memory for each key.
- **A sum with weights for the match and the score, as in ADR 0049's Considered Options.** Rejected: the weights need tuning, and the order is hard to predict. Tiers then the score give most of the gain.
- **One Browser History for each Environment.** Rejected: the pages are the user's, on the Mac, whichever tmux server shows.
- **Off by default.** Rejected: the address field then suggests nothing until the user finds the key, and a user who never finds it sees no gain. The file stays on the Mac, and Clear Browser History removes any part of it.

## Consequences

- The ranker is one pure function of the History entries, the live rows, the query, the Active Topic and the time. Unit tests check its order without the app.
- A History entry keeps the Topic ids where the user visited it. When a Topic is forgotten, its id stays in the file until the History entry goes.
- A secret in a URL whose query or fragment key is not in the list gets recorded. The file is in the user's state folder, with the Topic records.
