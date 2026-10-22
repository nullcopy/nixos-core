# The backup peers: every machine that sends or receives ZFS
# replication, keyed by name. modules/backup.nix reads this as the
# default of core.backup.peers.
#
# hostKey is the machine's SSH host public key
# (/etc/ssh/ssh_host_ed25519_key.pub). It identifies the machine in
# both directions: receivers accept it as the login key of recv-<name>,
# and senders verify it as the host key of <name>. Public keys only;
# nothing here is secret.
#
# address is where SSH reaches the machine; it defaults to the name,
# which the tailnet resolves.
{
  hawkeye = {
    hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKXZyEGoiojXhZ7AbCO3ByzXStBSDT0vCdryxuMtXQvq";
  };
  obelisk = {
    hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIENAUeUrO1CAMPc89fMSrJyoyl7B2TJRLhOdRKL2ou1/";
  };
}
