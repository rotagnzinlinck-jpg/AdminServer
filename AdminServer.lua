-- AdminServer.lua
-- Colocar em ServerScriptService
-- Script de administrador completo com persistência (DataStore)
-- Configurações iniciais:
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local DATASTORE_NAME = "AdminScriptData_v1"
local DATA_KEY = "global" -- único key para armazenar tudo
local COMMAND_PREFIX = ":" -- prefixo dos comandos no chat

-- Nomes iniciais autorizados (conforme seu pedido)
local initialAdminNames = {
    "enzorepefadenati",
    "aoaioappp",
}

-- Ferramentas disponíveis para "give" devem existir em ServerStorage/tools OU ReplicatedStorage/tools
local TOOL_FOLDER_PATHS = {
    ServerStorage:FindFirstChild("tools"),
    ReplicatedStorage:FindFirstChild("tools"),
}

-- Dados em memória (serão carregados / salvos no DataStore)
local data = {
    admins = {},   -- [userId] = true
    bans = {},     -- [userId] = { reason = string, expires = timestamp or nil } expires = os.time() + seconds
    muted = {},    -- [userId] = true (não persistido - sessão)
}

local function safePcall(fn, ...)
    local ok, res = pcall(fn, ...)
    return ok, res
end

-- DataStore helpers
local store = DataStoreService:GetDataStore(DATASTORE_NAME)

local function loadData()
    local ok, stored = pcall(function() return store:GetAsync(DATA_KEY) end)
    if ok and type(stored) == "table" then
        -- merge stored data into data
        if type(stored.admins) == "table" then
            for k,v in pairs(stored.admins) do data.admins[tonumber(k) or k] = v end
        end
        if type(stored.bans) == "table" then
            for k,v in pairs(stored.bans) do data.bans[tonumber(k) or k] = v end
        end
    else
        if not ok then
            warn("AdminServer: falha ao carregar DataStore:", stored)
        end
    end
end

local function saveData()
    -- we store only admins and bans (muted not persisted)
    local payload = {
        admins = {},
        bans = {},
    }
    for k,v in pairs(data.admins) do payload.admins[tostring(k)] = v end
    for k,v in pairs(data.bans) do payload.bans[tostring(k)] = v end

    local ok, err = pcall(function()
        store:SetAsync(DATA_KEY, payload)
    end)
    if not ok then
        warn("AdminServer: falha ao salvar DataStore:", err)
    end
end

-- Inicializa admins a partir dos nomes iniciais (converte para userIds quando possível)
local function initAdminsFromNames(names)
    for _, name in ipairs(names) do
        local ok, id = pcall(function() return Players:GetUserIdFromNameAsync(name) end)
        if ok and type(id) == "number" then
            data.admins[id] = true
            print("Admin adicionado (por nome):", name, id)
        else
            -- se não conseguimos converter, tentamos manter nome-mapping temporário:
            -- como DataStore guarda por userId (número), se não existir userId não persistiremos.
            warn(("Não foi possível obter UserId para '%s'. Só funcionará enquanto o jogador usar exatamente esse nome e estiver online."):format(name))
        end
    end
    saveData()
end

-- Verifica se player é admin (UserId primeiro; fallback por nome)
local function isAdmin(player)
    if not player then return false end
    if data.admins[player.UserId] then return true end
    -- fallback por nome (somente para casos não convertidos)
    for k,_ in pairs(data.admins) do
        -- nothing, primary is numeric; fallback handled by initial names below
    end
    -- scan initialAdminNames as last-resort fallback
    for _, n in ipairs(initialAdminNames) do
        if string.lower(player.Name) == string.lower(n) then
            return true
        end
    end
    return false
end

-- Ban check
local function isBanned(userId)
    local entry = data.bans[userId]
    if not entry then return false end
    if entry.expires == nil then
        return true -- permanent ban
    end
    if os.time() < entry.expires then
        return true
    else
        -- ban expirou; remover
        data.bans[userId] = nil
        saveData()
        return false
    end
end

-- encontra jogador por nome (case-insensitive, exato primeiro, depois parcial)
local function findPlayerByName(query)
    if not query or query == "" then return nil end
    query = string.lower(query)
    for _, p in ipairs(Players:GetPlayers()) do
        if string.lower(p.Name) == query then return p end
    end
    for _, p in ipairs(Players:GetPlayers()) do
        if string.find(string.lower(p.Name), query, 1, true) then return p end
    end
    return nil
end

local function getRootPart(character)
    if not character then return nil end
    return character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")
end

-- Utilities para afetar personagem
local function setAnchoredForPlayer(player, anchored)
    if not player or not player.Character then return end
    local root = getRootPart(player.Character)
    if root then
        root.Anchored = anchored
    end
end

local function giveToolToPlayer(player, toolName)
    if not player then return false, "player nil" end
    if not toolName or toolName == "" then return false, "nome da ferramenta vazio" end
    -- procurar em TOOL_FOLDER_PATHS
    for _, folder in ipairs(TOOL_FOLDER_PATHS) do
        if folder and folder:IsA("Instance") then
            local t = folder:FindFirstChild(toolName)
            if t and t:IsA("Tool") then
                local clone = t:Clone()
                clone.Parent = player:FindFirstChild("Backpack") or player:WaitForChild("Backpack")
                return true
            end
        end
    end
    return false, ("Ferramenta '%s' não encontrada em ServerStorage/ReplicatedStorage tools"):format(toolName)
end

local function removeAllTools(player)
    if not player then return end
    local backpack = player:FindFirstChild("Backpack")
    if backpack then
        for _, item in ipairs(backpack:GetChildren()) do
            if item:IsA("Tool") then item:Destroy() end
        end
    end
    if player.Character then
        for _, item in ipairs(player.Character:GetChildren()) do
            if item:IsA("Tool") then item:Destroy() end
        end
    end
end

-- Comandos map (string -> função(player, args...))
local commandDescriptions = {
    help = ":help - Mostra esta lista de comandos",
    kick = ":kick <player> [motivo]",
    ban = ":ban <player> [motivo]  (ban temporário na sessão)",
    permaban = ":permaban <player> [motivo]  (ban persistente)",
    tempban = ":tempban <player> <minutes> [motivo]",
    unban = ":unban <playerNameOrUserId>",
    mute = ":mute <player>",
    unmute = ":unmute <player>",
    freeze = ":freeze <player>",
    unfreeze = ":unfreeze <player>",
    kill = ":kill <player>",
    respawn = ":respawn <player>",
    tp = ":tp <playerFrom> <playerTo>",
    goto = ":goto <player>",
    bring = ":bring <player>",
    teleportall = ":teleportall <player>",
    setspeed = ":setspeed <player> <walkSpeed>",
    setjump = ":setjump <player> <jumpPower>",
    give = ":give <player> <toolName>",
    removegear = ":removegear <player>",
    god = ":god <player>",
    ungod = ":ungod <player>",
    addadmin = ":addadmin <playerNameOrUserId>",
    removeadmin = ":removeadmin <playerNameOrUserId>",
    listadmins = ":listadmins",
}

local function sendFeedback(player, msg)
    -- envia mensagem no console do servidor; se quiser, pode enviar via RemoteEvent a GUIs clientes
    print(("[Admin][%s]: %s"):format(player and player.Name or "System", msg))
end

local function executeCommand(invoker, cmd, args)
    cmd = string.lower(cmd)
    if cmd == "help" then
        sendFeedback(invoker, "Comandos disponíveis:")
        for _, v in pairs(commandDescriptions) do sendFeedback(invoker, v) end

    elseif cmd == "kick" then
        local targetName = args[1]; table.remove(args,1)
        if not targetName then return end
        local target = findPlayerByName(targetName)
        if target then
            local reason = table.concat(args, " ")
            target:Kick(reason ~= "" and reason or ("Kicked by " .. invoker.Name))
            sendFeedback(invoker, ("Kick executado em %s"):format(target.Name))
        end

    elseif cmd == "ban" then
        local targetName = args[1]; table.remove(args,1)
        if not targetName then return end
        local target = findPlayerByName(targetName)
        if target then
            local reason = table.concat(args, " ")
            data.bans[target.UserId] = { reason = reason ~= "" and reason or ("Banido por " .. invoker.Name), expires = nil } -- ban por sessão (persistimos se permaban)
            saveData()
            target:Kick("Você foi banido: " .. (reason ~= "" and reason or "Sem motivo dado"))
            sendFeedback(invoker, ("Ban aplicado (sessão) em %s"):format(target.Name))
        end

    elseif cmd == "permaban" then
        local targetName = args[1]; table.remove(args,1)
        if not targetName then return end
        local ok, id = pcall(function() return tonumber(targetName) or Players:GetUserIdFromNameAsync(targetName) end)
        local userId = ok and id or nil
        if userId then
            local reason = table.concat(args, " ")
            data.bans[userId] = { reason = reason ~= "" and reason or ("Permaban por " .. invoker.Name), expires = nil }
            saveData()
            -- kick if online
            local p = Players:GetPlayerByUserId(userId)
            if p then p:Kick("Você foi permanentemente banido: " .. (reason ~= "" and reason or "Sem motivo")) end
            sendFeedback(invoker, ("Permaban aplicado em %s (UserId %s)"):format(targetName, tostring(userId)))
        else
            sendFeedback(invoker, "Usuário não encontrado para permaban.")
        end

    elseif cmd == "tempban" then
        local targetName = args[1]; local minutes = tonumber(args[2])
        if not targetName or not minutes then
            sendFeedback(invoker, "Uso: :tempban <player> <minutes> [motivo]")
            return
        end
        table.remove(args,1); table.remove(args,1)
        local reason = table.concat(args, " ")
        local target = findPlayerByName(targetName)
        if target then
            local expires = os.time() + (minutes * 60)
            data.bans[target.UserId] = { reason = reason ~= "" and reason or ("Tempban por " .. invoker.Name), expires = expires }
            saveData()
            target:Kick("Você foi banido por " .. tostring(minutes) .. " minutos. Motivo: " .. (reason ~= "" and reason or "Sem motivo"))
            sendFeedback(invoker, ("Tempban de %s minutos aplicado em %s"):format(tostring(minutes), target.Name))
        else
            sendFeedback(invoker, "Jogador não encontrado.")
        end

    elseif cmd == "unban" then
        local arg = args[1]
        if not arg then return end
        local ok, id = pcall(function() return tonumber(arg) or Players:GetUserIdFromNameAsync(arg) end)
        local userId = ok and id or nil
        if userId and data.bans[userId] then
            data.bans[userId] = nil
            saveData()
            sendFeedback(invoker, ("Unban aplicado em UserId %s"):format(tostring(userId)))
        else
            sendFeedback(invoker, "Unban falhou: usuário não está banido ou não foi encontrado.")
        end

    elseif cmd == "mute" then
        local targetName = args[1]
        if not targetName then return end
        local target = findPlayerByName(targetName)
        if target then
            data.muted[target.UserId] = true
            sendFeedback(invoker, "Muted " .. target.Name)
        end

    elseif cmd == "unmute" then
        local targetName = args[1]
        if not targetName then return end
        local target = findPlayerByName(targetName)
        if target then
            data.muted[target.UserId] = nil
            sendFeedback(invoker, "Unmuted " .. target.Name)
        end

    elseif cmd == "freeze" then
        local targetName = args[1]; if not targetName then return end
        local target = findPlayerByName(targetName)
        if target then setAnchoredForPlayer(target, true); sendFeedback(invoker, "Freeze em " .. target.Name) end

    elseif cmd == "unfreeze" then
        local targetName = args[1]; if not targetName then return end
        local target = findPlayerByName(targetName)
        if target then setAnchoredForPlayer(target, false); sendFeedback(invoker, "Unfreeze em " .. target.Name) end

    elseif cmd == "kill" then
        local targetName = args[1]; if not targetName then return end
        local target = findPlayerByName(targetName)
        if target and target.Character then
            local h = target.Character:FindFirstChildOfClass("Humanoid")
            if h then h.Health = 0; sendFeedback(invoker, "Kill em " .. target.Name) end
        end

    elseif cmd == "respawn" then
        local targetName = args[1]; if not targetName then return end
        local target = findPlayerByName(targetName)
        if target then
            if target.Character then
                local h = target.Character:FindFirstChildOfClass("Humanoid")
                if h then h.Health = 0 end
            end
            sendFeedback(invoker, "Respawn solicitado para " .. target.Name)
        end

    elseif cmd == "tp" then
        local p1 = args[1]; local p2 = args[2]
        if not p1 or not p2 then return end
        local from = findPlayerByName(p1); local to = findPlayerByName(p2)
        if from and to and from.Character and to.Character then
            local rFrom = getRootPart(from.Character); local rTo = getRootPart(to.Character)
            if rFrom and rTo then rFrom.CFrame = rTo.CFrame; sendFeedback(invoker, ("%s teleportado para %s"):format(from.Name, to.Name)) end
        end

    elseif cmd == "goto" then
        local targetName = args[1]; if not targetName then return end
        local target = findPlayerByName(targetName)
        if target and target.Character and invoker and invoker.Character then
            local rTarget = getRootPart(target.Character); local rInvoker = getRootPart(invoker.Character)
            if rTarget and rInvoker then rInvoker.CFrame = rTarget.CFrame; sendFeedback(invoker, "Você foi teleportado para " .. target.Name) end
        end

    elseif cmd == "bring" then
        local targetName = args[1]; if not targetName then return end
        local target = findPlayerByName(targetName)
        if target and target.Character and invoker and invoker.Character then
            local rTarget = getRootPart(target.Character); local rInvoker = getRootPart(invoker.Character)
            if rTarget and rInvoker then rTarget.CFrame = rInvoker.CFrame * CFrame.new(0,0,3); sendFeedback(invoker, target.Name .. " trazido até você") end
        end

    elseif cmd == "teleportall" then
        local targetName = args[1]; if not targetName then return end
        local target = findPlayerByName(targetName)
        if target and target.Character then
            local rTarget = getRootPart(target.Character)
            if rTarget then
                for _, p in ipairs(Players:GetPlayers()) do
                    if p.Character and p ~= target then
                        local r = getRootPart(p.Character)
                        if r then r.CFrame = rTarget.CFrame * CFrame.new(math.random(-5,5),0,math.random(-5,5)) end
                    end
                end
                sendFeedback(invoker, "TeleportAll para " .. target.Name)
            end
        end

    elseif cmd == "setspeed" then
        local targetName = args[1]; local speed = tonumber(args[2])
        if not targetName or not speed then sendFeedback(invoker, "Uso: :setspeed <player> <walkSpeed>") return end
        local target = findPlayerByName(targetName)
        if target and target.Character then
            local hum = target.Character:FindFirstChildOfClass("Humanoid")
            if hum then hum.WalkSpeed = speed; sendFeedback(invoker, ("WalkSpeed de %s = %s"):format(target.Name, tostring(speed))) end
        end

    elseif cmd == "setjump" then
        local targetName = args[1]; local jp = tonumber(args[2])
        if not targetName or not jp then sendFeedback(invoker, "Uso: :setjump <player> <jumpPower>") return end
        local target = findPlayerByName(targetName)
        if target and target.Character then
            local hum = target.Character:FindFirstChildOfClass("Humanoid")
            if hum then hum.JumpPower = jp; sendFeedback(invoker, ("JumpPower de %s = %s"):format(target.Name, tostring(jp))) end
        end

    elseif cmd == "give" then
        local targetName = args[1]; local tool = args[2]
        if not targetName or not tool then sendFeedback(invoker, "Uso: :give <player> <toolName>") return end
        local target = findPlayerByName(targetName)
        if target then
            local ok, err = giveToolToPlayer(target, tool)
            if ok then sendFeedback(invoker, ("Dado %s para %s"):format(tool, target.Name)) else sendFeedback(invoker, "Erro give: "..tostring(err)) end
        end

    elseif cmd == "removegear" then
        local targetName = args[1]; if not targetName then return end
        local target = findPlayerByName(targetName)
        if target then removeAllTools(target); sendFeedback(invoker, "Ferramentas removidas de " .. target.Name) end

    elseif cmd == "god" then
        local targetName = args[1]; if not targetName then return end
        local target = findPlayerByName(targetName)
        if target and target.Character then
            if not target.Character:FindFirstChildOfClass("ForceField") then
                local ff = Instance.new("ForceField")
                ff.Parent = target.Character
            end
            sendFeedback(invoker, target.Name .. " está em modo god (ForceField)")
        end

    elseif cmd == "ungod" then
        local targetName = args[1]; if not targetName then return end
        local target = findPlayerByName(targetName)
        if target and target.Character then
            for _, c in ipairs(target.Character:GetChildren()) do
                if c:IsA("ForceField") then c:Destroy() end
            end
            sendFeedback(invoker, target.Name .. " ungod")
        end

    elseif cmd == "addadmin" then
        local who = args[1]; if not who then return end
        local ok, id = pcall(function() return tonumber(who) or Players:GetUserIdFromNameAsync(who) end)
        local userId = ok and id or nil
        if userId then
            data.admins[userId] = true
            saveData()
            sendFeedback(invoker, ("Admin adicionado: UserId %s"):format(tostring(userId)))
        else
            sendFeedback(invoker, "Não foi possível adicionar admin (usuário não encontrado).")
        end

    elseif cmd == "removeadmin" then
        local who = args[1]; if not who then return end
        local ok, id = pcall(function() return tonumber(who) or Players:GetUserIdFromNameAsync(who) end)
        local userId = ok and id or nil
        if userId and data.admins[userId] then
            data.admins[userId] = nil
            saveData()
            sendFeedback(invoker, ("Admin removido: UserId %s"):format(tostring(userId)))
        else
            sendFeedback(invoker, "RemoveAdmin falhou: usuário não é admin ou não encontrado.")
        end

    elseif cmd == "listadmins" then
        sendFeedback(invoker, "Admins salvos (UserIds):")
        for id,_ in pairs(data.admins) do
            sendFeedback(invoker, tostring(id))
        end

    else
        sendFeedback(invoker, "Comando desconhecido: " .. tostring(cmd))
    end
end

-- Processa string de comando e executa
local function processChatCommand(player, msg)
    if type(msg) ~= "string" then return end
    if string.sub(msg,1,#COMMAND_PREFIX) ~= COMMAND_PREFIX then return end
    if not isAdmin(player) then return end

    local raw = string.sub(msg, #COMMAND_PREFIX + 1)
    local parts = string.split(raw, " ")
    if #parts == 0 then return end
    local cmd = parts[1]
    table.remove(parts,1)
    executeCommand(player, cmd, parts)
end

-- Hook para bloquear chat de jogadores mutados (Player.Chatted)
local function onPlayerChatted(player, msg)
    if data.muted[player.UserId] then
        -- ignore chat (não faz nada)
        return
    end
    -- se for comando, processa
    processChatCommand(player, msg)
end

-- Ao jogador entrar
Players.PlayerAdded:Connect(function(player)
    -- checar ban
    if isBanned(player.UserId) then
        local entry = data.bans[player.UserId]
        local reason = entry and entry.reason or "Banido"
        player:Kick("Você está banido: " .. reason)
        return
    end

    -- conectar chat
    player.Chatted:Connect(function(msg) onPlayerChatted(player, msg) end)

    -- restaurar estado god/freeze etc se desejar (não persistimos frozen/muted)
    -- nada para restaurar aqui por padrão
end)

Players.PlayerRemoving:Connect(function(player)
    -- nada especial
end)

-- inicialização
loadData()
initAdminsFromNames(initialAdminNames)

print("AdminServer carregado. Prefixo de comando:", COMMAND_PREFIX)
print("Comandos disponíveis: use :help para ver a lista em console.")
