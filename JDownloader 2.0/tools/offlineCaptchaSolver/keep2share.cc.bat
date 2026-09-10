@echo off
cd /d "%~dp0"
call checkdeps.bat


set "file=result.txt"
if not "%~2"=="" set "file=%~2"

if exist "%file%" del "%file%"

node.exe ocr.js keep2share.cc %*
if errorlevel 1 (
    if exist "%file%" del "%file%"
    exit /b 1
)

if not exist "%file%" (
    exit /b 1
)

exit /b 0