#!/bin/bash
# Run this Saturday afternoon on the demo machine before hacking begins.
# Opens the System Settings panels you need to grant permissions in.

echo "=== YC Voice Agent — macOS Permission Setup ==="
echo ""
echo "You need to grant the following permissions to your terminal app"
echo "(Terminal, iTerm2, or VS Code — whichever you run Python from)."
echo ""
echo "Opening each panel now. Grant access, then return here and press Enter."
echo ""

echo "[1/4] Accessibility — needed for push-to-talk hotkey capture"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
read -p "Press Enter when Accessibility is granted..."

echo ""
echo "[2/4] Full Disk Access — needed to read files from any location"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
read -p "Press Enter when Full Disk Access is granted..."

echo ""
echo "[3/4] Automation — needed to control Messages, Mail, Calendar, Contacts"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
read -p "Press Enter when Automation is granted..."

echo ""
echo "[4/4] Microphone — needed for voice recording"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
read -p "Press Enter when Microphone access is granted..."

echo ""
echo "=== All permissions configured. ==="
echo "Test iMessage with: osascript -e 'tell application \"Messages\" to get name of every account'"
echo "Test mic with:      python -c 'import pyaudio; p = pyaudio.PyAudio(); print(p.get_default_input_device_info())'"
echo "Test Playwright with: python -c 'from playwright.sync_api import sync_playwright; p = sync_playwright().start(); b = p.chromium.launch(); print(\"OK\"); b.close()'"
