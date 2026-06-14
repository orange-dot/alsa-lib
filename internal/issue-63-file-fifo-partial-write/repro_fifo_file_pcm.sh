#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR=${BUILD_DIR:-/tmp/alsa-63-build}
PCM_MIN=${PCM_MIN:-"$BUILD_DIR/test/pcm_min"}
WRITER_ARGS=${WRITER_ARGS:-}
WRITER_TIMEOUT=${WRITER_TIMEOUT:-}
FIFO_READER_DELAY=${FIFO_READER_DELAY:-}
LIB_DIR=${LIB_DIR:-"$BUILD_DIR/src/.libs"}
TMP_ROOT=${TMP_ROOT:-/tmp}

tmpdir=$(mktemp -d "$TMP_ROOT/alsa-file-fifo-repro.XXXXXX")
reader_pid=

cleanup() {
	if [ -n "${reader_pid:-}" ]; then
		kill "$reader_pid" 2>/dev/null || true
		wait "$reader_pid" 2>/dev/null || true
	fi
	rm -rf "$tmpdir"
}
trap cleanup EXIT

write_common_config_prefix() {
	cat > "$tmpdir/asound.conf" <<'EOF'
pcm.null {
	type null
}
EOF
}

write_config_direct() {
	local sink=$1
	write_common_config_prefix
	cat >> "$tmpdir/asound.conf" <<EOF
pcm.!default {
	type file
	slave.pcm "null"
	file "$sink"
	format "raw"
}
EOF
}

write_config_rate() {
	local sink=$1
	write_common_config_prefix
	cat >> "$tmpdir/asound.conf" <<EOF
pcm.alsaFile {
	type file
	slave.pcm "null"
	file "$sink"
	format "raw"
}

pcm.!default {
	type rate
	slave {
		pcm "alsaFile"
		rate 44100
		format "S16_LE"
	}
}
EOF
}

write_config_tee() {
	local sink=$1
	write_common_config_prefix
	cat >> "$tmpdir/asound.conf" <<EOF
pcm.!default {
	type file
	slave.pcm "null"
	file "$sink"
	format "raw"
}
EOF
}

write_config_route_multi() {
	local sink=$1
	write_common_config_prefix
	cat >> "$tmpdir/asound.conf" <<EOF
pcm.fileSink {
	type file
	slave.pcm "null"
	file "$sink"
	format "raw"
}

pcm.vumeter {
	type rate
	slave {
		pcm "fileSink"
		rate 44100
		format "S16_LE"
	}
}

pcm.split_direct {
	type multi
	slaves.a.pcm "null"
	slaves.a.channels 2
	slaves.b.pcm "vumeter"
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

pcm.!default {
	type route
	slave.pcm "split_direct"
	ttable.0.0 1
	ttable.1.1 1
	ttable.0.2 1
	ttable.1.3 1
}
EOF
}

run_pcm_min() {
	if [ -n "$WRITER_TIMEOUT" ]; then
		timeout "$WRITER_TIMEOUT" env \
			ALSA_CONFIG_PATH="$tmpdir/asound.conf" \
			LD_LIBRARY_PATH="$LIB_DIR:${LD_LIBRARY_PATH:-}" \
			"$PCM_MIN" $WRITER_ARGS
	else
		env \
			ALSA_CONFIG_PATH="$tmpdir/asound.conf" \
			LD_LIBRARY_PATH="$LIB_DIR:${LD_LIBRARY_PATH:-}" \
			"$PCM_MIN" $WRITER_ARGS
	fi
}

bytes_of() {
	wc -c < "$1" | tr -d '[:space:]'
}

run_case() {
	local name=$1
	local writer=$2
	local regular_out="$tmpdir/$name-regular.raw"
	local fifo="$tmpdir/$name.fifo"
	local fifo_out="$tmpdir/$name-fifo.raw"
	local regular_bytes fifo_bytes

	"$writer" "$regular_out"
	run_pcm_min >/dev/null
	regular_bytes=$(bytes_of "$regular_out")

	mkfifo "$fifo"
	"$writer" "$fifo"
	if [ -n "$FIFO_READER_DELAY" ]; then
		bash -c 'exec 3< "$1"; sleep "$2"; cat <&3' sh "$fifo" "$FIFO_READER_DELAY" > "$fifo_out" &
	else
		cat "$fifo" > "$fifo_out" &
	fi
	reader_pid=$!
	run_pcm_min >/dev/null
	wait "$reader_pid"
	reader_pid=
	fifo_bytes=$(bytes_of "$fifo_out")

	printf 'case=%s regular_bytes=%s fifo_bytes=%s\n' \
		"$name" "$regular_bytes" "$fifo_bytes"

	if [ "$regular_bytes" != "$fifo_bytes" ]; then
		printf 'case=%s mismatch: FIFO captured %s bytes, regular file captured %s bytes\n' \
			"$name" "$fifo_bytes" "$regular_bytes" >&2
		return 1
	fi
}

run_case direct write_config_direct
run_case rate write_config_rate
run_case tee write_config_tee

if [ "${INCLUDE_ROUTE_MULTI:-0}" = 1 ]; then
	run_case route_multi write_config_route_multi
fi
