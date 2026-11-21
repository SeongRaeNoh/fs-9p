#!/usr/bin/env bash
# demo/bisect.sh - git bisect run with tools/qnx-run: find the commit that broke a unit test that
# fails only on QNX.
# The script makes a small git history (8 commits) of a portable C file, errclass.c, which sorts
# errno values into "retry", "unsupported" and "fatal". Commit 5 "simplifies" it: it drops the
# ENOTSUP test because ENOTSUP and EOPNOTSUPP are the same value on Linux with glibc. The script
# prints whether the two are the same value on this Linux machine and in the QNX guest; where they
# differ, the unit test fails from commit 5 on, while the same test built for Linux still passes.
# Each bisect step builds the test with qcc on this machine into the shared folder and runs it in
# the guest with tools/qnx-run: exit status 0 marks the commit good, 1 bad, 125 (build failed or
# qnx-run failed) skips it, and 255 (ssh cannot reach the guest) ends the bisect.
# Runs on the machine with QNX SDP 8.0 (source qnxsdp-env.sh) and the running guest: after
# tools/qnx-vm start with QNX_IMAGE set, or with QNX_SHARE and QNX_SSH / QNX_SSH_PORT as for
# tools/qnx-run. Needs git, and cc for the Linux comparison. The output has no host paths and no
# times; a copy goes to tests/logs/bisect_<date>.log.
# usage: demo/bisect.sh [WORK_DIR]   (inside the shared folder; default: SHARE/bisect-demo)
# Copyright 2026 The fs-9p authors. Licensed under the Apache License, Version 2.0.
set -u
cd "$(dirname "$0")/.." || exit 2
REPO=$PWD
export PATH=$REPO/tools:$PATH          # qnx-run below is tools/qnx-run
SHARE=${QNX_SHARE:-$(cat "${QNX_IMAGE:-/nonexistent}/qnx-vm/share" 2>/dev/null)}
[ -n "$SHARE" ] || { echo "bisect: set QNX_SHARE (or QNX_IMAGE of tools/qnx-vm)"; exit 2; }
command -v qcc >/dev/null || { echo "bisect: qcc not found; source qnxsdp-env.sh of QNX SDP 8.0"; exit 2; }
command -v git >/dev/null || { echo "bisect: git not found"; exit 2; }
D=${1:-$SHARE/bisect-demo}
mkdir -p tests/logs
LOG=$REPO/tests/logs/bisect_$(date +%Y%m%d_%H%M%S).log
HASH=$(sh tests/srchash.sh)
hide() { sed -e "s|$D|WORK|g" -e "s|$SHARE|SHARE|g" -e "s|$REPO|REPO|g" -e "s|$HOME|HOME|g"; }
# run CMD: print CMD, then run it with bash in WORK
run() { printf '\n$ %s\n' "$1"; bash -c "$1" 2>&1; }

# Fixed names and dates: the commit hashes are the same on every run.
export GIT_AUTHOR_NAME=demo GIT_AUTHOR_EMAIL=demo@example.invalid
export GIT_COMMITTER_NAME=demo GIT_COMMITTER_EMAIL=demo@example.invalid GIT_CONFIG_NOSYSTEM=1
n=0
commit() {   # commit MESSAGE
    n=$((n + 1))
    export GIT_AUTHOR_DATE="2026-01-0$n 12:00:00 +0000" GIT_COMMITTER_DATE="2026-01-0$n 12:00:00 +0000"
    git add -A && git -c commit.gpgsign=false commit -q -m "$1"
}

{
echo "# fs-9p git bisect demo, $(date -Iseconds), sources sha256 $HASH (tests/srchash.sh)"
rm -rf "$D"; mkdir -p "$D"; cd "$D" || exit 2
git init -q -b main . 2>/dev/null || git init -q .

# --- commit 1: the function and its unit test
cat > errclass.h <<'EOF'
/* errclass.h - sort errno values into classes that a caller can act on */
enum err_class { ERR_RETRY, ERR_UNSUPPORTED, ERR_FATAL };
enum err_class err_class(int e);
EOF
cat > errclass.c <<'EOF'
#include <errno.h>
#include "errclass.h"

enum err_class err_class(int e)
{
    if (e == EAGAIN || e == EINTR)
        return ERR_RETRY;
    if (e == ENOSYS || e == ENOTSUP || e == EOPNOTSUPP)
        return ERR_UNSUPPORTED;
    return ERR_FATAL;
}
EOF
cat > test_errclass.c <<'EOF'
#include <errno.h>
#include <stdio.h>
#include "errclass.h"

static int failed;

static void check(int e, const char *name, enum err_class want)
{
    int ok = err_class(e) == want;
    printf("%s %s\n", ok ? "ok" : "not ok", name);
    failed += !ok;
}

int main(void)
{
    check(EAGAIN, "EAGAIN is retry", ERR_RETRY);
    check(EINTR, "EINTR is retry", ERR_RETRY);
    check(ENOSYS, "ENOSYS is unsupported", ERR_UNSUPPORTED);
    check(ENOTSUP, "ENOTSUP is unsupported", ERR_UNSUPPORTED);
    check(EOPNOTSUPP, "EOPNOTSUPP is unsupported", ERR_UNSUPPORTED);
    printf("%d failed\n", failed);
    return failed != 0;
}
EOF
printf 'test_errclass\ntest_linux\nsame_qnx\nsame_linux\n' > .gitignore
commit "errclass: sort errno values into retry, unsupported and fatal"
# --- commits 2 to 8
sed -i 's|^    printf("%d failed|    check(EIO, "EIO is fatal", ERR_FATAL);\n    printf("%d failed|' test_errclass.c
commit "test: EIO is fatal"
sed -i 's/e == EAGAIN || e == EINTR/e == EAGAIN || e == EWOULDBLOCK || e == EINTR/' errclass.c
commit "errclass: EWOULDBLOCK is retry too"
printf 'errclass: sort errno values into classes; test: test_errclass.c\n' > README
commit "add README"
sed -i 's/e == ENOSYS || e == ENOTSUP || e == EOPNOTSUPP/e == ENOSYS || e == EOPNOTSUPP/' errclass.c
commit "errclass: simplify, ENOTSUP is EOPNOTSUPP"
sed -i 's/e == EWOULDBLOCK || e == EINTR/e == EWOULDBLOCK || e == EINTR || e == ETIMEDOUT/' errclass.c
sed -i 's|^    check(ENOSYS|    check(ETIMEDOUT, "ETIMEDOUT is retry", ERR_RETRY);\n    check(ENOSYS|' test_errclass.c
commit "errclass: ETIMEDOUT is retry"
printf 'classes: retry (try again), unsupported (use another way), fatal (give up)\n' >> README
commit "README: the three classes"
sed -i 's|^/\* errclass.h - .*|/* errclass.h - sort errno values into retry, unsupported and fatal */|' errclass.h
commit "errclass.h: comment"

run "git log --oneline"
echo
echo "### Is ENOTSUP the same value as EOPNOTSUPP? (a program prints the comparison)"
printf '#include <errno.h>\n#include <stdio.h>\nint main(void) { puts(ENOTSUP == EOPNOTSUPP ? "same value" : "two different values"); return 0; }\n' > same.c
run 'cc -o same_linux same.c && echo "Linux: $(./same_linux)"'
run 'qcc -Vgcc_ntox86_64 -o same_qnx same.c && echo "QNX guest: $(qnx-run ./same_qnx)"'
rm -f same.c

echo
echo "### The unit test at the newest commit: built for Linux, and built with qcc and run in the QNX guest"
run 'cc -o test_linux test_errclass.c errclass.c && ./test_linux; echo "Linux exit status $?"'
run 'qcc -Vgcc_ntox86_64 -o test_errclass test_errclass.c errclass.c && qnx-run ./test_errclass; echo "QNX exit status $?"'

echo
echo "### git bisect: newest commit bad, first commit good; each step builds with qcc and runs the test in the guest"
FIRST=$(git rev-list --max-parents=0 HEAD)
run "git bisect start HEAD $FIRST"
run 'git bisect run sh -c '"'"'qcc -Vgcc_ntox86_64 -o test_errclass test_errclass.c errclass.c || exit 125; qnx-run ./test_errclass'"'"'' | tee "$D.bisect.txt"
BAD=$(sed -n 's/^\([0-9a-f]\{7,40\}\) is the first bad commit$/\1/p' "$D.bisect.txt" | head -1)
STEPS=$(grep -c '^running ' "$D.bisect.txt")
run "git bisect reset"
SUBJ=$( [ -n "$BAD" ] && git log -1 --format=%s "$BAD")
echo
echo "bisect: $(git rev-list --count HEAD) commits in the history; $STEPS commits built and run in the guest by git bisect run"
echo "bisect: first bad commit: ${BAD:0:7} \"$SUBJ\""
rm -f "$D.bisect.txt"
if [ "$SUBJ" = "errclass: simplify, ENOTSUP is EOPNOTSUPP" ]; then
    echo "RESULT: git bisect run with tools/qnx-run found the planted commit"
else
    echo "RESULT: FAILED: the planted commit was not found"
fi
} 2>&1 | hide | tee "$LOG"
echo "log: ${LOG#$REPO/}"
grep -q '^RESULT: git bisect run with tools/qnx-run found the planted commit' "$LOG"
