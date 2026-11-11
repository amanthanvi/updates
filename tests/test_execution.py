#!/usr/bin/env python3
"""Subprocess regressions using isolated, marker-controlled command stubs."""
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
STUB = r'''
import json, os, pathlib, subprocess, sys, time
root = pathlib.Path(os.environ['PROBE_DIR'])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'calls').open('a') as stream:
    stream.write(json.dumps([name] + args) + '\n')
mode = os.environ['PROBE_MODE']
def pause():
    (root / 'child.pid').write_text(str(os.getpid()))
    print('stub diagnostic before completion', file=sys.stderr, flush=True)
    (root / 'ready').touch()
    while not (root / 'release').exists():
        time.sleep(.02)
if name == 'sleep':
    with (root / 'timer.pids').open('a') as stream:
        stream.write(str(os.getpid()) + '\n')
    os.execv('/bin/sleep', ['/bin/sleep'] + args)
elif name == 'uname':
    print('Darwin')
elif name == 'brew':
    if args == ['update']:
        (root / 'brew-no-ask').write_text(os.environ.get('HOMEBREW_NO_ASK', '<unset>'))
        if mode == 'brew130':
            sys.exit(130)
        if mode == 'pty':
            print('Type confirmation:', flush=True)
            (root / 'ready').touch()
            if input() != 'confirmed':
                sys.exit(7)
            (root / 'answered').touch()
        else:
            pause()
elif name == 'ncu':
    if args[:1] == ['--help']:
        print('--enginesNode')
    else:
        if mode == 'ncu':
            pause()
        print('{"execution-probe":"2.0.0"}')
elif name == 'npm':
    if '--dry-run' in args:
        if mode == 'preflight':
            pause()
    else:
        if mode == 'npm-descendant':
            child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
            (root / 'descendant.pid').write_text(str(child.pid))
            print('inherited descriptor diagnostic', file=sys.stderr, flush=True)
            (root / 'ready').touch()
        else:
            pause()
        sys.exit(19 if mode == 'npm-fail' else 0)
elif name in ('python', 'python3'):
    if args[:1] == ['-c']:
        if 'EXTERNALLY-MANAGED' in args[1]:
            print('1' if mode == 'pip-help' else '0')
        else:
            os.execv(os.environ['REAL_PYTHON'], [os.environ['REAL_PYTHON']] + args)
    elif args[:2] == ['-m', 'pip']:
        if '--version' in args:
            if mode == 'pip-version':
                pause()
            print('pip 25.0')
        elif 'list' in args:
            if mode == 'pip-scheduler':
                print(json.dumps([{'name': name} for name in ('first', 'second', 'third')]))
            else:
                print('[{"name":"execution-probe"}]')
        elif 'install' in args:
            if mode == 'pip-scheduler' and args[-1] != 'first':
                (root / (args[-1] + '.started')).touch()
                print('scheduler ' + args[-1] + ' complete', flush=True)
            else:
                pause()
        else:
            sys.exit(3)
    else:
        sys.exit(4)
else:
    sys.exit(5)
'''


class ExecutionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='updates-execution-')
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.command_tmp = self.root / 'tmp'
        self.command_tmp.mkdir()
        install_bin = self.root / 'home' / 'bin'
        install_bin.mkdir(parents=True)
        self.script = install_bin / 'updates'
        self.script.write_bytes((ROOT / 'updates').read_bytes())
        self.script.chmod(0o755)
        self.processes = []
        self.handles = []
        self.env = {key: value for key, value in os.environ.items()
                    if key not in ('BASH_ENV', 'ENV', 'ZSH', 'ZSH_CUSTOM', 'NVM_DIR',
                                   'FNM_DIR', 'FNM_MULTISHELL_PATH', 'PYTHONPATH',
                                   'PYTHONHOME') and not key.startswith('UPDATES_')}
        self.env.update(HOME=str(self.root / 'home'), PATH=str(self.bin) + ':/usr/bin:/bin:/usr/sbin:/sbin',
                        PROBE_DIR=str(self.root), REAL_PYTHON=sys.executable, TMPDIR=str(self.command_tmp),
                        UPDATES_SELF_UPDATE='0')
        self.env.pop('HOMEBREW_NO_ASK', None)
        for name in ('uname', 'brew', 'ncu', 'npm', 'python', 'python3', 'sleep'):
            path = self.bin / name
            path.write_text('#!' + sys.executable + '\n' + STUB)
            path.chmod(0o755)

    def tearDown(self):
        (self.root / 'release').touch()
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
        marker = self.root / 'child.pid'
        if marker.exists():
            pid = int(marker.read_text())
            if self.alive(pid):
                os.kill(pid, signal.SIGTERM)
        descendant = self.root / 'descendant.pid'
        if descendant.exists() and self.alive(int(descendant.read_text())):
            os.kill(int(descendant.read_text()), signal.SIGTERM)
        for pid in self.timer_pids():
            if self.alive(pid):
                os.kill(pid, signal.SIGTERM)
        for handle in self.handles:
            handle.close()
        self.temp.cleanup()

    def module_calls(self):
        return [json.loads(line) for line in self.output('calls').splitlines()
                if json.loads(line)[0] != 'sleep']

    def timer_pids(self):
        return [int(line) for line in self.output('timer.pids').splitlines()]

    @staticmethod
    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    def until(self, predicate, timeout=5):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(.02)
        self.fail('Timed out waiting for stub condition; stdout=' + self.output('stdout') +
                  '; stderr=' + self.output('stderr'))

    def output(self, name):
        path = self.root / name
        return path.read_text() if path.exists() else ''

    def start(self, mode, module, extra=(), tty=None, color=False, tty_streams=('stdout', 'stderr')):
        env = dict(self.env, PROBE_MODE=mode)
        if color:
            env['TERM'] = 'xterm-256color'
            env.pop('NO_COLOR', None)
        streams = {}
        for name in ('stdout', 'stderr'):
            handle = (self.root / name).open('wb')
            self.handles.append(handle)
            streams[name] = tty if tty is not None and name in tty_streams else handle
        flags = ['--no-config', '--no-self-update', '--no-emoji']
        if not color:
            flags.append('--no-color')
        process = subprocess.Popen(['/bin/bash', str(self.script)] + flags +
                                   ['--only', module] + list(extra), env=env,
                                   stdin=tty if tty is not None else subprocess.DEVNULL,
                                   stdout=streams['stdout'], stderr=streams['stderr'],
                                   start_new_session=True)
        self.processes.append(process)
        return process

    def test_parent_signals_stop_active_commands(self):
        for mode, module in (('brew', 'brew'), ('ncu', 'node'),
                             ('preflight', 'node'), ('pip', 'python'),
                             ('pip-version', 'python'), ('pip-help', 'python')):
            for sig, status in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
                with self.subTest(mode=mode, signal=sig):
                    for name in ('ready', 'release', 'child.pid', 'calls', 'timer.pids'):
                        (self.root / name).unlink(missing_ok=True)
                    process = self.start(mode, module)
                    self.until(lambda: (self.root / 'ready').exists())
                    pid = int((self.root / 'child.pid').read_text())
                    calls = self.module_calls()
                    process.send_signal(sig)
                    self.assertEqual(process.wait(timeout=5), status)
                    self.until(lambda: not self.alive(pid))
                    self.until(lambda: not any(self.alive(timer) for timer in self.timer_pids()))
                    self.assertEqual(self.module_calls(), calls, 'Commands ran after cancellation')
                    self.assertIn('Interrupted', self.output('stderr'))
                    self.assertEqual(list(self.command_tmp.glob('updates-command.*')), [],
                                     'Command temporary directories survived cancellation')

    def test_interactive_stdin_is_preserved(self):
        master, slave = pty.openpty()
        try:
            process = self.start('pty', 'brew', tty=slave)
            os.close(slave)
            slave = None
            self.until(lambda: (self.root / 'ready').exists())
            os.write(master, b'confirmed\n')
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertTrue((self.root / 'answered').exists())
        finally:
            os.close(master)
            if slave is not None:
                os.close(slave)

    def test_json_colors_follow_the_human_stream(self):
        # Human output goes to stderr under --json, so only a terminal on
        # stderr may receive ANSI colors; JSONL on stdout never does.
        for tty_stream, file_stream in (('stdout', 'stderr'), ('stderr', 'stdout')):
            with self.subTest(tty=tty_stream):
                master, slave = pty.openpty()
                try:
                    process = self.start('brew', 'brew', ('--json', '--dry-run'), tty=slave,
                                         color=True, tty_streams=(tty_stream,))
                    os.close(slave)
                    slave = None
                    # Drain while running: an unread pty blocks the writer, and
                    # macOS drops buffered pty output once the slave closes.
                    terminal = b''
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        if select.select([master], [], [], .05)[0]:
                            try:
                                chunk = os.read(master, 4096)
                            except OSError:
                                break
                            if not chunk:
                                break
                            terminal += chunk
                        elif process.poll() is not None:
                            break
                    self.assertEqual(process.wait(timeout=5), 0)
                finally:
                    os.close(master)
                    if slave is not None:
                        os.close(slave)
                redirected = (self.root / file_stream).read_bytes()
                self.assertNotIn(b'\x1b', redirected)
                if tty_stream == 'stderr':
                    self.assertIn(b'\x1b[', terminal, 'Expected colored human output on a TTY')
                else:
                    self.assertNotIn(b'\x1b', terminal, 'JSONL stdout must stay uncolored')

    def test_terminal_group_interrupt_stops_runner(self):
        process = self.start('brew', 'brew,node')
        self.until(lambda: (self.root / 'ready').exists())
        pid = int((self.root / 'child.pid').read_text())
        # The fixture owns this newly created session and its process group.
        os.killpg(process.pid, signal.SIGINT)
        self.assertEqual(process.wait(timeout=5), 130)
        self.until(lambda: not self.alive(pid))
        self.until(lambda: not any(self.alive(timer) for timer in self.timer_pids()))
        self.assertNotIn('"ncu"', self.output('calls'))

    def test_child_interrupt_status_stops_later_modules(self):
        process = self.start('brew130', 'brew,node')
        self.assertEqual(process.wait(timeout=5), 130)
        self.assertNotIn('"ncu"', self.output('calls'))
        self.assertNotIn('"upgrade"', self.output('calls'))

    def test_brew_no_ask_is_scoped_to_noninteractive_mode(self):
        for extra, expected in (((), '<unset>'), (('-n',), '1')):
            with self.subTest(extra=extra):
                for name in ('ready', 'release'):
                    (self.root / name).unlink(missing_ok=True)
                process = self.start('brew', 'brew', extra)
                self.until(lambda: (self.root / 'ready').exists())
                self.assertEqual(self.output('brew-no-ask'), expected)
                (self.root / 'release').touch()
                self.assertEqual(process.wait(timeout=5), 0)

    def test_heartbeat_is_live_and_quiet_mode_has_no_timer(self):
        process = self.start('brew', 'brew')
        self.until(lambda: (self.root / 'ready').exists())
        self.until(lambda: 'still running (' in self.output('stdout'), timeout=35)
        self.assertIsNone(process.poll(), 'Heartbeat only appeared after completion')
        self.assertIn('Ctrl+C to cancel', self.output('stdout'))
        self.assertTrue(self.timer_pids())
        (self.root / 'release').touch()
        self.assertEqual(process.wait(timeout=5), 0, self.output('stdout') + self.output('stderr'))
        self.until(lambda: not any(self.alive(pid) for pid in self.timer_pids()))
        for name in ('ready', 'release', 'timer.pids'):
            (self.root / name).unlink(missing_ok=True)
        quiet = self.start('brew', 'brew', ('--log-level', 'warn'))
        self.until(lambda: (self.root / 'ready').exists())
        time.sleep(.15)
        self.assertEqual(self.timer_pids(), [], 'Quiet command started a heartbeat helper')
        (self.root / 'release').touch()
        self.assertEqual(quiet.wait(timeout=5), 0)
        self.assertNotIn('still running', self.output('stdout'))
        self.assertNotIn('still running', self.output('stderr'))

    def test_live_npm_stderr_and_json_log_file(self):
        logfile = self.root / 'updates.log'
        process = self.start('npm-fail', 'node', ('--json', '--log-file', str(logfile)))
        self.until(lambda: (self.root / 'ready').exists())
        self.until(lambda: 'stub diagnostic before completion' in self.output('stderr'))
        self.assertIsNone(process.poll(), 'Diagnostic only became visible after completion')
        (self.root / 'release').touch()
        self.assertEqual(process.wait(timeout=5), 1)
        self.until(lambda: 'stub diagnostic before completion' in self.output('updates.log'))
        rows = [json.loads(line) for line in self.output('stdout').splitlines()]
        summary = next(row for row in rows if row['event'] == 'summary')
        self.assertEqual(summary['fail'], 1)
        self.assertEqual(summary['failures'], ['node'])
        self.assertEqual(self.output('stderr').count('stub diagnostic before completion'), 1)
        self.assertNotIn('"event":', self.output('updates.log'))
        self.assertEqual(list(self.command_tmp.glob('updates-command.*')), [],
                         'Command temporary directories survived streaming completion')

    def test_inherited_npm_stderr_does_not_block_completion(self):
        process = self.start('npm-descendant', 'node')
        self.until(lambda: (self.root / 'ready').exists())
        descendant = int((self.root / 'descendant.pid').read_text())
        self.assertEqual(process.wait(timeout=5), 0, self.output('stderr'))
        self.assertTrue(self.alive(descendant), 'Fixture descendant did not retain its descriptor')
        self.assertIn('inherited descriptor diagnostic', self.output('stderr'))
        self.assertEqual(list(self.command_tmp.glob('updates-command.*')), [],
                         'Command temporary directories survived inherited-stderr completion')
        # This independently started fixture process is intentionally not the
        # updater's direct child. tearDown terminates its recorded PID.

    def test_parallel_pip_reuses_finished_worker_before_first_completes(self):
        process = self.start('pip-scheduler', 'python', ('--parallel', '2'))
        self.until(lambda: (self.root / 'ready').exists())
        first_pid = int((self.root / 'child.pid').read_text())
        self.until(lambda: (self.root / 'second.started').exists())
        self.until(lambda: 'scheduler second complete' in self.output('stdout'))
        self.until(lambda: (self.root / 'third.started').exists())
        self.assertTrue(self.alive(first_pid), 'First worker stopped before its release')
        self.assertIsNone(process.poll())
        self.assertIn('python: finished second', self.output('stdout'))
        self.assertNotIn('python: finished first', self.output('stdout'))
        (self.root / 'release').touch()
        self.assertEqual(process.wait(timeout=5), 0, self.output('stderr'))
        self.until(lambda: not self.alive(first_pid))

    def test_pip_background_and_discovery_are_noninteractive(self):
        for extra in ((), ('-n',)):
            with self.subTest(extra=extra):
                for name in ('ready', 'release', 'calls'):
                    (self.root / name).unlink(missing_ok=True)
                process = self.start('pip', 'python', extra)
                self.until(lambda: (self.root / 'ready').exists())
                calls = [json.loads(line) for line in self.output('calls').splitlines()]
                installs = [call for call in calls if 'install' in call]
                self.assertTrue(installs)
                self.assertTrue(all('--no-input' in call for call in installs))
                if extra:
                    queries = [call for call in calls if 'list' in call]
                    self.assertTrue(queries)
                    self.assertTrue(all('--no-input' in call for call in queries))
                (self.root / 'release').touch()
                self.assertEqual(process.wait(timeout=5), 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
