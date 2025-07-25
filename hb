-- DumpHouseInfo.lua
-- Vuelca TODA la información del interior de la casa y cada mueble.
-- Genera 2 JSON + UI con último volcado.

local RS        = game:GetService("ReplicatedStorage")
local Players   = game:GetService("Players")
local LP        = Players.LocalPlayer
local HttpService = game:GetService("HttpService")

local Fsys                 = require(RS:WaitForChild("Fsys"))
local load                 = Fsys.load
local Roact                = load("Roact")

local ClientData            = load("ClientData")
local InteriorsM            = load("InteriorsM")
local FurnitureDB           = load("FurnitureDB")
local FurnitureModelTracker = load("FurnitureModelTracker")

--------------------------------------------------------------------
-- Helpers básicos
--------------------------------------------------------------------
local function safeSerializeCF(cf)
	if typeof(cf) == "CFrame" then
		local p = cf.Position
		local look = (cf - cf.Position).LookVector
		return { __type="CFrame", pos={p.X,p.Y,p.Z}, look={look.X,look.Y,look.Z} }
	end
	return cf
end

local function serializeColor(color, includeHex)
	if typeof(color) == "Color3" then
		local r0,g0,b0 = color.R,color.G,color.B
		local r = math.clamp(r0,0,1)
		local g = math.clamp(g0,0,1)
		local b = math.clamp(b0,0,1)
		local out = { __type="Color3", r=r0, g=g0, b=b0 }
		if includeHex then
			out.hex = string.format("%02X%02X%02X", math.floor(r*255+0.5), math.floor(g*255+0.5), math.floor(b*255+0.5))
			out.clamped = (r~=r0 or g~=g0 or b~=b0) or nil
		end
		return out
	end
	return color
end

local MAX_DEPTH = 5
local function serializeValue(v, ctx, depth)
	depth = depth or 0
	local visited = ctx.visited
	local includeHex = ctx.includeHex
	if depth > MAX_DEPTH then
		return {__truncated=true, type=typeof(v)}
	end
	local t = typeof(v)
	if t == "number" or t == "string" or t == "boolean" or t == "nil" then
		return v
	elseif t == "Color3" then
		return serializeColor(v, includeHex)
	elseif t == "CFrame" then
		return safeSerializeCF(v)
	elseif t == "Vector3" then
		return {__type="Vector3", x=v.X, y=v.Y, z=v.Z}
	elseif t == "ColorSequence" then
		local out = {__type="ColorSequence", keypoints={}}
		for _,kp in ipairs(v.Keypoints) do
			table.insert(out.keypoints, {time=kp.Time, value=serializeColor(kp.Value, includeHex)})
		end
		return out
	elseif t == "NumberSequence" then
		local out = {__type="NumberSequence", keypoints={}}
		for _,kp in ipairs(v.Keypoints) do
			table.insert(out.keypoints, {time=kp.Time, value=kp.Value})
		end
		return out
	elseif t == "Instance" then
		return {__type="Instance", class=v.ClassName, name=v.Name, fullName=v:GetFullName()}
	elseif t == "table" then
		if visited.map[v] then
			return {__ref = visited.map[v]}
		end
		visited.count += 1
		local id = "tbl_"..visited.count
		visited.map[v] = id
		local out = {__id=id}
		for k,val in pairs(v) do
			out[tostring(k)] = serializeValue(val, ctx, depth+1)
		end
		return out
	end
	return tostring(v)
end

local function serializeModel(model, ctx)
	if not model then return nil end
	local info = { name=model.Name, fullName=model:GetFullName(), attributes={}, children={} }
	for a,v in pairs(model:GetAttributes()) do
		info.attributes[a] = serializeValue(v, ctx)
	end
	for _,desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(info.children,{
				name=desc.Name,class=desc.ClassName,
				size={desc.Size.X,desc.Size.Y,desc.Size.Z},
				color=serializeColor(desc.Color, ctx.includeHex),
				transparency=desc.Transparency,anchored=desc.Anchored,
				cframe=safeSerializeCF(desc.CFrame)
			})
		end
	end
	return info
end

local function waitForHouseInterior(timeout)
	local t0 = os.clock()
	while true do
		local interior = ClientData.get("house_interior")
		local loc = InteriorsM.get_current_location()
		if interior and loc and loc.destination_id == "housing" then
			return interior
		end
		if timeout and os.clock() - t0 > timeout then
			return nil
		end
		task.wait(0.2)
	end
end

local function sanitize(str)
	str = tostring(str or "unknown")
	str = str:gsub("[^%w_%-]", "_")
	return str
end

--------------------------------------------------------------------
-- Dump principal (includeHex true/false)
--------------------------------------------------------------------
local function buildDump(includeHex)
	local ctx = {visited={map={},count=0}, includeHex=includeHex}
	local interior = ClientData.get("house_interior")
	if not interior then
		return {error="No hay interior cargado."}
	end

	local houseInfo = {}
	for k,v in pairs(interior) do
		if k ~= "furniture" then
			houseInfo[k] = serializeValue(v, ctx)
		end
	end

	local addons = {}
	if interior.active_addons then
		for _,name in ipairs(interior.active_addons) do addons[name]=true end
	elseif interior.addons then
		for name,enabled in pairs(interior.addons) do if enabled then addons[name]=true end end
	end
	houseInfo.active_addons_resolved = addons

	local furnitureDump = {}
	for unique,data in pairs(interior.furniture or {}) do
		local dbEntry = FurnitureDB[data.id]
		local model = FurnitureModelTracker.get_furniture_by_unique(unique)

		local dbSerialized
		if dbEntry then
			dbSerialized = {}
			for k,v in pairs(dbEntry) do
				dbSerialized[k] = serializeValue(v, ctx)
			end
		end

		local entry = {
			unique=unique,
			furniture_data={
				id=data.id,
				cframe=serializeValue(data.cframe, ctx),
				scale =serializeValue(data.scale, ctx),
				colors=serializeValue(data.colors, ctx),
				mutated=data.mutated,
			},
			db=dbSerialized,
			model=serializeModel(model, ctx),
		}
		for k,v in pairs(data) do
			if entry.furniture_data[k]==nil then
				entry.furniture_data[k]=serializeValue(v, ctx)
			end
		end
		table.insert(furnitureDump, entry)
	end
	table.sort(furnitureDump,function(a,b)return tostring(a.furniture_data.id)<tostring(b.furniture_data.id) end)

	local loc = InteriorsM.get_current_location()
	local locationDump
	if loc then
		locationDump = {
			destination_id = loc.destination_id,
			player = tostring(loc.player),
		}
	end

	return {
		time=os.time(),
		location=locationDump,
		house=houseInfo,
		furniture_count=#furnitureDump,
		furniture=furnitureDump
	}
end

--------------------------------------------------------------------
-- Guardado
--------------------------------------------------------------------
local function saveToPlayerGui(name,jsonText)
	local pg = LP:WaitForChild("PlayerGui")
	local folder = pg:FindFirstChild("HouseDump")
	if not folder then
		folder = Instance.new("Folder"); folder.Name="HouseDump"; folder.Parent=pg
	end
	local sv = Instance.new("StringValue")
	sv.Name = name
	if #jsonText <= 50000 then
		local ok,err = pcall(function() sv.Value = jsonText end)
		if not ok then
			warn("[DumpHouse] No se pudo asignar Value (JSON grande):",err)
			sv.Value = "[JSON demasiado grande]"
		end
	else
		sv.Value="[JSON demasiado grande ("..#jsonText..")]"
	end
	sv.Parent = folder
	return sv
end

local function saveToDisk(filename,jsonText)
	if not writefile then
		warn("[DumpHouse] writefile no disponible.")
		return false
	end
	if makefolder and isfolder and not isfolder("HouseDumps") then pcall(makefolder,"HouseDumps") end
	local path="HouseDumps/"..filename
	local ok,err = pcall(function() writefile(path,jsonText) end)
	if ok then
		print("[DumpHouse] Guardado "..path)
	else
		warn("[DumpHouse] Error guardando:",err)
	end
	return ok
end

--------------------------------------------------------------------
-- Evento global para la UI
--------------------------------------------------------------------
if not _G.__DumpHouseChangedEvent then
	_G.__DumpHouseChangedEvent = Instance.new("BindableEvent")
end

--------------------------------------------------------------------
-- DumpHouse() público
--------------------------------------------------------------------
function DumpHouse()
	local interior = ClientData.get("house_interior")
	local loc = InteriorsM.get_current_location()
	if not interior or not loc then
		warn("[DumpHouse] Casa no cargada.")
		return
	end

	-- Propietario de la casa
	local ownerName = "unknown"
	if loc.player then
		if typeof(loc.player)=="Instance" and loc.player:IsA("Player") then
			ownerName = loc.player.Name
		else
			ownerName = tostring(loc.player)
		end
	end

	-- building_type
	local houseType = interior.building_type or interior.house_kind or interior.houseType or interior.kind or interior.id or "unknown"

	ownerName = sanitize(ownerName)
	houseType = sanitize(houseType)
	local dateStr = os.date("%Y%m%d_%H%M%S")

	-- dumps
	local dumpBasic = buildDump(false)
	local dumpExtended = buildDump(true)

	local okB,jsonB = pcall(function() return HttpService:JSONEncode(dumpBasic) end)
	local okE,jsonE = pcall(function() return HttpService:JSONEncode(dumpExtended) end)
	if not okB then warn("[DumpHouse] Error JSON básico:",jsonB) return end
	if not okE then warn("[DumpHouse] Error JSON extendido:",jsonE) return end

	print("===== DUMP CASA (BÁSICO) =====")
	print(jsonB:sub(1,5000))

	local baseFile = string.format("dump_house_%s_%s_%s.json", ownerName, houseType, dateStr)
	local extFile  = string.format("dump_house_%s_%s_%s_withhex.json", ownerName, houseType, dateStr)

	saveToPlayerGui("DumpBasic_"..dateStr, jsonB)
	saveToPlayerGui("DumpExtended_"..dateStr, jsonE)
	saveToDisk(baseFile,jsonB)
	saveToDisk(extFile,jsonE)

	if setclipboard then pcall(setclipboard,jsonB) end

	_G.__LAST_HOUSE_DUMP = {
		time=os.time(),
		date=dateStr,
		owner=ownerName,
		building_type=houseType,
		furniture_count=dumpBasic.furniture_count,
		file_basic=baseFile,
		file_ext=extFile,
	}
	_G.__DumpHouseChangedEvent:Fire(_G.__LAST_HOUSE_DUMP)

	print("[DumpHouse] Listo.")
	return dumpBasic,dumpExtended
end

--------------------------------------------------------------------
-- UI (Roact)
--------------------------------------------------------------------
local App = Roact.Component:extend("DumpHouseApp")

function App:init()
	self.state = {
		showUI=true,
		last=_G.__LAST_HOUSE_DUMP,
		status="Esperando..."
	}
	self.conn = _G.__DumpHouseChangedEvent.Event:Connect(function(info)
		self:setState({last=info,status="Último dump OK"})
	end)
end

function App:willUnmount()
	if self.conn then self.conn:Disconnect() end
end

function App:render()
	local s = self.state
	local last = s.last
	local infoText
	if last then
		infoText = string.format(
			"Owner: %s\nTipo casa: %s\nMuebles: %d\nFecha: %s\nArchivo básico: %s\nArchivo hex: %s",
			last.owner, last.building_type, last.furniture_count or 0, last.date,
			last.file_basic or "-", last.file_ext or "-"
		)
	else
		infoText = "Todavía no se ha hecho ningún volcado."
	end

	local ToggleButton = Roact.createElement("TextButton",{
		Text="☰",Font=Enum.Font.GothamBold,TextSize=22,
		BackgroundColor3=Color3.fromRGB(50,50,90),TextColor3=Color3.new(1,1,1),
		Size=UDim2.new(0,36,0,36),Position=UDim2.new(0,10,0,56),ZIndex=5,
		[Roact.Event.Activated]=function() self:setState({showUI=not s.showUI}) end,
	})

	local FrameMain = Roact.createElement("Frame",{
		Visible=s.showUI,
		Size=UDim2.new(0,420,0,250),
		Position=UDim2.new(0,60,0,60),
		BackgroundColor3=Color3.fromRGB(30,30,30),BorderSizePixel=0,
	},{
		UICorner = Roact.createElement("UICorner",{CornerRadius=UDim.new(0,10)}),
		Title = Roact.createElement("TextLabel",{
			Text="House Dump",Font=Enum.Font.GothamBold,TextSize=22,
			BackgroundTransparency=1,TextColor3=Color3.new(1,1,1),
			Size=UDim2.new(1,-20,0,30),Position=UDim2.new(0,10,0,8),
			TextXAlignment=Enum.TextXAlignment.Left,
		}),
		Status = Roact.createElement("TextLabel",{
			Text=s.status,Font=Enum.Font.Gotham,TextSize=14,
			BackgroundTransparency=1,TextColor3=Color3.fromRGB(200,200,200),
			Size=UDim2.new(1,-20,0,16),Position=UDim2.new(0,10,0,40),
			TextXAlignment=Enum.TextXAlignment.Left,
		}),
		InfoBox = Roact.createElement("TextLabel",{
			Text=infoText,Font=Enum.Font.Gotham,TextSize=14,
			BackgroundColor3=Color3.fromRGB(45,45,45),TextColor3=Color3.new(1,1,1),
			TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,
			Size=UDim2.new(1,-20,1,-110),Position=UDim2.new(0,10,0,60),
			BorderSizePixel=0,
		},{
			UICorner=Roact.createElement("UICorner",{CornerRadius=UDim.new(0,6)}),
			Padding=Roact.createElement("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8)})
		}),
		DumpBtn = Roact.createElement("TextButton",{
			Text="Dump now",Font=Enum.Font.GothamBold,TextSize=18,
			BackgroundColor3=Color3.fromRGB(80,150,90),TextColor3=Color3.new(1,1,1),
			BorderSizePixel=0,Size=UDim2.new(1,-20,0,36),Position=UDim2.new(0,10,1,-44),
			[Roact.Event.Activated]=function()
				self:setState({status="Generando..."})
				task.spawn(function()
					local ok = pcall(DumpHouse)
					if not ok then
						self:setState({status="❌ Error al generar dump"})
					end
				end)
			end
		}),
	})

	return Roact.createElement("ScreenGui",{ResetOnSpawn=false},{
		Toggle=ToggleButton,
		Main=FrameMain
	})
end

Roact.mount(Roact.createElement(App), LP:WaitForChild("PlayerGui"))

--------------------------------------------------------------------
-- Auto‑ejecución inicial
--------------------------------------------------------------------
task.spawn(function()
	local interior = waitForHouseInterior(30)
	if not interior then
		warn("[DumpHouse] No se cargó la casa en 30s.")
		return
	end
	print("[DumpHouse] Casa detectada; generando volcado...")
	DumpHouse()
end)

-- Llamar manualmente: DumpHouse()
