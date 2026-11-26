"""senior-mode: query-count helper for Django. A list must cost the same number of queries for 1 record and for 10.

    with count_queries() as one:
        list_users()                           # 1 record seeded
    with expect_queries(one.count):
        list_users()                           # 10 records seeded: same count, or the test fails
"""
from contextlib import contextmanager

from django.db import connection
from django.test.utils import CaptureQueriesContext


class QueryCount:
    def __init__(self, captured):
        self._captured = captured

    @property
    def count(self):
        return len(self._captured)


@contextmanager
def count_queries():
    with CaptureQueriesContext(connection) as captured:
        yield QueryCount(captured)


@contextmanager
def expect_queries(expected):
    with count_queries() as counter:
        yield counter
    assert counter.count == expected, f"expected {expected} queries, got {counter.count}"
