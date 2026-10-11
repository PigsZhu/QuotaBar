# QuotaBar

<img src="AppResources/QuotaBar.png" width="88" height="88" alt="QuotaBar 应用图标">

**藏在 Mac 刘海里的 Codex 额度小助手。**

设计与开发 · **pigs** · MIT License

QuotaBar 在屏幕顶部显示一双会动的眼睛和剩余额度圆环。点击后展开卡片，查看剩余百分比、重置时间和刷新状态。

这是独立项目，与 OpenAI 没有隶属关系。用量来自用户本机已登录的 Codex，实际可用额度以服务端返回为准。

## 功能

- **快速查看用量**：优先展示 `5-Hour`，没有该窗口时展示 `Weekly`；两者都没有时显示暂无可用额度。
- **自动刷新**：收起时约每 30 秒、展开时约每 10 秒更新；支持手动刷新、失败重试，以及唤醒和网络恢复后的更新。
- **动态眼睛**：鼠标跟随、待机表情、眯眼蓄力与圆环互动；装饰动画不会改变真实额度。
- **连贯开合**：浮层从顶部入口展开并弹性收回，数字和进度变化平滑过渡。
- **适配系统**：有刘海的屏幕读取系统安全区，无刘海屏幕使用顶部居中入口；支持减少动态效果。
- **轻量常驻**：不显示 Dock 图标，可从“更多”菜单刷新、查看作者信息或退出。

## 使用条件

| 项目 | 要求 |
| --- | --- |
| 操作系统 | macOS 14 或更新版本 |
| 处理器 | Apple 芯片或 Intel；Intel 尚未完成实机验证 |
| Codex | 本机安装并登录 Codex App，或安装支持 app-server 的 Codex CLI |
| 网络 | 读取最新额度时需要联网 |
| 界面材质 | macOS 26 及以上使用系统玻璃，较早版本使用磨砂材质 |

## 安装与使用

1. 从 [Releases](https://github.com/cinzrozhu-stack/QuotaBar/releases) 下载 `QuotaBar-<版本号>-Universal.zip`。
2. 解压，将 `QuotaBar.app` 拖入“应用程序”。
3. 打开后，点击屏幕顶部中央的小刘海查看额度。
4. 点击外部、顶部收起区域或按 Escape 可收回卡片。

目前发布流程生成本地签名的测试包，尚未经过 Developer ID 签名和苹果公证。首次打开可能受到系统安全策略限制；也可以按下面的说明自行编译。

应用不自带 Codex，也不会要求你把登录文件或令牌交给项目作者。若提示未登录，先在自己的 Codex 中完成登录，再使用“更多 → 刷新用量”。

## 从源码运行

需要完整的 **Xcode 26 或更新版本**（包含 macOS 26 SDK），以及随 Xcode 提供的 Swift 工具链。最低运行版本仍为 macOS 14。

在项目根目录执行：

```bash
./script/build_and_run.sh --verify
```

脚本会构建、签名并启动 `dist/QuotaBar.app`；如果当前选择的是独立 Command Line Tools，会在本次构建中尝试选择已安装的 Xcode。

公开源码不需要购买或下载任何字体即可编译，默认使用 macOS 系统字体。

运行测试：

```bash
swift test
```

测试主要使用模拟用量提供器和本地进程，不需要登录真实账号。构建及打包细节见 [开发说明](docs/development.md)。

## 数据来源与隐私

QuotaBar 通过本机 Codex 后台的只读 `account/rateLimits/read` 接口读取用量。优先寻找 Codex App 内置程序；可用时复用其共享连接，否则启动并复用 QuotaBar 自己的后台连接。

- QuotaBar 不直接读取、复制或上传登录令牌；登录维护及联网请求由官方 Codex 后台处理。
- 不读取对话内容、不发送聊天消息，不运行模型生成任务。
- 不包含独立的分析统计、广告或遥测上传服务。
- 本次运行的用量缓存在内存中；刷新失败时保留上次成功数据并显示提示。
- 当前通过定时读取更新，不是服务端实时推送，可能有短暂延迟。

## 字体与版权

原始界面设计使用 **PP Neue Machina Inktrap Regular**，由 **Pangram Pangram® Foundry** 提供。这是第三方收费字体，**不属于 QuotaBar 的 MIT 许可范围**。

**公开源码和默认通用安装包均不包含该字体文件，使用 macOS 系统字体。** 开源、免费或添加署名都不等于取得字体嵌入及再分发授权。原设计字体若需用于应用，须自行确认相应授权；官方将应用内嵌入列为 App License 使用场景。

- [字体官方网站](https://pangrampangram.com/products/neue-machina)
- [官方授权说明](https://pangrampangram.com/pages/faq)
- [完整第三方资源说明](THIRD_PARTY_NOTICES.md)

## 已知限制

- 同时返回多档额度时，目前只展示优先选中的一档。
- Codex 后台接口或安装位置的变化可能影响兼容性。
- 通用包包含两种架构，但 Intel 及较早 macOS 版本尚需更多实机验证。
- 不包含文件拖放入口、自动更新或开机启动设置。
- 在某些重新打开应用的场景下可能出现空白 Settings 窗口，关闭该窗口不影响顶部入口。

## 作者与许可

设计与开发：**pigs**。

项目代码采用 [MIT 许可证](LICENSE)。使用和分发时应保留版权与许可声明；第三方字体及服务标识的权利单独归其权利人所有。

版本变化见 [更新记录](CHANGELOG.md)，首次发布流程见 [发布说明](docs/release.md)。
