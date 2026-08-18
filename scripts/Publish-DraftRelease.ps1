[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$AssetDirectory,
    [Parameter(Mandatory=$true)][string]$Tag,
    [Parameter(Mandatory=$true)][string]$Repository,
    [Parameter(Mandatory=$true)][string]$TargetCommit
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$scriptRoot=Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptRoot 'Builder.Core.psm1') -Force -DisableNameChecking
$gh=(Get-Command gh.exe -ErrorAction Stop).Source
$assetRoot=[IO.Path]::GetFullPath($AssetDirectory)
$assets=@(Get-ChildItem -LiteralPath $assetRoot -File | Sort-Object Name)
$runtime=@($assets|Where-Object{$_.Name -match '^xmrig-\d+\.\d+\.\d+-windows-x64-nodonate-r\d+\.zip$'})
$source=@($assets|Where-Object{$_.Name -match '^xmrig-\d+\.\d+\.\d+-nodonate-r\d+-source\.zip$'})
$manifest=@($assets|Where-Object{$_.Name -match '^xmrig-\d+\.\d+\.\d+-nodonate-r\d+\.manifest\.json$'})
$bundle=@($assets|Where-Object{$_.Name -eq ($runtime[0].Name+'.sigstore.json')})
$required=@('SHA256SUMS','THIRD-PARTY-NOTICES.md','XMRIG-GPL-3.0-LICENSE.txt')
if($runtime.Count -ne 1 -or $source.Count -ne 1 -or $manifest.Count -ne 1 -or $bundle.Count -ne 1 -or @($assets|Where-Object{$_.Name -match '\.spdx\.json$'}).Count -ne 1 -or @($required|Where-Object{$_ -notin $assets.Name}).Count -ne 0){throw 'Release asset allowlist is incomplete or ambiguous.'}

function Test-DownloadedRelease {
    param([string]$DownloadRoot)
    $downloaded=@(Get-ChildItem -LiteralPath $DownloadRoot -File)
    if(@(Compare-Object -ReferenceObject @($assets.Name|Sort-Object) -DifferenceObject @($downloaded.Name|Sort-Object) -CaseSensitive).Count -ne 0){throw 'Published release asset names do not match the local allowlist.'}
    $sumLines=[IO.File]::ReadAllLines((Join-Path $DownloadRoot 'SHA256SUMS'))
    foreach($line in $sumLines){
        if($line -notmatch '^(?<hash>[a-f0-9]{64}) \*(?<name>[^\\/:]+)$'){throw "Malformed release checksum line: $line"}
        $path=Join-Path $DownloadRoot $matches.name
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)-or (Get-XnbSha256 $path)-cne $matches.hash){throw "Release checksum mismatch: $($matches.name)"}
    }
}

$view=Invoke-XnbCommand -FilePath $gh -Arguments @('release','view',$Tag,'--repo',$Repository,'--json','isDraft,tagName') -TimeoutSeconds 60
if($view.ExitCode -eq 0){
    $existing=$view.StdOut|ConvertFrom-Json
    if([bool]$existing.isDraft){throw 'A pre-existing draft release requires manual review; assets will not be replaced.'}
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('xnb-existing-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp|Out-Null
    try{[void](Invoke-XnbCheckedCommand -FilePath $gh -Arguments @('release','download',$Tag,'--repo',$Repository,'--dir',$temp));Test-DownloadedRelease $temp}
    finally{if((Split-Path -Leaf $temp)-like 'xnb-existing-*'){Remove-Item -LiteralPath $temp -Recurse -Force}}
    Write-Host 'The immutable release already exists with the expected assets; no publication was attempted.'
    return
}

$created=$false
try{
    [void](Invoke-XnbCheckedCommand -FilePath $gh -Arguments @('release','create',$Tag,'--repo',$Repository,'--target',$TargetCommit,'--draft','--title',$Tag,'--notes',('Verified donation-free XMRig build '+$Tag+'. See the manifest, source archive, checksums, SBOM, and provenance bundle.')))
    $created=$true
    foreach($asset in $assets){[void](Invoke-XnbCheckedCommand -FilePath $gh -Arguments @('release','upload',$Tag,$asset.FullName,'--repo',$Repository))}
    $verify=Join-Path ([IO.Path]::GetTempPath()) ('xnb-verify-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $verify|Out-Null
    try{[void](Invoke-XnbCheckedCommand -FilePath $gh -Arguments @('release','download',$Tag,'--repo',$Repository,'--dir',$verify));Test-DownloadedRelease $verify}
    finally{if((Split-Path -Leaf $verify)-like 'xnb-verify-*'){Remove-Item -LiteralPath $verify -Recurse -Force}}
    [void](Invoke-XnbCheckedCommand -FilePath $gh -Arguments @('release','edit',$Tag,'--repo',$Repository,'--draft=false'))
}
catch{
    if($created){[void](Invoke-XnbCommand -FilePath $gh -Arguments @('release','delete',$Tag,'--repo',$Repository,'--yes','--cleanup-tag=false') -TimeoutSeconds 60)}
    throw
}
