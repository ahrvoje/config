# Install wezterm_cwd.ps1 for the PowerShell version that runs this script
# (Windows PowerShell 5.1 or PowerShell 7). Start it with install_pwsh5.cmd
# or install_pwsh7.cmd.
#
# The script copies wezterm_cwd.ps1 from its own folder into the profile
# folder and adds one line to the profile. A second run changes nothing.

$ErrorActionPreference = 'Stop'

$name = 'wezterm_cwd.ps1'
$source = Join-Path $PSScriptRoot $name
$profilePath = $PROFILE.CurrentUserAllHosts
$profileDir = Split-Path $profilePath
$line = ". `"`$PSScriptRoot\$name`""

if (-not (Test-Path -LiteralPath $source)) {
    throw "$name must be in the same folder as this script: $PSScriptRoot"
}

New-Item -ItemType Directory -Force $profileDir | Out-Null
Copy-Item -LiteralPath $source -Destination $profileDir -Force

$text = ''
if (Test-Path -LiteralPath $profilePath) {
    $text = [IO.File]::ReadAllText($profilePath)  # '' for an empty file
}
if ($text.Contains($line)) {
    "Profile already loads ${name}: $profilePath"
} else {
    # Start on a new line if the profile does not end with one.
    $prefix = ''
    if ($text -ne '' -and -not $text.EndsWith("`n")) { $prefix = "`r`n" }
    Add-Content -LiteralPath $profilePath -Value ($prefix + $line)
    "Added to profile: $profilePath"
}
"Copied $name to: $profileDir"

# The policy of a normal start: the first defined scope, without the Process
# scope that -ExecutionPolicy sets for this run only.
$policy = Get-ExecutionPolicy -List |
    Where-Object { $_.Scope -ne 'Process' -and $_.ExecutionPolicy -ne 'Undefined' } |
    Select-Object -First 1
$effective = 'Restricted'
if ($policy) { $effective = [string]$policy.ExecutionPolicy }
if ($effective -in 'Restricted', 'AllSigned', 'Default') {
    Write-Warning "Execution policy is '$effective': PowerShell will not run the profile. See the README, section 'Execution policy'."
} else {
    "Execution policy is '$effective'. Open a new PowerShell tab in WezTerm."
}
