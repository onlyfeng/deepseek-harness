# Agent Note: Fork 托管 CI 替代方案

Status: implemented

[English](2026-08-26-fork-hosted-ci-replacement.md) | 中文

## 问题

[CI](../../../../.github/workflows/ci.yml) 将其静态、覆盖率、consumer 与原生 Windows 作业绑定到私有 runner 标签（`dsh-ubuntu-24-04-16core`、`dsh-windows-2025-16core`）。本 fork 无法分配这些池，那些作业会无限排队，`all checks passed` 也永远不会结束。要求该聚合结果的分支保护因此无法完成。

在 Actions 选项卡中禁用上游 `CI` 工作流可以解除死锁。同一文件里其余已在托管 runner 上运行的作业——Node 22.19 / 26 兼容性、Python SDK 套件、发布形态的 Linux x64 Python runtime 构建器，以及 Wine Windows 通道——随后也会停止运行，因为它们属于被禁用的工作流，而不在可移植文件中。

把 `ci.yml` 里这些私有 runner 作业改到 `ubuntu-latest` 可以恢复信号，但该文件在上游变动频繁，每次同步都会在 `runs-on` 表达式上冲突。

## 决策

[`.github/workflows/fork-ci.yml`](../../../../.github/workflows/fork-ci.yml) 是 `onlyfeng/deepseek-harness` 上拉取请求与 `dev/compat` 推送的必需门禁。该文件在上游不存在，因此合并 `master` 不会与它冲突。操作者在本 fork 上禁用上游 `CI` 工作流；工作流文件本身保持未修改。

`fork checks passed` 依赖本工作流能在标准托管 runner 上运行的每一项作业：

- `static` 在完整历史与 `DSH_ARCHIVE_BASE_REF`（拉取请求的 base SHA，或 `dev/compat` 推送上的 `github.event.before`）下运行 `pnpm run check:ci:static`，然后运行 `build:lib:host`，再运行 `typecheck:contracts-ready` 与 `lint:contracts-ready`。静态聚合拥有 runtime-closure、workspace 约束、package invariant、Cordis 配置、文档、catalog、module-graph 和 `knip`；typecheck 与 lint 留在本作业中，因为静态聚合并不拥有它们。Client tsc 会解析包 `remote` 子路径下生成的 Typert remote，因此 Host 契约构建必须先于它——与上游 consumer 通道的 `typertContractsGate()` 顺序相同。
- `snapshots` 先用 `scripts/prepare-ci-bubblewrap.sh` 准备 bubblewrap，再运行 `pnpm run check:ci:snapshot`（一次完整的官方 `pnpm run build`，随后以 `DSH_EXAMPLE_MODE=lib` 运行 `test:snapshot`）——与上游 consumer 通道使用的同一个 `snapshotGate()`，包括源码 mode 会省略的组装后 Web 快照。Lib-mode Web 快照会请求 `workspace-write` 并拒绝在无隔离环境下运行；ACP 与 headless 会话在没有可用 sandbox 后端时会注入 `danger-full-access` 运行时上下文快照，而这与带 sandbox 录制的 fixture 不一致。托管 Ubuntu 镜像自带 `pwsh`，因此 `pwshOnly` ACP 场景会实际运行，其 header 必须与当前工具描述一致。该作业设置 `DSH_SNAPSHOT_MAX_CONCURRENCY=1`，以免并行快照文件饿死 DeepSeek SSE keep-alive 注释测试。`persistent-pwsh-tool-turn` 在 `RUNNER_ENVIRONMENT` 为 `github-hosted` 时设置 `skipRun`：持久 PTY 返回的是 shell 初始化回滚缓冲而不是命令输出，已提交 fixture 不会被改写成该结果。
- `node-compat` 复现托管的 Node 22.19 与 Node 26 兼容性冒烟测试。
- `python-sdk` 运行无密钥的 Python 3.10 SDK 套件。
- `python-runtime` 以 `ci: true` 调用共享的[单文件可执行文件构建器](../../../../.github/workflows/build-exe-for-python-sdk.yml) 构建 `node24-linux-x64`，与[必需的 Python runtime 作业](../testing/2026-08-12-required-python-runtime-pull-request-ci.zh.md)一致。
- `windows` 在 `ubuntu-latest` 上运行 `scripts/wine-windows-gates.sh`，与[可移植拉取请求 CI 记录](2026-07-23-portable-required-pull-request-ci.zh.md)中的阻塞式 Wine 通道一致。

本工作流不运行 `check:ci:coverage` 或 `pnpm run test`。这些套件包含 `packages/terminal` 与 `packages/shell` 集成测试，它们依赖调校过的 PTY / PowerShell runner，并在 GitHub 托管镜像上失败；仓库的 Vitest `projects` 配置也无法在不编辑上游 Vitest 配置的情况下用 CLI 排除它们。`windows-native` 仍然省略，因为它仍需要本 fork 没有的私有 Windows runner。

每项作业都以 `github.repository == 'onlyfeng/deepseek-harness'` 作为守卫，使本仓库的再 fork 不会在错误仓库下继承该门禁。聚合作业使用 `if: always()`，因此失败或跳过的依赖会让必需检查失败，而不是被计为 skip-pass。

## 曾考虑的替代方案

**把 `ci.yml` 的私有 runner 作业改到 `ubuntu-latest`。** 这会让上游工作流重新成为门禁，但 `ci.yml` 在上游变动频繁，每次同步都会在 `runs-on` 表达式上冲突。

**在替代方案中只保留 build、typecheck 和 lint。** 这会让 Cordis 配置、package invariant、文档、catalog 和 module-graph 失败仍能合并，并把 typecheck 加 lint 当成与 `check:ci:static` 等价，而它们并不等价。

**在仅 Host 的 `build:lib:host` 之后直接调用 `pnpm run test:snapshot`。** 未设置 `DSH_EXAMPLE_MODE` 会选择源码 mode，随后 `vitest.snapshot.config.ts` 会省略组装后的 Web 快照。损坏的包导出、Client bundle 或 Web 输出仍可通过。

**在没有 `build:lib:host` 的情况下运行 `typecheck:contracts-ready`。** Client tsc 会解析生成的 Typert remote（例如 `@deepseek-ai/dsh-commands/remote`）。这些文件只在 Host 契约构建之后存在；静态聚合不会产出它们。

**在未准备 bubblewrap 的情况下运行 `check:ci:snapshot`。** 没有可用 sandbox 后端时，lib-mode Web 快照会拒绝 `workspace-write`。ACP 与 headless 会话随后会注入 `danger-full-access` 运行时上下文快照，而这与带 bubblewrap 录制的 fixture 不一致。

**省略托管的 Node-compat、Python SDK 或 Python runtime 作业。** 这些作业在上游 CI 中已经运行在 `ubuntu-latest` 上。禁用该工作流却不复现它们，会从必需判定中丢掉最低支持的 Node 版本线以及两项 Python 分发检查。

**在托管 runner 上运行 `check:ci:coverage`，并用 Vitest CLI `--exclude` 隔离不稳定套件。** 本仓库使用 Vitest `projects`，因此 CLI `--exclude` 不会跨 project 生效。排除那些套件需要编辑上游 Vitest 配置，从而再次引入同步冲突。

## 后果

本 fork 上的拉取请求与 `dev/compat` 推送等待 `fork checks passed`，而不是上游的 `all checks passed` 聚合。该替代方案覆盖每一项托管的上游作业，以及原先由私有 runner 拥有的静态与快照聚合。穷尽单元覆盖率、原生 Windows、Playwright Web 快照以及持久 pwsh PTY ACP 场景仍是本地或上游私有 runner 上的证据；仅限于那些套件的回归在此仍可能合并。托管 Ubuntu 镜像包含 `pwsh`，因此一次性 `pwshOnly` ACP header 必须与当前的 job 工具和 pwsh 工具描述保持一致。
