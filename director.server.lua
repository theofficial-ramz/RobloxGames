-- Event Director: Orchestrates random events

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Wait for LobbyManager to initialize
repeat task.wait(0.1) until _G.LobbyManager

-- Load RemoteEvents
local eventRemotes = ReplicatedStorage:WaitForChild("EventRemotes")
local broadcastWarning = eventRemotes:WaitForChild("BroadcastWarning")
local showRestingUI = eventRemotes:WaitForChild("ShowRestingUI")

-- ==========================================
-- Map Management - Initialize BEFORE loading event modules
-- ==========================================
local currentMap = nil

local function loadMap(mapName)
	if currentMap then
		currentMap:Destroy() -- Remove the previous map
	end

	local mapTemplate = ServerStorage.Maps:FindFirstChild(mapName)
	if mapTemplate then
		currentMap = mapTemplate:Clone()
		currentMap.Parent = workspace
		print("Loaded map:", mapName)
		
		-- Clear MapBounds cache when a new map is loaded
		if _G.MapBounds then
			_G.MapBounds.ClearCache()
		end
	else
		warn("Map not found:", mapName)
	end
end

local function cleanupMap()
	if currentMap then
		currentMap:Destroy()
		currentMap = nil
		print("Map cleaned up.")
		
		-- Clear MapBounds cache when map is removed
		if _G.MapBounds then
			_G.MapBounds.ClearCache()
		end
	end
end

-- Make these functions available globally for event modules
_G.EventDirector = _G.EventDirector or {}
_G.EventDirector.LoadMap = loadMap
_G.EventDirector.CleanupMap = cleanupMap

-- ==========================================
-- Helper function: Check if any players are alive in the map
-- ==========================================
local function arePlayersAliveInMap()
	local MapBounds = _G.MapBounds
	if not MapBounds then
		return true -- Default to continuing if we can't check
	end
	
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			local humanoid = player.Character:FindFirstChild("Humanoid")
			local rootPart = player.Character:FindFirstChild("HumanoidRootPart")
			
			if humanoid and rootPart and humanoid.Health > 0 then
				-- Check if player is inside the map
				if MapBounds.IsInsideMap(rootPart.Position) then
					return true -- Found at least one alive player in map
				end
			end
		end
	end
	
	return false -- No alive players in map
end

-- Make this function available globally for event modules
_G.EventDirector.ArePlayersAliveInMap = arePlayersAliveInMap

-- Load all event modules from ServerStorage
local eventDirector = ServerStorage:WaitForChild("EventDirector")
local eventModulesFolder = eventDirector:WaitForChild("EventModules")
local eventModules = {}

-- Load and expose MapBounds globally for events to use
local MapBounds = require(eventDirector.Shared:WaitForChild("map-bounds"))
_G.MapBounds = MapBounds

print("Director: Loading event modules...")
for _, moduleScript in ipairs(eventModulesFolder:GetChildren()) do
	if moduleScript:IsA("ModuleScript") then
		local success, module = pcall(function()
			return require(moduleScript)
		end)
		
		if success then
			table.insert(eventModules, module)
			print("Loaded:", moduleScript.Name)
		else
			warn("Error loading:", moduleScript.Name, "-", module)
		end
	end
end

print("Director: Loaded", #eventModules, "events")

-- Configuration
local MIN_WAIT_TIME = 25 
local MAX_WAIT_TIME = 25
local MIN_PLAYERS = 1
local currentState = "Idle"
local restStartTime = nil
local restEndTime = nil

-- Handle new players joining during rest
Players.PlayerAdded:Connect(function(player)
	-- Wait for player to load
	player.CharacterAdded:Wait()
	task.wait(1) -- Give time for client scripts to load
	
	-- If we're resting, show them the UI
	if currentState == "Idle" and restEndTime then
		local remainingTime = restEndTime - tick()
		if remainingTime > 0 then
			showRestingUI:FireClient(player, true, remainingTime)
		end
	end
end)

-- Main Director Loop 
while true do
	-- ==========================================
	-- 1. PHASE: IDLE (Rest)
	-- ==========================================
	currentState = "Idle"
	local waitTime = math.random(MIN_WAIT_TIME, MAX_WAIT_TIME)
	restStartTime = tick()
	restEndTime = restStartTime + waitTime
	print("Director: Resting for", waitTime, "seconds...")
	
	-- Show resting UI to all players
	showRestingUI:FireAllClients(true, waitTime)
	
	task.wait(waitTime)
	
	-- Hide resting UI
	showRestingUI:FireAllClients(false)
	restEndTime = nil
	
	-- ==========================================
	-- 2. PHASE: CHECK (Can we start?)
	-- ==========================================
	if #Players:GetPlayers() < MIN_PLAYERS then
		print("Director: Not enough players. Resting...")
		continue
	end
	
	if #eventModules == 0 then
		warn("Director: No events available!")
		continue
	end
	
	-- ==========================================
	-- 3. PHASE: SELECTION (Choose an event)
	-- ==========================================
	local chosenEvent = eventModules[math.random(1, #eventModules)]
	local eventData = chosenEvent.GetInfo()
	
	print("Director: Event selected -", eventData.Name)
	
	-- ==========================================
	-- 4. PHASE: WARNING (Warn players and prepare lobby)
	-- ==========================================
	currentState = "Warning"
	print("Director: Broadcasting warning to clients -", eventData.Name)
	broadcastWarning:FireAllClients(eventData.Name, eventData.WarningDuration)
	
	-- Load the map for the event FIRST
	local mapName = nil
	if chosenEvent.GetMapName then
		mapName = chosenEvent.GetMapName()
		if mapName then
			loadMap(mapName)
			-- Wait for the map to fully load and replicate
			task.wait(1)
			print("Director: Map loaded and ready")
		end
	end
	
	-- NOW move players from lobby to game (after map is fully loaded)
	_G.LobbyManager.StartEvent(mapName)
	
	-- Continue waiting for the warning duration
	task.wait(eventData.WarningDuration - 1) -- Subtract the 1 second we already waited
	
	-- ==========================================
	-- 5. PHASE: ACTIVE (Start the event)
	-- ==========================================
	currentState = "Active"
	print("Director: Starting event -", eventData.Name)
	
	local success, errorMsg = pcall(function()
		chosenEvent.Start() -- This function yields (blocking)
	end)
	
	if not success then
		warn("Director: Error during event:", errorMsg)
	else
		print("Director: Event completed -", eventData.Name)
	end
	
	-- ==========================================
	-- 6. PHASE: CLEANUP
	-- ==========================================
	currentState = "Cleanup"
	print("Director: Cleaning up after event...")
	
	local cleanupSuccess, cleanupError = pcall(function()
		chosenEvent.Cleanup()
	end)
	
	if not cleanupSuccess then
		warn("Director: Error during cleanup:", cleanupError)
	end
	
	-- Award points and return players to lobby FIRST
	-- (LobbyManager.EndEvent() will wait for players to teleport)
	_G.LobbyManager.EndEvent()
	
	-- NOW cleanup the map after everyone is safely in lobby
	print("Director: Unloading map...")
	cleanupMap()
	
	print("Director: Cycle completed. Returning to Idle.\n")
end
