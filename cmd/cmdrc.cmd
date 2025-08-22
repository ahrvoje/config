@echo off
REM echo off must on the first line for script not to leak any output (not even comments)
REM otherwise starship init will fail with error "starship.lua:1: attempt to call a nil value"

REM make cd also change drives when needed
doskey cd=cd /d $*

REM set Unicode code page
chcp 65001 >nul
