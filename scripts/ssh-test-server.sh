#!/bin/bash
# Starts a throwaway SSH server (localhost:52222, user tunnel / tunnelpass) on a private docker
# network with the sample database (dbjoy-pg), for the SSH tunnel tests:
#   scripts/ssh-test-server.sh
#   DBJOY_TEST_SSH=1 DBJOY_TEST_SSH_KEY=/tmp/dbjoy_test_key swift test --filter SSHTunnelTests
#   docker rm -f dbjoy-ssh
set -euo pipefail
docker network create dbjoy-net >/dev/null 2>&1 || true
docker network connect dbjoy-net dbjoy-pg 2>/dev/null || true
docker rm -f dbjoy-ssh >/dev/null 2>&1 || true
docker run -d --name dbjoy-ssh --network dbjoy-net -p 127.0.0.1:52222:22 alpine:3.20 sh -c "
  apk add --no-cache openssh >/dev/null && ssh-keygen -A >/dev/null &&
  adduser -D -s /bin/sh tunnel && echo 'tunnel:tunnelpass' | chpasswd &&
  sed -i -E 's/^#?AllowTcpForwarding.*/AllowTcpForwarding yes/; s/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config &&
  mkdir -p /home/tunnel/.ssh && chown tunnel /home/tunnel/.ssh && chmod 700 /home/tunnel/.ssh &&
  exec /usr/sbin/sshd -D -e" >/dev/null
# The published port can accept connections before sshd is up, so wait inside the container.
for _ in $(seq 1 60); do
  docker exec dbjoy-ssh sh -c 'test -d /home/tunnel/.ssh && pgrep sshd' >/dev/null 2>&1 && break
  sleep 1
done
rm -f /tmp/dbjoy_test_key /tmp/dbjoy_test_key.pub
ssh-keygen -q -t ed25519 -N 'keypass' -f /tmp/dbjoy_test_key -C dbjoy-test
docker exec -i dbjoy-ssh sh -c 'cat > /home/tunnel/.ssh/authorized_keys && chown tunnel /home/tunnel/.ssh/authorized_keys && chmod 600 /home/tunnel/.ssh/authorized_keys' < /tmp/dbjoy_test_key.pub
echo "SSH test server ready on 127.0.0.1:52222"
