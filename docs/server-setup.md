# Run the bridge on a server

Run a private instance of the **InkApp bridge** on a Linux server or VPS you control. The X4 Pro connects to that server over HTTPS, so your personal computer can be off during reading and sync. The same `storygraph.xtapp` works with either a local or remote bridge.

A trusted home server is also suitable for local Wi-Fi. For that setup, follow [the standard bridge instructions](../README.md#2-start-the-bridge-on-your-computer) on the home server and pair the reader with its LAN address.

## Before you start

- A Linux server with Docker Engine and Docker Compose v2. Run the commands over SSH from a non-root account that can run Docker.
- A DNS hostname pointing to the server, such as `sync.example.com`. Allow inbound TCP ports `80` and `443` for Caddy’s HTTPS setup. The Python bridge runs on the container network.
- A StoryGraph browser session. Your server holds the session cookie, so use a server you trust and keep access to the account and the deployment files private.
- A current copy of the [project files](https://github.com/tubbygregory/licorice-storygraph-sync/archive/refs/heads/main.zip) on the server.

## 1. Configure the server

Open a Bash shell in the extracted project folder on the server. Replace `sync.example.com` with your actual DNS hostname. Run these commands for initial setup.

```bash
umask 077
mkdir -p .bridge-state/config
printf 'BRIDGE_HOST=%s\nBRIDGE_UID=%s\nBRIDGE_GID=%s\n' \
  'sync.example.com' "$(id -u)" "$(id -g)" > .env
```

Generate a pairing token. Save it in `.bridge-state/config/bridge.json` and keep a copy for the reader.

```bash
docker run --rm python:3.12-slim python -c 'import secrets; print(secrets.token_urlsafe(32))'
```

```json
{
  "token": "paste-your-generated-token-here",
  "books": {}
}
```

If you’re moving an existing setup, copy your current `bridge.json` into `.bridge-state/config/` to keep the token and saved book matches.

## 2. Load your StoryGraph session

In a browser where you’re signed in to StoryGraph, open **Developer Tools → Network** and reload a StoryGraph book page. Copy the **Cookie** value under **Request Headers** for the request to `app.thestorygraph.com`. It should include `_storygraph_session`.

In the Bash shell on the server, paste it at the hidden prompt. The file stays on the server and Docker mounts it into the bridge container as a secret.

```bash
umask 077
IFS= read -rs -p 'StoryGraph Cookie header: ' storygraph_cookie
printf '\n'
printf '%s\n' "$storygraph_cookie" > .bridge-state/storygraph-cookie.txt
unset storygraph_cookie
```

## 3. Start the HTTPS service

```bash
docker compose up -d --build
docker compose logs --tail=50
```

Caddy obtains and renews the HTTPS certificate. If certificate issuance fails, check the DNS record and confirm ports `80` and `443` are reachable. [Caddy automatic HTTPS](https://caddyserver.com/docs/automatic-https)

On the X4 Pro, open **StoryGraph Sync → StoryGraph setup**. Enter the HTTPS address, such as `https://sync.example.com`, and the pairing token from your server’s `bridge.json`. Tap **Connect and save**. Read a few pages, try **Sync now**, and verify the book’s progress in StoryGraph. Pairing only tests the connection to the bridge. Some hosting networks may be rejected by StoryGraph.

## Maintain the server

- If your StoryGraph session expires, repeat step 2 and run `docker compose up -d --force-recreate bridge`.
- To update, replace the project files while keeping `.env` and `.bridge-state/`, then run `docker compose up -d --build`. Keep one bridge instance so that book mappings are written consistently.
- To stop the server, run `docker compose down`. The saved book mappings and Caddy certificate volumes are retained.
