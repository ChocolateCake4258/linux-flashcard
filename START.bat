@echo off
call "%~dp0win\build-all.bat" %*
exit /b %errorlevel%
