StoryGraph Sync for Xteink X4 Pro
=================================

Requires stock XTOS Licorice with Ink Apps and lock-screen networking
(API 2.26, firmware build 26111201 or later), Wi-Fi, and an always-on
computer running the local bridge. X4 Classic and other models are
unverified. When upgrading, replace both the InkApp package and the
bridge script to enable book matching.

See README.md for Windows, macOS, and Linux setup commands. To keep
your PC off during sync, see docs/server-setup.md.

1. Copy storygraph.xtapp to the SD card root. Open it from All Files
   to install, then launch StoryGraph Sync from the Ink App drawer.
2. On the computer, create bridge.json in this folder:

   {
     "token": "paste-your-random-token-here",
     "books": {}
   }

   Generate a token with:
     python -c "import secrets; print(secrets.token_urlsafe(32))"

   Install the bridge dependencies in Python 3.10+:
     python -m venv .venv
     . .venv/bin/activate
     python -m pip install -r requirements.txt

   In your signed-in StoryGraph browser, open Developer Tools >
   Network, reload a book page, and copy the Cookie request header
   for the HTTPS request to app.thestorygraph.com. It must include
   _storygraph_session. Keep the header private. In Bash:
     read -rs -p 'StoryGraph Cookie header: ' STORYGRAPH_COOKIE
     export STORYGRAPH_COOKIE
     python bridge.py --bind 192.168.1.20

   Replace the example IP with the computer's LAN address. Use a
   trusted private network for HTTP. An HTTPS reverse proxy with a
   device-trusted certificate also works. Keep the bridge off the
   public Internet. If the session expires, sign in again and restart
   the bridge with an updated Cookie header.

3. On the reader, open StoryGraph Sync > StoryGraph setup. Enter the
   Bridge address (for example http://192.168.1.20:8765) and the token
   from bridge.json, then tap Connect and save. Bridge connected
   confirms the reader can reach and authenticate to the bridge.
   Existing bridge.txt settings still work.

4. Read a few pages on the X4 Pro. Open StoryGraph Sync, tap Sync now,
   and verify the percentage on StoryGraph. The app uses the book
   metadata Licorice exposes. The bridge checks for an exact title and
   author match, or verifies the ISBN when the reader supplies one. It skips ambiguous matches and books with insufficient
   metadata. Existing book mappings in bridge.json are retained.

5. In StoryGraph Sync, tap Enable automatic sync and confirm the
   firmware prompt to make StoryGraph Sync the default lock screen.
   The app checks at lock and on roughly 15-minute wakes while Wi-Fi is
   available. Tap Disable automatic sync or choose another lock screen
   to turn this off.

Custom lock-screen picture
--------------------------

1. In StoryGraph Sync, tap Choose lock screen picture. To import
   over Wi-Fi, tap Import JPEG from URL and type a direct HTTPS
   address for a JPEG you can access without signing in. A web
   gallery or sharing page will not work. A successful download
   becomes the selected wallpaper.
2. You can also copy JPEGs over USB to XTApps/storygraph/files/ on
   the SD card, then tap the filename on the reader. Use filenames
   without spaces, such as forest.jpg. In either mode the JPEG must
   be at most 480 x 800 pixels and 512 KiB. A 480 x 800 portrait
   image fills the display. Lock the reader to see the selection.
3. Select Use default screen in the picker to restore the built-in
   display. A missing or unreadable picture falls back to it.

This setting applies to the InkApp lock screen. The built-in KOReader
Sync mode uses the device's regular wallpaper settings.

The bridge uses integer percentages and only advances progress. It
checks one new match or up to two already-mapped books per pass. A newly
matched book can be marked Currently Reading when StoryGraph shows it
as untracked and the progress is below 100%. Finishing a book does not
change its reading status. For a reread, update your StoryGraph reading
entry and restart the bridge to clear its in-memory cache. Verify your
first update on StoryGraph. Sync runs when requested or on a lock-screen
wake.

The StoryGraph form is unofficial and may change. This project has been
checked with mocks. Live StoryGraph writes and physical hardware use
require an account and a compatible device.

Rebuild from source
-------------------

The separate foreground and lock entry points use the shared sync.lua:

  cat sync.lua wallpaper.lua setup.lua foreground.lua > app/index.lua
  cat sync.lua wallpaper.lua locked.lua > app/lockscreen.lua
  python /path/to/touch-licorice-apps/xtpack.py app -o storygraph.xtapp

Packer and XTApp API references:
https://github.com/omer-faruq-xteink/touch-licorice-apps
StoryGraph form reference:
https://github.com/cernoh/storygraph.koreader/blob/main/API.md
