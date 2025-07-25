--═════════════════════════════════════════════════════════════════════
--  ReplicateHouseFromURL.lua   –   versión robusta 25‑jul‑2025
--═════════════════════════════════════════════════════════════════════
--  ▸ Introduce smart_remote(timeout)  (sin esperas infinitas)
--  ▸ Comprueba/activa modo edición con HouseClient
--  ▸ Proxy HTTP automático (executor ► HttpGet ► RemoteFunction)
--  ▸ UI Roact igual al estilo DumpHouse
--═════════════════════════════════════════════════════════════════════

------------------------------ rutas & delays ------------------------------
local ROUTE_ENTER_EDIT_MODE = "HousingAPI/EnterEditMode"
local ROUTE_EXIT_EDIT_MODE  = "HousingAPI/ExitEditMode"
local ROUTE_PLACE_FURNITURE = "HousingAPI/PlaceFurniture"
local ROUTE_SET_TEXTURE     = "HousingAPI/SetRoomTexture"
local ROUTE_MODIFY_ADDONS   = "HousingAPI/ModifyHouseAddons"

local BATCH_SIZE   = 10
local WAIT_BATCH   = 0.12
local WAIT_TEXTURE = 0.05
-------------------------------------------------------------------------

local RS, Players = game:GetService("ReplicatedStorage"), game:GetService("Players")
local LP          = Players.LocalPlayer
local HttpService = game:GetService("HttpService")

------------------------------ Fsys/Roact stack ------------------------------
local Fsys  = require(RS:WaitForChild("Fsys"))
local load  = Fsys.load
local Roact = load("Roact")
local RouterClient = load("RouterClient")
local HouseClient  = load("HouseClient")          -- para saber si ya estamos en edit‑mode
------------------------------------------------------------------------------

--══════════════════════  Herramientas de red (remotos)  ══════════════════════
--- Devuelve el RemoteEvent/Function indicado por la ruta.
--- No espera más de <timeout> s en cada segmento → evita infinite yield.
local function smart_remote(route, timeout)
    timeout = timeout or 3
    local parent = RS
    for _, seg in ipairs(string.split(route, "/")) do
        local child = parent:FindFirstChild(seg) or parent:WaitForChild(seg, timeout)
        if not child then
            warn(("[Replicate] remote '%s' no encontrado"):format(route))
            return nil
        end
        parent = child
    end
    return parent
end

local function safe_call(remoteObj, ...)
    if not remoteObj then return false, "remote nil" end
    local fn = remoteObj.InvokeServer or remoteObj.FireServer
    if not fn then return false, "sin método Invoke/Fire" end
    return pcall(fn, remoteObj, ...)
end

--════════════════════  helpers para entrar / salir del editor  ══════════════
local entered_by_script = false

local function ensure_edit()
    if HouseClient and HouseClient.is_edit_mode_active() then return end
    local r = smart_remote(ROUTE_ENTER_EDIT_MODE)
    if safe_call(r) then
        local t0 = tick()
        while not HouseClient.is_edit_mode_active() and tick() - t0 < 4 do
            task.wait(0.1)
        end
        entered_by_script = true
    else
        warn("[Replicate] No se pudo entrar en modo edición")
    end
end

local function leave_edit()
    if not entered_by_script then return end
    entered_by_script = false
    safe_call(smart_remote(ROUTE_EXIT_EDIT_MODE))
end

--═══════════════════════  HTTP Fetch (executor ► proxy)  ════════════════════
local proxyRF                                       -- se crea on‑demand
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

--- Descarga el contenido de url y devuelve string (o lanza error)
local function httpFetch(url)
    -- 1) Executors con request()
    local req = (syn and syn.request) or (http and http.request) or request
    if req then
        local r = req{Url=url, Method="GET", Headers={}}
        if r and r.StatusCode == 200 then return r.Body end
        error(("HTTP %s"):format(r and r.StatusCode or "?"))
    end
    -- 2) game:HttpGet()
    if game.HttpGet then
        local ok, body = pcall(game.HttpGet, game, url)
        if ok then return body end
    end
    -- 3) Proxy servidor
    local ok, res = getProxy():InvokeServer(url)
    if ok then return res end
    error(res)
end
--═════════════════════════════════════════════════════════════════════════════

----------------------------- eventos progreso -------------------------------
local DownloadEvent  = Instance.new("BindableEvent") -- (ahora sólo status string)
local ReplicateEvent = Instance.new("BindableEvent") -- (muebles colocados)
------------------------------------------------------------------------------

--══════════════════════  rutina principal de réplica  ═══════════════════════
local function replicateHouse(dump, setStatus)
    task.spawn(function()
        setStatus("Entering edit mode…")
        ensure_edit()

        ------------------- texturas -------------------
        local setTexR = smart_remote(ROUTE_SET_TEXTURE)
        if dump.house and dump.house.textures and setTexR then
            for roomId, room in pairs(dump.house.textures) do
                for texType, texId in pairs(room) do
                    safe_call(setTexR, roomId, texType, texId)
                    task.wait(WAIT_TEXTURE)
                end
            end
        end

        ------------------- add‑ons --------------------
        if dump.house and dump.house.active_addons_resolved then
            safe_call(smart_remote(ROUTE_MODIFY_ADDONS),
                      dump.house.house_id or 0,
                      dump.house.active_addons_resolved)
            task.wait(WAIT_TEXTURE)
        end

        ------------------- muebles --------------------
        local placeR = smart_remote(ROUTE_PLACE_FURNITURE)
        local list   = dump.furniture or {}
        for i, entry in ipairs(list) do
            local f = entry.furniture_data
            safe_call(placeR, {id=f.id,cframe=f.cframe,scale=f.scale,colors=f.colors})
            if i % BATCH_SIZE == 0 then task.wait(WAIT_BATCH) end
            ReplicateEvent:Fire(i, #list)
        end

        leave_edit()
        setStatus("✅ Replicación completada")
    end)
end

--═══════════════════════════════  UI  ═══════════════════════════════════════
local Ui = Roact.Component:extend("ReplicateUi")

function Ui:init()
    self.state = {
        shown       = true,
        url         = "",
        status      = "Waiting URL…",
        meta        = nil,
        prog        = 0,
        total       = 1,
        downloading = false,
        replicating = false,
    }

    self.repConn = ReplicateEvent.Event:Connect(function(done,total)
        -- setState seguro (deferred)
        task.defer(function()
            self:setState{prog=done,total=total,
                          status=("Replicating %d/%d…"):format(done,total)}
        end)
    end)
end

function Ui:willUnmount()
    self.repConn:Disconnect()
end

function Ui:render()
    local s = self.state
    local pct = s.prog / math.max(1, s.total)
    local metaTxt = s.meta and string.format(
        "Owner: %s\nType: %s\nFurniture: %d\nDate: %s",
        tostring(s.meta.owner or "‑"),
        tostring(s.meta.building_type or "‑"),
        tonumber(s.meta.furniture_count or 0),
        os.date("%c", s.meta.time or 0)
    ) or "No dump loaded."

    return Roact.createElement("ScreenGui",{ResetOnSpawn=false},{
        Toggle = Roact.createElement("TextButton",{
            Text="☰",Font=Enum.Font.GothamBold,TextSize=22,
            BackgroundColor3=Color3.fromRGB(50,50,90),TextColor3=Color3.new(1,1,1),
            Size=UDim2.new(0,36,0,36),Position=UDim2.new(0,10,0,56),
            [Roact.Event.Activated]=function()
                self:setState{shown=not s.shown}
            end
        }),
        Window = Roact.createElement("Frame",{
            Visible=s.shown,Size=UDim2.new(0,430,0,250),
            Position=UDim2.new(0,60,0,60),
            BackgroundColor3=Color3.fromRGB(30,30,30),BorderSizePixel=0,
        },{
            Roact.createElement("UICorner",{CornerRadius=UDim.new(0,10)}),

            Title = Roact.createElement("TextLabel",{
                Text="Replicate House (URL)",Font=Enum.Font.GothamBold,TextSize=22,
                BackgroundTransparency=1,TextColor3=Color3.new(1,1,1),
                Size=UDim2.new(1,-20,0,28),Position=UDim2.new(0,10,0,8),
                TextXAlignment=Enum.TextXAlignment.Left,
            }),

            UrlBox = Roact.createElement("TextBox",{
                PlaceholderText="https://…/dump_house_*.json",
                Text=s.url,ClearTextOnFocus=false,
                Font=Enum.Font.Code,TextSize=14,
                BackgroundColor3=Color3.fromRGB(45,45,60),TextColor3=Color3.new(1,1,1),
                Size=UDim2.new(1,-20,0,28),Position=UDim2.new(0,10,0,38),
                [Roact.Change.Text]=function(r) self:setState{url=r.Text} end,
            },{Roact.createElement("UICorner",{CornerRadius=UDim.new(0,4)})}),

            Status = Roact.createElement("TextLabel",{
                Text=s.status,Font=Enum.Font.Gotham,TextSize=14,
                BackgroundTransparency=1,TextColor3=Color3.fromRGB(200,200,200),
                Size=UDim2.new(1,-20,0,18),Position=UDim2.new(0,10,0,70),
                TextXAlignment=Enum.TextXAlignment.Left,
            }),

            ProgBG = Roact.createElement("Frame",{
                Size=UDim2.new(1,-20,0,10),Position=UDim2.new(0,10,0,90),
                BackgroundColor3=Color3.fromRGB(55,55,55),BorderSizePixel=0,
            },{
                Fill = Roact.createElement("Frame",{
                    Size=UDim2.new(pct,0,1,0),
                    BackgroundColor3=Color3.fromRGB(60,120,200),BorderSizePixel=0,
                })
            }),

            Info = Roact.createElement("TextLabel",{
                Text=metaTxt,Font=Enum.Font.Gotham,TextSize=14,
                BackgroundColor3=Color3.fromRGB(45,45,45),TextColor3=Color3.new(1,1,1),
                TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,
                Size=UDim2.new(1,-20,1,-140),Position=UDim2.new(0,10,0,110),
                BorderSizePixel=0,
            },{Roact.createElement("UICorner",{CornerRadius=UDim.new(0,6)})}),

            BtnLoad = Roact.createElement("TextButton",{
                Text=s.downloading and"Loading…" or"Load JSON",
                Font=Enum.Font.GothamBold,TextSize=18,
                BackgroundColor3=Color3.fromRGB(80,150,90),TextColor3=Color3.new(1,1,1),
                Size=UDim2.new(0.48,-12,0,36),Position=UDim2.new(0,10,1,-46),
                AutoButtonColor=not s.downloading,
                [Roact.Event.Activated]=function()
                    if s.downloading then return end
                    local url=s.url
                    if not url:match("^https?://") then
                        self:setState{status="❌ Invalid URL."};return
                    end
                    self:setState{downloading=true,status="Downloading…"}
                    task.spawn(function()
                        local ok, body = pcall(httpFetch, url)
                        if not ok then
                            self:setState{status="❌ "..tostring(body),downloading=false};return
                        end
                        local ok2, dump = pcall(HttpService.JSONDecode,HttpService,body)
                        if not ok2 then
                            self:setState{status="❌ Malformed JSON",downloading=false};return
                        end
                        self.dumpLoaded = dump
                        local h = dump.house or {}
                        self:setState{
                            downloading=false,status="JSON OK",
                            meta={
                                owner           = h.player or h.owner or "?",
                                building_type   = h.building_type or "?",
                                furniture_count = dump.furniture_count or #(dump.furniture or {}),
                                time            = dump.time,
                            },
                            prog=0,total=1
                        }
                    end)
                end
            }),

            BtnRep = Roact.createElement("TextButton",{
                Text=s.replicating and"Replicating…" or"Replicate",
                Font=Enum.Font.GothamBold,TextSize=18,
                BackgroundColor3=Color3.fromRGB(60,120,200),TextColor3=Color3.new(1,1,1),
                Size=UDim2.new(0.48,-12,0,36),Position=UDim2.new(0.52,2,1,-46),
                AutoButtonColor=not s.replicating,
                [Roact.Event.Activated]=function()
                    if self.dumpLoaded and not s.replicating then
                        local total = self.dumpLoaded.furniture_count or #(self.dumpLoaded.furniture or {})
                        self:setState{replicating=true,status="Replicating…",prog=0,total=total}
                        replicateHouse(self.dumpLoaded,function(txt)
                            self:setState{status=txt,replicating=false}
                        end)
                    end
                end
            }),
        })
    })
end

Roact.mount(Roact.createElement(Ui), LP:WaitForChild("PlayerGui"))
--═════════════════════════════════════════════════════════════════════
