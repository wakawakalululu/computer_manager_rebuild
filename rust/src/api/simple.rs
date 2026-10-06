//! api::simple —— 应用初始化入口（净室实现）。
//!
//! 函数名与 frb codec 映射保持与规格整理规格一致（见 specs/api-map），
//! 函数头注释保留原 codec 名。

use std::fs;
use std::path::PathBuf;

use anyhow::Context;

/// 应用初始化：确保日志目录（exe 目录 logs\，失败回退当前工作目录 logs\）
/// 存在，并记录初始化完成标记。返回 `Ok(())`。
pub fn init_app() -> anyhow::Result<()> {
    // frb codec: crateApiSimpleInitApp
    // 与 gui_log 模块保持同一目录选择策略：exe 目录优先，回退当前工作目录
    let logs_dir = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.join("logs")))
        .unwrap_or_else(|| PathBuf::from("logs"));
    fs::create_dir_all(&logs_dir)
        .with_context(|| format!("创建日志目录失败: {}", logs_dir.display()))?;
    log::info!(
        "init_app 完成：应用初始化成功（日志目录: {}）",
        logs_dir.display()
    );
    Ok(())
}
