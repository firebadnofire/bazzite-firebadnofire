# bazzite-firebadnofire

Personal Fedora Atomic/Bazzite workstation image.

## Goals

- Hyprland-first desktop
- NVIDIA RTX desktop support
- Gaming functionality inherited from Bazzite
- Strong remote-system-administration toolset
- VFIO/libvirt workstation functionality
- Comfortable general Linux development environment
- Reproducible workstation deployment
- Built and published through Forgejo Actions
- OCI images signed with Cosign

## Non-goals

- Minimal image size
- Supporting arbitrary hardware
- Supporting GNOME
- Supporting KDE as a primary desktop
- Being a general-purpose public Linux distribution
- Maintaining replacements for functionality already maintained by Bazzite

## Philosophy

Prefer packages in the base image when they are:
- system administration tools
- hardware integration
- desktop/session infrastructure
- virtualization infrastructure
- tools expected to always be available

Prefer Flatpak for ordinary graphical applications.

Prefer Distrobox/containers for project-specific development environments.

Keep user configuration/dotfiles outside the image where practical.

## Target

Architecture: x86_64
GPU: NVIDIA
Desktop: Hyprland
Base: appropriate Bazzite NVIDIA desktop image
CI: Forgejo Actions
Registry: <registry>
Image: bazzite-firebadnofire

## Maintenance

Keep modifications to upstream Bazzite as shallow as practical.
Do not duplicate Bazzite functionality unnecessarily.
Prefer upstream packages over locally maintained forks.