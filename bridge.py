#!/usr/bin/env python3
"""
bridge.py v0.4 — LLMBot bridge enrichi
Usage: python bridge.py [--obs PATH] [--cmd PATH] [--interval SEC] [--dry-run] [--full|--light]
"""

import argparse
import json
import os
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
6. buildings = liste des batiments (id, name, dist, alarm, entry, visited=true/false). visited = deja entre au moins une fois. move_to(entry.x, entry.y) pour entrer. building_id = batiment ou tu te trouves (nil si exterieur).
7. visited_buildings_items = objets vus par batiment (id -> liste noms). Utilise pour prioriser batiments non visites ou revenir ou un batiment connu.
8. nearest_unvisited_building = { name, id, dist, entry {x,y}, danger, zombie_count }. Prochain batiment non visite ; danger = sur/faible/moyen/eleve selon zombies autour de l'entree. Preferer danger faible ou sur.
9. Sinon explorer (move_to vers position inconnue)

REGLES :
- Reponds UNIQUEMENT avec le JSON de l'action, rien d'autre, pas de markdown
- Ne jamais attaquer sans arme equipee en bon etat
- Les armes ont condition, condition_max, is_broken (inventaire, conteneurs, equipped) : preferer condition elevee, ignorer is_broken
- Preferencer les conteneurs non explores proches
- Si is_busy=true, prefere idle sauf danger immediat"""


def _safe_dict(v):
    """Retourne un dict (pour .get); évite 'list'/'None' has no attribute 'get'."""
    return v if isinstance(v, dict) else {}


def _safe_list(v):
    """Retourne une liste (pour itération); évite les erreurs sur types inattendus."""
    return v if isinstance(v, list) else []


MEMORY_FILENAME = "LLMBot_memory.json"


def load_memory(memory_path: Path) -> dict:
    """Charge la memoire (batiments visites + objets par batiment)."""
    out = {"visited_building_ids": [], "building_items": {}}
    try:
        if memory_path.exists():
            with open(memory_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            out["visited_building_ids"] = _safe_list(data.get("visited_building_ids"))
            out["building_items"] = _safe_dict(data.get("building_items"))
            for k in list(out["building_items"].keys()):
                if not isinstance(out["building_items"][k], list):
                    out["building_items"][k] = []
    except Exception:
        pass
    return out


def save_memory(memory_path: Path, memory: dict) -> None:
    """Sauvegarde la memoire (batiments visites + objets par batiment)."""
    try:
        with open(memory_path, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "visited_building_ids": memory.get("visited_building_ids", []),
                    "building_items": memory.get("building_items", {}),
                },
                f,
                ensure_ascii=False,
                indent=0,
            )
    except Exception:
        pass


def update_and_enrich_obs(obs: dict, memory: dict, memory_path: Path) -> None:
    """Met a jour la memoire depuis l'obs, enrichit obs (visited sur batiments, visited_buildings_items)."""
    current_bid = obs.get("building_id")
    if current_bid is not None:
        ids = list(memory.get("visited_building_ids", []))
        if current_bid not in ids:
            ids.append(current_bid)
        memory["visited_building_ids"] = ids

    building_items = memory.get("building_items", {})
    for c in _safe_list(obs.get("containers")):
        if not isinstance(c, dict):
            continue
        bid = c.get("building_id")
        if bid is None:
            continue
        key = str(bid)
        if key not in building_items:
            building_items[key] = []
        seen = {x.get("name") for x in building_items[key] if isinstance(x, dict) and x.get("name")}
        for item in _safe_list(c.get("items")):
            if not isinstance(item, dict) or not item.get("name"):
                continue
            name = item.get("name")
            if name in seen:
                continue
            building_items[key].append({"name": name, "type": item.get("type", "")})
            seen.add(name)
    memory["building_items"] = building_items

    visited_set = set(memory.get("visited_building_ids", []))
    for b in _safe_list(obs.get("buildings")):
        if isinstance(b, dict) and "id" in b:
            b["visited"] = b["id"] in visited_set

    obs["visited_buildings_items"] = memory.get("building_items", {})
    obs["visited_building_ids"] = memory.get("visited_building_ids", [])
    save_memory(memory_path, memory)


def format_obs_summary(obs: dict) -> str:
    """Formate un resume lisible de l'observation pour les logs."""
    obs = _safe_dict(obs)
    pos   = _safe_dict(obs.get("position"))
    stats = _safe_dict(obs.get("stats"))
    inv   = _safe_list(obs.get("inventory"))
    zomb  = _safe_list(obs.get("zombies"))
    cont  = _safe_list(obs.get("containers"))
    equip = _safe_dict(obs.get("equipped"))
    buildings = _safe_list(obs.get("buildings"))

    # Items d'inventaire : chaque entrée peut être dict ou autre (ex. liste)
    def item_get(it, key, default=None):
        return it.get(key, default) if isinstance(it, dict) else default

    food_count   = sum(1 for i in inv if item_get(i, "is_food"))
    weapon_count = sum(1 for i in inv if item_get(i, "is_weapon"))
    weapons_ok   = sum(1 for i in inv if item_get(i, "is_weapon") and not item_get(i, "is_broken") and (item_get(i, "condition") or 0) > 0)
    unexplored   = [c for c in cont if not item_get(c, "explored")]
    nearest_z    = min((item_get(z, "dist", 999) for z in zomb if isinstance(z, dict)), default=999)

    primary = _safe_dict(equip.get("primary"))
    primary_name = primary.get("name", "—")
    primary_cond = ""
    if primary.get("is_weapon") and "condition" in primary:
        primary_cond = f" ({primary.get('condition', 0)}/{primary.get('condition_max', 1)})"

    building_id = obs.get("building_id")
    building_name = obs.get("building_name") or ""
    if building_id is not None and building_id != "":
        in_bldg = f"dans {building_name} (id={building_id})"
    else:
        in_bldg = "extérieur"

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
        f"buildings={len(buildings)} total, {len(_safe_list(obs.get('visited_building_ids')))} visités | "
        f"lieu={in_bldg} "
        f"indoors={obs.get('is_indoors')} "
        f"day={obs.get('game_day')} hour={obs.get('game_hour', 0):.1f} "
        f"busy={obs.get('is_busy')} queue={obs.get('action_queue')}"
    )


def format_containers(containers: list) -> str:
    """Formate les conteneurs pour les logs."""
    containers = _safe_list(containers)
    if not containers:
        return "  (aucun)"
    lines = []
    for c in sorted(containers, key=lambda x: x.get("dist", 999) if isinstance(x, dict) else 999):
        if not isinstance(c, dict):
            continue
        explored = "✓" if c.get("explored") else "?"
        items    = _safe_list(c.get("items"))
        preview  = ", ".join(str(i.get("name", "?")) for i in items[:3] if isinstance(i, dict))
        if len(items) > 3:
            preview += f" (+{len(items)-3})"
        lines.append(
            f"  [{explored}] {c.get('name','?')} "
            f"@ ({c.get('x')},{c.get('y')}) dist={c.get('dist')}t"
            + (f" — {preview}" if preview else "")
        )
    return "\n".join(lines)


def format_buildings(buildings: list, max_count: int = 10) -> str:
    """Formate les bâtiments avec ID, nom, [visité], distance et entrée (x,y)."""
    buildings = _safe_list(buildings)
    if not buildings:
        return "  (aucun)"
    lines = []
    for b in buildings[:max_count]:
        if not isinstance(b, dict):
            continue
        bid = b.get("id", "?")
        name, dist = b.get("name", "?"), b.get("dist", "?")
        visited = " [visité]" if b.get("visited") else ""
        entry = _safe_dict(b.get("entry"))
        if entry and "x" in entry and "y" in entry:
            lines.append(f"  id={bid}  {name}{visited}  dist={dist}t  entrée=({entry.get('x')},{entry.get('y')})")
        else:
            lines.append(f"  id={bid}  {name}{visited}  dist={dist}t")
    return "\n".join(lines) if lines else "  (aucun)"


# Rayon (tiles) autour de l'entrée d'un bâtiment pour compter les zombies
ZOMBIES_NEAR_BUILDING_RADIUS = 12


def _zombies_near_point(zombies: list, px: int, py: int, radius: float) -> int:
    """Compte les zombies à moins de radius tiles du point (px, py)."""
    n = 0
    for z in zombies:
        if not isinstance(z, dict):
            continue
        zx, zy = z.get("x"), z.get("y")
        if zx is None or zy is None:
            continue
        d = ((zx - px) ** 2 + (zy - py) ** 2) ** 0.5
        if d <= radius:
            n += 1
    return n


def _danger_label(zombie_count: int) -> str:
    """Note de danger selon le nombre de zombies."""
    if zombie_count == 0:
        return "sûr"
    if zombie_count <= 3:
        return "faible"
    if zombie_count <= 6:
        return "moyen"
    return "élevé"


def format_nearest_unvisited(obs: dict) -> str:
    """Une ligne : bâtiment non visité le plus proche + note de danger (zombies autour de l'entrée). Toujours affiche une note de danger."""
    zombies = _safe_list(obs.get("zombies"))
    pos = _safe_dict(obs.get("position"))
    px, py = pos.get("x"), pos.get("y")

    def danger_near_player() -> str:
        if px is None or py is None:
            return "danger: ?"
        n = _zombies_near_point(zombies, px, py, ZOMBIES_NEAR_BUILDING_RADIUS)
        return f"danger proche: {_danger_label(n)} ({n} z.)"

    buildings = [
        b for b in _safe_list(obs.get("buildings"))
        if isinstance(b, dict) and not b.get("visited")
    ]
    if not buildings:
        return f"[bridge] PROCHAIN | (aucun bâtiment non visité) — {danger_near_player()}"

    nearest = min(buildings, key=lambda b: b.get("dist", 999))
    name = nearest.get("name", "?")
    bid = nearest.get("id", "?")
    dist = nearest.get("dist", "?")
    entry = _safe_dict(nearest.get("entry"))
    ex, ey = entry.get("x"), entry.get("y")
    if ex is not None and ey is not None:
        n = _zombies_near_point(zombies, ex, ey, ZOMBIES_NEAR_BUILDING_RADIUS)
        danger = _danger_label(n)
        return f"[bridge] PROCHAIN | {name} id={bid} dist={dist}t entrée=({ex},{ey}) — danger: {danger} ({n} z.)"
    return f"[bridge] PROCHAIN | {name} id={bid} dist={dist}t (pas d'entrée) — {danger_near_player()}"


def enrich_obs_nearest_unvisited(obs: dict) -> None:
    """Ajoute nearest_unvisited_building (nom, id, dist, entry, danger, zombie_count) pour le LLM."""
    buildings = [
        b for b in _safe_list(obs.get("buildings"))
        if isinstance(b, dict) and not b.get("visited")
    ]
    if not buildings:
        obs["nearest_unvisited_building"] = None
        return
    nearest = min(buildings, key=lambda b: b.get("dist", 999))
    entry = _safe_dict(nearest.get("entry"))
    ex, ey = entry.get("x"), entry.get("y")
    zombies = _safe_list(obs.get("zombies"))
    n = _zombies_near_point(zombies, ex, ey, ZOMBIES_NEAR_BUILDING_RADIUS) if (ex is not None and ey is not None) else 0
    obs["nearest_unvisited_building"] = {
        "name": nearest.get("name"),
        "id": nearest.get("id"),
        "dist": nearest.get("dist"),
        "entry": entry,
        "danger": _danger_label(n),
        "zombie_count": n,
    }


def query_llm(obs: dict, client, log_full: bool = True) -> dict:
    response = client.messages.create(
        model="claude-opus-4-5",
        max_tokens=150,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": json.dumps(obs, ensure_ascii=False)}],
    )
    raw = response.content[0].text.strip()
    if log_full:
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
    parser.add_argument("--dry-run",  action="store_true", help="Ne pas appeler le LLM (pas de clé API requise)")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--full",     action="store_true", help="Logs détaillés (inventaire, zombies, conteneurs, bâtiments)")
    group.add_argument("--light",    action="store_true", help="Une seule ligne par tick (défaut)")
    args = parser.parse_args()

    obs_path = Path(args.obs)
    cmd_path = Path(args.cmd)
    log_full = args.full
    if not args.full and not args.light:
        log_full = False  # défaut = light

    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    dry_run = args.dry_run or not HAS_ANTHROPIC
    if not dry_run and not api_key:
        dry_run = True
        print("[bridge] ANTHROPIC_API_KEY non défini — mode dry-run (pas d'appel LLM)")

    client = None
    if HAS_ANTHROPIC and not dry_run and api_key:
        try:
            client = anthropic.Anthropic(api_key=api_key)
        except Exception as e:
            print(f"[bridge] Erreur client Anthropic: {e} — mode dry-run")
            dry_run = True

    version_str = f"[bridge] v0.4 | obs={obs_path} cmd={cmd_path} interval={args.interval}s dry={dry_run} log={'full' if log_full else 'light'}"
    if log_full:
        print(version_str)
    else:
        # En mode light : effacer et réafficher uniquement le dernier statut (texte peut être multi-ligne)
        def light_refresh(msg: str) -> None:
            sys.stdout.write("\033[2J\033[H")  # clear screen, cursor home (ANSI)
            sys.stdout.write(version_str + "\n")
            if not msg.endswith("\n"):
                msg = msg + "\n"
            sys.stdout.write(msg)
            sys.stdout.flush()

    last_mtime = 0

    while True:
        try:
            if not obs_path.exists():
                if log_full:
                    time.sleep(0.5)
                else:
                    light_refresh("[bridge] En attente de LLMBot_obs.json...")
                    time.sleep(0.5)
                continue

            mtime = obs_path.stat().st_mtime
            if mtime == last_mtime:
                time.sleep(args.interval)
                continue
            last_mtime = mtime

            with open(obs_path, "r", encoding="utf-8") as f:
                raw_obs = json.load(f)
            obs = _safe_dict(raw_obs)

            memory_path = obs_path.parent / MEMORY_FILENAME
            memory = load_memory(memory_path)
            update_and_enrich_obs(obs, memory, memory_path)
            enrich_obs_nearest_unvisited(obs)

            # --- Log (une ligne rafraîchie en light, détaillé en full) ---
            status_line = f"[bridge] OBS  | {format_obs_summary(obs)}"
            if log_full:
                print(f"\n[bridge] {'='*70}")
                print(status_line)
            else:
                # En light : OBS + PROCHAIN (danger) en premier, puis conteneurs + bâtiments
                status_line += "\n" + format_nearest_unvisited(obs)
                containers = _safe_list(obs.get("containers"))
                if containers:
                    status_line += "\n" + format_containers(containers)
                buildings = _safe_list(obs.get("buildings"))
                if buildings:
                    status_line += "\n[bridge] BLDG |\n" + format_buildings(buildings)
                light_refresh(status_line)

            if log_full:
                inv = _safe_list(obs.get("inventory"))
                if inv:
                    def ig(it, k, d=None):
                        return it.get(k, d) if isinstance(it, dict) else d
                    food    = [i for i in inv if isinstance(i, dict) and ig(i, "is_food")]
                    weapons = [i for i in inv if isinstance(i, dict) and ig(i, "is_weapon")]
                    other   = [i for i in inv if isinstance(i, dict) and not ig(i, "is_food") and not ig(i, "is_weapon")]
                    if food:
                        print(f"[bridge] FOOD | " + ", ".join(
                            f"{ig(i,'name','?')}(hc={ig(i,'hunger_change',0):.2f})" for i in food))
                    if weapons:
                        wep_str = ", ".join(
                            f"{ig(i,'name','?')}({ig(i,'condition','?')}/{ig(i,'condition_max','?')}{' BROKEN' if ig(i,'is_broken') else ''})"
                            for i in weapons
                        )
                        print(f"[bridge] WEAP | " + wep_str)
                    if other:
                        print(f"[bridge] INV  | " + ", ".join(
                            f"{ig(i,'name','?')}({ig(i,'weight',0):.1f}kg)" for i in other[:10]))
                zombies = _safe_list(obs.get("zombies"))
                if zombies:
                    zstr = ", ".join(f"({z.get('x')},{z.get('y')}) d={z.get('dist')}" for z in zombies[:5] if isinstance(z, dict))
                    print(f"[bridge] ZOMB | {zstr}")
                containers = _safe_list(obs.get("containers"))
                if containers:
                    print(f"[bridge] CONT |\n{format_containers(containers)}")
                buildings = _safe_list(obs.get("buildings"))
                if buildings:
                    print(f"[bridge] BLDG |\n{format_buildings(buildings)}")
                print(format_nearest_unvisited(obs))

            if dry_run:
                time.sleep(args.interval)
                continue

            # Ne pas appeler le LLM si bot occupé et pas de danger
            zombies_close = any(isinstance(z, dict) and z.get("dist", 999) < 4 for z in _safe_list(obs.get("zombies")))
            if obs.get("is_busy") and not zombies_close:
                if log_full:
                    print(f"[bridge] SKIP | bot occupe, pas de danger")
                time.sleep(args.interval)
                continue

            if cmd_path.exists() and cmd_path.stat().st_size > 0:
                if log_full:
                    print(f"[bridge] SKIP | commande precedente non consommee")
                time.sleep(args.interval)
                continue

            cmd = query_llm(obs, client, log_full)

            with open(cmd_path, "w", encoding="utf-8") as f:
                json.dump(cmd, f)
            cmd = _safe_dict(cmd)
            if log_full:
                print(f"[bridge] CMD  | {cmd.get('action', '?')} → {cmd}")
            else:
                status = f"[bridge] OBS  | {format_obs_summary(obs)}\n"
                status += format_nearest_unvisited(obs) + "\n"
                cont = _safe_list(obs.get("containers"))
                if cont:
                    status += format_containers(cont) + "\n"
                bldg = _safe_list(obs.get("buildings"))
                if bldg:
                    status += "[bridge] BLDG |\n" + format_buildings(bldg) + "\n"
                status += f"[bridge] CMD  | {cmd.get('action', '?')}"
                light_refresh(status)

        except KeyboardInterrupt:
            if not log_full:
                sys.stdout.write("\n")
                sys.stdout.flush()
            print("[bridge] Arret.")
            sys.exit(0)
        except Exception as e:
            if not log_full:
                sys.stdout.write("\n")
                sys.stdout.flush()
            print(f"[bridge] ERR  | {e}")

        time.sleep(args.interval)


if __name__ == "__main__":
    main()
