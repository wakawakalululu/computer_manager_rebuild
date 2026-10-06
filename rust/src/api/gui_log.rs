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
