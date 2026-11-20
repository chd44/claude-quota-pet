#!/usr/bin/env python3
"""Explicit macOS GUI regression: a packaged helper must deliver cold/warm CLI URLs.

Run from any directory:
    python3 scripts/check-launch-activation.py --run-gui [path/to/QuotaPetLauncher]

Requires a logged-in macOS graphical session, Swift Command Line Tools and codesign.
This is intentionally outside headless make check. It builds a unique temporary
.app receiver, copies only the supplied helper, and never starts the real QuotaPet,
opens websites, changes preferences, or registers a login item. Only the receiver
whose PID and exact executable path belong to this run may be terminated.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

RECEIVER = r'''
import AppKit
import Foundation

let root = Bundle.main.bundleURL.deletingLastPathComponent()
let pid = ProcessInfo.processInfo.processIdentifier
try String(pid).write(to: root.appendingPathComponent("receiver.pid"), atomically: true, encoding: .utf8)

final class Receiver: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let file = root.appendingPathComponent("events.jsonl")
        var content = (try? Data(contentsOf: file)) ?? Data()
        for url in urls {
            let event: [String: Any] = ["pid": pid, "url": url.absoluteString]
            content.append(try! JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
            content.append(10)
        }
        try! content.write(to: file, options: .atomic)
    }
}
let app = NSApplication.shared
let delegate = Receiver()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
app.run()
'''


def wait_for(predicate, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return bool(predicate())


def executable_for_pid(pid):
    """Inspect one PID, without enumerating processes or matching unrelated apps."""
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    libproc.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        return None
    return Path(os.fsdecode(buffer.value)).resolve()


def verify(helper):
    results = {'helper': str(helper), 'passed': False}
    with tempfile.TemporaryDirectory(prefix='quotapet-launch-activation-') as directory:
        root = Path(directory).resolve()
        app = root / 'QuotaPet Activation Receiver.app'
        mac = app / 'Contents/MacOS'
        mac.mkdir(parents=True)
        source = root / 'receiver.swift'
        source.write_text(RECEIVER)
        receiver = mac / 'Receiver'
        identifier = 'dev.quotapet.activationtest.' + uuid.uuid4().hex
        results['temporary_bundle_id'] = identifier
        with (app / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump({'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'Receiver',
                          'CFBundleName': 'QuotaPet Activation Receiver', 'CFBundlePackageType': 'APPL',
                          'CFBundleVersion': '1', 'LSUIElement': True}, stream)
        # Deliberately no URL-scheme registration: activation targets this exact .app.
        subprocess.run(['/usr/bin/xcrun', 'swiftc', str(source), '-module-cache-path',
                        str(root / 'ModuleCache'), '-o', str(receiver)], check=True, timeout=180)
        shutil.copy2(helper, mac / 'QuotaPetLauncher')
        for target in [receiver, mac / 'QuotaPetLauncher', app]:
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(target)],
                           check=True, capture_output=True, text=True, timeout=30)
        pid_file = root / 'receiver.pid'
        events_file = root / 'events.jsonl'

        def events():
            if not events_file.exists():
                return []
            return [json.loads(line) for line in events_file.read_text().splitlines()]

        def owned_pid():
            if not pid_file.exists():
                return None
            pid = int(pid_file.read_text())
            if pid <= 1 or executable_for_pid(pid) != receiver.resolve():
                return None
            return pid

        command = [str(mac / 'QuotaPetLauncher'), '--wake-cli']
        captured_pid = None
        try:
            for name, count in [('cold', 1), ('warm', 2)]:
                launch = subprocess.run(command, capture_output=True, text=True, timeout=25)
                results[name + '_helper_exit'] = launch.returncode
                if launch.returncode:
                    raise RuntimeError(name + ' helper failed: ' + launch.stderr.strip())
                # Helper exit zero alone is insufficient: require actual receiver delivery.
                delivered = wait_for(lambda: len(events()) >= count and owned_pid() is not None)
                results[name + '_url_received'] = delivered
                if not delivered:
                    raise RuntimeError(name + ' CLI URL did not reach the receiver')
                pid = owned_pid()
                if captured_pid is None:
                    captured_pid = pid
                if pid != captured_pid:
                    raise RuntimeError('Warm activation launched a different receiver process')
                expected = [{'pid': captured_pid, 'url': 'quotapet://cli'}] * count
                if events() != expected:
                    raise RuntimeError('Unexpected, duplicate, or wrong-PID URL delivery: ' + repr(events()))
            results.update(receiver_pid=captured_pid, warm_same_receiver=True, events=events(), passed=True)
        finally:
            # The receiver records its PID before initializing AppKit, including on failure.
            # Never scan/kill by application name or touch a PID with a different executable.
            if pid_file.exists():
                pid = int(pid_file.read_text())
                current = executable_for_pid(pid)
                if current == receiver.resolve():
                    os.kill(pid, signal.SIGTERM)
                    if not wait_for(lambda: executable_for_pid(pid) != receiver.resolve(), seconds=5):
                        if executable_for_pid(pid) == receiver.resolve():
                            os.kill(pid, signal.SIGKILL)
                        if not wait_for(lambda: executable_for_pid(pid) != receiver.resolve(), seconds=5):
                            raise RuntimeError('Could not clean up the owned receiver process')
                    results['receiver_cleaned_up'] = True
                elif current is None:
                    results['receiver_cleaned_up'] = True
                else:
                    raise RuntimeError('Refusing to signal a PID that no longer belongs to this receiver')
            else:
                results['receiver_cleaned_up'] = True  # No receiver ever started.
            print(json.dumps(results, indent=2), flush=True)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--run-gui', action='store_true', help='explicitly enable this graphical-session test')
    parser.add_argument('helper', nargs='?', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'build/QuotaPet.app/Contents/MacOS/QuotaPetLauncher')
    args = parser.parse_args()
    if not args.run_gui:
        parser.error('This GUI test is opt-in. Re-run with --run-gui in a logged-in macOS graphical session.')
    if sys.platform != 'darwin':
        parser.error('This test requires macOS LaunchServices and a graphical session.')
    helper = args.helper.expanduser().resolve()
    if not helper.is_file() or not os.access(helper, os.X_OK):
        parser.error('Build a packaged executable helper first, or pass its path: ' + str(helper))
    try:
        verify(helper)
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print('FAIL: ' + str(error), file=sys.stderr)
        return 1
    print('PASS: cold/warm CLI URLs reached the same temporary receiver; owned process cleaned up.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
