$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\flutter_toolchain.ps1"

Invoke-ExtScreenFlutter @('pub', 'get')
Invoke-ExtScreenFlutter @('build', 'windows', '--release')
