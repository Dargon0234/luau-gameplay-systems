--[[
	ModuleScript in ReplicatedStorage > SharedModules > SandWormShared

	Shared by the worm's server brain (ServerScriptService > Server > SandWorm) and its renderer
	(StarterPlayer > StarterPlayerScripts > Client > SandWormRenderer), so the hitboxes the server uses
	line up exactly with what players see.

	How the worm is built (same math as the Blender motion preview, worm_mob.blend / worm_rig):
	  the HEAD runs along a path, and every ring, fin and the tail sits a fixed distance behind it on that
	  path, like train cars on a track. Nothing is skinned or animated: the 5 imported parts in
	  ReplicatedStorage > Mobs > SandWorm are copied and placed every frame.
]]

local Shared = {}

local UP = Vector3.yAxis

------------------------------------------------------------------ body layout (from worm_rig in worm_mob.blend)
Shared.RING_S = { 1.073, 1.06, 1.033, 1.008, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0.984, 0.941, 0.878, 0.802, 0.718, 0.635, 0.558, 0.495, 0.452, 0.436 }
Shared.FIN_S = { 0.779, 0.923, 1.017, 1.091, 1.167, 1.242, 1.306, 1.361, 1.407, 1.444, 1.471, 1.49, 1.499, 1.499, 1.49, 1.471, 1.421, 1.325, 1.195, 1.047, 0.892, 0.741, 0.604, 0.488, 0.394, 0.317 }
Shared.HEAD_S = 1.15
Shared.TAIL_S = 0.436
Shared.FIN_UP = 5.885 -- fin base = ring centre + up * FIN_UP * ring scale
Shared.PET_SPIN = { 45, -45, -135, 135 } -- petal spin about the head's forward axis (degrees)
Shared.PET_OPEN = math.rad(36) -- petal hinge angle at MawOpen = 1
Shared.HINGE = Vector3.new(0, 6.0, 0.8) -- petal hinge, head-local
Shared.MAW_LEN = 13.05 * 1.15 -- closed beak tip, studs ahead of the head point
Shared.STEP = 0.5 -- trail point spacing (studs)

-- Each mesh's bounding-box centre in part-local axes. Roblox puts a MeshPart's pivot at its bbox centre,
-- so every part is shifted by this (times its scale) from the point it hangs on.
-- (Blender (x, y, z) -> Roblox (-x, z, y); the worm faces -Z, which is LookVector.)
Shared.CENTER = {
	Ring = Vector3.new(-0.03, 0.16, 0),
	Fin = Vector3.new(0, 2.05, 0.61),
	Head = Vector3.new(0, 0, 3.55),
	Petal = Vector3.new(0, 3.61, -6.13),
	Tail = Vector3.new(0, 0, 2),
}

-- distance behind the head point of every ring, and of the tail
local HEAD_GAP, RING_STEP, TAIL_GAP = 3.77, 3.295, 1.72
local D = { HEAD_GAP }
for i = 2, #Shared.RING_S do
	D[i] = D[i - 1] + RING_STEP * (Shared.RING_S[i - 1] + Shared.RING_S[i]) / 2
end
Shared.D = D
Shared.DT = D[#D] + TAIL_GAP

-- every ring is rolled 0/90/180/270 degrees so the armour doesn't repeat (same on every client)
do
	local rng = Random.new(5)
	Shared.ROLL = {}
	for i = 1, #Shared.RING_S do
		Shared.ROLL[i] = math.rad(90 * rng:NextInteger(0, 3))
	end
end

-- CFrame at p facing t (forward) with u as its up
function Shared.frame(p, t, u)
	return CFrame.fromMatrix(p, t:Cross(u), u, -t)
end

------------------------------------------------------------------ ground (terrain only)
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace.Terrain }
groundParams.IgnoreWater = true
local DOWN = Vector3.new(0, -2200, 0)

-- The terrain never changes during a game, so each 2x2-stud cell is only raycast once and remembered.
-- (Without this the worm fired hundreds of long raycasts a second.)
local CELL = 2
local cacheY, cacheM, cacheN = {}, {}, 0

function Shared.ground(x, z, fallback)
	local ix, iz = math.floor(x / CELL), math.floor(z / CELL)
	local key = (ix + 20000) * 40000 + (iz + 20000)
	local y = cacheY[key]
	if y == nil then
		local hit = workspace:Raycast(Vector3.new((ix + 0.5) * CELL, 1600, (iz + 0.5) * CELL), DOWN, groundParams)
		if hit then
			y = hit.Position.Y
			cacheM[key] = hit.Material
		else
			y = false
		end
		cacheY[key] = y
		cacheN += 1
		if cacheN > 250000 then -- safety cap; it never gets near this on this map
			table.clear(cacheY)
			table.clear(cacheM)
			cacheN = 0
		end
	end
	if y then
		return y, cacheM[key]
	end
	return fallback or 226, nil
end

------------------------------------------------------------------ the trail the body follows
-- Keeps the head's recent path as points every STEP studs (oldest first) plus the live head point.
-- For each point it also keeps the direction of travel and an "up" carried along the path, so the
-- razorback stays on the worm's back through climbs and dives without flipping.
local Trail = {}
Trail.__index = Trail

local function transport(u, t)
	u = u - t * u:Dot(t)
	if u.Magnitude < 1e-5 then
		u = UP - t * t.Y
		if u.Magnitude < 1e-5 then
			u = Vector3.xAxis - t * t.X
		end
	end
	u = u.Unit
	-- nudge toward world up when travelling level (keeps the fins up), barely at all when vertical
	local zp = UP - t * t.Y
	local w = zp.Magnitude
	if w > 1e-3 then
		local b = 0.06 * w ^ 4
		u = u * (1 - b) + (zp / w) * b
		u = u - t * u:Dot(t)
		u = (u.Magnitude > 1e-5) and u.Unit or zp / w
	end
	return u
end
Shared.transport = transport

function Shared.newTrail(maxLen)
	local self = setmetatable({}, Trail)
	self.maxN = math.ceil((maxLen or 110) / Shared.STEP) + 6
	self:reset(Vector3.zero, -Vector3.zAxis)
	return self
end

-- Start over with the head at `head`, the body laid out straight behind it (opposite `dir`).
function Trail:reset(head, dir, length)
	dir = (dir and dir.Magnitude > 1e-4) and dir.Unit or -Vector3.zAxis
	local n = math.max(2, math.floor((length or (self.maxN - 6) * Shared.STEP) / Shared.STEP))
	local u = transport(UP, dir)
	local F, T, U = {}, {}, {}
	for k = n, 1, -1 do
		F[#F + 1] = head - dir * (k * Shared.STEP)
	end
	for i = 1, #F do
		T[i] = dir
		U[i] = u
	end
	self.F, self.T, self.U = F, T, U
	self.H = head
	self.LT, self.LU = {}, {}
	self:refresh()
end

local function dropFront(arr, count)
	local n = #arr
	if count <= 0 then
		return
	end
	table.move(arr, count + 1, n, 1)
	for i = n - count + 1, n do
		arr[i] = nil
	end
end

-- Move the head to p (the head only ever moves forward along its path).
function Trail:push(p)
	local F, T, U = self.F, self.T, self.U
	local n = #F
	local last = F[n]
	local v = p - last
	local dist = v.Magnitude
	if dist >= Shared.STEP then
		local dir = v / dist
		local k = math.floor(dist / Shared.STEP)
		for j = 1, k do
			F[n + j] = last + dir * (Shared.STEP * j)
		end
		n += k
		-- points with two neighbours ahead of them get their direction / up fixed for good
		for i = #T + 1, n - 2 do
			local t = F[math.min(i + 2, n)] - F[math.max(i - 2, 1)]
			t = (t.Magnitude > 1e-6) and t.Unit or (T[i - 1] or -Vector3.zAxis)
			T[i] = t
			U[i] = transport(U[i - 1] or UP, t)
		end
		-- forget the path behind the tail
		local extra = n - self.maxN
		if extra > 0 then
			dropFront(F, extra)
			dropFront(T, math.min(extra, #T))
			dropFront(U, math.min(extra, #U))
		end
	end
	self.H = p
	self:refresh()
end

-- direction / up for the newest points (they still change as the head moves)
function Trail:refresh()
	local F, T, U = self.F, self.T, self.U
	local n = #F
	local LT, LU = self.LT, self.LU
	table.clear(LT)
	table.clear(LU)
	local prevU = U[#T] or UP
	for i = #T + 1, n + 1 do
		local a = F[math.max(i - 2, 1)]
		local bi = math.min(i + 2, n + 1)
		local b = (bi == n + 1) and self.H or F[bi]
		local t = b - a
		t = (t.Magnitude > 1e-6) and t.Unit or (T[#T] or -Vector3.zAxis)
		LT[i] = t
		prevU = transport(prevU, t)
		LU[i] = prevU
	end
end

function Trail:_t(i)
	return self.T[i] or self.LT[i] or -Vector3.zAxis
end

function Trail:_u(i)
	return self.U[i] or self.LU[i] or UP
end

-- Position, forward direction and up at `d` studs behind the head.
function Trail:at(d)
	local F, H = self.F, self.H
	local n = #F
	local r = (H - F[n]).Magnitude
	local i0, i1, f
	if d <= r then
		if r < 1e-6 then
			i0, i1, f = n + 1, n + 1, 0
		else
			i0, i1, f = n + 1, n, math.max(d, 0) / r
		end
	else
		local x = (d - r) / Shared.STEP
		local k = math.floor(x)
		i0 = n - k
		i1 = i0 - 1
		f = x - k
		if i1 < 1 then
			local t1 = self:_t(1)
			return F[1] - t1 * ((d - r) - (n - 1) * Shared.STEP), t1, self:_u(1)
		end
	end
	local p0 = (i0 == n + 1) and H or F[i0]
	local p1 = (i1 == n + 1) and H or F[i1]
	local t0, t1 = self:_t(i0), self:_t(i1)
	local t = t0:Lerp(t1, f)
	t = (t.Magnitude > 1e-6) and t.Unit or t0
	local u = self:_u(i0):Lerp(self:_u(i1), f)
	u = u - t * u:Dot(t)
	u = (u.Magnitude > 1e-6) and u.Unit or transport(UP, t)
	return p0:Lerp(p1, f), t, u
end

function Trail:pos(d)
	local p = self:at(d)
	return p
end

-- how sharply the path bends at d (1/studs), averaged over +-3 studs
function Trail:curv(d)
	local a = math.max(d - 3, 0)
	local _, ta = self:at(a)
	local _, tb = self:at(d + 3)
	return (ta - tb).Magnitude / math.max(d + 3 - a, 1)
end

-- head-first points every `spacing` studs (for players joining mid-fight)
function Trail:points(spacing, length)
	local out = {}
	for d = 0, length, spacing do
		out[#out + 1] = self:pos(d)
	end
	return out
end

------------------------------------------------------------------ tail whip
-- The tail bursts out of the ground at T0, bends over and lies low like a whip about Height studs off the
-- ground, then swings around T0 through the target. Times are seconds after the whip starts.
Shared.TAIL = {
	Warn = 0.9, -- ground cracks, nothing out yet
	Rise = 0.5, -- tail rips up out of the ground
	Sweep = 0.55, -- the swing (this is when it hits)
	Hold = 0.35,
	Sink = 0.6,
	Radius = 8, -- the bend from coming straight up to lying flat (tighter opens gaps between the rings)
	Height = 4, -- how high the flat part sweeps (chest height on a player)
	Straight = 10, -- length of the flat part at the end
	Swing = math.rad(80), -- swings this far either side of the target
	Reach = 13, -- the target stands this far from where the tail comes up (middle of the flat part)
	Submerge = 24, -- how far underground it waits before rising
	HookLen = 34, -- the last 34 studs of the body are drawn on the tail pose instead of the path
}
local TL = Shared.TAIL
Shared.TAIL.Total = TL.Warn + TL.Rise + TL.Sweep + TL.Hold + TL.Sink

local function easeOut(x)
	return 1 - (1 - x) ^ 3
end
local function easeIn(x)
	return x ^ 3
end
local function easeInOut(x)
	return (x < 0.5) and 4 * x ^ 3 or 1 - (-2 * x + 2) ^ 3 / 2
end

-- spec = { T0 = Vector3 (ground), aMid = horizontal unit (from T0 toward the target), sign = 1/-1, t0 = server time }
-- returns rise (0..1), the curl's direction, seconds since start, and whether it's mid-swing. nil when it's over.
function Shared.tailState(spec, now)
	local e = now - spec.t0
	local s1 = TL.Warn
	local s2 = s1 + TL.Rise
	local s3 = s2 + TL.Sweep
	local s4 = s3 + TL.Hold
	local s5 = s4 + TL.Sink
	local rho, phi
	if e < 0 then
		rho, phi = 0, -TL.Swing
	elseif e < s1 then
		rho, phi = 0, -TL.Swing
	elseif e < s2 then
		rho, phi = easeOut((e - s1) / TL.Rise), -TL.Swing
	elseif e < s3 then
		rho, phi = 1, -TL.Swing + 2 * TL.Swing * easeInOut((e - s2) / TL.Sweep)
	elseif e < s4 then
		rho, phi = 1, TL.Swing
	elseif e < s5 then
		rho, phi = 1 - easeIn((e - s4) / TL.Sink), TL.Swing
	else
		return nil
	end
	local a = CFrame.fromAxisAngle(UP, phi * spec.sign):VectorToWorldSpace(spec.aMid)
	return rho, a, e, (e >= s2 and e < s3)
end

-- Point on the tail at `u` studs from the tail end (0 = tail tip, bigger = toward the body).
-- Shape: straight down underground -> bends (Radius) -> flat part Height studs up, pointing out along `a`.
-- Returns position, forward (toward the head) and up (the razorback side).
function Shared.tailAt(spec, rho, a, u)
	local R, L, H = TL.Radius, TL.Straight, TL.Height
	local base = spec.T0 - Vector3.new(0, (1 - rho) * TL.Submerge, 0)
	u = math.max(u, 0)
	if u <= L then -- the flat part
		return base + UP * H + a * (R + L - u), -a, UP
	end
	local bendLen = R * math.pi / 2
	if u <= L + bendLen then -- the bend
		local psi = (u - L) / R
		local sp, cp = math.sin(psi), math.cos(psi)
		local centre = base + a * R + UP * (H - R)
		local radial = -a * sp + UP * cp
		return centre + radial * R, -(a * cp + UP * sp), radial
	end
	-- straight down into the ground toward the rest of the body
	return base + UP * (H - R - (u - L - bendLen)), -UP, -a
end

-- how sharply the tail bends at u (for stretching the rings so the curve never gaps)
function Shared.tailCurv(u)
	local L = TL.Straight
	if u > L and u < L + TL.Radius * math.pi / 2 then
		return 1 / TL.Radius
	end
	return 0
end

-- which rings sit on the curl during a tail whip
Shared.HOOK = {}
for i = 1, #Shared.RING_S do
	Shared.HOOK[i] = (Shared.DT - D[i]) <= TL.HookLen
end

return Shared
