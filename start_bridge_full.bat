@echo off
setlocal

set OBS=%USERPROFILE%\Zomboid\Lua\LLMBot_obs.json
set CMD=%USERPROFILE%\Zomboid\Lua\LLMBot_cmd.json

echo [LLMBot] Bridge en mode FULL (logs detailles)...
echo [LLMBot] obs = %OBS%
echo [LLMBot] cmd = %CMD%
echo.

python "%~dp0bridge.py" --obs "%OBS%" --cmd "%CMD%" --interval 2.5 --full

pause
