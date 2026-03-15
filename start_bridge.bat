@echo off
setlocal EnableDelayedExpansion

REM Aller dans le dossier du script (ou bridge.py et .env ne seront pas trouves)
cd /d "%~dp0"

set OBS=%USERPROFILE%\Zomboid\Lua\LLMBot_obs.json
set CMD=%USERPROFILE%\Zomboid\Lua\LLMBot_cmd.json

REM Verifier que Python et bridge.py existent
where python >nul 2>&1
if errorlevel 1 (
    echo [LLMBot] Erreur : Python introuvable. Ajoutez Python au PATH ou lancez depuis un terminal ou Anaconda.
    goto :fin
)
if not exist "bridge.py" (
    echo [LLMBot] Erreur : bridge.py introuvable dans %CD%
    goto :fin
)

REM Charger les cles API depuis .env (format: GEMINI_API_KEY=ta_cle sans espace autour du =)
if exist ".env" (
    for /f "usebackq eol=# tokens=1,* delims==" %%a in (".env") do (
        set "envkey=%%a"
        set "envkey=!envkey: =!"
        if not "!envkey!"=="" call set "!envkey!=%%b"
    )
    echo [LLMBot] Fichier .env charge.
    if defined GEMINI_API_KEY (echo [LLMBot] GEMINI_API_KEY presente.) else (echo [LLMBot] GEMINI_API_KEY absente dans .env - verifiez la ligne.)
) else (
    echo [LLMBot] Pas de fichier .env - definissez GEMINI_API_KEY ou ANTHROPIC_API_KEY.
)

echo [LLMBot] Demarrage du bridge (mode light)...
echo [LLMBot] obs = %OBS%
echo [LLMBot] cmd = %CMD%
echo [LLMBot] Pour logs detailles : bridge.py --full
echo.

python "%~dp0bridge.py" --obs "%OBS%" --cmd "%CMD%" --interval 1.0 --light

:fin
echo.
echo Appuyez sur une touche pour fermer cette fenetre...
pause >nul