# Graphon

A very small graph database.

```gql
MATCH (db:Database WHERE db.name='graphon')<-[:wrote]-(p:Person)
RETURN p.name
```

Can be queried with [GQL](https://www.iso.org/standard/76120.html), the ISO-standard graph query language.

## Getting started

Graphon is a single binary that implements almost the entire GQL standard, to specification. You can query it either from Neo4j client libraries, or by making an HTTP request in any language.

To start a database, just download the binary and run it.

```sh-session
$ graphon
$ curl 'http://localhost:7687/?query=RETURN%2020'
20
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

- `CREATE INDEX` on the properties of a node label
- Execution cost tracking for terminating unbounded paths / undecidability
- JSON data type

You could consider using Graphon when you want something small and low-overhead, yet still powerful.

## Architecture

The database itself is written in Zig and based on RocksDB as a foundational storage layer.

1. **Connection manager:** Accept GQL requests over HTTP and Bolt protocols.
2. **Tokenizer and parser:** Convert text queries into an abstract syntax tree.
3. **Query planner:** Materialize and optimize a plan for executing the query.
4. **Execution engine:** Safely execute query plans with specific graph algorithms in an interruptible, streaming API.
5. **Storage and transactions:** Move and fetch data from durable storage, hold transaction locks, and page files via RocksDB.

## Limitations

Graphon is a very small project. It tries to be fast in many ways, but the query planner is not going to be very advanced. It won't perfectly optimize every query out there.

The author has never made a database before, so there will be bugs. Also, the on-disk format is unstable. We currently make no guarantees about consistency or durabillity. **Assume that you may lose your data at any time. Do not use Graphon as a load-bearing store for production data.**
