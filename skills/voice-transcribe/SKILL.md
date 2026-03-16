---
name: voice-transcribe
description: Transcribe audio / Telegram voice notes locally with the OpenClaw Studio Whisper runtime (no API key).
homepage: https://github.com/openai/whisper
metadata:
  {
    "openclaw":
      {
        "emoji": "🎤",
        "requires": { "bins": ["voice-transcribe"], "env": [] },
        "primaryEnv": "WHISPER_RUNNER",
      },
  }
---

# Voice Transcribe (local Whisper)

Transcribe audio files using the local Whisper model installed by OpenClaw Studio.
No API key required — everything runs on-device.

## Quick start

```bash
voice-transcribe /path/to/audio.ogg
voice-transcribe /path/to/voice_note.m4a --model medium --out /tmp/transcript.txt
```

The runner is installed at `~/.openclaw/bin/voice-transcribe` and uses the model
chosen during Studio setup (stored in `~/.openclaw/voice/model`).

## Useful flags

```bash
voice-transcribe /path/audio.ogg --model tiny      # fast, low-accuracy
voice-transcribe /path/audio.ogg --model base      # balanced
voice-transcribe /path/audio.ogg --model small     # good accuracy
voice-transcribe /path/audio.ogg --model medium    # high accuracy
voice-transcribe /path/audio.ogg --model large-v3  # best, slower
voice-transcribe /path/audio.ogg --language en     # force language
voice-transcribe /path/audio.ogg --out result.txt  # custom output path
```

## Environment variables (set by installer)

| Variable             | Purpose                                         |
| -------------------- | ----------------------------------------------- |
| `WHISPER_RUNNER`     | Path to the runner binary                       |
| `WHISPER_MODEL_FILE` | File containing the active model name           |
| `WHISPER_CACHE_DIR`  | Directory where model weights are cached        |
| `WHISPER_VENV`       | Path to the Python venv with openai-whisper     |

Source `~/.openclaw/voice/env.sh` to populate all variables in your shell.

## Telegram voice note integration

When the OpenClaw gateway receives a Telegram voice message, it stores the file
in the workspace and sets `TELEGRAM_VOICE_FILE`. The agent can call:

```bash
{baseDir}/scripts/transcribe.sh "$TELEGRAM_VOICE_FILE"
```

or simply invoke `voice-transcribe "$TELEGRAM_VOICE_FILE"` if the bin dir is
on `PATH` (it will be after sourcing `~/.openclaw/voice/env.sh`).
