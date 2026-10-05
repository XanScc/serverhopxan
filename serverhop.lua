-- @XanScc Server | Server Hop con menu para Xeno (PC) y Delta (iPhone)
-- Pega TODO este archivo y ejecutalo. El menu se vuelve a cargar solo despues de cada salto.

local SRC = [==[
local env = (getgenv and getgenv()) or _G
local SRC = env.__SH_SRC

-- TABLERO COMPARTIDO (opcional). Es la solucion a que desde fuera de un servidor no se puede ver que hay dentro:
-- quien usa el script publica lo que encuentra (tipo de hallazgo, tamano, hora y servidor) y los demas van
-- directo a ese servidor y lo VERIFICAN al llegar. Necesita una base de datos tipo Firebase Realtime Database
-- (ver las instrucciones). Vacio = desactivado: el script no envia ni pide nada. Se puede poner aqui o con
-- getgenv().XANSCC_BOARD = "https://tu-proyecto-default-rtdb.firebaseio.com" antes de ejecutar.
local BOARD_DEFAULT = ""
local BOARD_URL = (tostring(env.XANSCC_BOARD or BOARD_DEFAULT):gsub("/+$", ""))
-- Como activarlo (gratis, unos 5 minutos):
--   1. En console.firebase.google.com crea un proyecto y entra a "Realtime Database" > "Crear base de datos".
--   2. En la pestana "Reglas" pega esto y publica:
--        { "rules": { "findings": { "$place": { ".indexOn": ["t"], ".read": true, ".write": true } } } }
--   3. Copia la direccion de la base (https://...firebaseio.com) y ponla en BOARD_DEFAULT arriba, o ejecuta antes
--      getgenv().XANSCC_BOARD = "esa direccion". Solo se guardan: tipo de hallazgo, tamano, hora y servidor.

-- Al saltar de servidor el menu se vuelve a cargar solo. Para no mandar todo el codigo en cada salto, se guarda en
-- un archivo y se manda un cargador pequeno (si no se puede, se manda todo el codigo como antes).
local LOADER_URL = "https://raw.githubusercontent.com/XanScc/serverhopxan/refs/heads/main/serverhop.lua"
local CACHE_FILE = "XanScc_cache.lua"
local cacheReady = false
if SRC and writefile and readfile and isfile then
    cacheReady = pcall(function()
        if not isfile(CACHE_FILE) or readfile(CACHE_FILE) ~= SRC then
            writefile(CACHE_FILE, SRC)
        end
        assert(readfile(CACHE_FILE) == SRC)
    end)
end

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
-- Si el script se ejecuta dos veces (a mano y recargado por el teletransporte) solo la ultima copia sigue
-- viva: dos copias saltando a la vez duplicarian la carga. La marca va en el jugador, no en el entorno del
-- ejecutor, asi funciona aunque ese entorno no se conserve entre servidores.
local runToken = ("%d_%d"):format(os.time(), math.random(1, 1000000000))
pcall(function()
    player:SetAttribute("XanSccRun", runToken)
end)
local function alive()
    if env.__SH_RUN ~= runId then
        return false
    end
    local ok, current = pcall(function()
        return player:GetAttribute("XanSccRun")
    end)
    return not ok or current == nil or current == runToken
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
    eggMode = "", -- "" = apagado, "rare" = huevos raros (top 4), "big" = huevos grandes (30+), "dim" = dimension
    -- Estado de la busqueda de huevos (se guarda para que sobreviva a cada salto)
    knownRare = "starry fox", -- nombres de huevos raros ya vistos ("|" entre nombres); se aprenden de los avisos
    eggTop = "[]",         -- los 3 mejores servidores vistos: [{job, score, size, rare}], de mejor a peor
    eggVisited = "[]",     -- ids de servidores ya revisados (no se repiten), de mas viejo a mas nuevo
    eggPoolState = "{}",   -- lista de servidores que se arma de a poco entre saltos (ver poolStep)
    lastTeleport = 0,      -- hora (os.time) del ultimo teletransporte: no se salta demasiado seguido
    rateUntil = 0,         -- hasta cuando (os.time) Roblox pidio no hacer peticiones
    eggFresh = false,      -- recien encendido un modo: el servidor donde estas NO cuenta, primero viaja
    dimSeen = "{}",        -- en cuantos servidores estuvo cada objeto tipo portal ({nombre = veces}), para ignorar los permanentes
    dimVisits = 0,         -- servidores revisados para eso
    boardTrust = "",       -- hallazgo del tablero al que se viaja ahora (se verifica al llegar)
    eggSamples = 0,        -- servidores revisados en esta busqueda
    eggReturning = false,  -- true mientras viaja de vuelta al mejor servidor
}

-- Escribir el archivo de ajustes muchas veces por segundo es pesado: saveSettings solo lo marca y se escribe
-- como mucho una vez por segundo. Antes de teletransportarse o cerrar se escribe ya (flushSettings).
local settingsDirty = false

local function flushSettings()
    settingsDirty = false
    if writefile then
        pcall(function()
            writefile(FILE, HttpService:JSONEncode(settings))
        end)
    end
end

local function saveSettings()
    settingsDirty = true
end

task.spawn(function()
    while alive() do
        task.wait(1)
        if settingsDirty then
            flushSettings()
        end
    end
end)

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

-- Un huevo raro dura como maximo hasta el siguiente reinicio (~5 min). Un aviso del servidor no se repite al
-- volver, asi que se acepta como "sigue ahi" solo mientras no pase este tiempo.
local RARE_LIFETIME = 270

-- Espacio libre que se exige en un servidor: si se llena, Roblox rechaza la entrada y ya no se puede volver.
-- Al buscar se piden HUNT_MIN_FREE + 1 lugares libres en la lista; al entrar, HUNT_MIN_FREE contandote a ti.
local HUNT_MIN_FREE = 3

-- Modo "huevos grandes": solo cuenta un huevo de GIANT_MIN studs o mas (entre los que lo tienen, el mas grande).
local GIANT_MIN = 40.0

local function resetHunt()
    settings.eggTop, settings.eggSamples, settings.eggReturning = "[]", 0, false
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
        giant = flags and flags.giant or false,
        via = flags and flags.via or "",   -- "map" (se puede volver a comprobar) o "announce" (aviso del servidor)
        t = flags and flags.t or os.time() })
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

-- Quita un servidor de la lista (el huevo ya no estaba al llegar)
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

local MAX_PAGES = 250           -- tope de paginas por lista (100 servidores cada una = hasta 25000 servidores)
local PAGE_DELAY = 0.05        -- pausa minima entre paginas
local SEARCH_TIMEOUT = 25        -- segundos maximos buscando servidores (salto normal)
local HUNT_PAGES_TOTAL = 300     -- paginas que cubre la lista de candidatos (150 desde cada extremo de la lista de Roblox)
local STEP_LIGHT = 4             -- paginas que pide en cada salto para ir completando esa lista
local STEP_HEAVY = 8             -- paginas que pide en un salto si faltan candidatos
local MIN_HOP_GAP = 10           -- segundos minimos entre un teletransporte y el siguiente (saltar mas rapido satura el juego)
local POOL_MAX = 400            -- servidores que se guardan de esa lista (al azar, de TODAS las paginas)
local POOL_TTL = 1200           -- segundos que vale la lista antes de empezar otra (los servidores cambian)
local POOL_MIN = 8              -- si quedan menos servidores sin visitar que esto, arma la lista de nuevo
local HUNT_PICKS = 12           -- a cuantos servidores de la lista intenta entrar en cada salto
local DIM_WARMUP = 5            -- servidores que revisa antes de fiarse de la deteccion de la dimension
local DIM_PERMANENT = 0.8       -- un objeto que esta en esta fraccion de los servidores se considera permanente
local MAX_FAILS_IN_A_ROW = 10 -- paginas seguidas fallidas antes de abandonar esa busqueda
local RANDOM_POOL = 30          -- en modo aleatorio junta hasta tantos servidores validos antes de elegir
local EMPTY_POOL = 15           -- servidores casi vacios que junta el boton "Server privado"
local EMPTY_MAX_PLAYERS = 1     -- "Server privado" busca servidores con 0 o 1 jugador
local MAX_TELEPORT_TRIES = 6    -- cuantos servidores distintos prueba si uno esta lleno o cerrado
local AUTO_START_DELAY = 2      -- segundos tras entrar a un servidor antes de volver a saltar (modo auto)
local AUTO_RETRY_DELAY = 3      -- espera tras un intento fallido en modo auto
local EGG_SCAN_SECONDS = 3     -- segundos que escanea los huevos de cada servidor (cargan poco a poco)
local EGG_SAMPLE_SERVERS = 8   -- servidores que revisa antes de volver al que tenia el huevo mas grande
local REQUEST_GAP_MIN = 1.2    -- segundos minimos entre peticiones a la lista de servidores (Roblox limita si se pide mas rapido)
local RATE_GIVEUP = 45          -- segundos seguidos con el limite de Roblox antes de dejar de insistir y avisar
local FLOOD_COOLDOWN = 10      -- espera si Roblox avisa que se esta saltando demasiado rapido
local CROWD_CHECK_PAGES = 2    -- paginas de servidores (las mas llenas) que revisa antes de volver a uno guardado

-- Se reemplaza mas abajo, cuando existe el menu, para avisar "Reintentando..."
local notifyRetry = function() end

---------------------------------------------------------------------
-- Busqueda de servidores
---------------------------------------------------------------------
-- Una peticion GET. Devuelve (cuerpo, codigo de estado, segundos de espera que pide Roblox).
-- Usa la funcion request del ejecutor (da el codigo de estado, asi se distingue el limite de peticiones
-- 429 de un error de red) y, si no existe, game:HttpGet.
local function httpRequest(url)
    local req = request or http_request or (syn and syn.request) or (http and http.request)
    if req then
        local ok, res = pcall(req, { Url = url, Method = "GET" })
        if ok and type(res) == "table" and res.StatusCode then
            local retryAfter
            if type(res.Headers) == "table" then
                retryAfter = tonumber(res.Headers["retry-after"] or res.Headers["Retry-After"])
            end
            return res.Body, res.StatusCode, retryAfter
        end
    end

    local ok, result = pcall(function()
        return game:HttpGet(url)
    end)
    if ok and result then
        return result, 200
    end
    if tostring(result):find("429", 1, true) then
        return nil, 429
    end
    return nil, 0
end

-- Segundos que Roblox pidio esperar (se recuerda entre saltos). Si la hora del sistema cambio y el valor guardado
-- quedo en el futuro lejano, se descarta.
local function persistedRateWait()
    local untilTime = settings.rateUntil or 0
    local now = os.time()
    if untilTime > now + 60 then
        settings.rateUntil = 0
        return 0
    end
    return math.max(0, untilTime - now)
end

-- Ritmo de peticiones: todas las listas comparten el mismo turno, para no saturar a Roblox (si se pide
-- demasiado rapido responde 429). Si aun asi limita, el ritmo se hace mas lento y despues se recupera.
local requestGap = REQUEST_GAP_MIN
local lastRequest = 0
local rateLimitUntil = 0

-- Pide UNA pagina de servidores. Devuelve la pagina, o (nil, "rate") si Roblox limito las peticiones,
-- o (nil, "net") si hubo un error de red / de Roblox.
local function fetchPage(sortOrder, cursor)
    local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=%s&limit=100&excludeFullGames=true"):format(placeId, sortOrder)
    if cursor then
        url = url .. "&cursor=" .. cursor
    end

    -- si Roblox pidio esperar en un salto anterior, se respeta (el script se reinicia en cada servidor)
    local persisted = persistedRateWait()
    if persisted > 0 then
        rateLimitUntil = math.max(rateLimitUntil, os.clock() + math.min(persisted, 20))
    end

    -- espera su turno (se reserva antes de esperar, asi la otra lista toma el turno siguiente)
    local now = os.clock()
    local at = math.max(lastRequest + requestGap, rateLimitUntil, now)
    lastRequest = at
    if at > now then
        task.wait(at - now)
    end

    local body, status, retryAfter = httpRequest(url)
    if status == 429 then
        requestGap = math.min(requestGap * 1.5, 8)
        local wait = math.max(retryAfter or 0, 5)
        rateLimitUntil = os.clock() + wait
        settings.rateUntil = os.time() + math.ceil(wait)
        return nil, "rate"
    end
    if status ~= 200 or not body then
        return nil, "net"
    end

    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(body)
    end)
    if ok and type(decoded) == "table" and type(decoded.data) == "table" then
        requestGap = math.max(REQUEST_GAP_MIN, requestGap * 0.9)
        return decoded
    end
    return nil, "net"
end

-- Recorre paginas juntando servidores que cumplan `accept`. No se rinde: sigue pasando de pagina
-- hasta juntar suficientes, llegar al final de la lista o agotar el tiempo.
--   orders:   lista de ordenes a recorrer AL MISMO TIEMPO (ej. {"Asc","Desc"} = empieza por los dos extremos)
--   target:   deja de buscar al juntar tantos servidores validos
--   firstHit: si es true, se detiene en la primera pagina que tenga resultados
--             (la lista viene ordenada, asi que lo mejor esta al principio)
-- Si Roblox limita las peticiones espera y sigue (no cuenta como fallo); solo se rinde ante errores de red.
-- Devuelve (lista, fallo, limitado): `fallo` es true si no junto nada por culpa de errores / del limite,
-- y `limitado` si Roblox llego a limitar las peticiones.
local function collectServers(accept, orders, target, firstHit, onProgress, timeout, maxPages)
    local found, seen = {}, {}
    local deadline = os.clock() + (timeout or SEARCH_TIMEOUT)
    local finished, pagesDone = 0, 0
    local stop, hadError, hadRate = false, false, false

    local function chain(sortOrder)
        local cursor
        local pages, fails = 0, 0
        local lastGood = os.clock()
        while pages < (maxPages or MAX_PAGES) and not stop and os.clock() < deadline do
            local page, reason = fetchPage(sortOrder, cursor)
            if stop then break end

            if page then
                fails = 0
                lastGood = os.clock()
                pages = pages + 1
                pagesDone = pagesDone + 1
                if onProgress then onProgress(pagesDone) end

                for _, server in ipairs(page.data) do
                    if not seen[server.id] and accept(server) then
                        seen[server.id] = true
                        -- solo lo necesario (miles de servidores ocuparian mucha memoria)
                        table.insert(found, { id = server.id, playing = server.playing, maxPlayers = server.maxPlayers })
                    end
                end

                if #found >= target or (firstHit and #found > 0) then
                    stop = true
                    break
                end

                cursor = page.nextPageCursor
                if not cursor then break end -- ya no hay mas paginas
                task.wait(PAGE_DELAY)
            elseif reason == "rate" then
                -- fetchPage ya fijo la espera; la proxima peticion (de cualquier lista) la respeta
                hadRate = true
                if os.clock() - lastGood > RATE_GIVEUP then break end
                notifyRetry("rate")
            else
                fails = fails + 1
                hadError = true
                if fails >= MAX_FAILS_IN_A_ROW then break end
                notifyRetry("net")
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

    return found, (hadError or hadRate) and #found == 0, hadRate
end

-- Antes de volver a un servidor guardado: mira los servidores mas llenos de la lista (salen primero en el
-- orden "Desc") y descarta los candidatos que ya estan casi llenos. Asi no se intenta entrar a uno que
-- Roblox va a rechazar y que mandaria a otro servidor sin huevo.
local function stillRoomy(list)
    if persistedRateWait() > 0 then
        return list -- Roblox esta limitando las peticiones: no se insiste, se confia en lo guardado
    end
    local crowded = {}
    local cursor
    for _ = 1, CROWD_CHECK_PAGES do
        local page = fetchPage("Desc", cursor)
        if not page then break end
        for _, server in ipairs(page.data) do
            if server.playing and server.maxPlayers and server.maxPlayers - server.playing < HUNT_MIN_FREE + 1 then
                crowded[server.id] = true
            end
        end
        cursor = page.nextPageCursor
        if not cursor then break end
    end

    local reachable = {}
    for _, candidate in ipairs(list) do
        if not crowded[candidate.job] then
            table.insert(reachable, candidate)
        end
    end
    return reachable
end

local function baseAccept(server)
    return server.id ~= currentJobId
        and server.playing ~= nil
        and server.maxPlayers ~= nil
        and server.playing < server.maxPlayers
end

local function normalAccept(server)
    if not baseAccept(server) then return false end
    -- Buscando huevos: solo servidores con espacio de sobra (al entrar tu y mientras vuelves se llenan)
    if huntOn() and server.maxPlayers - server.playing < HUNT_MIN_FREE + 1 then return false end
    -- Buscando huevos: no repite servidores que ya reviso
    if huntOn() and huntVisited[server.id] then return false end
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

local bigRow = modeRow(("Huevos grandes (%.0f+)"):format(GIANT_MIN), -134)
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

notifyRetry = function(kind)
    if kind == "rate" then
        setStatus("Roblox limitó las peticiones; espero y sigo...", "busy")
    else
        setStatus("Roblox va lento, sigo buscando...", "busy")
    end
end

-- Credito abajo, tambien en arcoiris
local footer = make("TextLabel", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1,
    Text = "by @XanScc | v18",
    TextColor3 = C.white,
    Font = Enum.Font.GothamBold,
    TextSize = 12,
}, section(16))
rainbow(footer)

-- Anima el arcoiris (se detiene solo cuando el menu se cierra o se recarga)
do
    local STEPS = 8
    local conn
    local acc = 0
    conn = RunService.Heartbeat:Connect(function(dt)
        if not alive() then
            conn:Disconnect()
            return
        end
        acc = acc + (dt or 0.016)
        if acc < 0.07 then return end
        acc = 0
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
local lastTarget            -- ultimo servidor al que se intento entrar
local teleportCooldownUntil = 0 -- si Roblox dice que se salta muy rapido, no se salta antes de esta hora

-- Intenta entrar al siguiente candidato de la lista. Devuelve true si el teleport arranco.
local function teleportNext()
    while poolIndex <= #pool and triesUsed < MAX_TELEPORT_TRIES do
        local target = pool[poolIndex]
        poolIndex = poolIndex + 1
        triesUsed = triesUsed + 1
        lastTarget = target
        if huntOn() then
            markVisited(target.id)
            settings.boardTrust = target.board and HttpService:JSONEncode({
                job = target.id, kind = settings.eggMode, size = target.board.size,
                rare = target.board.rare, t = target.board.t }) or ""
            saveSettings()
        end

        -- Hace que el menu se cargue de nuevo en el servidor nuevo. Si se pudo guardar el codigo en un archivo,
        -- solo se manda un cargador pequeno (mandar los ~90 KB completos en cada salto cargaba mucho el juego).
        if not queued and queue_on_teleport and SRC then
            queued = true
            local loader
            if cacheReady then
                loader = string.format(
                    "local e=(getgenv and getgenv()) or _G; e.XANSCC_BOARD=%q; "
                    .. "local ok,src=pcall(readfile,%q); "
                    .. "if ok and type(src)=='string' and #src>5000 then e.__SH_SRC=src; loadstring(src)() "
                    .. "else local ok2,full=pcall(game.HttpGet,game,%q); "
                    .. "if ok2 and type(full)=='string' then loadstring(full)() end end",
                    BOARD_URL, CACHE_FILE, LOADER_URL)
            else
                loader = string.format(
                    "local e=(getgenv and getgenv()) or _G; e.XANSCC_BOARD=%q; e.__SH_SRC=%q; loadstring(e.__SH_SRC)()",
                    BOARD_URL, SRC)
            end
            pcall(queue_on_teleport, loader)
        end

        if target.label then
            setStatus(target.label, "info")
        elseif statusSuffix ~= "" then
            setStatus("Teletransportando...", "info")
        else
            setStatus(("Teletransportando... (%d/%d jugadores)"):format(target.playing, target.maxPlayers), "info")
        end
        -- guarda todo en el disco ANTES de salir (lo demas se guarda de a poco)
        settings.lastTeleport = os.time()
        flushSettings()
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

local function resultIs(result, name)
    local ok, value = pcall(function()
        return Enum.TeleportResult[name]
    end)
    return ok and result == value
end

-- Espera antes de saltar: si Roblox dijo que se salta muy rapido, y siempre un minimo entre un salto y el siguiente
-- (teletransportarse cada pocos segundos satura el cliente y puede cerrarlo). El plazo se fija una vez, con
-- os.clock, asi que no puede quedarse esperando para siempre aunque cambie la hora del sistema.
local function waitTeleportCooldown()
    local gapWait = math.max(0, math.min((settings.lastTeleport or 0) + MIN_HOP_GAP - os.time(), MIN_HOP_GAP))
    local untilClock = math.max(teleportCooldownUntil, os.clock() + gapWait)
    while alive() and os.clock() < untilClock do
        setStatus(("Espero %ds para no saltar demasiado rápido..."):format(math.ceil(untilClock - os.clock())), "busy")
        task.wait(0.5)
    end
end

-- Si el servidor elegido se lleno o cerro, prueba automaticamente con el siguiente
TeleportService.TeleportInitFailed:Connect(function(_, result, message)
    if not alive() or not busy then return end

    -- un servidor lleno o cerrado no se vuelve a intentar pronto
    if lastTarget and lastTarget.id then
        markVisited(lastTarget.id)
        saveSettings()
    end

    if resultIs(result, "Flooded") then
        -- esto si lo provoca el script (saltos muy seguidos): espera y sigue
        teleportCooldownUntil = os.clock() + FLOOD_COOLDOWN
        setStatus("Muchos saltos seguidos; espero unos segundos...", "busy")
        task.wait(FLOOD_COOLDOWN)
    elseif resultIs(result, "GameFull") then
        setStatus("Servidor lleno, probando otro...", "busy")
    elseif resultIs(result, "GameEnded") or resultIs(result, "GameNotFound") then
        setStatus("Servidor cerrado, probando otro...", "busy")
    else
        setStatus("No pude entrar, probando otro...", "busy")
    end

    if not teleportNext() then
        setStatus("Ningún servidor aceptó, reintento...", "busy")
        busy = false
    end
end)

-- Lista de servidores para buscar huevos / dimension. Se arma DE A POCO: en cada salto pide unas pocas paginas
-- (STEP_LIGHT, o STEP_HEAVY si faltan candidatos), siguiendo donde se quedo la vez anterior, hasta cubrir
-- HUNT_PAGES_TOTAL paginas (mas de 200) repartidas entre los dos extremos de la lista de Roblox. Pedir 300
-- paginas de golpe hacia que Roblox limitara las peticiones y cargaba mucho el juego. Se guardan hasta
-- POOL_MAX servidores al azar de todas esas paginas; la lista vale POOL_TTL segundos y despues empieza otra.
local function newPoolState()
    return { pool = {}, seen = 0, ca = "", cd = "", pages = 0, doneA = false, doneD = false, nextOrder = 1, t = os.time() }
end

local function loadPoolState()
    local ok, st = pcall(function()
        return HttpService:JSONDecode(settings.eggPoolState)
    end)
    if not ok or type(st) ~= "table" or type(st.pool) ~= "table" then
        return newPoolState()
    end
    for key, value in pairs(newPoolState()) do
        if st[key] == nil then
            st[key] = value
        end
    end
    local age = os.time() - (tonumber(st.t) or 0)
    if age > POOL_TTL or age < -60 then
        return newPoolState() -- vencida (o con hora imposible): empieza otra
    end
    return st
end

local function savePoolState(st)
    settings.eggPoolState = HttpService:JSONEncode(st)
    saveSettings()
end

-- Servidores de la lista que aun no se han visitado
local function freshFromPool(st, visited)
    local out = {}
    for _, entry in ipairs(st.pool) do
        if entry.id ~= currentJobId and not visited[entry.id] then
            table.insert(out, { id = entry.id, playing = entry.p, maxPlayers = entry.m })
        end
    end
    return out
end

-- Agrega un servidor a la lista; si ya esta llena, reemplaza uno al azar (asi quedan repartidos entre todas las paginas)
local function poolAdd(st, server)
    st.seen = st.seen + 1
    local entry = { id = server.id, p = server.playing, m = server.maxPlayers }
    if #st.pool < POOL_MAX then
        table.insert(st.pool, entry)
    else
        local j = math.random(1, st.seen)
        if j <= POOL_MAX then
            st.pool[j] = entry
        end
    end
end

-- Pide hasta `maxPages` paginas siguiendo donde se quedo. Devuelve (limitado, error de red).
-- Si Roblox esta limitando las peticiones no espera ni insiste: el salto sigue con lo que ya hay.
local function poolStep(st, maxPages)
    if persistedRateWait() > 0 then
        return true, false
    end

    local have = {}
    for _, entry in ipairs(st.pool) do
        have[entry.id] = true
    end

    local fetched = 0
    while fetched < maxPages do
        if st.doneA and st.doneD then break end

        -- alterna entre los dos extremos de la lista
        local useAsc = (st.nextOrder == 1 and not st.doneA) or st.doneD
        local order = useAsc and "Asc" or "Desc"
        local cursorKey = useAsc and "ca" or "cd"
        local doneKey = useAsc and "doneA" or "doneD"
        st.nextOrder = useAsc and 2 or 1

        local cursor = st[cursorKey] ~= "" and st[cursorKey] or nil
        local page, reason = fetchPage(order, cursor)
        if page then
            fetched = fetched + 1
            st.pages = st.pages + 1
            for _, server in ipairs(page.data) do
                if not have[server.id] and normalAccept(server) then
                    have[server.id] = true
                    poolAdd(st, server)
                end
            end
            st[cursorKey] = page.nextPageCursor or ""
            if not page.nextPageCursor then
                st[doneKey] = true
            end
            setStatus(("Actualizando la lista de servidores... (%d/%d páginas)"):format(st.pages, HUNT_PAGES_TOTAL), "busy")
        elseif reason == "rate" then
            return true, false
        else
            if cursor then
                st[cursorKey] = "" -- si el cursor guardado ya no sirve, esa lista empieza de nuevo
            end
            return false, true
        end
    end
    return false, false
end

-- Servidores a los que saltar. Devuelve (lista, fallo, limitado, sinNuevos). `sinNuevos` es true si ya se
-- recorrieron todas las paginas y no hay un solo servidor valido: "ni modo", la busqueda se detiene.
local function huntCandidates()
    local visited = loadVisited()
    huntVisited = visited

    local st = loadPoolState()
    local fresh = freshFromPool(st, visited)

    local failed, rateLimited = false, false
    local needMore = #fresh < POOL_MIN
    if needMore or st.pages < HUNT_PAGES_TOTAL then
        local rate, net = poolStep(st, needMore and STEP_HEAVY or STEP_LIGHT)
        rateLimited = rate
        failed = rate or net
        savePoolState(st)
        fresh = freshFromPool(st, visited)
    end

    if #fresh == 0 and next(visited) ~= nil then
        -- ya visito todo lo que tiene la lista: olvida lo visitado y vuelve a empezar con ella
        clearVisited()
        saveSettings()
        visited = {}
        huntVisited = visited
        fresh = freshFromPool(st, visited)
    end

    if #fresh == 0 then
        if not failed and (st.pages >= HUNT_PAGES_TOTAL or (st.doneA and st.doneD)) then
            return {}, false, false, true -- ni modo
        end
        return {}, failed, rateLimited, false
    end

    shuffle(fresh)
    local picks = {}
    for i = 1, math.min(#fresh, HUNT_PICKS) do
        picks[i] = fresh[i]
    end
    return picks, false, rateLimited, false
end

---------------------------------------------------------------------
-- Tablero compartido (opcional, ver BOARD_URL)
---------------------------------------------------------------------
local BOARD_MAX_AGE = { rare = 270, big = 270, dim = 600 } -- segundos que vale un hallazgo de cada tipo
local BOARD_POST_GAP = 60  -- no publica el mismo hallazgo de este servidor mas de una vez por minuto
local boardPosted = {}
local boardCache = { kind = "", at = -1e9, list = {} }

local function boardEnabled()
    return BOARD_URL ~= ""
end

-- Peticion al tablero. Devuelve el cuerpo si salio bien, o nil.
local function boardRequest(method, path, body)
    local req = request or http_request or (syn and syn.request) or (http and http.request)
    if not req then return nil end
    local ok, res = pcall(req, {
        Url = BOARD_URL .. path,
        Method = method,
        Headers = { ["Content-Type"] = "application/json" },
        Body = body,
    })
    if ok and type(res) == "table" and type(res.StatusCode) == "number" and res.StatusCode >= 200 and res.StatusCode < 300 then
        return res.Body or ""
    end
    return nil
end

-- Publica un hallazgo de este servidor para que otros lo usen. kind: "rare" | "big" | "dim".
local function boardPost(kind, size, rareWord)
    if not boardEnabled() then return end
    local key = kind .. "_" .. game.JobId
    if os.clock() - (boardPosted[key] or -1e9) < BOARD_POST_GAP then return end
    boardPosted[key] = os.clock()

    local entry = HttpService:JSONEncode({
        t = os.time(), kind = kind, size = size or 0, rare = rareWord or "",
        p = #Players:GetPlayers(), m = Players.MaxPlayers, -- ocupacion al publicar
    })
    task.spawn(function()
        boardRequest("PUT", ("/findings/%d/%s.json"):format(placeId, key), entry)
    end)
end

-- Quita un hallazgo que al llegar ya no estaba (para que nadie mas viaje por gusto)
local function boardDelete(kind, job)
    if not boardEnabled() then return end
    task.spawn(function()
        boardRequest("DELETE", ("/findings/%d/%s_%s.json"):format(placeId, kind, job))
    end)
end

-- Hallazgos recientes de ese tipo, el mejor primero (huevo mas grande; la dimension: la mas reciente).
-- Todo lo que viene del tablero es dato de terceros: se valida y, de todos modos, se verifica al llegar.
local function boardFetch(kind)
    if not boardEnabled() then return {} end
    if boardCache.kind == kind and os.clock() - boardCache.at < 8 then
        return boardCache.list
    end

    local maxAge = BOARD_MAX_AGE[kind] or 270
    local now = os.time()
    local body = boardRequest("GET", ("/findings/%d.json?orderBy=%%22t%%22&startAt=%d"):format(placeId, now - maxAge))
    if not body then
        body = boardRequest("GET", ("/findings/%d.json"):format(placeId)) -- por si la base no tiene indice en "t"
    end

    local list = {}
    if body and body ~= "" and body ~= "null" then
        local ok, data = pcall(function()
            return HttpService:JSONDecode(body)
        end)
        if ok and type(data) == "table" then
            for key, e in pairs(data) do
                if type(key) == "string" and type(e) == "table" and e.kind == kind
                    and type(e.t) == "number" and now - e.t <= maxAge and now - e.t >= -120 then
                    local job = key:match("^%a+_([%x%-]+)$")
                    local roomy = type(e.p) ~= "number" or type(e.m) ~= "number" or e.m - e.p >= HUNT_MIN_FREE + 1
                    if job and #job <= 40 and job ~= currentJobId and not huntVisited[job] and roomy then
                        table.insert(list, {
                            job = job, size = tonumber(e.size) or 0,
                            rare = tostring(e.rare or ""):gsub("[^%a]", ""):sub(1, 12), t = e.t,
                        })
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if kind == "dim" then return a.t > b.t end
        return a.size > b.size
    end)

    boardCache = { kind = kind, at = os.clock(), list = list }
    return list
end

-- Si el salto actual lo recomendo el tablero para ESTE servidor, devuelve ese hallazgo (y lo borra de los ajustes)
local function takeBoardTrust()
    local raw = settings.boardTrust
    settings.boardTrust = ""
    if raw == "" then return nil end
    local ok, e = pcall(function()
        return HttpService:JSONDecode(raw)
    end)
    if ok and type(e) == "table" and e.job == game.JobId then
        e.rare = e.rare or ""
        e.t = tonumber(e.t) or 0
        e.size = tonumber(e.size) or 0
        return e
    end
    return nil
end

-- mode: nil = salto normal (con filtros del menu), "empty" = servidor casi vacio
local function hop(mode)
    if busy then return false end
    busy = true
    waitTeleportCooldown()

    local ok, list, failed, rateLimited
    local ordered = false -- true si la lista ya viene en orden de preferencia (tablero): no se desordena
    if mode == "empty" then
        setStatus("Buscando server vacío...", "busy")
        ok, list, failed, rateLimited = pcall(collectServers, emptyAccept, { "Asc" }, EMPTY_POOL, true, function(page)
            setStatus(("Buscando server vacío... (página %d)"):format(page), "busy")
        end)
    else
        if huntOn() then
            -- Tablero compartido: si otra persona ya vio lo que buscas, va directo a ese servidor
            local fromBoard = {}
            if boardEnabled() then
                huntVisited = loadVisited()
                for i, e in ipairs(boardFetch(settings.eggMode)) do
                    if i > 3 then break end
                    table.insert(fromBoard, { id = e.job, playing = 0, maxPlayers = 0, board = e,
                        label = "Voy a un servidor que otra persona ya vio..." })
                end
            end

            local noNew
            if #fromBoard > 0 then
                ok, list, failed, rateLimited = true, fromBoard, false, false
                ordered = true
            else
                -- Buscando huevos / dimension: elige entre la lista grande armada con 300 paginas
                ok, list, failed, rateLimited, noNew = pcall(huntCandidates)
            end
            if ok and noNew then
                -- ni modo: no hay servidores validos ni en 300 paginas nuevas
                settings.eggMode = ""
                settings.eggFresh = false
                resetHunt()
                refreshRare(true)
                refreshBig(true)
                refreshDim(true)
                saveSettings()
                statusSuffix = ""
                setStatus("No encontré servidores nuevos en 300 páginas; búsqueda detenida", "error")
                busy = false
                return false
            end
        else
            local isRandom = settings.sort == "Random"
            local orders = isRandom and { "Asc", "Desc" } or { (settings.sort == "Most") and "Desc" or "Asc" }
            setStatus("Buscando servidores...", "busy")
            ok, list, failed, rateLimited = pcall(collectServers, normalAccept, orders,
                isRandom and RANDOM_POOL or 15, not isRandom, function(page)
                    if page > 1 then
                        setStatus(("Buscando servidores... (página %d)"):format(page), "busy")
                    end
                end)
        end
    end

    if not ok then
        -- error del propio script: se avisa y el detalle va a la consola
        warn("[@XanScc Server] error al buscar servidores: " .. tostring(list))
        setStatus("Error al buscar servidores", "error")
        busy = false
        return false
    end
    if #list == 0 then
        if failed and rateLimited then
            -- Roblox limito las peticiones: es temporal, el script espera solo y reintenta
            setStatus("Roblox limitó las peticiones; espero y reintento", "busy")
        elseif failed then
            setStatus("Sin respuesta de Roblox (red o servidor), reintento", "error")
        elseif mode == "empty" then
            setStatus("No hay servers con 0-1 jugadores ahora", "error")
        elseif huntOn() then
            setStatus("No hay servidores con espacio ahora; reintento", "busy")
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
    elseif not ordered and (settings.sort == "Random" or huntOn()) then
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
    waitTeleportCooldown()
    pool = {}
    for _, candidate in ipairs(candidates) do
        table.insert(pool, { id = candidate.job, label = label })
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
    -- Cada vez que cambia el modo empieza una busqueda nueva
    resetHunt()
    settings.eggFresh = settings.eggMode ~= "" -- recien encendido: primero viaja a otros servidores
    statusSuffix = ""
    refreshRare(true)
    refreshBig(true)
    refreshDim(true)
    saveSettings()
    if settings.eggMode == "rare" then
        setStatus("Solo huevos raros (Divine, Eternal, Secret, Cosmic): voy al servidor del más grande", "ok")
    elseif settings.eggMode == "big" then
        setStatus(("Solo huevos de %.0f+: voy al servidor del más grande"):format(GIANT_MIN), "ok")
    elseif settings.eggMode == "dim" then
        setStatus("Buscando un servidor con la dimensión (Dr. Scramble) abierta", "ok")
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
    flushSettings()
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

-- Una sola pasada por el mapa (es lo mas pesado del script: se hace una vez por servidor y solo para lo que se busca).
--   scanMap(true,  false) = solo huevos enormes     scanMap(false, true) = solo la dimension     scanMap() = las dos
-- Devuelve (huevo mas grande >= GIANT_MIN fuera de la biblioteca de modelos, nombre del primer objeto tipo portal
-- o nil, huevo enorme, todos los objetos tipo portal {clave = nombre}).
-- Los objetos tipo portal se reconocen por el nombre (scramble / rift / dimension / portal) y se descartan
-- maquinas, tiendas y carteles. Pero ese nombre tambien lo llevan objetos que existen SIEMPRE (puertas de
-- zona, carteles...): por eso judgeDimension aprende cuales son permanentes y los ignora.
local DIM_WORDS = { "scramble", "rift", "dimension", "portal" }
local DIM_SKIP = { "machine", "shop", "button", "index", "token", "banner", "sign", "egg", "teleportpad", "spawn" }

-- "DrScramblePortal_123" -> "drscrambleportal": letras solamente, para comparar entre servidores
local function normalizeDimName(name)
    return (name:lower():gsub("[%d%p%s]+", "")):sub(1, 40)
end

local function scanMap(wantGiant, wantDim)
    if wantGiant == nil and wantDim == nil then
        wantGiant, wantDim = true, true
    end

    local giant, giantInst, dimension = 0, nil, nil
    local dimNames = {}
    local character = player.Character
    local assets = workspace:FindFirstChild("ClientRenderedAssets")

    local count = 0
    for _, inst in ipairs(workspace:GetDescendants()) do
        count = count + 1
        if count % 2000 == 0 then
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

            if wantDim and not (character and inst:IsDescendantOf(character)) then
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
                            local key = normalizeDimName(inst.Name)
                            if key ~= "" and not dimNames[key] then
                                dimNames[key] = inst.Name:sub(1, 30)
                            end
                            dimension = dimension or inst.Name:sub(1, 30)
                        end
                        break
                    end
                end
            end
        end
    end
    return giant, dimension, giantInst, dimNames
end

local function loadDimSeen()
    local ok, seen = pcall(function()
        return HttpService:JSONDecode(settings.dimSeen)
    end)
    return (ok and type(seen) == "table") and seen or {}
end

-- Decide si en este servidor hay una dimension ABIERTA. Un objeto tipo portal que esta en casi todos los
-- servidores (>= DIM_PERMANENT) es permanente (una puerta, un cartel) y no cuenta; solo cuenta uno que
-- aparece de vez en cuando. Los primeros DIM_WARMUP servidores solo sirven para aprender.
-- Devuelve (nombre de la dimension abierta o nil, si ya aprendio lo suficiente).
local function judgeDimension(dimNames)
    local seen = loadDimSeen()
    local visits = settings.dimVisits
    local learned = visits >= DIM_WARMUP

    local open
    if learned then
        for key, raw in pairs(dimNames) do
            if (seen[key] or 0) / visits < DIM_PERMANENT then
                open = open or raw
            end
        end
    end

    -- registra este servidor
    for key in pairs(dimNames) do
        seen[key] = (seen[key] or 0) + 1
    end
    visits = visits + 1
    if visits > 200 then -- olvida lo viejo poco a poco
        for key, n in pairs(seen) do
            seen[key] = math.floor(n / 2)
        end
        visits = math.floor(visits / 2)
    end
    settings.dimSeen = HttpService:JSONEncode(seen)
    settings.dimVisits = visits

    return open, learned
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
    if type(text) ~= "string" or text == "" or #text > 300 then return end
    -- filtro barato: casi todos los textos de la pantalla no dicen "spawned" y se descartan aqui
    if not (text:find("spawned", 1, true) or text:find("Spawned", 1, true)) then return end
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

        -- Comparte el aviso: cualquiera que use el script puede ir a este servidor (verificandolo al llegar)
        local rarityNow = announcementRarity
        if rarityNow and boardEnabled() then
            task.delay(4, function() -- da tiempo a que el huevo aparezca en el mapa para medirlo
                if alive() then
                    boardPost("rare", (scanForEggs()), rarityNow)
                end
            end)
        end
    end
end

-- Se queda en este servidor (avisando) hasta que apagues la busqueda de huevos.
-- En modo "raros", si mientras tanto llega un aviso de huevo raro, lo muestra.
local function holdHere(message)
    statusSuffix = ""
    setStatus(message, "ok")
    notify(message)

    local seen = announcementTime
    while alive() and huntOn() do
        if settings.eggMode == "rare" and announcementRarity and announcementTime > seen then
            seen = announcementTime
            local text = "¡Huevo raro! " .. tostring(announcement)
            setStatus(text, "ok")
            notify(text)
        end
        task.wait(0.5)
    end
end

-- "Encontrado: huevo Secret (12.3)" (modo raros) / "Encontrado: huevo más grande (12.3)" (grandes)
local function foundMessage(mode, rareWord, size, giant)
    if rareWord and rareWord ~= "" then
        local label = rareWord:sub(1, 1):upper() .. rareWord:sub(2)
        return ("Encontrado: huevo %s (%.1f)"):format(label, size)
    end
    if giant then
        return ("Encontrado: huevo gigante (%.1f)"):format(size)
    end
    return ("Encontrado: huevo (%.1f)"):format(size)
end

task.spawn(function()
    pcall(function()
        game:GetService("TextChatService").MessageReceived:Connect(function(message)
            checkAnnouncement(message.Text)
        end)
    end)

    local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
    if not playerGui then return end

    -- Un aviso nuevo aparece como un texto NUEVO en la pantalla: solo se vigilan los que aparecen despues. Antes se
    -- conectaba a todos los que ya habia (cientos o miles, en cada salto), lo que cargaba y podia cerrar el juego.
    local function watch(label)
        local text = label.Text
        checkAnnouncement(text)
        if text == "" then
            -- nace vacio: puede recibir el texto despues (el caso de un aviso nuevo)
            label:GetPropertyChangedSignal("Text"):Connect(function()
                checkAnnouncement(label.Text)
            end)
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
task.spawn(function()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end
    task.wait(AUTO_START_DELAY)

    while alive() do
        if huntOn() and not busy then
            local mode = settings.eggMode
            -- Recien encendido: el servidor donde estas NO cuenta; primero viaja a otros
            local freshStart = settings.eggFresh
            settings.eggFresh = false
            statusSuffix = ""
            setStatus(
                (mode == "rare" and "Buscando huevos raros...")
                    or (mode == "dim" and "Buscando la dimensión...")
                    or "Buscando huevos grandes...",
                "busy")

            -- Escanea unos segundos (el mapa carga poco a poco) y se queda con lo mejor visto
            local biggest, checked = 0, 0
            local rareWord, rareInst
            local rareViaMap = false -- true si la rareza se leyo del mapa (se puede volver a comprobar)
            local dimNames = {}
            local started = os.clock()
            if freshStart then
                started = started - EGG_SCAN_SECONDS -- no se detiene a escanear: una sola pasada
            end
            repeat
                if mode == "dim" then
                    local _, _, _, names = scanMap(false, true)
                    for key, raw in pairs(names) do
                        dimNames[key] = raw
                    end
                    task.wait(1.5)
                else
                    local size, count = scanForEggs()
                    if size > biggest then biggest = size end
                    if count > checked then checked = count end

                    if mode == "rare" and not rareViaMap then
                        -- la rareza o el nombre del huevo leidos de sus datos en el mapa (se puede volver a comprobar)
                        local word, inst = findRareEgg()
                        if word then
                            rareWord, rareInst, rareViaMap = word, inst, true
                        end
                    end
                    if mode == "rare" and not rareWord and announcementRarity and announcementTime >= started - 15 then
                        rareWord = announcementRarity -- aviso del servidor ("A Secret ... egg spawned in ..."): no se repite
                    end
                    task.wait(0.5)
                end
            until os.clock() - started >= EGG_SCAN_SECONDS or not huntOn() or not alive()

            -- Este servidor ya cuenta como visto: la proxima busqueda no lo repite
            markVisited(game.JobId)
            saveSettings()

            if not huntOn() or not alive() then
                -- se apago mientras escaneaba
            elseif freshStart then
                -- el servidor donde estabas no cuenta: viaja de inmediato a buscar en otros
                if mode == "dim" then
                    judgeDimension(dimNames) -- solo aprende que objetos son permanentes
                    saveSettings()
                end
                hop()
                task.wait(AUTO_RETRY_DELAY)
            elseif mode == "dim" then
                -- Solo la dimension: si en este servidor esta abierta se queda (el jefe puede morir en cualquier
                -- momento); si no, sigue con otro servidor, sin conformarse con nada mas.
                local open, learned = judgeDimension(dimNames)
                saveSettings()
                local trust = takeBoardTrust()
                if trust and not open and not learned then
                    -- aun aprendiendo que objetos son permanentes: si hay objetos tipo portal, confia en el tablero
                    open = next(dimNames) and select(2, next(dimNames)) or nil
                end
                if trust and not open then
                    boardDelete("dim", game.JobId) -- el tablero decia que habia dimension y al llegar no esta
                end
                if open then
                    boardPost("dim", 0, "")
                    holdHere(("Encontrado: dimensión abierta (%s)"):format(open))
                else
                    if learned then
                        statusSuffix = " | sin dimensión"
                    else
                        statusSuffix = (" | aprendiendo %d/%d"):format(settings.dimVisits, DIM_WARMUP)
                    end
                    hop()
                    task.wait(AUTO_RETRY_DELAY)
                end
            else
                -- Modos "raros" y "grandes": solo cuenta un servidor que TIENE lo buscado, comprobado aqui mismo.
                -- Entre los que lo tienen se elige el del huevo mas grande. Si ninguno lo tiene, sigue buscando
                -- (no se conforma con otra cosa).
                local giantSize = 0
                if mode == "big" then
                    giantSize = scanMap(true, false)
                end
                local isGiant = mode == "big" and giantSize >= GIANT_MIN
                local isRare = mode == "rare" and rareWord ~= nil
                local found = isRare or isGiant
                local size = biggest
                if isRare then
                    size = math.max(rareInst and largestDimension(rareInst) or biggest, 0.1)
                elseif isGiant then
                    size = giantSize
                end
                local rareLabel = isRare and rareWord or ""

                -- Solo sirve para volver si tiene espacio: un servidor casi lleno se llena y ya no deja entrar
                local freeSlots = Players.MaxPlayers - #Players:GetPlayers()
                local roomy = freeSlots >= HUNT_MIN_FREE

                -- VERIFICACION al llegar: si venia a un servidor guardado o recomendado por el tablero, el huevo
                -- tiene que seguir ahi; si no, no se queda. (Un aviso del servidor no se repite: solo se acepta
                -- mientras no haya pasado la vida de un huevo raro.)
                local arrivedInfo
                local trust = takeBoardTrust()
                if settings.eggReturning then
                    settings.eggReturning = false
                    local candidate = findCandidate(game.JobId)
                    if candidate and (found or (mode == "rare" and candidate.via ~= "map"
                            and os.time() - (candidate.t or 0) <= RARE_LIFETIME)) then
                        arrivedInfo = candidate
                    elseif candidate then
                        removeCandidate(game.JobId)
                        setStatus("El huevo ya no está; sigo buscando", "busy")
                    else
                        resetHunt() -- no se pudo entrar a ninguno de los guardados: empieza una busqueda nueva
                    end
                    saveSettings()
                elseif trust then
                    if found or (mode == "rare" and os.time() - trust.t <= RARE_LIFETIME) then
                        arrivedInfo = { rare = trust.rare, size = trust.size, giant = (mode == "big") }
                    else
                        boardDelete(mode, game.JobId) -- el tablero decia que estaba y al llegar no esta
                    end
                end

                -- comparte lo encontrado con el tablero (si esta activado)
                if found then
                    boardPost(mode, size, rareLabel)
                end

                if found and not roomy then
                    statusSuffix = " | casi lleno"
                elseif isGiant then
                    statusSuffix = (" | gigante %.1f"):format(size)
                elseif isRare then
                    statusSuffix = (" | raro %.1f"):format(size)
                elseif mode == "rare" then
                    statusSuffix = " | sin raros aquí"
                else
                    statusSuffix = (" | sin huevos %.0f+"):format(GIANT_MIN)
                end

                if arrivedInfo then
                    local label = (arrivedInfo.rare or "") ~= "" and arrivedInfo.rare or rareLabel
                    holdHere(foundMessage(mode, label ~= "" and label or nil, math.max(size, arrivedInfo.size or 0),
                        isGiant or arrivedInfo.giant))
                elseif found and not roomy then
                    -- lo tiene pero esta casi lleno: despues no se podria volver, asi que se queda ahora
                    holdHere(foundMessage(mode, rareLabel ~= "" and rareLabel or nil, size, isGiant))
                else
                    if found then
                        addCandidate(game.JobId, size, size, rareLabel, { giant = isGiant,
                            via = (isRare and rareViaMap) and "map" or "announce", t = os.time() })
                    end
                    settings.eggSamples = settings.eggSamples + 1
                    saveSettings()

                    local top = topList()
                    if settings.eggSamples >= EGG_SAMPLE_SERVERS and #top > 0 then
                        local best = top[1]
                        if best.job == game.JobId then
                            holdHere(foundMessage(mode, best.rare ~= "" and best.rare or nil, best.size, best.giant))
                        else
                            -- antes de volver, comprueba que esos servidores no se hayan llenado
                            setStatus("Compruebo que el mejor servidor tenga espacio...", "busy")
                            local reachable = stillRoomy(top)
                            if #reachable == 0 then
                                -- todos casi llenos: mejor buscar de nuevo que caer en uno cualquiera sin huevo
                                setStatus("Los mejores servidores se llenaron; sigo buscando", "busy")
                                resetHunt()
                                saveSettings()
                                hop()
                            else
                                -- vuelve al mejor servidor con espacio; si no deja entrar, prueba el siguiente
                                settings.eggReturning = true
                                saveSettings()
                                best = reachable[1]
                                if best.giant then
                                    statusSuffix = (" | gigante %.1f"):format(best.size)
                                else
                                    statusSuffix = (" | raro %.1f"):format(best.size)
                                end
                                goToServer(reachable, "Teletransportando al mejor servidor...")
                            end
                            task.wait(AUTO_RETRY_DELAY)
                        end
                    else
                        hop()
                        task.wait(AUTO_RETRY_DELAY)
                    end
                end
            end
        elseif settings.auto and not busy then
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
