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
    [String] $Commit
)

begin {
    # Enable Qt GUI
    $_enableQtGui   = "ON"
    # Set the git branch to pull from (should be "main")
    $_gitBranch     = "main"
    # Set the git dirty suffix
    $_gitDirty      = "-${env:USERNAME}/bb-hacks"
    # GitHub user/repo to the shadPS4 repository
    $_githubRepo    = "shadps4-emu/shadPS4"
    # Set the build and release directories, these should stay as-is
    $_buildDirName  = "build"
    $_buildDir      = Join-Path -Path $ShadPs4SourcePath -ChildPath $_buildDirName
    $_releaseDir    = Join-Path -Path $_buildDir -ChildPath $BuildType
    $_patchesDir    = Join-Path -Path $PSScriptRoot -ChildPath "patches"
    $_configDir     = Join-Path -Path $PSScriptRoot -ChildPath "config"
}
process {
    Function Pull-ShadPs4 {
        if ($BuildOnly) {
            return
        }
    
        # Reset and update source-code
        "-- Git fetch"
        & git fetch --prune --tags
        "-- Git reset"
        & git reset --hard
        "-- Git clean"
        & git clean -f -d -e "${_buildDirName}/"
        "-- Git checkout ${_gitBranch}"
        & git checkout "${_gitBranch}"
        
        # Make sure we are on a branch if we want to pull...
        $currentBranch = & git branch --show-current
        if ($currentBranch) {
            "-- Pulling ${currentBranch}..."
            & git pull "origin" "${currentBranch}"
        }

        "-- Updating submodules..."
        & git submodule update --init --force --recursive
    }

    Function Revert-Commits {
        if (Test-Path -Path "${_configDir}\revert-commits.txt") {
            $commits = Get-Content -Path "${_configDir}\revert-commits.txt"

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
                "-- Reverting commit: ${commit}"
                & git revert --no-edit --no-commit $commit

                if ($LASTEXITCODE -ne 0) {
                    "-- Failed to revert commit ${commit}"
                    exit 1
                }

                "-- Resetting to unstage..."
                & git reset HEAD | Out-Null
            }
        }
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
                "-- Enabled patch: ${patchName}"
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
                "-- Disabled patch: ${patchName}"
            }
        }

        Exit 0
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
            $ghPrStatus = & gh api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "repos/${_githubRepo}/pulls/${prId}" | ConvertFrom-Json

            # If the PR details could not be fetched, skip this patch
            if ($LASTEXITCODE -ne 0) {
                "-- Failed to get PR details for PR #${prId}: ${patchName}"
                continue
            }

            # If the PR is not open, delete the patch
            if ($ghPrStatus.state -ne "open") {
                "-- PR #${prId} not open, deleting patch: ${patchName}"
                Remove-Item -Path $patch.FullName
                continue
            }

            "-- Updating patch for PR #${prId}: $($ghPrStatus.title)"
            Invoke-WebRequest -Uri "$($ghPrStatus.patch_url)" -Method Get -OutFile "${_patchesDir}\${fileId}_pr-${prId}${fileDesc}.patch"
        }
    }

    Function Patch-ShadPs4 {
        if ($BuildOnly) {
            return
        }
    
        $patches = Get-ChildItem -Path $_patchesDir -Filter *.patch

        foreach($patch in $patches) {
            $patchName = $patch.Name

            "-- Applying patch: ${patchName}"
            & git apply $patch.FullName

            if ($LASTEXITCODE -ne 0) {
                "-- Patch failed: ${patchName}"
                exit 1
            }
        }
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
    
        "-- Build version: ${gitDesc}"

        $buildStart = Get-Date

        # Now build shadPS4
        & cmake -S "${ShadPs4SourcePath}" -B "${_buildDir}" -DCMAKE_BUILD_TYPE="${BuildType}" -DGIT_DESC="${gitDesc}" -DCMAKE_PREFIX_PATH="${QtPath}" -T "ClangCL" -DENABLE_QT_GUI="${_enableQtGui}"

        if ($MultiToolTask) {
            & cmake --build "${_buildDir}" --config "${BuildType}" -- "/p:UseMultiToolTask=true"
        } else {
            & cmake --build "${_buildDir}" --config "${BuildType}" --parallel
        }

        $buildEnd = Get-Date

        "-- Build time: $([math]::Round(($buildEnd - $buildStart).TotalMinutes, 2)) minutes"
    }
    
    Function Install-ShadPs4 {
        if (-not $Install) {
            return
        }
    
        "-- Running WinDeployQt..."
        & "${QtPath}\bin\windeployqt.exe" "${_releaseDir}\shadps4.exe"
    
        "-- Copying shadPS4 to `"${InstallDestination}`"..."
        Copy-Item -Path "${_releaseDir}\*" -Destination "${InstallDestination}" -Recurse -Force    
    }

    if (-not (Test-Path -Path $ShadPs4SourcePath)) {
        & git clone "git@github.com:shadps4-emu/shadPS4.git" "${ShadPs4SourcePath}"
    }

    If ($Commit) {
        $_gitBranch = $Commit
    }

    Push-Location -Path $ShadPs4SourcePath

    Enable-Patch
    Disable-Patch

    Pull-ShadPs4
    Revert-Commits
    Update-PrPatches
    Patch-ShadPs4

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
