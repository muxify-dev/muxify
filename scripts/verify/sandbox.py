"""One isolated Muxify verify run: its own tmux server, Config, state and app copy.

Every tmux command goes through `Sandbox.tmux`, which always names the
sandbox socket with -S, so no script built on this can reach the user's
default tmux server. The Debug app copy runs the TestDriver
(Sources/Muxify/App/TestDriver.swift), which refuses to start unless its
TMUX_TMPDIR lies inside this sandbox.

Each run gets the root BASE/<suite>/<run-id>/ and an owner file that names the
process that owns it. A new Sandbox first sweeps the roots whose owner is gone,
so a run that was killed with -9 leaves nothing behind for long.
"""

import fcntl
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

REPO = pathlib.Path(__file__).resolve().parents[2]
DEBUG_APP = REPO/'build/Build/Products/Debug/Muxify.app'
AX_WAKE_SOURCE = REPO/'scripts/verify/ax_wake.swift'
# The user allows the accessibility helper in System Settings once. So it lives outside /tmp, which macOS empties,
# and its name comes from its source, so every worktree with the same source uses the same file.
AX_WAKE_DIR = pathlib.Path.home()/'Library/Application Support/MuxifyVerify'
LSREGISTER = ('/System/Library/Frameworks/CoreServices.framework/Frameworks/'
              'LaunchServices.framework/Support/lsregister')
BASE = pathlib.Path('/tmp/muxify-verify')
RUN_ID = re.compile(r'^\d{8}-\d{6}-[0-9a-f]{6}$')
OWNER = 'owner.json'
# A run writes its owner file just after it makes its root. A root without one
# is a run that died in that gap, or what a hand left; it is swept after this
# many seconds, so the sweep cannot race a run that is starting.
OWNERLESS_GRACE = 60


def new_run_id():
    return time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6]


class Sandbox:
    def __init__(self, name):
        sweep()
        self._bind(BASE/name/new_run_id())
        self._create()

    @classmethod
    def _existing(cls, root):
        """A Sandbox for a root that another run made, so the sweep can tear it down."""
        sandbox = cls.__new__(cls)
        sandbox._bind(root)
        return sandbox

    def _bind(self, root):
        self.name = root.parent.name
        self.root = root
        self.app = self.root/'Muxify.app'
        self.binary = self.app/'Contents/MacOS/MuxifyApp'
        self.driver_dir = self.root/'driver'
        self.bundle_id = 'dev.muxify.verify.%s.%s' % (self.name, root.name)
        self.pid = None

        self.app_env = dict(TMUX_TMPDIR=str(self.root/'tmux'), XDG_CONFIG_HOME=str(self.root/'config'),
                            XDG_STATE_HOME=str(self.root/'state'), MUXIFY_TEST_DRIVER=str(self.driver_dir),
                            PATH=os.environ.get('PATH', ''))
        self.env = dict(os.environ, **self.app_env)
        # tmux uses the socket in $TMUX before TMUX_TMPDIR.
        self.env.pop('TMUX', None)
        self.env.pop('TMUX_PANE', None)
        self.tmux_binary = shutil.which('tmux', path=self.env.get('PATH')) or '/opt/homebrew/bin/tmux'
        self.socket = self.root/'tmux'/('tmux-%d' % os.getuid())/'default'
        # tmux ignores an empty TMUX_TMPDIR.
        default = (pathlib.Path(os.environ.get('TMUX_TMPDIR') or '/tmp')/('tmux-%d' % os.getuid())/'default').resolve()
        resolved = self.socket.resolve()
        assert resolved.is_relative_to(self.root.resolve()), 'socket %s is outside %s' % (resolved, self.root)
        assert resolved != default, 'socket %s is the default tmux socket' % resolved

    def _create(self):
        self.root.mkdir(parents=True)
        owner = self.root/(OWNER + '.tmp')
        owner.write_text(json.dumps(dict(pid=os.getpid(), started=started(os.getpid()))))
        owner.replace(self.root/OWNER)
        for relative in ['tmux', 'config/muxify', 'state/muxify', 'logs', 'driver']:
            (self.root/relative).mkdir(parents=True, exist_ok=True)
        # With -S tmux creates only the socket, not its directory; the app finds
        # the same socket through TMUX_TMPDIR.
        self.socket.parent.mkdir(mode=0o700)
        os.chmod(self.root/'tmux', 0o700)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.teardown()

    def teardown(self):
        """Stops every process this sandbox started; keeps root for the logs.

        Killing the app is not enough: a `tmux -C` client that outlives it
        keeps the server alive even after kill-server, and Agents such as
        Codex leave daemons behind. Clients are found through the server;
        everything else carries the root path in its command line or, like a
        server or client the app started, in its environment (TMUX_TMPDIR).
        """
        app = self._app_pid()
        if app is not None:
            self._terminate([app])
        clients = self.tmux_ok('list-clients', '-F', '#{client_pid}').stdout.split()
        self._terminate([int(pid) for pid in clients])
        server_socket = self.tmux_ok('display-message', '-p', '#{socket_path}').stdout.strip()
        if server_socket:
            assert pathlib.Path(server_socket).resolve().is_relative_to(self.root.resolve()), \
                'refusing kill-server: socket %s is outside %s' % (server_socket, self.root)
            self.tmux_ok('kill-server')
        self._terminate(self.processes())
        left = self.processes()
        assert not left, 'sandbox processes still running: %s' % left

    def _remove(self):
        """Tears down a dead run and deletes its root and app registration.

        The owner file goes last, so a sweep that stops halfway leaves a root
        that the next sweep still sees as dead and finishes.
        """
        self.teardown()
        subprocess.run(['defaults', 'delete', self.bundle_id], capture_output=True)
        if self.app.exists():
            subprocess.run([LSREGISTER, '-u', str(self.app)], capture_output=True)
        try:
            entries = [entry for entry in self.root.iterdir() if entry.name != OWNER]
        except FileNotFoundError:
            return
        for entry in entries:
            if entry.is_dir() and not entry.is_symlink():
                shutil.rmtree(entry, ignore_errors=True)
            else:
                entry.unlink(missing_ok=True)
        (self.root/OWNER).unlink(missing_ok=True)
        try:
            self.root.rmdir()
        except FileNotFoundError:
            pass

    def processes(self):
        """PIDs of every process whose command line or environment names this sandbox root."""
        roots = {str(self.root), str(self.root.resolve())}
        # -e appends the environment, which ps shows for the user's own processes.
        listing = subprocess.run(['ps', '-axeww', '-o', 'pid=,ppid=,command='], capture_output=True, text=True).stdout
        parents, commands = {}, {}
        for line in listing.splitlines():
            pid, ppid, command = line.split(None, 2) + [''] * (3 - len(line.split(None, 2)))
            parents[int(pid)], commands[int(pid)] = int(ppid), command
        # The shell or agent that runs this script may name the root too
        # (`| tee root/log`); it is the caller, not a leftover.
        callers, pid = set(), os.getpid()
        while pid > 1 and pid not in callers:
            callers.add(pid)
            pid = parents.get(pid, 1)
        return [pid for pid, command in commands.items()
                if pid not in callers and any(root + '/' in command for root in roots)]

    def _app_pid(self):
        """The recorded app PID, if that process still runs this sandbox's app copy."""
        try:
            pid = int((self.root/'app.pid').read_text())
        except (FileNotFoundError, ValueError):
            return None
        return pid if self._runs_app(pid) else None

    def _runs_app(self, pid):
        command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout.strip()
        # LaunchServices starts the app by its resolved path (/private/tmp/...).
        return any(command.startswith(str(binary)) for binary in (self.binary, self.binary.resolve()))

    def _terminate(self, pids, grace=5):
        for pid in pids:
            _signal(pid, signal.SIGTERM)
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline and any(alive(pid) for pid in pids):
            time.sleep(.1)
        for pid in pids:
            if alive(pid):
                _signal(pid, signal.SIGKILL)

    # tmux

    def _tmux_command(self, args):
        # -f /dev/null keeps the user's tmux config and hooks out of the sandbox server.
        return [self.tmux_binary, '-S', str(self.socket), '-f', '/dev/null', *args]

    def tmux(self, *args, env=None):
        """`env` adds to the sandbox environment, for a command whose client environment matters."""
        return subprocess.check_output(self._tmux_command(args), env=dict(self.env, **(env or {})), text=True).strip()

    def tmux_ok(self, *args, timeout=None):
        """The finished tmux command, whatever its status. Past `timeout` seconds it raises TimeoutExpired."""
        return subprocess.run(self._tmux_command(args), env=self.env, capture_output=True, text=True, timeout=timeout)

    def tmux_client(self, session, terminal):
        """Starts a plain Client on a PTY owned by the check."""
        return subprocess.Popen(self._tmux_command(['attach-session', '-t', session]),
                                env=dict(self.env, TERM='xterm-256color'),
                                stdin=terminal, stdout=terminal, stderr=terminal)

    # app

    def launch(self, args=(), app_source=DEBUG_APP, timeout=30):
        if self.app.exists():
            shutil.rmtree(self.app)
        shutil.copytree(app_source, self.app, symlinks=True)
        plist = str(self.app/'Contents/Info.plist')
        for key, value in [('CFBundleIdentifier', self.bundle_id), ('CFBundleName', 'MuxifyVerify-' + self.name)]:
            subprocess.run(['/usr/libexec/PlistBuddy', '-c', 'Set :%s %s' % (key, value), plist], check=True)
        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(self.app)], check=True, capture_output=True)

        ready = self.driver_dir/'ready'
        ready.unlink(missing_ok=True)
        log = str(self.root/'logs/app.log')
        # Through LaunchServices with -g the app starts behind the user's front app
        # and does not take keyboard focus. open passes only the --env variables;
        # the app gets the rest of its environment from launchd, not from this shell.
        environment = [arg for item in self.app_env.items() for arg in ('--env', '%s=%s' % item)]
        subprocess.run(['open', '-g', '-n', '-F', *environment, '--stdout', log, '--stderr', log,
                        str(self.app), '--args', *args], env=self.env, check=True, capture_output=True)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                word, pid = ready.read_text().split()
                if word == 'ready' and self._runs_app(int(pid)):
                    self.pid = int(pid)
                    (self.root/'app.pid').write_text(pid)
                    self._wake_accessibility(deadline)
                    return self.pid
            except (FileNotFoundError, ValueError):
                pass
            if not self._app_running():
                break
            time.sleep(.1)
        raise AssertionError('app did not report ready (%s); app.log tail:\n%s'
                             % ('running' if self._app_running() else 'exited', self.log_tail()))

    def _wake_accessibility(self, deadline):
        """Asks for the app's windows as an outside accessibility client, then waits until the driver sees the
        SwiftUI elements. Without that request SwiftUI gives the driver an App Window with no elements."""
        helper = AX_WAKE_DIR/('ax-wake-%s' % hashlib.sha256(AX_WAKE_SOURCE.read_bytes()).hexdigest()[:12])
        if not helper.exists():
            # swiftc signs the binary with its file name. Under the same name, the same source and compiler give the
            # same code signature, so a rebuilt helper keeps its Accessibility permission.
            AX_WAKE_DIR.mkdir(parents=True, exist_ok=True)
            building = pathlib.Path(tempfile.mkdtemp(dir=AX_WAKE_DIR))
            try:
                built = subprocess.run(['swiftc', '-O', '-o', str(building/'ax-wake'), str(AX_WAKE_SOURCE)],
                                       capture_output=True, text=True)
                assert built.returncode == 0, 'swiftc could not build %s:\n%s' % (AX_WAKE_SOURCE, built.stderr)
                (building/'ax-wake').replace(helper)
            finally:
                shutil.rmtree(building, ignore_errors=True)
        while True:
            woke = subprocess.run([str(helper), str(self.pid)], capture_output=True, text=True)
            if any(row.get('accessibilityIdentifier') for row in self.driver('dump')['rows']):
                return
            assert time.monotonic() < deadline, ('the driver sees no SwiftUI elements: ax_wake exit %d %s'
                                                 % (woke.returncode, woke.stderr.strip()))
            time.sleep(.2)

    def restart_app(self, args=()):
        """Stops the app and starts it again on the same tmux server, state and defaults, as a relaunch does."""
        app = self._app_pid()
        assert app is not None, 'no app to restart'
        self._terminate([app])
        return self.launch(args)

    def _app_running(self):
        return bool(subprocess.run(['pgrep', '-f', '^(/private)?' + re.escape(str(self.binary))], capture_output=True).stdout)

    def log_tail(self, lines=30):
        try:
            return '\n'.join((self.root/'logs/app.log').read_text(errors='replace').splitlines()[-lines:])
        except FileNotFoundError:
            return '(no app.log)'

    # driver

    def driver(self, command, target='', text=None, timeout=15, **options):
        nonce = str(uuid.uuid4())
        request = dict(nonce=nonce, command=command, target=target, pid=self.pid, text=text or '', **options)
        temporary = self.driver_dir/'command.tmp'
        temporary.write_text(json.dumps(request))
        temporary.replace(self.driver_dir/'command.json')
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                result = json.loads((self.driver_dir/'result.json').read_text())
                if result['nonce'] == nonce:
                    return result
            except (FileNotFoundError, json.JSONDecodeError, KeyError):
                pass
            time.sleep(.01)
        raise AssertionError('test driver timed out: %s %s' % (command, target))

    def act(self, command, target='', text=None, **options):
        """A driver command that must hit its target."""
        result = self.driver(command, target, text, **options)
        assert result['pressed'], (command, target)
        return result

    def rows(self):
        return self.driver('dump')['rows']

    def reveal(self, key):
        """Scrolls the row with the identifier to the top of its list and returns the rows. A lazy list builds only
        the rows it shows, so a row far down is not in a dump until the list has scrolled to it."""
        rows = self.driver('dump', key, reveal=True)['rows']
        assert any(r.get('accessibilityIdentifier') == key for r in rows), 'no row %s to reveal' % key
        return rows

    def ids(self, rs=None):
        return [r.get('accessibilityIdentifier', '') for r in (rs if rs is not None else self.rows())]

    def row(self, key, rs=None):
        return next((r for r in (rs if rs is not None else self.rows()) if r.get('accessibilityIdentifier') == key), {})

    def has(self, key, rs=None):
        return bool(self.row(key, rs))

    def wait_shown(self, target, seconds=10):
        """Waits until the app shows the tmux Window: the App Window's title names its Session, and its Sidebar row,
        in either mode, is selected when the dump has one. tmux moves a client at once; the app follows at its
        next read of tmux."""
        window = session = ''
        last = {}
        def shown():
            nonlocal window, session
            # A Session that a request is still making has no Window yet, and tmux names neither.
            if not window:
                found = self.tmux_ok('display-message', '-p', '-t', target, '#{window_id}|#{session_name}').stdout.strip()
                window, session = found.split('|', 1) if '|' in found else ('', '')
                if not window:
                    return False
            keys = ('topic-window-' + window, 'session-window-' + window)
            rs = self.rows()
            title = next((r.get('accessibilityTitle') for r in rs if r.get('accessibilityRole') == 'AXWindow'), None)
            last.update(title=title, rows={r['accessibilityIdentifier']: r.get('accessibilityValue')
                                           for r in rs if r.get('accessibilityIdentifier') in keys})
            return title == session and all(value == 'selected' for value in last['rows'].values())
        try:
            wait(shown, 'the app does not show ' + target, seconds)
        except AssertionError as error:
            clients = self.tmux_ok('list-clients', '-F', '#{client_control_mode} #{session_name} #{window_id}').stdout
            raise AssertionError('%s (%s of %s): it shows %s; tmux clients: %s'
                                 % (error, window or 'no Window', session or 'no Session', last, clients.split('\n'))) from None

    def wait_rows(self, predicate, message, seconds=20):
        """The first UI dump for which predicate(rows) holds."""
        return wait(lambda: (lambda rs: rs if predicate(rs) else None)(self.rows()), message, seconds)


def frame(row):
    """(bottom, top) of a dump row's accessibilityFrame, in screen points: a larger value is higher on screen."""
    x, y, width, height = map(float, re.findall(r'-?[\d.]+', row['accessibilityFrame']))
    return y, y + height


def remove_topic(path):
    """Deletes a Topic record while holding the app's record lock (MuxifyPaths.recordLock). An app write reads a
    record and renames its new version in under that lock, so a delete between the two would bring the record back."""
    with open(path.parent.parent/'topics.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path.unlink(missing_ok=True)


def sweep():
    """Removes every run root under BASE whose owner is gone. Live runs are left alone.

    Safe to run from several processes at once and after a sweep that stopped
    halfway: every step skips what is already gone.
    """
    for root in sorted(BASE.glob('*/*')):
        if not RUN_ID.match(root.name) or not root.is_dir() or _owned(root):
            continue
        try:
            Sandbox._existing(root)._remove()
        except AssertionError as error:
            print('muxify verify: kept dead run %s: %s' % (root, error), file=sys.stderr)


def _owned(root):
    """Whether the process that made root still runs, or root is too young to judge."""
    try:
        owner = json.loads((root/OWNER).read_text())
        return started(owner['pid']) == owner['started']
    except (FileNotFoundError, ValueError, KeyError):
        pass
    try:
        return time.time() - root.stat().st_mtime < OWNERLESS_GRACE
    except FileNotFoundError:
        return True


def started(pid):
    """The start time of pid as ps shows it, or None when pid is gone.

    With the PID it names one process: a reused PID has a later start time.
    The fixed locale and time zone make the text the same in every shell.
    """
    environment = dict(os.environ, LC_ALL='C', TZ='UTC')
    return subprocess.run(['ps', '-p', str(pid), '-o', 'lstart='], capture_output=True, text=True,
                          env=environment).stdout.strip() or None


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def _signal(pid, number):
    try:
        os.kill(pid, number)
    except ProcessLookupError:
        pass


def wait(predicate, message, seconds=20, step=.1):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            last = predicate()
            if last:
                return last
        except (subprocess.CalledProcessError, KeyError, FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(step)
    raise AssertionError(message)
