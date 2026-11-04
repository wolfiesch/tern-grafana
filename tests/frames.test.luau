local frames = require("../frames")

local function eq(got: any, want: any, what: string)
	assert(got == want, what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end
local function notNull() return false end

-- One Prometheus instant series as /api/ds/query returns it (numeric-multi: one frame per series).
local function series(ref: string, host: string, value: number): any
	return {
		schema = { refId = ref, fields = {
			{ name = "Time", type = "time" },
			{ name = "Value", type = "number", labels = { host = host }, config = { displayNameFromDS = "{host=\"" .. host .. "\"}" } },
		} },
		data = { values = { { 1000 }, { value } } },
	}
end
local QUERIES = {
	{ refId = "cpu", format = "table", datasource = { type = "prometheus", uid = "prometheus" } },
	{ refId = "mem", format = "table", datasource = { type = "prometheus", uid = "prometheus" } },
}
local RESULTS = {
	cpu = { frames = { series("cpu", "b", 0.5), series("cpu", "a", 0.25) } },
	mem = { frames = { series("mem", "a", 0.75) } },
}

local function field(frame: any, name: string): any
	for _, f in frame.fields do
		if (f.cfg and f.cfg.displayName) == name or f.name == name then return f end
	end
	return nil
end

-- Table-format Prometheus queries and Loki instant queries fold into one table per refId, as Grafana's frontend does.
do
	local fs = frames.decode(RESULTS, { "cpu", "mem" }, notNull)
	eq(#fs, 3, "series frames")
	fs = frames.tables(fs, QUERIES)
	eq(#fs, 2, "one table per refId")
	local cpu = fs[1]
	eq(cpu.refId, "cpu", "refId order")
	eq(#cpu.fields, 3, "Time, host, value")
	eq(cpu.fields[2].name, "host", "label column")
	eq(cpu.fields[3].name, "Value #cpu", "value column named by refId")
	eq(cpu.fields[3].config.displayNameFromDS, nil, "series display name dropped")
	eq(frames.length(cpu), 2, "one row per series")
	-- A single table query keeps the plain name.
	local one = frames.tables(frames.decode({ cpu = RESULTS.cpu }, { "cpu" }, notNull), { QUERIES[1] })
	eq(one[1].fields[3].name, "Value", "single table value name")
	-- Time-series queries are left alone.
	local ts = frames.tables(frames.decode(RESULTS, { "cpu", "mem" }, notNull), {
		{ refId = "cpu", datasource = { type = "prometheus" } }, { refId = "mem", datasource = { type = "prometheus" } },
	})
	eq(#ts, 3, "time series untouched")
	-- Loki instant metric queries fold the same way; Loki range queries stay series.
	local loki = frames.tables(frames.decode(RESULTS, { "cpu", "mem" }, notNull), {
		{ refId = "cpu", queryType = "instant", datasource = { type = "loki" } },
		{ refId = "mem", queryType = "range", datasource = { type = "loki" } },
	})
	eq(#loki, 2, "instant folded, range kept")
	eq(loki[2].refId, "cpu", "folded table after series")
	eq(loki[2].fields[3].name, "Value", "one folded Loki refId")
end

-- merge then organize: one row per host with every query as a renamed, ordered column (fleet "Hosts").
do
	local fs = frames.tables(frames.decode(RESULTS, { "cpu", "mem" }, notNull), QUERIES)
	fs = frames.transform(fs, {
		{ id = "merge", options = {} },
		{ id = "organize", options = {
			excludeByName = { Time = true },
			indexByName = { host = 0, ["Value #mem"] = 1, ["Value #cpu"] = 2 },
			renameByName = { host = "Host", ["Value #cpu"] = "CPU", ["Value #mem"] = "Memory" },
		} },
	}, function() return nil end)
	eq(#fs, 1, "merged")
	frames.applyConfig(fs, {})
	local t = fs[1]
	local host, cpu, mem = field(t, "Host"), field(t, "CPU"), field(t, "Memory")
	assert(host and cpu and mem, "renamed columns")
	eq(field(t, "Time"), nil, "excluded column")
	eq(t.fields[1], host, "Host first")
	eq(t.fields[2], mem, "Memory second")
	eq(frames.length(t), 2, "one row per host")
	local rows = {}
	for i, h in host.values do rows[h] = i end
	eq(cpu.values[rows.a], 0.25, "a cpu")
	eq(mem.values[rows.a], 0.75, "a memory")
	eq(cpu.values[rows.b], 0.5, "b cpu")
	eq(frames.present(mem.values[rows.b]), false, "b has no memory")
end

-- Reducers skip missing values, except count, which counts every row like Grafana's.
do
	local values = { 1, false, 3, false }
	eq(frames.reduce(values, "lastNotNull"), 3, "lastNotNull")
	eq(frames.reduce(values, "mean"), 2, "mean")
	eq(frames.reduce(values, "max"), 3, "max")
	eq(frames.reduce(values, "count"), 4, "count")
end

-- Thresholds: the highest step at or under the value wins; the base step has no value.
do
	local cfg = { thresholds = { mode = "absolute", steps = {
		{ color = "green", value = false }, { color = "orange", value = 180 }, { color = "red", value = 600 },
	} } }
	eq(frames.threshold(cfg, 10).color, "green", "base")
	eq(frames.threshold(cfg, 180).color, "orange", "boundary")
	eq(frames.threshold(cfg, 1e9).color, "red", "top")
end

print("frames tests passed")
