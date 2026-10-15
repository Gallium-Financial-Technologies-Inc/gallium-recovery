# Security

`gallium-recover.sh` reads two recovery packages that contain loan private keys. It uses those keys only to talk to Bitcoin Core on the machine where you run it. It does not phone home to Gallium.

## Verify before you run

Gallium pins one git commit and one SHA-256 checksum. Download that commit's `gallium-recover.sh` and compare it with the checksum printed in your recovery package. If they differ, stop.

The `main` branch moves. A download of `main` is not the pinned release.

## Reporting a vulnerability

Open a private security advisory on this GitHub repository. Do not open a public issue that includes a recovery package, a private key, or a recovery phrase.
