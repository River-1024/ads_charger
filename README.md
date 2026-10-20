# ADS Charger Flutter App

Android/iOS 直连 ADS 充电器的 Flutter 客户端。当前提供当前轮 BLE 扫描、本机默认设备、01/02 查询、
受保护的 03 锂电参数修改、用户预设，以及首页固定帧控制。

## 首页充电器控制

- **强制激活**：长按 3 秒后弹出二次确认，只发送一次固定 `04 + AA` 帧。
- **手动按键调节**：显式选择“锁定”或“开启”，分别发送 `09 + A0` / `09 + 0A`。
- 未取得有效 `02` 时禁用控制；设备读回已与目标一致时不发送。
- 锁定等待候选 `05`、开启等待候选 `06`；只有新的 `02.lockRaw` 与目标一致才显示“已验证”。
- 强制激活没有可由 `02` 核对的字段，因此最多显示“已回包未核验”。
- 超时、断线和回读不一致都不会自动重发控制帧。

这些规则是本地安全边界。真实 ADS 对 `04/05/06`、`08 12 34` 依赖、`timerRaw` 单位和 HCI `0x13`
断线行为尚需实机验收。

## 本地检查

在仓库根目录执行：

```powershell
$env:PUB_CACHE="$PWD\.pubcache"
flutter test --reporter compact
dart analyze lib test
```

## Android Debug 构建

本机约定使用 JDK 21 和用户 Android SDK：

```powershell
cd android
$env:JAVA_HOME='<JDK 21 安装路径>'
$env:Path="$env:JAVA_HOME\bin;$env:LOCALAPPDATA\Android\Sdk\cmdline-tools\latest\bin;$env:LOCALAPPDATA\Android\Sdk\platform-tools;$env:Path"
.\gradlew.bat assembleDebug
```

Oracle JDK 26.0.1 会在 Android API 36 的 `JdkImageTransform/jlink` 阶段失败，因此本机实际使用
Microsoft OpenJDK 21.0.12.101 构建；应用的 Java/Kotlin 字节码目标仍为 17。

2026-09-15 已用 JDK 21 成功执行 `gradlew.bat clean assembleDebug`，APK 输出到：

`build/app/outputs/flutter-apk/app-debug.apk`

## 云端构建

仓库内置三条 GitHub Actions 流水线，不需要本地 Mac 或 Android SDK：

| 工作流 | 触发方式 | 产物 | 说明 |
| --- | --- | --- | --- |
| `android-apk.yml` | push / 手动 | `android-apk-release` | ubuntu runner + JDK 21，release 变体沿用 debug 签名配置，产物可直接安装 |
| `ios-build.yml` | push / 手动 | `ios-unsigned-ipa` | macos-15 runner，`--no-codesign`，仅用于验证可编译，产物无法直装 |
| `ios-release.yml` | 仅手动 | `ios-signed-ipa` | 需先配置 `IOS_P12_BASE64`、`IOS_P12_PASSWORD`、`IOS_PROVISION_BASE64` 三个 secret |

### iOS 依赖管理注意

本工程使用 **Swift Package Manager** 管理插件依赖（`Runner.xcodeproj` 内含
`XCLocalSwiftPackageReference "Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage"`）。
**不要添加 `ios/Podfile`** —— 同时启用 CocoaPods 通道会与纯 SPM 工程冲突，构建报
`The sandbox is not in sync with the Podfile.lock`。

`permission_handler_apple` 的权限由 `Info.plist` 中的 usage description key 自动启用
（解析优先级：环境变量 > Info.plist > 默认关闭），不需要 `PERMISSION_*` 预处理宏。
当前 `Info.plist` 已包含 `NSBluetoothAlwaysUsageDescription` 与
`NSBluetoothPeripheralUsageDescription`。

### 验证状态

2026-10-20：Android release APK（23.8 MB）与 iOS 签名 IPA（8.1 MB）均已安装到真机并正常启动。
BLE 扫描、连接与参数读写尚未在真机上做连接测试。
