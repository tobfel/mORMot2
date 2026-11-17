wrk.method = "POST"
wrk.body   = string.rep("p", tonumber(os.getenv("POSTKB") or "64") * 1024)
wrk.headers["Content-Type"] = "application/octet-stream"
