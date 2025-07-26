--═════════════════════════════════════════════════════════════════════
-- ReplicateHouseFromURL.lua  V7.2 (DoorLocalOnly + RouteScanNoRouter)
--  • Lee format.space = "door_local_only"
--  • Usa entry.space.door_local_cf (basis_v2) => world = doorHere:ToWorldSpace(local_cf)
--  • Descubre remotos por nombre en ReplicatedStorage (sin RouterClient, sin WaitForChild)
--  • Si no hay BuyTextures => las salta sin bloquear; muebles siguen
--  • Auto‑detect WORLD/LOCAL + retry por ítem
--  • Loader blindado + HTTP proxy + UI completa
--═════════════════════════════════════════════════════════════════════

------------------------------ Ajustes --------------------------------
local WAIT_EACH_FURNI   = 0.07
local RETRIES_PER_ITEM  = 1
local WAIT_TEXTURE      = 0.05
local EPS_DETECT        = 1e-3
local APPLY_TEXTURES    = true -- pon false si quieres saltarlas siempre
local SCAN_COOLDOWN     = 0.25 -- para no escanear RS en exceso

------------------------------ Servicios ------------------------------
local RS          = game:GetService("ReplicatedStorage")
local Players     = game:GetService("Players")
local LP          = Players.LocalPlayer
local HttpService = game:GetService("HttpService")

--------------------------- Loader seguro (Fsys + fallback) ----------
local function requireDeep(name)
    local inst = RS:FindFirstChild(name, true)
    if inst and inst:IsA("ModuleScript") then
        local ok,mod = pcall(require, inst)
        if ok and mod ~= nil then return mod end
    end
end

local Fsys do
    local ok,obj = pcall(function() return RS:WaitForChild("Fsys", 2) end)
    if ok and obj then pcall(function() Fsys = require(obj) end) end
end

local function FsLoad(name)
    if Fsys and type(Fsys.load)=="function" then
        local ok,m  = pcall(Fsys.load,name)       ; if ok and m  ~= nil then return m  end
        local ok2,m2= pcall(Fsys.load,Fsys,name)  ; if ok2 and m2 ~= nil then return m2 end
    end
    local m = requireDeep(name); if m ~= nil then return m end
    error(("(Replicate) No se pudo cargar módulo '%s'"):format(tostring(name)))
end

------------------------------ Módulos --------------------------------
local Roact        = FsLoad("Roact")
local HouseClient  = (pcall(FsLoad,"HouseClient")           and FsLoad("HouseClient")) or nil
local InteriorsM   = (pcall(FsLoad,"InteriorsM")            and FsLoad("InteriorsM"))  or nil
local ClientData   = (pcall(FsLoad,"ClientData")            and FsLoad("ClientData"))  or nil
local FurnitureModelTracker = (pcall(FsLoad,"FurnitureModelTracker") and FsLoad("FurnitureModelTracker")) or nil

------------------------------ HTTP -----------------------------------
local proxyRF
local function getProxy()
    if proxyRF then return proxyRF end
    proxyRF = Instance.new("RemoteFunction")
    proxyRF.Name = "__ReplicateHttpProxy"
    proxyRF.Parent = RS
    proxyRF.OnServerInvoke = function(_, url)
        local ok, res = pcall(HttpService.GetAsync, HttpService, url, false)
        return ok, ok and res or tostring(res)
    end
    return proxyRF
end
local function httpFetch(url)
    local req = (syn and syn.request) or (http and http.request) or request
    if req then local r=req{Url=url,Method="GET"}; if r and r.StatusCode==200 then return r.Body end end
    if game.HttpGet then local ok,b=pcall(game.HttpGet,game,url); if ok then return b end end
    local ok,res=getProxy():InvokeServer(url); if ok then return res end; error(res)
end

------------------------------ Reconstrucción -------------------------
local function cf_from_basis(t)
    local p = Vector3.new(t.pos[1], t.pos[2], t.pos[3])
    local r = Vector3.new(t.right[1], t.right[2], t.right[3])
    local u = Vector3.new(t.up[1], t.up[2], t.up[3])
    return CFrame.fromMatrix(p, r, u)
end
local function toCF(v)
    if typeof(v)=="CFrame" then return v end
    if type(v)=="table" and v.__type=="CFrame" then
        if v.pos and v.right and v.up then return cf_from_basis(v) end
        if v.pos and v.look then
            local p = Vector3.new(v.pos[1],v.pos[2],v.pos[3])
            local l = Vector3.new(v.look[1],v.look[2],v.look[3])
            return CFrame.lookAt(p, p+l)
        end
    end
    return CFrame.new()
end
local function toV3(v)
    if typeof(v)=="Vector3" then return v end
    if type(v)=="number" then return Vector3.new(v,v,v) end
    if type(v)=="table" then
        if v.__type=="Vector3" then return Vector3.new(v.x or v[1] or 0, v.y or v[2] or 0, v.z or v[3] or 0) end
        if v[1] and v[2] and v[3] then return Vector3.new(v[1],v[2],v[3]) end
    end
end
local function c3(t)
    if typeof(t)=="Color3" then return t end
    if type(t)=="table" and t.__type=="Color3" then
        local r,g,b=tonumber(t.r) or 0, tonumber(t.g) or 0, tonumber(t.b) or 0
        if r>1 or g>1 or b>1 then r/=255; g/=255; b/=255 end
        return Color3.new(r,g,b)
    end
    if type(t)=="table" and t.hex then
        local n=tonumber(t.hex,16) or 0
        return Color3.fromRGB(math.floor(n/65536)%256, math.floor(n/256)%256, n%256)
    end
end
local function toColors(tbl)
    if not tbl then return nil end
    if typeof(tbl)=="Color3" then return {tbl} end
    local out={}; for k,v in pairs(tbl) do local cc=c3(v); if cc then out[k]=cc end end
    return next(out) and out or nil
end

------------------------------ Interior / Puerta ----------------------
local DOOR_PAT = { "MainDoor","Main_Door","Door","Puerta","Entrance","Entry" }
local function tryCall(mod, fn, ...)
    if not mod then return end
    local f = mod[fn]; if type(f)~="function" then return end
    local ok,res = pcall(f, ...); if ok then return res end
end
local function getPivotCF(inst)
    if not inst then return CFrame.new() end
    if inst:IsA("Model") then local ok,cf=pcall(inst.GetPivot,inst); if ok then return cf end end
    if inst:IsA("BasePart") then return inst.CFrame end
    return CFrame.new()
end
local function getInteriorModel()
    local loc = tryCall(InteriorsM, "get_current_location")
    if type(loc)=="table" then
        if typeof(loc.model)=="Instance"    then return loc.model end
        if typeof(loc.container)=="Instance" then return loc.container end
    end
end
local function findDoor(root)
    if not root then return end
    for _,d in ipairs(root:GetDescendants()) do
        if d:IsA("BasePart") then
            if d:GetAttribute("is_main_door") or d:GetAttribute("door") then return d end
            local nm=d.Name:lower(); for _,p in ipairs(DOOR_PAT) do if nm:find(p:lower()) then return d end end
        end
    end
end
local function buildDoorCS(partOrCF)
    if typeof(partOrCF)=="CFrame" then
        local cf = partOrCF
        return CFrame.fromMatrix(cf.Position, cf.RightVector.Unit, cf.UpVector.Unit)
    end
    if typeof(partOrCF)=="Instance" then
        local cf = getPivotCF(partOrCF) or CFrame.new()
        return CFrame.fromMatrix(cf.Position, cf.RightVector.Unit, cf.UpVector.Unit)
    end
    return CFrame.new()
end

------------------------------ Detección espacio ----------------------
local function detect_server_space(doorCF)
    local interior = tryCall(ClientData,"get","house_interior")
    if not (interior and interior.furniture) or not FurnitureModelTracker then return "world" end
    for unique,data in pairs(interior.furniture) do
        if data and data.cframe then
            local mdl = FurnitureModelTracker.get_furniture_by_unique(unique)
            if mdl then
                local mcf = getPivotCF(mdl)
                local dcw = toCF(data.cframe)             -- WORLD
                local dcl = doorCF:ToWorldSpace(dcw)      -- LOCAL interpretado como si fuera door_local
                local d1  = (mcf.Position - dcw.Position).Magnitude
                local d2  = (mcf.Position - dcl.Position).Magnitude
                if d1 < EPS_DETECT and d1 <= d2 then return "world" end
                if d2 < EPS_DETECT and d2 <  d1 then return "local" end
            end
        end
    end
    return "world"
end

------------------------------ Descubrimiento de remotos -------------
local lastScan, cache = 0, { textures=nil, furnitures=nil }
local TEXTURE_NAMES   = { "BuyTextures","BuyTexture","ApplyTexture","SetRoomTexture" }
local FURNITURE_NAMES = { "BuyFurnitures","BuyFurniture","PlaceFurniture" }

local function scanRemotes()
    if os.clock()-lastScan < SCAN_COOLDOWN then return end
    lastScan = os.clock()
    local textures, furnitures
    for _,inst in ipairs(RS:GetDescendants()) do
        if inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction") then
            local name = inst.Name
            for _,t in ipairs(TEXTURE_NAMES) do
                if name == t then textures = inst end
            end
            for _,f in ipairs(FURNITURE_NAMES) do
                if name == f then furnitures = inst end
            end
        end
    end
    cache.textures  = textures
    cache.furnitures= furnitures
end

local function sendTexture(roomId, typ, texId)
    scanRemotes()
    local r = cache.textures
    if not r then return false,"no textures remote" end
    if r:IsA("RemoteFunction") then
        local ok = pcall(r.InvokeServer, r, roomId, typ, texId); if ok then return true end
        -- firmas alternativas empaquetadas
        ok = pcall(r.InvokeServer, r, {roomId=roomId,type=typ,textureId=texId}); if ok then return true end
        ok = pcall(r.InvokeServer, r, {room=roomId,texType=typ,texId=texId});    if ok then return true end
        return false,"invoke failed"
    else
        local ok = pcall(r.FireServer, r, roomId, typ, texId); if ok then return true end
        ok = pcall(r.FireServer, r, {roomId=roomId,type=typ,textureId=texId}); if ok then return true end
        ok = pcall(r.FireServer, r, {room=roomId,texType=typ,texId=texId});    if ok then return true end
        return false,"fire failed"
    end
end

local function placeOne(kind, props)
    scanRemotes()
    local r = cache.furnitures
    if not r then return false,"no furnitures remote" end
    local payloads = {
        { { kind=kind, properties=props } },
        { kind=kind, properties=props },
        { items = { { kind=kind, properties=props } } },
    }
    if r:IsA("RemoteFunction") then
        for _,p in ipairs(payloads) do
            local ok,res = pcall(r.InvokeServer, r, p)
            if ok then
                if type(res)=="table" and res.success==false then return false, tostring(res.status or "failed") end
                return true
            end
        end
        return false,"invoke failed"
    else
        for _,p in ipairs(payloads) do
            local ok = pcall(r.FireServer, r, p)
            if ok then return true end
        end
        return false,"fire failed"
    end
end

------------------------------ UI eventos ----------------------------
local ReplicateEvent = Instance.new("BindableEvent")
local DoneEvent      = Instance.new("BindableEvent")

------------------------------ Replicación ---------------------------
local function replicateHouse(dump, setStatus)
    task.spawn(function()
        -- Validación formato
        local space = dump.format and dump.format.space
        if space ~= "door_local_only" then
            setStatus("❌ JSON debe tener format.space='door_local_only'.")
            DoneEvent:Fire(); return
        end

        -- Esperar modo edición
        local t0=os.clock()
        while true do
            local ok,on = pcall(HouseClient and HouseClient.is_edit_mode_active or function() return true end)
            if ok and on then break end
            if os.clock()-t0>15 then setStatus("❌ No se pudo entrar en modo edición."); DoneEvent:Fire(); return end
            setStatus("Pulsa *Edit House*…"); task.wait(0.2)
        end
        setStatus("✓ Edit mode detectado")

        -- Puerta actual
        local rootM  = getInteriorModel()
        local doorP  = rootM and findDoor(rootM)
        local doorCF = buildDoorCS(doorP or rootM or CFrame.new())
        if doorP then setStatus("Puerta detectada: "..doorP.Name) else setStatus("⚠️ Puerta no encontrada; usando pivot del interior.") end

        -- Espacio server
        local serverSpace = detect_server_space(doorCF)
        print("[Replicate] serverSpace detectado = "..serverSpace)

        -- Texturas
        if APPLY_TEXTURES and dump.house and dump.house.textures then
            scanRemotes()
            if not cache.textures then
                setStatus("⚠️ Sin remoto de texturas; se omiten.")
            else
                for roomId,room in pairs(dump.house.textures) do
                    for texType,texId in pairs(room) do
                        local ok,msg = sendTexture(roomId, texType, texId)
                        if not ok then warn("[Replicate] no se pudo aplicar textura "..tostring(roomId).."/"..tostring(texType).." ("..tostring(msg)..")") end
                        task.wait(WAIT_TEXTURE)
                    end
                end
            end
        end

        -- Muebles
        local list  = dump.furniture or {}
        local total = #list
        if total==0 then setStatus("⚠️ No hay muebles en el JSON."); DoneEvent:Fire(); return end

        scanRemotes()
        if not cache.furnitures then setStatus("❌ No hay remoto de muebles en RS."); DoneEvent:Fire(); return end

        for i,entry in ipairs(list) do
            local f   = entry.furniture_data or entry
            local loc = (entry.space and (entry.space.door_local_cf or entry.space.canon_local_cf)) or f.door_local_cf
            if not loc then
                warn("[Replicate] entrada sin door_local_cf; omitida "..tostring(f.id or f.kind))
                ReplicateEvent:Fire(i,total)
                setStatus(string.format("Omitido %d/%d (sin door_local_cf)…",i,total))
                task.wait(WAIT_EACH_FURNI)
            else
                local local_cf = toCF(loc)
                local world_cf = doorCF:ToWorldSpace(local_cf)

                local function mkProps(which)
                    local props = { cframe = (which=="world") and world_cf or local_cf }
                    local sc=toV3(f.scale);      if sc then props.scale  = sc end
                    local cs=toColors(f.colors); if cs then props.colors = cs end
                    return props
                end

                local ok,err = placeOne(f.id or f.kind, mkProps(serverSpace))
                if (not ok) and RETRIES_PER_ITEM>0 then
                    task.wait(0.15)
                    local alt=(serverSpace=="world") and "local" or "world"
                    ok,err = placeOne(f.id or f.kind, mkProps(alt))
                    if ok then serverSpace=alt; print("[Replicate DoorLocal] switch => "..alt) end
                end
                if not ok then
                    warn(("[Replicate] Falló '%s' (%d/%d): %s"):format(tostring(f.id or f.kind), i, total, tostring(err)))
                end

                ReplicateEvent:Fire(i,total)
                setStatus(string.format("Replicando %d/%d…",i,total))
                task.wait(WAIT_EACH_FURNI)
            end
        end

        setStatus("✅ Replicación completada")
        DoneEvent:Fire()
    end)
end

------------------------------ UI completa ----------------------------
local Ui = Roact.Component:extend("ReplicateUi")
function Ui:init()
    self.state = { visible=true, url="", status="Esperando URL…", meta=nil, prog=0, total=1, downloading=false, replicating=false }
    self.c1 = ReplicateEvent.Event:Connect(function(done,total)
        self:setState{prog=done,total=total,status=string.format("Replicando %d/%d…",done,total)}
    end)
    self.c2 = DoneEvent.Event:Connect(function() self:setState{replicating=false} end)
end
function Ui:willUnmount() if self.c1 then self.c1:Disconnect() end; if self.c2 then self.c2:Disconnect() end end

local function metaStr(meta)
    if not meta then return "No dump loaded." end
    return string.format("Owner: %s\nType: %s\nFurniture: %d\nDate: %s\nFormat: %s/%s",
        tostring(meta.owner or "‑"), tostring(meta.building_type or "‑"),
        tonumber(meta.furniture_count or 0) or 0, os.date("%c", tonumber(meta.time) or 0),
        tostring((meta.format and meta.format.cframe) or "-"),
        tostring((meta.format and meta.format.space) or "-"))
end

function Ui:render()
    local s=self.state; local pct=(type(s.prog)=="number" and type(s.total)=="number" and s.total>0) and (s.prog/s.total) or 0
    return Roact.createElement("ScreenGui",{ResetOnSpawn=false},{
        Toggle=Roact.createElement("TextButton",{Text="☰",Font=Enum.Font.GothamBold,TextSize=22,BackgroundColor3=Color3.fromRGB(50,50,90),TextColor3=Color3.new(1,1,1),Size=UDim2.new(0,36,0,36),Position=UDim2.new(0,10,0,56),[Roact.Event.Activated]=function() self:setState{visible=not s.visible} end}),
        Window=Roact.createElement("Frame",{Visible=s.visible,Size=UDim2.new(0,460,0,260),Position=UDim2.new(0,60,0,60),BackgroundColor3=Color3.fromRGB(30,30,30),BorderSizePixel=0},{
            Roact.createElement("UICorner",{CornerRadius=UDim.new(0,10)}),
            Roact.createElement("TextLabel",{Text="Replicate House (URL) – V7.2 DoorLocalOnly",Font=Enum.Font.GothamBold,TextSize=22,BackgroundTransparency=1,TextColor3=Color3.new(1,1,1),Size=UDim2.new(1,-20,0,28),Position=UDim2.new(0,10,0,8),TextXAlignment=Enum.TextXAlignment.Left}),
            Roact.createElement("TextBox",{PlaceholderText="https://…/dump_house_*.json",Text=s.url,Font=Enum.Font.Code,TextSize=14,ClearTextOnFocus=false,BackgroundColor3=Color3.fromRGB(45,45,60),TextColor3=Color3.new(1,1,1),Size=UDim2.new(1,-20,0,28),Position=UDim2.new(0,10,0,38),[Roact.Change.Text]=function(r) self:setState{url=r.Text} end},{Roact.createElement("UICorner",{CornerRadius=UDim.new(0,4)})}),
            Roact.createElement("TextLabel",{Text=s.status,Font=Enum.Font.Gotham,TextSize=14,BackgroundTransparency=1,TextColor3=Color3.fromRGB(200,200,200),Size=UDim2.new(1,-20,0,18),Position=UDim2.new(0,10,0,70),TextXAlignment=Enum.TextXAlignment.Left}),
            Roact.createElement("Frame",{Size=UDim2.new(1,-20,0,10),Position=UDim2.new(0,10,0,90),BackgroundColor3=Color3.fromRGB(55,55,55),BorderSizePixel=0},{Roact.createElement("Frame",{Size=UDim2.new(pct,0,1,0),BackgroundColor3=Color3.fromRGB(60,120,200),BorderSizePixel=0})}),
            Roact.createElement("TextLabel",{Text=metaStr(s.meta),Font=Enum.Font.Gotham,TextSize=14,BackgroundColor3=Color3.fromRGB(45,45,45),TextColor3=Color3.new(1,1,1),TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,Size=UDim2.new(1,-20,1,-138),Position=UDim2.new(0,10,0,110),BorderSizePixel=0},{Roact.createElement("UICorner",{CornerRadius=UDim.new(0,6)})}),
            Roact.createElement("TextButton",{Text=s.downloading and"Loading…" or"Load JSON",Font=Enum.Font.GothamBold,TextSize=18,BackgroundColor3=Color3.fromRGB(80,150,90),TextColor3=Color3.new(1,1,1),Size=UDim2.new(0.48,-12,0,36),Position=UDim2.new(0,10,1,-46),AutoButtonColor=not s.downloading,
                [Roact.Event.Activated]=function()
                    if s.downloading then return end
                    local url=s.url; if not url:match("^https?://") then self:setState{status="❌ URL no válida."}; return end
                    self:setState{downloading=true,status="Descargando…",prog=0,total=1}
                    task.spawn(function()
                        local ok,body=pcall(httpFetch,url); if not ok then self:setState{status="❌ "..tostring(body),downloading=false}; return end
                        local ok2,dump=pcall(HttpService.JSONDecode,HttpService,body); if not ok2 then self:setState{status="❌ JSON mal formado",downloading=false}; return end
                        if dump and dump.format and dump.format.space=="door_local_only" then self:setState{status="JSON OK"} else self:setState{status="⚠️ JSON no es 'door_local_only'."} end
                        self.dumpLoaded=dump; local h=dump.house or {}
                        self:setState{downloading=false,meta={owner=h.player or h.owner or "?",building_type=h.building_type or "?",furniture_count=dump.furniture_count or #(dump.furniture or {}),time=dump.time,format=dump.format},prog=0,total=1}
                    end)
                end}),
            Roact.createElement("TextButton",{Text=s.replicating and"Replicating…" or"Replicate",Font=Enum.Font.GothamBold,TextSize=18,BackgroundColor3=Color3.fromRGB(60,120,200),TextColor3=Color3.new(1,1,1),Size=UDim2.new(0.48,-12,0,36),Position=UDim2.new(0.52,2,1,-46),AutoButtonColor=not s.replicating,
                [Roact.Event.Activated]=function()
                    if self.dumpLoaded and not s.replicating then
                        local total=self.dumpLoaded.furniture_count or #(self.dumpLoaded.furniture or {})
                        self:setState{replicating=true,status="Replicando…",prog=0,total=total}
                        replicateHouse(self.dumpLoaded,function(txt) self:setState{status=txt} end)
                    end
                end}),
        }),
    })
end
Roact.mount(Roact.createElement(Ui), LP:WaitForChild("PlayerGui"))
