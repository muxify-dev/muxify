"""The compare run: shows each scene in the SwiftUI Sessions list and in the AppKit one, fails when the two differ in
what a check can measure, and leaves a report of pictures for the user to judge
(docs/adr/0074-an-area-leaves-swiftui-for-appkit-only-where-swiftui-caused-bugs.md).

    python3 -m scripts.verify.compare [--self] [scene ...]

Without a scene it runs every scene of compare_scenes.py, one after the other, each in its own Sandbox. A scene makes
its fixture once. Then, for each version, it starts the app with that version, shows each of its shots, and takes a
picture of the App Window and a dump for it. `make compare` builds the Debug app first.

**The gate** (compare_gate.py) matches the rows inside the Sessions list between the two versions. The run fails when
a scene's gate fails, or when a scene cannot show a shot or measure it. It names each row that failed, with the
values of both versions.

**The report** is REPORT/index.html: for each shot the two pictures side by side, a picture of their difference, the
share of pixels that differ, the gate's result, and the scene's section of NOTES. Nothing deletes it. A run of some
scenes replaces their part of the report and keeps the rest. The share of pixels does not fail the run.

**--self** shows each scene twice in the SwiftUI list. Then every difference is a fault of the run itself, so one
pixel that differs fails the run too. Its report is REPORT/self/index.html, so it leaves the report of the two
versions alone.

The run takes no focus: it starts the app only through `Sandbox.launch`, and it uses only the driver commands of
scripts/verify/README.md, "Do not take focus".
"""

import json
import shutil
import subprocess
import sys
import time
from typing import NamedTuple

from scripts.verify import compare_report, gate
from scripts.verify.compare_gate import judge, list_rows, rect
from scripts.verify.compare_scenes import SCENES
from scripts.verify.run import prepare_mac
from scripts.verify.run_suite import write_json
from scripts.verify.sandbox import REPO, SESSIONS_LIST_DEFAULT, SESSIONS_LIST_VERSIONS, Sandbox, alive, swift_helper

REPORT = gate.EVIDENCE/'compare'
NOTES = REPO/'scripts/verify/compare-notes.md'
PICTURE_DIFF_SOURCE = REPO/'scripts/verify/picture_diff.swift'
# What every scene starts the app with: the Sidebar with its Sessions list, and no Session card open from an earlier
# launch, so each launch opens only the cards that the scene opens. A launch argument wins over the stored default.
ARGS = ['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Sessions', '-expandedSessions', '()']
# A shot is at rest when this many pictures and dumps in a row are the same, REST_STEP seconds apart.
REST_SAMPLES = 3
REST_STEP = .25
REST_TIMEOUT = 15
# The room around the Sidebar in the part of a picture that the report shows, in points.
CROP_MARGIN = 8
# What stops one shot or one scene, and not the run: a wait that ran out, a driver command that missed, a tmux command
# that failed.
FAILURES = (AssertionError, subprocess.SubprocessError, OSError, ValueError)


class Side(NamedTuple):
    """One of the two showings of a scene: `label` names its files and its column in the report, and `version` is the
    Sessions list it asks for."""
    label: str
    version: str


def sides(self_run):
    return [Side('swiftui-1', 'swiftui'), Side('swiftui-2', 'swiftui')] if self_run else [
        Side('swiftui', 'swiftui'), Side('appkit', 'appkit')]


class View:
    """One showing of a scene: the app with one version of the Sessions list, in the scene's Sandbox `s`. A scene
    drives it to a shot, and the run measures the shot."""

    def __init__(self, sandbox, side, out):
        self.s = sandbox
        self.side = side
        self.out = out

    def launch(self, config=None):
        """Starts the app with this showing's version of the Sessions list, or starts it again when it runs. With
        `config`, it writes that Config first, so the app reads it as it starts."""
        if config is not None:
            (self.s.root/'config/muxify/config.yaml').write_text(config)
        args = [*ARGS, '-' + SESSIONS_LIST_DEFAULT, SESSIONS_LIST_VERSIONS[self.side.version]]
        if self.s.pid is not None and alive(self.s.pid):
            self.s.restart_app(args)
        else:
            self.s.launch(args)

    def wait(self, predicate, message, seconds=10):
        """The first dump for which predicate(rows) holds. A shot that the list cannot show fails here."""
        return self.s.wait_rows(predicate, lambda: '%s, in the %s list' % (message() if callable(message) else message,
                                                                         self.side.version), seconds)

    def go(self, window):
        """Moves the Location to the Window, as `muxify window open` does, and waits until the app shows it. The card
        of the Window's Session opens, and with `sidebar.session_cards: one` every other card closes."""
        self.s.show(window)

    def value(self, key, rows):
        return self.s.row(key, rows).get('accessibilityValue') or ''

    def close_card(self, session):
        """Closes the card of the Location's Session, which the move to the Session opened."""
        key = 'session-' + session
        self.wait(lambda rs: 'expanded' in self.value(key, rs), 'the card %s of the Location is not open' % key)
        self.s.act('press', key)
        self.wait(lambda rs: 'collapsed' in self.value(key, rs), 'the card %s did not close' % key)

    def measure(self, shot):
        """The picture and the dump of a shot: (path of the picture, rows). It first asks the driver which Sessions
        list shows, and fails when that is not the version this showing asked for. Then it waits until nothing moves."""
        shown = self.s.sessions_list()
        assert shown == self.side.version, (
            'the App Window shows the %s Sessions list, and the scene asked for the %s list' % (shown, self.side.version))
        picture = self.out/('%s-%s.png' % (shot, self.side.label))
        rows = self.rest(picture)
        write_json(picture.with_suffix('.json'), rows)
        return picture, rows

    def rest(self, picture=None):
        """Waits until nothing moves: takes a picture and a dump again and again, until REST_SAMPLES in a row are the
        same. The last picture is at `picture`, for a caller that keeps it; returns the last dump. A scene calls it
        before a step that starts from where the list stands, such as a swipe or a hover: a card that still opens
        gives the same rows as a card at rest."""
        picture = picture or self.s.root/'rest.png'
        deadline = time.monotonic() + REST_TIMEOUT
        last, same = None, 1
        while True:
            self.s.act('snapshot', '', str(picture))
            now = (picture.read_bytes(), self.s.rows())
            same = same + 1 if now == last else 1
            if same >= REST_SAMPLES:
                return now[1]
            assert time.monotonic() < deadline, (
                'the App Window did not come to rest in %d seconds: its picture or its rows still change' % REST_TIMEOUT)
            last = now
            time.sleep(REST_STEP)


def picture_diff(first, second, difference):
    """Writes the picture of the difference of two pictures, and returns dict(width, height, pixels, differ, box):
    how many pixels differ, and the box around them as [left, top, right, bottom] in pixels."""
    helper = swift_helper(PICTURE_DIFF_SOURCE, 'picture-diff')
    done = subprocess.run([str(helper), str(first), str(second), str(difference)], capture_output=True, text=True)
    assert done.returncode == 0, 'picture-diff failed: %s' % done.stderr.strip()
    return json.loads(done.stdout)


def crop(dumps):
    """The part of the App Window that the report shows of a shot: the Sidebar, and a hover label that reaches out
    of it, in every dump of `dumps`. Returns (crop, window): the crop as [x, y, width, height] in points from the top
    left corner of the App Window, and the App Window's [width, height]. None when no dump has a Sidebar."""
    window, shown = None, []
    for rows in dumps:
        panel = next((index for index, row in enumerate(rows) if row.get('accessibilityIdentifier') == 'sidebar-panel'), None)
        # The App Window is the row without a parent that the Sidebar follows.
        frame = next((rect(row) for row in reversed(rows[:panel or 0]) if row.get('depth') == '0'), None)
        if not frame:
            continue
        window = window or [frame[2], frame[3]]
        for row in rows:
            if row.get('accessibilityIdentifier') in ('sidebar-panel', 'hover-label') and rect(row):
                x, y, width, height = rect(row)
                left, top = x - frame[0], frame[1] + frame[3] - (y + height)
                shown.append((left, top, left + width, top + height))
    if not shown:
        return None, None
    left, top = (max(0, min(edges[index] for edges in shown) - CROP_MARGIN) for index in (0, 1))
    right, bottom = (min(window[index - 2], max(edges[index] for edges in shown) + CROP_MARGIN) for index in (2, 3))
    return [left, top, right - left, bottom - top], window


def run_scene(scene, pair, out, self_run):
    """Runs one scene and returns its result, which it also writes to out/result.json. `failed` lists why the scene
    fails; it is empty when the scene passes."""
    began = time.monotonic()
    result = dict(scene=scene.name, shows=scene.shows, self_run=self_run, sides=[side._asdict() for side in pair],
                  time=time.strftime(gate.TIME), head=gate.git('rev-parse', 'HEAD'), shots=[], failed=[])
    taken = {}
    sandbox = Sandbox('compare-' + scene.name)
    # teardown copies the app logs here, beside the pictures.
    sandbox.evidence = str(out)
    try:
        scene.fixture(sandbox)
        # The status line has a clock, and the picture of the App Window has the Terminal.
        sandbox.tmux_ok('set-option', '-g', 'status', 'off')
        for side in pair:
            view = View(sandbox, side, out)
            for shot, arrange in scene.shots():
                record = taken.setdefault(shot, {})[side.label] = dict(picture=None, rows=None, error=None)
                try:
                    arrange(view)
                except FAILURES as error:
                    record['error'] = 'the scene could not show this shot: %s' % error
                # A shot that the list could not show is still measured, so the report has its picture and its rows.
                try:
                    record['picture'], record['rows'] = view.measure(shot)
                except FAILURES as error:
                    record['error'] = '; '.join(filter(None, [record['error'], 'no measure: %s' % error]))
    except FAILURES as error:
        result['failed'].append('the scene could not make its fixture: %s' % error)
    finally:
        sandbox.teardown()

    first, second = pair
    for shot, _ in scene.shots():
        records = taken.get(shot, {})
        one, other = records.get(first.label), records.get(second.label)
        entry = dict(name=shot, pictures={}, errors={}, pixels=None, difference=None, gate=None, crop=None, window=None)
        for side, record in ((first, one), (second, other)):
            if record and record['picture']:
                entry['pictures'][side.label] = record['picture'].name
            if record is None or record['error']:
                entry['errors'][side.label] = record['error'] if record else 'the scene did not come to this shot'
                result['failed'].append('%s, %s: %s' % (shot, side.label, entry['errors'][side.label]))
        if one and other and one['picture'] and other['picture']:
            difference = out/('%s-difference.png' % shot)
            entry['pixels'] = picture_diff(one['picture'], other['picture'], difference)
            entry['difference'] = difference.name
            entry['gate'] = judge(list_rows(one['rows']), list_rows(other['rows']))
            entry['crop'], entry['window'] = crop([one['rows'], other['rows']])
            if entry['gate']['failed']:
                result['failed'].append('%s: the gate failed for %d rows' % (shot, len({row['row'] for row in entry['gate']['failed']})))
            if self_run and entry['pixels']['differ']:
                result['failed'].append('%s: %d pixels differ between two showings of the SwiftUI list, %s'
                                        % (shot, entry['pixels']['differ'], compare_report.where(entry)))
        result['shots'].append(entry)
    result['seconds'] = round(time.monotonic() - began, 1)
    write_json(out/'result.json', result)
    return result


def explain(result, first, second):
    """The lines that say why a scene failed: its problems, and each row that failed its gate with both values."""
    lines = ['  - ' + problem for problem in result['failed']]
    for shot in result['shots']:
        for row in (shot['gate'] or {}).get('failed', []):
            lines.append('      %s: %s: %s  |  %s: %r  |  %s: %r' % (shot['name'], row['row'], row['what'], first.label,
                                                                      row['first'], second.label, row['second']))
    return lines


def main(argv):
    self_run = '--self' in argv
    names = [arg for arg in argv if arg != '--self']
    scenes = {scene.name: scene for scene in SCENES}
    unknown = [name for name in names if name not in scenes]
    if unknown:
        sys.exit('no scene %s; the scenes are %s' % (', '.join(unknown), ', '.join(scenes)))
    chosen = [scene for scene in SCENES if not names or scene.name in names]
    prepare_mac()

    root = REPORT/'self' if self_run else REPORT
    pair = sides(self_run)
    print('compare: %d scenes, the %s list and the %s list, report in %s' % (
        len(chosen), pair[0].version, pair[1].version, root/'index.html'), flush=True)
    clock = time.monotonic()
    failed = []
    for scene in chosen:
        out = root/scene.name
        shutil.rmtree(out, ignore_errors=True)
        out.mkdir(parents=True)
        result = run_scene(scene, pair, out, self_run)
        shares = ', '.join('%s %s' % (shot['name'], compare_report.share(shot['pixels'])) for shot in result['shots']
                           if shot['pixels'])
        print('%-7s %-16s %5.1f s  pixels that differ: %s' % ('FAILED' if result['failed'] else 'ok', scene.name,
                                                             result['seconds'], shares or 'no pictures'), flush=True)
        if result['failed']:
            failed.append(scene.name)
            print('\n'.join(explain(result, *pair)), flush=True)
        # After each scene, so a run that stops halfway leaves a report of what it did.
        (root/'index.html').write_text(compare_report.render(root, [scene.name for scene in SCENES], NOTES.read_text()))
    print('%d scenes in %.0f s: %s' % (len(chosen), time.monotonic() - clock,
                                       '%d failed: %s' % (len(failed), ', '.join(failed)) if failed else 'all passed'))
    print('report: %s' % (root/'index.html'))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
