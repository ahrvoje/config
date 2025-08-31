:: setting for cmd.exe AutoRun
:: injects clink and calls script cmdrc.cmd which can contain more init actions
:: to start cmd.exe avoiding this autorun start it with cmd.exe /d

:: IMPORTANT! setting this autorun will cause every shell start to run this initialization, even apps internal system shell calls
:: for this reason do not consider this setup a usual default configuration, I do not use it on any of my machines

:: per user
reg add "HKCU\Software\Microsoft\Command Processor" /v AutoRun /t REG_EXPAND_SZ /d "clink inject -q & if exist ""%USERPROFILE%\cmdrc.cmd"" (call ""%USERPROFILE%\cmdrc.cmd"")" /f

:: all users (entire machine)
:: reg add "HKLM\Software\Microsoft\Command Processor" /v AutoRun /t REG_EXPAND_SZ /d "clink inject -q & if exist ""%USERPROFILE%\cmdrc.cmd"" (call ""%USERPROFILE%\cmdrc.cmd"")" /f
