//! Definition of common types used in modeling property graphs.

const std = @import("std");
const random = std.crypto.random;

/// Unique element ID for a node or edge. Element IDs are random 96-bit integers.
pub const ElementId = struct {
    value: u96,

    /// Generates a new random element ID.
    pub fn generate() ElementId {
        return ElementId{ .value = random.int(u96) };
    }

    /// Return this element ID as a big-endian byte array.
    pub fn toBytes(self: ElementId) [12]u8 {
        var buf: [12]u8 = undefined;
        std.mem.writeInt(u96, &buf, self.value, .big);
        return buf;
    }

    /// Return an element ID as a base64 string.
    pub fn toString(self: ElementId) [16]u8 {
        var buf: [16]u8 = undefined;
        var x = self.value;
        var i = buf.len;
        while (i > 0) {
            i -= 1;
            const c = x & 0x3f;
            buf[i] = switch (c) {
                0...25 => 'A' + @as(u8, @intCast(c)),
                26...51 => 'a' + @as(u8, @intCast(c - 26)),
                52...61 => '0' + @as(u8, @intCast(c - 52)),
                62 => '-',
                63 => '_',
                else => unreachable,
            };
            x >>= 6;
        }
        return buf;
    }
};

test ElementId {
    const id = ElementId{ .value = 238093323431135580 };
    try std.testing.expectEqualStrings(&id.toString(), "AAAAAANN4J2-gUlc");
    try std.testing.expect(ElementId.generate().value != ElementId.generate().value);
}

/// Edge direction as expressed in a path pattern.
pub const EdgeDirection = enum {
    left, // <-[]-
    right, // -[]->
    undirected, // ~[]~
    left_or_undirected, // <~[]~
    right_or_undirected, // ~[]~>
    left_or_right, // <-[]->
    any, // -[]-

    /// Returns the left part of the edge direction as a string.
    pub fn leftPart(self: EdgeDirection) [:0]const u8 {
        return switch (self) {
            .left => "<-[",
            .right => "-[",
            .undirected => "~[",
            .left_or_undirected => "<~[",
            .right_or_undirected => "~[",
            .left_or_right => "<-[",
            .any => "-[",
        };
    }

    /// Returns the right part of the edge direction as a string.
    pub fn rightPart(self: EdgeDirection) [:0]const u8 {
        return switch (self) {
            .left => "]-",
            .right => "]->",
            .undirected => "]~",
            .left_or_undirected => "]~",
            .right_or_undirected => "]~>",
            .left_or_right => "]->",
            .any => "]-",
        };
    }
};
