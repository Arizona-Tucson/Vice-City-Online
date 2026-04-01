--?? fix by st1q ( Scaramouche_Shute ) --??

local url = "https://api.arizona-five.com/launcher/servers"

local autoVcEnabled = true
local sampev = require 'samp.events'

local ANTI_AD_DIALOG_ID = 25624

local logFile = getWorkingDirectory() .. "\\vc_log.json"
local userLogs = {}

local userCooldowns = {}
local COOLDOWN_TIME = 120

local globalMessages = {}
local MAX_MESSAGES_PER_MINUTE = 3

local needCloseDialog = false
local lastGlobalAnswerTime = 0

local recentVcMessages = {}
local DUPLICATE_WINDOW = 7 

local lastQueueRequestNick = nil
local lastQueueRequestTime = 0
local QUEUE_REQUEST_WINDOW = 5

-- ================= ПЕРЕМЕННЫЕ ДЛЯ ЗАДЕРЖКИ VC =================
local vcDelayRange = { min = 0.2, max = 3.0 }

-- ================= JSON =================
local function encodeJSON(tbl)
    local str = "{\n"
    for k, v in pairs(tbl) do
        str = str .. string.format('"%s": {"count": %d, "last_time": "%s"},\n',
            k, v.count or 0, v.last_time or "")
    end
    str = str:gsub(",\n$", "\n")
    str = str .. "}"
    return str
end

local function decodeJSON(str)
    local result = {}
    for name, count, time in str:gmatch('"(.-)":%s*{.-"count":%s*(%d+).-"last_time":%s*"(.-)".-}') do
        result[name] = {
            count = tonumber(count),
            last_time = time
        }
    end
    return result
end

-- ================= АНТИ-ДУБЛИКАТ =================
local function normalizeText(text)
    return text:lower()
        :gsub("o", "о")
        :gsub("a", "а")
        :gsub("e", "е")
        :gsub("p", "р")
end

local function isDuplicateVc(text)
    local now = os.time()
    local norm = normalizeText(text)

    -- очищаем старые сообщения
    for i = #recentVcMessages, 1, -1 do
        if now - recentVcMessages[i].time > DUPLICATE_WINDOW then
            table.remove(recentVcMessages, i)
        end
    end

    -- проверка на дубликаты
    for _, msg in ipairs(recentVcMessages) do
        if msg.text == norm then
            return true
        end
    end

    return false
end

local function rememberVc(text)
    table.insert(recentVcMessages, {
        text = normalizeText(text),
        time = os.time()
    })
end

-- ================= ИГНОР СЕБЯ =================
local function isMyNick(nickname)
    if not nickname then return false end
    if not isSampAvailable() then return false end
    if not sampIsLocalPlayerSpawned() then return false end

    local result, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if not result then return false end

    local myName = sampGetPlayerNickname(id)
    if not myName then return false end

    nickname = nickname:lower():gsub("%s+", "")
    myName = myName:lower():gsub("%s+", "")

    return nickname == myName
end

local function mutateText(text)
    local replacements = {
        ["О"] = {"О", "O"}, ["о"] = {"о", "o"},
        ["А"] = {"А", "A"}, ["а"] = {"а", "a"},
        ["Е"] = {"Е", "E"}, ["е"] = {"е", "e"},
        ["Р"] = {"Р", "P"}, ["р"] = {"р", "p"}
    }

    local result = ""
    for char in text:gmatch(".") do
        if replacements[char] then
            local variants = replacements[char]
            result = result .. variants[math.random(#variants)]
        else
            result = result .. char
        end
    end
    return result
end

local messageVariants = {
    "[VC] %s :palm_tree: | Онлайн: %s/%s :u1f465: | Очередь: %s :u23f3:",
    "[VC] %s :palm_tree: | Онлaйн: %s/%s :u1f465: | Очeрeдь: %s :u23f3:",
    "[VC] %s :palm_tree: | Oнлайн: %s/%s :u1f465: | Очередь: %s :u23f3:",
    "[VC] %s :palm_tree: | Онлайн: %s/%s :u1f465: | Oчередь: %s :u23f3:",
    "[VC] %s :palm_tree: | Онлайn: %s/%s :u1f465: | Очередь: %s :u23f3:"
}

-- ================= MAIN =================
function main()
    while not isSampAvailable() do wait(0) end

    loadLogs()

    sampRegisterChatCommand('vc', function()
        getVcServer(false, nil)
    end)

    sampRegisterChatCommand('vcoff', disableAutoVc)
    sampRegisterChatCommand('vcon', enableAutoVc)
    
    sampRegisterChatCommand('vchelp', function()
        sampAddChatMessage("{00FFAA}[VC]{FFFFFF} Доступные команды:", -1)
        sampAddChatMessage("{00FFAA}/vc{FFFFFF} - запросить VC сервер", -1)
        sampAddChatMessage("{00FFAA}/vcon{FFFFFF} - включить автоответ VC", -1)
        sampAddChatMessage("{00FFAA}/vcoff{FFFFFF} - выключить автоответ VC", -1)
        sampAddChatMessage("{00FFAA}/vcdup <секунды>{FFFFFF} - изменить окно проверки дубликатов сообщений", -1)
        sampAddChatMessage("{00FFAA}/vcdelay <min> <max>{FFFFFF} - изменить диапазон задержки ответа VC в секундах", -1)
    end)

    sampRegisterChatCommand('vcdup', function(param)
        if not param or param == "" then
            sampAddChatMessage(string.format("{00FFAA}[VC]{FFFFFF} Текущее окно дубликатов: %d сек", DUPLICATE_WINDOW), -1)
            return
        end

        local newWindow = tonumber(param)
        if not newWindow or newWindow <= 0 then
            sampAddChatMessage("{FF4444}[VC]{FFFFFF} Ошибка: используйте /vcdup <секунды>", -1)
            return
        end

        if newWindow > vcDelayRange.min then
            sampAddChatMessage(string.format("{FF4444}[VC]{FFFFFF} Ошибка: окно дубликатов не может быть больше минимальной задержки VC (%.1f сек)", vcDelayRange.min), -1)
            return
        end

        DUPLICATE_WINDOW = newWindow
        sampAddChatMessage(string.format("{00FFAA}[VC]{FFFFFF} Новое окно дубликатов: %d сек", DUPLICATE_WINDOW), -1)
    end)

    sampRegisterChatCommand('vcdelay', function(param)
        if not param or param == "" then
            sampAddChatMessage(string.format("{00FFAA}[VC]{FFFFFF} Текущий диапазон задержки VC: %.1f - %.1f сек", vcDelayRange.min, vcDelayRange.max), -1)
            return
        end

        local minDelay, maxDelay = param:match("(%d+%.?%d*)%s*(%d+%.?%d*)")
        minDelay = tonumber(minDelay)
        maxDelay = tonumber(maxDelay)

        if not minDelay or not maxDelay or minDelay <= 0 or maxDelay < minDelay then
            sampAddChatMessage("{FF4444}[VC]{FFFFFF} Ошибка: используйте /vcdelay <min> <max>", -1)
            return
        end

        if minDelay < DUPLICATE_WINDOW then
            sampAddChatMessage(string.format("{FF4444}[VC]{FFFFFF} Ошибка: минимальная задержка VC (%.1f сек) не может быть меньше окна дубликатов (%d сек)", minDelay, DUPLICATE_WINDOW), -1)
            return
        end

        vcDelayRange.min = minDelay
        vcDelayRange.max = maxDelay
        sampAddChatMessage(string.format("{00FFAA}[VC]{FFFFFF} Новый диапазон задержки VC: %.1f - %.1f сек", vcDelayRange.min, vcDelayRange.max), -1)
    end)

    sampAddChatMessage("{00FFAA}[VC Auto]{FFFFFF} Автоответ включён. /vcoff", -1)

    while true do wait(0) end
end

-- ================= ЧАТ =================
function sampev.onServerMessage(color, text)
    if not autoVcEnabled then return end

    local normalized = normalizeText(text:lower())

    local nickname =
        text:match("%]%s*%b{}([^%[]+)%[%d+%]") or
        text:match("^([^%[]+)%[%d+%]") or
        text:match("([^%[]+)%[%d+%]")

    if nickname then
        nickname = nickname:gsub("^%s+", ""):gsub("%s+$", "")
    end

    if not nickname or isMyNick(nickname) then return end

    local hasQueue = normalized:find("очередь")
    local hasVC = normalized:find("вс") or normalized:find("vc") or normalized:find("вц") or normalized:find("vice")

    if normalized:find("онлайн") and hasQueue then
        rememberVc(text)
        lastGlobalAnswerTime = os.clock()
        return
    end

    if hasQueue and hasVC and isDuplicateVc(normalized) then
        return
    end

    if hasQueue and hasVC then
        if lastQueueRequestNick == nickname and os.time() - lastQueueRequestTime < QUEUE_REQUEST_WINDOW then
            return
        end

        lastQueueRequestNick = nickname
        lastQueueRequestTime = os.time()

        if not canRespond(nickname) then return end
        if not canSendGlobal() then return end

        logUser(nickname)

        lua_thread.create(function()
            local delay = math.random() * (vcDelayRange.max - vcDelayRange.min) + vcDelayRange.min
            wait(delay * 1000)

            if os.time() - lastQueueRequestTime > QUEUE_REQUEST_WINDOW then return end
            if lastQueueRequestNick ~= nickname then return end

            getVcServer(true, nickname)
        end)
    end
end

-- ================= API =================
function getVcServer(sendToVr, nickname)
    local requests = require('requests')
    if not requests then return end

    local res = requests.get(url)
    if res and res.status_code == 200 then
        local data = res.json()

        if data and data.vc then
            for _, po in pairs(data.vc) do
                local template = messageVariants[math.random(#messageVariants)]

                local msg = template:format(
                    po.name or "Vice City",
                    po.online or 0,
                    po.maxplayers or 0,
                    po.queue or 0
                )

                msg = mutateText(msg)

                if isDuplicateVc(msg) then return end
                rememberVc(msg)

                if nickname and not isMyNick(nickname) then
                    msg = msg .. " @" .. nickname
                end

                if sendToVr then
                    needCloseDialog = true
                    sampSendChat("/vr " .. msg)
                else
                    sampAddChatMessage("{00FFAA}" .. msg, -1)
                end
            end
        end
    end
end

-- ================= ПРОЧЕЕ =================
function loadLogs()
    local f = io.open(logFile, "r")
    if f then
        local content = f:read("*a")
        f:close()
        if content and content ~= "" then
            userLogs = decodeJSON(content)
        end
    end
end

function saveLogs()
    local f = io.open(logFile, "w+")
    if f then
        f:write(encodeJSON(userLogs))
        f:close()
    end
end

function logUser(nickname)
    if not nickname or isMyNick(nickname) then return end

    local time = os.date("%Y-%m-%d %H:%M:%S")

    if not userLogs[nickname] then
        userLogs[nickname] = {count = 0, last_time = time}
    end

    userLogs[nickname].count = userLogs[nickname].count + 1
    userLogs[nickname].last_time = time

    saveLogs()
end

function canRespond(nickname)
    local now = os.time()
    if userCooldowns[nickname] and now - userCooldowns[nickname] < COOLDOWN_TIME then
        return false
    end
    userCooldowns[nickname] = now
    return true
end

function canSendGlobal()
    local now = os.time()

    for i = #globalMessages, 1, -1 do
        if now - globalMessages[i] > 60 then
            table.remove(globalMessages, i)
        end
    end

    if #globalMessages >= MAX_MESSAGES_PER_MINUTE then
        return false
    end

    table.insert(globalMessages, now)
    return true
end

function sampev.onShowDialog(id, style, title, button1, button2, text)
    if id == ANTI_AD_DIALOG_ID and needCloseDialog then
        needCloseDialog = false
        sampSendDialogResponse(id, 0, 1, "")
        return false
    end
end

function disableAutoVc()
    autoVcEnabled = false
    sampAddChatMessage("{FF4444}[VC]{FFFFFF} автоответ выключен", -1)
end

function enableAutoVc()
    autoVcEnabled = true
    sampAddChatMessage("{00FFAA}[VC]{FFFFFF} автоответ включен", -1)
end