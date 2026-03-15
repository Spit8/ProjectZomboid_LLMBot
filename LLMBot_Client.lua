-- LLMBot_Client.lua v1.0 — Build 42.15
-- Plan ANALYSE_LLM_DECISIONS : world_items, poids, worn_clothing, is_clothing,
--   take_item_from_container, grab_world_item, sprint_toggle, drop_heaviest,
--   equip_weapon (ciblé), equip_clothing.
-- Requis: TimedActions/ISGrabItemAction, ISInventoryTransferUtil, ISWearClothing (chargés par le jeu)

-- Charger les TimedActions utilisées (conteneur -> inventaire, ramassage au sol)
if not ISInventoryTransferUtil then require "TimedActions/ISInventoryTransferUtil" end
if not ISGrabItemAction then require "TimedActions/ISGrabItemAction" end

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

    -- Armes equipees
    local primary = player:getPrimaryHandItem()
    if primary then
        obs.equipped.primary = {
            name      = tostring(primary:getName()),
            type      = tostring(primary:getType()),
            is_weapon = instanceof(primary, "HandWeapon"),
        }
        local wf = getWeaponConditionFields(primary)
        if wf then
            obs.equipped.primary.condition = wf.condition
            obs.equipped.primary.condition_max = wf.condition_max
            obs.equipped.primary.is_broken = wf.is_broken
        end
        pcall(function()
            if primary.isTwoHandWeapon and primary:isTwoHandWeapon() then
                obs.equipped.primary.is_two_handed = true
            end
        end)
    end
    local secondary = player:getSecondaryHandItem()
    if secondary and secondary ~= primary then
        obs.equipped.secondary = {
            name = tostring(secondary:getName()),
            type = tostring(secondary:getType()),
            is_weapon = instanceof(secondary, "HandWeapon"),
        }
        local wf = getWeaponConditionFields(secondary)
        if wf then
            obs.equipped.secondary.condition = wf.condition
            obs.equipped.secondary.condition_max = wf.condition_max
            obs.equipped.secondary.is_broken = wf.is_broken
        end
        pcall(function()
            if secondary.isTwoHandWeapon and secondary:isTwoHandWeapon() then
                obs.equipped.secondary.is_two_handed = true
            end
        end)
    end

    -- Inventaire
    local inv      = player:getInventory()
    local invItems = inv:getItems()
    for i = 0, math.min(invItems:size() - 1, 29) do
        local item  = invItems:get(i)
        local entry = {
            name      = tostring(item:getName()),
            type      = tostring(item:getType()),
            weight    = item:getActualWeight(),
        }
        if item:IsFood() then
            entry.is_food       = true
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
        table.insert(obs.inventory, entry)
    end

    local cell = getCell()

    -- Poids inventaire (getCapacityWeight, getEffectiveCapacity, getMaxWeight — ISInventoryPage, XpUpdate)
    pcall(function()
        local inv = player:getInventory()
        obs.inventory_weight = (inv.getCapacityWeight and inv:getCapacityWeight()) or 0
        obs.max_weight = (inv.getEffectiveCapacity and inv:getEffectiveCapacity(player)) or (player.getMaxWeight and player:getMaxWeight()) or 0
        if obs.max_weight == 0 and player.getMaxWeight then obs.max_weight = player:getMaxWeight() end
    end)

    -- Vêtements portés (getWornItems, getItem, getLocation, getBiteDefense, getScratchDefense — ISInventoryPaneContextMenu)
    obs.worn_clothing = {}
    pcall(function()
        local wornItems = player:getWornItems()
        if wornItems and wornItems.size then
            for i = 1, wornItems:size() do
                local worn = wornItems:get(i - 1)
                if worn and worn.getItem then
                    local it = worn:getItem()
                    if it then
                        local loc = worn.getLocation and worn:getLocation()
                        local e = {
                            name = tostring(it:getName()),
                            type = tostring(it:getType()),
                            body_location = loc and tostring(loc) or nil,
                        }
                        if it.getBiteDefense then e.bite_defense = it:getBiteDefense() end
                        if it.getScratchDefense then e.scratch_defense = it:getScratchDefense() end
                        table.insert(obs.worn_clothing, e)
                    end
                end
            end
        end
    end)

    -- Objets au sol à proximité
    obs.world_items = scanWorldItemsNearPlayer(cell, px, py, pz)

    -- Zombies dans la zone visible a l'ecran (meme rayon que batiments)
    if cell then
        local zlist = cell:getZombieList()
        local inRadius = {}
        for i = 0, zlist:size() - 1 do
            local ze = zlist:get(i)
            local d = player:DistTo(ze)
            if d <= VISIBLE_RADIUS then
                table.insert(inRadius, { ze = ze, dist = d })
            end
        end
        table.sort(inRadius, function(a, b) return a.dist < b.dist end)
        for _, e in ipairs(inRadius) do
            if #obs.zombies >= 60 then break end
            local ze = e.ze
            table.insert(obs.zombies, {
                x    = math.floor(ze:getX()),
                y    = math.floor(ze:getY()),
                dist = math.floor(e.dist),
            })
        end
    end

    -- Conteneurs dans les 5 tiles autour du joueur
    -- Confirme ISMenuContextWorld.lua : player:getCurrentSquare()
    -- Confirme ISMenuContextWorld.lua : sq:getObjects()
    local currentSq = player:getCurrentSquare()
    if currentSq and cell then
        for dx = -5, 5 do
            for dy = -5, 5 do
                local sq = cell:getGridSquare(px + dx, py + dy, pz)
                if sq then
                    local found = scanSquareContainers(sq, px, py)
                    for _, c in ipairs(found) do
                        table.insert(obs.containers, c)
                    end
                end
            end
        end
    end

    -- Bâtiments les plus proches (getRoom, getBuilding — DebugChunkState_SquarePanel)
    obs.buildings = scanNearbyBuildings(player, cell, px, py, pz)
    -- Nombre de zombies a l'interieur de chaque batiment (meme rayon que zombies visibles)
    if cell then
        local zlist = cell:getZombieList()
        countZombiesInBuildings(cell, obs.buildings, zlist, player, VISIBLE_RADIUS)
    end

    -- Interieur / exterieur + batiment actuel (ID du jeu : getBuilding():getID())
    local sq = cell:getGridSquare(px, py, pz)
    if sq then
        obs.is_indoors = sq:getRoom() ~= nil
        if sq:getRoom() then
            local b = sq:getBuilding()
            if b then
                obs.building_id = b:getID()
                obs.building_name = "Building"
                pcall(function()
                    local roomDef = sq:getRoom():getRoomDef()
                    if roomDef then obs.building_name = tostring(roomDef:getName()) end
                end)
            end
        end
    end

    -- Heure du jeu
    local gt      = getGameTime()
    obs.game_hour = gt:getTimeOfDay()
    obs.game_day  = gt:getDay()

    -- File d'actions
    if ISTimedActionQueue.queues and ISTimedActionQueue.queues[player] then
        obs.action_queue = #ISTimedActionQueue.queues[player]
    end
    obs.is_busy = obs.action_queue > 0

    return obs
end

-- ---------------------------------------------------------------
-- 4. ACTIONS
-- ---------------------------------------------------------------
local function executeCommand(player, cmd)
    if not cmd or not cmd.action then return end
    local a = cmd.action

    if a == "move_to" then
        local tx = tonumber(cmd.x)
        local ty = tonumber(cmd.y)
        local tz = tonumber(cmd.z) or math.floor(player:getZ())
        if not tx or not ty then return end
        local square = getCell():getGridSquare(tx, ty, tz)
        if not square then print("[LLMBot] move_to: square introuvable"); return end
        ISTimedActionQueue.clear(player)
        ISTimedActionQueue.add(ISWalkToTimedAction:new(player, square))
        print("[LLMBot] move_to " .. tx .. "," .. ty)

    elseif a == "loot_container" then
        -- ISOpenContainerTimedAction:new(character, container, time, x, y)
        local tx = tonumber(cmd.x)
        local ty = tonumber(cmd.y)
        local tz = tonumber(cmd.z) or math.floor(player:getZ())
        if not tx or not ty then return end
        local sq = getCell():getGridSquare(tx, ty, tz)
        if not sq then return end
        local objects = sq:getObjects()
        for i = 0, objects:size() - 1 do
            local obj       = objects:get(i)
            local container = obj:getContainer()
            if container then
                ISTimedActionQueue.clear(player)
                ISTimedActionQueue.add(ISOpenContainerTimedAction:new(player, container, 50, tx, ty))
                print("[LLMBot] loot_container at " .. tx..","..ty)
                break
            end
        end

    elseif a == "eat_best_food" then
        local inv      = player:getInventory()
        local invItems = inv:getItems()
        local best, bestHC = nil, 0
        for i = 0, invItems:size() - 1 do
            local item = invItems:get(i)
            if item:IsFood() then
                local hc = item:getHungerChange()
                if hc and hc < bestHC then bestHC = hc; best = item end
            end
        end
        if best then
            ISTimedActionQueue.clear(player)
            ISTimedActionQueue.add(ISEatFoodAction:new(player, best, 1))
            print("[LLMBot] eat_best_food: " .. tostring(best:getName()))
        else
            print("[LLMBot] eat_best_food: aucune nourriture")
        end

    elseif a == "equip_best_weapon" then
        local inv      = player:getInventory()
        local invItems = inv:getItems()
        local best, bestCond = nil, -1
        for i = 0, invItems:size() - 1 do
            local item = invItems:get(i)
            if instanceof(item, "HandWeapon") and not item:isBroken() and item:getCondition() > 0 then
                local c = item:getCondition()
                if c > bestCond then bestCond = c; best = item end
            end
        end
        if best then
            ISTimedActionQueue.clear(player)
            ISTimedActionQueue.add(ISEquipWeaponAction:new(player, best, 50, true, best:isTwoHandWeapon()))
            print("[LLMBot] equip_best_weapon: " .. tostring(best:getName()) .. " cond=" .. best:getCondition())
        end

    elseif a == "attack_nearest" then
        local c = getCell()
        if not c then return end
        local nearest, bestDist = nil, 999
        local zlist = c:getZombieList()
        for i = 0, zlist:size() - 1 do
            local z = zlist:get(i)
            local d = player:DistTo(z)
            if d < bestDist then bestDist = d; nearest = z end
        end
        if nearest and bestDist < 2.5 then
            ISTimedActionQueue.clear(player)
            ISTimedActionQueue.add(ISAttackTimedAction:new(player, nearest, false))
            print("[LLMBot] attack_nearest dist=" .. math.floor(bestDist))
        end

    elseif a == "say" then
        if cmd.text then player:Say(tostring(cmd.text):sub(1, 100)) end

    elseif a == "sprint_toggle" then
        pcall(function()
            if player.setRunning then
                player:setRunning(not player:isRunning())
                print("[LLMBot] sprint_toggle: " .. tostring(player:isRunning()))
            elseif player.setVariable and player.getVariableBoolean then
                local cur = player:getVariableBoolean("IsRunning")
                player:setVariable("IsRunning", not cur)
                print("[LLMBot] sprint_toggle (var): " .. tostring(not cur))
            end
        end)

    elseif a == "drop_heaviest" then
        local inv = player:getInventory()
        local invItems = inv:getItems()
        local heaviest, bestWeight = nil, -1
        for i = 0, invItems:size() - 1 do
            local item = invItems:get(i)
            local w = (item.getActualWeight and item:getActualWeight()) or 0
            if w > bestWeight then bestWeight = w; heaviest = item end
        end
        if heaviest then
            ISTimedActionQueue.clear(player)
            local dropContainer = nil
            pcall(function()
                if ISInventoryPage and ISInventoryPage.GetFloorContainer then
                    dropContainer = ISInventoryPage.GetFloorContainer(player:getPlayerNum())
                end
            end)
            if dropContainer then
                ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(player, heaviest, inv, dropContainer))
                print("[LLMBot] drop_heaviest: " .. tostring(heaviest:getName()))
            else
                print("[LLMBot] drop_heaviest: GetFloorContainer indisponible")
            end
        else
            print("[LLMBot] drop_heaviest: inventaire vide")
        end

    elseif a == "take_item_from_container" then
        local tx = tonumber(cmd.x)
        local ty = tonumber(cmd.y)
        local tz = tonumber(cmd.z) or math.floor(player:getZ())
        local itemSpec = cmd.item_type or cmd.item_name
        if not tx or not ty or not itemSpec then
            print("[LLMBot] take_item_from_container: x,y,item_type ou item_name requis")
            return
        end
        local sq = getCell():getGridSquare(tx, ty, tz)
        if not sq then return end
        local objects = sq:getObjects()
        for i = 0, objects:size() - 1 do
            local obj = objects:get(i)
            local container = obj:getContainer()
            if container then
                if not luautils.walkToContainer(container, player:getPlayerNum()) then return end
                local cItems = container:getItems()
                for j = 0, cItems:size() - 1 do
                    local item = cItems:get(j)
                    local itype = tostring(item:getType())
                    local iname = tostring(item:getName())
                    if itype == tostring(itemSpec) or iname == tostring(itemSpec) then
                        ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(player, item, container, player:getInventory()))
                        print("[LLMBot] take_item_from_container: " .. iname .. " at " .. tx .. "," .. ty)
                        return
                    end
                end
                print("[LLMBot] take_item_from_container: item non trouvé " .. tostring(itemSpec))
                return
            end
        end
        print("[LLMBot] take_item_from_container: pas de conteneur à " .. tx .. "," .. ty)

    elseif a == "grab_world_item" then
        local tx = tonumber(cmd.x)
        local ty = tonumber(cmd.y)
        local tz = tonumber(cmd.z) or math.floor(player:getZ())
        local idx = tonumber(cmd.index)
        local cell = getCell()
        if not cell then return end
        local worldItemObj = nil
        if tx and ty then
            local sq = cell:getGridSquare(tx, ty, tz)
            if sq then
                local wobs = sq:getWorldObjects()
                if wobs and wobs:size() > 0 then
                    worldItemObj = wobs:get(0)
                end
            end
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
                            if it and tostring(it:getType()) == (e.type or "") and tostring(it:getName()) == (e.name or "") then
                                worldItemObj = wob
                                break
                            end
                        end
                    end
                end
            end
        end
        if worldItemObj and luautils.walkAdj(player, worldItemObj:getSquare()) then
            local time = 50
            if ISWorldObjectContextMenu and ISWorldObjectContextMenu.grabItemTime then
                time = ISWorldObjectContextMenu.grabItemTime(player, worldItemObj)
            end
            ISTimedActionQueue.add(ISGrabItemAction:new(player, worldItemObj, time))
            print("[LLMBot] grab_world_item at " .. (tx or "?") .. "," .. (ty or "?"))
        else
            print("[LLMBot] grab_world_item: objet introuvable ou trop loin")
        end

    elseif a == "equip_weapon" then
        local spec = cmd.item_type or cmd.item_name
        if not spec then spec = "" end
        spec = tostring(spec)
        local inv = player:getInventory()
        local invItems = inv:getItems()
        for i = 0, invItems:size() - 1 do
            local item = invItems:get(i)
            if instanceof(item, "HandWeapon") and not item:isBroken() and item:getCondition() > 0 then
                if tostring(item:getType()) == spec or tostring(item:getName()) == spec then
                    ISTimedActionQueue.clear(player)
                    ISTimedActionQueue.add(ISEquipWeaponAction:new(player, item, 50, true, item:isTwoHandWeapon()))
                    print("[LLMBot] equip_weapon: " .. tostring(item:getName()))
                    return
                end
            end
        end
        print("[LLMBot] equip_weapon: aucune arme correspondante pour " .. spec)

    elseif a == "equip_clothing" then
        local spec = cmd.item_type or cmd.item_name
        if not spec then spec = "" end
        spec = tostring(spec)
        local inv = player:getInventory()
        local invItems = inv:getItems()
        for i = 0, invItems:size() - 1 do
            local item = invItems:get(i)
            if item.IsClothing and item:IsClothing() then
                if tostring(item:getType()) == spec or tostring(item:getName()) == spec then
                    ISTimedActionQueue.clear(player)
                    ISTimedActionQueue.add(ISWearClothing:new(player, item, 50))
                    print("[LLMBot] equip_clothing: " .. tostring(item:getName()))
                    return
                end
            end
        end
        print("[LLMBot] equip_clothing: aucun vêtement correspondant pour " .. spec)

    elseif a == "idle" then
        print("[LLMBot] idle")

    else
        print("[LLMBot] action inconnue: " .. tostring(a))
    end
end

-- ---------------------------------------------------------------
-- 5. BOUCLE PRINCIPALE
-- ---------------------------------------------------------------
local tickCounter = 0

Events.OnTick.Add(function()
    tickCounter = tickCounter + 1
    if tickCounter < LLMBot.TICK_RATE then return end
    tickCounter = 0

    local player = getPlayer()
    if not player then return end

    local ok, result = pcall(buildObservation, player)
    if not ok then
        print("[LLMBot] obs error: " .. tostring(result))
        return
    end

    writeFile(LLMBot.OBS_FILE, LLMBot.toJSON(result))

    local raw = readFile(LLMBot.CMD_FILE)
    if raw and raw ~= "" then
        local cmd = LLMBot.fromJSON(raw)
        if cmd and cmd.action then
            deleteFile(LLMBot.CMD_FILE)
            if not result.is_busy or cmd.action == "move_to" or cmd.action == "sprint_toggle" then
                executeCommand(player, cmd)
            else
                print("[LLMBot] busy, skip: " .. tostring(cmd.action))
            end
        end
    end
end)

Events.OnGameStart.Add(function()
    print("[LLMBot] v1.0 pret (world_items, poids, worn_clothing, sprint_toggle, drop_heaviest, take_item, grab_world_item, equip_weapon, equip_clothing).")
    writeFile("LLMBot_test.txt", "ok v1.0")
end)
