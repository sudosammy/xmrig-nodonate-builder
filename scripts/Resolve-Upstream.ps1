[CmdletBinding()]
param([string]$RepositoryRoot)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$scriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepositoryRoot){$RepositoryRoot=Split-Path -Parent $scriptRoot}
$root=[IO.Path]::GetFullPath($RepositoryRoot)
$lock=[IO.File]::ReadAllText((Join-Path $root 'locks\build.lock.json')) | ConvertFrom-Json
$headers=@{'Accept'='application/vnd.github+json';'User-Agent'='xmrig-nodonate-builder';'X-GitHub-Api-Version'='2022-11-28'}
# Do not send the repository-scoped Actions token to the public upstream
# repository.  GITHUB_TOKEN is intentionally limited to this repository and
# can return an empty/404 response for cross-repository public API calls.
# Anonymous access is sufficient for this single public release listing and
# avoids coupling upstream discovery to token scope.
$releases=@(Invoke-RestMethod -Uri 'https://api.github.com/repos/xmrig/xmrig/releases/latest' -Headers $headers -TimeoutSec 30)
$stable=@()
$seen=@{}
foreach($release in $releases){
    if($release.draft -or $release.prerelease -or [string]$release.tag_name -notmatch '^v\d+\.\d+\.\d+$'){continue}
    $version=[Version]([string]$release.tag_name).Substring(1)
    if($seen.ContainsKey($version.ToString())){throw "Duplicate official stable version: $version"}
    $seen[$version.ToString()]=$true
    $stable+=[pscustomobject]@{Version=$version;Release=$release}
}
if($stable.Count -eq 0){throw 'No official stable XMRig release was found.'}
$latest=$stable | Sort-Object Version -Descending | Select-Object -First 1
$locked=[Version][string]$lock.upstream.version
$requiresReview=($latest.Version -ne $locked)
$tag='v{0}-nodonate.r{1}' -f [string]$lock.upstream.version,[int]$lock.recipe
$releaseExists=$false
if(-not $requiresReview -and (Get-Command gh.exe -ErrorAction SilentlyContinue)){
    & gh.exe release view $tag --repo $env:GITHUB_REPOSITORY --json tagName 2>$null | Out-Null
    $releaseExists=($LASTEXITCODE -eq 0)
}
$result=[pscustomobject]@{LatestVersion=$latest.Version.ToString();LockedVersion=$locked.ToString();RequiresReview=$requiresReview;Tag=$tag;ReleaseExists=$releaseExists;ShouldBuild=(-not $requiresReview -and -not $releaseExists)}
if($env:GITHUB_OUTPUT){
    @("latest=$($result.LatestVersion)","locked=$($result.LockedVersion)","requires_review=$($result.RequiresReview.ToString().ToLowerInvariant())","tag=$tag","should_build=$($result.ShouldBuild.ToString().ToLowerInvariant())") | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding UTF8
}
$result
