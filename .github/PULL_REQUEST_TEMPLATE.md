## What broke, and what this changes

<!-- If it is a fix, describe the failure mode, not only the diff. That is what
     makes the commit useful in a year. -->

## Checks

- [ ] `tests/run` passes
- [ ] `bash -n ssmd lib/*.sh runtimes/*/commands.sh` is clean
- [ ] a test covers the bug this fixes, or the behaviour this adds
- [ ] no configuration value was written into code - new values went into
      `config/defaults.yml` and are read with `_cfg`
- [ ] nothing language-specific left `runtimes/<kind>/`
- [ ] `README.md` and any affected plugin skill still describe reality

## Invariants

<!-- Say so explicitly if this touches any of these, and why it is right.
     They are listed with their reasons in CLAUDE.md. -->

- [ ] this touches an invariant, a file under `policy/`, or something in
      `agent/` - explained below

<!-- Otherwise delete this section. -->
