@echo off
setlocal

set OBS=%USERPROFILE%\Zomboid\Lua\LLMBot_obs.json
set CMD=%USERPROFILE%\Zomboid\Lua\LLMBot_cmd.json

REM Pour utiliser Gemini : definissez GEMINI_API_KEY (ex. set GEMINI_API_KEY=xxx)
REM Puis lancez avec --provider gemini ou laissez le bridge choisir automatiquement.

echo [LLMBot] Demarrage du bridge (mode light = une ligne par tick)...
echo [LLMBot] obs = %OBS%
echo [LLMBot] cmd = %CMD%
echo [LLMBot] Pour logs detailles: bridge.py --full
echo [LLMBot] Pour Gemini: set GEMINI_API_KEY=xxx puis bridge.py --provider gemini
echo.

python "%~dp0bridge.py" --obs "%OBS%" --cmd "%CMD%" --interval 2.5 --light

pause