# Graphon

A very small graph database.

```gql
MATCH (db:Database {name: 'graphon'})<-[:Wrote]-(p:Person)
RETURN p.name
```

Can be queried with [GQL](https://www.iso.org/standard/76120.html), the ISO-standard graph query language.

## Getting started

Graphon is a single binary that implements almost the entire GQL standard, to specification. You can query it either from Neo4j client libraries, or by making an HTTP request in any language.

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
MATCH TRAIL (follower:Person) ((nodes)-[:Follows]->()){1,3} (influencer:Person),
      (influencer)-[:Created]->(post:Post),
      (follower)-[:Likes]->(post)
WHERE post.likes_count > 100
OPTIONAL MATCH (influencer)-[:Created]->(otherPost:Post)
         WHERE otherPost.creation_date > DATE '2024-01-01'
WITH follower, influencer, post, nodes, COUNT(otherPost) AS recentPosts
RETURN DISTINCT follower.name AS FollowerName,
                influencer.name AS InfluencerName,
                post.title AS PopularPost,
                recentPosts AS RecentPostCount,
                nodes AS FollowerTrail
ORDER BY RecentPostCount DESC, InfluencerName
LIMIT 10;
```

You can also insert, modify, and delete graph data.

```gql
// Insert nodes and edges
INSERT (a:Building {address: '285 Fulton St', city: 'New York', state: 'NY', zipcode: 10007})
INSERT (a)-[:Nearby]-(:Geography {name: 'Hudson River', type: 'water'})
INSERT (a)-[:Nearby]-(:Geography {name: 'The Battery', type: 'park'})

// Modify properties
MATCH (p:Person {name: 'Eric'}) SET p.age = 23

// Delete a node and attached edges
MATCH (x:Account)-[:Invoice {unpaid: true}]->(:Account {id: 627})
DETACH DELETE x
```

Graphon can be queried via HTTP (results sent in JSON format) or [Bolt](https://neo4j.com/docs/bolt/current/) sessions. Concurrent transactions implement [snapshot isolation](https://jepsen.io/consistency/models/snapshot-isolation) to ensure consistency.

The core GQL language includes graph pattern-matching queries, transactional updates, catalog changes, and list data types.

These features are explicitly _not_ supported:

- Having multiple directories and schemas in one database
- Having multiple graphs in one database
- Typed graphs, nodes, and edges (i.e., closed type schemas)
- Named procedures
- The datetime data type and time zones

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
- `ShortestPath`: Finds the shortest path(s) between two nodes.
- `Join`: Take rows from the left subquery, execute the tree on the right subquery, and return both.
- `SemiJoin`: Return rows from the left subquery where the right subquery is not null.
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
- `Update`: Set, add, or remove labels and properties from nodes and edges.
- `Delete`: Delete a node or edge.
- `Aggregate`: Compute aggregations, grouping by one or more columns.
- `GroupAggregate`: Compute aggregations, where result table is already ordered into groups.

There needs to be particular attention paid to graph algorithms to implement certain kinds of path queries efficiently, especially those that traverse paths or trails. We'll add new types of backend operations as Graphon's query language increases in expressivity.
