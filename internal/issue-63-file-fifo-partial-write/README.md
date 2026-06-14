# Internal evidence bundle: ALSA lib issue #63 - 2026-06-14

Branch: `internal/alsa-63-file-fifo-partial-write`

Upstream repo: `alsa-project/alsa-lib`

Fork remote: `origin` = `https://github.com/orange-dot/alsa-lib.git`

Context:
- User wants to continue ALSA contributions after PR #511.
- Work should target issue #452 first, then #63.
- This internal branch intentionally carries private/local evidence and repro
  helpers alongside the source fix. Before an upstream PR, either clean this
  branch or create a PR branch/cherry-pick with only upstream-appropriate files.

Bundle files:
- `README.md`: curation notes, repro notes, and validation record.
- `repro_fifo_file_pcm.sh`: software-only FIFO/regular-file comparator.
- `repro_issue63_ag03.sh`: Yamaha AG06/AG03 hardware-oriented issue topology reproducer.
- `pcm_write_finite.c`: finite PCM writer used by the repro scripts.
- `partial_write_preload.c`: `LD_PRELOAD` shim that forces short `write(2)` results.

## Selected targets

### #452 - test suite build fails with GCC 15 warnings

URL: https://github.com/alsa-project/alsa-lib/issues/452

Why it is a good first target:
- No hardware dependency.
- No open comment trail or competing PR observed during curation.
- Likely small, reviewable C/test-suite cleanup.
- Fits a maintainer-friendly PR: reproduce on current master, patch warning failures, add only necessary test/build changes.

Initial checks:
- Reproduce on current upstream `master`.
- Prefer the repo's existing autotools flow.
- Look for `-Wincompatible-pointer-types` and `-Wold-style-definition` in test build output.
- Confirm whether GCC 15 still fails on current master before patching.

2026-06-14 result:
- Current upstream `master` at `f453d783336167ee2714573f4352a72e3ce65094` does not reproduce the reported failure.
- Compiler used: `gcc (GCC) 16.1.1 20260515 (Red Hat 16.1.1-2)`.
- Normal out-of-tree validation in `/tmp/alsa-452-build`:
  - `env CCACHE_DISABLE=1 <repo>/configure --disable-aload --prefix=/tmp/alsa-452-install`
  - `env CCACHE_DISABLE=1 make -j4`
  - `env CCACHE_DISABLE=1 make check -k`
  - Result: success; `test/playmidi1` built and linked.
- Strict warning validation in `/tmp/alsa-452-strict-build-20260614b`:
  - `env CCACHE_DISABLE=1 CFLAGS='-O2 -Werror=incompatible-pointer-types -Werror=old-style-definition' <repo>/configure --disable-aload --prefix=/tmp/alsa-452-strict-install`
  - `env CCACHE_DISABLE=1 make -j4`
  - `env CCACHE_DISABLE=1 make check -k`
  - Result: success; `test/playmidi1` built and linked under the targeted `-Werror` flags.
- Current `test/midifile.h` and `test/midifile.c` already have typed callback/function prototypes for the areas shown in #452.
- Conclusion: no patch needed for #452 on current master; the useful contribution is likely an issue comment noting that master already passes, if the maintainer wants closure evidence.

### #63 - file plugin drops data when writing to FIFO

URL: https://github.com/alsa-project/alsa-lib/issues/63

Why it is worth doing:
- Labeled `bug` and `help wanted`.
- Multiple affected users.
- Perex noted in 2020 that there was no proper fix yet.
- It can likely be attacked with a local FIFO reproducer, then a focused plugin fix.

Risk:
- Older issue and may need careful reproduction against current master.
- Higher complexity than #452 because it involves PCM plugin behavior and FIFO write semantics.

Initial checks:
- Reproduce with a minimal `asound.conf` using the `file` plugin and a FIFO.
- Compare FIFO output length/content against normal file output.
- Inspect `src/pcm/pcm_file.c` write/error handling.
- Try to turn the reproducer into a small regression test or at least a deterministic local validation script.

2026-06-14 result:
- Created local run helpers:
  - `internal/issue-63-file-fifo-partial-write/repro_fifo_file_pcm.sh`
  - `internal/issue-63-file-fifo-partial-write/repro_issue63_ag03.sh`
  - `internal/issue-63-file-fifo-partial-write/pcm_write_finite.c`
  - `internal/issue-63-file-fifo-partial-write/partial_write_preload.c`
- Simple current-master FIFO checks were byte-perfect:
  - `case=direct regular_bytes=262144 fifo_bytes=262144`
  - `case=rate regular_bytes=481646 fifo_bytes=481646`
  - `case=tee regular_bytes=262144 fifo_bytes=262144`
- Finite 4-channel writer checks were also byte-perfect for direct/rate/tee:
  - `case=direct regular_bytes=2097152 fifo_bytes=2097152`
  - `case=rate regular_bytes=1926584 fifo_bytes=1926584`
  - `case=tee regular_bytes=2097152 fifo_bytes=2097152`
- A local `route -> multi -> rate -> file` shape timed out before producing a regular-file baseline with the synthetic helper, so it was not used as #63 proof.
- The actionable bug was reproduced deterministically with `LD_PRELOAD=/tmp/alsa_partial_write_preload.so PARTIAL_WRITE_LIMIT=4096`, forcing partial `write()` results:
  - Before patch: `snd_pcm_file_drain` aborted at `src/pcm/pcm_file.c:554` with `Assertion file->wbuf_used_bytes == 0 failed`.
  - After patch: the same forced-partial direct/rate/tee run completed byte-perfect:
    - `case=direct regular_bytes=524288 fifo_bytes=524288`
    - `case=rate regular_bytes=481644 fifo_bytes=481644`
    - `case=tee regular_bytes=524288 fifo_bytes=524288`
- Hardware-oriented reproduction with Yamaha AG06/AG03:
  - Host ALSA card: `AG06AG03`, playback device `hw:AG06AG03,0`.
  - AG03 advertises `S32_LE`, 2 channels, rates `[44100 192000]`; the issue's `type hw` path does not accept the helper's default `S16_LE`.
  - Local script: `internal/issue-63-file-fifo-partial-write/repro_issue63_ag03.sh`.
  - Exact issue topology with `hiface` remapped to `card "AG06AG03"`, using hardware-compatible writer settings `PCM_FORMAT=S32_LE WRITER_CHANNELS=4`:
    - `pcm.vumeter` path on unpatched master: `regular_bytes=32768`, `fifo_bytes=32768`.
    - `pcm.alsaFifoTee` path on unpatched master: `regular_bytes=65536`, `fifo_bytes=65536`.
  - Conclusion: the AG03 run does not naturally reproduce byte loss on current unpatched master with a normal FIFO reader.
  - Forced partial-write AG03 run with unpatched master:
    - `LD_PRELOAD=/tmp/alsa_partial_write_preload.so PARTIAL_WRITE_LIMIT=4096 PCM_FORMAT=S32_LE WRITER_CHANNELS=4 B_PCM=vumeter bash internal/issue-63-file-fifo-partial-write/repro_issue63_ag03.sh`
    - Result: abort at `/tmp/alsa-lib-master-f453d/src/pcm/pcm_file.c:554`, `Assertion file->wbuf_used_bytes == 0 failed`.
  - Same forced partial-write AG03 run with patched build:
    - `LD_PRELOAD=/tmp/alsa_partial_write_preload.so PARTIAL_WRITE_LIMIT=4096 BUILD_DIR=/tmp/alsa-452-build PCM_WRITER=/tmp/alsa_pcm_write_finite_patched PCM_FORMAT=S32_LE WRITER_CHANNELS=4 B_PCM=vumeter bash internal/issue-63-file-fifo-partial-write/repro_issue63_ag03.sh`
    - Result: `regular_bytes=32768`, `fifo_bytes=32768`.
- Patch branch in ALSA checkout: `internal/alsa-63-file-fifo-partial-write`.
- Patch scope: `src/pcm/pcm_file.c` now continues the write loop after partial writes and treats zero-byte writes as `-EIO` to avoid an infinite loop.
- Validation after patch:
  - `/tmp/alsa-452-build`: `env CCACHE_DISABLE=1 make -j4`
  - `/tmp/alsa-452-build`: `env CCACHE_DISABLE=1 make check -k`
  - `/tmp/alsa-452-strict-build-20260614b`: `env CCACHE_DISABLE=1 make -j4`
  - `/tmp/alsa-452-strict-build-20260614b`: `env CCACHE_DISABLE=1 make check -k`
  - `git diff --check`

## Deferred / avoid for now

- #456: already covered by PR #511.
- #507: has maintainer guidance and related PR #508.
- #502, #503: likely cross-stack or hardware/boot-race heavy.
- #377: interesting API design, but larger scope.
- #402, #472: likely hardware/driver/clocking dependent.

## Local checkout notes

Observed before syncing:
- Current branch: `fix-snd-config-imul`
- `origin`: `https://github.com/orange-dot/alsa-lib.git`
- `upstream`: `https://github.com/alsa-project/alsa-lib.git`
- Active work belongs under `workspace/`.

Sync result:
- Fetched `upstream master` on 2026-06-14.
- Fast-forwarded local `master` from `96f23dda144e1f2b3f192022edc191af3c389243` to `f453d783336167ee2714573f4352a72e3ce65094`.
- Left `fix-snd-config-imul` untouched for PR #511.
