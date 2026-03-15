#!/usr/bin/env python3
"""
bridge.py v0.3 — LLMBot bridge enrichi
Usage: python bridge.py [--obs PATH] [--cmd PATH] [--interval SEC] [--dry-run]
"""

import argparse
import json
import time
import sys
from pathlib import Path

try:
    import anthropic
    HAS_ANTHROPIC = True
except ImportError:
    HAS_ANTHROPIC = False
    print("[bridge] anthropic non installe — mode dry-run force")

SYSTEM_PROMPT = """Tu es un survivant dans Project Zomboid (apocalypse zombie).
Tu recois l'etat complet du monde en JSON et tu dois choisir UNE action.

ACTIONS DISPONIBLES :
  {"action": "move_to", "x": INT, "y": INT}
  {"action": "attack_nearest"}
  {"action": "eat_best_food"}
  {"action": "equip_best_weapon"}
  {"action": "loot_container", "x": INT, "y": INT, "z": INT}
  {"action": "say", "text": "message visible en jeu"}
  {"action": "idle"}

PRIORITES DE SURVIE :
1. Si health < 50 et pas de zombie proche → idle (se reposer)
2. Si un zombie est a dist < 3 → attack_nearest si arme equipee (et non cassee), sinon move_to (fuir)
3. Si hunger > 0.6 et nourriture en inventaire → eat_best_food
4. Si pas d'arme equipee et HandWeapon en bon etat en inventaire → equip_best_weapon (ignore armes is_broken ou condition=0)
5. Si conteneur non explore a moins de 5 tiles → loot_container
6. buildings = liste des batiments proches (id, name, dist, alarm) ; tu peux move_to vers un batiment pour explorer
7. Sinon explorer (move_to vers position inconnue)

REGLES :
- Reponds UNIQUEMENT avec le JSON de l'action, rien d'autre, pas de markdown
- Ne jamais attaquer sans arme equipee en bon etat
- Les armes ont condition, condition_max, is_broken (inventaire, conteneurs, equipped) : preferer condition elevee, ignorer is_broken
- Preferencer les conteneurs non explores proches
- Si is_busy=true, prefere idle sauf danger immediat"""


def format_obs_summary(obs: dict) -> str:
    """Formate un resume lisible de l'observation pour les logs."""
    pos   = obs.get("position", {})
    stats = obs.get("stats", {})
    inv   = obs.get("inventory", [])
    zomb  = obs.get("zombies", [])
    cont  = obs.get("containers", [])
    equip = obs.get("equipped", {})

    food_count   = sum(1 for i in inv if i.get("is_food"))
    weapon_count = sum(1 for i in inv if i.get("is_weapon"))
    weapons_ok   = sum(1 for i in inv if i.get("is_weapon") and not i.get("is_broken") and (i.get("condition") or 0) > 0)
    unexplored   = [c for c in cont if not c.get("explored")]
    nearest_z    = min((z["dist"] for z in zomb), default=999)
    buildings    = obs.get("buildings", [])

    primary = equip.get("primary", {})
    primary_name = primary.get("name", "—")
    primary_cond = ""
    if primary.get("is_weapon") and "condition" in primary:
        primary_cond = f" ({primary.get('condition', 0)}/{primary.get('condition_max', 1)})"

    return (
        f"pos=({pos.get('x')},{pos.get('y')}) "
        f"hp={stats.get('health', 0):.0f} "
        f"hunger={stats.get('hunger', 0):.2f} "
        f"thirst={stats.get('thirst', 0):.2f} "
        f"fatigue={stats.get('fatigue', 0):.2f} "
        f"stress={stats.get('stress', 0):.2f} "
        f"morale={stats.get('morale', 0):.2f} "
        f"sanity={stats.get('sanity', 0):.2f} "
        f"infected={stats.get('infected', False)} | "
        f"weapon={primary_name}{primary_cond} | "
        f"inv={len(inv)} items ({food_count} food, {weapon_count} weapons, {weapons_ok} ok) | "
        f"zombies={len(zomb)} (nearest={nearest_z:.0f}t) | "
        f"containers={len(cont)} ({len(unexplored)} unexplored) | "
        f"buildings={len(buildings)} | "
        f"indoors={obs.get('is_indoors')} "
        f"day={obs.get('game_day')} hour={obs.get('game_hour', 0):.1f} "
        f"busy={obs.get('is_busy')} queue={obs.get('action_queue')}"
    )


def format_containers(containers: list) -> str:
    """Formate les conteneurs pour les logs."""
    if not containers:
        return "  (aucun)"
    lines = []
    for c in sorted(containers, key=lambda x: x.get("dist", 999)):
        explored = "✓" if c.get("explored") else "?"
        items    = c.get("items", [])
        preview  = ", ".join(i["name"] for i in items[:3])
        if len(items) > 3:
            preview += f" (+{len(items)-3})"
        lines.append(
            f"  [{explored}] {c.get('name','?')} "
            f"@ ({c.get('x')},{c.get('y')}) dist={c.get('dist')}t"
            + (f" — {preview}" if preview else "")
        )
    return "\n".join(lines)


def query_llm(obs: dict, client) -> dict:
    response = client.messages.create(
        model="claude-opus-4-5",
        max_tokens=150,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": json.dumps(obs, ensure_ascii=False)}],
    )
    raw = response.content[0].text.strip()
    print(f"[bridge] LLM → {raw}")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        print(f"[bridge] JSON invalide, fallback idle")
        return {"action": "idle"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--obs",      default="LLMBot_obs.json")
    parser.add_argument("--cmd",      default="LLMBot_cmd.json")
    parser.add_argument("--interval", type=float, default=2.5)
    parser.add_argument("--dry-run",  action="store_true")
    args = parser.parse_args()

    obs_path = Path(args.obs)
    cmd_path = Path(args.cmd)
    dry_run  = args.dry_run or not HAS_ANTHROPIC

    client = anthropic.Anthropic() if HAS_ANTHROPIC and not dry_run else None

    print(f"[bridge] v0.3 | obs={obs_path} cmd={cmd_path} interval={args.interval}s dry={dry_run}")
    print(f"[bridge] En attente de LLMBot_obs.json...")

    last_mtime = 0

    while True:
        try:
            if not obs_path.exists():
                time.sleep(0.5)
                continue

            mtime = obs_path.stat().st_mtime
            if mtime == last_mtime:
                time.sleep(args.interval)
                continue
            last_mtime = mtime

            with open(obs_path, "r", encoding="utf-8") as f:
                obs = json.load(f)

            # --- Log principal ---
            print(f"\n[bridge] {'='*70}")
            print(f"[bridge] OBS  | {format_obs_summary(obs)}")

            # Log inventaire
            inv = obs.get("inventory", [])
            if inv:
                food    = [i for i in inv if i.get("is_food")]
                weapons = [i for i in inv if i.get("is_weapon")]
                other   = [i for i in inv if not i.get("is_food") and not i.get("is_weapon")]
                if food:
                    print(f"[bridge] FOOD | " + ", ".join(
                        f"{i['name']}(hc={i.get('hunger_change',0):.2f})" for i in food))
                if weapons:
                    wep_str = ", ".join(
                        f"{i['name']}({i.get('condition', '?')}/{i.get('condition_max', '?')}{' BROKEN' if i.get('is_broken') else ''})"
                        for i in weapons
                    )
                    print(f"[bridge] WEAP | " + wep_str)
                if other:
                    print(f"[bridge] INV  | " + ", ".join(
                        f"{i['name']}({i['weight']:.1f}kg)" for i in other[:10]))

            # Log zombies
            zombies = obs.get("zombies", [])
            if zombies:
                zstr = ", ".join(f"({z['x']},{z['y']}) d={z['dist']}" for z in zombies[:5])
                print(f"[bridge] ZOMB | {zstr}")

            # Log conteneurs
            containers = obs.get("containers", [])
            if containers:
                print(f"[bridge] CONT |\n{format_containers(containers)}")

            # Log bâtiments proches
            buildings = obs.get("buildings", [])
            if buildings:
                bstr = ", ".join(f"{b.get('name', '?')}(d={b.get('dist')})" for b in buildings[:5])
                print(f"[bridge] BLDG | {bstr}")

            if dry_run:
                time.sleep(args.interval)
                continue

            # Ne pas appeler le LLM si bot occupé et pas de danger
            zombies_close = any(z["dist"] < 4 for z in obs.get("zombies", []))
            if obs.get("is_busy") and not zombies_close:
                print(f"[bridge] SKIP | bot occupe, pas de danger")
                time.sleep(args.interval)
                continue

            if cmd_path.exists() and cmd_path.stat().st_size > 0:
                print(f"[bridge] SKIP | commande precedente non consommee")
                time.sleep(args.interval)
                continue

            cmd = query_llm(obs, client)

            with open(cmd_path, "w", encoding="utf-8") as f:
                json.dump(cmd, f)
            print(f"[bridge] CMD  | ecrite → {cmd}")

        except KeyboardInterrupt:
            print("\n[bridge] Arret.")
            sys.exit(0)
        except Exception as e:
            print(f"[bridge] ERR  | {e}")

        time.sleep(args.interval)


if __name__ == "__main__":
    main()
