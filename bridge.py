"""Local, single-user bridge from XTApp snapshots to StoryGraph."""
import argparse
import hmac
import json
import logging
import os
import re
import tempfile
import time
import unicodedata
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from uuid import UUID

import requests
from bs4 import BeautifulSoup

SITE = "https://app.thestorygraph.com"
MAX_BODY = 60_000
MATCH_RETRY_SECONDS = 3600


def book_page(session, edition):
    url = f"{SITE}/books/{edition}"
    page = session.get(url, timeout=5, allow_redirects=False)
    if page.status_code != 200:
        raise ValueError(f"book page HTTP {page.status_code}")
    return url, BeautifulSoup(page.text, "html.parser")


def read_progress_form(book_url, soup):
    form = soup.select_one('form[action="/update-progress"]')
    csrf = soup.select_one('meta[name="csrf-token"][content]')
    previous = form and form.select_one('input[name="read_status[last_reached_percent]"][value]')
    if form and csrf and previous:
        return book_url, form, csrf, int(previous["value"] or "0")


def progress_form(session, edition):
    form = read_progress_form(*book_page(session, edition))
    if form is None:
        raise ValueError("progress form unavailable; check sign-in and Currently Reading status")
    return form


def storygraph_progress(session, edition, percent, form_details=None):
    book_url, form, csrf, last = form_details or progress_form(session, edition)
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


def normalize_text(value):
    return " ".join(unicodedata.normalize("NFKC", value).casefold().split())


def normalize_isbn(value):
    isbn = re.sub(r"[\s-]", "", value).upper()
    if re.fullmatch(r"[0-9]{9}[0-9X]", isbn):
        digits = [int(digit) for digit in isbn[:9]] + [10 if isbn[-1] == "X" else int(isbn[-1])]
        if sum((10 - i) * digit for i, digit in enumerate(digits)) % 11:
            return ""
        prefix = "978" + isbn[:9]
        isbn = prefix + str((-sum(int(d) * (1 + 2 * (i % 2)) for i, d in enumerate(prefix))) % 10)
    if re.fullmatch(r"97[89][0-9]{10}", isbn) and sum(
        int(d) * (1 + 2 * (i % 2)) for i, d in enumerate(isbn)
    ) % 10 == 0:
        return isbn
    return ""


def lookup_edition(session, book):
    isbn = normalize_isbn(book.get("isbn", ""))
    title, author = book.get("title", "").strip(), book.get("author", "").strip()
    if not isbn and not (title and author):
        return None
    response = session.get(
        f"{SITE}/search", params={"search_term": isbn or title, "button": ""},
        timeout=5, allow_redirects=False,
    )
    if response.status_code != 200:
        raise ValueError(f"book search HTTP {response.status_code}")
    soup = BeautifulSoup(response.text, "html.parser")
    expected = normalize_text(f"{title} by {author}")
    candidates = set()
    for link in soup.select('a.book-list-option[href^="/books/"]'):
        path = urlsplit(link["href"]).path
        try:
            edition = str(UUID(path.removeprefix("/books/")))
        except ValueError:
            continue
        heading = link.select_one("h1.sr-only")
        if isbn or (heading and normalize_text(heading.get_text(" ", strip=True)) == expected):
            candidates.add(edition)
    if len(candidates) != 1:
        return None

    edition = candidates.pop()
    url, page = book_page(session, edition)
    if isbn:
        identifiers = {
            normalize_isbn(label.parent.get_text(" ", strip=True).removeprefix("ISBN/UID:").strip())
            for label in page.select("p > span.font-semibold")
            if label.get_text(strip=True) == "ISBN/UID:"
        }
        if isbn not in identifiers:
            return None
    return edition, url, page


def start_untracked_book(session, url, page, edition):
    # The default status menu also appears on signed-out pages.
    if not page.select_one('a[href="/users/sign_out"], form[action="/users/sign_out"]'):
        return False
    if page.select_one('a[href="/users/sign_in"], a[href^="/users/sign_in?"]'):
        return False
    panels = page.select(f'.on-book-page.action-menu[data-book-id="{edition}"]')
    if not panels:
        return False

    action = f"/update-status.js?book_id={edition}&status=currently-reading"
    tokens = []
    for panel in panels:
        states = [
            element.get("data-current-status", "") or element.get("data-read-status", "") or element.get("value", "")
            for element in [panel, *panel.select('[data-current-status], [data-read-status], input[name="read_status[status]"]')]
        ]
        if any(state not in ("", "none", "untracked") for state in states):
            return False
        default = panel.select_one(
            f'div[data-controller="remove-book"] > form[method="post"]'
            f'[action="/update-status.js?book_id={edition}&status=to-read"]'
            ' > button[aria-label="Add to your To-Read Pile"]'
        )
        if not default:
            return False
        menu = default.find_parent("div", attrs={"data-controller": "remove-book"})
        form = menu.select_one(
            f'.read-status-dropdown-content[data-book-id="{edition}"] > form[method="post"][action="{action}"]'
        )
        if not form or not form.select_one('button[aria-label="Mark as currently reading"]'):
            return False
        token = form.select_one('input[name="authenticity_token"][value]')
        if not token or not token["value"]:
            return False
        tokens.append(token["value"])
    reply = session.post(
        f"{SITE}{action}", data={"authenticity_token": tokens[0]}, timeout=5,
        allow_redirects=False, headers={
            "X-Requested-With": "XMLHttpRequest",
            "X-CSRF-Token": tokens[0],
            "Accept": "text/javascript, application/javascript",
            "Origin": SITE,
            "Referer": url,
        },
    )
    if reply.status_code != 200 or "javascript" not in reply.headers.get("Content-Type", ""):
        raise ValueError(f"start reading returned HTTP {reply.status_code}")
    return True


def snapshot_payload(data):
    if "progress" in data and isinstance(data["progress"], dict):
        progress, books = data["progress"], data.get("books", {})
        current = data.get("current")
        if books == []:
            books = {}
    else:
        progress, books, current = data, {}, None
    if any(not reader_id or len(reader_id) > 256 or type(value) is not int or not 0 <= value <= 100
           for reader_id, value in progress.items()):
        raise ValueError("invalid book progress")
    if not isinstance(books, dict) or any(
        not reader_id or len(reader_id) > 256 or not isinstance(fields, dict)
        or any(not isinstance(value, str) or len(value) > 512 for value in fields.values())
        for reader_id, fields in books.items()
    ):
        raise ValueError("invalid book metadata")
    if current is not None and (not isinstance(current, str) or len(current) > 256):
        raise ValueError("invalid current book ID")
    return progress, books, current


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
        try:
            progress, books, current = snapshot_payload(data)
        except ValueError as exc:
            self.respond(400, {"error": str(exc)})
            return

        # Alternate discovery and existing updates so a failing book cannot block new matches.
        new, ready = self.discovery_candidates(books, progress)
        ready.sort(key=lambda candidate: candidate[0] != current)
        linked = [
            (reader_id, edition) for reader_id, edition in self.server.links.items()
            if progress.get(reader_id, 0) > self.server.confirmed.get(edition, 0)
        ]
        checked = matched = unmatched = errors = deferred = 0
        if ready and (not linked or self.server.discover_next):
            reader_id, key = ready[0]
            matched, unmatched, errors = self.discover_book(reader_id, key, books[reader_id], progress[reader_id])
            checked = matched
            deferred = len(linked) + len(ready) - 1
            self.server.discover_next = False
        else:
            checked, errors = self.update_linked_books(linked[:2], progress)
            deferred = max(0, len(linked) - 2) + len(ready)
            unmatched = len(new) if not ready else 0
            self.server.discover_next = True
        self.respond(502 if errors else 200, {
            "checked": checked, "deferred": deferred, "errors": errors,
            "matched": matched, "unmatched": unmatched,
        })

    def update_linked_books(self, linked, progress):
        checked = errors = 0
        for reader_id, edition in linked:
            self.server.links[reader_id] = self.server.links.pop(reader_id)
            try:
                storygraph_progress(self.server.session, edition, progress[reader_id])
            except ValueError as exc:
                logging.warning("Edition %s: %s", edition, exc)
                errors += 1
            except requests.RequestException:
                logging.warning("Edition %s: StoryGraph connection failed", edition)
                errors += 1
            else:
                self.server.confirmed[edition] = progress[reader_id]
                checked += 1
        return checked, errors

    def discovery_candidates(self, books, progress):
        if not books:
            return [], []
        now = time.monotonic()
        retry = self.server.match_retry
        for expired in [key for key, until in retry.items() if until <= now]:
            del retry[expired]
        new = []
        ready = []
        for reader_id, book in books.items():
            if reader_id in self.server.links or progress.get(reader_id, 0) <= 0:
                continue
            new.append(reader_id)
            key = (reader_id, book.get("title", ""), book.get("author", ""), book.get("isbn", ""))
            if key not in retry and (key[1].strip() and key[2].strip() or normalize_isbn(key[3])):
                ready.append((reader_id, key))
        return new, ready

    def discover_book(self, reader_id, key, book, percent):
        now = time.monotonic()
        try:
            match = lookup_edition(self.server.session, book)
            if match and self.sync_discovered_book(reader_id, match, percent):
                return 1, 0, 0
        except ValueError as exc:
            logging.warning("Automatic book match: %s", exc)
        except (OSError, requests.RequestException):
            logging.warning("Automatic book match could not be completed")
        else:
            self.server.match_retry[key] = now + MATCH_RETRY_SECONDS
            logging.info("No syncable StoryGraph match for %r", book.get("title", reader_id))
            return 0, 1, 0
        # Give other books a chance while a network or session failure clears.
        self.server.match_retry[key] = now + 60
        return 0, 0, 1

    def sync_discovered_book(self, reader_id, match, percent):
        edition, url, page = match
        if edition in self.server.links.values():
            return False
        form = read_progress_form(url, page)
        if form is None:
            if percent == 100 or not start_untracked_book(self.server.session, url, page, edition):
                return False
            form = progress_form(self.server.session, edition)
        storygraph_progress(self.server.session, edition, percent, form)
        links = {**self.server.links, reader_id: edition}
        save_links(self.server.config_path, links)
        self.server.links = links
        self.server.confirmed[edition] = percent
        logging.info("Auto-matched reader book to StoryGraph edition %s", edition)
        return True

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
    def __init__(self, server_address, handler):
        super().__init__(server_address, handler)
        self.match_retry = {}
        self.discover_next = True

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
