// Copyright (c) 2014 Cloudera, Inc.
#include "kudu/tserver/remote_bootstrap_client.h"

#include <gflags/gflags.h>
#include <glog/logging.h>

#include "kudu/common/wire_protocol.h"
#include "kudu/fs/block_id.h"
#include "kudu/fs/fs_manager.h"
#include "kudu/gutil/strings/substitute.h"
#include "kudu/gutil/strings/util.h"
#include "kudu/rpc/messenger.h"
#include "kudu/rpc/transfer.h"
#include "kudu/server/metadata.pb.h"
#include "kudu/tablet/tablet.pb.h"
#include "kudu/tablet/tablet_bootstrap.h"
#include "kudu/tablet/tablet_peer.h"
#include "kudu/tserver/remote_bootstrap.pb.h"
#include "kudu/tserver/tablet_server.h"
#include "kudu/tserver/tserver_service.proxy.h"
#include "kudu/util/crc.h"
#include "kudu/util/env.h"
#include "kudu/util/env_util.h"
#include "kudu/util/net/net_util.h"

DEFINE_int32(remote_bootstrap_begin_session_timeout_ms, 10000,
             "Tablet server RPC client timeout for BeginRemoteBootstrapSession calls.");

// RETURN_NOT_OK_PREPEND() with a remote-error unwinding step.
#define RETURN_NOT_OK_UNWIND_PREPEND(status, controller, msg) \
  RETURN_NOT_OK_PREPEND(UnwindRemoteError(status, controller), msg)

namespace kudu {
namespace tserver {

using consensus::OpId;
using metadata::ColumnDataPB;
using metadata::QuorumPB;
using metadata::QuorumPeerPB;
using metadata::DeltaDataPB;
using metadata::RowSetDataPB;
using metadata::TabletMasterBlockPB;
using metadata::TabletMetadata;
using metadata::TabletSuperBlockPB;
using rpc::Messenger;
using std::string;
using std::tr1::shared_ptr;
using std::vector;
using strings::Substitute;
using tablet::TabletStatusListener;

RemoteBootstrapClient::RemoteBootstrapClient(FsManager* fs_manager,
                                             const shared_ptr<Messenger>& messenger,
                                             const string& client_permanent_uuid)
  : fs_manager_(fs_manager),
    messenger_(messenger),
    permanent_uuid_(client_permanent_uuid),
    state_(kNoSession),
    status_listener_(NULL),
    session_idle_timeout_millis_(0) {
}

Status RemoteBootstrapClient::RunRemoteBootstrap(TabletMetadata* meta,
                                                 const QuorumPB& quorum,
                                                 TabletStatusListener* status_listener) {
  DCHECK(meta != NULL);

  CHECK_EQ(metadata::REMOTE_BOOTSTRAP_COPYING, meta->remote_bootstrap_state());
  const string& tablet_id = meta->oid();

  // Download all the files (serially, for now, but in parallel in the future).
  RETURN_NOT_OK(BeginRemoteBootstrapSession(tablet_id, quorum, status_listener));
  RETURN_NOT_OK(DownloadWALs());
  RETURN_NOT_OK(DownloadBlocks());

  // Replace tablet metadata superblock. This will set the tablet metadata state
  // to REMOTE_BOOTSTRAP_DONE, since we checked above that the response
  // superblock is in a valid state to bootstrap from.
  LOG(INFO) << "Tablet " << tablet_id_ << " remote bootstrap complete. Replacing superblock.";
  UpdateStatusMessage("Replacing tablet superblock");
  RETURN_NOT_OK(meta->ReplaceSuperBlock(*superblock_));

  // Note: Ending the remote bootstrap session releases anchors on the remote.
  RETURN_NOT_OK(EndRemoteBootstrapSession());

  return Status::OK();
}

Status RemoteBootstrapClient::ExtractLeaderFromQuorum(const metadata::QuorumPB& quorum,
                                                      metadata::QuorumPeerPB* leader) {
  BOOST_FOREACH(const QuorumPeerPB& peer, quorum.peers()) {
    if (peer.role() == QuorumPeerPB::LEADER) {
      leader->CopyFrom(peer);
      return Status::OK();
    }
  }
  return Status::NotFound("No leader found in quorum");
}

// Decode the remote error into a human-readable Status object.
Status RemoteBootstrapClient::ExtractRemoteError(const rpc::ErrorStatusPB& remote_error) {
  if (PREDICT_TRUE(remote_error.HasExtension(RemoteBootstrapErrorPB::remote_bootstrap_error_ext))) {
    const RemoteBootstrapErrorPB& error =
        remote_error.GetExtension(RemoteBootstrapErrorPB::remote_bootstrap_error_ext);
    return StatusFromPB(error.status()).CloneAndPrepend("Received error code " +
              RemoteBootstrapErrorPB::Code_Name(error.code()) + " from remote service");
  } else {
    return Status::InvalidArgument("Unable to decode remote bootstrap RPC error message",
                                   remote_error.ShortDebugString());
  }
}

// Enhance a RemoteError Status message with additional details from the remote.
Status RemoteBootstrapClient::UnwindRemoteError(const Status& status,
                                                const rpc::RpcController& controller) {
  if (!status.IsRemoteError()) {
    return status;
  }
  Status extension_status = ExtractRemoteError(*controller.error_response());
  return status.CloneAndAppend(extension_status.ToString());
}

void RemoteBootstrapClient::UpdateStatusMessage(const string& message) {
  if (status_listener_ != NULL) {
    status_listener_->StatusMessage("RemoteBootstrap: " + message);
  }
}

Status RemoteBootstrapClient::BeginRemoteBootstrapSession(const std::string& tablet_id,
                                                          const metadata::QuorumPB& quorum,
                                                          TabletStatusListener* status_listener) {
  CHECK_EQ(kNoSession, state_);

  tablet_id_ = tablet_id;
  status_listener_ = status_listener;

  UpdateStatusMessage("Initializing remote bootstrap");

  // Find the quorum leader's address.
  // TODO: Support looking up quorum info from Master and also redirecting
  // from follower to quorum leader in the future.
  QuorumPeerPB leader;
  RETURN_NOT_OK_PREPEND(ExtractLeaderFromQuorum(quorum, &leader),
                        "Cannot find leader tablet in quorum to remotely bootstrap from: " +
                        quorum.ShortDebugString());
  if (!leader.has_last_known_addr()) {
    return Status::InvalidArgument("Unknown address for quorum leader", leader.ShortDebugString());
  }
  HostPort host_port;
  RETURN_NOT_OK(HostPortFromPB(leader.last_known_addr(), &host_port));
  Sockaddr addr;
  RETURN_NOT_OK(SockaddrFromHostPort(host_port, &addr));
  LOG(INFO) << "Beginning remote bootstrap session on tablet " << tablet_id
            << " from leader " << host_port.ToString();

  UpdateStatusMessage("Beginning remote bootstrap session with leader " + host_port.ToString());

  // Set up an RPC proxy for the RemoteBootstrapService.
  proxy_.reset(new TabletServerServiceProxy(messenger_, addr));

  BeginRemoteBootstrapSessionRequestPB req;
  req.set_requestor_uuid(permanent_uuid_);
  req.set_tablet_id(tablet_id);

  rpc::RpcController controller;
  controller.set_timeout(MonoDelta::FromMilliseconds(
      FLAGS_remote_bootstrap_begin_session_timeout_ms));

  // Begin the remote bootstrap session.
  BeginRemoteBootstrapSessionResponsePB resp;
  RETURN_NOT_OK_UNWIND_PREPEND(proxy_->BeginRemoteBootstrapSession(req, &resp, &controller),
                               controller,
                               "Unable to begin remote bootstrap session");

  // TODO: Support retrying based on updated info from Master or quorum.
  if (resp.superblock().remote_bootstrap_state() != metadata::REMOTE_BOOTSTRAP_DONE) {
    Status s = Status::IllegalState("Leader of quorum (" + quorum.ShortDebugString() + ")" +
                                    " is currently remotely bootstrapping itself!",
                                    resp.superblock().ShortDebugString());
    LOG(WARNING) << s.ToString();
    return s;
  }

  session_id_ = resp.session_id();
  session_idle_timeout_millis_ = resp.session_idle_timeout_millis();
  superblock_.reset(resp.release_superblock());
  wal_initial_opids_.clear();
  BOOST_FOREACH(const OpId& op_id, resp.first_op_ids()) {
    wal_initial_opids_.push_back(op_id);
  }

  state_ = kSessionStarted;

  return Status::OK();
}

Status RemoteBootstrapClient::EndRemoteBootstrapSession() {
  CHECK_EQ(kSessionStarted, state_);

  UpdateStatusMessage("Ending remote bootstrap session");

  rpc::RpcController controller;
  controller.set_timeout(MonoDelta::FromMilliseconds(
        FLAGS_remote_bootstrap_begin_session_timeout_ms));

  EndRemoteBootstrapSessionRequestPB req;
  req.set_session_id(session_id_);
  req.set_is_success(true);
  EndRemoteBootstrapSessionResponsePB resp;
  RETURN_NOT_OK_UNWIND_PREPEND(proxy_->EndRemoteBootstrapSession(req, &resp, &controller),
                               controller,
                               "Failure ending remote bootstrap session");

  UpdateStatusMessage("Remote bootstrap complete");

  return Status::OK();
}

Status RemoteBootstrapClient::DownloadWALs() {
  CHECK_EQ(kSessionStarted, state_);

  // Create WAL root dir if needed.
  bool created_wal_root = false;
  RETURN_NOT_OK(fs_manager_->CreateDirIfMissing(fs_manager_->GetWalsRootDir(), &created_wal_root));
  if (created_wal_root) {
    RETURN_NOT_OK(fs_manager_->env()->SyncDir(DirName(fs_manager_->GetWalsRootDir())));
  }

  // Delete and recreate WAL dir if it already exists, to ensure stray files are
  // not kept from previous bootstraps and runs.
  string path = fs_manager_->GetTabletWalDir(tablet_id_);
  if (fs_manager_->env()->FileExists(path)) {
    RETURN_NOT_OK(fs_manager_->env()->DeleteRecursively(path));
  }
  RETURN_NOT_OK(fs_manager_->env()->CreateDir(path));
  RETURN_NOT_OK(fs_manager_->env()->SyncDir(DirName(path))); // fsync() parent dir.

  // Download the WAL segments.
  int num_segments = wal_initial_opids_.size();
  LOG(INFO) << "Starting download of " << num_segments << " WAL segments...";
  uint64_t wal_seqno = 0;
  BOOST_FOREACH(const OpId& op_id, wal_initial_opids_) {
    UpdateStatusMessage(Substitute("Downloading WAL segment with seqno $0 ($1/$2)",
                                   wal_seqno, wal_seqno + 1, num_segments));
    RETURN_NOT_OK(DownloadWAL(op_id, wal_seqno++));
  }
  return Status::OK();
}

Status RemoteBootstrapClient::DownloadBlocks() {
  CHECK_EQ(kSessionStarted, state_);

  // Collect all the block ids.
  vector<BlockId> blocks_to_copy;
  BOOST_FOREACH(const RowSetDataPB& rowset, superblock_->rowsets()) {
    BOOST_FOREACH(const ColumnDataPB& col, rowset.columns()) {
      blocks_to_copy.push_back(BlockId::FromPB(col.block()));
    }
    BOOST_FOREACH(const DeltaDataPB& redo, rowset.redo_deltas()) {
      blocks_to_copy.push_back(BlockId::FromPB(redo.block()));
    }
    BOOST_FOREACH(const DeltaDataPB& undo, rowset.undo_deltas()) {
      blocks_to_copy.push_back(BlockId::FromPB(undo.block()));
    }
    if (rowset.has_bloom_block()) {
      blocks_to_copy.push_back(BlockId::FromPB(rowset.bloom_block()));
    }
    if (rowset.has_adhoc_index_block()) {
      blocks_to_copy.push_back(BlockId::FromPB(rowset.adhoc_index_block()));
    }
  }

  // Download all the blocks.
  int num_blocks = blocks_to_copy.size();
  LOG(INFO) << "Starting download of " << num_blocks << " data blocks...";
  int block_count = 0;
  BOOST_FOREACH(const BlockId& block_id, blocks_to_copy) {
    UpdateStatusMessage(Substitute("Downloading block $0 ($1/$2)",
                                   block_id.ToString(), ++block_count, num_blocks));
    RETURN_NOT_OK_PREPEND(DownloadBlock(block_id),
        "Unable to download block with id " + block_id.ToString());
  }

  return Status::OK();
}

Status RemoteBootstrapClient::DownloadWAL(const OpId& initial_opid, uint64_t wal_segment_seqno) {
  VLOG(1) << "Downloading WAL segment with seqno " << wal_segment_seqno;
  DataIdPB data_id;
  data_id.set_type(DataIdPB::LOG_SEGMENT);
  data_id.mutable_first_op_id()->CopyFrom(initial_opid);
  string dest_path = fs_manager_->GetWalSegmentFileName(tablet_id_, wal_segment_seqno);

  WritableFileOptions opts;
  opts.sync_on_close = true;
  WritableFile* writer;
  RETURN_NOT_OK_PREPEND(fs_manager_->env()->NewWritableFile(opts, dest_path, &writer),
                        "Unable to open file for writing");
  shared_ptr<WritableFile> refcounted_writer(writer);

  RETURN_NOT_OK_PREPEND(DownloadFile(data_id, refcounted_writer),
                        Substitute("Unable to download WAL segment with initial OpId $0",
                                   initial_opid.ShortDebugString()));
  return Status::OK();
}

Status RemoteBootstrapClient::DownloadBlock(const BlockId& block_id) {
  VLOG(1) << "Downloading block with block_id " << block_id.ToString();
  DataIdPB data_id;
  data_id.set_type(DataIdPB::BLOCK);
  block_id.CopyToPB(data_id.mutable_block_id());

  shared_ptr<WritableFile> writer;
  RETURN_NOT_OK_PREPEND(fs_manager_->CreateBlockWithId(block_id, &writer),
                        "Unable to create new block");

  RETURN_NOT_OK_PREPEND(DownloadFile(data_id, writer),
                        Substitute("Unable to download block $0", block_id.ToString()));
  return Status::OK();
}

Status RemoteBootstrapClient::DownloadFile(const DataIdPB& data_id,
                                           const shared_ptr<WritableFile>& writer) {
  uint64_t offset = 0;
  int32_t max_length = FLAGS_rpc_max_message_size - 1024; // Leave 1K for message headers.

  rpc::RpcController controller;
  controller.set_timeout(MonoDelta::FromMilliseconds(session_idle_timeout_millis_));
  FetchDataRequestPB req;

  bool done = false;
  while (!done) {
    controller.Reset();
    req.set_session_id(session_id_);
    req.mutable_data_id()->CopyFrom(data_id);
    req.set_offset(offset);
    req.set_max_length(max_length);

    FetchDataResponsePB resp;
    RETURN_NOT_OK_UNWIND_PREPEND(proxy_->FetchData(req, &resp, &controller),
                                controller,
                                "Unable to fetch data from remote");

    // Sanity-check for corruption.
    RETURN_NOT_OK_PREPEND(VerifyData(offset, resp.chunk()),
                          Substitute("Error validating data item $0", data_id.ShortDebugString()));

    // Write the data.
    RETURN_NOT_OK(writer->Append(resp.chunk().data()));

    if (offset + resp.chunk().data().size() == resp.chunk().total_data_length()) {
      done = true;
    }
    offset += resp.chunk().data().size();
  }

  return Status::OK();
}

Status RemoteBootstrapClient::VerifyData(uint64_t offset, const DataChunkPB& chunk) {
  // Verify the offset is what we expected.
  if (offset != chunk.offset()) {
    return Status::InvalidArgument("Offset did not match what was asked for",
        Substitute("$0 vs $1", offset, chunk.offset()));
  }

  // Verify the checksum.
  uint32_t crc32 = crc::Crc32c(chunk.data().data(), chunk.data().length());
  if (PREDICT_FALSE(crc32 != chunk.crc32())) {
    return Status::Corruption(
        Substitute("CRC32 does not match at offset $0 size $1: $2 vs $3",
          offset, chunk.data().size(), crc32, chunk.crc32()));
  }
  return Status::OK();
}

} // namespace tserver
} // namespace kudu