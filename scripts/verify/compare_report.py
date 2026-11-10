"""The HTML report of the compare run, from the result.json that compare.py writes for each scene.

The page is index.html in the folder of the run's results, build/verify/compare/ or build/verify/compare/self/, and
names the pictures by relative paths, so it works opened from disk. It shows each scene that has a result, also one of
an earlier run, in the order of the scenes. Under a scene's pictures it shows the scene's section of
scripts/verify/compare-notes.md.
"""

import json
import re

from scripts.verify.compare_gate import describe
from scripts.verify.report import STYLE, esc, tag

# The notes' first section, before the sections of the scenes.
COST = 'Cost of the pilot'
PAGE_STYLE = STYLE + '''
body { max-width: 1700px; } h3 { font-size: 14px; margin: 18px 0 6px; }
.pictures { display: flex; flex-wrap: wrap; gap: 14px; align-items: flex-start; }
figure { margin: 0; } figcaption { color: var(--muted); font-size: 12px; margin-bottom: 4px; }
.crop { display: block; position: relative; overflow: hidden; border: 1px solid var(--line); border-radius: 4px; }
.crop img { position: absolute; max-width: none; } img.whole { max-width: 480px; border: 1px solid var(--line); }
.notes { border-left: 3px solid var(--line); padding: 2px 12px; margin: 12px 0; }
.notes p, .notes ul { margin: 6px 0; }
'''


def share(pixels):
    """The share of pixels that differ, as the report and the run's output show it."""
    if not pixels['differ']:
        return '0 %'
    percent = 100 * pixels['differ'] / pixels['pixels']
    return ('%.2f %%' % percent) if percent >= .01 else 'under 0.01 %'


def where(shot):
    """Where the pixels of a shot differ: the box around them, as the gate shows a frame, in points from the top left
    corner of the App Window. A shot that does not know the size of the App Window gives the box in pixels of the
    picture."""
    scale = shot['pixels']['width'] / shot['window'][0] if shot['window'] else 1
    return 'inside %s%s' % (describe([edge / scale for edge in shot['pixels']['box']]),
                            '' if shot['window'] else ', in pixels of the picture')


def sections(notes):
    """The sections of compare-notes.md by their `## ` heading, each as its text without the heading."""
    found, name = {}, None
    for line in notes.splitlines():
        if line.startswith('## '):
            name = line[3:].strip()
            found[name] = []
        elif name is not None:
            found[name].append(line)
    return {name: '\n'.join(lines).strip() for name, lines in found.items()}


def prose(text):
    """Notes as HTML: paragraphs, lists of `- ` lines, and `code`."""
    def inline(line):
        return re.sub(r'`([^`]+)`', r'<code>\1</code>', esc(line))
    blocks = []
    for block in re.split(r'\n\s*\n', text.strip()):
        lines = [line.strip() for line in block.splitlines() if line.strip()]
        if lines and all(line.startswith('- ') for line in lines):
            blocks.append('<ul>%s</ul>' % ''.join('<li>%s</li>' % inline(line[2:]) for line in lines))
        elif lines:
            blocks.append('<p>%s</p>' % inline(' '.join(lines)))
    return ''.join(blocks)


def picture(scene, shot, file, caption):
    """One picture of a shot, cut to the Sidebar when the shot knows where it is, as a link to the whole picture."""
    if not file:
        return '<figure><figcaption>%s</figcaption><p class="muted">no picture</p></figure>' % esc(caption)
    path = esc('%s/%s' % (scene, file))
    if shot['crop']:
        x, y, width, height = shot['crop']
        image = ('<a class="crop" href="%s" style="width:%gpx;height:%gpx"><img src="%s" alt="%s" '
                 'style="left:%gpx;top:%gpx;width:%gpx;height:%gpx"></a>'
                 % (path, width, height, path, esc(caption), -x, -y, shot['window'][0], shot['window'][1]))
    else:
        image = '<a href="%s"><img class="whole" src="%s" alt="%s"></a>' % (path, path, esc(caption))
    return '<figure><figcaption>%s</figcaption>%s</figure>' % (esc(caption), image)


def gate_box(shot, first, second):
    gate = shot['gate']
    if gate is None:
        return '<div class="box failed"><b>Gate: not judged.</b> A picture is missing.</div>'
    rows = '%d rows in the %s list, %d in the %s list' % (gate['rows'][0], first, gate['rows'][1], second)
    order = ''
    if gate['order']:
        order = ('<details><summary>The rows stand in another order. This does not fail the gate.</summary>'
                 '<table><tr><th>%s</th><th>%s</th></tr><tr><td>%s</td><td>%s</td></tr></table></details>'
                 % (esc(first), esc(second), '<br>'.join(map(esc, gate['order']['first'])),
                    '<br>'.join(map(esc, gate['order']['second']))))
    if not gate['failed']:
        return '<div class="box pass"><b>Gate: passed.</b> %s.%s</div>' % (esc(rows), order)
    def value(text):
        return '<span class="muted">none</span>' if text is None else '<code>%s</code>' % esc(text)
    failed = ''.join('<tr><td><code>%s</code></td><td>%s%s</td><td>%s</td><td>%s</td></tr>' % (
        esc(row['row']), esc(row['what']), esc(' (%s)' % ', '.join(row['edges'])) if row.get('edges') else '',
        value(row['first']), value(row['second'])) for row in gate['failed'])
    return ('<div class="box failed"><b>Gate: FAILED</b> for %d rows. %s.'
            '<table><tr><th>Row</th><th>Differs in</th><th>%s</th><th>%s</th></tr>%s</table>%s</div>'
            % (len({row['row'] for row in gate['failed']}), esc(rows), esc(first), esc(second), failed, order))


def scene_section(result, notes):
    first, second = (side['label'] for side in result['sides'])
    name = result['scene']
    shots = []
    for shot in result['shots']:
        errors = ''.join('<div class="box failed"><b>%s:</b> %s</div>' % (esc(label), esc(error))
                         for label, error in shot['errors'].items())
        pixels = shot['pixels']
        differ = ('<p><b>Pixels that differ:</b> %s <span class="muted">(%d of %d%s)</span></p>'
                  % (esc(share(pixels)), pixels['differ'], pixels['pixels'],
                     esc(', ' + where(shot)) if pixels['differ'] else '')) if pixels else ''
        shots.append('<h3>%s</h3><div class="pictures">%s%s%s</div>%s%s%s' % (
            esc(shot['name']), picture(name, shot, shot['pictures'].get(first), first),
            picture(name, shot, shot['pictures'].get(second), second),
            picture(name, shot, shot['difference'], 'difference'), differ, errors, gate_box(shot, first, second)))
    fixture = ''.join('<div class="box failed">%s</div>' % esc(problem) for problem in result['failed']
                      if problem.startswith('the scene could not make'))
    return ('<h2 id="%s">%s %s</h2><p>%s <span class="muted">Run %s on <code>%s</code>, %.1f s.</span></p>%s%s'
            '<div class="notes"><b>Notes</b>%s</div>' % (
                esc(name), esc(name), tag('failed' if result['failed'] else 'pass'), esc(result['shows']),
                esc(result['time']), esc(result['head'][:9]), result['seconds'], fixture, ''.join(shots),
                prose(notes) or '<p class="muted">No notes.</p>'))


def render(root, names, notes):
    """The page for the results in the folder `root`, with the scenes `names` in their order."""
    noted = sections(notes)
    results = []
    for name in names:
        try:
            results.append(json.loads((root/name/'result.json').read_text()))
        except (FileNotFoundError, ValueError):
            pass
    self_run = any(result['self_run'] for result in results)
    missing = [name for name in names if name not in [result['scene'] for result in results]]
    summary = ''.join('<tr><td><a href="#%s">%s</a></td><td>%s</td><td>%s</td><td>%s</td></tr>' % (
        esc(result['scene']), esc(result['scene']), tag('failed' if result['failed'] else 'pass'),
        esc(', '.join('%s %s' % (shot['name'], share(shot['pixels'])) for shot in result['shots'] if shot['pixels'])),
        esc(result['time'])) for result in results)
    cost = prose(noted.get(COST, ''))
    return '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
<title>%(title)s</title><style>%(style)s</style></head><body>
<h1>%(title)s</h1>
<p class="muted">%(intro)s Each picture shows the Sidebar; a click opens the picture of the whole App Window.
A picture is drawn from the App Window's layers, so it does not show a material that the window server blends.</p>
%(missing)s
<table><tr><th>Scene</th><th>Result</th><th>Pixels that differ</th><th>Run</th></tr>%(summary)s</table>
%(cost)s
%(scenes)s
</body></html>
''' % dict(title='Compare run: the SwiftUI Sessions list twice' if self_run else 'Compare run: the SwiftUI and the AppKit Sessions list',
           style=PAGE_STYLE,
           intro=('Each scene shows twice in the SwiftUI Sessions list, so every difference is a fault of the run.'
                  if self_run else
                  'A scene fails when a row inside the Sessions list has no match in the other version, differs in '
                  'label, title, value or help, or stands more than half a point away. The pixels are for the eye.'),
           missing='<p class="muted">No result yet: %s.</p>' % esc(', '.join(missing)) if missing else '',
           summary=summary, cost='<h2>%s</h2>%s' % (esc(COST), cost) if cost else '',
           scenes=''.join(scene_section(result, noted.get(result['scene'], '')) for result in results))
