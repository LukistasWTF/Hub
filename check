-- StarterPlayerScripts/DebugForSaleItems.client.lua
-- Lista los KindDB que están "for sale" + categoría, precio y moneda.

----------------------------------------------------------
-- 1· Localizar ForSaleManager (búsqueda recursiva segura)
----------------------------------------------------------
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function findForSaleModule()
    local found = ReplicatedStorage:FindFirstChild("ForSaleManager", true)
    return (found and found:IsA("ModuleScript")) and found or nil
end

local forSaleModule = findForSaleModule()
if not forSaleModule then
    warn("[ForSaleList] No se encontró ningún ModuleScript llamado 'ForSaleManager'.")
    return
end

local ForSaleM = require(forSaleModule)

----------------------------------------------------------
-- 2· Cargar Fsys y KindDB
----------------------------------------------------------
local Fsys       = require(ReplicatedStorage:WaitForChild("Fsys")).load
local KindDB     = Fsys("KindDB")      -- Diccionario con la info de cada kind

----------------------------------------------------------
-- 3· Helpers para leer categoría y precio de cada entrada
----------------------------------------------------------
local function getCategory(kindEntry)
    -- Ajusta estos nombres si tu estructura es distinta
    return  kindEntry.category
        or kindEntry.kind_group
        or kindEntry.kind_type
        or "Desconocida"
end

local function getCostAndCurrency(kindEntry)
    -- Maneja distintos esquemas posibles de 'cost'
    -- 1) cost = {amount = 500, currency = "bucks"}
    -- 2) cost = 500  (implícitamente bucks)
    -- 3) cost_robux = 199  (para dev‑products en Robux)
    if typeof(kindEntry.cost) == "table" then
        return kindEntry.cost.amount, (kindEntry.cost.currency or "bucks")
    elseif typeof(kindEntry.cost) == "number" then
        return kindEntry.cost, "bucks"
    elseif kindEntry.cost_robux then
        return kindEntry.cost_robux, "robux"
    end
    return "—", "—"
end

----------------------------------------------------------
-- 4· ¿Está el ítem realmente a la venta?
----------------------------------------------------------
local function isActuallyForSale(kindKey: string): boolean
    if ForSaleM.are_all_purchases_disabled() then
        return false
    end
    if ForSaleM.is_item_purchase_disabled(kindKey) then
        return false
    end
    return ForSaleM.is_for_sale(kindKey)
end

----------------------------------------------------------
-- 5· Recorremos KindDB y construimos la tabla de salida
----------------------------------------------------------
local entries = {}

for kindKey, entry in KindDB do
    if isActuallyForSale(kindKey) then
        local price, currency = getCostAndCurrency(entry)
        table.insert(entries, {
            key       = kindKey,
            category  = getCategory(entry),
            price     = price,
            currency  = currency
        })
    end
end

table.sort(entries, function(a, b) return a.key < b.key end)

----------------------------------------------------------
-- 6· Imprimir bonito en Output
----------------------------------------------------------
print("\n=========== ITEMS FOR SALE ===========")
print(string.format("%-30s | %-15s | %-8s | %s", "Key", "Categoría", "Precio", "Moneda"))
print(string.rep("-", 70))
for _, data in ipairs(entries) do
    print(string.format("%-30s | %-15s | %-8s | %s",
        data.key, data.category, tostring(data.price), tostring(data.currency)))
end
print(string.rep("-", 70))
print(("Total: %d items"):format(#entries))
print("======================================\n")
