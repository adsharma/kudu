// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.
//
// Protobufs which are common throughout Kudu.
//
// This file may contain protobufs which are persisted on disk
// as well as sent on the wire. If a particular protobuf is only
// used as part of the client-server wire protocol, it should go
// in common/wire_protocol.proto instead. If it is only used within
// the server(s), it should go in cfile/cfile.proto, server/metadata.proto,
// etc, as appropriate.
namespace cpp kudu
namespace java org.kududb

// If you add a new type keep in mind to add it to the end
// or update AddMapping() functions like the one in key_encoder.cc
// that have a vector that maps the protobuf tag with the index.
enum DataType {
  UNKNOWN_DATA = 999;
  UINT8 = 0;
  INT8 = 1;
  UINT16 = 2;
  INT16 = 3;
  UINT32 = 4;
  INT32 = 5;
  UINT64 = 6;
  INT64 = 7;
  STRING = 8;
  BOOL = 9;
  FLOAT = 10;
  DOUBLE = 11;
  BINARY = 12;
  TIMESTAMP = 13;
}

enum EncodingType {
  UNKNOWN_ENCODING = 999;
  AUTO_ENCODING = 0;
  PLAIN_ENCODING = 1;
  PREFIX_ENCODING = 2;
  GROUP_VARINT = 3;
  RLE = 4;
  DICT_ENCODING = 5;
  BIT_SHUFFLE = 6;
}

enum CompressionType {
  UNKNOWN_COMPRESSION = 999;
  DEFAULT_COMPRESSION = 0;
  NO_COMPRESSION = 1;
  SNAPPY = 2;
  LZ4 = 3;
  ZLIB = 4;
}

// TODO: Differentiate between the schema attributes
// that are only relevant to the server (e.g.,
// encoding and compression) and those that also
// matter to the client.
struct ColumnSchemaPB {
  1: optional i32 id;
  2: required string name;
  3: required DataType type;
  4: optional bool is_key = false;
  5: optional bool is_nullable = false;
  6: optional string read_default_value;
  7: optional string write_default_value;

  // The following attributes refer to the on-disk storage of the column.
  // They won't always be set, depending on context.
  8: optional EncodingType encoding = EncodingType.AUTO_ENCODING;
  9: optional CompressionType compression;
  10: optional i32 cfile_block_size = 0;
}

struct SchemaPB {
  1: list<ColumnSchemaPB> columns;
}

struct HostPortPB {
  1: string host;
  2: i32 port;
}

// The external consistency mode for client requests.
// This defines how transactions and/or sequences of operations that touch
// several TabletServers, in different machines, can be observed by external
// clients.
//
// Note that ExternalConsistencyMode makes no guarantee on atomicity, i.e.
// no sequence of operations is made atomic (or transactional) just because
// an external consistency mode is set.
// Note also that ExternalConsistencyMode has no implication on the
// consistency between replicas of the same tablet.
enum ExternalConsistencyMode {
  UNKNOWN_EXTERNAL_CONSISTENCY_MODE = 0;

  // The response to any write will contain a timestamp.
  // Any further calls from the same client to other servers will update
  // those servers with that timestamp. The user will make sure that the
  // timestamp is propagated through back-channels to other
  // KuduClient's.
  //
  // WARNING: Failure to propagate timestamp information through
  // back-channels will negate any external consistency guarantee under this
  // mode.
  //
  // Example:
  // 1 - Client A executes operation X in Tablet A
  // 2 - Afterwards, Client A executes operation Y in Tablet B
  //
  //
  // Client B may observe the following operation sequences:
  // {}, {X}, {X Y}
  //
  // This is the default mode.
  CLIENT_PROPAGATED = 1;

  // The server will guarantee that each transaction is externally
  // consistent by making sure that none of its results are visible
  // until every Kudu server agrees that the transaction is in the past.
  // The client is not obligated to forward timestamp information
  // through back-channels.
  //
  // WARNING: Depending on the clock synchronization state of TabletServers
  // this may imply considerable latency. Moreover operations with
  // COMMIT_WAIT requested external consistency will outright fail if
  // TabletServer clocks are either unsynchronized or synchronized but
  // with a maximum error which surpasses a pre-configured one.
  //
  // Example:
  // - Client A executes operation X in Tablet A
  // - Afterwards, Client A executes operation Y in Tablet B
  //
  //
  // Client B may observe the following operation sequences:
  // {}, {X}, {X Y}
  COMMIT_WAIT = 2;
}

// The possible read modes for clients.
// Clients set these in Scan requests.
// The server keeps 2 snapshot boundaries:
// - The earliest snapshot: this corresponds to the earliest kept undo records
//   in the tablet, meaning the current state (Base) can be undone up to
//   this snapshot.
// - The latest snapshot: This corresponds to the instant beyond which no
//   no transaction will have an earlier timestamp. Usually this corresponds
//   to whatever clock->Now() returns, but can be higher if the client propagates
//   a timestamp (see below).
enum ReadMode {
  UNKNOWN_READ_MODE = 0;

  // When READ_LATEST is specified the server will execute the read independently
  // of the clock and will always return all visible writes at the time the request
  // was received. This type of read does not return a snapshot timestamp since
  // it might not be repeatable, i.e. a later read executed at the same snapshot
  // timestamp might yield rows that were committed by in-flight transactions.
  //
  // This is the default mode.
  READ_LATEST = 1;

  // When READ_AT_SNAPSHOT is specified the server will attempt to perform a read
  // at the required snapshot. If no snapshot is defined the server will take the
  // current time as the snapshot timestamp. Snapshot reads are repeatable, i.e.
  // all future reads at the same timestamp will yield the same rows. This is
  // performed at the expense of waiting for in-flight transactions whose timestamp
  // is lower than the snapshot's timestamp to complete.
  //
  // When mixing reads and writes clients that specify COMMIT_WAIT as their
  // external consistency mode and then use the returned write_timestamp to
  // to perform snapshot reads are guaranteed that that snapshot time is
  // considered in the past by all servers and no additional action is
  // necessary. Clients using CLIENT_PROPAGATED however must forcibly propagate
  // the timestamps even at read time, so that the server will not generate
  // any more transactions before the snapshot requested by the client.
  // The latter option is implemented by allowing the client to specify one or
  // two timestamps, the first one obtained from the previous CLIENT_PROPAGATED
  // write, directly or through back-channels, must be signed and will be
  // checked by the server. The second one, if defined, is the actual snapshot
  // read time. When selecting both the latter must be lower than or equal to
  // the former.
  // TODO implement actually signing the propagated timestamp.
  READ_AT_SNAPSHOT = 2;
}

// The possible order modes for clients.
// Clients specify these in new scan requests.
// Ordered scans are fault-tolerant, and can be retried elsewhere in the case
// of tablet server failure. However, ordered scans impose additional overhead
// since the tablet server needs to sort the result rows.
enum OrderMode {
  UNKNOWN_ORDER_MODE = 0;
  // This is the default order mode.
  UNORDERED = 1;
  ORDERED = 2;
}

// A column identifier for partition schemas. In general, the name will be
// used when a client creates the table since column IDs are assigned by the
// master. All other uses of partition schemas will use the numeric column ID.
union ColumnIdentifierPB {
  1: i32 id;
  2: string name;
}

struct RangeSchemaPB {
  // Column identifiers of columns included in the range. All columns must be
  // a component of the primary key.
  1: list<ColumnIdentifierPB> columns;
}

enum HashAlgorithm {
  UNKNOWN = 0;
  MURMUR_HASH_2 = 1;
}

struct HashBucketSchemaPB {
  // Column identifiers of columns included in the hash. Every column must be
  // a component of the primary key.
  1: list<ColumnIdentifierPB> columns;

  // Number of buckets into which columns will be hashed. Must be at least 2.
  2: required i32 num_buckets;

  // Seed value for hash calculation. Administrators may set a seed value
  // on a per-table basis in order to randomize the mapping of rows to
  // buckets. Setting a seed provides some amount of protection against denial
  // of service attacks when the hash bucket columns contain user provided
  // input.
  3: optional i32 seed;

  // The hash algorithm to use for calculating the hash bucket.
  4: optional HashAlgorithm hash_algorithm;
}

// The serialized format of a Kudu table partition schema.
struct PartitionSchemaPB {
  1: list<HashBucketSchemaPB> hash_bucket_schemas;
  2: optional RangeSchemaPB range_schema;
}

// The serialized format of a Kudu table partition.
struct PartitionPB {
  // The hash buckets of the partition. The number of hash buckets must match
  // the number of hash bucket components in the partition's schema.
  1: list<i32> hash_buckets;
  // The encoded start partition key (inclusive).
  2: optional string partition_key_start;
  // The encoded end partition key (exclusive).
  3: optional string partition_key_end;
}

struct Range {

  // Bounds should be encoded as follows:
  // - STRING/BINARY values: simply the exact string value for the bound.
  // - other type: the canonical x86 in-memory representation -- eg for
  //   i32s, a little-endian value.
  //
  // Note that this predicate type should not be used for NULL data --
  // NULL is defined to neither be greater than or less than other values
  // for the comparison operator. We will eventually add a special
  // predicate type for null-ness.

  // The inclusive lower bound.
  1: optional string lower;

  // The exclusive upper bound.
  2: optional string upper;
}

struct Equality {
  // The inclusive lower bound. See comment in Range for notes on the
  // encoding.
  1: optional string value;
}

struct IsNotNull {}

union predicate {
  1: Range range;
  2: Equality equality;
  3: IsNotNull is_not_null;
}

// A predicate that can be applied on a Kudu column.
struct ColumnPredicatePB {
  // The predicate column name.
  1: optional string column;
  2: Equality equality;
  3: IsNotNull not_null;
  4: predicate pred;
}