FROM archlinux:latest

RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
      archiso \
      base-devel \
      devtools \
      git \
      cmake \
      ninja \
      gcc \
      pkgconf \
      grub \
      qemu-system-x86 \
      edk2-ovmf \
      sudo \
      tree \
      jq \
      ripgrep \
      curl \
      wget \
      dosfstools \
      mtools \
      squashfs-tools \
      xorriso \
      libisoburn \
      wlroots0.19 \
      wayland-protocols \
      libxrandr \
      libxinerama \
      libxcursor \
      libxi && \
    pacman -Scc --noconfirm

WORKDIR /workspace

CMD ["/bin/bash"]
