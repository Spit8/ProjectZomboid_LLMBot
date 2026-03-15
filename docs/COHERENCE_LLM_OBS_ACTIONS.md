# Cohérence : observations LLM, actions et objectifs du jeu

Vérification que ce que le LLM peut **observer**, ce qu’il peut **faire** (actions) et les **objectifs de survie** de Project Zomboid sont alignés.

---

## 1. Ce que le LLM reçoit (observation)

Le bridge envoie à l’API le JSON complet de `buildObservation()` (Lua), enrichi côté Python par :
- `update_and_enrich_obs` : `buildings[].visited`, `visited_building_ids`, `visited_buildings_items`
- `enrich_obs_nearest_unvisited` : `nearest_unvisited_building` (name, id, dist, entry, danger, zombie_count)

### 1.1 Structure de l’observation (Lua)

| Champ | Contenu | Utilisation par le prompt |
|-------|---------|---------------------------|
| `position` | `x`, `y`, `z` | move_to, coordonnées des cibles |
| `stats` | `health`, `hunger`, `thirst`, `fatigue`, `endurance`, `stress`, `morale`, `panic`, `sanity`, `infected` | Priorités (santé, faim, etc.) |
| `equipped` | `primary`, `secondary` (name, type, is_weapon, condition, condition_max, is_broken) | Attaque, état de l’arme |
| `inventory` | Jusqu’à 29 items (name, type, weight, is_food, is_weapon, is_clothing, body_location, condition, …) | eat_best_food, equip_*, drop_heaviest |
| `inventory_weight`, `max_weight` | Poids actuel / capacité | Surcharge → drop ou équiper sac |
| `worn_clothing` | name, type, body_location, bite_defense, scratch_defense | Protection, sac (Back) |
| `world_items` | x, y, z, dist, name, type, is_weapon, is_food, is_clothing, weight, … | grab_world_item (x,y ou index) |
| `zombies` | Jusqu’à 60 (x, y, dist) | attack_nearest, fuite |
| `containers` | x, y, z, dist, name, explored, items[] | loot_container, take_item_from_container |
| `buildings` | id, name, dist, alarm, entry{x,y,z}, zombie_count, entrance_zombie_count, entrance_danger, visited | Exploration, move_to(entry) |
| `building_id`, `building_name`, `is_indoors` | Bâtiment actuel | Contexte |
| `game_hour`, `game_day` | Heure / jour en jeu | Contexte |
| `action_queue`, `is_busy` | File d’actions | Éviter de surcharger ou idle si occupé |

**Cohérence** : Les champs décrits dans le prompt système (inventory_weight, max_weight, world_items, worn_clothing, buildings avec zombie_count/entrance_danger, etc.) correspondent bien à ce que le Lua envoie.

---

## 2. Actions disponibles et paramètres

Chaque action du prompt existe dans `LLMBot_Shared.ACTIONS` et est implémentée dans `executeCommand()` (LLMBot_Client.lua).

| Action | Paramètres (prompt) | Paramètres (Lua) | Cohérent |
|--------|--------------------|------------------|----------|
| move_to | x, y, z? | cmd.x, cmd.y, cmd.z (défaut: getZ()) | Oui |
| attack_nearest | — | — | Oui (condition: zombie < 2,5 tiles) |
| eat_best_food | — | — | Oui |
| equip_best_weapon | — | — | Oui |
| equip_weapon | item_type ou item_name | cmd.item_type or cmd.item_name | Oui |
| equip_clothing | item_type ou item_name | idem | Oui |
| loot_container | x, y, z | cmd.x, cmd.y, cmd.z | Oui |
| take_item_from_container | x, y, z?, item_type ou item_name | idem | Oui |
| grab_world_item | (x,y,z) ou index | tx,ty,tz ou cmd.index (1-based) | Oui |
| drop_heaviest | — | — | Oui |
| sprint_toggle | — | — | Oui |
| say | text | cmd.text | Oui |
| idle | — | — | Oui |

Les coordonnées utilisées (buildings[].entry, containers[].x/y/z, world_items[].x/y/z, zombies[].x/y) sont bien celles produites par l’observation.

---

## 3. Objectifs du jeu vs capacités du bot

| Objectif survie | Observable par le LLM | Action disponible | Note |
|-----------------|------------------------|--------------------|------|
| Ne pas mourir (santé) | stats.health | idle (repos), fuite (move_to + sprint) | Pas de soin direct ; priorité « health < 50 → idle » dans le prompt. |
| Éviter / combattre zombies | zombies[].dist, equipped.primary | attack_nearest, move_to, sprint_toggle | Condition d’attaque : dist < 2,5 et arme. |
| Gérer la faim | stats.hunger, inventory[].is_food, hunger_change | eat_best_food | Cohérent. |
| Gérer la soif | stats.thirst | **Aucune** | Pas d’action « boire ». Soif visible mais non traitable par le bot. |
| Fatigue / sommeil | stats.fatigue | **Aucune** | Pas d’action dormir. |
| Infection | stats.infected | **Aucune** | Pas d’action médicale. |
| S’équiper (arme) | inventory[].is_weapon, condition, equipped | equip_best_weapon, equip_weapon | Cohérent. |
| S’équiper (vêtements / sac) | worn_clothing, inventory[].is_clothing, body_location | equip_clothing | Sac (Back) pour max_weight décrit dans le prompt. |
| Capacité d’inventaire | inventory_weight, max_weight | equip_clothing (sac), drop_heaviest | Cohérent. |
| Loot (conteneurs / sol) | containers[], world_items[] | loot_container, take_item_from_container, grab_world_item | Cohérent. |
| Explorer (bâtiments) | buildings[], nearest_unvisited_building | move_to(entry.x, entry.y) | Cohérent. |

**Résumé** : Faim, armes, vêtements, sac, surcharge, loot et exploration sont couverts. Soif, fatigue et infection sont observables mais sans action dédiée (limitation volontaire ou à étendre plus tard).

---

## 4. Incohérences et lacunes identifiées

### 4.1 Prompt vs observation

- **Santé / faim** : Le prompt parle de « health < 50 » et « hunger > 0,6 ». Les valeurs sont dans `stats.health` et `stats.hunger`. Le LLM reçoit tout le JSON donc voit `stats.*` ; préciser « stats.health », « stats.hunger » (et « stats.thirst ») dans le prompt évite toute ambiguïté.
- **Hunger** : Dans PZ, la stat hunger est typiquement entre 0 et 1 (1 = estomac vide / très faim). « hunger > 0,6 » = besoin de manger est cohérent ; à valider en jeu selon la convention exacte du build.
- **Soif** : Mentionner dans le prompt que `stats.thirst` existe mais qu’il n’y a pas d’action « boire » pour l’instant (le bot peut au moins prioriser l’eau en loot si on l’ajoute plus tard).

### 4.2 Arme deux mains et sac à dos

- **Comportement en jeu** : Dans Project Zomboid, équiper une arme à deux mains **ne retire pas** le sac à dos (slot Back). Le code `ISEquipWeaponAction` ne modifie que les mains (primary/secondary), pas `getClothingItem_Back()`. Sac et arme deux mains sont compatibles.
- Le prompt a été corrigé pour ne plus indiquer que l’arme deux mains oblige à déséquiper le sac. `is_two_handed` reste utile pour décrire comment l’arme est portée (une main vs deux mains).

### 4.3 Parsing des commandes (Lua)

- Le client lit `LLMBot_cmd.json` et utilise `LLMBot.fromJSON(raw)`. Le bridge écrit avec `json.dump(cmd)` (objet plat).
- Le parseur minimal (Shared) gère les objets plats `{"key": value}` (string, number, bool, null). Pour les commandes actuelles (pas de tableaux ni objets imbriqués), c’est cohérent.
- Risque marginal : chaînes contenant des guillemets échappés dans `say` (text) peuvent poser problème au parseur minimal ; à garder en tête si on autorise des messages complexes.

---

## 5. Recommandations appliquées / à appliquer

1. **Fait** : Documenter la cohérence (ce fichier).
2. **Fait** : `is_two_handed` est exposé dans l’observation pour les armes (equipped + inventory + world_items + containers). Utile pour savoir si l’arme est portée à deux mains (pas pour retirer le sac : en PZ le sac reste équipé).
3. **À faire** : Clarifier le prompt : préciser que health/hunger/thirst sont sous `stats`, et mentionner l’absence d’action boire (et optionnellement soif/fatigue/infection).
4. **Optionnel** : Ajouter plus tard une action « boire » (ex. drink_best_water / utiliser une bouteille) et l’indiquer dans le prompt pour aligner objectifs et actions.

---

## 6. Synthèse

- **Observations ↔ prompt** : Alignés (structure et champs décrits).
- **Actions ↔ prompt ↔ Lua** : Toutes les actions listées dans le prompt sont implémentées et les paramètres correspondent.
- **Objectifs du jeu** : Faim, combat, équipement, sac, surcharge, loot et exploration sont couverts. Soif, fatigue et infection restent en lecture seule tant qu’aucune action n’est ajoutée.
- **Comportement PZ** : Arme deux mains et sac à dos sont compatibles (le jeu ne retire pas le sac quand on équipe une arme deux mains).
