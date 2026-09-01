# Agent Note: Fork-hosted CI replacement

Status: implemented

English | [中文](2026-08-26-fork-hosted-ci-replacement.zh.md)

## Problem

[CI](../../../../.github/workflows/ci.yml) binds its static, coverage, consumer, and native-Windows jobs to private runner labels (`dsh-ubuntu-24-04-16core`, `dsh-windows-2025-16core`). This fork cannot allocate those pools, so those jobs queue indefinitely and `all checks passed` never settles. Branch protection that requires that aggregate therefore never completes.

Disabling the upstream `CI` workflow in the Actions tab removes the deadlock. The remaining hosted jobs in that same file — Node 22.19 / 26 compatibility, the Python SDK suite, the release-shaped Linux x64 Python runtime builder, and the Wine Windows lane — then stop running as well, because they live in the disabled workflow rather than in a portable file.

Editing `ci.yml` to retarget those private-runner jobs onto `ubuntu-latest` would restore a signal, but every upstream sync of that frequently changing file would conflict.

## Decision

[`.github/workflows/fork-ci.yml`](../../../../.github/workflows/fork-ci.yml) is the required pull-request and `dev/compat` push gate on `onlyfeng/deepseek-harness`. The file does not exist upstream, so merging `master` does not conflict with it. Operators disable the upstream `CI` and `CI master` workflows on this fork; both bind jobs to private runner labels this fork cannot allocate. The workflow files themselves stay unmodified.

`fork checks passed` depends on every job this workflow can run on standard hosted runners:

- `static` runs `pnpm run check:ci:static` with complete history and `DSH_ARCHIVE_BASE_REF` (the pull-request base SHA, or `github.event.before` on a `dev/compat` push), then `build:lib:host`, then `typecheck:contracts-ready` and `lint:contracts-ready`. The static aggregate owns runtime-closure, workspace constraints, package invariants, Cordis config, documentation, catalogs, module-graph, and `knip`; typecheck and lint stay in this job because the static aggregate does not own them. Client tsc resolves generated Typert remotes under package `remote` subpaths, so the Host contract build must precede it — the same `typertContractsGate()` ordering the upstream consumer lane uses.
- `snapshots` prepares bubblewrap with `scripts/prepare-ci-bubblewrap.sh`, installs Playwright Chromium with `--with-deps` (lib-mode `test:snapshot` includes `apps/web/tests/**/*.snapshot.ts`), then runs the same official `pnpm run build` plus `DSH_EXAMPLE_MODE=lib` `test:snapshot` graph as `snapshotGate()`, with `--testNamePattern` taken from `DSH_SNAPSHOT_NAME_PATTERN` (`^(?!.*pwsh-tool-turn)`) so both hosted pwsh headless runs are omitted. The pattern is an environment value so a YAML `run` string cannot expand `!`. Lib-mode Web snapshots request `workspace-write` and refuse to run unconfined; ACP and headless sessions without a usable sandbox backend inject a `danger-full-access` runtime-context snapshot that fixtures recorded with a sandbox do not contain. Hosted Ubuntu images ship `pwsh`, so both `pwshOnly` scenarios would otherwise execute: the persistent PTY returns shell-init scrollback instead of command output, and one-shot `pwsh-tool-turn` emits `permission/preset` pin events that the committed fixture does not contain. The committed fixtures are not rewritten to those hosted results. The job sets `DSH_SNAPSHOT_MAX_CONCURRENCY=1` so the DeepSeek SSE keep-alive comment test is not starved by parallel snapshot files. Fixture guards still cover `snapshots/session/persistent-pwsh-tool-turn/` and `snapshots/session/pwsh-tool-turn/`. Local `pnpm run test:snapshot` still executes both scenarios. The skip lives in [`fork-ci.yml`](../../../../.github/workflows/fork-ci.yml) only: `snapshot.yml` rejects unknown fields, and editing `session-snapshot` would conflict on every sync.
- `artifacts` runs `pnpm run check:ci:artifacts` (official `pnpm run build`, then publint, built-package invariants, `verify-node-next-types`, and built-bin smokes), then `pnpm run duplication` and `doc-typecheck:contracts-ready` with `DSH_DOC_TYPECHECK_USE_BUILD_OUTPUT=1`. After that official build it prepares bubblewrap with `scripts/prepare-ci-bubblewrap.sh`, installs Playwright Chromium with `--with-deps` (the same hosted path the upstream consumer job uses), and runs `DSH_SNAPSHOT=replay pnpm run test:web:ci`. `scripts/run-web-snapshots.ts` runs `apps/web/tests/built-boot.expected.e2e.ts` before `hmr-live.e2e.ts` because that digest hashes official `apps/web/dist` and `lib/client.js`, and `dev:web` rewrites those trees. Lib-mode Web snapshots request `workspace-write` and refuse to run unconfined. Hosted `ubuntu-latest` has 4 CPUs, so `DSH_WEB_SNAPSHOT_WORKERS` is `2` (upstream uses `6` on the 16-core pool). The job does not run `check:ci:consumers`: that aggregate also repeats snapshots and node-compat.
- `node-compat` runs `check:node-compat` on Node 22.19, Node 24, and Node 26. The 22.19 and 26 jobs reproduce the hosted upstream matrix. Node 24 covers the source-worker, Zstandard, source-launch, and jsdom smokes that `ciConsumerGates()` ran on the disabled consumer lane; `check:ci:artifacts` and `check:ci:snapshot` do not include them.
- `python-sdk` runs the keyless Python 3.10 SDK suite.
- `python-runtime` calls the shared [single-executable builder](../../../../.github/workflows/build-exe-for-python-sdk.yml) for `node24-linux-x64` with `ci: true` and maps `secrets.DEEPSEEK_API_KEY_EXTERNAL`, matching the [required Python runtime job](../../archived/testing/2026-08-12-required-python-runtime-pull-request-ci.md). Reusable workflows receive named secrets only when the caller passes them. Pull-request events skip the installed-wheel live-API preflight because this GitHub fork sets `head.repo.fork`; a `dev/compat` push runs that preflight and fails if the secret is empty.
- `windows` runs `scripts/wine-windows-gates.sh` on `ubuntu-latest`, matching the blocking Wine lane in [the portable pull-request CI record](2026-07-23-portable-required-pull-request-ci.md).

The workflow does not run `check:ci:coverage` or `pnpm run test`. Those suites include `packages/terminal` and `packages/shell` integration tests that require a tuned PTY / PowerShell runner and fail on GitHub-hosted images, and the repository Vitest `projects` configuration cannot exclude them from the CLI without editing the upstream Vitest config. `windows-native` stays omitted because it still requires the private Windows runner.

Each job is guarded with `github.repository == 'onlyfeng/deepseek-harness'` so a fork of this fork does not inherit the gate under the wrong repository. The aggregate uses `if: always()` so a failed or skipped dependency fails the required check instead of counting as a skip-pass.

## Alternatives considered

**Retarget `ci.yml` private-runner jobs onto `ubuntu-latest`.** This restores the upstream workflow as the gate, but `ci.yml` changes frequently upstream and every sync would conflict on the `runs-on` expressions.

**Keep only build, typecheck, and lint in the replacement.** That leaves Cordis-config, package-invariant, documentation, catalog, and module-graph failures able to merge, and it treats typecheck plus lint as equivalent to `check:ci:static`, which they are not.

**Invoke `pnpm run test:snapshot` after a Host-only `build:lib:host`.** Unset `DSH_EXAMPLE_MODE` selects source mode, and `vitest.snapshot.config.ts` then omits assembled Web snapshots. Broken package exports, Client bundles, or Web output can pass.

**Run `typecheck:contracts-ready` without `build:lib:host`.** Client tsc resolves generated Typert remotes such as `@deepseek-ai/dsh-commands/remote`. Those files exist only after the Host contract build; the static aggregate does not emit them.

**Run `check:ci:snapshot` without preparing bubblewrap.** Lib-mode Web snapshots refuse `workspace-write` when no sandbox backend is usable. ACP and headless sessions then inject a `danger-full-access` runtime-context snapshot that fixtures recorded with bubblewrap do not contain.

**Run `check:ci:consumers` as the replacement for the private consumer job.** That aggregate repeats `snapshotGate()` and `check:node-compat`, which this workflow already owns as separate jobs.

**Omit Playwright web snapshots because Chromium is not on the stock Node image.** The upstream consumer job already installs Chromium with `playwright install --with-deps` on Ubuntu. Lib-mode `test:snapshot` includes `apps/web/tests/**/*.snapshot.ts`, so the snapshots job installs Chromium as well. Without those lanes, UI, HMR, settings, approval, and conversation regressions satisfy `fork checks passed`.

**Run `test:web:ci` after installing Chromium but without preparing bubblewrap.** Lib-mode Web snapshots request `workspace-write` and refuse to run unconfined, so hosted Playwright fails with a sandbox-backend error instead of asserting the recorded UI.

**Keep the steer-all mid golden on the pre-composer frame (textarea + Stop generating).** `captureStableAria` polls until two consecutive frames match. On a quiet hosted runner the question composer arrives inside that poll, so the committed pre-composer tree is not a stable milestone. The mid snapshot waits for `[data-question-key]` first, matching the single-steer scenario.

**Add a skip field to `snapshot.yml` or `session-snapshot`, or refresh the pwsh goldens from hosted replay.** The YAML parser rejects unknown fields, and `session-snapshot` is an upstream package that would conflict on every sync. The live hosted persistent result is shell-init scrollback, not `PWSH_OK`; recording that output would pin a broken PTY. One-shot `pwsh-tool-turn` emits `permission/preset` pin events that the committed fixture does not contain; rewriting that golden on the fork would conflict on every master merge. Changing prompt settlement is product terminal behavior; the same hosted PTY class is why coverage and the terminal/shell unit suites stay omitted. Both hosted `pwshOnly` scenarios are omitted through `DSH_SNAPSHOT_NAME_PATTERN` in [`fork-ci.yml`](../../../../.github/workflows/fork-ci.yml). Fixture guards still cover the committed files. Local `pnpm run test:snapshot` still executes both scenarios.

**Omit `DEEPSEEK_API_KEY_EXTERNAL` from the reusable `python-runtime` call, or switch that call to `release: true`.** Reusable workflows do not inherit caller secrets. `ci: true` is required for the builder's plan job; `release: true` is the Python release builder. Pull-request events already skip the live-API preflight on this GitHub fork (`head.repo.fork`); a `dev/compat` push runs it and fails if the mapped secret is empty.

**Drop `built-boot.expected.e2e.ts` from `test:web:ci` serialFiles.** That digest hashes official `apps/web/dist` and `lib/client.js`. `hmr-live` starts `dev:web`, which rewrites those trees, so the digest must run first.

**Reproduce only the hosted Node 22.19 / 26 matrix.** That matches `ci.yml`'s `node-compat` job and omits the Node 24 `check:node-compat` smokes the disabled consumer lane ran. A Node-24-only failure in source-worker, Zstandard, source-launch, or jsdom then satisfies `fork checks passed`.

**Omit the hosted Python SDK or Python runtime jobs.** Those jobs already run on `ubuntu-latest` in upstream CI. Disabling that workflow without reproducing them drops both Python distribution checks from the required verdict.

**Run `check:ci:coverage` on hosted runners and isolate the flaky suites with Vitest CLI `--exclude`.** The repository uses Vitest `projects`, so CLI `--exclude` does not apply across projects. Excluding those suites requires editing the upstream Vitest config, which reintroduces a sync conflict.

## Consequences

Pull requests and `dev/compat` pushes on this fork wait for `fork checks passed` instead of the upstream `all checks passed` aggregate. The replacement covers every hosted upstream job plus the static, snapshot, artifact, and Playwright web-snapshot aggregates that private runners previously owned. Exhaustive unit coverage, native Windows, and both hosted pwsh headless scenarios remain local or upstream-private-runner evidence; a regression confined to those suites can still merge here. Operators who need a green `dev/compat` push must store a non-empty `DEEPSEEK_API_KEY_EXTERNAL`; pull-request `python-runtime` already skips that live-API preflight on this fork.
