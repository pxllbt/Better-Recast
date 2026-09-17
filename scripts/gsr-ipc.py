#!/usr/bin/env python3
"""pix.recast IPC client — sends commands to gpu-screen-recorder via unix socket.

Usage:
    gsr-ipc.py <socket_path> <command> [args...]

Commands:
    status          Check if gsr is running (prints "running" or "not running")
    toggle-pause    Pause/unpause recording
    set-paused      Pause (true) or unpause (false) — requires argument
    stop            Stop and save recording
"""

import socket
import sys
import json


def main():
    if len(sys.argv) < 3:
        print("Usage: gsr-ipc.py <socket_path> <command> [args...]", file=sys.stderr)
        sys.exit(1)

    socket_path = sys.argv[1]
    command = sys.argv[2]
    request_id = 1

    if command == "status":
        request = {"id": request_id, "name": "set-paused", "data": False}
        # status is not a real gsr command — just check if socket is reachable
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(2.0)
            s.connect(socket_path)
            s.sendall(json.dumps({"id": request_id, "name": "toggle-pause"}).encode() + b"\n")
            data = s.recv(4096)
            s.close()
            reply = json.loads(data.decode().strip())
            if reply.get("result") == "ok":
                print("running")
            else:
                print("not running")
        except (socket.error, OSError, json.JSONDecodeError, ValueError):
            print("not running")
        return

    # Build the request
    data = None
    if command == "set-paused" and len(sys.argv) >= 4:
        arg = sys.argv[3].lower()
        data = arg in ("true", "1", "yes")
    elif command == "stop-replay-recording" or command == "stop":
        pass  # no data needed
    elif command == "save-replay" and len(sys.argv) >= 4:
        try:
            seconds = int(sys.argv[3])
            data = {"seconds": seconds}
        except ValueError:
            pass

    request = {"id": request_id, "name": command}
    if data is not None:
        request["data"] = data

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10.0)
        s.connect(socket_path)
        s.sendall(json.dumps(request).encode() + b"\n")

        # Read reply (may be multi-line, find matching id)
        buf = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
            for line in buf.decode().split("\n"):
                line = line.strip()
                if not line:
                    continue
                try:
                    reply = json.loads(line)
                    if reply.get("id") == request_id:
                        s.close()
                        if reply.get("result") == "ok":
                            result_data = reply.get("data", "")
                            if result_data:
                                print(result_data)
                            else:
                                print("ok")
                            sys.exit(0)
                        else:
                            err = reply.get("data", "unknown error")
                            print("error: " + str(err), file=sys.stderr)
                            sys.exit(1)
                except json.JSONDecodeError:
                    continue
        s.close()
        print("error: no reply from gsr", file=sys.stderr)
        sys.exit(1)
    except (socket.error, OSError) as e:
        print("error: " + str(e), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
