-- Development probe: splices a test body onto the end of src/eqsolver.lua so
-- the file's file-local helpers are in scope, then runs it under desktop Lua.
--   lua5.1 tests/probe.lua tests/bodies/foo.lua
package.path = "./tests/?.lua;" .. package.path
require("mock_nspire")

local srcFile = io.open("src/eqsolver.lua", "r")
local src = srcFile:read("*a")
srcFile:close()

local bodyFile = io.open(arg[1], "r")
local body = bodyFile:read("*a")
bodyFile:close()

local combined = src .. "\n\nlocal function __probe()\n" .. body .. "\nend\n__probe()\n"
local chunk, err = loadstring(combined, "@eqsolver+probe")
if not chunk then
  io.stderr:write("load error: " .. tostring(err) .. "\n")
  os.exit(1)
end
chunk()
