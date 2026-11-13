--[[
	ROBLOX FPS BOOSTER V3 — GRAPHICS PRESETS + SMART OPTIMIZATION
	+ MAP INTELLIGENCE + NETWORK LAYER + ANTI-STUTTER

	(LocalScript)

	INSTALL: StarterPlayer > StarterPlayerScripts > LocalScript > "FPSBoosterV3"

	GRAPHICS PRESETS
	  1. ภาพมันฝรั่ง   (Potato)    — pixelated, effects ปิด, shadows ปิด
	  2. ลื่นไหล       (Smooth)    — effects เบา, ไม่มี shadows
	  3. ภาพปกติ       (Normal)    — สมดุล, effects ปกติ
	  4. สวยปานกลาง    (Beautiful) — effects สวย, shadows เบา
	  5. RTX + แสงเงา  (RTX)       — effects เต็ม, shadows ครบ

	HOTKEYS
	  F1 = Toggle Booster
	  F2 = Screenshot mode (pause 3s)
	  F3 = Cycle graphics preset
	  F4 = Benchmark (10s)
]]

--// Services ------------------------------------------------------------------------------
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local TweenService       = game:GetService("TweenService")
local UserInputService   = game:GetService("UserInputService")
local GuiService         = game:GetService("GuiService")
local StarterGui         = game:GetService("StarterGui")
local Stats              = game:GetService("Stats")
local Lighting           = game:GetService("Lighting")
local CollectionService  = game:GetService("CollectionService")
local Teams              = game:GetService("Teams")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local Debris             = game:GetService("Debris")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--// Config ----------------------------------------------------------------------------------
local CONFIG = {
	GUI_NAME             = "FPSBoosterV3UI",
	IGNORE_TAG           = "FPSBoosterIgnore",
	IFRAME_TAG           = "FPSBoosterIFrameOverlay",
	KEEP_ATTRIBUTE       = "FPSBoosterKeep",
	CACHE_ATTRIBUTE      = "FPSBoosterCacheable",
	REPEAT_MIN           = 12,
	MAP_SCAN_INTERVAL    = 40,
	PASS_BUDGET_MS       = 6,
	BATCH_SIZE           = 400,
	HOTKEYS_ENABLED      = true,
	SCREENSHOT_PAUSE     = 3,
	BENCHMARK_DURATION   = 10,
	AUTO_LOW_FPS         = 25,
	SCAN_CAPS = {
		RemoteStorage = 120,
		RoundPattern  = 500,
		ShopGui       = 250,
		ShopBackpack  = 50,
	},
}

--// Singleton -------------------------------------------------------------------------------
do
	local previous = _G.__FPSBooster
	if type(previous) == "table" and type(previous.Destroy) == "function" then
		pcall(previous.Destroy)
	end
	for _, n in ipairs({ CONFIG.GUI_NAME, "FPSBoosterV2UI", "FPSBoosterUI" }) do
		local stale = playerGui:FindFirstChild(n)
		if stale then stale:Destroy() end
	end
end

local running = true
local ready = false
local conns = {}
local startTime = os.clock()
local function track(conn) conns[#conns + 1] = conn return conn end

--// Device ---------------------------------------------------------------------------------
local platformName, isMobile = "PC", false
do
	local ok, p = pcall(function() return UserInputService:GetPlatform() end)
	local n = ok and p and p.Name or ""
	if n == "Android" or n == "AndroidTV" then platformName, isMobile = "Android", true
	elseif n == "IOS" then platformName, isMobile = "iOS", true
	elseif GuiService:IsTenFootInterface() then platformName = "Console"
	elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then platformName, isMobile = "Mobile", true
	end
end

--// Theme ----------------------------------------------------------------------------------
local C = {
	bg = Color3.fromRGB(12, 14, 20), panel = Color3.fromRGB(21, 25, 35), chip = Color3.fromRGB(32, 38, 52),
	off = Color3.fromRGB(52, 60, 78), green = Color3.fromRGB(0, 255, 136), blue = Color3.fromRGB(0, 170, 255),
	text = Color3.fromRGB(232, 240, 255), dim = Color3.fromRGB(130, 146, 168),
	yellow = Color3.fromRGB(255, 200, 60), red = Color3.fromRGB(255, 77, 96), dark = Color3.fromRGB(8, 10, 14),
	purple = Color3.fromRGB(180, 130, 255), orange = Color3.fromRGB(255, 140, 60),
}

--// Helpers --------------------------------------------------------------------------------
local function make(className, props, parent)
	local o = Instance.new(className)
	for k, v in pairs(props) do o[k] = v end
	if parent then o.Parent = parent end
	return o
end
local function tween(obj, t, props)
	TweenService:Create(obj, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end
local function round2(x) return math.floor(x * 100 + 0.5) / 100 end
local function setText(l, t) if l.Text ~= t then l.Text = t end end

local function sameValue(a, b)
	local ta = typeof(a)
	if ta ~= typeof(b) then return false end
	if ta == "number" then
		return math.abs(a - b) <= 0.001 * math.max(1, math.abs(a))
	elseif ta == "NumberRange" then
		return sameValue(a.Min, b.Min) and sameValue(a.Max, b.Max)
	elseif ta == "NumberSequence" then
		local ka, kb = a.Keypoints, b.Keypoints
		if #ka ~= #kb then return false end
		for i = 1, #ka do
			if not (sameValue(ka[i].Time, kb[i].Time) and sameValue(ka[i].Value, kb[i].Value)
				and sameValue(ka[i].Envelope, kb[i].Envelope)) then return false end
		end
		return true
	end
	return a == b
end

local function scaleSeq(seq, m)
	local kps = {}
	for i, k in ipairs(seq.Keypoints) do
		kps[i] = NumberSequenceKeypoint.new(k.Time, k.Value * m, k.Envelope * m)
	end
	return NumberSequence.new(kps)
end

local function scaleFloor(orig, mult, floorValue)
	local v = orig * mult
	local f = math.min(orig, floorValue)
	if v < f then v = f end
	return v
end

local function notify(title, text, duration)
	for _ = 1, 8 do
		local ok = pcall(function()
			StarterGui:SetCore("SendNotification", { Title = title, Text = text, Duration = duration or 5 })
		end)
		if ok then return true end
		task.wait(0.4)
	end
	return false
end

--==================================================================================================
-- 1) GRAPHICS PRESETS (replaces old LEVELS)
--==================================================================================================
-- Each preset defines multipliers (1 = keep original, 0.x = reduce).
-- "special" flags control extra behaviors (pixelation, shadows, etc.)
local PRESETS = {
	{
		id = "Potato", name = "ภาพมันฝรั่ง", icon = "🥔", color = C.red,
		desc = "Pixelated, no effects, no shadows",
		rate = 0.10, life = 0.50, size = 0.60, trail = 0.15, beam = 0.25, post = 0.15, cc = 0.50,
		lightShadows = false, pixelation = true, noPost = true, lowTerrain = true,
	},
	{
		id = "Smooth", name = "ลื่นไหล", icon = "⚡", color = C.green,
		desc = "Light effects, no shadows, high FPS",
		rate = 0.35, life = 0.75, size = 0.85, trail = 0.40, beam = 0.45, post = 0.40, cc = 0.75,
		lightShadows = false, pixelation = false, noPost = false, lowTerrain = false,
	},
	{
		id = "Normal", name = "ภาพปกติ", icon = "⚖️", color = C.blue,
		desc = "Balanced visuals and performance",
		rate = 0.60, life = 0.90, size = 0.95, trail = 0.70, beam = 0.70, post = 0.70, cc = 0.92,
		lightShadows = false, pixelation = false, noPost = false, lowTerrain = false,
	},
	{
		id = "Beautiful", name = "สวยปานกลาง", icon = "💎", color = C.purple,
		desc = "Nice effects, soft shadows",
		rate = 0.85, life = 0.95, size = 1.00, trail = 0.90, beam = 0.90, post = 0.90, cc = 0.98,
		lightShadows = true, pixelation = false, noPost = false, lowTerrain = false,
	},
	{
		id = "RTX", name = "RTX + แสงเงา", icon = "✨", color = C.yellow,
		desc = "Full effects, all shadows, max quality",
		rate = 1.00, life = 1.00, size = 1.00, trail = 1.00, beam = 1.00, post = 1.00, cc = 1.00,
		lightShadows = true, pixelation = false, noPost = false, lowTerrain = false,
	},
}
local PRESET_INDEX = { Potato = 1, Smooth = 2, Normal = 3, Beautiful = 4, RTX = 5 }

local PROFILES = {
	Combat    = { tag = "A", display = "Combat / Fighting", bias = 0, repeatS = 1.3, trailS = 1.0,
		s = { ambient = 1.2, other = 1.1, own = 0.5, object = 0.8, post = 1.0 } },
	Sports    = { tag = "B", display = "Football / Sports", bias = 0, repeatS = 1.1, trailS = 1.3,
		s = { ambient = 1.1, other = 1.0, own = 0.8, object = 0.0, post = 0.9 } },
	OpenWorld = { tag = "C", display = "Open World", bias = 0, repeatS = 1.1, trailS = 1.0,
		s = { ambient = 1.2, other = 1.0, own = 0.8, object = 0.7, post = 1.0 } },
	Simulator = { tag = "D", display = "Simulator", bias = 0, repeatS = 1.5, trailS = 1.0,
		s = { ambient = 1.2, other = 1.0, own = 0.8, object = 0.7, post = 1.0 } },
	HeavyVFX  = { tag = "E", display = "Heavy VFX", bias = 1, repeatS = 1.4, trailS = 1.2,
		s = { ambient = 1.3, other = 1.3, own = 0.7, object = 0.6, post = 1.2 } },
	General   = { tag = "F", display = "General", bias = 0, repeatS = 1.0, trailS = 1.0,
		s = { ambient = 1.0, other = 1.0, own = 0.8, object = 0.7, post = 1.0 } },
}
local PROFILE_CHOICES = { "Auto", "Combat", "Sports", "OpenWorld", "Simulator", "HeavyVFX", "General" }
local MODES = { "Auto", "Manual" }
local MODE_NAMES = { Auto = "Auto (adaptive)", Manual = "Manual (fixed preset)" }

local POST_CLASSES = {
	BloomEffect = true, BlurEffect = true, SunRaysEffect = true,
	DepthOfFieldEffect = true, ColorCorrectionEffect = true,
}
local PRESERVED = { Highlight = true, ForceField = true, Sparkles = true, Explosion = true }
local PART_CLASSES = {
	Part = true, MeshPart = true, UnionOperation = true, WedgePart = true, CornerWedgePart = true, TrussPart = true,
}

--==================================================================================================
-- 2) STATE
--==================================================================================================
local State  = {
	enabled = true,
	mode = "Auto",
	presetId = "Normal",
	profileChoice = "Auto",
	autoQuality = true,
	screenshotMode = false,
	benchmarking = false,
}
local Active = { presetId = "Normal", presetIdx = 3, profile = "General" }
local Detect = { profile = "General", reason = "Analyzing…", workload = "Unknown",
                 pending = nil, pendingCount = 0, lastChange = 0, scores = {} }
local Auto   = { presetIdx = 3, low = 0, high = 0, lowSecs = 0, lastChange = 0, lastDown = nil,
                 floorIdx = 1, floorUntil = 0, noRaiseUntil = 0, peak = 0, pending = nil,
                 bottleneck = "Measuring…" }
local Perf   = { fps = 0, frameMs = 0, worstMs = 0, frames = 0, acc = 0, maxDt = 0, hitches = 0,
                 hitchShown = 0, memMb = nil }
local Net    = { samples = {}, ping = nil, source = "", jitter = 0, peak = 0, mean = 0, status = "Unavailable",
                 trend = "steady", recv = nil, send = nil }
local Scene  = { parts = 0, humanoids = 0, balls = 0, preserved = 0, extent = 0, terrainSpan = 0,
                 minX = math.huge, maxX = -math.huge, minZ = math.huge, maxZ = -math.huge }
local Metrics = { emitters = 0, active = 0, rateSum = 0, trails = 0, beams = 0, post = 0, lights = 0, smokeFire = 0,
                  charFx = 0, objectFx = 0, ambientFx = 0, tracked = 0, maxRep = 0, repRatio = 0, tools = 0,
                  physRate = 60, cachedRemotes = 0 }
local Counts = { tracked = 0, adjusted = 0, scanned = 0 }
local IFrame = { enabled = false, conns = {} }
local StatusText = "Initializing…"

local Bench = { running = false, startTime = 0, samples = {}, avg = 0, min = math.huge, max = 0,
                minFps = math.huge, maxFps = 0, result = nil }

local MapInfo = {
	placeId = game.PlaceId, placeName = "", creatorName = "", creatorId = 0,
	playerCount = 0, maxPlayers = 0, isPrivate = false,
	hasTeams = false, teamCount = 0, hasRoundSys = false, hasShop = false,
	hasLeaderstats = false, remoteCount = 0,
	hasTerrain = false, terrainSize = 0, partCount = 0,
	signature = "Unknown", confidence = 0, detectedAt = 0,
}

local UI = nil
local refresh, reapplyAll, setEnabled, setMode, setPreset, cyclePreset, cycleProfile,
      setAutoQuality, setIFrame, restoreAll, closeAll, runBenchmark, toggleScreenshotMode
      = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil

--==================================================================================================
-- 3) VFX ENGINE — Fast batch processing + dirty tracking
--==================================================================================================
local records  = setmetatable({}, { __mode = "k" })
local tracked  = setmetatable({}, { __mode = "k" })
local metaOf   = setmetatable({}, { __mode = "k" })
local overlays = setmetatable({}, { __mode = "k" })
local NameCount = {}
local trackedList = {}  -- flat array for iteration (cache)

-- Cache current preset values (avoid table lookups)
local CUR = { rate = 1, life = 1, size = 1, trail = 1, beam = 1, post = 1, cc = 1,
              lightShadows = false, pixelation = false, noPost = false, lowTerrain = false }

local function updateCur()
	local p = PRESETS[Active.presetIdx]
	CUR.rate = p.rate; CUR.life = p.life; CUR.size = p.size; CUR.trail = p.trail
	CUR.beam = p.beam; CUR.post = p.post; CUR.cc = p.cc
	CUR.lightShadows = p.lightShadows; CUR.pixelation = p.pixelation
	CUR.noPost = p.noPost; CUR.lowTerrain = p.lowTerrain
end

local curCat, curRep = "ambient", false

local function M(kind, minM)
	local prof = PROFILES[Active.profile]
	local s = prof.s[curCat] or 1
	if curRep then s *= prof.repeatS end
	if kind == "trail" then s *= prof.trailS end
	return math.clamp(1 - (1 - CUR[kind]) * s, minM or 0.1, 1)
end

local function lightShadowsOff()
	return CUR.lightShadows and PROFILES[Active.profile].s[curCat] ~= 0
end

local lightHandler = { { "Shadows", function(o) if lightShadowsOff() then return false end return o end } }
local HANDLERS = {
	ParticleEmitter = {
		{ "Rate", function(o)
			if o <= 0 then return o end
			return math.min(o, math.max(1, round2(o * M("rate", 0.08))))
		end },
		{ "Lifetime", function(o)
			local m = M("life", 0.5)
			if m >= 0.999 then return o end
			local a = math.min(o.Min, math.max(0.1, o.Min * m))
			local b = math.min(o.Max, math.max(0.1, o.Max * m))
			return NumberRange.new(a, math.max(a, b))
		end },
		{ "Size", function(o)
			local m = M("size", 0.6)
			if m >= 0.999 then return o end
			return scaleSeq(o, m)
		end },
	},
	Trail = { { "Lifetime", function(o) return scaleFloor(o, M("trail", 0.25), 0.15) end } },
	Beam = { { "Segments", function(o)
		if o <= 3 then return o end
		return math.max(3, math.floor(o * M("beam", 0.25) + 0.5))
	end } },
	BloomEffect = {
		{ "Intensity", function(o) return scaleFloor(o, M("post", 0.3), 0.05) end },
		{ "Size",      function(o) return scaleFloor(o, M("post", 0.5), 4) end },
	},
	BlurEffect    = { { "Size",      function(o) return scaleFloor(o, M("post", 0.3), 1) end } },
	SunRaysEffect = { { "Intensity", function(o) return scaleFloor(o, M("post", 0.3), 0.02) end } },
	DepthOfFieldEffect = {
		{ "FarIntensity",  function(o) return scaleFloor(o, M("post", 0.3), 0.02) end },
		{ "NearIntensity", function(o) return scaleFloor(o, M("post", 0.3), 0.02) end },
	},
	ColorCorrectionEffect = {
		{ "Saturation", function(o) return o * M("cc", 0.6) end },
		{ "Contrast",   function(o) return o * M("cc", 0.6) end },
	},
	Smoke = { { "Size", function(o) return scaleFloor(o, M("size", 0.6), 1) end } },
	Fire  = { { "Size", function(o) return scaleFloor(o, M("size", 0.6), 2) end } },
	PointLight = lightHandler, SpotLight = lightHandler, SurfaceLight = lightHandler,
}

local function applyProp(inst, rec, prop, fn, cfg)
	local okRead, cur = pcall(function() return inst[prop] end)
	if not okRead then return end

	local entry = rec[prop]
	if not entry then
		if not cfg then return end
		entry = { orig = cur, applied = cur }
		rec[prop] = entry
	elseif not sameValue(cur, entry.applied) then
		entry.orig, entry.applied = cur, cur
	end

	local target = entry.orig
	if cfg then
		local okFn, res = pcall(fn, entry.orig)
		if okFn and res ~= nil then target = res end
	end
	if sameValue(target, cur) then return end

	if pcall(function() inst[prop] = target end) then
		local okNow, now = pcall(function() return inst[prop] end)
		entry.applied = okNow and now or target
	end
end

local function findCharacter(inst)
	local a = inst.Parent
	while a and a ~= workspace do
		if a:IsA("Model") and a:FindFirstChildOfClass("Humanoid") then return a end
		a = a.Parent
	end
	return nil
end

local function isMovingObject(part)
	if not (part and part:IsA("BasePart")) then return false end
	local ok, res = pcall(function()
		if part.Anchored or part.Size.Magnitude >= 14 then return false end
		if part:IsA("Part") and part.Shape == Enum.PartType.Ball then return true end
		return part:FindFirstChildOfClass("Trail") ~= nil
	end)
	return ok and res
end

local function classifyWorld(inst)
	local char = findCharacter(inst)
	if char then
		return (Players:GetPlayerFromCharacter(char) == player) and "own" or "other"
	end
	local part = inst.Parent
	if part and part:IsA("Attachment") then part = part.Parent end
	if isMovingObject(part) then return "object" end
	return "ambient"
end

local function isIgnored(inst)
	return CollectionService:HasTag(inst, CONFIG.IGNORE_TAG) or inst:GetAttribute(CONFIG.IGNORE_TAG) == true
end

local function register(inst)
	if tracked[inst] then return end
	if isIgnored(inst) then return end
	local cn = inst.ClassName
	tracked[inst] = true
	trackedList[#trackedList + 1] = inst
	metaOf[inst] = { cat = POST_CLASSES[cn] and "post" or classifyWorld(inst) }
	if cn == "ParticleEmitter" then NameCount[inst.Name] = (NameCount[inst.Name] or 0) + 1 end
end

local function processInstance(inst)
	local handlers = HANDLERS[inst.ClassName]
	if not handlers then return end
	local enabled = State.enabled and not State.screenshotMode
	local rec = records[inst]
	if not enabled and not rec then return end

	if enabled then
		if not metaOf[inst] then register(inst) end
		local meta = metaOf[inst]
		if not meta then return end
		curCat = meta.cat
		curRep = inst.ClassName == "ParticleEmitter" and (NameCount[inst.Name] or 0) >= CONFIG.REPEAT_MIN
		if not rec then rec = {}; records[inst] = rec end
	end
	for _, h in ipairs(handlers) do
		applyProp(inst, rec, h[1], h[2], enabled or nil)
	end
	if not enabled then records[inst] = nil end
end

--==================================================================================================
-- 4) IFRAME MODULE
--==================================================================================================
local function overlayProp(inst)
	if inst:IsA("GuiObject") then return "Visible" end
	if inst:IsA("LayerCollector") or inst:IsA("Highlight") then return "Enabled" end
	return nil
end

local function isApprovedOverlay(inst)
	if not overlayProp(inst) then return false end
	if inst:GetAttribute(CONFIG.KEEP_ATTRIBUTE) == true then return false end
	if UI and UI.gui and inst:IsDescendantOf(UI.gui) then return false end
	local explicit = CollectionService:HasTag(inst, CONFIG.IFRAME_TAG)
		or inst:GetAttribute(CONFIG.IFRAME_TAG) == true
	if not explicit then return false end
	if inst:IsA("GuiButton") or inst:IsA("TextBox") then return false end
	if inst:IsA("GuiBase2d") and (inst:FindFirstChildWhichIsA("GuiButton", true) or inst:FindFirstChildWhichIsA("TextBox", true)) then
		return false
	end
	return true
end

local function returnFalse() return false end
local function processOverlay(inst)
	local prop = overlayProp(inst)
	if not prop then return end
	local hide = State.enabled and IFrame.enabled and not State.screenshotMode
	local rec = records[inst]
	if not hide and not rec then return end
	if not rec then rec = {}; records[inst] = rec end
	applyProp(inst, rec, prop, returnFalse, hide or nil)
	if not hide then records[inst] = nil end
end

local function registerOverlay(inst)
	if overlays[inst] then return end
	if isApprovedOverlay(inst) then
		overlays[inst] = true
		pcall(processOverlay, inst)
	end
end

setIFrame = function(v)
	v = v and true or false
	if v == IFrame.enabled then return end
	IFrame.enabled = v
	for _, c in ipairs(IFrame.conns) do pcall(function() c:Disconnect() end) end
	table.clear(IFrame.conns)
	if v then
		IFrame.conns[1] = playerGui.DescendantAdded:Connect(function(inst)
			if inst:GetAttribute(CONFIG.IFRAME_TAG) == true then
				task.defer(registerOverlay, inst)
			end
		end)
		task.spawn(function()
			for _, d in ipairs(playerGui:GetDescendants()) do
				if d:GetAttribute(CONFIG.IFRAME_TAG) == true then pcall(registerOverlay, d) end
			end
		end)
	else
		for inst in pairs(overlays) do pcall(processOverlay, inst) end
		table.clear(overlays)
	end
	if UI then UI.syncControls(false) end
end

--==================================================================================================
-- 5) APPLY PASSES — frame-budgeted with adaptive chunk
--==================================================================================================
local generation = 0
local function processAny(inst)
	if overlays[inst] then processOverlay(inst) else processInstance(inst) end
end

local function runPass(gen)
	updateCur()
	local n = #trackedList
	local i = 1
	local budget = CONFIG.PASS_BUDGET_MS / 1000
	local chunkLimit = 2000

	while i <= n do
		if gen ~= generation or not running then return false end
		local frameStart = os.clock()
		local processed = 0
		while i <= n and (os.clock() - frameStart) < budget and processed < chunkLimit do
			local inst = trackedList[i]
			pcall(processAny, inst)
			i += 1
			processed += 1
		end
		if i <= n then RunService.Heartbeat:Wait() end
	end

	-- process overlays too
	for inst in pairs(overlays) do
		if gen ~= generation or not running then return false end
		pcall(processOverlay, inst)
	end
	return true
end

reapplyAll = function()
	if not ready then return end
	generation += 1
	task.spawn(runPass, generation)
end

local pending = {}
local function onDescendantAdded(inst)
	if HANDLERS[inst.ClassName] then pending[#pending + 1] = inst end
end

--==================================================================================================
-- 6) SCENE ANALYSIS
--==================================================================================================
local function scanChunk(list, i, j)
	for k = i, j do
		local d = list[k]
		local cn = d.ClassName
		if HANDLERS[cn] then
			register(d)
		elseif PART_CLASSES[cn] then
			Scene.parts += 1
			if d.Anchored then
				if Scene.parts % 4 == 0 then
					local sz = d.Size
					if sz.Magnitude < 800 then
						local p = d.Position
						if p.X < Scene.minX then Scene.minX = p.X end
						if p.X > Scene.maxX then Scene.maxX = p.X end
						if p.Z < Scene.minZ then Scene.minZ = p.Z end
						if p.Z > Scene.maxZ then Scene.maxZ = p.Z end
					end
				end
			elseif cn == "Part" and d.Shape == Enum.PartType.Ball and d.Size.Magnitude < 14 and not findCharacter(d) then
				Scene.balls += 1
			end
		elseif cn == "Humanoid" then
			Scene.humanoids += 1
		elseif PRESERVED[cn] then
			Scene.preserved += 1
		end
	end
end

local function scanRoot(root)
	local list = root:GetDescendants()
	local total, i = #list, 1
	while i <= total do
		local j = math.min(i + 1199, total)
		pcall(scanChunk, list, i, j)
		i = j + 1
		if i <= total then RunService.Heartbeat:Wait() end
	end
end

local function finishScene()
	if Scene.maxX > Scene.minX then
		Scene.extent = math.max(Scene.maxX - Scene.minX, Scene.maxZ - Scene.minZ)
	end
	pcall(function()
		local e = workspace.Terrain.MaxExtents
		Scene.terrainSpan = math.max(e.Max.X - e.Min.X, e.Max.Z - e.Min.Z)
	end)
end

local function updateMetrics()
	local m = { emitters = 0, active = 0, rateSum = 0, trails = 0, beams = 0, post = 0, lights = 0, smokeFire = 0,
		charFx = 0, objectFx = 0, ambientFx = 0, tracked = 0, maxRep = 0, repRatio = 0, tools = 0,
		physRate = 60, cachedRemotes = 0 }
	local names = {}
	for i = 1, #trackedList do
		local inst = trackedList[i]
		local cn = inst.ClassName
		m.tracked += 1
		local meta = metaOf[inst]
		if meta then
			local c = meta.cat
			if c == "own" or c == "other" then m.charFx += 1
			elseif c == "object" then m.objectFx += 1
			elseif c == "ambient" then m.ambientFx += 1 end
		end
		if cn == "ParticleEmitter" then
			m.emitters += 1
			names[inst.Name] = (names[inst.Name] or 0) + 1
			if inst.Enabled then
				m.active += 1
				local rec = records[inst]
				local rate = (rec and rec.Rate and rec.Rate.orig) or inst.Rate
				m.rateSum += rate
			end
		elseif cn == "Trail" then m.trails += 1
		elseif cn == "Beam" then m.beams += 1
		elseif POST_CLASSES[cn] then m.post += 1
		elseif cn == "Smoke" or cn == "Fire" then m.smokeFire += 1
		elseif cn == "PointLight" or cn == "SpotLight" or cn == "SurfaceLight" then m.lights += 1 end
	end
	local repCount = 0
	for _, n in pairs(names) do
		if n > m.maxRep then m.maxRep = n end
		if n >= CONFIG.REPEAT_MIN then repCount += n end
	end
	m.repRatio = (m.emitters > 0) and (repCount / m.emitters) or 0
	NameCount = names

	pcall(function()
		local n = 0
		for _, c in ipairs(player.Backpack:GetChildren()) do if c:IsA("Tool") then n += 1 end end
		if player.Character then
			for _, c in ipairs(player.Character:GetChildren()) do if c:IsA("Tool") then n += 1 end end
		end
		m.tools = n
	end)

	Metrics = m

	local fx = m.active + m.trails + m.beams
	if fx < 40 and m.rateSum < 1500 then Detect.workload = "Light"
	elseif fx < 150 and m.rateSum < 4000 then Detect.workload = "Moderate"
	elseif fx < 400 and m.rateSum < 10000 then Detect.workload = "Heavy"
	else Detect.workload = "Extreme" end
end

--==================================================================================================
-- 6.5) MAP INTELLIGENCE
--==================================================================================================
local _productCache = nil
local function getProductInfoCached()
	if _productCache then return _productCache end
	local ok, product = pcall(function() return MarketplaceService:GetProductInfo(game.PlaceId) end)
	if ok and product then
		_productCache = { name = product.Name or "", creator = "", creatorId = 0 }
	else
		_productCache = { name = "", creator = "", creatorId = 0 }
	end
	return _productCache
end

local function scanMapInfo()
	local info = MapInfo
	info.detectedAt = os.clock()

	local prod = getProductInfoCached()
	info.placeName = prod.name
	if info.placeName == "" then
		pcall(function()
			info.creatorName = game.CreatorName or ""
			info.creatorId   = game.CreatorId or 0
		end)
	end

	info.playerCount = #Players:GetPlayers()
	info.maxPlayers  = Players.MaxPlayers
	info.isPrivate   = (info.playerCount <= 1 and info.maxPlayers >= 2)

	pcall(function()
		local teams = Teams:GetTeams()
		info.teamCount = #teams
		info.hasTeams  = info.teamCount > 0
	end)

	info.hasLeaderstats = player:FindFirstChild("leaderstats") ~= nil

	local shopGuiHit, shopBpHit, roundHit, remoteCount = false, false, false, 0

	pcall(function()
		local n = 0
		for _, d in ipairs(playerGui:GetDescendants()) do
			if not shopGuiHit then
				local nm = d.Name:lower()
				if nm:find("shop") or nm:find("store") or nm:find("buy") then shopGuiHit = true end
			end
			n += 1
			if n >= CONFIG.SCAN_CAPS.ShopGui then break end
		end
	end)

	pcall(function()
		local n = 0
		for _, d in ipairs(player.Backpack:GetChildren()) do
			if not shopBpHit then
				local nm = d.Name:lower()
				if nm:find("shop") or nm:find("buy") then shopBpHit = true end
			end
			n += 1
			if n >= CONFIG.SCAN_CAPS.ShopBackpack then break end
		end
	end)

	pcall(function()
		local n = 0
		for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
			if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
				remoteCount += 1
				if remoteCount >= CONFIG.SCAN_CAPS.RemoteStorage then break end
			end
			if not roundHit then
				local nm = d.Name:lower()
				if nm:find("round") or nm:find("gamestate") or nm:find("match") then roundHit = true end
			end
			n += 1
			if n >= CONFIG.SCAN_CAPS.RoundPattern then break end
		end
	end)

	info.hasShop = shopGuiHit or shopBpHit
	info.remoteCount = remoteCount
	info.hasRoundSys = roundHit

	pcall(function()
		local e = workspace.Terrain.MaxExtents
		info.terrainSize = math.max(e.Max.X - e.Min.X, e.Max.Z - e.Min.Z)
		info.hasTerrain  = info.terrainSize > 64
	end)

	info.partCount = Scene.parts

	local sig, conf = "Unknown", 0
	if info.hasTeams and info.teamCount >= 2 and (Scene.humanoids >= 4 or info.maxPlayers >= 8) then
		sig, conf = "TeamCombat", 70
	elseif info.hasRoundSys and remoteCount >= 5 then
		sig, conf = "RoundBased", 65
	elseif Scene.balls >= 1 and info.hasLeaderstats then
		sig, conf = "SportsSimulator", 60
	elseif info.hasTerrain and info.terrainSize >= 1000 and workspace.StreamingEnabled then
		sig, conf = "OpenWorld", 75
	elseif info.hasLeaderstats and Scene.balls == 0 then
		sig, conf = "Simulator", 55
	elseif Metrics.active >= 200 then
		sig, conf = "HeavyVFX", 60
	end
	info.signature, info.confidence = sig, conf
end

--==================================================================================================
-- 7) PERFORMANCE + NETWORK MONITORING
--==================================================================================================
local function readPing()
	local ok, v = pcall(function() return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() end)
	if ok and type(v) == "number" and v > 0 then return v, "Data Ping" end
	local ok2, p = pcall(function() return player:GetNetworkPing() end)
	if ok2 and type(p) == "number" then return p * 1000, "GetNetworkPing" end
	return nil, ""
end

local function sampleNetwork()
	local ping, source = readPing()
	Net.ping, Net.source = ping, source
	if ping then
		local s = Net.samples
		s[#s + 1] = ping
		if #s > 20 then table.remove(s, 1) end
		local sum, peak, deltaSum = 0, 0, 0
		for i, v in ipairs(s) do
			sum += v
			if v > peak then peak = v end
			if i > 1 then deltaSum += math.abs(v - s[i - 1]) end
		end
		Net.mean, Net.peak = sum / #s, peak
		Net.jitter = (#s > 1) and (deltaSum / (#s - 1)) or 0

		if #s >= 10 then
			local a, b = 0, 0
			for i = #s - 4, #s do a += s[i] end
			for i = #s - 9, #s - 5 do b += s[i] end
			local diff = (a - b) / 5
			Net.trend = (diff > 15) and "rising" or ((diff < -15) and "falling" or "steady")
		end

		if #s >= 5 and (Net.jitter > 40 or Net.peak > math.max(250, Net.mean * 3)) then Net.status = "Unstable"
		elseif ping < 60 then Net.status = "Excellent"
		elseif ping < 120 then Net.status = "Good"
		elseif ping < 200 then Net.status = "Fair"
		else Net.status = "Poor" end
	else
		Net.status = "Unavailable"
	end
	local okR, r = pcall(function() return Stats.DataReceiveKbps end)
	local okS, s2 = pcall(function() return Stats.DataSendKbps end)
	Net.recv = okR and r or nil
	Net.send = okS and s2 or nil
end

local function targetFps()
	local p = Auto.peak
	if p <= 0 then return 60 end
	if p < 40 then return 30 end
	if p < 75 then return 60 end
	if p < 100 then return 90 end
	return 120
end

local function perfLabel()
	if Perf.fps <= 0 then return "Measuring…", C.dim end
	local ratio = Perf.fps / targetFps()
	if ratio >= 0.93 then return "Smooth", C.green end
	if ratio >= 0.78 then return "Moderate", C.yellow end
	if ratio >= 0.50 then return "Heavy load", C.yellow end
	return "Critical", C.red
end

local function updateCounts()
	local t, a = 0, 0
	for _ in pairs(tracked) do t += 1 end
	for _, rec in pairs(records) do
		for _, e in pairs(rec) do
			if not sameValue(e.orig, e.applied) then a += 1 break end
		end
	end
	Counts.tracked, Counts.adjusted = t, a
end

--==================================================================================================
-- 7.5) NETWORK OPTIMIZATION LAYER
--==================================================================================================
local NetOpt = {
	enabled = true, physicsThrottle = true,
	region = "Unknown", physRate = 60, restoredPhys = nil,
}

local function detectRegion()
	local ok, regionId = pcall(function() return workspace:GetAttribute("Region") end)
	if ok and type(regionId) == "string" and #regionId >= 2 then return regionId end
	return "Unknown"
end

local function setupPhysicsThrottle()
	if not NetOpt.physicsThrottle then return end
	pcall(function()
		NetOpt.restoredPhys = workspace.PhysicsSteppingMethod
		if workspace.PhysicsSteppingMethod ~= Enum.PhysicsSteppingMethod.Fixed then
			workspace.PhysicsSteppingMethod = Enum.PhysicsSteppingMethod.Fixed
		end
	end)
end

local pingEMA = 0
local function smoothPing()
	if not Net.ping then return nil end
	pingEMA = (pingEMA == 0) and Net.ping or (pingEMA * 0.8 + Net.ping * 0.2)
	return pingEMA
end

local NetDiag = { serverRTT = 0, clientLoad = 0, netHealth = "Unknown", advice = "", perceived = 0 }

local function runNetworkDiagnostics()
	NetDiag.serverRTT  = smoothPing() or 0
	NetDiag.clientLoad = Perf.frameMs
	local perceived = NetDiag.serverRTT + NetDiag.clientLoad * 1.5
	NetDiag.perceived = perceived
	if perceived < 80 then
		NetDiag.netHealth = "Excellent"; NetDiag.advice = "Connection is optimal."
	elseif perceived < 150 then
		NetDiag.netHealth = "Good"; NetDiag.advice = "Smooth — no action needed."
	elseif perceived < 250 then
		NetDiag.netHealth = "Fair"; NetDiag.advice = "Try lower preset or closer region."
	else
		NetDiag.netHealth = "Poor"; NetDiag.advice = "Check Wi-Fi; try a closer server."
	end
end

local function applyNetworkOpt()
	if not NetOpt.enabled then return end
	NetOpt.region = detectRegion()
	pcall(setupPhysicsThrottle)
end

local function restoreNetworkOpt()
	pcall(function()
		if NetOpt.restoredPhys ~= nil then
			workspace.PhysicsSteppingMethod = NetOpt.restoredPhys
		end
	end)
end

--==================================================================================================
-- 8) SMART PROFILE DETECTION
--==================================================================================================
local function evaluateProfile()
	local m, sc, mi = Metrics, Scene, MapInfo
	local scores = { Combat = 0, Sports = 0, OpenWorld = 0, Simulator = 0, HeavyVFX = 0 }
	local why = { Combat = {}, Sports = {}, OpenWorld = {}, Simulator = {}, HeavyVFX = {} }
	local function add(p, pts, text) scores[p] += pts; why[p][#why[p] + 1] = text end

	local fxTotal = m.emitters + m.trails + m.beams
	local charRatio = (fxTotal > 0) and (m.charFx / fxTotal) or 0

	if fxTotal >= 8 and charRatio >= 0.35 then add("Combat", 3, string.format("%d%% of effects attach to characters", math.floor(charRatio * 100))) end
	if m.tools >= 2 then add("Combat", 2, string.format("%d tools equipped/owned", m.tools)) end
	if sc.humanoids >= 4 then add("Combat", 1, string.format("%d characters/NPCs present", sc.humanoids)) end
	if sc.balls >= 1 and sc.balls <= 4 then add("Sports", 3, string.format("%d ball-shaped moving object(s)", sc.balls)) end
	if m.objectFx >= 1 and sc.balls >= 1 then add("Sports", 1, "effects attached to moving objects") end
	if sc.humanoids >= 6 and sc.balls >= 1 then add("Sports", 1, "many players around a ball") end
	if sc.extent >= 2500 then add("OpenWorld", 3, string.format("world spans ~%d studs", math.floor(sc.extent))) end
	if workspace.StreamingEnabled then add("OpenWorld", 2, "StreamingEnabled is on") end
	if sc.terrainSpan >= 200 then add("OpenWorld", 2, "large terrain area") end
	if sc.parts >= 20000 then add("OpenWorld", 1, string.format("%d parts loaded", sc.parts)) end
	if m.maxRep >= 15 and m.repRatio >= 0.4 then add("Simulator", 3, string.format("%d identical emitters", m.maxRep)) end
	if player:FindFirstChild("leaderstats") then add("Simulator", 1, "leaderstats present") end
	if m.ambientFx >= 40 then add("Simulator", 1, string.format("%d world-placed effects", m.ambientFx)) end
	if m.active >= 250 then add("HeavyVFX", 3, string.format("%d active emitters", m.active))
	elseif m.active >= 120 then add("HeavyVFX", 2, string.format("%d active emitters", m.active)) end
	if m.rateSum >= 4000 then add("HeavyVFX", 3, string.format("%dk particles/s", math.floor(m.rateSum / 1000)))
	elseif m.rateSum >= 1500 then add("HeavyVFX", 2, string.format("%.1fk particles/s", m.rateSum / 1000)) end
	if m.post >= 4 then add("HeavyVFX", 1, string.format("%d lighting effects", m.post)) end
	if Auto.lowSecs >= 10 and fxTotal >= 60 then add("HeavyVFX", 2, "FPS below target while many effects active") end

	if mi.hasTeams and mi.teamCount >= 2 then add("Combat", 2, string.format("%d teams", mi.teamCount)) end
	if mi.hasRoundSys then add("Combat", 1, "round system") end
	if mi.signature == "SportsSimulator" then add("Sports", 2, "sports signature") end
	if mi.hasTerrain and mi.terrainSize >= 1000 then add("OpenWorld", 2, string.format("terrain %.0f studs", mi.terrainSize)) end
	if mi.hasLeaderstats and m.maxRep >= 10 then add("Simulator", 2, "leaderstats + repeated emitters") end
	if mi.hasShop then add("Simulator", 1, "shop UI") end
	if mi.remoteCount >= 20 and m.active >= 100 then add("HeavyVFX", 1, string.format("%d remotes + heavy FX", mi.remoteCount)) end

	local best, bestScore = "General", 0
	for _, p in ipairs({ "Combat", "Sports", "OpenWorld", "Simulator" }) do
		if scores[p] > bestScore then best, bestScore = p, scores[p] end
	end
	if bestScore < 3 then best = "General" end
	local genre = best
	if scores.HeavyVFX >= 4 then best = "HeavyVFX" end

	Detect.scores = scores
	local reason
	if best == "General" then
		reason = "No strong genre, using balanced defaults"
	else
		local parts = {}
		for i = 1, math.min(3, #why[best]) do parts[i] = why[best][i] end
		reason = table.concat(parts, "; ")
		if best == "HeavyVFX" and genre ~= "General" then
			reason ..= " (also resembles " .. PROFILES[genre].display .. ")"
		end
	end
	return best, reason
end

-- Convert profile → suggested preset index
local function suggestPreset(profileKey)
	local prof = PROFILES[profileKey]
	if profileKey == "HeavyVFX" then return 1 end  -- potato
	if profileKey == "Combat" then return 2 end     -- smooth
	if profileKey == "Sports" then return 2 end     -- smooth
	if profileKey == "OpenWorld" then return isMobile and 1 or 3 end
	if profileKey == "Simulator" then return 2 end
	return isMobile and 2 or 3
end

local function runDetection(initial, now)
	local best, reason = evaluateProfile()
	if initial then
		Detect.profile, Detect.reason, Detect.lastChange = best, reason, now
		Detect.pending, Detect.pendingCount = nil, 0
		Auto.presetIdx = suggestPreset(best)
		return true
	end
	if best == Detect.profile then
		Detect.reason, Detect.pending, Detect.pendingCount = reason, nil, 0
		return false
	end
	if Detect.pending == best then Detect.pendingCount += 1 else Detect.pending, Detect.pendingCount = best, 1 end
	if Detect.pendingCount >= 3 and now - Detect.lastChange >= 60 then
		Detect.profile, Detect.reason, Detect.lastChange = best, reason, now
		Detect.pending, Detect.pendingCount = nil, 0
		Auto.presetIdx = math.max(Auto.presetIdx, suggestPreset(best) - 1)
		return true
	end
	return false
end

--==================================================================================================
-- 9) ADAPTIVE ENGINE
--==================================================================================================
local function resolveActive()
	local presetId = State.presetId
	local presetIdx = PRESET_INDEX[presetId] or 3
	if State.mode == "Auto" then
		presetIdx = Auto.presetIdx
		presetId = PRESETS[presetIdx].id
	end
	local profile = Detect.profile
	if State.profileChoice ~= "Auto" then profile = State.profileChoice end
	return presetId, presetIdx, profile
end

refresh = function(forceReapply)
	local presetId, presetIdx, prof = resolveActive()
	local changed = presetId ~= Active.presetId or prof ~= Active.profile
	Active.presetId, Active.presetIdx, Active.profile = presetId, presetIdx, prof
	updateCur()
	if UI then UI.syncControls(false) end
	if changed or forceReapply then reapplyAll() end
end

local function setAutoPreset(idx, now)
	Auto.presetIdx = idx
	Auto.lastChange, Auto.low, Auto.high = now, 0, 0
	refresh()
end

local function autoStep(now)
	-- Auto quality (independent of Auto mode) — drop preset if FPS too low
	if State.autoQuality and State.enabled and not State.screenshotMode then
		if Perf.fps > 5 and Perf.fps < CONFIG.AUTO_LOW_FPS and Active.presetIdx > 1 then
			if now - Auto.lastChange > 15 then
				Auto.bottleneck = "Auto-quality: FPS low, dropping preset"
				setAutoPreset(Active.presetIdx - 1, now)
				return
			end
		end
	end

	if State.mode ~= "Auto" or not State.enabled then
		Auto.low, Auto.high, Auto.pending = 0, 0, nil
		return
	end
	if now - startTime < 8 or Perf.fps < 5 then return end
	local target = targetFps()

	if Auto.pending and now >= Auto.pending.at + 10 then
		local p = Auto.pending
		Auto.pending = nil
		if Perf.fps < p.fpsBefore * 1.04 and Perf.fps < target * 0.93 then
			Auto.noRaiseUntil = now + 120
			Auto.bottleneck = "Not VFX-bound (CPU, scripts or physics)"
			setAutoPreset(p.from, now)
			return
		end
		Auto.bottleneck = "Render/VFX-bound (reduction helped)"
	end

	if Perf.fps < target * 0.78 then Auto.low += 1; Auto.high = 0
	elseif Perf.fps > target * 0.95 then Auto.high += 1; Auto.low = 0
	else Auto.low, Auto.high = 0, 0 end

	if now - Auto.lastChange < 8 then return end

	if Auto.low >= 3 and Active.presetIdx > 1 and now >= Auto.noRaiseUntil then
		if Auto.lastDown and now - Auto.lastDown < 90 then
			Auto.floorIdx, Auto.floorUntil = Active.presetIdx - 1, now + 180
		end
		Auto.pending = { from = Active.presetIdx, fpsBefore = Perf.fps, at = now }
		setAutoPreset(Active.presetIdx - 1, now)
	elseif Auto.high >= 15 and Active.presetIdx < 5 then
		local floor = (now < Auto.floorUntil) and Auto.floorIdx or 1
		if Active.presetIdx + 1 <= 5 and Active.presetIdx + 1 >= floor then
			Auto.lastDown = now
			setAutoPreset(Active.presetIdx + 1, now)
		end
	end
end

--==================================================================================================
-- 10) BENCHMARK + SCREENSHOT MODE
--==================================================================================================
runBenchmark = function()
	if Bench.running then return end
	Bench = { running = true, startTime = os.clock(), samples = {}, avg = 0, min = math.huge, max = 0,
	          minFps = math.huge, maxFps = 0, result = nil }
	task.spawn(function()
		notify("FPS BOOSTER", "Benchmark started (10s)…", 3)
		local frames, acc, maxFps, minFps = 0, 0, 0, math.huge
		local conn = RunService.RenderStepped:Connect(function(dt)
			frames += 1
			acc += dt
			if dt > 0 then
				local fps = 1 / dt
				if fps > maxFps then maxFps = fps end
				if fps < minFps then minFps = fps end
			end
		end)
		local elapsed = 0
		while elapsed < CONFIG.BENCHMARK_DURATION do
			task.wait(0.5)
			elapsed = os.clock() - Bench.startTime
			Bench.avg = (acc > 0) and (frames / acc) or 0
		end
		conn:Disconnect()
		Bench.running = false
		Bench.avg = (acc > 0) and (frames / acc) or 0
		Bench.minFps, Bench.maxFps = minFps, maxFps
		-- Suggest preset based on avg FPS
		local sugIdx
		if Bench.avg >= 100 then sugIdx = 5
		elseif Bench.avg >= 60 then sugIdx = 4
		elseif Bench.avg >= 45 then sugIdx = 3
		elseif Bench.avg >= 30 then sugIdx = 2
		else sugIdx = 1 end
		Bench.result = sugIdx
		notify("FPS BOOSTER", string.format("Benchmark: avg %.0f FPS · recommend %s %s",
			Bench.avg, PRESETS[sugIdx].icon, PRESETS[sugIdx].name), 8)
	end)
end

toggleScreenshotMode = function()
	if State.screenshotMode then return end
	State.screenshotMode = true
	reapplyAll()
	if UI then UI.syncControls(false) end
	notify("FPS BOOSTER", "Screenshot mode — original visuals restored", 2)
	task.delay(CONFIG.SCREENSHOT_PAUSE, function()
		State.screenshotMode = false
		reapplyAll()
		if UI then UI.syncControls(false) end
		notify("FPS BOOSTER", "Screenshot mode ended", 2)
	end)
end

--==================================================================================================
-- 11) USER INTERFACE
--==================================================================================================
local function buildUI()
	local gui = make("ScreenGui", {
		Name = CONFIG.GUI_NAME, ResetOnSpawn = false, DisplayOrder = 1000,
		IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, playerGui)

	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	local TITLE_H = 42
	local width = math.clamp(vp.X - 24, 280, 340)

	local window = make("Frame", {
		Name = "Window", Size = UDim2.fromOffset(width, TITLE_H), Position = UDim2.fromOffset(12, 80),
		BackgroundColor3 = C.bg, BorderSizePixel = 0, ClipsDescendants = true,
	}, gui)
	make("UICorner", { CornerRadius = UDim.new(0, 12) }, window)
	local stroke = make("UIStroke", { Thickness = 1.5, Color = Color3.new(1, 1, 1), Transparency = 0.25 }, window)
	make("UIGradient", { Color = ColorSequence.new(C.green, C.blue), Rotation = 45 }, stroke)

	local titleBar = make("Frame", { Name = "TitleBar", Size = UDim2.new(1, 0, 0, TITLE_H),
		BackgroundColor3 = C.panel, BorderSizePixel = 0 }, window)
	local dot = make("Frame", { Size = UDim2.fromOffset(10, 10), Position = UDim2.new(0, 14, 0.5, -5),
		BackgroundColor3 = C.green, BorderSizePixel = 0 }, titleBar)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
	local titleText = make("TextLabel", {
		BackgroundTransparency = 1, Text = "FPS BOOSTER V3", Font = Enum.Font.GothamBlack, TextSize = 14,
		TextColor3 = C.green, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(32, 0), Size = UDim2.new(1, -112, 1, 0),
	}, titleBar)
	local function titleButton(text, xOffset, color)
		local b = make("TextButton", {
			Text = text, Font = Enum.Font.GothamBold, TextSize = 18, TextColor3 = color or C.text,
			BackgroundColor3 = C.chip, AutoButtonColor = true, BorderSizePixel = 0,
			Size = UDim2.fromOffset(32, 30), Position = UDim2.new(1, xOffset, 0.5, -15),
		}, titleBar)
		make("UICorner", { CornerRadius = UDim.new(0, 8) }, b)
		return b
	end
	local minBtn = titleButton("–", -74)
	local closeBtn = titleButton("×", -38, C.red)

	local body = make("ScrollingFrame", {
		Name = "Body", Position = UDim2.fromOffset(0, TITLE_H), Size = UDim2.new(1, 0, 1, -TITLE_H),
		BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = C.blue,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, window)
	make("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10),
		PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, body)
	local list = make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, body)

	local function card(h, order)
		local f = make("Frame", { Size = UDim2.new(1, 0, 0, h), BackgroundColor3 = C.panel,
			BorderSizePixel = 0, LayoutOrder = order, ClipsDescendants = true }, body)
		make("UICorner", { CornerRadius = UDim.new(0, 8) }, f)
		return f
	end
	local function label(parent, props)
		local l = make("TextLabel", { BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 12,
			TextColor3 = C.text, TextXAlignment = Enum.TextXAlignment.Left }, nil)
		for k, v in pairs(props) do l[k] = v end
		l.Parent = parent
		return l
	end
	local function caption(parent, text)
		return label(parent, { Text = text, TextSize = 10, Font = Enum.Font.GothamBold, TextColor3 = C.dim,
			Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 12) })
	end

	-- Stats row
	local statsRow = make("Frame", { Size = UDim2.new(1, 0, 0, 68), BackgroundTransparency = 1, LayoutOrder = 1 }, body)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder }, statsRow)
	local function statCard(order, cap)
		local f = make("Frame", { Size = UDim2.new(0.5, -4, 1, 0), BackgroundColor3 = C.panel,
			BorderSizePixel = 0, LayoutOrder = order, ClipsDescendants = true }, statsRow)
		make("UICorner", { CornerRadius = UDim.new(0, 8) }, f)
		caption(f, cap)
		local value = label(f, { Text = "--", TextSize = 26, Font = Enum.Font.GothamBlack,
			Position = UDim2.fromOffset(10, 18), Size = UDim2.new(1, -20, 0, 32) })
		local sub = label(f, { Text = "", TextSize = 10, TextColor3 = C.dim, TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(10, 50), Size = UDim2.new(1, -20, 0, 14) })
		return value, sub
	end
	local fpsValue, fpsSub = statCard(1, "FPS")
	local pingValue, pingSub = statCard(2, "PING")

	-- ===== GRAPHICS PRESETS =====
	local presetCard = card(320, 2)
	caption(presetCard, "GRAPHICS PRESET")
	local presetBtns = {}
	for i, p in ipairs(PRESETS) do
		local y = 22 + (i - 1) * 58
		local btn = make("TextButton", {
			Text = "", BackgroundColor3 = C.chip, AutoButtonColor = false, BorderSizePixel = 0,
			Position = UDim2.fromOffset(10, y), Size = UDim2.new(1, -20, 0, 54),
		}, presetCard)
		make("UICorner", { CornerRadius = UDim.new(0, 6) }, btn)
		local iconLbl = label(btn, { Text = p.icon, TextSize = 24, Font = Enum.Font.GothamBlack,
			Position = UDim2.fromOffset(8, 12), Size = UDim2.fromOffset(40, 30) })
		local nameLbl = label(btn, { Text = string.format("%d. %s", i, p.name), Font = Enum.Font.GothamBold,
			TextSize = 13, Position = UDim2.fromOffset(52, 8), Size = UDim2.new(1, -62, 0, 18) })
		local descLbl = label(btn, { Text = p.desc, TextSize = 10, TextColor3 = C.dim,
			Position = UDim2.fromOffset(52, 26), Size = UDim2.new(1, -62, 0, 20) })
		btn.Activated:Connect(function() setPreset(i) end)
		presetBtns[i] = btn
	end

	-- Network
	local netCard = card(94, 3)
	local netLine1 = label(netCard, { Text = "Network: …", Font = Enum.Font.GothamBold, TextSize = 13,
		Position = UDim2.fromOffset(10, 8), Size = UDim2.new(1, -20, 0, 16) })
	local netLine2 = label(netCard, { Text = "", TextSize = 11, TextColor3 = C.dim, TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(10, 26), Size = UDim2.new(1, -20, 0, 42) })
	local netAdvice = label(netCard, { Text = "", TextSize = 10, TextColor3 = C.yellow, TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(10, 68), Size = UDim2.new(1, -20, 0, 22) })

	-- Dashboard
	local ROWS = { "Booster", "Mode", "Profile", "Preset", "Workload", "Device", "Status" }
	local dash = card(14 + #ROWS * 22, 4)
	local rowDots, rowTexts = {}, {}
	for i, name in ipairs(ROWS) do
		local y = 7 + (i - 1) * 22
		local d = make("Frame", { Size = UDim2.fromOffset(8, 8), Position = UDim2.fromOffset(10, y + 7),
			BackgroundColor3 = C.off, BorderSizePixel = 0 }, dash)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, d)
		label(dash, { Text = name, TextColor3 = C.dim, Position = UDim2.fromOffset(26, y), Size = UDim2.fromOffset(62, 22) })
		rowTexts[name] = label(dash, { Text = "", Font = Enum.Font.GothamMedium, TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(90, y), Size = UDim2.new(1, -98, 0, 22) })
		rowDots[name] = d
	end

	-- Why
	local whyCard = card(122, 5)
	caption(whyCard, "WHY THIS PROFILE")
	local whyText = label(whyCard, { Text = "", TextSize = 11, TextColor3 = C.text, TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(10, 22), Size = UDim2.new(1, -20, 0, 96) })

	-- Toggle
	local function makeToggle(order, text, sub, initial, onChange)
		local row = card(sub and 50 or 40, order)
		label(row, { Text = text, Font = Enum.Font.GothamBold, TextSize = 13,
			Position = UDim2.fromOffset(10, sub and 7 or 0), Size = UDim2.new(1, -76, 0, sub and 18 or 40) })
		if sub then
			label(row, { Text = sub, TextSize = 10, TextColor3 = C.dim, TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(10, 26), Size = UDim2.new(1, -76, 0, 22) })
		end
		local trackFrame = make("Frame", { Size = UDim2.fromOffset(48, 26), AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0), BackgroundColor3 = C.off, BorderSizePixel = 0 }, row)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, trackFrame)
		local knob = make("Frame", { Size = UDim2.fromOffset(20, 20), Position = UDim2.fromOffset(3, 3),
			BackgroundColor3 = C.text, BorderSizePixel = 0 }, trackFrame)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)
		local hit = make("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
			ZIndex = 5 }, row)
		local value = initial
		local function set(v, instant)
			value = v
			local pos = v and UDim2.fromOffset(25, 3) or UDim2.fromOffset(3, 3)
			local col = v and C.green or C.off
			if instant then knob.Position, trackFrame.BackgroundColor3 = pos, col
			else tween(knob, 0.18, { Position = pos }); tween(trackFrame, 0.18, { BackgroundColor3 = col }) end
		end
		set(initial, true)
		hit.Activated:Connect(function() onChange(not value) end)
		return set
	end
	local setBoosterToggle = makeToggle(6, "Booster", "Master on/off", State.enabled, function(v) setEnabled(v) end)
	local setAutoToggle = makeToggle(7, "Auto Mode", "Adapt preset to FPS", State.mode == "Auto", function(v)
		if v then setMode("Auto") else setMode("Manual") end
	end)
	local setAutoQualityToggle = makeToggle(8, "Auto Quality", "Drop preset if FPS < 25", State.autoQuality,
		function(v) setAutoQuality(v) end)

	-- Profile selector
	local profCard = card(62, 9)
	caption(profCard, "GAME PROFILE")
	local function arrow(text, xScale, xOff)
		local b = make("TextButton", { Text = text, Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = C.text,
			BackgroundColor3 = C.chip, AutoButtonColor = true, BorderSizePixel = 0,
			Position = UDim2.new(xScale, xOff, 0, 24), Size = UDim2.fromOffset(40, 30) }, profCard)
		make("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
		return b
	end
	local prevBtn, nextBtn = arrow("‹", 0, 10), arrow("›", 1, -50)
	local profLabel = make("TextLabel", { Text = "", Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.green,
		BackgroundColor3 = C.chip, BorderSizePixel = 0, TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.new(0, 54, 0, 24), Size = UDim2.new(1, -108, 0, 30) }, profCard)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, profLabel)
	prevBtn.Activated:Connect(function() cycleProfile(-1) end)
	nextBtn.Activated:Connect(function() cycleProfile(1) end)

	-- IFrame toggle
	local setIFrameToggle = makeToggle(10, "IFrame overlays", "Hide tagged visual overlays", false,
		function(v) setIFrame(v) end)

	-- Actions
	local actionRow = make("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, LayoutOrder = 11 }, body)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder }, actionRow)
	local function actionBtn(order, text, color, onActivate)
		local b = make("TextButton", {
			Text = text, Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = color,
			BackgroundColor3 = C.panel, AutoButtonColor = false, BorderSizePixel = 0,
			Size = UDim2.new(0.5, -3, 1, 0), LayoutOrder = order,
		}, actionRow)
		make("UICorner", { CornerRadius = UDim.new(0, 8) }, b)
		make("UIStroke", { Color = color, Thickness = 1, Transparency = 0.3 }, b)
		b.Activated:Connect(function()
			b.BackgroundColor3 = color
			tween(b, 0.3, { BackgroundColor3 = C.panel })
			onActivate()
		end)
		return b
	end
	actionBtn(1, "📸 SCREENSHOT", C.purple, function() toggleScreenshotMode() end)
	actionBtn(2, "⏱ BENCHMARK", C.yellow, function() runBenchmark() end)

	-- Restore
	local restoreBtn = make("TextButton", {
		Text = "RESTORE ORIGINALS", Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.blue,
		BackgroundColor3 = C.panel, AutoButtonColor = false, BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 42), LayoutOrder = 12,
	}, body)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, restoreBtn)
	make("UIStroke", { Color = C.blue, Thickness = 1.2, Transparency = 0.2 }, restoreBtn)
	restoreBtn.Activated:Connect(function()
		restoreBtn.BackgroundColor3, restoreBtn.TextColor3 = C.blue, C.dark
		tween(restoreBtn, 0.35, { BackgroundColor3 = C.panel, TextColor3 = C.blue })
		restoreAll()
	end)

	label(body, { Text = "Hotkeys: F1=toggle · F2=screenshot · F3=cycle preset · F4=benchmark",
		TextSize = 10, TextColor3 = C.dim, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 13 })

	-- Minimize / resize
	local minimized = false
	local function fullHeight()
		local maxBody = math.max(120, gui.AbsoluteSize.Y - 110)
		return TITLE_H + math.min(list.AbsoluteContentSize.Y + 20, maxBody)
	end
	local function resize()
		local h = minimized and TITLE_H or fullHeight()
		tween(window, 0.25, { Size = UDim2.fromOffset(width, h) })
		minBtn.Text = minimized and "+" or "–"
	end
	minBtn.Activated:Connect(function() minimized = not minimized; resize() end)
	list:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(resize)
	track(gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize))

	local armed = false
	closeBtn.Activated:Connect(function()
		if armed then closeAll() return end
		armed = true
		closeBtn.Text, closeBtn.BackgroundColor3 = "?", C.red
		task.delay(3, function()
			if armed and closeBtn.Parent then
				armed = false
				closeBtn.Text, closeBtn.BackgroundColor3 = "×", C.chip
			end
		end)
	end)

	local dragging, dragInput, dragStart, startPos = false, nil, nil, nil
	titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, input.Position, window.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	titleBar.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			dragInput = input
		end
	end)
	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and input == dragInput then
			local delta = input.Position - dragStart
			local size = gui.AbsoluteSize
			window.Position = UDim2.fromOffset(
				math.clamp(startPos.X.Offset + delta.X, 0, math.max(0, size.X - width)),
				math.clamp(startPos.Y.Offset + delta.Y, 0, math.max(0, size.Y - TITLE_H)))
		end
	end))

	-- Public API
	local api = { gui = gui }

	function api.syncControls(instant)
		setBoosterToggle(State.enabled, instant)
		setAutoToggle(State.mode == "Auto", instant)
		setAutoQualityToggle(State.autoQuality, instant)
		setIFrameToggle(IFrame.enabled, instant)
		for i, btn in ipairs(presetBtns) do
			local active = (i == Active.presetIdx)
			local p = PRESETS[i]
			local bg = active and p.color or C.chip
			local fg = active and C.dark or C.text
			if instant then
				btn.BackgroundColor3 = bg
			else
				tween(btn, 0.18, { BackgroundColor3 = bg })
			end
			for _, child in ipairs(btn:GetChildren()) do
				if child:IsA("TextLabel") and child ~= btn then
					if child.Font == Enum.Font.GothamBold then
						child.TextColor3 = fg
					end
				end
			end
		end
	end

	local function setRow(name, text, color)
		setText(rowTexts[name], text)
		rowDots[name].BackgroundColor3 = color
	end

	function api.update()
		local fpsInt = math.floor(Perf.fps + 0.5)
		if minimized then
			setText(titleText, (Perf.fps > 0 and ("V3 · " .. fpsInt .. " FPS") or "V3")
				.. (Net.ping and (" · " .. math.floor((smoothPing() or Net.ping) + 0.5) .. " ms") or ""))
			return
		end
		setText(titleText, "FPS BOOSTER V3")

		local ratio = (Perf.fps > 0) and (Perf.fps / targetFps()) or 1
		local fpsColor = (ratio >= 0.93) and C.green or ((ratio >= 0.6) and C.yellow or C.red)
		setText(fpsValue, (Perf.fps > 0) and tostring(fpsInt) or "--")
		fpsValue.TextColor3 = (Perf.fps > 0) and fpsColor or C.dim
		setText(fpsSub, (Perf.fps > 0)
			and string.format("%.1f ms · %d hitches", Perf.frameMs, Perf.hitchShown) or "measuring…")

		local smoothed = smoothPing()
		if smoothed then
			setText(pingValue, math.floor(smoothed + 0.5) .. " ms")
			pingValue.TextColor3 = (smoothed < 80) and C.green or ((smoothed < 160) and C.yellow or C.red)
			setText(pingSub, Net.source)
		else
			setText(pingValue, "N/A"); pingValue.TextColor3 = C.dim; setText(pingSub, "not readable")
		end

		local nColor = ({ Excellent = C.green, Good = C.green, Fair = C.yellow, Poor = C.red,
			Unstable = C.red, Unavailable = C.dim })[Net.status] or C.dim
		setText(netLine1, "Connection · " .. Net.status .. " · " .. NetOpt.region)
		netLine1.TextColor3 = nColor
		if Net.ping then
			setText(netLine2, string.format("RTT %d · jitter %d · peak %d\nPerceived %.0f ms (%s)",
				math.floor(NetDiag.serverRTT + 0.5), math.floor(Net.jitter + 0.5),
				math.floor(Net.peak + 0.5), NetDiag.perceived, NetDiag.netHealth))
		else
			setText(netLine2, "Ping unavailable on this client.")
		end
		setText(netAdvice, NetDiag.advice)

		if not ready then setRow("Booster", StatusText, C.yellow)
		elseif not State.enabled then setRow("Booster", "Off · restored", C.off)
		elseif State.screenshotMode then setRow("Booster", "Screenshot mode", C.purple)
		else setRow("Booster", "Enabled", C.green) end
		setRow("Mode", MODE_NAMES[State.mode], (State.mode == "Auto") and C.blue or C.green)
		local prof = PROFILES[Active.profile]
		local manual = (State.profileChoice ~= "Auto")
		setRow("Profile", prof.tag .. " · " .. prof.display .. (manual and " (manual)" or ""), C.green)
		local preset = PRESETS[Active.presetIdx]
		setRow("Preset", preset.icon .. " " .. preset.name, preset.color)
		local wl = Detect.workload
		setRow("Workload", string.format("%s · %d FX", wl, Metrics.active + Metrics.trails + Metrics.beams),
			(wl == "Light" or wl == "Unknown") and C.green or ((wl == "Moderate") and C.yellow or C.red))
		local pl, pc = perfLabel()
		setRow("Device", platformName .. " · " .. pl .. (Perf.memMb and (" · " .. math.floor(Perf.memMb) .. "MB") or ""), pc)
		if Bench.running then setRow("Status", string.format("Benchmarking… %.0f FPS", Bench.avg), C.yellow)
		elseif not ready then setRow("Status", StatusText, C.yellow)
		elseif not State.enabled then setRow("Status", "Restored", C.blue)
		else setRow("Status", string.format("%d/%d FX adjusted", Counts.adjusted, Counts.tracked), C.green) end

		local whyLine = manual and "Profile chosen manually." or Detect.reason
		local mapLine = "Map: " .. (MapInfo.placeName ~= "" and MapInfo.placeName or ("PlaceId " .. MapInfo.placeId))
			.. string.format(" · %d players · %d parts", MapInfo.playerCount, MapInfo.partCount)
		local benchLine = ""
		if Bench.result then
			local bs = PRESETS[Bench.result]
			benchLine = string.format("\nBenchmark: %.0f FPS avg → %s %s", Bench.avg, bs.icon, bs.name)
		end
		setText(whyText, whyLine .. "\n" .. mapLine .. benchLine .. "\n" .. Auto.bottleneck)

		local choice = State.profileChoice
		setText(profLabel, (choice == "Auto") and ("Auto → " .. PROFILES[Detect.profile].tag .. " · " .. PROFILES[Detect.profile].display)
			or (PROFILES[choice].tag .. " · " .. PROFILES[choice].display))
	end

	window.BackgroundTransparency = 1
	tween(window, 0.35, { BackgroundTransparency = 0 })
	api.syncControls(true)
	RunService.Heartbeat:Wait()
	resize()
	return api
end

--==================================================================================================
-- 12) CONTROLS
--==================================================================================================
setEnabled = function(v)
	State.enabled = v and true or false
	Auto.low, Auto.high, Auto.pending = 0, 0, nil
	refresh(true)
end

setMode = function(m)
	if State.mode == m then return end
	if m == "Auto" then
		Auto.presetIdx = suggestPreset(Detect.profile)
		Auto.low, Auto.high, Auto.pending = 0, 0, nil
		Auto.floorUntil, Auto.noRaiseUntil, Auto.lastChange = 0, 0, os.clock()
	end
	State.mode = m
	refresh()
end

setPreset = function(idx)
	if idx < 1 or idx > #PRESETS then return end
	State.presetId = PRESETS[idx].id
	State.mode = "Manual"
	refresh()
end

cyclePreset = function()
	local cur = Active.presetIdx
	local next_ = (cur % #PRESETS) + 1
	setPreset(next_)
end

cycleProfile = function(dir)
	local idx = table.find(PROFILE_CHOICES, State.profileChoice) or 1
	idx = ((idx - 1 + dir) % #PROFILE_CHOICES) + 1
	State.profileChoice = PROFILE_CHOICES[idx]
	refresh()
end

setAutoQuality = function(v)
	State.autoQuality = v and true or false
	if UI then UI.syncControls(false) end
end

restoreAll = function()
	State.enabled = false
	Auto.pending = nil
	refresh(true)
end

--==================================================================================================
-- 13) SHUTDOWN + INIT
--==================================================================================================
local function destroy()
	if not running then return end
	running = false
	generation += 1
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	table.clear(conns)
	for _, c in ipairs(IFrame.conns) do pcall(function() c:Disconnect() end) end
	table.clear(IFrame.conns)

	State.enabled = false
	State.screenshotMode = false
	local all = {}
	for inst in pairs(records) do all[#all + 1] = inst end
	for _, inst in ipairs(all) do pcall(processAny, inst) end

	pcall(restoreNetworkOpt)
	if UI and UI.gui then UI.gui:Destroy() end
	if _G.__FPSBooster and _G.__FPSBooster.Destroy == destroy then _G.__FPSBooster = nil end
end
closeAll = destroy
_G.__FPSBooster = { Destroy = destroy }

local function setupHotkeys()
	if not CONFIG.HOTKEYS_ENABLED then return end
	track(UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.F1 then
			setEnabled(not State.enabled)
		elseif input.KeyCode == Enum.KeyCode.F2 then
			toggleScreenshotMode()
		elseif input.KeyCode == Enum.KeyCode.F3 then
			cyclePreset()
		elseif input.KeyCode == Enum.KeyCode.F4 then
			runBenchmark()
		end
	end))
end

local function startMonitor()
	task.spawn(function()
		local tick = 0
		while running do
			task.wait(0.5)
			if not running then break end
			tick += 1
			local now = os.clock()

			if Perf.frames > 0 and Perf.acc > 0 then
				local instFps = Perf.frames / Perf.acc
				Perf.fps = (Perf.fps == 0) and instFps or (Perf.fps * 0.4 + instFps * 0.6)
				Perf.frameMs = (Perf.acc / Perf.frames) * 1000
				Perf.worstMs = Perf.maxDt * 1000
				Perf.frames, Perf.acc, Perf.maxDt = 0, 0, 0
			end
			if now - startTime > 5 and Perf.fps > Auto.peak then Auto.peak = Perf.fps end

			if tick % 2 == 0 then
				pcall(sampleNetwork)
				if Perf.fps > 5 and Perf.fps < targetFps() * 0.7 then Auto.lowSecs += 1 else Auto.lowSecs = 0 end
				pcall(autoStep, now)
			end
			if tick % 4 == 0 then
				pcall(runNetworkDiagnostics)
				pcall(updateCounts)
			end
			if tick % 20 == 0 then
				Perf.hitchShown, Perf.hitches = Perf.hitches, 0
				pcall(function() Perf.memMb = Stats:GetTotalMemoryUsageMb() end)
			end
			if tick % CONFIG.MAP_SCAN_INTERVAL == 0 then
				task.spawn(function() pcall(scanMapInfo) end)
			end
			if tick % 30 == 3 then
				task.spawn(function()
					pcall(updateMetrics)
					local ok, switched = pcall(runDetection, false, now)
					if ok and switched then refresh() end
				end)
			end
			pcall(UI.update)
		end
	end)
end

local function init()
	track(workspace.DescendantAdded:Connect(onDescendantAdded))
	track(Lighting.DescendantAdded:Connect(onDescendantAdded))
	track(RunService.Heartbeat:Connect(function()
		if not ready or #pending == 0 then return end
		local n = 0
		while #pending > 0 and n < 50 do
			local inst = table.remove(pending)
			pcall(function() register(inst); processInstance(inst) end)
			n += 1
		end
	end))

	local _frames, _acc, _maxDt, _hitches = 0, 0, 0, 0
	track(RunService.RenderStepped:Connect(function(dt)
		_frames += 1
		_acc += dt
		if dt > _maxDt then _maxDt = dt end
		if dt > 0.05 then _hitches += 1 end
		Perf.frames, Perf.acc, Perf.maxDt, Perf.hitches = _frames, _acc, _maxDt, _hitches
	end))

	setupHotkeys()
	UI = buildUI()
	pcall(applyNetworkOpt)

	scanRoot(Lighting)
	scanRoot(workspace)
	finishScene()
	updateMetrics()
	updateCounts()

	task.spawn(function()
		RunService.Heartbeat:Wait()
		RunService.Heartbeat:Wait()
		pcall(scanMapInfo)
	end)
	local waited = 0
	while MapInfo.detectedAt == 0 and waited < 30 do
		task.wait(0.1)
		waited += 1
	end

	runDetection(true, os.clock())
	Active.presetId, Active.presetIdx, Active.profile = resolveActive()
	updateCur()

	generation += 1
	runPass(generation)
	ready = true
	updateCounts()
	StatusText = "Optimized"
	UI.syncControls(false)
	startMonitor()
end

local ok, err = pcall(init)
if ok then
	task.spawn(function()
		notify("FPS BOOSTER V3", "Ready! 5 graphics presets available.", 4)
		notify("FPS BOOSTER V3", string.format("%s %s · Profile: %s",
			PRESETS[Active.presetIdx].icon, PRESETS[Active.presetIdx].name,
			PROFILES[Active.profile].display), 5)
	end)
else
	warn("[FPSBoosterV3] Init failed: " .. tostring(err))
	pcall(destroy)
	task.spawn(notify, "FPS BOOSTER V3", "Init failed: " .. string.sub(tostring(err), 1, 120), 8)
end
