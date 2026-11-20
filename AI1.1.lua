--[[
	============================================================
	AI菜单 · Roblox  （UI 统一为 5.lua 风格）
	============================================================

	界面：WindUI · Neumorph（新拟态）主题
	功能：
	  · 首页：常用分类快速入口
	  · 自瞄追踪：自瞄 / 追踪 / 目标判断 / FOV 大小·距离·颜色
	  · 人物绘制：NPC 方框 / 射线 / 信息
	              玩家 方框 / 射线 / 信息 / 血量
	              掩体判断（可见绿色，掩体后红色）
	  · 标点传送：定位 / X Y Z 空格格式坐标传送 / 循环传送 / 标点行走
	  · 其他功能：速度 / 高跳 / 无限跳 / 穿墙 / 飞行 V1-V3
	  · 设置：弹窗缩放 / 透明度 / 提示 / 长宽 / 主界面背景色 / 配置管理

	快捷键：Right Shift 开关窗口
	要求：执行器支持 loadstring（或 load）、HttpGet、Drawing。
	重复执行会先销毁上一实例；全局代次锁确保同一时间只保留一个主 UI。

	UI 修复（与 5.lua 同步）：
	  · 首次启动只选择一次首页；暗色主题普通/选中 Tab 底色一致
	  · 清除分类鼠标悬停残留底色，切换分类后始终只保留当前分类的选中状态
	  · 所有自定义提示/确认弹窗共用尺寸控制，默认宽 300、高/长 220；主窗口关闭框除外
	  · 同一 Tab 内相邻 Section 之间显式插入 Space，首次打开不会塌陷
	  · Section 先折叠，首帧渲染后再统一展开，避免多 Section 同时展开导致间距错乱

	人物绘制修复：
	  · 玩家与 NPC 血条根据投影方框宽高动态计算，位于方框左侧并随人物尺寸缩放
	  · 使用模型包围盒投影，避免角色部分入镜时漏绘；离屏对象及时隐藏并回收
	  · 方框最小 10px，修复 230m 以外整段隐藏的问题
	  · 新增「屏蔽队友」开关，同队玩家不绘制
	  · 每个目标最多 4 个 Drawing，并自动回收 8 秒未显示的缓存
]]

-- ============================================================
-- 0. 清理上一次运行
-- ============================================================
local genv
pcall(function()
	if type(getgenv) == "function" then
		genv = getgenv()
	end
end)
if not genv then
	pcall(function()
		if type(shared) == "table" then
			genv = shared
		elseif type(_G) == "table" then
			genv = _G
		end
	end)
end

-- 每次执行都先登记新一代实例；旧实例优先完整清理，否则至少销毁旧窗口。
-- runToken 还可阻止较慢的旧脚本在新脚本启动后继续创建第二个主 UI。
local RUN_TOKEN = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1000000000))
local cleanup -- 在创建中文关闭按钮前声明，回调稍后绑定真正的清理函数
local closeRequested = false
local function isCurrentRun()
	if not genv then return true end
	local current = genv.__NeumorphHub
	return type(current) == "table" and current.token == RUN_TOKEN
end
local function releaseRunSlot()
	if genv and type(genv.__NeumorphHub) == "table"
		and genv.__NeumorphHub.token == RUN_TOKEN then
		genv.__NeumorphHub = nil
	end
end

if genv then
	local old = genv.__NeumorphHub
	if type(old) == "table" then
		local cleaned = false
		if type(old.cleanup) == "function" then
			cleaned = pcall(old.cleanup)
		end
		if not cleaned then
			if type(old.destroy) == "function" then
				pcall(old.destroy)
			elseif old.window then
				pcall(function() old.window:Destroy() end)
			end
		end
	end
	genv.__NeumorphHub = { token = RUN_TOKEN, loading = true }
end

-- ============================================================
-- 1. 载入 WindUI
-- ============================================================
local SOURCES = {
	-- 固定使用已发布版本，避免 latest/main 更新导致接口变化。
	"https://github.com/Footagesus/WindUI/releases/download/1.6.66/main.lua",
	-- 官方文档推荐的最新发布地址作为备用。
	"https://github.com/Footagesus/WindUI/releases/latest/download/main.lua",
	-- 官方仓库构建文件备用（可能随主分支变化）。
	"https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua",
}

local WindUI
local LoadError = "未尝试任何 WindUI 地址"
local compile = loadstring or load

for _, url in ipairs(SOURCES) do
	local ok, result = pcall(function()
		assert(type(compile) == "function", "执行器没有可用的 loadstring/load")
		local source = game:HttpGet(url)
		assert(type(source) == "string" and #source > 10000, "WindUI 下载内容为空或不是 Lua 文件")
		local chunk, compileError = compile(source)
		assert(type(chunk) == "function", "WindUI 编译失败：" .. tostring(compileError))
		local module = chunk()
		assert(type(module) == "table", "WindUI 初始化结果不是 table")
		assert(type(module.CreateWindow) == "function", "WindUI 缺少 CreateWindow 接口")
		return module
	end)

	if ok then
		WindUI = result
		break
	end
	LoadError = result
	warn("[Neumorph] WindUI 地址加载失败：" .. tostring(url) .. "；原因：" .. tostring(result))
end

if not WindUI then
	warn("[Neumorph] 载入 WindUI 失败：" .. tostring(LoadError))
	warn("[Neumorph] 请确认执行器支持 game:HttpGet 和 loadstring，并允许访问 github.com。")
	releaseRunSlot()
	return
end

if not isCurrentRun() then
	return
end

-- ============================================================
-- 2. 新拟态主题（内联）
-- ============================================================
local function hex(s) return Color3.fromHex(s) end

local THEMES = {
	{
		Name = "Neumorph Light",
		Accent = hex("#eef2f8"), Dialog = hex("#f1f4f9"), Outline = hex("#ffffff"),
		Text = hex("#2a3140"), Placeholder = hex("#8d98ab"), Background = hex("#dfe4ec"),
		Button = hex("#5c6bf6"), Icon = hex("#6f7b8e"), Toggle = hex("#2fae7d"),
		Slider = hex("#5c6bf6"), Checkbox = hex("#5c6bf6"), Primary = hex("#5c6bf6"),
		PanelBackground = hex("#e3e8f0"), PanelBackgroundTransparency = 0,
		LabelBackground = hex("#dfe4ec"), LabelBackgroundTransparency = 0,
		ElementBackground = hex("#e8ecf3"), ElementBackgroundTransparency = 0,
		TabBackground = hex("#e8ecf3"), TabBackgroundHover = hex("#eef2f8"),
		TabBackgroundHoverTransparency = 0, TabBackgroundActive = hex("#eef2f8"),
		TabBackgroundActiveTransparency = 0,
		ShadowDark = hex("#92a2b8"), ShadowLight = hex("#ffffff"),
		ShadowTransparency = 0.45, Elevation = 7, Inset = 4,
	},
	{
		Name = "Neumorph Dark",
		Accent = hex("#323945"), Dialog = hex("#2a303a"), Outline = hex("#3a4250"),
		Text = hex("#eef2f9"), Placeholder = hex("#7d8799"), Background = hex("#15181d"),
		Button = hex("#7d88ff"), Icon = hex("#98a3b5"), Toggle = hex("#3ecf9a"),
		Slider = hex("#7d88ff"), Checkbox = hex("#7d88ff"), Primary = hex("#7d88ff"),
		PanelBackground = hex("#1c2027"), PanelBackgroundTransparency = 0,
		LabelBackground = hex("#15181d"), LabelBackgroundTransparency = 0,
		ElementBackground = hex("#242931"), ElementBackgroundTransparency = 0,
		TabBackground = hex("#242931"), TabBackgroundHover = hex("#2a303a"),
		TabBackgroundHoverTransparency = 0, TabBackgroundActive = hex("#242931"),
		TabBackgroundActiveTransparency = 0,
		ShadowDark = hex("#000000"), ShadowLight = hex("#3a4250"),
		ShadowTransparency = 0.65, Elevation = 7, Inset = 4,
	},
	{
		Name = "Neumorph Clay",
		Accent = hex("#f4eee5"), Dialog = hex("#f2ece2"), Outline = hex("#fffaf2"),
		Text = hex("#3a3128"), Placeholder = hex("#a5957f"), Background = hex("#ded6ca"),
		Button = hex("#d1704f"), Icon = hex("#8a7a68"), Toggle = hex("#6f9b5f"),
		Slider = hex("#d1704f"), Checkbox = hex("#d1704f"), Primary = hex("#d1704f"),
		PanelBackground = hex("#e2d9cc"), PanelBackgroundTransparency = 0,
		LabelBackground = hex("#ded6ca"), LabelBackgroundTransparency = 0,
		ElementBackground = hex("#e8e0d4"), ElementBackgroundTransparency = 0,
		TabBackground = hex("#e8e0d4"), TabBackgroundHover = hex("#f0e9de"),
		TabBackgroundHoverTransparency = 0, TabBackgroundActive = hex("#f0e9de"),
		TabBackgroundActiveTransparency = 0,
		ShadowDark = hex("#9e886c"), ShadowLight = hex("#fffdf7"),
		ShadowTransparency = 0.42, Elevation = 7, Inset = 4,
	},
	{
		Name = "Neumorph Mint",
		Accent = hex("#f1f8f5"), Dialog = hex("#eef6f2"), Outline = hex("#ffffff"),
		Text = hex("#23342f"), Placeholder = hex("#8fa69c"), Background = hex("#d9e5e2"),
		Button = hex("#2f9c7c"), Icon = hex("#6f877e"), Toggle = hex("#2f9c7c"),
		Slider = hex("#2f9c7c"), Checkbox = hex("#2f9c7c"), Primary = hex("#2f9c7c"),
		PanelBackground = hex("#dde9e4"), PanelBackgroundTransparency = 0,
		LabelBackground = hex("#d9e5e2"), LabelBackgroundTransparency = 0,
		ElementBackground = hex("#e3eee9"), ElementBackgroundTransparency = 0,
		TabBackground = hex("#e3eee9"), TabBackgroundHover = hex("#edf6f2"),
		TabBackgroundHoverTransparency = 0, TabBackgroundActive = hex("#edf6f2"),
		TabBackgroundActiveTransparency = 0,
		ShadowDark = hex("#7a988c"), ShadowLight = hex("#ffffff"),
		ShadowTransparency = 0.38, Elevation = 7, Inset = 4,
	},
	{
		Name = "Neumorph Lavender",
		Accent = hex("#f6f3fb"), Dialog = hex("#f2eef9"), Outline = hex("#ffffff"),
		Text = hex("#302a3f"), Placeholder = hex("#9e95b3"), Background = hex("#e2ddec"),
		Button = hex("#8265e8"), Icon = hex("#7f7696"), Toggle = hex("#4ea88b"),
		Slider = hex("#8265e8"), Checkbox = hex("#8265e8"), Primary = hex("#8265e8"),
		PanelBackground = hex("#e4dff0"), PanelBackgroundTransparency = 0,
		LabelBackground = hex("#e2ddec"), LabelBackgroundTransparency = 0,
		ElementBackground = hex("#eae5f4"), ElementBackgroundTransparency = 0,
		TabBackground = hex("#eae5f4"), TabBackgroundHover = hex("#f3effa"),
		TabBackgroundHoverTransparency = 0, TabBackgroundActive = hex("#f3effa"),
		TabBackgroundActiveTransparency = 0,
		ShadowDark = hex("#8e80a8"), ShadowLight = hex("#ffffff"),
		ShadowTransparency = 0.38, Elevation = 7, Inset = 4,
	},
}

for _, theme in ipairs(THEMES) do
	pcall(function() WindUI:AddTheme(theme) end)
end

local THEME_NAME = "Neumorph Dark"
pcall(function() WindUI:SetTheme(THEME_NAME) end)

-- ============================================================
-- 3. 建窗口
-- ============================================================
local windowConfig = {
	Title = "AI菜单",
	Author = "1.1",
	Icon = "wind",
	Theme = THEME_NAME,
	Size = UDim2.fromOffset(640, 560),
	MinSize = Vector2.new(520, 420),
	MaxSize = Vector2.new(1100, 900),
	SideBarWidth = 186,
	ToggleKey = Enum.KeyCode.RightShift,
	Resizable = true,
	HideSearchBar = true,
	Folder = "NeumorphHub",
	User = { Enabled = true },
	-- 手机端和没有实体键盘的设备也能点击打开窗口。
	OpenButton = {
		Enabled = true,
		Title = "打开菜单",
		Draggable = true,
		OnlyMobile = false,
	},
}

local okWindow, Window = pcall(function()
	return WindUI:CreateWindow(windowConfig)
end)

-- 兼容部分旧构建：若高级可选参数不受支持，退回官方文档中的基础配置。
if not okWindow or not Window then
	warn("[Neumorph] 完整窗口配置失败，尝试基础配置：" .. tostring(Window))
	okWindow, Window = pcall(function()
		return WindUI:CreateWindow({
			Title = "AI菜单",
			Author = "1.1",
			Icon = "wind",
			Theme = THEME_NAME,
			Size = UDim2.fromOffset(640, 560),
			MinSize = Vector2.new(520, 420),
			MaxSize = Vector2.new(1100, 900),
			ToggleKey = Enum.KeyCode.RightShift,
			Resizable = true,
			HideSearchBar = true,
			Folder = "NeumorphHub",
		})
	end)
end

if not okWindow or not Window then
	warn("[Neumorph] 创建窗口失败：" .. tostring(Window))
	warn("[Neumorph] 请检查 WindUI 版本、执行器输出中的上一条错误，以及是否允许创建 UI。")
	releaseRunSlot()
	return
end

if not isCurrentRun() then
	pcall(function() Window:Destroy() end)
	return
end
if genv then
	local record = genv.__NeumorphHub
	record.window = Window
	record.destroy = function()
		pcall(function() Window:Destroy() end)
	end
end

-- 替换 WindUI 自带的英文销毁确认框，使用中文确认；取消不会影响窗口。
local disableCloseOK, disableCloseError = pcall(function()
	Window:DisableTopbarButtons({ "Close" })
end)
-- 就算当前 WindUI 构建不支持隐藏内置关闭键，也阻止它弹出英文确认框；
-- 用户仍可使用下面创建的中文关闭按钮进行二次确认。
pcall(function() Window.IgnoreAlerts = true end)
if not disableCloseOK then
	warn("[Neumorph] 隐藏 WindUI 内置关闭按钮失败：" .. tostring(disableCloseError))
end
local closeButtonOK, closeButtonError = pcall(function()
	Window:CreateTopbarButton("NeumorphChineseClose", "x", function()
		Window:Dialog({
			Title = "关闭主界面",
			Content = "确定要关闭主界面吗？关闭后需要重新执行脚本才能再次打开。",
			Buttons = {
				{
					Title = "取消",
					Variant = "Secondary",
					Callback = function() end,
				},
				{
					Title = "确认关闭",
					Variant = "Primary",
					Callback = function()
						if cleanup then
							cleanup()
						else
							closeRequested = true
							pcall(function() Window:Destroy() end)
						end
					end,
				},
			},
		})
	end, 1000)
end)
if not closeButtonOK then
	warn("[Neumorph] 中文关闭按钮创建失败：" .. tostring(closeButtonError))
end

-- ============================================================
-- 4. 服务与状态
-- ============================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")

local LocalPlayer = Players.LocalPlayer
local waited = 0
while not LocalPlayer and waited < 15 do
	task.wait(0.5)
	waited = waited + 0.5
	LocalPlayer = Players.LocalPlayer
end
if not LocalPlayer then
	warn("[Neumorph] 未获取到 LocalPlayer，请在游戏内执行。")
	return
end

local Aim = {
	Enabled = false,
	Track = false,
	Smooth = 8,
	Strength = 100,
	SilentAim = false,

	-- 自瞄独立目标判断与视野范围
	AimTeamCheck = true,
	AimCoverCheck = true,
	AimNpcCheck = true,
	AimFov = 180,
	AimRange = 500,
	AimColor = Color3.fromRGB(40, 220, 90), -- 自瞄 FOV 默认绿色
	AimShowFov = false,
	AimFovThickness = 3,
	AimFovTransparency = 0.8,

	-- 追踪独立目标判断与视野范围
	TrackTeamCheck = true,
	TrackCoverCheck = true,
	TrackNpcCheck = true,
	TrackFov = 180,
	TrackRange = 500,
	TrackColor = Color3.fromRGB(125, 145, 255),
	TrackShowFov = false,
	TrackFovThickness = 3,
	TrackFovTransparency = 0.8,
}

local ESP = {
	PlayerBox = false, PlayerRay = false, PlayerInfo = false, PlayerHealth = false,
	NpcBox = false, NpcRay = false, NpcInfo = false, NpcHealth = false,
	DrawNpcTeammates = false,
	Cover = true, TeamCheck = false, MaxDistance = 1500,
	Color = Color3.fromRGB(140, 160, 255),
	CoverVisibleColor = Color3.fromRGB(80, 225, 130),
	CoverOccludedColor = Color3.fromRGB(255, 85, 85),
	HealthBarColor = Color3.fromRGB(80, 225, 130),
	Thickness = 1,
	Transparency = 0.9,
	RefreshEvery2s = false,
}

local Misc = {
	SpeedOn = false, Speed = 50,
	JumpOn = false, JumpPower = 120,
	InfJumpOn = false, JumpInterval = 0.15,
	NoclipOn = false, NoclipSpeed = 60,
	FlightV1On = false, FlightV1Speed = 50, FlightV1Height = 0,
	FlightV2On = false, FlightV2Speed = 60,
	FlightV3On = false, FlightV3Speed = 60,
	FlightViewControl = true, FlightMoveControl = true,
	FlightAscend = false, FlightDescend = false, -- 旧配置兼容字段，不再用于持续升降
	FlightHeightLock = true,
	FlightPanelScale = 0.65,
}

-- 设置状态：弹窗缩放、透明度、提示、宽高，以及主界面背景色。
local PopupSettings = {
	Scale = 0.5,             -- 默认缩小 50%
	Transparency = 0.12,
	ShowNotifications = true,
	Width = 300,             -- 弹窗基础宽度（像素），由“弹窗宽度”统一调整
	Height = 220,            -- 弹窗基础高度/长度（像素），由“弹窗长度”统一调整
}
local UISettings = {
	BackgroundColor = Color3.fromRGB(21, 24, 29), -- 主界面背景色
	BackgroundTransparency = 0.10, -- 主界面背景透明度（0-0.9）
}
local PopupGui, PopupPanel, PopupScale, PopupTitle, PopupDescription
local PopupConfirm, PopupCancel
local PopupSizeControl, PopupTransparencyControl, PopupNotifyControl
local PopupWidthControl, PopupHeightControl, UIBackgroundColorControl, UIBackgroundTransparencyControl
local PopupAction = nil

-- 标点传送状态：坐标按添加顺序编号，清空后从 1 重新开始。
local WaypointState = {
	Points = {},
	LoopEnabled = false,
	LoopInterval = 1,
	LoopRate = 1, -- 每秒传送 b 个标点；实际间隔为 1/b 秒
	LoopToggle = nil,
	IntervalInput = nil, -- 旧版本输入控件字段，保留兼容
	RateInput = nil,
	IntervalRow = nil,
	RateRow = nil,
	Folder = nil,
	WalkEnabled = false,
	WalkToggle = nil,
	WalkSpeed = 16,
	WalkSpeedInput = nil, -- 旧版本输入控件字段，保留兼容
	WalkSpeedRow = nil,
	CoordinateText = "",
	CoordinateInput = nil,
}

local running = true
local connections = {}
local espObjects = {}
local coverCache = setmetatable({}, { __mode = "k" })
local npcCache = {}
local noclipSaved = {}
local lastInfJump = 0

-- 飞行控制状态。三种飞行模式互斥，共用同一个物理控制器，避免叠加力对象。
local FlightRuntime = {
	Mode = nil, Root = nil, Humanoid = nil,
	Velocity = nil, Gyro = nil,
	BaseY = 0, SavedAutoRotate = nil, SavedWalkSpeed = nil,
	SavedJumpPower = nil, SavedUseJumpPower = nil,
}
local FlightPanelGui, FlightPanel, FlightPanelButtons = nil, nil, {}
local FlightPanelScaleObject, FlightPanelMiniButton = nil, nil
local FlightPanelConnections = {}
local FlightV1Toggle, FlightV2Toggle, FlightV3Toggle = nil, nil, nil
local FlightV1OpenButton, FlightV2SpeedInput, FlightV3SpeedInput = nil, nil, nil
local FlightUIBusy = false
local destroyFlightPhysics

-- WindUI 1.6.66 的 Colorpicker 对话框是在点击时动态创建的，内部按钮/字段标签使用英文常量。
-- 这里仅翻译颜色选择器会用到的精确英文短词，不改动菜单中的其他文字。
local COLOR_PICKER_TRANSLATIONS = {
	Cancel = "取消",
	Apply = "应用",
	Hex = "十六进制",
	Red = "红色",
	Green = "绿色",
	Blue = "蓝色",
	Alpha = "透明度",
}
local colorPickerWatchedRoots = setmetatable({}, { __mode = "k" })
local colorPickerWatchedObjects = setmetatable({}, { __mode = "k" })

local function watchColorPickerTextObject(object)
	if not object or (not object:IsA("TextLabel") and not object:IsA("TextButton")) then return end
	if colorPickerWatchedObjects[object] then return end
	colorPickerWatchedObjects[object] = true

	local function translate()
		if not object.Parent then return end
		local translated = COLOR_PICKER_TRANSLATIONS[object.Text]
		if translated and translated ~= object.Text then
			object.Text = translated
		end
	end

	translate()
	local ok, connection = pcall(function()
		return object:GetPropertyChangedSignal("Text"):Connect(translate)
	end)
	if ok and connection then table.insert(connections, connection) end
end

local function attachColorPickerLocalization(root)
	if typeof(root) ~= "Instance" or colorPickerWatchedRoots[root] then return end
	colorPickerWatchedRoots[root] = true
	-- 新建的颜色选择窗口会作为后代加入，因此可以在其创建瞬间汉化。
	for _, descendant in ipairs(root:GetDescendants()) do
		watchColorPickerTextObject(descendant)
	end
	table.insert(connections, root.DescendantAdded:Connect(watchColorPickerTextObject))
end

local function initializeColorPickerLocalization()
	local roots = {}
	pcall(function()
		if type(gethui) == "function" then
			local root = gethui()
			if root then table.insert(roots, root) end
		end
	end)
	pcall(function() table.insert(roots, game:GetService("CoreGui")) end)
	pcall(function()
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if playerGui then table.insert(roots, playerGui) end
	end)
	for _, root in ipairs(roots) do attachColorPickerLocalization(root) end
end

local buildErrors = {}
local function safe(label, fn)
	local ok, err = pcall(fn)
	if not ok then
		local message = label .. "：" .. tostring(err)
		buildErrors[#buildErrors + 1] = message
		warn("[Neumorph] UI 构建失败：" .. message)
	end
end

local displayPopupNotification
-- 监听 WindUI 的 GUI 根节点。颜色选择对话框为延迟创建，DescendantAdded 会在弹出时完成汉化。
task.defer(initializeColorPickerLocalization)

local function notify(title, content, icon, duration)
	if PopupSettings and PopupSettings.ShowNotifications == false then return end
	if displayPopupNotification then
		local ok, shown = pcall(displayPopupNotification, title, content, duration)
		if ok and shown then return end
	end
	pcall(function()
		WindUI:Notify({
			Title = title, Content = content,
			Icon = icon or "info", Duration = duration or 4,
		})
	end)
end

-- 独立的轻量确认弹窗：不遮挡整个屏幕，固定在右下角，默认缩放为原尺寸的 50%。
local function createActionPopup()
	local parent
	pcall(function()
		if type(gethui) == "function" then parent = gethui() end
	end)
	if not parent then
		pcall(function() parent = LocalPlayer:WaitForChild("PlayerGui") end)
	end
	if not parent then
		pcall(function() parent = game:GetService("CoreGui") end)
	end
	assert(parent, "找不到可用于显示弹窗的 UI 容器")

	pcall(function()
		local old = parent:FindFirstChild("NeumorphActionPopup")
		if old then old:Destroy() end
	end)

	local gui = Instance.new("ScreenGui")
	gui.Name = "NeumorphActionPopup"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 10000
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = parent
	PopupGui = gui

	local panel = Instance.new("Frame")
	panel.Name = "Popup"
	panel.AnchorPoint = Vector2.new(1, 1)
	panel.Position = UDim2.new(1, -18, 1, -18)
	panel.Size = UDim2.fromOffset(PopupSettings.Width, PopupSettings.Height)
	panel.BackgroundColor3 = Color3.fromRGB(31, 36, 48)
	panel.BackgroundTransparency = PopupSettings.Transparency
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = gui
	PopupPanel = panel

	local scale = Instance.new("UIScale")
	scale.Scale = PopupSettings.Scale
	scale.Parent = panel
	PopupScale = scale

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 18)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(125, 136, 255)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.22
	stroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0.04, 0, 0.05, 0)
	title.Size = UDim2.new(0.92, 0, 0.18, 0)
	title.Font = Enum.Font.GothamBold
	title.Text = "操作确认"
	title.TextColor3 = Color3.fromRGB(245, 247, 255)
	title.TextSize = 30
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Parent = panel
	PopupTitle = title

	local desc = Instance.new("TextLabel")
	desc.Name = "Description"
	desc.BackgroundTransparency = 1
	desc.Position = UDim2.new(0.04, 0, 0.25, 0)
	desc.Size = UDim2.new(0.92, 0, 0.46, 0)
	desc.Font = Enum.Font.Gotham
	desc.Text = "是否继续？"
	desc.TextColor3 = Color3.fromRGB(205, 212, 228)
	desc.TextSize = 22
	desc.TextWrapped = true
	desc.TextXAlignment = Enum.TextXAlignment.Left
	desc.TextYAlignment = Enum.TextYAlignment.Top
	desc.Parent = panel
	PopupDescription = desc

	local function makeButton(name, text, position, color)
		local button = Instance.new("TextButton")
		button.Name = name
		button.Position = position
		button.Size = UDim2.new(0.42, 0, 0.17, 0)
		button.BackgroundColor3 = color
		button.BorderSizePixel = 0
		button.AutoButtonColor = true
		button.Font = Enum.Font.GothamBold
		button.Text = text
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		button.TextSize = 22
		button.Parent = panel
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 12)
		c.Parent = button
		return button
	end

	PopupConfirm = makeButton("Confirm", "确认", UDim2.new(0.04, 0, 0.78, 0), Color3.fromRGB(83, 105, 235))
	PopupCancel = makeButton("Cancel", "取消", UDim2.new(0.54, 0, 0.78, 0), Color3.fromRGB(75, 83, 101))

	PopupConfirm.Activated:Connect(function()
		local action = PopupAction
		PopupAction = nil
		panel.Visible = false
		if type(action) == "function" then
			local ok, err = pcall(action)
			if not ok then
				warn("[Neumorph] 弹窗操作失败：" .. tostring(err))
				notify("操作失败", tostring(err), "alert-triangle", 5)
			end
		end
	end)
	PopupCancel.Activated:Connect(function()
		PopupAction = nil
		panel.Visible = false
	end)
	return true
end

local function applyPopupSettings()
	PopupSettings.Scale = math.clamp(tonumber(PopupSettings.Scale) or 0.5, 0.25, 1)
	PopupSettings.Transparency = math.clamp(tonumber(PopupSettings.Transparency) or 0.12, 0, 0.9)
	PopupSettings.Width = math.clamp(math.floor((tonumber(PopupSettings.Width) or 300) + 0.5), 100, 1000)
	PopupSettings.Height = math.clamp(math.floor((tonumber(PopupSettings.Height) or 220) + 0.5), 70, 700)
	if PopupScale then PopupScale.Scale = PopupSettings.Scale end
	if PopupPanel then
		PopupPanel.Size = UDim2.fromOffset(PopupSettings.Width, PopupSettings.Height)
		PopupPanel.BackgroundTransparency = PopupSettings.Transparency
	end
	-- 子控件使用相对尺寸，改变弹窗长宽时不会挤出边界。
	local width = PopupSettings.Width
	if PopupTitle then PopupTitle.TextSize = math.clamp(math.floor(width / 20), 16, 30) end
	if PopupDescription then PopupDescription.TextSize = math.clamp(math.floor(width / 28), 14, 22) end
	if PopupConfirm then PopupConfirm.TextSize = math.clamp(math.floor(width / 28), 14, 22) end
	if PopupCancel then PopupCancel.TextSize = math.clamp(math.floor(width / 28), 14, 22) end
end

-- 所有操作提示也使用同一弹窗：自动隐藏、默认缩放 50%，并跟随设置中的透明度。
local popupMessageToken = 0
displayPopupNotification = function(title, content, duration)
	if PopupPanel and PopupPanel.Visible and PopupAction then
		return false -- 不覆盖正在等待确认的操作
	end
	if not PopupPanel then
		local ok = pcall(createActionPopup)
		if not ok or not PopupPanel then return false end
	end
	popupMessageToken = popupMessageToken + 1
	local token = popupMessageToken
	PopupTitle.Text = tostring(title or "提示")
	PopupDescription.Text = tostring(content or "")
	PopupConfirm.Visible = false
	PopupCancel.Visible = false
	PopupAction = nil
	applyPopupSettings()
	PopupPanel.Visible = true
	task.delay(math.clamp(tonumber(duration) or 4, 1, 15), function()
		if popupMessageToken == token and PopupPanel and PopupPanel.Parent and not PopupAction then
			PopupPanel.Visible = false
			-- 恢复用户在“设置 → 弹窗”中的常规尺寸与缩放。
			applyPopupSettings()
			PopupConfirm.Visible = true
			PopupCancel.Visible = true
		end
	end)
	return true
end

local function openActionPopup(title, description, callback, confirmText)
	if not PopupPanel then
		local ok, err = pcall(createActionPopup)
		if not ok then
			warn("[Neumorph] 创建操作弹窗失败：" .. tostring(err))
			notify("弹窗不可用", "无法创建确认界面，请查看执行器报错。", "alert-triangle", 4)
			return
		end
	end
	PopupTitle.Text = tostring(title or "操作确认")
	PopupDescription.Text = tostring(description or "是否继续？")
	popupMessageToken = popupMessageToken + 1
	PopupConfirm.Text = tostring(confirmText or "确认")
	PopupConfirm.Visible = true
	PopupCancel.Visible = true
	PopupAction = callback
	applyPopupSettings()
	PopupPanel.Visible = true
end

local function getHumanoid()
	local char = LocalPlayer.Character
	if char then return char:FindFirstChildOfClass("Humanoid") end
	return nil
end

local function getFlightRoot()
	local char = LocalPlayer.Character
	if not char then return nil end
	return char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
end

local function getFlightSpeed(mode)
	if mode == "V1" then return math.clamp(tonumber(Misc.FlightV1Speed) or 50, 1, 500) end
	if mode == "V2" then return math.clamp(tonumber(Misc.FlightV2Speed) or 60, 1, 500) end
	return math.clamp(tonumber(Misc.FlightV3Speed) or 60, 1, 500)
end

local function flightModeFromSettings()
	-- 优先级只用于处理手动编辑配置文件时出现多个 true 的情况。
	if Misc.FlightV3On then return "V3" end
	if Misc.FlightV2On then return "V2" end
	if Misc.FlightV1On then return "V1" end
	return nil
end

local function syncFlightToggleControls()
	FlightUIBusy = true
	pcall(function() if FlightV1Toggle and FlightV1Toggle.Set then FlightV1Toggle:Set(Misc.FlightV1On) end end)
	pcall(function() if FlightV2Toggle and FlightV2Toggle.Set then FlightV2Toggle:Set(Misc.FlightV2On) end end)
	pcall(function() if FlightV3Toggle and FlightV3Toggle.Set then FlightV3Toggle:Set(Misc.FlightV3On) end end)
	FlightUIBusy = false
end

local function setFlightMode(mode, enabled, silent)
	if mode ~= "V1" and mode ~= "V2" and mode ~= "V3" then return end
	if enabled then
		Misc.FlightV1On = mode == "V1"
		Misc.FlightV2On = mode == "V2"
		Misc.FlightV3On = mode == "V3"
		if FlightRuntime.Mode ~= mode then
			-- 切换模式前恢复旧 Humanoid，避免 V1/V2/V3 连续切换后 WalkSpeed 一直为 0。
			if destroyFlightPhysics then destroyFlightPhysics(true) end
			FlightRuntime.Mode = mode
		end
	else
		if mode == "V1" then Misc.FlightV1On = false end
		if mode == "V2" then Misc.FlightV2On = false end
		if mode == "V3" then Misc.FlightV3On = false end
		local nextMode = flightModeFromSettings()
		if nextMode ~= FlightRuntime.Mode then
			if destroyFlightPhysics then destroyFlightPhysics(true) end
			FlightRuntime.Mode = nextMode
		end
	end
	syncFlightToggleControls()
	if not silent then
		if enabled then notify("飞行 " .. mode, "已开启。使用 WASD/摇杆移动；升降请在控制面板点击单次上升/下降。", "wind", 3)
		else notify("飞行 " .. mode, "已关闭。", "check", 2) end
	end
end

local function disconnectFlightPanelConnections()
	for _, connection in ipairs(FlightPanelConnections) do
		pcall(function() connection:Disconnect() end)
	end
	FlightPanelConnections = {}
end

local function refreshFlightPanel()
	if not FlightPanelGui or not FlightPanelGui.Parent then return end
	local b = FlightPanelButtons
	if b.Move then b.Move.Text = "移动控制：" .. (Misc.FlightMoveControl and "开启" or "关闭") end
	if b.View then b.View.Text = "视角控制：" .. (Misc.FlightViewControl and "开启" or "关闭") end
	if b.HeightLock then b.HeightLock.Text = "高度锁定：" .. (Misc.FlightHeightLock and "开启" or "关闭") end
	if b.Stats then
		b.Stats.Text = "飞行速度：" .. tostring(Misc.FlightV1Speed)
			.. "\n目标高度偏移：" .. tostring(Misc.FlightV1Height)
			.. "\n高度锁定：" .. (Misc.FlightHeightLock and "开启" or "关闭")
	end
	if b.SpeedInput and not b.SpeedInput:IsFocused() then
		b.SpeedInput.Text = tostring(Misc.FlightV1Speed)
	end
	if b.HeightInput and not b.HeightInput:IsFocused() then
		b.HeightInput.Text = tostring(Misc.FlightV1Height)
	end
	for _, spec in pairs(b.Sliders or {}) do
		local value = tonumber(spec.Get()) or spec.Min
		local alpha = math.clamp((value - spec.Min) / (spec.Max - spec.Min), 0, 1)
		if spec.Knob and spec.Track then
			spec.Knob.Position = UDim2.new(alpha, 0, 0.5, 0)
		end
		if spec.Label then
			spec.Label.Text = spec.Title .. "：" .. tostring(value)
		end
	end
	local scale = math.clamp(tonumber(Misc.FlightPanelScale) or 0.65, 0.35, 1)
	if FlightPanelScaleObject then FlightPanelScaleObject.Scale = scale end
	if b.ScaleLabel then b.ScaleLabel.Text = "子 UI 大小：" .. tostring(math.floor(scale * 100 + 0.5)) .. "%" end
	if b.ScaleKnob and b.ScaleTrack then
		local alpha = (scale - 0.35) / 0.65
		b.ScaleKnob.Position = UDim2.new(alpha, 0, 0.5, 0)
	end
end

-- 锁高只控制目标 Y，不会禁用视角控制或手动升降。
-- 已经锁定时不重复重设 BaseY，避免拖动滑块期间目标高度不断漂移。
local function lockFlightAtCurrentHeight(forceRebase)
	local root = getFlightRoot()
	if root and FlightRuntime.Mode and (not Misc.FlightHeightLock or forceRebase) then
		FlightRuntime.BaseY = root.Position.Y - (tonumber(Misc.FlightV1Height) or 0)
	end
	Misc.FlightHeightLock = true
end

local function setFlightV1Speed(value)
	local number = tonumber(value)
	if not number or number ~= number or number == math.huge or number == -math.huge then
		notify("飞行速度", "请输入有效数字（1～500）。", "alert-triangle", 3)
		refreshFlightPanel()
		return false
	end
	Misc.FlightV1Speed = math.clamp(math.floor(number + 0.5), 1, 500)
	refreshFlightPanel()
	return true
end

local function setFlightHeightOffset(value)
	local number = tonumber(value)
	if not number or number ~= number or number == math.huge or number == -math.huge then
		notify("目标高度偏移", "请输入有效数字（-10000～10000）。", "alert-triangle", 3)
		refreshFlightPanel()
		return false
	end
	if not Misc.FlightHeightLock then
		lockFlightAtCurrentHeight()
	end
	-- 输入框支持一位小数；滑块以整数单位调整。
	local scaled = number * 10
	if scaled >= 0 then
		number = math.floor(scaled + 0.5) / 10
	else
		number = math.ceil(scaled - 0.5) / 10
	end
	Misc.FlightV1Height = math.clamp(number, -10000, 10000)
	Misc.FlightHeightLock = true
	refreshFlightPanel()
	return true
end

local function createFlightPanel()
	local parent
	pcall(function() if type(gethui) == "function" then parent = gethui() end end)
	if not parent then pcall(function() parent = LocalPlayer:WaitForChild("PlayerGui") end) end
	if not parent then pcall(function() parent = game:GetService("CoreGui") end) end
	assert(parent, "找不到飞行控制面板的 UI 容器")

	disconnectFlightPanelConnections()
	local old = parent:FindFirstChild("NeumorphFlightV1Panel")
	if old then old:Destroy() end
	FlightPanelButtons = {}

	local gui = Instance.new("ScreenGui")
	gui.Name = "NeumorphFlightV1Panel"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 10001
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = true
	gui.Parent = parent
	FlightPanelGui = gui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(1, 1)
	panel.Position = UDim2.new(1, -18, 1, -18)
	panel.Size = UDim2.fromOffset(420, 490)
	panel.BackgroundColor3 = Color3.fromRGB(27, 31, 39)
	panel.BackgroundTransparency = 0.06
	panel.BorderSizePixel = 0
	panel.Visible = true
	panel.ZIndex = 10
	panel.Parent = gui
	FlightPanel = panel
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(85, 101, 135)
	stroke.Transparency = 0.25
	stroke.Thickness = 1
	stroke.Parent = panel

	local scaleObject = Instance.new("UIScale")
	scaleObject.Scale = math.clamp(tonumber(Misc.FlightPanelScale) or 0.65, 0.35, 1)
	scaleObject.Parent = panel
	FlightPanelScaleObject = scaleObject

	-- 顶栏可拖动；最小化与关闭都只隐藏界面，不销毁 ScreenGui 或控制状态。
	local dragBar = Instance.new("Frame")
	dragBar.Name = "DragBar"
	dragBar.BackgroundTransparency = 1
	dragBar.Position = UDim2.fromOffset(0, 0)
	dragBar.Size = UDim2.new(1, 0, 0, 40)
	dragBar.Active = true
	dragBar.ZIndex = 11
	dragBar.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(14, 5)
	title.Size = UDim2.new(1, -94, 0, 30)
	title.Font = Enum.Font.GothamBold
	title.Text = "飞行控制面板"
	title.TextSize = 17
	title.TextColor3 = Color3.fromRGB(240, 243, 250)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Active = false
	title.ZIndex = 12
	title.Parent = dragBar

	local function makeTopButton(name, text, x, callback)
		local button = Instance.new("TextButton")
		button.Name = name
		button.Position = UDim2.new(1, x, 0, 6)
		button.Size = UDim2.fromOffset(30, 28)
		button.BackgroundColor3 = Color3.fromRGB(60, 67, 82)
		button.BorderSizePixel = 0
		button.Font = Enum.Font.GothamBold
		button.Text = text
		button.TextSize = 18
		button.TextColor3 = Color3.new(1, 1, 1)
		button.ZIndex = 13
		button.Parent = dragBar
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 8)
		c.Parent = button
		table.insert(FlightPanelConnections, button.Activated:Connect(callback))
		FlightPanelButtons[name] = button
		return button
	end

	local mini
	local function minimizePanel()
		-- 每次最小化都主动校验图标父级、显示状态、层级和显示顺序。
		gui.Enabled = true
		gui.DisplayOrder = 10001
		if mini and mini.Parent ~= gui then mini.Parent = gui end
		if mini then
			mini.Text = "FLY"
			mini.Visible = true
			mini.ZIndex = 200
		end
		panel.Visible = false
	end
	local function closePanel()
		-- 关闭只隐藏窗口；不会 Destroy，主界面的“打开飞行控制面板”仍可恢复。
		panel.Visible = false
		if mini then mini.Visible = false end
		gui.Enabled = true
	end
	makeTopButton("Minimize", "—", -76, minimizePanel)
	makeTopButton("Close", "×", -40, closePanel)

	local hint = Instance.new("TextLabel")
	hint.BackgroundTransparency = 1
	hint.Position = UDim2.fromOffset(12, 42)
	hint.Size = UDim2.new(1, -24, 0, 30)
	hint.Font = Enum.Font.Gotham
	hint.Text = "WASD / 摇杆移动；锁定高度时也可通过升降按钮、滑块或输入框改变目标高度。"
	hint.TextWrapped = true
	hint.TextSize = 11
	hint.TextColor3 = Color3.fromRGB(175, 185, 202)
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.ZIndex = 12
	hint.Parent = panel

	local function makeButton(key, text, x, y, width, callback)
		local button = Instance.new("TextButton")
		button.Name = key
		button.Position = UDim2.fromOffset(x, y)
		button.Size = UDim2.fromOffset(width, 34)
		button.BackgroundColor3 = Color3.fromRGB(48, 56, 70)
		button.BorderSizePixel = 0
		button.AutoButtonColor = true
		button.Font = Enum.Font.GothamSemibold
		button.Text = text
		button.TextSize = 12
		button.TextColor3 = Color3.fromRGB(238, 242, 250)
		button.ZIndex = 12
		button.Parent = panel
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 8)
		c.Parent = button
		table.insert(FlightPanelConnections, button.Activated:Connect(callback))
		FlightPanelButtons[key] = button
		return button
	end

	local function makeLabel(key, text, y)
		local label = Instance.new("TextLabel")
		label.Name = key
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromOffset(12, y)
		label.Size = UDim2.new(1, -24, 0, 18)
		label.Font = Enum.Font.GothamSemibold
		label.Text = text
		label.TextSize = 12
		label.TextColor3 = Color3.fromRGB(220, 226, 238)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.ZIndex = 12
		label.Parent = panel
		return label
	end

	local function makeInput(key, placeholder, x, y, width, callback)
		local input = Instance.new("TextBox")
		input.Name = key
		input.Position = UDim2.fromOffset(x, y)
		input.Size = UDim2.fromOffset(width, 30)
		input.BackgroundColor3 = Color3.fromRGB(38, 45, 58)
		input.BorderSizePixel = 0
		input.ClearTextOnFocus = false
		input.Font = Enum.Font.Gotham
		input.Text = ""
		input.PlaceholderText = placeholder
		input.PlaceholderColor3 = Color3.fromRGB(140, 151, 172)
		input.TextColor3 = Color3.fromRGB(245, 247, 252)
		input.TextSize = 12
		input.TextXAlignment = Enum.TextXAlignment.Center
		input.ZIndex = 13
		input.Parent = panel
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 7)
		c.Parent = input
		table.insert(FlightPanelConnections, input.FocusLost:Connect(function()
			callback(input.Text)
		end))
		return input
	end

	local function makeSlider(key, titleText, y, minimum, maximum, getter, setter)
		local label = makeLabel(key .. "Label", titleText, y)
		local track = Instance.new("Frame")
		track.Name = key .. "Track"
		track.Position = UDim2.fromOffset(12, y + 22)
		track.Size = UDim2.new(1, -24, 0, 8)
		track.BackgroundColor3 = Color3.fromRGB(65, 74, 91)
		track.BorderSizePixel = 0
		track.Active = true
		track.ZIndex = 12
		track.Parent = panel
		local trackCorner = Instance.new("UICorner")
		trackCorner.CornerRadius = UDim.new(1, 0)
		trackCorner.Parent = track
		local knob = Instance.new("Frame")
		knob.Name = key .. "Knob"
		knob.AnchorPoint = Vector2.new(0.5, 0.5)
		knob.Size = UDim2.fromOffset(16, 16)
		knob.BackgroundColor3 = Color3.fromRGB(125, 145, 255)
		knob.BorderSizePixel = 0
		knob.Active = true
		knob.ZIndex = 14
		knob.Parent = track
		local knobCorner = Instance.new("UICorner")
		knobCorner.CornerRadius = UDim.new(1, 0)
		knobCorner.Parent = knob
		local spec = {
			Title = titleText, Min = minimum, Max = maximum,
			Get = getter, Set = setter, Track = track, Knob = knob, Label = label,
		}
		FlightPanelButtons.Sliders[key] = spec
		return spec
	end

	makeButton("Move", "移动控制：开启", 12, 78, 194, function()
		Misc.FlightMoveControl = not Misc.FlightMoveControl
		refreshFlightPanel()
	end)
	makeButton("View", "视角控制：开启", 214, 78, 194, function()
		Misc.FlightViewControl = not Misc.FlightViewControl
		refreshFlightPanel()
	end)
	makeButton("AscendOnce", "上升一次 +5", 12, 118, 194, function()
		setFlightHeightOffset((tonumber(Misc.FlightV1Height) or 0) + 5)
	end)
	makeButton("DescendOnce", "下降一次 -5", 214, 118, 194, function()
		setFlightHeightOffset((tonumber(Misc.FlightV1Height) or 0) - 5)
	end)

	FlightPanelButtons.Sliders = {}
	makeSlider("Speed", "飞行速度", 160, 1, 500,
		function() return Misc.FlightV1Speed end,
		function(value) setFlightV1Speed(value) end)
	local speedInput = makeInput("SpeedInput", "输入 1～500", 12, 205, 174, setFlightV1Speed)
	FlightPanelButtons.SpeedInput = speedInput
	makeButton("SpeedDown", "速度 -1", 194, 203, 103, function()
		setFlightV1Speed((tonumber(Misc.FlightV1Speed) or 50) - 1)
	end)
	makeButton("SpeedUp", "速度 +1", 305, 203, 103, function()
		setFlightV1Speed((tonumber(Misc.FlightV1Speed) or 50) + 1)
	end)

	makeSlider("Height", "目标高度偏移（滑块范围 -1000～1000）", 244, -1000, 1000,
		function() return Misc.FlightV1Height end,
		function(value) setFlightHeightOffset(value) end)
	local heightInput = makeInput("HeightInput", "输入 -10000～10000", 12, 289, 174, setFlightHeightOffset)
	FlightPanelButtons.HeightInput = heightInput
	makeButton("HeightDown", "偏移 -1", 194, 287, 103, function()
		setFlightHeightOffset((tonumber(Misc.FlightV1Height) or 0) - 1)
	end)
	makeButton("HeightUp", "偏移 +1", 305, 287, 103, function()
		setFlightHeightOffset((tonumber(Misc.FlightV1Height) or 0) + 1)
	end)

	makeButton("HeightLock", "高度锁定：开启", 12, 327, 396, function()
		if Misc.FlightHeightLock then
			Misc.FlightHeightLock = false
		else
			lockFlightAtCurrentHeight(true)
		end
		refreshFlightPanel()
	end)

	local scaleLabel = makeLabel("ScaleLabel", "子 UI 大小：65%", 371)
	FlightPanelButtons.ScaleLabel = scaleLabel
	local scaleTrack = Instance.new("Frame")
	scaleTrack.Name = "ScaleTrack"
	scaleTrack.Position = UDim2.fromOffset(12, 395)
	scaleTrack.Size = UDim2.new(1, -24, 0, 8)
	scaleTrack.BackgroundColor3 = Color3.fromRGB(65, 74, 91)
	scaleTrack.BorderSizePixel = 0
	scaleTrack.Active = true
	scaleTrack.ZIndex = 12
	scaleTrack.Parent = panel
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = scaleTrack
	local scaleKnob = Instance.new("Frame")
	scaleKnob.Name = "ScaleKnob"
	scaleKnob.AnchorPoint = Vector2.new(0.5, 0.5)
	scaleKnob.Size = UDim2.fromOffset(16, 16)
	scaleKnob.BackgroundColor3 = Color3.fromRGB(125, 145, 255)
	scaleKnob.BorderSizePixel = 0
	scaleKnob.Active = true
	scaleKnob.ZIndex = 14
	scaleKnob.Parent = scaleTrack
	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = scaleKnob
	FlightPanelButtons.ScaleTrack = scaleTrack
	FlightPanelButtons.ScaleKnob = scaleKnob

	local stats = Instance.new("TextLabel")
	stats.Name = "FlightStats"
	stats.BackgroundTransparency = 1
	stats.Position = UDim2.fromOffset(12, 417)
	stats.Size = UDim2.new(1, -24, 0, 62)
	stats.Font = Enum.Font.Gotham
	stats.Text = "飞行速度：50\n目标高度偏移：0\n高度锁定：开启"
	stats.TextSize = 12
	stats.TextColor3 = Color3.fromRGB(200, 209, 224)
	stats.TextXAlignment = Enum.TextXAlignment.Left
	stats.TextYAlignment = Enum.TextYAlignment.Center
	stats.ZIndex = 12
	stats.Parent = panel
	FlightPanelButtons.Stats = stats

	-- 固定创建并置顶悬浮按钮；最小化时不会依赖重新创建，因此不会偶发丢图标。
	mini = Instance.new("TextButton")
	mini.Name = "FlightMiniButton"
	mini.AnchorPoint = Vector2.new(1, 1)
	mini.Position = UDim2.new(1, -18, 1, -18)
	mini.Size = UDim2.fromOffset(58, 48)
	mini.BackgroundColor3 = Color3.fromRGB(48, 58, 83)
	mini.BorderSizePixel = 0
	mini.Font = Enum.Font.GothamBold
	mini.Text = "FLY"
	mini.TextSize = 16
	mini.TextColor3 = Color3.fromRGB(245, 248, 255)
	mini.Visible = false
	mini.Active = true
	mini.AutoButtonColor = true
	mini.ZIndex = 200
	mini.Parent = gui
	local miniCorner = Instance.new("UICorner")
	miniCorner.CornerRadius = UDim.new(0, 14)
	miniCorner.Parent = mini
	local miniStroke = Instance.new("UIStroke")
	miniStroke.Color = Color3.fromRGB(125, 145, 255)
	miniStroke.Thickness = 1.5
	miniStroke.Parent = mini
	FlightPanelMiniButton = mini

	local function registerDrag(handle, target, clickCallback)
		local dragging = false
		local moved = false
		local dragInputType = nil
		local dragStart, startPosition
		table.insert(FlightPanelConnections, handle.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				moved = false
				dragInputType = input.UserInputType
				dragStart = input.Position
				startPosition = target.Position
			end
		end))
		table.insert(FlightPanelConnections, UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local delta = input.Position - dragStart
				if delta.Magnitude > 5 then moved = true end
				target.Position = UDim2.new(
					startPosition.X.Scale, startPosition.X.Offset + delta.X,
					startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
				)
			end
		end))
		table.insert(FlightPanelConnections, UserInputService.InputEnded:Connect(function(input)
			local isEnd = input.UserInputType == Enum.UserInputType.MouseButton1
				or (dragInputType == Enum.UserInputType.Touch and input.UserInputType == Enum.UserInputType.Touch)
			if dragging and isEnd then
				local shouldClick = not moved
				dragging = false
				dragInputType = nil
				if shouldClick and clickCallback then clickCallback() end
			end
		end))
	end

	local function showPanel()
		gui.Enabled = true
		gui.DisplayOrder = 10001
		panel.Visible = true
		mini.Visible = false
		refreshFlightPanel()
	end
	registerDrag(dragBar, panel)
	registerDrag(mini, mini, showPanel)

	-- 滑块支持鼠标与触摸拖动；高度锁定开着时，滑块也会更新目标 Y。
	local activeSlider = nil
	local scaleDragging = false
	local function setSliderFromX(key, x)
		local spec = FlightPanelButtons.Sliders[key]
		if not spec then return end
		local width = math.max(spec.Track.AbsoluteSize.X, 1)
		local alpha = math.clamp((x - spec.Track.AbsolutePosition.X) / width, 0, 1)
		local value = spec.Min + alpha * (spec.Max - spec.Min)
		if key == "Speed" then value = math.floor(value + 0.5) else value = math.floor(value + 0.5) end
		spec.Set(value)
	end
	for key, spec in pairs(FlightPanelButtons.Sliders) do
		local function beginSlider(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
			activeSlider = key
			setSliderFromX(key, input.Position.X)
		end
		table.insert(FlightPanelConnections, spec.Track.InputBegan:Connect(beginSlider))
		table.insert(FlightPanelConnections, spec.Knob.InputBegan:Connect(beginSlider))
	end
	local function setScaleFromX(x)
		local width = math.max(scaleTrack.AbsoluteSize.X, 1)
		local alpha = math.clamp((x - scaleTrack.AbsolutePosition.X) / width, 0, 1)
		Misc.FlightPanelScale = 0.35 + alpha * 0.65
		refreshFlightPanel()
	end
	local function beginScale(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
		scaleDragging = true
		setScaleFromX(input.Position.X)
	end
	table.insert(FlightPanelConnections, scaleTrack.InputBegan:Connect(beginScale))
	table.insert(FlightPanelConnections, scaleKnob.InputBegan:Connect(beginScale))
	table.insert(FlightPanelConnections, UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			if scaleDragging then
				setScaleFromX(input.Position.X)
			elseif activeSlider then
				setSliderFromX(activeSlider, input.Position.X)
			end
		end
	end))
	table.insert(FlightPanelConnections, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			activeSlider = nil
			scaleDragging = false
		end
	end))

	-- 关闭与最小化的回调已由 makeTopButton 注册。

	refreshFlightPanel()
	gui.Enabled = true
	return gui
end

local function openFlightPanel()
	if not FlightPanelGui or not FlightPanelGui.Parent or not FlightPanel or not FlightPanel.Parent then
		local ok, err = pcall(createFlightPanel)
		if not ok then
			warn("[Neumorph] 飞行控制面板创建失败：" .. tostring(err))
			notify("飞行面板不可用", tostring(err), "alert-triangle", 4)
			return
		end
	end
	FlightPanelGui.Enabled = true
	FlightPanelGui.DisplayOrder = 10001
	refreshFlightPanel()
	FlightPanel.Visible = true
	if FlightPanelMiniButton then FlightPanelMiniButton.Visible = false end
end

-- 单独建立本地文件夹，方便一次性清理所有地图标记。
local function getWaypointFolder()
	if not WaypointState.Folder or not WaypointState.Folder.Parent then
		local folder = Instance.new("Folder")
		folder.Name = "NeumorphWaypoints_" .. tostring(LocalPlayer.UserId)
		folder.Parent = Workspace
		WaypointState.Folder = folder
	end
	return WaypointState.Folder
end

-- 在保存位置放置本地透明锚点，并通过 BillboardGui 显示“标点N”。
local function createWaypointVisual(index, savedCFrame)
	local anchor = Instance.new("Part")
	anchor.Name = "NeumorphWaypoint_" .. tostring(index)
	anchor.Anchored = true
	anchor.CanCollide = false
	pcall(function() anchor.CanTouch = false end)
	pcall(function() anchor.CanQuery = false end)
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = savedCFrame
	anchor.Parent = getWaypointFolder()

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "WaypointLabel"
	billboard.Adornee = anchor
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = 10000
	billboard.Size = UDim2.fromOffset(120, 34)
	billboard.StudsOffset = Vector3.new(0, 2.5, 0)
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundColor3 = Color3.fromRGB(28, 34, 48)
	label.BackgroundTransparency = 0.12
	label.BorderSizePixel = 0
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = "标点" .. tostring(index)
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextScaled = true
	label.TextStrokeTransparency = 0.65
	label.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 7)
	corner.Parent = label

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(125, 136, 255)
	stroke.Thickness = 1
	stroke.Transparency = 0.15
	stroke.Parent = label

	return anchor
end

local function teleportToWaypoint(point, quiet)
	if not point or typeof(point.CFrame) ~= "CFrame" then
		return false
	end

	local character = LocalPlayer.Character
	if not character or not character.Parent then
		if not quiet then notify("标点传送", "当前角色尚未加载。", "alert-triangle", 3) end
		return false
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		if not quiet then notify("标点传送", "未找到角色根部，无法传送。", "alert-triangle", 3) end
		return false
	end

	local ok, err = pcall(function()
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		root.CFrame = point.CFrame
	end)
	if not ok then
		if not quiet then notify("标点传送失败", tostring(err), "alert-triangle", 4) end
		return false
	end
	return true
end

-- 解析自定义坐标：首选空格分隔的 X Y Z；为兼容旧习惯，也保留逗号分隔输入。
local function parseCoordinateInput(value)
	if type(value) ~= "string" then
		return nil, "请先输入坐标，格式为 X Y Z，例如：100 25 -50。"
	end

	local normalized = value
		:gsub("，", ",")
		:gsub("、", ",")
		:gsub("；", ",")
		:gsub(";", ",")

	-- 新格式：三个数字之间用空格分隔。
	local xText, yText, zText = normalized:match(
		"^%s*([^,%s]+)%s+([^,%s]+)%s+([^,%s]+)%s*$"
	)
	-- 旧格式兼容：英文或中文逗号分隔。
	if not xText or not yText or not zText then
		xText, yText, zText = normalized:match(
			"^%s*([^,%s]+)%s*,%s*([^,%s]+)%s*,%s*([^,%s]+)%s*$"
		)
	end
	if not xText or not yText or not zText then
		return nil, "坐标格式不正确，请输入 X Y Z 三个数字，例如：100 25 -50。"
	end

	local x, y, z = tonumber(xText), tonumber(yText), tonumber(zText)
	local function validNumber(number)
		return number ~= nil and number == number
			and number ~= math.huge and number ~= -math.huge
	end
	if not validNumber(x) or not validNumber(y) or not validNumber(z) then
		return nil, "坐标必须是三个有效数字，例如：100 25 -50。"
	end

	return Vector3.new(x, y, z)
end

local function destroyAllWaypoints()
	WaypointState.LoopEnabled = false
	WaypointState.WalkEnabled = false
	if WaypointState.WalkToggle then
		pcall(function() WaypointState.WalkToggle:Set(false) end)
	end
	if WaypointState.LoopToggle then
		pcall(function() WaypointState.LoopToggle:Set(false) end)
	end

	-- WindUI 的 Destroy 会从父级元素数组中移除控件；动态控件必须倒序删除，
	-- 否则前面的控件被移除后，后续控件保存的数组索引会偏移。
	for i = #WaypointState.Points, 1, -1 do
		local point = WaypointState.Points[i]
		if point.Button then
			pcall(function() point.Button:Destroy() end)
		end
		if point.Visual then
			pcall(function() point.Visual:Destroy() end)
		end
	end
	WaypointState.Points = {}

	if WaypointState.Folder then
		pcall(function() WaypointState.Folder:Destroy() end)
		WaypointState.Folder = nil
	end
end

-- 自定义标点数值条：标题/说明沿用“开始标点行走”的文字层级；下方为减号、滑轨、加号和数值输入框。
-- 直接挂到 WindUI Section 的 Content 容器中，随分类滚动/折叠，不会成为屏幕外悬浮窗。
local function createWaypointValueRow(sectionProxy, config)
	local sectionFrame = sectionProxy and sectionProxy.ElementFrame
	local parent = sectionFrame and sectionFrame.Outline and sectionFrame.Outline:FindFirstChild("Content")
	assert(parent, "无法获取标点设置 Section 内容容器")

	local row = Instance.new("Frame")
	row.Name = config.Name or "WaypointValueRow"
	row.Size = UDim2.new(1, 0, 0, 108)
	-- 与上方“开始标点行走”开关卡片使用相同底色，避免数值条显得像独立深色面板。
	row.BackgroundColor3 = Color3.fromRGB(42, 47, 53)
	row.BackgroundTransparency = 0
	row.BorderSizePixel = 0
	row.LayoutOrder = 500 + (#parent:GetChildren())
	row.Parent = parent
	local rowCorner = Instance.new("UICorner")
	rowCorner.CornerRadius = UDim.new(0, 13)
	rowCorner.Parent = row
	local rowStroke = Instance.new("UIStroke")
	rowStroke.Color = Color3.fromRGB(58, 64, 74)
	rowStroke.Thickness = 1
	rowStroke.Transparency = 0.72
	rowStroke.Parent = row

	local title = Instance.new("TextLabel")
	title.Name = "ValueTitle"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 7)
	title.Size = UDim2.new(1, -32, 0, 22)
	title.Font = Enum.Font.GothamSemibold
	title.Text = tostring(config.Title or "数值调节")
	title.TextColor3 = Color3.fromRGB(245, 247, 252)
	title.TextSize = 18
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextYAlignment = Enum.TextYAlignment.Center
	title.Parent = row

	if config.Description and config.Description ~= "" then
		local description = Instance.new("TextLabel")
		description.Name = "ValueDescription"
		description.BackgroundTransparency = 1
		description.Position = UDim2.fromOffset(16, 30)
		description.Size = UDim2.new(1, -32, 0, 18)
		description.Font = Enum.Font.Gotham
		description.Text = tostring(config.Description)
		description.TextColor3 = Color3.fromRGB(185, 192, 204)
		description.TextSize = 14
		description.TextXAlignment = Enum.TextXAlignment.Left
		description.TextYAlignment = Enum.TextYAlignment.Center
		description.Parent = row
	end

	local function makeButton(name, text, x, width)
		local button = Instance.new("TextButton")
		button.Name = name
		button.Position = UDim2.new(0, x, 0, 56)
		button.Size = UDim2.new(0, width, 0, 44)
		button.BackgroundTransparency = 1
		button.BorderSizePixel = 0
		button.AutoButtonColor = true
		button.Font = Enum.Font.GothamMedium
		button.Text = text
		button.TextColor3 = Color3.fromRGB(245, 247, 252)
		button.TextSize = 29
		button.Parent = row
		return button
	end

	local minus = makeButton("Decrease", "−", 5, 42)
	local plus = Instance.new("TextButton")
	plus.Name = "Increase"
	plus.AnchorPoint = Vector2.new(1, 0)
	plus.Position = UDim2.new(1, -116, 0, 56)
	plus.Size = UDim2.new(0, 42, 0, 44)
	plus.BackgroundTransparency = 1
	plus.BorderSizePixel = 0
	plus.AutoButtonColor = true
	plus.Font = Enum.Font.GothamMedium
	plus.Text = "+"
	plus.TextColor3 = Color3.fromRGB(245, 247, 252)
	plus.TextSize = 29
	plus.Parent = row

	local input = Instance.new("TextBox")
	input.Name = "ValueInput"
	input.AnchorPoint = Vector2.new(1, 0)
	input.Position = UDim2.new(1, -10, 0, 56)
	input.Size = UDim2.new(0, 98, 0, 44)
	input.BackgroundColor3 = Color3.fromRGB(17, 19, 24)
	input.BorderSizePixel = 0
	input.ClearTextOnFocus = false
	input.Font = Enum.Font.Gotham
	input.Text = ""
	input.PlaceholderText = "数值"
	input.PlaceholderColor3 = Color3.fromRGB(125, 133, 148)
	input.TextColor3 = Color3.fromRGB(245, 247, 252)
	input.TextSize = 20
	input.TextXAlignment = Enum.TextXAlignment.Center
	input.Parent = row
	local inputCorner = Instance.new("UICorner")
	inputCorner.CornerRadius = UDim.new(0, 11)
	inputCorner.Parent = input

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.new(0, 55, 0, 73)
	track.Size = UDim2.new(1, -238, 0, 10)
	track.BackgroundColor3 = Color3.fromRGB(75, 82, 97)
	track.BorderSizePixel = 0
	track.Active = true
	track.Parent = row
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(224, 231, 250)
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.new(0, 0, 0.5, 0)
	knob.Size = UDim2.fromOffset(17, 17)
	knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	knob.BorderSizePixel = 0
	knob.Active = true
	knob.Parent = track
	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = knob
	local knobStroke = Instance.new("UIStroke")
	knobStroke.Color = Color3.fromRGB(135, 149, 190)
	knobStroke.Thickness = 1
	knobStroke.Parent = knob

	local minimum = tonumber(config.Min) or 0
	local maximum = tonumber(config.Max) or 100
	local step = tonumber(config.Step) or 1
	local buttonStep = tonumber(config.ButtonStep) or step
	local current = tonumber(config.Value) or minimum
	local dragging = false
	local dragInputType = nil
	local controller = {}

	local function quantize(value)
		value = math.clamp(tonumber(value) or current, minimum, maximum)
		local steps = math.floor(((value - minimum) / step) + 0.5)
		local result = minimum + steps * step
		local decimals = config.Decimals
		if decimals == nil then decimals = step < 1 and 1 or 0 end
		local multiplier = 10 ^ decimals
		return math.clamp(math.floor(result * multiplier + 0.5) / multiplier, minimum, maximum)
	end

	local function render(value)
		current = quantize(value)
		local alpha = maximum > minimum and math.clamp((current - minimum) / (maximum - minimum), 0, 1) or 0
		fill.Size = UDim2.new(alpha, 0, 1, 0)
		knob.Position = UDim2.new(alpha, 0, 0.5, 0)
		if not input:IsFocused() then
			input.Text = config.Format and config.Format(current) or tostring(current)
		end
	end

	local function commit(value)
		local parsed = tonumber(value)
		if not parsed or parsed ~= parsed or parsed == math.huge or parsed == -math.huge then
			notify(config.Title or "数值设置", config.InvalidMessage or "请输入有效数字。", "alert-triangle", 3)
			render(current)
			return
		end
		parsed = quantize(parsed)
		if config.Callback then config.Callback(parsed) end
		render(parsed)
	end

	local function updateFromX(x)
		local width = track.AbsoluteSize.X
		if width <= 1 then return end
		local alpha = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
		commit(minimum + alpha * (maximum - minimum))
	end

	minus.Activated:Connect(function() commit(current - buttonStep) end)
	plus.Activated:Connect(function() commit(current + buttonStep) end)
	input.FocusLost:Connect(function() commit(input.Text) end)
	local function beginDrag(inputObject)
		local kind = inputObject.UserInputType
		if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then return end
		dragging = true
		dragInputType = kind
		updateFromX(inputObject.Position.X)
	end
	track.InputBegan:Connect(beginDrag)
	knob.InputBegan:Connect(beginDrag)
	table.insert(connections, UserInputService.InputChanged:Connect(function(inputObject)
		if dragging and (inputObject.UserInputType == Enum.UserInputType.MouseMovement or inputObject.UserInputType == Enum.UserInputType.Touch) then
			updateFromX(inputObject.Position.X)
		end
	end))
	table.insert(connections, UserInputService.InputEnded:Connect(function(inputObject)
		local ended = inputObject.UserInputType == Enum.UserInputType.MouseButton1
			or (dragInputType == Enum.UserInputType.Touch and inputObject.UserInputType == Enum.UserInputType.Touch)
		if dragging and ended then
			dragging = false
			dragInputType = nil
		end
	end))

	function controller:Set(value)
		render(value)
	end
	function controller:Get()
		return current
	end
	function controller:Destroy()
		if row and row.Parent then row:Destroy() end
	end
	render(current)
	return controller
end

local function setWaypointInterval(value, updateInput)
	local parsed = tonumber(value)
	if not parsed then
		if not updateInput then notify("间隔设置", "请输入有效数字，例如 1 或 0.5。", "alert-triangle", 3) end
		parsed = WaypointState.LoopInterval
	end
	parsed = math.clamp(parsed, 0.1, 60)
	parsed = math.floor(parsed * 10 + 0.5) / 10
	WaypointState.LoopInterval = parsed
	if WaypointState.IntervalRow then pcall(function() WaypointState.IntervalRow:Set(parsed) end) end
end

local function setWaypointRate(value, updateInput)
	local parsed = tonumber(value)
	if not parsed then
		if not updateInput then notify("循环速度", "请输入有效数字，例如 1 或 2.5。", "alert-triangle", 3) end
		parsed = WaypointState.LoopRate
	end
	parsed = math.clamp(parsed, 0.1, 20)
	parsed = math.floor(parsed * 10 + 0.5) / 10
	WaypointState.LoopRate = parsed
	if WaypointState.RateRow then pcall(function() WaypointState.RateRow:Set(parsed) end) end
end

local function setWaypointWalkSpeed(value, updateInput)
	local parsed = tonumber(value)
	if not parsed then
		if not updateInput then notify("行走速度", "请输入有效数字。", "alert-triangle", 3) end
		parsed = WaypointState.WalkSpeed
	end
	parsed = math.clamp(parsed, 4, 100)
	parsed = math.floor(parsed + 0.5)
	WaypointState.WalkSpeed = parsed
	if WaypointState.WalkSpeedRow then pcall(function() WaypointState.WalkSpeedRow:Set(parsed) end) end
end

-- 使用 Humanoid:MoveTo / Pathfinding 行走，不修改角色坐标。
local function walkToWaypoint(point)
	if not point or typeof(point.CFrame) ~= "CFrame" then return false end
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then return false end

	humanoid.WalkSpeed = WaypointState.WalkSpeed
	local destination = point.CFrame.Position
	local path
	local computed = pcall(function()
		path = PathfindingService:CreatePath({
			AgentRadius = 2,
			AgentHeight = 5,
			AgentCanJump = true,
			WaypointSpacing = 4,
		})
		path:ComputeAsync(root.Position, destination)
	end)

	local nodes = {}
	if computed and path and path.Status == Enum.PathStatus.Success then
		nodes = path:GetWaypoints()
	else
		-- 地图没有导航网格或寻路失败时，仍尝试 Humanoid 正常行走到目标点。
		nodes = {{ Position = destination, Action = Enum.PathWaypointAction.Walk }}
	end

	for _, node in ipairs(nodes) do
		if not running or not WaypointState.WalkEnabled then return false end
		if not root.Parent or not humanoid.Parent or humanoid.Health <= 0 then return false end

		humanoid.WalkSpeed = WaypointState.WalkSpeed
		if node.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end

		local reached = false
		local moveConnection = humanoid.MoveToFinished:Connect(function(success)
			if success then reached = true end
		end)
		-- 先连接 MoveToFinished 再调用 MoveTo，避免近距离目标先完成导致漏接事件。
		humanoid:MoveTo(node.Position)

		local distance = (root.Position - node.Position).Magnitude
		local timeout = math.max(8, (distance / math.max(4, WaypointState.WalkSpeed)) * 3 + 5)
		local deadline = os.clock() + timeout
		while running and WaypointState.WalkEnabled and not reached and os.clock() < deadline do
			task.wait(0.05)
			if root.Parent and (root.Position - node.Position).Magnitude <= 3 then
				reached = true
			end
		end
		moveConnection:Disconnect()
		if not reached then return false end
	end

	return (root.Position - destination).Magnitude <= 5
end

task.spawn(function()
	while running do
		if not WaypointState.WalkEnabled then
			task.wait(0.1)
		else
			local count = #WaypointState.Points
			if count == 0 then
				WaypointState.WalkEnabled = false
				if WaypointState.WalkToggle then pcall(function() WaypointState.WalkToggle:Set(false) end) end
				notify("标点行走已停止", "没有可用标点，请先定位坐标。", "alert-triangle", 3)
			else
				for i = 1, count do
					if not running or not WaypointState.WalkEnabled then break end
					local point = WaypointState.Points[i]
					if point and not walkToWaypoint(point) then
						if WaypointState.WalkEnabled then notify("标点行走", "前往 " .. point.Name .. " 失败，已停止。", "alert-triangle", 3) end
						WaypointState.WalkEnabled = false
						if WaypointState.WalkToggle then pcall(function() WaypointState.WalkToggle:Set(false) end) end
						break
					end
				end
				if WaypointState.WalkEnabled then
					WaypointState.WalkEnabled = false
					if WaypointState.WalkToggle then pcall(function() WaypointState.WalkToggle:Set(false) end) end
					notify("标点行走完成", "已按顺序走到最后一个标点。", "check", 3)
				end
			end
		end
	end
end)

-- 循环按 1 → 最后一个标点的顺序传送，到末尾后重新从 1 开始。
task.spawn(function()
	while running do
		if not WaypointState.LoopEnabled then
			task.wait(0.1)
		else
			local index = 1
			while running and WaypointState.LoopEnabled do
				local pointCount = #WaypointState.Points
				if pointCount == 0 then
					WaypointState.LoopEnabled = false
					if WaypointState.LoopToggle then
						pcall(function() WaypointState.LoopToggle:Set(false) end)
					end
					notify("循环传送已停止", "当前没有可用标点，请先定位坐标。", "info", 3)
					break
				end

				if index > pointCount then
					-- 一轮全部标点完成后，才执行“循环间隔”设置。
					local roundWaitUntil = os.clock() + WaypointState.LoopInterval
					while running and WaypointState.LoopEnabled and os.clock() < roundWaitUntil do
						task.wait(math.min(0.05, math.max(0.01, roundWaitUntil - os.clock())))
					end
					index = 1
				else
					local point = WaypointState.Points[index]
					if point and not teleportToWaypoint(point, true) then
						WaypointState.LoopEnabled = false
						if WaypointState.LoopToggle then
							pcall(function() WaypointState.LoopToggle:Set(false) end)
						end
						notify("循环传送已停止", "传送到 " .. point.Name .. " 失败，请确认角色已加载。", "alert-triangle", 4)
						break
					end

					-- b 表示每秒传送 b 个标点，所以相邻标点的间隔为 1/b 秒。
					local rateDelay = 1 / math.max(0.1, WaypointState.LoopRate)
					local waitUntil = os.clock() + rateDelay
					while running and WaypointState.LoopEnabled and os.clock() < waitUntil do
						task.wait(math.min(0.05, math.max(0.01, waitUntil - os.clock())))
					end
					index = index + 1
				end
			end
		end
	end
end)

-- ============================================================
-- 5. UI 辅助（来自之前对话的间距修复）
-- ============================================================
local pendingSections = {}
local tabKeys = setmetatable({}, { __mode = "k" })
local trackedControls = {}

-- 在相邻 Section 之间强制占位，首次打开不塌陷
local function gap(tab)
	pcall(function() tab:Space() end)
end

-- Section 先折叠，首帧渲染后再展开；代理对象同时记录控件引用，供配置加载时同步 UI。
local function section(tab, opts)
	opts = opts or {}
	local shouldOpen = opts.Opened == true
	opts.Opened = false
	local s = tab:Section(opts)
	if shouldOpen then
		table.insert(pendingSections, s)
	end
	local tabKey = tabKeys[tab]
	return setmetatable({}, {
		__index = function(_, methodName)
			local method = s[methodName]
			if type(method) ~= "function" then return method end
			return function(_, config)
				local result = method(s, config)
				if tabKey and type(config) == "table" and config.Title and result then
					trackedControls[tabKey .. "|" .. tostring(config.Title)] = result
				end
				return result
			end
		end,
	})
end

-- ============================================================
-- 6. 通用工具
-- ============================================================
local function worldToScreen(position)
	local cam = Workspace.CurrentCamera
	if not cam then return nil end
	local screen, onScreen = cam:WorldToViewportPoint(position)
	if screen.Z <= 0 then return nil end
	return Vector2.new(screen.X, screen.Y), onScreen
end

local GREEN = Color3.fromRGB(80, 225, 130)
local RED = Color3.fromRGB(255, 85, 85)
local BLUE = Color3.fromRGB(140, 160, 255)

local function healthColor(frac)
	return Color3.fromRGB(255, 90, 90):Lerp(Color3.fromRGB(90, 235, 130), frac)
end

-- ============================================================
-- 7. 穿墙 / 其他功能引擎
-- ============================================================
local function applyNoclip(char)
	if not char then return end
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") then
			if noclipSaved[part] == nil then noclipSaved[part] = part.CanCollide end
			if part.CanCollide then part.CanCollide = false end
		end
	end
end

local function restoreNoclip()
	for part, originalCanCollide in pairs(noclipSaved) do
		pcall(function()
			if part and part.Parent then part.CanCollide = originalCanCollide == true end
		end)
	end
	noclipSaved = {}
end

local function restoreFlightHumanoid()
	local hum = FlightRuntime.Humanoid
	if hum and hum.Parent then
		pcall(function()
			hum.AutoRotate = FlightRuntime.SavedAutoRotate ~= false
			hum.WalkSpeed = WaypointState.WalkEnabled and WaypointState.WalkSpeed
				or (Misc.NoclipOn and Misc.NoclipSpeed)
				or (Misc.SpeedOn and Misc.Speed)
				or FlightRuntime.SavedWalkSpeed
				or 16
			hum.UseJumpPower = Misc.JumpOn or FlightRuntime.SavedUseJumpPower == true
			hum.JumpPower = Misc.JumpOn and Misc.JumpPower or FlightRuntime.SavedJumpPower or 50
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	end
end

destroyFlightPhysics = function(restoreHumanoid)
	if FlightRuntime.Velocity then pcall(function() FlightRuntime.Velocity:Destroy() end) end
	if FlightRuntime.Gyro then pcall(function() FlightRuntime.Gyro:Destroy() end) end
	FlightRuntime.Velocity, FlightRuntime.Gyro = nil, nil
	if restoreHumanoid then restoreFlightHumanoid() end
	FlightRuntime.Root, FlightRuntime.Humanoid = nil, nil
	FlightRuntime.SavedAutoRotate, FlightRuntime.SavedWalkSpeed = nil, nil
	FlightRuntime.SavedJumpPower, FlightRuntime.SavedUseJumpPower = nil, nil
end

local function isKeyDown(keyCode)
	local ok, value = pcall(function() return UserInputService:IsKeyDown(keyCode) end)
	return ok and value == true
end

local function updateFlightPhysics()
	local mode = flightModeFromSettings()
	if not mode then
		if FlightRuntime.Mode then
			destroyFlightPhysics(true)
			FlightRuntime.Mode = nil
			if not Misc.NoclipOn then restoreNoclip() end
		end
		return
	end

	if FlightRuntime.Mode ~= mode then
		destroyFlightPhysics(true)
		FlightRuntime.Mode = mode
	end

	local char = LocalPlayer.Character
	local hum = getHumanoid()
	local root = getFlightRoot()
	if not char or not hum or hum.Health <= 0 or not root then
		destroyFlightPhysics(true)
		return
	end

	if FlightRuntime.Root ~= root or not FlightRuntime.Velocity or not FlightRuntime.Gyro
		or not FlightRuntime.Velocity.Parent or not FlightRuntime.Gyro.Parent then
		destroyFlightPhysics(true)
		FlightRuntime.Root = root
		FlightRuntime.Humanoid = hum
		-- 重新进入飞行模式或角色重生时，以当前位置作为新的锁高基准，
		-- 保留已有偏移值但不重复触发上一次的升降动作。
		FlightRuntime.BaseY = root.Position.Y - (Misc.FlightHeightLock and (tonumber(Misc.FlightV1Height) or 0) or 0)
		FlightRuntime.SavedAutoRotate = hum.AutoRotate
		FlightRuntime.SavedWalkSpeed = hum.WalkSpeed
		FlightRuntime.SavedJumpPower = hum.JumpPower
		FlightRuntime.SavedUseJumpPower = hum.UseJumpPower
		local velocity = Instance.new("BodyVelocity")
		velocity.Name = "NeumorphFlightVelocity"
		velocity.MaxForce = Vector3.new(100000000, 100000000, 100000000)
		velocity.P = 25000
		velocity.Velocity = Vector3.zero
		velocity.Parent = root
		local gyro = Instance.new("BodyGyro")
		gyro.Name = "NeumorphFlightGyro"
		gyro.MaxTorque = Vector3.new(100000000, 100000000, 100000000)
		gyro.P = 90000
		gyro.D = 1200
		gyro.CFrame = Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame or root.CFrame
		gyro.Parent = root
		FlightRuntime.Velocity, FlightRuntime.Gyro = velocity, gyro
		pcall(function() hum:ChangeState(Enum.HumanoidStateType.Freefall) end)
	end

	hum.AutoRotate = false
	hum.WalkSpeed = 0

	local camera = Workspace.CurrentCamera
	if not camera then return end
	local look = camera.CFrame.LookVector
	local right = camera.CFrame.RightVector
	local forwardFlat = Vector3.new(look.X, 0, look.Z)
	local rightFlat = Vector3.new(right.X, 0, right.Z)
	if forwardFlat.Magnitude > 0.001 then forwardFlat = forwardFlat.Unit end
	if rightFlat.Magnitude > 0.001 then rightFlat = rightFlat.Unit end

	local forwardAmount, strafeAmount = 0, 0
	if Misc.FlightMoveControl then
		local forwardInput = (isKeyDown(Enum.KeyCode.W) or isKeyDown(Enum.KeyCode.Up)) and 1 or 0
		local backInput = (isKeyDown(Enum.KeyCode.S) or isKeyDown(Enum.KeyCode.Down)) and 1 or 0
		local rightInput = (isKeyDown(Enum.KeyCode.D) or isKeyDown(Enum.KeyCode.Right)) and 1 or 0
		local leftInput = (isKeyDown(Enum.KeyCode.A) or isKeyDown(Enum.KeyCode.Left)) and 1 or 0
		forwardAmount = forwardInput - backInput
		strafeAmount = rightInput - leftInput

		-- 移动端沿用 Roblox 虚拟摇杆方向；键盘输入优先，并分解出前后/左右量，
		-- 这样摇杆前进时也能根据镜头俯仰执行升降。
		if math.abs(forwardAmount) < 0.01 and math.abs(strafeAmount) < 0.01
			and hum.MoveDirection.Magnitude > 0.01 then
			local moveDirection = hum.MoveDirection
			if forwardFlat.Magnitude > 0.001 then
				forwardAmount = moveDirection:Dot(forwardFlat)
			else
				-- 镜头接近垂直时水平前向向量退化，仍允许摇杆输入驱动镜头方向升降。
				forwardAmount = moveDirection.Magnitude
			end
			if rightFlat.Magnitude > 0.001 then
				strafeAmount = moveDirection:Dot(rightFlat)
			end
		end
	end

	local inputMagnitude = math.sqrt(forwardAmount * forwardAmount + strafeAmount * strafeAmount)
	if inputMagnitude > 1 then
		forwardAmount = forwardAmount / inputMagnitude
		strafeAmount = strafeAmount / inputMagnitude
	end

	local speed = getFlightSpeed(mode)
	local pitch = math.clamp(look.Y, -1, 1)
	local followViewPitch = Misc.FlightViewControl == true and math.abs(pitch) > 0.02
	local verticalFromView = followViewPitch and (pitch * forwardAmount * speed) or 0
	local forwardHorizontalScale = followViewPitch and math.sqrt(math.max(0, 1 - pitch * pitch)) or 1
	local horizontal = forwardFlat * (forwardAmount * forwardHorizontalScale)
		+ rightFlat * strafeAmount
	if horizontal.Magnitude > 1 then horizontal = horizontal.Unit end

	-- 高度锁定负责稳定当前高度，但不再屏蔽镜头俯仰产生的垂直移动：
	-- 前进时镜头向上就上升，镜头向下就下降；镜头回平或停止前进后，
	-- 将当前位置更新为新的锁高基准，避免锁高把角色拉回旧高度。
	local vertical = 0
	local applyVerticalForce = false
	if followViewPitch and math.abs(forwardAmount) > 0.01 then
		vertical = verticalFromView
		applyVerticalForce = true
		if Misc.FlightHeightLock then
			FlightRuntime.BaseY = root.Position.Y - (tonumber(Misc.FlightV1Height) or 0)
		end
	elseif Misc.FlightHeightLock then
		local targetY = FlightRuntime.BaseY + (tonumber(Misc.FlightV1Height) or 0)
		local heightError = targetY - root.Position.Y
		if math.abs(heightError) > 0.12 then
			vertical = math.clamp(heightError * 3, -speed * 0.75, speed * 0.75)
		end
		applyVerticalForce = true
	end

	FlightRuntime.Velocity.MaxForce = Vector3.new(
		100000000,
		applyVerticalForce and 100000000 or 0,
		100000000
	)
	FlightRuntime.Velocity.Velocity = horizontal * speed + Vector3.new(0, vertical, 0)
	local facing = look
	if not Misc.FlightViewControl then
		facing = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
		if facing.Magnitude < 0.001 then facing = Vector3.new(0, 0, -1) end
	end
	local upVector = Misc.FlightViewControl and camera.CFrame.UpVector or Vector3.yAxis
	FlightRuntime.Gyro.CFrame = CFrame.lookAt(root.Position, root.Position + facing, upVector)
end

table.insert(connections, RunService.Heartbeat:Connect(function()
	local ok, err = pcall(updateFlightPhysics)
	if not ok then
		warn("[Neumorph] 飞行控制运行失败：" .. tostring(err))
		Misc.FlightV1On, Misc.FlightV2On, Misc.FlightV3On = false, false, false
		destroyFlightPhysics(true)
		FlightRuntime.Mode = nil
		syncFlightToggleControls()
	end
end))

task.spawn(function()
	while running do
		local char = LocalPlayer.Character
		local hum = getHumanoid()
		if hum then
			-- 飞行时由 BodyVelocity 接管位移，避免普通移动速度循环覆盖飞行控制。
			if FlightRuntime.Mode and FlightRuntime.Root then
				hum.WalkSpeed = 0
			elseif WaypointState.WalkEnabled then
				-- 标点行走优先于普通移动速度。
				hum.WalkSpeed = WaypointState.WalkSpeed
			elseif Misc.NoclipOn then
				hum.WalkSpeed = Misc.NoclipSpeed
			elseif Misc.SpeedOn then
				hum.WalkSpeed = Misc.Speed
			end
			if Misc.JumpOn then
				hum.UseJumpPower = true
				hum.JumpPower = Misc.JumpPower
			end
			if Misc.NoclipOn or Misc.FlightV3On then
				applyNoclip(char)
			elseif next(noclipSaved) ~= nil then
				restoreNoclip()
			end
		elseif next(noclipSaved) ~= nil then
			restoreNoclip()
		end
		task.wait(0.15)
	end
end)

table.insert(connections, LocalPlayer.CharacterAdded:Connect(function(char)
	noclipSaved = {}
	task.wait(0.4)
	destroyFlightPhysics(false)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		if not flightModeFromSettings() then
			if WaypointState.WalkEnabled then hum.WalkSpeed = WaypointState.WalkSpeed
			elseif Misc.NoclipOn then hum.WalkSpeed = Misc.NoclipSpeed
			elseif Misc.SpeedOn then hum.WalkSpeed = Misc.Speed end
		end
		if Misc.JumpOn then
			hum.UseJumpPower = true
			hum.JumpPower = Misc.JumpPower
		end
		if Misc.NoclipOn or Misc.FlightV3On then applyNoclip(char) end
	end
end))

table.insert(connections, UserInputService.JumpRequest:Connect(function()
	if not Misc.InfJumpOn then return end
	local now = os.clock()
	if now - lastInfJump < Misc.JumpInterval then return end
	local hum = getHumanoid()
	if hum and hum.Health > 0 then
		lastInfJump = now
		hum:ChangeState(Enum.HumanoidStateType.Jumping)
	end
end))

-- NPC 缓存：只遍历 Humanoid，扫描间隔放宽到 3 秒，避免人多时卡住绘制
task.spawn(function()
	while running do
		local need = ESP.NpcBox or ESP.NpcRay or ESP.NpcInfo or ESP.NpcHealth or Aim.Enabled or Aim.Track or Aim.SilentAim
		if need then
			local list = {}
			local seen = {}
			local ok = pcall(function()
				for _, obj in ipairs(Workspace:GetDescendants()) do
					if obj:IsA("Humanoid") then
						local model = obj.Parent
						if model
							and model:IsA("Model")
							and not seen[model]
							and obj.Health > 0
							and not Players:GetPlayerFromCharacter(model)
							and (model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart)
						then
							seen[model] = true
							list[#list + 1] = model
						end
					end
				end
			end)
			if ok then npcCache = list end
		elseif #npcCache > 0 then
			npcCache = {}
		end
		task.wait(3)
	end
end)

-- ============================================================
-- 8. 人物绘制引擎
-- ============================================================
local DrawingLib
do
	local ok, fn = pcall(function() return Drawing.new end)
	if ok and type(fn) == "function" then DrawingLib = Drawing end
end

local TEXT_FONT = 2
if DrawingLib and DrawingLib.Fonts and DrawingLib.Fonts.UI then
	TEXT_FONT = DrawingLib.Fonts.UI
end

-- 同类 Drawing 创建失败后暂停 5 秒再试，避免每帧刷错误拖垮其它绘制
local drawingRetry = {}
local targetWarned = false

local function newDrawing(kind, setup)
	local now = os.clock()
	local retryAt = drawingRetry[kind]
	if retryAt then
		if now < retryAt then return nil end
		drawingRetry[kind] = nil
	end

	local created
	local ok, obj = pcall(function()
		created = DrawingLib.new(kind)
		assert(created, "Drawing.new returned nil")
		if setup then setup(created) end
		created.Visible = false
		return created
	end)
	if ok and obj then return obj end
	if created then pcall(function() created:Remove() end) end
	drawingRetry[kind] = now + 5
	return nil
end

local function getPart(obj, key, kind, setup)
	if obj[key] then return obj[key] end
	local d = newDrawing(kind, setup)
	-- 创建失败时不缓存 false；等待 newDrawing 的重试冷却结束后继续尝试，
	-- 避免某个角色第一次分配失败后永久漏绘。
	if d then obj[key] = d end
	return d
end

local function setupBox(d)
	d.Filled = false
	d.Thickness = ESP.Thickness
	d.Transparency = ESP.Transparency
end

local function setupRay(d)
	d.Thickness = ESP.Thickness
	d.Transparency = ESP.Transparency
end

local function setupText(d)
	d.Center = true
	d.Outline = true
	d.OutlineColor = Color3.new(0, 0, 0)
	d.Font = TEXT_FONT
	d.Size = 13
	d.Transparency = ESP.Transparency
end

local function setupHp(d)
	d.Filled = true
	d.Transparency = ESP.Transparency
end

local function hideESP(obj)
	for key, d in pairs(obj) do
		if key ~= "lastSeen" and d then
			pcall(function() d.Visible = false end)
		end
	end
end

local function destroyESP(obj)
	for key, d in pairs(obj) do
		if key ~= "lastSeen" and d then
			pcall(function() d.Visible = false end)
			pcall(function() d:Remove() end)
		end
	end
end

table.insert(connections, Players.PlayerRemoving:Connect(function(plr)
	local char = plr.Character
	if char then
		local obj = espObjects[char]
		if obj then
			destroyESP(obj)
			espObjects[char] = nil
		end
		coverCache[char] = nil
	end
end))

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

-- 统一的视线检测：目标自身不加入忽略列表；穿过透明/非碰撞装饰后继续检测，
-- 遇到真正阻挡视线的实体才判定为掩体后。供绘制和自瞄/追踪共同使用。
local function isVisible(char, targetPart)
	if not (char and char.Parent) then return false end
	local now = os.clock()
	local cached = coverCache[char]
	if cached and now - cached.t < 0.10 then return cached.v end

	local cam = Workspace.CurrentCamera
	targetPart = targetPart or char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
	if not (cam and targetPart and targetPart.Parent) then return false end

	local origin = cam.CFrame.Position
	local direction = targetPart.Position - origin
	if direction.Magnitude < 0.05 then
		coverCache[char] = { t = now, v = true }
		return true
	end

	local filter = {}
	if LocalPlayer.Character then filter[#filter + 1] = LocalPlayer.Character end
	rayParams.FilterDescendantsInstances = filter
	local visible = false

	-- 最多跳过 8 个透明或非碰撞部件，避免玻璃/装饰物造成误判。
	for _ = 1, 8 do
		local hit = Workspace:Raycast(origin, direction, rayParams)
		if not hit then
			visible = true
			break
		end

		local inst = hit.Instance
		if inst and inst:IsDescendantOf(char) then
			visible = true
			break
		end

		local passThrough = false
		pcall(function()
			passThrough = (not inst.CanCollide) or inst.Transparency >= 0.9
		end)
		if passThrough then
			filter[#filter + 1] = inst
			rayParams.FilterDescendantsInstances = filter
		else
			visible = false
			break
		end
	end

	coverCache[char] = { t = now, v = visible }
	return visible
end

-- 通过模型包围盒的 8 个角点投影计算屏幕边界。
-- 相比只投影头部和 RootPart，角色贴近镜头或部分身体越过屏幕边缘时也能保留绘制。
local function getProjectedBounds(char, head, hrp, cam, viewport)
	local minX, minY = math.huge, math.huge
	local maxX, maxY = -math.huge, -math.huge
	local pointCount = 0

	local function include(worldPos)
		local point = cam:WorldToViewportPoint(worldPos)
		if point.Z > 0.05 and point.X == point.X and point.Y == point.Y then
			minX = math.min(minX, point.X)
			minY = math.min(minY, point.Y)
			maxX = math.max(maxX, point.X)
			maxY = math.max(maxY, point.Y)
			pointCount = pointCount + 1
		end
	end

	local ok, boxCFrame, boxSize = pcall(function()
		return char:GetBoundingBox()
	end)
	if ok and boxCFrame and boxSize then
		local half = boxSize * 0.5
		for _, x in ipairs({ -1, 1 }) do
			for _, y in ipairs({ -1, 1 }) do
				for _, z in ipairs({ -1, 1 }) do
					include(boxCFrame:PointToWorldSpace(Vector3.new(half.X * x, half.Y * y, half.Z * z)))
				end
			end
		end
	end

	-- 包围盒投影点不足时，使用关键身体部位补足。
	if head then include(head.Position + Vector3.new(0, 0.35, 0)) end
	if hrp then
		include(hrp.Position + Vector3.new(0, 1.5, 0))
		include(hrp.Position - Vector3.new(0, 2.6, 0))
	end

	if pointCount == 0 then return nil end
	if maxX < -48 or minX > viewport.X + 48 or maxY < -48 or minY > viewport.Y + 48 then
		return nil
	end

	-- 近距离模型可能有投影角点落在极远坐标；限制绘制边界，避免巨型方框遮满屏幕。
	minX = math.clamp(minX, -48, viewport.X + 48)
	maxX = math.clamp(maxX, -48, viewport.X + 48)
	minY = math.clamp(minY, -48, viewport.Y + 48)
	maxY = math.clamp(maxY, -48, viewport.Y + 48)
	return minX, minY, maxX, maxY
end

local function collectTargets()
	local list = {}
	local cam = Workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position or Vector3.zero
	-- 绘制距离以本地角色的 HumanoidRootPart 为起点；直接用摄像机位置会把
	-- 摄像机高度/后置距离也算进去，常见会比角色间实际距离多出约 10–20 studs。
	local localChar = LocalPlayer.Character
	local localRoot = localChar and (localChar:FindFirstChild("HumanoidRootPart") or localChar.PrimaryPart)
	local distanceOrigin = localRoot and localRoot.Position or camPos

	local function add(char, plr)
		local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
		local dist = hrp and (distanceOrigin - hrp.Position).Magnitude or math.huge
		list[#list + 1] = { char = char, plr = plr, dist = dist }
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local char = player.Character
			if char and char.Parent then
				local hum = char:FindFirstChildOfClass("Humanoid")
				if hum and hum.Health > 0 then add(char, player) end
			end
		end
	end
	for _, model in ipairs(npcCache) do
		if model.Parent then
			local hum = model:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then add(model, nil) end
		end
	end

	-- 近处优先：Drawing 数量受限时先保证最近的玩家能显示
	table.sort(list, function(a, b) return a.dist < b.dist end)
	return list
end

local function makeLabel(char, plr)
	local label
	if plr then
		label = (plr.DisplayName ~= plr.Name) and (plr.DisplayName .. " @" .. plr.Name) or plr.Name
	else
		label = "NPC·" .. char.Name
	end
	if #label > 26 then label = string.sub(label, 1, 26) .. "…" end
	return label
end

local function isTeammate(plr)
	if not plr or plr == LocalPlayer then return false end

	-- Team 实例相同是最明确的同队判断。
	local myTeam = LocalPlayer.Team
	local theirTeam = plr.Team
	if myTeam and theirTeam and myTeam == theirTeam then
		return true
	end

	-- 部分游戏只更新 TeamColor，或 Team 与 TeamColor 不同步；
	-- 因此只要双方颜色都不是 White，就用 TeamColor 补充判断。
	local myColor = LocalPlayer.TeamColor
	local theirColor = plr.TeamColor
	if myColor and theirColor
		and myColor ~= Enum.TeamColor.White
		and theirColor ~= Enum.TeamColor.White
		and myColor == theirColor then
		return true
	end

	return false
end

-- 识别与本地玩家同阵营的 NPC。不同游戏的 NPC 阵营字段名称不统一，
-- 因此同时检查常见 Attribute、ValueObject、Team 实例及阵营标签。
local function isTeammateNPC(model, humanoid)
	if not model then return false end
	-- 部分游戏通过 CollectionService 标签标记友方 NPC。
	local tagServiceOK, tagService = pcall(function() return game:GetService("CollectionService") end)
	if tagServiceOK and tagService then
		for _, tag in ipairs({ "Friendly", "FriendlyNPC", "Ally", "Teammate" }) do
			local hasTag = false
			pcall(function() hasTag = tagService:HasTag(model, tag) end)
			if hasTag then return true end
		end
	end
	local holders = { model }
	if humanoid then holders[#holders + 1] = humanoid end

	for _, holder in ipairs(holders) do
		for _, key in ipairs({ "IsFriendly", "Friendly", "IsAlly", "Ally", "IsTeammate", "FriendlyNPC", "IsFriendlyNPC" }) do
			local ok, flag = pcall(function() return holder:GetAttribute(key) end)
			if ok and flag == true then return true end
		end
	end

	local localTeam = LocalPlayer.Team
	local localTeamName = localTeam and string.lower(localTeam.Name) or nil
	local localTeamColor = LocalPlayer.TeamColor
	local localTeamColorName = localTeamColor and string.lower(localTeamColor.Name) or nil
	local keys = { "Team", "TeamName", "Faction", "FactionName", "Allegiance", "TeamColor" }

	local function matchesTeam(value)
		if value == nil then return false end
		if typeof(value) == "Instance" then
			if localTeam and value == localTeam then return true end
			local ok, name = pcall(function() return value.Name end)
			if ok and type(name) == "string" and localTeamName and string.lower(name) == localTeamName then return true end
		elseif type(value) == "string" then
			local lowered = string.lower(value)
			if localTeamName and lowered == localTeamName then return true end
			if localTeamColorName and lowered == localTeamColorName then return true end
		elseif typeof(value) == "BrickColor" then
			if localTeamColor and value == localTeamColor then return true end
		elseif typeof(value) == "Color3" then
			if localTeamColor and (value - localTeamColor.Color).Magnitude < 0.02 then return true end
		end
		return false
	end

	for _, holder in ipairs(holders) do
		for _, key in ipairs(keys) do
			local ok, attributeValue = pcall(function() return holder:GetAttribute(key) end)
			if ok and matchesTeam(attributeValue) then return true end
			local child
			pcall(function() child = holder:FindFirstChild(key, true) end)
			if child then
				local value
				pcall(function() value = child.Value end)
				if matchesTeam(value) then return true end
			end
		end
	end
	return false
end

local function updateTarget(t, cam, vp, rayFrom)
	local char, plr = t.char, t.plr
	local isPlayer = plr ~= nil
	local obj = espObjects[char]

	-- 屏蔽同队玩家；NPC 阵营检测只影响 NPC 绘制。
	if isPlayer and ESP.TeamCheck and isTeammate(plr) then
		if obj then hideESP(obj) end
		return
	end

	local hum = char:FindFirstChildOfClass("Humanoid")
	if not isPlayer and not ESP.DrawNpcTeammates and isTeammateNPC(char, hum) then
		if obj then hideESP(obj) end
		return
	end

	local showBox = isPlayer and ESP.PlayerBox or ((not isPlayer) and ESP.NpcBox)
	local showRay = isPlayer and ESP.PlayerRay or ((not isPlayer) and ESP.NpcRay)
	local showHealth = isPlayer and ESP.PlayerHealth or ((not isPlayer) and ESP.NpcHealth)
	-- 开启血量时自动确保对应的信息行显示，以便在名称/距离后追加当前/最大生命值。
	local showInfo = (isPlayer and ESP.PlayerInfo or ((not isPlayer) and ESP.NpcInfo)) or showHealth

	if not (showBox or showRay or showInfo or showHealth) then
		if obj then hideESP(obj) end
		return
	end

	local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
	local head = char:FindFirstChild("Head") or hrp
	local dist = t.dist

	if not (hum and hrp and head) or hum.Health <= 0 or dist > ESP.MaxDistance then
		if obj then hideESP(obj) end
		return
	end

	local leftX, topY, rightX, bottomY = getProjectedBounds(char, head, hrp, cam, vp)
	if not leftX then
		if obj then hideESP(obj) end
		return
	end

	local boxHeight = math.max(10, bottomY - topY)
	local boxWidth = math.max(6, rightX - leftX)
	local midY = (topY + bottomY) * 0.5
	if bottomY - topY < 10 then
		topY = midY - 5
		bottomY = midY + 5
	end
	local boxX = leftX
	local centerX = (leftX + rightX) * 0.5

	-- 关闭掩体判断时使用通用绘制颜色；开启时分别使用无遮挡/掩体后颜色。
	local color = ESP.Color
	if ESP.Cover then
		color = isVisible(char, head) and ESP.CoverVisibleColor or ESP.CoverOccludedColor
	end

	if not obj then
		obj = {}
		espObjects[char] = obj
	end
	obj.lastSeen = os.clock()

	-- 方框
	if showBox then
		local box = getPart(obj, "box", "Square", setupBox)
		if box then
			box.Visible = true
			box.Position = Vector2.new(boxX, topY)
			box.Size = Vector2.new(boxWidth, boxHeight)
			box.Color = color
			box.Thickness = ESP.Thickness
			box.Transparency = ESP.Transparency
		end
	elseif obj.box then
		obj.box.Visible = false
	end

	-- 射线
	if showRay then
		local ray = getPart(obj, "ray", "Line", setupRay)
		if ray then
			ray.Visible = true
			ray.From = rayFrom
			ray.To = Vector2.new(centerX, bottomY)
			ray.Color = color
			ray.Thickness = ESP.Thickness
			ray.Transparency = ESP.Transparency
		end
	elseif obj.ray then
		obj.ray.Visible = false
	end

	-- 信息文字使用独立 Drawing 对象：玩家头顶信息与 NPC 信息分开管理，
	-- 玩家信息直接锚定在 Head 的水平中心上方，不依赖血条或方框的位置。
	-- 距离仅在显示时减 2；真实距离、绘制距离筛选和目标排序不受影响。
	local infoKey = isPlayer and "playerInfo" or "info"
	if showInfo then
		local info = getPart(obj, infoKey, "Text", setupText)
		if info then
			local displayDistance = math.max(0, math.floor((tonumber(dist) or 0) + 0.5) - 2)
			local infoText = string.format("%s  [%dm]", makeLabel(char, plr), displayDistance)
			if showHealth then
				infoText = infoText .. string.format("  (%d/%d)", math.floor(hum.Health + 0.5), math.floor(hum.MaxHealth + 0.5))
			end

			local infoX, infoY
			if isPlayer then
				-- 玩家信息独立锚定在头部上方，始终以头部 X 中线为中心。
				-- 增加世界高度与屏幕偏移，给 Roblox 原生名字留出间距；血条定位不受影响。
				local headTopOffset = math.max((head.Size.Y * 0.5) + 1.55, 1.9)
				local headPoint = cam:WorldToViewportPoint(head.Position + Vector3.new(0, headTopOffset, 0))
				infoX = headPoint.X
				infoY = headPoint.Y - 30
				if headPoint.Z <= 0 then
					infoX, infoY = centerX, topY - 52
				end
			else
				-- NPC 保留原来的头顶信息位置。
				local headPoint = cam:WorldToViewportPoint(head.Position + Vector3.new(0, 0.35, 0))
				infoX, infoY = centerX, topY - 30
				if headPoint.Z > 0 then
					infoX = headPoint.X
					infoY = math.min(topY, headPoint.Y) - 30
				end
			end

			info.Visible = true
			info.Center = true
			info.Text = infoText
			info.Position = Vector2.new(infoX, infoY)
			info.Color = color
			info.Transparency = ESP.Transparency
		end
	elseif obj[infoKey] then
		obj[infoKey].Visible = false
	end

	-- 动态血条：根据当前人物投影方框尺寸计算宽高，随人物远近/方框尺寸同步缩放。
	-- 血条位于方框左侧；背景覆盖完整方框高度，前景血量从底部向上填充。
	if showHealth then
		local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
		local barW = math.clamp(boxWidth * 0.12, 2, 6)
		local barH = math.max(1, boxHeight)
		local barLeft = math.floor(boxX - barW - 4 + 0.5)
		local barTop = math.floor(topY + 0.5)
		local filledH = math.max(0, barH * frac)

		local hpBg = getPart(obj, "hpBg", "Square", setupHp)
		if hpBg then
			hpBg.Visible = true
			hpBg.Filled = true
			hpBg.Position = Vector2.new(barLeft, barTop)
			hpBg.Size = Vector2.new(barW, barH)
			hpBg.Color = Color3.fromRGB(28, 32, 40)
			hpBg.Transparency = math.max(ESP.Transparency, 0.25)
		end

		local hp = getPart(obj, "hp", "Square", setupHp)
		if hp then
			hp.Visible = filledH > 0
			hp.Filled = true
			hp.Position = Vector2.new(barLeft, barTop + barH - filledH)
			hp.Size = Vector2.new(barW, filledH)
			hp.Color = ESP.HealthBarColor
			hp.Transparency = ESP.Transparency
		end
	else
		if obj.hp then obj.hp.Visible = false end
		if obj.hpBg then obj.hpBg.Visible = false end
	end
end

local function updateESP(targets)
	local cam = Workspace.CurrentCamera
	if not cam then return end
	local vp = cam.ViewportSize
	local rayFrom = Vector2.new(vp.X * 0.5, vp.Y - 1)
	local activeChars = {}

	for _, t in ipairs(targets) do
		activeChars[t.char] = true
		-- 单个角色出错不影响其他人；出错时先隐藏旧图形，避免残留。
		local ok, err = pcall(updateTarget, t, cam, vp, rayFrom)
		if not ok then
			local obj = espObjects[t.char]
			if obj then hideESP(obj) end
			if not targetWarned then
				targetWarned = true
				warn("[Neumorph] 单体绘制出错：" .. tostring(err))
			end
		end
	end

	-- 角色重生、Humanoid 暂时卸载或 NPC 离开候选列表时，立即隐藏旧对象。
	for char, obj in pairs(espObjects) do
		if not activeChars[char] then hideESP(obj) end
	end
end

local function refreshESPNow()
	if not (DrawingLib and running) then return end
	local ok, err = pcall(function()
		updateESP(collectTargets())
	end)
	if not ok then
		warn("[Neumorph] 绘制即时刷新失败：" .. tostring(err))
	end
end

-- ============================================================
-- 9. 自瞄引擎 + 独立 FOV 圈 + 静默自瞄
-- ============================================================
local aimFovCircle, trackFovCircle
local silentAimTarget = nil
local silentAimHookInstalled = false
local silentAimHookErrorShown = false
local aimMouse = nil
local silentAimToggleControl = nil
pcall(function() aimMouse = LocalPlayer:GetMouse() end)

local function createAimFovCircle(color, thickness, transparency)
	if not DrawingLib then return nil end
	local circle
	local ok = pcall(function()
		circle = DrawingLib.new("Circle")
		circle.Thickness = thickness
		circle.Filled = false
		circle.Transparency = transparency
		circle.Color = color
		circle.NumSides = 64
		circle.Visible = false
	end)
	if not ok then
		if circle then pcall(function() circle:Remove() end) end
		return nil
	end
	return circle
end

aimFovCircle = createAimFovCircle(Aim.AimColor, Aim.AimFovThickness, Aim.AimFovTransparency)
trackFovCircle = createAimFovCircle(Aim.TrackColor, Aim.TrackFovThickness, Aim.TrackFovTransparency)

-- 通用 Mouse 静默重定向：只支持游戏逻辑读取 Mouse.Hit / Mouse.Target / Mouse.UnitRay 的情况。
-- 不修改摄像机；若执行器不支持 hookmetamethod，则开关会自动恢复关闭。
local function installSilentAimHook()
	if silentAimHookInstalled then return true end
	local hookFn = hookmetamethod
	local wrap = newcclosure
	if type(hookFn) ~= "function" or type(wrap) ~= "function" or not aimMouse then
		return false, "执行器缺少 hookmetamethod/newcclosure，无法启用静默自瞄"
	end
	local oldIndex
	local ok, err = pcall(function()
		oldIndex = hookFn(game, "__index", wrap(function(self, key)
			if running and Aim.SilentAim and silentAimTarget and silentAimTarget.Parent and self == aimMouse then
				local fromExecutor = false
				if type(checkcaller) == "function" then
					pcall(function() fromExecutor = checkcaller() end)
				end
				if not fromExecutor then
					if key == "Hit" then
						return silentAimTarget.CFrame
					elseif key == "Target" then
						return silentAimTarget
					elseif key == "UnitRay" then
						local origin = oldIndex(self, "Origin")
						local direction = silentAimTarget.Position - origin
						if direction.Magnitude > 0.001 then
							return Ray.new(origin, direction.Unit * 1000)
						end
					end
				end
			end
			return oldIndex(self, key)
		end))
	end)
	if not ok or type(oldIndex) ~= "function" then
		return false, tostring(err or "静默自瞄钩子安装失败")
	end
	silentAimHookInstalled = true
	return true
end

local function findBestAimPart(targets, settings)
	local cam = Workspace.CurrentCamera
	if not cam then return nil end
	local viewport = cam.ViewportSize
	local center = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
	local bestPart, bestScreenDistance
	for _, target in ipairs(targets) do
		local isPlayer = target.plr ~= nil
		local allowedKind = isPlayer or settings.NpcCheck == true
		local teammate = isPlayer and settings.TeamCheck and isTeammate(target.plr)
		if allowedKind and not teammate then
			local char = target.char
			local humanoid = char and char:FindFirstChildOfClass("Humanoid")
			local part = char and (char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
			if humanoid and humanoid.Health > 0 and part then
				local screenPoint = cam:WorldToViewportPoint(part.Position)
				if screenPoint.Z > 0 then
					local screenDistance = (Vector2.new(screenPoint.X, screenPoint.Y) - center).Magnitude
					local worldDistance = (cam.CFrame.Position - part.Position).Magnitude
					if screenDistance <= settings.Fov and worldDistance <= settings.Range then
						local visible = (not settings.CoverCheck) or isVisible(char, part)
						if visible and (not bestScreenDistance or screenDistance < bestScreenDistance) then
							bestScreenDistance = screenDistance
							bestPart = part
						end
					end
				end
			end
		end
	end
	return bestPart
end

local function updateAim(targets, dt)
	local cam = Workspace.CurrentCamera
	if not cam then
		silentAimTarget = nil
		return
	end

	local aimPart
	if Aim.Enabled or Aim.SilentAim then
		aimPart = findBestAimPart(targets, {
			TeamCheck = Aim.AimTeamCheck,
			CoverCheck = Aim.AimCoverCheck,
			NpcCheck = Aim.AimNpcCheck,
			Fov = Aim.AimFov,
			Range = Aim.AimRange,
		})
	end
	local trackPart
	if Aim.Track then
		trackPart = findBestAimPart(targets, {
			TeamCheck = Aim.TrackTeamCheck,
			CoverCheck = Aim.TrackCoverCheck,
			NpcCheck = Aim.TrackNpcCheck,
			Fov = Aim.TrackFov,
			Range = Aim.TrackRange,
		})
	end

	-- 静默自瞄只重定向 Mouse 命中属性，不移动摄像机。
	silentAimTarget = Aim.SilentAim and aimPart or nil

	-- 摄像机只由当前明确开启的模式控制；追踪开启时优先控制摄像机，
	-- 但两种模式的筛选、FOV 和距离仍完全独立。
	local selectedPart
	if Aim.Track then
		selectedPart = trackPart
	elseif Aim.Enabled and not Aim.SilentAim then
		selectedPart = aimPart
	end
	if not selectedPart or not selectedPart.Parent then return end
	local cameraPosition = cam.CFrame.Position
	if (selectedPart.Position - cameraPosition).Magnitude < 0.1 then return end
	local goal = CFrame.lookAt(cameraPosition, selectedPart.Position)
	if Aim.Track then
		local alpha = math.clamp(dt * Aim.Smooth, 0, 1)
		cam.CFrame = cam.CFrame:Lerp(goal, alpha)
	else
		local alpha = math.clamp((tonumber(Aim.Strength) or 100) / 100, 0.01, 1)
		cam.CFrame = cam.CFrame:Lerp(goal, alpha)
	end
end

local function updateFovCircle(circle, camera, radius, color, thickness, transparency, visible)
	if not circle then return end
	local viewport = camera.ViewportSize
	circle.Position = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
	circle.Radius = radius
	circle.Color = color
	circle.Thickness = thickness
	circle.Transparency = transparency
	circle.Visible = visible == true
end

-- ============================================================
-- 10. 主循环
-- ============================================================
local staleTimer = 0
local lastESPRefresh = 0
local espWarned = false
local aimWarned = false

table.insert(connections, RunService.RenderStepped:Connect(function(dt)
	if not running then return end
	local cam = Workspace.CurrentCamera
	if not cam then return end

	updateFovCircle(aimFovCircle, cam, Aim.AimFov, Aim.AimColor,
		Aim.AimFovThickness, Aim.AimFovTransparency, Aim.AimShowFov)
	updateFovCircle(trackFovCircle, cam, Aim.TrackFov, Aim.TrackColor,
		Aim.TrackFovThickness, Aim.TrackFovTransparency, Aim.TrackShowFov)

	local targets = collectTargets()

	if DrawingLib then
		local now = os.clock()
		if not ESP.RefreshEvery2s or now - lastESPRefresh >= 2 then
			lastESPRefresh = now
			local ok, err = pcall(updateESP, targets)
			if not ok and not espWarned then
				espWarned = true
				warn("[Neumorph] 绘制更新出错：" .. tostring(err))
			end
		end
	end

	if Aim.Enabled or Aim.Track or Aim.SilentAim then
		local ok, err = pcall(updateAim, targets, dt)
		if not ok and not aimWarned then
			aimWarned = true
			warn("[Neumorph] 自瞄更新出错：" .. tostring(err))
		end
	end

	staleTimer = staleTimer + dt
	if staleTimer >= 1 then
		staleTimer = 0
		local now = os.clock()
		for char, obj in pairs(espObjects) do
			-- 角色离开，或 8 秒没有再出现在屏幕内：释放 Drawing，给其他人让位
			if not char.Parent or (obj.lastSeen and now - obj.lastSeen > 8) then
				destroyESP(obj)
				espObjects[char] = nil
			end
		end	end
end))

-- ============================================================
-- 11. 界面：首页（第 1 大分类）
-- ============================================================
-- Tab 的创建顺序决定侧栏顺序，因此首页必须在其他 Tab 之前创建。
local HomeTab = Window:Tab({ Title = "首页", Icon = "house" })
tabKeys[HomeTab] = "Home"
HomeTab:Paragraph({
    Title = "AI菜单",
    Desc = "欢迎使用，本菜单耗时大约13小时。",
})

-- ============================================================
-- 12. 界面：自瞄追踪
-- ============================================================
local AimTab = Window:Tab({ Title = "自瞄追踪", Icon = "crosshair" })
tabKeys[AimTab] = "Aim"

AimTab:Paragraph({
	Title = "自瞄 / 追踪",
	Desc = "自瞄和追踪分别拥有独立的目标判断与视野范围；静默自瞄不会移动摄像机。",
})

safe("瞄准模式", function()
	local s = section(AimTab, { Title = "自瞄", Desc = "自瞄强度与静默命中设置", Icon = "crosshair", Opened = true })
	s:Toggle({
		Title = "自瞄", Desc = "根据自瞄独立目标判断与 FOV 选择目标并调整镜头", Icon = "crosshair", Value = false,
		Callback = function(value) Aim.Enabled = value end,
	})
	s:Slider({
		Title = "自瞄强度", Desc = "1% 较弱、100% 立即贴近目标", IsTooltip = true, IsTextbox = true,
		Value = { Min = 1, Max = 100, Default = 100 }, Step = 1,
		Callback = function(value) Aim.Strength = math.clamp(tonumber(value) or 100, 1, 100) end,
	})
	silentAimToggleControl = s:Toggle({
		Title = "静默自瞄", Desc = "不移动镜头，重定向游戏读取的 Mouse.Hit / Mouse.Target（需执行器支持）",
		Icon = "scan-eye", Value = false,
		Callback = function(value)
			if value then
				local ok, err = installSilentAimHook()
				if not ok then
					Aim.SilentAim = false
					if silentAimToggleControl and silentAimToggleControl.Set then
						task.defer(function() pcall(function() silentAimToggleControl:Set(false) end) end)
					end
					if not silentAimHookErrorShown then
						silentAimHookErrorShown = true
						notify("静默自瞄不可用", tostring(err), "alert-triangle", 5)
					end
					return
				end
			end
			Aim.SilentAim = value
		end,
	})
	gap(AimTab)
end)

safe("追踪模式", function()
	local s = section(AimTab, { Title = "追踪", Desc = "独立的平滑镜头跟随设置", Icon = "target", Opened = true })
	s:Toggle({
		Title = "追踪", Desc = "根据追踪独立目标判断与 FOV 平滑跟随目标", Icon = "target", Value = false,
		Callback = function(value) Aim.Track = value end,
	})
	s:Slider({
		Title = "追踪平滑度", Desc = "数值越小，镜头移动越慢越稳",
		IsTooltip = true, IsTextbox = true,
		Value = { Min = 1, Max = 20, Default = 8 }, Step = 1,
		Callback = function(value) Aim.Smooth = value end,
	})
	gap(AimTab)
end)

safe("自瞄目标判断", function()
	local s = section(AimTab, { Title = "自瞄目标判断", Desc = "只影响自瞄，不影响追踪", Icon = "shield-check", Opened = true })
	s:Toggle({
		Title = "自瞄队友判断", Desc = "开启后自瞄跳过同队玩家", Icon = "users", Value = true,
		Callback = function(value) Aim.AimTeamCheck = value end,
	})
	s:Toggle({
		Title = "自瞄掩体判断", Desc = "开启后自瞄跳过被实体障碍遮挡的目标", Icon = "scan-eye", Value = true,
		Callback = function(value) Aim.AimCoverCheck = value end,
	})
	s:Toggle({
		Title = "自瞄 NPC 判断", Desc = "开启后自瞄也可以选择场景 NPC", Icon = "bot", Value = true,
		Callback = function(value) Aim.AimNpcCheck = value end,
	})
	gap(AimTab)
end)

safe("追踪目标判断", function()
	local s = section(AimTab, { Title = "追踪目标判断", Desc = "只影响追踪，不影响自瞄", Icon = "shield-check", Opened = true })
	s:Toggle({
		Title = "追踪队友判断", Desc = "开启后追踪跳过同队玩家", Icon = "users", Value = true,
		Callback = function(value) Aim.TrackTeamCheck = value end,
	})
	s:Toggle({
		Title = "追踪掩体判断", Desc = "开启后追踪跳过被实体障碍遮挡的目标", Icon = "scan-eye", Value = true,
		Callback = function(value) Aim.TrackCoverCheck = value end,
	})
	s:Toggle({
		Title = "追踪 NPC 判断", Desc = "开启后追踪也可以选择场景 NPC", Icon = "bot", Value = true,
		Callback = function(value) Aim.TrackNpcCheck = value end,
	})
	gap(AimTab)
end)

safe("自瞄视野范围", function()
	local s = section(AimTab, { Title = "自瞄视野范围", Desc = "仅控制自瞄的目标距离、FOV 和圆圈外观", Icon = "circle", Opened = true })
	s:Slider({
		Title = "自瞄 FOV 大小", Desc = "自瞄屏幕中心范围半径（像素）", IsTooltip = true, IsTextbox = true,
		Value = { Min = 40, Max = 600, Default = 180 }, Step = 1,
		Callback = function(value) Aim.AimFov = math.clamp(tonumber(value) or 180, 40, 600) end,
	})
	s:Slider({
		Title = "自瞄最大距离", Desc = "自瞄目标最大距离（studs）", IsTooltip = true, IsTextbox = true,
		Value = { Min = 50, Max = 2000, Default = 500 }, Step = 10,
		Callback = function(value) Aim.AimRange = math.clamp(tonumber(value) or 500, 50, 2000) end,
	})
	s:Colorpicker({
		Title = "自瞄 FOV 颜色", Desc = "自瞄范围圆圈颜色，默认绿色", Icon = "palette", Default = Aim.AimColor,
		Callback = function(color) Aim.AimColor = color end,
	})
	s:Slider({
		Title = "自瞄 FOV 粗细", Desc = "自瞄圆圈线条宽度", IsTooltip = true, IsTextbox = true,
		Value = { Min = 1, Max = 12, Default = Aim.AimFovThickness }, Step = 1,
		Callback = function(value) Aim.AimFovThickness = math.clamp(tonumber(value) or 3, 1, 12) end,
	})
	s:Slider({
		Title = "自瞄 FOV 透明度", Desc = "100% 最清晰，0% 完全透明", IsTooltip = true, IsTextbox = true,
		Value = { Min = 0, Max = 100, Default = 80 }, Step = 1,
		Callback = function(value) Aim.AimFovTransparency = math.clamp(tonumber(value) or 80, 0, 100) / 100 end,
	})
	s:Toggle({
		Title = "显示自瞄 FOV", Desc = "显示自瞄自己的视野范围圆圈", Icon = "circle", Value = false,
		Callback = function(value) Aim.AimShowFov = value end,
	})
	gap(AimTab)
end)

safe("追踪视野范围", function()
	local s = section(AimTab, { Title = "追踪视野范围", Desc = "仅控制追踪的目标距离、FOV 和圆圈外观", Icon = "circle", Opened = true })
	s:Slider({
		Title = "追踪 FOV 大小", Desc = "追踪屏幕中心范围半径（像素）", IsTooltip = true, IsTextbox = true,
		Value = { Min = 40, Max = 600, Default = 180 }, Step = 1,
		Callback = function(value) Aim.TrackFov = math.clamp(tonumber(value) or 180, 40, 600) end,
	})
	s:Slider({
		Title = "追踪最大距离", Desc = "追踪目标最大距离（studs）", IsTooltip = true, IsTextbox = true,
		Value = { Min = 50, Max = 2000, Default = 500 }, Step = 10,
		Callback = function(value) Aim.TrackRange = math.clamp(tonumber(value) or 500, 50, 2000) end,
	})
	s:Colorpicker({
		Title = "追踪 FOV 颜色", Desc = "追踪范围圆圈颜色", Icon = "palette", Default = Aim.TrackColor,
		Callback = function(color) Aim.TrackColor = color end,
	})
	s:Slider({
		Title = "追踪 FOV 粗细", Desc = "追踪圆圈线条宽度", IsTooltip = true, IsTextbox = true,
		Value = { Min = 1, Max = 12, Default = Aim.TrackFovThickness }, Step = 1,
		Callback = function(value) Aim.TrackFovThickness = math.clamp(tonumber(value) or 3, 1, 12) end,
	})
	s:Slider({
		Title = "追踪 FOV 透明度", Desc = "100% 最清晰，0% 完全透明", IsTooltip = true, IsTextbox = true,
		Value = { Min = 0, Max = 100, Default = 80 }, Step = 1,
		Callback = function(value) Aim.TrackFovTransparency = math.clamp(tonumber(value) or 80, 0, 100) / 100 end,
	})
	s:Toggle({
		Title = "显示追踪 FOV", Desc = "显示追踪自己的视野范围圆圈", Icon = "circle", Value = false,
		Callback = function(value) Aim.TrackShowFov = value end,
	})
end)

-- ============================================================
-- 13. 界面：人物绘制
-- ============================================================
local EspTab = Window:Tab({ Title = "人物绘制", Icon = "eye" })
tabKeys[EspTab] = "ESP"

safe("NPC 绘制", function()
	local s = section(EspTab, { Title = "NPC 绘制", Desc = "场景中非玩家的角色", Icon = "users", Opened = true })
	s:Toggle({
		Title = "NPC 方框", Desc = "用方框圈出 NPC", Icon = "box", Value = false,
		Callback = function(v) ESP.NpcBox = v; refreshESPNow() end,
	})
	s:Toggle({
		Title = "NPC 射线", Desc = "从屏幕底部指向 NPC", Icon = "move-up-right", Value = false,
		Callback = function(v) ESP.NpcRay = v; refreshESPNow() end,
	})
	s:Toggle({
		Title = "NPC 信息", Desc = "显示 NPC 名称与距离（居中显示在头顶上方）", Icon = "info", Value = false,
		Callback = function(v) ESP.NpcInfo = v; refreshESPNow() end,
	})
	s:Toggle({
		Title = "NPC 血量", Desc = "在 NPC 信息后显示（当前生命值/最大生命值）", Icon = "heart", Value = false,
		Callback = function(v) ESP.NpcHealth = v; refreshESPNow() end,
	})
	s:Toggle({
		Title = "绘制队友 NPC", Desc = "开启后也绘制可识别为本地同阵营的 NPC", Icon = "users", Value = ESP.DrawNpcTeammates,
		Callback = function(v) ESP.DrawNpcTeammates = v; refreshESPNow() end,
	})
	gap(EspTab)
end)

safe("玩家绘制", function()
	local s = section(EspTab, { Title = "玩家绘制", Desc = "其他玩家角色 · 可屏蔽队友", Icon = "user", Opened = true })
	s:Toggle({
		Title = "玩家信息", Desc = "显示玩家名称与距离（居中显示在头顶上方）", Icon = "info", Value = false,
		Callback = function(v) ESP.PlayerInfo = v; refreshESPNow() end,
	})
	s:Toggle({
		Title = "玩家方框", Desc = "用方框圈出玩家", Icon = "box", Value = false,
		Callback = function(v) ESP.PlayerBox = v; refreshESPNow() end,
	})
	s:Toggle({
		Title = "玩家射线", Desc = "从屏幕底部指向玩家", Icon = "move-up-right", Value = false,
		Callback = function(v) ESP.PlayerRay = v; refreshESPNow() end,
	})
	s:Toggle({
		Title = "玩家血量", Desc = "在玩家信息后显示（当前生命值/最大生命值），并显示血量条", Icon = "heart", Value = false,
		Callback = function(v) ESP.PlayerHealth = v; refreshESPNow() end,
	})
	s:Toggle({
		Title = "屏蔽队友", Desc = "不绘制与自己同队的玩家", Icon = "users", Value = ESP.TeamCheck,
		Callback = function(v)
			ESP.TeamCheck = v
			-- 开关变化时立即刷新现有目标，不必等待下一轮绘制或重跑脚本。
			refreshESPNow()
		end,
	})
	gap(EspTab)
end)

safe("绘制样式", function()
	local s = section(EspTab, {
		Title = "绘制样式", Desc = "调整方框、射线与信息样式；血量条保留渐变颜色", Icon = "palette", Opened = true,
	})
	s:Colorpicker({
		Title = "绘制颜色", Desc = "关闭掩体判断时使用此颜色", Icon = "palette", Default = ESP.Color,
		Callback = function(color)
			ESP.Color = color
			refreshESPNow()
		end,
	})
	s:Colorpicker({
		Title = "血条颜色", Desc = "单独调整玩家与 NPC 血量条颜色", Icon = "heart", Default = ESP.HealthBarColor,
		Callback = function(color)
			ESP.HealthBarColor = color
			refreshESPNow()
		end,
	})
	s:Slider({
		Title = "绘制粗细", Desc = "调整方框和射线线条宽度",
		IsTooltip = true, IsTextbox = true,
		Value = { Min = 1, Max = 5, Default = 1 }, Step = 1,
		Callback = function(v)
			ESP.Thickness = math.clamp(tonumber(v) or 1, 1, 5)
			refreshESPNow()
		end,
	})
	s:Slider({
		Title = "绘制透明度", Desc = "100% 最清晰，0% 完全透明",
		IsTooltip = true, IsTextbox = true,
		Value = { Min = 0, Max = 100, Default = 90 }, Step = 5,
		Callback = function(v)
			ESP.Transparency = math.clamp(tonumber(v) or 90, 0, 100) / 100
			refreshESPNow()
		end,
	})
	s:Toggle({
		Title = "每2秒刷新一次绘制", Desc = "开启后每2秒更新绘制；关闭则逐帧更新",
		Icon = "timer", Value = false,
		Callback = function(v)
			ESP.RefreshEvery2s = v
			refreshESPNow()
			lastESPRefresh = v and os.clock() or 0
		end,
	})
	gap(EspTab)
end)

safe("掩体判断", function()
	local s = section(EspTab, {
		Title = "掩体判断", Desc = "能看到 → 绿色；躲在掩体后 → 红色",
		Icon = "eye-off", Opened = true,
	})
	s:Toggle({
		Title = "掩体判断", Desc = "开启时显示可见/遮挡颜色；关闭后使用绘制样式中的自定义颜色", Icon = "scan-eye", Value = true,
		Callback = function(v) ESP.Cover = v; refreshESPNow() end,
	})
	s:Colorpicker({
		Title = "无遮挡绘制颜色", Desc = "目标没有被掩体遮挡时使用的颜色", Icon = "eye", Default = ESP.CoverVisibleColor,
		Callback = function(color)
			ESP.CoverVisibleColor = color
			refreshESPNow()
		end,
	})
	s:Colorpicker({
		Title = "掩体后绘制颜色", Desc = "目标处于墙体或其他有效掩体后时使用的颜色", Icon = "eye-off", Default = ESP.CoverOccludedColor,
		Callback = function(color)
			ESP.CoverOccludedColor = color
			refreshESPNow()
		end,
	})
	s:Slider({
		Title = "绘制距离", Desc = "超过这个距离不绘制（studs）",
		IsTooltip = true, IsTextbox = true,
		Value = { Min = 100, Max = 5000, Default = 1500 }, Step = 50,
		Callback = function(v) ESP.MaxDistance = v end,
	})
end)

-- ============================================================
-- 14. 界面：标点传送（第 4 大分类）
-- ============================================================
local WaypointTab = Window:Tab({ Title = "标点传送", Icon = "map-pin" })
tabKeys[WaypointTab] = "Waypoint"

safe("标点管理", function()
	local s = section(WaypointTab, {
		Title = "标点管理", Desc = "保存当前位置并生成地图标记与传送按钮", Icon = "map-pin", Opened = true,
	})

	local locateButton = s:Button({
		Title = "定位坐标", Desc = "保存当前坐标，并在本分类底部创建传送按钮",
		Icon = "map-pin", Justify = "Between",
		Callback = function()
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root then
				notify("定位坐标失败", "未找到角色根部，请稍后重试。", "alert-triangle", 3)
				return
			end

			local index = #WaypointState.Points + 1
			local savedCFrame = root.CFrame
			local point = {
				Index = index,
				Name = tostring(index) .. "标点",
				CFrame = savedCFrame,
				Visual = nil,
				Button = nil,
			}

			local visualOk, visual = pcall(function()
				return createWaypointVisual(index, savedCFrame)
			end)
			if visualOk then
				point.Visual = visual
			else
				warn("[Neumorph] 创建标点地图文字失败：" .. tostring(visual))
			end

			local position = savedCFrame.Position
			local desc = string.format("点击传送 · X %.1f  Y %.1f  Z %.1f", position.X, position.Y, position.Z)
			local buttonOk, button = pcall(function()
				-- 直接追加到 Tab，确保新按钮始终出现在本分类最下方。
				return WaypointTab:Button({
					Title = point.Name,
					Desc = desc,
					Icon = "map-pin",
					Justify = "Center",
					Callback = function()
						if teleportToWaypoint(point, false) then
							notify("标点传送", "已传送到 " .. point.Name, "check", 2)
						end
					end,
				})
			end)
			if buttonOk and button then
				point.Button = button
			else
				warn("[Neumorph] 创建标点按钮失败：" .. tostring(button))
				notify("标点按钮创建失败", "坐标已保存，但按钮未创建。请重新定位或查看执行器报错。", "alert-triangle", 4)
			end

			table.insert(WaypointState.Points, point)
			notify("定位成功", "已保存 " .. point.Name .. "，共 " .. tostring(#WaypointState.Points) .. " 个标点。", "check", 3)
		end,
	})
	-- 坐标传送卡片：黑色输入框 + 纸飞机执行按钮，放在“定位坐标”下方。
	-- 卡片自己用 AutomaticSize 计算高度，不改动 WindUI 内部元素的尺寸。
	local coordinateOk, coordinateErr = pcall(function()
		local sectionObject = s.ElementFrame
		local content = sectionObject and sectionObject.Outline and sectionObject.Outline.Content
		assert(content, "找不到标点管理内容容器")

		local coordinateTextBox = nil
		local function submitCoordinateTeleport()
			local rawText = WaypointState.CoordinateText
			if coordinateTextBox and coordinateTextBox.Parent then
				rawText = coordinateTextBox.Text
			end
			local targetPosition, parseError = parseCoordinateInput(rawText)
			if not targetPosition then
				notify("坐标格式错误", parseError, "alert-triangle", 4)
				return
			end

			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root then
				notify("坐标传送失败", "当前角色尚未加载或缺少 HumanoidRootPart。", "alert-triangle", 4)
				return
			end

			local targetCFrame = CFrame.new(targetPosition) * root.CFrame.Rotation
			if teleportToWaypoint({Name = "输入坐标", CFrame = targetCFrame}, false) then
				notify("坐标传送成功", string.format("X %.2f Y %.2f Z %.2f", targetPosition.X, targetPosition.Y, targetPosition.Z), "check", 3)
			end
		end

		-- 与上方“定位坐标”卡片保持完全一致。
		-- 参考用户截图取样：背景 RGB(42, 47, 53)，不透明（Transparency = 0）。
		-- 不再读取 Squircle 图片的 ImageColor3，避免误取到浅蓝灰色图层。
		local cardColor = Color3.fromRGB(42, 47, 53)
		local cardBackgroundTransparency = 0
		local cardTextColor = Color3.fromRGB(238, 242, 249)
		local elementConfig = Window.ElementConfig or {}
		local configuredCorner = elementConfig.UICorner
		local cardCornerRadius = UDim.new(0, tonumber(configuredCorner) or 16)
		local anchorFrame = locateButton and locateButton.ElementFrame

		-- 保留标题文字颜色和圆角的同步；背景颜色/透明度使用上方卡片截图中的准确值。
		if not anchorFrame then
			for _, descendant in ipairs(content:GetDescendants()) do
				if descendant:IsA("TextLabel") and descendant.Text == "定位坐标" then
					local candidate = descendant
					while candidate.Parent and candidate.Parent ~= content do
						candidate = candidate.Parent
					end
					anchorFrame = candidate
					break
				end
			end
		end

		if anchorFrame then
			local textSample = anchorFrame:FindFirstChildWhichIsA("TextLabel", true)
			if textSample then
				cardTextColor = textSample.TextColor3
			end
			local sourceCorner = anchorFrame:FindFirstChildWhichIsA("UICorner", true)
			if sourceCorner then
				cardCornerRadius = sourceCorner.CornerRadius
			end
		end
		local cardPaddingSize = elementConfig.UIPadding or 13

		local card = Instance.new("Frame")
		card.Name = "CoordinateTeleportCard"
		card.BackgroundColor3 = cardColor
		card.BackgroundTransparency = cardBackgroundTransparency
		card.BorderSizePixel = 0
		card.AutomaticSize = Enum.AutomaticSize.Y
		card.Size = UDim2.new(1, 0, 0, 0)
		card.Parent = content
		local cardCorner = Instance.new("UICorner")
		cardCorner.CornerRadius = cardCornerRadius
		cardCorner.Parent = card
		local cardPadding = Instance.new("UIPadding")
		cardPadding.PaddingTop = UDim.new(0, cardPaddingSize)
		cardPadding.PaddingBottom = UDim.new(0, cardPaddingSize)
		cardPadding.PaddingLeft = UDim.new(0, cardPaddingSize)
		cardPadding.PaddingRight = UDim.new(0, cardPaddingSize)
		cardPadding.Parent = card
		local cardLayout = Instance.new("UIListLayout")
		cardLayout.FillDirection = Enum.FillDirection.Vertical
		cardLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		cardLayout.VerticalAlignment = Enum.VerticalAlignment.Top
		cardLayout.SortOrder = Enum.SortOrder.LayoutOrder
		cardLayout.Padding = UDim.new(0, 8)
		cardLayout.Parent = card

		local title = Instance.new("TextLabel")
		title.LayoutOrder = 1
		title.BackgroundTransparency = 1
		title.Size = UDim2.new(1, 0, 0, 0)
		title.AutomaticSize = Enum.AutomaticSize.Y
		title.FontFace = Font.new("rbxassetid://12187365364", Enum.FontWeight.SemiBold)
		title.TextSize = 17
		title.TextColor3 = cardTextColor
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextWrapped = true
		title.Text = "坐标传送"
		title.Parent = card

		local desc = Instance.new("TextLabel")
		desc.LayoutOrder = 2
		desc.BackgroundTransparency = 1
		desc.Size = UDim2.new(1, 0, 0, 0)
		desc.AutomaticSize = Enum.AutomaticSize.Y
		desc.FontFace = Font.new("rbxassetid://12187365364", Enum.FontWeight.Medium)
		desc.TextSize = 15
		desc.TextColor3 = cardTextColor
		desc.TextTransparency = 0.3
		desc.TextXAlignment = Enum.TextXAlignment.Left
		desc.TextWrapped = true
		desc.Text = "输入 X Y Z，三个坐标用空格分隔"
		desc.Parent = card

		local rowHeight = 46
		local row = Instance.new("Frame")
		row.Name = "CoordinateTeleportRow"
		row.LayoutOrder = 3
		row.BackgroundTransparency = 1
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1, 0, 0, rowHeight)
		row.Parent = card

		local rowLayout = Instance.new("UIListLayout")
		rowLayout.FillDirection = Enum.FillDirection.Horizontal
		rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
		rowLayout.Padding = UDim.new(0, 8)
		rowLayout.Parent = row

		-- 黑色圆角输入框
		local plate = Instance.new("Frame")
		plate.Name = "CoordinateInputPlate"
		plate.LayoutOrder = 1
		plate.Size = UDim2.new(1, -(rowHeight + 8), 1, 0)
		plate.BackgroundColor3 = Color3.fromRGB(15, 17, 23)
		plate.BackgroundTransparency = 0
		plate.BorderSizePixel = 0
		plate.ClipsDescendants = true
		plate.ZIndex = 1
		plate.Parent = row
		local plateCorner = Instance.new("UICorner")
		plateCorner.CornerRadius = UDim.new(0, 14)
		plateCorner.Parent = plate

		local textBox = Instance.new("TextBox")
		textBox.Name = "CoordinateInput"
		textBox.BackgroundTransparency = 1
		textBox.BorderSizePixel = 0
		textBox.Size = UDim2.new(1, -32, 1, 0)
		textBox.Position = UDim2.fromOffset(16, 0)
		textBox.FontFace = Font.new("rbxassetid://12187365364", Enum.FontWeight.Regular)
		textBox.TextSize = 17
		textBox.TextColor3 = Color3.fromRGB(255, 255, 255)
		textBox.PlaceholderColor3 = Color3.fromRGB(146, 150, 162)
		textBox.PlaceholderText = "输入 X Y Z"
		textBox.Text = ""
		textBox.TextXAlignment = Enum.TextXAlignment.Left
		textBox.TextYAlignment = Enum.TextYAlignment.Center
		textBox.ClearTextOnFocus = false
		textBox.ClipsDescendants = true
		textBox.ZIndex = 2
		textBox.Parent = plate
		coordinateTextBox = textBox

		-- 使用 WindUI 官方 Creator.Icon 接口，从内置 Lucide 图标库读取 send 纸飞机。
		-- Creator.Icon 返回 {assetId, rectInfo}；Lucide send 与参考图的折线纸飞机轮廓最接近。
		-- 不使用 Emoji、手写字符或外部图片，保持 UI 图标库的原生线条样式。
		local iconImage, iconRectOffset, iconRectSize
		local iconLoaded, iconResult = pcall(function()
			local creator = WindUI and WindUI.Creator
			assert(creator and type(creator.Icon) == "function", "WindUI.Creator.Icon 接口不可用")
			return creator.Icon("send") -- Lucide 默认图标库中的纸飞机
		end)
		if iconLoaded and type(iconResult) == "table" then
			local asset = iconResult[1] or iconResult.asset or iconResult.Asset or iconResult.Image or iconResult.image
			local rectInfo = iconResult[2] or iconResult.rect_info or iconResult.Rect or iconResult.rect
			if type(asset) == "string" and asset ~= "" then
				iconImage = asset
			end
			if type(rectInfo) == "table" then
				local rectData = rectInfo.Rect or rectInfo.rect or rectInfo
				if type(rectData) == "table" then
					iconRectOffset = rectData.ImageRectPosition or rectData.ImageRectOffset
						 or rectData.offset or rectData.Offset
					iconRectSize = rectData.ImageRectSize or rectData.size or rectData.Size
				end
			end
		elseif not iconLoaded then
			warn("[Neumorph] WindUI 内置 Lucide send 图标加载失败：" .. tostring(iconResult))
		else
			warn("[Neumorph] WindUI.Creator.Icon(\"send\") 未返回有效图标数据。")
		end

		-- 右侧方形纸飞机箭头执行按钮
		local button = Instance.new("ImageButton")
		button.Name = "CoordinateTeleportButton"
		button.LayoutOrder = 2
		button.Size = UDim2.fromOffset(rowHeight, rowHeight)
		button.BackgroundColor3 = Color3.fromRGB(52, 60, 82)
		button.BorderSizePixel = 0
		button.AutoButtonColor = true
		button.ZIndex = 1
		button.Parent = row
		local buttonCorner = Instance.new("UICorner")
		buttonCorner.CornerRadius = UDim.new(0, 16)
		buttonCorner.Parent = button

		if iconImage and iconImage ~= "" then
			local icon = Instance.new("ImageLabel")
			icon.Name = "LucideSendPlaneIcon"
			icon.BackgroundTransparency = 1
			icon.AnchorPoint = Vector2.new(0.5, 0.5)
			icon.Position = UDim2.fromScale(0.5, 0.5)
			icon.Size = UDim2.fromScale(0.58, 0.58)
			icon.Image = iconImage
			icon.ImageColor3 = Color3.fromRGB(255, 255, 255)
			if typeof(iconRectOffset) == "Vector2" and iconRectOffset.Magnitude > 0 then
				icon.ImageRectOffset = iconRectOffset
			end
			if typeof(iconRectSize) == "Vector2" and iconRectSize.Magnitude > 0 then
				icon.ImageRectSize = iconRectSize
			end
			icon.ScaleType = Enum.ScaleType.Fit
			icon.ZIndex = 2
			icon.Parent = button
		else
			warn("[Neumorph] 坐标传送纸飞机图标未能从 WindUI/Lucide 图标库解析；按钮仍可点击执行传送。")
		end

		table.insert(connections, button.Activated:Connect(submitCoordinateTeleport))
		table.insert(connections, textBox:GetPropertyChangedSignal("Text"):Connect(function()
			WaypointState.CoordinateText = textBox.Text
		end))
		table.insert(connections, textBox.FocusLost:Connect(function(enterPressed)
			if enterPressed then
				submitCoordinateTeleport()
			end
		end))
		table.insert(connections, plate.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				pcall(function() textBox:CaptureFocus() end)
			end
		end))
	end)
	if not coordinateOk then
		warn("[Neumorph] 坐标传送卡片创建失败：" .. tostring(coordinateErr))
	end

	s:Button({
		Title = "清除所有标点", Desc = "删除全部坐标、地图文字和下方传送按钮；编号重置为 1",
		Icon = "trash-2", Justify = "Between",
		Callback = function()
			local oldCount = #WaypointState.Points
			destroyAllWaypoints()
			notify("标点已清除", "已清除 " .. tostring(oldCount) .. " 个标点；需要重新定位才能使用传送。", "check", 4)
		end,
	})

	WaypointState.LoopToggle = s:Toggle({
		Title = "循环传送", Desc = "按 1标点 → 最后一个标点的顺序循环传送", Icon = "repeat", Value = false,
		Callback = function(enabled)
			if enabled and #WaypointState.Points == 0 then
				WaypointState.LoopEnabled = false
				notify("无法开启循环传送", "请先使用“定位坐标”保存至少一个标点。", "alert-triangle", 4)
				task.defer(function()
					if WaypointState.LoopToggle then
						pcall(function() WaypointState.LoopToggle:Set(false) end)
					end
				end)
				return
			end
			if enabled then
				WaypointState.WalkEnabled = false
				if WaypointState.WalkToggle then
					pcall(function() WaypointState.WalkToggle:Set(false) end)
				end
			end
			WaypointState.LoopEnabled = enabled
			if enabled then
				notify("循环传送已开启", "将按顺序循环传送，关闭开关即可停止。", "check", 3)
			end
		end,
	})

	-- 三个参数集中显示在同一分类中，不再拆分为独立分类卡片。
	WaypointState.IntervalRow = createWaypointValueRow(s, {
		Name = "LoopIntervalControl", Title = "循环传送间隔（秒）",
		Description = "每轮完成全部标点后等待的时间，范围 0.1–60 秒",
		Min = 0.1, Max = 60, Step = 0.1, ButtonStep = 0.5, Decimals = 1, Value = WaypointState.LoopInterval,
		Format = function(v) return string.format("%.1f", v) end,
		InvalidMessage = "请输入 0.1–60 秒之间的有效数字。",
		Callback = function(value) setWaypointInterval(value, false) end,
	})
	WaypointState.RateRow = createWaypointValueRow(s, {
		Name = "LoopRateControl", Title = "循环传送速度（次/秒）",
		Description = "相邻两个标点之间的传送频率，范围 0.1–20 次/秒",
		Min = 0.1, Max = 20, Step = 0.1, Decimals = 1, Value = WaypointState.LoopRate,
		Format = function(v) return string.format("%.1f", v) end,
		InvalidMessage = "请输入 0.1–20 次/秒之间的有效数字。",
		Callback = function(value) setWaypointRate(value, false) end,
	})

	WaypointState.WalkToggle = s:Toggle({
		Title = "开始标点行走",
		Desc = "按第 1 个标点到最后一个标点依次正常行走，完成后自动关闭",
		Icon = "footprints", Value = false,
		Callback = function(enabled)
			if enabled and #WaypointState.Points == 0 then
				WaypointState.WalkEnabled = false
				notify("无法开始行走", "请先使用上方“定位坐标”保存至少一个标点。", "alert-triangle", 4)
				task.defer(function()
					if WaypointState.WalkToggle then
						pcall(function() WaypointState.WalkToggle:Set(false) end)
					end
				end)
				return
			end
			if enabled then
				WaypointState.LoopEnabled = false
				if WaypointState.LoopToggle then
					pcall(function() WaypointState.LoopToggle:Set(false) end)
				end
			end
			WaypointState.WalkEnabled = enabled
			if enabled then
				notify("标点行走已开始", "将从第 1 个标点依次走到最后一个。", "check", 3)
			end
		end,
	})
	WaypointState.WalkSpeedRow = createWaypointValueRow(s, {
		Name = "WalkSpeedControl", Title = "标点行走速度",
		Description = "角色沿标点路线行走时的移动速度，范围 4–100",
		Min = 4, Max = 100, Step = 1, Decimals = 0, Value = WaypointState.WalkSpeed,
		Format = function(v) return tostring(math.floor(v + 0.5)) end,
		InvalidMessage = "请输入 4–100 之间的有效行走速度。",
		Callback = function(value) setWaypointWalkSpeed(value, false) end,
	})
end)


-- ============================================================
-- 15. 界面：其他功能（第 5 大分类）
-- ============================================================
local MiscTab = Window:Tab({ Title = "其他功能", Icon = "settings" })
tabKeys[MiscTab] = "Misc"

safe("移动速度", function()
	local s = section(MiscTab, { Title = "移动速度", Desc = "拖动滑块，或点数值直接输入", Icon = "gauge", Opened = true })
	s:Toggle({
		Title = "启用速度调节", Desc = "关闭后恢复默认 16", Icon = "gauge", Value = false,
		Callback = function(v)
			Misc.SpeedOn = v
			local hum = getHumanoid()
			if hum and not v and not Misc.NoclipOn then hum.WalkSpeed = 16 end
		end,
	})
	s:Slider({
		Title = "速度数值", Desc = "16-500",
		IsTooltip = true, IsTextbox = true,
		Value = { Min = 16, Max = 500, Default = 50 }, Step = 1,
		Callback = function(v) Misc.Speed = v end,
	})
	gap(MiscTab)
end)

safe("高跳", function()
	local s = section(MiscTab, { Title = "高跳", Desc = "提高角色的跳跃力", Icon = "arrow-up", Opened = true })
	s:Toggle({
		Title = "启用高跳", Desc = "关闭后恢复默认 50", Icon = "arrow-up", Value = false,
		Callback = function(v)
			Misc.JumpOn = v
			local hum = getHumanoid()
			if hum and not v then hum.JumpPower = 50 end
		end,
	})
	s:Slider({
		Title = "跳跃力", Desc = "50-500，数值越大跳得越高",
		IsTooltip = true, IsTextbox = true,
		Value = { Min = 50, Max = 500, Default = 120 }, Step = 1,
		Callback = function(v) Misc.JumpPower = v end,
	})
	gap(MiscTab)
end)

safe("无限跳", function()
	local s = section(MiscTab, { Title = "无限跳", Desc = "空中也能再次起跳", Icon = "repeat", Opened = true })
	s:Toggle({
		Title = "启用无限跳", Desc = "按跳跃键即可连续跳", Icon = "repeat", Value = false,
		Callback = function(v) Misc.InfJumpOn = v end,
	})
	s:Slider({
		Title = "连跳间隔", Desc = "两次起跳之间的最短时间（秒）",
		IsTooltip = true, IsTextbox = true,
		Value = { Min = 0.05, Max = 1, Default = 0.15 }, Step = 0.01,
		Callback = function(v) Misc.JumpInterval = v end,
	})
	gap(MiscTab)
end)

safe("穿墙", function()
	local s = section(MiscTab, { Title = "穿墙", Desc = "关闭角色碰撞，可穿过墙体", Icon = "maximize", Opened = true })
	s:Toggle({
		Title = "启用穿墙", Desc = "关闭后恢复碰撞", Icon = "maximize", Value = false,
		Callback = function(v)
			Misc.NoclipOn = v
			if not v and not Misc.FlightV3On then
				restoreNoclip()
				local hum = getHumanoid()
				if hum and not FlightRuntime.Mode then hum.WalkSpeed = Misc.SpeedOn and Misc.Speed or 16 end
			end
		end,
	})
	s:Slider({
		Title = "穿墙速度", Desc = "穿墙状态下的移动速度",
		IsTooltip = true, IsTextbox = true,
		Value = { Min = 16, Max = 300, Default = 60 }, Step = 1,
		Callback = function(v) Misc.NoclipSpeed = v end,
	})
end)

gap(MiscTab)

safe("飞行", function()
	-- 所有飞行按钮与参数放在同一分类内，不再拆分子分类。
	local s = section(MiscTab, {
		Title = "飞行", Desc = "V1 手动控制 / V2 视角飞行 / V3 视角飞行并穿墙", Icon = "wind", Opened = true,
	})
	FlightV1Toggle = s:Toggle({
		Title = "飞行 V1", Desc = "开启/关闭 V1 飞行；移动、升降、高度和速度在子界面调节",
		Icon = "plane", Value = false,
		Callback = function(v)
			if FlightUIBusy then return end
			setFlightMode("V1", v)
		end,
	})
	FlightV1OpenButton = s:Button({
		Title = "打开飞行控制面板", Desc = "管理移动、视角、单次升降、高度锁定和子 UI 大小；支持最小化悬浮窗",
		Icon = "sliders-horizontal", Justify = "Between",
		Callback = openFlightPanel,
	})
	FlightV2Toggle = s:Toggle({
		Title = "飞行 V2", Desc = "WASD / 游戏摇杆移动；前进时镜头上仰上升、下俯下降，高度锁定仍可开启",
		Icon = "plane-takeoff", Value = false,
		Callback = function(v)
			if FlightUIBusy then return end
			setFlightMode("V2", v)
		end,
	})
	FlightV2SpeedInput = s:Input({
		Title = "飞行 V2 速度", Desc = "输入 1–500 的飞行速度",
		Value = tostring(Misc.FlightV2Speed), Placeholder = "例如 60", Type = "Input",
		Callback = function(value)
			local speed = tonumber(value)
			if not speed or speed ~= speed or speed == math.huge or speed == -math.huge then
				notify("飞行 V2", "请输入有效数字。", "alert-triangle", 3)
				return
			end
			Misc.FlightV2Speed = math.clamp(speed, 1, 500)
		end,
	})
	FlightV3Toggle = s:Toggle({
		Title = "飞行 V3", Desc = "水平视角飞行并自动穿墙；默认锁定高度，关闭后恢复原碰撞状态",
		Icon = "plane", Value = false,
		Callback = function(v)
			if FlightUIBusy then return end
			setFlightMode("V3", v)
		end,
	})
	FlightV3SpeedInput = s:Input({
		Title = "飞行 V3 速度", Desc = "输入 1–500 的飞行速度",
		Value = tostring(Misc.FlightV3Speed), Placeholder = "例如 60", Type = "Input",
		Callback = function(value)
			local speed = tonumber(value)
			if not speed or speed ~= speed or speed == math.huge or speed == -math.huge then
				notify("飞行 V3", "请输入有效数字。", "alert-triangle", 3)
				return
			end
			Misc.FlightV3Speed = math.clamp(speed, 1, 500)
		end,
	})
end)

-- ============================================================
-- 16. 界面：设置（第 6 大分类；不再拆分子分类）
-- ============================================================
local SettingsTab = Window:Tab({ Title = "设置", Icon = "sliders-horizontal" })
tabKeys[SettingsTab] = "Settings"

-- 设置之后新增独立主分类；按钮入口由用户自行填入脚本内容。
local OtherScriptsTab = Window:Tab({ Title = "其他脚本", Icon = "code" })
tabKeys[OtherScriptsTab] = "OtherScripts"

-- 配置文件采用 JSON，颜色转换为 RGB 数值，避免 Roblox Color3 无法直接序列化。
local HttpService = game:GetService("HttpService")
local CONFIG_FOLDER = "NeumorphHub"
local CONFIG_FILE = CONFIG_FOLDER .. "/NeumorphConfig.json"
local CONFIG_FALLBACK = "NeumorphHubConfig.json"

local function colorToTable(color)
	return {
		R = math.floor(math.clamp(color.R, 0, 1) * 255 + 0.5),
		G = math.floor(math.clamp(color.G, 0, 1) * 255 + 0.5),
		B = math.floor(math.clamp(color.B, 0, 1) * 255 + 0.5),
	}
end

local function tableToColor(value)
	if type(value) ~= "table" then return nil end
	local r, g, b = tonumber(value.R), tonumber(value.G), tonumber(value.B)
	if not r or not g or not b then return nil end
	return Color3.fromRGB(math.clamp(r, 0, 255), math.clamp(g, 0, 255), math.clamp(b, 0, 255))
end

-- WindUI 支持运行时注册并切换主题；固定主题名称可重复覆盖，不会不断累积主题。
local CUSTOM_THEME_NAME = "Neumorph User Background"
local function applyUIBackgroundColor(color)
	if typeof(color) ~= "Color3" then return false end
	UISettings.BackgroundColor = color
	local baseTheme
	for _, candidate in ipairs(THEMES) do
		if candidate.Name == "Neumorph Dark" then
			baseTheme = candidate
			break
		end
	end
	if not baseTheme then return false end
	local theme = {}
	for key, value in pairs(baseTheme) do theme[key] = value end
	local brightness = color.R * 0.299 + color.G * 0.587 + color.B * 0.114
	local tint = brightness < 0.5 and Color3.new(1, 1, 1) or Color3.new(0, 0, 0)
	theme.Name = CUSTOM_THEME_NAME
	theme.Background = color
	theme.PanelBackground = color:Lerp(tint, 0.07)
	-- 分类内容区（MainBar）的背景透明度与主窗口滑动条保持同步。
	theme.PanelBackgroundTransparency = math.clamp(tonumber(UISettings.BackgroundTransparency) or 0, 0, 0.9)
	theme.LabelBackground = color:Lerp(tint, 0.04)
	theme.Dialog = color:Lerp(tint, 0.10)
	theme.ElementBackground = color:Lerp(tint, 0.12)
	theme.TabBackground = color:Lerp(tint, 0.12)
	theme.TabBackgroundHover = color:Lerp(tint, 0.17)
	-- Active 与普通状态同色，避免首次启动时某个分类出现突兀的白色底色。
	theme.TabBackgroundActive = theme.TabBackground
	local ok, err = pcall(function()
		WindUI:AddTheme(theme)
		assert(WindUI:SetTheme(CUSTOM_THEME_NAME), "WindUI 未能切换到自定义主题")
	end)
	if not ok then
		warn("[Neumorph] 应用界面背景色失败：" .. tostring(err))
		return false
	end
	return true
end

-- 同步调整主窗口外围与分类内容面板透明度；0 为不透明，0.9 为高透明。
-- WindUI:SetBackgroundTransparency 只控制 Main.Background（窗口外围），
-- 当前分类页面的底板位于 MainBar.Background，需要单独设置 ImageTransparency。
local function applyWindowTransparency(value)
	local transparency = math.floor(math.clamp(tonumber(value) or UISettings.BackgroundTransparency or 0.10, 0, 0.9) * 10 + 0.5) / 10
	UISettings.BackgroundTransparency = transparency

	local outerOK, outerErr = pcall(function()
		assert(Window and type(Window.SetBackgroundTransparency) == "function", "当前 WindUI 构建缺少 SetBackgroundTransparency 接口")
		Window:SetBackgroundTransparency(transparency)
	end)
	if not outerOK then
		warn("[Neumorph] 应用主窗口外围透明度失败：" .. tostring(outerErr))
		-- 兼容分支：直接设置主窗口背景图片透明度。
		pcall(function()
			local background = Window and Window.UIElements and Window.UIElements.Main and Window.UIElements.Main:FindFirstChild("Background")
			if background then background.ImageTransparency = transparency end
		end)
	end

	-- 分类切换后显示的右侧内容面板，与外围使用同一个透明度值。
	local panelOK, panelErr = pcall(function()
		local mainBar = Window and Window.UIElements and Window.UIElements.MainBar
		local panelBackground = mainBar and mainBar:FindFirstChild("Background")
		assert(panelBackground, "WindUI 分类内容面板 Background 未找到")
		if panelBackground:IsA("ImageLabel") or panelBackground:IsA("ImageButton") then
			panelBackground.ImageTransparency = transparency
		else
			panelBackground.BackgroundTransparency = transparency
		end
	end)
	if not panelOK then
		warn("[Neumorph] 应用分类内容面板透明度失败：" .. tostring(panelErr))
	end

	return outerOK and panelOK
end

local ConfigBindings = {
	{ id="Aim|自瞄", group="Aim", field="Enabled", kind="boolean" },
	{ id="Aim|自瞄强度", group="Aim", field="Strength", kind="number" },
	{ id="Aim|静默自瞄", group="Aim", field="SilentAim", kind="boolean" },
	{ id="Aim|追踪", group="Aim", field="Track", kind="boolean" },
	{ id="Aim|追踪平滑度", group="Aim", field="Smooth", kind="number" },
	{ id="Aim|自瞄队友判断", group="Aim", field="AimTeamCheck", kind="boolean" },
	{ id="Aim|自瞄掩体判断", group="Aim", field="AimCoverCheck", kind="boolean" },
	{ id="Aim|自瞄 NPC 判断", group="Aim", field="AimNpcCheck", kind="boolean" },
	{ id="Aim|自瞄 FOV 大小", group="Aim", field="AimFov", kind="number" },
	{ id="Aim|自瞄最大距离", group="Aim", field="AimRange", kind="number" },
	{ id="Aim|自瞄 FOV 颜色", group="Aim", field="AimColor", kind="color" },
	{ id="Aim|自瞄 FOV 粗细", group="Aim", field="AimFovThickness", kind="number" },
	{ id="Aim|自瞄 FOV 透明度", group="Aim", field="AimFovTransparency", kind="number", toUI=function(v) return v * 100 end },
	{ id="Aim|显示自瞄 FOV", group="Aim", field="AimShowFov", kind="boolean" },
	{ id="Aim|追踪队友判断", group="Aim", field="TrackTeamCheck", kind="boolean" },
	{ id="Aim|追踪掩体判断", group="Aim", field="TrackCoverCheck", kind="boolean" },
	{ id="Aim|追踪 NPC 判断", group="Aim", field="TrackNpcCheck", kind="boolean" },
	{ id="Aim|追踪 FOV 大小", group="Aim", field="TrackFov", kind="number" },
	{ id="Aim|追踪最大距离", group="Aim", field="TrackRange", kind="number" },
	{ id="Aim|追踪 FOV 颜色", group="Aim", field="TrackColor", kind="color" },
	{ id="Aim|追踪 FOV 粗细", group="Aim", field="TrackFovThickness", kind="number" },
	{ id="Aim|追踪 FOV 透明度", group="Aim", field="TrackFovTransparency", kind="number", toUI=function(v) return v * 100 end },
	{ id="Aim|显示追踪 FOV", group="Aim", field="TrackShowFov", kind="boolean" },

	{ id="ESP|NPC 方框", group="ESP", field="NpcBox", kind="boolean" },
	{ id="ESP|NPC 射线", group="ESP", field="NpcRay", kind="boolean" },
	{ id="ESP|NPC 信息", group="ESP", field="NpcInfo", kind="boolean" },
	{ id="ESP|NPC 血量", group="ESP", field="NpcHealth", kind="boolean" },
	{ id="ESP|绘制队友 NPC", group="ESP", field="DrawNpcTeammates", kind="boolean" },
	{ id="ESP|玩家信息", group="ESP", field="PlayerInfo", kind="boolean" },
	{ id="ESP|玩家方框", group="ESP", field="PlayerBox", kind="boolean" },
	{ id="ESP|玩家射线", group="ESP", field="PlayerRay", kind="boolean" },
	{ id="ESP|玩家血量", group="ESP", field="PlayerHealth", kind="boolean" },
	{ id="ESP|屏蔽队友", group="ESP", field="TeamCheck", kind="boolean" },
	{ id="ESP|绘制颜色", group="ESP", field="Color", kind="color" },
	{ id="ESP|血条颜色", group="ESP", field="HealthBarColor", kind="color" },
	{ id="ESP|无遮挡绘制颜色", group="ESP", field="CoverVisibleColor", kind="color" },
	{ id="ESP|掩体后绘制颜色", group="ESP", field="CoverOccludedColor", kind="color" },
	{ id="ESP|绘制粗细", group="ESP", field="Thickness", kind="number" },
	{ id="ESP|绘制透明度", group="ESP", field="Transparency", kind="number", toUI=function(v) return v * 100 end },
	{ id="ESP|每2秒刷新一次绘制", group="ESP", field="RefreshEvery2s", kind="boolean" },
	{ id="ESP|掩体判断", group="ESP", field="Cover", kind="boolean" },
	{ id="ESP|绘制距离", group="ESP", field="MaxDistance", kind="number" },

	{ id="Misc|启用速度调节", group="Misc", field="SpeedOn", kind="boolean" },
	{ id="Misc|速度数值", group="Misc", field="Speed", kind="number" },
	{ id="Misc|启用高跳", group="Misc", field="JumpOn", kind="boolean" },
	{ id="Misc|跳跃力", group="Misc", field="JumpPower", kind="number" },
	{ id="Misc|启用无限跳", group="Misc", field="InfJumpOn", kind="boolean" },
	{ id="Misc|连跳间隔", group="Misc", field="JumpInterval", kind="number" },
	{ id="Misc|启用穿墙", group="Misc", field="NoclipOn", kind="boolean" },
	{ id="Misc|穿墙速度", group="Misc", field="NoclipSpeed", kind="number" },
	{ id="Misc|飞行 V1", group="Misc", field="FlightV1On", kind="boolean" },
	{ id="Misc|飞行 V2", group="Misc", field="FlightV2On", kind="boolean" },
	{ id="Misc|飞行 V2 速度", group="Misc", field="FlightV2Speed", kind="number" },
	{ id="Misc|飞行 V3", group="Misc", field="FlightV3On", kind="boolean" },
	{ id="Misc|飞行 V3 速度", group="Misc", field="FlightV3Speed", kind="number" },
	{ id="Misc|飞行 V1 速度", group="Misc", field="FlightV1Speed", kind="number" },
	{ id="Misc|飞行 V1 高度", group="Misc", field="FlightV1Height", kind="number" },
	{ id="Misc|飞行高度锁定", group="Misc", field="FlightHeightLock", kind="boolean" },
	{ id="Misc|飞行子 UI 大小", group="Misc", field="FlightPanelScale", kind="number" },
	{ id="Misc|飞行视角控制", group="Misc", field="FlightViewControl", kind="boolean" },
	{ id="Misc|飞行移动控制", group="Misc", field="FlightMoveControl", kind="boolean" },
	{ id="Misc|飞行持续上升", group="Misc", field="FlightAscend", kind="boolean" },
	{ id="Misc|飞行持续下降", group="Misc", field="FlightDescend", kind="boolean" },

}

local function buildConfigSnapshot()
	local data = {
		Version = 3,
		Aim = {}, ESP = {}, Misc = {},
		UI = {
			PopupScale = PopupSettings.Scale,
			PopupTransparency = PopupSettings.Transparency,
			ShowNotifications = PopupSettings.ShowNotifications,
			PopupWidth = PopupSettings.Width,
			PopupHeight = PopupSettings.Height,
			BackgroundColor = colorToTable(UISettings.BackgroundColor),
			BackgroundTransparency = UISettings.BackgroundTransparency,
		},
		Waypoint = {
			LoopInterval = WaypointState.LoopInterval,
			LoopRate = WaypointState.LoopRate,
			WalkSpeed = WaypointState.WalkSpeed,
			Points = {},
		},
	}
	for _, point in ipairs(WaypointState.Points) do
		if point and typeof(point.CFrame) == "CFrame" then
			local components = { point.CFrame:GetComponents() }
			table.insert(data.Waypoint.Points, { Name = point.Name, Components = components })
		end
	end
	for _, binding in ipairs(ConfigBindings) do
		local source = ({ Aim=Aim, ESP=ESP, Misc=Misc })[binding.group]
		local value = source[binding.field]
		if binding.kind == "color" then value = colorToTable(value) end
		data[binding.group][binding.field] = value
	end
	return data
end

local function getConfigPath()
	if type(writefile) ~= "function" and type(readfile) ~= "function" and type(delfile) ~= "function" then
		return nil
	end
	if type(makefolder) == "function" then
		pcall(function()
			if type(isfolder) ~= "function" or not isfolder(CONFIG_FOLDER) then makefolder(CONFIG_FOLDER) end
		end)
	end
	if type(isfolder) == "function" then
		local ok, exists = pcall(isfolder, CONFIG_FOLDER)
		if ok and exists then return CONFIG_FILE end
	end
	return CONFIG_FALLBACK
end

local function saveConfig()
	if type(writefile) ~= "function" then
		notify("保存配置失败", "当前执行器不支持 writefile 文件接口。", "alert-triangle", 5)
		return
	end
	local path = getConfigPath() or CONFIG_FALLBACK
	local ok, err = pcall(function()
		writefile(path, HttpService:JSONEncode(buildConfigSnapshot()))
	end)
	if ok then
		notify("配置已保存", "保存位置：" .. path, "check", 4)
	else
		notify("保存配置失败", tostring(err), "alert-triangle", 5)
	end
end

local function loadConfig()
	if type(readfile) ~= "function" then
		notify("加载配置失败", "当前执行器不支持 readfile 文件接口。", "alert-triangle", 5)
		return
	end
	local preferredPath = getConfigPath() or CONFIG_FILE
	local candidates = { preferredPath }
	if preferredPath ~= CONFIG_FALLBACK then table.insert(candidates, CONFIG_FALLBACK) end
	local data, path, lastReadError
	for _, candidate in ipairs(candidates) do
		local shouldTry = true
		if type(isfile) == "function" then
			local checkOk, exists = pcall(isfile, candidate)
			if checkOk and not exists then shouldTry = false end
		end
		if shouldTry then
			local readOk, decoded = pcall(function()
				return HttpService:JSONDecode(readfile(candidate))
			end)
			if readOk and type(decoded) == "table" then
				data, path = decoded, candidate
				break
			else
				lastReadError = decoded
			end
		end
	end
	if type(data) ~= "table" then
		notify("加载配置失败", "配置文件不存在或内容损坏：" .. tostring(lastReadError or "未找到配置文件"), "alert-triangle", 5)
		return
	end
	local stateGroups = { Aim=Aim, ESP=ESP, Misc=Misc }
	for _, binding in ipairs(ConfigBindings) do
		local groupData = data[binding.group]
		local value = type(groupData) == "table" and groupData[binding.field] or nil
		local target = stateGroups[binding.group]
		if binding.kind == "boolean" then
			if type(value) == "boolean" then target[binding.field] = value end
		elseif binding.kind == "number" then
			local number = tonumber(value)
			if number and number == number and number ~= math.huge and number ~= -math.huge then
				target[binding.field] = number
			end
		elseif binding.kind == "color" then
			local color = tableToColor(value)
			if color then target[binding.field] = color end
		end
	end

	-- 旧配置只有一套共享 FOV/判断设置：升级时复制到自瞄和追踪两套，
	-- 新配置字段优先，不会互相覆盖。
	local legacyAim = type(data.Aim) == "table" and data.Aim or {}
	if legacyAim.AimFov == nil and tonumber(legacyAim.Fov) then
		Aim.AimFov = math.clamp(tonumber(legacyAim.Fov), 40, 600)
		Aim.TrackFov = Aim.AimFov
	end
	if legacyAim.AimRange == nil and tonumber(legacyAim.Range) then
		Aim.AimRange = math.clamp(tonumber(legacyAim.Range), 50, 2000)
		Aim.TrackRange = Aim.AimRange
	end
	if legacyAim.AimColor == nil and legacyAim.Color ~= nil then
		local legacyColor = tableToColor(legacyAim.Color)
		if legacyColor then Aim.AimColor = legacyColor; Aim.TrackColor = legacyColor end
	end
	if legacyAim.AimTeamCheck == nil and type(legacyAim.TeamCheck) == "boolean" then
		Aim.AimTeamCheck = legacyAim.TeamCheck; Aim.TrackTeamCheck = legacyAim.TeamCheck
	end
	if legacyAim.AimCoverCheck == nil and type(legacyAim.CoverCheck) == "boolean" then
		Aim.AimCoverCheck = legacyAim.CoverCheck; Aim.TrackCoverCheck = legacyAim.CoverCheck
	end
	if legacyAim.AimFovThickness == nil and tonumber(legacyAim.FovThickness) then
		Aim.AimFovThickness = math.clamp(tonumber(legacyAim.FovThickness), 1, 12)
		Aim.TrackFovThickness = Aim.AimFovThickness
	end
	if legacyAim.AimFovTransparency == nil and tonumber(legacyAim.FovTransparency) then
		Aim.AimFovTransparency = math.clamp(tonumber(legacyAim.FovTransparency), 0, 1)
		Aim.TrackFovTransparency = Aim.AimFovTransparency
	end
	if legacyAim.AimShowFov == nil and type(legacyAim.ShowFov) == "boolean" then
		Aim.AimShowFov = legacyAim.ShowFov; Aim.TrackShowFov = legacyAim.ShowFov
	end
	Aim.Strength = math.clamp(tonumber(Aim.Strength) or 100, 1, 100)
	Aim.Smooth = math.clamp(tonumber(Aim.Smooth) or 8, 1, 20)
	Aim.AimFov = math.clamp(tonumber(Aim.AimFov) or 180, 40, 600)
	Aim.TrackFov = math.clamp(tonumber(Aim.TrackFov) or 180, 40, 600)
	Aim.AimRange = math.clamp(tonumber(Aim.AimRange) or 500, 50, 2000)
	Aim.TrackRange = math.clamp(tonumber(Aim.TrackRange) or 500, 50, 2000)
	Aim.AimFovThickness = math.clamp(tonumber(Aim.AimFovThickness) or 3, 1, 12)
	Aim.TrackFovThickness = math.clamp(tonumber(Aim.TrackFovThickness) or 3, 1, 12)
	Aim.AimFovTransparency = math.clamp(tonumber(Aim.AimFovTransparency) or 0.8, 0, 1)
	Aim.TrackFovTransparency = math.clamp(tonumber(Aim.TrackFovTransparency) or 0.8, 0, 1)
	if Aim.SilentAim and not installSilentAimHook() then Aim.SilentAim = false end

	Misc.FlightPanelScale = math.clamp(tonumber(Misc.FlightPanelScale) or 0.65, 0.35, 1)
	Misc.FlightV1Speed = math.clamp(tonumber(Misc.FlightV1Speed) or 50, 1, 500)
	Misc.FlightV1Height = math.clamp(tonumber(Misc.FlightV1Height) or 0, -10000, 10000)
	local ui = type(data.UI) == "table" and data.UI or {}
	if tonumber(ui.PopupScale) then PopupSettings.Scale = math.clamp(tonumber(ui.PopupScale), 0.25, 1) end
	if tonumber(ui.PopupTransparency) then PopupSettings.Transparency = math.clamp(tonumber(ui.PopupTransparency), 0, 0.9) end
	if type(ui.ShowNotifications) == "boolean" then PopupSettings.ShowNotifications = ui.ShowNotifications end
	if tonumber(ui.PopupWidth) then PopupSettings.Width = math.clamp(tonumber(ui.PopupWidth), 100, 1000) end
	if tonumber(ui.PopupHeight) then PopupSettings.Height = math.clamp(tonumber(ui.PopupHeight), 70, 700) end
	local savedBackgroundColor = tableToColor(ui.BackgroundColor)
	if savedBackgroundColor then UISettings.BackgroundColor = savedBackgroundColor end
	if tonumber(ui.BackgroundTransparency) then
		UISettings.BackgroundTransparency = math.clamp(tonumber(ui.BackgroundTransparency), 0, 0.9)
	end
	local waypoint = type(data.Waypoint) == "table" and data.Waypoint or {}
	if tonumber(waypoint.LoopInterval) then setWaypointInterval(waypoint.LoopInterval, true) end
	if tonumber(waypoint.LoopRate) then setWaypointRate(waypoint.LoopRate, true) end
	if tonumber(waypoint.WalkSpeed) then setWaypointWalkSpeed(waypoint.WalkSpeed, true) end

	-- 配置中包含标点的完整 CFrame；恢复时重建本地地图标记与动态传送按钮。
	if type(waypoint.Points) == "table" then
		destroyAllWaypoints()
		for index, savedPoint in ipairs(waypoint.Points) do
			local components = type(savedPoint) == "table" and savedPoint.Components or nil
			if type(components) == "table" and #components >= 12 then
				local values, valid = {}, true
				for i = 1, 12 do
					local value = tonumber(components[i])
					if not value or value ~= value or value == math.huge or value == -math.huge then
						valid = false
						break
					end
					values[i] = value
				end
				if valid then
					local savedCFrame = CFrame.new(
						values[1], values[2], values[3], values[4], values[5], values[6],
						values[7], values[8], values[9], values[10], values[11], values[12]
					)
					local point = {
						Index = #WaypointState.Points + 1,
						Name = tostring(#WaypointState.Points + 1) .. "标点",
						CFrame = savedCFrame, Visual = nil, Button = nil,
					}
					local visualOk, visual = pcall(function()
						return createWaypointVisual(point.Index, savedCFrame)
					end)
					if visualOk then point.Visual = visual end
					local pos = savedCFrame.Position
					local description = string.format("点击传送 · X %.1f  Y %.1f  Z %.1f", pos.X, pos.Y, pos.Z)
					local buttonOk, button = pcall(function()
						return WaypointTab:Button({
							Title = point.Name, Desc = description, Icon = "map-pin", Justify = "Center",
							Callback = function()
								if teleportToWaypoint(point, false) then
									notify("标点传送", "已传送到 " .. point.Name, "check", 2)
								end
							end,
						})
					end)
					if buttonOk then point.Button = button end
					table.insert(WaypointState.Points, point)
				end
			end
		end
	end

	-- 同步控件显示值；Set 不可用的个别 WindUI 控件不会影响配置状态恢复。
	for _, binding in ipairs(ConfigBindings) do
		local control = trackedControls[binding.id]
		if control then
			local value = stateGroups[binding.group][binding.field]
			if binding.toUI then value = binding.toUI(value) end
			pcall(function() if control.Set then control:Set(value) end end)
		end
	end
	applyPopupSettings()
	applyUIBackgroundColor(UISettings.BackgroundColor)
	applyWindowTransparency(UISettings.BackgroundTransparency)
	pcall(refreshFlightPanel)
	pcall(function() if PopupSizeControl and PopupSizeControl.Set then PopupSizeControl:Set(PopupSettings.Scale * 100) end end)
	pcall(function() if PopupTransparencyControl and PopupTransparencyControl.Set then PopupTransparencyControl:Set(PopupSettings.Transparency * 100) end end)
	pcall(function() if PopupNotifyControl and PopupNotifyControl.Set then PopupNotifyControl:Set(PopupSettings.ShowNotifications) end end)
	pcall(function() if PopupWidthControl and PopupWidthControl.Set then PopupWidthControl:Set(PopupSettings.Width) end end)
	pcall(function() if PopupHeightControl and PopupHeightControl.Set then PopupHeightControl:Set(PopupSettings.Height) end end)
	pcall(function() if UIBackgroundColorControl and UIBackgroundColorControl.Set then UIBackgroundColorControl:Set(UISettings.BackgroundColor) end end)
	pcall(function() if UIBackgroundTransparencyControl and UIBackgroundTransparencyControl.Set then UIBackgroundTransparencyControl:Set(UISettings.BackgroundTransparency * 100) end end)
	refreshESPNow()
	-- 启动配置中的飞行模式（若多个模式同时为 true，则按 V3 > V2 > V1 处理）。
	-- 老版本配置可能包含“持续上升/持续下降”字段，升级后忽略并清零。
	Misc.FlightAscend, Misc.FlightDescend = false, false
	local savedFlightMode = flightModeFromSettings()
	if savedFlightMode then
		setFlightMode(savedFlightMode, true, true)
	else
		setFlightMode("V1", false, true)
	end
	pcall(function() if FlightV2SpeedInput and FlightV2SpeedInput.Set then FlightV2SpeedInput:Set(tostring(Misc.FlightV2Speed)) end end)
	pcall(function() if FlightV3SpeedInput and FlightV3SpeedInput.Set then FlightV3SpeedInput:Set(tostring(Misc.FlightV3Speed)) end end)
	local hum = getHumanoid()
	if hum and not FlightRuntime.Mode then
		hum.WalkSpeed = Misc.SpeedOn and Misc.Speed or (Misc.NoclipOn and Misc.NoclipSpeed or 16)
		hum.JumpPower = Misc.JumpOn and Misc.JumpPower or 50
	end
	notify("配置加载完成", "已恢复自瞄、绘制、移动、飞行、界面外观、弹窗设置及标点。", "check", 4)
end

local function deleteConfig()
	if type(delfile) ~= "function" then
		notify("删除配置失败", "当前执行器不支持 delfile 文件接口。", "alert-triangle", 5)
		return
	end
	local paths = { CONFIG_FILE, CONFIG_FALLBACK }
	local deleted = false
	for _, path in ipairs(paths) do
		local exists = true
		if type(isfile) == "function" then
			local ok, result = pcall(isfile, path)
			exists = ok and result == true
		end
		if exists then
			local ok = pcall(delfile, path)
			if ok then deleted = true end
		end
	end
	if deleted then notify("配置已删除", "本地 Neumorph 配置文件已删除。", "check", 4)
	else notify("没有找到配置", "未发现可删除的配置文件。", "info", 4) end
end

-- 弹窗控制集中在“弹窗”分类中；默认宽 300、高/长 220，最终显示尺寸统一乘以缩放比例。
-- 主窗口右上角的原生关闭确认框不属于此自定义弹窗系统，保持 WindUI 原样。
safe("弹窗设置分类", function()
	local s = section(SettingsTab, { Title = "弹窗", Desc = "控制右下角操作弹窗的大小、尺寸与提示行为", Icon = "app-window", Opened = true })
	PopupSizeControl = s:Slider({
		Title = "弹窗大小", Desc = "整体缩放 25%–100%；默认 50%",
		IsTooltip = true, IsTextbox = true,
		Value = { Min = 25, Max = 100, Default = math.floor(PopupSettings.Scale * 100 + 0.5) }, Step = 5,
		Callback = function(value)
			PopupSettings.Scale = math.clamp(tonumber(value) or 50, 25, 100) / 100
			applyPopupSettings()
		end,
	})
	PopupTransparencyControl = s:Slider({
		Title = "弹窗背景透明度", Desc = "0% 不透明，90% 高透明",
		IsTooltip = true, IsTextbox = true,
		Value = { Min = 0, Max = 90, Default = 12 }, Step = 2,
		Callback = function(value)
			PopupSettings.Transparency = math.clamp(tonumber(value) or 12, 0, 90) / 100
			applyPopupSettings()
		end,
	})
	PopupNotifyControl = s:Toggle({
		Title = "显示提示", Desc = "关闭后不再显示操作成功/失败通知，但确认弹窗仍会显示",
		Icon = "bell", Value = true,
		Callback = function(value) PopupSettings.ShowNotifications = value end,
	})
	PopupWidthControl = s:Slider({
		Title = "弹窗宽度", Desc = "基础宽度 100–1000 像素；默认 300，最终显示宽度受弹窗大小比例影响",
		IsTooltip = true, IsTextbox = true,
		Value = { Min = 100, Max = 1000, Default = PopupSettings.Width }, Step = 20,
		Callback = function(value)
			PopupSettings.Width = math.clamp(tonumber(value) or 300, 100, 1000)
			applyPopupSettings()
		end,
	})
	PopupHeightControl = s:Slider({
		Title = "弹窗长度", Desc = "基础高度/长度 70–700 像素；默认 220，最终显示长度受弹窗大小比例影响",
		IsTooltip = true, IsTextbox = true,
		Value = { Min = 70, Max = 700, Default = PopupSettings.Height }, Step = 20,
		Callback = function(value)
			PopupSettings.Height = math.clamp(tonumber(value) or 220, 70, 700)
			applyPopupSettings()
		end,
	})
end)
gap(SettingsTab)

safe("界面背景色分类", function()
	local s = section(SettingsTab, { Title = "界面外观", Desc = "自定义主窗口与分类内容面板的背景颜色及透明度", Icon = "palette", Opened = true })
	UIBackgroundColorControl = s:Colorpicker({
		Title = "设置 UI 背景色", Desc = "调整主菜单、设置页及各分类面板的背景色",
		Icon = "palette", Default = UISettings.BackgroundColor,
		Callback = function(color)
			if typeof(color) == "Color3" then applyUIBackgroundColor(color) end
		end,
	})
	UIBackgroundTransparencyControl = s:Slider({
		Title = "界面透明度", Desc = "同步控制主窗口外围和点击分类后显示的内容面板；0% 不透明，90% 高透明",
		IsTooltip = true, IsTextbox = true,
		Value = { Min = 0, Max = 90, Default = math.floor(UISettings.BackgroundTransparency * 100 + 0.5) }, Step = 10,
		Callback = function(value)
			UISettings.BackgroundTransparency = math.clamp(tonumber(value) or 10, 0, 90) / 100
			applyWindowTransparency(UISettings.BackgroundTransparency)
		end,
	})
end)
gap(SettingsTab)

safe("保存配置按钮", function()
	SettingsTab:Button({
		Title = "保存配置", Desc = "保存功能参数、弹窗设置、界面背景色与透明度",
		Icon = "save", Justify = "Between",
		Callback = function()
			openActionPopup("保存配置", "将当前功能参数保存到本地配置文件？", saveConfig, "保存")
		end,
	})
end)

gap(SettingsTab)

safe("加载配置按钮", function()
	SettingsTab:Button({
		Title = "加载配置", Desc = "从本地配置文件恢复已保存的参数",
		Icon = "folder-open", Justify = "Between",
		Callback = function()
			openActionPopup("加载配置", "加载后将覆盖当前的功能参数，是否继续？", loadConfig, "加载")
		end,
	})
end)

gap(SettingsTab)

safe("删除配置按钮", function()
	SettingsTab:Button({
		Title = "删除配置", Desc = "永久删除本地 Neumorph 配置文件",
		Icon = "trash-2", Justify = "Between",
		Callback = function()
			openActionPopup("删除配置", "删除后无法恢复，确定删除本地配置文件？", deleteConfig, "删除")
		end,
	})
end)

-- 每个按钮都有独立函数入口；把对应脚本写入函数体即可。
local OtherScriptActions = {
	[1] = function() 
	loadstring(game:HttpGet("https://raw.githubusercontent.com/vbxfhcd/BS/refs/heads/main/BS-loves_you.txt"))()-- 按钮一 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[2] = function() 
	loadstring(game:HttpGet("https://raw.githubusercontent.com/idrobsc/rob_script/refs/heads/main/rob.v4"))()-- 按钮二 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[3] = function() loadstring(game:HttpGet("https://raw.githubusercontent.com/xiaopi77/xiaopi77/main/QQ1002100032-Roblox-Pi-script.lua"))()-- 按钮三 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[4] = function() loadstring(game:HttpGet("https://raw.githubusercontent.com/roblox-ye/QQ515966991/main/ROBLOX-CNVIP-XIAOYE.lua"))()-- 按钮四 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[5] = function() -- 按钮五 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[6] = function() -- 按钮六 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[7] = function() -- 按钮七 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[8] = function() -- 按钮八 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[9] = function() -- 按钮九 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[10] = function() -- 按钮十 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[11] = function() -- 按钮十一 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[12] = function() -- 按钮十二 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[13] = function() -- 按钮十三 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[14] = function() -- 按钮十四 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[15] = function() -- 按钮十五 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[16] = function() -- 按钮十六 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[17] = function() -- 按钮十七 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[18] = function() -- 按钮十八 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[19] = function() -- 按钮十九 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[20] = function() -- 按钮二十 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[21] = function() -- 按钮二十一 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[22] = function() -- 按钮二十二 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[23] = function() -- 按钮二十三 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[24] = function() -- 按钮二十四 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[25] = function() -- 按钮二十五 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[26] = function() -- 按钮二十六 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[27] = function() -- 按钮二十七 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[28] = function() -- 按钮二十八 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[29] = function() -- 按钮二十九 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
	[30] = function() -- 按钮三十 的脚本入口
		-- 在此处粘贴/编写对应脚本。
	end,
}

local function runOtherScript(index)
	local action = OtherScriptActions[index]
	if type(action) ~= "function" then return end
	local ok, err = pcall(action)
	if not ok then
		warn("[其他脚本] 按钮 " .. tostring(index) .. " 执行出错：" .. tostring(err))
	end
end

safe("其他脚本按钮列表", function()
	local s = section(OtherScriptsTab, { Title = "脚本列表", Desc = "30 个独立脚本入口；将代码填入对应按钮函数即可", Icon = "code", Opened = true })
	for index, title in ipairs({
		"BS脚本[强烈推荐内有其他的脚本]",
		"ROB脚本",
		"皮脚本",
		"叶脚本",
		"按钮五",
		"按钮六",
		"按钮七",
		"按钮八",
		"按钮九",
		"按钮十",
		"按钮十一",
		"按钮十二",
		"按钮十三",
		"按钮十四",
		"按钮十五",
		"按钮十六",
		"按钮十七",
		"按钮十八",
		"按钮十九",
		"按钮二十",
		"按钮二十一",
		"按钮二十二",
		"按钮二十三",
		"按钮二十四",
		"按钮二十五",
		"按钮二十六",
		"按钮二十七",
		"按钮二十八",
		"按钮二十九",
		"按钮三十",
	}) do
		local buttonIndex = index
		s:Button({
			Title = title, Desc = "点击执行对应脚本入口", Icon = "play", Justify = "Between",
			Callback = function() runOtherScript(buttonIndex) end,
		})
	end
end)

-- 主界面透明度在 UI 创建后立即应用，确保首次打开时与滑动条状态一致。
applyWindowTransparency(UISettings.BackgroundTransparency)

-- 首页简介放在快速导航上方，集中说明菜单功能和基本使用方式。
safe("首页简介", function()
    local intro = section(HomeTab, {
        Title = "简介", Desc = "菜单功能说明与使用提示", Icon = "info", Opened = true,
    })
    intro:Paragraph({
        Title = "AI菜单",
        Desc = "本菜单整合自瞄追踪、人物绘制、标点传送、其他功能、设置和其他脚本。你可以通过下方快速导航切换分类，并在设置中调整界面外观、透明度、弹窗和本地配置。",
    })
    intro:Paragraph({
        Title = "使用提示",
        Desc = "首次使用建议先查看设置并保存配置。开启飞行、穿墙等移动功能时，请留意当前游戏环境；切换角色或重生后，如效果未恢复，可关闭再重新开启对应功能。",
    })
end)

-- 首页快速入口放在所有主分类创建完成之后，确保每个跳转目标都已初始化。
safe("首页快速导航", function()
    local s = section(HomeTab, {
        Title = "快速导航", Desc = "点击按钮切换到对应的大分类", Icon = "compass", Opened = true,
    })
    local function goTo(tab, index)
        if not tab then return end
        local ok, err = pcall(function()
            if type(tab.Select) == "function" then
                tab:Select()
            elseif Window and type(Window.SelectTab) == "function" then
                Window:SelectTab(index)
            elseif Window and Window.TabModule and type(Window.TabModule.SelectTab) == "function" then
                Window.TabModule:SelectTab(index)
            else
                error("找不到分类切换接口")
            end
        end)
        if not ok then
            warn("[Neumorph] 首页分类跳转失败：" .. tostring(err))
        end
    end
    s:Button({
        Title = "自瞄追踪", Desc = "自瞄、追踪、目标判断与 FOV 设置",
        Icon = "crosshair", Justify = "Between", Callback = function() goTo(AimTab, 2) end,
    })
    s:Button({
        Title = "人物绘制", Desc = "玩家与 NPC 方框、射线、信息和血量",
        Icon = "eye", Justify = "Between", Callback = function() goTo(EspTab, 3) end,
    })
    s:Button({
        Title = "标点传送", Desc = "保存坐标、传送、循环传送与标点行走",
        Icon = "map-pin", Justify = "Between", Callback = function() goTo(WaypointTab, 4) end,
    })
    s:Button({
        Title = "其他功能", Desc = "移动速度、高跳、无限跳、穿墙与飞行",
        Icon = "settings", Justify = "Between", Callback = function() goTo(MiscTab, 5) end,
    })
    s:Button({
        Title = "设置", Desc = "弹窗、界面外观与配置管理",
        Icon = "sliders-horizontal", Justify = "Between", Callback = function() goTo(SettingsTab, 6) end,
    })
    s:Button({
        Title = "其他脚本", Desc = "30 个可自行填写代码的脚本按钮",
        Icon = "code", Justify = "Between", Callback = function() goTo(OtherScriptsTab, 7) end,
    })
end)

-- ============================================================
-- 16.5 修复 Tab 悬停残留与多分类同时高亮
-- ============================================================
-- WindUI 1.6.66 在鼠标离开分类时，只恢复内层 Frame 的透明度，
-- 没有将它恢复为透明状态；当鼠标曾悬停在首页/自瞄追踪上时，
-- 内层亮色可能残留，造成两个分类看起来同时被选中。
local mainTabs = { HomeTab, AimTab, EspTab, WaypointTab, MiscTab, SettingsTab, OtherScriptsTab }
local function clearTabHoverBackground(tab)
    local main = tab and tab.UIElements and tab.UIElements.Main
    local inner = main and main:FindFirstChild("Frame")
    if inner and inner:IsA("ImageLabel") then
        inner.ImageTransparency = 1
    end
end

local function clearAllTabHoverBackgrounds()
    for _, tab in ipairs(mainTabs) do
        pcall(clearTabHoverBackground, tab)
    end
end

-- 鼠标离开/触摸结束时，强制清除内层悬停层；不改变 WindUI 外层真正的选中底色。
for _, tab in ipairs(mainTabs) do
    local main = tab and tab.UIElements and tab.UIElements.Main
    if main then
        table.insert(connections, main.MouseLeave:Connect(function()
            clearTabHoverBackground(tab)
        end))
        table.insert(connections, main.InputEnded:Connect(function()
            clearTabHoverBackground(tab)
        end))
    end
end

-- 侧栏点击、Tab:Select() 与首页快速导航都会经过 TabModule:SelectTab。
-- 包装原接口，在 WindUI 更新唯一选中 Tab 后清除所有旧悬停层，避免残留亮色。
pcall(function()
    local tabModule = Window and Window.TabModule
    local originalSelectTab = tabModule and tabModule.SelectTab
    if type(originalSelectTab) == "function" and not tabModule.__NeumorphHoverFix then
        tabModule.__NeumorphHoverFix = true
        tabModule.SelectTab = function(self, index, ...)
            local result = originalSelectTab(self, index, ...)
            task.defer(clearAllTabHoverBackgrounds)
            return result
        end
    end
end)

-- 第一次绘制时也清除 WindUI 初始鼠标位置可能触发的悬停层。
clearAllTabHoverBackgrounds()

-- 创建弹窗；失败时不影响主菜单和其他功能使用。
pcall(createActionPopup)

-- ============================================================
-- 17. 首次渲染后统一展开 Section（关键修复）
-- ============================================================
if not isCurrentRun() then
	cleanup()
	return
end

task.defer(function()
	-- WindUI 1.6.66 的 Tab 内容容器初始为隐藏状态；必须显式选择一个 Tab，
	-- 否则窗口框架虽然出现，右侧主内容区会保持空白。
	task.wait(0.25)
	local function selectHomeTab()
		if HomeTab and type(HomeTab.Select) == "function" then
			HomeTab:Select() -- WindUI 官方 Tab 选择接口
		elseif Window and type(Window.SelectTab) == "function" then
			Window:SelectTab(1)
		elseif Window and Window.TabModule and type(Window.TabModule.SelectTab) == "function" then
			Window.TabModule:SelectTab(1)
		else
			error("找不到可用的首页选择接口")
		end
	end
	local selected, selectError = pcall(selectHomeTab)
	if not selected then
		warn("[Neumorph] 首个分类自动显示失败：" .. tostring(selectError))
		pcall(function()
			if Window and Window.TabModule and Window.TabModule.SelectTab then
				Window.TabModule:SelectTab(1)
			end
		end)
	end
	-- 只在启动时选择一次首页；不延迟二次强制选择，以免覆盖用户刚刚点选的其他分类。
	task.defer(clearAllTabHoverBackgrounds)

	-- 首次显示页面后再展开各 Section，避免初始隐藏状态下展开造成高度计算错误。
	for _, sectionObject in ipairs(pendingSections) do
		pcall(function()
			if sectionObject.SetOpen then sectionObject:SetOpen(true)
			elseif sectionObject.Open then sectionObject:Open()
			elseif sectionObject.Toggle then sectionObject:Toggle()
			else sectionObject.Opened = true end
		end)
	end

	if #buildErrors > 0 then
		local message = table.concat(buildErrors, "\n")
		warn("[Neumorph] 部分界面控件未能创建：" .. message)
		pcall(function()
			HomeTab:Paragraph({
				Title = "部分控件加载异常",
				Desc = message,
			})
		end)
	end
end)

-- ============================================================
-- 18. 清理与结束
-- ============================================================
local cleanedUp = false
cleanup = function()
	if cleanedUp then return end
	cleanedUp = true
	running = false
	WaypointState.WalkEnabled = false
	Misc.FlightV1On, Misc.FlightV2On, Misc.FlightV3On = false, false, false
	destroyFlightPhysics(true)
	FlightRuntime.Mode = nil
	disconnectFlightPanelConnections()
	if FlightPanelGui then pcall(function() FlightPanelGui:Destroy() end); FlightPanelGui = nil end
	FlightPanel, FlightPanelMiniButton, FlightPanelScaleObject = nil, nil, nil
	FlightPanelButtons = {}
	destroyAllWaypoints()
	for _, conn in ipairs(connections) do
		pcall(function() conn:Disconnect() end)
	end
	connections = {}

	for _, obj in pairs(espObjects) do destroyESP(obj) end
	espObjects = {}
	coverCache = setmetatable({}, { __mode = "k" })

	silentAimTarget = nil
	Aim.SilentAim = false
	if aimFovCircle then pcall(function() aimFovCircle:Remove() end); aimFovCircle = nil end
	if trackFovCircle then pcall(function() trackFovCircle:Remove() end); trackFovCircle = nil end

	restoreNoclip()
	if PopupGui then pcall(function() PopupGui:Destroy() end); PopupGui = nil end
	PopupPanel, PopupScale, PopupTitle, PopupDescription = nil, nil, nil, nil
	pcall(function() Window:Destroy() end)
	releaseRunSlot()
end

-- 新一代实例只有在仍是当前运行代次时，才可登记为活动主 UI。
if not isCurrentRun() or closeRequested then
	cleanup()
	return
end
if genv then
	local record = genv.__NeumorphHub
	record.cleanup = cleanup
	record.window = Window
	record.destroy = function()
		pcall(function() Window:Destroy() end)
	end
	record.loading = false
end

if not DrawingLib then
	task.delay(1, function()
		notify("缺少 Drawing 支持",
			"当前执行器不支持 Drawing，人物绘制与 FOV 圈不可用；自瞄和其他功能仍可使用。",
			"alert-triangle", 8)
	end)
end

task.delay(0.8, function()
	if #buildErrors > 0 then
		notify("脚本已启动，但部分界面加载失败", table.concat(buildErrors, " | "), "alert-triangle", 10)
	else
		notify("Neumorph已加载", "首页已就绪；包含自瞄追踪、人物绘制、标点传送、其他功能（含飞行 V1-V3）和设置。", "check", 6)
	end
end)

print("[Neumorph] 加载完成。")