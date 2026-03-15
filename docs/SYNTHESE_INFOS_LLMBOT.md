# Synthèse : informations essentielles pour que le LLMBot joue correctement

Ce document résume ce qu’il faut donner au LLM (prompt système, champs d’observation, règles de décision) pour que le bot survive et agisse de façon cohérente dans Project Zomboid. Il s’appuie sur les scripts Lua du mod, le bridge Python et les sources Lua du jeu (`media/lua`).

---

## 1. Conventions du jeu (sources PZ)

### 1.1 Stats du personnage

- **Hunger, Thirst, Fatigue, Stress, etc.** : lues via `player:getStats():get(CharacterStat.XXX)`.
- **Échelles** : les stats sont généralement sur une échelle **0 à 1** (ou équivalent) :
  - **Hunger** : plus la valeur est **élevée**, plus le personnage a faim (ex. `> 0.5` ou `> 0.6` = priorité manger).
  - **Thirst** : idem ; dans l’UI du jeu, `THIRST > 0.1` déclenche déjà les options de boire (`ISInventoryPaneContextMenu`, `ISInventoryPane.lua`). Donc soif « notable » dès ~0.1.
  - **Fatigue** : plus c’est élevé, plus le personnage est fatigué (sommeil nécessaire à terme).
  - **Health** : `player:getBodyDamage():getHealth()` — typiquement **0–100** ; en dessous de 50, priorité repos / éviter le combat.
- **Infection** : `player:getBodyDamage():IsInfected()` — mort à terme si non soignée ; le bot n’a pas d’action de soin pour l’instant.

**À communiquer au LLM** :  
- `stats.hunger` : plus c’est haut, plus il faut manger ; seuil raisonnable « manger » vers 0.5–0.6.  
- `stats.thirst` : idem ; seuil « boire » dans le jeu dès 0.1 — mais **pas d’action boire** pour le bot actuellement.  
- `stats.health` : 0–100 ; < 50 → privilégier repos (idle), fuite, pas de combat risqué.  
- `stats.fatigue` : pas d’action « dormir » pour l’instant.  
- `stats.infected` : informatif uniquement (aucune action médicale).

---

### 1.2 Nourriture

- **Valeur de nourriture** : `item:getHungerChange()` — en PZ c’est souvent **négatif** (réduit la faim). Plus `math.abs(hunger_change)` est grand, plus l’aliment est « nourrissant ».
- Le bridge / l’obs exposent `hunger_change` sur les items `is_food` (inventaire, conteneurs, world_items).

**À communiquer au LLM** :  
- Pour choisir quoi manger : préférer les aliments avec `hunger_change` le plus négatif (ou `abs(hunger_change)` le plus élevé).  
- Action disponible : `eat_best_food` (le client choisit déjà le meilleur en inventaire).

---

### 1.3 Combat et armes

- **Portée d’attaque** : dans le mod, `attack_nearest` ne s’exécute que si un zombie est à **< 2,5 tiles** (`LLMBot_Client.lua`). Au-delà, il faut d’abord `move_to` vers le zombie (ou fuir).
- **Condition des armes** : `getCondition()`, `getConditionMax()`, `isBroken()`. Une arme cassée ou à 0 de condition ne doit pas être utilisée.
- **Armes à deux mains** : `isTwoHandWeapon()` — en PZ, équiper une arme à deux mains **ne retire pas le sac à dos** (slot Back). Le sac reste équipé ; pas besoin de « libérer » le dos pour l’arme.
- **Endurance** : le jeu utilise `CharacterStat.ENDURANCE` ; en dessous d’un seuil (`getEnduranceWarning()`), les actions coûtent plus cher. Le bot n’a pas d’action dédiée « reprendre son souffle », mais `idle` aide.

**À communiquer au LLM** :  
- Ne jamais attaquer sans arme équipée en bon état (`equipped.primary` avec `is_weapon` et `!is_broken`, `condition > 0`).  
- Si zombie proche (ex. `dist < 3`) et arme OK → `attack_nearest`.  
- Si zombie proche et pas d’arme / arme cassée → `sprint_toggle` + `move_to` pour fuir.  
- Arme deux mains : compatible avec le sac à dos ; `is_two_handed` sert à décrire l’arme, pas à interdire le sac.

---

### 1.4 Inventaire et capacité

- **Poids** : `inv:getCapacityWeight()` = poids actuel ; `inv:getEffectiveCapacity(character)` = capacité effective (avec sacs équipés, etc.) ; `player:getMaxWeight()` = max sans bonus.
- Dans le jeu, si `getCapacityWeight() > getEffectiveCapacity(character)`, le personnage est en surcharge (effets négatifs, risque de drop automatique dans certains cas — voir `ActionManager.lua`).
- **Sac à dos** : équiper un vêtement/sac sur le slot **Back** (body_location) augmente la capacité (`getEffectiveCapacity`). C’est prioritaire pour pouvoir porter plus.

**À communiquer au LLM** :  
- `inventory_weight` et `max_weight` (ou capacité effective) : si `inventory_weight` proche ou supérieur à `max_weight` → alléger : `drop_heaviest` ou équiper un sac (`equip_clothing` avec un item `body_location` Back) si pas encore fait.  
- Pour avoir plus de capacité : équiper un sac (Back) via `equip_clothing` avec un item `is_clothing` dont `body_location` est "Back" (ou "Bag").

---

### 1.5 Conteneurs et exploration

- **Conteneur « exploré »** : `container:isExplored()` — tant que ce n’est pas exploré, le client ne voit pas le contenu (liste vide côté obs). Il faut d’abord **ouvrir** le conteneur avec `loot_container` (équivalent `ISOpenContainerTimedAction`).
- **Ordre logique** : 1) `loot_container` (x, y, z) pour ouvrir/explorer ; 2) à l’obs suivante, `containers[].items` est rempli ; 3) `take_item_from_container` (x, y, z, item_type ou item_name) pour prendre un objet précis.

**À communiquer au LLM** :  
- Conteneur avec `explored == false` → d’abord `loot_container` à ses coordonnées.  
- Conteneur avec `explored == true` et `items` non vides → utiliser `take_item_from_container` avec les coordonnées du conteneur et le `item_type` ou `item_name` souhaité.

---

### 1.6 Objets au sol (world items)

- Les objets au sol sont scannés dans un rayon (ex. 3 tiles) et exposés dans `world_items` (x, y, z, dist, name, type, is_weapon, is_food, is_clothing, weight, etc.).
- **Action** : `grab_world_item` avec (x, y, z) ou avec `index` (index 1-based dans la liste `world_items`). Le client fait la marche vers la tile si nécessaire (`luautils.walkAdj`) puis lance `ISGrabItemAction`.

**À communiquer au LLM** :  
- Utiliser `grab_world_item` pour ramasser un objet au sol en donnant soit ses coordonnées, soit son index dans `world_items`.  
- Vérifier la place en inventaire (`inventory_weight`, `max_weight`) avant de ramasser des objets lourds.

---

### 1.7 Bâtiments et danger

- **Bâtiments** : liste avec `id`, `name`, `dist`, `entry` (x, y, z), `zombie_count` (à l’intérieur), `entrance_zombie_count`, `entrance_danger` (sur, faible, moyen, élevé).
- Le bridge enrichit avec `nearest_unvisited_building` et une mémoire des bâtiments visités (`visited_building_ids`, `visited_buildings_items`).

**À communiquer au LLM** :  
- Pour explorer : privilégier `nearest_unvisited_building` et se déplacer vers `entry.x`, `entry.y`.  
- Tenir compte de `entrance_danger` et `zombie_count` avant d’entrer (éviter les bâtiments « élevé » si faible santé ou pas d’arme).  
- `building_id` et `building_name` dans l’obs indiquent le bâtiment actuel (intérieur/extérieur).

---

### 1.8 File d’actions et occupation

- **ISTimedActionQueue** : le personnage peut avoir une file d’actions (marche, ouvrir conteneur, manger, etc.).  
- **Obs** : `action_queue` (nombre d’actions en file), `is_busy` (true si file non vide).  
- Le client **ignore** une nouvelle commande (sauf `move_to`, `sprint_toggle`) si `is_busy` est true, pour éviter d’écraser une action en cours.

**À communiquer au LLM** :  
- Si `is_busy == true` et pas de zombie très proche : privilégier `idle` pour ne pas envoyer une commande qui sera ignorée.  
- Pour fuir en urgence, `sprint_toggle` et `move_to` sont quand même exécutés même si occupé.

---

## 2. Actions disponibles et paramètres (rappel)

| Action | Paramètres | Notes |
|--------|------------|--------|
| `move_to` | x, y, z? | Se déplacer vers une tile (coordonnées monde). |
| `attack_nearest` | — | Uniquement si un zombie est à < 2,5 tiles ; nécessite une arme équipée en bon état. |
| `eat_best_food` | — | Meilleure nourriture en inventaire (hunger_change). |
| `equip_best_weapon` | — | Meilleure arme en inventaire (condition max, non cassée). |
| `equip_weapon` | item_type ou item_name | Équiper une arme précise (ex. "Base.Bat"). |
| `equip_clothing` | item_type ou item_name | Équiper un vêtement (ex. sac Back). |
| `loot_container` | x, y, z | Ouvrir/explorer un conteneur à cette position. |
| `take_item_from_container` | x, y, z?, item_type ou item_name | Prendre un objet précis dans un conteneur déjà exploré. |
| `grab_world_item` | (x, y, z) ou index | Ramasser un objet au sol (coordonnées ou index dans world_items). |
| `drop_heaviest` | — | Jeter l’objet le plus lourd de l’inventaire. |
| `sprint_toggle` | — | Activer/désactiver la course. |
| `say` | text | Dire un message en jeu. |
| `idle` | — | Ne rien faire (repos, attendre la fin d’une action). |

---

## 3. Priorités de décision recommandées (pour le prompt)

À encoder dans le prompt système (ordre de priorité logique) :

1. **Santé basse et pas de zombie proche** : `idle` (repos).  
2. **Zombie très proche (dist < 3)** :  
   - Si arme équipée et en bon état → `attack_nearest`.  
   - Sinon → `sprint_toggle` + `move_to` pour fuir.  
3. **Faim élevée** (ex. `stats.hunger > 0.5`) et nourriture en inventaire → `eat_best_food`.  
4. **Pas d’arme équipée** (ou cassée) : `equip_best_weapon` ou `equip_weapon` avec un type/nom.  
5. **Protection** : si `worn_clothing` montre des slots importants vides (ex. pas de sac Back) et qu’un vêtement adapté est en inventaire → `equip_clothing`.  
6. **Objets utiles au sol** : `grab_world_item` (x, y) ou index.  
7. **Conteneur non exploré proche** : `loot_container` (x, y, z).  
8. **Conteneur exploré avec objet utile** : `take_item_from_container` (x, y, item_type ou item_name).  
9. **Surcharge** (`inventory_weight` proche de `max_weight`) : équiper un sac (Back) si possible, sinon `drop_heaviest`.  
10. **Exploration** : utiliser `nearest_unvisited_building` et `move_to(entry.x, entry.y)`.

---

## 4. Limitations actuelles (à indiquer au LLM)

- **Pas d’action « boire »** : `stats.thirst` est visible mais le bot ne peut pas boire. Prioriser le loot d’eau si on ajoute l’action plus tard.  
- **Pas d’action « dormir »** : `stats.fatigue` est visible mais pas d’action pour se reposer au lit.  
- **Pas de soin / infection** : `stats.infected` et dégâts corporels sont visibles, mais pas d’action bandage/médicale.  
- **Pas d’action « boire » depuis une bouteille** : dans les sources PZ, boire utilise des fluides (getFluidContainer(), THIRST > 0.1) ; non implémenté côté bot.

---

## 5. Champs d’observation essentiels (résumé)

À bien décrire dans le prompt pour que le LLM sache les utiliser :

- **position** : x, y, z (pour move_to et cibles).  
- **stats** : health (0–100), hunger, thirst, fatigue, endurance, stress, morale, panic, sanity, infected.  
- **equipped** : primary (et secondary) — name, type, is_weapon, condition, condition_max, is_broken, is_two_handed.  
- **inventory** : name, type, weight, is_food, hunger_change, is_weapon, is_clothing, body_location, condition, is_broken.  
- **inventory_weight**, **max_weight** : capacité et surcharge.  
- **worn_clothing** : body_location, bite_defense, scratch_defense (et name, type).  
- **world_items** : x, y, z, dist, name, type, is_weapon, is_food, is_clothing, weight (pour grab_world_item).  
- **zombies** : x, y, dist (pour attack_nearest et fuite).  
- **containers** : x, y, z, dist, name, explored, items[], building_id.  
- **buildings** : id, name, dist, entry, zombie_count, entrance_zombie_count, entrance_danger, visited.  
- **nearest_unvisited_building** : name, id, dist, entry, danger, zombie_count (enrichi par le bridge).  
- **building_id**, **building_name**, **is_indoors** : lieu actuel.  
- **game_hour**, **game_day** : contexte temps.  
- **action_queue**, **is_busy** : pour éviter de surcharger ou choisir idle.

---

## 6. Références sources PZ (Lua)

- Stats : `CharacterStat.*`, `getStats():get()`, `getBodyDamage():getHealth()`, `IsInfected()`.  
- Nourriture : `getHungerChange()`, `IsFood()`.  
- Soif (UI) : `CharacterStat.THIRST > 0.1` (ISInventoryPane.lua, ISInventoryPaneContextMenu.lua).  
- Inventaire : `getCapacityWeight()`, `getEffectiveCapacity(character)`, `getMaxWeight()` (ISInventoryPage.lua, XpUpdate.lua, ActionManager.lua).  
- Conteneurs : `container:isExplored()`, `ISOpenContainerTimedAction`.  
- Ramassage : `ISGrabItemAction`, `ISWorldObjectContextMenu.grabItemTime()`.  
- Transfert : `ISInventoryTransferUtil.newInventoryTransferAction`, `walkToContainer` (take_item_from_container).  
- Équipement : `ISEquipWeaponAction`, `ISWearClothing`, body locations (ItemBodyLocation.*, getBodyLocation()).  
- Armes : `HandWeapon`, `getCondition()`, `getConditionMax()`, `isBroken()`, `isTwoHandWeapon()`.

---

*Document généré pour le projet LLMBot — à mettre à jour si de nouvelles actions ou champs d’observation sont ajoutés.*
