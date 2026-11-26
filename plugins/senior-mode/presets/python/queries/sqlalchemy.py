"""senior-mode: query-count helper for SQLAlchemy. A list must cost the same number of queries for 1 record and for 10.

    with count_queries(engine) as one:
        list_users(session)                    # 1 record seeded
    with expect_queries(engine, one.count):
        list_users(session)                    # 10 records seeded: same count, or the test fails
"""
from contextlib import contextmanager

from sqlalchemy import event


class QueryCount:
    count = 0


@contextmanager
def count_queries(engine):
    counter = QueryCount()

    def on_execute(*_):
        counter.count += 1

    target = getattr(engine, "sync_engine", engine)
    event.listen(target, "before_cursor_execute", on_execute)
    try:
        yield counter
    finally:
        event.remove(target, "before_cursor_execute", on_execute)


@contextmanager
def expect_queries(engine, expected):
    with count_queries(engine) as counter:
        yield counter
    assert counter.count == expected, f"expected {expected} queries, got {counter.count}"
