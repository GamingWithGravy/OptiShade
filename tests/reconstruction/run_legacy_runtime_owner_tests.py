"""Exercise the production legacy runtime registry and discovery callbacks.

Only the ReShade/Win32 event surface is replaced. The registration, capacity,
candidate and adoption decisions below are extracted unchanged from the client.
This is a CPU ownership regression, not graphics or game qualification.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


def extract(source: str, first: str, following: str) -> str:
    if source.count(first) != 1 or source.count(following) != 1:
        raise SystemExit("Legacy runtime extraction boundary changed: " + first)
    start = source.index(first)
    return source[start:source.index(following, start)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--compiler", default="g++")
    args = parser.parse_args()
    root = args.root.resolve()
    source = (root / "Beta/legacy-nr/upstream/src/dlss5-feed32.cpp").read_text()
    registry = extract(source, "struct RuntimeSlot\n{", "\nstatic void PollLegacyPreparation(reshade::api::effect_runtime* rt){")
    init = extract(source, "static void OnInitEffectRuntime(reshade::api::effect_runtime *rt)\n{", "\nstatic void OnDestroyEffectRuntime(reshade::api::effect_runtime *rt)\n{")
    reload = extract(source, "static void OnReloadedEffects(reshade::api::effect_runtime *rt)\n{", "\nstatic void OnRenderTechnique(reshade::api::effect_runtime *rt, reshade::api::effect_technique technique,")
    fixture = (root / "tests/reconstruction/legacy_runtime_owner_tests.cpp").read_text()
    if fixture.count("// PRODUCTION_RUNTIME_OWNER") != 1:
        raise SystemExit("Legacy runtime fixture insertion point changed")
    generated = fixture.replace("// PRODUCTION_RUNTIME_OWNER", registry + init + reload)
    with tempfile.TemporaryDirectory(prefix="optishade-legacy-runtime-") as temporary:
        work = Path(temporary)
        cpp = work / "legacy_runtime_owner.cpp"
        cpp.write_text(generated)
        msvc = Path(args.compiler).name.lower() in ("cl", "cl.exe")
        binary = work / ("legacy_runtime_owner.exe" if msvc else "legacy_runtime_owner")
        if msvc:
            command = [args.compiler, "/nologo", "/EHsc", "/std:c++20", str(cpp), "/Fe:" + str(binary)]
        else:
            command = [args.compiler, "-std=c++20", "-O0", "-Wall", "-Wextra", str(cpp), "-o", str(binary)]
        subprocess.run(command, cwd=work, check=True)
        subprocess.run([str(binary)], cwd=work, check=True)


if __name__ == "__main__":
    main()
