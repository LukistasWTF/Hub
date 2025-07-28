--!nonstrict
-- AutoMinigames – Smart ETA + TP + FULL AutoPlay (v6)
-- Solo prints (sin UI). Pega este archivo como LocalScript en StarterPlayerScripts.

local ok_boot, boot_err = pcall(function()

    ------------------------------ Servicios ------------------------------
    local Players     = game:GetService("Players")
    local RS          = game:GetService("ReplicatedStorage")
    local RunService  = game:GetService("RunService")

    if not RunService:IsClient() then warn("[AutoMG] SOLO cliente (LocalScript)."); return end
    local LP = Players.LocalPlayer
    if not LP then return end

    ------------------------------ Helpers básicos ------------------------------
    local function isFn(x) return type(x)=="function" end
    local function isMS(x) return typeof(x)=="Instance" and x:IsA("ModuleScript") end
    local function srequire(ms) if not isMS(ms) then return nil end local ok,m=pcall(function() return require(ms) end); return ok and m or nil end

    local function loadM(name)
        -- Fsys.load primero
        local Fsys = srequire(RS:FindFirstChild("Fsys"))
        local FSYS_LOAD = Fsys and type(Fsys.load)=="function" and Fsys.load or nil
        if FSYS_LOAD then local ok,mod=pcall(function() return FSYS_LOAD(name) end); if ok and mod then return mod end end
        -- Búsqueda plana
        for _,root in ipairs({"ClientModules","SharedModules"}) do
            local f = RS:FindFirstChild(root, true)
            if f then local m=f:FindFirstChild(name, true); local got=srequire(m); if got then return got end end
        end
        return nil
    end

    ------------------------------ Módulos opcionales ------------------------------
    local LiveOpsTime           = loadM("LiveOpsTime") or { now=function() return os.clock() end }
    local MinigameClientManager = nil  -- refrescamos dinámicamente
    local ClientData            = nil

    ------------------------------ Config ------------------------------
    local CONFIG = {
        autoEnabled = true,
        statusRefresh = 1.0,          -- s, frecuencia de revisión de estado/ETA
        defaultQueueCountdown = 12,   -- ETA defecto si no hay señales
        inProgressGrace = 5,          -- margen cuando está en marcha (s)

        -- Coordenadas de colas (ajústalas a tu mapa)
        coords = {
            joetation    = Vector3.new(-590.8, 35.8, -1667.1),
            coconut_bonk = Vector3.new(-600.3, 41.6, -1610.3),
        },

        -- No mandamos "join_queue" explícito (el juego mete por zona)
        sendJoinMessageAfterTP = false,

        -- Cadencia de acciones (adaptativa)
        actionCadence = { joetation = 0.85, coconut_bonk = 0.80 },
        minCadence = 0.50, maxCadence = 2.0, stepDown = 0.06, stepUp = 0.10,

        -- “Visión completa”: fuerza intentos a TODOS los objetivos
        joetation = {
            triesPerAct = 4,          -- cuántos cañones intentar por tick
            fallbackMaxIdx = 12,      -- si no hay lista de cañones del cliente
        },
        coconut = {
            pilesToCycle = 4,         -- intentamos recoger de 1..N (round‑robin)
            usesPerAct   = 4,         -- cuántos objetivos probar por tick
        },

        enableAFK = true,
        verboseRPC = true,            -- log de cada RPC fallida
    }

    ------------------------------ Utils ------------------------------
    local function nowS() return LiveOpsTime.now() end
    local function srvNow() if isFn(workspace.GetServerTimeNow) then return workspace:GetServerTimeNow() end return nowS() end
    local function hrp() local c=LP.Character; return c and c:FindFirstChild("HumanoidRootPart") end
    local function humanoid() local c=LP.Character; return c and c:FindFirstChildWhichIsA("Humanoid") end
    local function ts() local t=os.date("*t"); return string.format("%02d:%02d:%02d",t.hour,t.min,t.sec) end
    local function loglvl(lvl, ...) print(("[AutoMG %s][%s] "):format(ts(), lvl), ...) end
    local function log(...) loglvl("INFO", ...) end
    local function warnl(...) loglvl("WARN", ...) end
    local function fmtTime(s) s=math.max(0, math.floor(s)); return string.format("%02d:%02d", math.floor(s/60), s%60) end

    local function refreshModules()
        if not MinigameClientManager then MinigameClientManager = loadM("MinigameClientManager") end
        if not ClientData then ClientData = loadM("ClientData") end
    end

    ------------------------------ Teleport seguro ------------------------------
    local function getRoot()
        local char = LP.Character or LP.CharacterAdded:Wait()
        return char:WaitForChild("HumanoidRootPart"), char:WaitForChild("Humanoid")
    end

    local function tpTo(v3)
        if typeof(v3)~="Vector3" then return end
        local root,hum = getRoot(); if not root or not hum then return end

        if workspace.StreamingEnabled and isFn(LP.RequestStreamAroundAsync) then
            pcall(function() LP:RequestStreamAroundAsync(v3, 128) end)
        end

        local oldState; pcall(function() oldState=hum:GetState(); hum:ChangeState(Enum.HumanoidStateType.Physics) end)
        local look = (root.CFrame * CFrame.new(0,0,-1)).Position
        root.CFrame = CFrame.new(v3 + Vector3.new(0,3,0), look)
        task.delay(0.12, function() if hum and hum.Parent then pcall(function() if oldState then hum:ChangeState(oldState) end end) end)
    end

    ------------------------------ Estado / ETA ------------------------------
    local function getClient(id)
        refreshModules()
        if not MinigameClientManager or not isFn(MinigameClientManager.get) then return nil end
        local ok,cli = pcall(function() return MinigameClientManager.get(id) end)
        return ok and cli or nil
    end

    local function readStatus(cli)
        local st = { active=false, loading=false, inQueue=false, timeLeft=nil, raw=nil }
        local ms = cli and cli.minigame_state
        local now = srvNow()

        if ms then
            local get = (type(ms.get)=="function") and function(k) local ok,v=pcall(function() return ms:get(k) end); return ok and v or nil end or function() return nil end
            st.active  = get("is_game_active") or false
            st.loading = get("players_loading") or false

            if type(ms.get_as_table)=="function" then
                local t; pcall(function() t = ms:get_as_table("queued_user_ids") end)
                if type(t)=="table" then for _,uid in ipairs(t) do if uid==LP.UserId then st.inQueue=true break end end end
            end

            local zts = get("zone_override_timestamp")
            if typeof(zts)=="number" and zts>0 then st.timeLeft = math.max(0, math.floor(zts - now)); st.raw="zone_override_timestamp" end
        end

        if cli and cli.is_participating and cli.end_time then
            st.active=true; st.timeLeft=math.max(0, math.floor(cli.end_time - now)); st.raw=st.raw or "client.end_time"
        end

        if (not st.timeLeft) and ClientData and cli and cli.cycle_timestamp_key and isFn(ClientData.get) then
            pcall(function()
                local rec = ClientData.get(cli.cycle_timestamp_key)
                local ts = rec and (rec.timestamp or rec.t or rec.next_timestamp)
                if ts then st.timeLeft = math.max(0, math.floor(ts - now)); st.raw="ClientData.cycle_timestamp" end
            end)
        end
        return st
    end

    local function etaToStart(cli, st)
        if st.active then return (st.timeLeft or CONFIG.defaultQueueCountdown)+CONFIG.inProgressGrace, false, st.raw end
        if st.loading then return 5, true, "players_loading" end
        if st.timeLeft and st.timeLeft>0 then return st.timeLeft, true, st.raw end
        return CONFIG.defaultQueueCountdown, true, "fallback"
    end

    local function statusAndEta(id)
        local cli = getClient(id); if not cli then return nil end
        local st = readStatus(cli)
        local eta, joinable, raw = etaToStart(cli, st)
        return { id=id, cli=cli, st=st, eta=eta, joinable=joinable, raw=raw }
    end

    local ORDER = { "joetation", "coconut_bonk" }
    local function pickBest()
        local best, bestEta
        for _,id in ipairs(ORDER) do
            local r = statusAndEta(id)
            if r then
                log(string.format("[ETA] %-13s → %s (%s)  active=%s inQueue=%s",
                    id, fmtTime(r.eta), r.raw or "fallback", tostring(r.st.active), tostring(r.st.inQueue)))
                if r.eta < (bestEta or math.huge) then best, bestEta = id, r.eta end
            else
                warnl(string.format("[ETA] %-13s → sin datos (cliente no disponible)", id))
            end
        end
        return best or "joetation"
    end

    ------------------------------ Auto‑play (FULL cobertura) ------------------------------
    local dynCad, lastAct = {}, {}
    for k,v in pairs(CONFIG.actionCadence) do dynCad[k]=v end
    local function canAct(id)
        local cad = dynCad[id] or 1.0
        local t = nowS()
        if not lastAct[id] or (t-lastAct[id])>=cad then lastAct[id]=t; return true end
        return false
    end
    local function tuneCad(id, ok)
        local cad = dynCad[id] or 1.0
        if ok then cad = math.max(CONFIG.minCadence, cad - CONFIG.stepDown)
        else cad = math.min(CONFIG.maxCadence, cad + CONFIG.stepUp) end
        dynCad[id]=cad
        log(string.format("[Cadencia] %-13s -> %.2fs (ok=%s)", id, cad, tostring(ok)))
    end
    local function rpc(cli, route, ...)
        if not cli or not isFn(cli.message_server) then return false end
        local ok, err = pcall(function() return cli:message_server(route, ...) end)
        if not ok and CONFIG.verboseRPC then warnl("[RPC FAIL]", route, err) end
        return ok
    end

    -- Round‑robin helpers
    local cannonCursor = 1
    local function cannonList(cli)
        -- Si el cliente expone posiciones/índices, úsalo. Si no, 1..fallbackMaxIdx
        local arr = {}
        local okList, cannons = pcall(function() return cli.cannons_world end)
        if okList and type(cannons)=="table" and #cannons>0 then
            for i=1,#cannons do arr[#arr+1]=i end
        else
            for i=1,CONFIG.joetation.fallbackMaxIdx do arr[#arr+1]=i end
        end
        return arr
    end

    local pileIdx = 1
    local shipCursor = 1
    local function shipUidList(cli)
        local arr = {}
        local okMap, ships = pcall(function() return cli.ships_by_uid end)
        if okMap and type(ships)=="table" then
            for uid,_ in pairs(ships) do arr[#arr+1]=uid end
        end
        return arr
    end

    -- JOETATION: recoger SIEMPRE y disparar a TODOS (round‑robin, múltiples intentos por tick)
    local function act_joetation(cli)
        if not canAct("joetation") then return end
        local root = hrp(); local pos = root and root.Position or Vector3.new()

        rpc(cli, "pickup_holdable_from_pile", pos, nowS())

        local list = cannonList(cli)
        if #list==0 then warnl("[joetation] No hay lista de cañones. Intento idx=1..N por defecto."); list = {1,2,3,4,5,6,7,8,9,10,11,12} end

        local okAny=false
        for n=1,CONFIG.joetation.triesPerAct do
            local idx = list[cannonCursor]
            cannonCursor = (cannonCursor % #list) + 1
            local ok = rpc(cli, "use_cannon", idx, pos, nowS())
            log(string.format("[joetation] intento %d/%d -> cannon=%d, ok=%s", n, CONFIG.joetation.triesPerAct, idx, tostring(ok)))
            okAny = okAny or ok
        end
        tuneCad("joetation", okAny)
    end

    -- COCONUT BONK: recoger SIEMPRE (rotando pilas) y usar contra TODOS los barcos (round‑robin, múltiples por tick)
    local function act_coconut(cli)
        if not canAct("coconut_bonk") then return end

        -- recoger (rotamos pilas 1..N)
        rpc(cli, "pickup_droppable", pileIdx)
        log(string.format("[coconut] pickup_droppable pile=%d", pileIdx))
        pileIdx = (pileIdx % CONFIG.coconut.pilesToCycle) + 1

        local uids = shipUidList(cli)
        if #uids==0 then
            warnl("[coconut] No hay ships_by_uid visibles todavía; reintento pronto.")
            tuneCad("coconut_bonk", false)
            return
        end

        local okAny=false
        for n=1,CONFIG.coconut.usesPerAct do
            if shipCursor>#uids then shipCursor=1 end
            local uid = uids[shipCursor]
            shipCursor = shipCursor + 1
            local ok = rpc(cli, "used_droppable", uid)
            log(string.format("[coconut] intento %d/%d -> uid=%s, ok=%s", n, CONFIG.coconut.usesPerAct, tostring(uid), tostring(ok)))
            okAny = okAny or ok
        end
        tuneCad("coconut_bonk", okAny)
    end

    ------------------------------ Anti‑AFK ------------------------------
    if CONFIG.enableAFK then
        LP.Idled:Connect(function()
            local vu = game:GetService("VirtualUser")
            vu:CaptureController(); vu:ClickButton2(Vector2.new())
        end)
    end

    ------------------------------ Bucle principal ------------------------------
    task.spawn(function()
        log("AutoMG v6 listo. AUTO =", CONFIG.autoEnabled and "ON" or "OFF")
        local currentPlaying -- "joetation" | "coconut_bonk" | nil

        while true do
            if CONFIG.autoEnabled then
                -- ¿Participando en alguno?
                local anyPlaying, playingId = false, nil
                for _, id in ipairs(ORDER) do
                    local r = statusAndEta(id)
                    if r and r.cli and r.cli.is_participating then anyPlaying=true; playingId=id end
                end

                if not anyPlaying then
                    -- Elegimos la mejor cola por ETA y TP
                    local best = pickBest()
                    if currentPlaying ~= nil then log("[Estado] Juego anterior terminó.") end
                    currentPlaying = nil

                    local v3 = CONFIG.coords[best] or CONFIG.coords.joetation
                    log(string.format("[TP] → %-13s @ (%.1f, %.1f, %.1f)", best, v3.X, v3.Y, v3.Z))
                    tpTo(v3)

                    if CONFIG.sendJoinMessageAfterTP then
                        local r = statusAndEta(best)
                        if r and r.cli then pcall(function() r.cli:message_server("join_queue") end) end
                    end

                    task.wait(2)
                else
                    -- Estamos dentro: solo jugar; NO salimos hasta que termine
                    if currentPlaying ~= playingId then
                        currentPlaying = playingId
                        log(string.format("[Juego] Entraste a %s. Autoplay FULL (todos los objetivos).", currentPlaying))
                        -- Reinicia cursores por nueva partida
                        cannonCursor, shipCursor, pileIdx = 1, 1, 1
                    end

                    local r = statusAndEta(currentPlaying)
                    if r and r.cli and r.cli.is_participating then
                        if currentPlaying=="joetation" then act_joetation(r.cli) else act_coconut(r.cli) end
                    end

                    task.wait(0.1) -- tick rápido de juego
                end

            else
                task.wait(0.25)
            end

            task.wait(CONFIG.statusRefresh)
        end
    end)

end)

if not ok_boot then
    warn("[AutoMG] Error al iniciar: ", boot_err)
end
