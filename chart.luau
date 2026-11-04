-- Vector time series for Tern image nodes: series -> SVG text. Uses only <path>, <rect>, <circle>,
-- <line> and <text>: Tern's SVG subset draws those (no <polyline>) and resolves no CSS variables, so
-- ink uses `currentColor` (the theme's text) and series use hex colors.

local units = require("./units")

local M = {}

export type Series = {
	name: string,
	color: string,
	t: { number },
	v: { any },
	lineWidth: number?,
	fill: number?,
	style: string?,
	dashed: boolean?,
	-- Expected sample spacing (ms); gaps longer than twice this break the line.
	interval: number?,
	legend: string?,
	-- Value format in the crosshair tooltip (the chart's `unit`/`decimals` otherwise).
	unit: string?,
	decimals: number?,
}

export type Threshold = { value: number, color: string }

export type Opts = {
	w: number,
	h: number,
	from: number,
	to: number,
	unit: string?,
	decimals: number?,
	min: number?,
	max: number?,
	stack: boolean?,
	legend: boolean?,
	thresholds: { Threshold }?,
	-- Crosshair time (ms); nil draws none.
	cursor: number?,
	-- Tooltip rows order beside the crosshair: "asc", "desc" or "none"; `tooltip = "hidden"` draws only the line.
	tooltipSort: string?,
	tooltip: string?,
}

local FONT = 11
local CHAR = 6.1 -- average glyph width at FONT px in the UI face

local function esc(s: string): string
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\"", "&quot;"))
end
M.esc = esc

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function r1(x: number): string
	local s = string.format("%.1f", x)
	return (s:gsub("%.0$", ""))
end

local function niceStep(span: number, count: number): number
	local raw = span / math.max(count, 1)
	if raw <= 0 then return 1 end
	local mag = 10 ^ math.floor(math.log10(raw))
	local norm = raw / mag
	local nice = if norm <= 1 then 1 elseif norm <= 2 then 2 elseif norm <= 2.5 then 2.5 elseif norm <= 5 then 5 else 10
	return nice * mag
end

local TIME_STEPS = {
	1e3, 5e3, 10e3, 15e3, 30e3, 60e3, 2 * 60e3, 5 * 60e3, 10 * 60e3, 15 * 60e3, 30 * 60e3,
	3600e3, 2 * 3600e3, 3 * 3600e3, 6 * 3600e3, 12 * 3600e3, 86400e3, 2 * 86400e3, 7 * 86400e3, 14 * 86400e3, 30 * 86400e3,
}

-- Seconds east of UTC at `sec` in the process's local zone.
local function tzOffset(sec: number): number
	local loc = os.date("*t", sec) :: any
	local utc = os.date("!*t", sec) :: any
	utc.isdst = loc.isdst
	return os.time(loc) - os.time(utc)
end

local function clock(ms: number): string
	local s = os.date("%I:%M %p", math.floor(ms / 1000)) :: string
	return (s:gsub("^0", ""))
end

function M.timeLabel(ms: number, step: number, span: number): string
	local sec = math.floor(ms / 1000)
	if step >= 86400e3 then
		return (os.date("%m/%d", sec) :: string):gsub("^0", ""):gsub("/0", "/")
	end
	if span > 30 * 3600e3 then
		local day = (os.date("%m/%d", sec) :: string):gsub("^0", ""):gsub("/0", "/")
		return day .. " " .. clock(ms)
	end
	if step < 60e3 then
		return ((os.date("%I:%M:%S", sec) :: string):gsub("^0", ""))
	end
	return clock(ms)
end
M.clock = clock

-- Tick times aligned to local boundaries, at most `maxTicks`.
function M.timeTicks(from: number, to: number, maxTicks: number): ({ number }, number)
	local span = to - from
	local step = TIME_STEPS[#TIME_STEPS]
	for _, s in TIME_STEPS do
		if span / s <= maxTicks then
			step = s
			break
		end
	end
	local off = tzOffset(math.floor(from / 1000)) * 1000
	local first = math.ceil((from + off) / step) * step - off
	local ticks = {}
	local t = first
	while t <= to and #ticks < 64 do
		table.insert(ticks, t)
		t += step
	end
	return ticks, step
end

-- Cuts a run of { t, value, base, index } points to [from, to]. An edge crossing the range ends at an
-- interpolated point (without an index) on the boundary, so lines meet the plot's edge. Points outside
-- the range would land far off the canvas: a dashboard whose data source ignores the time range (the
-- SQLite plugin returns every row) put paths millions of px wide in a 15 minute chart, and planning
-- those stalls Tern's renderer.
local function clipRun(run: { { number } }, from: number, to: number): { { { number } } }
	local out: { { { number } } } = {}
	local cur: { { number } } = {}
	local function inside(p: { number }): boolean
		return p[1] >= from and p[1] <= to
	end
	local function at(a: { number }, b: { number }, t: number): { number }
		local f = (t - a[1]) / (b[1] - a[1])
		return { t, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f }
	end
	local function flush()
		if #cur > 0 then
			table.insert(out, cur)
			cur = {}
		end
	end
	for k, p in run do
		local prev = run[k - 1]
		if not prev then
			if inside(p) then table.insert(cur, p) end
		elseif inside(prev) and inside(p) then
			table.insert(cur, p)
		elseif prev[1] ~= p[1] and math.min(prev[1], p[1]) <= to and math.max(prev[1], p[1]) >= from then
			if not inside(prev) then
				flush()
				table.insert(cur, at(prev, p, if prev[1] < from then from else to))
			end
			if inside(p) then
				table.insert(cur, p)
			else
				table.insert(cur, at(prev, p, if p[1] > to then to else from))
				flush()
			end
		else
			flush()
		end
	end
	flush()
	return out
end
M.clipRun = clipRun
export type Axis = { lo: number, hi: number, ticks: { number }, labels: { string }, width: number }

-- A value axis over [lo, hi] with about `count` nice ticks; fixed `min`/`max` override the data bounds.
local function valueAxis(lo: number, hi: number, min: number?, max: number?, unit: string?, decimals: number?, count: number): Axis
	if type(min) == "number" then lo = min end
	if type(max) == "number" then hi = max end
	if hi == lo then
		local pad = if hi == 0 then 1 else math.abs(hi) * 0.1
		lo, hi = lo - pad, hi + pad
	end
	local step = niceStep(hi - lo, count)
	local alo = if type(min) == "number" then lo else math.floor(lo / step + 1e-9) * step
	local ahi = if type(max) == "number" then hi else math.ceil(hi / step - 1e-9) * step
	if ahi <= alo then ahi = alo + step end
	local ticks, labels, width = {}, {}, 0
	local t = math.ceil(alo / step - 1e-9) * step
	while t <= ahi + step * 1e-6 and #ticks < 12 do
		local text = units.format(if math.abs(t) < step * 1e-9 then 0 else t, unit, decimals)
		table.insert(ticks, t)
		table.insert(labels, text)
		width = math.max(width, #text * CHAR)
		t += step
	end
	return { lo = alo, hi = ahi, ticks = ticks, labels = labels, width = width }
end

export type LegendItem = { text: string, color: string }
type LegendRow = { { x: number, color: string, text: string } }

-- Legend entries wrapped into rows of width `W`; rows past what leaves the plot half of `H` fold into
-- "+N more". Returns the rows and their height.
local function legendLayout(items: { LegendItem }, W: number, H: number): ({ LegendRow }, number)
	local rows: { LegendRow } = {}
	if #items == 0 then return rows, 0 end
	local row, x = {}, 0
	for _, it in items do
		local text = it.text
		if #text > 60 then text = text:sub(1, 57) .. "…" end
		local w = 14 + #text * CHAR + 14
		if x + w > W - 8 and #row > 0 then
			table.insert(rows, row)
			row, x = {}, 0
		end
		table.insert(row, { x = x, color = it.color, text = text })
		x += w
	end
	if #row > 0 then table.insert(rows, row) end
	local maxRows = math.max(1, math.floor((H - 80) / 16 / 2))
	if #rows > maxRows then
		local hidden = 0
		for r = maxRows + 1, #rows do hidden += #rows[r] end
		for r = #rows, maxRows + 1, -1 do table.remove(rows, r) end
		local last = rows[maxRows]
		last[#last].text ..= "  +" .. hidden .. " more"
	end
	return rows, #rows * 16 + 4
end

-- Draws legend rows with the first row's baseline at `y`.
local function drawLegend(add: (string) -> (), rows: { LegendRow }, y: number)
	for _, row in rows do
		for _, e in row do
			add(string.format("<rect x=\"%s\" y=\"%s\" width=\"10\" height=\"3\" rx=\"1\" fill=\"%s\"/>", r1(e.x + 2), r1(y - 5), e.color))
			add(string.format("<text x=\"%s\" y=\"%s\" fill=\"currentColor\" fill-opacity=\"0.8\">%s</text>", r1(e.x + 16), r1(y), esc(e.text)))
		end
		y += 16
	end
end

local function svgOpen(W: number, H: number): { string }
	return {
		string.format(
			"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 %d %d\" width=\"%d\" height=\"%d\" font-family=\"system-ui, sans-serif\" font-size=\"%d\">",
			W, H, W, H, FONT
		),
	}
end

-- Vertical time grid lines and their labels under a plot spanning `left`..`left + plotW`.
local function timeAxis(add: (string) -> (), from: number, to: number, left: number, top: number, plotW: number, plotH: number)
	local ticks, step = M.timeTicks(from, to, math.max(2, math.floor(plotW / 90)))
	for _, t in ticks do
		local x = left + (t - from) / (to - from) * plotW
		add(string.format("<path d=\"M%s %sV%s\" stroke=\"currentColor\" stroke-opacity=\"0.08\" stroke-width=\"1\"/>", r1(x), r1(top), r1(top + plotH)))
		add(string.format("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" fill=\"currentColor\" fill-opacity=\"0.6\">%s</text>", r1(x), r1(top + plotH + 13), esc(M.timeLabel(t, step, to - from))))
	end
end

local function clip(text: string, px: number): string
	local max = math.floor(px / CHAR)
	if #text <= max then return text end
	return text:sub(1, math.max(1, max - 1)) .. "…"
end

-- Index of the sample in ascending times `t` nearest `at` whose value is finite, among the two around
-- `at`, when it lies within `limit` ms of it.
function M.nearest(t: { any }, v: { any }, at: number, limit: number): number?
	local lo, hi = 1, #t
	while lo <= hi do
		local mid = (lo + hi) // 2
		if (tonumber(t[mid]) or -math.huge) < at then lo = mid + 1 else hi = mid - 1 end
	end
	local best, bestD = nil, limit
	for _, j in { lo - 1, lo } do
		local tj = t[j]
		if type(tj) == "number" and finite(v[j]) and math.abs(tj - at) <= bestD then
			best, bestD = j, math.abs(tj - at)
		end
	end
	return best
end

-- The crosshair's time: seconds over short ranges, the date over ranges longer than a day.
function M.cursorLabel(ms: number, span: number): string
	local sec = math.floor(ms / 1000)
	local day = if span > 30 * 3600e3 then (os.date("%m/%d", sec) :: string):gsub("^0", ""):gsub("/0", "/") .. " " else ""
	local clockText = (os.date(if span <= 6 * 3600e3 then "%I:%M:%S %p" else "%I:%M %p", sec) :: string):gsub("^0", "")
	return day .. clockText
end

export type TipRow = { color: string?, name: string, value: string }

-- Tooltips draw dark in every theme: SVG images resolve no theme colors, and light text on a fixed dark
-- box reads over any plot.
local TIP_BG, TIP_INK, TIP_ROW = "#1F2329", "#E8EAED", 15

local function drawCrosshair(add: (string) -> (), x: number, top: number, plotH: number)
	add(string.format("<path d=\"M%s %sV%s\" stroke=\"currentColor\" stroke-opacity=\"0.7\" stroke-width=\"1\" stroke-dasharray=\"3 3\"/>", r1(x), r1(top), r1(top + plotH)))
end

-- A tooltip box beside (`x`, `y`) inside the plot rectangle, flipped to the left of `x` when it would
-- cross the right edge; rows past the plot's height fold into "+N more".
local function drawTip(add: (string) -> (), x: number, y: number, left: number, top: number, plotW: number, plotH: number, head: string, rows: { TipRow })
	local maxRows = math.floor((plotH - 10) / TIP_ROW) - 1
	if maxRows < 1 then return end
	local shown, more = rows, 0
	if #rows > maxRows then
		shown = table.move(rows, 1, maxRows - 1, 1, {})
		more = #rows - #shown
	end
	local maxW = math.max(100, plotW - 20)
	local valW = 0
	for _, r in shown do valW = math.max(valW, #r.value * CHAR) end
	valW = math.min(valW, maxW / 2)
	local nameW = 0
	for _, r in shown do nameW = math.max(nameW, #r.name * CHAR) end
	nameW = math.min(nameW, maxW - valW - 46)
	local w = math.max(#head * CHAR + 16, 16 + 12 + nameW + 14 + valW)
	local lines = 1 + #shown + (if more > 0 then 1 else 0)
	local h = TIP_ROW * lines + 8
	local bx = x + 10
	if bx + w > left + plotW then bx = x - 10 - w end
	if bx < left then bx = math.max(left, left + plotW - w) end
	local by = math.clamp(y, top, math.max(top, top + plotH - h))
	add(string.format("<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" rx=\"4\" fill=\"%s\" fill-opacity=\"0.94\"/>", r1(bx), r1(by), r1(w), r1(h), TIP_BG))
	local ty = by + 4 + 11
	add(string.format("<text x=\"%s\" y=\"%s\" fill=\"%s\" fill-opacity=\"0.75\">%s</text>", r1(bx + 8), r1(ty), TIP_INK, esc(head)))
	for _, r in shown do
		ty += TIP_ROW
		if r.color then
			add(string.format("<rect x=\"%s\" y=\"%s\" width=\"8\" height=\"8\" rx=\"2\" fill=\"%s\"/>", r1(bx + 8), r1(ty - 8), r.color))
		end
		add(string.format("<text x=\"%s\" y=\"%s\" fill=\"%s\">%s</text>", r1(bx + 22), r1(ty), TIP_INK, esc(clip(r.name, nameW + CHAR))))
		add(string.format("<text x=\"%s\" y=\"%s\" text-anchor=\"end\" fill=\"%s\">%s</text>", r1(bx + w - 8), r1(ty), TIP_INK, esc(clip(r.value, valW + CHAR))))
	end
	if more > 0 then
		add(string.format("<text x=\"%s\" y=\"%s\" fill=\"%s\" fill-opacity=\"0.75\">+%d more</text>", r1(bx + 22), r1(ty + TIP_ROW), TIP_INK, more))
	end
end

-- Orders tooltip rows by value ("asc" or "desc"), rows without a value last; other orders keep series order.
local function sortTip(rows: { TipRow }, keys: { any }, order: string?)
	if order ~= "asc" and order ~= "desc" then return end
	local idx = {}
	for i in rows do idx[i] = i end
	table.sort(idx, function(a, b)
		local ka, kb = keys[a], keys[b]
		if not finite(ka) or not finite(kb) then
			if finite(ka) ~= finite(kb) then return finite(ka) end
			return a < b
		end
		if ka == kb then return a < b end
		return if order == "asc" then ka < kb else ka > kb
	end)
	local copy = table.clone(rows)
	for i, j in idx do rows[i] = copy[j] end
end

function M.svg(series: { Series }, o: Opts): string
	local W, H = math.max(120, math.floor(o.w)), math.max(60, math.floor(o.h))
	local from, to = o.from, o.to
	if to <= from then to = from + 1 end

	-- Stacking aligns series on shared timestamps and draws each between its base and top.
	local base: { { any } } = {}
	local tops: { { any } } = {}
	for i, s in series do
		tops[i] = s.v
	end
	if o.stack and #series > 1 then
		local acc: { [number]: number } = {}
		for i, s in series do
			local b, top = {}, {}
			for j, t in s.t do
				local v = s.v[j]
				local cur = acc[t] or 0
				b[j] = cur
				if type(v) == "number" and v == v then
					top[j] = cur + v
					acc[t] = cur + v
				else
					top[j] = false
				end
			end
			base[i], tops[i] = b, top
		end
	end

	local lo, hi = math.huge, -math.huge
	for i, s in series do
		for j, t in s.t do
			local v = tops[i][j]
			if t >= from and t <= to and type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
				if v < lo then lo = v end
				if v > hi then hi = v end
			end
		end
	end
	local hasData = lo <= hi
	if not hasData then lo, hi = 0, 1 end
	if o.stack or (series[1] and (series[1].fill or 0) > 0) or series[1] and series[1].style == "bars" then
		if lo > 0 then lo = 0 end
	end
	local axis = valueAxis(lo, hi, o.min, o.max, o.unit, o.decimals, 4)
	local ylo, yhi = axis.lo, axis.hi

	-- Legend rows under the plot.
	local legendRows, legendH = {}, 0
	if o.legend ~= false and #series > 0 then
		local items = {}
		for i, s in series do items[i] = { text = s.legend or s.name, color = s.color } end
		legendRows, legendH = legendLayout(items, W, H)
	end

	local left = math.floor(axis.width + 10)
	local right = 8
	local top = 8
	local axisH = 18
	local plotW = W - left - right
	local plotH = H - top - axisH - legendH
	if plotH < 30 then
		legendRows, legendH = {}, 0
		plotH = H - top - axisH
	end
	local function px(t: number): number
		return left + (t - from) / (to - from) * plotW
	end
	local function py(v: number): number
		return top + (1 - (v - ylo) / (yhi - ylo)) * plotH
	end
	-- Values past a fixed min or max, and edges cut at the time range, stay on the plot.
	local function cy(y: number): number
		return math.max(top, math.min(top + plotH, y))
	end

	local out = svgOpen(W, H)
	local function add(s: string) out[#out + 1] = s end

	-- Grid and y labels.
	for i, v in axis.ticks do
		local y = py(v)
		add(string.format("<path d=\"M%s %sH%s\" stroke=\"currentColor\" stroke-opacity=\"0.12\" stroke-width=\"1\"/>", r1(left), r1(y), r1(left + plotW)))
		add(string.format("<text x=\"%s\" y=\"%s\" text-anchor=\"end\" fill=\"currentColor\" fill-opacity=\"0.6\">%s</text>", r1(left - 6), r1(y + 4), esc(axis.labels[i])))
	end
	timeAxis(add, from, to, left, top, plotW, plotH)

	-- Thresholds drawn as dashed lines.
	for _, th in (o.thresholds or {}) do
		if th.value >= ylo and th.value <= yhi then
			local y = py(th.value)
			add(string.format("<path d=\"M%s %sH%s\" stroke=\"%s\" stroke-width=\"1\" stroke-dasharray=\"4 4\"/>", r1(left), r1(y), r1(left + plotW), th.color))
		end
	end

	-- Series, last drawn on top; stacked fills paint top-down so lower layers stay visible.
	for i = #series, 1, -1 do
		local s = series[i]
		local vals = tops[i]
		local b = base[i]
		local style = s.style or "line"
		local gap = (s.interval or 0) * 2
		if style == "bars" then
			local n = math.max(1, #s.t)
			local bw = math.max(1, plotW / n * 0.8)
			local zero = py(math.max(ylo, math.min(yhi, 0)))
			local rects = {}
			for j, t in s.t do
				local v = vals[j]
				if finite(v) and (not b or finite(b[j])) and t >= from and t <= to then
					local y0 = if b then cy(py(b[j])) else zero
					local y1 = cy(py(v))
					table.insert(rects, string.format("<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\"/>", r1(px(t) - bw / 2), r1(math.min(y0, y1)), r1(bw), r1(math.abs(y0 - y1))))
				end
			end
			add(string.format("<g fill=\"%s\" fill-opacity=\"%s\">", s.color, r1(math.max(0.3, (s.fill or 80) / 100))))
			add(table.concat(rects))
			add("</g>")
		else
			-- Runs of consecutive values, cut to the time range, in pixels.
			local runs: { { { number } } } = {}
			local run: { { number } } = {}
			local prevT: number? = nil
			for j, t in s.t do
				local v = vals[j]
				local ok = finite(v) and (not b or finite(b[j]))
				if ok and prevT ~= nil and gap > 0 and t - prevT > gap and #run > 0 then
					table.insert(runs, run)
					run = {}
				end
				if ok then
					table.insert(run, { t, v, if b then b[j] else 0, j })
					prevT = t
				elseif #run > 0 then
					table.insert(runs, run)
					run = {}
				end
			end
			if #run > 0 then table.insert(runs, run) end
			local segs: { { { number } } } = {}
			for _, r in runs do
				for _, c in clipRun(r, from, to) do
					local sg = {}
					for k, p in c do sg[k] = { px(p[1]), cy(py(p[2])), if b then cy(py(p[3])) else 0, p[4] } end
					table.insert(segs, sg)
				end
			end
			local fill = s.fill or 0
			if o.stack and fill == 0 then fill = 30 end
			for _, sg in segs do
				local parts = {}
				for k, p in sg do parts[k] = (if k == 1 then "M" else "L") .. r1(p[1]) .. " " .. r1(p[2]) end
				local line = table.concat(parts)
				if fill > 0 and #sg > 1 then
					local closing
					if b then
						local back = {}
						for k = #sg, 1, -1 do table.insert(back, "L" .. r1(sg[k][1]) .. " " .. r1(sg[k][3])) end
						closing = table.concat(back)
					else
						local zero = py(math.max(ylo, math.min(yhi, 0)))
						closing = "L" .. r1(sg[#sg][1]) .. " " .. r1(zero) .. "L" .. r1(sg[1][1]) .. " " .. r1(zero)
					end
					add(string.format("<path d=\"%s%sZ\" fill=\"%s\" fill-opacity=\"%s\" stroke=\"none\"/>", line, closing, s.color, r1(fill / 100)))
				end
				if style == "points" or #sg == 1 then
					local dots = {}
					for _, p in sg do
						-- Only samples get dots, not the points where a line meets the range's edge.
						if p[4] then table.insert(dots, string.format("<circle cx=\"%s\" cy=\"%s\" r=\"2\"/>", r1(p[1]), r1(p[2]))) end
					end
					add(string.format("<g fill=\"%s\">%s</g>", s.color, table.concat(dots)))
				end
				if style ~= "points" and #sg > 1 then
					add(string.format(
						"<path d=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"%s\" stroke-linejoin=\"round\"%s/>",
						line, s.color, r1(s.lineWidth or 1), if s.dashed then " stroke-dasharray=\"6 4\"" else ""
					))
				end
			end
		end
	end

	if not hasData then
		add(string.format("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" fill=\"currentColor\" fill-opacity=\"0.5\">No data</text>", r1(left + plotW / 2), r1(top + plotH / 2)))
	end

	-- Crosshair: a dot on each series at its sample nearest the cursor, and their values beside it. A sample
	-- owns half its interval on each side, so a missing value at the cursor shows as missing.
	local cursor = o.cursor
	if cursor and cursor >= from and cursor <= to then
		local x = px(cursor)
		drawCrosshair(add, x, top, plotH)
		local rows, keys, dots = {}, {}, {}
		for i, s in series do
			local j = M.nearest(s.t, s.v, cursor, if s.interval then s.interval / 2 else (to - from) / 100)
			local y = j and tops[i][j]
			if j and finite(y) and s.t[j] >= from and s.t[j] <= to then
				table.insert(dots, string.format("<circle cx=\"%s\" cy=\"%s\" r=\"3\" fill=\"%s\"/>", r1(px(s.t[j])), r1(py(math.clamp(y, ylo, yhi))), s.color))
			else
				j = nil
			end
			table.insert(rows, { color = s.color, name = s.name, value = if j then units.format(s.v[j], s.unit or o.unit, s.decimals or o.decimals) else "–" })
			table.insert(keys, if j then s.v[j] else false)
		end
		add(table.concat(dots))
		if o.tooltip ~= "hidden" and #rows > 0 then
			sortTip(rows, keys, o.tooltipSort)
			drawTip(add, x, top + 4, left, top, plotW, plotH, M.cursorLabel(cursor, to - from), rows)
		end
	end

	drawLegend(add, legendRows, top + plotH + axisH + 12)

	add("</svg>")
	return table.concat(out)
end

--- State timeline ----------------------------------------------------------------------------------

export type Segment = { from: number, to: number, color: string?, text: string? }
export type Lane = { name: string, segs: { Segment } }
export type TimelineOpts = {
	w: number,
	h: number,
	from: number,
	to: number,
	-- Share of a lane its bars fill (Grafana's rowHeight).
	rowHeight: number?,
	fillOpacity: number?,
	lineWidth: number?,
	-- "auto" (when the text fits), "always" or "never".
	showValue: string?,
	legend: { LegendItem }?,
	-- Crosshair time (ms); nil draws none. `tooltip = "hidden"` draws only the line.
	cursor: number?,
	tooltip: string?,
}

local function opacity(x: number): string
	local s = string.format("%.2f", math.clamp(x, 0, 1))
	return (s:gsub("0+$", ""):gsub("%.$", ""))
end

-- Black or white, whichever reads on `hex`.
function M.contrast(hex: string): string
	local h = hex:sub(2)
	if #h == 3 or #h == 4 then h = h:sub(1, 1):rep(2) .. h:sub(2, 2):rep(2) .. h:sub(3, 3):rep(2) end
	local r = tonumber(h:sub(1, 2), 16) or 0
	local g = tonumber(h:sub(3, 4), 16) or 0
	local b = tonumber(h:sub(5, 6), 16) or 0
	return if (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6 then "#000000" else "#FFFFFF"
end

-- One lane of colored state bars per series over [from, to]. Lanes stay at least 10px tall; returns the
-- SVG and how many lanes did not fit.
function M.timeline(lanes: { Lane }, o: TimelineOpts): (string, number)
	local W, H = math.max(120, math.floor(o.w)), math.max(60, math.floor(o.h))
	local from, to = o.from, o.to
	if to <= from then to = from + 1 end
	local legendRows, legendH = {}, 0
	if o.legend and #o.legend > 0 then legendRows, legendH = legendLayout(o.legend, W, H) end
	local top, axisH, right = 4, 18, 8
	local plotH = H - top - axisH - legendH
	if plotH < 20 then
		legendRows, legendH = {}, 0
		plotH = H - top - axisH
	end
	local shown = math.min(#lanes, math.max(1, math.floor(plotH / 10)))
	local labelW = 0
	for i = 1, shown do labelW = math.max(labelW, #lanes[i].name * CHAR) end
	labelW = math.min(labelW, W * 0.4)
	-- Glyphs run wider than CHAR on average for some names; keep slack so labels never clip at the edge.
	local left = math.floor(labelW + 16)
	local plotW = W - left - right
	local function px(t: number): number
		return left + (math.clamp(t, from, to) - from) / (to - from) * plotW
	end

	local out = svgOpen(W, H)
	local function add(s: string) out[#out + 1] = s end
	timeAxis(add, from, to, left, top, plotW, plotH)

	local laneH = plotH / math.max(shown, 1)
	local bh = laneH * math.clamp(o.rowHeight or 0.9, 0.1, 1)
	local fill = opacity((o.fillOpacity or 70) / 100)
	local stroke = o.lineWidth or 0
	local showValue = o.showValue or "auto"
	for k = 1, shown do
		local lane = lanes[k]
		local y = top + (k - 1) * laneH + (laneH - bh) / 2
		add(string.format("<text x=\"%s\" y=\"%s\" text-anchor=\"end\" fill=\"currentColor\" fill-opacity=\"0.8\">%s</text>", r1(left - 6), r1(y + bh / 2 + 4), esc(clip(lane.name, labelW + CHAR))))
		for _, sg in lane.segs do
			if sg.to <= from or sg.from >= to then continue end
			local x0, x1 = px(sg.from), px(sg.to)
			if x1 - x0 <= 0 then continue end
			local color = sg.color or "currentColor"
			add(string.format(
				"<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"%s\" fill-opacity=\"%s\"%s/>",
				r1(x0), r1(y), r1(math.max(x1 - x0, 0.5)), r1(bh), color, if sg.color then fill else "0.25",
				if stroke > 0 then string.format(" stroke=\"%s\" stroke-width=\"%s\"", color, r1(stroke)) else ""
			))
			local text = sg.text
			if showValue ~= "never" and text and text ~= "" and bh >= FONT and (showValue == "always" or #text * CHAR + 6 <= x1 - x0) then
				local ink = if sg.color then M.contrast(sg.color) else "currentColor"
				add(string.format("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" fill=\"%s\">%s</text>", r1((x0 + x1) / 2), r1(y + bh / 2 + 4), ink, esc(text)))
			end
		end
	end
	if #lanes == 0 then
		add(string.format("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" fill=\"currentColor\" fill-opacity=\"0.5\">No data</text>", r1(left + plotW / 2), r1(top + plotH / 2)))
	end
	-- Crosshair: each drawn lane's state at the cursor.
	local cursor = o.cursor
	if cursor and cursor >= from and cursor <= to and #lanes > 0 then
		local x = px(cursor)
		drawCrosshair(add, x, top, plotH)
		if o.tooltip ~= "hidden" then
			local rows = {}
			for k = 1, shown do
				local hit: Segment? = nil
				for _, sg in lanes[k].segs do
					if sg.from <= cursor and cursor < sg.to then
						hit = sg
						break
					end
				end
				table.insert(rows, { color = hit and hit.color, name = lanes[k].name, value = if hit then hit.text or "" else "–" })
			end
			drawTip(add, x, top + 4, left, top, plotW, plotH, M.cursorLabel(cursor, to - from), rows)
		end
	end
	drawLegend(add, legendRows, top + plotH + axisH + 12)
	add("</svg>")
	return table.concat(out), #lanes - shown
end

--- Bar chart ---------------------------------------------------------------------------------------

export type BarSeries = {
	name: string,
	color: string,
	values: { any },
	-- Per-bar colors (threshold or mapping colors); `color` otherwise.
	colors: { string? }?,
	-- On the second value axis (right, or top when horizontal).
	right: boolean?,
	unit: string?,
	decimals: number?,
	min: number?,
	max: number?,
}
export type BarOpts = {
	w: number,
	h: number,
	-- Category labels, one per bar group.
	labels: { string },
	horizontal: boolean?,
	-- "none", "normal" or "percent".
	stacking: string?,
	-- Share of a category's slot its group of bars fills, and of each bar's lane its bar fills.
	groupWidth: number?,
	barWidth: number?,
	fillOpacity: number?,
	showValue: string?,
	-- Category under the crosshair (time x fields only); nil draws none. `tooltip = "hidden"` draws only the band.
	cursor: number?,
	tooltip: string?,
	legend: boolean?,
	-- Axis titles of the first and second value axes.
	leftLabel: string?,
	rightLabel: string?,
}

-- Grouped (or stacked) bars per category. Series on `right` scale against a second axis.
function M.bars(series: { BarSeries }, o: BarOpts): string
	local W, H = math.max(120, math.floor(o.w)), math.max(60, math.floor(o.h))
	local n = #o.labels
	local horizontal = o.horizontal == true
	local stacked = o.stacking == "normal" or o.stacking == "percent"
	local percent = o.stacking == "percent"

	local sides: { { number } } = { {}, {} }
	for i, s in series do table.insert(sides[if s.right then 2 else 1], i) end

	-- Bar extents [base, top] per series and category in their axis's units.
	local base: { { [number]: number } } = {}
	local tops: { { [number]: number } } = {}
	for side = 1, 2 do
		local total: { [number]: number } = {}
		if percent then
			for _, i in sides[side] do
				for j = 1, n do
					local v = series[i].values[j]
					if finite(v) then total[j] = (total[j] or 0) + math.abs(v) end
				end
			end
		end
		local pos: { [number]: number }, neg: { [number]: number } = {}, {}
		for _, i in sides[side] do
			base[i], tops[i] = {}, {}
			for j = 1, n do
				local v = series[i].values[j]
				if not finite(v) then continue end
				if percent then v = if (total[j] or 0) > 0 then v / total[j] else 0 end
				if stacked then
					local acc = if v >= 0 then pos else neg
					local b = acc[j] or 0
					base[i][j], tops[i][j] = b, b + v
					acc[j] = b + v
				else
					base[i][j], tops[i][j] = 0, v
				end
			end
		end
	end

	local ticks = if horizontal then math.max(2, math.floor((W - 100) / 90)) else 4
	local axes: { Axis? } = {}
	local hasData = false
	for side = 1, 2 do
		if #sides[side] == 0 then continue end
		local lo, hi = 0, 0
		for _, i in sides[side] do
			for _, t in tops[i] do
				hasData = true
				lo, hi = math.min(lo, t), math.max(hi, t)
			end
		end
		if hi == lo then hi = lo + 1 end
		local s1 = series[sides[side][1]]
		if percent then
			axes[side] = valueAxis(lo, hi, 0, 1, "percentunit", nil, ticks)
		else
			axes[side] = valueAxis(lo, hi, s1.min, s1.max, s1.unit, s1.decimals, ticks)
		end
	end
	local main = axes[1] or axes[2]

	local legendRows, legendH = {}, 0
	if o.legend ~= false and #series > 0 then
		local items = {}
		for i, s in series do items[i] = { text = s.name, color = s.color } end
		legendRows, legendH = legendLayout(items, W, H)
	end

	local labelW = 0
	for _, l in o.labels do labelW = math.max(labelW, #l * CHAR) end
	local left, right, top, bottom
	if horizontal then
		labelW = math.min(labelW, W * 0.4)
		left = math.floor(labelW + 16)
		local last = main and main.labels[#main.labels] or ""
		right = math.max(8, math.floor(#last * CHAR / 2) + 4)
		top = if axes[2] then 22 else 8
		bottom = 18
	else
		left = if axes[1] then math.floor(axes[1].width + 10) else 8
		right = if axes[2] then math.floor(axes[2].width + 10) else 8
		top = if o.leftLabel or o.rightLabel then 22 else 8
		bottom = 18
	end
	local plotW = W - left - right
	local plotH = H - top - bottom - legendH
	if plotH < 30 then
		legendRows, legendH = {}, 0
		plotH = H - top - bottom
	end

	-- Positions along the value dimension (y when vertical) and the category dimension.
	local function vpos(side: number, v: number): number
		local a = axes[side] :: Axis
		local f = (math.clamp(v, a.lo, a.hi) - a.lo) / (a.hi - a.lo)
		return if horizontal then left + f * plotW else top + (1 - f) * plotH
	end
	local catStart = if horizontal then top else left
	local slot = (if horizontal then plotH else plotW) / math.max(n, 1)
	local gw = slot * math.clamp(o.groupWidth or 0.7, 0.05, 1)
	local used = (if #sides[1] > 0 then 1 else 0) + (if #sides[2] > 0 then 1 else 0)
	local lanes = if stacked then math.max(used, 1) else math.max(#series, 1)
	local lw = gw / lanes
	local bw = math.max(1, lw * math.clamp(o.barWidth or 0.97, 0.05, 1))

	local out = svgOpen(W, H)
	local function add(s: string) out[#out + 1] = s end

	-- Value grid and labels.
	for side = 1, 2 do
		local a = axes[side]
		if not a then continue end
		for i, v in a.ticks do
			local p = vpos(side, v)
			if a == main then
				if horizontal then
					add(string.format("<path d=\"M%s %sV%s\" stroke=\"currentColor\" stroke-opacity=\"0.12\" stroke-width=\"1\"/>", r1(p), r1(top), r1(top + plotH)))
				else
					add(string.format("<path d=\"M%s %sH%s\" stroke=\"currentColor\" stroke-opacity=\"0.12\" stroke-width=\"1\"/>", r1(left), r1(p), r1(left + plotW)))
				end
			end
			local x, y, anchor
			if horizontal then
				x, y, anchor = p, if side == 1 then top + plotH + 13 else top - 6, "middle"
			else
				x, y, anchor = if side == 1 then left - 6 else left + plotW + 6, p + 4, if side == 1 then "end" else "start"
			end
			add(string.format("<text x=\"%s\" y=\"%s\" text-anchor=\"%s\" fill=\"currentColor\" fill-opacity=\"0.6\">%s</text>", r1(x), r1(y), anchor, esc(a.labels[i])))
		end
	end
	if not horizontal then
		if o.leftLabel and axes[1] then
			add(string.format("<text x=\"2\" y=\"12\" fill=\"currentColor\" fill-opacity=\"0.7\">%s</text>", esc(o.leftLabel)))
		end
		if o.rightLabel and axes[2] then
			add(string.format("<text x=\"%d\" y=\"12\" text-anchor=\"end\" fill=\"currentColor\" fill-opacity=\"0.7\">%s</text>", W - 2, esc(o.rightLabel)))
		end
	end

	-- Category labels, thinned so they do not overlap.
	local every = if horizontal then math.ceil(14 / math.max(slot, 1)) else math.ceil((math.min(labelW, 160) + 8) / math.max(slot, 1))
	for j, l in o.labels do
		if (j - 1) % every ~= 0 then continue end
		local c = catStart + (j - 0.5) * slot
		if horizontal then
			add(string.format("<text x=\"%s\" y=\"%s\" text-anchor=\"end\" fill=\"currentColor\" fill-opacity=\"0.6\">%s</text>", r1(left - 6), r1(c + 4), esc(clip(l, labelW + CHAR))))
		else
			add(string.format("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" fill=\"currentColor\" fill-opacity=\"0.6\">%s</text>", r1(c), r1(top + plotH + 13), esc(clip(l, 160))))
		end
	end

	-- Crosshair: a band behind the category under the cursor.
	local cur = o.cursor
	if cur and (cur < 1 or cur > n) then cur = nil end
	if cur then
		local c0 = catStart + (cur - 1) * slot
		if horizontal then
			add(string.format("<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"currentColor\" fill-opacity=\"0.1\"/>", r1(left), r1(c0), r1(plotW), r1(slot)))
		else
			add(string.format("<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"currentColor\" fill-opacity=\"0.1\"/>", r1(c0), r1(top), r1(slot), r1(plotH)))
		end
	end

	-- Bars.
	local fill = opacity((o.fillOpacity or 80) / 100)
	local showValue = o.showValue or "auto"
	for i, s in series do
		local side = if s.right then 2 else 1
		local lane = if stacked then (if side == 2 and used == 2 then 2 else 1) else i
		for j = 1, n do
			local t = tops[i][j]
			if t == nil then continue end
			local c0 = catStart + (j - 1) * slot + (slot - gw) / 2 + (lane - 1) * lw + (lw - bw) / 2
			local p0, p1 = vpos(side, base[i][j]), vpos(side, t)
			local color = (s.colors and s.colors[j]) or s.color
			local x, y, w, h
			if horizontal then
				x, y, w, h = math.min(p0, p1), c0, math.abs(p1 - p0), bw
			else
				x, y, w, h = c0, math.min(p0, p1), bw, math.abs(p1 - p0)
			end
			add(string.format("<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"%s\" fill-opacity=\"%s\"/>", r1(x), r1(y), r1(w), r1(h), color, fill))
			if showValue == "never" or (showValue == "auto" and stacked) then continue end
			local text = units.format(s.values[j], s.unit, s.decimals)
			local neg = t < base[i][j]
			if horizontal then
				if showValue == "always" or bw >= FONT then
					add(string.format("<text x=\"%s\" y=\"%s\" text-anchor=\"%s\" fill=\"currentColor\">%s</text>", r1(if neg then x - 3 else x + w + 3), r1(c0 + bw / 2 + 4), if neg then "end" else "start", esc(text)))
				end
			elseif showValue == "always" or #text * CHAR <= lw + 2 then
				add(string.format("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" fill=\"currentColor\">%s</text>", r1(c0 + bw / 2), r1(if neg then y + h + 12 else y - 3), esc(text)))
			end
		end
	end

	if cur and o.tooltip ~= "hidden" then
		local rows = {}
		for _, s in series do
			local v = s.values[cur]
			table.insert(rows, { color = (s.colors and s.colors[cur]) or s.color, name = s.name, value = if finite(v) then units.format(v, s.unit, s.decimals) else "–" })
		end
		local c = catStart + (cur - 0.5) * slot
		if horizontal then
			drawTip(add, left + plotW / 2, c + slot / 2 + 4, left, top, plotW, plotH, o.labels[cur], rows)
		else
			drawTip(add, c + slot / 2, top + 4, left, top, plotW, plotH, o.labels[cur], rows)
		end
	end

	if not hasData then
		add(string.format("<text x=\"%s\" y=\"%s\" text-anchor=\"middle\" fill=\"currentColor\" fill-opacity=\"0.5\">No data</text>", r1(left + plotW / 2), r1(top + plotH / 2)))
	end
	drawLegend(add, legendRows, top + plotH + bottom + 12)
	add("</svg>")
	return table.concat(out)
end

return M
