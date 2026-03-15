# Analyse : ce qu’il manque pour qu’un LLM prenne des décisions (côté client)

Objectifs du jeu pour le bot :
1. **Récupérer des objets** (loot)
2. **Tuer des zombies si nécessaire** (agressifs, détectent facilement)
3. **S’équiper** (armes, protections)

---

## 1. Ce qui existe déjà

### Observations (LLMBot_Client.lua – `buildObservation`)
- **Position** : `x`, `y`, `z`
- **Stats** : hunger, thirst, fatigue, endurance, stress, morale, panic, sanity, health, infected
- **Inventaire** : jusqu’à 29 items (name, type, weight, is_food, is_weapon, condition, etc.)
- **Équipé** : primary/secondary (nom, type, is_weapon, condition, is_broken)
- **Zombies** : jusqu’à 60 dans un rayon 40 (x, y, dist)
- **Conteneurs** : dans un rayon 5 tiles (x, y, z, dist, name, explored, items jusqu’à 9, building_id)
- **Bâtiments** : jusqu’à 25 (id, name, dist, alarm, entry)
- **Contexte** : is_indoors, building_id, building_name, game_hour, game_day
- **Actions** : action_queue, is_busy

### Actions exécutables (`executeCommand`)
- `move_to` (x, y, z)
- `loot_container` (x, y, z) — ouvre le conteneur
- `eat_best_food`
- `equip_best_weapon` — meilleure arme en inventaire (condition max, non cassée)
- `attack_nearest` — uniquement si un zombie est à **< 2,5 tiles**
- `say`, `idle`

### Côté bridge (mémoire, enrichissement)
- Mémoire des bâtiments visités et des objets vus par bâtiment
- `nearest_unvisited_building` avec danger (zombies autour de l’entrée)

---

## 2. Ce qui manque pour le LLM

### 2.1 Récupérer des objets

| Manque | Détail | Impact |
|--------|--------|--------|
| **Prendre un objet précis depuis un conteneur** | Aujourd’hui : `loot_container` ouvre le conteneur, mais il n’y a **aucune action** du type « prends l’objet X du conteneur Y ». Le LLM voit les items dans `containers[].items` mais ne peut pas demander de les prendre. | Le bot ne peut pas choisir quoi loot (ex. prioriser arme / nourriture / vêtement). |
| **Objets au sol** | Aucune observation des **WorldItem** (objets sur la tile / à proximité). En PZ, `square:getWorldObjects()` donne les `IsoWorldInventoryObject`. Pas exposé dans l’obs. | Le LLM ne sait pas qu’il y a des objets à ramasser au sol. |
| **Action « prendre objet au sol »** | Pas d’action du type `grab_world_item` (équivalent à `ISGrabItemAction`). | Même si on ajoutait les world items en obs, le bot ne pourrait pas les ramasser. |
| **Action « prendre objet depuis conteneur »** | Pas d’action du type `take_item` (conteneur → inventaire) utilisant `ISInventoryTransferUtil.newInventoryTransferAction`. | Une fois le conteneur ouvert, le bot ne peut pas dire « prends la batte / la canette ». |

**Recommandations client :**
- **Obs** : ajouter une liste `world_items` (proche du joueur, ex. rayon 3) : pour chaque objet au sol, (x, y, dist, name, type, weight, is_weapon, is_food, etc.).
- **Actions** :  
  - `take_item_from_container` : (x, y, z du conteneur, type ou nom d’item) → marche vers le conteneur si besoin, puis transfert item → inventaire (via `ISInventoryTransferUtil` + conteneur trouvé par (x,y,z)).  
  - `grab_world_item` : (x, y, z) ou identifiant (ex. index dans world_items) → `ISGrabItemAction` sur le `IsoWorldInventoryObject` correspondant.

---

### 2.2 Tuer des zombies (agressifs, détection facile)

| Manque | Détail | Impact |
|--------|--------|--------|
| **État d’alerte des zombies** | Obs actuelle : seulement (x, y, dist). Pas d’info « ce zombie me voit / est en alerte / me poursuit ». En PZ il peut exister des infos côté moteur (target, état). | Le LLM ne peut pas distinguer « zombie passif » vs « zombie qui me chasse » → décisions fuite/combat moins fines. |
| **Sprint / fuite** | `sprint_toggle` est dans `LLMBot.ACTIONS` (Shared) mais **n’est pas implémenté** dans `executeCommand` (Client). Pas d’appel à `player:setRunning(true/false)` ou équivalent. | Le bot ne peut pas sprinter pour fuir ou se repositionner. |
| **Séquence « s’approcher puis attaquer »** | `attack_nearest` ne s’exécute que si un zombie est déjà à **< 2,5 tiles**. Pas d’action « va vers le zombie puis attaque » (move_to + attack au bon moment). | En pratique le bot doit déjà être collé au zombie ; pas de décision « j’avance pour frapper ». |
| **Info « je suis vu »** | Pas d’indicateur agrégé du type « au moins un zombie me cible ». | Le LLM ne peut pas prioriser « fuir d’abord » de façon explicite. |

**Recommandations client :**
- **Obs** : si l’API PZ l’expose, ajouter par zombie un champ du type `alerted` ou `targeting_player` (à vérifier dans les sources Lua zombie/IsoZombie).
- **Action** : implémenter `sprint_toggle` dans `executeCommand` (ex. bascule `player:setRunning()` selon l’état actuel).
- **Stratégie** : le bridge peut déjà combiner `move_to` + `attack_nearest` au tick suivant ; côté client, s’assurer que `attack_nearest` reste fiable quand le joueur est à portée (et éventuellement ajouter une action `attack_target` avec coordonnées si besoin).

---

### 2.3 S’équiper (armes et protections)

| Manque | Détail | Impact |
|--------|--------|--------|
| **Équipement en armes ciblé** | Seule action : `equip_best_weapon` (meilleure condition en inventaire). Pas d’action « équipe l’item de type X » ou « équipe l’item à l’index Y ». | Le LLM ne peut pas dire « équipe la batte » ou « garde le couteau pour plus tard ». |
| **Vêtements / protections** | Aucune observation des **vêtements portés** (getWornItems, BodyLocation, etc.). Pas de liste du type « casque, gilet, pantalon… » ni de niveau de protection (bite/scratch). | Le LLM ne sait pas s’il est déjà protégé ni quelles pièces manquent. |
| **Items « vêtement » dans l’obs** | Dans inventaire et conteneurs, pas de flag `is_clothing` (ou équivalent). Les items Clothing existent en PZ (IsClothing(), getBodyLocation()). | Le LLM ne peut pas prioriser « prendre / équiper un manteau » dans le loot. |
| **Actions équiper vêtement** | Pas d’action du type `equip_clothing` (équivalent à `ISWearClothing:new(player, item, 50)`). | Même avec l’obs, le bot ne peut pas s’équiper en protection. |

**Recommandations client :**
- **Obs** :  
  - **Équipement porté** : liste `worn_clothing` (body_location, name, type, et si dispo : niveau de protection bite/scratch).  
  - **Items** : pour chaque item (inventaire + conteneurs + world_items), ajouter `is_clothing` et éventuellement `body_location` (ex. pour prioriser « prendre un casque »).
- **Actions** :  
  - `equip_weapon` : paramètre type ou nom (ou index inventaire) → équiper cet item HandWeapon (ISEquipWeaponAction).  
  - `equip_clothing` : paramètre type ou nom (ou index) → ISWearClothing pour cet item.

---

### 2.4 Autres manques utiles

| Manque | Détail | Impact |
|--------|--------|--------|
| **Capacité de portée** | Pas de `carry_capacity` ni `current_weight` / `max_weight` (getMaxWeight(), getInventoryWeight() ou getEffectiveCapacity). | Le LLM ne sait pas s’il peut encore prendre des objets ou s’il doit alléger. |
| **Action drop** | `drop_heaviest` est dans `LLMBot.ACTIONS` (Shared) mais **pas implémentée** dans `executeCommand`. | Le bot ne peut pas vider du poids en jetant l’objet le plus lourd. |
| **Soif** | Soif dans l’obs ; pas d’action « boire » (équivalent boisson / source d’eau). | Gestion survie incomplète. |

**Recommandations client :**
- **Obs** : ajouter `inventory_weight` et `max_weight` (ou `capacity`) pour le personnage.
- **Actions** : implémenter `drop_heaviest` (ou `drop_item` par type/nom) dans `executeCommand` ; plus tard, ajouter une action « boire » si besoin.

---

## 3. Synthèse des priorités (côté client)

1. **Récupérer des objets**  
   - Obs : `world_items` (objets au sol à proximité) ; optionnel : `is_clothing` / `body_location` sur les items.  
   - Actions : `take_item_from_container`, `grab_world_item`.

2. **Zombies et fuite**  
   - Implémenter `sprint_toggle`.  
   - Obs : état d’alerte des zombies si disponible dans l’API.

3. **S’équiper**  
   - Obs : `worn_clothing` ; `is_clothing` (et éventuellement `body_location`) sur les items.  
   - Actions : `equip_weapon` (ciblé), `equip_clothing`.

4. **Poids et drop**  
   - Obs : poids courant / max.  
   - Action : `drop_heaviest` (et éventuellement `drop_item`).

Ensuite, adapter le **SYSTEM_PROMPT** et le format des réponses du bridge pour exposer ces nouveaux champs et actions (ex. quand utiliser `take_item_from_container` vs `grab_world_item`, quand sprinter, quand équiper une protection).
