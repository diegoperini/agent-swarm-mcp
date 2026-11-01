@echo off
rem Opens the swarm's web view: focuses the running swarm's window, or starts the
rem swarm (without an MCP client) when none is running. Close this console window
rem only after you close the web view: the swarm runs inside it in that case.
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0mcp-server.ps1" open
exit /b %ERRORLEVEL%
