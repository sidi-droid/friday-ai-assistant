# FRIDAY

A fully local voice assistant running on an NVIDIA Jetson Orin Nano 8 GB. Speech
recognition, reasoning, and speech synthesis all execute on-device. No network
call is required to hold a conversation.

Friday can also propose and run shell commands, gated by a deterministic risk
classifier that the language model is structurally unable to weaken.

---

## Pipeline

```
USB microphone
   -> PipeWire capture (pw-record, 16 kHz mono s16)
   -> energy gate + VAD segmentation
   -> whisper.cpp (CUDA)                    speech -> text
   -> wake word + session state machine     IDLE <-> ACTIVE, 30 s window
   -> router
        - deterministic voice vocabulary    16 fixed phrases, sub-30 ms
        - live sensor injection             regex -> real procfs/sysfs reads
        - Nemotron 3 Nano 4B (llama.cpp)    everything else
   -> tool dispatch
        - read-only tools                   pure procfs/sysfs, no subprocess
        - propose_command -> command_policy -> operator -> executor
   -> Piper TTS
   -> PipeWire playback -> HDMI
```

---

## Hardware and platform

| | |
|---|---|
| Board | Jetson Orin Nano 8 GB Developer Kit (tegra234, SM 8.7) |
| CPU | 6x Cortex-A78AE @ 1.51 GHz |
| Power mode | 15 W — the maximum this unit supports (no MAXN) |
| L4T / JetPack | R39.2 / JetPack 7.2, kernel `6.8.12-1021-tegra` |
| CUDA / TensorRT | 13.2 / 10.16.2, cuDNN 9.20 |
| Python | 3.12.3 |
| Root disk | Crucial T500 NVMe (2280 slot, Gen3 x4) — **never modified by this project** |
| Project disk | Crucial P310 NVMe (2230 slot, Gen3 x2), ext4, mounted at `/friday` |
| Memory protection | zram (zstd) + 8 GiB swapfile on root; `CommitLimit` raised 3.65 -> 15.65 GiB |

---

## Models

| Role | Model | Notes |
|---|---|---|
| ASR | `ggml-base.en.bin` | `small.en` also present; base is the default for latency |
| Reasoning | NVIDIA Nemotron 3 Nano 4B, `Q4_K_M` GGUF | `nemotron_h` — hybrid Mamba-2 with 4 attention layers |
| TTS | Piper `en_US-lessac-medium` | ONNX + JSON config |
| Wake word (optional) | openWakeWord 0.4.0 | opt-in; see below |

Nemotron's Mamba-2 recurrent state cannot be rewound token-by-token in
llama.cpp, so a naive per-turn rebuild cost ~523 replayed tokens (~1.7 s).
Friday keeps a persistent append-only conversation state instead, which raised
prefix-cache reuse from 0.952 to 1.000.

---

## Repository layout

```
src/friday/          the Python package - this is the actual work
  config.py            paths, tunables, env overrides
  audio_input.py       PipeWire capture (pw-record, arecord fallback)
  vad.py               energy VAD, noise-floor calibration, segmentation
  asr.py               whisper.cpp client
  local_llm.py         prompt, routing, live sensors, tool dispatch
  reasoning.py         backend selection (local Nemotron / Claude API)
  tools.py             six read-only tools - no subprocess, no eval
  command_policy.py    deterministic risk classification (security core)
  operator.py          proposal, fingerprinting, approval lifecycle
  executor.py          argv execution, streaming output limits
  tts.py               Piper synthesis and playback
  wakeword.py          optional openWakeWord bridge
  orchestrator.py      session state machine, guards, main loop
  __main__.py          CLI entry point

bin/
  friday               entry point; refuses to run as root
  friday-test          full regression suite
  friday-wakeword      wake-word daemon (runs under the venv interpreter)

config/
  friday.env.example   tunables template -> copy to friday.env
                       (secrets.env is NEVER committed)

deploy/
  friday.service       systemd --user unit

scripts/
  bootstrap.sh         rebuild a device from a clean checkout
  sync-from-jetson.sh  pull source off the device into this repo
  deploy-to-jetson.sh  push this repo's source back to the device
```

`models/`, `venvs/`, `logs/`, `backups/`, `tmp/`, `src/whisper.cpp/`,
`src/llama.cpp/` and `opt/piper/` exist on the device but are deliberately not
tracked — several GB of weights and third-party build trees.

---

## Installation

Requires a Jetson running JetPack 7.2 with CUDA available.

```bash
git clone git@github.com:sidi-droid/friday-ai-assistant.git /friday
cd /friday
./scripts/bootstrap.sh          # builds whisper.cpp + llama.cpp, fetches models
```

`bootstrap.sh` is annotated with which steps are verified and which need
confirming on a fresh device — read it before running.

The Python package itself has **zero pip dependencies**. It is standard library
only. The single optional dependency (`openwakeword` + `onnxruntime`) installs
into `/friday/venvs/friday` and is never imported by the system interpreter.

---

## Configuration

```bash
cp config/friday.env.example config/friday.env
```

Every setting is optional; defaults live in `src/friday/config.py`.

| Variable | Default | Purpose |
|---|---|---|
| `FRIDAY_BACKEND` | `auto` | `auto` \| `local` \| `claude` |
| `FRIDAY_SESSION_WINDOW` | `30` | seconds before ACTIVE reverts to IDLE |
| `FRIDAY_SPEECH_MIN_PEAK` | `2500` | raise in a noisy room |
| `FRIDAY_TTS_SETTLE` | `0.6` | post-speech drain, prevents self-hearing |
| `FRIDAY_EXEC_TIMEOUT` | `30` | command timeout (10 s for read-only) |
| `FRIDAY_ALLOW_DESTRUCTIVE` | `0` | leave at `0` |
| `FRIDAY_WAKE_ENGINE` | `whisper` | `whisper` \| `openwakeword` |
| `FRIDAY_WAKE_MODEL` | `hey_jarvis` | custom ONNX in `models/wakewords/` wins |

Secrets go in `config/secrets.env` (mode `600`), which is gitignored. Only
`ANTHROPIC_API_KEY` is read, and only when the Claude backend is selected.

---

## Running

```bash
friday                   # continuous listening
friday --doctor          # health, integrity hashes, resources, policy check
friday --selftest        # preflight only
friday --tools           # exercise all six read-only tools
friday --text "..."      # one turn, no microphone
friday --once            # one spoken utterance, then exit
friday-test              # full regression suite
```

As a service:

```bash
cp deploy/friday.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now friday
# survives logout only with:  sudo loginctl enable-linger $USER
```

---

## Security model

Friday can execute shell commands. The controls below are the reason that is
acceptable, and none of them depend on the language model behaving well.

- Runs as an unprivileged user. **Refuses to start as root.**
- **No shell, ever.** `shell=True` is never used; commands run as argv vectors.
  `tools.py` contains zero `subprocess`, `os.system`, `eval` or `exec` calls.
- `command_policy.py` is the sole authority on risk. The model may *propose* a
  command but never classify it: effective risk is
  `max(deterministic, model_claim)`, so a model can only ever escalate. A model
  claiming `READ_ONLY` for `rm -rf` still yields `DESTRUCTIVE`.
- `READ_ONLY` auto-executes. `LOW_RISK_WRITE`, `PRIVILEGED` and `DESTRUCTIVE`
  require spoken confirmation bound to a SHA-256 fingerprint of the exact
  argv + cwd + sudo tuple. If anything changes after you were shown it,
  approval is refused. Fails closed.
- Destructive execution is disabled outright (`EXEC_ALLOW_DESTRUCTIVE=0`).
- Privileged commands can be proposed but not executed: `sudo -n` never
  prompts, and there is deliberately no sudoers rule.
- Protected paths: `/etc /usr /boot /opt/ros /sys /proc /dev /var` and all
  block devices. `key=value` arguments are parsed, so `tee of=/dev/nvme0n1` is
  caught.
- Output is streamed with an 8 KB cap and a timeout. A runaway producer is
  killed, never buffered. (`cat /dev/zero` once buffered GB into RAM over
  78.5 s; after the rewrite it terminates in 0.003 s with no memory movement.)
- Every proposal, approval, discard and execution is appended to
  `logs/commands.log` as JSON.
- Verified against 15 policy cases plus live prompt-injection attempts.

---

## Measured performance

All figures from the device, not estimates.

| | |
|---|---|
| Wake acknowledgement | ~1.3 s |
| Sensor question, end to end | 4.4 – 6.6 s |
| Conversational reply | 4.35 – 6.10 s |
| Deterministic voice command | under 30 ms |
| ASR | 127 – 465 ms (4.7 – 24.5x realtime) |
| Nemotron generation | ~11.4 tok/s, 1.1 – 2.6 s warm |
| Piper synthesis | 0.2 – 0.6 s |
| Cold start to listening | ~14 s |
| RAM free, all three servers resident | 1.32 GiB |

Wake word:

| Method | Detection | False accepts | CPU |
|---|---|---|---|
| Whisper, "Friday" alone | 11/20 (55%) | 0 after guards | none (already running) |
| Whisper, "Friday, <request>" | 17/20 (85%) | 0 after guards | none |
| openWakeWord `hey_jarvis` | 13/15 (87%); 13/13 where audio reached the detector | 0 in 20 s | 20.3% of one core, continuous |

---

## What works

- Continuous listening with VAD, energy gating and noise-floor calibration
- Wake word, 30 s session window, expiry evaluated during silence
- Local ASR, local reasoning, local TTS — no cloud dependency
- Six read-only system tools with deterministic live-value injection
- Deterministic voice vocabulary (16 phrases) bypassing the model entirely
- Command proposal, risk classification, spoken confirmation, audited execution
- Audio feedback suppression (echo detection + post-speech drain)
- Fabrication guard: a measurement-shaped number with no live data behind it is
  refused rather than spoken
- `--doctor` health report and a one-command regression suite

## Known limitations

- **Wake word "Friday" alone is 55%.** `base.en` is weak on isolated single
  words. Say "Friday, <request>" in one breath for 85%.
- **Spoken shell commands are unreliable.** `df -h` transcribes as `d-h`,
  `docker` as "dock goes over". Use the voice vocabulary or type them.
- **Privileged commands cannot execute.** By design.
- **openWakeWord has no "friday" model.** Only `alexa`, `hey_jarvis`,
  `hey_marvin`, `hey_mycroft`, `timer`, `weather` ship pretrained. A custom
  model requires training. openWakeWord 0.6.0 will not install on aarch64 /
  Python 3.12 (`tflite-runtime` has no wheel), so 0.4.0's
  `wakeword_model_paths` API is used.
- **GPU ACR/WPR firmware bootstrap intermittently fails at boot**, leaving
  `cudaGetDeviceCount -> 0`. A reboot has cleared it every time. Root cause not
  established.
- **`src/friday/operator.py` shadows Python's stdlib `operator`** when the
  working directory is the package directory. Anything importing numpy from
  there will fail. All scripts must run from outside `src/friday/`.

## Not yet built

- ROS 2 / Aura integration. Blocked on memory: 1.32 GiB free with all servers
  resident. Gazebo will not run on this board at all and should live on a
  workstation with ROS 2 distributed over DDS. Making `llama-server` idle-unload
  would free ~2.5 GB and is the most promising lever.
- Custom "Friday" wake-word model.
- Live end-to-end acceptance test with all servers running (the last attempt
  scored 3/7 because the servers had been killed by a prior benchmark, not
  because of a defect).

---

## Provenance

Built incrementally on hardware, with every phase verified before the next
began. Performance figures come from benchmark runs on the device. Where a
result was later found to be measurement error rather than system behaviour,
the corrected figure is the one recorded here.
