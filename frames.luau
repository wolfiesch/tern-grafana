-- Grafana data frames from /api/ds/query: decoding, the transformations dashboards use, field config
-- (defaults, overrides, display names), reducers, thresholds, value mappings and colors.
-- Missing values are `false` so value arrays stay dense; `present(v)` tests for a value.

local regex = require("./regex")

local M = {}

export type Field = {
	name: string,
	type: string,
	labels: { [string]: string }?,
	-- Config the data source sent (displayNameFromDS, interval, unit).
	config: { [string]: any },
	values: { any },
	-- Effective config after panel defaults and overrides (set by `applyConfig`).
	cfg: { [string]: any }?,
	-- Final display name (set by `applyConfig`).
	display: string?,
}

export type Frame = { name: string?, refId: string?, fields: { Field } }

function M.present(v: any): boolean
	return v ~= false and v ~= nil
end

local function copy(t: any): any
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in t do out[k] = copy(v) end
	return out
end
M.copy = copy

function M.length(frame: Frame): number
	local f = frame.fields[1]
	return if f then #f.values else 0
end

-- Decodes the `results` object of /api/ds/query. `refs` orders refIds; `isNull` recognizes JSON null.
function M.decode(results: { [string]: any }, refs: { string }, isNull: (any) -> boolean): ({ Frame }, { string })
	local frames: { Frame } = {}
	local errors: { string } = {}
	local order = copy(refs)
	for ref in results do
		if not table.find(order, ref) then table.insert(order, ref) end
	end
	for _, ref in order do
		local res = results[ref]
		if type(res) == "table" then
			if type(res.error) == "string" and res.error ~= "" then
				table.insert(errors, ref .. ": " .. res.error)
			end
			for _, raw in (if type(res.frames) == "table" then res.frames else {}) do
				local schema = raw.schema or {}
				local data = raw.data or {}
				local cols = data.values or {}
				local fields: { Field } = {}
				for i, sf in (schema.fields or {}) do
					local values = {}
					local src = cols[i] or {}
					for j = 1, #src do
						local v = src[j]
						values[j] = if v == nil or isNull(v) then false else v
					end
					local labels = nil
					if type(sf.labels) == "table" then
						labels = {}
						for k, v in sf.labels do labels[k] = tostring(v) end
					end
					table.insert(fields, {
						name = tostring(sf.name or ("Field " .. i)),
						type = tostring(sf.type or "other"),
						labels = labels,
						config = if type(sf.config) == "table" then sf.config else {},
						values = values,
					})
				end
				-- NaN and ±Inf travel as entity indexes (zero-based) per field.
				if type(data.entities) == "table" then
					for i, ent in data.entities do
						local f = fields[i]
						if f and type(ent) == "table" then
							for kind, value in { NaN = 0 / 0, Inf = math.huge, NegInf = -math.huge } do
								for _, idx in (if type(ent[kind]) == "table" then ent[kind] else {}) do
									if type(idx) == "number" then f.values[idx + 1] = value end
								end
							end
						end
					end
				end
				if #fields > 0 then
					table.insert(frames, { name = schema.name, refId = schema.refId or ref, fields = fields })
				end
			end
		end
	end
	return frames, errors
end

-- Prometheus table-format queries and Loki instant metric queries answer with one frame per series;
-- Grafana's frontend folds each refId's series into one table: Time, the sorted label columns, then
-- `Value #<refId>` when that data source folded several refIds (else `Value`). Table frames follow the
-- other frames, in refId order. `queries` are the sent bodies.
function M.tables(frames: { Frame }, queries: { any }): { Frame }
	local kindOf: { [string]: string } = {}
	local perKind: { [string]: number } = {}
	for _, q in queries do
		local ds = q.datasource
		local kind = type(ds) == "table" and ds.type or nil
		local folds = (kind == "prometheus" and q.format == "table") or (kind == "loki" and q.queryType == "instant")
		if folds and type(q.refId) == "string" then kindOf[q.refId] = kind end
	end
	if next(kindOf) == nil then return frames end
	local out: { Frame } = {}
	local groups: { [string]: { Frame } } = {}
	local refs: { string } = {}
	for _, f in frames do
		local ref = f.refId
		if ref and kindOf[ref] then
			if not groups[ref] then
				groups[ref] = {}
				table.insert(refs, ref)
				perKind[kindOf[ref]] = (perKind[kindOf[ref]] or 0) + 1
			end
			table.insert(groups[ref], f)
		else
			table.insert(out, f)
		end
	end
	for _, ref in refs do
		local keys: { string } = {}
		local seen: { [string]: boolean } = {}
		local valueConfig: { [string]: any }? = nil
		for _, f in groups[ref] do
			for _, field in f.fields do
				if field.type == "number" then
					valueConfig = valueConfig or field.config
					for k in field.labels or {} do
						if not seen[k] then
							seen[k] = true
							table.insert(keys, k)
						end
					end
				end
			end
		end
		table.sort(keys)
		local times, values = {}, {}
		local labelCols: { { any } } = {}
		for i in keys do labelCols[i] = {} end
		for _, f in groups[ref] do
			local tf, vf
			for _, field in f.fields do
				if field.type == "time" then tf = tf or field elseif field.type == "number" then vf = vf or field end
			end
			if vf then
				for row = 1, #vf.values do
					table.insert(times, if tf then tf.values[row] or false else false)
					table.insert(values, vf.values[row])
					for i, k in keys do table.insert(labelCols[i], (vf.labels and vf.labels[k]) or "") end
				end
			end
		end
		local config: { [string]: any } = {}
		for k, v in valueConfig or {} do
			if k ~= "displayNameFromDS" then config[k] = v end
		end
		local fields: { Field } = { { name = "Time", type = "time", config = {}, values = times } }
		for i, k in keys do table.insert(fields, { name = k, type = "string", config = {}, values = labelCols[i] }) end
		local name = if perKind[kindOf[ref]] > 1 then "Value #" .. ref else "Value"
		table.insert(fields, { name = name, type = "number", config = config, values = values })
		table.insert(out, { name = nil, refId = ref, fields = fields })
	end
	return out
end

local function labelText(labels: { [string]: string }?): (string?, number)
	if not labels then return nil, 0 end
	local keys = {}
	for k in labels do
		if k ~= "__name__" then table.insert(keys, k) end
	end
	table.sort(keys)
	if #keys == 0 then return nil, 0 end
	if #keys == 1 then return labels[keys[1]], 1 end
	local parts = {}
	for _, k in keys do table.insert(parts, k .. "=\"" .. labels[k] .. "\"") end
	return "{" .. table.concat(parts, ", ") .. "}", #keys
end

-- `${__field.labels.x}`, `${__field.name}`, `${__series.name}` in a display name template.
local function expandTemplate(text: string, field: Field, frame: Frame): string
	return (text:gsub("%${__([%w_]+)%.?([%w_%.]*)}", function(scope, path)
		if scope == "field" then
			if path == "name" or path == "displayName" then return field.name end
			local label = path:match("^labels%.(.+)$")
			if label then return (field.labels and field.labels[label]) or "" end
			if path == "labels" then return (labelText(field.labels)) or "" end
		elseif scope == "series" and path == "name" then
			return frame.name or field.name
		end
		return nil
	end))
end

-- Grafana's name for a field before panel overrides.
function M.baseName(field: Field, frame: Frame): string
	local c = field.config
	if type(c.displayName) == "string" and c.displayName ~= "" then return expandTemplate(c.displayName, field, frame) end
	if type(c.displayNameFromDS) == "string" and c.displayNameFromDS ~= "" then return c.displayNameFromDS end
	if field.type == "time" then return field.name end
	local nonTime = 0
	for _, f in frame.fields do
		if f.type ~= "time" then nonTime += 1 end
	end
	if frame.name and frame.name ~= "" and nonTime == 1 then return frame.name end
	local text = labelText(field.labels)
	if text then
		if field.name == "Value" or field.name == "" then return text end
		return field.name .. " " .. text
	end
	return field.name
end

local function setPath(t: { [string]: any }, path: string, value: any)
	local keys = string.split(path, ".")
	local node = t
	for i = 1, #keys - 1 do
		local k = keys[i]
		if type(node[k]) ~= "table" then node[k] = {} end
		node = node[k]
	end
	node[keys[#keys]] = copy(value)
end

local function deepMerge(base: { [string]: any }, top: { [string]: any }): { [string]: any }
	local out = copy(base)
	for k, v in top do
		if type(v) == "table" and type(out[k]) == "table" and #v == 0 and next(v) ~= nil then
			out[k] = deepMerge(out[k], v)
		else
			out[k] = copy(v)
		end
	end
	return out
end

local function matches(matcher: any, field: Field, frame: Frame, name: string): boolean
	if type(matcher) ~= "table" then return false end
	local id, opt = matcher.id, matcher.options
	if id == "byName" then return opt == name or opt == field.name end
	if id == "byNames" and type(opt) == "table" then
		local names = opt.names or {}
		local hit = table.find(names, name) ~= nil or table.find(names, field.name) ~= nil
		if opt.mode == "exclude" then return not hit end
		return hit
	end
	if id == "byRegexp" and type(opt) == "string" then return regex.test(opt, name) end
	if id == "byType" then return opt == field.type end
	if id == "byFrameRefID" then return opt == frame.refId end
	return false
end

-- Sets each field's `cfg` (DS config over panel defaults, then overrides) and `display`.
function M.applyConfig(frames: { Frame }, fieldConfig: any)
	local defaults = if type(fieldConfig) == "table" and type(fieldConfig.defaults) == "table" then fieldConfig.defaults else {}
	local overrides = if type(fieldConfig) == "table" and type(fieldConfig.overrides) == "table" then fieldConfig.overrides else {}
	for _, frame in frames do
		for _, field in frame.fields do
			local base = M.baseName(field, frame)
			local cfg = deepMerge(defaults, field.config)
			for _, o in overrides do
				if matches(o.matcher, field, frame, base) then
					for _, p in (o.properties or {}) do
						if type(p.id) == "string" then setPath(cfg, p.id, p.value) end
					end
				end
			end
			field.cfg = cfg
			local dn = cfg.displayName
			field.display = if type(dn) == "string" and dn ~= "" and dn ~= field.config.displayName
				then expandTemplate(dn, field, frame)
				else base
		end
	end
end

function M.hidden(field: Field): boolean
	local c = field.cfg or field.config
	local custom = c.custom
	if type(custom) ~= "table" then return false end
	if custom.hidden == true then return true end
	local hf = custom.hideFrom
	return type(hf) == "table" and hf.viz == true
end

function M.timeField(frame: Frame): Field?
	for _, f in frame.fields do
		if f.type == "time" then return f end
	end
	return nil
end

function M.numberFields(frame: Frame): { Field }
	local out = {}
	for _, f in frame.fields do
		if f.type == "number" and not M.hidden(f) then table.insert(out, f) end
	end
	return out
end

-- Reducers, Grafana names.
function M.reduce(values: { any }, calc: string?): any
	local c = calc or "lastNotNull"
	local n = #values
	if c == "last" then return values[n] end
	if c == "first" then return values[1] end
	if c == "lastNotNull" then
		for i = n, 1, -1 do
			local v = values[i]
			if M.present(v) and not (type(v) == "number" and v ~= v) then return v end
		end
		return nil
	end
	if c == "firstNotNull" then
		for i = 1, n do
			local v = values[i]
			if M.present(v) and not (type(v) == "number" and v ~= v) then return v end
		end
		return nil
	end
	local sum, count, mn, mx, firstV, lastV = 0, 0, math.huge, -math.huge, nil, nil
	for i = 1, n do
		local v = values[i]
		if type(v) == "number" and v == v then
			sum += v
			count += 1
			if v < mn then mn = v end
			if v > mx then mx = v end
			if firstV == nil then firstV = v end
			lastV = v
		end
	end
	if c == "count" then return n end
	if count == 0 then return nil end
	if c == "sum" then return sum end
	if c == "mean" then return sum / count end
	if c == "max" then return mx end
	if c == "min" then return mn end
	if c == "range" then return mx - mn end
	if c == "delta" or c == "diff" then return (lastV :: number) - (firstV :: number) end
	if c == "distinctCount" then
		local seen, k = {}, 0
		for i = 1, n do
			local v = values[i]
			if M.present(v) and not seen[v] then
				seen[v] = true
				k += 1
			end
		end
		return k
	end
	return M.reduce(values, "lastNotNull")
end

-- Threshold step for `v`; percentage mode scales by min/max.
function M.threshold(cfg: { [string]: any }, v: any, min: number?, max: number?): any
	local th = cfg.thresholds
	if type(th) ~= "table" or type(th.steps) ~= "table" or type(v) ~= "number" then return nil end
	local x = v
	if th.mode == "percentage" then
		local lo, hi = min or 0, max or 100
		if hi == lo then return th.steps[1] end
		x = (v - lo) / (hi - lo) * 100
	end
	local hit = th.steps[1]
	for _, step in th.steps do
		if type(step.value) ~= "number" or x >= step.value then hit = step end
	end
	return hit
end

-- Value mapping result `{text, color}` for `v`, or nil.
function M.mapValue(cfg: { [string]: any }, v: any): any
	local mappings = cfg.mappings
	if type(mappings) ~= "table" then return nil end
	for _, m in mappings do
		local opts = m.options
		if type(opts) == "table" then
			if m.type == "value" then
				local key = if type(v) == "number" and v == math.floor(v) then string.format("%d", v) else tostring(v)
				local hit = opts[key]
				if hit == nil and type(v) == "boolean" then hit = opts[if v then "true" else "false"] end
				if type(hit) == "table" then return hit end
			elseif m.type == "range" and type(v) == "number" then
				local from = if type(opts.from) == "number" then opts.from else -math.huge
				local to = if type(opts.to) == "number" then opts.to else math.huge
				if v >= from and v <= to then return opts.result end
			elseif m.type == "special" then
				local match = opts.match
				local isNil = not M.present(v)
				local isNan = type(v) == "number" and v ~= v
				if (match == "null" and isNil) or (match == "nan" and isNan) or (match == "null+nan" and (isNil or isNan))
					or (match == "true" and (v == true or v == 1)) or (match == "false" and (v == false or v == 0))
					or (match == "empty" and v == "")
				then
					return opts.result
				end
			elseif m.type == "regex" and type(opts.pattern) == "string" and v ~= nil then
				if regex.test(opts.pattern, tostring(v)) then return opts.result end
			end
		end
	end
	return nil
end

local NAMED: { [string]: string } = {
	green = "#73BF69", ["dark-green"] = "#37872D", ["semi-dark-green"] = "#56A64B", ["light-green"] = "#96D98D", ["super-light-green"] = "#C8F2C2",
	red = "#F2495C", ["dark-red"] = "#C4162A", ["semi-dark-red"] = "#E02F44", ["light-red"] = "#FF7383", ["super-light-red"] = "#FFA6B0",
	yellow = "#FADE2A", ["dark-yellow"] = "#E0B400", ["semi-dark-yellow"] = "#F2CC0C", ["light-yellow"] = "#FFEE52", ["super-light-yellow"] = "#FFF899",
	orange = "#FF9830", ["dark-orange"] = "#FA6400", ["semi-dark-orange"] = "#FF780A", ["light-orange"] = "#FFB357", ["super-light-orange"] = "#FFCB7D",
	blue = "#5794F2", ["dark-blue"] = "#1F60C4", ["semi-dark-blue"] = "#3274D9", ["light-blue"] = "#8AB8FF", ["super-light-blue"] = "#C0D8FF",
	purple = "#B877D9", ["dark-purple"] = "#8F3BB8", ["semi-dark-purple"] = "#A352CC", ["light-purple"] = "#CA95E5", ["super-light-purple"] = "#DEB6F2",
}

-- CSS color names Grafana passes through for names outside its palette; looked up without hyphens, so
-- "dark-gray" reads as CSS darkgray.
local CSS: { [string]: string } = {
	black = "#000000", white = "#FFFFFF", silver = "#C0C0C0", gray = "#808080", grey = "#808080",
	darkgray = "#A9A9A9", darkgrey = "#A9A9A9", dimgray = "#696969", dimgrey = "#696969",
	lightgray = "#D3D3D3", lightgrey = "#D3D3D3", slategray = "#708090", darkslategray = "#2F4F4F",
}

M.PALETTE = {
	"#73BF69", "#F2CC0C", "#8AB8FF", "#FF780A", "#F2495C", "#5794F2", "#B877D9", "#705DA0",
	"#37872D", "#FADE2A", "#447EBC", "#C15C17", "#890F02", "#0A437C", "#6D1F62", "#584477",
}

-- Hex for a Grafana color name, hex or rgb(a) string; nil for `text`/`transparent`/unknown.
function M.hex(color: any): string?
	if type(color) ~= "string" then return nil end
	if NAMED[color] then return NAMED[color] end
	local css = CSS[(color:lower():gsub("-", ""))]
	if css then return css end
	if color:match("^#%x%x%x%x?%x?%x?%x?%x?$") then return color end
	local r, g, b = color:match("^rgba?%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
	if r then return string.format("#%02X%02X%02X", tonumber(r) :: number, tonumber(g) :: number, tonumber(b) :: number) end
	return nil
end

-- Tern tone token for a color: by hue family.
function M.tone(color: any): string?
	if type(color) ~= "string" then return nil end
	for _, fam in { "green", "red", "yellow", "orange", "blue", "purple" } do
		if color == fam or color:sub(-#fam - 1) == "-" .. fam then
			return ({ green = "success", red = "error", yellow = "warning", orange = "warning", blue = "info", purple = "accent" })[fam]
		end
	end
	local hex = M.hex(color)
	if not hex then return nil end
	local r = tonumber(hex:sub(2, 3), 16) :: number / 255
	local g = tonumber(hex:sub(4, 5), 16) :: number / 255
	local b = tonumber(hex:sub(6, 7), 16) :: number / 255
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	if mx - mn < 0.12 then return nil end
	local h
	if mx == r then
		h = ((g - b) / (mx - mn)) % 6
	elseif mx == g then
		h = (b - r) / (mx - mn) + 2
	else
		h = (r - g) / (mx - mn) + 4
	end
	h *= 60
	if h < 20 or h >= 330 then return "error" end
	if h < 70 then return "warning" end
	if h < 170 then return "success" end
	if h < 260 then return "info" end
	return "accent"
end

-- Color of a field's value: mapping color, then threshold or fixed color.
function M.valueColor(cfg: { [string]: any }, v: any, min: number?, max: number?): string?
	local mapped = M.mapValue(cfg, v)
	if type(mapped) == "table" and type(mapped.color) == "string" then return mapped.color end
	local mode = type(cfg.color) == "table" and cfg.color.mode or "thresholds"
	if mode == "fixed" or mode == "shades" then return cfg.color.fixedColor end
	if mode == "thresholds" or mode == nil then
		local step = M.threshold(cfg, v, min, max)
		return step and step.color
	end
	return nil
end

--- Transformations -----------------------------------------------------------------------------

local function fieldNamed(frame: Frame, name: string): Field?
	for _, f in frame.fields do
		if M.baseName(f, frame) == name or f.name == name then return f end
	end
	return nil
end

local function merge(frames: { Frame }): { Frame }
	if #frames < 2 then return frames end
	-- Fields every frame has are the join key; the rest become columns.
	local counts: { [string]: number } = {}
	for _, fr in frames do
		local seen = {}
		for _, f in fr.fields do
			local n = M.baseName(f, fr)
			if not seen[n] then
				seen[n] = true
				counts[n] = (counts[n] or 0) + 1
			end
		end
	end
	local outFields: { Field } = {}
	local byName: { [string]: Field } = {}
	local shared: { string } = {}
	for _, fr in frames do
		for _, f in fr.fields do
			local n = M.baseName(f, fr)
			if not byName[n] then
				local nf: Field = { name = n, type = f.type, labels = nil, config = copy(f.config), values = {} }
				nf.config.displayNameFromDS = nil
				nf.config.displayName = nil
				byName[n] = nf
				table.insert(outFields, nf)
				if counts[n] == #frames then table.insert(shared, n) end
			end
		end
	end
	local rowOf: { [string]: number } = {}
	local rows = 0
	for _, fr in frames do
		local len = M.length(fr)
		local names = {}
		for i, f in fr.fields do names[i] = M.baseName(f, fr) end
		for r = 1, len do
			local keyParts = {}
			for _, n in shared do
				local f = fieldNamed(fr, n)
				keyParts[#keyParts + 1] = tostring(f and f.values[r])
			end
			local key = table.concat(keyParts, "\0")
			local row = rowOf[key]
			if not row then
				rows += 1
				row = rows
				rowOf[key] = row
				for _, of in outFields do of.values[row] = false end
			end
			for i, f in fr.fields do
				local v = f.values[r]
				if M.present(v) then byName[names[i]].values[row] = v end
			end
		end
	end
	return { { name = nil, refId = frames[1].refId, fields = outFields } }
end

local function organize(frames: { Frame }, opts: any): { Frame }
	local exclude = opts.excludeByName or {}
	local index = opts.indexByName or {}
	local rename = opts.renameByName or {}
	for _, fr in frames do
		local kept = {}
		for _, f in fr.fields do
			local n = M.baseName(f, fr)
			if exclude[n] ~= true then
				f.config = copy(f.config)
				if type(rename[n]) == "string" and rename[n] ~= "" then f.config.displayName = rename[n] end
				table.insert(kept, { f = f, n = n, i = #kept })
			end
		end
		table.sort(kept, function(a, b)
			local ia = if type(index[a.n]) == "number" then index[a.n] else 1e6 + a.i
			local ib = if type(index[b.n]) == "number" then index[b.n] else 1e6 + b.i
			return ia < ib
		end)
		local fields = {}
		for _, k in kept do table.insert(fields, k.f) end
		fr.fields = fields
	end
	return frames
end

local function compareValues(a: any, b: any): boolean
	if not M.present(a) then return false end
	if not M.present(b) then return true end
	if type(a) == "number" and type(b) == "number" then return a < b end
	return tostring(a) < tostring(b)
end

local function sortBy(frames: { Frame }, opts: any): { Frame }
	local spec = type(opts.sort) == "table" and opts.sort[1]
	if not spec or type(spec.field) ~= "string" then return frames end
	for _, fr in frames do
		local key = fieldNamed(fr, spec.field)
		if key then
			local order = {}
			for i = 1, M.length(fr) do order[i] = i end
			local kv = key.values
			table.sort(order, function(x, y)
				local a, b = kv[x], kv[y]
				if spec.desc then
					if not M.present(a) then return false end
					if not M.present(b) then return true end
					return compareValues(b, a)
				end
				return compareValues(a, b)
			end)
			for _, f in fr.fields do
				local nv = {}
				for i, src in order do nv[i] = f.values[src] end
				f.values = nv
			end
		end
	end
	return frames
end

local function filterByName(frames: { Frame }, opts: any): { Frame }
	local inc, exc = opts.include, opts.exclude
	for _, fr in frames do
		local kept = {}
		for _, f in fr.fields do
			local n = M.baseName(f, fr)
			local keep = true
			if type(inc) == "table" then
				keep = (type(inc.names) == "table" and table.find(inc.names, n) ~= nil)
					or (type(inc.pattern) == "string" and regex.test(inc.pattern, n))
			end
			if keep and type(exc) == "table" then
				if (type(exc.names) == "table" and table.find(exc.names, n) ~= nil)
					or (type(exc.pattern) == "string" and regex.test(exc.pattern, n))
				then
					keep = false
				end
			end
			if keep then table.insert(kept, f) end
		end
		fr.fields = kept
	end
	return frames
end

local function convertTypes(frames: { Frame }, opts: any): { Frame }
	for _, conv in (if type(opts.conversions) == "table" then opts.conversions else {}) do
		for _, fr in frames do
			local f = type(conv.targetField) == "string" and fieldNamed(fr, conv.targetField)
			if f then
				local to = conv.destinationType
				for i, v in f.values do
					if not M.present(v) then continue end
					if to == "number" or to == "time" then
						f.values[i] = tonumber(v) or false
					elseif to == "string" then
						f.values[i] = tostring(v)
					elseif to == "boolean" then
						f.values[i] = v == true or v == "true" or v == 1
					end
				end
				if to == "number" or to == "time" or to == "string" or to == "boolean" then f.type = to end
			end
		end
	end
	return frames
end

local function extractFields(frames: { Frame }, opts: any, decode: (string) -> any): { Frame }
	for _, fr in frames do
		local src = fieldNamed(fr, opts.source or "Line")
		if src then
			local cols: { [string]: Field } = {}
			local order: { Field } = {}
			local len = M.length(fr)
			for r = 1, len do
				local v = src.values[r]
				local ok, obj = pcall(decode, if type(v) == "string" then v else "")
				if ok and type(obj) == "table" then
					for k, val in obj do
						local c = cols[k]
						if not c then
							c = { name = tostring(k), type = if type(val) == "number" then "number" else "string", config = {}, values = table.create(len, false) }
							cols[k] = c
							table.insert(order, c)
						end
						c.values[r] = if type(val) == "table" then tostring(val) else val
					end
				end
			end
			table.sort(order, function(a, b) return a.name < b.name end)
			local fields = {}
			if opts.replace then
				if opts.keepTime then
					local t = M.timeField(fr)
					if t then table.insert(fields, t) end
				end
			else
				fields = copy(fr.fields)
			end
			for _, c in order do table.insert(fields, c) end
			fr.fields = fields
		end
	end
	return frames
end

-- Applies the panel's transformations in order; returns the frames and notes about skipped ones.
function M.transform(frames: { Frame }, transformations: any, decode: (string) -> any): ({ Frame }, { string })
	local notes = {}
	if type(transformations) ~= "table" then return frames, notes end
	for _, t in transformations do
		if type(t) == "table" and t.disabled ~= true then
			local opts = if type(t.options) == "table" then t.options else {}
			if t.id == "merge" then
				frames = merge(frames)
			elseif t.id == "organize" then
				frames = organize(frames, opts)
			elseif t.id == "sortBy" then
				frames = sortBy(frames, opts)
			elseif t.id == "filterFieldsByName" then
				frames = filterByName(frames, opts)
			elseif t.id == "convertFieldType" then
				frames = convertTypes(frames, opts)
			elseif t.id == "extractFields" then
				frames = extractFields(frames, opts, decode)
			else
				table.insert(notes, tostring(t.id))
			end
		end
	end
	return frames, notes
end

return M
