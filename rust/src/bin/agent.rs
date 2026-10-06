//! cm_agent —— 常驻采集 Agent（独立实现原 `cloud_computer_manager_agent.exe`）。
//!
//! 行为规格来源：specs/arch-notes §2（进程模型）/ §4（后端接口）：
//! - 由 ComputerKeepAlive 服务守护拉起，常驻后台；
//! - 每 30s POST `{baseHost}/api/cm/log-collect/task/pull` 拉取采集任务，
//!   请求体 `{"machine_id": <mid>}`，请求头 `mid` 携带 machine_id；
//! - 响应包格式 `{"error": null, "data": {"list": [...]}}`；
//! - 收到任务后把 exe 同目录 `logs\` 打包为 zip 输出到 `%TEMP%`，
//!   再以 multipart POST `{baseHost}/report/upload/feedfile` 上传；
//! - 日志追加写 exe 同目录 `logs\cm_agent.log`，格式 `[INFO yyyy-MM-dd HH:mm:ss] ...`。
//!
//! 依赖约束：tokio 未启用 `signal` feature，因此 Ctrl+C 优雅退出改为直接绑定
//! `kernel32!SetConsoleCtrlHandler`（语义等价），而非 `tokio::signal::ctrl_c`；
//! reqwest 启用了 `multipart` feature 用于采集包上传。

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context};
use chrono::Local;
use reqwest::multipart;
use serde_json::{json, Value};
use uuid::Uuid;
use winreg::enums::HKEY_LOCAL_MACHINE;
use winreg::RegKey;

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/// 任务轮询周期（秒）——与参考实现一致：30s（REVERSE_REPORT §2）
const POLL_INTERVAL_SECS: u64 = 30;
/// 单次 HTTP 请求超时（秒）
const HTTP_TIMEOUT_SECS: u64 = 30;
/// 任务拉取接口路径（REVERSE_REPORT §4，请求头 `mid` 携带 machine_id）
const TASK_PULL_PATH: &str = "/api/cm/log-collect/task/pull";
/// 采集包上传接口路径（REVERSE_REPORT §4 / specs/routes_ui.txt）
const UPLOAD_PATH: &str = "/report/upload/feedfile";
/// 日志目录名 / agent 日志文件名
const LOG_DIR: &str = "logs";
const LOG_FILE: &str = "cm_agent.log";
/// 配置文件（exe 同目录，[config] 节：env / baseHost / channel / autoUpgrade）
const CONFIG_FILE: &str = "config.ini";
/// 注册表 MachineGuid 位置（machine_id 首选来源，与参考实现一致）
const MACHINE_GUID_KEY: &str = r"SOFTWARE\Microsoft\Cryptography";
const MACHINE_GUID_VALUE: &str = "MachineGuid";
/// 注册表不可用时的 machine_id 落盘文件（exe 同目录）
const AGENT_ID_FILE: &str = "agent_id";

// ---------------------------------------------------------------------------
// 控制台事件（Ctrl+C 等）→ 优雅退出
// ---------------------------------------------------------------------------

/// 退出标志：控制台事件置位，主循环 ≤250ms 内感知并优雅退出
static SHUTDOWN: AtomicBool = AtomicBool::new(false);

const CTRL_C_EVENT: u32 = 0;
const CTRL_BREAK_EVENT: u32 = 1;
const CTRL_CLOSE_EVENT: u32 = 2;
const CTRL_LOGOFF_EVENT: u32 = 5;
const CTRL_SHUTDOWN_EVENT: u32 = 6;

/// 控制台事件回调：置位退出标志并返回 TRUE 拦截默认的立即终止。
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

/// 当前 exe 所在目录（与参考实现一致：所有路径基准为 exe 目录而非工作目录）
fn app_dir() -> anyhow::Result<PathBuf> {
    let exe = std::env::current_exe().context("获取当前进程 exe 路径失败")?;
    exe.parent()
        .map(|dir| dir.to_path_buf())
        .ok_or_else(|| anyhow!("exe 路径无父目录: {}", exe.display()))
}

/// 初始化日志：确保 exe 目录 logs\ 存在并登记日志文件路径
fn init_log(exe_dir: &Path) {
    let logs_dir = exe_dir.join(LOG_DIR);
    let _ = fs::create_dir_all(&logs_dir);
    let _ = LOG_PATH.set(logs_dir.join(LOG_FILE));
}

/// 追加写日志：`[INFO yyyy-MM-dd HH:mm:ss] ...`，同时镜像到 stdout 便于前台调试。
fn write_log(level: &str, msg: &str) {
    let ts = Local::now().format("%Y-%m-%d %H:%M:%S");
    println!("[{level} {ts}] {msg}");
    if let Some(path) = LOG_PATH.get() {
        if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "[{level} {ts}] {msg}");
        }
    }
}

fn truncate(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        s.to_string()
    } else {
        let head: String = s.chars().take(max_chars).collect();
        format!("{head}...")
    }
}

fn format_value(v: Option<&Value>) -> String {
    v.map(|x| x.to_string())
        .unwrap_or_else(|| "null".to_string())
}

// ---------------------------------------------------------------------------
// config.ini（[config] 节）手写简易解析
// ---------------------------------------------------------------------------

/// 手写简易 INI 解析：仅满足 config.ini 的读取需求。
/// 支持 `[section]`、`key=value`、`;`/`#` 行注释、等号两侧空白、
/// 值两侧成对英文引号剥离；不支持转义与跨行。文件缺失/不可读返回空表。
fn read_ini(path: &Path) -> HashMap<String, HashMap<String, String>> {
    let mut sections: HashMap<String, HashMap<String, String>> = HashMap::new();
    let text = match fs::read_to_string(path) {
        Ok(t) => t,
        Err(_) => return sections,
    };
    let mut current = String::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with(';') || line.starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix('[').and_then(|r| r.strip_suffix(']')) {
            current = rest.trim().to_string();
            sections.entry(current.clone()).or_default();
            continue;
        }
        if let Some(eq) = line.find('=') {
            let key = line[..eq].trim().to_string();
            let mut val = line[eq + 1..].trim().to_string();
            if val.len() >= 2
                && ((val.starts_with('"') && val.ends_with('"'))
                    || (val.starts_with('\'') && val.ends_with('\'')))
            {
                val = val[1..val.len() - 1].to_string();
            }
            if !key.is_empty() {
                sections.entry(current.clone()).or_default().insert(key, val);
            }
        }
    }
    sections
}

fn ini_get(
    ini: &HashMap<String, HashMap<String, String>>,
    section: &str,
    key: &str,
) -> Option<String> {
    ini.get(section).and_then(|m| m.get(key)).cloned()
}

struct AgentConfig {
    env: String,
    base_host: String,
    channel: String,
    auto_upgrade: bool,
}

/// 读取 exe 同目录 config.ini 的 [config] 节。
/// 缺省 baseHost 为占位符：真实后端地址通过 config.ini 的 baseHost 注入，
/// 不在仓库中硬编码任何网关域名（合规要求，见 README 合规节）。
fn load_config(exe_dir: &Path) -> AgentConfig {
    let path = exe_dir.join(CONFIG_FILE);
    let ini = read_ini(&path);
    if ini.is_empty() {
        write_log(
            "WARN",
            &format!("config.ini 未读取到内容（{}），使用默认配置", path.display()),
        );
    }
    let get = |key: &str| -> String { ini_get(&ini, "config", key).unwrap_or_default() };

    let base_host = {
        let raw = get("baseHost");
        if raw.trim().is_empty() {
            "https://your-backend-gateway.example.com".to_string()
        } else {
            raw.trim().to_string()
        }
    };
    let env = {
        let e = get("env");
        if e.trim().is_empty() {
            "prod".to_string()
        } else {
            e.trim().to_string()
        }
    };
    let channel = get("channel").trim().to_string();
    let auto_upgrade = matches!(
        get("autoUpgrade").trim().to_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    );
    AgentConfig {
        env,
        base_host,
        channel,
        auto_upgrade,
    }
}

// ---------------------------------------------------------------------------
// machine_id
// ---------------------------------------------------------------------------

/// machine_id 三级来源（与参考实现一致 + 规格约定）：
/// 1) HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid；
/// 2) exe 同目录 `agent_id` 缓存文件；
/// 3) 生成 uuid v4 写入 `agent_id` 持久化，保证后续运行稳定。
fn load_machine_id(exe_dir: &Path) -> String {
    if let Ok(hklm) = RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey(MACHINE_GUID_KEY) {
        if let Ok(guid) = hklm.get_value::<String, _>(MACHINE_GUID_VALUE) {
            let guid = guid.trim().to_string();
            if !guid.is_empty() {
                return guid;
            }
        }
    }
    let cache = exe_dir.join(AGENT_ID_FILE);
    if let Ok(existing) = fs::read_to_string(&cache) {
        let existing = existing.trim().to_string();
        if !existing.is_empty() {
            return existing;
        }
    }
    let id = Uuid::new_v4().to_string();
    if let Err(e) = fs::write(&cache, &id) {
        write_log("ERROR", &format!("写入 {AGENT_ID_FILE} 缓存失败: {e}"));
    }
    id
}

// ---------------------------------------------------------------------------
// 任务轮询与日志打包
// ---------------------------------------------------------------------------

/// 单次任务轮询：POST /api/cm/log-collect/task/pull，容错解析并处理任务。
async fn poll_once(client: &reqwest::Client, cfg: &AgentConfig, mid: &str, exe_dir: &Path) {
    let url = format!("{}{}", cfg.base_host.trim_end_matches('/'), TASK_PULL_PATH);
    write_log("INFO", &format!("轮询任务: POST {url}"));

    let resp = match client
        .post(&url)
        // 请求头 mid 携带 machine_id（REVERSE_REPORT §4）
        .header("mid", mid)
        .json(&json!({ "machine_id": mid }))
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => {
            write_log("ERROR", &format!("请求失败: {e}"));
            return;
        }
    };

    let status = resp.status();
    let body = match resp.text().await {
        Ok(t) => t,
        Err(e) => {
            write_log("ERROR", &format!("读取响应失败: HTTP {status}, {e}"));
            return;
        }
    };
    if !status.is_success() {
        write_log("ERROR", &format!("HTTP {status}: {}", truncate(&body, 200)));
        return;
    }

    // 容错解析 {"error": null, "data": {"list": [...]}}
    let parsed: Value = match serde_json::from_str(&body) {
        Ok(v) => v,
        Err(e) => {
            write_log("ERROR", &format!("响应非合法 JSON: {e}"));
            return;
        }
    };
    if parsed.get("error").map(|e| !e.is_null()).unwrap_or(false) {
        write_log(
            "WARN",
            &format!(
                "服务端返回 error: {}",
                truncate(&format_value(parsed.get("error")), 200)
            ),
        );
        return;
    }
    let list = parsed
        .pointer("/data/list")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    if list.is_empty() {
        write_log("INFO", "本次轮询无待处理任务");
        return;
    }
    write_log("INFO", &format!("收到 {} 个采集任务", list.len()));
    for task in &list {
        let tid = task_id_label(task);
        match pack_logs_zip(exe_dir) {
            Ok(Some(zip_path)) => {
                write_log(
                    "INFO",
                    &format!("任务[{tid}] 日志已打包: {}", zip_path.display()),
                );
                match upload_collect_pack(client, cfg, mid, &zip_path).await {
                    Ok(desc) => {
                        write_log("INFO", &format!("任务[{tid}] 上传成功: {desc}"))
                    }
                    Err(e) => {
                        write_log("ERROR", &format!("任务[{tid}] 上传失败: {e:#}"))
                    }
                }
            }
            Ok(None) => {
                write_log(
                    "INFO",
                    &format!("任务[{tid}] logs 目录为空或不存在，跳过打包"),
                );
            }
            Err(e) => {
                write_log("ERROR", &format!("任务[{tid}] 打包失败: {e:#}"));
            }
        }
    }
}

/// 上传采集包：POST `{baseHost}/report/upload/feedfile`，multipart 携带 zip 文件，
/// 请求头 `mid` 与拉任务一致（REVERSE_REPORT §4）。
/// TODO(假设)：规格清单只给出接口路径（specs/routes_ui.txt），
/// multipart 字段名按接口名推断为 `feedfile`；真实字段名待联调确认。
/// 另外参考实现应有“任务完成回执”，但接口清单里没有独立回执路径，
/// 故此处只把响应 `data`（一般是服务端存储路径）记入日志，不虚构回执接口。
async fn upload_collect_pack(
    client: &reqwest::Client,
    cfg: &AgentConfig,
    mid: &str,
    zip_path: &Path,
) -> anyhow::Result<String> {
    let url = format!("{}{}", cfg.base_host.trim_end_matches('/'), UPLOAD_PATH);
    let bytes = fs::read(zip_path)
        .with_context(|| format!("读取采集包失败: {}", zip_path.display()))?;
    let file_name = zip_path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "cm_collect.zip".to_string());

    let form = multipart::Form::new().part(
        "feedfile",
        multipart::Part::bytes(bytes)
            .file_name(file_name.clone())
            .mime_str("application/zip")
            .context("构造 multipart 部件失败")?,
    );
    write_log("INFO", &format!("上传采集包: POST {url} file={file_name}"));

    let resp = client
        .post(&url)
        .header("mid", mid)
        .multipart(form)
        .send()
        .await
        .context("上传请求发送失败")?;
    let status = resp.status();
    let body = resp.text().await.context("读取上传响应失败")?;
    if !status.is_success() {
        return Err(anyhow!("HTTP {status}: {}", truncate(&body, 200)));
    }
    let parsed: Value =
        serde_json::from_str(&body).map_err(|e| anyhow!("上传响应非合法 JSON: {e}"))?;
    if let Some(err) = parsed.get("error").filter(|e| !e.is_null()) {
        return Err(anyhow!("服务端拒绝: {}", truncate(&err.to_string(), 200)));
    }
    Ok(truncate(&format_value(parsed.get("data")), 200))
}

/// 尽量从任务对象里取出一个可读标识（任务字段规格整理未确认，逐个候选尝试）。
fn task_id_label(task: &Value) -> String {
    for key in ["id", "taskId", "task_id", "name", "type"] {
        if let Some(v) = task.get(key) {
            if let Some(s) = v.as_str() {
                return s.to_string();
            }
            if let Some(n) = v.as_i64() {
                return n.to_string();
            }
        }
    }
    "?".to_string()
}

/// 把 exe 同目录 logs\ 递归打包为 zip，输出 `%TEMP%\cm_collect_<unix_ts>.zip`。
/// logs 目录不存在或无文件时返回 `Ok(None)`。
fn pack_logs_zip(exe_dir: &Path) -> anyhow::Result<Option<PathBuf>> {
    let logs_dir = exe_dir.join(LOG_DIR);
    if !logs_dir.is_dir() {
        return Ok(None);
    }
    let mut files: Vec<PathBuf> = Vec::new();
    for entry in walkdir::WalkDir::new(&logs_dir) {
        match entry {
            Ok(e) if e.file_type().is_file() => files.push(e.into_path()),
            // 单个条目遍历失败（权限等）不阻断整体
            _ => {}
        }
    }
    if files.is_empty() {
        return Ok(None);
    }
    files.sort();

    let zip_path = unique_zip_path(Local::now().timestamp());
    let out = File::create(&zip_path)
        .with_context(|| format!("创建压缩包失败: {}", zip_path.display()))?;
    let mut writer = zip::ZipWriter::new(out);
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    for f in &files {
        // zip 条目用相对路径且以 '/' 分隔（zip 规范），形如 logs/xxx.log
        let rel = f.strip_prefix(exe_dir).unwrap_or(f.as_path());
        let entry_name = rel.to_string_lossy().replace('\\', "/");
        writer
            .start_file(entry_name.as_str(), options)
            .with_context(|| format!("写入 zip 条目失败: {entry_name}"))?;
        let data = fs::read(f).with_context(|| format!("读取日志文件失败: {}", f.display()))?;
        writer
            .write_all(&data)
            .with_context(|| format!("写入 zip 数据失败: {entry_name}"))?;
    }
    writer
        .finish()
        .with_context(|| format!("收尾压缩包失败: {}", zip_path.display()))?;
    Ok(Some(zip_path))
}

/// `%TEMP%\cm_collect_<unix_ts>.zip`；同一秒内多个任务时追加序号避免互相覆盖。
fn unique_zip_path(unix_ts: i64) -> PathBuf {
    let tmp = std::env::temp_dir();
    let first = tmp.join(format!("cm_collect_{unix_ts}.zip"));
    if !first.exists() {
        return first;
    }
    for n in 1..u32::MAX {
        let p = tmp.join(format!("cm_collect_{unix_ts}_{n}.zip"));
        if !p.exists() {
            return p;
        }
    }
    // 兜底（理论不可达）：直接用 uuid
    tmp.join(format!("cm_collect_{unix_ts}_{}.zip", Uuid::new_v4()))
}

// ---------------------------------------------------------------------------
// 主循环
// ---------------------------------------------------------------------------

/// 可中断等待：total_secs 内每 250ms 检查一次退出标志
/// （等效 select! + ctrl_c，但不依赖 tokio 未启用的 "signal" feature）。
async fn wait_interruptible(total_secs: u64) {
    let deadline = Instant::now() + Duration::from_secs(total_secs);
    while Instant::now() < deadline {
        if SHUTDOWN.load(Ordering::SeqCst) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

async fn run() -> i32 {
    let exe_dir = match app_dir() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("定位 exe 目录失败: {e:#}");
            return 1;
        }
    };
    init_log(&exe_dir);
    install_console_handler();
    write_log(
        "INFO",
        "cm_agent 启动（独立实现 cloud_computer_manager_agent.exe）",
    );

    let cfg = load_config(&exe_dir);
    write_log(
        "INFO",
        &format!(
            "config.ini: env={} baseHost={} channel={} autoUpgrade={}",
            cfg.env, cfg.base_host, cfg.channel, cfg.auto_upgrade
        ),
    );
    // TODO(集成期)：env / channel 目前仅记录未参与逻辑（参考实现用于区分
    // prod/test/dev 网关与上报渠道）；autoUpgrade=1 时应触达镜像自升级流程
    //（对应 rust_lib api::sysinfo::upgrade_image / 镜像下载安装）。

    let mid = load_machine_id(&exe_dir);
    write_log("INFO", &format!("machine_id = {mid}"));

    let client = match reqwest::Client::builder()
        .user_agent(concat!("cm-agent/", env!("CARGO_PKG_VERSION")))
        .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            write_log("ERROR", &format!("构建 HTTP 客户端失败: {e}"));
            return 1;
        }
    };

    write_log(
        "INFO",
        &format!(
            "开始轮询：每 {}s POST {}{}",
            POLL_INTERVAL_SECS,
            cfg.base_host.trim_end_matches('/'),
            TASK_PULL_PATH
        ),
    );
    loop {
        if SHUTDOWN.load(Ordering::SeqCst) {
            break;
        }
        // 启动后立即执行首轮，之后每 POLL_INTERVAL_SECS 一次（参考实现节奏）
        poll_once(&client, &cfg, &mid, &exe_dir).await;
        wait_interruptible(POLL_INTERVAL_SECS).await;
    }
    write_log("INFO", "cm_agent 收到退出信号，优雅退出");
    0
}

#[tokio::main]
async fn main() {
    let code = run().await;
    std::process::exit(code);
}
