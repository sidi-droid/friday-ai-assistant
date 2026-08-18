#!/usr/bin/env bash
# Rebuild a Friday device from a clean checkout.
#
# VERIFICATION STATUS is marked on every step. Steps marked [VERIFIED] were
# executed successfully on the original device. Steps marked [UNVERIFIED] are
# reconstructed and must be confirmed before being trusted - in particular the
# model download URLs, which were not recorded.
#
# Nothing here runs automatically. Read it, then run the sections you need.

set -euo pipefail
ROOT="${FRIDAY_ROOT:-/friday}"

cat <<'BANNER'
FRIDAY bootstrap
================
This script does NOT run end to end unattended. Work through it section by
section. It assumes JetPack 7.2 with CUDA 13.2 on a Jetson Orin Nano.
BANNER

if [ "$(id -u)" -eq 0 ]; then echo "do not run this as root"; exit 1; fi

# ---------------------------------------------------------------------------
# 1. Directory layout                                            [VERIFIED]
# ---------------------------------------------------------------------------
mkdir -p "$ROOT"/{bin,config,logs,models/wakewords,src,tmp,backups,opt}
chmod 700 "$ROOT/config"

# ---------------------------------------------------------------------------
# 2. whisper.cpp with CUDA                                       [VERIFIED]
#    SM 8.7 is the Orin architecture. Keep parallelism low - the board has
#    6 cores and 8 GB shared between CPU and GPU.
# ---------------------------------------------------------------------------
build_whisper() {
  cd "$ROOT/src"
  [ -d whisper.cpp ] || git clone https://github.com/ggerganov/whisper.cpp
  cd whisper.cpp
  cmake -B build -DGGML_CUDA=1 -DCMAKE_CUDA_ARCHITECTURES=87 -DCMAKE_BUILD_TYPE=Release
  cmake --build build -j3
  ls -la build/bin/
}

# ---------------------------------------------------------------------------
# 3. llama.cpp with CUDA                                         [VERIFIED]
# ---------------------------------------------------------------------------
build_llama() {
  cd "$ROOT/src"
  [ -d llama.cpp ] || git clone https://github.com/ggml-org/llama.cpp
  cd llama.cpp
  cmake -B build -DGGML_CUDA=1 -DCMAKE_CUDA_ARCHITECTURES=87 -DCMAKE_BUILD_TYPE=Release
  cmake --build build -j3
  ls -la build/bin/
}

# ---------------------------------------------------------------------------
# 4. Models                                                    [UNVERIFIED]
#    The exact download URLs were not recorded. Required files:
#      models/ggml-base.en.bin                       (whisper.cpp release assets)
#      models/ggml-small.en.bin                      (optional)
#      models/NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf   (Hugging Face)
#      models/en_US-lessac-medium.onnx  + .onnx.json (Piper voices)
#    whisper.cpp ships models/download-ggml-model.sh, which is the supported
#    path for the first two.
# ---------------------------------------------------------------------------
fetch_models() {
  echo "Populate $ROOT/models manually - see the list above."
  ls -la "$ROOT/models" || true
}

# ---------------------------------------------------------------------------
# 5. Piper TTS                                                 [UNVERIFIED]
#    Binary plus libs plus espeak-ng-data, extracted to $ROOT/opt/piper.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 6. Optional wake-word engine                                   [VERIFIED]
#    Contained in a venv. NEVER installed system-wide: the venv carries
#    numpy 2.x while the system interpreter has 1.26.4, and mixing them
#    produces a dtype ABI error.
#    openwakeword 0.6.0 will NOT install here - tflite-runtime has no
#    aarch64 / py3.12 wheel. 0.4.0 is correct and uses wakeword_model_paths.
# ---------------------------------------------------------------------------
build_wakeword() {
  python3 -m venv "$ROOT/venvs/friday"
  "$ROOT/venvs/friday/bin/pip" install --upgrade pip
  "$ROOT/venvs/friday/bin/pip" install 'openwakeword==0.4.0' onnxruntime
  # Must run with cwd outside src/friday - see note in section 8.
  ( cd / && "$ROOT/venvs/friday/bin/python" -c \
      "import onnxruntime, openwakeword; print('wake-word engine ok')" )
}

# ---------------------------------------------------------------------------
# 7. Configuration                                               [VERIFIED]
# ---------------------------------------------------------------------------
setup_config() {
  [ -f "$ROOT/config/friday.env" ] || cp "$ROOT/config/friday.env.example" "$ROOT/config/friday.env"
  if [ ! -f "$ROOT/config/secrets.env" ]; then
    umask 077
    printf '# ANTHROPIC_API_KEY=...   # only needed for the Claude backend\n' > "$ROOT/config/secrets.env"
    chmod 600 "$ROOT/config/secrets.env"
  fi
  chmod +x "$ROOT"/bin/*
}

# ---------------------------------------------------------------------------
# 8. Verify                                                      [VERIFIED]
#    Always run from $ROOT, never from $ROOT/src/friday: our operator.py
#    shadows Python's stdlib operator module and breaks any numpy import.
# ---------------------------------------------------------------------------
verify() {
  cd "$ROOT"
  PYTHONPATH="$ROOT/src" python3 -m py_compile src/friday/*.py && echo "modules compile"
  "$ROOT/bin/friday" --doctor
  "$ROOT/bin/friday-test"
}

cat <<'NEXT'

Functions available - run them individually:
    build_whisper     build_llama      fetch_models
    build_wakeword    setup_config     verify

Recommended memory protection before loading any model (system changes, apply
deliberately): zram with zstd, an 8 GiB swapfile on the ROOT disk (not the
project disk), and raised vm.overcommit limits via /etc/sysctl.d/.
NEXT
