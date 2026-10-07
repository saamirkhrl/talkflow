#!/bin/bash
# Starts a whisper-server, sends it a recording through /inference (the
# endpoint the app uses) and checks the transcript.
#
#   scripts/smoke-whisper-macos.sh <whisper-server> <model.bin> <audio.wav> [port] [expected text]
#
# Defaults: port 8197 (not 8178/8179, which a running talkflow uses) and the
# words of whisper.cpp's samples/jfk.wav. SMOKE_ARCH=x86_64 runs the Intel
# slice of the universal binary (under Rosetta on Apple Silicon).
set -euo pipefail

BIN="${1:?usage: $0 <whisper-server> <model.bin> <audio.wav> [port] [expected text]}"
MODEL="${2:?model path}"
WAV="${3:?wav path}"
PORT="${4:-8197}"
EXPECT="${5:-ask not what your country}"
ARCH="${SMOKE_ARCH:-}"

LOG="$(mktemp -t whisper-smoke)"
RUN=("$BIN")
[ -z "$ARCH" ] || RUN=(arch "-$ARCH" "$BIN")

if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/"; then
    echo "error: something already answers on port $PORT" >&2
    exit 1
fi

echo "==> Starting ${RUN[*]} on port $PORT"
"${RUN[@]}" -m "$MODEL" --host 127.0.0.1 --port "$PORT" -nt >"$LOG" 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true' EXIT

for _ in $(seq 120); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/" && break
    kill -0 "$PID" 2>/dev/null || { cat "$LOG" >&2; echo "error: whisper-server exited" >&2; exit 1; }
    sleep 0.5
done

START=$(date +%s)
TEXT="$(curl -sS --fail --max-time 120 "http://127.0.0.1:$PORT/inference" \
    -F "file=@$WAV" -F "response_format=text")"
echo "    transcript ($(( $(date +%s) - START ))s): $TEXT"
grep -E "backend|Metal|MTL|CPU|system_info" "$LOG" | head -8 | sed 's/^/    log: /' || true

if echo "$TEXT" | tr '[:upper:]' '[:lower:]' | grep -q "$EXPECT"; then
    echo "    ok: the transcript contains \"$EXPECT\""
else
    echo "error: expected \"$EXPECT\" in the transcript" >&2
    tail -30 "$LOG" >&2
    exit 1
fi
