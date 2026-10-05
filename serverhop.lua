-- @XanScc Server | Server Hop con menu para Xeno (PC) y Delta (iPhone)
-- Pega TODO este archivo y ejecutalo. El menu se vuelve a cargar solo despues de cada salto.

local SRC = [==[
local env = (getgenv and getgenv()) or _G
local SRC = env.__SH_SRC

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local placeId = game.PlaceId
local currentJobId = game.JobId

-- Evita menus duplicados y detiene loops de ejecuciones anteriores
if env.__SH_GUI then
    pcall(function() env.__SH_GUI:Destroy() end)
end
env.__SH_RUN = (env.__SH_RUN or 0) + 1
local runId = env.__SH_RUN
local function alive()
    return env.__SH_RUN == runId
end

---------------------------------------------------------------------
-- Ajustes (se guardan en un archivo para que sobrevivan al salto)
---------------------------------------------------------------------
local FILE = "ServerHopSettings.json"
local SORTS = { "Random", "Fewest", "Most" }
local SORT_LABEL = { Random = "Aleatorio", Fewest = "Menos", Most = "Más" }

local settings = {
    minPlayers = 1,
    maxPlayers = 0, -- 0 = sin limite
    sort = "Random",
    auto = false,
    eggMode = "", -- "" = apagado, "rare" = huevos raros (top 4), "big" = huevos grandes (40+), "dim" = dimension
    -- Estado de la busqueda de huevos (se guarda para que sobreviva a cada salto)
    knownRare = "starry fox", -- nombres de huevos raros ya vistos ("|" entre nombres); se aprenden de los avisos
    eggTop = "[]",         -- los 3 mejores servidores vistos: [{job, score, size, rare}], de mejor a peor
    eggVisited = "[]",     -- ids de servidores ya revisados (no se repiten), de mas viejo a mas nuevo
    eggSamples = 0,        -- servidores revisados en esta busqueda
    eggReturning = false,  -- true mientras viaja de vuelta al mejor servidor
    lastTeleport = 0,      -- hora del ultimo salto (para no saltar demasiado seguido)
    huntSkip = "",        -- servidor donde empezo la busqueda: no cuenta nunca
}

local function saveSettings()
    if writefile then
        pcall(function()
            writefile(FILE, HttpService:JSONEncode(settings))
        end)
    end
end

local function loadSettings()
    if isfile and readfile then
        local ok, data = pcall(function()
            if isfile(FILE) then
                return HttpService:JSONDecode(readfile(FILE))
            end
        end)
        if ok and type(data) == "table" then
            for k, v in pairs(data) do
                if settings[k] ~= nil and type(v) == type(settings[k]) then
                    settings[k] = v
                end
            end
        end
    end
end
loadSettings()
-- Version anterior: el modo "any" ahora se llama "big"
if settings.eggMode == "any" then
    settings.eggMode = "big"
end

local function huntOn()
    return settings.eggMode ~= ""
end

-- Un servidor con huevo raro siempre le gana a uno sin raro; entre servidores del mismo tipo gana el
-- huevo mas grande. Los huevos miden unos cuantos studs, asi que 1000 nunca se alcanza solo con tamano.
local RARE_BONUS = 1000

-- "Casi lleno": un servidor con menos de este numero de lugares libres NO se usa (ni para saltar, ni para
-- volver): si se llena, Roblox rechaza la entrada y te manda a otro servidor donde ya no esta el huevo.
local HUNT_MIN_FREE = 2

-- Modo "huevos grandes": solo cuentan los huevos de GIANT_MIN studs o mas; entre ellos gana el mas grande.
-- Si no hay ninguno no se conforma con uno mas chico: sigue buscando.
local GIANT_MIN = 40.0

local function resetHunt()
    settings.eggTop, settings.eggSamples, settings.eggReturning = "[]", 0, false
end

-- Si el menu se carga a mano (no despues de un salto), el servidor donde estas NO cuenta para la busqueda:
-- se busca en OTROS. Despues de un salto, el servidor nuevo si se revisa.
local arrivedByHop = env.__SH_TP == true
env.__SH_TP = nil
local skipCurrent = not arrivedByHop
if not arrivedByHop then
    resetHunt()
end

-- Los 3 mejores servidores vistos, de mejor a peor. Si el primero ya no deja entrar (lleno), se prueba el
-- segundo, y asi, en vez de caer en un servidor cualquiera sin huevo.
local function topList()
    local ok, list = pcall(function()
        return HttpService:JSONDecode(settings.eggTop)
    end)
    return (ok and type(list) == "table") and list or {}
end

local function addCandidate(job, score, size, rare, flags)
    local list = topList()
    for i, candidate in ipairs(list) do
        if candidate.job == job then
            table.remove(list, i)
            break
        end
    end
    table.insert(list, { job = job, score = score, size = size, rare = rare,
        giant = flags and flags.giant or false, ann = flags and flags.ann or false, t = os.time() })
    table.sort(list, function(a, b) return a.score > b.score end)
    while #list > 3 do
        table.remove(list)
    end
    settings.eggTop = HttpService:JSONEncode(list)
end

local function findCandidate(job)
    for _, candidate in ipairs(topList()) do
        if candidate.job == job then
            return candidate
        end
    end
    return nil
end

local function removeCandidate(job)
    local list = topList()
    for i, candidate in ipairs(list) do
        if candidate.job == job then
            table.remove(list, i)
            break
        end
    end
    settings.eggTop = HttpService:JSONEncode(list)
end

-- Servidores ya revisados en busquedas anteriores: no se vuelven a visitar. Asi la busqueda avanza por
-- servidores nuevos (hasta donde haga falta) en vez de repetir siempre los de las primeras paginas.
local HUNT_VISITED_MAX = 150
local huntVisited = {} -- conjunto { [jobId] = true }, se carga en cada busqueda

-- Devuelve (conjunto, lista) de servidores visitados
local function loadVisited()
    local ok, list = pcall(function()
        return HttpService:JSONDecode(settings.eggVisited)
    end)
    if not ok or type(list) ~= "table" then
        list = {}
    end
    local set = {}
    for _, id in ipairs(list) do
        set[id] = true
    end
    return set, list
end

local function markVisited(job)
    local set, list = loadVisited()
    if set[job] then return end
    table.insert(list, job)
    while #list > HUNT_VISITED_MAX do
        table.remove(list, 1)
    end
    settings.eggVisited = HttpService:JSONEncode(list)
end

local function clearVisited()
    settings.eggVisited = "[]"
    huntVisited = {}
end

local MAX_PAGES = 100           -- tope de paginas por lista (100 servidores cada una)
local HUNT_MAX_PAGES = 50       -- buscando huevos: paginas por extremo de la lista (2 extremos = 100 en total)
local REQUEST_GAP = 0.3         -- segundos minimos entre peticiones a Roblox (para no ser limitado)
local SEARCH_TIMEOUT = 15       -- segundos maximos buscando servidores (salto normal)
local HUNT_SEARCH_TIMEOUT = 15  -- segundos maximos buscando servidores cuando se buscan huevos
local HUNT_POOL = 30            -- servidores NUEVOS que junta antes de elegir uno al buscar huevos
local MAX_FAILS_IN_A_ROW = 3    -- peticiones seguidas fallidas antes de abandonar esa busqueda
local RANDOM_POOL = 30          -- en modo aleatorio junta hasta tantos servidores validos antes de elegir
local EMPTY_POOL = 15           -- servidores casi vacios que junta el boton "Server privado"
local EMPTY_MAX_PLAYERS = 1     -- "Server privado" busca servidores con 0 o 1 jugador
local MAX_TELEPORT_TRIES = 6    -- cuantos servidores distintos prueba si uno esta lleno o cerrado
local MIN_HOP_GAP = 6           -- segundos minimos entre un salto y el siguiente (si no, Roblox da "Flooded")
local FLOOD_COOLDOWN = 10       -- espera cuando Roblox dice que se salta muy rapido
local AUTO_START_DELAY = 2      -- segundos tras entrar a un servidor antes de volver a saltar (modo auto)
local AUTO_RETRY_DELAY = 1      -- espera tras iniciar un salto
local FAIL_RETRY_DELAY = 6      -- espera tras un intento fallido (Roblox limita / sin red)
local EGG_SCAN_SECONDS = 2.5    -- segundos que escanea los huevos de cada servidor (cargan poco a poco)
local EGG_SAMPLE_SERVERS = 5    -- servidores que revisa antes de volver al que tenia el mejor huevo
local RARE_LIFETIME = 270       -- segundos que se da por buena una rareza avisada por el juego

-- Se reemplaza mas abajo, cuando existe el menu, para avisar "Reintentando..."
local notifyRetry = function() end

---------------------------------------------------------------------
-- Busqueda de servidores
---------------------------------------------------------------------
-- game:HttpGet en Xeno/Delta; si no existe, usa la funcion request del ejecutor.
-- Devuelve el texto, o (nil, codigo, espera) si fallo (429 = Roblox limito las peticiones).
local function httpGet(url)
    local ok, body = pcall(function()
        return game:HttpGet(url)
    end)
    if ok and body then
        return body
    end
    local message = tostring(body)
    if message:find("429", 1, true) or message:lower():find("too many", 1, true) then
        return nil, 429
    end

    local req = request or http_request or (syn and syn.request) or (http and http.request)
    if req then
        local ok2, res = pcall(req, { Url = url, Method = "GET" })
        if ok2 and res then
            if res.StatusCode == 200 and res.Body then
                return res.Body
            end
            local headers = res.Headers or {}
            return nil, tonumber(res.StatusCode) or 0, tonumber(headers["retry-after"] or headers["Retry-After"])
        end
    end
    return nil, 0
end

-- Pide UNA pagina de servidores (un solo intento), sin pasar de una peticion cada REQUEST_GAP segundos.
-- Devuelve la pagina, o (nil, codigo, espera) si fallo.
local lastRequest = 0
local function fetchPage(sortOrder, cursor)
    local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=%s&limit=100&excludeFullGames=true"):format(placeId, sortOrder)
    if cursor then
        url = url .. "&cursor=" .. cursor
    end

    local at = math.max(os.clock(), lastRequest + REQUEST_GAP)
    lastRequest = at
    if at > os.clock() then
        task.wait(at - os.clock())
    end

    local ok, body, code, retry = pcall(httpGet, url)
    if not ok or not body then
        return nil, (ok and code) or 0, retry
    end
    local ok2, decoded = pcall(function()
        return HttpService:JSONDecode(body)
    end)
    if ok2 and type(decoded) == "table" and type(decoded.data) == "table" then
        return decoded
    end
    return nil, 0
end

-- Recorre paginas juntando servidores que cumplan `accept`; se detiene en cuanto junta suficientes, llega al
-- final de la lista, o se acaba el tiempo / las paginas.
--   orders:   lista de ordenes a recorrer AL MISMO TIEMPO (ej. {"Asc","Desc"} = empieza por los dos extremos)
--   target:   deja de buscar al juntar tantos servidores validos
--   firstHit: si es true, se detiene en la primera pagina que tenga resultados
--             (la lista viene ordenada, asi que lo mejor esta al principio)
-- Si Roblox limita una pagina, espera lo que pide y reintenta unas pocas veces; si sigue limitando, se rinde.
-- Devuelve (lista, huboError): huboError solo si no se junto ningun servidor.
local function collectServers(accept, orders, target, firstHit, onProgress, timeout, maxPages)
    local found, seen = {}, {}
    local deadline = os.clock() + (timeout or SEARCH_TIMEOUT)
    local limit = maxPages or MAX_PAGES
    local finished, pagesDone = 0, 0
    local stop, hadError = false, false

    local function chain(sortOrder)
        local cursor
        local pages, fails = 0, 0
        while pages < limit and not stop and os.clock() < deadline do
            local page, code, retryAfter = fetchPage(sortOrder, cursor)
            if stop then break end

            if page then
                fails = 0
                pages = pages + 1
                pagesDone = pagesDone + 1
                if onProgress then onProgress(pagesDone) end

                for _, server in ipairs(page.data) do
                    if not seen[server.id] and accept(server) then
                        seen[server.id] = true
                        table.insert(found, server)
                    end
                end

                if #found >= target or (firstHit and #found > 0) then
                    stop = true
                    break
                end

                cursor = page.nextPageCursor
                if not cursor then break end -- ya no hay mas paginas
            else
                fails = fails + 1
                hadError = true
                if fails >= MAX_FAILS_IN_A_ROW then break end
                notifyRetry(fails)
                task.wait(code == 429 and math.min(retryAfter or (2 * fails), 6) or math.min(0.4 * fails, 2))
            end
        end
        finished = finished + 1
    end

    for _, order in ipairs(orders) do
        task.spawn(chain, order)
    end
    while finished < #orders and not stop and os.clock() < deadline do
        task.wait(0.05)
    end
    stop = true

    return found, hadError and #found == 0
end

local function baseAccept(server)
    return server.id ~= currentJobId
        and server.playing ~= nil
        and server.maxPlayers ~= nil
        and server.playing < server.maxPlayers
        -- casi lleno: no se usa nunca (se llenaria antes de entrar y Roblox te mandaria a otro servidor)
        and server.maxPlayers - server.playing >= HUNT_MIN_FREE
end

local function normalAccept(server)
    if not baseAccept(server) then return false end
    -- Buscando huevos: no repite servidores que ya reviso
    if huntOn() and (huntVisited[server.id] or server.id == settings.huntSkip) then return false end
    if server.playing < settings.minPlayers then return false end
    if settings.maxPlayers > 0 and server.playing > settings.maxPlayers then return false end
    return true
end

local function emptyAccept(server)
    return baseAccept(server) and server.playing <= EMPTY_MAX_PLAYERS
end

local function shuffle(list)
    for i = #list, 2, -1 do
        local j = math.random(1, i)
        list[i], list[j] = list[j], list[i]
    end
end

---------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "XanSccServer"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true -- tambien cubre el notch del iPhone
env.__SH_GUI = gui

local function make(class, props, parent)
    local obj = Instance.new(class)
    for k, v in pairs(props) do
        obj[k] = v
    end
    obj.Parent = parent
    return obj
end

local C = {
    bg = Color3.fromRGB(15, 15, 24),
    field = Color3.fromRGB(30, 30, 46),
    border = Color3.fromRGB(52, 52, 76),
    accentA = Color3.fromRGB(139, 92, 246),
    accentB = Color3.fromRGB(56, 189, 248),
    text = Color3.fromRGB(240, 240, 248),
    dim = Color3.fromRGB(150, 150, 172),
    white = Color3.fromRGB(255, 255, 255),
    ok = Color3.fromRGB(52, 211, 153),
    warn = Color3.fromRGB(251, 191, 36),
    info = Color3.fromRGB(96, 165, 250),
    err = Color3.fromRGB(248, 113, 113),
    switchOff = Color3.fromRGB(60, 60, 84),
}

local function gradient(parent, rotation, colorA, colorB)
    return make("UIGradient", {
        Color = ColorSequence.new(colorA or C.accentA, colorB or C.accentB),
        Rotation = rotation or 0,
    }, parent)
end

local function corner(parent, radius)
    return make("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, parent)
end

local function stroke(parent, color, thickness, transparency)
    return make("UIStroke", {
        Color = color or C.border,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, parent)
end

-- Texto arcoiris animado: cada UIGradient registrado aqui recibe los colores en cada frame
local rainbowGradients = {}
local function rainbow(parent)
    local g = make("UIGradient", {}, parent)
    table.insert(rainbowGradients, g)
    return g
end

local W, H = 290, 432

local main = make("Frame", {
    Size = UDim2.fromOffset(W, H),
    Position = UDim2.new(0, 20, 0.5, -H / 2),
    BackgroundColor3 = C.bg,
    BorderSizePixel = 0,
    Active = true,
}, gui)
corner(main, 12)
stroke(main, C.accentA, 1.5, 0.45)

-- Escala automatica: en pantallas chicas (iPhone) el menu se reduce para caber
local uiScale = make("UIScale", {}, main)
local function updateScale()
    local cam = workspace.CurrentCamera
    if not cam then return end
    local vp = cam.ViewportSize
    uiScale.Scale = math.clamp(math.min(vp.Y * 0.9 / H, vp.X * 0.9 / W), 0.6, 1)
end
updateScale()
if workspace.CurrentCamera then
    workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
end

-- Barra de titulo
local bar = make("Frame", {
    Size = UDim2.new(1, -12, 0, 30),
    Position = UDim2.fromOffset(6, 6),
    BackgroundColor3 = C.field,
    BorderSizePixel = 0,
}, main)
corner(bar, 8)
stroke(bar, C.border, 1, 0)

local title = make("TextLabel", {
    Size = UDim2.new(1, -76, 1, 0),
    Position = UDim2.fromOffset(12, 0),
    BackgroundTransparency = 1,
    Text = "@XanScc Server",
    TextColor3 = C.white,
    Font = Enum.Font.GothamBold,
    TextSize = 16,
    TextXAlignment = Enum.TextXAlignment.Left,
}, bar)
rainbow(title)

local function barButton(text, xFromRight)
    local b = make("TextButton", {
        Size = UDim2.fromOffset(26, 22),
        Position = UDim2.new(1, xFromRight, 0, 4),
        BackgroundColor3 = C.border,
        BackgroundTransparency = 0,
        Text = text,
        TextColor3 = C.white,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        BorderSizePixel = 0,
    }, bar)
    corner(b, 6)
    return b
end
local minBtn = barButton("-", -60)
local closeBtn = barButton("X", -30)

local body = make("Frame", {
    Size = UDim2.new(1, -20, 1, -52),
    Position = UDim2.fromOffset(10, 44),
    BackgroundTransparency = 1,
}, main)
make("UIListLayout", {
    Padding = UDim.new(0, 8),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, body)

local order = 0
local function section(height)
    order = order + 1
    return make("Frame", {
        Size = UDim2.new(1, 0, 0, height),
        BackgroundTransparency = 1,
        LayoutOrder = order,
    }, body)
end

local function caption(text, parent, position, size)
    return make("TextLabel", {
        Size = size,
        Position = position,
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = C.dim,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, parent)
end

local function numberField(parent, position, size, value)
    local box = make("TextBox", {
        Size = size,
        Position = position,
        BackgroundColor3 = C.field,
        Text = tostring(value),
        TextColor3 = C.text,
        PlaceholderColor3 = C.dim,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        ClearTextOnFocus = false,
        BorderSizePixel = 0,
    }, parent)
    corner(box, 8)
    local s = stroke(box, C.border, 1, 0)
    box.Focused:Connect(function() s.Color = C.accentA end)
    box.FocusLost:Connect(function() s.Color = C.border end)
    return box
end

-- Jugadores minimo / maximo
local players = section(48)
caption("Mínimo", players, UDim2.fromOffset(2, 0), UDim2.new(0.5, -6, 0, 14))
caption("Máx (0 = sin límite)", players, UDim2.new(0.5, 6, 0, 0), UDim2.new(0.5, -6, 0, 14))
local minBox = numberField(players, UDim2.fromOffset(0, 18), UDim2.new(0.5, -6, 0, 30), settings.minPlayers)
local maxBox = numberField(players, UDim2.new(0.5, 6, 0, 18), UDim2.new(0.5, -6, 0, 30), settings.maxPlayers)

-- Prioridad (selector de 3 opciones)
local sortSection = section(48)
caption("Prioridad de servidor", sortSection, UDim2.fromOffset(2, 0), UDim2.new(1, 0, 0, 14))
local segment = make("Frame", {
    Size = UDim2.new(1, 0, 0, 30),
    Position = UDim2.fromOffset(0, 18),
    BackgroundColor3 = C.field,
    BorderSizePixel = 0,
}, sortSection)
corner(segment, 8)
stroke(segment, C.border, 1, 0)
make("UIPadding", {
    PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, 3),
    PaddingTop = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3),
}, segment)
make("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 3),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, segment)

-- El degradado va en un fondo aparte: un UIGradient tambien tine el texto de su padre
local sortButtons = {}
local function refreshSort()
    for key, item in pairs(sortButtons) do
        local active = settings.sort == key
        item.bg.BackgroundTransparency = active and 0 or 1
        item.label.TextColor3 = active and C.white or C.dim
    end
end

for i, key in ipairs(SORTS) do
    local holder = make("Frame", {
        Size = UDim2.new(1 / 3, -2, 1, 0),
        BackgroundColor3 = C.white,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        LayoutOrder = i,
    }, segment)
    corner(holder, 6)
    gradient(holder, 0)

    local btn = make("TextButton", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = SORT_LABEL[key],
        TextColor3 = C.dim,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        BorderSizePixel = 0,
        AutoButtonColor = false,
    }, holder)
    sortButtons[key] = { bg = holder, label = btn }
    btn.Activated:Connect(function()
        settings.sort = key
        refreshSort()
        saveSettings()
    end)
end
refreshSort()

-- Interruptor de modo automatico
local autoRow = section(30)
make("TextLabel", {
    Size = UDim2.new(1, -60, 1, 0),
    BackgroundTransparency = 1,
    Text = "Modo automático",
    TextColor3 = C.text,
    Font = Enum.Font.GothamMedium,
    TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left,
}, autoRow)

-- Interruptor reutilizable. Devuelve (boton, funcion para refrescar su aspecto).
local function makeSwitch(row, getValue)
    local track = make("TextButton", {
        Size = UDim2.fromOffset(48, 26),
        Position = UDim2.new(1, -48, 0, 2),
        BackgroundColor3 = C.switchOff,
        Text = "",
        BorderSizePixel = 0,
        AutoButtonColor = false,
    }, row)
    corner(track, 13)
    local knob = make("Frame", {
        Size = UDim2.fromOffset(20, 20),
        Position = UDim2.fromOffset(3, 3),
        BackgroundColor3 = C.white,
        BorderSizePixel = 0,
    }, track)
    corner(knob, 10)

    local function refresh(animate)
        local on = getValue()
        local trackColor = on and C.ok or C.switchOff
        local knobPos = on and UDim2.fromOffset(25, 3) or UDim2.fromOffset(3, 3)
        if animate then
            local info = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
            TweenService:Create(track, info, { BackgroundColor3 = trackColor }):Play()
            TweenService:Create(knob, info, { Position = knobPos }):Play()
        else
            track.BackgroundColor3 = trackColor
            knob.Position = knobPos
        end
    end
    refresh(false)
    return track, refresh
end

local track, refreshSwitch = makeSwitch(autoRow, function() return settings.auto end)

-- Busqueda de huevos: tres modos independientes (solo uno encendido a la vez)
local function modeRow(label, width)
    local row = section(30)
    make("TextLabel", {
        Size = UDim2.new(1, width, 1, 0),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = C.text,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)
    return row
end

local rareRow = modeRow("Huevos raros (top 4)", -60)
local rareTrack, refreshRare = makeSwitch(rareRow, function() return settings.eggMode == "rare" end)

local bigRow = modeRow("Huevos grandes (40+)", -134)
local bigTrack, refreshBig = makeSwitch(bigRow, function() return settings.eggMode == "big" end)

local dimRow = modeRow("Dimensión (Dr. Scramble)", -60)
local dimTrack, refreshDim = makeSwitch(dimRow, function() return settings.eggMode == "dim" end)

-- Boton para ver como se llaman (y que tan grandes son) los huevos del servidor actual
local inspectBtn = make("TextButton", {
    Size = UDim2.fromOffset(70, 26),
    Position = UDim2.new(1, -124, 0, 2),
    BackgroundColor3 = C.field,
    Text = "Ver huevos",
    TextColor3 = C.accentB,
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    BorderSizePixel = 0,
}, bigRow)
corner(inspectBtn, 8)
stroke(inspectBtn, C.border, 1, 0)

-- Botones principales
local hopSection = section(38)

-- Dos botones lado a lado. El degradado va en un fondo aparte para no teñir el texto.
local function bigButton(text, position, colorA, colorB)
    local bg = make("Frame", {
        Size = UDim2.new(0.5, -4, 1, 0),
        Position = position,
        BackgroundColor3 = C.white,
        BorderSizePixel = 0,
    }, hopSection)
    corner(bg, 10)
    gradient(bg, 0, colorA, colorB)
    return make("TextButton", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = C.white,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        BorderSizePixel = 0,
    }, bg)
end
local hopBtn = bigButton("Saltar ahora", UDim2.fromOffset(0, 0))
local emptyBtn = bigButton("Server privado", UDim2.new(0.5, 4, 0, 0),
    Color3.fromRGB(16, 185, 129), Color3.fromRGB(56, 189, 248))

-- Estado
local statusSection = section(44)
local statusBox = make("Frame", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundColor3 = C.field,
    BorderSizePixel = 0,
}, statusSection)
corner(statusBox, 8)
stroke(statusBox, C.border, 1, 0)

local statusDot = make("Frame", {
    Size = UDim2.fromOffset(8, 8),
    Position = UDim2.new(0, 10, 0.5, -4),
    BackgroundColor3 = C.ok,
    BorderSizePixel = 0,
}, statusBox)
corner(statusDot, 4)

local statusLabel = make("TextLabel", {
    Size = UDim2.new(1, -30, 1, 0),
    Position = UDim2.fromOffset(26, 0),
    BackgroundTransparency = 1,
    Text = "Listo",
    TextColor3 = C.text,
    Font = Enum.Font.GothamMedium,
    TextSize = 12,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
}, statusBox)

local STATUS_COLORS = { ok = C.ok, busy = C.warn, info = C.info, error = C.err }
local statusSuffix = "" -- texto que se agrega a todo estado (ej. " | huevo 12.3" durante la busqueda de huevos)
local function setStatus(text, kind)
    local color = STATUS_COLORS[kind or "info"] or C.info
    statusLabel.Text = text .. statusSuffix
    statusDot.BackgroundColor3 = color
    statusLabel.TextColor3 = color
end
setStatus("Listo", "ok")

notifyRetry = function()
    setStatus("Roblox va lento, sigo buscando...", "busy")
end

-- Credito abajo, tambien en arcoiris
local footer = make("TextLabel", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1,
    Text = "by @XanScc | v14.1",
    TextColor3 = C.white,
    Font = Enum.Font.GothamBold,
    TextSize = 12,
}, section(16))
rainbow(footer)

-- Anima el arcoiris (se detiene solo cuando el menu se cierra o se recarga)
do
    local STEPS = 8
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not alive() then
            conn:Disconnect()
            return
        end
        local t = os.clock() * 0.25
        local keys = {}
        for i = 0, STEPS - 1 do
            local pos = i / (STEPS - 1)
            keys[#keys + 1] = ColorSequenceKeypoint.new(pos, Color3.fromHSV((t + pos * 0.75) % 1, 0.85, 1))
        end
        local seq = ColorSequence.new(keys)
        for _, g in ipairs(rainbowGradients) do
            g.Color = seq
        end
    end)
end

-- Parent del menu (gethui / CoreGui / PlayerGui)
do
    local target
    if gethui then
        local ok, h = pcall(gethui)
        if ok then target = h end
    end
    if not target then
        local ok, cg = pcall(function() return game:GetService("CoreGui") end)
        if ok then target = cg end
    end
    local ok = target and pcall(function() gui.Parent = target end)
    if not ok or not gui.Parent then
        gui.Parent = player:WaitForChild("PlayerGui")
    end
end

---------------------------------------------------------------------
-- Arrastrar el menu
---------------------------------------------------------------------
do
    -- Se sigue solo el dedo que empezo el arrastre (no se mezcla con el joystick)
    local dragInput, dragStart, startPos
    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End and dragInput == input then
                    dragInput = nil
                end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if not dragInput then return end
        local isMove = input.UserInputType == Enum.UserInputType.MouseMovement and dragInput.UserInputType == Enum.UserInputType.MouseButton1
        if input == dragInput or isMove then
            local d = (input.Position - dragStart) / uiScale.Scale
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

---------------------------------------------------------------------
-- Saltar de servidor
---------------------------------------------------------------------
local busy = false
local queued = false
local pool = {}          -- servidores candidatos del salto actual, en orden de preferencia
local poolIndex = 1      -- siguiente candidato a probar
local triesUsed = 0      -- cuantos candidatos se han intentado en este salto
local busyToken = 0

-- Hace que el menu se cargue de nuevo en el servidor nuevo (y le avisa que llego por un salto)
local function queueReload()
    if not queued and queue_on_teleport and SRC then
        queued = true
        pcall(queue_on_teleport, string.format(
            "local e=(getgenv and getgenv()) or _G; e.__SH_TP=true; e.__SH_SRC=%q; loadstring(e.__SH_SRC)()", SRC))
    end
end

-- Si Roblox no responde en 20s, libera el boton para volver a intentar
local function armBusyRelease()
    busyToken = busyToken + 1
    local token = busyToken
    task.delay(20, function()
        if busyToken == token then
            busy = false
        end
    end)
end

-- Anota la hora del salto y espera lo que falte para no saltar demasiado seguido
-- (si no, Roblox rechaza con "Flooded"). Si la hora del sistema es rara, no espera.
local function waitTeleportCooldown()
    local since = os.time() - settings.lastTeleport
    if since < 0 or since >= MIN_HOP_GAP then return end
    local deadline = os.clock() + (MIN_HOP_GAP - since)
    while alive() and os.clock() < deadline do
        task.wait(0.25)
    end
end

local function markTeleport()
    settings.lastTeleport = os.time()
    saveSettings()
end

-- Intenta entrar al siguiente candidato de la lista. Devuelve true si el teleport arranco.
local function teleportNext()
    while poolIndex <= #pool and triesUsed < MAX_TELEPORT_TRIES do
        local target = pool[poolIndex]
        poolIndex = poolIndex + 1
        triesUsed = triesUsed + 1

        queueReload()

        if target.label then
            setStatus(target.label, "info")
        elseif statusSuffix ~= "" then
            setStatus("Teletransportando...", "info")
        else
            setStatus(("Teletransportando... (%d/%d jugadores)"):format(target.playing, target.maxPlayers), "info")
        end
        markTeleport()
        local ok = pcall(function()
            TeleportService:TeleportToPlaceInstance(placeId, target.id, player)
        end)
        if ok then
            armBusyRelease()
            return true
        end
    end
    return false
end

-- Plan B: si Roblox no da la lista de servidores (limite o sin red), Roblox elige uno por nosotros.
-- Asi el salto siempre cambia de servidor, sin quedarse pegado reintentando.
local function plainTeleport()
    setStatus("Teletransportando...", "info")
    queueReload()
    markTeleport()
    local ok = pcall(function()
        TeleportService:Teleport(placeId, player)
    end)
    if ok then
        armBusyRelease()
    end
    return ok
end

-- Si el servidor elegido se lleno o cerro, prueba automaticamente con el siguiente
TeleportService.TeleportInitFailed:Connect(function(_, result, message)
    if not alive() or not busy then return end
    if result == Enum.TeleportResult.Flooded then
        -- Roblox pide ir mas despacio: no es un servidor malo, es que se salto muy rapido
        setStatus("Roblox pide ir más despacio, espero...", "busy")
        task.wait(FLOOD_COOLDOWN)
        if not alive() or not busy then return end
    else
        setStatus("Servidor no disponible, probando otro...", "busy")
    end
    if not teleportNext() then
        setStatus("Ningún servidor aceptó, reintenta", "error")
        busy = false
    end
end)

-- mode: nil = salto normal (con filtros del menu), "empty" = servidor casi vacio
local function hop(mode)
    if busy then return false end
    busy = true

    waitTeleportCooldown()
    if not alive() then
        busy = false
        return false
    end

    local hunting = huntOn() and mode ~= "empty"
    local ok, list, failed
    if mode == "empty" then
        setStatus("Buscando server vacío...", "busy")
        ok, list, failed = pcall(collectServers, emptyAccept, { "Asc" }, EMPTY_POOL, true, nil, nil, MAX_PAGES)
    else
        -- Buscando huevos siempre recorre los dos extremos de la lista a la vez y elige al azar entre
        -- servidores nuevos, sin importar el orden elegido.
        local isRandom = hunting or settings.sort == "Random"
        local orders = isRandom and { "Asc", "Desc" } or { (settings.sort == "Most") and "Desc" or "Asc" }
        local target = hunting and HUNT_POOL or (isRandom and RANDOM_POOL or 15)
        local timeout = hunting and HUNT_SEARCH_TIMEOUT or nil
        local maxPages = hunting and HUNT_MAX_PAGES or MAX_PAGES

        local function search()
            if not hunting then
                setStatus("Buscando servidores...", "busy")
            else
                huntVisited = loadVisited()
            end
            return pcall(collectServers, normalAccept, orders, target, not isRandom, nil, timeout, maxPages)
        end

        ok, list, failed = search()

        -- Si ya reviso todos los servidores que hay, olvida la lista y busca una vez mas
        if hunting and ok and #list == 0 and not failed and next(huntVisited) ~= nil then
            clearVisited()
            saveSettings()
            ok, list, failed = search()
        end
    end

    if not ok then
        setStatus("Error al buscar servidores", "error")
        busy = false
        return false
    end
    if #list == 0 then
        if failed then
            -- Roblox no dio la lista (limite o sin red): no es del script, pero no se queda parado
            if mode ~= "empty" and (hunting or (settings.minPlayers <= 1 and settings.maxPlayers == 0)) then
                if plainTeleport() then
                    return true
                end
            end
            setStatus("Error de red o límite de Roblox, reintenta", "error")
        elseif hunting then
            -- ni modo: no hay servidores con espacio; no se queda buscando para siempre
            settings.eggMode = ""
            resetHunt()
            statusSuffix = ""
            refreshRare(true)
            refreshBig(true)
            refreshDim(true)
            saveSettings()
            setStatus("No encontré servidores con espacio; búsqueda detenida", "error")
        elseif mode == "empty" then
            setStatus("No hay servers con 0-1 jugadores ahora", "error")
        else
            setStatus("No hay servidores con ese filtro", "error")
        end
        busy = false
        return false
    end

    -- Orden de preferencia de los candidatos
    if mode == "empty" then
        shuffle(list)
        table.sort(list, function(a, b) return a.playing < b.playing end) -- los mas vacios primero
    elseif settings.sort == "Random" or hunting then
        shuffle(list)
    end

    pool = list
    poolIndex = 1
    triesUsed = 0
    if not teleportNext() then
        setStatus("Teleport falló, reintenta", "error")
        busy = false
        return false
    end
    return true
end

-- Viaja a uno de varios servidores: prueba el primero y, si no deja entrar, el siguiente
local function goToServer(candidates, label)
    if busy then return false end
    busy = true
    pool = {}
    for _, candidate in ipairs(candidates) do
        if candidate.job ~= game.JobId then
            table.insert(pool, { id = candidate.job, label = label })
        end
    end
    poolIndex = 1
    triesUsed = 0
    if not teleportNext() then
        setStatus("No pude entrar a esos servidores", "error")
        busy = false
        return false
    end
    return true
end

---------------------------------------------------------------------
-- Eventos del menu
---------------------------------------------------------------------
local function numberBox(box, key)
    box.FocusLost:Connect(function()
        local n = tonumber(box.Text)
        if n then
            settings[key] = math.clamp(math.floor(n), 0, 100)
            -- Mantiene minimo <= maximo (cuando hay maximo)
            if settings.maxPlayers > 0 and settings.minPlayers > settings.maxPlayers then
                if key == "minPlayers" then
                    settings.maxPlayers = settings.minPlayers
                else
                    settings.minPlayers = settings.maxPlayers
                end
            end
            saveSettings()
        end
        minBox.Text = tostring(settings.minPlayers)
        maxBox.Text = tostring(settings.maxPlayers)
    end)
end
numberBox(minBox, "minPlayers")
numberBox(maxBox, "maxPlayers")

track.Activated:Connect(function()
    settings.auto = not settings.auto
    refreshSwitch(true)
    saveSettings()
    if settings.auto then
        setStatus("Modo automático activado", "ok")
    else
        setStatus("Modo automático apagado", "info")
    end
end)

-- Enciende un modo de busqueda de huevos (y apaga los otros). Pulsar el activo lo apaga.
local function setEggMode(mode)
    settings.eggMode = (settings.eggMode == mode) and "" or mode
    -- Cada vez que cambia el modo empieza una busqueda nueva, y el servidor donde estas no cuenta
    resetHunt()
    skipCurrent = true
    statusSuffix = ""
    refreshRare(true)
    refreshBig(true)
    refreshDim(true)
    saveSettings()
    if settings.eggMode == "rare" then
        setStatus("Busco solo huevos raros (Divine, Eternal, Secret, Cosmic) en otros servidores", "ok")
    elseif settings.eggMode == "big" then
        setStatus("Busco solo huevos de 40.0 o más en otros servidores", "ok")
    elseif settings.eggMode == "dim" then
        setStatus("Busco otro servidor con la dimensión (Dr. Scramble) abierta", "ok")
    else
        setStatus("Búsqueda de huevos apagada", "info")
    end
end

rareTrack.Activated:Connect(function()
    setEggMode("rare")
end)
bigTrack.Activated:Connect(function()
    setEggMode("big")
end)
dimTrack.Activated:Connect(function()
    setEggMode("dim")
end)

hopBtn.Activated:Connect(function()
    hop()
end)
emptyBtn.Activated:Connect(function()
    hop("empty")
end)

local minimized = false
minBtn.Activated:Connect(function()
    minimized = not minimized
    body.Visible = not minimized
    main.Size = minimized and UDim2.fromOffset(W, 42) or UDim2.fromOffset(W, H)
end)

closeBtn.Activated:Connect(function()
    env.__SH_RUN = (env.__SH_RUN or 0) + 1
    gui:Destroy()
    env.__SH_GUI = nil
end)

---------------------------------------------------------------------
-- Busqueda de huevos: revisa el servidor actual y, si no hay, salta al siguiente
---------------------------------------------------------------------
-- En Steal an Egg los huevos del mapa son hijos de Workspace.AreaEggSlotsClient y el nombre no dice
-- ni la rareza ni el tamano: lo que cambia es el tamano del modelo. Un huevo gigante es uno cuya
-- dimension mas grande pasa del minimo configurado en el menu.
local function largestDimension(inst)
    local ok, size = pcall(function()
        return inst:IsA("Model") and inst:GetExtentsSize() or inst.Size
    end)
    if ok and size then
        return math.max(size.X, size.Y, size.Z)
    end
    return 0
end

local function cleanText(text)
    return (text:gsub("<[^>]*>", "")) -- quita etiquetas de texto enriquecido
end

-- Los huevos de la zona nueva (Enchanted Forest) traen el nombre de su tipo en el atributo
-- PreparedSourceName ("Workspace.NewEggs.Starry Fox").
-- Nombre del tipo de huevo ("Starry Fox") si el modelo lo trae; si no, nil.
local function eggTypeName(inst)
    local source = inst:GetAttribute("PreparedSourceName")
    if type(source) == "string" then
        return source:match("NewEggs%.(.+)$")
    end
    return nil
end

-- Mide el huevo mas grande de Workspace.AreaEggSlotsClient (a mas kg, mas grande el huevo).
-- Devuelve (tamano del huevo mas grande, cuantos huevos reviso, el huevo mas grande).
local function scanForEggs()
    local slots = workspace:FindFirstChild("AreaEggSlotsClient")
    if not slots then
        return 0, 0, nil
    end

    local biggest, checked, biggestInst = 0, 0, nil
    for _, child in ipairs(slots:GetChildren()) do
        if child:IsA("Model") or child:IsA("BasePart") then
            checked = checked + 1
            local size = largestDimension(child)
            if size > biggest then
                biggest = size
                biggestInst = child
            end
        end
    end
    return biggest, checked, biggestInst
end

-- Las 4 mejores rarezas del juego (de mayor a menor: Divine, Eternal, Secret, Cosmic).
-- Son las unicas que cuentan como "huevo raro".
local RARE_WORDS = { "divine", "eternal", "secret", "cosmic" }

local function rareWordIn(text)
    local lower = tostring(text):lower()
    for _, word in ipairs(RARE_WORDS) do
        if lower:find(word, 1, true) then
            return word
        end
    end
    return nil
end

-- Busca una rareza en el nombre, atributos, valores y textos de un objeto y de todo lo que tiene dentro.
-- Devuelve (rareza, donde la encontro) o nil.
local function treeRarity(root)
    local function check(obj)
        local word = rareWordIn(obj.Name)
        if word then return word, "nombre" end

        for key, value in pairs(obj:GetAttributes()) do
            if type(value) == "string" then
                word = rareWordIn(value)
                if word then return word, key end
            end
        end

        if obj:IsA("TextLabel") or obj:IsA("TextButton") then
            word = rareWordIn(obj.Text)
            if word then return word, "texto" end
        elseif obj:IsA("StringValue") then
            word = rareWordIn(obj.Value)
            if word then return word, obj.Name end
        end
        return nil
    end

    local word, where = check(root)
    if word then return word, where end
    for _, d in ipairs(root:GetDescendants()) do
        word, where = check(d)
        if word then return word, where end
    end
    return nil
end

-- Nombres de huevos raros ya vistos en avisos del juego (guardados entre saltos)
local function isKnownRare(typeName)
    local lower = typeName:lower()
    for name in tostring(settings.knownRare):gmatch("[^|]+") do
        if name == lower then
            return true
        end
    end
    return false
end

local function learnRare(typeName)
    if typeName == "" or isKnownRare(typeName) then return end
    settings.knownRare = settings.knownRare .. "|" .. typeName:lower()
    saveSettings()
end

-- Revisa cada huevo del mapa buscando una rareza Secret / Eternal / Divine en sus datos, y tambien en la
-- plantilla de la que viene (Workspace.NewEggs.<Nombre>, segun su atributo PreparedSourceName).
-- Devuelve (rareza, huevo) del primer huevo raro que encuentre, o nil.
local function findRareEgg()
    local slots = workspace:FindFirstChild("AreaEggSlotsClient")
    if not slots then
        return nil
    end

    for _, child in ipairs(slots:GetChildren()) do
        if child:IsA("Model") or child:IsA("BasePart") then
            -- 1) el tipo del huevo coincide con un huevo raro ya conocido (ej. "Starry Fox")
            local typeName = eggTypeName(child)
            if typeName and isKnownRare(typeName) then
                return "raro", child
            end

            -- 2) la rareza esta escrita en los datos del huevo o de su plantilla
            local word, where = treeRarity(child)

            if not word then
                local source = child:GetAttribute("PreparedSourceName")
                local templateName = type(source) == "string" and source:match("NewEggs%.(.+)$")
                local newEggs = workspace:FindFirstChild("NewEggs")
                local template = templateName and newEggs and newEggs:FindFirstChild(templateName)
                if template then
                    word, where = treeRarity(template)
                end
            end

            if word then
                return word, child
            end
        end
    end
    return nil
end

-- Una sola pasada por el mapa. Devuelve (huevo mas grande fuera de la biblioteca de modelos,
-- nombre del objeto de la dimension abierta o nil, huevo enorme). wantGiant / wantDim = false apaga esa parte.
-- La dimension (el portal del jefe Dr. Scramble, o el Rift) se reconoce por el nombre del portal; se descartan maquinas, tiendas y carteles
-- que existen siempre en el lobby (la "Rift Machine", la tienda de jefes...).
local DIM_WORDS = { "scramble", "rift", "dimension", "portal" }
local DIM_SKIP = { "machine", "shop", "button", "index", "token", "banner", "sign", "egg", "teleportpad", "spawn" }

local function scanMap(wantGiant, wantDim)
    wantGiant = wantGiant ~= false
    wantDim = wantDim ~= false
    local giant, giantInst, dimension = 0, nil, nil
    local character = player.Character
    local assets = workspace:FindFirstChild("ClientRenderedAssets")

    local count = 0
    for _, inst in ipairs(workspace:GetDescendants()) do
        count = count + 1
        if count % 4000 == 0 then
            task.wait() -- no congela el juego en mapas enormes
        end

        if inst:IsA("Model") or inst:IsA("BasePart") then
            local name = inst.Name:lower()

            if wantGiant and name:find("egg", 1, true) and not (assets and inst:IsDescendantOf(assets)) then
                local size = largestDimension(inst)
                if size > giant then
                    giant, giantInst = size, inst
                end
            end

            if wantDim and not dimension and not (character and inst:IsDescendantOf(character)) then
                for _, word in ipairs(DIM_WORDS) do
                    if name:find(word, 1, true) then
                        local skip = false
                        for _, bad in ipairs(DIM_SKIP) do
                            if name:find(bad, 1, true) then
                                skip = true
                                break
                            end
                        end
                        if not skip then
                            dimension = inst.Name:sub(1, 30)
                            if not wantGiant then
                                return giant, dimension, giantInst
                            end
                        end
                        break
                    end
                end
            end
        end
    end
    return giant, dimension, giantInst
end

local function notify(text)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "@XanScc Server",
            Text = text,
            Duration = 10,
        })
    end)
end

-- El juego avisa a todo el servidor cuando sale un huevo raro (aprox. cada 5 minutos), con un mensaje como
-- "A Secret Starry Fox Egg spawned in Enchanted Forest". Se vigila el chat y los textos de la pantalla
-- en busca de ese aviso: de el sale el nombre del huevo y su rareza.
local announcement -- ultimo aviso visto en este servidor, resumido ("Secret Starry Fox")
local announcementRarity -- rareza de ese huevo si es una de las 4 mejores ("secret"), si no nil
local announcementTime = 0

-- "A Secret Starry Fox Egg spawned in Enchanted Forest!" -> "Secret Starry Fox"
local function parseAnnouncement(text)
    local clean = cleanText(text)
    local at = clean:lower():find("spawned in", 1, true)
    if not at then
        return clean:sub(1, 80), nil
    end

    local egg = (clean:sub(1, at - 1):gsub("^%s*[Aa]n?%s+", ""))
    egg = (egg:gsub("%s+[Hh]as%s*$", ""))
    egg = (egg:gsub("%s+[Ee]gg%s*$", ""))
    egg = egg:match("^%s*(.-)%s*$")

    if egg == "" then
        return clean:sub(1, 80), nil
    end
    return egg, egg
end

local function checkAnnouncement(text)
    -- los avisos son frases largas: ignora rapido los textos cortos o enormes (contadores, dinero, etc.)
    if type(text) ~= "string" or #text < 20 or #text > 300 then return end
    local lower = text:lower()
    if lower:find("egg", 1, true) and lower:find("spawned", 1, true) then
        local summary, egg = parseAnnouncement(text)
        announcement = summary
        announcementTime = os.clock()

        -- La rareza es la primera palabra ("Secret Starry Fox"): solo cuenta si es de las 4 mejores
        announcementRarity = egg and rareWordIn(egg:match("^(%S+)") or "") or nil

        -- "Secret Starry Fox" -> aprende "starry fox" para reconocer ese huevo en el mapa
        local typeName = egg and egg:match("^%S+%s+(.+)$")
        if typeName and announcementRarity then
            learnRare(typeName)
        end
    end
end

-- Se queda en este servidor (avisando) hasta que apagues la busqueda de huevos o cambies de modo.
-- En modo "raros", si mientras tanto llega un aviso de huevo raro, lo muestra.
local function holdHere(message)
    statusSuffix = ""
    setStatus(message, "ok")
    notify(message)

    local held = settings.eggMode
    local seen = announcementTime
    while alive() and settings.eggMode == held do
        if held == "rare" and announcementRarity and announcementTime > seen then
            seen = announcementTime
            local text = "¡Huevo raro! " .. tostring(announcement)
            setStatus(text, "ok")
            notify(text)
        end
        task.wait(0.5)
    end
end

-- "¡Aquí! Huevo Secret: 12.3" (modo raros) / "¡Aquí! Huevo gigante: 45.0" (modo grandes)
local function foundMessage(rareWord, size)
    if rareWord then
        local label = rareWord:sub(1, 1):upper() .. rareWord:sub(2)
        return ("¡Aquí! Huevo %s: %.1f"):format(label, size)
    end
    return ("¡Aquí! Huevo gigante: %.1f"):format(size)
end

task.spawn(function()
    pcall(function()
        game:GetService("TextChatService").MessageReceived:Connect(function(message)
            checkAnnouncement(message.Text)
        end)
    end)

    local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
    if not playerGui then return end

    local function watch(label)
        checkAnnouncement(label.Text)
        label:GetPropertyChangedSignal("Text"):Connect(function()
            checkAnnouncement(label.Text)
        end)
    end
    for _, d in ipairs(playerGui:GetDescendants()) do
        if d:IsA("TextLabel") then
            watch(d)
        end
    end
    playerGui.DescendantAdded:Connect(function(d)
        if d:IsA("TextLabel") then
            watch(d)
        end
    end)
end)

-- Lista los objetos del mapa con "egg" en el nombre, agrupados por nombre, del mas grande al mas chico.
-- Sirve para ver como se llaman los huevos de este juego y cuales son gigantes.
local function inspectEggs()
    local groups, list = {}, {}
    for _, inst in ipairs(workspace:GetDescendants()) do
        if (inst:IsA("Model") or inst:IsA("BasePart")) and inst.Name:lower():find("egg", 1, true) then
            local parent = inst.Parent
            local nested = parent and parent:IsA("Model") and parent.Name:lower():find("egg", 1, true)
            if not nested then
                local ok, size = pcall(function()
                    return inst:IsA("Model") and inst:GetExtentsSize() or inst.Size
                end)
                local biggest = ok and math.max(size.X, size.Y, size.Z) or 0

                local group = groups[inst.Name]
                if not group then
                    group = { name = inst.Name, count = 0, biggest = 0, path = inst:GetFullName() }
                    groups[inst.Name] = group
                    table.insert(list, group)
                end
                group.count = group.count + 1
                if biggest > group.biggest then
                    group.biggest = biggest
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.biggest > b.biggest end)
    return list
end

-- Describe un objeto: tamano, atributos, valores, textos visibles y nombres de sus hijos.
-- Sirve para descubrir donde guarda el juego la rareza / el tamano de cada huevo.
local function describeInstance(inst)
    local parts = { inst.Name .. " [" .. inst.ClassName .. "]" }

    local ok, size = pcall(function()
        return inst:IsA("Model") and inst:GetExtentsSize() or inst.Size
    end)
    if ok and size then
        table.insert(parts, ("tam %.1f"):format(math.max(size.X, size.Y, size.Z)))
    end

    local attrs = {}
    for key, value in pairs(inst:GetAttributes()) do
        table.insert(attrs, key .. "=" .. tostring(value))
    end
    if #attrs > 0 then
        table.insert(parts, "atributos{" .. table.concat(attrs, ", ") .. "}")
    end

    -- Textos, valores, cuadros de interaccion y atributos de las partes de adentro (Hitbox, etc.)
    local extras = {}
    for _, d in ipairs(inst:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            if d.Text ~= "" then
                table.insert(extras, "texto:" .. d.Text)
            end
        elseif d:IsA("ValueBase") then
            table.insert(extras, d.Name .. "=" .. tostring(d.Value))
        elseif d:IsA("ProximityPrompt") then
            table.insert(extras, "prompt:" .. d.ObjectText .. "/" .. d.ActionText)
        end

        local childAttrs = {}
        for key, value in pairs(d:GetAttributes()) do
            table.insert(childAttrs, key .. "=" .. tostring(value))
        end
        if #childAttrs > 0 then
            table.insert(extras, d.Name .. "{" .. table.concat(childAttrs, ", ") .. "}")
        end

        if #extras >= 12 then break end
    end
    if #extras > 0 then
        table.insert(parts, "{" .. table.concat(extras, " | ") .. "}")
    end

    local kids = {}
    for _, child in ipairs(inst:GetChildren()) do
        table.insert(kids, child.Name)
        if #kids >= 6 then break end
    end
    if #kids > 0 then
        table.insert(parts, "hijos(" .. table.concat(kids, ", ") .. ")")
    end

    return table.concat(parts, " ; ")
end

inspectBtn.Activated:Connect(function()
    local groups = inspectEggs()
    local slots = workspace:FindFirstChild("AreaEggSlotsClient")
    if #groups == 0 and not slots then
        setStatus("No hay nada con 'egg' en el nombre aquí", "error")
        return
    end

    local lines = {}
    if slots then
        table.insert(lines, "== Workspace.AreaEggSlotsClient (huevos del mapa) ==")
        local rootAttrs = describeInstance(slots)
        table.insert(lines, rootAttrs)
        for i, child in ipairs(slots:GetChildren()) do
            if i > 30 then break end
            table.insert(lines, describeInstance(child))
        end
        table.insert(lines, "== otros objetos con egg ==")
    end
    for i, group in ipairs(groups) do
        if i > 10 then break end
        table.insert(lines, ("%s x%d | tamaño máx %.1f | %s"):format(group.name, group.count, group.biggest, group.path))
    end

    -- El peso de un huevo se muestra en kg: busca carteles de texto del mapa que lo digan
    local kgTexts = {}
    for _, inst in ipairs(workspace:GetDescendants()) do
        if (inst:IsA("TextLabel") or inst:IsA("TextButton")) and inst.Text:lower():find("kg", 1, true) then
            table.insert(kgTexts, cleanText(inst.Text) .. "  <" .. inst:GetFullName() .. ">")
            if #kgTexts >= 10 then break end
        end
    end
    if #kgTexts > 0 then
        table.insert(lines, "== carteles con kg ==")
        for _, text in ipairs(kgTexts) do
            table.insert(lines, text)
        end
    end
    if announcement then
        table.insert(lines, "== ultimo aviso de huevo raro ==")
        table.insert(lines, announcement)
    end

    -- Plantillas de huevos (de ahi sale el nombre del huevo; puede traer su rareza)
    local newEggs = workspace:FindFirstChild("NewEggs")
    if newEggs then
        table.insert(lines, "== Workspace.NewEggs (plantillas) ==")
        for i, template in ipairs(newEggs:GetChildren()) do
            if i > 40 then break end
            local attrs = {}
            for key, value in pairs(template:GetAttributes()) do
                table.insert(attrs, key .. "=" .. tostring(value))
            end
            table.insert(lines, template.Name .. (#attrs > 0 and (" {" .. table.concat(attrs, ", ") .. "}") or ""))
        end
    end

    -- Zonas del mapa tal como las llama el juego
    local worldAreas = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Areas")
    if worldAreas then
        local names = {}
        for _, area in ipairs(worldAreas:GetChildren()) do
            table.insert(names, area.Name)
        end
        table.insert(lines, "== Workspace.World.Areas ==")
        table.insert(lines, table.concat(names, ", "))

        local guard = worldAreas:FindFirstChild("GuardAreas")
        if guard then
            local zones = {}
            for _, zone in ipairs(guard:GetChildren()) do
                table.insert(zones, zone.Name)
            end
            table.insert(lines, "== zonas (GuardAreas) ==")
            table.insert(lines, table.concat(zones, ", "))
        end
    end

    -- Textos visibles en la pantalla que hablen de huevos / zonas (por si el juego muestra un panel)
    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    if playerGui then
        local shown = {}
        for _, d in ipairs(playerGui:GetDescendants()) do
            if d:IsA("TextLabel") and d.Visible then
                local lower = d.Text:lower()
                if lower:find("egg", 1, true) or lower:find("spawn", 1, true) or lower:find("zone", 1, true) then
                    table.insert(shown, cleanText(d.Text) .. "  <" .. d:GetFullName() .. ">")
                    if #shown >= 12 then break end
                end
            end
        end
        if #shown > 0 then
            table.insert(lines, "== textos en pantalla sobre huevos ==")
            for _, text in ipairs(shown) do
                table.insert(lines, text)
            end
        end
    end
    -- Dimension / eventos (Rift, jefe, portal): para ver como los representa el juego cuando estan abiertos
    local keywords = { "rift", "dimension", "portal", "boss", "overlord", "scramble" }
    local eventLines, eventCount = {}, 0
    for _, inst in ipairs(workspace:GetDescendants()) do
        if inst:IsA("Model") or inst:IsA("BasePart") or inst:IsA("Folder") or inst:IsA("TextLabel") then
            local label = inst:IsA("TextLabel") and inst.Text or inst.Name
            local lower = label:lower()
            for _, word in ipairs(keywords) do
                if lower:find(word, 1, true) then
                    eventCount = eventCount + 1
                    if eventCount <= 25 then
                        table.insert(eventLines, ("%s [%s] <%s>"):format(cleanText(label):sub(1, 40), inst.ClassName, inst:GetFullName()))
                    end
                    break
                end
            end
        end
    end
    table.insert(lines, ("== objetos rift/portal/jefe/dimension (%d) =="):format(eventCount))
    for _, line in ipairs(eventLines) do
        table.insert(lines, line)
    end

    local giantSize, dimName, giantInst = scanMap()
    table.insert(lines, ("== escaneo: huevo enorme %.1f (%s) | dimension: %s =="):format(
        giantSize, giantInst and giantInst:GetFullName() or "ninguno", tostring(dimName)))

    local report = table.concat(lines, "\n")

    local copied = false
    if setclipboard then
        copied = pcall(setclipboard, report)
    end
    if not copied then
        warn(report)
    end

    setStatus(("%d tipos de huevo (%s)"):format(#groups, copied and "copiado al portapapeles" or "en consola"), "ok")
    notify(tostring(lines[3] or lines[1]):sub(1, 180))
end)

---------------------------------------------------------------------
-- Loop principal: busqueda de huevos y modo automatico
---------------------------------------------------------------------
-- Un salto con pausa: si falla (Roblox limita o no responde) espera un poco mas antes de reintentar
local function pacedHop()
    local started = hop()
    task.wait(started and AUTO_RETRY_DELAY or FAIL_RETRY_DELAY)
end

local function searchText(mode)
    return (mode == "rare" and "Buscando huevos raros...")
        or (mode == "dim" and "Buscando la dimensión...")
        or "Buscando huevos grandes..."
end

-- Revisa el servidor donde estoy (solo despues de un salto) y decide: quedarme, volver al mejor, o seguir
local function huntStep()
    local mode = settings.eggMode
    statusSuffix = ""
    setStatus(searchText(mode), "busy")

    -- El servidor donde estabas al empezar no cuenta: se busca en OTROS
    if skipCurrent then
        skipCurrent = false
        settings.huntSkip = game.JobId
        markVisited(game.JobId)
        saveSettings()
        pacedHop()
        return
    end

    -- Escanea unos segundos (el mapa carga poco a poco) y se queda con lo mejor visto
    local biggest, checked = 0, 0
    local rareWord, rareInst, rareViaAnnouncement
    local dimName
    local started = os.clock()
    repeat
        if mode == "dim" then
            local _, found = scanMap(false, true)
            dimName = found
            if dimName then break end
            task.wait(1.3)
        else
            local size, count = scanForEggs()
            if size > biggest then biggest = size end
            if count > checked then checked = count end

            if mode == "rare" and not rareWord then
                -- 1) el aviso del servidor: "A Secret ... egg spawned in ..."
                if announcementRarity and announcementTime >= started - 15 then
                    rareWord, rareViaAnnouncement = announcementRarity, true
                end
                -- 2) la rareza o el nombre del huevo leidos de sus datos en el mapa
                if not rareWord then
                    rareWord, rareInst = findRareEgg()
                end
            end
            if rareWord or (mode == "big" and biggest >= GIANT_MIN) then break end
            task.wait(0.5)
        end
    until os.clock() - started >= EGG_SCAN_SECONDS or not huntOn() or not alive()

    -- Este servidor ya cuenta como visto: la proxima busqueda no lo repite
    markVisited(game.JobId)
    saveSettings()

    if not huntOn() or not alive() or settings.eggMode ~= mode then
        return -- se apago (o cambio de modo) mientras escaneaba
    end

    if mode == "dim" then
        -- Solo la dimension: apenas la ve abierta se queda (el jefe puede morir en cualquier momento)
        -- y si no esta abierta sigue buscando en otro servidor, sin conformarse con nada mas.
        if dimName then
            holdHere(("¡Aquí! Dimensión abierta (%s)"):format(dimName))
        else
            pacedHop()
        end
        return
    end

    -- Huevos grandes: ademas de los huevos del mapa mide cualquier huevo grande en todo el mapa
    local giantSize = 0
    if mode == "big" and biggest < GIANT_MIN then
        giantSize = scanMap(true, false)
    end

    local isRare = rareWord ~= nil
    local size = math.max(biggest, giantSize)
    local isGiant = size >= GIANT_MIN
    if isRare then
        size = math.max(rareInst and largestDimension(rareInst) or biggest, 0.1)
    end
    -- Solo sirve lo que se pidio: raro en modo raros, 40+ en modo grandes. Nada de conformarse con otra cosa.
    local qualifies = (mode == "rare" and isRare) or (mode == "big" and isGiant)
    local rareLabel = isRare and rareWord or ""
    local score = size + (isRare and RARE_BONUS or 0)

    -- Con lugar para que el servidor no se llene (cuenta que yo ya estoy dentro)
    local roomy = Players.MaxPlayers - #Players:GetPlayers() >= HUNT_MIN_FREE - 1

    -- Si venia de vuelta hacia uno de los mejores, comprueba que llego Y que el huevo sigue ahi
    local arrived, lost
    if settings.eggReturning then
        settings.eggReturning = false
        local candidate = findCandidate(game.JobId)
        if candidate then
            local stillThere = qualifies
                or (mode == "rare" and candidate.ann and os.time() - (candidate.t or 0) < RARE_LIFETIME)
            if stillThere then
                arrived = candidate
            else
                removeCandidate(game.JobId)
                lost = true
            end
        else
            -- no se pudo entrar a ninguno: empieza una busqueda nueva
            resetHunt()
        end
        saveSettings()
    end

    if arrived then
        local label = arrived.rare ~= "" and arrived.rare or (rareLabel ~= "" and rareLabel or nil)
        holdHere(foundMessage(label, math.max(size, arrived.size or 0)))
    elseif lost and #topList() > 0 then
        -- el huevo ya no estaba: prueba el siguiente mejor
        settings.eggReturning = true
        saveSettings()
        goToServer(topList(), "Teletransportando al siguiente mejor...")
        task.wait(AUTO_RETRY_DELAY)
    elseif qualifies and not roomy then
        -- lo que busco, en un servidor casi lleno: mejor quedarme que arriesgarme a no volver
        holdHere(foundMessage(rareLabel ~= "" and rareLabel or nil, size))
    else
        if qualifies then
            addCandidate(game.JobId, score, size, rareLabel, { giant = isGiant, ann = rareViaAnnouncement })
        end
        settings.eggSamples = settings.eggSamples + 1
        saveSettings()

        local top = topList()
        if settings.eggSamples >= EGG_SAMPLE_SERVERS and #top > 0 then
            local best = top[1]
            if best.job == game.JobId then
                holdHere(foundMessage(best.rare ~= "" and best.rare or nil, best.size))
            else
                -- vuelve al mejor servidor visto; si no deja entrar, prueba el 2o y el 3o
                settings.eggReturning = true
                saveSettings()
                goToServer(top, "Teletransportando al mejor servidor...")
                task.wait(AUTO_RETRY_DELAY)
            end
        else
            pacedHop()
        end
    end
end

task.spawn(function()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end
    task.wait(AUTO_START_DELAY)

    while alive() do
        -- un error del script no debe dejar el menu muerto: se avisa y sigue
        local okStep, stepError = pcall(function()
            if huntOn() and not busy then
                huntStep()
            elseif settings.auto and not busy then
                pacedHop()
            else
                task.wait(0.3)
            end
        end)
        if not okStep then
            warn("[@XanScc Server] " .. tostring(stepError))
            setStatus("Error del script: " .. tostring(stepError):sub(1, 70), "error")
            task.wait(3)
        end
    end
end)
]==]

local env = (getgenv and getgenv()) or _G
env.__SH_SRC = SRC

-- Si algo falla al cargar, lo muestra como notificacion en pantalla (ademas de la consola)
local function showError(message)
    warn("[@XanScc Server] " .. tostring(message))
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "@XanScc Server: error",
            Text = tostring(message):sub(1, 180),
            Duration = 15,
        })
    end)
end

local fn, compileError = loadstring(SRC)
if not fn then
    showError("No compiló: " .. tostring(compileError))
else
    local ok, runError = pcall(fn)
    if not ok then
        showError(runError)
    end
end
