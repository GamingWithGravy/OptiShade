# OptiShade Core 1.0.78

Signed OptiShade Core package for the OptiShade launcher. The launcher reads [`channel.json`](channel.json), checks its signature, then downloads and verifies `packages/OptiShade.Core-1.0.78.tar.gz` and every file in it before installing.

Changes in 1.0.78:
- Image effects: each effect file is loaded once. Duplicate copies of the same effect (for example LumaSharpen or the PD80 effects) no longer make a look show as "ambiguous" or apply twice.
- Fixes a freeze during play caused by an image-effects crash when the game used graphics resources the effects layer had not seen.
- Fixes a freeze after the graphics device was lost: effects pause for that frame instead of crashing.
- VR: on graphics cards with 12 GB or less, the headset starts with its own light look; headset effects pause for the session if video memory runs out.

`packages/OptiShade.Core-source.tar.gz` is the corresponding source for the GPL-covered OptiScaler-derived portions. The launcher and installer are not included here.
