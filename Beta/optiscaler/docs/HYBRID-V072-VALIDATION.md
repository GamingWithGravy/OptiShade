# BG3 two-minute model comparison — 2026-09-09

Each model was captured for 120 seconds. The first 20 seconds were discarded, leaving approximately 100 seconds per model. Capture order: candidate, FP8, existing hybrid.

| Model | Rendered average FPS | Rendered 1% low FPS | FG output average FPS |
|---|---:|---:|---:|
| FP8 | 54.57 | 44.35 | 109.14 |
| Existing hybrid | 54.91 | 44.59 | 109.83 |
| Candidate | 55.16 | 43.93 | 110.32 |

Candidate rendered average was 0.45% higher than existing hybrid and 1.08% higher than FP8. Its 1% low was slightly lower than both. These are single sequential runs; the small differences are not established repeatable gains.

Scene: unchanged close-up Custom High Elf Level 1 Wizard (Sage) character creation scene. BG3 DX11, PID 41168, RTX 5090, 3840x2160 output. Neural Rendering enabled and applied before Super Resolution, two model passes, 100% model resolution, Hybrid proxy + composed, detail 1.14, colour 0.98, compare and debug view off, 119 FPS limit.

PresentMon streams were analyzed separately: 0x2A122317160 (Composed: Flip) is inferred to be the source/render stream; 0x2A1246F9E60 (Hardware: Independent Flip), with approximately twice its rate, is inferred to be the FG output. Streams were never summed. FG output is a presentation rate, not a verified display pacing measurement; no output 1% low is reported because its events are batched.

Average FPS = 1000 / mean consecutive retained event intervals in milliseconds. Rendered 1% low = 1000 / mean of the slowest ceil(1% of retained intervals). Only events from capture-relative seconds 20 through 120 were retained; no interval crosses the discarded warm-up boundary. These measure whole-game performance, not isolated model execution time.

Raw captures: candidate.csv, fp8.csv, hybrid.csv. Analysis: analyze.py and summary.json (including SHA-256 hashes and retained spans). The earlier candidate-scene-changed-excluded.csv is excluded. Earlier 20s and 60s benchmarks used different scenes/settings and are not pooled here.

Candidate selection was verified after testing. Overlay closure could not be verified because the UI runtime stopped responding.
