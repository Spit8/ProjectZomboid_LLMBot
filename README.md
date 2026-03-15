# LLMBot — Mod client Project Zomboid

Pilote un personnage PZ via un LLM externe (Claude, GPT-4…).
Le mod écrit l'état du monde en JSON, le bridge Python appelle le LLM,
le mod exécute la commande retournée via `ISTimedActionQueue`.

## Structure

```
LLMBot/
├── mod.info
├── bridge.py                          ← bridge Python (externe au jeu)
└── media/lua/
    ├── shared/LLMBot_Shared.lua       ← constantes + JSON minimal
    └── client/LLMBot_Client.lua       ← boucle principale
```

## Installation

1. Copier le dossier `LLMBot/` dans :
   - **Windows** : `%USERPROFILE%\Zomboid\mods\`
   - **Linux**   : `~/.config/Zomboid/mods/`

2. Activer le mod dans le menu Mods du jeu.

3. Installer les dépendances Python :
   ```bash
   pip install anthropic
   ```

4. Exporter votre clé API :
   ```bash
   export ANTHROPIC_API_KEY="sk-ant-..."
   ```

## Utilisation

1. Lancer PZ et rejoindre le serveur (ou une partie solo en mode multijoueur).

2. Dans un terminal, depuis le **répertoire racine de PZ** (là où tournent les .json) :
   ```bash
   python bridge.py
   ```
   Ou pointer explicitement vers les fichiers :
   ```bash
   python bridge.py \
     --obs /chemin/vers/LLMBot_obs.json \
     --cmd /chemin/vers/LLMBot_cmd.json \
     --interval 2.5
   ```

3. Pour tester sans LLM (affichage seul) :
   ```bash
   python bridge.py --dry-run
   ```

## Fichiers d'échange

Le mod Lua et le bridge communiquent via deux fichiers JSON dans le
répertoire courant de PZ (configurable dans `LLMBot_Shared.lua`) :

| Fichier           | Écrit par  | Lu par    | Contenu                         |
|-------------------|------------|-----------|----------------------------------|
| `LLMBot_obs.json` | Mod Lua    | Bridge    | État du monde (pos, stats, inv…) |
| `LLMBot_cmd.json` | Bridge     | Mod Lua   | Action à exécuter                |

## Format observation (LLMBot_obs.json)

```json
{
  "tick": 123.4,
  "position": {"x": 12045, "y": 8234, "z": 0},
  "stats": {
    "hunger": 0.3, "thirst": 0.1, "fatigue": 0.05,
    "stress": 0.0, "morale": 0.8, "endurance": 0.9,
    "health": 1.0
  },
  "inventory": [
    {"type": "Base.Axe", "name": "Hache", "weight": 1.8, "count": 1}
  ],
  "zombies": [
    {"x": 12047, "y": 8234, "dist": 2}
  ],
  "players": [
    {"username": "Bot2", "x": 12050, "y": 8234, "dist": 5}
  ],
  "action_queue": 0,
  "is_busy": false
}
```

## Commandes disponibles

```json
{"action": "move_to", "x": 12050, "y": 8234}
{"action": "attack_nearest"}
{"action": "loot_container", "x": 12048, "y": 8232, "z": 0}
{"action": "equip_best_weapon"}
{"action": "eat_best_food"}
{"action": "drop_heaviest"}
{"action": "sprint_toggle"}
{"action": "idle"}
```

## Limites connues

- **Kahlua** (Lua 5.1 de PZ) n'a pas `io.*` ni `os.*` — les I/O fichiers
  passent par `java.io.*` via `luajava.bindClass`.
- **Un compte Steam par bot** en mode multijoueur standard.
  En mode `-nosteam` (serveur dédié configuré sans Steam),
  plusieurs instances peuvent tourner sur le même compte.
- **Latence LLM** (~1-3s) : le mod a un TICK_RATE de 60 ticks (~2s)
  pour ne pas submerger le bridge. Le bot reste sur sa dernière action
  pendant ce temps (`ISTimedActionQueue` continue de s'exécuter).
- Les `ISTimedAction*` disponibles varient selon la version de PZ.
  Tester avec Build 41.78 LTS ou Build 42.

## Étapes suivantes

- [ ] Mémoire épisodique : stocker les 5 dernières actions dans l'obs
- [ ] Détection des bâtiments proches via `IsoBuilding`
- [ ] Compétition : scores (jours survécus, zombies tués) via RCON
- [ ] Mode multi-bot : N bridges avec N comptes sur serveur `-nosteam`
