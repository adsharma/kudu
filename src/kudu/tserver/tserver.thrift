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
namespace cpp kudu.tserver
namespace java org.kududb.tserver

include "kudu/common/common.thrift"
include "kudu/common/wire_protocol.thrift"

enum Code {
  // An error which has no more specific error code.
  // The code and message in 'status' may reveal more details.
  //
  // RPCs should avoid returning this, since callers will not be
  // able to easily parse the error.
  UNKNOWN_ERROR = 1;

  // The schema provided for a request was not well-formed.
  INVALID_SCHEMA = 2;

  // The row data provided for a request was not well-formed.
  INVALID_ROW_BLOCK = 3;

  // The mutations or mutation keys provided for a request were
  // not well formed.
  INVALID_MUTATION = 4;

  // The schema provided for a request didn't match the actual
  // schema of the tablet.
  MISMATCHED_SCHEMA = 5;

  // The requested tablet_id is not currently hosted on this server.
  TABLET_NOT_FOUND = 6;

  // A request was made against a scanner ID that was either never
  // created or has expired.
  SCANNER_EXPIRED = 7;

  // An invalid scan was specified -- e.g the values passed for
  // predicates were incorrect sizes.
  INVALID_SCAN_SPEC = 8;

  // The provided configuration was not well-formed and/or
  // had a sequence number that was below the current config.
  INVALID_CONFIG = 9;

  // On a create tablet request, signals that the tablet already exists.
  TABLET_ALREADY_EXISTS = 10;

  // If the tablet has a newer schema than the requested one the "alter"
  // request will be rejected with this error.
  TABLET_HAS_A_NEWER_SCHEMA = 11;

  // The tablet is hosted on this server, but not in RUNNING state.
  TABLET_NOT_RUNNING = 12;

  // Client requested a snapshot read but the snapshot was invalid.
  INVALID_SNAPSHOT = 13;

  // An invalid scan call sequence ID was specified.
  INVALID_SCAN_CALL_SEQ_ID = 14;

  // This tserver is not the leader of the consensus configuration.
  NOT_THE_LEADER = 15;

  // The destination UUID in the request does not match this server.
  WRONG_SERVER_UUID = 16;

  // The compare-and-swap specified by an atomic RPC operation failed.
  CAS_FAILED = 17;

  // The requested operation is already inprogress, e.g. RemoteBootstrap.
  ALREADY_INPROGRESS = 18;

  // The request is throttled.
  THROTTLED = 19;
}

// Tablet-server specific errors use this protobuf.
struct TabletServerErrorPB {

  // The error code.
  1: Code code = Code.UNKNOWN_ERROR;

  // The Status object for the error. This will include a textual
  // struct that may be more useful to present in log messages, etc,
  // though its error code is less specific.
  2: wire_protocol.AppStatusPB status;
}


struct PingRequestPB {
}

struct PingResponsePB {
}

// A batched set of insert/mutate requests.
struct WriteRequestPB {
  1: string tablet_id;

  // The schema as seen by the client. This may be out-of-date, in which case
  // it will be projected to the current schema automatically, with defaults/NULLs
  // being filled in.
  2: optional common.SchemaPB schema;

  // Operations to perform (insert/update/delete)
  3: optional wire_protocol.RowOperationsPB row_operations;

  // The required consistency mode for this write.
  4: optional common.ExternalConsistencyMode external_consistency_mode = common.CLIENT_PROPAGATED;

  // A timestamp obtained by the client from a previous request.
  // TODO crypto sign this and propagate the signature along with
  // the timestamp.
  5: optional i64 propagated_timestamp;
}

// If errors occurred with particular row operations, then the errors
// for those operations will be passed back in 'per_row_errors'.
struct PerRowErrorPB {
  // The index of the row in the incoming batch.
  1: i32 row_index;
  // The error that occurred.
  2: wire_protocol.AppStatusPB error;
}

struct WriteResponsePB {
  // If the entire WriteResponsePB request failed, the error status that
  // caused the failure. This type of error is triggered for
  // cases such as the tablet not being on this server, or the
  // schema not matching. If any error specific to a given row
  // occurs, this error will be recorded in per_row_errors below,
  // even if all rows failed.
  1: optional TabletServerErrorPB error;

  2: list<PerRowErrorPB> per_row_errors;

  // The timestamp chosen by the server for this write.
  // TODO KUDU-611 propagate timestamps with server signature.
  3: optional i64 timestamp;
}

// A list tablets request
struct ListTabletsRequestPB {
}


struct StatusAndSchemaPB {
  // TODO: tablet.proto not translated to thrift yet 
  1: string tablet_status;
  2: common.SchemaPB schema;
  3: optional common.PartitionSchemaPB partition_schema;
}

// A list tablets response
struct ListTabletsResponsePB {
  1: optional TabletServerErrorPB error;
  2: list<StatusAndSchemaPB> status_and_schema;
}

// DEPRECATED: Use ColumnPredicatePB
//
// A range predicate on one of the columns in the underlying
// data.
struct ColumnRangePredicatePB {
  1: common.ColumnSchemaPB column;

  // These bounds should be encoded as follows:
  // - STRING values: simply the exact string value for the bound.
  // - other type: the canonical x86 in-memory representation -- eg for
  //   i32s, a little-endian value.
  //
  // Note that this predicate type should not be used for NULL data --
  // NULL is defined to neither be greater than or less than other values
  // for the comparison operator. We will eventually add a special
  // predicate type for null-ness.
  //
  // Both bounds are inclusive.
  2: optional string lower_bound;
  3: optional string inclusive_upper_bound;
}

// List of predicates used by the Java client. Will rapidly evolve into something more reusable
// as a way to pass scanner configurations.
struct ColumnRangePredicateListPB {
  1: list<ColumnRangePredicatePB> range_predicates;
}

struct NewScanRequestPB {
  // The tablet to scan.
  1: string tablet_id;

  // The maximum number of rows to scan.
  // The scanner will automatically stop yielding results and close
  // itself after reaching this number of result rows.
  2: optional i64 limit;

  // DEPRECATED: use column_predicates field.
  //
  // Any column range predicates to enforce.
  3: list<ColumnRangePredicatePB> DEPRECATED_range_predicates = 3;

  // Column predicates to enforce.
  4: list<common.ColumnPredicatePB> column_predicates;

  // Encoded primary key to begin scanning at (inclusive).
  5: optional string start_primary_key;

  // Encoded primary key to stop scanning at (exclusive).
  6: optional string stop_primary_key;

  // Which columns to select.
  // if this is an empty list, no data will be returned, but the num_rows
  // field of the returned RowBlock will indicate how many rows passed
  // the predicates. Note that in some cases, the scan may still require
  // multiple round-trips, and the caller must aggregate the counts.
  7: list<common.ColumnSchemaPB> projected_columns;

  // The read mode for this scan request.
  // See common.proto for further information about read modes.
  8: optional common.ReadMode read_mode = common.READ_LATEST;

  // The requested snapshot timestamp. This is only used
  // when the read mode is set to READ_AT_SNAPSHOT.
  9: optional i64 snap_timestamp;

  // Sent by clients which previously executed CLIENT_PROPAGATED writes.
  // This updates the server's time so that no transaction will be assigned
  // a timestamp lower than or equal to 'previous_known_timestamp'
  10: optional i64 propagated_timestamp;

  // Whether data blocks will be cached when read from the files or discarded after use.
  // Disable this to lower cache churn when doing large scans.
  11: optional bool cache_blocks = true;

  // Whether to order the returned rows by primary key.
  // This is used for scanner fault-tolerance.
  12: optional common.OrderMode order_mode = common.UNORDERED;

  // If retrying a scan, the final primary key retrieved in the previous scan
  // attempt. If set, this will take precedence over the `start_primary_key`
  // field, and functions as an exclusive start primary key.
  13: optional string last_primary_key;
}

// A scan request. Initially, it should specify a scan. Later on, you
// can use the scanner id returned to fetch result batches with a different
// scan request.
//
// The scanner will remain open if there are more results, and it's not
// asked to be closed explicitly. Some errors on the Tablet Server may
// close the scanner automatically if the scanner state becomes
// inconsistent.
//
// Clients may choose to retry scan requests that fail to complete (due to, for
// example, a timeout or network error). If a scan request completes with an
// error result, the scanner should be closed by the client.
//
// You can fetch the results and ask the scanner to be closed to save
// a trip if you are not interested in remaining results.
//
// This is modeled somewhat after HBase's scanner API.
struct ScanRequestPB {
  // If continuing an existing scan, then you must set scanner_id.
  // Otherwise, you must set 'new_scan_request'.
  1: optional string scanner_id;
  2: optional NewScanRequestPB new_scan_request;

  // The sequence ID of this call. The sequence ID should start at 0
  // with the request for a new scanner, and after each successful request,
  // the client should increment it by 1. When retrying a request, the client
  // should _not_ increment this value. If the server detects that the client
  // missed a chunk of rows from the middle of a scan, it will respond with an
  // error.
  3: optional i32 call_seq_id;

  // The maximum number of bytes to send in the response.
  // This is a hint, not a requirement: the server may send
  // arbitrarily fewer or more bytes than requested.
  4: optional i32 batch_size_bytes;

  // If set, the server will close the scanner after responding to
  // this request, regardless of whether all rows have been delivered.
  // In order to simply close a scanner without selecting any rows, you
  // may set batch_size_bytes to 0 in conjunction with setting this flag.
  5: optional bool close_scanner;
}

struct ScanResponsePB {
  // The error, if an error occurred with this request.
  1: optional TabletServerErrorPB error;

  // When a scanner is created, returns the scanner ID which may be used
  // to pull new rows from the scanner.
  2: optional string scanner_id;

  // Set to true to indicate that there may be further results to be fetched
  // from this scanner. If the scanner has no more results, then the scanner
  // ID will become invalid and cannot continue to be used.
  //
  // Note that if a scan returns no results, then the initial response from
  // the first RPC may return false in this flag, in which case there will
  // be no scanner ID assigned.
  3: optional bool has_more_results;

  // The block of returned rows.
  //
  // NOTE: the schema-related fields will not be present in this row block.
  // The schema will match the schema requested by the client when it created
  // the scanner.
  4: optional wire_protocol.RowwiseRowBlockPB data;

  // The snapshot timestamp at which the scan was executed. This is only set
  // in the first response (i.e. the response to the request that had
  // 'new_scan_request' set) and only for READ_AT_SNAPSHOT scans.
  5: optional i64 snap_timestamp;

  // If this is a fault-tolerant scanner, this is set to the encoded primary
  // key of the last row returned in the response.
  6: optional string last_primary_key;
}

// A scanner keep-alive request.
// Updates the scanner access time, increasing its time-to-live.
struct ScannerKeepAliveRequestPB {
  1: string scanner_id;
}

struct ScannerKeepAliveResponsePB {
  // The error, if an error occurred with this request.
  1: optional TabletServerErrorPB error;
}

enum TabletServerFeatures {
  UNKNOWN_FEATURE = 0;
  COLUMN_PREDICATES = 1;
}
