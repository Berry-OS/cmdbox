"""udhcpd + udhcpc + dumpleases + dhcprelay-less loop inside a private network namespace (veth pair).
usage: dhcp_compat.py <cmdbox>   (skipped without root / unshare / ip)"""
import os, shutil, subprocess, sys, tempfile
from pathlib import Path
binary = str(Path(sys.argv[1]).resolve())
if os.geteuid() != 0 or not shutil.which('unshare') or not shutil.which('ip'):
    print('dhcp tests skipped (need root, unshare, ip)'); sys.exit(0)
if subprocess.run(['unshare', '-n', '-m', '--propagation', 'private', 'true'], capture_output=True).returncode != 0:
    print('dhcp tests skipped (cannot create a network namespace)'); sys.exit(0)

script = r'''
set -e
B="$1"; D="$2"
NS=dhcpt$$
trap 'ip netns del $NS 2>/dev/null || true' EXIT
ip netns add $NS
ip link add veth0 type veth peer name veth1
ip link set veth1 netns $NS
ip addr add 192.168.77.1/24 dev veth0
ip link set veth0 up; ip link set lo up
ip -n $NS link set veth1 up; ip -n $NS link set lo up
MAC=$(ip -n $NS -o link show veth1 | sed -n 's/.*link\/ether \([0-9a-f:]*\) .*/\1/p')
cat > $D/ud.conf <<EOC
start 192.168.77.100
end 192.168.77.102
interface veth0
lease_file $D/ud.leases
pidfile $D/ud.pid
opt_lease 120
option subnet 255.255.255.0
option router 192.168.77.1
option dns 192.168.77.1 8.8.8.8
option domain test.local
EOC
cat > $D/cs.sh <<'EOC'
#!/bin/sh
case "$1" in bound|renew) ip addr replace $ip/$mask dev $interface;; deconfig) ip addr flush dev $interface;; esac
echo "$1 ip=$ip subnet=$subnet mask=$mask broadcast=$broadcast router=$router dns=$dns domain=$domain lease=$lease serverid=$serverid hostname=$hostname" >> $LOG
EOC
chmod +x $D/cs.sh
bash -c "exec -a udhcpd $B -f $D/ud.conf" &
SP=$!
sleep 1
export LOG=$D/s1.log
ip netns exec $NS bash -c "exec -a udhcpc $B -i veth1 -s $D/cs.sh -n -q -F myhost" > $D/c1.out 2>&1 && echo "rc1=0" || echo "rc1=$?"
bash -c "exec -a dumpleases $B -f $D/ud.leases" > $D/dump.out 2>&1
bash -c "exec -a dumpleases $B -a -f $D/ud.leases" > $D/dumpa.out 2>&1
# second request keeps the same address; a release frees it
export LOG=$D/s2.log
ip netns exec $NS bash -c "exec -a udhcpc $B -i veth1 -s $D/cs.sh -n -q -R" > $D/c2.out 2>&1 && echo "rc2=0" || echo "rc2=$?"
sleep 0.5
bash -c "exec -a dumpleases $B -f $D/ud.leases" > $D/dump2.out 2>&1
# a static lease takes precedence
printf 'static_lease %s 192.168.77.101\n' "$MAC" >> $D/ud.conf
kill $SP; wait $SP 2>/dev/null || true
rm -f $D/ud.leases
bash -c "exec -a udhcpd $B -f $D/ud.conf" &
SP=$!
sleep 1
export LOG=$D/s3.log
ip netns exec $NS bash -c "exec -a udhcpc $B -i veth1 -s $D/cs.sh -n -q" > $D/c3.out 2>&1 && echo "rc3=0" || echo "rc3=$?"
kill $SP; wait $SP 2>/dev/null || true
# no server: -n gives up
export LOG=$D/s4.log
ip netns exec $NS bash -c "exec -a udhcpc $B -i veth1 -s $D/cs.sh -n -t 1 -T 1" > $D/c4.out 2>&1 && echo "rc4=0" || echo "rc4=$?"
'''
fails = []
n = 0
def check(name, cond, info=''):
    global n
    n += 1
    if not cond:
        fails.append((name, info))

with tempfile.TemporaryDirectory() as d:
    r = subprocess.run(['unshare', '-n', '-m', '--propagation', 'private', 'bash', '-c', script, 'x', binary, d], capture_output=True, text=True, timeout=120)
    if os.environ.get('DHCP_DEBUG'): print(r.stdout, r.stderr, [ (f, open(os.path.join(d,f)).read()) for f in sorted(os.listdir(d)) if f.endswith(('.out','.log'))])
    rd = lambda f: open(os.path.join(d, f)).read() if os.path.exists(os.path.join(d, f)) else ''
    out = r.stdout
    check('rc1', 'rc1=0' in out, r.stdout + r.stderr)
    c1 = rd('c1.out')
    check('client messages', 'udhcpc: started, v1.22.1' in c1 and 'broadcasting discover' in c1 and 'broadcasting select for 192.168.77.100, server 192.168.77.1' in c1 and 'lease of 192.168.77.100 obtained from 192.168.77.1, lease time 120' in c1, c1)
    s1 = rd('s1.log').split('\n')
    check('deconfig first', s1[0].startswith('deconfig'), s1)
    check('bound env', s1[1] == 'bound ip=192.168.77.100 subnet=255.255.255.0 mask=24 broadcast=192.168.77.255 router=192.168.77.1 dns=192.168.77.1 8.8.8.8 domain=test.local lease=120 serverid=192.168.77.1 hostname=', s1)
    dump = rd('dump.out').split('\n')
    check('dumpleases header', dump[0] == 'Mac Address       IP Address      Host Name           Expires in', dump[0])
    check('dumpleases row', dump[1].split()[1:3] == ['192.168.77.100', 'myhost'] and dump[1].split()[-1].startswith('00:01:5') or dump[1].split()[-1].startswith('00:02:0'), dump[1])
    check('dumpleases -a', 'Expires at' in rd('dumpa.out'), rd('dumpa.out'))
    check('rc2 and same address', 'rc2=0' in out and 'lease of 192.168.77.100 obtained' in rd('c2.out'), rd('c2.out'))
    check('release message', 'unicasting a release of 192.168.77.100' in rd('c2.out'), rd('c2.out'))
    check('release frees lease', len(rd('dump2.out').strip().split('\n')) == 1, rd('dump2.out'))
    check('static lease', 'rc3=0' in out and 'lease of 192.168.77.101 obtained' in rd('c3.out'), rd('c3.out'))
    check('no server fails', 'rc4=1' in out and 'no lease, failing' in rd('c4.out'), rd('c4.out'))
    check('leasefail script', 'leasefail' in rd('s4.log'), rd('s4.log'))

if fails:
    for f in fails:
        print('FAIL', f)
    sys.exit(1)
print(f'{n} dhcp checks passed')
