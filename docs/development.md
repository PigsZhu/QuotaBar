# 开发说明

## 环境与入口

这是 SwiftPM 管理的原生 macOS 应用，使用 SwiftUI、AppKit 和 Core Animation，没有额外的第三方 Swift 包依赖。

- 编译：完整 Xcode 26 或更新版本，包含 macOS 26 SDK。
- 运行：macOS 14 或更新版本。
- 构建并启动：`./script/build_and_run.sh --verify`。
- 测试：`swift test`。

如果测试提示当前仅选择了 Command Line Tools，可以显式指定已安装的完整 Xcode：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

不要直接启动 `.build` 下的 GUI 可执行文件；打包脚本会放好图标、资源和应用信息。

## 目录

| 目录或文件 | 用途 |
| --- | --- |
| `Sources/QuotaBar/App` | 窗口、刘海形状、眼睛、圆环和开合动画 |
| `Sources/QuotaBar/Views` | 用量卡片、分段进度条和资源加载 |
| `Sources/QuotaBar/Models` | 用量窗口及快照 |
| `Sources/QuotaBar/Services` | Codex 只读连接、解码和刷新调度 |
| `Sources/QuotaBar/Resources` | 界面图标及可选的本地字体 |
| `Tests/QuotaBarTests` | 额度、连接恢复、调度和动画回归测试 |
| `AppResources` | 应用图标、作者署名和字体说明 |
| `VERSION` | 应用与安装包的版本号 |
| `script/build_and_run.sh` | 构建、签名、启动和通用打包 |
| `script/prepare_source.py` | 按明确清单导出可公开的源码副本 |

## 可选字体

默认公开版本使用系统字体。已取得适当授权的开发者可以在本地放置：

```text
Sources/QuotaBar/Resources/Fonts/PPNeueMachina-InktrapRegular.otf
```

字体文件被 `.gitignore` 排除。字体缺失或注册失败时自动回退，不会因缺少商业资源而崩溃。`--package-universal` 始终排除字体文件；它不会因为开发机器装有字体而把文件带入公开安装包。

授权边界及官网地址见 [第三方资源说明](../THIRD_PARTY_NOTICES.md)。

## 打包

```bash
./script/build_and_run.sh --package-universal
```

输出 `dist/QuotaBar-<版本号>-Universal.zip`，包含 arm64 和 x86_64，解压后只有一个 `QuotaBar.app`。应用中包含作者署名、MIT 许可和字体来源说明。

通用构建使用独立缓存和临时应用目录，不停止本机正在运行的开发版。打包后临时应用自动清理，避免留下重复图标。当前为 ad-hoc 本地签名，不代表已经通过苹果公证。

## 图标

已选定的图稿保存在 `AppResources/QuotaBar.png`，生成图标：

```bash
./script/generate_app_icon.sh
```

## 验证范围

测试覆盖额度窗口选择、缺失及异常数据、连接恢复、自动刷新、开合中断、减少动态效果和眼睛与圆环互动。自动测试通过不代替真机上的动画、屏幕适配和首次安装体验检查。
