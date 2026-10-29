"""Execute release shell steps offline with tag values treated as untrusted data."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ReleaseNameTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="opal release names ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.env = {
            **os.environ,
            "PATH": f"{self.tools}{os.pathsep}{os.defpath}",
            "PROBE_ROOT": str(self.root),
        }
        self.env.pop("DMG_FAIL_ONCE", None)
        self.tool("create-dmg", '''
import json, os, sys
from pathlib import Path
root = Path(os.environ["PROBE_ROOT"])
log = root / "dmg-args"
first = not log.exists()
with log.open("a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\\n")
if first and os.environ.get("DMG_FAIL_ONCE"):
    sys.exit(1)
Path(sys.argv[-2]).write_bytes(b"offline dmg")
''')
        self.tool("xcrun", '''
import json, os, sys
from pathlib import Path
root = Path(os.environ["PROBE_ROOT"])
args = sys.argv[1:]
if args[:2] == ["notarytool", "submit"]:
    filename = args[2]
else:
    assert args[:2] == ["stapler", "staple"]
    filename = args[2]
assert Path(filename).read_bytes() == b"offline dmg"
with (root / "notary-args").open("a") as log:
    log.write(json.dumps(args) + "\\n")
''')

    def tool(self, name, source):
        path = self.tools / name
        path.write_text(f"#!{sys.executable}\n" + textwrap.dedent(source).lstrip())
        path.chmod(0o755)

    def workflow_step(self, name, tag):
        # Execute the actual block, emulating runner expansion in env and source.
        lines = (ROOT / ".github/workflows/release.yml").read_text().splitlines()
        start = lines.index("      - name: " + name) + 1
        end = next(
            (i for i in range(start, len(lines)) if lines[i].startswith("      - ")),
            len(lines),
        )
        block = lines[start:end]
        run = block.index("        run: |")
        source = textwrap.dedent("\n".join(block[run + 1:]))
        environment = dict(self.env)
        for line in block[:run]:
            if line.startswith("          "):
                key, value = line.strip().split(": ", 1)
                environment[key] = tag if value == "${{ github.ref_name }}" else "offline test value"
        source = re.sub(r"\$\{\{\s*github\.ref_name\s*\}\}", lambda match: tag, source)
        return subprocess.run(
            ["/bin/bash", "-e", "-c", source], cwd=self.root, env=environment,
            capture_output=True, text=True, timeout=15,
        )

    def assert_literal_release_name(self, tag, fallback=False):
        validity = subprocess.run(
            ["git", "check-ref-format", f"refs/tags/{tag}"], cwd=self.root,
            env=self.env, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(validity.returncode, 0, validity.stdout + validity.stderr)
        filename = f"OpenOpal-{tag}.dmg"
        if fallback:
            self.env["DMG_FAIL_ONCE"] = "1"
        for step in ("Package DMG", "Notarize DMG"):
            result = self.workflow_step(step, tag)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((self.root / "tag-injected").exists())
        self.assertEqual((self.root / filename).read_bytes(), b"offline dmg")
        self.assertEqual(sorted(p.name for p in self.root.glob("*.dmg")), [filename])
        calls = [json.loads(line) for line in (self.root / "dmg-args").read_text().splitlines()]
        self.assertEqual(len(calls), 2 if fallback else 1)
        for call in calls:
            self.assertEqual(call[-2:], [filename, "build/DerivedData/Build/Products/Release/OpenOpal.app"])
        if fallback:
            self.assertEqual(calls[1], [filename, "build/DerivedData/Build/Products/Release/OpenOpal.app"])
        notary = [json.loads(line) for line in (self.root / "notary-args").read_text().splitlines()]
        self.assertEqual(notary, [
            ["notarytool", "submit", filename, "--apple-id", "offline test value",
             "--team-id", "offline test value", "--password", "offline test value", "--wait"],
            ["stapler", "staple", filename],
        ])

    def test_normal_tag_is_used_for_packaging_and_notarization(self):
        self.assert_literal_release_name("v0.1.0")

    def test_command_substitution_is_literal_in_fallback_and_notarization(self):
        self.assert_literal_release_name("v$(touch${IFS}tag-injected)", fallback=True)

    def test_backtick_substitution_is_literal(self):
        self.assert_literal_release_name("v`touch${IFS}tag-injected`")

    def test_quotes_and_shell_commands_are_literal(self):
        self.assert_literal_release_name('v";touch${IFS}tag-injected;echo"', fallback=True)


if __name__ == "__main__":
    unittest.main()
