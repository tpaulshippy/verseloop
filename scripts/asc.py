#!/usr/bin/env python3
"""Minimal App Store Connect API helper (JWT via .p8, no secrets in repo).

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
Usage: asc.py apps | create-app
"""
import json
import os
import sys
import time
import urllib.request

import jwt

KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER_ID = os.environ["ASC_ISSUER_ID"]
KEY_PATH = os.environ["ASC_KEY_PATH"]
BASE = "https://api.appstoreconnect.apple.com"


def token():
    with open(KEY_PATH) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path,
        data=data,
        method=method,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def main():
    cmd = sys.argv[1]
    if cmd == "apps":
        status, out = call("GET", "/v1/apps?filter[bundleId]=com.tpaulshippy.verseloop&limit=1")
        print(json.dumps({"status": status, "apps": out.get("data", [])}, indent=1))
    elif cmd == "create-app":
        status, out = call(
            "POST",
            "/v1/apps",
            {"data": {"type": "apps", "attributes": {
                "bundleId": "com.tpaulshippy.verseloop",
                "name": "VerseLoop",
                "primaryLocale": "en-US",
                "sku": "verseloop",
            }}},
        )
        print(json.dumps({"status": status, "result": out}, indent=1)[:2000])
    elif cmd == "create-bundle-id":
        status, out = call(
            "POST",
            "/v1/bundleIds",
            {"data": {"type": "bundleIds", "attributes": {
                "identifier": "com.tpaulshippy.verseloop",
                "name": "VerseLoop",
                "platform": "IOS",
            }}},
        )
        print(json.dumps({"status": status, "result": out}, indent=1)[:2000])
    elif cmd == "create-cert":
        csr = open(sys.argv[2]).read()
        status, out = call(
            "POST",
            "/v1/certificates",
            {"data": {"type": "certificates", "attributes": {
                "certificateType": "DISTRIBUTION",
                "csrContent": csr,
            }}},
        )
        print(json.dumps({"status": status, "result": out}, indent=1)[:3000])
    elif cmd == "create-profile":
        bundle_id, cert_id = sys.argv[2], sys.argv[3]
        status, out = call(
            "POST",
            "/v1/profiles",
            {"data": {"type": "profiles", "attributes": {
                "name": "VerseLoop AppStore",
                "profileType": "IOS_APP_STORE",
            }, "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
            }}},
        )
        print(json.dumps({"status": status, "result": out}, indent=1)[:3000])
    else:
        sys.exit(f"unknown command: {cmd}")


if __name__ == "__main__":
    main()
