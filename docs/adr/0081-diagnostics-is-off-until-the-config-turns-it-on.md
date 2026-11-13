# Diagnostics is off until the Config turns it on

`diagnostics.enabled` defaults to false, in Debug and Release builds alike. Diagnostics runs only when the Local Config sets it to true, and stops when the Config sets it back. This supersedes the default of [ADR 0075](0075-diagnostics-is-on-by-default-and-keeps-a-week.md). While it is on, everything else in ADR 0075 still applies: one file per local day kept for 7 days, raw samples kept for 3 days, and the size guards.

Diagnostics costs something on every Mac that runs Muxify: a CPU read every second, a `minute` record, the BodyCount ticks, and samples of the process during each freeze and Burst, written to disk whether or not anyone reads them. The user who wants that evidence turns it on explicitly.

## Consequences

- A freeze or a Burst that happens while Diagnostics is off leaves no record. To investigate one, turn Diagnostics on first, then reproduce the problem.
- BodyCount counts only while Diagnostics is on, so the TestDriver's `counts` reads nothing without it. A verify suite that reads `counts` or the Diagnostics log turns Diagnostics on in its Config.
- A remote Config still cannot turn Diagnostics on or off.
