local function show(fn, s)
  print(("\n" .. string.rep("=",70) .. "\n%s\n" .. string.rep("=",70)):format(s))
  local ok, res = pcall(fn, s)
  if not ok then print("ERROR: " .. tostring(type(res)=="table" and res.msg or res)) return end
  if not res.ok then print("ERROR: " .. res.error) return end
  local n = 0
  for _, st in ipairs(res.steps) do
    local tag = st.kind
    if tag == "work" or tag == "answer" then n = n + 1; tag = "Step " .. n
    elseif tag == "given" then tag = "Given"
    elseif tag == "check" then tag = "Check"
    elseif tag == "warn" then tag = "!"
    else tag = "" end
    print(("%-8s %s"):format(tag, st.title))
    if st.body and st.body ~= "" then
      for line in (st.body.."\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then print("         " .. line) end
      end
    end
    if st.note then print("         ~ " .. st.note) end
  end
end
show(ENG.solve, "2(x+3)=5x-4")
show(ENG.solve, "6x^2+11x+3=0")
show(ENG.solve, "x^2+x-1=0")
show(ENG.solve, "sqrt(x+4)=x-2")
