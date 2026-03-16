#!/usr/bin/env bash
# voice-transcribe/scripts/transcribe.sh
# Wrapper for the OpenClaw Studio local Whisper runner.
# Usage: transcribe.sh <audio-file> [--model MODEL] [--out OUTPUT] [--language LANG]
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  transcribe.sh <audio-file> [--model MODEL] [--out OUTPUT] [--language LANG]

Options:
  --model    Whisper model (tiny|base|small|medium|large-v3). Default: reads ~/.openclaw/voice/model
  --out      Output path for transcript text. Default: <audio-file>.txt
  --language Force language (e.g. en, es, fr). Default: auto-detect

Examples:
  transcribe.sh voice_note.ogg
  transcribe.sh audio.m4a --model medium --out /tmp/result.txt --language en
EOF
    exit 2
}

[[ "${1:-}" == "" || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

AUDIO_FILE="${1}"
shift || true

MODEL=""
OUT=""
LANGUAGE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)    MODEL="${2:-}";    shift 2 ;;
        --out)      OUT="${2:-}";      shift 2 ;;
        --language) LANGUAGE="${2:-}"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

if [[ ! -f "$AUDIO_FILE" ]]; then
    echo "File not found: $AUDIO_FILE" >&2
    exit 1
fi

# Resolve runner — prefer env var, fall back to default install path
RUNNER="${WHISPER_RUNNER:-${HOME}/.openclaw/bin/voice-transcribe}"

if [[ ! -x "$RUNNER" ]]; then
    echo "voice-transcribe runner not found at: $RUNNER" >&2
    echo "Run OpenClaw Studio option 1 (Install/Update) and enable voice transcription." >&2
    exit 1
fi

# Resolve model — prefer flag, then env file, then runner default
if [[ -z "$MODEL" ]]; then
    MODEL_FILE="${WHISPER_MODEL_FILE:-${HOME}/.openclaw/voice/model}"
    [[ -f "$MODEL_FILE" ]] && MODEL=$(cat "$MODEL_FILE" | tr -d '[:space:]')
fi

# Resolve output path
if [[ -z "$OUT" ]]; then
    OUT="${AUDIO_FILE%.*}.txt"
fi

mkdir -p "$(dirname "$OUT")"

# Build runner args
ARGS=("$AUDIO_FILE")
[[ -n "$MODEL" ]]    && ARGS+=(--model "$MODEL")
[[ -n "$LANGUAGE" ]] && ARGS+=(--language "$LANGUAGE")

# Run transcription and capture to output file
"$RUNNER" "${ARGS[@]}" > "$OUT"

echo "$OUT"
