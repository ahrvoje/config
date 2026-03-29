@echo off
REM echo off must on the first line for script not to leak any output (not even comments)
REM otherwise starship init will fail with error "starship.lua:1: attempt to call a nil value"

REM on some machines this file is referenced and run within wezterm_local.lua

REM make cd also change drives when needed
doskey cd=if "$*"=="" (chdir) else if "$1"=="/?" (chdir /?) else (chdir /d "$*")
doskey pwd=cd

doskey gb=git branch
doskey gc=git commit
doskey gd=git diff
doskey gs=git status

doskey log=jj log -r ::

REM set Unicode code page
chcp 65001 >nul
