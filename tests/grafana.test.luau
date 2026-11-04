local grafana = require("../grafana")

local function eq(got: any, want: any, what: string)
	assert(got == want, what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end

local DATASOURCES = { { uid = "prometheus", type = "prometheus", name = "Prometheus", isDefault = true } }
local function fleetDash()
	return { templating = { list = {
		{ name = "spot", type = "custom", current = { text = "Hide", value = "spot-pool" },
			options = { { text = "Show", value = "__none__" }, { text = "Hide", value = "spot-pool" } } },
		{ name = "host", type = "query", includeAll = true, multi = true,
			current = { text = { "All" }, value = { "$__all" } },
			query = { query = "label_values(up{instance!~\"$spot\"}, instance)" },
			datasource = { type = "prometheus", uid = "prometheus" } },
		{ name = "node", type = "query", current = {}, query = "label_values(node_uname_info, nodename)" },
	} } }
end

-- An All query variable saved without options is looked up, filtered by the variables it depends on,
-- and expands to every value (Grafana's behavior without allValue), so Loki's non-empty matcher rule holds.
do
	local vars = grafana.variables(fleetDash(), DATASOURCES)
	local path = grafana.varRequest(vars.host, vars, { from = 0, to = 0 }, DATASOURCES, 0, 60_000)
	assert(path, "All variable without options must be looked up")
	assert(path:find("/api/datasources/uid/prometheus/resources/api/v1/label/instance/values?", 1, true), path)
	assert(path:find("spot%-pool"), "dependent variable not interpolated: " .. path)
	grafana.resolveVar(vars.host, { "web-1", "db.local" })
	-- Values sit inside a double-quoted PromQL/LogQL string: metacharacters get an escaped backslash,
	-- and `-` (not a metacharacter there) stays bare; a bare `\-` is a query parse error.
	eq(grafana.interpolate('{host=~"$host"}', vars, { from = 0, to = 0 }, "loki"), '{host=~"(db\\\\.local|web-1)"}', "All expansion")
	-- A single-select variable is substituted as is.
	eq(grafana.interpolate('{i!~"$spot"}', vars, { from = 0, to = 0 }, "prometheus"), '{i!~"spot-pool"}', "single value")
	eq(vars.host.text, "All", "All label")
end

-- A single-value query variable without a saved value takes the first value, like Grafana's default.
do
	local vars = grafana.variables(fleetDash(), DATASOURCES)
	assert(grafana.varRequest(vars.node, vars, { from = 0, to = 0 }, DATASOURCES, 0, 0), "node lookup")
	grafana.resolveVar(vars.node, { "worker", "alpha" })
	eq(grafana.interpolate("x{nodename=\"$node\"}", vars, { from = 0, to = 0 }, "prometheus"), 'x{nodename="alpha"}', "first value")
	-- Once it has a value it is not looked up again.
	eq(grafana.varRequest(vars.node, vars, { from = 0, to = 0 }, DATASOURCES, 0, 0), nil, "resolved variable re-requested")
end

-- The SQLite backend runs queryText only; a dashboard stores rawQueryText.
do
	local panel = { datasource = { type = "frser-sqlite-datasource", uid = "metrics" },
		targets = { { refId = "A", rawQueryText = "SELECT stars FROM stars_daily WHERE unixepoch(date) >= $__from / 1000" } } }
	local qs, _, err = grafana.queries(panel, { vars = {}, builtins = { from = 5000, to = 9000 }, datasources = {},
		maxDataPoints = 600, rangeMs = 4000 })
	eq(err, nil, "sqlite query error")
	eq(qs[1].queryText, "SELECT stars FROM stars_daily WHERE unixepoch(date) >= 5000 / 1000", "sqlite queryText")
end

-- Layout trees: every panel appears exactly once, in rows whose spans add up to the parent width.
local function cell(id: number, x: number, y: number, w: number, h: number): any
	return { panel = { id = id }, x = x, y = y, w = w, h = h }
end
local function check(node: any, width: number, seen: { [number]: boolean })
	if node.kind == "panel" then
		assert(not seen[node.cell.panel.id], "panel drawn twice")
		seen[node.cell.panel.id] = true
	elseif node.kind == "stack" then
		for _, item in node.items do check(item, width, seen) end
	else
		eq(node.w, width, "row width")
		local sum = 0
		for _, item in node.items do
			sum += item.w
			if item.node then check(item.node, item.w, seen) end
		end
		eq(sum, width, "row spans")
	end
end
local function tree(cells: { any }): any
	local t = grafana.tree(cells, 0, 24)
	local seen = {}
	check(t, 24, seen)
	for _, c in cells do assert(seen[c.panel.id], "panel " .. c.panel.id .. " missing") end
	return t
end

do
	-- Fleet overview: four stats over a full-width table.
	local t = tree({ cell(1, 0, 0, 4, 5), cell(2, 4, 0, 4, 5), cell(3, 8, 0, 4, 5), cell(4, 12, 0, 12, 5), cell(5, 0, 5, 24, 16) })
	eq(t.kind, "stack", "bands")
	eq(t.items[1].kind, "row", "first band")
	eq(#t.items[1].items, 4, "first band spans")
	eq(t.items[2].kind, "panel", "full-width panel")
	-- A tall panel beside two stacked ones stays beside them.
	t = tree({ cell(1, 0, 0, 12, 10), cell(2, 12, 0, 12, 5), cell(3, 12, 5, 12, 5) })
	eq(t.kind, "row", "side by side")
	eq(t.items[2].node.kind, "stack", "right column stacks")
	-- A half-width panel on the right keeps its offset through a spacer.
	t = tree({ cell(1, 12, 0, 12, 4) })
	eq(t.items[1].node, nil, "spacer")
	eq(t.items[1].w, 12, "spacer width")
	-- A pinwheel has no straight cut; its panels stack in reading order.
	t = tree({ cell(1, 0, 0, 16, 4), cell(2, 16, 0, 8, 12), cell(3, 8, 4, 8, 4), cell(4, 0, 4, 8, 8), cell(5, 8, 8, 16, 4) })
	eq(t.kind, "stack", "pinwheel")
end

-- Relative times resolve against now; bad input is rejected rather than guessed.
do
	local now = 1_800_000_000_000
	eq(grafana.parseTime("now-6h", now), now - 6 * 3600e3, "now-6h")
	eq(grafana.parseTime("now", now), now, "now")
	eq(grafana.duration("1h30m"), 5400e3, "compound duration")
	eq(grafana.duration("soon"), nil, "bad duration")
end

print("grafana tests passed")
