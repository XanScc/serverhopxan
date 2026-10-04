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

local MAX_PAGES = 50            -- tope de paginas (100 servidores cada una = hasta 5000 servidores)
local PAGE_DELAY = 0.05        -- pausa minima entre paginas
local SEARCH_TIMEOUT = 25        -- segundos maximos buscando (sin limite de intentos por pagina)
local MAX_FAILS_IN_A_ROW = 10 -- paginas seguidas fallidas antes de abandonar esa busqueda
local RANDOM_POOL = 30          -- en modo aleatorio junta hasta tantos servidores validos antes de elegir
local EMPTY_POOL = 15           -- servidores casi vacios que junta el boton "Server privado"
local EMPTY_MAX_PLAYERS = 1     -- "Server privado" busca servidores con 0 o 1 jugador
local MAX_TELEPORT_TRIES = 6    -- cuantos servidores distintos prueba si uno esta lleno o cerrado
local AUTO_START_DELAY = 2      -- segundos tras entrar a un servidor antes de volver a saltar (modo auto)
local AUTO_RETRY_DELAY = 3      -- espera tras un intento fallido en modo auto

-- Se reemplaza mas abajo, cuando existe el menu, para avisar "Reintentando..."
local notifyRetry = function() end

---------------------------------------------------------------------
-- Busqueda de servidores
---------------------------------------------------------------------
-- game:HttpGet en Xeno/Delta; si no existe, usa la funcion request del ejecutor
local function httpGet(url)
    local ok, body = pcall(function()
        return game:HttpGet(url)
    end)
    if ok and body then
        return body
    end

    local req = request or http_request or (syn and syn.request) or (http and http.request)
    if req then
        local res = req({ Url = url, Method = "GET" })
        if res and res.StatusCode == 200 then
            return res.Body
        end
    end
    error("sin respuesta HTTP")
end

-- Pide UNA pagina de servidores (un solo intento). Devuelve nil si fallo o hay limite de Roblox.
local function fetchPage(sortOrder, cursor)
    local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=%s&limit=100&excludeFullGames=true"):format(placeId, sortOrder)
    if cursor then
        url = url .. "&cursor=" .. cursor
    end

    local ok, body = pcall(httpGet, url)
    if not ok or not body then
        return nil
    end
    local ok2, decoded = pcall(function()
        return HttpService:JSONDecode(body)
    end)
    if ok2 and type(decoded) == "table" and type(decoded.data) == "table" then
        return decoded
    end
    return nil
end

-- Recorre paginas juntando servidores que cumplan `accept`. No se rinde: sigue pasando de pagina
-- hasta juntar suficientes, llegar al final de la lista o agotar SEARCH_TIMEOUT.
--   orders:   lista de ordenes a recorrer AL MISMO TIEMPO (ej. {"Asc","Desc"} = empieza por los dos extremos)
--   target:   deja de buscar al juntar tantos servidores validos
--   firstHit: si es true, se detiene en la primera pagina que tenga resultados
--             (la lista viene ordenada, asi que lo mejor esta al principio)
-- Si Roblox limita una pagina, espera un momento (cada vez un poco mas) y sigue con la misma pagina.
-- Devuelve (lista, huboError).
local function collectServers(accept, orders, target, firstHit, onProgress)
    local found, seen = {}, {}
    local deadline = os.clock() + SEARCH_TIMEOUT
    local finished, pagesDone = 0, 0
    local stop, hadError = false, false

    local function chain(sortOrder)
        local cursor
        local pages, fails = 0, 0
        while pages < MAX_PAGES and not stop and os.clock() < deadline do
            local page = fetchPage(sortOrder, cursor)
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
                task.wait(PAGE_DELAY)
            else
                fails = fails + 1
                hadError = true
                if fails >= MAX_FAILS_IN_A_ROW then break end
                notifyRetry(fails)
                task.wait(math.min(0.4 * fails, 2))
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
end

local function normalAccept(server)
    if not baseAccept(server) then return false end
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

local W, H = 290, 304

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

local track = make("TextButton", {
    Size = UDim2.fromOffset(48, 26),
    Position = UDim2.new(1, -48, 0, 2),
    BackgroundColor3 = C.switchOff,
    Text = "",
    BorderSizePixel = 0,
    AutoButtonColor = false,
}, autoRow)
corner(track, 13)
local knob = make("Frame", {
    Size = UDim2.fromOffset(20, 20),
    Position = UDim2.fromOffset(3, 3),
    BackgroundColor3 = C.white,
    BorderSizePixel = 0,
}, track)
corner(knob, 10)

local function refreshSwitch(animate)
    local goal = {
        track = { BackgroundColor3 = settings.auto and C.ok or C.switchOff },
        knob = { Position = settings.auto and UDim2.fromOffset(25, 3) or UDim2.fromOffset(3, 3) },
    }
    if animate then
        local info = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        TweenService:Create(track, info, goal.track):Play()
        TweenService:Create(knob, info, goal.knob):Play()
    else
        track.BackgroundColor3 = goal.track.BackgroundColor3
        knob.Position = goal.knob.Position
    end
end
refreshSwitch(false)

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
local statusSection = section(30)
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
    TextTruncate = Enum.TextTruncate.AtEnd,
    TextXAlignment = Enum.TextXAlignment.Left,
}, statusBox)

local STATUS_COLORS = { ok = C.ok, busy = C.warn, info = C.info, error = C.err }
local function setStatus(text, kind)
    local color = STATUS_COLORS[kind or "info"] or C.info
    statusLabel.Text = text
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
    Text = "by @XanScc",
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

-- Intenta entrar al siguiente candidato de la lista. Devuelve true si el teleport arranco.
local function teleportNext()
    while poolIndex <= #pool and triesUsed < MAX_TELEPORT_TRIES do
        local target = pool[poolIndex]
        poolIndex = poolIndex + 1
        triesUsed = triesUsed + 1

        -- Hace que el menu se cargue de nuevo en el servidor nuevo
        if not queued and queue_on_teleport and SRC then
            queued = true
            pcall(queue_on_teleport, string.format(
                "local e=(getgenv and getgenv()) or _G; e.__SH_SRC=%q; loadstring(e.__SH_SRC)()", SRC))
        end

        setStatus(("Teletransportando... (%d/%d jugadores)"):format(target.playing, target.maxPlayers), "info")
        local ok = pcall(function()
            TeleportService:TeleportToPlaceInstance(placeId, target.id, player)
        end)
        if ok then
            -- Si Roblox no responde en 20s, libera el boton para volver a intentar
            busyToken = busyToken + 1
            local token = busyToken
            task.delay(20, function()
                if busyToken == token then
                    busy = false
                end
            end)
            return true
        end
    end
    return false
end

-- Si el servidor elegido se lleno o cerro, prueba automaticamente con el siguiente
TeleportService.TeleportInitFailed:Connect(function(_, result, message)
    if not alive() or not busy then return end
    setStatus("Servidor no disponible, probando otro...", "busy")
    if not teleportNext() then
        setStatus("Ningún servidor aceptó, reintenta", "error")
        busy = false
    end
end)

-- mode: nil = salto normal (con filtros del menu), "empty" = servidor casi vacio
local function hop(mode)
    if busy then return false end
    busy = true

    local ok, list, failed
    if mode == "empty" then
        setStatus("Buscando server vacío...", "busy")
        ok, list, failed = pcall(collectServers, emptyAccept, { "Asc" }, EMPTY_POOL, true, function(page)
            setStatus(("Buscando server vacío... (página %d)"):format(page), "busy")
        end)
    else
        setStatus("Buscando servidores...", "busy")
        local isRandom = settings.sort == "Random"
        -- Aleatorio recorre los dos extremos de la lista a la vez (mas rango, mas rapido)
        local orders = isRandom and { "Asc", "Desc" } or { (settings.sort == "Most") and "Desc" or "Asc" }
        ok, list, failed = pcall(collectServers, normalAccept, orders,
            isRandom and RANDOM_POOL or 15, not isRandom, function(page)
                if page > 1 then
                    setStatus(("Buscando servidores... (página %d)"):format(page), "busy")
                end
            end)
    end

    if not ok then
        setStatus("Error al buscar servidores", "error")
        busy = false
        return false
    end
    if #list == 0 then
        if failed then
            setStatus("Error de red o rate limit, reintenta", "error")
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
    elseif settings.sort == "Random" then
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
-- Loop del modo automatico (sin temporizador: salta apenas entra al servidor)
---------------------------------------------------------------------
task.spawn(function()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end
    task.wait(AUTO_START_DELAY)

    while alive() do
        if settings.auto and not busy then
            hop()
            task.wait(AUTO_RETRY_DELAY)
        else
            task.wait(0.3)
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
