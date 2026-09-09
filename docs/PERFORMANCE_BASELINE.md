# 性能基线

> 性能基线 / Performance baseline：记录可重复的测量口径、环境和限制。
> Records reproducible measurement definitions, environments, and limitations.

> 性能基线 / Performance baseline：记录可重复的测量口径、环境和限制。
> Records reproducible measurement definitions, environments, and limitations.

## 记录方式

本记录只描述可重复的 Git 读取采样，不代表 Flutter 首次绘制、滚动帧时间、内存或 CPU 预算已
达标。使用固定 seed 的离线 Small fixture，并由 `tool/benchmark_repository.dart` 读取 status、
refs 和固定 revision snapshot 的 500 条历史。

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

这是一份首次记录的基线，不能据此声明 Medium/Stress 或 UI 性能预算已完成。Medium 与 Stress
只在相同参考机的专用性能任务中采样，避免在普通 PR 上创建大型 fixture。
