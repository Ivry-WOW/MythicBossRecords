@echo off
rem Mythic Boss Records - tools. Double-click for the menu.
rem   1 = automatic: every minute it checks for a new version, every 15 minutes it reads your new combat log;
rem       nothing to do after that.
setlocal
cd /d "%~dp0"
set "TASK=MythicBossRecords Tools"
if not exist "%~dp0MythicBossRecords.toc" (
  echo This file must stay inside the MythicBossRecords addon folder:
  echo   ...\Interface\AddOns\MythicBossRecords\
  pause
  exit /b 1
)

:menu
cls
echo  Mythic Boss Records - tools
echo  ===========================
echo.
schtasks /Query /TN "%TASK%" >nul 2>&1 && (echo  Automatic import + updates: ON) || (echo  Automatic import + updates: off)
echo.
echo   1. Turn on automatic (addon updates every minute, combat log every 15 minutes)
echo   2. Import my combat log now
echo   3. Update the addon now
echo   4. Read my whole combat log again (from the start)
echo   5. Turn off automatic
echo   6. Exit
echo.
choice /C 123456 /N /M " Choose 1-6: "
if errorlevel 6 exit /b 0
if errorlevel 5 goto uninstall
if errorlevel 4 (call :run import -FromStart & pause & goto menu)
if errorlevel 3 goto update
if errorlevel 2 (call :run import & pause & goto menu)

:install
echo.
echo Reading your combat log (the first time can take a few minutes)...
call :run auto
schtasks /Create /F /TN "%TASK%" /SC MINUTE /MO 1 /TR "wscript.exe \"%~dp0Tools\run-hidden.vbs\"" >nul
if errorlevel 1 (echo Could not create the scheduled task. & pause & goto menu)
schtasks /Create /F /TN "%TASK% (logon)" /SC ONLOGON /TR "wscript.exe \"%~dp0Tools\run-hidden.vbs\"" >nul 2>&1
echo.
echo Done. From now on: update check every minute, combat log every 15 minutes. In WoW: /reload or log in to load new data.
pause
goto menu

:update
call :run update
if exist "%~dp0MBR Tools.cmd.new" (echo. & echo Updated. Run "MBR Tools.cmd" again for the new menu. & pause & move /y "%~dp0MBR Tools.cmd.new" "%~dp0MBR Tools.cmd" >nul & exit /b 0)
pause
goto menu

:uninstall
schtasks /Delete /F /TN "%TASK%" >nul 2>&1
schtasks /Delete /F /TN "%TASK% (logon)" >nul 2>&1
echo Automatic import + updates turned off.
pause
goto menu

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Tools\MBR-Tools.ps1" -Action %*
exit /b 0
