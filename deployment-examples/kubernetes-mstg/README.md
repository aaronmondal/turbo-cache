# Chromium example

This deployment sets up a 4-container deployment with separate CAS, scheduler
and two worker pods. Don't use this example deployment in production. It's
insecure.

All commands should be run from nix to ensure all dependencies exist in the
environment:

```bash
nix develop
```

In this example we're using `kind` to set up the cluster `cilium` to provide a
`LoadBalancer` and `GatewayController`.

First set up a local development cluster:

```bash
./00_infra.sh
```

Next start a few standard deployments. This part also builds the remote
execution container and makes it available to the cluster:

```bash
./01_operations.sh
```

Before we can deploy NativeLink, set the `NATIVELINK_WORKER_PLATFORM` variable
in the `worker.yaml` to the `container-image` property of your Bazel platform:

```yaml
# Modify worker.yaml
...
- name: NATIVELINK_WORKER_PLATFORM
  value: your-platform
```

Finally, deploy NativeLink:

```bash
./02_application.sh
```

> [!TIP]
> You can use `./03_delete_application.sh` to remove just the `nativelink`
> deployments but leave the rest of the cluster intact.

This demo setup creates two gateways to expose the `cas` and `scheduler`
deployments via your local docker network:

```bash
CACHE=$(kubectl get gtw cache -o=jsonpath='{.status.addresses[0].value}')
SCHEDULER=$(kubectl get gtw scheduler -o=jsonpath='{.status.addresses[0].value}')

echo "Cache IP: $CACHE"
echo "Scheduler IP: $SCHEDULER"
```

You can now pass these IP addresses to your Bazel invocation to use the remote
cache and executor. Add the following to your `.bazelrc`:

```bash
# Ensure that we're not leaking local PATH and LD_LIBRARY_PATH information into
# the build.
common --incompatible_strict_action_env

# Basic remote execution configuration.
build:nativelink --define=EXECUTOR=remote
build:nativelink --repo_env=BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1

# The instance name for nativelink. Most likely `main` is correct here.
# Depending on the nativelink configuration this might need to be adjusted.
build:nativelink --remote_instance_name=main

# Select the correct toolchains.
build:nativelink --extra_execution_platforms=YOURPLATFORMFORTHEIMAGE
build:nativelink --extra_toolchains=YOURTOOLCHAINFORTHEIMAGE

# TODO(aaronmondal): Either set the correct values in this file or add them to
#                    the Bazel build command.
# build:nativelink --remote_cache=grpc://172.18.255.10:50051
# build:nativelink --remote_executor=grpc://172.18.255.9:50052
```

> [!TIP]
> You can monitor the logs of container groups with `kubectl logs`:
> ```bash
> kubectl logs -f -l app=nativelink-cas
> kubectl logs -f -l app=nativelink-scheduler
> kubectl logs -f -l app=nativelink-worker-mstg-rbe --all-containers=true
> ```

When you're done testing, delete the cluster:

```bash
kind delete cluster
```
