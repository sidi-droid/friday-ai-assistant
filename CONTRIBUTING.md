# Working on Friday

Notes for anyone — human or agent — changing this codebase.

## Read first

`SECURITY.md`. Four files carry security invariants and must not be modified
casually:

```
src/friday/command_policy.py    risk classification
src/friday/operator.py          proposal and approval lifecycle
src/friday/executor.py          argv execution and output limits
src/friday/tools.py             read-only tools (contains no subprocess)
```

Changing any of them requires re-running `bin/friday-test` and stating why the
change was necessary.

## Hard constraints

These come from the device owner and are not negotiable:

- Friday runs as an unprivileged user, never root.
- No `shell=True` anywhere.
- No blanket sudoers rule.
- Everything Friday-specific lives under `/friday`. Do not modify `/etc`,
  `/usr`, `/boot`, `/opt/ros`, partitions, firmware or power configuration.
- `/opt/ros` belongs to an unrelated robotics project (Aura). Never touch it.
- The root NVMe (`/dev/nvme0n1`) is never modified.
- No new pip dependencies in the core package. It is standard library only.
  The one optional extra (`openwakeword`) is confined to `/friday/venvs/friday`.

## Environment traps

- **Never run anything with the working directory set to `src/friday/`.**
  `operator.py` shadows Python's stdlib `operator`, and numpy will fail with a
  misleading circular-import error. Run from the repo root or `/friday`.
- The venv interpreter and the system interpreter have incompatible numpy
  versions. Do not import venv packages from system Python; spawn the venv
  interpreter as a subprocess instead. `bin/friday-wakeword` is the pattern.
- The device is a Jetson with **8 GB shared between CPU and GPU**. With
  whisper-server, llama-server and Piper resident, ~1.3 GiB remains. Assume
  memory pressure.
- Maximum power mode is 15 W. There is no MAXN on this unit.

## Testing

```bash
bin/friday-test        # policy, shell-usage, shadowing, routing, tools
bin/friday --doctor    # health, integrity hashes, resources
bin/friday --text "…"  # single turn without a microphone
```

`friday-test` proposes and discards; it never approves, and it runs with
`FRIDAY_ALLOW_DESTRUCTIVE=0`.

Anything touching audio, wake-word accuracy or latency needs a **live test on
the device**. Two lessons from prior benchmarks:

- If the microphone stream is not drained continuously, PipeWire buffers and
  you measure stale audio. A wake-word benchmark once read 20% purely because
  the countdown loop stopped consuming frames.
- A detection score of exactly `0.00` means no audio arrived, not that the
  detector missed. Distinguish those before drawing conclusions.

## Style

- Standard library only in `src/friday/`.
- Comments explain *why*, especially where something looks odd — most oddities
  here are load-bearing workarounds for real, reproduced bugs.
- When patching programmatically, anchor on function boundaries via AST or
  regex and verify the result compiles **before** writing. Naive string
  replacement has silently corrupted this codebase before.
- Keep spoken output short. Replies are capped at roughly two sentences and
  twenty words; sensor answers are a value plus its unit.

## Deploying

```bash
./scripts/deploy-to-jetson.sh              # dry run
./scripts/deploy-to-jetson.sh --apply      # backs up, syncs, verifies
ssh sid@<jetson> /friday/bin/friday-test
```
