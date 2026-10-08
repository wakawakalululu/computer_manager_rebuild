//! api::gui_log —— GUI 层日志落盘（净室实现）。
//!
//! - 函数名与 frb codec 映射保持与规格整理规格一致（见 specs/api-map），函数头注释
//!   保留原 codec 名。
//! - 日志文件：exe 目录 logs\gui_log.log（创建失败时回退当前工作目录 logs\），
//!   行格式 `[LEVEL yyyy-MM-dd HH:mm:ss] msg`（本地时间）。
//! - 文件句柄以 append 模式打开一次后存入 static Mutex 复用；写失败时丢弃旧
//!   句柄重新打开并重试一次（应对目录被删等场景）。

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

use anyhow::anyhow;
use chrono::Local;

/// 日志文件名
const LOG_FILE_NAME: &str = "gui_log.log";

/// 复用的日志文件句柄（append 模式打开一次，后续追加写入）
static LOG_HANDLE: Mutex<Option<File>> = Mutex::new(None);

// ---------------------------------------------------------------------------
// frb 暴露函数
// ---------------------------------------------------------------------------

/// 追加一条 INFO 级 GUI 日志，返回已写入的行文本。
pub fn info(msg: String) -> anyhow::Result<String> {
    // frb codec: crateApiGuiLogRInfo
    append_log("INFO", &msg)
}

/// 追加一条 WARN 级 GUI 日志，返回已写入的行文本。
pub fn warn(msg: String) -> anyhow::Result<String> {
    // frb codec: crateApiGuiLogRWarn
    append_log("WARN", &msg)
}

/// 追加一条 ERROR 级 GUI 日志，返回已写入的行文本。
pub fn error(msg: String) -> anyhow::Result<String> {
    // frb codec: crateApiGuiLogRError
    append_log("ERROR", &msg)
}

// ---------------------------------------------------------------------------
// 内部实现
// ---------------------------------------------------------------------------

/// 打开日志文件：优先 exe 目录 logs\，失败回退当前工作目录 logs\。
/// 目录不存在则先创建；两个候选位置均失败时返回 io 错误。
fn open_log_file() -> std::io::Result<File> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join("logs"));
        }
    }
    // 回退：当前工作目录下 logs\
    candidates.push(PathBuf::from("logs"));
    for dir in candidates {
        if fs::create_dir_all(&dir).is_err() {
            continue;
        }
        if let Ok(file) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(dir.join(LOG_FILE_NAME))
        {
            return Ok(file);
        }
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::PermissionDenied,
        "创建日志文件失败（exe 目录与当前目录均不可用）",
    ))
}

/// 写入一行（含换行）；句柄未打开时先打开。
fn write_line(handle: &mut Option<File>, line: &str) -> std::io::Result<()> {
    if handle.is_none() {
        *handle = Some(open_log_file()?);
    }
    let file = handle.as_mut().expect("日志句柄应已打开");
    file.write_all(line.as_bytes())?;
    file.write_all(b"\n")?;
    file.flush()
}

/// 按 `[LEVEL yyyy-MM-dd HH:mm:ss] msg` 格式追加日志。
fn append_log(level: &str, msg: &str) -> anyhow::Result<String> {
    let line = format!(
        "[{} {}] {}",
        level,
        Local::now().format("%Y-%m-%d %H:%M:%S"),
        msg
    );
    let mut guard = LOG_HANDLE
        .lock()
        .map_err(|_| anyhow!("gui_log 句柄锁中毒"))?;
    if write_line(&mut guard, &line).is_err() {
        // 旧句柄失效（如日志目录被删除）：丢弃后重新打开并重试一次
        *guard = None;
        write_line(&mut guard, &line)?;
    }
    Ok(line)
}

// ---------------------------------------------------------------------------
// 把 `log` crate 的输出接到同一个文件
// ---------------------------------------------------------------------------

/// 实现 `log::Log`，让 Rust 侧的 `log::info!/warn!/error!` 落到 `gui_log.log`。
///
/// 为什么需要：库里有一批 `log::info!(...)` 调用（utils / sysinfo / simple 共 10 处），
/// 但**本项目从未调用过 `log::set_logger`**。`log` crate 在没有 logger 时会把每条
/// 记录直接丢掉（只留一行 stderr 提示），于是那些诊断信息**一个字都没有落盘**——
/// 而 `logs\` 目录恰恰是靠 `gui_log` 自己创建的，所以现象是"目录可能都没有"。
///
/// 这里不引第三方 logger（`fern` / `tracing`）：为转发 10 行文本不值得多一个依赖，
/// 直接复用已有的 [append_log] 即可，两边落到同一个文件、同一种行格式。
pub struct GuiFileLogger;

impl log::Log for GuiFileLogger {
    fn enabled(&self, _metadata: &log::Metadata) -> bool {
        true
    }

    fn log(&self, record: &log::Record) {
        let level = match record.level() {
            log::Level::Error => "ERROR",
            log::Level::Warn => "WARN",
            log::Level::Info => "INFO",
            log::Level::Debug => "DEBUG",
            log::Level::Trace => "TRACE",
        };
        // 写失败只能丢：此刻正在打日志，再报错就是递归
        let _ = append_log(level, &record.args().to_string());
    }

    fn flush(&self) {}
}

/// 把 `log` crate 全局指向 [GuiFileLogger]。
///
/// **只能调一次**：第二次 `set_logger` 返回 `Err`（全局 logger 已被占用），
/// 那种情况下忽略即可——上一次的安装仍然有效。
/// 写日志失败**不抛**：启动期打一条日志失败就整个起不来，比不打更糟。
pub fn init_log_bridge() {
    if log::set_logger(&LOGGER).is_ok() {
        log::set_max_level(log::LevelFilter::Info);
    }
}

static LOGGER: GuiFileLogger = GuiFileLogger;

#[cfg(test)]
mod log_bridge_tests {
    /// `log::info!` 必须在装上桥之后**真的落到文件里**。
    ///
    /// 这条钉的是"引了 log crate 却没装 logger，记录全被静默丢掉"——断言不能只看
    /// 装上了，要看**文件里多出了那一行**。日志目录由 append_log 自己挑
    /// （exe 目录优先，失败回退当前工作目录），所以这里读回来的是 exe 旁的那个文件。
    #[test]
    fn log_macro_actually_reaches_the_file() {
        super::init_log_bridge();
        let marker = format!("cm_log_bridge_probe_{}", std::process::id());

        // 先确认桥真的把记录接住了（不是"装上了但没生效"）
        log::info!("{marker}");
        log::logger().flush();

        // append_log 的落盘位置：exe 目录 logs\，失败回退 CWD logs\。
        let exe_logs = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.join("logs").join(super::LOG_FILE_NAME)));
        let cwd_logs = std::env::current_dir()
            .ok()
            .map(|d| d.join("logs").join(super::LOG_FILE_NAME));
        let hit = [exe_logs, cwd_logs]
            .into_iter()
            .flatten()
            .any(|p| std::fs::read_to_string(&p).map(|t| t.contains(&marker)).unwrap_or(false));
        assert!(hit, "装上 log 桥之后，{marker} 仍未出现在任何候选日志文件里");
    }
}

#[cfg(test)]
mod port_log_tests {
    use super::*;

    fn current_log_file() -> std::path::PathBuf {
        let mut cands: Vec<std::path::PathBuf> = Vec::new();
        if let Ok(exe) = std::env::current_exe() {
            if let Some(dir) = exe.parent() {
                cands.push(dir.join("logs").join(LOG_FILE_NAME));
            }
        }
        cands.push(std::path::PathBuf::from("logs").join(LOG_FILE_NAME));
        for c in &cands {
            if c.exists() {
                return c.clone();
            }
        }
        cands.into_iter().next().expect("至少有一条候选路径")
    }

    /// 「端口表落进了日志文件」这件事只能在这里钉住：Dart 侧拿不到 Rust 用的那个路径，
    /// 而 `collect_log` 的暂存目录用完就删。更要紧的是桥没装上时 `log::info!` 会
    /// **静默丢掉每一条**——那时 `log_process_port_usage` 的返回值照样非空、界面照样
    /// 看着正常，只有文件是空的（这一族本项目真中过一次）。
    #[test]
    fn port_usage_lines_reach_the_log_file() {
        let _ = init_log_bridge();
        let path = current_log_file();
        let before = std::fs::read_to_string(&path).unwrap_or_default();
        let lines = crate::api::sysinfo::log_process_port_usage()
            .expect("netstat -ano 应能执行");
        let after = std::fs::read_to_string(&path)
            .expect("写入端口表后日志文件应存在");
        assert!(!lines.is_empty(), "本机端口表不该一个字都没有");
        assert!(after.len() > before.len(), "端口表应让日志文件变长");
        assert!(after.contains("[port-usage]"), "日志里应有 [port-usage] 行");
    }
}
