[CmdletBinding()]
param([string]$RepositoryRoot)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$scriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepositoryRoot){$RepositoryRoot=Split-Path -Parent $scriptRoot}
$root=[IO.Path]::GetFullPath($RepositoryRoot)
Import-Module (Join-Path $scriptRoot 'Builder.Core.psm1') -Force -DisableNameChecking
$lock=[IO.File]::ReadAllText((Join-Path $root 'locks\build.lock.json')) | ConvertFrom-Json
# Resolve the highest stable upstream tag over Git HTTPS. The repository-scoped
# Actions token 404s public cross-repo REST calls, and Windows PowerShell's
# web cmdlets against api.github.com have timed out on hosted runners.
$git=Get-Command git.exe -ErrorAction SilentlyContinue
if (-not $git) {$git=Get-Command git -ErrorAction Stop}
$remote=Invoke-XnbCheckedCommand -FilePath $git.Source -Arguments @('ls-remote','--tags','--refs',[string]$lock.upstream.repository) -TimeoutSeconds 60
$stable=@(Get-XnbStableTagVersions $remote.StdOut)
if ($stable.Count -eq 0) { throw 'No official stable XMRig release was found.' }
$latest=$stable | Sort-Object Version -Descending | Select-Object -First 1
$locked=[Version][string]$lock.upstream.version
$requiresReview=($latest.Version -ne $locked)
$tag='v{0}-nodonate.r{1}' -f [string]$lock.upstream.version,[int]$lock.recipe
$releaseExists=$false
if (-not $requiresReview -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
    $gh=Get-Command gh.exe -ErrorAction SilentlyContinue
    if (-not $gh) { $gh=Get-Command gh -ErrorAction SilentlyContinue }
    if ($gh) {
        # Do not redirect native stderr under ErrorActionPreference=Stop; Windows
        # PowerShell treats that as a terminating error when the release is absent.
        $view=Invoke-XnbCommand -FilePath $gh.Source -Arguments @('release','view',$tag,'--repo',$env:GITHUB_REPOSITORY,'--json','tagName') -TimeoutSeconds 60
        $releaseExists=($view.ExitCode -eq 0)
    }
}
$result=[pscustomobject]@{LatestVersion=$latest.Version.ToString();LockedVersion=$locked.ToString();RequiresReview=$requiresReview;Tag=$tag;ReleaseExists=$releaseExists;ShouldBuild=(-not $requiresReview -and -not $releaseExists)}
if ($env:GITHUB_OUTPUT) {
    @("latest=$($result.LatestVersion)","locked=$($result.LockedVersion)","requires_review=$($result.RequiresReview.ToString().ToLowerInvariant())","tag=$tag","should_build=$($result.ShouldBuild.ToString().ToLowerInvariant())") | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding UTF8
}
$result
