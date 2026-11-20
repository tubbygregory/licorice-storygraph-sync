"""Receive native KOReader progress pushes and forward mapped editions to StoryGraph."""
import argparse
import hashlib
import hmac
import json
import logging
import math
import os
import sqlite3
import threading
import time
from contextlib import closing, contextmanager
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit
from uuid import UUID

import requests

from bridge import Handler, storygraph_progress

SCHEMA = """
CREATE TABLE IF NOT EXISTS progress (
    document TEXT PRIMARY KEY,
    payload TEXT NOT NULL,
    highest INTEGER NOT NULL,
    timestamp INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS delivered (
    document TEXT NOT NULL,
    edition TEXT NOT NULL,
    percent INTEGER NOT NULL,
    PRIMARY KEY (document, edition)
);
"""


class KOHandler(Handler):
    def authorized(self):
        user = self.headers.get("X-Auth-User", "").encode()
        key = self.headers.get("X-Auth-Key", "").encode()
        if hmac.compare_digest(user, self.server.user) and hmac.compare_digest(key, self.server.key):
            return True
        self.respond(401, {"message": "Unauthorized"})
        return False

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/users/auth":
            if self.authorized():
                self.respond(200, {"authorized": "OK"})
        elif path.startswith("/syncs/progress/"):
            if not self.authorized():
                return
            document = unquote(path.removeprefix("/syncs/progress/"))
            with self.server.database() as db:
                row = db.execute("SELECT payload, timestamp FROM progress WHERE document = ?", (document,)).fetchone()
            self.respond(200, {**json.loads(row[0]), "timestamp": row[1]} if row else {})
        else:
            self.respond(404, {"message": "Unknown endpoint"})

    def do_POST(self):
        self.respond(405, {"message": "Use the account configured on the bridge"})

    def do_PUT(self):
        if urlsplit(self.path).path != "/syncs/progress":
            self.respond(404, {"message": "Unknown endpoint"})
            return
        if not self.authorized():
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 16384:
                raise ValueError()
            body = json.loads(self.rfile.read(size))
            if not isinstance(body, dict):
                raise ValueError()
            document = body["document"]
            percentage = body["percentage"]
            if not isinstance(document, str) or not 0 < len(document) <= 256:
                raise ValueError()
            if type(percentage) not in (int, float) or not 0 <= percentage <= 1:
                raise ValueError()
            payload = {key: body[key] for key in ("document", "percentage", "progress", "device")}
            if "device_id" in body:
                payload["device_id"] = body["device_id"]
        except (ValueError, KeyError, TimeoutError):
            self.respond(400, {"message": "Invalid progress payload"})
            return

        timestamp = int(time.time())
        percent = math.floor(percentage * 100 + 1e-9)
        with self.server.database() as db:
            db.execute("""
                INSERT INTO progress VALUES (?, ?, ?, ?)
                ON CONFLICT(document) DO UPDATE SET
                    payload = excluded.payload,
                    highest = MAX(progress.highest, excluded.highest),
                    timestamp = excluded.timestamp
                """, (document, json.dumps(payload), percent, timestamp))
        logging.info("Progress received for %r (%d%%)", document, percent)
        self.respond(200, {"document": document, "timestamp": timestamp})


class KOServer(ThreadingHTTPServer):
    @contextmanager
    def database(self):
        with closing(sqlite3.connect(self.state)) as db, db:
            yield db

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(10)
        return connection, address


def deliver(server, session):
    with server.database() as db:
        rows = db.execute("SELECT document, highest FROM progress WHERE highest > 0").fetchall()
        confirmed = {
            (document, edition): percent
            for document, edition, percent in db.execute("SELECT document, edition, percent FROM delivered")
        }
    for document, percent in rows:
        edition = server.links.get(document)
        if not edition or percent <= confirmed.get((document, edition), 0):
            continue
        try:
            storygraph_progress(session, edition, percent)
        except ValueError as exc:
            logging.warning("Edition %s: %s", edition, exc)
        except requests.RequestException:
            logging.warning("Edition %s: StoryGraph connection failed", edition)
        else:
            with server.database() as db:
                db.execute("INSERT OR REPLACE INTO delivered VALUES (?, ?, ?)", (document, edition, percent))
            logging.info("StoryGraph progress checked for %s at %d%%", edition, percent)


def worker(server, cookies, stop):
    with requests.Session() as session:
        session.headers["Cookie"] = cookies
        while not stop.wait(30):
            deliver(server, session)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("kosync.json"))
    parser.add_argument("--state", type=Path, default=Path("kosync.sqlite3"))
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    cookies = os.environ.get("STORYGRAPH_COOKIE", "").strip()
    if "_storygraph_session=" not in cookies:
        parser.error("set STORYGRAPH_COOKIE to your signed-in StoryGraph Cookie header")
    if len(config["password"]) < 24:
        parser.error("use a dedicated random password of at least 24 characters")
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    with KOServer((args.bind, args.port), KOHandler) as server:
        server.user = config["username"].encode()
        server.key = hashlib.md5(config["password"].encode(), usedforsecurity=False).hexdigest().encode()
        server.links = {doc: str(UUID(edition)) for doc, edition in config["books"].items()}
        server.state = args.state
        if len(set(server.links.values())) != len(server.links):
            parser.error("map each StoryGraph edition to one document")
        with server.database() as db:
            db.executescript(SCHEMA)
        stop = threading.Event()
        background = threading.Thread(target=worker, args=(server, cookies, stop), daemon=True)
        background.start()
        logging.info("Listening on %s:%d with %d mapped books", args.bind, args.port, len(server.links))
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            stop.set()


if __name__ == "__main__":
    main()
