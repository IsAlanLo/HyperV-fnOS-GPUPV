#!/usr/bin/env bash
# lib/serve.sh - move the host's DriverStore into the guest when SSH/SMB is not
# an option: a throwaway HTTP PUT receiver.
#
# The Windows script normally uses SSH (scp/tar over ssh). This exists for the
# case where OpenSSH is not enabled on either side but the LAN reaches the guest,
# and for anyone doing it by hand.

cmd_receive() {
	local dir=${1:-/tmp/nvstore}
	local port=${2:-8899}
	mkdir -p "$dir" || die "cannot create $dir"
	local py
	py=$(mktemp -d "${TMPDIR:-/tmp}/gpupv-recv.XXXXXX")/http_put_server.py
	asset_write http_put_server.py "$py" || die "cannot materialise http_put_server.py"

	local ip
	ip=$(lan_ip)
	say "HTTP PUT receiver"
	note "listen 0.0.0.0:$port"
	note "write  $dir"
	[ -n "$ip" ] && note "url    http://$ip:$port/"
	note ""
	note "from the Windows host (Administrator PowerShell):"
	if [ -n "$ip" ]; then
		note "  curl.exe -s --max-time 5 http://$ip:$port/            # expect: alive"
		note "  .\\gpupv-windows.ps1 -Action Push -GuestUrl http://$ip:$port/"
	fi
	note ""
	note "each file answers 'ok <name> <bytes>'; a GET / lists what landed."
	note "Ctrl-C when the batch is in, then: $PROG driverstore compare $dir"
	note ""
	exec python3 "$py" "$dir" "$port"
}
