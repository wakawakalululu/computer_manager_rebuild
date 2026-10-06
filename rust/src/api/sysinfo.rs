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

/// 镜像升级版本记录文件（沿袭参考实现路径）
const IMAGE_VERSION_FILE: &str = r"C:\ProgramData\\ImageUpgrade\version.txt";

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
    std::fs::write(&path, cleaned.join("\r\n") + "\r\n")?;
    let _ = Command::new("ipconfig").arg("/flushdns").status();
    Ok(true)
}

/// 适配器数量（条数）
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
        None => Ok(vec!["false".to_string()]),
    }
}

/// 是否开启了手动代理（HKCU\...\Internet Settings\ProxyEnable != 0）
pub fn has_manual_proxy() -> anyhow::Result<bool> {
    // frb codec: crateApiSysinfoAdapterRHasManualProxy
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let key = hkcu.open_subkey(INET_SETTINGS_PATH)?;
    let enable: u32 = key.get_value("ProxyEnable").unwrap_or(0);
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

/// 外网连通性探测：TCP 连接 1.1.1.1:80，1 秒超时
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
        out.push(InstalledAppInfo {
            name,
            version,
            publisher,
            uninstall_string,
            display_icon,
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
        .unwrap_or_else(|| "UNKNOWN".to_string());
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
pub fn get_cursor_pos() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiSysinfoCursorRGetCursorPos
    let mut pt = POINT::default();
    // GetCursorPos 的返回类型（BOOL/Result）不做依赖，用 let _ 吞掉；
    // 交互桌面下该调用基本不会失败，失败时返回 (0, 0)
    let _ = unsafe { GetCursorPos(&mut pt) };
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
            let dest = stage_dir.join(entry.file_name());
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
    let key = match hkcu.open_subkey(STORAGE_POLICY_PATH) {
        Ok(k) => k,
        Err(_) => return Ok(vec!["0".to_string()]),
    };
    let v: u32 = key.get_value("01").unwrap_or(0);
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
    match std::fs::read_to_string(IMAGE_VERSION_FILE) {
        Ok(s) => Ok(vec![s.trim().to_string()]),
        Err(_) => Ok(Vec::new()),
    }
}

/// 是否 x86（32 位）CPU 架构编译目标
pub fn is_x86_cpu() -> anyhow::Result<bool> {
    // frb codec: crateApiSysinfoUpgradeImageRIsX86Cpu
    Ok(cfg!(target_arch = "x86"))
}

// ---------------------------------------------------------------------------
// api::sysinfo::windows_info
// ---------------------------------------------------------------------------

// ---- original path: api::sysinfo::windows_info ----

/// 应用列表：枚举开始菜单（所有用户 + 当前用户）的 .lnk 项，
/// 去重排序后最多返回 500 条
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

/// 打开应用：路径存在则直接 spawn，否则交给 cmd start 按名称/协议解析
pub fn open_app(target: String) -> anyhow::Result<()> {
    // frb codec: crateApiSysinfoWindowsInfoROpenApp
    let p = Path::new(&target);
    if p.exists() {
        Command::new(p).spawn().context("启动应用失败")?;
    } else {
        Command::new("cmd")
            .args(["/C", "start", "", target.as_str()])
            .spawn()
            .context("启动应用失败")?;
    }
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
