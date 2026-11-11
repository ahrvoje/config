# PowerShell: working folder in the WezTerm status

`wezterm_cwd.ps1` sends the working folder to WezTerm at each prompt. It
serves Windows PowerShell 5.1 and PowerShell 7 and does nothing outside
WezTerm.

## Install

Keep all files of this folder together; the folder can be anywhere. Run the
install script of each PowerShell version that you use:

| Version                | Script              |
|------------------------|---------------------|
| Windows PowerShell 5.1 | `install_pwsh5.cmd` |
| PowerShell 7           | `install_pwsh7.cmd` |

Each script runs `install.ps1` in its PowerShell version. `install.ps1`
copies `wezterm_cwd.ps1` into the profile folder of that version, adds one
line to the profile and reports the execution policy. A second run changes
nothing.

Open a new PowerShell tab in WezTerm. The folder shows in the right status.

If the profile sets its own prompt (oh-my-posh, starship), keep the added
line after it.

## Execution policy

A profile is a script. PowerShell must be allowed to run local scripts. The
default policy of Windows PowerShell 5.1 is `Restricted`: no script runs, and
no profile. Allow local scripts for your user:

```powershell
Get-ExecutionPolicy -List
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

`RemoteSigned` runs local scripts and refuses unsigned downloaded ones. It
needs no administrator rights. PowerShell 5.1 and PowerShell 7 keep separate
policies; set each one in its own shell.

If `MachinePolicy` or `UserPolicy` shows a value, Group Policy controls the
setting: the command has no effect and the install scripts cannot run. Then,
or to keep `Restricted`, load the script as text from the WezTerm launch menu
entry instead; no profile is necessary. Replace `<folder>` with the full path
of the folder that contains the script, and use `pwsh.exe` for PowerShell 7:

```lua
{
  label = 'PowerShell 5',
  args = { 'powershell.exe', '-NoLogo', '-NoExit', '-Command',
    'Invoke-Expression (Get-Content -Raw "<folder>/wezterm_cwd.ps1")' },
},
```

This covers only the tabs that start from that entry.
