#!/usr/bin/env python3
"""Bundle the app's non-system dylib closure before code signing."""

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys


MACHO_MAGIC = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
LOAD_COMMANDS = {
    "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
    "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB",
}


class BundleError(Exception):
    pass


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        raise BundleError(f"{' '.join(map(str, args))}: {result.stderr.strip()}")
    return result.stdout


def inspect(path):
    """Use load commands, not otool -L's first line (which may be LC_ID_DYLIB)."""
    dependencies, rpaths, install_ids = [], [], []
    command = None
    for line in run("otool", "-l", str(path)).splitlines():
        line = line.strip()
        if line.startswith("cmd "):
            command = line[4:]
        match = re.match(r"(?:name|path) (.+) \(offset \d+\)$", line)
        if not match:
            continue
        value = match[1]
        if command in LOAD_COMMANDS and value not in dependencies:
            dependencies.append(value)
        elif command == "LC_RPATH" and value not in rpaths:
            rpaths.append(value)
        elif command == "LC_ID_DYLIB" and value not in install_ids:
            install_ids.append(value)
    return dependencies, rpaths, install_ids


def is_system(name):
    return name.startswith(("/usr/lib/", "/System/Library/"))


def is_macho(path):
    with path.open("rb") as stream:
        return stream.read(4) in MACHO_MAGIC


def contained(path, directory):
    return path.resolve().is_relative_to(directory)


def executable_for(binary, app):
    for directory in binary.parents:
        if directory.name == "Contents":
            info = directory / "Info.plist"
            if info.exists():
                with info.open("rb") as stream:
                    name = plistlib.load(stream).get("CFBundleExecutable")
                if name:
                    return directory / "MacOS" / name
        if directory == app:
            break
    raise BundleError(f"Cannot find bundle executable for {binary}")


def expand(name, origin, executable):
    if name == "@loader_path":
        return origin.parent
    if name == "@executable_path":
        return executable.parent
    if name.startswith("@loader_path/"):
        return origin.parent / name[len("@loader_path/"):]
    if name.startswith("@executable_path/"):
        return executable.parent / name[len("@executable_path/"):]
    if name.startswith("/"):
        return Path(name)
    raise BundleError(f"Unsupported relative install path {name!r} in {origin}")


def resolve(name, origin, executable, rpaths):
    if name.startswith("@rpath/"):
        suffix = name[len("@rpath/"):]
        candidates = [directory / suffix for directory in rpaths]
    else:
        candidates = [expand(name, origin, executable)]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise BundleError(f"Unresolved dependency {name!r} in {origin}")


def digest(path):
    return hashlib.sha256(path.read_bytes()).digest()


def process(app, validate_only=False):
    app = app.resolve()
    if not (app / "Contents/Info.plist").is_file():
        raise BundleError(f"Not an application bundle: {app}")
    frameworks = app / "Contents/Frameworks"
    if frameworks.is_symlink() and not contained(frameworks, app):
        raise BundleError(f"Frameworks directory escapes the app: {frameworks}")
    binaries = []
    for path in sorted(app.rglob("*")):
        if path.is_symlink() and not contained(path, app):
            raise BundleError(f"Bundle symlink escapes the app: {path}")
        if not path.is_file():
            continue
        if not contained(path, app):
            raise BundleError(f"Bundle symlink escapes the app: {path}")
        if is_macho(path):
            binaries.append(path.resolve())
    if not binaries:
        raise BundleError(f"No Mach-O binaries in {app}")
    if not validate_only:
        frameworks.mkdir(parents=True, exist_ok=True)

    # A copied library's @loader_path/LC_RPATH still refers to its source until
    # we rewrite its load commands. Keep that origin separate from its target.
    pending = []
    for binary in binaries:
        executable = executable_for(binary, app)
        inherited = [expand(p, executable, executable) for p in inspect(executable)[1]]
        pending.append((binary, binary, executable, inherited))
    seen = set()
    sources = {}
    while pending:
        binary, origin, executable, inherited = pending.pop(0)
        if binary in seen:
            continue
        seen.add(binary)
        dependencies, local_rpaths, install_ids = inspect(binary)
        rpaths = [expand(p, origin, executable) for p in local_rpaths] + inherited
        changes = []
        for name in dependencies:
            if is_system(name):
                continue
            if validate_only and name.startswith("/"):
                raise BundleError(f"Non-system absolute dependency {name!r} in {binary}")
            source = resolve(name, origin, executable, rpaths)
            if contained(source, app):
                target = source
            elif validate_only:
                raise BundleError(f"Dependency {name!r} escapes the app: {source}")
            else:
                if source.suffix != ".dylib" or not is_macho(source):
                    raise BundleError(f"Expected an external Mach-O dylib: {source}")
                # Preserve the load command's filename, including versioned
                # names, even when Homebrew resolves it through a symlink.
                target = frameworks / Path(name).name
                previous = sources.get(target)
                if previous is not None and previous != source:
                    raise BundleError(f"Dylib basename collision: {previous} and {source} -> {target}")
                if target.exists():
                    if previous is None and digest(target) != digest(source):
                        raise BundleError(f"Dylib basename collision: {source} -> existing {target}")
                else:
                    shutil.copy2(source, target)
                    target.chmod(target.stat().st_mode | 0o200)
                    print(f"Bundled {source.name}")
                sources[target] = source
                pending.append((target, source, executable, rpaths))
            if not validate_only:
                replacement = "@loader_path/" + os.path.relpath(target, binary.parent)
                if name != replacement:
                    changes.extend(["-change", name, replacement])
        if not validate_only:
            if install_ids:
                changes.extend(["-id", "@rpath/" + binary.name])
            if changes:
                run("install_name_tool", *changes, str(binary))
    if not validate_only:
        # Inspect the rewritten files afresh, without build-machine origins.
        process(app, validate_only=True)
    else:
        print(f"Validated {len(seen)} Mach-O binaries: dependency closure stays inside the app or macOS")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--validate-only", action="store_true",
                        help="reject external/unresolved dependencies without modifying files")
    args = parser.parse_args()
    try:
        process(args.app, args.validate_only)
    except (BundleError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"bundle-dependencies: {error}\n")


if __name__ == "__main__":
    main()
