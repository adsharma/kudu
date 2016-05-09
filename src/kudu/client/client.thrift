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

// Protobufs which are specific to client implementations.

namespace cpp kudu.client
namespace java org.kududb.client

include "kudu/common/common.thrift"

// Features used by the scan token message. Every time the ScanTokenPB message
// is updated with a new feature, the feature should be added to this enum, so
// that clients that lack the feature can recognize when they receive a token
// that uses unknown features.
enum Feature {
  Unknown = 0;
}

// Serialization format for client scan tokens. Scan tokens are serializable
// scan descriptors that are used by query engines to plan a set of parallizable
// scanners that are executed on remote task runners. The scan token protobuf
// format includes all of the information necessary to recreate a scanner in the
// remote task.
struct ScanTokenPB {

  // The feature set used by this scan token.
  1: list<Feature> feature_flags;

  // The table to scan.
  2: optional string table_name;

  // Which columns to select.
  // if this is an empty list, no data will be returned, but the num_rows
  // field of the returned RowBlock will indicate how many rows passed
  // the predicates. Note that in some cases, the scan may still require
  // multiple round-trips, and the caller must aggregate the counts.
  3: list<common.ColumnSchemaPB> projected_columns;

  // Any column predicates to enforce.
  4: list<common.ColumnPredicatePB> column_predicates;

  // Encoded primary key to begin scanning at (inclusive).
  5: optional string lower_bound_primary_key;

  // Encoded primary key to stop scanning at (exclusive).
  6: optional string upper_bound_primary_key;

  // Encoded partition key to begin scanning at (inclusive).
  7: optional string lower_bound_partition_key;

  // Encoded partition key to stop scanning at (exclusive).
  8: optional string upper_bound_partition_key;

  // The maximum number of rows to scan.
  // The scanner will automatically stop yielding results and close
  // itself after reaching this number of result rows.
  9: optional i64 limit;

  // The read mode for this scan request.
  // See common.proto for further information about read modes.
  10: optional common.ReadMode read_mode = common.READ_LATEST;

  // The requested snapshot timestamp. This is only used
  // when the read mode is set to READ_AT_SNAPSHOT.
  11: optional i64 snap_timestamp;

  // Sent by clients which previously executed CLIENT_PROPAGATED writes.
  // This updates the server's time so that no transaction will be assigned
  // a timestamp lower than or equal to 'previous_known_timestamp'
  12: optional i64 propagated_timestamp;

  // Whether data blocks will be cached when read from the files or discarded after use.
  // Disable this to lower cache churn when doing large scans.
  13: optional bool cache_blocks = true;

  // Whether the scan should be fault tolerant.
  14: optional bool fault_tolerant = false;
}
