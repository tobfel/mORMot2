-- mixed Laravel workload: 40% /api/items, 40% /page, 20% welcome; PREFIX=/index.php for mORMot
local pre = os.getenv("PREFIX") or ""
local paths = {pre .. "/api/items", pre .. "/page", (pre ~= "" and pre or "/")}
request = function()
  local r = math.random(10)
  local p = r <= 4 and paths[1] or (r <= 8 and paths[2] or paths[3])
  return wrk.format("GET", p)
end
