$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\Builder.Core.psm1') -Force -DisableNameChecking

Describe 'xmrig-nodonate-builder policy' {
    It 'validates the reviewed build lock and all pinned file hashes' {
        $lock=[IO.File]::ReadAllText((Join-Path $root 'locks\build.lock.json'))|ConvertFrom-Json
        {Test-XnbLock $lock}|Should Not Throw
        (Get-XnbSha256 (Join-Path $root $lock.patch.path))|Should Be $lock.patch.sha256
        (Get-XnbSha256 (Join-Path $root $lock.upstream.signingKeyPath))|Should Be $lock.upstream.signingKeySha256
    }

    It 'applies only the exact two-line donation patch and produces the pinned header' {
        $fixture=Join-Path $TestDrive 'fixture'
        $source=Join-Path $fixture 'src'
        New-Item -ItemType Directory -Path $source -Force|Out-Null
        $lines=@()
        1..39|ForEach-Object{$lines+='// fixture line '+$_}
        $lines+='constexpr const int kDefaultDonateLevel = 1;'
        $lines+='constexpr const int kMinimumDonateLevel = 1;'
        $lines+='#endif'
        [IO.File]::WriteAllLines((Join-Path $source 'donate.h'),$lines,(New-Object Text.UTF8Encoding($false)))
        git -C $fixture init|Out-Null
        git -C $fixture config user.name fixture
        git -C $fixture config user.email fixture@example.invalid
        git -C $fixture add -- src/donate.h
        git -C $fixture commit -m fixture|Out-Null
        git -C $fixture apply --check --unidiff-zero (Join-Path $root 'patches\donation-zero.patch')
        $LASTEXITCODE|Should Be 0
        git -C $fixture apply --unidiff-zero (Join-Path $root 'patches\donation-zero.patch')
        $LASTEXITCODE|Should Be 0
        @(git -C $fixture diff --name-only)|Should Be @('src/donate.h')
        {Test-XnbDonationHeader (Join-Path $source 'donate.h')}|Should Not Throw
    }

    It 'rejects missing or nonzero donation declarations' {
        $path=Join-Path $TestDrive 'bad-donate.h'
        [IO.File]::WriteAllText($path,"constexpr const int kDefaultDonateLevel = 0;`nconstexpr const int kMinimumDonateLevel = 1;")
        {Test-XnbDonationHeader $path}|Should Throw
    }

    It 'creates stable ZIP bytes from the same ordered inputs' {
        $a=Join-Path $TestDrive 'a.txt';$b=Join-Path $TestDrive 'b.txt'
        [IO.File]::WriteAllText($a,'a');[IO.File]::WriteAllText($b,'b')
        $files=@([pscustomobject]@{SourcePath=$b;EntryPath='b.txt'},[pscustomobject]@{SourcePath=$a;EntryPath='a.txt'})
        $one=Join-Path $TestDrive 'one.zip';$two=Join-Path $TestDrive 'two.zip'
        [void](New-XnbDeterministicZip -Files $files -OutputPath $one)
        [void](New-XnbDeterministicZip -Files @($files[1],$files[0]) -OutputPath $two)
        (Get-XnbSha256 $one)|Should Be (Get-XnbSha256 $two)
    }

    It 'emits a manifest containing enforced repository and zero-donation identity' {
        $lock=[IO.File]::ReadAllText((Join-Path $root 'locks\build.lock.json'))|ConvertFrom-Json
        $runtime=Join-Path $TestDrive 'runtime.zip';$source=Join-Path $TestDrive 'source.zip'
        [IO.File]::WriteAllText($runtime,'runtime');[IO.File]::WriteAllText($source,'source')
        $records=@(
            [pscustomobject]@{path='LICENSE';sha256=('1'*64);bytes=1},
            [pscustomobject]@{path='SHA256SUMS';sha256=('2'*64);bytes=1},
            [pscustomobject]@{path='WinRing0x64.sys';sha256=('3'*64);bytes=1},
            [pscustomobject]@{path='xmrig.exe';sha256=('4'*64);bytes=1}
        )
        $manifest=New-XnbRuntimeManifest -Lock $lock -Repository owner/xmrig-nodonate-builder -RepositoryId 123 -WorkflowCommit ('a'*40) -WorkflowRef refs/heads/main -RunnerImageVersion fixture -RuntimeArchive $runtime -RuntimeFiles $records -SourceArchive $source
        $manifest.builder.repositoryId|Should Be 123
        $manifest.builder.workflowPath|Should Be '.github/workflows/build-release.yml'
        $manifest.runtime.donationLevel|Should Be 0
        $manifest.runtime.donationOverProxy|Should Be 0
        @($manifest.runtime.files).Count|Should Be 4
    }

    It 'selects the highest stable vX.Y.Z tag and ignores prerelease suffixes' {
        $lsRemote=@(
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa	refs/tags/v6.25.0',
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb	refs/tags/v6.26.0',
            'cccccccccccccccccccccccccccccccccccccccc	refs/tags/v6.27.0-beta',
            'dddddddddddddddddddddddddddddddddddddddd	refs/tags/v6.24.0'
        ) -join "`n"
        $versions=@(Get-XnbStableTagVersions $lsRemote)
        $versions.Count | Should Be 3
        @($versions | Where-Object {$_.Tag -eq 'v6.26.0'}).Count | Should Be 1
        @($versions | Where-Object {$_.Tag -match '-'}).Count | Should Be 0
        ($versions | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString() | Should Be '6.26.0'
    }

    It 'captures native-command failure without treating stderr as terminating' {
        $cmd=Get-Command cmd.exe -ErrorAction SilentlyContinue
        if ($cmd) {
            $result=Invoke-XnbCommand -FilePath $cmd.Source -Arguments @('/c','echo err 1>&2 & exit 7') -TimeoutSeconds 10
        } else {
            $sh=(Get-Command sh -ErrorAction Stop).Source
            $result=Invoke-XnbCommand -FilePath $sh -Arguments @('-c','echo err 1>&2; exit 7') -TimeoutSeconds 10
        }
        $result.ExitCode | Should Be 7
        $result.StdErr | Should Match 'err'
    }

    It 'resolves upstream over git and does not redirect native stderr' {
        $script=[IO.File]::ReadAllText((Join-Path $root 'scripts\Resolve-Upstream.ps1'))
        $script | Should Match ([regex]::Escape('ls-remote'))
        $script | Should Not Match 'Invoke-RestMethod'
        $script | Should Not Match '2>\$null'
    }

    It 'converts Git-for-Windows gpg homedirs to MSYS paths' {
        (Get-XnbGnuPgHome -WindowsPath 'D:\a\_temp\verified-build\gnupg' -GpgPath 'C:\Program Files\Git\usr\bin\gpg.exe') | Should Be '/d/a/_temp/verified-build/gnupg'
        (Get-XnbGnuPgHome -WindowsPath 'D:\a\_temp\verified-build\gnupg' -GpgPath 'C:\Program Files (x86)\GnuPG\bin\gpg.exe') | Should Be ([IO.Path]::GetFullPath('D:\a\_temp\verified-build\gnupg'))
    }

    It 'pins every reused action by the exact full SHA in the lock' {
        $lock=[IO.File]::ReadAllText((Join-Path $root 'locks\build.lock.json'))|ConvertFrom-Json
        $workflow=[IO.File]::ReadAllText((Join-Path $root '.github\workflows\build-release.yml'))
        $expected=@($lock.actions.checkout,$lock.actions.uploadArtifact,$lock.actions.downloadArtifact,$lock.actions.attestBuildProvenance)
        foreach($sha in $expected){$workflow|Should Match ([regex]::Escape('@'+$sha))}
        $uses=[regex]::Matches($workflow,'(?m)^\s*-?\s*uses:\s*[^@\s]+@(?<ref>[^\s]+)')
        foreach($use in $uses){$use.Groups['ref'].Value|Should Match '^[a-f0-9]{40}$'}
    }
}
