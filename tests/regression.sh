#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/rh-regression.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() {
  [ "$2" = "$3" ] || fail "$1: expected '$3', got '$2'"
}
assert_grep() {
  grep -F -- "$2" "$1" >/dev/null || fail "$3: missing '$2' in $1"
}

. "$ROOT/scripts/_common.sh"

parse_via "ssh -J jump -p 2222 -i /tmp/key dev@example.com"
assert_eq "host" "$V_HOST" "example.com"
assert_eq "port" "$V_PORT" "2222"
assert_eq "user" "$V_USER" "dev"
assert_eq "identity" "$V_IDENTITY" "/tmp/key"
assert_eq "proxyjump" "$V_PROXYJUMP" "jump"

parse_via "ssh -o ProxyJump=bastion -o Port=2022 -o User=deploy app.internal"
assert_eq "o-host" "$V_HOST" "app.internal"
assert_eq "o-port" "$V_PORT" "2022"
assert_eq "o-user" "$V_USER" "deploy"
assert_eq "o-proxyjump" "$V_PROXYJUMP" "bastion"

parse_via "ssh -F /tmp/ssh_config app.internal"
assert_eq "unsupported ssh options" "$V_UNSUPPORTED_SSH_OPTIONS" " -F"

CFG="$tmp/config"
touch "$CFG"
parse_via "ssh -J jumpbox -p 2200 -i /tmp/key user@example.com"
write_managed_alias example-dev "    ServerAliveInterval 30"
assert_grep "$CFG" "Host example-dev" "managed alias"
assert_grep "$CFG" "    HostName example.com" "managed hostname"
assert_grep "$CFG" "    Port 2200" "managed port"
assert_grep "$CFG" "    User user" "managed user"
assert_grep "$CFG" "    IdentityFile /tmp/key" "managed identity"
assert_grep "$CFG" "    ProxyJump jumpbox" "managed proxyjump"

parse_via "ssh -J otherjump user@example.com"
write_managed_alias example-dev
host_count="$(awk '$1=="Host" && $2=="example-dev"{n++} END{print n+0}' "$CFG")"
assert_eq "idempotent alias count" "$host_count" "1"
assert_grep "$CFG" "    ProxyJump otherjump" "managed alias replacement"

remote_root="$tmp/root with 'quote"
mkdir -p "$remote_root/project"
mkdir -p "$remote_root/sub/deeprepo/.git"   # depth-2 git repo — only scan_projects reaches it
mkdir -p "$tmp/bin"
cat > "$tmp/bin/ssh" <<'EOS'
#!/usr/bin/env bash
remote_cmd="${!#}"
sh -c "$remote_cmd"
EOS
chmod +x "$tmp/bin/ssh"
PATH="$tmp/bin:$PATH" "$ROOT/scripts/list-projects.sh" \
  --via dummy --root "$remote_root" --limit 5 > "$tmp/projects.out"
assert_grep "$tmp/projects.out" "PROJECT	$remote_root/project	-" "remote root quoting"

assert_grep "$tmp/projects.out" "$remote_root/sub/deeprepo" "depth-2 git repo via scan_projects (skip_dir clobber regression)"

mkdir -p "$tmp/code" "$tmp/mount" "$tmp/home with 'quote/.codex" "$tmp/rh with 'quote"
printf 'personal guidance\n' > "$tmp/home with 'quote/.codex/AGENTS.md"
rh_home="$tmp/rh with 'quote"
home_dir="$tmp/home with 'quote"
session_key="$(printf '%s' "$tmp/mount" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
session_dir="$rh_home/.sessions/$session_key"
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" on codex "$tmp/code" laptop "$tmp/mount" 0 > "$tmp/inject.out"
assert_grep "$tmp/inject.out" "RH_STATUS=INJECTED" "inject on"
assert_grep "$tmp/inject.out" "RH_LAUNCH_ENV=CODEX_HOME='" "inject codex env quoted"
assert_grep "$tmp/inject.out" "'\\''quote" "inject codex env escapes apostrophe"
assert_grep "$tmp/inject.out" "-c 'sandbox_workspace_write.writable_roots=[\"~/.ssh\"]'" "inject codex flags quoted"
[ -f "$session_dir/rule.md" ] || fail "inject rule file missing"
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" off codex "$tmp/mount" > "$tmp/inject-off.out"
assert_grep "$tmp/inject-off.out" "RH_STATUS=RESTORED" "inject off"
[ ! -d "$session_dir" ] || fail "inject session dir was not removed"

RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" on claude "$tmp/code" laptop "$tmp/mount-claude" 0 > "$tmp/inject-claude.out"
assert_grep "$tmp/inject-claude.out" "RH_LAUNCH_FLAGS=--append-system-prompt-file '" "inject claude flag quoted"
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" off claude "$tmp/mount-claude" >/dev/null
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" on opencode "$tmp/code" laptop "$tmp/mount-opencode" 1 > "$tmp/inject-opencode.out"
assert_grep "$tmp/inject-opencode.out" "RH_LAUNCH_ENV=OPENCODE_CONFIG='" "inject opencode env quoted"
RH_HOME="$rh_home" HOME="$home_dir" \
  "$ROOT/scripts/inject-rule.sh" off opencode "$tmp/mount-opencode" >/dev/null

cat > "$tmp/bin/sudo" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
cat > "$tmp/bin/systemctl" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
cat > "$tmp/bin/service" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
cat > "$tmp/bin/sshd" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$tmp/bin/sudo" "$tmp/bin/systemctl" "$tmp/bin/service" "$tmp/bin/sshd"
setup_home="$tmp/setup-home"
mkdir -p "$setup_home"
HOME="$setup_home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" \
  bash "$ROOT/scripts/laptop-setup.sh" \
    --host example.com --port 32022 \
    --via "ssh -J jumpbox -i /tmp/key user@example.com" \
    --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test" \
    --box-alias laptop --setup-only --yes > "$tmp/setup-only.out"
assert_grep "$setup_home/.ssh/config" "Host user-remote" "setup-only managed alias"
assert_grep "$setup_home/.ssh/config" "    HostName example.com" "setup-only hostname"
assert_grep "$setup_home/.ssh/config" "    User user" "setup-only user"
assert_grep "$setup_home/.ssh/config" "    IdentityFile /tmp/key" "setup-only identity"
assert_grep "$setup_home/.ssh/config" "    ProxyJump jumpbox" "setup-only proxyjump"
assert_grep "$setup_home/.ssh/config" "    RemoteForward 32022 127.0.0.1:22" "setup-only remote forward"

if HOME="$tmp/unsafe-rh" RH_HOME=/ bash "$ROOT/manage.sh" --uninstall >/dev/null 2>"$tmp/manage-rh-root.err"; then
  fail "manage accepted RH_HOME=/"
fi
assert_grep "$tmp/manage-rh-root.err" "RH_HOME" "manage rejects root RH_HOME"
if HOME="$tmp/unsafe-rh" RH_HOME="$tmp/unsafe-rh" bash "$ROOT/manage.sh" --uninstall >/dev/null 2>"$tmp/manage-rh-home.err"; then
  fail "manage accepted RH_HOME=\$HOME"
fi
assert_grep "$tmp/manage-rh-home.err" "RH_HOME" "manage rejects HOME RH_HOME"
if HOME="$tmp/unsafe-rh" RH_HOME="../remote-harness" bash "$ROOT/manage.sh" --uninstall >/dev/null 2>"$tmp/manage-rh-rel.err"; then
  fail "manage accepted relative traversal RH_HOME"
fi
assert_grep "$tmp/manage-rh-rel.err" "RH_HOME" "manage rejects relative RH_HOME"

if HOME="$tmp/launch-home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" \
  bash "$ROOT/scripts/laptop-setup.sh" \
    --host example.com --port 32022 --via "ssh user@example.com" \
    --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test" \
    --box-alias laptop --launch "codex --flag" --setup-only --yes \
    >"$tmp/laptop-bad-launch.out" 2>"$tmp/laptop-bad-launch.err"; then
  fail "laptop-setup accepted extra --launch words"
fi
assert_grep "$tmp/laptop-bad-launch.err" "unsupported --launch" "laptop launch validation"
if HOME="$tmp/local-launch-home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" \
  bash "$ROOT/scripts/local-setup.sh" --via "ssh user@example.com" --remote-path /srv/app \
    --launch "codex --flag" --yes >"$tmp/local-bad-launch.out" 2>"$tmp/local-bad-launch.err"; then
  fail "local-setup accepted extra --launch words"
fi
assert_grep "$tmp/local-bad-launch.err" "unsupported --launch" "local launch validation"

cat > "$tmp/bin/ssh" <<'EOS'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    *'grep -qx'*) exit 0;;
    *'mount-project.sh'*) printf 'STATUS=mounted\nMOUNTPOINT=/tmp/rh-remote\n'; exit 0;;
    *'inject-rule.sh'*) printf 'RH_STATUS=ERROR\n'; exit 0;;
  esac
done
exit 0
EOS
chmod +x "$tmp/bin/ssh"
proj_home="$tmp/project-dir-home"
valid_project="$tmp/valid project"
created_project="$tmp/created project"
file_project="$tmp/not-a-dir"
mkdir -p "$proj_home" "$valid_project"
printf 'x\n' > "$file_project"
HOME="$proj_home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" \
  bash "$ROOT/scripts/laptop-setup.sh" \
    --host example.com --port 32023 --via "ssh user@example.com" \
    --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test" \
    --box-alias laptop --remote-mountpoint /tmp/rh-remote \
    --project-dir "$valid_project" --launch codex --yes > "$tmp/project-valid.out"
assert_grep "$tmp/project-valid.out" "Project dir (from skill)" "project-dir valid accepted"
HOME="$proj_home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" \
  bash "$ROOT/scripts/laptop-setup.sh" \
    --host example.com --port 32024 --via "ssh user@example.com" \
    --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test" \
    --box-alias laptop --remote-mountpoint /tmp/rh-remote \
    --project-dir "$created_project" --launch codex --yes >"$tmp/project-create.out" 2>"$tmp/project-create.err"
[ -d "$created_project" ] || fail "laptop-setup did not create missing project dir under --yes"
assert_grep "$tmp/project-create.err" "Created $created_project" "project-dir create path"
if HOME="$proj_home" PATH="$tmp/bin:$PATH" RH_COMMON="$ROOT/scripts/_common.sh" \
  bash "$ROOT/scripts/laptop-setup.sh" \
    --host example.com --port 32025 --via "ssh user@example.com" \
    --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest remote-harness@test" \
    --box-alias laptop --remote-mountpoint /tmp/rh-remote \
    --project-dir "$file_project" --launch codex --yes >"$tmp/project-file.out" 2>"$tmp/project-file.err"; then
  fail "laptop-setup accepted non-directory project path"
fi
assert_grep "$tmp/project-file.err" "No valid project directory selected" "project-dir non-directory abort"

if bash "$ROOT/scripts/mount-project.sh" --alias >/dev/null 2>"$tmp/mount-missing.err"; then
  fail "mount-project accepted missing --alias value"
fi
assert_grep "$tmp/mount-missing.err" "missing value for --alias" "mount missing arg"
if bash "$ROOT/scripts/check-tunnel.sh" --alias >/dev/null 2>"$tmp/check-missing.err"; then
  fail "check-tunnel accepted missing --alias value"
fi
assert_grep "$tmp/check-missing.err" "missing value for --alias" "check missing arg"
if bash "$ROOT/scripts/preflight.sh" --direction >/dev/null 2>"$tmp/preflight-missing.err"; then
  fail "preflight accepted missing --direction value"
fi
assert_grep "$tmp/preflight-missing.err" "missing value for --direction" "preflight missing arg"

while IFS= read -r f; do
  [ -f "${f%.md}.cn.md" ] || fail "missing Chinese doc counterpart for $f"
done < <(git -C "$ROOT" ls-files --cached --others --exclude-standard '*.md' | grep -v '^README.md$' | grep -v '^CLAUDE.md$' | grep -v '\.cn\.md$')

printf 'ok\n'
