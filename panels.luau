-- Panel bodies as Tern UI nodes: stat, gauge, bar gauge, table, logs, text and alert lists natively; time
-- series, state timelines and bar charts as SVG images from chart.luau; other panel types as a card that
-- opens Grafana.

local frames = require("./frames")
local units = require("./units")
local chart = require("./chart")
local regex = require("./regex")
local grafana = require("./grafana")

local M = {}

M.NATIVE = {
	stat = true, gauge = true, bargauge = true, table = true, logs = true, text = true, timeseries = true,
	["state-timeline"] = true, barchart = true, alertlist = true,
}

local present = frames.present

local function strip0(s: string): string
	return (s:gsub("^0", ""):gsub(" 0(%d:)", " %1"))
end

-- Local wall-clock text for epoch ms: "11/4 2:05:09 PM", or "2:05:09 PM" when `short`.
function M.timeText(ms: any, short: boolean?): string
	if type(ms) ~= "number" then return tostring(ms) end
	local sec = math.floor(ms / 1000)
	if short then return strip0(os.date("%I:%M:%S %p", sec) :: string) end
	local day = (os.date("%m/%d", sec) :: string):gsub("^0", ""):gsub("/0", "/")
	return day .. " " .. strip0(os.date("%I:%M:%S %p", sec) :: string)
end

-- Display text of a value under field config: mapping text, else the unit format.
function M.valueText(cfg: any, v: any, ftype: string?): string
	local mapped = frames.mapValue(cfg, v)
	if type(mapped) == "table" and type(mapped.text) == "string" and mapped.text ~= "" then return mapped.text end
	if not present(v) then
		return if type(cfg.noValue) == "string" then cfg.noValue else "No data"
	end
	if ftype == "time" then return M.timeText(v) end
	if type(v) == "number" then return units.format(v, cfg.unit, cfg.decimals) end
	if type(v) == "boolean" then return units.format(v, cfg.unit, cfg.decimals) end
	return tostring(v)
end

local function toneOf(cfg: any, v: any): string?
	return frames.tone(frames.valueColor(cfg, v, cfg.min, cfg.max))
end

--- Reduced values (stat, gauge, bar gauge) -----------------------------------------------------------

export type Reduced = { name: string, value: any, cfg: any, ftype: string }

-- The values a stat-like panel shows, per `reduceOptions`.
function M.reduced(panel: any, fs: { frames.Frame }): { Reduced }
	local ro = type(panel.options) == "table" and type(panel.options.reduceOptions) == "table" and panel.options.reduceOptions or {}
	local calc = type(ro.calcs) == "table" and ro.calcs[1] or "lastNotNull"
	local pattern = if type(ro.fields) == "string" then ro.fields else ""
	local limit = if type(ro.limit) == "number" then ro.limit else 24
	local out: { Reduced } = {}
	for _, fr in fs do
		for _, f in fr.fields do
			if frames.hidden(f) then continue end
			local name = f.display or f.name
			local wanted
			if pattern == "" then
				wanted = f.type == "number"
			else
				wanted = (f.type ~= "time" or pattern == name) and (pattern == name or regex.test(pattern, name))
			end
			if not wanted then continue end
			if ro.values == true then
				for i, v in f.values do
					if #out >= limit then break end
					table.insert(out, { name = name, value = v, cfg = f.cfg or f.config, ftype = f.type, row = i })
				end
			else
				local v = if f.type == "number" then frames.reduce(f.values, calc) else frames.reduce(f.values, if calc == "last" or calc == "lastNotNull" or calc == "first" or calc == "firstNotNull" then calc else "lastNotNull")
				table.insert(out, { name = name, value = v, cfg = f.cfg or f.config, ftype = f.type })
			end
			if #out >= 48 then return out end
		end
	end
	-- Rows of a table-shaped frame name their values by the first string field (Grafana's row naming).
	if ro.values == true then
		for _, r in out do
			local fr = fs[1]
			local rowName = nil
			for _, f in (fr and fr.fields or {}) do
				if f.type == "string" and f.display ~= r.name then
					rowName = f.values[(r :: any).row]
					break
				end
			end
			if type(rowName) == "string" then r.name = rowName end
		end
	end
	return out
end

local function noData(ui: any, text: string?): any
	return ui.text(ui.span(text or "No data", "muted"))
end

local function stat(panel: any, fs: { frames.Frame }, ui: any): { any }
	local items = M.reduced(panel, fs)
	if #items == 0 then return { noData(ui) } end
	local opts = panel.options or {}
	local textMode = opts.textMode or "auto"
	local colorMode = opts.colorMode or "value"
	local tiles = {}
	for _, r in items do
		local showName = textMode == "value_and_name" or textMode == "name" or (textMode == "auto" and #items > 1)
		local value = M.valueText(r.cfg, r.value, r.ftype)
		local label = if showName then r.name else ""
		if textMode == "name" then value, label = r.name, "" end
		if textMode == "none" then value = "" end
		table.insert(tiles, {
			label = label,
			value = value,
			tone = if colorMode == "none" then nil else toneOf(r.cfg, r.value),
			title = r.name .. ": " .. M.valueText(r.cfg, r.value, r.ftype),
		})
	end
	return { ui.stats(tiles) }
end

local function bounds(cfg: any, v: any): (number, number)
	local lo = if type(cfg.min) == "number" then cfg.min else 0
	local hi = cfg.max
	if type(hi) ~= "number" then
		if cfg.unit == "percentunit" then
			hi = 1
		elseif type(v) == "number" and v > 100 then
			hi = v
		else
			hi = 100
		end
	end
	return lo, hi
end

local function fraction(cfg: any, v: any): number
	if type(v) ~= "number" or v ~= v then return 0 end
	local lo, hi = bounds(cfg, v)
	if hi <= lo then return 0 end
	return math.clamp((v - lo) / (hi - lo), 0, 1)
end

-- Gauges: the value as a stat tile above its fill between min and max (Grafana names each gauge only
-- when there are several).
local function gauge(panel: any, fs: { frames.Frame }, ui: any): { any }
	local items = M.reduced(panel, fs)
	if #items == 0 then return { noData(ui) } end
	local tiles, meters = {}, {}
	for _, r in items do
		local cfg = r.cfg
		local lo, hi = bounds(cfg, r.value)
		local value = M.valueText(cfg, r.value, r.ftype)
		local range = units.format(lo, cfg.unit, cfg.decimals) .. " – " .. units.format(hi, cfg.unit, cfg.decimals)
		table.insert(tiles, {
			label = if #items > 1 then r.name else "",
			value = value,
			tone = toneOf(cfg, r.value),
			title = r.name .. ": " .. value .. " of " .. range,
		})
		local node = ui.meter(fraction(cfg, r.value), {
			ui.span(if #items > 1 then r.name .. "  " .. range else range, "muted"),
		})
		node.p = node.p or {}
		node.p.tone = toneOf(cfg, r.value)
		table.insert(meters, node)
	end
	return { ui.stats(tiles), ui.col(meters) }
end

local function bargauge(panel: any, fs: { frames.Frame }, ui: any): { any }
	local items = M.reduced(panel, fs)
	if #items == 0 then return { noData(ui) } end
	local rows = {}
	for i, r in items do
		local cell = ui.meter_cell(fraction(r.cfg, r.value))
		cell.meter.tone = toneOf(r.cfg, r.value) or "accent"
		rows[i] = { r.name, cell, ui.span(M.valueText(r.cfg, r.value, r.ftype), "strong") }
	end
	return {
		ui.table({
			{ id = "name", head = "", grow = 1, truncate = "end" },
			{ id = "bar", head = "", grow = 2 },
			{ id = "value", head = "", align = "end" },
		}, rows),
	}
end

--- Table -------------------------------------------------------------------------------------------

M.TABLE_ROWS = 100

local function tableCell(f: frames.Field, v: any, ui: any): any
	local cfg = f.cfg or f.config
	local text = M.valueText(cfg, v, f.type)
	if not present(v) then return ui.span("", "muted") end
	local custom = type(cfg.custom) == "table" and cfg.custom or {}
	local co = type(custom.cellOptions) == "table" and custom.cellOptions or (type(custom.displayMode) == "string" and { type = custom.displayMode }) or {}
	local kind = co.type
	if kind == "gauge" or kind == "gradient-gauge" or kind == "lcd-gauge" or kind == "basic" then
		if type(v) == "number" then
			local cell = ui.meter_cell(fraction(cfg, v))
			cell.meter.tone = toneOf(cfg, v) or "accent"
			return cell
		end
	end
	if kind == "color-text" or kind == "color-background" or kind == "color-background-solid" then
		local tone = toneOf(cfg, v)
		if tone then return { text = text, dot = tone } end
	end
	local mapped = frames.mapValue(cfg, v)
	if type(mapped) == "table" and type(mapped.color) == "string" then
		local tone = frames.tone(mapped.color)
		if tone then return { text = text, dot = tone } end
	end
	return text
end

local function tablePanel(panel: any, fs: { frames.Frame }, ui: any): ({ any }, string?)
	local fr = fs[1]
	if not fr or #fr.fields == 0 then return { noData(ui) }, nil end
	local fields = {}
	for _, f in fr.fields do
		if not frames.hidden(f) then table.insert(fields, f) end
	end
	local n = frames.length(fr)
	local order = {}
	for i = 1, n do order[i] = i end
	local sortBy = type(panel.options) == "table" and type(panel.options.sortBy) == "table" and panel.options.sortBy[1]
	if type(sortBy) == "table" and type(sortBy.displayName) == "string" then
		for _, f in fields do
			if (f.display or f.name) == sortBy.displayName then
				local vals = f.values
				table.sort(order, function(a, b)
					local x, y = vals[a], vals[b]
					if not present(x) then return false end
					if not present(y) then return true end
					if type(x) == "number" and type(y) == "number" then
						if sortBy.desc then return x > y end
						return x < y
					end
					if sortBy.desc then return tostring(x) > tostring(y) end
					return tostring(x) < tostring(y)
				end)
				break
			end
		end
	end
	local cols = {}
	for j, f in fields do
		local custom = type((f.cfg or f.config).custom) == "table" and (f.cfg or f.config).custom or {}
		local align = custom.align
		if align == "left" then
			align = "start"
		elseif align == "right" then
			align = "end"
		elseif align == "center" then
			align = "center"
		else
			align = if f.type == "number" then "end" else "start"
		end
		cols[j] = {
			id = "c" .. j,
			head = f.display or f.name,
			align = align,
			-- Grafana spreads a table's width across its auto-width columns; a fixed `custom.width` keeps
			-- its column at its natural width here.
			grow = if type(custom.width) == "number" then 0 else 1,
			priority = if j == 1 then 10 else 0,
		}
	end
	local rows = {}
	for k = 1, math.min(n, M.TABLE_ROWS) do
		local i = order[k]
		local cells = {}
		for j, f in fields do cells[j] = tableCell(f, f.values[i], ui) end
		rows[k] = cells
	end
	local body = { ui.table(cols, rows, { empty = "No data" }) }
	if n > M.TABLE_ROWS then
		table.insert(body, ui.text(ui.span(string.format("%d of %d rows; open in Grafana for the rest", M.TABLE_ROWS, n), "muted")))
	end
	local note = if #fs > 1 then string.format("frame 1 of %d", #fs) else nil
	return body, note
end

--- Logs --------------------------------------------------------------------------------------------

M.LOG_LINES = 150

local function levelTone(labels: any, line: string): string?
	local lvl = type(labels) == "table" and (labels.level or labels.detected_level or labels.severity) or nil
	lvl = string.lower(tostring(lvl or ""))
	if lvl == "" then
		local l = line:sub(1, 200):lower()
		if l:find("error") or l:find("panic") or l:find("fatal") then
			lvl = "error"
		elseif l:find("warn") then
			lvl = "warn"
		end
	end
	if lvl == "error" or lvl == "err" or lvl == "fatal" or lvl == "critical" or lvl == "panic" then return "error" end
	if lvl == "warn" or lvl == "warning" then return "warning" end
	return nil
end

local function logs(panel: any, fs: { frames.Frame }, ui: any): { any }
	local entries = {}
	for _, fr in fs do
		local timeF, lineF, labelsF
		for _, f in fr.fields do
			if f.type == "time" and not timeF then timeF = f end
			if f.name == "Line" or f.name == "body" then lineF = f end
			if f.name == "labels" then labelsF = f end
		end
		if not lineF then
			for _, f in fr.fields do
				if f.type == "string" then
					lineF = f
					break
				end
			end
		end
		if lineF then
			for i, line in lineF.values do
				table.insert(entries, {
					t = timeF and timeF.values[i],
					line = if present(line) then tostring(line) else "",
					labels = labelsF and labelsF.values[i],
				})
			end
		end
	end
	if #entries == 0 then return { noData(ui, "No logs") } end
	local opts = panel.options or {}
	local asc = opts.sortOrder == "Ascending"
	table.sort(entries, function(a, b)
		local x, y = tonumber(a.t) or 0, tonumber(b.t) or 0
		if asc then return x < y end
		return x > y
	end)
	local showTime = opts.showTime ~= false
	local out = {}
	for i = 1, math.min(#entries, M.LOG_LINES) do
		local e = entries[i]
		local line = e.line:gsub("[\r\n]+", " ")
		if #line > 400 then line = line:sub(1, 400) .. "…" end
		local spans = {}
		if showTime and type(e.t) == "number" then
			table.insert(spans, ui.span(M.timeText(e.t, true), "muted"))
			table.insert(spans, "  ")
		end
		local tone = levelTone(e.labels, line)
		table.insert(spans, if tone then ui.span(line, tone) else line)
		table.insert(out, ui.text(spans))
	end
	local body = { ui.lines(out) }
	if #entries > M.LOG_LINES then table.insert(body, ui.text(ui.span(string.format("newest %d of %d lines", M.LOG_LINES, #entries), "muted"))) end
	return body
end

--- Text --------------------------------------------------------------------------------------------

local function textPanel(panel: any, ui: any, interpolate: (string) -> string): { any }
	local opts = panel.options or {}
	local content = interpolate(tostring(opts.content or ""))
	if opts.mode == "html" then
		content = content:gsub("<br%s*/?>", "\n"):gsub("</p>", "\n\n"):gsub("<[^>]+>", ""):gsub("&nbsp;", " "):gsub("&amp;", "&")
	end
	if content:match("^%s*$") then return {} end
	return { ui.md(content) }
end

--- Time series -------------------------------------------------------------------------------------

-- Series color for field `f`, the i-th series on the panel.
local function seriesColor(cfg: any, f: frames.Field, i: number): string
	local color = type(cfg.color) == "table" and cfg.color or {}
	local mode = color.mode or "palette-classic"
	if mode == "fixed" or mode == "shades" then
		local hex = frames.hex(color.fixedColor)
		if hex then return hex end
	elseif mode == "thresholds" then
		local step = frames.threshold(cfg, frames.reduce(f.values, "lastNotNull"), cfg.min, cfg.max)
		local hex = step and frames.hex(step.color)
		if hex then return hex end
	end
	return frames.PALETTE[(i - 1) % #frames.PALETTE + 1]
end

local LEGEND_CALC: { [string]: string } = {
	mean = "Mean", max = "Max", min = "Min", last = "Last", lastNotNull = "Last", first = "First",
	firstNotNull = "First", sum = "Total", count = "Count", range = "Range", delta = "Delta",
}

M.MAX_SERIES = 40

-- `cursor`: the dashboard's crosshair time (ms), nil when none.
export type ChartOpts = { w: number, h: number, from: number, to: number, cursor: number? }

-- Grafana's tooltip mode as the chart's: "hidden" when the panel turns tooltips off.
local function tooltipMode(opts: any): string?
	local tip = type(opts.tooltip) == "table" and opts.tooltip or {}
	return if tip.mode == "none" then "hidden" else nil
end

-- SVG text for a time series panel, or nil with a reason.
function M.timeseriesSvg(panel: any, fs: { frames.Frame }, o: ChartOpts): (string?, string?)
	local opts = panel.options or {}
	local legend = type(opts.legend) == "table" and opts.legend or {}
	local showLegend = legend.showLegend ~= false and legend.displayMode ~= "hidden"
	local calcs = type(legend.calcs) == "table" and legend.calcs or {}
	local series: { chart.Series } = {}
	local first: any = nil
	local stack = false
	local thresholds = nil
	local dropped = 0
	for _, fr in fs do
		local tf = frames.timeField(fr)
		if not tf then continue end
		for _, f in frames.numberFields(fr) do
			if #series >= M.MAX_SERIES then
				dropped += 1
				continue
			end
			local cfg = f.cfg or f.config
			local custom = type(cfg.custom) == "table" and cfg.custom or {}
			if not first then
				first = cfg
				local st = type(custom.stacking) == "table" and custom.stacking.mode
				stack = st == "normal" or st == "percent"
				local ts = type(custom.thresholdsStyle) == "table" and custom.thresholdsStyle.mode
				if type(ts) == "string" and ts ~= "off" and type(cfg.thresholds) == "table" and type(cfg.thresholds.steps) == "table" and cfg.thresholds.mode ~= "percentage" then
					thresholds = {}
					for _, step in cfg.thresholds.steps do
						local hex = frames.hex(step.color)
						if type(step.value) == "number" and hex then table.insert(thresholds, { value = step.value, color = hex }) end
					end
				end
			end
			local name = f.display or f.name
			local legendText = name
			for _, c in calcs do
				local v = frames.reduce(f.values, c)
				legendText ..= "   " .. (LEGEND_CALC[c] or c) .. " " .. (if type(v) == "number" then units.format(v, cfg.unit, cfg.decimals) else "-")
			end
			local spanNulls = custom.spanNulls
			local interval = nil
			if spanNulls ~= true then
				interval = if type(spanNulls) == "number" then spanNulls / 2 else (if type(f.config.interval) == "number" then f.config.interval else nil)
			end
			local draw = custom.drawStyle or "line"
			table.insert(series, {
				name = name,
				legend = legendText,
				color = seriesColor(cfg, f, #series + 1),
				t = tf.values,
				v = f.values,
				lineWidth = if type(custom.lineWidth) == "number" then custom.lineWidth else 1,
				fill = if type(custom.fillOpacity) == "number" then custom.fillOpacity else 0,
				style = if draw == "bars" then "bars" elseif draw == "points" then "points" else "line",
				dashed = type(custom.lineStyle) == "table" and custom.lineStyle.fill == "dash",
				interval = interval,
				unit = cfg.unit,
				decimals = cfg.decimals,
			})
		end
	end
	first = first or {}
	local svg = chart.svg(series, {
		w = o.w,
		h = o.h,
		from = o.from,
		to = o.to,
		unit = first.unit,
		decimals = first.decimals,
		min = if type(first.min) == "number" then first.min else nil,
		max = if type(first.max) == "number" then first.max else nil,
		stack = stack,
		legend = showLegend,
		thresholds = thresholds,
		cursor = o.cursor,
		tooltip = tooltipMode(opts),
		tooltipSort = type(opts.tooltip) == "table" and opts.tooltip.sort or nil,
	})
	return svg, if dropped > 0 then string.format("%d series not drawn", dropped) else nil
end

--- State timeline ----------------------------------------------------------------------------------

-- Legend entries of a field's value mappings in mapping order, then its threshold steps when it colors
-- by thresholds and maps nothing.
local function stateLegend(cfg: any, into: { chart.LegendItem }, seen: { [string]: boolean })
	local mapped = false
	for _, m in (if type(cfg.mappings) == "table" then cfg.mappings else {}) do
		local opts = type(m.options) == "table" and m.options or {}
		local results = {}
		if m.type == "value" then
			for _, r in opts do
				if type(r) == "table" then table.insert(results, r) end
			end
			table.sort(results, function(a, b) return (tonumber(a.index) or 0) < (tonumber(b.index) or 0) end)
		elseif type(opts.result) == "table" then
			results = { opts.result }
		end
		for _, r in results do
			if type(r.text) ~= "string" or r.text == "" then continue end
			mapped = true
			local color = frames.hex(r.color) or "currentColor"
			local key = r.text .. "\0" .. color
			if not seen[key] then
				seen[key] = true
				table.insert(into, { text = r.text, color = color })
			end
		end
	end
	local mode = type(cfg.color) == "table" and cfg.color.mode or "thresholds"
	local steps = type(cfg.thresholds) == "table" and cfg.thresholds.steps
	if mapped or mode ~= "thresholds" or type(steps) ~= "table" then return end
	for i, step in steps do
		local nextStep = steps[i + 1]
		local text
		if i == 1 then
			text = if nextStep and type(nextStep.value) == "number" then "< " .. units.format(nextStep.value, cfg.unit, cfg.decimals) else "Base"
		elseif type(step.value) == "number" then
			text = units.format(step.value, cfg.unit, cfg.decimals) .. "+"
		end
		local color = frames.hex(step.color)
		if text and color and not seen[text .. "\0" .. color] then
			seen[text .. "\0" .. color] = true
			table.insert(into, { text = text, color = color })
		end
	end
end

-- State lanes of one field over its time field: each value lasts until the next sample, or one sample
-- interval when the next is more than two intervals away (or there is none). Missing values leave gaps;
-- `merge` joins neighbours that show the same state.
function M.stateLanes(tf: frames.Field, f: frames.Field, to: number, merge: boolean): { chart.Segment }
	local cfg = f.cfg or f.config
	local interval = type(f.config.interval) == "number" and f.config.interval or nil
	local segs: { chart.Segment } = {}
	local times = tf.values
	for i, t in times do
		local v = f.values[i]
		if type(t) ~= "number" or not present(v) or (type(v) == "number" and v ~= v) then continue end
		local nextT = times[i + 1]
		local stop
		if type(nextT) == "number" and (not interval or nextT - t <= 2 * interval) then
			stop = nextT
		else
			stop = if interval then t + interval else to
		end
		local color = frames.hex(frames.valueColor(cfg, v, cfg.min, cfg.max))
		local text = M.valueText(cfg, v, f.type)
		local last = segs[#segs]
		if merge and last and last.to == t and last.text == text and last.color == color then
			last.to = stop
		else
			table.insert(segs, { from = t, to = stop, color = color, text = text })
		end
	end
	return segs
end

function M.timelineSvg(panel: any, fs: { frames.Frame }, o: ChartOpts): (string?, string?)
	local opts = panel.options or {}
	local legend = type(opts.legend) == "table" and opts.legend or {}
	local showLegend = legend.showLegend ~= false and legend.displayMode ~= "hidden"
	local lanes: { chart.Lane } = {}
	local items: { chart.LegendItem } = {}
	local seen: { [string]: boolean } = {}
	local custom: any = nil
	for _, fr in fs do
		local tf = frames.timeField(fr)
		if not tf then continue end
		for _, f in fr.fields do
			if f.type == "time" or frames.hidden(f) then continue end
			local cfg = f.cfg or f.config
			custom = custom or (type(cfg.custom) == "table" and cfg.custom or {})
			table.insert(lanes, { name = f.display or f.name, segs = M.stateLanes(tf, f, o.to, opts.mergeValues ~= false) })
			stateLegend(cfg, items, seen)
		end
	end
	custom = custom or {}
	local svg, dropped = chart.timeline(lanes, {
		w = o.w,
		h = o.h,
		from = o.from,
		to = o.to,
		rowHeight = if type(opts.rowHeight) == "number" then opts.rowHeight else 0.9,
		fillOpacity = if type(custom.fillOpacity) == "number" then custom.fillOpacity else 70,
		lineWidth = if type(custom.lineWidth) == "number" then custom.lineWidth else 0,
		showValue = if type(opts.showValue) == "string" then opts.showValue else "auto",
		legend = if showLegend then items else nil,
		cursor = o.cursor,
		tooltip = tooltipMode(opts),
	})
	return svg, if dropped > 0 then string.format("%d rows not drawn", dropped) else nil
end

--- Bar chart ---------------------------------------------------------------------------------------

function M.barchartSvg(panel: any, fs: { frames.Frame }, o: ChartOpts): (string?, string?)
	local opts = panel.options or {}
	local fr = fs[1]
	if not fr or #fr.fields == 0 then
		return chart.bars({}, { w = o.w, h = o.h, labels = {} }), nil
	end
	local xf: frames.Field? = nil
	if type(opts.xField) == "string" and opts.xField ~= "" then
		for _, f in fr.fields do
			if (f.display or f.name) == opts.xField or f.name == opts.xField then
				xf = f
				break
			end
		end
	end
	if not xf then
		for _, f in fr.fields do
			if f.type == "string" and not frames.hidden(f) then
				xf = f
				break
			end
		end
	end
	xf = xf or frames.timeField(fr)
	if not xf then return nil, "bar charts need a string or time field" end
	local x = xf :: frames.Field
	local xcfg = x.cfg or x.config
	local labels = {}
	for i, v in x.values do
		labels[i] = if x.type == "time" and type(v) == "number" then M.timeText(v) else M.valueText(xcfg, v, x.type)
	end
	local series: { chart.BarSeries } = {}
	local leftLabel, rightLabel
	local fillOpacity
	for _, f in frames.numberFields(fr) do
		if f == x then continue end
		local cfg = f.cfg or f.config
		local custom = type(cfg.custom) == "table" and cfg.custom or {}
		local right = custom.axisPlacement == "right"
		local axisLabel = if type(custom.axisLabel) == "string" and custom.axisLabel ~= "" then custom.axisLabel else nil
		if right then rightLabel = rightLabel or axisLabel else leftLabel = leftLabel or axisLabel end
		if type(custom.fillOpacity) == "number" then fillOpacity = fillOpacity or custom.fillOpacity end
		local colors = nil
		local mode = type(cfg.color) == "table" and cfg.color.mode or "palette-classic"
		if mode == "thresholds" or type(cfg.mappings) == "table" then
			colors = {}
			for i, v in f.values do
				local mapped = frames.mapValue(cfg, v)
				local c = if type(mapped) == "table" and mapped.color then mapped.color elseif mode == "thresholds" then frames.valueColor(cfg, v, cfg.min, cfg.max) else nil
				colors[i] = frames.hex(c)
			end
		end
		table.insert(series, {
			name = f.display or f.name,
			color = seriesColor(cfg, f, #series + 1),
			values = f.values,
			colors = colors,
			right = right,
			unit = cfg.unit,
			decimals = cfg.decimals,
			min = if type(cfg.min) == "number" then cfg.min else nil,
			max = if type(cfg.max) == "number" then cfg.max else nil,
		})
	end
	local legend = type(opts.legend) == "table" and opts.legend or {}
	local orientation = opts.orientation or "auto"
	local horizontal = orientation == "horizontal" or (orientation == "auto" and o.h > o.w)
	-- A time x field takes the dashboard's crosshair at the bar nearest it, within one bar's spacing.
	local cursor = nil
	if o.cursor and x.type == "time" and o.cursor >= o.from and o.cursor <= o.to then
		local xs = x.values
		local spacing = if #xs > 1 and type(xs[1]) == "number" and type(xs[2]) == "number" then math.abs(xs[2] - xs[1]) else math.huge
		cursor = chart.nearest(xs, xs, o.cursor, spacing)
	end
	local svg = chart.bars(series, {
		w = o.w,
		h = o.h,
		labels = labels,
		horizontal = horizontal,
		stacking = if type(opts.stacking) == "string" then opts.stacking else "none",
		groupWidth = if type(opts.groupWidth) == "number" then opts.groupWidth else 0.7,
		barWidth = if type(opts.barWidth) == "number" then opts.barWidth else 0.97,
		fillOpacity = fillOpacity or 80,
		showValue = if type(opts.showValue) == "string" then opts.showValue else "auto",
		cursor = cursor,
		tooltip = tooltipMode(opts),
		legend = legend.showLegend ~= false and legend.displayMode ~= "hidden",
		leftLabel = leftLabel,
		rightLabel = rightLabel,
	})
	return svg, if #fs > 1 then string.format("frame 1 of %d", #fs) else nil
end

--- Alert list --------------------------------------------------------------------------------------

-- Instance states as `stateFilter` keys, and their importance (sortOrder 3).
local ALERT_STATE: { [string]: string } = { alerting = "firing", firing = "firing", pending = "pending", nodata = "noData", normal = "normal", error = "error", recovering = "normal", inactive = "normal" }
local ALERT_RANK: { [string]: number } = { firing = 1, error = 1, pending = 2, noData = 3, normal = 4 }
local ALERT_TEXT: { [string]: string } = { firing = "Firing", error = "Error", pending = "Pending", noData = "No data", normal = "Normal" }
local ALERT_TONE: { [string]: string } = { firing = "error", error = "error", pending = "warning", noData = "info", normal = "success" }

-- "Normal (NoData)" -> "normal": the state before any reason.
function M.alertState(s: any): string
	local base = tostring(s or ""):gsub("%s*%(.*%)%s*$", ""):gsub("%s+", ""):lower()
	return ALERT_STATE[base] or "normal"
end

-- Label matchers of `alertInstanceLabelFilter` ({a="b", c=~"d.*"}); nil when it does not parse.
function M.labelMatchers(src: string): { { name: string, op: string, value: string } }?
	local body = src:match("^%s*{(.*)}%s*$") or src
	local out = {}
	local rest = body
	while true do
		rest = rest:gsub("^[%s,]+", "")
		if rest == "" then break end
		local name, op, value, after = rest:match("^([%w_]+)%s*([!=]?[=~])%s*\"(.-)\"(.*)$")
		if not name or not (op == "=" or op == "!=" or op == "=~" or op == "!~") then return nil end
		table.insert(out, { name = name, op = op, value = value })
		rest = after
	end
	return out
end

local function labelsMatch(labels: any, matchers: { { name: string, op: string, value: string } }): boolean
	for _, m in matchers do
		local v = tostring(type(labels) == "table" and labels[m.name] or "")
		local ok
		if m.op == "=" then
			ok = v == m.value
		elseif m.op == "!=" then
			ok = v ~= m.value
		else
			ok = regex.test("^(" .. m.value .. ")$", v)
			if m.op == "!~" then ok = not ok end
		end
		if not ok then return false end
	end
	return true
end

-- "3d 4h", "12m 5s": the two largest units of a duration in ms.
function M.shortDuration(ms: number): string
	local s = math.max(0, math.floor(ms / 1000))
	local parts = {}
	for _, u in { { 86400, "d" }, { 3600, "h" }, { 60, "m" }, { 1, "s" } } do
		if s >= u[1] and #parts < 2 then
			local n = math.floor(s / u[1])
			s -= n * u[1]
			table.insert(parts, n .. u[2])
		elseif #parts > 0 then
			break
		end
	end
	return if #parts == 0 then "0s" else table.concat(parts, " ")
end

export type AlertItem = {
	name: string,
	-- stateFilter key of the item's most important instance.
	state: string,
	-- When that state began (epoch ms), if known.
	since: number?,
	count: number,
	-- Instance counts by state.
	states: { [string]: number },
}

export type AlertCtx = { dashboardUid: string?, interpolate: (string) -> string }

-- Rules of /api/prometheus/grafana/api/v1/rules `data` an alert list shows, as Grafana's alert list
-- filters, groups and sorts them. Rules group per rule, or per `groupBy` label values in custom mode.
function M.alertItems(panel: any, data: any, ctx: AlertCtx): ({ AlertItem }, string?)
	local opts = panel.options or {}
	local filter = type(opts.stateFilter) == "table" and opts.stateFilter or {}
	local any = false
	for _, on in filter do any = any or on == true end
	local nameFilter = if type(opts.alertName) == "string" then ctx.interpolate(opts.alertName):lower() else ""
	local matchers = {}
	if type(opts.alertInstanceLabelFilter) == "string" and opts.alertInstanceLabelFilter:match("%S") then
		local parsed = M.labelMatchers(ctx.interpolate(opts.alertInstanceLabelFilter))
		if not parsed then return {}, "alert instance label filter does not parse" end
		matchers = parsed
	end
	local folder = type(opts.folder) == "table" and opts.folder.uid or nil
	local custom = opts.groupMode == "custom" and type(opts.groupBy) == "table" and #opts.groupBy > 0
	local groups: { [string]: AlertItem } = {}
	local order: { AlertItem } = {}
	local function add(key: string, name: string, inst: any?)
		local item = groups[key]
		if not item then
			item = { name = name, state = "normal", since = nil, count = 0, states = {} }
			groups[key] = item
			table.insert(order, item)
		end
		if not inst then return end
		local st = M.alertState(inst.state)
		local at = if type(inst.activeAt) == "string" then grafana.iso(inst.activeAt) else nil
		if at and at < 86400e3 * 366 then at = nil end
		item.count += 1
		item.states[st] = (item.states[st] or 0) + 1
		local cur = ALERT_RANK[item.state]
		if item.count == 1 or ALERT_RANK[st] < cur then
			item.state, item.since = st, at
		elseif ALERT_RANK[st] == cur and at and (not item.since or at < item.since) then
			item.since = at
		end
	end
	for _, g in (type(data) == "table" and type(data.groups) == "table" and data.groups or {}) do
		if folder and g.folderUid ~= folder then continue end
		for _, rule in (type(g.rules) == "table" and g.rules or {}) do
			if rule.type ~= nil and rule.type ~= "alerting" then continue end
			local name = tostring(rule.name or "")
			if nameFilter ~= "" and not name:lower():find(nameFilter, 1, true) then continue end
			if opts.dashboardAlerts == true then
				local ann = type(rule.annotations) == "table" and rule.annotations or {}
				if not ctx.dashboardUid or ann.__dashboardUid__ ~= ctx.dashboardUid then continue end
			end
			local kept = 0
			for _, inst in (type(rule.alerts) == "table" and rule.alerts or {}) do
				local st = M.alertState(inst.state)
				if any and filter[st] ~= true then continue end
				if not labelsMatch(inst.labels, matchers) then continue end
				kept += 1
				if custom then
					local parts = {}
					for _, label in opts.groupBy do
						local v = type(inst.labels) == "table" and inst.labels[label]
						table.insert(parts, tostring(label) .. "=" .. tostring(v or ""))
					end
					local key = table.concat(parts, ", ")
					add(key, key, inst)
				else
					add(tostring(rule.uid or name) .. "\0" .. name, name, inst)
				end
			end
			if kept == 0 and opts.showInactiveAlerts == true and not custom then
				add(tostring(rule.uid or name) .. "\0" .. name, name, nil)
			end
		end
	end
	local sortOrder = tonumber(opts.sortOrder) or 1
	table.sort(order, function(a, b)
		if sortOrder == 3 and ALERT_RANK[a.state] ~= ALERT_RANK[b.state] then return ALERT_RANK[a.state] < ALERT_RANK[b.state] end
		if sortOrder == 4 or sortOrder == 5 then
			local x, y = a.since or math.huge, b.since or math.huge
			if x ~= y then
				if sortOrder == 4 then return x < y end
				return (if x == math.huge then -1 else x) > (if y == math.huge then -1 else y)
			end
		end
		if sortOrder == 2 then return a.name:lower() > b.name:lower() end
		return a.name:lower() < b.name:lower()
	end)
	local max = tonumber(opts.maxItems) or 20
	local out = {}
	for i = 1, math.min(#order, max) do out[i] = order[i] end
	return out, nil
end

local function alertList(panel: any, ctx: Ctx): { any }
	local ui = ctx.ui
	local opts = panel.options or {}
	if opts.datasource ~= nil and opts.datasource ~= "grafana" then
		return { ui.text(ui.span("Alert lists from external alert managers draw only in Grafana", "muted")) }
	end
	local items, err = M.alertItems(panel, ctx.rules, { dashboardUid = ctx.dashboardUid, interpolate = ctx.interpolate })
	if err then return { ui.text(ui.span(err, "error")) } end
	if opts.viewMode == "stat" then
		local n = 0
		for _, it in items do n += it.count end
		return { ui.stats({ { label = "", value = tostring(n), tone = if n > 0 then "error" else "success", title = n .. " alert instances" } }) }
	end
	if #items == 0 then return { noData(ui, "No alerts matching filters") } end
	local now = ctx.now or os.time() * 1000
	local rows = {}
	for i, it in items do
		local state = if it.count == 0 then "No instances" else ALERT_TEXT[it.state]
		if it.count > 0 and it.since then state ..= " for " .. M.shortDuration(now - it.since) end
		local counts = {}
		for _, key in { "firing", "error", "pending", "noData", "normal" } do
			if it.states[key] then table.insert(counts, it.states[key] .. " " .. ALERT_TEXT[key]:lower()) end
		end
		rows[i] = {
			{ text = it.name, dot = if it.count == 0 then "muted" else ALERT_TONE[it.state] },
			ui.span(state, if it.count == 0 then "muted" else ALERT_TONE[it.state]),
			ui.span(table.concat(counts, ", "), "muted"),
		}
	end
	return {
		ui.table({
			{ id = "name", head = "", grow = 2, truncate = "end", priority = 10 },
			{ id = "state", head = "", grow = 0 },
			{ id = "count", head = "", grow = 1, align = "end" },
		}, rows),
	}
end

--- Entry -------------------------------------------------------------------------------------------

export type Ctx = {
	ui: any,
	-- Blob id of the panel's chart image, when drawn.
	chart: string?,
	-- Why the chart image could not be drawn.
	chartError: string?,
	interpolate: (string) -> string,
	-- Alert list panels: the `data` of Grafana's rules API, the dashboard's uid and the current time.
	rules: any?,
	dashboardUid: string?,
	now: number?,
}

-- Panel types drawn as an SVG chart image, by their SVG builder.
M.CHARTS = {
	timeseries = M.timeseriesSvg,
	["state-timeline"] = M.timelineSvg,
	barchart = M.barchartSvg,
}

-- Value font sizes (px) style.css defines for `.gf-cell[data-fit]`.
M.FIT_SIZES = { 13, 15, 18, 22, 26, 32, 40, 48, 56, 64 }

-- The largest value font at which a stat or gauge panel's values fit `w`×`h` px, as Grafana sizes
-- stat text to its panel; nil for other panels.
function M.fitSize(panel: any, fs: { frames.Frame }, w: number, h: number): number?
	if panel.type ~= "stat" and panel.type ~= "gauge" then return nil end
	local items = M.reduced(panel, fs)
	if #items == 0 then return nil end
	local longest = 1
	for _, r in items do longest = math.max(longest, utf8.len(M.valueText(r.cfg, r.value, r.ftype)) or 1) end
	local perRow = math.clamp(math.floor(w / 140), 1, #items)
	local rows = math.ceil(#items / perRow)
	local tileW = w / perRow - 12
	-- Named tiles spend a line on the label; gauges also draw a meter row per item.
	local tileH = (h - (if panel.type == "gauge" then #items * 28 else 0)) / rows - (if #items > 1 then 20 else 0)
	local size = math.min(tileW / (longest * 0.6), tileH * 0.7)
	local best = M.FIT_SIZES[1]
	for _, s in M.FIT_SIZES do
		if s <= size then best = s end
	end
	return best
end

-- The body nodes of a panel with prepared frames, and a short note for its head.
function M.body(panel: any, fs: { frames.Frame }, ctx: Ctx): ({ any }, string?)
	local ui = ctx.ui
	local t = panel.type
	if t == "stat" then return stat(panel, fs, ui), nil end
	if t == "gauge" then return gauge(panel, fs, ui), nil end
	if t == "bargauge" then return bargauge(panel, fs, ui), nil end
	if t == "table" then return tablePanel(panel, fs, ui) end
	if t == "logs" then return logs(panel, fs, ui), nil end
	if t == "text" then return textPanel(panel, ui, ctx.interpolate), nil end
	if t == "alertlist" then return alertList(panel, ctx), nil end
	if M.CHARTS[t] then
		if not ctx.chart then return { noData(ui, ctx.chartError or "Drawing…") }, nil end
		return { ui.node("image", { blob = ctx.chart, role = "grafana.chart", alt = tostring(panel.title or "chart") }) }, nil
	end
	return {}, nil
end

return M
