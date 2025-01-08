FROM chromium-dev:local
WORKDIR $HOME
RUN git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git && mkdir chromium

WORKDIR $HOME/chromium

RUN fetch --nohooks --no-history chromium

WORKDIR $HOME/chromium/src

RUN patchtool && gclient runhooks && gn gen \
    --args='use_siso=true use_remoteexec=true reclient_cfg_dir="../../buildtools/reclient_cfgs/linux"' \
    out/Default
