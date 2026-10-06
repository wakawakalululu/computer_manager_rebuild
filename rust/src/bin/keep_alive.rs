//! cm_keep_alive —— Windows 服务守护（独立实现原
//! `cloud_computer_manager_keep_alive.exe`；本工程服务名 `CmKeepAlive`，
//! 不复用原厂商服务名 `ComputerKeepAlive`，理由见 SERVICE_NAME 注释）。
//!
//! 行为规格来源：specs/arch-notes §2：原服务为 C++ 实现
//! （Process32First 枚举进程 + CreateProcessAsUser 拉起），守护对象：
//! - `cloud_computer_manager_agent.exe`（30s 任务轮询常驻进程）
//! - `PC Manager.exe`（GUI 主进程）
//!
//! 实现形态下被守护对象换成本工程产物名 `cm_agent.exe` / `computer_manager.exe`
//!（见 DEFAULT_WATCH_LIST），行为模型一致。
//!
//! CLI：
//! - （无参数）   服务模式：`service_dispatcher` 分派给 SCM（服务名 CmKeepAlive）
//! - `--install`  调 `sc create` 注册服务（binPath= 带引号写法，开机自启）
//! - `--uninstall` 调 `sc stop` + `sc delete` 移除服务
//! - `--run`      前台 watchdog 调试，Ctrl+C 优雅退出
//!
//! 依赖约束（Cargo.toml 已锁定、不可修改）：tokio 未启用 `signal` feature，
//! 前台模式的 Ctrl+C 同样经 `kernel32!SetConsoleCtrlHandler` 实现（语义等价）。

use std::collections::HashSet;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context};
use chrono::Local;
use sysinfo::{ProcessesToUpdate, System};
use windows_service::service::{
    ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
    ServiceType,
};
use windows_service::service_control_handler::{
    self, ServiceControlHandlerResult, ServiceStatusHandle,
};
use windows_service::{define_windows_service, service_dispatcher};

/// 交互会话注入（原服务用 CreateProcessAsUser 把被守护进程拉进登录用户的桌面会话）
///
/// 显式 `#[path]`：bin 的模块根目录是 `src/bin/`，而 cargo 会把 `src/bin/*.rs`
/// 自动当成 bin 目标，所以模块文件放在 `src/bin/keep_alive/` 子目录里。
#[path = "keep_alive/session.rs"]
mod session;

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/// 服务名：本工程自带 `CmKeepAlive`。
/// 参考实现服务名是 `ComputerKeepAlive`（规格整理规格记录，见 REVERSE_REPORT §2），
/// 但实现不能沿用同名：本机实测存在厂商已安装的 `ComputerKeepAlive` 且状态 RUNNING，
/// 同名会让 GUI 的守护判定误以为“服务已在守护实现 agent”而永久让位，
/// 也让 `--install` 与厂商服务抢名字（sc create 直接 1073 冲突）。
const SERVICE_NAME: &str = "CmKeepAlive";
const SERVICE_DISPLAY_NAME: &str = "CmKeepAlive Service";
/// watchdog 检查周期（秒）
const WATCH_INTERVAL_SECS: u64 = 10;
/// 缺省守护对象（REVERSE_REPORT §2 的模型：agent 常驻进程 + GUI 主进程）。
/// 取本工程实现产物的 exe 名；原厂商程序名仅作为规格整理规格记录在模块头注释与
/// REVERSE_REPORT 中，不进入运行配置（独立实现，见 README 合规节）。
/// 需要守护其它进程时用 keep_alive.ini 的 `watch=名1,名2` 覆盖。
const DEFAULT_WATCH_LIST: &[&str] = &["cm_agent.exe", "computer_manager.exe"];
/// 配置文件（exe 同目录，`watch=名1,名2` 可覆盖缺省守护对象）
const KEEP_ALIVE_INI: &str = "keep_alive.ini";
const LOG_DIR: &str = "logs";
const LOG_FILE: &str = "cm_keep_alive.log";

/// CREATE_NEW_PROCESS_GROUP (0x200)：被守护子进程脱离本服务的进程组，
/// 服务停止 / Ctrl+C 时控制台事件不会连带传递给被守护进程。
const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
/// CREATE_NO_WINDOW (0x08000000)：无窗口启动，前台 --run 调试时不闪黑框。
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

// ---------------------------------------------------------------------------
// 控制台事件（Ctrl+C 等，仅前台 --run 模式生效）
// ---------------------------------------------------------------------------

/// 前台调试模式的退出标志
static SHUTDOWN: AtomicBool = AtomicBool::new(false);

const CTRL_C_EVENT: u32 = 0;
const CTRL_BREAK_EVENT: u32 = 1;
const CTRL_CLOSE_EVENT: u32 = 2;
const CTRL_LOGOFF_EVENT: u32 = 5;
const CTRL_SHUTDOWN_EVENT: u32 = 6;

extern "system" fn console_ctrl_handler(ctrl_type: u32) -> i32 {
    match ctrl_type {
        CTRL_C_EVENT | CTRL_BREAK_EVENT | CTRL_CLOSE_EVENT | CTRL_LOGOFF_EVENT
        | CTRL_SHUTDOWN_EVENT => {
            SHUTDOWN.store(true, Ordering::SeqCst);
            1 // TRUE：交给主循环优雅退出
        }
        _ => 0,
    }
}

#[link(name = "kernel32")]
extern "system" {
    fn SetConsoleCtrlHandler(
        handler: Option<unsafe extern "system" fn(u32) -> i32>,
        add: i32,
    ) -> i32;
}

fn install_console_handler() {
    unsafe {
        SetConsoleCtrlHandler(Some(console_ctrl_handler), 1);
    }
}

// ---------------------------------------------------------------------------
// 基础设施：exe 目录 / 日志
// ---------------------------------------------------------------------------

static LOG_PATH: OnceLock<PathBuf> = OnceLock::new();

/// 当前 exe 所在目录（服务进程工作目录是 System32，必须以 exe 目录为基准）
fn app_dir() -> anyhow::Result<PathBuf> {
    let exe = std::env::current_exe().context("获取当前进程 exe 路径失败")?;
    exe.parent()
        .map(|dir| dir.to_path_buf())
        .ok_or_else(|| anyhow!("exe 路径无父目录: {}", exe.display()))
}

fn init_log(exe_dir: &Path) {
    let logs_dir = exe_dir.join(LOG_DIR);
    let _ = fs::create_dir_all(&logs_dir);
    let _ = LOG_PATH.set(logs_dir.join(LOG_FILE));
}

/// 追加写日志：`[INFO yyyy-MM-dd HH:mm:ss] ...`，同时镜像到 stdout。
fn write_log(level: &str, msg: &str) {
    let ts = Local::now().format("%Y-%m-%d %H:%M:%S");
    println!("[{level} {ts}] {msg}");
    if let Some(path) = LOG_PATH.get() {
        if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "[{level} {ts}] {msg}");
        }
    }
}

// ---------------------------------------------------------------------------
// watchdog
// ---------------------------------------------------------------------------

/// 读取 exe 同目录 keep_alive.ini 的守护对象覆盖：`watch=名1,名2`。
/// 宽松解析（忽略节名与 `;`/`#` 注释行）；文件缺失或无有效配置时用缺省列表。
fn load_watch_list(exe_dir: &Path) -> Vec<String> {
    let default: Vec<String> = DEFAULT_WATCH_LIST.iter().map(|s| (*s).to_string()).collect();
    let text = match fs::read_to_string(exe_dir.join(KEEP_ALIVE_INI)) {
        Ok(t) => t,
        Err(_) => return default,
    };
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with(';') || line.starts_with('#')
            || line.starts_with('[')
        {
            continue;
        }
        if let Some(eq) = line.find('=') {
            if line[..eq].trim().eq_ignore_ascii_case("watch") {
                let list: Vec<String> = line[eq + 1..]
                    .split(',')
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect();
                if !list.is_empty() {
                    return list;
                }
            }
        }
    }
    default
}

/// 单轮巡检：缺失的守护进程从 exe 同目录拉起，返回本轮拉起数量。
fn ensure_processes(sys: &mut System, watch_list: &[String], exe_dir: &Path) -> usize {
    // sysinfo 0.32：全量刷新进程表并移除已退出进程
    sys.refresh_processes(ProcessesToUpdate::All, true);
    let running: HashSet<String> = sys
        .processes()
        .values()
        .map(|p| p.name().to_string_lossy().to_lowercase())
        .collect();
    let mut spawned = 0usize;
    for name in watch_list {
        let lower = name.to_lowercase();
        // Windows 进程名不区分大小写；兼容 sysinfo 返回名带/不带 .exe 后缀两种形态
        let alive =
            running.contains(&lower) || running.contains(&format!("{lower}.exe"));
        if alive {
            continue;
        }
        let target = exe_dir.join(name);
        if !target.is_file() {
            write_log(
                "WARN",
                &format!("进程缺失且目标文件不存在，无法拉起: {}", target.display()),
            );
            continue;
        }
        // CREATE_NEW_PROCESS_GROUP：子进程脱离本服务的进程组，服务停止时
        //   控制台事件不连带传递给被守护进程；
        // CREATE_NO_WINDOW：无窗口启动，前台 --run 调试时不闪黑框。
        match launch_guarded(&target) {
            // Child 句柄立即释放：子进程独立存活，由后续巡检继续守护
            Ok(describe) => {
                spawned += 1;
                write_log("INFO", &format!("检测到进程缺失，已拉起: {name} {describe}"));
            }
            Err(e) => write_log("ERROR", &format!("拉起 {name} 失败: {e}")),
        }
    }
    spawned
}

/// 拉起一个被守护进程，返回"pid / 会话 / 方式"这串现场可读的描述。
///
/// 先按原服务模型注入活动用户会话（服务在会话 0，直接 spawn 出去的进程没有桌面，
/// 悬浮窗与托盘根本画不出来）；注入失败只降级为同上下文 spawn 并写明原因，
/// 守护不能因为注入这一步失败就彻底不拉进程。
fn launch_guarded(target: &Path) -> anyhow::Result<String> {
    match session::active_user_session() {
        Some(sid) => match session::launch_in_user_session(target, sid) {
            Ok(info) => return Ok(format!(
                "pid={} 会话={sid} 方式=CreateProcessAsUser({}) 环境块={}",
                info.pid,
                info.via,
                if info.env_block { "用户块" } else { "调用方块（CreateEnvironmentBlock 失败）" }
            )),
            Err(e) => write_log("WARN", &format!("交互会话注入未成功，回落同上下文拉起: {e}")),
        },
        None => write_log("WARN", "无活动用户会话（无人登录），回落同上下文拉起"),
    }
    Command::new(target)
        .creation_flags(CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW)
        .spawn()
        .map(|child| format!("pid={} 会话=同上下文 方式=Command::spawn", child.id()))
        .context("同上下文拉起也失败")
}

/// watchdog 主循环：每 WATCH_INTERVAL_SECS 巡检一次，stop_flag 置位后退出。
fn watchdog_loop(stop_flag: &AtomicBool, exe_dir: &Path) {
    let watch_list = load_watch_list(exe_dir);
    write_log(
        "INFO",
        &format!(
            "watchdog 启动：周期 {}s，守护对象 [{}]",
            WATCH_INTERVAL_SECS,
            watch_list.join(", ")
        ),
    );
    let mut sys = System::new();
    // 启动即报告注入能力：管理员手动 --run 时"同上下文拉起"是身份所限，不是故障，
    // 这一行让现场第一眼就能分清。
    write_log("INFO", &format!("注入能力预检：{}", session::precheck()));
    loop {
        if stop_flag.load(Ordering::SeqCst) {
            break;
        }
        let spawned = ensure_processes(&mut sys, &watch_list, exe_dir);
        write_log(
            "INFO",
            &format!(
                "watchdog 巡检：{} 个守护对象，本轮拉起 {} 个",
                watch_list.len(),
                spawned
            ),
        );
        // 分片睡眠（250ms 一档）：秒级响应停止信号，避免长 sleep 拖慢 SCM 停机
        let deadline = Instant::now() + Duration::from_secs(WATCH_INTERVAL_SECS);
        while Instant::now() < deadline {
            if stop_flag.load(Ordering::SeqCst) {
                break;
            }
            thread::sleep(Duration::from_millis(250));
        }
    }
}

// ---------------------------------------------------------------------------
// Windows 服务模式
// ---------------------------------------------------------------------------

define_windows_service!(ffi_service_main, service_main);

fn service_main(_arguments: Vec<OsString>) {
    if let Err(e) = run_service() {
        write_log("ERROR", &format!("服务运行异常退出: {e:#}"));
    }
}

fn run_service() -> anyhow::Result<()> {
    let exe_dir = app_dir()?;
    init_log(&exe_dir);
    write_log("INFO", "ComputerKeepAlive 服务入口（SCM 分派）");

    let stop_flag = Arc::new(AtomicBool::new(false));
    let event_handler = {
        let flag = Arc::clone(&stop_flag);
        move |control: ServiceControl| -> ServiceControlHandlerResult {
            match control {
                // SCM 询问当前状态：回应无错误，状态由 set_service_status 维护
                ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
                // 停止 / 预关机 / 关机：置位停止标志，watchdog 在 ≤250ms 内退出
                ServiceControl::Stop | ServiceControl::Preshutdown
                | ServiceControl::Shutdown => {
                    flag.store(true, Ordering::SeqCst);
                    ServiceControlHandlerResult::NoError
                }
                _ => ServiceControlHandlerResult::NotImplemented,
            }
        }
    };
    // windows-service 0.7：register 需显式传服务名
    let status_handle = service_control_handler::register(SERVICE_NAME, event_handler)
        .map_err(|e| anyhow!("注册服务控制处理器失败: {e}"))?;

    report_status(&status_handle, ServiceState::StartPending, ServiceControlAccept::empty())?;
    report_status(
        &status_handle,
        ServiceState::Running,
        ServiceControlAccept::STOP | ServiceControlAccept::PRESHUTDOWN,
    )?;

    watchdog_loop(&stop_flag, &exe_dir);

    report_status(&status_handle, ServiceState::StopPending, ServiceControlAccept::empty())?;
    report_status(&status_handle, ServiceState::Stopped, ServiceControlAccept::empty())?;
    write_log("INFO", "ComputerKeepAlive 服务已停止");
    Ok(())
}

/// 上报服务状态（OWN_PROCESS / exit 0 / wait_hint 10s）
fn report_status(
    handle: &ServiceStatusHandle,
    state: ServiceState,
    accepted: ServiceControlAccept,
) -> anyhow::Result<()> {
    handle
        .set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: state,
            controls_accepted: accepted,
            exit_code: ServiceExitCode::Win32(0),
            checkpoint: 0,
            wait_hint: Duration::from_secs(10),
            process_id: None,
        })
        .map_err(|e| anyhow!("上报服务状态 {state:?} 失败: {e}"))
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

fn print_usage() {
    eprintln!("用法: cm_keep_alive [--install | --uninstall | --run]");
    eprintln!("  无参数服务模式（由服务管理器启动）");
    eprintln!("  --install    注册服务（sc create，开机自启）");
    eprintln!("  --uninstall  移除服务（sc stop + sc delete）");
    eprintln!("  --run        前台 watchdog 调试（Ctrl+C 退出）");
}

/// 无参数：服务模式。SCM 启动后阻塞直至服务停止；
/// 非 SCM 启动（双击/命令行直接运行）时 start 返回 Err。
fn run_as_service() -> anyhow::Result<()> {
    if let Err(e) = service_dispatcher::start(SERVICE_NAME, ffi_service_main) {
        if let Ok(dir) = app_dir() {
            init_log(&dir);
            write_log(
                "ERROR",
                &format!(
                    "service_dispatcher::start 失败: {e}（应由服务管理器启动；手动调试请用 --run）"
                ),
            );
        }
        return Err(anyhow!(
            "服务分派失败: {e}（应由服务管理器启动；手动调试请用 --run）"
        ));
    }
    Ok(())
}

fn cmd_install() -> anyhow::Result<()> {
    let exe_dir = app_dir()?;
    init_log(&exe_dir);
    let exe = std::env::current_exe().context("获取当前 exe 路径失败")?;
    // sc.exe 命令行约定：`binPath=`（等号后必须留空格）后跟值，因此
    // "binPath=" 与路径作为两个独立参数传递；值整体加英文引号，
    // 保证路径含空格时 SCM 启动不会截断 ImagePath。
    let binpath = format!("\"{}\"", exe.display());
    let args = [
        "create",
        SERVICE_NAME,
        "binPath=",
        binpath.as_str(),
        "start=",
        "auto",
        "DisplayName=",
        SERVICE_DISPLAY_NAME,
    ];
    sc_run(&args)?;
    write_log(
        "INFO",
        &format!("服务 {SERVICE_NAME} 注册成功（开机自启）: {}", exe.display()),
    );
    Ok(())
}

fn cmd_uninstall() -> anyhow::Result<()> {
    let exe_dir = app_dir()?;
    init_log(&exe_dir);
    // 运行中的服务无法直接删除（只能标记删除），先尽力停止，失败不阻断
    let _ = sc_run(&["stop", SERVICE_NAME]);
    sc_run(&["delete", SERVICE_NAME])?;
    write_log(
        "INFO",
        &format!("服务 {SERVICE_NAME} 已移除（如仍在运行，将在停止后删除）"),
    );
    Ok(())
}

fn cmd_run_foreground() -> anyhow::Result<()> {
    let exe_dir = app_dir()?;
    init_log(&exe_dir);
    write_log("INFO", "前台 watchdog 调试模式（Ctrl+C 优雅退出）");
    install_console_handler();
    watchdog_loop(&SHUTDOWN, &exe_dir);
    write_log("INFO", "前台模式已退出");
    Ok(())
}

/// 执行 sc.exe 子命令并落日志；非零退出码视为失败。
fn sc_run(args: &[&str]) -> anyhow::Result<()> {
    let out = Command::new("sc.exe")
        .args(args)
        // 隐藏 sc.exe 的控制台窗口（GUI/服务上下文运行时不应弹窗）
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .context("启动 sc.exe 失败（确认系统 PATH 中存在 sc.exe）")?;
    let code = out.status.code().unwrap_or(-1);
    let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
    let detail = if stdout.is_empty() { &stderr } else { &stdout };
    write_log(
        "INFO",
        &format!("sc {} → exit={} {}", args.join(" "), code, detail),
    );
    if !out.status.success() {
        bail!("sc {} 失败（exit={code}）: {detail}", args.join(" "));
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        None => run_as_service(),
        Some("--install") => cmd_install(),
        Some("--uninstall") => cmd_uninstall(),
        Some("--run") => cmd_run_foreground(),
        Some("--help") | Some("-h") | Some("/?") => {
            print_usage();
            Ok(())
        }
        Some(other) => {
            eprintln!("未知参数: {other}");
            print_usage();
            Err(anyhow!("未知参数: {other}"))
        }
    };
    if let Err(e) = result {
        eprintln!("执行失败: {e:#}");
        std::process::exit(1);
    }
}
