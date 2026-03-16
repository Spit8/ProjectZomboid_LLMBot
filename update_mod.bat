@echo off
REM Adapter MOD_DIR selon votre installation (dossier du mod LLMBot dans Zomboid/Workshop ou mods)
set MOD_DIR=%USERPROFILE%\Zomboid\Workshop\LLMBot\Contents\mods\LLMBot\42\media\lua
if not exist "%MOD_DIR%\client" (
    echo [LLMBot] Dossier introuvable : %MOD_DIR%\client
    echo Modifiez MOD_DIR dans ce script pour pointer vers votre dossier de mod.
    pause
    exit /b 1
)
copy /Y "%~dp0LLMBot_Client.lua" "%MOD_DIR%\client\"
copy /Y "%~dp0LLMBot_Shared.lua" "%MOD_DIR%\shared\"
echo Done.