---
fragment: 7aeb525f
generation: 0001
branch: read-scope-approved
---

~ Unread
  A separate mark saved on a Topic, or a done, failed or blocked Agent update that the user has not read. Automatic visits read shown Terminal Panes only and preserve Topic Unread except on a new Empty Topic page visit.
  was: A Topic explicitly marked with Mark Unread, or an Agent with a done, failed or blocked update that the user has not marked read. Topic Unread is saved independently of Agents and remains when they exit. With Manual Read, updates stay Unread until Mark Read or Mark All as Read. Without Manual Read, a new visit to a Window or Topic clears Unread; continued viewing preserves an explicit mark. A Topic mark is not an Agent Status and does not add to an Agent count. Snooze hides its mark without clearing it.

~ Manual Read
  A Config behavior that preserves Unread during visits and Zoom changes. Agent updates become Unread even in shown Panes.
  was: A behavior the user turns on in the Config, in which visiting a Window or Topic does not clear Unread, and Agent updates become Unread even while the user looks at their Window. It is off by default, so a visit reads the Window or Topic.

~ Mark Read
  An Action that clears Unread in its named target without changing Agent Status. Its Command and direct shortcut target the current Window or its Zoomed Pane, or the Topic mark on an Empty Topic page.
  was: An Action that clears the Topic Unread mark and Unread for Agents in its target. Its Command and direct shortcut use the Active Topic, or the current Session when there is no Active Topic. It is available for every Topic, with or without Agents. A blocked Agent keeps its blocked Notification until its Status changes.

~ Mark Unread
  An Action that marks a Topic or eligible Agents in its named target Unread. Its Command and shortcut target the current Window or its Zoomed Pane, or the Topic mark on an Empty Topic page.
  was: An Action that marks any Topic as Unread, with or without Agents. It also marks read Agents with done, failed or blocked Status as Unread. Its Command and direct shortcut use the Active Topic, or the current Session when there is no Active Topic. Its row Action uses the selected Topic, Session, Window or Agent.
