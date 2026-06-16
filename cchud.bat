@echo off
rem cchud - Claude Code Heads-Up Display (Windows: double-click to launch)
cd /d "%~dp0"

where Rscript >nul 2>nul
if %errorlevel%==0 (
  Rscript run.R
  if errorlevel 1 pause
  goto :eof
)

set "RSCRIPT="
for /d %%D in ("%ProgramFiles%\R\R-*") do set "RSCRIPT=%%D\bin\Rscript.exe"
if defined RSCRIPT if exist "%RSCRIPT%" (
  "%RSCRIPT%" run.R
  if errorlevel 1 pause
  goto :eof
)

echo Rscript not found. Install R from https://cran.r-project.org/ and ensure it is on PATH.
pause
