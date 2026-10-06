//! api::utils —— 进程级工具函数（净室实现）。
//!
//! - 函数名与 frb codec 映射保持与规格整理规格一致（见 specs/api-map），每个函数头
//!   注释保留原 codec 名（如 `crateApiUtilsRCreateMutex`）。
//! - 桩阶段的占位返回类型（`Vec<String>`）按实际语义改为 `String` / `()`，并补充
//!   了必要参数；集成期需重新运行 flutter_rust_bridge_codegen 生成 Dart 侧镜像。
//! - 所有路径基准均为“当前 exe 所在目录”（与参考实现行为一致），而非工作目录。

use std::fs::{self, File};
use std::path::PathBuf;
use std::process::Command;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, SystemTime};

use anyhow::{anyhow, Context};
use uuid::Uuid;
use winreg::enums::HKEY_LOCAL_MACHINE;
use winreg::RegKey;
use windows::core::w;
use windows::Win32::Foundation::{GetLastError, BOOL, ERROR_ALREADY_EXISTS};
use windows::Win32::System::Threading::CreateMutexW;

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/// 单实例互斥体名（Global 命名空间，全机范围内可见）。
/// 注意：w! 宏只接受字面量，故 CreateMutexW 处的字面量与本常量需保持一致。
const MUTEX_NAME: &str = "Global\\cm_rebuild_mutex";

/// 注册表 MachineGuid 所在键路径（HKLM）
const MACHINE_GUID_KEY_PATH: &str = r"SOFTWARE\Microsoft\Cryptography";
/// 注册表 MachineGuid 值名
const MACHINE_GUID_VALUE: &str = "MachineGuid";

/// 注册表不可用时的 machine_id 缓存文件名（位于 exe 目录）
const MACHINE_ID_CACHE_FILE: &str = "machine_id";

/// 环境变量键名（约定）：开发模式开关
/// TODO(假设)：参考实现真实键名规格整理未确认，这里统一约定为 IS_DEV
const IS_DEV_ENV_KEY: &str = "IS_DEV";

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

/// 当前 exe 所在目录（多数函数的路径基准）
fn app_dir() -> anyhow::Result<PathBuf> {
    let exe = std::env::current_exe().context("获取当前进程 exe 路径失败")?;
    exe.parent()
        .map(|dir| dir.to_path_buf())
        .ok_or_else(|| anyhow!("exe 路径无父目录: {}", exe.display()))
}

// ---------------------------------------------------------------------------
// 通知消息队列（Rust → Dart）
// ---------------------------------------------------------------------------

/// Rust 侧待通知消息队列；Dart 通过 get_rust_notify_msg 轮询取走
static NOTIFY_QUEUE: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// 向 UI 通知队列追加一条消息（非 frb 接口，供本 crate 其它模块调用）。
/// TODO(集成期)：sysinfo / disk_scan 等模块尚未接入推送，接入后无需再改本函数。
pub fn push_notify(msg: String) {
    if let Ok(mut queue) = NOTIFY_QUEUE.lock() {
        queue.push(msg);
    }
}

// ---------------------------------------------------------------------------
// frb 暴露函数
// ---------------------------------------------------------------------------

/// 读取机器唯一标识：
/// 1) 首选注册表 HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid（与参考实现一致）；
/// 2) 注册表失败则回退 exe 目录 `machine_id` 缓存文件；
/// 3) 缓存不存在则生成 uuid v4 写入缓存并返回，保证后续运行稳定。
pub fn get_machine_id() -> anyhow::Result<String> {
    // frb codec: crateApiUtilsRGetMachineId
    if let Ok(hklm) = RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey(MACHINE_GUID_KEY_PATH) {
        if let Ok(guid) = hklm.get_value::<String, _>(MACHINE_GUID_VALUE) {
            let guid = guid.trim().to_string();
            if !guid.is_empty() {
                return Ok(guid);
            }
        }
    }
    // 注册表读取失败：尝试 exe 目录缓存文件
    let cache = app_dir()?.join(MACHINE_ID_CACHE_FILE);
    if let Ok(existing) = fs::read_to_string(&cache) {
        let existing = existing.trim().to_string();
        if !existing.is_empty() {
            return Ok(existing);
        }
    }
    // 首次生成 uuid v4 并落盘
    let id = Uuid::new_v4().to_string();
    fs::write(&cache, &id)
        .with_context(|| format!("写入 machine_id 缓存失败: {}", cache.display()))?;
    Ok(id)
}

/// 获取应用当前目录（当前 exe 所在目录），字符串形式返回。
pub fn get_app_current_dir() -> anyhow::Result<String> {
    // frb codec: crateApiUtilsRGetAppCurrentDir
    Ok(app_dir()?.to_string_lossy().into_owned())
}

/// 创建单实例互斥体：已存在同名实例时直接退出进程（参考实现防多开行为）。
///
/// windows 0.58 的 `CreateMutexW` 仅在句柄无效（真正创建失败）时返回 `Err`；
/// “互斥体已存在”时仍返回 `Ok(有效句柄)`，因此成功后需立即读取 GetLastError 判定。
pub fn create_mutex() -> anyhow::Result<()> {
    // frb codec: crateApiUtilsRCreateMutex
    let _mutex_handle = unsafe { CreateMutexW(None, BOOL(0), w!("Global\\cm_rebuild_mutex")) }
        .with_context(|| format!("创建单实例互斥体失败: {}", MUTEX_NAME))?;
    // HANDLE 为 Copy 类型且不调用 CloseHandle：句柄随进程生命周期持有，
    // 互斥体因此保持被占用状态，直到进程退出由系统回收。
    if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
        log::info!("检测到已有实例运行（{}），进程退出", MUTEX_NAME);
        std::process::exit(0);
    }
    Ok(())
}

/// 设置进程环境变量。
pub fn set_env(key: String, value: String) -> anyhow::Result<()> {
    // frb codec: crateApiUtilsRSetEnv
    std::env::set_var(&key, &value);
    Ok(())
}

/// 设置开发模式开关（写入环境变量 IS_DEV，"true"/"false"）。
pub fn set_is_dev(is_dev: bool) -> anyhow::Result<()> {
    // frb codec: crateApiUtilsRSetIsDev
    std::env::set_var(IS_DEV_ENV_KEY, if is_dev { "true" } else { "false" });
    Ok(())
}

/// 取走（drain）全部待通知消息并以换行拼接返回；无消息时返回空字符串。
pub fn get_rust_notify_msg() -> anyhow::Result<String> {
    // frb codec: crateApiUtilsRGetRustNotifyMsg
    let mut queue = NOTIFY_QUEUE
        .lock()
        .map_err(|_| anyhow!("通知队列互斥锁中毒"))?;
    let msgs: Vec<String> = queue.drain(..).collect();
    Ok(msgs.join("\n"))
}

/// 启动主进程数据采集。
///
/// 说明：真实的系统数据采集（CPU/内存/进程等）由常驻 agent 进程（cm_agent bin）
/// 负责；GUI 侧此调用仅保留一个低频心跳线程占位，不阻塞 UI 线程。
pub fn main_collect() -> anyhow::Result<()> {
    // frb codec: crateApiUtilsRMainCollect
    thread::Builder::new()
        .name("cm_main_collect".to_string())
        .spawn(|| {
            loop {
                // TODO(集成期)：接入 agent 采集任务后替换为真实周期采集逻辑
                log::info!("collect tick");
                thread::sleep(Duration::from_secs(60));
            }
        })
        .context("启动采集心跳线程失败")?;
    Ok(())
}

/// 后端初始化：确保 exe 目录下 logs\ 存在，并输出初始化标记日志。
pub fn rust_backend_init() -> anyhow::Result<()> {
    // frb codec: crateApiUtilsRRustBackendInit
    let dir = app_dir()?;
    let logs = dir.join("logs");
    fs::create_dir_all(&logs)
        .with_context(|| format!("创建日志目录失败: {}", logs.display()))?;
    log::info!("rust_backend_init 完成（exe 目录: {}）", dir.display());
    Ok(())
}

/// 后端清理：删除 exe 目录 temp\ 下修改时间超过 24 小时的文件。
pub fn rust_backend_clean() -> anyhow::Result<()> {
    // frb codec: crateApiUtilsRRustBackendClean
    let temp = app_dir()?.join("temp");
    if !temp.is_dir() {
        return Ok(()); // 无临时目录视为无事可做
    }
    let cutoff = SystemTime::now() - Duration::from_secs(24 * 60 * 60);
    let mut removed = 0usize;
    for entry in fs::read_dir(&temp)? {
        let entry = match entry {
            Ok(e) => e,
            // 单个条目读取失败不阻断整体清理
            Err(_) => continue,
        };
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let expired = fs::metadata(&path)
            .and_then(|meta| meta.modified())
            .map(|modified| modified < cutoff)
            .unwrap_or(false);
        if expired && fs::remove_file(&path).is_ok() {
            removed += 1;
        }
    }
    log::info!(
        "rust_backend_clean 清理临时文件 {} 个（{}）",
        removed,
        temp.display()
    );
    Ok(())
}

/// 重启应用：拉起当前 exe 后立即退出当前进程（正常路径不会返回）。
pub fn restart_application2() -> anyhow::Result<()> {
    // frb codec: crateApiUtilsRRestartApplication2
    let exe = std::env::current_exe().context("获取当前 exe 路径失败")?;
    Command::new(&exe)
        .spawn()
        .with_context(|| format!("重新启动自身失败: {}", exe.display()))?;
    log::info!("应用即将重启: {}", exe.display());
    std::process::exit(0);
}

/// 创建指定大小的空白临时文件（按 mtime/大小占位用）。
///
/// 注意：函数名沿用原工程拼写（tmep / whit），刻意保留以保证 codec 对齐。
pub fn create_tmep_empty_file_whit_size(path: String, size: u64) -> anyhow::Result<()> {
    // frb codec: crateApiUtilsRCreateTmepEmptyFileWhitSize
    let file = File::create(&path).with_context(|| format!("创建临时文件失败: {}", path))?;
    file.set_len(size)
        .with_context(|| format!("设置临时文件长度失败: {} ({} 字节)", path, size))?;
    Ok(())
}
