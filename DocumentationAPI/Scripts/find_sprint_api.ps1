# find_sprint_api.ps1
# Cherche les APIs pour activer la course (sprint/run) dans les scripts Lua de Project Zomboid Build 42.
# Usage : powershell -ExecutionPolicy Bypass -File .\find_sprint_api.ps1 -PZPath "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid"

param(
    [string]$PZPath = "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid"
)

$luaDir = Join-Path $PZPath "media\lua"

if (-not (Test-Path $luaDir)) {
    Write-Error "Dossier Lua introuvable : $luaDir"
    exit 1
}

Write-Host "`n=== RECHERCHE APIs SPRINT/RUN dans $luaDir ===`n"

$keywords = @(
    "setRunning",
    "isRunning",
    "setSprinting",
    "isSprinting",
    "setWalkSpeed",
    "setMoveSpeed",
    "RunAnim",
    "runAnim",
    "canSprint",
    "tiredness",
    "Run\b",
    "Sprint\b",
    ":Run\(",
    ":Sprint\(",
    "WalkStyle",
    "walkStyle",
    "setMoving",
    "startRunning"
)

$results = @{}

foreach ($kw in $keywords) {
    $matches = Get-ChildItem -Path $luaDir -Recurse -Filter "*.lua" |
        Select-String -Pattern $kw -CaseSensitive:$false |
        Select-Object Filename, LineNumber, Line

    if ($matches) {
        $results[$kw] = $matches
    }
}

foreach ($kw in ($results.Keys | Sort-Object)) {
    Write-Host "---------- $kw ----------"
    foreach ($m in $results[$kw]) {
        Write-Host "  $($m.Filename):$($m.LineNumber)  $($m.Line.Trim())"
    }
    Write-Host ""
}
