"""Offline compiler fixtures with the real macOS directory-exchange helper."""

import os
import signal
import sys
import threading
import unittest

from test_model_downloads import COMPILED, ModelFixture


class ModelPublicationTests(ModelFixture):
    def setUp(self):
        super().setUp()
        self.tool("xcrun", '''
import os, signal, subprocess, sys
from pathlib import Path
root = Path(os.environ["PROBE_ROOT"])
if sys.argv[1:3] == ["coremlcompiler", "compile"]:
    mode = os.environ.get("COMPILE_MODE", "success")
    package = Path(sys.argv[3])
    for member in ("Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin", "Manifest.json"):
        assert (package / member).read_bytes() == b"complete"
    if mode != "missing":
        output = Path(sys.argv[4]) / (package.stem + ".mlmodelc")
        output.mkdir()
        (output / "new").write_bytes(b"replacement")
        (output / "weights").mkdir()
        (output / "weights" / "data").write_bytes(b"complete weights")
    if mode == "interrupt":
        os.kill(os.getppid(), signal.SIGTERM)
    sys.exit(65 if mode in ("fail", "interrupt") else 0)
assert sys.argv[1] == "clang"
result = subprocess.run(["/usr/bin/xcrun", *sys.argv[1:]])
if result.returncode:
    sys.exit(result.returncode)
mode = os.environ.get("SWAP_MODE")
if mode:
    helper = Path(sys.argv[-1])
    native = helper.with_name("exchange-model-native")
    helper.rename(native)
    helper.write_text(f"""#!{sys.executable}
import os, signal, subprocess, sys
mode = {mode!r}
if mode == "fail":
    sys.exit(1)
if mode in ("interrupt", "kill-before"):
    os.kill(os.getppid(), signal.SIGKILL if mode == "kill-before" else signal.SIGTERM)
    sys.exit(1)
result = subprocess.run([{str(native)!r}, *sys.argv[1:]])
if result.returncode == 0 and mode == "kill-after":
    os.kill(os.getppid(), signal.SIGKILL)
sys.exit(result.returncode)
""")
    helper.chmod(0o755)
sys.exit(0)
''')

    def previous_model(self):
        if sys.platform != "darwin":
            self.skipTest("Replacement uses macOS atomic directory exchange")
        self.compiled.mkdir(parents=True)
        (self.compiled / "old").write_bytes(b"last working model")
        (self.compiled / "weights").mkdir()
        (self.compiled / "weights" / "data").write_bytes(b"old weights")

    def assert_previous_model(self, directory=None):
        directory = self.compiled if directory is None else directory
        self.assertEqual(sorted(p.name for p in directory.iterdir()), ["old", "weights"])
        self.assertEqual((directory / "old").read_bytes(), b"last working model")
        self.assertEqual((directory / "weights" / "data").read_bytes(), b"old weights")

    def assert_new_model(self, directory=None):
        directory = self.compiled if directory is None else directory
        self.assertEqual(sorted(p.name for p in directory.iterdir()), ["new", "weights"])
        self.assertEqual((directory / "new").read_bytes(), b"replacement")
        self.assertEqual((directory / "weights" / "data").read_bytes(), b"complete weights")

    def compile_failure_and_retry(self, **settings):
        self.previous_model()
        failure = self.run_fetch(**settings)
        self.assertNotEqual(failure.returncode, 0, failure.stdout + failure.stderr)
        self.assert_previous_model()
        self.assert_no_temporary_outputs()
        downloads = (self.root / "downloads").read_bytes()
        retry = self.run_fetch()
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        self.assertEqual((self.root / "downloads").read_bytes(), downloads)
        self.assert_new_model()
        self.assert_no_temporary_outputs()

    def test_failed_compilation_preserves_previous_model(self):
        self.compile_failure_and_retry(COMPILE_MODE="fail")

    def test_interrupted_compilation_preserves_previous_model(self):
        self.compile_failure_and_retry(COMPILE_MODE="interrupt")

    def test_missing_compiler_output_preserves_previous_model(self):
        self.compile_failure_and_retry(COMPILE_MODE="missing")

    def test_failed_exchange_preserves_previous_model(self):
        self.compile_failure_and_retry(SWAP_MODE="fail")

    def test_interrupted_exchange_preserves_previous_model(self):
        self.compile_failure_and_retry(SWAP_MODE="interrupt")

    def test_first_install_publishes_complete_model(self):
        result = self.run_fetch()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_new_model()
        self.assert_no_temporary_outputs()

    def test_replacement_keeps_published_directory_visible(self):
        self.previous_model()
        stop = threading.Event()
        observing = threading.Event()
        missing = []

        def observe():
            while not stop.is_set():
                try:
                    self.compiled.stat()
                except FileNotFoundError:
                    missing.append(True)
                observing.set()
                stop.wait(0.0001)

        reader = threading.Thread(target=observe)
        reader.start()
        try:
            self.assertTrue(observing.wait(1))
            result = self.run_fetch()
        finally:
            stop.set()
            reader.join()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(missing, "Replacement briefly removed the published model")
        self.assert_new_model()
        self.assert_no_temporary_outputs()

    def killed_exchange_and_retry(self, mode):
        self.previous_model()
        result = self.run_fetch(SWAP_MODE=mode)
        self.assertEqual(result.returncode, -signal.SIGKILL, result.stdout + result.stderr)
        abandoned = list(self.models.glob(".compile.*"))
        self.assertEqual(len(abandoned), 1)
        staged = abandoned[0] / COMPILED
        if mode == "kill-before":
            self.assert_previous_model()
            self.assert_new_model(staged)
        else:
            self.assert_new_model()
            self.assert_previous_model(staged)
        retry = self.run_fetch()
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        self.assert_new_model()
        self.assertEqual(list(self.models.glob(".compile.*")), abandoned)
        if mode == "kill-before":
            self.assert_new_model(staged)
        else:
            self.assert_previous_model(staged)

    def test_killed_exchange_before_swap_keeps_old_model(self):
        self.killed_exchange_and_retry("kill-before")

    def test_killed_exchange_after_swap_keeps_new_model(self):
        self.killed_exchange_and_retry("kill-after")

    def test_failed_compilation_cleans_only_its_own_staging_directory(self):
        self.previous_model()
        foreign = self.models / ".compile.foreign"
        foreign.mkdir()
        (foreign / "owned").write_bytes(b"another compiler")
        result = self.run_fetch(COMPILE_MODE="fail")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_previous_model()
        self.assertEqual(list(self.models.glob(".compile.*")), [foreign])
        self.assertEqual((foreign / "owned").read_bytes(), b"another compiler")


if __name__ == "__main__":
    unittest.main()
