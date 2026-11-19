--[[
    Grow a Toilet | AutoFarm (Delta)
    Покупка яиц на конвейере, посадка на базу, вылупление, продажа, квесты, статистика.
    Данные взяты из диагностики: PlacedItems, ConveyorEggs, SellGui, QuestsFrame.
    + окно "Список туалетов" с галочками, какие подбирать.
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local VIM = game:GetService("VirtualInputManager")
local GuiService = game:GetService("GuiService")
local player = Players.LocalPlayer

--================ НАСТРОЙКИ ================--
local EGGS = {"Basic Egg", "Rare Egg", "Epic Egg", "Overload Egg", "Legendary Egg", "Darkness Egg", "Astro Egg"}

local BUY_DELAY = 0.3          -- как часто проверять конвейер
local TELEPORT_TO_EGG = false  -- false = покупать с места
local REACH_DISTANCE = 500     -- растягивание дистанции подсказок (без телепорта)
local BUY_BURST = 5          -- сколько яиц покупать за один заход (меняется кнопкой в меню)
local SELL_ALL = true       -- true = продавать ВСЕ туалеты из рюкзака (меняется кнопкой в меню)
local STOP_AT_OWNED = 0        -- 0 = покупать всегда; число = стоп, когда рюкзак+база >= числа

local PLACE_DELAY = 1.2        -- пауза между посадками яиц
local MAX_PLACE_FAILS = 3      -- после стольких неудачных посадок подряд пауза
local PLACE_RETRY_PAUSE = 15   -- длина паузы (сек), например когда база заполнена

local SELL_MAX_PRICE = 100     -- продавать только туалеты с SellPrice <= этого числа
local SELL_DELAY = 6           -- как часто проверять, есть ли что продать

-- Какие туалеты подбирать по умолчанию (имя модели в PlacedItems).
-- Дальше это можно менять галочками в окне "Список туалетов".
local PICKUP_NAMES = {
    SmallToilet = true,
    CatToilet = true,
    ParasiteToilet = true,
}
local PICKUP_DELAY = 2         -- как часто подбирать
local PICKUP_BATCH = 10        -- сколько туалетов подбирать за один заход
--===========================================--

local selectedEggs = {[EGGS[1]] = true}   -- какие яйца ПОКУПАТЬ (кнопки в главном меню)
local placeEggs = {[EGGS[1]] = true}      -- какие яйца САЖАТЬ (окно "Яйца")
local hatchEggs = {}                      -- какие яйца ВЫЛУПЛЯТЬ (окно "Яйца")
for _, n in ipairs(EGGS) do hatchEggs[n] = true end
local function selectedList()
    local list = {}
    for _, n in ipairs(EGGS) do
        if selectedEggs[n] then table.insert(list, n) end
    end
    return list
end
local on = {buy = false, place = false, hatch = false, pickup = false, sell = false, claim = false}
local stats = {bought = 0, placed = 0, hatched = 0, picked = 0, sold = 0, claimed = 0}
local busy = false

local function locked(fn)
    if busy then return end
    busy = true
    local ok, err = pcall(fn)
    busy = false
    if not ok then warn("[AutoFarm]", err) end
end

local function eggKey(eggName) return (eggName:gsub(" ", "")) end -- "Basic Egg" -> "BasicEgg"

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

local function myPlacedEggs(eggName) -- eggName = nil: все яйца
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

--==================== ПОСАДКА ЯИЦ НА БАЗУ ====================--
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

    -- случайная точка на твоём участке (с отступом от краёв)
    local s = plot.Size
    local rx = (math.random() - 0.5) * math.max(s.X - 8, 1)
    local rz = (math.random() - 0.5) * math.max(s.Z - 8, 1)
    local point = plot.CFrame:PointToWorldSpace(Vector3.new(rx, s.Y / 2, rz))

    -- камера смотрит на точку, клик в центр экрана
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
    return true -- неизвестный вид яйца вылупляем
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

--==================== ПОДБОР ТУАЛЕТОВ С БАЗЫ ====================--
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

local function findSellButton(substr)
    local g = player.PlayerGui:FindFirstChild("SellGui")
    if not g then return end
    -- в SellGui текст лежит в TextLabel внутри пустой кнопки (TextButton "1", "2"...),
    -- поэтому ищем текст у любой надписи и возвращаем ближайшую кнопку-родителя
    for _, d in ipairs(g:GetDescendants()) do
        if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text:lower():find(substr, 1, true) then
            local b = d:IsA("TextButton") and d or d:FindFirstAncestorWhichIsA("TextButton")
            if b then return b end
        end
    end
end

local function sellCheapToilets()
    local hrp, hum = getHRP(), getHum()
    if not (hrp and hum) then return end
    local function collect()
        local list = {}
        eachTool(function(t)
            if t:GetAttribute("Type") == "Toilets" and (SELL_ALL or (t:GetAttribute("SellPrice") or math.huge) <= SELL_MAX_PRICE) then
                table.insert(list, t)
            end
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

    -- продаёт один предмет-стопку (например "20x Small Toilet") до конца
    local function sellTool(t)
        local stuck = 0
        for _ = 1, 300 do
            if not t.Parent then break end
            if t.Parent ~= player.Character then
                hum:EquipTool(t)
                task.wait(0.2)
            end
            local btnAll = SELL_ALL and (findSellButton("sell my inventory") or findSellButton("sell all"))
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

--==================== КВЕСТЫ ====================--
local function questFrames()
    local main = player.PlayerGui:FindFirstChild("Main")
    local qf = main and main:FindFirstChild("QuestsFrame")
    local mf = qf and qf:FindFirstChild("MainFrame")
    return qf, mf and mf:FindFirstChild("ScrollingFrame")
end

local function claimableButtons()
    local list = {}
    local _, sf = questFrames()
    if sf then
        for _, q in ipairs(sf:GetChildren()) do
            local st = q:FindFirstChild("Status", true)
            local btn = st and (st:IsA("TextButton") and st or st:FindFirstChildWhichIsA("TextButton", true))
            if btn then
                local t = btn.Text:lower()
                if t:find("claim") and not t:find("can") and not t:find("claimed") then
                    table.insert(list, btn)
                end
            end
        end
    end
    return list
end

local function questStatusText()
    local qf = questFrames()
    local title = qf and qf:FindFirstChild("Title")
    local lbl = title and title:FindFirstChild("CompletedStatus")
    return lbl and lbl.Text or "?"
end

local function claimQuests()
    for _, btn in ipairs(claimableButtons()) do
        clickButton(btn)
        stats.claimed += 1
        task.wait(0.4)
    end
end

--==================== МЕНЮ ====================--
local FRAME_H = 480

local gui = Instance.new("ScreenGui")
gui.Name = "AutoFarmGui"
gui.ResetOnSpawn = false
local okh, hui = pcall(function() return gethui and gethui() end)
gui.Parent = (okh and hui) or player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame", gui)
frame.Size = UDim2.new(0, 240, 0, FRAME_H)
frame.Position = UDim2.new(0, 20, 0.12, 0)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
frame.BorderSizePixel = 0
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel", frame)
title.Size = UDim2.new(1, -40, 0, 30)
title.Position = UDim2.new(0, 10, 0, 0)
title.BackgroundTransparency = 1
title.Text = "Grow a Toilet AutoFarm"
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 15

local body = Instance.new("Frame", frame)
body.Size = UDim2.new(1, 0, 1, -30)
body.Position = UDim2.new(0, 0, 0, 30)
body.BackgroundTransparency = 1

local minBtn = Instance.new("TextButton", frame)
minBtn.Size = UDim2.new(0, 26, 0, 22)
minBtn.Position = UDim2.new(1, -32, 0, 4)
minBtn.Text = "–"
minBtn.TextColor3 = Color3.new(1, 1, 1)
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 16
minBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
minBtn.BorderSizePixel = 0
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 5)
local minimized = false
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    body.Visible = not minimized
    frame.Size = minimized and UDim2.new(0, 240, 0, 30) or UDim2.new(0, 240, 0, FRAME_H)
    minBtn.Text = minimized and "+" or "–"
end)

local lblStats = Instance.new("TextLabel", body)
local function updateStats()
    local made = tokens() - startTokens
    local bag, base = 0, 0
    for _, n in ipairs(selectedList()) do
        bag += countInBag(n)
        base += #myPlacedEggs(n)
    end
    lblStats.Text = string.format(
        "Рюкзак: %d | База: %d (видов яиц: %d)\nТокены за сессию: %s%d\nКуплено %d | Посажено %d | Вылуплено %d\nПродано %d | Подобрано %d",
        bag, base, #selectedList(),
        made >= 0 and "+" or "", made,
        stats.bought, stats.placed, stats.hatched, stats.sold, stats.picked)
end

local eggButtons = {}
local function refreshEggButtons()
    for n, b in pairs(eggButtons) do
        b.BackgroundColor3 = selectedEggs[n] and Color3.fromRGB(70, 130, 255) or Color3.fromRGB(50, 50, 65)
    end
    pcall(updateStats)
end

for i, name in ipairs(EGGS) do
    local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
    local b = Instance.new("TextButton", body)
    b.Size = UDim2.new(0.5, -15, 0, 26)
    b.Position = UDim2.new(col * 0.5, col == 0 and 10 or 5, 0, 4 + row * 30)
    b.Text = name
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.Gotham
    b.TextSize = 12
    b.BorderSizePixel = 0
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    b.MouseButton1Click:Connect(function()
        selectedEggs[name] = (not selectedEggs[name]) or nil
        refreshEggButtons()
    end)
    eggButtons[name] = b
end

local toggleRows = {
    {"buy", "Покупать яйца"},
    {"place", "Сажать на базу"},
    {"hatch", "Вылуплять"},
    {"pickup", "Подбирать туалеты"},
    {"sell", "Продавать туалеты"},
}
local toggleStart = 4 + math.ceil(#EGGS / 2) * 30 + 6
for i, row in ipairs(toggleRows) do
    local key, label = row[1], row[2]
    local b = Instance.new("TextButton", body)
    b.Size = UDim2.new(1, -20, 0, 26)
    b.Position = UDim2.new(0, 10, 0, toggleStart + (i - 1) * 30)
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 13
    b.BorderSizePixel = 0
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    local function refresh()
        b.Text = label .. ": " .. (on[key] and "ВКЛ" or "ВЫКЛ")
        b.BackgroundColor3 = on[key] and Color3.fromRGB(50, 160, 70) or Color3.fromRGB(170, 50, 50)
    end
    b.MouseButton1Click:Connect(function() on[key] = not on[key]; refresh() end)
    refresh()
end

-- кнопка: сколько яиц покупать за раз
local burstValues = {1, 3, 5, 10}
local burstBtn = Instance.new("TextButton", body)
burstBtn.Size = UDim2.new(1, -20, 0, 26)
burstBtn.Position = UDim2.new(0, 10, 0, toggleStart + #toggleRows * 30)
burstBtn.TextColor3 = Color3.new(1, 1, 1)
burstBtn.Font = Enum.Font.GothamBold
burstBtn.TextSize = 13
burstBtn.BackgroundColor3 = Color3.fromRGB(70, 130, 255)
burstBtn.BorderSizePixel = 0
Instance.new("UICorner", burstBtn).CornerRadius = UDim.new(0, 6)
local function refreshBurst() burstBtn.Text = "Яиц за раз: " .. BUY_BURST end
burstBtn.MouseButton1Click:Connect(function()
    local idx = 1
    for i, v in ipairs(burstValues) do if v == BUY_BURST then idx = i end end
    BUY_BURST = burstValues[idx % #burstValues + 1]
    refreshBurst()
end)
refreshBurst()

-- кнопка: продавать всё или только дешёвые
local sellModeBtn = Instance.new("TextButton", body)
sellModeBtn.Size = UDim2.new(1, -20, 0, 26)
sellModeBtn.Position = UDim2.new(0, 10, 0, toggleStart + (#toggleRows + 1) * 30)
sellModeBtn.TextColor3 = Color3.new(1, 1, 1)
sellModeBtn.Font = Enum.Font.GothamBold
sellModeBtn.TextSize = 13
sellModeBtn.BorderSizePixel = 0
Instance.new("UICorner", sellModeBtn).CornerRadius = UDim.new(0, 6)
local function refreshSellMode()
    sellModeBtn.Text = SELL_ALL and "Продажа: ВСЕ туалеты" or ("Продажа: до " .. SELL_MAX_PRICE)
    sellModeBtn.BackgroundColor3 = SELL_ALL and Color3.fromRGB(200, 120, 40) or Color3.fromRGB(70, 130, 255)
end
sellModeBtn.MouseButton1Click:Connect(function() SELL_ALL = not SELL_ALL; refreshSellMode() end)
refreshSellMode()

-- кнопка: скопировать в буфер, какие кнопки есть в окне продажи
local dumpBtn = Instance.new("TextButton", body)
dumpBtn.Size = UDim2.new(1, -20, 0, 26)
dumpBtn.Position = UDim2.new(0, 10, 0, toggleStart + (#toggleRows + 2) * 30)
dumpBtn.Text = "Кнопки продажи -> буфер"
dumpBtn.TextColor3 = Color3.new(1, 1, 1)
dumpBtn.Font = Enum.Font.Gotham
dumpBtn.TextSize = 12
dumpBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 75)
dumpBtn.BorderSizePixel = 0
Instance.new("UICorner", dumpBtn).CornerRadius = UDim.new(0, 6)
dumpBtn.MouseButton1Click:Connect(function()
    local g = player.PlayerGui:FindFirstChild("SellGui")
    local out = {"SellGui найден: " .. tostring(g ~= nil)}
    if g then
        for _, d in ipairs(g:GetDescendants()) do
            if d:IsA("TextButton") or d:IsA("TextLabel") then
                table.insert(out, d.ClassName .. " | " .. d.Name .. " | " .. d.Text .. " | видна=" .. tostring(d.Visible))
            end
        end
    end
    pcall(setclipboard, table.concat(out, "\n"))
    dumpBtn.Text = "Скопировано!"
    task.delay(1.5, function() dumpBtn.Text = "Кнопки продажи -> буфер" end)
end)

lblStats.Size = UDim2.new(1, -20, 0, 65)
lblStats.Position = UDim2.new(0, 10, 0, toggleStart + (#toggleRows + 3) * 30 + 4)
lblStats.BackgroundTransparency = 1
lblStats.TextColor3 = Color3.fromRGB(210, 210, 220)
lblStats.Font = Enum.Font.Gotham
lblStats.TextSize = 11
lblStats.TextWrapped = true
lblStats.TextXAlignment = Enum.TextXAlignment.Left
lblStats.TextYAlignment = Enum.TextYAlignment.Top

-- перетаскивание меню (мышь и тач)
local dragging, dragStart, startPos
frame.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
        dragging, dragStart, startPos = true, i.Position, frame.Position
    end
end)
UIS.InputChanged:Connect(function(i)
    if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
        local d = i.Position - dragStart
        frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
end)
UIS.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

--==================== СПИСОК ТУАЛЕТОВ (галочки) ====================--
local KNOWN_TOILETS = {
    "SmallToilet", "PoliceToilet", "ParasiteToilet", "CatToilet",
    "PoliceMutantToilet", "VacuumToilet", "AstroToilet", "AstroSpiderToilet",
    "JuggernautAstroToilet", "GlitchToilet", "TheMothership",
}

local listFrame = Instance.new("Frame", gui)
listFrame.Size = UDim2.new(0, 240, 0, 320)
listFrame.Position = UDim2.new(0, 270, 0.12, 0)
listFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
listFrame.BorderSizePixel = 0
listFrame.Visible = false
Instance.new("UICorner", listFrame).CornerRadius = UDim.new(0, 8)

local listTitle = Instance.new("TextLabel", listFrame)
listTitle.Size = UDim2.new(1, -10, 0, 30)
listTitle.Position = UDim2.new(0, 10, 0, 0)
listTitle.BackgroundTransparency = 1
listTitle.Text = "Подбирать (зелёные)"
listTitle.TextXAlignment = Enum.TextXAlignment.Left
listTitle.TextColor3 = Color3.new(1, 1, 1)
listTitle.Font = Enum.Font.GothamBold
listTitle.TextSize = 14

local scroll = Instance.new("ScrollingFrame", listFrame)
scroll.Size = UDim2.new(1, -10, 1, -36)
scroll.Position = UDim2.new(0, 5, 0, 32)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 6
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
local layout = Instance.new("UIListLayout", scroll)
layout.Padding = UDim.new(0, 4)

local function prettify(n)
    local s = n:gsub("(%l)(%u)", "%1 %2")
    s = s:gsub("(%u)(%u%l)", "%1 %2")
    return s
end

local toiletSeen = {}
local function addToilet(name)
    if toiletSeen[name] then return end
    toiletSeen[name] = true
    local b = Instance.new("TextButton", scroll)
    b.Size = UDim2.new(1, -8, 0, 28)
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 12
    b.BorderSizePixel = 0
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    local function refresh()
        local v = PICKUP_NAMES[name]
        b.Text = (v and "[x] " or "[  ] ") .. prettify(name)
        b.BackgroundColor3 = v and Color3.fromRGB(50, 160, 70) or Color3.fromRGB(60, 60, 75)
    end
    b.MouseButton1Click:Connect(function()
        PICKUP_NAMES[name] = not PICKUP_NAMES[name] or nil
        refresh()
    end)
    refresh()
end

for _, n in ipairs(KNOWN_TOILETS) do addToilet(n) end
for n in pairs(PICKUP_NAMES) do addToilet(n) end

-- новые типы туалетов добавляются сами, когда появляются в рюкзаке или на базе
task.spawn(function()
    while true do
        pcall(function()
            eachTool(function(t)
                if t:GetAttribute("Type") == "Toilets" then
                    local n = t:GetAttribute("Name")
                    if n then addToilet(n) end
                end
            end)
            local placed = workspace:FindFirstChild("PlacedItems")
            if placed then
                for _, m in ipairs(placed:GetChildren()) do
                    if isMine(m) and m:GetAttribute("Type") == "Toilets" then addToilet(m.Name) end
                end
            end
        end)
        task.wait(3)
    end
end)

-- кнопка открытия под главным меню
local listBtn = Instance.new("TextButton", frame)
listBtn.Size = UDim2.new(1, 0, 0, 26)
listBtn.Position = UDim2.new(0, 0, 1, 6)
listBtn.Text = "Список туалетов"
listBtn.TextColor3 = Color3.new(1, 1, 1)
listBtn.Font = Enum.Font.GothamBold
listBtn.TextSize = 13
listBtn.BackgroundColor3 = Color3.fromRGB(70, 130, 255)
listBtn.BorderSizePixel = 0
Instance.new("UICorner", listBtn).CornerRadius = UDim.new(0, 6)
listBtn.MouseButton1Click:Connect(function() listFrame.Visible = not listFrame.Visible end)

-- перетаскивание окна списка за заголовок
local ld, lStart, lPos
listTitle.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
        ld, lStart, lPos = true, i.Position, listFrame.Position
    end
end)
UIS.InputChanged:Connect(function(i)
    if ld and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
        local d = i.Position - lStart
        listFrame.Position = UDim2.new(lPos.X.Scale, lPos.X.Offset + d.X, lPos.Y.Scale, lPos.Y.Offset + d.Y)
    end
end)
UIS.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then ld = false end
end)

--==================== ОКНО ЯИЦ (что сажать / вылуплять) ====================--
local eggFrame = Instance.new("Frame", gui)
eggFrame.Size = UDim2.new(0, 260, 0, 320)
eggFrame.Position = UDim2.new(0, 270, 0.12, 0)
eggFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
eggFrame.BorderSizePixel = 0
eggFrame.Visible = false
Instance.new("UICorner", eggFrame).CornerRadius = UDim.new(0, 8)

local eggTitle = Instance.new("TextLabel", eggFrame)
eggTitle.Size = UDim2.new(1, -10, 0, 30)
eggTitle.Position = UDim2.new(0, 10, 0, 0)
eggTitle.BackgroundTransparency = 1
eggTitle.Text = "Яйца (зелёный = можно)"
eggTitle.TextXAlignment = Enum.TextXAlignment.Left
eggTitle.TextColor3 = Color3.new(1, 1, 1)
eggTitle.Font = Enum.Font.GothamBold
eggTitle.TextSize = 14

local eggScroll = Instance.new("ScrollingFrame", eggFrame)
eggScroll.Size = UDim2.new(1, -10, 1, -36)
eggScroll.Position = UDim2.new(0, 5, 0, 32)
eggScroll.BackgroundTransparency = 1
eggScroll.BorderSizePixel = 0
eggScroll.ScrollBarThickness = 6
eggScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
eggScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
Instance.new("UIListLayout", eggScroll).Padding = UDim.new(0, 4)

for _, name in ipairs(EGGS) do
    local row = Instance.new("Frame", eggScroll)
    row.Size = UDim2.new(1, -8, 0, 30)
    row.BackgroundTransparency = 1

    local lbl = Instance.new("TextLabel", row)
    lbl.Size = UDim2.new(0.4, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = name
    lbl.TextColor3 = Color3.new(1, 1, 1)
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 11
    lbl.TextWrapped = true
    lbl.TextXAlignment = Enum.TextXAlignment.Left

    local function makeToggle(xScale, label, set)
        local b = Instance.new("TextButton", row)
        b.Size = UDim2.new(0.29, -3, 1, 0)
        b.Position = UDim2.new(xScale, 0, 0, 0)
        b.Text = label
        b.TextColor3 = Color3.new(1, 1, 1)
        b.Font = Enum.Font.GothamBold
        b.TextSize = 11
        b.BorderSizePixel = 0
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
        local function refresh()
            b.BackgroundColor3 = set[name] and Color3.fromRGB(50, 160, 70) or Color3.fromRGB(170, 50, 50)
        end
        b.MouseButton1Click:Connect(function()
            set[name] = (not set[name]) or nil
            refresh()
        end)
        refresh()
    end
    makeToggle(0.41, "Сажать", placeEggs)
    makeToggle(0.71, "Вылупл.", hatchEggs)
end

-- кнопка открытия окна яиц (под кнопкой списка туалетов)
local eggBtn = Instance.new("TextButton", frame)
eggBtn.Size = UDim2.new(1, 0, 0, 26)
eggBtn.Position = UDim2.new(0, 0, 1, 38)
eggBtn.Text = "Яйца: сажать / вылуплять"
eggBtn.TextColor3 = Color3.new(1, 1, 1)
eggBtn.Font = Enum.Font.GothamBold
eggBtn.TextSize = 13
eggBtn.BackgroundColor3 = Color3.fromRGB(70, 130, 255)
eggBtn.BorderSizePixel = 0
Instance.new("UICorner", eggBtn).CornerRadius = UDim.new(0, 6)
eggBtn.MouseButton1Click:Connect(function()
    eggFrame.Visible = not eggFrame.Visible
    if eggFrame.Visible then listFrame.Visible = false end
end)
listBtn.MouseButton1Click:Connect(function()
    if listFrame.Visible then eggFrame.Visible = false end
end)

-- перетаскивание окна яиц за заголовок
local ed, eStart, ePos
eggTitle.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
        ed, eStart, ePos = true, i.Position, eggFrame.Position
    end
end)
UIS.InputChanged:Connect(function(i)
    if ed and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
        local d = i.Position - eStart
        eggFrame.Position = UDim2.new(ePos.X.Scale, ePos.X.Offset + d.X, ePos.Y.Scale, ePos.Y.Offset + d.Y)
    end
end)
UIS.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then ed = false end
end)

--==================== ЦИКЛЫ ====================--
local function loop(delay, fn)
    task.spawn(function()
        while true do
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
    if on.pickup then pickupToilets() end
end)

loop(SELL_DELAY, function()
    if on.sell then locked(sellCheapToilets) end
end)

-- статистика: купленные яйца считаем по росту числа яиц в рюкзаке
local lastEggs = totalEggsInBag()
loop(1, function()
    local cur = totalEggsInBag()
    if cur > lastEggs then stats.bought += cur - lastEggs end
    lastEggs = cur
    updateStats()
end)

-- посажено / вылуплено считаем по появлению и исчезновению моих яиц на базе
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

refreshEggButtons()
