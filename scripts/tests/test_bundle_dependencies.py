"""Real Mach-O fixtures; compiles tiny libraries, never executes their code."""

import hashlib
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "bundle-dependencies.py"
SPEC = importlib.util.spec_from_file_location("bundler", SCRIPT)
bundler = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundler)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("clang"), "requires macOS command line tools")
class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="opal bundle test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "OpenOpal.app"
        self.frameworks = self.app / "Contents/Frameworks"
        self.executable = self.app / "Contents/MacOS/OpenOpal"
        self.frameworks.mkdir(parents=True)
        self.executable.parent.mkdir()
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "OpenOpal"}, stream)
        self.external = self.root / "external"
        self.external.mkdir()

    def compile(self, output, code, *flags, dylib=True):
        source = output.with_suffix(".c")
        source.write_text(code)
        args = ["clang", "-Wl,-headerpad_max_install_names", str(source), "-o", str(output)]
        if dylib:
            args.append("-dynamiclib")
        subprocess.run(args + list(flags), check=True, capture_output=True)
        source.unlink()
        return output

    def make_executable(self, *libs):
        calls = " + ".join(f"fn{i}()" for i in range(len(libs))) or "0"
        declarations = "".join(f"extern int fn{i}(void);" for i in range(len(libs)))
        self.compile(self.executable, declarations + f"int main(void) {{ return {calls}; }}",
                     *map(str, libs), "-Wl,-rpath,@executable_path/../Frameworks", dylib=False)

    def test_recursive_closure_loader_paths_and_source_immutability(self):
        leaf = self.compile(self.external / "libleaf.dylib", "int leaf(void) { return 1; }",
                            "-Wl,-install_name,@loader_path/libleaf.dylib")
        extra = self.compile(self.external / "libextra.dylib",
                             "extern int leaf(void); int extra(void) { return leaf(); }",
                             str(leaf), f"-Wl,-install_name,{self.external}/libextra.dylib")
        middle = self.compile(self.frameworks / "libmiddle.dylib",
                              "extern int extra(void); int fn0(void) { return extra(); }",
                              str(extra), "-Wl,-install_name,@rpath/libmiddle.dylib",
                              "-Wl,-rpath,@loader_path")
        self.make_executable(middle)
        before = {p: hashlib.sha256(p.read_bytes()).digest() for p in (leaf, extra)}
        with self.assertRaisesRegex(bundler.BundleError, "Non-system absolute"):
            bundler.process(self.app, validate_only=True)
        bundler.process(self.app)
        for p, checksum in before.items():
            self.assertEqual(hashlib.sha256(p.read_bytes()).digest(), checksum)
        shutil.rmtree(self.external)
        bundler.process(self.app, validate_only=True)
        self.assertEqual(bundler.inspect(middle)[0][0], "@loader_path/libextra.dylib")
        self.assertTrue((self.frameworks / "libleaf.dylib").exists())
        # Running the bundler again does not need the source libraries.
        bundler.process(self.app)

    def test_unresolved_rpath_rejected(self):
        library = self.compile(self.frameworks / "libmissing.dylib", "int fn0(void) { return 0; }",
                               "-Wl,-install_name,@rpath/libmissing.dylib")
        self.make_executable(library)
        library.unlink()
        with self.assertRaisesRegex(bundler.BundleError, "Unresolved dependency"):
            bundler.process(self.app, validate_only=True)

    def test_external_rpath_rejected_and_bundled(self):
        library = self.compile(self.external / "libexternal.dylib", "int fn0(void) { return 0; }",
                               "-Wl,-install_name,@rpath/libexternal.dylib")
        self.make_executable(library)
        subprocess.run(["install_name_tool", "-add_rpath", str(self.external), str(self.executable)], check=True)
        with self.assertRaisesRegex(bundler.BundleError, "escapes the app"):
            bundler.process(self.app, validate_only=True)
        bundler.process(self.app)
        shutil.rmtree(self.external)
        bundler.process(self.app, validate_only=True)

    def test_install_id_is_not_a_dependency(self):
        # This old build path exists only as LC_ID_DYLIB, not LC_LOAD_DYLIB.
        self.compile(self.frameworks / "libunused.dylib", "int unused(void) { return 0; }",
                     "-Wl,-install_name,/nonexistent/build/libunused.dylib")
        self.make_executable()
        bundler.process(self.app, validate_only=True)
        bundler.process(self.app)

    def test_basename_collision_rejected(self):
        libraries = []
        for i in range(2):
            directory = self.external / str(i)
            directory.mkdir()
            library = directory / "libsame.dylib"
            libraries.append(self.compile(library, f"int fn{i}(void) {{ return {i}; }}",
                                          f"-Wl,-install_name,{library}"))
        self.make_executable(*libraries)
        with self.assertRaisesRegex(bundler.BundleError, "basename collision"):
            bundler.process(self.app)

    def test_external_symlink_rejected(self):
        library = self.compile(self.external / "libexternal.dylib", "int fn0(void) { return 0; }")
        self.make_executable()
        (self.frameworks / "libexternal.dylib").symlink_to(library)
        with self.assertRaisesRegex(bundler.BundleError, "symlink escapes"):
            bundler.process(self.app)

    def test_external_directory_symlink_rejected(self):
        self.make_executable()
        (self.frameworks / "external").symlink_to(self.external, target_is_directory=True)
        with self.assertRaisesRegex(bundler.BundleError, "symlink escapes"):
            bundler.process(self.app)


if __name__ == "__main__":
    unittest.main()
