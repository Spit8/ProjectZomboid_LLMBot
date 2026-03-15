#!/usr/bin/env python3
"""
bridge.py v0.4 — LLMBot bridge enrichi
Usage: python bridge.py [--obs PATH] [--cmd PATH] [--interval SEC] [--dry-run] [--full|--light]
"""

import argparse
import json
import os
import re
import time
import sys
from pathlib import Path

# Charger .env si présent (fichier gitignoré, ne pas committer les clés)
_env_loaded = False
_env_file = Path(__file__).resolve().parent / ".env"
try:
    import dotenv
    if _env_file.exists():
        dotenv.load_dotenv(_env_file)
        _env_loaded = True
    elif Path.cwd() / ".env" != _env_file and (Path.cwd() / ".env").exists():
        dotenv.load_dotenv(Path.cwd() / ".env")
        _env_loaded = True
except ImportError:
    pass


try:
    import anthropic
    HAS_ANTHROPIC = True
except ImportError:
    HAS_ANTHROPIC = False
    print("[bridge] anthropic non installe — mode dry-run force")

try:
    from google import genai
    from google.genai import types
    HAS_GEMINI = True
except ImportError:
    HAS_GEMINI = False
    print("[bridge] google-genai non installe — provider gemini indisponible")

try:
    from openai import OpenAI
    HAS_OPENAI = True
except ImportError:
    HAS_OPENAI = False
    print("[bridge] openai non installe — provider local (LM Studio) indisponible")

SYSTEM_PROMPT = """Tu es un survivant dans Project Zomboid (apocalypse zombie).
Tu recois l'etat complet du monde en JSON et tu dois choisir UNE action par tour.

PLAN D'ACTION — LISTE D'ACTIONS (recommandé) :
Tu peux envoyer une LISTE d'actions que le bridge executera une par une sans te rappeler a chaque fois. Reponds avec :
- "action_plan" (optionnel) : un TABLEAU d'actions a executer dans l'ordre. Chaque element est un objet action (ex. {"action": "move_to", "x": 12050, "y": 8234}). Le bridge enverra la premiere au jeu, puis la suivante quand la precedente est terminee, etc. Tu n'es rappele que quand la liste est vide.
- "plan" (optionnel) : une phrase decrivant ton objectif (pour log).
- "action" (obligatoire si pas d'action_plan) : une seule action a executer ce tour.
Si tu envoies "action_plan", donne 3 a 10 actions coherentes (ex. move_to vers un batiment, open_door, move_to vers un conteneur, loot_container, take_item_from_container...). Inclus les coordonnees x,y (et z si besoin) pour move_to, loot_container, etc. en t'appuyant sur l'observation (containers[].x/y, nearest_unvisited_building.entry, etc.).
Exemple avec liste : {"action_plan": [{"action": "move_to", "x": 12050, "y": 8234}, {"action": "open_door", "x": 12050, "y": 8235}, {"action": "move_to", "x": 12048, "y": 8232}, {"action": "loot_container", "x": 12048, "y": 8232}], "plan": "Entrer et fouiller la cuisine"}
Exemple une action : {"action": "eat_best_food"}

REGLE CRITIQUE — OBJETS ET CONTENEURS A PORTEE :
- Si "world_item_on_tile_hint" est present : objet sur ta case (dist=0). Reponds UNIQUEMENT avec {"action": "grab_world_item", "x": <hint.x>, "y": <hint.y>}. Pas move_to.
- Si "container_nearby_hint" est present : conteneur a proximite (dist<=2). Regle OUVERTURE UNIQUE : chaque conteneur ne doit etre ouvert qu'UNE FOIS avec loot_container. Si "already_opened" ou "explored" est true dans le hint, n'envoie JAMAIS loot_container — utilise UNIQUEMENT take_item_from_container avec un item_type ou item_name pris dans "items_of_interest" (priorite) ou "items". Si le conteneur n'est pas encore ouvert, envoie loot_container une seule fois pour ouvrir ; au tour suivant utilise take_item_from_container.
- LOOT D'INTERET (priorite pour take_item_from_container) : nourriture, boisson, medecine (bandages, desinfectant, suture, antalgiques), armes et outils de combat, sacs (Bag/Backpack/Duffel), vetements et protection, munitions, lampe torche, briquet, montre, eau. Utilise UNIQUEMENT le champ "items_of_interest" du hint pour choisir quoi prendre ; n'accumule pas de bric-a-brac (papier, magazines, chiffons, jouets, etc.). Reponds avec {"action": "take_item_from_container", "x": INT, "y": INT, "z": INT?, "item_type": "Base.XXX"} ou "item_name": "Nom".
- ENCHAINE LES PRISES : quand un conteneur est deja ouvert (container_nearby_hint avec already_opened) et qu'il contient plusieurs items_of_interest, envoie un action_plan avec 3 a 5 take_item_from_container (un par item_type prioritaire) pour que le bridge les enchaîne sans te rappeler a chaque prise.
- Si "all_nearby_containers_empty" est true : pas de loot proche. Change d'objectif : etablis un action_plan (t'eloigner des zombies si proches, puis move_to vers nearest_unvisited_building pour fouiller un nouveau batiment). N'envoie pas idle.
- Si "last_take_item_result" a ok=false : le dernier take_item_from_container a echoue (item non trouve). Essayer un autre item_type/item_name dans la liste items du conteneur (utiliser exactement type ou name affiche), ou changer de conteneur (move_to autre conteneur ou nearest_unvisited_building).
- Si "switch_container_hint" est present : echecs repetes sur les conteneurs proches ou conteneurs vides. Envoie move_to vers un autre conteneur (containers[] avec is_empty=false, dist>2) ou vers nearest_unvisited_building. N'envoie pas take_item ni loot_container sur place.
- Conteneurs is_empty=true ou dans known_empty_container_positions : ne jamais cibler. Choisir un autre conteneur ou objectif.

ORDRE OBLIGATOIRE — PROXIMITE AVANT INTERACTION :
Tu ne peux interagir avec un conteneur, un objet au sol ou un batiment QUE si tu es deja a proximite. Chaque tour tu n'envoies qu'UNE action ; le jeu met a jour ta position au tour suivant.
- Conteneur (loot_container, take_item_from_container) : utilise "dist" dans containers[]. Si dist > 2, envoie UNIQUEMENT move_to(container.x, container.y). N'envoie loot_container ou take_item_from_container QUE lorsque dist <= 2.
- Objet au sol (grab_world_item) : utilise "dist" dans world_items[]. Si dist > 0, envoie UNIQUEMENT move_to(item.x, item.y). N'envoie grab_world_item QUE lorsque dist = 0 (meme case).
- Batiment a explorer : les conteneurs a l'interieur ne sont visibles qu'une fois proche. Tu DOIS d'abord move_to(nearest_unvisited_building.entry.x, entry.y). Une fois entre, les containers apparaitront ; alors seulement move_to vers un container puis loot_container / take_item_from_container.
- Portes (doors[]) : x, y, is_open, is_locked, dist. Si is_locked=true la porte est verrouillee a cle : open_door ne marche pas (il faut passer par une fenetre). Si is_open=false et is_locked=false, envoie open_door(x, y) puis move_to.
- Fenetres (windows[]) : x, y, is_smashed, is_glass_removed, has_barricade, can_climb_through, dist. Si une porte est verrouillee (is_locked), entre par une fenetre : 1) move_to vers la fenetre (dist <= 1), 2) smash_window(x, y) — a faire de preference avec une arme equipee, 3) remove_glass_window(x, y), 4) climb_through_window(x, y) — OBLIGATOIRE pour enjamber et entrer (sans ca le pathfinding repasse par la porte). 5) move_to vers l'interieur. Ne pas smash_window si has_barricade ou si deja is_smashed. Ne pas remove_glass_window sauf si is_smashed et pas is_glass_removed.
Resume : porte verrouillee → move_to fenetre, smash_window, remove_glass_window, climb_through_window (enjamber), puis move_to interieur. Toujours envoyer climb_through_window apres remove_glass_window pour entrer. Le personnage court automatiquement lors des deplacements.

ACTIONS DISPONIBLES :
  {"action": "move_to", "x": INT, "y": INT, "z": INT?}
  {"action": "open_door", "x": INT, "y": INT, "z": INT?}  — ouvre une porte NON verrouillee (inutile si is_locked=true)
  {"action": "smash_window", "x": INT, "y": INT, "z": INT?}  — casser une fenetre (mieux avec arme equipee)
  {"action": "remove_glass_window", "x": INT, "y": INT, "z": INT?}  — enlever les bris de verre apres avoir casse
  {"action": "climb_through_window", "x": INT, "y": INT, "z": INT?}  — enjamber la fenetre pour entrer (APRES remove_glass_window, avant move_to interieur)
  {"action": "attack_nearest"}
  {"action": "eat_best_food"}
  {"action": "drink"} ou {"action": "drink", "item_type": "Base.WaterBottleFull"} / "item_name": "..."
  {"action": "apply_bandage"} ou {"action": "apply_bandage", "item_type": "Base.Bandage"} / "item_name": "..."
  {"action": "equip_best_weapon"}
  {"action": "equip_weapon", "item_type": "Base.Bat" ou "item_name": "Batte"}
  {"action": "equip_clothing", "item_type": "Base.Jacket" ou "item_name": "Veste"}
  {"action": "loot_container", "x": INT, "y": INT, "z": INT}
  {"action": "take_item_from_container", "x": INT, "y": INT, "z": INT?, "item_type": "Base.X" ou "item_name": "Nom"}
  {"action": "grab_world_item", "x": INT, "y": INT, "z": INT?} ou {"action": "grab_world_item", "index": INT}
  {"action": "drop_heaviest"}
  {"action": "sprint_toggle"}
  {"action": "say", "text": "message visible en jeu"}
  {"action": "idle"}

OBSERVATIONS : position ; stats ; body_damage ; equipped ; inventory[] ; worn_clothing ; world_items (x, y, dist) ; zombies[] ; containers[] (x, y, dist, items, explored, is_empty) ; known_empty_container_positions ; doors[] ; windows[] ; locked_doors_hint ; pathfinding_blocked_by_locked_door (si present : le pathfinding a ete interrompu car une porte verrouillee bloque, tu DOIS choisir move_to vers une fenetre listee) ; pathfinding_stuck (si present : le joueur marche sans avancer, choisis une autre cible ou action) ; world_item_on_tile_hint ; container_nearby_hint ; all_nearby_containers_empty ; nothing_to_do_hint ; buildings[] ; nearest_unvisited_building ; is_busy ; action_queue ; current_action. Si pathfinding_blocked_by_locked_door ou pathfinding_stuck ou world_item_on_tile_hint ou container_nearby_hint est present, applique l'instruction en priorite.

PRIORITES DE SURVIE :
1. Si stats.health < 50 et pas de zombie proche → idle (se reposer)
2. Si body_damage.is_bleeding ou body_damage.needs_bandage et item is_bandage en inventaire → apply_bandage
3. Si zombie a dist < 3 → attack_nearest si arme equipee (non cassee), sinon sprint_toggle + move_to (fuir)
4. Si stats.thirst eleve (ex. > 0.2) et item is_drink en inventaire → drink
5. Si stats.hunger eleve (ex. > 0.5) et nourriture en inventaire → eat_best_food
6. Pas d'arme equipee → equip_best_weapon ou equip_weapon avec item_type
7. Manque protection (worn_clothing) → equip_clothing avec item is_clothing de l'inventaire
8. Objet au sol : si world_items[].dist > 0 → move_to(item.x, item.y). Si dist = 0 (ou world_item_on_tile_hint present) → OBLIGATOIRE grab_world_item(x,y) ou index — jamais move_to quand un objet est sur ta case.
9. Conteneur : is_empty=false uniquement. Si dist > 2 → move_to. Si dist <= 2 et container_nearby_hint present : si already_opened/explored → take_item_from_container avec item_type UNIQUEMENT dans items_of_interest (pas d'objets inutiles). Si pas encore ouvert → loot_container UNE SEULE FOIS puis take_item_from_container aux tours suivants. Pour enchaîner vite : envoie action_plan avec plusieurs take_item_from_container (3-5 items d'interet).
10. Conteneur vide (is_empty ou known_empty_container_positions) : ne jamais cibler. Choisir autre conteneur ou objectif.
11. Si all_nearby_containers_empty=true : tous les conteneurs proches sont vides → ne pas envoyer loot_container ni idle. Etablis un action_plan : t'eloigner des zones de danger (move_to oppose aux zombies si proches), puis aller fouiller un nouveau batiment (move_to nearest_unvisited_building.entry).
12. Porte fermee non verrouillee (is_open=false, is_locked=false) → open_door(door.x, door.y) puis move_to
13. Porte verrouillee : move_to fenetre, smash_window(x,y), remove_glass_window(x,y), puis climb_through_window(x,y) pour enjamber et entrer, puis move_to interieur. Sans climb_through_window le personnage ne rentre pas.
14. Batiment non visite : move_to(entry) ou open_door si porte fermee non verrouillee ; si porte verrouillee, passer par fenetre (smash_window, remove_glass_window, climb_through_window)
15. Trop charge (inventory_weight ~ max_weight) : equip_clothing(sac) ou drop_heaviest

INDICATIONS DE JEU :
- Equiper un sac (sac a dos, sac de sport, etc.) augmente max_weight : utiliser equip_clothing avec un item is_clothing dont body_location est "Back" (ou "Bag") pour porter plus.
- En PZ, une arme a deux mains (is_two_handed) ne retire pas le sac a dos : tu peux garder sac + arme deux mains. is_two_handed sert a savoir comment l'arme est portee (deux mains).
- Les slots worn_clothing (body_location) incluent Torso, Hands, Back, Belt, etc. ; un sac sur le dos (Back) est prioritaire pour la capacite.

REGLES :
- Reponds UNIQUEMENT avec un objet JSON. Soit {"action": "..."} (une action), soit {"action_plan": [{action1}, {action2}, ...], "plan": "description"} (liste d'actions executees par le bridge). Rien d'autre, pas de markdown.
- Si world_item_on_tile_hint ou container_nearby_hint : grab_world_item ou action conteneur (loot_container une seule fois si pas ouvert, sinon take_item_from_container avec item_type de items_of_interest/items). Pas move_to.
- Ne jamais attaquer sans arme equipee en bon etat
- Armes : condition, condition_max, is_broken ; preferer condition elevee
- Si is_busy=true (ou current_action present) : le personnage est occupe. Reponds de preference avec idle. Ne renvoie JAMAIS move_to vers la meme destination que tu viens de donner (cela provoque une boucle). En cas de danger tu peux choisir attack_nearest, apply_bandage, sprint_toggle, open_door, smash_window, remove_glass_window, climb_through_window. N'envoie pas move_to, loot_container, grab_world_item, eat_best_food, drink, equip_* tant qu'il est occupe.
- Ne jamais take/loot/grab si dist trop grand : move_to d'abord.
- Porte fermee non verrouillee : open_door avant move_to. Porte verrouillee : move_to fenetre, smash_window, remove_glass_window, puis climb_through_window pour enjamber (obligatoire), puis move_to interieur.

QUAND TU N'AS PLUS RIEN A FAIRE (nothing_to_do_hint=true dans l'observation, ou all_nearby_containers_empty sans conteneur a proximite, sans urgence sante/zombie immediat) : ne reponds JAMAIS avec {\"action\": \"idle\"}. Tu DOIS etablir un nouveau plan d'action en envoyant \"action_plan\" : 1) S'eloigner des zones de danger : si des zombies sont proches (zombies[].dist < 5), inclus d'abord sprint_toggle et/ou move_to vers une case plus eloignee des zombies (utilise ta position et zombies[].x/y pour choisir une direction opposee). 2) Puis aller fouiller un nouveau batiment : move_to(nearest_unvisited_building.entry.x, entry.y), puis open_door si porte fermee non verrouillee, move_to vers un conteneur, loot_container, etc. Donne 3 a 10 actions dans action_plan et \"plan\" (ex. \"S'eloigner du danger puis fouiller la pharmacie\"). Si nearest_unvisited_building est absent (aucun batiment non visite), utilise move_to vers un conteneur plus loin (containers[] avec is_empty=false) ou idle en dernier recours."""


def _safe_dict(v):
    """Retourne un dict (pour .get); évite 'list'/'None' has no attribute 'get'."""
    return v if isinstance(v, dict) else {}


def _safe_list(v):
    """Retourne une liste (pour itération); évite les erreurs sur types inattendus."""
    return v if isinstance(v, list) else []


MEMORY_FILENAME = "LLMBot_memory.json"


def _container_key(c: dict) -> str | None:
    """Cle unique pour un conteneur (x,y,z)."""
    x, y, z = c.get("x"), c.get("y"), c.get("z")
    if x is None or y is None:
        return None
    z = z if z is not None else 0
    return f"{int(x)},{int(y)},{int(z)}"


# Nombre max de positions de conteneurs vides a retenir (evite croissance infinie)
MAX_EMPTY_CONTAINERS_MEMORY = 80


# Nombre max d'actions recentes pour la memoire persistante (contexte logique pour le LLM)
MAX_RECENT_ACTIONS = 15

# Nombre max de conteneurs "deja ouverts" a retenir (eviter de rappeler loot_container)
MAX_OPENED_CONTAINERS_MEMORY = 120

# Apres ce nombre d'echecs take_item sur un meme conteneur, on suggere de changer de conteneur
TAKE_FAIL_THRESHOLD = 2

# Nombre max d'actions en file (quand le LLM envoie action_plan)
MAX_PENDING_ACTIONS = 50

# Tokens max pour la reponse LLM (liste d'actions peut etre longue)
MAX_RESPONSE_TOKENS = 400

# Distance max (tiles) pour considerer que le joueur a "atteint" la cible d'un move_to (2 = a cote ou case d a cote)
MOVE_TARGET_TOLERANCE_TILES = 2

# Distance max pour considerer un conteneur "a portee" (loot/take sans move_to d'abord). 2 = adjacent ou une case de plus.
CONTAINER_NEARBY_DIST = 2

# Nombre max de cibles move_to en echec a retenir (evite de renvoyer la meme cible apres pathfinding_stuck / timeout)
MAX_FAILED_MOVE_TARGETS = 10

# Apres ce nombre de skips consecutifs (position non atteinte / pas a proximite), on force le deblocage (~10-12 s avec interval 1-2 s)
MAX_POSITION_SKIP_BEFORE_RECOVERY = 5

# Apres ce nombre de skips pour is_busy, on envoie quand meme (evite blocage si obs ne se met pas a jour)
MAX_BUSY_SKIP_BEFORE_RECOVERY = 40

# Apres ce nombre de skips "cmd non consommee", on considere le fichier cmd obsolete et on reprend (evite ~37 s d'attente)
MAX_CMD_PENDING_SKIP_BEFORE_RECOVERY = 5

# Apres ce nombre de take_item_from_container identiques (meme conteneur + meme item), on force idle pour casser la boucle (action buggee cote jeu)
MAX_TAKE_REPEAT_BEFORE_SKIP = 2

# Actions qui necessitent d'etre a la position (x, y) pour reussir
POSITION_DEPENDENT_ACTIONS = (
    "loot_container", "take_item_from_container", "grab_world_item",
    "open_door", "smash_window", "remove_glass_window", "climb_through_window",
)

# Objets d'interet pour la survie dans Project Zomboid (survie, combat, capacite, medecine, utilitaire)
# Refs : guides PZ (fire station, police, pharmacy, gigamart), types Base.* courants
# Objets a ne pas prioriser (bric-a-brac, peu utiles en survie)
LOOT_JUNK_OR_LOW_VALUE = (
    "Rotten", "Corpse", "Sheet", "Paper", "Newspaper", "Pencil", "Eraser", "Pen",
    "Magazine", "Book", "Comic", "Poster", "Fabric", "RippedSheets", "Thread",
    "Soap", "Perfume", "Makeup", "Lipstick", "Comb", "Hairspray", "Toothbrush",
    "Toy", "Plush", "BoardGame", "Doll", "Sponge", "Scrub", "DisinfectantWipe",
    "Empty", "Broken", "Scrap", "ScrapMetal", "Garbage", "Trash", "Leaflet",
)

LOOT_INTEREST_KEYWORDS = (
    # Eau et boissons
    "Water", "Bottle", "WaterBottle", "PopBottle", "Canteen", "Soda", "Beer", "Wine",
    # Nourriture
    "Food", "Canned", "Cereal", "Fruit", "Vegetable", "Meat", "Fish", "Bread", "Pasta", "Rice",
    "Chocolate", "Candy", "Chip", "Crisp", "Tin", "Can", "Frozen", "Fresh",
    # Medecine et premiers secours
    "Bandage", "FirstAid", "Disinfectant", "Alcohol", "Antiseptic", "Suture", "Needle", "Holder",
    "Sterilized", "Cotton", "Pills", "Painkiller", "Vitamins", "Antidepressant", "BetaBlockers",
    "Splint", "SutureNeedle", "SutureHolder", "Wound", "Plaster", "Adhesive",
    # Armes et outils de combat
    "Weapon", "Bat", "Axe", "Knife", "BaseballBat", "Crowbar", "Hammer", "Golfclub", "Machete",
    "Spade", "Spear", "Pipe", "Wrench", "Screwdriver", "LeadPipe", "Nightstick", "HockeyStick",
    "WoodAxe", "HandAxe", "Katana", "Machete", "BaseballBat", "Guitar", "Pan",
    # Sacs et capacite
    "Bag", "Backpack", "Duffel", "Satchel", "FannyPack", "PlasticBag", "Handbag", "Briefcase",
    "GarbageBag", "HikingBag", "SchoolBag", "AlicePack", "Military",
    # Vetements et protection
    "Clothing", "Jacket", "Boots", "Shirt", "Pants", "Shoes", "Sweater", "Hat", "Gloves",
    "Vest", "Bulletproof", "Firefighter", "Hoodie", "Jacket", "Trousers", "Socks", "Scarf",
    "Helmet", "Mask", "Goggles", "Leather", "Denim",
    # Munitions et armes a feu
    "Ammo", "Bullets", "Shotgun", "Rifle", "Pistol", "Magazine", "BoxOf", "Round", "Cartridge",
    "9mm", "45", "308", "556", "Shell", "Bullet",
    # Utilitaire (nuit, feu, temps)
    "Flashlight", "Torch", "Lighter", "Matches", "Watch", "DigitalWatch", "Radio", "Walkie",
)


def _player_distance_to(obs: dict, tx: int | float, ty: int | float) -> float:
    """Retourne la distance (Manhattan) du joueur a la tile (tx, ty). 999 si position inconnue."""
    pos = _safe_dict(obs.get("position"))
    px, py = pos.get("x"), pos.get("y")
    if px is None or py is None or tx is None or ty is None:
        return 999.0
    try:
        return abs(float(px) - float(tx)) + abs(float(py) - float(ty))
    except (TypeError, ValueError):
        return 999.0


def _player_at_or_near(obs: dict, x: int | float, y: int | float, max_dist: float = 1.0) -> bool:
    """True si le joueur est a au plus max_dist tiles de (x, y)."""
    return _player_distance_to(obs, x, y) <= max_dist


def _normalize_cmd(cmd: dict) -> dict:
    """Convertit x, y, z en entiers pour les actions qui en ont besoin."""
    if not isinstance(cmd, dict) or not cmd.get("action"):
        return _safe_dict(cmd)
    out = dict(cmd)
    if out.get("action") in (
        "move_to", "open_door", "smash_window", "remove_glass_window", "climb_through_window", "climb_through_window",
        "grab_world_item", "loot_container", "take_item_from_container",
    ):
        for key in ("x", "y", "z"):
            if key in out and out[key] is not None:
                try:
                    out[key] = int(round(float(out[key])))
                except (TypeError, ValueError):
                    pass
    return out


def _collapse_consecutive_same_move_to(actions: list) -> list:
    """Supprime les move_to consecutifs vers la meme destination (evite envoi en rafale)."""
    if not actions or len(actions) < 2:
        return list(actions)
    out = []
    last_move = None
    for c in actions:
        if not isinstance(c, dict) or not c.get("action"):
            continue
        if c.get("action") == "move_to":
            try:
                key = (int(c.get("x") or 0), int(c.get("y") or 0))
            except (TypeError, ValueError):
                key = None
            if key and key == last_move:
                continue
            last_move = key
        else:
            last_move = None
        out.append(c)
    return out


def _item_is_of_interest(item: dict) -> bool:
    """True si l'item est dans la liste de loot d'interet (survie, combat, capacite), hors bric-a-brac."""
    if not isinstance(item, dict):
        return False
    name = (item.get("name") or "").lower()
    typ = (item.get("type") or "").lower()
    for junk in LOOT_JUNK_OR_LOW_VALUE:
        if junk.lower() in name or junk.lower() in typ:
            return False
    if item.get("is_food") or item.get("is_drink") or item.get("is_bandage") or item.get("is_weapon"):
        return True
    for kw in LOOT_INTEREST_KEYWORDS:
        if kw.lower() in name or kw.lower() in typ:
            return True
    return False


def load_memory(memory_path: Path) -> dict:
    """Charge la memoire (batiments, conteneurs vides, dernier loot, actions recentes, objectif, plan LLM)."""
    out = {
        "visited_building_ids": [],
        "building_items": {},
        "empty_container_positions": [],
        "opened_container_positions": [],
        "take_fail_count": {},
        "last_loot_target": None,
        "loot_repeat_count": 0,
        "recent_actions": [],
        "current_goal": None,
        "llm_plan": None,
        "pending_action_queue": [],
        "last_sent_command": None,
        "recent_failed_move_targets": [],
    }
    try:
        if memory_path.exists():
            with open(memory_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            out["visited_building_ids"] = _safe_list(data.get("visited_building_ids"))
            out["building_items"] = _safe_dict(data.get("building_items"))
            for k in list(out["building_items"].keys()):
                if not isinstance(out["building_items"][k], list):
                    out["building_items"][k] = []
            out["empty_container_positions"] = _safe_list(data.get("empty_container_positions"))
            out["opened_container_positions"] = _safe_list(data.get("opened_container_positions"))[-MAX_OPENED_CONTAINERS_MEMORY:]
            out["take_fail_count"] = _safe_dict(data.get("take_fail_count"))
            out["last_loot_target"] = data.get("last_loot_target")
            out["loot_repeat_count"] = int(data.get("loot_repeat_count", 0)) if data.get("loot_repeat_count") is not None else 0
            out["recent_actions"] = _safe_list(data.get("recent_actions"))[-MAX_RECENT_ACTIONS:]
            out["current_goal"] = data.get("current_goal")
            out["llm_plan"] = data.get("llm_plan")
            out["pending_action_queue"] = _safe_list(data.get("pending_action_queue"))[:MAX_PENDING_ACTIONS]
            out["last_sent_command"] = _safe_dict(data.get("last_sent_command")) or None
            out["recent_failed_move_targets"] = _safe_list(data.get("recent_failed_move_targets"))[-MAX_FAILED_MOVE_TARGETS:]
    except Exception:
        pass
    return out


def save_memory(memory_path: Path, memory: dict) -> None:
    """Sauvegarde la memoire (batiments, conteneurs vides/ouverts, take_fail_count, loot, actions recentes, objectif, plan LLM)."""
    try:
        with open(memory_path, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "visited_building_ids": memory.get("visited_building_ids", []),
                    "building_items": memory.get("building_items", {}),
                    "empty_container_positions": memory.get("empty_container_positions", []),
                    "opened_container_positions": memory.get("opened_container_positions", [])[-MAX_OPENED_CONTAINERS_MEMORY:],
                    "take_fail_count": memory.get("take_fail_count", {}),
                    "last_loot_target": memory.get("last_loot_target"),
                    "loot_repeat_count": memory.get("loot_repeat_count", 0),
                    "recent_actions": memory.get("recent_actions", [])[-MAX_RECENT_ACTIONS:],
                    "current_goal": memory.get("current_goal"),
                    "llm_plan": memory.get("llm_plan"),
                    "pending_action_queue": memory.get("pending_action_queue", [])[:MAX_PENDING_ACTIONS],
                    "last_sent_command": memory.get("last_sent_command"),
                    "recent_failed_move_targets": memory.get("recent_failed_move_targets", [])[-MAX_FAILED_MOVE_TARGETS:],
                },
                f,
                ensure_ascii=False,
                indent=0,
            )
    except Exception:
        pass


def update_and_enrich_obs(obs: dict, memory: dict, memory_path: Path) -> None:
    """Met a jour la memoire depuis l'obs, enrichit obs (visited, conteneurs vides, visited_buildings_items)."""
    # Si on a cible le meme conteneur 3 fois de suite sans succes, le considerer vide et ne plus le proposer
    repeat_count = memory.get("loot_repeat_count", 0)
    last_target = memory.get("last_loot_target")
    if repeat_count >= 3 and last_target:
        empty_positions = list(memory.get("empty_container_positions", []))
        if last_target not in empty_positions:
            empty_positions.append(last_target)
        memory["empty_container_positions"] = empty_positions[-MAX_EMPTY_CONTAINERS_MEMORY:]
        memory["last_loot_target"] = None
        memory["loot_repeat_count"] = 0

    current_bid = obs.get("building_id")
    if current_bid is not None:
        ids = list(memory.get("visited_building_ids", []))
        if current_bid not in ids:
            ids.append(current_bid)
        memory["visited_building_ids"] = ids

    building_items = memory.get("building_items", {})
    empty_positions = list(memory.get("empty_container_positions", []))
    empty_set = set(empty_positions)

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

        # Memoire des conteneurs vides et deja ouverts
        ckey = _container_key(c)
        explored = c.get("explored") is True
        items = _safe_list(c.get("items"))
        if ckey and explored:
            opened = list(memory.get("opened_container_positions", []))
            if ckey not in opened:
                opened.append(ckey)
                memory["opened_container_positions"] = opened[-MAX_OPENED_CONTAINERS_MEMORY:]
        if ckey and explored and len(items) == 0:
            if ckey not in empty_set:
                empty_positions.append(ckey)
                empty_set.add(ckey)
        # Marquer is_empty pour le LLM (ce tour ou memoire)
        c["is_empty"] = (explored and len(items) == 0) or (ckey in empty_set)

    if len(empty_positions) > MAX_EMPTY_CONTAINERS_MEMORY:
        empty_positions = empty_positions[-MAX_EMPTY_CONTAINERS_MEMORY:]
    memory["empty_container_positions"] = empty_positions

    visited_set = set(memory.get("visited_building_ids", []))
    for b in _safe_list(obs.get("buildings")):
        if isinstance(b, dict) and "id" in b:
            b["visited"] = b["id"] in visited_set

    obs["visited_buildings_items"] = memory.get("building_items", {})
    obs["visited_building_ids"] = memory.get("visited_building_ids", [])
    obs["known_empty_container_positions"] = empty_positions

    # Mise a jour du compteur d'echecs take_item (depuis le resultat envoye par le client Lua)
    last_take = obs.get("last_take_item_result")
    if isinstance(last_take, dict):
        ckey = None
        x, y, z = last_take.get("x"), last_take.get("y"), last_take.get("z")
        if x is not None and y is not None:
            z = z if z is not None else 0
            ckey = f"{int(x)},{int(y)},{int(z)}"
        if ckey:
            fail_count = dict(memory.get("take_fail_count", {}))
            if last_take.get("ok") is True:
                fail_count.pop(ckey, None)
            else:
                fail_count[ckey] = fail_count.get(ckey, 0) + 1
                if len(fail_count) > MAX_OPENED_CONTAINERS_MEMORY:
                    fail_count = dict(list(fail_count.items())[-MAX_OPENED_CONTAINERS_MEMORY:])
            memory["take_fail_count"] = fail_count

    # Memoire des portes verrouillees (open_door a echoue) : ne pas reessayer open_door, utiliser fenetre ou abandonner
    last_door = obs.get("last_open_door_result")
    if isinstance(last_door, dict):
        x, y = last_door.get("x"), last_door.get("y")
        if x is not None and y is not None:
            door_key = f"{int(x)},{int(y)}"
            locked = list(memory.get("locked_door_positions", []))
            if last_door.get("ok") is False and last_door.get("reason") == "locked":
                if door_key not in locked:
                    locked.append(door_key)
                memory["locked_door_positions"] = locked[-15:]
            elif last_door.get("ok") is True:
                locked = [p for p in locked if p != door_key]
                memory["locked_door_positions"] = locked

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
    drink_count  = sum(1 for i in inv if item_get(i, "is_drink"))
    bandage_count = sum(1 for i in inv if item_get(i, "is_bandage"))
    weapon_count = sum(1 for i in inv if item_get(i, "is_weapon"))
    weapons_ok   = sum(1 for i in inv if item_get(i, "is_weapon") and not item_get(i, "is_broken") and (item_get(i, "condition") or 0) > 0)
    body = _safe_dict(obs.get("body_damage"))
    body_str = "bleed" if body.get("is_bleeding") else ""
    if body.get("needs_bandage"):
        body_str = (body_str + " bandage" if body_str else "bandage")
    if not body_str:
        body_str = "ok"
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
        f"body={body_str} | "
        f"inv={len(inv)} items ({food_count} food, {drink_count} drink, {bandage_count} bandage, {weapon_count} weapons, {weapons_ok} ok) | "
        f"zombies={len(zomb)} (nearest={nearest_z:.0f}t) | "
        f"containers={len(cont)} ({len(unexplored)} unexplored) | "
        f"buildings={len(buildings)} total, {len(_safe_list(obs.get('visited_building_ids')))} visités | "
        f"lieu={in_bldg} "
        f"indoors={obs.get('is_indoors')} "
        f"day={obs.get('game_day')} hour={obs.get('game_hour', 0):.1f} "
        f"busy={obs.get('is_busy')} queue={obs.get('action_queue')} current_action={obs.get('current_action')}"
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
    """Formate les bâtiments avec ID, nom, [visité], distance, entrée, zombies intérieur, danger entrée."""
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
        z_inside = b.get("zombie_count")
        z_entrance = b.get("entrance_zombie_count")
        danger = b.get("entrance_danger", "")
        extra = ""
        if z_inside is not None:
            extra += f"  intérieur={z_inside}"
        if z_entrance is not None and danger:
            extra += f"  porte={z_entrance} ({danger})"
        if entry and "x" in entry and "y" in entry:
            lines.append(f"  id={bid}  {name}{visited}  dist={dist}t  entrée=({entry.get('x')},{entry.get('y')}){extra}")
        else:
            lines.append(f"  id={bid}  {name}{visited}  dist={dist}t{extra}")
    return "\n".join(lines) if lines else "  (aucun)"


# Rayon (tiles) autour de l'entrée d'un bâtiment pour compter les zombies
ZOMBIES_NEAR_BUILDING_RADIUS = 20


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
    """Note de danger (sans accent pour affichage console Windows)."""
    if zombie_count == 0:
        return "sur"
    if zombie_count <= 3:
        return "faible"
    if zombie_count <= 6:
        return "moyen"
    return "eleve"


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


def enrich_obs_locked_doors_hint(obs: dict) -> None:
    """Si des portes ont is_locked=true, ajoute un hint explicite pour le LLM."""
    doors = _safe_list(obs.get("doors"))
    locked = [d for d in doors if isinstance(d, dict) and d.get("is_locked") is True]
    if locked:
        obs["locked_doors_hint"] = (
            "ATTENTION: des portes sont verrouillees a cle (is_locked=true). "
            "open_door ne marche PAS. Ta premiere action doit etre move_to(fenetre.x, fenetre.y) pour QUITTER la porte et aller vers une fenetre (windows[]), "
            "puis smash_window, remove_glass_window si besoin. N'envoie jamais open_door sur une porte verrouillee."
        )
    else:
        obs["locked_doors_hint"] = None


def get_best_window_for_locked_door(obs: dict) -> dict | None:
    """Retourne la meilleure fenetre vers laquelle se deplacer quand une porte est verrouillee.
    Fenetre utilisable : pas barricadee, et soit deja franchissable (can_climb_through),
    soit a casser (not is_smashed) ou a debarrasser (is_smashed et pas is_glass_removed).
    Les windows[] sont deja triees par dist cote Lua."""
    windows = _safe_list(obs.get("windows"))
    for w in windows:
        if not isinstance(w, dict):
            continue
        if w.get("has_barricade") is True:
            continue
        if w.get("can_climb_through") is True:
            return w
        if w.get("is_smashed") is not True:
            return w
        if w.get("is_glass_removed") is not True:
            return w
    return None


def build_pathfinding_stuck_block(obs: dict) -> str:
    """Quand le joueur est en WalkTo depuis longtemps sans bouger (pathfinding bloque) : demander au LLM une autre decision."""
    if not isinstance(obs, dict) or obs.get("pathfinding_stuck") is not True:
        return ""
    return (
        "*** PATHFINDING BLOQUE (joueur en marche sans progression) ***\n"
        "Le personnage est en train de marcher mais n'avance pas (obstacle, mur, etc.). "
        "Choisis une autre action : une autre cible (move_to vers une fenetre, un autre conteneur), ou une action sur place. "
        "Ne re-envoie pas le meme move_to vers la meme cible.\n\n"
    )


def build_move_to_recovery_hint(memory: dict) -> str:
    """Apres un recovery (cible non atteinte) ou pathfinding_stuck : dire au LLM de ne pas renvoyer le meme move_to."""
    failed = memory.get("last_failed_move_to_target") if isinstance(memory, dict) else None
    if not isinstance(failed, dict):
        return ""
    x, y = failed.get("x"), failed.get("y")
    if x is None or y is None:
        return ""
    return (
        "*** NE PAS RENVOYER LE MEME move_to ***\n"
        f"La cible ({int(x)},{int(y)}) n'a pas ete atteinte (timeout ou pathfinding bloque). "
        "Tu DOIS choisir une AUTRE action : move_to vers une autre case (autre fenetre, autre conteneur), idle, ou une action sur place. "
        "N'envoie surtout pas move_to(" + str(int(x)) + "," + str(int(y)) + ") encore une fois.\n\n"
    )


def build_reached_move_to_hint(memory: dict, obs: dict) -> str:
    """Si le joueur est a proximite de la derniere cible move_to, dire au LLM de ne pas renvoyer le meme move_to (hint persistant tant qu'il est sur place)."""
    target = memory.get("last_move_to_target") if isinstance(memory, dict) else None
    if not isinstance(target, dict):
        return ""
    x, y = target.get("x"), target.get("y")
    if x is None or y is None:
        return ""
    if not _player_at_or_near(obs, x, y, MOVE_TARGET_TOLERANCE_TILES):
        return ""
    return (
        "*** TU ES DEJA ARRIVE A PROXIMITE DE CETTE CIBLE ***\n"
        f"Le personnage est deja a proximite de ({int(x)},{int(y)}) (dernier move_to). "
        "N'envoie PAS move_to(" + str(int(x)) + "," + str(int(y)) + ") encore : tu ferais une boucle. "
        "Fais l'action suivante : climb_through_window(x,y) si tu es devant une fenetre cassee, open_door(x,y), loot_container(x,y), ou move_to vers une AUTRE case.\n\n"
    )


def build_pathfinding_blocked_block(obs: dict) -> str:
    """Quand le pathfinding a ete interrompu car une porte verrouillee bloque : demander au LLM de choisir une fenetre."""
    blocked = obs.get("pathfinding_blocked_by_locked_door") if isinstance(obs, dict) else None
    if not isinstance(blocked, dict):
        return ""
    door = blocked.get("door") or {}
    target = blocked.get("target") or {}
    windows = _safe_list(blocked.get("windows"))
    door_pos = f"({int(door.get('x', 0))},{int(door.get('y', 0))})"
    target_pos = f"({int(target.get('x', 0))},{int(target.get('y', 0))})"
    win_str = ", ".join(f"({int(w.get('x', 0))},{int(w.get('y', 0))})" for w in windows[:8] if isinstance(w, dict))
    return (
        "*** PATHFINDING BLOQUE — PORTE VERROUILLEE ***\n"
        f"Tu voulais aller vers {target_pos} mais une porte verrouillee en {door_pos} bloque le chemin. "
        "L'action a ete interrompue. Cette porte est maintenant en memoire (ne plus tenter open_door dessus).\n"
        f"Tu DOIS envoyer move_to vers une de ces fenetres : {win_str}. "
        "Puis smash_window(x,y), remove_glass_window(x,y), climb_through_window(x,y), puis move_to vers ta cible.\n"
        "Reponds UNIQUEMENT avec move_to(fenetre.x, fenetre.y) en choisissant une fenetre dans la liste ci-dessus. Pas open_door, pas idle, pas le meme move_to vers la cible.\n\n"
    )


def build_locked_door_failed_block(obs: dict, memory: dict) -> str:
    """Quand open_door vient d'echouer (porte verrouillee), instruire le LLM : ne pas reessayer, utiliser fenetre ou abandonner."""
    last_door = obs.get("last_open_door_result") if isinstance(obs, dict) else None
    if not isinstance(last_door, dict) or last_door.get("ok") is not False or last_door.get("reason") != "locked":
        return ""
    x, y = last_door.get("x"), last_door.get("y")
    pos = f"({int(x)},{int(y)})" if x is not None and y is not None else "(position inconnue)"
    return (
        "*** PORTE VERROUILLEE — NE PAS REESSAYER open_door ***\n"
        f"Tu viens d'essayer open_door en {pos} : la porte est verrouillee a cle. open_door ne marchera pas.\n"
        "Ta PROCHAINE action doit etre move_to(fenetre.x, fenetre.y) pour QUITTER la porte et aller vers une fenetre (windows[]). "
        "N'envoie ni open_door ni idle : envoie move_to vers une fenetre utilisable (pas has_barricade). "
        "Ensuite : smash_window, remove_glass_window, puis climb_through_window(x,y) pour enjamber (OBLIGATOIRE), puis move_to a l'interieur.\n"
        "Si aucune fenetre utilisable : envoie action_plan avec move_to(nearest_unvisited_building.entry) pour fouiller ailleurs. Ne renvoie jamais open_door vers cette porte.\n\n"
    )


def enrich_obs_world_item_on_tile(obs: dict) -> None:
    """Si un objet au sol est sur la meme case que le joueur (dist=0), ajoute un hint pour forcer grab_world_item."""
    items = _safe_list(obs.get("world_items"))
    on_tile = [i for i in items if isinstance(i, dict) and (i.get("dist") == 0 or i.get("dist") == 0.0)]
    if on_tile:
        first = on_tile[0]
        obs["world_item_on_tile_hint"] = {
            "action": "grab_world_item",
            "x": first.get("x"),
            "y": first.get("y"),
            "z": first.get("z"),
            "name": first.get("name"),
            "message": "Un objet est sur ta case (dist=0). Envoie UNIQUEMENT grab_world_item avec ces x,y — pas move_to.",
        }
    else:
        obs["world_item_on_tile_hint"] = None


def build_player_busy_block(obs: dict) -> str:
    """Bloc explicite en tête du message quand le personnage est occupé (pour que le LLM le voie en premier)."""
    is_busy = obs.get("is_busy") is True
    if not is_busy:
        return ""
    queue = obs.get("action_queue") or 0
    current = obs.get("current_action") or "action_en_cours"
    return (
        "*** JOUEUR OCCUPE (PLAYER BUSY) ***\n"
        f"Le personnage est actuellement occupe: {current} (file d'actions: {queue}).\n"
        "Reponds de preference avec {\"action\": \"idle\"} sauf en cas de danger immediat (zombie proche, saignement, sante critique).\n"
        "N'envoie pas move_to, loot_container, grab_world_item, eat_best_food, drink ni equip_* tant qu'il est occupe.\n\n"
    )


def build_already_moving_hint(obs: dict, memory: dict) -> str:
    """Quand on est deja en train de se deplacer vers l'objectif, demander idle pour eviter de renvoyer le meme move_to en boucle."""
    goal = memory.get("current_goal") or ""
    if "se deplacer vers" not in goal:
        return ""
    if not obs.get("is_busy") or (obs.get("current_action") or "") != "walking":
        return ""
    return (
        "*** DEJA EN MARCHE *** Tu es deja en train de te deplacer vers ta cible. "
        "Ne renvoie PAS move_to vers la meme destination. Reponds UNIQUEMENT avec {\"action\": \"idle\"} jusqu'a ton arrivee.\n\n"
    )


def build_memory_summary(obs: dict, memory: dict) -> str:
    """Resume lisible de la memoire pour que le LLM en tienne compte en priorite."""
    parts = []
    llm_plan = memory.get("llm_plan")
    if llm_plan and isinstance(llm_plan, str) and llm_plan.strip():
        parts.append(f"Ton plan actuel (que tu as defini) : {llm_plan.strip()}. Suis ce plan pour choisir l'action ; une fois une etape faite, passe a la suivante.")
    empty_list = memory.get("empty_container_positions", [])
    if empty_list:
        formatted = [f"({p})" for p in empty_list[-15:]]
        parts.append(
            "CONTENEURS A NE PLUS CIBLER (vides ou deja cibles sans succes): "
            + ", ".join(formatted)
            + ". N'envoie NI move_to NI loot_container vers ces positions."
        )
    last_target = memory.get("last_loot_target")
    count = memory.get("loot_repeat_count", 0)
    if last_target and count >= 1:
        parts.append(
            f"ATTENTION: le conteneur {last_target} a deja ete cible {count} fois. "
            "Si tu le revois, change d'objectif (autre conteneur avec is_empty=false, ou batiment non visite)."
        )
    visited_ids = memory.get("visited_building_ids", [])
    if visited_ids:
        parts.append(f"Batiments deja visites (ids): {visited_ids[-10:]}.")
    locked_doors = memory.get("locked_door_positions", [])
    if locked_doors:
        parts.append(
            "Portes verrouillees (ne pas reessayer open_door): "
            + ", ".join(f"({p})" for p in locked_doors[-10:])
            + ". Utiliser fenetre : move_to fenetre, smash_window, remove_glass_window, climb_through_window (enjamber), puis move_to interieur. Sinon move_to(nearest_unvisited_building.entry)."
        )
    failed_move = memory.get("recent_failed_move_targets", [])
    if failed_move:
        parts.append(
            "Cibles move_to en echec (pathfinding bloque / timeout) — NE PAS renvoyer move_to vers ces cases: "
            + ", ".join(f"({p})" for p in failed_move[-8:])
        )
    recent = memory.get("recent_actions", [])
    if recent:
        lines = []
        take_at = {}  # (x,y) -> count
        for e in recent[-15:]:
            if isinstance(e, dict):
                a = e.get("action", "?")
                x, y = e.get("x"), e.get("y")
                if x is not None and y is not None:
                    lines.append(f"{a}({int(x)},{int(y)})")
                    if a == "take_item_from_container":
                        k = (int(x), int(y))
                        take_at[k] = take_at.get(k, 0) + 1
                else:
                    lines.append(a)
            else:
                lines.append(str(e))
        parts.append("Dernieres actions (contexte): " + ", ".join(lines) + ".")
        for (tx, ty), count in take_at.items():
            if count >= 4:
                parts.append(
                    f"Tu as deja pris {count} objets du conteneur ({tx},{ty}). Envisage move_to vers un autre conteneur ou nearest_unvisited_building."
                )
                break
    goal = memory.get("current_goal")
    if goal:
        parts.append(f"Objectif en cours: {goal}.")
    last_take = obs.get("last_take_item_result") if isinstance(obs, dict) else None
    if isinstance(last_take, dict) and last_take.get("ok") is False:
        x, y = last_take.get("x"), last_take.get("y")
        it = last_take.get("item_type") or last_take.get("item_name") or "?"
        parts.append(
            f"Dernier take_item_from_container a ECHOUE a ({x},{y}) pour item_type/item_name={it}. "
            "Essayer un autre item_type dans la liste items du conteneur (utiliser exactement le type ou name affiche), ou changer de conteneur: move_to vers un autre conteneur ou nearest_unvisited_building."
        )
    switch = obs.get("switch_container_hint") if isinstance(obs, dict) else None
    if isinstance(switch, dict) and switch.get("message"):
        parts.append("CHANGER DE CONTENEUR: " + switch.get("message", ""))
    if not parts:
        return "MEMOIRE: aucune contrainte particuliere."
    return "MEMOIRE (a respecter en priorite): " + " ".join(parts)


def enrich_obs_container_nearby(obs: dict, memory: dict) -> None:
    """Si un conteneur non vide est a proximite (dist<=CONTAINER_NEARBY_DIST), ajoute un hint pour loot/take.
    Exclut les conteneurs avec trop d'echecs take_item (on suggere de changer de conteneur)."""
    containers = _safe_list(obs.get("containers"))
    nearby = [c for c in containers if isinstance(c, dict) and c.get("dist") is not None and c.get("dist") <= CONTAINER_NEARBY_DIST]
    nearby_non_empty = [c for c in nearby if not c.get("is_empty")]
    opened_set = set(memory.get("opened_container_positions", []))
    fail_count = memory.get("take_fail_count") or {}

    # Ne pas proposer un conteneur ou take_item a echoue trop souvent : preferer un autre ou suggerer de changer
    def skip_container(cc):
        k = _container_key(cc)
        return k and fail_count.get(k, 0) >= TAKE_FAIL_THRESHOLD

    candidates = [c for c in nearby_non_empty if not skip_container(c)]
    if not candidates and nearby_non_empty:
        # Tous les conteneurs proches ont trop d'echecs : suggerer de changer de conteneur
        obs["switch_container_hint"] = {
            "message": "Echecs repetes de take_item sur les conteneurs a proximite. Change de conteneur: envoie move_to vers un autre conteneur (dans containers[] avec is_empty=false et dist>%d) ou vers nearest_unvisited_building. N'envoie pas take_item ni loot_container ici." % CONTAINER_NEARBY_DIST,
            "reason": "take_fail_repeated",
        }
        obs["container_nearby_hint"] = None
        obs["all_nearby_containers_empty"] = False
        return
    if not candidates:
        obs["switch_container_hint"] = None
        obs["container_nearby_hint"] = None
        obs["all_nearby_containers_empty"] = bool(nearby)
        return

    obs["switch_container_hint"] = None
    def sort_key(cc):
        dist = cc.get("dist") if cc.get("dist") is not None else 999
        explored = 1 if cc.get("explored") else 0
        return (explored, dist)
    candidates.sort(key=sort_key)
    first = candidates[0]
    ckey = _container_key(first)
    explored = first.get("explored") is True
    already_opened = explored or (ckey in opened_set)
    items = _safe_list(first.get("items"))
    items_of_interest = []
    for it in items:
        if not isinstance(it, dict):
            continue
        if _item_is_of_interest(it):
            items_of_interest.append({
                "type": it.get("type"),
                "name": it.get("name"),
            })
    first_item_type = None
    if items_of_interest:
        first_item_type = items_of_interest[0].get("type") or items_of_interest[0].get("name")
    elif items and isinstance(items[0], dict):
        first_item_type = items[0].get("type") or items[0].get("name")
    if already_opened:
        message = (
            "Conteneur DEJA OUVERT (explored=true ou deja ouvert). N'envoie PAS loot_container. "
            "Utilise take_item_from_container avec item_type ou item_name pris dans items_of_interest ou items (priorite: nourriture, boisson, bandages, armes, sacs)."
        )
    else:
        message = (
            "Conteneur pas encore ouvert. Envoie loot_container UNE SEULE FOIS pour ouvrir. "
            "Au tour suivant utilise take_item_from_container avec un item_type de items_of_interest ou items."
        )
    obs["container_nearby_hint"] = {
        "x": first.get("x"),
        "y": first.get("y"),
        "z": first.get("z"),
        "name": first.get("name"),
        "explored": explored,
        "already_opened": already_opened,
        "first_item_type": first_item_type,
        "items_of_interest": items_of_interest[:12],
        "items": [{"type": (it.get("type") or it.get("name")), "name": it.get("name")} for it in items[:15] if isinstance(it, dict)],
        "message": message,
    }
    obs["all_nearby_containers_empty"] = False


def enrich_obs_nothing_to_do_hint(obs: dict) -> None:
    """Indique au LLM qu'il n'a plus rien a faire ici : il doit etablir un nouveau plan (s'eloigner du danger, nouveau batiment a loot)."""
    if obs.get("world_item_on_tile_hint") or obs.get("container_nearby_hint"):
        obs["nothing_to_do_hint"] = False
        return
    if obs.get("all_nearby_containers_empty") is True:
        obs["nothing_to_do_hint"] = True
        return
    obs["nothing_to_do_hint"] = False


def build_nothing_to_do_block(obs: dict) -> str:
    """Quand nothing_to_do_hint=true, rappelle au LLM d'etablir un action_plan (s'eloigner du danger, puis nouveau batiment)."""
    if obs.get("nothing_to_do_hint") is not True:
        return ""
    return (
        "*** RIEN A FAIRE ICI *** Tu n'as plus rien a faire sur place. "
        "Etablis un NOUVEAU PLAN (action_plan) : 1) t'eloigner des zombies si proches (sprint_toggle + move_to oppose), "
        "2) aller fouiller un nouveau batiment (move_to nearest_unvisited_building.entry puis open_door, loot, etc.). "
        "Reponds avec action_plan et \"plan\", pas avec {\"action\": \"idle\"}.\n\n"
    )


def apply_hint_overrides(
    obs: dict,
    cmd: dict,
    last_obs_position: tuple | None = None,
    last_written_move_to: tuple | None = None,
) -> tuple[dict, bool]:
    """Si le LLM a renvoye move_to alors qu'un objet est sur la case ou un conteneur a proximite,
    on force grab_world_item ou loot_container. Si deja en marche vers la meme destination, forcer idle.
    Retourne (commande_finale, override_effectue)."""
    cmd = _safe_dict(cmd)
    # Eviter la boucle : meme move_to que la derniere cible envoyee -> idle (en marche OU deja arrive, pour eviter rafale / re-envoi)
    if cmd.get("action") == "move_to" and last_written_move_to and len(last_written_move_to) >= 2:
        try:
            cx, cy = cmd.get("x"), cmd.get("y")
            if cx is not None and cy is not None:
                lx, ly = last_written_move_to[0], last_written_move_to[1]
                if int(cx) == int(lx) and int(cy) == int(ly):
                    return {"action": "idle"}, True
        except (TypeError, ValueError):
            pass
    # Si on doit changer de conteneur (echecs repetes) et que le LLM renvoie take/loot, forcer move_to vers un autre objectif
    switch = obs.get("switch_container_hint")
    if isinstance(switch, dict) and cmd.get("action") in ("take_item_from_container", "loot_container"):
        nearest = _safe_dict(obs.get("nearest_unvisited_building"))
        entry = _safe_dict(nearest.get("entry"))
        ex, ey = entry.get("x"), entry.get("y")
        if ex is not None and ey is not None:
            override = {"action": "move_to", "x": int(ex), "y": int(ey)}
            if entry.get("z") is not None:
                override["z"] = int(entry["z"])
            return override, True
        # Pas de batiment non visite : prendre un conteneur plus loin (dist > 1, non vide)
        for c in _safe_list(obs.get("containers")):
            if not isinstance(c, dict) or c.get("is_empty") or (c.get("dist") or 0) <= CONTAINER_NEARBY_DIST:
                continue
            cx, cy = c.get("x"), c.get("y")
            if cx is not None and cy is not None:
                return {"action": "move_to", "x": int(cx), "y": int(cy), "z": int(c.get("z") or 0)}, True
        return {"action": "idle"}, True
    if cmd.get("action") != "move_to":
        return cmd, False
    pos = _safe_dict(obs.get("position"))
    px, py = pos.get("x"), pos.get("y")
    cx, cy = cmd.get("x"), cmd.get("y")
    try:
        same_tile = (px is not None and py is not None and cx is not None and cy is not None
                     and int(px) == int(cx) and int(py) == int(cy))
    except (TypeError, ValueError):
        same_tile = False
    # move_to vers la position du tick precedent + distance faible = aller-retour entre 2 cases
    try:
        if last_obs_position and len(last_obs_position) >= 2 and cx is not None and cy is not None and px is not None and py is not None:
            if (int(cx), int(cy)) == (int(last_obs_position[0]), int(last_obs_position[1])) and not same_tile:
                dist = abs(int(cx) - int(px)) + abs(int(cy) - int(py))
                if dist <= 2:  # oscillation entre cases adjacentes
                    return {"action": "idle"}, True
    except (TypeError, ValueError):
        pass
    hint_item = obs.get("world_item_on_tile_hint")
    if isinstance(hint_item, dict) and hint_item.get("action") == "grab_world_item":
        x, y = hint_item.get("x"), hint_item.get("y")
        if x is not None and y is not None:
            override = {"action": "grab_world_item", "x": x, "y": y}
            if hint_item.get("z") is not None:
                override["z"] = hint_item["z"]
            return override, True
    hint_cont = obs.get("container_nearby_hint")
    if isinstance(hint_cont, dict):
        x, y = hint_cont.get("x"), hint_cont.get("y")
        if x is not None and y is not None:
            already_opened = hint_cont.get("already_opened") or hint_cont.get("explored")
            first_type = hint_cont.get("first_item_type")
            if not first_type:
                items = _safe_list(hint_cont.get("items"))
                if items and isinstance(items[0], dict):
                    first_type = items[0].get("type") or items[0].get("name")
            # Conteneur deja ouvert : prendre un objet (take_item), jamais loot_container.
            if already_opened:
                if first_type:
                    override = {"action": "take_item_from_container", "x": x, "y": y, "item_type": first_type}
                else:
                    override = {"action": "idle"}
            elif first_type:
                override = {"action": "take_item_from_container", "x": x, "y": y, "item_type": first_type}
            else:
                override = {"action": "loot_container", "x": x, "y": y}
            if override.get("action") and hint_cont.get("z") is not None:
                override["z"] = hint_cont["z"]
            return override, True
    # move_to vers la case actuelle = boucle ; forcer idle pour casser
    if same_tile:
        return {"action": "idle"}, True
    return cmd, False


def _extract_and_save_llm_plan_text(cmd: dict, memory: dict, memory_path: Path) -> None:
    """Extrait le champ plan (texte) de la reponse LLM, le sauvegarde en memoire et le retire de cmd. Ne touche pas a action_plan (liste d'actions)."""
    if not isinstance(cmd, dict) or "plan" not in cmd:
        return
    plan_val = cmd.pop("plan")
    if plan_val is not None and str(plan_val).strip():
        memory["llm_plan"] = str(plan_val).strip()
        save_memory(memory_path, memory)


def _extract_json_from_llm_response(raw: str) -> str:
    """Extrait une chaine JSON depuis une reponse LLM qui peut contenir des blocs markdown ou du texte."""
    s = raw.strip()
    # Enlever blocs markdown ```json ... ``` ou ``` ... ```
    for pattern in (r"```(?:json)?\s*\n?(.*?)\n?```", r"```(.*?)```"):
        m = re.search(pattern, s, re.DOTALL | re.IGNORECASE)
        if m:
            s = m.group(1).strip()
            break
    # Garder seulement la partie entre premier { et dernier }
    start = s.find("{")
    end = s.rfind("}")
    if start != -1 and end != -1 and end > start:
        s = s[start : end + 1]
    # Supprimer virgules orphelines en fin d'objet/tableau (non valides en JSON strict)
    s = re.sub(r",\s*}", "}", s)
    s = re.sub(r",\s*]", "]", s)
    return s


def _parse_llm_json(raw: str) -> tuple[dict, str]:
    """Parse la reponse JSON du LLM ; fallback idle si invalide. Retourne (cmd_dict, raw_string)."""
    raw = raw.strip()
    print(f"[bridge] LLM -> {raw[:200]}{'...' if len(raw) > 200 else ''}")
    to_parse = _extract_json_from_llm_response(raw)
    if not to_parse or to_parse.find("{") == -1:
        print(f"[bridge] JSON introuvable dans la reponse, fallback idle")
        return {"action": "idle"}, raw
    try:
        data = json.loads(to_parse)
    except json.JSONDecodeError as e:
        print(f"[bridge] JSON invalide ({e}), fallback idle")
        return {"action": "idle"}, raw
    if not isinstance(data, dict):
        print(f"[bridge] Reponse pas un objet JSON, fallback idle")
        return {"action": "idle"}, raw
    has_action = data.get("action")
    has_plan = isinstance(data.get("action_plan"), list) and len(data.get("action_plan", [])) > 0
    if not has_action and not has_plan:
        print(f"[bridge] Champ 'action' (ou 'action_plan') manquant, fallback idle")
        return {"action": "idle"}, raw
    return data, raw


def query_anthropic(user_content: str, client) -> tuple[dict, str]:
    response = client.messages.create(
        model="claude-opus-4-5",
        max_tokens=MAX_RESPONSE_TOKENS,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_content}],
    )
    raw = response.content[0].text
    return _parse_llm_json(raw)


def query_gemini(user_content: str, client, model: str) -> tuple[dict, str]:
    config = types.GenerateContentConfig(
        system_instruction=SYSTEM_PROMPT,
        max_output_tokens=MAX_RESPONSE_TOKENS,
    )
    response = client.models.generate_content(
        model=model,
        contents=user_content,
        config=config,
    )
    raw = (response.text or "").strip()
    return _parse_llm_json(raw)


def query_local(user_content: str, client, model: str) -> tuple[dict, str]:
    """Appel vers un serveur OpenAI-compatible (LM Studio, Ollama, etc.)."""
    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_content},
        ],
        max_tokens=MAX_RESPONSE_TOKENS,
    )
    raw = (response.choices[0].message.content or "").strip()
    return _parse_llm_json(raw)


def query_llm(user_content: str, client, provider: str, log_full: bool = True, gemini_model: str = None, local_model: str = None) -> tuple[dict, str]:
    if provider == "gemini":
        return query_gemini(user_content, client, gemini_model or "gemini-2.5-flash")
    if provider == "local":
        return query_local(user_content, client, local_model or "qwen3.5-9b")
    return query_anthropic(user_content, client)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--obs",      default="LLMBot_obs.json")
    parser.add_argument("--cmd",      default="LLMBot_cmd.json")
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--dry-run",  action="store_true", help="Ne pas appeler le LLM (pas de clé API requise)")
    parser.add_argument("--provider", default=None, choices=["anthropic", "gemini", "local"],
                        help="LLM : anthropic (Claude), gemini (Google) ou local (LM Studio / OpenAI-compatible).")
    parser.add_argument("--gemini-model", default=None,
                        help="Modèle Gemini (ex. gemini-2.5-flash). Défaut : gemini-2.5-flash ou GEMINI_MODEL.")
    parser.add_argument("--local-url", default=None,
                        help="URL du serveur local (LM Studio, Ollama…). Défaut : http://localhost:1234/v1 ou LOCAL_API_URL.")
    parser.add_argument("--local-model", default=None,
                        help="Nom du modèle chargé (ex. qwen3.5-9b). Défaut : LOCAL_MODEL ou qwen3.5-9b.")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--full",     action="store_true", help="Logs détaillés (inventaire, zombies, conteneurs, bâtiments)")
    group.add_argument("--light",    action="store_true", help="Une seule ligne par tick (défaut)")
    args = parser.parse_args()

    obs_path = Path(args.obs)
    cmd_path = Path(args.cmd)
    log_full = args.full
    if not args.full and not args.light:
        log_full = False  # défaut = light

    gemini_key = os.environ.get("GEMINI_API_KEY", "").strip()
    anthropic_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()

    # Secours : si pas de cle et .env existe, charger manuellement (batch ou dotenv ont pu echouer)
    if not gemini_key and not anthropic_key and _env_file.exists():
        try:
            with open(_env_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, _, v = line.partition("=")
                        k, v = k.strip(), v.strip()
                        if v and (v.startswith('"') and v.endswith('"') or v.startswith("'") and v.endswith("'")):
                            v = v[1:-1]
                        if k and k not in os.environ:
                            os.environ[k] = v
            gemini_key = os.environ.get("GEMINI_API_KEY", "").strip()
            anthropic_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
        except Exception:
            pass

    local_url = args.local_url or os.environ.get("LOCAL_API_URL", "http://localhost:1234/v1").strip()
    local_model = args.local_model or os.environ.get("LOCAL_MODEL", "qwen3.5-9b").strip()

    provider = args.provider
    if provider is None:
        if os.environ.get("LOCAL_MODEL") or os.environ.get("LOCAL_API_URL"):
            provider = "local"
        else:
            provider = "gemini" if gemini_key else "anthropic"

    dry_run = args.dry_run
    if provider == "gemini":
        dry_run = dry_run or not HAS_GEMINI
        if not dry_run and not gemini_key:
            dry_run = True
            print("[bridge] GEMINI_API_KEY non défini — mode dry-run (pas d'appel LLM)")
    elif provider == "local":
        dry_run = dry_run or not HAS_OPENAI
        if not dry_run:
            print("[bridge] Provider local : pas de cle API requise.")
    else:
        dry_run = dry_run or not HAS_ANTHROPIC
        if not dry_run and not anthropic_key:
            dry_run = True
            print("[bridge] ANTHROPIC_API_KEY non défini — mode dry-run (pas d'appel LLM)")

    client = None
    gemini_model = args.gemini_model or os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
    if provider == "gemini" and HAS_GEMINI and not dry_run and gemini_key:
        try:
            client = genai.Client(api_key=gemini_key)
        except Exception as e:
            print(f"[bridge] Erreur client Gemini: {e} — mode dry-run")
            dry_run = True
    elif provider == "anthropic" and HAS_ANTHROPIC and not dry_run and anthropic_key:
        try:
            client = anthropic.Anthropic(api_key=anthropic_key)
        except Exception as e:
            print(f"[bridge] Erreur client Anthropic: {e} — mode dry-run")
            dry_run = True
    elif provider == "local" and HAS_OPENAI and not dry_run:
        try:
            base = local_url.rstrip("/")
            if not base.endswith("/v1"):
                base = base + "/v1"
            client = OpenAI(base_url=base, api_key="lm-studio")
        except Exception as e:
            print(f"[bridge] Erreur client local: {e} — mode dry-run")
            dry_run = True

    version_str = f"[bridge] v0.4 | provider={provider}"
    if provider == "gemini":
        version_str += f" model={gemini_model}"
    elif provider == "local":
        version_str += f" url={local_url} model={local_model}"
    version_str += f" obs={obs_path} cmd={cmd_path} interval={args.interval}s dry={dry_run} log={'full' if log_full else 'light'}"

    # Message de demarrage toujours affiche : clé API et mode
    if provider == "local":
        if dry_run:
            print(f"[bridge] *** DRY-RUN : openai non installe ou --dry-run. pip install openai pour LM Studio. ***")
        else:
            print(f"[bridge] API active : provider=local | {local_url} | modele={local_model}")
    else:
        key_var = "GEMINI_API_KEY" if provider == "gemini" else "ANTHROPIC_API_KEY"
        key_set = bool(gemini_key if provider == "gemini" else anthropic_key)
        key_status = "definie" if key_set else "NON DEFINIE"
        if dry_run and not key_set:
            print(f"[bridge] *** DRY-RUN : {key_var} absente. Aucun appel API. ***")
            print(f"[bridge] Definir la cle : fichier .env ou variable d'environnement {key_var}")
            print(f"[bridge] .env cherche : {_env_file} (existe={_env_file.exists()}) | python-dotenv charge : {_env_loaded}")
            if provider == "gemini" and not _env_loaded:
                print(f"[bridge] Astuce : pip install python-dotenv puis creer .env avec GEMINI_API_KEY=ta_cle")
        elif dry_run:
            print(f"[bridge] *** DRY-RUN (--dry-run actif) : pas d'appel API ***")
        else:
            print(f"[bridge] API active : provider={provider} | {key_var}={key_status}")
    print(version_str)
    print()

    if log_full:
        pass  # version_str deja affiche ci-dessus
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
    last_obs_position = None  # (x, y) du tick precedent pour detecter boucles A<->B
    last_written_move_to = None  # (x, y) derniere destination move_to ecrite (eviter de renvoyer le meme en boucle)
    last_api_time = 0.0
    MIN_API_INTERVAL = 15
    position_skip_count = 0  # skips consecutifs pour "position non atteinte" ; apres N on force le deblocage
    busy_skip_count = 0  # skips consecutifs pour is_busy ; apres N on envoie quand meme
    cmd_pending_skip_count = 0  # skips "commande non consommee" ; apres N on force reprise

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
            enrich_obs_locked_doors_hint(obs)
            enrich_obs_world_item_on_tile(obs)
            enrich_obs_container_nearby(obs, memory)
            enrich_obs_nothing_to_do_hint(obs)

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
                if not log_full:
                    light_refresh(status_line + "\n[bridge] (dry-run) pas d'appel API — aucune reponse LLM")
                else:
                    print("[bridge] (dry-run) pas d'appel API")
                time.sleep(args.interval)
                continue

            # Ne pas envoyer de nouvelle commande tant que la precedente n'est pas consommee par le jeu
            if cmd_path.exists() and cmd_path.stat().st_size > 0:
                cmd_pending_skip_count += 1
                print(f"[bridge] SKIP: commande non consommee (attente lecture par le jeu) [{cmd_pending_skip_count}/{MAX_CMD_PENDING_SKIP_BEFORE_RECOVERY}]")
                if cmd_pending_skip_count >= MAX_CMD_PENDING_SKIP_BEFORE_RECOVERY:
                    try:
                        cmd_path.write_text("", encoding="utf-8")
                        print(f"[bridge] RECOVERY: fichier cmd vide force (reprise apres {MAX_CMD_PENDING_SKIP_BEFORE_RECOVERY} ticks)")
                    except Exception as e:
                        print(f"[bridge] RECOVERY: impossible de vider cmd ({e})")
                    cmd_pending_skip_count = 0
                time.sleep(args.interval)
                continue
            cmd_pending_skip_count = 0

            # Ne pas envoyer de nouvelle commande tant que le joueur est occupe (action en cours)
            # Sinon on enverrait la suite de la file avant que l'action precedente soit terminee
            if obs.get("is_busy") is True:
                busy_skip_count += 1
                if busy_skip_count >= MAX_BUSY_SKIP_BEFORE_RECOVERY:
                    busy_skip_count = 0
                    print(f"[bridge] RECOVERY: envoi quand meme apres {MAX_BUSY_SKIP_BEFORE_RECOVERY} skips is_busy")
                else:
                    print(f"[bridge] SKIP: joueur occupe (is_busy=true) [{busy_skip_count}/{MAX_BUSY_SKIP_BEFORE_RECOVERY}]")
                    time.sleep(args.interval)
                    continue
            busy_skip_count = 0

            # Si le jeu signale pathfinding_stuck (marche longue sans progression), on annule le move_to en cours pour redemander au LLM
            if obs.get("pathfinding_stuck") is True:
                last_sent_stuck = memory.get("last_sent_command")
                if isinstance(last_sent_stuck, dict) and last_sent_stuck.get("action") == "move_to":
                    lx, ly = last_sent_stuck.get("x"), last_sent_stuck.get("y")
                    memory["last_failed_move_to_target"] = {"x": lx, "y": ly}
                    if lx is not None and ly is not None:
                        failed_list = list(memory.get("recent_failed_move_targets", []))
                        key = f"{int(lx)},{int(ly)}"
                        if key not in failed_list:
                            failed_list.append(key)
                        memory["recent_failed_move_targets"] = failed_list[-MAX_FAILED_MOVE_TARGETS:]
                    memory["last_sent_command"] = None
                    save_memory(memory_path, memory)
                    position_skip_count = 0
                    print("[bridge] pathfinding_stuck signale par le jeu -> annulation move_to en cours, on redemande au LLM")

            # Ne pas envoyer de nouvelle commande tant que le joueur n'a pas atteint la cible du dernier move_to.
            # Si le client a redirige vers une fenetre, obs.current_walk_target = cible reelle ; on considere "arrive" si proche de l'une ou l'autre.
            last_sent = memory.get("last_sent_command")
            move_to_blocking = False
            if isinstance(last_sent, dict) and last_sent.get("action") == "move_to":
                lx, ly = last_sent.get("x"), last_sent.get("y")
                if lx is not None and ly is not None:
                    at_sent_target = _player_at_or_near(obs, lx, ly, MOVE_TARGET_TOLERANCE_TILES)
                    cw = _safe_dict(obs.get("current_walk_target"))
                    cwx, cwy = cw.get("x"), cw.get("y")
                    at_actual_target = (
                        cwx is not None and cwy is not None
                        and _player_at_or_near(obs, cwx, cwy, MOVE_TARGET_TOLERANCE_TILES)
                    )
                    if not at_sent_target and not at_actual_target:
                        move_to_blocking = True
                        position_skip_count += 1
                        if position_skip_count >= MAX_POSITION_SKIP_BEFORE_RECOVERY:
                            position_skip_count = 0
                            memory["last_failed_move_to_target"] = {"x": lx, "y": ly}
                            if lx is not None and ly is not None:
                                failed_list = list(memory.get("recent_failed_move_targets", []))
                                key = f"{int(lx)},{int(ly)}"
                                if key not in failed_list:
                                    failed_list.append(key)
                                memory["recent_failed_move_targets"] = failed_list[-MAX_FAILED_MOVE_TARGETS:]
                            memory["last_sent_command"] = None
                            save_memory(memory_path, memory)
                            print(f"[bridge] RECOVERY: cible move_to consideree atteinte apres {MAX_POSITION_SKIP_BEFORE_RECOVERY} skips")
                        else:
                            dist = _player_distance_to(obs, lx, ly)
                            print(f"[bridge] SKIP: cible move_to ({int(lx)},{int(ly)}) non atteinte (dist={dist:.0f}) [{position_skip_count}/{MAX_POSITION_SKIP_BEFORE_RECOVERY}]")
                            time.sleep(args.interval)
                            continue
            if not move_to_blocking:
                position_skip_count = 0

            # Si le joueur est deja a proximite de last_move_to_target (ex. fenetre) -> envoyer climb_through_window sans depiler la file ni appeler le LLM (casse la boucle meme avec pending plein de move_to/idle)
            cmd = None
            raw_response = None
            t = memory.get("last_move_to_target")
            if isinstance(t, dict) and t.get("x") is not None and t.get("y") is not None:
                tx, ty = int(t["x"]), int(t["y"])
                if _player_at_or_near(obs, tx, ty, MOVE_TARGET_TOLERANCE_TILES):
                    cmd = {"action": "climb_through_window", "x": tx, "y": ty}
                    raw_response = "(auto: climb_through_window pour sortir de la boucle fenetre)"
                    if log_full:
                        print(f"[bridge] Auto climb_through_window({tx},{ty}) (joueur deja a la cible, priorite sur file/LLM)")

            if cmd is None:
                # File d'actions : si le LLM a envoye une liste (action_plan), on depile une action sans rappeler le LLM
                pending = memory.get("pending_action_queue") or []
                if pending:
                    # Ne pas depiler une action "position" si le joueur n'est pas a proximite (evite loot_container avant d'etre arrive)
                    next_cmd = pending[0] if isinstance(pending[0], dict) else {}
                    next_action = next_cmd.get("action")
                    need_move_to_target = False
                    if next_action in POSITION_DEPENDENT_ACTIONS:
                        nx, ny = next_cmd.get("x"), next_cmd.get("y")
                        # Pour loot/take : considerer "a portee" si a 2 tiles (CONTAINER_NEARBY_DIST)
                        max_dist = CONTAINER_NEARBY_DIST if next_action in ("loot_container", "take_item_from_container") else 1.0
                        if nx is not None and ny is not None and not _player_at_or_near(obs, nx, ny, max_dist):
                            # Envoyer move_to vers la cible pour que le joueur s'y rende au lieu de rester bloque
                            need_move_to_target = True
                    if need_move_to_target:
                        nx, ny = next_cmd.get("x"), next_cmd.get("y")
                        cmd = _normalize_cmd({"action": "move_to", "x": int(nx), "y": int(ny)})
                        if next_cmd.get("z") is not None:
                            cmd["z"] = int(next_cmd["z"])
                        raw_response = f"(approche vers {next_action} ({int(nx)},{int(ny)}), file inchangée)"
                        if log_full:
                            dist = _player_distance_to(obs, nx, ny)
                            print(f"[bridge] Pas a proximite pour {next_action} (dist={dist:.0f}) -> envoi move_to({nx},{ny})")
                        position_skip_count = 0
                    else:
                        position_skip_count = 0
                        cmd = _normalize_cmd(pending.pop(0))
                        memory["pending_action_queue"] = pending
                        save_memory(memory_path, memory)
                        raw_response = f"(depuis file, {len(pending)} restantes)"
                        if log_full:
                            print(f"[bridge] CMD depuis file d'actions (reste {len(pending)})")
                else:
                    # File vide : demander au LLM
                    if log_full:
                        print(f"[bridge] File d'actions vide -> appel LLM pour nouveau plan / action")
                    # Throttle : au moins 15 s entre deux appels pour quota gratuit Gemini (5/min) ; pas pour local
                    if provider == "gemini" and last_api_time and (time.time() - last_api_time) < MIN_API_INTERVAL:
                        wait = MIN_API_INTERVAL - (time.time() - last_api_time)
                        if wait > 0 and not dry_run:
                            if log_full:
                                print(f"[bridge] Attente {wait:.0f}s (quota gratuit)...")
                            time.sleep(wait)

                    pathfinding_blocked_block = build_pathfinding_blocked_block(obs)
                    pathfinding_stuck_block = build_pathfinding_stuck_block(obs)
                    move_to_recovery_hint = build_move_to_recovery_hint(memory)
                    if move_to_recovery_hint:
                        memory.pop("last_failed_move_to_target", None)
                        save_memory(memory_path, memory)
                    reached_move_to_hint = build_reached_move_to_hint(memory, obs)
                    busy_block = build_player_busy_block(obs)
                    already_moving_block = build_already_moving_hint(obs, memory)
                    nothing_to_do_block = build_nothing_to_do_block(obs)
                    locked_door_block = build_locked_door_failed_block(obs, memory)
                    user_content = (
                        pathfinding_blocked_block
                        + pathfinding_stuck_block
                        + move_to_recovery_hint
                        + reached_move_to_hint
                        + busy_block
                        + already_moving_block
                        + nothing_to_do_block
                        + locked_door_block
                        + build_memory_summary(obs, memory)
                        + "\n\nObservation (JSON):\n"
                        + json.dumps(obs, ensure_ascii=False)
                    )
                    try:
                        cmd, raw_response = query_llm(user_content, client, provider, log_full, gemini_model=gemini_model, local_model=local_model)
                        last_api_time = time.time()
                        # Si le LLM a envoye une liste d'actions, remplir la file et prendre la premiere comme commande courante
                        if isinstance(cmd, dict) and "action_plan" in cmd:
                            lst = cmd.get("action_plan")
                            if isinstance(lst, list) and len(lst) > 0:
                                normalized = [_normalize_cmd(c) for c in lst if isinstance(c, dict) and c.get("action")]
                                normalized = _collapse_consecutive_same_move_to(normalized)
                                if normalized:
                                    memory["pending_action_queue"] = normalized[1:][:MAX_PENDING_ACTIONS]
                                    cmd = normalized[0]
                            cmd.pop("action_plan", None)
                        _extract_and_save_llm_plan_text(cmd, memory, memory_path)
                    except Exception as api_err:
                        err_msg = str(api_err).strip() or repr(api_err)
                        is_429 = "429" in err_msg or "RESOURCE_EXHAUSTED" in err_msg or "quota" in err_msg.lower()
                        if is_429:
                            wait_sec = 30
                            print(f"[bridge] Quota depasse (5 req/min en gratuit). Attente {wait_sec}s puis nouvel essai...")
                            time.sleep(wait_sec)
                            try:
                                cmd, raw_response = query_llm(user_content, client, provider, log_full, gemini_model=gemini_model, local_model=local_model)
                                last_api_time = time.time()
                                if isinstance(cmd, dict) and "action_plan" in cmd:
                                    lst = cmd.get("action_plan")
                                    if isinstance(lst, list) and len(lst) > 0:
                                        normalized = [_normalize_cmd(c) for c in lst if isinstance(c, dict) and c.get("action")]
                                        normalized = _collapse_consecutive_same_move_to(normalized)
                                        if normalized:
                                            memory["pending_action_queue"] = normalized[1:][:MAX_PENDING_ACTIONS]
                                            cmd = normalized[0]
                                    cmd.pop("action_plan", None)
                                    _extract_and_save_llm_plan_text(cmd, memory, memory_path)
                            except Exception as retry_err:
                                err_msg = str(retry_err).strip() or repr(retry_err)
                                print(f"[bridge] ERREUR API (apres retry) : {err_msg}")
                                cmd, raw_response = {"action": "idle"}, f"(erreur API) {err_msg}"
                        else:
                            print(f"[bridge] ERREUR API : {err_msg}")
                            print(f"[bridge] Verifiez la cle (GEMINI_API_KEY), le modele et le reseau.")
                            cmd, raw_response = {"action": "idle"}, f"(erreur API) {err_msg}"
                        if not log_full:
                            sys.stdout.write("\n")
                            sys.stdout.flush()

                # Forcer grab/loot ou idle quand hint present ou boucle move_to (evite boucles) — seulement pour reponse LLM
                cmd, overridden = apply_hint_overrides(
                    obs, _safe_dict(cmd), last_obs_position, last_written_move_to
                )
                if overridden and log_full:
                    print(f"[bridge] Override | move_to -> {cmd.get('action')} (hint applique)")
                # Porte verrouillee : ne pas reessayer open_door ; forcer move_to vers une fenetre pour quitter la porte
                if not overridden and cmd.get("action") == "open_door":
                    cx, cy = cmd.get("x"), cmd.get("y")
                    if cx is not None and cy is not None:
                        door_key = f"{int(cx)},{int(cy)}"
                        if door_key in memory.get("locked_door_positions", []):
                            window = get_best_window_for_locked_door(obs)
                            if window and window.get("x") is not None and window.get("y") is not None:
                                cmd = {"action": "move_to", "x": int(window["x"]), "y": int(window["y"])}
                                if window.get("z") is not None:
                                    cmd["z"] = int(window["z"])
                                overridden = True
                                if log_full:
                                    print(f"[bridge] Override | open_door({cx},{cy}) -> move_to fenetre ({window.get('x')},{window.get('y')}) (porte verrouillee)")
                            else:
                                cmd = {"action": "idle"}
                                if log_full:
                                    print(f"[bridge] Override | open_door({cx},{cy}) -> idle (porte verrouillee, aucune fenetre utilisable)")

            # Normaliser et ecrire la commande (depuis file ou LLM)
            cmd = _normalize_cmd(_safe_dict(cmd))
            idle_was_duplicate_move_to = False  # si True, on ne vide pas last_written_move_to pour eviter boucle move_to(A)->idle->move_to(A)
            # Ne pas renvoyer le meme take_item_from_container en boucle (evite boucle quand l'action bugge cote jeu)
            if cmd.get("action") == "take_item_from_container":
                tx, ty = cmd.get("x"), cmd.get("y")
                tz = cmd.get("z") or 0
                it = cmd.get("item_type") or cmd.get("item_name") or ""
                take_key = f"{int(tx)},{int(ty)},{int(tz)},{it}"
                last_take_key = memory.get("last_take_sent_key")
                take_repeat = memory.get("take_repeat_count", 0)
                if last_take_key == take_key and take_repeat >= MAX_TAKE_REPEAT_BEFORE_SKIP:
                    cmd = {"action": "idle"}
                    memory["last_take_sent_key"] = None
                    memory["take_repeat_count"] = 0
                    if log_full:
                        print(f"[bridge] Override | take_item_from_container({take_key}) -> idle (deja envoye {take_repeat} fois)")
            # Ne pas renvoyer le meme move_to d'affilee (evite boucle / rafale) ; garder last_written_move_to pour continuer a bloquer les re-envois
            if cmd.get("action") == "move_to" and last_written_move_to:
                try:
                    cx, cy = cmd.get("x"), cmd.get("y")
                    if cx is not None and cy is not None and (int(cx), int(cy)) == last_written_move_to:
                        cmd = {"action": "idle"}
                        idle_was_duplicate_move_to = True
                except (TypeError, ValueError):
                    pass
            # Ne pas renvoyer move_to vers une cible deja en echec (pathfinding_stuck / timeout)
            if cmd.get("action") == "move_to":
                try:
                    cx, cy = cmd.get("x"), cmd.get("y")
                    if cx is not None and cy is not None:
                        move_key = f"{int(cx)},{int(cy)}"
                        if move_key in memory.get("recent_failed_move_targets", []):
                            cmd = {"action": "idle"}
                            if log_full:
                                print(f"[bridge] Override | move_to({move_key}) -> idle (cible en echec recent)")
                except (TypeError, ValueError):
                    pass
            # Si le joueur est deja a proximite de last_move_to_target (ex. fenetre) : forcer climb_through_window pour casser la boucle idle/move_to
            t = memory.get("last_move_to_target")
            if isinstance(t, dict) and t.get("x") is not None and t.get("y") is not None:
                tx, ty = int(t["x"]), int(t["y"])
                if _player_at_or_near(obs, tx, ty, MOVE_TARGET_TOLERANCE_TILES):
                    if cmd.get("action") == "move_to":
                        cx, cy = cmd.get("x"), cmd.get("y")
                        if cx is not None and cy is not None:
                            cx, cy = int(cx), int(cy)
                            dist_cmd = abs(cx - tx) + abs(cy - ty)
                            if dist_cmd <= MOVE_TARGET_TOLERANCE_TILES:
                                cmd = {"action": "climb_through_window", "x": tx, "y": ty}
                                if log_full:
                                    print(f"[bridge] Override | move_to({cx},{cy}) -> climb_through_window({tx},{ty})")
                    elif cmd.get("action") == "idle":
                        cmd = {"action": "climb_through_window", "x": tx, "y": ty}
                        if log_full:
                            print(f"[bridge] Override | idle -> climb_through_window({tx},{ty}) (joueur deja a la fenetre)")
            with open(cmd_path, "w", encoding="utf-8") as f:
                json.dump(cmd, f)
            # Memoriser la commande envoyee pour verifier (au prochain tick) que la cible move_to est atteinte
            memory["last_sent_command"] = {"action": cmd.get("action")}
            if cmd.get("x") is not None:
                memory["last_sent_command"]["x"] = int(cmd.get("x"))
            if cmd.get("y") is not None:
                memory["last_sent_command"]["y"] = int(cmd.get("y"))
            if cmd.get("z") is not None:
                memory["last_sent_command"]["z"] = int(cmd.get("z"))
            if cmd.get("action") == "move_to":
                cx, cy = cmd.get("x"), cmd.get("y")
                last_written_move_to = (int(cx), int(cy)) if (cx is not None and cy is not None) else None
                if cx is not None and cy is not None:
                    memory["last_move_to_target"] = {"x": int(cx), "y": int(cy)}
                    save_memory(memory_path, memory)
            else:
                # Ne pas effacer last_written_move_to si on a force idle pour "meme cible" -> evite boucle move_to(A) repete
                if not idle_was_duplicate_move_to:
                    last_written_move_to = None
                # Effacer la cible move_to quand on fait une action "sur place" pour ne plus afficher le hint "tu es deja la"
                if cmd.get("action") in (
                    "climb_through_window", "open_door", "smash_window", "remove_glass_window",
                    "loot_container", "take_item_from_container", "grab_world_item"
                ):
                    memory.pop("last_move_to_target", None)
                    save_memory(memory_path, memory)
            if cmd.get("action") == "take_item_from_container":
                tx, ty = cmd.get("x"), cmd.get("y")
                tz = cmd.get("z") or 0
                it = cmd.get("item_type") or cmd.get("item_name") or ""
                take_key = f"{int(tx)},{int(ty)},{int(tz)},{it}"
                if memory.get("last_take_sent_key") == take_key:
                    memory["take_repeat_count"] = memory.get("take_repeat_count", 0) + 1
                else:
                    memory["last_take_sent_key"] = take_key
                    memory["take_repeat_count"] = 1
            if cmd.get("action") == "loot_container":
                x, y, z = cmd.get("x"), cmd.get("y"), cmd.get("z")
                if x is not None and y is not None:
                    loot_key = f"{int(x)},{int(y)},{int(z) if z is not None else 0}"
                    opened = list(memory.get("opened_container_positions", []))
                    if loot_key not in opened:
                        opened.append(loot_key)
                        memory["opened_container_positions"] = opened[-MAX_OPENED_CONTAINERS_MEMORY:]
                    if memory.get("last_loot_target") == loot_key:
                        memory["loot_repeat_count"] = memory.get("loot_repeat_count", 0) + 1
                    else:
                        memory["last_loot_target"] = loot_key
                        memory["loot_repeat_count"] = 1
                    save_memory(memory_path, memory)
            # Memoire persistante : derniere action + objectif en cours (pour decisions logiques du LLM)
            action_name = cmd.get("action")
            entry = {"action": action_name}
            if action_name == "move_to":
                x, y = cmd.get("x"), cmd.get("y")
                if x is not None and y is not None:
                    entry["x"], entry["y"] = int(x), int(y)
                    memory["current_goal"] = f"se deplacer vers ({int(x)},{int(y)})"
            elif action_name == "loot_container":
                x, y, z = cmd.get("x"), cmd.get("y"), cmd.get("z")
                if x is not None and y is not None:
                    entry["x"], entry["y"] = int(x), int(y)
                    if z is not None:
                        entry["z"] = int(z)
                    memory["current_goal"] = f"fouiller conteneur ({int(x)},{int(y)})"
            elif action_name == "grab_world_item":
                x, y = cmd.get("x"), cmd.get("y")
                if x is not None and y is not None:
                    entry["x"], entry["y"] = int(x), int(y)
                    memory["current_goal"] = "ramasser objet au sol"
            elif action_name in ("eat_best_food", "drink"):
                memory["current_goal"] = "manger/boire"
            elif action_name == "idle":
                memory["current_goal"] = None
            recent = list(memory.get("recent_actions", []))
            recent.append(entry)
            memory["recent_actions"] = recent[-MAX_RECENT_ACTIONS:]
            save_memory(memory_path, memory)
            pos = _safe_dict(obs.get("position"))
            last_obs_position = (pos.get("x"), pos.get("y"))
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
                status += f"[bridge] LLM  | {raw_response}\n"
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
