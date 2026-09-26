# -*- coding: utf-8 -*-
"""
Uploads the whole SUPERCARS project to a GitHub repository (so Bitrise can build it).

    python tools/upload_to_github.py                       # asks for your GitHub token, pushes to the default repo
    python tools/upload_to_github.py --dry-run             # shows what would be uploaded, pushes nothing
    python tools/upload_to_github.py --repo https://github.com/USER/REPO.git --branch main
    python tools/upload_to_github.py --skip-assets-src     # do not upload assets_src/ (66 MB of original GLBs, not needed for the build)
    python tools/upload_to_github.py --force               # overwrite whatever is already in the repo (e.g. its auto-created README)

Needs: git (https://git-scm.com/download/win) and a GitHub personal access token with the "repo" scope
(GitHub > Settings > Developer settings > Personal access tokens > Tokens (classic) > Generate new token > tick "repo").
The token is read from the GITHUB_TOKEN environment variable or typed in (hidden). It is NEVER written to disk, to the git config or to the
remote URL: it is passed to git for this one push only, and it is removed from every message this script prints.
"""
import argparse
import base64
import getpass
import os
import shutil
import subprocess
import sys

DEFAULT_REPO = "https://github.com/Mohamed2020p/firstgameswift.git"
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GITHUB_FILE_LIMIT = 100 * 1024 * 1024          # a single file above this is rejected by GitHub
WARN_LIMIT = 50 * 1024 * 1024
JUNK = ["__pycache__/", "*.pyc", ".DS_Store", "Thumbs.db", "*.tmp"]


class Runner(object):
    def __init__(self, token, verbose):
        self.token = token
        self.verbose = verbose

    def _clean(self, text):
        if self.token:
            text = text.replace(self.token, "***")
            text = text.replace(base64.b64encode(("x-access-token:" + self.token).encode()).decode(), "***")
        return text

    def git(self, *args, **kw):
        """runs git in the project folder; returns (exit code, combined output)"""
        cmd = ["git"]
        if kw.get("auth") and self.token:
            basic = base64.b64encode(("x-access-token:" + self.token).encode()).decode()
            cmd += ["-c", "http.extraheader=AUTHORIZATION: basic " + basic]
        cmd += list(args)
        if self.verbose:
            print("   $ " + self._clean(" ".join(cmd)))
        p = subprocess.run(cmd, cwd=PROJECT_ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = self._clean(p.stdout.decode("utf-8", "replace"))
        return p.returncode, out


def fail(msg, code=1):
    print("\nERROR: " + msg)
    sys.exit(code)


def human(n):
    return "%.1f MB" % (n / 1048576.0)


def check_big_files(skip_assets_src):
    big, warn = [], []
    for dp, dn, fn in os.walk(PROJECT_ROOT):
        dn[:] = [d for d in dn if d not in (".git", "__pycache__")]
        rel_dir = os.path.relpath(dp, PROJECT_ROOT)
        if skip_assets_src and (rel_dir == "assets_src" or rel_dir.startswith("assets_src" + os.sep)):
            continue
        for f in fn:
            p = os.path.join(dp, f)
            try:
                s = os.path.getsize(p)
            except OSError:
                continue
            if s >= GITHUB_FILE_LIMIT:
                big.append((p, s))
            elif s >= WARN_LIMIT:
                warn.append((p, s))
    return big, warn


def main():
    ap = argparse.ArgumentParser(description="Upload the SUPERCARS project to GitHub")
    ap.add_argument("--repo", default=DEFAULT_REPO, help="https URL of the (empty) GitHub repository")
    ap.add_argument("--branch", default="main")
    ap.add_argument("--message", default="Supercars: full project upload")
    ap.add_argument("--skip-assets-src", action="store_true", help="do not upload assets_src/ (original GLBs, not needed by the build)")
    ap.add_argument("--force", action="store_true", help="overwrite the remote branch (use when the repo already contains a README)")
    ap.add_argument("--dry-run", action="store_true", help="only show what would happen")
    ap.add_argument("--verbose", action="store_true", help="print every git command")
    ap.add_argument("--name", default="", help="git user.name for the commit (only used if git has none configured)")
    ap.add_argument("--email", default="", help="git user.email for the commit (only used if git has none configured)")
    args = ap.parse_args()

    print("SUPERCARS -> GitHub uploader")
    print("  project : " + PROJECT_ROOT)
    print("  repo    : " + args.repo)
    print("  branch  : " + args.branch)

    if not args.repo.startswith("https://"):
        fail("use the https:// URL of the repository (the token login only works over https).")
    if shutil.which("git") is None:
        fail("git is not installed or not in PATH. Install it from https://git-scm.com/download/win and open a new terminal.")
    if not os.path.isdir(os.path.join(PROJECT_ROOT, "Supercars")) or not os.path.isfile(os.path.join(PROJECT_ROOT, "bitrise.yaml")):
        fail("this does not look like the SUPERCARS project folder (Supercars/ or bitrise.yaml missing).")

    big, warn = check_big_files(args.skip_assets_src)
    for p, s in warn:
        print("  note: %s is %s (allowed, but slow to upload)" % (os.path.relpath(p, PROJECT_ROOT), human(s)))
    if big:
        for p, s in big:
            print("  TOO BIG: %s is %s" % (os.path.relpath(p, PROJECT_ROOT), human(s)))
        fail("GitHub rejects files of 100 MB or more. Remove them or use --skip-assets-src.")

    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token and not args.dry_run:
        print("\nPaste your GitHub personal access token (scope: repo). Nothing is shown while you type/paste.")
        token = getpass.getpass("token: ").strip()
        if not token:
            fail("no token given.")
    run = Runner(token, args.verbose)

    # ---- repository setup ------------------------------------------------------------------------------------------------------------
    if not os.path.isdir(os.path.join(PROJECT_ROOT, ".git")):
        print("\n[1/6] git init")
        code, out = run.git("init", "-b", args.branch)
        if code != 0:                                    # older git without -b
            run.git("init")
            run.git("checkout", "-B", args.branch)
    else:
        print("\n[1/6] existing git repository found")
        run.git("checkout", "-B", args.branch)

    # keep junk out; optionally keep assets_src out (local exclude, does not change .gitignore)
    exclude_path = os.path.join(PROJECT_ROOT, ".git", "info", "exclude")
    os.makedirs(os.path.dirname(exclude_path), exist_ok=True)
    lines = []
    if os.path.isfile(exclude_path):
        lines = open(exclude_path, "r", encoding="utf-8", errors="replace").read().splitlines()
    wanted = list(JUNK) + (["assets_src/"] if args.skip_assets_src else [])
    changed = False
    for w in wanted:
        if w not in lines:
            lines.append(w)
            changed = True
    if not args.skip_assets_src and "assets_src/" in lines:
        lines.remove("assets_src/")
        changed = True
    if changed:
        open(exclude_path, "w", encoding="utf-8").write("\n".join(lines) + "\n")

    # commit identity
    code, cur_name = run.git("config", "user.name")
    code2, cur_email = run.git("config", "user.email")
    if not cur_name.strip():
        run.git("config", "user.name", args.name or "c0derz")
    if not cur_email.strip():
        run.git("config", "user.email", args.email or "c0derz@users.noreply.github.com")

    # ---- stage ----------------------------------------------------------------------------------------------------------------------
    print("[2/6] staging files")
    code, out = run.git("add", "-A")
    if code != 0:
        fail("git add failed:\n" + out)
    code, out = run.git("status", "--short")
    staged = [l for l in out.splitlines() if l.strip()]
    print("      %d changed / new files" % len(staged))
    if args.dry_run:
        code, out = run.git("ls-files")
        files = [l for l in out.splitlines() if l.strip()]
        print("\nDRY RUN: %d files would be in the repository. First entries:" % len(files))
        for l in files[:25]:
            print("   " + l)
        print("   ...")
        print("\nNothing was pushed. Run again without --dry-run to upload.")
        return 0

    # ---- commit ---------------------------------------------------------------------------------------------------------------------
    print("[3/6] committing")
    code, out = run.git("commit", "-m", args.message)
    if code != 0 and "nothing to commit" not in out.lower():
        fail("git commit failed:\n" + out)
    if "nothing to commit" in out.lower():
        print("      nothing new to commit (already committed)")

    # ---- remote ---------------------------------------------------------------------------------------------------------------------
    print("[4/6] setting the remote")
    code, out = run.git("remote", "get-url", "origin")
    if code == 0:
        run.git("remote", "set-url", "origin", args.repo)
    else:
        run.git("remote", "add", "origin", args.repo)

    # ---- push -----------------------------------------------------------------------------------------------------------------------
    print("[5/6] pushing (this can take a few minutes for ~80 MB)")
    push = ["push", "-u", "origin", args.branch]
    if args.force:
        push.insert(1, "--force")
    code, out = run.git(*push, auth=True)
    if code != 0:
        low = out.lower()
        if "rejected" in low or "non-fast-forward" in low or "fetch first" in low:
            print("\nThe repository already has commits (usually the README GitHub created).")
            print("Run again with  --force  to replace them with this project:")
            print("    python tools/upload_to_github.py --force")
        elif "authentication" in low or "403" in low or "401" in low or "invalid username or password" in low or "denied" in low:
            print("\nGitHub refused the login. Check that the token is a classic token with the 'repo' scope and that it belongs to the")
            print("owner of the repository (or that you are a collaborator).")
        elif "not found" in low or "404" in low:
            print("\nRepository not found: check the URL, and that the token can see private repositories (scope 'repo').")
        elif "http2" in low or "rpc failed" in low or "hung up" in low or "timed out" in low:
            print("\nThe upload was interrupted (large push). Try again, or:  git config --global http.postBuffer 524288000")
        fail("git push failed:\n" + out)

    print("[6/6] done")
    print("\nUploaded. Repository: " + args.repo[:-4] if args.repo.endswith(".git") else args.repo)
    print("Next: bitrise.io > Add new app > pick this repo > use the existing bitrise.yaml > run workflow 'build_ipa'.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\ncancelled.")
        sys.exit(130)
