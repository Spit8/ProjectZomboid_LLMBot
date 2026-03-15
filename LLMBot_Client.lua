-- LLMBot_Client.lua v0.9 — Build 42.15
-- Sources confirmees : ISEatFoodAction, ISEquipWeaponAction, WalkToTimedAction,
--                      ISStatsAndBody, ISHealthPanel, ISMenuContextWorld,
--                      ISOpenContainerTimedAction, ISInventoryPane (getCondition),
--                      DebugChunkState_SquarePanel (getRoom, getBuilding, getDef)

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
                    end
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

-- ---------------------------------------------------------------
-- 3. OBSERVATION
-- ---------------------------------------------------------------
local function buildObservation(player)
    local obs = {
        position     = {},
        stats        = {},
        inventory    = {},
        zombies      = {},
        containers   = {},
        buildings    = {},
        equipped     = {},
        action_queue = 0,
        is_busy      = false,
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
        end
        table.insert(obs.inventory, entry)
    end

    -- Zombies dans la zone visible a l'ecran (meme rayon que batiments)
    local cell = getCell()
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
            if not result.is_busy or cmd.action == "move_to" then
                executeCommand(player, cmd)
            else
                print("[LLMBot] busy, skip: " .. tostring(cmd.action))
            end
        end
    end
end)

Events.OnGameStart.Add(function()
    print("[LLMBot] v0.9 pret.")
    writeFile("LLMBot_test.txt", "ok v0.9")
end)
