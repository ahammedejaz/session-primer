@echo off
rem session-primer — Windows convenience wrapper. Double-click, or run from
rem cmd/PowerShell; it opens Git Bash and runs the guided ./setup.sh there.
setlocal
set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"
if not exist "%BASH%" (
    echo Git for Windows is required ^(it provides Git Bash^): https://git-scm.com/download/win
    if "%~1"=="" pause
    exit /b 1
)
"%BASH%" -lc "cd \"$(cygpath -u '%~dp0')\" && ./setup.sh %*"
set "RC=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %RC%
