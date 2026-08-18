[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$OutputDirectory,
    [string]$WorkDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$scriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepositoryRoot) {$RepositoryRoot=Split-Path -Parent $scriptRoot}
$root=[IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
if (-not $OutputDirectory) {$OutputDirectory=Join-Path $root 'out'}
if (-not $WorkDirectory) {$WorkDirectory=Join-Path $root 'work'}
$output=[IO.Path]::GetFullPath($OutputDirectory)
$work=[IO.Path]::GetFullPath($WorkDirectory)
Import-Module (Join-Path $scriptRoot 'Builder.Core.psm1') -Force -DisableNameChecking

$lockPath=Join-Path $root 'locks\build.lock.json'
$lock=[IO.File]::ReadAllText($lockPath) | ConvertFrom-Json
[void](Test-XnbLock $lock)
if ($env:RUNNER_ENVIRONMENT -cne [string]$lock.toolchain.runnerEnvironment -or $env:ImageOS -cne 'win22') {throw 'Builds are accepted only on the GitHub-hosted windows-2022 image.'}
foreach ($required in @('GITHUB_REPOSITORY','GITHUB_REPOSITORY_ID','GITHUB_SHA','GITHUB_REF','ImageVersion')) {if ([string]::IsNullOrWhiteSpace([string][Environment]::GetEnvironmentVariable($required))) {throw "Missing GitHub Actions identity: $required"}}
if ($env:GITHUB_SHA -notmatch '^[a-f0-9]{40}$' -or $env:GITHUB_REPOSITORY_ID -notmatch '^\d+$') {throw 'Malformed GitHub workflow identity.'}

foreach ($path in @($output,$work)) {if (Test-Path -LiteralPath $path) {throw "Refusing to replace an existing build directory: $path"}; New-Item -ItemType Directory -Path $path -Force | Out-Null}
$source=Join-Path $work 'xmrig-source'
$deps=Join-Path $work 'xmrig-deps'
$build=Join-Path $work 'build'
$gnupg=Join-Path $work 'gnupg'
New-Item -ItemType Directory -Path $gnupg -Force | Out-Null
$git=(Get-Command git.exe -ErrorAction Stop).Source
$gpgCommand=Get-Command gpg.exe -ErrorAction SilentlyContinue
if (-not $gpgCommand) {$gpgCommand=Get-Command gpg -ErrorAction Stop}
$cmake=(Get-Command cmake.exe -ErrorAction Stop).Source
$gpgEnvironment=@{GNUPGHOME=(Get-XnbGnuPgHome -WindowsPath $gnupg -GpgPath $gpgCommand.Source)}

$keyPath=Join-Path $root ([string]$lock.upstream.signingKeyPath).Replace('/','\')
if ((Get-XnbSha256 $keyPath) -cne [string]$lock.upstream.signingKeySha256) {throw 'Pinned XMRig signing key hash mismatch.'}
$gpgHome=@('--homedir',[string]$gpgEnvironment.GNUPGHOME)
[void](Invoke-XnbCheckedCommand -FilePath $gpgCommand.Source -Arguments ($gpgHome+@('--batch','--import',$keyPath)) -Environment $gpgEnvironment)
$keyListing=Invoke-XnbCheckedCommand -FilePath $gpgCommand.Source -Arguments ($gpgHome+@('--batch','--with-colons','--fingerprint','--list-keys')) -Environment $gpgEnvironment
$fingerprints=@([regex]::Matches($keyListing.StdOut,'(?m)^fpr:::::::::([A-F0-9]{40}):$') | ForEach-Object {$_.Groups[1].Value})
if ($fingerprints -notcontains ([string]$lock.upstream.signingFingerprint).ToUpperInvariant()) {throw 'Pinned XMRig signing fingerprint was not imported.'}

[void](Invoke-XnbCheckedCommand -FilePath $git -Arguments @('init',$source))
[void](Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$source,'remote','add','origin',[string]$lock.upstream.repository))
[void](Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$source,'fetch','--depth=1','origin',('refs/tags/'+[string]$lock.upstream.tag+':refs/tags/'+[string]$lock.upstream.tag)))
[void](Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$source,'checkout','--detach',[string]$lock.upstream.tag))
$sourceCommit=(Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$source,'rev-parse','HEAD')).StdOut.Trim()
$sourceTree=(Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$source,'rev-parse','HEAD^{tree}')).StdOut.Trim()
$tagCommit=(Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$source,'rev-list','-n','1',[string]$lock.upstream.tag)).StdOut.Trim()
if ($sourceCommit -cne [string]$lock.upstream.commit -or $tagCommit -cne $sourceCommit -or $sourceTree -cne [string]$lock.upstream.tree) {throw 'Upstream tag, commit, or tree does not match the reviewed lock.'}
$signature=Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$source,'verify-commit','--raw',$sourceCommit) -Environment $gpgEnvironment
if ($signature.Output -notmatch ('(?i)VALIDSIG\s+'+[regex]::Escape([string]$lock.upstream.signingFingerprint))) {throw 'Upstream commit signature did not resolve to the pinned fingerprint.'}

[void](Invoke-XnbCheckedCommand -FilePath $git -Arguments @('init',$deps))
[void](Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$deps,'remote','add','origin',[string]$lock.dependencies.repository))
[void](Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$deps,'fetch','--depth=1','origin',[string]$lock.dependencies.commit))
[void](Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$deps,'checkout','--detach',[string]$lock.dependencies.commit))
$depsCommit=(Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$deps,'rev-parse','HEAD')).StdOut.Trim()
$depsTree=(Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$deps,'rev-parse','HEAD^{tree}')).StdOut.Trim()
if ($depsCommit -cne [string]$lock.dependencies.commit -or $depsTree -cne [string]$lock.dependencies.tree) {throw 'xmrig-deps commit or tree mismatch.'}

$patchPath=Join-Path $root ([string]$lock.patch.path).Replace('/','\')
if ((Get-XnbSha256 $patchPath) -cne [string]$lock.patch.sha256) {throw 'Donation patch hash mismatch.'}
[void](Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$source,'apply','--check','--unidiff-zero','--whitespace=error',$patchPath))
[void](Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$source,'apply','--unidiff-zero','--whitespace=error',$patchPath))
[void](Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$source,'diff','--check'))
$changed=@((Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$source,'diff','--name-only')).StdOut -split "`r?`n" | Where-Object {$_})
if ($changed.Count -ne 1 -or $changed[0] -cne 'src/donate.h') {throw "The donation patch changed unexpected files: $($changed -join ', ')"}
$donateHeader=Join-Path $source 'src\donate.h'
[void](Test-XnbDonationHeader $donateHeader)
if ((Get-XnbSha256 $donateHeader) -cne [string]$lock.patch.patchedDonateHeaderSha256) {throw 'Patched donation header hash mismatch.'}

$cmakeOutput=(Invoke-XnbCheckedCommand -FilePath $cmake -Arguments @('--version')).StdOut
if ($cmakeOutput -notmatch ('(?m)^cmake version '+[regex]::Escape([string]$lock.toolchain.cmakeVersion)+'$')) {throw "CMake version is not pinned $($lock.toolchain.cmakeVersion): $cmakeOutput"}
$vsRoot='C:\Program Files\Microsoft Visual Studio\2022\Enterprise'
$toolset=Join-Path $vsRoot ('VC\Tools\MSVC\'+[string]$lock.toolchain.msvcToolsVersion)
$sdk=Join-Path 'C:\Program Files (x86)\Windows Kits\10' ('Include\'+[string]$lock.toolchain.windowsSdkVersion)
if (-not (Test-Path -LiteralPath $toolset -PathType Container) -or -not (Test-Path -LiteralPath $sdk -PathType Container)) {throw 'Pinned MSVC toolset or Windows SDK is not installed on this runner image.'}
$depsPath=Join-Path $deps ([string]$lock.dependencies.relativePath).Replace('/','\')
[void](Invoke-XnbCheckedCommand -FilePath $cmake -Arguments @('-S',$source,'-B',$build,'-G',[string]$lock.toolchain.generator,'-A',[string]$lock.toolchain.architecture,'-T',('version='+[string]$lock.toolchain.msvcToolsVersion),('-DCMAKE_SYSTEM_VERSION='+[string]$lock.toolchain.windowsSdkVersion),('-DXMRIG_DEPS='+$depsPath)))
[void](Invoke-XnbCheckedCommand -FilePath $cmake -Arguments @('--build',$build,'--config',[string]$lock.toolchain.configuration,'--parallel','2') -TimeoutSeconds 3600)

$version=[string]$lock.upstream.version
$recipe=[int]$lock.recipe
$runtimeName="xmrig-$version-windows-x64-nodonate-r$recipe.zip"
$sourceName="xmrig-$version-nodonate-r$recipe-source.zip"
$manifestName="xmrig-$version-nodonate-r$recipe.manifest.json"
$runtimeStage=Join-Path $work 'runtime'
New-Item -ItemType Directory -Path $runtimeStage -Force | Out-Null
$xmrigExe=Join-Path $build 'Release\xmrig.exe'
$driver=Join-Path $source ([string]$lock.driver.relativePath).Replace('/','\')
foreach ($record in @(@($xmrigExe,'xmrig.exe'),@($driver,'WinRing0x64.sys'),@((Join-Path $source 'LICENSE'),'LICENSE'))) {if (-not (Test-Path -LiteralPath $record[0] -PathType Leaf)){throw "Required runtime input missing: $($record[0])"};Copy-Item -LiteralPath $record[0] -Destination (Join-Path $runtimeStage $record[1])}
$versionResult=Invoke-XnbCheckedCommand -FilePath (Join-Path $runtimeStage 'xmrig.exe') -Arguments @('--version') -WorkingDirectory $runtimeStage -TimeoutSeconds 30
if ($versionResult.Output -notmatch ('(?<!\d)'+[regex]::Escape($version)+'(?!\d)') -or $versionResult.Output -notmatch '(?i)x64|64-bit') {throw 'Built XMRig version or architecture self-test failed.'}
$driverSignature=Get-AuthenticodeSignature -LiteralPath (Join-Path $runtimeStage 'WinRing0x64.sys')
if ($driverSignature.Status -ne [Management.Automation.SignatureStatus]::Valid -or [string]$driverSignature.SignerCertificate.Subject -cne [string]$lock.driver.authenticodeSubject -or [string]$driverSignature.SignerCertificate.Thumbprint -cne [string]$lock.driver.authenticodeThumbprint) {throw 'WinRing0x64.sys failed the pinned Authenticode policy.'}
$dryConfig=Join-Path $work 'dry-run.json'
$dryJson=[ordered]@{autosave=$false;'donate-level'=0;'donate-over-proxy'=0;cpu=$false;opencl=$false;cuda=$false;pools=@([ordered]@{url='127.0.0.1:65535';user='x';pass='x';keepalive=$false;tls=$false});http=[ordered]@{enabled=$false;host='127.0.0.1';port=0;restricted=$true}} | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText($dryConfig,$dryJson,(New-Object Text.UTF8Encoding($false)))
$dry=Invoke-XnbCheckedCommand -FilePath (Join-Path $runtimeStage 'xmrig.exe') -Arguments @('--dry-run','--config',$dryConfig) -WorkingDirectory $runtimeStage -TimeoutSeconds 30
if ($dry.Output -notmatch '(?im)DONATE\s+0%' -or $dry.Output -match '(?i)donat(?:e|ion).*proxy.*(?:enabled|yes|[1-9]\d*%)') {throw "Donation-free dry-run policy failed: $($dry.Output)"}

$sumFiles=@('LICENSE','WinRing0x64.sys','xmrig.exe')
$sumLines=@($sumFiles | ForEach-Object {(Get-XnbSha256 (Join-Path $runtimeStage $_))+' *'+$_})
[IO.File]::WriteAllLines((Join-Path $runtimeStage 'SHA256SUMS'),$sumLines,(New-Object Text.UTF8Encoding($false)))
$runtimeFileNames=@('LICENSE','SHA256SUMS','WinRing0x64.sys','xmrig.exe')
if (@(Get-ChildItem -LiteralPath $runtimeStage -File).Count -ne 4) {throw 'Runtime allowlist contains an unexpected file.'}
$runtimeRecords=@($runtimeFileNames | ForEach-Object {$item=Get-Item -LiteralPath (Join-Path $runtimeStage $_);[pscustomobject]@{path=$_;sha256=Get-XnbSha256 $item.FullName;bytes=[long]$item.Length}})
$runtimeArchive=Join-Path $output $runtimeName
[void](New-XnbDeterministicZip -OutputPath $runtimeArchive -Files @($runtimeFileNames | ForEach-Object {[pscustomobject]@{SourcePath=(Join-Path $runtimeStage $_);EntryPath=$_}}))

$sourceRecords=@()
$sourcePrefix="xmrig-$version-nodonate-r$recipe-source"
foreach ($relative in @((Invoke-XnbCheckedCommand -FilePath $git -Arguments @('-C',$source,'ls-files')).StdOut -split "`r?`n" | Where-Object {$_})) {$sourceRecords += [pscustomobject]@{SourcePath=(Join-Path $source $relative.Replace('/','\'));EntryPath=($sourcePrefix+'/'+$relative)}}
foreach ($material in @('patches/donation-zero.patch','locks/build.lock.json','docs/BUILDING.md')) {$sourceRecords += [pscustomobject]@{SourcePath=(Join-Path $root $material.Replace('/','\'));EntryPath=($sourcePrefix+'/builder-materials/'+$material)}}
$sourceArchive=Join-Path $output $sourceName
[void](New-XnbDeterministicZip -OutputPath $sourceArchive -Files $sourceRecords)

$manifest=New-XnbRuntimeManifest -Lock $lock -Repository $env:GITHUB_REPOSITORY -RepositoryId ([long]$env:GITHUB_REPOSITORY_ID) -WorkflowCommit $env:GITHUB_SHA -WorkflowRef $env:GITHUB_REF -RunnerImageVersion $env:ImageVersion -RuntimeArchive $runtimeArchive -RuntimeFiles $runtimeRecords -SourceArchive $sourceArchive
$manifestPath=Join-Path $output $manifestName
[IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
Copy-Item -LiteralPath (Join-Path $source 'LICENSE') -Destination (Join-Path $output 'XMRIG-GPL-3.0-LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $root 'THIRD-PARTY-NOTICES.md') -Destination (Join-Path $output 'THIRD-PARTY-NOTICES.md')

$spdxFiles=@($runtimeRecords | ForEach-Object {[ordered]@{fileName=$_.path;checksums=@([ordered]@{algorithm='SHA256';checksumValue=$_.sha256})}})
$spdx=[ordered]@{spdxVersion='SPDX-2.3';dataLicense='CC0-1.0';SPDXID='SPDXRef-DOCUMENT';name="XMRig $version no-donation recipe $recipe";documentNamespace=('https://github.com/'+$env:GITHUB_REPOSITORY+'/spdx/'+$env:GITHUB_SHA);creationInfo=[ordered]@{created=[DateTimeOffset]::UtcNow.ToString('o');creators=@('Tool: xmrig-nodonate-builder')};files=$spdxFiles}
[IO.File]::WriteAllText((Join-Path $output "xmrig-$version-nodonate-r$recipe.spdx.json"),($spdx | ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))

[pscustomobject]@{RuntimeArchive=$runtimeArchive;SourceArchive=$sourceArchive;Manifest=$manifestPath;Tag=$manifest.releaseTag}
