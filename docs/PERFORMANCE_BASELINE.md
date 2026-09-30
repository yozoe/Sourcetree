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
