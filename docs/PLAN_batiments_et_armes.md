# Plan : bâtiments proches + état des armes

Ce document décrit un plan d’implémentation pour :
1. **Détecter les bâtiments les plus proches** du joueur.
2. **Exposer l’état et le niveau de dégâts des armes** (inventaire + conteneurs autour du joueur).

---

## 1. Détection des bâtiments les plus proches

### Objectif
Ajouter dans l’observation (`LLMBot_obs.json`) une liste `buildings` : les bâtiments les plus proches du joueur, avec identifiant, nom (type de pièce/bâtiment), distance et optionnellement alarme.

### API Project Zomboid (sources vérifiées)
- **Case (IsoGridSquare)** : `sq:getRoom()` → retourne une pièce si la case est à l’intérieur.
- **Pièce** : `room:getBuilding()` → retourne le bâtiment (ou on utilise directement `sq:getBuilding()` quand `sq:getRoom()` est non nil — voir `DebugChunkState_SquarePanel.lua`).
- **Bâtiment** :
  - `building:getID()` — identifiant unique.
  - `building:getDef()` → **BuildingDef** :
    - `getDef():getName()` — nom (via RoomDef de la pièce).
    - `getDef():isAlarmed()` — si le bâtiment a une alarme.
- **Distance** : on peut utiliser la distance du joueur à la case (comme pour les zombies) : `math.sqrt((sq:getX()-playerX)^2 + (sq:getY()-playerY)^2)`.

Références dans le jeu : `client/DebugUIs/DebugChunkState/DebugChunkState_SquarePanel.lua` (l.97–103), `shared/Util/BuildingHelper.lua` (getRooms sur BuildingDef).

### Algorithme proposé (côté Lua)

1. **Rayon de scan** : parcourir les cases dans un rayon donné (ex. 15 ou 20 tiles) autour du joueur, comme pour les conteneurs (actuellement -5 à +5). Pour les bâtiments, un rayon plus grand (ex. 15) est pertinent.
2. **Collecte des bâtiments** :
   - Pour chaque case `(x, y, z)` dans ce rayon : `sq = cell:getGridSquare(px+dx, py+dy, pz)`.
   - Si `sq` et `sq:getRoom() ~= nil` alors `building = sq:getBuilding()`.
   - Si `building` non nil : utiliser `building:getID()` comme clé unique.
   - Stocker pour ce bâtiment : **id**, **name** (ex. `building:getDef():getName()` — à confirmer selon que getName soit sur BuildingDef ou RoomDef), **dist** (distance min du joueur à cette case), **alarm** (optionnel, `building:getDef():isAlarmed()`).
3. **Déduplication** : un même bâtiment apparaît sur plusieurs cases ; ne garder qu’une entrée par `building:getID()` avec la **distance minimale** rencontrée.
4. **Tri et limite** : trier par `dist` croissant, garder les N premiers (ex. 5 ou 10) pour limiter la taille du JSON.

### Structure de données dans l’observation

```json
"buildings": [
  {"id": 123, "name": "Office", "dist": 3, "alarm": false},
  {"id": 456, "name": "Kitchen", "dist": 8, "alarm": true}
]
```

### Fichiers à modifier
- **LLMBot_Client.lua** :
  - Ajouter une fonction `scanNearbyBuildings(player, cell, radius, maxCount)` qui retourne une liste de tables `{id, name, dist, alarm}`.
  - Dans `buildObservation()`, appeler cette fonction et remplir `obs.buildings`.

### Points à vérifier en jeu
- Que `square:getBuilding()` soit bien disponible lorsque `square:getRoom() ~= nil` (confirmé dans DebugChunkState_SquarePanel).
- Le nom affiché : `building:getDef():getName()` ou via `square:getRoom():getRoomDef():getName()` (nom de la pièce). Pour un “nom de bâtiment” lisible, le RoomDef name est souvent le plus utile.

---

## 2. État et niveau de dégâts des armes

### Objectif
Pour toutes les armes (HandWeapon) visibles par le bot — **inventaire**, **conteneurs explorés** autour du joueur, et **arme équipée** — exposer dans l’observation :
- **condition** (état actuel),
- **condition_max** (état max),
- **is_broken** (arme cassée / inutilisable).

Cela permet au LLM de privilégier les armes en bon état et d’éviter d’équiper une arme cassée.

### API Project Zomboid (sources vérifiées)
- **HandWeapon** (et items avec condition) :
  - `item:getCondition()` — état actuel (nombre).
  - `item:getConditionMax()` — état maximum (nombre).
  - `item:isBroken()` — vrai si l’objet est cassé (utilisé dans ISInventoryPaneContextMenu, ISUpgradeWeapon, etc.).
- Affichage condition dans l’UI : `ISInventoryPane.lua` (l.2642–2644) utilise `item:getCondition() / item:getConditionMax()` pour la barre de condition.

Références : `client/ISUI/ISInventoryPaneContextMenu.lua` (l.199, 251, 254–255), `client/ISUI/ISInventoryPane.lua` (l.2642–2644).

### Où ajouter les champs

| Emplacement | Fichier / fonction | Modification |
|------------|---------------------|--------------|
| **Inventaire** | `LLMBot_Client.lua` → `buildObservation()` (boucle sur `inv:getItems()`) | Pour chaque item : si `instanceof(item, "HandWeapon")` alors en plus de `is_weapon = true`, ajouter `condition`, `condition_max`, `is_broken`. |
| **Conteneurs** | `LLMBot_Client.lua` → `scanSquareContainers()` (boucle sur `container:getItems()`) | Pour chaque item : si `instanceof(item, "HandWeapon")` alors ajouter `condition`, `condition_max`, `is_broken` à l’entry. |
| **Équipé (primary/secondary)** | `LLMBot_Client.lua` → `buildObservation()` (bloc equipped) | Pour `primary` et `secondary` : si `is_weapon` / HandWeapon, ajouter `condition`, `condition_max`, `is_broken`. |

### Structure des champs (exemple)

Pour un item arme dans `inventory` ou dans un `container.items` :

```json
{
  "name": "Base.Axe",
  "type": "HandWeapon",
  "weight": 1.8,
  "is_weapon": true,
  "condition": 8,
  "condition_max": 10,
  "is_broken": false
}
```

Pour l’arme équipée :

```json
"equipped": {
  "primary": {
    "name": "Axe",
    "type": "Base.Axe",
    "is_weapon": true,
    "condition": 8,
    "condition_max": 10,
    "is_broken": false
  }
}
```

### Implémentation Lua (résumé)

- **Helper** (optionnel) : une fonction `getWeaponConditionFields(item)` qui retourne `{ condition = item:getCondition(), condition_max = item:getConditionMax(), is_broken = item:isBroken() }` si `instanceof(item, "HandWeapon")`, sinon `nil`. Utiliser cette fonction dans les trois endroits (inventaire, conteneurs, équipé) pour éviter la duplication.
- **Sécurité** : appeler `getCondition` / `getConditionMax` / `isBroken` uniquement si l’item n’est pas nil et si `instanceof(item, "HandWeapon")` (certains items peuvent avoir condition sans être HandWeapon ; on ne modifie que les armes pour rester cohérent avec `equip_best_weapon`).

### Fichiers à modifier
- **LLMBot_Client.lua** uniquement :
  - `scanSquareContainers()` : ajouter les champs condition pour les HandWeapon dans chaque `entry`.
  - `buildObservation()` : inventaire (champs condition pour HandWeapon), équipé (primary/secondary avec condition si arme).

### Côté bridge Python
- **bridge.py** : aucun changement obligatoire. Le prompt et la logique peuvent ensuite utiliser `condition`, `condition_max`, `is_broken` (par ex. “ne pas équiper d’arme cassée”, “préférer l’arme avec la meilleure condition”).

---

## 3. Ordre d’implémentation suggéré

1. **Armes (état / dégâts)**  
   - Modifications localisées (inventaire, conteneurs, équipé).  
   - Pas de nouvelle structure globale, seulement des champs en plus.  
   - Facile à tester en regardant `LLMBot_obs.json`.

2. **Bâtiments proches**  
   - Nouvelle structure `obs.buildings` et nouvelle fonction de scan.  
   - Vérifier en jeu le nom (BuildingDef vs RoomDef) et le rayon/limite pour éviter un JSON trop gros.

3. **Optionnel**  
   - Adapter le prompt du bridge pour utiliser `buildings` (ex. “se diriger vers le bâtiment le plus proche”) et les champs armes (ex. “équiper l’arme en meilleur état, ne pas prendre d’arme cassée”).

---

## 4. Résumé des sources PZ consultées

| Besoin | Fichiers PZ |
|--------|--------------|
| Bâtiment depuis une case | `DebugChunkState_SquarePanel.lua`, `ISWorldObjectContextMenu.lua`, `BuildingHelper.lua` |
| BuildingDef (nom, alarme) | `DebugChunkState_SquarePanel.lua`, `ClientCommands.lua` |
| Condition / cassé des armes | `ISInventoryPaneContextMenu.lua`, `ISInventoryPane.lua`, `ISRemoveBush.lua`, `ISUpgradeWeapon.lua` |

Toute modification Lua doit rester cohérente avec ces APIs (Build 41.78 / 42).
