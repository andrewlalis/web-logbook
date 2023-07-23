#!/usr/bin/env bash

dub clean
rm -f web-logbook
dub build --build=release
echo "Stopping web-logbook service."
ssh -f root@andrewlalis.com 'systemctl stop web-logbook'
echo "Uploading new binary."
scp web-logbook root@andrewlalis.com:/opt/web-logbook/
echo "Starting web-logbook service."
ssh -f root@andrewlalis.com 'systemctl start web-logbook'
