[CmdletBinding(SupportsShouldProcess=$True)]
param
(
    [String] $ShadPs4SourcePath  = "${PSScriptRoot}\shadPS4",
    [String] $QtPath             = "C:\Development\Qt\6.7.2\msvc2019_64",
    [String] $InstallDestination = "G:\Emulation\Emulators\shadPS4",
    [String] $BuildType          = "Release",
    [Switch] $Clean,
    [Switch] $PullAndPatch,
    [Switch] $Build,
    [Switch] $Install
)

begin {
    $_enableQtGui = "ON"
    $_gitBranch   = "main"
    $_gitDirty    = "-${env:USERNAME}/bb-hacks"
    $_buildDir    = Join-Path -Path $ShadPs4SourcePath -ChildPath "build"
    $_releaseDir  = Join-Path -Path $_buildDir -ChildPath $BuildType
}
process {
    if (-not (Test-Path -Path $ShadPs4SourcePath)) {
        & git clone "git@github.com:shadps4-emu/shadPS4.git" "${ShadPs4SourcePath}"
    }

    Push-Location -Path $ShadPs4SourcePath

    # Reset and update source-code
    & git fetch --prune --tags
    & git reset --hard
    & git checkout "${_gitBranch}"
    & git pull
    & git submodule update --init --force --recursive

    # Apply patch to make versioning configurable
    "-- Applying tsukasa's CMakeList patch..."
    & git apply "${PSScriptRoot}\shadPS4-cmake.patch"

    # Apply patch to not show main window if a bin file is being passed as arg
    "-- Applying tsukasa's main_window patch..."
    & git apply "${PSScriptRoot}\shadPS4-hidemainwindow.patch"

    # Apply "official" bb-hacks patch
    "-- Applying bb-hacks patch..."
    & git apply "${PSScriptRoot}\shadPS4-bb-hacks.patch"

    # Apply Pino's collected community bb-hacks patch
    "-- Applying Pino's community bb-hacks patch..."
    & git apply "${PSScriptRoot}\shadPS4-bb-hacks-pino.patch"

    if ($PullAndPatch) {
        # Pull and patch only, exit here
        return
    }

    if ($Clean) {
        & cmake --build "${_buildDir}" --target "clean"
    }

    # Get the current git description for versioning
    $gitDesc = & git describe --always --long --dirty="${_gitDirty}"

    "-- Build version: ${gitDesc}"

    # Now build shadPS4
    & cmake -S "${ShadPs4SourcePath}" -B "${_buildDir}" -DCMAKE_BUILD_TYPE="${BuildType}" -DGIT_DESC="${gitDesc}" -DCMAKE_PREFIX_PATH="${QtPath}" -T "ClangCL" -DENABLE_QT_GUI="${_enableQtGui}"
    & cmake --build "${_buildDir}" --config "${BuildType}" --parallel

    # If the emulator needs to be installed, we should run windeployqt first!
    if ($Install) {
        "-- Running WinDeployQt..."
        & "${QtPath}\bin\windeployqt.exe" "${_releaseDir}\shadps4.exe"

        "-- Copying shadPS4 to `"${InstallDestination}`"..."
        Copy-Item -Path "${_releaseDir}\*" -Destination "${InstallDestination}" -Recurse -Force
    }
}
clean {
    Pop-Location
}
