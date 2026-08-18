Set-StrictMode -Version 2.0

function Quote-XnbArgument {
    param([Parameter(Mandatory=$true)][string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1') + '"'
}

function Get-XnbGnuPgHome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$WindowsPath,
        [Parameter(Mandatory=$true)][string]$GpgPath
    )
    $full=[IO.Path]::GetFullPath($WindowsPath)
    # Git for Windows ships an MSYS gpg that treats a drive-letter GNUPGHOME as
    # relative to the current Unix cwd, producing a concatenated path that does
    # not exist. Native GnuPG wants the Windows path unchanged.
    if ([string]$GpgPath -match '(?i)\\Git\\(?:usr\\)?bin\\gpg(?:\.exe)?$') {
        foreach ($candidate in @($WindowsPath,$full)) {
            if ($candidate -match '^(?<drive>[A-Za-z]):\\(?<rest>.*)$') {
                return '/' + $Matches.drive.ToLowerInvariant() + '/' + $Matches.rest.Replace('\','/')
            }
        }
    }
    return $full
}

function Invoke-XnbCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments=@(),
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds=1800,
        [hashtable]$Environment=@{}
    )
    $startInfo=New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName=$FilePath
    $startInfo.Arguments=(($Arguments | ForEach-Object { Quote-XnbArgument ([string]$_) }) -join ' ')
    $startInfo.UseShellExecute=$false
    $startInfo.CreateNoWindow=$true
    $startInfo.RedirectStandardOutput=$true
    $startInfo.RedirectStandardError=$true
    if ($WorkingDirectory) { $startInfo.WorkingDirectory=$WorkingDirectory }
    foreach ($key in $Environment.Keys) { $startInfo.EnvironmentVariables[[string]$key]=[string]$Environment[$key] }
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$startInfo
    try {
        if (-not $process.Start()) { throw "Failed to start $FilePath." }
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit([Math]::Max(1,$TimeoutSeconds)*1000)) {
            try { $process.Kill() } catch { }
            throw "Command timed out: $FilePath"
        }
        $stdout.Wait(); $stderr.Wait()
        return [pscustomobject]@{ExitCode=$process.ExitCode;StdOut=$stdout.Result;StdErr=$stderr.Result;Output=($stdout.Result+$stderr.Result)}
    }
    finally { $process.Dispose() }
}

function Invoke-XnbCheckedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments=@(),
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds=1800,
        [hashtable]$Environment=@{}
    )
    $result=Invoke-XnbCommand -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -Environment $Environment
    if ($result.ExitCode -ne 0) { throw "Command failed ($($result.ExitCode)): $FilePath $($Arguments -join ' ')`n$($result.Output)" }
    return $result
}

function Get-XnbSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-XnbStableTagVersions {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$LsRemoteOutput)
    $stable=@()
    $seen=@{}
    foreach ($line in @($LsRemoteOutput -split "`r?`n")) {
        if ($line -notmatch '^[0-9a-f]{40}\trefs/tags/(v\d+\.\d+\.\d+)$') { continue }
        $tag=[string]$Matches[1]
        $version=[Version]$tag.Substring(1)
        $key=$version.ToString()
        if ($seen.ContainsKey($key)) { throw "Duplicate official stable version: $version" }
        $seen[$key]=$true
        $stable+=[pscustomobject]@{Version=$version;Tag=$tag}
    }
    return $stable
}

function Test-XnbLock {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Lock)
    if ([int]$Lock.lockSchema -ne 1 -or [int]$Lock.recipe -lt 1) { throw 'Unsupported builder lock schema or recipe.' }
    foreach ($hash in @($Lock.upstream.commit,$Lock.upstream.tree,$Lock.dependencies.commit,$Lock.dependencies.tree)) {
        if ([string]$hash -notmatch '^[a-f0-9]{40}$') { throw 'The build lock contains a malformed Git object ID.' }
    }
    foreach ($hash in @($Lock.upstream.signingKeySha256,$Lock.patch.sha256,$Lock.patch.patchedDonateHeaderSha256)) {
        if ([string]$hash -notmatch '^[a-f0-9]{64}$') { throw 'The build lock contains a malformed SHA-256.' }
    }
    if ([string]$Lock.upstream.tag -cne ('v'+[string]$Lock.upstream.version)) { throw 'The upstream tag/version lock is inconsistent.' }
    if ([int]$Lock.patch.expectedReplacements -ne 2) { throw 'The donation patch must make exactly two replacements.' }
    if ([string]$Lock.toolchain.runnerImage -cne 'windows-2022' -or [string]$Lock.toolchain.runnerEnvironment -cne 'github-hosted') { throw 'Only a GitHub-hosted windows-2022 runner is accepted.' }
    return $true
}

function Test-XnbDonationHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    $text=[IO.File]::ReadAllText($Path)
    $defaultMatches=[regex]::Matches($text,'(?m)^constexpr const int kDefaultDonateLevel = 0;\r?$')
    $minimumMatches=[regex]::Matches($text,'(?m)^constexpr const int kMinimumDonateLevel = 0;\r?$')
    if ($defaultMatches.Count -ne 1 -or $minimumMatches.Count -ne 1) { throw 'Donation constants were not changed to exactly two zero-valued declarations.' }
    if ($text -match '(?m)^constexpr const int k(?:Default|Minimum)DonateLevel = [1-9]\d*;\r?$') { throw 'A nonzero compiled donation constant remains.' }
    return $true
}

function New-XnbDeterministicZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object[]]$Files,
        [Parameter(Mandatory=$true)][string]$OutputPath
    )
    Add-Type -AssemblyName System.IO.Compression
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $records=@($Files | Sort-Object EntryPath)
    foreach ($record in $records) {
        $entry=[string]$record.EntryPath
        if ([string]::IsNullOrWhiteSpace($entry) -or [IO.Path]::IsPathRooted($entry) -or $entry -match '(^|/)\.\.(/|$)' -or $entry.Contains(':')) { throw "Unsafe ZIP entry: $entry" }
        if (-not $seen.Add($entry)) { throw "Duplicate ZIP entry: $entry" }
        if (-not (Test-Path -LiteralPath ([string]$record.SourcePath) -PathType Leaf)) { throw "ZIP source is missing: $($record.SourcePath)" }
    }
    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
    $parent=Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $stream=[IO.File]::Open($OutputPath,[IO.FileMode]::CreateNew)
    try {
        $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        try {
            foreach ($record in $records) {
                $entry=$archive.CreateEntry(([string]$record.EntryPath).Replace('\','/'),[IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime=[DateTimeOffset]'2000-01-01T00:00:00Z'
                $input=[IO.File]::OpenRead([string]$record.SourcePath)
                try { $output=$entry.Open(); try {$input.CopyTo($output)} finally {$output.Dispose()} } finally {$input.Dispose()}
            }
        }
        finally {$archive.Dispose()}
    }
    finally {$stream.Dispose()}
    return $OutputPath
}

function New-XnbRuntimeManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Lock,
        [Parameter(Mandatory=$true)][string]$Repository,
        [Parameter(Mandatory=$true)][long]$RepositoryId,
        [Parameter(Mandatory=$true)][string]$WorkflowCommit,
        [Parameter(Mandatory=$true)][string]$WorkflowRef,
        [Parameter(Mandatory=$true)][string]$RunnerImageVersion,
        [Parameter(Mandatory=$true)][string]$RuntimeArchive,
        [Parameter(Mandatory=$true)][object[]]$RuntimeFiles,
        [Parameter(Mandatory=$true)][string]$SourceArchive
    )
    $version=[string]$Lock.upstream.version
    $recipe=[int]$Lock.recipe
    return [ordered]@{
        manifestSchema=1
        releaseTag="v$version-nodonate.r$recipe"
        recipe=$recipe
        upstream=[ordered]@{repository=[string]$Lock.upstream.repository;version=$version;tag=[string]$Lock.upstream.tag;commit=[string]$Lock.upstream.commit;tree=[string]$Lock.upstream.tree;signingFingerprint=[string]$Lock.upstream.signingFingerprint}
        dependencies=[ordered]@{repository=[string]$Lock.dependencies.repository;commit=[string]$Lock.dependencies.commit;tree=[string]$Lock.dependencies.tree;relativePath=[string]$Lock.dependencies.relativePath}
        patch=[ordered]@{sha256=[string]$Lock.patch.sha256;patchedDonateHeaderSha256=[string]$Lock.patch.patchedDonateHeaderSha256;replacements=[int]$Lock.patch.expectedReplacements}
        toolchain=[ordered]@{cmakeVersion=[string]$Lock.toolchain.cmakeVersion;visualStudioProductLine=[string]$Lock.toolchain.visualStudioProductLine;msvcToolsVersion=[string]$Lock.toolchain.msvcToolsVersion;windowsSdkVersion=[string]$Lock.toolchain.windowsSdkVersion}
        builder=[ordered]@{repository=$Repository;repositoryId=$RepositoryId;workflowPath='.github/workflows/build-release.yml';workflowCommit=$WorkflowCommit;workflowRef=$WorkflowRef;oidcIssuer='https://token.actions.githubusercontent.com';runnerImage=[string]$Lock.toolchain.runnerImage;runnerImageVersion=$RunnerImageVersion;runnerEnvironment=[string]$Lock.toolchain.runnerEnvironment}
        runtime=[ordered]@{
            name=[IO.Path]::GetFileName($RuntimeArchive);sha256=Get-XnbSha256 $RuntimeArchive;bytes=[long](Get-Item -LiteralPath $RuntimeArchive).Length
            donationLevel=0;donationOverProxy=0
            executable=($RuntimeFiles | Where-Object {$_.path -ceq 'xmrig.exe'} | Select-Object -First 1)
            driver=($RuntimeFiles | Where-Object {$_.path -ceq 'WinRing0x64.sys'} | Select-Object -First 1)
            files=@($RuntimeFiles)
        }
        source=[ordered]@{name=[IO.Path]::GetFileName($SourceArchive);sha256=Get-XnbSha256 $SourceArchive;bytes=[long](Get-Item -LiteralPath $SourceArchive).Length}
    }
}

Export-ModuleMember -Function *-Xnb*
