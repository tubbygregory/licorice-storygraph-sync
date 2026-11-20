StoryGraph Sync for Xteink X4 Pro
=================================

Requires stock XTOS Licorice with Ink Apps and lock-screen networking
(API 2.26, firmware build 26111201 or later), Wi-Fi, and an always-on
computer running the local bridge. X4 Classic and other models are
unverified.

1. Copy storygraph.xtapp to the SD card root. Open it from All Files
   to install, then launch StoryGraph Sync from the Ink App drawer.
2. Open each ebook in the native reader, then open StoryGraph Sync.
   Copy the displayed reader book ID. In StoryGraph, set the matching
   edition to Currently Reading and copy the UUID from its /books/
   URL. Add each pair to bridge.json on the computer:

   {
     "token": "paste-your-random-token-here",
     "books": {
       "reader-book-id": "12345678-1234-1234-1234-123456789abc"
     }
   }

   Generate a token with:
     python -c "import secrets; print(secrets.token_urlsafe(32))"

3. Put bridge.txt in XTApps/storygraph/files/ on the SD card (create
   the files folder if needed). Use two lines, replacing both examples:

   http://192.168.1.20:8765
   paste-your-random-token-here

   The address must be reachable from the reader. Use a trusted private
   network for HTTP. The bridge also works behind an HTTPS reverse proxy
   with a device-trusted certificate. Keep the bridge off the public
   Internet. Only the bridge token and reading IDs/progress are sent
   over this connection.

4. On the computer, in this folder, use Python 3.10+:
     python -m venv .venv
     . .venv/bin/activate
     python -m pip install -r requirements.txt

   In your own signed-in StoryGraph browser, open Developer Tools >
   Network, reload the matching book page, and read the Cookie request
   header from the HTTPS request to app.thestorygraph.com. It must
   include _storygraph_session. Treat that header as an account secret.
   In Bash, load it without putting it in shell history:
     read -rs -p 'StoryGraph Cookie header: ' STORYGRAPH_COOKIE
     export STORYGRAPH_COOKIE
     python bridge.py --bind 192.168.1.20

   Replace the IP with the computer's LAN address. Restart the bridge
   when you change mappings or renew the browser session. Check bridge
   logs for rejected requests. Requests are scoped to app.thestorygraph.com.
   When the session expires, sign in again and supply an updated header.

5. Read a few pages and save your position by leaving the book. Tap
   Sync now and verify the percentage on the StoryGraph edition page.
   Then tap Enable automatic sync and confirm the firmware prompt to
   make StoryGraph Sync the default lock screen. It checks at lock and
   on roughly 15-minute wakeups when Wi-Fi is available. Leaving the
   device locked retries missed updates. Disable automatic sync or
   choose a different lock screen to turn this off.

The bridge uses integer percentages, only advances an edition, and
checks up to two changed mapped books per pass. It reads the existing
progress form and leaves status changes and rereads to StoryGraph.
For a reread, update your StoryGraph reading entry and restart the bridge
to clear its in-memory cache. An HTTP 200 on the device means the bridge
accepted the snapshot; verify your first update on StoryGraph. There is
no firmware hook here for syncing during ordinary page turns.

The StoryGraph form is unofficial and may change. This project has been
checked with mocks. Live StoryGraph writes and physical hardware use
require an account and a compatible device.

Rebuild from source
-------------------

The separate foreground and lock entry points use the shared sync.lua:

  cat sync.lua foreground.lua > app/index.lua
  cat sync.lua locked.lua > app/lockscreen.lua
  python /path/to/touch-licorice-apps/xtpack.py app -o storygraph.xtapp

Packer and XTApp API references:
https://github.com/omer-faruq-xteink/touch-licorice-apps
StoryGraph form reference:
https://github.com/cernoh/storygraph.koreader/blob/main/API.md
