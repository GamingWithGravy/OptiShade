# TAA neural rendering - Coming soon (INOP)

The TAA experiment did not work in the MSFS test and is disabled in 0.19.19.
The menu displays a disabled Coming soon (INOP) option. Saved TaaFallback=true
settings are ignored and saved as false. The runtime transport refuses requests
and cannot submit TAA neural work, including from older shaders or settings.

The research source and attributed guide assets remain for future development.
Do not enable OptiShade_TAA_Guides: it cannot activate neural rendering in this
release and generating unused guide textures costs GPU time.

Image effects remain separate from Performance. Normal game TAA can still be
used for image effects; this restriction concerns neural rendering with TAA.

Third-party notices are in
installer/DefaultEffects/Licenses/OptiShade-TAA-THIRD-PARTY.txt.
