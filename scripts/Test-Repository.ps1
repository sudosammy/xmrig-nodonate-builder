[CmdletBinding()]
param([string]$RepositoryRoot)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$scriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
if(-not $RepositoryRoot){$RepositoryRoot=Split-Path -Parent $scriptRoot}
$root=[IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
if($PSVersionTable.PSVersion.Major -ne 5){
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path -RepositoryRoot $root
    if($LASTEXITCODE -ne 0){throw "Windows PowerShell builder tests failed with exit code $LASTEXITCODE."}
    return
}
foreach($file in @(Get-ChildItem -LiteralPath $root -Recurse -File|Where-Object{$_.Extension -in @('.ps1','.psm1')})){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if(@($errors).Count -gt 0){throw "$($file.FullName): $(@($errors|ForEach-Object{$_.Message}) -join '; ')"}
}
foreach($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.json')){[void]([IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json)}
$selfPath=$MyInvocation.MyCommand.Path
$allText=@(Get-ChildItem -LiteralPath $root -Recurse -File|Where-Object{$_.FullName -notmatch '\\.git\\' -and $_.FullName -cne $selfPath}|ForEach-Object{try{[IO.File]::ReadAllText($_.FullName)}catch{''}}) -join "`n"
if($allText -match '(?i)-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|ghp_[A-Za-z0-9]{20,}|github_pat_'){throw 'A private key or token-shaped value is present.'}
Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop
$result=Invoke-Pester -Script (Join-Path $root 'tests') -PassThru
if([int]$result.FailedCount -gt 0){throw "$($result.FailedCount) builder test(s) failed."}
Write-Host 'Builder repository verification passed.' -ForegroundColor Green
