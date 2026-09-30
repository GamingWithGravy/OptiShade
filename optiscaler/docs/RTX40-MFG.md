# Optional RTXMFG integration

OptiShade integrates [Universal RTXMFG](https://github.com/dashdogy/RTX40MFG-Unlock),
MIT-licensed work by Michael Robles / dashdogy. The maintained component is the
single-DLL v1.3.3-hotfix.2 release, pinned to source commit
`53e3311157140df7b72a6cf0c76fb4e93c44fc04`. The old split Core/ASI/ReShade panel
instructions do not describe this component. See the installer component's
`PROVENANCE.md` and unchanged upstream README/build/licence files for its origin.

## Installation and hardware scope

Automatic setup is restricted to MSFS 2020/2024 and a single detected NVIDIA
RTX 40 GPU. It installs one verified `version.dll` only when there is no foreign
loader conflict. An integrated AMD companion GPU is allowed. The game must
already support a compatible Streamline/DLSS Frame Generation pipeline and load
the proxy early. Do not replace working game/runtime DLLs with another game's
Streamline files.

The first optional installation selects `[FrameGen] External=true` and disables
OptiShade's competing Ada/Ampere unlock overrides. Repeated verified setup and
repair of a missing owned DLL preserve the user's later frame-generation
choices. Changing backend ownership is a startup operation; a restart is needed.

Upstream supports RTX 40 and very early experimental RTX 30 D3D12 paths. The
latter depends on validated native caches and provider contracts and is not
validated or automatically deployed by OptiShade. RTX 20 is unsupported by this
optional backend. RTX 50 continues to use native frame-generation handling;
ordinary AMD image effects and supported performance paths are unchanged.
Requested or accepted settings are not proof of generated frames. Available
multipliers depend on the GPU, game/runtime and NVIDIA's per-game limits.

## Configuration and current preserved binary

The v1.3.3 backend consumes `RTXMFG-Universal.json` beside the actual game EXE.
`RTX_MFG_CONFIG_PATH`, when set, overrides that location. Preserve existing JSON
keys and user preferences; do not overwrite another override target. Backend
status and logs must be checked before reporting a setting as applied.

The current build retains the unmodified upstream DLL and its own
first-launch/Backspace menu. OptiShade also exposes supported settings under
Performance > Smoother motion, with verified loaded-backend status and protection
against conflicting frame-generation controls. Its original separate-menu
instructions remain accurate. This build does not claim that the upstream
menu/hotkey has been removed.

## Controls-only build held pending original inputs

The intended replacement exposes controls through OptiShade's Performance UI,
with no secondary menu and no replacement hotkey. The local source patch is
`installer/OptionalMFG/controls-only.patch` at the repository root. The guarded
`build-controls-only.ps1` recipe applies it to the exact pinned archive and uses
the supported `EnableOverlayMenuDraw=false` configuration. Unified GPU dispatch,
validated native caches and backend behavior are retained.

A complete DLL build is currently blocked by missing original upstream native
cache manifests/JSON contracts and matching kernel inputs, plus alignment of
the hash-pinned SDK/toolchain inputs. The recipe fails without those inputs;
it does not reconstruct contracts, bypass checks or force a GPU family.
Native source tests verify disabled binding/key consumption and the guarded
input/UI entry points. A rebuilt DLL still needs input-isolation and backend
regression checks, followed by appropriate hardware testing for rendering.

The future controls-only replacement must pass `verify-controls-only.ps1` with
a reviewed receipt matching the new DLL and patch. Compilation alone does not
create that approval receipt. The preserved official DLL is not a controls-only
build and is rejected by that check; current packaging retains its original
hash pin instead. All original licence,
copyright, attribution and third-party notices remain required for the modified
build; OptiShade claims only its integration changes.
