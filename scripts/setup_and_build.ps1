# computer_manager_rebuild 一键构建脚本
# 在装有/可装 Flutter + Rust 工具链的机器上执行
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
Set-Location $root

Write-Host '[1/5] 检查工具链' -ForegroundColor Cyan
foreach ($t in 'flutter', 'dart', 'cargo') {
  if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
    throw "缺少 $t —— 见 README.md 第 1 步安装"
  }
}

Write-Host '[2/5] 生成 Windows 平台目录（如缺）' -ForegroundColor Cyan
if (-not (Test-Path 'windows')) {
  flutter create . --platforms=windows --org dev.rebuild --project-name computer_manager
}

Write-Host '[3/5] flutter pub get' -ForegroundColor Cyan
flutter pub get

Write-Host '[4/5] flutter_rust_bridge codegen' -ForegroundColor Cyan
if (-not (Get-Command flutter_rust_bridge_codegen -ErrorAction SilentlyContinue)) {
  dart pub global activate flutter_rust_bridge_codegen 2.9.0
}
flutter_rust_bridge_codegen generate

Write-Host '[5/5] 构建并运行' -ForegroundColor Cyan
flutter run -d windows
# 发布: flutter build windows --release
