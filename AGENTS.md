# AGENTS.md

## Règle obligatoire — Vérification des sources Project Zomboid

**Avant toute modification d'un fichier Python (`.py`) ou Lua (`.lua`) de ce dépôt**, l'agent DOIT consulter les sources Lua du jeu pour vérifier les API, signatures de fonctions, noms de classes et comportements utilisés.

Chemin des sources du jeu :
```
C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\media\lua
```

Étapes à suivre systématiquement :
1. Identifier quelles API / classes / fonctions PZ sont concernées par la modification.
2. Lire les fichiers sources pertinents dans le dossier ci-dessus (par exemple `client/ISUI/`, `client/TimedActions/`, `shared/`, etc.).
3. Vérifier que les noms de méthodes, paramètres et comportements correspondent bien aux sources du jeu.
4. Seulement ensuite, procéder à la modification.

Cela s'applique aussi bien aux fichiers Lua du mod (`LLMBot_Client.lua`, `LLMBot_Shared.lua`) qu'au bridge Python (`bridge.py`) qui génère des commandes JSON consommées par le mod.

## Règle obligatoire — Déploiement automatique après modification Lua

**Après toute modification de `LLMBot_Client.lua` et/ou `LLMBot_Shared.lua`**, l'agent DOIT exécuter `update_mod.bat` pour déployer les fichiers modifiés dans le dossier du mod Project Zomboid.

```
update_mod.bat
```

Ce script copie les fichiers vers :
- `LLMBot_Client.lua` → `C:\Users\wiwil\Zomboid\Workshop\LLMBot\Contents\mods\LLMBot\42\media\lua\client\`
- `LLMBot_Shared.lua` → `C:\Users\wiwil\Zomboid\Workshop\LLMBot\Contents\mods\LLMBot\42\media\lua\shared\`

L'exécution doit avoir lieu **après le commit** des fichiers modifiés, afin que le jeu utilise immédiatement la dernière version du mod.

## Cursor Cloud specific instructions

### Project overview

LLMBot is a Project Zomboid mod with a Python bridge (`bridge.py`). The Lua mod files (`LLMBot_Client.lua`, `LLMBot_Shared.lua`) run inside the game engine and cannot be tested outside of Project Zomboid. The Python bridge is the only component runnable in this environment.

### Running the bridge

- **Dry-run mode** (no API key needed): `python3 bridge.py --dry-run --obs <obs_file>`
- **Full mode** (requires `ANTHROPIC_API_KEY`): `python3 bridge.py --obs <obs_file> --cmd <cmd_file>`
- The bridge polls for `LLMBot_obs.json` and writes commands to `LLMBot_cmd.json`. Create a mock obs file for testing (see README for JSON format).
- Use `python3 -u` for unbuffered output when capturing logs.

### Linting and testing

- No test framework or linter is configured in this repository.
- Syntax-check the Python bridge with: `python3 -c "import ast; ast.parse(open('bridge.py').read()); print('OK')"`
- Lua files depend on Project Zomboid's Kahlua engine and `luajava` bindings; they cannot be lint-checked or tested outside the game.

### Dependencies

- Sole Python dependency: `anthropic` (installed via `pip install anthropic`).
- No `requirements.txt` exists; the update script handles installation.
