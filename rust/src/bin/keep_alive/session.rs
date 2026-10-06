//! 交互会话注入 —— 把进程拉进"当前登录用户的桌面会话"，而不是调用方所在的会话。
//!
//! 规格来源：`specs/arch-notes` §2。原 `keep_alive` 服务是 C++ 实现，
//! 证据里明确有 `CreateProcessAsUser`：服务跑在会话 0（Services），被守护的
//! agent / GUI 必须出现在交互用户会话里，否则悬浮窗与托盘根本画不出来。
//! 本工程此前用 `std::process::Command` 同上下文 spawn，等价于"服务拉起 =
//! 拉进会话 0"，只有 GUI 侧的会话内守护才是对的，故补上这条真实路径。
//!
//! 权限模型（决定本模块为什么长这样）：
//!  * `WTSQueryUserToken` 要求调用方持有 `SeTcbPrivilege`（"作为操作系统的一部分"），
//!    默认只给 LocalSystem / LocalService / NetworkService。服务态直接可用。
//!  * `CreateProcessAsUserW` 还要求 `SeAssignPrimaryTokenPrivilege`（或 `SeTcbPrivilege`）
//!    与 `SeIncreaseQuotaPrivilege` —— 也就是说"取到令牌"和"用令牌起进程"必须是
//!    **同一个身份**，所以借 SYSTEM 令牌时整条注入链路（取令牌 → 复制 primary →
//!    CreateProcessAsUser）都要在冒充上下文里跑完，不能取完就还原。
//!  * 管理员令牌**没有** `SeTcbPrivilege`，但有 `SeDebugPrivilege`。所以现场用
//!    管理员账户手动 `--run` 调试时，这里退而求其次：借会话 0 的 System 进程
//!    （pid 4）令牌 `SetThreadToken` 临时冒充，跑完立刻还原。
//!  * 令牌特权"启得上"不等于"API 认"：本机实测 `AdjustTokenPrivileges(SE_TCB_NAME)`
//!    成功，`WTSQueryUserToken` 依旧被拒（策略/安全产品拦截）。因此直取一旦失败，
//!    **无条件**再走一次借 SYSTEM 令牌，而不是按特权标志跳过。
//!  * 两条路都不通（普通用户 / 无人登录）就返回 `Err`，由调用方回落同上下文
//!    spawn —— 守护不能因为注入失败就彻底不拉进程。
//!  * 每条失败路径都带出真实 Win32 错误码 + 判读（5=拒绝访问，1314=缺特权，
//!    1312=该会话没有登录会话即无人登录，1300=特权没启上来），现场只看日志就能
//!    区分"没人登录"和"没权限"。错误码一律取 windows crate 常量，不手抄数字。

use std::ffi::c_void;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;

use anyhow::{anyhow, Context, Result};
use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::{
    CloseHandle, HANDLE, LUID, WIN32_ERROR, ERROR_ACCESS_DENIED, ERROR_BAD_IMPERSONATION_LEVEL,
    ERROR_NOT_ALL_ASSIGNED, ERROR_NO_SUCH_LOGON_SESSION, ERROR_PRIVILEGE_NOT_HELD, SetLastError,
};
use windows::Win32::System::Environment::{CreateEnvironmentBlock, DestroyEnvironmentBlock};
use windows::Win32::System::RemoteDesktop::{
    WTSEnumerateSessionsW, WTSFreeMemory, WTSGetActiveConsoleSessionId, WTSQueryUserToken,
    WTS_SESSION_INFOW, WTSActive,
};
use windows::Win32::System::Threading::{
    CreateProcessAsUserW, GetCurrentProcess, OpenProcess, OpenProcessToken, SetThreadToken, CREATE_NO_WINDOW,
    CREATE_UNICODE_ENVIRONMENT, PROCESS_INFORMATION, PROCESS_QUERY_INFORMATION,
    STARTUPINFOW,
};
use windows::Win32::Security::{
    AdjustTokenPrivileges, DuplicateTokenEx, LookupPrivilegeValueW,
    SE_PRIVILEGE_ENABLED, SE_DEBUG_NAME, SE_TCB_NAME, SecurityImpersonation,
    TOKEN_ADJUST_PRIVILEGES, TOKEN_ASSIGN_PRIMARY, TOKEN_DUPLICATE, TOKEN_IMPERSONATE,
    TOKEN_PRIVILEGES, TOKEN_QUERY, TokenImpersonation, TokenPrimary, LUID_AND_ATTRIBUTES,
};

/// 当前活动控制台会话号；`0xFFFFFFFF`（无控制台会话）返回 `None`。
pub fn console_session_id() -> Option<u32> {
    // SAFETY: 无参数，纯查询。
    let id = unsafe { WTSGetActiveConsoleSessionId() };
    (id != u32::MAX).then_some(id)
}

/// 交互用户会话号：优先枚举到 `WTSActive` 且非 0 号的会话，其次回落控制台会话。
///
/// 为什么要枚举而不是直接用控制台会话号：云电脑/远程桌面下用户挂在 RDP 会话上，
/// 控制台会话可能是断开的空会话，界面要出现在真正活动的那个会话里。
pub fn active_user_session() -> Option<u32> {
    let mut info: *mut WTS_SESSION_INFOW = std::ptr::null_mut();
    let mut count: u32 = 0;
    // SAFETY: 出参为本栈上的空指针地址；成功后那段数组由 WTSFreeMemory 释放。
    if unsafe { WTSEnumerateSessionsW(HANDLE(std::ptr::null_mut()), 0, 1, &mut info, &mut count) }.is_err() {
        return console_session_id();
    }
    let mut picked = None;
    // SAFETY: info/count 由 WTSEnumerateSessionsW 保证为一段有效数组。
    unsafe {
        for i in 0..count {
            let entry = *info.add(i as usize);
            if entry.State == WTSActive && entry.SessionId != 0 {
                picked = Some(entry.SessionId);
                break;
            }
        }
        WTSFreeMemory(info as *mut c_void);
    }
    picked.or_else(console_session_id)
}

/// 尝试在当前进程令牌上启用一项特权。
///
/// 返回 `Ok(true)` 已启用；`Ok(false)` 表示令牌里根本没有这项特权
/// （`AdjustTokenPrivileges` 会以 `ERROR_NOT_ALL_ASSIGNED` = 1300 报告）；
/// `Err` 才是真的调用失败。调用方通常只关心"能不能"，不该因为 `Ok(false)` 报错。
///
/// 这里踩过一次坑：`ERROR_NOT_ALL_ASSIGNED` 是 1300 而不是 0x0522(1314=
/// `ERROR_PRIVILEGE_NOT_HELD`)，抄错之后管理员进程会被误判成"SeTcbPrivilege
/// 已启用"，于是跳过借 SYSTEM 令牌那条唯一能走通的路，日志还把原因写成"已启用"。
/// 所以错误码一律取 windows crate 的常量，并且在调用前显式清零 last error ——
/// `AdjustTokenPrivileges` 成功时不重置 last error，不清零会读到上一步的残值。
pub fn enable_privilege(name: PCWSTR) -> Result<bool> {
    let mut luid = LUID::default();
    let mut token = HANDLE(std::ptr::null_mut());
    // SAFETY: 出参都是本栈上的有效地址；token 句柄在返回前关闭。
    unsafe {
        LookupPrivilegeValueW(None, name, &mut luid).context("LookupPrivilegeValueW")?;
        OpenProcessToken(
            GetCurrentProcess(),
            TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
            &mut token,
        )
        .context("OpenProcessToken")?;
        let tp = TOKEN_PRIVILEGES {
            PrivilegeCount: 1,
            Privileges: [LUID_AND_ATTRIBUTES { Luid: luid, Attributes: SE_PRIVILEGE_ENABLED }],
        };
        SetLastError(WIN32_ERROR(0));
        // 第二个参数 false = 只增不减；后两个出参传 None 表示不查询旧值。
        let adjusted = AdjustTokenPrivileges(token, false, Some(&tp), 0, None, None);
        // 真话只在这里：AdjustTokenPrivileges 连"一项都没启上来"都返回成功。
        let last = windows::core::Error::from_win32().code().0 as u32 & 0xFFFF;
        CloseHandle(token).ok();
        adjusted.context("AdjustTokenPrivileges")?;
        Ok(last != ERROR_NOT_ALL_ASSIGNED.0)
    }
}

/// 从 `windows::core::Error` 取出 Win32 错误码（`HRESULT_FROM_WIN32` 的低 16 位）。
fn win32_code(e: &windows::core::Error) -> u32 {
    e.code().0 as u32 & 0xFFFF
}

/// 错误码的可读判读，直接进日志：现场不用翻错误码表就知道下一步查什么。
/// 一律用 windows crate 的常量比对，不再手抄数字。
fn code_hint(code: u32) -> &'static str {
    match code {
        c if c == ERROR_ACCESS_DENIED.0 => "拒绝访问：身份不足或被安全策略拦截",
        c if c == ERROR_PRIVILEGE_NOT_HELD.0 => {
            "调用方缺少所需特权（SeTcbPrivilege / SeAssignPrimaryTokenPrivilege）"
        }
        c if c == ERROR_NO_SUCH_LOGON_SESSION.0 => "该会话没有登录会话（无人登录）",
        c if c == ERROR_BAD_IMPERSONATION_LEVEL.0 => "冒充级别不对（令牌需为 impersonation 类型）",
        _ => "未知，需查 Win32 错误码表",
    }
}

/// 统一格式的 Win32 失败描述：哪一步 + 错误码 + 判读。
fn werr(step: &str, e: &windows::core::Error) -> anyhow::Error {
    let code = win32_code(e);
    anyhow!("{step} 失败：错误码 {code} (0x{code:04X}，{}）", code_hint(code))
}

/// 调 `WTSQueryUserToken` 取指定会话的交互用户令牌；失败带出真实错误码。
fn query_user_token(session_id: u32) -> Result<HANDLE> {
    let mut token = HANDLE(std::ptr::null_mut());
    // SAFETY: 出参为本栈地址；成功时句柄由调用方 CloseHandle。
    match unsafe { WTSQueryUserToken(session_id, &mut token) } {
        Ok(()) => Ok(token),
        Err(e) => Err(werr(&format!("WTSQueryUserToken(会话 {session_id})"), &e)),
    }
}

/// 在当前身份下完成整条注入：取用户令牌 → 复制 primary → 用户环境块 → CreateProcessAsUser。
///
/// 返回 `(pid, 是否带上了用户环境块)`。
/// 必须整体成一体：`CreateProcessAsUserW` 要求调用身份持有 `SeAssignPrimaryTokenPrivilege`
/// 或 `SeTcbPrivilege`，所以借 SYSTEM 令牌时这一步也要在冒充上下文里跑。
fn launch_as(exe: &Path, session_id: u32) -> Result<(u32, bool)> {
    let dir = exe
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let user_token = query_user_token(session_id)?;

    // WTSQueryUserToken 给的已经是 primary 令牌，但访问掩码不一定含
    // TOKEN_ASSIGN_PRIMARY，CreateProcessAsUser 会因此拒绝，故再复制一份。
    let mut primary = HANDLE(std::ptr::null_mut());
    // SAFETY: 出参为本栈地址；user_token 复制后立即关闭。
    let dup = unsafe {
        DuplicateTokenEx(
            user_token,
            TOKEN_ASSIGN_PRIMARY | TOKEN_DUPLICATE | TOKEN_IMPERSONATE | TOKEN_QUERY,
            None,
            SecurityImpersonation,
            TokenPrimary,
            &mut primary,
        )
    };
    // SAFETY: user_token 由 query_user_token 打开，此处已不再使用。
    unsafe { CloseHandle(user_token).ok() };
    if let Err(e) = dup {
        return Err(werr("DuplicateTokenEx(primary)", &e));
    }

    // 用户环境块：没有它，agent 读不到 %USERPROFILE% / %APPDATA%，
    // 配置与日志会落到服务账户目录下——原服务同样带环境块。
    let mut env_block: *mut c_void = std::ptr::null_mut();
    // SAFETY: primary 为本函数持有的有效令牌句柄。
    let has_env = unsafe { CreateEnvironmentBlock(&mut env_block, primary, false) }.is_ok();

    // lpDesktop 必须是可写缓冲（PWSTR），指向目标会话的交互桌面。
    let mut desktop: Vec<u16> = "Winsta0\\Default".encode_utf16().chain([0]).collect();
    let exe_wide: Vec<u16> = exe.as_os_str().encode_wide().chain([0]).collect();
    let dir_wide: Vec<u16> = dir.as_os_str().encode_wide().chain([0]).collect();

    let mut si = STARTUPINFOW {
        cb: std::mem::size_of::<STARTUPINFOW>() as u32,
        lpDesktop: PWSTR(desktop.as_mut_ptr()),
        ..Default::default()
    };
    let mut pi = PROCESS_INFORMATION::default();

    // SAFETY: 传入的每个指针在本调用期间都活着（desktop/exe/dir 三个 Vec 在作用域内），
    // 句柄与环境块在下面的统一清理里关闭。
    let started = unsafe {
        CreateProcessAsUserW(
            primary,
            PCWSTR(exe_wide.as_ptr()),
            PWSTR::null(),
            None,
            None,
            false,
            CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
            if has_env { Some(env_block as *const c_void) } else { None },
            PCWSTR(dir_wide.as_ptr()),
            &mut si,
            &mut pi,
        )
    };
    let pid = pi.dwProcessId;
    // SAFETY: 句柄与环境块在此统一释放；成功时 hThread 立即关，hProcess 只取 pid 不持有。
    unsafe {
        if has_env && !env_block.is_null() {
            DestroyEnvironmentBlock(env_block).ok();
        }
        CloseHandle(primary).ok();
        if started.is_ok() {
            CloseHandle(pi.hThread).ok();
            CloseHandle(pi.hProcess).ok();
        }
    }
    if let Err(e) = started {
        return Err(werr("CreateProcessAsUserW", &e));
    }
    Ok((pid, has_env))
}

/// 注入结果：pid + 所走的权限路径 + 是否拿到用户环境块。
///
/// 后两项直接进服务日志，现场只看一行就知道进程是谁把它拉起来的、
/// 读的是哪个用户的 `%APPDATA%`。
#[derive(Debug)]
pub struct LaunchInfo {
    pub pid: u32,
    pub via: &'static str,
    pub env_block: bool,
}

/// 把 `exe` 拉进 `session_id` 会话的交互桌面。
///
/// 先按服务态直取（`SeTcbPrivilege`），失败则**无条件**借 SYSTEM 令牌整条链路重试；
/// 两条路都不通才 `Err`，且错误里带真实错误码，调用方负责回落同上下文 spawn。
pub fn launch_in_user_session(exe: &Path, session_id: u32) -> Result<LaunchInfo> {
    // 先把 SeTcbPrivilege 能启就启上：启不上也不报错，后面还有借 SYSTEM 这条路。
    let tcb = enable_privilege(SE_TCB_NAME).unwrap_or(false);
    match launch_as(exe, session_id) {
        Ok((pid, env_block)) => Ok(LaunchInfo {
            pid,
            env_block,
            via: if tcb { "SeTcbPrivilege 直取" } else { "直取（令牌自带 SeTcbPrivilege）" },
        }),
        Err(direct) => match system_impersonation() {
            // 守卫要活到 launch_as 返回：`CreateProcessAsUserW` 需要的
            // SeAssignPrimaryToken/SeTcbPrivilege 正是靠这次冒充才拿到的。
            Ok(_guard) => match launch_as(exe, session_id) {
                Ok((pid, env_block)) => Ok(LaunchInfo {
                    pid,
                    env_block,
                    via: "借 SYSTEM 令牌（取令牌与注入同在冒充上下文内）",
                }),
                Err(borrowed) => Err(anyhow!(
                    "交互会话注入两条路都失败：直取[{direct}]；借 SYSTEM 令牌[{borrowed}]"
                )),
            },
            Err(why) => Err(anyhow!(
                "交互会话注入失败：直取[{direct}]；借 SYSTEM 令牌没借到[{why}]"
            )),
        },
    }
}

/// 线程令牌冒充守卫：Drop 时还原为"不冒充"并关闭借来的令牌。
///
/// 用 RAII 而不是手写还原：注入链路中间任何一步失败都必须还原，否则本线程
/// 后续所有 Win32 调用都跑在 SYSTEM 身份下（连日志落点都会跟着变）。
struct Impersonation(HANDLE);

impl Drop for Impersonation {
    fn drop(&mut self) {
        // SAFETY: 本结构只持有 SetThreadToken 成功后的 impersonation 令牌句柄。
        unsafe {
            let _ = SetThreadToken(None, HANDLE(std::ptr::null_mut()));
            let _ = CloseHandle(self.0);
        }
    }
}

/// 启动时的一次性能力预检：只查不拉起，把"这个身份到底能不能注入会话"写进日志。
///
/// 现场排障第一行就该看到这个结论，而不是等某个进程缺失了才从逐次 WARN 里倒推；
/// 也解释了为什么管理员手动 `--run` 时日志会走"同上下文拉起" —— 那不是 bug，
/// 是当前身份本来就注入不了（只有 LocalSystem 服务态才有 SeTcbPrivilege）。
pub fn precheck() -> String {
    let Some(sid) = active_user_session() else {
        return "无活动用户会话（无人登录），注入无从谈起，只能同上下文拉起".to_string();
    };
    let tcb = enable_privilege(SE_TCB_NAME).unwrap_or(false);
    let (direct, direct_ok) = match query_user_token(sid) {
        // 预检只验证"取得到"，句柄立刻关闭，不留任何冒充或残留状态。
        Ok(token) => {
            // SAFETY: token 由 query_user_token 打开，本函数不再使用。
            unsafe { CloseHandle(token).ok() };
            (format!("可取（SeTcbPrivilege 启用={}）", tcb), true)
        }
        Err(e) => (format!("不可取[{e}]"), false),
    };
    let (borrow, borrow_ok) = match system_impersonation() {
        // 守卫出作用域即还原线程令牌：预检不会把调用线程留在 SYSTEM 身份下。
        Ok(_guard) => ("可借".to_string(), true),
        Err(e) => (format!("不可借[{e}]"), false),
    };
    format!(
        "目标会话={sid}；直取用户令牌: {direct}；借 SYSTEM 令牌: {borrow}；结论={}",
        if direct_ok || borrow_ok { "可注入交互会话" } else { "只能同上下文拉起（需 LocalSystem 服务态才能注入）" }
    )
}

/// 借会话 0 的 System 进程（pid 4）令牌冒充当前线程，返回守卫（Drop 自动还原）。
///
/// 需要 `SeDebugPrivilege`（管理员默认持有、默认未启用，这里自行启用）。
/// 每一步失败都点名是哪一步、带错误码：本机的两个真实卡点分别是
/// 安全产品剥掉 `SeDebugPrivilege`（`OpenProcess(pid 4)` 给 5），
/// 以及访问掩码用错导致 `OpenProcessToken` 给 5（见下面注释）。
fn system_impersonation() -> Result<Impersonation> {
    // SeDebugPrivilege 的启用结果必须出现在每一条失败原因里：它是"借得到令牌"
    // 与"OpenProcess 成功但令牌 DACL 拒绝"这两种现场的唯一区分依据。
    let debug_state = match enable_privilege(SE_DEBUG_NAME) {
        Ok(true) => "已启用".to_string(),
        Ok(false) => "令牌里没有这项特权（被组策略/安全产品剥掉）".to_string(),
        Err(e) => format!("启用调用失败: {e}"),
    };
    let note = |e: anyhow::Error| {
        anyhow!("{e}（SeDebugPrivilege: {debug_state}，借 SYSTEM 令牌完全依赖它）")
    };
    // SAFETY: 句柄逐步关闭，每条失败路径都显式 CloseHandle 已打开的句柄。
    unsafe {
        // 掩码必须是 PROCESS_QUERY_INFORMATION：本机实测踩坑 —— 用
        // PROCESS_QUERY_LIMITED_INFORMATION 打开 pid 4 会成功，但紧接着的
        // OpenProcessToken 一律回错误码 5（拒绝访问），看起来像"安全策略拦截"，
        // 实际是 OpenProcessToken 要求句柄带 PROCESS_QUERY_INFORMATION 权限。
        let system = match OpenProcess(PROCESS_QUERY_INFORMATION, false, 4) {
            Ok(h) => h,
            Err(e) => return Err(note(werr("OpenProcess(pid 4, PROCESS_QUERY_INFORMATION)", &e))),
        };
        let mut sys_token = HANDLE(std::ptr::null_mut());
        if let Err(e) = OpenProcessToken(system, TOKEN_DUPLICATE | TOKEN_QUERY, &mut sys_token) {
            CloseHandle(system).ok();
            return Err(note(werr("OpenProcessToken(SYSTEM)", &e)));
        }
        CloseHandle(system).ok();
        let mut impersonation = HANDLE(std::ptr::null_mut());
        if let Err(e) = DuplicateTokenEx(
            sys_token,
            TOKEN_QUERY | TOKEN_IMPERSONATE | TOKEN_DUPLICATE,
            None,
            SecurityImpersonation,
            TokenImpersonation,
            &mut impersonation,
        ) {
            CloseHandle(sys_token).ok();
            return Err(note(werr("DuplicateTokenEx(impersonation)", &e)));
        }
        CloseHandle(sys_token).ok();
        if let Err(e) = SetThreadToken(None, impersonation) {
            CloseHandle(impersonation).ok();
            return Err(note(werr("SetThreadToken(SYSTEM)", &e)));
        }
        Ok(Impersonation(impersonation))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 会话枚举必须给出非 0 的交互会话，或者明确给不出（无人登录）。
    /// 0 号是 Services 会话，注入到它等于没注入，所以绝不返回 0。
    #[test]
    fn active_user_session_never_points_at_session_zero() {
        if let Some(id) = active_user_session() {
            assert_ne!(id, 0, "交互会话不能是 0 号 Services 会话");
        }
    }

    /// 令牌获取失败必须报出可读原因 + 真实 Win32 错误码，而不是 panic 或空错误。
    /// 这条是现场判读的命门：错误码 1314 是"缺特权"，1312 才是"没人登录"。
    #[test]
    fn user_token_failure_carries_win32_code() {
        // 0x1234 不是任何真实会话
        let err = query_user_token(0x1234).unwrap_err().to_string();
        assert!(err.contains("WTSQueryUserToken"), "要点名是哪一步失败: {err}");
        assert!(err.contains("错误码"), "要带出真实 Win32 错误码: {err}");
        assert!(err.contains("0x"), "错误码要同时给十六进制，便于对照错误码表: {err}");
    }

    /// 注入到当前活动会话：能拿到会话与令牌的环境（服务态、或管理员态可借
    /// SYSTEM）必须返回可用 pid 与所走路径；否则必须返回带原因的错误而不是 panic。
    #[test]
    fn launch_into_active_session_or_explain_why_not() {
        let Some(session) = active_user_session() else {
            eprintln!("无活动用户会话，跳过");
            return;
        };
        let exe = Path::new(r"C:\Windows\System32\where.exe");
        if !exe.is_file() {
            eprintln!("无 where.exe，跳过");
            return;
        }
        match launch_in_user_session(exe, session) {
            // where.exe 不带参数会立刻退出，所以只断言 pid 有效、路径可读。
            Ok(info) => {
                assert!(info.pid > 0, "注入成功必须给出 pid");
                assert!(!info.via.is_empty(), "注入成功必须说明走了哪条权限路径");
            }
            Err(e) => {
                let text = e.to_string();
                assert!(
                    text.contains("令牌") || text.contains("CreateProcessAsUser"),
                    "失败原因要落在令牌或注入这一步: {text}"
                );
            }
        }
    }

    /// 直取失败必须**两条路都试过**再把两边的原因一起报出来 —— 之前按
    /// SeTcbPrivilege 标志跳过借 SYSTEM 那一步，现场就永远看不到真实失败点。
    #[test]
    fn failed_launch_reports_both_privilege_routes() {
        let exe = Path::new(r"C:\Windows\System32\where.exe");
        let err = launch_in_user_session(exe, 0x1234).unwrap_err().to_string();
        assert!(err.contains("直取["), "要带出 SeTcbPrivilege 直取那条路的失败原因: {err}");
        assert!(
            err.contains("借 SYSTEM 令牌") || err.contains("借SYSTEM 令牌"),
            "要说明借 SYSTEM 令牌那条路的结果（成功/失败/没借到）: {err}"
        );
    }

    /// 借 SYSTEM 令牌失败时，原因里必须点名 SeDebugPrivilege 的状态 —— 这是现场
    /// 唯一能区分"令牌里没这条特权"和"有特权但 SYSTEM 令牌 DACL 拒绝"的信息。
    #[test]
    fn impersonation_failure_names_se_debug_state() {
        match system_impersonation() {
            // 借到了：守卫出作用域自动还原线程令牌，不留残留冒充状态。
            Ok(_guard) => {}
            Err(e) => {
                let text = e.to_string();
                assert!(text.contains("SeDebugPrivilege"), "要说明特权启用状态: {text}");
                assert!(text.contains("错误码"), "要带出失败步骤与错误码: {text}");
            }
        }
    }

    /// 预检必须是"一行、二选一结论"：它进的是启动日志，不能换行也不能含糊。
    #[test]
    fn precheck_states_capability_in_one_line() {
        let line = precheck();
        assert!(!line.contains('\n'), "预检是单行日志: {line}");
        assert!(line.contains("结论="), "预检要直接给结论: {line}");
        assert!(
            line.contains("可注入交互会话") || line.contains("只能同上下文拉起"),
            "结论必须二选一，不能模棱两可: {line}"
        );
    }

    /// 特权启用是"能不能"的判定：令牌里没有这项特权时返回 false，不报错。
    #[test]
    fn enable_privilege_distinguishes_absent_from_failed() {
        let bogus_name: Vec<u16> = "SeThisPrivilegeDoesNotExist\0".encode_utf16().collect();
        // 不存在的特权名：LookupPrivilegeValueW 直接失败，调用方按"没有"处理
        assert!(enable_privilege(PCWSTR(bogus_name.as_ptr())).is_err());
        // 存在且管理员可启用的特权：结果只能是 true/false，不能是 Err
        let backup = enable_privilege(windows::Win32::Security::SE_BACKUP_NAME);
        assert!(backup.is_ok(), "启用已持有的特权不应失败: {backup:?}");
        // 钉住两个极易抄错的价值：1300="特权没启上来"（判定 Ok(false) 的唯一依据），
        // 1314="缺特权"（WTSQueryUserToken 对管理员令牌的典型返回）。差 14，抄反了
        // 就会把管理员误判成"SeTcbPrivilege 已启用"，从而跳过唯一能走通的借 SYSTEM 路。
        assert_eq!(ERROR_NOT_ALL_ASSIGNED.0, 1300);
        assert_eq!(ERROR_PRIVILEGE_NOT_HELD.0, 1314);
        assert_eq!(ERROR_NO_SUCH_LOGON_SESSION.0, 1312);
    }
}
