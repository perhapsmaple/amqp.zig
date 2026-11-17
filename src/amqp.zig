//! amqp.zig: an AMQP 0-9-1 (RabbitMQ) client built on `std.Io`.

const std = @import("std");

/// Wire codec internals. Public for tests and tools; not a stable API.
pub const wire = struct {
    pub const primitives = @import("wire/primitives.zig");
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(wire);
}
