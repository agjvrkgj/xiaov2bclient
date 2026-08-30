# Third-party notices

## Mihomo

This project embeds or downloads **Mihomo v1.19.30** from the official
[MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) project.

- Copyright: Mihomo contributors
- License: GNU General Public License, version 3
- Exact upstream source: https://github.com/MetaCubeX/mihomo/tree/v1.19.30
- Release binaries: https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.30

The desktop artifacts are unmodified official release binaries whose SHA-256
digests are pinned in `tool/fetch_mihomo.py`. The Android library is built from
the tagged Go module with the `with_gvisor,cmfa` build tags and linked to the
JNI/VPNService bridge in this repository. The complete corresponding bridge and
build scripts are under `core/`, `android/core/`, and `tool/`.

This repository is distributed under GPL-3.0 so that the combined Android work
and redistributed desktop packages retain the freedoms required by Mihomo's
license. See `LICENSE` for the full terms.
