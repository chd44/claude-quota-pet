#!/usr/bin/env python3
"""Isolated shell integration checks. Never launches an installed app or real CLI."""
import json
import os
from pathlib import Path
import pty
import select
import shlex
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'Resources/quotapet-shell.sh'


class ShellIntegration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='quotapet-shell-')
        self.root = Path(self.tmp.name)
        fake = self.root / 'cli'
        fake.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['CLI_LOG'], 'a') as f:
    f.write(json.dumps({'args': sys.argv[1:], 'tty': [os.isatty(i) for i in range(3)]}) + '\\n')
if os.environ.get('READ_INPUT'):
    print('INPUT:' + sys.stdin.read())
print('CLI stdout')
print('CLI stderr', file=sys.stderr)
sys.exit(23)
''')
        fake.chmod(0o755)
        for name in ('codex', 'claude'):
            (self.root / name).symlink_to(fake)
        bundle = self.root / "Installed one's apps/Quota Pet's.app/Contents"
        (bundle / 'MacOS').mkdir(parents=True)
        (bundle / 'Resources').mkdir()
        (bundle / 'Info.plist').write_text('<plist/>')
        launcher = bundle / 'MacOS/QuotaPetLauncher'
        launcher.write_text('''#!/usr/bin/env python3
import json, os, sys, time
with open(os.environ['OPEN_LOG'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
time.sleep(float(os.environ.get('OPEN_DELAY', '0')))
sys.exit(9)
''')
        launcher.chmod(0o755)
        # Exercise the real script unchanged inside a synthetic .app bundle.
        # The only executable helper here is the fake above, never an installed app.
        self.integration = bundle / 'Resources/quotapet-shell.sh'
        self.integration.write_text(SCRIPT.read_text())
        self.env = dict(os.environ, PATH=str(self.root) + ':' + os.environ['PATH'],
                        CLI_LOG=str(self.root / 'cli.jsonl'), OPEN_LOG=str(self.root / 'open.jsonl'))

    def tearDown(self):
        self.tmp.cleanup()

    def run_shell(self, shell, body, interactive=True, terminal=False):
        command = [shell, '-f' if shell.endswith('zsh') else '--noprofile']
        if shell.endswith('bash'):
            command += ['--norc']
        command += ['-ic' if interactive else '-c', 'source ' + shlex.quote(str(self.integration)) + '\n' + body]
        if not terminal:
            return subprocess.run(command, env=self.env, input='', text=True, capture_output=True, timeout=5)
        master, slave = pty.openpty()
        process = subprocess.Popen(command, env=self.env, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = b''
        while process.poll() is None:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    output += os.read(master, 4096)
                except OSError:
                    break
        process.wait(timeout=5)
        os.close(master)
        return subprocess.CompletedProcess(command, process.returncode, output.decode(), '')

    def lines(self, filename, wait=False):
        path = self.root / filename
        deadline = time.monotonic() + (2 if wait else 0)
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        return [json.loads(s) for s in path.read_text().splitlines()] if path.exists() else []

    def test_forwarding_redirection_and_launch(self):
        for shell in ('/bin/bash', '/bin/zsh'):
            with self.subTest(shell=shell):
                result = self.run_shell(shell, 'codex "a b" "" "*" --flag >"$CLI_LOG.out" 2>"$CLI_LOG.err"\nexit $?')
                self.assertEqual(result.returncode, 23)
                self.assertEqual(self.lines('cli.jsonl')[-1]['args'], ['a b', '', '*', '--flag'])
                self.assertEqual((self.root / 'cli.jsonl.out').read_text(), 'CLI stdout\n')
                self.assertEqual((self.root / 'cli.jsonl.err').read_text(), 'CLI stderr\n')
                self.assertTrue(self.lines('open.jsonl', wait=True), 'CLI invocation must request QuotaPet launch')
                self.assertEqual(self.lines('open.jsonl')[-1], ['--wake-cli'])

    def test_pipeline_and_stdin_are_preserved(self):
        self.env['READ_INPUT'] = '1'
        for shell in ('/bin/bash', '/bin/zsh'):
            result = self.run_shell(shell, "printf 'hello input' | claude | cat")
            self.assertIn('INPUT:hello input', result.stdout)
            self.assertIn('CLI stdout', result.stdout)
            self.assertIn('CLI stderr', result.stderr)

    def test_repeated_source_does_not_nest_wrappers(self):
        for shell in ('/bin/bash', '/bin/zsh'):
            self.run_shell(shell, 'source ' + shlex.quote(str(self.integration)) + '\ncodex')
        deadline = time.monotonic() + 2
        while len(self.lines('open.jsonl')) < 2 and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(len(self.lines('cli.jsonl')), 2)
        self.assertEqual(len(self.lines('open.jsonl')), 2)

    def test_cli_preserves_tty(self):
        for shell in ('/bin/bash', '/bin/zsh'):
            result = self.run_shell(shell, 'claude\nexit $?', terminal=True)
            self.assertEqual(result.returncode, 23)
            self.assertEqual(self.lines('cli.jsonl')[-1]['tty'], [True, True, True])

    def test_preexisting_customizations_skip_install(self):
        for shell in ('/bin/bash', '/bin/zsh'):
            # Define before sourcing in a fresh shell rather than replacing installed wrappers.
            original = self.integration.read_text()
            self.integration.write_text('alias codex="printf alias-kept"\nfunction claude { printf function-kept; }\n' + original)
            result = self.run_shell(shell, 'eval codex\nclaude')
            self.assertIn('alias-kept', result.stdout)
            self.assertIn('function-kept', result.stdout)
            self.assertIn('codex', result.stderr)
            self.assertIn('claude', result.stderr)
            self.assertEqual(self.lines('open.jsonl'), [])
            self.integration.write_text(original)

    def test_noninteractive_does_not_install_or_launch(self):
        for shell in ('/bin/bash', '/bin/zsh'):
            result = self.run_shell(shell, 'codex\nexit $?', interactive=False)
            self.assertEqual(result.returncode, 23)
            self.assertEqual(self.lines('open.jsonl'), [])

    def test_wrapper_remains_bound_after_cwd_and_variable_changes(self):
        for shell in ('/bin/bash', '/bin/zsh'):
            result = self.run_shell(shell, 'cd /\n__quotapet_launcher_quoted=/missing\ncodex\nexit $?')
            self.assertEqual(result.returncode, 23)
        deadline = time.monotonic() + 2
        while len(self.lines('open.jsonl')) < 2 and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(len(self.lines('open.jsonl')), 2)

    def test_script_outside_bundle_does_not_install(self):
        self.integration = self.root / 'quotapet-shell.sh'
        self.integration.write_text(SCRIPT.read_text())
        for shell in ('/bin/bash', '/bin/zsh'):
            result = self.run_shell(shell, 'codex\nexit $?')
            self.assertEqual(result.returncode, 23)
            self.assertIn('QuotaPet', result.stderr)
        self.assertEqual(self.lines('open.jsonl'), [])

    def test_missing_helper_does_not_install(self):
        (self.integration.parent.parent / 'MacOS/QuotaPetLauncher').unlink()
        for shell in ('/bin/bash', '/bin/zsh'):
            result = self.run_shell(shell, 'codex\nexit $?')
            self.assertEqual(result.returncode, 23)
            self.assertIn('QuotaPet', result.stderr)
        self.assertEqual(self.lines('open.jsonl'), [])

    def test_failed_slow_launcher_does_not_delay_cli(self):
        self.env['OPEN_DELAY'] = '2'
        start = time.monotonic()
        result = self.run_shell('/bin/zsh', 'codex\nexit $?')
        self.assertEqual(result.returncode, 23)
        self.assertLess(time.monotonic() - start, 1.5)
        self.assertTrue(self.lines('open.jsonl', wait=True))


if __name__ == '__main__':
    unittest.main()
