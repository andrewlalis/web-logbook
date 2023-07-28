#!/usr/bin/env bash

# Build and deploy script for deploying this service to my VPS. Note that
# you'll need SSH authentication to run this.
# I just include it here for ease of use.

dub clean
rm -f web-logbook
dub build --build=release --compiler=/opt/ldc2/ldc2-1.33.0-linux-x86_64/bin/ldc2
echo "Stopping web-logbook service."
ssh -f root@andrewlalis.com 'systemctl stop web-logbook'
echo "Uploading new binary."
scp web-logbook root@andrewlalis.com:/opt/web-logbook/
echo "Starting web-logbook service."
ssh -f root@andrewlalis.com 'systemctl start web-logbook'
