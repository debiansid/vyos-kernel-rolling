#!/bin/sh

set -eux
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

passed=0
finish() {
	status=$?
	trap - EXIT
	if [ "$passed" -eq 1 ]; then
		echo FULLCONE_TEST_PASS
	else
		echo "FULLCONE_TEST_FAIL status=$status"
		ip netns exec router nft list ruleset || true
		ip netns exec router conntrack -L -p udp || true
	fi
	sync
	reboot -f || poweroff -f
	while :; do sleep 1; done
}
trap finish EXIT

for command in ip nft conntrack socat ss modprobe; do
	command -v "$command"
done
nft --version

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /run
mkdir -p /run/netns /tmp

modprobe nft_fullcone
modprobe veth
modprobe bridge

ip link add br-wan type bridge
ip link set br-wan up

add_wan_node() {
	name=$1
	address=$2
	ip netns add "$name"
	ip link add "$name-br" type veth peer name wan0
	ip link set wan0 netns "$name"
	ip link set "$name-br" master br-wan
	ip link set "$name-br" up
	ip -n "$name" link set lo up
	ip -n "$name" link set wan0 up
	ip -n "$name" address add "$address/24" dev wan0
}

add_wan_node router 192.0.2.1
add_wan_node peer1 192.0.2.2
add_wan_node peer2 192.0.2.3
add_wan_node peer3 192.0.2.4

ip netns add client
ip link add lan0 type veth peer name eth0
ip link set lan0 netns router
ip link set eth0 netns client
ip -n router link set lan0 up
ip -n router address add 10.0.0.1/24 dev lan0
ip -n client link set lo up
ip -n client link set eth0 up
ip -n client address add 10.0.0.2/24 dev eth0
ip -n client route add default via 10.0.0.1
ip netns exec router sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'

install_rules() {
	case $1 in
	fullcone)
		ip netns exec router nft -f - <<'EOF'
table ip fullcone_test {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		iifname "wan0" fullcone
	}

	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "wan0" meta l4proto udp fullcone to :20000-20010
	}
}
EOF
		;;
	brcm)
		ip netns exec router nft -f - <<'EOF'
table ip fullcone_test {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
	}

	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "wan0" masquerade brcmfullcone
	}
}
EOF
		;;
	esac
}

receive_once() {
	namespace=$1
	port=$2
	output=$3
	ip netns exec "$namespace" socat -T 10 -u "UDP4-RECVFROM:$port,reuseaddr" \
		"OPEN:$output,creat,trunc"
}

wait_for_listener() {
	namespace=$1
	port=$2
	pid=$3
	tries=0
	while [ "$tries" -lt 50 ]; do
		kill -0 "$pid" 2>/dev/null || return 1
		if ip netns exec "$namespace" ss -H -4 -u -l -n "sport = :$port" | grep -q .; then
			return 0
		fi
		tries=$((tries + 1))
		sleep 0.1
	done
	return 1
}

wait_for_payload() {
	output=$1
	payload=$2
	pid=$3
	tries=0
	while [ "$tries" -lt 50 ]; do
		if grep -qx "$payload" "$output" 2>/dev/null; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
			return 0
		fi
		tries=$((tries + 1))
		sleep 0.1
	done
	return 1
}

send_from_client() {
	destination=$1
	port=$2
	payload=$3
	printf '%s\n' "$payload" | ip netns exec client socat -T 3 -u STDIN \
		"UDP4-DATAGRAM:$destination:$port,bind=:12345"
}

mapping_port() {
	destination=$1
	destination_port=$2
	tries=0
	while [ "$tries" -lt 50 ]; do
		port=$(ip netns exec router conntrack -L -p udp |
			grep "src=10.0.0.2 dst=$destination sport=12345 dport=$destination_port" |
			sed -n "s/.*src=$destination dst=192\\.0\\.2\\.1 sport=$destination_port dport=\\([0-9]*\\).*/\\1/p" |
			head -n 1)
		if [ -n "$port" ]; then
			echo "$port"
			return 0
		fi
		tries=$((tries + 1))
		sleep 0.1
	done
	return 1
}

exercise_path() {
	name=$1
	min_port=$2
	max_port=$3
	rm -f /tmp/peer1.out /tmp/peer2.out /tmp/client.out

	receive_once peer1 4000 /tmp/peer1.out &
	peer1_pid=$!
	wait_for_listener peer1 4000 "$peer1_pid"
	send_from_client 192.0.2.2 4000 peer1
	wait_for_payload /tmp/peer1.out peer1 "$peer1_pid"
	port1=$(mapping_port 192.0.2.2 4000)

	receive_once peer2 4001 /tmp/peer2.out &
	peer2_pid=$!
	wait_for_listener peer2 4001 "$peer2_pid"
	send_from_client 192.0.2.3 4001 peer2
	wait_for_payload /tmp/peer2.out peer2 "$peer2_pid"
	port2=$(mapping_port 192.0.2.3 4001)
	test "$port1" = "$port2"
	test "$port1" -ge "$min_port"
	test "$port1" -le "$max_port"

	receive_once client 12345 /tmp/client.out &
	client_pid=$!
	wait_for_listener client 12345 "$client_pid"
	printf 'unsolicited\n' | ip netns exec peer3 socat -T 3 -u STDIN \
		"UDP4-DATAGRAM:192.0.2.1:$port1"
	wait_for_payload /tmp/client.out unsolicited "$client_pid"

	ip netns exec router nft list ruleset
	ip netns exec router conntrack -L -p udp
	echo "FULLCONE_PATH_PASS name=$name port=$port1"
}

install_rules fullcone
exercise_path fullcone 20000 20010

ip netns exec router nft flush ruleset
ip netns exec router conntrack -F expect || true
ip netns exec router conntrack -F

install_rules brcm
exercise_path brcm 1 65535
passed=1
