#!/usr/bin/env bash
# Cloud Agent bootstrap for DeepSeek Harness.
#
# Idempotent: re-running against a warm or partially prepared VM converges
# without side effects. Runs after the repository is checked out.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# --- Node -----------------------------------------------------------------
# package.json requires node ^22.19.0 || >=24.0.0; CI's primary version is 24.
# The base image's default `node` can be older, so pin node 24 through nvm and
# make it the login-shell default the interactive agent inherits.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"
nvm install 24
nvm alias default 24
nvm use 24

# --- pnpm -----------------------------------------------------------------
# pnpm is pinned by package.json "packageManager"; provide it via corepack.
corepack enable
corepack prepare pnpm@11.7.0 --activate

# `pnpm run`/`pnpm exec` default to re-running `pnpm install` whenever
# node_modules looks stale (verifyDepsBeforeRun=install). That re-runs the root
# postinstall scripts/install-lefthook.mjs, which correctly refuses to overwrite
# the Cursor-managed git core.hooksPath and exits non-zero — breaking every
# `pnpm run <script>` in a plain agent shell. Disable the pre-run check
# (deps are installed explicitly below and on demand with `pnpm install`).
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/pnpm"
config_file="$config_dir/config.yaml"
mkdir -p "$config_dir"
if ! grep -qs '^verifyDepsBeforeRun:' "$config_file"; then
  echo 'verifyDepsBeforeRun: false' >> "$config_file"
fi

# --- Dependencies ---------------------------------------------------------
# CI=true makes the lefthook git-hook postinstall no-op exactly as it does in
# GitHub CI (the hooks are a local pre-commit convenience the development docs
# mark safely skippable); every other lifecycle script still runs.
CI=true pnpm install --frozen-lockfile

echo "install.sh: node $(node --version), pnpm $(pnpm --version) — dependencies ready"
