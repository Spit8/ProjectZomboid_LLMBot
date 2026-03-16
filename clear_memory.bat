@echo off
setlocal

REM Memoire + obs = meme dossier que start_bridge.bat
set LUA_DIR=%USERPROFILE%\Zomboid\Lua
set MEMORY=%LUA_DIR%\LLMBot_memory.json
set OBS=%LUA_DIR%\LLMBot_obs.json
set CMD=%LUA_DIR%\LLMBot_cmd.json

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

if exist "%CMD%" (
    del "%CMD%"
    echo [LLMBot] CMD efface : %CMD%
) else (
    echo [LLMBot] Aucun fichier CMD : %CMD%
)

endlocal
