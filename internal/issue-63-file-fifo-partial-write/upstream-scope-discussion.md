# Internal scope decision: buffered PCM payload short writes

Branch: `internal/alsa-63-file-fifo-partial-write`

This note records the internal review discussion for the ALSA `pcm_file`
change. It is intentionally private-branch material: do not copy this file into
an upstream submission. The upstream patch should be source-only unless
maintainers ask for a regression harness.

## Decision

Use option A for the upstream-ready branch:

- keep the source change focused on buffered PCM payload writes;
- describe the target descriptors as the blocking file/pipe descriptors used by
  the plugin's normal output paths;
- do not claim general partial-write support for every `pcm_file` write path;
- leave caller-supplied nonblocking descriptors out of scope.

Do not implement option B or option C now. Both are policy changes for
caller-owned descriptors and should be driven by maintainer feedback, not hidden
inside this payload-write patch.

## Source Change Scope

The source change is in `snd_pcm_file_write_bytes()`.

The old loop treated a short positive `write(2)` as successful progress and
then stopped. That could leave `wbuf_used_bytes` nonzero. The observable
failure is an assertion in `snd_pcm_file_drain()`, `snd_pcm_file_drop()`, or
`snd_pcm_file_reset()` when those paths expect the buffered payload to be fully
flushed. In non-assert builds or under different timing, the same mechanism can
surface as incomplete output.

The new loop keeps flushing after each positive short write:

- `err > 0`: advance `bytes`, `wbuf_used_bytes`, `file_ptr_bytes`, and
  `filelen`, then continue until the requested payload is fully written;
- `err == 0`: return `-EIO` to avoid a no-progress infinite loop;
- `err < 0`: preserve the existing fatal output-error policy.

The ring-buffer wrap remains safe because each transfer is capped by:

```text
cont = wbuf_size_bytes - file_ptr_bytes
```

so `file_ptr_bytes += err` can reach the end exactly, but cannot skip past it.

## Deliberate Non-Claims

This is not a blanket statement that `pcm_file` handles all partial writes.

The WAV header path still uses one-shot `safe_write()` calls. The WAV length
rewrite path also writes 4-byte fields without retrying short positive writes.
Those paths are outside this patch because the observed payload loss/assert is
in the buffered PCM payload flush path.

The upstream wording should say "buffered PCM payload writes". It should not
say "all `pcm_file` partial writes".

## Caller-Supplied Nonblocking Descriptors

There are two ways for a caller-prepared descriptor to reach the plugin:

- C API: `snd_pcm_file_open(..., fd, ...)`;
- config: `file <int>`, because the parser first tries a string and then an
  integer descriptor for the `file` field.

That descriptor is stored as `file->fd`. Later, the delayed output open is
skipped when `file->fd >= 0`, so the descriptor reaches the payload-write loop
with whatever flags the caller set, including `O_NONBLOCK`.

The plugin-created output paths are different. They open regular files/FIFOs
without `O_NONBLOCK`, or use `popen(..., "w")`. Those are the normal blocking
output paths this change targets.

`safe_write()` retries `EINTR` and maps `EPIPE` to `-EIO`, but it does not have
`EAGAIN` retry/poll handling. Therefore a caller-supplied nonblocking pipe can
still fail after progress:

```text
pipe has 4096 bytes free, payload flush requests 8192 bytes

old behavior:
  write -> 4096
  buffer advances by 4096
  loop stops and returns success
  remaining 4096 bytes stay buffered for a later flush cycle

new behavior:
  write -> 4096
  buffer advances by 4096
  loop retries immediately
  write -> -EAGAIN
  existing fatal error path clears the remaining buffer and returns -EAGAIN
```

That is a real edge case, but it is not a supported nonblocking mode. The old
code also had no general `EAGAIN` recovery. The new change widens one failure
window for caller-owned nonblocking descriptors, while correcting the blocking
FIFO/pipe payload path used by the plugin's normal output modes.

## Why Not Force Or Reject Nonblocking FDs Now

Option A: narrow wording only.

This is the preferred path. It keeps the patch proportional to the observed
bug: blocking buffered PCM payload writes should continue after short positive
`write(2)` results.

Option B: force blocking with `fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)`.

Rejected for now. A `file <int>` or API descriptor is caller-owned. The close
path reinforces that ownership boundary: when there is no `fname`, the plugin
does not close the descriptor. Silently changing `O_NONBLOCK` would be a
stronger ownership claim than the close behavior makes. It would also mutate
the open file description, so the change is visible to `dup()` or fork-shared
users of the same open file description.

Option C: reject nonblocking descriptors during setup.

Also rejected for now. It is cleaner than silently changing flags, but it is
still a policy change for caller-owned descriptors and should be discussed
separately if maintainers want explicit nonblocking handling.

Do not add real nonblocking support in this patch. Poll-based retry and
preserving buffered remainder after `EAGAIN` are a larger design change, and
would interact with drain/drop/reset assumptions.

## Upstream Commit Message Draft

```text
pcm_file: continue flushing buffered payload after short writes

A short positive write(2) on the output descriptor advanced the buffer
only partially but the flush loop returned success, leaving
wbuf_used_bytes non-zero. In builds with assertions enabled this trips
assert(file->wbuf_used_bytes == 0) in snd_pcm_file_drain(),
snd_pcm_file_drop(), or snd_pcm_file_reset(); otherwise the unflushed
remainder can be lost as incomplete output.

Continue flushing until all requested payload bytes are written, and treat
a zero-byte write as -EIO to avoid an infinite loop.

This is scoped to the blocking file/pipe descriptors used by the file
plugin's normal output paths, such as regular files, FIFOs, and popen.
It does not add support for caller-supplied non-blocking descriptors,
which have no EAGAIN retry/poll handling in pcm_file and remain out of
scope.
```

## Rust/AIG Lab Evidence

External lab source, not vendored into ALSA:

```text
workspace/systems/aig-adg-lab/binaries/aig-adg-lab-alsa-fifo-repro
workspace/systems/aig-adg-lab/crates/aig-adg-lab-audio/src/fifo_repro.rs
```

The Rust repro is a real-workflow-style check around an AIG-derived reference
WAV. It drives ALSA `aplay` through the `file` plugin twice:

- regular raw output baseline;
- FIFO raw output with a Rust VU-meter reader consuming the FIFO.

The run compares byte counts and FNV hashes for regular output versus FIFO
output, and records VU meter frames/levels from the FIFO reader.

### Patched ALSA, Normal FIFO

Command:

```text
cargo run --locked -p aig-adg-lab-alsa-fifo-repro -- \
  --alsa-lib-dir /tmp/alsa-452-build/src/.libs
```

Result:

```text
result=pass
format=S16_LE rate=48000 channels=1
regular_bytes=216000
fifo_bytes=216000
regular_hash=0xda3c449901876d40
fifo_hash=0xda3c449901876d40
vu_frames=108000
vu_peak_dbfs=-3.97
vu_rms_dbfs=-22.12
```

Artifacts:

```text
wav=/home/dev/work-base-20260421/workspace/systems/aig-adg-lab/target/aig-adg-lab-runs/aig_adg-lab/alsa-file-fifo-vu-repro/alsa-file-fifo-vu-repro.reference.wav
output_dir=/home/dev/work-base-20260421/workspace/systems/aig-adg-lab/target/aig-adg-lab-runs/alsa-file-fifo-vu-repro/run-1781477999670-2
regular_raw=/home/dev/work-base-20260421/workspace/systems/aig-adg-lab/target/aig-adg-lab-runs/alsa-file-fifo-vu-repro/run-1781477999670-2/regular.raw
fifo_raw=/home/dev/work-base-20260421/workspace/systems/aig-adg-lab/target/aig-adg-lab-runs/alsa-file-fifo-vu-repro/run-1781477999670-2/fifo.raw
vu_log=/home/dev/work-base-20260421/workspace/systems/aig-adg-lab/target/aig-adg-lab-runs/alsa-file-fifo-vu-repro/run-1781477999670-2/fifo-vu.log
```

### Patched ALSA, Forced FIFO Short Writes

Command:

```text
cargo run --locked -p aig-adg-lab-alsa-fifo-repro -- \
  --alsa-lib-dir /tmp/alsa-452-build/src/.libs \
  --preload /tmp/alsa_partial_write_preload.so \
  --partial-write-limit 4096 \
  --preload-fifo-only
```

Result:

```text
result=pass
format=S16_LE rate=48000 channels=1
regular_bytes=216000
fifo_bytes=216000
regular_hash=0xda3c449901876d40
fifo_hash=0xda3c449901876d40
vu_frames=108000
vu_peak_dbfs=-3.97
vu_rms_dbfs=-22.12
```

Artifacts:

```text
output_dir=/home/dev/work-base-20260421/workspace/systems/aig-adg-lab/target/aig-adg-lab-runs/alsa-file-fifo-vu-repro/run-1781478004413-2
regular_raw=/home/dev/work-base-20260421/workspace/systems/aig-adg-lab/target/aig-adg-lab-runs/alsa-file-fifo-vu-repro/run-1781478004413-2/regular.raw
fifo_raw=/home/dev/work-base-20260421/workspace/systems/aig-adg-lab/target/aig-adg-lab-runs/alsa-file-fifo-vu-repro/run-1781478004413-2/fifo.raw
vu_log=/home/dev/work-base-20260421/workspace/systems/aig-adg-lab/target/aig-adg-lab-runs/alsa-file-fifo-vu-repro/run-1781478004413-2/fifo-vu.log
```

### Unpatched ALSA, Forced FIFO Short Writes

Command:

```text
cargo run --locked -p aig-adg-lab-alsa-fifo-repro -- \
  --alsa-lib-dir /tmp/alsa-63-master-build/src/.libs \
  --preload /tmp/alsa_partial_write_preload.so \
  --partial-write-limit 4096 \
  --preload-fifo-only
```

Result:

```text
error: audio repro failed: aplay failed with status exit status: 1:
aplay: /tmp/alsa-lib-master-f453d/src/pcm/pcm_file.c:554:
snd_pcm_file_drain: Assertion `file->wbuf_used_bytes == 0' failed.
```

## Validation Commands

ALSA internal repro scripts:

```text
env BUILD_DIR=/tmp/alsa-452-build \
  bash internal/issue-63-file-fifo-partial-write/repro_fifo_file_pcm.sh

env BUILD_DIR=/tmp/alsa-452-build \
  LD_PRELOAD=/tmp/alsa_partial_write_preload.so \
  PARTIAL_WRITE_LIMIT=4096 \
  bash internal/issue-63-file-fifo-partial-write/repro_fifo_file_pcm.sh
```

Both patched runs completed byte-perfect:

```text
case=direct regular_bytes=262144 fifo_bytes=262144
case=rate regular_bytes=481646 fifo_bytes=481646
case=tee regular_bytes=262144 fifo_bytes=262144
```

Rust lab validation:

```text
cargo check --locked --workspace --all-targets
cargo test --locked --workspace
```

Both Rust validation commands passed in `workspace/systems/aig-adg-lab`.
