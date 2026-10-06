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
/// TODO(占位)：真实多显示器枚举（EnumDisplayMonitors 等）的命名规则规格整理未确认，
/// 主显示器按约定固定命名为 "Display 0"。
pub fn get_main_monitor() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiDeviceInfoMonitorRGetMainMonitor
    Ok(vec!["Display 0".to_string()])
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

/// 获取虚拟桌面工作区：SM_XVIRTUALSCREEN=76 / SM_YVIRTUALSCREEN=77 /
/// SM_CXVIRTUALSCREEN=78 / SM_CYVIRTUALSCREEN=79。
pub fn get_monitor_work_size() -> anyhow::Result<MonitorWorkSize> {
    // frb codec: crateApiDeviceInfoStructsMonitorInfoGetMonitorWorkSize
    Ok(MonitorWorkSize {
        x: unsafe { GetSystemMetrics(SM_XVIRTUALSCREEN) },
        y: unsafe { GetSystemMetrics(SM_YVIRTUALSCREEN) },
        width: unsafe { GetSystemMetrics(SM_CXVIRTUALSCREEN) },
        height: unsafe { GetSystemMetrics(SM_CYVIRTUALSCREEN) },
    })
}
