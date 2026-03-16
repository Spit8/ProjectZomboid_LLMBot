# API Lua : vérifier si une case est praticable (walkable)

Tu as vu dans le debugger du jeu les champs **solidtrans** (flags) et **moveType** (properties). En Lua, on n’accède pas toujours aux mêmes noms, mais l’API exposée permet de vérifier si on peut marcher sur une case avant d’y envoyer un `move_to` (ou un clic).

## Méthodes sur `IsoGridSquare` (exposées en Lua)

D’après la doc Java du jeu ([IsoGridSquare](https://projectzomboid.com/modding/zombie/iso/IsoGridSquare.html)) :

| Méthode | Retour | Description |
|--------|--------|-------------|
| **`sq:isFree(bCountOtherCharacters)`** | boolean | Case libre pour le pathfinding. `false` = ignorer les autres personnages, `true` = les compter comme bloquants. **C’est la méthode la plus directe pour “peut-on marcher ici ?”.** |
| **`sq:isSolid()`** | boolean | Case considérée comme solide (bloquante). |
| **`sq:isSolidTrans()`** | boolean | Correspond au flag **solidtrans** du debugger : obstacles “transparents” (eau, trous, etc.) qui bloquent quand même le déplacement. |
| **`sq:getPathMatrix(dx, dy, dz)`** | boolean | Bit de la matrice de pathfinding à la sous-position `(dx, dy, dz)` (valeurs 0 ou 1 pour la grille 2×2×2). Utile pour un contrôle fin. |
| **`sq:getCollideMatrix(dx, dy, dz)`** | boolean | Bit de la matrice de collision. |
| **`sq:getProperties()`** | PropertyContainer | Propriétés de la case (peut contenir des infos type **moveType** selon le moteur ; à tester en jeu avec `sq:getProperties():get("moveType")` ou équivalent). |

## Vérifier “peut-on walk sur cette case ?” avant un clic / move_to

- **Recommandé** : utiliser **`sq:isFree(false)`** pour “la case est-elle praticable ?” (sans compter les autres personnages).
- Si tu veux exclure aussi les cases “solidtrans” (eau, vide, etc.) : en plus, vérifier **`not sq:isSolidTrans()`**.
- **moveType** : il vient en général des **définitions de tuile** (sprites / TileDef). Sur la case, tu peux tenter `sq:getProperties()` et lire la propriété correspondante (nom exact à confirmer en jeu). Ce n’est pas toujours exposé de la même façon qu’en debug.

## Exemple Lua (avant d’envoyer un move_to)

```lua
local cell = getCell() or player:getCell()
local sq = cell and cell:getGridSquare(tx, ty, tz)
if not sq then
    -- pas de case valide
    return
end
-- Option 1 : case libre pour le pathfinding
if not sq:isFree(false) then
    -- case bloquée (solide, eau, etc.)
    return
end
-- Option 2 : exclure aussi solidtrans (eau, trous, etc.)
if sq:isSolidTrans() then
    -- case avec obstacle "transparent"
    return
end
-- Optionnel : lire moveType si exposé
local props = sq:getProperties()
if props and props.get then
    local moveType = props:get("moveType")  -- ou props:getProperty("moveType") selon l’API
    -- utiliser moveType selon tes règles
end
-- OK pour marcher vers (tx, ty, tz)
```

## Intégration dans le LLMBot (comportement par défaut)

La vérification walkable est **prépondérante** sur les déplacements :

1. **À la réception d’un `move_to(x, y, z)`** : si la case `(x, y, z)` n’est pas walkable (`isFree(false)` ou `isSolidTrans()`), le client :
   - enregistre `(x, y, z)` dans **`LLMBotNonWalkableTiles`** (cache en mémoire, max 200 entrées) ;
   - cherche la **case walkable la plus proche** par spirale (rayon max 20) via `findNearestWalkableSquare` ;
   - envoie le déplacement vers cette case walkable (puis `AdjacentFreeTileFinder` peut encore ajuster une case adjacente au besoin).

2. **Dans l’observation** : **`obs.non_walkable_positions`** contient jusqu’à 50 positions `{x, y}` connues comme non walkable (triées par distance au joueur), pour que le LLM **ne redemande pas** `move_to` vers ces coordonnées.

3. **Côté bridge** : le prompt indique au LLM de ne jamais envoyer `move_to` vers une position listée dans `non_walkable_positions`.

En résumé : le joueur ne va jamais *cliquer* sur une case non walkable ; on redirige toujours vers la plus proche walkable et on mémorise les mauvaises cibles pour le LLM.

---

## Contrainte interior / exterior

Si la cible (conteneur ou case) demandée est **intérieure** (non exterior : dans une pièce, ou `isExteriorCache == false`), le joueur doit être amené sur une case **exacte ou adjacente** qui est **elle aussi intérieure**. On n’envoie pas le joueur sur une case extérieure pour interagir avec un conteneur en intérieur.

- **Détection** : **exterior** est un **flag des tiles** (`IsoFlagType.exterior`). Sur une case, `sq:getHasTypes()` retourne un `ZomboidBitFlag` ; si `hasTypes:isSet(IsoFlagType.exterior)` est vrai, la tile est extérieure, sinon intérieure. Le helper `isSquareInterior(sq)` utilise ce flag en priorité ; en fallback : `sq:getRoom() ~= nil` ou `sq.isExteriorCache == false`.
- **Recherche de case walkable** : quand on cherche la plus proche case walkable (`findNearestWalkableSquare`), si la cible est intérieure on ne garde que des cases intérieures (`mustBeInterior = true`).
- **Case adjacente** : si on utilise `AdjacentFreeTileFinder` pour une case adjacente à la cible, et que la cible est intérieure, on n’accepte une adjacente que si elle est elle aussi intérieure ; sinon on garde la case cible (exacte) comme destination.
