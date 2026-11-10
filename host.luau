-- The `dashboard` block: loads a Grafana dashboard through the HTTP API, runs every visible panel's
-- queries through /api/ds/query and draws the panels natively.

local grafana = require("./grafana")
local frames = require("./frames")
local panels = require("./panels")
local chart = require("./chart")
local keychain = require("./keychain")

local ui = tern.ui
local isNull = function(v: any): boolean return v == tern.json.null end

-- Pixel geometry of the 24-column grid, matching style.css.
local ROW_PX, GAP_PX = 30, 8
-- Width of one terminal cell in the block's surface, in px: 0.6 × the terminal font size, which the window
-- half stores in kv "cell_px" (blocks cannot read settings); 8.4 is the default 14px font.
local CELL_PX = 8.4
local function cellPx(): number
	local ok, v = pcall(tern.kv.get, "cell_px")
	return if ok and type(v) == "number" and v > 0 then v else CELL_PX
end
-- The init cx keeps the width it opened at; view and resize report the current one.
local function cols(st: any): number
	return st.cols or st.cx.cols
end
-- Card chrome inside a grid cell: head and padding.
local CARD_HEAD_PX, CARD_PAD_PX = 34, 12
local NARROW_COLS = 110
-- Blocks by pane, so closed panes stop their timers and callbacks.
local blocks: { [number]: any } = {}
local MAX_INFLIGHT = 6
local MIN_REFRESH_MS = 15_000
-- Crosshair steps per time range: an arrow key moves one, Shift+arrow five.
local CURSOR_STEPS = 120

local function now(): number return os.time() * 1000 end

--- Connection ------------------------------------------------------------------------------------

local function baseUrl(): string?
	local ok, saved = pcall(tern.kv.get, "url")
	local url = if ok and type(saved) == "string" and saved ~= "" then saved else tern.getenv("TERN_GRAFANA_URL")
	if type(url) ~= "string" or url == "" then return nil end
	return (url:gsub("/+$", ""))
end

-- `TERN_GRAFANA_TOKEN` from Tern's launch environment, else the token **Set Grafana token** stored: in
-- the macOS keychain (read again whenever kv "token_rev" changes), elsewhere in kv.json. A kv.json token
-- from before the keychain still counts until the window half moves it. A failed keychain read sends
-- requests without the token and retries after KEYCHAIN_RETRY_MS.
local KEYCHAIN_RETRY_MS = 30_000
local stored = {
	loaded = false, rev = nil :: any, token = nil :: string?,
	err = nil :: string?, retry_at = 0, loading = false,
}

local function envToken(): string?
	local env = tern.getenv("TERN_GRAFANA_TOKEN")
	return if type(env) == "string" and env ~= "" then env else nil
end

local function kvToken(): string?
	local ok, saved = pcall(tern.kv.get, "token")
	return if ok and type(saved) == "string" and saved ~= "" then saved else nil
end

local function tokenRev(): any
	local ok, rev = pcall(tern.kv.get, "token_rev")
	return if ok then rev else nil
end

-- Whether the keychain must be read before a request can carry the token; starts that read, which
-- calls `after` once done.
local function tokenPending(after: () -> ()): boolean
	if envToken() or kvToken() or not keychain.available() then return false end
	if stored.loading then return true end
	local rev = tokenRev()
	if stored.loaded and stored.rev == rev then return false end
	if stored.err and stored.rev == rev and now() < stored.retry_at then return false end
	stored.loading = true
	keychain.read(function(t, err)
		stored.loading, stored.rev, stored.err = false, rev, err
		if err then
			stored.loaded, stored.token, stored.retry_at = false, nil, now() + KEYCHAIN_RETRY_MS
			print("grafana: keychain: " .. err)
		else
			stored.loaded, stored.token = true, t
		end
		after()
	end)
	return true
end

local function token(): string?
	return envToken() or kvToken() or (if keychain.available() then stored.token else nil)
end

local function headers(): { [string]: string }
	local h = { Accept = "application/json", ["Content-Type"] = "application/json" }
	local t = token()
	if t then h.Authorization = "Bearer " .. t end
	return h
end

type Done = (ok: boolean, data: any) -> ()
-- `st` (a block state) receives callback failures through `st.fail`, so they show in the block.
local queue: { { method: string, path: string, body: string?, done: Done, st: any } } = {}
local inflight = 0

local function errorText(res: any): string
	if res.error then return if res.timed_out then "Grafana did not answer within 30s" else tostring(res.error) end
	local ok, body = pcall(tern.json.decode, res.body)
	local msg = if ok and type(body) == "table" and type(body.message) == "string" then body.message else nil
	local hint = if res.status ~= 401 then ""
		elseif stored.err then " (keychain: " .. stored.err .. "; palette: Set Grafana token)"
		else " (palette: Set Grafana token)"
	return string.format("HTTP %d%s%s", res.status, if msg then ": " .. msg else "", hint)
end

local pump
function pump()
	if #queue > 0 and tokenPending(function() pump() end) then return end
	while inflight < MAX_INFLIGHT and #queue > 0 do
		local job = table.remove(queue, 1)
		local base = baseUrl()
		if not base then
			job.done(false, "No Grafana URL set")
			continue
		end
		inflight += 1
		tern.fetch(base .. job.path, { method = job.method, headers = headers(), body = job.body, timeout_ms = 30_000 }, function(res)
			inflight -= 1
			local ok, data = false, nil
			if not res.error then
				local parsed, decoded = pcall(tern.json.decode, res.body)
				-- /api/ds/query answers 4xx with per-query errors in `results`; keep those.
				if parsed and (res.status < 400 or (type(decoded) == "table" and type(decoded.results) == "table")) then
					ok, data = true, decoded
				end
			end
			if not ok then data = errorText(res) end
			local fine, err = pcall(job.done, ok, data)
			if not fine then
				if job.st and job.st.fail then job.st.fail(err) else print("grafana: callback failed: " .. tostring(err)) end
			end
			pump()
		end)
	end
end

local function request(st: any, method: string, path: string, body: any, done: Done)
	table.insert(queue, {
		method = method,
		path = path,
		body = if body ~= nil then tern.json.encode(body) else nil,
		done = done,
		st = st,
	})
	pump()
end

local datasources: { any }? = nil
local function withDatasources(st: any, done: () -> ())
	if datasources then return done() end
	request(st, "GET", "/api/datasources", nil, function(ok, data)
		datasources = if ok and type(data) == "table" then data else {}
		done()
	end)
end

--- Block state -----------------------------------------------------------------------------------

type PanelState = {
	panel: any,
	key: string,
	frames: { frames.Frame }?,
	errors: { string },
	notes: { string },
	loading: boolean,
	version: number,
	chart: string?,
	chartKey: string?,
	chartNote: string?,
	-- Why the chart could not be drawn.
	chartError: string?,
	-- Alert list panels: the `data` of Grafana's rules API.
	rules: any?,
}

local function panelKey(p: any, i: number): string
	return if p.id ~= nil then "p" .. tostring(p.id) else "i" .. i
end

local function render(st: any)
	if st.pending or st.closed then return end
	st.pending = true
	tern.timer(50, function()
		st.pending = false
		if st.closed then return end
		local ok, err = pcall(st.draw, st)
		if not ok then print("grafana: draw failed: " .. tostring(err)) end
		st.cx:render()
	end)
end

-- Grid placements of every section, for the block's current width.
local function layout(st: any): { { section: grafana.Section, key: string, collapsed: boolean, cells: { grafana.Placement } } }
	local out = {}
	if not st.dash then return out end
	local narrow = cols(st) < NARROW_COLS
	local n = 0
	for i, sec in grafana.sections(st.dash) do
		local key = if sec.row then panelKey(sec.row, -i) else "top"
		local collapsed = sec.collapsed
		if st.collapsed[key] ~= nil then collapsed = st.collapsed[key] end
		local list = {}
		for _, p in sec.panels do
			n += 1
			if type(p) == "table" then
				p.__key = p.__key or panelKey(p, n)
				table.insert(list, p)
			end
		end
		table.insert(out, { section = sec, key = key, collapsed = collapsed, cells = if collapsed then {} else grafana.place(list, narrow) })
	end
	return out
end

local function pixelSize(st: any, c: grafana.Placement): (number, number)
	local inner = cols(st) * cellPx() - 24
	local colW = (inner - 23 * GAP_PX) / 24
	local w = c.w * colW + (c.w - 1) * GAP_PX - 2 * CARD_PAD_PX
	local h = c.h * ROW_PX + (c.h - 1) * GAP_PX - CARD_HEAD_PX - 2 * CARD_PAD_PX
	return math.max(120, math.floor(w)), math.max(60, math.floor(h))
end

local function builtins(st: any): grafana.Builtins
	return { from = st.from, to = st.to, dashboard = st.dash and st.dash.title }
end

-- Alert lists read Grafana's own rules API rather than a data source.
local function queryRules(st: any, ps: PanelState)
	ps.loading = true
	local gen = st.gen
	request(st, "GET", "/api/prometheus/grafana/api/v1/rules", nil, function(ok, data)
		if gen ~= st.gen or st.closed then return end
		ps.loading = false
		if ok and type(data) == "table" and type(data.data) == "table" then
			ps.rules, ps.frames, ps.errors = data.data, {}, {}
			ps.version += 1
		else
			ps.errors = { if ok then "Unexpected alert rules response" else tostring(data) }
		end
		render(st)
	end)
end

local function queryPanel(st: any, ps: PanelState)
	local p = ps.panel
	if not panels.NATIVE[p.type] or p.type == "text" then return end
	if p.type == "alertlist" then return queryRules(st, ps) end
	local queries, refs, err = grafana.queries(p, {
		vars = st.vars,
		builtins = builtins(st),
		datasources = datasources or {},
		maxDataPoints = 600,
		rangeMs = st.to - st.from,
		clone = function(t) return tern.json.decode(tern.json.encode(t)) end,
	})
	if err then
		ps.errors, ps.loading = { err }, false
		return
	end
	ps.loading = true
	local gen = st.gen
	request(st, "POST", "/api/ds/query", { queries = queries, from = tostring(st.from), to = tostring(st.to) }, function(ok, data)
		if gen ~= st.gen or st.closed then return end
		ps.loading = false
		if not ok then
			ps.errors = { tostring(data) }
		else
			local fs, errors = frames.decode(data.results or {}, refs, isNull)
			fs = frames.tables(fs, queries)
			local notes
			fs, notes = frames.transform(fs, p.transformations, tern.json.decode)
			frames.applyConfig(fs, p.fieldConfig)
			ps.frames, ps.errors, ps.notes = fs, errors, notes
			ps.version += 1
		end
		render(st)
	end)
end

-- Queries every panel in an expanded section that has no request running.
local function queryVisible(st: any)
	for _, sec in layout(st) do
		for _, c in sec.cells do
			local key = c.panel.__key
			local ps = st.panels[key]
			if not ps then
				ps = { panel = c.panel, key = key, errors = {}, notes = {}, loading = false, version = 0 }
				st.panels[key] = ps
			end
			if not ps.loading then queryPanel(st, ps) end
		end
	end
	st.updated = now()
	render(st)
end

local function setRange(st: any)
	st.from, st.to, st.rangeLabel = grafana.range(st.dash, st.range, now())
	-- The crosshair keeps its time across refreshes until the range leaves it behind.
	if st.cursor and (st.cursor < st.from or st.cursor > st.to) then st.cursor = nil end
end

local function resolveVars(st: any, gen: number, order: { string }, i: number, done: () -> ())
	while i <= #order do
		local var = st.vars[order[i]]
		local path = var and grafana.varRequest(var, st.vars, builtins(st), datasources or {}, st.from, st.to)
		if path then
			request(st, "GET", path, nil, function(ok, data)
				if gen ~= st.gen then return end
				if ok and type(data) == "table" then grafana.resolveVar(var, data.data) end
				resolveVars(st, gen, order, i + 1, done)
			end)
			return
		end
		i += 1
	end
	done()
end

local function armRefresh(st: any)
	if st.timer then
		st.timer:cancel()
		st.timer = nil
	end
	local every = st.dash and grafana.duration(st.dash.refresh)
	if not every or every <= 0 then return end
	every = math.max(every, MIN_REFRESH_MS)
	local gen = st.gen
	local function tick()
		if gen ~= st.gen or st.closed then return end
		st.timer = tern.timer(every, tick)
		setRange(st)
		queryVisible(st)
	end
	st.timer = tern.timer(every, tick)
end

local function loadList(st: any)
	st.list = st.list or { items = {}, sel = nil }
	st.list.loading = true
	st.list.error = nil
	render(st)
	request(st, "GET", "/api/search?type=dash-db&limit=1000", nil, function(ok, data)
		st.list.loading = false
		if ok and type(data) == "table" then
			st.list.items = data
			if not st.list.sel and data[1] then st.list.sel = data[1].uid end
		else
			st.list.error = tostring(data)
		end
		render(st)
	end)
end

local function loadDashboard(st: any)
	st.gen += 1
	local gen = st.gen
	st.loading, st.error = true, nil
	if not baseUrl() then
		st.loading, st.error = false, nil
		render(st)
		return
	end
	render(st)
	withDatasources(st, function()
		request(st, "GET", "/api/dashboards/uid/" .. grafana.urlencode(st.uid), nil, function(ok, data)
			if gen ~= st.gen or st.closed then return end
			if not ok or type(data) ~= "table" or type(data.dashboard) ~= "table" then
				st.loading, st.error = false, if ok then "Unexpected dashboard response" else tostring(data)
				render(st)
				return
			end
			st.dash, st.meta = data.dashboard, data.meta
			st.panels = {}
			st.vars = grafana.variables(st.dash, datasources or {})
			setRange(st)
			resolveVars(st, gen, grafana.varOrder(st.dash), 1, function()
				if gen ~= st.gen then return end
				st.loading = false
				queryVisible(st)
				armRefresh(st)
			end)
		end)
	end)
end

local function openDashboard(st: any, uid: string)
	st.uid = uid
	st.dash, st.panels, st.collapsed, st.cursor = nil, {}, {}, nil
	loadDashboard(st)
	st.cx:save()
end

local function showList(st: any)
	st.gen += 1
	if st.timer then st.timer:cancel() end
	st.uid, st.dash, st.panels, st.cursor = nil, nil, {}, nil
	loadList(st)
	st.cx:save()
end

local function grafanaUrl(st: any, panelId: any): string?
	local base = baseUrl()
	if not base then return nil end
	if not st.uid then return base .. "/dashboards" end
	local url = string.format("%s/d/%s?from=%d&to=%d", base, grafana.urlencode(st.uid), st.from or 0, st.to or 0)
	for name, v in (st.vars or {}) do
		if v.def and v.def.type ~= "constant" and v.def.type ~= "datasource" then
			if v.all then
				url ..= "&var-" .. grafana.urlencode(name) .. "=$__all"
			else
				for _, value in v.values do url ..= "&var-" .. grafana.urlencode(name) .. "=" .. grafana.urlencode(value) end
			end
		end
	end
	if panelId ~= nil then url ..= "&viewPanel=" .. grafana.urlencode(tostring(panelId)) end
	return url
end

-- Redraws chart images whose data or size changed.
local function draw(st: any)
	for _, sec in layout(st) do
		for _, c in sec.cells do
			local ps = st.panels[c.panel.__key]
			local build = panels.CHARTS[c.panel.type]
			if ps and ps.frames and build then
				local w, h = pixelSize(st, c)
				local key = string.format("%dx%d:%d:%s", w, h, ps.version, tostring(st.cursor))
				if ps.chartKey ~= key then
					local svg, note = build(c.panel, ps.frames, { w = w, h = h, from = st.from, to = st.to, cursor = st.cursor })
					ps.chart = if svg then st.cx:blob(svg, "image/svg+xml") else nil
					ps.chartKey, ps.chartNote, ps.chartError = key, if svg then note else nil, if svg then nil else note
				end
			end
		end
	end
end

--- View ------------------------------------------------------------------------------------------

local function panelCard(st: any, c: grafana.Placement): any
	local p = c.panel
	local ps: PanelState? = st.panels[p.__key]
	local title = grafana.interpolate(tostring(p.title or ""), st.vars, builtins(st))
	local body, note
	if not panels.NATIVE[p.type] then
		body = {
			ui.text(ui.span(string.format("%s panels draw only in Grafana", tostring(p.type)), "muted")),
			ui.button("Open in Grafana", { size = "sm", icon = "external-link", actions = { click = "panel=" .. tostring(p.id) } }),
		}
	elseif p.type == "text" then
		body = panels.body(p, {}, { ui = ui, interpolate = function(s) return grafana.interpolate(s, st.vars, builtins(st)) end })
	elseif ps and ps.frames then
		body, note = panels.body(p, ps.frames, {
			ui = ui,
			chart = ps.chart,
			interpolate = function(s) return grafana.interpolate(s, st.vars, builtins(st)) end,
			rules = ps.rules,
			dashboardUid = st.uid,
			now = now(),
			chartError = ps.chartError,
		})
		note = note or ps.chartNote
	elseif ps and #ps.errors > 0 then
		body = {}
	else
		body = { ui.text(ui.span("Loading…", "muted")) }
	end
	if ps and #ps.errors > 0 then
		local lines = {}
		for i, e in ps.errors do
			if i > 3 then break end
			table.insert(lines, ui.text(ui.span(e, "error")))
		end
		table.insert(body, 1, ui.col(lines))
	end
	if ps and #ps.notes > 0 then
		note = (if note then note .. " · " else "") .. "skipped " .. table.concat(ps.notes, ", ")
	end
	local meta = note
	if ps and ps.loading and ps.frames then meta = (if meta then meta .. " · " else "") .. "updating" end
	local card = ui.card(if title ~= "" then title else " ", body, { meta = meta, role = "grafana.panel", key = "card-" .. p.__key })
	local fit = nil
	if ps and ps.frames and panels.NATIVE[p.type] then
		local w, h = pixelSize(st, c)
		fit = panels.fitSize(p, ps.frames, w, h)
	end
	return ui.el("div", {
		class = "gf-cell",
		key = p.__key,
		attrs = {
			["data-h"] = tostring(math.clamp(c.h, 1, 48)),
			["data-type"] = tostring(p.type),
			["data-fit"] = fit and tostring(fit) or nil,
		},
	}, { card })
end

-- Nested 24-column grids from `grafana.tree`; equal gaps keep columns aligned across levels.
local function renderTree(st: any, node: grafana.Tree, key: string): any
	if node.kind == "panel" then return panelCard(st, node.cell) end
	local children = {}
	if node.kind == "stack" then
		for i, item in node.items do children[i] = renderTree(st, item, key .. "." .. i) end
		return ui.el("div", { class = "gf-stack", key = key }, children)
	end
	for i, item in node.items do
		children[i] = ui.el("div", { class = "gf-span", key = key .. ":" .. i, attrs = { ["data-w"] = tostring(item.w) } },
			if item.node then { renderTree(st, item.node, key .. ":" .. i) } else {})
	end
	return ui.el("div", { class = "gf-g" .. node.w, key = key }, children)
end

local function setupView(): any
	return ui.col({
		ui.card("Connect Grafana", {
			ui.md(table.concat({
				"Set the Grafana base URL, then reopen this block:",
				"",
				"- palette: **Set Grafana URL**, plus **Set Grafana token** when Grafana needs one, or",
				"- environment: `TERN_GRAFANA_URL` (and `TERN_GRAFANA_TOKEN` for a service account token).",
			}, "\n")),
		}, { icon = "gauge" }),
	})
end

local function listView(st: any): any
	local list = st.list or { items = {} }
	local rows = {}
	for _, d in list.items do
		local tags = if type(d.tags) == "table" then table.concat(d.tags, ", ") else ""
		table.insert(rows, { id = tostring(d.uid), cells = { tostring(d.title), tostring(d.folderTitle or "General"), tags } })
	end
	local children = {
		ui.row({ ui.text(ui.span("Grafana dashboards", "strong")), ui.text(ui.span(baseUrl() or "", "muted")) }),
	}
	if list.error then table.insert(children, ui.text(ui.span(list.error, "error"))) end
	table.insert(children, ui.table({
		{ id = "title", head = "Dashboard", grow = 2 },
		{ id = "folder", head = "Folder", grow = 1, priority = -1 },
		{ id = "tags", head = "Tags", grow = 1, priority = -2 },
	}, rows, { selectable = true, selected = list.sel, empty = if list.loading then "Loading…" else "No dashboards" }))
	return ui.col(children)
end

local function dashboardView(st: any): any
	local children = {}
	local head = { ui.text(ui.span(tostring(st.dash and st.dash.title or st.uid), "strong")) }
	for _, name in (if st.dash then grafana.varOrder(st.dash) else {}) do
		local v = st.vars[name]
		if v and v.def.hide ~= 2 and v.type ~= "constant" and v.type ~= "datasource" then
			table.insert(head, ui.badge("$" .. name .. " = " .. (if v.all then "All" else v.text), "info"))
		end
	end
	local status = st.rangeLabel or ""
	if st.updated then status ..= " · updated " .. chart.clock(st.updated) end
	if st.loading then status ..= " · loading" end
	table.insert(head, ui.text(ui.span(status, "muted")))
	local header = ui.row(head)
	header.p = header.p or {}
	header.p.role = "grafana.header"
	table.insert(children, header)
	if st.error then
		table.insert(children, ui.card("Could not load dashboard", { ui.text(ui.span(st.error, "error")) }, { tone = "error" }))
	end
	for _, sec in layout(st) do
		local row = sec.section.row
		if row then
			local title = grafana.interpolate(tostring(row.title or ""), st.vars, builtins(st))
			table.insert(children, ui.button((if sec.collapsed then "▸ " else "▾ ") .. title, {
				variant = "quiet",
				size = "sm",
				key = "row-" .. sec.key,
				actions = { click = "row=" .. sec.key },
				role = "grafana.row",
			}))
		end
		if #sec.cells > 0 then
			table.insert(children, renderTree(st, grafana.tree(sec.cells, 0, 24), "grid-" .. sec.key))
		end
	end
	return ui.col(children)
end

local function dock(st: any): any
	local items = {}
	if st.uid then
		for i, r in grafana.RANGES do
			table.insert(items, ui.button(r.label, {
				size = "sm",
				on = st.range == r.key,
				keys = { tostring(i) },
				actions = { click = "range=" .. r.key },
			}))
		end
		table.insert(items, ui.button("Saved", { size = "sm", on = st.range == nil, keys = { "0" }, actions = { click = "range=" } }))
		table.insert(items, ui.button("Refresh", { size = "sm", icon = "refresh", keys = { "r" }, actions = { click = "refresh" } }))
		table.insert(items, ui.button("Grafana", { size = "sm", icon = "external-link", keys = { "o" }, actions = { click = "open" } }))
		table.insert(items, ui.button(if st.cursor then "Crosshair " .. chart.cursorLabel(st.cursor, st.to - st.from) else "Crosshair", {
			size = "sm",
			on = st.cursor ~= nil,
			keys = if st.cursor then { "←", "→", "esc" } else { "←", "→" },
			actions = { click = "cursor" },
		}))
		table.insert(items, ui.button("Dashboards", { size = "sm", icon = "list", keys = { "l" }, actions = { click = "list" } }))
	else
		table.insert(items, ui.button("Open", { size = "sm", keys = { "enter" }, actions = { click = "pick" } }))
		table.insert(items, ui.button("Refresh", { size = "sm", icon = "refresh", keys = { "r" }, actions = { click = "refresh" } }))
	end
	return ui.col({ ui.row(items) })
end

--- Commands --------------------------------------------------------------------------------------

local function refresh(st: any)
	if st.uid then
		datasources = nil
		loadDashboard(st)
	else
		loadList(st)
	end
end

local function chooseRange(st: any, key: string?)
	st.range = if key == "" then nil else key
	if st.dash then
		setRange(st)
		queryVisible(st)
	end
	st.cx:save()
end

local function moveSelection(st: any, delta: number)
	local items = st.list and st.list.items or {}
	if #items == 0 then return end
	local idx = 1
	for i, d in items do
		if d.uid == st.list.sel then idx = i end
	end
	idx = math.clamp(idx + delta, 1, #items)
	st.list.sel = items[idx].uid
end

-- Moves the crosshair `steps` steps along the time range; the first move puts it at the range's end.
local function moveCursor(st: any, steps: number)
	if not st.dash or not st.from then return end
	if st.cursor == nil then
		st.cursor = st.to
	else
		st.cursor = math.clamp(st.cursor + steps * (st.to - st.from) / CURSOR_STEPS, st.from, st.to)
	end
end

local function act(st: any, name: string, value: string?)
	if name == "refresh" then
		refresh(st)
	elseif name == "range" then
		chooseRange(st, value)
	elseif name == "open" then
		local url = grafanaUrl(st, nil)
		if url then st.cx:open(url) end
	elseif name == "panel" then
		local url = grafanaUrl(st, value)
		if url then st.cx:open(url) end
	elseif name == "list" then
		showList(st)
	elseif name == "pick" then
		if st.list and st.list.sel then openDashboard(st, st.list.sel) end
	elseif name == "row" and value then
		local current = nil
		for _, sec in layout(st) do
			if sec.key == value then current = sec.collapsed end
		end
		st.collapsed[value] = not current
		if current then queryVisible(st) end
		st.cx:save()
	elseif name == "cursor" then
		if st.cursor then st.cursor = nil else moveCursor(st, 0) end
	end
	render(st)
end

tern.block.define("dashboard", {
	font = "sans",
	init = function(cx, args, saved)
		local st: any = {
			cx = cx,
			uid = args[1],
			range = nil,
			collapsed = {},
			panels = {},
			vars = {},
			gen = 0,
			draw = draw,
		}
		blocks[cx.pane] = st
		st.fail = function(err: any)
			st.error = "Plugin error: " .. tostring(err)
			st.loading = false
			render(st)
		end
		if type(saved) == "table" then
			st.uid = st.uid or saved.uid
			st.range = saved.range
			if type(saved.collapsed) == "table" then st.collapsed = saved.collapsed end
		end
		-- Defer IO until the block exists.
		tern.timer(0, function()
			local ok, err = pcall(if st.uid then loadDashboard else loadList, st)
			if not ok then st.fail(err) end
		end)
		return st
	end,
	title = function(st)
		if st.dash and st.dash.title then return "Grafana · " .. tostring(st.dash.title) end
		return "Grafana"
	end,
	view = function(st, cx)
		if st.cols ~= cx.cols then
			st.cols = cx.cols
			-- Chart images were sized for the old width.
			if st.dash then render(st) end
		end
		if not baseUrl() then return { main = setupView() } end
		if not st.uid then return { main = listView(st), dock = dock(st) } end
		local ok, main = pcall(dashboardView, st)
		if not ok then
			main = ui.col({ ui.text(ui.span("Could not draw this dashboard: " .. tostring(main), "err")) })
		end
		return { main = main, dock = dock(st) }
	end,
	key = function(st, key, _cx)
		if key.ctrl or key.alt or key.meta then return false end
		local n = key.name
		if n == "r" then
			act(st, "refresh", nil)
		elseif not st.uid then
			if n == "up" or n == "k" then
				moveSelection(st, -1)
			elseif n == "down" or n == "j" then
				moveSelection(st, 1)
			elseif n == "enter" then
				act(st, "pick", nil)
			else
				return false
			end
		elseif n == "o" then
			act(st, "open", nil)
		elseif n == "l" or n == "backspace" then
			act(st, "list", nil)
		elseif n == "0" then
			act(st, "range", "")
		elseif n == "left" or n == "right" then
			moveCursor(st, (if n == "left" then -1 else 1) * (if key.shift then 5 else 1))
			render(st)
		elseif (n == "escape" or n == "esc") and st.cursor then
			act(st, "cursor", nil)
		elseif n:match("^[1-9]$") and grafana.RANGES[tonumber(n) :: number] then
			act(st, "range", grafana.RANGES[tonumber(n) :: number].key)
		else
			return false
		end
		return true
	end,
	event = function(st, ev, _cx)
		if ev.ev == "action" and type(ev.act) == "string" then
			act(st, ev.act, ev.value)
		elseif ev.ev == "select" and not st.uid and st.list then
			st.list.sel = ev.item
			render(st)
		elseif ev.ev == "activate" and not st.uid and type(ev.item) == "string" then
			openDashboard(st, ev.item)
		end
	end,
	resize = function(st, newCols, _rows, _cx)
		st.cols = newCols
		local ok, err = pcall(draw, st)
		if not ok then print("grafana: draw failed: " .. tostring(err)) end
	end,
	save = function(st)
		return { uid = st.uid, range = st.range, collapsed = st.collapsed }
	end,
})

-- Marks blocks whose panes closed so their timers and callbacks stop.
local function sweep()
	tern.timer(10_000, sweep)
	local live = {}
	for _, pane in tern.pane.list() do live[pane.pane] = true end
	for pane, st in blocks do
		if not live[pane] then
			st.closed = true
			if st.timer then st.timer:cancel() end
			blocks[pane] = nil
		end
	end
end
tern.timer(10_000, sweep)

-- Redraws dashboards when the window records a new cell width (a font change, or a block restored before
-- any window reported one), since chart images are sized from it.
local lastCellPx = cellPx()
local function watchCellPx()
	tern.timer(2_000, watchCellPx)
	local px = cellPx()
	if px == lastCellPx then return end
	lastCellPx = px
	for _, st in blocks do
		if st.dash and not st.closed then render(st) end
	end
end
tern.timer(2_000, watchCellPx)
