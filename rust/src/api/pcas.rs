//! api::pcas —— PCAS 认证客户端拉起（净室实现）。
//!
//! 原路径：api::pcas::client_api_tool（PCAS =  Application Auth 认证组件）。
//! 函数名与 frb codec 映射保持与规格整理规格一致（见 specs/api-map）。

use std::path::PathBuf;
use std::process::Command;

use anyhow::Context;

/// PCAS 认证客户端的文件名（目录部分由 %ProgramFiles% 决定，见 [pcas_client_path]）。
///
/// 注意这里**不能**写成 raw string 再手写 `\\`：raw string 里的 `\\` 是两个
/// 真实反斜杠，拼出来的路径永远不存在，`is_file()` 恒为 false，于是每次都走
/// 兜底分支、客户端永远拉不起来。普通字符串里 `\\` 才表示一个反斜杠。
const PCAS_CLIENT_FILE: &str = "AppAuth\\ Application Auth.exe";

/// PCAS 认证客户端的完整安装路径。
///
/// 目录取 **%ProgramFiles%** 而不是写死 `C:\\Program Files`——装到别的盘时
/// "程序文件"就在那个盘上，写死 C: 会让 `is_file()` 恒 false，
/// 于是**永远**走兜底浏览器分支、客户端明明装了却拉不起来。
/// 读不到 %ProgramFiles% 才退回 `C:\\Program Files`（与别处同一口径）。
fn pcas_client_path() -> PathBuf {
    let base = std::env::var("ProgramFiles")
        .unwrap_or_else(|_| r"C:\Program Files".to_string());
    PathBuf::from(base).join(PCAS_CLIENT_FILE)
}
// 这里原来有一个"客户端缺失时打开官网兜底"的常量 PCAS_FALLBACK_URL，
// 值是自己填的占位网址，上面还挂着 TODO(占位)。它已经**连同那条分支一起删掉**了：
// 拉起失败时替用户打开一个猜出来的第三方站点，是把猜测当产品行为，
// 而且这条路径在界面上完全不可见（用户只看到浏览器被叫起来）。
// 现在未安装就是"未安装"，由界面如实说，见 pcas_client_installed。

// ---- original path: api::pcas::client_api_tool ----
/// 拉起 PCAS 认证客户端的结果：告诉调用方到底是哪条路走通了。
///
/// 原来两条分支都返回 `Ok(())`，调用方无从分辨——客户端没装时它悄悄开了浏览器，
/// 界面上却像"客户端已启动"。这里把事实带回去。
#[derive(serde::Serialize, serde::Deserialize)]
pub struct PcasLaunchOutcome {
    /// true = 真的拉起了客户端；false = 客户端不存在，走了兜底链接
    pub client_started: bool,
    /// 走兜底分支时为 true，提示文案别自称"已启动客户端"
    pub fell_back_to_url: bool,
}

/// 认证客户端在默认安装位置下是否存在。
///
/// 单独给一个探测口，是为了让**界面**能在拉起之前就说出"未安装"，
/// 而不是等拉起失败再猜——原来的写法在客户端不存在时会去开一个
/// **我们自己占位的网址**（那条分支已删除，理由见文件里那段注释），
/// 那等于用一个猜来的行为冒充产品行为。
pub fn pcas_client_installed() -> bool {
    // frb codec: crateApiPcasClientApiToolRIsInstalled
    pcas_client_path().is_file()
}

/// 拉起 PCAS 认证客户端。
///
/// **只有客户端存在时才做事**；不存在就返回"什么都没起"，
/// 不再打开兜底网址（那条分支连同 `PCAS_FALLBACK_URL` 一起停用，理由见上）。
/// 调用方应先问 [pcas_client_installed]，这里的返回值只用来如实报告结果。
pub fn open_pcas_client() -> anyhow::Result<PcasLaunchOutcome> {
    // frb codec: crateApiPcasClientApiToolROpenPcasClient
    if pcas_client_path().is_file() {
        Command::new(pcas_client_path())
            .spawn()
            .with_context(|| format!("启动 PCAS 客户端失败: {}", pcas_client_path().display()))?;
        Ok(PcasLaunchOutcome {
            client_started: true,
            fell_back_to_url: false,
        })
    } else {
        Ok(PcasLaunchOutcome {
            client_started: false,
            fell_back_to_url: false,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_path_has_no_doubled_separators() {
        // 这条曾经写成 raw string 又手写 `\`，拼出来的路径永远不存在，
        // is_file() 恒 false，客户端永远拉不起来、每次都掉进兜底分支。
        let p = pcas_client_path();
        let text = p.to_string_lossy().to_string();
        assert!(text.contains("AppAuth"));
        assert!(
            !text.contains("\\\\"),
            "路径里出现了连续两个反斜杠：{text}"
        );
        // 也不能带尾随空白
        assert_eq!(text.trim(), text);
        assert!(p.is_absolute(), "{text} 不是绝对路径");
    }

    /// 目录必须跟着 **%ProgramFiles%** 走，不能写死 `C:\Program Files`。
    ///
    /// 装到别的盘时"程序文件"在那个盘上；写死 C: 会让 `is_file()` 恒 false，
    /// 于是**明明装了客户端却永远走兜底浏览器分支**，而且界面上看不出异常。
    /// 本机是 C:，所以只能断言"等于 %ProgramFiles%"这个**关系**。
    #[test]
    fn client_dir_follows_program_files() {
        let expected =
            std::env::var("ProgramFiles").unwrap_or_else(|_| r"C:\Program Files".to_string());
        let text = pcas_client_path().to_string_lossy().to_string();
        assert!(
            text.starts_with(&expected),
            "客户端路径应位于 %ProgramFiles%={expected:?} 之下，实际 {text}"
        );
    }
}
