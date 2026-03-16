-- LLMBot_Client.lua v1.1 — Build 42.15
-- Phase 1 : drink, apply_bandage ; obs body_damage, is_drink, is_bandage.
-- Requis: ISDrinkFromBottle, ISApplyBandage (chargés par le jeu)

-- Charger les TimedActions utilisées (conteneur -> inventaire, ramassage au sol, déplacement)
if not ISInventoryTransferUtil then require "TimedActions/ISInventoryTransferUtil" end
if not ISGrabItemAction then require "TimedActions/ISGrabItemAction" end
if not ISWalkToTimedAction then require "TimedActions/WalkToTimedAction" end
-- Sous-classe sans limite getGameSpeed() pour que move_to fonctionne en 3x/4x
LLMBotWalkToTimedAction = ISWalkToTimedAction:derive("LLMBotWalkToTimedAction")
function LLMBotWalkToTimedAction:isValid()
    if self.character.getVehicle and self.character:getVehicle() then return false end
    return true
end
if not ISPathFindAction then
    pcall(function() require "Vehicles/TimedActions/ISPathFindAction" end)
    if not ISPathFindAction then
        pcall(function() require "TimedActions/ISPathFindAction" end)
    end
end
if not ISSmashWindow then require "TimedActions/ISSmashWindow" end
if not ISRemoveBrokenGlass then require "TimedActions/ISRemoveBrokenGlass" end
if not ISClimbThroughWindow then require "TimedActions/ISClimbThroughWindow" end
if not ISOpenContainerTimedAction then require "TimedActions/ISOpenContainerTimedAction" end

-- Resultat du dernier take_item_from_container (rempli par executeCommand, lu dans buildObservation puis remis a nil)
LLMBotLastTakeResult = nil
-- Prise en attente : on a ajoute un transfert mais le jeu peut le annuler (bugged action) ; au tick suivant si pas busy on verifie si l'item est encore dans le conteneur
LLMBotPendingTakeContainer = nil   -- { x, y, z }
LLMBotPendingTakeItemSpec = nil   -- string (item_type ou item_name)
-- Resultat du dernier open_door (ok=false, reason="locked", x, y, z si porte verrouillee)
LLMBotLastOpenDoorResult = nil
-- Cible du dernier move_to (pour detecter pathfinding bloque par porte verrouillee)
LLMBotLastMoveToTarget = nil
-- Debut de la marche en cours (pour detecter pathfinding_stuck : marche longue sans progression)
LLMBotWalkToStartTick = nil
LLMBotWalkToStartX = nil
LLMBotWalkToStartY = nil
-- Redirection fenetre persistante : quand move_to a ete redirige vers une fenetre (porte verrouillee),
-- on conserve l'info jusqu'a ce que le joueur ait enjambe (climb_through_window) ou change de cible.
-- { window = {x,y}, original_target = {x,y} }
LLMBotWindowRedirectPending = nil
-- Sequence fenetre auto en cours : true pendant WalkTo+smash+remove_glass+climb auto-enqueuee.
-- Empeche le bridge d'interrompre avec un nouveau move_to.
LLMBotWindowSequenceActive = false
-- Cible de la sequence fenetre en attente (pour enfiler smash+remove_glass+climb une fois arrive)
LLMBotWindowSequenceTarget = nil  -- { sq, obj, wx, wy }
-- Fenetres en echec (inatteignables) : exclues des prochaines redirections jusqu'au prochain move_to different
LLMBotFailedWindowKeys = LLMBotFailedWindowKeys or {}  -- { "x,y" = count }
-- Derniere cible move_to originale (pour detecter changement de cible et reinitialiser LLMBotFailedWindowKeys)
LLMBotLastMoveToOriginalTarget = nil
-- Cases non walkable connues (cible move_to refusee car isFree=false ou isSolidTrans) : cles "x,y", valeur true. Limite 200.
-- Expose dans obs.non_walkable_positions pour que le LLM ne redemande pas move_to vers ces cases.
LLMBotNonWalkableTiles = LLMBotNonWalkableTiles or {}
local LLMBOT_NON_WALKABLE_MAX = 200
-- Compteur de répétitions "même walkSquare déjà en marche" : si trop élevé, on abandonne pour signaler au LLM.
LLMBotSameWalkToRepeatCount = LLMBotSameWalkToRepeatCount or 0
local SAME_WALKTO_MAX_REPEAT = 4

-- ---------------------------------------------------------------
-- 1. FICHIERS (Zomboid/Lua/)
-- ---------------------------------------------------------------
local function writeFile(filename, content)
    local ok, err = pcall(function()
        local w = getFileWriter(filename, true, false)
        w:write(content)
        w:close()
    end)
    if not ok then print("[LLMBot] writeFile: " .. tostring(err)) end
end

local function readFile(filename)
    local result = nil
    pcall(function()
        local r = getFileReader(filename, false)
        if not r then return end
        local lines = {}
        local line = r:readLine()
        while line ~= nil do
            table.insert(lines, line)
            line = r:readLine()
        end
        r:close()
        result = table.concat(lines, "\n")
    end)
    return result
end

local function deleteFile(filename)
    pcall(function()
        local w = getFileWriter(filename, true, false)
        w:write("")
        w:close()
    end)
end

-- ---------------------------------------------------------------
-- 2. HELPERS
-- ---------------------------------------------------------------

-- Champs condition pour HandWeapon (getCondition, getConditionMax, isBroken)
-- Sources: ISInventoryPane.lua, ISInventoryPaneContextMenu.lua
local function getWeaponConditionFields(item)
    if not item or not instanceof(item, "HandWeapon") then return nil end
    local ok, cond, condMax, broken = pcall(function()
        return item:getCondition(), item:getConditionMax(), item:isBroken()
    end)
    if not ok or cond == nil then return nil end
    return {
        condition     = cond,
        condition_max = condMax or cond,
        is_broken     = (broken == true) or (cond and cond <= 0),
    }
end

-- Enrichit une entrée item (name, type, weight, ...) avec is_clothing et body_location
-- Sources: IsClothing(), getBodyLocation() — ISInventoryPaneContextMenu
local function addClothingFields(item, entry)
    if not item or not entry then return end
    pcall(function()
        if item.IsClothing and item:IsClothing() then
            entry.is_clothing = true
            local loc = item.getBodyLocation and item:getBodyLocation()
            if loc then entry.body_location = tostring(loc) end
        end
    end)
end

-- Phase 1 : item buvable (eau) ou bandage. Sources: getFluidContainer, isWaterSource, isCanBandage — ISInventoryPane.lua
local function addDrinkAndBandageFields(item, entry)
    if not item or not entry then return end
    pcall(function()
        if item.getFluidContainer and item:getFluidContainer() then
            local fc = item:getFluidContainer()
            if not fc:isEmpty() and fc.getPrimaryFluid and fc:getPrimaryFluid() then
                local fluidType = fc:getPrimaryFluid():getFluidTypeString()
                if fluidType == "Water" or fluidType == "CarbonatedWater" then
                    entry.is_drink = true
                end
            end
        end
        if item.isWaterSource and item:isWaterSource() then
            entry.is_drink = true
        end
        if item.isCanBandage and item:isCanBandage() then
            entry.is_bandage = true
        end
    end)
end

-- Phase 1 : resume des degats corporels (saignement, besoin de bandage). Sources: getBodyDamage, getBodyParts, haveDamagePart
local function getBodyDamageSummary(player)
    local out = { is_bleeding = false, needs_bandage = false }
    if not player or not player.getBodyDamage then return out end
    pcall(function()
        if not BodyPartType or not BodyPartType.ToIndex or not BodyPartType.MAX then return end
        local bd = player:getBodyDamage()
        if not bd or not bd.getBodyParts then return end
        local bodyParts = bd:getBodyParts()
        if not bodyParts then return end
        for idx = 0, BodyPartType.ToIndex(BodyPartType.MAX) - 1 do
            local bp = bodyParts:get(idx)
            if bp and not bp:bandaged() then
                if bp.bleeding and bp:bleeding() then out.is_bleeding = true end
                if bp.getBandageNeededDamageLevel and bp:getBandageNeededDamageLevel() and bp:getBandageNeededDamageLevel() > 0 then
                    out.needs_bandage = true
                end
                if bp.scratched and bp:scratched() then out.needs_bandage = true end
                if bp.deepWounded and bp:deepWounded() then out.needs_bandage = true end
                if bp.bitten and bp:bitten() then out.needs_bandage = true end
                if bp.isBurnt and bp:isBurnt() then out.needs_bandage = true end
            end
        end
    end)
    return out
end

-- Objets au sol (IsoWorldInventoryObject) sur les tiles à proximité.
-- Sources: square:getWorldObjects(), getItem() — ISWorldObjectContextMenu, ISGrabItemAction
local WORLD_ITEMS_RADIUS = 3
local WORLD_ITEMS_MAX = 30

local function scanWorldItemsNearPlayer(cell, playerX, playerY, playerZ)
    local result = {}
    if not cell then return result end
    for dx = -WORLD_ITEMS_RADIUS, WORLD_ITEMS_RADIUS do
        for dy = -WORLD_ITEMS_RADIUS, WORLD_ITEMS_RADIUS do
            local sq = cell:getGridSquare(playerX + dx, playerY + dy, playerZ)
            if sq then
                local wobs = sq:getWorldObjects()
                if wobs then
                    for i = 0, wobs:size() - 1 do
                        if #result >= WORLD_ITEMS_MAX then return result end
                        local wob = wobs:get(i)
                        if wob and wob.getItem then
                            local invItem = wob:getItem()
                            if invItem then
                                local entry = {
                                    x     = math.floor(sq:getX()),
                                    y     = math.floor(sq:getY()),
                                    z     = math.floor(sq:getZ()),
                                    dist  = math.floor(math.sqrt((sq:getX() - playerX)^2 + (sq:getY() - playerY)^2)),
                                    name  = tostring(invItem:getName()),
                                    type  = tostring(invItem:getType()),
                                    weight = (invItem.getActualWeight and invItem:getActualWeight()) or 0,
                                }
                                if invItem.IsFood and invItem:IsFood() then
                                    entry.is_food = true
                                    if invItem.getHungerChange then entry.hunger_change = invItem:getHungerChange() end
                                end
                                if instanceof(invItem, "HandWeapon") then
                                    entry.is_weapon = true
                                    local wf = getWeaponConditionFields(invItem)
                                    if wf then
                                        entry.condition = wf.condition
                                        entry.condition_max = wf.condition_max
                                        entry.is_broken = wf.is_broken
                                    end
                                    pcall(function()
                                        if invItem.isTwoHandWeapon and invItem:isTwoHandWeapon() then
                                            entry.is_two_handed = true
                                        end
                                    end)
                                end
                                addClothingFields(invItem, entry)
                                addDrinkAndBandageFields(invItem, entry)
                                table.insert(result, entry)
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(result, function(a, b) return (a.dist or 999) < (b.dist or 999) end)
    return result
end

-- Scanner les conteneurs sur un IsoGridSquare
-- Confirme ISMenuContextWorld.lua : sq:getObjects():size(), sq:getObjects():get(i)
-- Confirme ISOpenContainerTimedAction.lua : obj:getContainer(), container:isExplored()
local function scanSquareContainers(sq, playerX, playerY)
    local result = {}
    if not sq then return result end
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        local container = obj:getContainer()
        if container then
            local items = {}
            -- Ne scanner le contenu que si deja explore (sinon vide cote client)
            if container:isExplored() then
                local cItems = container:getItems()
                for j = 0, math.min(cItems:size() - 1, 9) do
                    local item = cItems:get(j)
                    local entry = {
                        name   = tostring(item:getName()),
                        type   = tostring(item:getType()),
                        weight = item:getActualWeight(),
                    }
                    if item:IsFood() then
                        entry.is_food = true
                        entry.hunger_change = item:getHungerChange()
                    end
                    if instanceof(item, "HandWeapon") then
                        entry.is_weapon = true
                        local wf = getWeaponConditionFields(item)
                        if wf then
                            entry.condition = wf.condition
                            entry.condition_max = wf.condition_max
                            entry.is_broken = wf.is_broken
                        end
                        pcall(function()
                            if item.isTwoHandWeapon and item:isTwoHandWeapon() then
                                entry.is_two_handed = true
                            end
                        end)
                    end
                    addClothingFields(item, entry)
                    addDrinkAndBandageFields(item, entry)
                    table.insert(items, entry)
                end
            end
            local sprite = obj:getSprite()
            local entry = {
                x        = math.floor(sq:getX()),
                y        = math.floor(sq:getY()),
                z        = math.floor(sq:getZ()),
                dist     = math.floor(math.sqrt((sq:getX()-playerX)^2 + (sq:getY()-playerY)^2)),
                name     = sprite and tostring(sprite:getName()) or "unknown",
                explored = container:isExplored(),
                items    = items,
            }
            -- Batiment contenant ce conteneur (pour memoire batiments visites + objets)
            if sq:getRoom() and sq:getBuilding() then
                entry.building_id = sq:getBuilding():getID()
            end
            table.insert(result, entry)
        end
    end
    return result
end

-- Zone observable = ce qui est visible a l'ecran (batiments + zombies coherents)
-- Hypothese : joueur completement dezoome -> on voit beaucoup de tiles (rayon ~40)
local VISIBLE_RADIUS = 40
local BUILDING_SCAN_RADIUS = VISIBLE_RADIUS
local BUILDING_MAX_COUNT   = 25

local function scanNearbyBuildings(player, cell, playerX, playerY, playerZ)
    local seen = {}
    local list = {}
    if not cell then return list end
    for dx = -BUILDING_SCAN_RADIUS, BUILDING_SCAN_RADIUS do
        for dy = -BUILDING_SCAN_RADIUS, BUILDING_SCAN_RADIUS do
            local sq = cell:getGridSquare(playerX + dx, playerY + dy, playerZ)
            if sq and sq:getRoom() then
                local building = sq:getBuilding()
                if building then
                    local id = building:getID()
                    local sqX = math.floor(sq:getX())
                    local sqY = math.floor(sq:getY())
                    local sqZ = math.floor(sq:getZ())
                    local dist = math.floor(math.sqrt((sq:getX() - playerX)^2 + (sq:getY() - playerY)^2))
                    if not seen[id] then
                        seen[id] = true
                        local name = "Building"
                        local alarm = false
                        pcall(function()
                            local roomDef = sq:getRoom():getRoomDef()
                            if roomDef then name = tostring(roomDef:getName()) end
                            local def = building:getDef()
                            if def then alarm = def:isAlarmed() end  -- getDef():isAlarmed() — DebugChunkState_SquarePanel
                        end)
                        table.insert(list, {
                            id = id, name = name, dist = dist, alarm = alarm,
                            entry = { x = sqX, y = sqY, z = sqZ },
                        })
                    else
                        for _, b in ipairs(list) do
                            if b.id == id then
                                if dist < b.dist then
                                    b.dist = dist
                                    b.entry = { x = sqX, y = sqY, z = sqZ }
                                end
                                break
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    while #list > BUILDING_MAX_COUNT do table.remove(list) end
    return list
end

-- Rayon (tiles) autour de l'entree pour le danger "porte" (aligné bridge ZOMBIES_NEAR_BUILDING_RADIUS)
local ENTRANCE_DANGER_RADIUS = 12

-- Libelles sans accent : affichage correct en console Windows (tous terminaux)
local function entranceDangerLabel(n)
    if n == 0 then return "sur" end
    if n <= 3 then return "faible" end
    if n <= 6 then return "moyen" end
    return "eleve"
end

-- Compte les zombies a l'interieur de chaque batiment + danger a l'entree (zombies pres de entry).
-- Pour tous les batiments (visites ou non). Sources: getZombieList(), getGridSquare(), getBuilding():getID()
local function countZombiesInBuildings(cell, buildings, zlist, player, visibleRadius)
    if not cell or not zlist or not buildings or #buildings == 0 then return end
    local counts = {}
    local zombiePositions = {}
    for i = 0, zlist:size() - 1 do
        local ze = zlist:get(i)
        if player:DistTo(ze) <= visibleRadius then
            local zx, zy, zz = ze:getX(), ze:getY(), ze:getZ()
            local sq = cell:getGridSquare(zx, zy, zz)
            if sq and sq:getBuilding() then
                local bid = sq:getBuilding():getID()
                counts[bid] = (counts[bid] or 0) + 1
            end
            table.insert(zombiePositions, { x = zx, y = zy })
        end
    end
    for _, b in ipairs(buildings) do
        b.zombie_count = counts[b.id] or 0
        local entry = b.entry
        local ex, ey = entry and entry.x, entry and entry.y
        if ex and ey then
            local n = 0
            for _, zp in ipairs(zombiePositions) do
                local d = math.sqrt((zp.x - ex)^2 + (zp.y - ey)^2)
                if d <= ENTRANCE_DANGER_RADIUS then n = n + 1 end
            end
            b.entrance_zombie_count = n
            b.entrance_danger = entranceDangerLabel(n)
        else
            b.entrance_zombie_count = 0
            b.entrance_danger = "sur"
        end
    end
end

-- Remplir portes et fenetres (scope separe pour limiter les locals et eviter la limite 200 du compilateur Kahlua)
local function fillDoorsAndWindows(obs, player, cell, px, py, pz)
    obs.doors = {}
    if not cell then return end
    for dx = -8, 8 do
        for dy = -8, 8 do
            local sq = cell:getGridSquare(px + dx, py + dy, pz)
            if sq then
                pcall(function()
                    local objs = sq:getObjects()
                    for i = 0, objs:size() - 1 do
                        local obj = objs:get(i)
                        if obj then
                            local isDoor = (instanceof(obj, "IsoThumpable") and obj:isDoor()) or instanceof(obj, "IsoDoor")
                            if isDoor then
                                local sx, sy = math.floor(sq:getX()), math.floor(sq:getY())
                                local dist = math.floor(math.sqrt((sx - px)^2 + (sy - py)^2))
                                local isOpen = (obj.IsOpen and obj:IsOpen()) or false
                                local isLocked = false
                                pcall(function()
                                    if obj.isLocked and obj:isLocked() then isLocked = true; return end
                                    local kid = nil
                                    if instanceof(obj, "IsoDoor") and obj.checkKeyId then kid = obj:checkKeyId()
                                    elseif obj.getKeyId then kid = obj:getKeyId() end
                                    if kid and kid ~= -1 then
                                        local inv = player:getInventory()
                                        if inv and inv.haveThisKeyId and not inv:haveThisKeyId(kid) then isLocked = true end
                                    end
                                end)
                                table.insert(obs.doors, { x = sx, y = sy, is_open = isOpen, is_locked = isLocked, dist = dist })
                                break
                            end
                        end
                    end
                end)
            end
        end
    end
    table.sort(obs.doors, function(a, b) return (a.dist or 999) < (b.dist or 999) end)
    obs.windows = {}
    for dx = -8, 8 do
        for dy = -8, 8 do
            local sq = cell:getGridSquare(px + dx, py + dy, pz)
            if sq then
                pcall(function()
                    local objs = sq:getObjects()
                    for i = 0, objs:size() - 1 do
                        local obj = objs:get(i)
                        if obj and (instanceof(obj, "IsoWindow") or (instanceof(obj, "IsoThumpable") and obj:isWindow())) then
                            if obj.isInvincible and obj:isInvincible() then return end
                            local sx, sy = math.floor(sq:getX()), math.floor(sq:getY())
                            local dist = math.floor(math.sqrt((sx - px)^2 + (sy - py)^2))
                            local smashed = (obj.isSmashed and obj:isSmashed()) or false
                            local glassRemoved = (obj.isGlassRemoved and obj:isGlassRemoved()) or false
                            local barricade = false
                            if obj.getBarricadeForCharacter then barricade = obj:getBarricadeForCharacter(player) and true or false end
                            local canClimb = (obj.canClimbThrough and obj:canClimbThrough(player)) or false
                            table.insert(obs.windows, { x = sx, y = sy, is_smashed = smashed, is_glass_removed = glassRemoved, has_barricade = barricade, can_climb_through = canClimb, dist = dist })
                            break
                        end
                    end
                end)
            end
        end
    end
    table.sort(obs.windows, function(a, b) return (a.dist or 999) < (b.dist or 999) end)
end

local function fillEquippedAndInventory(obs, player)
    local primary = player:getPrimaryHandItem()
    if primary then
        obs.equipped.primary = { name = tostring(primary:getName()), type = tostring(primary:getType()), is_weapon = instanceof(primary, "HandWeapon") }
        local wf = getWeaponConditionFields(primary)
        if wf then obs.equipped.primary.condition = wf.condition; obs.equipped.primary.condition_max = wf.condition_max; obs.equipped.primary.is_broken = wf.is_broken end
        pcall(function() if primary.isTwoHandWeapon and primary:isTwoHandWeapon() then obs.equipped.primary.is_two_handed = true end end)
    end
    local secondary = player:getSecondaryHandItem()
    if secondary and secondary ~= primary then
        obs.equipped.secondary = { name = tostring(secondary:getName()), type = tostring(secondary:getType()), is_weapon = instanceof(secondary, "HandWeapon") }
        local wf = getWeaponConditionFields(secondary)
        if wf then obs.equipped.secondary.condition = wf.condition; obs.equipped.secondary.condition_max = wf.condition_max; obs.equipped.secondary.is_broken = wf.is_broken end
        pcall(function() if secondary.isTwoHandWeapon and secondary:isTwoHandWeapon() then obs.equipped.secondary.is_two_handed = true end end)
    end
    local inv = player:getInventory()
    local invItems = inv:getItems()
    for i = 0, math.min(invItems:size() - 1, 29) do
        local item = invItems:get(i)
        local entry = { name = tostring(item:getName()), type = tostring(item:getType()), weight = item:getActualWeight() }
        if item:IsFood() then entry.is_food = true; entry.hunger_change = item:getHungerChange() end
        if instanceof(item, "HandWeapon") then
            entry.is_weapon = true
            local wf = getWeaponConditionFields(item)
            if wf then entry.condition = wf.condition; entry.condition_max = wf.condition_max; entry.is_broken = wf.is_broken end
            pcall(function() if item.isTwoHandWeapon and item:isTwoHandWeapon() then entry.is_two_handed = true end end)
        end
        addClothingFields(item, entry)
        addDrinkAndBandageFields(item, entry)
        table.insert(obs.inventory, entry)
    end
end

local function fillWornAndWeight(obs, player)
    obs.worn_clothing = {}
    pcall(function()
        local wornItems = player:getWornItems()
        if not wornItems or not wornItems.size then return end
        for i = 1, wornItems:size() do
            local worn = wornItems:get(i - 1)
            if worn and worn.getItem then
                local it = worn:getItem()
                if it then
                    local loc = worn.getLocation and worn:getLocation()
                    local e = { name = tostring(it:getName()), type = tostring(it:getType()), body_location = loc and tostring(loc) or nil }
                    if it.getBiteDefense then e.bite_defense = it:getBiteDefense() end
                    if it.getScratchDefense then e.scratch_defense = it:getScratchDefense() end
                    table.insert(obs.worn_clothing, e)
                end
            end
        end
    end)
    pcall(function()
        local inv = player:getInventory()
        obs.inventory_weight = (inv.getCapacityWeight and inv:getCapacityWeight()) or 0
        obs.max_weight = (inv.getEffectiveCapacity and inv:getEffectiveCapacity(player)) or (player.getMaxWeight and player:getMaxWeight()) or 0
        if obs.max_weight == 0 and player.getMaxWeight then obs.max_weight = player:getMaxWeight() end
    end)
end

local function fillZombiesList(obs, player, cell)
    if not cell then return end
    local zlist = cell:getZombieList()
    local inRadius = {}
    for i = 0, zlist:size() - 1 do
        local ze = zlist:get(i)
        local d = player:DistTo(ze)
        if d <= VISIBLE_RADIUS then table.insert(inRadius, { ze = ze, dist = d }) end
    end
    table.sort(inRadius, function(a, b) return a.dist < b.dist end)
    for _, e in ipairs(inRadius) do
        if #obs.zombies >= 60 then break end
        local ze = e.ze
        table.insert(obs.zombies, { x = math.floor(ze:getX()), y = math.floor(ze:getY()), dist = math.floor(e.dist) })
    end
end

local function fillContainersBuildingsIndoors(obs, player, cell, px, py, pz)
    if player:getCurrentSquare() and cell then
        for dx = -5, 5 do
            for dy = -5, 5 do
                local sq = cell:getGridSquare(px + dx, py + dy, pz)
                if sq then
                    local found = scanSquareContainers(sq, px, py)
                    for _, c in ipairs(found) do table.insert(obs.containers, c) end
                end
            end
        end
    end
    obs.buildings = scanNearbyBuildings(player, cell, px, py, pz)
    if cell then
        local zlist = cell:getZombieList()
        countZombiesInBuildings(cell, obs.buildings, zlist, player, VISIBLE_RADIUS)
    end
    local sq = cell and cell:getGridSquare(px, py, pz) or nil
    if sq then
        obs.is_indoors = sq:getRoom() ~= nil
        if sq:getRoom() then
            local b = sq:getBuilding()
            if b then
                obs.building_id = b:getID()
                obs.building_name = "Building"
                pcall(function() local rd = sq:getRoom():getRoomDef(); if rd then obs.building_name = tostring(rd:getName()) end end)
            end
        end
    end
    local gt = getGameTime()
    obs.game_hour = gt:getTimeOfDay()
    obs.game_day = gt:getDay()
end

-- Duree (en ticks jeu) pendant laquelle on considere encore le perso "busy" apres avoir lance move_to ou take_item (evite envoi trop rapide quand TICK_RATE reduit)
local MOVE_BUSY_EXTRA_TICKS  = 35
local TAKE_BUSY_EXTRA_TICKS  = 25
-- Si en WalkTo depuis ce nombre de ticks sans bouger (ou < 2 cases), on met pathfinding_stuck dans l'obs (~5 s a 30 Hz)
local WALK_STUCK_TICKS = 150
LLMBotGlobalTick = LLMBotGlobalTick or 0
LLMBotLastMoveToTick = LLMBotLastMoveToTick or 0
LLMBotLastTakeItemTick = LLMBotLastTakeItemTick or 0

local function fillActionQueueAndBusy(obs, player)
    obs.current_action = nil
    obs.action_queue = 0
    if not ISTimedActionQueue.queues or not ISTimedActionQueue.queues[player] then return end
    local q = ISTimedActionQueue.queues[player]
    if q.queue then obs.action_queue = #q.queue end
    if obs.action_queue > 0 and q.queue and q.queue[1] then
        local cur = q.queue[1]
        local typ = (cur.Type and tostring(cur.Type)) or "Action"
        if typ:find("WalkTo") or typ:find("PathFind") then obs.current_action = "walking"
        elseif typ:find("OpenContainer") or typ:find("Container") then obs.current_action = "opening_container"
        elseif typ:find("GrabItem") or typ:find("Grab") then obs.current_action = "grabbing_item"
        elseif typ:find("Eat") then obs.current_action = "eating"
        elseif typ:find("Drink") then obs.current_action = "drinking"
        elseif typ:find("Bandage") then obs.current_action = "applying_bandage"
        elseif typ:find("Equip") or typ:find("Wear") then obs.current_action = "equipping"
        elseif typ:find("Attack") then obs.current_action = "attacking"
        elseif typ:find("Smash") then obs.current_action = "smashing_window"
        elseif typ:find("RemoveBrokenGlass") or typ:find("Glass") then obs.current_action = "removing_glass"
        elseif typ:find("ClimbThrough") or typ:find("Climb") then obs.current_action = "climbing_through_window"
        elseif typ:find("Transfer") or typ:find("Inventory") then obs.current_action = "transferring_items"
        else obs.current_action = typ end
    end
    obs.is_busy = obs.action_queue > 0
    if not obs.is_busy and ISTimedActionQueue.isPlayerDoingAction and ISTimedActionQueue.isPlayerDoingAction(player) then
        obs.is_busy = true
        obs.current_action = obs.current_action or "other_activity"
    end
    -- Allonger la duree "busy" apres un move_to ou take_item (tick plus court => eviter commande trop tot)
    if not obs.is_busy and LLMBotGlobalTick > 0 then
        if LLMBotLastMoveToTick > 0 and (LLMBotGlobalTick - LLMBotLastMoveToTick) < MOVE_BUSY_EXTRA_TICKS then
            obs.is_busy = true
            obs.current_action = obs.current_action or "walking"
        end
        if LLMBotLastTakeItemTick > 0 and (LLMBotGlobalTick - LLMBotLastTakeItemTick) < TAKE_BUSY_EXTRA_TICKS then
            obs.is_busy = true
            obs.current_action = obs.current_action or "transferring_items"
        end
    end
end

-- Detecte si le pathfinding est bloque (on est en train de marcher vers target mais une porte verrouillee est sur le trajet).
-- Retourne nil ou { door = {x,y}, target = {x,y}, windows = [{x,y}, ...] } pour que le bridge interrompe et demande au LLM de choisir une fenetre.
local function getPathfindingBlockedInfo(player, cell, tx, ty, tz)
    if not cell or not tx or not ty then return nil end
    local px, py = math.floor(player:getX()), math.floor(player:getY())
    local pz = math.floor(player:getZ() or 0)
    local margin, winMargin = 12, 20
    local x0 = math.min(px, tx) - margin
    local x1, y0, y1 = math.max(px, tx) + margin, math.min(py, ty) - margin, math.max(py, ty) + margin
    local lockedDoors = {}
    local windows = {}
    for gx = x0, x1 do
        for gy = y0, y1 do
            local sq = cell:getGridSquare(gx, gy, pz)
            if sq then
                pcall(function()
                    local objs = sq:getObjects()
                    for i = 0, objs:size() - 1 do
                        local obj = objs:get(i)
                        if obj then
                            local isDoor = (instanceof(obj, "IsoThumpable") and obj:isDoor()) or instanceof(obj, "IsoDoor")
                            if isDoor then
                                local sx, sy = math.floor(sq:getX()), math.floor(sq:getY())
                                local isLocked = false
                                pcall(function()
                                    if obj.isLocked and obj:isLocked() then isLocked = true; return end
                                    local kid = (instanceof(obj, "IsoDoor") and obj.checkKeyId and obj:checkKeyId()) or (obj.getKeyId and obj:getKeyId()) or nil
                                    if kid and kid ~= -1 then
                                        local inv = player:getInventory()
                                        if inv and inv.haveThisKeyId and not inv:haveThisKeyId(kid) then isLocked = true end
                                    end
                                end)
                                if isLocked then table.insert(lockedDoors, { x = sx, y = sy }) end
                                break
                            end
                        end
                    end
                end)
            end
        end
    end
    local wx0, wx1 = math.min(px, tx) - winMargin, math.max(px, tx) + winMargin
    local wy0, wy1 = math.min(py, ty) - winMargin, math.max(py, ty) + winMargin
    for gx = wx0, wx1 do
        for gy = wy0, wy1 do
            local sq = cell:getGridSquare(gx, gy, pz)
            if sq then
                pcall(function()
                    local objs = sq:getObjects()
                    for i = 0, objs:size() - 1 do
                        local obj = objs:get(i)
                        if obj and (instanceof(obj, "IsoWindow") or (instanceof(obj, "IsoThumpable") and obj:isWindow())) then
                            if obj.isInvincible and obj:isInvincible() then return end
                            local barricade = false
                            if obj.getBarricadeForCharacter then barricade = obj:getBarricadeForCharacter(player) and true or false end
                            if not barricade then
                                local sx, sy = math.floor(sq:getX()), math.floor(sq:getY())
                                local dist = math.abs(sx - px) + math.abs(sy - py)
                                table.insert(windows, { x = sx, y = sy, dist = dist })
                            end
                            break
                        end
                    end
                end)
            end
        end
    end
    for _, door in ipairs(lockedDoors) do
        local dx, dy = door.x, door.y
        local playerNearDoor = (math.abs(px - dx) + math.abs(py - dy)) <= 1
        local targetOnOrAdjDoor = (math.abs(tx - dx) + math.abs(ty - dy)) <= 1
        local targetNotPlayer = (tx ~= px or ty ~= py)
        local doorInBbox = (dx >= math.min(px, tx) and dx <= math.max(px, tx) and dy >= math.min(py, ty) and dy <= math.max(py, ty))
            and (dx ~= px or dy ~= py) and (dx ~= tx or dy ~= ty)
        if (playerNearDoor and targetOnOrAdjDoor and targetNotPlayer) or doorInBbox then
            table.sort(windows, function(a, b) return (a.dist or 999) < (b.dist or 999) end)
            local winList = {}
            for _, w in ipairs(windows) do
                if w.x and w.y then table.insert(winList, { x = w.x, y = w.y }) end
            end
            return { door = { x = dx, y = dy }, target = { x = tx, y = ty }, windows = winList }
        end
    end
    return nil
end

-- Retourne true si le conteneur en (tx,ty,tz) contient encore un item dont le type ou le nom matche itemSpecStr (exact ou suffixe).
-- Defini avant buildObservation pour etre en scope lors de l'appel (pending take / bugged action).
local function containerStillHasItemMatching(tx, ty, tz, itemSpecStr)
    local cell = getCell()
    if not cell then return false end
    local sq = cell:getGridSquare(tx, ty, tz)
    if not sq then return false end
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        local container = obj and obj:getContainer()
        if container then
            local cItems = container:getItems()
            for j = 0, cItems:size() - 1 do
                local item = cItems:get(j)
                local itype, iname = tostring(item:getType()), tostring(item:getName())
                local exactMatch = (itype == itemSpecStr or iname == itemSpecStr)
                local suffixMatch = (itype:find(itemSpecStr, 1, true) or itemSpecStr:find(itype, 1, true) or iname:find(itemSpecStr, 1, true) or itemSpecStr:find(iname, 1, true))
                if exactMatch or suffixMatch then return true end
            end
            return false
        end
    end
    return false
end

-- ---------------------------------------------------------------
-- 3. OBSERVATION
-- ---------------------------------------------------------------
local function buildObservation(player)
    local obs = {
        position         = {},
        stats            = {},
        inventory        = {},
        zombies          = {},
        containers       = {},
        buildings        = {},
        equipped         = {},
        world_items      = {},
        worn_clothing    = {},
        body_damage      = { is_bleeding = false, needs_bandage = false },
        inventory_weight = 0,
        max_weight       = 0,
        action_queue     = 0,
        is_busy          = false,
    }

    -- Position
    local px = math.floor(player:getX())
    local py = math.floor(player:getY())
    local pz = math.floor(player:getZ())
    obs.position = {x = px, y = py, z = pz}

    -- Stats
    local stats = player:getStats()
    obs.stats = {
        hunger    = stats:get(CharacterStat.HUNGER),
        thirst    = stats:get(CharacterStat.THIRST),
        fatigue   = stats:get(CharacterStat.FATIGUE),
        endurance = stats:get(CharacterStat.ENDURANCE),
        stress    = stats:get(CharacterStat.STRESS),
        morale    = stats:get(CharacterStat.MORALE),
        panic     = stats:get(CharacterStat.PANIC),
        sanity    = stats:get(CharacterStat.SANITY),
        health    = player:getBodyDamage():getHealth(),
        infected  = player:getBodyDamage():IsInfected(),
    }

    fillEquippedAndInventory(obs, player)
    obs.body_damage = getBodyDamageSummary(player)
    local cell = getCell()
    fillWornAndWeight(obs, player)
    obs.world_items = scanWorldItemsNearPlayer(cell, px, py, pz)
    fillZombiesList(obs, player, cell)
    fillDoorsAndWindows(obs, player, cell, px, py, pz)
    fillContainersBuildingsIndoors(obs, player, cell, px, py, pz)
    fillActionQueueAndBusy(obs, player)

    -- Sequence fenetre auto : surveiller l'arrivee pour enfiler smash+remove_glass+climb
    if LLMBotWindowSequenceActive and LLMBotWindowSequenceTarget then
        local t = LLMBotWindowSequenceTarget
        local distW = math.abs(px - t.wx) + math.abs(py - t.wy)
        if distW <= 2 and not obs.is_busy then
            -- Joueur arrive : enfiler la sequence de cassage/enjambement
            local wObj = t.winObj
            -- Rafraichir l'etat de la fenetre (peut avoir change)
            local wSq = t.winSq
            local freshWinObj = nil
            if wSq then
                local objs2 = wSq:getObjects()
                for i = 0, objs2:size() - 1 do
                    local o = objs2:get(i)
                    if o and (instanceof(o, "IsoWindow") or (instanceof(o, "IsoThumpable") and o:isWindow()) or instanceof(o, "IsoWindowFrame")) then
                        freshWinObj = o
                        break
                    end
                end
            end
            wObj = freshWinObj or wObj
            if wObj then
                if not (wObj.isSmashed and wObj:isSmashed()) then
                    if ISSmashWindow then ISTimedActionQueue.add(ISSmashWindow:new(player, wObj, nil)) end
                end
                if not (wObj.isGlassRemoved and wObj:isGlassRemoved()) then
                    if ISRemoveBrokenGlass then ISTimedActionQueue.add(ISRemoveBrokenGlass:new(player, wObj)) end
                end
                if ISClimbThroughWindow then
                    if luautils and luautils.walkAdjWindowOrDoor then
                        luautils.walkAdjWindowOrDoor(player, wSq, wObj)
                    end
                    ISTimedActionQueue.add(ISClimbThroughWindow:new(player, wObj, 0))
                end
                print("[LLMBot] sequence fenetre: smash+remove_glass+climb enfiles a l'arrivee (" .. t.wx .. "," .. t.wy .. ")")
            else
                print("[LLMBot] sequence fenetre: fenetre introuvable a l'arrivee, abandon")
                LLMBotWindowSequenceActive = false
            end
            LLMBotWindowSequenceTarget = nil
        elseif not obs.is_busy and distW > 2 then
            -- Plus en marche, loin de la fenetre : abandonner seulement si le WalkTo est vraiment termine
            -- (LLMBotLastMoveToTick assez ancien pour exclure le demarrage immediat)
            local ticksSinceMove = LLMBotGlobalTick - (LLMBotLastMoveToTick or 0)
            if ticksSinceMove > 10 then
                local fkey = t.wx .. "," .. t.wy
                LLMBotFailedWindowKeys[fkey] = (LLMBotFailedWindowKeys[fkey] or 0) + 1
                print("[LLMBot] sequence fenetre abandonnee (not busy, dist=" .. distW .. ", ticks=" .. ticksSinceMove .. ") — fenetre " .. fkey .. " blacklistee")
                LLMBotWindowSequenceActive = false
                LLMBotWindowSequenceTarget = nil
            end
        end
    elseif LLMBotWindowSequenceActive then
        -- WalkTo termine (LLMBotWindowSequenceTarget nil mais flag actif) : sequence smash/climb en cours
        if not obs.is_busy then
            LLMBotWindowSequenceActive = false
            print("[LLMBot] sequence fenetre terminee")
        else
            obs.window_sequence_active = true
        end
    end
    if LLMBotWindowSequenceActive then
        obs.window_sequence_active = true
    end

    -- Si on est en train de marcher vers une cible et qu'une porte verrouillee bloque : interrompre et signaler au bridge pour que le LLM choisisse une fenetre
    if obs.current_action == "walking" and LLMBotLastMoveToTarget and LLMBotLastMoveToTarget.x and LLMBotLastMoveToTarget.y then
        local blocked = getPathfindingBlockedInfo(player, cell, LLMBotLastMoveToTarget.x, LLMBotLastMoveToTarget.y, pz)
        if blocked and blocked.windows and #blocked.windows > 0 then
            obs.pathfinding_blocked_by_locked_door = blocked
            obs.last_open_door_result = { ok = false, reason = "locked", x = blocked.door.x, y = blocked.door.y }
            ISTimedActionQueue.clear(player)
            LLMBotLastMoveToTarget = nil
            obs.is_busy = false
            obs.current_action = nil
            obs.action_queue = 0
        end
    elseif obs.current_action ~= "walking" then
        LLMBotLastMoveToTarget = nil
    end
    -- Cible de marche en cours (pour que le bridge considere "arrive" meme apres redirection fenetre)
    if obs.current_action == "walking" and LLMBotLastMoveToTarget and LLMBotLastMoveToTarget.x and LLMBotLastMoveToTarget.y then
        obs.current_walk_target = { x = LLMBotLastMoveToTarget.x, y = LLMBotLastMoveToTarget.y }
    end

    -- Detection "pathfinding_stuck" : en WalkTo depuis longtemps sans (ou avec tres peu de) mouvement -> bridge redemande au LLM
    if obs.current_action == "walking" then
        if not LLMBotWalkToStartTick or LLMBotWalkToStartTick == 0 then
            LLMBotWalkToStartTick = LLMBotGlobalTick
            LLMBotWalkToStartX = px
            LLMBotWalkToStartY = py
        elseif (LLMBotGlobalTick - LLMBotWalkToStartTick) >= WALK_STUCK_TICKS then
            local distMoved = math.abs(px - LLMBotWalkToStartX) + math.abs(py - LLMBotWalkToStartY)
            if distMoved < 2 then
                obs.pathfinding_stuck = true
            end
        end
    else
        LLMBotWalkToStartTick = 0
    end

    -- Si on a lance un transfert au tick precedent et qu'on n'est plus busy : le jeu l'a soit termine soit annule (bugged action). Verifier si l'item est encore dans le conteneur.
    if not obs.is_busy and LLMBotPendingTakeContainer and LLMBotPendingTakeItemSpec then
        local c = LLMBotPendingTakeContainer
        local tz = c.z or 0
        local stillHas = containerStillHasItemMatching(c.x, c.y, tz, LLMBotPendingTakeItemSpec)
        LLMBotLastTakeResult = {
            ok = not stillHas,
            x = c.x, y = c.y, z = tz,
            item_type = LLMBotPendingTakeItemSpec,
            reason = stillHas and "cancelled_or_bugged" or nil
        }
        if stillHas then
            print("[LLMBot] take_item_from_container: action annulee par le jeu (bugged), item encore dans conteneur -> ok=false")
        end
        LLMBotPendingTakeContainer = nil
        LLMBotPendingTakeItemSpec = nil
    end
    -- Resultat du dernier take_item_from_container (pour que le bridge sache si ca a reussi ou non)
    obs.last_take_item_result = LLMBotLastTakeResult
    LLMBotLastTakeResult = nil
    -- Resultat du dernier open_door (porte verrouillee -> bridge peut suggerer fenetre ou abandon)
    obs.last_open_door_result = LLMBotLastOpenDoorResult
    LLMBotLastOpenDoorResult = nil
    -- Cases non walkable connues : ne pas demander move_to vers ces (x,y). Limite 50, priorite aux plus proches du joueur.
    obs.non_walkable_positions = {}
    local px_obs, py_obs = obs.position and obs.position.x or 0, obs.position and obs.position.y or 0
    local nwList, nwMax = {}, 50
    for key, _ in pairs(LLMBotNonWalkableTiles) do
        local x, y, z = key:match("^(%d+),(%d+),(%d+)$")
        if x and y then
            x, y = tonumber(x), tonumber(y)
            local dist = math.abs(x - px_obs) + math.abs(y - py_obs)
            table.insert(nwList, { x = x, y = y, dist = dist })
        end
    end
    table.sort(nwList, function(a, b) return (a.dist or 999) < (b.dist or 999) end)
    for i = 1, math.min(nwMax, #nwList) do
        table.insert(obs.non_walkable_positions, { x = nwList[i].x, y = nwList[i].y })
    end
    if #obs.non_walkable_positions == 0 then obs.non_walkable_positions = nil end

    return obs
end

-- ---------------------------------------------------------------
-- 4. ACTIONS (handlers extraits pour eviter la limite 200 locals Kahlua)
-- ---------------------------------------------------------------
-- Si la cible (tx,ty) est de l'autre cote d'une porte verrouillee par rapport au joueur, retourne les coords d'une fenetre pour rediriger le pathfinding ; sinon nil.
-- Zone de scan : bbox joueur<->cible + marge 12 ; fenetres : marge 20 pour trouver une fenetre du batiment.
local function getRedirectToWindowIfLockedDoorInWay(player, cell, tx, ty, tz)
    if not cell then return nil end
    local px, py = math.floor(player:getX()), math.floor(player:getY())
    local pz = math.floor(player:getZ() or 0)
    local margin = 12
    local x0 = math.min(px, tx) - margin
    local x1 = math.max(px, tx) + margin
    local y0 = math.min(py, ty) - margin
    local y1 = math.max(py, ty) + margin
    local lockedDoors = {}
    local windows = {}
    for gx = x0, x1 do
        for gy = y0, y1 do
            local sq = cell:getGridSquare(gx, gy, pz)
            if sq then
                pcall(function()
                    local objs = sq:getObjects()
                    for i = 0, objs:size() - 1 do
                        local obj = objs:get(i)
                        if obj then
                            local isDoor = (instanceof(obj, "IsoThumpable") and obj:isDoor()) or instanceof(obj, "IsoDoor")
                            if isDoor then
                                local sx, sy = math.floor(sq:getX()), math.floor(sq:getY())
                                local isLocked = false
                                pcall(function()
                                    if obj.isLocked and obj:isLocked() then isLocked = true; return end
                                    local kid = (instanceof(obj, "IsoDoor") and obj.checkKeyId and obj:checkKeyId()) or (obj.getKeyId and obj:getKeyId()) or nil
                                    if kid and kid ~= -1 then
                                        local inv = player:getInventory()
                                        if inv and inv.haveThisKeyId and not inv:haveThisKeyId(kid) then isLocked = true end
                                    end
                                end)
                                if isLocked then table.insert(lockedDoors, { x = sx, y = sy }) end
                                break
                            end
                        end
                    end
                end)
            end
        end
    end
    local winMargin = 20
    local wx0, wx1 = math.min(px, tx) - winMargin, math.max(px, tx) + winMargin
    local wy0, wy1 = math.min(py, ty) - winMargin, math.max(py, ty) + winMargin
    for gx = wx0, wx1 do
        for gy = wy0, wy1 do
            local sq = cell:getGridSquare(gx, gy, pz)
            if sq then
                pcall(function()
                    local objs = sq:getObjects()
                    for i = 0, objs:size() - 1 do
                        local obj = objs:get(i)
                        if obj and (instanceof(obj, "IsoWindow") or (instanceof(obj, "IsoThumpable") and obj:isWindow())) then
                            if obj.isInvincible and obj:isInvincible() then return end
                            local barricade = false
                            if obj.getBarricadeForCharacter then barricade = obj:getBarricadeForCharacter(player) and true or false end
                            if not barricade then
                                local sx, sy = math.floor(sq:getX()), math.floor(sq:getY())
                                local dist = math.abs(sx - px) + math.abs(sy - py)
                                table.insert(windows, { x = sx, y = sy, dist = dist })
                            end
                            break
                        end
                    end
                end)
            end
        end
    end
    for _, door in ipairs(lockedDoors) do
        local dx, dy = door.x, door.y
        local playerNearDoor = (math.abs(px - dx) + math.abs(py - dy)) <= 1
        local targetOnOrAdjDoor = (math.abs(tx - dx) + math.abs(ty - dy)) <= 1
        local targetNotPlayer = (tx ~= px or ty ~= py)
        local doorInBbox = (dx >= math.min(px, tx) and dx <= math.max(px, tx) and dy >= math.min(py, ty) and dy <= math.max(py, ty))
            and (dx ~= px or dy ~= py) and (dx ~= tx or dy ~= ty)
        if (playerNearDoor and targetOnOrAdjDoor and targetNotPlayer) or doorInBbox then
            table.sort(windows, function(a, b) return (a.dist or 999) < (b.dist or 999) end)
            -- Exclure les fenetres en echec (inatteignables)
            for _, w in ipairs(windows) do
                if w.x and w.y then
                    local wkey = w.x .. "," .. w.y
                    if not (LLMBotFailedWindowKeys and LLMBotFailedWindowKeys[wkey] and LLMBotFailedWindowKeys[wkey] >= 2) then
                        return w.x, w.y
                    end
                end
            end
            -- Toutes les fenetres en echec : retourner nil (le bridge signalera pathfinding bloque)
            print("[LLMBot] getRedirectToWindow: toutes les fenetres sont en echec, abandon redirection")
            return nil
        end
    end
    return nil
end

-- Retourne true si la case est praticable (isFree et non solidtrans). Voir docs/API_tuiles_walkable.md
-- Si l'API (isFree/isSolidTrans) est absente ou erre, on considere walkable=true pour ne pas bloquer tous les deplacements.
local function isSquareWalkable(sq)
    if not sq then return false end
    local ok, walkable = pcall(function()
        if sq.isFree and not sq:isFree(false) then return false end
        if sq.isSolidTrans and sq:isSolidTrans() then return false end
        return true
    end)
    if not ok then return true end
    return walkable == true
end

-- Retourne true si la case est interieure (non exterior). Les tiles ont un flag "exterior" (IsoFlagType).
-- On utilise sq:getHasTypes():isSet(IsoFlagType.exterior) : si le flag est pose, la tile est exterior ; sinon interieur.
-- Fallback : getRoom() ~= nil ou isExteriorCache == false. Si l'API manque, on considere interior=true (ne pas filtrer).
local function isSquareInterior(sq)
    if not sq then return true end
    local ok, interior = pcall(function()
        -- Priorite : flag "exterior" sur les tiles (IsoFlagType)
        if sq.getHasTypes then
            local hasTypes = sq:getHasTypes()
            if hasTypes and hasTypes.isSet and IsoFlagType and IsoFlagType.exterior then
                if hasTypes:isSet(IsoFlagType.exterior) then return false end
                return true
            end
        end
        if sq.getRoom and sq:getRoom() then return true end
        if sq.isExteriorCache == false then return true end
        return false
    end)
    if not ok then return true end
    return interior == true
end

-- Trouve la case walkable la plus proche de (cx, cy, cz) en explorant en spirale (rayon max maxRadius). Retourne IsoGridSquare ou nil.
-- Si mustBeInterior=true, ne retourne que des cases interieures (non exterior).
local function findNearestWalkableSquare(cell, cx, cy, cz, maxRadius, mustBeInterior)
    if not cell then return nil end
    maxRadius = math.min(maxRadius or 20, 25)
    for r = 0, maxRadius do
        for dx = -r, r do
            for dy = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local sq = cell:getGridSquare(cx + dx, cy + dy, cz)
                    if sq and isSquareWalkable(sq) then
                        if mustBeInterior and not isSquareInterior(sq) then
                            -- skip
                        else
                            return sq
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- Enregistre (x,y,z) comme non walkable ; limite la taille du cache.
local function recordNonWalkableTile(x, y, z)
    local key = x .. "," .. y .. "," .. (z or 0)
    LLMBotNonWalkableTiles[key] = true
    local n, keys = 0, {}
    for k, _ in pairs(LLMBotNonWalkableTiles) do keys[#keys + 1] = k end
    if #keys > LLMBOT_NON_WALKABLE_MAX then
        table.sort(keys)
        for i = 1, #keys - LLMBOT_NON_WALKABLE_MAX do LLMBotNonWalkableTiles[keys[i]] = nil end
    end
end

-- Déplacement fiable : une seule marche vers la cible (ou case adjacente atteignable). Redirige vers une fenetre si la cible est derriere une porte verrouillee.
-- Si la cible demandee n'est pas walkable, on cherche la case walkable la plus proche et on enregistre la cible comme non walkable pour le LLM.
-- Si une WalkTo/PathFind est déjà en cours, on l'interrompt et on lance le nouveau move_to (comme les autres actions interrompibles).
local function executeMoveTo(player, cmd)
    local tx, ty = tonumber(cmd.x), tonumber(cmd.y)
    if not tx or not ty then print("[LLMBot] move_to: x ou y manquant") return end
    tx, ty = math.floor(tx), math.floor(ty)
    local tz = math.floor(tonumber(cmd.z) or player:getZ())
    if player.getVehicle and player:getVehicle() then print("[LLMBot] move_to: en vehicule, ignore") return end
    local px, py = math.floor(player:getX()), math.floor(player:getY())
    local pz = math.floor(player:getZ() or 0)
    local dist = math.abs(tx - px) + math.abs(ty - py)
    if dist == 0 then return end
    local cell = getCell() or (player.getCell and player:getCell())
    if not cell then print("[LLMBot] move_to: getCell indisponible") return end
    -- Si la cible est de l'autre cote d'une porte verrouillee, le bridge le detectera via
    -- getPathfindingBlockedInfo dans buildObservation (pendant la marche) et instruira le LLM.
    -- On ne fait pas de detection preventive ici : trop de faux positifs (portes ouvertes, bbox trop large).
    local targetKey = tx .. "," .. ty
    if LLMBotLastMoveToOriginalTarget ~= targetKey then
        LLMBotLastMoveToOriginalTarget = targetKey
        LLMBotFailedWindowKeys = {}
    end
    -- Cible reelle (apres redirection eventuelle) pour que le bridge sache quand considerer "arrive"
    LLMBotLastMoveToTarget = { x = tx, y = ty }
    local targetSquare = cell:getGridSquare(tx, ty, tz)
    if not targetSquare and dist > 1 then
        local step = math.min(12, dist)
        local wx = px + math.floor((tx - px) * step / dist)
        local wy = py + math.floor((ty - py) * step / dist)
        targetSquare = cell:getGridSquare(wx, wy, pz)
    end
    if not targetSquare then
        local dx = (tx > px and 1) or (tx < px and -1) or 0
        local dy = (ty > py and 1) or (ty < py and -1) or 0
        targetSquare = cell:getGridSquare(px + dx, py + dy, pz)
            or cell:getGridSquare(px + 1, py, pz) or cell:getGridSquare(px - 1, py, pz)
            or cell:getGridSquare(px, py + 1, pz) or cell:getGridSquare(px, py - 1, pz)
    end
    if not targetSquare then
        print("[LLMBot] move_to: aucune case valide vers " .. tx .. "," .. ty .. " (pos " .. px .. "," .. py .. ")")
        return
    end
    -- Cible interieure (non exterior) : on doit amener le joueur sur une case exacte ou adjacente qui est aussi interieure.
    local reqSq = cell:getGridSquare(tx, ty, tz)
    local isTargetInterior = reqSq and isSquareInterior(reqSq)
    -- Verification walkable UNIQUEMENT sur la case reellement demandee (tx,ty). Pas sur une case de fallback (intermediaire/adjacente).
    local targetIsRequestedTile = (targetSquare:getX() == tx and targetSquare:getY() == ty)
    if targetIsRequestedTile and not isSquareWalkable(targetSquare) then
        recordNonWalkableTile(tx, ty, tz)
        print("[LLMBot] move_to: case " .. tx .. "," .. ty .. " non walkable, recherche case walkable la plus proche...")
        local nearest = findNearestWalkableSquare(cell, tx, ty, tz, 20, isTargetInterior)
        if not nearest then
            print("[LLMBot] move_to: aucune case walkable trouvee autour de " .. tx .. "," .. ty .. (isTargetInterior and " (interieur requis)" or ""))
            return
        end
        targetSquare = nearest
        print("[LLMBot] move_to: redirection vers " .. targetSquare:getX() .. "," .. targetSquare:getY() .. " (walkable)")
    end
    -- Ne considérer "déjà arrivé" que si on est sur la cible FINALE (tx,ty), pas sur un waypoint
    local sqx, sqy = targetSquare:getX(), targetSquare:getY()
    local diffX = math.abs(sqx + 0.5 - player:getX())
    local diffY = math.abs(sqy + 0.5 - player:getY())
    if sqx == tx and sqy == ty and diffX <= 0.5 and diffY <= 0.5 then return end
    -- Préférer une case adjacente atteignable (comme luautils.walkAdj) pour éviter échec pathfinding.
    -- Si la cible est interieure, l'adjacente doit aussi etre interieure (sinon on garde targetSquare).
    local walkSquare = targetSquare
    if AdjacentFreeTileFinder and AdjacentFreeTileFinder.Find then
        local adjacent = AdjacentFreeTileFinder.Find(targetSquare, player)
        if adjacent and (adjacent:getX() ~= px or adjacent:getY() ~= py) then
            if not isTargetInterior or isSquareInterior(adjacent) then
                walkSquare = adjacent
            end
        end
    end
    -- Verifier que walkSquare est effectivement walkable (AdjacentFreeTileFinder peut retourner une case bloquee).
    -- Si non-walkable, chercher la case walkable la plus proche autour de targetSquare.
    if not isSquareWalkable(walkSquare) then
        recordNonWalkableTile(walkSquare:getX(), walkSquare:getY(), walkSquare:getZ())
        print("[LLMBot] move_to: walkSquare " .. walkSquare:getX() .. "," .. walkSquare:getY() .. " non walkable, recherche alternative...")
        local alt = findNearestWalkableSquare(cell, targetSquare:getX(), targetSquare:getY(), tz, 10, isTargetInterior)
        if alt and (alt:getX() ~= px or alt:getY() ~= py) then
            walkSquare = alt
            print("[LLMBot] move_to: walkSquare redirige vers " .. walkSquare:getX() .. "," .. walkSquare:getY())
        else
            print("[LLMBot] move_to: aucune walkSquare alternative trouvee pour " .. tx .. "," .. ty)
            return
        end
    end
    -- Si on est déjà en WalkTo vers la même case, ne pas interrompre (évite la boucle quand le bridge renvoie le même move_to en retry)
    local q = ISTimedActionQueue.queues and ISTimedActionQueue.queues[player]
    if q and q.queue and q.queue[1] then
        local cur = q.queue[1]
        local typ = (cur.Type and tostring(cur.Type)) or ""
        if typ:find("WalkTo") and cur.location then
            local lx, ly = cur.location:getX(), cur.location:getY()
            if lx == walkSquare:getX() and ly == walkSquare:getY() then
                LLMBotSameWalkToRepeatCount = (LLMBotSameWalkToRepeatCount or 0) + 1
                if LLMBotSameWalkToRepeatCount >= SAME_WALKTO_MAX_REPEAT then
                    -- Trop de repetitions sans progresser : enregistrer la cible comme non-walkable et laisser le LLM décider
                    recordNonWalkableTile(tx, ty, tz)
                    LLMBotSameWalkToRepeatCount = 0
                    ISTimedActionQueue.clear(player)
                    LLMBotLastMoveToTick = 0
                    print("[LLMBot] move_to: meme walkSquare repete " .. SAME_WALKTO_MAX_REPEAT .. "x → abandon, non-walkable enregistre pour " .. tx .. "," .. ty)
                    return
                end
                -- Prolonger is_busy pour eviter que le bridge ne renvoie une commande pendant qu'on marche encore
                LLMBotLastMoveToTick = LLMBotGlobalTick
                print("[LLMBot] move_to: deja en marche vers " .. lx .. "," .. ly .. " — LLMBotLastMoveToTick prolonge")
                return
            end
        end
    end
    LLMBotSameWalkToRepeatCount = 0
    LLMBotLastMoveToTick = LLMBotGlobalTick
    pcall(function() if player.setSprinting then player:setSprinting(true) elseif player.setRunning and player:canSprint() then player:setRunning(true) end end)
    ISTimedActionQueue.add(LLMBotWalkToTimedAction:new(player, walkSquare))
    -- Mettre a jour LLMBotLastMoveToTarget avec la case reelle (walkSquare), pas la cible redirectee,
    -- pour que current_walk_target dans l'obs corresponde exactement a ou le joueur marche.
    LLMBotLastMoveToTarget = { x = walkSquare:getX(), y = walkSquare:getY() }
    print("[LLMBot] move_to vers " .. walkSquare:getX() .. "," .. walkSquare:getY() .. " (cible " .. tx .. "," .. ty .. ") ok")
end

local function executeOpenDoor(player, cmd)
    local tx = math.floor(tonumber(cmd.x) or 0)
    local ty = math.floor(tonumber(cmd.y) or 0)
    local tz = math.floor(tonumber(cmd.z) or player:getZ())
    local cell = getCell() or (player.getCell and player:getCell())
    if not cell or not tx or not ty then print("[LLMBot] open_door: x,y manquants ou cell indisponible") return end
    local function findDoorAt(sqx, sqy, sqz)
        local sq = cell:getGridSquare(sqx, sqy, sqz)
        if not sq then return nil end
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local obj = objs:get(i)
            if obj and ((instanceof(obj, "IsoThumpable") and obj:isDoor()) or instanceof(obj, "IsoDoor")) then return obj end
        end
        return nil
    end
    local door = findDoorAt(tx, ty, tz)
    if not door then
        for _, d in ipairs({{0,1},{0,-1},{1,0},{-1,0}}) do
            door = findDoorAt(tx + d[1], ty + d[2], tz)
            if door then break end
        end
    end
    if not door then print("[LLMBot] open_door: aucune porte trouvee en (" .. tx .. "," .. ty .. ")") return end
    local doorLocked = false
    pcall(function()
        if door.isLocked and door:isLocked() then doorLocked = true return end
        local kid = (instanceof(door, "IsoDoor") and door.checkKeyId and door:checkKeyId()) or (door.getKeyId and door:getKeyId()) or nil
        if kid and kid ~= -1 then
            local inv = player:getInventory()
            if inv and inv.haveThisKeyId and not inv:haveThisKeyId(kid) then doorLocked = true end
        end
    end)
    if doorLocked then
        LLMBotLastOpenDoorResult = { ok = false, reason = "locked", x = tx, y = ty, z = tz }
        print("[LLMBot] open_door: porte verrouillee (pas de cle)")
        return
    end
    if ISWorldObjectContextMenu and ISWorldObjectContextMenu.onOpenCloseDoor then
        ISWorldObjectContextMenu.onOpenCloseDoor(nil, door, player:getIndex())
        LLMBotLastOpenDoorResult = { ok = true, x = tx, y = ty, z = tz }
        print("[LLMBot] open_door " .. tx .. "," .. ty .. " ok")
    end
end

local function executeSmashWindow(player, cmd)
    local tx, ty = math.floor(tonumber(cmd.x) or 0), math.floor(tonumber(cmd.y) or 0)
    local tz = math.floor(tonumber(cmd.z) or player:getZ())
    local cell = getCell() or (player.getCell and player:getCell())
    if not cell or not tx or not ty then return end
    local function findWindowAt(sqx, sqy, sqz)
        local sq = cell:getGridSquare(sqx, sqy, sqz)
        if not sq then return nil end
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local obj = objs:get(i)
            if obj and (instanceof(obj, "IsoWindow") or (instanceof(obj, "IsoThumpable") and obj:isWindow())) then
                if obj.isInvincible and obj:isInvincible() then return nil end
                if obj.isSmashed and obj:isSmashed() then return nil end
                if obj.getBarricadeForCharacter and obj:getBarricadeForCharacter(player) then return nil end
                return obj
            end
        end
        return nil
    end
    local window = findWindowAt(tx, ty, tz)
    if not window then
        for _, d in ipairs({{0,1},{0,-1},{1,0},{-1,0}}) do
            window = findWindowAt(tx + d[1], ty + d[2], tz)
            if window then break end
        end
    end
    if window and ISSmashWindow then
        ISTimedActionQueue.add(ISSmashWindow:new(player, window, nil))
        print("[LLMBot] smash_window " .. tx .. "," .. ty .. " ok")
    else
        print("[LLMBot] smash_window: fenetre non trouvable ou deja cassee en (" .. tx .. "," .. ty .. ")")
    end
end

local function executeRemoveGlassWindow(player, cmd)
    local tx, ty = math.floor(tonumber(cmd.x) or 0), math.floor(tonumber(cmd.y) or 0)
    local tz = math.floor(tonumber(cmd.z) or player:getZ())
    local cell = getCell() or (player.getCell and player:getCell())
    if not cell or not tx or not ty then return end
    local function findSmashedWindowAt(sqx, sqy, sqz)
        local sq = cell:getGridSquare(sqx, sqy, sqz)
        if not sq then return nil end
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local obj = objs:get(i)
            if obj and (instanceof(obj, "IsoWindow") or (instanceof(obj, "IsoThumpable") and obj:isWindow())) then
                if obj.isSmashed and obj:isSmashed() and obj.isGlassRemoved and not obj:isGlassRemoved() then return obj end
            end
        end
        return nil
    end
    local window = findSmashedWindowAt(tx, ty, tz)
    if not window then
        for _, d in ipairs({{0,1},{0,-1},{1,0},{-1,0}}) do
            window = findSmashedWindowAt(tx + d[1], ty + d[2], tz)
            if window then break end
        end
    end
    if window and ISRemoveBrokenGlass then
        ISTimedActionQueue.add(ISRemoveBrokenGlass:new(player, window))
        print("[LLMBot] remove_glass_window " .. tx .. "," .. ty .. " ok")
    else
        print("[LLMBot] remove_glass_window: pas de fenetre cassee avec verre en (" .. tx .. "," .. ty .. ")")
    end
end

local function executeClimbThroughWindow(player, cmd)
    local tx, ty = math.floor(tonumber(cmd.x) or 0), math.floor(tonumber(cmd.y) or 0)
    local tz = math.floor(tonumber(cmd.z) or player:getZ())
    local cell = getCell() or (player.getCell and player:getCell())
    if not cell or not tx or not ty then return end
    local function findClimbableWindowAt(sqx, sqy, sqz)
        local sq = cell:getGridSquare(sqx, sqy, sqz)
        if not sq then return nil end
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local obj = objs:get(i)
            if obj and (instanceof(obj, "IsoWindow") or (instanceof(obj, "IsoThumpable") and obj:isWindow()) or instanceof(obj, "IsoWindowFrame")) then
                if obj.canClimbThrough and obj:canClimbThrough(player) then return obj end
            end
        end
        return nil
    end
    local window = findClimbableWindowAt(tx, ty, tz)
    if not window then
        for _, d in ipairs({{0,1},{0,-1},{1,0},{-1,0}}) do
            window = findClimbableWindowAt(tx + d[1], ty + d[2], tz)
            if window then break end
        end
    end
    if window and ISClimbThroughWindow then
        if luautils and luautils.walkAdjWindowOrDoor then
            luautils.walkAdjWindowOrDoor(player, window:getSquare(), window)
        end
        ISTimedActionQueue.add(ISClimbThroughWindow:new(player, window, 0))
        LLMBotWindowRedirectPending = nil  -- redirection resolue : on a enjambe la fenetre
        LLMBotWindowSequenceActive = false
        print("[LLMBot] climb_through_window " .. tx .. "," .. ty .. " ok")
    else
        print("[LLMBot] climb_through_window: pas de fenetre franchissable en (" .. tx .. "," .. ty .. ")")
    end
end

-- Marche vers une case adjacente au conteneur (tx,ty,tz) quand walkToContainer echoue (joueur trop loin).
local function walkToContainerSquare(player, tx, ty, tz)
    local cell = getCell() or (player.getCell and player:getCell())
    if not cell then return false end
    local sq = cell:getGridSquare(tx, ty, tz or player:getZ())
    if not sq then return false end
    local px, py = math.floor(player:getX()), math.floor(player:getY())
    local walkSquare = sq
    if AdjacentFreeTileFinder and AdjacentFreeTileFinder.Find then
        local adjacent = AdjacentFreeTileFinder.Find(sq, player)
        if adjacent and (adjacent:getX() ~= px or adjacent:getY() ~= py) then
            walkSquare = adjacent
        end
    end
    ISTimedActionQueue.add(LLMBotWalkToTimedAction:new(player, walkSquare))
    return true
end

local function executeLootContainer(player, cmd)
    local tx, ty = tonumber(cmd.x), tonumber(cmd.y)
    local tz = tonumber(cmd.z) or math.floor(player:getZ())
    if not tx or not ty then return end
    local cell = getCell()
    if not cell then return end
    local sq = cell:getGridSquare(tx, ty, tz)
    if not sq then return end
    local container = nil
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        if obj and obj.getContainer then local c = obj:getContainer(); if c then container = c break end end
    end
    if not container then print("[LLMBot] loot_container: pas de conteneur a " .. tx .. "," .. ty) return end
    ISTimedActionQueue.clear(player)
    pcall(function() if player.setSprinting then player:setSprinting(true) elseif player.setRunning and player:canSprint() then player:setRunning(true) end end)
    if luautils and luautils.walkToContainer and not luautils.walkToContainer(container, player:getPlayerNum()) then
        -- Joueur trop loin : marcher vers une case adjacente au conteneur, puis reessayer au prochain cycle
        if walkToContainerSquare(player, tx, ty, tz) then
            print("[LLMBot] loot_container: marche vers conteneur " .. tx .. "," .. ty .. " (reessayer apres arrivee)")
        else
            print("[LLMBot] loot_container: pas de case adjacente pour " .. tx .. "," .. ty)
        end
        return
    end
    local uiReady = false
    pcall(function()
        if ISInventoryPage and ISInventoryPage.playerInventory and ISInventoryPage.playerInventory.getX then uiReady = true end
    end)
    if uiReady then
        local panelX, panelY = 100, 100
        pcall(function()
            if getCore then panelX = math.max(0, getCore():getScreenWidth() / 2 - 130) panelY = math.max(0, getCore():getScreenHeight() / 2 - 60) end
        end)
        ISTimedActionQueue.add(ISOpenContainerTimedAction:new(player, container, 50, panelX, panelY))
        print("[LLMBot] loot_container: marche + ouverture conteneur " .. tx .. "," .. ty)
    else
        local added = false
        pcall(function()
            local loot = getPlayerLoot and getPlayerLoot(player:getPlayerNum())
            if not (loot and loot.inventoryPane and loot.inventoryPage and loot.inventoryPage.addContainerButton) then return end
            for bi = 1, #(loot.inventoryPage.backpacks or {}) do
                local cb = loot.inventoryPage.backpacks[bi]
                if cb and cb.inventory == container then added = true return end
            end
            if not container:isExplored() and isClient() and container.inventory and container.inventory.requestServerItemsForContainer then
                container.inventory:requestServerItemsForContainer()
            end
            container:setExplored(true)
            loot.inventoryPage:addContainerButton(container, nil, "Loot", nil)
            added = true
        end)
        if added then print("[LLMBot] loot_container: conteneur enregistre pour take_item " .. tx .. "," .. ty)
        else print("[LLMBot] loot_container: marche vers " .. tx .. "," .. ty .. " (ouvrir [I] pour take_item)") end
    end
end

local function executeEatBestFood(player, cmd)
    local inv, invItems = player:getInventory(), player:getInventory():getItems()
    local best, bestHC = nil, 0
    for i = 0, invItems:size() - 1 do
        local item = invItems:get(i)
        if item:IsFood() then local hc = item:getHungerChange(); if hc and hc < bestHC then bestHC = hc best = item end end
    end
    if best then ISTimedActionQueue.clear(player) ISTimedActionQueue.add(ISEatFoodAction:new(player, best, 1)) print("[LLMBot] eat_best_food: " .. tostring(best:getName()))
    else print("[LLMBot] eat_best_food: aucune nourriture") end
end

local function executeDrink(player, cmd)
    local spec, inv, invItems = cmd.item_type or cmd.item_name, player:getInventory(), player:getInventory():getItems()
    local chosen = nil
    for i = 0, invItems:size() - 1 do
        local item = invItems:get(i)
        if item and item.getFluidContainer and item:getFluidContainer() then
            local fc = item:getFluidContainer()
            if not fc:isEmpty() and fc.getPrimaryFluid and fc:getPrimaryFluid() then
                local ft = fc:getPrimaryFluid():getFluidTypeString()
                if (ft == "Water" or ft == "CarbonatedWater") and (not spec or tostring(item:getType()) == tostring(spec) or tostring(item:getName()) == tostring(spec)) then chosen = item break end
                if not chosen then chosen = item end
            end
        end
        if not chosen and item and item.isWaterSource and item:isWaterSource() and (not spec or tostring(item:getType()) == tostring(spec) or tostring(item:getName()) == tostring(spec)) then chosen = item break end
        if not chosen and item and item.isWaterSource and item:isWaterSource() then chosen = item end
    end
    if chosen then
        ISTimedActionQueue.clear(player)
        pcall(function()
            if ISDrinkFromBottle then ISTimedActionQueue.add(ISDrinkFromBottle:new(player, chosen, 1)) print("[LLMBot] drink: " .. tostring(chosen:getName()))
            elseif ISDrinkFluidAction then ISTimedActionQueue.add(ISDrinkFluidAction:new(player, chosen, 1)) print("[LLMBot] drink (fluid): " .. tostring(chosen:getName())) end
        end)
    else print("[LLMBot] drink: aucun item buvable") end
end

local function executeApplyBandage(player, cmd)
    local bodyParts, damaged = player:getBodyDamage():getBodyParts(), {}
    pcall(function()
        for idx = 0, BodyPartType.ToIndex(BodyPartType.MAX) - 1 do
            local bp = bodyParts:get(idx)
            if bp and not bp:bandaged() and (bp:scratched() or bp:deepWounded() or bp:bitten() or bp:stitched() or bp:bleeding() or bp:isBurnt()) then table.insert(damaged, bp) end
        end
    end)
    local worstPart, worstLevel = nil, -1
    for _, bp in ipairs(damaged) do local lvl = bp.getBandageNeededDamageLevel and bp:getBandageNeededDamageLevel() or 0; if lvl > worstLevel then worstLevel = lvl worstPart = bp end end
    if not worstPart and #damaged > 0 then worstPart = damaged[1] end
    local spec, inv, invItems = cmd.item_type or cmd.item_name, player:getInventory(), player:getInventory():getItems()
    local bandageItem = nil
    for i = 0, invItems:size() - 1 do
        local item = invItems:get(i)
        if item and item.isCanBandage and item:isCanBandage() and (not spec or tostring(item:getType()) == tostring(spec) or tostring(item:getName()) == tostring(spec)) then bandageItem = item break end
        if item and item.isCanBandage and item:isCanBandage() and not bandageItem then bandageItem = item end
    end
    if worstPart and bandageItem and ISApplyBandage then
        ISTimedActionQueue.clear(player) ISTimedActionQueue.add(ISApplyBandage:new(player, player, bandageItem, worstPart, true))
        print("[LLMBot] apply_bandage: " .. tostring(bandageItem:getName()))
    else
        if not worstPart then print("[LLMBot] apply_bandage: aucune partie endommagee") end
        if not bandageItem then print("[LLMBot] apply_bandage: aucun bandage") end
    end
end

local function executeEquipBestWeapon(player, cmd)
    local inv, invItems = player:getInventory(), player:getInventory():getItems()
    local best, bestCond = nil, -1
    for i = 0, invItems:size() - 1 do
        local item = invItems:get(i)
        if instanceof(item, "HandWeapon") and not item:isBroken() and item:getCondition() > 0 then
            local c = item:getCondition()
            if c > bestCond then bestCond = c best = item end
        end
    end
    if best then ISTimedActionQueue.clear(player) ISTimedActionQueue.add(ISEquipWeaponAction:new(player, best, 50, true, best:isTwoHandWeapon())) print("[LLMBot] equip_best_weapon: " .. tostring(best:getName())) end
end

local function executeAttackNearest(player, cmd)
    local c = getCell()
    if not c then return end
    local nearest, bestDist, zlist = nil, 999, c:getZombieList()
    for i = 0, zlist:size() - 1 do local z = zlist:get(i) local d = player:DistTo(z) if d < bestDist then bestDist = d nearest = z end end
    if nearest and bestDist < 2.5 then
        ISTimedActionQueue.clear(player)
        local attacked = false
        -- Methode 1 : DoAttack (Build 42)
        if not attacked then
            pcall(function()
                if player.DoAttack then
                    player:DoAttack(0)
                    attacked = true
                end
            end)
        end
        -- Methode 2 : ISAttackTimedAction (Build 41)
        if not attacked and ISAttackTimedAction then
            local ok, err = pcall(function()
                ISTimedActionQueue.add(ISAttackTimedAction:new(player, nearest, false))
                attacked = true
            end)
            if not ok then print("[LLMBot] ISAttackTimedAction erreur: " .. tostring(err)) end
        end
        -- Methode 2 : ISSwingTimedAction (Build 42+)
        if not attacked then
            pcall(function()
                if ISSwingTimedAction then
                    ISTimedActionQueue.add(ISSwingTimedAction:new(player, nearest))
                    attacked = true
                end
            end)
        end
        -- Methode 3 : player:attack() direct
        if not attacked then
            pcall(function()
                if player.attack then
                    player:attack(nearest, false)
                    attacked = true
                end
            end)
        end
        -- Methode 4 : forcer le joueur a viser et attaquer via setAttacking
        if not attacked then
            pcall(function()
                if player.setAttackTarget then player:setAttackTarget(nearest) end
                if player.setAttacking then player:setAttacking(true) attacked = true end
            end)
        end
        if attacked then
            print("[LLMBot] attack_nearest dist=" .. math.floor(bestDist))
        else
            print("[LLMBot] attack_nearest: aucune methode d'attaque disponible (dist=" .. math.floor(bestDist) .. ")")
        end
    end
end

local function executeSay(player, cmd)
    if cmd.text then player:Say(tostring(cmd.text):sub(1, 100)) end
end

local function executeSprintToggle(player, cmd)
    pcall(function()
        if player.setSprinting then
            local cur = false
            if player.isSprinting then cur = player:isSprinting() end
            player:setSprinting(not cur)
            print("[LLMBot] sprint_toggle (setSprinting): " .. tostring(not cur))
        elseif player.setRunning then
            player:setRunning(not player:isRunning())
            print("[LLMBot] sprint_toggle (setRunning): " .. tostring(player:isRunning()))
        elseif player.setVariable and player.getVariableBoolean then
            local cur = player:getVariableBoolean("IsRunning")
            player:setVariable("IsRunning", not cur)
            print("[LLMBot] sprint_toggle (var): " .. tostring(not cur))
        end
    end)
end

local function executeDropHeaviest(player, cmd)
    local inv, invItems = player:getInventory(), player:getInventory():getItems()
    local heaviest, bestWeight = nil, -1
    for i = 0, invItems:size() - 1 do local item = invItems:get(i) local w = (item.getActualWeight and item:getActualWeight()) or 0 if w > bestWeight then bestWeight = w heaviest = item end end
    if heaviest then
        ISTimedActionQueue.clear(player)
        local dropContainer = nil
        pcall(function() if ISInventoryPage and ISInventoryPage.GetFloorContainer then dropContainer = ISInventoryPage.GetFloorContainer(player:getPlayerNum()) end end)
        if dropContainer then ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(player, heaviest, inv, dropContainer)) print("[LLMBot] drop_heaviest: " .. tostring(heaviest:getName()))
        else print("[LLMBot] drop_heaviest: GetFloorContainer indisponible") end
    else print("[LLMBot] drop_heaviest: inventaire vide") end
end

local function executeTakeItemFromContainer(player, cmd)
    local tx, ty = tonumber(cmd.x), tonumber(cmd.y)
    local tz = tonumber(cmd.z) or math.floor(player:getZ())
    local itemSpec = cmd.item_type or cmd.item_name
    if not tx or not ty or not itemSpec then print("[LLMBot] take_item_from_container: x,y,item_type ou item_name requis") return end
    local cell = getCell()
    if not cell then return end
    local sq = cell:getGridSquare(tx, ty, tz)
    if not sq then return end
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local obj = objects:get(i)
        local container = obj:getContainer()
        if container then
            pcall(function()
                local loot = getPlayerLoot and getPlayerLoot(player:getPlayerNum())
                if not (loot and loot.inventoryPane and loot.inventoryPage and loot.inventoryPage.addContainerButton) then return end
                for bi = 1, #(loot.inventoryPage.backpacks or {}) do
                    if loot.inventoryPage.backpacks[bi] and loot.inventoryPage.backpacks[bi].inventory == container then return end
                end
                if not container:isExplored() and isClient() and container.inventory and container.inventory.requestServerItemsForContainer then container.inventory:requestServerItemsForContainer() end
                container:setExplored(true)
                loot.inventoryPage:addContainerButton(container, nil, "Loot", nil)
            end)
            if not luautils.walkToContainer(container, player:getPlayerNum()) then
                -- Joueur trop loin : marcher vers une case adjacente au conteneur
                if walkToContainerSquare(player, tx, ty, tz) then
                    print("[LLMBot] take_item_from_container: marche vers conteneur " .. tx .. "," .. ty .. " (reessayer apres arrivee)")
                end
                return
            end
            local px, py = math.floor(player:getX()), math.floor(player:getY())
            if px == tx and py == ty then LLMBotLastTakeResult = { ok = false, x = tx, y = ty, z = tz, item_type = tostring(itemSpec) } return end
            local cItems, itemSpecStr = container:getItems(), tostring(itemSpec)
            for j = 0, cItems:size() - 1 do
                local item = cItems:get(j)
                local itype, iname = tostring(item:getType()), tostring(item:getName())
                local exactMatch = (itype == itemSpecStr or iname == itemSpecStr)
                local suffixMatch = (itype:find(itemSpecStr, 1, true) or itemSpecStr:find(itype, 1, true) or iname:find(itemSpecStr, 1, true) or itemSpecStr:find(iname, 1, true))
                if exactMatch or suffixMatch then
                    LLMBotLastTakeItemTick = LLMBotGlobalTick
                    local transferTime = 15
                    ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(player, item, container, player:getInventory(), transferTime))
                    print("[LLMBot] take_item_from_container: " .. iname .. " at " .. tx .. "," .. ty)
                    -- Ne pas rapporter succes tout de suite : le jeu peut annuler l'action (bugged action). On verifiera au prochain tick.
                    LLMBotPendingTakeContainer = { x = tx, y = ty, z = tz }
                    LLMBotPendingTakeItemSpec = itemSpecStr
                    return
                end
            end
            print("[LLMBot] take_item_from_container: item non trouvé " .. tostring(itemSpec))
            LLMBotLastTakeResult = { ok = false, x = tx, y = ty, z = tz, item_type = tostring(itemSpec) } return
        end
    end
    print("[LLMBot] take_item_from_container: pas de conteneur à " .. tx .. "," .. ty)
    LLMBotLastTakeResult = { ok = false, x = tx, y = ty, z = tz, item_type = tostring(itemSpec) }
end

local function executeGrabWorldItem(player, cmd)
    local tx, ty = tonumber(cmd.x), tonumber(cmd.y)
    local tz = tonumber(cmd.z) or math.floor(player:getZ())
    local idx = tonumber(cmd.index)
    local cell = getCell()
    if not cell then return end
    local worldItemObj = nil
    if tx and ty then
        local sq = cell:getGridSquare(tx, ty, tz)
        if sq then local wobs = sq:getWorldObjects(); if wobs and wobs:size() > 0 then worldItemObj = wobs:get(0) end end
    elseif idx and idx >= 1 then
        local list = scanWorldItemsNearPlayer(cell, math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ()))
        local e = list[idx]
        if e then
            local sq = cell:getGridSquare(e.x, e.y, e.z or math.floor(player:getZ()))
            if sq then
                local wobs = sq:getWorldObjects()
                for wi = 0, wobs:size() - 1 do
                    local wob = wobs:get(wi)
                    if wob and wob.getItem then
                        local it = wob:getItem()
                        if it and tostring(it:getType()) == (e.type or "") and tostring(it:getName()) == (e.name or "") then worldItemObj = wob break end
                    end
                end
            end
        end
    end
    if worldItemObj and luautils.walkAdj(player, worldItemObj:getSquare()) then
        local time = (ISWorldObjectContextMenu and ISWorldObjectContextMenu.grabItemTime and ISWorldObjectContextMenu.grabItemTime(player, worldItemObj)) or 50
        ISTimedActionQueue.add(ISGrabItemAction:new(player, worldItemObj, time))
        print("[LLMBot] grab_world_item at " .. (tx or "?") .. "," .. (ty or "?"))
    else print("[LLMBot] grab_world_item: objet introuvable ou trop loin") end
end

local function executeEquipWeapon(player, cmd)
    local spec = tostring(cmd.item_type or cmd.item_name or "")
    local inv, invItems = player:getInventory(), player:getInventory():getItems()
    for i = 0, invItems:size() - 1 do
        local item = invItems:get(i)
        if instanceof(item, "HandWeapon") and not item:isBroken() and item:getCondition() > 0 and (tostring(item:getType()) == spec or tostring(item:getName()) == spec) then
            ISTimedActionQueue.clear(player) ISTimedActionQueue.add(ISEquipWeaponAction:new(player, item, 50, true, item:isTwoHandWeapon())) print("[LLMBot] equip_weapon: " .. tostring(item:getName())) return
        end
    end
    print("[LLMBot] equip_weapon: aucune arme pour " .. spec)
end

local function executeEquipClothing(player, cmd)
    local spec = tostring(cmd.item_type or cmd.item_name or "")
    local inv, invItems = player:getInventory(), player:getInventory():getItems()
    for i = 0, invItems:size() - 1 do
        local item = invItems:get(i)
        if item.IsClothing and item:IsClothing() and (tostring(item:getType()) == spec or tostring(item:getName()) == spec) then
            ISTimedActionQueue.clear(player) ISTimedActionQueue.add(ISWearClothing:new(player, item, 50)) print("[LLMBot] equip_clothing: " .. tostring(item:getName())) return
        end
    end
    print("[LLMBot] equip_clothing: aucun vêtement pour " .. spec)
end

local function executeCommand(player, cmd)
    if not cmd or not cmd.action then return end
    local a = cmd.action
    if a == "move_to" then executeMoveTo(player, cmd) return end
    if a == "open_door" then executeOpenDoor(player, cmd) return end
    if a == "smash_window" then executeSmashWindow(player, cmd) return end
    if a == "remove_glass_window" then executeRemoveGlassWindow(player, cmd) return end
    if a == "climb_through_window" then executeClimbThroughWindow(player, cmd) return end
    if a == "loot_container" then executeLootContainer(player, cmd) return end
    if a == "eat_best_food" then executeEatBestFood(player, cmd) return end
    if a == "drink" then executeDrink(player, cmd) return end
    if a == "apply_bandage" then executeApplyBandage(player, cmd) return end
    if a == "equip_best_weapon" then executeEquipBestWeapon(player, cmd) return end
    if a == "attack_nearest" then executeAttackNearest(player, cmd) return end
    if a == "say" then executeSay(player, cmd) return end
    if a == "sprint_toggle" then executeSprintToggle(player, cmd) return end
    if a == "drop_heaviest" then executeDropHeaviest(player, cmd) return end
    if a == "take_item_from_container" then executeTakeItemFromContainer(player, cmd) return end
    if a == "grab_world_item" then executeGrabWorldItem(player, cmd) return end
    if a == "equip_weapon" then executeEquipWeapon(player, cmd) return end
    if a == "equip_clothing" then executeEquipClothing(player, cmd) return end
    if a == "idle" then print("[LLMBot] idle") return end
    print("[LLMBot] action inconnue: " .. tostring(a))
end

-- ---------------------------------------------------------------
-- 5. BOUCLE PRINCIPALE
-- ---------------------------------------------------------------
local tickCounter = 0

Events.OnTick.Add(function()
    LLMBotGlobalTick = (LLMBotGlobalTick or 0) + 1
    tickCounter = tickCounter + 1
    if tickCounter < LLMBot.TICK_RATE then return end
    tickCounter = 0

    local player = getPlayer()
    if not player then return end

    -- Flux limite : envoi -> attente decision LLM -> selon decision on renvoie un statut.
    -- 1) Lire la commande eventuelle
    local raw = readFile(LLMBot.CMD_FILE)
    if raw and raw ~= "" then
        local cmd = LLMBot.fromJSON(raw)
        if cmd and cmd.action then
            local ok, result = pcall(buildObservation, player)
            if not ok then
                print("[LLMBot] obs error: " .. tostring(result))
                return
            end
            -- Quand is_busy, seules certaines actions peuvent s'executer (elles interrompent l'action en cours).
            -- move_to interrompt pour que la nouvelle destination soit toujours prise en compte (evite commandes perdues).
            -- EXCEPTION : si une sequence fenetre auto est en cours, aucun move_to ne doit l'interrompre.
            local canInterruptWhenBusy = (cmd.action == "move_to" or cmd.action == "sprint_toggle" or cmd.action == "open_door" or cmd.action == "smash_window" or cmd.action == "remove_glass_window" or cmd.action == "climb_through_window")
            -- Bloquer move_to pendant une sequence fenetre auto (evite ISTimedActionQueue.clear)
            if LLMBotWindowSequenceActive and cmd.action == "move_to" then
                LLMBotLastMoveToTick = LLMBotGlobalTick  -- prolonger is_busy
                print("[LLMBot] move_to bloque : sequence fenetre auto en cours")
                -- Garder le fichier cmd pour que le bridge attende
                local ok2, result2 = pcall(buildObservation, player)
                if ok2 and result2 then writeFile(LLMBot.OBS_FILE, LLMBot.toJSON(result2)) end
                return
            end
            -- Detecter move_to vers case deja en cours (evite interruption/relance boucle)
            local sameWalkToInProgress = false
            if cmd.action == "move_to" then
                local qtx, qty = tonumber(cmd.x), tonumber(cmd.y)
                if qtx and qty then
                    local cell2 = getCell()
                    local pz2 = math.floor(getPlayer():getZ())
                    local tSq = cell2 and cell2:getGridSquare(math.floor(qtx), math.floor(qty), pz2)
                    local walkSq2 = tSq
                    if tSq and AdjacentFreeTileFinder and AdjacentFreeTileFinder.Find then
                        local adj = AdjacentFreeTileFinder.Find(tSq, player)
                        if adj then walkSq2 = adj end
                    end
                    local qq = ISTimedActionQueue.queues and ISTimedActionQueue.queues[player]
                    if qq and qq.queue and qq.queue[1] and walkSq2 then
                        local cur2 = qq.queue[1]
                        local typ2 = (cur2.Type and tostring(cur2.Type)) or ""
                        if typ2:find("WalkTo") and cur2.location then
                            if cur2.location:getX() == walkSq2:getX() and cur2.location:getY() == walkSq2:getY() then
                                sameWalkToInProgress = true
                                LLMBotLastMoveToTick = LLMBotGlobalTick  -- prolonger is_busy
                                print("[LLMBot] move_to: WalkTo identique deja en cours (" .. cur2.location:getX() .. "," .. cur2.location:getY() .. ") — cmd conservee, LLMBotLastMoveToTick prolonge")
                            end
                        end
                    end
                end
            end
            if sameWalkToInProgress then
                -- Ne pas supprimer le fichier cmd et ne pas executer : le bridge attendra
            elseif not result.is_busy or canInterruptWhenBusy then
                deleteFile(LLMBot.CMD_FILE)
                executeCommand(player, cmd)
            else
                -- Ne pas supprimer le fichier : le jeu relira la meme commande au prochain cycle (evite perte de commande).
                print("[LLMBot] busy, skip: " .. tostring(cmd.action) .. " — attente fin action (commande conservee)")
            end
            -- Apres execution (ou skip) : nouveau statut pour la prochaine decision
            ok, result = pcall(buildObservation, player)
            if ok and result then
                writeFile(LLMBot.OBS_FILE, LLMBot.toJSON(result))
            end
        else
            -- Commande invalide : on supprime pour debloquer le cycle
            deleteFile(LLMBot.CMD_FILE)
        end
        return
    end

    -- 2) Pas de commande en attente : envoi du statut actuel (demande de decision au LLM)
    local ok, result = pcall(buildObservation, player)
    if not ok then
        print("[LLMBot] obs error: " .. tostring(result))
        return
    end
    writeFile(LLMBot.OBS_FILE, LLMBot.toJSON(result))
end)

Events.OnGameStart.Add(function()
    print("[LLMBot] v1.0 pret (world_items, poids, worn_clothing, sprint_toggle, drop_heaviest, take_item, grab_world_item, equip_weapon, equip_clothing).")
    writeFile("LLMBot_test.txt", "ok v1.0")
end)
