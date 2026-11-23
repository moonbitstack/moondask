///|
/// The name a value is filed under: a node's identity inside a graph, and the
/// name the nodes that depend on it read it by.
///
/// Keys are plain strings so a whole plan can be written down, compared, logged
/// and sent over a connection without a registry of numeric handles.
pub type Key = String
