-- mixed workload: 50% hello, 25% json, 10% 100KB, 10% POST 64KB, 5% sleep 20ms
local body = string.rep("p", 65536)
request = function()
  local r = math.random(100)
  if r <= 50 then return wrk.format("GET", "/hello.php")
  elseif r <= 75 then return wrk.format("GET", "/json.php")
  elseif r <= 85 then return wrk.format("GET", "/big.php?kb=100")
  elseif r <= 95 then return wrk.format("POST", "/post.php", {["Content-Type"]="application/octet-stream"}, body)
  else return wrk.format("GET", "/sleep.php?ms=20") end
end
