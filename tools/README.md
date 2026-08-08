# Our own dumper tools

Seven tools written from scratch. No DumprX, no magiskboot, no payload-dumper-go.
Each one is a separate file on purpose, so a single broken stage can be fixed
without touching anything else.

| # | File | What it does | Why we wrote our own |
| --- | --- | --- | --- |
| 01 | `01_fetch.sh` | Downloads the OTA with 16 connections, then proves it is a real FULL A/B OTA before anything else runs | old runs wasted 40 minutes before discovering a bad link |
| 02 | `02_payload_extract.py` | Pure-python `payload.bin` extractor. Reads the payload in place out of a STORED zip, so there is no 8 GB copy | payload-dumper-go was banned, and DumprX deleted the images afterwards |
| 03 | `03_bootimg_unpack.py` | Pure-python `ANDROID!` v0-v4 and `VNDRBOOT` v3/v4 parser, including the v4 vendor-ramdisk table | magiskboot died with `Illegal instruction (core dumped)` on this device |
| 04 | `04_ramdisk_extract.sh` | Turns any ramdisk into real files: lz4_legacy, lz4, gzip, xz, zstd, lzma, bzip2, raw cpio | MTK ships lz4_legacy, most scripts only try gzip |
| 05 | `05_unpack_fs.sh` | Routes each image by magic bytes: sparse, EROFS, ext4, f2fs, with real fallbacks | avoids the fake `7z failed` spam and keeps the raw image when extraction is impossible |
| 06 | `06_dump_meta.sh` | `all_files.txt`, `board-info.txt`, `proprietary-files.txt`, `README.md`, kernel version and kernel config | the device uses Transsion MSSI props, so twrpdtgen crashed on `ro.product.system.device` |
| 07 | `07_gitlab_push.sh` | Resumable per-partition commit and push, deletes the working copy after each group so the disk never fills | the old pipeline never finished, and a dead job lost everything |

## Glue (`lib/`)

| File | What it does |
| --- | --- |
| `lib/preflight.sh` | refuses to start unless `GITLAB_TOKEN` actually works |
| `lib/env_setup.sh` | frees the runner disk and picks the biggest volume as workspace |
| `lib/install_deps.sh` | installs every extractor and prints exactly what is present or missing |
| `lib/selfcheck.sh` | `bash -n` and `py_compile` on every tool before the 8 GB job starts |
| `lib/boot_stage.sh` | drives TOOL 03 then TOOL 04 across all boot images, and prints the recovery evidence |
| `lib/fs_stage.sh` | magic-byte routing, then TOOL 05 per filesystem image |
| `lib/gitlab_project.sh` | creates or reuses the GitLab project |
| `lib/summary.sh` | writes an honest job summary even when the job failed |

## Install the workflow (one move, no copy/paste)

`tools/dump.yml` is the workflow. A GitHub integration is not allowed to write
inside `.github/workflows/`, so it was parked here. To activate it:

1. Open `tools/dump.yml` on GitHub and click the pencil (Edit).
2. In the filename box at the top, replace the name with
   `../.github/workflows/dump.yml`
3. Commit changes.

## One-time setup

1. Create a GitLab personal access token with scopes `api` and `write_repository`.
2. Add it as a repository secret named `GITLAB_TOKEN`
   (Settings -> Secrets and variables -> Actions -> New repository secret).
3. Actions tab -> **Android Full Dump (our own tools) -> GitLab** -> Run workflow.

Leave `GITLAB_GROUP` empty to dump into your personal GitLab namespace.

## Resume model

TOOL 07 pushes in this order, one commit and one push per group:

`meta` -> `boot` -> `images` -> `dlkm` -> `product` -> `odm` -> `system_ext` -> `vendor` -> `system` -> `tr_*` -> `rest`

Every finished group is appended to `dump_state.txt`, which is committed with the
group itself. If the job dies, re-running the workflow on the same branch clones
that state back, skips everything already on GitLab, and continues from where it
stopped. Only `RESET_BRANCH=true` starts over.
