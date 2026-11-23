"""Build and test the parallel kernels with OpenMP turned on.

The default build uses the thread pool, because the flag that enables OpenMP is
not the same on every compiler. This script copies the repository to a temporary
directory, gives the `moondask/omp` package the flag for this platform, and runs
its tests plus the example that times the kernels. The copy is thrown away, so the
working tree is untouched.

Usage: python3 scripts/check_openmp.py [--moon moon]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = Path("src") / "omp" / "moon.pkg"
STUB = '"native-stub": [ "kernel.c" ],'


def openmp_build():
    """The compile flag and the runtime library, per compiler family."""
    if sys.platform == "win32":
        return "-openmp", "vcomp"
    return "-fopenmp", "gomp"


def patched(text, flag, library):
    """The package file with the C stub compiled against OpenMP.

    The runtime is named as a library dependency of the stub, so every program
    that links the kernels gets it, including the tests of the package itself.
    """
    if STUB not in text:
        sys.exit(f"{PACKAGE} does not look like the package file this expects")
    link = json.dumps(
        {"native": {"stub-cc-flags": flag, "stub-lib-deps": [library]}}
    )
    addition = f'  "native-stub": [ "kernel.c" ],\n  link: {link},'
    return text.replace(STUB, addition, 1)


def run(moon, work, *args):
    print(f"$ moon {' '.join(args)}")
    result = subprocess.run([moon, *args], cwd=work)
    if result.returncode != 0:
        sys.exit(result.returncode)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--moon", default="moon")
    options = parser.parse_args()

    package = (ROOT / PACKAGE).read_text(encoding="utf-8")
    flag, library = openmp_build()
    with tempfile.TemporaryDirectory(prefix="moondask-openmp-") as raw:
        work = Path(raw)
        for name in ("moon.mod", "src", "LICENSE", "README.md"):
            source = ROOT / name
            target = work / name
            if source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copy2(source, target)
        (work / PACKAGE).write_text(patched(package, flag, library), encoding="utf-8")
        run(options.moon, work, "update")
        run(options.moon, work, "check", "--target", "native", "--deny-warn")
        run(
            options.moon,
            work,
            "run",
            "src/examples/04-parallel-kernels",
            "--target",
            "native",
        )
        run(
            options.moon,
            work,
            "test",
            "--target",
            "native",
            "-p",
            "moonbitstack/moondask/omp",
        )


if __name__ == "__main__":
    main()
