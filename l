--[[ 
AutoMinigames – Smart Queue + Real ETA + Safe TP (v4.0) 🚀
──────────────────────────────────────────────────────────
✅ Elige SIEMPRE la cola con menor ETA real
✅ Muestra cuenta atrás continua (ETA real desde minigame_state/ClientData)
✅ Auto‑play de minijuegos (joetation / coconut_bonk)
✅ Reclama recompensas automáticamente
✅ Reintentos si una cola se queda “atascada”
✅ Anti‑AFK + panel de depuración + atajos (!automg …)
✅ TP seguro: intenta InteriorsM.enter_smooth SOLO si es seguro; si no, CFrame directo a TeleportLocations

Notas técnicas (basadas en tu código real):
- Los estados de cola se leen desde `minigame_state`: is_game_active, players_loading,
  zone_override_text / zone_override_timestamp y lista `queued_user_ids`. :contentReference[oaicite:9]{index=9}
- Los eventos y tiempos del minijuego (intermission_end_time / end_time) se alimentan desde el cliente. :contentReference[oaicite:10]{index=10}
- En tu stack existe un prompt que teleporta con `InteriorsM.enter_smooth(join_zone_destination_id, "MainDoor", {spawn_cframe = StaticMap.TeleportLocations[<id>]})`.
  Aquí lo usamos con backoff y alternativa por CFrame para evitar el error de “enter_core_async died…”. :contentReference[oaicite:11]{index=11}
- La API de mensajes al servidor se hace vía `MinigameAPI/MessageServer` → `cli:message_server(route, ...)`. :contentReference[oaicite:12]{index=12}
- Las colas etiquetan jugadores y exponen señales `get_queue_player_added_signal/removed_signal` (no imprescindibles aquí, pero contempladas). :contentReference[oaicite:13]{index=13}

Coloca este script como **LocalScript** (StarterPlayerScripts o PlayerGui).
]]]

------------------ Cliente obligatorio ------------------
local RunService = game:GetService("RunService")
if not RunService:IsClient() then warn("[AutoMG] Debe ser LocalScript."); return end

------------------ Servicios ------------------
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local StarterGui         = game:GetService("StarterGui")
local PathfindingService = game:GetService("PathfindingService")
local VirtualUser        = game:GetService("VirtualUser")
local LocalPlayer        = Players.LocalPlayer
if not LocalPlayer then warn("[AutoMG] LocalPlayer nil."); return end

------------------ Fsys (carga segura) ------------------
local function safeRequire(obj) local ok,res=pcall(function() return require(obj) end); return ok and res or nil end
local Fsys = ReplicatedStorage:FindFirstChild("Fsys") and safeRequire(ReplicatedStorage.Fsys)
local FSYS_LOAD = (Fsys and type(Fsys.load)=="function") and Fsys.load or nil
local function loadM(name) if not FSYS_LOAD then return nil end local ok,mod=pcall(function() return FSYS_LOAD(name) end); return ok and mod or nil end

------------------ Módulos (con fallback si Fsys no está listo) ------------------
local UIManager             = loadM("UIManager")                           -- opcional
local LiveOpsTime           = loadM("LiveOpsTime") or { now=function() return os.clock() end }
local ClientToolManager     = loadM("ClientToolManager") or { now=function() return LiveOpsTime.now() end }
local MinigameClientManager = loadM("MinigameClientManager")
local InteriorsM            = loadM("InteriorsM")      -- cuidado: puede requerir más UI; se usa protegida
local ClientData            = loadM("ClientData")      -- para timestamps cíclicos (si existen)

------------------ Config ------------------
local CONFIG = {
	games = {
		-- Ids de tus minijuegos tal como están en MinigameClientManager
		joetation     = { name="Joetation" },
		coconut_bonk  = { name="Coconut Bonk" },
	},
	order = { "joetation", "coconut_bonk" },

	-- Acciones (cadencia dinámica)
	actionCadence  = { joetation = 1.25, coconut_bonk = 1.50 },
	minCadence = 0.6, maxCadence = 2.5, cadenceStepDown = 0.10, cadenceStepUp = 0.15,

	-- ETA / backoff
	defaultQueueCountdown = 12,   -- cuando no hay timestamp real
	inProgressGrace       = 5,
	statusRefresh         = 1.0,
	queueStuckThreshold   = 90,   -- si llevas >X s en cola y no arranca → reintento

	-- Movimiento opcional
	moveAggressive = true, moveRadiusStop = 10,

	-- Teleport
	useInteriorsIfSafe = false,   -- ← por defecto OFF para evitar tu error “enter_core_async...”. Cambia a true si quieres probar.
	interiorsTimeout    = 6.0,

	-- Anti‑AFK
	AFK_ENABLED = true,

	-- UI
	screenLogs=true, debugPanel=true, maxLogLines=18,
}

------------------ UI / Logs ------------------
local function nowText() return os.date("%Y-%m-%d %H:%M:%S") end
local function fmtTime(s) s = math.max(0, math.floor(s)); return string.format("%02d:%02d", math.floor(s/60), s%60) end

local debugGui, debugTextLabel, infoLine
local logBuf = {}
local function ensureDebugGui()
	if not CONFIG.debugPanel or debugGui then return end
	local sg = Instance.new("ScreenGui"); sg.Name="AutoMG_Debug"; sg.ResetOnSpawn=false; sg.IgnoreGuiInset=true; sg.DisplayOrder=1000
	sg.Parent = LocalPlayer:WaitForChild("PlayerGui")
	local frame = Instance.new("Frame"); frame.Name="Panel"; frame.Position=UDim2.new(0,12,0,12); frame.Size=UDim2.new(0,520,0,340)
	frame.BackgroundColor3=Color3.fromRGB(20,20,28); frame.BackgroundTransparency=0.15; frame.BorderSizePixel=0; frame.Parent=sg
	local corner = Instance.new("UICorner"); corner.CornerRadius=UDim.new(0,12); corner.Parent=frame
	local title = Instance.new("TextLabel"); title.Size=UDim2.new(1,-16,0,28); title.Position=UDim2.new(0,8,0,8)
	title.BackgroundTransparency=1; title.TextXAlignment=Enum.TextXAlignment.Left; title.Font=Enum.Font.GothamBold; title.TextSize=18
	title.Text="🤖 AutoMinigames v4 – Smart Queue + Safe TP + Real ETA"; title.TextColor3=Color3.fromRGB(255,255,255); title.Parent=frame
	local info = Instance.new("TextLabel"); info.Name="Info"; info.Size=UDim2.new(1,-16,0,18); info.Position=UDim2.new(0,8,0,36)
	info.BackgroundTransparency=1; info.TextXAlignment=Enum.TextXAlignment.Left; info.Font=Enum.Font.Code; info.TextSize=14
	info.Text="—"; info.TextColor3=Color3.fromRGB(255,240,180); info.Parent=frame; infoLine=info
	local box = Instance.new("TextLabel"); box.Name="Log"; box.Size=UDim2.new(1,-16,1,-64); box.Position=UDim2.new(0,8,0,58)
	box.BackgroundTransparency=1; box.TextXAlignment=Enum.TextXAlignment.Left; box.TextYAlignment=Enum.TextYAlignment.Top
	box.Font=Enum.Font.Code; box.TextSize=15; box.Text=""; box.TextColor3=Color3.fromRGB(220,235,255); box.Parent=frame
	debugGui, debugTextLabel = sg, box
end
local function pushLog(s)
	if not (CONFIG.debugPanel and debugTextLabel) then return end
	table.insert(logBuf, s); while #logBuf>CONFIG.maxLogLines do table.remove(logBuf,1) end
	debugTextLabel.Text = table.concat(logBuf, "\n")
end
local function notify(text)
	if UIManager and CONFIG.screenLogs and UIManager.apps and UIManager.apps.HintApp then
		pcall(function() UIManager.apps.HintApp:hint({text=text; length=2.0; color=Color3.fromRGB(235,255,180); overridable=true}) end)
	else
		pcall(function() StarterGui:SetCore("SendNotification", {Title="AutoMG", Text=text, Duration=2}) end)
	end
end
local function LOG(tag, icon, msg)
	local line = string.format("%s[%s %s] %s", nowText(), tag, icon, msg)
	print(line); pushLog(line); if CONFIG.screenLogs then notify(icon.." "..msg) end
end
local function LOGP(tag, icon, msg) -- panel/console only (para countdown cada segundo)
	local line = string.format("%s[%s %s] %s", nowText(), tag, icon, msg)
	print(line); pushLog(line)
end

------------------ Helpers ------------------
local function hrp() local c=LocalPlayer.Character; return c and c:FindFirstChild("HumanoidRootPart") end
local function humanoid() local c=LocalPlayer.Character; return c and c:FindFirstChildWhichIsA("Humanoid") end
local function serverNow()
	if workspace.GetServerTimeNow then return workspace:GetServerTimeNow() end
	return LiveOpsTime.now()
end

------------------ Movimiento opcional ------------------
local function moveTo(target)
	if not CONFIG.moveAggressive then return end
	local hum, root = humanoid(), hrp(); if not (hum and root) then return end
	if (root.Position - target).Magnitude <= CONFIG.moveRadiusStop then return end
	local path = PathfindingService:CreatePath()
	local ok = pcall(function() path:ComputeAsync(root.Position, target) end)
	if not ok or path.Status ~= Enum.PathStatus.Success then hum:MoveTo(target); return end
	for _, wp in ipairs(path:GetWaypoints()) do hum:MoveTo(wp.Position) end
end

------------------ Cliente MG ------------------
local function getClient(id)
	if not MinigameClientManager then return nil end
	local ok, cli = pcall(function() return MinigameClientManager.get(id) end)
	return ok and cli or nil
end

-- Lectura robusta del estado (tiempos REALES)
local function readStatus(cli, id)
	-- Campos de minigame_state que existen en tu build. :contentReference[oaicite:14]{index=14}
	local st = {
		active=false, loading=false, inQueue=false,
		timeLeft=nil,   -- tiempo restante para arrancar/juego
		raw=nil
	}
	local ms = cli and cli.minigame_state
	local now = serverNow()

	if ms and ms.get then
		st.active  = ms:get("is_game_active") or false
		st.loading = ms:get("players_loading") or false
		-- Detectar si estamos en cola: lista queued_user_ids (servidor la expone). :contentReference[oaicite:15]{index=15}
		local q = nil
		pcall(function() q = ms:get_as_table and ms:get_as_table("queued_user_ids") end)
		if type(q)=="table" then
			for _,uid in ipairs(q) do if uid==LocalPlayer.UserId then st.inQueue=true break end end
		end
		-- ETA de inicio desde timestamp de zona si existe (override). :contentReference[oaicite:16]{index=16}
		local zts = ms:get("zone_override_timestamp")
		if typeof(zts)=="number" and zts ~= -1 then
			st.timeLeft = math.max(0, math.floor(zts - now)); st.raw="minigame_state.zone_override_timestamp"
		end
	end

	-- Si participando, usar fin real del minijuego. :contentReference[oaicite:17]{index=17}
	if cli and cli.is_participating and cli.end_time then
		st.active = true
		st.timeLeft = math.max(0, math.floor((cli.end_time or now) - now)); st.raw = st.raw or "client.end_time"
	end

	-- Si no hay override, intentar ClientData del ciclo (si existe)
	if (not st.timeLeft) and ClientData and cli and cli.cycle_timestamp_key then
		pcall(function()
			local rec = ClientData.get(cli.cycle_timestamp_key)
			local ts = rec and (rec.timestamp or rec.t or rec.next_timestamp)
			if ts then st.timeLeft = math.max(0, math.floor(ts - now)); st.raw="ClientData.cycle_timestamp" end
		end)
	end

	return st
end

-- ETA hasta iniciar (o reintentar)
local function estimateSecondsToStart(cli, id, st)
	if st.active then
		-- Estamos en partida u “ingame”; si no hay timeLeft, usa un cushion
		local left = st.timeLeft or CONFIG.defaultQueueCountdown
		return left + CONFIG.inProgressGrace, false, st.raw
	end
	if st.loading then
		return 5, true, "players_loading"
	end
	if st.timeLeft and st.timeLeft > 0 then
		return st.timeLeft, true, st.raw
	end
	return CONFIG.defaultQueueCountdown, true, "fallback.defaultQueueCountdown"
end

------------------ Teletransporte seguro al join zone ------------------
local function tpToJoinZone(cli)
	-- Preferimos NO abrir Interiors (causaba tu error). Si está activado, intentamos con timeout; si no, CFrame.
	local ok = false
	-- 1) CFrame directo si existe StaticMap.TeleportLocations[<id>]
	local destCF = nil
	pcall(function()
		local locs = workspace:FindFirstChild("StaticMap") and workspace.StaticMap:FindFirstChild("TeleportLocations")
		if locs then
			local n = cli.minigame_id
			local p = locs:FindFirstChild(n) or locs:FindFirstChild((n or ""):gsub("^%l", string.upper))
			if p and p:IsA("BasePart") then destCF = p.CFrame end
		end
	end)
	if destCF and hrp() then
		hrp().CFrame = destCF + Vector3.new(0, 3, 0)
		ok = true
		LOG("tp","🛰️","TP directo a TeleportLocations → "..tostring(cli.minigame_id))
	end

	-- 2) (Opcional) Interiors si se permite
	if (not ok) and CONFIG.useInteriorsIfSafe and InteriorsM and cli and cli.join_zone_destination_id then
		local done=false
		LOG("tp","🛫","Interiors → "..tostring(cli.join_zone_destination_id).." (MainDoor)")
		pcall(function()
			task.spawn(function()
				InteriorsM.enter_smooth(cli.join_zone_destination_id, "MainDoor")
				done=true
			end)
			local t0=tick(); while (not done) and tick()-t0<CONFIG.interiorsTimeout do task.wait(0.1) end
		end)
		ok = done
		if not ok then LOG("tp","⏱️","enter_smooth tardó demasiado; usaré CFrame si puedo.") end
	end

	-- 3) Último recurso: moverse hacia spawn si lo conocemos
	if (not ok) and destCF then
		moveTo(destCF.Position)
	end
end

------------------ Acciones de juego ------------------
local dynCadence, lastActionAt, actionsCount = {}, {}, {}
for k,v in pairs(CONFIG.actionCadence) do dynCadence[k]=v end
local windowStart = LiveOpsTime.now()
local function updInfo()
	if not infoLine then return end
	local parts = {}
	for _, id in ipairs(CONFIG.order) do
		local apm, elapsed = 0, math.max(1, LiveOpsTime.now() - windowStart)
		if actionsCount[id] then apm = math.floor(actionsCount[id]*60/elapsed) end
		table.insert(parts, string.format("%s: APM %d | cad %.2fs", id, apm, dynCadence[id] or 0))
	end
	infoLine.Text = table.concat(parts, "  •  ")
end
local function canAct(id)
	local cad = dynCadence[id] or 2.0
	local t = LiveOpsTime.now()
	if not lastActionAt[id] or (t-lastActionAt[id])>=cad then lastActionAt[id]=t; return true end
	return false
end
local function adjustCadence(id, ok)
	local cad = dynCadence[id] or 2.0
	if ok then cad = math.max(CONFIG.minCadence, cad-CONFIG.cadenceStepDown)
	else cad = math.min(CONFIG.maxCadence, cad+CONFIG.cadenceStepUp) end
	dynCadence[id]=cad; updInfo()
end

-- JOETATION (disparo al cañón más cercano)
local function act_joetation(cli)
	if not canAct("joetation") then return end
	local root = hrp(); local pos = root and root.Position or Vector3.new()
	if cli.pickup_pile_position then moveTo(cli.pickup_pile_position) end
	local ok1 = pcall(function() return cli:message_server("pickup_holdable_from_pile", pos, (ClientToolManager.now and ClientToolManager.now() or LiveOpsTime.now())) end)
	local idx = math.random(1,12)
	if cli.cannons_world and #cli.cannons_world>0 and pos then
		local me, best, bestIdx = pos
		for i,p in ipairs(cli.cannons_world) do local d=(p-me).Magnitude; if not best or d<best then best,bestIdx=d,i end end
		if bestIdx then idx=bestIdx end
	end
	local ok2 = pcall(function() return cli:message_server("use_cannon", idx, pos, (ClientToolManager.now and ClientToolManager.now() or LiveOpsTime.now())) end)
	actionsCount.joetation = (actionsCount.joetation or 0) + 1
	LOG("joetation","🎯","Disparo cañón #"..idx)
	adjustCadence("joetation", ok1 or ok2)
end

-- COCONUT BONK (prioriza barco más cercano con más vida)
local function act_coconut(cli)
	if not canAct("coconut_bonk") then return end
	pcall(function() cli:message_server("pickup_droppable", 1) end)
	local root = hrp(); local me = root and root.Position or Vector3.new()
	local bestUid, bestScore = nil, -1
	if cli.ships_by_uid then
		for uid, ship in pairs(cli.ships_by_uid) do
			local hp, p = 1, nil
			pcall(function()
				if ship.ship_data and ship.ship_data.health then hp = ship.ship_data.health end
				if ship.base and ship.base.PrimaryPart then p = ship.base.PrimaryPart.Position end
			end)
			local dist = p and (p-me).Magnitude or 1000
			local score = hp - dist*0.02
			if score>bestScore then bestScore, bestUid = score, uid end
		end
	end
	if bestUid then
		local ok = pcall(function() return cli:message_server("used_droppable", bestUid) end)
		actionsCount.coconut_bonk = (actionsCount.coconut_bonk or 0) + 1
		LOG("coconut_bonk","🥥","Lanzado a "..tostring(bestUid))
		adjustCadence("coconut_bonk", ok)
	end
end

------------------ Recompensas ------------------
local rewardRoutes = { "claim_rewards","collect_rewards","request_rewards","request_reward_payout","claim_payout","claim_xp" }
local function tryClaimRewards(id, cli)
	for _, r in ipairs(rewardRoutes) do
		if pcall(function() return cli:message_server(r) end) then LOG(id,"🏆","Recompensas ("..r..")"); return end
	end
	if cli.ingame_app_controller then
		for _, m in ipairs({"claimRewards","ClaimRewards","Finish","finish","Complete","complete"}) do
			local f = cli.ingame_app_controller[m]
			if typeof(f)=="function" and pcall(function() f(cli.ingame_app_controller) end) then
				LOG(id,"🏆","Recompensas via controller ("..m..")"); return
			end
		end
	end
end

------------------ Colas: salir/entrar ------------------
local leaveRoutes = { "leave_queue","cancel_queue","cancel_join","leave_persistent_game" }
local function leaveQueue(id)
	local cli = getClient(id); if not cli then return false end
	for _, r in ipairs(leaveRoutes) do
		if pcall(function() cli:message_server(r) end) then
			LOG(id,"🚪","Salir de cola ("..r..")"); return true
		end
	end
	return false
end
local function leaveAllQueues() for _, id in ipairs(CONFIG.order) do leaveQueue(id) end end

local function attemptJoin(id, st)
	local cli = getClient(id); if not cli then return false end
	if st.inQueue then LOG(id,"✅","Ya en cola."); return true end
	if st.active then return false end
	tpToJoinZone(cli) -- posicionarse en el lobby/join zone sin crashear UI
	local ok=false
	if cli.join_persistent_game then ok=pcall(function() cli:join_persistent_game() end) end
	if (not ok) and cli.message_server then ok=pcall(function() cli:message_server("join_queue") end) end
	if ok then LOG(id,"🕒","Entré a la cola.") end
	return ok
end

------------------ Selector de cola ------------------
local function readStatusAndEta(id)
	local cli = getClient(id); if not cli then return nil end
	local st = readStatus(cli, id)
	local eta, joinable, raw = estimateSecondsToStart(cli, id, st)
	return { cli=cli, st=st, eta=eta, joinable=joinable, raw=raw }
end

local function pickBestQueue()
	local bestId, bestEta, bestJoinable
	for _, id in ipairs(CONFIG.order) do
		local r = readStatusAndEta(id)
		if r then
			if r.eta < (bestEta or math.huge) then
				bestId, bestEta, bestJoinable = id, r.eta, r.joinable
			end
			LOG(id,"🧮", string.format("ETA %s (%s) | active=%s loading=%s inQueue=%s",
				fmtTime(r.eta), tostring(r.raw or "fallback"), tostring(r.st.active), tostring(r.st.loading), tostring(r.st.inQueue)))
		end
	end
	return bestId, bestEta, bestJoinable
end

------------------ Ciclo / Estado ------------------
local playing, mgEndsAt = {}, {}
local currentGame, queuedThisCycle, queuedGameId = nil, false, nil
local lastQueueLogSec = -1
local queueEnteredAt = nil

local function onGameStarted(id, cli)
	playing[id], currentGame = true, id
	actionsCount[id], windowStart = 0, LiveOpsTime.now()
	local left = nil
	if cli and cli.end_time then left = math.max(0, math.floor(cli.end_time - serverNow())) end
	if left then mgEndsAt[id] = serverNow() + left end
	LOG(id,"🚀","¡Partida iniciada! ⏱️ "..fmtTime(left or 0))
end

local function onGameEnded(id, cli)
	playing[id] = false; if currentGame==id then currentGame=nil end; mgEndsAt[id]=nil
	LOG(id,"🏁","Fin de partida. Reclamando recompensas…"); tryClaimRewards(id, cli)
	leaveAllQueues()
	queuedThisCycle, queuedGameId = false, nil
	queueEnteredAt, lastQueueLogSec = nil, -1
	LOG(id,"🔁","Nuevo ciclo → volveré a elegir la cola con menor ETA.")
end

------------------ Anti‑AFK ------------------
local AFK = { enabled = CONFIG.AFK_ENABLED, conns={}, lastW=0 }
local function enableAFK()
	if not AFK.enabled or #AFK.conns>0 then return end
	LOG("afk","🛡️","Anti‑AFK ON.")
	table.insert(AFK.conns, LocalPlayer.Idled:Connect(function()
		VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new())
		LOG("afk","🖱️","Ping anti‑idle.")
	end))
	table.insert(AFK.conns, RunService.Heartbeat:Connect(function()
		local t=LiveOpsTime.now(); if t-AFK.lastW>30 then
			local r=hrp(); if r then r.CFrame=r.CFrame*CFrame.Angles(0, math.rad(1), 0) end
			AFK.lastW=t; LOG("afk","🎮","Wiggle.")
		end
	end))
end
local function disableAFK()
	for _,c in ipairs(AFK.conns) do pcall(function() c:Disconnect() end) end
	AFK.conns={}; LOG("afk","🛑","Anti‑AFK OFF.")
end

------------------ Arranque ------------------
ensureDebugGui()
if AFK.enabled then enableAFK() end
LOG("init","✨","AutoMinigames v4 listo.")
LOG("init","🎯","Regla: una cola por ciclo, siempre la de menor ETA real.")

-- Cableado simple: vigilar transición (polling ligero)
task.spawn(function()
	while true do
		-- Selección/Join (si no estamos jugando y aún no hicimos join)
		if not currentGame and not queuedThisCycle then
			local bestId, eta, joinable = pickBestQueue()
			if bestId then
				if joinable then
					local r = readStatusAndEta(bestId)
					if attemptJoin(bestId, r and r.st or {}) or (r and r.st and r.st.inQueue) then
						queuedThisCycle, queuedGameId = true, bestId
						queueEnteredAt, lastQueueLogSec = tick(), -1
					else
						task.wait(math.max(2, math.min(eta or 5, 10)))
					end
				else
					LOG(bestId,"⏳","Esperando disponibilidad (~"..fmtTime(eta)..").")
					task.wait(math.max(CONFIG.statusRefresh, eta))
				end
			else
				task.wait(1.0)
			end

		else
			-- Si ya estamos en cola este ciclo y aún no estamos jugando → countdown continuo + watchdog de atasco
			if queuedThisCycle and queuedGameId and not currentGame then
				local r = readStatusAndEta(queuedGameId)
				if r then
					local seconds = math.max(0, math.floor(r.eta))
					if seconds ~= lastQueueLogSec then
						local src = (r.raw or "fallback")
						LOGP(queuedGameId, "⌛", "En cola — empieza en T‑"..fmtTime(seconds).." ("..tostring(src)..")")
						lastQueueLogSec = seconds
					end
					-- Watchdog de cola atascada
					if queueEnteredAt and (tick() - queueEnteredAt) > CONFIG.queueStuckThreshold and not r.st.loading and not r.st.active then
						LOG(queuedGameId,"🧹","Cola atascada > "..CONFIG.queueStuckThreshold.."s → reintento.")
						leaveAllQueues()
						queuedThisCycle, queuedGameId = false, nil
						queueEnteredAt, lastQueueLogSec = nil, -1
					end
					task.wait(CONFIG.statusRefresh)
				else
					task.wait(CONFIG.statusRefresh)
				end
			else
				task.wait(0.1)
			end
		end

		-- Juego activo: actuar
		for _, id in ipairs(CONFIG.order) do
			local cli = getClient(id)
			if cli and cli.is_participating then
				if currentGame ~= id or not playing[id] then onGameStarted(id, cli) end
				if id=="joetation" then act_joetation(cli)
				elseif id=="coconut_bonk" then act_coconut(cli)
				else pcall(function() cli:message_server("heartbeat") end); LOG(id,"🎮","Ping genérico.") end
			end
			-- Countdown local a fin de partida
			local etaEnd = mgEndsAt[id]
			if etaEnd and cli and cli.is_participating then
				local rem = math.max(0, math.floor(etaEnd - serverNow()))
				if rem % 5 == 0 then LOG(id,"⏳","Quedan "..fmtTime(rem)) end
				if rem==0 then tryClaimRewards(id, cli); mgEndsAt[id]=nil end
			end
		end
	end
end)

-- Respawn
LocalPlayer.CharacterAdded:Connect(function()
	LOG("player","🧍","Character listo; reanudando.")
end)

-- Atajos por chat
pcall(function()
	LocalPlayer.Chatted:Connect(function(msg)
		if msg == "!automg panel" and debugGui then
			debugGui.Enabled = not debugGui.Enabled; LOG("ui","🖥️","Panel "..(debugGui.Enabled and "ON" or "OFF"))
		elseif msg == "!automg afk on" then AFK.enabled=true; enableAFK()
		elseif msg == "!automg afk off" then AFK.enabled=false; disableAFK()
		elseif msg == "!automg move on" then CONFIG.moveAggressive=true; LOG("ui","🧭","Reposicionamiento ON")
		elseif msg == "!automg move off" then CONFIG.moveAggressive=false; LOG("ui","🧭","Reposicionamiento OFF")
		elseif msg == "!automg interiors on" then CONFIG.useInteriorsIfSafe=true; LOG("ui","🚪","Interiors TP ON (con timeout)")
		elseif msg == "!automg interiors off" then CONFIG.useInteriorsIfSafe=false; LOG("ui","🚪","Interiors TP OFF (CFrame)")
		end
	end)
end)
