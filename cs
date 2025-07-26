-- DumpHouseInfoStreaming.lua V2
-- Streaming dump con precisión absoluta:
--  • CFrame basis_v2
--  • world_cf + interior_root_cf + local_cf (posición exacta relativa al interior)
--  • euler/axis-angle redundantes
--  • colores normalizados (y hex en versión extendida)

---------------------------------------------------------------------
-- Servicios / módulos
---------------------------------------------------------------------
local RS          = game:GetService("ReplicatedStorage")
local Players     = game:GetService("Players")
local LP          = Players.LocalPlayer
local HttpService = game:GetService("HttpService")

-- ► CARGADOR FSYS SEGURO
local FsysModule = require(RS:WaitForChild("Fsys"))
local FSLOAD     = assert(FsysModule and FsysModule.load, "[DumpHouse] Fsys.load es nil")
local function Load(name)
	local ok, mod = pcall(FSLOAD, name)
	assert(ok and mod ~= nil, ("[DumpHouse] No se pudo cargar '%s'"):format(tostring(name)))
	return mod
end

local Roact                 = Load("Roact")
local ClientData            = Load("ClientData")
local InteriorsM            = Load("InteriorsM")
local FurnitureDB           = Load("FurnitureDB")
local FurnitureModelTracker = Load("FurnitureModelTracker")

local HouseClient
pcall(function() HouseClient = Load("HouseClient") end)

---------------------------------------------------------------------
-- Utilidades de CFrame / Color
---------------------------------------------------------------------
local function serializeBasis(cf)
	-- basis v2 + axis/angle (redundante)
	local p = cf.Position
	local r = cf.RightVector
	local u = cf.UpVector
	local l = cf.LookVector
	local axis, angle = cf:ToAxisAngle()
	return {
		__type="CFrame",
		pos   = {p.X,p.Y,p.Z},
		right = {r.X,r.Y,r.Z},
		up    = {u.X,u.Y,u.Z},
		look  = {l.X,l.Y,l.Z},
		axis  = {axis.X,axis.Y,axis.Z},
		angle = angle,
		__v   = 2
	}
end

local function colorNoHex(c)  return {__type="Color3", r=c.R, g=c.G, b=c.B} end
local function colorWithHex(c)
	local r,g,b = c.R,c.G,c.B
	return {
		__type="Color3",
		r=r,g=g,b=b,
		hex=string.format("%02X%02X%02X", math.floor(r*255+0.5), math.floor(g*255+0.5), math.floor(b*255+0.5))
	}
end

local function serializeValue(v, includeHex, depth, seen)
	depth = depth or 0
	if depth > 4 then return {__truncated=true,type=typeof(v)} end
	local t = typeof(v)
	if t=="number" or t=="string" or t=="boolean" or t=="nil" then return v end
	if t=="Color3" then return includeHex and colorWithHex(v) or colorNoHex(v) end
	if t=="Vector3" then return {__type="Vector3",x=v.X,y=v.Y,z=v.Z} end
	if t=="CFrame" then return serializeBasis(v) end
	if t=="ColorSequence" then
		local out={__type="ColorSequence",keypoints={}}
		for _,kp in ipairs(v.Keypoints) do
			table.insert(out.keypoints,{time=kp.Time,value=serializeValue(kp.Value,includeHex,depth+1,seen)})
		end
		return out
	end
	if t=="NumberSequence" then
		local out={__type="NumberSequence",keypoints={}}
		for _,kp in ipairs(v.Keypoints) do
			table.insert(out.keypoints,{time=kp.Time,value=kp.Value})
		end
		return out
	end
	if t=="Instance" then
		return {__type="Instance",class=v.ClassName,name=v.Name,fullName=v:GetFullName()}
	end
	if t=="table" then
		seen = seen or {}
		if seen[v] then return {__ref="1"} end
		seen[v]=true
		local out={}
		for k,val in pairs(v) do out[tostring(k)] = serializeValue(val, includeHex, depth+1, seen) end
		return out
	end
	return tostring(v)
end

---------------------------------------------------------------------
-- Detección del root del interior y utilidades de espacio
---------------------------------------------------------------------
local function tryCall(mod, method, ...)
	if not mod then return nil end
	local f = mod[method]
	if type(f) ~= "function" then return nil end
	local ok, res = pcall(f, ...)
	if ok then return res end
	return nil
end

local function findInteriorRootModel()
	-- 1) Si InteriorsM expone un modelo/instancia, úsalo
	local loc = tryCall(InteriorsM, "get_current_location")
	if type(loc)=="table" then
		if typeof(loc.model)=="Instance" then return loc.model end
		if typeof(loc.container)=="Instance" then return loc.container end
	end
	-- 2) Buscar por algún mueble y subir hasta el modelo padre “grande”
	local anyUnique
	local interior = ClientData.get("house_interior")
	if interior and interior.furniture then
		for u,_ in pairs(interior.furniture) do anyUnique=u; break end
	end
	if anyUnique then
		local mdl = FurnitureModelTracker.get_furniture_by_unique(anyUnique)
		local top = mdl
		while top and top.Parent and top.Parent ~= workspace do
			top = top.Parent
		end
		if top then return top end
	end
	-- 3) Fallback: nil (se asumirá mundo)
	return nil
end

local function getPivotCF(inst)
	if not inst then return nil end
	if inst:IsA("Model") then
		local ok, cf = pcall(inst.GetPivot, inst)
		if ok then return cf end
	end
	if inst:IsA("BasePart") then
		return inst.CFrame
	end
	return nil
end

---------------------------------------------------------------------
-- Captura del modelo con espacios world/local
---------------------------------------------------------------------
local function captureFurnitureEntry(unique, data, includeHex, interiorRootCF)
	local info = {
		unique = unique,
		furniture_data = {},  -- se rellena más abajo
		db = nil,
		space = {},           -- NUEVO: world/local
		model = nil,          -- estructura del modelo con basis v2
	}

	-- Modelo y pivotes
	local model  = FurnitureModelTracker.get_furniture_by_unique(unique)
	local pivot  = model and getPivotCF(model) or nil
	local world_cf = pivot or data.cframe -- si no hay modelo, usamos su cframe del estado
	local local_cf = interiorRootCF and (interiorRootCF:ToObjectSpace(world_cf)) or nil

	info.space = {
		world_cf         = serializeBasis(world_cf),
		interior_root_cf = interiorRootCF and serializeBasis(interiorRootCF) or nil,
		local_cf         = local_cf and serializeBasis(local_cf) or nil,
		-- Yaw/Pitch/Roll (en grados) respecto al mundo para inspección
		euler_deg = (function()
			local _, y, _ = world_cf:ToOrientation()
			local rx, ry, rz = world_cf:ToEulerAnglesXYZ()
			return { x = math.deg(rx), y = math.deg(ry), z = math.deg(rz) }
		end)()
	}

	-- Datos comunes del mueble tal como están en ClientData
	local fd = info.furniture_data
	for k,v in pairs(data) do
		fd[k] = serializeValue(v, includeHex) -- incluye colors/cframe/scale/etc
	end

	-- DB (opcional)
	local db = FurnitureDB[data.id]
	if db then
		local out = {}
		for k,v in pairs(db) do out[k] = serializeValue(v, includeHex) end
		info.db = out
	end

	-- Modelo físico (descendientes/partes) con basis v2
	local function captureModelRaw(modelX)
		if not modelX then return nil end
		local m = {
			name = modelX.Name,
			fullName = modelX:GetFullName(),
			attributes = modelX:GetAttributes(),
			children = {},
		}
		for _,d in ipairs(modelX:GetDescendants()) do
			if d:IsA("BasePart") then
				table.insert(m.children,{
					name = d.Name,
					class = d.ClassName,
					size  = {d.Size.X,d.Size.Y,d.Size.Z},
					color = includeHex and colorWithHex(d.Color) or colorNoHex(d.Color),
					transparency = d.Transparency,
					anchored     = d.Anchored,
					cframe       = serializeBasis(d.CFrame),
				})
			end
		end
		return m
	end
	info.model = captureModelRaw(model)

	return info
end

---------------------------------------------------------------------
-- Guardado incremental (archivos + GUI streaming)
---------------------------------------------------------------------
local hasWrite   = typeof(writefile)  == "function"
local hasAppend  = typeof(appendfile) == "function"

local function ensureFolder()
	local pg = LP:WaitForChild("PlayerGui")
	local folder = pg:FindFirstChild("HouseDump")
	if not folder then
		folder = Instance.new("Folder"); folder.Name = "HouseDump"; folder.Parent = pg
	end
	return folder
end

local function newGuiStreamSub(namePrefix)
	local root = ensureFolder()
	local sub = Instance.new("Folder"); sub.Name = namePrefix; sub.Parent = root
	return sub
end

local function guiStreamAppend(sub, buffers, text)
	local b = buffers.current .. text
	if #b >= buffers.chunkSize then
		local sv = Instance.new("StringValue")
		buffers.index += 1
		sv.Name = "Chunk_"..buffers.index
		sv.Value = b
		sv.Parent = sub
		buffers.current = ""
	else
		buffers.current = b
	end
end

local function guiStreamFlush(sub, buffers)
	if buffers.current ~= "" then
		local sv = Instance.new("StringValue")
		buffers.index += 1
		sv.Name = "Chunk_"..buffers.index
		sv.Value = buffers.current
		sv.Parent = sub
		buffers.current = ""
	end
end

local function openFileStreaming(filename, header)
	if hasWrite then writefile(filename, header) end
	return { filename = filename, useAppend = hasAppend, buffer = header }
end
local function fileAppend(stream, text)
	if stream.useAppend then appendfile(stream.filename, text)
	elseif hasWrite then stream.buffer = stream.buffer .. text end
end
local function fileClose(stream, footer)
	if footer and footer ~= "" then fileAppend(stream, footer) end
	if not stream.useAppend and hasWrite then writefile(stream.filename, stream.buffer) end
end

---------------------------------------------------------------------
-- Eventos UI
---------------------------------------------------------------------
if not _G.__DumpHouseChangedEvent then _G.__DumpHouseChangedEvent = Instance.new("BindableEvent") end
if not _G.__DumpHouseProgressEvent then _G.__DumpHouseProgressEvent = Instance.new("BindableEvent") end

---------------------------------------------------------------------
-- Principal (streaming)
---------------------------------------------------------------------
local DUMP_IN_PROGRESS = false

local function DumpHouse()
	if DUMP_IN_PROGRESS then warn("[DumpHouse] Ya hay un dump en curso."); return end
	local interior = ClientData.get("house_interior")
	local loc = InteriorsM.get_current_location()
	if not interior or not loc then warn("[DumpHouse] Casa no cargada."); return end

	DUMP_IN_PROGRESS = true
	task.spawn(function()
		local t0 = os.clock()
		-- detectar raíz del interior
		local interiorRootModel = findInteriorRootModel()
		local interiorRootCF    = interiorRootModel and getPivotCF(interiorRootModel) or CFrame.new()

		local ownerName = tostring((function()
			if loc and loc.player and typeof(loc.player)=="Instance" and loc.player:IsA("Player") then return loc.player.Name end
			if interior.player and typeof(interior.player)=="Instance" and interior.player:IsA("Player") then return interior.player.Name end
			return "unknown"
		end)()):gsub("[^%w_%-]","_")

		local houseType = tostring(interior.building_type or interior.house_kind or interior.houseType or interior.kind or interior.id or "unknown"):gsub("[^%w_%-]","_")
		local dateStr   = os.date("%Y%m%d_%H%M%S")

		-- muebles ordenados
		local list = {}
		for unique,data in pairs(interior.furniture or {}) do table.insert(list,{unique=unique,data=data}) end
		table.sort(list,function(a,b) return tostring(a.data.id) < tostring(b.data.id) end)
		local total = #list

		-- cabeceras
		local metaBasic = {
			time = os.time(),
			location = { destination_id = loc.destination_id },
			house = serializeValue(interior, false),
			furniture_count = total,
			furniture = "__STREAM__",
			format = { cframe = "basis_v2", space = "world_and_local" },
			interior_root = {
				name = interiorRootModel and interiorRootModel.Name or nil,
				full = interiorRootModel and interiorRootModel:GetFullName() or nil,
				cframe = serializeBasis(interiorRootCF),
			}
		}
		local metaHex = {
			time = metaBasic.time, location = metaBasic.location,
			house = serializeValue(interior, true),
			furniture_count = total, furniture="__STREAM__",
			format = metaBasic.format, interior_root = metaBasic.interior_root
		}

		local function startArray(tbl)
			local clone = {}
			for k,v in pairs(tbl) do if k~="furniture" then clone[k]=v end end
			local json = HttpService:JSONEncode(clone)
			return json:sub(1,#json-1)..',"furniture":['
		end

		local baseFile = string.format("dump_house_%s_%s_%s.json", ownerName, houseType, dateStr)
		local hexFile  = string.format("dump_house_%s_%s_%s_withhex.json", ownerName, houseType, dateStr)

		local headerBasic = startArray(metaBasic)
		local headerHex   = startArray(metaHex)

		local streamBasic = openFileStreaming(baseFile, headerBasic)
		local streamHex   = openFileStreaming(hexFile , headerHex)

		local guiBFolder = newGuiStreamSub("DumpBasic_"..dateStr)
		local guiHFolder = newGuiStreamSub("DumpExtended_"..dateStr)
		local guiB = {current="",index=0,chunkSize=50000}
		local guiH = {current="",index=0,chunkSize=50000}
		guiStreamAppend(guiBFolder, guiB, headerBasic)
		guiStreamAppend(guiHFolder, guiH, headerHex)

		-- recorrer muebles
		local YIELD_EVERY = 25
		for i, it in ipairs(list) do
			local entryBasic = captureFurnitureEntry(it.unique, it.data, false, interiorRootCF)
			local entryHex   = captureFurnitureEntry(it.unique, it.data, true , interiorRootCF)

			local ok1, js1 = pcall(HttpService.JSONEncode, HttpService, entryBasic)
			local ok2, js2 = pcall(HttpService.JSONEncode, HttpService, entryHex)
			if ok1 and ok2 then
				if i>1 then
					fileAppend(streamBasic, ","); fileAppend(streamHex, ",")
					guiStreamAppend(guiBFolder, guiB, ","); guiStreamAppend(guiHFolder, guiH, ",")
				end
				fileAppend(streamBasic, js1); fileAppend(streamHex, js2)
				guiStreamAppend(guiBFolder, guiB, js1); guiStreamAppend(guiHFolder, guiH, js2)
			else
				warn("[DumpHouse] Error codificando entrada "..i)
			end

			if i%YIELD_EVERY==0 then task.wait() end
			_G.__DumpHouseProgressEvent:Fire(i,total)
		end

		-- cerrar
		fileAppend(streamBasic, "]}"); guiStreamAppend(guiBFolder, guiB, "]}")
		fileAppend(streamHex,   "]}"); guiStreamAppend(guiHFolder, guiH, "]}")
		guiStreamFlush(guiBFolder, guiB); guiStreamFlush(guiHFolder, guiH)
		fileClose(streamBasic); fileClose(streamHex)

		if setclipboard then pcall(setclipboard, baseFile) end

		_G.__LAST_HOUSE_DUMP = {
			time=metaBasic.time, date=dateStr,
			owner=ownerName, building_type=houseType,
			furniture_count=total,
			file_basic=baseFile, file_ext=hexFile,
			duration = os.clock()-t0,
			format = metaBasic.format
		}

		DUMP_IN_PROGRESS=false
		_G.__DumpHouseChangedEvent:Fire(_G.__LAST_HOUSE_DUMP)
		print(("[DumpHouse V2] Hecho en %.2fs. Total: %d"):format(os.clock()-t0, total))
	end)
end

_G.DumpHouse = DumpHouse

---------------------------------------------------------------------
-- UI (igual que V1, solo título actualizado)
---------------------------------------------------------------------
local App = Roact.Component:extend("DumpHouseApp")
function App:init()
	self.state={showUI=true,last=_G.__LAST_HOUSE_DUMP,status="Esperando...",progress=0,total=0}
	self.conn1=_G.__DumpHouseChangedEvent.Event:Connect(function(info)
		self:setState({last=info,status="Último dump OK",progress=info.furniture_count,total=info.furniture_count})
	end)
	self.conn2=_G.__DumpHouseProgressEvent.Event:Connect(function(done,total)
		self:setState({status=("Procesando %d/%d..."):format(done,total),progress=done,total=total})
	end)
end
function App:willUnmount() if self.conn1 then self.conn1:Disconnect() end; if self.conn2 then self.conn2:Disconnect() end end
function App:render()
	local s=self.state; local last=s.last
	local infoText = last and string.format(
		"Owner: %s\nTipo casa: %s\nMuebles: %d\nFecha: %s\nDuración: %.2fs\nArchivo básico: %s\nArchivo hex: %s\nFormato: %s/%s",
		last.owner,last.building_type,last.furniture_count or 0,last.date,last.duration or 0,last.file_basic or "-",last.file_ext or "-",
		(last.format and last.format.cframe) or "-", (last.format and last.format.space) or "-"
	) or "Todavía no se ha hecho ningún volcado."
	local pct=(s.total>0) and (s.progress/s.total) or 0
	return Roact.createElement("ScreenGui",{ResetOnSpawn=false},{
		Toggle=Roact.createElement("TextButton",{Text="☰",Font=Enum.Font.GothamBold,TextSize=22,BackgroundColor3=Color3.fromRGB(50,50,90),TextColor3=Color3.new(1,1,1),Size=UDim2.new(0,36,0,36),Position=UDim2.new(0,10,0,56),ZIndex=5,[Roact.Event.Activated]=function() self:setState({showUI=not s.showUI}) end}),
		Main=Roact.createElement("Frame",{Visible=s.showUI,Size=UDim2.new(0,430,0,270),Position=UDim2.new(0,60,0,60),BackgroundColor3=Color3.fromRGB(30,30,30),BorderSizePixel=0},{
			UICorner=Roact.createElement("UICorner",{CornerRadius=UDim.new(0,10)}),
			Title=Roact.createElement("TextLabel",{Text="House Dump (Streaming) V2",Font=Enum.Font.GothamBold,TextSize=22,BackgroundTransparency=1,TextColor3=Color3.new(1,1,1),Size=UDim2.new(1,-20,0,30),Position=UDim2.new(0,10,0,8),TextXAlignment=Enum.TextXAlignment.Left}),
			Status=Roact.createElement("TextLabel",{Text=s.status,Font=Enum.Font.Gotham,TextSize=14,BackgroundTransparency=1,TextColor3=Color3.fromRGB(200,200,200),Size=UDim2.new(1,-20,0,16),Position=UDim2.new(0,10,0,40),TextXAlignment=Enum.TextXAlignment.Left}),
			ProgressBG=Roact.createElement("Frame",{Size=UDim2.new(1,-20,0,12),Position=UDim2.new(0,10,0,60),BackgroundColor3=Color3.fromRGB(50,50,50),BorderSizePixel=0},{
				UICorner=Roact.createElement("UICorner",{CornerRadius=UDim.new(0,4)}),
				Fill=Roact.createElement("Frame",{Size=UDim2.new(pct,0,1,0),BackgroundColor3=Color3.fromRGB(80,150,90),BorderSizePixel=0},{UICorner=Roact.createElement("UICorner",{CornerRadius=UDim.new(0,4)})})
			}),
			InfoBox=Roact.createElement("TextLabel",{Text=infoText,Font=Enum.Font.Gotham,TextSize=14,BackgroundColor3=Color3.fromRGB(45,45,45),TextColor3=Color3.new(1,1,1),TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,Size=UDim2.new(1,-20,1,-140),Position=UDim2.new(0,10,0,80),BorderSizePixel=0},{
				UICorner=Roact.createElement("UICorner",{CornerRadius=UDim.new(0,6)}),
				Padding=Roact.createElement("UIPadding",{PaddingTop=UDim.new(0,6),PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8)})
			}),
			DumpBtn=Roact.createElement("TextButton",{Text="Dump now",Font=Enum.Font.GothamBold,TextSize=18,BackgroundColor3=Color3.fromRGB(80,150,90),TextColor3=Color3.new(1,1,1),BorderSizePixel=0,Size=UDim2.new(1,-20,0,36),Position=UDim2.new(0,10,1,-44),AutoButtonColor=true,[Roact.Event.Activated]=function()
				if not DUMP_IN_PROGRESS then self:setState({status="Preparando...",progress=0,total=0}); DumpHouse() end
			end}),
		})})
end
Roact.mount(Roact.createElement(App), LP:WaitForChild("PlayerGui"))

---------------------------------------------------------------------
-- Auto‑start (opcional)
---------------------------------------------------------------------
task.spawn(function()
	local interior
	local t0=os.clock()
	while not interior and os.clock()-t0<30 do
		interior = ClientData.get("house_interior")
		if not interior then task.wait(0.2) end
	end
	if interior then
		print("[DumpHouse V2] Casa detectada; generando dump…"); DumpHouse()
	else
		warn("[DumpHouse V2] No se cargó la casa en 30s.")
	end
end)
