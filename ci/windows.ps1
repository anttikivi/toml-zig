$ErrorActionPreference = "Stop"
Set-PSDebug -Trace 1

.\zig.ps1 build fetch-toml-test
.\zig.ps1 build test --summary all
