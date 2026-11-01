--[[
	LocalScript in StarterPlayer > StarterPlayerScripts > Client > SandWormRenderer

	Draws the Sandworm for this player. The server (ServerScriptService > Server > SandWorm) only sends where
	the head is; this builds the whole body from the 5 parts in ReplicatedStorage > Mobs > SandWorm and lays
	every ring, fin and the tail along the path the head just travelled (SandWormShared). Underground parts
	are hidden by the terrain, so the fins poking through ARE the warning.

	Also does the effects: sand/snow wake over the worm, the ground cracking before a burst or slam, the burst
	and slam dust, the roar, a rumble when it's close under you, and the sink when it dies.
	Everything here is visual only; all damage happens on the server.

	Kept light for phones (2026-10-20): no moving shadows, the body isn't drawn at all while it's deep
	underground or far away, rings are only resized while the body is out of the ground, and the dust
	scales down with the player's graphics quality.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local UserInputService = game:GetService("UserInputService")

local Shared = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("SandWormShared"))
local net = ReplicatedStorage:WaitForChild("SandWormNet")
local Pose = net:WaitForChild("Pose")
local Fx = net:WaitForChild("Fx")
local Snapshot = net:WaitForChild("Snapshot")
local templates = ReplicatedStorage:WaitForChild("Mobs"):WaitForChild("SandWorm")
local wormServer = workspace:WaitForChild("Characters"):WaitForChild("SandWorm")
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local CONFIG = {
	InterpDelay = 0.12, -- draws the head this far in the past so movement stays smooth
	DrawDistance = 600, -- doesn't draw the body past this (studs from the camera)
	Shadows = false, -- 58 moving parts casting shadows redraws the shadow map every frame; off for phones
	RoarSound = 9114628113,
	RoarPitch = 0.75,
	RoarVolume = 1.3,
	RumbleRange = 60, -- feel it under you within this distance
	RumbleStrength = 0.15,
	SinkTime = 4, -- death: sinks into the ground over this long
	HiddenDepth = 15, -- deeper than this (and not attacking) nothing of it can show, so it isn't drawn
}

-- dust amount: full on high graphics, less on low graphics and on phones/tablets
local FX_SCALE = 1
do
	local ok, q = pcall(function()
		return UserSettings().GameSettings.SavedQualityLevel.Value
	end)
	if ok and q and q > 0 then
		FX_SCALE = (q <= 3) and 0.35 or ((q <= 6) and 0.6 or 1)
	else
		FX_SCALE = 0.7 -- Automatic
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		FX_SCALE = math.min(FX_SCALE, 0.5)
	end
end

local SAND = Color3.fromRGB(196, 168, 120)
local SNOW = Color3.fromRGB(228, 236, 246)
local DIRT = Color3.fromRGB(160, 140, 112)
local function groundColor(mat)
	if mat == Enum.Material.Snow or mat == Enum.Material.Glacier or mat == Enum.Material.Ice then
		return SNOW
	elseif mat == Enum.Material.Sand or mat == Enum.Material.Sandstone then
		return SAND
	end
	return DIRT
end

local HIDE = CFrame.new(0, -150, 0)
local C = Shared.CENTER
local HS, TS = Shared.HEAD_S, Shared.TAIL_S
local RING_S, FIN_S, D, DT = Shared.RING_S, Shared.FIN_S, Shared.D, Shared.DT
local NR = #RING_S

------------------------------------------------------------------ the body parts (local only)
local visual = Instance.new("Model")
visual.Name = "SandWormVisual"

local function make(name, scale)
	local src = templates:WaitForChild(name)
	local p = src:Clone()
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = CONFIG.Shadows
	p.Size = src.Size * scale
	p.CFrame = HIDE
	p.Parent = visual
	return p
end

local headPart = make("SW_Head", HS)
local petals = {}
for k = 1, 4 do
	petals[k] = make("SW_Petal", HS)
end
local rings, fins = {}, {}
for i = 1, NR do
	rings[i] = make("SW_Ring", RING_S[i])
	fins[i] = make("SW_Fin", FIN_S[i])
end
local tailPart = make("SW_Tail", TS)

local all = { headPart }
for k = 1, 4 do
	all[#all + 1] = petals[k]
end
for i = 1, NR do
	all[#all + 1] = rings[i]
	all[#all + 1] = fins[i]
end
all[#all + 1] = tailPart
local cfs = table.create(#all, HIDE)

local ringBase = templates.SW_Ring.Size
local ringStretch = table.create(NR, 1)
local ROLLCF = {}
for i = 1, NR do
	ROLLCF[i] = CFrame.Angles(0, 0, Shared.ROLL[i])
end
-- petal pieces that don't change: spin about the beak, move to the hinge (and back + the mesh offset)
local PET_A, PET_B = {}, {}
for k = 1, 4 do
	PET_A[k] = CFrame.Angles(0, 0, math.rad(Shared.PET_SPIN[k])) * CFrame.new(Shared.HINGE)
	PET_B[k] = CFrame.new(-Shared.HINGE) * CFrame.new(C.Petal)
end
local HEAD_OFF = CFrame.new(C.Head * HS)
local TAIL_OFF = CFrame.new(C.Tail * TS)

visual.Parent = workspace

local hidden = true
local function hideAll()
	if hidden then
		return
	end
	hidden = true
	for i = 1, #all do
		cfs[i] = HIDE
	end
	workspace:BulkMoveTo(all, cfs, Enum.BulkMoveMode.FireCFrameChanged)
end

local fadeNow = 0
local function setFade(f)
	if math.abs(f - fadeNow) < 0.02 and f ~= 0 and f ~= 1 then
		return
	end
	fadeNow = f
	for _, p in ipairs(all) do
		p.LocalTransparencyModifier = f
	end
end

------------------------------------------------------------------ effects folder + emitters
local fxFolder = Instance.new("Folder")
fxFolder.Name = "SandWormFX"
fxFolder.Parent = workspace

local function fxPart(cf)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(1, 1, 1)
	p.CFrame = cf or HIDE
	p.Parent = fxFolder
	return p
end

local function dustEmitter(parent, opts)
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/smoke_main.dds"
	e.LightInfluence = 1
	e.Lifetime = opts.Lifetime or NumberRange.new(0.6, 1)
	e.Speed = opts.Speed or NumberRange.new(5, 10)
	e.SpreadAngle = opts.Spread or Vector2.new(35, 35)
	e.Acceleration = opts.Accel or Vector3.new(0, -18, 0)
	e.Drag = opts.Drag or 1
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-40, 40)
	e.Size = opts.Size or NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 4.5) })
	e.Transparency = opts.Transparency
		or NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
	e.Rate = opts.Rate or 0
	e.Color = ColorSequence.new(SAND)
	e.EmissionDirection = Enum.NormalId.Top
	e.Enabled = opts.Enabled ~= false
	e.Parent = parent
	return e
end

-- wake: the ground heaves and sprays over the head and the middle of the body
local wake = {}
for k, d in ipairs({ 0, D[12] }) do
	local part = fxPart()
	local att = Instance.new("Attachment")
	att.Parent = part
	wake[k] = { d = d, part = part, emitter = dustEmitter(att, { Rate = 0, Enabled = true }), colour = SAND, on = false }
end

-- burst / slam debris (reused)
local burstPart = fxPart()
local burstAtt = Instance.new("Attachment")
burstAtt.Parent = burstPart
local chunks = dustEmitter(burstAtt, {
	Lifetime = NumberRange.new(1, 1.8),
	Speed = NumberRange.new(30, 55),
	Spread = Vector2.new(55, 55),
	Accel = Vector3.new(0, -70, 0),
	Drag = 0.6,
	Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 2.2) }),
	Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.8, 0.2), NumberSequenceKeypoint.new(1, 1) }),
	Enabled = false,
})
local cloud = dustEmitter(burstAtt, {
	Lifetime = NumberRange.new(1.2, 2),
	Speed = NumberRange.new(8, 20),
	Spread = Vector2.new(80, 80),
	Accel = Vector3.new(0, 2, 0),
	Drag = 2,
	Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 4), NumberSequenceKeypoint.new(1, 9) }),
	Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) }),
	Enabled = false,
})

-- roar comes from the head
local voicePart = fxPart()
local roarSound = Instance.new("Sound")
roarSound.SoundId = "rbxassetid://" .. CONFIG.RoarSound
roarSound.PlaybackSpeed = CONFIG.RoarPitch
roarSound.Volume = CONFIG.RoarVolume
roarSound.RollOffMode = Enum.RollOffMode.InverseTapered
roarSound.RollOffMinDistance = 30
roarSound.RollOffMaxDistance = 320
roarSound.Parent = voicePart

------------------------------------------------------------------ camera rumble
local shakeAmp, impulse = 0, 0
RunService:BindToRenderStep("SandWormShake", Enum.RenderPriority.Camera.Value + 1, function(dt)
	impulse = math.max(0, impulse - dt * 1.8)
	local a = math.min(shakeAmp + impulse, 0.8)
	if a > 0.003 then
		local t = os.clock() * 24
		camera.CFrame = camera.CFrame
			* CFrame.Angles(math.noise(t, 1.3) * 0.02 * a, math.noise(t, 7.1) * 0.02 * a, math.noise(t, 4.4) * 0.012 * a)
	end
end)

local function myRoot()
	local ch = player.Character
	return ch and ch:FindFirstChild("HumanoidRootPart")
end

local function kick(pos, strength, range)
	local r = myRoot()
	if r then
		local d = (r.Position - pos).Magnitude
		if d < range then
			impulse = math.max(impulse, strength * (1 - d / range))
		end
	end
end

------------------------------------------------------------------ head position from the server (smoothed)
local samples = {}
Pose.OnClientEvent:Connect(function(t, p, maw)
	local n = #samples
	if n > 0 and t <= samples[n].t then
		return -- arrived out of order
	end
	samples[n + 1] = { t = t, p = p, maw = maw }
	if n + 1 > 40 then
		table.remove(samples, 1)
	end
end)

local function catmull(p0, p1, p2, p3, f)
	local f2, f3 = f * f, f * f * f
	return 0.5 * ((2 * p1) + (p2 - p0) * f + (2 * p0 - 5 * p1 + 4 * p2 - p3) * f2 + (3 * p1 - p0 - 3 * p2 + p3) * f3)
end

local function sampleHead(rt)
	local n = #samples
	if n == 0 then
		return nil, 0
	end
	if rt >= samples[n].t then
		return samples[n].p, samples[n].maw
	end
	if rt <= samples[1].t then
		return samples[1].p, samples[1].maw
	end
	local i = n - 1
	while i > 1 and samples[i].t > rt do
		i -= 1
	end
	local a, b = samples[i], samples[i + 1]
	local f = math.clamp((rt - a.t) / math.max(b.t - a.t, 1e-4), 0, 1)
	local p0 = (samples[i - 1] or a).p
	local p3 = (samples[i + 2] or b).p
	return catmull(p0, a.p, b.p, p3, f), a.maw + (b.maw - a.maw) * f
end

------------------------------------------------------------------ state
local trail = Shared.newTrail(110)
local haveBody = false
local tailSpec = nil
local deadAt = nil
local lastHead = nil
local speedEst = 0
local showUntil = 0 -- keeps drawing for a few seconds after it was last near the surface (the body pours back in)
local bodyOutUntil = 0 -- same, for the body itself being above ground (after a bite / smack / tail whip)

local function resetBody(headPos, dir)
	trail:reset(headPos, dir, 100)
	table.clear(samples)
	haveBody = true
	deadAt = nil
	tailSpec = nil
	setFade(0)
	lastHead = headPos
end

-- joining mid-fight: get the whole body from the server
task.spawn(function()
	local ok, snap = pcall(function()
		return Snapshot:InvokeServer()
	end)
	if not ok or type(snap) ~= "table" then
		return
	end
	local pts = snap.trail
	if pts and #pts > 12 then
		-- oldest first; leave out the newest few studs, the live head position fills those in
		local oldest, nextP = pts[#pts], pts[#pts - 1]
		trail:reset(oldest, nextP - oldest, 4)
		for k = #pts - 1, 6, -1 do
			trail:push(pts[k])
		end
		haveBody = true
		lastHead = pts[6]
		showUntil = os.clock() + 5
	end
	if snap.tail then
		tailSpec = { T0 = snap.tail[1], aMid = snap.tail[2], sign = snap.tail[3], t0 = snap.tail[4] }
	end
end)

------------------------------------------------------------------ one-off effects
local function warnRing(pos, radius, dur)
	local _, mat = Shared.ground(pos.X, pos.Z, pos.Y)
	local col = groundColor(mat)
	local flatCF = CFrame.new(pos + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.rad(90))
	-- glowing edge (a slightly bigger neon disc under a dark one = a ring)
	local edge = fxPart(flatCF)
	edge.Shape = Enum.PartType.Cylinder
	edge.Material = Enum.Material.Neon
	edge.Color = Color3.fromRGB(255, 150, 60)
	edge.Transparency = 0.45
	edge.Size = Vector3.new(0.18, radius * 0.5, radius * 0.5)
	local disc = fxPart(flatCF * CFrame.new(0.04, 0, 0))
	disc.Shape = Enum.PartType.Cylinder
	disc.Material = Enum.Material.SmoothPlastic
	disc.Color = col:Lerp(Color3.new(0, 0, 0), 0.55)
	disc.Transparency = 0.15
	disc.Size = Vector3.new(0.2, radius * 0.45, radius * 0.45)
	local info = TweenInfo.new(math.max(dur, 0.2), Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(edge, info, { Size = Vector3.new(0.18, radius * 2, radius * 2), Transparency = 0.2 }):Play()
	TweenService:Create(disc, info, { Size = Vector3.new(0.2, radius * 1.85, radius * 1.85) }):Play()
	if FX_SCALE >= 0.5 then
		local att = Instance.new("Attachment")
		att.Parent = disc
		local e = dustEmitter(att, { Rate = 12 * FX_SCALE, Speed = NumberRange.new(2, 6), Spread = Vector2.new(70, 70) })
		e.Color = ColorSequence.new(col)
	end
	Debris:AddItem(edge, dur + 0.25)
	Debris:AddItem(disc, dur + 0.25)
	kick(pos, 0.12, 50)
	showUntil = os.clock() + dur + 6
end

local function burstAt(pos, big)
	local _, mat = Shared.ground(pos.X, pos.Z, pos.Y)
	local col = groundColor(mat)
	burstPart.CFrame = CFrame.new(pos + Vector3.new(0, 1, 0))
	chunks.Color = ColorSequence.new(col:Lerp(Color3.new(0, 0, 0), 0.2))
	cloud.Color = ColorSequence.new(col)
	chunks:Emit(math.ceil((big and 30 or 20) * FX_SCALE))
	cloud:Emit(math.ceil((big and 14 or 10) * FX_SCALE))
	-- crater: a dark patch that fades out
	local crater = fxPart(CFrame.new(pos + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90)))
	crater.Shape = Enum.PartType.Cylinder
	crater.Material = Enum.Material.SmoothPlastic
	crater.Color = col:Lerp(Color3.new(0, 0, 0), 0.6)
	crater.Transparency = 0.25
	crater.Size = Vector3.new(0.2, 22, 22)
	TweenService:Create(crater, TweenInfo.new(3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 }):Play()
	Debris:AddItem(crater, 3.2)
	kick(pos, big and 0.7 or 0.5, 80)
	showUntil = os.clock() + 10
end

local function slamAt(pos, radius)
	burstAt(pos, false)
	local _, mat = Shared.ground(pos.X, pos.Z, pos.Y)
	local ring = fxPart(CFrame.new(pos + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90)))
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = (groundColor(mat) == SNOW) and Color3.fromRGB(150, 230, 255) or Color3.fromRGB(255, 200, 120)
	ring.Transparency = 0.25
	ring.Size = Vector3.new(0.3, 3, 3)
	TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.3, radius * 2.4, radius * 2.4),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.6)
end

Fx.OnClientEvent:Connect(function(kind, a, b, c, d)
	if kind == "Warn" then
		warnRing(a, b, c)
	elseif kind == "Burst" then
		burstAt(a, true)
	elseif kind == "Slam" then
		slamAt(a, b)
	elseif kind == "Roar" then
		roarSound.TimePosition = 0
		roarSound:Play()
	elseif kind == "Tail" then
		tailSpec = { T0 = a, aMid = b, sign = c, t0 = d }
		showUntil = os.clock() + Shared.TAIL.Total + 2
	elseif kind == "Reset" then
		resetBody(a, b)
	end
end)

------------------------------------------------------------------ drawing
local function headSway(mode, t)
	if mode == "Idle" then
		return CFrame.Angles(0.12 * math.sin(t * 1.3), 0.22 * math.sin(t * 0.9) + 0.08 * math.sin(t * 2.3), 0)
	elseif mode == "Rear" then
		return CFrame.Angles(0.05 * math.sin(t * 31), 0.05 * math.sin(t * 27), 0) -- shaking with rage
	end
	return CFrame.identity
end

local function quant(x)
	return math.floor(x * 10 + 0.5) / 10
end

local function draw(now, maw, sink, bodyOut)
	local idx = 0
	local headMode = wormServer:GetAttribute("HeadMode")
	local sinkV = Vector3.new(0, sink, 0)

	-- tail whip: the back of the body is drawn on the curl instead of the path
	local rho, ta
	if tailSpec then
		rho, ta = Shared.tailState(tailSpec, now)
		if not rho then
			tailSpec = nil
		end
	end

	local hp, ht, hu = trail:at(0)
	local headCF = Shared.frame(hp + sinkV, ht, hu) * headSway(headMode, now)
	idx += 1
	cfs[idx] = headCF * HEAD_OFF
	voicePart.CFrame = headCF
	local open = Shared.PET_OPEN * math.max(maw, 0)
	for k = 1, 4 do
		local m = PET_A[k] * CFrame.Angles(open, 0, 0) * PET_B[k]
		idx += 1
		cfs[idx] = headCF * (CFrame.new(m.Position * HS) * m.Rotation)
	end

	for i = 1, NR do
		local s = RING_S[i]
		local p, t, u
		local stretch = nil -- nil = leave the ring's size alone (it's underground, nobody sees it)
		if rho and Shared.HOOK[i] then
			p, t, u = Shared.tailAt(tailSpec, rho, ta, DT - D[i])
			stretch = quant(math.clamp(1.03 + 1.25 * Shared.tailCurv(DT - D[i]) * 6.1 * s, 1, 1.7))
		else
			p, t, u = trail:at(D[i])
			if bodyOut then
				-- stretch rings along the body on bends so the outside of the curve never gaps
				stretch = quant(math.clamp(1.03 + 1.25 * trail:curv(D[i]) * 6.1 * s, 1, 1.7))
			end
		end
		if stretch and stretch ~= ringStretch[i] then
			ringStretch[i] = stretch
			rings[i].Size = Vector3.new(ringBase.X * s, ringBase.Y * s, ringBase.Z * s * stretch)
		end
		p += sinkV
		idx += 1
		cfs[idx] = Shared.frame(p, t, u) * ROLLCF[i] * CFrame.new(C.Ring * s)
		idx += 1
		cfs[idx] = Shared.frame(p + u * (Shared.FIN_UP * s), t, u) * CFrame.new(C.Fin * FIN_S[i])
	end

	local p, t, u
	if rho then
		p, t, u = Shared.tailAt(tailSpec, rho, ta, 0)
	else
		p, t, u = trail:at(DT)
	end
	idx += 1
	cfs[idx] = Shared.frame(p + sinkV, t, u) * TAIL_OFF

	workspace:BulkMoveTo(all, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	hidden = false
end

local function wakeOff()
	for _, w in ipairs(wake) do
		if w.on then
			w.on = false
			w.emitter.Rate = 0
		end
	end
end

local function updateWake(alive, near)
	shakeAmp = 0
	if not alive or not near then
		wakeOff()
		return
	end
	for _, w in ipairs(wake) do
		local p = trail:pos(w.d)
		local g, mat = Shared.ground(p.X, p.Z, p.Y)
		local depth = g - p.Y
		if speedEst > 3 and depth > 1.5 and depth < 30 then
			w.on = true
			w.part.CFrame = CFrame.new(p.X, g + 0.4, p.Z)
			local col = groundColor(mat)
			if col ~= w.colour then
				w.colour = col
				w.emitter.Color = ColorSequence.new(col)
			end
			w.emitter.Rate = (4 + 12 * math.clamp((30 - depth) / 26, 0, 1)) * FX_SCALE
		elseif w.on then
			w.on = false
			w.emitter.Rate = 0
		end
	end
	-- rumble when it's close under you
	local r = myRoot()
	if r then
		local hp = trail:pos(0)
		local g = Shared.ground(hp.X, hp.Z, hp.Y)
		local depth = g - hp.Y
		local dist = Vector3.new(r.Position.X - hp.X, 0, r.Position.Z - hp.Z).Magnitude
		if depth > 0 and depth < 28 and dist < CONFIG.RumbleRange and speedEst > 3 then
			shakeAmp = CONFIG.RumbleStrength * (1 - dist / CONFIG.RumbleRange)
		end
	end
end

RunService.RenderStepped:Connect(function(dt)
	local state = wormServer:GetAttribute("State")
	if state == "Dormant" or state == "Gone" or not haveBody then
		hideAll()
		shakeAmp = 0
		wakeOff()
		if state == "Gone" then
			haveBody = false
		end
		return
	end

	local now = workspace:GetServerTimeNow()
	local sink = 0
	if state == "Dead" then
		deadAt = deadAt or os.clock()
		local e = os.clock() - deadAt
		sink = -35 * math.clamp(e / CONFIG.SinkTime, 0, 1) ^ 2
		setFade(math.clamp((e - 1.5) / (CONFIG.SinkTime - 1.5), 0, 1))
		tailSpec = nil
	else
		local hp, _ = sampleHead(now - CONFIG.InterpDelay)
		if hp then
			if lastHead then
				speedEst += (((hp - lastHead).Magnitude / math.max(dt, 1e-3)) - speedEst) * math.min(dt * 6, 1)
			end
			lastHead = hp
			trail:push(hp)
		end
	end
	local _, maw = sampleHead(now - CONFIG.InterpDelay)

	-- is any of it out of the ground (or about to be)? attacking, surfaced, dying, a tail whip,
	-- shallow enough for the fins to show, or still pouring back under after one of those
	local headPos = trail:pos(0)
	local g = Shared.ground(headPos.X, headPos.Z, headPos.Y)
	local clock = os.clock()
	local outNow = state == "Attack" or state == "Surfaced" or state == "Dead" or tailSpec ~= nil
	if outNow then
		bodyOutUntil = clock + 4
	end
	if outNow or (g - headPos.Y) < CONFIG.HiddenDepth then
		showUntil = math.max(showUntil, clock + 4)
	end
	local bodyOut = clock < bodyOutUntil -- body above ground: rings need stretching on bends
	local near = (camera.CFrame.Position - headPos).Magnitude <= CONFIG.DrawDistance

	if near and clock < showUntil then
		draw(now, maw or 0, sink, bodyOut)
	else
		hideAll() -- deep underground or far away: nothing to see, so nothing to move
	end
	updateWake(state ~= "Dead", near)
end)
