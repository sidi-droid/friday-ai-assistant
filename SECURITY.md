# Security model

Friday accepts spoken input and can execute shell commands. The controls below
are what make that acceptable. **None of them depend on the language model
behaving correctly.**

If you are an automated agent modifying this repository, read this file before
touching `command_policy.py`, `operator.py`, `executor.py` or `tools.py`.

---

## Invariants

These must hold after any change. The regression suite (`bin/friday-test`)
checks all of them.

1. **Never runs as root.** `bin/friday` exits if `id -u` is 0.
2. **No shell.** `shell=True`, `os.system`, `eval` and `exec` appear nowhere in
   the package. Commands execute as argv vectors via `subprocess.Popen` with
   `shell=False` and `start_new_session=True`.
3. **`tools.py` performs no execution.** All six tools are pure procfs/sysfs
   reads. The file contains zero `subprocess` references.
4. **The model cannot classify risk.** `command_policy.py` decides
   deterministically. Effective risk is `max(deterministic, model_claim)` — a
   model may escalate, never downgrade. The `risk` field is stripped from the
   model-facing tool schema and from model-supplied arguments before use.
5. **Confirmation is fingerprint-bound.** Approval covers a SHA-256 of the
   exact argv + normalised cwd + sudo flag. Any change invalidates it. Failure
   modes fail closed.
6. **Destructive execution is off.** `EXEC_ALLOW_DESTRUCTIVE=0`.
7. **Privileged execution is impossible.** `sudo -n` never prompts and no
   sudoers rule exists. Privileged commands can be proposed, never run.
8. **Output is bounded.** Streaming reads via `selectors`, 8 KB cap, timeout,
   process killed on breach. `capture_output=True` is never used on child
   output.
9. **Everything is audited.** Proposals, approvals, discards and executions are
   appended as JSON to `logs/commands.log`.

## Protected paths

`/etc` `/usr` `/boot` `/opt/ros` `/sys` `/proc` `/dev` `/var`, plus all block
devices. Arguments of the form `key=value` are parsed, so `dd of=/dev/nvme0n1`
and `tee of=/dev/nvme1n1` are both caught.

`/opt/ros` is protected because this machine also hosts an unrelated robotics
project. Friday must never modify it.

## Package managers

Classified by a **read allowlist**, not a write denylist — the safer default.
Anything not explicitly a read operation (`list`, `show`, `search`, `policy`,
`depends`) is at least `PRIVILEGED`. Removal verbs (`remove`, `purge`,
`autoremove`, `uninstall`, `erase`, `dpkg -r`, `dpkg -P`) are `DESTRUCTIVE`.

This inversion was made after `apt get cowsay -y` — a malformed but plausible
transcription — classified as `LOW_RISK_WRITE`.

## Prompt injection

The model's output is data, never authority. It cannot set its own risk level,
cannot supply a `cwd` (invented values are stripped), and cannot bypass
confirmation. Verified against live injection attempts, including a model
explicitly claiming `READ_ONLY` for `rm -rf`, which still classified as
`DESTRUCTIVE`.

## Secrets

`config/secrets.env`, mode `600`, gitignored. Only `ANTHROPIC_API_KEY` is read,
and only when the Claude backend is selected. It is never logged or spoken.
The default local backend requires no credentials at all.

## Known hazards

- **`src/friday/operator.py` shadows Python's stdlib `operator`** whenever the
  working directory is `src/friday/`. Any numpy import from there fails with a
  confusing circular-import error. All entry points and scripts run from
  outside that directory. Renaming the module would be the real fix, but it is
  a security-critical file and has not been touched.
- **Wake-word detection is not authentication.** Anyone within earshot can talk
  to Friday. There is no speaker verification.
- **The audit log is append-only by convention, not enforcement.** A local user
  with write access could alter it.

## Reporting

This is a personal project on a private network. If you find a flaw, open an
issue on the repository.
