-- Palette commands: open a dashboard by name, and set the Grafana URL and token.

local keychain = require("./keychain")

local BLOCK = "grafana.dashboard"

local function baseUrl(): string?
	local ok, saved = pcall(tern.kv.get, "url")
	local url = if ok and type(saved) == "string" and saved ~= "" then saved else tern.getenv("TERN_GRAFANA_URL")
	if type(url) ~= "string" or url == "" then return nil end
	return (url:gsub("/+$", ""))
end

local function envToken(): string?
	local env = tern.getenv("TERN_GRAFANA_TOKEN")
	return if type(env) == "string" and env ~= "" then env else nil
end

local function kvToken(): string?
	local ok, saved = pcall(tern.kv.get, "token")
	return if ok and type(saved) == "string" and saved ~= "" then saved else nil
end

-- Calls `done(token?, cx?)` in host.luau's order: `TERN_GRAFANA_TOKEN`, a kv.json token not yet moved,
-- the keychain; `cx` is the fresh context of an asynchronous keychain read.
local function withToken(done: (string?, any) -> ())
	local t = envToken() or kvToken()
	if t or not keychain.available() then return done(t, nil) end
	keychain.read(function(saved, err, cx)
		if err then print("grafana: keychain: " .. err) end
		done(saved, cx)
	end)
end

-- Moves a token saved in kv.json before the keychain into it.
local function migrateToken()
	local t = kvToken()
	if not t or not keychain.available() then return end
	keychain.write(t, function(err)
		if err then
			print("grafana: keychain: " .. err)
			return
		end
		if kvToken() == t then tern.kv.set("token", nil) end
		keychain.bump()
	end)
end

-- Blocks size their chart images from cells, and only the window can read the terminal font size, so the
-- window records one cell's width (0.6 × the font size) in kv "cell_px" for the host half.
local function recordCellPx(cx)
	if not cx then return end
	local ok, size = pcall(function() return cx.settings:get("font_size") end)
	if ok and type(size) == "number" and size > 0 then
		local px = math.floor(size * 0.6 * 100 + 0.5) / 100
		if tern.kv.get("cell_px") ~= px then tern.kv.set("cell_px", px) end
	end
end

-- A restored block opens without the command, and a font change resizes panes; both are followed by a
-- window start or a focus change.
tern.on("window_start", function(cx)
	recordCellPx(cx)
	migrateToken()
end)
tern.on("focus", function(_ev, cx) recordCellPx(cx) end)

local function openBlock(cx, args)
	recordCellPx(cx)
	if not cx:new_block(BLOCK, args, "tab") then
		cx:toast("error", "Could not open Grafana", "Install the grafana plugin on the current Tern host.")
	end
end

local function setUrl(cx, after)
	cx:prompt({ value = baseUrl() or "https://", placeholder = "Grafana URL, e.g. https://grafana.example.com", icon = "gauge", action = "save" })
		:next(function(text, _err, cx2)
			if type(text) ~= "string" or not text:match("^https?://.") then return end
			tern.kv.set("url", (text:gsub("/+$", "")))
			local c = cx2 or cx
			c:toast("success", "Grafana URL saved", text)
			if after then after(c) end
		end)
end

-- In the macOS keychain (keychain.luau), elsewhere in kv.json: `tern.secrets` is window-only and the
-- host half sends every query. The field never shows the saved token; an empty one clears it.
local function setToken(cx)
	cx:prompt({ placeholder = "Grafana service account token (empty clears it)", icon = "gauge", action = "save" })
		:next(function(text, _err, cx2)
			if type(text) ~= "string" then return end
			local c = cx2 or cx
			local t = text:match("^%s*(.-)%s*$") :: string
			local where = if keychain.available() then "the macOS keychain" else "the plugin's kv.json"
			local function saved(err: string?, cx3)
				local c3 = cx3 or c
				if err then
					c3:toast("error", "Could not save the Grafana token", err)
					return
				end
				tern.kv.set("token", if t ~= "" and not keychain.available() then t else nil)
				if keychain.available() then keychain.bump() end
				if t == "" then
					c3:toast("success", "Grafana token cleared")
				else
					c3:toast("success", "Grafana token saved in " .. where,
						if envToken() then "TERN_GRAFANA_TOKEN is set and takes precedence" else nil)
				end
			end
			if not keychain.available() then
				saved(nil, c)
			elseif t == "" then
				keychain.clear(saved)
			else
				keychain.write(t, saved)
			end
		end)
end

local function fetchList(cx, base: string, headers: { [string]: string })
	tern.fetch(base .. "/api/search?type=dash-db&limit=1000", { headers = headers, timeout_ms = 10_000 }, function(res, cx2)
		local c = cx2 or cx
		local ok, list = false, nil
		if not res.error and res.status < 400 then ok, list = pcall(tern.json.decode, res.body) end
		if not ok or type(list) ~= "table" or #list == 0 then
			-- The block's list view shows the error and retries.
			openBlock(c, {})
			return
		end
		local items = {}
		for _, d in list do
			table.insert(items, {
				label = tostring(d.title),
				detail = if type(d.tags) == "table" and #d.tags > 0 then table.concat(d.tags, ", ") else nil,
				group = tostring(d.folderTitle or "General"),
				icon = "gauge",
				uid = d.uid,
			})
		end
		table.sort(items, function(a, b)
			if a.group ~= b.group then return a.group < b.group end
			return a.label:lower() < b.label:lower()
		end)
		c:pick({ items = items, placeholder = "Grafana dashboard", icon = "gauge", action = "open" }):next(function(item, _err, cx3)
			if type(item) == "table" and type(item.uid) == "string" then openBlock(cx3 or c, { item.uid }) end
		end)
	end)
end

local function open(cx)
	local base = baseUrl()
	if not base then
		setUrl(cx, open)
		return
	end
	withToken(function(t, cx2)
		local headers = { Accept = "application/json" }
		if t then headers.Authorization = "Bearer " .. t end
		fetchList(cx2 or cx, base, headers)
	end)
end

tern.command({ id = "open", title = "Open Grafana dashboard", icon = "gauge", keys = { "ctrl+alt+g" }, run = open })
tern.command({ id = "url", title = "Set Grafana URL", icon = "gauge", run = function(cx) setUrl(cx, nil) end })
tern.command({ id = "token", title = "Set Grafana token", icon = "gauge", run = setToken })
