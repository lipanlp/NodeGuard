#!/usr/bin/env python3
"""Exercise real Unix HTTP I/O against a fake Mihomo; never touches Clash or signals Claude."""
import json, os, socket, subprocess, threading, uuid
from pathlib import Path
root = Path(__file__).resolve().parent.parent
socket_path = '/tmp/ng-' + uuid.uuid4().hex[:12] + '.sock'
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(socket_path); os.chmod(socket_path, 0o600); server.listen(8); server.settimeout(.2)
stop = threading.Event(); calls = []; selected = ['A']; failures = []
def serve():
    while not stop.is_set():
        try: conn, _ = server.accept()
        except socket.timeout: continue
        except OSError: break
        try:
            conn.settimeout(2); data = b''
            while b'\r\n\r\n' not in data: data += conn.recv(8192)
            header, body = data.split(b'\r\n\r\n', 1)
            method, path, _ = header.decode().split('\r\n')[0].split(' ')
            length = next((int(x.split(':', 1)[1]) for x in header.decode().split('\r\n')[1:] if x.lower().startswith('content-length:')), 0)
            while len(body) < length: body += conn.recv(8192)
            assert path == '/proxies/KTM%E5%89%8D%E7%BD%AE%E8%8A%82%E7%82%B9', path
            calls.append(method)
            if method == 'PUT':
                assert json.loads(body) == {'name': 'B'}
                selected[0] = 'B'; status = '204 No Content'; payload = b''
            else:
                assert method == 'GET'
                status = '200 OK'; payload = json.dumps({'name':'KTM前置节点','type':'Selector','now':selected[0],'all':['A','B','C']}).encode()
            conn.sendall(('HTTP/1.1 '+status+'\r\nConnection: close\r\nContent-Length: '+str(len(payload))+'\r\n\r\n').encode()+payload)
        except Exception as error: failures.append(str(error))
        finally: conn.close()
thread = threading.Thread(target=serve, daemon=True); thread.start()
proxy = socket.socket(socket.AF_INET, socket.SOCK_STREAM); proxy.bind(('127.0.0.1', 0)); proxy.listen(1); proxy.settimeout(.2)
def stall_proxy():
    while not stop.is_set():
        try: conn, _ = proxy.accept()
        except socket.timeout: continue
        except OSError: return
        try:
            conn.settimeout(3)
            while conn.recv(4096): pass
        except (OSError, socket.timeout): pass
        finally: conn.close()
proxy_thread = threading.Thread(target=stall_proxy, daemon=True); proxy_thread.start()
try:
    binary = root / 'work' / ('build-' + os.uname().machine) / 'NodeGuardTests'
    result = subprocess.run([str(binary), '--mock-socket', socket_path, '--cancel-proxy-port', str(proxy.getsockname()[1])], capture_output=True, text=True, timeout=20)
    print(result.stdout, end='')
    assert result.returncode == 0, result.stderr
    assert not failures, failures
    assert calls == ['GET','PUT','GET','GET','GET'], calls
    print('PASS mock server: exactly one PUT; manual selection preserved; real Clash unchanged')
finally:
    stop.set(); server.close(); proxy.close(); thread.join(1); proxy_thread.join(1); Path(socket_path).unlink(missing_ok=True)
