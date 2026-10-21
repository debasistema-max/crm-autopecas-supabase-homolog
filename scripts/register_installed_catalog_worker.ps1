param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [Parameter(Mandatory=$true)][string]$NodePath,
    [string]$TaskName = 'IPS Catalogo Local Homolog'
)
$ErrorActionPreference = 'Stop'
$config = (Resolve-Path -LiteralPath $ConfigPath).Path
$node = (Resolve-Path -LiteralPath $NodePath).Path
$script = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'installed_catalog_worker.cjs')).Path
$repo = Split-Path $PSScriptRoot -Parent
if ($config.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Guarde credenciais fora do repositorio.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$configFolder = Split-Path $config -Parent
$expectedFolder = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'IPSCRM\InstalledCatalogWorkerHomolog'))
if (![string]::Equals($configFolder, $expectedFolder, [StringComparison]::OrdinalIgnoreCase)) { throw 'Use somente a pasta privada IPSCRM\InstalledCatalogWorkerHomolog em LOCALAPPDATA.' }
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
$directory = Get-Item -LiteralPath $configFolder
if ($PSVersionTable.PSEdition -eq 'Core') {
    [IO.FileSystemAclExtensions]::SetAccessControl($directory, $acl)
} else {
    $directory.SetAccessControl($acl)
}
& $node $script $config --check
if ($LASTEXITCODE -ne 0) { throw 'O teste do executor falhou. A tarefa nao foi registrada.' }
$wrapper = Join-Path $PSScriptRoot 'run_installed_catalog_worker.ps1'
$powershell = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
$action = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File `"$wrapper`" -ConfigPath `"$config`" -NodePath `"$node`"" -WorkingDirectory $repo
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 25) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { throw 'A tarefa ja existe; revise antes de substituir.' }
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
Write-Output "Executor registrado: $TaskName. Requer Windows ligado e usuario conectado."
