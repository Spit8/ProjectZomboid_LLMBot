# Plan de complétion du client LLMBot

Objectif : permettre au LLMBot de **monter en compétences** dans le jeu et de **prendre les bonnes décisions** (survie, soins, repos, lecture, etc.). Ce plan s’appuie sur les sources Lua de Project Zomboid et l’état actuel du mod.

---

## État actuel (rappel)

### Déjà en place
- **Obs** : position, stats (health, hunger, thirst, fatigue, etc.), equipped, inventory (avec is_food, is_weapon, is_clothing, body_location), world_items, zombies, containers, buildings, worn_clothing, inventory_weight / max_weight, action_queue, is_busy.
- **Actions** : move_to, attack_nearest, eat_best_food, equip_best_weapon, equip_weapon, equip_clothing, loot_container, take_item_from_container, grab_world_item, drop_heaviest, sprint_toggle, say, idle.

### Manques identifiés
1. **Survie** : pas d’action boire → soif non gérée ; pas d’action dormir → fatigue non gérée ; pas de soins (bandage).
2. **Compétences** : le LLM ne voit pas les niveaux de perks ni les livres de compétence ; pas d’action « lire un livre ».
3. **Décisions** : pas d’info sur les dégâts corporels (saignement, parties à panser), pas d’info « item buvable » dans l’obs.

---

## Phase 1 — Survie : boire et soins de base

Objectif : que le bot gère la soif et les blessures légères (bandage).

### 1.1 Action « boire »

- **Sources PZ** : `ISDrinkFromBottle:new(character, item, uses)` pour les bouteilles ; `ISDrinkFluidAction:new(...)` pour les fluides génériques. Le jeu considère « boire » si `getFluidContainer()` et (Water ou CarbonatedWater), et si `THIRST > 0.1` (ISInventoryPane.lua). Les items « water source » ou avec `getFluidContainer():getPrimaryFluid():getFluidTypeString() == "Water"` sont buvables.
- **Client** :
  - Dans **buildObservation** : pour chaque item (inventaire, conteneurs, world_items), ajouter un flag **is_drink** (ou **is_water_container**) si l’item a un `getFluidContainer()` non vide et contient de l’eau (Fluid.Water ou type "Water"). Optionnel : exposer **thirst_change** ou **amount** pour prioriser.
  - Nouvelle **action** `drink` (ou `drink_best_water`) :
    - Soit sans paramètre : le client choisit le meilleur item buvable en inventaire (ex. bouteille d’eau), puis appelle `ISDrinkFromBottle:new(player, item, 1)` ou `ISDrinkFluidAction` selon le type d’item (voir `onDrinkFluid` / `onDrinkForThirst` dans ISInventoryPaneContextMenu.lua).
    - Soit avec paramètre `item_type` / `item_name` : boire un item précis.
  - Gérer le masque (retirer pour boire, remettre après) comme dans `onDrinkForThirst` si nécessaire (getEatingMask, ISWearClothing).
- **Shared** : ajouter `"drink"` (ou `"drink_best_water"`) dans `LLMBot.ACTIONS`.
- **Bridge** : documenter l’action dans le prompt et la priorité (ex. si `stats.thirst > 0.2` et item buvable en inventaire → drink).

### 1.2 Observations pour les soins

- **Sources PZ** : `player:getBodyDamage():getBodyParts()`, chaque partie peut avoir `getBleedingTime() > 0`, `getBandageNeededDamageLevel()`, etc. `ISInventoryPaneContextMenu.haveDamagePart(player)` retourne les parties endommagées ; `applyBandage(item, bodyPart, player)` utilise `ISApplyBandage:new(playerObj, playerObj, item, bodyPart, true)`.
- **Client** :
  - Dans **buildObservation** : ajouter une structure **body_damage** (ou **injuries**) :
    - Résumé : **is_bleeding** (au moins une partie avec saignement), **needs_bandage** (au moins une partie avec bandage nécessaire), optionnel **body_parts** : liste des parties avec saignement / niveau de dégât pour que le LLM priorise.
  - Dans **inventory** (et conteneurs / world_items) : ajouter **is_bandage** (ou **can_bandage**) pour les items utilisables comme bandage (`item:isCanBandage()` dans le jeu).

### 1.3 Action « appliquer bandage »

- **Client** :
  - Nouvelle **action** `apply_bandage` :
    - Sans paramètre : le client choisit la partie la plus endommagée (ex. `haveDamagePart`, puis partie avec `getBandageNeededDamageLevel()` max) et un bandage en inventaire, puis `ISApplyBandage:new(player, player, item, bodyPart, true)`.
    - Ou avec paramètre optionnel **body_part** (ex. "Hand_R", "Head") et/ou **item_type** pour cibler.
  - Vérifier `isCanBandage()` sur l’item et que la partie nécessite un bandage.
- **Shared** : ajouter `"apply_bandage"` dans `LLMBot.ACTIONS`.
- **Bridge** : priorité (ex. si `body_damage.is_bleeding` ou `needs_bandage` et bandage en inventaire → apply_bandage).

---

## Phase 2 — Repos : dormir

Objectif : que le bot puisse se reposer en dormant pour gérer la fatigue.

### 2.1 Détection d’un lit / lieu pour dormir

- **Sources PZ** : le sommeil passe par `ISSleepDialog` (choix d’heures) puis `getSleepingEvent():setPlayerFallAsleep(player, hours)`, `player:setAsleep(true)`, etc. Le joueur doit être à proximité d’un lit ou d’un objet « sleepable » (bed, etc.). Les tiles avec lit sont détectées côté jeu (building, furniture).
- **Client** :
  - **Observation** : ajouter **near_bed** ou **sleep_spot** (booléen ou position) si le joueur est à proximité d’un lit/sleeping bag (à implémenter via recherche d’objets sur la tile ou les tiles adjacentes — vérifier dans les sources comment le jeu détermine qu’on peut dormir : `ISContextualActions`, furniture avec propriété « bed », etc.).
  - Si l’API expose « current square has bed » ou « adjacent bed », l’exposer dans l’obs (ex. **can_sleep_here**).

### 2.2 Action « dormir »

- **Client** :
  - Nouvelle **action** `sleep` :
    - Optionnel : paramètre **hours** (nombre d’heures, défaut dérivé de la fatigue comme dans ISSleepDialog : base 7h + (fatigue - 0.3)/0.7 * 5).
    - Appeler la même logique que le jeu : ouvrir le sleep dialog revient à `player:setForceWakeUpTime(wakeTime)`, `player:setAsleep(true)`, `getSleepingEvent():setPlayerFallAsleep(player, hours)`. Vérifier dans `ISSleepDialog:onClick` et `ISSleepingUI` / events de sommeil pour ne pas dépendre de l’UI.
  - Si le jeu n’expose pas de « sleep at position » sans UI, il faudra peut‑être déclencher l’event de sommeil directement (recherche dans les sources : `setPlayerFallAsleep`, `SleepingEvent`).
- **Shared** : ajouter `"sleep"` dans `LLMBot.ACTIONS`.
- **Bridge** : priorité (ex. si `stats.fatigue > 0.5` et `near_bed` / `can_sleep_here` → sleep).

---

## Phase 3 — Montée en compétences : livres et lecture

Objectif : exposer les compétences (perks) et permettre au bot de lire des livres pour gagner des multiplicateurs d’XP.

### 3.1 Observations : niveaux de compétences (perks)

- **Sources PZ** : `player:getPerkLevel(Perk)` pour chaque Perk (Strength, Fitness, Sprinting, Cooking, etc.) ; `player:getXp():getXP(perk)` pour l’XP brute. Liste des perks dans le jeu (Perks.*).
- **Client** :
  - Dans **buildObservation** : ajouter **perks** (ou **skills**) : une table [perk_name] = level, pour les perks utiles au bot (ex. Strength, Fitness, Sprinting, Axe, LongBlunt, ShortBlunt, Cooking, Carpentry, Farming, etc.). Ne pas surcharger le JSON ; une liste de 10–15 perks clés suffit.
  - Optionnel : **xp** (getXP) pour affiner les décisions (ex. « proche du niveau supérieur »).

### 3.2 Observations : livres de compétence

- **Sources PZ** : les livres ont `getSkillTrained()`, `getLvlSkillTrained()` (niveau du livre, ex. 1–5), `getMaxLevelTrained()`. Le personnage peut bénéficier du livre si `getLvlSkillTrained() <= getPerkLevel(SkillBook[item:getSkillTrained()].perk) + 1` (ISReadABook.lua). Sinon « trop difficile » ; si `getMaxLevelTrained() < getPerkLevel(...) + 1` le livre est déjà dépassé.
- **Client** :
  - Pour les items (inventaire, conteneurs, world_items) : ajouter **is_literature** (ou **is_skill_book**), **skill_trained** (nom ou id du perk), **level_trained** (niveau du livre, ex. 1–5), **max_level_trained**.
  - Optionnel : **already_read_pages** / **number_of_pages** pour indiquer si le livre est en cours / terminé.
  - Le bridge pourra ainsi dire au LLM : « Tu as un livre Cooking 1 en inventaire ; ton niveau Cooking est 2 → tu peux le lire pour un bonus XP. »

### 3.3 Action « lire un livre »

- **Sources PZ** : `ISReadABook:new(character, item)` (2 arguments). Il faut que le personnage ne soit pas dans le noir (`tooDarkToRead()`), et que le livre soit dans l’inventaire avec des pages à lire.
- **Client** :
  - Nouvelle **action** `read_book` :
    - Paramètre **item_type** ou **item_name** (ou index dans l’inventaire) pour choisir le livre.
    - Vérifier que l’item est un livre (Literature / skill book), qu’il reste des pages, et que ce n’est pas trop sombre (`player:tooDarkToRead()`).
    - `ISTimedActionQueue.add(ISReadABook:new(player, item))`.
  - Optionnel : `read_best_book` sans paramètre — le client choisit un livre de compétence utile (skill_trained où le niveau du joueur est < max_level_trained du livre, et level_trained <= player_perk_level + 1).
- **Shared** : ajouter `"read_book"` (et éventuellement `"read_best_book"`) dans `LLMBot.ACTIONS`.
- **Bridge** : priorité (ex. en sécurité, pas de zombie proche, fatigue pas critique : si un livre « lisible » et utile en inventaire → read_book).

---

## Phase 4 — Améliorations optionnelles (décisions plus fines)

### 4.1 Endurance et repos debout

- **Obs** : `stats.endurance` est déjà exposé. Le jeu utilise `getEnduranceWarning()` pour limiter les actions.
- **Bridge** : indiquer au LLM que si endurance basse, privilégier `idle` (ou éviter sprint / combat prolongé). Pas de nouvelle action client nécessaire.

### 4.2 Zombies : état d’alerte

- **Sources PZ** : si l’API expose « zombie me cible » ou « alerted », l’ajouter dans **zombies[]** (ex. **targeting_player**).
- **Client** : vérifier dans les classes zombie (IsoZombie, etc.) s’il existe un getter (target, isAlerted, etc.) et l’exposer dans l’obs pour que le LLM priorise mieux la fuite.

### 4.3 Crafting et réparation

- Plus lourd : exposer les recettes connues (`isRecipeKnown`), les ingrédients disponibles, et une action **craft** (recipe_id). À traiter dans un second temps si besoin (dépend de HandcraftLogic, ISCraftingUI, etc.).

### 4.4 Soif depuis conteneurs / sources d’eau

- **ISTakeWaterAction** : boire à une source d’eau (rivière, puits). Nécessite de détecter les tiles « eau » à proximité et d’appeler la TimedAction appropriée. Peut compléter l’action « boire » (inventaire) pour les parties longues sans bouteille.

---

## Ordre de mise en œuvre recommandé

| Priorité | Tâche | Fichiers principaux | Dépendances |
|----------|--------|----------------------|-------------|
| 1 | Obs : is_drink / is_water_container sur les items | LLMBot_Client.lua (buildObservation, scan des items) | — |
| 2 | Action drink / drink_best_water | LLMBot_Client.lua (executeCommand), LLMBot_Shared.lua (ACTIONS) | 1 |
| 3 | Obs : body_damage (is_bleeding, needs_bandage) + is_bandage sur items | LLMBot_Client.lua | — |
| 4 | Action apply_bandage | LLMBot_Client.lua, LLMBot_Shared.lua | 3 |
| 5 | Obs : near_bed / can_sleep_here | LLMBot_Client.lua (scan tile/adjacent pour lit) | Sources PZ (furniture, bed) |
| 6 | Action sleep | LLMBot_Client.lua, LLMBot_Shared.lua | 5 + events PZ |
| 7 | Obs : perks (niveaux de compétences) | LLMBot_Client.lua | Perks.*, getPerkLevel |
| 8 | Obs : is_literature, skill_trained, level_trained sur items | LLMBot_Client.lua | getSkillTrained, SkillBook |
| 9 | Action read_book (+ read_best_book optionnel) | LLMBot_Client.lua, LLMBot_Shared.lua | 8, ISReadABook |
| 10 | Mise à jour du prompt bridge (priorités, nouvelles actions/obs) | bridge.py | 1–9 |

---

## Synthèse des nouveaux champs d’observation

| Champ | Description |
|-------|-------------|
| **body_damage** | is_bleeding, needs_bandage [, body_parts[] ] |
| **perks** | { [perk_name]: level } pour les perks principaux |
| **near_bed** / **can_sleep_here** | booléen (ou position) |
| Sur chaque **item** (inventaire, containers, world_items) : | |
| **is_drink** / **is_water_container** | item buvable (eau) |
| **is_bandage** / **can_bandage** | item utilisable comme bandage |
| **is_literature** | livre (skill book) |
| **skill_trained**, **level_trained**, **max_level_trained** | pour les livres |

---

## Synthèse des nouvelles actions

| Action | Paramètres | Description |
|--------|------------|-------------|
| **drink** | — ou item_type / item_name | Boire le meilleur item buvable en inventaire (ou ciblé). |
| **apply_bandage** | — ou body_part, item_type | Appliquer un bandage (partie la plus endommagée ou ciblée). |
| **sleep** | hours? | Dormir (heures optionnelles, dérivées de la fatigue). |
| **read_book** | item_type ou item_name | Lire un livre de compétence. |
| **read_best_book** | — | (Optionnel) Lire un livre utile choisi par le client. |

---

## Vérifications à faire dans les sources PZ

- **Fluid / eau** : identifier tous les cas où un item est « buvable » (Drainable, Water bottle, etc.) et la méthode exacte (ISDrinkFromBottle vs ISDrinkFluidAction) selon le type d’item.
- **Lit** : nom de la propriété ou de la classe pour « bed » / « sleepable » sur une tile ou un objet (ISContextualActions, furniture).
- **Sleep sans UI** : signature de `getSleepingEvent():setPlayerFallAsleep(player, hours)` et préconditions (position, lit).
- **SkillBook** : table SkillBook (mapping skill id → perk) pour exposer le nom du perk dans l’obs (shared Lua ou client).
- **BodyPartType** : noms des parties (Hand_R, Head, etc.) pour les exposer en string dans body_damage.body_parts et pour apply_bandage(body_part).

Ce plan peut être découpé en issues ou tâches courtes et implémenté phase par phase, en mettant à jour le bridge et la synthèse (SYNTHESE_INFOS_LLMBOT.md) à chaque étape.
