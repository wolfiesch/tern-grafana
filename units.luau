-- Grafana unit formatting: format(value, unit, decimals) -> display string.
-- Covers the units Grafana dashboards commonly use; unknown units print the number and the unit id.

local M = {}

local function isNum(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end
M.isNum = isNum

-- Decimals Grafana picks when none are configured: about three significant digits.
local function autoDecimals(v: number): number
	local a = math.abs(v)
	if a == 0 or a >= 100 then return 0 end
	if a >= 10 then return 1 end
	if a >= 1 then return 2 end
	local d = 2 - math.floor(math.log10(a))
	return math.min(d, 6)
end

local function commas(int: string): string
	local neg = int:sub(1, 1) == "-"
	if neg then int = int:sub(2) end
	local out = int:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then out = out:sub(2) end
	return (if neg then "-" else "") .. out
end

function M.fixed(v: number, decimals: number?): string
	local auto = decimals == nil
	local d = if decimals ~= nil then math.max(0, math.floor(decimals)) else autoDecimals(v)
	local s = string.format("%." .. d .. "f", v)
	if auto and s:find("%.") then
		s = s:gsub("0+$", ""):gsub("%.$", "")
	end
	if s == "-0" then s = "0" end
	return s
end

-- Scales `v` by `step` through `suffixes` (index 1 is unscaled).
local function scaled(v: number, decimals: number?, step: number, suffixes: { string }, sep: string?): string
	local i = 1
	local a = math.abs(v)
	while a >= step and i < #suffixes do
		a /= step
		v /= step
		i += 1
	end
	local suffix = suffixes[i]
	if suffix == "" then return M.fixed(v, decimals) end
	return M.fixed(v, decimals) .. (sep or " ") .. suffix
end

local SHORT = { "", "K", "Mil", "Bil", "Tri", "Quadr" }
local IEC_BYTES = { "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" }
local SI_BYTES = { "B", "kB", "MB", "GB", "TB", "PB", "EB" }
local SI_BITS = { "b", "kb", "Mb", "Gb", "Tb", "Pb" }
local BITS_PS = { "b/s", "kb/s", "Mb/s", "Gb/s", "Tb/s", "Pb/s" }
local BYTES_PS = { "B/s", "kB/s", "MB/s", "GB/s", "TB/s", "PB/s" }
local IEC_BYTES_PS = { "B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s" }
local HERTZ = { "Hz", "kHz", "MHz", "GHz", "THz" }
local METERS = { "m", "km", "Mm", "Gm" }

local RATES: { [string]: string } = {
	ops = "ops/s", reqps = "req/s", rps = "reads/s", wps = "writes/s", iops = "io/s",
	eps = "evts/s", pps = "p/s", cps = "c/s", mps = "m/s", opm = "ops/min", rpm = "reads/min",
}

-- Durations from seconds, Grafana's `s` style: one unit, the largest that keeps the value >= 1.
local function seconds(v: number, decimals: number?): string
	local a = math.abs(v)
	if a == 0 then return "0 s" end
	if a < 1e-6 then return M.fixed(v * 1e9, decimals) .. " ns" end
	if a < 1e-3 then return M.fixed(v * 1e6, decimals) .. " µs" end
	if a < 1 then return M.fixed(v * 1e3, decimals) .. " ms" end
	if a < 60 then return M.fixed(v, decimals) .. " s" end
	if a < 3600 then return M.fixed(v / 60, decimals) .. " min" end
	if a < 86400 then return M.fixed(v / 3600, decimals) .. " hour" end
	if a < 604800 then return M.fixed(v / 86400, decimals) .. " day" end
	if a < 31536000 then return M.fixed(v / 604800, decimals) .. " week" end
	return M.fixed(v / 31536000, decimals) .. " year"
end

local DT_UNITS = {
	{ 31536000, "year" }, { 2592000, "month" }, { 604800, "week" }, { 86400, "day" },
	{ 3600, "hour" }, { 60, "minute" }, { 1, "second" },
}

-- `dtdurations`: the two largest whole units, as "2 hours, 5 minutes".
local function dtdurations(v: number): string
	local neg = v < 0
	local rest = math.floor(math.abs(v))
	if rest == 0 then
		if v == 0 then return "0 seconds" end
		return M.fixed(v * 1000, 0) .. " ms"
	end
	local parts = {}
	for _, u in DT_UNITS do
		if rest >= u[1] and #parts < 2 then
			local n = math.floor(rest / u[1])
			rest -= n * u[1]
			table.insert(parts, n .. " " .. u[2] .. (if n == 1 then "" else "s"))
		end
	end
	return (if neg then "-" else "") .. table.concat(parts, ", ")
end

function M.format(v: any, unit: string?, decimals: number?): string
	if type(v) == "boolean" then
		if unit == "bool_yes_no" then return if v then "Yes" else "No" end
		if unit == "bool_on_off" then return if v then "On" else "Off" end
		return if v then "true" else "false"
	end
	if type(v) ~= "number" then return if v == nil then "No data" else tostring(v) end
	if v ~= v then return "NaN" end
	if v == math.huge then return "+Inf" end
	if v == -math.huge then return "-Inf" end
	local u = unit or "short"
	if u == "" or u == "short" then return scaled(v, decimals, 1000, SHORT) end
	if u == "none" or u == "string" then return M.fixed(v, decimals) end
	if u == "locale" then
		local s = M.fixed(v, decimals)
		local int, frac = s:match("^(-?%d+)(.*)$")
		return if int then commas(int) .. frac else s
	end
	if u == "percent" then return M.fixed(v, decimals) .. "%" end
	if u == "percentunit" then return M.fixed(v * 100, decimals) .. "%" end
	if u == "bytes" then return scaled(v, decimals, 1024, IEC_BYTES) end
	if u == "kbytes" then return scaled(v * 1024, decimals, 1024, IEC_BYTES) end
	if u == "mbytes" then return scaled(v * 1024 ^ 2, decimals, 1024, IEC_BYTES) end
	if u == "gbytes" then return scaled(v * 1024 ^ 3, decimals, 1024, IEC_BYTES) end
	if u == "decbytes" then return scaled(v, decimals, 1000, SI_BYTES) end
	if u == "deckbytes" then return scaled(v * 1e3, decimals, 1000, SI_BYTES) end
	if u == "decmbytes" then return scaled(v * 1e6, decimals, 1000, SI_BYTES) end
	if u == "decgbytes" then return scaled(v * 1e9, decimals, 1000, SI_BYTES) end
	if u == "bits" or u == "decbits" then return scaled(v, decimals, 1000, SI_BITS) end
	if u == "bps" then return scaled(v, decimals, 1000, BITS_PS) end
	if u == "Bps" then return scaled(v, decimals, 1000, BYTES_PS) end
	if u == "binBps" then return scaled(v, decimals, 1024, IEC_BYTES_PS) end
	if u == "hertz" then return scaled(v, decimals, 1000, HERTZ) end
	if u == "lengthm" then return scaled(v, decimals, 1000, METERS) end
	if u == "ns" then return seconds(v / 1e9, decimals) end
	if u == "µs" then return seconds(v / 1e6, decimals) end
	if u == "ms" then return seconds(v / 1000, decimals) end
	if u == "s" then return seconds(v, decimals) end
	if u == "m" then return seconds(v * 60, decimals) end
	if u == "h" then return seconds(v * 3600, decimals) end
	if u == "d" then return seconds(v * 86400, decimals) end
	if u == "dtdurations" then return dtdurations(v) end
	if u == "dtdurationms" then return dtdurations(v / 1000) end
	if u == "celsius" then return M.fixed(v, decimals) .. "°C" end
	if u == "fahrenheit" then return M.fixed(v, decimals) .. "°F" end
	if u == "rotrpm" then return scaled(v, decimals, 1000, SHORT) .. " rpm" end
	if u == "currencyUSD" then
		local s = scaled(math.abs(v), decimals, 1000, { "", "K", "M", "B", "T" }, "")
		return (if v < 0 then "-$" else "$") .. s
	end
	if u == "bool" then return if v ~= 0 then "true" else "false" end
	if u == "bool_yes_no" then return if v ~= 0 then "Yes" else "No" end
	if u == "bool_on_off" then return if v ~= 0 then "On" else "Off" end
	local rate = RATES[u]
	if rate then return scaled(v, decimals, 1000, SHORT) .. " " .. rate end
	local suffix = u:match("^suffix:(.*)$")
	if suffix then return M.fixed(v, decimals) .. suffix end
	local prefix = u:match("^prefix:(.*)$")
	if prefix then return prefix .. M.fixed(v, decimals) end
	return M.fixed(v, decimals) .. " " .. u
end

return M
