# showmap.py - Launches a map in the browser using an address from the
# command line or clipboard

import webbrowser, sys, pyperclip

if len(sys.argv) > 1:
    # Get address from command line arguments.
    address = ' '.join(sys.argv[1:])
else:
    # Get address from clipboard.
    address = pyperclip.paste()

# Open the web browser.
webbrowser.open('https://www.openstreetmap.org/search?query=' + address)