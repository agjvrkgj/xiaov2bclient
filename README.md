# XiaoV2B Client - V2Board 客户端

一个基于 Flutter 开发的跨平台 V2Board 客户端，已接入 Mihomo 内核与完整 API。

![动画](https://github.com/user-attachments/assets/d3711d6b-e5a8-463a-afe3-8385de55f536)

## ⚠️ 重要说明

- ✅ **全部代码由 AI 代写**
- ✅ 订阅连接会以 `flag=meta` 请求 Clash.Meta/Mihomo 配置
- ⚠️ 首次在 Android 连接时需要用户授予系统 VPN 权限
- ⚠️ 桌面端使用系统 HTTP/HTTPS/SOCKS 代理，不会透明接管不遵循系统代理的程序

## 📱 支持平台

- ✅ Windows（Mihomo mixed-port + 可恢复的系统代理）
- ✅ macOS（Mihomo mixed-port + 可恢复的系统代理）
- ✅ Linux/GNOME（Mihomo mixed-port + `gsettings` 系统代理）
- ✅ Android（`VpnService` + Mihomo userspace TUN）
- ⚠️ iOS（现有 UI/API 可构建，尚未接入 Network Extension）
- ⚠️ Web（现有 UI/API 可运行，不支持本地 VPN 内核）

## 🚀 主要功能

### 核心功能
- 用户登录/注册
- 订阅管理
- 节点选择与切换
- 流量记录
- 订阅套餐购买
- 邀请码系统
- 工单系统
- 公告通知
- Mihomo v1.19.30 内核生命周期管理
- Rule/Global 模式切换
- 连接中实时切换 Selector 节点
- 异常退出后恢复桌面系统代理

### OSS 动态配置
OSS 配置见另一个仓库：[APIOSS](https://github.com/sunyuchentrx/APIOSS)

OSS 预设了以下功能：
- 邀请连接单独 URL
- 轮询 API 地址
- 动态加载商品 ID
- 应用版本检测与更新

## 🔧 技术栈

- **框架**: Flutter 3.x
- **状态管理**: Provider
- **网络请求**: Dio
- **本地存储**: SharedPreferences
- **UI设计**: Glassmorphism 风格
- **图标生成**: flutter_launcher_icons

## 📦 配置说明

### OSS 配置

在 `lib/services/config_service.dart` 中配置 OSS URL：

```dart
final List<String> _ossUrls = [
  'https://raw.githubusercontent.com/sunyuchentrx/APIOSS/refs/heads/main/api.txt',
  'https://your-backup-url.com/config.txt'  // 备用地址
];
```

### 应用信息配置

在 `build_config.yaml` 中修改应用信息：

```yaml
app_name: "学习强国"              # 应用显示名称
process_name: "xuexi"            # 进程名称（exe文件名）
package_name: "com.xuexi.app"    # 包名
```

### Logo 替换

将您的 logo.png 放置在以下位置：
- 主 Logo: `assets/images/logo.png`
- macOS Logo (可选): `assets/images/logo/logo_mac.png`

然后运行：
```bash
flutter pub get
flutter pub run flutter_launcher_icons
```

## 🛠️ 编译指南

### 环境要求
- Flutter SDK >= 3.10.1
- Dart SDK >= 3.10.1
- Android 构建另需 Go 1.25 与 Android NDK `28.0.13004108`
- 桌面内核由下载脚本从 Mihomo 官方 Release 获取并校验 SHA-256

### Windows
```bash
python tool/fetch_mihomo.py --platform windows --arch amd64
flutter build windows --release
```

### Android
```bash
export ANDROID_NDK_HOME=/path/to/android-ndk/28.0.13004108
bash tool/build_android_core.sh
flutter build apk --release
```

### macOS
```bash
python3 tool/fetch_mihomo.py --platform macos --arch universal
flutter build macos --release
```

### Linux
```bash
python3 tool/fetch_mihomo.py --platform linux --arch amd64
flutter build linux --release
```

GitHub Actions 会执行配置测试，并构建 Android、Windows、macOS 和 Linux
四个平台的可下载产物。内核二进制不会提交到 Git 仓库。


## 📁 项目结构

```
lib/
├── main.dart                    # 应用入口
├── models/                      # 数据模型
│   └── app_config.dart         # 应用配置模型
├── pages/                       # 页面
│   ├── welcome_page.dart       # 欢迎页
│   ├── login_page.dart         # 登录页
│   ├── register_page.dart      # 注册页
│   ├── home_page.dart          # 主页
│   ├── premium_page.dart       # 套餐购买页
│   └── ...
├── providers/                   # 状态管理
│   └── language_provider.dart  # 语言切换
├── services/                    # 服务层
│   ├── api_service.dart        # API 服务
│   ├── config_service.dart     # 配置服务（OSS）
│   └── mihomo/                 # 内核配置、控制器及各平台后端
├── theme/                       # 主题
│   └── app_theme.dart          # 应用主题配置
└── widgets/                     # 通用组件
    ├── connect_button.dart     # 连接按钮
    ├── server_card.dart        # 服务器卡片
    └── ...
```

## 🔐 API 对接

项目已完整对接 V2Board API，包括：

- ✅ 用户认证（登录/注册/重置密码）
- ✅ 订阅管理（获取订阅信息/流量统计）
- ✅ 节点获取
- ✅ 套餐购买
- ✅ 订单管理
- ✅ 工单系统
- ✅ 公告系统
- ✅ 邀请码系统

具体 API 实现见 `lib/services/api_service.dart`

## 🧩 Mihomo 实现说明

- 控制器固定监听 `127.0.0.1:19090`，并使用随机持久化 secret 鉴权。
- mixed-port 固定为 `127.0.0.1:17890`，`allow-lan` 强制关闭。
- Android 由系统 `VpnService` 创建 TUN，应用 UID 被排除，内核出站 socket
  仍会调用 `VpnService.protect()` 防止路由回环。
- Windows/macOS/Linux 在连接前保存原系统代理，断开或内核异常退出时恢复。
- macOS 为了启动子进程并调用 `networksetup`，目标采用站外分发配置且未启用
  App Sandbox；如需上架 Mac App Store，需要改用受支持的 Network Extension。
- 订阅必须返回 Clash/Mihomo YAML；仅有通用 URI 列表的订阅无法启动。

## 📝 待优化项

- [ ] 实现节点延迟测试（Ping）
- [ ] 添加自动重连机制
- [ ] iOS Network Extension / Packet Tunnel 接入
- [ ] 非 GNOME Linux 桌面代理适配

## 🤝 贡献

本项目由[Antigravity操盘手孙宇晨开发](https://t.me/sunyuchentrx)

感谢[胖~](https://t.me/panghu_code) 的开源项目提供的API

🚀项目交流群： [胖虎妙妙屋](https://t.me/panghu_dev)

🚀机场主都在看的频道：[机场观察](https://t.me/jichangguancha)


## 📄 许可证

本项目采用 [GNU GPL v3](LICENSE)。Mihomo 的版本、来源、校验与构建方式见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。分发修改后的应用时必须同时
遵守 GPL-3.0 的源码与许可证义务。

## 🔗 相关项目

- OSS 配置仓库: [APIOSS](https://github.com/sunyuchentrx/APIOSS)
- V2Board 后端: [xiaov2board](https://github.com/wyx2685/v2board)

---

**注意**: 本项目全部代码由 AI 生成，使用前请仔细测试并根据实际需求调整（README也是AI写的）。
