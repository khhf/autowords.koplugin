"""Run the AutoWords offline unit tests with the lupa Lua runtime.

Usage (from the repository root):

    python tests/run_tests.py

Requires `pip install lupa`.  The tests themselves live in
tests/test_autowords.lua and only need a plain Lua interpreter.
"""

import os
import sys

try:
    import lupa
except ImportError:  # pragma: no cover
    sys.exit("lupa is required: python -m pip install lupa")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TEST_FILE = os.path.join(HERE, "test_autowords.lua")


def main():
    with open(TEST_FILE, "r", encoding="utf-8") as fh:
        source = fh.read()

    runtime = lupa.LuaRuntime(unpack_returned_tuples=True)
    os.chdir(ROOT)
    try:
        runtime.execute(source)
    except lupa.LuaError as exc:
        print(exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
