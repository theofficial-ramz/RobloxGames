-- Sistema raccolta prodotti (server-side completo)
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

print("[Grocery] Sistema raccolta prodotti inizializzato")

-- Configurazione
local PICKUP_RANGE = 8
local PICKUP_HOLD_TIME = 0.5
local MAX_CART_ITEMS = 20
local PRODUCTS_TO_HIGHLIGHT = 5

-- Traccia gli inventari e i prodotti evidenziati
local playerInventories = {}
local highlightedProducts = {}
local playerHighlights = {} -- Traccia gli highlight per ogni player

-- Ottieni inventario player
local function getPlayerInventory(player)
	if not playerInventories[player.UserId] then
		playerInventories[player.UserId] = {}
	end
	return playerInventories[player.UserId]
end

-- Controlla se un player è attaccato al carrello
local function isPlayerAttached(player)
	if not player.Character then return false end
	local root = player.Character:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	return root:FindFirstChild("PlayerCartWeld") ~= nil
end

-- Mostra highlight per un player specifico
local function showHighlightsForPlayer(player)
	if playerHighlights[player.UserId] then return end -- Già mostrati
	
	playerHighlights[player.UserId] = {}
	
	for product, _ in pairs(highlightedProducts) do
		if product and product.Parent then
			local highlight = Instance.new("Highlight")
			highlight.FillColor = Color3.fromRGB(255, 255, 0)
			highlight.OutlineColor = Color3.fromRGB(255, 200, 0)
			highlight.FillTransparency = 0.5
			highlight.OutlineTransparency = 0
			highlight.Parent = product
			
			table.insert(playerHighlights[player.UserId], highlight)
		end
	end
end

-- Nascondi highlight per un player specifico
local function hideHighlightsForPlayer(player)
	if not playerHighlights[player.UserId] then return end
	
	for _, highlight in ipairs(playerHighlights[player.UserId]) do
		if highlight and highlight.Parent then
			highlight:Destroy()
		end
	end
	
	playerHighlights[player.UserId] = nil
end

-- Monitora lo stato di attacco al carrello per ogni player
local function monitorPlayerAttachment(player)
	local wasAttached = false
	
	-- Loop continuo per controllare lo stato
	while player.Parent do
		local isAttached = isPlayerAttached(player)
		
		if isAttached and not wasAttached then
			-- Appena attaccato, mostra highlight
			showHighlightsForPlayer(player)
			wasAttached = true
		elseif not isAttached and wasAttached then
			-- Appena staccato, nascondi highlight
			hideHighlightsForPlayer(player)
			wasAttached = false
		end
		
		task.wait(0.5) -- Controlla ogni mezzo secondo
	end
end

-- Evidenzia prodotti randomici in una shelf
local function highlightRandomProducts(shelf, numToHighlight)
	local allProducts = {}
	
	-- Trova tutti i Model (prodotti) nella shelf, escludi "Shelf" e "Highlight"
	for _, model in ipairs(shelf:GetChildren()) do
		if model:IsA("Model") and model.Name ~= "Shelf" then
			table.insert(allProducts, model)
		end
	end
	
	print("[Grocery] Found", #allProducts, "products in", shelf.Name)
	
	-- Seleziona randomicamente
	numToHighlight = math.min(numToHighlight or PRODUCTS_TO_HIGHLIGHT, #allProducts)
	
	for i = 1, numToHighlight do
		if #allProducts == 0 then break end
		
		local randomIndex = math.random(1, #allProducts)
		local product = table.remove(allProducts, randomIndex)
		
		-- Trova la parte su cui mettere Highlight e ProximityPrompt
		local targetPart = product.PrimaryPart or product:FindFirstChildWhichIsA("BasePart")
		if not targetPart then
			warn("[Grocery] Product senza BasePart:", product.Name)
			continue
		end
		
		-- NON creare Highlight qui, verrà creato dinamicamente per ogni player
		
		-- Crea ProximityPrompt sulla parte
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Pick up"
		prompt.ObjectText = "Product"
		prompt.KeyboardKeyCode = Enum.KeyCode.F
		prompt.HoldDuration = PICKUP_HOLD_TIME
		prompt.MaxActivationDistance = PICKUP_RANGE
		prompt.RequiresLineOfSight = false
		prompt.Style = Enum.ProximityPromptStyle.Default -- Usa la GUI nera standard
		prompt.Parent = targetPart
		
		-- Listener per Triggered
		prompt.Triggered:Connect(function(player)
			pickupProduct(player, product)
		end)
		
		highlightedProducts[product] = true
	end
	
	print("[Grocery] Highlighted", numToHighlight, "products in", shelf.Name)
end

-- Pickup prodotto
function pickupProduct(player, product)
	if not highlightedProducts[product] then return false end
	
	local character = player.Character
	if not character then return false end
	
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	
	-- Verifica carrello
	local weld = root:FindFirstChild("PlayerCartWeld")
	if not weld then
		warn("[Grocery] Player senza carrello:", player.Name)
		return false
	end
	
	local cart = weld.Part1 and weld.Part1.Parent
	if not cart then return false end
	
	-- Verifica limiti
	local inventory = getPlayerInventory(player)
	if #inventory >= MAX_CART_ITEMS then
		warn("[Grocery] Carrello pieno")
		return false
	end
	
	-- Aggiungi a inventario
	local productPosition = product:GetPivot().Position
	table.insert(inventory, {Name = product.Name, Position = productPosition})
	
	-- Rimuovi highlight e prompt
	local highlight = product:FindFirstChildOfClass("Highlight")
	if highlight then highlight:Destroy() end
	
	for _, part in ipairs(product:GetDescendants()) do
		if part:IsA("ProximityPrompt") then
			part:Destroy()
		end
	end
	
	-- Nascondi originale (non clonare)
	for _, part in ipairs(product:GetDescendants()) do
		if part:IsA("BasePart") or part:IsA("UnionOperation") then
			part.Transparency = 1
			part.CanCollide = false
		end
	end
	
	highlightedProducts[product] = nil
	
	-- Pesca un model casuale da ServerStorage.CartProducts
	local cartProductsFolder = ServerStorage:FindFirstChild("CartProducts")
	if not cartProductsFolder then
		warn("[Grocery] Folder 'CartProducts' non trovata in ServerStorage!")
		return false
	end
	
	local availableModels = cartProductsFolder:GetChildren()
	if #availableModels == 0 then
		warn("[Grocery] Nessun model in ServerStorage.CartProducts!")
		return false
	end
	
	-- Scegli un model casuale (o l'unico disponibile)
	local randomModel = availableModels[math.random(1, #availableModels)]
	local clone = randomModel:Clone()
	
	-- Trova o imposta la PrimaryPart prima di scalare
	if not clone.PrimaryPart then
		clone.PrimaryPart = clone:FindFirstChildWhichIsA("BasePart") or clone:FindFirstChildWhichIsA("UnionOperation")
	end
	
	-- Disabilita collisioni e anchored per tutte le parti
	for _, part in ipairs(clone:GetDescendants()) do
		if part:IsA("BasePart") or part:IsA("UnionOperation") then
			part.CanCollide = false
			part.Anchored = false
		end
	end
	
	-- Welda tutte le parti del model tra loro per evitare che si smolecolino
	local primaryPart = clone.PrimaryPart
	if primaryPart then
		for _, part in ipairs(clone:GetDescendants()) do
			if (part:IsA("BasePart") or part:IsA("UnionOperation")) and part ~= primaryPart then
				local internalWeld = Instance.new("WeldConstraint")
				internalWeld.Part0 = primaryPart
				internalWeld.Part1 = part
				internalWeld.Parent = part
			end
		end
	end
	
	-- Pulisci clone
	local cloneHighlight = clone:FindFirstChildOfClass("Highlight")
	if cloneHighlight then cloneHighlight:Destroy() end
	local clonePrompt = clone:FindFirstChildOfClass("ProximityPrompt")
	if clonePrompt then clonePrompt:Destroy() end
	
	-- Weld al carrello
	local cartMain = cart:FindFirstChild("Main")
	if cartMain then
		-- Trova la parte principale del clone da weldare (BasePart o Union)
		local clonePrimaryPart = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart") or clone:FindFirstChildWhichIsA("UnionOperation")
		if not clonePrimaryPart then
			warn("[Grocery] Clone senza BasePart/Union per weld")
			return false
		end
		
		-- Imposta come PrimaryPart se non è già impostata
		if not clone.PrimaryPart then
			clone.PrimaryPart = clonePrimaryPart
		end
		
		local weldConstraint = Instance.new("WeldConstraint")
		weldConstraint.Part0 = cartMain
		weldConstraint.Part1 = clonePrimaryPart
		weldConstraint.Parent = clonePrimaryPart
		
		-- Posiziona nel carrello
		-- Usa la ProductZone se esiste, altrimenti fallback a Main
		local productZone = cart:FindFirstChild("ProductZone", true) or cartMain
		
		-- Posiziona i prodotti dentro il carrello in modo organizzato
		local column = (#inventory - 1) % 3 -- Colonna (0, 1, 2)
		local row = math.floor((#inventory - 1) / 3) -- Riga
		
		local offsetX = (column - 1) * 0.4 -- Spaziatura orizzontale
		local offsetY = 0.5 + (row * 0.4) -- Impila verticalmente
		local offsetZ = 0 -- Centrato in profondità
		
		clone:SetPrimaryPartCFrame(productZone.CFrame * CFrame.new(offsetX, offsetY, offsetZ))
		
		clone.Parent = cart
	end
	
	print("[Grocery]", player.Name, "picked up product")
	return true
end

-- Setup shelfs
local function setupShelfs()
	local storeFolder = workspace:FindFirstChild("Store")
	if not storeFolder then
		warn("[Grocery] Folder 'Store' non trovata!")
		return
	end
	local shelfsFolder = storeFolder:FindFirstChild("Shelfs")
	if not shelfsFolder then
		warn("[Grocery] Folder 'Shelfs' non trovata dentro 'store'!")
		return
	end
	
	-- Conta quante shelf ci sono
	local allShelfs = {}
	for _, shelf in ipairs(shelfsFolder:GetChildren()) do
		if shelf:IsA("Model") and shelf.Name == "ShefWithProducts" then
			table.insert(allShelfs, shelf)
		end
	end
	
	if #allShelfs == 0 then
		warn("[Grocery] Nessuna shelf trovata!")
		return
	end
	
	-- Distribuisci i prodotti equamente tra tutte le shelf
	local productsPerShelf = math.ceil(PRODUCTS_TO_HIGHLIGHT / #allShelfs)
	
	for _, shelf in ipairs(allShelfs) do
		highlightRandomProducts(shelf, productsPerShelf)
	end
	
	print("[Grocery] Setup completato su", #allShelfs, "shelf")
end

-- Cleanup
Players.PlayerRemoving:Connect(function(player)
	playerInventories[player.UserId] = nil
	hideHighlightsForPlayer(player)
end)

-- Monitora i player esistenti e nuovi
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		monitorPlayerAttachment(player)
	end)
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(function()
		monitorPlayerAttachment(player)
	end)
end)

-- Avvia dopo 2 secondi
task.wait(2)
setupShelfs()

print("[Grocery] Sistema pronto")
