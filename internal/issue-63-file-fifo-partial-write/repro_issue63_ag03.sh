#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR=${BUILD_DIR:-/tmp/alsa-63-master-build}
PCM_WRITER=${PCM_WRITER:-/tmp/alsa_pcm_write_finite_master}
HIFACE_CARD=${HIFACE_CARD:-AG06AG03}
HIFACE_DEVICE=${HIFACE_DEVICE:-0}
WRITER_RATE=${WRITER_RATE:-44100}
WRITER_CHANNELS=${WRITER_CHANNELS:-2}
WRITER_FRAMES=${WRITER_FRAMES:-256}
WRITER_ITERATIONS=${WRITER_ITERATIONS:-32}
WRITER_TIMEOUT=${WRITER_TIMEOUT:-10s}
SAMPLE_AMPLITUDE=${SAMPLE_AMPLITUDE:-64}
PCM_FORMAT=${PCM_FORMAT:-S16_LE}
B_PCM=${B_PCM:-vumeter}

tmpdir=$(mktemp -d /tmp/alsa-issue63-ag03.XXXXXX)
reader_pid=

cleanup() {
	if [ -n "${reader_pid:-}" ]; then
		kill "$reader_pid" 2>/dev/null || true
		wait "$reader_pid" 2>/dev/null || true
	fi
	rm -rf "$tmpdir"
}
trap cleanup EXIT

write_config() {
	local sink=$1
	cat > "$tmpdir/asound.conf" <<EOF
defaults.pcm.file_format raw
defaults.pcm.file_truncate true

pcm.null {
	type null
}

pcm.tee {
	@args [ SLAVE FILE FORMAT ]
	@args.SLAVE {
		type string
	}
	@args.FILE {
		type string
	}
	@args.FORMAT {
		type string
		default raw
	}
	type file
	slave.pcm \$SLAVE
	file \$FILE
	format \$FORMAT
	truncate true
}

pcm.hiface {
	type hw
	card "$HIFACE_CARD"
	device $HIFACE_DEVICE
}

pcm.vumeter {
	type rate
	slave {
		pcm "alsaFifo"
		rate 44100
		format "S16_LE"
	}
}

pcm.alsaFifo {
	type file
	slave.pcm "null"
	file "$sink"
}

pcm.alsaFifoTee {
	type empty
	slave.pcm "tee:null,'$sink',raw"
}

pcm.direct {
	type route
	slave.pcm "split_direct"
	ttable.0.0 1
	ttable.1.1 1
	ttable.0.2 1
	ttable.1.3 1
}

pcm.split_direct {
	type multi
	slaves.a.pcm "hiface"
	slaves.a.channels 2
	slaves.b.pcm "$B_PCM"
	slaves.b.channels 2
	bindings.0.slave a
	bindings.0.channel 0
	bindings.1.slave a
	bindings.1.channel 1
	bindings.2.slave b
	bindings.2.channel 0
	bindings.3.slave b
	bindings.3.channel 1
}
EOF
}

run_writer() {
	timeout "$WRITER_TIMEOUT" env \
		ALSA_CONFIG_PATH="$tmpdir/asound.conf" \
		LD_LIBRARY_PATH="$BUILD_DIR/src/.libs:${LD_LIBRARY_PATH:-}" \
		SAMPLE_AMPLITUDE="$SAMPLE_AMPLITUDE" \
		PCM_FORMAT="$PCM_FORMAT" \
		"$PCM_WRITER" direct "$WRITER_RATE" "$WRITER_CHANNELS" \
		"$WRITER_FRAMES" "$WRITER_ITERATIONS"
}

bytes_of() {
	wc -c < "$1" | tr -d '[:space:]'
}

regular_out="$tmpdir/direct-regular.raw"
write_config "$regular_out"
regular_log="$tmpdir/direct-regular.log"
run_writer > "$regular_log"
regular_bytes=$(bytes_of "$regular_out")

fifo="$tmpdir/alsa-fifo"
fifo_out="$tmpdir/direct-fifo.raw"
mkfifo "$fifo"
write_config "$fifo"
cat "$fifo" > "$fifo_out" &
reader_pid=$!
fifo_log="$tmpdir/direct-fifo.log"
run_writer > "$fifo_log"
wait "$reader_pid"
reader_pid=
fifo_bytes=$(bytes_of "$fifo_out")

printf 'regular_bytes=%s\n' "$regular_bytes"
printf 'fifo_bytes=%s\n' "$fifo_bytes"
printf 'regular_writer=%s\n' "$(cat "$regular_log")"
printf 'fifo_writer=%s\n' "$(cat "$fifo_log")"

if [ "$regular_bytes" != "$fifo_bytes" ]; then
	printf 'mismatch: FIFO captured %s bytes, regular file captured %s bytes\n' \
		"$fifo_bytes" "$regular_bytes" >&2
	exit 1
fi
