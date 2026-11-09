# OptiShade launcher

Signed launcher channel used by the OptiShade installer and by installed launchers for self-update. [`channel.json`](channel.json) is signed; the installer and launcher verify its signature, the file size and SHA-256 before using `launcher/<version>/OptiShade.exe`.

Install OptiShade with the OptiShade installer. The launcher only opens after the installer has set it up.
