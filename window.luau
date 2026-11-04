-- Palette commands: open a dashboard by name, and set the Grafana URL and token.

local BLOCK = "grafana.dashboard"

local function baseUrl(): string?
	local ok, saved = pcall(tern.kv.get, "url")
	local url = if ok and type(saved) == "string" and saved ~= "" then saved else tern.getenv("TERN_GRAFANA_URL")
	if type(url) ~= "string" or url == "" then return nil end
	return (url:gsub("/+$", ""))
end

-- `TERN_GRAFANA_TOKEN` wins over the stored token, as in host.luau.
local function token(): string?
	local env = tern.getenv("TERN_GRAFANA_TOKEN")
	if type(env) == "string" and env ~= "" then return env end
	local ok, saved = pcall(tern.kv.get, "token")
	return if ok and type(saved) == "string" and saved ~= "" then saved else nil
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
tern.on("window_start", function(cx) recordCellPx(cx) end)
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

-- Stored in kv.json, not `tern.secrets`: the host half sends every query and cannot read secrets. The
-- field never shows the saved token; an empty one clears it.
local function setToken(cx)
	cx:prompt({ placeholder = "Grafana service account token (empty clears it)", icon = "gauge", action = "save" })
		:next(function(text, _err, cx2)
			if type(text) ~= "string" then return end
			local c = cx2 or cx
			local t = text:match("^%s*(.-)%s*$") :: string
			if t == "" then
				tern.kv.set("token", nil)
				c:toast("success", "Grafana token cleared")
				return
			end
			tern.kv.set("token", t)
			local env = tern.getenv("TERN_GRAFANA_TOKEN")
			c:toast("success", "Grafana token saved",
				if type(env) == "string" and env ~= "" then "TERN_GRAFANA_TOKEN is set and takes precedence" else nil)
		end)
end

local function open(cx)
	local base = baseUrl()
	if not base then
		setUrl(cx, open)
		return
	end
	local headers = { Accept = "application/json" }
	local t = token()
	if t then headers.Authorization = "Bearer " .. t end
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

tern.command({ id = "open", title = "Open Grafana dashboard", icon = "gauge", keys = { "ctrl+alt+g" }, run = open })
tern.command({ id = "url", title = "Set Grafana URL", icon = "gauge", run = function(cx) setUrl(cx, nil) end })
tern.command({ id = "token", title = "Set Grafana token", icon = "gauge", run = setToken })
