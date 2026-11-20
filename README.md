# Licorice StoryGraph Sync

Forward reading progress from an Xteink X4 Pro running XTOS Licorice to The StoryGraph.

- [Built-in KOReader Sync](KOSYNC.txt) keeps the normal lock screen. The bridge forwards progress when the firmware sends it. Automatic sending on physical hardware is unverified.
- [InkApp lock screen](README.txt) checks for progress while the reader is locked. The app has a JPEG picture picker for photos copied to the SD card over USB. Copy [storygraph.xtapp](storygraph.xtapp) to your SD card to install it. Requires Licorice build `26111201` or later.

Both modes use a locally hosted Python bridge and a one-time mapping from each book to its StoryGraph edition. They advance percentages for editions already marked Currently Reading. The bridge uses StoryGraph's website form, which can change. Local tests used mocked StoryGraph responses.
