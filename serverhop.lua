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
    knownRare = "starry fox", -- nombres de huevos raros ya vistos en avisos ("|" entre nombres)
    rareHunt = false,         -- buscando servidores con huevos del top 4 de rarezas
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

local W, H = 290, 442

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

---------------------------------------------------------------------
-- Datos del servidor y huevos raros (agregado)
---------------------------------------------------------------------
local function buttonIn(parent, text, position, colorA, colorB)
    local bg = make("Frame", {
        Size = UDim2.new(0.5, -4, 1, 0),
        Position = position,
        BackgroundColor3 = C.white,
        BorderSizePixel = 0,
    }, parent)
    corner(bg, 10)
    gradient(bg, 0, colorA, colorB)
    return make("TextButton", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = C.white,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        BorderSizePixel = 0,
    }, bg)
end

local eggSection = section(38)
local scanBtn = buttonIn(eggSection, "Escanear servidor", UDim2.fromOffset(0, 0),
    Color3.fromRGB(245, 158, 11), Color3.fromRGB(239, 68, 68))
local rareBtn = buttonIn(eggSection, "Buscar raros", UDim2.new(0.5, 4, 0, 0),
    Color3.fromRGB(236, 72, 153), C.accentA)

local infoSection = section(92)
local infoBox = make("Frame", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundColor3 = C.field,
    BorderSizePixel = 0,
}, infoSection)
corner(infoBox, 8)
stroke(infoBox, C.border, 1, 0)

local infoLabel = make("TextLabel", {
    Size = UDim2.new(1, -16, 1, -8),
    Position = UDim2.fromOffset(8, 4),
    BackgroundTransparency = 1,
    Text = "Pulsa «Escanear servidor» para ver el huevo más grande, su tamaño y su zona.",
    TextColor3 = C.text,
    Font = Enum.Font.GothamMedium,
    TextSize = 11,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
}, infoBox)

local copyBtn = make("TextButton", {
    Size = UDim2.fromOffset(50, 18),
    Position = UDim2.new(1, -56, 1, -22),
    BackgroundColor3 = C.border,
    Text = "Copiar",
    TextColor3 = C.white,
    Font = Enum.Font.GothamBold,
    TextSize = 10,
    BorderSizePixel = 0,
}, infoBox)
corner(copyBtn, 6)

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

---------------------------------------------------------------------
-- Huevos: tamano, zona y rareza (agregado)
---------------------------------------------------------------------
-- Cosas que se sabe del juego (Steal An Egg):
--  * Los huevos del mapa son hijos de Workspace.AreaEggSlotsClient; el nombre del modelo no dice la rareza.
--  * Tamano: se mide en studs (el huevo mas grande del modelo); el peso en kg solo se ve en la mochila.
--  * Rarezas, de menor a mayor: Common, Uncommon, Rare, Epic, Legendary, Mythic, Cosmic, Secret, Eternal, Divine.
--    El "top 4" son Cosmic, Secret, Eternal y Divine.
--  * Zonas (Workspace.World.Areas.GuardAreas): Forest, Lake, Desert, Jungle, Snow, Volcano, Abyss Ocean,
--    Prehistoric, Cosmic, Cherry Blossom, Titan Temple, Light Dark, Enchanted Forest.
--  * Cuando sale un huevo raro, el juego avisa: "A Secret Starry Fox Egg spawned in Enchanted Forest!".
local GIANT_MIN = 40.0          -- un huevo de tantos studs o mas se marca como gigante
local RARE_POOL = 100           -- servidores que junta la busqueda de raros
local RARE_SCAN_SECONDS = 3     -- segundos que revisa cada servidor buscando un raro
local RARE_LIFETIME = 270       -- segundos que vale un aviso de huevo raro
local RARE_WORDS = { "divine", "eternal", "secret", "cosmic" }

-- Rarezas del top 4 que se han visto salir en cada zona (segun guias del juego; puede estar incompleto)
local ZONE_RARES = {
    ["forest"] = "ninguna de las 4 más buscadas",
    ["lake"] = "Cosmic",
    ["desert"] = "Cosmic",
    ["jungle"] = "Secret",
    ["snow"] = "Secret, Eternal",
    ["volcano"] = "Secret, Eternal",
    ["abyss ocean"] = "Eternal",
    ["prehistoric"] = "Secret, Eternal",
    ["cosmic"] = "Cosmic, Secret, Eternal, Divine",
    ["cherry blossom"] = "Cosmic, Secret, Eternal, Divine",
    ["titan temple"] = "Divine",
    ["enchanted forest"] = "Secret (Starry Fox)",
}

-- Los 5 huevos de la zona Enchanted Forest traen su nombre en el atributo PreparedSourceName
local ZONE_BY_EGG = {
    ["prism gecko"] = "Enchanted Forest",
    ["petal beetle"] = "Enchanted Forest",
    ["enchanted bluejay"] = "Enchanted Forest",
    ["astral jackalope"] = "Enchanted Forest",
    ["starry fox"] = "Enchanted Forest",
}

local function notify(text)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "@XanScc Server",
            Text = text,
            Duration = 10,
        })
    end)
end

local function cleanText(text)
    return (text:gsub("<[^>]*>", "")) -- quita etiquetas de texto enriquecido
end

local function capital(text)
    return text:sub(1, 1):upper() .. text:sub(2)
end

local function largestDimension(inst)
    local ok, size = pcall(function()
        return inst:IsA("Model") and inst:GetExtentsSize() or inst.Size
    end)
    if ok and size then
        return math.max(size.X, size.Y, size.Z)
    end
    return 0
end

-- Nombre del tipo de huevo ("Starry Fox") si el modelo lo trae; si no, nil.
local function eggTypeName(inst)
    local source = inst:GetAttribute("PreparedSourceName")
    if type(source) == "string" then
        return source:match("NewEggs%.(.+)$")
    end
    return nil
end

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
local function treeRarity(root)
    local function check(obj)
        local word = rareWordIn(obj.Name)
        if word then return word end
        for _, value in pairs(obj:GetAttributes()) do
            if type(value) == "string" then
                word = rareWordIn(value)
                if word then return word end
            end
        end
        if obj:IsA("TextLabel") or obj:IsA("TextButton") then
            word = rareWordIn(obj.Text)
            if word then return word end
        elseif obj:IsA("StringValue") then
            word = rareWordIn(obj.Value)
            if word then return word end
        end
        return nil
    end

    local word = check(root)
    if word then return word end
    for _, d in ipairs(root:GetDescendants()) do
        word = check(d)
        if word then return word end
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

-- Rareza de UN huevo (top 4): por su nombre de tipo ya conocido, o por lo escrito en sus datos / plantilla.
-- Devuelve la rareza ("secret"), "raro" si solo se sabe que es raro, o nil.
local function eggRarity(egg)
    -- el juego marca los huevos raros con un resaltado propio (RareAreaEggHighlight) dentro del modelo
    if egg:FindFirstChild("RareAreaEggHighlight", true) then
        return "raro"
    end
    local typeName = eggTypeName(egg)
    if typeName and isKnownRare(typeName) then
        return "raro"
    end
    local word = treeRarity(egg)
    if word then return word end

    local templateName = typeName
    local newEggs = workspace:FindFirstChild("NewEggs")
    local template = templateName and newEggs and newEggs:FindFirstChild(templateName)
    if template then
        return treeRarity(template)
    end
    return nil
end

-- Todos los huevos del mapa: { { inst, size }, ... }
local function listEggs()
    local eggs = {}
    local slots = workspace:FindFirstChild("AreaEggSlotsClient")
    if slots then
        for _, child in ipairs(slots:GetChildren()) do
            if child:IsA("Model") or child:IsA("BasePart") then
                eggs[#eggs + 1] = { inst = child, size = largestDimension(child) }
            end
        end
    end
    return eggs
end

-- Primer huevo raro (top 4) del mapa, o nil. Devuelve (rareza, huevo).
local function findRareEgg()
    for _, egg in ipairs(listEggs()) do
        local word = eggRarity(egg.inst)
        if word then
            return word, egg.inst
        end
    end
    return nil
end

-- Zonas del mapa: cada hijo de Workspace.World.Areas (y, dentro de GuardAreas, cada zona), con su caja.
-- Antes solo se miraba GuardAreas y zonas como "Demons" no salian.
local zoneCache = { time = -100, list = {} }

local function boundsOf(area)
    local ok, center, size = pcall(function()
        if area:IsA("Model") then
            local cf, sz = area:GetBoundingBox()
            return cf.Position, sz
        elseif area:IsA("BasePart") then
            return area.Position, area.Size
        end
        local lo, hi, count
        for _, d in ipairs(area:GetDescendants()) do
            if d:IsA("BasePart") then
                local p, half = d.Position, d.Size / 2
                local a, b = p - half, p + half
                if not lo then
                    lo, hi = a, b
                else
                    lo = Vector3.new(math.min(lo.X, a.X), math.min(lo.Y, a.Y), math.min(lo.Z, a.Z))
                    hi = Vector3.new(math.max(hi.X, b.X), math.max(hi.Y, b.Y), math.max(hi.Z, b.Z))
                end
                count = (count or 0) + 1
                if count >= 300 then break end
            end
        end
        if lo then
            return (lo + hi) / 2, hi - lo
        end
    end)
    if ok and center then
        return center, size
    end
    return nil
end

local function zoneList()
    if os.clock() - zoneCache.time < 10 and #zoneCache.list > 0 then
        return zoneCache.list
    end
    local list = {}
    pcall(function()
        for _, area in ipairs(workspace.World.Areas:GetChildren()) do
            local items = (area.Name == "GuardAreas") and area:GetChildren() or { area }
            for _, item in ipairs(items) do
                local center, size = boundsOf(item)
                if center then
                    list[#list + 1] = { name = item.Name, center = center, size = size }
                end
            end
        end
    end)
    zoneCache = { time = os.clock(), list = list }
    return list
end

-- Zona (bioma) de un huevo: si su nombre la trae ("..._Forest:Slot_005") o es de la zona nueva, esa;
-- si no, la zona cuya caja contiene al huevo (la mas chica) y, si ninguna, la mas cercana (aproximada).
local function zoneOfEgg(inst)
    if not inst then return nil end

    local typeName = eggTypeName(inst)
    if typeName and ZONE_BY_EGG[typeName:lower()] then
        return ZONE_BY_EGG[typeName:lower()]
    end

    local fromName = inst.Name:match("_([^_:]+):Slot_%d+$")
    if fromName then
        return fromName
    end

    local ok, zone = pcall(function()
        local position = inst:IsA("Model") and inst:GetPivot().Position or inst.Position
        local inside, insideArea, nearest, nearestDistance
        for _, z in ipairs(zoneList()) do
            local d = position - z.center
            local area = z.size.X * z.size.Z
            if math.abs(d.X) <= z.size.X / 2 and math.abs(d.Z) <= z.size.Z / 2 then
                if not insideArea or area < insideArea then
                    inside, insideArea = z.name, area
                end
            end
            local distance = Vector3.new(d.X, 0, d.Z).Magnitude
            if not nearestDistance or distance < nearestDistance then
                nearest, nearestDistance = z.name, distance
            end
        end
        if inside then
            return inside
        end
        return nearest and (nearest .. " (aprox.)") or nil
    end)
    if ok and zone then
        return zone
    end
    return nil
end

local function zoneRares(zone)
    if not zone then return nil end
    local key = zone:gsub(" %(aprox%.%)", ""):lower()
    return ZONE_RARES[key]
end

---------------------------------------------------------------------
-- Avisos del juego: "A Secret Starry Fox Egg spawned in Enchanted Forest!"
---------------------------------------------------------------------
-- Cartel grande arriba de la pantalla: SOLO sale al pulsar "Escanear servidor" y hay huevos raros
-- (una linea por huevo). Se quita solo a los 10 segundos.
local banner, bannerToken = nil, 0
local function hideBanner()
    bannerToken = bannerToken + 1
    if banner then
        banner.Visible = false
    end
end

local function showBanner(text, lines)
    task.spawn(function()
        pcall(function()
            if not banner then
                banner = make("TextLabel", {
                    BackgroundColor3 = Color3.fromRGB(120, 20, 160),
                    TextColor3 = C.white,
                    Font = Enum.Font.GothamBold,
                    TextSize = 14,
                    TextWrapped = true,
                    Visible = false,
                    ZIndex = 10,
                }, gui)
                corner(banner, 10)
                stroke(banner, Color3.fromRGB(251, 191, 36), 2, 0)
            end
            banner.Size = UDim2.fromOffset(460, 16 + 18 * (lines or 1))
            banner.Position = UDim2.new(0.5, -230, 0, 70)
            banner.Text = text
            banner.Visible = true
            bannerToken = bannerToken + 1
            local token = bannerToken
            task.wait(10)
            if bannerToken == token then
                banner.Visible = false
            end
        end)
    end)
end

-- Ultimos avisos del juego de huevos Divine / Eternal / Secret / Cosmic: sirven para ponerle nombre y zona
-- a los huevos raros cuando se escanea el servidor.
local recentAnnouncements = {}

local announcement       -- ultimo aviso visto en este servidor, resumido ("Secret Starry Fox")
local announcementRarity -- su rareza si es del top 4 ("secret"), si no nil
local announcementZone   -- zona que dice el aviso ("Enchanted Forest")
local announcementTime = 0

local function parseAnnouncement(text)
    local clean = cleanText(text)
    local at = clean:lower():find("spawned in", 1, true)
    if not at then return nil end

    local egg = (clean:sub(1, at - 1):gsub("^%s*[Aa]n?%s+", ""))
    egg = (egg:gsub("%s+[Hh]as%s*$", ""))
    egg = (egg:gsub("%s+[Ee]gg%s*$", ""))
    egg = egg:match("^%s*(.-)%s*$")
    if egg == "" then return nil end

    local zone = clean:sub(at + #"spawned in"):match("^%s*([%a%s']+)")
    zone = zone and zone:match("^(.-)%s*$") or nil
    return egg, zone
end

local function checkAnnouncement(text)
    -- los avisos son frases largas: ignora rapido los textos cortos o enormes (contadores, dinero, etc.)
    if type(text) ~= "string" or #text < 20 or #text > 300 then return end
    local lower = text:lower()
    if lower:find("egg", 1, true) and lower:find("spawned", 1, true) then
        local egg, zone = parseAnnouncement(text)
        if not egg then return end
        announcement = egg
        announcementZone = zone
        announcementTime = os.clock()

        -- la rareza es la primera palabra ("Secret Starry Fox"): solo cuenta si es del top 4
        announcementRarity = rareWordIn(egg:match("^(%S+)") or "")

        -- "Secret Starry Fox" -> aprende "starry fox" para reconocer ese huevo en el mapa
        local typeName = egg:match("^%S+%s+(.+)$")
        if typeName and announcementRarity then
            learnRare(typeName)
        end
        if announcementRarity then
            local last = recentAnnouncements[#recentAnnouncements]
            if not (last and last.name == egg and os.clock() - last.time < 60) then
                recentAnnouncements[#recentAnnouncements + 1] = { name = egg, zone = zone, time = os.clock(), type = typeName }
                while #recentAnnouncements > 10 do
                    table.remove(recentAnnouncements, 1)
                end
            end
        end
    end
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

---------------------------------------------------------------------
-- Panel de datos del servidor
---------------------------------------------------------------------
local info = {}
local function renderInfo()
    local lines = {}
    lines[1] = "Huevo: " .. (info.egg or "-") .. "  |  " .. (info.rarity or "-")
    if info.size then
        lines[2] = ("Tamaño: %.1f studs%s"):format(info.size, info.size >= GIANT_MIN and " (gigante)" or "")
    else
        lines[2] = "Tamaño: -"
    end
    lines[3] = "Zona: " .. (info.zone or "-")
    local rares = zoneRares(info.zone)
    if rares then
        lines[3] = lines[3] .. "  (ahí salen: " .. rares .. ")"
    end
    lines[4] = ("Servidor: %d/%d jugadores"):format(#Players:GetPlayers(), Players.MaxPlayers)
        .. (info.count and (" | huevos: " .. info.count .. " | raros: " .. (info.rareCount or 0)) or "")
    lines[5] = info.note or ""
    infoLabel.Text = table.concat(lines, "\n")
end

local function setInfo(fields)
    for k, v in pairs(fields) do
        if v == false then
            info[k] = nil
        else
            info[k] = v
        end
    end
    renderInfo()
end

---------------------------------------------------------------------
-- Guia al huevo: lo resalta y muestra la distancia, para que vayas caminando
---------------------------------------------------------------------
local guides = {} -- { { inst, text, highlight, billboard, label }, ... }

local function clearGuide()
    for _, g in ipairs(guides) do
        pcall(function() if g.highlight then g.highlight:Destroy() end end)
        pcall(function() if g.billboard then g.billboard:Destroy() end end)
    end
    guides = {}
end

local function eggPosition(inst)
    local ok, pos = pcall(function()
        return inst:IsA("Model") and inst:GetPivot().Position or inst.Position
    end)
    return ok and pos or nil
end

local function distanceTo(inst)
    local ok, d = pcall(function()
        local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
        local pos = eggPosition(inst)
        if root and pos then
            return math.floor((root.Position - pos).Magnitude)
        end
    end)
    return (ok and type(d) == "number") and d or nil
end

local function addGuide(inst, text, color)
    local part = inst:IsA("BasePart") and inst
        or (inst:IsA("Model") and (inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)))
    if not part then return end

    local g = { inst = inst, text = text }
    pcall(function()
        g.highlight = make("Highlight", {
            Adornee = inst,
            FillColor = color or Color3.fromRGB(251, 191, 36),
            FillTransparency = 0.5,
            OutlineColor = C.white,
            DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
        }, gui)
        g.billboard = make("BillboardGui", {
            Adornee = part,
            AlwaysOnTop = true,
            Size = UDim2.fromOffset(150, 32),
            StudsOffset = Vector3.new(0, 4, 0),
        }, gui)
        g.label = make("TextLabel", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundColor3 = C.bg,
            BackgroundTransparency = 0.3,
            TextColor3 = C.white,
            Font = Enum.Font.GothamBold,
            TextSize = 10,
            TextWrapped = true,
            Text = text,
        }, g.billboard)
        corner(g.label, 8)
    end)
    guides[#guides + 1] = g
end

local function setGuide(inst, text, color)
    clearGuide()
    addGuide(inst, text, color)
end

-- Actualiza la distancia a cada huevo guiado (y quita la guia si el huevo desaparece o se cierra el menu)
task.spawn(function()
    while alive() do
        for i = #guides, 1, -1 do
            local g = guides[i]
            if not g.inst.Parent then
                pcall(function() if g.highlight then g.highlight:Destroy() end end)
                pcall(function() if g.billboard then g.billboard:Destroy() end end)
                table.remove(guides, i)
            elseif g.label then
                local d = distanceTo(g.inst)
                if d then
                    pcall(function()
                        local name, detail = g.text:match("^(.-)\n(.*)$")
                        name = name or g.text
                        if d <= 150 then
                            g.billboard.Size = UDim2.fromOffset(210, detail and 54 or 38)
                            g.label.TextSize = 11
                            g.label.BackgroundTransparency = 0.3
                            g.label.Text = name .. (detail and ("\n" .. detail) or "") .. "\n" .. d .. " studs"
                        elseif d <= 500 then
                            g.billboard.Size = UDim2.fromOffset(150, 32)
                            g.label.TextSize = 10
                            g.label.BackgroundTransparency = 0.45
                            g.label.Text = name .. "\n" .. d .. " studs"
                        else
                            g.billboard.Size = UDim2.fromOffset(120, 20)
                            g.label.TextSize = 9
                            g.label.BackgroundTransparency = 0.6
                            g.label.Text = name:sub(1, 22) .. " | " .. d
                        end
                    end)
                end
            end
        end
        task.wait(0.3)
    end
    clearGuide()
end)

---------------------------------------------------------------------
-- Escanear servidor: recopila los datos del servidor y marca el huevo mas grande
---------------------------------------------------------------------
-- Descripcion corta de un objeto (atributos e hijos) para el reporte
local function describeShort(inst)
    local parts = { inst:GetFullName() }
    local attrs = {}
    for key, value in pairs(inst:GetAttributes()) do
        attrs[#attrs + 1] = key .. "=" .. tostring(value)
    end
    if #attrs > 0 then parts[#parts + 1] = "atributos{" .. table.concat(attrs, ", ") .. "}" end
    local kids = {}
    for _, child in ipairs(inst:GetChildren()) do
        kids[#kids + 1] = child.Name
        if #kids >= 8 then break end
    end
    if #kids > 0 then parts[#parts + 1] = "hijos(" .. table.concat(kids, ", ") .. ")" end

    -- lo de adentro (Hitbox, etc.): textos, valores, cuadros de interaccion y atributos de las partes
    local extras = {}
    for _, d in ipairs(inst:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            if d.Text ~= "" then extras[#extras + 1] = "texto:" .. cleanText(d.Text) end
        elseif d:IsA("ValueBase") then
            extras[#extras + 1] = d.Name .. "=" .. tostring(d.Value)
        elseif d:IsA("ProximityPrompt") then
            extras[#extras + 1] = "prompt:" .. d.ObjectText .. "/" .. d.ActionText
        end
        local childAttrs = {}
        for key, value in pairs(d:GetAttributes()) do
            childAttrs[#childAttrs + 1] = key .. "=" .. tostring(value)
        end
        if #childAttrs > 0 then extras[#extras + 1] = d.Name .. "{" .. table.concat(childAttrs, ", ") .. "}" end
        if #extras >= 14 then break end
    end
    if #extras > 0 then parts[#parts + 1] = "dentro{" .. table.concat(extras, " | ") .. "}" end
    return table.concat(parts, " ; ")
end

local function zoneKey(z)
    if not z then return nil end
    return ((z:gsub(" %(aprox%.%)", "")):lower())
end

-- Busca el aviso del juego que corresponde a un huevo raro: primero por el nombre del tipo, luego por la zona.
-- "used" evita darle el mismo aviso a dos huevos.
local function matchAnnouncement(inst, zone, used)
    local typeName = eggTypeName(inst)
    for i = #recentAnnouncements, 1, -1 do
        local a = recentAnnouncements[i]
        if not used[a] and typeName and a.type and a.type:lower() == typeName:lower() then
            used[a] = true
            return a
        end
    end
    for i = #recentAnnouncements, 1, -1 do
        local a = recentAnnouncements[i]
        if not used[a] and a.zone and zoneKey(a.zone) == zoneKey(zone) then
            used[a] = true
            return a
        end
    end
    return nil
end

-- Texto de rareza para el panel
local function rarityText(word)
    if not word then return "no raro / sin detectar" end
    if word == "raro" then
        if announcementRarity and (os.clock() - announcementTime) < RARE_LIFETIME then
            return capital(announcementRarity) .. " (confirmado por aviso)"
        end
        return "RARO (aura del juego; rareza sin confirmar)"
    end
    return capital(word)
end

-- Describe la marca de rareza de un huevo (para el reporte): tamano, zona, nombre y colores del resaltado
local function describeMark(egg)
    local mark = egg:FindFirstChild("RareAreaEggHighlight", true)
    if not mark then return nil end
    local parts = { ("%.1f"):format(largestDimension(egg)), zoneOfEgg(egg) or "-", egg.Name, mark.ClassName }
    pcall(function()
        parts[#parts + 1] = "FillColor=" .. tostring(mark.FillColor) .. " OutlineColor=" .. tostring(mark.OutlineColor)
            .. " Enabled=" .. tostring(mark.Enabled)
    end)
    for key, value in pairs(mark:GetAttributes()) do
        parts[#parts + 1] = key .. "=" .. tostring(value)
    end
    -- particulas del aura (Glow, glare...): colores y cantidad
    local count = 0
    for _, d in ipairs(egg:GetDescendants()) do
        if d:IsA("ParticleEmitter") then
            count = count + 1
            if count <= 6 then
                pcall(function()
                    local keys = d.Color.Keypoints
                    parts[#parts + 1] = ("particula %s color(%s -> %s) rate=%s enabled=%s"):format(
                        d.Name, tostring(keys[1].Value), tostring(keys[#keys].Value), tostring(d.Rate), tostring(d.Enabled))
                end)
            end
        end
    end
    return table.concat(parts, " | ")
end

local lastReport = ""

local function scanServer()
    setStatus("Escaneando servidor...", "busy")
    local eggs = listEggs()
    table.sort(eggs, function(a, b) return a.size > b.size end)

    local rareCount, firstRare, rareEggs = 0, nil, {}
    local lines = {
        ("Servidor %s | jugadores %d/%d | huevos %d"):format(game.JobId, #Players:GetPlayers(), Players.MaxPlayers, #eggs),
    }
    for i, egg in ipairs(eggs) do
        local rarity = eggRarity(egg.inst)
        if rarity then
            rareCount = rareCount + 1
            rareEggs[#rareEggs + 1] = egg
            if not firstRare then firstRare = egg end
        end
        if i <= 60 then
            lines[#lines + 1] = ("%.1f | tipo %s | zona %s | rareza %s | %s"):format(
                egg.size, eggTypeName(egg.inst) or "-", zoneOfEgg(egg.inst) or "-", rarity or "-", egg.inst.Name)
        end
    end

    for _, egg in ipairs(eggs) do
        local mark = describeMark(egg.inst)
        if mark then
            lines[#lines + 1] = "MARCADO RARO: " .. mark
            lines[#lines + 1] = "detalle raro: " .. describeShort(egg.inst)
        end
    end

    -- aviso reciente del juego (huevo raro)
    local recent = announcement and (os.clock() - announcementTime) < RARE_LIFETIME
    if announcement then
        lines[#lines + 1] = "aviso: " .. announcement .. " | zona " .. tostring(announcementZone)
    end
    for i = 1, math.min(3, #eggs) do
        lines[#lines + 1] = "detalle " .. i .. ": " .. describeShort(eggs[i].inst)
    end
    local shown = {}
    for _, egg in ipairs(eggs) do
        local typeName = eggTypeName(egg.inst)
        if typeName and not shown[typeName] then
            shown[typeName] = true
            lines[#lines + 1] = "tipo " .. typeName .. ": " .. describeShort(egg.inst)
        end
    end
    local newEggs = workspace:FindFirstChild("NewEggs")
    if newEggs then
        lines[#lines + 1] = "== Workspace.NewEggs (plantillas) =="
        for i, template in ipairs(newEggs:GetChildren()) do
            if i > 40 then break end
            lines[#lines + 1] = describeShort(template)
        end
    end
    local areas = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Areas")
    if areas then
        lines[#lines + 1] = "== Workspace.World.Areas (todas las areas) =="
        for i, area in ipairs(areas:GetChildren()) do
            if i > 30 then break end
            local kids = {}
            for _, child in ipairs(area:GetChildren()) do
                kids[#kids + 1] = child.Name
                if #kids >= 14 then break end
            end
            lines[#lines + 1] = ("area %s [%s] hijos(%s)"):format(area.Name, area.ClassName, table.concat(kids, ", "))
        end
    end
    local zoneBoxes = {}
    for _, z in ipairs(zoneList()) do
        zoneBoxes[#zoneBoxes + 1] = ("%s centro(%d,%d) tam(%d x %d)"):format(z.name, z.center.X, z.center.Z, z.size.X, z.size.Z)
    end
    lines[#lines + 1] = "== cajas de zonas usadas =="
    for _, box in ipairs(zoneBoxes) do lines[#lines + 1] = box end

    local demons, seenCount = {}, 0
    for _, d in ipairs(workspace:GetDescendants()) do
        seenCount = seenCount + 1
        if seenCount % 4000 == 0 then task.wait() end
        if d.Name:lower():find("demon", 1, true) then
            demons[#demons + 1] = d:GetFullName() .. " [" .. d.ClassName .. "]"
            if #demons >= 10 then break end
        end
    end
    if #demons > 0 then
        lines[#lines + 1] = "== objetos con 'demon' =="
        for _, d in ipairs(demons) do lines[#lines + 1] = d end
    end

    local guard = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Areas")
    guard = guard and guard:FindFirstChild("GuardAreas")
    if guard then
        local names = {}
        for _, zone in ipairs(guard:GetChildren()) do names[#names + 1] = zone.Name end
        lines[#lines + 1] = "zonas: " .. table.concat(names, ", ")
    end
    lastReport = table.concat(lines, "\n")

    local biggest = eggs[1]
    if not biggest then
        clearGuide()
        hideBanner()
        setInfo({ egg = false, rarity = false, size = false, zone = false, count = 0, rareCount = 0,
            note = recent and ("Aviso: " .. announcement) or "No hay huevos en el mapa de este servidor (todavía)." })
        setStatus("Escaneo listo: sin huevos", "info")
        return
    end

    local inst = biggest.inst
    local typeName = eggTypeName(inst)
    local rarity = eggRarity(inst)
    local zone = zoneOfEgg(inst)
    setInfo({
        egg = typeName or "huevo del mapa",
        rarity = rarityText(rarity),
        size = biggest.size,
        zone = zone or false,
        count = #eggs,
        rareCount = rareCount,
        note = (#rareEggs > 0 and ("Raros: %d (ver cartel y guías en el mapa)"):format(#rareEggs))
            or (recent and ("Aviso: " .. announcement .. (announcementZone and (" en " .. announcementZone) or "")) or "Resaltado en el mapa: camina hacia el huevo"),
    })
    -- guias en el mapa: una por cada huevo raro (rosa) y el mas grande (amarillo), cada una con su distancia
    clearGuide()
    local used, bannerLines, biggestIsRare = {}, {}, false
    for i, egg in ipairs(rareEggs) do
        if egg.inst == inst then biggestIsRare = true end
        if i > 6 then
            bannerLines[#bannerLines + 1] = ("... y %d raros más"):format(#rareEggs - 6)
            break
        end
        local zone = zoneOfEgg(egg.inst)
        local ann = matchAnnouncement(egg.inst, zone, used)
        local name = (ann and ann.name) or (eggTypeName(egg.inst) and ("Raro " .. eggTypeName(egg.inst))) or "RARO (aura)"
        local where = (ann and ann.zone) or zone or "?"
        local d = distanceTo(egg.inst)
        bannerLines[#bannerLines + 1] = ("%s  |  %.1f studs  |  %s%s"):format(
            name, egg.size, where, d and ("  |  a " .. d .. " studs") or "")
        addGuide(egg.inst, ("%s\n%.1f studs | %s"):format(name, egg.size, where), Color3.fromRGB(236, 72, 153))
    end
    if not biggestIsRare then
        addGuide(inst, ("Huevo más grande: %.1f"):format(biggest.size))
    end
    if #bannerLines > 0 then
        showBanner(table.concat(bannerLines, "\n"), #bannerLines)
    else
        hideBanner()
    end
    setStatus(("Escaneo listo: más grande %.1f"):format(biggest.size), "ok")
end

scanBtn.Activated:Connect(function()
    local ok, err = pcall(scanServer)
    if not ok then
        warn("[@XanScc Server] " .. tostring(err))
        setStatus("No pude escanear este servidor", "info")
    end
end)

copyBtn.Activated:Connect(function()
    if lastReport == "" then
        setStatus("Primero pulsa Escanear servidor", "info")
        return
    end
    local copied = false
    if setclipboard then
        copied = pcall(setclipboard, lastReport)
    end
    if copied then
        setStatus("Datos copiados al portapapeles", "ok")
    else
        warn(lastReport)
        setStatus("Datos en la consola (F9)", "info")
    end
end)

---------------------------------------------------------------------
-- Buscar raros: salta de servidor en servidor hasta uno con un huevo del top 4 (de cualquier tamano)
---------------------------------------------------------------------
-- La lista de servidores se guarda unos minutos para no pedirla a Roblox en cada salto
-- (Roblox bloquea si se piden muchas paginas seguidas).
local function rareListFromCache()
    local c = env.__SH_RPOOL
    local list = {}
    if type(c) == "table" and c.place == placeId and type(c.list) == "table" and os.time() - (c.time or 0) <= 600 then
        for _, server in ipairs(c.list) do
            if normalAccept(server) then
                list[#list + 1] = server
            end
        end
    end
    return list
end

local function huntHop()
    if busy then return false end
    busy = true

    local list = rareListFromCache()
    if #list == 0 then
        setStatus("Buscando servidores...", "busy")
        local ok, found, failed = pcall(collectServers, normalAccept, { "Asc", "Desc" }, RARE_POOL, false, nil)
        if not ok or #found == 0 then
            setStatus(failed and "Roblox va lento, reintento..." or "No hay servidores con ese filtro", "info")
            busy = false
            return false
        end
        shuffle(found)
        env.__SH_RPOOL = { place = placeId, time = os.time(), list = found }
        list = found
    end

    -- toma los primeros y los saca de la lista (ya no se repiten)
    pool = {}
    local used = {}
    for i = 1, math.min(#list, MAX_TELEPORT_TRIES) do
        pool[i] = list[i]
        used[list[i].id] = true
    end
    local c = env.__SH_RPOOL
    if type(c) == "table" and type(c.list) == "table" then
        local keep = {}
        for _, server in ipairs(c.list) do
            if not used[server.id] then keep[#keep + 1] = server end
        end
        c.list = keep
    end
    poolIndex = 1
    triesUsed = 0
    if not teleportNext() then
        setStatus("Teleport falló, reintenta", "info")
        busy = false
        return false
    end
    return true
end

local function refreshRareButton()
    rareBtn.Text = settings.rareHunt and "Parar raros" or "Buscar raros"
end
refreshRareButton()

local skipFirst = false -- el servidor donde estas al encender la busqueda no cuenta: se busca en OTROS

rareBtn.Activated:Connect(function()
    settings.rareHunt = not settings.rareHunt
    if settings.rareHunt then
        -- el modo automatico y la busqueda de raros no pueden saltar los dos a la vez
        if settings.auto then
            settings.auto = false
            refreshSwitch(true)
        end
        skipFirst = true
        setStatus("Buscando huevos raros (Divine, Eternal, Secret, Cosmic)...", "ok")
    else
        setStatus("Búsqueda de raros apagada", "info")
    end
    refreshRareButton()
    saveSettings()
end)

-- Revisa el servidor donde acaba de entrar: aviso del juego o huevo raro del mapa
local function scanForRare()
    local started = os.clock()
    repeat
        if announcementRarity and announcementTime >= started - 15 then
            return announcementRarity, nil
        end
        local word, inst = findRareEgg()
        if word then
            return word, inst
        end
        task.wait(0.5)
    until os.clock() - started >= RARE_SCAN_SECONDS or not settings.rareHunt or not alive()
    return nil
end

local function foundRare(word, inst)
    settings.rareHunt = false
    saveSettings()
    refreshRareButton()

    local label = (word == "raro") and "raro" or capital(word)
    local size = inst and largestDimension(inst) or nil
    local fresh = announcementZone and (os.clock() - announcementTime) < RARE_LIFETIME
    local zone = (fresh and announcementZone) or (inst and zoneOfEgg(inst)) or announcementZone
    setInfo({
        egg = (inst and eggTypeName(inst)) or announcement or "huevo raro",
        rarity = rarityText(word),
        size = size or false,
        zone = zone or false,
        count = false,
        rareCount = false,
        note = "¡Encontrado! Me quedo en este servidor",
    })
    if inst then
        setGuide(inst, "Huevo raro: " .. label)
    end
    local message = "¡Aquí! Huevo " .. label .. (size and (" de " .. ("%.1f"):format(size) .. " studs") or "")
        .. (zone and (" en " .. zone) or "")
    setStatus(message, "ok")
    notify(message)
end

task.spawn(function()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end
    task.wait(AUTO_START_DELAY)

    while alive() do
        local okStep, stepError = pcall(function()
            if settings.rareHunt and not busy then
                if skipFirst then
                    skipFirst = false
                    huntHop()
                    task.wait(AUTO_RETRY_DELAY)
                    return
                end
                setStatus("Buscando huevos raros...", "busy")
                local word, inst = scanForRare()
                if not settings.rareHunt or not alive() then return end
                if word then
                    foundRare(word, inst)
                else
                    huntHop()
                    task.wait(AUTO_RETRY_DELAY)
                end
            else
                task.wait(0.3)
            end
        end)
        if not okStep then
            warn("[@XanScc Server] " .. tostring(stepError))
            task.wait(3)
        end
    end
end)

renderInfo()
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
