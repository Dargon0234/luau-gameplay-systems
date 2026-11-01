--[[
	Script in ServerScriptService > Server > SandWorm

	The Sandworm: a roaming mini-boss that lives under the map. The server decides where the head goes and
	when it attacks; every player's SandWormRenderer draws the body from the head's path (same math as the
	Blender motion preview), using SandWormShared in ReplicatedStorage > SharedModules.

	  • shows up 2 minutes after the server starts
	  • hunts in this order: whoever is highest on the Kills board in this server, then the players with the
	    most kills this session, then everyone else. After every strike it moves down the list (#1, #2, #3 ...
	    then back to #1). It goes anywhere on the map except the SafeZone.
	  • warning as it closes in: deep = only a sand/snow wake and a rumble; closer = the black-ice fins break
	    the ground, taller the nearer it gets; right under you = it dips, the ground cracks, it bursts out
	  • 3 attacks (never the same one twice in a row):
	      Bite       bursts up under the target and bites, then stays up ~8 s (hit it!) and dives back down,
	                 smacking its head into anyone it can reach on the way down
	      Head Smack breaches a short way off, rears up and slams its head down where the target stands
	      Tail Whip  the tail rips up beside the target and sweeps across
	    Damage goes through the game's normal DamageHumanoid pipeline, so the SafeZone, blocking, stun and
	    knockback all work like every other attack.
	  • takes hits only while part of it is above ground (lives in workspace.Characters like the other mobs)
	  • on death: everyone who hit it gets the kill + XP, it sinks, and comes back after RespawnTime

	Tuning is all in CONFIG below.
	For testing (Studio only): give this Script a number attribute "StartDelay" to override the 2-minute wait, and a string
	attribute "ForcePattern" (Bite / HeadSmack / TailWhip) to make it use one attack only.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("SandWormShared"))
local KillTracker = require(script.Parent:WaitForChild("KillTracker"))
local ZoneBounds = require(script.Parent:WaitForChild("ZoneBounds"))
local PlayerLevelProgression = require(ServerScriptService.SharedModules.PlayerLevelProgression)

------------------------------------------------------------------ settings
local CONFIG = {
	StartDelay = 120, -- seconds after the server starts before it appears
	MaxHealth = 2000,
	KillXP = 200, -- every player who hit it gets this (Brute = 75, zombie = 15)
	RespawnTime = 180,
	DisplayName = "Sandworm",
	HealthBarDistance = 250,

	-- moving underground
	TurnRadius = 20, -- tightest bend; tighter than ~18 opens gaps between the rings
	DeepDepth = 26, -- far away: only the wake shows
	FinDepthFar = 14, -- fins just start breaking the ground
	FinDepthNear = 8, -- fins at full height (any shallower and the top of its back shows)
	DipDepth = 19, -- dips under the target right before it bursts up
	FarRange = 170, -- beyond this it travels deep and fast
	FarSpeed = 40,
	NearSpeed = 30,
	DipSpeed = 26,
	RoamSpeed = 22,
	ApproachTimeout = 30, -- gives up on a target it can't catch after this long
	RestAfterStrike = 4, -- swims off for this long before going after the next target

	-- Bite
	SurfaceTime = 8, -- seconds it stays up after a bite
	SurfaceHeight = 16, -- how high the head stands while it's up
	BiteRadius = 11,
	BiteDamage = 50,
	BiteBlockable = false, -- it comes from under you

	-- Head Smack (also how it dives back down after a bite)
	SmackRadius = 11,
	SmackDamage = 35,
	SmackBlockable = true,
	SmackWindup = 0.9, -- rears up this long before coming down
	SmackMinRange = 20, -- only smacks players this far from where it stands...
	SmackMaxRange = 60, -- ...and no farther than this

	-- Tail Whip
	TailDamage = 30,
	TailBlockable = true,
	TailHitRadius = 4.5,

	PatternWeights = { Bite = 4, HeadSmack = 3, TailWhip = 3 },

	SafeZoneMargin = 35, -- stays at least this far from the SafeZone pad
	RoarSound = 9114628113, -- played on clients (SandWormRenderer)
}

------------------------------------------------------------------ setup
local Characters = workspace:WaitForChild("Characters")
local Requests = ServerStorage:WaitForChild("Requests")
local DamageHumanoid = Requests:WaitForChild("DamageHumanoid")
local SafeZone = workspace:WaitForChild("SafeZone")

local UP = Vector3.yAxis
local HIDE = CFrame.new(0, -150, 0)

-- network
local old = ReplicatedStorage:FindFirstChild("SandWormNet")
if old then
	old:Destroy()
end
local net = Instance.new("Folder")
net.Name = "SandWormNet"
local Pose = Instance.new("UnreliableRemoteEvent") -- head position 20x a second
Pose.Name = "Pose"
Pose.Parent = net
local Fx = Instance.new("RemoteEvent") -- one-off events: warnings, bursts, slams, roars, tail whips
Fx.Name = "Fx"
Fx.Parent = net
local Snapshot = Instance.new("RemoteFunction") -- the whole body, for players who join mid-fight
Snapshot.Name = "Snapshot"
Snapshot.Parent = net
net.Parent = ReplicatedStorage

-- the server-side worm: invisible hitboxes + a Humanoid (players see the renderer's copy)
local oldModel = Characters:FindFirstChild("SandWorm")
if oldModel then
	oldModel:Destroy()
end
local model = Instance.new("Model")
model.Name = "SandWorm"
model:SetAttribute("ArenaBot", true) -- zombies and Brutes never hit it (HitDetection)
model:SetAttribute("State", "Dormant")
model:SetAttribute("HeadMode", "None")

local function box(name, size)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Transparency = 1
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.CFrame = HIDE
	p.Parent = model
	return p
end

local hrp = box("HumanoidRootPart", Vector3.new(10, 10, 10))
model.PrimaryPart = hrp
local hurt = {}
for i = 1, 10 do
	hurt[i] = box("Hurtbox" .. i, Vector3.new(8, 8, 8))
end

-- hit sounds / particles every combat target carries (same as players, zombies and Brutes)
do
	local assets = ServerStorage:FindFirstChild("Assets")
	local hrpAssets = assets and assets:FindFirstChild("HumanoidRootPart")
	if hrpAssets then
		for _, asset in ipairs(hrpAssets:GetChildren()) do
			asset:Clone().Parent = hrp
		end
	end
end
-- far too big to be knocked around by punches
hrp.ChildAdded:Connect(function(child)
	if child:IsA("BodyVelocity") then
		task.defer(function()
			if child.Parent then
				child:Destroy()
			end
		end)
	end
end)
model.Parent = Characters

------------------------------------------------------------------ helpers
local function flat(v, fallback)
	local f = Vector3.new(v.X, 0, v.Z)
	if f.Magnitude < 1e-4 then
		return fallback or Vector3.xAxis
	end
	return f.Unit
end

local function flatDist(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function ground(p, fallback)
	return (Shared.ground(p.X, p.Z, fallback))
end

-- inside the SafeZone pad's footprint grown by `margin` (height ignored, like ServerHandler)
local function nearSafe(p, margin)
	local lp = SafeZone.CFrame:PointToObjectSpace(p)
	return math.abs(lp.X) <= SafeZone.Size.X / 2 + margin and math.abs(lp.Z) <= SafeZone.Size.Z / 2 + margin
end

local function inMap(p)
	return ZoneBounds.contains("DesertZone", p) or ZoneBounds.contains("SnowZone", p)
end

local function turnToward(a, b, maxAng)
	local c = math.clamp(a:Dot(b), -1, 1)
	local ang = math.acos(c)
	if ang <= maxAng or ang < 1e-5 then
		return b
	end
	local axis = a:Cross(b)
	if axis.Magnitude < 1e-6 then
		axis = (math.abs(a.Y) < 0.9) and a:Cross(UP) or a:Cross(Vector3.xAxis)
	end
	return CFrame.fromAxisAngle(axis.Unit, maxAng):VectorToWorldSpace(a).Unit
end

-- path pieces the head can follow exactly: a straight line, and a circular arc
local function lineSeg(p, dir, len)
	return {
		len = len,
		at = function(s)
			return p + dir * s, dir
		end,
	}
end

-- arc starting at p heading h, turning toward direction d with radius R (n = which way to curl, optional)
local function arcSeg(p, h, d, R, n)
	local c0 = math.clamp(h:Dot(d), -1, 1)
	local theta = math.acos(c0)
	n = n or (d - h * c0)
	if n.Magnitude < 1e-4 then
		n = (math.abs(h.Y) < 0.9) and (UP - h * h.Y) or (Vector3.xAxis - h * h.X)
	end
	n = n.Unit
	local centre = p + n * R
	return {
		len = R * theta,
		at = function(s)
			local ph = s / R
			local cp, sp = math.cos(ph), math.sin(ph)
			return centre + (-n * cp + h * sp) * R, (h * cp + n * sp).Unit
		end,
	}
end

------------------------------------------------------------------ who it hunts
local seasonKills, sessionKills, seenKills = {}, {}, {}
KillTracker.KillUpdated.Event:Connect(function(plr, kills)
	if seenKills[plr] and kills == (seasonKills[plr] or 0) + 1 then
		sessionKills[plr] = (sessionKills[plr] or 0) + 1
	end
	seenKills[plr] = true
	seasonKills[plr] = kills
end)
Players.PlayerRemoving:Connect(function(plr)
	seasonKills[plr], sessionKills[plr], seenKills[plr] = nil, nil, nil
end)

-- the player's root if they can be hunted right now
local function validTarget(plr)
	local ch = plr and plr.Character
	if not ch or ch.Parent ~= Characters then
		return nil
	end
	local h = ch:FindFirstChildOfClass("Humanoid")
	local r = ch:FindFirstChild("HumanoidRootPart")
	if not h or not r or h.Health <= 0 then
		return nil
	end
	if nearSafe(r.Position, CONFIG.SafeZoneMargin) or ch:FindFirstChildWhichIsA("ForceField") then
		return nil
	end
	return r
end

-- #1 on the Kills board, then most kills this session, then everyone else
local function targetOrder()
	local list = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if validTarget(plr) then
			table.insert(list, plr)
		end
	end
	if #list <= 1 then
		return list
	end
	table.sort(list, function(a, b)
		local sa, sb = seasonKills[a] or 0, seasonKills[b] or 0
		if sa ~= sb then
			return sa > sb
		end
		return a.UserId < b.UserId
	end)
	local order = { list[1] }
	local rest = {}
	for i = 2, #list do
		rest[#rest + 1] = list[i]
	end
	table.sort(rest, function(a, b)
		local na, nb = sessionKills[a] or 0, sessionKills[b] or 0
		if na ~= nb then
			return na > nb
		end
		local sa, sb = seasonKills[a] or 0, seasonKills[b] or 0
		if sa ~= sb then
			return sa > sb
		end
		return a.UserId < b.UserId
	end)
	for _, plr in ipairs(rest) do
		order[#order + 1] = plr
	end
	return order
end

local function randomMapPoint(minFromSafe, minFromPlayers)
	local best
	for _ = 1, 60 do
		local p = Vector3.new(math.random(-1650, 480), 0, math.random(990, 2850))
		if inMap(p) and not nearSafe(p, minFromSafe) then
			local ok = true
			if minFromPlayers then
				for _, plr in ipairs(Players:GetPlayers()) do
					local r = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
					if r and flatDist(r.Position, p) < minFromPlayers then
						ok = false
						break
					end
				end
			end
			best = p
			if ok then
				return p
			end
		end
	end
	return best or Vector3.new(-1077, 0, 2153)
end

------------------------------------------------------------------ state
local head = { pos = HIDE.Position, dir = -Vector3.zAxis, speed = 0 }
local trail = Shared.newTrail(110)
local mode = "off" -- off | steer | plan | hold
local steerGoal = nil -- function() -> goal Vector3, depth, speed
local plan = nil
local maw, mawTarget, mawRate = 0, 0, 1
local tailSpec = nil
local alive = false
local showing = false -- sending the head to clients (alive, or still sinking after death)
local hum, bar
local contributors = {}
local strikeQueue = {}
local hrpLockUntil = 0

local function setMaw(v, t)
	mawTarget = v
	mawRate = math.abs(v - maw) / math.max(t or 0.15, 0.02)
end

local function setState(s)
	model:SetAttribute("State", s)
end

local function roar()
	Fx:FireAllClients("Roar")
	setMaw(1.3, 0.25)
	task.delay(1.1, function()
		if alive and mawTarget >= 1.3 then
			setMaw(0.05, 0.4)
		end
	end)
end

------------------------------------------------------------------ health bar (built on the server so every player sees it)
local function makeHealthBar(h)
	local gui = Instance.new("BillboardGui")
	gui.Name = "HealthBar"
	gui.Size = UDim2.fromOffset(220, 44)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 22, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = CONFIG.HealthBarDistance
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Enabled = false

	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(1, 0, 0, 18)
	name.Font = Enum.Font.GothamBold
	name.TextSize = 16
	name.TextColor3 = Color3.fromRGB(255, 220, 160)
	name.TextStrokeColor3 = Color3.fromRGB(30, 18, 6)
	name.TextStrokeTransparency = 0.3
	name.Text = CONFIG.DisplayName
	name.Parent = gui

	local back = Instance.new("Frame")
	back.Position = UDim2.fromOffset(0, 21)
	back.Size = UDim2.new(1, 0, 0, 20)
	back.BackgroundColor3 = Color3.fromRGB(26, 18, 10)
	back.BackgroundTransparency = 0.15
	back.BorderSizePixel = 0
	back.ClipsDescendants = true
	back.Parent = gui
	Instance.new("UICorner", back).CornerRadius = UDim.new(0, 5)
	local stroke = Instance.new("UIStroke", back)
	stroke.Color = Color3.fromRGB(120, 220, 255)
	stroke.Thickness = 1.5

	local trailBar = Instance.new("Frame")
	trailBar.Size = UDim2.fromScale(1, 1)
	trailBar.BackgroundColor3 = Color3.fromRGB(255, 245, 230)
	trailBar.BorderSizePixel = 0
	trailBar.Parent = back
	Instance.new("UICorner", trailBar).CornerRadius = UDim.new(0, 5)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BorderSizePixel = 0
	fill.Parent = back
	Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 5)
	local shine = Instance.new("UIGradient", fill)
	shine.Rotation = 90
	shine.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(170, 170, 170))

	local hp = Instance.new("TextLabel")
	hp.BackgroundTransparency = 1
	hp.Size = UDim2.fromScale(1, 1)
	hp.ZIndex = 3
	hp.Font = Enum.Font.GothamBold
	hp.TextSize = 14
	hp.TextColor3 = Color3.new(1, 1, 1)
	hp.TextStrokeColor3 = Color3.fromRGB(20, 12, 4)
	hp.TextStrokeTransparency = 0.2
	hp.Parent = back

	local function update()
		local frac = math.clamp(h.Health / h.MaxHealth, 0, 1)
		fill.Size = UDim2.fromScale(frac, 1)
		if frac > 0.5 then
			fill.BackgroundColor3 = Color3.fromRGB(230, 180, 90) -- sand
		elseif frac > 0.25 then
			fill.BackgroundColor3 = Color3.fromRGB(255, 140, 60)
		else
			fill.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
		end
		hp.Text = string.format("%d / %d", math.max(math.ceil(h.Health), 0), h.MaxHealth)
		if trailBar.Size.X.Scale <= frac then
			trailBar.Size = fill.Size
		else
			TweenService:Create(trailBar, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.3), {
				Size = fill.Size,
			}):Play()
		end
	end
	update()
	h.HealthChanged:Connect(update)
	gui.Parent = hrp
	return gui
end

------------------------------------------------------------------ dying, rewards, respawning
local onDeath -- below

local function newHumanoid()
	if hum then
		hum:Destroy()
	end
	if bar then
		bar:Destroy()
	end
	table.clear(contributors)
	for _, c in ipairs(model:GetChildren()) do
		if c.Name == "Stun" or c.Name == "Knocked" then
			c:Destroy()
		end
	end
	hum = Instance.new("Humanoid")
	hum.MaxHealth = CONFIG.MaxHealth
	hum.Health = CONFIG.MaxHealth
	hum.WalkSpeed = 0
	hum.UseJumpPower = true
	hum.JumpPower = 0
	hum.RequiresNeck = false
	hum.BreakJointsOnDeath = false
	hum.DisplayName = CONFIG.DisplayName
	hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	for _, st in ipairs({
		Enum.HumanoidStateType.FallingDown,
		Enum.HumanoidStateType.Ragdoll,
		Enum.HumanoidStateType.Climbing,
		Enum.HumanoidStateType.Swimming,
		Enum.HumanoidStateType.Seated,
		Enum.HumanoidStateType.Jumping,
		Enum.HumanoidStateType.Freefall,
	}) do
		hum:SetStateEnabled(st, false)
	end
	-- remember everyone who lands a hit (ServerHandler writes their UserId into this tag on every hit)
	local myHum = hum
	hum.ChildAdded:Connect(function(c)
		if c.Name == "LastAttacker" and c:IsA("IntValue") then
			local function record()
				if c.Value ~= 0 and myHum == hum then
					contributors[c.Value] = true
				end
			end
			record()
			c.Changed:Connect(record)
		end
	end)
	hum.HealthChanged:Connect(function(hp)
		if hp <= 0 and alive and myHum == hum then
			onDeath()
		end
	end)
	hum.Parent = model
	bar = makeHealthBar(hum)
end

local function spawnWorm()
	newHumanoid()
	local p = randomMapPoint(250, 150)
	local g = ground(p)
	local a = math.random() * math.pi * 2
	head.dir = Vector3.new(math.cos(a), 0, math.sin(a))
	head.pos = Vector3.new(p.X, g - 30, p.Z)
	head.speed = 10
	trail:reset(head.pos, head.dir, 100)
	maw, mawTarget = 0, 0
	tailSpec = nil
	alive = true
	showing = true
	Fx:FireAllClients("Reset", head.pos, head.dir)
	setState("Roam")
	model:SetAttribute("HeadMode", "None")
	steerGoal = function()
		return head.pos + head.dir * 50, CONFIG.DeepDepth, CONFIG.RoamSpeed
	end
	mode = "steer"
end

onDeath = function()
	alive = false
	tailSpec = nil
	mode = "hold"
	table.clear(strikeQueue)
	setState("Dead")
	model:SetAttribute("HeadMode", "None")
	Fx:FireAllClients("Roar")
	setMaw(1.3, 0.2)
	-- everyone who hit it gets the kill and the XP (deferred a frame so the killing blow's tag is in)
	local deadHum = hum
	task.defer(function()
		local tag = deadHum and deadHum:FindFirstChild("LastAttacker")
		if tag and tag.Value ~= 0 then
			contributors[tag.Value] = true
		end
		local credited = 0
		for userId in pairs(contributors) do
			local plr = Players:GetPlayerByUserId(userId)
			if plr then
				credited += 1
				pcall(PlayerLevelProgression.AwardXP, plr, CONFIG.KillXP)
				pcall(KillTracker.RecordKill, plr)
			end
		end
		print(string.format("[SandWorm] killed - %d player(s) credited (%d XP each)", credited, CONFIG.KillXP))
	end)
	task.delay(5, function()
		if not alive then
			showing = false
			mode = "off"
			head.pos = HIDE.Position
			setState("Gone")
		end
	end)
	task.delay(CONFIG.RespawnTime, function()
		if not alive then
			spawnWorm()
		end
	end)
end

------------------------------------------------------------------ hitting players
-- One victim per frame: the root is turned to face away from the hit first, so the game's own knockback
-- throws them outward (the damage event may run at the end of the frame).
local function queueStrike(ch, from, push, props)
	table.insert(strikeQueue, { ch = ch, from = from, push = flat(push, Vector3.xAxis), props = props })
end

local function strikeArea(centre, radius, yMin, yMax, props)
	for _, plr in ipairs(Players:GetPlayers()) do
		local ch = plr.Character
		local r = ch and ch:FindFirstChild("HumanoidRootPart")
		local h = ch and ch:FindFirstChildOfClass("Humanoid")
		if r and h and h.Health > 0 and ch.Parent == Characters then
			local dp = r.Position - centre
			if Vector3.new(dp.X, 0, dp.Z).Magnitude <= radius and dp.Y >= yMin and dp.Y <= yMax then
				queueStrike(ch, centre, dp, table.clone(props))
			end
		end
	end
end

local function processStrikeQueue()
	local job = table.remove(strikeQueue, 1)
	if not job or not alive then
		return
	end
	local ch = job.ch
	if not ch.Parent or not ch:FindFirstChild("HumanoidRootPart") then
		return
	end
	hrp.CFrame = CFrame.lookAt(job.from, job.from + job.push)
	hrpLockUntil = os.clock() + 0.12
	DamageHumanoid:Fire(model, ch, job.props)
end

------------------------------------------------------------------ hitboxes on the parts above ground
local exposed = false
local exposeUntil = 0 -- after a surfacing the body takes a few seconds to pour back under
local function updateHurt()
	-- just swimming (it never swims shallow enough for its back to show): nothing to hit, nothing to move.
	-- Skipping this keeps the hitboxes and root still, so they aren't re-sent to every player all the time.
	if alive and mode == "steer" and not tailSpec and os.clock() > exposeUntil then
		for _, b in ipairs(hurt) do
			if b.CanQuery then
				b.CanQuery = false
				b.CFrame = HIDE
			end
		end
		if hrp.CanQuery then
			hrp.CanQuery = false
		end
		if bar and bar.Enabled then
			bar.Enabled = false
		end
		exposed = false
		return
	end
	if not alive then
		for _, b in ipairs(hurt) do
			if b.CanQuery then
				b.CanQuery = false
				b.CFrame = HIDE
			end
		end
		hrp.CanQuery = false
		if bar then
			bar.Enabled = false
		end
		return
	end
	local used = 0
	local function place(p)
		used += 1
		local b = hurt[used]
		b.CFrame = CFrame.new(p)
		b.CanQuery = true
	end
	local headOut = head.pos.Y > ground(head.pos, head.pos.Y) - 2
	-- the body near ground level (where punches can reach it)
	for d = 5, 65, 6 do
		if used >= #hurt then
			break
		end
		local p = trail:pos(d)
		local h = p.Y - ground(p, p.Y)
		if h > -3.5 and h < 9 then
			place(p)
		end
	end
	local tailOut, tailRho, tailA = false, nil, nil
	if tailSpec then
		tailRho, tailA = Shared.tailState(tailSpec, workspace:GetServerTimeNow())
		if tailRho and tailRho > 0.25 then
			tailOut = true
			for _, u in ipairs({ 1, 6, 11, 16 }) do
				if used < #hurt then
					local p = Shared.tailAt(tailSpec, tailRho, tailA, u)
					if p.Y > tailSpec.T0.Y - 3 then
						place(p)
					end
				end
			end
		end
	end
	for i = used + 1, #hurt do
		local b = hurt[i]
		if b.CanQuery then
			b.CanQuery = false
			b.CFrame = HIDE
		end
	end
	if os.clock() >= hrpLockUntil then
		if tailOut and not headOut then
			hrp.CFrame = CFrame.new((Shared.tailAt(tailSpec, tailRho, tailA, 3)))
			if bar then
				bar.StudsOffsetWorldSpace = Vector3.new(0, 9, 0)
			end
		else
			hrp.CFrame = CFrame.new(head.pos)
			if bar then
				bar.StudsOffsetWorldSpace = Vector3.new(0, 22, 0)
			end
		end
	end
	hrp.CanQuery = headOut or tailOut
	exposed = headOut or tailOut or used > 0
	if bar then
		bar.Enabled = exposed
	end
end

------------------------------------------------------------------ moving the head
local function safePush(p)
	local lp = SafeZone.CFrame:PointToObjectSpace(p)
	local ex = SafeZone.Size.X / 2 + CONFIG.SafeZoneMargin + 40
	local ez = SafeZone.Size.Z / 2 + CONFIG.SafeZoneMargin + 40
	if math.abs(lp.X) < ex and math.abs(lp.Z) < ez then
		local k = 1 - math.max(math.abs(lp.X) / ex, math.abs(lp.Z) / ez)
		return flat(p - SafeZone.Position) * (0.5 + 3 * k)
	end
	return nil
end

local function steerTick(dt)
	local goal, depth, speed = steerGoal()
	head.speed += math.clamp(speed - head.speed, -25 * dt, 25 * dt)
	local p = head.pos
	local hz = Vector3.new(goal.X - p.X, 0, goal.Z - p.Z)
	local hdir = (hz.Magnitude > 0.5) and hz.Unit or flat(head.dir)
	local push = safePush(p)
	if push then
		hdir = (hdir + push).Unit
	end
	-- look ahead so it dives before a dune drops away under it (otherwise its back breaks the surface)
	local g = ground(p, p.Y + depth)
	local gAhead = ground(p + hdir * 24, g)
	local vy = math.clamp((math.min(g, gAhead) - depth - p.Y) / 12, -0.75, 0.75)
	local desired = (hdir + Vector3.new(0, vy, 0)).Unit
	head.dir = turnToward(head.dir, desired, head.speed * dt / CONFIG.TurnRadius)
	local np = p + head.dir * head.speed * dt
	-- never lets its back break the surface while just swimming (only the fins may show, and it can't be hit)
	local g2 = ground(np, g)
	if np.Y > g2 - 7.5 then
		np = Vector3.new(np.X, g2 - 7.5, np.Z)
	end
	head.pos = np
end

local function planTick(dt)
	local step = plan.steps[plan.i]
	local len = math.max(step.seg.len, 1e-3)
	local v = step.v0 + (step.v1 - step.v0) * math.clamp(plan.s / len, 0, 1)
	plan.s += v * dt
	while plan.s >= step.seg.len do
		plan.s -= step.seg.len
		plan.i += 1
		local nextStep = plan.steps[plan.i]
		if not nextStep then
			plan.done = true
			head.pos, head.dir = step.seg.at(step.seg.len)
			head.speed = step.v1
			if plan.onTick then
				plan.onTick(head.pos, head.dir, plan.i - 1, 1)
			end
			return
		end
		step = nextStep
	end
	head.pos, head.dir = step.seg.at(plan.s)
	head.speed = v
	if plan.onTick then
		plan.onTick(head.pos, head.dir, plan.i, plan.s / math.max(step.seg.len, 1e-3))
	end
end

-- follow a list of path pieces; returns false if it died on the way
local function runPlan(steps, onTick)
	plan = { steps = steps, i = 1, s = 0, done = false, onTick = onTick }
	mode = "plan"
	while alive and not plan.done do
		task.wait()
	end
	return alive and plan.done
end

local function waitAlive(seconds)
	local t0 = os.clock()
	while alive and os.clock() - t0 < seconds do
		task.wait()
	end
	return alive
end

local netAcc, hurtAcc = 0, 0
RunService.Heartbeat:Connect(function(dt)
	dt = math.min(dt, 0.1)
	if alive then
		if mode == "steer" and steerGoal then
			steerTick(dt)
		elseif mode == "plan" and plan and not plan.done then
			planTick(dt)
		end
	end
	if maw ~= mawTarget then
		local stepM = mawRate * dt
		if math.abs(mawTarget - maw) <= stepM then
			maw = mawTarget
		else
			maw += stepM * math.sign(mawTarget - maw)
		end
	end
	if showing then
		trail:push(head.pos)
		netAcc += dt
		if netAcc >= 0.05 then
			netAcc = 0
			Pose:FireAllClients(workspace:GetServerTimeNow(), head.pos, maw)
		end
	end
	processStrikeQueue()
	if mode == "plan" or mode == "hold" or tailSpec then
		exposeUntil = os.clock() + 4
	end
	hurtAcc += dt
	if hurtAcc >= 1 / 15 then
		hurtAcc = 0
		updateHurt()
	end
end)

------------------------------------------------------------------ attacks
-- Curving straight up out of the ground from where the head is now. Returns the arc and the spot where
-- the head breaks the surface (the radius is solved so the arc ends right at ground level).
local function emergeArc(pos, dir)
	if dir.Y < -0.45 then
		return nil
	end
	local R = math.max(12, ground(pos, pos.Y) - pos.Y)
	local seg, E
	for _ = 1, 4 do
		seg = arcSeg(pos, dir, UP, R)
		E = seg.at(seg.len)
		local rise = E.Y - pos.Y
		if rise < 1 then
			return nil
		end
		R = R * (ground(E, E.Y) - pos.Y) / rise
		if R < 12 or R > 34 then
			return nil
		end
	end
	seg = arcSeg(pos, dir, UP, R)
	E = seg.at(seg.len)
	return seg, Vector3.new(E.X, ground(E, E.Y), E.Z)
end

local function pickSmackVictim(top, prefer)
	local best, bestD = nil, nil
	for _, plr in ipairs(Players:GetPlayers()) do
		local r = validTarget(plr)
		if r then
			local d = flatDist(r.Position, top)
			if d >= CONFIG.SmackMinRange and d <= CONFIG.SmackMaxRange then
				if plr == prefer then
					return r
				end
				if not bestD or d < bestD then
					best, bestD = r, d
				end
			end
		end
	end
	return best
end

-- From standing straight up at `top`: rear up, arc over and slam the head down, then dive back under.
local function smackDive(top, prefer)
	local victim = pickSmackVictim(top, prefer)
	local dirH, r
	if victim then
		dirH = flat(victim.Position - top)
		r = math.clamp(flatDist(victim.Position, top) / 2, 14, 26)
	else
		dirH, r = nil, 18
		for _ = 1, 10 do
			local a = math.random() * math.pi * 2
			local d = Vector3.new(math.cos(a), 0, math.sin(a))
			local land = top + d * 2 * r
			if not nearSafe(land, 15) and inMap(land) then
				dirH = d
				break
			end
		end
		dirH = dirH or flat(top - SafeZone.Position)
	end
	if nearSafe(top + dirH * 2 * r, 15) then
		dirH = -dirH
	end
	local arc = arcSeg(top, UP, -UP, r, dirH)
	local A1 = arc.at(arc.len)
	local gL = ground(A1, top.Y - CONFIG.SurfaceHeight)
	local L = Vector3.new(A1.X, gL, A1.Z)
	local down = lineSeg(A1, -UP, math.max(A1.Y - gL, 0) + 14)
	local B = down.at(down.len)
	local turn = arcSeg(B, -UP, dirH, 18)

	-- wind up: rears and roars, the landing spot cracks so it can be dodged
	setState("Surfaced")
	model:SetAttribute("HeadMode", "Rear")
	roar()
	local travel = arc.len / 40 + math.max(A1.Y - gL - Shared.MAW_LEN, 0) / 50
	Fx:FireAllClients("Warn", L, CONFIG.SmackRadius, CONFIG.SmackWindup + travel)
	if not waitAlive(CONFIG.SmackWindup) then
		return false
	end
	model:SetAttribute("HeadMode", "None")
	setState("Attack")
	setMaw(0.9, 0.3)
	local slammed = false
	local ok = runPlan({
		{ seg = arc, v0 = 34, v1 = 46 },
		{ seg = down, v0 = 50, v1 = 40 },
		{ seg = turn, v0 = 34, v1 = 30 },
	}, function(pos, dir)
		if not slammed and dir.Y < -0.5 then
			local tip = pos + dir * Shared.MAW_LEN
			if tip.Y <= gL + 0.5 then
				slammed = true
				setMaw(0, 0.15)
				Fx:FireAllClients("Slam", L, CONFIG.SmackRadius)
				strikeArea(L, CONFIG.SmackRadius, -4, 10, {
					damage = CONFIG.SmackDamage,
					block = CONFIG.SmackBlockable,
					combo = 4,
					knockback = true,
					ragdoll = true,
				})
			end
		end
	end)
	setMaw(0, 0.3)
	return ok
end

-- Bite: the arc is already lined up under the target.
local function doBite(seg, E)
	setState("Attack")
	local v = CONFIG.DipSpeed
	Fx:FireAllClients("Warn", E, CONFIG.BiteRadius, seg.len / (v * 1.15))
	local top = E + Vector3.new(0, CONFIG.SurfaceHeight, 0)
	local rise = lineSeg(E, UP, CONFIG.SurfaceHeight)
	local burst, bitten = false, false
	local t0 = os.clock()
	local ok = runPlan({
		{ seg = seg, v0 = v, v1 = v * 1.3 },
		{ seg = rise, v0 = 36, v1 = 4 },
	}, function(pos, dir, i, frac)
		if i == 1 and frac > 0.45 and mawTarget < 1 and not bitten then
			setMaw(1.15, 0.35) -- opens underground
		end
		local tip = pos + dir * Shared.MAW_LEN
		if not burst and tip.Y >= E.Y - 0.5 then
			burst = true
			Fx:FireAllClients("Burst", E)
		end
		if not bitten and pos.Y >= E.Y - 3 then
			bitten = true
			setMaw(1.2, 0.05)
			task.delay(0.08, function()
				setMaw(0, 0.12) -- snaps shut
			end)
			strikeArea(E, CONFIG.BiteRadius, -4, 14, {
				damage = CONFIG.BiteDamage,
				block = CONFIG.BiteBlockable,
				combo = 4,
				knockback = true,
				ragdoll = true,
			})
		end
	end)
	if not ok then
		return false
	end
	-- stays up: roar, a double chomp, another roar, then it dives (smacking whoever it can reach)
	mode = "hold"
	head.pos, head.dir = top, UP
	setState("Surfaced")
	model:SetAttribute("HeadMode", "Idle")
	-- SurfaceTime counts from the bite (the end of the arc) and includes the smack wind-up
	local stay = CONFIG.SurfaceTime - (os.clock() - t0 - seg.len / (v * 1.15)) - CONFIG.SmackWindup
	task.delay(0.8, function()
		if alive and model:GetAttribute("HeadMode") == "Idle" then
			roar()
		end
	end)
	task.delay(3.4, function()
		if alive and model:GetAttribute("HeadMode") == "Idle" then
			setMaw(0.75, 0.12)
			task.wait(0.14)
			setMaw(0, 0.12)
			task.wait(0.14)
			setMaw(0.6, 0.12)
			task.wait(0.14)
			setMaw(0, 0.12)
		end
	end)
	if not waitAlive(math.max(stay, 3)) then
		return false
	end
	return smackDive(top)
end

-- Head Smack: breaches a short way in front of the target, then rears up and slams down on them.
local function doBreach(seg, E, plr)
	setState("Attack")
	local v = CONFIG.DipSpeed
	local top = E + Vector3.new(0, CONFIG.SurfaceHeight, 0)
	local rise = lineSeg(E, UP, CONFIG.SurfaceHeight)
	local burst = false
	local ok = runPlan({
		{ seg = seg, v0 = v, v1 = v * 1.3 },
		{ seg = rise, v0 = 36, v1 = 4 },
	}, function(pos, dir)
		local tip = pos + dir * Shared.MAW_LEN
		if not burst and tip.Y >= E.Y - 0.5 then
			burst = true
			Fx:FireAllClients("Burst", E)
		end
	end)
	if not ok then
		return false
	end
	mode = "hold"
	head.pos, head.dir = top, UP
	return smackDive(top, plr)
end

-- Tail Whip: the tail rips up beside the target and sweeps across while the head circles underneath.
local function doTailWhip(targetRoot)
	local X = targetRoot.Position
	local side = flat(head.dir):Cross(UP).Unit * ((math.random() < 0.5) and 1 or -1)
	local T0
	for _, s in ipairs({ side, -side, -flat(head.dir) }) do
		local c = X + s * Shared.TAIL.Reach
		if not nearSafe(c, 8) then
			T0, side = c, s
			break
		end
	end
	if not T0 then
		return false
	end
	T0 = Vector3.new(T0.X, ground(T0, X.Y - 3), T0.Z)
	local spec = { T0 = T0, aMid = -side, sign = (math.random() < 0.5) and 1 or -1, t0 = workspace:GetServerTimeNow() }
	tailSpec = spec
	Fx:FireAllClients("Tail", spec.T0, spec.aMid, spec.sign, spec.t0)
	Fx:FireAllClients("Warn", T0, 7, Shared.TAIL.Warn)
	setState("Attack")
	local orbitA = math.atan2(head.pos.Z - T0.Z, head.pos.X - T0.X)
	steerGoal = function()
		orbitA += 0.012
		return T0 + Vector3.new(math.cos(orbitA) * 28, 0, math.sin(orbitA) * 28), 16, 18
	end
	mode = "steer"
	local hitDone = {}
	while alive do
		local rho, a, _, sweeping = Shared.tailState(spec, workspace:GetServerTimeNow())
		if not rho then
			break
		end
		if sweeping then
			local tangent = UP:Cross(a) * spec.sign
			for _, plr in ipairs(Players:GetPlayers()) do
				local ch = plr.Character
				local r = ch and ch:FindFirstChild("HumanoidRootPart")
				local h = ch and ch:FindFirstChildOfClass("Humanoid")
				if r and h and h.Health > 0 and not hitDone[plr] and ch.Parent == Characters then
					for u = 0, 10, 2.5 do
						local p = Shared.tailAt(spec, rho, a, u)
						if (r.Position - p).Magnitude <= CONFIG.TailHitRadius then
							hitDone[plr] = true
							queueStrike(ch, p, tangent, {
								damage = CONFIG.TailDamage,
								block = CONFIG.TailBlockable,
								combo = 3,
								knockback = true,
							})
							break
						end
					end
				end
			end
		end
		task.wait()
	end
	tailSpec = nil
	return alive
end

------------------------------------------------------------------ hunting
local function pickPattern(last)
	local forced = RunService:IsStudio() and script:GetAttribute("ForcePattern")
	if forced and CONFIG.PatternWeights[forced] then
		return forced
	end
	local total, pool = 0, {}
	for name, w in pairs(CONFIG.PatternWeights) do
		if name ~= last and w > 0 then
			table.insert(pool, name)
			total += w
		end
	end
	if #pool == 0 then
		return last or "Bite"
	end
	local roll = math.random() * total
	for _, name in ipairs(pool) do
		roll -= CONFIG.PatternWeights[name]
		if roll <= 0 then
			return name
		end
	end
	return pool[#pool]
end

-- swim after one player and hit them with `pattern`. Returns "struck", "lost" or "dead".
local function huntAndStrike(plr, pattern)
	setState("Hunt")
	local lastGoal = head.pos
	local dipAt = (pattern == "HeadSmack") and 120 or 60
	steerGoal = function()
		local r = validTarget(plr)
		if r then
			lastGoal = r.Position
		end
		local d = flatDist(lastGoal, head.pos)
		if d > CONFIG.FarRange then
			return lastGoal, CONFIG.DeepDepth, CONFIG.FarSpeed
		end
		if pattern ~= "TailWhip" and d < dipAt then
			return lastGoal, CONFIG.DipDepth, CONFIG.DipSpeed
		end
		local k = math.clamp((CONFIG.FarRange - d) / (CONFIG.FarRange - dipAt), 0, 1)
		local depth = CONFIG.FinDepthFar + (CONFIG.FinDepthNear - CONFIG.FinDepthFar) * k
		if pattern == "TailWhip" then
			depth = math.max(depth, 11)
		end
		return lastGoal, depth, CONFIG.NearSpeed
	end
	mode = "steer"
	local t0 = os.clock()
	local nextCheck = 0
	while alive do
		if os.clock() - t0 > CONFIG.ApproachTimeout then
			return "lost"
		end
		local r = validTarget(plr)
		if not r then
			return "lost"
		end
		local d = flatDist(r.Position, head.pos)
		-- the burst geometry only needs re-checking ~12 times a second, not every frame
		if os.clock() < nextCheck then
			d = math.huge
		else
			nextCheck = os.clock() + 0.08
		end
		if pattern == "Bite" and d < 40 then
			local seg, E = emergeArc(head.pos, head.dir)
			if seg and flatDist(E, r.Position) <= 9 and not nearSafe(E, 15) then
				return doBite(seg, E) and "struck" or "dead"
			end
		elseif pattern == "HeadSmack" and d < 110 then
			local seg, E = emergeArc(head.pos, head.dir)
			if seg and not nearSafe(E, 15) then
				local dE = flatDist(E, r.Position)
				if dE >= 30 and dE <= 52 and flat(r.Position - E):Dot(flat(head.dir)) > 0.75 then
					return doBreach(seg, E, plr) and "struck" or "dead"
				end
			end
		elseif pattern == "TailWhip" and d < 40 then
			return doTailWhip(r) and "struck" or "lost"
		end
		task.wait()
	end
	return "dead"
end

local function swimOff(seconds, from)
	setState("Roam")
	local goal = head.pos + flat(head.pos - from, flat(head.dir)) * 150
	steerGoal = function()
		return goal, CONFIG.DeepDepth, CONFIG.RoamSpeed + 6
	end
	mode = "steer"
	waitAlive(seconds)
end

local function roam(seconds)
	setState("Roam")
	local goal = randomMapPoint(150)
	steerGoal = function()
		return goal, CONFIG.DeepDepth, CONFIG.RoamSpeed
	end
	mode = "steer"
	local t0 = os.clock()
	while alive and os.clock() - t0 < seconds do
		if flatDist(goal, head.pos) < 40 then
			goal = randomMapPoint(150)
		end
		task.wait(0.2)
	end
end

------------------------------------------------------------------ players joining mid-fight get the whole body
Snapshot.OnServerInvoke = function()
	local tail = nil
	if tailSpec then
		tail = { tailSpec.T0, tailSpec.aMid, tailSpec.sign, tailSpec.t0 }
	end
	return {
		state = model:GetAttribute("State"),
		head = head.pos,
		dir = head.dir,
		maw = maw,
		trail = showing and trail:points(1, 100) or nil,
		tail = tail,
	}
end

------------------------------------------------------------------ main loop
task.wait((RunService:IsStudio() and tonumber(script:GetAttribute("StartDelay"))) or CONFIG.StartDelay)
spawnWorm()
local rank, lastPattern = 1, nil
while true do
	if not alive then
		task.wait(0.5)
	else
		local order = targetOrder()
		if #order == 0 then
			roam(4)
		else
			local plr = order[((rank - 1) % #order) + 1]
			local pattern = pickPattern(lastPattern)
			local result = huntAndStrike(plr, pattern)
			rank += 1
			if result == "struck" then
				lastPattern = pattern
				swimOff(CONFIG.RestAfterStrike, head.pos)
			elseif result == "lost" then
				task.wait()
			end
		end
	end
end
