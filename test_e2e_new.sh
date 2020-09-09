#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

TESTCASE=""
function testcase() {
    clean_root
    init_repo
    echo -n "testcase $1: "
    TESTCASE="$1"
}

function dump_stack() {
  local stack_skip=${1:-0}
  stack_skip=$((stack_skip + 1))
  if [[ ${#FUNCNAME[@]} -gt ${stack_skip} ]]; then
    echo "Call stack:" >&2
    local i
    for ((i=1 ; i <= ${#FUNCNAME[@]} - stack_skip ; i++))
    do
      local frame_no=$((i - 1 + stack_skip))
      local source_file=${BASH_SOURCE[${frame_no}]}
      local source_lineno=${BASH_LINENO[$((frame_no - 1))]}
      local funcname=${FUNCNAME[${frame_no}]}
      echo "  ${i}: ${source_file}:${source_lineno} ${funcname}(...)" >&2
    done
  fi
}

function fail() {
    echo "FAIL: " "$@"
    dump_stack
    remove_containers || true
    exit 1
}

function pass() {
    echo "PASS"
    remove_containers || true
    TESTCASE=""
}

function assert_link_exists() {
    if ! [[ -e "$1" ]]; then
        fail "$1 does not exist"
    fi
    if ! [[ -L "$1" ]]; then
        fail "$1 is not a symlink"
    fi
}

function assert_file_exists() {
    if ! [[ -f "$1" ]]; then
        fail "$1 does not exist"
    fi
}

function assert_file_absent() {
    if [[ -f "$1" ]]; then
        fail "$1 exists"
    fi
}

function assert_file_eq() {
    if [[ $(cat "$1") == "$2" ]]; then
        return
    fi
    fail "file $1 does not contain '$2': $(cat $1)"
}

#FIXME: remove all users of this in favor of docker
NCPORT=8888
function freencport() {
  while :; do
    NCPORT=$((RANDOM+2000))
    ss -lpn | grep -q ":$NCPORT " || break
  done
}

# #####################
# main
# #####################

# Build it
make container REGISTRY=e2e VERSION=$(make -s version)
echo
make test-tools REGISTRY=e2e
echo

RUNID="${RANDOM}${RANDOM}"
DIR=""
for i in $(seq 1 10); do
    DIR="/tmp/git-sync-e2e.$RUNID"
    mkdir "$DIR" && break
done
if [[ -z "$DIR" ]]; then
    echo "Failed to make a test root dir"
    exit 1
fi
TMP="$DIR/tmp"
mkdir -p "$TMP"

echo "test root is $DIR"
echo

REPO="$DIR/repo"
function init_repo() {
    rm -rf "$REPO"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    touch "$REPO"/file
    git -C "$REPO" add file
    git -C "$REPO" commit -aqm "init file"
}

ROOT="$DIR/root"
function clean_root() {
    rm -rf "$ROOT"
}

# Init SSH for test cases.
DOT_SSH="$DIR/dot_ssh"
mkdir -p "$DOT_SSH"
ssh-keygen -f "$DOT_SSH/id_test" -P "" >/dev/null
cat "$DOT_SSH/id_test.pub" > "$DOT_SSH/authorized_keys"

function finish() {
  if [ $? -ne 0 ]; then
    echo -e "\nTest logs: $DIR"
  fi
  trap "" INT EXIT
  remove_containers
  exit 1
}
trap finish INT EXIT

SLOW_GIT=/slow_git.sh
ASKPASS_GIT=/askpass_git.sh

#FIXME: not on hostnet?
function GIT_SYNC() {
    #./bin/linux_amd64/git-sync "$@"
    docker run \
        -i \
        --rm \
        --label git-sync-e2e="$RUNID" \
        --network="host" \
        -u $(id -u):$(id -g) \
        -v "$DIR":"$DIR":rw \
        -v "$(pwd)/slow_git.sh":"$SLOW_GIT":ro \
        -v "$(pwd)/askpass_git.sh":"$ASKPASS_GIT":ro \
        -v "$DOT_SSH/id_test":"/etc/git-secret/ssh":ro \
        --env XDG_CONFIG_HOME=$DIR \
        e2e/git-sync:$(make -s version)__$(go env GOOS)_$(go env GOARCH) \
        --add-user \
        --v=5 \
        "$@"
}

function remove_containers() {
    sleep 2 # Let docker finish saving container metadata
    docker ps --filter label="git-sync-e2e=$RUNID" --format="{{.ID}}" \
        | while read CTR; do
            docker kill "$CTR" >/dev/null
        done
}

##############################################
# Test initializing when root doesn't exist
##############################################
testcase "sha-root-doesnt-exist"
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
SHA=$(git -C "$REPO" rev-parse HEAD)
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --rev="sha:$SHA" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

##############################################
# Test initializing when root exists but is under a git repo
##############################################
testcase "sha-root-exists-but-is-not-git-root"
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
SHA=$(git -C "$REPO" rev-parse HEAD)
# Make a parent dir that is a git repo.
mkdir -p "$ROOT/subdir/root"
git -C "$ROOT/subdir" init >/dev/null
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --rev="sha:$SHA" \
    --root="$ROOT/subdir/root" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/subdir/root/link
assert_file_exists "$ROOT"/subdir/root/link/file
assert_file_eq "$ROOT"/subdir/root/link/file "$TESTCASE"
# Wrap up
pass

##############################################
# Test initializing when root exists but fails sanity
##############################################
testcase "sha-root-exists-but-fails-sanity"
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
SHA=$(git -C "$REPO" rev-parse HEAD)
# Make an invalid git repo.
mkdir -p "$ROOT"
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --rev="sha:$SHA" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

##############################################
# Test initializing when root exists and is valid
##############################################
testcase "sha-root-exists-and-is-valid"
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
SHA=$(git -C "$REPO" rev-parse HEAD)
# Make a valid git repo.
mkdir -p "$ROOT"
git -C "$ROOT" init >/dev/null
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --rev="sha:$SHA" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

##############################################
# Test initializing when worktree exists but no link
##############################################
testcase "sha-worktree-exists-but-no-link"
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
SHA=$(git -C "$REPO" rev-parse HEAD)
# Make a valid git repo.
mkdir -p "$ROOT"
git -C "$ROOT" init >/dev/null
# Fake a worktree, but not a link
mkdir -p "$ROOT/worktrees/$SHA"
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --rev="sha:$SHA" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

##############################################
# Test initializing when worktree exists but is not correctly linked
##############################################
testcase "sha-worktree-exists-but-wrong-link"
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
SHA=$(git -C "$REPO" rev-parse HEAD)
# Make a valid git repo.
mkdir -p "$ROOT"
git -C "$ROOT" init >/dev/null
# Fake a worktree and link
mkdir -p "$ROOT/worktrees/$SHA"
ln -sf "$ROOT/wrong" "$ROOT/link"
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --rev="sha:$SHA" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

##############################################
# Test initializing when worktree exists and is linked
##############################################
testcase "sha-worktree-exists-correct-link-bad-worktree"
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
SHA=$(git -C "$REPO" rev-parse HEAD)
# Make a valid git repo.
mkdir -p "$ROOT"
git -C "$ROOT" init >/dev/null
# Fake a worktree and link
mkdir -p "$ROOT/worktrees/$SHA"
ln -sf "$ROOT/worktrees/$SHA" "$ROOT/link"
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --rev="sha:$SHA" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

##############################################
# Test initializing with a weird --root flag
##############################################
testcase "sha-root-flag-is-weird"
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
SHA=$(git -C "$REPO" rev-parse HEAD)
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --rev="sha:$SHA" \
    --root="../../../../../$ROOT/../../../../../../$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

##############################################
# Test initializing when worktree exists and linked is correct, but weird
##############################################
testcase "sha-worktree-exists-correct-but-weird-link"
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
SHA=$(git -C "$REPO" rev-parse HEAD)
# Make a valid git repo.
mkdir -p "$ROOT"
git -C "$ROOT" init >/dev/null
# Fake a worktree and link
mkdir -p "$ROOT/worktrees/$SHA"
ln -sf "../../../../../$ROOT/../../../../../$ROOT/worktrees/$SHA" "$ROOT/link"
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --rev="sha:$SHA" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

##############################################
# Test converting from a normal to shallow repo
##############################################
testcase "sha-deep-to-shallow-to-deep"
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
SHA=$(git -C "$REPO" rev-parse HEAD)
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --rev="sha:$SHA" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
if [ $(git -C "$ROOT/worktrees/$SHA" rev-parse --is-shallow-repository) = "true" ]; then
    fail "repo should not be shallow"
fi
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --rev="sha:$SHA" \
    --root="$ROOT" \
    --leaf="link" \
    --depth=1 \
    >> "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
if [ $(git -C "$ROOT/worktrees/$SHA" rev-parse --is-shallow-repository) = "false" ]; then
    fail "repo should be shallow"
fi
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --rev="sha:$SHA" \
    --root="$ROOT" \
    --leaf="link" \
    >> "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
if [ $(git -C "$ROOT/worktrees/$SHA" rev-parse --is-shallow-repository) = "true" ]; then
    fail "repo should not be shallow"
fi
# Wrap up
pass

#FIXME: COMMENT
testcase "repo-size"
dd if=/dev/urandom of="$REPO"/file1 bs=1024 count=4096 >/dev/null 2>&1
git -C "$REPO" add file1
git -C "$REPO" commit -qam "file 1"
git -C "$REPO" tag -f "f1" # to force export of the SHA
SHA1=$(git -C "$REPO" rev-parse HEAD)
dd if=/dev/urandom of="$REPO"/file2 bs=1024 count=4096 >/dev/null 2>&1
git -C "$REPO" add file2
git -C "$REPO" commit -qam "file 1+2"
git -C "$REPO" rm -q file1
git -C "$REPO" commit -qam "file 2"
git -C "$REPO" tag -f "f2" # to force export of the SHA
SHA2=$(git -C "$REPO" rev-parse HEAD)
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --rev="sha:$SHA1" \
    --root="$ROOT" \
    --leaf="link" \
    --depth=1 \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
SIZE=$(du -s "$ROOT" | cut -f1)
if [ "$SIZE" -lt 7000 ]; then
    fail "repo is impossibly small: $SIZE"
fi
if [ "$SIZE" -gt 9000 ]; then
    fail "repo is too big: $SIZE"
fi
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --rev="sha:$SHA2" \
    --root="$ROOT" \
    --leaf="link" \
    --depth=1 \
    >> "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file2
SIZE=$(du -s "$ROOT" | cut -f1)
if [ "$SIZE" -lt 7000 ]; then
    fail "repo is impossibly small: $SIZE"
fi
if [ "$SIZE" -gt 9000 ]; then
    fail "repo is too big: $SIZE"
fi
# Wrap up
pass

##############################################
# Test master one-time
##############################################
testcase "master-one-time"
# First sync
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --rev=master \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

##############################################
# Test master syncing
##############################################
testcase "master"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --period=100ms \
    --repo="file://$REPO" \
    --rev=master \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Move HEAD forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move HEAD backward
git -C "$REPO" reset -q --hard HEAD^
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test initializing when root doesn't exist
##############################################
testcase "special-file-names"
# First sync
echo "$TESTCASE 1" > "$REPO"/link
git -C "$REPO" add link
mkdir -p "$REPO"/worktrees/
echo "$TESTCASE 1" > "$REPO"/worktrees/file
git -C "$REPO" add worktrees/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --period=100ms \
    --repo="file://$REPO" \
    --rev=master \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/link
assert_file_eq "$ROOT"/link/link "$TESTCASE 1"
assert_file_exists "$ROOT"/link/worktrees/file
assert_file_eq "$ROOT"/link/worktrees/file "$TESTCASE 1"
# Move HEAD forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/link
assert_file_eq "$ROOT"/link/link "$TESTCASE 1"
assert_file_exists "$ROOT"/link/worktrees/file
assert_file_eq "$ROOT"/link/worktrees/file "$TESTCASE 1"
# Move HEAD backward
git -C "$REPO" reset -q --hard HEAD^
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/link
assert_file_eq "$ROOT"/link/link "$TESTCASE 1"
assert_file_exists "$ROOT"/link/worktrees/file
assert_file_eq "$ROOT"/link/worktrees/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test default syncing (master)
##############################################
testcase "defaults"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --period=100ms \
    --repo="file://$REPO" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Move forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move backward
git -C "$REPO" reset -q --hard HEAD^
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test branch syncing
##############################################
testcase "branch"
BRANCH="$TESTCASE"--BRANCH
# First sync
git -C "$REPO" checkout -q -b "$BRANCH"
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
git -C "$REPO" checkout -q master
GIT_SYNC \
    --period=100ms \
    --repo="file://$REPO" \
    --rev="$BRANCH" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Add to the branch.
git -C "$REPO" checkout -q "$BRANCH"
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
git -C "$REPO" checkout -q master
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move the branch backward
git -C "$REPO" checkout -q "$BRANCH"
git -C "$REPO" reset -q --hard HEAD^
git -C "$REPO" checkout -q master
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test tag syncing
##############################################
testcase "simple-tag"
TAG="$TESTCASE"--TAG
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
git -C "$REPO" tag -f "$TAG" >/dev/null
GIT_SYNC \
    --period=100ms \
    --repo="file://$REPO" \
    --rev="$TAG" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Add something and move the tag forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
git -C "$REPO" tag -f "$TAG" >/dev/null
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move the tag backward
git -C "$REPO" reset -q --hard HEAD^
git -C "$REPO" tag -f "$TAG" >/dev/null
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Add something after the tag
echo "$TESTCASE 3" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 3"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test tag syncing with annotated tags
##############################################
testcase "annotated-tag"
TAG="$TESTCASE"--TAG
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 1" >/dev/null
GIT_SYNC \
    --period=100ms \
    --repo="file://$REPO" \
    --rev="$TAG" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Add something and move the tag forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 2" >/dev/null
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move the tag backward
git -C "$REPO" reset -q --hard HEAD^
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 3" >/dev/null
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Add something after the tag
echo "$TESTCASE 3" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 3"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test syncing after a crash
##############################################
#FIXME: fup with earlier cases?
testcase "bad-git-repo"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Corrupt it
rm -f "$ROOT"/.git/HEAD
# Try again
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --root="$ROOT" \
    --leaf="link" \
    >> "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test syncing after a crash
##############################################
testcase "bad-worktree"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Corrupt it
rm -f "$ROOT"/link
# Try again
GIT_SYNC \
    --one-time \
    --repo="file://$REPO" \
    --root="$ROOT" \
    --leaf="link" \
    >> "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test sync loop timeout
##############################################
testcase "sync-loop-timeout"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --git="$SLOW_GIT" \
    --one-time \
    --sync-timeout=1s \
    --repo="file://$REPO" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 || true
# check for failure
assert_file_absent "$ROOT"/link/file
# run with slow_git but without timing out
GIT_SYNC \
    --git="$SLOW_GIT" \
    --period=100ms \
    --sync-timeout=16s \
    --repo="file://$REPO" \
    --root="$ROOT" \
    --leaf="link" \
    >> "$DIR"/log."$TESTCASE" 2>&1 &
sleep 10
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Move forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 10
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Wrap up
pass

##############################################
# Test depth syncing
##############################################
testcase "depth"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
expected_depth="1"
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --period=100ms \
    --repo="file://$REPO" \
    --depth="$expected_depth" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
if [ $expected_depth != $depth ]; then
    fail "initial depth mismatch expected=$expected_depth actual=$depth"
fi
# Move forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
if [ $expected_depth != $depth ]; then
    fail "forward depth mismatch expected=$expected_depth actual=$depth"
fi
# Move backward
git -C "$REPO" reset -q --hard HEAD^
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
if [ $expected_depth != $depth ]; then
    fail "backward depth mismatch expected=$expected_depth actual=$depth"
fi
# Wrap up
pass

##############################################
# Test password
##############################################
testcase "password"
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
# run with askpass_git but with wrong password
GIT_SYNC \
    --git="$ASKPASS_GIT" \
    --username="my-username" \
    --password="wrong" \
    --one-time \
    --repo="file://$REPO" \
    --rev=master \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 || true
# check for failure
assert_file_absent "$ROOT"/link/file
# run with askpass_git with correct password
GIT_SYNC \
    --git="$ASKPASS_GIT" \
    --username="my-username" \
    --password="my-password" \
    --one-time \
    --repo="file://$REPO" \
    --rev=master \
    --root="$ROOT" \
    --leaf="link" \
    >> "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##############################################
# Test askpass_url
##############################################
testcase "askpass_url"
echo "$TESTCASE 1" > "$REPO"/file
freencport
git -C "$REPO" commit -qam "$TESTCASE 1"
# run the askpass_url service with wrong password
CTR=$(docker run \
    -d \
    --rm \
    --label git-sync-e2e="$RUNID" \
    -u $(id -u):$(id -g) \
    alpine sh -c \
        "while true; do echo -e 'HTTP/1.1 200 OK\r\n\r\nusername=my-username\npassword=wrong' | nc -l -p 8000; done")
sleep 1 # wait for it to come up
IP=$(docker inspect "$CTR" | jq -r .[0].NetworkSettings.IPAddress)
GIT_SYNC \
    --git="$ASKPASS_GIT" \
    --askpass-url="http://$IP:8000/git_askpass" \
    --one-time \
    --repo="file://$REPO" \
    --rev=master \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 || true
# check for failure
assert_file_absent "$ROOT"/link/file
docker kill "$CTR" >/dev/null
# run with askpass_url service with correct password
CTR=$(docker run \
    -d \
    --rm \
    --label git-sync-e2e="$RUNID" \
    -u $(id -u):$(id -g) \
    alpine sh -c \
        "while true; do echo -e 'HTTP/1.1 200 OK\r\n\r\nusername=my-username\npassword=my-password' | nc -l -p 8000; done")
sleep 1 # wait for it to come up
IP=$(docker inspect "$CTR" | jq -r .[0].NetworkSettings.IPAddress)
GIT_SYNC \
    --git="$ASKPASS_GIT" \
    --askpass-url="http://$IP:8000/git_askpass" \
    --one-time \
    --repo="file://$REPO" \
    --rev=master \
    --root="$ROOT" \
    --leaf="link" \
    >> "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pass

##FIXME: ##############################################
##FIXME: # Test webhook
##FIXME: ##############################################
##FIXME: testcase "webhook"
##FIXME: # Check that basic call works
##FIXME: echo 0 > "$TMP/count.$TESTCASE"
##FIXME: CTR=$(docker run \
##FIXME:     -d \
##FIXME:     --rm \
##FIXME:     --label git-sync-e2e="$RUNID" \
##FIXME:     -u $(id -u):$(id -g) \
##FIXME:     -v "$TMP":"$TMP":rw \
##FIXME:     alpine sh -c \
##FIXME:         "I=1; while true; do echo -e 'HTTP/1.1 200 OK\r\n' | nc -l -p 80; echo \$I > $TMP/count.$TESTCASE; done")
##FIXME: sleep 1 # wait for it to come up
##FIXME: IP=$(docker inspect "$CTR" | jq -r .[0].NetworkSettings.IPAddress)
##FIXME: # First sync
##FIXME: echo "$TESTCASE 1" > "$REPO"/file
##FIXME: git -C "$REPO" commit -qam "$TESTCASE 1"
##FIXME: GIT_SYNC \
##FIXME:     --repo="file://$REPO" \
##FIXME:     --root="$ROOT" \
##FIXME:     --webhook-url="http://$IP" \
##FIXME:     --leaf="link" \
##FIXME:     > "$DIR"/log."$TESTCASE" 2>&1 &
##FIXME: sleep 3
##FIXME: COUNT=$(cat "$TMP/count.$TESTCASE")
##FIXME: if [ "$COUNT" != 1 ]; then
##FIXME:     fail "webhook 1: expected 1 call, got $COUNT"
##FIXME: fi
##FIXME: docker kill "$CTR" >/dev/null
##FIXME: ###FIXME: this is not good - if I start a new container I may get a new IP.
##FIXME: # Move forward
##FIXME: echo "$TESTCASE 2" > "$REPO"/file
##FIXME: git -C "$REPO" commit -qam "$TESTCASE 2"
##FIXME: # return a failure to ensure that we try again
##FIXME: { (echo -e "HTTP/1.1 500 Internal Server Error\r\n" | nc -q1 -l $NCPORT > /dev/null) &}
##FIXME: NCPID=$!
##FIXME: sleep 3
##FIXME: if kill -0 $NCPID > /dev/null 2>&1; then
##FIXME:     fail "webhook 2 not called, server still running"
##FIXME: fi
##FIXME: # Now return 200, ensure that it gets called
##FIXME: { (echo -e "HTTP/1.1 200 OK\r\n" | nc -q1 -l $NCPORT > /dev/null) &}
##FIXME: NCPID=$!
##FIXME: sleep 3
##FIXME: if kill -0 $NCPID > /dev/null 2>&1; then
##FIXME:     fail "webhook 3 not called, server still running"
##FIXME: fi
##FIXME: # Wrap up
##FIXME: pass

##############################################
# Test http handler
##############################################
testcase "http-handler"
BINDPORT=8888
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --git="$SLOW_GIT" \
    --repo="file://$REPO" \
    --root="$ROOT" \
    --http-bind=":$BINDPORT" \
    --http-metrics \
    --http-pprof \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
while ! curl --silent --output /dev/null http://localhost:$BINDPORT; do
    # do nothing, just wait for the HTTP to come up
    true
done
# check that health endpoint fails
if [[ $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$BINDPORT) -ne 503 ]] ; then
    fail "health endpoint should have failed: $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$BINDPORT)"
fi
sleep 2
# check that health endpoint is alive
if [[ $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$BINDPORT) -ne 200 ]] ; then
    fail "health endpoint failed"
fi
# check that the metrics endpoint exists
if [[ $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$BINDPORT/metrics) -ne 200 ]] ; then
    fail "metrics endpoint failed"
fi
# check that the pprof endpoint exists
if [[ $(curl --write-out %{http_code} --silent --output /dev/null http://localhost:$BINDPORT/debug/pprof/) -ne 200 ]] ; then
    fail "pprof endpoint failed"
fi
# Wrap up
pass

##############################################
# Test submodule sync
##############################################
testcase "submodule"

# Init submodule repo
SUBMODULE_REPO_NAME="sub"
SUBMODULE="$DIR/$SUBMODULE_REPO_NAME"
mkdir "$SUBMODULE"

git -C "$SUBMODULE" init -q
echo "submodule" > "$SUBMODULE"/submodule
git -C "$SUBMODULE" add submodule
git -C "$SUBMODULE" commit -aqm "init submodule file"

# Init nested submodule repo
NESTED_SUBMODULE_REPO_NAME="nested-sub"
NESTED_SUBMODULE="$DIR/$NESTED_SUBMODULE_REPO_NAME"
mkdir "$NESTED_SUBMODULE"

git -C "$NESTED_SUBMODULE" init -q
echo "nested-submodule" > "$NESTED_SUBMODULE"/nested-submodule
git -C "$NESTED_SUBMODULE" add nested-submodule
git -C "$NESTED_SUBMODULE" commit -aqm "init nested-submodule file"

# Add submodule
git -C "$REPO" submodule add -q file://$SUBMODULE
git -C "$REPO" commit -aqm "add submodule"
GIT_SYNC \
    --period=100ms \
    --repo="file://$REPO" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "submodule"
# Make change in submodule repo
echo "$TESTCASE 2" > "$SUBMODULE"/submodule
git -C "$SUBMODULE" commit -qam "$TESTCASE 2"
git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "$TESTCASE 2"
# Move backward in submodule repo
git -C "$SUBMODULE" reset -q --hard HEAD^
git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1
git -C "$REPO" commit -qam "$TESTCASE 3"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "submodule"
# Add nested submodule to submodule repo
git -C "$SUBMODULE" submodule add -q file://$NESTED_SUBMODULE
git -C "$SUBMODULE" commit -aqm "add nested submodule"
git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1
git -C "$REPO" commit -qam "$TESTCASE 4"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/$NESTED_SUBMODULE_REPO_NAME/nested-submodule
assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/$NESTED_SUBMODULE_REPO_NAME/nested-submodule "nested-submodule"
# Remove nested submodule
git -C "$SUBMODULE" submodule deinit -q $NESTED_SUBMODULE_REPO_NAME
rm -rf "$SUBMODULE"/.git/modules/$NESTED_SUBMODULE_REPO_NAME
git -C "$SUBMODULE" rm -qf $NESTED_SUBMODULE_REPO_NAME
git -C "$SUBMODULE" commit -aqm "delete nested submodule"
git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1
git -C "$REPO" commit -qam "$TESTCASE 5"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_absent "$ROOT"/link/$SUBMODULE_REPO_NAME/$NESTED_SUBMODULE_REPO_NAME/nested-submodule
# Remove submodule
git -C "$REPO" submodule deinit -q $SUBMODULE_REPO_NAME
rm -rf "$REPO"/.git/modules/$SUBMODULE_REPO_NAME
git -C "$REPO" rm -qf $SUBMODULE_REPO_NAME
git -C "$REPO" commit -aqm "delete submodule"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_absent "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
# Wrap up
rm -rf $SUBMODULE
rm -rf $NESTED_SUBMODULE
pass

##############################################
# Test submodules depth syncing
##############################################
testcase "submodule-with-depth"

# Init submodule repo
SUBMODULE_REPO_NAME="sub"
SUBMODULE="$DIR/$SUBMODULE_REPO_NAME"
mkdir "$SUBMODULE"

git -C "$SUBMODULE" init -q

# First sync
expected_depth="1"
echo "$TESTCASE 1" > "$SUBMODULE"/submodule
git -C "$SUBMODULE" add submodule
git -C "$SUBMODULE" commit -aqm "submodule $TESTCASE 1"
git -C "$REPO" submodule add -q file://$SUBMODULE
git -C "$REPO" config -f "$REPO"/.gitmodules submodule.$SUBMODULE_REPO_NAME.shallow true
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --period=100ms \
    --repo="file://$REPO" \
    --depth="$expected_depth" \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "$TESTCASE 1"
depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
if [ $expected_depth != $depth ]; then
    fail "initial depth mismatch expected=$expected_depth actual=$depth"
fi
submodule_depth=$(GIT_DIR="$ROOT"/link/$SUBMODULE_REPO_NAME/.git git log | grep commit | wc -l)
if [ $expected_depth != $submodule_depth ]; then
    fail "initial submodule depth mismatch expected=$expected_depth actual=$submodule_depth"
fi
# Move forward
echo "$TESTCASE 2" > "$SUBMODULE"/submodule
git -C "$SUBMODULE" commit -aqm "submodule $TESTCASE 2"
git -C "$REPO" submodule update --recursive --remote > /dev/null 2>&1
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "$TESTCASE 2"
depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
if [ $expected_depth != $depth ]; then
    fail "forward depth mismatch expected=$expected_depth actual=$depth"
fi
submodule_depth=$(GIT_DIR="$ROOT"/link/$SUBMODULE_REPO_NAME/.git git log | grep commit | wc -l)
if [ $expected_depth != $submodule_depth ]; then
    fail "forward submodule depth mismatch expected=$expected_depth actual=$submodule_depth"
fi
# Move backward
git -C "$SUBMODULE" reset -q --hard HEAD^
git -C "$REPO" submodule update --recursive --remote  > /dev/null 2>&1
git -C "$REPO" commit -qam "$TESTCASE 3"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule "$TESTCASE 1"
depth=$(GIT_DIR="$ROOT"/link/.git git log | grep commit | wc -l)
if [ $expected_depth != $depth ]; then
    fail "initial depth mismatch expected=$expected_depth actual=$depth"
fi
submodule_depth=$(GIT_DIR="$ROOT"/link/$SUBMODULE_REPO_NAME/.git git log | grep commit | wc -l)
if [ $expected_depth != $submodule_depth ]; then
    fail "initial submodule depth mismatch expected=$expected_depth actual=$submodule_depth"
fi
# Wrap up
rm -rf $SUBMODULE
pass

##############################################
# Test submodules off
##############################################
testcase "submodule-sync-off"

# Init submodule repo
SUBMODULE_REPO_NAME="sub"
SUBMODULE="$DIR/$SUBMODULE_REPO_NAME"
mkdir "$SUBMODULE"

git -C "$SUBMODULE" init -q
echo "submodule" > "$SUBMODULE"/submodule
git -C "$SUBMODULE" add submodule
git -C "$SUBMODULE" commit -aqm "init submodule file"

# Add submodule
git -C "$REPO" submodule add -q file://$SUBMODULE
git -C "$REPO" commit -aqm "add submodule"

GIT_SYNC \
    --period=100ms \
    --repo="file://$REPO" \
    --root="$ROOT" \
    --leaf="link" \
    --submodules=off \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_file_absent "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
rm -rf $SUBMODULE
pass

##############################################
# Test submodules shallow
##############################################
testcase "submodule-sync-shallow"

# Init submodule repo
SUBMODULE_REPO_NAME="sub"
SUBMODULE="$DIR/$SUBMODULE_REPO_NAME"
mkdir "$SUBMODULE"

git -C "$SUBMODULE" init -q
echo "submodule" > "$SUBMODULE"/submodule
git -C "$SUBMODULE" add submodule
git -C "$SUBMODULE" commit -aqm "init submodule file"
# Init nested submodule repo
NESTED_SUBMODULE_REPO_NAME="nested-sub"
NESTED_SUBMODULE="$DIR/$NESTED_SUBMODULE_REPO_NAME"
mkdir "$NESTED_SUBMODULE"

git -C "$NESTED_SUBMODULE" init -q
echo "nested-submodule" > "$NESTED_SUBMODULE"/nested-submodule
git -C "$NESTED_SUBMODULE" add nested-submodule
git -C "$NESTED_SUBMODULE" commit -aqm "init nested-submodule file"
git -C "$SUBMODULE" submodule add -q file://$NESTED_SUBMODULE
git -C "$SUBMODULE" commit -aqm "add nested submodule"

# Add submodule
git -C "$REPO" submodule add -q file://$SUBMODULE
git -C "$REPO" commit -aqm "add submodule"

GIT_SYNC \
    --period=100ms \
    --repo="file://$REPO" \
    --root="$ROOT" \
    --leaf="link" \
    --submodules=shallow \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/$SUBMODULE_REPO_NAME/submodule
assert_file_absent "$ROOT"/link/$SUBMODULE_REPO_NAME/$NESTED_SUBMODULE_REPO_NAME/nested-submodule
rm -rf $SUBMODULE
rm -rf $NESTED_SUBMODULE
pass

##############################################
# Test submodule remote tracking sync
##############################################
testcase "submodule-sync-remote-tracking"

# Init submodule repo
SUBMODULE1_REPO_NAME="sub1"
SUBMODULE1_NAME="submodule1-remote-tracking"
SUBMODULE1_BRANCH="branch1"

SUBMODULE2_REPO_NAME="sub2"
SUBMODULE2_NAME="submodule2-remote-tracking"

SUBMODULE3_REPO_NAME="sub3"
SUBMODULE3_NAME="submodule3-remote-tracking"

SUBMODULE1=$DIR/$SUBMODULE1_REPO_NAME
SUBMODULE2=$DIR/$SUBMODULE2_REPO_NAME
SUBMODULE3=$DIR/$SUBMODULE3_REPO_NAME

for i in $(seq 1 3); do
  SUBMODULE=$(eval "echo \$SUBMODULE${i}")
  SUBMODULE_NAME=$(eval "echo \$SUBMODULE${i}_NAME")

  # Create submodule repo
  mkdir "$SUBMODULE"
  git -C "$SUBMODULE" init -q
  echo "submodule${i}" > "$SUBMODULE"/submodule
  git -C "$SUBMODULE" add submodule
  git -C "$SUBMODULE" commit -aqm "init submodule${i} file"

  # Add submodule
  git -C "$REPO" submodule add -q --name $SUBMODULE_NAME file://$SUBMODULE
  git -C "$REPO" commit -aqm "add submodule${i}"
done

GIT_SYNC \
    --logtostderr \
    --v=5 \
    --period="100ms" \
    --repo="file://$REPO" \
    --root="$ROOT" \
    --leaf="link" \
    --submodules-remote-tracking="$SUBMODULE1_NAME,$SUBMODULE3_NAME" \
    > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/$SUBMODULE1_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE1_REPO_NAME/submodule "submodule1"
assert_file_exists "$ROOT"/link/$SUBMODULE2_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE2_REPO_NAME/submodule "submodule2"
assert_file_exists "$ROOT"/link/$SUBMODULE3_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE3_REPO_NAME/submodule "submodule3"

## Make change in submodules repo listed in the remote tracking
echo "$TESTCASE 2" > "$SUBMODULE1"/submodule
git -C "$SUBMODULE1" commit -qam "$TESTCASE 2"
echo "$TESTCASE 2" > "$SUBMODULE3"/submodule
git -C "$SUBMODULE3" commit -qam "$TESTCASE 2"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/$SUBMODULE1_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE1_REPO_NAME/submodule "$TESTCASE 2"
assert_file_exists "$ROOT"/link/$SUBMODULE2_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE2_REPO_NAME/submodule "submodule2"
assert_file_exists "$ROOT"/link/$SUBMODULE3_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE3_REPO_NAME/submodule "$TESTCASE 2"

## Make change in submodules repo not listed in the remote tracking
git -C "$SUBMODULE1" reset -q --hard HEAD~1
git -C "$SUBMODULE3" reset -q --hard HEAD~1
echo "$TESTCASE 2" > "$SUBMODULE2"/submodule
git -C "$SUBMODULE2" commit -qam "$TESTCASE 3"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/$SUBMODULE1_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE1_REPO_NAME/submodule "submodule1"
assert_file_exists "$ROOT"/link/$SUBMODULE2_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE2_REPO_NAME/submodule "submodule2"
assert_file_exists "$ROOT"/link/$SUBMODULE3_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE3_REPO_NAME/submodule "submodule3"

## Remote tracking submodules branch
git -C "$SUBMODULE1" checkout -qb $SUBMODULE1_BRANCH
echo "$TESTCASE 4" > "$SUBMODULE1"/submodule
git -C "$SUBMODULE1" commit -qam "$TESTCASE 4"
git -C "$REPO" submodule -q set-branch --branch $SUBMODULE1_BRANCH -- $SUBMODULE1_NAME
git -C "$REPO" commit -aqm "submodule1 with branch"
sleep 3
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_exists "$ROOT"/link/$SUBMODULE1_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE1_REPO_NAME/submodule "$TESTCASE 4"
assert_file_exists "$ROOT"/link/$SUBMODULE2_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE2_REPO_NAME/submodule "submodule2"
assert_file_exists "$ROOT"/link/$SUBMODULE3_REPO_NAME/submodule
assert_file_eq "$ROOT"/link/$SUBMODULE3_REPO_NAME/submodule "submodule3"

# Wrap up
rm -rf $SUBMODULE1 $SUBMODULE2 $SUBMODULE3
pass

##############################################
# Test SSH
##############################################
testcase "ssh"
echo "$TESTCASE" > "$REPO"/file
# Run a git-over-SSH server
#FIXME: run as my uid?
CTR=$(docker run \
    -d \
    --rm \
    --label git-sync-e2e="$RUNID" \
    -v "$DOT_SSH":/dot_ssh:ro \
    -v "$REPO":/src:ro \
    e2e/test/test-sshd)
sleep 3 # wait for sshd to come up
IP=$(docker inspect "$CTR" | jq -r .[0].NetworkSettings.IPAddress)
git -C "$REPO" commit -qam "$TESTCASE"
GIT_SYNC \
    --one-time \
    --ssh \
    --ssh-known-hosts=false \
    --repo="test@$IP:/src" \
    --rev=master \
    --root="$ROOT" \
    --leaf="link" \
    > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass
