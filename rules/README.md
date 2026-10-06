# rules 说明

winapp2 格式清理规则目录。`rust/src/winapp2.rs` 引擎按
`FileKeyN=目录|模式|RECURSE|REMOVESELF` 语法解析并执行。

放入你自己的 `*.ini` 即可（**不入库**）。社区规则库可选用
[MoscaDotTo/Winapp2](https://github.com/MoscaDotTo/Winapp2)（CC-BY-SA-4.0，
署名 + 相同方式共享），下载其 `Winapp2.ini` 放到本目录。
