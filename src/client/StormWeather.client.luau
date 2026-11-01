-- LocalScript > StarterPlayer > StarterPlayerScripts > Client > StormWeather
--
-- Sandstorm (DesertZone) and snowstorm (SnowZone), drawn around the local
-- camera.
--
-- 2026-10-20 performance rebuild. The old version had the server fill both
-- zones with ~11,300 ParticleEmitters that every client simulated all the
-- time (~73k grains/s and ~113k flakes/s requested near the player; FPS 42
-- vs 55 in the desert and 33 vs 60 in the snow, storm on vs off), and each
-- grain was a 2-stud speckle picture, so it looked like PNGs sliding by.
--
-- How it works now:
--   * WeatherZones (server) publishes each zone's outline to
--     ReplicatedStorage.WeatherZoneData. No emitters on the server.
--   * ~10 times a second this script works out how deep the camera is in a
--     zone (fades in over EdgeFade studs past the outline, calms down near
--     the SafeZone, dims under a roof) and eases the storm toward that.
--   * Each storm is a few layers. A layer is one invisible box Part
--     (parented to the Camera, so it only exists on this client) that
--     follows the camera with ONE ParticleEmitter filling the box.
--     Particles live in world space, so you walk through them instead of
--     dragging them along.
--       Sand: thin wind streaks, fine grains, soft sand veils, sand
--             sheets skimming the ground, and huge faint dust waves.
--       Snow: falling flakes, blizzard streaks, far flakes, spindrift on
--             the ground, and huge faint snow waves.
--   * The sky (Atmosphere) and a light colour grade blend toward tan or
--     icy white while you're in a storm.
--   * Look rules (learned the hard way): anything you can see the shape of
--     reads as a "floating oval", so particles are either tiny (grains,
--     flakes, hairline streaks) or so big and faint that they just read as
--     the air getting thicker. Streaks are the soft dot texture stretched
--     along the wind: Orientation VelocityParallel + a NEGATIVE Squash
--     (negative = longer along the direction of travel, thinner across).
--     Layers near the camera use KeepOut so nothing is born right next to
--     the lens (a grain an inch from the camera is a big blob on screen).
--   * Particle counts follow the player's graphics level; phones get about
--     half. Mostly tiny particles, so they're cheap to draw.
--
-- This replaces the old WeatherZoneLOD and SnowZoneFog scripts (SnowZoneFog
-- tweened Lighting fog, which does nothing while Lighting has an
-- Atmosphere, so the cold haze never showed).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local CONFIG = {
	UpdateInterval = 0.1, -- seconds between zone checks / rate updates
	EdgeFade = 90, -- studs inside a zone outline before the storm is at full strength
	SafeFadeStart = 25, -- studs from the SafeZone footprint where the storm starts
	SafeFadeEnd = 110, -- ...and where it reaches full strength
	EaseTime = 0.9, -- seconds for the storm to ease in or out
	RoofCheck = 70, -- studs straight up; anything solid there counts as shelter
	RoofFactor = 0.3, -- storm strength while sheltered
	GroundRay = 150, -- studs down from the camera to look for the ground
	Wind = Vector3.new(1, 0, 0.3).Unit, -- main wind direction (both storms)
	WindWobble = math.rad(10), -- slow swing either side of the main direction
}

-- Particle textures. Both are Roblox built-ins, so nothing has to be
-- uploaded: Dot is a soft round dot (grains, flakes, and stretched into
-- streaks), Puff is the same soft cloud used huge and faint for dust waves.
local TEXTURES = {
	Dot = "rbxasset://textures/particles/smoke_main.dds",
	Puff = "rbxasset://textures/particles/smoke_main.dds",
}

-- Size / Transparency keypoints are {time, value, envelope?}. Rates are
-- particles per second at full strength on the highest graphics level.
-- Anchor "Ground": box centre sits Height studs above the ground under the
-- camera. Anchor "Camera": Height studs above the camera. Ahead / Upwind
-- push the box in front of the camera / into the wind so particles cross
-- the view; KeepOut instead parks the box in front of the camera with its
-- near face that many studs away. Tilt tips the wind down (snow falls,
-- sand mostly doesn't).
local STORMS = {
	Sand = {
		Atmosphere = {
			Density = 0.46, Offset = 0.05, Haze = 2.2, Glare = 0.3,
			Color = Color3.fromRGB(214, 178, 128), Decay = Color3.fromRGB(176, 124, 72),
		},
		Fog = {FogEnd = 450, FogColor = Color3.fromRGB(205, 172, 125)}, -- only used if Lighting has no Atmosphere
		Grade = {TintColor = Color3.fromRGB(255, 238, 214), Saturation = -0.08, Contrast = -0.04, Brightness = 0.02},
		Layers = {
			{ -- thin streaks of blown sand
				Name = "SandStreaks", Texture = "Dot", Anchor = "Ground", Height = 11,
				Box = Vector3.new(44, 22, 44), KeepOut = 4, Upwind = 18, Tilt = -0.02,
				Rate = 600, Lifetime = NumberRange.new(0.5, 0.9), Speed = NumberRange.new(55, 80),
				Spread = Vector2.new(3, 5), Accel = Vector3.new(0, -4, 0), Gusty = true,
				Size = {{0, 0.26, 0.08}, {1, 0.26, 0.08}},
				Squash = -3.5,
				Transparency = {{0, 1}, {0.15, 0.05}, {0.8, 0.15}, {1, 1}},
				Colors = {Color3.fromRGB(242, 218, 172), Color3.fromRGB(168, 128, 82)},
				Orientation = Enum.ParticleOrientation.VelocityParallel,
			},
			{ -- fine grains right around you
				Name = "SandGrains", Texture = "Dot", Anchor = "Camera", Height = -2,
				Box = Vector3.new(26, 12, 26), KeepOut = 5, Upwind = 8, Tilt = 0,
				Rate = 350, Lifetime = NumberRange.new(0.6, 1), Speed = NumberRange.new(35, 50),
				Spread = Vector2.new(10, 10), Accel = Vector3.new(0, -10, 0),
				Size = {{0, 0.09, 0.03}, {1, 0.09, 0.03}},
				Transparency = {{0, 1}, {0.1, 0}, {0.85, 0.1}, {1, 1}},
				Colors = {Color3.fromRGB(150, 115, 70), Color3.fromRGB(110, 82, 48)},
			},
			{ -- soft veils of sand at eye level, between the streaks and the haze
				Name = "SandVeils", Texture = "Dot", Anchor = "Ground", Height = 9,
				Box = Vector3.new(70, 18, 70), KeepOut = 6, Upwind = 20, Tilt = 0,
				Rate = 90, Lifetime = NumberRange.new(0.9, 1.4), Speed = NumberRange.new(45, 60),
				Spread = Vector2.new(3, 4), Gusty = true,
				Size = {{0, 1.4, 0.4}, {1, 1.8, 0.4}},
				Squash = -3,
				Transparency = {{0, 1}, {0.25, 0.6}, {0.75, 0.66}, {1, 1}},
				Colors = {Color3.fromRGB(222, 190, 140), Color3.fromRGB(200, 165, 115)},
				Orientation = Enum.ParticleOrientation.VelocityParallel,
			},
			{ -- sand sheets streaming along the ground
				Name = "SandSheets", Texture = "Dot", Anchor = "Ground", Height = 0.7,
				Box = Vector3.new(80, 1.2, 80), Upwind = 15, Ahead = 25, Tilt = 0,
				Rate = 140, Lifetime = NumberRange.new(0.8, 1.3), Speed = NumberRange.new(40, 55),
				Spread = Vector2.new(4, 0),
				Size = {{0, 0.8, 0.3}, {1, 0.8, 0.3}},
				Squash = -3.5,
				Transparency = {{0, 1}, {0.2, 0.4}, {0.8, 0.5}, {1, 1}},
				Colors = {Color3.fromRGB(230, 200, 152), Color3.fromRGB(210, 176, 124)},
				Orientation = Enum.ParticleOrientation.VelocityParallel,
			},
			{ -- huge faint dust waves rolling through (too big to see their edges)
				Name = "SandWaves", Texture = "Puff", Anchor = "Ground", Height = 18,
				Box = Vector3.new(200, 30, 200), Upwind = 60, Ahead = 60, Tilt = 0,
				Rate = 2, Lifetime = NumberRange.new(5, 7), Speed = NumberRange.new(25, 35),
				Spread = Vector2.new(5, 2), Gusty = true,
				Size = {{0, 60, 10}, {1, 90, 10}},
				Transparency = {{0, 1}, {0.3, 0.9}, {0.7, 0.9}, {1, 1}},
				Colors = {Color3.fromRGB(205, 170, 120), Color3.fromRGB(190, 152, 104)},
				Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-6, 6),
			},
		},
	},
	Snow = {
		Atmosphere = {
			Density = 0.44, Offset = 0.1, Haze = 1.6, Glare = 0.2,
			Color = Color3.fromRGB(214, 226, 238), Decay = Color3.fromRGB(150, 170, 196),
		},
		Fog = {FogEnd = 400, FogColor = Color3.fromRGB(205, 218, 230)},
		Grade = {TintColor = Color3.fromRGB(232, 242, 255), Saturation = -0.15, Contrast = -0.03, Brightness = 0.03},
		Layers = {
			{ -- falling flakes around you
				Name = "SnowFlakes", Texture = "Dot", Anchor = "Ground", Height = 11,
				Box = Vector3.new(44, 22, 44), KeepOut = 4, Upwind = 12, Tilt = -0.45,
				Rate = 420, Lifetime = NumberRange.new(1.4, 2), Speed = NumberRange.new(14, 22),
				Spread = Vector2.new(20, 20), Accel = Vector3.new(0, -2, 0), Gusty = true,
				Size = {{0, 0.17, 0.05}, {1, 0.15, 0.04}},
				Transparency = {{0, 1}, {0.08, 0}, {0.85, 0.05}, {1, 1}},
				Colors = {Color3.fromRGB(255, 255, 255), Color3.fromRGB(196, 210, 230)}, -- white to light blue-grey so flakes show on bright snow too
			},
			{ -- fast blizzard streaks
				Name = "SnowStreaks", Texture = "Dot", Anchor = "Ground", Height = 7,
				Box = Vector3.new(40, 14, 40), KeepOut = 4, Upwind = 15, Tilt = -0.15,
				Rate = 220, Lifetime = NumberRange.new(0.6, 1), Speed = NumberRange.new(35, 50),
				Spread = Vector2.new(6, 6), Gusty = true,
				Size = {{0, 0.14, 0.04}, {1, 0.14, 0.04}},
				Squash = -3,
				Transparency = {{0, 1}, {0.15, 0.2}, {0.8, 0.3}, {1, 1}},
				Colors = {Color3.fromRGB(255, 255, 255), Color3.fromRGB(200, 214, 232)},
				Orientation = Enum.ParticleOrientation.VelocityParallel,
			},
			{ -- flakes further out, for depth
				Name = "SnowFarFlakes", Texture = "Dot", Anchor = "Ground", Height = 20,
				Box = Vector3.new(160, 40, 160), KeepOut = 20, Upwind = 30, Tilt = -0.4,
				Rate = 100, Lifetime = NumberRange.new(3, 4), Speed = NumberRange.new(14, 20),
				Spread = Vector2.new(18, 18),
				Size = {{0, 0.32, 0.08}, {1, 0.3, 0.08}},
				Transparency = {{0, 1}, {0.1, 0.05}, {0.85, 0.15}, {1, 1}},
				Colors = {Color3.fromRGB(255, 255, 255), Color3.fromRGB(204, 216, 234)},
			},
			{ -- spindrift streaming along the snow
				Name = "SnowDrift", Texture = "Dot", Anchor = "Ground", Height = 0.7,
				Box = Vector3.new(80, 1.2, 80), Upwind = 15, Ahead = 25, Tilt = 0,
				Rate = 50, Lifetime = NumberRange.new(0.8, 1.3), Speed = NumberRange.new(30, 44),
				Spread = Vector2.new(4, 0),
				Size = {{0, 0.7, 0.25}, {1, 0.7, 0.25}},
				Squash = -3.5,
				Transparency = {{0, 1}, {0.2, 0.5}, {0.8, 0.55}, {1, 1}},
				Colors = {Color3.fromRGB(255, 255, 255), Color3.fromRGB(238, 244, 252)},
				Orientation = Enum.ParticleOrientation.VelocityParallel,
			},
			{ -- huge faint snow waves rolling through
				Name = "SnowWaves", Texture = "Puff", Anchor = "Ground", Height = 18,
				Box = Vector3.new(200, 34, 200), Upwind = 60, Ahead = 60, Tilt = -0.1,
				Rate = 2, Lifetime = NumberRange.new(5, 7), Speed = NumberRange.new(22, 32),
				Spread = Vector2.new(5, 3), Gusty = true,
				Size = {{0, 60, 10}, {1, 90, 10}},
				Transparency = {{0, 1}, {0.3, 0.88}, {0.7, 0.88}, {1, 1}},
				Colors = {Color3.fromRGB(255, 255, 255), Color3.fromRGB(228, 238, 250)},
				Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-6, 6),
			},
		},
	},
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function smoothstep(e0, e1, x)
	local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

local function numberSequence(points)
	local kps = table.create(#points)
	for i, p in ipairs(points) do
		kps[i] = NumberSequenceKeypoint.new(p[1], p[2], p[3] or 0)
	end
	return NumberSequence.new(kps)
end

-- Where a layer's box goes this frame. pos = camera position, ground =
-- ground height under it, ahead = flat camera look direction, wind = flat
-- wind direction. With KeepOut the box sits in front of the camera with its
-- near face at least KeepOut studs away (box X = across the wind, Y = up,
-- Z = along the wind before Tilt).
local function layerCFrame(layer, pos, ground, ahead, wind)
	local baseY = layer.Anchor == "Camera" and pos.Y or ground
	local centre = Vector3.new(pos.X, baseY + layer.Height, pos.Z)
	local tilt = layer.Tilt or 0
	if layer.KeepOut then
		local side = Vector3.new(-wind.Z, 0, wind.X)
		local pitch = math.atan(math.abs(tilt))
		local halfAlong = (layer.Box.Z * math.cos(pitch) + layer.Box.Y * math.sin(pitch)) / 2
		local halfSide = layer.Box.X / 2
		local cw, cs = math.abs(ahead:Dot(wind)), math.abs(ahead:Dot(side))
		local reach = math.min(
			cw > 1e-3 and (halfAlong + layer.KeepOut) / cw or math.huge,
			cs > 1e-3 and (halfSide + layer.KeepOut) / cs or math.huge
		)
		if reach < math.huge then
			centre += ahead * reach
		end
		-- slide upwind as far as looking across the wind allows (the camera
		-- stays outside the box) so particles blow across the view
		centre -= wind * ((layer.Upwind or 0) * cs)
	else
		centre += ahead * (layer.Ahead or 0) - wind * (layer.Upwind or 0)
	end
	return CFrame.lookAt(centre, centre + (wind + Vector3.new(0, tilt, 0)).Unit)
end

-- Graphics-level particle scale: highest graphics 1, Automatic 0.7, low
-- 0.35; touch-only devices (phones/tablets) never above 0.5.
local function qualityScale()
	local scale = 0.7
	local ok, level = pcall(function()
		return UserSettings().GameSettings.SavedQualityLevel
	end)
	if ok and level and level ~= Enum.SavedQualitySetting.Automatic then
		local v = level.Value
		scale = (v <= 3 and 0.35) or (v <= 6 and 0.6) or 1
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		scale = math.min(scale, 0.5)
	end
	return scale
end

---------------------------------------------------------------------------
-- Textures
---------------------------------------------------------------------------

local function applyTexture(emitter, layer)
	emitter.Texture = TEXTURES[layer.Texture] or TEXTURES.Dot
end

---------------------------------------------------------------------------
-- Zones
---------------------------------------------------------------------------

local data = ReplicatedStorage:WaitForChild("WeatherZoneData")
local zones = {} -- Configuration -> {Kind, Outline = {{x, z}...}}

local function parseZone(entry)
	local kind = entry:GetAttribute("Kind")
	local text = entry:GetAttribute("Outline")
	if not STORMS[kind] or type(text) ~= "string" then
		zones[entry] = nil
		return
	end
	local outline = {}
	for xs, zs in string.gmatch(text, "(-?[%d%.]+),(-?[%d%.]+)") do
		table.insert(outline, {tonumber(xs), tonumber(zs)})
	end
	zones[entry] = #outline >= 3 and {Kind = kind, Outline = outline} or nil
end

local function watchZone(entry)
	if not entry:IsA("Configuration") then
		return
	end
	parseZone(entry)
	entry.AttributeChanged:Connect(function()
		parseZone(entry)
	end)
end

for _, entry in ipairs(data:GetChildren()) do
	watchZone(entry)
end
data.ChildAdded:Connect(watchZone)
data.ChildRemoved:Connect(function(entry)
	zones[entry] = nil
end)

-- Even-odd point-in-polygon test on X/Z.
local function isInside(px, pz, outline)
	local inside = false
	local j = #outline
	for i = 1, #outline do
		local xi, zi = outline[i][1], outline[i][2]
		local xj, zj = outline[j][1], outline[j][2]
		if (zi > pz) ~= (zj > pz) and px < (xj - xi) * (pz - zi) / (zj - zi) + xi then
			inside = not inside
		end
		j = i
	end
	return inside
end

local function distanceToEdge(px, pz, outline)
	local best = math.huge
	local n = #outline
	for i = 1, n do
		local a, b = outline[i], outline[i % n + 1]
		local dx, dz = b[1] - a[1], b[2] - a[2]
		local lenSq = dx * dx + dz * dz
		local t = lenSq > 0 and math.clamp(((px - a[1]) * dx + (pz - a[2]) * dz) / lenSq, 0, 1) or 0
		local cx, cz = a[1] + dx * t - px, a[2] + dz * t - pz
		best = math.min(best, cx * cx + cz * cz)
	end
	return math.sqrt(best)
end

local function safeZoneFactor(pos)
	local cf, size = data:GetAttribute("SafeZoneCFrame"), data:GetAttribute("SafeZoneSize")
	if typeof(cf) ~= "CFrame" or typeof(size) ~= "Vector3" then
		return 1
	end
	local p = cf:PointToObjectSpace(pos)
	local dx = math.max(math.abs(p.X) - size.X / 2, 0)
	local dz = math.max(math.abs(p.Z) - size.Z / 2, 0)
	return smoothstep(CONFIG.SafeFadeStart, CONFIG.SafeFadeEnd, math.sqrt(dx * dx + dz * dz))
end

---------------------------------------------------------------------------
-- Emitter rig
---------------------------------------------------------------------------

local rig = Instance.new("Folder")
rig.Name = "StormWeatherRig"

local function parentRig()
	rig.Parent = workspace.CurrentCamera
end
parentRig()
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(parentRig)

local layers = {} -- {Storm, Layer, Part, Emitter, LastRate}
local ready = false

local function buildLayer(stormName, layer)
	local part = Instance.new("Part")
	part.Name = layer.Name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = layer.Box
	part.CFrame = CFrame.new(0, -10000, 0)
	part.Parent = rig

	local e = Instance.new("ParticleEmitter")
	e.Name = layer.Name
	e.Shape = Enum.ParticleEmitterShape.Box
	e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	e.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
	e.EmissionDirection = Enum.NormalId.Front -- the part faces downwind
	e.Rate = 0
	e.Lifetime = layer.Lifetime
	e.Speed = layer.Speed
	e.SpreadAngle = layer.Spread or Vector2.zero
	e.Acceleration = layer.Accel or Vector3.zero
	e.Size = numberSequence(layer.Size)
	e.Transparency = numberSequence(layer.Transparency)
	e.Color = ColorSequence.new(layer.Colors[1], layer.Colors[2] or layer.Colors[1])
	e.Orientation = layer.Orientation or Enum.ParticleOrientation.FacingCamera
	e.Rotation = layer.Rotation or NumberRange.new(0)
	e.RotSpeed = layer.RotSpeed or NumberRange.new(0)
	if layer.Squash then
		e.Squash = NumberSequence.new(layer.Squash)
	end
	e.LightEmission = 0
	e.LightInfluence = 0.9
	e.Brightness = 1
	e.LockedToPart = false
	e.VelocityInheritance = 0
	applyTexture(e, layer)
	e.Parent = part

	table.insert(layers, {Storm = stormName, Layer = layer, Part = part, Emitter = e, LastRate = 0})
end

for _, stormName in ipairs({"Sand", "Snow"}) do
	for _, layer in ipairs(STORMS[stormName].Layers) do
		buildLayer(stormName, layer)
	end
end
ready = true

---------------------------------------------------------------------------
-- Sky and colour grade
---------------------------------------------------------------------------

local ATMOS_KEYS = {"Density", "Offset", "Haze", "Glare", "Color", "Decay"}
local GRADE_KEYS = {"TintColor", "Saturation", "Contrast", "Brightness"}
local atmosphere, atmosBase
local fogBase = {FogEnd = Lighting.FogEnd, FogColor = Lighting.FogColor}
local grade -- ColorCorrectionEffect, client-only
local gradeBase = {TintColor = Color3.new(1, 1, 1), Saturation = 0, Contrast = 0, Brightness = 0}
local skyAtRest = true

local function findAtmosphere()
	if atmosphere and atmosphere.Parent == Lighting then
		return atmosphere
	end
	atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	atmosBase = nil
	if atmosphere then
		atmosBase = {}
		for _, k in ipairs(ATMOS_KEYS) do
			atmosBase[k] = atmosphere[k]
		end
	end
	return atmosphere
end
findAtmosphere()

local function lerp(a, b, t)
	if typeof(a) == "Color3" then
		return a:Lerp(b, t)
	end
	return a + (b - a) * t
end

-- weights = {Sand = s, Snow = w} (eased storm strengths)
local function applySky(weights)
	local total = 0
	for _, w in pairs(weights) do
		total += w
	end
	local amount = math.min(total, 1)
	if amount < 0.002 then
		if skyAtRest then
			return
		end
		skyAtRest = true
		amount = 0
	else
		skyAtRest = false
	end

	-- the storm look to blend toward (both storms mixed by strength at a border)
	local function target(section, key, base)
		if total <= 0 then
			return base
		end
		local value
		for stormName, w in pairs(weights) do
			if w > 0 then
				local v = STORMS[stormName][section][key]
				value = value == nil and v or lerp(value, v, w / total)
			end
		end
		return value
	end

	if findAtmosphere() and atmosBase then
		for _, k in ipairs(ATMOS_KEYS) do
			atmosphere[k] = lerp(atmosBase[k], target("Atmosphere", k, atmosBase[k]), amount)
		end
	else
		Lighting.FogEnd = lerp(fogBase.FogEnd, target("Fog", "FogEnd", fogBase.FogEnd), amount)
		Lighting.FogColor = lerp(fogBase.FogColor, target("Fog", "FogColor", fogBase.FogColor), amount)
	end

	if not grade or grade.Parent ~= Lighting then
		grade = Instance.new("ColorCorrectionEffect")
		grade.Name = "StormGrade"
		grade.Parent = Lighting
	end
	grade.Enabled = amount > 0
	for _, k in ipairs(GRADE_KEYS) do
		grade[k] = lerp(gradeBase[k], target("Grade", k, gradeBase[k]), amount)
	end
end

---------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------

local strength = {Sand = 0, Snow = 0} -- eased 0..1
local targetStrength = {Sand = 0, Snow = 0}
local groundY = nil
local scale = qualityScale()
local nextScaleCheck = 0

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function updateRayFilter()
	local list = {rig}
	local chars = workspace:FindFirstChild("Characters")
	if chars then
		table.insert(list, chars)
	end
	if player.Character then
		table.insert(list, player.Character)
	end
	rayParams.FilterDescendantsInstances = list
end

local function gustAt(t)
	return 0.9 + 0.25 * math.sin(t * 0.7) * math.sin(t * 0.23 + 1.3) -- 0.65..1.15
end

local function windAt(t)
	local yaw = CONFIG.WindWobble * math.sin(t * 0.11) * math.cos(t * 0.047 + 0.5)
	return (CFrame.Angles(0, yaw, 0) * CONFIG.Wind).Unit
end

local function updateTargets()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local pos = camera.CFrame.Position
	updateRayFilter()

	local down = workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -CONFIG.GroundRay, 0), rayParams)
	groundY = down and down.Position.Y or (pos.Y - 12)

	local roof = workspace:Raycast(pos, Vector3.new(0, CONFIG.RoofCheck, 0), rayParams)
	local shelter = roof and CONFIG.RoofFactor or 1
	local safe = safeZoneFactor(pos)

	targetStrength.Sand, targetStrength.Snow = 0, 0
	for _, zone in pairs(zones) do
		if isInside(pos.X, pos.Z, zone.Outline) then
			local depth = smoothstep(0, CONFIG.EdgeFade, distanceToEdge(pos.X, pos.Z, zone.Outline))
			targetStrength[zone.Kind] = math.max(targetStrength[zone.Kind], depth * safe * shelter)
		end
	end
end

local function updateRates(t)
	if os.clock() >= nextScaleCheck then
		scale = qualityScale()
		nextScaleCheck = os.clock() + 5
	end
	local gust = gustAt(t)
	for _, l in ipairs(layers) do
		local rate = l.Layer.Rate * strength[l.Storm] * scale
		if l.Layer.Gusty then
			rate *= gust
		end
		if rate < 0.05 then
			rate = 0
		end
		if math.abs(rate - l.LastRate) > math.max(0.05, l.LastRate * 0.03) or (rate == 0 and l.LastRate ~= 0) then
			l.Emitter.Rate = rate
			l.LastRate = rate
		end
	end
end

local lastAhead = Vector3.new(0, 0, -1)

-- Keep each active storm's boxes around the camera, upwind of it, facing
-- downwind. Runs after the camera has moved for this frame.
local function placeRig()
	if not ready then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local pos = camera.CFrame.Position
	local t = os.clock()
	local wind = windAt(t)
	local ground = groundY or (pos.Y - 12)
	-- boxes sit in front of the camera, so particles land where you're
	-- looking (keeps the last direction while looking straight up/down)
	local view = camera.CFrame.LookVector
	local flat = Vector3.new(view.X, 0, view.Z)
	if flat.Magnitude > 0.05 then
		lastAhead = flat.Unit
	end
	local parts, cframes = {}, {}
	for _, l in ipairs(layers) do
		if strength[l.Storm] > 0.002 or l.LastRate > 0 then
			table.insert(parts, l.Part)
			table.insert(cframes, layerCFrame(l.Layer, pos, ground, lastAhead, wind))
		end
	end
	if #parts > 0 then
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

RunService:BindToRenderStep("StormWeather", Enum.RenderPriority.Camera.Value + 1, placeRig)

local accum = CONFIG.UpdateInterval
RunService.Heartbeat:Connect(function(dt)
	if not ready then
		return
	end
	-- ease toward the target every frame (cheap), check zones 10x a second
	local k = 1 - math.exp(-dt / CONFIG.EaseTime)
	for name, value in pairs(strength) do
		local goal = targetStrength[name]
		value += (goal - value) * k
		if math.abs(goal - value) < 0.002 then
			value = goal
		end
		strength[name] = value
	end
	accum += dt
	if accum >= CONFIG.UpdateInterval then
		accum = 0
		updateTargets()
		updateRates(os.clock())
		applySky(strength)
	end
end)
