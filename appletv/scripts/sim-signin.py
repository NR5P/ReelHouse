#!/usr/bin/env python3
"""Sign the ReelHouse app in the Apple TV simulator in to a server, from the Mac.

Typing into the tvOS simulator is awkward, so this asks for the username and password here
(the password isn't echoed), signs in to the server, and hands the session cookie to the app
the same way it saves its own (UserDefaults `sessionCookies`). Relaunch the app afterwards.

    python3 scripts/sim-signin.py [server] [simulator-udid]
"""
import getpass
import http.cookiejar
import json
import subprocess
import sys
import urllib.request

SERVER = sys.argv[1] if len(sys.argv) > 1 else "http://192.168.10.8:3350"
UDID = sys.argv[2] if len(sys.argv) > 2 else "booted"
BUNDLE = "com.reelhouse.client.tv"
APPLE_EPOCH = 978307200  # Foundation's JSONEncoder writes dates as seconds since 2001

username = input("ReelHouse username: ").strip()
password = getpass.getpass("Password (hidden): ")

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
request = urllib.request.Request(
    f"{SERVER.rstrip('/')}/api/auth/login",
    data=json.dumps({"username": username, "password": password}).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    opener.open(request, timeout=15)
except urllib.error.HTTPError as error:
    sys.exit(f"Sign-in failed: HTTP {error.code}")

cookies = [
    {
        "name": c.name,
        "value": c.value,
        "domain": c.domain,
        "path": c.path,
        "expiresAt": (c.expires - APPLE_EPOCH) if c.expires else None,
    }
    for c in jar
]
if not cookies:
    sys.exit("Signed in, but the server sent no session cookie.")

subprocess.run(["xcrun", "simctl", "terminate", UDID, BUNDLE], capture_output=True)
subprocess.run(
    ["xcrun", "simctl", "spawn", UDID, "defaults", "write", BUNDLE, "sessionCookies",
     "-data", json.dumps(cookies).encode().hex()],
    check=True,
)
print("Signed in. Relaunch ReelHouse in the simulator.")
