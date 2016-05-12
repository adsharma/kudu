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
// Protobufs used by both client-server and server-server traffic
// for user data transfer. This file should only contain protobufs
// which are exclusively used on the wire. If a protobuf is persisted on
// disk and not used as part of the wire protocol, it belongs in another
// place such as common/common.proto or within cfile/, server/, etc.
namespace cpp kudu
namespace java org.kududb

include "kudu/common/common.thrift"

// Error status returned by any RPC method.
// Every RPC method which could generate an application-level error
// should have this (or a more complex error result) as an optional field
// in its response.
//
// This maps to kudu::Status in C++ and org.kududb.Status in Java.

enum ErrorCode {
  UNKNOWN_ERROR = 999;
  OK = 0;
  NOT_FOUND = 1;
  CORRUPTION = 2;
  NOT_SUPPORTED = 3;
  INVALID_ARGUMENT = 4;
  IO_ERROR = 5;
  ALREADY_PRESENT = 6;
  RUNTIME_ERROR = 7;
  NETWORK_ERROR = 8;
  ILLEGAL_STATE = 9;
  NOT_AUTHORIZED = 10;
  ABORTED = 11;
  REMOTE_ERROR = 12;
  SERVICE_UNAVAILABLE = 13;
  TIMED_OUT = 14;
  UNINITIALIZED = 15;
  CONFIGURATION_ERROR = 16;
  INCOMPLETE = 17;
  END_OF_FILE = 18;
}

struct AppStatusPB {

  1: ErrorCode code;
  2: optional string message;
  3: optional i32 posix_code;
}

// Uniquely identify a particular instance of a particular server in the
// cluster.
struct NodeInstancePB {
  // Unique ID which is created when the server is first started
  // up. This is stored persistently on disk.
  1: string permanent_uuid;

  // Sequence number incremented on every start-up of the server.
  // This makes it easy to detect when an instance has restarted (and
  // thus can be assumed to have forgotten any soft state it had in
  // memory).
  //
  // On a freshly initialized server, the first sequence number
  // should be 0.
  2: i64 instance_seqno;
}

// A row block in which each row is stored contiguously.
struct RowwiseRowBlockPB {
  // The number of rows in the block. This can typically be calculated
  // by dividing rows.size() by the width of the row, but in the case that
  // the client is scanning an empty projection (i.e a COUNT(*)), this
  // field is the only way to determine how many rows were returned.
  1: optional i32 num_rows = 0;

  // Sidecar index for the row data.
  //
  // In the sidecar, each row is stored in the same in-memory format
  // as kudu::ContiguousRow (i.e the raw unencoded data followed by
  // a null bitmap).
  //
  // The data for NULL cells will be present with undefined contents --
  // typically it will be filled with \x00s but this is not guaranteed,
  // and clients may choose to initialize NULL cells with whatever they
  // like. Setting to some constant improves RPC compression, though.
  //
  // Any pointers are made relative to the beginning of the indirect
  // data sidecar.
  //
  // See rpc/rpc_sidecar.h for more information on where the data is
  // actually stored.
  2: optional i32 rows_sidecar;

  // Sidecar index for the indirect data.
  //
  // In the sidecar, "indirect" data types in the block are stored
  // contiguously. For example, STRING values in the block will be
  // stored using the normal Slice in-memory format, except that
  // instead of being pointers in RAM, the pointer portion will be an
  // offset into this protobuf field.
  3: optional i32 indirect_data_sidecar;
}

enum Type {
  UNKNOWN = 0;
  INSERT = 1;
  UPDATE = 2;
  DELETE = 3;
  // Used when specifying split rows on table creation.
  SPLIT_ROW = 4;
}

// A set of operations (INSERT, UPDATE, or DELETE) to apply to a table.
struct RowOperationsPB {

  // The row data for each operation is stored in the following format:
  //
  // [operation type] (one byte):
  //   A single-byte field which determines the type of operation. The values are
  //   based on the 'Type' enum above.
  // [column isset bitmap]   (one bit for each column in the Schema, rounded to nearest byte)
  //   A set bit in this bitmap indicates that the user has specified the given column
  //   in the row. This indicates that the column will be present in the data to follow.
  // [null bitmap]           (one bit for each Schema column, rounded to nearest byte)
  //   A set bit in this bitmap indicates that the given column is NULL.
  //   This is only present if there are any nullable columns.
  // [column data]
  //   For each column which is set and not NULL, the column's data follows. The data
  //   format of each cell is the canonical in-memory format (eg little endian).
  //   For string data, the pointers are relative to 'indirect_data'.
  //
  // The rows are concatenated end-to-end with no padding/alignment.
  1: optional string rows;
  2: optional string indirect_data;
}
