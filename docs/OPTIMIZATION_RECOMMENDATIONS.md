# Sourcetree 桌面客户端优化建议

> 文档日期：2026-09-07
>
> 代码基线：`d564e90`（本文初始检查时的 `main` HEAD）
>
> 适用范围：`lib/`、`test/`、`integration_test/`、`macos/`
>
> 文档性质：现状评估与实施建议，不替代项目路线图

## 1. 文档定位

本文基于当前 `main` 分支的代码、测试和既有实施规划，整理下一阶段的优化方向、优先级、
验收标准与建议顺序。

`docs/IMPLEMENTATION_PLAN.md` 仍是项目唯一的路线图和任务状态来源。本文不独立维护功能完成
状态；任何建议进入实际开发后，都应在 `docs/IMPLEMENTATION_PLAN.md` 中登记、更新和验收。

## 2. 当前基线

本文的初始检查于 2026-09-06 在 `d564e90` 上完成。当时项目处于 P1 MVP 垂直闭环阶段，核心
Git 工作流、安全边界和测试基础已经较完整。检查结果如下：

- `flutter analyze` 通过，无静态分析问题。
- `flutter test` 通过，共执行 337 项测试。
- 检查开始前工作区干净，`main` 与 `origin/main` 同步；这不是当前工作区状态声明。
- 已具备临时真实 Git 仓库测试、取消机制、敏感信息脱敏和多窗口生命周期测试。
- 已定义启动、历史、状态刷新、帧时间、内存和 CPU 性能预算，但尚未形成持续执行的基准体系。
- 尚未发现仓库内的持续集成工作流。

当前主要风险不是基础质量失控，而是功能持续增长后产生的结构复杂度、开发回归不可见和大仓库
性能缺少持续测量。

## 3. 优化目标

下一阶段建议围绕以下目标展开：

1. 将现有测试能力转化为自动化质量门禁。
2. 在不改变用户可见行为和 Git 契约的前提下降低核心代码维护成本。
3. 将性能预算转化为可重复、可对比、可阻断回归的测量结果。
4. 优先复用已交付能力，减少低价值的“待实现”入口。
5. 在开放外部工具和高级集成前建立明确的仓库信任边界。

本轮优化不建议同时进行大规模视觉重设计、跨平台迁移或 Git 执行层替换。

## 4. 优先级总览

| 优先级 | 方向 | 主要收益 | 主要风险 | 建议时机 |
| --- | --- | --- | --- | --- |
| P0 | CI 质量门禁 | 防止合并后回归 | macOS Runner 配置与测试隔离 | 立即 |
| P1 | 核心模块行为中性拆分 | 降低修改和评审成本 | 拆分时破坏异步生命周期 | CI 基线稳定后 |
| P1 | 性能基准与回归门禁 | 避免大仓库体验退化 | fixture 成本和机器噪声 | 与拆分并行准备 |
| P2 | 已有能力的菜单接入 | 提升完成度和可发现性 | 多窗口状态路由错误 | 上述基础完成后 |
| P2 | 仓库信任模型 | 为外部工具和高级集成铺路 | 安全策略过松或误阻断 | 高级功能之前 |

## 5. 优化一：拆分核心模块

### 5.1 现状

当前维护成本集中在少数大型文件：

| 文件 | 当前规模约值 | 主要职责 |
| --- | ---: | --- |
| `lib/src/app/git_desktop_app.dart` | 7656 行 | 应用入口、工作区协调、菜单动作和大量对话框 |
| `lib/src/presentation/repository_overview.dart` | 6968 行 | 引用、历史、Graph、Changes、Diff、详情和状态页 |
| `lib/src/app/repository_session.dart` | 4841 行 | 仓库状态、选择、远端、文件、冲突、分支、标签和贮藏操作 |
| `lib/src/git/git_repository_writer.dart` | 3145 行 | Git 写操作、补丁、路径校验和安全文件处理 |
| `macos/Runner/AppDelegate.swift` | 1879 行 | 应用生命周期、窗口协调、菜单和原生桥接 |

大型文件本身并不必然造成缺陷，但当前职责数量已经使局部改动需要理解过多无关状态，尤其容易
影响异步 generation、取消、窗口关闭和写后刷新边界。

### 5.2 拆分原则

- 保持用户可见行为、Riverpod 对外接口、Git argv 和错误语义不变。
- 先补 characterization test，再移动代码。
- 每次只拆一个能力边界，不在同一提交中加入新功能或视觉改造。
- `RepositorySessionController` 可继续作为 facade，避免 UI 直接依赖多个执行服务。
- 不在拆分过程中引入第二套状态管理框架。
- 所有异步子模块共享明确的 repository generation、取消和 shutdown 协议。
- `RepositorySessionController` 的私有状态不能因为跨文件拆分而改为公开。实施前必须选定
  `part` 共享 library，或只向子服务暴露最小内部 port；两种方式均需明确所有权和生命周期。

### 5.3 建议结构

应用层可逐步拆分如下。以下目录仅表达能力边界；文件之间应采用上节约定的 `part` 或最小内部
port，不能通过公开 controller 内部字段来共享状态：

```text
lib/src/app/repository/
  repository_session.dart
  repository_session_state.dart
  repository_task_tracker.dart
  repository_remote_operations.dart
  repository_worktree_operations.dart
  repository_history_controller.dart
  repository_ref_operations.dart
  repository_stash_operations.dart
  repository_conflict_operations.dart
```

界面层可逐步拆分为：

```text
lib/src/presentation/repository/
  repository_overview.dart
  toolbar/
  refs/
  history/
  changes/
  diff/
  details/
  loading/
  dialogs/
```

Git 写入层建议按能力组合对象，而不是简单按文件行数切割：

```text
lib/src/git/write/
  git_remote_writer.dart
  git_ref_writer.dart
  git_worktree_writer.dart
  git_history_writer.dart
  git_patch_writer.dart
  secure_file_operations.dart
```

原生层可将窗口协调、菜单路由、恢复持久化和 AskPass 桥接拆为独立 Swift 类型；
`AppDelegate` 只保留应用生命周期组装和系统回调入口。

### 5.4 验收标准

- 拆分前后 `flutter analyze` 和现有测试全部通过。
- Git 命令参数、错误分类、写后刷新范围和菜单可用状态不变。
- 快速打开/关闭多个仓库窗口时，不出现已销毁 Engine 回写状态。
- 每个新模块存在明确职责说明和中英双语 DartDoc。
- 新文件之间没有形成循环依赖。
- 单次拆分应保持可独立评审和回退。

第一阶段已将 Engine 关闭屏障、任务追踪和取消令牌的实际所有权抽到
`repository_session_tasks.dart`；它通过 Dart `part` 保持 controller 的私有 library 边界，
`RepositorySessionController` 仍是唯一 facade，公开接口与 generation 语义不变。

## 6. 优化二：建立持续集成质量门禁

### 6.1 建议流水线

每个合并请求至少运行：

```sh
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test
flutter build macos --debug
```

根据 macOS Runner 的执行成本，将验证分层：

- PR 必跑：格式、静态分析、Dart 单元测试、Widget 测试、Debug 构建。
- 主分支必跑：macOS Runner 原生单元测试和核心本地 Git 工作流。
- 定时任务：完整 macOS `integration_test`、多窗口生命周期和 AskPass 链路。

### 6.2 覆盖率策略

不建议仅设置一个全局行覆盖率数字。优先对以下高风险边界设置覆盖要求：

- Git 状态、引用、历史和 Diff 解析器。
- Git argv、pathspec 和环境变量构造。
- 敏感信息脱敏。
- repository generation、latest-wins 和 shutdown。
- 写操作的成功、失败、取消、冲突和部分成功。
- 原生菜单只作用于当前 key workspace 的路由规则。

### 6.3 验收标准

- 已提供 `.github/workflows/quality.yml`：PR 和 `main` 推送运行格式、分析、Flutter 测试和
  macOS Debug 构建；非 PR 的 `main` 任务运行 XCTest；定时和手动任务运行 macOS 核心集成测试。
- 未格式化代码、静态分析问题和测试失败均阻止合并。
- CI 不依赖开发者私有仓库、凭据、固定绝对路径或公网 Git 服务。
- 测试使用隔离的临时 HOME、Git 配置和本地 bare remote。
- 失败产物保留必要日志，但必须经过脱敏。
- 慢测试和偶发测试有独立统计，不能通过无条件重试掩盖。

## 7. 优化三：建立性能基准

### 7.1 原则

先测量，再优化。不得仅凭文件规模或主观卡顿替换 Git 实现、增加缓存或引入常驻进程。

### 7.2 建议数据集

建立可重复生成、无需网络的三档仓库：

| 档位 | 用途 | 建议规模 |
| --- | --- | --- |
| Small | 日常快速回归 | 1000 commits、1000 files、20 refs |
| Medium | PR 性能抽检 | 10000 commits、10000 files、200 refs |
| Stress | 定时性能评估 | 100000 commits、100000 files、1000 refs、10000 changes |

fixture 生成器应固定随机种子，并记录 Git、Flutter、macOS、CPU 和构建模式。

当前提供 `tool/benchmark_repository.dart` 作为只读采样入口：它重复读取 status、refs 和固定
快照中的 500 条历史，并输出每轮与 median/P95 JSON 结果。`tool/generate_benchmark_fixture.dart`
以固定 seed 离线生成 Small、Medium、Stress 三档数据集；它只接受不存在或空目录，并隔离
Git 配置、hooks 与网络。大规模 Stress fixture 仍应只在定时性能任务中生成和保存。

Small fixture 的首次可重复参考机采样与环境记录在
[PERFORMANCE_BASELINE.md](PERFORMANCE_BASELINE.md)。它仅建立 Git 读取基线，不应被解释为
Medium/Stress、启动、UI 帧时间、内存或 CPU 预算的完成声明。

### 7.3 建议指标

- 冷启动和热启动到可交互时间。
- 仓库识别、status、refs、首屏历史和首个 Diff 的分项耗时。
- 历史继续加载和搜索筛选耗时。
- Changes 大列表滚动帧时间和内存峰值。
- Diff 快速切换时的取消延迟、过期结果丢弃数量和峰值进程数。
- 单仓库与多窗口空闲内存、CPU 和文件描述符数量。
- Fetch/Pull/Push 期间 UI 帧时间及取消后进程树清理时间。

### 7.4 针对性优化候选

以下方案只能在基准确认热点后实施：

- 对对象批量读取引入长驻 `git cat-file --batch`，并补齐取消和 shutdown 契约。
- 将大型 Graph 或 patch 解析移入 isolate。
- 对 refs、历史和 Diff 使用精确失效范围，避免全会话重复读取。
- 对文件列表、历史和 Diff 保持虚拟化，避免嵌套滚动导致全部子项构建。
- 测量现有文件监听、焦点校准与事件合并策略，再按数据调整冷却时间、最大等待和失效范围。
- 只缓存可由 Git 结果验证或安全失效的只读数据。

### 7.5 验收标准

沿用实施规划中的预算：

- 冷启动可交互 P95 不超过 3 秒，热启动不超过 1.5 秒。
- 大仓库首屏 500 条历史 P95 不超过 2.5 秒。
- 大仓库状态刷新总计不超过 5 秒，应用额外开销不超过 500ms。
- 主线程不连续阻塞 100ms，滚动 P95 frame time 不超过 24ms。
- 普通仓库空闲内存不超过 350MB，大仓库不超过 800MB。
- 相对已记录基线回退超过 15% 时阻止合并，除非记录明确豁免原因。

## 8. 优化四：减少待实现入口

当前 Flutter 上下文菜单和 macOS 原生菜单仍保留较多“（待实现）”入口。为提升完成度，建议
优先接入已经存在应用层能力、风险较低且符合高频工作流的项目。

### 8.1 建议顺序

1. 原生菜单复用现有 Refresh、Commit、Fetch、Pull、Push、Branch、Tag 和 Stash。
2. 接入 Finder 定位、复制路径、Quick Look 和打开文件。
3. 接入添加到索引、取消暂存和已有的停止追踪流程。
4. 完善多个 workspace 快速切换后的菜单状态同步和过期快照失效。
5. 再考虑 ignore、复制、移动、内置审查和文件历史。

Submodule、Subtree、LFS、Git-flow、外部 Diff、自定义操作和托管平台 API 应继续后置，因为它们
会扩大可执行代码、认证、兼容性和远端状态边界。

当前已接入 Refresh、Fetch、Pull、Push、Commit、Branch 与 Stash：均使用稳定 action ID，只路由到
当前 key workspace；这些动作的 AppKit 启用状态来自该 Engine 的 Flutter capability 快照，Flutter
在打开现有对话框前再次校验。

### 8.2 验收标准

- 菜单动作只作用于当前 key workspace。
- Flutter 与原生菜单消费同一份能力判断，不重复维护 Git 安全规则。
- workspace 切换、关闭和 Engine 销毁后，原生菜单不会使用过期选择。
- 未交付入口继续在可见 label 中保留“（待实现）”。
- 已交付入口在实现、测试和文档同步完成后统一移除该标记。

## 9. 优化五：仓库信任模型

### 9.1 背景

Git hooks、filters、credential helper、`core.sshCommand`、external diff 和 textconv 都可能执行
外部程序。随着外部工具、自定义动作和托管平台能力增加，仅依赖操作确认不足以覆盖全部风险。

### 9.2 建议能力

- 为仓库记录“未确认、信任、受限”状态，不根据目录位置自动推断信任。
- 首次触发可执行扩展前展示实际来源、命令类别和作用范围。
- 受限模式下禁用 external diff、textconv、自定义操作及其他非核心可执行扩展。
- 明确展示使用中的 Git executable、credential helper、SSH 配置来源和 hooks 状态。
- 提供脱敏诊断导出，不包含 token、密码、私钥、认证 Header 或 prompt 回答。
- 信任状态只控制应用选择启用的扩展，不伪造、覆盖或修改 Git 的真实配置。

当前已在“仓库详情…”交付按 Git common-dir/worktree 身份保存的未确认、信任、受限选择：默认
未确认，用户可撤销为受限；持久化记录不保存命令、凭据、hooks、SSH 或远端 URL。外部扩展尚未
交付，因此它们不会因信任状态而被静默执行。

### 9.3 验收标准

- 未信任仓库不能通过 UI 静默执行自定义外部命令。
- 信任选择具有明确范围并可撤销。
- 核心只读 Git 查询与安全模式的行为边界有测试覆盖。
- 应用不会静默修改 global/system Git 配置或 `safe.directory`。

## 10. 推荐实施节奏

### 迭代 A：工程基线

- 引入 PR、主分支和定时 CI。
- 固化临时 Git 仓库、目录监听和多窗口生命周期的可重复验证。
- 记录当前测试时长、慢测试排行和已知测试限制。

### 迭代 B：质量门禁

- 建立测试分层、失败产物和脱敏规则。
- 为 Git parser、写操作、关闭屏障和菜单路由设置重点覆盖要求。
- 将自动刷新现有的事件合并、冷却和焦点校准参数纳入可观测指标。

### 迭代 C：行为中性拆分

- 优先拆分 `RepositorySessionController` 的任务跟踪和远端操作。
- 再拆分对话框、Repository Overview 子区域和 Git writer。
- 每个拆分提交均运行静态分析、相关测试和完整 Flutter 测试。

### 迭代 D：性能与菜单完成度

- 建立 Small/Medium/Stress fixture 和性能采集。
- 根据数据优化真实热点。
- 接通原生菜单 M1 中低风险且已有应用层能力的动作。

## 11. 风险控制

| 风险 | 控制方式 |
| --- | --- |
| 重构改变 Git 行为 | 保持 facade 和 argv 不变；先补 characterization test |
| 异步任务在窗口关闭后回写 | 统一 generation、取消、shutdown 和 Engine 生命周期协议 |
| CI 只在特定机器通过 | 隔离 HOME/Git 配置；使用本地 bare remote 和固定 fixture |
| 性能数字受机器波动影响 | 固定参考机和性能专用编译配置；比较 median/P95 和相对回退 |
| 菜单作用到后台仓库 | 只消费 key workspace 快照并验证 Engine/session generation |
| 外部工具扩大攻击面 | 先建立仓库信任模型，再开放自定义执行能力 |

## 12. 完成定义

本轮优化可在满足以下条件后视为完成：

- PR 合并受格式、静态分析和测试门禁保护。
- 核心大型模块完成至少第一阶段行为中性拆分，且没有新增循环依赖。
- 性能预算存在可重复执行的 fixture、采集方式和基线结果。
- 高频原生菜单动作复用现有应用层能力，不再重复实现 Git 规则。
- 高级外部集成具备明确的仓库信任前置条件。
- `README.md`、`docs/IMPLEMENTATION_PLAN.md` 和 `RELEASE_NOTES.md` 与最终实际行为同步。
