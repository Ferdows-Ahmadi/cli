# SPDX-License-Identifier: Apache-2.0

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $Version,
    [ValidateNotNullOrEmpty()]
    [string] $InstallDir,
    [ValidateNotNullOrEmpty()]
    [string] $ReleaseDirectory
)

# Dot-sourcing only defines the implementation for offline fixture tests.
function Install-Proofline {
    [CmdletBinding()]
    param(
        [string] $Version,
        [ValidateNotNullOrEmpty()]
        [string] $InstallDir = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Proofline', 'bin'),
        [ValidateNotNullOrEmpty()]
        [string] $ReleaseDirectory
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    # Handle native tool exit codes explicitly in both Windows PowerShell and PowerShell 7.
    $PSNativeCommandUseErrorActionPreference = $false
    $archiveName = 'proofline-x86_64-pc-windows-msvc.tar.gz'
    $versionNumber = '[0-9]+\.[0-9]+\.[0-9]+'

    function Save-ReleaseFile([string] $Url, [string] $File) {
        & $curl --disable --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent `
            --show-error --location --connect-timeout 15 --max-time 180 --output $File -- $Url
        if ($LASTEXITCODE -ne 0) {
            throw "Could not download $Url. Nothing was installed."
        }
    }

    function Get-ExpectedHash([string] $File) {
        $name = [Regex]::Escape($archiveName)
        $hashes = @(
            foreach ($line in Get-Content -LiteralPath $File) {
                if ($line -cmatch "^([0-9a-fA-F]{64})[ \t]+\*?${name}\z") {
                    $Matches[1]
                }
            }
        )
        if ($hashes.Count -ne 1) {
            throw "SHA256SUMS must contain exactly one valid checksum for $archiveName."
        }
        return $hashes[0]
    }

    if ($PSBoundParameters.ContainsKey('Version') -and $Version -cnotmatch "^v?${versionNumber}\z") {
        throw 'Use a release version such as 0.3.9 or v0.3.9.'
    }
    if ($ReleaseDirectory -and $PSBoundParameters.ContainsKey('Version')) {
        throw 'Use either -Version or -ReleaseDirectory, not both.'
    }

    $tarName = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'tar.exe' } else { 'tar' }
    $tar = (Get-Command $tarName -CommandType Application -TotalCount 1).Source
    $destinationDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $InstallDir
    )
    $destination = Join-Path $destinationDir 'proofline.exe'
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("proofline-download-" + [Guid]::NewGuid())
    $staged = $null
    $backup = $null
    $keepBackup = $false
    try {
        [void] [System.IO.Directory]::CreateDirectory($work)
        $archive = Join-Path $work $archiveName
        $checksums = Join-Path $work 'SHA256SUMS'
        if ($ReleaseDirectory) {
            Copy-Item -LiteralPath (Join-Path $ReleaseDirectory $archiveName) -Destination $archive
            Copy-Item -LiteralPath (Join-Path $ReleaseDirectory 'SHA256SUMS') -Destination $checksums
            $label = 'from local release files'
        } else {
            $curlName = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'curl.exe' } else { 'curl' }
            $curl = (Get-Command $curlName -CommandType Application -TotalCount 1).Source
            if (-not $Version) {
                $metadata = Join-Path $work 'release.json'
                Save-ReleaseFile 'https://api.github.com/repos/prooflinedev/cli/releases/latest' $metadata
                $Version = (Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json).tag_name
                if ($Version -isnot [string] -or $Version -cnotmatch "^v${versionNumber}\z") {
                    throw 'GitHub did not return a valid Proofline release tag.'
                }
            }
            $tag = 'v' + ($Version -creplace '^v', '')
            $release = "https://github.com/prooflinedev/cli/releases/download/$tag"
            Save-ReleaseFile "$release/SHA256SUMS" $checksums
            Save-ReleaseFile "$release/$archiveName" $archive
            $label = $tag
        }

        $expected = Get-ExpectedHash $checksums
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash
        if ($expected -ne $actual) {
            throw 'The archive does not match SHA256SUMS. Nothing was installed.'
        }

        # Official archives contain one root-level executable; extract nothing else.
        $entries = @(& $tar -tzf $archive)
        if ($LASTEXITCODE -ne 0 -or $entries.Count -ne 1 -or $entries[0] -cne 'proofline.exe') {
            throw "$archiveName must contain only the root-level proofline.exe."
        }
        & $tar -xzf $archive -C $work -- proofline.exe
        if ($LASTEXITCODE -ne 0) {
            throw "Could not extract proofline.exe from $archiveName."
        }
        $candidate = Get-Item -LiteralPath (Join-Path $work 'proofline.exe') -Force
        if ($candidate.PSIsContainer -or $candidate.Length -eq 0 -or
            ($candidate.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw 'The archive did not contain a nonempty regular proofline.exe.'
        }

        [void] [System.IO.Directory]::CreateDirectory($destinationDir)
        $stem = ".proofline-" + [Guid]::NewGuid()
        $staged = Join-Path $destinationDir "$stem.tmp"
        $backup = Join-Path $destinationDir "$stem.bak"
        [System.IO.File]::Copy($candidate.FullName, $staged)
        try {
            if ([System.IO.File]::Exists($destination)) {
                [System.IO.File]::Replace($staged, $destination, $backup)
            } else {
                [System.IO.File]::Move($staged, $destination)
            }
        } catch {
            if ([System.IO.File]::Exists($backup)) {
                try {
                    # On a failed replacement keep the original, including after a partial OS error.
                    if ([System.IO.File]::Exists($destination)) {
                        [System.IO.File]::Replace($backup, $destination, [NullString]::Value)
                    } else {
                        [System.IO.File]::Move($backup, $destination)
                    }
                } catch {
                    $keepBackup = $true
                    throw "Could not restore the previous executable. It is backed up at $backup."
                }
            }
            throw "Could not replace $destination. Close running Proofline processes and check folder permissions, then retry."
        }

        Write-Output "Installed Proofline $label at $destination"
        Write-Output 'PATH was not changed. Use the full path or add the install directory to your user PATH yourself.'
    } finally {
        foreach ($path in @($staged, $backup)) {
            if ($path -and -not ($keepBackup -and $path -eq $backup)) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        $architecture -ne 'AMD64') {
        throw 'This installer supports Windows x64 only.'
    }
    Install-Proofline @PSBoundParameters
}
