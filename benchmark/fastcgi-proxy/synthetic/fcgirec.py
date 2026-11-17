import socket, struct, sys, collections
def rec(t, c): return struct.pack('>BBHHBB', 1, t, 1, len(c), 0, 0) + c
def nv(n, v):
    n, v = n.encode(), v.encode()
    return bytes([len(n)]) + (bytes([len(v)]) if len(v) < 128 else struct.pack('>I', len(v) | 0x80000000)) + n + v
params = b''.join(nv(k, v) for k, v in [('SCRIPT_FILENAME', '/srv/bench/www/big.php'), ('REQUEST_METHOD', 'GET'),
    ('QUERY_STRING', 'kb=' + sys.argv[1]), ('SERVER_PROTOCOL', 'HTTP/1.1')])
s = socket.socket(socket.AF_UNIX); s.connect('/srv/bench/run/php-fpm.sock')
s.sendall(rec(1, struct.pack('>HB5x', 1, 0)) + rec(4, params) + rec(4, b'') + rec(5, b''))
buf = b''; recvs = collections.Counter(); sizes = collections.Counter()
while True:
    d = s.recv(1 << 20)
    if not d: break
    recvs[len(d) // 4096 * 4096] += 1; buf += d
i = 0
while i < len(buf):
    v, t, rid, cl, pl, _ = struct.unpack('>BBHHBB', buf[i:i+8]); sizes[(t, cl)] += 1; i += 8 + cl + pl
print('records (type,len):count', sorted(sizes.items())[:10], '... total', sum(sizes.values()))
print('recv sizes (4KB buckets):', sorted(recvs.items())[:10], 'total recvs', sum(recvs.values()))
