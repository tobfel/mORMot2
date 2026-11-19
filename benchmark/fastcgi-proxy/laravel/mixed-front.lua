-- 35% /api/items, 35% /page, 15% welcome, 15% static robots.txt (front controller, pretty URLs)
request = function()
  local r = math.random(20)
  local p = r <= 7 and "/api/items" or (r <= 14 and "/page" or (r <= 17 and "/" or "/robots.txt"))
  return wrk.format("GET", p)
end
