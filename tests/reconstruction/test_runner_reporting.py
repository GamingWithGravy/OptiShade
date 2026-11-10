"""Exercise actual failed, timed-out and unavailable commands and suite reports."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('reconstruction_runner', HERE / 'run_tests.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class FailureReporting(unittest.TestCase):
    @unittest.skipUnless(os.name == 'nt', 'Windows child-console creation flags are Windows-only')
    def test_captured_windows_children_do_not_create_console_windows(self):
        expected = getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000)
        completed = subprocess.CompletedProcess(['fixture'], 0, '')
        with contextlib.redirect_stdout(io.StringIO()), mock.patch.object(
                runner.subprocess, 'run', return_value=completed) as run_child:
            runner.RegressionRecorder().run([sys.executable, '-c', 'pass'])
        self.assertEqual(expected, run_child.call_args.kwargs['creationflags'])

        with mock.patch.object(runner.shutil, 'which', return_value=r'C:\\Tools\\cl.exe'):
            with mock.patch.object(runner.subprocess, 'run', return_value=completed) as compiler_probe:
                runner.environment_identity('cl')
        self.assertEqual(expected, compiler_probe.call_args.kwargs['creationflags'])

    def test_nonzero_retains_output_and_exit_status(self):
        log = runner.RegressionRecorder()
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(runner.RegressionFailure):
            log.run([sys.executable, '-c', 'print("real failure evidence"); raise SystemExit(7)'])
        self.assertEqual(1, len(log.records))
        self.assertEqual('failed', log.records[0]['status'])
        self.assertEqual(7, log.records[0]['exit_code'])
        self.assertIn('real failure evidence', log.records[0]['output'])

    def test_timeout_retains_partial_output(self):
        log = runner.RegressionRecorder()
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(runner.RegressionFailure):
            log.run([sys.executable, '-u', '-c', 'import time; print("before timeout"); time.sleep(10)'], timeout=0.5)
        self.assertEqual('timed_out', log.records[0]['status'])
        self.assertIsNone(log.records[0]['exit_code'])
        self.assertIn('before timeout', log.records[0]['output'])

    def test_unavailable_command_is_not_a_pass(self):
        log = runner.RegressionRecorder()
        with self.assertRaises(runner.RegressionFailure):
            log.run(['optishade-deliberately-missing-test-executable'])
        self.assertEqual('could_not_start', log.records[0]['status'])
        self.assertIsNone(log.records[0]['exit_code'])

    def test_missing_compiler_cli_writes_fresh_failure_report(self):
        with tempfile.TemporaryDirectory(prefix='optishade-report-fixture-') as directory:
            report = Path(directory) / 'nested' / 'report.json'
            report.parent.mkdir()
            report.write_text('{"status":"passed","records":["stale"]}')
            process = subprocess.run([sys.executable, str(HERE / 'run_tests.py'), '--compiler',
                                      'optishade-deliberately-missing-compiler', '--report', str(report)],
                                     text=True, capture_output=True, timeout=20)
            result = json.loads(report.read_text())
            self.assertNotEqual(0, process.returncode)
            self.assertEqual('failed', result['status'])
            self.assertIn('Compiler unavailable', result['error'])
            self.assertEqual([], result['records'])
            self.assertEqual('not run', result['simulator_or_physical_gpu'])
            self.assertNotIn('regressions passed', process.stdout)


if __name__ == '__main__':
    unittest.main()
