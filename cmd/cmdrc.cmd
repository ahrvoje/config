@echo off
REM echo off must be the first line for script not to leak any output (not even comments)
REM otherwise starship init will fail with error "starship.lua:1: attempt to call a nil value"

REM on some machines this file is referenced and run within wezterm_local.lua

REM make cd also change drives and expand ~ to the user home directory
doskey pwd=cd

doskey gb=git branch
doskey gc=git commit
doskey gd=git diff
doskey gs=git status

doskey log=jj log -r ::

REM set Unicode code page
chcp 65001 >nul
