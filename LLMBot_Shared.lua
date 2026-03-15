-- LLMBot_Shared.lua
-- Constantes et serialisation JSON legere, chargees cote client ET serveur.

LLMBot = LLMBot or {}

LLMBot.VERSION     = "0.1.0"
LLMBot.TICK_RATE   = 60          -- ticks entre chaque polling (env. 2s a 30 tps)
LLMBot.CMD_FILE    = "LLMBot_cmd.json"   -- bridge ecrit ici
LLMBot.OBS_FILE    = "LLMBot_obs.json"   -- mod ecrit ici

-- Actions reconnues (le bridge envoie l'une de ces valeurs)
LLMBot.ACTIONS = {
    "move_to",                  -- {action, x, y, z?}
    "attack_nearest",           -- {action}
    "loot_container",           -- {action, x, y, z}
    "equip_best_weapon",        -- {action}
    "equip_weapon",             -- {action, item_type ou item_name}
    "equip_clothing",           -- {action, item_type ou item_name}
    "eat_best_food",            -- {action}
    "drop_heaviest",            -- {action}
    "sprint_toggle",            -- {action}
    "take_item_from_container", -- {action, x, y, z, item_type ou item_name}
    "grab_world_item",          -- {action, x, y, z} ou {action, index} (index dans world_items)
    "say",                      -- {action, text}
    "idle",                     -- {action}
}

-- ---------------------------------------------------------------
-- Serialisation JSON minimale (pas de dependance externe)
-- Supporte : string, number, boolean, nil, table (array et dict)
-- ---------------------------------------------------------------
local function serializeValue(v, depth)
    depth = depth or 0
    if depth > 10 then return '"<deep>"' end
    local t = type(v)
    if t == "nil"     then return "null"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number"  then
        if v ~= v then return "null" end  -- NaN
        return tostring(v)
    elseif t == "string"  then
        -- Echapper les caracteres speciaux
        v = v:gsub('\\', '\\\\')
               :gsub('"',  '\\"')
               :gsub('\n', '\\n')
               :gsub('\r', '\\r')
               :gsub('\t', '\\t')
        return '"' .. v .. '"'
    elseif t == "table" then
        -- Detecter si c'est un array (cles numeriques consecutives)
        local isArray = true
        local maxN = 0
        for k, _ in pairs(v) do
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
                isArray = false; break
            end
            if k > maxN then maxN = k end
        end
        if isArray and maxN == #v then
            local parts = {}
            for i = 1, #v do
                parts[i] = serializeValue(v[i], depth + 1)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, val in pairs(v) do
                if type(k) == "string" or type(k) == "number" then
                    table.insert(parts,
                        serializeValue(tostring(k), depth + 1)
                        .. ":" ..
                        serializeValue(val, depth + 1))
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return '"<unsupported:' .. t .. '>"'
end

-- Parser JSON minimaliste (suffisant pour les commandes simples du bridge)
-- Supporte les objets plats {key: value} - pas de tableaux imbriques profonds
local function parseJSON(s)
    if not s or s == "" then return nil end
    s = s:match("^%s*(.-)%s*$")  -- trim

    -- Objet
    if s:sub(1,1) == "{" then
        local result = {}
        local inner = s:match("^{(.*)}$")
        if not inner then return nil end
        -- Parser cle:valeur simplement
        for key, val in inner:gmatch('"([^"]+)"%s*:%s*("?[^,"}]+"?)') do
            -- Enlever les guillemets des valeurs string
            if val:sub(1,1) == '"' then
                result[key] = val:match('^"(.*)"$')
            elseif val == "true"  then result[key] = true
            elseif val == "false" then result[key] = false
            elseif val == "null"  then result[key] = nil
            else
                result[key] = tonumber(val) or val
            end
        end
        return result
    end
    return nil
end

LLMBot.toJSON   = serializeValue
LLMBot.fromJSON = parseJSON

print("[LLMBot] Shared module loaded v" .. LLMBot.VERSION)
