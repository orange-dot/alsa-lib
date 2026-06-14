# Internal evidence bundle: ALSA lib file-plugin buffered FIFO write handling

Branch: `internal/alsa-63-file-fifo-partial-write`

Fork remote: `origin` = `https://github.com/orange-dot/alsa-lib.git`

Upstream base commit used for this investigation:
`f453d783336167ee2714573f4352a72e3ce65094`

This internal branch intentionally carries local evidence and reproduction
helpers next to the source fix. Before an upstream submission, create a clean
PR-ready branch or prune this internal bundle.

## Bundle Files

- `README.md`: investigation notes, reproduction notes, and validation record.
- `repro_fifo_file_pcm.sh`: software-only FIFO versus regular-file comparator.
- `repro_issue63_ag03.sh`: Yamaha AG06/AG03 hardware-oriented topology reproducer.
- `pcm_write_finite.c`: finite PCM writer used by the reproduction scripts.
- `partial_write_preload.c`: `LD_PRELOAD` shim that forces short `write(2)` results.

## Problem Under Investigation

The ALSA `file` PCM plugin flushes buffered PCM payload data to an output file
descriptor. When that descriptor is a FIFO or pipe, `write(2)` may legally
return a short positive byte count. That is not an error; it means the caller
must retry the remaining bytes.

The old `snd_pcm_file_write_bytes()` loop stopped after a short positive write
and returned success. That could leave bytes in the internal write buffer. In a
debug build, `snd_pcm_file_drain()` can then abort because `wbuf_used_bytes` is
not zero. In a non-debug or different timing scenario, this can plausibly become
lost output data.

The source fix changes the buffered PCM payload flush path so partial writes
continue until all requested payload bytes are flushed, and treats a zero-byte
write as `-EIO` to avoid an infinite loop. It does not claim to cover every
`pcm_file` write path; WAV header and length-fixup writes remain outside the
scope of this patch.

## Software FIFO Checks

Simple current-master FIFO checks with a normal reader were byte-perfect:

```text
case=direct regular_bytes=262144 fifo_bytes=262144
case=rate regular_bytes=481646 fifo_bytes=481646
case=tee regular_bytes=262144 fifo_bytes=262144
```

Finite 4-channel writer checks were also byte-perfect for direct, rate, and tee
paths:

```text
case=direct regular_bytes=2097152 fifo_bytes=2097152
case=rate regular_bytes=1926584 fifo_bytes=1926584
case=tee regular_bytes=2097152 fifo_bytes=2097152
```

A local `route -> multi -> rate -> file` shape timed out before producing a
regular-file baseline with the synthetic helper, so it was not used as proof.

## Forced Short-Write Reproduction

The actionable bug was reproduced deterministically with:

```text
LD_PRELOAD=/tmp/alsa_partial_write_preload.so
PARTIAL_WRITE_LIMIT=4096
```

The preload shim forces `write(2)` to return a short positive byte count for
large writes. This simulates a legal FIFO/pipe behavior without relying on
kernel timing or a slow reader.

Before the fix:

```text
snd_pcm_file_drain: Assertion `file->wbuf_used_bytes == 0' failed
```

After the fix, the same forced-short-write direct/rate/tee run completed
byte-perfect:

```text
case=direct regular_bytes=524288 fifo_bytes=524288
case=rate regular_bytes=481644 fifo_bytes=481644
case=tee regular_bytes=524288 fifo_bytes=524288
```

## Yamaha AG06/AG03 Hardware Checks

Host ALSA card:

```text
AG06AG03
```

Playback device:

```text
hw:AG06AG03,0
```

Observed hardware parameters:

```text
FORMAT: S32_LE
CHANNELS: 2
RATE: [44100 192000]
```

The hardware-oriented reproduction remapped the issue topology's hardware PCM
to `card "AG06AG03"` and used hardware-compatible writer settings:

```text
PCM_FORMAT=S32_LE
WRITER_CHANNELS=4
```

Normal FIFO reader, unpatched master, `pcm.vumeter` path:

```text
regular_bytes=32768
fifo_bytes=32768
```

Normal FIFO reader, unpatched master, `pcm.alsaFifoTee` path:

```text
regular_bytes=65536
fifo_bytes=65536
```

Conclusion: the AG03 setup did not naturally reproduce byte loss on current
master with a normal FIFO reader.

Forced short-write AG03 run on unpatched master:

```text
LD_PRELOAD=/tmp/alsa_partial_write_preload.so \
PARTIAL_WRITE_LIMIT=4096 \
PCM_FORMAT=S32_LE \
WRITER_CHANNELS=4 \
B_PCM=vumeter \
bash internal/issue-63-file-fifo-partial-write/repro_issue63_ag03.sh
```

Result:

```text
snd_pcm_file_drain: Assertion `file->wbuf_used_bytes == 0' failed
```

Same forced short-write AG03 run with the patched build:

```text
regular_bytes=32768
fifo_bytes=32768
```

## Validation After Fix

Completed validation:

```text
env CCACHE_DISABLE=1 make -j4
env CCACHE_DISABLE=1 make check -k
env CCACHE_DISABLE=1 CFLAGS='-O2 -Werror=incompatible-pointer-types -Werror=old-style-definition' <repo>/configure --disable-aload --prefix=<tmp-install>
env CCACHE_DISABLE=1 make -j4
env CCACHE_DISABLE=1 make check -k
git diff --check
```

All checks passed after the `pcm_file` change.

## Upstream Preparation Notes

This branch is intentionally internal. For an upstream-ready branch:

- keep the `src/pcm/pcm_file.c` fix;
- decide whether any small regression helper belongs upstream;
- remove this internal evidence bundle unless maintainers ask for it;
- describe the source change as buffered PCM payload write handling, not as a
  complete fix for every partial write in `pcm_file`;
- write the upstream PR without overclaiming natural reproduction on AG03.
