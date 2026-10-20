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
