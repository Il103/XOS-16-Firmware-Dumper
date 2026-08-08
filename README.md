# Android Full Dump - our own tools

No DumprX. No magiskboot. No payload-dumper-go. No Crave.
Seven tools written from scratch, running on plain GitHub Actions (`ubuntu-latest`),
pushing the dump to GitLab **one partition group at a time** so a dead runner never
costs you the whole run.

## The seven tools

| # | File | What it does |
|---|------|--------------|
| 01 | `01_fetch.sh` | `aria2c` download, 16 connections. Verifies size, zip integrity, presence of `payload.bin`, and that the OTA is FULL and not incremental. Fails in the first minute instead of after two hours. |
| 02 | `02_payload_extract.py` | Our own `payload.bin` extractor. Minimal protobuf reader, no third-party libs. Supports `REPLACE`, `REPLACE_BZ`, `REPLACE_XZ`, `ZERO`, `DISCARD`. Reads the payload **in place inside the zip** (no 8 GB copy) and writes `ZERO` extents as sparse holes. |
| 03 | `03_bootimg_unpack.py` | Pure-Python reader for `boot` / `init_boot` / `vendor_boot`. `ANDROID!` v0-v4 and `VNDRBOOT` v3/v4, **including the v4 vendor ramdisk fragment table**, so `ramdisk` and `recovery_ramdisk` come out separately. This is exactly where magiskboot died with `Illegal instruction (core dumped)`. |
| 04 | `04_ramdisk_extract.sh` | Any compressed ramdisk to real files: `lz4_legacy` (MediaTek), `lz4`, `gzip`, `xz`, `zstd`, `lzma`, `bzip2`, and raw cpio. |
| 05 | `05_unpack_fs.sh` | Detects the filesystem from **magic bytes**, not from the filename: sparse -> `simg2img`, EROFS -> `fsck.erofs`, ext4/f2fs -> mount or `debugfs`, `7z` only as a last resort. On failure it keeps the raw image so nothing is ever lost. |
| 06 | `06_dump_meta.sh` | Makes the tree look like a real dump: `all_files.txt`, `board-info.txt`, `README.md` with a size table, `proprietary-files.txt`, and `kernel_config.txt` recovered from the `IKCFG_ST` blob inside the kernel. |
| 07 | `07_gitlab_push.sh` | The resumable uploader. Per group: `git add` -> commit -> push -> drop the files from the working copy -> clear the LFS cache -> read real project size from the GitLab API. |

## Glue (`lib/`)

Every workflow step is its own script. The YAML contains no heredocs at all.

| Script | Step |
|--------|------|
| `lib/preflight.sh` | Validates `GITLAB_TOKEN`, resolves the GitLab account, prints the locked device identity |
| `lib/env_setup.sh` | Frees disk, picks the biggest volume as `$WORK`, exports `$DL` `$RAW` `$DUMP` `$TOOLS` |
| `lib/install_deps.sh` | `aria2`, `erofs-utils`, `android-sdk-libsparse-utils`, `lz4`, `zstd`, `git-lfs`, ... |
| `lib/selfcheck.sh` | `bash -n` + `py_compile` on every tool, and `chmod +x`, **before** downloading 8 GB |
| `lib/boot_stage.sh` | Runs TOOL 03 then TOOL 04 over every boot-ish image |
| `lib/fs_stage.sh` | Magic-byte routing into TOOL 05; keeps boot-ish images raw at the dump root |
| `lib/gitlab_project.sh` | Creates or reuses the GitLab project, exports slug / id / url |
| `lib/summary.sh` | Honest job summary, runs with `if: always()` |

## Resume model - the whole point

Upload order is deliberate: small and important first, the monsters last.

```
meta -> boot -> images -> dlkm -> product -> odm -> system_ext -> vendor -> system -> tr_* -> rest
```

1. When a group finishes, its name is appended to `dump_state.txt` and pushed **in the same commit as the group itself**.
2. If the job dies at any point, everything already pushed is on GitLab for good.
3. Re-run the workflow: it does `git clone --filter=blob:none --depth=1` of the branch, reads `dump_state.txt`, skips finished groups, and continues where it stopped.
4. No `--force`, no history rewriting. To start over on purpose, set `RESET_BRANCH = true`.

`recovery_ramdisk` lands in the `boot` group, the **second** thing pushed. Even if the
runner dies after 40 minutes, the recovery tree source is already in your hands.

## One-time setup

1. **Move this workflow into place.** GitHub blocks integrations from writing to
   `.github/workflows/`, so the file ships here as `tools/dump.yml`. Open it, click the
   pencil, change the filename field to `../.github/workflows/dump.yml`, commit. No copy-paste.
2. **Add the GitLab token.** On gitlab.com create a personal access token with scopes
   `api` and `write_repository`. Then in this repo:
   Settings -> Secrets and variables -> Actions -> New repository secret, named exactly `GITLAB_TOKEN`.
3. **Run it.** Actions -> "Android Full Dump (our own tools) -> GitLab" -> Run workflow.
   Leave `GITLAB_GROUP` empty to use your personal namespace.

## Things worth knowing

- **Huge raw filesystem images are not pushed by default, and that is correct.** No normal
  dump stores `system.img` or `vendor.img`; the extracted tree *is* the content. The root keeps
  the small important images: boot, dtbo, vbmeta, and the MTK firmware blobs. Result is roughly
  6-8 GB instead of 26. Set `KEEP_BIG_IMAGES = true` if you really want them, but you will hit
  the GitLab 10 GiB project cap.
- **GitLab cap is 10 GiB per project.** TOOL 07 reads the real size from the API after every
  push and warns at 9 GiB. If a push is refused for space, the log names the exact group that
  stopped and confirms everything before it is safe.
- **Timing.** `timeout-minutes: 350`. Download ~10 min, payload ~20-30, filesystems ~30-45,
  upload ~60-90. Around 2.5-3 hours. If the timeout hits, re-run and it resumes.
- **`boot.img` has no ramdisk on this device and that is normal.** It is GKI (`RAMDISK_SZ 0`);
  the real ramdisk lives in `vendor_boot`. The tool says so plainly instead of calling it a failure.
- **Nothing fails silently.** If a partition cannot be unpacked, the raw image stays in the dump
  and the step emits a `::warning::`.

## Dump layout

```
android_dump_infinix_x6886/
  all_files.txt  board-info.txt  README.md  proprietary-files.txt
  kernel_config.txt  kernel_version.txt  dump_state.txt  ota_metadata.txt
  boot.img  init_boot.img  vendor_boot.img  dtbo.img  vbmeta*.img
  md1img.img  lk.img  preloader_raw.img  ...
  boot/            kernel  dtb  header_info.json  ramdisk/
  vendor_boot/     dtb  bootconfig  header_info.json  ramdisk/  recovery_ramdisk/
  system/  system_ext/  vendor/  product/  odm/
  vendor_dlkm/  odm_dlkm/  system_dlkm/
  tr_*/
```
