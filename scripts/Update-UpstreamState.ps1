[CmdletBinding()]
param([string]$RepositoryRoot,[Parameter(Mandatory=$true)][string]$LatestVersion,[int]$MaximumHeartbeatDays=40)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$scriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
if(-not $RepositoryRoot){$RepositoryRoot=Split-Path -Parent $scriptRoot}
$path=Join-Path $RepositoryRoot 'upstream-state.json'
$existing=$null
if(Test-Path -LiteralPath $path){$existing=[IO.File]::ReadAllText($path)|ConvertFrom-Json}
$last=[DateTimeOffset]::MinValue
$due=(-not $existing -or -not [DateTimeOffset]::TryParse([string]$existing.checkedAtUtc,[ref]$last) -or ([DateTimeOffset]::UtcNow-$last.ToUniversalTime()).TotalDays -ge $MaximumHeartbeatDays -or [string]$existing.latestStableVersion -cne $LatestVersion)
if($due){
    $state=[ordered]@{schemaVersion=1;latestStableVersion=$LatestVersion;checkedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
    [IO.File]::WriteAllText($path,($state|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
}
if($env:GITHUB_OUTPUT){('changed='+$due.ToString().ToLowerInvariant())|Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding UTF8}
[pscustomobject]@{Changed=$due;Path=$path}

