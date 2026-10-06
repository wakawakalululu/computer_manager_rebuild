//! rust_lib — 实现自参考实现 flutter_rust_bridge v2 架构。
//! 参考实现导出面：frb_pde_ffi_dispatcher_primary / _sync 等统一分发器，
//! 本工程由 flutter_rust_bridge_codegen 生成等价的 frb_generated.rs。
//!
//! 模块树严格对照规格整理结果（specs/arch-notes、specs/api-map）。

pub mod api;

/// winapp2.ini 清理规则引擎（深度清理的规则解析 / 扫描 / 清理执行核心）
pub mod winapp2;

mod frb_generated; // ← 运行 `flutter_rust_bridge_codegen generate` 后自动生成
