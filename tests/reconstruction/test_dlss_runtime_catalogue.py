#!/usr/bin/env python3
"""Guard the split NVIDIA runtime pins and the version-qualified MFG stack."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
installer = ROOT / "Beta/installer"
files = {item["Name"]: item for item in json.loads((installer / "nvidia-files.json").read_text(encoding="utf-8-sig"))}
expected = {
    "nvngx_dlssg.dll": ("310.9.16.0", "v310.9.16", "8D59D49B36410DD6B62FEF2503A5871D347415BD85D943FA0848563A95DD50C7"),
}
assert set(files) == set(expected), f"Unexpected NVIDIA runtime set: {sorted(files)}"
for name, (version, tag, digest) in expected.items():
    actual = files[name]
    assert (actual["Version"], actual["SourceTag"], actual["SHA256"]) == (version, tag, digest), name

streamline = json.loads((installer / "streamline-files.json").read_text(encoding="utf-8-sig"))
assert streamline["version"] == "2.14.16", "The managed Streamline stack must track the current official release"
assert streamline["archiveSha256"] == "32041E51DB0CAB709A271B72A352281B690C2ABBD669A827809401A5DD23956B"
assert all(item.get("version") == ("310.9.16.0" if item["name"] == "nvngx_dlssg.dll" else "2.14.16.0") for item in streamline["files"] if item["name"].endswith(".dll"))
sl_version = (ROOT / "Beta/optiscaler/external/streamline/sl_version.h").read_text(encoding="utf-8")
assert "#define SL_VERSION_MINOR 14" in sl_version and "#define SL_VERSION_PATCH 16" in sl_version, "OptiScaler Streamline headers and runtime must share the candidate SDK version"
profiles = json.loads((installer / "nvidia-runtime-profiles.json").read_text(encoding="utf-8-sig"))
assert profiles["default"] == "nvidia-310.9.16"
assert [item["id"] for item in profiles["profiles"]] == ["nvidia-310.9.16"], "Only the current qualified DLSS SR/RR runtime should ship"
assert not (set(files) & set(profiles["scope"])), "SR/RR pins must not be duplicated in the base NVIDIA catalogue"
assert "nvidia-310.9.1'" in (installer / "nvidia.ps1").read_text(encoding="utf-8-sig"), "legacy profile IDs must migrate forward"
assert "nvidia-310.7.0'" in (installer / "nvidia.ps1").read_text(encoding="utf-8-sig"), "legacy profile IDs must migrate forward"

script = (installer / "nvidia.ps1").read_text(encoding="utf-8-sig")
assert "$($file.SourceTag)" in script and "$file.Version" in script
assert "TestNvidiaFileVersion (Get-Item -LiteralPath $dest).VersionInfo" in script
assert "FileMajorPart,$VersionInfo.FileMinorPart,$VersionInfo.FileBuildPart,$VersionInfo.FilePrivatePart" in script
assert ".VersionInfo.FileVersion -cne [string]$file.Version" not in script
assert "InstalledDLSSSR=$sr.Version" in script and "InstalledDLSSRR=$rr.Version" in script and "InstalledDLSSG=$fg.Version" in script
compatibility = (installer / "compatibility.ps1").read_text(encoding="utf-8-sig")
assert "DLSS SR/RR 310.9.16 with Streamline 2.14.16" in compatibility
provider_policy = (ROOT / "Beta/optiscaler/external/RTX40MFG-Unlock/source/native/dlssg_provider_policy.h").read_text(encoding="utf-8")
assert "{310, 9, 16}" in provider_policy and "IsSupportedVersion({310, 9, 16})" in provider_policy
policy = (ROOT / "Beta/optiscaler/docs/DLSS-RUNTIME-POLICY.md").read_text(encoding="utf-8")
assert "No release, tag or upload has been created." in policy
loader = (ROOT / "Beta/optiscaler/OptiScaler/hooks/LibraryLoad_Hooks.cpp").read_text(encoding="utf-8")
assert "State::Instance().NVNGX_DLSS_Path.has_value()" in loader, "automatic managed DLSS runtime must enter the DLL selection hook"
assert "LoadNvngxDlss(requestedPath)" in loader, "the resolved game request must remain the final compatibility fallback"
assert "optishade::dlssruntime::Candidates(" in loader, "DLSS load order must be centralized and covered by native policy tests"
assert 'LOG_INFO("nvngx_dlss.dll loaded from {0}"' in loader, "runtime log must name the DLL that actually loaded"
print("Latest checked DLSS SR/RR and Streamline/DLSS-G test-candidate pins passed.")
