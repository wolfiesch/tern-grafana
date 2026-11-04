-- A small backtracking regex for Grafana's byRegexp matchers and regex options (JS syntax, `/src/flags`).
-- Supports literals, `.`, classes `[...]` and `\d \w \s` (negated too), anchors, groups, `|`,
-- and the quantifiers `* + ? {n} {n,} {n,m}` (lazy forms match greedily; only the yes/no answer is used).
-- compile(src) -> matcher | nil, err ; matcher(s) -> boolean (searches anywhere unless anchored).

local M = {}

type Node = { t: string, [string]: any }

local function classFn(ch: string, negate: boolean): (string) -> boolean
	local f: (string) -> boolean
	if ch == "d" then
		f = function(c) return c:match("%d") ~= nil end
	elseif ch == "w" then
		f = function(c) return c:match("[%w_]") ~= nil end
	elseif ch == "s" then
		f = function(c) return c:match("%s") ~= nil end
	else
		f = function(c) return c == ch end
	end
	if negate then return function(c) return not f(c) end end
	return f
end

local ESCAPES: { [string]: string } = { n = "\n", t = "\t", r = "\r" }

local function escapeAtom(c: string): Node
	if c == "d" or c == "w" or c == "s" then return { t = "set", f = classFn(c, false) } end
	if c == "D" or c == "W" or c == "S" then return { t = "set", f = classFn(c:lower(), true) } end
	return { t = "char", c = ESCAPES[c] or c }
end

local function parse(src: string, fold: boolean): Node
	local pos = 1
	local n = #src

	local parseAlt: () -> Node

	local function peek(): string
		return src:sub(pos, pos)
	end

	local function parseClass(): Node
		-- pos is after '['
		local negate = false
		if peek() == "^" then
			negate = true
			pos += 1
		end
		local tests: { (string) -> boolean } = {}
		local first = true
		while pos <= n and (peek() ~= "]" or first) do
			first = false
			local c = peek()
			pos += 1
			local test: (string) -> boolean
			if c == "\\" then
				local e = peek()
				pos += 1
				if e == "d" or e == "w" or e == "s" then
					test = classFn(e, false)
				elseif e == "D" or e == "W" or e == "S" then
					test = classFn(e:lower(), true)
				else
					local lit = ESCAPES[e] or e
					test = function(x) return x == lit end
				end
			elseif peek() == "-" and src:sub(pos + 1, pos + 1) ~= "]" and pos + 1 <= n then
				local hi = src:sub(pos + 1, pos + 1)
				pos += 2
				local lo = c
				test = function(x) return x >= lo and x <= hi end
			else
				test = function(x) return x == c end
			end
			table.insert(tests, test)
		end
		if peek() ~= "]" then error("unterminated [") end
		pos += 1
		return {
			t = "set",
			f = function(x)
				local hit = false
				for _, test in tests do
					if test(x) or (fold and (test(x:lower()) or test(x:upper()))) then
						hit = true
						break
					end
				end
				return hit ~= negate
			end,
		}
	end

	local function parseAtom(): Node?
		local c = peek()
		if c == "" or c == "|" or c == ")" then return nil end
		pos += 1
		if c == "(" then
			if src:sub(pos, pos + 1) == "?:" or src:sub(pos, pos + 1) == "?=" or src:sub(pos, pos + 1) == "?!" then
				pos += 2
			end
			local inner = parseAlt()
			if peek() ~= ")" then error("unterminated (") end
			pos += 1
			return inner
		elseif c == "[" then
			return parseClass()
		elseif c == "." then
			return { t = "any" }
		elseif c == "^" then
			return { t = "bol" }
		elseif c == "$" then
			return { t = "eol" }
		elseif c == "\\" then
			local e = peek()
			if e == "" then error("trailing \\") end
			pos += 1
			return escapeAtom(e)
		end
		return { t = "char", c = c }
	end

	local function parseSeq(): Node
		local items: { Node } = {}
		while true do
			local atom = parseAtom()
			if not atom then break end
			local q = peek()
			local lo, hi = nil, nil
			if q == "*" then
				lo, hi = 0, math.huge
				pos += 1
			elseif q == "+" then
				lo, hi = 1, math.huge
				pos += 1
			elseif q == "?" then
				lo, hi = 0, 1
				pos += 1
			elseif q == "{" then
				local a, b, close = src:match("^{(%d*),?(%d*)()}", pos)
				local body = src:match("^{([%d,]*)}", pos)
				if body and a ~= nil and a ~= "" then
					lo = tonumber(a)
					if body:find(",") then
						hi = if b ~= "" then tonumber(b) else math.huge
					else
						hi = lo
					end
					pos += #body + 2
					local _ = close
				end
			end
			if lo ~= nil then
				if peek() == "?" then pos += 1 end
				atom = { t = "rep", node = atom, lo = lo, hi = hi }
			end
			table.insert(items, atom)
		end
		return { t = "seq", items = items }
	end

	parseAlt = function(): Node
		local opts = { parseSeq() }
		while peek() == "|" do
			pos += 1
			table.insert(opts, parseSeq())
		end
		if #opts == 1 then return opts[1] end
		return { t = "alt", opts = opts }
	end

	local root = parseAlt()
	if pos <= n then error("unexpected " .. src:sub(pos, pos)) end
	return root
end

local function matchNode(node: Node, s: string, i: number, fold: boolean, k: (number) -> boolean): boolean
	local t = node.t
	if t == "char" then
		local c = s:sub(i, i)
		if c == node.c or (fold and c:lower() == node.c:lower() and c ~= "") then return k(i + 1) end
		return false
	elseif t == "any" then
		local c = s:sub(i, i)
		if c ~= "" and c ~= "\n" then return k(i + 1) end
		return false
	elseif t == "set" then
		local c = s:sub(i, i)
		if c ~= "" and node.f(c) then return k(i + 1) end
		return false
	elseif t == "bol" then
		if i == 1 then return k(i) end
		return false
	elseif t == "eol" then
		if i == #s + 1 then return k(i) end
		return false
	elseif t == "seq" then
		local items = node.items
		local function step(idx: number, j: number): boolean
			if idx > #items then return k(j) end
			return matchNode(items[idx], s, j, fold, function(nj) return step(idx + 1, nj) end)
		end
		return step(1, i)
	elseif t == "alt" then
		for _, opt in node.opts do
			if matchNode(opt, s, i, fold, k) then return true end
		end
		return false
	elseif t == "rep" then
		local function rep(count: number, j: number): boolean
			if count < node.hi then
				local progressed = matchNode(node.node, s, j, fold, function(nj)
					if nj == j then return false end
					return rep(count + 1, nj)
				end)
				if progressed then return true end
			end
			if count >= node.lo then return k(j) end
			return false
		end
		return rep(0, i)
	end
	return false
end

-- `/src/flags` (JS style) or a bare pattern.
function M.compile(text: string): (((string) -> boolean)?, string?)
	local src, flags = text:match("^/(.*)/([gimsuy]*)$")
	if not src then
		src, flags = text, ""
	end
	local fold = (flags :: string):find("i") ~= nil
	local ok, root = pcall(parse, src :: string, fold)
	if not ok then return nil, tostring(root) end
	local node = root :: Node
	return function(s: string): boolean
		for start = 1, #s + 1 do
			if matchNode(node, s, start, fold, function() return true end) then return true end
		end
		return false
	end, nil
end

local cache: { [string]: any } = {}

-- Cached compile; an invalid pattern never matches.
function M.test(pattern: string, s: string): boolean
	local m = cache[pattern]
	if m == nil then
		local f = M.compile(pattern)
		m = f or false
		cache[pattern] = m
	end
	if m == false then return false end
	return (m :: (string) -> boolean)(s)
end

return M
