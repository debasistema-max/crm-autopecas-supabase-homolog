param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [Parameter(Mandatory=$true)][string]$NodePath
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Core') {
    $env:PSModulePath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\Modules'
}
$config = (Resolve-Path -LiteralPath $ConfigPath).Path
$node = (Resolve-Path -LiteralPath $NodePath).Path
$worker = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'installed_catalog_worker.cjs')).Path
$folder = Split-Path $config -Parent
$process = Start-Process -FilePath $node -ArgumentList @("`"$worker`"", "`"$config`"") -WindowStyle Hidden -Wait -PassThru `
    -RedirectStandardOutput (Join-Path $folder 'last-run.log') -RedirectStandardError (Join-Path $folder 'last-error.log')
exit $process.ExitCode
