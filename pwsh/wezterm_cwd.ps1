# Publish the working folder to WezTerm at each prompt. Works in Windows
# PowerShell 5.1 and PowerShell 7. See ../wezterm/AGENTS.md for the protocol.
#
# Only `cwd` and `state_serial` are sent. Do not add `shell_integration` or
# `shell_prompt`: the WezTerm Esc and Ctrl-D actions rely on PowerShell
# publishing neither.

if (-not $env:WEZTERM_PANE -or $global:WezTermPrompt) { return }

$global:WezTermPrompt = $function:prompt
$global:WezTermSerial = 0

function global:prompt {
    $text = & $global:WezTermPrompt
    try {
        $esc = [char]27
        $bel = [char]7
        $osc7 = ''
        $path = $PWD.Path
        if ($PWD.Provider.Name -eq 'FileSystem') {
            $path = $PWD.ProviderPath
            # OSC 7 for WezTerm itself, in the form that Clink sends:
            # file:///C:/dir, and file:////server/share for a UNC path.
            $parts = $path.Replace('\', '/').Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }
            $uri = (($parts -join '/').Replace('%3A', ':')) -replace '^/', ''
            $osc7 = "$esc]7;file:///$uri$bel"
        }
        # Base64 is plain ASCII, so no code page can damage the path.
        $cwd = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($path))
        $global:WezTermSerial++
        $serial = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("ps:$PID`:$global:WezTermSerial"))
        # One write; state_serial goes last and commits the repaint.
        [Console]::Write("$osc7$esc]1337;SetUserVar=cwd=$cwd$bel$esc]1337;SetUserVar=state_serial=$serial$bel")
    } catch {
        # A prompt must never fail because of the status bar.
    }
    $text
}
