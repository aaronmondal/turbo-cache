#!/usr/bin/env bash

set -euo pipefail

function fetch_chromium() {
    mkdir -p ${HOME}/chromium
    cd ${HOME}/chromium
    fetch --no-history chromium
}

# Based on requirements Ubuntu is the most well supported system
# https://chromium.googlesource.com/chromium/src/+/main/docs/linux/build_instructions.md
if ! grep -q 'ID=ubuntu' /etc/os-release; then
    echo "This system is not running Ubuntu."
    exit 0
fi

if [ -d "${HOME}/chromium/src" ]; then
    echo "Using existing chromium checkout"
    cd ${HOME}/chromium
    set +e
    gclient sync --no-history
    exit_status=$?
    set -e
    if [ $exit_status -ne 0 ]; then
        echo "Failed to sync, removing files in ${HOME}/chromium"
        rm -rf ${HOME}/chromium/
        fetch_chromium
    fi

    cd src
else
    echo "This script will modify the local system by adding depot_tools to .bashrc,"
    echo "downloading chrome code base and installing dependencies based on instructions"
    echo "https://chromium.googlesource.com/chromium/src/+/main/docs/linux/build_instructions.md."
    echo "Do you want to continue? (yes/no)"
    read answer
    answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')
    if [[ "$answer" != "yes" ]]; then
        echo "Exiting."
        # Exit or handle "no" logic here
        exit 0
    fi

    # Add depot_tools to path
    if [[ "$PATH" != *"/depot_tools"* ]]; then
        cd ${HOME}
        git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
        echo 'export PATH="${HOME}/depot_tools:$PATH"' >> ${HOME}/.bashrc
        export PATH="${HOME}/depot_tools:$PATH"
    fi

    # Checkout chromium into home directory without history
    fetch_chromium
    cd src

    # Install dependencies required for clients to have on chromium builds
    ./build/install-build-deps.sh
fi

echo "Generating ninja projects"
# Siso
# gn gen --args='use_siso=true use_remoteexec=true reclient_cfg_dir="../../buildtools/reclient_cfgs/linux"' out/Default

# Reclient
gn gen --args='use_remoteexec=true reclient_cfg_dir="../../buildtools/reclient_cfgs/linux"' out/Default

# Error?
#  2025-01-16T21:23:01.303891Z  INFO nativelink_service::bytestream_server: return: Ok(
#Response { metadata: MetadataMap { headers: {} }, message: WriteResponse { committed_s
#ize: 276 }, extensions: Extensions })
#    at nativelink-service/src/bytestream_server.rs:391
#    in nativelink_service::bytestream_server::inner_write with digest: DigestInfo("dfb
#b59f5c026921c04f17d507a4988605d66a965ac4c89eca3ec69b5c26b0277-276"), stream: WriteRequ
#estStreamWrapper { resource_info: ResourceInfo { instance_name: "", uuid: Some("a571de
#c9-f799-4e4c-8f3b-58c08c586a39"), compressor: None, digest_function: None, hash: "dfbb
#59f5c026921c04f17d507a4988605d66a965ac4c89eca3ec69b5c26b0277", size: "276", expected_s
#ize: 276, optional_metadata: None }, bytes_received: 0, first_msg: Some(WriteRequest {
# resource_name: "/uploads/a571dec9-f799-4e4c-8f3b-58c08c586a39/blobs/dfbb59f5c026921c0
#4f17d507a4988605d66a965ac4c89eca3ec69b5c26b0277/276", write_offset: 0, finish_write: f
#alse, data: b"\x1b[1m../../third_party/protobuf/src/google/protobuf/service.cc:35:10:
#\x1b[0m\x1b[0;1;31mfatal error: \x1b[0m\x1b[1m'google/protobuf/service.h' file not fou
#nd\x1b[0m\n   35 | #include <google/protobuf/service.h>\x1b[0m\n      | \x1b[0;1;32m
#       ^~~~~~~~~~~~~~~~~~~~~~~~~~~\n\x1b[0m1 error generated.\n" }), write_finished: f
#alse }, stream.first_msg: "<redacted>"
#    in nativelink_service::bytestream_server::bytestream_write
#    in nativelink_service::bytestream_server::write with request: Streaming
#    in nativelink_util::task::http_executor
#    in nativelink::services::http_connection with remote_addr: 10.0.3.185:45014, socke
#t_addr: 0.0.0.0:50051

# Fetch cache and schedular IP address for passing to ninja
NATIVELINK=$(kubectl get gtw nativelink-gateway -o=jsonpath='{.status.addresses[0].value}')

echo "Starting autoninja build"
RBE_service=${NATIVELINK}:80 RBE_cas_service=${NATIVELINK}:80 RBE_instance="" RBE_reclient_timeout=60m RBE_exec_timeout=4m RBE_service_no_security=true RBE_service_no_auth=true RBE_local_resource_fraction=0.00001 RBE_automatic_auth=false RBE_gcert_refresh_timeout=20 RBE_compression_threshold=-1 RBE_metrics_namespace="" RBE_platform= RBE_experimental_credentials_helper= RBE_experimental_credentials_helper_args= RBE_use_rpc_credentials=false autoninja -v -j 24 -C out/Default cc_unittests
