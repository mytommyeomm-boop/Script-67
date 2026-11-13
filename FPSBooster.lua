--[[
	ROBLOX FPS & NETWORK OPTIMIZER  (LocalScript)

	INSTALL
	  1. Open your experience in Roblox Studio.
	  2. Explorer > StarterPlayer > StarterPlayerScripts
	  3. Right-click StarterPlayerScripts > Insert Object > LocalScript
	  4. Name it "FPSBooster" and paste this whole file in. Press Play.

	WHAT IT DOES
	  - Reduces VFX intensity (never deletes / disables anything)
	  - Restores originals on request (values are saved before any change)
	  - Auto mode adapts the reduction level to measured FPS
	  - Shows FPS, ping (measured, not "improved") and network diagnostics

	WHAT IT NEVER TOUCHES
	  - Render distance, fog, Atmosphere, terrain, StreamingMinRadius /
	    StreamingTargetRadius, RemoteEvents / RemoteFunctions, gameplay objects.
]]

--// Services ------------------------------------------------------------------
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService       = game:GetService("GuiService")
local StarterGui       = game:GetService("StarterGui")
local Stats            = game:GetService("Stats")
local Lighting         = game:GetService("Lighting")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--// Singleton guard (prevents duplicate GUIs / duplicate optimizers) ------------
local GUI_NAME = "FPSBoosterUI"
do
	local previous = _G.__FPSBooster
	if type(previous) == "table" and type(previous.Destroy) == "function" then
		pcall(previous.Destroy)
	end
	local stale = playerGui:FindFirstChild(GUI_NAME)
	if stale then stale:Destroy() end
end

--// Lifecycle bookkeeping -------------------------------------------------------
local running = true
local conns = {}
local function track(conn)
	conns[#conns + 1] = conn
	return conn
end

local startTime = os.clock()

--// Device -----------------------------------------------------------------------
local function detectDevice()
	if GuiService:IsTenFootInterface() then return "Console" end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then return "Mobile" end
	return "PC"
end
local deviceType = detectDevice()

--// State --------------------------------------------------------------------------
local State = {
	enabled = true,
	auto    = true,
	level   = (deviceType == "Mobile") and 2 or 1,
}

-- VFX reduction levels. Every multiplier keeps effects visible (floors are
-- applied below, nothing is ever set to 0 / disabled / destroyed).
local LEVELS = {
	[1] = { name = "Light",    rate = 0.80, post = 0.85, trail = 0.85, beam = 0.85, lightShadows = false },
	[2] = { name = "Balanced", rate = 0.60, post = 0.70, trail = 0.70, beam = 0.70, lightShadows = false },
	[3] = { name = "Strong",   rate = 0.40, post = 0.55, trail = 0.55, beam = 0.55, lightShadows = true  },
}

--// Colors ---------------------------------------------------------------------------
local C = {
	bg     = Color3.fromRGB(12, 14, 20),
	panel  = Color3.fromRGB(21, 25, 35),
	chip   = Color3.fromRGB(32, 38, 52),
	off    = Color3.fromRGB(52, 60, 78),
	green  = Color3.fromRGB(0, 255, 136),
	blue   = Color3.fromRGB(0, 170, 255),
	text   = Color3.fromRGB(232, 240, 255),
	dim    = Color3.fromRGB(130, 146, 168),
	yellow = Color3.fromRGB(255, 200, 60),
	red    = Color3.fromRGB(255, 77, 96),
	dark   = Color3.fromRGB(8, 10, 14),
}

--// Small helpers ------------------------------------------------------------------------
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

local function sameValue(a, b)
	if type(a) == "number" and type(b) == "number" then
		return math.abs(a - b) <= 0.001 * math.max(1, math.abs(a))
	end
	return a == b
end

local function notify(title, text, duration)
	for _ = 1, 10 do
		local ok = pcall(function()
			StarterGui:SetCore("SendNotification", { Title = title, Text = text, Duration = duration or 5 })
		end)
		if ok then return true end
		task.wait(0.5) -- SetCore may not be registered yet
	end
	return false
end

--==============================================================================
-- 1) VFX OPTIMIZATION ENGINE
--==============================================================================
-- records[instance][property] = { orig = <saved original>, applied = <value we set> }
-- Weak keys: destroyed instances are garbage collected, no leaks.
local records = setmetatable({}, { __mode = "k" })
local tracked = setmetatable({}, { __mode = "k" })

local function scaleFloor(orig, mult, floorValue)
	local v = orig * mult
	local f = math.min(orig, floorValue) -- never push above the original
	if v < f then v = f end
	return v
end

-- Property handlers per class: { propertyName, function(original, levelConfig) -> newValue }
local HANDLERS = {
	ParticleEmitter = {
		{ "Rate", function(o, c)
			if o <= 0 then return o end -- burst-only emitters (Emit()) stay untouched
			return math.min(o, math.max(1, round2(o * c.rate)))
		end },
	},
	Trail = {
		{ "Lifetime", function(o, c) return scaleFloor(o, c.trail, 0.15) end },
	},
	Beam = {
		{ "Segments", function(o, c)
			if o <= 3 then return o end
			return math.max(3, math.floor(o * c.beam + 0.5))
		end },
	},
	BloomEffect = {
		{ "Intensity", function(o, c) return scaleFloor(o, c.post, 0.05) end },
	},
	BlurEffect = {
		{ "Size", function(o, c) return scaleFloor(o, c.post, 1) end },
	},
	SunRaysEffect = {
		{ "Intensity", function(o, c) return scaleFloor(o, c.post, 0.02) end },
	},
	DepthOfFieldEffect = {
		{ "FarIntensity",  function(o, c) return scaleFloor(o, c.post, 0.02) end },
		{ "NearIntensity", function(o, c) return scaleFloor(o, c.post, 0.02) end },
	},
}
-- Shadow-casting lights are expensive; only the "Strong" level turns the SHADOW off
-- (the light itself stays enabled and visible).
local lightHandler = {
	{ "Shadows", function(o, c) if c.lightShadows then return false end return o end },
}
HANDLERS.PointLight   = lightHandler
HANDLERS.SpotLight    = lightHandler
HANDLERS.SurfaceLight = lightHandler

-- Apply (cfg != nil) or restore (cfg == nil) one property. Skips redundant writes.
local function applyProp(inst, rec, prop, fn, cfg)
	local okRead, cur = pcall(function() return inst[prop] end)
	if not okRead then return end

	local entry = rec[prop]
	if not entry then
		if not cfg then return end
		entry = { orig = cur, applied = cur }
		rec[prop] = entry
	elseif not sameValue(cur, entry.applied) then
		-- The game changed this property itself: adopt its value as the new original.
		entry.orig, entry.applied = cur, cur
	end

	local target = entry.orig
	if cfg then target = fn(entry.orig, cfg) end
	if sameValue(target, cur) then return end

	if pcall(function() inst[prop] = target end) then
		local okNow, now = pcall(function() return inst[prop] end)
		entry.applied = okNow and now or target
	end
end

local function processInstance(inst)
	local handlers = HANDLERS[inst.ClassName]
	if not handlers then return end

	local cfg = State.enabled and LEVELS[State.level] or nil
	local rec = records[inst]
	if not cfg and not rec then return end
	if not rec then rec = {}; records[inst] = rec end

	for _, h in ipairs(handlers) do
		applyProp(inst, rec, h[1], h[2], cfg)
	end
	if not cfg then records[inst] = nil end -- fully restored
end

-- Re-process everything in small slices so a level change never hitches a frame.
local generation = 0
local function reapplyAll()
	generation += 1
	local gen = generation
	task.spawn(function()
		local list = {}
		for inst in pairs(tracked) do list[#list + 1] = inst end
		for i, inst in ipairs(list) do
			if gen ~= generation or not running then return end
			pcall(processInstance, inst)
			if i % 150 == 0 then task.wait() end
		end
	end)
end

-- New effects (streamed in, spawned by abilities, etc.) go through a small queue.
local pending = {}
local function onDescendantAdded(inst)
	if HANDLERS[inst.ClassName] then
		tracked[inst] = true
		pending[#pending + 1] = inst
	end
end

local function scan(root)
	local n = 0
	for _, d in ipairs(root:GetDescendants()) do
		if HANDLERS[d.ClassName] then
			tracked[d] = true
			pcall(processInstance, d)
		end
		n += 1
		if n % 500 == 0 then task.wait() end
	end
end

--==============================================================================
-- 2) PERFORMANCE + NETWORK MONITORING
--==============================================================================
local Perf = { fps = 0, frameMs = 0, worstMs = 0, frames = 0, acc = 0, maxDt = 0 }
local Auto = { low = 0, high = 0, lastChange = 0, lastDown = nil, floorLevel = 1, floorUntil = 0, peak = 0 }
local Net  = { samples = {}, ping = nil, source = "", jitter = 0, peak = 0, mean = 0,
               status = "Unavailable", recv = nil, send = nil }
local Counts = { tracked = 0, adjusted = 0 }

local function readPing()
	-- Same value Roblox shows in its performance stats (round-trip, ms).
	local ok, v = pcall(function() return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() end)
	if ok and type(v) == "number" and v > 0 then return v, "Data Ping" end
	-- Fallback: official Player API (seconds).
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
		Net.mean = sum / #s
		Net.peak = peak
		Net.jitter = (#s > 1) and (deltaSum / (#s - 1)) or 0

		if #s >= 5 and (Net.jitter > 40 or Net.peak > math.max(250, Net.mean * 3)) then
			Net.status = "Unstable"
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

--==============================================================================
-- 3) USER INTERFACE
--==============================================================================
local UI = nil -- filled by buildUI()

local function setLevel(level, fromAuto) end -- forward declarations
local function setEnabled(v) end
local function setAuto(v) end
local function restoreAll() end

local function buildUI()
	local gui = make("ScreenGui", {
		Name = GUI_NAME, ResetOnSpawn = false, DisplayOrder = 1000,
		IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, playerGui)

	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	local TITLE_H = 40
	local width = math.clamp(vp.X - 24, 240, 310)

	local window = make("Frame", {
		Name = "Window", Size = UDim2.fromOffset(width, TITLE_H),
		Position = UDim2.fromOffset(12, 80), BackgroundColor3 = C.bg,
		BorderSizePixel = 0, ClipsDescendants = true,
	}, gui)
	make("UICorner", { CornerRadius = UDim.new(0, 12) }, window)
	local stroke = make("UIStroke", { Thickness = 1.5, Color = Color3.new(1, 1, 1), Transparency = 0.25 }, window)
	make("UIGradient", {
		Color = ColorSequence.new(C.green, C.blue), Rotation = 45,
	}, stroke)

	-- Title bar -----------------------------------------------------------------------
	local titleBar = make("Frame", {
		Name = "TitleBar", Size = UDim2.new(1, 0, 0, TITLE_H),
		BackgroundColor3 = C.panel, BorderSizePixel = 0,
	}, window)
	local dot = make("Frame", {
		Size = UDim2.fromOffset(10, 10), Position = UDim2.new(0, 14, 0.5, -5),
		BackgroundColor3 = C.green, BorderSizePixel = 0,
	}, titleBar)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
	make("TextLabel", {
		BackgroundTransparency = 1, Text = "FPS BOOSTER", Font = Enum.Font.GothamBlack,
		TextSize = 15, TextColor3 = C.green, TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(32, 0), Size = UDim2.new(1, -140, 1, 0),
	}, titleBar)
	local miniFps = make("TextLabel", {
		BackgroundTransparency = 1, Text = "", Font = Enum.Font.GothamBold, TextSize = 13,
		TextColor3 = C.blue, TextXAlignment = Enum.TextXAlignment.Right, Visible = false,
		Position = UDim2.new(1, -118, 0, 0), Size = UDim2.new(0, 76, 1, 0),
	}, titleBar)
	local minBtn = make("TextButton", {
		Text = "–", Font = Enum.Font.GothamBold, TextSize = 20, TextColor3 = C.text,
		BackgroundColor3 = C.chip, AutoButtonColor = true, BorderSizePixel = 0,
		Size = UDim2.fromOffset(30, 28), Position = UDim2.new(1, -38, 0.5, -14),
	}, titleBar)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, minBtn)

	-- Scrollable body (keeps the window usable on small phone screens) ----------------
	local body = make("ScrollingFrame", {
		Name = "Body", Position = UDim2.fromOffset(0, TITLE_H), Size = UDim2.new(1, 0, 1, -TITLE_H),
		BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
		ScrollBarImageColor3 = C.blue, CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
	}, window)
	make("UIPadding", {
		PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10),
		PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
	}, body)
	local list = make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, body)

	local function card(h, order, parent)
		local f = make("Frame", {
			Size = UDim2.new(1, 0, 0, h), BackgroundColor3 = C.panel,
			BorderSizePixel = 0, LayoutOrder = order,
		}, parent or body)
		make("UICorner", { CornerRadius = UDim.new(0, 8) }, f)
		return f
	end
	local function label(parent, props)
		local l = make("TextLabel", {
			BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 12,
			TextColor3 = C.text, TextXAlignment = Enum.TextXAlignment.Left,
		}, nil)
		for k, v in pairs(props) do l[k] = v end
		l.Parent = parent
		return l
	end

	-- FPS / Ping cards --------------------------------------------------------------------
	local statsRow = make("Frame", {
		Size = UDim2.new(1, 0, 0, 68), BackgroundTransparency = 1, LayoutOrder = 1,
	}, body)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, statsRow)

	local function statCard(order, caption)
		local f = make("Frame", {
			Size = UDim2.new(0.5, -4, 1, 0), BackgroundColor3 = C.panel,
			BorderSizePixel = 0, LayoutOrder = order,
		}, statsRow)
		make("UICorner", { CornerRadius = UDim.new(0, 8) }, f)
		label(f, { Text = caption, TextSize = 10, Font = Enum.Font.GothamBold, TextColor3 = C.dim,
			Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 12) })
		local value = label(f, { Text = "--", TextSize = 26, Font = Enum.Font.GothamBlack,
			Position = UDim2.fromOffset(10, 18), Size = UDim2.new(1, -20, 0, 32) })
		local sub = label(f, { Text = "", TextSize = 10, TextColor3 = C.dim,
			Position = UDim2.fromOffset(10, 50), Size = UDim2.new(1, -20, 0, 14) })
		return value, sub
	end
	local fpsValue, fpsSub = statCard(1, "FPS")
	local pingValue, pingSub = statCard(2, "PING (MEASURED)")

	-- Network diagnostics card --------------------------------------------------------------
	local netCard = card(60, 2)
	local netLine1 = label(netCard, { Text = "Network: …", Font = Enum.Font.GothamBold, TextSize = 13,
		Position = UDim2.fromOffset(10, 8), Size = UDim2.new(1, -20, 0, 16) })
	local netLine2 = label(netCard, { Text = "", TextSize = 11, TextColor3 = C.dim, TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(10, 27), Size = UDim2.new(1, -20, 0, 28) })

	-- Status card -------------------------------------------------------------------------------
	local statusCard = card(84, 3)
	local function statusRow(i, name)
		local y = 8 + (i - 1) * 24
		local d = make("Frame", {
			Size = UDim2.fromOffset(8, 8), Position = UDim2.fromOffset(10, y + 8),
			BackgroundColor3 = C.off, BorderSizePixel = 0,
		}, statusCard)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, d)
		label(statusCard, { Text = name, TextColor3 = C.dim, Position = UDim2.fromOffset(26, y), Size = UDim2.fromOffset(80, 24) })
		local v = label(statusCard, { Text = "", Font = Enum.Font.GothamMedium, TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(106, y), Size = UDim2.new(1, -114, 0, 24) })
		return d, v
	end
	local optDot, optText = statusRow(1, "Optimization")
	local vfxDot, vfxText = statusRow(2, "VFX")
	local devDot, devText = statusRow(3, "Device")

	-- Toggles ----------------------------------------------------------------------------------------
	local function makeToggle(order, text, initial, onChange)
		local row = card(36, order)
		label(row, { Text = text, Font = Enum.Font.GothamBold, TextSize = 13,
			Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -70, 1, 0) })
		local trackBtn = make("TextButton", {
			Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(44, 22),
			Position = UDim2.new(1, -54, 0.5, -11), BackgroundColor3 = C.off, BorderSizePixel = 0,
		}, row)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, trackBtn)
		local knob = make("Frame", {
			Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(3, 3),
			BackgroundColor3 = C.text, BorderSizePixel = 0,
		}, trackBtn)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)

		local value = initial
		local function set(v, instant)
			value = v
			local pos = v and UDim2.fromOffset(25, 3) or UDim2.fromOffset(3, 3)
			local col = v and C.green or C.off
			if instant then
				knob.Position, trackBtn.BackgroundColor3 = pos, col
			else
				tween(knob, 0.18, { Position = pos })
				tween(trackBtn, 0.18, { BackgroundColor3 = col })
			end
		end
		set(initial, true)
		trackBtn.Activated:Connect(function() onChange(not value) end)
		return set
	end
	local setOptToggle  = makeToggle(4, "Optimization", State.enabled, function(v) setEnabled(v) end)
	local setAutoToggle = makeToggle(5, "Auto-optimize", State.auto,   function(v) setAuto(v) end)

	-- VFX level selector -----------------------------------------------------------------------------------
	local levelCard = card(58, 6)
	label(levelCard, { Text = "VFX REDUCTION LEVEL", TextSize = 10, Font = Enum.Font.GothamBold, TextColor3 = C.dim,
		Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 12) })
	local levelRow = make("Frame", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 24), Size = UDim2.new(1, -20, 0, 28),
	}, levelCard)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
	}, levelRow)
	local levelButtons = {}
	for i = 1, 3 do
		local b = make("TextButton", {
			Text = LEVELS[i].name:upper(), Font = Enum.Font.GothamBold, TextSize = 11,
			TextColor3 = C.dim, BackgroundColor3 = C.chip, AutoButtonColor = false,
			BorderSizePixel = 0, LayoutOrder = i, Size = UDim2.new(1 / 3, -4, 1, 0),
		}, levelRow)
		make("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
		b.Activated:Connect(function() setLevel(i, false) end)
		levelButtons[i] = b
	end

	-- Restore button -----------------------------------------------------------------------------------------------
	local restoreBtn = make("TextButton", {
		Text = "RESTORE ORIGINAL SETTINGS", Font = Enum.Font.GothamBold, TextSize = 12,
		TextColor3 = C.blue, BackgroundColor3 = C.panel, AutoButtonColor = false,
		BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 38), LayoutOrder = 7,
	}, body)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, restoreBtn)
	make("UIStroke", { Color = C.blue, Thickness = 1.2, Transparency = 0.2 }, restoreBtn)
	restoreBtn.Activated:Connect(function()
		restoreBtn.BackgroundColor3 = C.blue
		restoreBtn.TextColor3 = C.dark
		tween(restoreBtn, 0.35, { BackgroundColor3 = C.panel, TextColor3 = C.blue })
		restoreAll()
	end)

	label(body, {
		Text = "Render distance, fog & streaming are never modified. Ping is measured only; this script cannot lower server latency.",
		TextSize = 10, TextColor3 = C.dim, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, 0, 0, 40), LayoutOrder = 8,
	})

	-- Window sizing / minimize -------------------------------------------------------------------------------------------
	local minimized = false
	local function fullHeight()
		local maxBody = math.max(120, gui.AbsoluteSize.Y - 110)
		return TITLE_H + math.min(list.AbsoluteContentSize.Y + 20, maxBody)
	end
	local function resize(animate)
		local h = minimized and TITLE_H or fullHeight()
		local size = UDim2.fromOffset(width, h)
		if animate == false then window.Size = size else tween(window, 0.25, { Size = size }) end
		minBtn.Text = minimized and "+" or "–"
		miniFps.Visible = minimized
	end
	minBtn.Activated:Connect(function()
		minimized = not minimized
		resize(true)
	end)
	list:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function() resize(true) end)
	track(gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() resize(true) end))

	-- Dragging (mouse + touch) ----------------------------------------------------------------------------------------------------
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
			local x = math.clamp(startPos.X.Offset + delta.X, 0, math.max(0, size.X - width))
			local y = math.clamp(startPos.Y.Offset + delta.Y, 0, math.max(0, size.Y - TITLE_H))
			window.Position = UDim2.fromOffset(x, y)
		end
	end))

	-- Public UI API ---------------------------------------------------------------------------------------------------------------------------
	local api = {}

	function api.syncControls(instant)
		setOptToggle(State.enabled, instant)
		setAutoToggle(State.auto, instant)
		for i, b in ipairs(levelButtons) do
			local active = (i == State.level)
			local bg = active and C.green or C.chip
			local fg = active and C.dark or C.dim
			if instant then
				b.BackgroundColor3, b.TextColor3 = bg, fg
			else
				tween(b, 0.18, { BackgroundColor3 = bg, TextColor3 = fg })
			end
		end
	end

	function api.update()
		-- Always keep the minimized FPS readout fresh (it is the only thing visible then).
		local fpsText = (Perf.fps > 0) and (tostring(math.floor(Perf.fps + 0.5)) .. " FPS") or "-- FPS"
		miniFps.Text = fpsText
		if minimized then return end

		local ratio = (Perf.fps > 0) and (Perf.fps / targetFps()) or 1
		local fpsColor = (ratio >= 0.93) and C.green or ((ratio >= 0.6) and C.yellow or C.red)
		fpsValue.Text = (Perf.fps > 0) and tostring(math.floor(Perf.fps + 0.5)) or "--"
		fpsValue.TextColor3 = (Perf.fps > 0) and fpsColor or C.dim
		fpsSub.Text = (Perf.fps > 0) and string.format("%.1f ms · worst %.0f ms", Perf.frameMs, Perf.worstMs) or "measuring…"

		if Net.ping then
			pingValue.Text = string.format("%d ms", math.floor(Net.ping + 0.5))
			pingValue.TextColor3 = (Net.ping < 80) and C.green or ((Net.ping < 160) and C.yellow or C.red)
			pingSub.Text = Net.source
		else
			pingValue.Text, pingValue.TextColor3, pingSub.Text = "N/A", C.dim, "not readable"
		end

		local nColor = ({ Excellent = C.green, Good = C.green, Fair = C.yellow, Poor = C.red,
			Unstable = C.red, Unavailable = C.dim })[Net.status] or C.dim
		netLine1.Text = "Network: " .. Net.status
		netLine1.TextColor3 = nColor
		if Net.ping then
			local extra = ""
			if Net.recv and Net.send then
				extra = string.format(" · ↓%d ↑%d kbps", math.floor(Net.recv), math.floor(Net.send))
			end
			local hint = (Net.status == "Unstable") and "\nSpikes detected: check Wi-Fi / background downloads." or ""
			netLine2.Text = string.format("Avg %d ms · Jitter %d ms · Peak %d ms%s%s",
				math.floor(Net.mean + 0.5), math.floor(Net.jitter + 0.5), math.floor(Net.peak + 0.5), extra, hint)
		else
			netLine2.Text = "Ping is not available on this client."
		end

		-- Status rows
		if State.enabled then
			optText.Text = "Active · " .. LEVELS[State.level].name .. (State.auto and " · Auto" or "")
			optDot.BackgroundColor3 = C.green
			vfxText.Text = string.format("%d of %d effects reduced", Counts.adjusted, Counts.tracked)
			vfxDot.BackgroundColor3 = (Counts.tracked == 0) and C.dim or C.green
		else
			optText.Text = "Off · original settings"
			optDot.BackgroundColor3 = C.off
			vfxText.Text = string.format("Restored · %d tracked", Counts.tracked)
			vfxDot.BackgroundColor3 = C.blue
		end
		local label2, col = perfLabel()
		devText.Text = deviceType .. " · " .. label2
		devDot.BackgroundColor3 = col
	end

	-- Entrance animation
	window.BackgroundTransparency = 1
	tween(window, 0.35, { BackgroundTransparency = 0 })
	api.syncControls(true)
	RunService.Heartbeat:Wait()
	resize(true)

	api.gui = gui
	return api
end

--==============================================================================
-- 4) CONTROLS (wired to UI + engine)
--==============================================================================
setLevel = function(level, fromAuto)
	level = math.clamp(level, 1, 3)
	State.level = level
	Auto.lastChange = os.clock()
	Auto.low, Auto.high = 0, 0
	if not fromAuto and not State.enabled then State.enabled = true end -- picking a level turns optimization on
	if UI then UI.syncControls(false) end
	reapplyAll()
end

setEnabled = function(v)
	State.enabled = v and true or false
	Auto.low, Auto.high = 0, 0
	if UI then UI.syncControls(false) end
	reapplyAll()
end

setAuto = function(v)
	State.auto = v and true or false
	Auto.low, Auto.high = 0, 0
	if UI then UI.syncControls(false) end
end

restoreAll = function()
	State.enabled = false -- restoring also switches optimization off so nothing is re-applied
	Auto.low, Auto.high = 0, 0
	if UI then UI.syncControls(false) end
	reapplyAll()
end

-- Automatic optimization: hysteresis + cooldown + anti-oscillation floor.
local function autoStep(now)
	if not (State.enabled and State.auto) then Auto.low, Auto.high = 0, 0 return end
	if now - startTime < 8 then return end        -- warm-up (loading spikes)
	if Perf.fps < 5 then return end               -- window unfocused / paused

	local target = targetFps()
	if Perf.fps < target * 0.78 then
		Auto.low += 1; Auto.high = 0
	elseif Perf.fps > target * 0.93 then
		Auto.high += 1; Auto.low = 0
	else
		Auto.low, Auto.high = 0, 0
	end

	if now - Auto.lastChange < 8 then return end  -- cooldown between changes

	if Auto.low >= 3 and State.level < 3 then
		-- If we just lowered the level and FPS fell again, remember that this level is needed.
		if Auto.lastDown and now - Auto.lastDown < 90 then
			Auto.floorLevel, Auto.floorUntil = State.level + 1, now + 180
		end
		setLevel(State.level + 1, true)
	elseif Auto.high >= 15 and State.level > 1 then
		local floor = (now < Auto.floorUntil) and Auto.floorLevel or 1
		if State.level - 1 >= floor then
			Auto.lastDown = now
			setLevel(State.level - 1, true)
		end
	end
end

--==============================================================================
-- 5) INITIALIZATION
--==============================================================================
local function destroy()
	if not running then return end
	running = false
	generation += 1
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	table.clear(conns)

	State.enabled = false -- restore every original value synchronously
	local list = {}
	for inst in pairs(records) do list[#list + 1] = inst end
	for _, inst in ipairs(list) do pcall(processInstance, inst) end

	if UI and UI.gui then UI.gui:Destroy() end
	if _G.__FPSBooster and _G.__FPSBooster.Destroy == destroy then _G.__FPSBooster = nil end
end
_G.__FPSBooster = { Destroy = destroy }

local function init()
	-- 1) Listen for new effects first so nothing is missed during the scan.
	track(workspace.DescendantAdded:Connect(onDescendantAdded))
	track(Lighting.DescendantAdded:Connect(onDescendantAdded))

	-- Process the new-effect queue a few items per frame (no spikes).
	track(RunService.Heartbeat:Connect(function()
		local n = 0
		while #pending > 0 and n < 40 do
			local inst = table.remove(pending)
			pcall(processInstance, inst)
			n += 1
		end
	end))

	-- Frame timing: arithmetic only, no allocations.
	track(RunService.RenderStepped:Connect(function(dt)
		Perf.frames += 1
		Perf.acc += dt
		if dt > Perf.maxDt then Perf.maxDt = dt end
	end))

	-- 2) UI
	UI = buildUI()

	-- 3) Initial optimization pass (Lighting effects, then the world).
	scan(Lighting)
	scan(workspace)
	updateCounts()

	-- 4) Lightweight 2 Hz monitor loop.
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
				pcall(autoStep, now)
			end
			if tick % 4 == 0 then pcall(updateCounts) end
			pcall(UI.update)
		end
	end)
end

local ok, err = pcall(init)
if ok then
	task.spawn(notify, "FPS BOOSTER", "Optimization completed successfully!", 5)
else
	warn("[FPSBooster] Initialization failed: " .. tostring(err))
	task.spawn(notify, "FPS BOOSTER", "Initialization failed: " .. string.sub(tostring(err), 1, 120), 8)
end
