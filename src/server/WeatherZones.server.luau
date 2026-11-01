-- Script in ServerScriptService > Server > WeatherZones
--
-- Reads the two Folders of numbered dot Parts in Workspace - "DesertZone"
-- and "SnowZone" - placed around the desert / ice area like a
-- connect-the-dots outline ("1", "2", "3"... in order around the edge), and
-- publishes each outline to ReplicatedStorage.WeatherZoneData so every
-- client knows where the storms are.
--
-- 2026-10-20 performance rebuild: this script used to fill both zones with
-- ParticleEmitters - about 2,500 in the desert and 8,800 in the snow - that
-- every client had to simulate all the time. Measured in a playtest: ~73,000
-- sand grains/s and ~113,000 flakes/s requested around the player, FPS 42 vs
-- 55 in the desert and 33 vs 60 in the snow (storm on vs off), and the grains
-- read as square pictures sliding past. The storms are now drawn on each
-- client around its own camera by
-- StarterPlayerScripts.Client.StormWeather, using a handful of emitters.
-- This script only shares the outlines (plus the SafeZone box, so the
-- storm can calm down around spawn) and creates no emitters at all.
--
-- The dots stay where they are (ZoneBounds also reads them); they are only
-- hidden here. Outlines are published to ReplicatedStorage (not streamed)
-- because with StreamingEnabled the dot Parts are often not loaded on a
-- client that spawns far away.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SafeZone = workspace:WaitForChild("SafeZone")

local ZONES = {
	{Folder = "DesertZone", Kind = "Sand"},
	{Folder = "SnowZone", Kind = "Snow"},
}

-- Bright neon lines tracing each outline, for checking dot placement in a
-- playtest. Leave false for the real game.
local SHOW_DEBUG_OUTLINE = false
local DEBUG_OUTLINE_COLOR = Color3.fromRGB(0, 255, 60)

-- Reads the numbered dots out of a zone Folder in ascending order and hides
-- them (they are placement markers only).
local function getOrderedDots(folder)
	local dots = {}
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("BasePart") then
			local order = tonumber(child.Name)
			if order then
				table.insert(dots, {Order = order, Position = child.Position})
			else
				warn(("[WeatherZones] '%s.%s' isn't named as a plain number - skipping, it won't be part of the outline."):format(folder.Name, child.Name))
			end
			child.Transparency = 1
			child.CanCollide = false
			child.CanQuery = false
			child.CanTouch = false
			child.CastShadow = false
			child.Anchored = true
		end
	end
	table.sort(dots, function(a, b)
		return a.Order < b.Order
	end)
	local points = {}
	for _, dot in ipairs(dots) do
		table.insert(points, dot.Position)
	end
	return points
end

local function drawDebugOutline(folder, outline)
	local existing = folder:FindFirstChild(folder.Name .. "_DebugOutline")
	if existing then
		existing:Destroy()
	end
	if not SHOW_DEBUG_OUTLINE then
		return
	end
	local lines = Instance.new("Folder")
	lines.Name = folder.Name .. "_DebugOutline"
	lines.Parent = folder
	for i = 1, #outline do
		local a, b = outline[i], outline[i % #outline + 1]
		local dist = (b - a).Magnitude
		if dist > 0.01 then
			local line = Instance.new("Part")
			line.Name = "DebugOutlineLine"
			line.Anchored = true
			line.CanCollide = false
			line.CanQuery = false
			line.CanTouch = false
			line.CastShadow = false
			line.Material = Enum.Material.Neon
			line.Color = DEBUG_OUTLINE_COLOR
			line.Size = Vector3.new(0.6, 0.6, dist)
			line.CFrame = CFrame.lookAt((a + b) / 2, b)
			line.Parent = lines
		end
	end
end

local data = ReplicatedStorage:FindFirstChild("WeatherZoneData")
if not data then
	data = Instance.new("Folder")
	data.Name = "WeatherZoneData"
	data.Parent = ReplicatedStorage
end
data:SetAttribute("SafeZoneCFrame", SafeZone.CFrame)
data:SetAttribute("SafeZoneSize", SafeZone.Size)

for _, zone in ipairs(ZONES) do
	local folder = workspace:FindFirstChild(zone.Folder)
	if not folder then
		warn(("[WeatherZones] No '%s' Folder in Workspace - the %s storm is off. Add one with numbered dot Parts (\"1\", \"2\", \"3\"...) around the area."):format(zone.Folder, zone.Kind:lower()))
		continue
	end

	-- Old emitter fill from the previous version of this script, if the
	-- place was saved while a playtest had it built.
	local oldFill = folder:FindFirstChild(folder.Name .. "_StormFill")
	if oldFill then
		oldFill:Destroy()
	end

	local outline = getOrderedDots(folder)
	if #outline < 3 then
		warn(("[WeatherZones] '%s' has %d numbered dots - need at least 3 to make an outline, skipping."):format(folder.Name, #outline))
		continue
	end
	drawDebugOutline(folder, outline)

	local parts = table.create(#outline)
	for i, p in ipairs(outline) do
		parts[i] = ("%.1f,%.1f"):format(p.X, p.Z)
	end

	local entry = data:FindFirstChild(zone.Folder)
	if not entry then
		entry = Instance.new("Configuration")
		entry.Name = zone.Folder
		entry.Parent = data
	end
	entry:SetAttribute("Kind", zone.Kind)
	entry:SetAttribute("Outline", table.concat(parts, ";"))
	print(("[WeatherZones] %s storm outline published (%d dots)."):format(zone.Kind, #outline))
end
