local panels = require("../panels")
local frames = require("../frames")
local chart = require("../chart")

local function eq(got: any, want: any, what: string)
	assert(got == want, what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end
local function count(s: string, pattern: string): number
	local n = 0
	for _ in s:gmatch(pattern) do n += 1 end
	return n
end

-- State lanes: a value lasts until the next sample unless the next is more than two intervals away;
-- equal neighbours merge, missing values leave gaps.
do
	local cfg = { mappings = { { type = "value", options = {
		["1"] = { text = "Up", color = "green", index = 0 },
		["2"] = { text = "Down", color = "red", index = 1 },
	} } } }
	local tf = { name = "Time", type = "time", config = {}, values = { 0, 60, 120, 300, 360, 420 } }
	local f = { name = "Value", type = "number", config = { interval = 60 }, cfg = cfg, values = { 1, 1, 2, 2, false, 1 } }
	local segs = panels.stateLanes(tf, f, 1000, true)
	eq(#segs, 4, "segments")
	eq(segs[1].from, 0, "first from")
	eq(segs[1].to, 120, "equal neighbours merge")
	eq(segs[1].text, "Up", "mapped text")
	eq(segs[1].color, "#73BF69", "mapped color")
	eq(segs[2].to, 180, "a long gap ends the state after one interval")
	eq(segs[3].from, 300, "no merge across a gap")
	eq(segs[3].to, 360, "lasts until the next sample")
	eq(segs[4].from, 420, "missing value leaves a gap")
	eq(segs[4].to, 480, "the last sample lasts one interval")
	eq(#panels.stateLanes(tf, f, 1000, false), 5, "mergeValues off keeps every sample")
end

-- Legends list mapping states in mapping order.
do
	local panel = {
		options = { legend = { showLegend = true } },
		fieldConfig = {},
	}
	local cfg = { mappings = { { type = "value", options = {
		["0"] = { text = "Away", color = "dark-gray", index = 1 },
		["1"] = { text = "Active", color = "green", index = 0 },
	} } } }
	local fs = { { fields = {
		{ name = "Time", type = "time", config = {}, values = { 1767225600000, 1767225660000 } },
		{ name = "Value", type = "number", config = {}, cfg = cfg, display = "Human", values = { 1, 0 } },
	} } }
	local svg = panels.timelineSvg(panel, fs, { w = 600, h = 120, from = 1767225600000, to = 1767225720000 }) :: string
	local a, b = svg:find(">Active<", 1, true), svg:find(">Away<", 1, true)
	assert(a and b and a < b, "legend follows mapping index")
	assert(svg:find("#A9A9A9", 1, true), "dark-gray reads as CSS darkgray")
end

eq(frames.hex("gray"), "#808080", "CSS gray")
eq(frames.hex("text"), nil, "text has no fixed hex")

-- Bar charts: one bar per finite value, against the panel's xField.
do
	local fs = { { fields = {
		{ name = "hour", type = "number", config = {}, cfg = {}, values = { 9, 10, 11 } },
		{ name = "Words", type = "number", config = {}, cfg = {}, values = { 100, false, 300 } },
		{ name = "WPM", type = "number", config = {}, cfg = { custom = { axisPlacement = "right" } }, values = { 120, 130, 140 } },
	} } }
	local panel = { options = { xField = "hour", showValue = "never", legend = { showLegend = false } } }
	local svg = panels.barchartSvg(panel, fs, { w = 600, h = 300, from = 0, to = 1 }) :: string
	eq(count(svg, "<rect"), 5, "bars")
	assert(svg:find(">10<", 1, true), "hour labels")
	assert(not svg:find("No data", 1, true), "data drawn")
	local pct = chart.bars({
		{ name = "a", color = "#000", values = { 1, 3 } },
		{ name = "b", color = "#111", values = { 1, 1 } },
	}, { w = 400, h = 200, labels = { "x", "y" }, stacking = "percent", legend = false })
	assert(pct:find(">100%<", 1, true), "percent stacking scales to 100%")
	local nofield = { { fields = { { name = "v", type = "number", config = {}, cfg = {}, values = { 1 } } } } }
	local none, why = panels.barchartSvg({ options = {} }, nofield, { w = 400, h = 200, from = 0, to = 1 })
	eq(none, nil, "no x field")
	assert(why and why:find("string or time"), "says why")
end

-- Alert lists filter instances by state and labels, then sort rules.
do
	local data = { groups = {
		{ folderUid = "f1", rules = {
			{ name = "Disk full", uid = "disk", type = "alerting", annotations = {}, alerts = {
				{ state = "Normal (NoData)", labels = { severity = "warning" }, activeAt = "2026-01-01T00:00:00Z" },
			} },
			{ name = "CI red", uid = "ci", type = "alerting", annotations = { __dashboardUid__ = "dash" }, alerts = {
				{ state = "Alerting", labels = { severity = "critical" }, activeAt = "2026-01-01T00:00:00Z" },
				{ state = "Pending", labels = { severity = "critical" }, activeAt = "2026-01-01T00:30:00Z" },
			} },
		} },
		{ folderUid = "f2", rules = {
			{ name = "Backup late", uid = "bk", type = "alerting", annotations = {}, alerts = {
				{ state = "Pending", labels = { severity = "warning" }, activeAt = "2026-01-01T01:00:00Z" },
			} },
		} },
	} }
	local ctx = { interpolate = function(s: string) return s end, dashboardUid = "dash" }
	local function items(opts: any): { panels.AlertItem }
		local out = panels.alertItems({ options = opts }, data, ctx)
		return out
	end
	local active = { firing = true, pending = true, noData = true, error = true, normal = false }
	local list = items({ stateFilter = active, sortOrder = 1 })
	eq(#list, 2, "rules with matching instances")
	eq(list[1].name, "Backup late", "alphabetical")
	eq(list[2].state, "firing", "a rule shows its most important instance")
	eq(list[2].count, 2, "instances counted")
	eq(list[2].since, 1767225600000, "since the firing instance became active")
	eq(items({ stateFilter = active, sortOrder = 3 })[1].name, "CI red", "importance puts firing first")
	eq(items({ stateFilter = active, sortOrder = 2 })[1].name, "CI red", "reverse alphabetical")
	eq(#items({ stateFilter = active, showInactiveAlerts = true }), 3, "rules without matching instances")
	eq(items({ stateFilter = { normal = true } })[1].name, "Disk full", "Normal (NoData) is normal")
	eq(#items({ stateFilter = active, alertName = "ci" }), 1, "name filter")
	eq(#items({ stateFilter = active, dashboardAlerts = true }), 1, "this dashboard's alerts")
	eq(#items({ stateFilter = active, folder = { uid = "f2" } }), 1, "folder")
	eq(items({ stateFilter = active, alertInstanceLabelFilter = "{severity=~\"crit.*\"}" })[1].name, "CI red", "label regex")
	eq(#items({ stateFilter = active, alertInstanceLabelFilter = "severity!=\"critical\"" }), 1, "negative matcher")
	eq(#items({ stateFilter = active, maxItems = 1 }), 1, "maxItems")
	local grouped = items({ stateFilter = active, groupMode = "custom", groupBy = { "severity" } })
	eq(#grouped, 2, "custom groups by label")
	eq(grouped[1].name, "severity=critical", "group name")
	local _, err = panels.alertItems({ options = { alertInstanceLabelFilter = "severity" } }, data, ctx)
	assert(err, "unparsable label filter")
end

-- Crosshair lookups take the nearer finite sample around the cursor, within the limit.
do
	local t = { 0, 10, 20, 30 }
	local v = { 1, 2, false, 4 }
	eq(chart.nearest(t, v, 13, 100), 2, "nearer sample")
	eq(chart.nearest(t, v, 18, 100), 2, "a missing value yields to its neighbour")
	eq(chart.nearest(t, v, 26, 100), 4, "after a missing value")
	eq(chart.nearest(t, v, 18, 5), nil, "nothing within the limit")
	eq(chart.nearest(t, v, -50, 100), 1, "before the first sample")
	eq(chart.nearest(t, v, 99, 100), 4, "after the last sample")
	eq(chart.nearest({}, {}, 5, 100), nil, "no samples")
end

-- Crosshair panels. Times sit in 2026: local time zone lookups fail near the epoch. Values avoid the axis tick labels.
local B = 1767225600000

-- Time series crosshairs list each series' value at the cursor in the panel's tooltip order.
do
	local tf = { name = "Time", type = "time", config = {}, values = { B, B + 60e3, B + 120e3 } }
	local fs = { { fields = {
		tf,
		{ name = "low", type = "number", config = { interval = 60e3 }, cfg = { unit = "ms" }, values = { 1, 3, 7 } },
		{ name = "high", type = "number", config = { interval = 60e3 }, cfg = { unit = "ms" }, values = { 11, 21, false } },
	} } }
	local function svgAt(cursor: number?, tooltip: any): string
		local panel = { options = { legend = { showLegend = false }, tooltip = tooltip } }
		return panels.timeseriesSvg(panel, fs, { w = 600, h = 200, from = B, to = B + 120e3, cursor = cursor }) :: string
	end
	local svg = svgAt(B + 60e3, { mode = "multi", sort = "desc" })
	local hi, lo = svg:find(">21 ms<", 1, true), svg:find(">3 ms<", 1, true)
	assert(hi and lo and hi < lo, "values at the cursor, largest first")
	eq(count(svg, "<circle"), 2, "a dot per series")
	local tail = svgAt(B + 120e3, { mode = "multi", sort = "asc" })
	local seven, dash = tail:find(">7 ms<", 1, true), tail:find(">–<", 1, true)
	assert(seven and dash and seven < dash, "a series without a value shows a dash, sorted last")
	assert(not svgAt(nil, nil):find("stroke-dasharray=\"3 3\"", 1, true), "no cursor, no crosshair")
	assert(not svgAt(B + 500e3, nil):find("stroke-dasharray=\"3 3\"", 1, true), "a cursor outside the range draws nothing")
	local hidden = svgAt(B + 60e3, { mode = "none" })
	assert(hidden:find("stroke-dasharray=\"3 3\"", 1, true) and not hidden:find(">21 ms<", 1, true), "tooltips off keep only the line")
end

-- State timeline crosshairs show each lane's state at the cursor; bar charts take it only on a time x field.
do
	local cfg = { mappings = { { type = "value", options = {
		["1"] = { text = "Up", color = "green", index = 0 },
		["2"] = { text = "Down", color = "red", index = 1 },
	} } } }
	local fs = { { fields = {
		{ name = "Time", type = "time", config = {}, values = { B, B + 60e3 } },
		{ name = "Value", type = "number", config = { interval = 60e3 }, cfg = cfg, values = { 1, 2 } },
	} } }
	local panel = { options = { showValue = "never", legend = { showLegend = false } } }
	local at = panels.timelineSvg(panel, fs, { w = 600, h = 200, from = B, to = B + 120e3, cursor = B + 90e3 }) :: string
	assert(at:find(">Down<", 1, true) and not at:find(">Up<", 1, true), "the state under the cursor")
	local gap = panels.timelineSvg(panel, fs, { w = 600, h = 200, from = B, to = B + 150e3, cursor = B + 130e3 }) :: string
	assert(gap:find(">–<", 1, true), "no state after the last one ends")

	local bars = { { fields = {
		{ name = "Time", type = "time", config = {}, values = { B, B + 60e3, B + 120e3 } },
		{ name = "n", type = "number", config = {}, cfg = {}, values = { 11, 17, 23 } },
	} } }
	local bp = { options = { showValue = "never", legend = { showLegend = false } } }
	local near = panels.barchartSvg(bp, bars, { w = 600, h = 300, from = B, to = B + 120e3, cursor = B + 70e3 }) :: string
	assert(near:find(">17<", 1, true) and not near:find(">11<", 1, true), "the bar nearest the cursor")
	local cats = { { fields = {
		{ name = "host", type = "string", config = {}, cfg = {}, values = { "a", "b" } },
		{ name = "n", type = "number", config = {}, cfg = {}, values = { 11, 17 } },
	} } }
	local plain = panels.barchartSvg(bp, cats, { w = 600, h = 300, from = B, to = B + 120e3, cursor = B + 70e3 }) :: string
	assert(not plain:find(">17<", 1, true), "category bar charts ignore the time crosshair")
end

eq(panels.shortDuration(3 * 86400e3 + 4 * 3600e3 + 5e3), "3d 4h", "two largest units")
eq(panels.shortDuration(65e3), "1m 5s", "minutes and seconds")

print("panels tests passed")
