# Licorice StoryGraph Sync

Forward reading progress from an Xteink X4 Pro running XTOS Licorice to The StoryGraph.

- [Built-in KOReader Sync](KOSYNC.txt) keeps the normal lock screen. The bridge forwards progress when the firmware sends it. Automatic sending on physical hardware is unverified.
- [InkApp lock screen](README.txt) checks for progress while the reader is locked. Use the X4 Pro touchscreen to connect to the bridge, link the current book, and select a JPEG from the SD card or import one from an HTTPS URL. Copy [storygraph.xtapp](storygraph.xtapp) to your SD card to install it. Requires Licorice build `26111201` or later.

Both modes use a locally hosted Python bridge and a one-time mapping from each book to its StoryGraph edition. They advance percentages for editions already marked Currently Reading. The bridge uses StoryGraph's website form, which can change. Local tests used mocked StoryGraph responses.

[View the on-device setup workflow](docs/setup-workflow.png). The renders use the app’s drawing code with a simulated firmware keyboard and network.
