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

3. Installer les dépendances Python (au moins une selon le fournisseur) :
   ```bash
   pip install anthropic        # pour Claude (Anthropic)
   pip install google-genai      # pour Gemini (Google)
   pip install python-dotenv     # optionnel : chargement automatique de .env
   ```

4. Exporter votre clé API selon le fournisseur choisi :
   - **Gemini (Google)** : `GEMINI_API_KEY` (recommandé pour démarrer)
     ```bash
     set GEMINI_API_KEY=votre_cle_gemini
     ```
   - **Claude (Anthropic)** : `ANTHROPIC_API_KEY`
     ```bash
     set ANTHROPIC_API_KEY=sk-ant-...
     ```
   Si `GEMINI_API_KEY` est défini, le bridge utilise Gemini par défaut ; sinon Claude.

   **Ne jamais mettre sa clé dans le dépôt.** Pour garder la clé hors du repo : copiez `.env.example` en `.env` à la racine du projet, remplissez vos clés dans `.env`. Le fichier `.env` est listé dans `.gitignore` et ne sera pas commité. Le bridge charge automatiquement `.env` au démarrage si le module `python-dotenv` est installé (`pip install python-dotenv`). Sinon, définissez les variables dans le terminal avant de lancer le bridge.

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

3. Pour utiliser **Gemini** explicitement (avec `GEMINI_API_KEY` défini) :
   ```bash
   python bridge.py --provider gemini
   ```
   Modèle par défaut : `gemini-2.5-flash`. Pour Gemini Pro : `--gemini-model gemini-2.5-pro` ou `set GEMINI_MODEL=gemini-2.5-pro`.

4. Pour utiliser un **modèle local** (LM Studio, Ollama…) — pas de clé API :
   - Démarrer le serveur dans LM Studio (Local Server, port 1234 par défaut).
   - Charger le modèle (ex. Qwen3.5 9B) et noter le nom affiché.
   ```bash
   pip install openai
   python bridge.py --provider local --local-model qwen3.5-9b
   ```
   Ou dans `.env` : `LOCAL_API_URL=http://localhost:1234/v1` et `LOCAL_MODEL=qwen3.5-9b`, puis `--provider local`.

5. Pour tester sans LLM (affichage seul) :
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
