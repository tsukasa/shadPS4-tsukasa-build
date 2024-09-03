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
    [String] $InstallDestination = "G:\Emulation\Emulators\shadPS4"
)

begin {
    # Enable Qt GUI
    $_enableQtGui = "ON"
    # Set the git branch to pull from (should be "main")
    $_gitBranch   = "main"
    # Set the git dirty suffix
    $_gitDirty    = "-${env:USERNAME}/bb-hacks"
    # Set the build and release directories, these should stay as-is
    $_buildDir    = Join-Path -Path $ShadPs4SourcePath -ChildPath "build"
    $_releaseDir  = Join-Path -Path $_buildDir -ChildPath $BuildType
    $_patchesDir  = Join-Path -Path $PSScriptRoot -ChildPath "patches"
}
process {
    Function Pull-ShadPs4 {
        if ($BuildOnly) {
            return
        }
    
        # Reset and update source-code
        & git fetch --prune --tags
        & git reset --hard
        & git clean -f -d
        & git checkout "${_gitBranch}"
        & git pull
        & git submodule update --init --force --recursive
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
                return
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
        # Get the current git description for versioning
        $gitDesc = & git describe --always --long --dirty="${_gitDirty}"
    
        "-- Build version: ${gitDesc}"
    
        # Now build shadPS4
        & cmake -S "${ShadPs4SourcePath}" -B "${_buildDir}" -DCMAKE_BUILD_TYPE="${BuildType}" -DGIT_DESC="${gitDesc}" -DCMAKE_PREFIX_PATH="${QtPath}" -T "ClangCL" -DENABLE_QT_GUI="${_enableQtGui}"
        & cmake --build "${_buildDir}" --config "${BuildType}" --parallel
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

    Push-Location -Path $ShadPs4SourcePath

    Pull-ShadPs4
    Patch-ShadPs4

    if ($PullAndPatch) {
        # Pull and patch only, exit here
        return
    }

    Clean-ShadPs4
    Build-ShadPs4

    # If the emulator needs to be installed, we should run windeployqt first!
    Install-ShadPs4
}
clean {
    Pop-Location
}
