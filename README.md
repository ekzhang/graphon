# graphon

A very small graph database written in Zig.

```gql
MATCH (db:Database WHERE db.name='graphon'})<-[:wrote]-(p:Person)
RETURN p.name
```

Can be queried with [GQL](https://www.iso.org/standard/76120.html), the ISO-standard graph query language.

## Quickstart

Graphon is a single binary that implements almost the entire GQL standard, to specification. You can query it from either Neo4j client libraries, or using simple HTTP requests in any language.

To start a database, just download the binary and run it.

```sh-session
$ graphon &
$ curl 'http://localhost:7687/?query=RETURN%2020'
20
```

The recommended way to explore a running Graphon database is by using the CLI.

```sh-session
$ graphon-cli
Connected to https://127.0.0.1:7687
> RETURN 100 * 3
300
```

## Features

In addition to the core GQL language that includes graph pattern-matching queries, transactions, insertions/removals/updates, and basic data types, Graphon supports:

- `CREATE INDEX` on the properties of a node type
- JSON data type

You could consider using Graphon when you want something small and low-overhead, yet still fairly powerful.

## Architecture

- Connection manager (HTTP and Bolt protocols)
- Tokenizer and parser
- Query planner
- Execution engine
- Storage and transaction layer using RocksDB

## Limitations

Graphon is a very small project. It tries to be fast in many ways, but the query planner is not going to be very advanced. It won't perfectly optimize every query out there.

The author has never made a database before, so there may be bugs. The on-disk format is unstable. You may lose your data at any time. We currently make no guarantees about consistency or durabillity. **Do not use Graphon as a main store for production data.**
