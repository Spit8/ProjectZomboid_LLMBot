# AGENTS.md

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
