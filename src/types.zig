//! Definition of common types used in modeling property graphs.

/// Edge direction as expressed in a path pattern.
pub const EdgeDirection = enum {
    Left, // <-[]-
    Right, // -[]->
    Undirected, // ~[]~
    LeftOrUndirected, // <~[]~
    RightOrUndirected, // ~[]~>
    LeftOrRight, // <-[]->
    Any, // -[]-
};
