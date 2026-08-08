#!/usr/bin/env bash
# DevContainer Post-Start Script

# Runs after every start (including from prebuild).
# Host: tailscale serve --service=svc:openchamber --https=443 http://127.0.0.1:4098
openchamber --port 4098
