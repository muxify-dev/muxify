"""The HTML report of one verify run, from the summary that run.py also writes to run.json.

The page lives in build/verify/reports/ and links the evidence in build/verify/runs/ by relative
paths, so it works opened from disk, with no server and no network. It follows the light or dark
setting of the system.
"""

import html

STYLE = '''
:root { color-scheme: light dark; --bg: #fff; --fg: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --panel: #f5f5f7;
        --pass: #1a7f37; --fail: #cf222e; --flaky: #9a6700; --other: #57606a; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #161618; --fg: #f5f5f7; --muted: #a1a1a6; --line: #3a3a3c; --panel: #232326;
          --pass: #3fb950; --fail: #ff7b72; --flaky: #d29922; --other: #8b949e; }
}
body { background: var(--bg); color: var(--fg); font: 14px/1.45 -apple-system, BlinkMacSystemFont, sans-serif;
       margin: 0 auto; padding: 24px; max-width: 1200px; }
h1 { font-size: 22px; margin: 0 0 4px; } h2 { font-size: 17px; margin: 28px 0 8px; }
.muted { color: var(--muted); } code, pre { font: 12px/1.4 ui-monospace, Menlo, monospace; }
pre { background: var(--panel); padding: 8px 10px; border-radius: 6px; white-space: pre-wrap; overflow-wrap: anywhere; }
table { border-collapse: collapse; width: 100%; } td, th { text-align: left; vertical-align: top; padding: 5px 8px;
        border-bottom: 1px solid var(--line); } th { font-weight: 600; }
td { overflow-wrap: anywhere; } a { color: inherit; }
.box { border: 1px solid var(--line); border-left-width: 5px; border-radius: 6px; padding: 10px 14px; margin: 12px 0; }
.pass { color: var(--pass); border-color: var(--pass); } .failed, .fail, .error, .timeout { color: var(--fail);
        border-color: var(--fail); } .FLAKY { color: var(--flaky); border-color: var(--flaky); }
.skip, .not-run { color: var(--other); } .box > * { color: var(--fg); } .box > b:first-child { color: inherit; }
.tag { font-weight: 600; font-size: 12px; } details summary { cursor: pointer; }
'''
# The worst verdict of a check over all rounds decides where its row sorts.
ORDER = {'failed': 0, 'FLAKY': 1, 'skip': 2, 'pass': 3}


def esc(text):
    return html.escape(str(text))


def link(path, text=None):
    """path is relative to build/verify, and this page is in build/verify/reports/."""
    return '<a href="../%s">%s</a>' % (esc(path), esc(text or path.rsplit('/', 1)[-1]))


def tag(status):
    return '<span class="tag %s">%s</span>' % (esc(status), esc(status))


def gate_box(summary):
    gate = summary['gate']
    note = '' if gate['counted'] else (' <span class="muted">This run was a subset, so it cannot pass the gate, and '
                                       'its exit status ignores the gate.</span>')
    if not gate['problems']:
        return '<div class="box pass"><b>Gate: passed.</b>%s</div>' % note
    return '<div class="box failed"><b>Gate: FAILED.</b>%s<ul>%s</ul></div>' % (
        note, ''.join('<li>%s</li>' % esc(problem) for problem in gate['problems']))


def file_label(path):
    """output.log, rerun output.log, or app.log 0f799e: the last part of the Sandbox run id tells two app logs apart."""
    parts = path.split('/')
    label = '%s %s' % (parts[-1], parts[-2][-6:]) if 'app-logs' in parts else parts[-1]
    return ('rerun ' if any(part.endswith('.rerun') for part in parts) else '') + label


def suite_rows(summary):
    rows = []
    for one in summary['rounds']:
        for suite in one['suites']:
            links = [link(path, file_label(path)) for path in suite['files']]
            rows.append('<tr><td>%s</td><td>%s</td><td>%s%s</td><td>%.1f s</td><td>%d s</td><td>%s</td></tr>' % (
                one['number'], esc(suite['suite']), tag(suite['status']),
                ' then rerun %s' % tag(suite['rerun']['status']) if suite['rerun'] else '',
                suite['seconds'], suite['timeout'], ' · '.join(links)))
    return ''.join(rows)


def error_block(record, label):
    if not record.get('error') or record['status'] in ('pass', 'skip'):
        return ''
    return '<details><summary>%s %s</summary><pre>%s</pre></details>' % (esc(label), tag(record['status']),
                                                                          esc(record['error']))


def check_rows(summary):
    """One row per check, one cell per round: its verdict, its seconds, and the errors of a check that failed once."""
    rows = {}
    for one in summary['rounds']:
        for suite in one['suites']:
            for check in suite['checks']:
                rows.setdefault(check['check'], (suite['suite'], {}))[1][one['number']] = check
    out = []
    for id, (suite, by_round) in sorted(rows.items(), key=lambda item: (
            min(ORDER.get(check['verdict'], 0) for check in item[1][1].values()), item[0])):
        cells = []
        for number in range(1, summary['repeat'] + 1):
            check = by_round.get(number)
            if not check:
                cells.append('<td></td>')
                continue
            errors = error_block(check['first'], 'parallel pass') + ''.join(
                error_block(record, 'alone' + ('' if record['check'] == id else ': ' + record['check']))
                for record in check['rerun'])
            cells.append('<td>%s <span class="muted">%.1f s</span>%s</td>' % (
                tag(check['verdict']), check['first']['seconds'], errors))
        out.append('<tr><td>%s</td><td><code>%s</code></td>%s</tr>' % (
            esc(suite), esc(id.rsplit('.', 1)[-1]), ''.join(cells)))
    return ''.join(out)


def render(summary):
    tree = summary['tree']
    verdicts = [check['verdict'] for one in summary['rounds'] for suite in one['suites'] for check in suite['checks']]
    totals = ', '.join('%d %s' % (verdicts.count(status), status) for status in ORDER if status in verdicts)
    seeds = [str(one['seed']) for one in summary['rounds'] if one['seed'] is not None]
    rounds = ''.join('<th>%s</th>' % ('verdict' if summary['repeat'] == 1 else 'round %d' % number)
                     for number in range(1, summary['repeat'] + 1))
    problems = ''.join('<div class="box %s"><b>%s</b> <code>%s</code></div>' % (status, status, esc(check))
                       for status, checks in (('failed', summary['failed']), ('FLAKY', summary['flaky']))
                       for check in checks)
    return '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
<title>verify %(run)s</title><style>%(style)s</style></head><body>
<h1>Verify run %(run)s</h1>
<p class="muted">Started %(started)s, %(seconds)d s. HEAD <code>%(head)s</code>, files <code>%(files)s</code>.
%(selection)s, %(jobs)d jobs%(repeat)s%(seeds)s. <a href="../runs/%(run)s/">Evidence folder</a>, <a href="../runs/%(run)s/run.json">run.json</a>.</p>
%(gate)s
<p><b>Checks:</b> %(totals)s.</p>
%(problems)s
<h2>Checks</h2>
<p class="muted">A check that fails in the parallel pass runs again alone. When it passes then, it is FLAKY.</p>
<table><tr><th>Suite</th><th>Check</th>%(rounds)s</tr>%(checks)s</table>
<h2>Suites</h2>
<table><tr><th>Round</th><th>Suite</th><th>Status</th><th>Time</th><th>Timeout</th><th>Evidence</th></tr>%(suites)s</table>
</body></html>
''' % dict(run=esc(summary['run']), style=STYLE, started=esc(summary['started']), seconds=summary['seconds'],
           head=esc(tree['head'][:9]), files=esc(tree.get('files', '')[:12]),
           selection='Full run of %d suites' % len(summary['rounds'][0]['suites']) if summary['full']
           else 'Subset of %d suites' % len(summary['rounds'][0]['suites']),
           jobs=summary['jobs'], repeat=', %d rounds' % summary['repeat'] if summary['repeat'] > 1 else '',
           seeds=', shuffle seeds %s' % ', '.join(seeds) if seeds else '', gate=gate_box(summary), totals=totals,
           problems=problems, rounds=rounds,
           checks=check_rows(summary), suites=suite_rows(summary))
