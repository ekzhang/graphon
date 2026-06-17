# Graphon

A very small graph database in Zig.

```gql
MATCH (db:Database {name: 'graphon'})<-[:Wrote]-(p:Person)
RETURN p.name
```

Can be queried with [GQL](https://www.iso.org/standard/76120.html), the ISO-standard graph query language.

## Quickstart

Clone the codebase, download [Zig 0.16](https://ziglang.org/download/) plus [RocksDB](https://rocksdb.org/), and run `zig build` to generate the `zig-out/bin/` folder.

```sh-session
$ graphon shell
```

## Running a server

Graphon is a single binary that implements a subset of the GQL standard. You can query it either from Neo4j client libraries, or by making an HTTP request in any language.

```sh-session
$ graphon
Graphon listening at http://127.0.0.1:7687 and bolt://127.0.0.1:7687 using /tmp/graphon.db with up to 64 concurrent connections
$ curl "http://127.0.0.1:7687/?query=RETURN%2055"
[{"value":55}]
```

There is a `graphon-cli` binary for connecting to a running server.

```sh-session
$ graphon-cli
Connected to http://127.0.0.1:7687
> RETURN 100 * 3
300
```

## Features

Graphon implements the [GQL](https://www.gqlstandards.org/home) language for graph queries, which is defined in [ISO/IEC 39075:2024](https://www.iso.org/standard/76120.html). This standard was recently published in April 2024, so there's not many resources on it yet. You can find some documentation on the [Google Spanner](https://cloud.google.com/spanner/docs/reference/standard-sql/graph-intro) website.

A simple graph query looks like this:

```gql
MATCH (a:User {name: 'Eric'})->[:Likes]->(f:Food)
RETURN f.name, f.calories
```

GQL is a powerful language. Here is a larger example that demonstrates a few features:

- **Pattern Matching:** Find a variable-length path (trail) between follower and influencer nodes, allowing for a chain of connections between one and three `Follows` relationships deep.
- **Complex Filtering:** Uses the `WHERE` clause to filter for influencers who have created popular posts (with more than 100 likes).
- **Aggregation:** `OPTIONAL MATCH` finds recent posts created by the influencer to enrich the output, and `WITH` implicitly aggregates them.
- **Structured Output:** Returns distinct named results including names, the titles of popular posts, the count of recent posts, and the entire trail of connections.
- **Ordering and Limiting:** Orders and limits the output to the top 10 results.

```gql
MATCH TRAIL (follower:Person)-[follows:Follows]->{1,3}(influencer:Person),
            (influencer)-[:Created]->(post:Post),
            (follower)-[:Likes]->(post)
WHERE post.likes_count > 100
OPTIONAL MATCH (influencer)-[:Created]->(otherPost:Post)
         WHERE otherPost.creation_date > '2024-01-01'
WITH follower, influencer, post, follows, COUNT(otherPost) AS recentPosts
RETURN DISTINCT follower.name AS FollowerName,
                influencer.name AS InfluencerName,
                post.title AS PopularPost,
                recentPosts AS RecentPostCount,
                follows AS FollowerTrail
ORDER BY RecentPostCount DESC, InfluencerName
LIMIT 10;
```

You can also insert, modify, and delete graph data.

```gql
// Insert nodes and edges
INSERT (a:Building {address: '285 Fulton St', city: 'New York', state: 'NY', zipcode: 10007}),
       (a)-[:Nearby]->(:Geography {name: 'Hudson River', type: 'water'}),
       (a)-[:Nearby]->(:Geography {name: 'The Battery', type: 'park'})

// Modify properties
MATCH (p:Person {name: 'Eric'}) SET p.age = 23

// Delete a node and attached edges
MATCH (x:Account)-[:Invoice {unpaid: true}]->(:Account {id: 627})
DETACH DELETE x
```

Graphon can be queried via HTTP (results sent in JSON format) or [Bolt](https://neo4j.com/docs/bolt/current/) sessions. Concurrent transactions implement [snapshot isolation](https://jepsen.io/consistency/models/snapshot-isolation) to ensure consistency.

The core GQL language includes graph pattern-matching queries, transactional updates, and list data types.

These features are explicitly _not_ supported right now:

- Having multiple directories and schemas in one database
- Having multiple graphs in one database
- Typed graphs, nodes, and edges (i.e., closed type schemas)
- Named procedures
- The datetime data type and storing time zones
- Identifiers (variable names) using non-ASCII characters

You could consider using Graphon when you want something small and low-overhead, yet still powerful.

## Limitations

Graphon is a very small project. It tries to be fast where possible, but the query planner is not going to be very advanced. It won't perfectly optimize every query out there.

I made this database primarily out of personal interest, to experiment with algorithms, and to learn what goes into a modern database. There will be bugs. Also, the on-disk format is unstable. **Do not use Graphon as a store for production data.**

## Architecture

The database itself is written in Zig and based on RocksDB as a foundational storage layer.

1. **Session manager:** Listens for requests over HTTP and Bolt protocols, creates new sessions.
2. **Tokenizer and parser:** Convert text queries into an abstract syntax tree.
3. **Query planner:** Translate each query into an optimized, low-level query plan.
4. **Execution engine:** Safely execute query plans with specific graph algorithms in an interruptible, streaming API.
5. **Storage and transactions:** Move and fetch data from durable storage, hold transaction locks, and page files via RocksDB.

### Query plans

Query plans are constructed out of the following operations. The design here was influenced by other databases, particularly the internal representations of [Postgres](https://github.com/postgres/postgres/blob/REL_16_3/src/backend/commands/explain.c#L1177-L1180) and [Neo4j](https://neo4j.com/docs/cypher-manual/current/planning-and-tuning/operators/operators-detail/).

- `NodeScan`: Scan for nodes in a graph, optionally providing labels.
- `EdgeScan`: Scan for edges in a graph, optionally providing labels.
- `NodeById`: Fetch the node with an ID.
- `EdgeById`: Fetch the edge with an ID.
- `Step`: Traverse the graph for edges from a node.
- `StepBetween`: Traverse the graph for edges between two nodes.
- `Begin`: Marker node for the start of the right subtree of a repeat or join operator.
- `Argument`: Marks a variable for the node or edge being repeated in a path.
- `Repeat`: Repeat the sub-pattern, used for trail and path queries.
- `ShortestPath`: Finds the shortest path(s) between two nodes. **(TODO)**
- `Join`: Take rows from the left subquery, execute the tree on the right subquery, and return both.
- `SemiJoin`: Return rows from the left subquery where the right subquery is not null.
- `OptionalJoin`: Left outer join, returns null when the right subquery does not match.
- `Anti`: Test for the absence of a pattern, yielding a single row.
- `Project`: Execute expressions or remap variable names.
- `ProjectEndpoints`: Find the endpoints of an edge.
- `EmptyResult`: Retrieve all results and drop them, used as the last operator in mutations.
- `Filter`: Filter results by label presence or conditional expression.
- `Limit`: Limit the count of result rows.
- `Distinct`: Remove duplicate rows from the result.
- `Skip`: Skip rows from the result.
- `Sort`: Sort results by a provided key.
- `Top`: Return some number of top rows by a provided key in sorted order (sort then limit).
- `UnionAll`: Concatenates results from the left and right subqueries.
- `InsertNode`: Insert a graph node with labels and properties.
- `InsertEdge`: Insert an edge with direction, labels, and properties between two nodes.
- `Update`: Set properties and add or remove labels on nodes and edges.
- `Delete`: Delete a node or edge.
- `Aggregate`: Compute aggregations, grouping by one or more columns.
- `OrderedAggregate`: Compute aggregations when input rows are already ordered by group key.

You need to pay attention to specific graph algorithms to implement certain kinds of path queries efficiently, especially those that traverse paths or trails. We'll add new types of backend operations as Graphon's query language gets more expressive.

### Query plan examples

Query plans are printed from the final operator back toward the source operators. `Plan{...}` lists the identifiers returned to the client; mutation plans use `Plan{}` because they return a mutation count instead of row values.

Filtered reads lower into scans, filters, projections, and `Top` when `ORDER BY` and `LIMIT` can be combined.

```gql
MATCH (p:Person)
WHERE p.age > 30
RETURN p.name
ORDER BY p.age DESC
LIMIT 2
```

```text
Plan{%1}
  Top 2 %2 desc
  Project %2: %0.age
  Project %1: %0.name
  Filter (%0.age > 30)
  NodeScan (%0:Person)
```

When both endpoints are bound, edge patterns lower to `StepBetween`.

```gql
MATCH (a:Person), (b:Person), (a)-[e:Knows]->(b)
RETURN a, b, e
```

```text
Plan{%0, %1, %2}
  StepBetween (%0)-[%2:Knows]->(%1)
  Join
    NodeScan (%1:Person)
  Begin
  NodeScan (%0:Person)
```

Aggregation uses `Aggregate` generally, and `OrderedAggregate` when the input is already ordered by the group key.

```gql
MATCH (p:Person)
WITH p.team AS team ORDER BY team
RETURN team, COUNT(*) AS people
```

```text
Plan{%1, %2}
  OrderedAggregate %2: count(*) BY %1
  Sort %1 asc
  Project %1: %0.team
  NodeScan (%0:Person)
```

Updates reuse the read side of the plan and then apply an `Update` operator.

```gql
MATCH (p:Person {name: 'Eric'})
SET p.age = 23
```

```text
Plan{}
  Update %0.age = 23
  Filter (%0.name = 'Eric')
  NodeScan (%0:Person)
```

Label updates use the same operator with label-specific update clauses.

```gql
MATCH (p:Person)
SET p:Employee
```

```text
Plan{}
  Update add %0:Employee
  NodeScan (%0:Person)
```
