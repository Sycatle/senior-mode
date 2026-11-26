//! senior-mode: query-count helper for sqlx. A list must cost the same number of queries for 1 record and for 10.
//!
//! ```ignore
//! let (one, _) = queries_of(list_users(&pool)).await;      // 1 record seeded
//! expect_queries(one, list_users(&pool)).await;            // 10 records seeded: same count, or the test panics
//! ```
//!
//! Needs `tracing` and `tracing-subscriber` as dev-dependencies. It counts the `sqlx::query` events of the future.
use std::future::Future;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use tracing::instrument::WithSubscriber;
use tracing::{Event, Subscriber};
use tracing_subscriber::layer::{Context, SubscriberExt};
use tracing_subscriber::{Layer, Registry};

struct Counter(Arc<AtomicUsize>);

impl<S: Subscriber> Layer<S> for Counter {
    fn on_event(&self, event: &Event<'_>, _: Context<'_, S>) {
        if event.metadata().target() == "sqlx::query" {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
}

pub async fn queries_of<T>(fut: impl Future<Output = T>) -> (usize, T) {
    let count = Arc::new(AtomicUsize::new(0));
    let subscriber = Registry::default().with(Counter(count.clone()));
    let out = fut.with_subscriber(subscriber).await;
    (count.load(Ordering::SeqCst), out)
}

pub async fn expect_queries<T>(expected: usize, fut: impl Future<Output = T>) -> T {
    let (actual, out) = queries_of(fut).await;
    assert!(actual == expected, "expected {expected} queries, got {actual}");
    out
}
