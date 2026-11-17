"""Offline model-member regressions; no network, app, signing, or camera access."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = "DepthAnythingV2SmallF16.mlpackage"
COMPILED = "DepthAnythingV2SmallF16.mlmodelc"
MEMBERS = (
    "Data/com.apple.CoreML/model.mlmodel",
    "Data/com.apple.CoreML/weights/weight.bin",
    "Manifest.json",
)


class ModelFixture(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="opal model inputs ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.script = scripts / "fetch-models.sh"
        shutil.copy2(ROOT / "scripts/fetch-models.sh", self.script)
        self.models = self.root / "Models"
        self.compiled = self.models / COMPILED
        self.env = {
            **os.environ,
            "PATH": f"{self.tools}{os.pathsep}{os.defpath}",
            "PROBE_ROOT": str(self.root),
        }
        for key in ("DOWNLOAD_MODE", "COMPILE_MODE", "SWAP_MODE"):
            self.env.pop(key, None)
        self.tool("curl", '''
import os, signal, sys
from pathlib import Path
root = Path(os.environ["PROBE_ROOT"])
url = sys.argv[-1]
dest = Path(sys.argv[sys.argv.index("-o") + 1])
with (root / "downloads").open("a") as log:
    log.write(url + "\\n")
mode = os.environ.get("DOWNLOAD_MODE", "success") if url.endswith("weight.bin") else "success"
dest.write_bytes(b"" if mode == "empty" else b"partial" if mode != "success" else b"complete")
if mode in ("interrupt", "terminate"):
    os.kill(os.getppid(), signal.SIGINT if mode == "interrupt" else signal.SIGTERM)
if mode in ("fail", "interrupt", "terminate"):
    sys.exit(18)
''')
        self.tool("xcrun", '''
import os, sys
from pathlib import Path
assert sys.argv[1:3] == ["coremlcompiler", "compile"]
package = Path(sys.argv[3])
for member in ("Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin", "Manifest.json"):
    assert (package / member).read_bytes() == b"complete"
output = Path(sys.argv[4]) / (package.stem + ".mlmodelc")
output.mkdir()
(output / "new").write_bytes(b"replacement")
''')

    def tool(self, name, source):
        path = self.tools / name
        path.write_text(f"#!{sys.executable}\n" + textwrap.dedent(source).lstrip())
        path.chmod(0o755)

    def run_fetch(self, **settings):
        return subprocess.run(
            ["/bin/bash", str(self.script)], cwd=self.root,
            env={**self.env, **settings}, capture_output=True, text=True, timeout=15,
        )

    def assert_no_temporary_outputs(self):
        self.assertEqual(list(self.models.rglob("*.download.*")), [])
        self.assertEqual(list(self.models.glob(".compile.*")), [])


class ModelDownloadTests(ModelFixture):
    def download_failure_and_retry(self, mode):
        failure = self.run_fetch(DOWNLOAD_MODE=mode)
        self.assertNotEqual(failure.returncode, 0, failure.stdout + failure.stderr)
        self.assertFalse((self.models / PACKAGE / MEMBERS[1]).exists())
        self.assertFalse(self.compiled.exists())
        self.assertEqual((self.models / PACKAGE / MEMBERS[0]).read_bytes(), b"complete")
        self.assert_no_temporary_outputs()
        retry = self.run_fetch()
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        downloads = (self.root / "downloads").read_text().splitlines()
        for member, count in zip(MEMBERS, (1, 2, 1)):
            self.assertEqual(sum(url.endswith("/" + member) for url in downloads), count)
            self.assertEqual((self.models / PACKAGE / member).read_bytes(), b"complete")
        self.assertEqual((self.compiled / "new").read_bytes(), b"replacement")
        self.assert_no_temporary_outputs()

    def test_failed_download_is_not_cached_on_retry(self):
        self.download_failure_and_retry("fail")

    def test_interrupted_download_is_not_cached_on_retry(self):
        self.download_failure_and_retry("interrupt")

    def test_terminated_download_is_not_cached_on_retry(self):
        self.download_failure_and_retry("terminate")

    def test_empty_successful_download_is_not_cached_on_retry(self):
        self.download_failure_and_retry("empty")

    def test_empty_cached_member_is_replaced(self):
        cached = self.models / PACKAGE / MEMBERS[1]
        cached.parent.mkdir(parents=True)
        cached.touch()
        result = self.run_fetch()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(cached.read_bytes(), b"complete")
        self.assertEqual(len((self.root / "downloads").read_text().splitlines()), 3)
        self.assert_no_temporary_outputs()

    def test_cleanup_leaves_another_runs_temporary_file_alone(self):
        foreign = self.models / PACKAGE / (MEMBERS[1] + ".download.foreign")
        foreign.parent.mkdir(parents=True)
        foreign.write_bytes(b"another download")
        result = self.run_fetch(DOWNLOAD_MODE="terminate")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(foreign.read_bytes(), b"another download")
        self.assertEqual(list(self.models.rglob("*.download.*")), [foreign])
        self.assertFalse((self.models / PACKAGE / MEMBERS[1]).exists())


if __name__ == "__main__":
    unittest.main()
