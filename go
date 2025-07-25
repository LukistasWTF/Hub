--═════════════════════════════════════════════════════════════════════
--  ReplicateHouseFromURL.lua  (1‑by‑1 BuyFurnitures)
--    • Descarga JSON básico por URL (con proxy si hace falta)
--    • Reconstruye CFrame / Vector3 / Color3
--    • Aplica texturas con BuyTexture
--    • Coloca muebles llamando BuyFurnitures **uno por uno**
--    • UI compacta (estilo DumpHouse)
--═════════════════════════════════════════════════════════════════════

--------------------------------------------------------------------- ajustes
local WAIT_EACH_FURNI = 0.07   -- pausa entre compras (anti flood)
local RETRIES_PER_ITEM = 2     -- reintentos por mueble si falla
local WAIT_TEXTURE     = 0.05  -- pausa entre texturas

--------------------------------------------------------------------- servicios
local RS          = game:GetService("ReplicatedStorage")
local Players     = game:GetService("Players")
local LP          = Players.LocalPlayer
local HttpService = game:GetService("HttpService")

--------------------------------------------------------------------- Fsys / módulos
local Fsys         = require(RS:WaitForChild("Fsys"))
local load         = Fsys.load
local Roact        = load("Roact")
local RouterClient = load("RouterClient")
local HouseClient  = load("HouseClient")

--------------------------------------------------------------------- Router helpers
local function RC(route)
    local r = RouterClient.get(route)
    if not r then warn("[Replicate] RouterClient no tiene '"..route.."'") end
    return r
end
local function rcInvoke(route, ...)
    local r = RC(route)
    if not r or not r.InvokeServer then return false, "remote nil" end
    return pcall(r.InvokeServer, r, ...)
end
local function rcFire(route, ...)
    local r = RC(route)
    if r and r.FireServer then pcall(r.FireServer, r, ...) end
end

--------------------------------------------------------------------- edit‑mode
local function waitForEditMode(timeout)
    local t0 = tick()
    while true do
        if HouseClient.is_edit_mode_active() then return true end
        if timeout and (tick() - t0) > timeout then return false end
        task.wait(0.2)
    end
end

--------------------------------------------------------------------- proxy HTTP (executor -> httpget -> RF)
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
    if req then
        local r = req{Url=url, Method="GET"}
        if r and r.StatusCode == 200 then return r.Body end
    end
    if game.HttpGet then
        local ok, body = pcall(game.HttpGet, game, url)
        if ok then return body end
    end
    local ok, res = getProxy():InvokeServer(url)
    if ok then return res end
    error(res)
end

--------------------------------------------------------------------- reconstructor de tipos del dump básico
local function toCF(v)
    if typeof(v) == "CFrame" then return v end
    if type(v)=="table" and v.__type=="CFrame" and v.pos and v.look then
        local p  = Vector3.new(v.pos[1], v.pos[2], v.pos[3])
        local lv = Vector3.new(v.look[1],v.look[2],v.look[3])
        return CFrame.lookAt(p, p + lv)
    end
    return CFrame.new()
end
local function toV3(v)
    if typeof(v)=="Vector3" then return v end
    if type(v)=="table" and v.__type=="Vector3" then
        return Vector3.new(v.x or v[1] or 0, v.y or v[2] or 0, v.z or v[3] or 0)
    end
    if type(v)=="number" then -- algunos dumps guardan scale como número
        return Vector3.new(v, v, v)
    end
    return nil
end
local function toC3(v)
    if typeof(v)=="Color3" then return v end
    if type(v)=="table" and v.__type=="Color3" then
        return Color3.new(v.r or 0, v.g or 0, v.b or 0)
    end
    return nil
end
local function toColors(tbl)
    if not tbl then return nil end
    if typeof(tbl)=="Color3" then return {tbl} end
    if type(tbl)=="table" then
        local out = {}
        for k,val in pairs(tbl) do
            local c = toC3(val)
            if c then out[k] = c end
        end
        return next(out) and out or nil
    end
    return nil
end

--------------------------------------------------------------------- progreso UI
local DownloadEvent  = Instance.new("BindableEvent")
local ReplicateEvent = Instance.new("BindableEvent") -- (done,total)

--------------------------------------------------------------------- colocar 1 mueble (BuyFurnitures uno a uno)
local function placeOne(kind, props)
    -- El servidor espera una **lista**; enviamos 1 elemento.
    local payload = { { kind = kind, properties = props } }
    local ok,res = rcInvoke("HousingAPI/BuyFurnitures", payload)
    if not ok then return false, "pcall "..tostring(res) end
    if type(res)=="table" and res.success==false then
        return false, tostring(res.status or "failed")
    end
    return true
end

--------------------------------------------------------------------- rutina principal
local function replicateHouse(dump, setStatus)
    task.spawn(function()
        ------------------------------------------------------------------ entrar en edición (manual/auto)
        if not HouseClient.is_edit_mode_active() then
            setStatus("Pulsa *Edit House* (15s)…")
            if not waitForEditMode(15) then
                -- algunos servidores abren el editor cuando reciben este log
                rcFire("HousingAPI/SendHousingOnePointOneLog","edit_state_entered",{house_type="mine"})
                if not waitForEditMode(5) then
                    setStatus("❌ No se pudo entrar en modo edición.")
                    return
                end
            end
        end
        setStatus("✓ Edit mode detectado")

        ------------------------------------------------------------------ texturas
        if dump.house and dump.house.textures then
            for roomId, room in pairs(dump.house.textures) do
                for texType, texId in pairs(room) do
                    rcFire("HousingAPI/BuyTexture", roomId, texType, texId)
                    task.wait(WAIT_TEXTURE)
                end
            end
        end

        ------------------------------------------------------------------ muebles (uno a uno)
        local list = dump.furniture or {}
        local total = #list
        for i, entry in ipairs(list) do
            local f = entry.furniture_data or {}

            -- construir properties
            local props = {
                cframe  = toCF(f.cframe),
            }
            local sc = toV3(f.scale)
            if sc then props.scale = sc end
            local cols = toColors(f.colors)
            if cols then props.colors = cols end

            -- reintentos
            local ok,err
            for attempt=1,(1+RETRIES_PER_ITEM) do
                ok,err = placeOne(f.id, props)
                if ok then break end
                task.wait(0.15)
            end
            if not ok then
                warn(("[Replicate] Falló '%s' (%d/%d): %s"):format(tostring(f.id), i, total, tostring(err)))
            end

            ReplicateEvent:Fire(i, total)
            task.wait(WAIT_EACH_FURNI)
        end

        rcFire("HousingAPI/SendHousingOnePointOneLog","edit_state_exited",{}) -- opcional
        setStatus("✅ Replicación completada")
    end)
end

--------------------------------------------------------------------- UI
local Ui = Roact.Component:extend("ReplicateUi")

function Ui:init()
    self.state = {
        visible   = true,
        url       = "",
        status    = "Esperando URL…",
        meta      = nil,
        prog      = 0,
        total     = 1,
        downloading = false,
        replicating = false,
    }

    self.dlConn = DownloadEvent.Event:Connect(function(done,total)
        self:setState{status=string.format("Descargando %d/%d KB…",done,total)}
    end)
    self.repConn = ReplicateEvent.Event:Connect(function(done,total)
        self:setState{prog=done,total=total,status=string.format("Replicando %d/%d…",done,total)}
    end)
end
function Ui:willUnmount()
    self.dlConn:Disconnect(); self.repConn:Disconnect()
end

local function metaToString(meta)
    if not meta then return "No dump loaded." end
    return string.format(
        "Owner: %s\nType: %s\nFurniture: %d\nDate: %s",
        tostring(meta.owner or "‑"),
        tostring(meta.building_type or "‑"),
        tonumber(meta.furniture_count or 0),
        os.date("%c", tonumber(meta.time) or 0)
    )
end

function Ui:render()
    local s = self.state
    local pct = s.prog / math.max(1, s.total)

    return Roact.createElement("ScreenGui",{ResetOnSpawn=false},{
        Toggle = Roact.createElement("TextButton",{
            Text="☰", Font=Enum.Font.GothamBold, TextSize=22,
            BackgroundColor3=Color3.fromRGB(50,50,90), TextColor3=Color3.new(1,1,1),
            Size=UDim2.new(0,36,0,36), Position=UDim2.new(0,10,0,56),
            [Roact.Event.Activated]=function() self:setState{visible=not s.visible} end,
        }),

        Window = Roact.createElement("Frame",{
            Visible=s.visible, Size=UDim2.new(0,430,0,250),
            Position=UDim2.new(0,60,0,60),
            BackgroundColor3=Color3.fromRGB(30,30,30), BorderSizePixel=0,
        },{
            Roact.createElement("UICorner",{CornerRadius=UDim.new(0,10)}),

            Title = Roact.createElement("TextLabel",{
                Text="Replicate House (URL)", Font=Enum.Font.GothamBold, TextSize=22,
                BackgroundTransparency=1, TextColor3=Color3.new(1,1,1),
                Size=UDim2.new(1,-20,0,28), Position=UDim2.new(0,10,0,8),
                TextXAlignment=Enum.TextXAlignment.Left,
            }),

            UrlBox = Roact.createElement("TextBox",{
                PlaceholderText="https://…/dump_house_*.json",
                Text=s.url, Font=Enum.Font.Code, TextSize=14, ClearTextOnFocus=false,
                BackgroundColor3=Color3.fromRGB(45,45,60), TextColor3=Color3.new(1,1,1),
                Size=UDim2.new(1,-20,0,28), Position=UDim2.new(0,10,0,38),
                [Roact.Change.Text]=function(r) self:setState{url=r.Text} end,
            },{Roact.createElement("UICorner",{CornerRadius=UDim.new(0,4)})}),

            Status = Roact.createElement("TextLabel",{
                Text=s.status, Font=Enum.Font.Gotham, TextSize=14,
                BackgroundTransparency=1, TextColor3=Color3.fromRGB(200,200,200),
                Size=UDim2.new(1,-20,0,18), Position=UDim2.new(0,10,0,70),
                TextXAlignment=Enum.TextXAlignment.Left,
            }),

            ProgBG = Roact.createElement("Frame",{
                Size=UDim2.new(1,-20,0,10), Position=UDim2.new(0,10,0,90),
                BackgroundColor3=Color3.fromRGB(55,55,55), BorderSizePixel=0,
            },{
                Fill = Roact.createElement("Frame",{
                    Size=UDim2.new(pct,0,1,0),
                    BackgroundColor3=Color3.fromRGB(60,120,200), BorderSizePixel=0,
                })
            }),

            Info = Roact.createElement("TextLabel",{
                Text=metaToString(s.meta), Font=Enum.Font.Gotham, TextSize=14,
                BackgroundColor3=Color3.fromRGB(45,45,45), TextColor3=Color3.new(1,1,1),
                TextXAlignment=Enum.TextXAlignment.Left, TextYAlignment=Enum.TextYAlignment.Top,
                Size=UDim2.new(1,-20,1,-140), Position=UDim2.new(0,10,0,110),
                BorderSizePixel=0,
            },{Roact.createElement("UICorner",{CornerRadius=UDim.new(0,6)})}),

            BtnLoad = Roact.createElement("TextButton",{
                Text=s.downloading and"Loading…" or"Load JSON",
                Font=Enum.Font.GothamBold, TextSize=18,
                BackgroundColor3=Color3.fromRGB(80,150,90), TextColor3=Color3.new(1,1,1),
                Size=UDim2.new(0.48,-12,0,36), Position=UDim2.new(0,10,1,-46),
                AutoButtonColor=not s.downloading,
                [Roact.Event.Activated]=function()
                    if s.downloading then return end
                    local url=s.url
                    if not url:match("^https?://") then
                        self:setState{status="❌ URL no válida."}; return
                    end
                    self:setState{downloading=true,status="Descargando…",prog=0,total=1}
                    task.spawn(function()
                        local ok, body = pcall(httpFetch, url)
                        if not ok then self:setState{status="❌ "..tostring(body),downloading=false}; return end
                        local ok2, dump = pcall(HttpService.JSONDecode,HttpService,body)
                        if not ok2 then self:setState{status="❌ JSON mal formado",downloading=false}; return end
                        self.dumpLoaded = dump
                        local h = dump.house or {}
                        self:setState{
                            downloading=false, status="JSON OK",
                            meta = {
                                owner           = h.player or h.owner or "?",
                                building_type   = h.building_type or "?",
                                furniture_count = dump.furniture_count or #(dump.furniture or {}),
                                time            = dump.time,
                            },
                            prog=0, total=1
                        }
                    end)
                end,
            }),

            BtnRep = Roact.createElement("TextButton",{
                Text=s.replicating and"Replicating…" or"Replicate",
                Font=Enum.Font.GothamBold, TextSize=18,
                BackgroundColor3=Color3.fromRGB(60,120,200), TextColor3=Color3.new(1,1,1),
                Size=UDim2.new(0.48,-12,0,36), Position=UDim2.new(0.52,2,1,-46),
                AutoButtonColor=not s.replicating,
                [Roact.Event.Activated]=function()
                    if self.dumpLoaded and not s.replicating then
                        local total = self.dumpLoaded.furniture_count or #(self.dumpLoaded.furniture or {})
                        self:setState{replicating=true,status="Replicando…",prog=0,total=total}
                        replicateHouse(self.dumpLoaded,function(txt) self:setState{status=txt} end)
                    end
                end,
            }),
        }),
    })
end

Roact.mount(Roact.createElement(Ui), LP:WaitForChild("PlayerGui"))
