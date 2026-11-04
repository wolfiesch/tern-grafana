local units = require("../units")
local regex = require("../regex")

local function eq(got: any, want: any, what: string)
	assert(got == want, what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end

-- What Grafana's value formatters print for the same input.
eq(units.format(1536, "bytes", 2), "1.50 KiB", "bytes")
eq(units.format(0.4567, "percentunit", 1), "45.7%", "percentunit")
eq(units.format(1500000, "short", 1), "1.5 Mil", "short")
eq(units.format(2.5, "decgbytes", 1), "2.5 GB", "decgbytes")
eq(units.format(0 / 0, "short"), "NaN", "NaN")
eq(units.format(nil, "short"), "No data", "missing")
eq(units.format(1, "bool_yes_no"), "Yes", "bool")
eq(units.format(12, "suffix: req"), "12 req", "suffix")
eq(units.format(-5, "currencyUSD", 0), "-$5", "currency")

-- Grafana matchers take JavaScript regexes; the subset dashboards use must match like JS.
assert(regex.test("^Value #(cpu|mem)$", "Value #mem"), "alternation")
assert(not regex.test("^Value #(cpu|mem)$", "Value #disk"), "anchored")
assert(regex.test("/^node_.*/i", "NODE_load1"), "slash form with flags")
assert(regex.test("\\d+\\.\\d", "v1.2"), "escapes")

print("units tests passed")
