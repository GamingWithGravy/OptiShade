"""Exercise exact legacy preparation owners with bounded Win32 handle seams."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def extract(source: str, first: str, following: str) -> str:
    if source.count(first) != 1 or source.count(following) != 1:
        raise SystemExit("Legacy lifetime extraction boundary changed: " + first)
    start = source.index(first)
    finish = source.index(following, start)
    return source[start:finish]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--compiler", default="g++")
    args = parser.parse_args()
    root = args.root.resolve()
    source = (root / "Beta/legacy-nr/upstream/src/dlss5-feed32.cpp").read_text()
    join = extract(source, "static void HostLinkJoin()\n{", "\n// Returns true when the worker is definitely")
    owners = extract(source, "static bool RetirePreparedLink()\n{", "\n// The build exchange, from the render thread's side.")
    if owners.count("static bool HostConnectReady(bool activate=true)") != 1:
        raise SystemExit("The production connection owner is missing or ambiguous")
    poll = extract(source, "static void PollLegacyPreparation(reshade::api::effect_runtime* rt){", "\nstatic void ApplySessionIntent(reshade::api::effect_runtime* rt){")
    fixture = (root / "tests/reconstruction/legacy_preparation_lifetime_tests.cpp").read_text()
    if fixture.count("// PRODUCTION_LIFETIME_FUNCTIONS") != 1:
        raise SystemExit("Legacy lifetime fixture insertion point changed")
    generated = fixture.replace("// PRODUCTION_LIFETIME_FUNCTIONS", join + owners + poll)
    with tempfile.TemporaryDirectory(prefix="optishade-legacy-lifetime-") as temporary:
        work = Path(temporary)
        cpp = work / "legacy_preparation_lifetime.cpp"
        cpp.write_text(generated)
        msvc = Path(args.compiler).name.lower() in ("cl", "cl.exe")
        binary = work / ("legacy_preparation_lifetime.exe" if msvc else "legacy_preparation_lifetime")
        includes = [root / "Beta/shared", root / "Beta/legacy-nr/upstream/src"]
        if msvc:
            command = [args.compiler, "/nologo", "/EHsc", "/std:c++20", *["/I" + str(p) for p in includes], str(cpp), "/Fe:" + str(binary)]
        else:
            command = [args.compiler, "-std=c++20", "-O0", "-Wall", "-Wextra", "-pthread", *["-I" + str(p) for p in includes], str(cpp), "-o", str(binary)]
        subprocess.run(command, cwd=work, check=True)
        subprocess.run([str(binary)], cwd=work, check=True)


if __name__ == "__main__":
    main()
