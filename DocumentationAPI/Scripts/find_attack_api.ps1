# find_attack_api.ps1
# Cherche les APIs d'attaque dans les scripts Lua de Project Zomboid Build 42.
# Usage : .\find_attack_api.ps1 -PZPath "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid"

param(
    [string]$PZPath = "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid"
)

$luaDir = Join-Path $PZPath "media\lua"

if (-not (Test-Path $luaDir)) {
    Write-Error "Dossier Lua introuvable : $luaDir"
    Write-Host "Modifier -PZPath pour pointer vers le dossier d'installation de PZ."
    exit 1
}

Write-Host "`n=== RECHERCHE APIs ATTAQUE dans $luaDir ===`n"

# Mots-cles a chercher
$keywords = @(
    "ISAttackTimedAction",
    "ISSwingTimedAction",
    "ISDefendTimedAction",
    "attack_nearest",
    ":attack\b",
    "setAttacking",
    "SwingAnim",
    "doAttack",
    "performAttack",
    "meleeAttack",
    "HitCharacter",
    "startAttack",
    "ISCombat",
    "attackTarget"
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

if ($results.Count -eq 0) {
    Write-Host "Aucun resultat trouve. Verifier le chemin PZ."
    exit 0
}

foreach ($kw in ($results.Keys | Sort-Object)) {
    Write-Host "---------- $kw ----------"
    foreach ($m in $results[$kw]) {
        Write-Host "  $($m.Filename):$($m.LineNumber)  $($m.Line.Trim())"
    }
    Write-Host ""
}

# Afficher les fichiers les plus pertinents (definis, pas juste utilises)
Write-Host "=== FICHIERS DEFINISSANT UNE CLASSE D'ATTAQUE ===`n"
Get-ChildItem -Path $luaDir -Recurse -Filter "*.lua" |
    Where-Object { $_.Name -match -join("Attack","Swing","Combat","Fight") } |
    ForEach-Object { Write-Host "  $($_.FullName)" }
