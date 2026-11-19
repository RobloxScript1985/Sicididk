--[[
    Grow a Toilet | AutoFarm v2 (Delta)
    Карточки с переключателем и кнопкой "+" (раскрывает настройки),
    авто-квесты Sell 500 / Sell 1000 с прогрессом, языки RU / EN / UK.
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local VIM = game:GetService("VirtualInputManager")
local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")
local player = Players.LocalPlayer

-- если скрипт запущен повторно, останавливаем старую копию
local genv = (getgenv and getgenv()) or _G
if genv.__AutoFarmStop then pcall(genv.__AutoFarmStop) end

--================ НАСТРОЙКИ (можно менять и в меню) ================--
local EGGS = {"Basic Egg", "Rare Egg", "Epic Egg", "Overload Egg", "Legendary Egg", "Darkness Egg", "Astro Egg"}

local BUY_DELAY = 0.3
local TELEPORT_TO_EGG = false
local REACH_DISTANCE = 500
local BUY_BURST = 5
local STOP_AT_OWNED = 0

local PLACE_DELAY = 1.2
local MAX_PLACE_FAILS = 3
local PLACE_RETRY_PAUSE = 15

local SELL_ALL = false         -- true = продавать ВСЕ туалеты, false = только дешёвые
local SELL_MAX_PRICE = 100
local SELL_DELAY = 6

local QUEST_MAX_PRICE = 100    -- цена туалета, до которой квест-режим продаёт (дешёвые первыми)
local QUESTS = {{"Sell 500 Toilets", 500}, {"Sell 1000 Toilets", 1000}}

local PICKUP_NAMES = {SmallToilet = true, CatToilet = true, ParasiteToilet = true}
local PICKUP_DELAY = 2
local PICKUP_BATCH = 10
--===================================================================--

local selectedEggs = {[EGGS[1]] = true}
local placeEggs = {[EGGS[1]] = true}
local hatchEggs = {}
for _, n in ipairs(EGGS) do hatchEggs[n] = true end

local on = {buy = false, place = false, hatch = false, pickup = false, sell = false, quest = false}
local stats = {bought = 0, placed = 0, hatched = 0, picked = 0, sold = 0, claimed = 0}
local busy = false
local running = true
local lang = "ru"

local function selectedList()
    local list = {}
    for _, n in ipairs(EGGS) do
        if selectedEggs[n] then table.insert(list, n) end
    end
    return list
end

local function locked(fn)
    if busy then return end
    busy = true
    local ok, err = pcall(fn)
    busy = false
    if not ok then warn("[AutoFarm]", err) end
end

local function eggKey(eggName) return (eggName:gsub(" ", "")) end

local function getHRP()
    local c = player.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function getHum()
    local c = player.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function tokens()
    local ls = player:FindFirstChild("leaderstats")
    local v = ls and ls:FindFirstChild("Farm Tokens")
    return v and v.Value or 0
end
local startTokens = tokens()

--==================== ИНВЕНТАРЬ / БАЗА ====================--
local function toolCount(tool)
    local n = tool.Name:match("^(%d+)x%s")
    return n and tonumber(n) or 1
end

local function eachTool(fn)
    for _, container in ipairs({player:FindFirstChild("Backpack"), player.Character}) do
        if container then
            for _, t in ipairs(container:GetChildren()) do
                if t:IsA("Tool") then fn(t) end
            end
        end
    end
end

local function countInBag(eggName)
    local key, total = eggKey(eggName), 0
    eachTool(function(t)
        if t:GetAttribute("Type") == "Eggs" and t:GetAttribute("Name") == key then
            total += toolCount(t)
        end
    end)
    return total
end

local function totalEggsInBag()
    local total = 0
    eachTool(function(t)
        if t:GetAttribute("Type") == "Eggs" then total += toolCount(t) end
    end)
    return total
end

local function findEggTool(eggName)
    local key, found = eggKey(eggName), nil
    eachTool(function(t)
        if not found and t:GetAttribute("Type") == "Eggs" and t:GetAttribute("Name") == key then
            found = t
        end
    end)
    return found
end

local function isMine(m)
    return m:GetAttribute("OwnerId") == player.UserId
end

local function myPlacedEggs(eggName)
    local placed = workspace:FindFirstChild("PlacedItems")
    local list = {}
    if placed then
        for _, m in ipairs(placed:GetChildren()) do
            if isMine(m) and m:GetAttribute("Type") == "Eggs" and (not eggName or m.Name == eggKey(eggName)) then
                table.insert(list, m)
            end
        end
    end
    return list
end

--==================== ПОКУПКА (конвейер) ====================--
local function findConveyorPrompts(eggName)
    local list = {}
    local folder = workspace:FindFirstChild("ConveyorEggs")
    if not folder then return list end
    local hrp = getHRP()
    for _, obj in ipairs(folder:GetDescendants()) do
        if obj:IsA("ProximityPrompt") and obj.Enabled and obj.ActionText == eggName then
            local part = obj.Parent
            local pos = part:IsA("BasePart") and part.Position or (part:IsA("Attachment") and part.WorldPosition)
            if pos then
                table.insert(list, {prompt = obj, pos = pos, d = hrp and (hrp.Position - pos).Magnitude or 0})
            end
        end
    end
    table.sort(list, function(x, y) return x.d < y.d end)
    return list
end

local function pressPrompt(prompt)
    if fireproximityprompt then
        fireproximityprompt(prompt)
    else
        VIM:SendKeyEvent(true, Enum.KeyCode.E, false, game)
        task.wait(0.4)
        VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game)
    end
end

local function buyEgg(eggName)
    local hrp = getHRP()
    if not hrp then return end
    local items = findConveyorPrompts(eggName)
    if #items == 0 then return end
    local oldCFrame = hrp.CFrame
    for i = 1, math.min(BUY_BURST, #items) do
        local prompt = items[i].prompt
        if prompt.Parent then
            pcall(function()
                prompt.HoldDuration = 0
                prompt.RequiresLineOfSight = false
                if not TELEPORT_TO_EGG then prompt.MaxActivationDistance = REACH_DISTANCE end
            end)
            if TELEPORT_TO_EGG then
                hrp.CFrame = CFrame.new(items[i].pos + Vector3.new(0, 3, 2))
                task.wait(0.1)
            end
            pressPrompt(prompt)
            task.wait(0.08)
            pressPrompt(prompt)
            task.wait(0.05)
        end
    end
    if TELEPORT_TO_EGG then hrp.CFrame = oldCFrame end
end

--==================== ПОСАДКА ЯИЦ ====================--
local placeFails = 0
local placePauseUntil = 0

local function getPlot()
    local name = player:GetAttribute("PlotName")
    local plots = workspace:FindFirstChild("Plots")
    return name and plots and plots:FindFirstChild(name)
end

local function placeEgg(eggName)
    if os.clock() < placePauseUntil then return end
    local plot = getPlot()
    local tool = findEggTool(eggName)
    local hum = getHum()
    local cam = workspace.CurrentCamera
    if not (plot and tool and hum and cam) then return end

    local before = #myPlacedEggs()
    hum:EquipTool(tool)
    task.wait(0.3)

    local s = plot.Size
    local rx = (math.random() - 0.5) * math.max(s.X - 8, 1)
    local rz = (math.random() - 0.5) * math.max(s.Z - 8, 1)
    local point = plot.CFrame:PointToWorldSpace(Vector3.new(rx, s.Y / 2, rz))

    local oldType, oldCF = cam.CameraType, cam.CFrame
    cam.CameraType = Enum.CameraType.Scriptable
    cam.CFrame = CFrame.lookAt(point + Vector3.new(0, 30, 8), point)
    task.wait(0.15)
    local vs = cam.ViewportSize
    local x, y = vs.X / 2, vs.Y / 2 + GuiService:GetGuiInset().Y / 2
    VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
    task.wait(0.05)
    VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
    task.wait(0.5)
    cam.CFrame = oldCF
    cam.CameraType = oldType
    hum:UnequipTools()

    if #myPlacedEggs() > before then
        placeFails = 0
    else
        placeFails += 1
        if placeFails >= MAX_PLACE_FAILS then
            placeFails = 0
            placePauseUntil = os.clock() + PLACE_RETRY_PAUSE
        end
    end
end

--==================== ВЫЛУПЛЕНИЕ ====================--
local function hatchAllowed(modelName)
    for _, n in ipairs(EGGS) do
        if eggKey(n) == modelName then return hatchEggs[n] == true end
    end
    return true
end

local function hatchReady()
    for _, m in ipairs(myPlacedEggs()) do
        local prompt = m:FindFirstChildWhichIsA("ProximityPrompt", true)
        if prompt and prompt.Enabled and prompt.ActionText == "Hatch!" and hatchAllowed(m.Name) then
            pcall(function()
                prompt.HoldDuration = 0
                prompt.MaxActivationDistance = math.max(prompt.MaxActivationDistance, REACH_DISTANCE)
            end)
            pressPrompt(prompt)
            task.wait(0.03)
        end
    end
end

--==================== ПОДБОР ТУАЛЕТОВ ====================--
local function pickupToilets()
    local placed = workspace:FindFirstChild("PlacedItems")
    if not placed then return end
    local n = 0
    for _, m in ipairs(placed:GetChildren()) do
        if isMine(m) and m:GetAttribute("Type") == "Toilets" and PICKUP_NAMES[m.Name] then
            local root = m:FindFirstChild("HumanoidRootPart")
            local prompt = root and root:FindFirstChildWhichIsA("ProximityPrompt")
            if prompt and prompt.Enabled and prompt.ActionText == "Pick up" then
                pcall(function()
                    prompt.HoldDuration = 0
                    prompt.MaxActivationDistance = math.max(prompt.MaxActivationDistance, REACH_DISTANCE)
                end)
                pressPrompt(prompt)
                n += 1
                task.wait(0.2)
                if n >= PICKUP_BATCH then break end
            end
        end
    end
end

--==================== КВЕСТЫ ====================--
local function questFrames()
    local main = player.PlayerGui:FindFirstChild("Main")
    local qf = main and main:FindFirstChild("QuestsFrame")
    local mf = qf and qf:FindFirstChild("MainFrame")
    return qf, mf and mf:FindFirstChild("ScrollingFrame")
end

local function questButton(q)
    local st = q:FindFirstChild("Status", true)
    return st and (st:IsA("TextButton") and st or st:FindFirstChildWhichIsA("TextButton", true))
end

-- читает "408/500" из метки Completion (или любой надписи точно такого вида)
local function progressOf(q)
    local lbl = q:FindFirstChild("Completion", true)
    local list = lbl and {lbl} or q:GetDescendants()
    for _, d in ipairs(list) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            local x, y = d.Text:match("^%s*([%d,]+)%s*/%s*([%d,]+)%s*$")
            if x and y then
                return tonumber((x:gsub(",", ""))), tonumber((y:gsub(",", "")))
            end
        end
    end
end

-- возвращает: текущее, цель, статус ("progress" / "claim" / "done" / nil)
local function questState(name)
    local _, sf = questFrames()
    local q = sf and sf:FindFirstChild(name)
    if not q then return nil end
    local cur, goal = progressOf(q)
    goal = goal or tonumber(name:match("(%d+)"))
    local status
    local btn = questButton(q)
    if btn then
        local t = btn.Text:lower()
        if t:find("claimed") or t:find("done") or t:find("complete") then
            status = "done"
        elseif t:find("claim") and not t:find("can") then
            status = "claim"
        else
            status = "progress"
        end
        -- кнопка ещё пишет "In Progress", но счётчик уже полный: значит, можно забирать
        if status == "progress" and cur and goal and cur >= goal then status = "claim" end
    end
    return cur, goal, status
end

local function questsPending()
    for _, q in ipairs(QUESTS) do
        local _, _, status = questState(q[1])
        if status == "progress" then return true end
    end
    return false
end

local function questStatusText()
    local qf = questFrames()
    local title = qf and qf:FindFirstChild("Title")
    local lbl = title and title:FindFirstChild("CompletedStatus")
    return lbl and lbl.Text or "?"
end

--==================== ПРОДАЖА ====================--
local function clickButton(btn)
    local done = false
    if firesignal then
        done = pcall(firesignal, btn.MouseButton1Click) or done
        pcall(firesignal, btn.Activated)
    end
    if not done and getconnections then
        for _, c in ipairs(getconnections(btn.MouseButton1Click)) do
            pcall(function() c:Fire() end)
            done = true
        end
    end
    if not done then
        local p, sz = btn.AbsolutePosition, btn.AbsoluteSize
        local x, y = p.X + sz.X / 2, p.Y + sz.Y / 2 + GuiService:GetGuiInset().Y
        VIM:SendMouseButtonEvent(x, y, 0, true, game, 1)
        task.wait(0.05)
        VIM:SendMouseButtonEvent(x, y, 0, false, game, 1)
    end
end

local function claimQuests()
    local _, sf = questFrames()
    if not sf then return end
    for _, q in ipairs(sf:GetChildren()) do
        local btn = questButton(q)
        if btn then
            local t = btn.Text:lower()
            local ready = t:find("claim") and not t:find("can") and not t:find("claimed")
            if not ready and not t:find("claimed") and not t:find("done") then
                local cur, goal = progressOf(q)
                ready = cur and goal and cur >= goal
            end
            if ready then
                clickButton(btn)
                stats.claimed += 1
                task.wait(0.4)
            end
        end
    end
end

local function findSellButton(substr)
    local g = player.PlayerGui:FindFirstChild("SellGui")
    if not g then return end
    for _, d in ipairs(g:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text:lower():find(substr, 1, true) then
            local b = d:IsA("TextButton") and d or d:FindFirstAncestorWhichIsA("TextButton")
            if b then return b end
        end
    end
end

-- nil = не продавать; число = максимальная цена туалета
local function sellLimit()
    local lim
    if on.sell then lim = SELL_ALL and math.huge or SELL_MAX_PRICE end
    if on.quest and questsPending() then
        lim = lim and math.max(lim, QUEST_MAX_PRICE) or QUEST_MAX_PRICE
    end
    return lim
end

local function sellToilets()
    local lim = sellLimit()
    if not lim then return end
    local useAll = on.sell and SELL_ALL
    local hrp, hum = getHRP(), getHum()
    if not (hrp and hum) then return end

    local function collect()
        local list = {}
        eachTool(function(t)
            if t:GetAttribute("Type") == "Toilets" and (t:GetAttribute("SellPrice") or math.huge) <= lim then
                table.insert(list, t)
            end
        end)
        table.sort(list, function(a, b)
            return (a:GetAttribute("SellPrice") or 0) < (b:GetAttribute("SellPrice") or 0)
        end)
        return list
    end
    if #collect() == 0 then return end

    local zones = workspace:FindFirstChild("Zones")
    local zone = zones and zones:FindFirstChild("SellZone")
    local oldCFrame = hrp.CFrame
    if zone then
        hrp.CFrame = zone.CFrame + Vector3.new(0, 3, 0)
        task.wait(0.6)
    end

    local function sellTool(t)
        local stuck = 0
        for i = 1, 300 do
            if not running or not t.Parent then break end
            if not (on.sell or on.quest) then break end
            -- квест-режим: проверяем, не выполнены ли уже квесты
            if not on.sell and i % 20 == 0 and not questsPending() then break end
            if t.Parent ~= player.Character then
                hum:EquipTool(t)
                task.wait(0.2)
            end
            local btnAll = useAll and (findSellButton("sell my inventory") or findSellButton("sell all"))
            local btn = btnAll or findSellButton("sell this")
            if not btn then
                stuck += 1
                if stuck >= 5 then break end
                task.wait(0.2)
            else
                local beforeTokens, beforeCount, beforeName = tokens(), toolCount(t), t.Name
                clickButton(btn)
                task.wait(0.15)
                local progress = (not t.Parent) or toolCount(t) ~= beforeCount or t.Name ~= beforeName or tokens() > beforeTokens
                if progress then
                    stats.sold += 1
                    stuck = 0
                else
                    stuck += 1
                    if stuck >= 6 then break end
                end
                if btnAll then task.wait(0.3) end
            end
        end
    end

    for _ = 1, 6 do
        local list = collect()
        if #list == 0 then break end
        for _, t in ipairs(list) do
            if t.Parent then sellTool(t) end
        end
        if #collect() >= #list then break end
    end
    hum:UnequipTools()
    if zone then hrp.CFrame = oldCFrame end
end

--==================== ЯЗЫКИ ====================--
local STR = {
    ru = {
        buy = "Покупать яйца", place = "Сажать на базу", hatch = "Вылуплять яйца",
        pickup = "Подбирать туалеты", sell = "Продавать туалеты", quest = "Авто-квесты", settings = "Настройки",
        buy_eggs = "Какие яйца покупать:", burst = "Яиц за раз",
        place_eggs = "Какие яйца сажать:", hatch_eggs = "Какие яйца вылуплять:",
        pick_list = "Какие туалеты подбирать:",
        sell_mode = "Режим", sell_all = "все туалеты", sell_cheap = "только дешёвые", sell_limit = "Макс. цена",
        quest_hint = "Продаёт туалеты до выбранной цены (дешёвые первыми), пока квесты не выполнены, и забирает награды. Для запаса включи «Подбирать туалеты».",
        quest_limit = "Макс. цена туалета", quest_any = "любая",
        q_session = "за сессию: %d", q_claim = "можно забрать", q_ok = "выполнено",
        language = "Язык", teleport = "Телепорт к яйцу", on = "ВКЛ", off = "ВЫКЛ",
        dump_quest = "Квесты → буфер (диагностика)", copied = "Скопировано!", unload = "Выгрузить скрипт",
        st_bag = "Рюкзак: %d | База: %d", st_tok = "Токены за сессию: %s%d",
        st_a = "Куплено %d | Посажено %d | Вылуплено %d", st_b = "Продано %d | Подобрано %d | Квестов забрано %d",
        st_quests = "Квесты: %s",
    },
    en = {
        buy = "Buy eggs", place = "Place on base", hatch = "Hatch eggs",
        pickup = "Pick up toilets", sell = "Sell toilets", quest = "Auto quests", settings = "Settings",
        buy_eggs = "Eggs to buy:", burst = "Eggs per cycle",
        place_eggs = "Eggs to place:", hatch_eggs = "Eggs to hatch:",
        pick_list = "Toilets to pick up:",
        sell_mode = "Mode", sell_all = "all toilets", sell_cheap = "cheap only", sell_limit = "Max price",
        quest_hint = "Sells toilets up to the chosen price (cheapest first) until the quests are done, then claims rewards. Turn on \"Pick up toilets\" for supply.",
        quest_limit = "Max toilet price", quest_any = "any",
        q_session = "this session: %d", q_claim = "ready to claim", q_ok = "completed",
        language = "Language", teleport = "Teleport to egg", on = "ON", off = "OFF",
        dump_quest = "Quests → clipboard (debug)", copied = "Copied!", unload = "Unload script",
        st_bag = "Bag: %d | Base: %d", st_tok = "Tokens this session: %s%d",
        st_a = "Bought %d | Placed %d | Hatched %d", st_b = "Sold %d | Picked up %d | Quests claimed %d",
        st_quests = "Quests: %s",
    },
    uk = {
        buy = "Купувати яйця", place = "Садити на базу", hatch = "Виводити яйця",
        pickup = "Підбирати туалети", sell = "Продавати туалети", quest = "Авто-квести", settings = "Налаштування",
        buy_eggs = "Які яйця купувати:", burst = "Яєць за раз",
        place_eggs = "Які яйця садити:", hatch_eggs = "Які яйця виводити:",
        pick_list = "Які туалети підбирати:",
        sell_mode = "Режим", sell_all = "усі туалети", sell_cheap = "лише дешеві", sell_limit = "Макс. ціна",
        quest_hint = "Продає туалети до обраної ціни (дешеві першими), поки квести не виконано, і забирає нагороди. Для запасу увімкни «Підбирати туалети».",
        quest_limit = "Макс. ціна туалету", quest_any = "будь-яка",
        q_session = "за сесію: %d", q_claim = "можна забрати", q_ok = "виконано",
        language = "Мова", teleport = "Телепорт до яйця", on = "УВІМК", off = "ВИМК",
        dump_quest = "Квести → буфер (діагностика)", copied = "Скопійовано!", unload = "Вивантажити скрипт",
        st_bag = "Рюкзак: %d | База: %d", st_tok = "Токени за сесію: %s%d",
        st_a = "Куплено %d | Посаджено %d | Виведено %d", st_b = "Продано %d | Підібрано %d | Квестів забрано %d",
        st_quests = "Квести: %s",
    },
}
local LANG_NAMES = {ru = "Русский", en = "English", uk = "Українська"}

local function tr(key, ...)
    local s = (STR[lang] and STR[lang][key]) or STR.en[key] or key
    if select("#", ...) > 0 then return s:format(...) end
    return s
end

local i18n, refreshers = {}, {}
local function bind(obj, key)
    table.insert(i18n, {obj, key})
    obj.Text = tr(key)
end

--==================== UI: ПОМОЩНИКИ ====================--
local C = {
    bg = Color3.fromRGB(16, 16, 24),
    card = Color3.fromRGB(26, 26, 38),
    chip = Color3.fromRGB(44, 44, 62),
    accent = Color3.fromRGB(120, 92, 255),
    on = Color3.fromRGB(52, 199, 120),
    off = Color3.fromRGB(78, 78, 100),
    no = Color3.fromRGB(196, 60, 82),   -- красный = выключено / нельзя
    text = Color3.fromRGB(238, 238, 248),
    muted = Color3.fromRGB(150, 150, 175),
    danger = Color3.fromRGB(220, 70, 90),
}

local function make(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end
local function corner(o, r) return make("UICorner", {CornerRadius = UDim.new(0, r)}, o) end
local function stroke(o, color, thick, transp)
    return make("UIStroke", {Color = color, Thickness = thick, Transparency = transp,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, o)
end
local function tween(o, t, props)
    TweenService:Create(o, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

local gui = make("ScreenGui", {Name = "AutoFarmGui", ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling})
do
    local ok, hui = pcall(function() return gethui and gethui() end)
    gui.Parent = (ok and hui) or player:WaitForChild("PlayerGui")
end

genv.__AutoFarmStop = function()
    running = false
    pcall(function() gui:Destroy() end)
end

local WIN_W, WIN_H = 300, 480
local win = make("Frame", {Name = "Win", Size = UDim2.new(0, WIN_W, 0, WIN_H),
    Position = UDim2.new(0, 16, 0.5, -WIN_H / 2), BackgroundColor3 = C.bg,
    BorderSizePixel = 0, ClipsDescendants = true}, gui)
corner(win, 14)
stroke(win, C.accent, 1.5, 0.35)

local header = make("Frame", {Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1}, win)
local titleLbl = make("TextLabel", {Size = UDim2.new(1, -60, 1, 0), Position = UDim2.new(0, 14, 0, 0),
    BackgroundTransparency = 1, Text = "Grow a Toilet  •  AutoFarm", TextColor3 = Color3.new(1, 1, 1),
    Font = Enum.Font.GothamBold, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left}, header)
make("UIGradient", {Color = ColorSequence.new(Color3.fromRGB(150, 120, 255), Color3.fromRGB(80, 210, 255))}, titleLbl)

local minBtn = make("TextButton", {Size = UDim2.new(0, 30, 0, 30), Position = UDim2.new(1, -40, 0.5, -15),
    BackgroundColor3 = C.chip, Text = "–", TextColor3 = C.text, Font = Enum.Font.GothamBold,
    TextSize = 18, AutoButtonColor = false, BorderSizePixel = 0}, header)
corner(minBtn, 8)

local scroll = make("ScrollingFrame", {Size = UDim2.new(1, 0, 1, -46), Position = UDim2.new(0, 0, 0, 46),
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4,
    ScrollBarImageColor3 = C.accent, CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y}, win)
make("UIListLayout", {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder}, scroll)
make("UIPadding", {PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 10),
    PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 14)}, scroll)

local minimized = false
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    if minimized then
        scroll.Visible = false
        tween(win, 0.25, {Size = UDim2.new(0, WIN_W, 0, 44)})
    else
        tween(win, 0.25, {Size = UDim2.new(0, WIN_W, 0, WIN_H)})
        task.delay(0.15, function() if not minimized then scroll.Visible = true end end)
    end
    minBtn.Text = minimized and "+" or "–"
end)

-- перетаскивание окна за заголовок
do
    local dragging, dragStart, startPos
    header.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, i.Position, win.Position
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - dragStart
            win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

--==================== UI: КАРТОЧКИ ====================--
local order = 0

-- Карточка: заголовок + переключатель (по желанию) + кнопка "+", раскрывающая настройки
local function Card(key, withSwitch)
    order += 1
    local card = make("Frame", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = C.card, BorderSizePixel = 0, LayoutOrder = order}, scroll)
    corner(card, 10)
    stroke(card, C.accent, 1, 0.8)
    make("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder}, card)

    local head = make("Frame", {Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1, LayoutOrder = 1}, card)
    local bar = make("Frame", {Size = UDim2.new(0, 3, 0, 22), Position = UDim2.new(0, 0, 0.5, -11),
        BackgroundColor3 = C.no, BorderSizePixel = 0}, head)
    corner(bar, 2)
    local lbl = make("TextLabel", {Size = UDim2.new(1, withSwitch and -110 or -56, 1, 0),
        Position = UDim2.new(0, 14, 0, 0), BackgroundTransparency = 1, TextColor3 = C.text,
        Font = Enum.Font.GothamBold, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left}, head)
    bind(lbl, key)

    local plus = make("TextButton", {Size = UDim2.new(0, 30, 0, 30), Position = UDim2.new(1, -38, 0.5, -15),
        BackgroundColor3 = C.chip, Text = "+", TextColor3 = C.text, Font = Enum.Font.GothamBold,
        TextSize = 20, AutoButtonColor = false, BorderSizePixel = 0}, head)
    corner(plus, 8)

    local sw, knob
    if withSwitch then
        sw = make("TextButton", {Size = UDim2.new(0, 44, 0, 24), Position = UDim2.new(1, -90, 0.5, -12),
            BackgroundColor3 = C.no, Text = "", AutoButtonColor = false, BorderSizePixel = 0}, head)
        corner(sw, 12)
        knob = make("Frame", {Size = UDim2.new(0, 18, 0, 18), Position = UDim2.new(0, 3, 0.5, -9),
            BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0}, sw)
        corner(knob, 9)
    end

    local function paint()
        local v = withSwitch and on[key]
        if sw then
            tween(sw, 0.18, {BackgroundColor3 = v and C.on or C.no})
            tween(knob, 0.18, {Position = v and UDim2.new(1, -21, 0.5, -9) or UDim2.new(0, 3, 0.5, -9)})
        end
        tween(bar, 0.18, {BackgroundColor3 = v and C.on or C.no})
    end
    if sw then
        sw.MouseButton1Click:Connect(function()
            on[key] = not on[key]
            paint()
        end)
    end

    local content = make("Frame", {Size = UDim2.new(1, 0, 0, 0), BackgroundTransparency = 1,
        ClipsDescendants = true, LayoutOrder = 2}, card)
    local inner = make("Frame", {Size = UDim2.new(1, -20, 0, 0), Position = UDim2.new(0, 10, 0, 2),
        AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1}, content)
    local innerList = make("UIListLayout", {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder}, inner)

    local open = false
    local function height() return innerList.AbsoluteContentSize.Y + 12 end
    plus.MouseButton1Click:Connect(function()
        open = not open
        plus.Text = open and "×" or "+"
        tween(plus, 0.2, {BackgroundColor3 = open and C.accent or C.chip})
        tween(content, 0.28, {Size = UDim2.new(1, 0, 0, open and height() or 0)})
    end)
    innerList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        if open then content.Size = UDim2.new(1, 0, 0, height()) end
    end)

    paint()
    return inner
end

local function Muted(parent, key)
    local l = make("TextLabel", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1, TextColor3 = C.muted, Font = Enum.Font.Gotham, TextSize = 11,
        TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left}, parent)
    bind(l, key)
    return l
end

-- сетка кнопок-галочек
local function ChipGrid(parent, set, labelFn)
    local grid = make("Frame", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1}, parent)
    make("UIGridLayout", {CellSize = UDim2.new(0.5, -3, 0, 28), CellPadding = UDim2.new(0, 6, 0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder}, grid)
    local chips = {}
    local api = {}
    function api.add(name)
        if chips[name] then return end
        local b = make("TextButton", {Text = labelFn and labelFn(name) or name, TextColor3 = C.text,
            Font = Enum.Font.GothamBold, TextSize = 11, TextWrapped = true, AutoButtonColor = false,
            BorderSizePixel = 0, BackgroundColor3 = set[name] and C.on or C.no}, grid)
        corner(b, 8)
        chips[name] = b
        b.MouseButton1Click:Connect(function()
            set[name] = (not set[name]) or nil
            tween(b, 0.15, {BackgroundColor3 = set[name] and C.on or C.no})
        end)
    end
    return api
end

-- кнопка, перебирающая значения по кругу
local function Cycle(parent, labelKey, values, get, set, fmt)
    local b = make("TextButton", {Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = C.chip,
        TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 12, AutoButtonColor = false,
        BorderSizePixel = 0}, parent)
    corner(b, 8)
    local function paint() b.Text = tr(labelKey) .. ": " .. fmt(get()) end
    b.MouseButton1Click:Connect(function()
        local idx = 1
        for i, v in ipairs(values) do
            if v == get() then idx = i end
        end
        set(values[idx % #values + 1])
        paint()
    end)
    table.insert(refreshers, paint)
    paint()
    return b
end

local function ActionButton(parent, key, color, fn)
    local b = make("TextButton", {Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = color or C.chip,
        TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 12, AutoButtonColor = false,
        BorderSizePixel = 0}, parent)
    corner(b, 8)
    bind(b, key)
    b.MouseButton1Click:Connect(function() fn(b) end)
    return b
end

local function ProgressRow(parent, name)
    local row = make("Frame", {Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1}, parent)
    make("TextLabel", {Size = UDim2.new(0.55, 0, 0, 16), BackgroundTransparency = 1, Text = name,
        TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left}, row)
    local valLbl = make("TextLabel", {Size = UDim2.new(0.45, 0, 0, 16), Position = UDim2.new(0.55, 0, 0, 0),
        BackgroundTransparency = 1, Text = "", TextColor3 = C.muted, Font = Enum.Font.GothamBold,
        TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right}, row)
    local track = make("Frame", {Size = UDim2.new(1, 0, 0, 8), Position = UDim2.new(0, 0, 0, 22),
        BackgroundColor3 = C.chip, BorderSizePixel = 0}, row)
    corner(track, 4)
    local fill = make("Frame", {Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = C.accent, BorderSizePixel = 0}, track)
    corner(fill, 4)
    return function(text, frac, color)
        valLbl.Text = text
        tween(fill, 0.3, {Size = UDim2.new(math.clamp(frac, 0, 1), 0, 1, 0), BackgroundColor3 = color or C.accent})
    end
end

local function prettify(n)
    local s = n:gsub("(%l)(%u)", "%1 %2")
    s = s:gsub("(%u)(%u%l)", "%1 %2")
    return s
end

local function onOff(v) return v and tr("on") or tr("off") end

--==================== UI: СБОРКА КАРТОЧЕК ====================--
local updateStats, updateQuestUI

do -- Покупка
    local inner = Card("buy", true)
    Muted(inner, "buy_eggs")
    local g = ChipGrid(inner, selectedEggs)
    for _, n in ipairs(EGGS) do g.add(n) end
    Cycle(inner, "burst", {1, 3, 5, 10}, function() return BUY_BURST end,
        function(v) BUY_BURST = v end, tostring)
end

do -- Посадка
    local inner = Card("place", true)
    Muted(inner, "place_eggs")
    local g = ChipGrid(inner, placeEggs)
    for _, n in ipairs(EGGS) do g.add(n) end
end

do -- Вылупление
    local inner = Card("hatch", true)
    Muted(inner, "hatch_eggs")
    local g = ChipGrid(inner, hatchEggs)
    for _, n in ipairs(EGGS) do g.add(n) end
end

do -- Подбор туалетов
    local inner = Card("pickup", true)
    Muted(inner, "pick_list")
    local g = ChipGrid(inner, PICKUP_NAMES, prettify)
    local known = {"SmallToilet", "PoliceToilet", "ParasiteToilet", "CatToilet", "PoliceMutantToilet",
        "VacuumToilet", "AstroToilet", "AstroSpiderToilet", "JuggernautAstroToilet", "GlitchToilet", "TheMothership"}
    for _, n in ipairs(known) do g.add(n) end
    for n in pairs(PICKUP_NAMES) do g.add(n) end
    -- новые типы туалетов добавляются сами
    task.spawn(function()
        while running do
            pcall(function()
                eachTool(function(t)
                    if t:GetAttribute("Type") == "Toilets" then
                        local n = t:GetAttribute("Name")
                        if n then g.add(n) end
                    end
                end)
                local placed = workspace:FindFirstChild("PlacedItems")
                if placed then
                    for _, m in ipairs(placed:GetChildren()) do
                        if isMine(m) and m:GetAttribute("Type") == "Toilets" then g.add(m.Name) end
                    end
                end
            end)
            task.wait(3)
        end
    end)
end

do -- Продажа
    local inner = Card("sell", true)
    Cycle(inner, "sell_mode", {false, true}, function() return SELL_ALL end,
        function(v) SELL_ALL = v end, function(v) return v and tr("sell_all") or tr("sell_cheap") end)
    Cycle(inner, "sell_limit", {50, 100, 500, 1000, 5000, 10000}, function() return SELL_MAX_PRICE end,
        function(v) SELL_MAX_PRICE = v end, tostring)
end

do -- Авто-квесты
    local inner = Card("quest", true)
    Muted(inner, "quest_hint")
    local rows = {}
    for _, q in ipairs(QUESTS) do rows[q[1]] = ProgressRow(inner, q[1]) end
    Cycle(inner, "quest_limit", {100, 500, 1000, 5000, 1e9}, function() return QUEST_MAX_PRICE end,
        function(v) QUEST_MAX_PRICE = v end,
        function(v) return v >= 1e9 and tr("quest_any") or tostring(v) end)

    function updateQuestUI()
        for _, q in ipairs(QUESTS) do
            local cur, goal, status = questState(q[1])
            goal = goal or q[2]
            local setRow = rows[q[1]]
            if status == "done" then
                setRow(tr("q_ok"), 1, C.on)
            elseif status == "claim" then
                setRow(tr("q_claim"), 1, C.on)
            elseif cur then
                setRow(string.format("%d / %d", cur, goal), cur / goal)
            elseif status == nil then
                setRow("—", 0)
            else
                setRow(tr("q_session", stats.sold) .. " / " .. goal, stats.sold / goal)
            end
        end
    end
end

do -- Настройки
    local inner = Card("settings", false)
    local names = {"ru", "en", "uk"}
    Cycle(inner, "language", names, function() return lang end, function(v)
        lang = v
        for _, e in ipairs(i18n) do e[1].Text = tr(e[2]) end
        for _, f in ipairs(refreshers) do pcall(f) end
        pcall(updateStats)
        pcall(updateQuestUI)
    end, function(v) return LANG_NAMES[v] end)
    Cycle(inner, "teleport", {false, true}, function() return TELEPORT_TO_EGG end,
        function(v) TELEPORT_TO_EGG = v end, onOff)
    ActionButton(inner, "dump_quest", C.chip, function(b)
        local out = {}
        local _, sf = questFrames()
        for _, q in ipairs(QUESTS) do
            local f = sf and sf:FindFirstChild(q[1])
            table.insert(out, "== " .. q[1] .. ": " .. (f and "found" or "missing"))
            if f then
                for _, d in ipairs(f:GetDescendants()) do
                    local extra = ""
                    if d:IsA("TextLabel") or d:IsA("TextButton") then extra = d.Text
                    elseif d:IsA("Frame") then extra = tostring(d.Size) end
                    table.insert(out, d.ClassName .. " | " .. d.Name .. " | " .. extra)
                end
            end
        end
        pcall(setclipboard, table.concat(out, "\n"))
        b.Text = tr("copied")
        task.delay(1.5, function() b.Text = tr("dump_quest") end)
    end)
    ActionButton(inner, "unload", C.danger, function() genv.__AutoFarmStop() end)
end

do -- Статистика
    order += 1
    local card = make("Frame", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = C.card, BorderSizePixel = 0, LayoutOrder = order}, scroll)
    corner(card, 10)
    stroke(card, C.accent, 1, 0.8)
    make("UIPadding", {PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
        PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12)}, card)
    local lbl = make("TextLabel", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1, TextColor3 = C.muted, Font = Enum.Font.Gotham, TextSize = 11,
        TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top, Text = ""}, card)

    function updateStats()
        local bag, base = 0, 0
        for _, n in ipairs(selectedList()) do
            bag += countInBag(n)
            base += #myPlacedEggs(n)
        end
        local made = tokens() - startTokens
        lbl.Text = table.concat({
            tr("st_bag", bag, base),
            tr("st_tok", made >= 0 and "+" or "", made),
            tr("st_a", stats.bought, stats.placed, stats.hatched),
            tr("st_b", stats.sold, stats.picked, stats.claimed),
            tr("st_quests", questStatusText()),
        }, "\n")
    end
end

--==================== ЦИКЛЫ ====================--
local function loop(delay, fn)
    task.spawn(function()
        while running do
            pcall(fn)
            task.wait(delay)
        end
    end)
end

loop(BUY_DELAY, function()
    if not on.buy then return end
    for _, egg in ipairs(selectedList()) do
        local owned = countInBag(egg) + #myPlacedEggs(egg)
        if not (STOP_AT_OWNED > 0 and owned >= STOP_AT_OWNED) then
            locked(function() buyEgg(egg) end)
        end
    end
end)

local placeIdx = 0
loop(PLACE_DELAY, function()
    if not on.place then return end
    local list = {}
    for _, n in ipairs(EGGS) do
        if placeEggs[n] then table.insert(list, n) end
    end
    for _ = 1, #list do
        placeIdx = placeIdx % #list + 1
        local egg = list[placeIdx]
        if findEggTool(egg) then
            locked(function() placeEgg(egg) end)
            break
        end
    end
end)

loop(0.5, function()
    if on.hatch then hatchReady() end
end)

loop(PICKUP_DELAY, function()
    if on.pickup or (on.quest and questsPending()) then pickupToilets() end
end)

loop(SELL_DELAY, function()
    if sellLimit() then locked(sellToilets) end
end)

loop(5, function()
    if on.quest then claimQuests() end
end)

local lastEggs = totalEggsInBag()
loop(1, function()
    local cur = totalEggsInBag()
    if cur > lastEggs then stats.bought += cur - lastEggs end
    lastEggs = cur
    updateStats()
end)

loop(2, function() updateQuestUI() end)

local placedFolder = workspace:FindFirstChild("PlacedItems")
if placedFolder then
    placedFolder.ChildAdded:Connect(function(c)
        task.wait(0.2)
        if isMine(c) and c:GetAttribute("Type") == "Eggs" then stats.placed += 1 end
    end)
    placedFolder.ChildRemoved:Connect(function(c)
        if isMine(c) then
            local t = c:GetAttribute("Type")
            if t == "Eggs" then stats.hatched += 1 elseif t == "Toilets" then stats.picked += 1 end
        end
    end)
end

pcall(updateStats)
pcall(updateQuestUI)
