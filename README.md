# PC Manager

Windows 桌面系统管理工具，**Flutter + Rust**（[flutter_rust_bridge v2](https://cjycode.com/flutter_rust_bridge)）构建。

## 功能

- **设备监控**：CPU / 内存 / 磁盘 / 网络实时仪表盘，健康评分与体检面板
- **进程与启动项**：进程列表与结束、启动项启用/禁用、开机时长
- **应用中心**：注册表 Uninstall 枚举、应用卸载
- **清理套件**：winapp2 格式规则引擎驱动的深度清理、大文件扫描、重复文件（内容指纹）、系统盘分析、回收站
- **工具箱**：网速测试（延迟/抖动/上下行）、补丁检测（WUSA / DISM / MSI / Common）
- **常驻组件**：资源悬浮窗（desktop_multi_window 子引擎 + 原生无边框面板）、托盘菜单窗口、
  采集 Agent（30s 任务轮询）与 Windows 保活服务（`CmKeepAlive`）
- **系统集成**：单实例、静默启动、关窗入托盘、阈值告警弹窗、点击埋点与问题反馈旁路

## 架构

```
CmKeepAlive 服务 ──守护──▶ cm_agent.exe（任务轮询 / 日志采集）
GUI（Flutter） ──frb v2──▶ rust_lib.dll（系统信息 / 磁盘扫描 / 进程管理）
   ├─ 悬浮窗子引擎（desktop_multi_window，主窗口推送、子引擎纯渲染）
   └─ 托盘菜单子引擎
```

- Rust 侧 95 个绑定接口，系统层基于 `sysinfo` / `winreg` / `wmi` / `windows` crate；
  清理规则解析为 winapp2.ini 格式（社区规则库可直接使用）。
- `windows/CMakeLists.txt` 集成 cargo：`flutter build windows` 自动产出
  `rust_lib.dll`、`cm_agent.exe`、`cm_keep_alive.exe` 并随包安装。

## 构建

```powershell
# 前置：Flutter stable（含 Windows 桌面支持）、Rust stable-msvc、VS Build Tools (C++)
flutter pub get
flutter run -d windows
flutter build windows --release   # 产物在 build\windows\x64\runner\Release\
```

运行时资源：`assets/images/`、`assets/lottie/`、`rules/*.ini` 为本机放置的
非入库资源（见各目录 README），缺省时界面有兜底渲染，不影响编译运行。

## 许可

[MIT](LICENSE)
