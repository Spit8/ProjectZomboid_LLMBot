@echo off
setlocal

set OBS=%USERPROFILE%\Zomboid\Lua\LLMBot_obs.json
set CMD=%USERPROFILE%\Zomboid\Lua\LLMBot_cmd.json

echo [LLMBot] Demarrage du bridge (mode light = une ligne par tick)...
echo [LLMBot] obs = %OBS%
echo [LLMBot] cmd = %CMD%
echo [LLMBot] Pour logs detailles: bridge.py --full
echo.

python "%~dp0bridge.py" --obs "%OBS%" --cmd "%CMD%" --interval 2.5 --light

pause