# Flutter Git 桌面客户端

这是一个以 Flutter 独立实现的桌面 Git 客户端项目。产品会对齐
Sourcetree 的核心工作流和信息密度，但不会复制其闭源代码、商标、
品牌素材或私有服务。

当前状态：**P1 MVP 垂直闭环进行中。**

当前版本可以打开、初始化和克隆仓库，展示工作区状态、最近提交、基础提交图和
单文件 Unified Diff。选中历史提交后，会读取该提交的文件清单、增删行统计和所选文件
的 Unified Diff；支持整文件暂存、提交、创建本地分支以及安全 Fetch / Pull / Push。
macOS bundle 的用户主动远端操作可使用单次受控 AskPass；发布签名、真实私有远端和
系统凭据兼容性仍在验证中。

已打开或成功克隆的仓库会保留在窗口顶部的横向 tab 中；点击 tab 会切回该仓库并重新
读取 Git 状态。读取失败会保留原先激活的 tab。为避免操作归属混淆，Clone、Fetch、Pull
或 Push 运行期间不允许切换 tab。

应用会在本机应用支持目录保存已打开仓库的路径和当前 tab；下次启动会自动恢复仍然有效的
仓库，已被移动、删除或不再可读的路径会自动跳过。不会保存 Git 凭据、操作记录或工作区内容。

## 运行

```sh
flutter pub get
flutter run -d macos
```

验证命令：

```sh
flutter analyze
flutter test
flutter test integration_test/macos_core_workflow_test.dart -d macos
flutter build macos --debug
```

## 安装到 Applications

在项目根目录运行：

```sh
./install_macos.sh
```

脚本会构建 Release app，使用系统授权安装到 `/Applications/Git Desktop.app`，并立即启动。
如已存在同名 app，会先移动到带时间戳的 `/Applications/Git Desktop.backup-*.app` 备份；
脚本不会关闭 Gatekeeper 或修改任何 macOS 安全设置。

## 首发目标

- macOS 优先，Apple Silicon 为第一验证平台。
- 使用系统或用户指定的 Git CLI，Git 仓库是唯一事实来源。
- 完成“打开/克隆 → 查看改动 → Diff → 暂存 → Commit → 分支 → Push”
  的安全闭环，并继续验证认证和恢复路径。
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
