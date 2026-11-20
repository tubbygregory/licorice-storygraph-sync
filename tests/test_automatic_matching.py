import json
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import requests

from bridge import Bridge, Handler, SITE


EDITION = "12345678-1234-5678-9abc-123456789abc"
OTHER = "23456789-1234-5678-9abc-123456789abc"
BOOK = {"title": "A Book", "author": "An Author"}


def response(text="", status=200, content_type="text/html"):
    return SimpleNamespace(status_code=status, text=text, headers={"Content-Type": content_type})


def result(edition, heading="A Book by An Author"):
    return f'<a class="list-option book-list-option" href="/books/{edition}"><h1 class="sr-only">{heading}</h1></a>'


def progress_page(last=10):
    return f"""
<meta name="csrf-token" content="page-token">
<form action="/update-progress">
    <input type="hidden" name="read_status[last_reached_percent]" value="{last}">
</form>
"""


def default_panel(token="form-token"):
    return f"""
<div class="on-book-page action-menu" data-book-id="{EDITION}">
  <div data-controller="remove-book">
    <form method="post" action="/update-status.js?book_id={EDITION}&amp;status=to-read">
      <button aria-label="Add to your To-Read Pile"></button>
    </form>
    <div class="read-status-dropdown-content" data-book-id="{EDITION}">
      <form method="post" action="/update-status.js?book_id={EDITION}&amp;status=currently-reading">
        <input name="authenticity_token" value="{token}" type="hidden">
        <button aria-label="Mark as currently reading"></button>
      </form>
    </div>
  </div>
</div>
"""


class AutomaticMatchingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.server = Bridge(("127.0.0.1", 0), Handler)
        self.addCleanup(self.server.server_close)
        self.server.config_path = Path(self.tmp.name) / "bridge.json"
        self.server.config_path.write_text('{"token":"test","books":{}}')
        self.server.links = {}
        self.server.confirmed = {}
        self.server.auth = b"Bearer test"
        self.session = self.server.session = Mock()
        self.session.post.return_value = response(content_type="text/javascript")

        worker = threading.Thread(target=self.server.serve_forever, args=(0.01,))
        worker.start()
        self.addCleanup(worker.join, 1)
        self.addCleanup(self.server.shutdown)

    def sync(self, data):
        return requests.post(
            f"http://127.0.0.1:{self.server.server_port}/sync",
            json=data, headers={"Authorization": "Bearer test"}, timeout=3,
        )

    def automatic_sync(self, book=BOOK, percent=40):
        return self.sync({"progress": {"epub": percent}, "books": {"epub": book}, "current": "epub"})

    def test_unique_exact_title_and_author_with_existing_progress(self):
        self.session.get.side_effect = [
            response(result(EDITION, "A   BOOK by AN AUTHOR") + result(OTHER, "A Book by Someone Else")),
            response(progress_page()),
        ]
        reply = self.automatic_sync()
        self.assertEqual(reply.status_code, 200)
        self.assertEqual(reply.json()["matched"], 1)
        self.assertEqual(self.session.post.call_args.args[0], f"{SITE}/update-progress")
        self.assertEqual(self.session.post.call_args.kwargs["data"]["read_status[progress_number]"], 40)
        self.assertEqual(json.loads(self.server.config_path.read_text())["books"], {"epub": EDITION})
        self.assertEqual(self.sync({"epub": 30}).json()["checked"], 0)
        self.assertEqual(self.session.post.call_count, 1)

    def test_ambiguous_match_does_not_write_or_repeat_search_immediately(self):
        self.session.get.return_value = response(result(EDITION) + result(OTHER))
        self.assertEqual(self.automatic_sync().json()["unmatched"], 1)
        self.assertEqual(self.automatic_sync().json()["unmatched"], 1)
        self.session.post.assert_not_called()
        self.assertEqual(self.session.get.call_count, 1)
        self.assertEqual(self.server.links, {})

    def test_isbn_requires_confirmation_on_edition_page(self):
        self.session.get.side_effect = [
            response(result(EDITION)),
            response('<p><span class="font-semibold">ISBN/UID:</span> 9780141346458</p>' + progress_page()),
        ]
        reply = self.automatic_sync({**BOOK, "isbn": "978-0-141-34645-8"})
        self.assertEqual(reply.json()["matched"], 1)
        self.assertEqual(self.session.get.call_args_list[0].kwargs["params"]["search_term"], "9780141346458")

    def test_mismatched_isbn_never_falls_back_to_title_match(self):
        self.session.get.side_effect = [
            response(result(EDITION)),
            response('<p><span class="font-semibold">ISBN/UID:</span> 9780131103627</p>' + progress_page()),
        ]
        self.assertEqual(self.automatic_sync({**BOOK, "isbn": "9780141346458"}).json()["unmatched"], 1)
        self.session.post.assert_not_called()

    def test_untracked_signed_in_edition_can_start_and_sync(self):
        self.session.get.side_effect = [
            response(result(EDITION)),
            response('<a href="/users/sign_out">Sign out</a>' + default_panel() + default_panel("other")),
            response(progress_page(last=0)),
        ]
        self.assertEqual(self.automatic_sync().json()["matched"], 1)
        start, progress = self.session.post.call_args_list
        self.assertTrue(start.args[0].endswith(f"book_id={EDITION}&status=currently-reading"))
        self.assertEqual(start.kwargs["data"], {"authenticity_token": "form-token"})
        self.assertEqual(progress.args[0], f"{SITE}/update-progress")

    def test_default_status_without_active_session_does_not_start_book(self):
        self.session.get.side_effect = [response(result(EDITION)), response(default_panel())]
        self.assertEqual(self.automatic_sync().json()["unmatched"], 1)
        self.session.post.assert_not_called()

    def test_conflicting_status_panels_do_not_start_book(self):
        other_panel = f'<div class="on-book-page action-menu" data-book-id="{EDITION}" data-current-status="read"></div>'
        self.session.get.side_effect = [
            response(result(EDITION)),
            response('<a href="/users/sign_out">Sign out</a>' + default_panel() + other_panel),
        ]
        self.assertEqual(self.automatic_sync().json()["unmatched"], 1)
        self.session.post.assert_not_called()

    def test_finished_book_does_not_start_a_new_storygraph_entry(self):
        self.session.get.side_effect = [
            response(result(EDITION)), response('<a href="/users/sign_out">Sign out</a>' + default_panel()),
        ]
        self.assertEqual(self.automatic_sync(percent=100).json()["unmatched"], 1)
        self.session.post.assert_not_called()

    def test_open_book_is_prioritized(self):
        self.session.get.side_effect = [response(result(EDITION)), response(progress_page())]
        reply = self.sync({
            "progress": {"old": 20, "epub": 30},
            "books": {"old": {"title": "Older Book", "author": "An Author"}, "epub": BOOK},
            "current": "epub",
        })
        self.assertEqual(reply.json()["matched"], 1)
        self.assertEqual(reply.json()["deferred"], 1)
        self.assertEqual(self.session.get.call_args_list[0].kwargs["params"]["search_term"], "A Book")

    def test_search_block_leaves_existing_mapping_available_for_next_sync(self):
        self.server.links["old"] = OTHER
        data = {"progress": {"old": 30, "epub": 40}, "books": {"epub": BOOK}}
        self.session.get.side_effect = [response(status=403), response(progress_page())]
        self.assertEqual(self.sync(data).status_code, 502)
        self.assertEqual(self.sync(data).json()["checked"], 1)
        self.assertEqual(self.server.links, {"old": OTHER})

    def test_empty_metadata_preserves_flat_sync_behavior(self):
        self.server.links["old"] = OTHER
        self.session.get.return_value = response(progress_page())
        self.assertEqual(self.sync({"progress": {"old": 30}, "books": []}).json()["checked"], 1)
        self.assertEqual(self.sync({"old": 45}).json()["checked"], 1)


if __name__ == "__main__":
    unittest.main()
