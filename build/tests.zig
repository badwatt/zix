//! Root test block for the build-time helper programs.
//!
//! `zig build test` runs these alongside the app and integration suites, so
//! the coverage reporter and the docs server are not left untested.

test {
    _ = @import("coverage.zig");
    _ = @import("serve.zig");
}
