local Fsys = require(game.ReplicatedStorage:WaitForChild("Fsys"))
local load = Fsys.load
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local ClientStore = load("ClientStore")
local HouseRenderHelper = load("HouseRenderHelper")
local HouseModule = load("HousingClient")

local function createHint(text)
	local hint = Instance.new("Hint")
	hint.Text = text
	hint.Parent = workspace
	Debris:AddItem(hint, 5)
end

local currentHouseId = nil
HouseModule.house_interior_changed:Connect(function()
	local state = ClientStore.store:getState()
	local houseData = state.house_interior

	if not houseData or houseData.house_id == currentHouseId then
		return
	end

	currentHouseId = houseData.house_id

	local owner = houseData.player and houseData.player.Name or "Desconocido"
	createHint("Entraste a la casa de " .. owner)

	task.wait(1)

	local success, err = pcall(function()
		local houseFolder = workspace:FindFirstChild("HouseInteriors")
		if not houseFolder then return end

		for _, blueprint in houseFolder:GetChildren() do
			if blueprint:FindFirstChild("interior") then
				local interior = blueprint.interior

				local muebles = {}
				for _, objeto in pairs(interior.Furniture:GetChildren()) do
					if objeto:IsA("Model") or objeto:IsA("BasePart") then
						table.insert(muebles, objeto.Name)
					end
				end

				createHint("Muebles: " .. table.concat(muebles, ", "))

				local colores = {}
				for _, texture in pairs(interior.Walls:GetDescendants()) do
					if texture:IsA("Texture") then
						local roomName = texture.Name
						local color = texture.Color3
						local hex = string.format("#%02X%02X%02X", color.R * 255, color.G * 255, color.B * 255)
						colores[roomName] = hex
					end
				end

				for room, hex in pairs(colores) do
					createHint("Pared " .. room .. ": " .. hex)
					task.wait(0.2)
				end
			end
		end
	end)

	if not success then
		warn("Error mostrando información de la casa: ", err)
	end
end)
