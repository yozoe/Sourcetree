# Flutter Git 桌面客户端

这是一个以 Flutter 独立实现的桌面 Git 客户端项目。产品会对齐
Sourcetree 的核心工作流和信息密度，但不会复制其闭源代码、商标、
品牌素材或私有服务。

当前状态：**P0 首个只读切片已可运行。**

当前版本可以打开本地 Git 仓库，展示工作区状态、最近提交、基础提交图和
单文件 Unified Diff。暂存、提交、分支和远端写操作均尚未开放，以避免在
安全恢复机制完成前修改用户仓库。

## 运行

```sh
flutter pub get
flutter run -d macos
```

验证命令：

```sh
flutter analyze
flutter test
flutter build macos --debug
```

## 首发目标

- macOS 优先，Apple Silicon 为第一验证平台。
- 使用系统或用户指定的 Git CLI，Git 仓库是唯一事实来源。
- 先完成“打开仓库 → 查看改动 → Diff → 暂存 → Commit → 查看历史”
  的安全闭环。
- 架构隔离平台能力，为后续 Windows 和 Linux 留出适配边界。

详细范围、架构、路线图和验收标准见：

- [实施规划](docs/IMPLEMENTATION_PLAN.md)

## 当前验证环境

- macOS 26.3.1（arm64）
- Flutter 3.41.6 stable
- Dart 3.11.4
- Git 2.50.1（Apple Git-155）

## 名称说明

仓库名暂沿用 `Sourcetree`，仅作为开发阶段的项目路径。正式产品应采用
独立名称、图标、文案和视觉资产。
