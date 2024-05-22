# Graphon

A very small graph database.

```gql
MATCH (db:Database {name: 'graphon'})<-[:wrote]-(p:Person)
RETURN p.name
```

Can be queried with [GQL](https://www.iso.org/standard/76120.html), the ISO-standard graph query language.

## Getting started

Graphon is a single binary that implements almost the entire GQL standard, to specification. You can query it either from Neo4j client libraries, or by making an HTTP request in any language.

To start a database, just download the binary and run it.

```sh-session
$ graphon
$ curl 'http://localhost:7687/?query=RETURN%2055'
55
```

The recommended way to explore a running Graphon database is through the CLI.

```sh-session
$ graphon-cli
Connected to https://127.0.0.1:7687
> RETURN 100 * 3
300
```

## Features

In addition to the core GQL language that includes graph pattern-matching queries, transactional updates, catalog changes, and list data types, Graphon supports:

- `CREATE INDEX` on the properties of nodes and relationships
- Execution cost tracking for terminating unbounded paths / undecidability
- JSON data type

You could consider using Graphon when you want something small and low-overhead, yet still powerful.

## Limitations

Graphon is a very small project. It tries to be fast where possible, but the query planner is not going to be very advanced. It won't perfectly optimize every query out there.

The author has never made a database before, so there will be bugs. Also, the on-disk format is unstable. We currently make no guarantees about consistency or durabillity. **Assume that you may lose your data at any time. Do not use Graphon as a load-bearing store for production data.**

## Architecture

The database itself is written in Zig and based on RocksDB as a foundational storage layer.

1. **Connection manager:** Accept GQL requests over HTTP and Bolt protocols.
2. **Tokenizer and parser:** Convert text queries into an abstract syntax tree.
3. **Query planner:** Materialize and optimize a plan for executing the query.
4. **Execution engine:** Safely execute query plans with specific graph algorithms in an interruptible, streaming API.
5. **Storage and transactions:** Move and fetch data from durable storage, hold transaction locks, and page files via RocksDB.

### Query plans

Query plans are binary trees constructed out of the following operations. The design here was influenced by other databases, particularly the internal representations of [Postgres](https://github.com/postgres/postgres/blob/REL_16_3/src/backend/commands/explain.c#L1177-L1180) and [Neo4j](https://neo4j.com/docs/cypher-manual/current/planning-and-tuning/operators/operators-detail/).

- `NodeScan`: Scan for nodes in a graph, optionally providing labels.
- `NodeById`: Fetch the node with an ID.
- `RelScan`: Scan for relationships in a graph, optionally providing labels.
- `RelById`: Fetch the relationship with an ID.
- `Step`: Traverse the graph for relationships from a node.
- `StepBetween`: Traverse the graph for relationships between two nodes.
- `Begin`: Marker node for the start of the right subtree of a repeat or join operator.
- `Repeat`: Repeat the sub-pattern, used for trail and path queries.
- `ShortestPath`: Finds the shortest path(s) between two nodes.
- `Join`: Take rows from the left side, execute the tree on the right side, and return both.
- `SemiJoin`: Return rows from the left side where the right side is present.
- `Argument`: Get a variable for the node being repeated, or the right side of a join.
- `Anti`: Test for the absence of a pattern, yielding a single row.
- `Projection`: Execute expressions or remap variable names.
- `ProjectEndpoints`: Find the endpoints of an edge.
- `Filter`: Filter results by label presence or conditional expression.
- `Limit`: Limit the count of result rows.
- `Distinct`: Remove duplicate rows from the result.
- `Skip`: Skip rows from the result.
- `Sort`: Sort results by a provided key.
- `Top`: Return some number of top rows by a provided key in sorted order (sort then limit).
- `UnionAll`: Concatenates results from the left and right child operators.
- `InsertNode`: Insert a graph node with labels and properties.
- `InsertEdge`: Insert an edge with direction, labels, and properties between two nodes.
- `Update`: Set, add, or remove labels and properties from nodes and relationships.
- `Delete`: Delete a node or relationship.
- `Aggregate`: Compute aggregations, grouping by one or more columns.
- `GroupAggregate`: Compute aggregations, where result table is already ordered into groups.
