local KillCounter = { version = "1.13" }
_G.KillCounter = KillCounter

KillCounterSet = KillCounterSet or {}

local active
local ready = false
local corpse = { target = nil, focus = nil }
local miniDragging = false
local historyOpen = false
local ROW_COUNT = 12
local historyIndex = 0
local offset = 0
local displayRows = {}
local displayKinds = 0
local listDirty = true
local scrollUpdating = false
local lastClock
local refreshElapsed = 0

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffFFD700[Licznik]|r "..msg)
end

local defaults = {
	total = 0,
	mobs = {},
	sessions = {},
	chat = false,
	debug = false,
	hasPos = false,
	posPoint = "CENTER",
	posRel = "CENTER",
	posX = 0,
	posY = 0,
	btnHasPos = false,
	btnX = 0,
	btnY = 0,
	btnNorm = 0,
}

local function IsCountable(unit)
	return UnitExists(unit) and not UnitIsPlayer(unit)
end

-- Pozycja ikony przy minimapie zapisana jako offset od srodka
-- MinimapViewFrame. GetLeft()/GetTop() zwracaja bezwzgledne
-- wspolrzedne pikseli ekranu, wiec zapis jedynie odejmuje je
-- od srodka minimapy; po wczytaniu przypinamy z powrotem.
-- Dziala to tak samo po zmianie rozdzielczosci i skali UI.
local function MinimapCenterXY()
	local mf = _G["MinimapViewFrame"]
	if mf and mf.GetLeft then
		local l = tonumber(mf:GetLeft()) or 0
		local t = tonumber(mf:GetTop()) or 0
		local w = tonumber(mf.GetWidth and mf:GetWidth()) or 160
		local h = tonumber(mf.GetHeight and mf:GetHeight()) or 160
		return l + w / 2, t + h / 2, true
	end
	return nil, nil, false
end

local function RestoreMinimapButton()
	local set = KillCounterSet
	if not set.btnHasPos then return end
	local btn = _G["KillCounterMinimapButton"]
	if not btn then return end
	if set.btnNorm ~= 2 and set.btnNorm ~= 1 and set.btnNorm ~= 0 then
		set.btnHasPos = false
		return
	end
	-- zapis w offsetach od srodka minimapy (srodek ikony),
	-- wiec przy przywracaniu cofamy o polowe rozmiaru ikony.
	if set.btnNorm == 2 then
		local dx = tonumber(set.btnX) or 0
		local dy = tonumber(set.btnY) or 0
		-- ochrona: offset wiekszy niz ekran znaczy uszkodzony zapis
		local w = tonumber(GetScreenWidth()) or 1024
		local h = tonumber(GetScreenHeight()) or 768
		if math.abs(dx) > w or math.abs(dy) > h then
			set.btnHasPos = false
			btn:ClearAllAnchors()
			btn:SetAnchor("CENTER", "CENTER", "MinimapViewFrame", -80, 20)
			return
		end
		-- kotwica bezposrednio do minimapy: ikona podaza za minimapa
		-- przy zmianach rozmiaru okna klienta
		btn:ClearAllAnchors()
		btn:SetAnchor("CENTER", "CENTER", "MinimapViewFrame", dx, dy)
		return
	end
	-- stary zapis w pikselach/znormalizowaniu - przelicz raz i
	-- od teraz zapisujemy offset wzgledem minimapy
	local w = tonumber(GetScreenWidth()) or 1024
	local h = tonumber(GetScreenHeight()) or 768
	local x, y
	if set.btnNorm == 1 then
		x = (tonumber(set.btnX) or 0) * (w / 1024)
		y = (tonumber(set.btnY) or 0) * (h / 768)
	else
		x = tonumber(set.btnX) or 0
		y = tonumber(set.btnY) or 0
	end
	if x < -100 or x > w + 50 or y < -100 or y > h + 50 then
		set.btnHasPos = false
		btn:ClearAllAnchors()
		btn:SetAnchor("CENTER", "CENTER", "MinimapViewFrame", -80, 20)
		return
	end
	-- pierwsze przeciagniecie po aktualizacji zapisze juz nowy format
	set.btnHasPos = false
	btn:ClearAllAnchors()
	btn:SetAnchor("CENTER", "CENTER", "MinimapViewFrame", -80, 20)
end

-- v1.11: bez walidacji wzgledem rozmiaru ekranu. GetScreenWidth() przy
-- VARIABLES_LOADED potrafi zwrocic stara/za mala wartosc (np. po zmianie
-- rozdzielczosci lub na 4K), wiec filtrowanie tutaj odrzucalo legalne
-- pozycje i okno wracalo na srodek. Zly zapis i tak da sie naprawic
-- komenda /lz center.
local function RestorePos(frame, point, rel, x, y)
	local px, py = tonumber(x), tonumber(y)
	if not px or not py or not point or not rel then return false end
	frame:ClearAllAnchors()
	frame:SetAnchor(point, rel, "UIParent", px, py)
	return true
end

local function CurStamp()
	if os and os.date then
		local ok, value = pcall(os.date, "%Y-%m-%d %H:%M")
		if ok and type(value) == "string" then return value end
	end
	return ""
end

local function NewActive()
	return {
		total = 0, mobs = {}, stamp = CurStamp(), time = 0,
		timerKills = 0, timerRunning = false, timerAutoStart = false,
	}
end

local function Rate(s)
	local elapsed = tonumber(s.time) or 0
	if elapsed <= 0 then return 0 end
	-- Old archives did not store timerKills. Keep their recorded rate.
	if s.timerKills == nil then
		return tonumber(s.rate) or ((tonumber(s.total) or 0) * 60 / elapsed)
	end
	return s.timerKills * 60 / elapsed
end

local function Snapshot(s)
	local copy = {
		total = tonumber(s.total) or 0,
		stamp = s.stamp or "", time = tonumber(s.time) or 0,
		timerKills = s.timerKills, rate = Rate(s), mobs = {},
	}
	for name, count in pairs(s.mobs or {}) do copy.mobs[name] = count end
	return copy
end

local function Archive(s)
	if type(s) ~= "table" or (tonumber(s.total) or 0) <= 0 then return end
	table.insert(KillCounterSet.sessions, Snapshot(s))
	while #KillCounterSet.sessions > 30 do
		table.remove(KillCounterSet.sessions, 1)
	end
end

local function Tick()
	if not ready then return end
	local now = GetTime()
	if active.timerRunning and lastClock then
		active.time = active.time + math.max(0, now - lastClock)
	end
	lastClock = now
end

function KillCounter.OnLoad(this)
	this:RegisterEvent("VARIABLES_LOADED")
end

function KillCounter.OnEvent(this, event)
	if event == "VARIABLES_LOADED" then
		if ready then return end
		for k, v in pairs(defaults) do
			if KillCounterSet[k] == nil then
				KillCounterSet[k] = type(v) == "table" and {} or v
			end
		end
		if type(KillCounterSet.sessions) ~= "table" then KillCounterSet.sessions = {} end
		if type(KillCounterSet.mobs) ~= "table" then KillCounterSet.mobs = {} end
		-- The prior client's active state was already in SavedVariables.
		-- Archive it exactly once, then replace it with a fresh active session.
		Archive(KillCounterSet.current)
		active = NewActive()
		KillCounterSet.current = active
		SaveVariablesPerCharacter("KillCounterSet")
		this:RegisterEvent("UNIT_HEALTH")
		this:RegisterEvent("PLAYER_TARGET_CHANGED")
		this:RegisterEvent("FOCUS_CHANGED")
		ready = true
		lastClock = GetTime()
		KillCounter.ApplyPos()
		RestoreMinimapButton()
		KillCounterFrame:Hide()
		KillCounter.Update()
		Print("v"..KillCounter.version.." zaladowany - /lz pomoc (okienko wlaczysz ikona przy minimapie)")
		return
	end
	if not ready then return end
	if event == "PLAYER_TARGET_CHANGED" then
		corpse.target = nil
		if KillCounterSet.debug then
			Print("dbg: PLAYER_TARGET_CHANGED")
		end
		return
	end
	if event == "FOCUS_CHANGED" then
		corpse.focus = nil
		return
	end
	if event == "UNIT_HEALTH" then
		local unit = arg1
		if unit ~= "target" and unit ~= "focus" then return end
		if not IsCountable(unit) then return end
		local hp = UnitHealth(unit) or 1
		if hp > 0 then
			corpse[unit] = nil
			if KillCounterSet.debug then
				Print("dbg: UNIT_HEALTH "..unit.." hp="..tostring(hp).." (zywy)")
			end
			return
		end
		local name = UnitName(unit)
		if not name or name == "" then return end
		local c = corpse[unit]
		if c and c.name == name and (GetTime() - c.t) < 1 then
			if KillCounterSet.debug then
				Print("dbg: UNIT_HEALTH "..unit.." hp=0 "..name.." (duplikat, pominiety)")
			end
			return
		end
		if KillCounterSet.debug then
			Print("dbg: UNIT_HEALTH "..unit.." hp=0 -> KILL: "..name)
		end
		corpse[unit] = { name = name, t = GetTime() }
		KillCounter.AddKill(name)
		return
	end
end

function KillCounter.AddKill(name)
	if not ready or type(name) ~= "string" or name == "" then return end
	Tick()
	active.total = active.total + 1
	active.mobs[name] = (active.mobs[name] or 0) + 1
	KillCounterSet.total = KillCounterSet.total + 1
	KillCounterSet.mobs[name] = (KillCounterSet.mobs[name] or 0) + 1
	-- v1.10: timer startuje TYLKO z przycisku Start - pierwszy kill
	-- nie wlacza juz pomiaru
	if active.timerRunning then
		active.timerKills = active.timerKills + 1
	end
	if KillCounterSet.chat then
		Print(string.format("%s - sesja: %d, razem: %d", name, active.mobs[name], KillCounterSet.mobs[name]))
	end
	-- active is KillCounterSet.current, not a temporary local-only copy.
	listDirty = true
	KillCounter.Update()
end

function KillCounter.AddManual()
	if UnitExists("target") then
		local name = UnitName("target")
		if name and name ~= "" then
			KillCounter.AddKill(name)
			Print("recznie dodano: "..name)
			return
		end
	end
	Print("brak celu - najpierw zaznacz potwora.")
end

function KillCounter.Center()
	KillCounterFrame:ClearAllAnchors()
	KillCounterFrame:SetAnchor("CENTER", "CENTER", "UIParent", 0, 0)
	KillCounterSet.hasPos = false
	KillCounterFrame:Show()
	Print("okienko wycentrowane.")
end

local function SortedMobs(counts)
	local arr = {}
	for name, c in pairs(counts or {}) do
		if type(name) == "string" and type(c) == "number" and c > 0 then
			arr[#arr + 1] = { name = name, count = c }
		end
	end
	table.sort(arr, function(a, b)
		if a.count == b.count then return a.name < b.name end
		return a.count > b.count
	end)
	return arr
end

local function NameParts(name)
	-- Short, separate FontStrings avoid the client's long-text buffer limit.
	-- Never split a UTF-8 codepoint; game-provided names remain unchanged.
	local parts, start, chars, bytes = {}, 1, 0, 0
	local i = 1
	while i <= #name do
		local b = string.byte(name, i)
		local width = 1
		if b >= 240 and b < 248 then width = 4
		elseif b >= 224 and b < 240 then width = 3
		elseif b >= 192 and b < 224 then width = 2 end
		width = math.min(width, #name - i + 1)
		if chars >= 34 or bytes + width > 80 then
			parts[#parts + 1] = string.sub(name, start, i - 1)
			start, chars, bytes = i, 0, 0
		end
		chars, bytes = chars + 1, bytes + width
		i = i + width
	end
	if start <= #name then parts[#parts + 1] = string.sub(name, start) end
	return parts
end

local function SelectedSession()
	if not historyOpen then return active end
	return KillCounterSet.sessions[historyIndex]
end

local function BuildRows()
	displayRows, displayKinds = {}, 0
	local s = SelectedSession()
	local mobs = SortedMobs(s and s.mobs)
	displayKinds = #mobs
	for _, mob in ipairs(mobs) do
		local parts = NameParts(mob.name)
		for i, text in ipairs(parts) do
			displayRows[#displayRows + 1] = {
				text = text, count = i == 1 and ("x"..mob.count) or "",
			}
		end
	end
	if #displayRows == 0 then
		displayRows[1] = { text = historyOpen and "Brak zapisanych sesji" or "Brak zabitych mobow", count = "" }
	end
	offset = math.max(0, math.min(offset, math.max(0, #displayRows - ROW_COUNT)))
	listDirty = false
end

function KillCounter.DrawRows()
	for i = 1, ROW_COUNT do
		local row = displayRows[offset + i]
		_G["KillCounterFrame_Row"..i.."_Name"]:SetText(row and row.text or "")
		_G["KillCounterFrame_Row"..i.."_Count"]:SetText(row and row.count or "")
	end
	local maximum = math.max(0, #displayRows - ROW_COUNT)
	scrollUpdating = true
	KillCounterFrame_Scroll:SetMinMaxValues(0, maximum)
	KillCounterFrame_Scroll:SetValue(offset)
	scrollUpdating = false
	if maximum > 0 then KillCounterFrame_Scroll:Show()
	else KillCounterFrame_Scroll:Hide() end
	KillCounterFrame_Page:SetText(string.format("Wiersze %d-%d/%d | Typy: %d",
		offset + 1, math.min(offset + ROW_COUNT, #displayRows), #displayRows, displayKinds))
end

function KillCounter.OnScrollChanged(this, value)
	-- arg1 is the RoM slider callback argument, not WoW's "value".
	if scrollUpdating or not ready then return end
	offset = math.floor(tonumber(value) or this:GetValue() or 0)
	offset = math.max(0, math.min(offset, math.max(0, #displayRows - ROW_COUNT)))
	KillCounter.DrawRows()
end

function KillCounter.OnMouseWheel(delta)
	if not ready then return end
	if (tonumber(delta) or 0) > 0 then offset = offset - 3
	else offset = offset + 3 end
	offset = math.max(0, math.min(offset, math.max(0, #displayRows - ROW_COUNT)))
	KillCounter.DrawRows()
end

function KillCounter.ChangeHistory(direction)
	if not ready or not historyOpen then return end
	historyIndex = math.max(1, math.min(#KillCounterSet.sessions, historyIndex + direction))
	offset, listDirty = 0, true
	KillCounter.Update()
end

function KillCounter.Update()
	if not ready then return end
	Tick()
	if historyOpen then
		local s = SelectedSession()
		local n = #KillCounterSet.sessions
		KillCounterFrame_Total:SetText(s and ("Archiwum | Zabitych: "..s.total) or "Archiwum sesji")
		KillCounterFrame_Stats:SetText(s and string.format("Czas: %s | %.1f/min | Pomiar: %d",
			KillCounter.FormatTime(s.time), Rate(s), s.timerKills or s.total) or "Zapis przy resecie lub kolejnym logowaniu.")
		local stamp = s and s.stamp or ""
		if stamp == "" then stamp = "bez daty" end
		KillCounterFrame_Session:SetText(n > 0 and string.format("Sesja %d/%d | %s", historyIndex, n, stamp) or "Brak sesji")
		KillCounterFrame_Prev:Show()
		KillCounterFrame_Next:Show()
		if historyIndex > 1 then KillCounterFrame_Prev:Enable() else KillCounterFrame_Prev:Disable() end
		if historyIndex < n then KillCounterFrame_Next:Enable() else KillCounterFrame_Next:Disable() end
		KillCounterFrame_HistoryBtn:SetText("Wroc")
	else
		KillCounterFrame_Total:SetText(string.format("Razem: %d | Sesja: %d", KillCounterSet.total, active.total))
		local state = active.timerRunning and "START" or "PAUZA"
		KillCounterFrame_Stats:SetText(string.format("%s | %s | %.1f/min | Pomiar: %d",
			state, KillCounter.FormatTime(active.time), Rate(active), active.timerKills))
		KillCounterFrame_Session:SetText("Biezaca sesja")
		KillCounterFrame_Prev:Hide()
		KillCounterFrame_Next:Hide()
		KillCounterFrame_HistoryBtn:SetText("Archiwum")
	end
	KillCounterFrame_TimerBtn:SetText(active.timerRunning and "Pauza" or "Start")
	-- Archived sessions are read-only; timer/reset controls apply to current.
	for _, button in ipairs({KillCounterFrame_TimerBtn, KillCounterFrame_TimerReset,
		KillCounterFrame_Reset}) do
		if historyOpen then button:Disable() else button:Enable() end
	end
	if listDirty then
		BuildRows()
		KillCounter.DrawRows()
	end
end

function KillCounter.FormatTime(sec)
	sec = math.floor(tonumber(sec) or 0)
	local h = math.floor(sec / 3600)
	local m = math.floor((sec % 3600) / 60)
	local s = sec % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%02d:%02d", m, s)
end

function KillCounter.TimerToggle()
	if not ready then return end
	Tick()
	active.timerAutoStart = false
	active.timerRunning = not active.timerRunning
	Print("timer: "..(active.timerRunning and "START" or "PAUZA"))
	KillCounter.Update()
end

function KillCounter.TimerReset()
	if not ready then return end
	Tick()
	active.time = 0
	active.timerKills = 0
	active.timerRunning = false
	active.timerAutoStart = false
	Print("pomiar czasu i zabic/min wyzerowany. Lista mobow bez zmian.")
	KillCounter.Update()
end

function KillCounter.OnUpdate(elapsedTime)
	if not ready then return end
	Tick()
	refreshElapsed = refreshElapsed + (tonumber(elapsedTime) or 0)
	if refreshElapsed < 0.5 then return end
	refreshElapsed = 0
	if KillCounterFrame:IsVisible() then
		KillCounter.Update()
	end
end

function KillCounter.ToggleHistory()
	if not ready then return end
	historyOpen = not historyOpen
	if historyOpen then historyIndex = #KillCounterSet.sessions end
	offset, listDirty = 0, true
	KillCounter.Update()
end

local function NewSession()
	active = NewActive()
	KillCounterSet.current = active
	lastClock = GetTime()
	offset, listDirty = 0, true
	corpse.target = nil
	corpse.focus = nil
	historyOpen = false
end

function KillCounter.ResetSession()
	if not ready then return end
	Tick()
	Archive(active)
	NewSession()
	KillCounter.Update()
	Print("licznik sesji zresetowany" .. (#KillCounterSet.sessions > 0 and " (poprzednia zapisana w archiwum)." or "."))
end

function KillCounter.ResetAll()
	if not ready then return end
	NewSession()
	KillCounterSet.total = 0
	KillCounterSet.mobs = {}
	KillCounterSet.sessions = {}
	KillCounter.Update()
	Print("licznik calkowity i historia zresetowane.")
end

function KillCounter.SaveSession()
	-- Compatibility entry point: close one session, never append duplicates.
	KillCounter.ResetSession()
end
_G.KillCounterSaveSession = KillCounter.SaveSession

-- pozycje przywracamy przy KAZDYM pokazaniu okienka, nie tylko
-- przy VARIABLES_LOADED. Kotwica ustawiona raz na sesje byla przez
-- klient nadpisywana (np. przy pozniejszej inicjalizacji rozmiaru UI).
function KillCounter.ApplyPos()
	if not ready or not KillCounterSet.hasPos then return end
	-- stary zapis oparty o GetAnchor (CENTER + offset) jest niepewny -
	-- jednorazowo go kasujemy, okienko pojawi sie na srodku i po jednym
	-- przeciagu zapisze sie juz w nowym formacie pikselowym
	if KillCounterSet.posFmt ~= 3 then
		KillCounterSet.hasPos = false
		return
	end
	local mf = _G["MinimapViewFrame"]
	if not mf then return end
	KillCounterFrame:ClearAllAnchors()
	KillCounterFrame:SetAnchor(KillCounterSet.posPoint, "CENTER", "MinimapViewFrame",
		tonumber(KillCounterSet.posX) or 0, tonumber(KillCounterSet.posY) or 0)
end

function KillCounter.OnShowFrame()
	KillCounter.ApplyPos()
	KillCounter.Update()
end

function KillCounter.Toggle()
	if not ready then return end
	if KillCounterFrame:IsVisible() then
		KillCounterFrame:Hide()
	else
		KillCounter.ApplyPos()
		KillCounter.Update()
		KillCounterFrame:Show()
	end
end

-- pozycja okienka jako offset od SRODKA minimapy - dokladnie ta
-- sama metoda, ktora uzytkownikowi dziala przy ikonach. Pixele
-- bezwzgledne (GetLeft/GetTop + UIParent) sa przez klienta skalowane
-- przy zmianach rozmiaru okna, stad okienko "uciekalo" na srodek.
-- Kotwica do minimapy sprawia, ze okienko jest do niej zadokowane i
-- podaza za nia przy kazdej zmianie rozmiaru okna klienta.
function KillCounter.OnDragStop(this)
	this:StopMovingOrSizing()
	local l = this.GetLeft and tonumber(this:GetLeft()) or nil
	local t = this.GetTop and tonumber(this:GetTop()) or nil
	local cx, cy, ok = MinimapCenterXY()
	if not ok or not l or not t then return end
	KillCounterSet.posPoint = "CENTER"
	KillCounterSet.posRel = "MinimapViewFrame"
	KillCounterSet.posX = math.floor(l + this:GetWidth() / 2 - cx + 0.5)
	KillCounterSet.posY = math.floor(t + this:GetHeight() / 2 - cy + 0.5)
	KillCounterSet.hasPos = true
	KillCounterSet.posFmt = 3
end

-- ikona przy minimapie
function KillCounter.MinimapClick(this, key)
	if miniDragging then
		miniDragging = false
		return
	end
	if key == "RBUTTON" then
		KillCounter.ResetSession()
	else
		KillCounter.Toggle()
	end
end

function KillCounter.MinimapDragStart(this)
	miniDragging = true
	this:StartMoving()
end

function KillCounter.MinimapDragStop(this)
	this:StopMovingOrSizing()
	-- zapis pozycji jako offset od srodka minimapy robi sie
	-- natychmiast po odczycie bezwzglednych wspolrzednych ramki.
	local l = this.GetLeft and tonumber(this:GetLeft()) or nil
	local t = this.GetTop and tonumber(this:GetTop()) or nil
	local cx, cy, ok = MinimapCenterXY()
	if not ok or not l or not t then
		local _, _, _, x, y = this:GetAnchor()
		if cx then
			KillCounterSet.btnX = math.floor((tonumber(x) or 0) + this:GetWidth() / 2 - cx + 0.5)
			KillCounterSet.btnY = math.floor((tonumber(y) or 0) + this:GetHeight() / 2 - cy + 0.5)
			KillCounterSet.btnHasPos = true
			KillCounterSet.btnNorm = 2
		end
		return
	end
	-- offset od srodka minimapy do srodka ikony
	KillCounterSet.btnX = math.floor(l + this:GetWidth() / 2 - cx + 0.5)
	KillCounterSet.btnY = math.floor(t + this:GetHeight() / 2 - cy + 0.5)
	KillCounterSet.btnHasPos = true
	KillCounterSet.btnNorm = 2
end

function KillCounter.MinimapHome()
	KillCounterSet.btnHasPos = false
	KillCounterSet.btnX = -80
	KillCounterSet.btnY = 20
	KillCounterSet.btnNorm = 2
	KillCounterMinimapButton:ClearAllAnchors()
	KillCounterMinimapButton:SetAnchor("CENTER", "CENTER", "MinimapViewFrame", -80, 20)
	KillCounterMinimapButton:Show()
	Print("ikona wrocila przy minimape.")
end

SLASH_KILLCOUNTER1 = "/lz"
SLASH_KILLCOUNTER2 = "/licznik"
SLASH_KILLCOUNTER3 = "/killcounter"
SlashCmdList["KILLCOUNTER"] = function(msg)
	if type(msg) ~= "string" then msg = "" end
	msg = string.lower(msg)
	if msg == "reset" then
		KillCounter.ResetSession()
	elseif msg == "resetall" then
		KillCounter.ResetAll()
	elseif msg == "dodaj" then
		KillCounter.AddManual()
	elseif msg == "center" then
		KillCounter.Center()
	elseif msg == "ikona" then
		KillCounter.MinimapHome()
	elseif msg == "timer" then
		KillCounter.TimerToggle()
	elseif msg == "czasreset" then
		KillCounter.TimerReset()
	elseif msg == "arch" or msg == "historia" then
		KillCounter.ToggleHistory()
		if not KillCounterFrame:IsVisible() then KillCounterFrame:Show() end
	elseif msg == "chat" then
		KillCounterSet.chat = not KillCounterSet.chat
		Print("powiadomienia o zabiciu na czacie: "..(KillCounterSet.chat and "WLACZONE" or "WYLACZONE"))
	elseif msg == "debug" then
		KillCounterSet.debug = not KillCounterSet.debug
		Print("tryb debug: "..(KillCounterSet.debug and "WLACZONY" or "WYLACZONY"))
	elseif msg == "pomoc" or msg == "help" then
		Print("/lz - pokaz/ukryj okienko")
		Print("/lz reset - reset sesji (zapisuje ja w archiwum)")
		Print("/lz resetall - reset wszystkich licznikow i historii")
		Print("/lz dodaj - recznie dodaj +1 dla zaznaczonego potwora")
		Print("/lz arch - archiwum poprzednich sesji")
		Print("/lz timer - start/pauza; /lz czasreset - zeruj pomiar")
		Print("Archiwum: strzalki wybieraja sesje. Lista: suwak lub kolko myszy.")
		Print("/lz center - przenies okienko na srodek ekranu")
		Print("/lz ikona - przywroc ikone obok minimapy")
		Print("/lz chat - wl./wyl. powiadomienia o zabiciu na czacie")
		Print("/lz debug - wl./wyl. podglad eventow (do diagnostyki)")
	else
		KillCounter.Toggle()
	end
end
