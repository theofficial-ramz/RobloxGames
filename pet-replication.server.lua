--!strict
--[[
	PetReplication.luau
	
	Handles all the server-side pet logic. This script spawns the visual models
	and makes them follow players around.
	
	I used a velocity-based movement system instead of just setting CFrame directly
	because it makes the movement look way smoother and less robotic.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.PetSystem.Config)
local Types = require(ReplicatedStorage.PetSystem.types)

local PetReplication = {}

-- Keeps track of every pet currently spawned in the world
-- Structure: ActivePets[Player][UUID] = { Model, PetId, PetIndex, Velocity, FloatTime }
local ActivePets: { [Player]: { [string]: any } } = {}

-- Folder in workspace to keep things organized
local serverPetsFolder: Folder = nil

-- Used to throttle updates if we need to save performance
local frameCount = 0

-- Just creates the folder if it doesn't exist
local function InitServerPetsFolder()
	serverPetsFolder = Workspace:FindFirstChild("ServerPets")
	if not serverPetsFolder then
		serverPetsFolder = Instance.new("Folder")
		serverPetsFolder.Name = "ServerPets"
		serverPetsFolder.Parent = Workspace
	end
end
-- Calculates where a pet should be positioned relative to the player
local function CalculatePetPosition(character: Model, petIndex: number, totalPets: number): Vector3?
	local rootPart = character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return nil
	end

	-- Config for the formation shape
	local columns = Config.Constants.PetGridColumns
	local baseRadius = 5 -- How far behind the player the first row starts
	local rowSpacing = 3 -- Gap between rows
	local arcSpread = math.pi * 0.75 -- 135 degrees arc

	-- Figure out grid position
	local row = math.floor((petIndex - 1) / columns)
	local col = (petIndex - 1) % columns

	local petsInThisRow = math.min(columns, totalPets - (row * columns))

	if petsInThisRow == 1 then
		-- If it's the only pet in this row, put it dead center
		local radius = baseRadius + (row * rowSpacing)
		local targetPos = rootPart.Position + (-rootPart.CFrame.LookVector * radius)
		targetPos += Vector3.new(0, Config.Constants.PetYOffset, 0)
		return targetPos
	else
		-- Spread them out in an arc if there's more than one
		local radius = baseRadius + (row * rowSpacing)

		-- Map the column to an angle on the arc
		local t = col / (petsInThisRow - 1)
		local angle = (t - 0.5) * arcSpread -- Center it so 0 is straight back

		-- Trig to get the offset
		local sideOffset = math.sin(angle) * radius
		local backOffset = math.cos(angle) * radius

		-- Apply offsets relative to player rotation
		local targetPos = rootPart.Position
			+ (-rootPart.CFrame.LookVector * backOffset)
			+ (rootPart.CFrame.RightVector * sideOffset)

		targetPos += Vector3.new(0, Config.Constants.PetYOffset, 0)

		return targetPos
	end
end

-- Spawns the actual visual model for the pet
function PetReplication.SpawnPet(player: Player, petData: Types.PetData, petIndex: number)
	if not ActivePets[player] then
		ActivePets[player] = {}
	end

	-- Prevent duplicates
	if ActivePets[player][petData.UUID] then
		warn(`Pet {petData.UUID} already spawned for {player.Name}`)
		return
	end

	local petConfig = Config.Pets[petData.Id]
	if not petConfig then
		warn(`Pet config not found for {petData.Id}`)
		return
	end

	local petsFolder = ReplicatedStorage:FindFirstChild("Pets")
	if not petsFolder then
		warn("ReplicatedStorage.Pets folder not found")
		return
	end

	local petTemplate = petsFolder:FindFirstChild(petConfig.Model)
	if not petTemplate then
		warn(`Pet model not found: {petConfig.Model}`)
		return
	end

	local petModel = petTemplate:Clone()
	petModel.Name = `Pet_{player.UserId}_{petData.UUID}`

	-- identification
	petModel:SetAttribute("OwnerUserId", player.UserId)
	petModel:SetAttribute("PetUUID", petData.UUID)
	petModel:SetAttribute("PetId", petData.Id)

	local scale = Config.Constants.PetScale or 1
	if petModel.PrimaryPart then
		petModel:ScaleTo(scale)
	end

	-- Disable collisions so pets don't push players around
	for _, descendant in petModel:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.Massless = true
		end
	end

	-- Sanity check
	if not petModel.PrimaryPart then
		local primaryPart = petModel:FindFirstChildWhichIsA("BasePart")
		if primaryPart then
			petModel.PrimaryPart = primaryPart
		else
			warn(`[PetReplication] No BasePart found in pet model {petData.Id}`)
			petModel:Destroy()
			return
		end
	end

	-- Count how many pets they have to update positions
	local totalPets = 0
	for _ in ActivePets[player] do
		totalPets += 1
	end
	totalPets += 1

	-- Snap to correct position immediately
	local character = player.Character
	if character then
		local targetPos = CalculatePetPosition(character, petIndex, totalPets)
		if targetPos then
			petModel:SetPrimaryPartCFrame(CFrame.new(targetPos))
		end
	end

	-- Important: Only anchor the root. Weld everything else to it.
	-- This is much more performant than anchoring everything.
	petModel.PrimaryPart.Anchored = true

	for _, descendant in petModel:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= petModel.PrimaryPart then
			descendant.Anchored = false

			local weld = Instance.new("Weld")
			weld.Part0 = petModel.PrimaryPart
			weld.Part1 = descendant
			weld.C0 = petModel.PrimaryPart.CFrame:Inverse() * descendant.CFrame
			weld.Parent = petModel.PrimaryPart
		end
	end

	petModel.Parent = serverPetsFolder

	ActivePets[player][petData.UUID] = {
		Model = petModel,
		PetId = petData.Id,
		PetIndex = petIndex,
	}

	print(`[PetReplication] Spawned pet {petData.Id} for {player.Name} at index {petIndex}`)
end

function PetReplication.DespawnPet(player: Player, uuid: string)
	if not ActivePets[player] then
		return
	end

	local petData = ActivePets[player][uuid]
	if not petData then
		return
	end

	if petData.Model and petData.Model.Parent then
		petData.Model:Destroy()
	end

	ActivePets[player][uuid] = nil

	print(`[PetReplication] Despawned pet {uuid} for {player.Name}`)
end

-- Re-shuffles the pets when one is removed so there are no gaps
function PetReplication.RecalculatePositions(player: Player)
	if not ActivePets[player] then
		return
	end

	local character = player.Character
	if not character or not character.PrimaryPart then
		return
	end

	local totalPets = 0
	for _ in ActivePets[player] do
		totalPets += 1
	end

	local newIndex = 1
	for uuid, petData in ActivePets[player] do
		petData.PetIndex = newIndex

		local targetPos = CalculatePetPosition(character, newIndex, totalPets)
		if targetPos and petData.Model and petData.Model.PrimaryPart then
			petData.Model.PrimaryPart.CFrame = CFrame.new(targetPos)
		end

		newIndex += 1
	end
end

local function UpdatePetPositions(deltaTime: number)
	for player, petsTable in ActivePets do
		local character = player.Character
		if character and character.PrimaryPart then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local isMoving = humanoid and humanoid.WalkSpeed > 0 and (humanoid.MoveDirection.Magnitude > 0.1)

			local totalPets = 0
			for _ in petsTable do
				totalPets += 1
			end

			for uuid, petData in petsTable do
				if petData.Model and petData.Model.PrimaryPart then
					if not petData.Velocity then
						petData.Velocity = Vector3.new(0, 0, 0)
					end

					if not petData.FloatTime then
						-- Randomize the float phase so they don't all bob in sync
						petData.FloatTime = math.random() * math.pi * 2
					end

					local targetPos = CalculatePetPosition(character, petData.PetIndex, totalPets)

					if targetPos then
						-- Add floating animation to TARGET position (prevents physics fighting)
						if not isMoving then
							petData.FloatTime += deltaTime * Config.Constants.PetFloatSpeed
							local floatOffset = math.sin(petData.FloatTime) * Config.Constants.PetFloatAmplitude
							targetPos += Vector3.new(0, floatOffset, 0)
						end

						local currentPos = petData.Model.PrimaryPart.Position
						local distance = (targetPos - currentPos).Magnitude

						-- Speed scales with distance - pets catch up faster if they fall behind
						local speed = Config.Constants.FollowSpeed
						if distance > Config.Constants.PetDistanceThreshold then
							local speedMultiplier = math.min(distance / Config.Constants.PetDistanceThreshold, 2)
							speed = math.min(speed * speedMultiplier, Config.Constants.PetFollowMaxSpeed)
						end

						-- Velocity lerping
						local direction = (targetPos - currentPos).Unit
						local lerpAlpha = math.clamp(speed * deltaTime * 5, 0, 1)

						if distance > 0.1 then
							petData.Velocity = petData.Velocity:Lerp(direction * distance * speed * 10, lerpAlpha)
						else
							-- Slow down smoothly when arriving
							petData.Velocity = petData.Velocity:Lerp(Vector3.new(0, 0, 0), lerpAlpha * 2)
						end

						local newPos = currentPos + petData.Velocity * deltaTime

						-- Rotation logic
						local currentCFrame = petData.Model.PrimaryPart.CFrame
						local targetLook
						local horizontalDist = (Vector3.new(targetPos.X, 0, targetPos.Z) - Vector3.new(
							currentPos.X,
							0,
							currentPos.Z
						)).Magnitude

						if horizontalDist > 0.5 then
							-- Moving: face the direction we're traveling
							local lookDir = (targetPos - currentPos) * Vector3.new(1, 0, 1)
							if lookDir.Magnitude > 0.01 then
								targetLook = lookDir.Unit
							else
								targetLook = character.PrimaryPart.CFrame.LookVector
							end
						else
							-- Idle: match the player's facing direction
							targetLook = character.PrimaryPart.CFrame.LookVector
						end

						local targetCFrame = CFrame.new(newPos, newPos + targetLook)

						petData.Model.PrimaryPart.CFrame =
							currentCFrame:Lerp(targetCFrame, Config.Constants.PetRotationSpeed)
					end
				end
			end
		end
	end
end

-- Clean up everything when a player leaves to prevent memory leaks
local function OnPlayerRemoving(player: Player)
	if not ActivePets[player] then
		return
	end

	for uuid, petData in ActivePets[player] do
		if petData.Model and petData.Model.Parent then
			petData.Model:Destroy()
		end
	end

	ActivePets[player] = nil
	print(`[PetReplication] Cleaned up all pets for {player.Name}`)
end

function PetReplication.Init()
	InitServerPetsFolder()

	-- Hook into Heartbeat for smooth updates
	RunService.Heartbeat:Connect(function(deltaTime)
		frameCount += 1
		if frameCount % Config.Constants.ServerPetUpdateRate == 0 then
			UpdatePetPositions(deltaTime)
		end
	end)

	Players.PlayerRemoving:Connect(OnPlayerRemoving)

	print("[PetReplication] Initialized")
end

return PetReplication
