@echo off
setlocal

REM Memoire + obs = meme dossier que start_bridge.bat
set LUA_DIR=%USERPROFILE%\Zomboid\Lua
set MEMORY=%LUA_DIR%\LLMBot_memory.json
set OBS=%LUA_DIR%\LLMBot_obs.json

if exist "%MEMORY%" (
    del "%MEMORY%"
    echo [LLMBot] Memoire effacee : %MEMORY%
) else (
    echo [LLMBot] Aucun fichier memoire : %MEMORY%
)

if exist "%OBS%" (
    del "%OBS%"
    echo [LLMBot] Obs efface : %OBS%
) else (
    echo [LLMBot] Aucun fichier obs : %OBS%
)

endlocal
