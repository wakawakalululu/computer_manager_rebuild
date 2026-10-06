//! winapp2.ini 格式清理规则解析与执行引擎（净室自研实现）。
//!
//! 支持的规则格式子集（参考公开的 winapp2/CCleaner 规则格式自行实现，未使用任何第三方代码）：
//! - 一个 INI 段（section）即一条清理规则，键值对描述清理目标；
//! - `FileKeyN=目录|模式串|RECURSE|REMOVESELF`：
//!   * 目录可含环境变量（%WinDir% 等）与通配符（`*` / `?`，可出现在任意路径组件，含最后一段）；
//!   * 模式串为 `;` 分隔的文件名通配符列表，如 `*.log;*.tmp`；
//!   * `RECURSE`    → 递归扫描子目录（否则只扫目标目录一层）；
//!   * `REMOVESELF` → 清理时先清空目录内容，再把目录本身一起删除；
//!   * `N` 仅为编号且同一键名可重复出现（同一键多行必须累加，不能覆盖）；
//! - `Detect` / `DetectFile` / `ExcludeKeyN`：已解析保存到结构体，但执行阶段忽略
//!   （TODO：后续支持注册表/文件条件探测与命中排除，见 parse_str 内注释）。
//!
//! 全部函数对无权限 / 被占用的文件与目录采取“静默跳过 + 日志”策略，尽力而为。

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use serde::{Deserialize, Serialize};
use walkdir::WalkDir;

/// 递归扫描的最大深度（walkdir 的 max_depth，不含目标目录本身这一层）
const MAX_WALK_DEPTH: usize = 8;
/// 单个通配路径组件展开后的目录数上限（防止病态规则把内存撑爆）
const MAX_EXPANDED_DIRS: usize = 4096;
/// 单条规则命中的文件数上限（防止超巨型目录拖垮前端；超出部分本次不处理，见 TODO）
const MAX_HITS_PER_ENTRY: usize = 50_000;

// ---------------------------------------------------------------------------
// 数据结构
// ---------------------------------------------------------------------------

/// 单条 `FileKeyN` 的解析结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileTarget {
    /// 目标目录（未展开环境变量的原始值，形如 `%LocalAppData%/Packages/Microsoft.Windows.SecHealthUI_*/AC`）
    pub dir: String,
    /// 文件名通配符模式列表（原格式中以 `;` 分隔，解析时已拆分）
    pub patterns: Vec<String>,
    /// 是否递归子目录（RECURSE）
    pub recurse: bool,
    /// 清理时连目录一起删除（REMOVESELF）
    pub remove_self: bool,
}

/// 一个 INI 段 = 一条清理规则
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleEntry {
    /// 段名，如 "Windows更新文件"、"Windows Update *"
    pub name: String,
    /// Description 键的值
    pub description: String,
    /// LangSecRef 原值（如 3021=应用程序 / 3401=Windows / 3402=应用 / 3403=浏览器），透传给前端做分类
    pub lang_sec_ref: String,
    /// 全部 FileKeyN 目标（同一键名多行累加）
    pub targets: Vec<FileTarget>,
    /// Detect=（注册表探测条件）——已解析但执行时忽略，留待后续支持
    #[serde(skip)]
    pub detect: Vec<String>,
    /// DetectFile=（文件探测条件）——已解析但执行时忽略，留待后续支持
    #[serde(skip)]
    pub detect_file: Vec<String>,
    /// ExcludeKeyN=（排除项）——已解析但执行时忽略，留待后续支持
    #[serde(skip)]
    pub exclude_keys: Vec<String>,
    /// 其他未知键（IconUrl 等），仅保留原始 `key=value` 字符串以便排查
    #[serde(skip)]
    pub extra_keys: Vec<String>,
}

/// 扫描命中的单个文件
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileHit {
    /// 文件绝对路径
    pub path: String,
    /// 文件大小（字节）
    pub size: u64,
}

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

/// 从 INI 文件解析全部清理规则；无 FileKey 目标的段会被丢弃。
pub fn parse_file(path: &str) -> anyhow::Result<Vec<RuleEntry>> {
    // 以字节读取后做有损 UTF-8 转换：规则文件可能带 BOM 或含非 UTF-8 字节，不应直接失败
    let raw = fs::read(path)?;
    let mut text = String::from_utf8_lossy(&raw).into_owned();
    if text.starts_with('\u{feff}') {
        text.remove(0); // 去 UTF-8 BOM
    }
    Ok(parse_str(&text))
}

/// 解析 INI 文本。行为约定：
/// - `#` / `;` 开头的行是注释；
/// - `[段名]` 开启一条新规则；
/// - `Key=Value` 归属最近的段，段外的键值行直接忽略；
/// - FileKeyN 同键多行累加（真实规则文件里存在 FileKey44 出现 6 次的情况）。
fn parse_str(text: &str) -> Vec<RuleEntry> {
    let mut entries: Vec<RuleEntry> = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue; // 空行 / 注释
        }
        if line.starts_with('[') && line.ends_with(']') {
            entries.push(RuleEntry {
                name: line[1..line.len() - 1].trim().to_string(),
                description: String::new(),
                lang_sec_ref: String::new(),
                targets: Vec::new(),
                detect: Vec::new(),
                detect_file: Vec::new(),
                exclude_keys: Vec::new(),
                extra_keys: Vec::new(),
            });
            continue;
        }
        let Some((key, val)) = line.split_once('=') else {
            continue; // 不是 key=value 的行，忽略
        };
        let key = key.trim();
        let val = val.trim();
        // 段外的键值行没有归属，忽略
        let Some(cur) = entries.last_mut() else { continue };
        match key.to_ascii_lowercase().as_str() {
            "description" => cur.description = val.to_string(),
            "langsecref" => cur.lang_sec_ref = val.to_string(),
            k if k.starts_with("filekey") => {
                if let Some(t) = parse_file_key(val) {
                    cur.targets.push(t);
                }
            }
            // ---- 以下键解析保存但执行时忽略（TODO：实现条件探测与排除） ----
            k if k.starts_with("excludekey") => cur.exclude_keys.push(val.to_string()),
            "detect" => cur.detect.push(val.to_string()),
            "detectfile" => cur.detect_file.push(val.to_string()),
            // 未知键（IconUrl、Default、Warning 等）只留档不执行
            _ => cur.extra_keys.push(format!("{}={}", key, val)),
        }
    }
    // 没有任何 FileKey 的段没有可执行目标，丢弃
    entries.retain(|e| !e.targets.is_empty());
    entries
}

/// 解析 `目录|模式串|RECURSE|REMOVESELF` 的值部分。
/// 目录与模式串必填；标志段可缺省，未知标志忽略。
fn parse_file_key(val: &str) -> Option<FileTarget> {
    let mut parts = val.split('|');
    let dir = parts.next()?.trim().to_string();
    if dir.is_empty() {
        return None;
    }
    let patterns: Vec<String> = parts
        .next()
        .unwrap_or("*")
        .split(';')
        .map(|p| p.trim().to_string())
        .filter(|p| !p.is_empty())
        .collect();
    let mut recurse = false;
    let mut remove_self = false;
    for flag in parts {
        match flag.trim().to_ascii_uppercase().as_str() {
            "RECURSE" => recurse = true,
            "REMOVESELF" => remove_self = true,
            _ => {} // 未知标志忽略
        }
    }
    Some(FileTarget {
        dir,
        patterns,
        recurse,
        remove_self,
    })
}

// ---------------------------------------------------------------------------
// 环境变量展开
// ---------------------------------------------------------------------------

/// 展开 `%TOKEN%` 形式的环境变量。未知 token 保留字面量（后续目录不存在 → 扫描自然跳过）。
fn expand_env(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(start) = rest.find('%') {
        out.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        match after.find('%') {
            Some(end) => {
                out.push_str(&env_value(&after[..end]));
                rest = &after[end + 1..];
            }
            None => {
                // 未闭合的 '%' 原样保留
                out.push('%');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// winapp2 惯用 token → Windows 实际环境变量的映射（不区分大小写）。
fn env_value(token: &str) -> String {
    let lower = token.to_ascii_lowercase();
    match lower.as_str() {
        // %WinDir% → SystemRoot
        "windir" => env_or("SystemRoot", "C:\\Windows"),
        "systemdrive" => env_or("SystemDrive", "C:"),
        // %ProgramData% 与 %CommonAppData% 同义；直接读进程环境变量即可，无需 WMI
        "programdata" | "commonappdata" => env_or("ProgramData", "C:\\ProgramData"),
        "programfiles" => env_or("ProgramFiles", "C:\\Program Files"),
        "programfiles(x86)" => env_or("ProgramFiles(x86)", "C:\\Program Files (x86)"),
        "localappdata" => env_or("LocalAppData", ""),
        "appdata" => env_or("AppData", ""),
        // %Documents% 没有对应系统环境变量 → %USERPROFILE%\Documents
        "documents" => format!("{}\\Documents", env_or("USERPROFILE", "")),
        "temp" | "tmp" => env_or("TEMP", &env_or("TMP", "")),
        "userprofile" => env_or("USERPROFILE", ""),
        // 未知 token：按原环境变量名读取；读不到则保留字面量（目录不存在 → 跳过）
        _ => std::env::var(token).unwrap_or_else(|_| format!("%{}%", token)),
    }
}

fn env_or(name: &str, fallback: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| fallback.to_string())
}

// ---------------------------------------------------------------------------
// 通配符匹配（手写，仅支持 * 与 ?）
// ---------------------------------------------------------------------------

/// 手写通配符匹配：`*` 匹配任意长度（含空），`?` 匹配单个字符。
/// Windows 文件名不区分大小写，这里统一按小写比较。
pub(crate) fn wildcard_match(pattern: &str, text: &str) -> bool {
    let p: Vec<char> = pattern.to_lowercase().chars().collect();
    let t: Vec<char> = text.to_lowercase().chars().collect();
    let (mut pi, mut ti) = (0usize, 0usize);
    // 最近一个 '*' 的位置及其匹配起点（用于回溯）
    let (mut star_pi, mut star_ti) = (usize::MAX, 0usize);
    while ti < t.len() {
        if pi < p.len() && (p[pi] == '?' || p[pi] == t[ti]) {
            pi += 1;
            ti += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if star_pi != usize::MAX {
            // 回溯：让上一个 '*' 多吞一个字符
            pi = star_pi + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

/// 文件名是否命中任一模式
fn match_any(file_name: &str, patterns: &[String]) -> bool {
    patterns.iter().any(|p| wildcard_match(p, file_name))
}

// ---------------------------------------------------------------------------
// 扫描
// ---------------------------------------------------------------------------

/// 扫描一条规则，返回命中文件列表（便捷接口，不关心 REMOVESELF 目录时使用）。
pub fn scan_entry(entry: &RuleEntry) -> Vec<FileHit> {
    scan_entry_full(entry, None).0
}

/// 扫描一条规则的完整结果：
/// - 返回 `(命中文件, REMOVESELF 目标目录列表)`；
/// - `cancel`：可选取消标志，置位后尽快停止扫描（部分结果仍会返回）；
/// - 无权限 / 被占用的文件与目录静默跳过；符号链接一律跳过。
pub fn scan_entry_full(
    entry: &RuleEntry,
    cancel: Option<&AtomicBool>,
) -> (Vec<FileHit>, Vec<String>) {
    let mut hits: Vec<FileHit> = Vec::new();
    let mut remove_dirs: Vec<String> = Vec::new();
    'outer: for target in &entry.targets {
        for dir in resolve_target_dirs(&target.dir) {
            if target.remove_self {
                // REMOVESELF：目录本身在清理阶段整体删除；其内容大小仍计入 hits 供展示
                remove_dirs.push(dir.to_string_lossy().into_owned());
            }
            if target.recurse {
                collect_walk(&dir, &target.patterns, &mut hits, cancel);
            } else {
                collect_shallow(&dir, &target.patterns, &mut hits, cancel);
            }
            if hits.len() >= MAX_HITS_PER_ENTRY || cancelled(cancel) {
                break 'outer;
            }
        }
    }
    // Windows 路径大小写不敏感，按小写路径去重（不同 FileKey 可能命中同一文件）
    let mut seen: HashSet<String> = HashSet::new();
    hits.retain(|h| seen.insert(h.path.to_lowercase()));
    let mut dseen: HashSet<String> = HashSet::new();
    remove_dirs.retain(|d| dseen.insert(d.to_lowercase()));
    (hits, remove_dirs)
}

/// 递归扫描（RECURSE）：walkdir，最大深度 8，跳过符号链接，权限错误静默跳过。
fn collect_walk(dir: &Path, patterns: &[String], hits: &mut Vec<FileHit>, cancel: Option<&AtomicBool>) {
    let walker = WalkDir::new(dir)
        .max_depth(MAX_WALK_DEPTH)
        .follow_links(false);
    for entry in walker {
        if cancelled(cancel) {
            return;
        }
        // 无权限 / 被占用等遍历错误：静默跳过该条目
        let Ok(entry) = entry else { continue };
        let ft = entry.file_type();
        if ft.is_symlink() {
            continue; // 跳过符号链接（含目录联接）
        }
        if !ft.is_file() {
            continue; // 只统计文件
        }
        let name = entry.file_name().to_string_lossy();
        if !match_any(&name, patterns) {
            continue;
        }
        let Ok(md) = entry.metadata() else { continue };
        hits.push(FileHit {
            path: entry.path().to_string_lossy().into_owned(),
            size: md.len(),
        });
        if hits.len() >= MAX_HITS_PER_ENTRY {
            return;
        }
    }
}

/// 浅层扫描（非 RECURSE）：只读目标目录一层。
fn collect_shallow(dir: &Path, patterns: &[String], hits: &mut Vec<FileHit>, cancel: Option<&AtomicBool>) {
    // 目录不存在 / 无权限：静默返回
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        if cancelled(cancel) {
            return;
        }
        let Ok(ft) = e.file_type() else { continue };
        if ft.is_symlink() || !ft.is_file() {
            continue;
        }
        let name = e.file_name().to_string_lossy().into_owned();
        if !match_any(&name, patterns) {
            continue;
        }
        let Ok(md) = e.metadata() else { continue };
        hits.push(FileHit {
            path: e.path().to_string_lossy().into_owned(),
            size: md.len(),
        });
        if hits.len() >= MAX_HITS_PER_ENTRY {
            return;
        }
    }
}

fn cancelled(cancel: Option<&AtomicBool>) -> bool {
    cancel.map(|c| c.load(Ordering::Relaxed)).unwrap_or(false)
}

// ---------------------------------------------------------------------------
// 目录通配符展开
// ---------------------------------------------------------------------------

/// 把含环境变量与通配符的目标目录展开为具体目录列表。
/// 通配符可出现在任意路径组件（如 `%LocalAppData%/Packages/Microsoft.AccountsControl_*/AC`），
/// 逐组件展开：普通组件直接拼接，通配组件对父目录做 read_dir + 通配匹配（只接受目录）。
fn resolve_target_dirs(dir_tpl: &str) -> Vec<PathBuf> {
    let expanded = expand_env(dir_tpl);
    let norm = expanded.replace('/', "\\");
    let comps: Vec<&str> = norm
        .split('\\')
        .filter(|c| !c.is_empty() && *c != ".")
        .collect();
    if comps.is_empty() {
        return Vec::new();
    }

    let mut current: Vec<PathBuf> = Vec::new();
    if norm.starts_with("\\\\") {
        // UNC 根：\\server\share
        if comps.len() < 2 {
            return Vec::new();
        }
        current.push(PathBuf::from(format!("\\\\{}\\{}", comps[0], comps[1])));
        for c in &comps[2..] {
            push_component(&mut current, c);
        }
    } else if comps[0].len() == 2 && comps[0].ends_with(':') {
        // 盘符根：`C:` 必须补成 `C:\`，否则 Path 语义漂移为“该盘当前目录”
        current.push(PathBuf::from(format!("{}\\", comps[0])));
        for c in &comps[1..] {
            push_component(&mut current, c);
        }
    } else {
        // 相对路径兜底（正常规则都会带盘符或环境变量前缀）
        current.push(PathBuf::new());
        for c in &comps {
            push_component(&mut current, c);
        }
    }

    // 只保留真实存在且为目录的路径（不存在的目标自然丢弃）
    current.retain(|p| {
        !p.as_os_str().is_empty() && fs::metadata(p).map(|m| m.is_dir()).unwrap_or(false)
    });
    current
}

/// 在 current 的每个前缀下展开一个路径组件，结果替换 current。
fn push_component(current: &mut Vec<PathBuf>, comp: &str) {
    let mut next: Vec<PathBuf> = Vec::new();
    if comp.contains('*') || comp.contains('?') {
        for base in current.iter() {
            let Ok(rd) = fs::read_dir(base) else { continue };
            for e in rd.flatten() {
                // 通配组件只接受目录（文件不能作为后续组件的父目录）
                if !e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    continue;
                }
                let name = e.file_name();
                if wildcard_match(comp, &name.to_string_lossy()) {
                    next.push(base.join(&name));
                }
            }
        }
    } else {
        for base in current.iter() {
            next.push(base.join(comp));
        }
    }
    *current = next;
    if current.len() > MAX_EXPANDED_DIRS {
        current.truncate(MAX_EXPANDED_DIRS);
    }
}

// ---------------------------------------------------------------------------
// 清理
// ---------------------------------------------------------------------------

/// 执行清理（`scan_entry_full` 的逆操作），尽力而为：
/// - `hits`：逐个删除文件；被占用 / 无权限的记录日志后跳过，不影响其余；
/// - `remove_self_dirs`（REMOVESELF 目标）：先尽力清空目录内容，再 remove_dir_all 连目录一起删；
///   带防呆保护：盘符根目录与关键系统根目录一律拒绝删除。
pub fn clean_hits(hits: &[FileHit], remove_self_dirs: &[String]) -> anyhow::Result<()> {
    let mut removed_files: u64 = 0;
    let mut freed_bytes: u64 = 0;
    let mut failed_files: u64 = 0;
    for hit in hits {
        match fs::remove_file(&hit.path) {
            Ok(()) => {
                removed_files += 1;
                freed_bytes += hit.size;
            }
            Err(e) => {
                failed_files += 1;
                log::warn!("winapp2: 删除文件失败（跳过）{}：{}", hit.path, e);
            }
        }
    }

    let mut removed_dirs: u64 = 0;
    let mut failed_dirs: u64 = 0;
    for dir in remove_self_dirs {
        if is_dangerous_root(dir) {
            log::warn!("winapp2: 拒绝删除受保护目录 {}", dir);
            failed_dirs += 1;
            continue;
        }
        match empty_and_remove_dir(dir) {
            Ok(()) => removed_dirs += 1,
            // 目录已不存在：视为成功
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                failed_dirs += 1;
                log::warn!("winapp2: 删除目录失败（跳过）{}：{}", dir, e);
            }
        }
    }

    log::info!(
        "winapp2 清理完成：删除文件 {} 个 / 释放 {} 字节 / 失败 {} 个；删除目录 {} 个 / 失败 {} 个",
        removed_files,
        freed_bytes,
        failed_files,
        removed_dirs,
        failed_dirs
    );
    Ok(())
}

/// 先尽力逐项清空目录内容（单个失败不影响其他），再 remove_dir_all 兜底删除整个目录。
fn empty_and_remove_dir(dir: &str) -> std::io::Result<()> {
    let p = Path::new(dir);
    if let Ok(rd) = fs::read_dir(p) {
        for e in rd.flatten() {
            let Ok(ft) = e.file_type() else { continue };
            let _ = if ft.is_dir() {
                fs::remove_dir_all(e.path())
            } else {
                fs::remove_file(e.path())
            };
        }
    }
    fs::remove_dir_all(p)
}

/// 防呆判断：REMOVESELF 不允许作用于盘符根目录与关键系统根目录。
fn is_dangerous_root(dir: &str) -> bool {
    let trim_slashes = |s: &str| {
        s.trim_end_matches(|c| c == '\\' || c == '/').to_lowercase()
    };
    let lower = trim_slashes(dir);
    if lower.is_empty() || lower.len() <= 2 {
        return true; // 空串或盘符根（如 "C:"）
    }
    let protected = [
        env_or("SystemRoot", "C:\\Windows"),
        env_or("SystemDrive", "C:"),
        env_or("ProgramFiles", "C:\\Program Files"),
        env_or("ProgramFiles(x86)", "C:\\Program Files (x86)"),
        env_or("ProgramData", "C:\\ProgramData"),
        env_or("USERPROFILE", ""),
        env_or("LocalAppData", ""),
        env_or("AppData", ""),
    ]
    .iter()
    .map(|s| trim_slashes(s))
    .filter(|s| !s.is_empty())
    .collect::<Vec<_>>();
    protected.iter().any(|p| lower == *p)
}

// ---------------------------------------------------------------------------
// 单元测试（不依赖文件系统真实环境的部分：解析 / 展开 / 通配匹配）
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_wildcard_match() {
        assert!(wildcard_match("*", "anything.log"));
        assert!(wildcard_match("*.log", "a.b.log"));
        assert!(wildcard_match("*.log*", "app.log.1"));
        assert!(wildcard_match("*FontCache*.dat", "F0FontCacheX.dat"));
        assert!(wildcard_match("diag*.xml", "diagerr.xml"));
        assert!(wildcard_match("a?c", "abc"));
        assert!(!wildcard_match("a?c", "ac"));
        assert!(!wildcard_match("*.log", "log.txt"));
        // 大小写不敏感
        assert!(wildcard_match("LOG.old", "log.OLD"));
    }

    #[test]
    fn test_expand_env() {
        std::env::set_var("CM_TEST_DIR", "D:\\tmp");
        assert_eq!(expand_env("%CM_TEST_DIR%/sub"), "D:\\tmp/sub");
        // 未闭合的 % 保留
        assert_eq!(expand_env("50%off"), "50%off");
        // 未知 token 保留字面量
        assert_eq!(expand_env("%NoSuchVarXyz%\\a"), "%NoSuchVarXyz%\\a");
    }

    #[test]
    fn test_parse_file_key() {
        let t = parse_file_key("%LocalAppData%/Packages/App_*/AC|*.log;*.tmp|RECURSE|REMOVESELF").unwrap();
        assert_eq!(t.dir, "%LocalAppData%/Packages/App_*/AC");
        assert_eq!(t.patterns, vec!["*.log".to_string(), "*.tmp".to_string()]);
        assert!(t.recurse && t.remove_self);
        let t2 = parse_file_key("%SystemDrive%|DumpStack.log").unwrap();
        assert!(!t2.recurse && !t2.remove_self);
        assert_eq!(t2.patterns, vec!["DumpStack.log".to_string()]);
    }

    #[test]
    fn test_parse_str_accumulates_duplicate_keys() {
        let ini = "\
# 注释行
[规则A]
Description=测试
LangSecRef=3401
FileKey1=C:/a|*.log
; 注释
FileKey1=C:/b|*.tmp|RECURSE
FileKey2=C:/c|*
Detect=HKCU\\Software\\X
ExcludeKey1=C:/a|keep.txt
IconUrl=https://example.com/x.png
[空段]
Description=没有 FileKey
";
        let entries = parse_str(ini);
        assert_eq!(entries.len(), 1); // 空段被丢弃
        let e = &entries[0];
        assert_eq!(e.name, "规则A");
        assert_eq!(e.description, "测试");
        assert_eq!(e.lang_sec_ref, "3401");
        assert_eq!(e.targets.len(), 3); // FileKey1 两行累加 + FileKey2
        assert_eq!(e.targets[0].dir, "C:/a");
        assert_eq!(e.detect.len(), 1);
        assert_eq!(e.exclude_keys.len(), 1);
        assert_eq!(e.extra_keys.len(), 1); // IconUrl
    }
}
