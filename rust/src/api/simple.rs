//! api::simple —— 应用初始化入口（净室实现）。
//!
//! 函数名与 frb codec 映射保持与规格整理规格一致（见 specs/api-map），
//! 函数头注释保留原 codec 名。

use std::fs;
use std::path::PathBuf;

use anyhow::Context;

/// 应用初始化：确保日志目录（exe 目录 logs\，失败回退当前工作目录 logs\）
/// 存在，并记录初始化完成标记。返回 `Ok(())`。
///
/// ⚠ **功能上与 `utils::rust_backend_init` 完全重复**（同一个目录、同一套回退策略），
/// 后者已经在启动路径上被调用（`RustApi.initBackendDirs`）。所以这里**故意不给出口**：
/// 再接一次只会做两遍同样的 `create_dir_all`，而这个版本有个更差的地方——
/// `current_exe()` 失败时**静默回退到相对路径 `logs`**（当前工作目录）。
/// 程序可能是被服务用不同工作目录拉起来的，那时日志会落到一个没人找得到的地方，
/// 而 `rust_backend_init` 至少会把"建目录失败"这件事报出来。
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
