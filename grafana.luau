-- The dashboard model: time ranges, template variables, query bodies for /api/ds/query and the grid
-- layout. Pure: no tern global.

local regex = require("./regex")

local M = {}

-- A shallow copy of list `t`; table.clone refuses tern.json tables (they carry a protected metatable).
local function copy<T>(t: { T }): { T }
	local out = table.create(#t)
	for i, v in t do out[i] = v end
	return out
end

--- Time ------------------------------------------------------------------------------------------

local UNIT_MS: { [string]: number } = {
	ms = 1, s = 1e3, m = 60e3, h = 3600e3, d = 86400e3, w = 7 * 86400e3, M = 30 * 86400e3, y = 365 * 86400e3,
}

-- "1m", "30s", "1h30m" -> ms; nil when unparseable.
function M.duration(s: any): number?
	if type(s) == "number" then return s end
	if type(s) ~= "string" or s == "" then return nil end
	local total, matched = 0, false
	for n, u in s:gmatch("(%d+%.?%d*)(%a+)") do
		local k = UNIT_MS[u]
		if not k then return nil end
		total += (tonumber(n) :: number) * k
		matched = true
	end
	return if matched then total else nil
end

local function daysFromCivil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = math.floor((153 * mp + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

-- ISO-8601 UTC ("2026-01-06T00:00:00.000Z") -> epoch ms.
function M.iso(s: string): number?
	local y, mo, d, h, mi, sec = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):?(%d*%.?%d*)")
	if not y then
		y, mo, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
		if not y then return nil end
		h, mi, sec = "0", "0", "0"
	end
	local days = daysFromCivil(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number)
	local secs = days * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(sec) or 0)
	local off = s:match("([%+%-]%d%d):?%d%d$")
	if off then
		local sign = if off:sub(1, 1) == "-" then -1 else 1
		local oh = tonumber(off:sub(2, 3)) :: number
		local om = tonumber(s:match("[%+%-]%d%d:?(%d%d)$")) :: number
		secs -= sign * (oh * 3600 + om * 60)
	end
	return secs * 1000
end

local function startOfLocalDay(ms: number): number
	local t = os.date("*t", math.floor(ms / 1000)) :: any
	t.hour, t.min, t.sec = 0, 0, 0
	return os.time(t) * 1000
end

-- "now", "now-6h", "now/d", ISO or epoch ms -> epoch ms. `isTo` rounds `/d` to the end of the day.
function M.parseTime(s: any, now: number, isTo: boolean?): number?
	if type(s) == "number" then return s end
	if type(s) ~= "string" then return nil end
	if s:match("^%d+$") then return tonumber(s) end
	if s:sub(1, 3) == "now" then
		local rest = s:sub(4)
		local t = now
		local rounding = rest:match("/(%a)$")
		if rounding then rest = rest:sub(1, -3) end
		for sign, n, u in rest:gmatch("([%+%-])(%d+)(%a+)") do
			local k = UNIT_MS[u]
			if not k then return nil end
			t += (if sign == "-" then -1 else 1) * (tonumber(n) :: number) * k
		end
		if rounding == "d" then
			t = startOfLocalDay(t)
			if isTo then t += 86400e3 - 1 end
		elseif rounding == "h" then
			t = math.floor(t / 3600e3) * 3600e3
			if isTo then t += 3600e3 - 1 end
		end
		return t
	end
	return M.iso(s)
end

M.RANGES = {
	{ key = "15m", label = "15m", from = "now-15m" },
	{ key = "1h", label = "1h", from = "now-1h" },
	{ key = "6h", label = "6h", from = "now-6h" },
	{ key = "24h", label = "24h", from = "now-24h" },
	{ key = "7d", label = "7d", from = "now-7d" },
	{ key = "30d", label = "30d", from = "now-30d" },
}

-- The effective range: a preset key, else the dashboard's saved time.
function M.range(dash: any, key: string?, now: number): (number, number, string)
	for _, r in M.RANGES do
		if r.key == key then return (M.parseTime(r.from, now) :: number), now, "Last " .. r.label end
	end
	local time = type(dash) == "table" and dash.time or {}
	local from = M.parseTime(time.from or "now-6h", now) or (now - 6 * 3600e3)
	local to = M.parseTime(time.to or "now", now, true) or now
	if to <= from then to = from + 1 end
	local label = tostring(time.from or "now-6h") .. " to " .. tostring(time.to or "now")
	local preset = tostring(time.from or ""):match("^now%-(%d+%a)$")
	if preset and (time.to == nil or time.to == "now") then label = "Last " .. preset end
	return from, to, label
end

local NICE_INTERVALS = {
	1, 10, 20, 50, 100, 200, 500, 1e3, 2e3, 5e3, 10e3, 15e3, 20e3, 30e3, 60e3, 120e3, 300e3, 600e3, 900e3,
	1200e3, 1800e3, 3600e3, 7200e3, 10800e3, 21600e3, 43200e3, 86400e3, 604800e3, 2592000e3,
}

function M.interval(rangeMs: number, maxPoints: number, minInterval: number?): number
	local raw = math.max(rangeMs / math.max(maxPoints, 1), minInterval or 0)
	for _, n in NICE_INTERVALS do
		if n >= raw then return n end
	end
	return NICE_INTERVALS[#NICE_INTERVALS]
end

export type Var = { name: string, type: string, values: { string }, text: string, all: boolean, allValue: string?, def: any }

local function strings(v: any): { string }
	if type(v) == "table" then
		local out = {}
		for _, x in v do table.insert(out, tostring(x)) end
		return out
	end
	if v == nil then return {} end
	return { tostring(v) }
end

-- The dashboard's variables at their saved values; "All" expands to the saved options or allValue.
function M.variables(dash: any, datasources: { any }): { [string]: Var }
	local out: { [string]: Var } = {}
	local list = type(dash) == "table" and type(dash.templating) == "table" and dash.templating.list or {}
	for _, v in list do
		if type(v) == "table" and type(v.name) == "string" then
			local cur = type(v.current) == "table" and v.current or {}
			local values = strings(cur.value)
			local all = table.find(values, "$__all") ~= nil
			if all then
				values = {}
				for _, o in (if type(v.options) == "table" then v.options else {}) do
					local ov = tostring(o.value)
					if ov ~= "$__all" then table.insert(values, ov) end
				end
			end
			if v.type == "datasource" then
				local want = values[1]
				local pick = nil
				for _, ds in datasources do
					if (want == nil or want == "default") and ds.isDefault and (v.query == nil or ds.type == v.query) then pick = ds end
					if ds.uid == want or ds.name == want then pick = ds end
				end
				if not pick then
					for _, ds in datasources do
						if ds.type == v.query then
							pick = ds
							break
						end
					end
				end
				values = if pick then { pick.uid } else values
			elseif v.type == "constant" and #values == 0 and v.query ~= nil then
				values = { tostring(v.query) }
			end
			local text = cur.text
			if type(text) == "table" then text = table.concat(strings(text), " + ") end
			out[v.name] = {
				name = v.name,
				type = tostring(v.type),
				values = values,
				text = if text ~= nil then tostring(text) else table.concat(values, ", "),
				all = all,
				allValue = if type(v.allValue) == "string" and v.allValue ~= "" then v.allValue else nil,
				def = v,
			}
		end
	end
	return out
end

-- Variables in definition order (for resolving dependent query variables one after another).
function M.varOrder(dash: any): { string }
	local out = {}
	local list = type(dash) == "table" and type(dash.templating) == "table" and dash.templating.list or {}
	for _, v in list do
		if type(v) == "table" and type(v.name) == "string" then table.insert(out, v.name) end
	end
	return out
end

function M.urlencode(s: string): string
	return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

-- The datasource resource path listing a query variable's values, when it has no saved value and its
-- query is a label lookup Level 1 understands (Prometheus `label_values`, Loki label queries).
function M.varRequest(var: Var, vars: { [string]: Var }, b: Builtins, datasources: { any }, from: number, to: number): string?
	if var.type ~= "query" or #var.values > 0 then return nil end
	local def = var.def
	local ds = M.datasource(def.datasource, vars, b, datasources)
	if not ds or type(ds.uid) ~= "string" then return nil end
	local base = "/api/datasources/uid/" .. M.urlencode(ds.uid) .. "/resources/"
	local q = def.query
	if ds.type == "loki" and type(q) == "table" and type(q.label) == "string" then
		local path = base .. "label/" .. M.urlencode(q.label) .. "/values"
		if type(q.stream) == "string" and q.stream ~= "" then
			path ..= "?query=" .. M.urlencode(M.interpolate(q.stream, vars, b, "loki"))
		end
		return path
	end
	local text = if type(q) == "table" then q.query else q
	if type(text) ~= "string" then return nil end
	text = M.interpolate(text, vars, b, "prometheus")
	local metric, label = text:match("^%s*label_values%(%s*(.-)%s*,%s*([%w_]+)%s*%)%s*$")
	if not metric then
		label = text:match("^%s*label_values%(%s*([%w_]+)%s*%)%s*$")
	end
	if not label then return nil end
	local path = base .. "api/v1/label/" .. label .. "/values?start=" .. math.floor(from / 1000) .. "&end=" .. math.floor(to / 1000)
	if metric and metric ~= "" then path ..= "&match[]=" .. M.urlencode(metric) end
	return path
end

-- Applies the values a `varRequest` returned: all of them for an All variable (Grafana expands All
-- without allValue to every option), else the first.
function M.resolveVar(var: Var, data: any)
	if type(data) ~= "table" then return end
	local values = {}
	for _, v in data do
		if type(v) == "string" then table.insert(values, v) end
	end
	table.sort(values)
	if #values == 0 then return end
	if var.all then
		var.values, var.text = values, "All"
	else
		var.values, var.text = { values[1] }, values[1]
	end
end

local function regexEscape(s: string): string
	return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?{}|\\/]", function(c) return "\\" .. c end))
end

-- Prometheus and Loki interpolate into double-quoted strings, so regex metacharacters carry an
-- escaped backslash (Grafana's prometheusSpecialRegexEscape / lokiSpecialRegexEscape).
local function quotedRegexEscape(s: string): string
	return (s:gsub("\\", "\\\\\\\\"):gsub("[%$%^%*{}%[%]'%+%?%.%(%)|]", function(c) return "\\\\" .. c end))
end

local function formatVar(var: Var, fmt: string?, dsType: string?): string
	if var.all and var.allValue then return var.allValue end
	local vals = var.values
	if var.all and #vals == 0 then return ".*" end
	local f = fmt
	if (f == nil or f == "") and (dsType == "prometheus" or dsType == "loki") then
		local def = var.def or {}
		if not (def.multi or def.includeAll) then
			return ((vals[1] or ""):gsub("\\", "\\\\"):gsub("'", "\\\\'"))
		end
		local esc = {}
		for i, v in vals do esc[i] = quotedRegexEscape(v) end
		if #esc == 1 then return esc[1] end
		return "(" .. table.concat(esc, "|") .. ")"
	end
	if f == nil or f == "" then
		if #vals <= 1 then return vals[1] or "" end
		f = if dsType == nil then "regex" else "singlequote"
	end
	if f == "raw" or f == "text" then return if f == "text" then var.text else table.concat(vals, ",") end
	if f == "csv" then return table.concat(vals, ",") end
	if f == "pipe" then return table.concat(vals, "|") end
	if f == "regex" then
		local esc = {}
		for i, v in vals do esc[i] = regexEscape(v) end
		if #esc == 1 then return esc[1] end
		return "(" .. table.concat(esc, "|") .. ")"
	end
	if f == "singlequote" or f == "sqlstring" then
		local q = {}
		for i, v in vals do q[i] = "'" .. v:gsub("'", "''") .. "'" end
		return table.concat(q, ",")
	end
	if f == "doublequote" then
		local q = {}
		for i, v in vals do q[i] = "\"" .. v:gsub("\"", "\\\"") .. "\"" end
		return table.concat(q, ",")
	end
	if f == "glob" then return if #vals == 1 then vals[1] else "{" .. table.concat(vals, ",") .. "}" end
	if f == "json" then
		local q = {}
		for i, v in vals do q[i] = "\"" .. v:gsub("\\", "\\\\"):gsub("\"", "\\\"") .. "\"" end
		return "[" .. table.concat(q, ",") .. "]"
	end
	return table.concat(vals, ",")
end

export type Builtins = { from: number, to: number, dashboard: string? }

local function builtin(name: string, fmt: string?, b: Builtins): string?
	if name == "__from" or name == "__to" then
		local ms = if name == "__from" then b.from else b.to
		if fmt == "date:seconds" then return tostring(math.floor(ms / 1000)) end
		if fmt == "date" or fmt == "date:iso" then
			return os.date("!%Y-%m-%dT%H:%M:%S.000Z", math.floor(ms / 1000)) :: string
		end
		return string.format("%d", ms)
	end
	if name == "__dashboard" then return b.dashboard end
	return nil
end

-- Substitutes `$var`, `${var}`, `${var:fmt}` and `[[var]]`; unknown names (server macros) stay.
function M.interpolate(s: string, vars: { [string]: Var }, b: Builtins, dsType: string?): string
	local function sub(name: string, fmt: string?): string?
		local v = vars[name]
		if v then return formatVar(v, fmt, dsType) end
		return builtin(name, fmt, b)
	end
	s = s:gsub("%${([%w_]+):?([^}]*)}", function(name, fmt)
		return sub(name, if fmt ~= "" then fmt else nil)
	end)
	s = s:gsub("%[%[([%w_]+)%]%]", function(name) return sub(name, nil) end)
	s = s:gsub("%$([%w_]+)", function(name) return sub(name, nil) end)
	return s
end

function M.interpolateDeep(t: any, vars: { [string]: Var }, b: Builtins, dsType: string?): any
	if type(t) == "string" then return M.interpolate(t, vars, b, dsType) end
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in t do out[k] = M.interpolateDeep(v, vars, b, dsType) end
	return out
end

local function deepCopy(t: any): any
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in t do out[k] = deepCopy(v) end
	return out
end

-- Interpolates every string inside `t` (a private copy) in place, keeping its tables, so JSON arrays
-- stay tagged and an empty one still encodes as `[]`.
local function interpolateInPlace(t: any, vars: { [string]: Var }, b: Builtins, dsType: string?)
	for k, v in t do
		if type(v) == "string" then
			t[k] = M.interpolate(v, vars, b, dsType)
		elseif type(v) == "table" then
			interpolateInPlace(v, vars, b, dsType)
		end
	end
end

--- Queries ---------------------------------------------------------------------------------------

local MIXED = "-- Mixed --"
local DASHBOARD_DS = "-- Dashboard --"

-- {uid, type} for a datasource reference (object, name string, variable or nil).
function M.datasource(ref: any, vars: { [string]: Var }, b: Builtins, datasources: { any }): any
	local uid, typ
	if type(ref) == "table" then
		uid, typ = ref.uid, ref.type
	elseif type(ref) == "string" then
		uid = ref
	end
	if type(uid) == "string" then uid = M.interpolate(uid, vars, b) end
	if uid == nil or uid == "default" or uid == "" then
		for _, ds in datasources do
			if ds.isDefault then return { uid = ds.uid, type = ds.type } end
		end
		return nil
	end
	for _, ds in datasources do
		if ds.uid == uid or ds.name == uid then return { uid = ds.uid, type = ds.type } end
	end
	return { uid = uid, type = typ }
end

export type QueryCtx = {
	vars: { [string]: Var },
	builtins: Builtins,
	datasources: { any },
	maxDataPoints: number,
	rangeMs: number,
	-- A deep copy that keeps JSON array tags (Tern: decode(encode(t))); plain copies lose empty arrays.
	clone: ((any) -> any)?,
}

-- The /api/ds/query queries of a panel, the refIds in order, and an error when it cannot run.
function M.queries(panel: any, ctx: QueryCtx): ({ any }, { string }, string?)
	local targets = type(panel.targets) == "table" and panel.targets or {}
	local panelRef = panel.datasource
	local panelUid = if type(panelRef) == "table" then panelRef.uid elseif type(panelRef) == "string" then panelRef else nil
	if panelUid == DASHBOARD_DS then return {}, {}, "Queries from another panel (-- Dashboard --) are not supported" end
	local hasExpr = false
	for _, t in targets do
		if type(t) == "table" and type(t.datasource) == "table" and (t.datasource.type == "__expr__" or t.datasource.uid == "__expr__") then
			hasExpr = true
		end
	end
	local maxPoints = if type(panel.maxDataPoints) == "number" then panel.maxDataPoints else ctx.maxDataPoints
	local minInterval = M.duration(if type(panel.interval) == "string" then M.interpolate(panel.interval, ctx.vars, ctx.builtins) else nil)
	local intervalMs = M.interval(ctx.rangeMs, maxPoints, minInterval)
	local out, refs = {}, {}
	for i, t in targets do
		if type(t) ~= "table" or (t.hide == true and not hasExpr) then continue end
		local isExpr = type(t.datasource) == "table" and (t.datasource.type == "__expr__" or t.datasource.uid == "__expr__")
		local ds
		if isExpr then
			ds = { uid = "__expr__", type = "__expr__" }
		elseif t.datasource ~= nil and (panelUid == MIXED or panelUid == nil or type(t.datasource) == "table") then
			ds = M.datasource(t.datasource, ctx.vars, ctx.builtins, ctx.datasources)
		else
			ds = M.datasource(panelRef, ctx.vars, ctx.builtins, ctx.datasources)
		end
		if ds == nil then return {}, {}, "No datasource for query " .. tostring(t.refId or i) end
		if ds.uid == MIXED or ds.uid == DASHBOARD_DS then return {}, {}, "Unsupported datasource " .. ds.uid end
		local q = (ctx.clone or deepCopy)(t)
		interpolateInPlace(q, ctx.vars, ctx.builtins, ds.type)
		q.datasource = ds
		q.refId = t.refId or string.char(64 + i)
		q.maxDataPoints = maxPoints
		q.intervalMs = intervalMs
		if ds.type == "loki" and panel.type == "logs" then
			q.maxLines = math.min(tonumber(t.maxLines) or 200, 500)
		end
		-- The SQLite plugin's backend runs `queryText`, which its frontend fills from `rawQueryText`.
		if ds.type == "frser-sqlite-datasource" and type(q.rawQueryText) == "string" then
			q.queryText = q.rawQueryText
		end
		table.insert(out, q)
		table.insert(refs, q.refId)
	end
	if #out == 0 then return {}, {}, "No queries" end
	return out, refs, nil
end

--- Layout ----------------------------------------------------------------------------------------

export type Section = { row: any?, collapsed: boolean, panels: { any } }

local function byPos(a: any, b: any): boolean
	local ga, gb = a.gridPos or {}, b.gridPos or {}
	local ya, yb = ga.y or 0, gb.y or 0
	if ya ~= yb then return ya < yb end
	return (ga.x or 0) < (gb.x or 0)
end

-- Top-level panels grouped under their row panels (collapsed rows carry their own panels).
function M.sections(dash: any): { Section }
	local panels = copy(type(dash.panels) == "table" and dash.panels or {})
	table.sort(panels, byPos)
	local out: { Section } = {}
	local cur: Section = { row = nil, collapsed = false, panels = {} }
	for _, p in panels do
		if type(p) ~= "table" then continue end
		if p.type == "row" then
			if cur.row ~= nil or #cur.panels > 0 then table.insert(out, cur) end
			local inner = if p.collapsed and type(p.panels) == "table" then copy(p.panels) else {}
			table.sort(inner, byPos)
			cur = { row = p, collapsed = p.collapsed == true, panels = inner }
		else
			table.insert(cur.panels, p)
		end
	end
	if cur.row ~= nil or #cur.panels > 0 then table.insert(out, cur) end
	return out
end

export type Placement = { panel: any, x: number, y: number, w: number, h: number }

-- Grid cells (24 columns, rows of 30 px) after Grafana's vertical compaction; `narrow` stacks panels.
function M.place(panels: { any }, narrow: boolean): { Placement }
	local heights = table.create(24, 0)
	local out: { Placement } = {}
	for _, p in panels do
		local g = p.gridPos or {}
		local w = math.clamp(math.floor(g.w or 12), 1, 24)
		local x = math.clamp(math.floor(g.x or 0), 0, 24 - w)
		local h = math.max(1, math.floor(g.h or 8))
		if narrow then
			x, w = 0, 24
		end
		local y = 0
		for c = x + 1, x + w do
			if heights[c] > y then y = heights[c] end
		end
		for c = x + 1, x + w do heights[c] = y + h end
		table.insert(out, { panel = p, x = x, y = y, w = w, h = h })
	end
	return out
end

-- A nesting of rows and stacks that reproduces placed panels without absolute grid placement:
-- horizontal cuts give stacked bands, vertical cuts give side-by-side spans of `w` columns (a span
-- without `node` is empty space). Layouts with no clean cut stack their panels in reading order.
export type Tree =
	{ kind: "panel", cell: Placement }
	| { kind: "stack", items: { Tree } }
	| { kind: "row", w: number, items: { { w: number, node: Tree? } } }

function M.tree(cells: { Placement }, x0: number, W: number): Tree
	if #cells == 1 then
		local c = cells[1]
		if c.x <= x0 and c.w >= W then return { kind = "panel", cell = c } end
		local items: { { w: number, node: Tree? } } = {}
		if c.x > x0 then table.insert(items, { w = c.x - x0 }) end
		table.insert(items, { w = c.w, node = { kind = "panel", cell = c } })
		local rest = x0 + W - (c.x + c.w)
		if rest > 0 then table.insert(items, { w = rest }) end
		return { kind = "row", w = W, items = items }
	end
	local byY = copy(cells)
	table.sort(byY, function(a, b)
		if a.y ~= b.y then return a.y < b.y end
		return a.x < b.x
	end)
	local bands: { { Placement } } = {}
	local cur: { Placement }? = nil
	local bottom = 0
	for _, c in byY do
		if cur and c.y >= bottom then
			table.insert(bands, cur)
			cur = nil
		end
		if not cur then
			cur, bottom = {}, c.y + c.h
		else
			bottom = math.max(bottom, c.y + c.h)
		end
		table.insert(cur :: { Placement }, c)
	end
	if cur then table.insert(bands, cur) end
	if #bands > 1 then
		local items = {}
		for i, band in bands do items[i] = M.tree(band, x0, W) end
		return { kind = "stack", items = items }
	end
	local byX = copy(cells)
	table.sort(byX, function(a, b) return a.x < b.x end)
	local groups: { { Placement } } = {}
	local right = 0
	local g: { Placement }? = nil
	for _, c in byX do
		if g and c.x >= right then
			table.insert(groups, g)
			g = nil
		end
		if not g then
			g, right = {}, c.x + c.w
		else
			right = math.max(right, c.x + c.w)
		end
		table.insert(g :: { Placement }, c)
	end
	if g then table.insert(groups, g) end
	if #groups > 1 then
		local items: { { w: number, node: Tree? } } = {}
		local pos = x0
		for _, grp in groups do
			local gx, gr = math.huge, 0
			for _, c in grp do
				gx = math.min(gx, c.x)
				gr = math.max(gr, c.x + c.w)
			end
			if gx > pos then table.insert(items, { w = gx - pos }) end
			table.insert(items, { w = gr - gx, node = M.tree(grp, gx, gr - gx) })
			pos = gr
		end
		if pos < x0 + W then table.insert(items, { w = x0 + W - pos }) end
		return { kind = "row", w = W, items = items }
	end
	local items = {}
	for i, c in byY do items[i] = M.tree({ c }, x0, W) end
	return { kind = "stack", items = items }
end

-- Whether a regex-style text matches (re-exported for panels' reduceOptions.fields).
M.match = regex.test

return M
