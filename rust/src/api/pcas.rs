//! api::pcas —— PCAS 认证客户端拉起（净室实现）。
//!
//! 原路径：api::pcas::client_api_tool（PCAS =  Application Auth 认证组件）。
//! 函数名与 frb codec 映射保持与规格整理规格一致（见 specs/api-map）。

use std::path::Path;
use std::process::Command;

use anyhow::Context;

/// PCAS 认证客户端安装路径
const PCAS_CLIENT_PATH: &str = r"C:\Program Files\\AppAuth\ Application Auth.exe";
/// 客户端缺失时的兜底跳转地址
/// TODO(占位)：参考实现真实跳转 URL 规格整理未确认，先以 139 云盘官网占位
const PCAS_FALLBACK_URL: &str = "https://cloud.139.com";

// ---- original path: api::pcas::client_api_tool ----
/// 拉起 PCAS 认证客户端：
/// - 客户端已安装（路径存在）→ 直接 spawn 该 exe；
/// - 未安装 → 经 explorer.exe 打开默认浏览器访问兜底链接（占位行为）。
pub fn open_pcas_client() -> anyhow::Result<()> {
    // frb codec: crateApiPcasClientApiToolROpenPcasClient
    if Path::new(PCAS_CLIENT_PATH).is_file() {
        Command::new(PCAS_CLIENT_PATH)
            .spawn()
            .with_context(|| format!("启动 PCAS 客户端失败: {}", PCAS_CLIENT_PATH))?;
    } else {
        // 占位实现：客户端缺失时经资源管理器打开默认浏览器
        Command::new("explorer.exe")
            .arg(PCAS_FALLBACK_URL)
            .spawn()
            .context("通过 explorer 打开兜底链接失败")?;
    }
    Ok(())
}
