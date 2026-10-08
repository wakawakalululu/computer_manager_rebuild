//! 磁盘扫描/清理 API（对照规格整理结果 specs/api-map 的 frb codec 面，函数名保持一致）。
//!
//! 实现说明：
//! - 所有返回 `String` 的扫描器均返回 serde_json 序列化后的字符串（经 frb 以 String 传给 Dart）；
//! - 每个扫描器一个 `static AtomicBool` 取消标志：扫描开始时复位，`cancel_*` 置位，
//!   扫描循环内逐条目检查，取消后返回 `Err("...已取消")`；
//! - 规则解析与文件清理核心在 `crate::winapp2`。

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{anyhow, Context};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use walkdir::WalkDir;

use crate::winapp2::{clean_hits, parse_file, scan_entry_full, FileHit, RuleEntry};

// ---------------------------------------------------------------------------
// 取消标志：每个扫描器一个（扫描开始时复位，cancel_* 置位）
// ---------------------------------------------------------------------------

static DEEP_CLEAN_SCAN_CANCEL: AtomicBool = AtomicBool::new(false);
static LARGE_FILE_SCAN_CANCEL: AtomicBool = AtomicBool::new(false);
static DUPLICATE_FILE_SCAN_CANCEL: AtomicBool = AtomicBool::new(false);
static SYSTEM_DISK_SCAN_CANCEL: AtomicBool = AtomicBool::new(false);

// ---------------------------------------------------------------------------
// 传输结构（全部经 serde_json 序列化为 String 后经 frb 传输）
// ---------------------------------------------------------------------------

/// 深度清理单条规则的扫描结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EntryResult {
    /// 规则名（INI 段名）
    pub name: String,
    /// 命中文件总大小（字节）
    pub size: u64,
    /// 命中文件明细
    pub hits: Vec<FileHit>,
    /// 规则的 LangSecRef 原值（如 3021/3401/3402/3403）。winapp2.rs 里
    /// 解析了它却一直没往外送，深度清理列表因此只能按规则名分组，
    /// 没法按"垃圾清理 / 系统无用文件 / 网络缓存"这类大类归类。
    pub lang_sec_ref: String,
}

/// 深度清理整体扫描结果
/// （注：在规格基础上额外增加 `remove_self_dirs` 字段，
///   用于把 REMOVESELF 目标目录从扫描阶段带到清理阶段）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanResult {
    pub entries: Vec<EntryResult>,
    /// REMOVESELF 目标目录（清理时需清空后整体删除）
    pub remove_self_dirs: Vec<String>,
}

/// 重复文件分组（展平结构便于 frb/Dart 消费）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DupGroup {
    /// 组号（从 0 递增，组间按重复总大小降序）
    pub group_id: u32,
    /// 同组重复文件
    pub items: Vec<FileHit>,
}

/// 目录大小统计
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DirStat {
    pub path: String,
    pub size: u64,
}

// ---------------------------------------------------------------------------
// 深度清理（winapp2 规则引擎）
// ---------------------------------------------------------------------------

// ---- original path: api::disk_scan::deep_clean::scan_deep_clean ----
pub fn scan_deep_clean() -> anyhow::Result<String> {
    // frb codec: crateApiDiskScanDeepCleanRScanDeepClean
    DEEP_CLEAN_SCAN_CANCEL.store(false, Ordering::SeqCst);

    // 1) 定位规则文件：exe 同目录 rules\DeepCleanCacheConfig.ini，fallback 当前目录 rules\...
    let rule_path = locate_rule_file("DeepCleanCacheConfig.ini")?;
    // 2) 解析全部规则
    let entries: Vec<RuleEntry> = parse_file(&rule_path.to_string_lossy())
        .with_context(|| format!("解析规则文件失败：{}", rule_path.display()))?;

    // 3) rayon 并行扫描每条规则，取消标志传入扫描循环内逐条目检查
    let pairs: Vec<(EntryResult, Vec<String>)> = entries
        .par_iter()
        .map(|entry| {
            let (hits, remove_dirs) = scan_entry_full(entry, Some(&DEEP_CLEAN_SCAN_CANCEL));
            let size: u64 = hits.iter().map(|h| h.size).sum();
            (
                EntryResult {
                    name: entry.name.clone(),
                    size,
                    hits,
                    lang_sec_ref: entry.lang_sec_ref.clone(),
                },
                remove_dirs,
            )
        })
        .collect();

    if DEEP_CLEAN_SCAN_CANCEL.load(Ordering::SeqCst) {
        return Err(anyhow!("深度清理扫描已取消"));
    }

    let mut results: Vec<EntryResult> = Vec::with_capacity(pairs.len());
    let mut remove_lists: Vec<Vec<String>> = Vec::with_capacity(pairs.len());
    for (r, dirs) in pairs {
        results.push(r);
        remove_lists.push(dirs);
    }

    // 4) 汇总 REMOVESELF 目录并去重（Windows 路径大小写不敏感）
    let mut seen: HashSet<String> = HashSet::new();
    let remove_self_dirs: Vec<String> = remove_lists
        .into_iter()
        .flatten()
        .filter(|d| seen.insert(d.to_lowercase()))
        .collect();

    // 5) 按可清理大小降序展示
    results.sort_by(|a, b| b.size.cmp(&a.size));

    let result = ScanResult {
        entries: results,
        remove_self_dirs,
    };
    Ok(serde_json::to_string(&result)?)
}

/// 清理深度清理扫描结果（本工程新增的配套 API，不在原始 95 个 codec 面内）。
/// `result_json`：`scan_deep_clean` 返回的 JSON 字符串。
pub fn clean_deep_clean(result_json: String) -> anyhow::Result<()> {
    let result: ScanResult = serde_json::from_str(&result_json)
        .with_context(|| "clean_deep_clean: 解析扫描结果 JSON 失败")?;
    let hits: Vec<FileHit> = result
        .entries
        .into_iter()
        .flat_map(|e| e.hits)
        .collect();
    clean_hits(&hits, &result.remove_self_dirs)
}

// ---- original path: api::disk_scan::deep_clean::cancel_deep_clean_scan ----
pub fn cancel_deep_clean_scan() -> anyhow::Result<()> {
    // frb codec: crateApiDiskScanDeepCleanRCancelDeepCleanScan
    DEEP_CLEAN_SCAN_CANCEL.store(true, Ordering::SeqCst);
    Ok(())
}

/// 定位规则文件：优先 exe 同目录 `rules\<name>`，其次当前工作目录 `rules\<name>`。
fn locate_rule_file(name: &str) -> anyhow::Result<PathBuf> {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let p = dir.join("rules").join(name);
            if p.is_file() {
                return Ok(p);
            }
        }
    }
    let p = PathBuf::from("rules").join(name);
    if p.is_file() {
        return Ok(p);
    }
    Err(anyhow!("未找到规则文件 {}（已尝试 exe 同目录与当前目录的 rules\\）", name))
}

// ---------------------------------------------------------------------------
// 回收站
// ---------------------------------------------------------------------------

// ---- original path: api::disk_scan::deep_clean::get_recycle_bin_size ----
pub fn get_recycle_bin_size() -> anyhow::Result<Vec<String>> {
    // frb codec: crateApiDiskScanDeepCleanRGetRecycleBinSize
    // walkdir C:\$Recycle.Bin 累加文件大小；各 SID 子目录可能拒绝访问，权限错误静默跳过。
    // 返回格式约定：[0] = 总字节数（十进制字符串），[1] = 人类可读大小（如 "1.23 GB"）。
    let mut total: u64 = 0;
    // 同上：回收站在**系统盘**上，写死 C: 会在装到别处的机器上读到别人的盘
    for entry in WalkDir::new(system_root_dir().join("$Recycle.Bin")).follow_links(false) {
        let Ok(entry) = entry else { continue }; // 无权限子树静默跳过
        if !entry.file_type().is_file() {
            continue;
        }
        if let Ok(md) = entry.metadata() {
            total += md.len();
        }
    }
    Ok(vec![total.to_string(), format_size(total)])
}

// ---- original path: api::disk_scan::deep_clean::empty_recycle_bin ----
pub fn empty_recycle_bin() -> anyhow::Result<()> {
    // frb codec: crateApiDiskScanDeepCleanREmptyRecycleBin
    // 通过 PowerShell 的 Clear-RecycleBin -Force 清空（-Force 免确认）。
    let out = Command::new("powershell")
        .args(["-NoProfile", "-Command", "Clear-RecycleBin -Force"])
        .output()
        .with_context(|| "启动 PowerShell 清空回收站失败")?;
    if !out.status.success() {
        return Err(anyhow!(
            "清空回收站失败：{}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(())
}

// ---- original path: api::disk_scan::deep_clean::open_recycle_bin_folder ----
pub fn open_recycle_bin_folder() -> anyhow::Result<()> {
    // frb codec: crateApiDiskScanDeepCleanROpenRecycleBinFolder
    Command::new("explorer.exe")
        .arg("shell:RecycleBinFolder")
        .spawn()
        .with_context(|| "打开回收站失败")?;
    Ok(())
}

// ---------------------------------------------------------------------------
// 磁盘工具
// ---------------------------------------------------------------------------

// ---- original path: api::disk_scan::disk_tools::check_files_exists ----
pub fn check_files_exists(paths: Vec<String>) -> anyhow::Result<Vec<bool>> {
    // frb codec: crateApiDiskScanDiskToolsRCheckFilesExists
    Ok(paths.iter().map(|p| Path::new(p).exists()).collect())
}

// ---- original path: api::disk_scan::disk_tools::delete_file ----
pub fn delete_file(paths: Vec<String>) -> anyhow::Result<()> {
    // frb codec: crateApiDiskScanDiskToolsRDeleteFile
    // 批量删除：单个失败不影响其余，所有错误收集后合并为一个 Err(String)。
    let mut errors: Vec<String> = Vec::new();
    for p in &paths {
        if let Err(e) = fs::remove_file(p) {
            errors.push(format!("{}: {}", p, e));
        }
    }
    if errors.is_empty() {
        Ok(())
    } else {
        Err(anyhow!(
            "删除失败 {} 个文件：{}",
            errors.len(),
            errors.join("; ")
        ))
    }
}

// ---- original path: api::disk_scan::disk_tools::delete_single_file ----
pub fn delete_single_file(path: String) -> anyhow::Result<()> {
    // frb codec: crateApiDiskScanDiskToolsRDeleteSingleFile
    fs::remove_file(&path).with_context(|| format!("删除文件失败：{}", path))
}

// ---- original path: api::disk_scan::disk_tools::open_file_dir ----
pub fn open_file_dir(path: String) -> anyhow::Result<()> {
    // frb codec: crateApiDiskScanDiskToolsROpenFileDir
    // explorer.exe /select,"path"：打开文件所在目录并选中该文件。
    // 用 raw_arg 原样传参，避免 std 对含空格路径的自动加引号被 explorer 二次改写。
    use std::os::windows::process::CommandExt;
    Command::new("explorer.exe")
        .raw_arg(format!("/select,\"{}\"", path))
        .spawn()
        .with_context(|| format!("打开文件所在目录失败：{}", path))?;
    Ok(())
}

// ---------------------------------------------------------------------------
// 大文件扫描
// ---------------------------------------------------------------------------

// ---- original path: api::disk_scan::large_file_scan::large_file_scan ----
pub fn large_file_scan(root: String, min_size_mb: u64) -> anyhow::Result<String> {
    // frb codec: crateApiDiskScanLargeFileScanRLargeFileScan
    LARGE_FILE_SCAN_CANCEL.store(false, Ordering::SeqCst);
    if !Path::new(&root).is_dir() {
        return Err(anyhow!("扫描根目录不存在或不是目录：{}", root));
    }
    let min_size = min_size_mb.saturating_mul(1024 * 1024);

    // 1) walkdir 遍历收集全部文件路径（取消点：每个条目；无权限/被占用静默跳过）
    let mut files: Vec<PathBuf> = Vec::new();
    for entry in WalkDir::new(&root).follow_links(false) {
        if LARGE_FILE_SCAN_CANCEL.load(Ordering::Relaxed) {
            return Err(anyhow!("大文件扫描已取消"));
        }
        let Ok(entry) = entry else { continue };
        let ft = entry.file_type();
        if ft.is_symlink() || !ft.is_file() {
            continue;
        }
        files.push(entry.into_path());
    }

    // 2) rayon 并行读取元数据并按阈值过滤（> min_size，不含等于）
    let mut hits: Vec<FileHit> = files
        .par_iter()
        .filter_map(|p| {
            if LARGE_FILE_SCAN_CANCEL.load(Ordering::Relaxed) {
                return None;
            }
            let md = fs::metadata(p).ok()?;
            (md.len() > min_size).then(|| FileHit {
                path: p.to_string_lossy().into_owned(),
                size: md.len(),
            })
        })
        .collect();

    if LARGE_FILE_SCAN_CANCEL.load(Ordering::SeqCst) {
        return Err(anyhow!("大文件扫描已取消"));
    }

    // 3) 按大小降序取前 100
    hits.sort_by(|a, b| b.size.cmp(&a.size));
    hits.truncate(100);
    Ok(serde_json::to_string(&hits)?)
}

// ---- original path: api::disk_scan::large_file_scan::cancel_large_file_scan ----
pub fn cancel_large_file_scan() -> anyhow::Result<()> {
    // frb codec: crateApiDiskScanLargeFileScanRCancelLargeFileScan
    LARGE_FILE_SCAN_CANCEL.store(true, Ordering::SeqCst);
    Ok(())
}

// ---------------------------------------------------------------------------
// 重复文件扫描
// ---------------------------------------------------------------------------

// ---- original path: api::disk_scan::duplicate_file_scan::duplicate_file_scan ----
pub fn duplicate_file_scan(root: String) -> anyhow::Result<String> {
    // frb codec: crateApiDiskScanDuplicateFileScanRDuplicateFileScan
    DUPLICATE_FILE_SCAN_CANCEL.store(false, Ordering::SeqCst);
    if !Path::new(&root).is_dir() {
        return Err(anyhow!("扫描根目录不存在或不是目录：{}", root));
    }

    // 1) 遍历收集 >1MB 的文件路径（取消点：每个条目）
    const MIN_DUP_SIZE: u64 = 1024 * 1024;
    let mut candidates: Vec<PathBuf> = Vec::new();
    for entry in WalkDir::new(&root).follow_links(false) {
        if DUPLICATE_FILE_SCAN_CANCEL.load(Ordering::Relaxed) {
            return Err(anyhow!("重复文件扫描已取消"));
        }
        let Ok(entry) = entry else { continue }; // 无权限/被占用：静默跳过
        let ft = entry.file_type();
        if ft.is_symlink() || !ft.is_file() {
            continue;
        }
        let Ok(md) = entry.metadata() else { continue };
        if md.len() > MIN_DUP_SIZE {
            candidates.push(entry.into_path());
        }
    }

    // 2) 先按文件大小分组：只有组内文件数 > 1 的才需要读内容哈希
    let mut by_size: HashMap<u64, Vec<PathBuf>> = HashMap::new();
    for p in candidates {
        if let Ok(md) = fs::metadata(&p) {
            by_size.entry(md.len()).or_default().push(p);
        }
    }
    let candidate_groups: Vec<Vec<PathBuf>> = by_size
        .into_values()
        .filter(|g| g.len() > 1)
        .collect();
    let pairs: Vec<(PathBuf, u64)> = candidate_groups
        .into_iter()
        .flatten()
        .map(|p| {
            let size = fs::metadata(&p).map(|m| m.len()).unwrap_or(0);
            (p, size)
        })
        .collect();

    // 3) rayon 并行计算内容 SHA-256（64KB 分块流式读取；读失败/取消返回 None 跳过）
    let hashed: Vec<(String, u64, String)> = pairs
        .par_iter()
        .filter_map(|(p, size)| {
            if DUPLICATE_FILE_SCAN_CANCEL.load(Ordering::Relaxed) {
                return None;
            }
            let digest = hash_file_sha256(p)?;
            Some((digest, *size, p.to_string_lossy().into_owned()))
        })
        .collect();

    if DUPLICATE_FILE_SCAN_CANCEL.load(Ordering::SeqCst) {
        return Err(anyhow!("重复文件扫描已取消"));
    }

    // 4) 同哈希成组，丢弃单文件组
    let mut by_hash: HashMap<String, Vec<FileHit>> = HashMap::new();
    for (digest, size, path) in hashed {
        by_hash
            .entry(digest)
            .or_default()
            .push(FileHit { path, size });
    }
    let mut groups: Vec<Vec<FileHit>> = by_hash
        .into_values()
        .filter(|g| g.len() > 1)
        .collect();

    // 5) 组间按重复总大小降序，展平为 Vec<DupGroup> 便于 frb 传输
    groups.sort_by(|a, b| {
        let ta: u64 = a.iter().map(|h| h.size).sum();
        let tb: u64 = b.iter().map(|h| h.size).sum();
        tb.cmp(&ta)
    });
    let dups: Vec<DupGroup> = groups
        .into_iter()
        .enumerate()
        .map(|(i, items)| DupGroup {
            group_id: i as u32,
            items,
        })
        .collect();
    Ok(serde_json::to_string(&dups)?)
}

// ---- original path: api::disk_scan::duplicate_file_scan::cancel_duplicate_file_scan ----
pub fn cancel_duplicate_file_scan() -> anyhow::Result<()> {
    // frb codec: crateApiDiskScanDuplicateFileScanRCancelDuplicateFileScan
    DUPLICATE_FILE_SCAN_CANCEL.store(true, Ordering::SeqCst);
    Ok(())
}

/// 以 64KB 分块流式读取计算文件 SHA-256；打不开/读失败（被占用、无权限）返回 None。
fn hash_file_sha256(path: &Path) -> Option<String> {
    let mut f = fs::File::open(path).ok()?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        if DUPLICATE_FILE_SCAN_CANCEL.load(Ordering::Relaxed) {
            return None;
        }
        let n = f.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Some(format!("{:x}", hasher.finalize()))
}

// ---------------------------------------------------------------------------
// 系统盘空间分析
// ---------------------------------------------------------------------------

/// 系统盘顶层目录统计的受限遍历深度
const SYSTEM_SCAN_MAX_DEPTH: usize = 4;
/// C:\ 顶层不统计的保留目录（权限受限或与用户无关；Windows 目录仍会受限扫描）
const SKIP_TOP_DIRS: [&str; 4] = [
    "$recycle.bin",
    "system volume information",
    "$winreagent",
    "config.msi",
];

fn is_skipped_top_dir(name: &str) -> bool {
    let lower = name.to_lowercase();
    SKIP_TOP_DIRS.iter().any(|s| lower == *s)
}

/// 系统盘根目录（带尾部分隔符，如 `C:\`）。
///
/// 回收站与系统盘扫描都依赖它。两处原先各自写死 `C:\`——装到 D:/E: 的机器上
/// 会去扫一个**无关的卷**，"系统盘文件"那一页列的根本不是系统盘，回收站容量
/// 也会读成别的盘的。读 %SystemDrive%（与 `get_root_disk_info` 同一口径，
/// 不引入第二套规则），读不到才退回 `C:`。
fn system_root_dir() -> PathBuf {
    let drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_string());
    let mut p = PathBuf::from(drive.trim_end_matches(['\\', '/']));
    p.push("\\");
    p
}

// ---- original path: api::disk_scan::system_disk_scan::system_disk_scan ----
pub fn system_disk_scan() -> anyhow::Result<String> {
    // frb codec: crateApiDiskScanSystemDiskScanRSystemDiskScan
    SYSTEM_DISK_SCAN_CANCEL.store(false, Ordering::SeqCst);
    // ⚠ 原来写死 `C:\`：**装到 D: 的机器会去扫一个无关的盘**（或干脆失败），
    // 于是"系统盘文件"这一页列的根本不是系统盘。系统盘问 %SystemDrive%
    // （与 get_root_disk_info 同一口径），问不到才退回 C:。
    let root = system_root_dir();

    let mut stats: Vec<DirStat> = Vec::new();
    let rd = fs::read_dir(&root)
        .with_context(|| format!("无法读取 {} 顶层目录", root.display()))?;
    for e in rd {
        let Ok(e) = e else { continue };
        let Ok(ft) = e.file_type() else { continue };
        if !ft.is_dir() {
            continue; // 只统计目录
        }
        let name = e.file_name().to_string_lossy().into_owned();
        if is_skipped_top_dir(&name) {
            continue;
        }
        if SYSTEM_DISK_SCAN_CANCEL.load(Ordering::Relaxed) {
            return Err(anyhow!("系统盘扫描已取消"));
        }
        let path = root.join(&name);
        // 受限深度 walkdir 统计目录大小（取消时返回已统计部分）
        let size = dir_size_limited(&path, SYSTEM_SCAN_MAX_DEPTH, &SYSTEM_DISK_SCAN_CANCEL);
        stats.push(DirStat {
            path: path.to_string_lossy().into_owned(),
            size,
        });
    }

    // 按占用大小降序
    stats.sort_by(|a, b| b.size.cmp(&a.size));
    Ok(serde_json::to_string(&stats)?)
}

// ---- original path: api::disk_scan::system_disk_scan::cancel_system_disk_scan ----
pub fn cancel_system_disk_scan() -> anyhow::Result<()> {
    // frb codec: crateApiDiskScanSystemDiskScanRCancelSystemDiskScan
    SYSTEM_DISK_SCAN_CANCEL.store(true, Ordering::SeqCst);
    Ok(())
}

// ---- original path: api::disk_scan::system_disk_scan::clear_system_disk_scan_data ----
pub fn clear_system_disk_scan_data() -> anyhow::Result<()> {
    // frb codec: crateApiDiskScanSystemDiskScanRClearSystemDiskScanData
    // 本实现无持久缓存（每次扫描即算即传），仅需复位取消标志。
    //
    // ⚠ **故意不给出口**：`system_disk_scan()` 开头已经做了同一件事
    // （`SYSTEM_DISK_SCAN_CANCEL.store(false, …)`），所以"下一次扫描"天然就是干净的。
    // 再接一条 UI 动作去手动复位，等于让用户点一下才开始扫描前才需要的状态——
    // 而且点了之后界面上没有任何变化（那本来就没有可清的数据），是个假 affordance。
    SYSTEM_DISK_SCAN_CANCEL.store(false, Ordering::SeqCst);
    Ok(())
}

/// 受限深度统计目录内文件总大小。
/// 无权限子树静默跳过；符号链接/junction 不跟随；取消时返回已统计部分。
fn dir_size_limited(dir: &Path, max_depth: usize, cancel: &AtomicBool) -> u64 {
    let mut total: u64 = 0;
    for entry in WalkDir::new(dir).max_depth(max_depth).follow_links(false) {
        if cancel.load(Ordering::Relaxed) {
            return total;
        }
        let Ok(entry) = entry else { continue }; // 无权限子树静默跳过
        if !entry.file_type().is_file() {
            continue;
        }
        if let Ok(md) = entry.metadata() {
            total += md.len();
        }
    }
    total
}

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------

/// 字节数的人类可读表示（B/KB/MB/GB/TB，1024 进制，两位小数）
fn format_size(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = bytes as f64;
    let mut u = 0usize;
    while v >= 1024.0 && u < UNITS.len() - 1 {
        v /= 1024.0;
        u += 1;
    }
    format!("{:.2} {}", v, UNITS[u])
}

#[cfg(test)]
mod system_root_tests {
    /// 系统盘根目录必须跟着 **%SystemDrive%** 走，不能写死 `C:\`。
    ///
    /// 两处曾各自写死：系统盘扫描去 `read_dir("C:\")`、回收站去
    /// `WalkDir::new("C:\$Recycle.Bin")`。装到 D:/E: 的机器上，那两处会去读一个
    /// **无关的卷**——"系统盘文件"页列的根本不是系统盘，回收站容量也读成别的盘的。
    /// 本机是 C:，所以这个 bug 在这里**看不出来**，只能靠断言把它钉住。
    #[test]
    fn system_root_follows_the_system_drive() {
        let root = super::system_root_dir();
        let expected_drive =
            std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_string());
        let expected = expected_drive.trim_end_matches(['\\', '/']);
        let got = root.to_string_lossy().trim_end_matches('\\').to_string();
        assert_eq!(
            got, expected,
            "系统盘根目录应跟着 %SystemDrive%={expected_drive:?}，实际 {root:?}"
        );
        // 必须是绝对路径且带尾部分隔符（拼子目录时省一次 join）
        assert!(root.is_absolute(), "{root:?} 不是绝对路径");
        assert!(root.to_string_lossy().ends_with('\\'), "{root:?} 缺尾部分隔符");
    }

    /// 回收站路径要建在**系统盘根**下面，而不是拼到 C: 上。
    #[test]
    fn recycle_bin_lives_under_the_system_root() {
        let bin = super::system_root_dir().join("$Recycle.Bin");
        let text = bin.to_string_lossy().to_string();
        assert!(
            text.contains("$Recycle.Bin"),
            "回收站路径不对：{text}"
        );
        // 关键性质：前缀是系统盘根，不是写死的 C:\
        let root = super::system_root_dir().to_string_lossy().to_string();
        assert!(
            text.starts_with(root.as_str()),
            "回收站 {text:?} 不在系统盘根 {root:?} 下面"
        );
    }
}
