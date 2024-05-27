//! Definition of common types used in modeling property graphs.

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
