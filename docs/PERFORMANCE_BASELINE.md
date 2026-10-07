# 性能基线

> 性能基线 / Performance baseline：记录可重复的测量口径、环境和限制。
> Records reproducible measurement definitions, environments, and limitations.

## 记录方式

本记录只描述可重复的 Git 读取采样，不代表 Flutter 首次绘制、滚动帧时间、内存或 CPU 预算已
达标。使用固定 seed 的离线 Small/Medium fixture，并由 `tool/benchmark_repository.dart` 读取 status、
refs 和固定 revision snapshot 的 500 条历史，同时记录 benchmark 进程的 resident set size（RSS）。

```sh
dart run tool/generate_benchmark_fixture.dart small /tmp/git-desktop-small 20260907
dart run tool/benchmark_repository.dart /tmp/git-desktop-small 5 --output baseline.json
dart run tool/benchmark_repository.dart /tmp/git-desktop-small 5 --baseline baseline.json
```

第二条命令的 P95 相对 `baseline.json` 回退超过默认 15% 时会失败。基线必须在相同的参考机、
Git、Flutter 和构建模式上更新；更新前须说明测量环境或已批准的豁免原因。不要把临时目录、
用户仓库、凭据或远端地址提交到仓库。

## Flutter UI 测量入口

首帧和历史滚动帧使用独立的 macOS integration test，避免把图形环境和机器差异引入普通 PR：

```sh
flutter test integration_test/macos_performance_test.dart -d macos
# profile 模式（通过 test_driver 桥接，需图形环境和可用的 Flutter VM service）
flutter drive --profile --no-pub --no-dds -d macos --target=integration_test/macos_performance_test.dart
# Engine/native 内存专项（需要 Instruments xctrace 与 footprint 权限）
./tool/profile_macos_memory.sh /private/tmp/git-desktop-macos-memory
# 汇总已保存的内存 JSON 和 Profile 报告，并校验预算与 trace 完整性
./tool/summarize_macos_performance.sh /private/tmp/git-desktop-macos-memory-followup \
  /private/tmp/git-desktop-macos-memory-followup/summary.md
```

测试使用 120 条提交及一个额外本地分支的临时本地仓库，通过 `watchPerformance` 报告首帧和滚动帧摘要，
并单独记录搜索防抖和引用导航的 UI 响应耗时，在
`macos_memory_samples` 中记录进程 RSS 的启动前、启动后和滚动后值；同时会向标准输出写入
`macos_performance_memory=…` JSON 行，并将完整结果写入系统临时目录
`git_desktop_macos_performance_report.json`，便于手动保存。测试还会尝试调用 Dart 原生 VM API
写出启动后和滚动后的 `.heapsnapshot`，并在 `heap_snapshots` 中记录路径、文件大小或不支持原因。
RSS 只是可重复的粗粒度观测；Dart heap snapshot 只覆盖 VM 堆，不代表包含 Flutter Engine/native
分配的完整 DevTools 应用内存快照。在固定参考机上实际运行并保存报告后，才能更新首帧、滚动 P95
和内存预算的验收结论。

`tool/profile_macos_memory.sh` 会为同一 Profile 场景设置测试专用协调目录，在初始提交预览完成和历史滚动
完成两个稳定点分别采集 macOS `footprint` 分类。脚本发现 Profile 应用进程后附加 Instruments Allocations
模板，并持续录制到目标进程正常退出；trace 包含 Allocations 和 VM Tracker，可覆盖附加后的 Flutter Engine、
Skia/Metal、IOSurface、原生插件与宿主分配，但不包含进程创建到附加成功前的完整分配调用记录。输出还包括
TOC、驱动日志及摘要 JSON；若 TOC 未记录 `Target app exited`，脚本会把该轮视为失败，避免接受截断 trace。
Instruments 会增加 `performance tool data` 等自身开销，因此应优先比较
同一 trace 内的阶段增量和类别变化，不能把单轮绝对值直接定为发布预算。trace/TOC 可能包含本机路径和进程
环境，只保存在受控临时目录，不提交或未经检查直接分享。

`tool/summarize_macos_performance.sh` 读取同一目录下的内存摘要 JSON 和保存的 Profile 报告，逐轮校验退出码、
TOC 结束原因及 Allocations/VM Tracker 条目，再计算中位数、样本 P95、最小值和最大值。它会检查启动可交互
3 秒与滚动构建 24ms 预算，并可将 Markdown 摘要写入指定路径；预算失败或样本校验失败时返回非零状态。

报告中的 `macos_search_performance` 验证搜索输入越过 220ms 防抖边界后的响应，
`macos_reference_navigation_performance` 验证点击本地分支后的状态刷新耗时；两者是墙钟采样，
不是发布预算。滚动测量会交替向上、向下执行 8 次 fling，并将所有动画帧合并计算精确 P95，避免列表到达边界
后重复采样空操作。报告同时记录 `scroll_samples`，便于比较不同运行的采样覆盖范围。

当前启动报告的 `interactive_definition` 为 `history_ready_before_initial_commit_preview`：状态、引用和首屏历史
ready 且完成一次绘制即停止启动计时，默认提交的文件摘要与首个 Diff 继续由关闭屏障跟踪的后台任务加载；测试在
采集启动后内存和滚动数据前仍明确等待该预览完成。2026-10-06 及更早的结果包含初始提交预览，因此只能保留为旧口径
历史记录；首次新口径 Profile 采样应建立独立基线，不直接计算相对回退。

## 2026-10-02 Flutter macOS 单次采样

本次采样在当前 Apple M4/macOS 图形环境完成，完整原始报告写入系统临时目录
`git_desktop_macos_performance_report.json`。它用于确认测量链路和发现明显回退，不作为稳定的
发布验收基线：启动阶段只采集到 2 帧，因此只记录首帧和到可交互的墙钟耗时，不把启动帧
伪装成 P95；RSS 也只是进程级粗粒度观测，不是 Flutter DevTools 应用内存快照。

| 项目 | 结果 |
| --- | ---: |
| Startup first frame build（2 帧样本中的首帧） | 396.513ms |
| Startup to interactive | 3,984.254ms |
| History scroll frame build P95（60 帧） | 17.594ms |
| History scroll frame build average | 7.838ms |
| RSS before startup | 245,219,328B |
| RSS after startup | 407,552,000B |
| RSS after history scroll | 411,844,608B |
| Startup RSS delta | 162,332,672B |
| Scroll RSS delta | 4,292,608B |

同一轮性能入口在 VM 支持 heap snapshot 的模式下另外生成了两份可导入 Dart DevTools 的快照：
启动完成后 `31,349,799B`，8 次交替历史滚动后 `34,602,980B`。快照只描述 Dart VM 堆，不能
代表 Flutter Engine、Skia、原生插件或系统窗口分配；原始 `.heapsnapshot` 保留在运行机的临时
目录，不提交到仓库。

后续仍需在固定 profile 构建和稳定采样窗口下重复首帧/可交互耗时，并补齐 DevTools 应用内存
快照，再决定是否更新预算验收状态。

同日追加的 8 次交替滚动采样得到 487 帧，历史滚动构建耗时 P95 为 13.533ms，滚动后 RSS
增量为 8,060,928B。该结果用于确认多轮测量链路已覆盖真实
滚动动画，不替代 profile 构建或 DevTools 内存快照验收。

## 2026-10-02 Flutter macOS Profile 单次采样

同一 Apple M4/macOS 图形环境使用 Flutter 3.47.1 / Dart 3.13.1，以
`flutter drive --profile --no-dds` 完成一次完整采样。Profile 驱动入口使用专用 binding，避免
当前 Flutter engine 已注册的 `ext.flutter.exit` 与标准 integration binding 重复注册；这只是
测试基础设施兼容处理，不改变应用运行时行为。

| 项目 | 结果 |
| --- | ---: |
| Startup first frame build（1 帧样本） | 100.714ms |
| Startup to interactive | 2,632.708ms |
| History scroll frame build P95（472 帧） | 3.878ms |
| History scroll frame build average | 1.238ms |
| RSS before startup | 146,178,048B |
| RSS after startup | 153,518,080B |
| RSS after history scroll | 192,397,312B |
| Startup RSS delta | 7,340,032B |
| Scroll RSS delta | 38,879,232B |
| Dart heap snapshot after startup | 11,233,942B |
| Dart heap snapshot after history scroll | 12,731,582B |

Profile 首帧只有一个样本，仍不作为稳定发布验收；RSS 与 Dart heap snapshot 也不包含完整的
Flutter Engine/native 分配。该采样确认 Profile 测量链路可运行，后续仍需固定参考机多轮采样和
DevTools 应用内存快照。

## 2026-09-07 Small 基线

| 项目 | 值 |
| --- | --- |
| macOS | 26.3.1（25D2128） |
| CPU | Apple M4 |
| Git | Apple Git 2.50.1 |
| Flutter / Dart | 3.47.1 / 3.13.1 |
| fixture | seed `20260907`；1,000 commits、1,000 files、20 tags、0 未提交改动 |
| iterations | 5 |
| status P95 | 92ms |
| refs P95 | 47ms |
| 500 条历史 P95 | 203ms |

这是一份首次记录的基线，不能据此声明 Medium/Stress 或 Flutter UI 性能预算已完成。Medium 与 Stress
只在相同参考机的专用性能任务中采样，避免在普通 PR 上创建大型 fixture。

## 2026-09-30 Small/Medium 复测

同一台 Apple M4 参考机、相同 Git/Flutter 环境和 seed `20260907` 下，使用 7 次迭代得到以下
Git 读取和 benchmark 进程 RSS P95。该结果用于后续回归比较，不包含 Flutter 首帧、滚动帧时间或完整应用内存测量。

| fixture | status P95 | refs P95 | 500 条历史 P95 | RSS P95 | RSS 增量 P95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Small（1,000 commits、20 tags） | 74ms | 26ms | 55ms | 240,287,744B | 10,944,512B |
| Medium（10,000 commits、200 tags） | 533ms | 55ms | 95ms | 227,803,136B | -2,162,688B |

RSS 字段已由 benchmark 工具输出并参与基线比较；这里的 RSS 是独立 benchmark 进程的粗粒度
观测值，受 Dart 堆回收和进程启动状态影响，不能替代 Flutter DevTools 的应用内存快照。负的
RSS 增量表示采样期间进程回收后低于启动值，不应解释为负内存使用。

## 2026-10-05 Small/Medium/Stress 工具链复测

本次在 arm64 macOS 26.5.2、Apple Git 2.50.1 环境使用固定 seed `20260907` 验证三档
fixture 的离线生成和读取工具链。Small/Medium 使用 5 次迭代，Stress 使用 3 次迭代；结果
只作为当前机器的可重复开发基线，不作为 Flutter UI 或发布性能验收。Stress fixture 已成功
生成 100,000 个提交、100,000 个文件、1,000 个标签和 10,000 个未提交改动。

| fixture | 迭代 | status P95 | refs P95 | 500 条历史 P95 | benchmark RSS P95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Small（1,000 commits、20 tags） | 5 | 142ms | 82ms | 158ms | 193,871,872B |
| Medium（10,000 commits、200 tags） | 5 | 165ms | 87ms | 149ms | 231,424,000B |
| Stress（100,000 commits、1,000 tags、10,000 changes） | 3 | 2,916ms | 413ms | 1,796ms | 109,559,808B |

原始 JSON 和临时 fixture 保留在本次运行的 `/private/tmp`，不提交到仓库；RSS 仍是独立
benchmark 进程的粗粒度观测，Stress 仅用于定时/手动回归比较。Flutter 首帧、滚动帧和完整
Engine/native 内存快照仍需图形环境下的 profile 专项采样。

## 2026-10-05 Flutter macOS UI 入口复测

在当前图形环境以 Debug macOS integration test 运行更新后的测量入口，临时仓库包含 120 个提交
和一个 `perf-navigation` 本地分支。该轮用于验证搜索防抖、引用导航、滚动和快照字段均能实际产出，
不作为稳定发布预算；profile 多轮采样仍需单独完成。

| 项目 | 结果 |
| --- | ---: |
| Startup first frame build（2 帧样本中的首帧） | 397.407ms |
| Startup to interactive | 4,327.581ms |
| History scroll frame build P95（488 帧） | 10.908ms |
| Search response wall time（含 220ms 防抖边界） | 856.109ms |
| Local reference navigation wall time | 847.609ms |
| RSS before startup | 230,457,344B |
| RSS after startup | 409,862,144B |
| RSS after history scroll | 411,893,760B |
| Startup RSS delta | 179,404,800B |
| Scroll RSS delta | 2,031,616B |
| Dart heap snapshot after startup | 32,117,676B |
| Dart heap snapshot after history scroll | 36,496,139B |

墙钟测量包含测试驱动和状态刷新开销，只用于回归趋势；RSS 与 Dart heap snapshot 仍不覆盖完整
Flutter Engine/native 分配。原始报告位于运行机临时目录，不提交到仓库。

## 2026-10-07 Flutter macOS Profile 新口径三轮采样

在同一 Apple M4/macOS 图形环境、Flutter 3.47.1 / Dart 3.13.1 下，使用
`flutter drive --profile --no-pub --no-dds -d macos --target=integration_test/macos_performance_test.dart`
完成三轮独立成功采样。每轮都使用 120 条提交和 `perf-navigation` 本地分支的临时仓库；启动计时口径为
`history_ready_before_initial_commit_preview`，即状态、引用和首屏历史 ready 且完成一次绘制后停止，
默认提交摘要与首个 Diff 在后续采样前等待完成。启动阶段每轮只采集到 1 帧，因此首帧数值不宣称启动帧
P95；下表中位数为 n=3 的描述性统计，不是正式发布 P95。

| 项目 | 第 1 轮 | 第 2 轮 | 第 3 轮 | 三轮中位数 |
| --- | ---: | ---: | ---: | ---: |
| Startup first frame build | 150.605ms | 155.705ms | 116.937ms | 150.605ms |
| Startup to interactive | 2,617.391ms | 2,782.608ms | 2,517.993ms | 2,617.391ms |
| History scroll frame build P95 | 2.662ms | 3.334ms | 3.323ms | 3.323ms |
| Search response wall time（含 220ms 防抖边界） | 1,032.855ms | 1,239.424ms | 874.943ms | 1,032.855ms |
| Local reference navigation wall time | 885.221ms | 967.678ms | 228.164ms | 885.221ms |
| Startup RSS delta | 69,861,376B | 73,449,472B | 60,424,192B | 69,861,376B |
| Scroll RSS delta | 2,555,904B | 6,799,360B | 8,437,760B | 6,799,360B |
| Dart heap snapshot after startup | 11,739,606B | 11,001,625B | 10,149,769B | 11,001,625B |
| Dart heap snapshot after history scroll | 14,115,112B | 15,990,008B | 15,846,131B | 15,846,131B |

早期三轮可交互耗时均低于当前冷启动预算 3 秒，滚动构建 P95 也低于 24ms；这支持当前参考机上的
Profile 路径没有明显预算回退，但该早期 n=3 样本不足以把首帧、可交互耗时或滚动指标称为稳定 P95。RSS 是进程级
粗粒度观测，滚动 RSS 可因回收出现负增量；Dart heap snapshot 只覆盖 VM 堆。完整 Flutter Engine/native
分配已在下节通过 Instruments/footprint 开始专项采样，但稳定内存预算仍需更多独立轮次。原始 JSON 仅保留在
运行机的系统临时目录用于核对，不提交到仓库。

## 2026-10-07 Flutter macOS Engine/native 内存专项两轮采样（历史记录）

同一 Apple M4/macOS 图形环境使用 `tool/profile_macos_memory.sh` 完成两轮独立成功专项采样。两轮 Profile
测试、Instruments Allocations/VM Tracker 和两个 `footprint` 协调点均正常结束；trace 分别录制
33.557 秒和 32.231 秒，并随目标进程正常退出。

| 指标 | 第 1 轮 | 第 2 轮 | 两轮中位数 |
| --- | ---: | ---: | ---: |
| 初始预览完成 phys_footprint | 179,850,368B | 181,931,072B | 180,890,720B |
| 历史滚动完成 phys_footprint | 200,740,032B | 202,050,752B | 201,395,392B |
| 历史滚动阶段增量 | 20,889,664B | 20,119,680B | 20,504,672B |
| 初始预览阶段进程峰值 | 194,055,296B | 181,996,608B | 188,025,952B |
| 历史滚动阶段进程峰值 | 216,108,224B | 210,914,432B | 213,511,328B |

| footprint 分类增量 | 第 1 轮 | 第 2 轮 |
| --- | ---: | ---: |
| untagged (VM_ALLOCATE) | +6,766,592B | +7,569,408B |
| MALLOC_SMALL | +9,240,576B | +8,634,368B |
| MALLOC_LARGE | +4,259,840B | +4,259,840B |
| IOSurface | 0B | 0B |
| IOAccelerator (graphics) | -442,368B | -409,600B |
| performance tool data | 0B | +49,152B |

这是两轮诊断样本，不是稳定内存预算。`performance tool data` 明确显示 Instruments 的测量开销；阶段增量也
包含滚动缓存及尚未回收的分配，不能直接解释为泄漏。原始 `.trace`、TOC、footprint 与日志保留在本机
`/private/tmp/git-desktop-macos-memory`，不提交到仓库；后续需要在同一环境重复采样，并用 Allocations 的
调用树和 VM Tracker 区分可回收缓存、图形表面、Dart/Engine 分配及真正持续增长的 native 分配。

## 2026-10-07 Flutter macOS Profile 与 Engine/native 内存专项五轮复测

同一 Apple M4/macOS 图形环境使用当前脚本完成五轮独立成功采样。五轮 Profile 测试均通过，滚动阶段每轮
收集 472 帧；五轮内存 trace 均包含 Allocations/VM Tracker，TOC 均以 `Target app exited` 结束。

| 指标 | 五轮样本值 | 中位数 | 样本 P95 |
| --- | ---: | ---: | ---: |
| 启动到可交互（ms） | 2,391.968 / 2,271.536 / 2,255.214 / 2,249.908 / 2,276.268 | 2,271.536 | 2,391.968 |
| 首帧构建（ms） | 77.704 / 21.675 / 19.065 / 23.805 / 32.426 | 23.805 | 77.704 |
| 历史滚动构建 P95（ms） | 1.948 / 1.362 / 1.397 / 4.125 / 3.947 | 1.948 | 4.125 |
| 启动完成 phys_footprint（B） | 183,684,288 / 179,408,000 / 184,880,192 / 179,326,080 / 183,389,376 | 183,389,376 | 184,880,192 |
| 滚动完成 phys_footprint（B） | 197,840,064 / 205,278,336 / 199,462,080 / 200,232,128 / 199,494,848 | 199,494,848 | 205,278,336 |
| 滚动阶段增量（B） | 14,155,776 / 25,870,336 / 14,581,888 / 20,906,048 / 16,105,472 | 16,105,472 | 25,870,336 |

可交互中位数和滚动构建样本 P95 低于当前 3 秒/24ms 预算；启动每轮只有一个首帧样本，首帧统计只作描述性
参考。内存阶段增量包含滚动缓存及尚未回收的分配，不能直接解释为泄漏或发布预算；原始五轮产物保留在本机
`/private/tmp/git-desktop-macos-memory-followup`，不提交到仓库。
