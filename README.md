# Graphon

A very small graph database. Requires Zig 0.16.

```gql
MATCH (db:Database {name: 'graphon'})<-[:Wrote]-(p:Person)
RETURN p.name
```

Can be queried with a small, growing subset of [GQL](https://www.iso.org/standard/76120.html), the ISO-standard graph query language.

## Getting started

Graphon is a single binary with an HTTP API, a local query command, and an interactive shell. The current query engine is an MVP: it parses a useful GQL-like subset and lowers every query through Graphon's plan IR before execution.

To start a database, just download the binary and run it.

```sh-session
$ graphon
$ curl "http://127.0.0.1:7687/?query=RETURN%2055"
55
```

The recommended way to explore a running Graphon database is through the CLI.

```sh-session
$ graphon-cli
Connected to http://127.0.0.1:7687
> RETURN 100 * 3
300
```

## Features

Graphon is building toward [GQL](https://www.gqlstandards.org/home), which is defined in [ISO/IEC 39075:2024](https://www.iso.org/standard/76120.html). The full standard is much larger than the current implementation.

A simple graph query looks like this:

```gql
MATCH (a:User {name: 'Eric'})->[:Likes]->(f:Food)
RETURN f.name, f.calories
```

Supported query features today:

- `RETURN` scalar expressions, aliases, property access, boolean operators, comparisons, `ORDER BY`, `SKIP`, and `LIMIT`
- `INSERT` node and edge path patterns with labels and properties
- `MATCH` node and edge path patterns, including comma-separated patterns and repeated node variables
- `WHERE` filters over comparisons and boolean expressions
- `MATCH ... RETURN`, `MATCH ... INSERT`, `MATCH ... SET`, `MATCH ... DELETE`, `MATCH ... DETACH DELETE`, and `MATCH ... FINISH`

You can also insert, modify, and delete graph data.

```gql
// Insert nodes and edges
INSERT (a:Building {address: '285 Fulton St', city: 'New York', state: 'NY', zipcode: 10007})
       -[:Nearby]->(:Geography {name: 'Hudson River', type: 'water'}),
       (a)-[:Nearby]->(:Geography {name: 'The Battery', type: 'park'})

// Modify properties
MATCH (p:Person {name: 'Eric'}) SET p.age = 23

// Delete a node and attached edges
MATCH (x:Account)-[:Invoice {unpaid: true}]->(:Account {id: 627})
DETACH DELETE x
```

Graphon can be queried via HTTP GET requests with a `query` parameter. Results are returned as JSON. Concurrent transactions implement [snapshot isolation](https://jepsen.io/consistency/models/snapshot-isolation) to ensure consistency.

These features are explicitly _not_ supported right now:

- The full GQL grammar or full ISO conformance
- Bolt or Neo4j client protocol compatibility
- `OPTIONAL MATCH`, `WITH`, `DISTINCT`, aggregation, grouping, and `UNION`
- Variable-length paths, trails, shortest paths, and path result values
- Parameters, prepared statements, procedures, and catalog changes
- List values and list operators
- Having multiple directories and schemas in one database
- Having multiple graphs in one database
- Typed graphs, nodes, and edges (i.e., closed type schemas)
- The datetime data type and storing time zones
- Identifiers (variable names) using non-ASCII characters

You could consider using Graphon when you want something small and low-overhead, yet still powerful.

## Limitations

Graphon is a very small project. It tries to be fast where possible, but the query planner is not going to be very advanced. It won't perfectly optimize every query out there.

I made this database primarily out of personal interest, to experiment with algorithms, and to learn what goes into a modern database. There will be bugs. Also, the on-disk format is unstable. **Do not use Graphon as a store for production data.**

## Architecture

The database itself is written in Zig and based on RocksDB as a foundational storage layer.

1. **Session manager:** Listens for HTTP requests and creates query sessions.
2. **Tokenizer and parser:** Convert text queries into an abstract syntax tree.
3. **Query planner:** Translate each query into an optimized, low-level query plan.
4. **Execution engine:** Safely execute query plans with specific graph algorithms in an interruptible, streaming API.
5. **Storage and transactions:** Move and fetch data from durable storage, hold transaction locks, and page files via RocksDB.

### Query plans

Query plans are constructed out of low-level operations. The design here was influenced by other databases, particularly the internal representations of [Postgres](https://github.com/postgres/postgres/blob/REL_16_3/src/backend/commands/explain.c#L1177-L1180) and [Neo4j](https://neo4j.com/docs/cypher-manual/current/planning-and-tuning/operators/operators-detail/).

The current MVP planner emits these operators:

- `NodeScan`: Scan for nodes in a graph, optionally providing labels.
- `Step`: Traverse the graph for edges from a node.
- `Begin`: Marker node for the start of the right subtree of a join operator.
- `Join`: Take rows from the left subquery, execute the tree on the right subquery, and return both.
- `Project`: Execute expressions or remap variable names.
- `Filter`: Filter results by label presence or conditional expression.
- `Limit`: Limit the count of result rows.
- `Skip`: Skip rows from the result.
- `Sort`: Sort results by a provided key.
- `InsertNode`: Insert a graph node with labels and properties.
- `InsertEdge`: Insert an edge with direction, labels, and properties between two nodes.
- `Update`: Set, add, or remove labels and properties from nodes and edges.
- `Delete`: Delete a node or edge.

The IR already has some scaffolded operator variants that are not exposed by the MVP parser yet. There needs to be particular attention paid to graph algorithms to implement certain kinds of path queries efficiently, especially those that traverse paths or trails. We'll add new types of backend operations as Graphon's query language increases in expressivity.
