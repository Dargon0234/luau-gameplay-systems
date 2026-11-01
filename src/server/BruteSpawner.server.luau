--[[
	Script in ServerScriptService > Server > BruteSpawner

	Spawns Frost Brutes at every Part inside  Workspace > SnowZone > BruteSpawns  and runs their AI.
	  • locked to the SnowZone: only notices players standing inside the snow outline, never steps past
	    its edge (ZoneBounds, same numbered dot Parts the snowstorm uses), walks back in if shoved out
	  • roars when it spots a player, stomps after them (Walk)
	  • up close it picks one of up to 4 attacks (never the same one twice in a row):
	      Slam   both fists into the ice in front of it (the original attack)
	      Sweep  right-arm backhand across the front
	      Stomp  knee up, stomps - hits everything around it
	      Combo  right hook, then a left uppercut that ragdolls
	    Every hit goes through HitDetection, so blocking, the SafeZone and knockback work exactly like
	    every other attack in the game. Sweep/Stomp/Combo switch on once their IDs are in ATTACK_IDS.
	  • takes hits like the zombies do (lives in workspace.Characters), can't be knocked around
	  • on death: kill + XP credit to whoever landed the last hit, Death anim, fades, respawns

	The master model lives in ServerStorage > Mobs > Brute and is never touched - each spawn is a copy
	that gets its Humanoid / HumanoidRootPart added here.
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")

local HitDetection = require(script.Parent:WaitForChild("HitDetection"))
local ZoneBounds = require(script.Parent:WaitForChild("ZoneBounds"))
local KillTracker = require(script.Parent:WaitForChild("KillTracker"))
local PlayerLevelProgression = require(ServerScriptService.SharedModules.PlayerLevelProgression)

------------------------------------------------------------------ settings
local CONFIG = {
	HomeZone = "SnowZone", -- the Brute never leaves this zone
	MaxHealth = 640, -- was 800; cut 20% so getting jumped by two of them isn't a death sentence
	HealthBarDistance = 100, -- the health bar shows when you're this close (studs)
	WalkSpeed = 10,
	WalkAnimSpeed = 1.8, -- walk cycle playback speed (raise if the feet slide, lower if the legs look frantic)
	KillXP = 75, -- zombie = 15, player kill = 40

	AggroRange = 60, -- notices players this close (who are inside the SnowZone)
	LoseRange = 100, -- gives up on a target past this
	LeashRange = 250, -- never chases farther than this from its spawn
	RoarCooldown = 12,
	RoarSound = 9116302511, -- "Lion Roar Short Blast Angry Sharp 4" (Pro Sound Effects, free Roblox library)
	-- (the old screech, 9113980319, is saved for the Wraith)
	RoarVolume = 1,
	RoarPitch = 0.8, -- below 1 = deeper and bigger, above 1 = higher. 0.8 stretches the 1.6 s roar to 2 s, the same as the Roar animation
	RoarHearRange = 200, -- studs; the roar fades to silence at this distance

	AttackRange = 8, -- starts an attack when the target is this close (flat distance)
	AttackCooldown = 2.5, -- seconds between attack starts

	HipHeight = 1,
	FootSink = 0.1, -- sinks the feet this far into the snow so they read as planted (raise it if they still look like they hover)
	RespawnTime = 20,
	CorpseTime = 4,
	FlipFacing = false, -- set to true if it walks backwards
	DisplayName = "Frost Brute",
}

-- Animation IDs. They're double-checked by length on load
-- (Walk shortest, then Attack, Idle/Roar, Death longest) and any mix-up is fixed automatically.
local ANIM_IDS = {
	Idle = 136360815743989,
	Attack = 119459492444508,
	Death = 116408287917332,
	Walk = 135979516217633,
	Roar = 126873238356632,
}

-- 2026-10-08: the 3 extra attacks (Brute_Sweep.fbx, Brute_Stomp.fbx, Brute_Combo.fbx).
-- Published 2026-10-08. Set an ID to 0 to switch that attack off.
-- Also checked by length on load (Sweep 1.47 s < Stomp 1.50 s < Combo 1.73 s) and swaps are fixed.
local ATTACK_IDS = {
	Sweep = 108313780258395,
	Stomp = 86870495187505,
	Combo = 115435283447004,
}

-- What each attack does. Weight = how often it's picked. Hits land at Time seconds into the animation.
-- Size/Offset = the hitbox (Offset is relative to the Brute: -Z is in front of it, +X is its right).
-- Ring = diameter of the ice shockwave drawn on the ground (RingReach = how far in front of it).
local ATTACKS = {
	Slam = { -- the original Attack animation (fists hit the ice on frame 24)
		Weight = 3,
		Hits = {
			{ Time = 0.77, Size = Vector3.new(18, 10, 18), Offset = CFrame.new(0, -1, -5), Damage = 40, Combo = 4, Knockback = true, Ring = 18, RingReach = 5 },
		},
	},
	Sweep = { -- backhand: the fist crosses its front on frame 21
		Weight = 3,
		Hits = {
			{ Time = 0.67, Size = Vector3.new(16, 8, 12), Offset = CFrame.new(2, -1, -4), Damage = 30, Combo = 3, Knockback = true },
		},
	},
	Stomp = { -- foot lands on frame 22; hits all the way around it
		Weight = 2,
		Hits = {
			{ Time = 0.70, Size = Vector3.new(22, 8, 22), Offset = CFrame.new(0, -2, 0), Damage = 25, Combo = 4, Ring = 24, RingReach = 0 },
		},
	},
	Combo = { -- hook on frame 14, uppercut on frame 27
		Weight = 2,
		Hits = {
			{ Time = 0.43, Size = Vector3.new(8, 8, 8), Offset = CFrame.new(0, 0, -5), Damage = 14, Combo = 1 },
			{ Time = 0.87, Size = Vector3.new(8, 10, 8), Offset = CFrame.new(0, 1, -5), Damage = 26, Combo = 4, Knockback = true, Ragdoll = true },
		},
	},
}

------------------------------------------------------------------ find the pieces (warns instead of hanging forever)
local function warnf(...)
	warn("[BruteSpawner]", ...)
end

local Characters = workspace:WaitForChild("Characters")
local mobsFolder = ServerStorage:WaitForChild("Mobs", 10)
if not mobsFolder then
	warnf("No Folder named 'Mobs' in ServerStorage. Make it and put the Brute model inside.")
	return
end
local template = mobsFolder:WaitForChild("Brute", 10)
if not template then
	warnf("No model named 'Brute' in ServerStorage.Mobs.")
	return
end
local zone = workspace:WaitForChild(CONFIG.HomeZone, 10)
if not zone then
	warnf("No '" .. CONFIG.HomeZone .. "' in Workspace.")
	return
end
local spawnFolder = zone:WaitForChild("BruteSpawns", 10)
if not spawnFolder then
	warnf("No Folder named 'BruteSpawns' inside Workspace." .. CONFIG.HomeZone .. ". Add it and put spawn Parts in it.")
	return
end

------------------------------------------------------------------ animations
local animObjects = {}
for label, id in pairs(ANIM_IDS) do
	local a = Instance.new("Animation")
	a.Name = "Brute_" .. label
	a.AnimationId = "rbxassetid://" .. tostring(id)
	animObjects[label] = a
end
local attackObjects = {}
for label, id in pairs(ATTACK_IDS) do
	if id ~= 0 then
		local a = Instance.new("Animation")
		a.Name = "Brute_" .. label
		a.AnimationId = "rbxassetid://" .. tostring(id)
		attackObjects[label] = a
	end
end
task.spawn(function()
	local list = {}
	for _, a in pairs(animObjects) do
		table.insert(list, a)
	end
	for _, a in pairs(attackObjects) do
		table.insert(list, a)
	end
	pcall(function()
		ContentProvider:PreloadAsync(list)
	end)
end)

local roleOf = nil -- label in ANIM_IDS -> role it actually is (decided once, from clip lengths)
local attackRoleOf = nil -- same idea for Sweep / Stomp / Combo

local function resolveRoles(tracks)
	local list = {}
	for label, track in pairs(tracks) do
		if track.Length <= 0 then
			warnf("Animation '" .. label .. "' (" .. tostring(ANIM_IDS[label]) .. ") didn't load. Check the ID, and that it was published by the same account or group that owns this game.")
			local same = {}
			for l in pairs(tracks) do
				same[l] = l
			end
			return same
		end
		table.insert(list, { label = label, len = track.Length })
	end
	table.sort(list, function(a, b)
		return a.len < b.len
	end)
	local map = {}
	map[list[1].label] = "Walk"
	map[list[2].label] = "Attack"
	map[list[5].label] = "Death"
	local m1, m2 = list[3].label, list[4].label -- Idle and Roar are both 2 s long, so trust your labels between those two
	if m1 == "Idle" or m1 == "Roar" then
		map[m1] = m1
		map[m2] = (m1 == "Idle") and "Roar" or "Idle"
	elseif m2 == "Idle" or m2 == "Roar" then
		map[m2] = m2
		map[m1] = (m2 == "Idle") and "Roar" or "Idle"
	else
		map[m1] = "Idle"
		map[m2] = "Roar"
	end
	for _, e in ipairs(list) do
		local role = map[e.label]
		if role ~= e.label then
			warnf(string.format("ID %s was listed as %s, but its length (%.2fs) says it's %s. Using it as %s.", tostring(ANIM_IDS[e.label]), e.label, e.len, role, role))
		end
	end
	print(string.format("[BruteSpawner] animations: Walk %.2fs, Attack %.2fs, Idle/Roar %.2fs/%.2fs, Death %.2fs", list[1].len, list[2].len, list[3].len, list[4].len, list[5].len))
	return map
end

-- Sweep 1.47 s < Stomp 1.50 s < Combo 1.73 s. Only re-sorts when all three loaded and the lengths are clearly apart.
local function resolveAttackRoles(tracks)
	local map, list = {}, {}
	for label, track in pairs(tracks) do
		map[label] = label
		table.insert(list, { label = label, len = track.Length })
	end
	if #list ~= 3 then
		return map
	end
	table.sort(list, function(a, b)
		return a.len < b.len
	end)
	if list[2].len - list[1].len < 0.02 or list[3].len - list[2].len < 0.02 then
		return map -- too close to tell apart, trust the labels
	end
	local order = { "Sweep", "Stomp", "Combo" }
	for i, e in ipairs(list) do
		map[e.label] = order[i]
		if order[i] ~= e.label then
			warnf(string.format("ID %s was listed as %s, but its length (%.2fs) says it's %s. Using it as %s.", tostring(ATTACK_IDS[e.label]), e.label, e.len, order[i], order[i]))
		end
	end
	print(string.format("[BruteSpawner] extra attacks: Sweep %.2fs, Stomp %.2fs, Combo %.2fs", list[1].len, list[2].len, list[3].len))
	return map
end

local function loadTracks(animator)
	local byLabel = {}
	for label, a in pairs(animObjects) do
		byLabel[label] = animator:LoadAnimation(a)
	end
	local extraByLabel = {}
	for label, a in pairs(attackObjects) do
		extraByLabel[label] = animator:LoadAnimation(a)
	end
	local t0 = os.clock()
	repeat
		local ready = true
		for _, track in pairs(byLabel) do
			if track.Length <= 0 then
				ready = false
			end
		end
		for _, track in pairs(extraByLabel) do
			if track.Length <= 0 then
				ready = false
			end
		end
		if not ready then
			task.wait(0.1)
		end
	until ready or os.clock() - t0 > 6
	if not roleOf then
		roleOf = resolveRoles(byLabel)
	end
	local tracks = {}
	for label, track in pairs(byLabel) do
		tracks[roleOf[label] or label] = track
	end
	tracks.Idle.Looped = true
	tracks.Idle.Priority = Enum.AnimationPriority.Idle
	tracks.Walk.Looped = true
	tracks.Walk.Priority = Enum.AnimationPriority.Movement
	tracks.Roar.Looped = false
	tracks.Roar.Priority = Enum.AnimationPriority.Action
	tracks.Attack.Looped = false
	tracks.Attack.Priority = Enum.AnimationPriority.Action2
	tracks.Death.Looped = false
	tracks.Death.Priority = Enum.AnimationPriority.Action4
	tracks.Slam = tracks.Attack

	-- extra attacks: anything that didn't load is left out (warned once), the rest join the rotation
	local loaded = {}
	for label, track in pairs(extraByLabel) do
		if track.Length > 0 then
			loaded[label] = track
		elseif not attackRoleOf then
			warnf("Attack animation '" .. label .. "' (" .. tostring(ATTACK_IDS[label]) .. ") didn't load, so the Brute won't use it. Check the ID, and that it was published by the same account or group that owns this game.")
		end
	end
	if not attackRoleOf then
		attackRoleOf = resolveAttackRoles(loaded)
	end
	for label, track in pairs(loaded) do
		local role = attackRoleOf[label] or label
		track.Looped = false
		track.Priority = Enum.AnimationPriority.Action2
		tracks[role] = track
	end
	return tracks
end

------------------------------------------------------------------ helpers
local function flatDist(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- Y of the bottom of the Brute's visible body (its feet).
-- The imported model has an invisible RootPart box that hangs ~0.9 studs below the feet, so invisible
-- parts are skipped. Measuring the whole model made the Humanoid stand the ROOTPART on the ground and
-- the Brute hovered.
local function feetY(model)
	local lowest
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and p.Transparency < 1 and p.Name ~= "HumanoidRootPart" then
			local cf, half = p.CFrame, p.Size / 2
			local reach = math.abs(cf.RightVector.Y) * half.X + math.abs(cf.UpVector.Y) * half.Y + math.abs(cf.LookVector.Y) * half.Z
			local y = cf.Position.Y - reach
			if not lowest or y < lowest then
				lowest = y
			end
		end
	end
	if not lowest then
		local boxCF, boxSize = model:GetBoundingBox()
		lowest = boxCF.Position.Y - boxSize.Y / 2
	end
	return lowest
end

local function inZone(position)
	return ZoneBounds.contains(CONFIG.HomeZone, position)
end

local function livingRoot(character)
	if not character or not character.Parent then
		return nil
	end
	local h = character:FindFirstChildOfClass("Humanoid")
	local r = character:FindFirstChild("HumanoidRootPart")
	if h and r and h.Health > 0 then
		return r, h
	end
	return nil
end

-- nearest living player who is standing inside the Brute's zone
local function nearestPlayer(pos, range)
	local best, bestDist = nil, nil
	for _, plr in ipairs(Players:GetPlayers()) do
		local r = livingRoot(plr.Character)
		if r and inZone(r.Position) then
			local d = (r.Position - pos).Magnitude
			if d <= range and (not bestDist or d < bestDist) then
				best, bestDist = plr.Character, d
			end
		end
	end
	return best
end

local function shockwave(pos, diameter)
	local ring = Instance.new("Part")
	ring.Name = "BruteShockwave"
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(140, 235, 255)
	ring.Transparency = 0.25
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Size = Vector3.new(0.3, 2, 2)
	ring.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = workspace
	TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.3, diameter, diameter),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.6)
end

-- one hit of an attack: damage through the game's normal pipeline (blocking, SafeZone, stun, knockback)
local function strike(brute, hrp, hit)
	HitDetection.hitboxCheck(brute, hit.Size, {
		damage = hit.Damage,
		block = true,
		combo = hit.Combo or 1,
		knockback = hit.Knockback,
		ragdoll = hit.Ragdoll,
	}, hit.Offset)

	if hit.Ring then
		local center = hrp.Position + hrp.CFrame.LookVector * (hit.RingReach or 0)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { Characters }
		local ray = workspace:Raycast(center + Vector3.new(0, 4, 0), Vector3.new(0, -20, 0), params)
		local ground = ray and ray.Position or (center - Vector3.new(0, hrp.Size.Y / 2 + CONFIG.HipHeight, 0))
		shockwave(ground + Vector3.new(0, 0.2, 0), hit.Ring)
	end
end

-- weighted random attack that has a loaded animation, never the same as last time
-- (if only one attack is loaded, it's always that one)
local function pickAttack(tracks, last)
	local total, pool = 0, {}
	for name, spec in pairs(ATTACKS) do
		if tracks[name] and name ~= last then
			table.insert(pool, name)
			total += spec.Weight
		end
	end
	if #pool == 0 then
		return "Slam"
	end
	local roll = math.random() * total
	for _, name in ipairs(pool) do
		roll -= ATTACKS[name].Weight
		if roll <= 0 then
			return name
		end
	end
	return pool[#pool]
end

------------------------------------------------------------------ health bar over its head (built on the server so every player sees it)
-- The Brute has no part named "Head", so Roblox's built-in Humanoid bar never shows. This replaces it.
local function makeHealthBar(hum, hrp)
	local gui = Instance.new("BillboardGui")
	gui.Name = "HealthBar"
	gui.Size = UDim2.fromOffset(180, 40) -- pixels, so it stays readable on phones at any distance
	gui.StudsOffset = Vector3.new(0, 4, 0) -- just above the horns
	gui.SizeOffset = Vector2.new(0, 0.5) -- the bar's bottom edge sits on that point, so it never covers his head up close or far away
	gui.AlwaysOnTop = true -- readable through the snowstorm
	gui.MaxDistance = CONFIG.HealthBarDistance
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false

	local name = Instance.new("TextLabel")
	name.Name = "BruteName"
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(1, 0, 0, 17)
	name.Font = Enum.Font.GothamBold
	name.TextSize = 15
	name.TextColor3 = Color3.fromRGB(190, 240, 255)
	name.TextStrokeColor3 = Color3.fromRGB(5, 12, 22)
	name.TextStrokeTransparency = 0.3
	name.Text = CONFIG.DisplayName
	name.Parent = gui

	local back = Instance.new("Frame")
	back.Name = "Back"
	back.Position = UDim2.fromOffset(0, 19)
	back.Size = UDim2.new(1, 0, 0, 18)
	back.BackgroundColor3 = Color3.fromRGB(10, 16, 26)
	back.BackgroundTransparency = 0.15
	back.BorderSizePixel = 0
	back.ClipsDescendants = true
	back.Parent = gui
	Instance.new("UICorner", back).CornerRadius = UDim.new(0, 5)
	local stroke = Instance.new("UIStroke", back)
	stroke.Color = Color3.fromRGB(120, 220, 255)
	stroke.Thickness = 1.5

	-- white chunk that shows how much the last hit took, then catches up
	local trail = Instance.new("Frame")
	trail.Name = "Trail"
	trail.Size = UDim2.fromScale(1, 1)
	trail.BackgroundColor3 = Color3.fromRGB(235, 245, 255)
	trail.BorderSizePixel = 0
	trail.Parent = back
	Instance.new("UICorner", trail).CornerRadius = UDim.new(0, 5)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(80, 205, 255)
	fill.BorderSizePixel = 0
	fill.Parent = back
	Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 5)
	local shine = Instance.new("UIGradient", fill)
	shine.Rotation = 90
	shine.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(170, 170, 170))

	local hp = Instance.new("TextLabel")
	hp.Name = "HP"
	hp.BackgroundTransparency = 1
	hp.Size = UDim2.fromScale(1, 1)
	hp.ZIndex = 3
	hp.Font = Enum.Font.GothamBold
	hp.TextSize = 13
	hp.TextColor3 = Color3.new(1, 1, 1)
	hp.TextStrokeColor3 = Color3.fromRGB(5, 12, 22)
	hp.TextStrokeTransparency = 0.2
	hp.Parent = back

	local function update()
		local frac = math.clamp(hum.Health / hum.MaxHealth, 0, 1)
		fill.Size = UDim2.fromScale(frac, 1)
		if frac > 0.5 then
			fill.BackgroundColor3 = Color3.fromRGB(80, 205, 255) -- icy blue
		elseif frac > 0.25 then
			fill.BackgroundColor3 = Color3.fromRGB(255, 190, 80) -- amber: half dead
		else
			fill.BackgroundColor3 = Color3.fromRGB(255, 75, 75) -- red: finish him
		end
		hp.Text = string.format("%d / %d", math.max(math.ceil(hum.Health), 0), hum.MaxHealth)
		if trail.Size.X.Scale <= frac then
			trail.Size = fill.Size -- healed: no chunk to show
		else
			TweenService:Create(trail, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.3), {
				Size = fill.Size,
			}):Play()
		end
	end
	update()
	hum.HealthChanged:Connect(update)
	hum.Died:Connect(function()
		task.delay(1.5, function()
			gui.Enabled = false
		end)
	end)

	gui.Parent = hrp
	return gui
end

------------------------------------------------------------------ turn a plain copy of the model into a walking NPC
local function prepareBrute(brute)
	for _, d in ipairs(brute:GetDescendants()) do
		if d:IsA("AnimationController") or d:IsA("Humanoid") or d.Name == "InitialPoses" then
			d:Destroy()
		end
	end
	brute:SetAttribute("ArenaBot", true) -- bots never hit each other (HitDetection)
	brute:SetAttribute("HomeZone", CONFIG.HomeZone)

	local pivot = brute:GetPivot()
	local bottomY = feetY(brute) + CONFIG.FootSink -- the Humanoid will hold this height on the ground
	local rootSize = Vector3.new(4, 5, 3)
	local rot = pivot - pivot.Position
	if CONFIG.FlipFacing then
		rot = rot * CFrame.Angles(0, math.pi, 0)
	end

	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = rootSize
	hrp.Transparency = 1
	hrp.CanCollide = true
	hrp.Anchored = false
	hrp.RootPriority = 127
	hrp.CustomPhysicalProperties = PhysicalProperties.new(10, 0.3, 0.5)
	hrp.CFrame = CFrame.new(pivot.Position.X, bottomY + CONFIG.HipHeight + rootSize.Y / 2, pivot.Position.Z) * rot

	for _, p in ipairs(brute:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = false
			p.CanCollide = false
			p.Massless = true
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = hrp
			weld.Part1 = p
			weld.Parent = hrp
		end
	end
	hrp.Parent = brute
	brute.PrimaryPart = hrp

	-- hit sounds / particles every combat target carries (same as zombies and players)
	local assets = ServerStorage:FindFirstChild("Assets")
	local hrpAssets = assets and assets:FindFirstChild("HumanoidRootPart")
	if hrpAssets then
		for _, asset in ipairs(hrpAssets:GetChildren()) do
			asset:Clone().Parent = hrp
		end
	end

	-- the roar when it spots you (3D: loud up close, fades with distance)
	local roar = Instance.new("Sound")
	roar.Name = "BruteRoar"
	roar.SoundId = "rbxassetid://" .. CONFIG.RoarSound
	roar.Volume = CONFIG.RoarVolume
	roar.PlaybackSpeed = CONFIG.RoarPitch
	roar.RollOffMode = Enum.RollOffMode.InverseTapered
	roar.RollOffMinDistance = 20
	roar.RollOffMaxDistance = CONFIG.RoarHearRange
	roar.Parent = hrp

	-- too heavy to shove: punches' knockback / clash pushes just don't move it
	hrp.ChildAdded:Connect(function(child)
		if child:IsA("BodyVelocity") then
			task.defer(function()
				if child.Parent then
					child:Destroy()
				end
			end)
		end
	end)

	local hum = Instance.new("Humanoid")
	hum.RigType = Enum.HumanoidRigType.R15
	hum.AutomaticScalingEnabled = false
	hum.HipHeight = CONFIG.HipHeight
	hum.MaxHealth = CONFIG.MaxHealth
	hum.Health = CONFIG.MaxHealth
	hum.WalkSpeed = CONFIG.WalkSpeed
	hum.UseJumpPower = true
	hum.JumpPower = 0
	hum.RequiresNeck = false
	hum.BreakJointsOnDeath = false
	hum.DisplayName = CONFIG.DisplayName
	hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.DisplayWhenDamaged
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None -- our own bar below replaces Roblox's
	local animator = Instance.new("Animator")
	animator.Parent = hum
	hum.Parent = brute
	makeHealthBar(hum, hrp)
	return hum, hrp, animator
end

------------------------------------------------------------------ AI
local spawnAt -- defined below (the AI needs it to respawn, and it needs the AI)

local function runBrute(brute, hum, hrp, animator, spawnPart, spawnCF)
	hrp:SetNetworkOwner(nil) -- the server moves it, so it doesn't jitter
	for _, state in ipairs({
		Enum.HumanoidStateType.FallingDown,
		Enum.HumanoidStateType.Ragdoll,
		Enum.HumanoidStateType.Climbing,
		Enum.HumanoidStateType.Swimming,
		Enum.HumanoidStateType.Seated,
		Enum.HumanoidStateType.PlatformStanding,
		Enum.HumanoidStateType.Jumping,
	}) do
		hum:SetStateEnabled(state, false) -- a heavy brute never trips, climbs, swims or jumps
	end
	local anim = loadTracks(animator)
	anim.Idle:Play(0.3)

	local home = hrp.Position
	local target = nil
	local busy = false
	local lastAttack = -math.huge
	local lastAttackName = nil
	local lastRoar = -math.huge

	local function face(pos)
		local p = hrp.Position
		if flatDist(pos, p) > 0.1 then
			hrp.CFrame = CFrame.lookAt(p, Vector3.new(pos.X, p.Y, pos.Z))
		end
	end

	local function holdStill()
		hum:MoveTo(hrp.Position)
		hum.WalkSpeed = 0
		hum.AutoRotate = false
	end

	local function release()
		hum.WalkSpeed = CONFIG.WalkSpeed
		hum.AutoRotate = true
	end

	-- walk somewhere, but never past the edge of the zone
	local function walkTo(pos)
		hum:MoveTo(ZoneBounds.clampPath(CONFIG.HomeZone, hrp.Position, pos, 4))
	end

	hum.Running:Connect(function(speed)
		if hum.Health <= 0 then
			return
		end
		if speed > 0.5 then
			if not anim.Walk.IsPlaying then
				anim.Walk:Play(0.25)
				anim.Walk:AdjustSpeed(CONFIG.WalkAnimSpeed)
			end
		elseif anim.Walk.IsPlaying then
			anim.Walk:Stop(0.3)
		end
	end)

	local function roarAt(pos)
		busy = true
		lastRoar = os.clock()
		holdStill()
		face(pos)
		anim.Roar:Play(0.15)
		local roarSound = hrp:FindFirstChild("BruteRoar")
		if roarSound then
			roarSound.TimePosition = 0
			roarSound:Play()
		end
		task.wait(anim.Roar.Length > 0 and anim.Roar.Length or 2)
		if hum.Health > 0 then
			release()
		end
		busy = false
	end

	local function attack(targetRoot)
		busy = true
		lastAttack = os.clock()
		holdStill()
		face(targetRoot.Position)
		local name = pickAttack(anim, lastAttackName)
		lastAttackName = name
		local spec = ATTACKS[name]
		local track = anim[name]
		track:Play(0.1)
		local t0 = os.clock()
		for _, hit in ipairs(spec.Hits) do
			local waitFor = hit.Time - (os.clock() - t0)
			if waitFor > 0 then
				task.wait(waitFor)
			end
			if hum.Health <= 0 or not brute.Parent then
				break
			end
			strike(brute, hrp, hit)
		end
		local total = track.Length > 0 and track.Length or 1.5
		task.wait(math.max(total - (os.clock() - t0), 0.2))
		if hum.Health > 0 then
			release()
		end
		busy = false
	end

	hum.Died:Connect(function()
		busy = true
		hrp.Anchored = true
		local roarSound = hrp:FindFirstChild("BruteRoar")
		if roarSound then
			roarSound:Stop() -- no roaring from beyond the grave
		end

		-- kill credit, same as zombies (the LastAttacker tag comes from ServerHandler)
		local tag = hum:FindFirstChild("LastAttacker")
		local killer = tag and Players:GetPlayerByUserId(tag.Value)
		if killer then
			pcall(PlayerLevelProgression.AwardXP, killer, CONFIG.KillXP)
			pcall(KillTracker.RecordKill, killer)
		end

		local stopped = {}
		for role, track in pairs(anim) do
			if role ~= "Death" and not stopped[track] then
				stopped[track] = true -- Slam and Attack are the same track
				track:Stop(0.2)
			end
		end
		anim.Death:Play(0.1)
		task.wait((anim.Death.Length > 0 and anim.Death.Length or 2.4) + CONFIG.CorpseTime)
		for _, p in ipairs(brute:GetDescendants()) do
			if p:IsA("BasePart") and p ~= hrp then
				TweenService:Create(p, TweenInfo.new(1), { Transparency = 1 }):Play()
			end
		end
		task.wait(1.1)
		brute:Destroy()
		task.delay(CONFIG.RespawnTime, function()
			spawnAt(spawnPart)
		end)
	end)

	task.spawn(function()
		while brute.Parent and hum.Health > 0 do
			if not busy then
				local pos = hrp.Position

				if not inZone(pos) then
					-- shoved or fell out of the zone: drop the target and go straight back in
					target = nil
					if ZoneBounds.distanceOutside(CONFIG.HomeZone, pos) > 40 then
						brute:PivotTo(spawnCF)
					else
						hum:MoveTo(ZoneBounds.pullInside(CONFIG.HomeZone, pos, 10))
					end
				else
					local fromHome = (pos - home).Magnitude

					if target then
						local tr = livingRoot(target)
						if not tr or not inZone(tr.Position) or (tr.Position - pos).Magnitude > CONFIG.LoseRange or fromHome > CONFIG.LeashRange then
							target = nil
						end
					end

					if not target then
						local found = fromHome <= CONFIG.LeashRange and nearestPlayer(pos, CONFIG.AggroRange) or nil
						if found then
							target = found
							if os.clock() - lastRoar >= CONFIG.RoarCooldown then
								roarAt(found.HumanoidRootPart.Position)
							end
						elseif fromHome > 6 then
							walkTo(home)
						end
					else
						local tr = livingRoot(target)
						if tr then
							if flatDist(tr.Position, pos) <= CONFIG.AttackRange then
								if os.clock() - lastAttack >= CONFIG.AttackCooldown then
									attack(tr)
								else
									hum:MoveTo(pos)
									face(tr.Position)
								end
							else
								walkTo(tr.Position)
							end
						end
					end
				end
			end
			task.wait(0.2)
		end
	end)
end

------------------------------------------------------------------ spawning
spawnAt = function(spawnPart)
	if not spawnPart or not spawnPart.Parent then
		return
	end
	local brute = template:Clone()

	-- stand it on the ground under the spawn part, facing the way the part faces
	local pivot = brute:GetPivot()
	local feetBelowPivot = pivot.Position.Y - feetY(brute)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { spawnFolder, Characters }
	local hit = workspace:Raycast(spawnPart.Position + Vector3.new(0, 5, 0), Vector3.new(0, -200, 0), params)
	local ground = hit and hit.Position or spawnPart.Position
	local look = spawnPart.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	local yaw = flat.Magnitude > 0.01 and CFrame.lookAt(Vector3.zero, flat.Unit) or CFrame.new()
	local spawnCF = CFrame.new(ground + Vector3.new(0, feetBelowPivot - CONFIG.FootSink, 0)) * yaw
	brute:PivotTo(spawnCF)

	if not inZone(spawnPart.Position) then
		warnf("Spawn point '" .. spawnPart.Name .. "' is outside " .. CONFIG.HomeZone .. " - the Brute will walk into the zone from there.")
	end

	local hum, hrp, animator = prepareBrute(brute)
	brute.Name = "Brute"
	brute.Parent = Characters -- combat only hits things inside workspace.Characters
	runBrute(brute, hum, hrp, animator, spawnPart, brute:GetPivot())
end

for _, part in ipairs(spawnFolder:GetChildren()) do
	if part:IsA("BasePart") then
		task.spawn(spawnAt, part)
	end
end
if #spawnFolder:GetChildren() == 0 then
	warnf("BruteSpawns is empty. Put at least one Part in it where a Brute should stand.")
end
