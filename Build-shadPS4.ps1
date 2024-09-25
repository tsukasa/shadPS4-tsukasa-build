<#
    .SYNOPSIS
    This script will pull new changes from the shadPS4 repository,
    apply patches, build the emulator and optionally install it.
#>
[CmdletBinding(SupportsShouldProcess=$True)]
param
(
    # Path to the shadPS4 source code
    [Parameter(Mandatory=$False, Position=1)]
    [String] $ShadPs4SourcePath  = "${PSScriptRoot}\shadPS4",
    # Path to the Qt installation
    [Parameter(Mandatory=$False, Position=2)]
    [String] $QtPath             = "C:\Development\Qt\6.7.2\msvc2019_64",
    # Build type (Debug or Release)
    [Parameter(Mandatory=$False, Position=3)]
    [String] $BuildType          = "Release",
    # Clean the build directory before building
    [Parameter(Mandatory=$False, Position=4)]
    [Switch] $Clean,
    # Pull and patch only, do not build
    [Parameter(Mandatory=$False, Position=5)]
    [Switch] $PullAndPatch,
    # Build only, do not pull, patch or install
    [Parameter(Mandatory=$False, Position=6)]
    [Switch] $BuildOnly,
    # Install the emulator after building
    [Parameter(Mandatory=$False, Position=7)]
    [Switch] $Install,
    # Path to the installation destination where -Install should copy the emulator to
    [Parameter(Mandatory=$False, Position=8)]
    [String] $InstallDestination = "G:\Emulation\Emulators\shadPS4",
    # Disable multithreaded build
    [Parameter(Mandatory=$False, Position=9)]
    [Switch] $SingleThreadedBuild,
    # Enable patch
    [Parameter(Mandatory=$False, Position=10)]
    [String] $EnablePatch,
    # Disable patch
    [Parameter(Mandatory=$False, Position=11)]
    [String] $DisablePatch,
    # Commit
    [Parameter(Mandatory=$False, Position=12)]
    [String] $Commit,
    # Download a PR patch
    [Parameter(Mandatory=$False, Position=13)]
    [String] $DownloadPatch,
    # Specifies the configuration file to use for base commit and patches
    [Parameter(Mandatory=$False, Position=14)]
    [String] $ConfigFile,
    # Saves the current configuration
    [Parameter(Mandatory=$False, Position=15)]
    [String] $SaveConfig
)

begin {
    # Enable Qt GUI
    $_enableQtGui   = "ON"
    # Set the git branch to pull from (should be "main")
    $_gitBranch     = "main"
    # Set the git dirty suffix
    $_gitDirty      = "-${env:USERNAME}"
    # GitHub user/repo to the shadPS4 repository
    $_githubRepo    = "shadps4-emu/shadPS4"
    # Set the build and release directories, these should stay as-is
    $_buildDirName  = "build"
    $_buildDir      = Join-Path -Path $ShadPs4SourcePath -ChildPath $_buildDirName
    $_releaseDir    = Join-Path -Path $_buildDir -ChildPath $BuildType
    $_patchesDir    = Join-Path -Path $PSScriptRoot -ChildPath "patches"
    $_configDir     = Join-Path -Path $PSScriptRoot -ChildPath "config"

    $_currentCommit  = $_gitBranch
    $_currentPatches = @()
    $_currentReverts = @()
}
process {
    Function Pull-ShadPs4 {
        param(
            [String] $Branch
        )

        if ($BuildOnly) {
            return
        }
    
        # Set the branch or commit to pull from
        $branchOrCommit = $_gitBranch

        if ($Branch) {
            $branchOrCommit = $Branch
        }

        # Keep result polution to a minimum..
        . {
            # Reset and update source-code
            Write-Host "-- Git fetch"
            & git fetch --prune --tags
            Write-Host "-- Git reset"
            & git reset --hard
            Write-Host "-- Git clean"
            & git clean -f -d -e "${_buildDirName}/"
            Write-Host "-- Git checkout ${branchOrCommit}"
            & git checkout "${branchOrCommit}"
            
            # Make sure we are on a branch if we want to pull...
            $currentBranch = & git branch --show-current

            if ($currentBranch) {
                Write-Host "-- Pulling ${currentBranch}..."
                & git pull "origin" "${currentBranch}"
                
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "-- Failed to pull ${currentBranch}"
                    exit 1
                }
            }

            Write-Host "-- Updating submodules..."
            & git submodule update --init --force --recursive
        } | Out-Null

        return $branchOrCommit
    }

    Function Revert-Commits {
        param(
            [String[]] $RevertCommits
        )


        [String[]] $revertedCommits = @()

        if ($RevertCommits) {
            $commits = $RevertCommits
        } else {
            if (Test-Path -Path "${_configDir}\revert-commits.txt") {
                $commits = Get-Content -Path "${_configDir}\revert-commits.txt"
            }
        }

        foreach($commit in $commits) {
            $commit = $commit.Trim()
            # Ignore comments
            if ($commit.StartsWith("#")) {
                continue
            }
            # Ignore empty lines
            if ($commit -eq "") {
                continue
            }
            Write-Host "-- Reverting commit: ${commit}"
            & git revert --no-edit --no-commit $commit

            if ($LASTEXITCODE -ne 0) {
                Write-Host "-- Failed to revert commit ${commit}"
                exit 1
            }

            # Add the reverted commit to the list
            $revertedCommits += $commit

            Write-Host "-- Resetting to unstage..."
            & git reset HEAD | Out-Null
        }

        return $revertedCommits
    }

    Function Enable-Patch {
        if (-not $EnablePatch) {
            return
        }

        $patches = Get-ChildItem -Path $_patchesDir -Filter "*.patch.disabled"

        foreach($patch in $patches) {
            if ($patch.Name.Contains($EnablePatch)) {
                $patchName = $patch.Name
                Rename-Item -Path $patch.FullName -NewName $patch.Name.Replace(".patch.disabled", ".patch")
                Write-Host "-- Enabled patch: ${patchName}"
            }
        }

        Exit 0
    }

    Function Disable-Patch {
        if (-not $DisablePatch) {
            return
        }

        $patches = Get-ChildItem -Path $_patchesDir -Filter "*.patch"

        foreach($patch in $patches) {
            if ($patch.Name.Contains($DisablePatch)) {
                $patchName = $patch.Name
                Rename-Item -Path $patch.FullName -NewName $patch.Name.Replace(".patch", ".patch.disabled")
                Write-Host "-- Disabled patch: ${patchName}"
            }
        }

        Exit 0
    }

    Function Get-PrDetails {
        param(
            [int] $PullRequest
        )

        $ghPrStatus = & gh api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "repos/${_githubRepo}/pulls/${prId}" | ConvertFrom-Json

        return $ghPrStatus
    }

    Function Update-PrPatches {
        if ($BuildOnly) {
            return
        }
    
        $patches = Get-ChildItem -Path $_patchesDir -Filter *.patch

        foreach($patch in $patches) {
            $patchName = $patch.Name

            if ($patchName -notmatch "^(\d+)_pr-(\d+)(.*)\.patch$") {
                continue
            }

            $fileId   = $Matches[1]
            $fileDesc = $Matches[3]
            $prId     = $Matches[2]

            # Use gh cli to get more details about the PR, for instance if it has been merged.
            $ghPrStatus = Get-PrDetails -PullRequest $prId

            # If the PR details could not be fetched, skip this patch
            if ($LASTEXITCODE -ne 0) {
                Write-Host "-- Failed to get PR details for PR #${prId}: ${patchName}"
                continue
            }

            # If the PR is not open, delete the patch
            if ($ghPrStatus.state -ne "open") {
                Write-Host "-- PR #${prId} not open, deleting patch: ${patchName}"
                Remove-Item -Path $patch.FullName
                continue
            }

            Write-Host "-- Updating patch for PR #${prId}: $($ghPrStatus.title)"
            Invoke-WebRequest -Uri "$($ghPrStatus.patch_url)" -Method Get -OutFile "${_patchesDir}\${fileId}_pr-${prId}${fileDesc}.patch"
        }
    }

    Function Patch-ShadPs4 {
        param(
            [String[]] $Patches
        )

        if ($BuildOnly) {
            return
        }

        [String[]] $usedPatches = @()        

        $patchFiles = Get-ChildItem -Path $_patchesDir -Filter *.patch

        foreach($patch in $patchFiles) {
            $patchName = $patch.Name

            if ($Patches -and $Patches -notcontains $patchName) {
                Write-Host "-- Skipping patch: ${patchName}"
                continue
            }

            Write-Host "-- Applying patch: ${patchName}"
            & git apply $patch.FullName

            if ($LASTEXITCODE -ne 0) {
                Write-Host "-- Patch failed: ${patchName}"
                exit 1
            }

            $usedPatches += $patchName
        }

        return $usedPatches
    }
    
    Function Clean-ShadPs4 {
        if (-not $Clean) {
            return
        }
    
        & cmake --build "${_buildDir}" --target "clean"
    }
    
    Function Build-ShadPs4 {
        param(
            [Switch] $MultiToolTask
        )

        # Get the current git description for versioning
        $gitDesc = & git describe --always --long --dirty="${_gitDirty}"
    
        Write-Host "-- Build version: ${gitDesc}"

        $buildStart = Get-Date

        # Now build shadPS4
        & cmake -S "${ShadPs4SourcePath}" -B "${_buildDir}" -DCMAKE_BUILD_TYPE="${BuildType}" -DGIT_DESC="${gitDesc}" -DCMAKE_PREFIX_PATH="${QtPath}" -T "ClangCL" -DENABLE_QT_GUI="${_enableQtGui}"

        if ($MultiToolTask) {
            & cmake --build "${_buildDir}" --config "${BuildType}" -- "/p:UseMultiToolTask=true"
        } else {
            & cmake --build "${_buildDir}" --config "${BuildType}" --parallel
        }

        $buildEnd = Get-Date

        Write-Host "-- Build time: $([math]::Round(($buildEnd - $buildStart).TotalMinutes, 2)) minutes"
    }
    
    Function Download-Patch {
        if (-not $DownloadPatch) {
            return
        }

        Write-Host "-- Downloading patch for PR #${DownloadPatch}..."
        $patchUrl = "https://github.com/${_githubRepo}/pull/${DownloadPatch}.patch"
        Invoke-WebRequest -Uri $patchUrl -Method Get -OutFile "${_patchesDir}\010_pr-${DownloadPatch}.patch"

        Exit 0
    }

    Function Load-Configuration {
        param (
            [String] $ConfigFile
        )

        begin {
            Push-Location -Path $PSScriptRoot
        }

        process {
            if (-not $ConfigFile) {
                return
            }
    
            $ConfigFile = Resolve-Path -Path $ConfigFile
    
            if (-not (Test-Path -Path $ConfigFile)) {
                Write-Host "-- Configuration file not found: ${ConfigFile}"
                return
            }
    
            $config = Get-Content -Path $ConfigFile | ConvertFrom-Json
            return $config
        }

        clean {
            Pop-Location
        }
    }

    Function Save-Configuration {
        param (
            [String] $BranchOrCommit,
            [String[]] $Patches,
            [String[]] $Reverts,
            [String] $Filename
        )

        begin {
            Push-Location -Path $PSScriptRoot
        }

        process {
            $Filename = [System.IO.Path]::GetFullPath($Filename)

            if (-not $Filename) {
                return
            }
    
            $config = @{
                "commit" = $BranchOrCommit
                "patches" = $Patches
                "reverts" = $Reverts
            }

            Write-Host "-- Saving configuration to: ${Filename}"
            $config | ConvertTo-Json | Set-Content -Path $Filename
        }

        clean {
            Pop-Location
        }
    }

    Function Install-ShadPs4 {
        if (-not $Install) {
            return
        }
    
        Write-Host "-- Running WinDeployQt..."
        & "${QtPath}\bin\windeployqt.exe" "${_releaseDir}\shadps4.exe"
    
        Write-Host "-- Copying shadPS4 to `"${InstallDestination}`"..."
        Copy-Item -Path "${_releaseDir}\*" -Destination "${InstallDestination}" -Recurse -Force    
    }

    if (-not (Test-Path -Path $ShadPs4SourcePath)) {
        & git clone "git@github.com:${_githubRepo}.git" "${ShadPs4SourcePath}"
    }

    If ($Commit) {
        $_gitBranch = $Commit
    }

    If ($ConfigFile) {
        $ConfigFile = Resolve-Path -Path $ConfigFile
        If (-not (Test-Path -Path $ConfigFile)) {
            Write-Host "-- Configuration file not found: ${ConfigFile}"
            exit 1
        }
        
        Write-Host "-- Using configuration file: ${ConfigFile}"
    }

    Push-Location -Path $ShadPs4SourcePath

    Download-Patch
    Enable-Patch
    Disable-Patch

    $config = Load-Configuration -ConfigFile $ConfigFile

    $_currentBranch = Pull-ShadPs4 -Branch $config.commit
    $_currentReverts = Revert-Commits -RevertCommits $config.reverts
    Update-PrPatches
    $_currentPatches = Patch-ShadPs4 -Patches $config.patches

    Save-Configuration -BranchOrCommit $_currentBranch -Patches $_currentPatches -Reverts $_currentReverts -Filename "${PSScriptRoot}/current.json"

    if ($PullAndPatch) {
        # Pull and patch only, exit here
        exit 0
    }

    Clean-ShadPs4
    Build-ShadPs4 -MultiToolTask:(-not $SingleThreadedBuild)

    # If the emulator needs to be installed, we should run windeployqt first!
    Install-ShadPs4
}
clean {
    Pop-Location
}
