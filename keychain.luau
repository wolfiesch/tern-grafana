-- The Grafana token in the macOS login keychain, through /usr/bin/security. `tern.secrets` is window-only
-- and the host half sends every request, so both halves go through `security` instead: an item that
-- `security` creates lists `security` in its access list, so later reads from either half need no prompt.
-- The token reaches `security` on stdin, never in argv.

local M = {}

local SECURITY = "/usr/bin/security"
local SERVICE, ACCOUNT, LABEL = "tern-grafana", "token", "Grafana token (Tern)"
local TIMEOUT_MS = 10_000

-- Whether this machine stores the token in the keychain; elsewhere it stays in kv.json.
function M.available(): boolean
	return tern.runtime.os == "macos"
end

local function missing(res: any): boolean
	return res.status ~= 0 and res.stderr:find("could not be found", 1, true) ~= nil
end

local function failure(res: any): string
	if res.timed_out then return "security did not answer within 10s" end
	local msg = res.stderr:match("^%s*(.-)%s*$") :: string
	return if msg ~= "" then msg else "security exited " .. tostring(res.status)
end

-- Calls `done(token?, err?, cx?)`: no token and no error when none is stored.
function M.read(done: (string?, string?, any) -> ())
	tern.process.run({ SECURITY, "find-generic-password", "-s", SERVICE, "-a", ACCOUNT, "-w" }, { timeout_ms = TIMEOUT_MS }, function(res, cx)
		if res.status == 0 then
			local t = res.stdout:match("^%s*(.-)%s*$") :: string
			done(if t ~= "" then t else nil, nil, cx)
		elseif missing(res) then
			done(nil, nil, cx)
		else
			done(nil, failure(res), cx)
		end
	end)
end

-- Stores `token`, replacing any; calls `done(err?, cx?)`. `security` asks for the password twice when -w
-- ends the arguments, so stdin carries it twice.
function M.write(token: string, done: (string?, any) -> ())
	local argv = { SECURITY, "add-generic-password", "-U", "-s", SERVICE, "-a", ACCOUNT, "-l", LABEL, "-w" }
	tern.process.run(argv, { stdin = token .. "\n" .. token .. "\n", timeout_ms = TIMEOUT_MS }, function(res, cx)
		done(if res.status == 0 then nil else failure(res), cx)
	end)
end

-- Deletes the stored token, if any; calls `done(err?, cx?)`.
function M.clear(done: (string?, any) -> ())
	tern.process.run({ SECURITY, "delete-generic-password", "-s", SERVICE, "-a", ACCOUNT }, { timeout_ms = TIMEOUT_MS }, function(res, cx)
		done(if res.status == 0 or missing(res) then nil else failure(res), cx)
	end)
end

-- kv "token_rev" counts keychain changes, so the host half knows to read the keychain again.
function M.bump()
	local ok, rev = pcall(tern.kv.get, "token_rev")
	tern.kv.set("token_rev", (if ok and type(rev) == "number" then rev else 0) + 1)
end

return M
