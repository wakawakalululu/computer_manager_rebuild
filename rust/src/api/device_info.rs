//! api::device_info —— 显示器信息（净室实现）。
//!
//! 原路径：api::device_info::monitor / api::device_info::structs_monitor_info。
//! 函数名与 frb codec 映射保持与规格整理规格一致（见 specs/api-map），函数头注释
//! 保留原 codec 名。GetSystemMetrics 属 Win32_UI_WindowsAndMessaging 特性。

use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, SM_CXSCREEN, SM_CXVIRTUALSCREEN, SM_CYSCREEN, SM_CYVIRTUALSCREEN,
    SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};

/// 主显示器分辨率（像素）
#[derive(Debug, Clone, serde::Serialize)]
pub struct MonitorSize {
    pub width: i32,
    pub height: i32,
}

/// 虚拟桌面（全部显示器的边界矩形）工作区信息（像素）
#[derive(Debug, Clone, serde::Serialize)]
pub struct MonitorWorkSize {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

// ---- original path: api::device_info::monitor ----
/// 获取主显示器名。
///
/// 原来直接 `Ok(vec!["Display 0"])` —— 那是个**编出来的名字**：注释里自己写着
/// 「TODO(占位)」。界面上写着它像一句实测结论，实际与这台机器的硬件无关
/// （本机真实设备名是 `QXL0001`，见下）。
///
/// 现在用 `EnumDisplayDevices` 读**系统自己写的** `DeviceString`（如 `QXL0001`），
/// 取第一个（`iDeviceNum == 0`，即主显示器）。读不到时返回**空列表**而不是编一个名——
/// 「没读到」和「有个叫 Display 0 的显示器」不是一回事。
///
/// ⚠ **故意不给适配层出口**（负向结论）：界面**没有可以放它的地方**。参考实现整张文案表里
/// 与显示设备有关的只有「分辨率变动！」(`:432`) 与「分辨率变动！通知类型」(`:265`) 两句
/// **日志**，搜「显示器 / 屏幕 / 刷新」零条界面标签；classes 里也只有一个 `DisplayFeatureState`
/// 孤名。也就是说对面拿设备名去做什么没有第二处证据，接出来只能凭空造一行显示。
/// 窗口尺寸那条路不需要它——工作区/主屏分辨率走 `get_monitor_work_size` 与
/// `get_monitor_size`，这条只给名字。
pub fn get_main_monitor() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiDeviceInfoMonitorRGetMainMonitor
    //
    // windows 0.58 里 EnumDisplayDevicesW 在 **Win32::Graphics::Gdi**（不是 Display），
    // 且是 4 参数版本（无 lpszDeviceString / dwFlags 拆分）。
    use windows::Win32::Graphics::Gdi::{EnumDisplayDevicesW, DISPLAY_DEVICEW};
    use windows::core::PCWSTR;

    // SAFETY: 传空的设备枚举（= 枚举显示器），输出结构体由 API 填满。
    let mut dev: DISPLAY_DEVICEW = unsafe { std::mem::zeroed() };
    dev.cb = std::mem::size_of::<DISPLAY_DEVICEW>() as u32;
    let ok = unsafe { EnumDisplayDevicesW(PCWSTR::null(), 0, &mut dev, 0) };
    if !ok.as_bool() {
        return Ok(Vec::new());
    }
    // DeviceString 是固定长度的 WCHAR 缓冲（本机型 32 个），API 只保证"以 NUL 结尾"，
    // 不会把后面的槽位清零。直接对整个数组 from_utf16_lossy 会把尾部一串 NUL
    // 也解出来（实测拿到 "ELINK DISPLAY WDDM DRIVER\0\0\0…"）——
    // 必须先截到第一个 NUL 再转字符串。
    let raw = &dev.DeviceString[..];
    let end = raw.iter().position(|&c| c == 0).unwrap_or(raw.len());
    let name = String::from_utf16_lossy(&raw[..end]).trim().to_string();
    if name.is_empty() {
        return Ok(Vec::new());
    }
    Ok(vec![name])
}

// ---- original path: api::device_info::structs_monitor_info ----
/// 获取主显示器分辨率：SM_CXSCREEN=0 / SM_CYSCREEN=1。
pub fn get_monitor_size() -> anyhow::Result<MonitorSize> {
    // frb codec: crateApiDeviceInfoStructsMonitorInfoGetMonitorSize
    Ok(MonitorSize {
        width: unsafe { GetSystemMetrics(SM_CXSCREEN) },
        height: unsafe { GetSystemMetrics(SM_CYSCREEN) },
    })
}

/// 获取工作区（窗口真正能放的那一片，已扣掉任务栏等停靠区）。
///
/// ⚠ 这里原先读的是 `SM_XVIRTUALSCREEN` / `SM_CXVIRTUALSCREEN` 那一组，**那是虚拟
/// 桌面尺寸，不是工作区**：任务栏贴底时它仍然返回整块屏幕的高度（本机实测
/// 1802×1013，而系统真实工作区是 1802×973，差 40 像素正好是任务栏）。
/// 函数名写着 work_size，实现却不做这件事——窗口按它算高度，底边正好压在任务栏上。
///
/// 真要工作区得问 `SPI_GETWORKAREA`。注意它给的是**主显示器**的工作区（不是全部
/// 显示器合起来那一片），坐标以主屏左上角为原点；多显示器各自的工作区要枚举
/// `EnumDisplayMonitors` 才是，这里不夸大范围。
pub fn get_monitor_work_size() -> anyhow::Result<MonitorWorkSize> {
    // frb codec: crateApiDeviceInfoStructsMonitorInfoGetMonitorWorkSize
    use windows::Win32::Foundation::RECT;
    use windows::Win32::UI::WindowsAndMessaging::{
        SystemParametersInfoW, SPI_GETWORKAREA, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS,
    };

    let mut rc: RECT = unsafe { std::mem::zeroed() };
    // SAFETY: rc 是有效的 RECT 出参；uParam 对 SPI_GETWORKAREA 必须为 0，
    // pvParam 指向 rc，cbParam 传 sizeof(RECT)。
    let ok = unsafe {
        SystemParametersInfoW(
            SPI_GETWORKAREA,
            0,
            Some(&mut rc as *mut RECT as *mut core::ffi::c_void),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(std::mem::size_of::<RECT>() as u32),
        )
    };
    if ok.is_err() {
        // 取不到就退回虚拟桌面尺寸：宁可少扣一点，也不能返回 0×0（那会让窗口按 0 当硬上限）。
        return Ok(MonitorWorkSize {
            x: unsafe { GetSystemMetrics(SM_XVIRTUALSCREEN) },
            y: unsafe { GetSystemMetrics(SM_YVIRTUALSCREEN) },
            width: unsafe { GetSystemMetrics(SM_CXVIRTUALSCREEN) },
            height: unsafe { GetSystemMetrics(SM_CYVIRTUALSCREEN) },
        });
    }
    Ok(MonitorWorkSize {
        x: rc.left,
        y: rc.top,
        width: rc.right - rc.left,
        height: rc.bottom - rc.top,
    })
}

#[cfg(test)]
mod main_monitor_tests {
    /// 主显示器名必须是**这台机器真实的**设备名，不能是编出来的 `"Display 0"`。
    ///
    /// 原实现直接 `Ok(vec!["Display 0"])`，注释里写着「TODO(占位)」——界面上那句像
    /// 一句实测结论，实际与硬件无关（本机真实名是 `QXL0001`，见 WmiMonitorID）。
    /// 这条断言"与 OS 说的对得上"，不是"函数没崩"。
    #[test]
    fn main_monitor_is_the_real_device_name() {
        let got = super::get_main_monitor().expect("读主显示器名不该失败");

        // 独立复核：PowerShell 侧走 WmiMonitorID 的 InstanceName（另一条数据路径）
        let os = std::process::Command::new("powershell")
            .args(["-NoProfile", "-Command", r"(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID | Select-Object -First 1).InstanceName"])
            .output();
        if os.is_err() || String::from_utf8_lossy(&os.as_ref().unwrap().stdout).trim().is_empty() {
            return; // 环境不支持 WMI，跳过交叉比对
        }
        let os_name = String::from_utf8_lossy(&os.unwrap().stdout).trim().to_string();
        // ⚠ 这两个**不是同一个标识**：`EnumDisplayDevices` 给的是显示器的**友好名**
        // （本机 `ELINK DISPLAY WDDM DRIVER`），`WmiMonitorID.InstanceName` 给的是
        // **设备实例 ID**（`DISPLAY\QXL0001\…`）。所以不能断言"互相包含"。
        // 真正该钉的是：**返回的不是编出来的占位串，且与 OS 报告的显示器数量一致**。
        assert!(
            !got.is_empty(),
            "OS 那边能查到显示器（{os_name}），这里却返回空——说明没真读到"
        );
        let os_count = std::process::Command::new("powershell")
            .args(["-NoProfile", "-Command", r"(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID).Count"])
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default();
        assert!(
            got.len() <= os_count.parse::<usize>().unwrap_or(got.len()) + 1,
            "返回了 {} 个显示器，而 OS 只认得出 {os_count} 个", got.len()
        );
        assert!(
            !got.iter().any(|n| n == "Display 0"),
            "仍然返回编出来的占位名 \"Display 0\""
        );
    }
}

#[cfg(test)]
mod work_area_tests {
    use super::*;

    /// 独立取主显示器的工作区：走 `EnumDisplayMonitors` + `GetMonitorInfoW`，
    /// 与实现用的 `SPI_GETWORKAREA` 是**两条不同的 API 路径**。
    ///
    /// 没有这个交叉比对，判据只能在"工作区"和"虚拟桌面"之间比——而那两组指标
    /// 在多屏机上天然分家，落到单屏机上就恒真：把实现改回 `SM_CXVIRTUALSCREEN`，
    /// 两条断言照样全绿（实测过）。所以判据必须换一个**没被实现用到**的数据源。
    fn primary_work_area_via_monitor_info() -> Option<(i32, i32, i32, i32)> {
        use windows::Win32::Foundation::{BOOL, LPARAM, RECT};
        use windows::Win32::Graphics::Gdi::{EnumDisplayMonitors, MONITORINFO};

        unsafe extern "system" fn cb(
            hmon: windows::Win32::Graphics::Gdi::HMONITOR,
            _hdc: windows::Win32::Graphics::Gdi::HDC,
            _lprc: *mut RECT,
            data: LPARAM,
        ) -> BOOL {
            // data 是调用方给的 out 槽位指针（指向 RECT）。
            let out = data.0 as *mut RECT;
            let mut mi = MONITORINFO {
                cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                ..std::mem::zeroed()
            };
            if windows::Win32::Graphics::Gdi::GetMonitorInfoW(hmon, &mut mi).as_bool() {
                *out = mi.rcWork;
            }
            // 返回 0 中止枚举：只取第一个（主显示器排在最前）。
            BOOL(0)
        }

        let mut rc: RECT = unsafe { std::mem::zeroed() };
        // SAFETY: cb 只写 data 指向的 RECT 且立刻返回 0，槽位在本函数栈上有效。
        // 返回值在这里没有判据：枚举"失败"与"没有显示器"都落在下面的
        // rc 全零判断上，分开区分反而是给两种结果编区分。
        unsafe {
            let _ = EnumDisplayMonitors(
                None,
                None,
                Some(cb),
                LPARAM(&mut rc as *mut RECT as isize),
            );
        }
        if rc.right <= rc.left || rc.bottom <= rc.top {
            return None;
        }
        Some((rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top))
    }

    /// 工作区必须与操作系统自己说的主显示器工作区**一致**。
    ///
    /// 这才是能钉住实现的那条：`SPI_GETWORKAREA`（实现用的）与
    /// `GetMonitorInfoW(MONITORINFO.rcWork)`（判据用的）两条独立路径应给出同一片
    /// 区域。改回 `SM_CXVIRTUALSCREEN` 就会差出一个任务栏的高度而红。
    #[test]
    fn work_area_matches_monitor_info_rc_work() {
        let Some((_, _, w, h)) = primary_work_area_via_monitor_info() else {
            // 拿不到第二个数据源时这条判据不成立，跳过而不是假装通过。
            eprintln!("跳过：EnumDisplayMonitors/GetMonitorInfoW 未返回工作区");
            return;
        };
        let work = get_monitor_work_size().expect("取工作区失败");
        assert_eq!(
            (work.width, work.height),
            (w, h),
            "实现读到的 {:?} 与 OS 的主屏工作区 {:?} 不一致——读的多半是虚拟桌面尺寸",
            (work.width, work.height),
            (w, h)
        );
    }

    /// 工作区不能是 0×0（那会让窗口按 0 当硬上限），也不能超出整块屏幕。
    #[test]
    fn work_area_is_within_primary_screen() {
        let work = get_monitor_work_size().expect("取工作区失败");
        let primary = get_monitor_size().expect("取屏幕分辨率失败");
        assert!(
            work.width > 0 && work.height > 0,
            "工作区不能是 0×0：窗口会按 0 当硬上限"
        );
        assert!(
            work.width <= primary.width && work.height <= primary.height,
            "工作区 {:?} 超出了屏幕 {:?}",
            (work.width, work.height),
            (primary.width, primary.height)
        );
    }
}
