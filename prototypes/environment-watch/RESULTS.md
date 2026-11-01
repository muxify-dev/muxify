# Environment watch results

This is a throwaway prototype. It does not change Muxify's behavior.

## Machine and method

The run used an Apple M2 Pro Mac14,10 with 12 logical CPUs and 32 GiB of memory. The system was macOS 26.5.1 on arm64. The tools were tmux 3.8, Python 3.13.15, and Apple Swift 6.2.3. The measurement ran on 26 October 2026.

The fixture had three Sessions, twelve Windows, and twenty-four Panes. Twelve Panes reported an Agent. Each case ran five times. Each trial used the same request count and a twenty-second measurement period before shutdown. Case order reversed on alternate trials. The app build and test bundles had finished before the measurements started.

The machine was not idle. Its initial load averages were 8.95, 10.19, and 9.15. A process check showed background security and indexing work. Those processes stayed running. The ranges below include that noise.

Run the measurement from the repository root:

```sh
python3 prototypes/environment-watch/measure.py
```

The script writes [the individual runs](measurements.json) and [the table](measurements.md). [The README](README.md) defines each counter and the pipe contract. Both modes use the real MuxifyCore Inventory parser and CommandRunner. The helper uses a release build.

## Measurements

| Case | CPU s median [range] | tmux starts | tmux output bytes | Protocol bytes | Protocol lines | Request p50/p95 ms | Status attached p50/p95 ms | Status other p50/p95 ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| poll 1 Local | 0.824 [0.794, 0.849] | 46 | 332435 | 535135 | 56 | 27.5 / 35.7 | 592.2 / 1050.2 | 50.1 / 88.0 |
| watch 1 Local | 0.485 [0.439, 0.496] | 33 | 208951 | 26218 | 37 | 28.3 / 36.0 | 520.5 / 1026.5 | 2834.0 / 2839.7 |
| watch_1s 1 Local | 0.837 [0.803, 0.865] | 48 | 351427 | 26219 | 37 | 26.6 / 34.6 | 511.0 / 1029.0 | 1017.6 / 1038.3 |
| poll 2 Local | 1.320 [1.235, 1.387] | 73 | 580976 | 934732 | 83 | 27.8 / 32.9 | 570.3 / 1036.3 | 1032.4 / 1088.1 |
| watch 2 Local | 0.474 [0.471, 0.495] | 33 | 208951 | 26207 | 37 | 29.2 / 36.0 | 526.4 / 1028.1 | 2831.4 / 2841.9 |

CPU is total CPU time for the prototype reader, its helper and reaped children, plus the client. It excludes the tmux server and the fixture commands. The table gives the median and range across five trials. Counts and bytes are medians. Latency columns give pooled p50 and p95 values.

`watch` uses a five-second fallback timer. `watch_1s` uses a one-second fallback timer. Both use Status subscriptions for the attached Session. The two-reader watch case applies one stream to two separate mirrors. The two-reader polling case has two independent Inventory loops.

Protocol bytes include the prototype JSON lines in both directions. They are not measurements of today's app network traffic. The polling baseline also encodes JSON so the same client can check its results. The tmux output column measures the real helper-command stdout before that encoding.

## Verdict on the three claims

1. Watch was cheaper in this Local prototype with a five-second fallback timer. One reader used 0.485 CPU seconds instead of 0.824 over twenty seconds. Two readers used 0.474 instead of 1.320. The savings were about 0.34 and 0.85 CPU seconds per run. The corresponding tmux start counts fell from 46 to 33 and from 73 to 33.

   The slower timer accounts for part of that saving. With a one-second timer, watch used 0.837 CPU seconds. Its range overlapped the polling range, so this case showed no clear CPU saving. It also started slightly more tmux processes. Delta output still reduced protocol bytes by about 95 percent for one reader.

2. The revision promise held for every checked request over the Local pipe. The client checked the first state at the reply's exact revision. This included no-op requests and failed Window selections. Requests took about 27 to 29 ms at p50 and 33 to 36 ms at p95 across the cases.

3. The code uses one client for Local and SSH startup, but Remote behavior remains unverified. The SSH probe failed because localhost had no trusted ED25519 host key. The script did not change host keys or SSH settings. No Remote performance claim follows from these results.

Keep the shared module and revision design as a candidate for production work. Delta output saves pipe bytes even with a one-second timer. Before adopting the slower timer, cover Status changes in every Session with subscriptions and measure again. In this load, another Session's Status took about 2.83 seconds to arrive with the five-second timer.

## Checks and limits

`make build` passed. `make test` passed with 906 tests, two skipped, and zero failures. The prototype's release build and Python syntax checks passed.

All 25 measurement trials passed. The client checked 250 request revisions, including 25 no-ops and 25 expected failures. There were no unexpected request failures. Every trial confirmed server cleanup after checking its socket path. The final process check found no prototype reader, helper, or throwaway server left running.

Each case has 40 request-latency observations. Attached-Session Status has 20 observations per case, or 40 for two polling readers. Other-Session Status has five observations per case, or ten for two polling readers. The small sample and fixed load offsets make the Status percentiles sensitive to timer phase. They are not general tail-latency estimates.

A separate profile used one watch trial and is excluded from the table. It showed event and timer waits as the main elapsed-time cost. Inventory publication took about 0.17 seconds across ten reads during that profile. Child CPU was about 0.12 seconds, compared with about 0.06 seconds in the Python watch process. The read count and child-process work explain the CPU reduction when the timer is slower.

This comparison models the Inventory loop. It excludes the app UI, Topic rules, process inspection, Codex report files, and Remote ownership probes. Its JSON representation also keeps raw Inventory rows beside typed fields for validation. The byte totals are specific to that representation. The results establish behavior for this fixture and load, not a total app speedup or a worst-case latency bound.

## Status in every Session

The five-second timer made Status in other Sessions slow, because a `%*` subscription covers only the attached Session. A second run tested a fix: `watch_all` keeps the five-second timer and subscribes to `#{S:#{W:#{P:#{pane_id}=#{@muxify_agent_status};}}}` for the attached Session. The `S:` loop expands every Session, so tmux pushes a change in any Session. A probe on a throwaway server showed the push for a Session that no client had attached. This needs no extra process and no hook. The new `set-hook -B` monitor hooks in tmux 3.8 were not needed, so they were not tested.

The run used the same fixture, load and method, with five trials of each case. It also counted the tmux server's CPU, because the subscription moves work into the server. It ran on 26 October 2026 with load averages of 3.49, 4.81 and 4.32 at the start. Absolute CPU values are lower than in the first run, so compare cases inside one run only. Run it with:

```sh
python3 prototypes/environment-watch/measure.py --output prototypes/environment-watch/measurements-status.json
```

The runs are in [measurements-status.json](measurements-status.json) and the table is in [measurements-status.md](measurements-status.md).

| Case | CPU s median [range] | tmux server CPU s | tmux starts | Request p50/p95 ms | Status attached p50/p95 ms | Status other p50/p95 ms |
| --- | --- | --- | --- | --- | --- | --- |
| poll 1 Local | 0.694 [0.577, 0.737] | 0.100 | 46 | 28.4 / 59.1 | 575.6 / 1038.0 | 1012.6 / 1040.9 |
| watch 1 Local | 0.381 [0.366, 0.441] | 0.060 | 33 | 24.4 / 33.0 | 519.6 / 1018.8 | 2819.9 / 2844.1 |
| watch_1s 1 Local | 0.696 [0.507, 0.752] | 0.110 | 47 | 25.7 / 38.4 | 508.1 / 1020.4 | 976.0 / 1000.8 |
| watch_all 1 Local | 0.444 [0.424, 0.528] | 0.080 | 34 | 28.1 / 59.4 | 528.7 / 1022.9 | 804.2 / 821.3 |
| poll 2 Local | 1.049 [0.990, 1.326] | 0.170 | 73 | 26.6 / 31.6 | 570.0 / 1028.2 | 953.1 / 1056.9 |
| watch 2 Local | 0.442 [0.343, 0.462] | 0.070 | 33 | 28.2 / 38.1 | 520.1 / 1019.0 | 2820.0 / 2844.7 |
| watch_all 2 Local | 0.427 [0.329, 0.472] | 0.060 | 34 | 25.8 / 32.9 | 516.3 / 1016.5 | 790.9 / 802.2 |

`watch_all` closes the gap. Status in another Session took about 0.8 s at p50, against about 1.0 s for polling and 2.8 s for `watch`. Status in the attached Session did not change. One reader used 0.444 CPU seconds against 0.694 for polling, and the tmux server used 0.08 against 0.10. The ranges do not overlap. Two readers used 0.427 against 1.049. So, at the same or better freshness for Status, the slower timer now saves CPU for one reader too.

The timer still covers every change that is not Status and has no control event. tmux sends events for Sessions, Windows and layout, so this fallback mostly covers user options other than Status, such as Unread written by another process. A change of that kind can take up to five seconds to show. The fixture does not measure it. A production module must name each value it shows and say which push covers it.

All 35 trials passed. They checked 350 request revisions, including 35 no-ops and 35 expected failures. Every trial confirmed server cleanup. `make build` and `make test` passed after the run.

## SSH to localhost: smoke result only

`measure.py` now also runs `watch` and `watch_all` over SSH when `ssh localhost` works with strict host key checking. A temporary key, limited to localhost and removed after the run, allowed one smoke trial. `watch_all` over SSH gave requests at about 44 ms p50, against about 30 ms on the Local pipe. Status in another Session showed in about 0.27 s, and the case used 0.519 CPU seconds, including the local SSH client and master. A five-trial run was stopped before it finished, so these values come from one trial. Localhost has almost no network delay, so they show the cost of SSH and the remote process, not of a real network.
