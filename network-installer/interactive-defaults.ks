# Stay interactive: the operator must deliberately select and confirm storage.
text
network --bootproto=dhcp --device=link --activate --onboot=on

# Resolve this mutable stream only after the installer has booted. The system
# fetches the source directly from GHCR, then keeps the canonical Pubcode
# reference as its update identity; later pulls try the GHCR mirror first.
bootc --source-imgref registry:ghcr.io/firebadnofire/bazzite-firebadnofire:stable --target-imgref pubcode.archuser.org/universalblue/bazzite-firebadnofire:stable
