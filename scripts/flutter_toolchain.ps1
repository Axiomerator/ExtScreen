function Invoke-ExtScreenFlutter {
    param([Parameter(Mandatory)][string[]]$FlutterArguments)

    $fvm = $env:EXTSCREEN_FVM_EXE
    if (-not $fvm) {
        $fvm = (Get-Command fvm -CommandType Application -ErrorAction Stop).Source
    }
    $ui = Join-Path $PSScriptRoot '..\ui'
    Push-Location -LiteralPath $ui
    try {
        & $fvm flutter @FlutterArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Flutter $($FlutterArguments -join ' ') failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}

function Get-ExtScreenFlutterRoot {
    # FVM can print its own notices alongside Flutter's JSON. Only read the SDK field.
    $rootField = Invoke-ExtScreenFlutter @('--version', '--machine') |
        Where-Object { $_ -match '^\s*"flutterRoot"\s*:\s*".*"\s*,?\s*$' } |
        Select-Object -First 1
    if (-not $rootField) {
        throw 'The pinned Flutter SDK could not be located through FVM.'
    }
    $flutterRoot = ('{' + $rootField.Trim().TrimEnd(',') + '}' | ConvertFrom-Json).flutterRoot
    if (-not (Test-Path -LiteralPath (Join-Path $flutterRoot 'bin\flutter.bat') -PathType Leaf)) {
        throw 'FVM reported a Flutter SDK without bin\flutter.bat.'
    }
    return $flutterRoot
}
