#!/usr/bin/env bash
# Scenario: lefthookVersion=latest. Verifies binary installed, dispatchers
# installed with correct perms, and dispatcher runtime semantics.
set -euo pipefail

echo "==> scenario: lefthook binary installed"
[ -x /usr/local/bin/lefthook ] || { echo "FAIL: lefthook binary missing"; exit 1; }
/usr/local/bin/lefthook version >/dev/null \
  || { echo "FAIL: lefthook binary not runnable"; exit 1; }

echo "==> scenario: dispatcher files installed with correct perms"
for hook in pre-commit commit-msg; do
  path="/etc/git-hooks-readonly/$hook"
  [ -f "$path" ] || { echo "FAIL: $path missing"; exit 1; }
  perms=$(stat -c %a "$path")
  [ "$perms" = "555" ] || { echo "FAIL: $path perms $perms != 555"; exit 1; }
  owner=$(stat -c '%U:%G' "$path")
  [ "$owner" = "root:root" ] || { echo "FAIL: $path owner $owner != root:root"; exit 1; }
done

echo "==> scenario: dispatcher silent in repo without lefthook.yml"
tmp=$(mktemp -d)
( cd "$tmp" && git init -q )
out=$(cd "$tmp" && /etc/git-hooks-readonly/pre-commit 2>&1; echo "exit=$?")
case "$out" in
  *"exit=0"*) ;;
  *) echo "FAIL: dispatcher non-zero in repo without lefthook.yml: $out"; rm -rf "$tmp"; exit 1 ;;
esac
rm -rf "$tmp"

echo "==> scenario: dispatcher dispatches to lefthook with passing config"
tmp=$(mktemp -d)
( cd "$tmp" && git init -q && cat >lefthook.yml <<'EOF'
pre-commit:
  commands:
    ok:
      run: "true"
EOF
)
( cd "$tmp" && /etc/git-hooks-readonly/pre-commit ) \
  || { echo "FAIL: dispatcher non-zero with passing lefthook.yml"; rm -rf "$tmp"; exit 1; }
rm -rf "$tmp"

echo "==> scenario: dispatcher fails closed on failing config"
tmp=$(mktemp -d)
( cd "$tmp" && git init -q && cat >lefthook.yml <<'EOF'
pre-commit:
  commands:
    fail:
      run: "false"
EOF
)
if ( cd "$tmp" && /etc/git-hooks-readonly/pre-commit ); then
  echo "FAIL: dispatcher exit 0 when lefthook command failed"; rm -rf "$tmp"; exit 1
fi
rm -rf "$tmp"

echo "==> scenario: commit-msg dispatcher dispatches to lefthook with passing config"
tmp=$(mktemp -d)
( cd "$tmp" && git init -q && cat >lefthook.yml <<'EOF'
commit-msg:
  commands:
    ok:
      run: "true"
EOF
)
( cd "$tmp" && /etc/git-hooks-readonly/commit-msg /dev/null ) \
  || { echo "FAIL: commit-msg dispatcher non-zero with passing lefthook.yml"; rm -rf "$tmp"; exit 1; }
rm -rf "$tmp"

echo "==> scenario: dispatcher fails when binary missing but config present"
tmp=$(mktemp -d)
( cd "$tmp" && git init -q && cat >lefthook.yml <<'EOF'
pre-commit:
  commands:
    ok:
      run: "true"
EOF
)
# Temporarily hide the lefthook binary
mv /usr/local/bin/lefthook /usr/local/bin/lefthook.bak
err_out=$(cd "$tmp" && /etc/git-hooks-readonly/pre-commit 2>&1; echo "exit=$?")
mv /usr/local/bin/lefthook.bak /usr/local/bin/lefthook
case "$err_out" in
  *"claude-sandbox:"*"exit=1"*) ;;
  *) echo "FAIL: expected claude-sandbox: message and exit=1, got: $err_out"; rm -rf "$tmp"; exit 1 ;;
esac
rm -rf "$tmp"

echo "All lefthook-enabled scenario tests passed."
