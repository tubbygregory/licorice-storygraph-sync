"""Local, single-user bridge from XTApp snapshots to StoryGraph."""
import argparse
import hmac
import json
import logging
import os
import re
import tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from uuid import UUID

import requests
from bs4 import BeautifulSoup

SITE = "https://app.thestorygraph.com"
MAX_BODY = 60_000


def progress_form(session, edition):
    book_url = f"{SITE}/books/{edition}"
    page = session.get(book_url, timeout=5, allow_redirects=False)
    if page.status_code != 200:
        raise ValueError(f"book page HTTP {page.status_code}")
    soup = BeautifulSoup(page.text, "html.parser")
    form = soup.select_one('form[action="/update-progress"]')
    csrf = soup.select_one('meta[name="csrf-token"][content]')
    previous = form and form.select_one('input[name="read_status[last_reached_percent]"][value]')
    if not (form and csrf and previous):
        raise ValueError("progress form unavailable; check sign-in and Currently Reading status")
    return book_url, form, csrf, int(previous["value"] or "0")


def storygraph_progress(session, edition, percent):
    book_url, form, csrf, last = progress_form(session, edition)
    if percent <= last:
        return

    fields = {
        field["name"]: field.get("value", "")
        for field in form.select('input[type="hidden"][name]:not([disabled])')
    }
    if fields.get("book_id", edition) != edition:
        raise ValueError("progress form is for a different edition")
    fields.update({
        "authenticity_token": form.select_one('input[name="authenticity_token"]')["value"]
        if form.select_one('input[name="authenticity_token"][value]') else csrf["content"],
        "read_status[progress_number]": percent,
        "read_status[progress_type]": "percentage",
        "book_id": edition,
        "commit": "Save",
    })
    reply = session.post(
        f"{SITE}/update-progress", data=fields, timeout=5, allow_redirects=False,
        headers={
            "X-CSRF-Token": csrf["content"],
            "X-Requested-With": "XMLHttpRequest",
            "Accept": "text/javascript, application/javascript",
            "Origin": SITE,
            "Referer": book_url,
        },
    )
    if reply.status_code != 200 or "javascript" not in reply.headers.get("Content-Type", ""):
        raise ValueError(f"unexpected progress reply (HTTP {reply.status_code})")


class Handler(BaseHTTPRequestHandler):
    def respond(self, code, result):
        data = json.dumps(result).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path not in ("/sync", "/pair", "/link"):
            self.respond(404, {})
            return
        auth = self.headers.get("Authorization", "")
        if not hmac.compare_digest(auth.encode(), self.server.auth):
            self.respond(401, {})
            return
        if self.path == "/pair":
            self.respond(200, {})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_BODY:
                raise ValueError()
            data = json.loads(self.rfile.read(length))
            if not isinstance(data, dict):
                raise ValueError()
        except (ValueError, TimeoutError):
            self.respond(400, {"error": "invalid book progress"})
            return

        if self.path == "/link":
            self.link_book(data)
            return
        if any(type(value) is not int or not 0 <= value <= 100 for value in data.values()):
            self.respond(400, {"error": "invalid book progress"})
            return

        # Cap remote work per request to fit the reader's network timeout.
        errors = 0
        deferred = 0
        attempted = 0
        for reader_id, edition in list(self.server.links.items()):
            percent = data.get(reader_id, 0)
            if percent <= self.server.confirmed.get(edition, 0):
                continue
            if attempted == 2:
                deferred += 1
                continue
            attempted += 1
            # Rotate attempted books so a failing edition cannot starve later books.
            self.server.links.pop(reader_id)
            self.server.links[reader_id] = edition
            try:
                storygraph_progress(self.server.session, edition, percent)
            except ValueError as exc:
                logging.warning("Edition %s: %s", edition, exc)
                errors += 1
            except requests.RequestException:
                logging.warning("Edition %s: StoryGraph connection failed", edition)
                errors += 1
            else:
                self.server.confirmed[edition] = percent
        self.respond(502 if errors else 200, {"checked": attempted, "deferred": deferred, "errors": errors})


    def link_book(self, data):
        reader_id = data.get("reader_id")
        try:
            if not isinstance(reader_id, str) or not 0 < len(reader_id) <= 256:
                raise ValueError()
            edition = str(UUID(data.get("edition", "")))
        except (TypeError, AttributeError, ValueError):
            self.respond(400, {"error": "invalid book or edition ID"})
            return
        if any(key != reader_id and value == edition for key, value in self.server.links.items()):
            self.respond(409, {"error": "edition already linked to another book"})
            return
        try:
            progress_form(self.server.session, edition)
        except (ValueError, requests.RequestException):
            self.respond(502, {"error": "StoryGraph progress form unavailable"})
            return
        links = {**self.server.links, reader_id: edition}
        try:
            save_links(self.server.config_path, links)
        except (OSError, ValueError):
            logging.exception("Could not save book links")
            self.respond(500, {"error": "could not save links"})
            return
        self.server.links = links
        self.respond(200, {})


def save_links(path, links):
    config = json.loads(path.read_text())
    config["books"] = links
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as staged:
        temporary = Path(staged.name)
        try:
            json.dump(config, staged, indent=2)
            staged.write("\n")
            staged.close()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


class Bridge(HTTPServer):
    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(35)
        return connection, address


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("bridge.json"))
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    token = config["token"]
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,}", token):
        parser.error("token must be at least 32 URL-safe characters")
    links = {reader_id: str(UUID(edition)) for reader_id, edition in config["books"].items()}
    if len(set(links.values())) != len(links):
        parser.error("each StoryGraph edition must be mapped at most once")
    cookies = os.environ.get("STORYGRAPH_COOKIE", "").strip()
    if "_storygraph_session=" not in cookies:
        parser.error("set STORYGRAPH_COOKIE to your logged-in StoryGraph cookie header")
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    with Bridge((args.bind, args.port), Handler) as server, requests.Session() as session:
        server.auth = f"Bearer {token}".encode()
        server.config_path = args.config
        server.links = links
        server.confirmed = {}
        server.session = session
        session.headers["Cookie"] = cookies
        logging.info("Listening on %s:%d with %d mapped books", args.bind, args.port, len(links))
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
