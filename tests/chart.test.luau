local chart = require("../chart")

-- Every coordinate an SVG element places, as numbers.
local function coords(svg: string): { number }
	local out = {}
	for attr, value in svg:gmatch(' ([%a]+)="([^"]*)"') do
		if attr == "d" or attr == "x" or attr == "y" or attr == "width" or attr == "height" or attr == "cx" or attr == "cy" then
			for n in value:gmatch("-?%d+%.?%d*") do table.insert(out, tonumber(n) :: number) end
		end
	end
	return out
end

local function onCanvas(svg: string, w: number, h: number, what: string)
	assert(not svg:find("nan") and not svg:find("inf"), what .. ": non-finite coordinate")
	for _, n in coords(svg) do
		assert(n >= -1 and n <= math.max(w, h) + 1, what .. ": coordinate " .. n .. " is off the " .. w .. "x" .. h .. " canvas")
	end
end

-- A data source that ignores the time range (Grafana's SQLite plugin) returns a year of daily rows for a
-- 15 minute chart. Drawing them put paths millions of px off the canvas, which froze Tern's renderer.
local DAY, MIN = 86400e3, 60e3
local now = 1_800_000_000_000
local t, v = {}, {}
for i = 365, 0, -1 do
	table.insert(t, now - i * DAY)
	table.insert(v, 1000 - i)
end
table.insert(t, now + 10 * MIN)
table.insert(v, 5)
local from, to = now - 5 * MIN, now + 10 * MIN
for _, style in { "line", "points", "bars" } do
	local s = { name = "tokens", color = "#73bf69", t = t, v = v, style = style, fill = 20 }
	onCanvas(chart.svg({ s }, { w = 400, h = 200, from = from, to = to }), 400, 200, style .. " with history outside the range")
	onCanvas(chart.svg({ s }, { w = 400, h = 200, from = from, to = to, max = 10 }), 400, 200, style .. " past a fixed max")
end
onCanvas(
	chart.svg({ { name = "n", color = "#fff", t = { now - DAY, now }, v = { math.huge, 1 } } }, { w = 300, h = 120, from = from, to = to }),
	300, 120, "infinite value"
)

-- A line crossing the range's edge ends on the edge at the interpolated value; samples outside are gone.
local runs = chart.clipRun({ { 0, 0, 0, 1 }, { 10, 100, 0, 2 }, { 20, 0, 0, 3 } }, 5, 15)
assert(#runs == 1 and #runs[1] == 3, "one run of entry, sample, exit")
local first, mid, last = runs[1][1], runs[1][2], runs[1][3]
assert(first[1] == 5 and first[2] == 50 and first[4] == nil, "enters at from, interpolated")
assert(mid[1] == 10 and mid[4] == 2, "keeps the sample inside")
assert(last[1] == 15 and last[2] == 50 and last[4] == nil, "leaves at to, interpolated")
local spans = chart.clipRun({ { 0, 0, 0, 1 }, { 20, 20, 0, 2 } }, 5, 15)
assert(#spans == 1 and spans[1][1][2] == 5 and spans[1][2][2] == 15, "an edge spanning the range is cut at both ends")
assert(#chart.clipRun({ { 0, 1, 0, 1 }, { 2, 1, 0, 2 } }, 5, 15) == 0, "a run before the range draws nothing")

print("chart tests passed")
