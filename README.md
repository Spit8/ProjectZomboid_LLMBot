# LLMBot — Mod client Project Zomboid

Pilote un personnage PZ via un LLM externe (Claude, Gemini…) ou local (LM Studio, Ollama).
Le mod écrit l'état du monde en JSON, le bridge Python appelle le LLM,
le mod exécute la commande retournée via `ISTimedActionQueue`.

## Structure du dépôt

```
ProjectZomboid_LLMBot/
├── mod.info
├── bridge.py                    # bridge Python (hors jeu)
├── requirements.txt             # dépendances Python
├── start_bridge.bat             # lance le bridge (Windows, chemins Zomboid/Lua)
├── update_mod.bat               # déploie les .lua vers le dossier du mod (à configurer)
├── LLMBot_Client.lua            # boucle principale (client)
├── LLMBot_Shared.lua            # constantes + JSON minimal (shared)
└── docs/                        # documentation
```

En jeu, les fichiers d'échange sont lus/écrits dans le dossier Lua de PZ (souvent `%USERPROFILE%\Zomboid\Lua\` sous Windows).

## Installation

1. **Mod**  
   Copier (ou cloner) le contenu du dépôt dans votre dossier de mods, ou utiliser le Workshop.  
   Activer le mod dans le menu Mods du jeu.

2. **Python**  
   Installer les dépendances (au moins une selon le fournisseur) :
   ```bash
   pip install -r requirements.txt
   ```
   Ou manuellement :
   ```bash
   pip install google-genai anthropic openai python-dotenv
   ```

3. **Clés API**  
   Ne jamais mettre de clé dans le dépôt.  
   Créer un fichier `.env` à la racine du projet (il est dans `.gitignore`) :
   - **Gemini (Google)** : `GEMINI_API_KEY=votre_cle` (recommandé pour démarrer)
   - **Claude (Anthropic)** : `ANTHROPIC_API_KEY=sk-ant-...`
   Si `GEMINI_API_KEY` est défini, le bridge utilise Gemini par défaut ; sinon Claude.  
   Avec `python-dotenv` installé, le bridge charge `.env` au démarrage. Sinon, définir les variables dans le terminal avant de lancer le bridge.

## Utilisation

1. Lancer PZ et rejoindre une partie (solo ou serveur).

2. **Lancer le bridge**  
   - **Windows (recommandé)** : exécuter `start_bridge.bat` depuis la racine du projet. Le script utilise `%USERPROFILE%\Zomboid\Lua\` pour `LLMBot_obs.json` et `LLMBot_cmd.json`.
   - **Ligne de commande** (depuis la racine du projet ou en pointant les fichiers) :
   ```bash
   python bridge.py
   ```
   Ou avec chemins explicites :
   ```bash
   python bridge.py --obs /chemin/vers/LLMBot_obs.json --cmd /chemin/vers/LLMBot_cmd.json --interval 1.0
   ```

3. **Fournisseur LLM**  
   - **Gemini** (défaut si `GEMINI_API_KEY` est défini) :
   ```bash
   python bridge.py --provider gemini
   ```
   Modèle par défaut : `gemini-2.5-flash`. Pour changer : `--gemini-model gemini-2.5-pro` ou `GEMINI_MODEL=gemini-2.5-pro` dans `.env`.
   - **Claude** : `python bridge.py --provider anthropic` (nécessite `ANTHROPIC_API_KEY`).
   - **Local (LM Studio / Ollama)** — pas de clé API :
   ```bash
   pip install openai
   python bridge.py --provider local --local-model qwen3.5-9b
   ```
   Ou dans `.env` : `LOCAL_API_URL=http://localhost:1234/v1` et `LOCAL_MODEL=qwen3.5-9b`, puis `--provider local`.

4. **Test sans LLM** (affichage seul) :
   ```bash
   python bridge.py --dry-run
   ```

## Fichiers d'échange

Le mod Lua et le bridge communiquent via deux fichiers JSON. Le mod écrit dans le dossier Lua de PZ (ex. `%USERPROFILE%\Zomboid\Lua\`), configurable côté mod dans `LLMBot_Shared.lua` (noms par défaut : `LLMBot_obs.json`, `LLMBot_cmd.json`).

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

Le bridge et le mod acceptent une action unique ou un `action_plan` (liste d’actions exécutées une par une).

| Action | Paramètres | Description |
|--------|------------|-------------|
| `move_to` | `x`, `y` | Se déplacer vers une case |
| `open_door` | `x`, `y` | Ouvrir une porte non verrouillée |
| `smash_window` | `x`, `y` | Casser une vitre (arme équipée recommandée) |
| `remove_glass_window` | `x`, `y` | Enlever les bris après smash |
| `climb_through_window` | `x`, `y` | Enjamber (après smash + remove_glass) |
| `loot_container` | `x`, `y` | Ouvrir un conteneur (une seule fois) |
| `take_item_from_container` | `x`, `y`, `item_type` | Prendre un objet dans un conteneur ouvert |
| `grab_world_item` | `x`, `y` | Ramasser un objet au sol (dist=0) |
| `attack_nearest` | — | Attaquer le zombie le plus proche |
| `eat_best_food` | — | Manger la meilleure nourriture |
| `drink` | — | Boire |
| `apply_bandage` | — | Appliquer un bandage |
| `equip_best_weapon` | — | Équiper la meilleure arme |
| `equip_weapon` | `item_type` | Équiper une arme par type |
| `equip_clothing` | `item_type` | Équiper un vêtement |
| `drop_heaviest` | — | Déposer l’objet le plus lourd |
| `sprint_toggle` | — | Activer/désactiver la course |
| `say` | `text` | Dire un message (chat) |
| `idle` | — | Ne rien faire |

Exemples JSON :

```json
{"action": "move_to", "x": 12050, "y": 8234}
{"action": "attack_nearest"}
{"action": "loot_container", "x": 12048, "y": 8232}
{"action": "equip_best_weapon"}
{"action": "eat_best_food"}
{"action": "drop_heaviest"}
{"action": "sprint_toggle"}
{"action": "idle"}
```

## Limites connues

- **Kahlua** (Lua 5.1 de PZ) n’a pas `io.*` ni `os.*` — les I/O fichier passent par `java.io.*` via `luajava.bindClass`.
- **Un compte Steam par bot** en multijoueur standard. En mode `-nosteam` (serveur dédié), plusieurs instances peuvent tourner.
- **Latence LLM** (~1–3 s) : le mod a un TICK_RATE (ex. 15 ticks) pour ne pas submerger le bridge ; le bot reste sur sa dernière action pendant l’attente.
- Les `ISTimedAction*` disponibles varient selon la version de PZ (tester avec Build 41.78 LTS ou Build 42).

## Étapes suivantes

- [ ] Mémoire épisodique : stocker les dernières actions dans l’obs
- [ ] Détection des bâtiments proches via `IsoBuilding`
- [ ] Compétition : scores (jours survécus, zombies tués) via RCON
- [ ] Mode multi-bot : N bridges avec N comptes sur serveur `-nosteam`
