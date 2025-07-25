--═════════════════════════════════════════════════════════════════
--  ReplicateHouseFromURL.lua  –  versión con proxy HTTP inteligente
--═════════════════════════════════════════════════════════════════

-------------------------- ajustes de rutas y tiempos --------------------------
local ROUTE_ENTER_EDIT_MODE = "HousingAPI/EnterEditMode"
local ROUTE_EXIT_EDIT_MODE  = "HousingAPI/ExitEditMode"
local ROUTE_PLACE_FURNITURE = "HousingAPI/PlaceFurniture"
local ROUTE_SET_TEXTURE     = "HousingAPI/SetRoomTexture"
local ROUTE_MODIFY_ADDONS   = "HousingAPI/ModifyHouseAddons"

local BATCH_SIZE   = 10      -- muebles por lote
local WAIT_BATCH   = 0.12    -- pausa entre lotes
local WAIT_TEXTURE = 0.05    -- pausa texturas / add‑ons
--------------------------------------------------------------------------------

local RS, Players = game:GetService("ReplicatedStorage"), game:GetService("Players")
local LP          = Players.LocalPlayer
local HttpService = game:GetService("HttpService")

------------------------------ Fsys / Roact stack ------------------------------
local Fsys  = require(RS:WaitForChild("Fsys"))
local load  = Fsys.load
local Roact = load("Roact")
local RouterClient = load("RouterClient")
--------------------------------------------------------------------------------

--═════════════════════════════════  HELPERS  ══════════════════════════════════
--------------------------------- remotos housing ------------------------------
local function remote(route)
   local r = RouterClient.get(route)
   if not r then warn("[Replicate] Remote '"..route.."' no encontrado") end
   return r
end
local function call(r, ...)
   if not r then return false, "remote nil" end
   local fn = r.InvokeServer or r.FireServer
   if not fn then return false, "sin método Invoke/Fire" end
   return pcall(fn, r, ...)
end
local function enterEdit() call(remote(ROUTE_ENTER_EDIT_MODE)) end
local function exitEdit()  call(remote(ROUTE_EXIT_EDIT_MODE )) end

------------------------------------ HTTP proxy --------------------------------
--   Devuelve contenido (string) ó lanza error comprensible
local httpProxyRF  -- RemoteFunction (se crea lazy)
local function getProxy()
   if httpProxyRF then return httpProxyRF end
   httpProxyRF = Instance.new("RemoteFunction")
   httpProxyRF.Name = "__ReplicateHttpProxy"
   httpProxyRF.Parent = RS

   -- pequeña implementación del lado servidor
   httpProxyRF.OnServerInvoke = function(_, url)
      local ok, res = pcall(HttpService.GetAsync, HttpService, url, false)
      if ok then return true, res else return false, tostring(res) end
   end
   return httpProxyRF
end

local function httpFetch(url)
   -------------------------------- executor request
   local req = (syn and syn.request)
            or (http and http.request)
            or request
   if req then
      local r = req{Url=url, Method="GET", Headers={}}
      if r and r.StatusCode == 200 then return r.Body end
      error(("HTTP %s"):format(r and r.StatusCode or "?"))
   end
   -------------------------------- executor httpget
   if game.HttpGet then
      local ok, body = pcall(game.HttpGet, game, url)
      if ok then return body end
      -- si falla, continuamos al proxy
   end
   -------------------------------- proxy servidor
   local ok, bodyOrErr = getProxy():InvokeServer(url)
   if ok then return bodyOrErr end
   error(bodyOrErr)
end
--══════════════════════════════════════════════════════════════════════════════

--══════════════════════  eventos de progreso (UI)  ════════════════════════════
local DownloadEvent  = Instance.new("BindableEvent")
local ReplicateEvent = Instance.new("BindableEvent")

--══════════════════════  rutina principal de réplica  ═════════════════════════
local function replicateHouse(dump, setStatus)
   task.spawn(function()
      setStatus("Entering edit mode…")
      enterEdit()

      -- texturas
      local setTexR = remote(ROUTE_SET_TEXTURE)
      if dump.house and dump.house.textures then
         for roomId, room in pairs(dump.house.textures) do
            for texType, texId in pairs(room) do
               call(setTexR, roomId, texType, texId)
               task.wait(WAIT_TEXTURE)
            end
         end
      end

      -- add‑ons
      if dump.house and dump.house.active_addons_resolved then
         call(remote(ROUTE_MODIFY_ADDONS),
              dump.house.house_id or 0,
              dump.house.active_addons_resolved)
         task.wait(WAIT_TEXTURE)
      end

      -- muebles
      local placeR = remote(ROUTE_PLACE_FURNITURE)
      local list   = dump.furniture or {}
      for i, entry in ipairs(list) do
         local f = entry.furniture_data
         call(placeR, {
            id     = f.id,
            cframe = f.cframe,
            scale  = f.scale,
            colors = f.colors,
         })
         if i % BATCH_SIZE == 0 then task.wait(WAIT_BATCH) end
         ReplicateEvent:Fire(i, #list)
      end

      exitEdit()
      setStatus("✅ Replicación completada")
   end)
end

--════════════════════════════════ UI  ═════════════════════════════════════════
local Ui = Roact.Component:extend("ReplicateUi")

function Ui:init()
   self.state = {
      show        = true,
      url         = "",
      status      = "Waiting URL…",
      meta        = nil,
      prog        = 0,
      total       = 1,
      downloading = false,
      replicating = false,
   }

   self.dlConn = DownloadEvent.Event:Connect(function(done,total)
      self:setState{status=("Downloading %d/%d KB…"):format(done,total)}
   end)
   self.repConn = ReplicateEvent.Event:Connect(function(done,total)
      self:setState{
         prog   = done,
         total  = total,
         status = ("Replicating %d/%d…"):format(done,total)
      }
   end)
end
function Ui:willUnmount()
   self.dlConn:Disconnect()
   self.repConn:Disconnect()
end

function Ui:render()
   local s = self.state
   local pct = s.prog / math.max(1, s.total)
   local meta = s.meta and string.format(
      "Owner: %s\nType: %s\nFurniture: %d\nDate: %s",
      s.meta.owner or "‑",
      s.meta.building_type or "‑",
      s.meta.furniture_count or 0,
      os.date("%c", s.meta.time or 0)
   ) or "No dump loaded."

   return Roact.createElement("ScreenGui",{ResetOnSpawn=false},{

      Toggle = Roact.createElement("TextButton",{
         Text="☰", Font=Enum.Font.GothamBold, TextSize=22,
         BackgroundColor3=Color3.fromRGB(50,50,90), TextColor3=Color3.new(1,1,1),
         Size=UDim2.new(0,36,0,36), Position=UDim2.new(0,10,0,56),
         [Roact.Event.Activated]=function() self:setState{show=not s.show} end,
      }),

      Window = Roact.createElement("Frame",{
         Visible=s.show, Size=UDim2.new(0,430,0,250),
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
            Text=s.url, Font=Enum.Font.Code, TextSize=14,
            ClearTextOnFocus=false,
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
            Text=meta, Font=Enum.Font.Gotham, TextSize=14,
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
               local url = s.url
               if not url:match("^https?://") then
                  self:setState{status="❌ Invalid URL."}; return
               end
               self:setState{downloading=true,status="Downloading…",prog=0,total=1}
               task.spawn(function()
                  local ok, body = pcall(httpFetch, url)
                  if not ok then
                     self:setState{status="❌ "..tostring(body),downloading=false}; return
                  end
                  local ok2, dump = pcall(HttpService.JSONDecode,HttpService,body)
                  if not ok2 then
                     self:setState{status="❌ Malformed JSON",downloading=false}; return
                  end
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
                  self:setState{replicating=true,status="Replicating…",prog=0,total=total}
                  replicateHouse(self.dumpLoaded,function(txt) self:setState{status=txt} end)
               end
            end,
         }),
      }),
   })
end

Roact.mount(Roact.createElement(Ui), LP:WaitForChild("PlayerGui"))
