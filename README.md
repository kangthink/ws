# ws

Workspace maintenance CLI tool.

Scans `~/workspace` for stale projects and cleans up dependency directories (`node_modules`, `.venv`, `__pycache__`, etc.) to reclaim disk space.

## Usage

```bash
ws status                     # workspace summary
ws clean --dry-run             # preview reclaimable space
ws clean                       # clean with confirmation
ws clean --months 3            # custom inactivity threshold
```

## Install

```bash
ln -sf ~/workspace/tool/ws/ws ~/bin/ws
```

## What gets cleaned

Only projects inactive for N months (default 6). Target directories:

`node_modules/` `.venv/` `venv/` `__pycache__/` `dist/` `.next/` `.turbo/` `.nuxt/` `coverage/` `.pytest_cache/` `.mypy_cache/`

iOS `build/` directories are automatically excluded.
