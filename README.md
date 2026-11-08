# OptiMFG — download channel

This branch currently hosts **download-only candidates** for transport testing. They are not installable releases and must not be applied to a game.

`download-test.json` provides exact byte lengths and SHA-256 hashes for the runtime archive and matching source archive. Both are fetched into a local cache by the OptiShade Download Test utility. The source archive contains the pinned source build tree and build provenance; all bundled notices remain authoritative.

The candidate is built from OptiShade `1.0.77`, Rebuild R370, source commit `e94315a6387c26c9731dea0ef5d3509fc48892ad`. No launcher or installer is included.
