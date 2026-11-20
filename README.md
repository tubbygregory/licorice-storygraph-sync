# Licorice StoryGraph Sync

Forward reading progress from an Xteink X4 Pro running XTOS Licorice to The StoryGraph.

- [InkApp lock screen](README.txt) looks up books automatically using the metadata available on the reader and syncs progress for unambiguous StoryGraph matches. Use the X4 Pro touchscreen to connect to the bridge and choose a lock-screen picture. Copy [storygraph.xtapp](storygraph.xtapp) to your SD card to install it. Requires Licorice build `26111201` or later.
- [Built-in KOReader Sync](KOSYNC.txt) keeps the normal lock screen and requires manual book mappings. The bridge forwards progress when the firmware sends it. Automatic sending on physical hardware is unverified.

Both modes require a running Python bridge and a StoryGraph browser session. The bridge uses StoryGraph's website forms, which can change. Local tests used mocked StoryGraph responses.

[View the on-device setup workflow](docs/setup-workflow.png). The renders use the app’s drawing code with a simulated firmware keyboard and network.
