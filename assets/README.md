# assets 说明

- `fonts/`：思源黑体全字重（SIL OFL 许可）+ iconfont，已入库。
- `branding/`：应用图标与托盘图标（自绘通用样式），已入库。
- `images/`、`lottie/`：运行时可选素材目录，**不入库**（保留 `.gitkeep` 占位）。
  界面所有引用都带 errorBuilder 兜底，目录为空不影响编译运行；放入素材即生效。
