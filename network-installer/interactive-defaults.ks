# Stay interactive: the operator must deliberately select and confirm storage.
text
network --bootproto=dhcp --device=link --activate --onboot=on

# Resolve this mutable stream only after the installer has booted. The system
# keeps the canonical reference as its update identity; containers/image uses
# the installed repository-scoped mirror configuration for registry failover.
bootc --source-imgref registry:pubcode.archuser.org/universalblue/bazzite-firebadnofire:stable --target-imgref pubcode.archuser.org/universalblue/bazzite-firebadnofire:stable
