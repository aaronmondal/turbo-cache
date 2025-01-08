{
  stdenv,
  buildEnv,
  fetchzip,
  autoPatchelfHook,
  writeShellScriptBin,
  nix2container,
  runCommand,
  runtimeShell,
  lib,
  # Chromium deps start here.
  #Debug
  strace,
  file,
  # These are usually supplied by an FHSEnv.
  glibcLocales,
  gcc,
  bashInteractive,
  coreutils,
  less,
  # shadow, We bake this into the image manually.
  su,
  gawk,
  diffutils,
  findutils,
  gnused,
  gnugrep,
  gnutar,
  gzip,
  bzip2,
  xz,
  # Tools missing from the upstream nix shell.
  python3,
  git,
  curl,
  cacert,
  which,
  vim, # TODO(aaronmondal): Remove
  ## for reclient...
  # E0508 08:28:41.337763 2357393 auth.go:527] Credentials helper warnings and
  # ... errors: E0508 08:28:41.335345 2357400 main.go:64] Failed to initialize
  # ... credentials: failed to retrieve gcloud credentials. gcloud not
  # ... installed: exec: "gcloud": executable file not found in $PATH
  google-cloud-sdk,
  ## for `autoninja -C out/Debug content_shell`...
  # ERROR at //build/config/linux/pkg_config.gni:104:17: Script returned
  # ... non-zero exit code.
  # FileNotFoundError: [Errno 2] No such file or directory: 'pkg-config'
  pkg-config,
  # ../../third_party/llvm-build/Release+Asserts/bin/clang++: error while
  # ... loading shared libraries: libz.so.1: cannot open shared object file:
  # ... No such file or directory
  # ../../third_party/rust-toolchain/bin/rustc: error while loading shared
  # ... libraries: libz.so.1: cannot open shared object file: No such file or
  # ... directory
  zlib,
  # FileNotFoundError: [Errno 2] No such file or directory: 'gperf'
  gperf,
  # subprocess.CalledProcessError: Command '['/cuffs/build/chromium/src/out/
  # ...Reclient/wayland_scanner', '--version']' returned non-zero exit status
  # ... 127.
  # => /cuffs/build/chromium/src/out/Reclient/wayland_scanner: error while
  # ... loading shared libraries: libexpat.so.1: cannot open shared object
  # ... file: No such file or directory
  expat,
  # ./root_store_tool: error while loading shared libraries: <soname>: cannot
  # ... open shared object file: No such file or directory
  glib, # libglib-2.0.so.0
  nss, # libnss3.so
  # ./transport_security_state_generator: error while loading shared
  # ... libraries: libnspr4.so: cannot open shared object file: No such file
  # ... or directory
  nspr,
  # ././v8_context_snapshot_generator: error while loading shared libraries:
  # ... <soname>: cannot open shared object file: No such file or directory
  xorg, # various shared objects
  mesa, # libgbm.so.1
  libdrm, # libdrm.so.2
  alsa-lib, # libasound.so.2
  libxkbcommon, # libxkbcommon.so.0
  pango, # libpango-1.0.so.0
  dbus, # libdbus-1.so.3
  ## for `content_shell`...
  # out/Default/content_shell: error while loading shared libraries: <soname>:
  # ... cannot open shared object file: No such file or directory
  at-spi2-atk, # libatk-1.0.so.0
  cairo, # libcairo.so.2
  # [788412:788449:0502/062912.187804:FATAL:udev_loader.cc(48)] Check failed:
  # ... false.
  systemd,
  ## for `third_party/blink/tools/run_web_tests.py`...
  # FileNotFoundError raised: [Errno 2] No such file or directory: 'xdpyinfo'
  # xorg.xdpyinfo,
  ## for `chrome`...
  # out/Default/chrome: error while loading shared libraries: libcups.so.2:
  # cannot open shared object file: No such file or directory
  cups,
}: let
  # A temporary directory. Note that this doesn't set any permissions. Those
  # need to be added explicitly in the final image arguments.
  mkTmp = runCommand "mkTmp" {} ''
    mkdir -p $out/tmp
  '';

  # Permissions for the temporary directory.
  mkTmpPerms = {
    path = mkTmp;
    regex = ".*";
    mode = "1777";
    uid = 0; # Owned by root.
    gid = 0; # Owned by root.
  };

  # Enable the shebang `#!/usr/bin/env bash`.
  mkEnvSymlink = runCommand "mkEnvSymlink" {} ''
    mkdir -p $out/usr/bin
    ln -s /bin/env $out/usr/bin/env
  '';

  # Some dynamically fetched toolchain artifacts (like rustc) ignore the dynamic
  # loader path from the nix store. This symlink works around that. Note that
  # some executables in the chromium build only respect the ld.so.cache though,
  # so while this works for "most" executables, it doesn't work for e.g. rustc
  # which requires an explicit LD_LIBRARY_PATH and patches to its wrappers.
  mkLib64Symlink = runCommand "mkLib64Symlink" {} ''
    mkdir -p $out/lib64
    ln -s ${stdenv.cc.bintools.dynamicLinker} $out/${stdenv.hostPlatform.libDir}/$(basename ${stdenv.cc.bintools.dynamicLinker})
  '';

  user = "ubuntu";
  group = "ubuntu";
  uid = "1000";
  gid = "1000";

  mkUser = runCommand "mkUser" {} ''
    mkdir -p $out/etc/pam.d

    echo "root:x:0:0::/root:${runtimeShell}" > $out/etc/passwd
    echo "${user}:x:${uid}:${gid}:::" >> $out/etc/passwd

    echo "root:!x:::::::" > $out/etc/shadow
    echo "${user}:!x:::::::" >> $out/etc/shadow

    echo "root:x:0:" > $out/etc/group
    echo "${group}:x:${gid}:" >> $out/etc/group

    echo "root:x::" > $out/etc/gshadow
    echo "${group}:x::" >> $out/etc/gshadow

    cat > $out/etc/pam.d/other <<EOF
    account sufficient pam_unix.so
    auth sufficient pam_rootok.so
    password requisite pam_unix.so nullok sha512
    session required pam_unix.so
    EOF

    touch $out/etc/login.defs
    mkdir -p $out/home/${user}
  '';

  # Permissions for the user's home directory.
  mkUserPerms = {
    path = mkUser;
    regex = "/home/${user}";
    mode = "0755";
    uid = lib.toInt uid;
    gid = lib.toInt gid;
    uname = user;
    gname = group;
    dirOnly = true;
  };

  customClangd = stdenv.mkDerivation rec {
    pname = "clangd";
    version = "18.1.3";
    src = fetchzip {
      url = "https://github.com/clangd/clangd/releases/download/${version}/${pname}-linux-${version}.zip";
      sha256 = "sha256-6d1P510uHtXJ8fOyi2OZFyILDS8XgK6vsWFewKFVvq4=";
    };
    nativeBuildInputs = [autoPatchelfHook];
    installPhase = ''
      mkdir -p $out
      mv bin $out
      mv lib $out
    '';
  };

  patchtool = writeShellScriptBin "patchtool" ''
    set -xeuo pipefail

    # Remove authentication.
    # TODO(aaronmondal): Implement a credential helper for nativelink.
    sed -i '/$auth_flags/d' /home/ubuntu/chromium/src/buildtools/reclient_cfgs/reproxy_cfg_templates/reproxy.cfg.template

    # Ensure the gclient config references "chromium-untrusted" (not to be confused
    # with Don't confuse this "chrome-untrusted").
    cat <<EOF > /home/ubuntu/chromium/.gclient
    solutions = [
      {
        "name": "src",
        "url": "https://chromium.googlesource.com/chromium/src.git",
        "managed": False,
        "custom_deps": {},
        "custom_vars": {
          "rbe_instance": "projects/rbe-chromium-untrusted/instances/default_instance",
        },
      },
    ]
    EOF

    # Workarounds for the nonhermeticity of the chromium toolchain.
    cat > /tmp/changes.patch << 'EOL'
    diff --git a/build/rust/run_build_script.py b/build/rust/run_build_script.py
    index 3cbb2c0194..8e4838b789 100755
    --- a/build/rust/run_build_script.py
    +++ b/build/rust/run_build_script.py
    @@ -161,6 +161,7 @@ def main():
           env["RUST_BACKTRACE"] = os.environ.get("RUST_BACKTRACE")
         if os.environ.get("RUST_LOG"):
           env["RUST_LOG"] = os.environ.get("RUST_LOG")
    +    env["LD_LIBRARY_PATH"] = os.environ.get("LD_LIBRARY_PATH")

         # In the future we should, set all the variables listed here:
         # https://doc.rust-lang.org/cargo/reference/environment-variables.html#environment-variables-cargo-sets-for-build-scripts
    diff --git a/build/rust/rust_bindgen_generator.gni b/build/rust/rust_bindgen_generator.gni
    index c91916be93..128ff684e6 100644
    --- a/build/rust/rust_bindgen_generator.gni
    +++ b/build/rust/rust_bindgen_generator.gni
    @@ -172,7 +172,7 @@ template("rust_bindgen_generator") {
           # point to.
           args += [
             "--ld-library-path",
    -        rebase_path(clang_base_path + "/lib", root_build_dir),
    +        rebase_path(clang_base_path + "/lib", root_build_dir) + ":/lib",
           ]
         }

    EOL

    if git apply -v -R --check --ignore-whitespace /tmp/changes.patch &>/dev/null; then
        echo "Patches are already applied"
    elif git apply -v --check --ignore-whitespace /tmp/changes.patch &>/dev/null; then
        echo "Applying patches..."
        git apply -v /tmp/changes.patch
    else
        echo "Cannot apply patches cleanly"
        exit 1
    fi

    rm /tmp/changes.patch
  '';

  # Some chromium tools expect this symlink.
  cacert-for-chromium = cacert.overrideAttrs (old: {
    installPhase = ''
      ${old.installPhase}
      ln -s ca-bundle.crt "$out/etc/ssl/certs/ca-certificates.crt"
    '';
  });

  buildEnvPaths = [
    # These are usually supplied by an FHSEnv.
    glibcLocales
    stdenv.cc.libc # libc.so.6
    stdenv.cc.cc.lib # libstdc++.so.6
    bashInteractive
    coreutils
    less
    # shadow
    su
    gawk
    diffutils
    findutils
    gnused
    gnugrep
    gnutar
    gzip
    bzip2
    xz

    # DEBUG
    strace
    file
    gcc

    # This is missing from the upstream nix shell, but required for manual
    # interaction with some build tooling.
    (python3.withPackages (ps:
      with ps; [
        pip
        setuptools
        distutils
        distutils-extra
        httplib2
        six
        virtualenv
        boto3
        wheel
        packaging
        appdirs
      ]))
    git
    curl
    cacert-for-chromium
    which
    vim # TODO(aaronmondal): Remove

    # These are from the upstream nix shell.
    google-cloud-sdk
    pkg-config
    zlib
    gperf
    expat
    glib # glib compilers
    glib.out # libglib-2.0.so.0
    nss # libnss3.so
    nspr
    xorg.libX11 # libX11.so.6
    xorg.libXcomposite # libXcomposite.so.1
    xorg.libXdamage # libXdamage.so.1
    xorg.libXext # libXext.so.6
    xorg.libXfixes # libXfixes.so.3
    xorg.libXrandr # libXrandr.so.2
    xorg.libXtst # libXtst.so.6
    mesa # libgbm.so.1
    libdrm # libdrm.so.2
    alsa-lib # libasound.so.2
    libxkbcommon # libxkbcommon.so.0
    pango # libpango-1.0.so.0
    dbus # libdbus-1.so.3
    at-spi2-atk # libatk-1.0.so.0
    xorg.libxcb # libxcb.so.1
    cairo # libcairo.so.2
    systemd
    xorg.xdpyinfo
    cups
    customClangd
  ];

  fhsEnv = buildEnv {
    name = "chromium-env";
    paths = buildEnvPaths;
    pathsToLink = [
      "/bin"
      "/etc"
      "/include"
      "/lib"
      "/lib32"
      "/lib64"
      "/libexec"
      "/share"
      "/usr"
    ];
  };
in
  nix2container.buildImage {
    name = "chromium-dev";
    tag = "local";

    layers = [
      (nix2container.buildLayer {
        perms = [
          mkUserPerms
          mkTmpPerms
        ];
        copyToRoot = [
          mkEnvSymlink
          mkUser
          mkTmp
        ];
      })
    ];

    copyToRoot = [
      mkLib64Symlink
      fhsEnv
      patchtool
    ];

    config = {
      entrypoint = ["/bin/bash"];
      env = [
        "USER=${user}"
        "HOME=/home/${user}"
        "VPYTHON_BYPASS='manually managed python not supported by chrome operations'"
        "LOCALE_ARCHIVE=/usr/lib/locale/locale-archive"
        "SSL_CERT_FILE=${cacert-for-chromium}/etc/ssl/certs/ca-certificates.crt"
        "PS1=chromium-env:\\u@\\h:\\w\\$ "
        "PATH=/home/ubuntu/depot_tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "NIX_BINTOOLS_WRAPPER_TARGET_HOST_${stdenv.cc.suffixSalt}=1"
        "NIX_CC_WRAPPER_TARGET_HOST_${stdenv.cc.suffixSalt}=1"
        "NIX_CFLAGS_COMPILE=-idirafter /usr/include"
        "NIX_CFLAGS_LINK=-L/usr/lib -L/usr/lib32"
        "NIX_LDFLAGS=-L/usr/lib -L/usr/lib32"
        "PKG_CONFIG_PATH=/usr/lib/pkgconfig"
        "ACLOCAL_PATH=/usr/share/aclocal"
        "GST_PLUGIN_SYSTEM_PATH_1_0=/usr/lib/gstreamer-1.0:/usr/lib32/gstreamer-1.0"
        "XDG_DATA_DIRS=/run/opengl-driver/share:/run/opengl-driver-32/share:/usr/local/share:/usr/share"
        "LD_LIBRARY_PATH=/lib"
      ];
    };
  }
