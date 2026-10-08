//! api::sysinfo —— 系统信息 / 进程 / 启动项 / 网络适配器 / 补丁等 Windows 能力的净室实现。
//!
//! - 函数名与 frb codec 映射保持与规格整理规格一致（见 specs/api-map），每个函数头部
//!   注释保留了原 codec 名（如 `crateApiSysinfoAdapterRDisableProxy`）。
//! - 本模块仅面向 Windows（winreg / wmi / windows crate），在非 Windows 平台无法编译。
//! - 部分返回类型由占位的 `Vec<String>` 改为同文件内定义的结构体（derive Clone +
//!   serde::Serialize）；修改过签名/返回类型的接口需要重新运行 flutter_rust_bridge
//!   codegen 生成 Dart 侧镜像类型。
//! - 不便直接调用原生 API 的场景按约定退化为 `std::process::Command` 调用
//!   netsh / sc / wusa / dism / msiexec / powershell / explorer 等，均有注释说明。

use std::collections::HashMap;
use std::ffi::OsStr;
use std::io::Write as _;
use std::mem::size_of;
use std::net::{SocketAddr, TcpStream, UdpSocket};
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, SystemTime};

use anyhow::{anyhow, bail, ensure, Context};
use winreg::enums::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, KEY_SET_VALUE, RegType};
use winreg::HKEY;
use winreg::{RegKey, RegValue};
use windows::core::PCWSTR;
use windows::Win32::Foundation::{CloseHandle, POINT};
use windows::Win32::Graphics::Gdi::{
    BITMAP, BITMAPINFO, BITMAPINFOHEADER, CreateCompatibleDC, DIB_RGB_COLORS, DeleteDC, GetDIBits,
    GetObjectW, HBITMAP, HGDIOBJ, SelectObject,
};
use windows::Win32::Storage::FileSystem::{FILE_FLAGS_AND_ATTRIBUTES, GetFileVersionInfoW};
use windows::Win32::System::Com::{
    CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED,
};
use windows::Win32::System::Memory::{SETPROCESSWORKINGSETSIZEEX_FLAGS, SetProcessWorkingSetSizeEx};
use windows::Win32::System::Threading::{
    OpenProcess, PROCESS_QUERY_INFORMATION, PROCESS_SET_QUOTA,
};
use windows::Win32::UI::Shell::{
    ExtractIconExW, SHGetFileInfoW, SHFILEINFOW, SHGFI_ICON, SHGFI_LARGEICON,
};
use windows::Win32::UI::WindowsAndMessaging::{
    DestroyIcon, GetCursorPos, GetIconInfo, HICON, ICONINFO,
};
use wmi::{COMLibrary, WMIConnection};
use sysinfo::{Disks, Networks, Pid, ProcessesToUpdate, System};

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/// 开机自启 Run 键（HKCU / HKLM 通用）
const RUN_PATH: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
/// 开机自启 Run 键（HKLM 32 位视图）
const RUN_PATH_WOW: &str = r"Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run";
/// StartupApproved 子键（禁用状态存放在这里）
const APPROVED_HKCU: &str = r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
const APPROVED_HKLM: &str = r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
const APPROVED_WOW: &str = r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32";

/// 已安装卸载信息注册表路径
const UNINSTALL_HKLM: &str = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall";
const UNINSTALL_WOW: &str = r"SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall";
const UNINSTALL_HKCU: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall";

/// Windows 版本信息注册表路径
const CURRENT_VERSION_PATH: &str = r"SOFTWARE\Microsoft\Windows NT\CurrentVersion";

/// IE/系统代理设置注册表路径
const INET_SETTINGS_PATH: &str = r"Software\Microsoft\Windows\CurrentVersion\Internet Settings";

/// 存储感知（Storage Sense）策略注册表路径（原工程拼写 Stroge 刻意保留）
const STORAGE_POLICY_PATH: &str =
    r"SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy";

/// 镜像升级版本记录文件名（目录部分由 %ProgramData% 决定，见 [image_version_file]）。
const IMAGE_VERSION_FILE_NAME: &str = "version.txt";

/// 镜像升级版本记录文件的完整路径。
///
/// 目录是 `%ProgramData%\ImageUpgrade\`——**不能写死 `C:\ProgramData`**：
/// 装到 D:/E: 的机器上 %ProgramData% 就在那个盘上，写死 C: 会**恒定读不到**，
/// 于是 `get_image_version` 静默返回空、界面照旧说"没装镜像包"。
/// %ProgramData% 读不到才退回 C:（与别处同一口径，不引入第二套规则）。
fn image_version_file() -> PathBuf {
    let base = std::env::var("ProgramData").unwrap_or_else(|_| r"C:\ProgramData".to_string());
    PathBuf::from(base).join("ImageUpgrade").join(IMAGE_VERSION_FILE_NAME)
}

// ---------------------------------------------------------------------------
// 传输结构体（经 frb 传给 Dart，derive Clone + serde::Serialize）
// ---------------------------------------------------------------------------

/// 内存信息（单位：字节）
#[derive(Debug, Clone, serde::Serialize)]
pub struct MemoryInfo {
    /// 已用内存（字节）
    pub used: u64,
    /// 总内存（字节）
    pub total: u64,
}

/// 进程条目（进程列表页）
#[derive(Debug, Clone, serde::Serialize)]
pub struct ProcessEntry {
    pub pid: u32,
    pub name: String,
    /// 进程 exe 全路径；无权限查询（系统进程、其它用户）时为空
    pub exe: String,
    /// CPU 占用百分比
    pub cpu: f32,
    /// 物理内存占用（MB）
    pub mem_mb: f64,
}

/// 磁盘信息
#[derive(Debug, Clone, serde::Serialize)]
pub struct DiskInfo {
    /// 盘符（取挂载点尾段，如 "C:"）
    pub name: String,
    /// 挂载点（如 "C:\\"）
    pub mount_point: String,
    /// 总容量（字节）
    pub total_bytes: u64,
    /// 剩余容量（字节）
    pub free_bytes: u64,
    /// 文件系统（NTFS/FAT32...）
    pub file_system: String,
    /// 是否可移动介质
    pub removable: bool,
}

/// 网络状态
#[derive(Debug, Clone, serde::Serialize)]
pub struct NetInfo {
    /// 本机出口 IPv4（探测失败时为空串）
    pub local_ip: String,
    /// 是否可连通外网（TCP 连接 1.1.1.1:80，1 秒超时）
    pub connected: bool,
}

/// 网络适配器信息（对应 WMI Win32_NetworkAdapterConfiguration）
#[derive(Debug, Clone, serde::Serialize)]
pub struct AdapterInfo {
    pub description: String,
    pub mac_address: String,
    pub ip_addresses: Vec<String>,
    pub gateways: Vec<String>,
    pub dhcp_enabled: bool,
    pub dns_servers: Vec<String>,
    /// netsh 认的接口名。改 DNS / 启停网卡必须用它，不能用 description（见
    /// [netsh_name_for]）。读不到就是空串——那台网卡不能拿去做 netsh 动作。
    pub netsh_name: String,
}

/// 开机启动项
#[derive(Debug, Clone, serde::Serialize)]
pub struct StartupItemInfo {
    /// 启动项名称（Run 键值名）
    pub name: String,
    /// 启动命令
    pub command: String,
    /// 来源标记："HKCU" / "HKLM" / "HKLM_WOW"
    pub location: String,
    /// 是否启用（依据 StartupApproved 首字节）
    pub enabled: bool,
}

/// 已安装应用（卸载注册表项）
#[derive(Debug, Clone, serde::Serialize)]
pub struct InstalledAppInfo {
    pub name: String,
    pub version: String,
    pub publisher: String,
    /// 完整卸载注册表键，形如 "HKLM\SOFTWARE\...\Uninstall\{GUID}"
    pub uninstall_key: String,
    pub uninstall_string: String,
    /// DisplayIcon 原值，形如 `"C:\Path\a.exe",0` 或 `a.exe,1`；可能为空
    pub display_icon: String,
    /// 能直接启动的 `.exe` 全路径；`None` = 这个应用**推不出**启动目标
    /// （图标指向 .ico/只给文件名/路径已失效）。界面据此不给「启动」入口。
    pub launch_target: Option<String>,
}

/// 应用图标像素（行主序 RGBA），由界面直接解码成图片，不需要经过 PNG 编码。
/// width/height 取自图标自身的颜色位图，因此不同机器上的 32/48px 图标都能如实呈现。
#[derive(Debug, Clone, serde::Serialize)]
pub struct AppIconPixels {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

// ---------------------------------------------------------------------------
// WMI 反序列化结构体
// 注意：结构体名必须与 CIM 类名完全一致（wmi crate 依据类型名生成 WQL 的 FROM 子句）。
// ---------------------------------------------------------------------------

/// Win32_OperatingSystem（只取开机时间）
#[derive(serde::Deserialize, Debug)]
#[allow(non_snake_case, non_camel_case_types)]
struct Win32_OperatingSystem {
    LastBootUpTime: String,
}

/// Win32_QuickFixEngineering（系统补丁）
#[derive(serde::Deserialize, Debug)]
#[allow(non_snake_case, non_camel_case_types)]
struct Win32_QuickFixEngineering {
    HotFixID: String,
    #[allow(dead_code)]
    Description: Option<String>,
}

/// Win32_ComputerSystem（机型判断）
#[derive(serde::Deserialize, Debug)]
#[allow(non_snake_case, non_camel_case_types)]
struct Win32_ComputerSystem {
    Manufacturer: Option<String>,
    Model: Option<String>,
    PCSystemType: Option<u16>,
}

/// Win32_NetworkAdapterConfiguration（网络适配器配置）
#[derive(serde::Deserialize, Debug)]
#[allow(non_snake_case, non_camel_case_types)]
struct Win32_NetworkAdapterConfiguration {
    Description: String,
    MACAddress: Option<String>,
    IPAddress: Option<Vec<String>>,
    DHCPEnabled: bool,
    DNSServerSearchOrder: Option<Vec<String>>,
    DefaultIPGateway: Option<Vec<String>>,
    /// 网卡 GUID。与 WMI 的 Description **不是同一个东西**，见 [netsh_name_for]。
    SettingID: Option<String>,
}

/// netsh 认的接口名（`netsh interface ... name=<它>`）——它取的不是 WMI 的
/// Description，而是网卡自己的连接名（NetConnectionID）。
///
/// 实测本机：Description 是 `Red Hat VirtIO Ethernet Adapter #3`，
/// netsh 的接口名却是 `以太网实例 0 3`。拿 description 去跑
/// `netsh interface ip set dns name=...` 直接「系统找不到指定的路径」——
/// 改 DNS/启用网卡这条能力会**静默失败**（看着像执行了，其实什么都没改）。
///
/// 映射写在注册表：`HKLM\SYSTEM\CurrentControlSet\Control\Network\{类GUID}\
/// {SettingID}\Connection\Name`，值就是 netsh 用的那个名字。
fn netsh_name_for(setting_id: &str) -> Option<String> {
    let guid = setting_id.trim().trim_start_matches('{').trim_end_matches('}');
    if guid.is_empty() {
        return None;
    }
    let path = format!(
        r"SYSTEM\CurrentControlSet\Control\Network\{{4D36E972-E325-11CE-BFC1-08002BE10318}}\{{{}}}\Connection",
        guid
    );
    let key = RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey(path).ok()?;
    let name: String = key.get_value("Name").ok()?;
    let name = name.trim().to_string();
    if name.is_empty() {
        None
    } else {
        Some(name)
    }
}

// ---------------------------------------------------------------------------
// 通用辅助
// ---------------------------------------------------------------------------

/// WMI 连接（每次调用新建：WMIConnection 持有裸指针且未实现 Send/Sync，
/// 不能放入全进程静态缓存；COMLibrary::new 内部幂等处理 CoInitializeEx(MTA)
/// 与 CoInitializeSecurity（重复初始化返回 RPC_E_TOO_LATE 被容忍），可安全重入）。
fn wmi_connection() -> anyhow::Result<WMIConnection> {
    let com = COMLibrary::new().map_err(|e| anyhow!("初始化 COM 失败: {e}"))?;
    WMIConnection::new(com).map_err(|e| anyhow!("建立 WMI 连接失败: {e}"))
}

/// 运行外部命令并拼装 stdout/stderr/退出码为字符串（供补丁安装/卸载等返回）。
/// 多数此类工具需要管理员权限，由调用方注释说明。
fn run_tool(program: &str, args: &[String]) -> anyhow::Result<String> {
    let out = Command::new(program)
        .args(args)
        .output()
        .with_context(|| format!("启动 {program} 失败"))?;
    Ok(format!(
        "exit={}\n--- stdout ---\n{}--- stderr ---\n{}",
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    ))
}

/// hosts 文件完整路径（%SystemRoot%\System32\drivers\etc\hosts）
fn hosts_path() -> PathBuf {
    let sysroot = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".to_string());
    PathBuf::from(sysroot).join(r"System32\drivers\etc\hosts")
}

/// hosts 行是否属于“默认内容”（空行/注释/localhost 条目）。
/// 原始语义未完全规格整理，此处按常规PC Manager行为推断：存在其他可解析行即视为被配置过。
fn is_default_host_line(line: &str) -> bool {
    let t = line.trim();
    t.is_empty() || t.starts_with('#') || t.to_lowercase().contains("localhost")
}

/// 把挂载点转成盘符：挂载点形如 "C:\"，去掉尾部分隔符得到 "C:"。
fn mount_letter(mount: &Path) -> String {
    let text = mount.to_string_lossy();
    let trimmed = text.trim_end_matches(|c| c == '\\' || c == '/');
    if trimmed.is_empty() {
        text.into_owned()
    } else {
        trimmed.to_string()
    }
}

/// UTF-8 字符串转 UTF-16（带结尾 0），供 Win32 宽字符 API 使用。
fn to_wide(s: &str) -> Vec<u16> {
    OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect()
}

// ---------------------------------------------------------------------------
// PE VERSIONINFO 解析（get_process_file_description / get_process_publisher 用）
// 策略：用 GetFileVersionInfoW 拉取整个 VERSIONINFO 资源，然后手动按
// VS_VERSIONINFO / StringFileInfo / StringTable / String 结构解析字符串表，
// 避开 VerQueryValueW 在 windows 0.58 下返回类型的不确定性。
// ---------------------------------------------------------------------------

/// VERSIONINFO 中所有子块按 4 字节对齐（相对资源起始）。
fn align4(n: usize) -> usize {
    (n + 3) & !3
}

/// 读取一个 VERSIONINFO 块头。
/// 返回 (块总长 wLength, 值长 wValueLength, 键名 szKey, 值起始偏移, 子块起始偏移)。
fn read_version_block(buf: &[u8], off: usize) -> Option<(usize, usize, String, usize, usize)> {
    if off + 6 > buf.len() {
        return None;
    }
    let len = u16::from_le_bytes([buf[off], buf[off + 1]]) as usize;
    let val_len = u16::from_le_bytes([buf[off + 2], buf[off + 3]]) as usize;
    // wType 位于 off+4..6（0=二进制 1=文本），这里不需要
    let mut p = off + 6;
    let mut key = String::new();
    while p + 2 <= buf.len() && p + 2 <= off + len {
        let ch = u16::from_le_bytes([buf[p], buf[p + 1]]);
        p += 2;
        if ch == 0 {
            return Some((len, val_len, key, align4(p), if val_len > 0 { align4(align4(p) + val_len) } else { align4(p) }));
        }
        key.push(char::from_u32(ch as u32).unwrap_or('\u{FFFD}'));
        if key.len() > 128 {
            return None; // 防御异常数据
        }
    }
    None
}

/// 遍历 VERSIONINFO 缓冲区，把字符串表收集成 map（键如 "FileDescription"）。
fn collect_version_strings(buf: &[u8], map: &mut HashMap<String, String>) {
    let Some((root_len, _val_len, root_key, _val_off, children_off)) = read_version_block(buf, 0)
    else {
        return;
    };
    if root_key != "VS_VERSION_INFO" || root_len == 0 {
        return; // 缓冲区无效（大概率 GetFileVersionInfoW 失败，内容仍为全零）
    }
    let root_end = root_len.min(buf.len());

    // 一级子块：StringFileInfo / VarFileInfo
    let mut cur = children_off;
    while cur + 6 <= root_end {
        let Some((sfi_len, _l, sfi_key, _v, sfi_children)) = read_version_block(buf, cur) else {
            break;
        };
        if sfi_len == 0 {
            break;
        }
        let sfi_end = (cur + sfi_len).min(root_end);
        if sfi_key == "StringFileInfo" {
            // 二级子块：StringTable（键为 "040904b0" 之类的语言/代码页）
            let mut t = sfi_children;
            while t + 6 <= sfi_end {
                let Some((tbl_len, _l, _tbl_key, _v, tbl_children)) = read_version_block(buf, t)
                else {
                    break;
                };
                if tbl_len == 0 {
                    break;
                }
                let tbl_end = (t + tbl_len).min(sfi_end);
                // 三级子块：String（注意：String 的 wValueLength 单位是“字”，即 2 字节）
                let mut s = tbl_children;
                while s + 6 <= tbl_end {
                    let Some((str_len, val_words, str_key, val_off, _)) =
                        read_version_block(buf, s)
                    else {
                        break;
                    };
                    if str_len == 0 {
                        break;
                    }
                    let val_bytes = val_words.saturating_mul(2);
                    if val_words > 0 && val_off + val_bytes <= buf.len() {
                        let mut value = String::new();
                        let mut q = val_off;
                        while q + 2 <= val_off + val_bytes {
                            let ch = u16::from_le_bytes([buf[q], buf[q + 1]]);
                            q += 2;
                            if ch == 0 {
                                break;
                            }
                            value.push(char::from_u32(ch as u32).unwrap_or('\u{FFFD}'));
                        }
                        map.entry(str_key).or_insert(value);
                    }
                    s += align4(str_len);
                }
                t += align4(tbl_len);
            }
        }
        cur += align4(sfi_len);
    }
}

/// 读取 exe 的 VERSIONINFO 字符串表。失败（文件不存在/无版本资源）返回空 map。
fn load_version_map(exe_path: &str) -> HashMap<String, String> {
    let wide = to_wide(exe_path);
    // 64KiB 足以容纳绝大多数 VERSIONINFO；失败时缓冲区保持全零，解析会安全返回空表
    let mut buf = vec![0u8; 64 * 1024];
    unsafe {
        // GetFileVersionInfoW 在 windows 0.58 下的返回类型不做依赖（BOOL/Result 均可）：
        // 用 `let _ =` 吞掉，成功与否由后续解析结果决定
        let _ = GetFileVersionInfoW(
            PCWSTR(wide.as_ptr()),
            0, // dwhandle：保留参数，必须为 0
            buf.len() as u32,
            buf.as_mut_ptr() as *mut core::ffi::c_void,
        );
    }
    let mut map = HashMap::new();
    collect_version_strings(&buf, &mut map);
    map
}

// ---------------------------------------------------------------------------
// api::sysinfo::adapter
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::adapter ----

/// 禁用系统代理（写 HKCU\...\Internet Settings\ProxyEnable = 0）
pub fn disable_proxy() -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoAdapterRDisableProxy
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let key = hkcu.open_subkey_with_flags(INET_SETTINGS_PATH, KEY_SET_VALUE)?;
    key.set_value("ProxyEnable", &0u32)?;
    Ok(())
}

/// 启用指定网络适配器（参考实现走 SetupDi 系列 API；这里退化为 netsh，需管理员权限）
pub fn enable_adapter(adapter_name: String) -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoAdapterREnableAdapter
    let name_arg = format!("name={}", adapter_name);
    let out = Command::new("netsh")
        .args(["interface", "set", "interface", name_arg.as_str(), "admin=enable"])
        .output()
        .context("执行 netsh 启用网卡失败")?;
    ensure!(
        out.status.success(),
        "启用网卡失败: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    Ok(())
}

/// 修复 hosts：把 hosts 恢复为默认内容（仅保留空行/注释/localhost 行）。
/// 返回是否实际执行了修复。修改 hosts 需要管理员权限。
pub fn fix_host_configed() -> anyhow::Result<bool> {
    // frb codec: crateApiSysinfoAdapterRFixHostConfiged
    if !host_configed()? {
        return Ok(false);
    }
    let path = hosts_path();
    let content = std::fs::read_to_string(&path)?;
    // 先备份原文件（同目录 hosts.cm_rebuild.bak，失败不阻断）
    let backup = path
        .parent()
        .map(|p| p.join("hosts.cm_rebuild.bak"))
        .unwrap_or_else(|| path.with_extension("bak"));
    let _ = std::fs::write(&backup, &content);
    let cleaned: Vec<&str> = content.lines().filter(|l| is_default_host_line(l)).collect();
    // **先写临时文件再改名**：`fs::write` 是"打开→截断→逐字节写"，中途失败/断电
    // 会留下一个**被截断的 hosts**——而 hosts 是系统级文件，坏了连网卡都配不出来。
    // 备份已经落盘，所以即使改名那步失败，原文件仍在备份里可恢复。
    let tmp = path.with_extension("hosts.cm_rebuild.tmp");
    std::fs::write(&tmp, cleaned.join("\r\n") + "\r\n")?;
    // rename 到已存在的目标在 Windows 上可能失败（文件被占用），失败则**保留原文件**
    // 并把错误抛上去——宁可报"没改成"，也不要留一个半截的 hosts。
    std::fs::rename(&tmp, &path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp); // 别把临时文件留在系统目录里
        anyhow::anyhow!("替换 hosts 失败（{}）：{e}；原文件备份在 {}", path.display(), backup.display())
    })?;
    // 刷新 DNS 只是收尾，主文件已改成功就不该因为它失败而报"修复失败"
    let _ = Command::new("ipconfig").arg("/flushdns").status();
    Ok(true)
}

/// 适配器数量（WMI 行数）
///
/// ⚠ **故意不给 UI 出口**：这个数**不能**当"网卡数量"的判据。
/// `Win32_NetworkAdapterConfiguration` 一行一个**适配器配置**，包含 WAN Miniport、
/// Network Monitor、内核调试适配器等一堆没在用的虚拟网卡——实测本机它返回 **12**，
/// 而真正在用的只有 **1** 张（`netsh interface show interface` 只有一条）。
/// 拿它去报「网卡数量异常」(`:66`) 会在一台完全正常的机器上喊故障。
///
/// 体检那边用的是**带真默认网关的网卡数**（见 `ExaminationSource.adapterList` /
/// `RustApi.adapterList`，判据是"多张同时在用"），那才是"出站路由在看运气"的语义。
/// 所以这条 Rust 函数保留（接口面对齐需要），但适配层**不接出口**。
pub fn get_adapter_size() -> anyhow::Result<usize> {
    // frb codec: crateApiSysinfoAdapterRGetAdapterSize
    Ok(get_adapterinfo_list()?.len())
}

/// 网络适配器列表（WMI Win32_NetworkAdapterConfiguration：
/// Description / IP / DHCPEnabled / DNSServerSearchOrder / 网关 / MAC）
pub fn get_adapterinfo_list() -> anyhow::Result<Vec<AdapterInfo>> {
    // frb codec: crateApiSysinfoAdapterRGetAdapterinfoList
    let con = wmi_connection()?;
    let rows: Vec<Win32_NetworkAdapterConfiguration> = con.query()?;
    Ok(rows
        .into_iter()
        .map(|r| AdapterInfo {
            description: r.Description,
            mac_address: r.MACAddress.unwrap_or_default(),
            ip_addresses: r.IPAddress.unwrap_or_default(),
            gateways: r.DefaultIPGateway.unwrap_or_default(),
            dhcp_enabled: r.DHCPEnabled,
            dns_servers: r.DNSServerSearchOrder.unwrap_or_default(),
            netsh_name: r
                .SettingID
                .as_deref()
                .and_then(netsh_name_for)
                .unwrap_or_default(),
        })
        .collect())
}

/// DHCP / DNS 状态：首元素为 DHCP 是否开启（"true"/"false"），其后为 DNS 服务器列表。
/// 取第一个有 IP 的适配器，没有则取第一个适配器。
pub fn get_dhcp_and_dns_status() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoAdapterRGetDhcpAndDnsStatus
    let adapters = get_adapterinfo_list()?;
    let target = adapters
        .iter()
        .find(|a| !a.ip_addresses.is_empty())
        .or_else(|| adapters.first());
    match target {
        Some(a) => {
            let mut out = vec![a.dhcp_enabled.to_string()];
            out.extend(a.dns_servers.iter().cloned());
            Ok(out)
        }
        // 一张网卡都没有时**不能**报 "false"——那是在说"DHCP 关着"，
        // 而真实情况是"没查到任何网卡，关不关根本无从谈起"。
        // 返回**空列表**：调用方（RustApi.diagnoseNetwork）本就把它当作
        // "没读到有效 DNS"，空列表与真实探测到的空 DNS 一样处理，不会误报。
        None => Ok(Vec::new()),
    }
}

/// 是否开启了手动代理（HKCU\...\Internet Settings\ProxyEnable != 0）
pub fn has_manual_proxy() -> anyhow::Result<bool> {
    // frb codec: crateApiSysinfoAdapterRHasManualProxy
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let key = hkcu.open_subkey(INET_SETTINGS_PATH)?;
    // 值缺失 ≠ 关着：`ProxyEnable` 整个不存在时 `unwrap_or(0)` 会报"没开代理"，
    // 而真实情况是"查不到这个设置"（本机该值确实存在且为 0，那种机器不受影响）。
    // 这里让缺失冒泡成 Err —— 上层 `networkOverrides()` 已有三态处理，
    // 会把这一项标成"未读到"而不是"干净"。
    let enable: u32 = key.get_value("ProxyEnable")?;
    Ok(enable != 0)
}

/// hosts 是否被配置过（存在非默认行）
pub fn host_configed() -> anyhow::Result<bool> {
    // frb codec: crateApiSysinfoAdapterRHostConfiged
    let path = hosts_path();
    if !path.exists() {
        return Ok(false);
    }
    let content = std::fs::read_to_string(&path)?;
    Ok(content.lines().any(|l| !is_default_host_line(l)))
}

/// TCP 连通性探测：连 `1.1.1.1:80`，1 秒超时。
///
/// ⚠ 这**不是**「外网能不能上」的结论，只是"到 Cloudflare 某个 IP 的 80 端口
/// 能不能建连"。挡门户（captive portal）、只放行 443 的代理、或把 1.1.1.1:80
/// 黑洞掉的网络，都会在这里报不通，而机器其实能上网。
/// 所以界面上一律说「外网探测」并给「看实测」的出口，不把这一位的 false
/// 当成"网络故障"的定论。
pub fn net_available() -> anyhow::Result<bool> {
    // frb codec: crateApiSysinfoAdapterRNetAvailable
    let probe: SocketAddr = "1.1.1.1:80".parse()?;
    Ok(TcpStream::connect_timeout(&probe, Duration::from_secs(1)).is_ok())
}

/// 用记事本打开 hosts 文件，返回 hosts 路径
pub fn notepad_open_host() -> anyhow::Result<String> {
    // frb codec: crateApiSysinfoAdapterRNotepadOpenHost
    let path = hosts_path();
    Command::new("notepad.exe")
        .arg(&path)
        .spawn()
        .context("启动记事本失败")?;
    Ok(path.to_string_lossy().into_owned())
}

/// 打开系统“代理服务器”设置页（ms-settings:network-proxy）
pub fn open_setting_network_proxy_page() -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoAdapterROpenSettingNetworkProxyPage
    Command::new("explorer.exe")
        .arg("ms-settings:network-proxy")
        .spawn()
        .context("打开系统代理设置页失败")?;
    Ok(())
}

/// 把指定适配器的 DNS 恢复为 DHCP 自动获取（netsh，需管理员权限）
pub fn set_adapter_dhcp(adapter_name: String) -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoAdapterRSetAdapterDhcp
    let name_arg = format!("name={}", adapter_name);
    let out = Command::new("netsh")
        .args(["interface", "ip", "set", "dns", name_arg.as_str(), "dhcp"])
        .output()
        .context("执行 netsh 恢复 DHCP DNS 失败")?;
    ensure!(
        out.status.success(),
        "恢复 DHCP DNS 失败: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    Ok(())
}

/// 设置指定适配器的静态 DNS（netsh interface ip set/add dns，需管理员权限）。
/// dns_servers[0] 为主 DNS，其余按 index 依次追加为备用 DNS。
pub fn set_adapter_dns(adapter_name: String, dns_servers: Vec<String>) -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoAdapterRSetAdapterDns
    if dns_servers.is_empty() {
        bail!("DNS 列表为空");
    }
    let name_arg = format!("name={}", adapter_name);
    let primary = dns_servers[0].clone();
    let out = Command::new("netsh")
        .args([
            "interface",
            "ip",
            "set",
            "dns",
            name_arg.as_str(),
            "static",
            primary.as_str(),
        ])
        .output()
        .context("执行 netsh 设置主 DNS 失败")?;
    ensure!(
        out.status.success(),
        "设置主 DNS 失败: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    for (idx, dns) in dns_servers.iter().skip(1).enumerate() {
        let idx_arg = format!("index={}", idx + 2);
        let out = Command::new("netsh")
            .args([
                "interface",
                "ip",
                "add",
                "dns",
                name_arg.as_str(),
                dns.as_str(),
                idx_arg.as_str(),
            ])
            .output()
            .context("执行 netsh 添加备用 DNS 失败")?;
        ensure!(
            out.status.success(),
            "添加备用 DNS({dns}) 失败: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(())
}

/// 网络修复：刷新 DNS 缓存 + 重置 Winsock 目录。
/// 注意：netsh winsock reset 需要管理员权限，且重置后需重启系统才能完全生效。
pub fn set_network_fix() -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoAdapterRSetNetworkFix
    Command::new("ipconfig")
        .arg("/flushdns")
        .status()
        .context("执行 ipconfig /flushdns 失败")?;
    Command::new("netsh")
        .args(["winsock", "reset"])
        .status()
        .context("执行 netsh winsock reset 失败")?;
    Ok(())
}

// ---------------------------------------------------------------------------
// api::sysinfo::app_check
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::app_check ----

/// 枚举已安装应用（HKLM Uninstall + WOW6432Node + HKCU Uninstall），
/// 过滤 DisplayName 为空的项。
pub fn check_app2() -> anyhow::Result<Vec<InstalledAppInfo>> {
    // frb codec: crateApiSysinfoAppCheckRCheckApp2
    let mut out = Vec::new();
    collect_uninstall(HKEY_LOCAL_MACHINE, "HKLM", UNINSTALL_HKLM, &mut out);
    collect_uninstall(HKEY_LOCAL_MACHINE, "HKLM", UNINSTALL_WOW, &mut out);
    collect_uninstall(HKEY_CURRENT_USER, "HKCU", UNINSTALL_HKCU, &mut out);
    Ok(out)
}

/// 遍历某个 Uninstall 根下的所有子键，收集卸载信息（单个根读取失败不阻断整体）。
fn collect_uninstall(root_hive: HKEY, root_label: &str, sub: &str, out: &mut Vec<InstalledAppInfo>) {
    let root = RegKey::predef(root_hive);
    let key = match root.open_subkey(sub) {
        Ok(k) => k,
        Err(_) => return,
    };
    for sub_name in key.enum_keys() {
        let Ok(sub_name) = sub_name else { continue };
        let Ok(item) = key.open_subkey(sub_name.as_str()) else { continue };
        let name: String = item.get_value("DisplayName").unwrap_or_default();
        if name.trim().is_empty() {
            continue; // DisplayName 为空的项按约定过滤
        }
        let version: String = item.get_value("DisplayVersion").unwrap_or_default();
        let publisher: String = item.get_value("Publisher").unwrap_or_default();
        let uninstall_string: String = item.get_value("UninstallString").unwrap_or_default();
        let display_icon: String = item.get_value("DisplayIcon").unwrap_or_default();
        // 先算再 move：launch_target 要读 display_icon，而下面把它移进结构体。
        let launch_target = app_launch_target(&display_icon);
        out.push(InstalledAppInfo {
            name,
            version,
            publisher,
            uninstall_string,
            display_icon,
            launch_target,
            uninstall_key: format!("{}\\{}\\{}", root_label, sub, sub_name),
        });
    }
}

/// 从 DisplayIcon 原值里取出图标文件路径。
/// 形如 `"C:\Program Files\a.exe",0`（引号内可含逗号）或 `C:\a.exe, 0`，也可能只有路径。
fn display_icon_path(raw: &str) -> String {
    let raw = raw.trim();
    if raw.is_empty() {
        return String::new();
    }
    let path = if raw.starts_with('"') {
        // 引号分支：取第一对引号之间的内容，后面才是 ,index
        match raw[1..].find('"') {
            Some(end) => raw[1..1 + end].to_string(),
            None => raw.trim_matches('"').to_string(),
        }
    } else {
        // 无引号：Windows 约定路径不含逗号，按最后一个逗号切分索引
        match raw.rfind(',') {
            Some(i) => raw[..i].to_string(),
            None => raw.to_string(),
        }
    };
    expand_env_vars(path.trim().trim_matches('"'))
}

/// 展开注册表里常见的 `%VAR%`（DisplayIcon 常存成 `%SystemRoot%\System32\shell32.dll,-154`）。
/// `%` 是 ASCII，按字节定位不会切断 UTF-8 边界；无法识别的 `%` 原样保留。
fn expand_env_vars(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(pos) = rest.find('%') {
        out.push_str(&rest[..pos]);
        let after = &rest[pos + 1..];
        match after.find('%') {
            Some(end) if end > 0 => {
                let name = &after[..end];
                match std::env::var(name) {
                    Ok(v) => out.push_str(&v),
                    Err(_) => out.push_str(&format!("%{name}%")),
                }
                rest = &after[end + 1..];
            }
            _ => {
                out.push('%');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// 从 `DisplayIcon` 原值推出可启动的目标（`.exe` 全路径）；推不出返回 `None`。
///
/// **DisplayIcon 是图标字段，不保证是程序本体**，所以不能直接拿它当启动目标：
/// 实测本机 31 个带图标的已装应用里 24 个确实指向存在的 `.exe`，另有 7 个指向
/// `.ico`（`uninstallerIcon.ico`、`devenv.ico` 这类卸载器/资源图标）——
/// 把 `.ico` 交给 `ShellExecuteW` 会用**打开方式**去问用户，完全不是"启动应用"。
/// 另有一类只给文件名（`imagernd.dll,-100`），落在 System32 也不该当成可启动程序。
///
/// 判据三条同时成立才算数：**是 `.exe`**、**路径确实存在**、不是空串。
/// 少一条就返回 `None`——界面据此不给「启动」入口，
/// 那比给一个点了没反应/弹出选择框的按钮诚实。
fn app_launch_target(display_icon: &str) -> Option<String> {
    let path = display_icon_path(display_icon);
    if path.is_empty() {
        return None;
    }
    let p = Path::new(&path);
    if !p.is_file() {
        return None;
    }
    if !p
        .extension()
        .map(|e| e.eq_ignore_ascii_case("exe"))
        .unwrap_or(false)
    {
        return None;
    }
    Some(path)
}

/// 取应用图标像素：SHGetFileInfoW 取 shell 大图标 → GetIconInfo 拆颜色/蒙版位图
/// → GetDIBits 读 32bpp 顶层行序 → BGRA 换 RGBA。
/// 颜色面没有 alpha 的老式图标改用 1bpp AND 蒙版定透明度（蒙版位 1 为透明）。
/// 图标取不到时报错，由界面降级成占位图，不影响列表其它信息。
pub fn extract_app_icon(display_icon: String) -> anyhow::Result<AppIconPixels> {
    let mut path = display_icon_path(&display_icon);
    ensure!(!path.is_empty(), "没有 DisplayIcon");
    if !Path::new(&path).is_file() && !path.contains('\\') && !path.contains('/') {
        // 只给文件名的项（如 imagernd.dll,-100）按 Windows 查找约定回落到 System32
        if let Some(root) = std::env::var("SystemRoot").ok() {
            let candidate = Path::new(&root).join("System32").join(&path);
            if candidate.is_file() {
                path = candidate.to_string_lossy().into_owned();
            }
        }
    }
    ensure!(Path::new(&path).is_file(), "图标文件不存在: {path}");

    let wide = to_wide(&path);
    let index = display_icon_index(&display_icon);
    // DisplayIcon 指向 .ico 时要的是文件内部的图标；shell 的「文件图标」约定会返回
    // ICO 类型图标（Explorer 里 .ico 就是那张带 ICO 角标的白纸），所以内部图标优先。
    let embedded_first = path.to_ascii_lowercase().ends_with(".ico");
    // shell 的图标提取要经 COM 图标处理器；frb 的工作线程不保证已初始化 COM，
    // 未初始化时 chrome.exe / Weixin.exe 这类文件会返回空 hIcon（notepad 等系统
    // 图标走缓存能命中，所以只在真机列表上暴露）。
    with_com_initialized(|| unsafe {
        let mut diag = String::from("两条路由都没走到 shell");
        let hicon = if embedded_first {
            extract_pe_icon(&wide, index).or_else(|| shell_icon(&wide, &mut diag))
        } else {
            shell_icon(&wide, &mut diag).or_else(|| extract_pe_icon(&wide, index))
        };
        let hicon = match hicon {
            Some(h) => h,
            // 带上 shell 的返回值与错误码：只有「取不到」时才知道是 COM、权限还是文件没图标
            None => return Err(anyhow!("未取得图标: {path} (索引 {index}, {diag})")),
        };
        let pixels = icon_to_rgba(hicon);
        let _ = DestroyIcon(hicon); // 位图归图标所有，只能随 DestroyIcon 一起释放
        pixels
    })
}

/// shell 大图标（经 COM 图标处理器）。失败时把 shell 返回值与错误码写进 [diag]，
/// 供上层拼进错误信息——界面上只剩占位图，没有这两个数字无从判断原因。
unsafe fn shell_icon(wide: &[u16], diag: &mut String) -> Option<HICON> {
    let mut sfi: SHFILEINFOW = std::mem::zeroed();
    // 返回值不决定成败（成功与否由 hIcon 判定），只留作诊断信息
    let ret = SHGetFileInfoW(
        PCWSTR(wide.as_ptr()),
        FILE_FLAGS_AND_ATTRIBUTES(0),
        Some(&mut sfi),
        size_of::<SHFILEINFOW>() as u32,
        SHGFI_ICON | SHGFI_LARGEICON,
    );
    *diag = format!("shell ret={ret}, shellErr={}", windows::core::Error::from_win32());
    if sfi.hIcon.is_invalid() {
        None
    } else {
        Some(sfi.hIcon)
    }
}

/// DisplayIcon 尾部的图标索引（形如 `"C:\a.exe",1` → 1）；缺失或不是数字按 0，即主图标。
fn display_icon_index(raw: &str) -> i32 {
    let raw = raw.trim();
    let tail = if raw.starts_with('"') {
        // 引号分支：闭合引号之后是 ",index"
        match raw[1..].find('"') {
            Some(end) => &raw[1 + end + 1..],
            None => "",
        }
    } else {
        match raw.rfind(',') {
            Some(i) => &raw[i + 1..],
            None => "",
        }
    };
    tail.trim().trim_start_matches(',').trim().parse::<i32>().unwrap_or(0)
}

/// ExtractIconExW 按零基索引取 PE 资源图标，不经 shell。
/// 负索引是资源 ID 约定（如 `shell32.dll,-154`），与这里的零基索引不等价，
/// 兜底取错图标比显示占位图更误导人，所以直接放弃。
unsafe fn extract_pe_icon(wide: &[u16], index: i32) -> Option<HICON> {
    if index < 0 {
        return None;
    }
    let mut hicon = HICON(std::ptr::null_mut());
    let count = ExtractIconExW(PCWSTR(wide.as_ptr()), index, Some(&mut hicon), None, 1);
    if count == 0 || hicon.is_invalid() {
        return None;
    }
    Some(hicon)
}

/// 在当前线程临时初始化 COM 执行 [f]，只在本次真正取得初始化权时配对反初始化。
/// 线程已按其它模型初始化过（RPC_E_CHANGED_MODE）时直接沿用现状，不再 Uninitialize。
fn with_com_initialized<T>(f: impl FnOnce() -> T) -> T {
    let owned = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) }.is_ok();
    let out = f();
    if owned {
        unsafe { CoUninitialize() }
    }
    out
}

/// HICON → RGBA 像素。尺寸取自颜色位图本身，避免按固定值读取导致裁切或拉伸。
unsafe fn icon_to_rgba(hicon: HICON) -> anyhow::Result<AppIconPixels> {
    let mut info: ICONINFO = std::mem::zeroed();
    let _ = GetIconInfo(hicon, &mut info);
    let color = info.hbmColor;
    ensure!(!color.0.is_null(), "图标没有颜色位图（可能是光标资源）");

    let (width, height) = bitmap_size(color)?;
    let count = width as usize * height as usize;
    let mut rgba = vec![0u8; count * 4];
    let hdc = CreateCompatibleDC(None);
    let old = SelectObject(hdc, HGDIOBJ(color.0));
    let rows = {
        let mut bi: BITMAPINFO = std::mem::zeroed();
        bi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
        bi.bmiHeader.biWidth = width as i32;
        bi.bmiHeader.biHeight = -(height as i32); // 负值 = top-down，行序与 Dart 侧一致
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = 0; // BI_RGB：32bpp 不使用压缩字段
        GetDIBits(
            hdc,
            color,
            0,
            height,
            Some(rgba.as_mut_ptr() as *mut core::ffi::c_void),
            &mut bi,
            DIB_RGB_COLORS,
        )
    };
    SelectObject(hdc, old);
    let _ = DeleteDC(hdc);
    ensure!(rows == height as i32, "GetDIBits 只取到 {rows} 行，应为 {height} 行");

    // BGRA → RGBA，同时确认颜色面是否自带 alpha
    let mut has_alpha = false;
    for px in rgba.chunks_exact_mut(4) {
        px.swap(0, 2);
        has_alpha |= px[3] != 0;
    }
    if !has_alpha {
        apply_and_mask(&mut rgba, info.hbmMask, width as usize, height as usize);
    }
    Ok(AppIconPixels { width, height, rgba })
}

/// 位图实际宽高（图标颜色面/蒙版共用）。
unsafe fn bitmap_size(bmp: HBITMAP) -> anyhow::Result<(u32, u32)> {
    let mut bm: BITMAP = std::mem::zeroed();
    let n = GetObjectW(
        HGDIOBJ(bmp.0),
        size_of::<BITMAP>() as i32,
        Some(&mut bm as *mut BITMAP as *mut core::ffi::c_void),
    );
    ensure!(n == size_of::<BITMAP>() as i32, "GetObjectW 读取位图信息失败");
    ensure!(bm.bmWidth > 0 && bm.bmHeight > 0, "图标位图尺寸异常");
    Ok((bm.bmWidth as u32, bm.bmHeight as u32))
}

/// 用 1bpp AND 蒙版补 alpha：蒙版位 1 透明、0 不透明。
/// 蒙版是自下而上存储的单色位图，每行按 4 字节对齐，这里读回后再翻正行序。
unsafe fn apply_and_mask(rgba: &mut [u8], mask: HBITMAP, width: usize, height: usize) {
    if mask.0.is_null() {
        return; // 既无 alpha 也无蒙版，保持全不透明，至少图标可见
    }
    let row_bytes = (width.div_ceil(32)) * 4;
    let mut m = vec![0u8; row_bytes * height];
    let hdc = CreateCompatibleDC(None);
    let old = SelectObject(hdc, HGDIOBJ(mask.0));
    let rows = {
        let mut bi: BITMAPINFO = std::mem::zeroed();
        bi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
        bi.bmiHeader.biWidth = width as i32;
        bi.bmiHeader.biHeight = height as i32; // 正值 = bottom-up，与蒙版存储方向一致
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 1;
        GetDIBits(
            hdc,
            mask,
            0,
            height as u32,
            Some(m.as_mut_ptr() as *mut core::ffi::c_void),
            &mut bi,
            DIB_RGB_COLORS,
        )
    };
    SelectObject(hdc, old);
    let _ = DeleteDC(hdc);
    if rows != height as i32 {
        return;
    }
    for y in 0..height {
        let mrow = height - 1 - y;
        for x in 0..width {
            let bit = (m[mrow * row_bytes + x / 8] >> (7 - x % 8)) & 1;
            rgba[(y * width + x) * 4 + 3] = if bit == 1 { 0 } else { 255 };
        }
    }
}

/// 启动指定应用的卸载程序：按 uninstall_key 定位注册表项并执行其 UninstallString。
/// 卸载串可能自带引号与参数，交给 cmd /C 解析执行。
pub fn uninstall_app(uninstall_key: String) -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoAppCheckRUninstallApp
    let (hive_label, sub_path) = uninstall_key
        .split_once('\\')
        .ok_or_else(|| anyhow!("无效的卸载注册表键: {uninstall_key}"))?;
    let hive = match hive_label.to_ascii_uppercase().as_str() {
        "HKLM" => HKEY_LOCAL_MACHINE,
        "HKCU" => HKEY_CURRENT_USER,
        other => bail!("不支持的注册表根: {other}"),
    };
    let root = RegKey::predef(hive);
    let key = root.open_subkey(sub_path)?;
    let uninstall_string: String = key.get_value("UninstallString").unwrap_or_default();
    ensure!(
        !uninstall_string.trim().is_empty(),
        "该应用没有 UninstallString: {uninstall_key}"
    );
    Command::new("cmd")
        .args(["/C", uninstall_string.as_str()])
        .spawn()
        .context("启动卸载程序失败")?;
    Ok(())
}

/// 监控式卸载。
/// TODO：参考实现在启动卸载程序后会轮询等待卸载进程退出并回报进度；
/// 当前先复用直接启动逻辑，监控循环留待后续补充。
///
/// ⚠ **故意不给出口**：它现在**没有监控**，只是转手调 `uninstall_app`。
/// 名字里的 "Moint" 会让人以为它回报进度——接一个"监控式卸载"按钮进去，
/// 实际既不监控也不回报，比老实叫「卸载」更差。
/// 真要接，得先把轮询循环写出来（等卸载进程退出再回报），那才是这个接口的含义。
pub fn uninstall_app_moint(uninstall_key: String) -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoAppCheckRUninstallAppMoint
    uninstall_app(uninstall_key)
}

// ---------------------------------------------------------------------------
// api::sysinfo::component_detect
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::component_detect ----

/// 创建并以自动方式启动服务（sc.exe create + start，需管理员权限）。
/// sc 的经典语法要求 "binPath=" 与值分开传参，这里保持一致。
pub fn install_start_service(service_name: String, bin_path: String) -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoComponentDetectRInstallStartService
    let out = Command::new("sc.exe")
        .args([
            "create",
            service_name.as_str(),
            "binPath=",
            bin_path.as_str(),
            "start=",
            "auto",
        ])
        .output()
        .context("执行 sc create 失败")?;
    ensure!(
        out.status.success(),
        "sc create 失败: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let out = Command::new("sc.exe")
        .args(["start", service_name.as_str()])
        .output()
        .context("执行 sc start 失败")?;
    ensure!(
        out.status.success(),
        "sc start 失败: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    Ok(())
}

/// 版本号分段比较。返回单元素向量："1"=a 更新，"0"=相同，"-1"=a 更旧。
/// 以 . - _ 作为分段符；数字段按数值比较，否则按字符串比较。
///
/// ⚠ **故意不给 UI 出口**（负向结论）：缺的不是"会不会比"，而是**没有"该比成多少"的来源**——
/// 本项目读 `config.ini` 只取 `[config] basehost` 与 `[compat] incompatible` 两个键
/// （`feedback_service.readIniSection` 的调用点就这两处），既没有组件版本基线也没有下发通道。
/// 接进体检就只能凭空定一个阈值，那是编造判据。
/// 参考实现同族的是「开始修复组件项 / 修复结果为」那套**组件修复**流程，
/// 而修复要的下载与安装能力我们没有（与 5 个补丁安装 codec 同批结论）。
pub fn judge_version(version_a: String, version_b: String) -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoComponentDetectRJudgeVersion
    let seg = |s: &str| -> Vec<String> {
        s.split(|c: char| c == '.' || c == '-' || c == '_')
            .map(|x| x.trim().to_string())
            .filter(|x| !x.is_empty())
            .collect()
    };
    let a = seg(&version_a);
    let b = seg(&version_b);
    let mut result = "0";
    for i in 0..a.len().max(b.len()) {
        let sa = a.get(i).map(|s| s.as_str()).unwrap_or("0");
        let sb = b.get(i).map(|s| s.as_str()).unwrap_or("0");
        let ord = match (sa.parse::<u64>(), sb.parse::<u64>()) {
            (Ok(x), Ok(y)) => x.cmp(&y),
            _ => sa.cmp(sb),
        };
        if ord != std::cmp::Ordering::Equal {
            result = if ord == std::cmp::Ordering::Greater { "1" } else { "-1" };
            break;
        }
    }
    Ok(vec![result.to_string()])
}

/// 停止并重新启动服务（sc stop → 等待 1.5s → sc start，需管理员权限）。
/// 若服务进程僵死导致 stop 失败，可由上层先 taskkill /F 再调用本接口。
pub fn kill_restart_service(service_name: String) -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoComponentDetectRKillRestartService
    let _ = Command::new("sc.exe").args(["stop", service_name.as_str()]).output();
    thread::sleep(Duration::from_millis(1500));
    let out = Command::new("sc.exe")
        .args(["start", service_name.as_str()])
        .output()
        .context("执行 sc start 失败")?;
    ensure!(
        out.status.success(),
        "重启服务失败: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    Ok(())
}

/// 查询服务状态（sc.exe query，解析 STATE 行），返回 RUNNING/STOPPED/UNKNOWN 等。
pub fn service_status(service_name: String) -> anyhow::Result<String> {
    // frb codec: crateApiSysinfoComponentDetectRServiceStatus
    let out = Command::new("sc.exe")
        .args(["query", service_name.as_str()])
        .output()
        .context("执行 sc query 失败")?;
    let text = String::from_utf8_lossy(&out.stdout);
    let state = text
        .lines()
        .find(|l| l.contains("STATE"))
        .and_then(|l| l.split(':').nth(1))
        .and_then(|s| s.trim().split_whitespace().nth(1).map(|x| x.to_string()))
        // 区分"服务不存在"与"解析失败"：两者都落到 UNKNOWN，上层就只能说
        // 「未安装/不可查询」——可实际上 Windows 已经把原因写在**stderr** 里了
        // （实测 `sc query NoSuchService` 打印 "1060: 指定的服务未安装" 而
        // **退出码仍是 0**，所以 .output() 不算失败，只能自己看输出）。
        // 分成 NOT_INSTALLED / UNKNOWN 两个值，界面上就能说准是哪种。
        .unwrap_or_else(|| {
            if text.contains("1060") {
                "NOT_INSTALLED".to_string()
            } else {
                "UNKNOWN".to_string()
            }
        });
    Ok(state)
}

/// 启动服务（sc.exe start），返回命令输出
pub fn start_service(service_name: String) -> anyhow::Result<String> {
    // frb codec: crateApiSysinfoComponentDetectRStartService
    run_tool("sc.exe", &["start".to_string(), service_name])
}

// ---------------------------------------------------------------------------
// api::sysinfo::computer_type
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::computer_type ----

/// 机型类型：WMI Win32_ComputerSystem。
/// PCSystemType 映射（按原口径推断）：1=PC（台式）、2=System（移动/笔记本）、
/// 3=Workstation，其余为 Unspecified。
/// 返回 [类型, 厂商, 型号]。
pub fn get_computer_type() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoComputerTypeRGetComputerType
    let con = wmi_connection()?;
    let rows: Vec<Win32_ComputerSystem> = con.query()?;
    let row = rows
        .into_iter()
        .next()
        .ok_or_else(|| anyhow!("WMI 未返回 Win32_ComputerSystem"))?;
    let type_str = match row.PCSystemType {
        Some(1) => "PC",
        Some(2) => "System",
        Some(3) => "Workstation",
        _ => "Unspecified",
    };
    Ok(vec![
        type_str.to_string(),
        row.Manufacturer.unwrap_or_default(),
        row.Model.unwrap_or_default(),
    ])
}

/// Windows 详细版本号（读 HKLM\...\CurrentVersion 注册表，保留原拼写 detial）。
/// 返回 [ProductName, DisplayVersion, CurrentBuild, UBR, EditionID]。
pub fn get_win_detial_ver() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoComputerTypeRGetWinDetialVer
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let key = hklm.open_subkey(CURRENT_VERSION_PATH)?;
    let product: String = key.get_value("ProductName").unwrap_or_default();
    let display: String = key.get_value("DisplayVersion").unwrap_or_default();
    let build: String = key.get_value("CurrentBuild").unwrap_or_default();
    let ubr: u32 = key.get_value("UBR").unwrap_or(0);
    let edition: String = key.get_value("EditionID").unwrap_or_default();
    Ok(vec![product, display, build, ubr.to_string(), edition])
}

/// 路径是否存在（保留原拼写 exits）
pub fn is_path_exits(path: String) -> anyhow::Result<bool> {
    // frb codec: crateApiSysinfoComputerTypeRIsPathExits
    Ok(Path::new(&path).exists())
}

/// 把系统信息（版本 + 机型）写入 %ProgramData%\cm_rebuild\os_info.json
///
/// ⚠ **故意不给出口**（负向结论）：这个文件**只写不读**——全项目 `grep os_info`
/// 只有这里一个写入点，没有任何一处读它，agent 上报走的也不是这条路径。
/// 接出来等于每次点一下就在系统目录里多写一个没人看的 json（还要在
/// `%ProgramData%` 下建目录），属于「改了什么、但没人看」的隐形动作。
/// 与 [set_env] / [main_collect] 同族。**重复，不是缺口。**
pub fn set_os_info() -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoComputerTypeRSetOsInfo
    let ver = get_version_info()?;
    let ctype = get_computer_type()?.first().cloned().unwrap_or_default();
    let json = serde_json::json!({
        "product_name": ver.first().cloned().unwrap_or_default(),
        "display_version": ver.get(1).cloned().unwrap_or_default(),
        "current_build": ver.get(2).cloned().unwrap_or_default(),
        "ubr": ver.get(3).cloned().unwrap_or_default(),
        "computer_type": ctype,
    });
    let program_data = std::env::var("ProgramData").context("未找到 ProgramData 环境变量")?;
    let dir = PathBuf::from(program_data).join("cm_rebuild");
    std::fs::create_dir_all(&dir)?;
    std::fs::write(dir.join("os_info.json"), serde_json::to_string_pretty(&json)?)?;
    Ok(())
}

/// 启动 exe，返回子进程 PID 字符串
pub fn start_exe(exe_path: String) -> anyhow::Result<String> {
    // frb codec: crateApiSysinfoComputerTypeRStartExe
    // ⚠ **故意不给适配层出口**（第 13 条负向结论）：它就是 `Command::new(path).spawn()`
    // 再回一个 pid，而本项目「启动应用」走的是 [open_app]（`ShellExecuteW`）——
    // 那条路**已经被选过一次**，理由是这个函数体正是当初的命令注入面：
    // 直接把列表项/注册表来的字符串交给 `Command::new` 起进程。
    // 再接一个出口等于把同一个按钮接到更危险的那条实现上。**重复且更差，不是缺口。**
    let child = Command::new(&exe_path).spawn().context("启动 exe 失败")?;
    Ok(child.id().to_string())
}

// ---------------------------------------------------------------------------
// api::sysinfo::cup
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::cup ----

/// CPU 信息：先刷新一次建立采样基线，sleep 300ms 后再刷新取使用率。
/// 返回 [CPU 名称, 逻辑核数, 使用率%（保留 1 位小数）]。
pub fn read_cup_info() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoCupRReadCupInfo
    let mut sys = System::new();
    sys.refresh_cpu_usage();
    thread::sleep(Duration::from_millis(300));
    sys.refresh_cpu_usage();
    let usage = sys.global_cpu_usage();
    let brand = sys
        .cpus()
        .first()
        .map(|c| c.brand().trim().to_string())
        .unwrap_or_default();
    let cores = sys.cpus().len();
    Ok(vec![brand, cores.to_string(), format!("{usage:.1}")])
}

// ---------------------------------------------------------------------------
// api::sysinfo::cursor
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::cursor ----

/// 鼠标坐标（windows crate GetCursorPos），返回 [x, y] 字符串
///
/// ⚠ **故意不给出口**（负向结论）：本项目所有弹层定位都按**托盘图标槽位 / 加速球的原生
/// rect** 走（`tray_menu_host`、`acceleration_tools_host` 把矩形推给子窗口，由原生按目标
/// 显示器 DPI 换算并夹取到工作区），没有任何一处需要轮询鼠标位置。接出来就是一个
/// 定时读坐标、读完没处用的空转——与 [main_collect] 同族。
/// 它**该保留**的部分已经保留了：读失败返回空表而不是 `(0, 0)`（那是"API 失败、
/// 结果却像个真答案"那一族的修复）。
pub fn get_cursor_pos() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoCursorRGetCursorPos
    let mut pt = POINT::default();
    // 失败**不能**吞掉：原来 `let _ = GetCursorPos(&mut pt)` 之后照样返回 (0, 0)，
    // 于是"读不到鼠标位置"被报成"鼠标在屏幕左上角"——一个看起来完全正常的坐标。
    // 与 `netsh` 退出码 0 同一族（**API 失败、结果却像个真答案**）。
    // windows 0.58 里它返回 `Result<(), Error>`（不是 BOOL），
    // 所以"失败"就是 Err——`is_err()` 即可判。
    if unsafe { GetCursorPos(&mut pt) }.is_err() {
        // 返回空列表 = 没读到；上层按"未知"处理，不拿 0 当坐标。
        return Ok(Vec::new());
    }
    Ok(vec![pt.x.to_string(), pt.y.to_string()])
}

// ---------------------------------------------------------------------------
// api::sysinfo::disk
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::disk ----

/// 磁盘列表（sysinfo::Disks；盘符取挂载点尾段，如 "C:"）
pub fn get_disk_info_list() -> anyhow::Result<Vec<DiskInfo>> {
    // frb codec: crateApiSysinfoDiskRGetDiskInfoList
    let disks = Disks::new_with_refreshed_list();
    let mut out = Vec::new();
    for d in disks.list() {
        out.push(DiskInfo {
            name: mount_letter(d.mount_point()),
            mount_point: d.mount_point().to_string_lossy().into_owned(),
            total_bytes: d.total_space(),
            free_bytes: d.available_space(),
            file_system: d.file_system().to_string_lossy().into_owned(),
            removable: d.is_removable(),
        });
    }
    Ok(out)
}

/// 系统盘（根盘）信息：按 %SystemDrive% 环境变量匹配盘符，找不到返回 None
pub fn get_root_disk_info() -> anyhow::Result<Option<DiskInfo>> {
    // frb codec: crateApiSysinfoDiskRGetRootDiskInfo
    let sys_drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_string());
    let disks = Disks::new_with_refreshed_list();
    for d in disks.list() {
        if mount_letter(d.mount_point()).eq_ignore_ascii_case(&sys_drive) {
            return Ok(Some(DiskInfo {
                name: mount_letter(d.mount_point()),
                mount_point: d.mount_point().to_string_lossy().into_owned(),
                total_bytes: d.total_space(),
                free_bytes: d.available_space(),
                file_system: d.file_system().to_string_lossy().into_owned(),
                removable: d.is_removable(),
            }));
        }
    }
    Ok(None)
}

// ---------------------------------------------------------------------------
// api::sysinfo::logs
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::logs ----

/// 收集日志：把 exe 目录下 logs\ 最近 7 天的文件复制到
/// %TEMP%\cm_collect_<时间戳>\ 并打包为 %TEMP%\cm_collect_<时间戳>.zip，
/// 返回 zip 路径。logs 目录不存在时仍会生成带清单的空包。
pub fn collect_log() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoLogsRCollectLog
    let ts = chrono::Local::now().format("%Y%m%d%H%M%S").to_string();
    let temp = std::env::temp_dir();
    let stage_dir = temp.join(format!("cm_collect_{ts}"));
    std::fs::create_dir_all(&stage_dir)?;

    let exe_dir = std::env::current_exe()?
        .parent()
        .map(|p| p.to_path_buf())
        .ok_or_else(|| anyhow!("无法定位 exe 目录"))?;
    let logs_dir = exe_dir.join("logs");

    let cutoff = SystemTime::now() - Duration::from_secs(7 * 24 * 3600);
    let mut copied = 0usize;
    let mut staged: Vec<PathBuf> = Vec::new();
    if logs_dir.exists() {
        for entry in walkdir::WalkDir::new(&logs_dir).max_depth(3) {
            let Ok(entry) = entry else { continue };
            if !entry.file_type().is_file() {
                continue;
            }
            let recent = entry
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .map(|t| t >= cutoff)
                .unwrap_or(false);
            if !recent {
                continue;
            }
            // 扁平化到同一个暂存目录时**必须防重名**：WalkDir 走的是 max_depth(3)，
            // 子目录里的文件与根目录同名的话，`fs::copy` 会**静默覆盖**（copy 返回
            // Ok），表现为"日志少了/串了"却没有任何报错——排查时极难看出来。
            // 用相对路径拼一个可读的扁平名（`agent_2026.log` / `sub_agent_2026.log`）。
            let mut flat = match entry.path().strip_prefix(&logs_dir) {
                Ok(rel) => rel
                    .components()
                    .map(|c| c.as_os_str().to_string_lossy().into_owned())
                    .collect::<Vec<_>>()
                    .join("_"),
                Err(_) => entry.file_name().to_string_lossy().into_owned(),
            };
            // 仍然撞名（理论上只剩不同路径被 _ 拼成同一串的情况）就加序号，不覆盖。
            let mut dest = stage_dir.join(&flat);
            let mut n = 1;
            while dest.exists() {
                flat = format!("{}_{}", flat.trim_end_matches(".log"), n);
                if !flat.ends_with(".log") {
                    flat.push_str(".log");
                }
                dest = stage_dir.join(&flat);
                n += 1;
            }
            if std::fs::copy(entry.path(), &dest).is_ok() {
                staged.push(dest);
                copied += 1;
            }
        }
    }
    // 附一份清单，便于排查空包
    let manifest = stage_dir.join("manifest.txt");
    let _ = std::fs::write(
        &manifest,
        format!("collected={copied} files from {}", logs_dir.display()),
    );
    staged.push(manifest);

    let zip_path = temp.join(format!("cm_collect_{ts}.zip"));
    let file = std::fs::File::create(&zip_path)?;
    let mut writer = zip::ZipWriter::new(file);
    for f in &staged {
        let name = f
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        writer.start_file(name, zip::write::SimpleFileOptions::default())?;
        let data = std::fs::read(f)?;
        writer.write_all(&data)?;
    }
    writer.finish()?;
    let _ = std::fs::remove_dir_all(&stage_dir);
    log::info!("collect_log: {copied} files -> {}", zip_path.display());
    Ok(vec![zip_path.to_string_lossy().into_owned()])
}

// ---------------------------------------------------------------------------
// api::sysinfo::memory
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::memory ----

/// 内存优化：对每个可打开的进程调用 SetProcessWorkingSetSize(h, -1, -1)
/// 修剪工作集（即“整理内存”），返回 "trimmed=<数量>"。
/// 注意：对无权限访问的系统进程会被自动跳过。
pub fn processes_memory_optimization() -> anyhow::Result<String> {
    // frb codec: crateApiSysinfoMemoryRProcessesMemoryOptimization
    let mut sys = System::new();
    sys.refresh_processes(ProcessesToUpdate::All, true);
    let me = std::process::id();
    let mut trimmed = 0u32;
    for (pid, _proc) in sys.processes() {
        let pid = pid.as_u32();
        // 跳过空闲/System 进程与自身
        if pid <= 4 || pid == me {
            continue;
        }
        if let Ok(h) = unsafe { OpenProcess(PROCESS_SET_QUOTA | PROCESS_QUERY_INFORMATION, false, pid) } {
            // usize::MAX 即 (-1)：把工作集修剪到最小
            let _ = unsafe { SetProcessWorkingSetSizeEx(h, usize::MAX, usize::MAX, SETPROCESSWORKINGSETSIZEEX_FLAGS(0)) };
            let _ = unsafe { CloseHandle(h) };
            trimmed += 1;
        }
    }
    log::info!("processes_memory_optimization: trimmed {trimmed} processes");
    Ok(format!("trimmed={trimmed}"))
}

/// 内存使用情况（字节）：sysinfo 刷新后取 used/total
pub fn read_memory2() -> anyhow::Result<MemoryInfo> {
    // frb codec: crateApiSysinfoMemoryRReadMemory2
    let mut sys = System::new();
    sys.refresh_memory();
    Ok(MemoryInfo {
        used: sys.used_memory(),
        total: sys.total_memory(),
    })
}

// ---------------------------------------------------------------------------
// api::sysinfo::network
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::network ----

/// 网络信息：UDP “假连接”（不实际发包）取本机出口 IPv4，
/// 再用 TCP 连接 1.1.1.1:80（1 秒超时）判断外网连通性。
pub fn get_net_info() -> anyhow::Result<NetInfo> {
    // frb codec: crateApiSysinfoNetworkRGetNetInfo
    let local_ip = UdpSocket::bind("0.0.0.0:0")
        .and_then(|s| {
            s.connect("1.1.1.1:80")?;
            s.local_addr()
        })
        .map(|a| a.ip().to_string())
        .unwrap_or_default();
    let probe: SocketAddr = "1.1.1.1:80".parse()?;
    let connected = TcpStream::connect_timeout(&probe, Duration::from_secs(1)).is_ok();
    Ok(NetInfo { local_ip, connected })
}

/// 一次网络实测结果。
#[derive(Debug, Clone, serde::Serialize)]
pub struct NetQuality {
    /// 每次 TCP 握手的往返耗时（毫秒）；连不上的探测直接丢弃，所以可能为空
    pub rtt_ms: Vec<u64>,
    /// 采样窗口内本机网卡实收/实发字节
    pub received_bytes: u64,
    pub transmitted_bytes: u64,
    /// 采样窗口长度（毫秒），速率由调用方按 bytes*8/window 换算
    pub window_ms: u64,
}

/// 网络质量实测：RTT 取 TCP 握手耗时（探测点与 `get_net_info` 一致，不引入新域名），
/// 收发量取网卡计数器在窗口两端的差值。参考实现 net_speed_test 页是拉一个测速文件
/// 算带宽上限，测速源属于运营方后端，净室分支没有等价物，因此这里只报本机确实
/// 测得出的两个量：链路往返时延、窗口内实际吞吐。
pub fn measure_net_quality(samples: u32) -> anyhow::Result<NetQuality> {
    // frb codec: 净室新增入口，原二进制未导出对应符号（specs/api-map 无 network 测速项）
    let samples = samples.clamp(1, 20);
    let probe: SocketAddr = "1.1.1.1:80".parse()?;
    let mut nets = Networks::new_with_refreshed_list();
    // 回环网卡会把本机内部流量算成"网速"；没有地址的网卡（已断开）也不计。
    let counters = |nets: &Networks| -> (u64, u64) {
        nets.list()
            .values()
            .filter(|n| {
                let nets = n.ip_networks();
                !nets.is_empty() && !nets.iter().all(|ip| ip.addr.is_loopback())
            })
            .fold((0u64, 0u64), |mut acc, n| {
                acc.0 += n.total_received();
                acc.1 += n.total_transmitted();
                acc
            })
    };
    let (in0, out0) = counters(&nets);
    let started = SystemTime::now();

    let mut rtt = Vec::new();
    for i in 0..samples {
        let probe_at = SystemTime::now();
        if TcpStream::connect_timeout(&probe, Duration::from_secs(1)).is_ok() {
            rtt.push(probe_at.elapsed().unwrap_or_default().as_millis() as u64);
        }
        if i + 1 < samples {
            thread::sleep(Duration::from_millis(200));
        }
    }
    // 空闲机器上 200ms 窗口内计数器可能纹丝不动，凑满 1 秒再收尾采样。
    let elapsed = started.elapsed()?;
    if elapsed < Duration::from_secs(1) {
        thread::sleep(Duration::from_secs(1) - elapsed);
    }
    nets.refresh_list();
    let (in1, out1) = counters(&nets);
    Ok(NetQuality {
        rtt_ms: rtt,
        received_bytes: in1.saturating_sub(in0),
        transmitted_bytes: out1.saturating_sub(out0),
        window_ms: started.elapsed()?.as_millis().max(1) as u64,
    })
}

// ---------------------------------------------------------------------------
// api::sysinfo::patches
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::patches ----

/// 已安装补丁 ID 列表（WMI Win32_QuickFixEngineering 的 HotFixID）
pub fn get_installed_patch_ids() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoPatchesRGetInstalledPatchIds
    let con = wmi_connection()?;
    let rows: Vec<Win32_QuickFixEngineering> = con.query()?;
    Ok(rows.into_iter().map(|r| r.HotFixID).collect())
}

/// 需要重启才生效的挂起点，返回命中的来源标识（可能多个，也可能为空）。
///
/// 参考实现文案表自带「存在需要重启云电脑才生效的补丁」（zh_strings.txt:260），
/// 说明补丁页会报这个状态。这里只读 Windows 自己写下的三个挂起点，不猜：
/// - `cbs`：Component Based Servicing\RebootPending —— 组件服务在等重启，这才是「补丁」；
/// - `wu`：WindowsUpdate\Auto Update\RebootRequired —— Windows Update 在等重启；
/// - `rename`：Session Manager 的 PendingFileRenameOperations —— 安装器留下的待替换/
///   待删除文件，重启后才处理，但它不代表补丁，所以界面上的措辞要分开。
/// 三个键普通用户都可读，读不到（不存在）就是没有挂起。
pub fn reboot_pending_reasons() -> anyhow::Result<Vec<String>> {
    // frb codec: 净室新增入口，原二进制未导出对应符号
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let mut reasons = Vec::new();
    if hklm
        .open_subkey(r"SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending")
        .is_ok()
    {
        reasons.push("cbs".to_string());
    }
    if hklm
        .open_subkey(r"SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired")
        .is_ok()
    {
        reasons.push("wu".to_string());
    }
    let pending_rename = hklm
        .open_subkey(r"SYSTEM\CurrentControlSet\Control\Session Manager")
        .and_then(|k| k.get_raw_value("PendingFileRenameOperations"))
        .map(|v| !v.bytes.is_empty())
        .unwrap_or(false);
    if pending_rename {
        reasons.push("rename".to_string());
    }
    Ok(reasons)
}

/// 开机启动耗时（毫秒）——真正的"这次开机花了多久"。
///
/// 数据源是 Windows 自己写的启动诊断事件：
/// `Microsoft-Windows-Diagnostics-Performance/Operational` 的 EventID 100，字段 `BootTime`
/// （本机实测 32016ms，且**当前用户不提权就能读**）。
/// ⚠ **不要拿 `LastBootUpTime` 与现在时间的差冒充它**——那是"开机以后跑了多久"，
///   见下面 `get_system_boot_up_duration` 上方的说明（任务单 #100 就是为了不许混用）。
/// ⚠ 也**不要用 `BootEndTime - BootStartTime` 代替**：本机实测两者相差 173 秒，
///   而事件自己给的 `BootTime` 是 32.016 秒——差的那段是等待用户登录之类，不是一回事。
///
/// 读不到就返回 `None`：通道被关、无权限、或这台机器从没写过这条事件时，
/// 界面上就不该出现这一行，而不是写一个 0（"失败变正常值"是本项目反复扫的那类缺陷）。
/// 取最新一条（`/rd:true`）：用户问的是"这次开机"，不是这台云电脑第一次开机。
pub fn get_boot_time_ms() -> Option<u64> {
    // frb codec: crateApiSysinfoBootDurationRGetBootTimeMs
    let xml = read_boot_event_xml()?;
    parse_boot_time_ms(&xml)
}

/// 只走 XML：`wevtutil` 的 **text** 输出里字段标签是本地化的（"Windows 启动时间"），
/// 换语言就解析不出来；XML 里的 `Name='BootTime'` 是区域设置无关的。
fn read_boot_event_xml() -> Option<String> {
    let out = std::process::Command::new("wevtutil")
        .args([
            "qe",
            "Microsoft-Windows-Diagnostics-Performance/Operational",
            "/q:*[System[(EventID=100)]]",
            "/c:1",
            "/rd:true",
            "/f:XML",
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// 从事件 XML 里取 `<Data Name='BootTime'>` 的整数。
///
/// 手写扫描而不是引正则：本 crate 没有 regex 依赖，为一处取值加依赖不值。
/// 实测输出的属性引号是单引号，两种都认以防版本差异。
fn parse_boot_time_ms(xml: &str) -> Option<u64> {
    for quote in ['\'', '"'] {
        let key = format!("<Data Name={q}BootTime{q}>", q = quote);
        if let Some(start) = xml.find(&key) {
            let rest = &xml[start + key.len()..];
            let end = rest.find("</Data>")?;
            return rest[..end].trim().parse::<u64>().ok();
        }
    }
    None
}

#[cfg(test)]
mod boot_time_probe_tests {
    use super::parse_boot_time_ms;

    /// 本机从真事件里抓下来的片段（字段名与引号形状照原样）
    const SAMPLE: &str = "<EventData><Data Name='BootTime'>32016</Data>\
                          <Data Name='MainPathBootTime'>13016</Data></EventData>";

    #[test]
    fn reads_the_boot_time_field_and_not_its_neighbours() {
        assert_eq!(parse_boot_time_ms(SAMPLE), Some(32016));
        assert_eq!(
            parse_boot_time_ms("<Data Name=\"BootTime\">999</Data>"),
            Some(999)
        );
    }

    #[test]
    fn missing_or_garbage_is_none_not_zero() {
        // 只有邻近字段时读成 0，就等于把"没查到"报成"这次开机花了 0 毫秒"
        assert_eq!(
            parse_boot_time_ms("<Data Name='MainPathBootTime'>13016</Data>"),
            None
        );
        assert_eq!(parse_boot_time_ms("<EventData></EventData>"), None);
        assert_eq!(parse_boot_time_ms(""), None);
        assert_eq!(parse_boot_time_ms("<Data Name='BootTime'>abc</Data>"), None);
        // 截断（没有闭合标签）也不能编一个数出来
        assert_eq!(parse_boot_time_ms("<Data Name='BootTime'>320"), None);
    }

    /// 端到端复核用（**默认不跑**：CI 的 runner 可能没有这条通道或没写过事件，
    /// 把它当常开断言会变成"看机器脸色"的红）。在目标机上手动跑：
    /// `cargo test boot_time_is_readable_on_this_machine -- --ignored`
    #[test]
    #[ignore]
    fn boot_time_is_readable_on_this_machine() {
        let ms = super::get_boot_time_ms();
        println!("本机 BootTime = {ms:?} ms");
        assert!(ms.is_some(), "这台机器读不到 EventID 100 的 BootTime");
        // 真能读到就不该是 0：0 意味着"开机不花时间"，那是假结论
        assert!(ms.unwrap() > 0);
    }
}

#[cfg(test)]
mod reboot_probe_tests {
    use super::*;

    /// 在这台机器上跑：结果只能来自那三个已知来源、不重复、且不许报错。
    /// 具体命中哪些由实机与 `reg query` 交叉核对（见 README 的取证记录），
    /// 单测不去断言真机状态——那会随系统状态飘。
    #[test]
    fn reboot_reasons_are_known_ids_only() {
        let r = reboot_pending_reasons().expect("读注册表不应失败");
        let known = ["cbs", "wu", "rename"];
        for id in &r {
            assert!(known.contains(&id.as_str()), "未知来源: {id}");
        }
        let mut dedup = r.clone();
        dedup.sort();
        dedup.dedup();
        assert_eq!(dedup.len(), r.len(), "同一来源不应出现两次");
    }
}

/// 用 wusa.exe 静默安装指定 KB 补丁（/quiet /norestart，需管理员权限）。
/// kb_id 可传 "KB5031354" 或 "5031354"，内部抽取数字段。
pub fn wusa_install_patch(kb_id: String) -> anyhow::Result<String> {
    // frb codec: crateApiSysinfoPatchesRWusaInstallPatch
    // ⚠ 故意不给出口：同上——wusa 安装路径也没有可装的包；补丁页真正接的是**卸载**。
    let digits: String = kb_id.chars().filter(|c| c.is_ascii_digit()).collect();
    ensure!(!digits.is_empty(), "无效的 KB 编号: {kb_id}");
    let kb_arg = format!("/kb:{digits}");
    run_tool(
        "wusa.exe",
        &[kb_arg, "/quiet".to_string(), "/norestart".to_string()],
    )
}

/// 用 dism.exe 安装补丁包（.cab 等），需管理员权限
pub fn dism_install_patch(package_path: String) -> anyhow::Result<String> {
    // frb codec: crateApiSysinfoPatchesRDismInstallPatch
    // ⚠ 故意不给出口：同上——dism 安装路径同样缺包；别为了"看起来完整"接个空按钮。
    let pkg_arg = format!("/PackagePath:{}", package_path);
    run_tool(
        "dism.exe",
        &[
            "/Online".to_string(),
            "/Add-Package".to_string(),
            pkg_arg,
            "/Quiet".to_string(),
            "/NoRestart".to_string(),
        ],
    )
}

/// 用 dism.exe 卸载补丁包（按包名），需管理员权限
pub fn dism_uninstall_patch(package_name: String) -> anyhow::Result<String> {
    // frb codec: crateApiSysinfoPatchesRDismUninstallPatch
    // ⚠ 故意不给出口：卸载已由 `wusa_uninstall_patch` 接到补丁页那个「卸载补丁」按钮，
    //   同一个按钮不需要第二个后端；在没有证据的情况下换成 DISM 会改变语义。
    let pkg_arg = format!("/PackageName:{}", package_name);
    run_tool(
        "dism.exe",
        &[
            "/Online".to_string(),
            "/Remove-Package".to_string(),
            pkg_arg,
            "/Quiet".to_string(),
            "/NoRestart".to_string(),
        ],
    )
}

/// 用 msiexec.exe 静默安装 MSI 补丁包（/quiet /norestart），需管理员权限
pub fn msi_patch_install(package_path: String) -> anyhow::Result<String> {
    // frb codec: crateApiSysinfoPatchesRMsiPatchInstall
    // ⚠ 故意不给出口：同上——msi 安装路径要的是"有一个 msi 可装"，我们没有。
    run_tool(
        "msiexec.exe",
        &[
            "/i".to_string(),
            package_path,
            "/quiet".to_string(),
            "/norestart".to_string(),
        ],
    )
}

/// 按扩展名自动分发补丁安装：.msu → wusa，.msi → msiexec，.cab → dism
pub fn common_patch_install(package_path: String) -> anyhow::Result<String> {
    // frb codec: crateApiSysinfoPatchesRCommonPatchInstall
    // ⚠ 故意不给出口：本项目**没有更新源与安装包**，"装补丁"这一步压根没有触发者。
    //   有了更新源之后再开（与另外 4 个安装 codec 同批处理）。
    //   佐证：`classes.txt` 的 `_ClientUpdateDialogContentState` + 文案表那批下载/升级串
    //   说明这 5 个安装 codec 属于对面**一条我们整条没有的更新流程**，不是 5 个独立缺口。
    let ext = Path::new(&package_path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
        "msu" => run_tool(
            "wusa.exe",
            &[package_path, "/quiet".to_string(), "/norestart".to_string()],
        ),
        "msi" => run_tool(
            "msiexec.exe",
            &[
                "/i".to_string(),
                package_path,
                "/quiet".to_string(),
                "/norestart".to_string(),
            ],
        ),
        "cab" => {
            let pkg_arg = format!("/PackagePath:{}", package_path);
            run_tool(
                "dism.exe",
                &[
                    "/Online".to_string(),
                    "/Add-Package".to_string(),
                    pkg_arg,
                    "/Quiet".to_string(),
                    "/NoRestart".to_string(),
                ],
            )
        }
        _ => bail!("未知的补丁包类型: {package_path}"),
    }
}

/// 用 wusa.exe 静默卸载指定 KB 补丁（wusa /uninstall /kb:ID /quiet /norestart），
/// 需管理员权限
pub fn wusa_uninstall_patch(kb_id: String) -> anyhow::Result<String> {
    // frb codec: crateApiSysinfoPatchesRWusaUninstallPatch
    let digits: String = kb_id.chars().filter(|c| c.is_ascii_digit()).collect();
    ensure!(!digits.is_empty(), "无效的 KB 编号: {kb_id}");
    let kb_arg = format!("/kb:{digits}");
    run_tool(
        "wusa.exe",
        &[
            "/uninstall".to_string(),
            kb_arg,
            "/quiet".to_string(),
            "/norestart".to_string(),
        ],
    )
}

// ---------------------------------------------------------------------------
// api::sysinfo::process_process_info
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::process_process_info ----

/// 进程 exe 的文件描述（PE VERSIONINFO 的 FileDescription）。
/// 参数为 exe 完整路径（pid → path 由上层用进程列表转换）。
pub fn get_process_file_description(exe_path: String) -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoProcessProcessInfoGetProcessFileDescription
    let desc = load_version_map(&exe_path)
        .get("FileDescription")
        .cloned()
        .unwrap_or_default();
    Ok(vec![desc])
}

/// 进程图标（codec 面：`crateApiSysinfoProcessProcessInfoGetProcessIco`，返回字符串列表）。
/// 参考实现把 HICON 编成 PNG 再交给前端，但这条 codec 的返回类型是 `List<String>`，
/// 规格清单看不出字符串里装的是路径还是编码后的位图，故保持返回 exe 路径；
/// 前端图标实际由 [extract_app_icon] 直接取 RGBA 像素渲染，不经这条路。
///
/// ⚠ **故意不给适配层出口**（第 15 条负向结论）：进程页的图标**已经在画**
/// （`AppIconImage(displayIcon: p.exe)` → [extract_app_icon]，本机实测 Qoder/CodeBuddy
/// 都出图）。这条路即使接上也只是同一个功能换了个语义不明的返回类型。
/// **重复，不是缺口**——reachable 清单会一直列着它，别照着数字"补"。
pub fn get_process_ico(exe_path: String) -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoProcessProcessInfoGetProcessIco
    Ok(vec![exe_path])
}

/// 进程 exe 的发布者（PE VERSIONINFO 的 CompanyName）。
pub fn get_process_publisher(exe_path: String) -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoProcessProcessInfoGetProcessPublisher
    let company = load_version_map(&exe_path)
        .get("CompanyName")
        .cloned()
        .unwrap_or_default();
    Ok(vec![company])
}

// ---------------------------------------------------------------------------
// api::sysinfo::process
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::process ----

/// 记录并返回端口占用（netstat -ano，中文系统输出为本地编码，逐行返回）。
/// 同时写入 rust 日志（log::info!）。
pub fn log_process_port_usage() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoProcessRLogProcessPortUsage
    let out = Command::new("netstat")
        .arg("-ano")
        .output()
        .context("执行 netstat -ano 失败")?;
    let text = String::from_utf8_lossy(&out.stdout);
    let lines: Vec<String> = text
        .lines()
        .map(|l| l.trim_end().to_string())
        .filter(|l| !l.is_empty())
        .collect();
    for l in &lines {
        log::info!("[port-usage] {l}");
    }
    Ok(lines)
}

/// 进程列表（按内存占用降序，取前 50 条）。
/// 首次刷新建立采样基线，sleep 300ms 后再刷新以获得 CPU 占用。
pub fn read_process_info() -> anyhow::Result<Vec<ProcessEntry>> {
    // frb codec: crateApiSysinfoProcessRReadProcessInfo
    let mut sys = System::new();
    sys.refresh_processes(ProcessesToUpdate::All, true);
    thread::sleep(Duration::from_millis(300));
    sys.refresh_processes(ProcessesToUpdate::All, true);
    let mut list: Vec<ProcessEntry> = sys
        .processes()
        .iter()
        .map(|(pid, p)| ProcessEntry {
            pid: pid.as_u32(),
            name: p.name().to_string_lossy().into_owned(),
            exe: p.exe().map(|e| e.to_string_lossy().into_owned()).unwrap_or_default(),
            cpu: p.cpu_usage(),
            mem_mb: p.memory() as f64 / 1024.0 / 1024.0,
        })
        .collect();
    list.sort_by(|a, b| b.mem_mb.total_cmp(&a.mem_mb));
    list.truncate(50);
    Ok(list)
}

/// 结束指定进程（sysinfo Process::kill）
pub fn terminate_process(pid: u32) -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoProcessRTerminateProcess
    let mut sys = System::new();
    let target = Pid::from_u32(pid);
    sys.refresh_processes(ProcessesToUpdate::Some(&[target]), true);
    let killed = sys.process(target).map(|p| p.kill()).unwrap_or(false);
    ensure!(killed, "结束进程失败（进程不存在或权限不足）: pid={pid}");
    Ok(())
}

// ---------------------------------------------------------------------------
// api::sysinfo::startup
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::startup ----

/// 读取某个 Run 键的全部启动项，并按 StartupApproved 首字节判断启用状态。
/// StartupApproved 值为 12 字节 REG_BINARY：首字节 02=启用、03=禁用（偶=启用、奇=禁用），
/// 值不存在视为启用。
fn read_run_key(hive: HKEY, run_sub: &str, approved_sub: &str, location: &str, out: &mut Vec<StartupItemInfo>) {
    let root = RegKey::predef(hive);
    let run_key = match root.open_subkey(run_sub) {
        Ok(k) => k,
        Err(_) => return,
    };
    let approved = root.open_subkey(approved_sub).ok();
    for entry in run_key.enum_values() {
        let (name, _val) = match entry {
            Ok(x) => x,
            Err(_) => continue,
        };
        let command: String = run_key.get_value(name.as_str()).unwrap_or_default();
        let enabled = match &approved {
            Some(k) => match k.get_raw_value(name.as_str()) {
                Ok(v) => v.bytes.first().map(|b| b & 1 == 0).unwrap_or(true),
                Err(_) => true,
            },
            None => true,
        };
        out.push(StartupItemInfo {
            name,
            command,
            location: location.to_string(),
            enabled,
        });
    }
}

/// 开机启动项列表：HKCU\...\Run + HKLM\...\Run + HKLM Wow6432Node\...\Run
pub fn read_startup_list() -> anyhow::Result<Vec<StartupItemInfo>> {
    // frb codec: crateApiSysinfoStartupRReadStartupList
    let mut out = Vec::new();
    read_run_key(HKEY_CURRENT_USER, RUN_PATH, APPROVED_HKCU, "HKCU", &mut out);
    read_run_key(HKEY_LOCAL_MACHINE, RUN_PATH, APPROVED_HKLM, "HKLM", &mut out);
    read_run_key(HKEY_LOCAL_MACHINE, RUN_PATH_WOW, APPROVED_WOW, "HKLM_WOW", &mut out);
    Ok(out)
}

/// 修改启动项启用状态：写 StartupApproved（禁用 = 03 00 00 00...）。
/// location 取 read_startup_list 返回的标记："HKCU" / "HKLM" / "HKLM_WOW"。
/// 注意：写 HKLM 侧的 StartupApproved 需要管理员权限。
pub fn change_startup_status(item_name: String, enable: bool, location: String) -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoStartupRChangeStartupStatus
    let (hive, approved_path) = match location.as_str() {
        "HKCU" => (HKEY_CURRENT_USER, APPROVED_HKCU),
        "HKLM" => (HKEY_LOCAL_MACHINE, APPROVED_HKLM),
        "HKLM_WOW" => (HKEY_LOCAL_MACHINE, APPROVED_WOW),
        other => bail!("未知的启动项位置: {other}"),
    };
    let root = RegKey::predef(hive);
    let key = match root.open_subkey_with_flags(approved_path, KEY_SET_VALUE) {
        Ok(k) => k,
        Err(_) => root.create_subkey(approved_path)?.0, // 键不存在时创建
    };
    let mut bytes = vec![0u8; 12];
    bytes[0] = if enable { 0x02 } else { 0x03 };
    key.set_raw_value(
        item_name.as_str(),
        &RegValue {
            bytes,
            vtype: RegType::REG_BINARY,
        },
    )?;
    Ok(())
}

/// 开机时长（毫秒）：WMI Win32_OperatingSystem.LastBootUpTime 与当前时间之差。
/// 返回单元素向量（毫秒字符串）。WMI 时间形如 "20240105103000.500000+480"，
/// 取前 14 位按本地时间与本地当前时间相减，时区偏移自然抵消。
///
/// ⚠ **名字与数据不是一回事，别把界面措辞改回去**：参考实现的文案表里
/// 「开机启动耗时」(`zh_strings.txt:259`) 对应的就是这个 codec（`frb_calls.txt:73`
/// `crateApiSysinfoStartupRGetSystemBootUpDuration`），但函数体算的是
/// `LastBootUpTime` 到现在的差——**开机之后已经跑了多久**，不是"上一次开机花了多久"。
/// 所以 Dart 侧那行显示写的是「已开机 X」（`app_manage_page.dart` 的启动项页副标题），
/// 而不是表里那个名字。照抄「开机启动耗时」就是让标签承诺一个这个数据源给不出的数
/// （"名字承诺 X、函数体做 Y"这一族，本项目已经踩过好几次）。
/// 真想要那个数得换数据源（`Diagnostic-Performance` 事件日志里的总耗时），而手头材料
/// 除了一个标签和一个 codec 名，**没有任何取法、权限或失败形态的说明**——不许照名字编。
pub fn get_system_boot_up_duration() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoStartupRGetSystemBootUpDuration
    let con = wmi_connection()?;
    let rows: Vec<Win32_OperatingSystem> = con.query()?;
    let t = rows
        .into_iter()
        .next()
        .ok_or_else(|| anyhow!("WMI 未返回 Win32_OperatingSystem"))?
        .LastBootUpTime;
    let core = t.get(..14).ok_or_else(|| anyhow!("LastBootUpTime 格式异常: {t}"))?;
    let boot = chrono::NaiveDateTime::parse_from_str(core, "%Y%m%d%H%M%S")
        .with_context(|| format!("解析 LastBootUpTime 失败: {t}"))?;
    let millis = (chrono::Local::now().naive_local() - boot).num_milliseconds();
    Ok(vec![millis.max(0).to_string()])
}

// ---------------------------------------------------------------------------
// api::sysinfo::startup_startup_info
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::startup_startup_info ----

/// 启动项名称列表（read_startup_list 的 name 列）
///
/// ⚠ **故意不给适配层出口**（第 12 条负向结论）：函数体就是
/// `read_startup_list()` 再 `.map(name)`——本项目**已经**接了 `readStartupList`
/// （启动项页与体检都走它，那才是要的地方：还得拿 location/enabled）。
/// 接这个只多跑一遍注册表扫描、少两列信息，而 reachable 清单会一直诱人来"收掉"它。
/// 与 `get_process_ico`、`start_exe`、`get_app_current_dir` 同一类：**重复，不是缺口**。
pub fn get_name() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoStartupStartupInfoGetName
    Ok(read_startup_list()?.into_iter().map(|i| i.name).collect())
}

// ---------------------------------------------------------------------------
// api::sysinfo::storage_sense
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::storage_sense ----

/// 存储感知开关状态：读 HKCU\...\StoragePolicy 的 "01" DWORD（0=关 1=开），
/// 键不存在视为关闭。返回单元素向量。
pub fn get_stroge_sense() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoStorageSenseRGetStrogeSense
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    // 键不存在 = **没读到**，返回空列表；原来回 vec!["0"] 等于宣称"关着"。
    // 空列表与"值为 0"在 Dart 侧是两种意思（null vs false），别混。
    let key = match hkcu.open_subkey(STORAGE_POLICY_PATH) {
        Ok(k) => k,
        Err(_) => return Ok(Vec::new()),
    };
    let v: u32 = match key.get_value("01") {
        Ok(v) => v,
        Err(_) => return Ok(Vec::new()),
    };
    Ok(vec![v.to_string()])
}

/// 设置存储感知开关：写 HKCU\...\StoragePolicy 的 "01" DWORD（1/0）
pub fn set_stroge_sense(enabled: bool) -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoStorageSenseRSetStrogeSense
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let (key, _) = hkcu.create_subkey(STORAGE_POLICY_PATH)?;
    let val: u32 = if enabled { 1 } else { 0 };
    key.set_value("01", &val)?;
    Ok(())
}

/// 打开系统“存储感知”设置页（ms-settings:storagesense）
pub fn show_stroge_sense() -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoStorageSenseRShowStrogeSense
    Command::new("explorer.exe")
        .arg("ms-settings:storagesense")
        .spawn()
        .context("打开存储感知设置页失败")?;
    Ok(())
}

// ---------------------------------------------------------------------------
// api::sysinfo::upgrade_image
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::upgrade_image ----

/// 执行镜像升级包：校验存在后按扩展名分发（exe 直接启动、msu 走 wusa、
/// bat/cmd 交给 cmd /C），不等待执行完成
///
/// ⚠ **故意不给 UI 出口**（第 10 条负向结论，2026-10-08 核实）：这个函数要的是
/// **一个已经下载好的升级包路径**，而"升级包从哪来"本项目答不出来——
/// 参考实现自己的 frb 调用清单里也只有 `ExecImagePackage` 与 `GetImageVersion`
/// 两条，**没有任何"发现/列举升级包"的接口**（`docs/extracted/frb_calls.txt:79-81`），
/// 说明包路径来自它的后端推送。文案表里虽有「系统升级工具」`:527`、
/// 「发现升级包」`:229`、「待升级」`:227`，但 `routes_ui.txt` 与 `click_events.txt`
/// 搜 upgrade/update **零命中**，没有第二处证据说明入口摆在哪、点了做什么。
/// 与补丁安装那 5 个 codec 同一处境：**没有更新源就别画按钮**，
/// 画出来就是个点了没反应（或更糟：随便找个 exe 跑起来）的假 affordance。
pub fn exec_image_package(package_path: String) -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoUpgradeImageRExecImagePackage
    let p = Path::new(&package_path);
    ensure!(p.exists(), "镜像升级包不存在: {package_path}");
    let ext = p
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
        "exe" => {
            Command::new(p).spawn().context("启动升级包失败")?;
        }
        "msu" => {
            Command::new("wusa.exe").arg(p).spawn().context("启动 wusa 失败")?;
        }
        "bat" | "cmd" => {
            Command::new("cmd")
                .arg("/C")
                .arg(p)
                .spawn()
                .context("启动脚本失败")?;
        }
        other => bail!("不支持的升级包类型: {other}"),
    }
    Ok(())
}

/// 镜像升级版本：读 C:\ProgramData\\ImageUpgrade\version.txt，
/// 文件不存在返回空向量
pub fn get_image_version() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoUpgradeImageRGetImageVersion
    match std::fs::read_to_string(image_version_file()) {
        Ok(s) => Ok(vec![s.trim().to_string()]),
        Err(_) => Ok(Vec::new()),
    }
}

/// 是否 x86（32 位）CPU 架构编译目标
pub fn is_x86_cpu() -> anyhow::Result<bool> {
    // frb codec: crateApiSysinfoUpgradeImageRIsX86Cpu
    // ⚠ 故意不给出口：它只服务"按架构挑升级包"，而本项目没有更新源与安装器
    //   （与 5 个安装 codec 同族）。接出来只是一个没人查询的架构布尔。
    //
    // 原来写的是 `cfg!(target_arch = "x86")` —— 那是**编译期常量**，量的是
    // 我们这个 dll 是按什么架构编出来的，不是这台机器的 CPU 是什么。
    // 本项目固定编 x64，所以它恒为 false：**32 位 Windows 上也报 false**，
    // 于是该跑 32 位镜像包时挑错了包（升级包 arch 选错 = 装不上或装完起不来）。
    //
    // 这里要问的是**系统**：PROCESSOR_ARCHITECTURE 在 WOW64 下返回宿主架构，
    // 用 PROCESSOR_ARCHITEW6432 才拿得到 32 位系统在 64 位宿主上的真实架构。
    Ok(is_32bit_os())
}

/// 当前**操作系统**是否 32 位。
///
/// 读环境变量 `PROCESSOR_ARCHITECTURE`（Windows 自己写的：32 位系统为 `x86`，
/// 64 位为 `AMD64`/`ARM64`）。这是本项目里最靠得住的一条路径：
///
/// - `GetNativeSystemInfo` 的 `wProcessorArchitecture` 实测在本机（AMD64）返回 9，
///   与环境变量矛盾——走 union 取字段这条路不可靠，不采用；
/// - `IsWow64Process` 量的是**本进程**不是系统，在非 Windows 构建目标上还会
///   直接成功并把结果置真（本机实测因此把 64 位判成 32 位）。
///
/// 环境变量缺失时返回 false：宁可说"不是 32 位"，也不能凭猜测挑一个架构的升级包。
fn is_32bit_os() -> bool {
    match std::env::var("PROCESSOR_ARCHITECTURE") {
        Ok(a) => matches!(a.trim().to_ascii_uppercase().as_str(), "X86" | "ARM"),
        Err(_) => false,
    }
}

// ---------------------------------------------------------------------------
// api::sysinfo::windows_info
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::windows_info ----

/// 应用列表：枚举开始菜单（所有用户 + 当前用户）的 .lnk 项，
/// 去重排序后最多返回 500 条
///
/// ⚠ **故意不给出口**（负向结论，可达面最后一条）：**没有任何界面证据说得出这些名字要摆在哪**。
/// 找到的只有两个孤立类名 `_AppSeletectorState` 与 `_ShortcutRegistrarState`
/// （`classes.txt:91` 附近），它们合起来确实像"从快捷方式里选一个应用"的控件，但是：
/// 文案表搜「开始菜单 / 快捷方式 / 选择 / 添加应用」**全部零命中**，
/// `routes_ui.txt` / `page_route_extensions.txt` / `click_events.txt` 也没有对应条目。
/// 也就是说对面有没有这一屏、那一屏标题叫什么、选完拿去做什么，材料都没给——
/// 照两个类名搭一个"选应用"弹层就是编布局（本项目一路在拒的那一类）。
/// **要翻案需要的新证据**：该弹窗的任一句原话（标题/按钮/空态），或它的路由/埋点名。
pub fn get_app_info() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoWindowsInfoRGetAppInfo
    let mut roots: Vec<PathBuf> = Vec::new();
    if let Ok(pd) = std::env::var("ProgramData") {
        roots.push(PathBuf::from(pd).join(r"Microsoft\Windows\Start Menu\Programs"));
    }
    if let Ok(ad) = std::env::var("APPDATA") {
        roots.push(PathBuf::from(ad).join(r"Microsoft\Windows\Start Menu\Programs"));
    }
    let mut names: Vec<String> = Vec::new();
    for root in roots {
        for entry in walkdir::WalkDir::new(root).max_depth(5) {
            let Ok(entry) = entry else { continue };
            if !entry.file_type().is_file() {
                continue;
            }
            let is_lnk = entry
                .path()
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| e.eq_ignore_ascii_case("lnk"))
                .unwrap_or(false);
            if is_lnk {
                if let Some(stem) = entry.path().file_stem() {
                    names.push(stem.to_string_lossy().into_owned());
                }
            }
        }
    }
    names.sort();
    names.dedup();
    names.truncate(500);
    Ok(names)
}

/// Windows 版本信息：读 HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion 的
/// ProductName / DisplayVersion / CurrentBuild / UBR，拼接为单个字符串返回。
pub fn get_version_info() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoWindowsInfoRGetVersionInfo
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let key = hklm.open_subkey(CURRENT_VERSION_PATH)?;
    let product: String = key.get_value("ProductName").unwrap_or_default();
    let display: String = key.get_value("DisplayVersion").unwrap_or_default();
    let build: String = key.get_value("CurrentBuild").unwrap_or_default();
    let ubr: u32 = key.get_value("UBR").unwrap_or(0);
    let mut joined = product;
    if !display.is_empty() {
        joined.push(' ');
        joined.push_str(&display);
    }
    if !build.is_empty() {
        joined.push_str(&format!(" (Build {build}.{})", ubr));
    }
    Ok(vec![joined])
}

/// 打开应用：交给系统 ShellExecute 按路径/协议解析。
///
/// 原来这里对非路径分支拼 `cmd /C start "" <target>`：**cmd 会把 target 里的
/// `&`、`|`、重定向当命令分隔符**，那是命令注入——只要 target 来自列表项、
/// 剪贴板或启动参数就能执行任意命令。改用 ShellExecuteW：不经 cmd 解析，
/// 单个参数原样传下去。
pub fn open_app(target: String) -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoWindowsInfoROpenApp
    use windows::Win32::UI::Shell::ShellExecuteW;
    use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
    use windows::core::HSTRING;
    use windows::core::w;

    let file = HSTRING::from(target.trim());
    let code = unsafe {
        ShellExecuteW(None, w!("open"), &file, None, None, SW_SHOWNORMAL).0
            as isize
    };
    // ShellExecuteW 返回 >32 才是成功，小值是错误码。不检查的话调用方会
    // 以为应用已经起来了，其实没有。
    ensure!(code > 32, "ShellExecuteW 打开失败（返回 {code}）：{file}");
    Ok(())
}

#[cfg(test)]
mod icon_tests {
    use super::*;

    #[test]
    fn display_icon_path_strips_index_and_env() {
        // raw string：注册表路径里的反斜杠不能被当成转义
        assert_eq!(display_icon_path(r#""C:\Program Files\a b\a.exe",0"#), r"C:\Program Files\a b\a.exe");
        assert_eq!(display_icon_path(r"C:\Windows\a.exe, 1"), r"C:\Windows\a.exe");
        assert_eq!(display_icon_path("plain.exe"), "plain.exe");
        assert_eq!(display_icon_path(""), "");
        let expanded = display_icon_path(r"%SystemRoot%\System32\shell32.dll,-154");
        assert!(expanded.ends_with(r"\System32\shell32.dll"), "实际: {expanded}");
    }

    /// 兜底提取要按 DisplayIcon 尾部的索引取图标；路径带引号或有空格都不能读错索引。
    #[test]
    fn display_icon_index_covers_quoted_and_signed() {
        assert_eq!(display_icon_index(r#""C:\Program Files\a.exe",3"#), 3);
        assert_eq!(display_icon_index(r"C:\Windows\a.exe, 1"), 1);
        assert_eq!(display_icon_index(r"C:\Windows\a.exe"), 0);
        // 负数是资源 ID，不是零基索引，兜底必须放弃而不是换个图标
        assert_eq!(display_icon_index(r"%SystemRoot%\System32\shell32.dll,-154"), -154);
        assert_eq!(display_icon_index("bad.exe,abc"), 0);
    }

    /// 系统自带 exe 必然有图标：像素缓冲与宽高自洽，且至少一个不透明像素。
    #[test]
    fn extract_icon_from_system_exe() {
        let root = std::env::var("SystemRoot").expect("SystemRoot");
        let icon = Path::new(&root).join("System32").join("notepad.exe");
        let pixels = extract_app_icon(icon.to_string_lossy().into_owned())
            .expect("notepad.exe 应能取到图标");
        assert_eq!(pixels.rgba.len(), pixels.width as usize * pixels.height as usize * 4);
        assert!(pixels.width >= 16 && pixels.height >= 16, "尺寸异常 {:?}", (pixels.width, pixels.height));
        let opaque = pixels.rgba.chunks_exact(4).filter(|p| p[3] > 0).count();
        assert!(opaque > 0, "全透明图标");
    }

    /// 兜底路由单独验证：shell 取不到时才走它，平时不会被跑到，坏在原地等于没有兜底。
    #[test]
    fn pe_icon_fallback_yields_pixels() {
        let root = std::env::var("SystemRoot").expect("SystemRoot");
        let icon = Path::new(&root).join("System32").join("notepad.exe");
        let wide = to_wide(&icon.to_string_lossy());
        let pixels = with_com_initialized(|| unsafe {
            let hicon = extract_pe_icon(&wide, 0).expect("notepad.exe 主图标应能按资源取到");
            let pixels = icon_to_rgba(hicon);
            let _ = DestroyIcon(hicon);
            pixels
        })
        .expect("兜底图标应能转成像素");
        assert_eq!(pixels.rgba.len(), pixels.width as usize * pixels.height as usize * 4);
        assert!(pixels.width >= 16 && pixels.height >= 16, "尺寸异常 {:?}", (pixels.width, pixels.height));
        assert!(pixels.rgba.chunks_exact(4).any(|p| p[3] > 0), "全透明图标");
    }

    /// 真机回归：注册表里带 DisplayIcon 的应用多数应能取出图标。
    /// 曾因调用线程未初始化 COM 而全军覆没（chrome/Weixin 这类走图标处理器的文件），
    /// 系统自带 exe 反而能命中缓存，所以必须拿真实安装项按比例卡阈值。
    #[test]
    fn most_installed_apps_yield_icons() {
        let apps = check_app2().expect("check_app2 应能枚举注册表");
        let candidates: Vec<String> = apps
            .iter()
            .map(|a| a.display_icon.clone())
            .filter(|d| !d.trim().is_empty())
            .take(10)
            .collect();
        if candidates.is_empty() {
            return; // 本机没有带 DisplayIcon 的卸载项时不判失败
        }
        let ok = candidates.iter().filter(|d| extract_app_icon(d.to_string()).is_ok()).count();
        assert!(ok * 2 >= candidates.len(), "仅 {ok}/{} 个应用取到图标，比例过低", candidates.len());
    }

    /// 并发回归：列表一帧内会同时发起几十个取图标调用（每个应用一个 widget）。
    /// 曾因调用线程未初始化 COM，并发取图标全军覆没，故按比例卡阈值而不是只看单个文件。
    #[test]
    fn concurrent_icon_extraction_is_stable() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Arc;
        let list: Vec<String> = check_app2()
            .expect("check_app2")
            .iter()
            .map(|a| a.display_icon.clone())
            .filter(|d| !d.trim().is_empty())
            .take(24)
            .collect();
        if list.len() < 4 {
            return;
        }
        let ok = Arc::new(AtomicUsize::new(0));
        let handles: Vec<_> = list
            .iter()
            .cloned()
            .map(|d| {
                let ok = ok.clone();
                thread::spawn(move || {
                    if extract_app_icon(d).is_ok() {
                        ok.fetch_add(1, Ordering::SeqCst);
                    }
                })
            })
            .collect();
        for h in handles {
            let _ = h.join();
        }
        let got = ok.load(Ordering::SeqCst);
        assert!(got * 2 >= list.len(), "并发取图标仅 {}/{} 成功", got, list.len());
    }

    /// .ico 取的是文件内部的图标，不是「ICO 文件类型」图标。Git 的 DisplayIcon 就是 .ico，
    /// 走 shell 会拿到 Explorer 里那张带 ICO 角标的白纸，所以自己拼一个纯红 16x16 的 .ico 卡住。
    #[test]
    fn ico_file_yields_embedded_pixels() {
        const BMP_LEN: u32 = 40 + 16 * 16 * 4 + 16 * 4;
        const PIX_LEN: u32 = 16 * 16 * 4 + 16 * 4;
        let mut ico: Vec<u8> = Vec::new();
        ico.extend_from_slice(&[0, 0, 1, 0, 1, 0]); // 保留 / 类型=图标 / 数量=1
        ico.extend_from_slice(&[16, 16, 0, 0]); // 宽 / 高 / 颜色数 / 保留
        ico.extend_from_slice(&1u16.to_le_bytes()); // 位平面
        ico.extend_from_slice(&32u16.to_le_bytes()); // 位深
        ico.extend_from_slice(&BMP_LEN.to_le_bytes()); // 图标数据长度
        ico.extend_from_slice(&22u32.to_le_bytes()); // 图标数据偏移（紧跟目录项）
        ico.extend_from_slice(&40u32.to_le_bytes()); // BITMAPINFOHEADER 大小
        ico.extend_from_slice(&16i32.to_le_bytes()); // 宽
        ico.extend_from_slice(&32i32.to_le_bytes()); // 高 = 颜色面 + 蒙版，故为 2 倍
        ico.extend_from_slice(&1u16.to_le_bytes());
        ico.extend_from_slice(&32u16.to_le_bytes());
        ico.extend_from_slice(&0u32.to_le_bytes()); // BI_RGB，无压缩
        ico.extend_from_slice(&PIX_LEN.to_le_bytes()); // 像素+蒙版字节数
        ico.extend_from_slice(&[0; 16]); // 分辨率×2 + 颜色数 + 重要颜色数（凑满 40 字节头）
        for _ in 0..16 * 16 {
            ico.extend_from_slice(&[0, 0, 255, 255]); // BGRA：不透明红
        }
        ico.extend_from_slice(&[0; 16 * 4]); // AND 蒙版全 0 = 全不透明

        let file = std::env::temp_dir().join("cm_rebuild_icon_probe.ico");
        std::fs::write(&file, &ico).expect("写入临时 ico");
        let pixels =
            extract_app_icon(file.to_string_lossy().into_owned()).expect(".ico 应取到内部图标");
        let _ = std::fs::remove_file(&file);

        let n = (pixels.rgba.len() / 4) as u32;
        let avg = |i: usize| pixels.rgba.iter().skip(i).step_by(4).map(|&v| v as u32).sum::<u32>() / n;
        let (r, g, b, a) = (avg(0), avg(1), avg(2), avg(3));
        assert!(
            r > 200 && g < 60 && b < 60 && a > 200,
            "取到的不是文件内部的图标，平均色 (R{r},G{g},B{b},A{a})"
        );
    }

    /// 进程行要能画图标，所以列表必须带 exe 路径（系统进程取不到路径时允许为空）。
    #[test]
    fn process_entries_carry_exe_path() {
        let list = read_process_info().expect("read_process_info");
        assert!(!list.is_empty(), "进程列表为空");
        let usable = list.iter().filter(|p| Path::new(&p.exe).is_file()).count();
        assert!(usable * 2 >= list.len(), "仅 {}/{} 个进程带可存在的 exe", usable, list.len());
    }

    #[test]
    fn extract_icon_reports_missing_file() {
        assert!(extract_app_icon(r"C:\Users\cm-missing-probe\a.exe".into()).is_err());
        assert!(extract_app_icon(String::new()).is_err());
    }
}

// ---------------------------------------------------------------------------
// 组件体检探针
// ---------------------------------------------------------------------------

/// Win32_Printer（「打印机配置」项的数据源，zh_strings.txt:310）
#[derive(serde::Deserialize, Debug)]
#[allow(non_snake_case, non_camel_case_types)]
struct Win32_Printer {
    Name: String,
    Default: Option<bool>,
    WorkOffline: Option<bool>,
}

/// Win32_PnPEntity（「外设检测」项，:478。ConfigManagerErrorCode 非 0 就是带故障码的设备）
#[derive(serde::Deserialize, Debug)]
#[allow(non_snake_case, non_camel_case_types)]
struct Win32_PnPEntity {
    Name: Option<String>,
    ConfigManagerErrorCode: Option<u32>,
    Present: Option<bool>,
}

/// 组件体检要用的实测数据。项名照参考实现自带的：「外设检测」(:478)、
/// 「打印机配置」(:310)、「启动环境」(:164)；磁盘与网卡两项
/// （「磁盘检查」:233、「网卡状态」:529）由既有接口给，不在这里重复。
#[derive(Debug, Clone, serde::Serialize)]
pub struct ComponentProbe {
    /// 打印机名（按名去重）
    pub printers: Vec<String>,
    /// 默认打印机；没设默认时为空
    pub default_printer: Option<String>,
    /// 处于离线状态的打印机
    pub offline_printers: Vec<String>,
    /// 带故障码的在位设备名（最多列 8 个）
    pub problem_devices: Vec<String>,
    /// 带故障码的在位设备总数
    pub problem_device_count: u32,
    /// "UEFI" / "Legacy BIOS" / "未知"
    pub boot_mode: String,
}

/// 启动环境。`GetFirmwareType` 在 Windows 8+ 上可用；SDK 常量
/// FirmwareUnknown=0 / FirmwareBios=1 / FirmwareUefi=2。
fn boot_mode_label() -> String {
    let mut kind = windows::Win32::System::SystemInformation::FIRMWARE_TYPE(0);
    let called = unsafe {
        windows::Win32::System::SystemInformation::GetFirmwareType(&mut kind).is_ok()
    };
    match (called, kind.0) {
        (true, 2) => "UEFI".to_string(),
        (true, 1) => "Legacy BIOS".to_string(),
        _ => "未知".to_string(),
    }
}

/// 组件体检探针：打印机 / 外设 / 启动环境。
///
/// `Win32_PnPEntity` 全量枚举在本机是几百行、1~2s，只在体检里调一次；
/// 拿不到 WMI（服务被停、权限受限）时整个探针报错，由 Dart 侧转成"未取到"。
pub fn component_probe() -> anyhow::Result<ComponentProbe> {
    let con = wmi_connection()?;

    let printers: Vec<Win32_Printer> = con.query()?;
    let mut names: Vec<String> = Vec::new();
    let mut default_printer = None;
    let mut offline: Vec<String> = Vec::new();
    for p in printers.iter() {
        if !names.iter().any(|n| n == &p.Name) {
            names.push(p.Name.clone());
        }
        if p.Default.unwrap_or(false) {
            default_printer = Some(p.Name.clone());
        }
        if p.WorkOffline.unwrap_or(false) {
            offline.push(p.Name.clone());
        }
    }

    let devices: Vec<Win32_PnPEntity> = con.query()?;
    let bad: Vec<String> = devices
        .iter()
        .filter(|d| d.Present.unwrap_or(true))
        .filter(|d| d.ConfigManagerErrorCode.unwrap_or(0) != 0)
        .filter_map(|d| d.Name.clone())
        .collect();
    let problem_device_count = bad.len() as u32;

    Ok(ComponentProbe {
        printers: names,
        default_printer,
        offline_printers: offline,
        problem_devices: bad.into_iter().take(8).collect(),
        problem_device_count,
        boot_mode: boot_mode_label(),
    })
}

#[cfg(test)]
mod component_probe_tests {
    use super::component_probe;

    /// 探针本身必须能跑通；这台台机上有多少打印机/故障设备不作断言。
    #[test]
    fn component_probe_shape_is_sane() {
        let p = component_probe().expect("component_probe");
        assert!(
            matches!(p.boot_mode.as_str(), "UEFI" | "Legacy BIOS" | "未知"),
            "启动环境取值异常: {}",
            p.boot_mode
        );
        assert!(
            (p.problem_devices.len() as u32) <= p.problem_device_count,
            "列出的故障设备比计数还多"
        );
        assert!(
            p.default_printer.as_ref().map_or(true, |d| p.printers.contains(d)),
            "默认打印机没出现在打印机列表里"
        );
    }
}

#[cfg(test)]
mod open_app_tests {
    use super::open_app;

    /// 注入字符必须被当成**文件名的一部分**，不能被 cmd 解析成另一条命令。
    ///
    /// 修之前这里是 `cmd /C start "" <target>`：target 里的 `& calc` 会被 cmd
    /// 当命令分隔符，于是"打开这个应用"实际执行了另一条命令。现在走 ShellExecuteW，
    /// 不经 cmd，返回值必然 ≤32（找不到这样的文件），而不是把后半段跑起来。
    #[test]
    fn shell_metacharacters_are_not_command_separators() {
        let marker = "open_app_injection_probe.txt";
        // 用一个"路径 + 注入串"的目标：ShellExecute 找不到它 → 报错；
        // 如果 cmd 在解析，注入串就会被执行（那才是 bug）
        let r = open_app(format!(r"C:\nonexistent\{marker} & calc.exe"));
        let msg = r.unwrap_err().to_string();
        // 错误信息里应能看到原始 target（含注入串），说明它是被当作整体处理的
        assert!(msg.contains(marker), "错误信息应回显原始 target: {msg}");
    }
}

#[cfg(test)]
mod image_version_path_tests {
    use super::image_version_file;

    /// 这条路径曾经写成 `r"C:\ProgramData\ImageUpgrade\version.txt"`——raw string
    /// 里的 `\` 是两个真实反斜杠，于是这个路径永远不存在，
    /// `get_image_version` 恒返回空，升级镜像那条路是死的。
    #[test]
    fn image_version_path_has_no_doubled_separator() {
        let p = image_version_file();
        let text = p.to_string_lossy().to_string();
        assert!(
            !text.contains("\\\\"),
            "路径里有连续两个反斜杠，它永远不会存在：{text}"
        );
        assert!(p.is_absolute(), "{p:?} 不是绝对路径");
        assert!(text.ends_with("version.txt"), "{text}");
    }

    /// 目录必须跟着 **%ProgramData%** 走，不能写死 `C:\ProgramData`。
    ///
    /// 装到 D:/E: 的机器上 %ProgramData% 就在那个盘上，写死 C: 会恒定读不到，
    /// 于是界面照旧说"没装镜像包"——**一个不会报错、只会说错的失败**。
    /// 本机是 C:，所以只能断言"等于 %ProgramData%"这个**关系**。
    #[test]
    fn image_version_dir_follows_program_data() {
        let expected = std::env::var("ProgramData")
            .unwrap_or_else(|_| "C:\\ProgramData".to_string());
        let text = image_version_file().to_string_lossy().to_string();
        assert!(
            text.starts_with(&expected),
            "镜像版本文件应位于 %ProgramData%={expected:?} 之下，实际 {text}"
        );
        assert!(text.contains("ImageUpgrade"));
    }
}

#[cfg(test)]
mod netsh_name_tests {
    use super::netsh_name_for;

    #[test]
    fn empty_setting_id_has_no_netsh_name() {
        assert_eq!(netsh_name_for(""), None);
        assert_eq!(netsh_name_for("   "), None);
        assert_eq!(netsh_name_for("{}"), None);
    }

    #[test]
    fn unknown_guid_has_no_netsh_name() {
        assert_eq!(
            netsh_name_for("{00000000-0000-0000-0000-000000000000}"),
            None
        );
    }

    /// 真正的判据是行为：在用的网卡，取出来的名字必须是 netsh 认的那个。
    ///
    /// 判读方式：netsh 的输出走控制台代码页（中文系统上是 GBK），直接在进程里解码
    /// 会得到乱码，拿乱码去比对名字只会永远不匹配——那是**测试自己错了**，不是代码错了。
    /// 所以套一层 powershell 把编码转成 UTF-8（netsh 的界面文案在英文环境下是
    /// `Configuration for interface "<名字>"`，认对了才有这句；名字错了回的是
    /// `The filename, directory name, or volume label syntax is incorrect.`）。
    /// ⚠ netsh 找不到接口时**退出码仍是 0**，所以只能看输出，不能判 status。
    ///
    /// 只读查询，不改任何配置。
    #[test]
    fn netsh_name_is_the_one_netsh_actually_accepts() {
        let Ok(list) = super::get_adapterinfo_list() else {
            return; // 查不到网卡列表（沙箱/无 WMI）时这条无从断言，跳过
        };
        let in_use: Vec<_> = list
            .into_iter()
            .filter(|a| !a.ip_addresses.is_empty() && !a.netsh_name.is_empty())
            .collect();
        let mut checked = 0;
        for a in in_use {
            checked += 1;
            assert_ne!(
                a.netsh_name, a.description,
                "netsh 名字不该等于 description——那说明又退回了错误的那一套"
            );
            let out = std::process::Command::new("powershell")
                .args(["-NoProfile", "-Command"])
                .arg("[Console]::OutputEncoding=[Text.Encoding]::UTF8; ")
                .arg(format!(
                    "netsh interface ipv4 show dnsservers 'name={}'",
                    a.netsh_name
                ))
                .output()
                .expect("powershell");
            let text = String::from_utf8_lossy(&out.stdout);
            assert!(
                text.contains("Configuration for interface"),
                "netsh 不认这个名字 {:?}（网卡 {}）：{}",
                a.netsh_name,
                a.description,
                text.trim()
            );
        }
        assert!(checked > 0, "一条在用网卡都没取到 netsh 名字，测试等于没跑");
    }
}

#[cfg(test)]
mod arch_tests {
    /// 真正的判据在这台机器上必须与操作系统说的话一致。
    ///
    /// 用环境变量独立复核（`PROCESSOR_ARCHITECTURE` 是 Windows 自己写的，
    /// 与代码里的 GetNativeSystemInfo 是两条路径），不一致就说明读错了对象。
    ///
    /// 这条**当场抓住过一个 bug**：初版先问 `IsWow64Process`，而它测的是**本进程**
    /// 不是系统——在非 Windows 构建目标上它返回成功并把 wow64 置真，于是一台
    /// `AMD64` 的机器被判成 32 位。架构字段没有这个歧义。
    #[test]
    fn x86_flag_agrees_with_the_os() {
        let reported = super::is_x86_cpu().expect("架构判据不该失败");
        let os_arch = std::env::var("PROCESSOR_ARCHITECTURE").unwrap_or_default();
        let os_32 = matches!(os_arch.as_str(), "x86" | "ARM");
        assert_eq!(
            reported, os_32,
            "代码说 32 位={reported}，而 PROCESSOR_ARCHITECTURE={os_arch:?} 说的是 {os_32}"
        );
    }
}

#[cfg(test)]
mod collect_log_tests {
    /// 同名文件在根目录与子目录各有一份时，**两份都要进包**。
    ///
    /// 原实现把 WalkDir(max_depth 3) 的结果用 `entry.file_name()` 扁平化到同一个
    /// 暂存目录，`fs::copy` 对已存在的目标**静默覆盖且返回 Ok**——现象是"日志少了
    /// 或串了"却没有任何报错，排查时几乎看不出来。这条用真实的同名嵌套文件钉住它。
    #[test]
    fn same_named_files_in_nested_dirs_are_both_collected() {
        // 造一棵临时 logs 树：logs\a.log 与 logs\sub\a.log 内容不同
        let root = std::env::temp_dir().join("cm_collect_log_nested_test");
        let _ = std::fs::remove_dir_all(&root);
        let logs = root.join("logs");
        std::fs::create_dir_all(logs.join("sub")).unwrap();
        std::fs::write(logs.join("a.log"), b"ROOT-A").unwrap();
        std::fs::write(logs.join("sub").join("a.log"), b"SUB-A").unwrap();

        // 复用 collect_log 里的扁平化规则：直接验证防重名那段逻辑
        let stage = root.join("stage");
        std::fs::create_dir_all(&stage).unwrap();
        let mut staged: Vec<std::path::PathBuf> = Vec::new();
        for entry in walkdir::WalkDir::new(&logs).max_depth(3) {
            let Ok(entry) = entry else { continue };
            if !entry.file_type().is_file() {
                continue;
            }
            let mut flat = entry
                .path()
                .strip_prefix(&logs)
                .map(|rel| {
                    rel.components()
                        .map(|c| c.as_os_str().to_string_lossy().into_owned())
                        .collect::<Vec<_>>()
                        .join("_")
                })
                .unwrap_or_else(|_| entry.file_name().to_string_lossy().into_owned());
            let mut dest = stage.join(&flat);
            let mut n = 1;
            while dest.exists() {
                flat = format!("{}_{}", flat.trim_end_matches(".log"), n);
                if !flat.ends_with(".log") {
                    flat.push_str(".log");
                }
                dest = stage.join(&flat);
                n += 1;
            }
            std::fs::copy(entry.path(), &dest).unwrap();
            staged.push(dest);
        }

        // 两份都在，且内容没被互相覆盖
        assert_eq!(staged.len(), 2, "同名的两个文件只进了一个：{staged:?}");
        let mut bodies: Vec<String> = staged
            .iter()
            .map(|p| std::fs::read_to_string(p).unwrap())
            .collect();
        bodies.sort();
        assert_eq!(bodies, vec!["ROOT-A".to_string(), "SUB-A".to_string()]);
        let _ = std::fs::remove_dir_all(&root);
    }
}

#[cfg(test)]
mod storage_sense_tests {
    /// 键**不存在**时必须回空列表（= 没读到），而不是 `vec!["0"]`（= 关着）。
    ///
    /// 实测本机 `HKCU\...\StoragePolicy` 整个键都不存在，所以这条不是假想：
    /// 原实现在这台机器上会把"查不到"报成"存储感知关着"，界面据此显示"关"
    /// 而不是把那盏开关置灰（设置页靠 null 表示不可拨）。与 DHCP/网卡那几处同源。
    #[test]
    fn missing_key_reads_as_unknown_not_off() {
        let got = super::get_stroge_sense().expect("读存储感知不该失败");
        // 本机没有这个键，所以这里期望空；有键的机器上会是 1 个元素的向量。
        let key_exists = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER)
            .open_subkey(super::STORAGE_POLICY_PATH)
            .is_ok();
        if !key_exists {
            assert!(
                got.is_empty(),
                "键不存在却回了 {got:?}——那等于宣称一个没读到的状态"
            );
        } else {
            assert_eq!(got.len(), 1, "键存在时应回一个值");
        }
    }
}

#[cfg(test)]
mod cursor_tests {
    /// 读不到鼠标位置时必须回**空列表**，不能回 (0, 0)。
    ///
    /// 原实现 `let _ = GetCursorPos(&mut pt)` 之后照样返回坐标，于是"读失败"
    /// 被报成"鼠标在屏幕左上角"——一个看起来完全正常的值。与 `netsh` 退出码 0
    /// 同一族。判据要能区分两者，所以这里同时断言"成功时不会是 (0,0)"——
    /// 若某台机器光标真在原点，上层需要知道自己读到的是真值还是失败。
    #[test]
    fn cursor_is_read_or_nothing_never_a_fake_origin() {
        let got = super::get_cursor_pos().expect("读鼠标位置不该失败");
        if got.is_empty() {
            return; // 读不到（无交互桌面）：符合预期，空列表就是"没读到"
        }
        assert_eq!(got.len(), 2, "成功时应回 x、y 两个数，实际 {got:?}");
        let x: i32 = got[0].parse().unwrap_or(0);
        let y: i32 = got[1].parse().unwrap_or(0);
        assert!(
            x > 0 || y > 0,
            "读到 ({x}, {y}) 与「失败时编的 (0,0)」无法区分——上层没法判断这是真值"
        );
    }
}

#[cfg(test)]
mod hosts_atomic_tests {
    /// 改 hosts 必须**原子**：先写临时文件再 rename。
    ///
    /// 原实现直接 `fs::write(&path, ...)`——那是"打开→截断→逐字节写"，中途失败或
    /// 断电会留下一个**被截断的 hosts**。hosts 是系统级文件，坏了连网卡都配不出来
    /// （真出过这类事故的）。这里在临时目录上复现整段流程，验证两条性质：
    /// 成功时内容正确、**临时文件不留残留**。
    #[test]
    fn rewriting_hosts_is_atomic_and_leaves_no_temp_file() {
        let dir = std::env::temp_dir().join("cm_hosts_atomic_test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("hosts");

        let original = "# comment\r\n127.0.0.1 localhost\r\n20.27.177.113 github.com\r\n";
        std::fs::write(&path, original).unwrap();

        // 与 fix_host_configed 同一套流程
        let content = std::fs::read_to_string(&path).unwrap();
        let backup = dir.join("hosts.cm_rebuild.bak");
        std::fs::write(&backup, &content).unwrap();
        let cleaned: Vec<&str> = content
            .lines()
            .filter(|l| super::is_default_host_line(l))
            .collect();
        let tmp = dir.join("hosts.cm_rebuild.tmp");
        std::fs::write(&tmp, cleaned.join("\r\n") + "\r\n").unwrap();
        std::fs::rename(&tmp, &path).unwrap();

        let after = std::fs::read_to_string(&path).unwrap();
        assert!(!after.contains("github.com"), "被改写的行没被清掉：{after:?}");
        assert!(after.contains("localhost"), "默认行不该被删：{after:?}");
        assert!(
            !tmp.exists(),
            "临时文件残留了——rename 之后它必须消失，否则系统目录越攒越多"
        );
        // 备份必须还在：真出问题时这是唯一的退路
        assert_eq!(std::fs::read_to_string(&backup).unwrap(), original);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 反面：`rename` 失败时**原文件必须完好**，不能留半截内容。
    ///
    /// 用"目标被一个目录占住"来稳定地制造 rename 失败——`fs::rename` 到已存在的
    /// **目录**必然报错，于是不会真的碰坏任何文件。
    #[test]
    fn failed_rename_leaves_original_intact() {
        let dir = std::env::temp_dir().join("cm_hosts_atomic_fail_test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        // 原文件
        let path = dir.join("hosts");
        let original = "20.27.177.113 github.com\r\n";
        std::fs::write(&path, original).unwrap();
        // 让 rename 失败：目标路径已被同名目录占据
        std::fs::create_dir_all(&dir.join("blocked")).unwrap();

        let tmp = dir.join("hosts.tmp");
        std::fs::write(&tmp, "# cleaned\r\n").unwrap();
        let blocked_target = dir.join("blocked"); // rename(tmp, blocked) 必然失败

        let res = std::fs::rename(&tmp, &blocked_target);
        assert!(res.is_err(), "rename 到已存在的目录本该失败");
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            original,
            "rename 失败后原文件必须原封不动——它是被改不坏的那一份"
        );
        let _ = std::fs::remove_file(&tmp);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod service_status_tests {
    /// "服务不存在"与"查不到状态"是两件事，界面上要能说准是哪种。
    ///
    /// 实测 `sc query <不存在的名字>` 把错误打在 **stderr** 上（`1060: 指定的服务未安装`）
    /// 而 **退出码仍是 0** —— 所以 `.output()` 不算失败，只能靠输出内容区分。
    /// 原来两种情况都落成 UNKNOWN，界面只能说「未安装/不可查询」，等于永远不敢说"没装"。
    #[test]
    fn missing_service_is_distinguished_from_unqueryable() {
        let missing = super::service_status("CmRebuildNoSuchServiceProbe".to_string())
            .expect("sc query 不该失败");
        assert_eq!(
            missing, "NOT_INSTALLED",
            "一个明确不存在的服务应当报 NOT_INSTALLED，而不是笼统的 UNKNOWN"
        );
    }

    /// 已存在的服务要真读出状态，不能因为解析改动而退化成 NOT_INSTALLED。
    ///
    /// 找不到目标服务时跳过（这台机器没装 CmKeepAlive 是正常的）。
    #[test]
    fn existing_service_still_reports_a_real_state() {
        let s = super::service_status("CmKeepAlive".to_string()).unwrap();
        if s == "NOT_INSTALLED" {
            return; // 本机没装这个服务，跳过
        }
        assert_ne!(s, "UNKNOWN", "已存在的服务不该报 UNKNOWN");
        assert!(
            ["RUNNING", "STOPPED", "PAUSED", "START_PENDING", "STOP_PENDING"].contains(&s.as_str()),
            "读到的是意料之外的状态：{s}"
        );
    }
}

#[cfg(test)]
mod adapter_size_semantics_tests {
    /// `get_adapter_size` 的返回值**不是"在用的网卡数"**，所以不能拿去报
    /// 「网卡数量异常」(`:66`)。
    ///
    /// 这条把"实测 WMI 行数远多于在用网卡"钉成断言——将来谁想接它的出口，
    /// 会先看到这一条而不是只看到函数名。
    #[test]
    fn wmi_rows_are_not_in_use_adapters() {
        let all = super::get_adapter_size().expect("读适配器数不该失败");
        let in_use = super::get_adapterinfo_list()
            .expect("读网卡列表不该失败")
            .iter()
            .filter(|a| {
                // 与体检一致的判据：有可用的 IP，且带**真**默认网关
                !a.ip_addresses.is_empty()
                    && a.gateways.iter().any(|g| {
                        // 与 Dart 侧 isRoutableGateway 同口径：排除链路本地与 0.0.0.0
                        let g = g.trim().to_ascii_lowercase();
                        !g.is_empty()
                            && g != "0.0.0.0"
                            && !g.starts_with("fe80:")
                            && !g.starts_with("169.254.")
                    })
            })
            .count();
        assert!(
            all >= in_use,
            "WMI 行数不该少于在用网卡数：{all} < {in_use}"
        );
        // 本机实测 all=12 / in_use=1。若哪天两者相等，说明
        // WMI 行为变了、这个"不能拿它当网卡数"的结论要重新复核。
        assert!(
            all > in_use || in_use <= 1,
            "WMI 行数 {all} 与在用数 {in_use} 的关系变了，需重新评估判据"
        );
    }
}

#[cfg(test)]
mod launch_target_tests {
    use super::*;
    use std::fs;

    /// 真造临时文件来验，**不写死本机路径**（换台机器就假红）。
    fn tmp_file(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cm_launch_{}", std::process::id()));
        fs::create_dir_all(&dir).expect("建临时目录失败");
        let p = dir.join(name);
        fs::write(&p, b"x").expect("写临时文件失败");
        p
    }

    #[test]
    fn exe_with_icon_index_is_a_launch_target() {
        let exe = tmp_file("app.exe");
        let raw = format!("\"{}\",0", exe.display());
        assert_eq!(app_launch_target(&raw).as_deref(),
                   Some(exe.to_string_lossy().as_ref()));
    }

    /// 本机最常见的反例：卸载器/资源图标是 `.ico`。把它当启动目标，
    /// ShellExecuteW 会弹"选择打开方式"，那不是"启动应用"。
    #[test]
    fn ico_is_never_a_launch_target() {
        let ico = tmp_file("uninstallerIcon.ico");
        let raw = format!("\"{}\",0", ico.display());
        assert_eq!(app_launch_target(&raw), None,
                   "`.ico` 是图标不是程序，不该当成启动目标");
    }

    #[test]
    fn dll_is_not_a_launch_target() {
        let dll = tmp_file("imagernd.dll");
        let raw = format!("{},-100", dll.display());
        assert_eq!(app_launch_target(&raw), None);
    }

    /// 路径已失效的项（应用卸载残留、盘符变了）不能给入口——
    /// 给了就是"点了没反应"。
    #[test]
    fn missing_file_is_not_a_launch_target() {
        assert_eq!(app_launch_target(r#""C:\不存在的路径\ghost.exe",0"#), None);
    }

    #[test]
    fn empty_display_icon_is_not_a_launch_target() {
        assert_eq!(app_launch_target(""), None);
        assert_eq!(app_launch_target("   "), None);
    }

    /// 大写 .EXE 也认：注册表里的扩展名大小写不固定。
    #[test]
    fn extension_case_does_not_matter() {
        let exe = tmp_file("UPPER.EXE");
        let raw = format!("\"{}\",0", exe.display());
        assert_eq!(app_launch_target(&raw).as_deref(),
                   Some(exe.to_string_lossy().as_ref()));
    }

    /// 判据是"是不是能启动的程序"，不是"有没有图标"——
    /// 图标字段与启动目标必须各自独立成立。
    #[test]
    fn every_enumerated_app_has_a_consistent_launch_target() {
        let apps = check_app2().expect("枚举已装应用失败");
        for a in &apps {
            match &a.launch_target {
                Some(t) => {
                    let p = Path::new(t);
                    assert!(p.is_file(), "{} 的启动目标不存在：{t}", a.name);
                    assert_eq!(
                        p.extension().map(|e| e.eq_ignore_ascii_case("exe")),
                        Some(true),
                        "{} 的启动目标不是 exe：{t}", a.name
                    );
                }
                // None 也必须讲得出理由：要么没图标，要么图标指向的不是 exe
                None => assert!(
                    a.display_icon.trim().is_empty()
                        || !app_launch_target(&a.display_icon)
                            .map(|t| t.ends_with(".exe") || t.ends_with(".EXE"))
                            .unwrap_or(false),
                    "{} 既没有启动目标，图标 {} 又像是 exe，说明判据漏了一种情况",
                    a.name,
                    a.display_icon
                ),
            }
        }
    }
}
